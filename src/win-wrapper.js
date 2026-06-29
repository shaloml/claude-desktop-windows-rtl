// Windows-only wrapper for Claude Desktop extensions.
//
// Unlike scripts/frame-fix-wrapper.js (Linux: frame/tray/WCO/cowork), this is a
// minimal, cross-platform feature shim for the official Windows app. It is loaded
// by win-entry.js BEFORE the original main bundle and attaches a single
// `web-contents-created` listener, so every window/webview created by the app
// gets:
//   - RTL CSS/JS injection             (reused from scripts/rtl-support.js)
//   - a multi-instance floating button (reused from multi-instance-support.js)
//   - a right-click menu: RTL toggle, רענן דף (reload), תרגם לעברית (translate),
//     new window, and a version label that copies to clipboard
//
// The patcher (patch-claude-windows.ps1) copies this file plus the three support
// modules into the asar next to package.json and points `main` at win-entry.js.

'use strict';

const { app, BrowserWindow, Menu, MenuItem, clipboard } = require('electron');

// Support modules are copied alongside this file by the patcher.
// rtl-support exports RTL_CSS + RTL_JS (NOT a single bundle); RTL_JS exposes
// window.claudeRTLToggle and creates its own floating toggle button.
const { RTL_CSS, RTL_JS } = require('./rtl-support.js');
const translateSupport = require('./translate-support.js');
const multiInstance = require('./multi-instance-support.js');

// ---- labels (mirror the Linux wrapper) ----
const RTL_TOGGLE_LABEL = 'הפעל/בטל RTL (כיוון טקסט)';
const REFRESH_LABEL = 'רענן דף';
const TRANSLATE_LABEL = translateSupport.TRANSLATE_CONTEXT_MENU_LABEL;
const NEW_WINDOW_LABEL = 'פתח חלון חדש';
const VERSION_LABEL_PREFIX = 'Claude Desktop v';

const APP_VERSION = (() => {
	try {
		return app.getVersion();
	} catch {
		return '';
	}
})();

// ---------------------------------------------------------------------------
// New window — in-process (NOT a second OS process)
//
// We deliberately do NOT spawn a second claude.exe. That route hit two walls on
// the Windows MSIX build: (1) the app's own single-instance gate
// ("Not main instance, returning early from app ready") makes a second process
// exit before showing a window, and (2) a separate --user-data-dir is a blank
// profile that demands a fresh login the OAuth callback can't complete.
//
// Instead we open another BrowserWindow inside THIS process. It shares the
// default Electron session, so it is already authenticated (same account, same
// cookies/token) and shares the MCP/runtime context. The app's
// `web-contents-created` event fires for this window too, so our own
// hookWebContents() injects RTL + buttons + the context menu automatically.
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

		const win = new BrowserWindow({
			width: 1280,
			height: 860,
			show: false,
			autoHideMenuBar: true,
			title: 'Claude',
			webPreferences: session ? { session } : {},
		});
		win.once('ready-to-show', () => win.show());
		win.loadURL(url);
		console.log('[Multi-Window] opened new in-process window ->', url);
		return true;
	} catch (e) {
		console.error('[Multi-Window] failed to open new window:', e.message);
		return false;
	}
}

// ---- injection + menu wiring (mirrors frame-fix-wrapper's contract) ----

// Windows-only reposition: the shared rtl-support / multi-instance modules pin
// the floating RTL panel (top-center) and the +window button near the top, which
// can collide with the Windows title-bar overlay / window controls. Push them
// down. Injected as an override so the shared modules stay untouched (Linux keeps
// its own positions).
const WIN_BUTTON_OFFSET_CSS = `
	#claude-rtl-panel { top: 46px !important; }
	#claude-new-instance-floating-btn { top: 62px !important; }
`;

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
	// Multi-window: floating "+חלון" button + its styles.
	injectCss(wc, 'claude-mi-css', multiInstance.MULTI_INSTANCE_BUTTON_CSS);
	try { wc.executeJavaScript(multiInstance.MULTI_INSTANCE_BUTTON_JS, true).catch(() => {}); } catch {}
	// Windows-only: nudge both floating buttons clear of the window controls.
	injectCss(wc, 'claude-win-btn-offset', WIN_BUTTON_OFFSET_CSS);
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
		click: () => { try { wc.reload(); } catch {} },
	}));
	menu.append(new MenuItem({
		label: TRANSLATE_LABEL,
		click: () => { translateSupport.translatePage(wc).catch(() => {}); },
	}));
	menu.append(new MenuItem({
		label: NEW_WINDOW_LABEL,
		click: () => { openNewWindow(); },
	}));
	menu.append(new MenuItem({ type: 'separator' }));
	menu.append(new MenuItem({
		label: `${VERSION_LABEL_PREFIX}${APP_VERSION}`,
		click: () => { try { clipboard.writeText(APP_VERSION); } catch {} },
	}));
	return menu;
}

// The renderer's floating "+חלון" button logs multiInstance.CONSOLE_TRIGGER;
// catch it here and open a new window. Handler is Electron-version-agnostic.
function setupBridge(wc) {
	try {
		wc.on('console-message', (...args) => {
			// Electron <37: (event, level, message, line, sourceId)
			// Electron >=37: (event) where event.message holds the text.
			const first = args[0];
			const message = (first && typeof first === 'object' && 'message' in first)
				? first.message
				: args[2];
			if (multiInstance.isTriggerMessage(message)) openNewWindow();
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

let installed = false;
function install() {
	if (installed) return;
	installed = true;
	try {
		app.on('web-contents-created', (_e, wc) => hookWebContents(wc));
	} catch (e) {
		console.error('[Claude Win Wrapper] install failed:', e.message);
	}
}

module.exports = { install, hookWebContents, openNewWindow };
