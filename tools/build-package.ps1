#Requires -Version 7
<#
.SYNOPSIS
    Stage src\ into a test package for tools\vmtest.ps1.

.DESCRIPTION
    CI packs src\* into an .apbx (7z, AME password) for AME Wizard. The VM harness drives the
    headless AME CLI instead, which takes an *extracted* playbook folder, so this script produces a
    plain zip of the same tree: src\* plus Executables\WinDebloatTool-Setup.exe (git-ignored, built
    only by CI). The installer comes from -ToolInstaller, else src\Executables, else the GitHub
    release named by -ToolRelease (cached under tools\cache\).

    Output: <OutDir>\playbook.zip and <OutDir>\build.json (commit, dirty flag, hashes).
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $PSScriptRoot '..\out\build'),
    [string]$ToolInstaller,
    [string]$ToolRelease = '26.10',
    [string]$Repo = 'sirmaestro/playbook'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$srcDir = Join-Path $repoRoot 'src'
$OutDir = [IO.Path]::GetFullPath($OutDir)

function Get-VmtToolInstaller {
    if ($ToolInstaller) {
        if (-not (Test-Path -LiteralPath $ToolInstaller)) { throw "ToolInstaller not found: $ToolInstaller" }
        return (Resolve-Path -LiteralPath $ToolInstaller).Path
    }
    $inSrc = Join-Path $srcDir 'Executables\WinDebloatTool-Setup.exe'
    if (Test-Path -LiteralPath $inSrc) { return $inSrc }

    # Downloaded binaries get their own directory (never next to scripts).
    $cacheDir = Join-Path $repoRoot "tools\cache\release-$ToolRelease"
    $cached = Join-Path $cacheDir 'WinDebloatTool-Setup.exe'
    if (-not (Test-Path -LiteralPath $cached)) {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        $url = "https://github.com/$Repo/releases/download/$ToolRelease/WinDebloatTool-Setup.exe"
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $cached
    }
    return $cached
}

$installer = Get-VmtToolInstaller
$stage = Join-Path $OutDir 'stage'
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

Copy-Item -Path (Join-Path $srcDir '*') -Destination $stage -Recurse -Force
# Transcripts INSTALL-APPS.ps1 leaves behind locally are not part of the playbook.
Get-ChildItem -LiteralPath (Join-Path $stage 'Executables') -Filter 'install-apps-*.log' -ErrorAction SilentlyContinue |
    Remove-Item -Force
Copy-Item -LiteralPath $installer -Destination (Join-Path $stage 'Executables\WinDebloatTool-Setup.exe') -Force

$zip = Join-Path $OutDir 'playbook.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal

$commit = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
$dirty = [bool](& git -C $repoRoot status --porcelain -- src 2>$null)
$info = [ordered]@{
    builtAt          = (Get-Date).ToString('o')
    commit           = $commit
    srcDirty         = $dirty
    package          = $zip
    packageSha256    = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
    toolInstaller    = $installer
    toolSha256       = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
}
$info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutDir 'build.json') -Encoding utf8
Write-Host "Built $zip ($($info.packageSha256)) from $commit$(if ($dirty) { ' + uncommitted src changes' })"
