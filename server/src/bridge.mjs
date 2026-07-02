// WebSocket bridge the PWA and the VS Code extension connect to. Port of Swift's
// BridgeServer. Speaks the same flat-JSON protocol.
import { WebSocketServer } from 'ws';

export class Bridge {
  constructor(port) {
    this.wss = new WebSocketServer({ port, host: '0.0.0.0' });
    this.onMessage = null;   // (msg) => void
    this.onConnect = null;   // (ws) => void
    this.wss.on('connection', (ws) => {
      ws.on('message', (data) => {
        let m; try { m = JSON.parse(data.toString()); } catch { return; }
        if (this.onMessage) this.onMessage(m, ws);
      });
      ws.on('error', () => {});
      if (this.onConnect) this.onConnect(ws);
    });
    this.wss.on('error', (e) => console.error('bridge error:', e.message));
  }

  broadcast(obj) {
    const s = JSON.stringify(obj);
    for (const c of this.wss.clients) { if (c.readyState === 1) { try { c.send(s); } catch {} } }
  }
  sendTo(ws, obj) { if (ws.readyState === 1) { try { ws.send(JSON.stringify(obj)); } catch {} } }
}
