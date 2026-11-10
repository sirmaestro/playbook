# WEEKLY-UPDATE.ps1 - weekly "winget upgrade --all" with a log. Optional: the playbook only registers it when the
# "Update apps weekly" option is ticked (windebloat-weekly-app-updates).
#
# Usage:
#   WEEKLY-UPDATE.ps1 -Stage       only copy this script to %ProgramData%\WinDebloat\Weekly Update (the playbook always
#                                  does this, so `wdtool tweaks utilities weekly-app-updates enable` can register the task
#                                  later, whether or not the option was ticked).
#   WEEKLY-UPDATE.ps1 -Register    copy this script to %ProgramData%\WinDebloat\Weekly Update and register the scheduled
#                                  task "WinDebloat Weekly App Update" (Sundays 12:00, or at the next logon if the PC was
#                                  off) for the CURRENT user, elevated, so winget sees the apps INSTALL-APPS installed
#                                  for that user as well as machine-wide ones.
#   WEEKLY-UPDATE.ps1 -Unregister  remove the task (logs stay).
#   WEEKLY-UPDATE.ps1              one upgrade run now (what the task does).
#
# Logs: %ProgramData%\WinDebloat\Weekly Update\logs\winget-upgrade-<date>.log (newest 12 kept).
# Scope: source "winget" only (the open-source community repository), so Store apps are left to the Store. Packages
# you pinned (winget pin add) are skipped by winget itself. Packages with an unknown installed version are not touched.
# A run exits 1 only when it could not start (no network, no winget), which makes Task Scheduler retry it 3 times,
# 30 minutes apart; failed upgrades of single packages are logged, not retried.
# Keep this file ASCII-only (Windows PowerShell 5.1).
[CmdletBinding()]
param(
    [switch]$Stage,
    [switch]$Register,
    [switch]$Unregister
)

$ErrorActionPreference = 'Continue'
$root = Join-Path $env:ProgramData 'WinDebloat\Weekly Update'
$logDir = Join-Path $root 'logs'
$taskName = 'WinDebloat Weekly App Update'
$keepLogs = 12
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$logFile = Join-Path $logDir "winget-upgrade-$stamp.log"
$taskLog = Join-Path $root 'weekly-update.log'

function Write-Log([string]$Message, [string]$File = $logFile) {
    $line = '{0} {1}' -f (Get-Date -Format 's'), $Message
    Add-Content -LiteralPath $File -Value $line -Encoding UTF8
    Write-Host $line
}

if ($Stage) {
    $dest = Join-Path $root 'WEEKLY-UPDATE.ps1'
    if ($PSCommandPath -and ($PSCommandPath -ne $dest)) { Copy-Item -LiteralPath $PSCommandPath -Destination $dest -Force }
    if (-not (Test-Path -LiteralPath $dest)) { Write-Log 'ERROR: the script was not staged' $taskLog; exit 1 }
    Write-Log "staged $dest" $taskLog
    exit 0
}

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "unregistered scheduled task '$taskName'" $taskLog
    exit 0
}

if ($Register) {
    $dest = Join-Path $root 'WEEKLY-UPDATE.ps1'
    if ($PSCommandPath -and ($PSCommandPath -ne $dest)) { Copy-Item -LiteralPath $PSCommandPath -Destination $dest -Force }
    if (-not (Test-Path -LiteralPath $dest)) { Write-Log 'ERROR: the script was not copied; task not registered' $taskLog; exit 1 }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $dest
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '12:00'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 30)
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Log "registered scheduled task '$taskName' for $user (Sundays 12:00, logs in $logDir)" $taskLog
        exit 0
    }
    catch { Write-Log "ERROR: could not register the task: $($_.Exception.Message)" $taskLog; exit 1 }
}

# ---- one upgrade run
function Find-Winget {
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $hit = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps" -Filter 'winget.exe' -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

function Test-Network {
    for ($i = 0; $i -lt 12; $i++) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $ar = $c.BeginConnect('cdn.winget.microsoft.com', 443, $null, $null)
            $ok = $ar.AsyncWaitHandle.WaitOne(5000) -and $c.Connected
            $c.Close()
            if ($ok) { return $true }
        } catch { }
        Start-Sleep -Seconds 10
    }
    return $false
}

Write-Log "weekly winget upgrade starting as $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
$winget = Find-Winget
if (-not $winget) { Write-Log 'ERROR: winget.exe not found (install App Installer, or run Install Apps first)'; exit 1 }
if (-not (Test-Network)) { Write-Log 'ERROR: cdn.winget.microsoft.com is unreachable'; exit 1 }
Write-Log "winget: $winget ($(& $winget --version 2>&1))"

& $winget source update --name winget 2>&1 | Out-Null

$wingetArgs = @('upgrade', '--all', '--source', 'winget', '--silent', '--accept-package-agreements',
    '--accept-source-agreements', '--disable-interactivity')
Write-Log ('winget ' + ($wingetArgs -join ' '))
# winget redraws a spinner and a progress bar (block characters U+2580..U+259F, sizes, percent) with carriage returns:
# keep only lines that carry text.
$progressLine = '^[' + [char]0x2580 + '-' + [char]0x259F + '\s\d.%/KMGB]+$'
# winget writes UTF-8; without this the block characters arrive as mojibake in the log and the filter below misses them.
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
& $winget @wingetArgs 2>&1 | ForEach-Object {
    $t = ([string]$_).Trim()
    if ($t -and $t -notmatch '^[-\\|/]$' -and $t -notmatch $progressLine) { Add-Content -LiteralPath $logFile -Value $t -Encoding UTF8 }
}
$code = $LASTEXITCODE
# 0x8A15002B = nothing to upgrade
if ($code -eq 0 -or $code -eq -1978335189) { Write-Log "finished, exit code $code" }
else { Write-Log "finished WITH ERRORS, exit code $code (see the lines above; failed packages are tried again next week)" }

Get-ChildItem -LiteralPath $logDir -Filter 'winget-upgrade-*.log' -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending | Select-Object -Skip $keepLogs | Remove-Item -Force -ErrorAction SilentlyContinue
exit 0
