# dev-dock server (Linux / macOS / Windows)

A cross-platform, headless version of dev-dock. It serves the **same PWA** and the
**same WebSocket bridge** as the macOS app, and drives Claude Code, terminals,
files and project history — so on Ubuntu (or any machine) you run one command and
use everything from the **browser** or the **VS Code extension**. There's no menu-bar
UI; the PWA is the UI.

## What works

- **Chat** with Claude Code (spawns `../agent-runner/runner.mjs`, same as the app)
- **Projects & history** from `~/.claude/projects` (browse, open, resume)
- **Terminal** tabs (real PTY via `node-pty`) — shared across devices, rename + colour
- **Files** browser (read-only, sandboxed to the open project) with the code viewer
- **Images**, **notifications**, **auto-approve**, **permission prompts** (incl. "always allow")

## Prerequisites (Ubuntu)

```bash
# Node 18+ (an LTS is best; very new Node may lack node-pty prebuilds)
sudo apt-get update
sudo apt-get install -y nodejs npm build-essential python3   # build tools for node-pty

# Claude Code auth — either log in with the CLI…
npm install -g @anthropic-ai/claude-code && claude   # then /login
# …or export an API key:
export ANTHROPIC_API_KEY=sk-ant-...
```

## Install & run

```bash
# 1) Claude Agent SDK used by the runner
cd agent-runner && npm install

# 2) the server (ws + node-pty)
cd ../server && npm install

# 3) run it
npm start
```

Then open **http://localhost:51890** in your browser. On `localhost` the page is a
secure context, so you can **install it as a PWA** right away (⋯ → Install app).

## Use from your phone / another machine

Same as the macOS app: put the machine on **Tailscale** and expose HTTPS so it's a
real installable PWA off-box:

```bash
# enable HTTPS Certificates in the Tailscale admin console first, then:
tailscale serve --bg --https=443 --set-path=/ws http://127.0.0.1:51888
tailscale serve --bg --https=443 http://127.0.0.1:51890
# → https://<machine>.<tailnet>.ts.net
```

The PWA auto-switches to `wss://…/ws` over HTTPS.

## VS Code extension

Point the extension at this server: set `devDock.bridgePort` to `51888` (default) and
run VS Code on the same machine, or forward the port. The extension connects to
`ws://localhost:51888`.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `DEVDOCK_PWA_PORT` | `51890` | HTTP port for the PWA. |
| `DEVDOCK_WS_PORT` | `51888` | WebSocket bridge port. |
| `DEVDOCK_HOST` | `0.0.0.0` | Interface to bind. Set `127.0.0.1` (local only) or your Tailscale IP to shrink exposure. |
| `DEVDOCK_TOKEN` | *(file)* | Pins an **immutable** token. Unset ⇒ a rotatable one is kept in `server/.devdock-token` (stable across restarts). |
| `DEVDOCK_TRUST_LOCAL` | off | `1` lets genuine localhost connect without a token (e.g. the VS Code extension). Proxied (Tailscale) requests are never trusted. |
| `DEVDOCK_DOMAINS` | `dev-dock.hmh.dev, dev-dock.hmh6.dev` | Comma-separated public base URLs offered as pairing targets (QR/links). |
| `DEVDOCK_ALL_IFACES` | off | `1` lists every network interface in the pairing menu (default hides Docker/VM bridges). |
| `DEVDOCK_TERMINAL` | on | Set `0` to disable the terminal (no shell exposed). |
| `DEVDOCK_ACCESS` | `ask` | Tool policy: `safe` (read-only), `ask` (prompt), `full` (auto-allow). |
| `DEVDOCK_AGENT_RUNNER` | `../agent-runner/runner.mjs` | Path to the runner. |

## Access control (token pairing)

Every network client must present a **pairing token**, printed at startup as a
**QR code** and a `http://…/?token=…` link:

- **Phone / another machine** — scan the QR (or open the link). The PWA stores the
  token and scrubs it from the address bar.
- **This machine's browser** — open the `localhost` link with `?token=…`.
- **In-app pairing screen** — if the PWA opens without a token (e.g. the installed
  app, or a fresh reload), it shows a pairing screen: **type/paste the token or the
  full link**, or tap **Scan QR code** to read it with the camera. Reopen it any time
  from **⋯ menu → Pairing token**. (Camera scanning needs a secure context — the
  HTTPS domains or `localhost`; on a plain-HTTP LAN IP, type the token instead.)
- **VS Code extension** — either run the server with `DEVDOCK_TRUST_LOCAL=1`, or set
  `devDock.token` to the printed token.

Unauthorized WebSocket handshakes are rejected with **401**; `/upload` and `/media`
are gated too. See connected devices any time via the terminal log (printed on every
connect/disconnect) or `GET /clients?token=…`.

**Rotate the token** any time — mints a new one, disconnects every paired device,
and kills the old token:

```bash
cd server && npm run new-token                 # interactive: pick localhost / LAN / Tailscale / a domain
npm run new-token -- --target dev-dock.hmh6.dev # non-interactive (number, substring, or "all")
```

Pairing targets are every real local IP plus the `DEVDOCK_DOMAINS`.

## Security notes

- Access is **token-gated** by default — localhost included. Loosen only with
  `DEVDOCK_TRUST_LOCAL=1`.
- The terminal is a **real shell**; even behind the token, keep it on Tailscale or
  set `DEVDOCK_TERMINAL=0` on untrusted networks.
- The file browser is **read-only and clamped** to opened project folders.
- Tool permissions flow through the access policy; a remote client only answers
  prompts the server decided to surface.
