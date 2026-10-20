# WinDebloat → Playbook port: Security (catalog/sec.psd1 + heavy.psd1)

Scope: `catalog/sec.psd1` (13 tweaks) and `catalog/heavy.psd1` (4 Script/revitool-mapped tweaks).
Output task file: `src/Configuration/Tasks/registry/security/windebloat-security.yml`.

Deconfliction searched across `src/Configuration/Tasks/**` (and `src/` for scripts) for each path+value.

## Ported

New registry/powershell actions added to `windebloat-security.yml` (absent from the playbook):

| win id | action(s) | notes |
|---|---|---|
| `sec.smart-app-control-off` | `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState` = `0` | Absent in src. One-way (OS limitation), reboot. SAC is also turned off by the disable-defender CBS package, but that is gated behind the radio and not present as a src registry value, so the standalone key is ported. |
| `sec.workplace-join-prompts-off` | `BlockAADWorkplaceJoin` = `1` under HKLM + HKCU `...\Policies\Microsoft\Windows\WorkplaceJoin` | HKCU mirrored to `HKU\.DEFAULT`. |
| `sec.ps-execution-policy` | `ExecutionPolicy` = `RemoteSigned` (REG_SZ) under HKCU + HKLM `...\PowerShell\1\ShellIds\Microsoft.PowerShell` | HKCU mirrored to `HKU\.DEFAULT`. Only `-ExecutionPolicy Bypass` command-line flags exist in src (not the registry policy), so not a duplicate. |
| `sec.refresh-root-certs` | `!powerShell` certutil `-generateSSTFromWU` + Import-Certificate into LocalMachine\Root and \AuthRoot | Script-type; extension doc says port cert refresh as a small `!cmd`/`!powerShell` if not covered. Not covered. Engine idempotence marker (`HKLM\SOFTWARE\WinDebloat\State\RootCertsRefreshed`) dropped — one-shot at apply. Does NOT set `DisableRootAutoUpdate` (Store needs it; `revert.yml` even deletes it). |

## Skipped (exact duplicate)

All actions already present in the playbook with identical path/value/type:

| win id | where in playbook |
|---|---|
| `sec.defender-ui-hide` | `registry/security/security.yml` — `HideSystray`=1, `SecurityHealth` Run delete, `AccountProtection_MicrosoftAccount_Disconnected`=0 (playbook also adds the `HKU\.DEFAULT` mirror — superset). |
| `sec.smartscreen-off` | `registry/security/security.yml` — `ConfigureAppInstallControlEnabled`=1, `ConfigureAppInstallControl`='Anywhere', `EnableWebContentEvaluation`=0, Edge `PhishingFilter\EnabledV9`=0. All four identical. |
| `sec.autoplay-off` | `registry/explorer/explorer.yml` — `NoDriveTypeAutoRun`=255 (HKCU+HKLM) and `AutoplayHandlers\DisableAutoplay`=1 (also in `win-settings.yml`). All three identical. |
| `sec.show-file-extensions` | `registry/explorer/view.yml` — `HideFileExt`=0 (with `HKU\.DEFAULT` mirror). |
| `sec.linked-connections` | `registry/misc/fixes.yml` — `EnableLinkedConnections`=1. |
| `sec.bitlocker-auto-encrypt-off` | `registry/security/bitlocker.yml` — `PreventDeviceEncryption`=1. |

## CONFLICTS — second pass

None. Every in-scope action was either an exact duplicate, absent (ported), or covered by an existing non-registry mechanism. No path exists in the playbook with a divergent value.

## Maps to existing mechanism (no port)

| win id | maps to |
|---|---|
| `sec.vbs-off` | `revitool tweaks security vbs disable` in `registry/security/vbs.yml` (bcdedit + DeviceGuard policy/control keys are what revitool performs). Registry keys NOT ported. |
| `sec.hvci-off` | Same `revitool tweaks security vbs disable` — it "automatically disables Memory Integrity (HVCI) as well" (per vbs.yml comment). `HypervisorEnforcedCodeIntegrity` keys NOT ported. |
| `sec.password-never-expires` | `Executables/FINALIZE.cmd:68` already runs `net accounts /maxpwage:unlimited` (identical command). Exec not ported. |
| `sec.defender-disable` (heavy) | `revitool tweaks security defender disable` + the `disable-defender` radio. Per references-learnings, the policy-only disable must NOT be ported as a Defender disabler (cannot stop PPL processes; platform self-heals). Script not ported. |
| `edge.remove-edge` (heavy) | `Executables/EDGE.ps1` + `packages/app-win32.yml`, option `remove-edge`. Script not ported. |
| `edge.remove-onedrive` (heavy) | `Executables/ONED.cmd` + `revitool winpackage --install onedrive-removal`, option `remove-onedrive`. Script not ported. |
| `start.remove-pinned-items` (heavy) | `Executables/LayoutModification.{xml,json}` + `STARTMENU.cmd`, option `remove-pinned-items-startmenu`. Script (incl. `ConfigureStartPins`) not ported. |
