### Checkpoint layers (`-Layers`): fast iteration

A full run costs about 22 minutes. Most of that is the apply (about 8 min) and the app installs (about 11 min
for base + media-office; mpv's GitHub download and Firefox are the slowest). With `-Layers`, the
harness caches finished stages as offline Hyper-V checkpoints (Standard type, always taken with the VM
Off) and reuses them, like image layers:

| Layer | Checkpoint | Holds | Cache key (sha256) |
|---|---|---|---|
| L1 | `vmtest-L1-<key>` | the applied playbook, shut down before its first post-apply boot | base checkpoint id, AME CLI, options, every package file **except** `INSTALL-APPS.cmd/.ps1`, `Apps/*` and `SFTA/*` (the installer's own files) |
| L2 | `vmtest-L2-<key>` | L1 plus the `-AppsGroups` installed | L1 key, the groups, the installer's own files (`INSTALL-APPS.cmd/.ps1`, `Apps/*`, `SFTA/*`); expires after `-AppsLayerMaxAgeHours` (24) |

- **Building.** L1 replaces the post-apply reboot with `shutdown /s` (a full shutdown; this
  `shutdown.exe` has no `/full`), an offline checkpoint, and a boot. So L1 costs nothing extra, and every restore replays the same first boot. L2 is taken after a
  clean app run. Layers are built only from clean results (no failed or unconfirmed tweaks, no failed
  apps, no `-RevertScript`).
- **Using.** A hit restores the deepest usable layer and copies the current installer and `Apps` lists in
  (guest-agent `SyncApps`, mirroring `start.yml`). The apply verdict recorded when the layer was built
  goes into `summary.json` (`apply.cachedFrom`), and only the remaining steps run. With an L2 hit,
  INSTALL-APPS reruns against the installed apps (about 1 min). That exercises default apps and the
  summary, not the install code.
- **Which edit costs what.** The installer's own files key L2, so editing `INSTALL-APPS.ps1`, an app list or
  `SFTA/*` misses L2 and reruns the installs on L1 (about 5 min), with no flag needed. Anything else in the
  package (the playbook YAML, other Executables) keys L1 and costs a full re-apply. `assoc.ps1` stays in the
  L1 key although the installer uses it too: the playbook's FILEASSOC.cmd runs it during the apply.
- **Flags.** `-FreshApps` ignores L2 (now only needed to repeat an install with nothing changed). `-RebuildLayers` ignores
  all hits. `-ClearLayers` deletes every `vmtest-L*` checkpoint. `-KeepLayers` (1) is kept per kind (L1s,
  and L2s per L1); after each saved layer, older layers and any `vmtest-L*` checkpoint without a record
  are pruned (the base checkpoint is never touched). Removing a checkpoint starts a background disk merge; the
  harness waits for it to finish (the VM cannot be restored or started meanwhile).
- **Records.** `out/vmtest/layers/<name>.json` holds the key inputs, creation time, the run that built
  the layer, and the cached verdict. A checkpoint without a record is never used.

Measured times (VirtualBox, 2026-10-23, base + media-office, with `-CacheDownloads`; Hyper-V timings are
the same within a few percent for the apply, 441 s against 432 s):

| Change | Layer used | Time |
|---|---|---|
| Playbook YAML or Executables | none | ~22 min (the run also builds both layers) |
| `INSTALL-APPS.ps1` install logic, or `Apps/*.json` (or `-FreshApps`) | L1 | ~6 min: L1 boot 1–2.5 min, apps 3.4 min (11–14 min uncached) |
| `INSTALL-APPS.ps1` default-apps or summary code | L2 | ~1.7 min end to end, build included |

The first boot from L1 can take a while: the Store updates inbox apps right after boot, and the
guest is briefly slow to answer. The harness retries guest hashing for that reason.

Layers are for iterating. The definition of done still needs an **uncached** run (no `-Layers`, or
`-RebuildLayers`): rebuilt package, applied from the clean checkpoint, error count compared. Restoring a
layer doesn't re-test what happens before it, such as delivery by `start.yml` or Store updates that
depend on uptime. The VM has 16 GB RAM, so layers are offline checkpoints (disk only, a few GB each);
never take live ones.

