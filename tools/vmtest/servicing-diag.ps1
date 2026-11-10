<#
.SYNOPSIS
    Guest side of the servicing diagnostics (tools\vmtest.ps1, Get-VmtServicingDiag).

.DESCRIPTION
    Run when the first boot after an apply did not commit the Revision CBS removal packages. Gathers what
    explains a rollback into one zip: CBS.log, the newest CbsPersist logs, dism.log, the Revision packages'
    state, the Setup event log and the boot time. Read-only. Windows PowerShell 5.1: keep it ASCII.

    Prints  VMTEST_DIAG_BEGIN <json> VMTEST_DIAG_END  with the zip path, size and SHA-256.
#>
$ErrorActionPreference = 'Continue'
$dir = 'C:\vmtest\servicing-diag'
$zip = 'C:\vmtest\servicing-diag.zip'
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$files = @('C:\Windows\Logs\CBS\CBS.log', 'C:\Windows\Logs\DISM\dism.log')
$files += @(Get-ChildItem -LiteralPath 'C:\Windows\Logs\CBS' -Filter 'CbsPersist_*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 2 | ForEach-Object { $_.FullName })
foreach ($f in $files) {
    if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $dir -Force -ErrorAction SilentlyContinue }
}

try {
    Get-WindowsPackage -Online -ErrorAction Stop | Where-Object { $_.PackageName -match 'Revision' } |
        Select-Object PackageName, PackageState, InstallTime | Format-List | Out-String -Width 300 |
        Set-Content -LiteralPath (Join-Path $dir 'revision-packages.txt')
}
catch { "Get-WindowsPackage failed: $($_.Exception.Message)" | Set-Content -LiteralPath (Join-Path $dir 'revision-packages.txt') }

try {
    Get-WinEvent -FilterHashtable @{ LogName = 'Setup' } -MaxEvents 300 -ErrorAction Stop |
        ForEach-Object { '{0:o} [{1}] {2}' -f $_.TimeCreated, $_.Id, ($_.Message -replace '\s+', ' ') } |
        Set-Content -LiteralPath (Join-Path $dir 'setup-events.txt')
}
catch { "Setup event log unreadable: $($_.Exception.Message)" | Set-Content -LiteralPath (Join-Path $dir 'setup-events.txt') }

$os = Get-CimInstance Win32_OperatingSystem
("boot: {0:o}`r`nnow: {1:o}`r`nbuild: {2}" -f $os.LastBootUpTime, (Get-Date), $os.Version) | Set-Content -LiteralPath (Join-Path $dir 'boot.txt')

Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip -Force
$len = (Get-Item -LiteralPath $zip).Length
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
Write-Output 'VMTEST_DIAG_BEGIN'
Write-Output ((@{ zip = $zip; size = $len; sha256 = $hash } | ConvertTo-Json -Compress))
Write-Output 'VMTEST_DIAG_END'
