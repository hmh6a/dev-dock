import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates a QR code image locally (no network) from a string — used to show
/// the Remote Control session URL for scanning with the Claude mobile app.
enum QRCode {
    static func image(from string: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
