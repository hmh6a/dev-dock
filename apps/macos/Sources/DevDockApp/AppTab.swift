import SwiftUI

/// The primary navigation tabs of the cockpit. ``ports``, ``ai``, ``remote``,
/// ``mobile``, ``system``, ``tools``, and ``settings`` ship real UI; the rest are
/// placeholders wired up for later phases.
enum AppTab: String, CaseIterable, Identifiable {
    case ai
    case remote
    case mobile
    case ports
    case system
    case tools
    case docker
    case projects
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: return "AI"
        case .remote: return "Remote"
        case .mobile: return "Mobile"
        case .ports: return "Ports"
        case .system: return "System"
        case .tools: return "Tools"
        case .docker: return "Docker"
        case .projects: return "Projects"
        case .logs: return "Logs"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .ai: return "sparkles"
        case .remote: return "antenna.radiowaves.left.and.right"
        case .mobile: return "iphone"
        case .ports: return "network"
        case .system: return "speedometer"
        case .tools: return "wrench.and.screwdriver"
        case .docker: return "square.stack.3d.up"
        case .projects: return "folder"
        case .logs: return "doc.text"
        case .settings: return "gearshape"
        }
    }

    /// Whether the tab has real functionality (vs. a "coming soon" placeholder).
    var isImplemented: Bool {
        switch self {
        case .ports, .ai, .remote, .mobile, .system, .tools, .settings: return true
        default: return false
        }
    }

    /// Tabs shown in the main navigation area (Settings is pinned to the bottom).
    ///
    /// A released build shows only what actually works — nobody installs an app
    /// to be shown three "coming soon" screens. The scaffolded tabs stay visible
    /// in a development build, where they are the roadmap being worked on.
    static var primaryTabs: [AppTab] {
        primaryTabs(includingUpcoming: AppBuild.isDevelopment)
    }

    static func primaryTabs(includingUpcoming: Bool) -> [AppTab] {
        allCases.filter { $0 != .settings && (includingUpcoming || $0.isImplemented) }
    }
}
