import SwiftUI
import AppKit

/// The Remote Control tab: start/stop the official Claude Code Remote Control
/// server for a chosen project, then scan the in-app QR to drive it from the
/// Claude mobile app or claude.ai while you're away.
struct RemoteView: View {
    @ObservedObject var manager: RemoteControlManager

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            SectionHeader("Remote Control", subtitle: subtitle) {
                if manager.isActive {
                    Button(role: .destructive) { manager.stop() } label: {
                        Label("Stop", systemImage: "stop.fill").font(.caption)
                    }
                    .controlSize(.small)
                }
            }

            folderChip

            if !manager.isAvailable {
                banner("`claude` CLI not found. Install Claude Code to use Remote Control.", icon: "exclamationmark.triangle.fill", color: .orange)
            }

            content

            Spacer(minLength: 0)
        }
        .padding(DS.contentPadding)
    }

    private var subtitle: String {
        switch manager.phase {
        case .idle, .stopped: return "Drive this Mac from your phone"
        case .starting: return "Starting…"
        case .ready: return manager.statusLine.isEmpty ? "Ready" : manager.statusLine
        case .failed: return "Couldn't start"
        }
    }

    // MARK: - Content by phase

    @ViewBuilder
    private var content: some View {
        switch manager.phase {
        case .idle, .stopped:
            startScreen
        case .starting:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to Anthropic…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            readyScreen
        case let .failed(message):
            failedScreen(message)
        }
    }

    private var startScreen: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a Remote Control session and Claude Code keeps running here on your Mac. Connect from the Claude app or claude.ai to send prompts and approve actions while you're away.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(action: manager.start) {
                Label("Start Remote Control", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!manager.isAvailable)

            Text("Requires a Claude subscription and being signed in (`claude` → `/login`).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var readyScreen: some View {
        VStack(spacing: 10) {
            if let url = manager.sessionURL {
                QRView(urlString: url.absoluteString)

                Text("Scan with the Claude app, or open the **Code** tab in the app / claude.ai/code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "safari").font(.caption)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc").font(.caption)
                    }
                }
                .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func failedScreen(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            banner(message, icon: "xmark.octagon.fill", color: .red)
            Button(action: manager.start) {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Pieces

    private var folderChip: some View {
        Button(action: chooseFolder) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
                Text(workspaceName).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("change").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(manager.isActive)
        .help("The project folder the remote session runs in")
    }

    private var workspaceName: String {
        guard let url = manager.workspaceURL else { return "~ (home)" }
        return url.lastPathComponent
    }

    private func banner(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(.init(text)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.1)))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            manager.workspaceURL = url
        }
    }
}

/// Renders a crisp QR code for a string, regenerating when the string changes.
private struct QRView: View {
    let urlString: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190, height: 190)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 190, height: 190)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: urlString) { image = QRCode.image(from: urlString) }
    }
}
