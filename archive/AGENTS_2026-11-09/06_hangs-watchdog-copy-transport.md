**Hangs.** The old VirtualBox guest froze intermittently on restart or mid-install (VirtualBox ran
through NEM on this Hyper-V host); none has been seen on Hyper-V yet, but the detection stays. The
harness detects a frozen guest itself:
- When restarting, booting or shutting down for a layer, the guest has to do disk I/O. If the VM's
  virtual-disk performance counters (`\Hyper-V Virtual Storage Device(*)\Read Count` / `Write Count`)
  don't move for `-StallSec` (360), the harness powers the VM off (`Stop-VM -TurnOff`; if that fails it
  ends the VM's `vmwp.exe`, found by VM id) and boots it again, at most twice per wait. If the counters
  cannot be found, the check reports activity, so a missing counter never looks like a freeze. A hung
  layer shutdown is not checkpointed.
- During a job, a hang means unanswered status polls *and* a static disk. The job is reported as
  `vm-hung`, a harness error (exit 2): rerun it.
- **Watchdog** (`tools/vmtest/watchdog.ps1`, started by the harness; `-NoWatchdog` turns it off,
  `-WatchdogQuietSec` = 900). The checks above only run inside a few wait loops, so a harness blocked in a
  host call, or one that dies silently, reported nothing. The watchdog is a separate process: it counts a new
  `harness.log` line as progress (the repeated `Status poll failed` lines do not count) and stops the run after
  `-WatchdogQuietSec` of silence if the VM is idle (no disk I/O change and CPU under 3 % for 5 min, or not
  running) or if the step has not declared more patience. Reboot, boot, layer-shutdown and checkpoint-merge
  waits declare theirs (`Set-VmtPatience`, a deadline in `watchdog.patience`; the next log line cancels it).
  Stopping means: end the harness and its children, power the VM off, write `watchdog-stuck.json` (reason,
  last log lines, samples, process tree) and a stub `summary.json` with `result: "harness-hung"` (exit 3).
  A harness that ends without a `summary.json` gets `"harness-died"` (exit 4) and the VM is left alone. The
  stub verifies nothing: rerun. A new step that can stay silent longer than 15 min must call `Set-VmtPatience`.
- `Copy-Item` over PowerShell Direct has no timeout of its own, so file copies run through `Invoke-VmtCopy`
  (thread job, 120 s + 2 s/MB, one retry on a fresh session; `VMTEST_COPY_TIMEOUT_SEC` overrides it for tests).
  Files of 8 MB and up go through `Copy-VMFile` (Guest Service Interface, about 54 MB/s against 16 MB/s for
  PowerShell Direct; the apps cache seed fell from 82 s to 34 s) and fall back to PowerShell Direct if that
  fails. `VMTEST_NO_GSI=1` forces the fallback for tests. The run's input files go in together through
  `Copy-VmtToGuestMany` (all over `Copy-VMFile`, one guest call for every SHA256): 21 s became 5 s, because a
  per-file copy cost about 5 s of PowerShell Direct session set-up.
- Each recovery is listed in `summary.json` → `hangs`. Details are in
  [docs/references-learnings.md](docs/references-learnings.md). Layers also shorten the exposure: a
  hang costs only the current layer.

