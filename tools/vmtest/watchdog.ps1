<#
.SYNOPSIS
    Out-of-process hang watchdog for tools\vmtest.ps1.

.DESCRIPTION
    tools\vmtest.ps1 starts this script next to a run (unless -NoWatchdog). It is a separate process on
    purpose: the harness's own stall checks only run inside a few wait loops, so a harness blocked in a host
    call (Copy-Item over PowerShell Direct, a checkpoint operation, a native tool) or one that died silently
    could not report anything. This script watches from outside and does not depend on the harness being alive.

    Progress = a new line in <OutDir>\harness.log, ignoring the "Status poll failed" repeats the harness
    writes while a guest does not answer. A run is declared stuck when it has made no progress for -QuietSec and
      R1  the VM is idle (no virtual-disk I/O change and CPU under 3 % over -IdleWindowSec, or the VM is not
          running), a frozen guest the harness's own check missed; or
      R2  the harness has not declared extra patience for the current step. The harness declares patience for
          waits that are legitimately long (reboot, boot, layer shutdown, checkpoint merge) by writing a deadline
          to <OutDir>\watchdog.patience; its next log line cancels it.
    A busy VM with a harness that is quiet inside declared patience is left alone.

    When stuck it writes <OutDir>\watchdog-stuck.json (reason, last log lines, samples, harness process tree),
    ends the harness and its children (not itself), powers the VM off, and, if the harness left no summary.json,
    writes a stub with result "harness-hung". If the harness exits on its own without a summary.json (killed,
    crashed), it writes a stub with result "harness-died" and leaves the VM alone. Exit codes: 0 harness finished
    normally, 3 stuck run stopped, 4 harness died without a summary.

    -ReportOnly logs and writes the diagnostics but does not stop anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$HarnessPid,
    [Parameter(Mandatory)][string]$OutDir,
    [string]$VMName = 'windowstest-hv',
    [int]$QuietSec = 900,
    [int]$IdleWindowSec = 300,
    [int]$PollSec = 10,
    [switch]$ReportOnly
)

$ErrorActionPreference = 'Continue'
$OutDir = [IO.Path]::GetFullPath($OutDir)
$harnessLog = Join-Path $OutDir 'harness.log'
$wdLog = Join-Path $OutDir 'watchdog.log'
$patienceFile = Join-Path $OutDir 'watchdog.patience'
$summaryFile = Join-Path $OutDir 'summary.json'
$diagFile = Join-Path $OutDir 'watchdog-stuck.json'

function Write-WdLog([string]$Message) {
    Add-Content -LiteralPath $wdLog -Value ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message)
}

function Read-HarnessLog {
    # The harness appends while we read: open shared. Returns all lines.
    if (-not (Test-Path -LiteralPath $harnessLog)) { return @() }
    try {
        $fs = [IO.File]::Open($harnessLog, 'Open', 'Read', 'ReadWrite')
        try { $sr = [IO.StreamReader]::new($fs); return @(($sr.ReadToEnd()) -split "`r?`n" | Where-Object { $_ }) }
        finally { $fs.Dispose() }
    }
    catch { return @() }
}

function Get-VmIo {
    # Cumulative read + write counts of the VM's virtual disks, $null if the counters cannot be found
    # (the VM is off, or the counter set is missing).
    $sum = [long]0; $hit = 0
    try {
        $c = Get-Counter -Counter '\Hyper-V Virtual Storage Device(*)\Read Count', '\Hyper-V Virtual Storage Device(*)\Write Count' -ErrorAction Stop
        foreach ($s in $c.CounterSamples) {
            if ($s.InstanceName -like "*$($VMName.ToLowerInvariant())*") { $sum += [long]$s.CookedValue; $hit++ }
        }
    }
    catch { }
    if ($hit) { return $sum }
    return $null
}

function Get-VmDisk {
    # Throughput (MB/s) of the VM's virtual disks, for the resource timeline only; $null when unreadable.
    # (The Hyper-V "Latency" counter read 0 in every sample, so it is deliberately not reported.)
    try {
        $n = $VMName.ToLowerInvariant()
        $c = Get-Counter -Counter '\Hyper-V Virtual Storage Device(*)\Read Bytes/sec', '\Hyper-V Virtual Storage Device(*)\Write Bytes/sec' -ErrorAction Stop
        $r = 0.0; $w = 0.0; $hit = 0
        foreach ($s in $c.CounterSamples) {
            if ($s.InstanceName -notlike "*$n*" -or $s.InstanceName -notlike '*vhd*') { continue }
            if ($s.Path -like '*read bytes/sec') { $r += $s.CookedValue; $hit++ }
            elseif ($s.Path -like '*write bytes/sec') { $w += $s.CookedValue }
        }
        if ($hit) { return [pscustomobject]@{ readMBps = [Math]::Round($r / 1MB, 2); writeMBps = [Math]::Round($w / 1MB, 2) } }
    }
    catch { }
    return $null
}

function Get-VmSample {
    $state = 'unknown'; $cpu = $null; $hb = $null
    try { $vm = Get-VM -Name $VMName -ErrorAction Stop; $state = [string]$vm.State; $cpu = [int]$vm.CPUUsage; $hb = [string]$vm.Heartbeat } catch { }
    $running = ($state -eq 'Running')
    return [pscustomobject]@{ at = (Get-Date); state = $state; cpu = $cpu; heartbeat = $hb
        io = $(if ($running) { Get-VmIo } else { $null }); disk = $(if ($running) { Get-VmDisk } else { $null }) }
}

$samplesCsv = Join-Path $OutDir 'watchdog-samples.csv'
function Write-Sample($s) {
    # One line per sample: the harness joins these with its phase timeline (summary.json -> phases[].resources).
    if (-not (Test-Path -LiteralPath $samplesCsv)) { Add-Content -LiteralPath $samplesCsv -Value 'at,state,cpuPct,readMBps,writeMBps' }
    $d = $s.disk
    Add-Content -LiteralPath $samplesCsv -Value ('{0},{1},{2},{3},{4}' -f $s.at.ToString('o'), $s.state, $s.cpu, $(if ($d) { $d.readMBps }), $(if ($d) { $d.writeMBps }))
}

function Test-VmIdle([object[]]$Samples) {
    # Idle over the whole window. Not provable (so not idle) while the VM runs without readable counters.
    $recent = @($Samples | Where-Object { $_.at -ge (Get-Date).AddSeconds(-$IdleWindowSec) })
    if ($recent.Count -lt 2 -or ($recent[-1].at - $recent[0].at).TotalSeconds -lt ($IdleWindowSec * 0.6)) { return $false }
    if (@($recent | Where-Object { $_.state -ne 'Running' }).Count -eq $recent.Count) { return $true }
    if (@($recent | Where-Object { $_.state -ne 'Running' -or $null -eq $_.io }).Count -gt 0) { return $false }
    if (@($recent | ForEach-Object { $_.io } | Sort-Object -Unique).Count -ne 1) { return $false }
    return (@($recent | Where-Object { $_.cpu -ge 3 }).Count -eq 0)
}

function Get-PatienceDeadline {
    try {
        if (Test-Path -LiteralPath $patienceFile) { return [DateTimeOffset]::FromUnixTimeSeconds([long](Get-Content -LiteralPath $patienceFile -Raw).Trim()).LocalDateTime }
    }
    catch { }
    return [datetime]::MinValue
}

function Get-DescendantIds([int]$RootPid) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $ids = [Collections.Generic.List[int]]::new()
    $queue = [Collections.Generic.Queue[int]]::new(); $queue.Enqueue($RootPid)
    while ($queue.Count) {
        $p = $queue.Dequeue()
        foreach ($c in @($all | Where-Object { $_.ParentProcessId -eq $p -and $_.ProcessId -ne $PID })) { $ids.Add([int]$c.ProcessId); $queue.Enqueue([int]$c.ProcessId) }
    }
    return $ids
}

function Write-StubSummary([string]$Result, [int]$ExitCode, [datetime]$StartedAt, [string]$Reason, [string]$LastLine) {
    if (Test-Path -LiteralPath $summaryFile) { return }
    $stub = [ordered]@{
        vm = $VMName; startedAt = $StartedAt.ToString('o'); finishedAt = (Get-Date).ToString('o')
        result = $Result; exitCode = $ExitCode
        hangs = @([ordered]@{ where = $LastLine; reason = $Reason; at = (Get-Date).ToString('o') })
        harnessErrors = @("watchdog: $Reason")
        note = 'Written by tools/vmtest/watchdog.ps1: the harness produced no summary of its own. Nothing was verified; see harness.log and watchdog.log.'
    }
    $stub | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryFile -Encoding utf8
}

# ------------------------------------------------------------------------------------------------ main
$proc = Get-Process -Id $HarnessPid -ErrorAction SilentlyContinue
if (-not $proc) { Write-WdLog "Harness pid $HarnessPid is not running; nothing to watch"; exit 0 }
$procStart = $proc.StartTime
Write-WdLog "Watching harness pid $HarnessPid (started $($procStart.ToString('HH:mm:ss'))): quiet limit ${QuietSec}s, idle window ${IdleWindowSec}s, poll ${PollSec}s$(if ($ReportOnly) { ', REPORT ONLY' })"

$samples = [Collections.Generic.List[object]]::new()
$progressCount = -1
$progressSince = [Diagnostics.Stopwatch]::StartNew()
$lastLine = ''
$lastNote = [datetime]::MinValue
$reported = $false

while ($true) {
    Start-Sleep -Seconds $PollSec

    $alive = $false
    try { $p = Get-Process -Id $HarnessPid -ErrorAction Stop; $alive = ($p.StartTime -eq $procStart) } catch { }
    if (-not $alive) {
        if (Test-Path -LiteralPath $summaryFile) { Write-WdLog 'Harness finished and wrote summary.json; done'; exit 0 }
        $lines = @(Read-HarnessLog)
        $last = if ($lines.Count) { [string]$lines[-1] } else { '' }
        Write-WdLog "Harness exited without writing summary.json (last line: $last)"
        Write-StubSummary -Result 'harness-died' -ExitCode 4 -StartedAt $procStart -Reason 'the harness process ended without writing summary.json (killed or crashed)' -LastLine $last
        exit 4
    }

    $lines = @(Read-HarnessLog)
    $real = @($lines | Where-Object { $_ -notmatch 'Status poll failed' })
    if ($real.Count -ne $progressCount) { $progressCount = $real.Count; $progressSince.Restart(); $reported = $false }
    $lastLine = if ($real) { $real[-1] } else { '' }
    $quiet = [int]$progressSince.Elapsed.TotalSeconds

    $s = Get-VmSample
    try { Write-Sample $s } catch { }
    $samples.Add($s)
    while ($samples.Count -gt 200) { $samples.RemoveAt(0) }

    if (((Get-Date) - $lastNote).TotalSeconds -ge 300) {
        Write-WdLog "alive: quiet ${quiet}s, vm $($s.state), cpu $($s.cpu)%, io $($s.io), last: $lastLine"
        $lastNote = Get-Date
    }
    if ($reported -or $quiet -lt $QuietSec) { continue }

    $idle = Test-VmIdle $samples
    $patientUntil = Get-PatienceDeadline
    $patient = ((Get-Date) -lt $patientUntil)
    $reason = $null
    if ($idle) { $reason = "no harness progress for ${quiet}s and the VM is idle (state $($s.state), no disk I/O change for ${IdleWindowSec}s)" }
    elseif (-not $patient) { $reason = "no harness progress for ${quiet}s and no patience declared for this step (VM state $($s.state), cpu $($s.cpu)%)" }
    if (-not $reason) { continue }

    Write-WdLog "STUCK: $reason; last line: $lastLine"
    $tree = @(Get-DescendantIds $HarnessPid)
    $diag = [ordered]@{
        detectedAt = (Get-Date).ToString('o'); reason = $reason; quietSec = $quiet; lastLine = $lastLine
        patienceUntil = $(if ($patientUntil -gt [datetime]::MinValue) { $patientUntil.ToString('o') } else { $null })
        reportOnly = [bool]$ReportOnly
        harnessPid = $HarnessPid; harnessStarted = $procStart.ToString('o')
        children = @($tree | ForEach-Object { $c = Get-CimInstance Win32_Process -Filter "ProcessId=$_" -ErrorAction SilentlyContinue; if ($c) { [ordered]@{ pid = $c.ProcessId; name = $c.Name; cmd = ([string]$c.CommandLine).Substring(0, [Math]::Min(200, ([string]$c.CommandLine).Length)) } } })
        logTail = @($lines | Select-Object -Last 40)
        samples = @($samples | Select-Object -Last 20 | ForEach-Object { [ordered]@{ at = $_.at.ToString('HH:mm:ss'); state = $_.state; cpu = $_.cpu; heartbeat = $_.heartbeat; io = $_.io } })
    }
    $diag | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $diagFile -Encoding utf8

    if ($ReportOnly) { Write-WdLog "Report only: diagnostics in $diagFile, nothing stopped"; $reported = $true; continue }

    # End the children first so nothing relaunches work, then the harness.
    foreach ($id in @($tree | Sort-Object -Descending) + $HarnessPid) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
    Add-Content -LiteralPath $harnessLog -Value ('[{0}] WATCHDOG: {1}; harness stopped, powering {2} off' -f (Get-Date -Format 'HH:mm:ss'), $reason, $VMName)
    Stop-VM -Name $VMName -TurnOff -Force -ErrorAction SilentlyContinue
    $off = $false
    for ($i = 0; $i -lt 15 -and -not $off; $i++) { try { $off = ([string](Get-VM -Name $VMName -ErrorAction Stop).State -eq 'Off') } catch { }; if (-not $off) { Start-Sleep -Seconds 2 } }
    if (-not $off) {
        # A wedged VM worker: end the vmwp.exe that carries this VM's id.
        try {
            $id = [string](Get-VM -Name $VMName).Id
            Get-CimInstance Win32_Process -Filter "Name='vmwp.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match [regex]::Escape($id) } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } catch { }
    }
    Write-WdLog "Harness and $($tree.Count) child process(es) stopped; VM off: $off"
    Write-StubSummary -Result 'harness-hung' -ExitCode 3 -StartedAt $procStart -Reason $reason -LastLine $lastLine
    exit 3
}
