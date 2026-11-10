# VM test run: where the time goes

Measured on the Hyper-V test VM (`windowstest-hv`, 4 vCPU, 16 GB, Windows 11 26300), 2026-11-09. Read this before
trying to speed up a run, and before adding a cache.

Sources, all under `out/vmtest/` (git-ignored, so they will not be in a fresh clone):

| Run | What it was | Total |
|---|---|---|
| `hv11-full-gaps` | Uncached full run (apply, first boot, apps, both layers saved) | 843 s |
| `hv16-e2e-verify` | Same, after the harness copy changes and the `assoc.ps1` fix | 886 s |
| `hv17-l1-iteration` | App-only iteration: restore L1, install apps, rebuild L2 (`-FreshApps`) | 277 s |

**Run totals are noisy.** Boot, winget and download phases swing by 30 to 100 s between identical runs (hv16's L1 boot
took 46 s against 12 s in hv11, with nothing changed there). Compare steps, not totals, and repeat a run before
believing a difference of under a minute.

## Harness phases

Names are the `phases` entries in `summary.json` and the "Timeline" table at the end of `harness.log`.

| Phase | What it does | hv11 | hv16 | hv17 | Why it takes this long |
|---|---|---|---|---|---|
| `build` | `tools/build-package.ps1`: zip `src\*` plus the tool installer | 1 | 1 | 1 | Local zip |
| `restore-boot` | Power off, restore the checkpoint, start, wait for PowerShell Direct and (base or L2) the desktop | 39 | 39 | 11 | A cold Windows boot: the checkpoints are Off-state, so there is no memory to restore. An L1 restore only waits for PowerShell Direct (the first boot is handled below) |
| `copy-inputs` | Guest agent, AME CLI, playbook zip, options into the guest, SHA256 checked | 21 | 5 | 1 | Was about 5 s of PowerShell Direct session set-up per file; now one batch over `Copy-VMFile` and one guest hash call |
| `prepare` | Guest agent unzips CLI and playbook, checks Defender, finds the interactive user | 18 | 10 | - | Unzip, a fixed 3 s sleep after Defender is re-disabled, and a PowerShell start |
| `apply` | The AME engine runs about 1,170 actions | 459 | 427 | - | See the next section |
| `apply-logs` | Pull the logs, summarize | 1 | 1 | - | |
| `l1-shutdown`, `l1-snapshot` | Clean guest shutdown, offline checkpoint | 31 | 29 | - | The shutdown after a heavy debloat takes about 26 s; the checkpoint itself 3 to 5 s |
| `l1-boot` / `first-boot-check` / `reboot-to-desktop` | First boot with auto-logon off, wait until the Revision packages commit, auto-logon back on, reboot to a desktop | 64 | 120 | 51 | The commit wait is CBS settling and is the check that matters; the rest is two Windows boots. The boots are the noisy part |
| `apps-seed` | Copy the winget and download caches into the guest (880 MB) | 34 | 36 | 36 | Disk copy at about 25 MB/s through the guest |
| `apps-run` | `INSTALL-APPS.ps1` for `base,media-office` | 158 | 201 | 158 | Nine installers and the default-apps step; mostly winget and the installers themselves |
| `live-state` | Live end-state check against the playbook | 2 | 2 | 2 | |
| `collect`, `l2-shutdown`, `l2-snapshot` | Pull logs, save L2 | 15 | 15 | 17 | |

An app-only iteration (hv17) is 277 s: the first-boot replay 51 s (18%), the cache seed 36 s (13%), the installs 158 s
(57%), rebuilding L2 16 s (6%). The installs are what is being tested, so they cannot be cut.

## Apply steps

The engine's `[Status]` lines name a step, and the log has no per-action timing, so these are the seconds from one
status change to the next. **A step's time includes any unlabelled work after it** (for example the capability
removals run under the "Removing Copilot providers" label). Output.txt times are guest-local, 12-hour (08:49 is 20:49).

| Step (status label) | What it does | runI* | iter6* | hv8 | hv11 | hv16 |
|---|---|---|---|---|---|---|
| Installing VCRedist | Download `vc_redist.x64.exe` from aka.ms (4 to 6 s), silent install | 26 | 10 | 9 | 13 | 13 |
| Installing WinDebloat Tool | Inno Setup installer (bundled in the package) | 25 | 10 | 14 | 13 | 14 |
| Optimizing PowerShell | `ngen.ps1`: native compile of about 19 .NET assemblies on 4 workers, plus the .NET NGEN scheduled tasks | 29 | 19 | 42 | 44 | 42 |
| Removing OneDrive | Kill processes, `ONED.cmd`, appx removal | 21 | 19 | 18 | 18 | 19 |
| Removing Teams | `wdtool appx --remove` for the Teams packages | 1 | 1 | 18 | 25 | 42 |
| Removing system packages, Defender, AI, OneDrive WinSxS, telemetry | `wdtool winpackage --install` of the bundled Revision CBS cabs (no network); the Defender step also runs `gpupdate` twice | 82 | 108 | 52 | 49 | 50 |
| Removing Appx Packages | `wdtool appx --remove` for about 60 packages | 19 | 24 | 22 | 24 | 21 |
| Restoring VCLibs | `wdtool msstore-apps`: downloads four VCLibs packages from the Microsoft Store (about 5 s when the network is fine), installs them | 12 | 13 | 120 | 30 | 15 |
| Removing Copilot providers | Appx removal, then six `Get-WindowsCapability -Online \| Remove-WindowsCapability` passes (about 5 s each) | 44 | 65 | 29 | 28 | 30 |
| Configuring scheduled tasks | Disables about 60 tasks | 17 | 18 | 14 | 13 | 18 |
| Configuring Explorer | About 450 registry actions, of which one stalls about 40 s (see below) | 50 | 35 | 47 | 44 | 46 |
| Configuring WinDebloat tweaks | About 1,275 log lines; `certutil -generateSSTFromWU` pulls the root-certificate list from Windows Update (13 to 25 s) and the import takes another 5 to 10 s | 60 | 37 | 13 | 25 | 14 |
| Finalizing process | `FINALIZE.cmd`, file associations, theme, four appx cache clears, `gpupdate`, tool patches | 88 | 119 | 94 | 94 | 63 |

\* VirtualBox runs, kept for comparison.

Privacy, Security, System and Updates registry steps take 0 to 1 s each: hundreds of registry writes are cheap.

## Resource profile

During the apply the guest averages about 4% CPU (peak 16%) and writes about 23 MB/s. It is waiting, not computing, so
more vCPUs will not help. The host CPU (12 cores) and the SATA SSD are not the limit either.

## Measured stalls

Found with an apply-only run of a scratch package (never the repo) that started a process and I/O sampler (every
0.6 s, with the engine's child processes, their command lines and thread wait reasons) at the top of `final.yml`.
Three silent stretches repeat to the second in every run:

| Where | Time | What the trace showed | Status |
|---|---|---|---|
| `assoc.ps1` (FILEASSOC.cmd), first `Add-Type` | 32 s | `csc.exe` sat in synchronous IPC waits (wait reason EventPairLow) with 0% CPU, no disk and no pending connection. It does not happen in an interactive session after the apply (`Add-Type` takes 0.1 s there). Cause unknown | **Fixed**: the P/Invoke is defined with Reflection.Emit, so `csc.exe` never runs. 32 s became 0.2 s, with the same `UserChoice` keys gone and the same class defaults |
| `!appx clearCache` for `*Client.CBS*` (`final.yml`) | 48 s | About 25 s of silence inside the engine, then about 22 s in AME's closed-source `ame-assassin.exe -ClearCache`. The other three clearCache actions take 0 s, so it is a first-call cost | No playbook-side lever found |
| First `HKCU\...\Feeds` write in `taskbar.yml` | 40 s | The engine's write ends in `UnauthorizedAccessException` (UCPD) after about 40 s and the value then lands through a fallback. Also seen in the VirtualBox runs | **Do not replace it with `reg add`**: that gets "Access is denied" and the values are then simply not set (checked in the guest) |

Tested and ruled out: the background `cleanmgr` started by `CLEANER.ps1` (moving that step to the end changed
nothing), and the six capability passes (merging them into one saved 0 to 1 s: the time is the removals, not the
enumeration).

## Downloads during the apply

| Download | By | Typical | Worst seen | Cacheable by the harness? |
|---|---|---|---|---|
| `vc_redist.x64.exe` | The engine's `!download` (`overwrite: true`) | 4 to 6 s | - | No. It re-downloads whatever is on disk |
| Four VCLibs packages | `wdtool msstore-apps`, Microsoft Store delivery | 5 s | 100 s | No. Store content URLs are signed and short-lived, so a file cache cannot replay them |
| Root-certificate list | `certutil -generateSSTFromWU`, Windows Update | 13 to 25 s | 50 s | No. Windows Update protocol, not a file fetch |
| Revision CBS cabs | The log says "Downloading", but the fork bundles them | 0 s | - | Nothing is downloaded |
| App installers, winget packages | `INSTALL-APPS.ps1` | minutes | - | **Yes, and already cached** (`-CacheDownloads`, the pre-seeded winget cache) |

Caching the three network items would need a TLS-intercepting proxy on the host with its root certificate trusted
in the base checkpoint, and the playbook edits the root store itself. The gain is about 25 to 40 s of an 800 s run
(most of what the proxy would remove is run-to-run variance), and it would hide what the end-to-end run exists to
catch: a Store API change, a rotated installer URL, or a changed Windows Update response. The checkpoint layers
already act as the cache for app work, since L1 holds the result of every one of these downloads. If variance is the
concern, report the three download times as their own lines rather than caching them.

## Options considered and not taken

| Option | Saves | Why not |
|---|---|---|
| A settled layer (snapshot after the first-boot commit and desktop) | about 25 s per L1 iteration (of the 51 s replay) | A second shutdown and checkpoint, more disk, a changed layer meaning, and the replay re-verifies the servicing commit on every restore |
| A running-state base checkpoint | about 30 s on uncached runs | A memory restore brings back a stale guest clock and network state, and the uncached run is the one that must be faithful |
| More vCPUs | nothing | The apply is wait-bound (see Resource profile) |
| Merging the six capability passes | 0 to 1 s | Measured: no gain |
| Moving `CLEANER.ps1` to the end | nothing | Measured: no gain |
