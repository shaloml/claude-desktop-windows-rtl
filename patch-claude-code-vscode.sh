#!/usr/bin/env bash
#
# In-place patcher for the Claude Code VS Code extension (auto-RTL).
#
# The extension renders its sidebar UI as a plain webview — <ext>/webview/index.js
# + index.css on disk, no asar, no integrity hash, no code-signing, owned by the
# user. So this patcher just appends two payloads (a dir="auto" stamper + a small
# CSS guard) between sentinel comments. Result: Hebrew paragraphs flip to RTL and
# right-align on their own, English and code stay LTR. No toggle, fully automatic.
#
# Runs on macOS AND Linux — the webview files sit at the same relative path under
# ~/.vscode/extensions on both. Same idempotency model (back up the originals to
# *.bak on first run, restore-from-bak before every re-patch) and the same
# auto-re-patch idea (re-applies after the extension auto-updates into a fresh,
# pristine folder) — via a launchd LaunchAgent on macOS, a systemd --user timer
# on Linux. (Windows uses patch-claude-code-vscode.ps1.)
#
# Usage:
#   ./patch-claude-code-vscode.sh                  # install (prompts first)
#   ./patch-claude-code-vscode.sh --restore        # revert index.js/index.css
#   ./patch-claude-code-vscode.sh --yes            # unattended (auto-approve)
#   ./patch-claude-code-vscode.sh --no-auto-update # skip the re-patch LaunchAgent
#   ./patch-claude-code-vscode.sh --enable-auto-update | --disable-auto-update
#
# After patching, reload the webview: VS Code command palette ->
# "Developer: Reload Window" (or just restart VS Code).

set -u

# --- config -----------------------------------------------------------------
# Cross-platform (macOS + Linux). The Claude Code webview files live at the same
# relative path under ~/.vscode/extensions on both; only the state dir and the
# auto-re-patch mechanism (launchd on macOS / systemd --user on Linux) differ.
OS="$(uname)"
case "$OS" in
	Darwin) STATE_DIR="$HOME/Library/Application Support/ClaudeCodeVscodeRtl" ;;
	Linux)  STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-code-vscode-rtl" ;;
	*)      STATE_DIR='' ;;   # unsupported; validated in the dispatcher below
esac
PLIST_LABEL='com.shaloml.claude-code-vscode-rtl.autopatch'   # macOS launchd label
SERVICE_NAME='claude-code-vscode-rtl'                        # Linux systemd --user unit
SENTINEL_BEGIN='/* >>> claude-code-rtl (auto) >>> */'
SENTINEL_END='/* <<< claude-code-rtl (auto) <<< */'

ASSUME_YES=0
NO_AUTO_UPDATE=0
ACTION='install'

# --- colored logging --------------------------------------------------------
# Diagnostics go to stderr so $(...) capture grabs only a function's real value.
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
	[[ $ASSUME_YES -eq 1 ]] && { log "$1 -> auto-yes (--yes)"; return 0; }
	local ans
	read -r -p "$1 [Y/n] " ans
	[[ -z "$ans" || "$ans" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# Portable file mtime (epoch seconds). Must branch on OS, NOT chain `stat -f ||
# stat -c`: on Linux `stat -f %m` is "filesystem mode", which prints a multi-line
# fs summary to stdout for the real operand before failing — that junk would leak
# into the captured value and break the numeric comparison in find_ext_dir.
file_mtime() {
	case "$OS" in
		Darwin) stat -f %m "$1" 2>/dev/null || echo 0 ;;
		*)      stat -c %Y "$1" 2>/dev/null || echo 0 ;;
	esac
}

# --- locate the Claude Code extension ---------------------------------------
# Search the editors that can host it; pick the most recently modified install
# that actually has a webview (so during an update we patch the NEW folder).
find_ext_dir() {
	local roots=(
		"$HOME/.vscode/extensions"
		"$HOME/.vscode-insiders/extensions"
		"$HOME/.cursor/extensions"
		"$HOME/.windsurf/extensions"
	)
	local best='' best_t=0 root d t
	for root in "${roots[@]}"; do
		[[ -d "$root" ]] || continue
		for d in "$root"/anthropic.claude-code-*; do
			[[ -f "$d/webview/index.js" && -f "$d/webview/index.css" ]] || continue
			t=$(file_mtime "$d")
			if [[ "$t" -ge "$best_t" ]]; then best_t="$t"; best="$d"; fi
		done
	done
	[[ -n "$best" ]] && { printf '%s' "$best"; return 0; }
	return 1
}

# --- resolve the two payload files (repo src/, or a flat bundle) -------------
resolve_src_dir() {
	local script_dir; script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
	if [[ -f "$script_dir/src/vscode-rtl-inject.js" ]]; then
		printf '%s' "$script_dir/src"; return 0
	fi
	if [[ -f "$script_dir/vscode-rtl-inject.js" ]]; then
		printf '%s' "$script_dir"; return 0
	fi
	return 1
}

# =============================================================================
# PREFLIGHT
# =============================================================================
preflight() {
	step 'Checking prerequisites...'
	local ext_dir; ext_dir=$(find_ext_dir)
	{
		printf '\n  Prerequisite check\n'
		if [[ -n "$ext_dir" ]]; then printf '  [+] Claude Code extension   %s\n' "$ext_dir"
		else printf '  [X] Claude Code extension   NOT FOUND\n'; fi
		printf '\n'
	} >&2
	[[ -n "$ext_dir" ]] || die "The Claude Code VS Code extension was not found. Install it from the VS Code Marketplace, then re-run."
	confirm 'Patch the Claude Code webview for auto-RTL now?' || die 'Aborted by user.'
	printf '%s' "$ext_dir"
}

# =============================================================================
# INSTALL
# =============================================================================
install_patch() {
	# preflight runs in a subshell ($(...)), so its die/abort can't exit us — an
	# empty return means "not found" or "user declined"; stop cleanly here.
	local ext_dir; ext_dir=$(preflight)
	[[ -n "$ext_dir" ]] || exit 1
	local css="$ext_dir/webview/index.css"
	local js="$ext_dir/webview/index.js"
	local src_dir; src_dir=$(resolve_src_dir) || die 'Payload files (vscode-rtl-inject.*) not found next to this script.'

	[[ -w "$css" && -w "$js" ]] || die "Webview files are not writable: $ext_dir/webview (check permissions)."

	# Safety: if there's already an injection but no backup, we can't recover the
	# pristine file — refuse rather than baking the patch into the .bak.
	if [[ ! -f "$css.bak" ]] && grep -qF "$SENTINEL_BEGIN" "$css" 2>/dev/null; then
		die "index.css already contains an injection but has no .bak. Reinstall the extension, then re-run."
	fi
	if [[ ! -f "$js.bak" ]] && grep -qF "$SENTINEL_BEGIN" "$js" 2>/dev/null; then
		die "index.js already contains an injection but has no .bak. Reinstall the extension, then re-run."
	fi

	step 'Backing up pristine webview files (first run only)...'
	[[ -f "$css.bak" ]] || { cp -p "$css" "$css.bak"; ok 'index.css.bak'; }
	[[ -f "$js.bak" ]]  || { cp -p "$js"  "$js.bak";  ok 'index.js.bak'; }

	step 'Restoring originals before re-injecting (idempotency)...'
	cp -p "$css.bak" "$css"
	cp -p "$js.bak"  "$js"

	step 'Injecting auto-RTL payloads...'
	# CSS: the linked stylesheet allows the appended block to apply directly.
	{
		printf '\n%s\n' "$SENTINEL_BEGIN"
		cat "$src_dir/vscode-rtl-inject.css"
		printf '%s\n' "$SENTINEL_END"
	} >> "$css"
	ok 'index.css <- vscode-rtl-inject.css'
	# JS: lead with a bare ';' so we never glue onto a trailing call expression
	# in the minified bundle; the payload runs under the page's existing nonce.
	{
		printf '\n;\n%s\n' "$SENTINEL_BEGIN"
		cat "$src_dir/vscode-rtl-inject.js"
		printf '%s\n' "$SENTINEL_END"
	} >> "$js"
	ok 'index.js <- vscode-rtl-inject.js'

	mkdir -p "$STATE_DIR"
	write_state "$ext_dir"
	save_stable_bundle "$src_dir"

	if [[ $NO_AUTO_UPDATE -eq 1 ]]; then
		log 'Auto-re-patch skipped (--no-auto-update). Re-run after an extension update, or use --enable-auto-update.'
	else
		enable_auto_update
	fi

	printf '\n\033[32m=== PATCH COMPLETE ===\033[0m\n' >&2
	printf '\033[33m    Reload the webview: VS Code -> "Developer: Reload Window" (or restart VS Code).\033[0m\n\n' >&2
}

# --- patch state ------------------------------------------------------------
write_state() {
	# Identity = the extension folder path; the watcher re-patches when it changes
	# (an update lands in a new versioned folder) or when the injection is gone.
	printf '{"patchedExtPath":"%s"}\n' "$1" > "$STATE_DIR/state.json"
}

save_stable_bundle() {
	local src="$1"
	local dst="$STATE_DIR/app"
	rm -rf "$dst"; mkdir -p "$dst"
	cp "${BASH_SOURCE[0]}" "$dst/patch-claude-code-vscode.sh"
	chmod +x "$dst/patch-claude-code-vscode.sh"
	cp "$src/vscode-rtl-inject.js"  "$dst/vscode-rtl-inject.js"
	cp "$src/vscode-rtl-inject.css" "$dst/vscode-rtl-inject.css"
}

# =============================================================================
# AUTO-UPDATE (launchd LaunchAgent on macOS / systemd --user timer on Linux)
# =============================================================================
enable_auto_update() {
	case "$OS" in
		Darwin) enable_auto_update_macos ;;
		Linux)  enable_auto_update_linux ;;
	esac
}

disable_auto_update() {
	step 'Disabling auto-re-patch...'
	case "$OS" in
		Darwin) disable_auto_update_macos ;;
		Linux)  disable_auto_update_linux ;;
	esac
}

enable_auto_update_macos() {
	step 'Enabling auto-re-patch (LaunchAgent)...'
	local agent_dir="$HOME/Library/LaunchAgents"
	local plist="$agent_dir/$PLIST_LABEL.plist"
	local watcher="$STATE_DIR/watcher.sh"
	mkdir -p "$agent_dir"

	cat > "$watcher" <<'WATCHER'
#!/usr/bin/env bash
# Auto-re-patch watcher: re-applies auto-RTL after the Claude Code extension
# updates into a fresh folder (or if VS Code restores the webview files).
set -u
state="$HOME/Library/Application Support/ClaudeCodeVscodeRtl"
patcher="$state/app/patch-claude-code-vscode.sh"
log="$state/watcher.log"
sentinel='/* >>> claude-code-rtl (auto) >>> */'

find_ext_dir() {
	local roots=(
		"$HOME/.vscode/extensions" "$HOME/.vscode-insiders/extensions"
		"$HOME/.cursor/extensions" "$HOME/.windsurf/extensions"
	)
	local best='' best_t=0 root d t
	for root in "${roots[@]}"; do
		[[ -d "$root" ]] || continue
		for d in "$root"/anthropic.claude-code-*; do
			[[ -f "$d/webview/index.js" ]] || continue
			t=$(stat -f %m "$d" 2>/dev/null || echo 0)
			[[ "$t" -ge "$best_t" ]] && { best_t="$t"; best="$d"; }
		done
	done
	[[ -n "$best" ]] && printf '%s' "$best"
}

cur=$(find_ext_dir)
[[ -z "$cur" ]] && { echo "$(date) no extension found" >>"$log"; exit 0; }
recorded=$(/usr/bin/sed -n 's/.*"patchedExtPath":"\([^"]*\)".*/\1/p' "$state/state.json" 2>/dev/null)

if [[ "$cur" == "$recorded" ]] && /usr/bin/grep -qF "$sentinel" "$cur/webview/index.js" 2>/dev/null; then
	exit 0
fi
echo "$(date) re-patching ($recorded -> $cur)" >>"$log"
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
		warn 'After an auto-re-patch you still need to reload the VS Code window once.'
	else
		warn 'Could not load the LaunchAgent.'
	fi
}

disable_auto_update_macos() {
	local plist="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
	launchctl unload "$plist" 2>/dev/null
	rm -f "$plist"
	ok 'Auto-re-patch disabled.'
}

# --- Linux auto-re-patch (systemd --user timer) -----------------------------
# The webview files are user-owned, so no root is needed — a per-user systemd
# timer re-applies the injection after the extension updates into a fresh folder.
enable_auto_update_linux() {
	step 'Enabling auto-re-patch (systemd --user timer)...'
	if ! command -v systemctl >/dev/null 2>&1; then
		warn 'systemctl not found; skipping auto-re-patch. Re-run after an extension update.'
		return 0
	fi
	local watcher="$STATE_DIR/watcher.sh"
	local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	mkdir -p "$unit_dir" "$STATE_DIR"

	# STATE_DIR is interpolated in; all runtime $-expansions are escaped (\$).
	cat > "$watcher" <<WATCHER
#!/usr/bin/env bash
# Auto-re-patch watcher: re-applies auto-RTL after the Claude Code extension
# updates into a fresh folder (or if VS Code restores the webview files).
set -u
state="$STATE_DIR"
patcher="\$state/app/patch-claude-code-vscode.sh"
log="\$state/watcher.log"
sentinel='/* >>> claude-code-rtl (auto) >>> */'
file_mtime() { stat -c %Y "\$1" 2>/dev/null || echo 0; }
find_ext_dir() {
	local roots=(
		"\$HOME/.vscode/extensions" "\$HOME/.vscode-insiders/extensions"
		"\$HOME/.cursor/extensions" "\$HOME/.windsurf/extensions"
	)
	local best='' best_t=0 root d t
	for root in "\${roots[@]}"; do
		[[ -d "\$root" ]] || continue
		for d in "\$root"/anthropic.claude-code-*; do
			[[ -f "\$d/webview/index.js" ]] || continue
			t=\$(file_mtime "\$d")
			[[ "\$t" -ge "\$best_t" ]] && { best_t="\$t"; best="\$d"; }
		done
	done
	[[ -n "\$best" ]] && printf '%s' "\$best"
}
cur=\$(find_ext_dir)
[[ -z "\$cur" ]] && { echo "\$(date) no extension found" >>"\$log"; exit 0; }
recorded=\$(sed -n 's/.*"patchedExtPath":"\([^"]*\)".*/\1/p' "\$state/state.json" 2>/dev/null)
if [[ "\$cur" == "\$recorded" ]] && grep -qF "\$sentinel" "\$cur/webview/index.js" 2>/dev/null; then
	exit 0
fi
echo "\$(date) re-patching (\$recorded -> \$cur)" >>"\$log"
/bin/bash "\$patcher" --yes --no-auto-update >>"\$log" 2>&1
WATCHER
	chmod +x "$watcher"

	cat > "$unit_dir/$SERVICE_NAME.service" <<SERVICE
[Unit]
Description=Re-apply Claude Code VS Code auto-RTL after an extension update

[Service]
Type=oneshot
ExecStart=/bin/bash $watcher
SERVICE

	cat > "$unit_dir/$SERVICE_NAME.timer" <<TIMER
[Unit]
Description=Periodic check to re-apply Claude Code VS Code auto-RTL

[Timer]
OnBootSec=3min
OnUnitActiveSec=3h
Persistent=true

[Install]
WantedBy=timers.target
TIMER

	systemctl --user daemon-reload 2>/dev/null
	if systemctl --user enable --now "$SERVICE_NAME.timer" 2>/dev/null; then
		ok "Auto-re-patch enabled ($SERVICE_NAME.timer, systemd --user)."
		log "Watcher log: $STATE_DIR/watcher.log"
		warn 'After an auto-re-patch you still need to reload the VS Code window once.'
	else
		warn 'Could not enable the systemd --user timer (no user session bus?).'
	fi
}

disable_auto_update_linux() {
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user disable --now "$SERVICE_NAME.timer" 2>/dev/null
	fi
	local unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
	rm -f "$unit_dir/$SERVICE_NAME.service" "$unit_dir/$SERVICE_NAME.timer"
	command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload 2>/dev/null
	ok 'Auto-re-patch disabled.'
}

# =============================================================================
# RESTORE
# =============================================================================
restore_patch() {
	local ext_dir; ext_dir=$(find_ext_dir)
	[[ -n "$ext_dir" ]] || die 'Claude Code extension not found.'
	local css="$ext_dir/webview/index.css"
	local js="$ext_dir/webview/index.js"

	step 'Restoring original webview files from backup...'
	[[ -f "$css.bak" ]] && { cp -p "$css.bak" "$css"; ok 'index.css restored'; } || warn 'no index.css.bak'
	[[ -f "$js.bak" ]]  && { cp -p "$js.bak"  "$js";  ok 'index.js restored'; }  || warn 'no index.js.bak'
	disable_auto_update
	printf '\n\033[32m=== Restore complete (reload the VS Code window) ===\033[0m\n\n' >&2
}

# =============================================================================
[[ -n "$STATE_DIR" ]] || die "Unsupported OS: $OS (this patcher targets macOS and Linux)."

case "$ACTION" in
	install)             install_patch ;;
	restore)             restore_patch ;;
	enable-auto-update)  enable_auto_update ;;
	disable-auto-update) disable_auto_update ;;
esac
