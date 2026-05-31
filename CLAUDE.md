# Claude Desktop — Windows RTL & extensions patch — dev notes

In-place PowerShell patcher that injects RTL + extensions into the **official
Windows Claude Desktop** (Microsoft Store / MSIX build). Read this before making
non-trivial changes.

## Commit & attribution policy

- **Every commit is authored AND committed by `Shalom Levi <shaloml@gmail.com>`.**
  This repo's local git config is already set to that identity — do not change it.
- **Do NOT add `Co-Authored-By: Claude` (or any AI) trailers** to commits, and do
  not add AI attribution to PR/issue bodies. Commits in this repo read as the
  owner's work, full stop.
- Keep commit subjects in the imperative mood; one logical change per commit.
- Only commit or push when explicitly asked.

## Project overview

The target is the MSIX/Store Claude Desktop at
`C:\Program Files\WindowsApps\Claude_<ver>_x64__pzs8sxrjxfjjc\app\`. That build
adds two locks an ordinary asar patch can't beat:

1. **File ACLs** — owned by `TrustedInstaller`/`SYSTEM`; even elevated, writing
   `app.asar` is Access Denied until `takeown` + `icacls`.
2. **ASAR integrity** — `claude.exe` has the Electron fuse
   `EnableEmbeddedAsarIntegrityValidation=Enabled` + `OnlyLoadAppFromAsar`, and
   the asar header carries a per-file SHA-256. A modified asar is rejected unless
   the hash embedded in `claude.exe` is updated (or the fuse flipped off).

`patch-claude-windows.ps1` defeats both: takeown → asar extract/inject/repack →
byte-replace the asar hash inside `claude.exe` → re-sign `claude.exe` and
`cowork-svc.exe` with a self-signed cert added to the machine Root store (editing
the binaries voids their Authenticode signature). Technique adapted from
[`shraga100/claude-desktop-rtl-patch`](https://github.com/shraga100/claude-desktop-rtl-patch).

## Architecture

```
patch-claude-windows.ps1   the patcher (Install / Restore), self-elevates via UAC
package-windows.ps1        builds dist\claude-windows-patch.zip
src\
  win-entry.js             package.json "main"; loads the wrapper then the app
  win-wrapper.js           web-contents hook: injection + right-click menu + new window
  rtl-support.js           RTL CSS/JS (origin: claude-desktop-debian/linux)
  translate-support.js     translate-to-Hebrew (main-process, uses Node https)
  multi-instance-support.js  floating "+window" button + console trigger
```

- The wrapper attaches ONE `app.on('web-contents-created')` listener. Every
  window/webview gets: RTL CSS+JS, the multi-window button, and the context menu
  (RTL toggle, refresh, translate, new window, version label).
- **New window is in-process** (`new BrowserWindow` reusing the focused window's
  session) — NOT a second `claude.exe`. Spawning a second process fails on MSIX:
  the app's own single-instance gate ("Not main instance, returning early") exits
  before showing a window, and a separate `--user-data-dir` is a blank profile
  whose OAuth callback can't complete. Same-process = already logged in.

## Source-file resolution (don't break this)

`Resolve-SourceFiles` in the patcher searches three layouts per file so the same
script runs from anywhere:

1. `.\src\<file>` — this standalone repo.
2. `.\<file>` — a flat bundle (the ZIP from `package-windows.ps1`).
3. `..\scripts\<file>` — the original claude-desktop-linux source tree.

If you move files, keep all three candidates working.

## Code style

- **PowerShell:** tabs for indentation; `[[ ]]`-style explicit checks; avoid
  `if` as an expression (PS 5.1 doesn't support it — use `if/else` statements).
  Target Windows PowerShell 5.1 — no ternary, no `??`, no `?.`. Parse-check with
  `[System.Management.Automation.Language.Parser]::ParseFile(...)` before commit.
- **JavaScript:** tabs; CommonJS (`require`/`module.exports`); guard every
  injection with try/catch so an extension failure never blocks app launch.
  Run `node --check` on every JS file before commit.
- **Don't edit the shared `*-support.js` modules to fix a Windows-only issue.**
  They originate upstream (Linux). Override from `win-wrapper.js` instead (e.g.
  the button-offset CSS), so the modules stay portable.

## Idempotency & safety

- The patcher backs up `app.asar` / `claude.exe` / `cowork-svc.exe` to `*.bak`
  on first run and **restores from `*.bak` before every re-patch**, so re-running
  is safe and always patches clean originals. `-Action Restore` reverts.
- Claude Desktop auto-updates wipe the patch — just re-run Install.
- **Never kill processes by name alone.** Claude Code (the CLI) also runs
  `claude.exe`; `Stop-ClaudeServices` must scope kills to the install dir path,
  or it will terminate the session driving the patch.

## Known constraints

- **EDR / endpoint protection** may flag the Root-cert add or re-lock
  `cowork-svc.exe`. If Claude won't launch post-patch: `-Action Restore`, add an
  EDR exclusion for the Claude install folder, retry.
- **Auth token** lives in `%APPDATA%\Claude\config.json` under
  `oauth:tokenCache` — an Electron safeStorage `v10` blob encrypted with the
  os_crypt key in `Local State` (DPAPI-wrapped to the user). Relevant only if
  multi-process instances are ever revisited (the current in-process approach
  sidesteps it).

## Testing

```powershell
# parse-check both scripts + node --check all JS, then build the ZIP:
powershell -ExecutionPolicy Bypass -File .\package-windows.ps1

# apply to the live install (elevates), then verify each menu item by hand:
powershell -ExecutionPolicy Bypass -File .\patch-claude-windows.ps1
```
