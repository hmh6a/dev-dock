import Foundation

/// Fetches the release list. A protocol so the checker can be tested against
/// canned JSON instead of the network.
public protocol ReleaseFeedFetching: Sendable {
    func fetch(_ url: URL) async throws -> Data
}

public struct ReleaseFeedFetcher: ReleaseFeedFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // GitHub asks API clients to identify themselves and to pin the API
        // version; unauthenticated calls are fine at one every twelve hours.
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("dev-dock", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateCheckError.server(status: http.statusCode)
        }
        return data
    }
}

public enum UpdateCheckError: LocalizedError, Equatable {
    case server(status: Int)

    public var errorDescription: String? {
        switch self {
        case .server(let status) where status == 403 || status == 429:
            return "GitHub is rate-limiting update checks — try again later."
        case .server(let status) where status == 404:
            // GitHub answers 404 — not 403 — for a repository the caller cannot
            // see, so a private repo and a repo with no releases look alike here.
            return "No public releases found — is the repository public?"
        case .server(let status):
            return "GitHub returned HTTP \(status)."
        }
    }
}

/// Asks GitHub what the newest release is and decides what the user should do
/// about it.
public struct UpdateChecker: Sendable {

    /// The repository releases are published from.
    public static let defaultRepository = "hmh6a/dev-dock"

    private let repository: String
    private let fetcher: ReleaseFeedFetching

    public init(
        repository: String = UpdateChecker.defaultRepository,
        fetcher: ReleaseFeedFetching = ReleaseFeedFetcher()
    ) {
        self.repository = repository
        self.fetcher = fetcher
    }

    /// The last 30 releases — enough history to notice a mandatory release the
    /// user skipped, and one request either way.
    public var feedURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30")!
    }

    /// Check for updates. Throws on network or API failure; the caller decides
    /// whether a failed check is worth showing.
    public func check(current: AppVersion) async throws -> UpdatePlan {
        let data = try await fetcher.fetch(feedURL)
        let releases = try GitHubReleaseParser.parse(data)
        return UpdatePlan.evaluate(current: current, releases: releases)
    }
}
