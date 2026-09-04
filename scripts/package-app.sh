#!/usr/bin/env bash
#
# dev-dock — build a distributable DevDock.app, plus a .dmg and a .zip.
#
#   ./scripts/package-app.sh [version]
#
# `version` defaults to the current git tag, or 0.0.0-dev outside a release.
# Everything lands in dist/.
#
# The result is a universal (Apple Silicon + Intel) menu bar app that runs on
# any Mac with macOS 13 or newer — no Xcode, no checkout, no `swift build`. The
# Node runner that powers the AI tab's permission prompts is bundled inside, so
# the only thing the user still needs on their machine is the `claude` CLI (and
# `node`, for that one tab).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(git describe --tags --exact-match 2>/dev/null || echo "0.0.0-dev")}"
VERSION="${VERSION#v}"
DIST="$ROOT/dist"
APP="$DIST/DevDock.app"

step() { printf "\n\033[1;36m▸ %s\033[0m\n" "$1"; }
ok()   { printf "  \033[0;32m✓\033[0m %s\n" "$1"; }
note() { printf "  \033[0;90m%s\033[0m\n" "$1"; }

step "Build (universal, release) — $VERSION"
rm -rf "$DIST"
mkdir -p "$DIST"
( cd apps/macos && swift build -c release --arch arm64 --arch x86_64 )
BINARY="$ROOT/apps/macos/.build/apple/Products/Release/DevDock"
[ -f "$BINARY" ] || { echo "no universal binary at $BINARY" >&2; exit 1; }
ok "$(file -b "$BINARY" | head -1)"

step "Assemble DevDock.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/DevDock"

# LSUIElement keeps it out of the Dock and ⌘-Tab: this app lives in the menu bar.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>dev-dock</string>
    <key>CFBundleDisplayName</key>       <string>dev-dock</string>
    <key>CFBundleExecutable</key>        <string>DevDock</string>
    <key>CFBundleIdentifier</key>        <string>com.devdock.app</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>MIT licensed</string>
</dict>
</plist>
PLIST
ok "Info.plist ($VERSION)"

# The icon is generated, not checked in — see scripts/make-icon.swift. Losing it
# costs a generic icon, not a release, so a failure here is only a warning.
if swift "$ROOT/scripts/make-icon.swift" "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
  ok "AppIcon.icns"
else
  note "icon generation failed — shipping with the default icon"
fi

step "Bundle the agent-runner"
# Production dependencies only: the AI tab's permission prompts run through the
# Claude Agent SDK in this Node script.
( cd agent-runner && npm install --omit=dev --no-audit --no-fund >/dev/null )
mkdir -p "$APP/Contents/Resources/agent-runner"
cp agent-runner/runner.mjs agent-runner/package.json "$APP/Contents/Resources/agent-runner/"
cp -R agent-runner/node_modules "$APP/Contents/Resources/agent-runner/node_modules"
ok "$(du -sh "$APP/Contents/Resources/agent-runner" | cut -f1) bundled"

step "Sign"
# Ad-hoc signature: enough for macOS to run the app locally (and required on
# Apple Silicon), but not a Developer ID — so first launch still needs the
# right-click → Open dance. Notarizing would need a paid Apple account.
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP" && ok "ad-hoc signed"

step "Package"
ditto -c -k --keepParent "$APP" "$DIST/DevDock-$VERSION-macOS.zip"
ok "DevDock-$VERSION-macOS.zip"

# A .dmg with an Applications symlink is the install gesture Mac users expect.
STAGE="$DIST/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "dev-dock" -srcfolder "$STAGE" -ov -format UDZO \
    "$DIST/DevDock-$VERSION-macOS.dmg" >/dev/null
rm -rf "$STAGE"
ok "DevDock-$VERSION-macOS.dmg"

( cd "$DIST" && shasum -a 256 DevDock-*.zip DevDock-*.dmg > "SHA256SUMS.txt" )
ok "SHA256SUMS.txt"

step "Done"
ls -lh "$DIST" | tail -n +2 | awk '{printf "  %s  %s\n", $5, $9}'
