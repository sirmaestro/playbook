**Download cache (`-CacheDownloads`).** This avoids re-downloading app installers in the guest, whose
network is much slower than the host's. It is a testing aid only; the files and checks stay the same.
- *GitHub release assets* (mpv; App Installer itself when INSTALL-APPS updates winget) are kept in
  `tools/cache/downloads/`. They are copied in, and INSTALL-APPS's `-DownloadCache` uses one only when
  its SHA-256 matches the release's published digest. New downloads are copied back out.
  `github.com/.../releases/download/...` has returned 504 for every asset (2026-11-08, GitHub's
  australiaeast edge) while `api.github.com` kept working, so INSTALL-APPS (`Get-GitHubFile`) and the
  harness (`Save-VmtDownload`) fall back to the API asset endpoint (`Accept: application/octet-stream`)
  when the direct download fails. winget's own downloads have no such fallback.
- *winget packages*: for each one in the selected groups, the host's `winget show` gives the version,
  URL and SHA-256 of the default installer. The host downloads it into
  `tools/cache/downloads/winget/<Id>.<Version>/`, and the harness copies it to the guest's
  `%TEMP%\WinGet\<Id>.<Version>\<sha256>`. winget 1.29 reuses a file there when the hash matches
  ("Existing installer file hash matches"). On any mismatch (new version, different installer) it
  just downloads. Dependencies such as LibreOffice's VC++ runtime are not seeded. Verified: all 8
  winget installers for base + media-office were reused (`REUSED` in winget's DiagOutputDir logs).
  Seeding is skipped on an L2 hit, where the apps are already installed.
- The cache grows with each new version. Delete `tools/cache/downloads/` to reset it.

