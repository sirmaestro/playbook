# WinDebloat → Playbook port: Shell / UI

Scope: `catalog/look.psd1`, `catalog/ctx.psd1`, `catalog/shell.psd1`, `catalog/start.psd1`
(34 tweaks). Mechanism notes cross-checked against `docs/tweaks/group4.mech.md`.

Ported tweaks land in `src/Configuration/Tasks/registry/explorer/windebloat-shell.yml`.
Deconfliction done per-action against the whole `src/Configuration/Tasks/**` tree.

Counts: **8 ported · 20 skipped (exact duplicate) · 3 conflicts · 3 maps-to-existing** (= 34).

---

## Ported

New actions added to `windebloat-shell.yml`. Three of these are *partial* ports — the rest of
the tweak was already present (noted inline and listed again under Skipped).

| win id | Ported actions | Notes |
|---|---|---|
| `look.startup-sound-off` | `LogonUI\BootAnimation\DisableStartupSound=1`, `EditionOverrides\UserSetting_DisableStartupSound=1` (HKLM) | Partial. `EnableFirstLogonAnimation=0` + `Policies\System\DisableStartupSound=1` already in `registry/system/logon.yml` (skipped). |
| `look.audio-ducking-off` | `Narrator\NoRoam\DuckAudio=0` (HKCU +DEFAULT) | Partial. `UserDuckingPreference=3` already in `registry/misc/enable-audio-communications-do-nothing.yml` (skipped). |
| `look.menu-responsiveness` | `Explorer\Serialize\StartupDelayInMSec=0` (HKCU +DEFAULT) | Partial. `MenuShowDelay=0` + `ActiveWndTrkTimeout=10` already in `registry/explorer/control-panel.yml` (skipped). |
| `shell.show-hidden-files` | `Advanced\Hidden=1` (HKCU +DEFAULT) | Fully absent. |
| `shell.hide-home-gallery` | `CLSID\{f874310e-…}` + `CLSID\{e88865ea-…}` `System.IsPinnedToNameSpaceTree=0` (HKCU +DEFAULT) | Fully absent. Pairs with existing `LaunchTo` (now `3` = Downloads). |
| `shell.recent-files-off` | `Explorer\ShowRecent=0`, `ShowRecommendations=0`, `ShowCloudFilesInQuickAccess=0` (HKCU +DEFAULT) | Fully absent. These `Explorer` values differ from the existing `Advanced\Start_IrisRecommendations`. |
| `shell.frequent-folders-off` | `Explorer\ShowFrequent=0` (HKCU +DEFAULT) | Fully absent. |
| `shell.this-pc-folders-hide` | `MyComputer\NameSpace\{GUID}\HiddenByDefault=1` ×6 GUIDs × (HKLM + WOW6432Node) | Fully absent. Ported as a guarded `!powerShell` block to honour the catalog `RequireKey=$true` semantics (only set where the NameSpace key already exists — a plain `!registryValue` would create the key and risk re-registering a removed folder node). |

HKCU values were mirrored to `HKU\.DEFAULT` per the playbook convention (explorer tweaks are
heavily mirrored). HKLM/policy values are single.

---

## Skipped (exact duplicate)

Present in the playbook with identical value + data (per-action; partial-port tweaks are listed
for the action(s) that duplicate):

| win id | Where it already exists |
|---|---|
| `look.jpeg-quality-100` | `explorer/control-panel.yml` (`JPEGImportQuality=100`, +DEFAULT) |
| `look.beeps-off` | `explorer/control-panel.yml` (`Sound\Beep=no`, +DEFAULT) |
| `look.mouse-accel-off` | `explorer/control-panel.yml` (`MouseSpeed/Threshold1/Threshold2=0`, +DEFAULT) |
| `look.spotlight-lockscreen-off` | `privacy/cdm.yml` (ContentDeliveryManager set + Subscriptions/SuggestedApps key delete), `privacy/cloud-content.yml` (CloudContent policies), `explorer/win-settings.yml` (SubscribedContent-338388/353698, SystemPaneSuggestionsEnabled). All values present & identical. |
| `look.menu-responsiveness` (part) | `explorer/control-panel.yml` (`MenuShowDelay=0`, `ActiveWndTrkTimeout=10`) |
| `look.startup-sound-off` (part) | `system/logon.yml` (`EnableFirstLogonAnimation=0`, `DisableStartupSound=1`) |
| `look.audio-ducking-off` (part) | `misc/enable-audio-communications-do-nothing.yml` (`UserDuckingPreference=3`) |
| `ctx.open-with-store-lookup-off` | `privacy/privacy.yml` (`NoInternetOpenWith=1` HKCU + HKLM) |
| `shell.show-file-extensions` | `explorer/view.yml` (`HideFileExt=0`, +DEFAULT) |
| `shell.launch-to-this-pc` | `explorer/explorer.yml` (`LaunchTo=3` Downloads — changed from WinDebloat's This PC on maintainer request, +DEFAULT) |
| `shell.full-path-title` | `explorer/view.yml` (`CabinetState\FullPath=1`, +DEFAULT) |
| `shell.sync-provider-notifications-off` | `explorer/view.yml` (`ShowSyncProviderNotifications=0`, +DEFAULT) |
| `shell.info-tips-off` | `explorer/explorer.yml` (`ShowInfoTip=0`, +DEFAULT) |
| `shell.shortcut-suffix-off` | `explorer/explorer.yml` (`Explorer\link=00000000`, +DEFAULT) |
| `shell.hide-spotlight-desktop-icon` | `explorer/explorer.yml` (`HideDesktopIcons\NewStartPanel\{2cc5ca98-…}=1`) |
| `shell.tablet-mode-desktop` | `explorer/win-settings.yml` (SignInMode=1, TabletMode=0, ConvertibleSlateModePromptPreference=2, TaskbarAppsVisibleInTabletMode=1, TaskbarAutoHideInTabletMode=0, +DEFAULT) |
| `start.pinned-folders-hidden` | `explorer/start-menu.yml` (all `AllowPinnedFolder*` + `_ProviderSet`, Settings=1) + `NoResolveSearch=1` |
| `start.recommendations-account-notifs-off` | `explorer/explorer.yml` (`Start_IrisRecommendations=0`, `Start_AccountNotifications=0`, +DEFAULT) |
| `start.taskbar-search-mode` | `explorer/taskbar.yml` (`SearchboxTaskbarMode=1`, +DEFAULT) |
| `start.task-view-off` | `explorer/taskbar.yml` (`ShowTaskViewButton=0`, +DEFAULT) |
| `start.widgets-off` | `explorer/taskbar.yml` (`EnableFeeds=0`, `ShellFeedsTaskbarViewMode=2`, `TaskbarDa=0`, `Dsh\AllowNewsAndInterests=0`) |
| `start.chat-meetnow-off` | `explorer/taskbar.yml` (`ChatIcon=3`, `TaskbarMn=0`, `HideSCAMeetNow` HKCU+HKLM, `HidePeopleBar=1`) |
| `start.end-task` | `explorer/explorer.yml` (`TaskbarDeveloperSettings\TaskbarEndTask=1`, +DEFAULT) |
| `start.cortana-cloud-search-off` (part) | `explorer/search.yml` — all values match **except** `AllowCortana` (see Conflicts). |

---

## CONFLICTS — second pass

Do not port. Flagged for the maintainer (identical value name, divergent data or gating).

| win id | WinDebloat (catalog) | Playbook | Difference |
|---|---|---|---|
| `look.sticky-keys-prompts-off` | Sets accessibility hotkey flags to specific values: `StickyKeys\Flags="26"`, `Keyboard Response\Flags="2"`, `ToggleKeys\Flags="34"`, `MouseKeys\Flags="130"`, `HighContrast\Flags="4194"` (clears the 0x4 "hotkey available" bit but leaves features usable). | `explorer/control-panel.yml` **deletes** the whole `Control Panel\Accessibility\*` subtree then rewrites every `Flags="0"` (HKCU +DEFAULT) — the `look.accessibility-reset` strategy. | Same value names, different data **and** different strategy (reset-to-0 vs selective-bit-clear). group4.mech.md explicitly says "pick one". Playbook already committed to the reset approach. |
| `shell.cross-device-resume-block` | `CrossDeviceResumeHost\ProcessPath`, `CrossDeviceResume\Configuration\IsResumeAllowed=0`, `PolicyManager\…\DisableCrossDeviceResume\value=1` — applied **unconditionally**. | `explorer/win-settings.yml` sets the same 3 values but **gated behind `option: "remove-appx-yourphone"`**. | Option-gated differently. Values identical; applies only when Your Phone is removed in the playbook, always in WinDebloat. |
| `start.cortana-cloud-search-off` (`AllowCortana`) | `HKLM\…\Windows Search\AllowCortana=0` (catalog note: "ReviOS writes AllowCortana=1 (sic); intended 0 used here"). | `explorer/search.yml` `AllowCortana=1`. | Different data (0 vs 1) for the same policy value. Deliberate divergence on both sides. All other values in this tweak match and are skipped. |

---

## Maps to existing mechanism

Satisfied by an existing playbook option/Executable; not ported.

| win id | Existing mechanism |
|---|---|
| `look.dark-mode` | `configure-darkmode` option in `Tasks/final.yml` (`AppsUseLightTheme=0`, `SystemUsesLightTheme=0` with `!configure-darkmode` restore branch + `Set-Theme.ps1`). Same two values, same data. |
| `look.transparency-off` | `configure-te` option in `explorer/win-settings.yml` (`Personalize\EnableTransparency=0` + `WindowMetrics\MinAnimate=0`). Catalog keeps `MinAnimate` in `look.animations-off`; the playbook bundles it into `configure-te`. |
| `ctx.legacy-menu` | `configure-lcm` option in `explorer/context-menu.yml` (`CLSID\{86ca1aa0-…}\InprocServer32` default = empty REG_SZ). Identical. |

Note: the "replace Start pins" Script tweak referenced in the task brief is **not present in
`start.psd1`** (that file is registry-only). The playbook's pinned-apps replacement is already
handled by `ConfigureStartPins` under `option: "remove-pinned-items-startmenu"` in
`explorer/start-menu.yml` — recorded here for completeness; nothing in scope to port.
