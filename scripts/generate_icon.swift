import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let iconsetURL = outputDirectory.appendingPathComponent("MagSafeWatch.iconset", isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let outputs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in outputs {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    drawIcon(size: size)
    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fatalError("Could not render \(filename)")
    }

    try png.write(to: iconsetURL.appendingPathComponent(filename))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = [
    "-c",
    "icns",
    iconsetURL.path,
    "-o",
    outputDirectory.appendingPathComponent("MagSafeWatch.icns").path
]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed")
}

try? fileManager.removeItem(at: iconsetURL)

func drawIcon(size: CGFloat) {
    let scale = size / 1024
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    func r(_ value: CGFloat) -> CGFloat { value * scale }
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: r(x), y: r(y))
    }
    func scaledRect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: r(x), y: r(y), width: r(width), height: r(height))
    }

    let background = NSBezierPath(roundedRect: scaledRect(64, 64, 896, 896), xRadius: r(210), yRadius: r(210))
    NSColor(red: 0.05, green: 0.08, blue: 0.17, alpha: 1).setFill()
    background.fill()

    let blueOverlay = NSBezierPath(roundedRect: scaledRect(64, 64, 896, 896), xRadius: r(210), yRadius: r(210))
    NSColor(red: 0.08, green: 0.18, blue: 0.43, alpha: 0.65).setFill()
    blueOverlay.fill()

    strokeArc(center: point(242, 314), radius: r(190), start: 24, end: 156, color: NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.44), width: r(22))
    strokeArc(center: point(242, 360), radius: r(122), start: 28, end: 152, color: NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.78), width: r(28))

    let alertRing = NSBezierPath(ovalIn: scaledRect(700, 160, 164, 164))
    NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1).setStroke()
    alertRing.lineWidth = r(34)
    alertRing.stroke()
    NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1).setFill()
    NSBezierPath(ovalIn: scaledRect(760, 220, 44, 44)).fill()

    let laptop = NSBezierPath(roundedRect: scaledRect(246, 503, 532, 215), xRadius: r(65), yRadius: r(65))
    laptop.lineWidth = r(38)
    NSColor(red: 0.9, green: 0.91, blue: 0.93, alpha: 1).setStroke()
    laptop.stroke()

    let base = NSBezierPath()
    base.move(to: point(196, 718))
    base.line(to: point(828, 718))
    base.line(to: point(776, 796))
    base.line(to: point(248, 796))
    base.close()
    NSColor(red: 0.9, green: 0.91, blue: 0.93, alpha: 1).setFill()
    base.fill()

    let bolt = NSBezierPath()
    bolt.move(to: point(456, 284))
    bolt.line(to: point(356, 524))
    bolt.line(to: point(470, 524))
    bolt.line(to: point(418, 740))
    bolt.line(to: point(648, 428))
    bolt.line(to: point(520, 428))
    bolt.line(to: point(592, 284))
    bolt.close()
    NSColor(red: 0.98, green: 0.62, blue: 0.08, alpha: 1).setFill()
    bolt.fill()

    let connector = NSBezierPath(roundedRect: scaledRect(108, 384, 126, 104), xRadius: r(38), yRadius: r(38))
    NSColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1).setFill()
    connector.fill()

    let cable = NSBezierPath()
    cable.move(to: point(194, 436))
    cable.line(to: point(304, 436))
    cable.lineCapStyle = .round
    cable.lineWidth = r(42)
    NSColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1).setStroke()
    cable.stroke()

    let gap = NSBezierPath()
    gap.move(to: point(304, 436))
    gap.line(to: point(366, 436))
    gap.lineCapStyle = .round
    gap.lineWidth = r(30)
    NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1).setStroke()
    gap.stroke()
}

func strokeArc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
    path.lineCapStyle = .round
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}
