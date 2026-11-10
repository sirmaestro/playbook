# Atlas 0.6 compared with this playbook: learnings and ideas

Source: `reference/Atlas-main` (AtlasOS 0.6) and `reference/atlas-toolbox-main` (Atlas Toolbox, section 7); local
copies, git-ignored, so the `reference/...` paths below only resolve on a machine that has them. Read on 2026-11-10. Atlas paths are abbreviated: `AM/` = `reference/Atlas-main/playbook/Executables/AtlasModules/Scripts/`.

**How much to trust this.** Lines marked **Atlas:** say what Atlas's code or docs do or claim. A claim has a **VM result**
line where it was run on our VM (details in section 8); a claim without one was not. A claim about *our* repo was checked by reading or grepping our files. Every idea in
section 5 is a proposal. Anything that removes, disables or changes existing behaviour needs the maintainer's yes
(golden rule 2), and any new tweak lands as AME YAML (golden rule 1), not as Atlas PowerShell.

## 1. The two designs

| | This playbook | Atlas 0.6 |
|---|---|---|
| What AME runs | ~60 YAML task files, ordered in `main.yml`, native `!registryValue` / `!service` / `!run` actions | `Configuration/custom.yml` only hands off: 30 `!run` calls into PowerShell (Begin, record options, Commit, `Invoke-AtlasInstall.ps1 -Run`) |
| Where the logic lives | YAML, plus `wdtool` (Dart/Rust) and scripts in `Executables/` | PowerShell 5.1 modules (`AM/Modules/Atlas.*`), data-only `.psd1` tweak and toggle definitions, one ordered plan (`AM/Install/Install-Plan.ps1`) |
| Failure handling | AME carries on past a failing `!run`; we grep `Output.txt` afterwards | Every `!run` has `handleExitCodes: { "!0": halt }`; a step records success or failure in a state file; a rerun resumes at the first incomplete step |
| Re-apply / upgrade | `revert.yml` with `onUpgrade: true` | Modes Fresh / Upgrade / Reapply / Rebase; a machine state document (`C:\Windows\AtlasOS\state.json`) records the choices, and upgrades replay them |
| Verification | VM harness: AME log parse + live end-state check derived from the YAML (`tools/vmtest/endstate-check.ps1`) | Every registry/service/task declaration can be read back (`Test-Atlas*Entries`); shipped health check `Check Atlas Health.cmd` reports drift; Pester suites in CI |
| Users | HKCU actions + a copy under `HKU\.DEFAULT` | Three passes per tweak: machine, the installing user (own token), the Default profile hive loaded as `HKU\Atlas_DefaultUser`; a RunOnce first-sign-in script for other accounts |
| Component removal | `wdtool winpackage` with CBS cabs (Defender, Telemetry, AI, OneDrive, Xbox, system packages) | Two CBS cabs (NoTelemetry, NoDefender), installed with `Add-WindowsPackage`; Safe Mode retry when one fails |
| Before the install | AME requirements (same five as Atlas) | Atlas Manager installs every Windows and Store update first and refuses to start while any are outstanding |

The Atlas architecture is not something to port: rule 1 keeps us in YAML, and much of Atlas's machinery (install
state, resume, the TrustedInstaller broker, toggles) exists because it replaced AME's runner. The useful parts are
the facts it learned and a handful of patterns that map onto YAML, `wdtool` or the harness.

## 2. Learnings

### 2.1 Component-store cleanup can corrupt a store with `38655.*` removal packages
**Atlas** (`reference/Atlas-main/docs/architecture.md`, "The component store and the Atlas packages"): its packages
supersede components with `38655.38527.65535.65535`, the same scheme ours use. Once a cumulative update adds a newer
version of a superseded component, `DISM /StartComponentCleanup` rebuilds the oldest version from its baseline and
cannot rebuild all of its files (with NoTelemetry: AppInv 10.0.26100.1591 without `aeinvext.dll`). The store then reads
"repairable"; online `/RestoreHealth` only moves the complaint to other files, offline it fails with `0x800F0915`.
Windows's own scheduled cleanup can do the same. Atlas therefore cleans the store only once, on a fresh install,
*before* its packages go on, and keeps a `LocalSourcePath` repair source (`AM/Modules/Atlas.Software/Domain/CbsPackages.ps1`).

**Our exposure (checked in our files):** the DISM line in `src/Executables/CLEANER.ps1:94` is commented out, but
`CLEANER.ps1:21` enables the Disk Cleanup handler `"Update Cleanup"` (Windows Update Cleanup, which removes superseded
components) and runs `cleanmgr /sagerun:1337` and the `SilentCleanup` task, from `final.yml:40`, i.e. after `win-sxs.yml`
installed the cabs. Nothing disables `\Microsoft\Windows\Servicing\StartComponentCleanup`. The harness never checks store
health (`servicing-diag.ps1` only runs when the packages fail to commit).
**VM result (section 8.1): confirmed.** With our five cabs on, a CU, then `DISM /StartComponentCleanup`, `/ScanHealth` reports
"The component store is repairable" (`CSI Payload Corruption: 3`, the AppInv components Atlas names). The same CU and
cleanup without our cabs leave the store clean. No repair works (`/RestoreHealth` and `sfc` make it worse), and our
own apply-time cleanup does not trigger it.

### 2.2 Atlas installs every update first; that removes the race behind our reappearing apps
**Atlas** refuses to install until an online Windows Update scan finds nothing, the Store has no pending updates or
queue items for the user, the connection is not metered and no restart is pending (`docs/architecture.md`,
"Preparation check"). Our learnings show Teams (`MSTeams_26276` staged by Windows), `StartExperiencesApp` (added from
`InboxApps`) and Copilot (forced by Edge Update) reappear because they arrive *after* our removal steps. Atlas has no
fix for these three (it removes them once, has no later sweep, and sets no EdgeUpdate policy); it simply never
debloats a machine that is still being updated. AME's `NoPendingUpdates` requirement, which we already declare, only
covers pending restarts, not "updates available".

**VM result (section 8.2):** our regular base was not up to date (the October CU and Store apps were pending). With everything
installed first, the apply-time removals were complete and Teams and StartExperiences needed no sweep; Copilot (installed by
Edge) still did. Reappearance over time was not measured.

### 2.3 `HKU\.DEFAULT` is not the new-user template
`AGENTS.md` and `docs/windebloat-extension.md` say HKCU values are copied to `HKU\.DEFAULT` "so new users inherit
them" (167 such lines in `src/`). In Windows `HKU\.DEFAULT` is the LocalSystem profile; new accounts are created from
`C:\Users\Default\NTUSER.DAT`. **Atlas** loads exactly that file as `HKU\Atlas_DefaultUser`
(`AM/Install/Tasks/Set-AtlasDefaultUserHive.ps1`) and never writes `.DEFAULT`. **VM result (section 8.3): the claim is wrong.** AME does not write `HKCU` actions into the Default profile either: after
an apply the Default hive holds 11 of 238 expected `HKCU` values (all Windows defaults) and a new local user gets none of
the non-default ones. The `.DEFAULT` copies are harmless (they affect the sign-in screen and SYSTEM), so this is about the
documented reason, not about removing them.

### 2.4 Start pins: the supported policy exists since 26100.4770
**Atlas** (`AM/Tweaks/qol/config-start-menu.psd1`, `AM/Modules/Atlas.Shell/Domain/Start.ps1:21-23`) writes
`HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer` `ConfigureStartPins`=1 and `ConfigureStartPinsJSON` (REG_EXPAND_SZ
path to a JSON file with `"applyOnce": true`, so users can change pins afterwards), and deletes
`PolicyManager\current\device\Start\ConfigureStartPins` as "the unsupported internal PolicyManager mirror". That
mirror is what our `registry/explorer/start-menu.yml:9` writes. The local policy arrived in KB5062660 (26100.4770); every
later build has it.

### 2.5 `AllowExperimentation` under PolicyManager can block Known Issue Rollback
**Atlas** removed its tweak (`AM/Tweaks/tweaks.manifest.psd1:45-47`): "a dead 1607-era MDM policy; the
PolicyManager\current variant is known to block Known Issue Rollback fixes, and disabling DiagTrack already cuts the
experimentation delivery channel." We write exactly that value (`registry/privacy/telemetry.yml:55`). Not verified by us.

### 2.6 Removal results lie; read the inventory again
**Atlas** (`AM/Modules/Atlas.Appx/Domain/Removal.ps1`): `Remove-AppxPackage -AllUsers` can report success and leave the
package registered for another account, SYSTEM or a deleted account. Atlas re-reads installed *and* provisioned
inventories afterwards, retries per SID (`-User <sid>`), skips `NonRemovable` and `PendingRemoval`, waits 5 s and judges
only the last read. Still installed for the installing user or still provisioned = failure; anything else = warning.
It then writes the `Deprovisioned` key for every family it matched, even if the removal failed. Its removal of Phone
Link (`Microsoft.YourPhone*`) runs as a separate best-effort pass because removing it with the others broke Cross Device
Experience Host (`AM/Modules/Atlas.Appx/Domain/PhoneLink.ps1`); its Phone Link toggle keeps `CDPSvc` at Manual because
Night Light needs it.

**VM result (section 8.4):** after the apply nothing the appx files target was left for the user or provisioned; the
SYSTEM-only leftovers are NonRemovable or staged (warnings by Atlas's rules).

### 2.7 MDCoreSvc after Defender removal
**Atlas** (`AM/Modules/Atlas.Security/Domain/Defender.ps1:60-95`): `MDCoreSvc` survives the removal package with its
binary gone, so it fails at every boot (event 7023). `Start=4` cannot be written before the restart ("Tamper Protection
is still enforced at the kernel level until the restart"), so Atlas registers a one-shot SYSTEM startup task that sets it
after the reboot and deletes itself. Our `wdtool` only writes `MDCoreSvc` `Start=2` on *restore*
(`debloat-tool/src/lib/features/tweaks/security/security_service.dart:197,235`). **VM result (section 8.4): does not occur on 26300.** After `disable-defender` the `MDCoreSvc` key is empty and the boot
logged no service-control error.

### 2.8 Service startup: Atlas uses documented controls, not `Start=4`
**Atlas** (`reference/Atlas-main/docs/services-startup-policy.md`) keeps every service at its Windows default except
`PcaSvc` (with the `DisablePCA` policy) and `NetBT` (via the File Sharing choice, per interface `NetbiosOptions=2`).
For `DiagTrack` it uses `AllowTelemetry` / `LimitDumpCollection` / `LimitDiagnosticLogCollection`; for `WerSvc` the
`Windows Error Reporting\Disabled` policy; `diagnosticshub.standardcollector.service` "Don't disable" (Microsoft IoT
guidance); `UCPD`, `GpuEnergyDrv`, `Telemetry` untouched (the name `Telemetry` can collide with third-party software).
We disable all of these in `services.yml`. Our learnings already list `GpuEnergyDrv`, `Telemetry` and
`diagnosticshub` as missing on 26300. A new override in Atlas needs a VM gate and a stated feature loss.

### 2.9 Smaller facts
- **Edge uninstall can sign the user out:** Atlas runs `setup.exe --uninstall --system-level --force-uninstall`
  detached with a short bounded wait, because a synchronous run "can reach RestartManager and sign the user out on
  24H2/25H2" (`AM/Operations/Remove-Edge.ps1`). It never kills `msedgewebview2`. Our `app-win32.yml` kills `MicrosoftEdge*`.
- **Copilot policy:** `RemoveMicrosoftCopilotApp=1` (Atlas: honoured on Enterprise/Education only).
- **Svchost split:** Atlas sets `SvcHostSplitDisable=1` per service and skips names matching `Xbl|Xbox`
  (`AM/Tweaks/performance/system/disable-service-host-split.ps1:10`). We reverted the global
  `SvcHostSplitThresholdInKB` because it broke `XboxGipSvc`, which that pattern also skips.
- **Background apps:** Atlas turns them off by the per-user `GlobalUserDisabled=1`, deliberately not the
  `LetAppsRunInBackground` policy, which "removes the per-app override UI entirely". We reverted background-apps-off
  for Game Bar; unknown which variant that was tested with.
- **`DisableAutomaticRestartSignOn=1`:** Atlas applies it; we reverted it (slow Hello). Atlas's choice does not
  disprove ours.
- **Default apps:** Atlas does not set browser or file defaults at all ("browser defaults remain owned by Settings or
  managed policy", `AM/Modules/Atlas.Shell/Domain/FileAssociations.ps1:3-4`). Our SFTA `UserChoiceLatest` path is
  further along; nothing to take here.
- **Toast mute during install:** Atlas sets `NoToastApplicationNotification=1` under
  `HKLM\SOFTWARE\Policies\...\PushNotifications` for the duration, after saving the old value, and restores it at the end.
- **Store auto-updates:** Atlas uses the user-visible `WindowsStore\WindowsUpdate\AutoDownload=2`; it notes that this
  does not stop an update the user or a tool asks for.
- **Power:** Atlas copies Balanced into its own scheme and changes four AC values only; it never deletes stock plans,
  and hibernation-off is an unchecked opt-in. Our hibernate page defaults to *disable*, with the overheat warning.

## 3. What Atlas does not solve for us

- The three reappearing apps (2.2): Atlas avoids the race rather than fixing it, so `POSTCLEAN.ps1` stays our answer.
- "Get Started" (`WebExperienceHost` in `MicrosoftWindows.Client.CBS`): untouched by Atlas.
- The staged `MicrosoftWindows.Client.WebExperience`: Atlas marks it `IgnoreErrors` and only warns, same as our "inert".
- The Defender PPL wall and the CBS signing wall: same constraints; Atlas's cab installer requires the same
  `8A334AA8…` root (`CbsPackages.ps1:75-114`).

## 4. Where we are already ahead

- **VM harness.** Layered checkpoints, out-of-process watchdog, disk-I/O stall detection, SHA256-checked copies, AME log
  parsing per action, and an end-state check with a triaged allow-list. Atlas's `tools/lab/Invoke-AtlasLabRun.ps1`
  is one checkpoint, one job with a 2 h timeout, a reboot and a health check.
- **Default apps** on 26300 (2.9).
- **More removal coverage:** AI, OneDrive, Xbox and system-package cabs; ~40 promo stubs, Copilot providers, AIHub,
  Office/OutlookPWA, CrossDevice and others that Atlas leaves.
- **The reappearance sweep** (`POSTCLEAN.ps1`, early EdgeUpdate policy, InboxApps deletion).

## 5. Ideas, ranked

Columns: **Where** it would land; **Rule 2** = changes or removes existing behaviour, needs the maintainer's yes;
**Verify** = what proves it.

### Tier 1: cheap, clear value

| # | Idea | Where | Rule 2 | Verify |
|---|---|---|---|---|
| 1 | 2.1 bites us (section 8.1). Add a read-only `DISM /ScanHealth` step to the harness end state so every run shows it | `tools/vmtest` | no | VM |
| 2 | 2.1 is confirmed, but our apply-time cleanup is harmless in the normal order (section 8.1); only to guard against a later cleanup: stop enabling `"Update Cleanup"` in `CLEANER.ps1`, disable the `Servicing\StartComponentCleanup` task, or run the cleanup *before* `win-sxs.yml` like Atlas | `CLEANER.ps1`, a task YAML | **yes** | VM: rerun CU then cleanup, ScanHealth clean |
| 3 | Static checks with no VM (Pester 5 + a YAML loader): every YAML parses; only known `!tags`; `data:` quoted; every `option:` exists in `playbook.conf` and every option is used; every `!task` path and referenced Executable exists; CRLF; `playbook.conf` identity is not ReviOS's | new `tests/`, CI job before release | no | CI |
| 4 | A package verifier after the CI archive step (Atlas `tools/build/Test-Apbx.ps1`): root layout, file parity with `src/`, `WinDebloatTool-Setup.exe` present, version stamped, `playbook.conf` parses | `.github/workflows/main.yml` | no | CI |
| 5 | A Windows PowerShell 5.1 parse check of every `src/Executables/*.ps1` and guest-side harness script (Atlas `.github/workflows/test.yml:51-71`, about 10 lines) | CI | no | CI |
| 6 | 2.3 is settled (section 8.3): correct the wrong reason in `AGENTS.md` / `windebloat-extension.md` (and, since AME does not cover the Default profile, consider a Default-hive pass for new users) | docs, maybe `start.yml` | no (docs) | VM |
| 7 | Mute toasts during the apply, restore at the end (2.9) | `start.yml` + `final.yml` | no | VM |
| 8 | New AI/privacy policies that are pure additions: `WindowsAI\DisableSettingsAgent=1`, `WindowsNotepad\DisableAIFeatures=1`, Paint `DisableCocreator` / `DisableImageCreator` / `DisableGenerativeFill`=1, `ConsentStore\generativeAI\Value=Deny`, `RemoveMicrosoftCopilotApp=1` | `registry/privacy/windebloat-ai.yml` (or similar) | no | end-state check |

### Tier 2: worth doing, needs a decision or a test

| # | Idea | Where | Rule 2 | Verify |
|---|---|---|---|---|
| 9 | Pre-apply update gate (2.2): for the VM, update Windows *and* Store apps in the base checkpoint and let staging settle; for users, a documented "update first" step or an `Executables` check that fails early when Windows Update offers updates | harness, `playbook.conf` text, maybe a `!run` | no | Apply-time result in section 8.2; still to measure: do Teams / Copilot / StartExperiencesApp come back later? |
| 10 | Start pins through the supported policy (2.4), gated to 26100.4770+, keeping LayoutModification for older builds | `start-menu.yml`, ship a JSON | replacing the PolicyManager value: **yes** | VM, pins applied and user-editable |
| 11 | Drop `AllowExperimentation` (2.5) | `telemetry.yml:55` | **yes** | KIR hard to test; decide on Atlas's evidence |
| 12 | Verify appx removal (2.6; by hand, nothing targeted was left, section 8.4): after `appx.yml`, re-read installed + provisioned per SID and log leftovers; could live in `wdtool appx` or the end-state check | `wdtool` or `tools/vmtest` | no | VM |
| 13 | MDCoreSvc one-shot startup task (2.7), dropped: the VM shows no event 7023 after `disable-defender` (section 8.4) | `wdtool` or a task YAML | no | VM event log |
| 14 | `handleExitCodes: { "!0": halt }` on the few steps whose failure makes the rest meaningless (`WinDebloatTool-Setup.exe` install). First test what our AME version does with it | `start.yml` | **yes** (changes failure behaviour) | VM, forced failure |
| 15 | Extra appx: `Microsoft.WindowsBackup` (the "Windows Backup" entry in our learnings), `Microsoft.StickyNotesPreview`, `Microsoft.ScreenSketch` (Snipping Tool, option-gated); remove Phone Link in its own step after the others | `appx.yml` / `windebloat-appx.yml` | no | VM; Cross Device / Night Light still work |
| 16 | Privacy/perf additions from the Atlas tweak set (Appendix A) | area YAML files | no | end-state check |
| 17 | Download hardening for `INSTALL-APPS.ps1`: wall-clock and size limits; in the GitHub fallback reject drafts/prereleases, require the canonical asset URL and check the asset's `digest` sha256; check the signer of downloaded installers | `INSTALL-APPS.ps1` | no | harness app run |

### Tier 3: consider later

- **Review our service disables against 2.8** (`DiagTrack`, `WerSvc`, `diagnosticshub`, `UCPD`, global `NetBT`) and
  move to the policy equivalents where they exist. Every item is a behaviour change: **rule 2**.
- **Svchost split with an Xbox exclusion** (2.9) as a safer re-entry of a reverted tweak: rule 2 + learnings check +
  a Game Bar / controller test.
- **First-sign-in RunOnce script** for accounts created after the install (theme, pins, default apps), with a per-user
  done marker and the retry entry re-queued before work starts (Atlas `Entry/Initialize-NewUser.ps1`). Relevant to
  the backlog goal of a yearly reinstall with several accounts.
- **A shipped, read-only health check** (Atlas `Check Atlas Health.cmd`): the end-state expectations, packed in
  `Executables` so a user can see drift after a feature update. Pairs with the backlog idea of a weekly maintenance task.
- **A generic before/after state dump in the harness** (Atlas `tools/dev/Compare-SystemState.ps1`: registry under four
  roots, every service `Start`, every scheduled-task state) to catch side effects no YAML declares. We have no
  scheduled-task coverage in the end-state check today.
- **`SupportedBuilds`:** we list 19044 … 28000 but test one build. Record the guest build in `summary.json` and
  write down which builds are actually verified.
- **Hibernate default:** Atlas makes hibernation-off an unchecked opt-in, which matches our own overheating note better
  than our default does. **rule 2.**
- **Cosmetic `playbook.conf` fields** Atlas uses: `EstimatedMinutes`, `ProgressText`, `<RadioImagePage DependsOn=…
  CheckDefaultBrowser="true">`. Never touch `UniqueId` or the edition marker (wdtool gate).

## 6. Not worth adopting

The install-state/resume engine, Fresh/Upgrade/Rebase modes, the TrustedInstaller broker and `Atlas.Native.cs`,
toggles and their generated launchers and catalog, Atlas Manager (Rust/GPUI), ISO creation, the reports service,
the UBR release catalog, the Safe Mode CBS retry (AME + wdtool would need a whole new recovery path), and Atlas's
taskbar pin blobs (binary values recorded per build, high upkeep).

## 7. Atlas Toolbox compared with the WinDebloat Tool

Source: `reference/atlas-toolbox-main` (Atlas Toolbox 0.2.0 beta, read 2026-11-10; `TB/` = its `AtlasToolbox/` folder).
It is the post-install settings app, our counterpart being `wdtool`/`wdtoolw` (`debloat-tool/`).

### What it is
A C# / WinUI 3 (.NET 8) app installed with Inno Setup, about 5,600 lines. **It contains no tweak logic.** Everything
it knows comes from three files Atlas installs (`README.md`, `TB/Atlas/AtlasContract.cs`):

| File | Used for |
|---|---|
| `AtlasModules\Toggles\catalog.json` (`schemaVersion` 1) | every toggle: states, recorded value, default, warning, reboot need, elevation, and `work.user` (the state changes the signed-in user's own settings) |
| `C:\Windows\AtlasOS\state.json` | installed Atlas version and the recorded state per toggle; watched with a debounced `FileSystemWatcher` |
| `Scripts\Entry\Invoke-AtlasToggleLauncher.cmd` | applies a state by toggle name, exactly as the Desktop launchers do |

Its pages are lists of toggle names (`TB/HostBuilder/AddViewModelsHostBuilderExtensions.cs`); a name missing from the
installed catalog is hidden and logged, and any Atlas outside the 0.6 series is refused. The catalog is generated
from the toggle definitions (`tools/dev/Export-AtlasCatalog.ps1` in Atlas, CI-checked), so the app and the install
can't drift apart.

### Compared with ours
- **One implementation per setting, partly.** Our playbook already delegates 15 settings (18 calls) to `wdtool tweaks …`
  (hibernation, fast startup, Defender, VBS, power plan, NTFS, background apps, …), the same idea as Atlas. But some
  settings the GUI offers are *also* written directly by YAML: the classic context menu
  (`registry/explorer/context-menu.yml:8` and `personalization_service.dart:460`) and Explorer Home
  (`windebloat-shell.yml:50` and `personalization_service.dart:659`). The values match today; nothing keeps them matched.
- **State.** Atlas records what was chosen (`state.json`); our tool reads the live registry for each status getter.
  Live reads are simpler and can't go stale, but there is no record of what the *playbook* chose, so a feature update
  that resets a value is indistinguishable from a user choice. This is the same gap as the health-check idea in Tier 3.
- **Self-update (checked in our code):** `debloat-tool/src/lib/core/settings/tool_update_service.dart` downloads
  `WinDebloatTool-Setup.exe` from `releases/latest` into `%TEMP%`, writes `wdtool_update.cmd` next to it and runs it
  from the elevated tool, with no hash or signature check. `%TEMP%` is writable by the user's unelevated processes,
  so a medium-integrity process can swap either file before it runs elevated. The Toolbox instead hands its update to
  Atlas's installer, which pins the repo by ID and checks the asset digest and Authenticode signer (see Atlas
  `Atlas.Download`, section 5 idea 17). Our CBS cabs are staged in `%TEMP%\WinDebloat-Tool\CAB` too, but CBS checks
  their signature itself, so the exposure there is small.
- **Installer pitfall not to copy:** the Toolbox's `Installer/setup.iss` keeps the Inno wizard's association block
  with `MyAppAssocExt ".exe"` and `ChangesAssociations=yes`, which adds the Toolbox to "Open with" for every `.exe`.
  Our `debloat-tool/inno-setup.iss` has no such block (checked).

### Techniques worth taking

| # | Idea | Where | Rule 2 | Verify |
|---|---|---|---|---|
| T1 | Verify the self-update before running it: stage in a folder only SYSTEM/Administrators can write (Toolbox `TB/Utils/ProtectedFolder.cs`: explicit SDDL, refuse reparse points), require the GitHub asset `digest` sha256 and an Authenticode signature check before launch | `tool_update_service.dart` | no | manual update from an older build |
| T2 | Run as the signed-in user without elevation, from the elevated tool: `TB/Atlas/UnelevatedProcess.cs` starts the child with Explorer (`GetShellWindow`) as `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS` and an environment block from Explorer's token. Candidates: default-app work that must happen in the user's own context (learnings, "Default apps"), anything `currentUserElevated` gets wrong | `wdtool` (Rust/Dart native) | no | VM, check the child's token |
| T3 | One implementation per GUI setting: where `wdtool` has a toggle, have the YAML call `wdtool tweaks … ` instead of repeating the keys, or add a static test that flags YAML keys a `@CliToggle` service also writes | YAML + `tests/` | swapping YAML lines for a call: **yes** | end-state check |
| T4 | Settings profiles: the Toolbox saves the on/off state of every item to a JSON profile and re-applies it later (`TB/Utils/ProfileSerializing.cs`). `wdtool`'s `@CliToggle` annotations already list name/status/enable/disable, so `wdtool profile export|import` is mostly generated. Fits the backlog goal of a yearly reinstall with settings carried over | `wdtool` | no | export, apply on a clean VM, compare |
| T5 | Silent runs close stdin so a script that asks a question fails instead of hanging, read output in the console code page, and run one change at a time (`TB/Atlas/ToggleRunner.cs`) | `wdtool` shell helpers | no | — |

Not worth taking: the WinUI app itself, the version-series lock (our exit-55 gate already does that job), and the
software page (39 hard-coded winget IDs; our `Apps/*.json` groups are richer).

## 8. VM validation (2026-11-10)

Where: `windowstest-hv`, checkpoint `clean-defender-off-UAC-off` (build 26300.9457), the package built from the working
tree, the released 26.10 `WinDebloatTool` installer. The probe scripts are scratch files, not in the repo. Runs: **hv22**
(regular apply, `-RebuildLayers`: 1065 applied, 0 failed, 5/5 cabs, live check 898 of 911, 0 unexpected), **hv23** (apply on
a base with every update installed first), and three experiments B, C, D on the component store. The test user, the
experiment checkpoint and the installed updates were removed again; the VM is off and has its two original checkpoints.

### 8.1 Component store (2.1): confirmed

| Step | Build | `ScanHealth` | Store |
|---|---|---|---|
| Apply (hv22), then a forced `StartComponentCleanup` | 9457 | clean, clean | |
| Our cabs on, then CU KB5127648 installed, **before any cleanup** (C) | 9711 | clean | 10.52 GB, 3 reclaimable |
| ... then `DISM /StartComponentCleanup` (B and C, same result both times) | 9711 | **"The component store is repairable"** | 7.44 GB |
| Same updated base **without our cabs**, same cleanup (D) | 9711 | clean | 6.93 GB |
| Disk Cleanup `/sagerun:1337` (the `CLEANER.ps1` path) instead of DISM (F c3) | 9711 | **repairable** | 7.44 GB |
| `DISM /StartComponentCleanup /ResetBase` (F c4) | 9711 | **repairable** | 7.26 GB |
| After the damage: `DISM /RestoreHealth` (11 min, "completed successfully"), then `sfc /scannow` (48 min, "repaired"), then a second cleanup (F c5) | 9711 | **still repairable; corrupt payloads 3, then 97** (OOBE and other 1591 components added) | 7.9 to 8.1 GB |
| Windows's `Servicing\StartComponentCleanup` task: right after the CU (F c1), and with the clock 35 days ahead, waiting for the servicing worker (G1) | 9711 | clean | 10.5 to 10.65 GB, still 3 reclaimable (it removed nothing) |
| **Normal user order (G2):** Windows fully updated first, then the apply (its own `cleanmgr` and `SilentCleanup` ran, cabs not yet committed), commit reboot, two more reboots | 9711 | clean | 10.0 to 10.2 GB, still 3 reclaimable |
| ... then a forced `DISM /StartComponentCleanup` on that store (G2) | 9711 | **repairable** (3 corrupt payloads) | 6.95 GB |

`CBS.log` lists `CSI Payload Corruption: 3`: `aeinvext.dll` and `Microsoft.Management.Deployment.winmd` in the AppInv
component `10.0.26100.1591`, and `nonarpinv.dll` in `inventory-nonarpinv` `10.0.26100.1591`. These are the components
Atlas names. So the cause is our cabs, a newer CU and then cleanup, together. The CU alone leaves the store clean (C), and
cleanup alone on a store without our cabs does too (D).

What this means:
- **There is no repair.** `/RestoreHealth` and `sfc` both report success and leave the store repairable, and
  `RestoreHealth` makes it worse (3 to 97 corrupt payloads). That is what Atlas's docs warn about. A second cleanup
  afterwards does nothing.
- **The damage needs a component cleanup that runs after our cabs are committed.** A manual `DISM /StartComponentCleanup`,
  `/ResetBase` and the Disk Cleanup "Update Cleanup" handler all do it, in either install order. Cleaning *before* the
  cabs (Atlas's rule) was not needed for the first apply, but does nothing for a cleanup run later.
- **Our own apply-time cleanup is harmless in the normal order.** In G2, `CLEANER.ps1`'s cleanup ran during the apply,
  before the cabs were committed, and removed nothing; the store was clean after the commit reboot and two more
  reboots. Keeping `CLEANER.ps1` as it is does not damage a new install.
- **Windows's own scheduled task did not trigger it** in two tries. That is not proof it never will: moving the clock
  35 days is only a rough stand-in for 30 days of real use.
- So the risk is a **later** cleanup on a machine that has our cabs and a CU: Disk Cleanup's "Windows Update Cleanup" run
  by hand, a cleaner tool, or `DISM /StartComponentCleanup`. We cannot repair the result.

Not tested: what a repairable store costs later (installing the next CU, a feature update, `/RestoreHealth` offline, for
which Atlas reports `0x800F0915`); which of our five cabs supersedes AppInv; the real 30-day wait of the scheduled task.

Options for the maintainer: (1) keep `CLEANER.ps1` as it is and add a docs warning plus the `/ScanHealth` canary in the
harness end state (idea 1; no rule 2); (2) additionally try to stop Disk Cleanup from offering "Windows Update Cleanup"
after the cabs go on, so a user cannot trigger it by accident (idea, untested; changes existing behaviour, rule 2).

**A real machine is already in this state.** A Windows 24H2 machine (build 26100.7840) that runs an older release of the
playbook (cabs 2.1.1.0) reports "The component store is repairable" from `CheckHealth` and `ScanHealth`, with 377 corrupt
payloads in three components, all at the `10.0.26100.1591` baseline: a `cloudexperiencehost.appxmain` component (345 files),
a `...okerplugin.appxmain` component (27) and a `...riencehost.appxmain` component (5). These are not the AppInv files
from the VM, so the cab version or the Windows build changes which components break. It shows 2 reclaimable packages;
Windows's own `StartComponentCleanup` task ran that morning and logged "skipping scavenge". Not known: when and what
damaged it (the retained `CBS.log` starts that day) and whether the owner ran a cleanup by hand. `/RestoreHealth` and
`sfc` were deliberately not run, because on the VM they made it worse. **Observed effect: none.** The owner sees no
problem. The cabs went on 25 Feb 2026, and the security updates KB5077181 and KB5077869 installed on 2 Nov 2026 with no
failed-install event in the Windows Update log and no `0x80073712` in the retained `CBS.log`. We do not know whether the
store was already damaged at that update. What is at stake is limited to operations that need those components' baseline
files (a repair tool, a feature update); Atlas documents `0x80073712` as the failure to expect and ships with the state
anyway. We have seen none of that, so for now this is a failed health check, not a known failure.

### 8.2 Update first (2.2): the apply-time race is gone, the later one is not measured

- The regular base was **not up to date**: pending were the October CU KB5127648 (26300.9711), .NET KB5127694, MSRT
  KB890830, Defender platform KB4052623, Windows Security platform KB5007651, Defender definitions KB2267602 and two
  drivers. Store apps were behind too (`MSTeams` 1.0.0.1 became 26276 after the Store scan, plus Photos and others).
  Atlas's preparation gate would refuse to run on that base.
- I installed everything (two rounds and a reboot pair; the update API refuses PowerShell Direct sessions, so the
  install runs as a SYSTEM scheduled task), let Store staging settle for 8 minutes, checkpointed, and applied (hv23).
- After two reboots: no targeted package left for the user or provisioned, `InboxApps` empty, 5/5 cabs. `postclean.log`:
  `StartExperiences` and `Teams` "nothing to remove" (the main steps had already removed them); `Copilot` (the Edge-installed
  Win32 app) still needed the sweep, uninstalled via `copilot_setup.exe` (exit code 19, then gone). So `POSTCLEAN.ps1` stays.
- SYSTEM-only leftovers, warnings by Atlas's rules: `EdgeDevToolsClient`, `PeopleExperienceHost` (both NonRemovable),
  and a staged `Microsoft.Edge.GameAssist` that the regular base did not have. `WebExperience` was staged in hv22, absent
  in hv23, and staged again after the CU in experiment B.
- **Not shown:** that the three apps stay away. The window was two reboots; the learnings' reappearance comes later. The
  regular base was also clean at the same point.
- Side effect: updating first exposed a regression, section 8.5 (a).

### 8.3 `HKU\.DEFAULT` (2.3): the documented reason is wrong

After the apply, the Default profile hive (`C:\Users\Default\NTUSER.DAT`) matches 11 of 238 expected `HKCU` values, all of
them Windows defaults. A new local user (created after the apply, own logon) also gets 11 of 238 and **none** of the
non-default ones: no `LaunchTo`, `Hidden`, `HideFileExt`, theme or classic context menu. The 139 `.DEFAULT` twins land in
`HKU\.DEFAULT` 139 of 139, which is the SYSTEM profile. So AME does not write `HKCU` into the Default profile, and new
accounts inherit none of the `HKCU` tweaks. `AGENTS.md` said the opposite; corrected and a Default-hive pass added in 8.8 (idea 6, done).

### 8.4 Appx re-read (2.6) and MDCoreSvc (2.7)

2.6: after the apply nothing the appx files target is left for the user or provisioned (idea 12 would not have found a
failure). 2.7: `MDCoreSvc` exists as an empty key (no `Start`, no `ImagePath`) and the boot logged no service-control error
(7000/7009/7023/7024/7031/7034/7038), so idea 13 is not needed on 26300.

### 8.5 Findings that are not from Atlas

**(a) UCPD blocks two Feeds policy writes on the updated build.** On 26300.9711 the apply failed two tweaks (hv23 and again hv24: 1063 applied,
2 failed, live check 2 unexpected):
`taskbar.yml#5` `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds\EnableFeeds` and `taskbar.yml#10`
`HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests`. On 26300.9457 with UCPD running the same writes succeed (hv22,
and by hand as the control). On 9711 they fail with "access denied" for PowerShell and `reg add` alike, `sc stop UCPD` is
refused (1052), and after the reboots, when `services.yml` has set UCPD to Start=4 and the driver is stopped, the values
are still missing. So one pass on a current Windows leaves them unset. Fix candidate (an addition, untested): write the two
values again once after the first reboot, when UCPD is stopped (a first-boot task or the `POSTCLEAN.ps1` scheduled task). Not
tested: whether a write after that reboot lands.

**(b) The pending `NoAutoUpdate` change.** Upstream commit 9c334b1 (merged in 2d06578) makes `enablePauseUpdatesWU` also
write `HKLM\...\WindowsUpdate\AU\NoAutoUpdate=1` (`updates_service.dart`, "since 2026 Q4, pausing updates no longer
enough"). `updates.yml:13-15` has that value commented out because it broke Xbox sign-in, and `updates.yml:22` calls the
toggle. The VM uses the released 26.10 installer, which does not write it (the probe found no `NoAutoUpdate`), so this
has not been seen; it returns once CI builds the merged tool. Needs a decision (rule 2 in spirit).

**(c) Harness: a CBS commit race on L1 restore.** hv21 failed: the five cabs rolled back with `0x800f0922` because the
harness's own first PowerShell Direct logon, 11 s after boot, raced the CBS per-user installer
(`OpenProfileRootKey STATUS_OBJECT_NAME_NOT_FOUND`). When no logon touched the first 5 minutes (B, C) or the first boot
came straight after saving (hv22), the cabs committed. An early logon after a normal reboot also committed once (hv23), so
it is intermittent. Fix candidate: after restoring a layer, wait for the commit before the first logon.

**(d) Harness: `postclean.log` is not collected.** It lives in `C:\ProgramData\WinDebloat\Post-Clean\`; earlier runs
(hv19 to hv22) only have the script. Pull it with the other logs.

### 8.6 Not tested

Start pins (2.4), `AllowExperimentation` and Known Issue Rollback (2.5), the toast mute (2.9), the AI and privacy policies
(idea 8), the service-policy review (2.8), and every Atlas Toolbox idea. Those remain claims from reading code.

### 8.7 Suggested order

1. 2.1: add the `/ScanHealth` canary to the end state and a docs warning; decide whether to guard against a later
   "Windows Update Cleanup" (8.1, option 2).
2. 8.5 (a): the post-reboot write of the two Feeds values.
3. 8.5 (b): decide on `NoAutoUpdate` before CI builds the merged tool.
4. Correct `AGENTS.md` and `windebloat-extension.md` (8.3).
5. Harness: wait for the CBS commit after a layer restore, collect `postclean.log`, refresh the base with updates so runs match what users have.

### 8.8 Implemented from these findings (2026-11-10)

Decisions taken after section 8, with what was and was not verified. Setup: Hyper-V `windowstest-hv`, base `atlas-exp-base-updated2`
(clean checkpoint plus Windows Update to 26300.9711), full uncached harness runs hv25 and hv26 (package rebuilt, applied),
compared with hv24 on the same build (1063 applied, 2 failed, engine `errors`).

| Decision | Change | Result (hv26: 1067 applied, 0 failed, engine `success`, 0 unexpected end-state entries) |
|---|---|---|
| 2.3 new users get no HKCU tweaks: fix docs, add a Default-hive pass | `Executables/DEFAULTUSER.ps1` run from `final.yml`; `AGENTS.md`, `windebloat-extension.md` and the learnings corrected | Copied 221 values, 0 failed. A new account: **218 of 238** expected values, was 11. The other 20 are the Photo Viewer associations overwritten by `FILEASSOC.cmd`, `TaskbarDa`/Feeds (Windows protects them) and `HighContrast`. Same 218 after a reboot |
| UCPD denies the two Feeds policy writes: re-write after the first reboot | `POSTCLEAN.ps1 -Target FeedsPolicy -Register` (`final.yml`); `errorAction: Ignore` on `taskbar.yml` #5 and #10 | On the hv24 and hv26 guests both writes were denied during the apply (logged, not an error) and, after the reboot, the startup task set both to 0 (`removed (2 item(s))`); hv24's 2 failed are gone. On the rebuilt base of hv27 and hv28 both writes succeeded and the task logged `nothing to remove`: the denial is **not deterministic**, the task is harmless when it is not needed |
| NoAutoUpdate: take upstream | no playbook change | Tested in part, see 8.9: the released 26.10 tool on the VM does not write `NoAutoUpdate`, so the value was set by hand |
| Store cleanup: keep `CLEANER.ps1`, warn | README warning. The `/ScanHealth` canary in the harness is **not added yet** | Cabs 5 of 5 `Installed` after the apply and reboot |

**New finding.** wdtool mounts the Default profile hive as `HKU\DefaultUserHive` for its own HKCU tweaks and never unloads it. While
it is mounted Windows cannot copy `C:\Users\Default\NTUSER.DAT` for a new account and logs the user on with a temporary profile (events
1509 and 1511). Unloading the hive fixed it at once; a reboot also clears it. This predates the Default-hive pass (the mount was
already there when it ran), so it affects an account created between the end of the apply and the next restart. `DEFAULTUSER.ps1`
reuses the mount. A last step in `final.yml`, after the final wdtool call, now unloads it (8.9).

### 8.9 Second round (2026-11-10, later)

Decisions taken after the first round. Same base (`atlas-exp-base-updated2`, rebuilt), full uncached harness runs hv27 and hv28.
**hv27 and hv28 both: 1075 applied, 0 failed, 82 skipped, engine `success`, 908 of 918 end-state entries match, 0 unexpected**
(hv26: 1067 applied; the 8 more are the 7 AI values and the unload step).

| Decision | Change | Verified |
|---|---|---|
| Unload the Default hive at the end of the apply | last step of `final.yml`, after the final wdtool call (`reg unload HKU\DefaultUserHive`, 6 tries, never fails the apply) | After the apply the mount is gone. An account created **with no reboot** got a normal profile and **218 of 238** expected values (hv27 and hv28), where before it got a temporary profile |
| NoAutoUpdate: test | none (upstream tool writes it) | By hand on 26300.9711, with updates paused: Gaming Services installed from the Store the same way before and after `NoAutoUpdate=1` (`winget install 9MWPM2CQNLHN`, exit 0, `GamingServices`/`GamingServicesNet` started), a Windows Update scan still ran (it found a driver update), and `XblAuthManager` started. **Not tested:** the Xbox sign-in itself (needs a Microsoft account), Windows 10 (where it broke), and the real merged tool build (the VM runs the released 26.10) |
| Collect `postclean.log` in the harness | `tools/vmtest/guest-agent.ps1` copies `Post-Clean\` and `default-user.log` | Both files are in `logs/WinDebloat/` of hv27 and hv28. The scheduled task runs after the reboot, so a run that collects first shows only the apply-time pass |
| CI checks (ideas 3, 4, 5) | `tools/verify_playbook.py`; `.github/workflows/verify.yml` (push, PR, and a gate in `main.yml`); `main.yml` re-opens the built `.apbx` with `--package` | Run locally only: 0 errors on the real tree and Windows PowerShell 5.1 parses all 16 scripts; 8 defects injected into a copy (unknown tag, unquoted `data`, unknown option, missing task path, missing Executable, non-ASCII, mixed line endings, ReviOS name) were all caught; package mode caught a wrong version, a changed file and a missing installer on a `.zip` and on an encrypted-header `.apbx` written by `py7zr`. **Later:** `verify.yml` passed on GitHub (run 42790120255, commit 88304bb). **Not run:** the `--package` step of `main.yml` (needs a release run) and anything with the real `7z` binary locally |
| New AI policies (idea 8) | 7 values in `registry/security/windebloat-ai.yml`, gated on `remove-winsxs-ai`: `DisableSettingsAgent`, `RemoveMicrosoftCopilotApp`, Notepad `DisableAIFeatures`, Paint `DisableCocreator`/`DisableImageCreator`/`DisableGenerativeFill`, `ConsentStore\generativeAI` Deny | All 7 present after the apply (hv27, hv28). **Not tested:** that Notepad and Paint actually hide the features (needs an interactive session) |
| Halt when the tool install fails (idea 14) | `start.yml`: the installer is a `!run` with `handleExitCodes: { "!0": halt }` | Forced failure with a stub installer that exits 2, on the clean base: **A** (old step) ran all 1112 steps, 20 failed, "completed with errors"; **B** (throw under `errorAction: Halt`) flagged the install step but also ran all 1112, so `errorAction: Halt` does **not** halt on this AME CLI (0.8.4); **C** (`handleExitCodes`) stopped after 38 s: "Playbook halted due to a critical error ... exit code 2 handled with filter '!0' --> Halt.", engine `fatal`. **D** (installer file missing): does **not** halt (an error is recorded and all 1112 steps run), because a missing file is not an exit code; the CI package check (installer present, over 1 MB) is what covers that. hv28 with the real installer passes |
| Start pins through the supported policy (idea 10) | none | **Not testable on this VM.** The experiment needs a second account to log on interactively; the harness base re-asserts autologon as `admin` on every boot (`DefaultUserName` and `AutoLogonSID` reverted after two attempts), and keyboard injection is not allowed. Decide on Atlas's design and Microsoft's policy (KB5062660) instead, or test on a real machine |

**New finding for a decision.** `registry/explorer/explorer.yml` (lines 98-102) uses the option `configure-explorer-taskbar-animations`,
which `playbook.conf` does not define. The positive branch (set `TaskbarAnimations` to 0) can never apply and the negated branch (delete
it) always runs, which is why Appendix B shows it as "deleted". Defining the option or removing the dead branch changes behaviour, so
it needs the maintainer's yes; `verify_playbook.py` reports it as a warning meanwhile.

### 8.10 Backlog status (2026-11-10)

Where each ranked idea stands after 8.8 and 8.9. "Done" means implemented and verified as stated in those sections.

| Status | Items |
|---|---|
| Done | 3, 4, 5 (CI checks; `verify.yml` green on GitHub, the `main.yml` package check not yet run), 6 (Default-hive pass), 8 (AI policies), 14 (halt on tool install failure), 1 (`/ScanHealth` canary, section 8.11) |
| Open, no decision needed | 7 (mute toasts), 9 (update-first gate for users), 15 (extra appx), 16 (Appendix A tweaks), 17 (download hardening), T1 to T5, all of Tier 3 |
| Open, needs the maintainer (rule 2) | Tier 3 service and hibernate changes |
| Decided 2026-11-10 | 2: keep `CLEANER.ps1`, docs and canary only. 11: keep `AllowExperimentation`. `configure-explorer-taskbar-animations`: option defined (8.11) |
| Open, blocked on testing | 10 (Start pins: needs a second interactive account), `NoAutoUpdate` on the CI-built tool and on Windows 10 (8.9) |
| Dropped | 12 (appx re-read: nothing was left, 8.4), 13 (MDCoreSvc task: no event 7023, 8.4) |

From the maintainer's own `backlog.md` (untracked): the weekly `winget upgrade --all --silent` task with a log is built
as an option (8.11); settings persistence across a yearly reinstall maps to T4 (`wdtool profile export|import`), not built.

### 8.11 Backlog build-out (2026-11-10, evening)

Decisions: define the taskbar-animations option, add the `/ScanHealth` canary (idea 1), build the weekly winget task from
`backlog.md`. Setup as 8.9 (`atlas-exp-base-updated2` was not used: run **hv29** started from the regular base
`clean-defender-off-UAC-off`, build 26300.9457), full uncached apply with both new options ticked, then checks in the guest.
**hv29: 1076 applied, 0 failed, 83 skipped, 0 unconfirmed, engine `success`, 905 of 918 end-state entries match, 0 unexpected,
`storeHealth` clean; result pass (exit 0).**

| Change | Where | Verified |
|---|---|---|
| Option `configure-explorer-taskbar-animations` ("Disable taskbar animations", unchecked) | `playbook.conf` page "General configuration options, page 2"; `explorer.yml` unchanged apart from a comment | Ticked in hv29: `TaskbarAnimations=0` in HKCU and `HKU\.DEFAULT`. **Not tested:** unticked on the VM (it is the old behaviour, the delete branch that always ran), and that the animation is really off on screen. `verify_playbook.py` has no known-undefined option left |
| Canary: `DISM /ScanHealth` after the final live check, `storeHealth` in `summary.json`, `repairable` or `not-repairable` fails the run, no verdict = harness error, `-NoStoreHealth` skips | `tools/vmtest/store-health.ps1`, `tools/vmtest.ps1`, `docs/vmtest.md` | hv29: clean in 150 s. Repeated by hand on the same guest: clean, 54 s, build now read from the registry (26300.9457). The status parser was tried on the three DISM sentences and an error text. **Not tested:** the `repairable` path end to end, which needs a store damaged the way 8.1 did (CU, cabs, cleanup) |
| Weekly winget task: option `windebloat-weekly-app-updates` (unchecked), `WEEKLY-UPDATE.ps1 -Register` from `final.yml`; the script is always staged (`-Stage`) so the tool can switch the task later (8.12) | `playbook.conf`, `final.yml`, `Executables/WEEKLY-UPDATE.ps1` | hv29: task registered for `admin`, Highest, Interactive, Sundays 12:00, 3 restarts 30 min apart, network required, next run 15 Nov. Run by hand through the task in the guest: found the updates for App Installer and Windows Terminal, installed them, log written, task result 0. The first run showed winget's progress bars as garbage in the log (console code page); fixed by setting UTF-8 and re-run: clean log, exit code 0. `-Unregister` then `-Register` by hand: task gone, then back. **Not tested:** the Sunday trigger itself, the retry on no network, the log pruning (12 files), a run with the user logged off (the task is Interactive and only runs while the user is on; `StartWhenAvailable` catches a missed Sunday at the next logon) |

Limits of the weekly task, as built: only the `winget` source (Store apps are left to the Store), packages with an unknown
installed version are skipped (`--include-unknown` is not used on purpose), pinned packages are skipped by winget, and an
upgrade that needs the app closed ("Restart the application") is logged but not forced. It does not use wdtool or the
playbook's own cabs, so it cannot touch the component store.

### 8.12 On/off switches in `wdtool` (2026-11-10, **not compiled or run**)

Both settings from 8.11 can now be switched after the install, from the CLI and the GUI. **This is source only: there is no
Dart or Flutter SDK on this machine, `.g.dart` files are generated in CI, and a local harness run uses the released tool, so
none of it has been built, analysed or run.** The first CI build (`main.yml`, manual) is the first compile.

| Setting | CLI (generated from `@CliToggle`) | GUI | How |
|---|---|---|---|
| Taskbar animations | `wdtool tweaks personalization taskbar-animations enable / disable / status` | Personalization, desktop section | Status: `HKCU\...\Explorer\Advanced\TaskbarAnimations` is not 0 (absent = on). Enable deletes the value, disable writes 0; both restart Explorer like the neighbouring toggles. Current user only: the Default profile that new accounts copy still comes from the playbook (`DEFAULTUSER.ps1`) |
| Weekly app updates | `wdtool tweaks utilities weekly-app-updates enable / disable / status` | Utilities page, last card | Status: the Task Scheduler cache key `...\Schedule\TaskCache\Tree\WinDebloat Weekly App Update` exists. Enable runs the staged `%ProgramData%\WinDebloat\Weekly Update\WEEKLY-UPDATE.ps1 -Register` (fails with a message when the playbook never staged it); disable runs `schtasks /Delete` and leaves the logs |

Playbook side, verified by run **hv30** (full uncached apply, 1077 applied, 0 failed, 905 of 918 live entries, 0 unexpected,
store clean, pass; the guest has the staged script, the registered task and its Task Scheduler cache key, which is what the
tool's status getter reads): `final.yml` always stages the script; the "unregister when the option is
unticked" step was dropped, so re-applying the playbook never removes a task the user switched on. The playbook still writes
the same registry value for taskbar animations itself (`explorer.yml`), so the two paths must keep matching (T3 in section 7).
Unit tests: mock tests for both services, plus status checks in the integration groups that CI skips by default.

## Appendix A: Atlas tweaks we do not have (candidates)

Matched by registry path tail + value name against `src/`; a hit anywhere counted as "have", so some of these may
exist under another path. Atlas paths are under `AM/Tweaks/`.

- **Privacy / telemetry:** Enhanced Phishing Protection `WTDS\Components\ServiceEnabled=0`, `CaptureThreatWindow=0`
  (loses password-reuse warnings; `privacy/telemetry/disable-phishing-protection.psd1`);
  `EnableDeviceHealthAttestationService=0`; WDI PerfTrack `{9c5a40da-…}\ScenarioExecutionEnabled=0`;
  `Control\Diagnostics\Performance\DisableDiagnosticTracing=1`; `Speech\AllowSpeechModelUpdate=0`; `WMDRM\DisableOnline=1`;
  MSRT reporting (`MRT\DontReportInfectionInformation`, `HeartbeatTrackingIndex=0`); Office 16 `sendcustomerdata=0`,
  `qmenable=0`, `sendtelemetry=3`; `EnableDynamicContentInWSB=0`; `StorageTelemetry\DeviceDumpEnabled=0`;
  `SettingSync\SyncPolicy=5`. `NoConnectedUser=1` blocks *adding* Microsoft accounts (never 3, which locks out MSA
  users): test against Store sign-in first.
- **Performance / system:** FTH off (`FTH\Enabled=0` + `fthsvc.dll,FthSysprepSpecialize`); maintenance `WakeUp=0`
  (keep maintenance itself: it runs TRIM); search `RespectPowerModes=1`; Sleep Study logs off (`wevtutil set-log /e:false`
  on three Diagnostic logs); `dism /Set-ReservedStorageState /State:Disabled`; tasks `\Flighting\FeatureConfig\UsageDataReporting`
  and `\Autochk\Proxy` (CEIP, "stays Ready after the other CEIP tasks are disabled").
- **Windows Update:** `AUPowerManagement=0`; `ManagePreviewBuilds=1` / `ManagePreviewBuildsPolicyValue=0`;
  `HideInsiderPage=1`. Atlas deliberately does not write `DeferFeatureUpdates*`.
- **Security / networking:** `RestrictAnonymous=1`, `RestrictAnonymousSAM=1`, `RestrictNullSessAccess=1`;
  `LanmanWorkstation\DisableBandwidthThrottling=1`; Remote Assistance off (`fAllowToGetHelp=0`, `fAllowFullControl=0`);
  Windows Security pages hidden by `UILockdown=1` (Family options, Device performance and health, Account protection).
  Atlas keeps LLMNR on (single-label home-LAN names) and lists `PromptOnSecureDesktop=0` as a security trade-off: skip both.
- **Shell / QoL (long tail):** `ShowOrHideMostUsedApps=2`, `HideRecommendedPersonalizedSites=1`, `DisallowShaking=1`,
  `MultiTaskingAltTabFilter=3`, `NoResolveTrack=1`, `LockScreenOverlaysDisabled=1`, `AmbientLightingEnabled=0`,
  USB-error and weak-charger notifications off, Previous Versions / Include in library / Share / Print context
  entries removed, accessibility sound and visualisation defaults. Full list: the `Registry` blocks under `AM/Tweaks/qol/`.

## Appendix B: same setting, different value

| Setting | Atlas | Ours |
|---|---|---|
| `Explorer\Advanced\LaunchTo` | 1 (This PC) | 3 (Downloads), `registry/explorer/explorer.yml` |
| `AllowCloudSearch` | 0 | 2, `search.yml` |
| `AllowCrossDeviceClipboard` | 0 | 1, `win-settings.yml` |
| `EnableAccountNotifications` | 0 | 1 (already in `windebloat-conflicts.md`) |
| `DisableClickToDo` | HKLM 1, HKCU policy deleted | HKLM, HKCU, `HKU\.DEFAULT` all 1 |
| `TaskbarAnimations` | 0 | deleted |
| Accessibility hotkey `Flags` | targeted bit values | all 0 (already known) |
| Start pins | `Policies\...\Explorer\ConfigureStartPins(JSON)` | `PolicyManager\current\device\Start\ConfigureStartPins` (2.4) |
| `AllowExperimentation` | not set (removed) | PolicyManager 0 (2.5) |
| Background apps | off, per user `GlobalUserDisabled=1` | on (reverted for Game Bar) |
| `DisableAutomaticRestartSignOn` | 1 | reverted (slow Hello) |
| Services `DiagTrack`, `WerSvc`, `diagnosticshub…`, `UCPD`, `GpuEnergyDrv`, `Telemetry` | Windows default, policies instead | disabled |
