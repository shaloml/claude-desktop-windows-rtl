#!/usr/bin/env bash
#
# In-place patcher for a Linux Claude Desktop (claude-desktop-debian layout).
#
# Injects this repo's cross-platform extensions (RTL, version label, refresh,
# translate-to-Hebrew, multi-window) into the app's app.asar. Sibling of
# patch-claude-windows.ps1 and patch-claude-macos.sh — SAME JS payload
# (src/*.js); Linux-specific mechanics:
#
#   - The Electron binary ships with asar-integrity fuses OFF
#     (EnableEmbeddedAsarIntegrityValidation / OnlyLoadAppFromAsar both Disabled)
#     and is not code-signed, so there is NO hash to update and NO re-signing —
#     this is the macOS patcher minus its Phase-2 (Info.plist) and Phase-3
#     (codesign) steps.
#   - App files under /usr/lib/claude-desktop are root-owned, so privileged
#     writes go through sudo (per-operation). Run this as your NORMAL user, not
#     under sudo — the heavy lifting (npx @electron/asar) runs as you so your
#     Node/npx stay on PATH; only the writes into the install dir elevate.
#   - Auto-re-patch uses a systemd system timer instead of launchd / a Scheduled
#     Task.
#
# Usage:
#   ./patch-claude-linux.sh                  # install (prompts for prerequisites)
#   ./patch-claude-linux.sh --yes            # unattended (auto-approve prompts)
#   ./patch-claude-linux.sh --no-auto-update # skip the auto-re-patch timer
#   ./patch-claude-linux.sh --restore        # revert to the original app.asar
#   ./patch-claude-linux.sh --enable-auto-update
#   ./patch-claude-linux.sh --disable-auto-update
#
# Override the install location with CLAUDE_DESKTOP_DIR=/path/to/app.

# Intentionally NOT using `set -e` (interacts badly with $(...) capture); check
# status explicitly instead.
set -u

# --- config -----------------------------------------------------------------
ASAR_PKG='@electron/asar@4.2.0'
# Native modules that MUST stay outside the asar (dlopen can't load a .node from
# inside an archive). `asar pack` only preserves app.asar.unpacked if we pass a
# matching --unpack glob. The natives are NESTED (node_modules/.../*.node), so the
# glob needs globstar — a bare `*.node` matches nothing here and silently packs
# the addons in, crashing the app at startup. The upstream claude-desktop-debian
# build packs with `**/*.node`; we add `**/spawn-helper` for node-pty parity with
# the Windows/macOS patchers (a no-op on builds without it).
ASAR_UNPACK_GLOB='{**/*.node,**/spawn-helper}'
MIN_NODE_MAJOR=22
STATE_DIR='/var/lib/claude-linux-rtl'
SERVICE_NAME='claude-linux-rtl'
# claude-desktop-debian launcher scripts (root-owned, NOT in the asar). Patched to
# stop a secondary (--new-window) instance from cleaning up the PRIMARY's shared
# cowork daemon — which otherwise closes the existing window when you open a
# connectors window. Absent on a vanilla build (then this step is skipped).
LAUNCHER_BIN='/usr/bin/claude-desktop'
LAUNCHER_LIB='/usr/lib/claude-desktop/launcher-common.sh'
ENTRY_FILE='linux-entry.js'
PAYLOAD_FILES=(linux-entry.js linux-wrapper.js rtl-support.js translate-support.js multi-instance-support.js)
# asar paths to probe under the install dir, most-specific first.
ASAR_REL_CANDIDATES=(
	'node_modules/electron/dist/resources/app.asar'
	'resources/app.asar'
)

ASSUME_YES=0
NO_AUTO_UPDATE=0
ACTION='install'

# --- colored logging --------------------------------------------------------
# All diagnostics go to stderr so functions can `printf` a return value to stdout
# and have `$(...)` capture ONLY that value (e.g. find_claude_app -> app_dir).
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

# Run a command as root: directly if we already are, else via sudo.
as_root() {
	if [[ $EUID -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}

# --- locate the install -----------------------------------------------------
find_asar() {
	# echoes the asar path under $1, or returns 1
	local dir="$1" rel
	for rel in "${ASAR_REL_CANDIDATES[@]}"; do
		[[ -f "$dir/$rel" ]] && { printf '%s' "$dir/$rel"; return 0; }
	done
	return 1
}

find_claude_app() {
	# echoes the install dir (the one containing the asar), or returns 1
	local candidates=(
		"${CLAUDE_DESKTOP_DIR:-}"
		'/usr/lib/claude-desktop'
		'/opt/claude-desktop'
		'/opt/Claude'
		"$HOME/.local/share/claude-desktop"
	)
	local c
	for c in "${candidates[@]}"; do
		[[ -n "$c" && -d "$c" ]] || continue
		find_asar "$c" >/dev/null 2>&1 && { printf '%s' "$c"; return 0; }
	done
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
		warn 'Node.js was not found on PATH.'
	fi
	warn 'Install Node.js 22+ (https://nodejs.org, your distro, or nvm) and re-run.'
	warn 'Tip: run this script as your normal user (not under sudo) so a per-user'
	warn '     Node install — e.g. nvm — stays on PATH.'
	die "Node.js ${MIN_NODE_MAJOR}+ is required."
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

	[[ -n "$app_dir" ]] || die "Claude Desktop for Linux was not found. Install it (claude-desktop-debian), or set CLAUDE_DESKTOP_DIR, then re-run."
	ensure_node
	confirm 'Patch Claude Desktop now?' || die 'Aborted by user.'
	printf '%s' "$app_dir"
}

# --- quit Claude ------------------------------------------------------------
# Scope kills to the install dir's electron binary ONLY. Claude Code (the CLI)
# also runs Node; matching on the desktop's electron path never touches it.
quit_claude() {
	local app_dir="$1"
	step 'Quitting Claude...'
	# The GUI runs as the invoking user, so a plain pkill (same uid) suffices.
	pkill -f "$app_dir/node_modules/electron/dist/electron" 2>/dev/null
	pkill -f "$app_dir/node_modules/electron/dist/chrome_crashpad_handler" 2>/dev/null
	sleep 1
	ok 'Claude quit (if it was running).'
}

# =============================================================================
# INSTALL
# =============================================================================
install_patch() {
	local app_dir; app_dir=$(preflight)
	local asar; asar=$(find_asar "$app_dir") || die "app.asar not found under $app_dir"

	local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	local src_dir="$script_dir/src"
	[[ -d "$src_dir" ]] || src_dir="$script_dir"   # flat bundle fallback

	local f
	for f in "${PAYLOAD_FILES[@]}"; do
		[[ -f "$src_dir/$f" ]] || die "Required source file not found: $src_dir/$f"
	done

	# Note a claude-desktop-debian build (ships frame-fix-wrapper.js). Our wrapper
	# still provides RTL + the floating buttons + the right-click menu; on such a
	# build "new window" opens a SEPARATE instance via the launcher's --new-window
	# (shares your login/MCP, never closes the existing window) instead of an
	# in-process window, which fights this build's window management.
	if npx --yes "$ASAR_PKG" list "$asar" 2>/dev/null | grep -q '^/frame-fix-wrapper.js$'; then
		log 'Detected a frame-fix (claude-desktop-debian) build: "new window" will open a'
		log 'separate instance (native Linux multi-window) rather than an in-process window.'
	fi

	quit_claude "$app_dir"

	step 'Backing up the pristine app.asar (first run only)...'
	if [[ ! -f "$asar.bak" ]]; then
		as_root cp -p "$asar" "$asar.bak" || die 'Backup failed.'
		ok 'app.asar.bak'
	else
		log 'Backup already present (re-patching from the pristine original).'
	fi

	step 'Build the patched asar in a temp dir (live app untouched until the end)'
	local tmp; tmp=$(mktemp -d)
	local work="$tmp/contents"
	# Extract the CURRENT live asar (its sibling app.asar.unpacked holds the native
	# modules), inject into a temp tree, repack, and write the live asar exactly once
	# at the end. Patching the live asar (not the .bak) keeps re-patching idempotent
	# (the package.json rewrite is a no-op when main is already our entry) AND correct
	# after a Claude update replaced the asar — building from a stale .bak would
	# downgrade it. Building in a temp dir + a single final cp keeps a mid-run failure
	# (npx hiccup, declined sudo, Ctrl-C) from leaving the app half-written.
	npx --yes "$ASAR_PKG" extract "$asar" "$work" || { rm -rf "$tmp"; die 'asar extract failed.'; }

	for f in "${PAYLOAD_FILES[@]}"; do
		cp "$src_dir/$f" "$work/$f"
		log "Injected $f"
	done

	# Rewrite package.json: stash the original main, point main at the entry shim.
	node -e '
		const fs = require("fs"); const p = process.argv[1]; const entry = process.argv[2];
		const pkg = JSON.parse(fs.readFileSync(p, "utf8"));
		if (pkg.main && pkg.main !== entry) pkg.claudeOriginalMain = pkg.main;
		else if (!pkg.claudeOriginalMain) pkg.claudeOriginalMain = ".vite/build/index.pre.js";
		pkg.main = entry;
		fs.writeFileSync(p, JSON.stringify(pkg, null, 2));
	' "$work/package.json" "$ENTRY_FILE" || { rm -rf "$tmp"; die 'package.json rewrite failed.'; }
	ok "package.json main -> $ENTRY_FILE"

	# Capture the app version from the already-extracted package.json (its version
	# field is untouched by the rewrite) — avoids a second 37MB extract just to
	# record it in state. Informational only; the watcher triggers on the asar SHA.
	local ver; ver=$(node -p 'try{require(process.argv[1]).version||""}catch(e){""}' "$work/package.json" 2>/dev/null)

	local new_asar="$tmp/app.asar.new"
	npx --yes "$ASAR_PKG" pack "$work" "$new_asar" --unpack "$ASAR_UNPACK_GLOB" \
		|| { rm -rf "$tmp"; die 'asar pack failed.'; }

	step 'Install the patched asar (single write to the live app)'
	# The freshly-generated <new>.unpacked is byte-identical to the pristine
	# app.asar.unpacked already in place (we never modify native modules), and the
	# new asar header still flags those paths as unpacked, so Electron keeps
	# loading them from the existing app.asar.unpacked. Keep the original; install
	# only the new asar.
	as_root cp "$new_asar" "$asar" || { rm -rf "$tmp"; die 'Installing patched asar failed.'; }
	ok 'app.asar patched.'
	rm -rf "$tmp"

	patch_launcher

	step 'Record state + stash a stable copy for the auto-updater'
	local patched_sha; patched_sha=$(sha256sum "$asar" | awk '{print $1}')
	local node_dir; node_dir=$(dirname "$(command -v node)")
	write_state "$asar" "$patched_sha" "$ver" "$node_dir"
	save_stable_bundle "$src_dir"
	save_shortcut

	if [[ $NO_AUTO_UPDATE -eq 1 ]]; then
		log 'Auto-re-patch skipped (--no-auto-update). Re-run after a Claude update, or use --enable-auto-update.'
	else
		enable_auto_update
	fi

	step 'Launch'
	if [[ $EUID -ne 0 && -x /usr/bin/claude-desktop ]]; then
		setsid /usr/bin/claude-desktop >/dev/null 2>&1 < /dev/null &
		disown 2>/dev/null
		ok 'Claude launched.'
	else
		log 'Start Claude Desktop from your launcher.'
	fi

	printf '\n\033[32m=== PATCH COMPLETE ===\033[0m\n\n'
}

# --- patch state ------------------------------------------------------------
# state.env is a shell-sourceable file (NOT JSON) so the root systemd watcher can
# read it without needing Node on PATH.
write_state() {
	local asar="$1" sha="$2" ver="$3" node_dir="$4"
	as_root mkdir -p "$STATE_DIR"
	printf 'APP_ASAR=%q\nPATCHED_ASAR_SHA=%q\nPATCHED_VERSION=%q\nNODE_BIN_DIR=%q\n' \
		"$asar" "$sha" "$ver" "$node_dir" | as_root tee "$STATE_DIR/state.env" >/dev/null
	ok "State recorded ($STATE_DIR/state.env)"
}

save_stable_bundle() {
	local src="$1"
	local dst="$STATE_DIR/app"
	as_root rm -rf "$dst"
	as_root mkdir -p "$dst"
	as_root cp "${BASH_SOURCE[0]}" "$dst/patch-claude-linux.sh"
	as_root chmod +x "$dst/patch-claude-linux.sh"
	local f
	for f in "${PAYLOAD_FILES[@]}"; do
		as_root cp "$src/$f" "$dst/$f"
	done
	ok "Stable copy saved ($dst)"
}

# --- re-patch desktop shortcut ----------------------------------------------
# A user-clickable shortcut that re-applies the patch after a Claude Desktop
# update. The stable patcher needs sudo for /usr/lib writes, so the .desktop runs
# in a terminal (Terminal=true) where the patcher's own `sudo` can prompt — NOT
# pkexec (that would run the whole script as root and lose npx/Node on PATH).
# User-space only, so it is skipped when this run is root (e.g. the systemd
# watcher); the shortcut from the first interactive install persists.
SHORTCUT_NAME='claude-linux-rtl-repatch.desktop'

desktop_dir() {
	local d
	d=$(xdg-user-dir DESKTOP 2>/dev/null)
	if [[ -n "$d" && -d "$d" ]]; then printf '%s' "$d"; return; fi
	printf '%s' "$HOME/Desktop"
}

save_shortcut() {
	[[ $EUID -eq 0 ]] && return 0  # no user home when run as root (watcher)
	local data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/claude-linux-rtl"
	local launcher="$data_dir/repatch.sh"
	mkdir -p "$data_dir" || return 0
	cat > "$launcher" <<-SH
		#!/usr/bin/env bash
		# Re-apply the Claude Desktop Hebrew RTL patch (after a Claude update).
		"$STATE_DIR/app/patch-claude-linux.sh" --yes --no-auto-update
		echo
		read -rp 'Press Enter to close...'
	SH
	chmod +x "$launcher"

	local desk; desk=$(desktop_dir)
	mkdir -p "$desk" || return 0
	local dfile="$desk/$SHORTCUT_NAME"
	cat > "$dfile" <<-DESK
		[Desktop Entry]
		Type=Application
		Name=Re-apply Claude RTL
		Comment=Re-apply the Hebrew RTL patch after Claude Desktop updates
		Exec=$launcher
		Terminal=true
		Icon=claude-desktop
		Categories=Utility;
	DESK
	chmod +x "$dfile"
	# KDE/GNOME: mark trusted so it launches from the desktop without a warning.
	gio set "$dfile" metadata::trusted true 2>/dev/null || true
	ok "Re-patch shortcut created ($dfile)"
}

remove_shortcut() {
	[[ $EUID -eq 0 ]] && return 0
	rm -f "$(desktop_dir)/$SHORTCUT_NAME" 2>/dev/null || true
	rm -f "${XDG_DATA_HOME:-$HOME/.local/share}/claude-linux-rtl/repatch.sh" 2>/dev/null || true
}

# =============================================================================
# LAUNCHER FIX (root-owned shell scripts, NOT the asar)
#
# A secondary (--new-window) instance runs the launcher's cleanup functions,
# which kill the PRIMARY's shared cowork-vm-service daemon and thereby close the
# running window. The fix: a secondary instance must NOT run those cleanups —
# guard the pre-launch calls (in /usr/bin/claude-desktop) on `new_instance==false`
# and short-circuit cleanup_after_electron_exit (in launcher-common.sh) when
# CLAUDE_SECONDARY_INSTANCE is set. Idempotent + reversible via marker text.
# =============================================================================
# Write the Node transformer used for both patch and unpatch to $1.
write_launcher_transformer() {
	cat > "$1" <<'NODE'
const fs = require('fs');
const [,, mode, srcBin, srcLib, outBin, outLib] = process.argv;
const T = '\t';
const BIN_OLD = 'cleanup_orphaned_cowork_daemon\ncleanup_stale_desktop_helpers\ncleanup_stale_lock\ncleanup_stale_cowork_socket';
const BIN_NEW = 'if [[ $new_instance == false ]]; then\n' + T + 'cleanup_orphaned_cowork_daemon\n' + T + 'cleanup_stale_desktop_helpers\n' + T + 'cleanup_stale_lock\n' + T + 'cleanup_stale_cowork_socket\nfi';
const BIN_MARK = 'if [[ $new_instance == false ]]; then';
const LIB_OLD = 'cleanup_after_electron_exit() {\n' + T + 'cleanup_orphaned_cowork_daemon';
const LIB_NEW = 'cleanup_after_electron_exit() {\n' + T + 'if [[ -n ${CLAUDE_SECONDARY_INSTANCE:-} ]]; then return 0; fi\n' + T + 'cleanup_orphaned_cowork_daemon';
const LIB_MARK = 'if [[ -n ${CLAUDE_SECONDARY_INSTANCE:-} ]]; then return 0; fi';
function tf(src, out, oldS, newS, mark) {
	let s = fs.readFileSync(src, 'utf8');
	if (mode === 'patch') {
		if (s.includes(mark)) { fs.writeFileSync(out, s); return 'already'; }
		if (!s.includes(oldS)) return null;
		s = s.replace(oldS, newS);
	} else {
		if (!s.includes(mark)) { fs.writeFileSync(out, s); return 'already'; }
		s = s.replace(newS, oldS);
	}
	fs.writeFileSync(out, s);
	return 'changed';
}
const rb = tf(srcBin, outBin, BIN_OLD, BIN_NEW, BIN_MARK);
const rl = tf(srcLib, outLib, LIB_OLD, LIB_NEW, LIB_MARK);
if (rb === null || rl === null) { console.error('expected launcher text not found (bin=' + rb + ', lib=' + rl + ')'); process.exit(2); }
console.log('launcher ' + mode + ': bin=' + rb + ', lib=' + rl);
NODE
}

# $1 = mode (patch|unpatch). Transforms the LIVE launcher files (idempotent),
# building in a temp dir and writing each live file exactly once.
apply_launcher() {
	local mode="$1"
	[[ -f "$LAUNCHER_BIN" && -f "$LAUNCHER_LIB" ]] || {
		log 'No claude-desktop launcher found; skipping launcher fix (vanilla build).'
		return 0
	}
	local tmp; tmp=$(mktemp -d)
	local js="$tmp/launcher-transform.js"
	write_launcher_transformer "$js"
	if node "$js" "$mode" "$LAUNCHER_BIN" "$LAUNCHER_LIB" "$tmp/bin" "$tmp/lib"; then
		as_root cp "$tmp/bin" "$LAUNCHER_BIN" && as_root chmod +x "$LAUNCHER_BIN"
		as_root cp "$tmp/lib" "$LAUNCHER_LIB"
		rm -rf "$tmp"
		return 0
	fi
	rm -rf "$tmp"
	return 1
}

patch_launcher() {
	[[ -f "$LAUNCHER_BIN" && -f "$LAUNCHER_LIB" ]] || return 0
	step 'Patch the launcher (a connectors "new window" must not close the existing one)'
	[[ -f "$LAUNCHER_BIN.bak" ]] || as_root cp -p "$LAUNCHER_BIN" "$LAUNCHER_BIN.bak"
	[[ -f "$LAUNCHER_LIB.bak" ]] || as_root cp -p "$LAUNCHER_LIB" "$LAUNCHER_LIB.bak"
	if apply_launcher patch; then
		ok 'Launcher patched: secondary instances leave the primary'"'"'s cowork daemon alone.'
	else
		warn 'Launcher text not in the expected shape (upstream changed?); skipped. Connectors window may still close the existing one.'
	fi
}

restore_launcher() {
	[[ -f "$LAUNCHER_BIN" && -f "$LAUNCHER_LIB" ]] || return 0
	step 'Reverting the launcher fix...'
	if apply_launcher unpatch; then
		ok 'Launcher reverted.'
	else
		warn 'Could not reverse the launcher patch automatically.'
	fi
}

# =============================================================================
# AUTO-UPDATE (systemd system timer)
# =============================================================================
enable_auto_update() {
	step 'Enabling auto-re-patch (systemd timer)...'
	if ! command -v systemctl >/dev/null 2>&1; then
		warn 'systemctl not found; skipping auto-re-patch. Re-run the patcher after a Claude update.'
		return 0
	fi

	local watcher="$STATE_DIR/watcher.sh"
	# The watcher runs as root. It detects an update by comparing the current
	# app.asar SHA-256 against the patched SHA we recorded (no Node, no version
	# parsing); on a mismatch it re-patches from the stable bundle, putting the
	# user's Node bin dir on PATH so npx can run.
	as_root tee "$watcher" >/dev/null <<'WATCHER'
#!/usr/bin/env bash
set -u
state='/var/lib/claude-linux-rtl'
log="$state/watcher.log"
[[ -f "$state/state.env" ]] || { echo "$(date) no state.env" >>"$log"; exit 0; }
# shellcheck disable=SC1090
source "$state/state.env"
[[ -f "${APP_ASAR:-}" ]] || { echo "$(date) no app.asar at ${APP_ASAR:-?}" >>"$log"; exit 0; }
cur=$(sha256sum "$APP_ASAR" | awk '{print $1}')
[[ "$cur" == "${PATCHED_ASAR_SHA:-}" ]] && exit 0
echo "$(date) app.asar changed; re-patching" >>"$log"
[[ -n "${NODE_BIN_DIR:-}" ]] && export PATH="$NODE_BIN_DIR:$PATH"
/bin/bash "$state/app/patch-claude-linux.sh" --yes --no-auto-update >>"$log" 2>&1
WATCHER
	as_root chmod +x "$watcher"

	as_root tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null <<SERVICE
[Unit]
Description=Re-apply the Claude Desktop RTL patch after an update

[Service]
Type=oneshot
ExecStart=/bin/bash $watcher
SERVICE

	as_root tee "/etc/systemd/system/$SERVICE_NAME.timer" >/dev/null <<TIMER
[Unit]
Description=Periodic check to re-apply the Claude Desktop RTL patch

[Timer]
OnBootSec=5min
OnUnitActiveSec=3h
Persistent=true

[Install]
WantedBy=timers.target
TIMER

	as_root systemctl daemon-reload 2>/dev/null
	if as_root systemctl enable --now "$SERVICE_NAME.timer" 2>/dev/null; then
		ok "Auto-re-patch enabled ($SERVICE_NAME.timer)."
		log "Watcher log: $STATE_DIR/watcher.log"
	else
		warn 'Could not enable the systemd timer.'
	fi
}

disable_auto_update() {
	step 'Disabling auto-re-patch...'
	if command -v systemctl >/dev/null 2>&1; then
		as_root systemctl disable --now "$SERVICE_NAME.timer" 2>/dev/null
		as_root systemctl daemon-reload 2>/dev/null
	fi
	as_root rm -f "/etc/systemd/system/$SERVICE_NAME.service" "/etc/systemd/system/$SERVICE_NAME.timer"
	ok 'Auto-re-patch disabled.'
}

# =============================================================================
# RESTORE
# =============================================================================
restore_patch() {
	local app_dir; app_dir=$(find_claude_app)
	[[ -n "$app_dir" ]] || die 'Claude Desktop install not found.'
	local asar; asar=$(find_asar "$app_dir") || die "app.asar not found under $app_dir"

	quit_claude "$app_dir"
	step 'Restoring original app.asar from backup...'
	if [[ -f "$asar.bak" ]]; then
		as_root cp -p "$asar.bak" "$asar" && ok 'app.asar restored.'
	else
		warn 'No app.asar.bak found — nothing to restore.'
	fi
	restore_launcher
	# An explicit restore means "stop" — turn the watcher off + drop the shortcut.
	disable_auto_update
	remove_shortcut

	if [[ $EUID -ne 0 && -x /usr/bin/claude-desktop ]]; then
		setsid /usr/bin/claude-desktop >/dev/null 2>&1 < /dev/null &
		disown 2>/dev/null
	fi
	printf '\n\033[32m=== Restore complete ===\033[0m\n\n'
}

# =============================================================================
[[ "$(uname)" == 'Linux' ]] || die 'This patcher is for Linux. Use patch-claude-windows.ps1 (Windows) or patch-claude-macos.sh (macOS).'

case "$ACTION" in
	install)             install_patch ;;
	restore)             restore_patch ;;
	enable-auto-update)  enable_auto_update ;;
	disable-auto-update) disable_auto_update ;;
esac
