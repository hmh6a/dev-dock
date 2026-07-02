# dev-dock

## Vision

**dev-dock** is a native macOS menu bar developer cockpit.

The goal is to keep everything a developer needs in one place without constantly switching between Terminal, VS Code, Docker Desktop, Activity Monitor, browsers, or SSH clients.

It should become a daily productivity tool similar in spirit to Raycast, but focused entirely on software development.

---

# Core Principles

- Native macOS application
- Fast startup (<300ms)
- Keyboard-first workflow
- Beautiful SwiftUI interface
- Modular architecture
- Plugin-ready in the future
- Secure local communication
- No cloud dependency for core features

---

# MVP Features

## Menu Bar

- Native MenuBarExtra
- Popover UI
- Dark/Light mode
- Resizable popover

## Tabs

- AI
- Ports
- Processes
- Docker
- Projects
- Logs
- Settings

Only **Ports** should be fully implemented in the MVP.

---

# Tech Stack

## macOS

- Swift
- SwiftUI
- AppKit
- MenuBarExtra

## VS Code

- TypeScript
- VS Code Extension API

## Communication

- Localhost WebSocket
- JSON messages

---

# Ports

Use:

```bash
lsof -iTCP -sTCP:LISTEN -n -P
```

Display:

- Port
- PID
- Process
- Address

Actions:

- Open localhost
- Copy URL
- Kill process
- Refresh

Ask confirmation before killing.

---

# AI Tab (Placeholder)

Create only the UI.

Later it should support:

- OpenAI
- Anthropic
- Ollama
- Custom API

The UI should include:

- Conversation
- Input box
- Workspace info
- Active file
- Selected code

---

# VS Code Extension

Create:

dev-dock-vscode

Responsibilities:

- Send active workspace
- Send active file
- Send selected text
- Receive commands

Commands:

- openFile
- createFile
- replaceSelection
- insertText
- runTerminalCommand

---

# Folder Structure

```text
dev-dock/
├── apps/
│   └── macos/
├── extensions/
│   └── dev-dock-vscode/
├── docs/
├── helper/
└── README.md
```

---

# Roadmap

## Phase 1

- Menu bar app
- Ports manager
- Kill process
- Open localhost

## Phase 2

- VS Code extension
- WebSocket bridge

## Phase 3

- AI integration

## Phase 4

- Docker
- Projects
- Logs

## Phase 5

- Git
- SSH
- Database tools
- Plugin SDK

---

# UI Style

- Native macOS
- Compact
- Rounded cards
- Monospace for technical data
- Minimal colors

---

# Future Features

- Docker manager
- PM2 manager
- SSH connections
- Git shortcuts
- Clipboard history
- Local databases
- Kubernetes
- Tailscale
- Proxmox integration
- Coolify integration
- Grafana widgets
- Notifications
- Plugin marketplace

---

# Security

- Localhost only
- Confirmation before destructive actions
- No automatic shell execution
- Store secrets in Keychain

---

# Deliverables

- Native SwiftUI app
- Clean architecture
- Documentation
- VS Code extension skeleton
- Production-ready code
- Unit-test friendly design
