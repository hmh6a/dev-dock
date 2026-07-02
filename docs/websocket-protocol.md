# WebSocket Bridge Protocol

The macOS app and the `dev-dock-vscode` extension communicate over a
**localhost WebSocket** using JSON. The app is the **server**, the extension is
the **client**, connecting to `ws://127.0.0.1:<bridgePort>` (default `51888`,
configurable on both sides).

> The app-side WebSocket **server** lands in Phase 2. The extension client and
> this protocol already exist so both ends can be developed against the same
> contract. The canonical definitions live in
> [`BridgeMessage.swift`](../apps/macos/Sources/DevDockCore/BridgeMessage.swift)
> and [`protocol.ts`](../extensions/dev-dock-vscode/src/protocol.ts) — keep them
> in sync.

## Envelope

Every message is a single JSON object with a required `type` and a set of
optional fields:

```jsonc
{
  "type": "activeFile",       // required — see message types below
  "workspace": "…",           // absolute workspace root
  "file": "…",                // absolute file path
  "language": "typescript",   // language id
  "text": "…",                // document/payload text
  "selection": "…",           // selected text
  "command": "npm run dev",   // shell command (runTerminalCommand)
  "content": "…",             // file contents (createFile)
  "line": 42,                 // 1-based line (openFile)
  "column": 5,                // 1-based column (openFile)
  "requestId": "uuid"         // correlates a command with its ack/error
}
```

## Direction: Editor → Dock (context)

Pushed by the extension as the user works.

| `type` | Fields | Meaning |
| ------ | ------ | ------- |
| `hello` | — | Sent on connect. |
| `workspaceInfo` | `workspace` | Active workspace root changed. |
| `activeFile` | `file`, `language` | The focused editor changed. |
| `selection` | `file`, `selection` | The selection changed. |

## Direction: Dock → Editor (commands)

Sent by the app; the extension executes them and replies with `ack` or `error`
(echoing `requestId`).

| `type` | Required fields | Effect |
| ------ | --------------- | ------ |
| `openFile` | `file` (+ optional `line`, `column`) | Open a file and reveal a location. |
| `createFile` | `file` (+ optional `content`) | Create + open a file (relative paths resolve against the workspace root). |
| `replaceSelection` | `text` | Replace the current selection. |
| `insertText` | `text` | Insert at the cursor. |
| `runTerminalCommand` | `command` | Run a command in the integrated terminal. |

## Chat sync (app ↔ clients: extension panel, phone PWA)

| `type` | Fields | Meaning |
| ------ | ------ | ------- |
| `chatSnapshot` | `chat`, `status`, `permission?`, `projectName?` | app → clients: full conversation + working status + active project. |
| `chatSend` | `text` | client → app: submit a message. |
| `chatStop` | — | client → app: stop the current turn. |
| `chatNew` | — | client → app: start a new conversation (same project). |
| `permissionResponse` | `permissionId`, `allow`, `text?` | client → app: answer a tool-permission prompt (`text` = "do this instead"). |

## Project & conversation browsing (any client can pick any project / past chat)

| `type` | Fields | Meaning |
| ------ | ------ | ------- |
| `listProjects` | — | client → app: request the project list. |
| `projectList` | `projects` | app → clients: available projects (`ProjectWire[]`). |
| `openProject` | `projectId` | client → app: switch workspace to that project (app then broadcasts its `sessionList`). |
| `listSessions` | `projectId?` | client → app: request past conversations (defaults to the current project). |
| `sessionList` | `sessions`, `projectName` | app → clients: past conversations for a project (`SessionWire[]`). |
| `resumeSession` | `sessionRef` | client → app: reopen a past conversation (app replays it via `chatSnapshot`). |

`ProjectWire`: `{ id, name, path, branch?, sessionCount, modified }` · `SessionWire`: `{ id, title, messageCount, modified }` (`modified` = epoch seconds).

## Meta / replies

| `type` | Fields | Meaning |
| ------ | ------ | ------- |
| `ack` | `requestId` | Command succeeded. |
| `error` | `requestId`, `text` | Command failed; `text` is the reason. |

## Example exchange

```jsonc
// extension → app, on connect
{ "type": "hello" }
{ "type": "workspaceInfo", "workspace": "/Users/me/dev/dev-dock" }
{ "type": "activeFile", "file": "/Users/me/dev/dev-dock/README.md", "language": "markdown" }

// app → extension
{ "type": "runTerminalCommand", "command": "swift test", "requestId": "a1" }

// extension → app
{ "type": "ack", "requestId": "a1" }
```

## Security

- The bridge (`51888`) and PWA server (`51890`) bind all interfaces so a phone can
  reach them over the LAN or Tailscale. Prefer Tailscale (WireGuard-encrypted,
  reachable only from your tailnet); the Mobile tab lets you pick which address to
  hand out. On an untrusted network, quit the app or firewall these ports.
- No message triggers a shell automatically; `runTerminalCommand` types into the
  visible integrated terminal so the user sees exactly what runs.
- Tool permissions still flow through the app's access-mode policy — a remote
  client can only answer a prompt the app decided to surface.
