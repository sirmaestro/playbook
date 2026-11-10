# Learnings & gotchas (short form)

Facts that are expensive to re-derive, one or two lines each. The full write-ups are kept verbatim in
`archive/references-learnings_2026-11-09/` (file named in brackets; trust order and superseded claims in
`archive/README.md`). Keep this list short: when an entry needs more than two lines, archive the detail.

## Component removal (CBS) and Defender
- Policy/registry disable never reaches zero Defender processes: `WinDefend`, `MDCoreSvc`, `WdFilter`, `WdBoot`, `WdNis*`
  are PPL and reject `Start` writes even as TrustedInstaller, independent of Tamper Protection; the platform self-heals.
  Only removing the components (signed CBS package via `wdtool winpackage`) removes the processes. A policy-only disable
  must not be ported as a Defender disabler. [01]
- DISM/`Add-WindowsPackage` needs the cab's signer to chain to Code Integrity's internal allowlist root
  (`8A334AA8…`); `0x800b0110` = that signing wall, not a corrupt cab. Only AME's own cab chains to it. Never hand-roll
  CBS installs; this is why WinDebloat lives in the playbook. [01]
- Removal packages supersede each target component with an empty version (`38655.38527.65535.65535`), durable across
  Windows Update. Components **deliberately kept** (DeviceCensus, Error-Reporting-Faults/Kernel, Flighting,
  Data-Pdf, GameExplorer, Gaming-Configuration/GameMode, AMSI, Security Center, the Edge block) have reasons; don't
  "fix" them. [02]
- Protected appx (`SecureAssessmentBrowser`, `MicrosoftEdgeDevToolsClient`) return `0x80070032` on per-user removal;
  they go through `system-components-removal`. [03]
- Tamper Protection can only be turned off in the Windows Security UI (`TamperProtection` 4 = off). [03]
- Confirmed on the VM (2026-11-10, 26300.9457 to 9711): with our cabs committed and a CU installed, a component cleanup (`DISM /StartComponentCleanup`, `/ResetBase`, Disk Cleanup "Update Cleanup") makes `/ScanHealth` report "repairable" (AppInv `10.0.26100.1591`); the CU alone, and the same cleanup without our cabs, stay clean. `/RestoreHealth` and `sfc` do not fix it (97 corrupt payloads afterwards). Our own apply-time cleanup removed nothing in the update-first order, and Windows's scheduled cleanup task did not trigger it in two tries. Do not run a component cleanup by hand after the cabs go on. See `docs/atlas-comparison.md` 8.1.
- AtlasOS reports that component-store cleanup corrupts a store holding `38655.*` removal packages once a CU adds newer
  versions; our `CLEANER.ps1` enables Disk Cleanup "Update Cleanup" after the cabs go on. Details: `docs/atlas-comparison.md` 2.1.

## AME and the VM
- AME does **not** stop on a failing `!run`/`!powerShell`: a "successful" run can hide failed phases. After every apply
  grep `Output.txt` for `exit code: 55` (wdtool gate), then `error code`. `Output.txt` contains NUL bytes: strip before grepping.
  Logs: `C:\ProgramData\AME\Logs\[<date>] WinDebloat\`. [04]
- AME extracts the playbook to `%TEMP%\AME\Playbooks\<UniqueId upper-case>`; `currentUserElevated` steps see the
  user's `%TEMP%`. The tool's mid-apply gate relies on this path. [04]
- **Validate the end state, not the log** (`docs/vmtest.md`, live end-state check). Known benign mismatches on 26300:
  missing `GpuEnergyDrv`/`Telemetry`/`diagnosticshub.standardcollector.service` and some tasks; Photo Viewer
  associations overwritten by `FILEASSOC.cmd`; `RegisterWithAU` consumed by WU. [04]
- `HKU\.DEFAULT` is the SYSTEM profile; new accounts are cloned from `C:\Users\Default\NTUSER.DAT`. `Executables/DEFAULTUSER.ps1`
  (final.yml) copies the HKCU values the user holds into it: a new account went from 11/238 to 218/238 expected values (hv26).
  wdtool mounts that file as `HKU\DefaultUserHive` for its own tweaks and never unloads it, so the script reuses the mount. While
  it is mounted a NEW account gets a temporary profile (events 1509/1511, cannot copy `NTUSER.DAT`) until the next reboot, so the
  last step of `final.yml` unloads it (hv27/hv28: a no-reboot account got a normal profile, 218/238).
- On build 26300.9711 UCPD can deny HKLM writes to `Windows Feeds\EnableFeeds` and `Dsh\AllowNewsAndInterests` during the apply (even
  as admin; seen in hv23, hv24, hv26, not on the rebuilt base of hv27/hv28); `services.yml` disables UCPD but it stops only after a
  restart. Those two entries are `errorAction: Ignore` and `POSTCLEAN.ps1 -Target FeedsPolicy` writes them after the first reboot
  (hv26: both 0, task logs "removed"; hv27: "nothing to remove").
- `NoAutoUpdate=1` is now written by the upstream tool's `wu-pause-updates` (merged 2026-11); `updates.yml` keeps its own line
  commented out. On 26300.9711 with it set by hand, a Store install of Gaming Services, a WU scan and `XblAuthManager` all worked; the
  Xbox sign-in itself and Windows 10 (where it broke) are untested, and the released 26.10 tool the VM uses does not write it.
- AME CLI 0.8.4: `handleExitCodes: { "!0": halt }` on a `!run` stops the apply ("Playbook halted due to a critical error", engine
  `fatal`). `errorAction: Halt` on a throwing `!powerShell` is only recorded as failed; the apply carries on. A missing exe is not an
  exit code and does not halt either (CI `verify_playbook.py --package` checks the installer ships). `start.yml` uses it for the tool install.
- The VM base re-asserts autologon as `admin` on every boot, so a second account cannot be logged on interactively without keyboard
  input (Start pins for a new account, 2.4, stay untested).
- `shutdown.exe` on 26300 has no `/full` (plain `/s` is full; `/hybrid` = Fast Startup); given `/full` it prints usage and
  exits 33 without shutting down. [04]
- Teams, `StartExperiencesApp` and Copilot reappear on a networked VM because they arrive AFTER their removal steps,
  from three different sources (hv17 logs, 2026-11-10): [04]
  - Teams: Windows stages a newer `MSTeams_26276` as SYSTEM ~20 s before wdtool looks, so wdtool only removes the
    `1.0.0.1` stub. The Deprovisioned key does not remove an already staged version.
  - `StartExperiencesApp`: per-user Add from `C:\Windows\InboxApps\...msixbundle` ~1 min after the removal step. Not
    provisioned, so there is nothing for the Deprovisioned key to act on; delete the bundle.
  - Copilot: a **Win32** app (`Program Files (x86)\Microsoft\Copilot`, Edge Update id `{C50565E9-CCCF-44B4-BA15-5AC5C6569197}`),
    force-installed by Edge Update (`reason=ecs` in `MicrosoftEdgeUpdate.log`) at ~22:16, before the registry tasks set any
    EdgeUpdate policy. `wdtool appx --remove Microsoft.Copilot` cannot see it. Uninstall:
    `copilot_setup.exe --uninstall --mscopilot --channel=stable --system-level --force-uninstall` (exits 19, still removes it).
  Fix: `Executables/POSTCLEAN.ps1` (final.yml; repeats via a self-deleting SYSTEM task), early EdgeUpdate policy in
  start.yml, InboxApps bundle deletion (on 26100 `C:\Windows\InboxApps` holds only StartExperiencesApp and
  WidgetsPlatformRuntime, both deleted), Deprovisioned keys. The staged `MicrosoftWindows.Client.WebExperience`
  (Widgets board) cannot be de-staged (`Remove-AppxPackage -AllUsers` and wdtool both leave it); it is inert, not
  installed for any user.
  "Get Started" is the `WebExperienceHost` app inside `MicrosoftWindows.Client.CBS` (System-signed, NonRemovable, so
  it is not in Settings > Installed apps; it is in Start > All apps, as is "Windows Backup"). An IFEO `Debugger` on
  `WebExperienceHostApp.exe` does NOT stop it: the app still launched (hv test, 2026-11-10), because packaged apps
  are activated through the broker. Not handled; see the open question. Not reproduced by re-triggering Edge Update after the first hour, so the policy's effect on the
  ECS force-install is unproven; the sweep is what removes it.
- GitHub `releases/download/...` can 504 while `api.github.com/.../assets/<id>` (`Accept: application/octet-stream`) works;
  winget has no fallback (`0x801901F8`), INSTALL-APPS and the harness do. [04]
- VirtualBox on a Hyper-V host (NEM) hung intermittently; testing moved to Hyper-V on 2026-11-08, identical apply, no
  hang seen. VirtualBox is removed. [04]
- `RealTimeIsUniversal=1` puts a VM guest 13 h ahead until time sync; harmless. [04]

## Default apps (Windows 11 26300)
- 26300 ignores the classic `UserChoice` hash; `UserChoiceLatest` wins. `assoc.ps1` sets only class defaults;
  `INSTALL-APPS.ps1` writes `UserChoiceLatest` with the vendored `SFTA/SFTA.ps1` (reproduces Windows' hash 157/157) plus an
  `ApplicationAssociationToasts` value `<ProgId>_<type>`=0 per known handler, or the picker still shows. [05]
- `UserChoice` has a Deny ACE: delete with `RegDeleteKey` (not .NET `DeleteSubKeyTree`). `assoc.ps1` defines it with
  Reflection.Emit, not `Add-Type` (`csc.exe` stalled 32 s in the apply context). [05]
- Types Windows seeds for its inbox apps (Photos, Media Player, Edge) keep winning after the app is removed.
  `DefaultAssociationsConfiguration` changed nothing on 26300 Pro. [05]
- Verify defaults by opening samples in the user's session (`cmd /c start "" <file>`), not by reading the registry or
  `AssocQueryString` from a remote-session process. [05]

## Monorepo / git
- A folder with its own `.git` is silently skipped by `git add`; `debloat-tool/` is a `git subtree` import: never put a nested `.git` back. [06]
- Root `.gitattributes` stores LF, checks out CRLF. Subtree pulls need `git -c merge.renormalize=true subtree pull …`. [06]
- VS Code locks open folders on Windows; work in a temp clone. The tool has no local toolchain: CI `build-tool` is the first compile. [06]

## Regressions already learned (don't reintroduce) [07]
- **wdtool support gate:** changing `EditionSubManufacturer`/`EditionSubVersion` or `<UniqueId>` makes every `wdtool` call exit 55
  while AME carries on, so a whole run "succeeds" with no appx, winpackage, Defender or power-plan step.
- Reverted or avoided because they broke something: `DisableWindowsConsumerFeatures` (Your Phone), `SvcHostSplitThresholdInKB`
  (XboxGipSvc), disabling core Superfetch (`defrag -b`), `bam` (Efficiency Mode), background apps off (Game Bar),
  `VulnerableDriverBlocklistEnable=0` (THE FINALS), `AppCaptureEnabled` (#74), `disabledynamictick` (ROG Ally #167), bbr2
  (websockets #27), Insider firewall rule (Xbox), `NoAutoUpdate=1` (Xbox sign-in, W10), `condrv` not Automatic (#184),
  `DisableAutomaticRestartSignOn` (slow Hello), Contacts consent Deny (Mail & Calendar).
- Edge removal needs a non-EEA region; Edge/WebView reinstall after updates, hence Deprovisioned keys + EdgeUpdate policies.
  Hibernate off may overheat laptops; `DisableRootAutoUpdate` is needed for the Store.

Playbook area-file comments hold the per-tweak reasons: check them before touching an area.
