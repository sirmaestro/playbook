`tools/build-package.ps1` (also run by `-Build`) zips `src\*` plus `WinDebloatTool-Setup.exe` into
`out/build/playbook.zip`. The installer is taken from `src\Executables` if present, otherwise from
GitHub release `-ToolRelease` (default `26.10`). So **a local run tests the released tool, not a tool
built from your working tree**.

Base VM and checkpoint requirements (VM `windowstest-hv`: Generation 2, 4 vCPU, 16 GB static memory,
vTPM, Secure Boot, nested virtualization exposed, Default Switch, dynamic 80 GB VHDX under `D:\HyperV`):
- An offline (VM Off) Standard checkpoint named `clean-defender-off-UAC-off`, with an auto-logon local
  account (`admin`) and BitLocker/device encryption off (`PreventDeviceEncryption`).
- Defender Tamper Protection off. This can only be set by hand in the Windows Security UI.
- UAC slider at "Never notify" (`ConsentPromptBehaviorAdmin=0`) so elevated steps in the interactive
  session don't prompt. PowerShell Direct's own token is already High integrity, so the harness itself
  doesn't need it; the playbook's `currentUserElevated` steps do.
- No pre-registered helper tasks are needed.
- Rebuilding the base from an ISO needs only an `autounattend.xml` on a second DVD (built with the
  IMAPI2 COM API, no ADK). Pick the Windows 11 Pro image and a generic key, create the `admin` account,
  and set `PreventDeviceEncryption`; the install takes about 7 minutes. Take the checkpoint after the
  manual Defender step, with the VM Off and no DVD drives attached.

Reading results:
- "applied" means the action ran without an error. It does not mean the end state was verified. For
  that, diff the end state as described in [docs/references-learnings.md](docs/references-learnings.md)
  ("Validate the end state, not the log").
- Non-zero exits on actions the playbook marks `errorAction: Ignore` are listed as `ignoredExitCode`
  and are not failures.
- Recovered registry warnings (e.g. UCPD-protected `TaskbarDa`, which AME re-applies via `reg.exe`) are
  listed under `warnings`.

Gotchas the harness already handles (keep them in mind when changing it):
- The transport's exit code is not the guest's, so the agent prints `VMTEST_EXIT=` instead.
- PowerShell Direct is refused for a short while after boot; `Invoke-VmtGuestRun` retries for up to
  3 minutes unless called with `-AllowFailure`. Each call is a job with a timeout, so a frozen guest
  cannot block the harness.
- Windows turns Defender real-time protection back on after each boot; the agent's `Prepare` re-disables it.
- The playbook's `RealTimeIsUniversal=1` puts the guest clock 13 h ahead after the apply (observed: the
  guest then reads the VM's clock, which is host local time, as UTC). Harmless; the harness times
  everything on the host.
- After removing a checkpoint, the VM is unusable until the background merge ends; the harness waits.
- In cmd, `echo %ERRORLEVEL%>f` writes nothing when the code is `0` (cmd reads it as `0>`, a redirect),
  so the exit-marker redirect goes first.
- A one-element PowerShell array unrolls to a string.
- Guest scripts stay ASCII-only for PS 5.1.

