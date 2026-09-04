# dev-dock

A native macOS **menu bar developer cockpit** — everything a developer reaches
for, one keystroke away, without juggling Terminal, Docker Desktop, Activity
Monitor, and a browser. Think Raycast, but built entirely for software
development.

> **Status:** MVP. The **Ports** manager is fully implemented; other tabs are
> scaffolded for the roadmap below.

---

## Install (no build needed)

Grab the latest **[release](https://github.com/hmh6a/dev-dock/releases/latest)**,
open the `.dmg`, and drag **dev-dock** to Applications. Universal build — Apple
Silicon and Intel — macOS 13 or newer.

The first launch needs one extra step, because the app is signed ad-hoc rather
than with a paid Apple Developer ID. macOS shows *"Apple could not verify
DevDock.app is free of malware"* — clear the quarantine flag once and it opens
normally from then on:

```bash
xattr -dr com.apple.quarantine /Applications/DevDock.app
```

Prefer not to touch the terminal? Try to open the app, dismiss the warning with
**Done**, then go to **System Settings → Privacy & Security**, scroll to the
message about DevDock, and click **Open Anyway**.

> The old right-click → Open trick no longer works: Apple removed it in macOS 15.
> The only way to make the warning disappear for good is notarization, which
> needs a paid Apple Developer account.

Then look for the box icon in the menu bar — there is no Dock icon. The **Ports**,
**System**, and **Tools** tabs work immediately; the **AI** and **Remote** tabs
need the [`claude` CLI](https://claude.com/claude-code) (and `node` for
permission prompts) on your machine. The Node runner itself ships inside the app.

### Updates

The app checks GitHub for a newer release **every 12 hours**, and on demand from
**Settings → Check now**. The version's own patch number says how urgent it is:

| Tag | `z` | What the installed app does |
| --- | --- | --- |
| `v1.4.3` | odd | Offers the update — a banner you can dismiss, and a card in Settings |
| `v1.4.4` | even | **Required.** The window is blocked until the update is installed |

A skipped mandatory release still forces the update later: if you are on `v1.0.1`
and `v1.0.2` (required) is followed by `v1.0.3`, the app blocks. Builds run from a
checkout (`swift run`, version `0.0.0-dev`) are never blocked.

"Install" downloads the `.dmg` to ~/Downloads and opens it — you drag the app to
Applications as usual. dev-dock does not replace its own binary behind your back.

### Releasing

Releases are built by [GitHub Actions](.github/workflows/release.yml) from a tag:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

Pick the last number deliberately: **even means every installed copy is forced to
update**, odd means they are merely offered it.

`scripts/package-app.sh` does the same thing locally, writing the `.app`, `.dmg`,
and `.zip` to `dist/`. The update check reads the **public** releases API, so the
repository has to be public for it (and for other people's downloads) to work.

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
  - **All of this Mac's IP addresses** — Wi-Fi, Ethernet, Tailscale, VPN —
    listed above the ports, each one click-to-copy with its own refresh button
  - Ports bound to every interface (`*` / `0.0.0.0`) show a chip per address
    (`Wi-Fi 192.168.0.189:3000`, `Tailscale 100.64.0.12:3000`) — click to copy
    the URL, ⌥-click to open it
  - **Live CPU and RAM of the owning process** on every row — the chips warm to
    orange/red as a server gets heavy (per-process, so ports sharing a PID show
    the same figures)
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
- **System tab** — the whole machine at a glance, refreshed every two seconds
  with a two-minute sparkline per meter:
  - **CPU** load split into user / system / idle, **memory** split the way
    Activity Monitor splits it (app · wired · compressed · cached) with the
    kernel's own pressure verdict, **GPU** utilization and mapped memory,
    **storage** used / free / total for every mounted volume, and live
    **network** transfer rates (Wi-Fi / Ethernet / cellular, VPN tunnels not
    double-counted)
  - **CPU and GPU temperature**, read from the Mac's thermal sensors without
    `sudo` — plus the full sensor list (die, storage, battery) behind a disclosure
- **Tools tab** — developer command-line tools, each showing whether it is
  installed (and at which version). One button per tool: **Install** runs
  `brew install <formula>` in a terminal window (guarded, so an already-installed
  tool is never reinstalled), **Run** launches it. Ships with
  [`mole`](https://mole.fit) — deep clean and optimize your Mac.
- **Other tabs** (Docker, Projects, Logs, Settings) — scaffolded
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

### Always-on menu bar agent

```bash
./reload-agent.sh
```

Rebuilds, refreshes the copy the LaunchAgent runs from, and restarts it.

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
| 1 ✅ | Menu bar app · Ports manager (dev-ports first) · kill process · open localhost · System monitor (CPU · RAM · GPU · storage · network · temperature) |
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
