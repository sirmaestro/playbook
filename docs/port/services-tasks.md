# WinDebloat port — Services & Scheduled Tasks

Scope: `catalog/svc.psd1` (Service-type) and `catalog/task.psd1` (ScheduledTask-type) → native playbook YAML.

Output files:
- `src/Configuration/Tasks/windebloat-services.yml` — `!service` actions (TrustedInstaller).
- `src/Configuration/Tasks/windebloat-scheduled-tasks.yml` — `!powerShell` `Disable-ScheduledTask` actions.

Deconfliction references in the existing playbook:
- `src/Configuration/Tasks/services.yml` — service startup changes.
- `src/Executables/FINALIZE.cmd` (lines 33-49) — `schtasks /change /disable` block.
- `src/Configuration/Tasks/final.yml` line 46 — `Get-ScheduledTask -TaskPath "\Microsoft\Office\*" | Disable-ScheduledTask`.
- `src/Configuration/Tasks/services.yml` line 67 — UCPD velocity task disable.

---

## Ported

### Services (`windebloat-services.yml`)

| win id | Service | Start type | Reason absent from playbook |
|---|---|---|---|
| `svc.remote-registry` | `RemoteRegistry` | Disabled (4) | Not set in services.yml. Breaks remote regedit/admin tools. |
| `svc.ai-fabric` | `WSAIFabricSvc` | Disabled (4) | Not set in services.yml. Complements AI removal group; N/A when absent. |

### Scheduled tasks (`windebloat-scheduled-tasks.yml`)

Ported only the task members that the base playbook does NOT already disable.

| win id | Task path | Task name |
|---|---|---|
| `task.application-experience` | `\Microsoft\Windows\Application Experience\` | `ProgramDataUpdater` |
| `task.application-experience` | `\Microsoft\Windows\Application Experience\` | `MareBackup` |
| `task.application-experience` | `\Microsoft\Windows\Application Experience\` | `StartupAppTask` |
| `task.application-experience` | `\Microsoft\Windows\Application Experience\` | `PcaPatchDbTask` |
| `task.disk-diagnostic` | `\Microsoft\Windows\DiskDiagnostic\` | `Microsoft-Windows-DiskDiagnosticResolver` |
| `task.diagnosis-scheduled` | `\Microsoft\Windows\Diagnosis\` | `Scheduled` |
| `task.feedback-siuf` | `\Microsoft\Windows\Feedback\Siuf\` | `DmClient` |
| `task.feedback-siuf` | `\Microsoft\Windows\Feedback\Siuf\` | `DmClientOnScenarioDownload` |
| `task.sqm` | `\Microsoft\Windows\PI\` | `Sqm-Tasks` |
| `task.windows-ai-recall` | `\Microsoft\Windows\WindowsAI\` | `RecallConfiguration` |
| `task.windows-ai-recall` | `\Microsoft\Windows\WindowsAI\` | `RecallPipeline` |

11 task-disable actions across 6 catalog entries (`task.application-experience` and `task.disk-diagnostic` are partial ports — see Skipped for their already-covered members).

---

## Skipped (exact duplicate)

### Services — already set identically in `services.yml`

| win id | Service(s) | Start type | Playbook location |
|---|---|---|---|
| `svc.reviOS-service-set` | bundle (dam, GpuEnergyDrv, NetBT, Telemetry, diagnosticshub, WerSvc, DiagTrack, wisvc, PcaSvc, WdiServiceHost/SystemHost, tcpipreg, edgeupdate, Wecsvc, UCPD, condrv + UCPD velocity task) | as below | services.yml — every member matches; catalog note says the individual svc.* items are idempotent copies of this RV bundle. |
| `svc.diagtrack` | `DiagTrack` | Disabled (4) | services.yml L41. (Catalog `StopNow=$true` is a runtime stop only; start type identical.) |
| `svc.diagnosticshub` | `diagnosticshub.standardcollector.service` | Disabled (4) | services.yml L35 |
| `svc.wersvc` | `WerSvc` | Disabled (4) | services.yml L38 |
| `svc.pcasvc` | `PcaSvc` | Disabled (4) | services.yml L47 |
| `svc.wisvc` | `wisvc` | Disabled (4) | services.yml L44 |
| `svc.wdi-hosts` | `WdiServiceHost`, `WdiSystemHost` | Disabled (4) | services.yml L50, L53 |
| `svc.dam` | `dam` | Disabled (4) | services.yml L16 |
| `svc.gpuenergydrv` | `GpuEnergyDrv` | Disabled (4) | services.yml L22 |
| `svc.netbt` | `NetBT` | Disabled (4) | services.yml L25 |
| `svc.intel-telemetry` | `Telemetry` | Disabled (4) | services.yml L28 |
| `svc.tcpipreg-wecsvc` | `tcpipreg`, `Wecsvc` | Disabled (4) | services.yml L56, L63 |
| `svc.ucpd` | `UCPD` + UCPD velocity task | Disabled (4) + task disabled | services.yml L66-67 |
| `svc.edgeupdate-manual` | `edgeupdate` | Manual (3) | services.yml L60 |
| `svc.condrv-auto` | `condrv` | Automatic (2) | services.yml L71 (#184 fix — matches) |

### Scheduled tasks — already disabled by the base playbook

| win id | Task(s) | Playbook location |
|---|---|---|
| `task.application-experience` (partial) | `AitAgent`, `Microsoft Compatibility Appraiser` | FINALIZE.cmd L39, L41 |
| `task.ceip` | `Consolidator`, `UsbCeip`, `KernelCeipTask` | FINALIZE.cmd L42-44 |
| `task.wer-queue` | `QueueReporting` | FINALIZE.cmd L38 |
| `task.disk-diagnostic` (partial) | `Microsoft-Windows-DiskDiagnosticDataCollector` | FINALIZE.cmd L40 |
| `task.power-efficiency` | `AnalyzeSystem` | FINALIZE.cmd L34 |
| `task.memory-diagnostic` | `ProcessMemoryDiagnosticEvents`, `RunFullMemoryDiagnostic` | FINALIZE.cmd L35-36 |
| `task.office` | `\Microsoft\Office\*` (all) | final.yml L46 (identical wildcard idiom) |
| `task.ucpd-velocity` | `\Microsoft\Windows\AppxDeploymentClient\ UCPD velocity` | services.yml L67 |

---

## CONFLICTS — second pass

None.

Every overlapping service matches the playbook's start type exactly, and every overlapping scheduled task is disabled by the playbook (same end state), so there were no divergent values to escalate. The playbook's commented-out services (Beep, GraphicsPerfSvc, bam, Ndu) have no counterpart in `svc.psd1`, and the service-grouping / `SvcHostSplitThresholdInKB` XboxGipSvc caveat is handled by `revitool` in final.yml and is not touched by any service in scope.

---

## Out of scope (not Service / ScheduledTask type — noted, not ported)

These entries live in the two in-scope catalog files but carry non-Service/non-ScheduledTask actions, so they fall outside this pass:

- `svc.msi-safeboot` — `Registry` actions (SafeBoot\{Minimal,Network}\MSIServer = `Service`). Already covered by `src/Configuration/Tasks/registry/misc/msi-installer-in-safe-mode.yml` (identical values). Belongs to the registry port.
- `task.etw-diagnostic-channels` — `Exec` actions (`wevtutil sl … /e:false` on SleepStudy / Kernel-Processor-Power / UserModePowerService diagnostic channels), not a scheduled task. Note: FINALIZE.cmd L51-53 runs `wevtutil sl … /q:false` on the same channels but does NOT set `/e:false`, so the catalog's channel *disable* is only partially covered — flag for the Exec/wevtutil port pass.
