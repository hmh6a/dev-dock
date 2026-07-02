# Architecture

dev-dock is split into three cooperating pieces:

```
┌──────────────────────┐     localhost WebSocket      ┌────────────────────────┐
│   VS Code extension  │  ◄───────  JSON  ──────────►  │   macOS menu bar app    │
│  (dev-dock-vscode)   │      BridgeMessage            │  (DevDockApp)           │
└──────────────────────┘                               │    ▲                    │
                                                        │    │ uses               │
                                                        │  ┌─┴──────────────────┐ │
                                                        │  │   DevDockCore      │ │
                                                        │  │  (pure logic lib)  │ │
                                                        │  └────────────────────┘ │
                                                        └────────────────────────┘
```

## macOS app (`apps/macos`)

A Swift Package with two targets plus tests:

### `DevDockCore` — the logic library

Deliberately free of SwiftUI so it can be unit-tested in isolation. It owns:

| File | Responsibility |
| ---- | -------------- |
| `PortEntry.swift` | Domain model for a listening port + browser-URL logic. |
| `LsofParser.swift` | Tolerant parser for `lsof` output → `[PortEntry]`. |
| `CommandRunner.swift` | `CommandRunning` protocol + `Process`-backed impl. Injectable for tests. |
| `PortScanner.swift` | Runs `lsof -iTCP -sTCP:LISTEN -n -P` and parses it. |
| `ProcessManager.swift` | Sends `SIGTERM`/`SIGKILL` to a PID. |
| `DevPortCatalog.swift` | Recognizes common dev ports (Vite, PostgreSQL, …) so they sort first. |
| `BridgeMessage.swift` | Codable wire protocol shared with the extension. |
| `AIModels.swift` | `ClaudeModel`, `ReasoningEffort`, `ClaudeAgent`, `AccessMode`, stream-event enum. |
| `ClaudeStreamParser.swift` | Parses `claude --output-format stream-json` lines → events. |
| `ClaudeCommandBuilder.swift` | Builds the `claude` argument vector (pure, testable). |
| `AgentCatalog.swift` | Discovers agents from `~/.claude/agents` + project agents. |

The key testability move is `CommandRunning`: services take a runner by
injection, so tests feed canned output instead of shelling out. See
`Tests/DevDockCoreTests`.

### `DevDockApp` — the SwiftUI shell

A thin UI layer. One `MenuBarExtra` scene (`.window` style) hosts `RootView`,
which switches between tabs. `PortsViewModel` is the only stateful view model in
the MVP; it wraps `PortScanner` + `ProcessManager` on the `@MainActor` and
exposes the four actions the UI binds to.

- `DesignSystem.swift` — shared `Card`, `SectionHeader`, `IconButton`, `MonoPill`.
- `RootView.swift` — sidebar rail + content switch.
- `PortsView.swift` — the fully implemented ports feature (dev ports first).
- `AIView.swift` + `ClaudeCodeSession.swift` — the AI chat (see below).
- `PlaceholderView.swift` / `SettingsView.swift` — the rest.

### AI tab — driving Claude Code

The AI tab is a real Claude Code chat. `ClaudeCodeSession` (a `@MainActor`
`ObservableObject`) spawns the local `claude` CLI **one process per turn**:

- Arguments come from `ClaudeCommandBuilder` (Core): `-p --output-format
  stream-json --model … --effort … --permission-mode … [--agent …]`.
- A stable session id is generated once; the first turn passes `--session-id`,
  later turns `--resume` it, so conversation history is preserved across
  processes.
- `stdout` is read line-by-line via `FileHandle.bytes.lines` and each line is
  decoded by `ClaudeStreamParser` into events that update the UI live (assistant
  text, tool-use chips, cost). `stderr` is drained concurrently to avoid a pipe
  deadlock.
- `ClaudeLocator` (App) resolves the `claude` binary by absolute path (Finder-safe).
- **Access mode** maps to permissions: *Read-only* → `--permission-mode default`
  with a read-only `--allowedTools` set; *Full access* → `bypassPermissions`.

`ClaudeStreamParser` and `ClaudeCommandBuilder` are pure and unit-tested against
real captured CLI output; a gated live test (`DEVDOCK_LIVE_CLAUDE=1`) exercises
the full spawn → stream → parse pipeline against the actual `claude` binary.

## VS Code extension (`extensions/dev-dock-vscode`)

- `bridgeClient.ts` — resilient `ws` client with capped-backoff reconnect.
- `extension.ts` — pushes editor context on change, executes inbound commands.
- `protocol.ts` — TypeScript mirror of `BridgeMessage`.

## Design principles

- **Core is pure.** No UI or global singletons in `DevDockCore`; everything the
  system touches is behind an injectable protocol.
- **Destructive actions are isolated and confirmed.** Killing a process lives in
  its own type and is always gated by a confirmation dialog.
- **Absolute tool paths.** `/usr/sbin/lsof`, `/bin/kill` — the app can't rely on
  a shell `PATH` when launched from Finder.
