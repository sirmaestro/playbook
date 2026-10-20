# Port findings: appx.psd1 / ai.psd1 / edge.psd1

Port of WinDebloat `catalog/appx.psd1`, `catalog/ai.psd1`, `catalog/edge.psd1` into the ReviOS
playbook fork. Deconfliction done against `packages/appx.yml`, `packages/win-sxs.yml`,
`packages/app-win32.yml`, and the full `Tasks/registry/**` tree.

Output files created (not yet wired into `main.yml` / `registry.yml` / `appx` aggregator — that
wiring is deliberately left to a follow-up pass, per the "do not edit existing task files" rule):

- `src/Configuration/Tasks/packages/windebloat-appx.yml` — new Appx removals
- `src/Configuration/Tasks/registry/security/windebloat-ai.yml` — AI (Copilot/Recall/Click To Do) policy
- `src/Configuration/Tasks/registry/misc/windebloat-edge.yml` — single Edge registry tweak

Counts (by catalog entry across appx.psd1 + ai.psd1 + edge.psd1, 66 entries total):
**ported 12** (8 appx entries — 3 of them partial where the rest was already a duplicate — plus
3 AI registry entries and 1 Edge registry entry; the 2 Copilot-provider appx under
ai.remove-copilot-appx were also added), **skipped-duplicate 40**, **conflicts 2**,
**maps-to-existing 12**.

---

## Ported

### Appx — `packages/windebloat-appx.yml` (unconditional set)
Removed via `revitool appx --all-users --remove`, matching `appx.yml`'s idiom. None of these are in
the playbook's existing appx list.

- `Microsoft.WindowsTips` — win: appx.tips
- `Microsoft.Office.Sway` — win: appx.onenote / appx.legacy-win10-leftovers
- `Microsoft.News` (alias of BingNews) — win: appx.bing-news
- `Microsoft.Messaging`, `Microsoft.OneConnect`, `Microsoft.Wallet`, `Microsoft.MSWallet`,
  `Microsoft.Print3D`, `Microsoft.3DBuilder`, `Microsoft.MicrosoftJournal`,
  `Microsoft.NetworkSpeedTest`, `Microsoft.MinecraftUWP` — win: appx.legacy-win10-leftovers
- `Microsoft.BingFinance`, `Microsoft.BingSports`, `Microsoft.BingFoodAndDrink`,
  `Microsoft.BingHealthAndFitness`, `Microsoft.BingTravel`, `Microsoft.BingTranslator`,
  `Microsoft.MicrosoftStart` — win: appx.bing-extras
- `Microsoft.M365Companions` — win: appx.m365-companions
- OEM/sponsored third-party stubs (Disney, Amazon, Netflix, TikTok, Candy Crush, Instagram,
  Facebook, LinkedIn, Hulu, SlingTV, DolbyAccess, WinZip, Adobe Express, …) — win: appx.third-party-promos
  - **CAVEAT:** WinDebloat matched these with leading/trailing `*` wildcards. The playbook's
    `revitool appx --remove` takes names, so the asterisks were stripped to the core identifier
    (e.g. `*Disney.37853FC22B2CE*` → `Disney.37853FC22B2CE`). Whether revitool does prefix/substring
    matching on these needs **VM verification**; some loosely-named ones (`Flipboard`, `iHeartRadio`,
    `TuneInRadio`, `SlingTV`) may need the full package name.

### Appx — `packages/windebloat-appx.yml` (gated behind `remove-winsxs-ai`)
AI appx not covered by `app-win32.yml`'s existing `Microsoft.Copilot` fallback. Gated behind the same
`remove-winsxs-ai` option the playbook already uses for Copilot appx removal.

- `Microsoft.Windows.AIHub` — win: appx.windows-aihub
- `Microsoft.Windows.Ai.Copilot.Provider`, `MicrosoftWindows.Client.CoPilot` — win: ai.remove-copilot-appx

### AI registry — `registry/security/windebloat-ai.yml`
- **win: ai.disable-copilot-policy** — `TurnOffWindowsCopilot=1` (HKLM + HKCU +DEFAULT),
  `ShowCopilotButton=0` (HKCU +DEFAULT), Copilot shell-extension GUID
  `{CB3B0003-8088-4EDE-8769-8B354AB2FF8C}` added to `Shell Extensions\Blocked` (HKLM). None present
  in the playbook.
- **win: ai.disable-recall-policy** — `AllowRecallEnablement=0` (HKLM), `TurnOffSavingSnapshots=1`
  (HKLM + HKCU +DEFAULT), `DisableAIDataAnalysis=1` (HKCU +DEFAULT). The **HKLM**
  `DisableAIDataAnalysis` was skipped — already in `registry/explorer/win-settings.yml` line 476.
- **win: ai.disable-click-to-do** — `DisableClickToDo=1` (HKLM + HKCU +DEFAULT). Not present.
- Note: catalog marks Recall/ClickToDo with `Builds.Min = 26100`. AME has no per-build gate here;
  the keys are inert on older builds, so they are applied unconditionally.

### Edge registry — `registry/misc/windebloat-edge.yml`
- **win: edge.no-desktop-shortcut** — `CreateDesktopShortcutDefault=0` under
  `HKLM\SOFTWARE\Policies\Microsoft\EdgeUpdate`. Not present in the playbook. Left ungated to match
  the existing (ungated) EdgeUpdate policy block in `registry/misc/fixes.yml`.

---

## Skipped (exact duplicate)

- **appx.deprovision-markers** — all ~49 Deprovisioned keys already in
  `registry/misc/deprovisioned-apps.yml` (which also adds extras: Paint/Notepad/Calculator/SecHealthUI).
- **appx.block-outlook-devhome-autoinstall** — `BlockedOobeUpdaters=["MS_Outlook"]`, DevHomeUpdate /
  OutlookUpdate DeleteKey + `workCompleted=1` all in `registry/updates/updates.yml` (66–71).
- **appx.preinstalled-apps-block** — PreInstalledAppsEnabled / PreInstalledAppsEverEnabled /
  OemPreInstalledAppsEnabled / SilentInstalledAppsEnabled = 0 all in `registry/privacy/cdm.yml`
  (with +DEFAULT mirroring).
- **appx.widgets-webexperience** — `MicrosoftWindows.Client.WebExperience` already in `appx.yml`;
  `AllowNewsAndInterests=0` + `EnableFeeds=0` already in `registry/explorer/taskbar.yml`.
- **ai.bing-copilot-ifeo-block** — BingChatInstaller / BGAUpsell / BCILauncher IFEO Debugger keys all
  in `registry/system/ifeo.yml` (19–21).
- **edge.block-edge-reinstall** — InstallDefault=0, Install{Edge}=0, Install{WebView2}=1,
  DoNotUpdateToEdgeWithChromium=1 all in `registry/misc/fixes.yml` (30–33) + `deprovisioned-apps.yml` (19).
- **edge.keep-webview2** — `Install{F3017226-…}=1` already in `fixes.yml` (32).
- **edge.block-teams-autoinstall** — `ConfigureChatAutoInstall=0` already in `app-win32.yml` (97).
- ~30 individual appx in the main WinDebloat lists (Getstarted, OfficeHub, People, Maps, BingSearch,
  BingWeather, Solitaire, Skype, FeedbackHub, GetHelp, ZuneVideo, MSPaint, Clipchamp, OutlookForWindows,
  OutlookPWA, Camera, PowerAutomateDesktop, Office.Word/Excel/PowerPoint, Office.OneNote, BingNews,
  3DViewer, Todos, StartExperiencesApp, WindowsAlarms, WindowsSoundRecorder, YourPhone*, Whiteboard,
  ZuneMusic, SurfaceHub Teams/Mail, QuickAssist, PowerBI, Cortana/549981C3F5F10, StickyNotes,
  communicationsapps, WidgetsPlatformRuntime, SpotifyMusic) — already in `packages/appx.yml`.

---

## CONFLICTS — second pass

1. **appx.mixed-reality-portal** — WinDebloat removes `Microsoft.MixedReality.Portal`; `appx.yml`
   line 56 lists `MixedReality.Portal` (no `Microsoft.` prefix). The playbook's string will not match
   the real package name (`deprovisioned-apps.yml` line 41 correctly uses
   `Microsoft.MixedReality.Portal_8wekyb3d8bbwe`), so the appx.yml entry is likely a typo. **Not
   ported / not overridden** — flag to maintainer to fix the name in `appx.yml` rather than add a
   second removal.
2. **appx.secure-assessment-browser** — WinDebloat removes `Microsoft.Windows.SecureAssessmentBrowser`
   as a per-user appx; `appx.yml` line 16 already lists it in the revitool appx set, **but**
   per `references-learnings.md` this package returns `0x80070032` on per-user `Remove-AppxPackage`
   ("part of Windows") and is actually stripped at the **CBS** level by `system-components-removal`
   (already run unconditionally in `win-sxs.yml`). The appx.yml line is effectively a no-op/duplicate.
   **Not ported** — flag: real removal is the CBS package; consider dropping the appx.yml line (needs
   maintainer confirmation per rule 2).

---

## Maps to existing mechanism

- **appx.photos** (`Microsoft.Windows.Photos`) → `appx.yml`, option `remove-appx-photos`.
- **appx.devhome** (`Microsoft.Windows.DevHome`) → `appx.yml`, option `remove-appx-devhome`.
- **appx.yourphone** (`Microsoft.YourPhone`) + **appx.crossdevice** (`MicrosoftWindows.CrossDevice`)
  → `appx.yml`, option `remove-appx-yourphone`.
- **appx.xbox-app** (`Microsoft.GamingApp`, `Microsoft.XboxApp`) + **appx.xbox-speech-overlay**
  (`Microsoft.XboxSpeechToTextOverlay`) → `revitool winpackage --install xbox-removal` in `win-sxs.yml`,
  option `remove-appx-xbox` (CBS removal; respects the option gate — not ported unconditionally).
- **ai.remove-copilot-appx** (`Microsoft.Copilot`) → `app-win32.yml` removes it behind
  `remove-winsxs-ai`; AI components via `ai-removal` CBS in `win-sxs.yml`. (The two extra provider
  appx were ported behind the same gate — see Ported.)
- **ai.recall-feature-remove** (Feature `Recall` -Remove) → `ai-removal` CBS package
  (Recall `UserExperience-AIX`/`CoreAI`), option `remove-winsxs-ai`.
- **edge.remove-teams** (MSTeams/MicrosoftTeams/Flipgrid + Meeting Add-in MSI + taskkill) →
  `app-win32.yml`, option `remove-teams` (full parity incl. the `{A7AB73A3-…}` MSI uninstall).
- **Edge browser removal** (EdgeRemoval.ps1 technique) → `Executables/EDGE.ps1` +
  `app-win32.yml` (`Microsoft.MicrosoftEdge`, `MicrosoftEdgeDevToolsClient`, `Edge.GameAssist`),
  option `remove-edge`.

### Partial / follow-up note (not a registry tweak — out of this pass's output scope)
- **edge.edgeupdate-manual** — WinDebloat sets `edgeupdate`, `edgeupdatem`,
  `MicrosoftEdgeElevationService` to **Manual**. The playbook sets **only `edgeupdate`** to Manual
  (`services.yml` line 60). `edgeupdatem` and `MicrosoftEdgeElevationService` are **absent**. These
  are `!service` startup changes that belong in `services.yml`; editing that existing file is out of
  scope for this pass (appx + AI/Edge registry). **Flag for a services pass.**
