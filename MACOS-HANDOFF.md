# macOS port — handoff for a fresh Claude Code session on the Mac

> **STATUS: VERIFIED on macOS 26 / Apple Silicon (v1.0.0).** The port works —
> patch applies, app launches, ASAR integrity passes, native modules load, RTL +
> multi-window buttons + movable new window all work. The unknowns below were
> resolved; this doc is kept as the record of how. Key outcomes:
> - **Risk #1 (integrity):** `Info.plist` `ElectronAsarIntegrity:Resources/app.asar:hash`
>   has exactly the assumed shape; PlistBuddy update works.
> - **Risk #2 (signing):** ad-hoc re-sign launches fine, but breaks `Claude Safe
>   Storage` keychain access → **one-time re-login per patch** (then sticks), and
>   blocks Claude's Squirrel auto-update.
> - **Bug fixed:** `asar pack` needs `--unpack "{*.node,spawn-helper}"` or native
>   modules get packed in and the app crashes at startup.
> - **Bug fixed:** `$(preflight)` was capturing log output as the app path — logs
>   now go to stderr.
> - **Fixed:** new window used `titleBarStyle:'hiddenInset'` with no drag region
>   (couldn't be moved); now a standard title bar + cascade offset.
> - **Known gap:** translate-to-Hebrew is best-effort (claude.ai re-renders revert it).

Goal: get the **first-draft macOS patcher working on a real Mac**, the same way
the Windows patcher was iterated to working on a real PC. This file gives a
fresh session on the Mac full context — it won't have the Windows chat history
that produced this code.

You are on branch **`macbook`** (NOT `main`). `main` is Windows-only and verified;
keep unverified macOS work on this branch until it's confirmed, then it can be
merged to `main`.

## What already exists on this branch

- `patch-claude-macos.sh` — the in-place patcher (install / `--restore` /
  `--enable-auto-update` / `--disable-auto-update`, with `--yes` / `--no-auto-update`).
- `src/mac-entry.js` — set as the asar's `package.json` `main`; loads the wrapper
  then chains to the app's original main.
- `src/mac-wrapper.js` — the `web-contents-created` hook: RTL + multi-window
  button injection, right-click menu (RTL toggle / רענן דף / תרגם לעברית / new
  window / version label), in-process new window.
- `package-macos.sh` — builds `dist/claude-desktop-macos-rtl[-vX.Y.Z].tar.gz`.
- Shared, unchanged from Windows: `src/rtl-support.js`,
  `src/translate-support.js`, `src/multi-instance-support.js`.

All of the above passed `node --check` / `bash -n` only. **Nothing has been run
against a real Claude.app.** Treat it as a hypothesis to verify.

## How the Windows version works (the proven reference)

The Windows flow, which the macOS script mirrors:

1. Locate the install, take write access, quit Claude.
2. Back up `app.asar` (+ the integrity carrier), restore from backup before
   every re-patch (idempotent).
3. `@electron/asar extract` → drop the 5 JS files in the asar root → rewrite
   `package.json` (`main` → our entry, stash upstream main in
   `claudeOriginalMain`) → `@electron/asar pack`.
4. Make Electron's ASAR-integrity check accept the new asar (Windows:
   byte-replace the header hash inside `claude.exe`).
5. Re-establish a valid code signature (Windows: self-signed re-sign).
6. Record state + stash a stable copy + (optionally) install an auto-re-patch
   watcher so a Claude update doesn't silently drop the patch.

The five JS modules and the **in-process new-window** approach are identical on
both platforms — do NOT reinvent them. Fix any macOS quirk in `mac-wrapper.js`,
never in the shared `*-support.js`.

## First steps on the Mac

```bash
git clone git@github.com:shaloml/claude-desktop-windows-rtl.git
cd claude-desktop-windows-rtl
git checkout macbook
chmod +x patch-claude-macos.sh package-macos.sh
./patch-claude-macos.sh        # prompts for prerequisites, then patches
```

Prereqs the script checks: `/Applications/Claude.app`, Node ≥ 22 (offers
`brew install node`), and your admin password (sudo writes inside /Applications).

## The make-or-break unknowns — verify these in order

These are the parts written blind from Windows. Each is a likely iteration point.

### 1. ASAR integrity location & format (HIGHEST RISK)

The script assumes the integrity hash lives in `Contents/Info.plist` under
`ElectronAsarIntegrity → Resources/app.asar → hash`, and updates it with
PlistBuddy. **Verify the real structure first:**

```bash
APP="/Applications/Claude.app"
/usr/libexec/PlistBuddy -c "Print :ElectronAsarIntegrity" "$APP/Contents/Info.plist"
```

- If the key exists with that shape → the script should work; confirm the hash
  it writes matches what Electron computes (see `asar_header_hash` in the
  script — it's the SHA-256 of the asar header JSON, same as Windows).
- If the shape differs (e.g. value is the hash directly, or keyed differently) →
  adjust the PlistBuddy path in `install_patch` (Phase 2).
- If the key is absent → integrity may be off entirely; the script logs and
  skips, and patching may "just work" after re-signing. Also check the fuse:
  `npx @electron/fuses read --app "$APP/Contents/MacOS/Claude"` — if
  `EnableEmbeddedAsarIntegrityValidation` is enabled and Info.plist isn't the
  carrier, you may need a fuse flip (mirror the Windows `Invoke-FuseFlip`).

### 2. Gatekeeper / code signing (SECOND RISK)

Editing the bundle invalidates Apple's signature. The script does
`codesign --force --deep --sign -` (ad-hoc) + `xattr -dr com.apple.quarantine`.

- If the app launches after that → done.
- If macOS kills it ("damaged" / won't open) → likely **hardened runtime +
  library validation**. Options, in order: (a) re-sign with
  `--options runtime` and the original entitlements
  (`codesign -d --entitlements - "$APP"` to dump them first); (b) if that fails,
  this approach may be blocked on that macOS version — document it and fall back
  to `--restore`. Capture the exact Console.app / `spctl --assess -vv "$APP"`
  output before changing anything.

### 3. Quit / relaunch

`osascript -e 'quit app "Claude"'` then a scoped `pkill` of
`/Claude.app/Contents/MacOS/Claude`. Confirm it doesn't catch anything else and
that `open -a "$APP"` brings it back patched.

### 4. Visual: floating-button offset

Traffic lights are top-LEFT, so the top-RIGHT buttons shouldn't collide. The
`MAC_BUTTON_OFFSET_CSS` in `mac-wrapper.js` nudges them down 40px to clear
claude.ai's in-app topbar. Adjust after looking at it (0 may be fine).

### 5. Auto-re-patch (launchd)

`enable_auto_update` writes a LaunchAgent +
`~/Library/Application Support/ClaudeMacRtl/watcher.sh` that re-patches when the
app version changes. Verify: `launchctl list | grep claude-mac-rtl`, then check
`~/Library/Application Support/ClaudeMacRtl/watcher.log` after the next Claude
update (or trigger the watcher by hand).

## After it works

1. Bump the version, build a release archive:
   `./package-macos.sh --version 1.0.0` → `dist/claude-desktop-macos-rtl-v1.0.0.tar.gz`.
2. Update `README.md` / `CLAUDE.md` on this branch to drop the "not yet verified"
   caveats and record whatever you learned (especially the real Info.plist
   integrity shape and the working codesign invocation).
3. Merge `macbook` → `main` and tag/release.

## Project rules (carried from CLAUDE.md)

- **Every commit authored AND committed by `Shalom Levi <shaloml@gmail.com>`.**
  No `Co-Authored-By: Claude` or any AI-attribution trailers.
- Only commit/push when the user explicitly asks.
- `bash -n` every shell script and `node --check` every JS file before committing.
- Don't edit the shared `*-support.js` modules for a macOS-only issue — override
  from `mac-wrapper.js`.

## Reference

- Windows equivalents to read for the proven logic: `patch-claude-windows.ps1`
  (functions `Compute-AsarHash`, `Install-Patch`, `Invoke-FuseFlip`,
  `Install-AutoUpdateTask`) — on the `main` branch.
- Linux origin of the shared modules:
  [`aaddrick/claude-desktop-debian`](https://github.com/aaddrick/claude-desktop-debian).
