// Renders assets/AppIcon.icns: a white shield on a blue rounded square. Run from the repo root:
//   swift scripts/make-icon.swift
// The .icns is committed; re-run only to change the artwork.
import AppKit

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: the artwork sits in ~80% of the canvas with a continuous-corner square.
    let inset = s * 0.1
    let square = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: square, xRadius: square.width * 0.225, yRadius: square.width * 0.225)
    NSGradient(starting: NSColor(calibratedRed: 0.29, green: 0.56, blue: 0.98, alpha: 1),
               ending: NSColor(calibratedRed: 0.11, green: 0.31, blue: 0.82, alpha: 1))!.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: square.width * 0.5, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let shield = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = shield.size
        shield.draw(in: NSRect(x: (s - size.width) / 2, y: (s - size.height) / 2, width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "assets/AppIcon.icns"]
try FileManager.default.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote assets/AppIcon.icns" : "iconutil failed")
