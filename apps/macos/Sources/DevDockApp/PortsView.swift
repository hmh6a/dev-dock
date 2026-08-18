import SwiftUI
import DevDockCore

/// The fully-implemented MVP feature: a live view of listening TCP ports with
/// open / copy / kill / refresh actions.
struct PortsView: View {
    @StateObject private var viewModel = PortsViewModel()
    @State private var pendingKill: PortEntry?

    var body: some View {
        // The whole app lives in a `MenuBarExtra(.window)` panel, which is a
        // non-activating window. Native modal presentations (`.confirmationDialog`,
        // `.alert`, `.sheet`) render inside it but their buttons don't reliably
        // receive mouse clicks — the panel never becomes key. So the kill
        // confirmation is drawn as an ordinary in-window overlay instead, whose
        // buttons are plain SwiftUI buttons that always respond.
        ZStack {
            VStack(alignment: .leading, spacing: DS.gap) {
                header
                searchBar

                NetworkAddressesPanel(
                    addresses: viewModel.networkAddresses,
                    isLoading: viewModel.isLoadingNetwork,
                    lastCopied: viewModel.lastCopied,
                    onCopy: { viewModel.copy($0) },
                    onRefresh: { Task { await viewModel.refreshNetwork() } }
                )

                if let error = viewModel.errorMessage {
                    errorBanner(error)
                }

                portList
            }
            .padding(DS.contentPadding)

            if let entry = pendingKill {
                KillConfirmationOverlay(
                    entry: entry,
                    onConfirm: {
                        viewModel.kill(entry)
                        pendingKill = nil
                    },
                    onCancel: { pendingKill = nil }
                )
            }
        }
        .task { await viewModel.refresh() }
        .animation(.easeInOut(duration: 0.12), value: pendingKill)
    }

    // MARK: - Header

    private var header: some View {
        SectionHeader(
            "Ports",
            subtitle: "\(viewModel.filteredEntries.count) listening"
        ) {
            HStack(spacing: 2) {
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 24)
                }
                IconButton(systemImage: "arrow.clockwise", help: "Refresh") {
                    Task { await viewModel.refresh() }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter by port, process, or address", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !viewModel.searchText.isEmpty {
                IconButton(systemImage: "xmark.circle.fill", help: "Clear") {
                    viewModel.searchText = ""
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }

    // MARK: - List

    @ViewBuilder
    private var portList: some View {
        if viewModel.filteredEntries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.gap) {
                    if !viewModel.devEntries.isEmpty {
                        groupLabel("Development", systemImage: "hammer.fill")
                        rows(for: viewModel.devEntries)
                    }
                    if !viewModel.otherEntries.isEmpty {
                        if !viewModel.devEntries.isEmpty {
                            groupLabel("Other ports", systemImage: "circle.grid.2x2")
                                .padding(.top, 4)
                        }
                        rows(for: viewModel.otherEntries)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private func rows(for entries: [PortEntry]) -> some View {
        ForEach(entries) { entry in
            PortRow(
                entry: entry,
                addresses: viewModel.networkAddresses,
                lastCopied: viewModel.lastCopied,
                onOpen: { viewModel.openInBrowser(entry) },
                onCopy: { viewModel.copyURL(entry) },
                onKill: { pendingKill = entry },
                onOpenFolder: { viewModel.openFolder(entry) },
                onCopyAddress: { viewModel.copy(entry.urlString(host: $0.ip)) },
                onOpenAddress: { viewModel.openInBrowser(entry, at: $0) }
            )
        }
    }

    private func groupLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: viewModel.isLoading ? "hourglass" : "network.slash")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyMessage: String {
        if viewModel.isLoading { return "Scanning ports…" }
        if !viewModel.searchText.isEmpty { return "No ports match “\(viewModel.searchText)”." }
        return "No listening ports found."
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
    }
}

/// In-window replacement for `.confirmationDialog`, shown when the user asks to
/// kill a port. Rendered as a dimmed overlay with a centered card so its buttons
/// stay clickable inside the non-activating menu-bar panel.
private struct KillConfirmationOverlay: View {
    let entry: PortEntry
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Dimmed backdrop; a tap outside the card cancels.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("Kill process?")
                        .font(.headline)
                    Text("This sends SIGTERM to PID \(entry.pid) listening on port \(entry.port).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 8) {
                    DialogButton(
                        title: "Kill \(entry.process) (PID \(entry.pid))",
                        role: .destructive,
                        action: onConfirm
                    )
                    DialogButton(title: "Cancel", role: .cancel, action: onCancel)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(24)
        }
    }
}

/// A full-width, rounded button used inside `KillConfirmationOverlay`.
private struct DialogButton: View {
    enum Role { case destructive, cancel }

    let title: String
    let role: Role
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fillColor)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fillColor: Color {
        switch role {
        case .destructive:
            return Color.red.opacity(hovering ? 0.28 : 0.18)
        case .cancel:
            return Color.primary.opacity(hovering ? 0.14 : 0.08)
        }
    }
}

/// A single row/card in the ports list.
private struct PortRow: View {
    let entry: PortEntry
    /// The machine's IP addresses, used to show where else this port is reachable.
    let addresses: [NetworkAddress]
    let lastCopied: String?
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onKill: () -> Void
    let onOpenFolder: () -> Void
    let onCopyAddress: (NetworkAddress) -> Void
    let onOpenAddress: (NetworkAddress) -> Void

    @State private var hovering = false

    /// A port bound to a single loopback address is only reachable from this Mac —
    /// listing LAN and Tailscale URLs for it would be a lie.
    private var reachableAddresses: [NetworkAddress] {
        entry.isReachableFromNetwork ? addresses : []
    }

    var body: some View {
        Card(highlighted: hovering) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    MonoPill(text: String(entry.port), tint: entry.isDevPort ? .accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(entry.process)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            if let service = entry.serviceLabel {
                                Text(service)
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(Color.accentColor.opacity(0.16))
                                    )
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                            }
                        }
                        Text("\(entry.address)  ·  PID \(entry.pid)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    HStack(spacing: 2) {
                        IconButton(systemImage: "safari", help: "Open \(entry.localURLString)", action: onOpen)
                        IconButton(systemImage: "doc.on.doc", help: "Copy URL", action: onCopy)
                        IconButton(systemImage: "xmark.octagon", help: "Kill process", tint: .red, action: onKill)
                    }
                    .opacity(hovering ? 1 : 0.55)
                }

                if let folder = entry.folderName {
                    FolderChip(name: folder, fullPath: entry.workingDirectory ?? folder, action: onOpenFolder)
                        .padding(.leading, 2)
                }

                if !reachableAddresses.isEmpty {
                    // Wrapping row of "Wi-Fi 192.168.0.189:3000" chips — click to
                    // copy the URL, ⌥-click to open it.
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 4, alignment: .leading)],
                        alignment: .leading,
                        spacing: 4
                    ) {
                        ForEach(reachableAddresses) { address in
                            let url = entry.urlString(host: address.ip)
                            AddressChip(
                                symbol: address.kind.symbolName,
                                label: address.label,
                                value: "\(address.ip):\(entry.port)",
                                copied: lastCopied == url,
                                help: "Click to copy \(url) · ⌥-click to open"
                            ) {
                                if NSEvent.modifierFlags.contains(.option) {
                                    onOpenAddress(address)
                                } else {
                                    onCopyAddress(address)
                                }
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

/// A clickable chip showing the project folder a port was started from. Opens the
/// folder in Finder when tapped.
private struct FolderChip: View {
    let name: String
    let fullPath: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9))
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(hovering ? 0.9 : 0.0)
            }
            .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(hovering ? Color.accentColor.opacity(0.14)
                                        : Color.primary.opacity(0.06))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Open \(fullPath) in Finder")
    }
}

/// The machine's own IP addresses — Wi-Fi, Ethernet, Tailscale, VPN — each one
/// click-to-copy, with its own refresh button. Collapsible, and remembered.
private struct NetworkAddressesPanel: View {
    let addresses: [NetworkAddress]
    let isLoading: Bool
    let lastCopied: String?
    let onCopy: (String) -> Void
    let onRefresh: () -> Void

    @AppStorage("ports.showNetworkAddresses") private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Button {
                    withAnimation(.easeInOut(duration: 0.14)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Image(systemName: "network")
                            .font(.system(size: 9, weight: .bold))
                        Text("THIS MAC")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.5)
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 4)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 20, height: 20)
                } else {
                    IconButton(systemImage: "arrow.clockwise", help: "Refresh IP addresses", action: onRefresh)
                }
            }
            .padding(.leading, 2)

            if expanded {
                if addresses.isEmpty {
                    Text(isLoading ? "Reading interfaces…" : "No network addresses — this Mac is offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                } else {
                    VStack(spacing: 3) {
                        ForEach(addresses) { address in
                            AddressRow(
                                address: address,
                                copied: lastCopied == address.ip,
                                onCopy: { onCopy(address.ip) }
                            )
                        }
                    }
                }
            }
        }
    }

    /// Collapsed hint, so the addresses stay glanceable without expanding.
    private var summary: String {
        guard !addresses.isEmpty else { return "" }
        if expanded { return "· \(addresses.count)" }
        return "· " + addresses.map(\.ip).joined(separator: "  ")
    }
}

/// One IP address line: link icon, its name, the address, and a copy button.
/// The whole row is the copy target.
private struct AddressRow: View {
    let address: NetworkAddress
    let copied: Bool
    let onCopy: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 7) {
                Image(systemName: address.kind.symbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
                    .frame(width: 14)

                Text(address.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(address.ip)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text(address.interface)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .opacity(copied || hovering ? 1 : 0.35)
                    .frame(width: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(copied ? "Copied \(address.ip)" : "Copy \(address.ip)")
    }
}

/// A compact "Wi-Fi 192.168.0.189:3000" chip under a port row.
private struct AddressChip: View {
    let symbol: String
    let label: String
    let value: String
    let copied: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : symbol)
                    .font(.system(size: 8, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(copied ? Color.green : (hovering ? Color.accentColor : Color.secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(copied ? Color.green.opacity(0.14)
                                      : (hovering ? Color.accentColor.opacity(0.14)
                                                  : Color.primary.opacity(0.06)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
