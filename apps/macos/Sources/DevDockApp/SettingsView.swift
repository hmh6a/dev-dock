import SwiftUI
import AppKit

/// Minimal settings surface. Kept intentionally small for the MVP — appearance
/// follows the system, and the only real control is Quit.
struct SettingsView: View {
    @AppStorage("bridge.port") private var bridgePort: Int = 51_888
    @AppStorage("ports.autoRefresh") private var autoRefresh: Bool = false
    @AppStorage("terminal.enabled") private var terminalEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            SectionHeader("Settings", subtitle: "dev-dock preferences")

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $autoRefresh) {
                        settingLabel("Auto-refresh ports", "Rescan listening ports periodically")
                    }
                    Divider()
                    Toggle(isOn: $terminalEnabled) {
                        settingLabel("Allow terminal from phone / extension",
                                     "Lets a connected client open a real shell on this Mac")
                    }
                    Divider()
                    HStack {
                        settingLabel("Bridge port", "Localhost WebSocket port for the editor bridge")
                        Spacer()
                        TextField("", value: $bridgePort, format: .number.grouping(.never))
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .font(.system(.callout, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("dev-dock").font(.callout.weight(.semibold))
                        Spacer()
                        Text("v0.1.0 · MVP").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Native macOS developer cockpit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit dev-dock", systemImage: "power")
                }
                .controlSize(.small)
            }
        }
        .padding(DS.contentPadding)
    }

    private func settingLabel(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
