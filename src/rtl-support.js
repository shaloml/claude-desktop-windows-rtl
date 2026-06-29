// RTL (Right-to-Left) support for Claude Desktop (claude.ai web app).
//
// Lineage: adapted from the "Claude.ai RTL Transformer" browser extension
// (https://github.com/shaloml/rtl-chatgpt). Injected into the renderer by the
// platform wrappers (win/mac/linux) as RTL_CSS (<style>) + RTL_JS.
//
// Three modes, chosen from a small floating, draggable panel pinned at the top
// (AUTO / RTL / LTR), persisted in localStorage (key: claude-rtl-mode):
//   AUTO (default) — decide each message paragraph's direction from its first
//     strong character and pin it once (locked) so streaming never flickers;
//     English & code stay LTR. Sidebar/UI chrome stays LTR.
//   RTL — force the whole window RTL (sidebar moves right, messages RTL), code LTR.
//   LTR — baseline / off.
// Inline per-element buttons (code block / input / preview card) remain available
// in AUTO and RTL for manual per-block overrides.

const RTL_CSS = `
  .claude-rtl-toggle-btn {
    display: inline-block;
    position: relative;
    margin-right: 10px;
    float: right;
    clear: both;
    z-index: 10;
    background: rgba(0, 0, 0, 0.6);
    color: white;
    border: 1px solid rgba(255, 255, 255, 0.3);
    border-radius: 6px;
    padding: 4px 10px;
    font-size: 11px;
    font-weight: 600;
    cursor: pointer;
    transition: all 0.2s ease;
    font-family: system-ui, -apple-system, sans-serif;
  }

  .claude-rtl-toggle-btn:hover {
    background: rgba(0, 0, 0, 0.8);
    transform: scale(1.05);
  }

  .claude-rtl-toggle-btn:active {
    transform: scale(0.95);
  }

  .claude-fieldset-wrapper {
    position: relative;
  }

  .claude-fieldset-wrapper .claude-rtl-toggle-btn {
    right: 12px;
    bottom: 12px;
    top: auto;
    left: auto;
    opacity: 1;
    pointer-events: auto;
  }

  .code-block__code {
    position: relative;
  }

  /* Keep sidebar LTR */
  body[data-claude-rtl="true"] nav .overflow-y-auto,
  body[data-claude-rtl="true"] aside .overflow-y-auto {
    direction: ltr !important;
  }

  /* Move sidebar to right side (RTL mode only) */
  body[data-claude-rtl="true"] nav.fixed {
    left: auto !important;
    right: 0 !important;
    border-right-width: 0 !important;
    border-left-width: 0.5px;
    border-left-style: solid;
    border-left-color: inherit;
  }

  /* Message content RTL via CSS cascade (RTL mode) */
  body[data-claude-rtl="true"] .font-claude-response,
  body[data-claude-rtl="true"] [data-testid="user-message"] {
    direction: rtl;
    text-align: right;
  }

  /* Code blocks default to LTR in any mode */
  body[data-claude-rtl="true"] .code-block__code,
  body[data-claude-rtl-mode="auto"] .code-block__code {
    direction: ltr !important;
    text-align: left !important;
  }

  /* Allow override when explicitly toggled to RTL */
  body[data-claude-rtl="true"] .code-block__code[data-claude-dir="rtl"],
  body[data-claude-rtl-mode="auto"] .code-block__code[data-claude-dir="rtl"] {
    direction: rtl !important;
    text-align: right !important;
  }

  /* ProseMirror input inherits from fieldset */
  body[data-claude-rtl="true"] .tiptap.ProseMirror {
    direction: inherit;
    text-align: inherit;
  }

  /* Preview card toggle button positioning */
  .claude-preview-card-wrapper {
    position: relative;
  }

  .claude-preview-card-wrapper > .claude-rtl-toggle-btn {
    position: absolute;
    top: 8px;
    left: 8px;
    float: none;
    margin: 0;
    z-index: 20;
    opacity: 0.7;
  }

  .claude-preview-card-wrapper > .claude-rtl-toggle-btn:hover {
    opacity: 1;
  }

  /* Floating AUTO / RTL / LTR control panel */
  #claude-rtl-panel {
    position: fixed;
    top: 10px;
    left: 50%;
    transform: translateX(-50%);
    z-index: 2147483647;
    display: flex;
    align-items: center;
    gap: 4px;
    padding: 3px 5px;
    border-radius: 8px;
    background: rgba(40, 40, 40, 0.92);
    box-shadow: 0 2px 8px rgba(0, 0, 0, 0.35);
    font-family: system-ui, -apple-system, "Segoe UI", sans-serif;
    direction: ltr;
    user-select: none;
    -webkit-user-select: none;
    /* The app's custom title bar marks the top strip as an OS window-drag region
       (-webkit-app-region: drag), which otherwise swallows clicks/drag on the
       panel (seen on Windows; harmless elsewhere). Opt the panel back out. */
    -webkit-app-region: no-drag;
    app-region: no-drag;
  }
  #claude-rtl-panel .ccr-grip {
    cursor: move;
    color: #aaa;
    padding: 0 4px;
    font-size: 12px;
    line-height: 1;
    touch-action: none;
  }
  #claude-rtl-panel .ccr-btn {
    -webkit-appearance: none;
    appearance: none;
    border: 1px solid transparent;
    background: transparent;
    color: #ddd;
    font-size: 11px;
    font-weight: 600;
    padding: 2px 8px;
    border-radius: 5px;
    cursor: pointer;
    line-height: 1.4;
  }
  #claude-rtl-panel .ccr-btn:hover {
    background: rgba(255, 255, 255, 0.12);
  }
  #claude-rtl-panel .ccr-btn[data-active] {
    background: #2f6feb;
    color: #fff;
  }
  #claude-rtl-panel .ccr-sep {
    width: 1px;
    height: 16px;
    margin: 0 2px;
    background: rgba(255, 255, 255, 0.18);
  }
  /* The "+window" action now lives inside the panel — hide the standalone
     floating new-window buttons (multi-instance on win/mac, our own on Linux). */
  #claude-new-instance-floating-btn,
  #claude-rtl-newwindow-btn {
    display: none !important;
  }
`;

const RTL_JS = `(function() {
  'use strict';

  if (window.claudeRTLInitialized) return;
  window.claudeRTLInitialized = true;

  var MODE_KEY = 'claude-rtl-mode';
  var LEGACY_KEY = 'claude-rtl-enabled';
  var PANEL_ID = 'claude-rtl-panel';
  var LS_LEFT = 'claude-rtl-panel-left';
  var LS_TOP = 'claude-rtl-panel-top';

  function lsGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
  function lsSet(k, v) { try { localStorage.setItem(k, String(v)); } catch (e) {} }

  // Initial mode: saved value, else migrate the legacy on/off flag, else AUTO.
  var mode = (function() {
    var m = lsGet(MODE_KEY);
    if (m === 'auto' || m === 'rtl' || m === 'ltr') return m;
    if (lsGet(LEGACY_KEY) === '1') return 'rtl';
    return 'auto';
  })();

  // ---- AUTO: first-strong-character detection (per paragraph, locked once) ----
  var RE_RTL = /[֑-߿‏יִ-﷽ﹰ-ﻼ]/;
  var RE_LTR = /[A-Za-z‎]/;
  var BLOCK_SEL = 'p,li,h1,h2,h3,h4,h5,h6,blockquote,td,th,dd,dt,summary,figcaption';
  var RESPONSE_SEL = '.font-claude-response';
  var USER_SEL = '[data-testid="user-message"]';
  var SKIP_SEL = 'pre,code,.code-block__code,#' + PANEL_ID;

  function firstStrongDir(text) {
    var r = text.search(RE_RTL);
    var l = text.search(RE_LTR);
    if (r === -1 && l === -1) return null;
    if (r === -1) return 'ltr';
    if (l === -1) return 'rtl';
    return r < l ? 'rtl' : 'ltr';
  }

  function decide(el) {
    if (el.__ccrLocked) return;
    if (el.closest && el.closest(SKIP_SEL)) { el.__ccrLocked = true; return; }
    var dir = firstStrongDir(el.textContent || '');
    if (!dir) return; // still neutral; re-check on a later tick
    if (!el.getAttribute('dir')) {
      el.setAttribute('dir', dir);
      el.setAttribute('data-ccr', '');
      el.style.textAlign = dir === 'rtl' ? 'right' : '';
    }
    el.__ccrLocked = true;
  }

  function pushHost(list, host) { if (host && list.indexOf(host) === -1) list.push(host); }

  function decideWithin(root) {
    if (!root || root.nodeType !== 1) return;
    // Assistant responses: decide each block descendant.
    var responses = [];
    if (root.matches && root.matches(RESPONSE_SEL)) pushHost(responses, root);
    if (root.closest) pushHost(responses, root.closest(RESPONSE_SEL));
    if (root.querySelectorAll) {
      var found = root.querySelectorAll(RESPONSE_SEL);
      for (var f = 0; f < found.length; f++) pushHost(responses, found[f]);
    }
    for (var i = 0; i < responses.length; i++) {
      var blocks = responses[i].querySelectorAll(BLOCK_SEL);
      for (var j = 0; j < blocks.length; j++) decide(blocks[j]);
    }
    // User messages: single-direction container, decide whole.
    var users = [];
    if (root.matches && root.matches(USER_SEL)) pushHost(users, root);
    if (root.closest) pushHost(users, root.closest(USER_SEL));
    if (root.querySelectorAll) {
      var uf = root.querySelectorAll(USER_SEL);
      for (var u = 0; u < uf.length; u++) pushHost(users, uf[u]);
    }
    for (var k = 0; k < users.length; k++) decide(users[k]);
  }

  function autoSweep() { try { decideWithin(document.body); } catch (e) {} }

  function clearAutoMarks() {
    try {
      var marked = document.querySelectorAll('[data-ccr]');
      for (var i = 0; i < marked.length; i++) {
        marked[i].removeAttribute('dir');
        marked[i].removeAttribute('data-ccr');
        marked[i].style.textAlign = '';
        marked[i].__ccrLocked = false;
      }
    } catch (e) {}
  }

  // ---- inline per-element toggle buttons (kept from the original) ----
  function createToggleButton(isCodeBlock) {
    var button = document.createElement('span');
    button.className = 'claude-rtl-toggle-btn';
    button.textContent = isCodeBlock ? 'LTR' : 'RTL';
    button.setAttribute('data-direction', isCodeBlock ? 'ltr' : 'rtl');
    button.setAttribute('role', 'button');
    button.setAttribute('tabindex', '0');
    return button;
  }

  function toggleElementDirection(element, button) {
    var currentDir = button.getAttribute('data-direction');
    var newDir = currentDir === 'rtl' ? 'ltr' : 'rtl';
    element.style.direction = newDir;
    element.setAttribute('data-claude-dir', newDir);
    element.style.textAlign = newDir === 'rtl' ? 'right' : 'left';
    button.setAttribute('data-direction', newDir);
    button.textContent = newDir.toUpperCase();
  }

  function setFieldsetDir(fieldset, dir) {
    var editor = fieldset.querySelector('.tiptap.ProseMirror')
      || fieldset.querySelector('[contenteditable="true"]');
    if (dir === 'auto') {
      fieldset.setAttribute('dir', 'auto');
      fieldset.style.direction = '';
      fieldset.style.textAlign = '';
      if (editor) { editor.setAttribute('dir', 'auto'); editor.style.direction = ''; editor.style.textAlign = ''; }
    } else {
      var ta = dir === 'rtl' ? 'right' : 'left';
      fieldset.style.direction = dir;
      fieldset.style.textAlign = ta;
      if (editor) {
        editor.style.direction = dir;
        editor.style.textAlign = ta;
        var overflowParent = editor.closest('.overflow-y-auto');
        if (overflowParent && fieldset.contains(overflowParent)) {
          overflowParent.style.direction = dir;
          overflowParent.style.textAlign = ta;
        }
      }
    }
  }

  function toggleFieldsetDirection(fieldset, button) {
    var newDir = button.getAttribute('data-direction') === 'rtl' ? 'ltr' : 'rtl';
    setFieldsetDir(fieldset, newDir);
    button.setAttribute('data-direction', newDir);
    button.textContent = newDir.toUpperCase();
  }

  function setCardDir(card, dir) {
    var scrollArea = card.querySelector('.overflow-y-auto');
    var textarea = card.querySelector('textarea');
    if (dir === 'auto') {
      card.setAttribute('dir', 'auto');
      card.style.direction = '';
      card.style.textAlign = '';
      if (scrollArea) { scrollArea.setAttribute('dir', 'auto'); scrollArea.style.direction = ''; scrollArea.style.textAlign = ''; }
      if (textarea) { textarea.setAttribute('dir', 'auto'); textarea.style.direction = ''; textarea.style.textAlign = ''; }
    } else {
      var ta = dir === 'rtl' ? 'right' : 'left';
      card.style.direction = dir;
      card.style.textAlign = ta;
      if (scrollArea) { scrollArea.style.direction = dir; scrollArea.style.textAlign = ta; }
      if (textarea) { textarea.style.direction = dir; textarea.style.textAlign = ta; }
    }
  }

  function togglePreviewCardDirection(card, button) {
    var newDir = button.getAttribute('data-direction') === 'rtl' ? 'ltr' : 'rtl';
    setCardDir(card, newDir);
    button.setAttribute('data-direction', newDir);
    button.textContent = newDir.toUpperCase();
  }

  function processCodeBlocks() {
    var codeBlocks = document.querySelectorAll('.code-block__code');
    codeBlocks.forEach(function(codeBlock) {
      if (codeBlock.parentElement &&
          codeBlock.parentElement.querySelector('.claude-rtl-toggle-btn')) {
        return;
      }
      codeBlock.style.direction = 'ltr';
      codeBlock.style.textAlign = 'left';
      var button = createToggleButton(true);
      button.addEventListener('click', function(e) {
        e.stopPropagation();
        toggleElementDirection(codeBlock, button);
      });
      if (codeBlock.parentElement) {
        codeBlock.parentElement.insertBefore(button, codeBlock);
      }
    });
  }

  function processFieldsets(initDir) {
    var fieldsets = document.querySelectorAll('fieldset.flex.w-full.min-w-0.flex-col');
    fieldsets.forEach(function(fieldset) {
      if (fieldset.parentElement &&
          fieldset.parentElement.classList.contains('claude-fieldset-wrapper')) {
        return;
      }
      setFieldsetDir(fieldset, initDir);
      var wrapper = document.createElement('div');
      wrapper.className = 'claude-fieldset-wrapper';
      fieldset.parentNode.insertBefore(wrapper, fieldset);
      wrapper.appendChild(fieldset);
      var button = createToggleButton(false);
      button.addEventListener('click', function(e) {
        e.stopPropagation();
        toggleFieldsetDirection(fieldset, button);
      });
      wrapper.appendChild(button);
    });
  }

  function processPreviewCards(initDir) {
    var cards = document.querySelectorAll('.font-ui.rounded-2xl.border');
    cards.forEach(function(card) {
      if (card.parentElement &&
          card.parentElement.classList.contains('claude-preview-card-wrapper')) {
        return;
      }
      setCardDir(card, initDir);
      var wrapper = document.createElement('div');
      wrapper.className = 'claude-preview-card-wrapper';
      card.parentNode.insertBefore(wrapper, card);
      wrapper.appendChild(card);
      var button = createToggleButton(false);
      button.addEventListener('click', function(e) {
        e.stopPropagation();
        togglePreviewCardDirection(card, button);
      });
      wrapper.insertBefore(button, card);
    });
  }

  // Blanket message RTL (RTL mode only).
  function processMessagesBlanket() {
    var messages = document.querySelectorAll(RESPONSE_SEL + ', ' + USER_SEL);
    messages.forEach(function(message) {
      if (message.getAttribute('data-claude-rtl-processed')) return;
      message.style.direction = 'rtl';
      message.style.textAlign = 'right';
      message.setAttribute('data-claude-rtl-processed', 'true');
    });
  }

  // Remove body-level state + AUTO/blanket marks (keeps inline wrappers/buttons).
  function fullClear() {
    var body = document.body;
    body.removeAttribute('data-claude-rtl');
    body.style.direction = '';
    clearAutoMarks();
    var processed = document.querySelectorAll('[data-claude-rtl-processed]');
    processed.forEach(function(el) {
      el.style.direction = '';
      el.style.textAlign = '';
      el.removeAttribute('data-claude-rtl-processed');
    });
  }

  function processForMode() {
    if (mode === 'rtl') {
      processCodeBlocks();
      processFieldsets('rtl');
      processMessagesBlanket();
      processPreviewCards('rtl');
    } else if (mode === 'auto') {
      processCodeBlocks();
      processFieldsets('auto');
      autoSweep();
      processPreviewCards('auto');
    }
  }

  function applyMode(m) {
    if (m !== 'auto' && m !== 'rtl' && m !== 'ltr') m = 'auto';
    mode = m;
    lsSet(MODE_KEY, m);
    var body = document.body;
    if (!body) return;
    body.setAttribute('data-claude-rtl-mode', m);
    fullClear();
    if (m === 'rtl') {
      body.style.direction = 'rtl';
      body.setAttribute('data-claude-rtl', 'true');
    }
    processForMode();
    updatePanelButtons();
  }

  // Context-menu helpers (back-compat: claudeRTLToggle now cycles).
  window.claudeRTLSetMode = function(m) { applyMode(m); };
  window.claudeRTLToggle = function() {
    var next = mode === 'auto' ? 'rtl' : (mode === 'rtl' ? 'ltr' : 'auto');
    applyMode(next);
  };

  // ---- Floating AUTO / RTL / LTR panel ----
  var btnAuto = null, btnRtl = null, btnLtr = null;

  function setActive(btn, on) {
    if (!btn) return;
    if (on) btn.setAttribute('data-active', '1');
    else btn.removeAttribute('data-active');
  }
  function updatePanelButtons() {
    try {
      setActive(btnAuto, mode === 'auto');
      setActive(btnRtl, mode === 'rtl');
      setActive(btnLtr, mode === 'ltr');
    } catch (e) {}
  }

  function makeBtn(m, label, title) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'ccr-btn';
    b.textContent = label;
    b.title = title;
    b.setAttribute('data-mode', m);
    b.addEventListener('click', function(e) {
      e.preventDefault();
      e.stopPropagation();
      applyMode(m);
    });
    return b;
  }

  // Open a new window via whichever global the platform wrapper exposed: Linux
  // uses claudeOpenNewWindow (in-process), Windows/macOS use claudeOpenNewInstance.
  function openNewWindow() {
    try {
      var fn = window.claudeOpenNewWindow || window.claudeOpenNewInstance;
      if (typeof fn === 'function') fn();
    } catch (e) {}
  }

  function makeActionBtn(label, title, onClick) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'ccr-btn';
    b.textContent = label;
    b.title = title;
    b.addEventListener('click', function(e) {
      e.preventDefault();
      e.stopPropagation();
      onClick();
    });
    return b;
  }

  function enableDrag(panel, grip) {
    var dragging = false, startX = 0, startY = 0, baseLeft = 0, baseTop = 0;
    grip.addEventListener('pointerdown', function(e) {
      dragging = true;
      var rect = panel.getBoundingClientRect();
      baseLeft = rect.left; baseTop = rect.top;
      startX = e.clientX; startY = e.clientY;
      panel.style.left = baseLeft + 'px';
      panel.style.top = baseTop + 'px';
      panel.style.right = 'auto';
      panel.style.transform = 'none';
      try { grip.setPointerCapture(e.pointerId); } catch (err) {}
      e.preventDefault();
    });
    grip.addEventListener('pointermove', function(e) {
      if (!dragging) return;
      var nx = baseLeft + (e.clientX - startX);
      var ny = baseTop + (e.clientY - startY);
      nx = Math.max(0, Math.min(nx, window.innerWidth - panel.offsetWidth));
      ny = Math.max(0, Math.min(ny, window.innerHeight - panel.offsetHeight));
      panel.style.left = nx + 'px';
      panel.style.top = ny + 'px';
    });
    function endDrag() {
      if (!dragging) return;
      dragging = false;
      lsSet(LS_LEFT, parseInt(panel.style.left, 10) || 0);
      lsSet(LS_TOP, parseInt(panel.style.top, 10) || 0);
    }
    grip.addEventListener('pointerup', endDrag);
    grip.addEventListener('pointercancel', endDrag);
  }

  function ensurePanel() {
    if (!document.body) return;
    if (document.getElementById(PANEL_ID)) return;
    var panel = document.createElement('div');
    panel.id = PANEL_ID;
    panel.setAttribute('dir', 'ltr');

    var grip = document.createElement('span');
    grip.className = 'ccr-grip';
    grip.textContent = '⠿';
    grip.title = 'Drag';
    panel.appendChild(grip);

    btnAuto = makeBtn('auto', 'AUTO', 'Automatic direction per paragraph');
    btnRtl = makeBtn('rtl', 'RTL', 'Force right-to-left everywhere');
    btnLtr = makeBtn('ltr', 'LTR', 'Force left-to-right everywhere');
    panel.appendChild(btnAuto);
    panel.appendChild(btnRtl);
    panel.appendChild(btnLtr);

    // "+window" action (opens a new window, same process / shared login).
    var sep = document.createElement('span');
    sep.className = 'ccr-sep';
    panel.appendChild(sep);
    panel.appendChild(makeActionBtn('+חלון', 'פתח חלון חדש', openNewWindow));

    var left = lsGet(LS_LEFT), top = lsGet(LS_TOP);
    if (left !== null && top !== null) {
      panel.style.left = left + 'px';
      panel.style.top = top + 'px';
      panel.style.right = 'auto';
      panel.style.transform = 'none';
    }

    document.body.appendChild(panel);
    enableDrag(panel, grip);
    updatePanelButtons();
  }

  // ---- streaming / SPA observer (batched per frame) ----
  function startObserver() {
    var scheduled = false;
    var pending = [];
    function flush() {
      scheduled = false;
      var batch = pending;
      pending = [];
      try {
        if (mode === 'auto') {
          for (var n = 0; n < batch.length; n++) decideWithin(batch[n]);
          processCodeBlocks();
          processFieldsets('auto');
          processPreviewCards('auto');
        } else if (mode === 'rtl') {
          processCodeBlocks();
          processFieldsets('rtl');
          processMessagesBlanket();
          processPreviewCards('rtl');
        }
        ensurePanel();
      } catch (e) {}
    }
    var schedule = window.requestAnimationFrame
      ? function() { window.requestAnimationFrame(flush); }
      : function() { setTimeout(flush, 0); };
    var observer = new MutationObserver(function(mutations) {
      if (mode === 'ltr') return;
      for (var i = 0; i < mutations.length; i++) {
        var mu = mutations[i];
        if (mu.type === 'characterData') {
          if (mu.target.parentElement) pending.push(mu.target.parentElement);
          continue;
        }
        var added = mu.addedNodes;
        for (var k = 0; k < added.length; k++) {
          if (added[k].nodeType === 1) pending.push(added[k]);
        }
      }
      if (!scheduled) { scheduled = true; schedule(); }
    });
    observer.observe(document.body, { childList: true, subtree: true, characterData: true });
  }

  function start() {
    ensurePanel();
    applyMode(mode);
    startObserver();
  }

  if (document.body) start();
  else document.addEventListener('DOMContentLoaded', start);
})();`;

const RTL_CONTEXT_MENU_LABEL = 'Switch language direction (AUTO/RTL/LTR)';

module.exports = { RTL_CSS, RTL_JS, RTL_CONTEXT_MENU_LABEL };
