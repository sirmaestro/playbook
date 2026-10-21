<#
.SYNOPSIS
    Installs app groups from the Apps folder with winget, after making sure winget works.

.DESCRIPTION
    Run once after the playbook has finished, while signed in and online.
    Each Apps\<group>.json is one use-case group in the `winget export` format, so
    `winget import Apps\<group>.json` also works. With no -Group, only the barebones "base"
    group is installed first; a menu then offers the other groups.
    A package may carry "InitialOverrideArguments" to replace the installer's own arguments.

    Apps not packaged in winget from their official source go in an optional top-level
    "GitHubReleases" list in the same group file (winget import ignores it):
      { "Name": "mpv", "Repo": "mpv-player/mpv", "Asset": "-x86_64-w64-mingw32.zip",
        "AddToPath": true, "PostInstall": { "File": "mpv.com", "Arguments": "--register" } }
    The latest release's zip asset whose name ends with "Asset" is checked against the SHA-256
    digest GitHub publishes, extracted to Program Files\<Name>, and PostInstall runs from there.

    After a group installs, its optional top-level "Associations" list makes those apps the
    signed-in user's defaults, through the playbook's assoc.ps1:
      { "App": "SumatraPDF", "Match": "SumatraPDF.exe", "Types": [".pdf", ".xps"] }
    For each type, the ProgId whose open command (or AppUserModelID, for Store apps) contains
    "Match" is picked from the ones the app registered. "CreateProgIds": "7-Zip" first creates
    the 7-Zip.<ext> ProgIds that 7-Zip's own Options dialog would; "RegisterCommand" runs an
    app's own registration first ({ "File": "ImageGlass.exe", "Arguments": "--ig-set-default-viewer
    \"{types}\"" }) for apps that create ProgIds only on request. "DefaultAppsPage": true opens
    the app's page in Settings > Default apps at the end, for defaults Windows only lets the
    user set (web links).

.PARAMETER Group
    Groups to install (file names in Apps without .json), e.g. -Group development,gaming,
    or "all". Skips the menu.

.PARAMETER DryRun
    Check winget and confirm every package ID exists, without installing anything.
    Checks every group unless -Group is given.

.PARAMETER NoAssociations
    Install only; leave default apps alone.
#>
param(
    [string[]]$Group,
    [string]$AppsDir = (Join-Path $PSScriptRoot 'Apps'),
    [version]$MinWingetVersion = '1.7.0',
    [switch]$DryRun,
    [switch]$NoAssociations
)
# Through powershell.exe -File, "-Group a,b" arrives as one string.
$Group = @($Group | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Machine-wide installers need admin; relaunch elevated so UAC is asked once, not per app.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $DryRun -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $hostExe = (Get-Process -Id $PID).Path
    $elevatedArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", '-AppsDir', "`"$AppsDir`"", '-MinWingetVersion', $MinWingetVersion
    )
    if ($Group.Count) { $elevatedArgs += @('-Group', ($Group -join ',')) }
    if ($NoAssociations) { $elevatedArgs += '-NoAssociations' }
    Start-Process -FilePath $hostExe -Verb RunAs -ArgumentList $elevatedArgs
    exit
}

$logFile = Join-Path $PSScriptRoot ("install-apps-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
try { Start-Transcript -Path $logFile | Out-Null } catch { $logFile = $null }

# Known winget exit codes (https://aka.ms/winget-returncodes). PowerShell reads these hex literals as Int32.
$codeAlreadyInstalled = @(0x8A150061, 0x8A15002B, 0x8A15010D)
$codeRebootToFinish   = @(0x8A150109)
$codeNames = @{
    0x8A150010 = 'no package found'
    0x8A150014 = 'no applicable installer'
    0x8A150101 = 'package in use'
    0x8A150102 = 'another install in progress'
    0x8A150103 = 'file in use'
    0x8A150105 = 'disk full'
    0x8A150107 = 'no network'
    0x8A15010A = 'reboot required before install'
    0x8A15010C = 'cancelled'
}

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }

function Wait-Network([int]$TimeoutMinutes = 10) {
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache/source.msix' -Method Head -UseBasicParsing -TimeoutSec 10 | Out-Null
            return $true
        } catch {
            Write-Host '   Not reachable yet, retrying in 10 seconds...'
            Start-Sleep -Seconds 10
        }
    }
    return $false
}

function Get-WingetVersion {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        # A freshly registered App Installer puts its alias here; this session's PATH may not have it yet.
        $aliasDir = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
        if (-not (Test-Path (Join-Path $aliasDir 'winget.exe'))) { return $null }
        $env:Path = "$env:Path;$aliasDir"
    }
    try {
        $text = (& winget.exe --version 2>$null | Out-String).Trim()   # e.g. v1.29.380
        if ($text -match '(\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
    } catch { }
    return $null
}

function Repair-Winget {
    Write-Host '   Repairing winget with Microsoft.WinGet.Client (Repair-WinGetPackageManager)...'
    try {
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
        }
        if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
            Install-Module -Name Microsoft.WinGet.Client -Repository PSGallery -Scope AllUsers -Force
        }
        Import-Module Microsoft.WinGet.Client -Force
        Repair-WinGetPackageManager -AllUsers -Latest
    } catch {
        Write-Warning "   Repair failed: $($_.Exception.Message)"
    }
}

function Format-ExitCode([int]$Code) {
    $hex = '0x{0:X8}' -f $Code
    if ($codeNames.ContainsKey($Code)) { return "$hex $($codeNames[$Code])" }
    return $hex
}

function Get-GitHubAsset($Package) {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($Package.Repo)/releases/latest" `
        -Headers @{ 'User-Agent' = 'INSTALL-APPS'; 'Accept' = 'application/vnd.github+json' } -UseBasicParsing
    $asset = @($release.assets | Where-Object { $_.name -like "*$($Package.Asset)" })
    if ($asset.Count -ne 1) { throw "expected one asset ending in '$($Package.Asset)' in $($release.tag_name), found $($asset.Count)" }
    if ($asset[0].digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "$($asset[0].name) has no SHA-256 digest to verify against" }
    [pscustomobject]@{
        Tag    = $release.tag_name
        Name   = $asset[0].name
        Url    = $asset[0].browser_download_url
        Sha256 = $asset[0].digest.Substring(7)
    }
}

function Expand-Flat([string]$Zip, [string]$Destination) {
    Expand-Archive -LiteralPath $Zip -DestinationPath $Destination -Force
    # Some releases wrap the build in a second zip or a single top-level folder.
    while ($true) {
        $items = @(Get-ChildItem -LiteralPath $Destination -Force)
        if ($items.Count -ne 1) { return }
        $only = $items[0]
        if (-not $only.PSIsContainer -and $only.Extension -eq '.zip') {
            Expand-Archive -LiteralPath $only.FullName -DestinationPath $Destination -Force
            Remove-Item -LiteralPath $only.FullName -Force
        } elseif ($only.PSIsContainer) {
            Get-ChildItem -LiteralPath $only.FullName -Force | Move-Item -Destination $Destination
            Remove-Item -LiteralPath $only.FullName -Force
        } else { return }
    }
}

function Install-GitHubRelease($Package) {
    $dir = Join-Path $env:ProgramFiles $Package.Id
    $marker = Join-Path $dir '.release'
    $work = Join-Path $env:TEMP ("install-apps-" + [guid]::NewGuid())
    try {
        $asset = Get-GitHubAsset $Package
        if ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $marker -Raw).Trim() -eq $asset.Tag) {
            Write-Host "   $($asset.Tag) is already installed in $dir"
            return $codeAlreadyInstalled[0]
        }
        Write-Host "   Downloading $($asset.Name) ($($asset.Tag))"
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $zip = Join-Path $work $asset.Name
        Invoke-WebRequest -Uri $asset.Url -OutFile $zip -UseBasicParsing
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $asset.Sha256) { throw "SHA-256 mismatch for $($asset.Name): got $hash, release lists $($asset.Sha256)" }
        $staged = Join-Path $work 'files'
        Expand-Flat $zip $staged

        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        Move-Item -LiteralPath $staged -Destination $dir
        Set-Content -LiteralPath $marker -Value $asset.Tag

        if ($Package.AddToPath) {
            $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
            if (($machinePath -split ';') -notcontains $dir) {
                [Environment]::SetEnvironmentVariable('Path', "$($machinePath.TrimEnd(';'));$dir", 'Machine')
                $env:Path = "$env:Path;$dir"
                Write-Host "   Added $dir to PATH"
            }
        }
        if ($Package.PostInstall) {
            $exe = Join-Path $dir $Package.PostInstall.File
            Write-Host "   Running $($Package.PostInstall.File) $($Package.PostInstall.Arguments)"
            $proc = Start-Process -FilePath $exe -ArgumentList $Package.PostInstall.Arguments -WorkingDirectory $dir -NoNewWindow -Wait -PassThru
            if ($proc.ExitCode -ne 0) { throw "$($Package.PostInstall.File) exited with $($proc.ExitCode)" }
        }
        Write-Host "   Installed $($asset.Tag) to $dir"
        return 0
    } catch {
        Write-Host "   $($_.Exception.Message)" -ForegroundColor Yellow
        return 1
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Install-Package($Package) {
    if ($Package.Source -eq 'github') { return Install-GitHubRelease $Package }
    $wingetArgs = @('install', '--id', $Package.Id, '--exact', '--source', $Package.Source,
        '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
    if ($Package.Override) { $wingetArgs += @('--override', $Package.Override) } else { $wingetArgs += '--silent' }
    & winget.exe @wingetArgs
    return $LASTEXITCODE
}

# 1. Network
Write-Step 'Waiting for winget download server'
if (-not (Wait-Network)) { throw 'cdn.winget.microsoft.com is unreachable. Check the network connection and run this again.' }

# 2-3. winget present and recent enough
Write-Step 'Checking winget'
$version = Get-WingetVersion
if (-not $version) {
    Write-Host '   winget not found, registering App Installer...'
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
    } catch {
        Write-Warning "   Registration failed: $($_.Exception.Message)"
    }
    $version = Get-WingetVersion
}
if (-not $version -or $version -lt $MinWingetVersion) {
    if ($DryRun) {
        Write-Warning "   winget $version is missing or older than $MinWingetVersion; a real run would repair it."
    } else {
        Repair-Winget
        $version = Get-WingetVersion
    }
}
if (-not $version) { throw 'winget is still unavailable. Update "App Installer" from the Microsoft Store, then run this again.' }
if ($version -lt $MinWingetVersion) { Write-Warning "   winget $version is older than $MinWingetVersion; continuing anyway." }
Write-Host "   winget $version"

# 4. Sources
Write-Step 'Updating winget sources'
& winget.exe source update --disable-interactivity
if ($LASTEXITCODE -ne 0) {
    Write-Host '   Source update failed, resetting sources...'
    & winget.exe source reset --force --disable-interactivity
    & winget.exe source update --disable-interactivity
}

# 5. Groups
if (-not (Test-Path -LiteralPath $AppsDir)) { throw "App groups folder not found: $AppsDir" }
# base first, the rest alphabetically.
$groupNames = @(Get-ChildItem -LiteralPath $AppsDir -Filter '*.json' | ForEach-Object { $_.BaseName } |
    Sort-Object { $_ -ne 'base' }, { $_ })

function Get-GroupPackages([string]$Name) {
    $file = Join-Path $AppsDir "$Name.json"
    if (-not (Test-Path -LiteralPath $file)) { throw "Unknown group '$Name'. Groups: $($groupNames -join ', ')" }
    $list = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    foreach ($source in $list.Sources) {
        foreach ($pkg in $source.Packages) {
            [pscustomobject]@{
                Id       = $pkg.PackageIdentifier
                Source   = $source.SourceDetails.Name
                Override = $pkg.InitialOverrideArguments
                Group    = $Name
            }
        }
    }
    foreach ($rel in $list.GitHubReleases) {
        [pscustomobject]@{
            Id          = $rel.Name
            Source      = 'github'
            Repo        = $rel.Repo
            Asset       = $rel.Asset
            AddToPath   = [bool]$rel.AddToPath
            PostInstall = $rel.PostInstall
            Group       = $Name
        }
    }
}

function Resolve-Groups([string[]]$Names) {
    if ($Names -contains 'all') { return $groupNames }
    return @($Names | Select-Object -Unique)
}

function Read-ExtraGroups {
    $extras = @($groupNames | Where-Object { $_ -ne 'base' })
    if (-not $extras.Count) { return @() }
    Write-Step 'Optional groups'
    for ($n = 0; $n -lt $extras.Count; $n++) {
        $count = @(Get-GroupPackages $extras[$n]).Count
        Write-Host ("   {0}. {1} ({2} apps)" -f ($n + 1), $extras[$n], $count)
    }
    $answer = Read-Host "`nGroups to install (e.g. 1,3 or all; Enter to finish)"
    if ($answer.Trim() -eq 'all') { return $extras }
    return @($answer -split '[,\s]+' | Where-Object { $_ -match '^\d+$' -and [int]$_ -ge 1 -and [int]$_ -le $extras.Count } |
        ForEach-Object { $extras[[int]$_ - 1] } | Select-Object -Unique)
}

if ($DryRun) {
    $checkGroups = if ($Group.Count) { Resolve-Groups $Group } else { $groupNames }
    $packages = @(foreach ($g in $checkGroups) { Get-GroupPackages $g })
    Write-Step "Dry run: confirming each package exists ($($checkGroups -join ', '))"
    $missing = @()
    foreach ($p in $packages) {
        if ($p.Source -eq 'github') {
            try {
                $a = Get-GitHubAsset $p
                Write-Host "   ok       $($p.Id) [$($p.Group)/github] $($a.Name)"
            } catch {
                Write-Host "   MISSING  $($p.Id) [$($p.Group)/github] $($_.Exception.Message)" -ForegroundColor Yellow; $missing += $p.Id
            }
            continue
        }
        & winget.exe show --id $p.Id --exact --source $p.Source --accept-source-agreements --disable-interactivity *> $null
        if ($LASTEXITCODE -eq 0) { Write-Host "   ok       $($p.Id) [$($p.Group)/$($p.Source)]" }
        else { Write-Host "   MISSING  $($p.Id) [$($p.Group)/$($p.Source)] $(Format-ExitCode $LASTEXITCODE)" -ForegroundColor Yellow; $missing += $p.Id }
    }
    Write-Host "`n$($packages.Count - $missing.Count) found, $($missing.Count) missing."
    if ($logFile) { Stop-Transcript | Out-Null }
    return
}

$installed = @(); $present = @(); $reboot = @(); $failed = @{}
$assocSet = 0; $assocMissing = @(); $defaultAppsPages = @()

# --- Default apps ---------------------------------------------------------------------------
$hkcr = [Microsoft.Win32.Registry]::ClassesRoot
$hklm = [Microsoft.Win32.Registry]::LocalMachine
$hkcu = [Microsoft.Win32.Registry]::CurrentUser

# What a ProgId launches: a Store app's AppUserModelID, else its default verb's command line.
function Get-ProgIdTarget([string]$ProgId) {
    $key = $hkcr.OpenSubKey($ProgId)
    if (-not $key) { return $null }
    try {
        $app = $key.OpenSubKey('Application')
        if ($app -and $app.GetValue('AppUserModelID')) { return [string]$app.GetValue('AppUserModelID') }
        $verb = 'open'
        $shell = $key.OpenSubKey('shell')
        if ($shell -and $shell.GetValue('')) { $verb = [string]$shell.GetValue('') }
        foreach ($v in $verb, 'open') {
            $cmd = $key.OpenSubKey("shell\$v\command")
            if ($cmd) { return [string]$cmd.GetValue('') }
        }
        return $null
    } finally { $key.Close() }
}

# Every registered app's declared Capabilities, as (Name, Scope, Path, root key).
function Get-RegisteredApps {
    foreach ($scope in @(@{ Name = 'Machine'; Root = $hklm }, @{ Name = 'User'; Root = $hkcu })) {
        $ra = $scope.Root.OpenSubKey('SOFTWARE\RegisteredApplications')
        if (-not $ra) { continue }
        foreach ($name in $ra.GetValueNames()) {
            [pscustomobject]@{ Name = $name; Scope = $scope.Name; Path = [string]$ra.GetValue($name); Root = $scope.Root }
        }
    }
}

function Get-ProgIdCandidates([string]$Type, $RegisteredApps) {
    $ids = New-Object System.Collections.Generic.List[string]
    $key = $hkcr.OpenSubKey($Type)
    if ($key) {
        if ($key.GetValue('')) { $ids.Add([string]$key.GetValue('')) }
        $owp = $key.OpenSubKey('OpenWithProgids')
        if ($owp) { foreach ($n in $owp.GetValueNames()) { if ($n) { $ids.Add($n) } } }
        $key.Close()
    }
    foreach ($app in $RegisteredApps) {
        foreach ($sub in 'FileAssociations', 'URLAssociations') {
            $caps = $app.Root.OpenSubKey("$($app.Path)\$sub")
            if ($caps -and $caps.GetValue($Type)) { $ids.Add([string]$caps.GetValue($Type)) }
        }
    }
    return @($ids | Select-Object -Unique)
}

function Resolve-ProgId([string]$Type, [string]$Match, $RegisteredApps) {
    foreach ($id in Get-ProgIdCandidates $Type $RegisteredApps) {
        if ($id -like '*_auto_file') { continue }   # Windows makes these from "Open with"; not the app's own
        $target = Get-ProgIdTarget $id
        if ($target -and $target -like "*$Match*") { return $id }
    }
    return $null
}

# The registered app whose web-link (or any) handler launches Match, for the Settings deep link.
function Find-RegisteredApp([string]$Match, $RegisteredApps) {
    foreach ($app in $RegisteredApps) {
        foreach ($sub in 'URLAssociations', 'FileAssociations') {
            $caps = $app.Root.OpenSubKey("$($app.Path)\$sub")
            if (-not $caps) { continue }
            foreach ($t in $caps.GetValueNames()) {
                $target = Get-ProgIdTarget ([string]$caps.GetValue($t))
                if ($target -and $target -like "*$Match*") { return $app }
            }
        }
    }
    return $null
}

# The signed-in user, even when UAC elevated with a different admin account.
function Get-ConsoleUserSid {
    try {
        $name = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($name) { return (New-Object Security.Principal.NTAccount $name).Translate([Security.Principal.SecurityIdentifier]).Value }
    } catch { }
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

# 7-Zip registers no ProgIds on install; create the 7-Zip.<ext> ones its Options > System page
# would, with icons from the ext:index table 7z.dll carries as string resource 100.
function Register-SevenZipProgIds([string[]]$Types) {
    $dir = $null
    foreach ($k in 'SOFTWARE\7-Zip-Zstandard', 'SOFTWARE\7-Zip') {
        $reg = $hklm.OpenSubKey($k)
        if ($reg -and $reg.GetValue('Path') -and (Test-Path -LiteralPath (Join-Path $reg.GetValue('Path') '7zFM.exe'))) { $dir = [string]$reg.GetValue('Path'); break }
    }
    if (-not $dir) { Write-Host '   7-Zip is not installed; skipping its ProgIds' -ForegroundColor Yellow; return }
    $fm = Join-Path $dir '7zFM.exe'
    $dll = Join-Path $dir '7z.dll'

    if (-not ('InstallApps.Res' -as [type])) {
        Add-Type -Namespace InstallApps -Name Res -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
[DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern int LoadString(IntPtr h, uint id, System.Text.StringBuilder buf, int max);
'@
    }
    $icons = @{}
    $h = [InstallApps.Res]::LoadLibraryEx($dll, [IntPtr]::Zero, 0x22)   # as datafile + image resource
    if ($h -ne [IntPtr]::Zero) {
        $sb = New-Object System.Text.StringBuilder 8192
        if ([InstallApps.Res]::LoadString($h, 100, $sb, $sb.Capacity) -gt 0) {
            foreach ($pair in $sb.ToString() -split '\s+') {
                $p = $pair -split ':'
                if ($p.Count -eq 2) { $icons[$p[0]] = $p[1] }
            }
        }
        [void][InstallApps.Res]::FreeLibrary($h)
    }

    foreach ($type in $Types) {
        $ext = $type.TrimStart('.')
        $progId = "7-Zip.$ext"
        $key = $hklm.CreateSubKey("SOFTWARE\Classes\$progId")
        $key.SetValue('', "$ext Archive")
        $icon = if ($icons.ContainsKey($ext)) { "$dll,$($icons[$ext])" } else { "$fm,0" }
        $key.CreateSubKey('DefaultIcon').SetValue('', $icon)
        $key.CreateSubKey('shell\open\command').SetValue('', "`"$fm`" `"%1`"")
        $key.Close()
        $owp = $hklm.CreateSubKey("SOFTWARE\Classes\$type\OpenWithProgids")
        $owp.SetValue($progId, [byte[]]@(), [Microsoft.Win32.RegistryValueKind]::None)
        $owp.Close()
    }
}

# Some apps only create their ProgIds when asked (ImageGlass 10: --ig-set-default-viewer).
# "{types}" in Arguments becomes the ";"-joined type list. A bare File name is looked up on PATH,
# then among Store app execution aliases.
function Invoke-RegisterCommand($Assoc) {
    $file = [string]$Assoc.RegisterCommand.File
    if (-not [IO.Path]::IsPathRooted($file)) {
        $cmd = Get-Command $file -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$file"
        $file = if ($cmd) { $cmd.Source } elseif (Test-Path -LiteralPath $alias) { $alias } else { $null }
    }
    if (-not $file) { Write-Host "   $($Assoc.App) is not installed; skipping its registration" -ForegroundColor Yellow; return }
    $arguments = ([string]$Assoc.RegisterCommand.Arguments).Replace('{types}', (@($Assoc.Types) -join ';'))
    Write-Host "   Registering $($Assoc.App) file types"
    $proc = Start-Process -FilePath $file -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0) { Write-Host "   $($Assoc.App) registration exited with $($proc.ExitCode)" -ForegroundColor Yellow }
}

function Set-GroupAssociations([string]$Name) {
    if ($NoAssociations) { return }
    $list = Get-Content -LiteralPath (Join-Path $AppsDir "$Name.json") -Raw | ConvertFrom-Json
    if (-not $list.Associations) { return }
    $assocScript = Join-Path $PSScriptRoot 'assoc.ps1'
    if (-not (Test-Path -LiteralPath $assocScript)) { Write-Warning "   assoc.ps1 not found next to this script; skipping default apps"; return }

    Write-Step "Setting default apps: $Name"
    try {
        foreach ($a in $list.Associations) {
            if ($a.CreateProgIds -eq '7-Zip') { Register-SevenZipProgIds $a.Types }
            if ($a.RegisterCommand) { Invoke-RegisterCommand $a }
        }
        $apps = @(Get-RegisteredApps)
        $pairs = @()
        foreach ($a in $list.Associations) {
            $found = 0; $missing = @()
            foreach ($type in $a.Types) {
                $progId = Resolve-ProgId $type $a.Match $apps
                if ($progId) { $pairs += "${type}:$progId"; $found++ } else { $missing += $type }
            }
            Write-Host "   $($a.App): $found of $(@($a.Types).Count) types"
            if ($missing.Count) {
                Write-Host "   $($a.App) has no handler for: $($missing -join ' ')" -ForegroundColor Yellow
                $script:assocMissing += "$($a.App): $($missing -join ' ')"
            }
            if ($a.DefaultAppsPage) {
                $reg = Find-RegisteredApp $a.Match $apps
                if ($reg) { $script:defaultAppsPages += $reg }
                else { $script:assocMissing += "$($a.App): not in Settings > Default apps" }
            }
        }
        if ($pairs.Count) {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $assocScript 'Placeholder' (Get-ConsoleUserSid) @pairs
            if ($LASTEXITCODE -ne 0) { throw "assoc.ps1 exited with $LASTEXITCODE" }
            $script:assocSet += $pairs.Count
        }
    } catch {
        Write-Host "   Default apps for $Name failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:assocMissing += "$Name group: $($_.Exception.Message)"
    }
}

function Install-Group([string]$Name) {
    $packages = @(Get-GroupPackages $Name)
    $queue = $packages
    foreach ($attempt in 1, 2) {
        if ($attempt -eq 2) {
            $retry = @($packages | Where-Object { $script:failed.ContainsKey($_.Id) })
            if (-not $retry.Count) { break }
            Write-Step "Retrying $($retry.Count) failed package(s) in $Name"
            $queue = $retry
            foreach ($p in $retry) { $script:failed.Remove($p.Id) }
        } else {
            Write-Step "Installing group: $Name ($($packages.Count) packages)"
        }
        $i = 0
        foreach ($p in $queue) {
            $i++
            Write-Host "`n[$Name $i/$($queue.Count)] $($p.Id)" -ForegroundColor White
            $code = Install-Package $p
            if ($code -eq 0)                               { $script:installed += $p.Id }
            elseif ($codeAlreadyInstalled -contains $code) { $script:present += $p.Id }
            elseif ($codeRebootToFinish -contains $code)   { $script:reboot += $p.Id }
            else {
                $script:failed[$p.Id] = Format-ExitCode $code
                Write-Host "   failed: $($script:failed[$p.Id])" -ForegroundColor Yellow
            }
        }
    }
}

if ($Group.Count) {
    $selected = Resolve-Groups $Group
    foreach ($g in $selected) { $null = @(Get-GroupPackages $g) }   # fail on a typo before installing anything
    foreach ($g in $selected) { Install-Group $g; Set-GroupAssociations $g }
} else {
    Install-Group 'base'
    Set-GroupAssociations 'base'
    foreach ($g in Read-ExtraGroups) { Install-Group $g; Set-GroupAssociations $g }
}

# Windows only lets the user pick the default browser; open the page with one "Set default" button.
foreach ($app in $defaultAppsPages | Sort-Object Name -Unique) {
    Write-Host "`n   Opening Settings > Default apps > $($app.Name): click 'Set default'." -ForegroundColor Cyan
    Start-Process "ms-settings:defaultapps?registeredApp$($app.Scope)=$([uri]::EscapeDataString($app.Name))"
}

Write-Step 'Summary'
Write-Host "   Installed:          $($installed.Count)"
Write-Host "   Already installed:  $($present.Count)"
if ($reboot.Count) { Write-Host "   Reboot to finish:   $($reboot -join ', ')" -ForegroundColor Yellow }
if ($failed.Count) {
    Write-Host "   Failed:             $($failed.Count)" -ForegroundColor Red
    foreach ($id in $failed.Keys | Sort-Object) { Write-Host "     $id  ($($failed[$id]))" -ForegroundColor Red }
} else {
    Write-Host '   Failed:             0' -ForegroundColor Green
}
if (-not $NoAssociations) {
    Write-Host "   Default app types:  $assocSet"
    foreach ($m in $assocMissing) { Write-Host "     not set: $m" -ForegroundColor Yellow }
}
if ($logFile) { Stop-Transcript | Out-Null; Write-Host "`nLog: $logFile" }
Read-Host "`nPress Enter to close"
