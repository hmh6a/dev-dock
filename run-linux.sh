#!/usr/bin/env bash
#
# dev-dock — one command to run everything on Linux.
#
#   ./run-linux.sh          set up everything + launch the headless server (PWA + bridge)
#   ./run-linux.sh --setup  just install deps & compile — don't launch
#
# The native macOS menu-bar app (apps/macos) can't run on Linux, so this drives
# the cross-platform server/ instead: it serves the SAME PWA and WebSocket bridge
# and talks to Claude Code, terminals, files and project history.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$1"; }
ok()   { printf "  \033[0;32m✓\033[0m %s\n" "$1"; }
note() { printf "  \033[0;90m%s\033[0m\n" "$1"; }

SETUP_ONLY=0
[ "${1:-}" = "--setup" ] && SETUP_ONLY=1

# 0) Build tools for node-pty (the terminal). Best-effort — the server runs
#    without them, just with the terminal tab disabled.
step "Build tools (for the terminal / node-pty)"
if command -v make >/dev/null 2>&1 && command -v gcc >/dev/null 2>&1; then
  ok "already present"
elif command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  if sudo apt-get update -qq && sudo apt-get install -y -qq build-essential python3; then
    ok "installed"
  else
    note "couldn't install — terminal tab will be disabled"
  fi
else
  note "no passwordless apt — skipping; terminal tab will be disabled"
fi

# 1) Node backend used by the AI tab (Claude Agent SDK).
step "agent-runner dependencies"
if [ -d agent-runner/node_modules ]; then
  ok "already installed"
else
  ( cd agent-runner && npm install ) && ok "installed"
fi

# 2) VS Code extension: deps + compile (cross-platform TypeScript).
step "VS Code extension (deps + compile)"
[ -d extensions/dev-dock-vscode/node_modules ] || ( cd extensions/dev-dock-vscode && npm install )
( cd extensions/dev-dock-vscode && npm run compile )
ok "compiled"

# 3) Server: ws bridge + node-pty terminal. Falls back to a build-free install
#    (terminal disabled) if node-pty can't compile.
step "server dependencies"
if ( cd server && npm install ); then
  ok "installed (terminal enabled)"
else
  note "node-pty native build failed — installing without it (terminal disabled)"
  ( cd server && npm install --ignore-scripts )
  ok "installed (terminal disabled)"
fi

if [ "$SETUP_ONLY" = "1" ]; then
  step "Setup complete"
  note "run ./run-linux.sh to launch the server"
  exit 0
fi

# 4) Launch. Replace any previous instance listening on our ports first.
step "Launching dev-dock server"
for port in 51890 51888; do
  pid="$(ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {print}' | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
  [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true
done
note "PWA → http://localhost:51890 · bridge → ws://localhost:51888 · Ctrl+C to stop"
exec node server/index.mjs
