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

