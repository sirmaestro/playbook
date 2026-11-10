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
