#!/usr/bin/env bash
#
# dev-dock — one command to run everything.
#
#   ./run.sh            build + launch (installs deps the first time)
#   ./run.sh --setup    just install deps, compile, install the extension — don't launch
#
# It: installs agent-runner + extension deps (once), compiles the extension,
# best-effort installs the extension into VS Code, then builds and launches the
# macOS app (which starts the bridge server the extension connects to).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$1"; }
ok()   { printf "  \033[0;32m✓\033[0m %s\n" "$1"; }
note() { printf "  \033[0;90m%s\033[0m\n" "$1"; }

SETUP_ONLY=0
[ "${1:-}" = "--setup" ] && SETUP_ONLY=1

# 1) Node backend used by the AI tab (Claude Agent SDK).
step "agent-runner dependencies"
if [ -d agent-runner/node_modules ]; then
  ok "already installed"
else
  ( cd agent-runner && npm install ) && ok "installed"
fi

# 2) VS Code extension: deps + compile.
step "VS Code extension (deps + compile)"
[ -d extensions/dev-dock-vscode/node_modules ] || ( cd extensions/dev-dock-vscode && npm install )
( cd extensions/dev-dock-vscode && npm run compile )
ok "compiled"

# 3) Best-effort: install the extension into VS Code so the chat panel is always
#    available (no F5 needed). Skipped cleanly if the tooling isn't present.
step "Install the extension into VS Code"
if command -v code >/dev/null 2>&1; then
  if ( cd extensions/dev-dock-vscode \
        && npx --yes @vscode/vsce package -o /tmp/dev-dock.vsix </dev/null >/dev/null 2>&1 \
        && code --install-extension /tmp/dev-dock.vsix --force </dev/null >/dev/null 2>&1 ); then
    ok "installed — open the dev-dock icon in the VS Code sidebar (reload the window once)"
  else
    note "couldn't auto-install — press F5 in extensions/dev-dock-vscode to load the panel"
  fi
else
  note "'code' CLI not found — press F5 in extensions/dev-dock-vscode to load the panel"
fi

# 4) Build the macOS app.
step "Build the dev-dock app"
( cd apps/macos && swift build )
ok "built"

if [ "$SETUP_ONLY" = "1" ]; then
  step "Setup complete"
  note "run ./run.sh to launch the app"
  exit 0
fi

# 5) Launch (foreground — Ctrl+C stops it). Replace any running instance first.
step "Launching dev-dock"
pkill -f ".build/debug/DevDock" 2>/dev/null || true
note "look for the box icon in the menu bar · open the dev-dock panel in VS Code · Ctrl+C to stop"
exec apps/macos/.build/debug/DevDock
