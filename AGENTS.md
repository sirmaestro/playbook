# AGENTS.md — ReviOS Playbook fork (WinDebloat) · agent reference

A **fork** of the ReviOS AME Wizard playbook (`meetrevision/playbook`), maintained at `sirmaestro/playbook`,
extended with the **WinDebloat** tweak set. No build/test step: `src/` is declarative YAML + XML + PowerShell/CMD,
zipped into an `.apbx` by CI. It is only truly verified by applying it to a Windows 11 VM (`docs/vmtest.md`).

## Golden rules

1. **Extend the playbook in *playbook format*.** New tweaks are native AME YAML tasks (`!registryValue`, `!service`,
   `!appx`, …), never the WinDebloat PowerShell engine. The WinDebloat catalog says *what* to add; the YAML is the
   *delivery format* ([docs/windebloat-extension.md](docs/windebloat-extension.md)).
2. **Confirm with the maintainer before removing or disabling existing playbook functionality** (no deleting,
   commenting out or `option:`-gating a task, Executable or `playbook.conf` entry on your own). Adding is fine;
   subtracting needs a yes. Where WinDebloat and the playbook overlap, flag it and propose.
3. **Order matters** in `Configuration/main.yml`; the comments there encode real constraints (e.g. Defender
   disabling needs Explorer alive, so shell hosts are killed *after* the package tasks). `edition.yml` stays first.
4. **Prefer `wdtool`** (`debloat-tool/`, our fork of Revision Tool) for component removal and anything heavy. Signed-CBS
   removals (Defender, AI, Xbox, OneDrive, telemetry) can only be done through it; never hand-roll CBS installs.
5. **Keep the *why*.** Preserve issue-link comments. When a tweak proves harmful, comment it out in its area file AND
   add a rollback to `revert.yml` (`onUpgrade`) — after confirming (rule 2). Check new tweaks against the reverted
   list in the learnings doc first.

Also: read this and [docs/references-learnings.md](docs/references-learnings.md) before starting; keep both lean.
`archive/` is frozen history: when a section of a live doc grows or goes stale, move it there verbatim (see
`archive/README.md`) and leave a pointer, don't delete it.

## Pipeline

```
playbook.conf (UI pages, options, requirements) → options (string flags)
Configuration/main.yml  (entry point, privilege: Admin, runs in order)
  ├─ registry/os-info/{edition,oem-info}.yml
  ├─ Tasks/start.yml     copy files (incl. app installer), hosts, VCRedist, install WinDebloat Tool, ngen, power plan
  ├─ packages/app-win32.yml  Edge, OneDrive, Teams   (before win-sxs: avoids leftovers)
  ├─ packages/win-sxs.yml    wdtool winpackage removals, Defender toggle, telemetry
  ├─ packages/appx.yml       UWP removal
  ├─ taskKill explorer & shell hosts (AFTER the Defender work)
  ├─ Tasks/services.yml, Tasks/registry.yml (→ ~50 files under Tasks/registry/**)
  ├─ Tasks/revert.yml        onUpgrade rollback of tweaks from older playbook versions
  └─ Tasks/final.yml         NTFS tweaks, cleanup, FINALIZE.cmd, wallpaper/theme, restart explorer
```

New WinDebloat tweaks go in `Tasks/registry/<area>/*.yml` or new option-gated task files, same ordering rules.

## Layout (`src/`)

| Path | Purpose |
|---|---|
| `playbook.conf` | AME metadata, `SupportedBuilds`, `Requirements`, ISO/OOBE settings, `FeaturePages` (all options) |
| `Configuration/main.yml`, `Tasks/*.yml` | Entry point (`privilege: Admin`); task groups (`privilege: TrustedInstaller`) |
| `Configuration/Tasks/registry/<area>/` | Registry tweaks: `explorer`, `privacy`, `security`, `system`, `updates`, `misc`, `os-info` |
| `Configuration/Tasks/packages/` | Win32 / WinSxS / Appx removal |
| `Executables/` | Scripts AME copies next to the run (`exeDir: true`); `Apps/*.json` = winget app groups for `INSTALL-APPS` (`base` first, others by menu; a group may list `WindowsFeatures`); `SFTA/` = vendored PS-SFTA |

Outside `src/`: `debloat-tool/` (WinDebloat Tool: Flutter/Dart + Rust bridge, Inno Setup; see its README, also for
`git subtree pull` upstream syncs), `tools/` (harness, `build-package.ps1`), `docs/`, `archive/`.

## YAML action types

Custom tags (`.vscode/settings.json`): `!task` (path relative to `Configuration\`), `!registryValue`, `!registryKey`,
`!service`, `!appx`, `!file`, `!run`, `!cmd`, `!powerShell`, `!taskKill`, `!download`, `!software`, `!writeStatus`.
`!systemPackage` is **deprecated** (raw WinSxS delete; meetrevision #49); use `wdtool winpackage`.
Keys: `option: "name"` / `"!name"`, `options: [...]`, `oobe`, `iso`, `runas: currentUserElevated|trustedInstaller`,
`exeDir`, `wait`, `weight`, `errorAction`, `ignoreErrors`, `cpuArch`. Registry: `data: 'N'` is **always a quoted
string**, `operation: delete|add`, hives `HKLM`/`HKCU`/`HKU\.DEFAULT`/`HKCR`. `HKU\.DEFAULT` is the **SYSTEM** profile, not the template for new
accounts; new users get the applied HKCU tweaks from `Executables/DEFAULTUSER.ps1` (final.yml), which copies them into
`C:\Users\Default\NTUSER.DAT`. Frontmatter: `title`, `description`,
`privilege`, `actions:` (`revert.yml` also `onUpgrade: true`).

## Options

Defined in `playbook.conf`, consumed via `option:`. Adding a toggle = a `<CheckboxOption>`/`<RadioOption>` in
`playbook.conf` AND `option:` in the task file(s); add the negated `!name` branch if the default must be restored
(see `configure-darkmode` in `final.yml`). WinDebloat toggles are named `windebloat-*`; some WinDebloat tweaks reuse
existing options (AI → `remove-winsxs-ai`, Game Bar → `remove-appx-xbox`, Smart App Control → `disable-defender`);
privacy, telemetry, scheduled-task, service and sponsored-appx ports are always on. Current list: read `playbook.conf`.

## WinDebloat Tool and CI

`wdtool` (`%ProgramFiles%\WinDebloat Tool\wdtool.exe`, GPL-3.0 fork, no runtime dependency on meetrevision) is
installed by `start.yml` from the bundled `WinDebloatTool-Setup.exe` CI builds from the same commit. It exits **`55`**
on every command unless `edition.yml` set the `WinDebloat` marker or AME is applying this playbook (`UniqueId` folder in
`%TEMP%\AME\Playbooks`): do not change the marker or `<UniqueId>` without updating `WinRegistryService` in the tool, and
grep `Output.txt` for `exit code: 55` after an apply. CBS cabs are pinned in `debloat-tool/src/additionals/packages/winsxs`.
`.github/workflows/main.yml` (manual dispatch): `build-tool` at `YY.MM`, then `build` stamps `<Version>` and
`FINALIZE.cmd`, packs `src/*` into the `.apbx` and releases it with `WinDebloatTool-Setup.exe`. **Never hand-edit the
version fields.** `docs/` is not packed; keep it out of `src/`.
`.github/workflows/verify.yml` (every push/PR, and a gate in `main.yml`) runs `tools/verify_playbook.py --ps51`: YAML parses,
only known `!tags`, quoted registry `data`, every `option`/`!task`/Executable resolves, own identity (not ReviOS), no mixed
line endings, scripts ASCII and parseable by Windows PowerShell 5.1. `main.yml` re-opens the built `.apbx` with `--package`
(file parity with `src/`, installer present, version stamped). Locally: `uv run --with pyyaml python tools/verify_playbook.py --ps51`.

## Conventions

- Commits: `feat(win-sxs): …`, `fix(start): …`. Windows paths use backslashes; double-quoted YAML needs them escaped.
- `.cmd` files starting with `<# :` are CMD/PowerShell polyglots: keep the header intact.
- Line endings: root `.gitattributes` stores LF and checks out CRLF (AME needs CRLF); no per-file overrides.

## VM testing

`tools/vmtest.ps1` applies the playbook to the Hyper-V VM `windowstest-hv` through PowerShell Direct and writes
`out/vmtest/<run>/summary.json`. Full how-to, flags, layers and base-VM requirements: **[docs/vmtest.md](docs/vmtest.md)**.

```powershell
$env:VMTEST_GUEST_PASSWORD = '<guest password>'
pwsh tools\vmtest.ps1 -Build                                                       # uncached full run (the definition of done)
pwsh tools\vmtest.ps1 -Build -Layers -CacheDownloads -AppsGroups base,media-office # fast iteration on layers
```

- **Done** = package rebuilt, applied from the clean checkpoint on the VM **without layers**, error count compared to
  the previous run. Layers are for iterating only. Run totals vary by 30–100 s: compare steps (`docs/vmtest-phase-breakdown.md`).
- A local run tests the *released* tool, not a tool built from the working tree (tool changes are CI-compiled only).
- Never take live checkpoints; the harness prunes old `vmtest-L*` checkpoints itself (keeps the newest L1 + L2).

## More context

- [docs/references-learnings.md](docs/references-learnings.md) — short list of facts that are expensive to re-derive; pointers into the archive.
- [docs/vmtest.md](docs/vmtest.md), [docs/vmtest-phase-breakdown.md](docs/vmtest-phase-breakdown.md) — harness how-to; where the time goes and why.
- [docs/windebloat-extension.md](docs/windebloat-extension.md), `docs/windebloat-conflicts.md`, `docs/windebloat-port-status.md`, `docs/port/` — how WinDebloat maps into playbook format, overlaps, per-area port notes.
- [docs/atlas-comparison.md](docs/atlas-comparison.md) — AtlasOS 0.6 and Atlas Toolbox (`reference/`) vs this playbook and `wdtool`: learnings, ranked ideas, tweak candidates.
- [archive/README.md](archive/README.md) — retired notes kept verbatim (the old long AGENTS.md and learnings, the VirtualBox harness). Search: `rg -n "<term>" archive/`.
- **Upstream playbook** (`meetrevision/playbook`): remote `upstream-playbook` (`--no-tags`); `git fetch upstream-playbook`, `git merge upstream-playbook/main`. Last synced 2026-11-09 (bc9f08a). With a dirty tree, do both syncs (this and the tool's) in `git worktree add ../playbook-sync -b upstream-sync`, then `git merge --ff-only upstream-sync` and remove the worktree.
