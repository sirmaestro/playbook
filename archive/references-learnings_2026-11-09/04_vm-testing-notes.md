## VM testing notes

- Test by applying with **AME Wizard** to a Win10/11 VM or ISO — there is no unit test for playbook YAML.
- A dedicated Hyper-V VM is used for WinDebloat testing (`windowstest-hv`; checkpoint/credential details
  are in the agent's private memory, not committed here; AGENTS.md "VM testing" has the setup). Restore the
  clean checkpoint before each apply — Appx/CBS removals are not reversible. It replaced a VirtualBox VM
  on 2026-11-08 (see "Host hypervisor matters").
- `0x800b0110` from DISM = the CBS signing wall above, not a corrupt cab.
- Mass-disabling AV services or planting a spoofed `CN=Microsoft Windows` root trips automated safety
  classifiers; expect to run those steps by hand in the VM.
- **AME logs** live in `C:\ProgramData\AME\Logs\[<date>] WinDebloat\`: `Log.yml` (selected options +
  warnings only) and `Output.txt` (every action and its process output; contains NUL bytes, strip them
  before grepping). AME does **not** stop on a failing `!run`/`!powerShell`, so a "successful" run can hide
  whole failed phases. First grep after every apply: `exit code: 55` (tool gate), then `error code`.
- AME extracts the running playbook to `%TEMP%\AME\Playbooks\<UniqueId, upper-case>`; `runas:
  currentUserElevated` steps see the *user's* `%TEMP%`. The tool's mid-apply gate relies on this path.
- **Validate the end state, not the log.** Diff the expected values (walk `main.yml` → `!task` tree, apply
  option gates incl. file-level `option:`) against the VM's registry/services/tasks/appx. Known benign
  mismatches on 26300: `GpuEnergyDrv`, `Telemetry`, `diagnosticshub.standardcollector.service` services and
  some scheduled tasks don't exist; Photo Viewer associations are overwritten by `FILEASSOC.cmd` by design;
  the `WindowsUpdate\Services\Pending\…\RegisterWithAU` key is consumed by WU.
- Not yet explained (seen on the VM): `Diagtrack-Listener` autologger `Start` back to `1`, and
  `HKCU\Control Panel\Accessibility\HighContrast\Flags` reset to `126`.
- **Host hypervisor matters** (history: why testing moved from VirtualBox to Hyper-V on 2026-11-08; the
  Hyper-V harness gave an identical apply, 1051/0/82/0 and the same 1133 action ids, with no hang seen).
  With Hyper-V/VBS/Memory integrity on the host, VirtualBox logs `AMD-V is
  not available` → `fall back to NEM` and runs the guest through WinHvPlatform. In that mode the guest
  intermittently hung on the post-apply restart (2 of 5: "Restarting" for 40+ min, vCPUs spinning in
  kernel, zero disk I/O, after the EventLog service had already stopped, so nothing is logged), once
  froze mid-install, a VM reset wedged VirtualBox Manager, and `debugvm injectnmi` fails with
  `VERR_NOT_SUP_BY_NEM`. Treat these as environment suspects until reproduced with native AMD-V/VT-x.
  Recover by ending the large `VBoxHeadless` process (VM goes `aborted`), then `startvm`.
  Tally by 2026-10-23: the restart hung in 3 of about 13 attempts, plus 2 freezes during installs.
  `AHCI#0: Port 0 reset` in `VBox.log` is **not** a hang sign: healthy sessions log it too. Judge by
  static disk counters, a frozen guest clock in screenshots, and
  `vmmDevHeartbeatFlatlinedTimer: Guest seems to be unresponsive`. After a kill, `showvminfo` briefly
  fails with `RPC_S_CALL_FAILED` while the session tears down. `tools/vmtest.ps1` now detects hangs
  (static disk counters for `-StallSec`) and recovers by itself; see AGENTS.md.
- `shutdown.exe` on 26300 has no `/full` switch (plain `/s` is already a full shutdown; Fast Startup
  needs `/hybrid`). Given `/full`, it prints its usage text and exits 33 without shutting down, so a
  script waiting for the power-off waits forever. A wait on a guest that "won't turn off" should
  first check whether the guest is still live (clock, disk writes).
- The playbook's `RealTimeIsUniversal=1` (upstream dual-boot fix) makes a VM guest boot 13 h off (the
  hypervisor supplies host local time, which the guest then reads as UTC; seen on VirtualBox and Hyper-V)
  until time sync; harmless, VM-only.
- **Teams and Start Experiences come back on a networked VM** (Hyper-V run, 2026-11-08). Windows stages
  an update of the inbox `MSTeams` stub right after boot (the update finished within a second of the
  playbook removing `MSTeams_1.0.0.1`, which then registered `MSTeams_26276…` for the user), and
  `Microsoft.StartExperiencesApp` is not yet installed when the one-shot appx removal runs ("No installed
  package matched") and shows up about a minute later. The VirtualBox baseline log has the same removal
  sequence. Whether the same happens on a real install that is offline during the apply is untested.
  "Get Started" in the Start menu is `MicrosoftWindows.Client.CBS!WebExperienceHost`, inside a
  non-removable system package; nothing in the playbook removes it (`STARTMENU.cmd` restores its files).
- **GitHub release downloads can 504 while the API works** (2026-11-08, from this network; the
  `x-github-edge-region: australiaeast` response carried a GitHub request id): every
  `github.com/<repo>/releases/download/...` URL returned 504, `api.github.com/repos/.../releases/assets/<id>`
  with `Accept: application/octet-stream` served the same file. winget manifests use the first form, so
  winget installs of GitHub-hosted packages fail with `0x801901F8` until it recovers; INSTALL-APPS's
  `GitHubReleases` route and the harness cache seeding fall back to the API form.

