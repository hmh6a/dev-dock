import Foundation
import AppKit

/// Opens a real terminal window running a command.
///
/// It writes a `.command` script and hands it to `NSWorkspace`, rather than
/// scripting Terminal over AppleScript. Two reasons: AppleScript automation
/// needs a TCC grant the user would have to approve first (and a `launchd`-
/// started agent has nothing to attach that prompt to), and opening a document
/// respects whichever terminal the user set as the handler for `.command`.
enum TerminalLauncher {

    enum LaunchError: LocalizedError {
        case couldNotWriteScript(String)
        case noTerminalApp

        var errorDescription: String? {
            switch self {
            case .couldNotWriteScript(let reason):
                return "Couldn't prepare the command: \(reason)"
            case .noTerminalApp:
                return "No app is set to open .command files."
            }
        }
    }

    /// Run `command` in a new terminal window.
    ///
    /// - Parameters:
    ///   - command: the shell line to execute.
    ///   - title: a short label echoed above the output so the window says what it is.
    ///   - directory: working directory for the command; defaults to the home folder.
    static func run(_ command: String, title: String, directory: String? = nil) throws {
        let script = """
        #!/bin/zsh
        # Written by dev-dock. Safe to delete.
        # A non-interactive zsh does not read ~/.zshrc, so put the usual Homebrew
        # prefixes back on PATH for anything the command shells out to.
        export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:$PATH"
        cd \(shellQuoted(directory ?? NSHomeDirectory()))
        printf '\\033[1;36m▸ %s\\033[0m\\n' \(shellQuoted(title))
        \(command)
        """

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-dock-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw LaunchError.couldNotWriteScript(error.localizedDescription)
        }

        guard let terminal = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            throw LaunchError.noTerminalApp
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration)
    }

    /// Single-quote a value for safe interpolation into the script.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
