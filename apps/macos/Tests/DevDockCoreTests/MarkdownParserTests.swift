import XCTest
@testable import DevDockCore

final class MarkdownParserTests: XCTestCase {

    func testPlainParagraph() {
        XCTAssertEqual(MarkdownParser.blocks(from: "hello world"), [.paragraph("hello world")])
    }

    func testFencedCodeBlockWithLanguage() {
        let text = """
        Run this:

        ```bash
        cd apps/macos
        swift run DevDock
        ```

        Done.
        """
        XCTAssertEqual(MarkdownParser.blocks(from: text), [
            .paragraph("Run this:"),
            .code(language: "bash", content: "cd apps/macos\nswift run DevDock"),
            .paragraph("Done."),
        ])
    }

    func testCodeBlockWithoutLanguage() {
        let text = "```\nplain code\n```"
        XCTAssertEqual(MarkdownParser.blocks(from: text), [.code(language: nil, content: "plain code")])
    }

    func testUnclosedCodeFenceTakesRest() {
        let text = "```swift\nlet x = 1"
        XCTAssertEqual(MarkdownParser.blocks(from: text), [.code(language: "swift", content: "let x = 1")])
    }

    func testStandaloneImage() {
        XCTAssertEqual(
            MarkdownParser.blocks(from: "![a diagram](https://example.com/a.png)"),
            [.image(alt: "a diagram", url: "https://example.com/a.png")]
        )
    }

    func testImageBetweenParagraphs() {
        let text = "before\n\n![](/tmp/shot.png)\n\nafter"
        XCTAssertEqual(MarkdownParser.blocks(from: text), [
            .paragraph("before"),
            .image(alt: "", url: "/tmp/shot.png"),
            .paragraph("after"),
        ])
    }

    func testInlineImageStaysInParagraph() {
        // Not a standalone image line → remains prose (inline markdown handled by renderer).
        XCTAssertEqual(
            MarkdownParser.blocks(from: "see ![x](y) here"),
            [.paragraph("see ![x](y) here")]
        )
    }

    func testArabicParagraphPreserved() {
        let text = "شغّل الأمر التالي:"
        XCTAssertEqual(MarkdownParser.blocks(from: text), [.paragraph("شغّل الأمر التالي:")])
    }
}
