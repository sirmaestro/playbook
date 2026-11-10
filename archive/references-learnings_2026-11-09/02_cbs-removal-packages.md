## What the CBS removal packages actually do (`meetrevision/packages`)

`revitool winpackage --install <name>` installs a signed CBS cab. Mechanism: for each
`target_component` the package registers an *update at version `38655.38527.65535.65535`* (max), so
CBS supersedes Microsoft's real component with an empty one — the component's files/registration drop
out while the servicing manifest stays consistent (durable; survives Windows Update — unlike the
deprecated raw-`systemPackage` file delete that caused issue #49). Payload escape hatches: export-only
**PE stubs** for DLLs that can't be removed without breaking boot (telemetry: `utcapi`/`utcutil`/
`sqmapi`), **registry** values, or **file** replace/delete.

Packages and notable **deliberately-kept** components (don't "fix" these — they're intentional):

- **telemetry-removal** — stubs `utcapi.dll`+`utcutil.dll` (system won't boot without them) and
  `sqmapi.dll` (statically imported by recovery/SpeechUX).
- **defender-removal** — removes all `Windows-Defender-*`, `Security-Octagon-*` (SGRM), WebThreatDefense,
  SenseClient (EDR), SmartScreen/AppRep; sets SmartScreen/SAC/PUA policy off. **Keeps** AMSI ("Causes
  File system error UAC") and Security Center (disabled via `wscsvc`, not stripped).
- **ai-removal** — Recall (`UserExperience-AIX/CoreAI`), Copilot, `AIFabric-CBS-1.6`, Agentic platform;
  + registry (`DisableAIDataAnalysis`, `TurnOffWindowsCopilot`, `LetAppsAccessGenerativeAI=2`, …).
- **onedrive-removal** — supersedes `OneDrive-Setup*` so it never re-provisions.
- **xbox-removal** — GameBar/BroadcastDVR/XboxLive/GameChat/etc. **Keeps** `Gaming-Configuration` +
  `GameMode` (new Xbox Full Screen Experience, Game Mode).
- **systemPackages-removal** (= `system-components-removal`) — ~130 components (Flash, CEIP/SQM,
  appraiser/CompatTelRunner, ErrorReporting, Feedback, Flighting, RetailDemo, screensavers, QuickAssist,
  SecureAssessment "Take a Test", etc.). **Keeps** (with reasons): DeviceCensus (removing it breaks WU
  driver downloads), ErrorReportingFaults/Kernel (breaks some games), Flighting-FeatureConfiguration
  (winver shows 2009), Data-Pdf (breaks Passmark), GameExplorer (older games), the whole Edge block.

Full per-component decode lives with the WinDebloat inventory (`windows11-debloat/docs/inventory/playbook.md`,
"CBS removal packages" section) if you have that repo checked out.

