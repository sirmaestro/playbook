# CLAUDE.md

Agent context for this repo lives in **[AGENTS.md](AGENTS.md)** — read it first.

Two rules that override default behavior here:
1. **Extend the playbook in playbook (AME YAML) format.** WinDebloat tweaks become native tasks; do
   not vendor or run the WinDebloat PowerShell engine. See [docs/windebloat-extension.md](docs/windebloat-extension.md).
2. **Confirm before removing or disabling any existing playbook functionality.** Adding is fine;
   subtracting needs the maintainer's yes.

Distilled gotchas (CBS/signing boundary, Defender/PPL, revitool, VM testing, known regressions):
[docs/references-learnings.md](docs/references-learnings.md).

## Editing Conventions section
## File editing on Windows
- Do NOT use `sed -i` or shell heredocs to patch files. Use the Edit/Write tools. Shell patches have mangled backslash escapes and stripped CRLF line endings.
- Preserve existing line endings. playbook.conf and other AME/playbook files must stay CRLF. After editing them, check with `file <path>` or a byte-level check, not a visual read.

## Testing / Definition of Done section
## Verification honesty
- Never call a change 'done' if it has only passed a dry run or a local self-test. State clearly what was verified (dry run, Windows only, VM run) and what was not (real install, elevated paths, macOS/Linux, re-applied package).
- For playbook and debloat changes, the definition of done is: package rebuilt, applied on the VirtualBox VM, and the error count compared to the previous run.

## Testing / Definition of Done section
## VM testing (VirtualBox)
- Drive the guest with `VBoxManage guestcontrol run`. Do not use keyboard injection. It once sent a command into Edge.
- The host server is not reachable from the guest over NAT. Use `guestcontrol copyto` to move files, and always confirm the copy replaced the old file.
- The snapshot must already have UAC disabled and any helper scheduled tasks (e.g. dbgjob) present. Check both before starting.
- In PowerShell helpers, avoid aliases that collide with built-ins and do not rely on `$Matches` across scopes.
- The playbook must have its own identity, not ReviOS. Otherwise AME flags it as malicious.

## Git section
## Git identity & privacy
- Commit author is 'sirmaestro' with the GitHub noreply email. Never write the user's real name or email into commits, .mailmap, or docs.
- Nested repos (forks, vendored tools) must be imported with `git subtree add`. Do not copy a folder that still contains its own `.git`.
