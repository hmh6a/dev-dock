import SwiftUI

/// Top-level layout: a slim icon rail on the left, tab content on the right.
struct RootView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarRail(
                    selection: $appState.selectedTab,
                    hasUpdate: appState.updates.showsOptionalUpdate
                )
                Divider()
                VStack(spacing: 0) {
                    // An optional update announces itself once, above whichever
                    // tab is open, and can be waved away. A mandatory one takes
                    // the whole window instead — see below.
                    UpdateBanner(updates: appState.updates)
                        .padding(.horizontal, DS.contentPadding)
                        .padding(.top, appState.updates.showsOptionalUpdate ? DS.contentPadding : 0)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }

            if appState.updates.mustUpdate {
                MandatoryUpdateOverlay(updates: appState.updates)
            }
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
        case .system:
            SystemView()
        case .tools:
            ToolsView()
        case .settings:
            SettingsView(updates: appState.updates)
        default:
            PlaceholderView(tab: appState.selectedTab)
        }
    }
}

/// The vertical navigation rail. Primary tabs at the top, Settings pinned bottom.
struct SidebarRail: View {
    @Binding var selection: AppTab
    /// Puts a dot on Settings, where the update lives, so a dismissed banner
    /// still leaves a trace.
    var hasUpdate = false

    var body: some View {
        VStack(spacing: 4) {
            ForEach(AppTab.primaryTabs) { tab in
                SidebarButton(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }
            Spacer()
            SidebarButton(tab: .settings, isSelected: selection == .settings, badged: hasUpdate) {
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
    var badged = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 15, weight: .medium))
                .overlay(alignment: .topTrailing) {
                    if badged {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 5, y: -3)
                    }
                }
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
