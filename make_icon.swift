// Renders AppIcon.iconset: a gradient rounded square with crop corners around a camera lens.
// Drawn from plain shapes on purpose: Apple's SF Symbols may not be used in app icons.
import AppKit

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024  // design on a 1024 grid

    // background: macOS icon grid (824pt square, 100pt margin)
    let bg = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let bgPath = NSBezierPath(roundedRect: bg, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.52, blue: 1.00, alpha: 1),
               ending: NSColor(calibratedRed: 0.40, green: 0.20, blue: 0.86, alpha: 1))!.draw(in: bgPath, angle: -90)

    // crop corners (a 16:9-ish frame)
    let frame = NSRect(x: 222 * s, y: 302 * s, width: 580 * s, height: 420 * s)
    let arm = 120 * s
    let corners = NSBezierPath()
    corners.lineWidth = 44 * s
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (x, y, dx, dy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                           (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
        corners.move(to: NSPoint(x: x + dx * arm, y: y))
        corners.line(to: NSPoint(x: x, y: y))
        corners.line(to: NSPoint(x: x, y: y + dy * arm))
    }
    NSColor.white.setStroke()
    corners.stroke()

    // camera lens in the middle
    let c = NSPoint(x: frame.midX, y: frame.midY)
    func circle(_ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s))
    }
    NSColor.white.setFill(); circle(118).fill()
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.30, alpha: 1).setFill(); circle(86).fill()
    NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.95, alpha: 1).setFill(); circle(50).fill()
    NSColor(white: 1, alpha: 0.85).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x + 14 * s, y: c.y + 22 * s, width: 30 * s, height: 30 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
