**Where a full run spends its time** (full tables: [docs/vmtest-phase-breakdown.md](docs/vmtest-phase-breakdown.md);
hv11, uncached-apply, about 14 min): apply 459 s, apps install 158 s,
restore 39 s, apps cache seed 34 s, first-boot check 32 s, L1 shutdown 26 s, input copy 21 s, reboot to
desktop 20 s, prepare 18 s, everything else under 15 s. During the apply the guest averages about 4% CPU
(peak 16%) and writes about 23 MB/s: it is waiting, not computing, so more vCPUs will not help. The long
silent stretches are playbook steps (Explorer configuration, ngen, appx removal, finalizing); shortening
them changes playbook behavior and needs the maintainer's yes. Harness-side options not taken: snapshot L1
after the first-boot commit (measured saving about 25 s per L1-restore run, but it changes what a layer means), a
running-state base checkpoint (saves about 30 s on uncached runs, but a memory restore brings back a stale
guest clock and network state, and the uncached run is the one that has to be faithful).

**Measured playbook stalls** (apply-only VM runs with a 0.6 s process sampler; a scratch package, not the
repo). Boot, app-download and VCLibs-download phases vary by 30 to 100 s between identical runs, so compare
steps, not run totals.
- `assoc.ps1` (FILEASSOC.cmd): 32 s, every run, at the first `Add-Type`. `csc.exe` sits blocked in synchronous
  IPC calls (wait reason EventPairLow) with 0% CPU, no disk and no pending connection. Fixed: the P/Invoke is
  defined with Reflection.Emit, so `csc.exe` never runs (32 s to 0.2 s; the same `UserChoice` keys are gone
  and the same class defaults are set). The cause of the IPC stall is not known; it does not happen in an
  interactive session after the apply (`Add-Type` takes 0.1 s there).
- `!appx clearCache` for `*Client.CBS*` (final.yml): 48 s, every run: about 25 s of silence inside the
  engine, then about 22 s in AME's closed-source `ame-assassin.exe -ClearCache`. The other three clearCache
  actions take 0 s, so it is a first-call cost. No playbook-side lever found.
- Explorer config, 40 s, every run (VirtualBox runs too): the first `HKCU\...\Feeds` write in `taskbar.yml`
  ends in `UnauthorizedAccessException` (UCPD) after about 40 s and then lands through a fallback. **Do not
  replace it with `reg add`: that also gets "Access is denied" and the values are then simply not set.**
- Not causes (tested): the background `cleanmgr` from CLEANER.ps1 (moving the step to the end changed
  nothing), the six separate `Get-WindowsCapability` passes (merging them saved 0 to 1 s).

