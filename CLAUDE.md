# CLAUDE.md

Agent context for this repo lives in **[AGENTS.md](AGENTS.md)** — read it first.

Two rules that override default behavior here:
1. **Extend the playbook in playbook (AME YAML) format.** WinDebloat tweaks become native tasks; do
   not vendor or run the WinDebloat PowerShell engine. See [docs/windebloat-extension.md](docs/windebloat-extension.md).
2. **Confirm before removing or disabling any existing playbook functionality.** Adding is fine;
   subtracting needs the maintainer's yes.

Distilled gotchas (CBS/signing boundary, Defender/PPL, revitool, VM testing, known regressions):
[docs/references-learnings.md](docs/references-learnings.md).
