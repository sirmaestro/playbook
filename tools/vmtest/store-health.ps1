<#
.SYNOPSIS
    Guest side of the component-store canary (tools\vmtest.ps1, Invoke-VmtStoreHealth).

.DESCRIPTION
    Runs  DISM /Online /Cleanup-Image /ScanHealth  and reports whether the component store is clean. The playbook
    supersedes components with the CBS removal cabs (38655.* versions); AtlasOS and our own VM runs
    (docs/atlas-comparison.md 8.1) show a later component cleanup can leave such a store "repairable" with no way
    back. A normal apply must leave it clean, so any other result is a regression worth seeing in every run.
    ScanHealth only reads: it changes nothing. Takes a few minutes. Windows PowerShell 5.1: keep it ASCII.

    Prints  VMTEST_STOREHEALTH_BEGIN <json> VMTEST_STOREHEALTH_END  with status clean | repairable |
    not-repairable | unknown, the DISM exit code, its last lines and the duration.
#>
$ErrorActionPreference = 'Continue'
$sw = [Diagnostics.Stopwatch]::StartNew()
$lines = @(& "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image /ScanHealth /NoRestart 2>&1 | ForEach-Object { [string]$_ })
$code = $LASTEXITCODE
$sw.Stop()
$text = ($lines -join "`n")

$status = 'unknown'
if ($text -match '(?i)no component store corruption detected') { $status = 'clean' }
elseif ($text -match '(?i)not repairable|cannot be repaired|unrepairable') { $status = 'not-repairable' }
elseif ($text -match '(?i)component store is repairable') { $status = 'repairable' }

$tail = @($lines | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\[[= ]*[\d.]*%?[= ]*\]$' } | Select-Object -Last 6)
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
$build = if ($cv) { '{0}.{1}' -f $cv.CurrentBuild, $cv.UBR } else { [Environment]::OSVersion.Version.ToString() }   # OSVersion reports x.0 without a manifest
$out = [ordered]@{
    status = $status; exitCode = $code; durationSec = [int]$sw.Elapsed.TotalSeconds
    build = $build; output = $tail
}
Write-Output 'VMTEST_STOREHEALTH_BEGIN'
Write-Output ($out | ConvertTo-Json -Depth 4 -Compress)
Write-Output 'VMTEST_STOREHEALTH_END'
