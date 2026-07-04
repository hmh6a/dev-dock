import WebSocket from 'ws';
import { BridgeMessage } from './protocol';

type MessageHandler = (message: BridgeMessage) => void;
type StatusHandler = (connected: boolean) => void;

/**
 * A resilient localhost WebSocket client that talks to the dev-dock app.
 *
 * Connects to `ws://127.0.0.1:<port>`, auto-reconnects with a capped backoff,
 * and surfaces incoming commands via `onMessage`. All traffic is JSON-encoded
 * `BridgeMessage` envelopes.
 */
export class BridgeClient {
  private socket: WebSocket | undefined;
  private reconnectTimer: NodeJS.Timeout | undefined;
  private reconnectDelayMs = 1000;
  private readonly maxReconnectDelayMs = 15000;
  private disposed = false;
  private wantConnected = false;

  constructor(
    private readonly port: number,
    private readonly onMessage: MessageHandler,
    private readonly onStatus: StatusHandler,
    private readonly log: (message: string) => void,
    private readonly token: string = ''
  ) {}

  get isConnected(): boolean {
    return this.socket?.readyState === WebSocket.OPEN;
  }

  connect(): void {
    this.wantConnected = true;
    this.openSocket();
  }

  disconnect(): void {
    this.wantConnected = false;
    this.clearReconnect();
    this.socket?.close();
    this.socket = undefined;
    this.onStatus(false);
  }

  dispose(): void {
    this.disposed = true;
    this.disconnect();
  }

  /** Send a message if connected. Returns whether it was actually sent. */
  send(message: BridgeMessage): boolean {
    if (!this.isConnected || !this.socket) {
      return false;
    }
    this.socket.send(JSON.stringify(message));
    return true;
  }

  private openSocket(): void {
    if (this.disposed) {
      return;
    }
    this.clearReconnect();

    // The server gates the bridge with a shared token. Loopback is exempt when it
    // runs with DEVDOCK_TRUST_LOCAL=1; otherwise set devDock.token to the pairing
    // token. Sent both as a header and a query param (belt and suspenders).
    const url = `ws://127.0.0.1:${this.port}${this.token ? `?token=${encodeURIComponent(this.token)}` : ''}`;
    this.log(`Connecting to ws://127.0.0.1:${this.port}…`);
    const socket = new WebSocket(url, this.token ? { headers: { 'x-devdock-token': this.token } } : undefined);
    this.socket = socket;

    socket.on('open', () => {
      this.reconnectDelayMs = 1000;
      this.log('Connected to dev-dock.');
      this.onStatus(true);
      this.send({ type: 'hello' });
    });

    socket.on('message', (data: WebSocket.RawData) => {
      try {
        const message = JSON.parse(data.toString()) as BridgeMessage;
        this.onMessage(message);
      } catch (error) {
        this.log(`Ignoring malformed message: ${String(error)}`);
      }
    });

    socket.on('close', () => {
      this.onStatus(false);
      this.scheduleReconnect();
    });

    // Swallow errors — a refused connection is expected when the app isn't
    // running yet. `close` fires afterwards and drives the reconnect.
    socket.on('error', () => {});
  }

  private scheduleReconnect(): void {
    if (this.disposed || !this.wantConnected) {
      return;
    }
    this.clearReconnect();
    this.log(`Reconnecting in ${this.reconnectDelayMs}ms…`);
    this.reconnectTimer = setTimeout(() => this.openSocket(), this.reconnectDelayMs);
    this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, this.maxReconnectDelayMs);
  }

  private clearReconnect(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
  }
}
