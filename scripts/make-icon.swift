#!/usr/bin/env swift
//
// dev-dock — generate the app icon.
//
//   swift scripts/make-icon.swift <output.icns>
//
// Draws the same shipping-box symbol the menu bar uses on a rounded-rect
// gradient, renders it at every size macOS asks for, and packs the result with
// `iconutil`. Generating it beats checking a binary into the repo: the icon
// stays in sync with the menu bar glyph, and there is nothing to re-export by
// hand when it changes.
//
// Best-effort by design — the packaging script ships the app without an icon if
// this fails rather than failing the build.

import AppKit
import Foundation

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "AppIcon.icns")

/// One square icon rendering at the given pixel size.
func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // macOS icons sit in a rounded square with a little breathing room.
    let inset = size * 0.06
    let plate = NSBezierPath(
        roundedRect: rect.insetBy(dx: inset, dy: inset),
        xRadius: size * 0.2,
        yRadius: size * 0.2
    )
    NSGradient(
        colors: [
            NSColor(calibratedRed: 0.20, green: 0.44, blue: 0.98, alpha: 1),
            NSColor(calibratedRed: 0.09, green: 0.24, blue: 0.72, alpha: 1)
        ]
    )?.draw(in: plate, angle: -90)

    let configuration = NSImage.SymbolConfiguration(
        pointSize: size * 0.5, weight: .semibold
    )
    if let symbol = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        // SF Symbols are template images: paint white through the glyph's own
        // alpha, rather than filling its bounding box.
        let white = NSImage(size: symbol.size, flipped: false) { bounds in
            NSColor.white.setFill()
            bounds.fill()
            symbol.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        white.draw(
            in: NSRect(
                x: (size - symbol.size.width) / 2,
                y: (size - symbol.size.height) / 2,
                width: symbol.size.width,
                height: symbol.size.height
            ),
            from: .zero, operation: .sourceOver, fraction: 1
        )
    }
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    representation.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])
}

let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DevDockIcon-\(UUID().uuidString)/AppIcon.iconset")
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

// The set `iconutil` expects: every size at 1× and 2×.
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let data = png(icon(size: CGFloat(pixels)), pixels: pixels) else {
            FileHandle.standardError.write(Data("could not render \(pixels)px\n".utf8))
            exit(1)
        }
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try data.write(to: workspace.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", workspace.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent())
exit(iconutil.terminationStatus)
