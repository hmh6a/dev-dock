import Foundation
import DevDockCore

/// Which kind of build this is.
///
/// The distinction the app cares about is "is this a published release, or a
/// copy someone is working on": a release carries a real version
/// (`CFBundleShortVersionString`), while a checkout run through `swift run` — or
/// a local `scripts/package-app.sh` with no tag — reports `0.0.0-dev`.
enum AppBuild {

    /// The version this build reports, or `0.0.0-dev` when it was run straight
    /// from a checkout, where there is no bundle version to read.
    static let version: AppVersion = {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return raw.flatMap(AppVersion.init) ?? AppVersion(major: 0, minor: 0, patch: 0, suffix: "dev")
    }()

    /// True when this copy was not built from a release tag.
    ///
    /// Used to keep unfinished work out of what people install: the scaffolded
    /// tabs are there while the app is being built, and gone in the release.
    static var isDevelopment: Bool { version.isDevelopmentBuild }
}
