# WinDebloat Tool

Companion CLI (`wdtool.exe`) and GUI (`wdtoolw.exe`) for the [WinDebloat playbook](../README.md).
The playbook installs it from the bundled `WinDebloatTool-Setup.exe` and calls `wdtool` for the work a
plain YAML task can't do: AppX removal for all users, the signed CBS removal packages (AI, Xbox,
OneDrive, telemetry, system components, Defender), the power plan, and VBS/update/utility tweaks.

> [!WARNING]
> Every command exits with code `55` unless the system carries the WinDebloat edition marker
> (`EditionSubManufacturer` or `EditionSubVersion` = `WinDebloat` under
> `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`, set by the playbook's `edition.yml`) or the
> WinDebloat playbook is currently being applied by AME Wizard.

## Fork of Revision Tool

This is a fork of [Revision Tool](https://github.com/meetrevision/revision-tool) by MeetRevision,
imported into this monorepo and decoupled from upstream:

| | Upstream | Here |
|---|---|---|
| Support gate | ReviOS edition / `Revision-ReviOS*` CBS package | WinDebloat edition marker / WinDebloat AME playbook folder |
| Self-update | `meetrevision/revision-tool` releases | `WinDebloatTool-Setup.exe` on `sirmaestro/playbook` releases |
| CBS removal cabs | downloaded at runtime from `meetrevision/packages` | pinned copies committed in `src/additionals/packages/winsxs`, verified against `src/tool/winsxs_packages.json`; never downloaded |
| Install | `%ProgramFiles%\Revision Tool`, `revitool.exe` | `%ProgramFiles%\WinDebloat Tool`, `wdtool.exe` (separate installer AppId and settings key `HKLM\SOFTWARE\WinDebloat\WinDebloat Tool`) |

The cabs keep their upstream CBS identity (`Revision-ReviOS-*-Removal`); it is part of the signed
package and can't be renamed. Internal identifiers (`revitool` Dart package, `revitool_native` crate)
are unchanged to keep the diff against upstream reviewable.

### Updating the pinned CBS packages

1. Download the `.cab` assets of a newer upstream `meetrevision/packages` release and check them against
   the release's published SHA-256 digests.
2. Replace the files in `src/additionals/packages/winsxs` and update `src/tool/winsxs_packages.json`.
3. `dart run melos run bundle:winsxs` (also run by CI) fails on any missing, altered or unpinned cab.
4. Test on the VM before releasing; CBS removals are not reversible.

## Syncing with upstream Revision Tool

`debloat-tool/` was imported with `git subtree add` **without `--squash`**, so upstream history is part
of this repo and `git subtree pull` merges only new upstream commits on top of the fork's changes. Keep
it that way: never squash a pull, and never re-add the folder.

One-time setup:

```
git remote add revision-tool https://github.com/meetrevision/revision-tool.git
```

Each sync (clean working tree, from the repo root):

```
git fetch revision-tool
git subtree pull --prefix=debloat-tool revision-tool main
```

If Git reports modifications you didn't make, it is line endings (the tree mixes CRLF- and LF-stored
files and `core.autocrlf=true` re-normalizes them); prefix the command with `git -c core.autocrlf=false`.
To take a single upstream fix instead: `git cherry-pick -X subtree=debloat-tool <commit>`.

### Resolving conflicts

Upstream edits to the files the fork deliberately changed will conflict. Keep the fork's side:

| Upstream touches | Keep |
|---|---|
| `WinRegistryService.isSupported` / `isAmePlaybook` (ReviOS gate) | The WinDebloat marker + playbook `UniqueId` check |
| `features/winsxs` download path (`api_cab_datasource.dart`, `release_*model.dart`, `WinPackageService.download`) | Bundled-only cabs; re-delete files that come back as modify/delete conflicts |
| `.github/` | Keep deleted; port useful build-step changes by hand to the `build-tool` job in the root `.github/workflows/main.yml` |
| i18n strings, links, `inno-setup.iss`, `windows/runner/*` | Fork names/links/AppId; rebrand any new strings that say Revision/ReviOS |
| `tool_update_service.dart`, `network_endpoints.dart` | `sirmaestro/playbook` releases, asset picked by name |
| `tool/bundle_winsxs.dart` | The offline pin verifier |

### After every sync

1. `grep -rn -i "meetrevision\|revi\.cc\|ReviOS" debloat-tool/src/lib` should only hit attribution
   (`ProjectLinks.upstream`) and the `Revision-ReviOS-*` CBS package names.
2. A new `WinPackageType` upstream needs its cab mirrored and pinned (below), or it fails with
   "No bundled package found". Upstream cab updates are never picked up automatically.
3. Run the CI build, then a VM apply; grep AME's `Output.txt` for `exit code: 55` (gate rejected).

## Building

CI builds the tool in the `build-tool` job of the repo's [`.github/workflows/main.yml`](../.github/workflows/main.yml)
and bundles the installer into the `.apbx`. Locally (Flutter stable, Rust, gcc, Inno Setup), from `src/`:

```
dart run melos run frb            # Rust bridge (when rust/src/api changes)
dart run melos run compile:c
dart run melos run bundle:winsxs  # verify pinned cabs
dart run melos run codegen
dart run melos run build:cli      # -> ../wdtool.exe
dart run melos run bundle:appx
flutter build windows
iscc ../inno-setup.iss            # -> ../WinDebloatTool-Setup.exe
```

## License

WinDebloat Tool is a modified version of Revision Tool, copyright MeetRevision, and is licensed under
the [GNU General Public License v3.0](LICENSE).

The tool also contains:
* [Fluent System Icons](https://github.com/microsoft/fluentui-system-icons) by Microsoft - MIT
