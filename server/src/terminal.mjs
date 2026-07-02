// Server-owned terminal sessions via node-pty. Port of Swift's TerminalManager:
// each shell keeps title/colour/scrollback so every device sees the same tabs and
// a reconnecting client catches up.
import os from 'node:os';

let ptyMod = null;
let ptyTried = false;
async function loadPty() {
  if (ptyTried) return ptyMod;
  ptyTried = true;
  try { ptyMod = await import('node-pty'); } catch { ptyMod = null; }
  return ptyMod;
}

const b64 = (s) => Buffer.from(s, 'utf8').toString('base64');

export class TerminalManager {
  constructor({ broadcast, onListChanged, enabled }) {
    this.broadcast = broadcast;              // (msg) => void
    this.onListChanged = onListChanged;      // () => void
    this.enabled = enabled !== false;
    this.entries = new Map();                // id -> { pty, title, color, projectId, buffer:Buffer }
    this.order = [];
    this.maxBuffer = 120_000;
  }

  list() {
    return this.order.filter((id) => this.entries.has(id)).map((id) => {
      const e = this.entries.get(id);
      return { id, title: e.title, color: e.color, projectId: e.projectId || null };
    });
  }

  async open(id, projectId, cwd, cols, rows) {
    if (!id) return;
    if (!this.enabled) {
      this.broadcast({ type: 'termData', termId: id, data: b64('\r\n\x1b[31mTerminal is off. Start the server with DEVDOCK_TERMINAL=1 to enable it.\x1b[0m\r\n') });
      this.broadcast({ type: 'termExit', termId: id });
      return;
    }
    const mod = await loadPty();
    if (!mod) {
      this.broadcast({ type: 'termData', termId: id, data: b64('\r\n\x1b[31mTerminal unavailable: node-pty failed to load. In server/: npm install (needs build tools).\x1b[0m\r\n') });
      this.broadcast({ type: 'termExit', termId: id });
      return;
    }

    const existing = this.entries.get(id);
    if (existing) {
      try { existing.pty.resize(Math.max(2, cols || 80), Math.max(2, rows || 24)); } catch {}
      this.broadcast({ type: 'termData', termId: id, data: existing.buffer.toString('base64'), reset: true });
      this.onListChanged();
      return;
    }

    const shell = process.env.SHELL || (process.platform === 'win32' ? 'powershell.exe' : '/bin/bash');
    const args = process.platform === 'win32' ? [] : ['-i', '-l'];
    let p;
    try {
      p = mod.spawn(shell, args, {
        name: 'xterm-256color',
        cols: Math.max(2, cols || 80),
        rows: Math.max(2, rows || 24),
        cwd: cwd || os.homedir(),
        env: { ...process.env, TERM: 'xterm-256color', LANG: process.env.LANG || 'en_US.UTF-8' },
      });
    } catch (e) {
      this.broadcast({ type: 'termData', termId: id, data: b64('\r\n\x1b[31mFailed to start shell: ' + (e && e.message || e) + '\x1b[0m\r\n') });
      this.broadcast({ type: 'termExit', termId: id });
      return;
    }

    const entry = { pty: p, title: `sh ${this.order.length + 1}`, color: '', projectId: projectId || null, buffer: Buffer.alloc(0) };
    this.entries.set(id, entry);
    this.order.push(id);

    p.onData((d) => {
      const data = Buffer.from(d, 'utf8');
      entry.buffer = Buffer.concat([entry.buffer, data]);
      if (entry.buffer.length > this.maxBuffer) entry.buffer = entry.buffer.subarray(entry.buffer.length - this.maxBuffer);
      this.broadcast({ type: 'termData', termId: id, data: data.toString('base64') });
    });
    p.onExit(() => {
      this.broadcast({ type: 'termExit', termId: id });
      this.entries.delete(id);
      this.order = this.order.filter((x) => x !== id);
      this.onListChanged();
    });
    this.onListChanged();
  }

  input(id, base64) {
    const e = this.entries.get(id);
    if (e && base64) { try { e.pty.write(Buffer.from(base64, 'base64').toString('utf8')); } catch {} }
  }
  resize(id, cols, rows) {
    const e = this.entries.get(id);
    if (e) { try { e.pty.resize(Math.max(2, cols || 80), Math.max(2, rows || 24)); } catch {} }
  }
  rename(id, title, color) {
    const e = this.entries.get(id);
    if (!e) return;
    if (title && title.trim()) e.title = title.trim();
    if (color != null) e.color = color;
    this.onListChanged();
  }
  close(id) {
    const e = this.entries.get(id);
    if (e) { try { e.pty.kill(); } catch {} }
    this.entries.delete(id);
    this.order = this.order.filter((x) => x !== id);
    this.onListChanged();
  }
  stopAll() {
    for (const e of this.entries.values()) { try { e.pty.kill(); } catch {} }
    this.entries.clear();
    this.order = [];
  }
}
