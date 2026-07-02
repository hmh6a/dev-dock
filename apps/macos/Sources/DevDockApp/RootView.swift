import SwiftUI

/// Top-level layout: a slim icon rail on the left, tab content on the right.
struct RootView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail(selection: $appState.selectedTab)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: 400, idealWidth: 440, maxWidth: 640,
            minHeight: 460, idealHeight: 540, maxHeight: 780
        )
    }

    @ViewBuilder
    private var content: some View {
        switch appState.selectedTab {
        case .ai:
            AIView(session: appState.claude)
        case .remote:
            RemoteView(manager: appState.remote)
        case .mobile:
            MobileView(server: appState.pwa)
        case .ports:
            PortsView()
        case .settings:
            SettingsView()
        default:
            PlaceholderView(tab: appState.selectedTab)
        }
    }
}

/// The vertical navigation rail. Primary tabs at the top, Settings pinned bottom.
struct SidebarRail: View {
    @Binding var selection: AppTab

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppTab.primaryTabs) { tab in
                SidebarButton(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }
            Spacer()
            SidebarButton(tab: .settings, isSelected: selection == .settings) {
                selection = .settings
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: 56)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarButton: View {
    let tab: AppTab
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 42, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(background)
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.isImplemented ? tab.title : "\(tab.title) — coming soon")
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }
}
