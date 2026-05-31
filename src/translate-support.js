//===========================================================================
// Best-effort, on-demand page translation to Hebrew.
//
// Why this shape: claude.ai is a React SPA behind a strict CSP, and Electron
// has no native Chromium translate. So this does a ONE-SHOT pass — collect
// the current visible text nodes in the renderer, translate them in the MAIN
// process via the free Google endpoint (no API key, and main-process requests
// are not subject to the page's CSP), then write the results back. Because it
// is one-shot, any later React re-render reverts it; re-run from the
// right-click menu to translate again.
//
// Privacy note: the visible page text is sent to Google's public translate
// endpoint. Do not use on sensitive conversations you don't want to share.
//
// Required at runtime by scripts/frame-fix-wrapper.js (main process).
//===========================================================================
'use strict';

const https = require('https');

const TRANSLATE_CONTEXT_MENU_LABEL = 'תרגם לעברית';
const TARGET_LANG = 'iw'; // Google's (legacy) code for Hebrew

// Renderer-side source: collect candidate text nodes, stash live refs on
// window, define the applier, and return the (whitespace-collapsed) texts.
const COLLECT_JS = `(() => {
  const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEXTAREA','CODE','PRE','INPUT','KBD','SAMP']);
  const hasLetter = /\\p{L}/u;
  const nodes = [];
  const texts = [];
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
      const p = n.parentElement;
      if (!p) return NodeFilter.FILTER_REJECT;
      if (SKIP.has(p.tagName) || p.isContentEditable) return NodeFilter.FILTER_REJECT;
      const t = n.nodeValue;
      if (!t || t.trim().length < 2 || !hasLetter.test(t)) return NodeFilter.FILTER_REJECT;
      if (p.getClientRects().length === 0) return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  let node;
  while ((node = walker.nextNode())) {
    nodes.push(node);
    texts.push(node.nodeValue.replace(/\\s+/g, ' ').trim());
  }
  window.__claudeTrNodes = nodes;
  window.__claudeApplyTranslation = (arr) => {
    const ns = window.__claudeTrNodes || [];
    let applied = 0;
    for (let i = 0; i < ns.length && i < arr.length; i++) {
      const n = ns[i];
      if (arr[i] == null || !n || !n.parentElement) continue;
      const orig = n.nodeValue || '';
      const lead = (orig.match(/^\\s*/) || [''])[0];
      const trail = (orig.match(/\\s*$/) || [''])[0];
      n.nodeValue = lead + arr[i] + trail;
      applied++;
    }
    window.__claudeTrNodes = null;
    return applied;
  };
  return texts;
})()`;

function httpsGetJson(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      url,
      { headers: { 'User-Agent': 'Mozilla/5.0' } },
      (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          if (res.statusCode !== 200) {
            reject(new Error('HTTP ' + res.statusCode));
            return;
          }
          try { resolve(JSON.parse(data)); }
          catch (e) { reject(new Error('parse: ' + e.message)); }
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(15000, () => req.destroy(new Error('timeout')));
  });
}

// Translate one batch (texts joined by newline) via the gtx single endpoint.
// Returns an aligned array, or null if the line count came back mismatched.
async function translateBatch(texts) {
  const q = encodeURIComponent(texts.join('\n'));
  const url = 'https://translate.googleapis.com/translate_a/single' +
    '?client=gtx&sl=auto&tl=' + TARGET_LANG + '&dt=t&q=' + q;
  const data = await httpsGetJson(url);
  // data[0] is an array of [translatedChunk, originalChunk, ...]; the
  // concatenation of chunk[0] reconstructs the full translated text, with
  // the newline batch separators preserved.
  const full = (data[0] || []).map((seg) => seg[0]).join('');
  const lines = full.split('\n');
  return lines.length === texts.length ? lines : null;
}

// Translate up to MAX_NODES texts, batching by source-char budget and
// running batches sequentially to stay under the endpoint's rate limit.
// Untranslatable batches fall back to the original text.
async function translateTexts(texts) {
  const MAX_NODES = 600;
  const BUDGET = 1500;
  const slice = texts.slice(0, MAX_NODES);
  const out = slice.slice();

  let batch = [];
  let idx = [];
  let len = 0;
  const flush = async () => {
    if (batch.length === 0) return;
    try {
      const res = await translateBatch(batch);
      if (res) {
        for (let i = 0; i < idx.length; i++) out[idx[i]] = res[i];
      }
    } catch (e) {
      console.error('[Translate] batch failed:', e.message);
    }
    batch = [];
    idx = [];
    len = 0;
  };

  for (let i = 0; i < slice.length; i++) {
    const t = slice[i];
    if (len + t.length > BUDGET && batch.length > 0) await flush();
    batch.push(t);
    idx.push(i);
    len += t.length + 1;
  }
  await flush();
  return out;
}

// Entry point called from the right-click menu (main process).
async function translatePage(webContents) {
  try {
    const texts = await webContents.executeJavaScript(COLLECT_JS, true);
    if (!Array.isArray(texts) || texts.length === 0) {
      console.log('[Translate] nothing to translate');
      return;
    }
    console.log('[Translate] collected ' + texts.length + ' text nodes');
    const translated = await translateTexts(texts);
    const applied = await webContents.executeJavaScript(
      'window.__claudeApplyTranslation ? window.__claudeApplyTranslation(' +
        JSON.stringify(translated) + ') : 0',
      true
    );
    console.log('[Translate] applied to ' + applied + ' nodes');
  } catch (e) {
    console.error('[Translate] failed:', e.message);
  }
}

module.exports = { TRANSLATE_CONTEXT_MENU_LABEL, translatePage };
