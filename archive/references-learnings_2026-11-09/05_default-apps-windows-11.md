## Default apps on Windows 11 (26300)

- The classic `UserChoice` hash (SetUserFTA/PS-SFTA algorithm, salt `User Choice set via Windows User
  Experience {D18B6DD5-6124-4341-9318-804003BAFA0B}`) still validates (157/157 on a 26100 host,
  146/146 on the 26300 VM), **but 26300 ignores it**: every type also has `UserChoiceLatest` (Hash +
  `ProgId\ProgId`), which wins; deleted, Windows recreates it with the previous choice. `assoc.ps1` only
  sets class defaults; `INSTALL-APPS.ps1` writes `UserChoiceLatest` with the vendored `SFTA\SFTA.ps1`.
- The `UserChoiceLatest` hash *is* reproducible: `SFTA.ps1` 2.0.1 from github.com/ComoEstaisAmigos/PS-SFTA
  (MIT; salt read from `windows.storage.dll`, `HKLM\SOFTWARE\Microsoft\SQMClient` MachineId, the
  `UserChoiceLatest\ProgId` key's write time) reproduced 157/157 Windows-written hashes on 26300.9457
  (`SystemProtectedUserData\<SID>\AnyoneRead\AppDefaults\HashVersion=1`), with and without Windows'
  own encoder. A valid hash alone still shows the picker on types where any known handler is "new":
  every ProgId from `HKCR\<type>\OpenWithProgids`, the user's `FileExts\<type>\OpenWithProgids` and
  each `RegisteredApplications` app's `Capabilities\FileAssociations` needs a
  `HKCU\...\ApplicationAssociationToasts` value `<ProgId>_<type>`=0 (Photo Viewer declares `.gif` as
  `PhotoViewer.FileAssoc.Gif`, in neither list). With both, 93 types across 8 apps opened directly,
  also after a reboot (VM, 2026-10-23). The picker then lists the written app as "Default app".
- Opening a sample with `explorer.exe <file>` browses into archives as folders; test those with
  `cmd /c start "" <file>`. `Invoke-Item` blocks while the OpenWith picker is up.
- `UserChoice` carries a Deny ACE on Set Value: delete it with `RegDeleteKey` (DELETE right), not .NET
  `DeleteSubKeyTree`, which silently does nothing; `RegDeleteKey` fails with 5 while subkeys exist.
- Settings deep links: `ms-settings:defaultapps?registeredAppMachine=<name>` / `registeredAppUser=<name>`
  (HKLM / HKCU `RegisteredApplications` value name) open that app's page. A packaged app's `AppX<hash>`
  entry opens only the main Default apps page, and `registeredAUMID=` shows just its URL protocol; use
  the app's own non-AppX entry (ImageGlass MSIX writes `HKCU ... ImageGlass` after `--ig-set-default-viewer`).
- Which types "just work": Windows seeds `UserChoiceLatest` at the user's first sign-in for the types
  its inbox apps own (Photos `AppX43hnx...`, Media Player `AppXqj98...`, Raw `AppX9rkaq...`, Edge
  `MSEdgeHTM` for .htm/.svg/.xml, CompressedFolder/CABFolder). Those keep winning after the playbook
  removes the app (the ProgIds no longer exist), so the type shows the picker until set in Settings.
  Types with no seeded entry (LibreOffice, Subtitle Edit, most 7-Zip types, .flv/.jxl/.psd) fall back
  to the class default `assoc.ps1` sets and open directly. Verified on the 26300 VM, 2026-10-23.
- The `DefaultAssociationsConfiguration` policy (HKLM\SOFTWARE\Policies\Microsoft\Windows\System,
  XML of `<Association Identifier ProgId ApplicationName>`) changed nothing on 26300 Pro for the
  existing user after a reboot: the seeded entries stayed (tested for 40 mpv/ImageGlass types).
- UCPD is already `Disabled` after the playbook, so it is not what blocks `.pdf`/`http`.
- Check defaults by opening sample files in the user's session (Limited scheduled task) and watching
  what launches (`OpenWith` = the picker), not by reading the registry or via `AssocQueryString` from a
  remote-session process such as a guestcontrol/PowerShell Direct one (it reported no association even
  when one existed; observed on VirtualBox guestcontrol).

