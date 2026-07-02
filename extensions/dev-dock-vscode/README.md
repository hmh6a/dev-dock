# dev-dock — VS Code extension

Bridges VS Code with the dev-dock menu bar cockpit over a localhost WebSocket.

## What it does

- **Synced AI chat panel** — a dev-dock icon in the activity bar opens a chat
  that **mirrors the dev-dock app conversation in real time, both ways**: type in
  VS Code and it appears in the app; type in the app and it appears here. Same
  live Claude Code session, streamed token-by-token over the localhost bridge.
- **Streams editor context** to the cockpit: active workspace, active file (with
  language), and the current selection — updated as you move around.
- **Executes commands** from the cockpit: `openFile`, `createFile`,
  `replaceSelection`, `insertText`, `runTerminalCommand`.
- Shows a status-bar item and auto-reconnects if the app isn't running yet.

## Using the synced chat

1. Run the dev-dock macOS app (it starts the WebSocket server on `51888`).
2. Open the **dev-dock** icon in the VS Code activity bar → **AI Chat**.
3. A green dot means connected. Type in either place — they stay in sync.

See [`../../docs/websocket-protocol.md`](../../docs/websocket-protocol.md) for
the message contract.

## Develop

```bash
npm install
npm run compile     # or: npm run watch
```

Press <kbd>F5</kbd> in VS Code to launch an Extension Development Host with the
extension loaded.

## Commands

| Command | Palette title |
| ------- | ------------- |
| `devDock.connect` | dev-dock: Connect to cockpit |
| `devDock.disconnect` | dev-dock: Disconnect |
| `devDock.sendContext` | dev-dock: Send current context |

## Settings

| Setting | Default | Description |
| ------- | ------- | ----------- |
| `devDock.bridgePort` | `51888` | Localhost WebSocket port. |
| `devDock.autoConnect` | `true` | Connect automatically on startup. |

## Requirements

- VS Code 1.85+
- The dev-dock macOS app running the bridge server (Phase 2). Until then the
  extension simply retries the connection in the background.
