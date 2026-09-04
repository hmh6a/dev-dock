import SwiftUI
import AppKit
import DevDockCore

/// The blocking screen for a mandatory release.
///
/// Drawn as an ordinary in-window overlay rather than a sheet or alert for the
/// same reason the kill confirmation is (see ``PortsView``): the menu bar panel
/// is a non-activating window, where native modal presentations don't reliably
/// receive clicks.
///
/// There is no dismiss button, by design — that is what "mandatory" means. Quit
/// is always available.
struct MandatoryUpdateOverlay: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(Color.accentColor)

                Text("Update required")
                    .font(.headline)

                if let release = updates.plan.release {
                    Text("dev-dock \(release.version.description) is a required update. "
                         + "You're on \(updates.currentVersion.description).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                if let progress = updates.downloadProgress {
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if updates.downloadedInstaller != nil {
                    // Finder is showing the mounted disk image at this point.
                    Text("Drag dev-dock to Applications, then quit and reopen it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else {
                    Button {
                        updates.downloadAndReveal()
                    } label: {
                        Label("Download and install", systemImage: "arrow.down.circle")
                            .frame(maxWidth: 200)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }

                if let error = updates.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                HStack(spacing: 12) {
                    Button("Release notes") { updates.openReleasePage() }
                        .buttonStyle(.link)
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.top, 2)
            }
            .padding(.vertical, 24)
        }
    }
}

/// The Settings card: what version is installed, when it last checked, and
/// whatever the last check found.
struct UpdatesCard: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("dev-dock").font(.callout.weight(.semibold))
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(updates.currentVersion.tag)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if let release = updates.plan.release {
                    Divider()
                    HStack(spacing: 8) {
                        Image(systemName: updates.mustUpdate ? "exclamationmark.triangle.fill" : "arrow.down.circle")
                            .foregroundStyle(updates.mustUpdate ? Color.orange : Color.accentColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(release.version.tag) available")
                                .font(.callout.weight(.medium))
                            Text(updates.mustUpdate ? "Required update" : "Optional update")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let progress = updates.downloadProgress {
                            ProgressView(value: progress).frame(width: 70)
                        } else {
                            Button("Install") { updates.downloadAndReveal() }
                                .controlSize(.small)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Release notes") { updates.openReleasePage() }
                            .buttonStyle(.link)
                        if updates.showsOptionalUpdate {
                            Button("Skip this version") { updates.dismissOptionalUpdate() }
                                .buttonStyle(.link)
                        }
                    }
                    .font(.caption)
                }

                if let error = updates.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }

                Divider()
                HStack {
                    Text("Checks automatically every 12 hours")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Check now") { Task { await updates.check() } }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private var statusLine: String {
        if updates.currentVersion.isDevelopmentBuild { return "Development build" }
        guard let checked = updates.lastCheckedAt else { return "Not checked yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: checked, relativeTo: Date()))"
    }
}

/// The banner shown above a tab's content when an optional update is waiting.
struct UpdateBanner: View {
    @ObservedObject var updates: UpdateManager

    var body: some View {
        if updates.showsOptionalUpdate, let release = updates.plan.release {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("\(release.version.tag) is available")
                    .font(.caption.weight(.medium))
                Spacer(minLength: 4)
                if let progress = updates.downloadProgress {
                    ProgressView(value: progress).frame(width: 60)
                } else {
                    Button("Install") { updates.downloadAndReveal() }
                        .controlSize(.mini)
                }
                IconButton(systemImage: "xmark", help: "Skip this version") {
                    updates.dismissOptionalUpdate()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
        }
    }
}
