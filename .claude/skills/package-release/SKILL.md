---
name: package-release
description: Build the distributable ZIP and optionally cut a GitHub release. Use when the user wants to package, bundle, ship, or release the Windows patch for other machines.
---

# Package & release

Produce the self-contained `claude-desktop-windows-rtl-vX.Y.Z.zip` that installs
on machines without a repo checkout (needs only Node.js + MSIX Claude Desktop on
the target).

## Build the ZIP

Always pass `-Version` so the bundle/zip names carry the version:
```powershell
powershell -ExecutionPolicy Bypass -File .\package-windows.ps1 -Version X.Y.Z
# -> dist\claude-desktop-windows-rtl-vX.Y.Z.zip
#    (flat bundle: patcher + 5 JS + INSTALL.txt + Run-Patch.cmd)
```

`package-windows.ps1` copies the patcher + the five `src/*.js` into a flat folder
(the layout `Resolve-SourceFiles` auto-detects), adds `INSTALL.txt` and the
`Run-Patch.cmd` UAC launcher, and zips it. `dist/` is gitignored — never commit it.

Sanity-check the ZIP before shipping:
```bash
unzip -l dist/claude-desktop-windows-rtl-vX.Y.Z.zip   # expect 8 entries
```

## Cut a GitHub release (only when asked)

Tag, then attach the versioned ZIP so users can download without cloning:
```bash
gh release create vX.Y.Z dist/claude-desktop-windows-rtl-vX.Y.Z.zip \
  --title "vX.Y.Z" --notes "<summary of changes>"
```
- Use semver; the tag and the `-Version` used to build the ZIP must match.
- Summarize what changed since the last tag.
- Confirm `gh auth status` first (install GitHub CLI if missing; `gh` may not be
  on PATH).

## Rules

- Bump nothing automatically — the user decides the version.
- Keep the release notes factual; no AI attribution (see `CLAUDE.md`).
- If the support modules changed, run `sync-upstream` considerations first so the
  bundled copies match intent.
