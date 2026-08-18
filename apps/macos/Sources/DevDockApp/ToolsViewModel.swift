import SwiftUI
import DevDockCore

/// Drives the Tools tab: which command-line tools are installed, and running or
/// installing them in a terminal window.
@MainActor
final class ToolsViewModel: ObservableObject {
    /// Installed tools, keyed by ``CLITool/id``. A missing key means not installed.
    @Published private(set) var installations: [String: CLIToolInstallation] = [:]
    @Published private(set) var isChecking = false
    /// Set when Homebrew itself is missing, so the install button can explain why.
    @Published private(set) var brewPath: String?
    @Published var errorMessage: String?

    let tools = CLIToolCatalog.all

    private let locator = CLIToolLocator()

    func installation(for tool: CLITool) -> CLIToolInstallation? {
        installations[tool.id]
    }

    func isInstalled(_ tool: CLITool) -> Bool {
        installations[tool.id] != nil
    }

    /// Re-check every tool. Cheap enough to run on every appearance and whenever
    /// the app comes back to the front — which is how an install started in the
    /// terminal turns into a "Run" button without the user pressing refresh.
    func refresh() async {
        isChecking = true
        errorMessage = nil
        async let found = locator.locateAllAsync(tools)
        async let brew = brewLocation()
        installations = await found
        brewPath = await brew
        isChecking = false
    }

    private func brewLocation() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.locator.path(forExecutable: "brew"))
            }
        }
    }

    /// Run the tool in a terminal window. No-op when it isn't installed.
    func run(_ tool: CLITool) {
        guard let installation = installation(for: tool) else { return }
        let command = ([installation.path] + tool.runArguments)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
        launch(command, title: tool.name)
    }

    /// Install the tool with Homebrew, in a terminal window so the user sees the
    /// download progress and any password prompt.
    ///
    /// The script re-checks before installing: the state here is a snapshot, and
    /// re-running `brew install` on a tool that is already there is pure noise.
    func install(_ tool: CLITool) {
        guard !isInstalled(tool) else { return }
        guard let brew = brewPath else {
            errorMessage = "Homebrew isn't installed — see https://brew.sh, then try again."
            return
        }

        let command = """
        if command -v \(tool.executable) >/dev/null 2>&1; then
          echo "\(tool.name) is already installed at $(command -v \(tool.executable)) — nothing to do."
        else
          \(brew) install \(tool.brewFormula)
        fi
        """
        launch(command, title: tool.installCommand)

        // The install runs in another window, so poll for a little while and let
        // the card flip to "Run" on its own once brew finishes.
        Task { await pollUntilInstalled(tool) }
    }

    private func launch(_ command: String, title: String) {
        do {
            try TerminalLauncher.run(command, title: title)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-check every few seconds until the tool shows up, giving up after ~2
    /// minutes — long enough for a `brew install`, short enough not to linger.
    private func pollUntilInstalled(_ tool: CLITool) async {
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            let found = await locator.locateAllAsync([tool])
            if let installation = found[tool.id] {
                installations[tool.id] = installation
                return
            }
        }
    }
}
