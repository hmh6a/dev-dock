import AppKit

/// An image the user attached to a prompt, backed by a temp PNG file that Claude
/// Code can read.
struct AttachedImage: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let image: NSImage
}

/// Persists pasted/dropped images to temp PNG files so they can be referenced by
/// path in the prompt (Claude reads them with the Read tool).
enum AttachmentStore {
    private static let directory: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dev-dock-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func saveTemp(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
