#!/usr/bin/env node
// dev-dock server — cross-platform (Linux/macOS/Windows) headless backend.
// Serves the PWA + WebSocket bridge and drives Claude Code, terminals, files and
// project history. Port of the macOS app's AppState wiring. Use it from a browser
// (the PWA) or the VS Code extension.
import os from 'node:os';
import { ClaudeSession } from './src/session.mjs';
import { TerminalManager } from './src/terminal.mjs';
import { Bridge } from './src/bridge.mjs';
import { startPWA } from './src/pwa.mjs';
import * as files from './src/files.mjs';

const WS_PORT = Number(process.env.DEVDOCK_WS_PORT || 51888);
const PWA_PORT = Number(process.env.DEVDOCK_PWA_PORT || 51890);

const session = new ClaudeSession();
const bridge = new Bridge(WS_PORT);
const terminal = new TerminalManager({
  broadcast: (m) => bridge.broadcast(m),
  onListChanged: () => bridge.broadcast({ type: 'termList', terminals: terminal.list() }),
  enabled: process.env.DEVDOCK_TERMINAL !== '0',
});
startPWA(PWA_PORT);

// --- wire shapes ---
const projectsWire = () => session.projects.map((p) => ({ id: p.id, name: p.path.split('/').pop(), path: p.path, branch: p.gitBranch, sessionCount: p.sessionCount, modified: p.modified }));
const sessionsWire = () => session.sessions.map((s) => ({ id: s.id, title: s.title, messageCount: s.messageCount, modified: s.modified }));
function chatSnapshot() {
  const perm = session.pendingPermission;
  return {
    type: 'chatSnapshot',
    chat: session.messages.map((m) => ({ role: m.role, text: m.text, tools: m.tools, streaming: m.streaming, isError: m.isError })),
    status: session.displayStatus,
    permission: perm ? { id: perm.id, tool: perm.tool, title: perm.title, body: perm.body, canRemember: perm.canRemember } : null,
    projectName: session.projectName,
    autoApprove: session.autoApprove,
    terminalEnabled: terminal.enabled,
    costUSD: session.totalCostUSD,
  };
}

// --- broadcasts (light throttle for the streaming firehose) ---
let chatTimer = null;
function broadcastChat() { if (chatTimer) return; chatTimer = setTimeout(() => { chatTimer = null; bridge.broadcast(chatSnapshot()); }, 60); }
session.on('change', broadcastChat);
session.on('projects', () => bridge.broadcast({ type: 'projectList', projects: projectsWire() }));
session.on('sessions', () => bridge.broadcast({ type: 'sessionList', sessions: sessionsWire(), projectName: session.projectName }));

bridge.onConnect = (ws) => {
  bridge.sendTo(ws, chatSnapshot());
  bridge.sendTo(ws, { type: 'termList', terminals: terminal.list() });
};

bridge.onMessage = (m) => {
  switch (m.type) {
    case 'chatSend': if (m.text) session.send(m.text); break;
    case 'chatStop': session.stop(); break;
    case 'chatNew': session.startNewSession(); break;
    case 'permissionResponse': if (m.permissionId) session.respondToPermission(m.permissionId, !!m.allow, !!m.remember, m.text); break;
    case 'listProjects': session.loadProjects(); break;
    case 'openProject': if (m.projectId) session.openProject(m.projectId); break;
    case 'listSessions': session.loadSessions(m.projectId); break;
    case 'resumeSession': if (m.sessionRef) session.resume(m.sessionRef); break;
    case 'setAutoApprove': session.setAutoApprove(!!m.autoApprove); break;
    case 'restartProject': session.restart(); break;
    case 'termOpen': if (m.termId) terminal.open(m.termId, m.projectId, session.terminalCwd(m.projectId), m.cols, m.rows); break;
    case 'termInput': if (m.termId) terminal.input(m.termId, m.data); break;
    case 'termResize': if (m.termId) terminal.resize(m.termId, m.cols, m.rows); break;
    case 'termClose': if (m.termId) terminal.close(m.termId); break;
    case 'termRename': if (m.termId) terminal.rename(m.termId, m.text, m.color); break;
    case 'listDir': {
      const root = session.projectRoot(m.projectId);
      if (!root) { bridge.broadcast({ type: 'dirList', file: '', entries: [] }); break; }
      const r = files.list(m.file || '', root);
      bridge.broadcast({ type: 'dirList', file: r.path, entries: r.entries });
      break;
    }
    case 'readFile': {
      const root = session.projectRoot(m.projectId);
      if (!root || !m.file) { bridge.broadcast({ type: 'fileContent', file: m.file, content: 'Open a project first to browse its files.', truncated: false }); break; }
      const r = files.read(m.file, root);
      bridge.broadcast(r
        ? { type: 'fileContent', file: r.path, content: r.content, truncated: r.truncated }
        : { type: 'fileContent', file: m.file, content: "Couldn't read this file.", truncated: false });
      break;
    }
  }
};

// --- best IP for the phone URL (prefer Tailscale) ---
function ips() {
  const out = [];
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const a of ifaces[name] || []) {
      if (a.family === 'IPv4' && !a.internal) out.push(a.address);
    }
  }
  return out;
}
function bestIP() {
  const all = ips();
  const ts = all.find((ip) => { const p = ip.split('.').map(Number); return p[0] === 100 && p[1] >= 64 && p[1] <= 127; });
  return ts || all[0] || 'localhost';
}

session.loadProjects();
process.on('SIGINT', () => { terminal.stopAll(); process.exit(0); });
process.on('SIGTERM', () => { terminal.stopAll(); process.exit(0); });

const ip = bestIP();
console.log('┌─ dev-dock server ────────────────────────────');
console.log('│  PWA:     http://localhost:' + PWA_PORT + '  ·  http://' + ip + ':' + PWA_PORT);
console.log('│  Bridge:  ws://' + ip + ':' + WS_PORT + '   (VS Code extension)');
console.log('│  Terminal: ' + (terminal.enabled ? 'enabled' : 'off (set DEVDOCK_TERMINAL=1)'));
console.log('│  Projects: ' + session.projects.length + ' found in ~/.claude/projects');
console.log('└──────────────────────────────────────────────');
console.log('Open the PWA in a browser, or install it (localhost is a secure context).');
