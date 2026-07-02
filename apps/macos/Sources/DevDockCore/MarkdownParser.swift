import Foundation

/// A block of rendered chat content. Enough structure to render assistant
/// messages nicely: prose (with inline markdown), copyable fenced code, and
/// standalone images.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case code(language: String?, content: String)
    case image(alt: String, url: String)
}

/// Splits a message into ``MarkdownBlock`` values. Block-level only — inline
/// markdown (bold, links, `code`) inside paragraphs is left to the renderer's
/// `AttributedString`. Pure and testable.
public enum MarkdownParser {

    public static func blocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    content: code.joined(separator: "\n")))
                index += 1 // consume the closing fence (or run off the end)
                continue
            }

            // A line that is *only* an image.
            if let image = parseImage(trimmed) {
                flushParagraph()
                blocks.append(image)
                index += 1
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func parseImage(_ string: String) -> MarkdownBlock? {
        guard string.hasPrefix("!["),
              string.hasSuffix(")"),
              let separator = string.range(of: "](") else { return nil }
        let alt = String(string[string.index(string.startIndex, offsetBy: 2)..<separator.lowerBound])
        let url = String(string[separator.upperBound..<string.index(before: string.endIndex)])
        guard !url.isEmpty else { return nil }
        return .image(alt: alt, url: url)
    }
}
