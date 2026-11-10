## Appx removal gotchas

Some packages are protected Windows components and return `0x80070032` on per-user `Remove-AppxPackage`
("part of Windows and cannot be uninstalled on a per-user basis"): e.g. `SecureAssessmentBrowser`
("Take a Test"), `MicrosoftEdgeDevToolsClient`. These are removed at the **component (CBS)** level by
`systemPackages-removal`, not per-user appx. Don't chase them with appx removal.

## Defender / Tamper Protection facts

- AME requires Tamper Protection **off** before Defender work (`playbook.conf` `DefenderToggled` /
  `NoAntivirus` requirements). Tamper Protection **cannot** be turned off by script — it's gated behind
  the Windows Security UI; AME/revision-tool open that UI and wait for the user.
- `Features\TamperProtection`: `1`/`5` = on, `4` = off. `TamperProtectionSource` varies.
- Even with Tamper off, Defender's PPL self-protection on its service keys stands (see above).

