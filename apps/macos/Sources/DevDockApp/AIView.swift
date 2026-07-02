import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DevDockCore

/// The AI tab: a real Claude Code chat driven by the local `claude` CLI, with a
/// Projects → Sessions → Chat flow so you can pick a project, browse its past
/// conversations, and continue one from the menu bar.
struct AIView: View {
    @ObservedObject var session: ClaudeCodeSession

    private enum Screen { case projects, sessions, chat }
    @State private var screen: Screen = .projects
    @State private var draft = ""
    @State private var didInit = false
    @State private var attachments: [AttachedImage] = []

    // Scroll metrics (drive the contextual up/down buttons + smart auto-scroll).
    @State private var contentTop: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        Group {
            switch screen {
            case .projects: projectsScreen
            case .sessions: sessionsScreen
            case .chat: chatScreen
            }
        }
        .padding(DS.contentPadding)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            session.loadProjects()
            screen = (session.currentProject == nil && session.messages.isEmpty) ? .projects : .chat
        }
    }

    // MARK: - Projects screen

    private var projectsScreen: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            NavHeader(
                title: "Projects",
                subtitle: "\(session.projects.count) recent",
                back: session.messages.isEmpty ? nil : { screen = .chat }
            ) {
                IconButton(systemImage: "arrow.clockwise", help: "Refresh") { session.loadProjects() }
            }

            if session.isLoadingHistory && session.projects.isEmpty {
                loading("Loading projects…")
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.gap) {
                        ForEach(session.projects) { project in
                            ProjectRow(project: project) {
                                session.openProject(project)
                                screen = .sessions
                            }
                        }
                        browseRow
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    private var browseRow: some View {
        Button(action: chooseFolder) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus").foregroundStyle(.secondary)
                Text("Open another folder…").font(.callout)
                Spacer()
            }
            .padding(DS.cardPadding)
            .background(RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sessions screen

    private var sessionsScreen: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            NavHeader(
                title: session.currentProject?.name ?? "Conversations",
                subtitle: session.currentProject?.path,
                back: { screen = .projects }
            ) {
                Button(action: { session.startNewSession(); screen = .chat }) {
                    Label("New", systemImage: "square.and.pencil").font(.caption)
                }
                .controlSize(.small)
            }

            if session.isLoadingHistory && session.sessions.isEmpty {
                loading("Loading conversations…")
            } else if session.sessions.isEmpty {
                empty("No past conversations here yet.", systemImage: "bubble.left.and.bubble.right")
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.gap) {
                        ForEach(session.sessions) { summary in
                            SessionRow(summary: summary) {
                                session.resume(summary)
                                screen = .chat
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }

    // MARK: - Chat screen

    private var chatScreen: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            chatHeader
            pickerBar
            contextStrip

            if !session.isAvailable {
                unavailableBanner
            }

            conversation

            if let request = session.pendingPermission {
                PermissionPrompt(
                    request: request,
                    onYes: { session.answerPendingPermission(allow: true) },
                    onAlways: { session.answerPendingPermission(allow: true, remember: true) },
                    onNo: { session.answerPendingPermission(allow: false) }
                )
            }

            inputArea
        }
    }

    private var chatHeader: some View {
        SectionHeader("AI", subtitle: statusSubtitle) {
            HStack(spacing: 2) {
                if session.totalCostUSD > 0 {
                    Text(String(format: "$%.3f", session.totalCostUSD))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if session.canFollow {
                    IconButton(
                        systemImage: "dot.radiowaves.left.and.right",
                        help: session.isLive ? "Live — mirroring this conversation. Tap to pause." : "Follow live (mirror VS Code)",
                        tint: session.isLive ? .green : .secondary
                    ) {
                        session.toggleLive()
                    }
                }
                IconButton(systemImage: "clock.arrow.circlepath", help: "Projects & history") {
                    session.loadProjects()
                    screen = .projects
                }
                IconButton(systemImage: "square.and.pencil", help: "New conversation") {
                    session.startNewSession()
                    draft = ""
                }
            }
        }
    }

    private var statusSubtitle: String {
        if session.isStreaming { return session.displayStatus }
        if session.isLive { return "Live — mirroring VS Code" }
        if !session.statusText.isEmpty { return session.statusText }
        if let project = session.currentProject { return project.name }
        return "Powered by Claude Code"
    }

    private var pickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                PickerMenu(systemImage: "cpu", items: ClaudeModel.all, selection: $session.model) { $0.displayName }
                PickerMenu(systemImage: "gauge.with.dots.needle.67percent",
                           items: ReasoningEffort.allCases, selection: $session.effort) { $0.displayName }
                PickerMenu(systemImage: "person.crop.circle",
                           items: session.availableAgents, selection: $session.agent) { $0.displayName }
                PickerMenu(systemImage: accessIcon, items: AccessMode.allCases,
                           selection: $session.accessMode, tint: accessTint) { $0.displayName }
            }
            .padding(.horizontal, 1)
        }
        .disabled(session.isStreaming)
    }

    private var accessIcon: String {
        switch session.accessMode {
        case .safe: return "lock"
        case .ask: return "hand.raised"
        case .full: return "bolt.fill"
        }
    }

    private var accessTint: Color {
        switch session.accessMode {
        case .safe: return .secondary
        case .ask: return .accentColor
        case .full: return .orange
        }
    }

    private var contextStrip: some View {
        Button {
            session.loadProjects()
            screen = session.currentProject != nil ? .sessions : .projects
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.caption).foregroundStyle(.secondary)
                Text(workspaceName).font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch project or browse conversation history")
    }

    private var workspaceName: String {
        if let project = session.currentProject { return project.name }
        guard let url = session.workspaceURL else { return "~ (home)" }
        return url.lastPathComponent
    }

    private var unavailableBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("`claude` CLI not found. Install Claude Code to use this tab.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.1)))
    }

    private var conversation: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.gap) {
                        if session.messages.isEmpty { emptyHint }
                        ForEach(session.messages) { message in
                            ChatBubble(
                                message: message,
                                workingVerb: session.workingVerb,
                                workingTokens: session.streamingTokens
                            ).id(message.id)
                        }
                    }
                    .padding(.vertical, 2)
                    .background(GeometryReader { inner in
                        Color.clear.preference(
                            key: ScrollFrameKey.self,
                            value: inner.frame(in: .named("chatScroll"))
                        )
                    })
                }
                .coordinateSpace(name: "chatScroll")
                .onPreferenceChange(ScrollFrameKey.self) { frame in
                    contentTop = frame.minY
                    contentHeight = frame.height
                    viewportHeight = outer.size.height
                }
                .overlay(alignment: .bottomTrailing) { scrollButtons(proxy) }
                // Land at the newest message when opening / resuming a conversation.
                .onAppear { scrollToBottom(proxy, animated: false) }
                .onChange(of: session.messages.count) { _ in scrollToBottom(proxy, animated: false) }
                .onChange(of: session.messages) { _ in
                    if isNearBottom { scrollToBottom(proxy, animated: true) }
                }
            }
        }
    }

    // Only show a jump button for the direction you're away from, and only when
    // the content is actually scrollable — so nothing crowds the view at rest.
    private var scrollY: CGFloat { -contentTop }
    private var maxScroll: CGFloat { max(0, contentHeight - viewportHeight) }
    private var isScrollable: Bool { contentHeight > viewportHeight + 20 }
    private var isNearTop: Bool { scrollY < 24 }
    private var isNearBottom: Bool { contentHeight <= 0 || scrollY > maxScroll - 60 }

    // Always visible when scrollable — one clean capsule; the direction you
    // can't go is dimmed rather than hidden.
    @ViewBuilder
    private func scrollButtons(_ proxy: ScrollViewProxy) -> some View {
        if isScrollable {
            VStack(spacing: 0) {
                navChevron(icon: "chevron.up", enabled: !isNearTop) {
                    if let first = session.messages.first?.id {
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(first, anchor: .top) }
                    }
                }
                Divider().frame(width: 16)
                navChevron(icon: "chevron.down", enabled: !isNearBottom) {
                    scrollToBottom(proxy, animated: true)
                }
            }
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.16), radius: 4, y: 1)
            )
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.trailing, 12)
            .padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.15), value: isNearTop)
            .animation(.easeInOut(duration: 0.15), value: isNearBottom)
        }
    }

    private func navChevron(icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 30, height: 28)
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.28))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = session.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ask Claude Code about your project.").font(.callout).foregroundStyle(.secondary)
            Text("It runs in the folder above and can read your files. Switch to Full access to let it edit and run commands.")
                .font(.caption).foregroundStyle(.secondary.opacity(0.8))
        }
        .padding(.top, 6)
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !attachments.isEmpty { attachmentThumbnails }
            inputBar
        }
        .onPasteCommand(of: [.image]) { _ in pasteImageFromClipboard() }
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: handleDrop)
    }

    private var attachmentThumbnails: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: attachment.image)
                            .resizable().scaledToFill()
                            .frame(width: 46, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button(action: attachImage) {
                Image(systemName: "paperclip").font(.system(size: 15))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(!session.isAvailable)
            .help("Attach an image (or paste / drop one)")

            TextField(inputPlaceholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.callout)
                .lineLimit(1...6)
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .disabled(!session.isAvailable)

            if session.isStreaming {
                Button(action: session.stop) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain).foregroundStyle(.red).help("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend)
                .help("Send (⌘↩)")
            }
        }
    }

    private var inputPlaceholder: String {
        if session.pendingPermission != nil { return "Tell Claude what to do instead…" }
        return session.isAvailable ? "Ask about your code…" : "agent runner unavailable"
    }

    private var canSend: Bool {
        if session.pendingPermission != nil {
            return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return session.isAvailable
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func send() {
        // While awaiting approval, a typed message becomes "do this instead".
        if session.pendingPermission != nil {
            let instruction = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            session.answerPendingPermission(allow: false, message: instruction.isEmpty ? nil : instruction)
            draft = ""
            return
        }
        guard canSend else { return }
        session.send(draft, attachments: attachments.map(\.url))
        draft = ""
        attachments = []
    }

    // MARK: - Image attachments

    private func addImage(_ image: NSImage) {
        guard let url = AttachmentStore.saveTemp(image) else { return }
        attachments.append(AttachedImage(url: url, image: image))
    }

    private func pasteImageFromClipboard() {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            addImage(image)
        }
    }

    private func attachImage() {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            addImage(image)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK {
            for url in panel.urls where NSImage(contentsOf: url) != nil {
                addImage(NSImage(contentsOf: url)!)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL? = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
                if let url, let image = NSImage(contentsOf: url) {
                    DispatchQueue.main.async { addImage(image) }
                }
            }
        }
        return handled
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use folder"
        if panel.runModal() == .OK, let url = panel.url {
            session.openFolder(url)
            screen = .chat
        }
    }

    // MARK: - Small shared bits

    private func loading(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func empty(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Navigation header

private struct NavHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var back: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.back = back
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let back {
                IconButton(systemImage: "chevron.left", help: "Back", action: back)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            trailing
        }
    }
}

// MARK: - Rows

private struct ProjectRow: View {
    let project: ClaudeProject
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Card(highlighted: hovering) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name).font(.callout.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            if let branch = project.gitBranch {
                                Label(branch, systemImage: "arrow.triangle.branch")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            Text("\(project.sessionCount) chat\(project.sessionCount == 1 ? "" : "s")")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                            Text("· \(RelativeTime.string(project.lastModified))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SessionRow: View {
    let summary: ClaudeSessionSummary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Card(highlighted: hovering) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.title).font(.callout).lineLimit(2)
                        HStack(spacing: 6) {
                            Text("\(summary.messageCount) msgs").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text("· \(RelativeTime.string(summary.lastModified))")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.uturn.left").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovering ? Color.accentColor : .secondary)
                        .help("Resume")
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    static func string(_ date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Permission prompt

private struct PermissionPrompt: View {
    let request: PermissionRequest
    let onYes: () -> Void
    let onAlways: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text(request.title).font(.callout.weight(.semibold))
            }
            if !request.body.isEmpty {
                ScrollView {
                    Text(request.body)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.18)))
            }
            choice(index: "1", label: "Yes", tint: .green, filled: true, action: onYes)
            if request.canRemember {
                choice(index: "2", label: "Yes, and don't ask again", tint: .green, filled: false, action: onAlways)
                choice(index: "3", label: "No", tint: .primary, filled: false, action: onNo)
            } else {
                choice(index: "2", label: "No", tint: .primary, filled: false, action: onNo)
            }
            Text("…or type an instruction below")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.4)))
    }

    private func choice(index: String, label: String, tint: Color, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(index).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(label).fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(filled ? tint.opacity(0.85) : Color.primary.opacity(0.07)))
            .foregroundStyle(filled ? Color.white : tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Scroll metrics

private struct ScrollFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - Picker menu

private struct PickerMenu<T: Identifiable & Hashable>: View {
    let systemImage: String
    let items: [T]
    @Binding var selection: T
    var tint: Color = .secondary
    let label: (T) -> String

    var body: some View {
        Menu {
            ForEach(items) { item in
                Button {
                    selection = item
                } label: {
                    if item == selection {
                        Label(label(item), systemImage: "checkmark")
                    } else {
                        Text(label(item))
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
                Text(label(selection)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(tint == .secondary ? Color.primary.opacity(0.75) : tint)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: ChatMessage
    var workingVerb: String = ""
    var workingTokens: Int = 0

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 28) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if !message.attachments.isEmpty { attachmentThumbs }
                if !message.tools.isEmpty { toolActivity }
                if !message.text.isEmpty || message.isStreaming || message.role == .assistant {
                    bubbleBody
                }
            }
            if message.role == .assistant { Spacer(minLength: 10) }
        }
    }

    @ViewBuilder
    private var bubbleBody: some View {
        if message.role == .assistant && message.text.isEmpty && message.isStreaming {
            workingIndicator
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(bubbleShape)
        } else if message.role == .assistant {
            MarkdownText(text: message.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(bubbleShape)
        } else {
            Text(message.text)
                .font(.callout).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(bubbleShape)
                .foregroundStyle(foreground)
        }
    }

    // Two-line working indicator, à la Claude Code: "Thinking… · N tokens" + a
    // rotating verb ("Ideating…").
    private var workingIndicator: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Color.secondary).frame(width: 5, height: 5)
                Text("Thinking…" + (workingTokens > 0 ? " · \(workingTokens) tokens" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.system(size: 10))
                Text((workingVerb.isEmpty ? "Working" : workingVerb) + "…")
                    .font(.callout.weight(.semibold))
            }
        }
    }

    // Tool activity list, à la Claude Code: green dot + bold tool name + target.
    private var toolActivity: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(message.tools, id: \.self) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    toolText(entry)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private func toolText(_ entry: String) -> Text {
        let parts = entry.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? entry
        let detail = parts.count > 1 ? parts[1] : ""
        return Text(name).font(.system(size: 11, weight: .semibold))
            + Text(detail.isEmpty ? "" : " " + detail)
                .font(.system(size: 11)).foregroundColor(.secondary)
    }

    private var attachmentThumbs: some View {
        HStack(spacing: 4) {
            ForEach(message.attachments, id: \.self) { url in
                if let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private var bubbleShape: some View {
        RoundedRectangle(cornerRadius: DS.corner, style: .continuous).fill(background)
    }

    private var background: Color {
        if message.isError { return Color.red.opacity(0.12) }
        return message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor)
    }

    private var foreground: Color {
        if message.isError { return .primary }
        return message.role == .user ? .white : .primary
    }
}
