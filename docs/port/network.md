# WinDebloat port — Network

Source catalog: `windows11-debloat/catalog/net.psd1` (one tweak).
Target task file: `src/Configuration/Tasks/registry/system/windebloat-network.yml`.

Deconfliction method: grepped the entire `src/Configuration/Tasks` tree (and all of `src/`)
for `DisabledComponents`, `Tcpip6`, `Tcpip\Parameters`, `Teredo`, `DisableSmartNameResolution`,
`TcpAckFrequency` — no existing network registry tweak of this kind is present (the only
`Tcpip`-adjacent hit was an unrelated `revert.yml` RegisteredOrganisation delete).

## Ported

| win id | Registry | Value | Notes |
|---|---|---|---|
| `net.ipv4-preferred` | `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters` | `DisabledComponents` = REG_DWORD `32` | Prefer IPv4 over IPv6 without disabling IPv6 (Microsoft-advised alternative to a full disable). HKLM-only, so no HKCU/`HKU\.DEFAULT` mirroring applies. Absent from the playbook → ported. |

Mech ref: `docs/tweaks/group1.mech.md` → `net.ipv4-preferred`
(`DisabledComponents=32`; revert = delete/0; same Tcpip6 value as `net.teredo-disable` (1) and
`net.ipv6-disable` (255), last writer wins).

## Skipped (exact duplicate)

None.

## CONFLICTS — second pass

None.

### Notes on out-of-scope conflicts (not in net.psd1, for reference)

`net.psd1` contains only `net.ipv4-preferred`. The other `net.*` ids seen in the WinDebloat
selection docs — including `net.bbr2-congestion` (the references-learnings.md gotcha: BBR2 breaks
websockets, issue #27 — do not port) and `net.ipv6-disable` — live in other catalog files and are
outside this scope, so they are not evaluated here.
