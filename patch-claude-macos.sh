#!/usr/bin/env bash
#
# In-place patcher for the official macOS Claude Desktop (Claude.app).
#
# Injects this repo's cross-platform extensions (RTL, version label, refresh,
# translate-to-Hebrew, multi-window) into the app's app.asar, then keeps
# Electron's ASAR integrity check happy by updating the header hash recorded in
# the app's Info.plist (ElectronAsarIntegrity), and re-signs the bundle ad-hoc so
# macOS will still launch it.
#
# Sibling of patch-claude-windows.ps1. Same JS payload (src/*.js); macOS-specific
# mechanics: Info.plist instead of byte-replacing a binary, codesign + xattr
# instead of Authenticode, launchd instead of a Scheduled Task.
#
# Usage:
#   ./patch-claude-macos.sh                 # install (prompts for prerequisites)
#   ./patch-claude-macos.sh --restore       # revert to the original app.asar
#   ./patch-claude-macos.sh --yes           # unattended (auto-approve prompts)
#   ./patch-claude-macos.sh --no-auto-update # skip the auto-re-patch LaunchAgent
#
# NOTE: First-draft port. Not yet verified on a real Mac — see the README's
# macOS section. Iterate against an actual machine.

# Intentionally NOT using `set -e` (interacts badly with $(...) capture); check
# status explicitly instead.
set -u

# --- config -----------------------------------------------------------------
ASAR_PKG='@electron/asar@4.2.0'
FUSES_PKG='@electron/fuses@2.1.1'
# Native modules that MUST stay outside the asar (dlopen can't load a .node from
# inside an archive). The app ships them in app.asar.unpacked; `asar pack` only
# preserves that if we pass a matching --unpack glob, else they get packed in and
# the app crashes loading claude-native at startup. Covers the 3 *.node addons
# plus node-pty's extensionless spawn-helper.
ASAR_UNPACK_GLOB='{*.node,spawn-helper}'
MIN_NODE_MAJOR=22
STATE_DIR="$HOME/Library/Application Support/ClaudeMacRtl"
PLIST_LABEL='com.shaloml.claude-mac-rtl.autopatch'

ASSUME_YES=0
NO_AUTO_UPDATE=0
ACTION='install'

# --- colored logging --------------------------------------------------------
# All diagnostics go to stderr so functions can `printf` a return value to stdout
# and have `$(...)` capture ONLY that value (e.g. preflight returning app_dir).
log()  { printf '  \033[36m[*]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[35m> %s\033[0m\n' "$*" >&2; }
ok()   { printf '  \033[32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '  \033[33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31m[X] %s\033[0m\n' "$*" >&2; exit 1; }

# --- arg parsing ------------------------------------------------------------
for arg in "$@"; do
	case "$arg" in
		--restore) ACTION='restore' ;;
		--enable-auto-update) ACTION='enable-auto-update' ;;
		--disable-auto-update) ACTION='disable-auto-update' ;;
		--yes|-y) ASSUME_YES=1 ;;
		--no-auto-update) NO_AUTO_UPDATE=1 ;;
		-h|--help)
			grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -40
			exit 0 ;;
		*) die "Unknown argument: $arg" ;;
	esac
done

confirm() {
	# confirm "Question" -> 0 if yes
	[[ $ASSUME_YES -eq 1 ]] && { log "$1 -> auto-yes (--yes)"; return 0; }
	local ans
	read -r -p "$1 [Y/n] " ans
	[[ -z "$ans" || "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# --- locate Claude.app ------------------------------------------------------
find_claude_app() {
	local candidates=(
		"/Applications/Claude.app"
		"$HOME/Applications/Claude.app"
	)
	local c
	for c in "${candidates[@]}"; do
		[[ -d "$c" && -f "$c/Contents/Resources/app.asar" ]] && { printf '%s' "$c"; return 0; }
	done
	# Fallback: Spotlight.
	local found
	found=$(mdfind "kMDItemCFBundleIdentifier == 'com.anthropic.claudefordesktop'" 2>/dev/null | head -1)
	[[ -z "$found" ]] && found=$(mdfind 'kMDItemFSName == "Claude.app"' 2>/dev/null | head -1)
	[[ -n "$found" && -f "$found/Contents/Resources/app.asar" ]] && { printf '%s' "$found"; return 0; }
	return 1
}

# --- node / npx -------------------------------------------------------------
node_major() {
	command -v node >/dev/null 2>&1 || return 1
	node -p 'process.versions.node.split(".")[0]' 2>/dev/null
}

ensure_node() {
	local maj
	maj=$(node_major)
	if [[ -n "$maj" && "$maj" -ge $MIN_NODE_MAJOR ]]; then
		return 0
	fi
	if [[ -n "$maj" ]]; then
		warn "Node v$(node -v 2>/dev/null) is older than the required v${MIN_NODE_MAJOR}+."
	else
		warn 'Node.js was not found.'
	fi
	if command -v brew >/dev/null 2>&1; then
		if confirm 'Install Node.js via Homebrew now?'; then
			step 'Installing Node via Homebrew...'
			brew install node || warn 'brew install node failed.'
		fi
	else
		warn 'Homebrew not found; cannot auto-install Node.'
	fi
	maj=$(node_major)
	[[ -n "$maj" && "$maj" -ge $MIN_NODE_MAJOR ]] || \
		die "Node.js ${MIN_NODE_MAJOR}+ is required. Install it from https://nodejs.org or via Homebrew, then re-run."
	ok "Node $(node -v) ready."
}

# --- asar header hash (matches the Windows Compute-AsarHash) -----------------
# Reads the uint32 JSON-size at offset 12, then sha256 of the next jsonSize
# bytes (the asar header JSON) — the value Electron stores as the integrity hash.
asar_header_hash() {
	node -e '
		const fs = require("fs"), crypto = require("crypto");
		const fd = fs.openSync(process.argv[1], "r");
		const head = Buffer.alloc(16);
		fs.readSync(fd, head, 0, 16, 0);
		const jsonSize = head.readUInt32LE(12);
		const json = Buffer.alloc(jsonSize);
		fs.readSync(fd, json, 0, jsonSize, 16);
		fs.closeSync(fd);
		process.stdout.write(crypto.createHash("sha256").update(json).digest("hex"));
	' "$1"
}

# =============================================================================
# PREFLIGHT
# =============================================================================
preflight() {
	step 'Checking prerequisites...'
	local app_dir; app_dir=$(find_claude_app)
	local node_maj; node_maj=$(node_major)

	# Report goes to stderr; only the final app_dir goes to stdout (so the caller's
	# `$(preflight)` captures just the path, not this diagnostic text).
	{
		printf '\n  Prerequisite check\n'
		if [[ -n "$app_dir" ]]; then printf '  [+] Claude Desktop      %s\n' "$app_dir"
		else printf '  [X] Claude Desktop      NOT FOUND\n'; fi
		if [[ -n "$node_maj" && "$node_maj" -ge $MIN_NODE_MAJOR ]]; then
			printf '  [+] Node.js >= %s        v%s\n' "$MIN_NODE_MAJOR" "$(node -v | sed 's/^v//')"
		else
			printf '  [X] Node.js >= %s        %s\n' "$MIN_NODE_MAJOR" \
				"$([[ -n "$node_maj" ]] && node -v || echo 'NOT FOUND')"
		fi
		printf '\n'
	} >&2

	[[ -n "$app_dir" ]] || die "Claude Desktop for macOS was not found. Install it from https://claude.ai/download, then re-run."
	ensure_node
	confirm 'Patch Claude Desktop now?' || die 'Aborted by user.'
	printf '%s' "$app_dir"
}

# --- quit Claude ------------------------------------------------------------
quit_claude() {
	step 'Quitting Claude...'
	osascript -e 'quit app "Claude"' >/dev/null 2>&1
	sleep 1
	# Force any stragglers (scoped to the app bundle, never anything else).
	pkill -f '/Claude.app/Contents/MacOS/Claude' 2>/dev/null
	sleep 1
	ok 'Claude quit.'
}

# =============================================================================
# INSTALL
# =============================================================================
install_patch() {
	local app_dir; app_dir=$(preflight)

	local res="$app_dir/Contents/Resources"
	local asar="$res/app.asar"
	local plist="$app_dir/Contents/Info.plist"
	local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local src_dir="$script_dir/src"
	[[ -d "$src_dir" ]] || src_dir="$script_dir"   # flat bundle fallback

	local files=(mac-entry.js mac-wrapper.js rtl-support.js translate-support.js multi-instance-support.js)
	local f
	for f in "${files[@]}"; do
		[[ -f "$src_dir/$f" ]] || die "Required source file not found: $src_dir/$f"
	done

	# /Applications is usually root-owned; re-exec under sudo if we can't write.
	if [[ ! -w "$asar" ]]; then
		warn 'app.asar is not writable; elevating with sudo...'
		exec sudo ASSUME_YES=$ASSUME_YES "$0" "$@"
	fi

	quit_claude

	step 'Backing up (first run only)...'
	[[ -f "$asar.bak" ]]  || { cp -p "$asar"  "$asar.bak";  ok 'app.asar.bak'; }
	[[ -f "$plist.bak" ]] || { cp -p "$plist" "$plist.bak"; ok 'Info.plist.bak'; }

	step 'Restoring originals before re-patching (idempotency)...'
	cp -p "$asar.bak"  "$asar"
	cp -p "$plist.bak" "$plist"

	step 'Phase 1: inject extensions into app.asar'
	local old_hash; old_hash=$(asar_header_hash "$asar")
	log "Original asar hash: $old_hash"

	local tmp; tmp=$(mktemp -d)
	npx --yes "$ASAR_PKG" extract "$asar" "$tmp" || die 'asar extract failed.'

	for f in "${files[@]}"; do
		cp "$src_dir/$f" "$tmp/$f"
		log "Injected $f"
	done

	# Rewrite package.json: stash original main, point main at mac-entry.js.
	node -e '
		const fs = require("fs"); const p = process.argv[1];
		const pkg = JSON.parse(fs.readFileSync(p, "utf8"));
		const entry = "mac-entry.js";
		if (pkg.main && pkg.main !== entry) pkg.claudeOriginalMain = pkg.main;
		else if (!pkg.claudeOriginalMain) pkg.claudeOriginalMain = ".vite/build/index.pre.js";
		pkg.main = entry;
		fs.writeFileSync(p, JSON.stringify(pkg, null, 2));
	' "$tmp/package.json" || die 'package.json rewrite failed.'
	ok 'package.json main -> mac-entry.js'

	local new_asar="$asar.new"
	npx --yes "$ASAR_PKG" pack "$tmp" "$new_asar" --unpack "$ASAR_UNPACK_GLOB" || die 'asar pack failed.'
	local new_hash; new_hash=$(asar_header_hash "$new_asar")
	log "New asar hash: $new_hash"
	mv "$new_asar" "$asar"
	# --unpack made asar pack emit a fresh sibling .unpacked of the native modules.
	# Its contents are byte-identical to the pristine app.asar.unpacked already in
	# place (we never modify natives), so discard the freshly-generated orphan and
	# keep the original. The new asar header still flags those paths as unpacked,
	# so Electron loads them from app.asar.unpacked as before.
	[[ -d "$new_asar.unpacked" ]] && rm -rf "$new_asar.unpacked"
	rm -rf "$tmp"

	step 'Phase 2: update ASAR integrity hash in Info.plist'
	# Electron records the asar header hash under
	# ElectronAsarIntegrity:Resources/app.asar:hash. Update it to the new hash.
	if /usr/libexec/PlistBuddy -c "Print :ElectronAsarIntegrity" "$plist" >/dev/null 2>&1; then
		/usr/libexec/PlistBuddy \
			-c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $new_hash" "$plist" \
			&& ok 'Info.plist integrity hash updated.' \
			|| warn 'Could not set integrity hash in Info.plist.'
	else
		log 'No ElectronAsarIntegrity key in Info.plist (integrity may be off) — skipping.'
	fi

	step 'Phase 3: re-sign the app bundle (ad-hoc) + clear quarantine'
	# Editing files inside the bundle invalidates Anthropic's signature. Re-sign
	# ad-hoc so Gatekeeper allows local launch. --deep covers nested binaries.
	if codesign --force --deep --sign - "$app_dir" 2>/dev/null; then
		ok 'Re-signed ad-hoc.'
	else
		warn 'codesign failed. If the app refuses to launch, see the README (hardened-runtime / entitlements / fuse fallback).'
	fi
	xattr -dr com.apple.quarantine "$app_dir" 2>/dev/null && log 'Cleared quarantine attribute.'

	# Record state for the auto-update watcher.
	mkdir -p "$STATE_DIR"
	defaults_write_state "$app_dir"
	save_stable_bundle "$src_dir"

	step 'Cleanup & launch'
	open -a "$app_dir" 2>/dev/null && ok 'Claude launched.' || warn 'Launch manually.'

	if [[ $NO_AUTO_UPDATE -eq 1 ]]; then
		log 'Auto-re-patch skipped (--no-auto-update). Re-run after a Claude update, or use --enable-auto-update.'
	else
		enable_auto_update
	fi

	printf '\n\033[32m=== PATCH COMPLETE ===\033[0m\n\n'
}

# --- patch state ------------------------------------------------------------
patched_version_of() {
	/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
		"$1/Contents/Info.plist" 2>/dev/null
}

defaults_write_state() {
	local ver; ver=$(patched_version_of "$1")
	printf '{"patchedVersion":"%s","appPath":"%s"}\n' "$ver" "$1" \
		> "$STATE_DIR/state.json"
}

save_stable_bundle() {
	local src="$1"
	local dst="$STATE_DIR/app"
	rm -rf "$dst"; mkdir -p "$dst"
	cp "${BASH_SOURCE[0]}" "$dst/patch-claude-macos.sh"
	chmod +x "$dst/patch-claude-macos.sh"
	local f
	for f in mac-entry.js mac-wrapper.js rtl-support.js translate-support.js multi-instance-support.js; do
		cp "$src/$f" "$dst/$f"
	done
}

# =============================================================================
# AUTO-UPDATE (launchd LaunchAgent)
# =============================================================================
enable_auto_update() {
	step 'Enabling auto-re-patch (LaunchAgent)...'
	local agent_dir="$HOME/Library/LaunchAgents"
	local plist="$agent_dir/$PLIST_LABEL.plist"
	local watcher="$STATE_DIR/watcher.sh"
	mkdir -p "$agent_dir"

	cat > "$watcher" <<'WATCHER'
#!/usr/bin/env bash
# Auto-re-patch watcher: re-applies the patch when Claude.app updates.
set -u
state="$HOME/Library/Application Support/ClaudeMacRtl"
patcher="$state/app/patch-claude-macos.sh"
log="$state/watcher.log"
app=$(/usr/bin/mdfind 'kMDItemFSName == "Claude.app"' 2>/dev/null | head -1)
[[ -z "$app" ]] && app="/Applications/Claude.app"
[[ -f "$app/Contents/Info.plist" ]] || { echo "$(date) no app" >>"$log"; exit 0; }
inst=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)
patched=$(/usr/bin/plutil -extract patchedVersion raw "$state/state.json" 2>/dev/null)
if [[ "$inst" == "$patched" ]]; then exit 0; fi
echo "$(date) version change ($patched -> $inst); re-patching" >>"$log"
/bin/bash "$patcher" --yes --no-auto-update >>"$log" 2>&1
WATCHER
	chmod +x "$watcher"

	cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$PLIST_LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/bash</string><string>$watcher</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>10800</integer>
</dict>
</plist>
PLIST

	launchctl unload "$plist" 2>/dev/null
	if launchctl load "$plist" 2>/dev/null; then
		ok "Auto-re-patch enabled ($PLIST_LABEL)."
		log "Watcher log: $STATE_DIR/watcher.log"
	else
		warn 'Could not load the LaunchAgent.'
	fi
}

disable_auto_update() {
	step 'Disabling auto-re-patch...'
	local plist="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
	launchctl unload "$plist" 2>/dev/null
	rm -f "$plist"
	ok 'Auto-re-patch disabled.'
}

# =============================================================================
# RESTORE
# =============================================================================
restore_patch() {
	local app_dir; app_dir=$(find_claude_app)
	[[ -n "$app_dir" ]] || die 'Claude.app not found.'
	local res="$app_dir/Contents/Resources"
	local asar="$res/app.asar"
	local plist="$app_dir/Contents/Info.plist"

	if [[ ! -w "$asar" && -f "$asar" ]]; then
		warn 'Elevating with sudo to restore...'
		exec sudo "$0" --restore
	fi

	quit_claude
	step 'Restoring original files from backup...'
	[[ -f "$asar.bak" ]]  && { cp -p "$asar.bak"  "$asar";  ok 'app.asar restored'; }
	[[ -f "$plist.bak" ]] && { cp -p "$plist.bak" "$plist"; ok 'Info.plist restored'; }
	codesign --force --deep --sign - "$app_dir" 2>/dev/null && log 're-signed ad-hoc'
	disable_auto_update
	open -a "$app_dir" 2>/dev/null
	printf '\n\033[32m=== Restore complete ===\033[0m\n\n'
}

# =============================================================================
[[ "$(uname)" == 'Darwin' ]] || die 'This patcher is for macOS. On Windows use patch-claude-windows.ps1.'

case "$ACTION" in
	install)             install_patch ;;
	restore)             restore_patch ;;
	enable-auto-update)  enable_auto_update ;;
	disable-auto-update) disable_auto_update ;;
esac
