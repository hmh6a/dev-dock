import SwiftUI

/// Small, shared visual language: rounded cards, monospace technical labels,
/// minimal color — as called for in the UI Style section of the spec.
enum DS {
    static let corner: CGFloat = 10
    static let cardPadding: CGFloat = 10
    static let gap: CGFloat = 8
    static let contentPadding: CGFloat = 12
}

/// A rounded, subtly bordered card — the primary container for list rows and
/// info blocks throughout the app.
struct Card<Content: View>: View {
    var highlighted: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(DS.cardPadding)
            .background(
                RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.5)
                                              : Color.primary.opacity(0.07))
            )
    }
}

/// A compact section header used at the top of each tab.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

/// A small icon-only toolbar button with hover feedback.
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var tint: Color = .primary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
                )
                .foregroundStyle(tint.opacity(hovering ? 1 : 0.75))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Monospaced pill for technical data such as port numbers.
struct MonoPill: View {
    let text: String
    var tint: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .foregroundStyle(tint)
    }
}
