import Foundation

/// One published release, as the GitHub Releases API describes it.
public struct ReleaseInfo: Equatable, Sendable, Identifiable {
    public let version: AppVersion
    /// The release page, for "what changed".
    public let pageURL: URL
    /// The `.dmg` to download, when the release has one.
    public let downloadURL: URL?
    public let notes: String?
    public let publishedAt: Date?

    public var id: String { version.tag }

    public init(
        version: AppVersion,
        pageURL: URL,
        downloadURL: URL? = nil,
        notes: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.version = version
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.notes = notes
        self.publishedAt = publishedAt
    }

    /// What the user should open: the installer if there is one, else the page.
    public var installURL: URL { downloadURL ?? pageURL }
}

/// What, if anything, the user should do about the releases we found.
public enum UpdatePlan: Equatable, Sendable {
    case upToDate
    /// A newer release exists and the user may take it whenever they like.
    case optional(ReleaseInfo)
    /// A newer release exists that the user must install — see
    /// ``AppVersion/isMandatoryRelease``.
    case mandatory(ReleaseInfo)

    public var release: ReleaseInfo? {
        switch self {
        case .upToDate: return nil
        case .optional(let release), .mandatory(let release): return release
        }
    }

    public var isMandatory: Bool {
        if case .mandatory = self { return true }
        return false
    }

    /// Decide what to do with the releases we know about.
    ///
    /// The newest release wins, and the update is mandatory when **any** release
    /// newer than the installed one has an even patch number — not just the
    /// newest. Someone who skipped three versions must not slip past a mandatory
    /// one just because the release after it was optional.
    ///
    /// A development build (`0.0.0`) is never *forced* to update: it is a build
    /// from a checkout, and blocking it would block the person working on the app.
    public static func evaluate(current: AppVersion, releases: [ReleaseInfo]) -> UpdatePlan {
        let newer = releases
            .filter { $0.version > current }
            .sorted { $0.version < $1.version }
        guard let latest = newer.last else { return .upToDate }

        let mandatory = newer.contains { $0.version.isMandatoryRelease }
        return mandatory && !current.isDevelopmentBuild ? .mandatory(latest) : .optional(latest)
    }
}

/// Decodes the GitHub Releases API response.
///
/// Kept separate from the network call so the parsing — which is where the
/// surprises live (drafts, pre-releases, tags that aren't versions, releases
/// with no `.dmg`) — can be tested against captured JSON.
public enum GitHubReleaseParser {

    /// Every published, non-draft, non-prerelease release with a `vX.Y.Z` tag.
    public static func parse(_ data: Data) throws -> [ReleaseInfo] {
        let payload = try JSONDecoder().decode([Payload].self, from: data)
        return payload.compactMap(release(from:))
    }

    private static func release(from payload: Payload) -> ReleaseInfo? {
        guard !(payload.draft ?? false), !(payload.prerelease ?? false),
              let version = AppVersion(payload.tag_name),
              let page = URL(string: payload.html_url)
        else { return nil }

        // Prefer the disk image: opening it is the install gesture Mac users know.
        let installer = payload.assets?.first { $0.name.hasSuffix(".dmg") }
            ?? payload.assets?.first { $0.name.hasSuffix(".zip") }

        return ReleaseInfo(
            version: version,
            pageURL: page,
            downloadURL: installer.flatMap { URL(string: $0.browser_download_url) },
            notes: payload.body,
            publishedAt: payload.published_at.flatMap(ISO8601DateFormatter().date(from:))
        )
    }

    // Only the fields we use; GitHub sends many more.
    private struct Payload: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
        let published_at: String?
        let assets: [Asset]?
    }

    private struct Asset: Decodable {
        let name: String
        let browser_download_url: String
    }
}
