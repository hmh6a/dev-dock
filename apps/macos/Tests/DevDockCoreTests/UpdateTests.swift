import XCTest
@testable import DevDockCore

final class AppVersionTests: XCTestCase {

    func testParsesTagsWithAndWithoutTheV() {
        XCTAssertEqual(AppVersion("v1.4.2"), AppVersion(major: 1, minor: 4, patch: 2))
        XCTAssertEqual(AppVersion("1.4.2"), AppVersion(major: 1, minor: 4, patch: 2))
        XCTAssertEqual(AppVersion("0.0.0-dev")?.suffix, "dev")
        XCTAssertEqual(AppVersion("v2.10.30")?.minor, 10)
    }

    func testRejectsAnythingThatIsNotThreeNumbers() {
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion("v1.2"))
        XCTAssertNil(AppVersion("1.2.3.4"))
        XCTAssertNil(AppVersion("v1.two.3"))
        XCTAssertNil(AppVersion(""))
    }

    func testOrdersByNumbersNotText() {
        XCTAssertTrue(AppVersion("v1.2.9")! < AppVersion("v1.2.10")!)
        XCTAssertTrue(AppVersion("v1.9.0")! < AppVersion("v2.0.0")!)
        XCTAssertTrue(AppVersion("v0.1.0")! > AppVersion("v0.0.9")!)
        // The suffix is display only — it never changes the order.
        XCTAssertEqual(AppVersion("1.2.3-beta")!, AppVersion("1.2.3")!)
    }

    /// The release contract: the patch number decides whether an update can wait.
    func testEvenPatchNumbersAreMandatoryReleases() {
        XCTAssertTrue(AppVersion("v1.0.0")!.isMandatoryRelease)
        XCTAssertTrue(AppVersion("v1.0.2")!.isMandatoryRelease)
        XCTAssertTrue(AppVersion("v3.7.14")!.isMandatoryRelease)
        XCTAssertFalse(AppVersion("v1.0.1")!.isMandatoryRelease)
        XCTAssertFalse(AppVersion("v1.0.3")!.isMandatoryRelease)
        XCTAssertFalse(AppVersion("v3.7.15")!.isMandatoryRelease)
    }

    func testTagRoundTrips() {
        XCTAssertEqual(AppVersion("v1.4.2")!.tag, "v1.4.2")
        XCTAssertEqual(AppVersion("1.4.2")!.description, "1.4.2")
    }
}

final class UpdatePlanTests: XCTestCase {

    private func release(_ tag: String) -> ReleaseInfo {
        ReleaseInfo(
            version: AppVersion(tag)!,
            pageURL: URL(string: "https://github.com/hmh6a/dev-dock/releases/tag/\(tag)")!,
            downloadURL: URL(string: "https://example.com/DevDock-\(tag).dmg")!
        )
    }

    func testNothingNewerMeansUpToDate() {
        let plan = UpdatePlan.evaluate(
            current: AppVersion("v1.2.3")!,
            releases: [release("v1.2.3"), release("v1.2.1")]
        )
        XCTAssertEqual(plan, .upToDate)
        XCTAssertNil(plan.release)
    }

    func testNoReleasesAtAllMeansUpToDate() {
        XCTAssertEqual(UpdatePlan.evaluate(current: AppVersion("v1.0.1")!, releases: []), .upToDate)
    }

    func testAnOddPatchIsOptional() {
        let plan = UpdatePlan.evaluate(current: AppVersion("v1.2.1")!, releases: [release("v1.2.3")])
        XCTAssertFalse(plan.isMandatory)
        XCTAssertEqual(plan.release?.version, AppVersion("v1.2.3"))
    }

    func testAnEvenPatchIsMandatory() {
        let plan = UpdatePlan.evaluate(current: AppVersion("v1.2.1")!, releases: [release("v1.2.4")])
        XCTAssertTrue(plan.isMandatory)
    }

    /// Skipping a mandatory release must not become optional just because the
    /// release after it was.
    func testAMandatoryReleaseInBetweenStillForcesTheUpdate() {
        let plan = UpdatePlan.evaluate(
            current: AppVersion("v1.0.1")!,
            releases: [release("v1.0.2"), release("v1.0.3"), release("v1.0.5")]
        )
        XCTAssertTrue(plan.isMandatory)
        // …and the user is offered the newest one, not the mandatory one they skipped.
        XCTAssertEqual(plan.release?.version, AppVersion("v1.0.5"))
    }

    /// A mandatory release the user already has must not force anything.
    func testAlreadyOnTheMandatoryReleaseIsNotForced() {
        let plan = UpdatePlan.evaluate(
            current: AppVersion("v1.0.2")!,
            releases: [release("v1.0.2"), release("v1.0.3")]
        )
        XCTAssertFalse(plan.isMandatory)
        XCTAssertEqual(plan.release?.version, AppVersion("v1.0.3"))
    }

    /// Blocking a checkout build would block whoever is working on the app.
    func testDevelopmentBuildsAreNeverBlocked() {
        let plan = UpdatePlan.evaluate(
            current: AppVersion("0.0.0-dev")!,
            releases: [release("v1.0.2")]
        )
        XCTAssertFalse(plan.isMandatory)
        XCTAssertEqual(plan.release?.version, AppVersion("v1.0.2"))
    }

    func testTheNewestReleaseWinsRegardlessOfFeedOrder() {
        let plan = UpdatePlan.evaluate(
            current: AppVersion("v1.0.1")!,
            releases: [release("v1.0.3"), release("v2.0.1"), release("v1.9.9")]
        )
        XCTAssertEqual(plan.release?.version, AppVersion("v2.0.1"))
    }
}

final class GitHubReleaseParserTests: XCTestCase {

    /// Trimmed to the fields we read, from `GET /repos/{owner}/{repo}/releases`.
    private let feed = """
    [
      {
        "tag_name": "v1.2.3",
        "html_url": "https://github.com/hmh6a/dev-dock/releases/tag/v1.2.3",
        "body": "Ports tab fixes",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-09-01T10:00:00Z",
        "assets": [
          {"name": "SHA256SUMS.txt", "browser_download_url": "https://example.com/SHA256SUMS.txt"},
          {"name": "DevDock-1.2.3-macOS.zip", "browser_download_url": "https://example.com/app.zip"},
          {"name": "DevDock-1.2.3-macOS.dmg", "browser_download_url": "https://example.com/app.dmg"}
        ]
      },
      {
        "tag_name": "v1.3.0-rc1",
        "html_url": "https://github.com/hmh6a/dev-dock/releases/tag/v1.3.0-rc1",
        "draft": false,
        "prerelease": true,
        "assets": []
      },
      {
        "tag_name": "v1.4.0",
        "html_url": "https://github.com/hmh6a/dev-dock/releases/tag/v1.4.0",
        "draft": true,
        "prerelease": false,
        "assets": []
      },
      {
        "tag_name": "nightly",
        "html_url": "https://github.com/hmh6a/dev-dock/releases/tag/nightly",
        "draft": false,
        "prerelease": false,
        "assets": []
      }
    ]
    """.data(using: .utf8)!

    func testKeepsOnlyPublishedVersionedReleases() throws {
        let releases = try GitHubReleaseParser.parse(feed)
        XCTAssertEqual(releases.map(\.version.tag), ["v1.2.3"])
    }

    func testPrefersTheDiskImageOverTheZip() throws {
        let release = try XCTUnwrap(GitHubReleaseParser.parse(feed).first)
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://example.com/app.dmg")
        XCTAssertEqual(release.installURL, release.downloadURL)
        XCTAssertEqual(release.notes, "Ports tab fixes")
        XCTAssertNotNil(release.publishedAt)
    }

    func testAReleaseWithNoInstallerFallsBackToItsPage() throws {
        let data = """
        [{"tag_name": "v2.0.1", "html_url": "https://example.com/tag/v2.0.1", "assets": []}]
        """.data(using: .utf8)!
        let release = try XCTUnwrap(GitHubReleaseParser.parse(data).first)
        XCTAssertNil(release.downloadURL)
        XCTAssertEqual(release.installURL.absoluteString, "https://example.com/tag/v2.0.1")
    }

    func testEmptyFeedParsesToNoReleases() throws {
        XCTAssertTrue(try GitHubReleaseParser.parse("[]".data(using: .utf8)!).isEmpty)
    }

    func testMalformedJSONThrows() {
        XCTAssertThrowsError(try GitHubReleaseParser.parse("not json".data(using: .utf8)!))
    }
}

final class UpdateCheckerTests: XCTestCase {

    private struct StubFetcher: ReleaseFeedFetching {
        let data: Data
        func fetch(_ url: URL) async throws -> Data { data }
    }

    private struct FailingFetcher: ReleaseFeedFetching {
        func fetch(_ url: URL) async throws -> Data { throw UpdateCheckError.server(status: 403) }
    }

    func testCheckTurnsTheFeedIntoAPlan() async throws {
        let feed = """
        [{"tag_name": "v1.0.4", "html_url": "https://example.com/t", "assets":
          [{"name": "DevDock-1.0.4-macOS.dmg", "browser_download_url": "https://example.com/a.dmg"}]}]
        """.data(using: .utf8)!
        let checker = UpdateChecker(repository: "hmh6a/dev-dock", fetcher: StubFetcher(data: feed))

        let plan = try await checker.check(current: AppVersion("v1.0.1")!)
        XCTAssertTrue(plan.isMandatory)
        XCTAssertEqual(plan.release?.version.tag, "v1.0.4")
    }

    func testFeedURLPointsAtTheRepositoryReleases() {
        let checker = UpdateChecker(repository: "hmh6a/dev-dock", fetcher: FailingFetcher())
        XCTAssertEqual(
            checker.feedURL.absoluteString,
            "https://api.github.com/repos/hmh6a/dev-dock/releases?per_page=30"
        )
    }

    func testANetworkFailurePropagatesInsteadOfLookingUpToDate() async {
        let checker = UpdateChecker(repository: "hmh6a/dev-dock", fetcher: FailingFetcher())
        do {
            _ = try await checker.check(current: AppVersion("v1.0.1")!)
            XCTFail("expected the check to throw")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .server(status: 403))
        }
    }
}
