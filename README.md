# Claude Desktop — Windows & macOS RTL & extensions patch

In-place patcher that adds RTL (Hebrew/Arabic) support and a few quality-of-life
extensions to the **official Claude Desktop** — no repackaged installer, no
rebuild. The same JavaScript extensions run on both platforms; each OS has its
own patcher.

```powershell
# Windows (run elevated, from an unzipped release or this repo root):
powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1
```

```bash
# macOS (from an unpacked release or this repo root):
./patch-claude-macos.sh
```

> **macOS support is a first-draft port** — see the [macOS](#macos) section.

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

## How it works (Windows)

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

## macOS

macOS uses the same JS extensions but a different patcher
(`patch-claude-macos.sh`), because the app ships as `/Applications/Claude.app`
rather than an MSIX package. The mechanics differ:

| | Windows (MSIX) | macOS (.app) |
|---|---|---|
| file access | `takeown` + `icacls` | `sudo` (no MSIX lock) |
| asar integrity | byte-replace hash in `claude.exe` | update `ElectronAsarIntegrity` in `Info.plist` |
| code signing | self-signed cert + Root store | `codesign --force --deep --sign -` (ad-hoc) + clear quarantine |
| auto-re-patch | Scheduled Task | launchd LaunchAgent |

```bash
./patch-claude-macos.sh                  # install (prompts for prerequisites)
./patch-claude-macos.sh --yes            # unattended
./patch-claude-macos.sh --no-auto-update # skip the auto-re-patch agent
./patch-claude-macos.sh --restore        # revert to the original app
```

Requirements: `/Applications/Claude.app`, Node.js 22+ (offered via Homebrew if
missing), and your admin password (sudo writes inside `/Applications`).

**Gatekeeper caveat:** editing the bundle invalidates Apple's signature, so the
patcher re-signs ad-hoc and clears the quarantine flag. If a future macOS / app
build enforces hardened-runtime *library validation*, ad-hoc re-signing may not
be enough and the app could refuse to launch — in that case restore with
`--restore`. This path is **not yet verified on a real Mac**; please report what
happens.

## Repository layout

```
patch-claude-windows.ps1     Windows patcher (Install / Restore / auto-update)
package-windows.ps1          builds the Windows ZIP under dist\
patch-claude-macos.sh        macOS patcher (install / --restore / auto-update)
package-macos.sh             builds the macOS tar.gz under dist/
src/
  win-entry.js / win-wrapper.js   Windows entry + web-contents hook
  mac-entry.js / mac-wrapper.js   macOS entry + web-contents hook
  rtl-support.js             RTL CSS/JS (shared, origin: claude-desktop-linux)
  translate-support.js       translate-to-Hebrew (main-process; shared)
  multi-instance-support.js  floating "new window" button (shared)
```

## Building a release archive

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\package-windows.ps1 -Version 1.0.0
# -> dist\claude-desktop-windows-rtl-v1.0.0.zip
```

```bash
# macOS
./package-macos.sh --version 1.0.0
# -> dist/claude-desktop-macos-rtl-v1.0.0.tar.gz
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
