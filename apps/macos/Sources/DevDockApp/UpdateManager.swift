import SwiftUI
import AppKit
import DevDockCore

/// Keeps the installed copy honest about its version: checks GitHub for a newer
/// release every twelve hours (and on demand), downloads the installer, and —
/// when the release is a mandatory one — tells the UI to block until it is taken.
///
/// See ``AppVersion/isMandatoryRelease`` for the rule: **an even patch number
/// (`z` in `vx.y.z`) is mandatory**, an odd one is optional.
@MainActor
final class UpdateManager: ObservableObject {

    /// How long a check is good for.
    static let checkInterval: TimeInterval = 12 * 60 * 60
    /// How often the loop wakes to ask whether a check is due. Short ticks rather
    /// than one twelve-hour sleep, so a Mac that spent the night asleep checks
    /// shortly after waking instead of drifting a night behind.
    private static let tickInterval: TimeInterval = 15 * 60

    @Published private(set) var plan: UpdatePlan = .upToDate
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var errorMessage: String?
    /// 0…1 while the installer is downloading, nil otherwise.
    @Published private(set) var downloadProgress: Double?
    /// Set once the disk image is on disk and has been handed to Finder.
    @Published private(set) var downloadedInstaller: URL?

    let currentVersion: AppVersion

    private let checker: UpdateChecker
    private var scheduleTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?

    private enum Key {
        static let lastChecked = "update.lastCheckedAt"
        static let dismissedVersion = "update.dismissedVersion"
    }

    init(checker: UpdateChecker = UpdateChecker()) {
        self.checker = checker
        self.currentVersion = Self.installedVersion()
        let stored = UserDefaults.standard.double(forKey: Key.lastChecked)
        self.lastCheckedAt = stored > 0 ? Date(timeIntervalSince1970: stored) : nil
    }

    /// The version this build reports, or `0.0.0-dev` when it was run straight
    /// from a checkout (`swift run`), where there is no bundle version to read.
    static func installedVersion() -> AppVersion {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return raw.flatMap(AppVersion.init) ?? AppVersion(major: 0, minor: 0, patch: 0, suffix: "dev")
    }

    // MARK: - Schedule

    /// Start the twelve-hour cycle. Checks straight away if the last check has
    /// aged out (or never happened), so a Mac that is rarely left running still
    /// hears about a mandatory release.
    func start() {
        guard scheduleTask == nil else { return }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(nanoseconds: UInt64(Self.tickInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    var nextCheckDue: Date? {
        lastCheckedAt?.addingTimeInterval(Self.checkInterval)
    }

    private func checkIfDue() async {
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.checkInterval { return }
        await check()
    }

    // MARK: - Checking

    /// Check now. Used by the Settings button and by the schedule.
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        errorMessage = nil
        do {
            plan = try await checker.check(current: currentVersion)
            lastCheckedAt = Date()
            UserDefaults.standard.set(lastCheckedAt!.timeIntervalSince1970, forKey: Key.lastChecked)
        } catch {
            // A failed check is not an emergency — the app keeps working and the
            // next tick tries again. Only the Settings card mentions it.
            errorMessage = error.localizedDescription
        }
        isChecking = false
    }

    // MARK: - What the UI shows

    /// Blocks the whole window: the installed build is behind a release that was
    /// published as mandatory.
    var mustUpdate: Bool { plan.isMandatory }

    /// An optional update the user hasn't waved away yet.
    var showsOptionalUpdate: Bool {
        guard case .optional(let release) = plan else { return false }
        return UserDefaults.standard.string(forKey: Key.dismissedVersion) != release.version.tag
    }

    /// Hide this optional update until a newer one shows up. Mandatory updates
    /// have no such door.
    func dismissOptionalUpdate() {
        guard case .optional(let release) = plan else { return }
        UserDefaults.standard.set(release.version.tag, forKey: Key.dismissedVersion)
        objectWillChange.send()
    }

    // MARK: - Installing

    /// Download the release's disk image and hand it to Finder, which mounts it
    /// and opens the drag-to-Applications window.
    ///
    /// Deliberately not a silent self-replacing updater: this build is signed
    /// ad-hoc rather than with a Developer ID, and a copy that swaps its own
    /// binary is exactly the shape of thing macOS is right to distrust. The user
    /// stays in the loop for the one gesture that matters.
    func downloadAndReveal() {
        guard let release = plan.release, downloadTask == nil else { return }
        guard let source = release.downloadURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }

        downloadProgress = 0
        errorMessage = nil
        downloadTask = Task { [weak self] in
            defer { Task { @MainActor in self?.downloadTask = nil } }
            do {
                let destination = try await Self.download(source, progress: { fraction in
                    Task { @MainActor in self?.downloadProgress = fraction }
                })
                await MainActor.run {
                    self?.downloadProgress = nil
                    self?.downloadedInstaller = destination
                    NSWorkspace.shared.open(destination)
                }
            } catch {
                await MainActor.run {
                    self?.downloadProgress = nil
                    self?.errorMessage = "Download failed — \(error.localizedDescription)"
                    // Fall back to the browser rather than leaving a dead end.
                    NSWorkspace.shared.open(release.pageURL)
                }
            }
        }
    }

    func openReleasePage() {
        guard let release = plan.release else { return }
        NSWorkspace.shared.open(release.pageURL)
    }

    /// Download the installer to ~/Downloads, reporting progress as it goes.
    private static func download(
        _ url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let temporary = try await InstallerDownload.run(url, progress: progress)

        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = downloads.appendingPathComponent(url.lastPathComponent)
        // URLSession hands the file over in a temporary location it will delete
        // as soon as the delegate returns, so it has to be moved, not copied later.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// A one-shot `URLSession` download that reports progress.
///
/// `URLSession.bytes(from:)` would be fewer lines, but iterating a 26 MB disk
/// image one byte at a time is slow enough to notice; the download delegate
/// streams to a file at full speed and hands back progress on the way.
private final class InstallerDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    /// Keeps the helper alive for the length of the transfer — `URLSession` holds
    /// only a weak-ish reference through its delegate contract.
    private var retained: InstallerDownload?

    private init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    static func run(
        _ url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let helper = InstallerDownload(progress: progress)
        return try await withCheckedThrowingContinuation { continuation in
            helper.continuation = continuation
            helper.retained = helper
            let session = URLSession(configuration: .default, delegate: helper, delegateQueue: nil)
            session.downloadTask(with: url).resume()
            // The session owns the helper until the transfer finishes.
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file is deleted when this returns, so move it somewhere durable now.
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(location.pathExtension)
        do {
            try FileManager.default.moveItem(at: location, to: staged)
            progress(1)
            finish(.success(staged))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        retained = nil
        continuation.resume(with: result)
    }
}
