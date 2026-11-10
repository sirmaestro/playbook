Exit codes: `0` = pass, `1` = any failed/unconfirmed action, non-success engine result or failed/hung
revert, `2` = harness or VM error (including misaligned log pairing).

Output lands in `out/vmtest/<timestamp>/` (git-ignored):

| File | Contents |
|---|---|
| `summary.json` | The verdict. Besides `result`, `tweaks`, `apps`, `endState`, `hangs`: `phases` (the timeline, with the VM's CPU and disk use per phase), `provenance` (SHA-256 of every harness script, git HEAD plus a `sourceFingerprint` of all uncommitted changes, host and VM configuration, the harness parameters), `liveState` (below) |
| `tweaks.json` | Per-action detail |
| `harness.log` | The harness's own log, ending with the timeline table |
| `logs/` | Everything pulled from the guest |
| `config/` | The exact Configuration that was tested |
| `endstate-live-<stage>.json` | Every difference found by the live end-state check at `first-boot` and `final` |
| `endstate-expected.json` | What the playbook's registry, service and file actions should leave behind |
| `watchdog.log`, `watchdog-samples.csv`, `watchdog-stuck.json` | The watchdog's log, the VM resource samples (every 10 s: state, CPU %, disk read/write MB/s), and, only if it stopped the run, its diagnosis |
| `diag/servicing-diag.zip` | Only when the first-boot commit check fails: `CBS.log`, `dism.log`, package states, Setup events |

**Live end-state check.** `liveState` compares the guest with what the playbook's `!registryValue`,
`!registryKey`, `!service` and `!file` actions should have left (`amelog.py expected`, last writer wins,
a write under a deleted key recreates it; `endstate-check.ps1` does the read-only comparison in the
guest). It runs twice: `first-boot` (right after the first-boot commit check: the playbook's own result)
and `final` (after the apps). A difference that is not listed in `tools/vmtest/endstate-known.json`
fails the run (exit 1). The known list has two statuses: `explained` (cause verified) and `open` (a real
difference whose cause is not established; it stays visible in every run and in `summary.json`). **Do not
add an entry without checking the cause and writing it down.** It does not cover `!run`/`!powerShell`
actions, scheduled tasks, appx removal or file associations set by SFTA, so a clean check is not proof
that the whole playbook worked.

