import Foundation

/// A command-line tool dev-dock can check for, install, and launch — the model
/// behind the **Tools** tab.
///
/// A plain value type with no behaviour, so the catalog below stays a piece of
/// data: adding a tool is one entry, not new code.
public struct CLITool: Identifiable, Equatable, Hashable, Sendable {
    /// Stable identity, also used as the SwiftUI list id.
    public let id: String
    /// Name shown in the UI.
    public let name: String
    /// One-line description of what the tool does.
    public let tagline: String
    /// The executable to look for on disk — e.g. `mole`.
    public let executable: String
    /// The Homebrew formula that provides it, used to build `brew install …`.
    public let brewFormula: String
    /// What to run when the user launches the tool. Usually just the executable.
    public let runArguments: [String]
    /// Arguments that make the tool print its version.
    public let versionArguments: [String]
    /// SF Symbol shown on the tool's card.
    public let symbolName: String

    public init(
        id: String,
        name: String,
        tagline: String,
        executable: String,
        brewFormula: String,
        runArguments: [String] = [],
        versionArguments: [String] = ["--version"],
        symbolName: String
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.executable = executable
        self.brewFormula = brewFormula
        self.runArguments = runArguments
        self.versionArguments = versionArguments
        self.symbolName = symbolName
    }

    /// The Homebrew command that installs this tool.
    public var installCommand: String { "brew install \(brewFormula)" }
}

/// The tools dev-dock offers. One entry per tool — see ``CLITool``.
public enum CLIToolCatalog {
    public static let mole = CLITool(
        id: "mole",
        name: "mole",
        tagline: "Deep clean and optimize your Mac",
        executable: "mole",
        brewFormula: "mole",
        versionArguments: ["--version"],
        symbolName: "sparkles.rectangle.stack"
    )

    public static let all: [CLITool] = [mole]
}
