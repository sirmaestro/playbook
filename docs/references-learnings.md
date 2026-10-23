# Learnings & gotchas (distilled from the reference projects)

Hard-won facts from investigating ReviOS/AME internals (`revision-tool`, `trusted-uninstaller-cli`,
`meetrevision/packages`, the ReviOS playbook) and from testing on a Windows 11 VM. These are the
things that are expensive to re-derive. Keep this current.

## Why component removal needs revitool/CBS (and a plain script can't do it)

Goal some users want: **no Defender processes at all**, not just "AV disabled". The boundary:

- **Registry/policy disable can never reach zero processes.** Setting the Defender policy keys
  (`DisableAntiSpyware`, `DisableRealtimeMonitoring`, …) makes Defender *inert*
  (`Get-MpComputerStatus` → `AntivirusEnabled:False`, `AMRunningMode:Not running`) but `MsMpEng`
  (`WinDefend`) and `MpDefenderCoreService` (`MDCoreSvc`) **still run**. After a reboot the platform
  **self-heals** `WinDefend`/`MDCoreSvc` `Start` back to `2` (a platform update re-arms them).
- **You cannot force the service `Start` values — even as TrustedInstaller.** `WinDefend`, `MDCoreSvc`,
  `WdFilter`, `WdBoot`, `WdNisDrv/Svc` reject the write ("Attempted to perform an unauthorized
  operation"): they run as **PPL (protected anti-malware)** and self-protect their own registry keys
  against everything, **independent of Tamper Protection**. (Only `Sense`/`webthreatdefsvc`/`wscsvc`
  are writable.) So "force Start=4" is a dead end for the core processes.
- **The only thing that removes the processes is removing the components — a signed CBS package.**
  That is exactly what `revitool winpackage --install …` / `revitool tweaks security defender disable`
  do. Use them. Do **not** try to hand-roll a CBS package install.

### The CBS signing wall (why we can't reproduce revitool's removal in a script)

`Add-WindowsPackage`/DISM require the package's signing cert to chain to a root on **Code Integrity's
internal allowlist** (e.g. thumbprint `8A334AA8052DD244A647306A76B8178FA215F344`, which CI trusts
internally and is *not* in the local Root store). Consequences, verified on the VM:

- Importing a self-signed cert into `LocalMachine\Root` is **not** enough → DISM returns
  `0x800b0110 CERT_E_WRONG_USAGE`.
- **AME's bypass** (`trusted-uninstaller-cli/…/Defender.cs`): disable UCPD, `Import-Certificate` the
  cab's signer to `Root`, **`Copy-Item` its registry blob into the allowlisted slot**
  `HKLM\…\SystemCertificates\ROOT\Certificates\8A334AA8…`, `DISM /Online /Add-Package /IgnoreCheck`,
  then delete the cert+slot. Fallback on failure: reboot to Safe Boot and apply there.
- **That bypass works only with AME's *own* cab**, whose leaf chains (via Authority Key Identifier) to
  the `8A334AA8` root. The public `meetrevision/packages` `Defender-Removal` cab is **self-signed**
  (issuer==subject, no AKI, thumbprint `183E66…`): CI builds its chain to *itself* (not allowlisted)
  and never consults the `8A334AA8` slot, so the slot trick does nothing → `CERT_E_WRONG_USAGE`
  regardless. Confirmed by two independent attempts.
- **Net:** a tool that won't ship-and-trust its own signing root cannot strip Defender components on
  stock Windows — this is Microsoft's CI allowlist working as designed. **This is the reason WinDebloat
  is being folded into the playbook** (which has `revitool` and runs in AME's trusted context) rather
  than shipped standalone.

## What the CBS removal packages actually do (`meetrevision/packages`)

`revitool winpackage --install <name>` installs a signed CBS cab. Mechanism: for each
`target_component` the package registers an *update at version `38655.38527.65535.65535`* (max), so
CBS supersedes Microsoft's real component with an empty one — the component's files/registration drop
out while the servicing manifest stays consistent (durable; survives Windows Update — unlike the
deprecated raw-`systemPackage` file delete that caused issue #49). Payload escape hatches: export-only
**PE stubs** for DLLs that can't be removed without breaking boot (telemetry: `utcapi`/`utcutil`/
`sqmapi`), **registry** values, or **file** replace/delete.

Packages and notable **deliberately-kept** components (don't "fix" these — they're intentional):

- **telemetry-removal** — stubs `utcapi.dll`+`utcutil.dll` (system won't boot without them) and
  `sqmapi.dll` (statically imported by recovery/SpeechUX).
- **defender-removal** — removes all `Windows-Defender-*`, `Security-Octagon-*` (SGRM), WebThreatDefense,
  SenseClient (EDR), SmartScreen/AppRep; sets SmartScreen/SAC/PUA policy off. **Keeps** AMSI ("Causes
  File system error UAC") and Security Center (disabled via `wscsvc`, not stripped).
- **ai-removal** — Recall (`UserExperience-AIX/CoreAI`), Copilot, `AIFabric-CBS-1.6`, Agentic platform;
  + registry (`DisableAIDataAnalysis`, `TurnOffWindowsCopilot`, `LetAppsAccessGenerativeAI=2`, …).
- **onedrive-removal** — supersedes `OneDrive-Setup*` so it never re-provisions.
- **xbox-removal** — GameBar/BroadcastDVR/XboxLive/GameChat/etc. **Keeps** `Gaming-Configuration` +
  `GameMode` (new Xbox Full Screen Experience, Game Mode).
- **systemPackages-removal** (= `system-components-removal`) — ~130 components (Flash, CEIP/SQM,
  appraiser/CompatTelRunner, ErrorReporting, Feedback, Flighting, RetailDemo, screensavers, QuickAssist,
  SecureAssessment "Take a Test", etc.). **Keeps** (with reasons): DeviceCensus (removing it breaks WU
  driver downloads), ErrorReportingFaults/Kernel (breaks some games), Flighting-FeatureConfiguration
  (winver shows 2009), Data-Pdf (breaks Passmark), GameExplorer (older games), the whole Edge block.

Full per-component decode lives with the WinDebloat inventory (`windows11-debloat/docs/inventory/playbook.md`,
"CBS removal packages" section) if you have that repo checked out.

## Appx removal gotchas

Some packages are protected Windows components and return `0x80070032` on per-user `Remove-AppxPackage`
("part of Windows and cannot be uninstalled on a per-user basis"): e.g. `SecureAssessmentBrowser`
("Take a Test"), `MicrosoftEdgeDevToolsClient`. These are removed at the **component (CBS)** level by
`systemPackages-removal`, not per-user appx. Don't chase them with appx removal.

## Defender / Tamper Protection facts

- AME requires Tamper Protection **off** before Defender work (`playbook.conf` `DefenderToggled` /
  `NoAntivirus` requirements). Tamper Protection **cannot** be turned off by script — it's gated behind
  the Windows Security UI; AME/revision-tool open that UI and wait for the user.
- `Features\TamperProtection`: `1`/`5` = on, `4` = off. `TamperProtectionSource` varies.
- Even with Tamper off, Defender's PPL self-protection on its service keys stands (see above).

## VM testing notes

- Test by applying with **AME Wizard** to a Win10/11 VM or ISO — there is no unit test for playbook YAML.
- A dedicated VirtualBox VM is used for WinDebloat testing (`windowstest`; snapshot/credential details
  are in the agent's private memory, not committed here). Restore a clean snapshot before each apply —
  Appx/CBS removals are not reversible.
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
- **Host hypervisor matters.** With Hyper-V/VBS/Memory integrity on the host, VirtualBox logs `AMD-V is
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
- The playbook's `RealTimeIsUniversal=1` (upstream dual-boot fix) makes a VirtualBox guest boot 13 h off
  (VirtualBox supplies local time) until time sync; harmless, VM-only.

## Default apps on Windows 11 (26300)

- The classic `UserChoice` hash (SetUserFTA/PS-SFTA algorithm, salt `User Choice set via Windows User
  Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}`) still validates (157/157 on a 26100 host,
  146/146 on the 26300 VM), **but 26300 ignores it**: every type also has `UserChoiceLatest` (Hash +
  `ProgId\ProgId`), which wins; deleted, Windows recreates it with the previous choice. `assoc.ps1` only
  sets class defaults; `INSTALL-APPS.ps1` writes `UserChoiceLatest` with the vendored `SFTA\SFTA.ps1`.
- The `UserChoiceLatest` hash *is* reproducible: `SFTA.ps1` 2.0.1 from github.com/ComoEstaisAmigos/PS-SFTA
  (MIT; salt read from `windows.storage.dll`, `HKLM\SOFTWARE\Microsoft\SQMClient` MachineId, the
  `UserChoiceLatest\ProgId` key's write time) reproduced 157/157 Windows-written hashes on 26300.9457
  (`SystemProtectedUserData\<SID>\AnyoneRead\AppDefaults\HashVersion=1`), with and without Windows'
  own encoder. A valid hash alone still shows the picker on types where any known handler is "new":
  every ProgId from `HKCR\<type>\OpenWithProgids`, the user's `FileExts\<type>\OpenWithProgids` and
  each `RegisteredApplications` app's `Capabilities\FileAssociations` needs a
  `HKCU\...\ApplicationAssociationToasts` value `<ProgId>_<type>`=0 (Photo Viewer declares `.gif` as
  `PhotoViewer.FileAssoc.Gif`, in neither list). With both, 93 types across 8 apps opened directly,
  also after a reboot (VM, 2026-10-23). The picker then lists the written app as "Default app".
- Opening a sample with `explorer.exe <file>` browses into archives as folders; test those with
  `cmd /c start "" <file>`. `Invoke-Item` blocks while the OpenWith picker is up.
- `UserChoice` carries a Deny ACE on Set Value: delete it with `RegDeleteKey` (DELETE right), not .NET
  `DeleteSubKeyTree`, which silently does nothing; `RegDeleteKey` fails with 5 while subkeys exist.
- Settings deep links: `ms-settings:defaultapps?registeredAppMachine=<name>` / `registeredAppUser=<name>`
  (HKLM / HKCU `RegisteredApplications` value name) open that app's page. A packaged app's `AppX<hash>`
  entry opens only the main Default apps page, and `registeredAUMID=` shows just its URL protocol; use
  the app's own non-AppX entry (ImageGlass MSIX writes `HKCU ... ImageGlass` after `--ig-set-default-viewer`).
- Which types "just work": Windows seeds `UserChoiceLatest` at the user's first sign-in for the types
  its inbox apps own (Photos `AppX43hnx...`, Media Player `AppXqj98...`, Raw `AppX9rkaq...`, Edge
  `MSEdgeHTM` for .htm/.svg/.xml, CompressedFolder/CABFolder). Those keep winning after the playbook
  removes the app (the ProgIds no longer exist), so the type shows the picker until set in Settings.
  Types with no seeded entry (LibreOffice, Subtitle Edit, most 7-Zip types, .flv/.jxl/.psd) fall back
  to the class default `assoc.ps1` sets and open directly. Verified on the 26300 VM, 2026-10-23.
- The `DefaultAssociationsConfiguration` policy (HKLM\SOFTWARE\Policies\Microsoft\Windows\System,
  XML of `<Association Identifier ProgId ApplicationName>`) changed nothing on 26300 Pro for the
  existing user after a reboot: the seeded entries stayed (tested for 40 mpv/ImageGlass types).
- UCPD is already `Disabled` after the playbook, so it is not what blocks `.pdf`/`http`.
- Check defaults by opening sample files in the user's session (Limited scheduled task) and watching
  what launches (`OpenWith` = the picker), not by reading the registry or via `AssocQueryString` from a
  `guestcontrol` session (it reports no association even when one exists).

## Monorepo / git gotchas (`debloat-tool/`)

- **A folder with its own `.git` is silently skipped by `git add`** (or added as a bare gitlink). That is
  how a first push shipped a workflow building `debloat-tool/src` without the folder ("The directory name
  is invalid" on the runner). `debloat-tool/` is a `git subtree` import — never put a nested `.git` back.
- **Line endings:** the root `.gitattributes` (`* text=auto eol=crlf`) stores every text file LF and checks
  it out CRLF regardless of `core.autocrlf`, so the packaged `.apbx` always gets CRLF (AME needs it). Don't
  add per-file overrides or commit CRLF blobs. Upstream Revision Tool stores a CRLF/LF mix, so subtree pulls
  must renormalize: `git -c merge.renormalize=true subtree pull ...`, or every upstream-CRLF file conflicts.
- **VS Code locks open folders** on Windows (`mv`/`Move-Item` fail with "being used by another process").
  Work around it in a temp clone (`git -c core.autocrlf=false clone`), then `git fetch` the result back and
  `git update-ref` + `git reset` when the working-tree files already match.
- The tool (Flutter + Rust + Inno Setup) has no local toolchain on the maintainer's machine; the
  `build-tool` CI job is the first compile. Upstream sync procedure: `debloat-tool/README.md`.

## Playbook regressions already learned (don't reintroduce)

- **The tool's support gate** (this fork): upstream revitool exits `55` ("Error validating ReviOS /
  Unsupported build detected") on *every* command unless `HKLM\…\Windows NT\CurrentVersion` has
  `EditionSubManufacturer=MeetRevision` **or** `EditionSubVersion=ReviOS` (verified on the VM). Rebranding
  both in `os-info/edition.yml` made a whole run "succeed" while no appx, winpackage, Defender or power-plan
  step ran. Our fork (`wdtool`, `debloat-tool/`) gates on `WinDebloat` in either value, or on AME applying
  this playbook (`%TEMP%\AME\Playbooks\<UniqueId>`) — so changing the edition marker or `<UniqueId>` silently
  breaks the same way. AME doesn't halt on it: grep `Output.txt` for `exit code: 55` after a test apply.

From the ReviOS playbook's own comments — tweaks that were tried and **reverted/avoided** because they
broke something:

- `DisableWindowsConsumerFeatures` → breaks Your Phone (left unset).
- `SvcHostSplitThresholdInKB` → breaks `XboxGipSvc` (reverted; use `revitool … service-grouping`).
- Disabling core Superfetch → breaks `defrag c: -b` (re-enabled in revert).
- `bam` disabled → breaks Efficiency Mode (reverted).
- Background-apps disabled → breaks Game Bar KGL update (re-enabled).
- `VulnerableDriverBlocklistEnable=0` → breaks THE FINALS; `AppCaptureEnabled` set → breaks Game Bar
  recording (#74); `disabledynamictick yes` → breaks ROG Ally sleep (#167); bbr2 → breaks websockets (#27).
- Block-Windows-Insider firewall rule → breaks Xbox; `NoAutoUpdate=1` → once broke Xbox sign-in (W10).
- `condrv` must stay Automatic (#184); `DisableAutomaticRestartSignOn` → slow Hello logon.
- Contacts consent `Deny` → breaks Mail & Calendar (left allowed).
- Edge removal needs a **non-EEA** region (the BrowserReplacement trick); Edge/WebView/Dev "still get
  reinstalled after Windows Updates" → hence Deprovisioned keys + EdgeUpdate policies.
- Hibernate disable may overheat laptops in sleep; `DisableRootAutoUpdate` needed for MS Store.

Before adding a WinDebloat tweak that touches any of these areas, check it against this list and the
playbook's area-file comments.
