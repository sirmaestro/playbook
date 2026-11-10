## More context

- [docs/windebloat-extension.md](docs/windebloat-extension.md) — how WinDebloat maps into playbook
  format: the catalog→YAML conversion table, where each category lands, overlap/deconfliction policy.
- [docs/vmtest-phase-breakdown.md](docs/vmtest-phase-breakdown.md) — what each harness phase and apply step
  does and why it takes its time (hv11/hv16/hv17 numbers), measured stalls, download behaviour and why the
  harness does not cache them, options considered and rejected. Read before trying to speed up a run.
- [docs/references-learnings.md](docs/references-learnings.md) — distilled gotchas from the upstream
  reference projects (the CBS/signing boundary, Defender/PPL facts, the CBS-package decode, revitool
  verbs, VM testing and log-reading notes, monorepo/git line-ending pitfalls, and the catalog of
  "this tweak was reverted because it broke X" lessons).
- [debloat-tool/README.md](debloat-tool/README.md) — WinDebloat Tool: what the fork changed vs Revision
  Tool, re-pinning the CBS cabs, building, and **pulling upstream changes** (`git subtree pull`, no squash).
- **Upstream playbook** (`meetrevision/playbook`, shares history with this repo): remote `upstream-playbook`;
  `git fetch upstream-playbook`, then `git merge upstream-playbook/main`. Last synced 2026-11-09 (bc9f08a).
  With a dirty working tree, do both syncs (this and the tool's) in a `git worktree add ../playbook-sync -b
  upstream-sync`, then `git merge --ff-only upstream-sync` in the main tree and remove the worktree.
