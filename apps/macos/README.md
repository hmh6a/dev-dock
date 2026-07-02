# dev-dock — macOS app

Native SwiftUI menu bar cockpit, distributed as a Swift Package.

## Build & run

```bash
swift build            # compile
swift test             # run DevDockCore unit tests
swift run DevDock      # launch (menu bar box icon; no Dock icon)
```

To develop in Xcode: `open Package.swift` and run the **DevDock** scheme.

## Targets

- **`DevDockCore`** — pure, testable logic (port scanning, parsing, process
  control, bridge protocol). No SwiftUI.
- **`DevDockApp`** — the `MenuBarExtra` SwiftUI app; a thin shell over the core.
- **`DevDockCoreTests`** — XCTest coverage for the parser, URL logic, services
  (via an injected command runner), and the bridge codec.

## Requirements

- macOS 13+ (`MenuBarExtra`)
- Swift 5.9+ toolchain / Xcode 15+
- The **AI tab** requires the `claude` CLI (Claude Code) installed and logged in.

## Live AI integration test

The stream parser and command builder are unit-tested against real captured CLI
output. A gated test also runs the full pipeline against the actual binary:

```bash
DEVDOCK_LIVE_CLAUDE=1 swift test --filter ClaudeLiveIntegrationTests
```

## Notes

- `lsof` and `kill` are invoked by absolute path (`/usr/sbin/lsof`, `/bin/kill`)
  so the app behaves the same whether launched from a shell or Finder.
- The Ports tab needs no special privileges to list ports or kill processes you
  own. A future `helper/` component will handle elevated actions.
