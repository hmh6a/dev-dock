import SwiftUI
import AppKit
import DevDockCore

/// Drives the Ports tab: scanning, filtering, and the four actions
/// (open localhost, copy URL, kill, refresh).
@MainActor
final class PortsViewModel: ObservableObject {
    @Published private(set) var entries: [PortEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""

    private let scanner = PortScanner()
    private let processManager = ProcessManager()

    var filteredEntries: [PortEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.process.lowercased().contains(query)
            || String($0.port).contains(query)
            || $0.address.lowercased().contains(query)
            || ($0.serviceLabel?.lowercased().contains(query) ?? false)
        }
    }

    /// Recognized development ports — shown first, since these are the ones you
    /// reach for while working.
    var devEntries: [PortEntry] {
        filteredEntries.filter(\.isDevPort)
    }

    /// Everything else, listed after the dev ports.
    var otherEntries: [PortEntry] {
        filteredEntries.filter { !$0.isDevPort }
    }

    /// Rescan listening ports.
    func refresh() async {
        isLoading = true
        errorMessage = nil
        do {
            entries = try await scanner.scanAsync()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Kill the owning process (SIGTERM). Callers must confirm first — see the
    /// confirmation dialog in `PortsView`.
    func kill(_ entry: PortEntry) {
        do {
            try processManager.kill(pid: entry.pid)
            // Optimistically drop every port owned by that pid for instant feedback…
            entries.removeAll { $0.pid == entry.pid }
            // …then reconcile with reality.
            Task { await refresh() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openInBrowser(_ entry: PortEntry) {
        guard let url = entry.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyURL(_ entry: PortEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.localURLString, forType: .string)
    }
}
