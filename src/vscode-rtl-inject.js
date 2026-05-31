// Auto-RTL for the Claude Code VS Code webview.
//
// Appended verbatim (between sentinel comments) to
//   <ext>/webview/index.js
// by patch-claude-code-vscode.sh. The webview links that file with the page's
// CSP nonce, so this code inherits the nonce for free — no host-side edit needed.
//
// Strategy: decide each text block's direction from its first strong character
// and pin it explicitly (dir="rtl" / dir="ltr"). We do NOT use dir="auto": that
// is re-evaluated live by the browser, so while a response streams the first
// strong char keeps changing and the paragraph oscillates left/right (eye-
// searing flicker). Instead we compute the direction once and LOCK it — once a
// block is decided it never flips again — so a Hebrew paragraph settles RTL on
// its first Hebrew glyph and stays there. English and code stay LTR. No hashed
// class names needed, so it survives extension updates.
(function () {
	'use strict';

	if (window.__claudeCodeRtlInit) return;
	window.__claudeCodeRtlInit = true;

	// Block elements whose direction should follow their own text content.
	var BLOCK_SEL = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,td,th,dd,dt,summary,figcaption';
	// Never touch code or editors — they must stay LTR regardless of first glyph.
	var SKIP_SEL = 'pre,code,textarea,input,[class*="codeBlock"],[class*="CodeBlock"],.monaco-editor';

	// Strong RTL scripts (Hebrew, Arabic, Syriac, Thaana, NKo, Arabic presentation
	// forms). Basic-Latin letters stand in for "strong LTR" — enough for English
	// and code without dragging in every Unicode letter.
	var RE_RTL = /[֑-߿‏יִ-﷽ﹰ-ﻼ]/;
	var RE_LTR = /[A-Za-z‎]/;

	// 'rtl' | 'ltr' | null (no strong char yet — stay undecided and re-check later).
	function firstStrongDir(text) {
		var r = text.search(RE_RTL);
		var l = text.search(RE_LTR);
		if (r === -1 && l === -1) return null;
		if (r === -1) return 'ltr';
		if (l === -1) return 'rtl';
		return r < l ? 'rtl' : 'ltr';
	}

	// Decide + lock a single block element. Once locked we never revisit it, which
	// is what kills the streaming oscillation.
	function decide(el) {
		if (el.__rtlLocked) return;
		if (el.closest && el.closest(SKIP_SEL)) { el.__rtlLocked = true; return; }
		var dir = firstStrongDir(el.textContent || '');
		if (!dir) return; // still neutral; leave undecided for a later tick
		if (!el.getAttribute('dir')) el.setAttribute('dir', dir);
		el.__rtlLocked = true;
	}

	// Decide `root` and every block descendant it contains.
	function decideWithin(root) {
		if (!root || root.nodeType !== 1) return;
		if (root.matches && root.matches(BLOCK_SEL)) decide(root);
		if (root.querySelectorAll) {
			var found = root.querySelectorAll(BLOCK_SEL);
			for (var i = 0; i < found.length; i++) decide(found[i]);
		}
	}

	// The composer is a contenteditable; dir="auto" is fine there — a single field
	// the user types into doesn't suffer the streaming-oscillation problem.
	function stampInput() {
		var inputs = document.querySelectorAll('[class*="messageInput"]');
		for (var i = 0; i < inputs.length; i++) {
			if (!inputs[i].getAttribute('dir')) inputs[i].setAttribute('dir', 'auto');
		}
	}

	function sweep() {
		try { decideWithin(document.body); stampInput(); }
		catch (e) { /* never block the UI on an injection failure */ }
	}

	function start() {
		sweep();

		// Coalesce a burst of streaming mutations into one pass per frame, run in the
		// render step (before paint) so a freshly-created paragraph is decided in the
		// same frame it appeared — no wrong-direction frame. We also re-check on
		// characterData changes so a block that streamed in neutral-first (e.g. a
		// bullet or number) gets decided the moment its first strong glyph arrives.
		var scheduled = false;
		var pending = [];
		function flush() {
			scheduled = false;
			var batch = pending;
			pending = [];
			try {
				for (var n = 0; n < batch.length; n++) decideWithin(batch[n]);
				stampInput();
			} catch (e) { /* ignore */ }
		}
		var schedule = window.requestAnimationFrame
			? function () { window.requestAnimationFrame(flush); }
			: function () { setTimeout(flush, 0); };
		var observer = new MutationObserver(function (mutations) {
			for (var i = 0; i < mutations.length; i++) {
				var m = mutations[i];
				if (m.type === 'characterData') {
					var host = m.target.parentElement;
					if (host) pending.push(host);
					continue;
				}
				var added = m.addedNodes;
				for (var k = 0; k < added.length; k++) {
					if (added[k].nodeType === 1) pending.push(added[k]);
				}
			}
			if (!pending.length) return;
			if (!scheduled) { scheduled = true; schedule(); }
		});
		observer.observe(document.body, { childList: true, subtree: true, characterData: true });
	}

	if (document.body) start();
	else document.addEventListener('DOMContentLoaded', start);
})();
