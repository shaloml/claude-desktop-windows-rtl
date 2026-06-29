# Claude Desktop — Windows, macOS & Linux RTL & extensions patch — dev notes

In-place patchers that inject RTL + extensions into the **official Claude
Desktop**: Windows (Microsoft Store / MSIX build) via PowerShell, macOS
(`/Applications/Claude.app`) via a bash script, and Linux
(`/usr/lib/claude-desktop`, claude-desktop-debian layout) via a bash script.
Read this before making non-trivial changes.

## Platforms

- **Windows:** `patch-claude-windows.ps1` + `src/win-entry.js` / `win-wrapper.js`.
  Verified working.
- **macOS:** `patch-claude-macos.sh` + `src/mac-entry.js` / `mac-wrapper.js`.
  Verified on macOS 26 (Apple Silicon). Differences from Windows: `sudo` instead
  of takeown/icacls (skipped when the user owns the bundle); asar integrity
  updated in `Info.plist` (`ElectronAsarIntegrity`) instead of byte-replacing a
  binary; `codesign --force --deep --sign -` (ad-hoc) + `xattr -dr
  com.apple.quarantine` instead of a self-signed cert; launchd LaunchAgent
  instead of a Scheduled Task. Two verified consequences of the ad-hoc re-sign:
  (1) the app loses access to the `Claude Safe Storage` keychain key, so the
  first launch after each patch logs the user out once (re-login then sticks
  across normal restarts); (2) Claude's Squirrel updater rejects its own
  downloads, so a patched app won't auto-update. `asar pack` MUST pass
  `--unpack "{*.node,spawn-helper}"` or the native modules get packed into the
  asar and the app crashes at startup.
- **Linux:** `patch-claude-linux.sh` + `src/linux-entry.js` / `linux-wrapper.js`.
  Core asar inject dry-run-verified against the installed claude-desktop-debian
  build (Ubuntu, v1.12603.1); full apply-and-click verification still pending on
  a vanilla build. By far the simplest target: the Electron binary ships with the
  asar-integrity fuses OFF (`EnableEmbeddedAsarIntegrityValidation` /
  `OnlyLoadAppFromAsar` both Disabled) and is unsigned, so there is NO hash to
  patch and NO re-signing — it's the macOS flow minus Phase 2 (integrity) and
  Phase 3 (codesign). App files under `/usr/lib/claude-desktop` are root-owned,
  so privileged writes go through per-operation `sudo` — run as your NORMAL user
  (not under sudo) so `npx`/Node stay on PATH; the heavy lifting (asar
  extract/pack) runs as you and only the writes into the install dir elevate.
  Two Linux-specific gotchas, both found the hard way: (1) `asar pack` MUST use
  `--unpack "{**/*.node,**/spawn-helper}"` — the natives are NESTED
  (`node_modules/.../*.node`), so a bare `*.node` (what the Win/mac globs use)
  matches nothing and silently packs them in, crashing startup; the upstream
  build packs with `**/*.node`. (2) `asar extract` reads the sibling
  `app.asar.unpacked/` dir, so ALWAYS extract from the real install path — never
  a lone copy of `app.asar` (extract then dies ENOENT on the natives, and the
  "Node.js vX" line printed is a crash banner, not info). Auto-re-patch is a
  systemd SYSTEM timer (`claude-linux-rtl.timer`, root, boot + every 3h) that
  re-applies from a stable copy when the installed `app.asar`'s SHA-256 differs
  from the recorded patched SHA — version-agnostic and needs no Node in the
  watcher (state is a sourceable `state.env`, not JSON). **"New window" — TWO
  flavors, because the app is one-window-per-profile.** `app.on('second-instance')`
  only focuses the existing window, and an externally-created `BrowserWindow` is
  "unknown" to the app's internal `<Window>` pool — so MCP connectors only wire
  into windows the app itself manages. There is no single window that has BOTH
  shared Cowork AND connectors; `linux-wrapper.js` exposes both as menu items: (1)
  IN-PROCESS `openNewWindow()` — a `new BrowserWindow` in this process sharing the
  session/user-data-dir → shared Cowork history, but no MCP connectors; (2)
  SEPARATE INSTANCE `multiInstance.openNewInstance()` — the launcher's
  `--new-window`, a separate `Claude-instance-N` profile the app fully manages →
  MCP connectors work, Cowork starts blank. The floating button uses #1. Both are
  debounced (~1.5s). The in-process button emits a PRIVATE trigger
  (`NEW_WINDOW_TRIGGER`), NOT the shared `multi-instance-support.js`
  `CONSOLE_TRIGGER`, so the host `frame-fix-wrapper`'s bridge doesn't ALSO spawn a
  separate process (that double-fire was the earlier "new window closes the other"
  bug). (Reusing the content view's `preload` via `getLastWebPreferences()` was
  tried to get MCP into the in-process window — it did NOT work; the app gates MCP
  on its own window management, not just the preload.) We do NOT defer to the host
  (an earlier deferral removed the RTL/button that only OUR wrapper reliably
  renders on this build). **Failure-safe + upgrade-safe install:** the patcher
  extracts the CURRENT live asar into a temp dir, injects, repacks, and writes the
  live asar exactly ONCE at the end — so a mid-run failure (npx hiccup, declined
  sudo, Ctrl-C) leaves the running app untouched, and re-patching the live (NOT a
  stale `.bak`) stays correct after a Claude update replaced the asar (the
  package.json rewrite is a no-op when `main` is already our entry). **Launcher
  fix (root-owned, outside the asar):** the connectors window (#2 above) is a
  secondary `--new-window` instance; the claude-desktop-debian launcher ran its
  cleanup functions for that secondary, killing the PRIMARY's shared
  cowork-vm-service daemon and closing the running window. `patch_launcher`
  text-patches `/usr/bin/claude-desktop` (guard the pre-launch cleanups on
  `new_instance==false`) and `launcher-common.sh` (short-circuit
  `cleanup_after_electron_exit` when `CLAUDE_SECONDARY_INSTANCE` is set) so a
  secondary never cleans up the primary's resources. It patches the LIVE files
  idempotently (marker-guarded), round-trips exactly on `--restore`, and is
  skipped on a vanilla build with no launcher. These files are NOT part of the
  asar and are wiped by `apt upgrade` — the watcher re-applies them on its next
  run (it re-runs the whole patcher).
- **Claude Code (VS Code extension):** `patch-claude-code-vscode.sh`
  (macOS + Linux, one cross-platform script — branches on `uname` for the state
  dir, `stat` flavor, and watcher) + `patch-claude-code-vscode.ps1` (Windows),
  both feeding the shared `src/vscode-rtl-inject.{js,css}` payloads. Verified on
  macOS; Linux auto-update path dry-run-verified. The Linux Claude Desktop
  release (`package-linux.sh`) bundles this patcher + its two payloads, so one
  tarball covers both the desktop app and the Claude Code sidebar. A different,
  far lighter target than Claude Desktop: the extension's sidebar is a plain
  webview
  (`<ext>/webview/index.js` + `index.css`) — no asar, no integrity hash, no
  code-signing, user-owned files. The patcher just appends the two payloads
  between sentinel comments and restores from `*.bak` before each re-patch (same
  idempotency model as the others). RTL here has **three modes**, chosen from a
  small floating, draggable panel pinned at the top of the webview (position +
  mode persisted in `localStorage`): **AUTO** (default), **RTL**, **LTR**. AUTO is
  the original behaviour — the JS computes each text block's direction from its
  first strong character and pins `dir="rtl"`/`"ltr"` **stickily** (locks per
  element, never re-evaluates). Do NOT use `dir="auto"` — the browser re-evaluates
  it live, so while a response streams the first strong char keeps changing and
  paragraphs oscillate left/right (eye-searing flicker). **RTL/LTR force one
  direction across the WHOLE webview** by tagging `<html data-claude-rtl-mode>`;
  the CSS drives direction from the root (covering chat, composer, tool rows,
  diffs), while `pre`/`code`/Monaco stay LTR because a direct rule on the element
  beats the inherited direction. This forced override is the escape hatch for the
  cases AUTO gets wrong (a mostly-Hebrew paragraph that *starts* with English or
  inline code, which AUTO would lock to LTR). Switching to a forced mode runs
  `clearOurMarks()` to strip the per-element `dir`/gutter attributes AUTO set (an
  element `dir` would otherwise beat the inherited root direction); switching back
  to AUTO re-sweeps. AUTO's first-strong heuristic is left unchanged on purpose —
  a "majority of strong chars" rule would reintroduce the streaming oscillation —
  the forced buttons are the fix instead. A launchd LaunchAgent (macOS) / systemd `--user` timer
  (Linux) / Scheduled Task (Windows) re-applies after the extension auto-updates
  into a fresh versioned folder; the watcher is on by default (pass
  `--no-auto-update` / `-NoAutoUpdate` to skip).
  After any (re)patch the webview must be reloaded once: VS Code "Developer:
  Reload Window".
- **Shared (all three):** `rtl-support.js`, `translate-support.js`,
  `multi-instance-support.js`, and the in-process "new window" approach. Fix a
  platform quirk in the platform `*-wrapper.js`, never in the shared modules.

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
package-windows.ps1        builds dist\claude-desktop-windows-rtl[-vX.Y.Z].zip
src\
  win-entry.js             package.json "main"; loads the wrapper then the app
  win-wrapper.js           web-contents hook: injection + right-click menu + new window
  rtl-support.js           RTL CSS/JS (origin: claude-desktop-debian/linux)
  translate-support.js     translate-to-Hebrew (main-process, uses Node https)
  multi-instance-support.js  floating "+window" button + console trigger
```

- **Preflight (`Invoke-Preflight`) runs first and is the only place that may
  install anything.** It checks Claude Desktop (MSIX) + Node ≥ MinNodeVersion,
  prints a present/missing report, and prompts before installing Node (winget
  `OpenJS.NodeJS.LTS`) or patching. `-Yes` auto-approves (and is forwarded across
  the UAC self-elevation). A missing Claude is fatal (can't auto-install it); a
  missing/old Node is offered. Node detection must survive UAC — see the
  PATH-forwarding note below and `Get-NodeCandidateDirs`.
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
- **Never kill processes by name alone.** Claude Code (the CLI) also runs
  `claude.exe`; `Stop-ClaudeServices` must scope kills to the install dir path,
  or it will terminate the session driving the patch.

## Auto-update (re-patch after Claude updates)

- Claude Desktop auto-updates install a fresh MSIX and wipe the patch. After a
  successful patch, `Install-Patch` records the patched version
  (`%ProgramData%\ClaudeWindowsRtl\state.json`), stashes a stable copy of the
  patcher + the 5 JS files under `...\app\`, and offers to enable a watcher.
- The watcher (`-Action EnableAutoUpdate` → Scheduled Task at logon + every 3h,
  RunLevel Highest) compares the installed Claude version to the patched version
  and, when they differ, runs `patch-claude-windows.ps1 -Action Install -Yes`
  from the stable copy. Logs to `...\watcher.log`.
- The watcher script is written to disk as plain `.ps1` (NOT `-EncodedCommand`)
  to avoid AV heuristics. It needs no network — everything runs from the local
  stable bundle.
- Explicit `-Action Restore` disables the watcher (a deliberate revert means
  "stop"); an internal rollback leaves it alone.
- `-EnableAutoUpdate` / `-Yes` skip the prompts (forwarded across UAC).

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
