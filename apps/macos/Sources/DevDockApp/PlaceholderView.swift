import SwiftUI

/// Generic "coming soon" screen for tabs that are scaffolded but not yet
/// implemented (Processes, Docker, Projects, Logs). Each names the roadmap phase
/// it belongs to.
struct PlaceholderView: View {
    let tab: AppTab

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            SectionHeader(tab.title, subtitle: roadmapPhase)

            Spacer()
            VStack(spacing: 12) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("\(tab.title) is coming soon")
                    .font(.headline)
                Text(blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(DS.contentPadding)
    }

    private var roadmapPhase: String {
        switch tab {
        case .processes: return "Phase 4"
        case .docker: return "Phase 4"
        case .projects: return "Phase 4"
        case .logs: return "Phase 4"
        default: return "Roadmap"
        }
    }

    private var blurb: String {
        switch tab {
        case .processes: return "Inspect and manage running processes, sorted by CPU and memory."
        case .docker: return "See containers, images, and volumes — start, stop, and view logs."
        case .projects: return "Quick-launch your repos in the editor, terminal, or browser."
        case .logs: return "Tail application and system logs in one place."
        default: return "This module is on the roadmap."
        }
    }
}
