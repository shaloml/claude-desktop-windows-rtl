// Linux-only wrapper for Claude Desktop extensions.
//
// Sibling of win-wrapper.js / mac-wrapper.js. Loaded by linux-entry.js BEFORE the
// app's original main bundle, attaches one `web-contents-created` listener, and
// every window/webview gets:
//   - RTL CSS/JS injection             (reused from rtl-support.js)
//   - a floating "+חלון" new-window button (our own — see below)
//   - a right-click menu: RTL toggle, רענן דף (reload), תרגם לעברית (translate),
//     TWO "new window" items (see below), and a version label.
//
// TWO kinds of "new window", because Claude Desktop is one-window-per-profile and
// cannot give both at once:
//   1. IN-PROCESS (היסטוריה משותפת) — a new BrowserWindow in THIS process. Shares
//      the session + user-data-dir, so it's logged in and shares Cowork history.
//      The app does NOT manage this window (it's "unknown" to the app's internal
//      window pool), so MCP connectors are NOT wired into it.
//   2. SEPARATE INSTANCE (עם connectors) — multi-instance-support.js's
//      openNewInstance(), i.e. the launcher's `--new-window`: a separate process
//      with its own `Claude-instance-N` profile. The app fully manages it, so MCP
//      connectors work — but its Cowork history starts blank (separate profile).
// The floating button uses #1 (the common case). Both are in the right-click menu.
//
// The in-process button emits a PRIVATE trigger (NEW_WINDOW_TRIGGER), NOT the
// shared multi-instance-support.js CONSOLE_TRIGGER, so the host frame-fix-wrapper's
// bridge never also turns the click into a separate process (that double-fire is
// what closed the other window before).
//
// This file does NOT do Linux frame/tray/WCO handling — a claude-desktop-debian
// build owns that via its own frame-fix-wrapper. RTL_JS self-guards and the button
// uses a stable id, so re-injection is idempotent.

'use strict';

const { app, BrowserWindow, Menu, MenuItem, clipboard } = require('electron');

// Shared, platform-agnostic modules copied alongside this file by the patcher.
const { RTL_CSS, RTL_JS } = require('./rtl-support.js');
const translateSupport = require('./translate-support.js');
const multiInstance = require('./multi-instance-support.js');

// ---- labels ----
const RTL_TOGGLE_LABEL = 'הפעל/בטל RTL (כיוון טקסט)';
const REFRESH_LABEL = 'רענן דף';
const TRANSLATE_LABEL = translateSupport.TRANSLATE_CONTEXT_MENU_LABEL;
const NEW_WINDOW_SHARED_LABEL = 'פתח חלון חדש (היסטוריה משותפת)';
const NEW_WINDOW_CONNECTORS_LABEL = 'פתח חלון חדש (עם connectors)';
const VERSION_LABEL_PREFIX = 'Claude Desktop v';

// Private new-window trigger — distinct from multi-instance-support.js's shared
// CONSOLE_TRIGGER, so the host frame-fix-wrapper's bridge (which spawns a separate
// process) never fires for our button. Only our own bridge reacts.
const NEW_WINDOW_TRIGGER = '[ClaudeLocalRTL] new-window';

const APP_VERSION = (() => {
	try {
		return app.getVersion();
	} catch {
		return '';
	}
})();

// ---------------------------------------------------------------------------
// New window #1 — in-process (shares session + Cowork history)
// ---------------------------------------------------------------------------
function openNewWindow() {
	try {
		// Reuse an existing window's bounds/URL/session so the new one looks and
		// behaves like the original and lands on the same logged-in surface.
		const src = BrowserWindow.getFocusedWindow()
			|| BrowserWindow.getAllWindows().find((w) => !w.isDestroyed());

		let url = 'https://claude.ai/new';
		let session;
		if (src && !src.isDestroyed()) {
			try {
				const cur = src.webContents.getURL();
				if (cur && /^https?:/i.test(cur)) url = cur;
			} catch {}
			try { session = src.webContents.session; } catch {}
		}

		const opts = {
			width: 1280,
			height: 860,
			show: false,
			autoHideMenuBar: true,
			title: 'Claude',
			webPreferences: session ? { session } : {},
		};
		// Cascade off the source window so the new one doesn't land exactly on top.
		try {
			if (src && !src.isDestroyed()) {
				const b = src.getBounds();
				opts.x = b.x + 36;
				opts.y = b.y + 36;
			}
		} catch {}

		const win = new BrowserWindow(opts);
		win.once('ready-to-show', () => win.show());
		win.loadURL(url);
		console.log('[Multi-Window] opened new in-process window ->', url);
		return true;
	} catch (e) {
		console.error('[Multi-Window] failed to open new window:', e.message);
		return false;
	}
}

// Debounced entry points. A click can reach us more than once in quick succession
// (button + accidental double-click); a shared ~1.5s guard keeps it to one window.
let lastNewWindowAt = 0;
function debounced(fn) {
	const now = Date.now();
	if (now - lastNewWindowAt < 1500) return false;
	lastNewWindowAt = now;
	return fn();
}
function newWindow() { return debounced(openNewWindow); }

// New window #2 — separate instance (the launcher's --new-window). Fully
// app-managed, so MCP connectors work; its Cowork history is a fresh profile.
function openNewInstanceWindow() {
	return debounced(() => {
		try {
			return multiInstance.openNewInstance();
		} catch (e) {
			console.error('[Multi-Window] openNewInstance failed:', e && e.message);
			return false;
		}
	});
}

// ---- injection + menu wiring ----

// Our own floating "+חלון" button. It emits our PRIVATE trigger (so the new window
// stays in-process), unlike multi-instance-support.js's button.
const NEW_WINDOW_BUTTON_CSS = `
	#claude-rtl-newwindow-btn {
		position: fixed;
		top: 12px;
		right: 88px;
		z-index: 99999;
		background: rgba(0, 0, 0, 0.7);
		color: white;
		border: 1px solid rgba(255, 255, 255, 0.3);
		border-radius: 8px;
		padding: 8px 12px;
		font-size: 13px;
		font-weight: 700;
		cursor: pointer;
		font-family: system-ui, -apple-system, sans-serif;
		transition: all 0.2s ease;
		user-select: none;
	}
	#claude-rtl-newwindow-btn:hover {
		background: rgba(0, 0, 0, 0.9);
		transform: scale(1.05);
	}
	@media (prefers-color-scheme: dark) {
		#claude-rtl-newwindow-btn {
			background: rgba(255, 255, 255, 0.15);
			border-color: rgba(255, 255, 255, 0.25);
		}
		#claude-rtl-newwindow-btn:hover {
			background: rgba(255, 255, 255, 0.25);
		}
	}
`;

const NEW_WINDOW_BUTTON_JS = `(function() {
	'use strict';
	if (window.claudeRtlNewWindowInit) return;
	window.claudeRtlNewWindowInit = true;
	function trigger() {
		// Picked up ONLY by our own console-message bridge (private trigger).
		console.log(${JSON.stringify(NEW_WINDOW_TRIGGER)});
	}
	window.claudeOpenNewWindow = trigger;
	function ensureButton() {
		if (document.getElementById('claude-rtl-newwindow-btn')) return;
		if (!document.body) return;
		var btn = document.createElement('button');
		btn.id = 'claude-rtl-newwindow-btn';
		btn.textContent = '+חלון';
		btn.title = 'פתח חלון חדש (אותו תהליך — חולק התחברות והיסטוריה/Cowork)';
		btn.addEventListener('click', trigger);
		document.body.appendChild(btn);
	}
	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', ensureButton);
	} else {
		ensureButton();
	}
	// Re-create if SPA navigation removes it.
	setInterval(ensureButton, 2000);
})();`;

// Linux button offset: empty by default (the verified build uses the module
// defaults unchanged). Tunable per desktop environment if buttons ever collide.
const LINUX_BUTTON_OFFSET_CSS = '';

// Inject a CSS string by appending a <style> with a stable id (idempotent).
function injectCss(wc, id, css) {
	if (!css) return;
	const js =
		`(function(){if(document.getElementById(${JSON.stringify(id)}))return;` +
		`var s=document.createElement('style');s.id=${JSON.stringify(id)};` +
		`s.textContent=${JSON.stringify(css)};` +
		`(document.head||document.documentElement).appendChild(s);})();`;
	try { wc.executeJavaScript(js, true).catch(() => {}); } catch {}
}

function injectAll(wc) {
	// RTL: stylesheet + behavior script. RTL_JS self-guards via
	// window.claudeRTLInitialized, exposes window.claudeRTLToggle, and builds
	// its own floating toggle button.
	injectCss(wc, 'claude-rtl-css', RTL_CSS);
	try { wc.executeJavaScript(RTL_JS, true).catch(() => {}); } catch {}
	// Our in-process "+חלון" button (private trigger; stays in this process).
	injectCss(wc, 'claude-rtl-newwindow-css', NEW_WINDOW_BUTTON_CSS);
	try { wc.executeJavaScript(NEW_WINDOW_BUTTON_JS, true).catch(() => {}); } catch {}
	// Linux-only: optional offset for the floating buttons (empty by default).
	injectCss(wc, 'claude-linux-btn-offset', LINUX_BUTTON_OFFSET_CSS);
}

function buildContextMenu(wc) {
	const menu = new Menu();
	menu.append(new MenuItem({
		label: RTL_TOGGLE_LABEL,
		click: () => {
			// rtl-support.js exposes window.claudeRTLToggle (toggles, no reload).
			wc.executeJavaScript('window.claudeRTLToggle && window.claudeRTLToggle()', true)
				.catch(() => {});
		},
	}));
	menu.append(new MenuItem({
		label: REFRESH_LABEL,
		accelerator: 'CmdOrCtrl+R',
		click: () => { try { wc.reload(); } catch {} },
	}));
	menu.append(new MenuItem({
		label: TRANSLATE_LABEL,
		click: () => { translateSupport.translatePage(wc).catch(() => {}); },
	}));
	menu.append(new MenuItem({ type: 'separator' }));
	// Two new-window flavors (see file header): shared-history vs connectors.
	menu.append(new MenuItem({
		label: NEW_WINDOW_SHARED_LABEL,
		click: () => { newWindow(); },
	}));
	menu.append(new MenuItem({
		label: NEW_WINDOW_CONNECTORS_LABEL,
		click: () => { openNewInstanceWindow(); },
	}));
	menu.append(new MenuItem({ type: 'separator' }));
	menu.append(new MenuItem({
		label: `${VERSION_LABEL_PREFIX}${APP_VERSION}`,
		click: () => { try { clipboard.writeText(APP_VERSION); } catch {} },
	}));
	return menu;
}

// The renderer's floating "+חלון" button logs our PRIVATE NEW_WINDOW_TRIGGER;
// catch it here and open an in-process window. Handler is version-agnostic.
function setupBridge(wc) {
	try {
		wc.on('console-message', (...args) => {
			// Electron <37: (event, level, message, line, sourceId)
			// Electron >=37: (event) where event.message holds the text.
			const first = args[0];
			const message = (first && typeof first === 'object' && 'message' in first)
				? first.message
				: args[2];
			if (typeof message === 'string' && message.includes(NEW_WINDOW_TRIGGER)) {
				newWindow();
			}
		});
	} catch {}
}

function hookWebContents(wc) {
	try {
		injectAll(wc);
		wc.on('did-finish-load', () => injectAll(wc));
		wc.on('context-menu', () => { buildContextMenu(wc).popup(); });
		setupBridge(wc);
	} catch {}
}

// We install our own web-contents hook unconditionally (RTL + button + menu). On a
// claude-desktop-debian build the host frame-fix-wrapper.js also exists, but our
// wrapper is what reliably renders RTL and the floating button. We do NOT defer to
// the host (an earlier deferral attempt removed RTL/button entirely), and we avoid
// its separate-process bridge via our private trigger.
let installed = false;
function install() {
	if (installed) return;
	installed = true;
	try {
		app.on('web-contents-created', (_e, wc) => hookWebContents(wc));
	} catch (e) {
		console.error('[Claude Linux Wrapper] install failed:', e.message);
	}
}

module.exports = { install, hookWebContents, openNewWindow };
