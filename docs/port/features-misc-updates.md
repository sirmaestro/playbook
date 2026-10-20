# WinDebloat port — feat / misc-features / misc / upd

Port of the WinDebloat catalog groups `feat.psd1`, `misc-features.psd1`, `misc.psd1`, `upd.psd1`
into native playbook YAML. 27 catalog tweaks reviewed.

Output files produced:
- `src/Configuration/Tasks/windebloat-features.yml` — 6 capability removals.
- `src/Configuration/Tasks/registry/misc/windebloat-misc.yml` — long paths, regional formats, Narrator hotkey.
- (no `windebloat-updates.yml` — every `upd.psd1` tweak was a duplicate, maps to revitool, or a conflict.)

> **Wiring note:** per task rules the existing `registry.yml` / `main.yml` were **not** edited, so the two
> new task files are not yet included. A maintainer still needs to add `!task` includes
> (`Tasks\windebloat-features.yml` near the package/feature phase, `Tasks\registry\misc\windebloat-misc.yml`
> into `registry.yml`'s misc block) for them to run.

> **Dead file confirmed:** `packages/optional-features.yml` (`DISM-FEATURES.ps1`) is referenced by nothing in
> `main.yml` / `registry.yml` / any task — unwired, as the references doc warned. Capabilities are therefore
> ported as direct `Remove-WindowsCapability` `!powerShell`, matching the WinDebloat engine's prefix-match
> semantics (`Get-WindowsCapability | Where Name -like 'X*'`), not via that file.

---

## Ported (9 tweaks; 8 full + 1 partial)

### Capabilities → `windebloat-features.yml`
All six absent from the playbook (the `InternetExplorer` hit in `ceip.yml` is a CEIP policy comment; the
`QuickAssist` hits are the UWP appx `MicrosoftCorporationII.QuickAssist`, not the `App.Support.QuickAssist`
legacy capability).

| win id | capability |
|---|---|
| `feat.internet-explorer-capability` | `Browser.InternetExplorer` |
| `feat.powershell-ise-capability` | `Microsoft.Windows.PowerShell.ISE` |
| `feat.quick-assist-legacy-capability` | `App.Support.QuickAssist` |
| `feat.steps-recorder-capability` | `App.StepsRecorder` |
| `feat.wordpad-capability` | `Microsoft.Windows.WordPad` |
| `feat.notepad-legacy-capability` | `Microsoft.Windows.Notepad` |

### Registry → `windebloat-misc.yml`
| win id | detail |
|---|---|
| `misc.long-paths` | `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled=1` (absent in playbook). |
| `misc.regional-formats` | HKCU `Control Panel\International` `dd/MM/yyyy` short date (+`sDate=/`, `iDate=1`) / Monday-first / metric / `.` decimal / `,` list prefs (absent); mirrored to `HKU\.DEFAULT`. |
| `misc.accessibility-hotkeys-off` **(partial)** | Only the Narrator `WinEnterLaunchEnabled=0` action (absent; `HKCU\...\Narrator\NoRoam`), mirrored to `HKU\.DEFAULT`. The five Flags actions conflict — see below. |

---

## Skipped (exact duplicate) (13 tweaks)

| win id | already in |
|---|---|
| `misc.hide-insider-page-wu-tray` | `explorer/win-settings.yml` (HideInsiderPage=1 L16, TrayIconVisibility=0 L18). |
| `misc.enable-sudo` | `explorer/win-settings.yml` L479 (Sudo\Enabled=3). |
| `misc.typing-suggestions-off` | `explorer/win-settings.yml` L95–130 (all TabletTip\1.7 + Input\Settings values, HKCU+HKLM). |
| `misc.inking-workspace` | `explorer/explorer.yml` L102,105 (AllowWindowsInkWorkspace=1, AllowSuggestedAppsInWindowsInkWorkspace=0). |
| `misc.boot-menu-legacy` | `Executables/FINALIZE.cmd` L60–61 (`bcdedit /set bootmenupolicy Legacy`, `lastknowngood yes`). |
| `misc.classic-photo-viewer` | `registry/misc/classic-photo-viewer.yml` (same values; option-gated `remove-appx-photos`, HKU\S-1-5-18 mirror). |
| `upd.hide-upgrade-mct` | `registry/updates/updates.yml` L28 (UpgradeAvailable=0), L74 (HideMCTLink=1), L75 (RestartNotificationsAllowed2=0). |
| `upd.delivery-optimization-off` | `registry/updates/updates.yml` L41 (DODownloadMode=0). |
| `upd.insider-off` | `registry/updates/updates.yml` L47 (PreviewBuilds\AllowBuildPreview=0) + `privacy/telemetry.yml` L37 (EnableConfigFlighting=0), L46 (DataCollection\AllowBuildPreview=0). |
| `upd.store-autodownload-off` | `registry/updates/ms-store.yml` L9 (AutoDownload=4), L12 (DisableOSUpgrade=1). |
| `upd.wmp-autoupdate-off` | `registry/updates/updates.yml` L62 (DisableAutoUpdate=1). |
| `upd.register-au-off` | `final.yml` L26 (Services\Pending\7971f918…\RegisterWithAU=0). |
| `upd.hw-requirements-bypass` | `system/bypass-requirements.yml` L14 (AllowUpgradesWithUnsupportedTPMOrCPU=1), L15–18 (SV1/SV2=0 incl. HKU\.DEFAULT). LabConfig values are install-time-only and intentionally unset here. |

---

## CONFLICTS — second pass (2)

### `misc.accessibility-hotkeys-off` — accessibility Flags values
- **WinDebloat:** sets `HKCU\Control Panel\Accessibility\...\Flags` to StickyKeys=`506`, Keyboard Response=`2`,
  ToggleKeys=`34`, MouseKeys=`130`, HighContrast=`4194` (disable the hotkey but keep the feature flags).
- **Playbook (`explorer/control-panel.yml`):** L76–102 **deletes** those Accessibility subkeys, then L108–134
  re-creates every `Flags` value as `0` (both HKCU and HKU\.DEFAULT) — a full Ease-of-Access wipe.
- **Difference / why not ported:** divergent data (`506/2/34/130/4194` vs `0`) and divergent approach
  (WinDebloat keeps the keys; playbook deletes+zeros them). Overriding would fight the playbook's own
  accessibility teardown. Only the non-overlapping Narrator action was ported.

### `upd.notification-level` — SetUpdateNotificationLevel
- **WinDebloat:** `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\SetUpdateNotificationLevel=2`.
- **Playbook:** `revert.yml` L71 (`onUpgrade`, runs **after** `registry.yml`) does
  `!registryKey {path: HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate, operation: delete}` and the
  pause itself is delegated to `revitool wu-pause-updates`.
- **Difference / why not ported:** writing into the exact `...\WindowsUpdate` policy key the playbook deletes
  on upgrade is futile (wiped) and conflicts with the revitool-owned pause design — the WinDebloat note itself
  says "Wiped if the WindowsUpdate policy key is deleted later." This is the documented WindowsUpdate-key gotcha.

---

## Maps to existing mechanism (4)

| win id | playbook mechanism |
|---|---|
| `upd.pause-2038` (Script `UpdatePause`) | `revitool tweaks updates wu-pause-updates enable` — `registry/updates/updates.yml` L19–24. Same `UX\Settings` pause values + `FlightSettingsMaxPauseDays`. |
| `upd.drivers-wu-off` | `revitool tweaks updates wu-drivers disable` — `registry/updates/drivers.yml`. Covers the driver-exclusion intent (DriverSearching / Device Metadata / `ExcludeWUDriversInQualityUpdate`). Note: the `ExcludeWUDriversInQualityUpdate` value under the `...\Policies\...\WindowsUpdate` key would be wiped by `revert.yml` L71 on upgrade — another reason to leave it to revitool. |
| `feat.update-health-tools-removal` | `Executables/FINALIZE.cmd` L8–20: msiexec `/X{43D501A5…}` + `/X{804A0628…}`, WindowsInstallationAssistant `/ForceUninstall`, and `reg delete` of `UpdateHealthTools` / `rempl` / `CloudManagedUpdate`. Identical effect. |
| `misc.hide-settings-pages` | `revitool registry hide-page` — `explorer/win-settings.yml` L11 (`cortana,privacy-feedback,windowsinsider,home`) + L188 (`crossdevice`, gated `remove-appx-yourphone`), both writing `SettingsPageVisibility`. **Gap for second pass:** WinDebloat's list also includes `aicomponents`, which the revitool call does **not** hide — a maintainer may want to extend the hide-page value if that page should be hidden. |

---

## Counts

- Ported: **9** (8 full + 1 partial = `misc.accessibility-hotkeys-off` Narrator only)
- Skipped (exact duplicate): **13**
- Conflicts (second pass): **2** (one is the partial above)
- Maps to existing mechanism: **4**
