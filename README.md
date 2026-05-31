# Claude Desktop — Windows RTL & extensions patch

In-place PowerShell patcher that adds RTL (Hebrew/Arabic) support and a few
quality-of-life extensions to the **official Windows Claude Desktop** (the
Microsoft Store / MSIX build) — no repackaged installer, no rebuild.

```powershell
# Run elevated from an unzipped release (or this repo root):
powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1
```

## Features

- **RTL support** — automatic right-to-left layout for Hebrew/Arabic, a floating
  LTR/RTL toggle, and an on/off item in the right-click menu (no page reload).
- **Translate to Hebrew** — one-shot page translation from the right-click menu.
- **New window** — opens another window in the same process, already logged in
  (shares the session — no second login).
- **Refresh page** and a **version label** (click to copy) in the right-click menu.

## Requirements

- Windows 10/11 with the **official Claude Desktop** installed (MSIX/Store build).
- Administrator rights (the patcher self-elevates via UAC).
- **Node.js ≥ 22.12** — the patcher checks for it and, if missing/too old, offers
  to install Node LTS automatically via `winget` (with your confirmation).

## Install

1. Download the latest `claude-desktop-windows-rtl-vX.Y.Z.zip` from Releases (or
   clone this repo) and unzip it.
2. Right-click **`Run-Patch.cmd`** → **Run as administrator** (or run the
   PowerShell line above).
3. The patcher runs a **prerequisite check**, prints what's present/missing, and
   asks before installing anything (Node) or patching. Approve the prompts;
   Claude closes, gets patched, and relaunches.

For unattended install (auto-approve every prompt), add `-Yes`:

```powershell
powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1 -Yes
```

Re-run after every Claude Desktop auto-update (the update replaces the patch).

## Uninstall / restore the original

```powershell
powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1 -Action Restore
```

Restore also disables auto-re-patch so it won't come back on the next update.

## How it works

The MSIX build locks the app files and enforces ASAR integrity, so the patcher:

1. Locates the install via `Get-AppxPackage *Claude*` and takes ownership
   (`takeown` + `icacls`).
2. Backs up `app.asar`, `claude.exe`, `cowork-svc.exe` (→ `*.bak`), restoring
   from backup before every re-patch so it is idempotent.
3. Extracts `app.asar`, injects the five JS modules in `src/`, repoints
   `package.json`'s `main` at `win-entry.js`, and repacks.
4. Byte-replaces the asar SHA-256 hash embedded in `claude.exe` so Electron's
   `EnableEmbeddedAsarIntegrityValidation` fuse still passes (falls back to
   flipping the fuse off if the hash can't be located).
5. Re-signs `claude.exe` and `cowork-svc.exe` with a self-signed certificate
   added to the machine Root store (editing the binaries voids their original
   Authenticode signature).

Technique adapted from
[`shraga100/claude-desktop-rtl-patch`](https://github.com/shraga100/claude-desktop-rtl-patch).

## Repository layout

```
patch-claude-windows.ps1     the in-place patcher (Install / Restore)
package-windows.ps1          builds the distributable ZIP under dist\
src/
  win-entry.js               package.json "main"; loads the wrapper then the app
  win-wrapper.js             web-contents hook: injection + right-click menu
  rtl-support.js             RTL CSS/JS (shared with the Linux project)
  translate-support.js       translate-to-Hebrew (main-process)
  multi-instance-support.js  floating "new window" button
```

## Building a release ZIP

```powershell
powershell -ExecutionPolicy Bypass -File .\package-windows.ps1 -Version 1.0.0
# -> dist\claude-desktop-windows-rtl-v1.0.0.zip
```

## Caveats

- **Endpoint protection (EDR):** re-signing the binaries and adding a Root cert
  can trip aggressive EDR. If Claude won't launch after patching, run `-Action
  Restore` and add an EDR exclusion for the Claude install folder, then retry.
- Unofficial modification of Claude Desktop; not affiliated with or endorsed by
  Anthropic. Use at your own risk.

## Credits

RTL and extension modules originate from the
[claude-desktop-debian/linux](https://github.com/aaddrick/claude-desktop-debian)
project. MSIX hash/cert technique from
[shraga100/claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch).
