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
    8. Exits 0 only when nothing failed: 1 = playbook/revert failures, 2 = harness or VM error.

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
    [int]$ApplyTimeoutMin = 120,
    [int]$RevertTimeoutMin = 30,
    [int]$PollSec = 15,
    [string]$OutDir,
    [switch]$KeepRunning,
    [switch]$NoDefenderRemediation,
    [string]$ParseOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$agentLocal = Join-Path $PSScriptRoot 'vmtest\guest-agent.ps1'
$amelog = Join-Path $PSScriptRoot 'vmtest\amelog.py'
$vbm = Join-Path ${env:ProgramFiles} 'Oracle\VirtualBox\VBoxManage.exe'
$guestRoot = 'C:\vmtest'
$guestIn = 'C:\vmtest\in'
$guestPs = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'

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
        $state = Get-VmtVmState
        if ($Wanted -contains $state) { return $state }
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
    $got = Get-VmtGuestSha256 -GuestPath $guestPath
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
    while ($sw.Elapsed.TotalMinutes -lt $TimeoutMin) {
        Start-Sleep -Seconds $PollSec
        $s = Invoke-VmtAgent -Mode Status -Job $Job -TimeoutSec 60
        if ($null -eq $s.Exit) {
            $misses++
            Write-VmtLog "Status poll failed ($misses): $($s.Raw -replace '\s+', ' ')"
            if ($misses -ge 3) {
                $state = Get-VmtVmState
                if ($state -ne 'running') { return [ordered]@{ status = 'vm-stopped'; vmState = $state; durationSec = [int]$sw.Elapsed.TotalSeconds } }
                Wait-VmtGuestReady
                $misses = 0
            }
            continue
        }
        $misses = 0
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
    Write-VmtLog "Apply: $($script:report.apply.status); revert: $($script:report.revert.status); result: $($script:report.result) (exit $ExitCode)"
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

# --------------------------------------------------------------------------- full run
if (-not $GuestPassword) { throw 'Set -GuestPassword or $env:VMTEST_GUEST_PASSWORD (guest account password)' }
$script:passwordFile = Join-Path $OutDir '.guestpw'
[IO.File]::WriteAllText($script:passwordFile, $GuestPassword)

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
    Expand-Archive -LiteralPath $Package -DestinationPath (Join-Path $OutDir 'package') -Force
    Copy-Item -LiteralPath (Join-Path $OutDir 'package\Configuration') -Destination $configCopy -Recurse -Force
    if (-not $Options) { $Options = Get-VmtDefaultOptions -ConfPath (Join-Path $OutDir 'package\playbook.conf') }
    $script:report.options = $Options
    $optFile = Join-Path $OutDir 'options.txt'
    [IO.File]::WriteAllLines($optFile, [string[]]$Options)
    Write-VmtLog "Options: $($Options -join ' ')"
    $cli = Get-VmtCliZip

    Stop-VmtVm
    Write-VmtLog "Restoring snapshot '$Snapshot'"
    Invoke-VmtVBox -ArgumentList @('snapshot', $VMName, 'restore', $Snapshot) -TimeoutSec 600 | Out-Null
    Invoke-VmtVBox -ArgumentList @('startvm', $VMName, '--type', 'headless') -TimeoutSec 300 | Out-Null
    Wait-VmtGuestReady

    Invoke-VmtVBox -ArgumentList (@('guestcontrol', $VMName, 'mkdir') + (Get-VmtCredArgs) + @('--parents', $guestIn)) | Out-Null
    Copy-VmtToGuest -LocalPath $agentLocal -GuestName 'guest-agent.ps1'
    Copy-VmtToGuest -LocalPath $cli -GuestName 'cli.zip'
    Copy-VmtToGuest -LocalPath $Package -GuestName 'playbook.zip'
    Copy-VmtToGuest -LocalPath $optFile -GuestName 'options.txt'
    if ($RevertScript) { Copy-VmtToGuest -LocalPath $RevertScript -GuestName 'revert.ps1' }

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

    if ((Get-VmtVmState) -eq 'running') {
        $col = Invoke-VmtAgent -Mode Collect
        if ($col.Exit -ne 0) { throw "Log collection failed: $(if ($col.Data) { $col.Data.error } else { $col.Raw })" }
        if ($col.Data.errors.Count) { Write-VmtLog "Collect warnings: $($col.Data.errors -join '; ')" }
        $zip = Copy-VmtFromGuest -GuestPath $col.Data.zip -ExpectedSha256 $col.Data.sha256 -LocalDir $OutDir
        $logsDir = Join-Path $OutDir 'logs'
        if (Test-Path -LiteralPath $logsDir) { Remove-Item -LiteralPath $logsDir -Recurse -Force }
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $logsDir)
        Write-VmtLog "Logs pulled to $logsDir (sha256 verified)"
        $script:report.tweaks = Invoke-VmtSummarize -ConfigDir $configCopy -OptionsFile $optFile -LogsDir $logsDir
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
