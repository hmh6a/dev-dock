import SwiftUI
import AppKit

/// The Mobile tab: shows the URL + QR for the installable phone web app (PWA),
/// which mirrors the AI chat over the local network.
struct MobileView: View {
    @ObservedObject var server: PWAServer

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            SectionHeader("Mobile", subtitle: server.isRunning ? "Use dev-dock from your phone" : "Starting…")

            if hasNetwork {
                ScrollView {
                    VStack(spacing: 12) {
                        connectionBadge

                        if server.interfaces.count > 1 {
                            interfacePicker
                        }

                        QRView(urlString: server.url)

                        Text(server.url)
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))

                        HStack(spacing: 6) {
                            Button {
                                NSWorkspace.shared.open(URL(string: server.url)!)
                            } label: { Label("Open", systemImage: "safari").font(.caption) }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(server.url, forType: .string)
                            } label: { Label("Copy link", systemImage: "doc.on.doc").font(.caption) }
                        }
                        .controlSize(.small)

                        instructions
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }
            } else {
                noNetwork
            }

            Spacer(minLength: 0)
        }
        .padding(DS.contentPadding)
    }

    private var hasNetwork: Bool { server.activeIP != nil }

    // A badge describing how the phone reaches this Mac on the active address.
    @ViewBuilder
    private var connectionBadge: some View {
        let tailscale = server.isTailscale
        let text = tailscale
            ? "Tailscale — reachable from anywhere"
            : "\(server.activeInterface?.label ?? "Local network") — same network only"
        Label(text, systemImage: tailscale ? "lock.shield" : "wifi")
            .font(.caption.weight(.medium))
            .foregroundStyle(tailscale ? Color.green : Color.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill((tailscale ? Color.green : Color.primary).opacity(tailscale ? 0.14 : 0.08)))
    }

    // Choose which of the Mac's addresses the URL/QR use — for machines without
    // Tailscale, or to force a specific network.
    private var interfacePicker: some View {
        Menu {
            Button {
                server.preferredIP = nil
            } label: {
                pickerRow(title: "Automatic", detail: NetworkInfo.bestIPv4(), selected: server.preferredIP == nil)
            }
            Divider()
            ForEach(server.interfaces) { iface in
                Button {
                    server.preferredIP = iface.ip
                } label: {
                    pickerRow(title: iface.label, detail: iface.ip, selected: server.preferredIP == iface.ip)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "network").font(.system(size: 10, weight: .semibold))
                Text(server.preferredIP == nil
                     ? "Automatic (\(server.activeInterface?.label ?? "—"))"
                     : "\(server.activeInterface?.label ?? "Address"): \(server.activeIP ?? "")")
                    .font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Color.primary.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func pickerRow(title: String, detail: String?, selected: Bool) -> some View {
        Label(
            title + (detail.map { " · \($0)" } ?? ""),
            systemImage: selected ? "checkmark" : "network"
        )
    }

    private var instructions: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                if server.isTailscale {
                    step("1", "Make sure Tailscale is on, on this Mac and your phone (any network).")
                } else {
                    step("1", "Put your phone on the same **\(server.activeInterface?.label ?? "Wi-Fi")** network as this Mac.")
                }
                step("2", "Scan the QR (or open the link) in your phone's browser.")
                step("3", "Chat with Claude Code — it's synced with the app in real time.")
                step("4", "Install it: Share → **Add to Home Screen** (iOS), or the browser's **Install** (Android).")
            }
        }
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.caption2.weight(.bold))
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.18)))
                .foregroundStyle(Color.accentColor)
            Text(.init(text)).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var noNetwork: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.slash").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No local network found").font(.callout)
            Text("Connect this Mac to Wi-Fi so your phone can reach it.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 40)
    }
}

/// Renders a crisp QR for a string, regenerating when it changes.
private struct QRView: View {
    let urlString: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.none).resizable().scaledToFit()
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
