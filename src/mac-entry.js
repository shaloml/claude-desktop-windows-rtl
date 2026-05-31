// macOS entry shim — set as package.json `main` by patch-claude-macos.sh.
//
// Loads the macOS feature wrapper, then hands control to the app's ORIGINAL
// main bundle. The patcher renames the original `main` field to
// `claudeOriginalMain` before repointing `main` here, so we resolve it at
// runtime from our own package.json (no hardcoded bundle path that would break
// when upstream renames the entry).

'use strict';

const path = require('path');

try {
	require('./mac-wrapper.js').install();
} catch (e) {
	// Never let an extension failure stop Claude from launching.
	console.error('[Claude Mac Entry] wrapper failed to install:', e && e.message);
}

let originalMain = '.vite/build/index.pre.js';
try {
	const pkg = require('./package.json');
	if (pkg && pkg.claudeOriginalMain) originalMain = pkg.claudeOriginalMain;
} catch (e) {
	console.error('[Claude Mac Entry] could not read package.json:', e && e.message);
}

// Resolve relative to this file (asar root) and load the real app.
require(path.join(__dirname, originalMain));
