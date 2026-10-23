#Requires -Version 7
<#
.SYNOPSIS
    Apply the playbook to the VirtualBox test VM headlessly and summarise the result as JSON.

.DESCRIPTION
    1. Restores -Snapshot (offline) and boots the VM headless.
    2. Waits for the guest execution service by probing it (no fixed sleeps).
    3. Copies the guest agent, the AME CLI and the package in with `guestcontrol copyto`, and
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

    With -Layers, finished stages are cached as offline snapshots and reused, like image layers:
      L1 vmtest-L1-<key>  the applied playbook, taken by shutting the guest down instead of the
                          post-apply reboot (so a restore replays that first boot). Key: base snapshot,
                          AME CLI, options, and every package file except the installer and Apps\*.json.
      L2 vmtest-L2-<key>  L1 plus the -AppsGroups installed. Key: L1, the groups and Apps\*.json.
                          Expires after -AppsLayerMaxAgeHours (winget content drifts).
    A hit restores the layer, copies the current INSTALL-APPS files in (as start.yml does), reuses
    the apply verdict recorded when the layer was built, and runs only what is left. -FreshApps skips
    L2 (installer install-logic changes), -RebuildLayers ignores hits, -ClearLayers deletes them all.
    Records live in out\vmtest\layers\<name>.json. A change is only "done" after an uncached run.

    Only `guestcontrol` drives the guest; no keyboard injection. See AGENTS.md, "VM testing".

.EXAMPLE
    $env:VMTEST_GUEST_PASSWORD = '...'; pwsh tools\vmtest.ps1 -Build
.EXAMPLE
    pwsh tools\vmtest.ps1 -ParseOnly out\vmtest\20261021-140000
#>
[CmdletBinding()]
param(
    [string]$VMName = 'windowstest',
    [string]$Snapshot = 'clean-defender-off-UAC-off',
    [string]$GuestUser = $(if ($env:VMTEST_GUEST_USER) { $env:VMTEST_GUEST_USER } else { 'vboxuser' }),
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
    [int]$KeepLayers = 2,
    [switch]$CacheDownloads,
    # VirtualBox on a Hyper-V host (NEM) sometimes freezes the guest: no disk I/O this long = hung.
    [int]$StallSec = 360,
    [string]$ParseOnly
)

$ErrorActionPreference = 'Stop'
# Through pwsh -File, "-AppsGroups a,b" arrives as one string.
$AppsGroups = @($AppsGroups | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$agentLocal = Join-Path $PSScriptRoot 'vmtest\guest-agent.ps1'
$amelog = Join-Path $PSScriptRoot 'vmtest\amelog.py'
$vbm = Join-Path ${env:ProgramFiles} 'Oracle\VirtualBox\VBoxManage.exe'
$guestRoot = 'C:\vmtest'
$guestIn = 'C:\vmtest\in'
$guestPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$layerDir = Join-Path $repoRoot 'out\vmtest\layers'
$dlCacheHost = Join-Path $repoRoot 'tools\cache\downloads'
$dlCacheGuest = 'C:\vmtest\dl'
# Package files INSTALL-APPS runs from; start.yml copies them to ProgramData, so they are left out
# of the L1 key and copied fresh into a restored layer.
$installerFiles = @('Executables/INSTALL-APPS.cmd', 'Executables/INSTALL-APPS.ps1')
$appsListPrefix = 'Executables/Apps/'

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
    layers = [ordered]@{ enabled = [bool]$Layers; startFrom = 'base'; created = @() }
    hangs = @()
    harnessErrors = @()
    result = $null
}

function Write-VmtLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    Add-Content -LiteralPath $harnessLog -Value $line
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

function Invoke-VmtVBox {
    param([string[]]$ArgumentList, [int]$TimeoutSec = 120, [switch]$AllowFailure)
    $r = Invoke-VmtProcess -FilePath $vbm -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec
    # Shortly after boot, guestcontrol can briefly fail to start a session ("current status is:
    # starting"); the command never ran, so retry it for up to 3 minutes. Probes (-AllowFailure)
    # have their own wait loops and stall checks.
    $deadline = (Get-Date).AddMinutes(3)
    while (-not $AllowFailure -and $ArgumentList[0] -eq 'guestcontrol' -and $r.Code -ne 0 -and
           $r.Stderr -match 'Error starting guest session' -and
           (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $r = Invoke-VmtProcess -FilePath $vbm -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec
    }
    if (-not $AllowFailure -and $r.Code -ne 0) {
        throw "VBoxManage $($ArgumentList[0..([Math]::Min(2, $ArgumentList.Count - 1))] -join ' ') failed ($($r.Code)): $($r.Stderr.Trim())"
    }
    return $r
}

function Get-VmtCredArgs { return @('--username', $GuestUser, '--passwordfile', $script:passwordFile) }

function Invoke-VmtGuestRun {
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 120, [switch]$AllowFailure)
    # VBoxManage 7.x passes everything after `--` as arguments (no argv[0] slot): an extra
    # leading program name is tolerated by cmd/powershell but breaks certutil.
    $list = @('guestcontrol', $VMName, 'run') + (Get-VmtCredArgs) +
        @('--exe', $Exe, '--timeout', [string]($TimeoutSec * 1000), '--wait-stdout', '--wait-stderr', '--') + $Arguments
    # The host-side timeout is a little longer, so a wedged VBoxManage is still killed.
    return Invoke-VmtVBox -ArgumentList $list -TimeoutSec ($TimeoutSec + 30) -AllowFailure:$AllowFailure
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

function Get-VmtVmState {
    $r = Invoke-VmtVBox -ArgumentList @('showvminfo', $VMName, '--machinereadable')
    $m = [regex]::Match($r.Stdout, '(?m)^VMState="([^"]+)"')
    if (-not $m.Success) { throw "Cannot read VMState of $VMName" }
    return $m.Groups[1].Value
}

function Wait-VmtVmState {
    param([string[]]$Wanted, [int]$TimeoutSec = 120)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        # Right after its process is killed, the session is torn down and showvminfo can fail with
        # RPC_S_CALL_FAILED for a moment; keep asking.
        try { $state = Get-VmtVmState } catch { $state = $null }
        if ($state -and $Wanted -contains $state) { return $state }
        Start-Sleep -Seconds 2
    }
    throw "VM did not reach state $($Wanted -join '/') within ${TimeoutSec}s (now $(Get-VmtVmState))"
}

function Stop-VmtVm {
    $state = Get-VmtVmState
    if (@('poweroff', 'aborted', 'saved') -notcontains $state) {
        Write-VmtLog "Powering off $VMName (state $state)"
        Invoke-VmtVBox -ArgumentList @('controlvm', $VMName, 'poweroff') -AllowFailure | Out-Null
        Wait-VmtVmState -Wanted @('poweroff', 'aborted') | Out-Null
    }
}

# ------------------------------------------------------------------------- hang detection
function Get-VmtDiskBytes {
    $r = Invoke-VmtVBox -ArgumentList @('debugvm', $VMName, 'statistics', '--pattern', '/Public/Storage/*/Port*/Bytes*') -TimeoutSec 60 -AllowFailure
    $sum = [long]0
    foreach ($m in [regex]::Matches($r.Stdout, 'c="(\d+)"')) { $sum += [long]$m.Groups[1].Value }
    return $sum
}

function New-VmtStallWatch { return @{ bytes = (Get-VmtDiskBytes); since = [Diagnostics.Stopwatch]::StartNew() } }

function Test-VmtStalled([hashtable]$Watch) {
    # True once the guest has done no disk I/O for -StallSec. A rebooting or working guest always
    # touches its disk; the NEM freezes leave busy vCPUs and a frozen clock with none at all.
    $now = Get-VmtDiskBytes
    if ($now -ne $Watch.bytes) { $Watch.bytes = $now; $Watch.since.Restart(); return $false }
    return ($Watch.since.Elapsed.TotalSeconds -ge $StallSec)
}

function Get-VmtVmPid {
    # VBox.log of the running session records its VBoxHeadless process ID.
    $info = (Invoke-VmtVBox -ArgumentList @('showvminfo', $VMName, '--machinereadable')).Stdout
    $cfg = [regex]::Match($info, '(?m)^CfgFile="(.*)"\r?$').Groups[1].Value.Replace('\\', '\')
    $log = Join-Path (Split-Path -Parent $cfg) 'Logs\VBox.log'
    $m = Select-String -LiteralPath $log -Pattern 'Process ID: (\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $m) { throw "No process ID in $log" }
    return [int]$m.Matches[0].Groups[1].Value
}

function Reset-VmtHungVm([string]$Where, [string]$Reason = "no disk I/O for ${StallSec}s") {
    # `controlvm poweroff` and reset can wedge on a frozen NEM guest; killing its process does not.
    # VBox.log of such a hang typically shows "AHCI#0: Port 0 reset" then a flatlined guest heartbeat.
    $vmPid = Get-VmtVmPid
    Write-VmtLog "Guest hung during $Where ($Reason); killing VBoxHeadless $vmPid and booting again"
    $script:report.hangs += [ordered]@{ where = $Where; reason = $Reason; at = (Get-Date).ToString('o') }
    Stop-Process -Id $vmPid -Force -ErrorAction SilentlyContinue
    Wait-VmtVmState -Wanted @('aborted', 'poweroff') | Out-Null
    Invoke-VmtVBox -ArgumentList @('startvm', $VMName, '--type', 'headless') -TimeoutSec 300 | Out-Null
}

function Wait-VmtGuestReady {
    # Guest properties survive a snapshot restore, so they can't prove readiness; a real
    # round-trip through the execution service can. Match the exact token, not "ready":
    # the not-ready error text contains that word.
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $last = ''
    while ($sw.Elapsed.TotalSeconds -lt $BootTimeoutSec) {
        $r = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\cmd.exe' -Arguments @('/c', 'echo', 'VMTEST_OK') -TimeoutSec 30 -AllowFailure
        if ($r.Code -eq 0 -and (($r.Stdout -split "`r?`n") -contains 'VMTEST_OK')) {
            $users = Invoke-VmtVBox -ArgumentList @('guestproperty', 'get', $VMName, '/VirtualBox/GuestInfo/OS/LoggedInUsers') -AllowFailure
            $m = [regex]::Match($users.Stdout, 'Value:\s*(\d+)')
            if ($m.Success -and [int]$m.Groups[1].Value -gt 0) {
                Write-VmtLog "Guest ready after $([int]$sw.Elapsed.TotalSeconds)s ($($m.Groups[1].Value) user(s) logged in)"
                return
            }
            $last = 'execution service up, waiting for an interactive logon'
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
    # copyto names the target after the source, so stage under the wanted name first.
    $stage = Join-Path $OutDir "upload\$GuestName"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stage) | Out-Null
    Copy-Item -LiteralPath $LocalPath -Destination $stage -Force
    Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'copyto') + (Get-VmtCredArgs) + @('--target-directory', "$guestIn\", $stage)) -TimeoutSec 900 | Out-Null
    # certutil can come back empty on a guest busy right after boot (Store updates): ask again.
    $got = $null
    for ($try = 1; $try -le 4 -and -not $got; $try++) {
        $got = Get-VmtGuestSha256 -GuestPath $guestPath
        if (-not $got) { Start-Sleep -Seconds 5 }
    }
    if ($got -ne $want) { throw "Hash mismatch after copying $GuestName to the guest (host $want, guest $got)" }
    Write-VmtLog "Copied $GuestName -> $guestPath (sha256 verified)"
}

function Copy-VmtFromGuest {
    param([string]$GuestPath, [string]$ExpectedSha256, [string]$LocalDir)
    New-Item -ItemType Directory -Force -Path $LocalDir | Out-Null
    $target = (Join-Path $LocalDir (Split-Path -Leaf $GuestPath))
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    # copyfrom needs the trailing backslash on the host directory.
    Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'copyfrom') + (Get-VmtCredArgs) + @('--target-directory', ($LocalDir.TrimEnd('\') + '\'), $GuestPath)) -TimeoutSec 900 | Out-Null
    $got = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
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
            if (-not $watch) { $watch = New-VmtStallWatch }
            elseif (Test-VmtStalled $watch) {
                Reset-VmtHungVm "$Job job"
                Wait-VmtDesktop
                $script:report.harnessErrors += "The guest froze during the $Job job (VirtualBox NEM on a Hyper-V host); rerun"
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
    $before = Invoke-VmtAgent -Mode Probe -TimeoutSec 120
    if ($null -eq $before.Exit) { throw "Guest probe failed before reboot: $($before.Raw)" }
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
        if ($p.Data.bootTime -ne $before.Data.bootTime -and @($p.Data.interactiveUsers).Count -gt 0) {
            Write-VmtLog "Guest rebooted (booted $($p.Data.bootTime)) and $($p.Data.interactiveUsers -join ',') has a desktop after $([int]$sw.Elapsed.TotalSeconds)s"
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

# ------------------------------------------------------------------------- snapshot layers
function Get-VmtSnapshots {
    # name -> UUID, from `snapshot list --machinereadable` (SnapshotName-1-2="..." / SnapshotUUID-1-2="...").
    $r = Invoke-VmtVBox -ArgumentList @('snapshot', $VMName, 'list', '--machinereadable') -AllowFailure
    $names = @{}; $uuids = @{}
    foreach ($m in [regex]::Matches($r.Stdout, '(?m)^Snapshot(Name|UUID)((?:-\d+)*)="([^"]*)"\r?$')) {
        if ($m.Groups[1].Value -eq 'Name') { $names[$m.Groups[2].Value] = $m.Groups[3].Value } else { $uuids[$m.Groups[2].Value] = $m.Groups[3].Value }
    }
    $map = @{}
    foreach ($k in $names.Keys) { $map[$names[$k]] = $uuids[$k] }
    return $map
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
    if ($MaxAgeHours -gt 0 -and ([datetime]$rec.created) -lt (Get-Date).AddHours(-$MaxAgeHours)) {
        Write-VmtLog "Layer $Name is older than $MaxAgeHours h; rebuilding it"
        return $false
    }
    return $true
}

function Remove-VmtLayer([string]$Name) {
    # Children first: VirtualBox cannot delete a snapshot that has more than one child.
    foreach ($f in @(Get-ChildItem -LiteralPath $layerDir -Filter 'vmtest-L*.json' -File -ErrorAction SilentlyContinue)) {
        $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable
        if ($rec.parent -eq $Name) { Remove-VmtLayer $rec.name }
    }
    if ((Get-VmtSnapshots).ContainsKey($Name)) {
        Write-VmtLog "Deleting layer snapshot $Name"
        Invoke-VmtVBox -ArgumentList @('snapshot', $VMName, 'delete', $Name) -TimeoutSec 1800 | Out-Null
    }
    Remove-Item -LiteralPath (Join-Path $layerDir "$Name.json") -Force -ErrorAction SilentlyContinue
}

function Remove-VmtOldLayers {
    # Keep the newest -KeepLayers L1s, and the newest -KeepLayers L2s under each L1.
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
    Write-VmtLog "Shutting the guest down to snapshot layer $Name"
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
            Wait-VmtDesktop
            return
        }
    }
    $state = Get-VmtVmState
    if ($state -ne 'poweroff') { throw "Guest ended in state $state instead of a clean shutdown; not snapshotting $Name" }
    if ((Get-VmtSnapshots).ContainsKey($Name)) { Remove-VmtLayer $Name }
    Invoke-VmtVBox -ArgumentList @('snapshot', $VMName, 'take', $Name, '--description',
        "vmtest $Kind layer, key $Key (record: out\vmtest\layers\$Name.json)") -TimeoutSec 900 | Out-Null
    New-Item -ItemType Directory -Force -Path $layerDir | Out-Null
    $rec = [ordered]@{ name = $Name; kind = $Kind; key = $Key; parent = $Parent; vm = $VMName
        created = (Get-Date).ToString('o'); inputs = $Inputs; cached = $Cached; builtBy = $OutDir }
    $rec | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $layerDir "$Name.json") -Encoding utf8
    $script:report.layers.created += $Name
    Write-VmtLog "Saved layer $Name"
    Remove-VmtOldLayers
    if ($NoRestart) { return }
    Invoke-VmtVBox -ArgumentList @('startvm', $VMName, '--type', 'headless') -TimeoutSec 300 | Out-Null
    Wait-VmtDesktop
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

function Get-VmtGuestFileNames([string]$GuestDir) {
    $r = Invoke-VmtGuestRun -Exe 'C:\Windows\System32\cmd.exe' -Arguments @('/c', 'dir', '/b', '/a-d', $GuestDir) -TimeoutSec 60 -AllowFailure
    return @($r.Stdout -split "`r?`n" | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Push-VmtDownloadCache {
    # -CacheDownloads: GitHub release assets INSTALL-APPS fetched before go in, so it skips the
    # download when the release digest still matches (see its -DownloadCache).
    Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'mkdir') + (Get-VmtCredArgs) + @('--parents', $dlCacheGuest)) | Out-Null
    $present = Get-VmtGuestFileNames $dlCacheGuest
    $files = @(Get-ChildItem -LiteralPath $dlCacheHost -File -ErrorAction SilentlyContinue | Where-Object { $present -notcontains $_.Name })
    foreach ($f in $files) {
        Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'copyto') + (Get-VmtCredArgs) + @('--target-directory', "$dlCacheGuest\", $f.FullName)) -TimeoutSec 900 | Out-Null
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
    # The echoed value comes back quoted through guestcontrol.
    $guestTemp = ($tempRun.Stdout -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim().Trim('"')
    $seeded = 0; $bytes = [long]0; $skipped = @()
    foreach ($id in $ids) {
        $inst = Get-VmtWingetInstaller $id
        if (-not $inst) { $skipped += $id; continue }
        $localDir = Join-Path $dlCacheHost "winget\$id.$($inst.Version)"
        $local = Join-Path $localDir $inst.Sha256
        if (-not (Test-Path -LiteralPath $local)) {
            New-Item -ItemType Directory -Force -Path $localDir | Out-Null
            $progress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -Uri $inst.Url -OutFile $local } catch { $skipped += $id; continue } finally { $ProgressPreference = $progress }
            if ((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant() -ne $inst.Sha256) {
                Remove-Item -LiteralPath $local -Force; $skipped += $id; continue
            }
        }
        $guestDir = "$guestTemp\WinGet\$id.$($inst.Version)"
        Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'mkdir') + (Get-VmtCredArgs) + @('--parents', $guestDir)) | Out-Null
        Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'copyto') + (Get-VmtCredArgs) + @('--target-directory', "$guestDir\", $local)) -TimeoutSec 900 | Out-Null
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
        foreach ($k in 'package', 'options', 'precheck', 'apply', 'revert') { if ($old.Contains($k)) { $script:report[$k] = $old[$k] } }
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
$script:passwordFile = Join-Path $OutDir '.guestpw'
[IO.File]::WriteAllText($script:passwordFile, $GuestPassword)

if ($AppsOnly) {
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
        Remove-Item -LiteralPath $script:passwordFile -Force -ErrorAction SilentlyContinue
        if (-not $KeepRunning) { try { Stop-VmtVm } catch { Write-VmtLog "Power-off failed: $($_.Exception.Message)" } }
    }
    Complete-VmtReport -ExitCode (Get-VmtExitCode)
}

try {
    if (-not (Test-Path -LiteralPath $vbm)) { throw "VBoxManage not found at $vbm" }
    $snaps = (Invoke-VmtVBox -ArgumentList @('snapshot', $VMName, 'list', '--machinereadable')).Stdout
    if (-not ([regex]::Match($snaps, '(?m)^SnapshotName[-0-9]*="' + [regex]::Escape($Snapshot) + '"\r?$')).Success) {
        throw "Snapshot '$Snapshot' not found on $VMName"
    }

    if ($Build) {
        & (Join-Path $PSScriptRoot 'build-package.ps1')
        if (-not $?) { throw 'build-package.ps1 failed' }
    }
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
            package = Get-VmtTreeHash -Root $pkgDir -Include { param($p) $installerFiles -notcontains $p -and -not $p.StartsWith($appsListPrefix) }
        }
        $l1Key = Get-VmtSha256Text ($l1Inputs | ConvertTo-Json -Compress)
        $l1Name = 'vmtest-L1-' + $l1Key.Substring(0, 12).ToLowerInvariant()
        if ($AppsGroups) {
            $l2Inputs = [ordered]@{
                l1 = $l1Key; groups = @($AppsGroups | Sort-Object)
                appLists = Get-VmtTreeHash -Root $pkgDir -Include { param($p) $p.StartsWith($appsListPrefix) }
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

    Stop-VmtVm
    Write-VmtLog "Restoring snapshot '$restoreName'"
    Invoke-VmtVBox -ArgumentList @('snapshot', $VMName, 'restore', $restoreName) -TimeoutSec 600 | Out-Null
    Invoke-VmtVBox -ArgumentList @('startvm', $VMName, '--type', 'headless') -TimeoutSec 300 | Out-Null
    # A layer's first boot is the post-apply one, which can run long; the base snapshot boots quickly.
    if ($startFrom -eq 'base') { Wait-VmtGuestReady } else { Wait-VmtDesktop }

    Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'mkdir') + (Get-VmtCredArgs) + @('--parents', $guestIn)) | Out-Null
    Copy-VmtToGuest -LocalPath $agentLocal -GuestName 'guest-agent.ps1'

    if ($startFrom -ne 'base') {
        # The layer already holds this apply: report the verdict recorded when it was built.
        $rec = Get-VmtLayerRecord $l1Name
        foreach ($k in 'precheck', 'apply', 'tweaks') { $script:report[$k] = $rec.cached[$k] }
        $script:report.apply.cachedFrom = $l1Name
        Write-VmtLog "Apply reused from $l1Name (built $($rec.created) by $($rec.builtBy)): $($rec.cached.tweaks.counts.applied) applied, $($rec.cached.tweaks.counts.failed) failed"
        Sync-VmtInstaller
    }
    else {
        Copy-VmtToGuest -LocalPath $cli -GuestName 'cli.zip'
        Copy-VmtToGuest -LocalPath $Package -GuestName 'playbook.zip'
        Copy-VmtToGuest -LocalPath $optFile -GuestName 'options.txt'
        if ($RevertScript) { Copy-VmtToGuest -LocalPath $RevertScript -GuestName 'revert.ps1' }
        if ($AppsGroups) { Write-VmtLog "Apps groups after apply: $($AppsGroups -join ',') (guest needs network)" }

        $prep = Invoke-VmtAgent -Mode Prepare
        $script:report.precheck = if ($prep.Data) { $prep.Data } else { @{ error = $prep.Raw } }
        if ($prep.Exit -ne 0) { throw "Guest precheck failed: $(if ($prep.Data) { $prep.Data.error } else { $prep.Raw })" }
        if ($prep.Data.defenderRemediated) { Write-VmtLog 'Defender toggles had turned back on; re-disabled them via Set-MpPreference' }
        Write-VmtLog "Guest build $($prep.Data.osBuild), interactive user $($prep.Data.interactiveUsers -join ',')"

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
            $script:report.tweaks = Invoke-VmtSummarize -ConfigDir $configCopy -OptionsFile $optFile -LogsDir (Get-VmtLogs)
            if (Test-VmtTweaksClean) {
                Save-VmtLayer -Kind L1 -Name $l1Name -Key $l1Key -Inputs $l1Inputs -Cached ([ordered]@{
                    package = $script:report.package; options = $script:report.options; precheck = $script:report.precheck
                    apply = $script:report.apply; tweaks = $script:report.tweaks })
                $l1Saved = $true
            }
            else { Write-VmtLog 'The apply had failures; not caching it as a layer' }
        }
    }

    if ($AppsGroups -and $script:report.apply.status -eq 'completed' -and (Get-VmtVmState) -eq 'running') {
        # A restored layer and a freshly saved L1 have just booted; only an uncached apply needs the reboot.
        if ($startFrom -eq 'base' -and -not $l1Saved) { Restart-VmtGuest }
        Invoke-VmtApps
    }

    if ((Get-VmtVmState) -eq 'running') {
        $logsDir = Get-VmtLogs
        if ($startFrom -eq 'base') { $script:report.tweaks = Invoke-VmtSummarize -ConfigDir $configCopy -OptionsFile $optFile -LogsDir $logsDir }
        Add-VmtAppsSummary -LogsDir $logsDir
        $a = $script:report.apps
        if ($l2Name -and $startFrom -ne 'L2' -and ($l1Saved -or $startFrom -eq 'L1') -and $a.status -eq 'completed' -and
            $a.summary -and $a.summary.failed.Count -eq 0 -and $script:report.harnessErrors.Count -eq 0) {
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
    Remove-Item -LiteralPath $script:passwordFile -Force -ErrorAction SilentlyContinue
    if (-not $KeepRunning) { try { Stop-VmtVm } catch { Write-VmtLog "Power-off failed: $($_.Exception.Message)" } }
}
Complete-VmtReport -ExitCode (Get-VmtExitCode)
