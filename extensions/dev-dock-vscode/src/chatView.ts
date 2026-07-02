import * as vscode from 'vscode';
import { ChatWireMessage, PermissionWire, ProjectWire, SessionWire } from './protocol';

/** Callbacks the panel invokes; wired to the bridge client in `extension.ts`. */
export interface ChatCallbacks {
  onSend: (text: string) => void;
  onStop: () => void;
  onNew: () => void;
  onPermission: (id: string, allow: boolean, message?: string, remember?: boolean) => void;
  onListProjects: () => void;
  onOpenProject: (projectId: string) => void;
  onListSessions: (projectId?: string) => void;
  onResumeSession: (sessionRef: string) => void;
  onSetAutoApprove: (on: boolean) => void;
  onRestart: () => void;
  onOpenTerminal: (path: string) => void;
}

/**
 * A webview chat panel in the VS Code sidebar that mirrors the dev-dock AI
 * conversation in real time. Sending here forwards to the app over the bridge;
 * the app broadcasts snapshots back so both stay in sync. You can also browse
 * and open any project or past conversation from here.
 */
export class ChatViewProvider implements vscode.WebviewViewProvider {
  public static readonly viewType = 'devDock.chat';

  private view?: vscode.WebviewView;
  private lastChat: ChatWireMessage[] = [];
  private lastStatus = '';
  private lastPermission: PermissionWire | null = null;
  private connected = false;
  private projectName = '';
  private autoApprove = false;
  private projects: ProjectWire[] = [];
  private sessions: SessionWire[] = [];

  constructor(private readonly cb: ChatCallbacks) {}

  resolveWebviewView(view: vscode.WebviewView): void {
    this.view = view;
    view.webview.options = { enableScripts: true };
    view.webview.html = this.html();
    view.webview.onDidReceiveMessage((message) => {
      switch (message?.type) {
        case 'send':
          if (typeof message.text === 'string' && message.text.trim()) {
            this.cb.onSend(message.text);
          }
          break;
        case 'stop':
          this.cb.onStop();
          break;
        case 'new':
          this.cb.onNew();
          break;
        case 'permission':
          if (typeof message.id === 'string') {
            this.cb.onPermission(message.id, !!message.allow, message.message, !!message.remember);
          }
          break;
        case 'listProjects':
          this.cb.onListProjects();
          break;
        case 'openProject':
          if (typeof message.projectId === 'string') {
            this.cb.onOpenProject(message.projectId);
          }
          break;
        case 'listSessions':
          this.cb.onListSessions(message.projectId);
          break;
        case 'resumeSession':
          if (typeof message.sessionRef === 'string') {
            this.cb.onResumeSession(message.sessionRef);
          }
          break;
        case 'setAutoApprove':
          this.cb.onSetAutoApprove(!!message.on);
          break;
        case 'restart':
          this.cb.onRestart();
          break;
        case 'openTerminal':
          if (typeof message.path === 'string') {
            this.cb.onOpenTerminal(message.path);
          }
          break;
        case 'ready':
          this.push(); // webview (re)loaded — send current state
          break;
      }
    });
    this.push();
  }

  update(
    chat: ChatWireMessage[],
    status: string,
    permission: PermissionWire | null,
    projectName?: string,
    autoApprove?: boolean
  ): void {
    this.lastChat = chat;
    this.lastStatus = status;
    this.lastPermission = permission;
    if (projectName) {
      this.projectName = projectName;
    }
    if (typeof autoApprove === 'boolean') {
      this.autoApprove = autoApprove;
    }
    this.push();
  }

  updateProjects(projects: ProjectWire[]): void {
    this.projects = projects;
    this.view?.webview.postMessage({ type: 'projects', projects });
  }

  updateSessions(sessions: SessionWire[], projectName?: string): void {
    this.sessions = sessions;
    if (projectName) {
      this.projectName = projectName;
    }
    this.view?.webview.postMessage({ type: 'sessions', sessions, projectName: this.projectName });
  }

  setConnected(connected: boolean): void {
    this.connected = connected;
    this.push();
  }

  private push(): void {
    this.view?.webview.postMessage({
      type: 'snapshot',
      chat: this.lastChat,
      status: this.lastStatus,
      permission: this.lastPermission,
      connected: this.connected,
      projectName: this.projectName,
      autoApprove: this.autoApprove,
    });
  }

  private html(): string {
    return /* html */ `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 0; height: 100vh; display: flex; flex-direction: column; position: relative;
    font-family: var(--vscode-font-family); font-size: var(--vscode-font-size);
    color: var(--vscode-foreground); background: var(--vscode-sideBar-background);
  }
  header {
    display: flex; align-items: center; gap: 6px; padding: 6px 10px;
    border-bottom: 1px solid var(--vscode-panel-border); font-size: 11px;
  }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: #888; flex: none; }
  .dot.on { background: #3fb950; }
  .htitle { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .htitle .name { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .htitle .status { color: var(--vscode-descriptionForeground); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  header button {
    background: transparent; color: var(--vscode-descriptionForeground);
    border: none; cursor: pointer; font-size: 12px; padding: 2px 6px; border-radius: 4px; flex: none;
  }
  header button:hover { background: var(--vscode-toolbar-hoverBackground); }
  #autoBtn.on { background: rgba(63,185,80,0.18); color: #3fb950; }
  .rowterm { flex: none; border: none; background: var(--vscode-toolbar-hoverBackground); color: var(--vscode-foreground);
    border-radius: 6px; cursor: pointer; font-size: 13px; padding: 4px 8px; margin-right: 4px; }
  #log { flex: 1; overflow-y: auto; padding: 10px; display: flex; flex-direction: column; gap: 8px; }
  .msg { max-width: 88%; padding: 7px 10px; border-radius: 10px; white-space: pre-wrap;
    word-wrap: break-word; line-height: 1.4; }
  .user { align-self: flex-end; background: var(--vscode-button-background);
    color: var(--vscode-button-foreground); }
  .assistant { align-self: flex-start; background: var(--vscode-editor-inactiveSelectionBackground); }
  .assistant.error { background: rgba(248,81,73,0.15); }
  .tool { align-self: flex-start; font-size: 11px; display: flex; align-items: baseline; gap: 6px; margin: 1px 0; }
  .tool .tdot { width: 6px; height: 6px; border-radius: 50%; background: #3fb950; flex: none; }
  .tool .tdim { color: var(--vscode-descriptionForeground); }
  #perm { display: none; margin: 8px; padding: 10px; border-radius: 8px;
    background: var(--vscode-editor-inactiveSelectionBackground); border: 1px solid var(--vscode-focusBorder); }
  #perm.show { display: block; }
  #perm .ptitle { font-weight: 600; margin-bottom: 6px; }
  #perm pre { margin: 0 0 8px; padding: 8px; border-radius: 6px; max-height: 120px; overflow: auto;
    background: var(--vscode-textCodeBlock-background, rgba(0,0,0,0.25)); white-space: pre-wrap;
    word-break: break-word; font-size: 11px; font-family: var(--vscode-editor-font-family, monospace); }
  #perm .pbtn { display: block; width: 100%; text-align: left; margin: 4px 0; padding: 7px 10px;
    border: none; border-radius: 6px; cursor: pointer; font-size: 12px; }
  #perm .yes { background: #2ea043; color: #fff; font-weight: 600; }
  #perm .always { background: #1f6f43; color: #fff; font-weight: 600; }
  #perm .no { background: var(--vscode-toolbar-hoverBackground); color: var(--vscode-foreground); }
  .empty { color: var(--vscode-descriptionForeground); font-size: 12px; padding: 8px; }
  footer { padding: 8px; border-top: 1px solid var(--vscode-panel-border); display: flex; gap: 6px; }
  #input {
    flex: 1; resize: none; min-height: 30px; max-height: 120px; padding: 6px 8px; border-radius: 6px;
    background: var(--vscode-input-background); color: var(--vscode-input-foreground);
    border: 1px solid var(--vscode-input-border, transparent); font-family: inherit; font-size: inherit;
  }
  #send { background: var(--vscode-button-background); color: var(--vscode-button-foreground);
    border: none; border-radius: 6px; padding: 0 12px; cursor: pointer; }
  #send:disabled { opacity: 0.5; cursor: default; }
  /* Project / conversation browser */
  #browse { position: absolute; inset: 0; z-index: 20; display: none; flex-direction: column;
    background: var(--vscode-sideBar-background); }
  #browse.show { display: flex; }
  .bhead { display: flex; align-items: center; gap: 6px; padding: 6px 10px;
    border-bottom: 1px solid var(--vscode-panel-border); }
  .btitle { flex: 1; min-width: 0; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  #blist { flex: 1; overflow-y: auto; padding: 8px; display: flex; flex-direction: column; gap: 6px; }
  .brow { display: flex; align-items: center; gap: 8px; padding: 8px 10px; border-radius: 8px; cursor: pointer;
    background: var(--vscode-editor-inactiveSelectionBackground); border: 1px solid transparent; }
  .brow:hover { border-color: var(--vscode-focusBorder); }
  .brow .ic { flex: none; }
  .brow .bbody { flex: 1; min-width: 0; }
  .brow .rt { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .brow .rs { color: var(--vscode-descriptionForeground); font-size: 11px; margin-top: 1px;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .brow .chev { color: var(--vscode-descriptionForeground); flex: none; }
  .brow.newchat { justify-content: center; border-style: dashed;
    border-color: var(--vscode-focusBorder); color: var(--vscode-textLink-foreground); font-weight: 600; }
  .bempty { color: var(--vscode-descriptionForeground); font-size: 12px; padding: 16px; text-align: center; }
</style>
</head>
<body>
  <header>
    <span class="dot" id="dot"></span>
    <button id="browseBtn" title="Projects & conversations">☰</button>
    <div class="htitle">
      <span class="name" id="name">dev-dock</span>
      <span class="status" id="statusText">Connecting to dev-dock…</span>
    </div>
    <button id="autoBtn" title="Auto-approve tool prompts">⚡ Auto</button>
    <button id="restartBtn" title="Restart the project (stop the current turn + fresh chat)">↻ Restart</button>
    <button id="new" title="New conversation">New</button>
  </header>
  <div id="log"><div class="empty">Waiting for the dev-dock app…</div></div>
  <div id="perm">
    <div class="ptitle" id="ptitle"></div>
    <pre id="pbody"></pre>
    <button class="pbtn yes" id="pyes">Yes</button>
    <button class="pbtn always" id="palways" style="display:none">Yes, and don't ask again</button>
    <button class="pbtn no" id="pno">No</button>
  </div>
  <footer>
    <textarea id="input" placeholder="Message Claude Code…" rows="1"></textarea>
    <button id="send">Send</button>
  </footer>

  <div id="browse">
    <div class="bhead">
      <button id="bback">‹</button>
      <span class="btitle" id="btitle">Projects</span>
      <button id="bnew">New chat</button>
    </div>
    <div id="blist"></div>
  </div>
<script>
  const vscode = acquireVsCodeApi();
  const esc = (s) => (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const $ = (id) => document.getElementById(id);
  const log = $('log'), input = $('input'), sendBtn = $('send'), dot = $('dot');
  const nameEl = $('name'), statusText = $('statusText');
  const perm = $('perm'), ptitle = $('ptitle'), pbody = $('pbody');
  const panel = $('browse'), blist = $('blist'), btitle = $('btitle'), bnew = $('bnew');
  const autoBtn = $('autoBtn');

  let streaming = false, permission = null, connected = false;
  let autoApprove = false;
  let activeProject = '';
  let projects = [], sessions = [], browseView = null; // null | 'projects' | 'sessions'

  function answer(allow, message, remember) {
    if (!permission) return;
    vscode.postMessage({ type: 'permission', id: permission.id, allow, message, remember });
    permission = null;
    perm.classList.remove('show');
  }
  $('pyes').addEventListener('click', () => answer(true));
  $('palways').addEventListener('click', () => answer(true, undefined, true));
  $('pno').addEventListener('click', () => answer(false));

  function render(chat, status) {
    dot.className = 'dot' + (connected ? ' on' : '');
    streaming = chat.some((m) => m.streaming);
    nameEl.textContent = activeProject || 'dev-dock';
    statusText.textContent = connected ? (status || (streaming ? 'Working…' : 'Connected')) : 'dev-dock app not running';
    sendBtn.textContent = streaming ? 'Stop' : 'Send';
    if (!chat.length) {
      log.innerHTML = '<div class="empty">' + (connected ? 'Start chatting — in sync with the dev-dock app.' : 'Open the dev-dock menu bar app to connect.') + '</div>';
      return;
    }
    log.innerHTML = '';
    for (const m of chat) {
      if (m.tools && m.tools.length) {
        for (const tool of m.tools) {
          const sp = tool.indexOf(' ');
          const nm = sp === -1 ? tool : tool.slice(0, sp);
          const detail = sp === -1 ? '' : tool.slice(sp + 1);
          const line = document.createElement('div');
          line.className = 'tool';
          line.innerHTML = '<span class="tdot"></span><span><b>' + esc(nm) + '</b> <span class="tdim">' + esc(detail) + '</span></span>';
          log.appendChild(line);
        }
      }
      const text = m.text || (m.streaming ? (status || 'Working…') : '');
      if (text) {
        const el = document.createElement('div');
        el.className = 'msg ' + m.role + (m.isError ? ' error' : '');
        el.textContent = text;
        log.appendChild(el);
      }
    }
    log.scrollTop = log.scrollHeight;
  }

  // --- Project / conversation browser ---
  function relTime(sec) {
    if (!sec) return '';
    const d = Date.now() / 1000 - sec;
    if (d < 60) return 'just now';
    if (d < 3600) return Math.floor(d / 60) + 'm ago';
    if (d < 86400) return Math.floor(d / 3600) + 'h ago';
    if (d < 604800) return Math.floor(d / 86400) + 'd ago';
    return Math.floor(d / 604800) + 'w ago';
  }
  function openBrowse() { browseView = 'projects'; panel.classList.add('show'); vscode.postMessage({ type: 'listProjects' }); renderBrowse(); }
  function closeBrowse() { browseView = null; panel.classList.remove('show'); }
  function back() { if (browseView === 'sessions') { browseView = 'projects'; renderBrowse(); } else closeBrowse(); }
  function pickProject(p) { browseView = 'sessions'; sessions = []; activeProject = p.name; vscode.postMessage({ type: 'openProject', projectId: p.id }); renderBrowse(); }
  function resume(s) { vscode.postMessage({ type: 'resumeSession', sessionRef: s.id }); closeBrowse(); }
  function newChat() { vscode.postMessage({ type: 'new' }); closeBrowse(); }

  function makeRow(icon, title, subtitle, chev, onClick) {
    const el = document.createElement('div');
    el.className = 'brow';
    el.innerHTML = '<span class="ic"></span><div class="bbody"><div class="rt"></div><div class="rs"></div></div><span class="chev"></span>';
    el.querySelector('.ic').textContent = icon;
    el.querySelector('.rt').textContent = title;
    el.querySelector('.rs').textContent = subtitle;
    el.querySelector('.chev').textContent = chev;
    el.addEventListener('click', onClick);
    return el;
  }
  function renderBrowse() {
    if (browseView === 'projects') {
      btitle.textContent = 'Projects';
      bnew.style.display = 'none';
      blist.innerHTML = '';
      if (!projects.length) { blist.innerHTML = '<div class="bempty">No projects yet. Start a chat in the app first.</div>'; return; }
      for (const p of projects) {
        const meta = [(p.sessionCount || 0) + ' chat' + (p.sessionCount === 1 ? '' : 's'), p.branch, relTime(p.modified)].filter(Boolean).join(' · ');
        const el = makeRow('📁', p.name || p.path, meta, '›', () => pickProject(p));
        const tb = document.createElement('button');
        tb.className = 'rowterm';
        tb.textContent = '⌨';
        tb.title = 'Open a terminal here';
        tb.addEventListener('click', (e) => { e.stopPropagation(); vscode.postMessage({ type: 'openTerminal', path: p.path }); });
        el.insertBefore(tb, el.querySelector('.chev'));
        blist.appendChild(el);
      }
    } else if (browseView === 'sessions') {
      btitle.textContent = activeProject || 'Conversations';
      bnew.style.display = '';
      blist.innerHTML = '';
      const nc = document.createElement('div');
      nc.className = 'brow newchat';
      nc.textContent = '+ New chat here';
      nc.addEventListener('click', newChat);
      blist.appendChild(nc);
      if (!sessions.length) {
        const e = document.createElement('div'); e.className = 'bempty'; e.textContent = 'No past conversations here yet.';
        blist.appendChild(e);
      } else {
        for (const s of sessions) {
          const meta = [(s.messageCount || 0) + ' msgs', relTime(s.modified)].filter(Boolean).join(' · ');
          blist.appendChild(makeRow('💬', s.title || 'Untitled', meta, '↩', () => resume(s)));
        }
      }
    }
  }

  function submit() {
    if (permission) {
      const t = input.value.trim();
      if (t) { answer(false, t); input.value = ''; autosize(); }
      return;
    }
    if (streaming) { vscode.postMessage({ type: 'stop' }); return; }
    const text = input.value.trim();
    if (!text) return;
    vscode.postMessage({ type: 'send', text });
    input.value = '';
    autosize();
  }

  function autosize() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 120) + 'px';
  }

  sendBtn.addEventListener('click', submit);
  $('new').addEventListener('click', () => vscode.postMessage({ type: 'new' }));
  $('restartBtn').addEventListener('click', () => vscode.postMessage({ type: 'restart' }));
  $('browseBtn').addEventListener('click', openBrowse);
  autoBtn.addEventListener('click', () => {
    autoApprove = !autoApprove;
    autoBtn.classList.toggle('on', autoApprove);
    vscode.postMessage({ type: 'setAutoApprove', on: autoApprove });
  });
  $('bback').addEventListener('click', back);
  bnew.addEventListener('click', newChat);
  input.addEventListener('input', autosize);
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); }
  });

  window.addEventListener('message', (event) => {
    const m = event.data;
    if (m.type === 'projects') {
      projects = m.projects || [];
      if (browseView === 'projects') renderBrowse();
      return;
    }
    if (m.type === 'sessions') {
      sessions = m.sessions || [];
      if (m.projectName) activeProject = m.projectName;
      if (browseView === 'sessions') renderBrowse();
      return;
    }
    if (m.type !== 'snapshot') return;
    connected = !!m.connected;
    if (m.projectName) activeProject = m.projectName;
    if (typeof m.autoApprove === 'boolean') { autoApprove = m.autoApprove; autoBtn.classList.toggle('on', autoApprove); }
    permission = m.permission || null;
    if (permission) {
      ptitle.textContent = permission.title || 'Allow this action?';
      pbody.textContent = permission.body || '';
      pbody.style.display = permission.body ? 'block' : 'none';
      $('palways').style.display = permission.canRemember ? 'block' : 'none';
      perm.classList.add('show');
      input.placeholder = 'Tell Claude what to do instead…';
    } else {
      perm.classList.remove('show');
      input.placeholder = 'Message Claude Code…';
    }
    render(m.chat || [], m.status || '');
  });

  vscode.postMessage({ type: 'ready' });
</script>
</body>
</html>`;
  }
}
