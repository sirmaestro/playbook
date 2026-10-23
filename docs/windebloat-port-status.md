# WinDebloat → playbook port status

First-pass port of the WinDebloat catalog (`windows11-debloat`) into native playbook YAML, done by
category. See [windebloat-extension.md](windebloat-extension.md) for the method and
[windebloat-conflicts.md](windebloat-conflicts.md) for the second-pass worklist.

## Totals (first pass)

| Category | Ported | Skipped (exact dup) | Conflicts | Maps to existing (revitool/Executable) |
|---|---|---|---|---|
| Privacy (`priv`) | 17 tweaks / 51 entries | 18 | 4 | — |
| Security (`sec`,`heavy`) | 4 | 6 | 0 | 7 |
| Services + Scheduled tasks (`svc`,`task`) | 2 svc + 11 task-disables | 23 | 0 | — |
| Perf/Power/Gaming (`perf`,`pwr`,`game`) | 4 | 19 | 2 | 6 |
| Network (`net`) | 1 | 0 | 0 | — |
| Shell/UI (`look`,`ctx`,`shell`,`start`) | 8 | 20 | 3 | 3 |
| Appx/AI/Edge (`appx`,`ai`,`edge`) | 12 | 40 | 2 | 12 |
| Features/Misc/Updates (`feat`,`misc-features`,`misc`,`upd`) | 9 | 13 | 2 | 4 |
| **Total** | **~88** | **~130** | **13** | **~32** |

The high duplicate count confirms the two projects target the same hardening — most of WinDebloat was
already in the playbook. The real value of the port is the gaps (ported) and the divergences (conflicts).

## Ported files (new, additive)

Registry area files (wired from `Tasks\registry.yml`):
- `registry/privacy/windebloat-privacy.yml`
- `registry/security/windebloat-security.yml`, `registry/security/windebloat-ai.yml`
- `registry/system/windebloat-performance.yml`, `registry/system/windebloat-network.yml`
- `registry/explorer/windebloat-shell.yml`
- `registry/misc/windebloat-misc.yml`, `registry/misc/windebloat-edge.yml`

Top-level task files (wired from `Configuration\main.yml`):
- `Tasks/windebloat-services.yml`, `Tasks/windebloat-scheduled-tasks.yml`, `Tasks/windebloat-features.yml`
- `Tasks/packages/windebloat-appx.yml`

Per-category findings: `docs/port/*.md`.

Every ported action carries a `# win: <catalog id>` trace comment for diffing against the catalog.

## Pending / second-pass items beyond the 13 conflicts

These were flagged by the port agents as gaps that aren't a value conflict — they need a follow-up pass,
most of which touch an **existing** file (so they need confirmation per the golden rule):

- **`priv.usage-reporting-off`** — the `diagsvc` service disable belongs in `services.yml`; its 3
  `wevtutil … /e:false` channel disables belong in `final.yml`. Not ported (would edit existing files).
- **`task.etw-diagnostic-channels`** — `FINALIZE.cmd` already runs `/q:false` on the same 3 channels
  but **not** `/e:false`, so channel disabling is only partial. Needs an Exec/wevtutil pass.
- **`misc.hide-settings-pages`** — mostly covered by `revitool registry hide-page`, but WinDebloat's
  list includes an `aicomponents` page the existing revitool call does not hide. Gap.
- **`edge.edgeupdate-manual`** — playbook sets only the `edgeupdate` service to Manual; WinDebloat also
  wants `edgeupdatem` + `MicrosoftEdgeElevationService`. Belongs in `services.yml`.
- **`svc.msi-safeboot`** — Registry-type (already identical in
  `registry/misc/msi-installer-in-safe-mode.yml`); exact dup, no action.
- **`appx.third-party-promos`** — WinDebloat used `*`-wildcard names; ported with wildcards stripped to
  core identifiers for revitool. Loosely-named ones (Flipboard, iHeartRadio, TuneInRadio, SlingTV) need
  full package names — **verify on a VM**.

## Playbook issues surfaced during the port (need maintainer confirmation to fix)

- **`packages/appx.yml` MixedReality.Portal** — lists `MixedReality.Portal` without the `Microsoft.`
  prefix, so it won't match the real package (the correct full name is used in
  `deprovisioned-apps.yml`). Likely a typo. Fixing it = editing existing functionality → confirm first.
- **`packages/appx.yml` SecureAssessmentBrowser** — listed for per-user appx removal, but that returns
  `0x80070032` and it's actually removed at CBS level by `system-components-removal`. The appx line is an
  effective no-op. Optional cleanup → confirm first.

## Wiring status

**Wired 2026-10-19.** All 12 port files are included: the 8 registry area files from a `# === WinDebloat
extension` block appended to `Tasks\registry.yml`, and the 4 top-level files from `Configuration\main.yml`
(`windebloat-appx.yml` + `windebloat-features.yml` after `appx.yml`; `windebloat-services.yml` +
`windebloat-scheduled-tasks.yml` after `services.yml`). All include paths verified to resolve.

Conflict decision: keep the playbook value for all value conflicts; both playbook bugs fixed (see
[windebloat-conflicts.md](windebloat-conflicts.md)). Verified on a VM 2026-10-19 — see below. The YAML cannot be
truly tested without applying the playbook via AME Wizard (see the VM testing prompt).

## VM verification (2026-10-19, windowstest, Win11 26300.9457, AME Wizard 0.8.4)

Applied from the `UAC-off` snapshot with default options + Xbox removal. AME `Log.yml`: **0 errors**, 4 warnings, and
none of those came from WinDebloat (upstream `taskbar.yml` `TaskbarDa`/`ShellFeedsTaskbarViewMode` writes are denied
by UCPD; both values ended up correct anyway). Registry/service/appx/capability spot checks across every
`windebloat-*.yml` passed, and so did the regression checks (AllowCortana=1, DPS enabled, VulnerableDriverBlocklistEnable=1,
condrv=2, bam on, AppCaptureEnabled gated, Game Mode present). `Microsoft.MixedReality.Portal` is gone. No
`0x80070032` appeared. SecureAssessmentBrowser remains a NonRemovable system app registered only for S-1-5-18 (it's
deprovisioned, and the dropped appx line couldn't have removed it).

**Bug found + fixed:** all 11 `windebloat-scheduled-tasks.yml` commands failed with a PowerShell parse error
(`-TaskPath "\…\"` → trailing `\"` escapes the quote on the powershell.exe command line). Rewritten with the
`services.yml` quoting style and verified on the VM with an AME-style command-line harness (the old form
reproduces the error; the new form matches the tasks). Also added `WindowsAI\Recall\*` (the 26300 location).
Feedback\Siuf, ProgramDataUpdater and the old Recall names don't exist on 26300 and now no-op.

revitool's `appx --remove` exits 1 when *none* of the listed packages are installed (seen for both WinDebloat appx
lists on a clean image). This is harmless.

## Fork changes after the first VM run

- Rebranded to **WinDebloat**: `playbook.conf` identity (new UniqueId, so AME stops flagging it as a tampered ReviOS),
  edition/OEM info, the FINALIZE.cmd boot entry/Model/Organization. Kept: Revision Tool references (functional),
  upstream issue links, and the CC BY-SA credit in `<Details>`.
- Removed the wallpaper (`configure-wallpaper`, WALLPAPER.ps1, WallpaperStartup.cmd, Wallpapers/). `dark.theme` is still applied by `configure-darkmode`.
- Removed Brave (option, software.yml block, BraveSoftware/, brave.png, license). Firefox is now the default browser choice.
- Removed the software step (software.yml, the `browser-firefox` option and browser page, `<Software>`, firefox.png).
  Apps, Firefox included, are now installed after the playbook by `Executables/INSTALL-APPS.cmd` from `Executables/Apps/*.json`;
  `start.yml` copies it to `%ProgramData%\WinDebloat\Install Apps` with an "Install Apps" Public Desktop shortcut.
- Gated the WinDebloat ports behind options (see AGENTS.md "Options").
