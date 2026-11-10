# DEFAULTUSER.ps1 - copies the HKCU tweaks this playbook applied into the Default user profile, so accounts created
# after the install start with them.
#
# Why: HKU\.DEFAULT is the LocalSystem profile (sign-in screen, services), NOT the template for new accounts. New
# accounts are built from C:\Users\Default\NTUSER.DAT, and nothing else in the playbook writes to it (verified on the
# VM, docs/atlas-comparison.md 2.3).
#
# How: it reads the playbook's own YAML (..\Configuration\Tasks\**\*.yml, not revert.yml), collects every
# !registryValue whose path starts with HKCU\, and copies a value into the Default hive only when the running user's
# HKCU holds exactly that value. Options the user did not select, values Windows overwrote and failed writes are
# therefore skipped without a second list that could drift. Deletes (operation: delete) are not copied.
#
# Usage: DEFAULTUSER.ps1 [-ConfigDir <folder with the .yml files>] [-HiveFile <NTUSER.DAT>] [-WhatIf]
# Runs as the elevated user whose HKCU received the tweaks. Never fails the apply: every problem is logged and exit is 0.
# Keep this file ASCII-only (Windows PowerShell 5.1).
[CmdletBinding()]
param(
    [string]$ConfigDir,
    [string]$HiveFile,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:ProgramData 'WinDebloat'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'default-user.log'

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 's'), $Message
    Add-Content -LiteralPath $logFile -Value $line
    Write-Host $line
}

if (-not $ConfigDir) { $ConfigDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'Configuration\Tasks' }
if (-not (Test-Path -LiteralPath $ConfigDir)) {
    Write-Log "SKIPPED: the playbook configuration folder was not found ($ConfigDir)"
    exit 0
}
if (-not $HiveFile) {
    $profileList = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue
    $defaultDir = if ($profileList -and $profileList.Default) { [Environment]::ExpandEnvironmentVariables($profileList.Default) } else { Join-Path $env:SystemDrive 'Users\Default' }
    $HiveFile = Join-Path $defaultDir 'NTUSER.DAT'
}
if (-not (Test-Path -LiteralPath $HiveFile)) {
    Write-Log "SKIPPED: the Default profile hive was not found ($HiveFile)"
    exit 0
}

# ---- 1. read the HKCU !registryValue entries from the YAML ----
function ConvertFrom-YamlScalar([string]$Text) {
    $t = $Text.Trim()
    if ($t.Length -ge 2 -and $t.StartsWith("'") -and $t.EndsWith("'")) { return $t.Substring(1, $t.Length - 2).Replace("''", "'") }
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) { return $t.Substring(1, $t.Length - 2).Replace('\\', '\').Replace('\"', '"') }
    return $t
}

$pairRegex = [regex]"(?<k>[A-Za-z]+):\s*(?<v>'(?:[^']|'')*'|""(?:[^""\\]|\\.)*""|[^,}]*)"
$entries = New-Object System.Collections.Generic.List[object]
$files = @(Get-ChildItem -LiteralPath $ConfigDir -Filter '*.yml' -Recurse -File | Where-Object { $_.Name -notmatch '^revert' })
foreach ($file in $files) {
    $text = [IO.File]::ReadAllText($file.FullName)
    $bodies = New-Object System.Collections.Generic.List[hashtable]
    # one-liners:  - !registryValue: {path: '...', value: '...', type: REG_DWORD, data: '0'}
    foreach ($m in [regex]::Matches($text, '!registryValue:\s*\{(?<body>[^\r\n]*)\}')) {
        $h = @{}
        foreach ($p in $pairRegex.Matches($m.Groups['body'].Value)) { $h[$p.Groups['k'].Value] = ConvertFrom-YamlScalar $p.Groups['v'].Value }
        $bodies.Add($h)
    }
    # block style:  - !registryValue:  followed by indented "key: value" lines
    foreach ($m in [regex]::Matches($text, '(?m)!registryValue:[ \t]*\r?\n(?<body>(?:[ \t]+[A-Za-z]+:[^\r\n]*\r?\n?)+)')) {
        $h = @{}
        foreach ($line in ($m.Groups['body'].Value -split '\r?\n')) {
            if ($line -match '^\s+(?<k>[A-Za-z]+):\s*(?<v>.*?)\s*$') { $h[$Matches['k']] = ConvertFrom-YamlScalar $Matches['v'] }
        }
        $bodies.Add($h)
    }
    foreach ($h in $bodies) {
        if (-not $h.path -or $h.path -notmatch '^HKCU\\') { continue }
        if ($h.operation -and $h.operation -ne 'add') { continue }
        if (-not $h.value -or -not $h.type -or $null -eq $h.data) { continue }
        $entries.Add([pscustomobject]@{ Sub = $h.path.Substring(5); Name = $h.value; Type = $h.type; Data = [string]$h.data; File = $file.Name })
    }
}
Write-Log "Found $($entries.Count) HKCU value entries in $($files.Count) YAML file(s)"

# ---- 2. keep the ones the running user's HKCU actually holds ----
function ConvertTo-RegValue($Entry) {
    # YAML data -> (kind, value) as the registry API wants them; $null when the type is not supported.
    switch ($Entry.Type) {
        'REG_DWORD' {
            $n = 0L
            if (-not [int64]::TryParse($Entry.Data, [ref]$n)) { return $null }
            return @{ Kind = 'DWord'; Value = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]($n -band 0xFFFFFFFFL)), 0) }
        }
        'REG_SZ' { return @{ Kind = 'String'; Value = $Entry.Data } }
        'REG_EXPAND_SZ' { return @{ Kind = 'ExpandString'; Value = $Entry.Data } }
        'REG_BINARY' {
            $hex = ($Entry.Data -replace '[^0-9A-Fa-f]', '')
            if ($hex.Length % 2 -ne 0) { return $null }
            $bytes = New-Object byte[] ($hex.Length / 2)
            for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring(2 * $i, 2), 16) }
            return @{ Kind = 'Binary'; Value = $bytes }
        }
        default { return $null }
    }
}

function Test-SameValue($Kind, $Wanted, $Live) {
    if ($null -eq $Live) { return $false }
    if ($Kind -eq 'Binary') { return (($Wanted | ForEach-Object { $_.ToString('x2') }) -join '') -eq (($Live | ForEach-Object { $_.ToString('x2') }) -join '') }
    return "$Wanted" -eq "$Live"
}

$toCopy = New-Object System.Collections.Generic.List[object]
$seen = @{}
$notApplied = 0; $unsupported = 0
foreach ($e in $entries) {
    $conv = ConvertTo-RegValue $e
    if (-not $conv) { $unsupported++; continue }
    $liveKey = $null
    try {
        $liveKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($e.Sub, $false)
        if (-not $liveKey) { $notApplied++; continue }
        $live = $liveKey.GetValue($e.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -ne $live -and $liveKey.GetValueKind($e.Name).ToString() -eq $conv.Kind -and (Test-SameValue $conv.Kind $conv.Value $live)) {
            $id = ($e.Sub + '|' + $e.Name).ToLowerInvariant()
            if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $toCopy.Add([pscustomobject]@{ Sub = $e.Sub; Name = $e.Name; Kind = $conv.Kind; Value = $conv.Value }) }
        } else { $notApplied++ }
    } catch { $notApplied++ } finally { if ($liveKey) { $liveKey.Close() } }
}
Write-Log "To copy: $($toCopy.Count); not applied for this user (option off, overwritten or failed): $notApplied; unsupported type: $unsupported"
if ($WhatIf) { $toCopy | ForEach-Object { Write-Log "  would copy $($_.Sub) $($_.Name)" }; exit 0 }
if ($toCopy.Count -eq 0) { exit 0 }

# ---- 3. write them into the Default hive ----
# wdtool's own HKCU tweaks mirror into this hive under HKU\DefaultUserHive and never unload it, so the file is usually
# already mounted (a second reg load of the same file fails with 'used by another process'). Reuse that mount.
$mount = 'DefaultUserHive'
$loadedByUs = $false
$probe = [Microsoft.Win32.Registry]::Users.OpenSubKey($mount, $false)
if ($probe) { $probe.Close(); Write-Log "using the already loaded HKU\$mount" }
else {
    $mount = 'WDDefaultUser'
    $out = & reg.exe load "HKU\$mount" "$HiveFile" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log "SKIPPED: could not load $HiveFile (reg load exit $LASTEXITCODE): $(($out | Out-String).Trim())"
        exit 0
    }
    $loadedByUs = $true
}
$copied = 0; $failed = 0
try {
    foreach ($v in $toCopy) {
        $key = $null
        try {
            $key = [Microsoft.Win32.Registry]::Users.CreateSubKey("$mount\$($v.Sub)")
            $key.SetValue($v.Name, $v.Value, [Microsoft.Win32.RegistryValueKind]$v.Kind)
            $copied++
        } catch {
            $failed++
            Write-Log "  failed: $($v.Sub) $($v.Name): $($_.Exception.Message)"
        } finally { if ($key) { $key.Close() } }
    }
} finally {
    $unloaded = -not $loadedByUs   # only release a mount this script made
    for ($i = 0; $i -lt 6 -and -not $unloaded; $i++) {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        & reg.exe unload "HKU\$mount" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $unloaded = $true } else { Start-Sleep -Seconds 2 }
    }
    if (-not $unloaded) { Write-Log 'WARNING: could not unload the Default hive; it is released at the next restart' }
}
Write-Log "Copied $copied value(s) into $HiveFile; failed $failed"
exit 0
