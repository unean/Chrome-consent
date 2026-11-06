import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let full = CGFloat(pixels)
        NSColor(calibratedRed: 0.045, green: 0.14, blue: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: full * 0.07, y: full * 0.07, width: full * 0.86, height: full * 0.86),
                     xRadius: full * 0.19, yRadius: full * 0.19).fill()
        let shield = NSBezierPath()
        shield.move(to: NSPoint(x: full * 0.5, y: full * 0.8))
        shield.line(to: NSPoint(x: full * 0.77, y: full * 0.69))
        shield.line(to: NSPoint(x: full * 0.72, y: full * 0.4))
        shield.curve(to: NSPoint(x: full * 0.5, y: full * 0.2), controlPoint1: NSPoint(x: full * 0.7, y: full * 0.3), controlPoint2: NSPoint(x: full * 0.57, y: full * 0.22))
        shield.curve(to: NSPoint(x: full * 0.28, y: full * 0.4), controlPoint1: NSPoint(x: full * 0.43, y: full * 0.22), controlPoint2: NSPoint(x: full * 0.3, y: full * 0.3))
        shield.line(to: NSPoint(x: full * 0.23, y: full * 0.69)); shield.close()
        NSColor(calibratedRed: 0.36, green: 0.87, blue: 0.68, alpha: 1).setFill(); shield.fill()
        let tick = NSBezierPath(); tick.move(to: NSPoint(x: full * 0.36, y: full * 0.51))
        tick.line(to: NSPoint(x: full * 0.46, y: full * 0.41)); tick.line(to: NSPoint(x: full * 0.66, y: full * 0.62))
        tick.lineWidth = full * 0.065; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
        NSColor(calibratedRed: 0.045, green: 0.14, blue: 0.17, alpha: 1).setStroke(); tick.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
