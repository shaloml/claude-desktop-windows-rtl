# Claude Desktop — Windows, macOS & Linux RTL & extensions patch

In-place patcher that adds RTL (Hebrew/Arabic) support and a few quality-of-life
extensions to the **official Claude Desktop** — no repackaged installer, no
rebuild. The same JavaScript extensions run on all three platforms; each OS has
its own patcher.

> Looking for **RTL in the Claude Code VS Code extension** (the sidebar chat)?
> That moved to its own project, developed and released separately:
> **[vscode-claude-rtl](https://github.com/shaloml/vscode-claude-rtl)**.

```powershell
# Windows (run elevated, from an unzipped release or this repo root):
powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1
```

```bash
# macOS (from an unpacked release or this repo root):
./patch-claude-macos.sh
```

```bash
# Linux (run as your normal user, from an unpacked release or this repo root):
./patch-claude-linux.sh
```

> **macOS is verified** (on macOS 26 / Apple Silicon). One quirk: the first
> launch after patching logs you out once — see the [macOS](#macos) section.
> **Linux** is the simplest target (no integrity hash, no code-signing) — see
> the [Linux](#linux) section.

## Related projects — Hebrew RTL for Claude everywhere

The same Hebrew/Arabic RTL treatment is available on every Claude surface:

- **Claude Desktop** (Windows / macOS / Linux) — *this repo*.
- **Claude Code in VS Code** — [`vscode-claude-rtl`](https://github.com/shaloml/vscode-claude-rtl)
  (installable extension + standalone patchers).
- **Browser (Chrome / Edge)** — *Claude.ai RTL Transformer*, for claude.ai in the browser:
  - Source: [`shaloml/rtl-chatgpt`](https://github.com/shaloml/rtl-chatgpt)
  - [Chrome Web Store](https://chromewebstore.google.com/detail/claude-ai-rtl-transformer/pcnpnpaipomdildpaehlnmlbiiaagdid)
  - [Edge Add-ons](https://microsoftedge.microsoft.com/addons/detail/claude-ai-rtl-transformer/mcbkppnfkonepcpndghjbdlhipmmhipn)

## Features

- **RTL support** — a floating, draggable **AUTO / RTL / LTR** panel at the top
  (mode + position remembered). **AUTO** (default) sets each message paragraph's
  direction automatically (Hebrew → RTL; English & code → LTR; no flicker while
  streaming); **RTL** forces the whole window right-to-left (sidebar moves right),
  code stays LTR; **LTR** is the baseline. Inline per-block LTR↔RTL buttons remain
  on code / input / preview cards, plus a cycle item in the right-click menu.
- **Re-patch shortcut** — the first install drops a **"Re-apply Claude RTL"**
  shortcut on your Desktop; click it to re-apply after a Claude Desktop update
  (Windows / KDE & other Linux / macOS). The auto-update watcher still does this
  automatically too.
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

| | Windows (MSIX) | macOS (.app) | Linux (deb) |
|---|---|---|---|
| file access | `takeown` + `icacls` | `sudo` (no MSIX lock) | `sudo` (root-owned `/usr/lib`) |
| asar integrity | byte-replace hash in `claude.exe` | update `ElectronAsarIntegrity` in `Info.plist` | **none** — fuse is off |
| code signing | self-signed cert + Root store | `codesign --force --deep --sign -` (ad-hoc) + clear quarantine | **none** — binary unsigned |
| auto-re-patch | Scheduled Task | launchd LaunchAgent | systemd system timer |

```bash
./patch-claude-macos.sh                  # install (prompts for prerequisites)
./patch-claude-macos.sh --yes            # unattended
./patch-claude-macos.sh --no-auto-update # skip the auto-re-patch agent
./patch-claude-macos.sh --restore        # revert to the original app
```

Requirements: `/Applications/Claude.app`, Node.js 22+ (offered via Homebrew if
missing), and — only if the app is root-owned — your admin password (the patcher
re-runs under `sudo` to write inside `/Applications`; if you own the bundle, no
password is needed). Native modules (`*.node`, node-pty's `spawn-helper`) are
re-marked as unpacked during repack so the app still loads them.

**One-time re-login (expected):** editing the bundle invalidates Apple's
signature, so the patcher re-signs ad-hoc. That changes the app's identity, so
macOS no longer lets it read the `Claude Safe Storage` keychain key that
encrypts your saved session — the first launch after patching logs you out.
Sign in once more (click **Always Allow** if macOS prompts for the keychain);
it then stays logged in across normal restarts. You only re-login again if you
re-run the patcher.

**No silent auto-update:** the ad-hoc signature also makes Claude's built-in
updater reject its own downloads, so a patched Claude won't auto-update and wipe
the patch. To move to a newer Claude: `--restore`, update Claude normally, then
re-run the patcher.

**Translate to Hebrew** is best-effort on macOS — claude.ai re-renders and tends
to revert the one-shot translation, so it may not stick. RTL, the version label,
refresh, and new-window are the verified extensions.

**Gatekeeper caveat:** if a future macOS / app build enforces hardened-runtime
*library validation*, ad-hoc re-signing may not be enough and the app could
refuse to launch — in that case restore with `--restore` and report it.

## Linux

Linux uses the same JS extensions but its own patcher (`patch-claude-linux.sh`),
targeting a `claude-desktop-debian`-layout install (typically
`/usr/lib/claude-desktop`, with the asar at
`node_modules/electron/dist/resources/app.asar`). It's the **simplest** of the
three: the Linux Electron binary ships with the asar-integrity fuses **off** and
is **unsigned**, so there's no hash to patch and no re-signing — the patcher just
backs up `app.asar`, injects the five JS modules, repoints `main` at
`linux-entry.js`, and repacks.

```bash
./patch-claude-linux.sh                  # install (prompts for prerequisites)
./patch-claude-linux.sh --yes            # unattended
./patch-claude-linux.sh --no-auto-update # skip the auto-re-patch timer
./patch-claude-linux.sh --restore        # revert to the original app.asar
```

**Run it as your normal user, not under `sudo`.** The heavy lifting (`npx
@electron/asar` extract/pack) runs as you, so a per-user Node install (e.g. nvm)
stays on `PATH`; only the writes into the root-owned install dir elevate via
`sudo` (you'll be prompted once). Override the install location with
`CLAUDE_DESKTOP_DIR=/path/to/app`.

Requirements: a Linux Claude Desktop install, Node.js 22+, and `sudo` rights.
Native modules (`*.node`) are re-marked as unpacked during repack with
`--unpack '{**/*.node,**/spawn-helper}'` so the app still loads them.

**Stays patched across updates:** a Claude update replaces `app.asar` and wipes
the patch, so a **systemd system timer** (`claude-linux-rtl.timer`, on by
default; `--no-auto-update` to skip) re-applies it when the installed `app.asar`
changes (it compares SHA-256, so it's version-agnostic). `--restore` removes the
timer too.

**Two kinds of "new window" (right-click menu):** Claude Desktop is
one-window-per-profile, so no single new window can have *both* your shared Cowork
history *and* your MCP connectors. The menu offers both:

- **חלון חדש (היסטוריה משותפת)** — in-process, like Windows/macOS: already logged
  in and shares your Cowork history. MCP connectors are *not* available in it
  (the app only wires connectors into windows it manages itself). The floating
  **+חלון** button uses this mode.
- **חלון חדש (עם connectors)** — a separate instance (the launcher's
  `--new-window`): your connectors work, but its Cowork history starts blank
  (separate profile).

On `claude-desktop-debian` builds the patcher also fixes the launcher so opening
that connectors window no longer closes your existing window. The launcher's own
cleanup used to kill the primary's shared Cowork daemon when a second instance
started; the patch keeps a secondary instance from touching the primary's
resources. (These launcher scripts are root-owned and live outside the asar, so
the patch backs them up and re-applies via the auto-update watcher after a
Claude update.) **Translate to Hebrew** is best-effort here as well.

## Claude Code in VS Code (moved out)

RTL for the **Claude Code VS Code extension** (the sidebar chat) used to live
here. It has since grown its own focus and is now **developed and released
separately**, in its own repository:

➡️ **[github.com/shaloml/vscode-claude-rtl](https://github.com/shaloml/vscode-claude-rtl)**

That project offers a proper installable VS Code extension — with a floating,
draggable **AUTO / RTL / LTR** panel — plus standalone `install/*.{sh,ps1}`
patchers for using it without the extension, and ready-to-install `.vsix`
downloads under its Releases. This repository is now strictly the **Claude
Desktop** (Windows / macOS / Linux) patcher.

## Repository layout

```
patch-claude-windows.ps1     Windows patcher (Install / Restore / auto-update)
package-windows.ps1          builds the Windows ZIP under dist\
patch-claude-macos.sh        macOS patcher (install / --restore / auto-update)
package-macos.sh             builds the macOS tar.gz under dist/
patch-claude-linux.sh        Linux patcher (install / --restore / auto-update)
package-linux.sh             builds the Linux tar.gz under dist/
src/
  win-entry.js / win-wrapper.js     Windows entry + web-contents hook
  mac-entry.js / mac-wrapper.js     macOS entry + web-contents hook
  linux-entry.js / linux-wrapper.js Linux entry + web-contents hook
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

```bash
# Linux
./package-linux.sh --version 1.0.0
# -> dist/claude-desktop-linux-rtl-v1.0.0.tar.gz
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
