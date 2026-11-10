## Why component removal needs revitool/CBS (and a plain script can't do it)

Goal some users want: **no Defender processes at all**, not just "AV disabled". The boundary:

- **Registry/policy disable can never reach zero processes.** Setting the Defender policy keys
  (`DisableAntiSpyware`, `DisableRealtimeMonitoring`, …) makes Defender *inert*
  (`Get-MpComputerStatus` → `AntivirusEnabled:False`, `AMRunningMode:Not running`) but `MsMpEng`
  (`WinDefend`) and `MpDefenderCoreService` (`MDCoreSvc`) **still run**. After a reboot the platform
  **self-heals** `WinDefend`/`MDCoreSvc` `Start` back to `2` (a platform update re-arms them).
- **You cannot force the service `Start` values — even as TrustedInstaller.** `WinDefend`, `MDCoreSvc`,
  `WdFilter`, `WdBoot`, `WdNisDrv/Svc` reject the write ("Attempted to perform an unauthorized
  operation"): they run as **PPL (protected anti-malware)** and self-protect their own registry keys
  against everything, **independent of Tamper Protection**. (Only `Sense`/`webthreatdefsvc`/`wscsvc`
  are writable.) So "force Start=4" is a dead end for the core processes.
- **The only thing that removes the processes is removing the components — a signed CBS package.**
  That is exactly what `revitool winpackage --install …` / `revitool tweaks security defender disable`
  do. Use them. Do **not** try to hand-roll a CBS package install.

### The CBS signing wall (why we can't reproduce revitool's removal in a script)

`Add-WindowsPackage`/DISM require the package's signing cert to chain to a root on **Code Integrity's
internal allowlist** (e.g. thumbprint `8A334AA8052DD244A647306A76B8178FA215F344`, which CI trusts
internally and is *not* in the local Root store). Consequences, verified on the VM:

- Importing a self-signed cert into `LocalMachine\Root` is **not** enough → DISM returns
  `0x800b0110 CERT_E_WRONG_USAGE`.
- **AME's bypass** (`trusted-uninstaller-cli/…/Defender.cs`): disable UCPD, `Import-Certificate` the
  cab's signer to `Root`, **`Copy-Item` its registry blob into the allowlisted slot**
  `HKLM\…\SystemCertificates\ROOT\Certificates\8A334AA8…`, `DISM /Online /Add-Package /IgnoreCheck`,
  then delete the cert+slot. Fallback on failure: reboot to Safe Boot and apply there.
- **That bypass works only with AME's *own* cab**, whose leaf chains (via Authority Key Identifier) to
  the `8A334AA8` root. The public `meetrevision/packages` `Defender-Removal` cab is **self-signed**
  (issuer==subject, no AKI, thumbprint `183E66…`): CI builds its chain to *itself* (not allowlisted)
  and never consults the `8A334AA8` slot, so the slot trick does nothing → `CERT_E_WRONG_USAGE`
  regardless. Confirmed by two independent attempts.
- **Net:** a tool that won't ship-and-trust its own signing root cannot strip Defender components on
  stock Windows — this is Microsoft's CI allowlist working as designed. **This is the reason WinDebloat
  is being folded into the playbook** (which has `revitool` and runs in AME's trusted context) rather
  than shipped standalone.

