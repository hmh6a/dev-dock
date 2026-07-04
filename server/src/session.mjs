// Drives a Claude Code conversation by spawning agent-runner/runner.mjs per turn
// and parsing its stream-json. Port of Swift's ClaudeCodeSession. Emits 'change'
// (conversation/status), 'projects', 'sessions' so the server can broadcast.
import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { parseStreamLine } from './streamParser.mjs';
import * as history from './history.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RUNNER = process.env.DEVDOCK_AGENT_RUNNER || path.resolve(__dirname, '../../agent-runner/runner.mjs');

const VERBS = ['Ideating', 'Manifesting', 'Conjuring', 'Pondering', 'Divining', 'Percolating', 'Ruminating', 'Synthesizing', 'Cogitating', 'Noodling', 'Formulating', 'Marinating', 'Brewing', 'Scheming', 'Contemplating'];

const rid = () => crypto.randomUUID();
const base = (p) => (p ? String(p).split('/').pop() : 'file');
const shortInput = (input) => { try { return JSON.stringify(input).slice(0, 400); } catch { return ''; } };
const encodeProjectId = (p) => String(p).replace(/\//g, '-');

function makePermission(id, tool, input, sdkTitle, sdkDescription, canRemember) {
  let title, body;
  switch (tool) {
    case 'Bash': title = 'Allow this command?'; body = input.command || ''; break;
    case 'Write': title = `Allow writing ${base(input.file_path)}?`; body = String(input.content || '').slice(0, 400); break;
    case 'Edit': case 'NotebookEdit': title = `Allow editing ${base(input.file_path || input.notebook_path)}?`; body = shortInput(input); break;
    default: title = `Allow ${tool}?`; body = shortInput(input);
  }
  if (sdkTitle) title = sdkTitle;
  if (sdkDescription) body = sdkDescription + (body ? '\n\n' + body : '');
  return { id, tool, title, body, canRemember: !!canRemember };
}

export class ClaudeSession extends EventEmitter {
  constructor() {
    super();
    this.messages = [];
    this.isStreaming = false;
    this.statusText = '';
    this.totalCostUSD = 0;
    this.streamingTokens = 0;
    this.workingVerb = 'Thinking';
    this.autoApprove = false;
    this.accessMode = process.env.DEVDOCK_ACCESS || 'ask';  // safe | ask | full
    this.pendingPermission = null;
    this.cwd = os.homedir();
    this.currentProject = null;
    this.projects = [];
    this.sessions = [];
    this.sessionId = rid();
    this.hasStarted = false;
    this.proc = null;
    this.verbTimer = null;
    this.streamingChars = 0;
    this._suppressFinishNotify = false;   // set when we kill the runner on purpose (stop/new)
  }

  get projectName() { return this.currentProject ? this.currentProject.name : (path.basename(this.cwd) || '~'); }
  get displayStatus() {
    if (!this.isStreaming) return this.statusText;
    const tokens = this.streamingTokens > 0 ? ` · ${this.streamingTokens} tokens` : '';
    return `${this.workingVerb}…${tokens}`;
  }
  _change() { this.emit('change'); }

  send(text, attachments = []) {
    text = (text || '').trim();
    if (this.isStreaming || (!text && !attachments.length)) return;
    this.messages.push({ id: rid(), role: 'user', text, tools: [], streaming: false, isError: false, attachments, time: Date.now() });

    let prompt = text;
    if (attachments.length) {
      const lead = text ? text + '\n\nAttached image(s) — view them with the Read tool:' : 'Please view the attached image(s) using the Read tool:';
      prompt = lead + '\n' + attachments.join('\n');
    }

    const assistant = { id: rid(), role: 'assistant', text: '', tools: [], streaming: true, isError: false, attachments: [], time: Date.now() };
    this.messages.push(assistant);
    this.isStreaming = true; this.streamingChars = 0; this.streamingTokens = 0; this.workingVerb = 'Thinking'; this.statusText = 'Thinking…';
    this._startVerbs();
    this._change();

    const config = {
      prompt, cwd: this.cwd,
      permissionMode: this.accessMode === 'full' ? 'bypassPermissions' : 'default',
      allowedTools: this.accessMode === 'safe' ? ['Read', 'Grep', 'Glob', 'WebFetch', 'WebSearch', 'NotebookRead'] : [],
      resume: this.hasStarted, sessionId: this.sessionId,
    };
    this._run(config, assistant);
  }

  _run(config, assistant) {
    let proc;
    try {
      proc = spawn(process.execPath, [RUNNER, JSON.stringify(config)], { cwd: config.cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    } catch (e) {
      assistant.text = 'Failed to launch runner: ' + (e && e.message || e); assistant.isError = true; assistant.streaming = false;
      this.isStreaming = false; this._stopVerbs(); this._change(); return;
    }
    this.proc = proc;
    let buf = '';
    proc.stdout.on('data', (d) => {
      buf += d.toString('utf8');
      let idx;
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx); buf = buf.slice(idx + 1);
        if (line.trim()) this._handleLine(line, assistant);
      }
    });
    let stderr = '';
    proc.stderr.on('data', (d) => { stderr += d.toString('utf8'); });
    proc.on('close', (code) => this._finalize(assistant, code, stderr));
    proc.on('error', (e) => this._finalize(assistant, -1, String(e && e.message || e)));
  }

  _handleLine(line, assistant) {
    let obj = null; try { obj = JSON.parse(line); } catch {}
    if (obj && obj.type === 'permission_request') { this._handlePermission(obj); return; }
    if (obj && obj.type === 'runner_error') { assistant.text += (obj.message || 'Runner error'); assistant.isError = true; this._change(); return; }
    if (obj && obj.type === 'runner_done') return;
    for (const ev of parseStreamLine(line)) this._handleEvent(ev, assistant);
  }

  _handleEvent(ev, assistant) {
    switch (ev.kind) {
      case 'sessionStarted': if (ev.sessionId) this.sessionId = ev.sessionId; this.statusText = 'Working…'; break;
      case 'assistantBlockStart': if (assistant.text && !assistant.text.endsWith('\n')) assistant.text += '\n\n'; break;
      case 'thinkingDelta': this.streamingChars += ev.text.length; this.streamingTokens = Math.floor(this.streamingChars / 4); break;
      case 'assistantDelta': this.streamingChars += ev.text.length; this.streamingTokens = Math.floor(this.streamingChars / 4); assistant.text += ev.text; this.statusText = 'Responding…'; break;
      case 'assistantText': if (!assistant.text) assistant.text = ev.text; break;
      case 'toolUse': if (!assistant.tools.includes(ev.name)) assistant.tools.push(ev.name); this.statusText = `Using ${ev.name}…`; break;
      case 'result': if (ev.costUSD) this.totalCostUSD += ev.costUSD; if (!assistant.text && ev.text) assistant.text = ev.text; if (ev.isError) assistant.isError = true; break;
    }
    this._change();
  }

  _handlePermission(obj) {
    const id = obj.id, tool = obj.tool;
    if (!id || !tool) return;
    if (this.accessMode === 'full') { this.respondToPermission(id, true); return; }
    if (this.accessMode === 'safe') { this.respondToPermission(id, false, false, 'Read-only mode — denied'); return; }
    if (this.autoApprove) { this.respondToPermission(id, true); return; }
    this.pendingPermission = makePermission(id, tool, obj.input || {}, obj.title, obj.description, obj.canRemember);
    this.statusText = 'Waiting for approval…';
    this._change();
    this.emit('permissionPending', this.pendingPermission);   // -> OS push notification
  }

  respondToPermission(id, allow, remember = false, message = null) {
    const reply = { type: 'permission', id, allow };
    if (remember) reply.remember = true;
    if (message) reply.message = message;
    try { this.proc && this.proc.stdin.write(JSON.stringify(reply) + '\n'); } catch {}
    if (this.pendingPermission && this.pendingPermission.id === id) { this.pendingPermission = null; this._change(); }
  }

  _finalize(assistant, code, stderr) {
    this.hasStarted = true; this.isStreaming = false; this._stopVerbs(); this.statusText = ''; this.proc = null;
    assistant.streaming = false; this.pendingPermission = null;
    // How long this prompt took, start (send) → now (turn finished).
    if (assistant.time) assistant.durationMs = Date.now() - assistant.time;
    if (!assistant.text) {
      const detail = (stderr || '').trim();
      assistant.text = detail || `No response (runner exited with code ${code}).`;
      assistant.isError = true;
    }
    this._change();
    // Notify (OS push) that the turn is done — unless we killed it ourselves.
    if (this._suppressFinishNotify) { this._suppressFinishNotify = false; }
    else this.emit('turnFinished', { isError: assistant.isError, text: assistant.text });
  }

  stop() {
    if (this.proc) { this._suppressFinishNotify = true; try { this.proc.kill(); } catch {} this.proc = null; }
    this._stopVerbs(); this.isStreaming = false; this.pendingPermission = null; this.statusText = 'Stopped';
    const last = this.messages[this.messages.length - 1];
    if (last && last.role === 'assistant') { last.streaming = false; if (last.time && last.durationMs == null) last.durationMs = Date.now() - last.time; }
    this._change();
  }

  startNewSession() {
    if (this.proc) { this._suppressFinishNotify = true; try { this.proc.kill(); } catch {} this.proc = null; }
    this._stopVerbs();
    this.messages = []; this.sessionId = rid(); this.hasStarted = false; this.totalCostUSD = 0;
    this.statusText = ''; this.isStreaming = false; this.pendingPermission = null;
    this._change();
  }
  restart() { this.startNewSession(); }

  setAutoApprove(v) { this.autoApprove = !!v; this._change(); }

  // --- Projects / history ---
  loadProjects() { this.projects = history.listProjects(); this.emit('projects', this.projects); }
  openProject(id) {
    const p = this.projects.find((x) => x.id === id);
    if (!p) return;
    this.currentProject = { id: p.id, path: p.path, name: path.basename(p.path) };
    this.cwd = p.path;
    this.startNewSession();
    this.loadSessions(id);
  }
  // Surface an arbitrary directory in the projects list WITHOUT switching to it —
  // used by the Git tab so a freshly cloned/created repo (which has no ~/.claude
  // history yet, so loadProjects() can't find it) is openable without disrupting
  // an in-progress chat. Deduped by path.
  registerProject(absPath, displayName) {
    if (!absPath) return null;
    const existing = this.projects.find((p) => p.path === absPath);
    if (existing) return { id: existing.id, path: absPath, name: displayName || path.basename(absPath) };
    const id = encodeProjectId(absPath);
    this.projects.unshift({ id, path: absPath, gitBranch: null, sessionCount: 0, modified: Date.now() / 1000 });
    this.emit('projects', this.projects);
    return { id, path: absPath, name: displayName || path.basename(absPath) };
  }

  // Open an arbitrary directory as the active project (registers it, then switches
  // cwd + starts a fresh session there).
  openPath(absPath, displayName) {
    const entry = this.registerProject(absPath, displayName);
    if (!entry) return null;
    this.currentProject = { id: entry.id, path: absPath, name: entry.name };
    this.cwd = absPath;
    this.startNewSession();
    return entry;
  }

  loadSessions(id) {
    const pid = id || (this.currentProject && this.currentProject.id);
    if (!pid) return;
    this.sessions = history.listSessions(pid);
    this.emit('sessions', this.sessions);
  }
  resume(sessionRef) {
    const s = this.sessions.find((x) => x.id === sessionRef);
    if (!s) return;
    this.cwd = s.projectPath;
    if (!this.currentProject || this.currentProject.path !== s.projectPath) {
      const proj = this.projects.find((x) => x.path === s.projectPath);
      this.currentProject = proj
        ? { id: proj.id, path: proj.path, name: path.basename(proj.path) }
        : { id: encodeProjectId(s.projectPath), path: s.projectPath, name: path.basename(s.projectPath) };
    }
    const msgs = history.transcript(sessionRef, this.currentProject.id);
    this.messages = msgs.slice(-120).map((m) => ({ id: m.id, role: m.role, text: m.text, tools: m.tools, streaming: false, isError: false, attachments: [], time: m.time || null }));
    // How long each past prompt took: for every user message, tag the LAST
    // assistant reply before the next user prompt with (that reply's time − the
    // prompt's time). Gives the same per-turn duration the live path records.
    for (let i = 0; i < this.messages.length; i++) {
      if (this.messages[i].role !== 'user' || !this.messages[i].time) continue;
      let lastA = null;
      for (let j = i + 1; j < this.messages.length && this.messages[j].role !== 'user'; j++) {
        if (this.messages[j].role === 'assistant' && this.messages[j].time) lastA = this.messages[j];
      }
      if (lastA) lastA.durationMs = Math.max(0, lastA.time - this.messages[i].time);
    }
    this.sessionId = sessionRef; this.hasStarted = true; this.statusText = '';
    this._change();
  }

  // Project root for the file browser: only a real opened project (never home).
  projectRoot(projectId) {
    if (projectId) { const p = this.projects.find((x) => x.id === projectId); if (p) return p.path; }
    if (this.currentProject) return this.currentProject.path;
    return null;
  }
  // Terminal cwd: the requested/current project, else home.
  terminalCwd(projectId) {
    if (projectId) { const p = this.projects.find((x) => x.id === projectId); if (p) return p.path; }
    if (this.currentProject) return this.currentProject.path;
    return this.cwd || os.homedir();
  }

  _startVerbs() {
    this._stopVerbs();
    let i = 0;
    this.verbTimer = setInterval(() => {
      if (!this.isStreaming) { this._stopVerbs(); return; }
      this.workingVerb = VERBS[i % VERBS.length]; i++;
      this._change();
    }, 1600);
  }
  _stopVerbs() { if (this.verbTimer) { clearInterval(this.verbTimer); this.verbTimer = null; } }
}
