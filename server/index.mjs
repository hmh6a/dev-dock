#!/usr/bin/env node
// dev-dock server — cross-platform (Linux/macOS/Windows) headless backend.
// Serves the PWA + WebSocket bridge and drives Claude Code, terminals, files and
// project history. Port of the macOS app's AppState wiring. Use it from a browser
// (the PWA) or the VS Code extension.
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ClaudeSession } from './src/session.mjs';
import { TerminalManager } from './src/terminal.mjs';
import { Bridge } from './src/bridge.mjs';
import { startPWA } from './src/pwa.mjs';
import * as files from './src/files.mjs';
import * as auth from './src/auth.mjs';
import * as push from './src/push.mjs';
import * as git from './src/git.mjs';
import { DOMAINS, pairURL } from './src/targets.mjs';

const WS_PORT = Number(process.env.DEVDOCK_WS_PORT || 51888);
const PWA_PORT = Number(process.env.DEVDOCK_PWA_PORT || 51890);
const HOST = process.env.DEVDOCK_HOST || '0.0.0.0';
const PID_FILE = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '.devdock.pid');

auth.loadToken();   // establish the active pairing token before anything can connect
await push.init();  // load/generate VAPID keys + stored subscriptions for OS notifications

const session = new ClaudeSession();
const bridge = new Bridge(WS_PORT, { host: HOST });
const terminal = new TerminalManager({
  broadcast: (m) => bridge.broadcast(m),
  onListChanged: () => bridge.broadcast({ type: 'termList', terminals: terminal.list() }),
  enabled: process.env.DEVDOCK_TERMINAL !== '0',
});
const pwaServer = startPWA(PWA_PORT, { host: HOST, getClients: () => bridge.clients() });
// Also serve the bridge at wss://host/ws on the PWA port, so a reverse proxy
// (Cloudflare/nginx/tailscale) that forwards one port still reaches it.
bridge.attachTo(pwaServer, '/ws');

// --- wire shapes ---
const projectsWire = () => session.projects.map((p) => ({ id: p.id, name: p.path.split('/').pop(), path: p.path, branch: p.gitBranch, sessionCount: p.sessionCount, modified: p.modified }));
const sessionsWire = () => session.sessions.map((s) => ({ id: s.id, title: s.title, messageCount: s.messageCount, modified: s.modified }));
function chatSnapshot() {
  const perm = session.pendingPermission;
  return {
    type: 'chatSnapshot',
    chat: session.messages.map((m) => ({ role: m.role, text: m.text, tools: m.tools, streaming: m.streaming, isError: m.isError, time: m.time || null, durationMs: m.durationMs || null })),
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

// OS push notifications: a turn finished, or a tool needs approval (auto-approve off).
// These reach the phone even when the PWA is closed/backgrounded (unlike the in-app toast).
session.on('turnFinished', (info) => {
  const proj = session.projectName;
  push.notifyAll(info && info.isError
    ? { title: '⚠︎ Claude stopped', body: proj + ' — the turn ended with an error.', tag: 'dd-turn' }
    : { title: '✓ Claude finished', body: proj + ' — your task is done.', tag: 'dd-turn' });
});
session.on('permissionPending', (perm) => {
  push.notifyAll({ title: 'Approval needed', body: (perm && perm.title) || 'Claude wants to run a tool.', tag: 'dd-perm' });
});

// --- connected devices: log to the terminal + push the live list to every client ---
function logDevices(clients) {
  if (!clients.length) { console.log('· devices: none connected'); return; }
  console.log('· devices connected (' + clients.length + '):');
  for (const c of clients) {
    const secs = Math.max(0, Math.round((Date.now() - c.connectedAt) / 1000));
    console.log('    - ' + c.label.padEnd(18) + ' ' + c.ip + '  (' + secs + 's ago)');
  }
}
bridge.onClientsChanged = (clients) => {
  bridge.broadcast({ type: 'deviceList', clients });
  logDevices(clients);
};

bridge.onConnect = (ws) => {
  bridge.sendTo(ws, chatSnapshot());
  bridge.sendTo(ws, { type: 'termList', terminals: terminal.list() });
  bridge.sendTo(ws, { type: 'deviceList', clients: bridge.clients() });
};

// --- Git tab -----------------------------------------------------------------
// Deterministic git/gh operations (list/clone/create/status/commit/pull/push)
// run directly via git.mjs and reply only to the requesting socket. Only merge-
// conflict resolution is handed to the AI session. All of this is already behind
// the shared token (the bridge rejects unauthorized upgrades).
const gitRootFor = (projectId) => session.projectRoot(projectId) || session.cwd || null;
function isUnderCloneDir(p) {
  try { const r = path.resolve(p); return r === git.CLONE_DIR || r.startsWith(git.CLONE_DIR + path.sep); } catch { return false; }
}
async function handleGit(m, ws) {
  const reply = (obj) => bridge.sendTo(ws, obj);
  try {
    switch (m.type) {
      case 'gitListRepos': {
        reply({ type: 'gitBusy', op: 'repos', busy: true });
        const r = await git.listRepos();
        reply({ type: 'gitRepoList', ok: r.ok, repos: r.repos || [], error: r.error || null });
        break;
      }
      case 'gitListOwners': {
        const r = await git.listOwners();
        reply({ type: 'gitOwnerList', ok: r.ok, owners: r.owners || [], login: r.login || null, error: r.error || null });
        break;
      }
      case 'gitStatus': {
        const root = gitRootFor(m.projectId);
        const r = root ? await git.status(root) : { ok: true, isRepo: false };
        reply({ type: 'gitStatusResult', ...r });
        break;
      }
      case 'gitClone': {
        reply({ type: 'gitBusy', op: 'clone', busy: true });
        const r = await git.clone(m.ref);
        let projectId = null;
        if (r.ok && r.path) { const e = session.registerProject(r.path); projectId = e && e.id; }
        reply({ type: 'gitCloneResult', ok: r.ok, path: r.path || null, nameWithOwner: r.nameWithOwner || null, projectId, error: r.error || null });
        break;
      }
      case 'gitCreateRepo': {
        reply({ type: 'gitBusy', op: 'create', busy: true });
        const r = await git.createRepo({ name: m.name, owner: m.owner, isPrivate: m.isPrivate !== false, description: m.description });
        let projectId = null;
        if (r.ok && r.path) { const e = session.registerProject(r.path); projectId = e && e.id; }
        reply({ type: 'gitCreateResult', ok: r.ok, path: r.path || null, nameWithOwner: r.nameWithOwner || null, projectId, error: r.error || null });
        break;
      }
      case 'gitOpen': {   // switch the active project to a cloned/created (or known) repo
        const known = session.projects.find((p) => p.id === m.projectId || p.path === m.path);
        const target = known ? known.path : (m.path && isUnderCloneDir(m.path) ? path.resolve(m.path) : null);
        if (target) { session.openPath(target); reply({ type: 'gitOpened', ok: true, projectId: session.currentProject.id, path: target }); }
        else reply({ type: 'gitOpened', ok: false, error: 'Unknown repo path.' });
        break;
      }
      case 'gitCommit': {
        const r = await git.commit(gitRootFor(m.projectId), m.message);
        reply({ type: 'gitOpResult', op: 'commit', ...r });
        break;
      }
      case 'gitPull': {
        reply({ type: 'gitBusy', op: 'pull', busy: true });
        const r = await git.pull(gitRootFor(m.projectId));
        reply({ type: 'gitOpResult', op: 'pull', ...r });
        break;
      }
      case 'gitPush': {
        reply({ type: 'gitBusy', op: 'push', busy: true });
        const r = await git.push(gitRootFor(m.projectId));
        reply({ type: 'gitOpResult', op: 'push', ...r });
        break;
      }
      case 'gitResolveConflicts': {
        const root = gitRootFor(m.projectId);
        if (!root) { reply({ type: 'gitOpResult', op: 'resolve', ok: false, error: 'Open the repo first.' }); break; }
        if (session.cwd !== root) session.openPath(root);   // point the AI session at the conflicted repo
        session.send(git.resolvePrompt(m.conflicted || []));
        reply({ type: 'gitResolveStarted', ok: true, projectId: session.currentProject && session.currentProject.id });
        break;
      }
    }
  } catch (e) {
    reply({ type: 'gitOpResult', op: m.type, ok: false, error: String((e && e.message) || e) });
  }
}

bridge.onMessage = (m, ws) => {
  if (typeof m.type === 'string' && m.type.startsWith('git')) { handleGit(m, ws); return; }
  switch (m.type) {
    case 'ping': bridge.sendTo(ws, { type: 'pong' }); break;   // client heartbeat — proves the socket is still alive
    case 'listClients': bridge.sendTo(ws, { type: 'deviceList', clients: bridge.clients() }); break;
    case 'resync':   // client returned to the foreground — re-send the full live state
      bridge.sendTo(ws, chatSnapshot());
      bridge.sendTo(ws, { type: 'termList', terminals: terminal.list() });
      bridge.sendTo(ws, { type: 'deviceList', clients: bridge.clients() });
      break;
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

// Write a pidfile so `npm run new-token` can signal us to rotate the token live.
try { fs.writeFileSync(PID_FILE, String(process.pid)); } catch { /* best effort */ }
function shutdown() { terminal.stopAll(); try { fs.unlinkSync(PID_FILE); } catch {} process.exit(0); }
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

// Render a scannable QR of the pairing URL right in the terminal (best-effort).
async function printQR(text) {
  try {
    const { default: qr } = await import('qrcode-terminal');
    await new Promise((resolve) => qr.generate(text, { small: true }, (s) => { process.stdout.write(s); resolve(); }));
  } catch { console.log('  (run `npm install qrcode-terminal` in server/ to show a scannable QR)'); }
}

// The pairing block: token + tokenized URLs + QR. Reprinted whenever the token rotates.
async function printPairing() {
  const token = auth.getToken();
  const ip = bestIP();
  console.log('');
  console.log('🔐 Pairing token: ' + token + (auth.TOKEN_PINNED ? '  (pinned via DEVDOCK_TOKEN)' : ''));
  console.log('   Open on this machine: http://localhost:' + PWA_PORT + '/?token=' + token);
  console.log('   Open from your phone: http://' + ip + ':' + PWA_PORT + '/?token=' + token);
  for (const d of DOMAINS) console.log('   Via domain:           ' + pairURL(d, token));
  console.log('   Scan to pair (pick another address: npm run new-token):');
  await printQR('http://' + ip + ':' + PWA_PORT + '/?token=' + token);
  console.log('');
  console.log('Nobody can connect without this token — the QR and the links carry it.');
  console.log('New token any time:  cd server && npm run new-token');
}

// Live token rotation: `new-token` writes a fresh token to the file and sends
// SIGHUP; we adopt it and kick every connected device so they must re-pair.
process.on('SIGHUP', () => {
  auth.reloadToken();
  const n = bridge.dropAll('token-rotated');
  console.log('\n🔄 Token rotated — ' + n + ' device(s) disconnected; they must re-pair with the new QR.');
  printPairing();
});

const ip = bestIP();
console.log('┌─ dev-dock server ────────────────────────────');
console.log('│  PWA:     http://localhost:' + PWA_PORT + '  ·  http://' + ip + ':' + PWA_PORT);
console.log('│  Bridge:  ws://' + ip + ':' + WS_PORT + '   (VS Code extension)');
console.log('│  Terminal: ' + (terminal.enabled ? 'enabled' : 'off (set DEVDOCK_TERMINAL=1)'));
console.log('│  Notify:   ' + (push.enabled() ? 'OS push ready (finish / approval)' : 'in-app only (npm i web-push for OS push)'));
console.log('│  Projects: ' + session.projects.length + ' found in ~/.claude/projects');
console.log('│  Access:   token required' + (process.env.DEVDOCK_TRUST_LOCAL === '1' ? ' (localhost trusted)' : ' (localhost too)'));
console.log('└──────────────────────────────────────────────');
await printPairing();
