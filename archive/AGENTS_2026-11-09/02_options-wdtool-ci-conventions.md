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

