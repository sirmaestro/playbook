# POSTCLEAN.ps1 - removes apps that Windows installs AFTER the playbook's own removal steps ran.
#
# Why: Windows Update / Edge Update / the inbox-app logon registration run in parallel with the apply and for a while
# after it. Teams (a newer MSTeams staged right before wdtool looked), the Copilot Win32 app (force-installed by Edge
# Update, not an appx) and StartExperiencesApp (re-registered per user from C:\Windows\InboxApps) all land after the
# early removal steps. See docs/references-learnings.md.
#
# Usage: POSTCLEAN.ps1 -Target Teams|Copilot|StartExperiences|FeedsPolicy [-Register]
#   no switch  : one removal pass
#   -Register  : one removal pass, then copy this script to %ProgramData%\WinDebloat\Post-Clean and register a SYSTEM
#                scheduled task that repeats the pass at startup/logon. The task deletes itself after 3 consecutive
#                runs that found nothing to remove (or after 20 runs).
# Keep this file ASCII-only (Windows PowerShell 5.1).
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Teams', 'Copilot', 'StartExperiences', 'FeedsPolicy')][string]$Target,
    [switch]$Register,
    [switch]$FromTask
)

$ErrorActionPreference = 'Continue'
$root = Join-Path $env:ProgramData 'WinDebloat\Post-Clean'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$logFile = Join-Path $root 'postclean.log'
$taskName = "WinDebloat PostClean - $Target"

function Write-Log([string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 's'), $Target, $Message
    Add-Content -LiteralPath $logFile -Value $line
    Write-Host $line
}

# Removes every installed/staged/provisioned package with one of the given names. Returns how many it found.
function Remove-AppxByName([string[]]$Names) {
    $found = 0
    foreach ($name in $Names) {
        foreach ($pkg in @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)) {
            $found++
            Write-Log "removing $($pkg.PackageFullName)"
            try { Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop }
            catch {
                Write-Log "  failed: $(($_.Exception.Message -split "`n")[0].Trim())"
                # Same removal path the playbook's appx steps use (the cmdlet is refused under some tokens).
                $wdtool = Join-Path $env:ProgramFiles 'WinDebloat Tool\wdtool.exe'
                if (Test-Path -LiteralPath $wdtool) {
                    Write-Log "  retrying with wdtool"
                    & $wdtool appx --all-users --remove $name 2>&1 | ForEach-Object { Write-Log "  wdtool: $_" }
                }
            }
        }
        foreach ($prov in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $name })) {
            $found++
            Write-Log "deprovisioning $($prov.PackageName)"
            try { Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null }
            catch { Write-Log "  failed: $($_.Exception.Message)" }
        }
    }
    return $found
}

# Copilot is an Edge Update product (Win32, Program Files (x86)\Microsoft\Copilot), so appx removal cannot see it.
function Remove-CopilotWin32 {
    $found = 0
    $copilotDir = "${env:ProgramFiles(x86)}\Microsoft\Copilot"
    $setups = @(Get-ChildItem -Path "$copilotDir\Application\*\Installer\copilot_setup.exe" -ErrorAction SilentlyContinue)
    if ($setups.Count -gt 0) {
        Get-Process -Name copilotapp, copilotapp_proxy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    foreach ($setup in $setups) {
        $found++
        Write-Log "uninstalling via $($setup.FullName)"
        $proc = Start-Process -FilePath $setup.FullName -ArgumentList '--uninstall --mscopilot --channel=stable --system-level --force-uninstall' -PassThru -WindowStyle Hidden
        if ($proc.WaitForExit(120000)) { Write-Log "  exit code $($proc.ExitCode)" }
        else { Write-Log '  timed out after 120 s'; $proc | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
    # An interrupted Edge Update install can leave only the undocked component (no setup.exe, no Uninstall entry).
    if (Test-Path -LiteralPath $copilotDir) {
        if ($setups.Count -eq 0) { $found++ }
        Write-Log "removing leftover folder $copilotDir"
        Remove-Item -LiteralPath $copilotDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $found
}

# FeedsPolicy is not an app: on builds where UCPD (UserChoice Protection Driver) is still loaded, HKLM writes to the
# Windows Feeds / Dsh policy keys are denied even for an administrator during the apply (seen on 26300.9711). UCPD is
# disabled by services.yml but only stops after a restart, so the values are written again here, after the first one.
$feedsPolicy = @(
    @{ Key = 'SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds' },
    @{ Key = 'SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests' }
)

function Test-FeedsPolicyOff {
    foreach ($v in $feedsPolicy) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($v.Key, $false)
        $cur = if ($key) { $key.GetValue($v.Name, $null) } else { $null }
        if ($key) { $key.Close() }
        if ($null -eq $cur -or [int]$cur -ne 0) { return $false }
    }
    return $true
}

# Writes the two values to 0 where they are not; returns how many needed writing.
function Set-FeedsPolicy {
    $found = 0
    foreach ($v in $feedsPolicy) {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($v.Key, $false)
        $cur = if ($key) { $key.GetValue($v.Name, $null) } else { $null }
        if ($key) { $key.Close() }
        if ($null -ne $cur -and [int]$cur -eq 0) { continue }
        $found++
        try {
            $w = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($v.Key)
            $w.SetValue($v.Name, 0, [Microsoft.Win32.RegistryValueKind]::DWord)
            $w.Close()
            Write-Log "set $($v.Key)\$($v.Name) = 0"
        } catch { Write-Log "  failed: $($v.Name): $($_.Exception.Message)" }
    }
    return $found
}

function Invoke-Pass {
    switch ($Target) {
        'Teams'            { return (Remove-AppxByName @('MSTeams', 'MicrosoftTeams')) }
        'StartExperiences' { return (Remove-AppxByName @('Microsoft.StartExperiencesApp')) }
        'Copilot'          { return ((Remove-CopilotWin32) + (Remove-AppxByName @('Microsoft.Copilot'))) }
        'FeedsPolicy'      { return (Set-FeedsPolicy) }
    }
}

# Get-AppxPackage -Name takes ONE string (an array throws), so check name by name.
function Test-AppxPresent([string[]]$Names) {
    foreach ($name in $Names) {
        if (Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Test-StillPresent {
    switch ($Target) {
        'Teams'            { return (Test-AppxPresent @('MSTeams', 'MicrosoftTeams')) }
        'StartExperiences' { return (Test-AppxPresent @('Microsoft.StartExperiencesApp')) }
        'Copilot'          { return ((Test-Path -Path "${env:ProgramFiles(x86)}\Microsoft\Copilot") -or (Test-AppxPresent @('Microsoft.Copilot'))) }
        'FeedsPolicy'      { return (-not (Test-FeedsPolicyOff)) }
    }
}

$found = Invoke-Pass
if ($found -eq 0) { Write-Log 'nothing to remove' }
elseif (Test-StillPresent) { Write-Log 'WARNING: still present after the removal pass' }
else { Write-Log "removed ($found item(s))" }

if ($Register) {
    $dest = Join-Path $root 'POSTCLEAN.ps1'
    if ($PSCommandPath -and ($PSCommandPath -ne $dest)) { Copy-Item -LiteralPath $PSCommandPath -Destination $dest -Force }
    $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Target {1} -FromTask' -f $dest, $Target
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $atStartup.Delay = 'PT3M'
    $atLogOn = New-ScheduledTaskTrigger -AtLogOn
    $atLogOn.Delay = 'PT5M'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($atStartup, $atLogOn) -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "registered scheduled task '$taskName'"
}

if ($FromTask) {
    $stateFile = Join-Path $root "$Target.state.json"
    $state = [pscustomobject]@{ Runs = 0; CleanRuns = 0 }
    if (Test-Path -LiteralPath $stateFile) {
        try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { }
    }
    $state.Runs = [int]$state.Runs + 1
    if ($found -eq 0) { $state.CleanRuns = [int]$state.CleanRuns + 1 } else { $state.CleanRuns = 0 }
    $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding ASCII
    if ($state.CleanRuns -ge 3 -or $state.Runs -ge 20) {
        Write-Log "done after $($state.Runs) run(s); removing scheduled task"
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
exit 0
