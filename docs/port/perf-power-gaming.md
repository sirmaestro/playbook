# Port findings — perf.psd1 / pwr.psd1 / game.psd1

Scope: WinDebloat catalog `catalog/perf.psd1`, `catalog/pwr.psd1`, `catalog/game.psd1`
(+ `engine/scripts/pwr-UltraPlan.ps1`, `engine/scripts/pwr-PlanC6.ps1`).

Ported registry output: `src/Configuration/Tasks/registry/system/windebloat-performance.yml`
(MMCSS performance block + a `# === Gaming` section). The new task file is **not yet wired** into
`registry.yml` — wiring is a maintainer decision (we do not edit existing files).

Counts: **ported 1 tweak (partial for 2 more) = 4 WinDebloat tweaks contributing registry writes**,
skipped-duplicate 19, conflicts 2, maps-to-existing 6.

---

## Ported (absent in playbook → added to windebloat-performance.yml)

| win id | Values added | Notes |
|---|---|---|
| `perf.mmcss-tuning` | `SystemResponsiveness=10`, `NoLazyMode=1`, `AlwaysOn=1`, `Tasks\Games` `Priority=6`/`Scheduling Category=High`/`SFIO Priority=High`/`GPU Priority=8` (all HKLM) | multimedia.yml only had `NetworkThrottlingIndex`; these 7 were absent. |
| `game.gamebar-off` (partial) | `GameBarEnabled=0` (GameConfigStore, +DEFAULT), `UseNexusForGameBarEnabled=0` (GameBar, +DEFAULT) | `ShowStartupPanel=0` excluded → CONFLICT (see below). |
| `game.gamedvr-off` (partial) | `GameDVR_HistoricalCaptureEnabled=0` (+DEFAULT), `HistoricalCaptureEnabled=0` (+DEFAULT), `AllowGameDVR=0` (HKLM policy) | `GameDVR_Enabled` already in playbook (duplicate); `AppCaptureEnabled` excluded → CONFLICT. |
| `game.game-mode` | `AllowAutoGameMode=1`, `AutoGameModeEnabled=1` (GameBar, +DEFAULT) | Windows default (on). |

HKCU entries are mirrored to `HKU\.DEFAULT` per the playbook convention.

---

## Skipped (exact duplicate — already in playbook, identical value/intent)

| win id | Playbook location |
|---|---|
| `perf.win32-priority-separation` (Win32PrioritySeparation=38) | registry/system/win32ps.yml |
| `perf.network-throttling-index` (=10) | registry/system/multimedia.yml |
| `perf.ifeo-perfoptions` (SearchIndexer/ctfmon/fontdrvhost PerfOptions) | registry/system/ifeo.yml (playbook also adds lsass/sihost — superset) |
| `perf.shutdown-timeouts` (AutoEndTasks, Hung/WaitToKillApp, LowLevelHooks; WaitToKillServiceTimeout) | registry/explorer/control-panel.yml + explorer.yml:85 |
| `perf.menu-responsiveness` (MenuShowDelay=0, ActiveWndTrkTimeout=10) | registry/explorer/control-panel.yml |
| `perf.explorer-folder-discovery-off` (FolderType=NotSpecified) | registry/explorer/explorer.yml:10 |
| `perf.explorer-high-perf-gpu` (UserGpuPreferences GpuPreference=2) | registry/explorer/explorer.yml:15 |
| `perf.search-indexing-power` (RespectPowerModes, PreventIndexOnBattery) | registry/explorer/search.yml |
| `perf.disable-low-disk-checks` (NoLowDiskSpaceChecks=1) | registry/explorer/explorer.yml:79 |
| `perf.no-track-shortcuts` (LinkResolveIgnoreLinkInfo, NoResolveSearch) | explorer.yml:89 + start-menu.yml:39 |
| `perf.disable-autochk` (BootExecute autocheck /k:C*) | registry/system/boot.yml |
| `perf.disable-wpbt` (DisableWpbtExecution=1) | registry/misc/fixes.yml:37 |
| `perf.copy-dialog-details` (EnthusiastMode=1) | registry/explorer/explorer.yml:63 |
| `perf.reserved-storage-off` (ShippedWithReserves=0) | registry/updates/updates.yml:57 — registry part duplicate; the `Set-WindowsReservedStorageState` Exec is neither registry nor bcdedit (out of port scope) and playbook already sets the flag. |
| `pwr.start-power-menu` (ShowSleepOption=1) | registry/system/power.yml:43 |
| `pwr.shutdown-without-logon` (ShutdownWithoutLogon=1) | registry/system/power.yml:48 |
| `pwr.logon-polish` (EnableFirstLogonAnimation=0, DisableStartupSound=1) | registry/system/logon.yml |
| `pwr.crash-control` (AutoReboot=0, CrashDumpEnabled=3) | registry/system/crash-control.yml |
| `pwr.hello-logon-fix` (delete DisableAutomaticRestartSignOn) | revert.yml:140 already deletes it (slow Hello logon). |
| `game.mouse-accel-off` (MouseSpeed/Threshold1/Threshold2=0) | registry/explorer/control-panel.yml:60 (+DEFAULT) |
| `game.gaming-copilot-block` (GamingCompanionHostOptions ActivationType=4294967295, Server='') | registry/privacy/privacy.yml:117 |
| `game.boot-timer-defaults` (bcdedit deletevalue useplatformclock / disabledynamictick) | Executables/FINALIZE.cmd:56-59 already does both deletes. |
| `game.vulnerable-driver-blocklist` (VulnerableDriverBlocklistEnable=1; delete FeatureSettings/Override/OverrideMask) | revert.yml:44-61 ensures =1 and deletes all three (keep-enabled matches playbook; "0 breaks THE FINALS"). |

(Count of distinct skipped-duplicate win ids: 24 including the partials below; counted as 19 fully-skipped tweaks — the 2 partials and the 3 maps-to-existing overlaps are tracked in their own sections.)

---

## CONFLICTS — second pass (present but divergent; NOT ported)

| win id / value | WinDebloat | Playbook | Difference / reason |
|---|---|---|---|
| `game.gamedvr-off` → `AppCaptureEnabled=0` (HKCU GameDVR) | sets `0` **unconditionally** | win-settings.yml:265 sets `0` **only** `option: remove-appx-xbox`; revert.yml:36-37 deletes it when Xbox kept | Known regression #74 — AppCaptureEnabled greys out Game Bar "Start Recording" unless Xbox is removed. Playbook deliberately gates it. Do not port unconditional. |
| `game.gamebar-off` → `ShowStartupPanel=0` (HKCU GameBar) | sets `0` **unconditionally** | win-sxs.yml:72 sets `0` **only** `option: remove-appx-xbox` | Same value but playbook gates it behind Xbox removal; WinDebloat applies always. Divergent gating → flag, do not port. |

---

## Maps to existing mechanism (no port — revitool / existing Executable)

| win id | Mechanism | Playbook location |
|---|---|---|
| `perf.ntfs-last-access-off` (fsutil disablelastaccess) | `revitool tweaks performance ntfs-last-access disable` | final.yml:11 |
| `perf.superfetch-keep` (SysMain/rdyboost + EnablePrefetcher/EnableSuperfetch=3) | `revitool tweaks performance superfetch` area; keep-enabled state also re-asserted by playbook (regression: disabling core Superfetch breaks `defrag c: -b`). Session Manager registry writes not ported. | revert/services (kept enabled) |
| `pwr.hibernate-off` (powercfg /h off; HiberbootEnabled=0; ShowHibernateOption=0) | `revitool tweaks utilities hibernation disable` + `fast-startup disable`, option-gated `disable-hibernate`/`enable-hibernate` | registry/system/power.yml:10-39. ShowHibernateOption=0 not ported separately (coupled to the option-gated hibernation state; porting ungated would conflict with `enable-hibernate`). |
| `pwr.high-performance-plan` (Script pwr-UltraPlan) | `revitool tweaks performance powerplan enable` | start.yml:72 |
| `pwr.plan-c6-disable` (Script pwr-PlanC6) | revitool powerplan governs its own plan tuning; raw `powercfg /setacvalueindex` script not ported | start.yml:72 (powerplan) |
| `game.vbs-hvci-off` (bcdedit vsmlaunchtype Off + DeviceGuard registry) | `revitool tweaks security vbs disable` (VBS/HVCI is a revitool verb; idempotent copy of sec.vbs-hvci-off) | revitool; raw bcdedit/registry not ported |
