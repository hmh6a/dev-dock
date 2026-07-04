// WebSocket bridge the PWA and the VS Code extension connect to. Port of Swift's
// BridgeServer. Speaks the same flat-JSON protocol. Every handshake is gated by a
// shared token (see auth.mjs); unauthorized upgrades are rejected with 401. Each
// live client is tracked (ip, label, connect time) for the connected-devices list.
//
// It accepts connections two ways, sharing one set of clients:
//   1) its own port  — ws://host:51888        (VS Code extension, direct LAN)
//   2) a shared HTTP server on path /ws        (so a reverse proxy — Cloudflare,
//      nginx, tailscale serve — that forwards everything to the PWA port still
//      reaches the bridge at wss://host/ws)
import { WebSocketServer } from 'ws';
import * as auth from './auth.mjs';

export class Bridge {
  constructor(port, { host = '0.0.0.0' } = {}) {
    this.onMessage = null;          // (msg, ws) => void
    this.onConnect = null;          // (ws) => void
    this.onClientsChanged = null;   // (clients[]) => void
    this.info = new Map();          // ws -> { id, ip, label, at } (across both transports)
    this.seq = 0;

    // 1) Own port — direct ws://host:PORT.
    this.wss = new WebSocketServer({ port, host, verifyClient: (i, cb) => this._verify(i.req, cb) });
    this.wss.on('connection', (ws, req) => this._onConn(ws, req));
    this.wss.on('error', (e) => console.error('bridge error:', e.message));

    // 2) Same-origin /ws — upgrades handed in by attachTo() below.
    this.wssShared = new WebSocketServer({ noServer: true });
    this.wssShared.on('connection', (ws, req) => this._onConn(ws, req));
  }

  _verify(req, cb) {
    const r = auth.check(req);
    if (r.ok) return cb(true);
    console.log('· bridge: rejected ' + auth.remoteIP(req) + ' (' + r.reason + ')');
    cb(false, 401, 'Unauthorized');
  }

  _onConn(ws, req) {
    const info = { id: 'c' + (++this.seq), ip: auth.remoteIP(req), label: auth.deviceLabel(req), at: Date.now() };
    this.info.set(ws, info);
    this._changed();
    ws.on('message', (data) => {
      let m; try { m = JSON.parse(data.toString()); } catch { return; }
      if (this.onMessage) this.onMessage(m, ws);
    });
    ws.on('error', () => {});
    ws.on('close', () => { this.info.delete(ws); this._changed(); });
    if (this.onConnect) this.onConnect(ws);
  }

  // Serve wss://host<path> on a shared HTTP server (the PWA port), so a reverse
  // proxy only has to forward one port. Auth is checked before the upgrade.
  attachTo(httpServer, path = '/ws') {
    httpServer.on('upgrade', (req, socket, head) => {
      let pathname = '/';
      try { pathname = new URL(req.url, 'http://x').pathname; } catch { /* keep default */ }
      if (pathname !== path) { socket.destroy(); return; }   // PWA server has no other WS endpoint
      const r = auth.check(req);
      if (!r.ok) {
        console.log('· bridge: rejected ' + auth.remoteIP(req) + ' (' + r.reason + ') on ' + path);
        socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
        socket.destroy();
        return;
      }
      this.wssShared.handleUpgrade(req, socket, head, (ws) => this.wssShared.emit('connection', ws, req));
    });
  }

  _changed() { if (this.onClientsChanged) this.onClientsChanged(this.clients()); }

  clients() {
    return [...this.info.values()].map((c) => ({ id: c.id, ip: c.ip, label: c.label, connectedAt: c.at }));
  }

  // Close every live client (used on token rotation) so they must re-pair.
  dropAll(reason = 'reauth') {
    const all = [...this.info.keys()];
    for (const c of all) { try { c.close(1008, reason); } catch {} }
    return all.length;
  }

  broadcast(obj) {
    const s = JSON.stringify(obj);
    for (const c of this.info.keys()) { if (c.readyState === 1) { try { c.send(s); } catch {} } }
  }
  sendTo(ws, obj) { if (ws.readyState === 1) { try { ws.send(JSON.stringify(obj)); } catch {} } }
}
