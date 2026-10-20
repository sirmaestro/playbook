# WinDebloat privacy catalog -> playbook port

Source of truth: `windows11-debloat/catalog/priv.psd1` (group1) + `docs/tweaks/group1.mech.md`.
Output file: `src/Configuration/Tasks/registry/privacy/windebloat-privacy.yml` (NEW values only).

Deconfliction searched across the whole `src/Configuration/Tasks` tree (not just `registry/privacy/`).
Many privacy values already live in `registry/explorer/win-settings.yml`, `notifications.yml`,
`explorer.yml`, `control-panel.yml`, `search.yml`, `registry/system/ifeo.yml`,
`registry/misc/{disable-logging,fixes}.yml`, `registry/updates/updates.yml`, `services.yml`,
`final.yml`, `revert.yml`, and `Executables/{hosts,settings.json}`.

Counts: **Ported = 51 registry entries across 17 tweaks** · **Skipped (exact duplicate) = 18 tweaks fully + the duplicate actions of partially-ported tweaks** · **Conflicts = 4**.

---

## Ported

51 new `!registryValue` entries written to `windebloat-privacy.yml`. By WinDebloat id:

| win id | new entries | what was added (the rest of the tweak was already present) |
|---|---|---|
| priv.telemetry-policy | 4 | HKCU `CurrentVersion\Policies\DataCollection\AllowTelemetry`; HKCU+HKLM `...\DataCollection\MaxTelemetryAllowed`; HKCU `Diagnostics\DiagTrack\ShowedToastAtLevel=1` |
| priv.content-delivery-off | 6 | `SubscribedContent-{338393,353694,353696}Enabled=0`, each HKCU +DEFAULT mirror |
| priv.cloudcontent-policies | 2 | HKLM `CloudContent\DisableConsumerAccountStateContent=1`, HKLM `CloudContent\DisableThirdPartySuggestions=1` |
| priv.restrict-internet-comm | 1 | HKLM `Assistance\Client\1.0\NoActiveHelp=1` |
| priv.error-reporting-off | 1 | HKCU `Policies\...\Windows Error Reporting\Disabled=1` |
| priv.advertising-id-off | 2 | HKCU `Policies\...\AdvertisingInfo\DisabledByGroupPolicy=1`, HKCU `CPSS\Store\AdvertisingInfo\Value=0` |
| priv.tailored-diagnostics-feedback | 1 | HKCU `Policies\...\DataCollection\DoNotShowFeedbackNotifications=1` |
| priv.activity-history-off | 1 | HKLM `System\PublishUserActivitiesOnUserConsent=0` |
| priv.input-personalization-off | 11 | HKCU `InputPersonalization` Restrict* + `TrainedDataStore\HarvestContacts` + `Settings\AcceptedPrivacyPolicy`; HKCU+HKLM `Policies\InputPersonalization` Restrict*; HKCU `Personalization\Settings\AcceptedPrivacyPolicy`; HKCU `CPSS\Store\{InkingAndTypingPersonalization,ImproveInkingAndTyping}\Value=0` |
| priv.online-speech-narrator | 2 | HKCU `Narrator\NoRoam\{OnlineServicesEnabled,ScriptingEnabled}=0` |
| priv.location-sensors-off | 6 | HKLM `ConsentStore\location=Deny`; HKLM `LocationAndSensors\{DisableLocation,DisableSensors}=1`; HKCU `Sensor\Permissions\{BFA794E4...}\SensorPermissionState=0`; HKCU `Geolocation\Status=0`; HKLM `lfsvc\Service\Configuration\Status=0` |
| priv.find-my-device-off | 1 | HKLM `Policies\...\FindMyDevice\AllowFindMyDevice=0` |
| priv.feature-advert-tips | 4 | HKCU `Notifications\Settings\{Windows.SystemToast.Suggested,Windows.SystemToast.StartupApp,Microsoft.SkyDrive.Desktop,Windows.SystemToast.AccountHealth}\Enabled=0` |
| priv.start-tracking-off | 2 | HKCU `Explorer\Advanced\{Start_TrackProgs,Start_TrackDocs}=0` |
| priv.search-cloud-history | 4 | HKCU `SearchSettings\{IsDeviceSearchHistoryEnabled,IsDynamicSearchBoxEnabled,IsMSACloudSearchEnabled,IsAADCloudSearchEnabled}=0` |
| priv.device-metadata-network-off | 2 | HKLM `Device Metadata\PreventDeviceMetadataFromNetwork=1` (both plain + `Policies` key) |
| priv.usage-reporting-off | 1 | HKLM `Session Manager\Power\SleepStudyDisabled=1` (registry portion only — see conflicts/pending below) |

### +DEFAULT mirroring note
Per `group1.mech.md`, `(+DEFAULT)` mirroring was applied only where the mech note marks it AND the
value was actually new. In practice that is only the three `SubscribedContent-*` values above
(priv.content-delivery-off). All other newly-ported HKCU values are not `(+DEFAULT)`-marked in the
mech note, so they were ported HKCU-only (matching the catalog action set). The already-present HKCU
values that DO carry +DEFAULT (CDM, CloudContent, AdvertisingInfo Enabled, Tailored, Siuf, capability
consent, location) are handled by their existing playbook files.

---

## Skipped (exact duplicate)

Fully-duplicate tweaks (every catalog action already present with identical path/value/type/data):

| win id | duplicated by |
|---|---|
| priv.datacollection-hardening | `registry/privacy/telemetry.yml` (all 13) |
| priv.autologgers-off | `registry/privacy/telemetry.yml` (Diagtrack-Listener, SQMLogger, SetupPlatformTel) |
| priv.appcompat-policy | `registry/privacy/app-compat.yml` (all 6) |
| priv.ceip-off | `registry/privacy/ceip.yml` (all 5) |
| priv.firewall-telemetry-block | `registry/privacy/privacy.yml` (all 4 FirewallRules, Defaults+Parameters, byte-identical) |
| priv.hosts-telemetry-blocklist | `Executables/hosts` (all 49 domains present; shipped + copied in `start.yml`) |
| priv.ifeo-telemetry-exes | `registry/system/ifeo.yml` (all 7 Debugger=taskkill entries) |
| priv.capability-consent-deny | `registry/explorer/win-settings.yml` (all 12 caps, HKCU+HKLM) |
| priv.settings-sync-off | `registry/explorer/win-settings.yml` (all 17 SettingSync values) |
| priv.wifi-sense-off | `registry/explorer/win-settings.yml` (all 5) |
| priv.cloud-messaging-misc | `registry/privacy/privacy.yml` (AllowMessageSync, DisableHelpSticker, DisableMFUTracking +DEFAULT, NVIDIA OptInOrOutPreference) |
| priv.mrt-reporting-off | `registry/updates/updates.yml` (DontReportInfectionInformation) |
| priv.valuebanner-off | `registry/explorer/win-settings.yml` (ActivationType + Server) |
| priv.dev-telemetry-env | `Tasks/final.yml` (`setx DOTNET_CLI_TELEMETRY_OPTOUT 1` + `setx POWERSHELL_TELEMETRY_OPTOUT 1`) |
| priv.winget-telemetry-off | `Executables/settings.json` (`"telemetry":{"disable":true}`) |
| priv.office-telemetry-off | `registry/misc/disable-logging.yml` (DisableLogManagement, TimerInterval) + `final.yml` (`Get-ScheduledTask \Microsoft\Office\*  \| Disable-ScheduledTask`) |
| priv.rsop-logging-off | `registry/misc/disable-logging.yml` (RSoPLogging) |
| priv.wpbt-off | `registry/misc/fixes.yml` (`DisableWpbtExecution=1`). Catalog writes the `CurrentControlSet` hive-path spelling; playbook uses the equivalent `ControlSet001` spelling — same key at runtime, same data, so treated as a duplicate. |

Per-action duplicates inside partially-ported tweaks (the non-listed actions of every "Ported"
tweak above) were also skipped as exact duplicates — e.g. priv.telemetry-policy's first 7 values
(telemetry.yml), the bulk of priv.content-delivery-off (cdm.yml + win-settings.yml), all of
priv.restrict-internet-comm except NoActiveHelp (privacy.yml), etc. They are not re-listed here.

---

## CONFLICTS — second pass

Catalog actions that exist in the playbook but DIFFER, or that the playbook deliberately
inverts/removes. **Not ported — left for the maintainer to decide.**

### 1. priv.search-cloud-history — `AllowCortana` (HKLM, and the HKCU sibling)
- **WinDebloat entry:** `HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search\AllowCortana=0` and
  `HKCU\SOFTWARE\Policies\Microsoft\Windows\Windows Search\AllowCortana=0` (DWORD).
- **Playbook:** `registry/explorer/search.yml:31` sets `HKLM\...\Windows Search\AllowCortana` **= 1**
  (comment "Allow Cortana - Disabled" but data is `1`); no HKCU entry.
- **Difference:** data `0` (WinDebloat) vs `1` (playbook) on HKLM; playbook keeps Cortana policy
  enabled. The HKCU variant is absent but belongs to the same inverted policy, so it was not ported
  either (porting HKCU=0 while HKLM=1 would be self-contradictory). Mech notes this value is
  "Win10-era, harmless".

### 2. priv.feature-advert-tips — `EnableAccountNotifications`
- **WinDebloat entry:** `HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications\EnableAccountNotifications=0` (WH value; the catalog Note explicitly prefers WH's 0).
- **Playbook:** `registry/explorer/win-settings.yml:297-298` sets it **= 1** (HKCU + HKU\.DEFAULT, with `weight: 50`).
- **Difference:** data `0` (WinDebloat) vs `1` (playbook). Mech records the RV/WH disagreement; the
  playbook follows RV's `1`. Not overridden.

### 3. priv.input-personalization-off — `AllowInputPersonalization`
- **WinDebloat entry:** `HKLM\SOFTWARE\Policies\Microsoft\InputPersonalization\AllowInputPersonalization=0`.
- **Playbook:** applies input-personalization disable via `revitool tweaks personalization
  input-personalization disable` (`win-settings.yml:307-312`), and `revert.yml:87` **deletes**
  `AllowInputPersonalization` as part of its onUpgrade rollback (the mechanism was moved from a static
  registry write to the revitool verb).
- **Difference:** the static value is deliberately removed by the playbook; re-adding it would
  reintroduce what `revert.yml` strips. The functional effect (=0) is already applied by the verb at
  runtime. Left unported.

### 4. priv.usage-reporting-off — service `DPS` disabled
- **WinDebloat entry:** service `DPS` Start=4 (Disabled).
- **Playbook:** DPS is **not** disabled in `services.yml`; `revert.yml:136-137` re-enables it
  (`startup: 2`) with the comment "DPS is needed for the Data Usage page in Settings and Network
  monitoring in Task Manager."
- **Difference:** playbook deliberately keeps DPS enabled. Not ported.

---

## Pending (non-registry, new — not ported to avoid editing existing task files)

These catalog actions are genuinely new (not in the playbook) but are **not** registry tweaks, so they
belong in files outside `registry/privacy/` that this task must not edit. Flagged for a follow-up:

- **priv.usage-reporting-off — service `diagsvc` = Disabled** → belongs in `Tasks/services.yml`
  (siblings `WdiServiceHost`/`WdiSystemHost` are already there; `diagsvc` is absent).
- **priv.usage-reporting-off — 3× `wevtutil sl … /e:false`** (SleepStudy/Diagnostic,
  Kernel-Processor-Power/Diagnostic, UserModePowerService/Diagnostic) → map to `!powerShell`/`!cmd`,
  natural home `final.yml` or a new usage-reporting task. (Catalog uses conditional Test/Apply Exec;
  mech lists `/q:false`, which does not change channel state — `/e:false` is the effective form.)
