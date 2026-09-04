import Foundation

/// A semantic version of the app — `v1.4.2` → `1.4.2`.
///
/// Only the three numbers matter for update decisions; a suffix (`-dev`, `-beta.1`)
/// is kept for display but never affects ordering, because dev-dock releases are
/// plain `vX.Y.Z` tags.
public struct AppVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Anything after the numbers — `dev` in `0.0.0-dev`.
    public let suffix: String?

    public init(major: Int, minor: Int, patch: Int, suffix: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.suffix = suffix
    }

    /// Parse `v1.2.3`, `1.2.3`, or `1.2.3-dev`. Nil when there aren't three numbers.
    public init?(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }

        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let numbers = parts.first else { return nil }

        let components = numbers.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0, minor >= 0, patch >= 0
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        let suffix = parts.count > 1 ? String(parts[1]) : nil
        self.suffix = (suffix?.isEmpty ?? true) ? nil : suffix
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return suffix.map { "\(core)-\($0)" } ?? core
    }

    /// How the version is written everywhere the user sees it, and how release
    /// tags are named.
    public var tag: String { "v\(description)" }

    /// **The release rule for dev-dock: an even patch number is a mandatory
    /// update.** Odd patches are optional, and the user can keep working.
    ///
    /// It lives on the version itself because that is the whole contract — the
    /// number in the tag is what tells every installed copy whether it may
    /// postpone the update.
    public var isMandatoryRelease: Bool { patch % 2 == 0 }

    /// A build that was never released — what `swift run` produces, where the
    /// bundle carries no real version. Never blocked by a mandatory update.
    public var isDevelopmentBuild: Bool { major == 0 && minor == 0 && patch == 0 }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Equality follows ordering: the suffix is display text, so `1.2.3-beta`
    /// and `1.2.3` are the same version. Leaving this to the synthesized
    /// conformance would make two versions neither equal nor ordered.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
    }
}
