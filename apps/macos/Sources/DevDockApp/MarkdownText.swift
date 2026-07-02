import SwiftUI
import AppKit
import DevDockCore

/// Renders an assistant message as blocks: prose with inline markdown, fenced
/// code with a copy button, and standalone images (also copyable).
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownParser.blocks(from: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .paragraph(paragraph):
                    ParagraphView(text: paragraph)
                case let .code(language, content):
                    CodeBlockView(language: language, content: content)
                case let .image(alt, url):
                    ImageBlockView(alt: alt, url: url)
                }
            }
        }
    }
}

/// A paragraph with inline markdown (bold, italics, `code`, links). Whitespace
/// is preserved so intra-paragraph line breaks survive.
private struct ParagraphView: View {
    let text: String

    var body: some View {
        Text(attributed)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A fenced code block: monospaced, horizontally scrollable, with a copy button.
private struct CodeBlockView: View {
    let language: String?
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    HStack(spacing: 3) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 9, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? .green : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

/// A standalone image (remote or local file), with a "copy image" button.
private struct ImageBlockView: View {
    let alt: String
    let url: String
    @State private var image: NSImage?
    @State private var failed = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            imageContent
            HStack(spacing: 6) {
                if !alt.isEmpty {
                    Text(alt).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if image != nil {
                    Button(action: copyImage) {
                        HStack(spacing: 3) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            Text(copied ? "Copied" : "Copy image")
                        }
                        .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .secondary)
                }
            }
        }
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(height: failed ? 44 : 80)
                .overlay {
                    if failed {
                        Label(url, systemImage: "photo").font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).padding(.horizontal, 8)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
        }
    }

    private func load() async {
        image = nil
        failed = false
        if let loaded = await Self.loadImage(from: url) {
            image = loaded
        } else {
            failed = true
        }
    }

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }

    private static func loadImage(from string: String) async -> NSImage? {
        if string.hasPrefix("http://") || string.hasPrefix("https://") {
            guard let url = URL(string: string),
                  let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return NSImage(data: data)
        }
        if string.hasPrefix("file://") {
            guard let url = URL(string: string) else { return nil }
            return NSImage(contentsOf: url)
        }
        let path = (string as NSString).expandingTildeInPath
        return NSImage(contentsOfFile: path)
    }
}
