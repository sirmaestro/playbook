# VM test harness (`tools/vmtest.ps1`)

Applies the playbook to the Hyper-V VM `windowstest-hv` and writes a JSON verdict. Drives the guest only through
PowerShell Direct (`Invoke-Command -VMName`; never keyboard injection), as a member of **Hyper-V Administrators**
(no elevation needed). Applies with TrustedUninstaller.CLI 0.8.4 (AME's headless core, SHA256-pinned, cached in
`tools/cache/`). Run details and rejected ideas: the archive (`archive/README.md`).

```powershell
$env:VMTEST_GUEST_PASSWORD = '<guest password>'      # VMTEST_GUEST_USER defaults to admin
pwsh tools\vmtest.ps1 -Build                         # build package + full run, VM powered off after
pwsh tools\vmtest.ps1 -Build -KeepRunning            # leave the VM up
pwsh tools\vmtest.ps1 -ParseOnly out\vmtest\<run>    # re-summarise a past run's logs (no VM)
pwsh tools\vmtest.ps1 -Build -AppsGroups all         # apply, reboot, then INSTALL-APPS (guest needs network)
pwsh tools\vmtest.ps1 -AppsOnly -AppsGroups base     # INSTALL-APPS only, on a VM left up by -KeepRunning
pwsh tools\vmtest.ps1 -Build -Layers -CacheDownloads -AppsGroups base,media-office   # fast iteration
```

`tools/build-package.ps1` (run by `-Build`) zips `src\*` plus `WinDebloatTool-Setup.exe` into `out/build/playbook.zip`.
The installer comes from `src\Executables` if present, else GitHub release `-ToolRelease` (26.10), so **a local run
tests the released tool, not one built from your working tree**.

## What a run does

Restore `-Snapshot` (default `clean-defender-off-UAC-off`) and boot; wait for PowerShell Direct and `explorer.exe`;
copy the agent, CLI, package and options in (SHA256 checked in the guest); precheck Defender (re-disable real-time
protection if it came back); apply through the agent's own `vmtest-apply` scheduled task (Highest, Interactive, the
signed-in user), killed as `hung` after `-ApplyTimeoutMin`; pull logs; summarise with `tools/vmtest/amelog.py`
(walks `main.yml` with the engine's applicability rules, pairs each action with its `Output.txt` block). Optionally
`-RevertScript`, and `-AppsGroups` (reboot, run `INSTALL-APPS.ps1`, parse its Summary block; any failed app fails
the run). `summary.json` buckets: **applied**, **failed** (with error), **skipped** (reason), **unconfirmed** (no log block).
"Applied" means the action ran without an error, not that the end state was verified.

Exit codes: `0` pass, `1` failed/unconfirmed action, bad engine result or failed revert, `2` harness/VM error,
`3` watchdog stopped a hung harness (`harness-hung`), `4` harness ended without a verdict (`harness-died`).

## Checkpoint layers (`-Layers`)

Finished stages are cached as offline Standard checkpoints (VM Off, disk only; never take live ones):

| Layer | Checkpoint | Holds | Key (sha256) |
|---|---|---|---|
| L1 | `vmtest-L1-<key>` | applied playbook, shut down before its first post-apply boot | base checkpoint id, AME CLI, options, every package file **except** the installer's own files |
| L2 | `vmtest-L2-<key>` | L1 plus the `-AppsGroups` installed | L1 key, groups, installer files (`INSTALL-APPS.cmd/.ps1`, `Apps/*`, `SFTA/*`); expires after 24 h |

- Edit cost: installer files, app lists or `SFTA/*` miss L2 and rerun installs on L1 (about 5 min); anything else in
  the package (YAML, other Executables, `assoc.ps1`) keys L1 and costs a full re-apply.
- Built only from clean results. A hit restores the deepest usable layer, syncs the current installer in
  (`SyncApps`), and only the remaining steps run; `summary.json` → `apply.cachedFrom` records the layer's verdict.
- Flags: `-FreshApps` ignores L2; `-RebuildLayers` ignores all; `-ClearLayers` deletes every `vmtest-L*`;
  `-KeepLayers` (1) keeps the newest L1 and the newest L2 under it, and after each saved layer the harness prunes
  older ones plus any `vmtest-L*` checkpoint without a record (never the base). Removing a checkpoint starts a
  background disk merge; the harness waits for it.
- Records: `out/vmtest/layers/<name>.json`. A checkpoint without a record is never used.
- **Layers are for iterating. Done = an uncached run** (no `-Layers`, or `-RebuildLayers`): package rebuilt, applied
  from the clean checkpoint, error count compared. A restored layer does not re-test delivery by `start.yml` or
  anything that depends on uptime.

## Download cache (`-CacheDownloads`)

Testing aid only (the guest's network is slower than the host's). GitHub release assets (mpv, App Installer) are kept
in `tools/cache/downloads/` and used by `INSTALL-APPS -DownloadCache` only when the SHA-256 matches the published
digest; winget installers are pre-seeded into the guest's `%TEMP%\WinGet\<Id>.<Version>\<sha256>` from the host's
`winget show`. Both fall back to a normal download on any mismatch. `github.com/.../releases/download/...` has
returned 504 while `api.github.com` worked, so `Get-GitHubFile` / `Save-VmtDownload` fall back to the API asset
endpoint. Apply-time downloads (VCRedist, VCLibs, root certificates) are deliberately not cached
(`docs/vmtest-phase-breakdown.md`). Delete `tools/cache/downloads/` to reset.

## Hangs and the watchdog

- Wait loops (restart, boot, layer shutdown) watch the VM's virtual-disk counters; no change for `-StallSec` (360)
  means the harness powers the VM off and boots it again (at most twice per wait). A missing counter reads as
  activity. During a job, unanswered polls plus a static disk is reported `vm-hung` (exit 2): rerun. Recoveries are in
  `summary.json` → `hangs`. No hang has been seen on Hyper-V.
- **Watchdog** (`tools/vmtest/watchdog.ps1`, separate process; `-NoWatchdog`, `-WatchdogQuietSec` 900): a new
  `harness.log` line is progress; after the quiet time with an idle VM it ends the harness, powers the VM off, and
  writes `watchdog-stuck.json` and a stub `summary.json` (`harness-hung`). A step that can be silent over 15 min must
  call `Set-VmtPatience`. The stub verifies nothing: rerun.
- File copies go through `Invoke-VmtCopy` (thread job, 120 s + 2 s/MB, one retry; `VMTEST_COPY_TIMEOUT_SEC`). Files of
  8 MB and up use `Copy-VMFile` (Guest Service Interface, about 54 MB/s vs 16 MB/s; `VMTEST_NO_GSI=1` disables it).
  The run's inputs go in together via `Copy-VmtToGuestMany` (one guest call for all hashes).

## Output (`out/vmtest/<timestamp>/`, git-ignored)

`summary.json` (verdict: `result`, `tweaks`, `apps`, `endState`, `hangs`, `phases`, `provenance`, `liveState`),
`tweaks.json`, `harness.log` (ends with the phase timeline), `logs/` (from the guest), `config/` (what was tested),
`endstate-live-<stage>.json`, `endstate-expected.json`, `watchdog.log`, `watchdog-samples.csv`,
`watchdog-stuck.json`, `diag/servicing-diag.zip` (only when the first-boot commit check fails). `logs/` also holds
`WinDebloat/Post-Clean/postclean.log` (every POSTCLEAN pass, apply-time and scheduled) and `WinDebloat/default-user.log`
(the Default-profile copy). The scheduled task runs after the first reboot, so a run that collects before rebooting
shows only the apply-time pass.

**Live end-state check.** `liveState` compares the guest with what the `!registryValue`, `!registryKey`, `!service`
and `!file` actions should leave (`amelog.py expected`, last writer wins; `endstate-check.ps1` reads in the guest),
at `first-boot` and `final`. A difference not in `tools/vmtest/endstate-known.json` fails the run. Statuses:
`explained` (cause verified) and `open` (real, cause unknown). **Do not add an entry without verifying the cause and
writing it down.** It does not cover `!run`/`!powerShell`, scheduled tasks, appx removal or SFTA associations, so a
clean check is not proof the playbook worked.

## Base VM

`windowstest-hv`: Gen 2, 4 vCPU, 16 GB static, vTPM, Secure Boot, nested virtualization, Default Switch, dynamic
80 GB VHDX under `D:\HyperV`. Needs an offline Standard checkpoint `clean-defender-off-UAC-off` with auto-logon
account `admin`, BitLocker/device encryption off (`PreventDeviceEncryption`), **Defender Tamper Protection off (by
hand, in the Windows Security UI)** and UAC at "Never notify" (`ConsentPromptBehaviorAdmin=0`). Rebuild from an ISO
with an `autounattend.xml` on a second DVD (IMAPI2, no ADK; Pro image, generic key, ~7 min), checkpoint after the
manual Defender step with the VM Off and no DVD attached. No vmconnect during runs (Enhanced Session blanks the view).

## Gotchas the harness already handles

- The transport's exit code is not the guest's: the agent prints `VMTEST_EXIT=`. In cmd, `echo %ERRORLEVEL%>f` writes
  nothing for `0`, so put the redirect first.
- PowerShell Direct is refused for a short time after boot; `Invoke-VmtGuestRun` retries up to 3 min.
- Defender real-time protection returns after each boot; `Prepare` re-disables it.
- `RealTimeIsUniversal=1` puts the guest clock 13 h ahead after the apply; harmless, the harness times on the host.
- A removed checkpoint makes the VM unusable until the merge ends. A one-element PowerShell array unrolls to a string.
  Guest scripts stay ASCII-only for PS 5.1.
- Non-zero exits on `errorAction: Ignore` actions are listed as `ignoredExitCode`, not failures. Recovered registry
  warnings (UCPD-protected `TaskbarDa`, re-applied via `reg.exe`) are listed under `warnings`.
- Do not replace the `taskbar.yml` Feeds/`TaskbarDa` writes with `reg add` (UCPD denies it and the values are then not
  set); the engine's slow path is what makes them land.
