## Monorepo / git gotchas (`debloat-tool/`)

- **A folder with its own `.git` is silently skipped by `git add`** (or added as a bare gitlink). That is
  how a first push shipped a workflow building `debloat-tool/src` without the folder ("The directory name
  is invalid" on the runner). `debloat-tool/` is a `git subtree` import — never put a nested `.git` back.
- **Line endings:** the root `.gitattributes` (`* text=auto eol=crlf`) stores every text file LF and checks
  it out CRLF regardless of `core.autocrlf`, so the packaged `.apbx` always gets CRLF (AME needs it). Don't
  add per-file overrides or commit CRLF blobs. Upstream Revision Tool stores a CRLF/LF mix, so subtree pulls
  must renormalize: `git -c merge.renormalize=true subtree pull ...`, or every upstream-CRLF file conflicts.
- **VS Code locks open folders** on Windows (`mv`/`Move-Item` fail with "being used by another process").
  Work around it in a temp clone (`git -c core.autocrlf=false clone`), then `git fetch` the result back and
  `git update-ref` + `git reset` when the working-tree files already match.
- The tool (Flutter + Rust + Inno Setup) has no local toolchain on the maintainer's machine; the
  `build-tool` CI job is the first compile. Upstream sync procedure: `debloat-tool/README.md`.

