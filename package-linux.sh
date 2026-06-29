#!/usr/bin/env bash
#
# Assemble a self-contained, distributable archive of the Linux patch.
#
# Collects patch-claude-linux.sh + the five JS payloads (from ./src) into a flat
# folder and tars it. The patcher's source resolution detects this flat layout,
# so the archive is self-contained — the target machine needs only Node.js and a
# Linux Claude Desktop install, no repo checkout.
#
# Usage:
#   ./package-linux.sh                 # -> dist/claude-desktop-linux-rtl.tar.gz
#   ./package-linux.sh --version 1.0.0 # -> dist/claude-desktop-linux-rtl-v1.0.0.tar.gz

set -u

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src_dir="$script_dir/src"
out_dir="$script_dir/dist"
project='claude-desktop-linux-rtl'
version=''

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) version="${2#v}"; shift 2 ;;
		--out) out_dir="$2"; shift 2 ;;
		*) echo "Unknown argument: $1" >&2; exit 1 ;;
	esac
done

suffix=''
[[ -n "$version" ]] && suffix="-v$version"
bundle="$project$suffix"
bundle_dir="$out_dir/$bundle"
tarball="$out_dir/$bundle.tar.gz"

files=(
	"patch-claude-linux.sh:$script_dir"
	"linux-entry.js:$src_dir"
	"linux-wrapper.js:$src_dir"
	"rtl-support.js:$src_dir"
	"translate-support.js:$src_dir"
	"multi-instance-support.js:$src_dir"
)

for entry in "${files[@]}"; do
	name="${entry%%:*}"; dir="${entry##*:}"
	[[ -f "$dir/$name" ]] || { echo "Missing payload file: $dir/$name" >&2; exit 1; }
done

# Parse/syntax sanity before bundling.
bash -n "$script_dir/patch-claude-linux.sh" || { echo "patch-claude-linux.sh failed to parse" >&2; exit 1; }
for js in linux-entry.js linux-wrapper.js rtl-support.js translate-support.js \
		multi-instance-support.js; do
	node --check "$src_dir/$js" || { echo "$js failed node --check" >&2; exit 1; }
done

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"
for entry in "${files[@]}"; do
	name="${entry%%:*}"; dir="${entry##*:}"
	cp "$dir/$name" "$bundle_dir/$name"
done
chmod +x "$bundle_dir/patch-claude-linux.sh"

cat > "$bundle_dir/INSTALL.txt" <<'TXT'
Claude Desktop — Linux extensions patch
=======================================

Adds RTL (Hebrew/Arabic) support, a version label, page refresh,
translate-to-Hebrew, and a "new window" item to a Linux Claude Desktop, by
patching the installed app's app.asar in place.

REQUIREMENTS
------------
- A Linux Claude Desktop install (claude-desktop-debian layout, typically
  /usr/lib/claude-desktop). Set CLAUDE_DESKTOP_DIR to override.
- Node.js 22+ (https://nodejs.org, your distro, or nvm).
- sudo rights — app files under /usr/lib are root-owned. RUN THIS AS YOUR
  NORMAL USER (not under sudo): npx runs as you so your Node/npx stay on PATH;
  only the writes into the install dir elevate via sudo.

INSTALL
-------
1. Unpack:  tar -xzf claude-desktop-linux-rtl-*.tar.gz
2. cd into the unpacked folder.
3. Run:     ./patch-claude-linux.sh
   (If it isn't executable: chmod +x patch-claude-linux.sh)
4. Approve the prerequisite/patch prompts and your sudo password.

UNINSTALL / RESTORE ORIGINAL
----------------------------
   ./patch-claude-linux.sh --restore

CLAUDE CODE IN VS CODE (RTL)
----------------------------
RTL for the Claude Code VS Code extension now lives in its own project:
   https://github.com/shaloml/vscode-claude-rtl

STAYING PATCHED ACROSS UPDATES
------------------------------
A Claude update replaces app.asar and removes the patch. Auto-re-patch is
enabled by default via a systemd system timer that re-applies the patch when
the installed app.asar changes. Opt out with --no-auto-update, or toggle:
   ./patch-claude-linux.sh --enable-auto-update
   ./patch-claude-linux.sh --disable-auto-update

NOTES
-----
- The patcher backs up app.asar before changing anything; Restore puts it back.
- The Linux Electron ships with asar-integrity fuses OFF and is not code-signed,
  so there is no hash to update and no re-signing — unlike Windows/macOS.
- If your build already bundles RTL (a community claude-desktop-debian build
  that baked it in), the patcher warns: it still applies, but the right-click
  menu may appear twice. A vanilla build avoids this.
- "Translate to Hebrew" is best-effort and may not stick on claude.ai (the page
  re-renders and reverts it); RTL, the version label, refresh, and new-window
  are the reliable features.
TXT

mkdir -p "$out_dir"
rm -f "$tarball"
tar -czf "$tarball" -C "$out_dir" "$bundle"

echo ""
echo "Bundle assembled:"
echo "  folder : $bundle_dir"
echo "  tarball: $tarball"
echo ""
ls -1 "$bundle_dir"
