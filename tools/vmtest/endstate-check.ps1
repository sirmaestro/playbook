<#
.SYNOPSIS
    Guest side of the live end-state check (tools\vmtest.ps1, Invoke-VmtLiveStateCheck).

.DESCRIPTION
    Reads the expected registry / service / file state that amelog.py derived from the playbook
    (`amelog.py expected`) and compares it with this machine. Runs in Windows PowerShell 5.1, as the
    interactive admin, so HKCU is the user the playbook was applied for. Keep it ASCII.

    Prints  VMTEST_ENDSTATE_BEGIN <json> VMTEST_ENDSTATE_END  with the counts and every mismatch.
    A value that matches is not listed. Read-only: nothing on the machine is changed.
#>
param([Parameter(Mandatory)][string]$ExpectedFile)

$ErrorActionPreference = 'Stop'
$expected = (Get-Content -LiteralPath $ExpectedFile -Raw | ConvertFrom-Json).entries

function Open-Hive([string]$Hive) {
    switch ($Hive.ToUpperInvariant()) {
        'HKLM' { return [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64') }
        'HKCU' { return [Microsoft.Win32.RegistryKey]::OpenBaseKey('CurrentUser', 'Registry64') }
        'HKU'  { return [Microsoft.Win32.RegistryKey]::OpenBaseKey('Users', 'Registry64') }
        'HKCR' { return [Microsoft.Win32.RegistryKey]::OpenBaseKey('ClassesRoot', 'Registry64') }
        default { return $null }
    }
}

function Open-Key([string]$Path) {
    # Returns the key, or $null when it does not exist. Throws on an unknown hive.
    $i = $Path.IndexOf('\')
    $hive = if ($i -ge 0) { $Path.Substring(0, $i) } else { $Path }
    $rest = if ($i -ge 0) { $Path.Substring($i + 1) } else { '' }
    $root = Open-Hive $hive
    if (-not $root) { throw "unknown hive $hive" }
    if (-not $rest) { return $root }
    return $root.OpenSubKey($rest, $false)
}

$kinds = @{ REG_SZ = 'String'; REG_DWORD = 'DWord'; REG_BINARY = 'Binary'; REG_MULTI_SZ = 'MultiString'; REG_EXPAND_SZ = 'ExpandString' }

function Format-Actual($v, $kind) {
    if ($null -eq $v) { return $null }
    if ($kind -eq 'Binary') { return (($v | ForEach-Object { '{0:x2}' -f $_ }) -join '') }
    if ($kind -eq 'MultiString') { return ($v -join '|') }
    if ($kind -eq 'DWord') { return [string][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$v), 0) }
    return [string]$v
}

function Test-ValueData($e, $v, $kind) {
    switch ($e.rtype) {
        'REG_DWORD' {
            $want = [int64]$e.data -band 0xFFFFFFFF
            return ([int64](Format-Actual $v $kind) -eq $want)
        }
        'REG_BINARY' {
            $want = ($e.data.ToLowerInvariant() -replace '[^0-9a-f]', '')
            return ((Format-Actual $v $kind) -ceq $want)
        }
        'REG_MULTI_SZ' {
            $joined = @($v) -join ' '
            return ($joined -ceq $e.data -or (@($v) -join "`0") -ceq $e.data -or (@($v) -join '|') -ceq $e.data)
        }
        default { return ([string]$v -ceq [string]$e.data) }
    }
}

$mismatches = New-Object System.Collections.ArrayList
$counts = @{ checked = 0; ok = 0; mismatch = 0; error = 0 }

foreach ($e in $expected) {
    $counts.checked++
    $result = $null   # $null = matches; otherwise a reason string plus the actual state
    $actual = $null
    try {
        switch ($e.kind) {
            'value' {
                $key = Open-Key $e.path
                if ($e.op -eq 'absent') {
                    if ($key) {
                        $v = $key.GetValue($e.name, $null, 'DoNotExpandEnvironmentNames')
                        if ($null -ne $v) { $kind = [string]$key.GetValueKind($e.name); $result = 'present'; $actual = Format-Actual $v $kind }
                    }
                }
                else {
                    if (-not $key) { $result = 'key missing' }
                    else {
                        $v = $key.GetValue($e.name, $null, 'DoNotExpandEnvironmentNames')
                        if ($null -eq $v) { $result = 'value missing' }
                        else {
                            $kind = [string]$key.GetValueKind($e.name)
                            if ($kinds[$e.rtype] -ne $kind) { $result = "type is $kind"; $actual = Format-Actual $v $kind }
                            elseif (-not (Test-ValueData $e $v $kind)) { $result = 'data differs'; $actual = Format-Actual $v $kind }
                        }
                    }
                }
            }
            'key' {
                $key = Open-Key $e.path
                if ($e.op -eq 'present' -and -not $key) { $result = 'key missing' }
                if ($e.op -eq 'absent' -and $key) { $result = 'key present' }
            }
            'service' {
                $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Services\' + $e.name, $false)
                # A service this build does not have cannot be started or stopped: nothing to compare.
                if ($key) {
                    $v = $key.GetValue('Start', $null)
                    if ($null -eq $v -or [string]$v -ne [string]$e.data) { $result = 'start differs'; $actual = [string]$v }
                }
            }
            'file' {
                $p = [Environment]::ExpandEnvironmentVariables($e.path)
                if (Test-Path -LiteralPath $p) { $result = 'present'; $actual = $p }
            }
        }
    }
    catch { $counts.error++; $result = 'error: ' + $_.Exception.Message }
    if ($null -eq $result) { $counts.ok++; continue }
    if (-not $result.StartsWith('error')) { $counts.mismatch++ }
    [void]$mismatches.Add([ordered]@{
        id = $e.id; kind = $e.kind; path = $e.path; name = $e.name; op = $e.op; soft = [bool]$e.soft
        expected = $(if ($e.op -eq 'absent') { 'absent' } elseif ($e.kind -eq 'service') { 'Start=' + $e.data } elseif ($e.kind -eq 'key') { 'present' } else { [string]$e.data })
        type = $e.rtype; reason = $result; actual = $actual
    })
}

$out = [ordered]@{ counts = $counts; mismatches = @($mismatches); user = $env:USERNAME; build = [Environment]::OSVersion.Version.ToString() }
Write-Output 'VMTEST_ENDSTATE_BEGIN'
Write-Output ($out | ConvertTo-Json -Depth 5 -Compress)
Write-Output 'VMTEST_ENDSTATE_END'
