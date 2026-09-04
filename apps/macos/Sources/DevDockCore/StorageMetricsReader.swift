import Foundation

/// Reads how full each mounted volume is.
///
/// Uses `URLResourceValues` rather than `df`, so the "available" figure matches
/// the one Finder shows — it counts purgeable space the system can reclaim,
/// which on an APFS Mac is often tens of gigabytes.
public struct StorageMetricsReader: Sendable {

    public init() {}

    /// Every local volume worth showing, boot disk first.
    ///
    /// Best-effort throughout: a volume whose capacity can't be read is skipped
    /// rather than failing the whole snapshot.
    public func scan() -> [VolumeUsage] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsBrowsableKey,
            .volumeIsLocalKey,
            .volumeIsRootFileSystemKey
        ]
        let mounted = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        let volumes = mounted.compactMap { url -> VolumeUsage? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal ?? false,
                  values.volumeIsBrowsable ?? false,
                  let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            // `availableCapacityForImportantUsage` is an Int64 already; fall back
            // to the plain capacity key on the volumes that don't publish it.
            let free = values.volumeAvailableCapacityForImportantUsage
                ?? Int64(values.volumeAvailableCapacity ?? 0)

            return VolumeUsage(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                totalBytes: Int64(total),
                freeBytes: max(0, min(Int64(total), free)),
                isRoot: values.volumeIsRootFileSystem ?? (url.path == "/")
            )
        }

        // Boot disk first, then the rest alphabetically — a stable order, so rows
        // don't jump around between refreshes.
        return volumes.sorted {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
