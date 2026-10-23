# AGENTS.md — ReviOS Playbook fork (WinDebloat) · agent reference

This is a **fork** of the ReviOS AME Wizard playbook (`meetrevision/playbook`), maintained at
`sirmaestro/playbook`, extended with the **WinDebloat** tweak set. There is no build/compile/test
step: `src/` is declarative YAML + XML + PowerShell/CMD, zipped into an `.apbx` by CI. It can only
be truly verified by applying it to a Windows 10/11 VM/ISO with AME Wizard.

## Golden rules for agents working here

1. **WinDebloat extends the playbook in *playbook format*.** New tweaks are added as native AME
   YAML tasks (`!registryValue`, `!service`, `!appx`, …), not by vendoring the WinDebloat PowerShell
   engine and shelling out to `debloat.ps1`. The WinDebloat catalog is the *source of truth for what
   to add*; the playbook YAML is the *delivery format*. See [docs/windebloat-extension.md](docs/windebloat-extension.md).
2. **Confirm with the maintainer before removing or disabling existing playbook functionality.**
   Do not delete, comment out, or `option:`-gate an existing task, Executable, or `playbook.conf`
   entry on your own initiative. Adding/extending is fine; subtracting needs a yes. When WinDebloat
   and the playbook overlap (same registry value, same removal), flag it and propose — don't silently
   drop one side.
3. **Order matters** in `Configuration/main.yml`. Don't reorder without a reason; the comments there
   encode real constraints (e.g. Defender disabling needs Explorer alive, so shell hosts are killed
   *after* the package tasks).
4. **Prefer `wdtool`** (WinDebloat Tool, our fork of Revision Tool's `revitool`, in `debloat-tool/`)
   for component removal and anything heavy. The signed-CBS component removals (Defender, AI, Xbox,
   OneDrive, telemetry) can only be done through it — a plain script cannot reproduce them (see
   [docs/references-learnings.md](docs/references-learnings.md), "Why component removal needs
   revitool/CBS"). Do not try to hand-roll CBS package installs. Older docs say `revitool`; it is the
   same CLI, now `wdtool`.
5. **Keep the *why*.** Many tweaks exist to fix a specific regression; preserve issue-link comments
   (`# https://github.com/meetrevision/playbook/issues/NNN`). When a tweak proves harmful, comment it
   out in its area file AND add a rollback to `revert.yml` (runs `onUpgrade`) — after confirming (rule 2).

## Pipeline

```
playbook.conf (UI pages, options, requirements)
      │  user choices become "options" (string flags)
      ▼
Configuration/main.yml  (entry point, privilege: Admin, runs in order)
  ├─ registry/os-info/{edition,oem-info}.yml
  ├─ Tasks/start.yml            copy files (incl. app installer), hosts, VCRedist, install WinDebloat Tool, ngen, power plan
  ├─ packages/app-win32.yml     Edge, OneDrive, Teams removal   (before win-sxs: avoids leftovers)
  ├─ packages/win-sxs.yml       wdtool winpackage removals, Defender toggle, telemetry removal
  ├─ packages/appx.yml          UWP removal
  ├─ taskKill explorer & shell hosts (Defender disabling needs explorer alive first, kill AFTER)
  ├─ Tasks/services.yml         service startup changes
  ├─ Tasks/registry.yml         aggregator -> ~50 files under Tasks/registry/**
  ├─ Tasks/revert.yml           onUpgrade rollback of tweaks from older playbook versions
  └─ Tasks/final.yml            NTFS tweaks, cleanup, FINALIZE.cmd, wallpaper/theme, restart explorer
```

**WinDebloat tweaks slot in via `Tasks/registry.yml`'s area files (new `Tasks/registry/<area>/*.yml`)
and new option-gated task files**, following the same ordering constraints. See the extension doc for
exactly where each WinDebloat category lands.

## Layout (`src/`)

| Path | Purpose |
|---|---|
| `playbook.conf` | AME metadata, `SupportedBuilds`, `Requirements`, ISO/OOBE settings, `FeaturePages` (all user-facing options) |
| `Configuration/main.yml` | Entry point; `privilege: Admin` |
| `Configuration/Tasks/*.yml` | Top-level task groups; `privilege: TrustedInstaller` |
| `Configuration/Tasks/registry/<area>/*.yml` | Registry tweaks by area: `explorer`, `privacy`, `security`, `system`, `updates`, `misc`, `os-info` |
| `Configuration/Tasks/packages/*.yml` | Removal of Win32 / WinSxS / Appx packages |
| `Executables/` | Scripts/assets AME copies next to the run; referenced with `exeDir: true`. Flat, plus `Licenses/` and `Apps/` |
| `Executables/Apps/*.json` | Post-playbook winget app groups (`winget export` format) for `INSTALL-APPS.cmd`: `base` installs first, the rest are picked from a menu. `start.yml` copies the installer (`INSTALL-APPS.*`, `assoc.ps1`, `Apps\`, `SFTA\`) to `%ProgramData%\WinDebloat\Install Apps` and puts an "Install Apps" shortcut on the Public Desktop |
| `docs/` | Agent references (this fork): extension strategy, distilled learnings/gotchas |

Outside `src/`: `debloat-tool/` is the WinDebloat Tool source (Flutter/Dart + Rust bridge, Inno Setup
installer); see [debloat-tool/README.md](debloat-tool/README.md).

Task file frontmatter: `title`, `description`, `privilege` (`Admin` / `TrustedInstaller`), `actions:`;
`revert.yml` also has `onUpgrade: true`.

## YAML action types (custom tags)

Registered in `.vscode/settings.json` (`yaml.customTags`):
`!task` (include file, path relative to `Configuration\`, backslashes), `!registryValue`, `!registryKey`,
`!service`, `!appx`, `!file`, `!run`, `!cmd`, `!powerShell`, `!taskKill`, `!download`, `!software`,
`!writeStatus` / `!status`. `!systemPackage` is **deprecated** (raw WinSxS delete — main cause of
meetrevision issue #49; use `revitool winpackage` instead). `!scheduledTask` is registered but unused
(the playbook disables tasks via `!powerShell: Get-ScheduledTask … | Disable-ScheduledTask`).

Common keys:
- `option: "name"` runs only if option selected; `option: "!name"` only if NOT selected; `options: [...]` extra required options.
- `oobe: true|false|only`, `iso: false`: restrict to OOBE/ISO contexts.
- `runas: currentUserElevated | trustedInstaller`; `exeDir: true` runs from the `Executables` dir; `wait: true`; `weight: N` (progress-bar share); `errorAction: Ignore|Log|Halt`; `ignoreErrors: true`; `cpuArch: X64|Arm64`.
- Registry: `type: REG_DWORD|REG_SZ|…`, `data: 'N'` (**always a quoted string**), `operation: delete|add`. Hives: `HKLM`, `HKCU`, `HKU\.DEFAULT`, `HKCR`.
- Registry entries are usually one-line flow mappings `{path: …, value: …, type: …, data: …}` with a `# === Policy name - State` comment above; **HKCU settings are usually duplicated for `HKU\.DEFAULT`** so new users inherit them (WinDebloat calls this "(+DEFAULT)" mirroring — preserve it when porting).

## Options (defined in `playbook.conf`, consumed via `option:`)

- Radio: `disable-defender`/`enable-defender`, `disable-hibernate`/`enable-hibernate`
- Checkbox: `remove-edge`, `remove-onedrive`, `remove-winsxs-ai`, `remove-teams`, `remove-appx-photos`, `remove-appx-devhome`, `remove-appx-xbox`, `remove-appx-yourphone`, `configure-darkmode`, `configure-lcm`, `configure-te`, `remove-pinned-items-startmenu`, `disable-automatic-maintenance` (the `configure-wallpaper` option was removed in this fork)
- WinDebloat checkboxes: `windebloat-explorer-cleanup`, `windebloat-show-hidden-files`, `windebloat-quiet-shell`,
  `windebloat-regional-formats`, `windebloat-remove-capabilities`, `windebloat-mmcss`,
  `windebloat-prefer-ipv4`, `windebloat-ps-remotesigned`. Some WinDebloat tweaks reuse existing options instead:
  AI policies/tasks/`WSAIFabricSvc` → `remove-winsxs-ai`; Game Bar/DVR off → `remove-appx-xbox` (#74);
  Smart App Control off → `disable-defender`. Privacy, telemetry, scheduled-task, service and sponsored-appx
  ports are always on.

Adding a user-facing toggle = add a `<CheckboxOption>`/`<RadioOption>` in `playbook.conf` AND reference
its `<Name>` in `option:` in the relevant task file(s). Include the negated `!name` branch if the
default state must be restored (see `configure-darkmode` in `final.yml`).

## WinDebloat Tool (`wdtool`)

Heavy lifting is delegated to `%ProgramFiles%\WinDebloat Tool\wdtool.exe`, built from `debloat-tool/`
(GPL-3.0 fork of Revision Tool, no runtime dependency on meetrevision). `start.yml` installs only the
bundled `Executables\WinDebloatTool-Setup.exe` that CI builds from the same commit (git-ignored locally).
`wdtool` exits `55` unless `edition.yml` has set the `WinDebloat` edition marker or AME is applying this
playbook (`UniqueId` folder in `%TEMP%\AME\Playbooks`), so `edition.yml` must stay first in `main.yml`
and the marker and `<UniqueId>` must not change without updating `WinRegistryService` in the tool.
The CBS removal cabs are pinned in `debloat-tool/src/additionals/packages/winsxs` (see its README). Subcommands:
`winpackage --install <system-components-removal|ai-removal|onedrive-removal|xbox-removal|telemetry-removal>`,
`tweaks security {defender,vbs} enable|disable`, `tweaks performance {powerplan,superfetch,background-apps,ntfs-last-access,ntfs-8dot3-naming,intel-tsx,service-grouping}`,
`tweaks utilities {hibernation,fast-startup}`, `tweaks updates {wu-pause-updates,wu-drivers}`,
`tweaks personalization input-personalization`, `appx --all-users --remove`, `registry hide-page`,
`msstore-apps`, `tweaks patches`. Prefer these over inventing new removal mechanisms.

## CI / release

`.github/workflows/main.yml` (manual dispatch): job `build-tool` builds WinDebloat Tool from
`debloat-tool/` (verifies the pinned cabs) at version `YY.MM`; job `build` sets `<Version>` in
`playbook.conf` and `set version=` in `FINALIZE.cmd` to the same `YY.MM`, bundles
`WinDebloatTool-Setup.exe` into `Executables/`, packs `src/*` into `*.apbx` (7z, AME's standard
password), and publishes a release with both the `.apbx` and `WinDebloatTool-Setup.exe` (the tool's
self-updater looks for that asset name). **Never hand-edit the version fields for a
release.** `docs/` is not packed into the `.apbx` (agent-facing only) — keep it out of `src/`.

## Conventions

- Commit style: `feat(win-sxs): …`, `fix(start): …`, `search: …`, `readme: …`.
- Windows paths use backslashes; single-quoted YAML needs no escaping, double-quoted does (`"%ProgramFiles%\\WinDebloat Tool"`).
- `.cmd` files starting with `<# :` are polyglot CMD/PowerShell hybrids — keep the header intact.

## VM testing

`tools/vmtest.ps1` applies the playbook to the VirtualBox test VM headlessly and writes a JSON verdict.
It drives the guest only through `VBoxManage guestcontrol` (never keyboard injection). It applies with
**TrustedUninstaller.CLI**, AME Wizard's headless core (Ameliorated-LLC/trusted-uninstaller-cli 0.8.4,
SHA256-pinned and cached in `tools/cache/`), so no GUI is involved.

```powershell
$env:VMTEST_GUEST_PASSWORD = '<guest password>'      # VMTEST_GUEST_USER defaults to vboxuser
pwsh tools\vmtest.ps1 -Build                         # build package + full run, VM powered off after
pwsh tools\vmtest.ps1 -Build -KeepRunning            # leave the VM up for inspection
pwsh tools\vmtest.ps1 -ParseOnly out\vmtest\<run>    # re-summarise a past run's logs (no VM)
pwsh tools\vmtest.ps1 -Build -AppsGroups all         # apply, reboot, then run INSTALL-APPS (guest needs network)
pwsh tools\vmtest.ps1 -AppsOnly -AppsGroups base     # INSTALL-APPS only, on a VM left up by -KeepRunning
pwsh tools\vmtest.ps1 -Build -Layers -CacheDownloads -AppsGroups base,media-office   # fast iteration (below)
```

What a run does:
1. **Restore and boot.** Restores `-Snapshot` (default `clean-defender-off-UAC-off`) and boots headless.
2. **Wait for the guest.** Waits for a real `guestcontrol` round-trip plus a logged-on user. There are no
   fixed sleeps.
3. **Copy in.** Copies `tools/vmtest/guest-agent.ps1`, the CLI zip, the package and `options.txt` to
   `C:\vmtest\in`, and checks each file's SHA256 inside the guest.
4. **Precheck.** The agent elevates itself and mirrors the CLI's Defender-toggle check. If real-time
   protection has turned itself back on, it re-disables it with `Set-MpPreference` (Tamper Protection
   must already be off).
5. **Apply.** The agent registers its own scheduled task `vmtest-apply` (RunLevel Highest, Interactive
   logon as the signed-in user) and runs the CLI from it. The harness polls until the CLI exits or
   `-ApplyTimeoutMin` passes. On timeout the apply is marked `hung` and killed.
6. **Pull logs.** Zips the CLI's `Output.txt`/`Log.yml`, job stdout and `ProgramData\AME\Logs` in the
   guest, copies the zip out and checks its hash.
7. **Summarise.** `tools/vmtest/amelog.py` (Python + PyYAML) walks `main.yml` with the engine's own
   applicability rules and pairs each executed action with its `Output.txt` block. It writes
   `summary.json` with these buckets:
   - **applied**
   - **failed**, each with its error: unhandled non-zero exit, inline Error/Critical, or the `55` gate
   - **skipped**, with the option or `onUpgrade` reason
   - **unconfirmed**, for actions with no log block
8. **Revert.** Runs `-RevertScript <file.ps1>` the same way under `-RevertTimeoutMin`. Without the
   flag, `revert.status` is `not-run`, because the playbook has no revert path yet. (`revert.yml` is an
   `onUpgrade` rollback; it runs only on a re-apply.)
9. **Apps (optional).** With `-AppsGroups`, reboots the guest, checks the playbook installed the app
   installer and its desktop shortcut, and runs `%ProgramData%\WinDebloat\Install Apps\INSTALL-APPS.ps1
   -Group <groups>` from the same elevated interactive task, under
   `-AppsTimeoutMin` (default 240). The script always exits 0, so `summary.json` → `apps.summary` is
   parsed from its closing Summary block (installed / failed / reboot-to-finish / default-app types
   set of total, types not set, types with no handler). Any failed app fails the run; its transcript
   is pulled to `logs\apps\`. The post-apply reboot waits up to `-RebootTimeoutSec` (default 2400).
   Default apps are written directly: Windows 11 (26300) keeps the real choice in `UserChoiceLatest`,
   which the vendored `Executables/SFTA/SFTA.ps1` (PS-SFTA, MIT) hashes as Settings does, plus an
   `ApplicationAssociationToasts` entry per handler so Windows does not ask again (see
   docs/references-learnings.md). Verify defaults by opening files in the user's session, not by
   reading the registry.

### Snapshot layers (`-Layers`): fast iteration

A full run costs about 22 minutes. Most of that is the apply (about 8 min) and the app installs (about 11 min
for base + media-office; mpv's GitHub download and Firefox are the slowest). With `-Layers`, the
harness caches finished stages as offline VirtualBox snapshots and reuses them, like image layers:

| Layer | Snapshot | Holds | Cache key (sha256) |
|---|---|---|---|
| L1 | `vmtest-L1-<key>` | the applied playbook, shut down before its first post-apply boot | base snapshot UUID, AME CLI, options, every package file **except** `INSTALL-APPS.cmd/.ps1` and `Apps/*.json` |
| L2 | `vmtest-L2-<key>` | L1 plus the `-AppsGroups` installed | L1 key, the groups, `Apps/*.json`; expires after `-AppsLayerMaxAgeHours` (24) |

- **Building.** L1 replaces the post-apply reboot with `shutdown /s /full`, an offline snapshot, and a
  boot. So L1 costs nothing extra, and every restore replays the same first boot. L2 is taken after a
  clean app run. Layers are built only from clean results (no failed or unconfirmed tweaks, no failed
  apps, no `-RevertScript`).
- **Using.** A hit restores the deepest usable layer and copies the current installer and `Apps` lists in
  (guest-agent `SyncApps`, mirroring `start.yml`). The apply verdict recorded when the layer was built
  goes into `summary.json` (`apply.cachedFrom`), and only the remaining steps run. With an L2 hit,
  INSTALL-APPS reruns against the installed apps (about 1 min). That exercises default apps and the
  summary, not the install code.
- **Flags.** `-FreshApps` ignores L2 (use it when the install logic changed). `-RebuildLayers` ignores
  all hits. `-ClearLayers` deletes every `vmtest-L*` snapshot. `-KeepLayers` (2) is kept per kind (L1s,
  and L2s per L1); older layers are pruned.
- **Records.** `out/vmtest/layers/<name>.json` holds the key inputs, creation time, the run that built
  the layer, and the cached verdict. A snapshot without a record is never used.

Measured times (2026-10-23, base + media-office, with `-CacheDownloads`):

| Change | Layer used | Time |
|---|---|---|
| Playbook YAML or Executables | none | ~22 min (the run also builds both layers) |
| `INSTALL-APPS.ps1` install logic, or `Apps/*.json` (or `-FreshApps`) | L1 | ~6 min: L1 boot 1–2.5 min, apps 3.4 min (11–14 min uncached) |
| `INSTALL-APPS.ps1` default-apps or summary code | L2 | ~1.7 min end to end, build included |

The first boot from L1 can take a while: the Store updates inbox apps right after boot, and the
guest is briefly slow to answer. The harness retries guest hashing for that reason.

Layers are for iterating. The definition of done still needs an **uncached** run (no `-Layers`, or
`-RebuildLayers`): rebuilt package, applied from the clean snapshot, error count compared. Restoring a
layer doesn't re-test what happens before it, such as delivery by `start.yml` or Store updates that
depend on uptime. The VM has 16 GB RAM, so layers are offline snapshots (disk only, a few GB each);
never take live ones.

**Download cache (`-CacheDownloads`).** This avoids re-downloading app installers in the guest, whose
network is much slower than the host's. It is a testing aid only; the files and checks stay the same.
- *GitHub release assets* (mpv; App Installer itself when INSTALL-APPS updates winget) are kept in
  `tools/cache/downloads/`. They are copied in, and INSTALL-APPS's `-DownloadCache` uses one only when
  its SHA-256 matches the release's published digest. New downloads are copied back out.
- *winget packages*: for each one in the selected groups, the host's `winget show` gives the version,
  URL and SHA-256 of the default installer. The host downloads it into
  `tools/cache/downloads/winget/<Id>.<Version>/`, and the harness copies it to the guest's
  `%TEMP%\WinGet\<Id>.<Version>\<sha256>`. winget 1.29 reuses a file there when the hash matches
  ("Existing installer file hash matches"). On any mismatch (new version, different installer) it
  just downloads. Dependencies such as LibreOffice's VC++ runtime are not seeded. Verified: all 8
  winget installers for base + media-office were reused (`REUSED` in winget's DiagOutputDir logs).
  Seeding is skipped on an L2 hit, where the apps are already installed.
- The cache grows with each new version. Delete `tools/cache/downloads/` to reset it.

**Hangs.** The host runs Hyper-V, so VirtualBox uses NEM, and the guest sometimes freezes on restart
or mid-install (busy vCPUs, zero disk I/O, frozen guest clock). The harness detects this itself:
- When restarting, booting or shutting down for a layer, the guest has to do disk I/O. If the disk
  counters (`VBoxManage debugvm <vm> statistics`) don't move for `-StallSec` (360), the harness kills
  that VM's `VBoxHeadless` (PID from `VBox.log`; `controlvm poweroff`/reset can wedge) and boots it
  again, at most twice per wait. A hung layer shutdown is not snapshotted.
- During a job, a hang means unanswered status polls *and* a static disk. The job is reported as
  `vm-hung`, a harness error (exit 2): rerun it.
- Each recovery is listed in `summary.json` → `hangs`. Details are in
  [docs/references-learnings.md](docs/references-learnings.md). Layers also shorten the exposure: a
  hang costs only the current layer.

Exit codes: `0` = pass, `1` = any failed/unconfirmed action, non-success engine result or failed/hung
revert, `2` = harness or VM error (including misaligned log pairing).

Output lands in `out/vmtest/<timestamp>/` (git-ignored):

| File | Contents |
|---|---|
| `summary.json` | The verdict |
| `tweaks.json` | Per-action detail |
| `harness.log` | The harness's own log |
| `logs/` | Everything pulled from the guest |
| `config/` | The exact Configuration that was tested |

`tools/build-package.ps1` (also run by `-Build`) zips `src\*` plus `WinDebloatTool-Setup.exe` into
`out/build/playbook.zip`. The installer is taken from `src\Executables` if present, otherwise from
GitHub release `-ToolRelease` (default `26.10`). So **a local run tests the released tool, not a tool
built from your working tree**.

Snapshot requirements:
- Win11 offline snapshot with Guest Additions and auto-logon.
- Defender Tamper Protection off. This can only be set by hand in the Windows Security UI.
- UAC slider at "Never notify" (`ConsentPromptBehaviorAdmin=0`). `guestcontrol` hands out a filtered
  token, and this is the only prompt-free way to elevate it. The harness checks this and explains if
  it's missing.
- No pre-registered helper tasks are needed.

Reading results:
- "applied" means the action ran without an error. It does not mean the end state was verified. For
  that, diff the end state as described in [docs/references-learnings.md](docs/references-learnings.md)
  ("Validate the end state, not the log").
- Non-zero exits on actions the playbook marks `errorAction: Ignore` are listed as `ignoredExitCode`
  and are not failures.
- Recovered registry warnings (e.g. UCPD-protected `TaskbarDa`, which AME re-applies via `reg.exe`) are
  listed under `warnings`.

Gotchas the harness already handles (keep them in mind when changing it):
- VBoxManage 7.2 `run --` has no argv[0] slot.
- Its exit code is not the guest's, so the agent prints `VMTEST_EXIT=` instead.
- In cmd, `echo %ERRORLEVEL%>f` writes nothing when the code is `0` (cmd reads it as `0>`, a redirect),
  so the exit-marker redirect goes first.
- A one-element PowerShell array unrolls to a string.
- Guest scripts stay ASCII-only for PS 5.1.

## More context

- [docs/windebloat-extension.md](docs/windebloat-extension.md) — how WinDebloat maps into playbook
  format: the catalog→YAML conversion table, where each category lands, overlap/deconfliction policy.
- [docs/references-learnings.md](docs/references-learnings.md) — distilled gotchas from the upstream
  reference projects (the CBS/signing boundary, Defender/PPL facts, the CBS-package decode, revitool
  verbs, VM testing and log-reading notes, monorepo/git line-ending pitfalls, and the catalog of
  "this tweak was reverted because it broke X" lessons).
- [debloat-tool/README.md](debloat-tool/README.md) — WinDebloat Tool: what the fork changed vs Revision
  Tool, re-pinning the CBS cabs, building, and **pulling upstream changes** (`git subtree pull`, no squash).
