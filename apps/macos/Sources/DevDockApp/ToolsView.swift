import SwiftUI
import AppKit
import DevDockCore

/// The Tools tab: developer command-line tools dev-dock can check for, install
/// with Homebrew, and launch in a terminal window.
struct ToolsView: View {
    @StateObject private var viewModel = ToolsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            header

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.gap) {
                    ForEach(viewModel.tools) { tool in
                        ToolCard(
                            tool: tool,
                            installation: viewModel.installation(for: tool),
                            isChecking: viewModel.isChecking,
                            onRun: { viewModel.run(tool) },
                            onInstall: { viewModel.install(tool) }
                        )
                    }
                }
                .padding(.bottom, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(DS.contentPadding)
        .task { await viewModel.refresh() }
        // An install runs in a terminal window; re-check when the user comes back
        // so the card flips to "Run" without a manual refresh.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await viewModel.refresh() }
        }
    }

    private var header: some View {
        SectionHeader("Tools", subtitle: subtitle) {
            HStack(spacing: 2) {
                if viewModel.isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 24)
                }
                IconButton(systemImage: "arrow.clockwise", help: "Re-check installed tools") {
                    Task { await viewModel.refresh() }
                }
            }
        }
    }

    private var subtitle: String {
        let installed = viewModel.tools.filter(viewModel.isInstalled).count
        return "\(installed) of \(viewModel.tools.count) installed"
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
    }
}

/// One tool: what it is, whether it's installed, and the single button that
/// either installs it or runs it.
private struct ToolCard: View {
    let tool: CLITool
    let installation: CLIToolInstallation?
    let isChecking: Bool
    let onRun: () -> Void
    let onInstall: () -> Void

    @State private var hovering = false

    private var isInstalled: Bool { installation != nil }

    var body: some View {
        Card(highlighted: hovering) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: tool.symbolName)
                        .font(.system(size: 15))
                        .foregroundStyle(isInstalled ? Color.accentColor : Color.secondary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(tool.name)
                                .font(.callout.weight(.semibold))
                            statusBadge
                        }
                        Text(tool.tagline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    ActionButton(
                        title: isInstalled ? "Run" : "Install",
                        systemImage: isInstalled ? "play.fill" : "arrow.down.circle",
                        tint: isInstalled ? .accentColor : .green,
                        action: isInstalled ? onRun : onInstall
                    )
                }

                Text(isInstalled ? (installation?.path ?? tool.executable) : tool.installCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .onHover { hovering = $0 }
        .help(isInstalled
              ? "Runs \(tool.executable) in a terminal window"
              : "Runs \(tool.installCommand) in a terminal window")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let installation {
            badge(
                text: installation.version.map { "v\($0)" } ?? "installed",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        } else if isChecking {
            badge(text: "checking…", systemImage: "hourglass", tint: .secondary)
        } else {
            badge(text: "not installed", systemImage: "circle.dashed", tint: .secondary)
        }
    }

    private func badge(text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 8, weight: .semibold))
            Text(text)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(tint.opacity(0.14)))
    }
}

/// The card's primary button — a pill that tints on hover.
private struct ActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(hovering ? 0.26 : 0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
