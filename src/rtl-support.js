// RTL (Right-to-Left) support for Claude Desktop
// Gated by CLAUDE_RTL=1 environment variable
// Adapted from the RTL ChatGPT browser extension

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

  /* Move sidebar to right side */
  body[data-claude-rtl="true"] nav.fixed {
    left: auto !important;
    right: 0 !important;
    border-right-width: 0 !important;
    border-left-width: 0.5px;
    border-left-style: solid;
    border-left-color: inherit;
  }

  /* Message content RTL via CSS cascade */
  body[data-claude-rtl="true"] .font-claude-response,
  body[data-claude-rtl="true"] [data-testid="user-message"] {
    direction: rtl;
    text-align: right;
  }

  /* Code blocks default to LTR */
  body[data-claude-rtl="true"] .code-block__code {
    direction: ltr !important;
    text-align: left !important;
  }

  /* Allow override when explicitly toggled to RTL */
  body[data-claude-rtl="true"] .code-block__code[data-claude-dir="rtl"] {
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

  /* Floating toggle button */
  #claude-rtl-floating-toggle {
    position: fixed;
    top: 12px;
    right: 20px;
    z-index: 99999;
    background: rgba(0, 0, 0, 0.7);
    color: white;
    border: 1px solid rgba(255, 255, 255, 0.3);
    border-radius: 8px;
    padding: 8px 16px;
    font-size: 13px;
    font-weight: 700;
    cursor: pointer;
    font-family: system-ui, -apple-system, sans-serif;
    transition: all 0.2s ease;
    user-select: none;
  }

  #claude-rtl-floating-toggle:hover {
    background: rgba(0, 0, 0, 0.9);
    transform: scale(1.05);
  }

  @media (prefers-color-scheme: dark) {
    #claude-rtl-floating-toggle {
      background: rgba(255, 255, 255, 0.15);
      border-color: rgba(255, 255, 255, 0.25);
    }
    #claude-rtl-floating-toggle:hover {
      background: rgba(255, 255, 255, 0.25);
    }
  }
`;

const RTL_JS = `(function() {
  'use strict';

  if (window.claudeRTLInitialized) return;
  window.claudeRTLInitialized = true;

  var STORAGE_KEY = 'claude-rtl-enabled';

  function createToggleButton(isCodeBlock) {
    var button = document.createElement('span');
    button.className = 'claude-rtl-toggle-btn';
    button.textContent = isCodeBlock ? 'LTR' : 'RTL';
    button.setAttribute('data-direction', isCodeBlock ? 'ltr' : 'rtl');
    button.setAttribute('role', 'button');
    button.setAttribute('tabindex', '0');
    return button;
  }

  function toggleElementDirection(element, button, applyToChildren) {
    var currentDir = button.getAttribute('data-direction');
    var newDir = currentDir === 'rtl' ? 'ltr' : 'rtl';

    element.style.direction = newDir;
    element.setAttribute('data-claude-dir', newDir);
    element.style.textAlign = newDir === 'rtl' ? 'right' : 'left';

    if (applyToChildren) {
      var allChildren = element.querySelectorAll('*');
      allChildren.forEach(function(child) {
        child.style.direction = newDir;
        if (newDir === 'rtl') {
          child.style.textAlign = 'right';
        } else {
          var computedAlign = getComputedStyle(child).textAlign;
          if (computedAlign === 'right' || computedAlign === 'start') {
            child.style.textAlign = 'left';
          }
        }
      });
    }

    button.setAttribute('data-direction', newDir);
    button.textContent = newDir.toUpperCase();
  }

  function toggleFieldsetDirection(fieldset, button) {
    var currentDir = button.getAttribute('data-direction');
    var newDir = currentDir === 'rtl' ? 'ltr' : 'rtl';
    var textAlign = newDir === 'rtl' ? 'right' : 'left';

    fieldset.style.direction = newDir;
    fieldset.style.textAlign = textAlign;

    var editor = fieldset.querySelector('.tiptap.ProseMirror')
      || fieldset.querySelector('[contenteditable="true"]');
    if (editor) {
      editor.style.direction = newDir;
      editor.style.textAlign = textAlign;
      var overflowParent = editor.closest('.overflow-y-auto');
      if (overflowParent && fieldset.contains(overflowParent)) {
        overflowParent.style.direction = newDir;
        overflowParent.style.textAlign = textAlign;
      }
    }

    button.setAttribute('data-direction', newDir);
    button.textContent = newDir.toUpperCase();
  }

  function togglePreviewCardDirection(card, button) {
    var currentDir = button.getAttribute('data-direction');
    var newDir = currentDir === 'rtl' ? 'ltr' : 'rtl';
    var textAlign = newDir === 'rtl' ? 'right' : 'left';

    card.style.direction = newDir;
    card.style.textAlign = textAlign;

    var scrollArea = card.querySelector('.overflow-y-auto');
    if (scrollArea) {
      scrollArea.style.direction = newDir;
      scrollArea.style.textAlign = textAlign;
    }

    var textarea = card.querySelector('textarea');
    if (textarea) {
      textarea.style.direction = newDir;
      textarea.style.textAlign = textAlign;
    }

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

  function processFieldsets() {
    var fieldsets = document.querySelectorAll(
      'fieldset.flex.w-full.min-w-0.flex-col'
    );
    fieldsets.forEach(function(fieldset) {
      if (fieldset.parentElement &&
          fieldset.parentElement.classList.contains('claude-fieldset-wrapper')) {
        return;
      }

      fieldset.style.direction = 'rtl';
      fieldset.style.textAlign = 'right';

      var editor = fieldset.querySelector('.tiptap.ProseMirror')
        || fieldset.querySelector('[contenteditable="true"]');
      if (editor) {
        editor.style.direction = 'rtl';
        editor.style.textAlign = 'right';
        var overflowParent = editor.closest('.overflow-y-auto');
        if (overflowParent && fieldset.contains(overflowParent)) {
          overflowParent.style.direction = 'rtl';
          overflowParent.style.textAlign = 'right';
        }
      }

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

  function processMessages() {
    var selectors = '.font-claude-response, [data-testid="user-message"]';
    var messages = document.querySelectorAll(selectors);
    messages.forEach(function(message) {
      if (message.getAttribute('data-claude-rtl-processed')) return;
      message.style.direction = 'rtl';
      message.style.textAlign = 'right';
      message.setAttribute('data-claude-rtl-processed', 'true');
    });
  }

  function processPreviewCards() {
    var cards = document.querySelectorAll('.font-ui.rounded-2xl.border');
    cards.forEach(function(card) {
      if (card.parentElement &&
          card.parentElement.classList.contains('claude-preview-card-wrapper')) {
        return;
      }

      card.style.direction = 'rtl';
      card.style.textAlign = 'right';

      var scrollArea = card.querySelector('.overflow-y-auto');
      if (scrollArea) {
        scrollArea.style.direction = 'rtl';
        scrollArea.style.textAlign = 'right';
      }

      var textarea = card.querySelector('textarea');
      if (textarea) {
        textarea.style.direction = 'rtl';
        textarea.style.textAlign = 'right';
      }

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

  function processAllElements() {
    processCodeBlocks();
    processFieldsets();
    processMessages();
    processPreviewCards();
  }

  function setRTLEnabled(enabled) {
    var body = document.body;
    if (enabled) {
      body.style.direction = 'rtl';
      body.setAttribute('data-claude-rtl', 'true');
      processAllElements();
    } else {
      body.style.direction = '';
      body.removeAttribute('data-claude-rtl');
      var processed = document.querySelectorAll('[data-claude-rtl-processed]');
      processed.forEach(function(el) {
        el.style.direction = '';
        el.style.textAlign = '';
        el.removeAttribute('data-claude-rtl-processed');
      });
    }
    try { localStorage.setItem(STORAGE_KEY, enabled ? '1' : '0'); }
    catch(e) { /* ignore */ }
    updateFloatingButton(enabled);
  }

  function toggleBodyDirection() {
    var isRTL = document.body.getAttribute('data-claude-rtl') === 'true';
    setRTLEnabled(!isRTL);
  }

  // Expose for context menu
  window.claudeRTLToggle = toggleBodyDirection;

  // Floating toggle button
  var floatingBtn = null;

  function updateFloatingButton(isRTL) {
    if (floatingBtn) {
      floatingBtn.textContent = isRTL ? 'RTL' : 'LTR';
    }
  }

  function createFloatingButton() {
    floatingBtn = document.createElement('button');
    floatingBtn.id = 'claude-rtl-floating-toggle';
    floatingBtn.textContent = 'LTR';
    floatingBtn.addEventListener('click', toggleBodyDirection);
    document.body.appendChild(floatingBtn);
  }

  // MutationObserver with debounce
  function startObserver() {
    var timeout;
    var observer = new MutationObserver(function(mutations) {
      var shouldProcess = false;
      for (var i = 0; i < mutations.length; i++) {
        if (mutations[i].addedNodes.length > 0) {
          shouldProcess = true;
          break;
        }
      }
      if (shouldProcess && document.body.getAttribute('data-claude-rtl') === 'true') {
        clearTimeout(timeout);
        timeout = setTimeout(processAllElements, 100);
      }
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true
    });
  }

  // Initialize
  createFloatingButton();

  var savedState = false;
  try { savedState = localStorage.getItem(STORAGE_KEY) === '1'; }
  catch(e) { /* ignore */ }

  if (savedState) {
    setRTLEnabled(true);
  }

  startObserver();
})();`;

const RTL_CONTEXT_MENU_LABEL = 'Switch language direction';

module.exports = { RTL_CSS, RTL_JS, RTL_CONTEXT_MENU_LABEL };
