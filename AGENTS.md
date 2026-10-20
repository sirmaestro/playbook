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
  ├─ Tasks/start.yml            copy files, hosts, VCRedist, install WinDebloat Tool, ngen, power plan
  ├─ packages/app-win32.yml     Edge, OneDrive, Teams removal   (before win-sxs: avoids leftovers)
  ├─ packages/win-sxs.yml       wdtool winpackage removals, Defender toggle, telemetry removal
  ├─ packages/appx.yml          UWP removal
  ├─ taskKill explorer & shell hosts (Defender disabling needs explorer alive first, kill AFTER)
  ├─ Tasks/software.yml         Brave / Firefox
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
| `playbook.conf` | AME metadata, `SupportedBuilds`, `Requirements`, ISO/OOBE settings, `Software` packages, `FeaturePages` (all user-facing options) |
| `Configuration/main.yml` | Entry point; `privilege: Admin` |
| `Configuration/Tasks/*.yml` | Top-level task groups; `privilege: TrustedInstaller` |
| `Configuration/Tasks/registry/<area>/*.yml` | Registry tweaks by area: `explorer`, `privacy`, `security`, `system`, `updates`, `misc`, `os-info` |
| `Configuration/Tasks/packages/*.yml` | Removal of Win32 / WinSxS / Appx packages |
| `Executables/` | Scripts/assets AME copies next to the run; referenced with `exeDir: true`. Flat, plus `Licenses/`, `Wallpapers/`, `BraveSoftware/` |
| `Images/` | Icons for the software picker in `playbook.conf` |
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

- Radio: `browser-firefox` (default; Brave was removed in this fork), `disable-defender`/`enable-defender`, `disable-hibernate`/`enable-hibernate`
- Checkbox: `remove-edge`, `remove-onedrive`, `remove-winsxs-ai`, `remove-teams`, `remove-appx-photos`, `remove-appx-devhome`, `remove-appx-xbox`, `remove-appx-yourphone`, `configure-darkmode`, `configure-lcm`, `configure-te`, `remove-pinned-items-startmenu`, `disable-automatic-maintenance` (the `configure-wallpaper` option was removed in this fork)
- WinDebloat checkboxes: `windebloat-explorer-cleanup`, `windebloat-show-hidden-files`, `windebloat-quiet-shell`,
  `windebloat-regional-formats` (default off), `windebloat-remove-capabilities`, `windebloat-mmcss`,
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

## More context

- [docs/windebloat-extension.md](docs/windebloat-extension.md) — how WinDebloat maps into playbook
  format: the catalog→YAML conversion table, where each category lands, overlap/deconfliction policy.
- [docs/references-learnings.md](docs/references-learnings.md) — distilled gotchas from the upstream
  reference projects (the CBS/signing boundary, Defender/PPL facts, the CBS-package decode, revitool
  verbs, VM testing notes, and the catalog of "this tweak was reverted because it broke X" lessons).
