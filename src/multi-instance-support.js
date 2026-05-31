// Multi-instance support: in-app affordances for opening additional
// Claude Desktop windows (each with its own MCP context / config dir).
//
// Loaded by frame-fix-wrapper.js via require('./multi-instance-support.js').
// Exposes:
//   - MULTI_INSTANCE_BUTTON_CSS / _JS — injected into renderer next to RTL toggle
//   - NEW_INSTANCE_CONTEXT_MENU_LABEL — string for the right-click menu item
//   - CONSOLE_TRIGGER — magic console.log message the renderer emits to ask
//                       the main process to spawn a new instance
//   - openNewInstance() — spawns the launcher with --new-window, detached
//
// Renderer→main bridge piggybacks on the existing console-message listener
// in frame-fix-wrapper.js — no preload / contextBridge changes needed.

const CONSOLE_TRIGGER = '[ClaudeLocal] open-new-instance';

const NEW_INSTANCE_CONTEXT_MENU_LABEL = 'פתח חלון חדש (instance)';

const MULTI_INSTANCE_BUTTON_CSS = `
  #claude-new-instance-floating-btn {
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
  #claude-new-instance-floating-btn:hover {
    background: rgba(0, 0, 0, 0.9);
    transform: scale(1.05);
  }
  @media (prefers-color-scheme: dark) {
    #claude-new-instance-floating-btn {
      background: rgba(255, 255, 255, 0.15);
      border-color: rgba(255, 255, 255, 0.25);
    }
    #claude-new-instance-floating-btn:hover {
      background: rgba(255, 255, 255, 0.25);
    }
  }
`;

const MULTI_INSTANCE_BUTTON_JS = `(function() {
  'use strict';
  if (window.claudeNewInstanceInitialized) return;
  window.claudeNewInstanceInitialized = true;

  function trigger() {
    // Picked up by the console-message listener in frame-fix-wrapper.js
    console.log(${JSON.stringify(CONSOLE_TRIGGER)});
  }
  window.claudeOpenNewInstance = trigger;

  function ensureButton() {
    if (document.getElementById('claude-new-instance-floating-btn')) return;
    if (!document.body) return;
    var btn = document.createElement('button');
    btn.id = 'claude-new-instance-floating-btn';
    btn.textContent = '+חלון';
    btn.title = 'Open a new Claude Desktop instance (separate MCP context)';
    btn.addEventListener('click', trigger);
    document.body.appendChild(btn);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ensureButton);
  } else {
    ensureButton();
  }
  // Re-create if SPA navigation removes it
  setInterval(ensureButton, 2000);
})();`;

// Resolve the launcher script — what to spawn for a new instance.
// Order: explicit env override > AppImage path > deb/rpm path.
function resolveLauncher() {
  if (process.env.CLAUDE_DESKTOP_LAUNCHER) return process.env.CLAUDE_DESKTOP_LAUNCHER;
  if (process.env.APPIMAGE) return process.env.APPIMAGE;
  return '/usr/bin/claude-desktop';
}

function openNewInstance() {
  const { spawn } = require('child_process');
  const fs = require('fs');
  const launcher = resolveLauncher();

  if (!fs.existsSync(launcher)) {
    console.error('[Multi-Instance] Launcher not found:', launcher);
    return false;
  }

  // CLAUDE_SECONDARY_INSTANCE / XDG_CONFIG_HOME from THIS process must NOT
  // leak into the child — the launcher's setup_multi_instance computes them
  // afresh per instance. Strip them defensively.
  const childEnv = { ...process.env };
  delete childEnv.CLAUDE_SECONDARY_INSTANCE;
  delete childEnv.XDG_CONFIG_HOME;

  try {
    const child = spawn(launcher, ['--new-window'], {
      detached: true,
      stdio: 'ignore',
      env: childEnv,
    });
    child.unref();
    console.log('[Multi-Instance] Spawned new instance via', launcher);
    return true;
  } catch (e) {
    console.error('[Multi-Instance] spawn failed:', e.message);
    return false;
  }
}

// Helper used by frame-fix-wrapper's console-message listener to detect
// the renderer's request and invoke openNewInstance.
function isTriggerMessage(message) {
  return typeof message === 'string' && message.includes(CONSOLE_TRIGGER);
}

module.exports = {
  CONSOLE_TRIGGER,
  NEW_INSTANCE_CONTEXT_MENU_LABEL,
  MULTI_INSTANCE_BUTTON_CSS,
  MULTI_INSTANCE_BUTTON_JS,
  openNewInstance,
  isTriggerMessage,
};
