# WinDebloat → Playbook extension guide

How the **WinDebloat** tweak set is folded into this ReviOS playbook fork. Read
[../AGENTS.md](../AGENTS.md) first for the playbook format and the golden rules.

## Principle

WinDebloat started as a standalone PowerShell engine (`debloat.ps1` + `engine/` + `catalog/*.psd1` +
`profiles/*.psd1`, upstream at `windows11-debloat`). In this fork we **do not** ship that engine or
run `debloat.ps1`. Instead:

- The WinDebloat **catalog is the source of truth** for *what* each tweak does (registry paths,
  values, service start types, appx names, mechanism notes, risk, and the per-tweak `docs/tweaks/*.mech.md`).
- Each tweak is **re-expressed as a native AME task** in `src/Configuration/Tasks/**` using the
  playbook's custom YAML tags. The result ships in the `.apbx` and runs under AME's TrustedInstaller
  context — no extra runtime.

Why: AME already gives us TrustedInstaller/SYSTEM, the `HKU\.DEFAULT` mirroring convention, option
gating, OOBE/ISO awareness, and `revitool` for the signed-CBS component removals a plain script can't
do (see [references-learnings.md](references-learnings.md)). Re-expressing in playbook format keeps one
delivery mechanism and one review surface.

## Catalog action type → playbook tag

WinDebloat catalog entries carry a `Type`. Port each to the matching AME construct:

| WinDebloat `Type` | Count* | Playbook equivalent | Notes |
|---|---|---|---|
| `Registry` | 720 | `!registryValue` / `!registryKey` | One-line flow mapping + `# === Name - State` comment. **Mirror HKCU → `HKU\.DEFAULT`** (WinDebloat "(+DEFAULT)"). `data:` is always a quoted string. `operation: delete` for removals. `TI = $true` → the task's `privilege: TrustedInstaller` (default for `Tasks/**`) covers it. |
| `Service` | 43 | `!service` | Start type maps directly (2=auto,3=manual,4=disabled). |
| `Appx` | 119 | `!appx` or `revitool appx --all-users --remove <csv>` | Playbook removes provisioned+installed for all users via revitool; prefer that for parity. Gate behind the existing `remove-appx-*` options where one exists. |
| `ScheduledTask` | 26 | `!powerShell: Get-ScheduledTask … \| Disable-ScheduledTask` | `!scheduledTask` tag is registered but unused in the playbook — follow the existing `Get-ScheduledTask` pattern (see `final.yml`). |
| `Capability` | 6 | `!powerShell` (`Remove-WindowsCapability -Online`) or `revitool` | |
| `Feature` | 1 | `DISM-FEATURES.ps1` / `!powerShell Disable-WindowsOptionalFeature` | |
| `Bcdedit` | 6 | `!cmd: bcdedit …` or `!run` | |
| `File` | 2 | `!file` | Delete/replace. |
| `Env` | 2 | `!cmd: setx …` | `runas: currentUserElevated` for user env. |
| `Hosts` | 1 | Executables `hosts` file + copy in `start.yml` | The playbook already ships `Executables/hosts`; merge WinDebloat's blocklist into it rather than scripting edits. |
| `Exec` | 13 | `!run` / `!cmd` | |
| `Script` | 9 | an `Executables/*.ps1` **or** a `revitool` subcommand | Map by intent — see below. |

\* counts are from the upstream catalog at time of writing; re-check with the catalog, don't trust the number.

### `Script`-type tweaks — map to revitool/existing Executables, don't port the PowerShell

WinDebloat's `engine/scripts/*` mostly duplicate things the playbook already does better:

| WinDebloat script | Playbook equivalent (prefer this) |
|---|---|
| `DefenderDisable.ps1` | `revitool tweaks security defender disable` + the `disable-defender` radio (CBS component removal). **Do not** port the registry-only disable — it can't stop the processes (see learnings). |
| `EdgeRemoval.ps1` | `Executables/EDGE.ps1` + `packages/app-win32.yml`, option `remove-edge`. |
| `OneDriveRemoval.ps1` | `Executables/ONED.cmd` + `revitool winpackage --install onedrive-removal`, option `remove-onedrive`. |
| `StartPins.ps1` | `Executables/LayoutModification.{xml,json}` + `STARTMENU.cmd`, option `remove-pinned-items-startmenu`. |
| `UpdatePause.ps1` | `revitool tweaks updates wu-pause-updates enable`. |
| `pwr-*Plan*.ps1` | `revitool tweaks performance powerplan enable`. |
| `sec-RefreshRootCerts.ps1` / `priv-WingetTelemetry.ps1` | `settings.json` (winget) is already shipped; port cert refresh as a small `!cmd`/`!powerShell` if not covered. |

## Where each category lands in `main.yml` order

Respect the existing ordering (AGENTS.md rule 3). Suggested homes:

- **Privacy / telemetry / advertising / content-delivery registry** → new files under
  `Tasks/registry/privacy/` (merge with existing privacy area; the playbook already covers much of it —
  deconflict, don't duplicate).
- **Services** → `Tasks/services.yml`.
- **Scheduled tasks** → a new `Tasks/scheduled-tasks.yml` invoked from `main.yml` near services.
- **Explorer / shell / Start / context-menu / appearance** → `Tasks/registry/explorer/` and the
  `final.yml` theme/layout steps.
- **Performance / power / NTFS / kernel** → `revitool tweaks performance …` in `final.yml` +
  `Tasks/registry/system/`.
- **Network / DNS** → `Tasks/registry/system/` or a new `Tasks/registry/network/`.
- **Security (VBS/HVCI/SmartScreen/SAC)** → `Tasks/registry/security/` + `revitool tweaks security vbs`.
- **Appx** → `packages/appx.yml`.

## Deconfliction policy (critical)

The playbook and WinDebloat overlap heavily (both set telemetry, privacy, services, appx). Before adding
a WinDebloat tweak:

1. **Search the playbook first** for the same path/value/package. If present and identical → skip (no
   duplicate).
2. If present but **divergent** (different data, or playbook comments it out with a reason) → **do not
   override silently.** Flag it to the maintainer with both values and the WinDebloat mech note; let
   them decide. Many playbook omissions are deliberate (see the "reverted because it broke X" list in
   references-learnings.md).
3. If absent → add it, in the right area file, with a `# === Name - State` comment and the WinDebloat
   id/mech reference in the comment for traceability.
4. **Never remove or gate an existing playbook task to make room** without explicit confirmation
   (AGENTS.md rule 2).

## Traceability

When porting a tweak, cite its WinDebloat id in the YAML comment, e.g.
`# win: priv.advertising-id-off` — so a future agent can diff the port against the catalog. A running
checklist of ported vs pending categories belongs in `docs/windebloat-port-status.md` (create it when
porting starts).
