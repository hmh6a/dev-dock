#!/usr/bin/env bash
#
# dev-dock — rebuild and restart the always-on menu bar agent.
#
#   ./reload-agent.sh
#
# Why the copy step: launchd cannot start the binary straight out of
# `.build/` because the repo lives under ~/Documents, which macOS guards with
# TCC. A login agent has no responsible app to attach a consent prompt to, so
# `dyld` hangs in `open()` on the executable and the app never appears. Running
# from ~/Library/Application Support sidesteps that; the app still runs *in* the
# repo (the LaunchAgent's WorkingDirectory), so it finds `agent-runner/` as usual.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.devdock.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INSTALL_DIR="$HOME/Library/Application Support/DevDock"
DOMAIN="gui/$(id -u)"

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$1"; }
ok()   { printf "  \033[0;32m✓\033[0m %s\n" "$1"; }

step "Build"
( cd "$ROOT/apps/macos" && swift build )
ok "built"

step "Install"
mkdir -p "$INSTALL_DIR"
# The agent holds the old copy open, so unload before overwriting it.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
cp "$ROOT/apps/macos/.build/debug/DevDock" "$INSTALL_DIR/DevDock"
ok "$INSTALL_DIR/DevDock"

step "Restart the agent"
# A rebuild gives the binary a new code-signing hash, which invalidates the
# launch constraint launchd cached for the job — so bootout/bootstrap, not
# `kickstart -k`, which would fail with OS_REASON_CODESIGNING.
launchctl bootstrap "$DOMAIN" "$PLIST"
sleep 2
launchctl print "$DOMAIN/$LABEL" | grep -E "^\s+(state|pid) " || true
ok "look for the box icon in the menu bar"
