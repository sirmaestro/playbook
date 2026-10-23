<#
.SYNOPSIS
    Installs app groups from the Apps folder with winget, after updating winget to its latest release.

.DESCRIPTION
    Run once after the playbook has finished, while signed in and online.
    Each Apps\<group>.json is one use-case group in the `winget export` format, so
    `winget import Apps\<group>.json` also works. With no -Group, only the barebones "base"
    group is installed first; a menu then offers the other groups.
    A package may carry "InitialOverrideArguments" to replace the installer's own arguments.

    Apps not packaged in winget from their official source go in an optional top-level
    "GitHubReleases" list in the same group file (winget import ignores it):
      { "Name": "mpv", "Repo": "zhongfly/mpv-winbuild", "AssetPattern": "^mpv-x86_64-\\d{8}-git-[0-9a-f]+\\.7z$",
        "AddToPath": true, "PostInstall": { "File": "mpv.com", "Arguments": "--register" } }
    The latest release's .zip or .7z asset whose name ends with "Asset" (or matches the regex
    "AssetPattern") is checked against the SHA-256 digest GitHub publishes, extracted to
    Program Files\<Name>, and PostInstall runs from there.

    After a group installs, its optional top-level "Associations" list makes those apps the
    signed-in user's defaults: the class defaults through the playbook's assoc.ps1, then, once all
    groups are in, the user's own choice (UserChoiceLatest on Windows 11, UserChoice before it)
    through SFTA\SFTA.ps1, as Settings > Default apps would write it. An app with no
    RegisteredApplications entry of its own gets one listing its resolved ProgIds, so Settings
    still offers it:
      { "App": "LibreOffice", "Match": "\\LibreOffice\\program\\", "Types": [".odt", ".docx"] }
    For each type, the ProgId whose open command (or AppUserModelID, for Store apps) contains
    "Match" is picked from the ones the app registered. "CreateProgIds": "7-Zip" first creates
    the 7-Zip.<ext> ProgIds that 7-Zip's own Options dialog would, and
    "CreateProgIds": { "Exe": "%ProgramFiles%\\App\\App.exe" } creates <App>.<ext> ones for an app that
    registers none; "RegisterCommand" runs an
    app's own registration first ({ "File": "ImageGlass.exe", "Arguments": "--ig-set-default-viewer
    \"{types}\"" }) for apps that create ProgIds only on request.

    An optional top-level "AppSettings" list then adjusts installed apps (environment variables are
    expanded; an entry whose "When" path or BlockInbound program does not exist is skipped):
      { "App": "ImageGlass", "When": "%LOCALAPPDATA%\\Packages\\<family name>",
        "JsonFile": "%LOCALAPPDATA%\\...\\igconfig.json", "Values": { "QuickSetupVersion": 10 } }
    merges Values into the signed-in user's JSON config (created if missing), and
      { "App": "Stirling-PDF", "BlockInbound": "%ProgramFiles%\\...\\java.exe" }
    adds a Windows Firewall rule blocking inbound connections to that program on every network
    profile, so Windows does not ask whether to let it on the network (localhost is not filtered).

.PARAMETER Group
    Groups to install (file names in Apps without .json), e.g. -Group development,gaming,
    or "all". Skips the menu.

.PARAMETER DryRun
    Check winget and confirm every package ID exists, without installing anything.
    Checks every group unless -Group is given.

.PARAMETER NoAssociations
    Install only; leave default apps alone.

.PARAMETER KeepDesktopShortcuts
    Keep the desktop shortcuts that installers create. By default, shortcuts added to the user's or
    the Public desktop during the run are removed; ones that were already there are left alone.

.PARAMETER DownloadCache
    Testing aid (tools\vmtest.ps1): a folder of GitHub release assets. One whose SHA-256 matches the
    release's published digest is used instead of downloading it, and new downloads are added.
#>
param(
    [string[]]$Group,
    [string]$AppsDir = (Join-Path $PSScriptRoot 'Apps'),
    [version]$MinWingetVersion = '1.7.0',
    [switch]$DryRun,
    [switch]$NoAssociations,
    [switch]$KeepDesktopShortcuts,
    [string]$DownloadCache
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
    if ($KeepDesktopShortcuts) { $elevatedArgs += '-KeepDesktopShortcuts' }
    if ($DownloadCache) { $elevatedArgs += @('-DownloadCache', "`"$DownloadCache`"") }
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

# The playbook turns off Store auto-updates, so App Installer (winget) stays at the image's version.
function Get-LatestWingetVersion {
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
            -Headers @{ 'User-Agent' = 'INSTALL-APPS'; 'Accept' = 'application/vnd.github+json' } -UseBasicParsing
        if ($release.tag_name -match '(\d+\.\d+(\.\d+)?)') { return [version]$Matches[1] }
    } catch {
        Write-Host "   Could not look up the latest winget release: $($_.Exception.Message)" -ForegroundColor Yellow
    }
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
    if ($Package.AssetPattern) {
        $asset = @($release.assets | Where-Object { $_.name -match $Package.AssetPattern })
        $wanted = "matching '$($Package.AssetPattern)'"
    } else {
        $asset = @($release.assets | Where-Object { $_.name -like "*$($Package.Asset)" })
        $wanted = "ending in '$($Package.Asset)'"
    }
    if ($asset.Count -ne 1) { throw "expected one asset $wanted in $($release.tag_name), found $($asset.Count)" }
    if ($asset[0].digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "$($asset[0].name) has no SHA-256 digest to verify against" }
    [pscustomobject]@{
        Tag    = $release.tag_name
        Name   = $asset[0].name
        Url    = $asset[0].browser_download_url
        Sha256 = $asset[0].digest.Substring(7)
    }
}

# Downloads a Get-GitHubAsset result into Dir and checks it against the release's SHA-256 digest.
# With -DownloadCache, a cached copy with that digest is used instead, and new downloads are kept.
function Save-GitHubAsset($Asset, [string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $file = Join-Path $Dir $Asset.Name
    $cached = if ($DownloadCache) { Join-Path $DownloadCache $Asset.Name } else { $null }
    $fromCache = $cached -and (Test-Path -LiteralPath $cached) -and
        (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Asset.Sha256
    if ($fromCache) {
        Write-Host "   Using cached $($Asset.Name) ($($Asset.Tag))"
        Copy-Item -LiteralPath $cached -Destination $file
    } else {
        Write-Host "   Downloading $($Asset.Name) ($($Asset.Tag))"
        # Windows PowerShell's progress bar slows Invoke-WebRequest downloads many times over.
        $progress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Asset.Url -OutFile $file -UseBasicParsing } finally { $ProgressPreference = $progress }
    }
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $Asset.Sha256) { throw "SHA-256 mismatch for $($Asset.Name): got $hash, release lists $($Asset.Sha256)" }
    if ($cached -and -not $fromCache) {
        New-Item -ItemType Directory -Force -Path $DownloadCache | Out-Null
        Copy-Item -LiteralPath $file -Destination $cached -Force
    }
    return $file
}

# Installs the latest App Installer (winget) from winget-cli's GitHub release, digest-verified, with
# the framework packages it needs for this CPU. Registers it for the user running this script.
function Update-Winget {
    $work = Join-Path $env:TEMP ("install-apps-" + [guid]::NewGuid())
    try {
        $repo = 'microsoft/winget-cli'
        $bundle = Save-GitHubAsset (Get-GitHubAsset ([pscustomobject]@{ Repo = $repo; Asset = '.msixbundle' })) $work
        $depsZip = Save-GitHubAsset (Get-GitHubAsset ([pscustomobject]@{ Repo = $repo; Asset = 'DesktopAppInstaller_Dependencies.zip' })) $work
        $deps = Join-Path $work 'deps'
        Expand-Archive -LiteralPath $depsZip -DestinationPath $deps -Force
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'x64' } }
        $depFiles = @(Get-ChildItem -LiteralPath $deps -Recurse -File |
            Where-Object { $_.Extension -in '.appx', '.msix' -and $_.FullName -match "[\\_]$arch[\\_.]" } | ForEach-Object { $_.FullName })
        Write-Host "   Installing App Installer with $($depFiles.Count) $arch framework package(s)"
        Add-AppxPackage -Path $bundle -DependencyPath $depFiles -ForceApplicationShutdown
        return $true
    } catch {
        Write-Warning "   App Installer update failed: $($_.Exception.Message)"
        return $false
    } finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# .zip through Expand-Archive; anything else (.7z) through Windows' tar.exe (libarchive), else 7-Zip.
function Expand-AnyArchive([string]$Archive, [string]$Destination) {
    if ([IO.Path]::GetExtension($Archive) -eq '.zip') { Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force; return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    & "$env:SystemRoot\System32\tar.exe" -xf $Archive -C $Destination
    if ($LASTEXITCODE -eq 0) { return }
    $sevenZip = @('7-Zip-Zstandard', '7-Zip') | ForEach-Object { Join-Path $env:ProgramFiles "$_\7z.exe" } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $sevenZip) { throw "tar.exe could not extract $(Split-Path $Archive -Leaf) and 7-Zip is not installed" }
    & $sevenZip x $Archive "-o$Destination" -y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "7-Zip could not extract $(Split-Path $Archive -Leaf) (exit $LASTEXITCODE)" }
}

function Expand-Flat([string]$Zip, [string]$Destination) {
    Expand-AnyArchive $Zip $Destination
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
        $zip = Save-GitHubAsset $asset $work
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
    # Out-Host: winget's console output would otherwise become part of this function's return value.
    & winget.exe @wingetArgs | Out-Host
    return $LASTEXITCODE
}

# 1. Network
Write-Step 'Waiting for winget download server'
if (-not (Wait-Network)) { throw 'cdn.winget.microsoft.com is unreachable. Check the network connection and run this again.' }

# 2-3. winget present and up to date
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
$latest = Get-LatestWingetVersion
if (-not $version -or $version -lt $MinWingetVersion -or ($latest -and $version -lt $latest)) {
    $target = if ($latest) { $latest } else { $MinWingetVersion }
    if ($DryRun) {
        Write-Warning "   winget $version is missing or older than $target; a real run would update it."
    } else {
        if ($version) { Write-Host "   winget $version is older than $target; updating..." }
        # Repair-WinGetPackageManager needs NuGet and PowerShell Gallery, which a fresh Windows
        # PowerShell 5.1 often cannot reach; it is the fallback.
        if (-not (Update-Winget)) { Repair-Winget }
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
            Id           = $rel.Name
            Source       = 'github'
            Repo         = $rel.Repo
            Asset        = $rel.Asset
            AssetPattern = $rel.AssetPattern
            AddToPath    = [bool]$rel.AddToPath
            PostInstall  = $rel.PostInstall
            Group        = $Name
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
$assocSet = 0; $assocMissing = @(); $userDefaults = @()

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
# Packaged apps' AppX<hash> entries are skipped: Settings opens its main page for those, not the app's.
function Find-RegisteredApp([string]$Match, $RegisteredApps) {
    foreach ($app in $RegisteredApps) {
        if ($app.Name -like 'AppX*') { continue }
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

# Apps that register no ProgIds at all (Subtitle Edit 5): create <App>.<ext> ones that open the
# file with CreateProgIds.Exe (environment variables expanded), as the app's own installer would.
function Register-AppProgIds($Assoc) {
    $exe = [Environment]::ExpandEnvironmentVariables([string]$Assoc.CreateProgIds.Exe)
    if (-not (Test-Path -LiteralPath $exe)) { Write-Host "   $($Assoc.App) is not installed at $exe; skipping its ProgIds" -ForegroundColor Yellow; return }
    $prefix = $Assoc.App -replace '[^A-Za-z0-9]', ''
    foreach ($type in $Assoc.Types) {
        $ext = $type.TrimStart('.')
        $progId = "$prefix.$ext"
        $key = $hklm.CreateSubKey("SOFTWARE\Classes\$progId")
        $key.SetValue('', "$($Assoc.App) $ext file")
        $key.CreateSubKey('DefaultIcon').SetValue('', "$exe,0")
        $key.CreateSubKey('shell\open\command').SetValue('', "`"$exe`" `"%1`"")
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

# Settings > Default apps lists only apps in RegisteredApplications. For an app that registers none
# (7-Zip) or points at a Capabilities key it never wrote (Subtitle Edit 5), register one here with
# the ProgIds resolved for it, so its page offers those types.
function Register-AppCapabilities([string]$App, [string[]]$Pairs) {
    $path = "SOFTWARE\WinDebloat\InstallApps\$($App -replace '[^A-Za-z0-9]', '')\Capabilities"
    $caps = $hklm.CreateSubKey($path)
    $caps.SetValue('ApplicationName', $App)
    $caps.SetValue('ApplicationDescription', "$App (registered by INSTALL-APPS)")
    foreach ($pair in $Pairs) {
        $i = $pair.LastIndexOf(':')
        $type = $pair.Substring(0, $i)
        $sub = if ($type.StartsWith('.')) { 'FileAssociations' } else { 'URLAssociations' }
        $k = $caps.CreateSubKey($sub); $k.SetValue($type, $pair.Substring($i + 1)); $k.Close()
    }
    $caps.Close()
    $ra = $hklm.CreateSubKey('SOFTWARE\RegisteredApplications'); $ra.SetValue($App, $path); $ra.Close()
    return [pscustomobject]@{ Name = $App; Scope = 'Machine'; Path = $path; Root = $hklm }
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
            elseif ($a.CreateProgIds.Exe) { Register-AppProgIds $a }
            if ($a.RegisterCommand) { Invoke-RegisterCommand $a }
        }
        $apps = @(Get-RegisteredApps)
        $pairs = @()
        foreach ($a in $list.Associations) {
            $found = 0; $missing = @(); $appPairs = @()
            foreach ($type in $a.Types) {
                $progId = Resolve-ProgId $type $a.Match $apps
                if ($progId) { $appPairs += "${type}:$progId"; $found++ } else { $missing += $type }
            }
            $pairs += $appPairs
            Write-Host "   $($a.App): $found of $(@($a.Types).Count) types"
            if ($missing.Count) {
                Write-Host "   $($a.App) has no handler for: $($missing -join ' ')" -ForegroundColor Yellow
                $script:assocMissing += "$($a.App): $($missing -join ' ')"
            }
            if (-not $appPairs.Count) { continue }
            if (-not (Find-RegisteredApp $a.Match $apps)) { $null = Register-AppCapabilities $a.App $appPairs }
            $script:userDefaults += [pscustomobject]@{ App = $a.App; Pairs = $appPairs }
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

function Set-GroupAppSettings([string]$Name) {
    $list = Get-Content -LiteralPath (Join-Path $AppsDir "$Name.json") -Raw | ConvertFrom-Json
    if (-not $list.AppSettings) { return }
    Write-Step "Adjusting apps: $Name"
    foreach ($s in $list.AppSettings) {
        try {
            if ($s.When -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables([string]$s.When)))) {
                Write-Host "   $($s.App) is not installed; skipping its settings"
                continue
            }
            if ($s.JsonFile) {
                $file = [Environment]::ExpandEnvironmentVariables([string]$s.JsonFile)
                $config = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } else { New-Object psobject }
                foreach ($p in $s.Values.PSObject.Properties) { $config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
                $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file)
                [IO.File]::WriteAllText($file, ($config | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
                Write-Host "   $($s.App): set $(@($s.Values.PSObject.Properties.Name) -join ', ') in $(Split-Path -Leaf $file)"
            }
            if ($s.BlockInbound) {
                $exe = [Environment]::ExpandEnvironmentVariables([string]$s.BlockInbound)
                if (-not (Test-Path -LiteralPath $exe)) { Write-Host "   $($s.App) is not installed at $exe; skipping its firewall rule"; continue }
                $rule = "WinDebloat-InstallApps-$($s.App -replace '[^A-Za-z0-9]', '')-BlockInbound"
                Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
                $null = New-NetFirewallRule -Name $rule -DisplayName "$($s.App) - block inbound (Install Apps)" -Direction Inbound -Action Block -Profile Any -Program $exe
                Write-Host "   $($s.App): inbound connections to $(Split-Path -Leaf $exe) blocked"
            }
        } catch {
            Write-Host "   $($s.App) settings failed: $($_.Exception.Message)" -ForegroundColor Yellow
        }
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

# Installers drop shortcuts on the user's and the Public desktop; note what is there now so only
# the ones added by this run are removed afterwards.
$desktops = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory')) | Where-Object { $_ }
function Get-DesktopShortcuts {
    @(Get-ChildItem -LiteralPath $desktops -File -Force -ErrorAction SilentlyContinue |
        Where-Object { '.lnk', '.url' -contains $_.Extension } | ForEach-Object { $_.FullName })
}
$shortcutsBefore = Get-DesktopShortcuts

if ($Group.Count) {
    $selected = Resolve-Groups $Group
    foreach ($g in $selected) { $null = @(Get-GroupPackages $g) }   # fail on a typo before installing anything
    foreach ($g in $selected) { Install-Group $g; Set-GroupAppSettings $g; Set-GroupAssociations $g }
} else {
    Install-Group 'base'
    Set-GroupAppSettings 'base'
    Set-GroupAssociations 'base'
    foreach ($g in Read-ExtraGroups) { Install-Group $g; Set-GroupAppSettings $g; Set-GroupAssociations $g }
}

$shortcutsRemoved = @()
if (-not $KeepDesktopShortcuts) {
    foreach ($s in Get-DesktopShortcuts) {
        if ($shortcutsBefore -contains $s) { continue }
        try { Remove-Item -LiteralPath $s -Force; $shortcutsRemoved += Split-Path $s -Leaf }
        catch { Write-Warning "   Could not remove desktop shortcut ${s}: $($_.Exception.Message)" }
    }
}

# Every app Windows knows can open Type: the class default, OpenWithProgids (machine, user classes
# and the user's FileExts list), OpenWithList and each registered app's Capabilities.
function Get-TypeHandlers([string]$Type, $RegisteredApps) {
    $ids = @(Get-ProgIdCandidates $Type $RegisteredApps)
    $owl = $hkcr.OpenSubKey("$Type\OpenWithList")
    if ($owl) { $ids += $owl.GetSubKeyNames(); $owl.Close() }
    $owp = $hkcu.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\$Type\OpenWithProgids")
    if ($owp) { $ids += $owp.GetValueNames(); $owp.Close() }
    @($ids | Where-Object { $_ } | Select-Object -Unique)
}

# Windows 11 (26xxx) opens a type with the user's choice in UserChoiceLatest, whose salted hash
# Settings writes; Windows pre-sets its inbox apps there at first sign-in, and that choice outlives
# removing them. SFTA.ps1 (PS-SFTA, MIT) computes the same hash (and the classic UserChoice for older
# builds) after checking that it reproduces the hashes already on this machine. Windows still asks
# "Select an app" for a type while any app that can open it has not been announced to the user, so
# each handler also gets its ApplicationAssociationToasts entry, as Windows writes once it has asked.
$defaultsSet = 0; $defaultsTotal = 0; $typesLeft = @(); $defaultsBlocked = $null
function Set-UserDefaults {
    $todo = @(foreach ($d in $userDefaults) {
        foreach ($pair in $d.Pairs) { $type, $progId = $pair -split ':', 2; [pscustomobject]@{ App = $d.App; Type = $type; ProgId = $progId } }
    })
    if (-not $todo.Count) { return }
    Write-Step 'Default apps'
    $script:defaultsTotal = $todo.Count
    $sfta = Join-Path $PSScriptRoot 'SFTA\SFTA.ps1'
    $blocked = $null
    if ((Get-ConsoleUserSid) -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        $blocked = 'the installer was elevated as a different user than the one signed in'
    } elseif (-not (Test-Path -LiteralPath $sfta)) {
        $blocked = 'SFTA\SFTA.ps1 is missing next to this script'
    } else {
        try {
            . $sfta
            $plan = Get-UclWritePlan
            if ($plan.Action -eq 'refuse') { $blocked = $plan.Reason }
            elseif ((Test-UclSelfCheck -Quiet) -eq 'mismatch') { $blocked = 'this Windows build hashes default apps in a way SFTA.ps1 does not know' }
        } catch { $blocked = "SFTA.ps1 could not load: $($_.Exception.Message)" }
    }
    if ($blocked) { Write-Host "   Cannot set default apps: $blocked" -ForegroundColor Yellow; $script:defaultsBlocked = $blocked }

    $apps = @(Get-RegisteredApps)
    $toasts = $hkcu.CreateSubKey('Software\Microsoft\Windows\CurrentVersion\ApplicationAssociationToasts')
    try {
        foreach ($app in @($todo | Group-Object App)) {
            $left = @()
            foreach ($d in $app.Group) {
                if (-not $blocked) {
                    try {
                        $null = Set-FTA -ProgId $d.ProgId -Extension $d.Type -SkipSelfCheck
                        foreach ($id in Get-TypeHandlers $d.Type $apps) {
                            if ($null -eq $toasts.GetValue("${id}_$($d.Type)")) { $toasts.SetValue("${id}_$($d.Type)", 0, [Microsoft.Win32.RegistryValueKind]::DWord) }
                        }
                        $script:defaultsSet++
                        continue
                    } catch { Write-Host "   $($app.Name) $($d.Type): $($_.Exception.Message)" -ForegroundColor Yellow }
                }
                $left += $d.Type
            }
            Write-Host "   $($app.Name): default for $($app.Count - $left.Count) of $($app.Count) types"
            if ($left.Count) { $script:typesLeft += "$($app.Name): $($left -join ' ')" }
        }
    } finally { $toasts.Close() }
}
if (-not $NoAssociations) { Set-UserDefaults }

Write-Step 'Summary'
Write-Host "   Installed:          $($installed.Count)"
Write-Host "   Already installed:  $($present.Count)"
if ($shortcutsRemoved.Count) { Write-Host "   Desktop shortcuts:  removed $($shortcutsRemoved -join ', ')" }
if ($reboot.Count) { Write-Host "   Reboot to finish:   $($reboot -join ', ')" -ForegroundColor Yellow }
if ($failed.Count) {
    Write-Host "   Failed:             $($failed.Count)" -ForegroundColor Red
    foreach ($id in $failed.Keys | Sort-Object) { Write-Host "     $id  ($($failed[$id]))" -ForegroundColor Red }
} else {
    Write-Host '   Failed:             0' -ForegroundColor Green
}
if (-not $NoAssociations) {
    Write-Host "   Default app types:  $defaultsSet of $defaultsTotal set"
    if ($defaultsBlocked) { Write-Host "     not set because $defaultsBlocked" -ForegroundColor Yellow }
    foreach ($m in $typesLeft) { Write-Host "     not set: $m (set these in Settings > Default apps)" -ForegroundColor Yellow }
    foreach ($m in $assocMissing) { Write-Host "     no handler: $m" -ForegroundColor Yellow }
}
if ($logFile) { Stop-Transcript | Out-Null; Write-Host "`nLog: $logFile" }
Read-Host "`nPress Enter to close"
