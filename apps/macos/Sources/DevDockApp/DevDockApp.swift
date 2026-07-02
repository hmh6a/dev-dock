import SwiftUI
import AppKit

/// Entry point for the dev-dock menu bar app.
///
/// The whole UI lives inside a single `MenuBarExtra` scene using the `.window`
/// style, which gives us a resizable popover we can fill with custom SwiftUI.
@main
struct DevDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("dev-dock", systemImage: "shippingbox.fill") {
            RootView(appState: appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Keeps the app out of the Dock and the ⌘-Tab switcher — it lives only in the
/// menu bar, matching the "native menu bar cockpit" vision.
///
/// Owns `AppState` so the WebSocket bridge server starts at launch, independent
/// of the popover ever being opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
