# archive/ – retired notes, kept for retrieval

`AGENTS.md` and `docs/references-learnings.md` used to hold everything; they now hold the current rules only. What they
used to say is here, **verbatim** (split by section, nothing edited, checked lossless on 2026-11-09), and git history keeps
every later change. Look here for the *why* behind a rule, an old measurement, a rejected idea or a bug fixed once.

**Trust order:** live docs (`AGENTS.md`, `docs/`) and the code > these notes. When an archived note disagrees with a live
doc, the live doc wins. Known superseded claims in the archive:
- "A full run costs about 22 minutes", "measured times (VirtualBox, 2026-10-23)": that was VirtualBox; an uncached Hyper-V
  run is about 14 min (`docs/vmtest-phase-breakdown.md`).
- `-KeepLayers (2)`: now 1 (newest L1 and newest L2 under it), with orphan-checkpoint pruning.
- Everything about VirtualBox (`VBoxManage`, `vboxuser`, guestcontrol, NEM hangs, "kept for reference" harness): VirtualBox
  and its VM were removed on 2026-11-09; the harness is Hyper-V only.
- "snapshot L1 after the first-boot commit saves about 80 s": measured about 25 s per L1 restore.
- `assoc.ps1` "first `Add-Type`" stall: fixed (Reflection.Emit), so the 32 s no longer occurs.

Search with `rg -n "<term>" archive/` or `git log -S"<term>" -- AGENTS.md`.

## AGENTS_2026-11-09/ (the old AGENTS.md, 416 lines)

| File | What is in it | Still current? |
|---|---|---|
| `00_intro-and-golden-rules.md` | what the fork is, golden rules 1-5 in full | **yes**, condensed in `AGENTS.md` |
| `01_pipeline-layout-action-types.md` | `main.yml` pipeline, `src/` layout table, YAML tags and keys | condensed in `AGENTS.md`; the tables here are fuller |
| `02_options-wdtool-ci-conventions.md` | the full option list, every `wdtool` subcommand, CI/release, conventions | options: read `playbook.conf`; subcommands: `wdtool --help` |
| `03_vm-testing-overview-and-run-steps.md` | the harness's nine run steps, flags, the old VirtualBox note | **moved to `docs/vmtest.md`** (condensed) |
| `04_checkpoint-layers.md` | layer table, keys, flags, measured times | `docs/vmtest.md`; the VirtualBox timings are history |
| `05_download-cache.md` | `-CacheDownloads`, winget seeding, GitHub 504 fallback | `docs/vmtest.md` (condensed) |
| `06_hangs-watchdog-copy-transport.md` | hang detection, watchdog semantics, copy transport and GSI | `docs/vmtest.md` (condensed) |
| `07_outputs-and-live-end-state-check.md` | exit codes, output files, the live end-state check and `endstate-known.json` rules | `docs/vmtest.md` (condensed) |
| `08_phase-timing-and-measured-stalls.md` | where a run spends its time, measured stalls | superseded by `docs/vmtest-phase-breakdown.md` |
| `09_build-base-vm-reading-results-gotchas.md` | build-package, base VM requirements, reading results, harness gotchas | `docs/vmtest.md` (condensed) |
| `10_more-context-and-upstream-sync.md` | doc index, upstream playbook sync procedure | the sync text is live in `AGENTS.md` |

## references-learnings_2026-11-09/ (the old docs/references-learnings.md, 236 lines)

The bracketed numbers in the live `docs/references-learnings.md` are these file numbers.

| File | What is in it | Still current? |
|---|---|---|
| `00_header.md` | title and intro | no |
| `01_why-component-removal-needs-cbs.md` | why only CBS removal reaches zero Defender processes (PPL, the signing wall, AME's bypass) | yes |
| `02_cbs-removal-packages.md` | what each `meetrevision/packages` removal does and which components it deliberately keeps | yes |
| `03_appx-removal-and-defender-facts.md` | `0x80070032` appx removal, Tamper Protection | yes |
| `04_vm-testing-notes.md` | AME logs, end-state validation, the VirtualBox hang history, `shutdown /full`, Teams return, GitHub 504 | yes, except the VirtualBox parts (history) |
| `05_default-apps-windows-11.md` | `UserChoiceLatest`, SFTA, toasts, what Windows seeds, how to verify | yes (the `AssocQueryString` note is from VirtualBox guestcontrol) |
| `06_monorepo-and-git-gotchas.md` | nested `.git`, line endings, subtree renormalize, VS Code locks | yes |
| `07_playbook-regressions-and-reverted-tweaks.md` | the wdtool gate, the list of tweaks reverted because they broke something | yes |

## vmtest-virtualbox/

`vmtest-virtualbox.ps1`: the earlier VirtualBox harness (guestcontrol driven), superseded by `tools/vmtest.ps1`. Nothing runs
it. VirtualBox is gone from the host, so it cannot run any more; kept only as reference for the approach.
