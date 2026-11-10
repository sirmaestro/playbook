#Requires -Version 7
<#
.SYNOPSIS
    Apply the playbook to the Hyper-V test VM and summarise the result as JSON.

.DESCRIPTION
    1. Restores the -Snapshot checkpoint (VM Off) and starts the VM.
    2. Waits for PowerShell Direct and the desktop shell by probing them (no fixed sleeps).
    3. Copies the guest agent, the AME CLI and the package in over PowerShell Direct, and
       verifies each file's SHA256 inside the guest.
    4. The guest agent elevates itself and runs the AME CLI (TrustedUninstaller.CLI, AME Wizard's
       headless core) from a scheduled task it registers (RunLevel Highest, interactive user).
    5. Pulls every log back (CLI Output.txt/Log.yml, job stdout, ProgramData\AME\Logs).
    6. Parses them into <OutDir>\summary.json: applied / failed (with error) / skipped actions.
    7. Optionally runs -RevertScript under a timeout and reports whether it hung.
    8. With -AppsGroups, reboots the guest (as AME does) and runs the package's INSTALL-APPS.ps1
       for those groups ("all", "base", ...); needs guest network. -AppsOnly does just this step
       on a VM that is already applied and running (e.g. after -KeepRunning).
    9. Exits 0 only when nothing failed: 1 = playbook/revert/app failures, 2 = harness or VM error.

    With -Layers, finished stages are cached as offline checkpoints and reused, like image layers:
      L1 vmtest-L1-<key>  the applied playbook, taken by shutting the guest down instead of the
                          post-apply reboot (so a restore replays that first boot). Key: base snapshot,
                          AME CLI, options, and every package file except the installer and Apps\*.json.
      L2 vmtest-L2-<key>  L1 plus the -AppsGroups installed. Key: L1, the groups and Apps\*.json.
                          Expires after -AppsLayerMaxAgeHours (winget content drifts).
    A hit restores the layer, copies the current INSTALL-APPS files in (as start.yml does), reuses
    the apply verdict recorded when the layer was built, and runs only what is left. -FreshApps skips
    L2 (installer install-logic changes), -RebuildLayers ignores hits, -ClearLayers deletes them all.
    Records live in out\vmtest\layers\<name>.json. A change is only "done" after an uncached run.

    Only PowerShell Direct drives the guest (VMBus: no integration software or guest network needed,
    but the host user must be in the Hyper-V Administrators group; an elevated shell is not required).
    No keyboard injection. The guest token is already High integrity, so guest-agent.ps1 runs as is.
    Hang detection reads the VM's virtual-disk performance counters. See AGENTS.md, "VM testing".
    A separate watchdog process (tools\vmtest\watchdog.ps1, off with -NoWatchdog) stops a run that stops
    making progress, and leaves watchdog.log / watchdog-stuck.json and a stub summary.json behind.

.EXAMPLE
    $env:VMTEST_GUEST_PASSWORD = '...'; pwsh tools\vmtest.ps1 -Build
.EXAMPLE
    pwsh tools\vmtest.ps1 -ParseOnly out\vmtest\20261021-140000
#>
[CmdletBinding()]
param(
    [string]$VMName = 'windowstest-hv',
    # Base checkpoint: Off, Defender Tamper Protection disabled by hand, UAC prompts off, auto-logon.
    [string]$Snapshot = 'clean-defender-off-UAC-off',
    [string]$GuestUser = $(if ($env:VMTEST_GUEST_USER) { $env:VMTEST_GUEST_USER } else { 'admin' }),
    [string]$GuestPassword = $env:VMTEST_GUEST_PASSWORD,
    [string]$Package,
    [switch]$Build,
    [string[]]$Options,
    [string]$CliZip,
    [string]$RevertScript,
    [int]$BootTimeoutSec = 600,
    # The first restart after the playbook can finish queued servicing work; it has taken >10 min.
    [int]$RebootTimeoutSec = 2400,
    [int]$ApplyTimeoutMin = 120,
    [int]$RevertTimeoutMin = 30,
    [int]$PollSec = 15,
    [string]$OutDir,
    [switch]$KeepRunning,
    [switch]$NoDefenderRemediation,
    [string[]]$AppsGroups,
    [int]$AppsTimeoutMin = 240,
    [switch]$AppsOnly,
    [switch]$Layers,
    [switch]$FreshApps,
    [switch]$RebuildLayers,
    [switch]$ClearLayers,
    [int]$AppsLayerMaxAgeHours = 24,
    [int]$KeepLayers = 1,
    [switch]$CacheDownloads,
    # Skip the component-store canary (DISM /ScanHealth, a few minutes) at the end of the run.
    [switch]$NoStoreHealth,
    # A guest that is working or rebooting always touches its disk: no virtual-disk I/O this long = hung.
    [int]$StallSec = 360,
    # Out-of-process watchdog (tools\vmtest\watchdog.ps1): stops the run when harness.log makes no progress this long
    # and the VM is idle, or the step has not declared more patience. -NoWatchdog turns it off.
    [switch]$NoWatchdog,
    [int]$WatchdogQuietSec = 900,
    [string]$ParseOnly
)

$ErrorActionPreference = 'Stop'
# Through pwsh -File, "-AppsGroups a,b" arrives as one string.
$AppsGroups = @($AppsGroups | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$agentLocal = Join-Path $PSScriptRoot 'vmtest\guest-agent.ps1'
$amelog = Join-Path $PSScriptRoot 'vmtest\amelog.py'
$endStateCheck = Join-Path $PSScriptRoot 'vmtest\endstate-check.ps1'
$endStateKnown = Join-Path $PSScriptRoot 'vmtest\endstate-known.json'
$servicingDiag = Join-Path $PSScriptRoot 'vmtest\servicing-diag.ps1'
$storeHealthScript = Join-Path $PSScriptRoot 'vmtest\store-health.ps1'
$guestIn = 'C:\vmtest\in'
$guestPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$layerDir = Join-Path $repoRoot 'out\vmtest\layers'
$dlCacheHost = Join-Path $repoRoot 'tools\cache\downloads'
$dlCacheGuest = 'C:\vmtest\dl'
# Package files INSTALL-APPS runs from; start.yml copies them to ProgramData, so they are left out
# of the L1 key and copied fresh into a restored layer (guest-agent SyncApps). They key L2 instead: a changed
# installer must not hit an L2 whose apps are already installed, because that run would test none of its code.
# Executables\assoc.ps1 is not here on purpose: the playbook's FILEASSOC.cmd runs it during the apply too.
$installerFiles = @('Executables/INSTALL-APPS.cmd', 'Executables/INSTALL-APPS.ps1')
$appsListPrefix = 'Executables/Apps/'
$sftaPrefix = 'Executables/SFTA/'   # only the installer uses it (start.yml copies it next to INSTALL-APPS.ps1)
$isInstallerInput = { param($p) $installerFiles -contains $p -or $p.StartsWith($appsListPrefix) -or $p.StartsWith($sftaPrefix) }

# Pinned AME CLI (Ameliorated-LLC/trusted-uninstaller-cli release 0.8.4, CLI-Standalone.zip).
$cliRelease = '0.8.4'
$cliUrl = "https://github.com/Ameliorated-LLC/trusted-uninstaller-cli/releases/download/$cliRelease/CLI-Standalone.zip"
$cliSha256 = '70E4946B52C9384CA88730C0DD25646DEFC63AFFDEF7ACADD69CB6317F21825A'

if (-not $OutDir) {
    $base = if ($ParseOnly) { $ParseOnly } else { Join-Path $repoRoot ('out\vmtest\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    $OutDir = $base
}
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$harnessLog = Join-Path $OutDir 'harness.log'

$script:report = [ordered]@{
    vm = $VMName; snapshot = $Snapshot; startedAt = (Get-Date).ToString('o')
    package = $null; options = @(); precheck = $null
    apply = [ordered]@{ status = 'not-run' }
    tweaks = $null
    revert = [ordered]@{ status = 'not-run'; reason = 'no -RevertScript given (the playbook has no revert path yet)' }
    apps = [ordered]@{ status = 'not-run' }
    endState = $null
    liveState = [ordered]@{ status = 'not-run' }
    storeHealth = [ordered]@{ status = 'not-run' }
    provenance = $null
    phases = @()
    layers = [ordered]@{ enabled = [bool]$Layers; startFrom = 'base'; created = @() }
    hangs = @()
    harnessErrors = @()
    result = $null
}

$script:patienceFile = Join-Path $OutDir 'watchdog.patience'

function Write-VmtLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -LiteralPath $harnessLog -Value $line
    # Any log line is progress, and ends the patience a step declared (see Set-VmtPatience).
    Remove-Item -LiteralPath $script:patienceFile -Force -ErrorAction SilentlyContinue
}

function Set-VmtPatience {
    # Tell the watchdog the current step may stay silent (no log line) for up to $Sec seconds, e.g. a reboot wait.
    # The step's next Write-VmtLog line cancels it, so a step that logs when it finishes needs no cleanup.
    param([int]$Sec)
    try { [IO.File]::WriteAllText($script:patienceFile, [string][DateTimeOffset]::UtcNow.AddSeconds($Sec).ToUnixTimeSeconds()) } catch { }
}

function Start-VmtWatchdog {
    if ($NoWatchdog) { Write-VmtLog 'Watchdog disabled (-NoWatchdog)'; return }
    # A stale verdict from a reused -OutDir would hide the watchdog's own.
    foreach ($stale in 'summary.json', 'watchdog-stuck.json', 'watchdog.log', 'watchdog.patience') { Remove-Item -LiteralPath (Join-Path $OutDir $stale) -Force -ErrorAction SilentlyContinue }
    $wd = Join-Path $PSScriptRoot 'vmtest\watchdog.ps1'
    $wdArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$wd`"", '-HarnessPid', $PID, '-OutDir', "`"$OutDir`"",
        '-VMName', "`"$VMName`"", '-QuietSec', $WatchdogQuietSec)
    $p = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $wdArgs -WindowStyle Hidden -PassThru
    Write-VmtLog "Watchdog started (pid $($p.Id)): stops the run after ${WatchdogQuietSec}s without progress on an idle VM, or without declared patience"
}

# ------------------------------------------------------------------------- timeline, provenance
# What the harness was invoked with (never the password), for summary.json -> provenance.
$script:invocation = [ordered]@{}
foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'GuestPassword') { $script:invocation[$k] = $PSBoundParameters[$k] } }
$script:phaseCur = $null
$script:phaseList = [Collections.Generic.List[object]]::new()

function Set-VmtPhase {
    # Close the running phase and open the next (no name = just close). The timeline lands in summary.json.
    param([string]$Name)
    $now = Get-Date
    if ($script:phaseCur) {
        $script:phaseCur.endedAt = $now.ToString('o')
        $script:phaseCur.durationSec = [int]($now - [datetime]$script:phaseCur.startedAt).TotalSeconds
    }
    if ($Name) {
        $script:phaseCur = [ordered]@{ name = $Name; startedAt = $now.ToString('o'); endedAt = $null; durationSec = $null }
        $script:phaseList.Add($script:phaseCur)
    }
    else { $script:phaseCur = $null }
}

function Get-VmtPhaseTimeline {
    # The phases, each with the VM's CPU and disk use over it (from the watchdog's samples, if it ran).
    $csv = Join-Path $OutDir 'watchdog-samples.csv'
    $rows = @()
    if (Test-Path -LiteralPath $csv) {
        $rows = @(try { Import-Csv -LiteralPath $csv | ForEach-Object { [pscustomobject]@{ at = [datetime]$_.at; cpu = $_.cpuPct; r = $_.readMBps; w = $_.writeMBps; state = $_.state } } } catch { @() })
    }
    foreach ($ph in $script:phaseList) {
        $res = $null
        if ($ph.endedAt -and $rows.Count) {
            $a = [datetime]$ph.startedAt; $b = [datetime]$ph.endedAt
            $in = @($rows | Where-Object { $_.at -ge $a -and $_.at -le $b -and $_.state -eq 'Running' })
            $num = { param($name) @($in | Where-Object { $_.$name -ne '' -and $null -ne $_.$name } | ForEach-Object { [double]$_.$name }) }
            $cpu = & $num 'cpu'; $r = & $num 'r'; $w = & $num 'w'
            if ($in.Count) {
                $res = [ordered]@{
                    samples = $in.Count
                    cpuAvgPct = $(if ($cpu.Count) { [Math]::Round(($cpu | Measure-Object -Average).Average, 1) })
                    cpuMaxPct = $(if ($cpu.Count) { ($cpu | Measure-Object -Maximum).Maximum })
                    diskReadAvgMBps = $(if ($r.Count) { [Math]::Round(($r | Measure-Object -Average).Average, 1) })
                    diskWriteAvgMBps = $(if ($w.Count) { [Math]::Round(($w | Measure-Object -Average).Average, 1) })
                }
            }
        }
        [ordered]@{ name = $ph.name; startedAt = $ph.startedAt; endedAt = $ph.endedAt; durationSec = $ph.durationSec; resources = $res }
    }
}

function Get-VmtProvenance {
    # What exactly was tested: the harness scripts, the repository state (HEAD plus a fingerprint of every
    # uncommitted change, since build.json only says "dirty"), the host and the VM configuration.
    $p = [ordered]@{ invocation = $script:invocation }
    $p.scripts = [ordered]@{}
    foreach ($f in $PSCommandPath, $agentLocal, (Join-Path $PSScriptRoot 'vmtest\watchdog.ps1'), $amelog, $endStateCheck, $endStateKnown,
            $servicingDiag, $storeHealthScript, (Join-Path $PSScriptRoot 'build-package.ps1')) {
        $p.scripts[(Split-Path -Leaf $f)] = $(if (Test-Path -LiteralPath $f) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash } else { $null })
    }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $g = $git.Source
        $diff = (& $g -C $repoRoot diff HEAD --no-color 2>$null) -join "`n"
        $untracked = @(& $g -C $repoRoot ls-files --others --exclude-standard 2>$null | Sort-Object)
        $fp = $diff
        foreach ($u in $untracked) {
            $full = Join-Path $repoRoot $u
            $fp += "`n$u`:" + $(if (Test-Path -LiteralPath $full -PathType Leaf) { (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash } else { '' })
        }
        $p.git = [ordered]@{
            commit = [string](& $g -C $repoRoot rev-parse --short HEAD 2>$null | Select-Object -First 1)
            branch = [string](& $g -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
            changedFiles = @(& $g -C $repoRoot status --porcelain 2>$null | Select-Object -First 80)
            sourceFingerprint = (Get-VmtSha256Text $fp)
        }
    }
    $p.host = [ordered]@{
        powershell = $PSVersionTable.PSVersion.ToString()
        os = [string][Environment]::OSVersion.Version
        python = $(try { (& (Get-VmtPython) --version 2>&1 | Select-Object -First 1) -as [string] } catch { $null })
    }
    try {
        $vm = Get-VM -Name $VMName -ErrorAction Stop
        $p.vm = [ordered]@{ name = $VMName; generation = $vm.Generation; processors = $vm.ProcessorCount; memoryStartupGB = [Math]::Round($vm.MemoryStartup / 1GB, 1); dynamicMemory = [bool]$vm.DynamicMemoryEnabled }
    }
    catch { $p.vm = [ordered]@{ error = $_.Exception.Message } }
    return $p
}

# ------------------------------------------------------------------------- live end-state check
function Invoke-VmtLiveStateCheck {
    # Compares what the playbook's registry, service and file actions should leave behind (amelog.py expected)
    # with the live guest (endstate-check.ps1). Run twice: right after the first-boot commit check, which is
    # the playbook's own result, and at the end, after the apps. Differences listed in endstate-known.json are
    # reported but do not fail the run; any other difference does (status "failed").
    param([ValidateSet('first-boot', 'final')][string]$Stage)
    try {
        $expected = Join-Path $OutDir 'endstate-expected.json'
        if (-not (Test-Path -LiteralPath $expected)) {
            $r = Invoke-VmtProcess -FilePath (Get-VmtPython) -ArgumentList @($amelog, 'expected', '--config', $configCopy, '--options-file', $optFile, '--out', $expected) -TimeoutSec 120
            if ($r.Code -ne 0) { throw "amelog.py expected failed: $($r.Stderr.Trim())" }
        }
        Copy-VmtToGuest -LocalPath $expected -GuestName 'endstate-expected.json'
        Copy-VmtToGuest -LocalPath $endStateCheck -GuestName 'endstate-check.ps1'
        $r = Invoke-VmtGuestRun -Exe $guestPs -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guestIn\endstate-check.ps1", '-ExpectedFile', "$guestIn\endstate-expected.json") -TimeoutSec 300 -AllowFailure
        $m = [regex]::Match($r.Stdout, '(?s)VMTEST_ENDSTATE_BEGIN\s*(.*?)\s*VMTEST_ENDSTATE_END')
        if (-not $m.Success) { throw "the guest check returned no result: $(($r.Stderr + $r.Stdout).Trim() -replace '\s+', ' ')" }
        $d = $m.Groups[1].Value | ConvertFrom-Json -AsHashtable
        $known = @()
        if (Test-Path -LiteralPath $endStateKnown) { $known = @((Get-Content -LiteralPath $endStateKnown -Raw | ConvertFrom-Json -AsHashtable).entries) }
        $unexpected = @(); $knownHits = @()
        foreach ($mm in @($d.mismatches)) {
            $key = "$($mm.kind)|$($mm.path)|$($mm.name)"
            $k = $known | Where-Object { $key -like $_.like } | Select-Object -First 1
            if ($k) { $mm.known = $k.status; $knownHits += $mm }
            elseif ($mm.soft) { $mm.known = 'soft'; $knownHits += $mm }   # errorAction: Ignore, may legitimately not have happened
            else { $unexpected += $mm }
        }
        $kc = [ordered]@{
            explained = @($knownHits | Where-Object { $_.known -eq 'explained' }).Count
            open = @($knownHits | Where-Object { $_.known -eq 'open' }).Count
            soft = @($knownHits | Where-Object { $_.known -eq 'soft' }).Count
        }
        $res = [ordered]@{
            stage = $Stage; checkedAt = (Get-Date).ToString('o'); user = $d.user; counts = $d.counts
            status = $(if ($unexpected.Count) { 'failed' } else { 'ok' })
            unexpected = @($unexpected | Select-Object -First 100); knownDifferences = $kc
            known = @($knownHits | ForEach-Object { [ordered]@{ id = $_.id; kind = $_.kind; path = $_.path; name = $_.name; expected = $_.expected; actual = $_.actual; status = $_.known } })
        }
        $script:report.liveState[$Stage] = $res
        $stages = @($script:report.liveState.Keys | Where-Object { $_ -ne 'status' } | ForEach-Object { $script:report.liveState[$_] })
        $script:report.liveState.status = $(if (@($stages | Where-Object { $_.status -eq 'failed' }).Count) { 'failed' } else { 'ok' })
        $d | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutDir "endstate-live-$Stage.json") -Encoding utf8
        Write-VmtLog ("Live state ($Stage): {0} of {1} entries match; {2} unexpected, known differences: {3} explained, {4} open, {5} soft" -f
            $d.counts.ok, $d.counts.checked, $unexpected.Count, $kc.explained, $kc.open, $kc.soft)
        foreach ($u in @($unexpected | Select-Object -First 25)) { Write-VmtLog "  DIFF $($u.kind) $($u.path) $($u.name): $($u.reason), want $($u.expected), have $($u.actual) [$($u.id)]" }
    }
    catch {
        $script:report.liveState.status = 'error'
        $script:report.liveState.error = $_.Exception.Message
        $script:report.harnessErrors += "live end-state check ($Stage) could not run: $($_.Exception.Message)"
        Write-VmtLog "Live state ($Stage) check failed to run: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------------- component-store canary
function Invoke-VmtStoreHealth {
    # DISM /ScanHealth in the guest (store-health.ps1). The playbook's CBS removal cabs plus a later component cleanup
    # can leave the store "repairable" with no way back (docs/atlas-comparison.md 8.1); a normal apply must leave it
    # clean. "repairable" and "not-repairable" fail the run; an unreadable result is a harness error, not a verdict.
    try {
        Copy-VmtToGuest -LocalPath $storeHealthScript -GuestName 'store-health.ps1'
        Set-VmtPatience (25 * 60)   # ScanHealth writes no harness log lines for a few minutes
        $r = Invoke-VmtGuestRun -Exe $guestPs -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guestIn\store-health.ps1") -TimeoutSec 1200 -AllowFailure
        $m = [regex]::Match($r.Stdout, '(?s)VMTEST_STOREHEALTH_BEGIN\s*(.*?)\s*VMTEST_STOREHEALTH_END')
        if (-not $m.Success) { throw "no result from store-health.ps1: $(($r.Stderr + $r.Stdout).Trim() -replace '\s+', ' ')" }
        $d = $m.Groups[1].Value | ConvertFrom-Json
        if ($d.status -eq 'unknown') { throw "DISM /ScanHealth gave no verdict (exit $($d.exitCode)): $($d.output -join ' | ')" }
        $script:report.storeHealth = [ordered]@{
            status = $d.status; exitCode = $d.exitCode; durationSec = $d.durationSec; build = $d.build; output = @($d.output)
        }
        Write-VmtLog ("Component store (DISM /ScanHealth, {0} s, build {1}): {2}" -f $d.durationSec, $d.build, $d.status)
        if ($d.status -ne 'clean') { Write-VmtLog "  STORE NOT CLEAN: $($d.output -join ' | ')" }
    }
    catch {
        $script:report.storeHealth = [ordered]@{ status = 'error'; error = $_.Exception.Message }
        $script:report.harnessErrors += "component-store check could not run: $($_.Exception.Message)"
        Write-VmtLog "Component-store check failed to run: $($_.Exception.Message)"
    }
}

function Get-VmtServicingDiag {
    # The servicing commit did not happen: pull CBS.log and friends while the guest still shows it.
    param([string]$Where)
    try {
        Copy-VmtToGuest -LocalPath $servicingDiag -GuestName 'servicing-diag.ps1'
        $r = Invoke-VmtGuestRun -Exe $guestPs -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "$guestIn\servicing-diag.ps1") -TimeoutSec 300 -AllowFailure
        $m = [regex]::Match($r.Stdout, '(?s)VMTEST_DIAG_BEGIN\s*(.*?)\s*VMTEST_DIAG_END')
        if (-not $m.Success) { throw "no result from servicing-diag.ps1: $($r.Stderr.Trim())" }
        $d = $m.Groups[1].Value | ConvertFrom-Json
        $local = Copy-VmtFromGuest -GuestPath $d.zip -ExpectedSha256 $d.sha256 -LocalDir (Join-Path $OutDir 'diag')
        Write-VmtLog ("Servicing diagnostics pulled: $local ({0:N1} MB, CBS.log, dism.log, package states, Setup events)" -f ($d.size / 1MB))
        $script:report.endState.diagnostics = $local
    }
    catch { Write-VmtLog "Servicing diagnostics could not be pulled ($Where): $($_.Exception.Message)" }
}

function Invoke-VmtProcess {
    param([string]$FilePath, [string[]]$ArgumentList, [int]$TimeoutSec = 120)
    $psi = [Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($TimeoutSec * 1000)
    if ($timedOut) { try { $proc.Kill($true) } catch { } ; $proc.WaitForExit(10000) | Out-Null }
    return [pscustomobject]@{
        Code     = if ($timedOut) { -1 } else { $proc.ExitCode }
        Stdout   = $outTask.Result
        Stderr   = $errTask.Result
        TimedOut = $timedOut
    }
}

# ------------------------------------------------------------------------- PowerShell Direct
$script:hvCred = $null

function Get-VmtHvCred {
    if (-not $script:hvCred) {
        if (-not $GuestPassword) { throw 'Set -GuestPassword or $env:VMTEST_GUEST_PASSWORD (guest account password)' }
        $script:hvCred = [pscredential]::new(".\$GuestUser", (ConvertTo-SecureString $GuestPassword -AsPlainText -Force))
    }
    return $script:hvCred
}

function Invoke-VmtHvJob {
    # One PowerShell Direct call as a job, so a frozen guest cannot block the harness. Ok=$false means the
    # transport failed (guest still booting, session refused) or timed out; the command may not have run.
    param([scriptblock]$Script, [object[]]$ArgumentList = @(), [int]$TimeoutSec = 120)
    try {
        $job = Invoke-Command -VMName $VMName -Credential (Get-VmtHvCred) -ScriptBlock $Script -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
    }
    catch { return [pscustomobject]@{ Ok = $false; TimedOut = $false; Error = $_.Exception.Message; Output = @() } }
    try {
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSec)) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            return [pscustomobject]@{ Ok = $false; TimedOut = $true; Error = "PowerShell Direct call did not return within ${TimeoutSec}s"; Output = @() }
        }
        if ($job.State -eq 'Failed') {
            $reason = if ($job.ChildJobs.Count -and $job.ChildJobs[0].JobStateInfo.Reason) { $job.ChildJobs[0].JobStateInfo.Reason.Message } else { 'job failed' }
            return [pscustomobject]@{ Ok = $false; TimedOut = $false; Error = $reason; Output = @() }
        }
        return [pscustomobject]@{ Ok = $true; TimedOut = $false; Error = ''; Output = @(Receive-Job -Job $job -ErrorAction SilentlyContinue) }
    }
    finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}

# Runs inside the guest (Windows PowerShell 5.1, so keep it ASCII): start a process, capture stdout/stderr/exit code.
$script:hvRunBlock = {
    param([string]$Exe, [string[]]$ArgList, [int]$TimeoutMs)
    function ConvertTo-QuotedArg([string]$a) {
        if ($a.Length -eq 0) { return '""' }
        if ($a -notmatch '[\s"]') { return $a }
        return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = (@($ArgList | ForEach-Object { ConvertTo-QuotedArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $o = $p.StandardOutput.ReadToEndAsync()
    $e = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Code = -1; TimedOut = $true; Stdout = ''; Stderr = '' }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Code = $p.ExitCode; TimedOut = $false; Stdout = [string]$o.Result; Stderr = [string]$e.Result }
}

function Invoke-VmtGuestRun {
    # Returns an object with Code, Stdout, Stderr, TimedOut. Shortly after boot the session can be refused;
    # nothing ran then, so without -AllowFailure it is retried for up to 3 minutes. Probes (-AllowFailure)
    # have their own wait loops and stall checks.
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 120, [switch]$AllowFailure)
    $deadline = (Get-Date).AddMinutes(3)
    while ($true) {
        $j = Invoke-VmtHvJob -Script $script:hvRunBlock -ArgumentList @($Exe, [string[]]@($Arguments), [int]($TimeoutSec * 1000)) -TimeoutSec ($TimeoutSec + 30)
        if (-not $j.Ok -and -not $j.TimedOut -and -not $AllowFailure -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10; continue }
        break
    }
    $res = $null
    if ($j.Ok) { $res = @($j.Output | Where-Object { $_ -and $_.PSObject.Properties['Code'] }) | Select-Object -Last 1 }
    if ($res) {
        $r = [pscustomobject]@{ Code = [int]$res.Code; Stdout = [string]$res.Stdout; Stderr = [string]$res.Stderr; TimedOut = [bool]$res.TimedOut }
    }
    else {
        $r = [pscustomobject]@{ Code = $(if ($j.TimedOut) { -1 } else { 1 }); Stdout = ''; Stderr = $(if ($j.Error) { $j.Error } else { 'PowerShell Direct returned no result' }); TimedOut = $j.TimedOut }
    }
    if (-not $AllowFailure -and $r.Code -ne 0) {
        throw "PowerShell Direct run of $Exe failed ($($r.Code)): $($r.Stderr.Trim())"
    }
    return $r
}

function New-VmtHvSession {
    $deadline = (Get-Date).AddMinutes(3)
    while ($true) {
        try { return (New-PSSession -VMName $VMName -Credential (Get-VmtHvCred) -ErrorAction Stop) }
        catch { if ((Get-Date) -ge $deadline) { throw }; Start-Sleep -Seconds 10 }
    }
}

function New-VmtGuestDirectory([string]$Path) {
    $j = $null
    $deadline = (Get-Date).AddMinutes(3)
    do {
        $j = Invoke-VmtHvJob -Script { param([string]$p) New-Item -ItemType Directory -Force -Path $p | Out-Null } -ArgumentList @($Path) -TimeoutSec 60
        if (-not $j.Ok) { Start-Sleep -Seconds 10 }
    } while (-not $j.Ok -and (Get-Date) -lt $deadline)
    if (-not $j.Ok) { throw "Could not create $Path in the guest: $($j.Error)" }
}

function Invoke-VmtCopy {
    # Copy-Item over PowerShell Direct has no timeout of its own: a guest that stops answering mid-copy blocks
    # the harness for good. Run it as a thread job with a limit and retry once on a fresh session. The limit
    # is generous (120 s plus 2 s per MB sent; 600 s for a pull; VMTEST_COPY_TIMEOUT_SEC overrides it, for tests).
    param([ValidateSet('To', 'From')][string]$Direction, [string]$HostPath, [string]$GuestPath, [switch]$Gsi)
    $limit = if ($Direction -eq 'To') { [int](120 + 2 * ((Get-Item -LiteralPath $HostPath).Length / 1MB)) } else { 600 }
    if ($env:VMTEST_COPY_TIMEOUT_SEC) { $limit = [int]$env:VMTEST_COPY_TIMEOUT_SEC }
    # Large files to the guest go through the Guest Service Interface (Copy-VMFile, ~3x faster than the
    # PowerShell Direct pipe: 54 vs 16 MB/s measured here), falling back to PowerShell Direct if it fails.
    # -Gsi asks for it for small files too (it needs no guest session, which is most of a small copy's cost).
    # VMTEST_NO_GSI=1 turns it off.
    $useGsi = ($Direction -eq 'To' -and ($Gsi -or (Get-Item -LiteralPath $HostPath).Length -ge 8MB) -and $env:VMTEST_NO_GSI -ne '1')
    $lastError = ''
    for ($try = 1; $try -le 2; $try++) {
        $job = Start-ThreadJob -ArgumentList $VMName, (Get-VmtHvCred), $Direction, $HostPath, $GuestPath, $useGsi -ScriptBlock {
            param($vm, $cred, $dir, $hostPath, $guestPath, $gsi)
            if ($gsi) {
                try { Copy-VMFile -Name $vm -SourcePath $hostPath -DestinationPath $guestPath -FileSource Host -CreateFullPath -Force -ErrorAction Stop; return }
                catch { }   # not available: use PowerShell Direct below
            }
            $s = New-PSSession -VMName $vm -Credential $cred -ErrorAction Stop
            try {
                if ($dir -eq 'To') { Copy-Item -LiteralPath $hostPath -Destination $guestPath -ToSession $s -Force -ErrorAction Stop }
                else { Copy-Item -LiteralPath $guestPath -Destination $hostPath -FromSession $s -Force -ErrorAction Stop }
            }
            finally { Remove-PSSession -Session $s -ErrorAction SilentlyContinue }
        }
        if (Wait-Job -Job $job -Timeout $limit) {
            try { Receive-Job -Job $job -ErrorAction Stop | Out-Null; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue; return }
            catch { $lastError = $_.Exception.Message; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        }
        else {
            $lastError = "no result within ${limit}s"
            # Stop-Job can itself wait on a blocked native call: do not let it hold the harness.
            Stop-Job -Job $job -PassThru -ErrorAction SilentlyContinue | Out-Null
            Start-ThreadJob -ScriptBlock { param($j) Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } -ArgumentList $job | Out-Null
        }
        Write-VmtLog "Copy $Direction guest $(Split-Path -Leaf $GuestPath) failed (attempt $try of 2): $lastError"
        if ($try -lt 2) { Start-Sleep -Seconds 10 }
    }
    throw "Copy $Direction guest failed twice ($GuestPath): $lastError"
}

function Send-VmtFile {
    param([string]$LocalPath, [string]$GuestPath)
    New-VmtGuestDirectory (Split-Path -Parent $GuestPath)
    Invoke-VmtCopy -Direction To -HostPath $LocalPath -GuestPath $GuestPath
}

function Receive-VmtFile {
    param([string]$GuestPath, [string]$LocalDir)
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    $target = Join-Path $LocalDir (Split-Path -Leaf $GuestPath)
    Invoke-VmtCopy -Direction From -HostPath $target -GuestPath $GuestPath
}

function Invoke-VmtAgent {
    param([string]$Mode, [string]$Job = 'apply', [int]$TimeoutSec = 660)
    $agentArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:/vmtest/in/guest-agent.ps1', '-Mode', $Mode, '-Job', $Job)
    if ($NoDefenderRemediation) { $agentArgs += '-NoDefenderRemediation' }
    $r = Invoke-VmtGuestRun -Exe $guestPs -Arguments $agentArgs -TimeoutSec $TimeoutSec -AllowFailure
    $text = $r.Stdout
    $begin = $text.IndexOf('VMTEST_JSON_BEGIN')
    $end = $text.IndexOf('VMTEST_JSON_END')
    $exitMatch = [regex]::Match($text, 'VMTEST_EXIT=(-?\d+)')
    if ($begin -lt 0 -or $end -lt $begin -or -not $exitMatch.Success) {
        return [pscustomobject]@{ Exit = $null; Data = $null; Raw = ($text + $r.Stderr).Trim() }
    }
    $json = $text.Substring($begin + 'VMTEST_JSON_BEGIN'.Length, $end - $begin - 'VMTEST_JSON_BEGIN'.Length)
    return [pscustomobject]@{ Exit = [int]$exitMatch.Groups[1].Value; Data = ($json | ConvertFrom-Json -AsHashtable); Raw = $null }
}

# ------------------------------------------------------------------------- VM state and power
function Get-VmtVmState {
    # Lower-case names the rest of the harness compares against: running, poweroff, saved, paused.
    $s = [string](Get-VM -Name $VMName -ErrorAction Stop).State
    switch ($s) {
        'Running' { return 'running' }
        'Off'     { return 'poweroff' }
        'Saved'   { return 'saved' }
        'Paused'  { return 'paused' }
        default   { return $s.ToLowerInvariant() }
    }
}

function Wait-VmtVmState {
    param([string[]]$Wanted, [int]$TimeoutSec = 120)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try { $state = Get-VmtVmState } catch { $state = $null }
        if ($state -and $Wanted -contains $state) { return $state }
        Start-Sleep -Seconds 2
    }
    throw "VM did not reach state $($Wanted -join '/') within ${TimeoutSec}s (now $(Get-VmtVmState))"
}

function Start-VmtVm { Start-VM -Name $VMName -ErrorAction Stop | Out-Null }

function Stop-VmtVm {
    $state = Get-VmtVmState
    if (@('poweroff', 'aborted', 'saved') -notcontains $state) {
        Write-VmtLog "Powering off $VMName (state $state)"
        Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
        Wait-VmtVmState -Wanted @('poweroff', 'aborted') | Out-Null
    }
}

# ------------------------------------------------------------------------- hang detection
$script:hvNoCounterWarned = $false

function Get-VmtDiskBytes {
    # Cumulative read + write operation counts of this VM's virtual disks; callers only compare successive
    # values. If the counters cannot be found, return an ever-changing value so a missing counter can never
    # be mistaken for a frozen guest.
    $sum = [long]0; $hit = 0
    try {
        $c = Get-Counter -Counter '\Hyper-V Virtual Storage Device(*)\Read Count', '\Hyper-V Virtual Storage Device(*)\Write Count' -ErrorAction Stop
        foreach ($s in $c.CounterSamples) {
            if ($s.InstanceName -like "*$($VMName.ToLowerInvariant())*") { $sum += [long]$s.CookedValue; $hit++ }
        }
    }
    catch { }
    if (-not $hit) {
        if (-not $script:hvNoCounterWarned) { Write-VmtLog "No Hyper-V storage counters found for $VMName; hang detection by disk I/O is off"; $script:hvNoCounterWarned = $true }
        return [long](Get-Date).Ticks
    }
    return $sum
}

function New-VmtStallWatch {
    # Every caller but Wait-VmtJob is a boot, reboot or shutdown wait that may legitimately log nothing for
    # as long as a reboot can take (queued servicing), so the watchdog is told to allow that.
    param([switch]$NoPatience)
    if (-not $NoPatience) { Set-VmtPatience ($RebootTimeoutSec + 120) }
    return @{ bytes = (Get-VmtDiskBytes); since = [Diagnostics.Stopwatch]::StartNew() }
}

function Test-VmtStalled([hashtable]$Watch) {
    # True once the guest has done no disk I/O for -StallSec. A rebooting or working guest always
    # touches its disk; a frozen one does not.
    $now = Get-VmtDiskBytes
    if ($now -ne $Watch.bytes) { $Watch.bytes = $now; $Watch.since.Restart(); return $false }
    return ($Watch.since.Elapsed.TotalSeconds -ge $StallSec)
}

function Reset-VmtHungVm([string]$Where, [string]$Reason = "no disk I/O for ${StallSec}s") {
    Write-VmtLog "Guest hung during $Where ($Reason); powering $VMName off and booting again"
    $script:report.hangs += [ordered]@{ where = $Where; reason = $Reason; at = (Get-Date).ToString('o') }
    Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
    if ((Get-VmtVmState) -ne 'poweroff') {
        # A wedged VM worker: end the vmwp.exe that carries this VM's id.
        $id = [string](Get-VM -Name $VMName).Id
        Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match [regex]::Escape($id) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Wait-VmtVmState -Wanted @('aborted', 'poweroff') | Out-Null
    Start-VmtVm
}

function Wait-VmtGuestReady {
    # A real round trip through PowerShell Direct plus an explorer.exe for a user (the auto-logon desktop).
    # Match the exact token, not "ready": the not-ready error text contains that word.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = ''
    Set-VmtPatience ($BootTimeoutSec + 120)
    while ($sw.Elapsed.TotalSeconds -lt $BootTimeoutSec) {
        $r = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\cmd.exe' -Arguments @('/c', 'echo', 'VMTEST_OK') -TimeoutSec 30 -AllowFailure
        if ($r.Code -eq 0 -and (($r.Stdout -split "`r?`n") -contains 'VMTEST_OK')) {
            $t = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\tasklist.exe' -Arguments @('/fi', 'imagename eq explorer.exe', '/nh') -TimeoutSec 30 -AllowFailure
            if ($t.Code -eq 0 -and $t.Stdout -match 'explorer\.exe') {
                Write-VmtLog "Guest ready after $([int]$sw.Elapsed.TotalSeconds)s (PowerShell Direct up, desktop shell running)"
                return
            }
            $last = 'PowerShell Direct is up, waiting for an interactive logon'
        }
        else { $last = ($r.Stderr.Trim() -split "`r?`n" | Select-Object -First 1) }
        Start-Sleep -Seconds 3
    }
    throw "Guest not ready within ${BootTimeoutSec}s: $last"
}

function Get-VmtGuestSha256 {
    param([string]$GuestPath)
    $r = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\certutil.exe' -Arguments @('-hashfile', $GuestPath, 'SHA256') -TimeoutSec 120 -AllowFailure
    foreach ($line in ($r.Stdout -split "`r?`n")) {
        $hex = ($line -replace '\s', '')
        if ($hex -match '^[0-9a-fA-F]{64}$') { return $hex.ToUpperInvariant() }
    }
    return $null
}

function Copy-VmtToGuest {
    param([string]$LocalPath, [string]$GuestName)
    $guestPath = "$guestIn\$GuestName"
    $want = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash
    Send-VmtFile -LocalPath $LocalPath -GuestPath $guestPath
    # certutil can come back empty on a guest busy right after boot (Store updates): ask again.
    $got = $null
    for ($try = 1; $try -le 4 -and -not $got; $try++) {
        $got = Get-VmtGuestSha256 -GuestPath $guestPath
        if (-not $got) { Start-Sleep -Seconds 5 }
    }
    if ($got -ne $want) { throw "Hash mismatch after copying $GuestName to the guest (host $want, guest $got)" }
    Write-VmtLog "Copied $GuestName -> $guestPath (sha256 verified)"
}

function Copy-VmtToGuestMany {
    # Several inputs in one pass: one directory call, the copies over the Guest Service Interface (no session per
    # file), and every SHA256 checked by a single guest call. Each file alone cost about 5 s of session set-up.
    param([object[]]$Files)   # each: @{ LocalPath = ...; GuestName = ... }
    $items = @($Files | ForEach-Object {
        [pscustomobject]@{ Name = $_.GuestName; Local = $_.LocalPath; Guest = "$guestIn\$($_.GuestName)"; Want = (Get-FileHash -LiteralPath $_.LocalPath -Algorithm SHA256).Hash }
    })
    New-VmtGuestDirectory $guestIn
    foreach ($i in $items) { Invoke-VmtCopy -Direction To -HostPath $i.Local -GuestPath $i.Guest -Gsi }
    $got = @{}
    for ($try = 1; $try -le 4; $try++) {
        $j = Invoke-VmtHvJob -TimeoutSec 180 -ArgumentList @(, [string[]]@($items | ForEach-Object { $_.Guest })) -Script {
            param([string[]]$Paths)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            foreach ($p in $Paths) {
                if (-not (Test-Path -LiteralPath $p)) { "$p|MISSING"; continue }
                $s = [System.IO.File]::OpenRead($p)
                try { "$p|" + [BitConverter]::ToString($sha.ComputeHash($s)).Replace('-', '') } finally { $s.Dispose() }
            }
        }
        if ($j.Ok) {
            foreach ($line in @($j.Output)) { $k, $v = ([string]$line) -split '\|', 2; if ($v) { $got[$k] = $v } }
            if (@($items | Where-Object { $got[$_.Guest] -and $got[$_.Guest] -ne 'MISSING' }).Count -eq $items.Count) { break }
        }
        if ($try -lt 4) { Start-Sleep -Seconds 5 }
    }
    foreach ($i in $items) {
        if ($got[$i.Guest] -ne $i.Want) { throw "Hash mismatch after copying $($i.Name) to the guest (host $($i.Want), guest $($got[$i.Guest]))" }
    }
    Write-VmtLog "Copied $($items.Count) input file(s) to $guestIn (sha256 verified): $(($items | ForEach-Object { $_.Name }) -join ', ')"
}

function Copy-VmtFromGuest {
    param([string]$GuestPath, [string]$ExpectedSha256, [string]$LocalDir)
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    $target = (Join-Path $LocalDir (Split-Path -Leaf $GuestPath))
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    Receive-VmtFile -GuestPath $GuestPath -LocalDir $LocalDir
    $got =(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($ExpectedSha256 -and $got -ne $ExpectedSha256.ToUpperInvariant()) { throw "Hash mismatch pulling $GuestPath (guest $ExpectedSha256, host $got)" }
    return $target
}

function Get-VmtDefaultOptions {
    # What AME Wizard pre-selects: checked checkboxes plus every radio page's DefaultOption.
    param([string]$ConfPath)
    [xml]$conf = Get-Content -LiteralPath $ConfPath -Raw
    $opts = [Collections.Generic.List[string]]::new()
    foreach ($page in $conf.Playbook.FeaturePages.ChildNodes) {
        if ($page.NodeType -ne 'Element') { continue }
        if ($page.LocalName -like 'Radio*Page' -and $page.DefaultOption) { $opts.Add($page.DefaultOption) }
        if ($page.LocalName -eq 'CheckboxPage') {
            foreach ($o in $page.Options.ChildNodes) {
                if ($o.NodeType -eq 'Element' -and $o.IsChecked -eq 'true' -and $o.Name) { $opts.Add($o.Name) }
            }
        }
    }
    return @($opts | Select-Object -Unique)
}

function Get-VmtCliZip {
    if ($CliZip) { $path = $CliZip }
    else {
        $dir = Join-Path $repoRoot "tools\cache\ame-cli-$cliRelease"
        $path = Join-Path $dir 'CLI-Standalone.zip'
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Write-VmtLog "Downloading $cliUrl"
            Invoke-WebRequest -Uri $cliUrl -OutFile $path
        }
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if (-not $CliZip -and $hash -ne $cliSha256) { throw "AME CLI zip hash $hash does not match the pinned $cliSha256" }
    return $path
}

function Get-VmtPython {
    foreach ($name in 'python', 'py') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    throw 'Python 3 with PyYAML is required for log summarising (pip install pyyaml)'
}

function Invoke-VmtSummarize {
    param([string]$ConfigDir, [string]$OptionsFile, [string]$LogsDir, [switch]$Upgrade)
    $out = Join-Path $OutDir 'tweaks.json'
    $stdout = Get-ChildItem -LiteralPath $LogsDir -Recurse -Filter 'stdout.txt' -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -eq 'apply' } | Select-Object -First 1
    $pyArgs = @($amelog, 'summarize', '--config', $ConfigDir, '--options-file', $OptionsFile, '--logs', $LogsDir, '--out', $out)
    if ($stdout) { $pyArgs += @('--cli-stdout', $stdout.FullName) }
    if ($Upgrade) { $pyArgs += '--upgrade' }
    $r = Invoke-VmtProcess -FilePath (Get-VmtPython) -ArgumentList $pyArgs -TimeoutSec 300
    if ($r.Code -ne 0) { throw "amelog.py failed: $($r.Stderr.Trim())" }
    return (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json -AsHashtable)
}

function Wait-VmtJob {
    param([string]$Job, [int]$TimeoutMin)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastTail = ''
    $misses = 0
    $watch = $null
    while ($sw.Elapsed.TotalMinutes -lt $TimeoutMin) {
        Start-Sleep -Seconds $PollSec
        $s = Invoke-VmtAgent -Mode Status -Job $Job -TimeoutSec 60
        if ($null -eq $s.Exit) {
            $misses++
            Write-VmtLog "Status poll failed ($misses): $($s.Raw -replace '\s+', ' ')"
            # Unanswered polls plus a disk with no I/O: a frozen guest, not a busy one. The job dies
            # with the reset, so report it rather than wait out the timeout.
            if (-not $watch) { $watch = New-VmtStallWatch -NoPatience }
            elseif (Test-VmtStalled $watch) {
                Reset-VmtHungVm "$Job job"
                Wait-VmtDesktop
                $script:report.harnessErrors += "The guest froze during the $Job job; rerun"
                return [ordered]@{ status = 'vm-hung'; durationSec = [int]$sw.Elapsed.TotalSeconds; lastOutput = $lastTail }
            }
            # Keep polling rather than block in Wait-VmtGuestReady: a busy guest (or one an installer
            # rebooted) keeps touching its disk and answers again; only a frozen one trips the watch.
            if ($misses -ge 3) {
                $state = try { Get-VmtVmState } catch { 'running' }
                if ($state -ne 'running') { return [ordered]@{ status = 'vm-stopped'; vmState = $state; durationSec = [int]$sw.Elapsed.TotalSeconds } }
            }
            continue
        }
        $misses = 0; $watch = $null
        $tail = ($s.Data.tail -join ' / ')
        if ($tail -and $tail -ne $lastTail) { Write-VmtLog "  $Job : $tail"; $lastTail = $tail }
        if ($s.Data.finished) {
            return [ordered]@{ status = 'completed'; exitCode = $s.Data.exitCode; durationSec = [int]$sw.Elapsed.TotalSeconds; lastOutput = $s.Data.tail }
        }
        if (-not $s.Data.started -and $sw.Elapsed.TotalMinutes -gt 2) {
            return [ordered]@{ status = 'not-started'; durationSec = [int]$sw.Elapsed.TotalSeconds }
        }
        if ($Job -eq 'apply' -and $s.Data.processes.Count -eq 0 -and $sw.Elapsed.TotalMinutes -gt 2) {
            # CLI gone without writing the exit marker: give cmd.exe one more poll to write it.
            Start-Sleep -Seconds 5
            $again = Invoke-VmtAgent -Mode Status -Job $Job -TimeoutSec 60
            if ($again.Data -and $again.Data.finished) { continue }
            return [ordered]@{ status = 'vanished'; durationSec = [int]$sw.Elapsed.TotalSeconds; lastOutput = $s.Data.tail }
        }
    }
    Write-VmtLog "$Job exceeded ${TimeoutMin} min - treating as hung and stopping it"
    $stop = Invoke-VmtAgent -Mode Stop -Job $Job
    return [ordered]@{ status = 'hung'; timeoutMin = $TimeoutMin; durationSec = [int]$sw.Elapsed.TotalSeconds; stop = $stop.Data; lastOutput = $lastTail }
}

function Get-VmtAppsSummary {
    # Parses INSTALL-APPS.ps1's closing "== Summary" block (it always exits 0).
    param([string]$Stdout)
    $text = [IO.File]::ReadAllText($Stdout)
    $idx = $text.LastIndexOf('== Summary')
    if ($idx -lt 0) { return $null }
    $s = [ordered]@{ installed = $null; alreadyInstalled = $null; rebootToFinish = @(); failed = @(); defaultAppTypes = $null; defaultAppTotal = $null; notSet = @(); noHandler = @() }
    $section = ''
    foreach ($line in ($text.Substring($idx) -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s+(Installed|Already installed|Reboot to finish|Failed|Default app types):\s*(.*)$')
        if ($m.Success) {
            $section = $m.Groups[1].Value
            $v = $m.Groups[2].Value.Trim()
            switch ($section) {
                'Installed' { $s.installed = [int]$v }
                'Already installed' { $s.alreadyInstalled = [int]$v }
                'Reboot to finish' { $s.rebootToFinish = @($v -split ',\s*' | Where-Object { $_ }) }
                'Default app types' {
                    # "<n> of <k> set"
                    $nums = [regex]::Matches($v, '\d+')
                    if ($nums.Count) { $s.defaultAppTypes = [int]$nums[0].Value }
                    if ($nums.Count -gt 1) { $s.defaultAppTotal = [int]$nums[1].Value }
                }
            }
            continue
        }
        $item = [regex]::Match($line, '^\s{5}(\S.*)$')
        if (-not $item.Success) { continue }
        if ($section -eq 'Failed') { $s.failed += $item.Groups[1].Value.Trim() }
        elseif ($section -eq 'Default app types') {
            # "not set: App: types (...)" / "not set because <why>" = the write failed; "no handler: App: types" = nothing to set
            $entry = $item.Groups[1].Value.Trim()
            if ($entry -match '^no handler:\s*(.*)$') { $s.noHandler += $Matches[1] }
            else { $s.notSet += ($entry -replace '^not set:\s*', '' -replace '\s*\(set these in Settings[^)]*\)$', '') }
        }
    }
    return $s
}

function Restart-VmtGuest {
    # Graceful reboot. Done only when the guest reports a new boot time AND explorer.exe runs for a
    # user: the execution service answers before the desktop exists, and elevating then fails with
    # "This operation requires an interactive window station".
    # -FirstBoot is the reboot that commits the servicing the apply queued: auto-logon is switched off for
    # it (see Complete-VmtFirstBoot), so a new boot time that answers over PowerShell Direct is enough.
    param([switch]$FirstBoot)
    $before = Invoke-VmtAgent -Mode Probe -TimeoutSec 120
    if ($null -eq $before.Exit) { throw "Guest probe failed before reboot: $($before.Raw)" }
    if ($FirstBoot) { Set-VmtAutoLogon -On $false }
    Write-VmtLog "Rebooting the guest (booted $($before.Data.bootTime))"
    Invoke-VmtGuestRun -Exe 'C:\Windows\System32\shutdown.exe' -Arguments @('/r', '/t', '5', '/f') -TimeoutSec 60 -AllowFailure | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $watch = New-VmtStallWatch; $resets = 0
    while ($sw.Elapsed.TotalSeconds -lt $RebootTimeoutSec) {
        Start-Sleep -Seconds 5
        if (Test-VmtStalled $watch) {
            # A reboot was asked for anyway, so a hard reset of a frozen one loses nothing.
            if (++$resets -gt 2) { throw "Guest hung on every reboot attempt ($resets)" }
            Reset-VmtHungVm 'reboot'
            $watch = New-VmtStallWatch
            continue
        }
        $p = Invoke-VmtAgent -Mode Probe -TimeoutSec 60
        if ($null -eq $p.Exit -or -not $p.Data) { continue }
        if ($p.Data.bootTime -ne $before.Data.bootTime -and ($FirstBoot -or @($p.Data.interactiveUsers).Count -gt 0)) {
            if ($FirstBoot) { Write-VmtLog "Guest rebooted (booted $($p.Data.bootTime)) and answers over PowerShell Direct after $([int]$sw.Elapsed.TotalSeconds)s (auto-logon off)" }
            else { Write-VmtLog "Guest rebooted (booted $($p.Data.bootTime)) and $($p.Data.interactiveUsers -join ',') has a desktop after $([int]$sw.Elapsed.TotalSeconds)s" }
            return
        }
    }
    throw "Guest did not finish rebooting to a desktop within ${RebootTimeoutSec}s"
}

function Wait-VmtDesktop {
    # After booting a layer: the first boot after the playbook can run queued servicing work for a
    # long time, so wait as long as a reboot may take, and for explorer.exe, not just the service.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $watch = New-VmtStallWatch; $resets = 0
    while ($sw.Elapsed.TotalSeconds -lt $RebootTimeoutSec) {
        Start-Sleep -Seconds 5
        if (Test-VmtStalled $watch) {
            if (++$resets -gt 2) { throw "Guest hung on every boot attempt ($resets)" }
            Reset-VmtHungVm 'boot'
            $watch = New-VmtStallWatch
            continue
        }
        $p = Invoke-VmtAgent -Mode Probe -TimeoutSec 60
        if ($null -eq $p.Exit -or -not $p.Data) { continue }
        if (@($p.Data.interactiveUsers).Count -gt 0) {
            Write-VmtLog "Guest booted ($($p.Data.bootTime)); $($p.Data.interactiveUsers -join ',') has a desktop after $([int]$sw.Elapsed.TotalSeconds)s"
            return
        }
    }
    throw "Guest did not boot to a desktop within ${RebootTimeoutSec}s"
}

# ------------------------------------------------------------------------- first boot after an apply
# The playbook installs the Revision CBS removal packages with -NoRestart; CBS commits them at the next boot,
# at about +10 s, while Winlogon's auto-logon has already loaded and unloaded the user's hive once. CBS then
# cannot open \Registry\USER\<sid> ("Per-User Registry Installer ... ERROR_FILE_NOT_FOUND", 0x800f0922) and rolls
# the whole queue back ("Something didn't go as planned, undoing changes"). Seen 2026-11-09: this guest rolled
# back at the first boot every time with auto-logon on, and committed cleanly (all five packages Installed,
# no Defender/telemetry services) in the one run with it off; the VirtualBox guest, where CBS ran before the
# auto-logon attempt, committed too. So the first boot after an apply runs with auto-logon off, the commit
# is verified, and only then is auto-logon restored.
$script:winlogonKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

function Set-VmtAutoLogon {
    param([bool]$On)
    $r = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\reg.exe' -Arguments @('add', $script:winlogonKey, '/v', 'AutoAdminLogon', '/t', 'REG_SZ', '/d', $(if ($On) { '1' } else { '0' }), '/f') -TimeoutSec 60 -AllowFailure
    if ($r.Code -ne 0) { throw "Could not set AutoAdminLogon=$([int]$On): $($r.Stderr.Trim())" }
    Write-VmtLog "Guest auto-logon $(if ($On) { 'restored' } else { 'switched off for the first boot' })"
}

function Wait-VmtGuestUp {
    # A boot with auto-logon off never gets a desktop: wait for a PowerShell Direct round trip instead.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $watch = New-VmtStallWatch; $resets = 0
    while ($sw.Elapsed.TotalSeconds -lt $RebootTimeoutSec) {
        Start-Sleep -Seconds 5
        if (Test-VmtStalled $watch) {
            if (++$resets -gt 2) { throw "Guest hung on every boot attempt ($resets)" }
            Reset-VmtHungVm 'first boot'
            $watch = New-VmtStallWatch
            continue
        }
        $r = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\cmd.exe' -Arguments @('/c', 'echo', 'VMTEST_OK') -TimeoutSec 30 -AllowFailure
        if ($r.Code -eq 0 -and (($r.Stdout -split "`r?`n") -contains 'VMTEST_OK')) {
            Write-VmtLog "Guest answers over PowerShell Direct after $([int]$sw.Elapsed.TotalSeconds)s (auto-logon off)"
            return
        }
    }
    throw "Guest did not answer within ${RebootTimeoutSec}s"
}

function Complete-VmtFirstBoot {
    # The guest has just taken its first boot after an apply, with auto-logon off and the current guest-agent.ps1
    # in place: verify the servicing commit, switch auto-logon back on and reboot to a desktop.
    param([string]$Where, [string]$LayerName)
    Set-VmtPhase 'first-boot-check'
    Test-VmtEndState -Where $Where -LayerName $LayerName
    Invoke-VmtLiveStateCheck -Stage 'first-boot'
    Set-VmtPhase 'reboot-to-desktop'
    Set-VmtAutoLogon -On $true
    Restart-VmtGuest
}

# ------------------------------------------------------------------------- checkpoint layers
function Assert-VmtBackend {
    try { $vm = Get-VM -Name $VMName -ErrorAction Stop }
    catch { throw "Hyper-V VM '$VMName' not found or no permission ($($_.Exception.Message)). The user must be in the Hyper-V Administrators group." }
    if ($vm.Generation -ne 2) { Write-VmtLog "Warning: $VMName is generation $($vm.Generation); the base was built as generation 2" }
}

function Get-VmtSnapshots {
    # name -> checkpoint id (the layer keys use the id to notice a base that was re-taken).
    $map = @{}
    foreach ($c in @(Get-VMCheckpoint -VMName $VMName -ErrorAction SilentlyContinue)) { $map[$c.Name] = [string]$c.Id }
    return $map
}

function Restore-VmtSnapshot([string]$Name) {
    Restore-VMCheckpoint -VMName $VMName -Name $Name -Confirm:$false -ErrorAction Stop
}

function New-VmtSnapshot([string]$Name, [string]$Description) {
    # Standard checkpoint taken with the VM Off, so it is disk only. Checkpoints carry no description;
    # the layer record in out\vmtest\layers holds it.
    Checkpoint-VM -Name $VMName -SnapshotName $Name -ErrorAction Stop
}

function Remove-VmtSnapshot([string]$Name) {
    Remove-VMCheckpoint -VMName $VMName -Name $Name -Confirm:$false -ErrorAction Stop
    # The differencing disk merges in the background; the VM cannot be restored or started until it is done.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Set-VmtPatience (30 * 60 + 120)
    Start-Sleep -Seconds 2
    while ($sw.Elapsed.TotalMinutes -lt 30) {
        if (([string](Get-VM -Name $VMName).Status) -notmatch 'erg') { Remove-Item -LiteralPath $script:patienceFile -Force -ErrorAction SilentlyContinue; return }
        Start-Sleep -Seconds 3
    }
    throw "Checkpoint $Name was removed but the disk merge did not finish within 30 minutes"
}

function Get-VmtSha256Text([string]$Text) {
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))
    return [Convert]::ToHexString($bytes)
}

function Get-VmtTreeHash {
    # One hash over "relative/path:sha256" lines of the extracted package, filtered by -Include.
    param([string]$Root, [scriptblock]$Include)
    $base = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
    $lines = foreach ($f in Get-ChildItem -LiteralPath $base -Recurse -File -Force) {
        $rel = $f.FullName.Substring($base.Length + 1).Replace('\', '/')
        if (& $Include $rel) { '{0}:{1}' -f $rel, (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
    }
    return Get-VmtSha256Text ((@($lines) | Sort-Object -CaseSensitive) -join "`n")
}

function Get-VmtLayerRecord([string]$Name) {
    $path = Join-Path $layerDir "$Name.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
}

function Test-VmtLayer {
    param([string]$Name, [hashtable]$Snapshots, [int]$MaxAgeHours = 0)
    $rec = Get-VmtLayerRecord $Name
    if (-not $rec -or -not $Snapshots.ContainsKey($Name) -or $rec.vm -ne $VMName) { return $false }
    # An apply whose first boot rolled the servicing back (Test-VmtEndState) is not a usable base, nor is
    # anything built on it.
    $parentRec = if ($rec.parent) { Get-VmtLayerRecord $rec.parent } else { $null }
    foreach ($r in @($rec, $parentRec)) {
        if ($r -and $r.endState -and $r.endState.status -eq 'failed') {
            Write-VmtLog "Layer $($r.name) is unusable: its first boot did not commit the removal packages; rebuilding"
            return $false
        }
    }
    if ($MaxAgeHours -gt 0 -and ([datetime]$rec.created) -lt (Get-Date).AddHours(-$MaxAgeHours)) {
        Write-VmtLog "Layer $Name is older than $MaxAgeHours h; rebuilding it"
        return $false
    }
    return $true
}

function Remove-VmtLayer([string]$Name) {
    # Children first, so a layer is never removed out from under one built on it.
    foreach ($f in @(Get-ChildItem -LiteralPath $layerDir -Filter 'vmtest-L*.json' -File -ErrorAction SilentlyContinue)) {
        $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable
        if ($rec.parent -eq $Name) { Remove-VmtLayer $rec.name }
    }
    if ((Get-VmtSnapshots).ContainsKey($Name)) {
        Write-VmtLog "Deleting layer snapshot $Name"
        Remove-VmtSnapshot $Name
    }
    Remove-Item -LiteralPath (Join-Path $layerDir "$Name.json") -Force -ErrorAction SilentlyContinue
}

function Remove-VmtOldLayers {
    # Keep the newest -KeepLayers L1s, and the newest -KeepLayers L2s under each L1. Only checkpoints this
    # harness created (vmtest-L1-/vmtest-L2- plus 12 hex digits) are ever touched; the base is never pruned.
    # A layer checkpoint with no record is unusable (Test-VmtLayer) and is removed too, L2s before L1s.
    $known = @(Get-ChildItem -LiteralPath $layerDir -Filter 'vmtest-L*.json' -File -ErrorAction SilentlyContinue | ForEach-Object BaseName)
    $snaps = (Get-VmtSnapshots).Keys
    foreach ($name in @($snaps | Where-Object { $_ -match '^vmtest-L2-[0-9a-f]{12}$' -and $_ -notin $known }) +
                      @($snaps | Where-Object { $_ -match '^vmtest-L1-[0-9a-f]{12}$' -and $_ -notin $known })) {
        Write-VmtLog "Deleting layer snapshot $name (no layer record)"
        Remove-VmtSnapshot $name
    }
    $recs = @(Get-ChildItem -LiteralPath $layerDir -Filter 'vmtest-L*.json' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable } |
        Where-Object { $_.vm -eq $VMName })
    $groups = @($recs | Group-Object { if ($_.kind -eq 'L1') { 'L1' } else { "L2|$($_.parent)" } })
    foreach ($g in $groups) {
        foreach ($old in @($g.Group | Sort-Object { [datetime]$_.created } -Descending | Select-Object -Skip $KeepLayers)) {
            Remove-VmtLayer $old.name
        }
    }
}

function Save-VmtLayer {
    # Shut the guest down cleanly, snapshot it offline, record what built it, then boot it again.
    param([string]$Kind, [string]$Name, [string]$Key, [string]$Parent, [Collections.IDictionary]$Inputs,
        [Collections.IDictionary]$Cached, [switch]$NoRestart)
    $kindTag = $Kind.ToLowerInvariant()
    Set-VmtPhase "$kindTag-shutdown"
    Write-VmtLog "Shutting the guest down to snapshot layer $Name"
    # An L1 holds the apply's queued servicing, which the next boot commits: that boot must run with auto-logon off.
    if ($Kind -eq 'L1') { Set-VmtAutoLogon -On $false }
    # Plain /s is a full shutdown: Fast Startup (a kernel resume on the next boot) needs /hybrid.
    # This shutdown.exe has no /full switch; given one, it prints its help and does nothing.
    $sd = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\shutdown.exe' -Arguments @('/s', '/t', '5', '/f') -TimeoutSec 60 -AllowFailure
    if ($sd.Stdout -match 'Usage:') { throw "shutdown.exe rejected its arguments: $(($sd.Stdout -split "`r?`n")[0])" }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $watch = New-VmtStallWatch
    while ($true) {
        try { $state = Get-VmtVmState } catch { $state = 'running' }   # transient RPC errors: ask again
        if ($state -ne 'running') { break }
        Start-Sleep -Seconds 5
        # The first shutdown after the playbook can run queued servicing, so allow a reboot's time.
        $timedOut = $sw.Elapsed.TotalSeconds -gt $RebootTimeoutSec
        if ($timedOut -or (Test-VmtStalled $watch)) {
            # A hard-killed shutdown is not a clean image: boot on without caching it.
            Reset-VmtHungVm 'layer shutdown' $(if ($timedOut) { "not off after ${RebootTimeoutSec}s" } else { "no disk I/O for ${StallSec}s" })
            Write-VmtLog "Not snapshotting ${Name}: the shutdown did not finish cleanly"
            if ($Kind -eq 'L1') { Wait-VmtGuestUp; Complete-VmtFirstBoot -Where "first boot after a hung shutdown ($Name not saved)" } else { Wait-VmtDesktop }
            return
        }
    }
    $state = Get-VmtVmState
    if ($state -ne 'poweroff') { throw "Guest ended in state $state instead of a clean shutdown; not snapshotting $Name" }
    Set-VmtPhase "$kindTag-snapshot"
    if ((Get-VmtSnapshots).ContainsKey($Name)) { Remove-VmtLayer $Name }
    New-VmtSnapshot -Name $Name -Description "vmtest $Kind layer, key $Key (record: out\vmtest\layers\$Name.json)"
    New-Item -ItemType Directory -Force -Path $layerDir | Out-Null
    $rec = [ordered]@{ name = $Name; kind = $Kind; key = $Key; parent = $Parent; vm = $VMName
        created = (Get-Date).ToString('o'); inputs = $Inputs; cached = $Cached; builtBy = $OutDir }
    $rec | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $layerDir "$Name.json") -Encoding utf8
    $script:report.layers.created += $Name
    Write-VmtLog "Saved layer $Name"
    Remove-VmtOldLayers
    if ($NoRestart) { return }
    Set-VmtPhase "$kindTag-boot"
    Start-VmtVm
    if ($Kind -eq 'L1') { Wait-VmtGuestUp; Complete-VmtFirstBoot -Where "first boot after saving $Name" -LayerName $Name }
    else { Wait-VmtDesktop }
}

function Sync-VmtInstaller {
    # A restored layer holds the installer of the package that built it; put the current one in.
    Copy-VmtToGuest -LocalPath $Package -GuestName 'playbook.zip'
    $s = Invoke-VmtAgent -Mode SyncApps
    if ($s.Exit -ne 0) { throw "Installer sync failed: $(if ($s.Data) { $s.Data.error } else { $s.Raw })" }
    Write-VmtLog "Installer synced into the layer: $($s.Data.copied.Count) file(s), INSTALL-APPS.ps1 $($s.Data.installerSha256.Substring(0, 12))"
}

function Test-VmtTweaksClean {
    $t = $script:report.tweaks
    return ($t -and $t.counts.failed -eq 0 -and $t.counts.unconfirmed -eq 0 -and $t.engineResult -eq 'success')
}

function Test-VmtEndState {
    # Run after a boot that follows an apply. The tweak counts cannot show a failed servicing commit: when
    # the Revision CBS removal packages roll back at that boot ("Something didn't go as planned, undoing
    # changes") every tweak still reads as applied, but Defender, OneDrive and telemetry are all still there.
    param([string]$Where, [string]$LayerName, [int]$SettleSec = 420)
    # CBS commits (or rolls back) a while after the guest starts answering, so ask until the answer is
    # final: a rollback was logged, or nothing is pending and every Revision package is Installed.
    $r = $null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $a = Invoke-VmtAgent -Mode EndState -TimeoutSec 180
        if ($a.Exit -eq 0 -and $a.Data) {
            $r = $a.Data
            $open = @(@($r.packages) | Where-Object { $_.state -ne 'Installed' }).Count
            if ($r.rolledBack -or ($r.pendingPackages -eq 0 -and $open -eq 0)) { break }
        }
        else { Write-VmtLog "End-state check: $(if ($a.Data) { $a.Data.error } else { $a.Raw })" }   # e.g. the guest is restarting
        if ($sw.Elapsed.TotalSeconds -ge $SettleSec) { break }
        Start-Sleep -Seconds 4
    }
    if (-not $r) { $script:report.harnessErrors += "end-state check could not run ($Where)"; return }
    $packages = @($r.packages)
    $notInstalled = @($packages | Where-Object { $_.state -ne 'Installed' })
    $status = if ($r.rolledBack -or $notInstalled.Count -gt 0) { 'failed' } elseif ($packages.Count -eq 0) { 'no-packages' } else { 'ok' }
    $script:report.endState = [ordered]@{
        status = $status; checkedAt = $Where; bootTime = $r.bootTime; packages = $packages; rolledBack = $r.rolledBack
        rollbackLines = $r.rollbackLines; pendingPackages = $r.pendingPackages; services = $r.services; msMpEngPresent = $r.msMpEngPresent
    }
    $svc = ($r.services.Keys | ForEach-Object { "$_=$($r.services[$_])" }) -join ' '
    Write-VmtLog "End state ($Where): $status - $(@($packages | Where-Object { $_.state -eq 'Installed' }).Count) of $($packages.Count) Revision package(s) installed, rolled back: $($r.rolledBack), pending: $($r.pendingPackages); $svc; MsMpEng.exe present: $($r.msMpEngPresent)"
    if ($status -eq 'failed') {
        foreach ($p in $notInstalled) { Write-VmtLog "  NOT COMMITTED $($p.name): $($p.state)" }
        foreach ($l in $r.rollbackLines) { Write-VmtLog "  CBS: $l" }
        Get-VmtServicingDiag -Where $Where
        # A layer whose first boot rolled the removal back must not be reused as if it were good.
        if ($LayerName) {
            $path = Join-Path $layerDir "$LayerName.json"
            $rec = Get-VmtLayerRecord $LayerName
            if ($rec) {
                $rec.endState = $script:report.endState
                $rec | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding utf8
                Write-VmtLog "  Layer $LayerName is marked unusable; the next run rebuilds it"
            }
        }
    }
}

function Get-VmtGuestFileNames([string]$GuestDir) {
    $r = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\cmd.exe' -Arguments @('/c', 'dir', '/b', '/a-d', $GuestDir) -TimeoutSec 60 -AllowFailure
    return @($r.Stdout -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Push-VmtDownloadCache {
    # -CacheDownloads: GitHub release assets INSTALL-APPS fetched before go in, so it skips the
    # download when the release digest still matches (see its -DownloadCache).
    New-VmtGuestDirectory $dlCacheGuest
    $present = Get-VmtGuestFileNames $dlCacheGuest
    $files = @(Get-ChildItem -LiteralPath $dlCacheHost -File -ErrorAction SilentlyContinue | Where-Object { $present -notcontains $_.Name })
    foreach ($f in $files) {
        Send-VmtFile -LocalPath $f.FullName -GuestPath "$dlCacheGuest\$($f.Name)"
        $got = Get-VmtGuestSha256 -GuestPath "$dlCacheGuest\$($f.Name)"
        if ($got -ne (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) { throw "Hash mismatch copying cached $($f.Name) to the guest" }
    }
    Write-VmtLog "Download cache: $($files.Count) file(s) copied in, $($present.Count) already in the guest"
}

function Get-VmtWingetInstaller([string]$Id) {
    # What the host's winget would install by default: same CPU and OS family as the guest, so
    # normally the same installer. A mismatch only means winget downloads it as usual.
    $r = Invoke-VmtProcess -FilePath 'winget.exe' -ArgumentList @('show', '--id', $Id, '--exact', '--source', 'winget',
        '--accept-source-agreements', '--disable-interactivity') -TimeoutSec 120
    $ver = [regex]::Match($r.Stdout, '(?m)^Version:\s*(\S+)').Groups[1].Value
    $url = [regex]::Match($r.Stdout, '(?m)Installer Url:\s*(\S+)').Groups[1].Value
    $sha = [regex]::Match($r.Stdout, '(?m)Installer SHA256:\s*([0-9a-fA-F]{64})').Groups[1].Value.ToLowerInvariant()
    if (-not $ver -or -not $url -or -not $sha) { return $null }
    return [pscustomobject]@{ Id = $Id; Version = $ver; Url = $url; Sha256 = $sha }
}

function Save-VmtDownload {
    # Invoke-WebRequest, and for a github.com release asset that fails, the API asset endpoint
    # (github.com/.../releases/download is a separate edge from api.github.com and has returned 504 for
    # every asset while the API kept working). The caller verifies the hash.
    param([string]$Url, [string]$OutFile)
    $progress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        try { Invoke-WebRequest -Uri $Url -OutFile $OutFile; return }
        catch {
            $m = [regex]::Match($Url, '^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/?]+)$')
            if (-not $m.Success) { throw }
            $err = $_.Exception.Message
        }
        $headers = @{ 'User-Agent' = 'vmtest'; 'Accept' = 'application/vnd.github+json' }
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($m.Groups[1].Value)/releases/tags/$([uri]::UnescapeDataString($m.Groups[2].Value))" -Headers $headers
        $asset = @($rel.assets | Where-Object { $_.name -eq [uri]::UnescapeDataString($m.Groups[3].Value) }) | Select-Object -First 1
        if (-not $asset) { throw "release asset not found through the API after: $err" }
        Write-VmtLog "  $($m.Groups[3].Value): direct download failed, fetching through the GitHub API"
        Invoke-WebRequest -Uri $asset.url -OutFile $OutFile -Headers @{ 'User-Agent' = 'vmtest'; 'Accept' = 'application/octet-stream' }
    }
    finally { $ProgressPreference = $progress }
}

function Push-VmtWingetCache {
    # winget reuses an installer already at %TEMP%\WinGet\<Id>.<Version>\<sha256> when its hash
    # matches ("Existing installer file hash matches"), so pre-seed those from the host's cache.
    $appsSrc = Join-Path $OutDir 'package\Executables\Apps'
    if (-not (Test-Path -LiteralPath $appsSrc)) { $appsSrc = Join-Path $repoRoot 'src\Executables\Apps' }
    $lists = if ($AppsGroups -contains 'all') { @(Get-ChildItem -LiteralPath $appsSrc -Filter '*.json' -File) }
             else { @($AppsGroups | ForEach-Object { Get-Item -LiteralPath (Join-Path $appsSrc "$_.json") -ErrorAction SilentlyContinue }) }
    $ids = @(foreach ($l in $lists) {
        $j = Get-Content -LiteralPath $l.FullName -Raw | ConvertFrom-Json
        foreach ($src in @($j.Sources | Where-Object { $_.SourceDetails.Name -eq 'winget' })) { $src.Packages.PackageIdentifier }
    }) | Select-Object -Unique
    $tempRun = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\cmd.exe' -Arguments @('/c', 'echo', '%TEMP%') -TimeoutSec 30
    $guestTemp = ($tempRun.Stdout -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim().Trim('"')
    $seeded = 0; $bytes = [long]0; $skipped = @()
    foreach ($id in $ids) {
        $inst = Get-VmtWingetInstaller $id
        if (-not $inst) { $skipped += $id; continue }
        $localDir = Join-Path $dlCacheHost "winget\$id.$($inst.Version)"
        $local = Join-Path $localDir $inst.Sha256
        if (-not (Test-Path -LiteralPath $local)) {
            New-Item -ItemType Directory -Force -Path $localDir | Out-Null
            try {
                Save-VmtDownload -Url $inst.Url -OutFile $local
                if ((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant() -ne $inst.Sha256) { throw 'hash mismatch' }
            }
            catch {
                # Leave no empty version folder behind: it looks like a cache hit.
                Remove-Item -LiteralPath $localDir -Recurse -Force -ErrorAction SilentlyContinue
                $skipped += $id; continue
            }
        }
        $guestDir = "$guestTemp\WinGet\$id.$($inst.Version)"
        New-VmtGuestDirectory $guestDir
        Send-VmtFile -LocalPath $local -GuestPath "$guestDir\$($inst.Sha256)"
        $seeded++; $bytes += (Get-Item -LiteralPath $local).Length
    }
    Write-VmtLog ("winget cache: {0} of {1} installer(s) pre-seeded ({2:N0} MB){3}" -f $seeded, $ids.Count, ($bytes / 1MB),
        $(if ($skipped.Count) { "; not cached: $($skipped -join ', ')" } else { '' }))
}

function Receive-VmtDownloadCache {
    New-Item -ItemType Directory -Force -Path $dlCacheHost | Out-Null
    $new = @(Get-VmtGuestFileNames $dlCacheGuest | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dlCacheHost $_)) })
    foreach ($name in $new) {
        Copy-VmtFromGuest -GuestPath "$dlCacheGuest\$name" -ExpectedSha256 (Get-VmtGuestSha256 -GuestPath "$dlCacheGuest\$name") -LocalDir $dlCacheHost | Out-Null
    }
    if ($new.Count) { Write-VmtLog "Download cache: $($new.Count) new file(s) saved to $dlCacheHost" }
}

function Invoke-VmtApps {
    Set-VmtPhase 'apps-seed'
    $groupsFile = Join-Path $OutDir 'apps-groups.txt'
    [IO.File]::WriteAllLines($groupsFile, [string[]]$AppsGroups)
    Copy-VmtToGuest -LocalPath $groupsFile -GuestName 'apps-groups.txt'
    if ($CacheDownloads) {
        Push-VmtDownloadCache
        # An L2 layer already has these apps installed, so winget will not download anything.
        if ($startFrom -ne 'L2') {
            try { Push-VmtWingetCache } catch { Write-VmtLog "winget cache skipped: $($_.Exception.Message)" }
        }
    }
    Set-VmtPhase 'apps-run'
    $start = Invoke-VmtAgent -Mode Start -Job apps
    if ($start.Exit -ne 0) {
        $script:report.apps = [ordered]@{ status = 'failed-to-start'; error = $(if ($start.Data) { $start.Data.error } else { $start.Raw }) }
        return
    }
    Write-VmtLog "Apps ($($AppsGroups -join ',')) started as $($start.Data.runAs); timeout $AppsTimeoutMin min"
    $script:report.apps = Wait-VmtJob -Job apps -TimeoutMin $AppsTimeoutMin
    $script:report.apps.groups = $AppsGroups
    Write-VmtLog "Apps finished: $($script:report.apps.status) after $($script:report.apps.durationSec)s"
    if ($CacheDownloads -and (Get-VmtVmState) -eq 'running') {
        Set-VmtPhase 'apps-cache-pull'
        try { Receive-VmtDownloadCache } catch { Write-VmtLog "Download cache pull failed: $($_.Exception.Message)" }
    }
}

function Get-VmtLogs {
    $col = Invoke-VmtAgent -Mode Collect
    if ($col.Exit -ne 0) { throw "Log collection failed: $(if ($col.Data) { $col.Data.error } else { $col.Raw })" }
    if ($col.Data.errors.Count) { Write-VmtLog "Collect warnings: $($col.Data.errors -join '; ')" }
    $zip = Copy-VmtFromGuest -GuestPath $col.Data.zip -ExpectedSha256 $col.Data.sha256 -LocalDir $OutDir
    $logsDir = Join-Path $OutDir 'logs'
    if (Test-Path -LiteralPath $logsDir) { Remove-Item -LiteralPath $logsDir -Recurse -Force }
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $logsDir)
    Write-VmtLog "Logs pulled to $logsDir (sha256 verified)"
    return $logsDir
}

function Add-VmtAppsSummary {
    param([string]$LogsDir)
    if ($script:report.apps.status -eq 'not-run') { return }
    $stdout = Join-Path $LogsDir 'jobs\apps\stdout.txt'
    if (Test-Path -LiteralPath $stdout) { $script:report.apps.summary = Get-VmtAppsSummary -Stdout $stdout }
    $a = $script:report.apps.summary
    if (-not $a) { Write-VmtLog 'Apps: no summary block in the INSTALL-APPS output'; return }
    Write-VmtLog ("Apps: {0} installed, {1} already present, {2} failed, {3} of {4} default-app types set" -f $a.installed, $a.alreadyInstalled, $a.failed.Count, $a.defaultAppTypes, $a.defaultAppTotal)
    foreach ($f in $a.failed) { Write-VmtLog "  APP FAIL $f" }
    foreach ($n in $a.notSet) { Write-VmtLog "  default app not set: $n" }
    foreach ($n in $a.noHandler) { Write-VmtLog "  no handler: $n" }
    if ($a.rebootToFinish.Count) { Write-VmtLog "  reboot to finish: $($a.rebootToFinish -join ', ')" }
}

function Complete-VmtReport {
    param([int]$ExitCode)
    Set-VmtPhase $null
    try {
        $script:report.phases = @(Get-VmtPhaseTimeline)
        $total = [math]::Round((@($script:report.phases | ForEach-Object { [double]$_.durationSec }) | Measure-Object -Sum).Sum, 0)
        Write-VmtLog "Timeline ($total s in phases):"
        foreach ($ph in $script:report.phases) {
            $r = $ph.resources
            $use = if ($r) { '  cpu {0}% avg / {1}% max, disk r {2} w {3} MB/s' -f $r.cpuAvgPct, $r.cpuMaxPct, $r.diskReadAvgMBps, $r.diskWriteAvgMBps } else { '' }
            Write-VmtLog ('  {0,-22}{1,5} s{2}' -f $ph.name, $ph.durationSec, $use)
        }
    }
    catch { Write-VmtLog "Timeline could not be built: $($_.Exception.Message)" }
    $script:report.finishedAt = (Get-Date).ToString('o')
    $script:report.result = switch ($ExitCode) { 0 { 'pass' } 1 { 'fail' } default { 'harness-error' } }
    $script:report.exitCode = $ExitCode
    $script:report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'summary.json') -Encoding utf8
    $t = $script:report.tweaks
    if ($t) {
        Write-VmtLog ("Tweaks: {0} applied, {1} failed, {2} skipped, {3} unconfirmed (engine: {4})" -f $t.counts.applied, $t.counts.failed, $t.counts.skipped, $t.counts.unconfirmed, $t.engineResult)
        foreach ($f in @($t.failed | Select-Object -First 25)) { Write-VmtLog "  FAIL $($f.id) $($f.description) -> $($f.error)" }
    }
    Write-VmtLog "Apply: $($script:report.apply.status); revert: $($script:report.revert.status); apps: $($script:report.apps.status); result: $($script:report.result) (exit $ExitCode)"
    Write-VmtLog "Summary: $(Join-Path $OutDir 'summary.json')"
    exit $ExitCode
}

function Get-VmtExitCode {
    $failed = $false
    if ($script:report.apply.status -ne 'completed') { $failed = $true }
    if ($script:report.tweaks -and $script:report.tweaks.counts.failed -gt 0) { $failed = $true }
    if (-not $script:report.tweaks) { $failed = $true }
    if ($script:report.apply.status -eq 'completed' -and $script:report.apply.exitCode -ne 0) { $failed = $true }
    if ($script:report.tweaks -and $script:report.tweaks.engineResult -ne 'success') { $failed = $true }
    if ($script:report.tweaks -and $script:report.tweaks.counts.unconfirmed -gt 0) { $failed = $true }
    # The servicing queued by the apply must have committed at the first boot (see Test-VmtEndState).
    if ($script:report.endState -and $script:report.endState.status -eq 'failed') { $failed = $true }
    # What the playbook should have left behind must be on the machine (differences in endstate-known.json aside).
    if ($script:report.liveState.status -eq 'failed') { $failed = $true }
    # The component store must still be clean after the apply (the canary, Invoke-VmtStoreHealth).
    if (@('repairable', 'not-repairable') -contains $script:report.storeHealth.status) { $failed = $true }
    if ($script:report.tweaks -and $script:report.tweaks.counts.misaligned -gt 0) {
        # Log/plan pairing drifted, so per-action verdicts can't be trusted.
        if ($script:report.harnessErrors -notcontains 'log pairing misaligned') { $script:report.harnessErrors += 'log pairing misaligned' }
    }
    if ($AppsOnly) {
        # Only the app install ran; the apply verdict belongs to the earlier run.
        if ($script:report.harnessErrors.Count -gt 0) { return 2 }
        if ($script:report.apps.status -ne 'completed' -or -not $script:report.apps.summary -or
            $script:report.apps.summary.failed.Count -gt 0) { return 1 }
        return 0
    }
    if ($AppsGroups -and ($script:report.apps.status -ne 'completed' -or -not $script:report.apps.summary -or
        $script:report.apps.summary.failed.Count -gt 0)) { $failed = $true }
    if (@('not-run', 'completed') -notcontains $script:report.revert.status) { $failed = $true }
    if ($script:report.revert.status -eq 'completed' -and $script:report.revert.exitCode -ne 0) { $failed = $true }
    if ($script:report.harnessErrors.Count -gt 0) { return 2 }
    if ($failed) { return 1 }
    return 0
}

# --------------------------------------------------------------------------- parse-only
if ($ParseOnly) {
    $logsDir = Join-Path $OutDir 'logs'
    $optFile = Join-Path $OutDir 'options.txt'
    $prev = Join-Path $OutDir 'summary.json'
    if (Test-Path -LiteralPath $prev) {
        $old = Get-Content -LiteralPath $prev -Raw | ConvertFrom-Json -AsHashtable
        foreach ($k in 'package', 'options', 'precheck', 'apply', 'revert', 'endState') { if ($old.Contains($k)) { $script:report[$k] = $old[$k] } }
    }
    $configDir = if (Test-Path -LiteralPath (Join-Path $OutDir 'config')) { Join-Path $OutDir 'config' } else { Join-Path $repoRoot 'src\Configuration' }
    $script:report.tweaks = Invoke-VmtSummarize -ConfigDir $configDir -OptionsFile $optFile -LogsDir $logsDir
    Complete-VmtReport -ExitCode (Get-VmtExitCode)
}

# --------------------------------------------------------------------------- clear layers
if ($ClearLayers) {
    try {
        Stop-VmtVm
        foreach ($f in @(Get-ChildItem -LiteralPath $layerDir -Filter 'vmtest-L1-*.json' -File -ErrorAction SilentlyContinue)) {
            Remove-VmtLayer $f.BaseName
        }
        # Snapshots whose record went missing.
        foreach ($name in @((Get-VmtSnapshots).Keys | Where-Object { $_ -match '^vmtest-L2-' }) + @((Get-VmtSnapshots).Keys | Where-Object { $_ -match '^vmtest-L1-' })) {
            Remove-VmtLayer $name
        }
        Write-VmtLog 'All vmtest layers removed'
        exit 0
    }
    catch { Write-VmtLog "HARNESS ERROR: $($_.Exception.Message)"; exit 2 }
}

# --------------------------------------------------------------------------- full run
if (-not $GuestPassword) { throw 'Set -GuestPassword or $env:VMTEST_GUEST_PASSWORD (guest account password)' }

Start-VmtWatchdog
try { $script:report.provenance = Get-VmtProvenance }
catch { Write-VmtLog "Provenance could not be captured: $($_.Exception.Message)" }

if ($AppsOnly) {
    Set-VmtPhase 'apps-only'
    if (-not $AppsGroups) { $AppsGroups = @('all') }
    try {
        if ((Get-VmtVmState) -ne 'running') { throw "-AppsOnly needs $VMName running with the playbook already applied (e.g. a -KeepRunning run)" }
        Wait-VmtGuestReady
        # The extracted package in C:\vmtest\pb is the one the earlier apply used.
        Copy-VmtToGuest -LocalPath $agentLocal -GuestName 'guest-agent.ps1'
        Restart-VmtGuest
        Invoke-VmtApps
        Add-VmtAppsSummary -LogsDir (Get-VmtLogs)
    }
    catch {
        $script:report.harnessErrors += "$($_.Exception.Message)"
        Write-VmtLog "HARNESS ERROR: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    }
    finally {
        if (-not $KeepRunning) { try { Stop-VmtVm } catch { Write-VmtLog "Power-off failed: $($_.Exception.Message)" } }
    }
    Complete-VmtReport -ExitCode (Get-VmtExitCode)
}

try {
    Assert-VmtBackend
    if (-not (Get-VmtSnapshots).ContainsKey($Snapshot)) {
        throw "Snapshot '$Snapshot' not found on $VMName"
    }

    Set-VmtPhase 'build'
    if ($Build) {
        & (Join-Path $PSScriptRoot 'build-package.ps1')
        if (-not $?) { throw 'build-package.ps1 failed' }
    }
    Set-VmtPhase 'setup'
    if (-not $Package) { $Package = Join-Path $repoRoot 'out\build\playbook.zip' }
    if (-not (Test-Path -LiteralPath $Package)) { throw "Package not found: $Package (run with -Build)" }
    $Package = (Resolve-Path -LiteralPath $Package).Path
    $script:report.package = [ordered]@{ path = $Package; sha256 = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash }
    $buildInfo = Join-Path (Split-Path -Parent $Package) 'build.json'
    if (Test-Path -LiteralPath $buildInfo) { $script:report.package.build = Get-Content -LiteralPath $buildInfo -Raw | ConvertFrom-Json -AsHashtable }

    # Keep the exact Configuration that was tested next to its logs, for -ParseOnly later.
    $configCopy = Join-Path $OutDir 'config'
    # A reused -OutDir must not keep a stale copy: Copy-Item would nest the new one inside it.
    foreach ($stale in $configCopy, (Join-Path $OutDir 'package')) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
    }
    Expand-Archive -LiteralPath $Package -DestinationPath (Join-Path $OutDir 'package') -Force
    Copy-Item -LiteralPath (Join-Path $OutDir 'package\Configuration') -Destination $configCopy -Recurse -Force
    if (-not $Options) { $Options = Get-VmtDefaultOptions -ConfPath (Join-Path $OutDir 'package\playbook.conf') }
    $script:report.options = $Options
    $optFile = Join-Path $OutDir 'options.txt'
    [IO.File]::WriteAllLines($optFile, [string[]]$Options)
    Write-VmtLog "Options: $($Options -join ' ')"
    $cli = Get-VmtCliZip

    $startFrom = 'base'; $l1Name = $null; $l2Name = $null; $l1Saved = $false
    if ($Layers) {
        $pkgDir = Join-Path $OutDir 'package'
        $snapsNow = Get-VmtSnapshots
        $l1Inputs = [ordered]@{
            baseSnapshot = $Snapshot; baseUuid = $snapsNow[$Snapshot]; cliSha256 = (Get-FileHash -LiteralPath $cli -Algorithm SHA256).Hash
            options = @($Options | Sort-Object)
            package = Get-VmtTreeHash -Root $pkgDir -Include { param($p) -not (& $isInstallerInput $p) }
        }
        $l1Key = Get-VmtSha256Text ($l1Inputs | ConvertTo-Json -Compress)
        $l1Name = 'vmtest-L1-' + $l1Key.Substring(0, 12).ToLowerInvariant()
        if ($AppsGroups) {
            $l2Inputs = [ordered]@{
                l1 = $l1Key; groups = @($AppsGroups | Sort-Object)
                installerInputs = Get-VmtTreeHash -Root $pkgDir -Include $isInstallerInput
            }
            $l2Key = Get-VmtSha256Text ($l2Inputs | ConvertTo-Json -Compress)
            $l2Name = 'vmtest-L2-' + $l2Key.Substring(0, 12).ToLowerInvariant()
        }
        if (-not $RebuildLayers) {
            if ($l2Name -and -not $FreshApps -and (Test-VmtLayer -Name $l2Name -Snapshots $snapsNow -MaxAgeHours $AppsLayerMaxAgeHours)) { $startFrom = 'L2' }
            elseif (Test-VmtLayer -Name $l1Name -Snapshots $snapsNow) { $startFrom = 'L1' }
        }
        $script:report.layers.l1 = $l1Name
        $script:report.layers.l2 = $l2Name
        $script:report.layers.startFrom = $startFrom
        Write-VmtLog "Layers: L1 $l1Name$(if ($l2Name) { ", L2 $l2Name" }); starting from $(if ($startFrom -eq 'base') { "'$Snapshot' (no usable layer)" } else { $startFrom })"
    }
    $restoreName = switch ($startFrom) { 'L2' { $l2Name } 'L1' { $l1Name } default { $Snapshot } }

    Set-VmtPhase 'restore-boot'
    Stop-VmtVm
    Write-VmtLog "Restoring snapshot '$restoreName'"
    Restore-VmtSnapshot $restoreName
    Start-VmtVm
    # An L1's first boot is the post-apply one, which can run long, and runs with auto-logon off (it holds no
    # desktop until Complete-VmtFirstBoot has verified the servicing commit); L2 holds a settled, logged-on guest.
    switch ($startFrom) { 'base' { Wait-VmtGuestReady } 'L1' { Wait-VmtGuestUp } default { Wait-VmtDesktop } }

    Set-VmtPhase 'copy-inputs'
    $inputFiles = @(@{ LocalPath = $agentLocal; GuestName = 'guest-agent.ps1' })
    if ($startFrom -eq 'base') {
        $inputFiles += @{ LocalPath = $cli; GuestName = 'cli.zip' }, @{ LocalPath = $Package; GuestName = 'playbook.zip' }, @{ LocalPath = $optFile; GuestName = 'options.txt' }
        if ($RevertScript) { $inputFiles += @{ LocalPath = $RevertScript; GuestName = 'revert.ps1' } }
    }
    Copy-VmtToGuestMany -Files $inputFiles

    if ($startFrom -ne 'base') {
        # The layer already holds this apply: report the verdict recorded when it was built.
        $rec = Get-VmtLayerRecord $l1Name
        foreach ($k in 'precheck', 'apply', 'tweaks') { $script:report[$k] = $rec.cached[$k] }
        $script:report.apply.cachedFrom = $l1Name
        Write-VmtLog "Apply reused from $l1Name (built $($rec.created) by $($rec.builtBy)): $($rec.cached.tweaks.counts.applied) applied, $($rec.cached.tweaks.counts.failed) failed"
        if ($startFrom -eq 'L1') { Complete-VmtFirstBoot -Where "first boot of restored $restoreName" -LayerName $l1Name }
        else { Test-VmtEndState -Where "restored $restoreName" -LayerName $l1Name }
        Sync-VmtInstaller
    }
    else {
        if ($AppsGroups) { Write-VmtLog "Apps groups after apply: $($AppsGroups -join ',') (guest needs network)" }

        Set-VmtPhase 'prepare'
        $prep = Invoke-VmtAgent -Mode Prepare
        $script:report.precheck = if ($prep.Data) { $prep.Data } else { @{ error = $prep.Raw } }
        if ($prep.Exit -ne 0) { throw "Guest precheck failed: $(if ($prep.Data) { $prep.Data.error } else { $prep.Raw })" }
        if ($prep.Data.defenderRemediated) { Write-VmtLog 'Defender toggles had turned back on; re-disabled them via Set-MpPreference' }
        Write-VmtLog "Guest build $($prep.Data.osBuild), interactive user $($prep.Data.interactiveUsers -join ',')"

        Set-VmtPhase 'apply'
        $start = Invoke-VmtAgent -Mode Start -Job apply
        if ($start.Exit -ne 0) {
            $script:report.apply = [ordered]@{ status = 'failed-to-start'; error = $(if ($start.Data) { $start.Data.error } else { $start.Raw }) }
        }
        else {
            Write-VmtLog "Apply started as $($start.Data.runAs) via task $($start.Data.task); timeout $ApplyTimeoutMin min"
            $script:report.apply = Wait-VmtJob -Job apply -TimeoutMin $ApplyTimeoutMin
            Write-VmtLog "Apply finished: $($script:report.apply.status) exit=$($script:report.apply.exitCode) after $($script:report.apply.durationSec)s"
        }

        if ($RevertScript -and $script:report.apply.status -eq 'completed') {
            $rs = Invoke-VmtAgent -Mode Start -Job revert
            if ($rs.Exit -ne 0) { $script:report.revert = [ordered]@{ status = 'failed-to-start'; error = $(if ($rs.Data) { $rs.Data.error } else { $rs.Raw }) } }
            else { $script:report.revert = Wait-VmtJob -Job revert -TimeoutMin $RevertTimeoutMin }
            Write-VmtLog "Revert: $($script:report.revert.status)"
        }

        # L1: a clean apply is snapshotted by shutting down in place of the post-apply reboot.
        if ($Layers -and -not $RevertScript -and $script:report.apply.status -eq 'completed' -and
            $script:report.apply.exitCode -eq 0 -and (Get-VmtVmState) -eq 'running') {
            Set-VmtPhase 'apply-logs'
            $script:report.tweaks = Invoke-VmtSummarize -ConfigDir $configCopy -OptionsFile $optFile -LogsDir (Get-VmtLogs)
            if (Test-VmtTweaksClean) {
                Save-VmtLayer -Kind L1 -Name $l1Name -Key $l1Key -Inputs $l1Inputs -Cached ([ordered]@{
                    package = $script:report.package; options = $script:report.options; precheck = $script:report.precheck
                    apply = $script:report.apply; tweaks = $script:report.tweaks })
                $l1Saved = $true   # Save-VmtLayer also took the first boot and verified the commit (Complete-VmtFirstBoot)
            }
            else { Write-VmtLog 'The apply had failures; not caching it as a layer' }
        }
    }

    if ($AppsGroups -and $script:report.apply.status -eq 'completed' -and (Get-VmtVmState) -eq 'running') {
        # A restored layer and a freshly saved L1 have just booted; only an uncached apply needs the reboot.
        if ($startFrom -eq 'base' -and -not $l1Saved) { Set-VmtPhase 'first-boot-reboot'; Restart-VmtGuest -FirstBoot; Complete-VmtFirstBoot -Where 'first boot after the apply' }
        Invoke-VmtApps
    }

    if ((Get-VmtVmState) -eq 'running') {
        Set-VmtPhase 'live-state'
        Invoke-VmtLiveStateCheck -Stage 'final'
        if (-not $NoStoreHealth -and -not $AppsOnly) { Set-VmtPhase 'store-health'; Invoke-VmtStoreHealth }
        Set-VmtPhase 'collect'
        $logsDir = Get-VmtLogs
        if ($startFrom -eq 'base') { $script:report.tweaks = Invoke-VmtSummarize -ConfigDir $configCopy -OptionsFile $optFile -LogsDir $logsDir }
        Add-VmtAppsSummary -LogsDir $logsDir
        $a = $script:report.apps
        if ($l2Name -and $startFrom -ne 'L2' -and ($l1Saved -or $startFrom -eq 'L1') -and $a.status -eq 'completed' -and
            $a.summary -and $a.summary.failed.Count -eq 0 -and $script:report.harnessErrors.Count -eq 0 -and
            -not ($script:report.endState -and $script:report.endState.status -eq 'failed')) {
            Save-VmtLayer -Kind L2 -Name $l2Name -Key $l2Key -Parent $l1Name -Inputs $l2Inputs -Cached ([ordered]@{ apps = $a }) -NoRestart:(-not $KeepRunning)
        }
    }
    else { $script:report.harnessErrors += 'VM not running at collection time; no logs pulled' }
}
catch {
    $script:report.harnessErrors += "$($_.Exception.Message)"
    Write-VmtLog "HARNESS ERROR: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
}
finally {
    Set-VmtPhase 'teardown'
    if (-not $KeepRunning) { try { Stop-VmtVm } catch { Write-VmtLog "Power-off failed: $($_.Exception.Message)" } }
}
Complete-VmtReport -ExitCode (Get-VmtExitCode)
