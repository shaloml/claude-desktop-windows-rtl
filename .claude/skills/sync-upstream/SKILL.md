---
name: sync-upstream
description: Refresh the shared support modules (rtl/translate/multi-instance) from the upstream claude-desktop-linux project. Use when the user wants to pull upstream RTL/translate fixes or update the bundled JS modules.
---

# Sync shared modules from upstream

`src/rtl-support.js`, `src/translate-support.js`, and
`src/multi-instance-support.js` originate from the Linux project
(`claude-desktop-debian` / the local `claude-desktop-linux` checkout). This repo
vendors copies. Use this to pull newer versions deliberately.

## Source of truth

The upstream modules live in the `scripts/` folder of a local
`claude-desktop-linux` (a.k.a. `claude-desktop-debian`) checkout. Point the
`$U` variable below at wherever that checkout sits on your machine — do not
hard-code an absolute path here. (`win-entry.js` and `win-wrapper.js` are
Windows-only — they live ONLY in this repo and are never overwritten by a sync.)

## Procedure

1. Set the upstream scripts dir, then diff before copying so changes are
   intentional:
   ```bash
   U="${CLAUDE_LINUX_REPO:-../claude-desktop-linux}/scripts"   # adjust as needed
   for f in rtl-support.js translate-support.js multi-instance-support.js; do
     echo "=== $f ==="; diff -u "src/$f" "$U/$f" || true
   done
   ```
2. Copy only the modules that genuinely changed.
3. **Re-apply Windows-only expectations:** `win-wrapper.js` imports
   `{ RTL_CSS, RTL_JS }` from rtl-support and calls `window.claudeRTLToggle`; it
   overrides button positions (62px) and opens new windows in-process. If an
   upstream change renames an export or the toggle global, update `win-wrapper.js`
   to match — do NOT patch the shared module for a Windows quirk.
4. Validate: `node --check` every `src/*.js`.
5. Re-test with the `apply-patch` skill, then rebuild with `package-release`.

## Rules

- Never edit the three shared modules to fix a Windows-only problem; override
  from `win-wrapper.js` (keeps them portable for upstream).
- Record what was synced in the commit subject (e.g. "sync rtl-support from
  upstream (per-line bidi fix)").
