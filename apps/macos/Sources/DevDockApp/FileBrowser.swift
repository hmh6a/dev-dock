import Foundation
import DevDockCore

/// Read-only file access for the phone's Files tab. Every path is clamped inside
/// the project root, so a remote client can browse and read but never escape the
/// project or write anything.
enum FileBrowser {
    static let maxFileBytes = 400_000
    private static let hidden: Set<String> = [".git", ".DS_Store", ".build"]

    /// Directory entries under `path` (folders first, then name). `path` is
    /// clamped to `root`; an out-of-bounds or missing path falls back to `root`.
    static func list(path: String, root: String) -> (path: String, entries: [FileEntryWire]) {
        let dir = resolved(path, root: root)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return (root, []) }

        var entries: [FileEntryWire] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !hidden.contains(name) {
            let full = (dir as NSString).appendingPathComponent(name)
            var sub: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &sub)
            let size = ((try? fm.attributesOfItem(atPath: full))?[.size] as? Int) ?? 0
            entries.append(FileEntryWire(name: name, isDir: sub.boolValue, size: size))
        }
        entries.sort { a, b in
            a.isDir == b.isDir ? a.name.lowercased() < b.name.lowercased() : (a.isDir && !b.isDir)
        }
        return (dir, entries)
    }

    /// Read a file's text (truncated if huge; a note for binary files).
    static func read(path: String, root: String) -> (path: String, content: String, truncated: Bool)? {
        let file = resolved(path, root: root)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: file, isDirectory: &isDir), !isDir.boolValue,
              let data = fm.contents(atPath: file) else { return nil }

        let truncated = data.count > maxFileBytes
        let slice = truncated ? data.prefix(maxFileBytes) : data.prefix(data.count)
        if slice.contains(0) { return (file, "[binary file — \(data.count) bytes]", false) }
        return (file, String(decoding: slice, as: UTF8.self), truncated)
    }

    /// Resolve `path` (relative to `root` unless absolute) and clamp inside `root`.
    private static func resolved(_ path: String, root: String) -> String {
        let rootStd = (root as NSString).standardizingPath
        let raw = path.isEmpty ? rootStd
            : (path.hasPrefix("/") ? path : (rootStd as NSString).appendingPathComponent(path))
        let std = (raw as NSString).standardizingPath
        return (std == rootStd || std.hasPrefix(rootStd + "/")) ? std : rootStd
    }
}
