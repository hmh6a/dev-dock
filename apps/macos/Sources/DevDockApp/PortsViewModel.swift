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
    /// Every IP this Mac is reachable at — Wi-Fi, Ethernet, Tailscale, VPN.
    @Published private(set) var networkAddresses: [NetworkAddress] = []
    @Published private(set) var isLoadingNetwork = false
    /// The address most recently copied, so the UI can flash a checkmark.
    @Published private(set) var lastCopied: String?

    private let scanner = PortScanner()
    private let processManager = ProcessManager()
    private let directoryResolver = ProcessDirectoryResolver()
    private let networkScanner = NetworkInterfaceScanner()
    private var copyResetTask: Task<Void, Never>?

    var filteredEntries: [PortEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.process.lowercased().contains(query)
            || String($0.port).contains(query)
            || $0.address.lowercased().contains(query)
            || ($0.serviceLabel?.lowercased().contains(query) ?? false)
            || ($0.folderName?.lowercased().contains(query) ?? false)
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

    /// Rescan listening ports and the machine's IP addresses.
    func refresh() async {
        async let network: Void = refreshNetwork()
        await refreshPorts()
        await network
    }

    /// Re-read the machine's IP addresses. Cheap (no subprocess), so it is also
    /// wired to its own refresh button next to the address list.
    func refreshNetwork() async {
        isLoadingNetwork = true
        networkAddresses = await networkScanner.scanAsync()
        isLoadingNetwork = false
    }

    /// Rescan listening ports.
    func refreshPorts() async {
        isLoading = true
        errorMessage = nil
        do {
            let scanned = try await scanner.scanAsync()
            // Enrich with each owner's working directory so the UI can show the
            // project folder the server was started from. Best-effort: unresolved
            // pids just show no folder.
            let directories = await directoryResolver.resolveAsync(pids: scanned.map(\.pid))
            entries = scanned.map { $0.withWorkingDirectory(directories[$0.pid]) }
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
            Task { await refreshPorts() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openInBrowser(_ entry: PortEntry) {
        guard let url = entry.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyURL(_ entry: PortEntry) {
        copy(entry.localURLString)
    }

    /// Open this port at one of the machine's addresses — e.g. the Tailscale IP.
    func openInBrowser(_ entry: PortEntry, at address: NetworkAddress) {
        guard let url = URL(string: entry.urlString(host: address.ip)) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Put any value (an IP, or a full URL) on the pasteboard and flash it as copied.
    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        lastCopied = value
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.lastCopied = nil }
        }
    }

    /// Reveal the project the server was started from by opening its working
    /// directory in Finder.
    func openFolder(_ entry: PortEntry) {
        guard let path = entry.workingDirectory, entry.folderName != nil else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
