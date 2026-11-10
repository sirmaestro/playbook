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
| `Executables/Apps/*.json` | Post-playbook winget app groups (`winget export` format) for `INSTALL-APPS.cmd`: `base` installs first, the rest are picked from a menu. A group may also list `WindowsFeatures` (e.g. `development` enables Hyper-V and the Virtual Machine Platform; needs a restart). `start.yml` copies the installer (`INSTALL-APPS.*`, `assoc.ps1`, `Apps\`, `SFTA\`) to `%ProgramData%\WinDebloat\Install Apps` and puts an "Install Apps" shortcut on the Public Desktop |
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

