// macOS wrapper for Claude Desktop extensions.
//
// Sibling of win-wrapper.js. Same contract — loaded by mac-entry.js BEFORE the
// app's original main bundle, attaches one `web-contents-created` listener, and
// every window/webview gets RTL injection, the multi-window button, and the
// right-click menu (RTL toggle, refresh, translate, new window, version label).
//
// macOS differences vs Windows:
//   - Window controls (traffic lights) are TOP-LEFT, not top-right, so the
//     floating buttons (which sit top-right) don't collide with them. We apply
//     only a small top offset to clear claude.ai's own in-app topbar; tune
//     MAC_BUTTON_OFFSET_CSS after visual testing.
//   - Everything else (in-process new window, injection, menu) is identical.

'use strict';

const { app, BrowserWindow, Menu, MenuItem, clipboard } = require('electron');

// Shared, platform-agnostic modules copied alongside this file by the patcher.
const { RTL_CSS, RTL_JS } = require('./rtl-support.js');
const translateSupport = require('./translate-support.js');
const multiInstance = require('./multi-instance-support.js');

// ---- labels (mirror the Windows wrapper) ----
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
// Same rationale as Windows: opening a second app process fights the app's
// single-instance lock and a separate profile demands a fresh login. Opening
// another BrowserWindow in THIS process shares the authenticated session and
// MCP/runtime context, and our web-contents-created hook decorates it too.
// ---------------------------------------------------------------------------
function openNewWindow() {
	try {
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

		// Cascade off the source window so the new one doesn't land exactly on
		// top of it. A standard (framed) title bar is used instead of
		// 'hiddenInset': claude.ai's web page defines no -webkit-app-region drag
		// strip, so a frameless/inset window has nothing to grab and can't be
		// moved (only minimized/resized). A normal title bar is draggable.
		const opts = {
			width: 1280,
			height: 860,
			show: false,
			title: 'Claude',
			webPreferences: session ? { session } : {},
		};
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

// ---- injection + menu wiring ----

// macOS-only nudge: traffic lights are top-LEFT, so the top-RIGHT floating
// buttons don't hit them. A small top offset just clears claude.ai's own
// in-app topbar. Adjust after visual testing (0 is also fine if no overlap).
const MAC_BUTTON_OFFSET_CSS = `
	#claude-rtl-floating-toggle { top: 40px !important; }
	#claude-new-instance-floating-btn { top: 40px !important; }
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
	// macOS-only: small top offset for the floating buttons.
	injectCss(wc, 'claude-mac-btn-offset', MAC_BUTTON_OFFSET_CSS);
}

function buildContextMenu(wc) {
	const menu = new Menu();
	menu.append(new MenuItem({
		label: RTL_TOGGLE_LABEL,
		click: () => {
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

// Renderer's floating "+חלון" button logs multiInstance.CONSOLE_TRIGGER; catch
// it here and open a new window. Handler is Electron-version-agnostic.
function setupBridge(wc) {
	try {
		wc.on('console-message', (...args) => {
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
		console.error('[Claude Mac Wrapper] install failed:', e.message);
	}
}

module.exports = { install, hookWebContents, openNewWindow };
