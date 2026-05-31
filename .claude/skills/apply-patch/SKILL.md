---
name: apply-patch
description: Apply the Windows patch to the locally-installed Claude Desktop and verify each feature. Use when the user wants to install, re-apply, test, or restore the patch on this machine.
---

# Apply / test the Windows patch

Apply `patch-claude-windows.ps1` to the live MSIX Claude Desktop and confirm the
extensions load. Always validate syntax first; never kill `claude.exe` by name.

## Preflight (always)

1. Parse-check the patcher and `node --check` every `src/*.js`:
   ```powershell
   $e=$null;$t=$null
   [void][System.Management.Automation.Language.Parser]::ParseFile('patch-claude-windows.ps1',[ref]$t,[ref]$e)
   if($e.Count){$e}else{"PS OK"}
   ```
   ```bash
   for f in src/*.js; do node --check "$f" && echo "OK $f"; done
   ```
2. Confirm the install + tooling:
   - `Get-AppxPackage *Claude* | ? InstallLocation -like '*WindowsApps*'`
   - `node --version` (need ≥ 22.12), `npx` present.

## Apply

Run in an **isolated elevated process** (not a child of this session — that risk
killed earlier sessions) and tee to a log:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList @(
  '-NoProfile','-ExecutionPolicy','Bypass','-File','patch-claude-windows.ps1')
```

Wait for `=== PATCH COMPLETE ===`, then read the log. The patcher self-elevates,
stops Claude Desktop (scoped to the install path — the CLI survives), backs up to
`*.bak`, injects, byte-replaces the hash, re-signs, and relaunches.

## Verify

After launch (reload the window once if needed), check each:
- Floating **RTL toggle** (top-right, ~62px down) and the right-click
  **"הפעל/בטל RTL"** item — toggles direction, no page reload.
- Right-click **"רענן דף"** (reload), **"תרגם לעברית"** (translate),
  **"פתח חלון חדש"** (opens an in-process window, already logged in),
  and the **version label** (click copies to clipboard).

Confirm the live asar actually carries the current code:
```bash
root=$(ls -d "/c/Program Files/WindowsApps/Claude_"*"_pzs8sxrjxfjjc" | sort | tail -1)
npx --yes @electron/asar@4.2.0 extract "$root/app/resources/app.asar" /tmp/lc
grep -c openNewWindow /tmp/lc/win-wrapper.js
```

## Restore

```powershell
powershell -ExecutionPolicy Bypass -File patch-claude-windows.ps1 -Action Restore
```

## Auto-update (re-patch after Claude updates)

A Claude update wipes the patch. Offer/enable the watcher so it re-applies
automatically:

```powershell
powershell -ExecutionPolicy Bypass -File patch-claude-windows.ps1 -Action EnableAutoUpdate
powershell -ExecutionPolicy Bypass -File patch-claude-windows.ps1 -Action DisableAutoUpdate
```

State + stable bundle + log live under `%ProgramData%\ClaudeWindowsRtl\`. To
check it's working: `Get-ScheduledTask ClaudeWindowsRtlAutoPatch` and read
`%ProgramData%\ClaudeWindowsRtl\watcher.log`.

## If it fails

- App won't launch → likely EDR. Restore, add an EDR exclusion for the Claude
  install folder, retry.
- "Not main instance" / blank window → a regression toward process-spawn; new
  window must use in-process `new BrowserWindow` (see `CLAUDE.md`).
