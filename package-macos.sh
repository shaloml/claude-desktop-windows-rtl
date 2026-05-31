#!/usr/bin/env bash
#
# Assemble a self-contained, distributable archive of the macOS patch.
#
# Collects patch-claude-macos.sh + the five JS payloads (from ./src) into a flat
# folder and tars it. The patcher's source resolution detects this flat layout,
# so the archive is self-contained — the target Mac needs only Node.js and the
# Claude Desktop .app, no repo checkout.
#
# Usage:
#   ./package-macos.sh                 # -> dist/claude-desktop-macos-rtl.tar.gz
#   ./package-macos.sh --version 1.0.0 # -> dist/claude-desktop-macos-rtl-v1.0.0.tar.gz

set -u

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src_dir="$script_dir/src"
out_dir="$script_dir/dist"
project='claude-desktop-macos-rtl'
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
	"patch-claude-macos.sh:$script_dir"
	"mac-entry.js:$src_dir"
	"mac-wrapper.js:$src_dir"
	"rtl-support.js:$src_dir"
	"translate-support.js:$src_dir"
	"multi-instance-support.js:$src_dir"
)

for entry in "${files[@]}"; do
	name="${entry%%:*}"; dir="${entry##*:}"
	[[ -f "$dir/$name" ]] || { echo "Missing payload file: $dir/$name" >&2; exit 1; }
done

rm -rf "$bundle_dir"
mkdir -p "$bundle_dir"
for entry in "${files[@]}"; do
	name="${entry%%:*}"; dir="${entry##*:}"
	cp "$dir/$name" "$bundle_dir/$name"
done
chmod +x "$bundle_dir/patch-claude-macos.sh"

cat > "$bundle_dir/INSTALL.txt" <<'TXT'
Claude Desktop — macOS extensions patch
=======================================

Adds RTL (Hebrew/Arabic) support, a version label, page refresh,
translate-to-Hebrew, and a "new window" item to the official macOS
Claude Desktop, by patching the installed app in place.

REQUIREMENTS
------------
- macOS with the official Claude Desktop installed (/Applications/Claude.app).
- Node.js 22+ (https://nodejs.org or `brew install node`) — the patcher checks
  and offers to install via Homebrew if missing.
- Admin password (the patcher uses sudo to write inside /Applications).

INSTALL
-------
1. Unpack:  tar -xzf claude-desktop-macos-rtl-*.tar.gz
2. cd into the unpacked folder.
3. Run:     ./patch-claude-macos.sh
   (If it isn't executable: chmod +x patch-claude-macos.sh)
4. Approve the prerequisite/patch prompts and your admin password.

UNINSTALL / RESTORE ORIGINAL
----------------------------
   ./patch-claude-macos.sh --restore

STAYING PATCHED ACROSS UPDATES
------------------------------
A Claude update replaces the app and removes the patch. Auto-re-patch is enabled
by default via a launchd LaunchAgent that re-applies the patch when Claude
updates. Opt out with --no-auto-update, or toggle:
   ./patch-claude-macos.sh --enable-auto-update
   ./patch-claude-macos.sh --disable-auto-update

NOTES
-----
- The patcher backs up app.asar + Info.plist before changing anything; Restore
  puts them back.
- Editing the bundle invalidates Apple's code signature, so the patcher re-signs
  it ad-hoc (codesign --sign -) and clears the quarantine flag. If macOS still
  refuses to launch it (hardened runtime / library validation), see the repo
  README's macOS section.
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
