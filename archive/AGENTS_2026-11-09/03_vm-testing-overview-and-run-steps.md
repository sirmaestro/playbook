## VM testing

`tools/vmtest.ps1` applies the playbook to the Hyper-V test VM (`windowstest-hv`) and writes a JSON
verdict. It drives the guest only through PowerShell Direct (`Invoke-Command -VMName`, never keyboard
injection). That runs over VMBus, so the guest needs no network and no integration software, and it works
from a non-elevated shell as a member of the **Hyper-V Administrators** group. It applies with
**TrustedUninstaller.CLI**, AME Wizard's headless core (Ameliorated-LLC/trusted-uninstaller-cli 0.8.4,
SHA256-pinned and cached in `tools/cache/`), so no GUI is involved.

(The earlier VirtualBox harness is kept for reference in `tools/archive/vmtest-virtualbox.ps1`; nothing
runs it. The VirtualBox host ran the guest through NEM and froze intermittently; see
[docs/references-learnings.md](docs/references-learnings.md), "Host hypervisor matters".)

```powershell
$env:VMTEST_GUEST_PASSWORD = '<guest password>'      # VMTEST_GUEST_USER defaults to admin
pwsh tools\vmtest.ps1 -Build                         # build package + full run, VM powered off after
pwsh tools\vmtest.ps1 -Build -KeepRunning            # leave the VM up for inspection
pwsh tools\vmtest.ps1 -ParseOnly out\vmtest\<run>    # re-summarise a past run's logs (no VM)
pwsh tools\vmtest.ps1 -Build -AppsGroups all         # apply, reboot, then run INSTALL-APPS (guest needs network)
pwsh tools\vmtest.ps1 -AppsOnly -AppsGroups base     # INSTALL-APPS only, on a VM left up by -KeepRunning
pwsh tools\vmtest.ps1 -Build -Layers -CacheDownloads -AppsGroups base,media-office   # fast iteration (below)
```

What a run does:
1. **Restore and boot.** Restores the `-Snapshot` checkpoint (default `clean-defender-off-UAC-off`) and
   starts the VM. There is no console window; open `vmconnect` only to look, and turn Enhanced Session
   off (View menu) or it blanks the view with a sign-in screen.
2. **Wait for the guest.** Waits for a real PowerShell Direct round-trip plus `explorer.exe` for the
   auto-logon user. There are no fixed sleeps.
3. **Copy in.** Copies `tools/vmtest/guest-agent.ps1`, the CLI zip, the package and `options.txt` to
   `C:\vmtest\in`, and checks each file's SHA256 inside the guest.
4. **Precheck.** The agent elevates itself and mirrors the CLI's Defender-toggle check. If real-time
   protection has turned itself back on, it re-disables it with `Set-MpPreference` (Tamper Protection
   must already be off).
5. **Apply.** The agent registers its own scheduled task `vmtest-apply` (RunLevel Highest, Interactive
   logon as the signed-in user) and runs the CLI from it. The harness polls until the CLI exits or
   `-ApplyTimeoutMin` passes. On timeout the apply is marked `hung` and killed.
6. **Pull logs.** Zips the CLI's `Output.txt`/`Log.yml`, job stdout and `ProgramData\AME\Logs` in the
   guest, copies the zip out and checks its hash.
7. **Summarise.** `tools/vmtest/amelog.py` (Python + PyYAML) walks `main.yml` with the engine's own
   applicability rules and pairs each executed action with its `Output.txt` block. It writes
   `summary.json` with these buckets:
   - **applied**
   - **failed**, each with its error: unhandled non-zero exit, inline Error/Critical, or the `55` gate
   - **skipped**, with the option or `onUpgrade` reason
   - **unconfirmed**, for actions with no log block
8. **Revert.** Runs `-RevertScript <file.ps1>` the same way under `-RevertTimeoutMin`. Without the
   flag, `revert.status` is `not-run`, because the playbook has no revert path yet. (`revert.yml` is an
   `onUpgrade` rollback; it runs only on a re-apply.)
9. **Apps (optional).** With `-AppsGroups`, reboots the guest, checks the playbook installed the app
   installer and its desktop shortcut, and runs `%ProgramData%\WinDebloat\Install Apps\INSTALL-APPS.ps1
   -Group <groups>` from the same elevated interactive task, under
   `-AppsTimeoutMin` (default 240). The script always exits 0, so `summary.json` → `apps.summary` is
   parsed from its closing Summary block (installed / failed / reboot-to-finish / default-app types
   set of total, types not set, types with no handler). Any failed app fails the run; its transcript
   is pulled to `logs\apps\`. The post-apply reboot waits up to `-RebootTimeoutSec` (default 2400).
   Default apps are written directly: Windows 11 (26300) keeps the real choice in `UserChoiceLatest`,
   which the vendored `Executables/SFTA/SFTA.ps1` (PS-SFTA, MIT) hashes as Settings does, plus an
   `ApplicationAssociationToasts` entry per handler so Windows does not ask again (see
   docs/references-learnings.md). Verify defaults by opening files in the user's session, not by
   reading the registry.

