import SwiftUI
import DevDockCore

/// The fully-implemented MVP feature: a live view of listening TCP ports with
/// open / copy / kill / refresh actions.
struct PortsView: View {
    @StateObject private var viewModel = PortsViewModel()
    @State private var pendingKill: PortEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            header
            searchBar

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            portList
        }
        .padding(DS.contentPadding)
        .task { await viewModel.refresh() }
        .confirmationDialog(
            "Kill process?",
            isPresented: killDialogBinding,
            titleVisibility: .visible,
            presenting: pendingKill
        ) { entry in
            Button("Kill \(entry.process) (PID \(entry.pid))", role: .destructive) {
                viewModel.kill(entry)
                pendingKill = nil
            }
            Button("Cancel", role: .cancel) { pendingKill = nil }
        } message: { entry in
            Text("This sends SIGTERM to PID \(entry.pid) listening on port \(entry.port).")
        }
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
                onOpen: { viewModel.openInBrowser(entry) },
                onCopy: { viewModel.copyURL(entry) },
                onKill: { pendingKill = entry }
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

    private var killDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingKill != nil },
            set: { if !$0 { pendingKill = nil } }
        )
    }
}

/// A single row/card in the ports list.
private struct PortRow: View {
    let entry: PortEntry
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onKill: () -> Void

    @State private var hovering = false

    var body: some View {
        Card(highlighted: hovering) {
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
        }
        .onHover { hovering = $0 }
    }
}
