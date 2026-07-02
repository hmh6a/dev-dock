# dev-dock

A native macOS **menu bar developer cockpit** — everything a developer reaches
for, one keystroke away, without juggling Terminal, Docker Desktop, Activity
Monitor, and a browser. Think Raycast, but built entirely for software
development.

> **Status:** MVP. The **Ports** manager is fully implemented; other tabs are
> scaffolded for the roadmap below.

---

## Repository layout

```text
dev-dock/
├── apps/
│   └── macos/                 # Native SwiftUI menu bar app (Swift Package)
│       ├── Sources/
│       │   ├── DevDockCore/   # Testable logic: lsof parsing, services, bridge protocol
│       │   └── DevDockApp/    # SwiftUI MenuBarExtra UI
│       └── Tests/             # XCTest unit tests for DevDockCore
├── extensions/
│   └── dev-dock-vscode/       # VS Code extension: synced chat panel + editor bridge
├── agent-runner/              # Node adapter for the Claude Agent SDK (permission approvals)
├── docs/                      # Architecture & protocol docs
├── helper/                    # (Future) privileged helper for elevated actions
└── README.md
```

## What works today (MVP)

- **Menu bar app** — native `MenuBarExtra`, dark/light aware, resizable popover,
  no Dock icon.
- **Ports tab** — live list of listening TCP ports via
  `lsof -iTCP -sTCP:LISTEN -n -P`, with:
  - Recognized **development ports shown first** (Vite, PostgreSQL, Redis, …),
    each tagged with its service
  - Open `localhost` in the browser
  - Copy URL
  - Kill the owning process (with confirmation)
  - Filter and refresh
- **AI tab** — a **real Claude Code chat**, driven by the local `claude` CLI in
  streaming mode:
  - **Projects → Conversations → Chat** flow: pick one of your projects, browse
    its past Claude Code conversations, and **resume any of them** — the same
    sessions you started in your editor, continued from the menu bar
  - Pick the **Agent**, **Model** (Opus / Sonnet / Haiku), and **reasoning
    Effort** (low → max)
  - **Live token-by-token streaming**, with markdown rendering (copyable code
    blocks + images)
  - **Interactive permission approvals** ("Allow this command? Yes / No / do this
    instead") — powered by the Claude Agent SDK (`agent-runner/`), and **synced to
    the VS Code panel** so you can approve from either place
  - Three access modes: **Read-only** (auto-deny) / **Ask** (prompt) / **Full auto**
  - Live working indicators ("Thinking… · N tokens", rotating verbs) and tool
    activity ("Read AIView.swift (lines 311-328)")
  - Runs in the selected project's folder, so it sees the same files as your editor
- **Remote tab** — start Claude Code's official **Remote Control** server for a
  project from inside dev-dock, and scan the **in-app QR code** to drive your Mac
  from the Claude mobile app / claude.ai while you're away.
- **Other tabs** (Processes, Docker, Projects, Logs, Settings) — scaffolded
  placeholders.
- **VS Code extension skeleton** — connects over a localhost WebSocket, streams
  workspace/active-file/selection context, and handles `openFile`, `createFile`,
  `replaceSelection`, `insertText`, and `runTerminalCommand`.

## Quick start

### One command (everything)

```bash
./run.sh
```

Installs deps (first run only), compiles the VS Code extension, builds and
launches the app. Use `./run.sh --setup` to prepare everything without launching.
Then open the **dev-dock** icon in the VS Code sidebar (or press <kbd>F5</kbd> in
`extensions/dev-dock-vscode`) for the synced chat panel.

### macOS app

```bash
cd agent-runner && npm install && cd ..   # AI engine (Claude Agent SDK) — one time
cd apps/macos
swift build            # compile
swift test             # run the unit tests
swift run DevDock      # launch — look for the box icon in the menu bar
```

Or open `apps/macos/Package.swift` in Xcode and run the `DevDock` scheme.

### VS Code extension

```bash
cd extensions/dev-dock-vscode
npm install
npm run compile
```

Then press <kbd>F5</kbd> in VS Code to launch an Extension Development Host.

## Architecture

Logic lives in **`DevDockCore`** (a plain, dependency-free Swift library) so it
stays unit-testable without a running UI or a live system. The SwiftUI app is a
thin shell over it. See [`docs/architecture.md`](docs/architecture.md) and the
[`docs/websocket-protocol.md`](docs/websocket-protocol.md) bridge spec.

## Roadmap

| Phase | Scope |
| ----- | ----- |
| 1 ✅ | Menu bar app · Ports manager (dev-ports first) · kill process · open localhost |
| 3 ✅ | AI chat via Claude Code CLI (agent/model/effort pickers, token streaming, images) |
| 2 ✅ | WebSocket bridge **app-side server** + **real-time two-way synced chat panel** in VS Code |
| 4 | Docker · Projects · Logs |
| 5 | Git · SSH · databases · plugin SDK · more AI providers (OpenAI, Ollama, custom) |

> The AI tab already runs in a workspace folder you pick. Streaming the editor's
> **active file and selection** into that chat needs the app-side WebSocket
> server (Phase 2) — the extension client and protocol are already in place.

## Security

- Localhost-only communication.
- Confirmation before destructive actions (e.g. killing a process).
- No automatic shell execution.
- Secrets stored in the macOS Keychain (planned for AI providers).

## License

MIT
