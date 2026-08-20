import AppKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 2 else {
    fatalError("Usage: swift generate_icon.swift <source.svg> <output-directory>")
}

let sourceURL = URL(fileURLWithPath: String(arguments[arguments.startIndex]))
let outputDirectory = URL(fileURLWithPath: String(arguments[arguments.index(after: arguments.startIndex)]))
let iconsetURL = outputDirectory.appendingPathComponent("MagSafeWatch.iconset", isDirectory: true)
let fileManager = FileManager.default

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconOutputs: [(String, CGFloat)] = [
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

for (filename, size) in iconOutputs {
    let pngURL = try renderSVG(sourceURL, size: Int(size), in: iconsetURL)
    let destinationURL = iconsetURL.appendingPathComponent(filename)
    try fileManager.moveItem(at: pngURL, to: destinationURL)
}

try run(
    executable: "/usr/bin/iconutil",
    arguments: [
        "-c",
        "icns",
        iconsetURL.path,
        "-o",
        outputDirectory.appendingPathComponent("MagSafeWatch.icns").path
    ]
)

let menuSourceURL = try renderSVG(sourceURL, size: 128, in: outputDirectory)
let menuIconURL = outputDirectory.appendingPathComponent("MagSafeWatchMenuBar.png")
try createTemplateMenuIcon(from: menuSourceURL, to: menuIconURL)
try? fileManager.removeItem(at: menuSourceURL)
try? fileManager.removeItem(at: iconsetURL)

func renderSVG(_ sourceURL: URL, size: Int, in outputDirectory: URL) throws -> URL {
    try run(
        executable: "/usr/bin/qlmanage",
        arguments: [
            "-t",
            "-s",
            String(size),
            "-o",
            outputDirectory.path,
            sourceURL.path
        ]
    )

    let generatedURL = outputDirectory.appendingPathComponent(sourceURL.lastPathComponent + ".png")
    guard fileManager.fileExists(atPath: generatedURL.path) else {
        fatalError("Quick Look did not render \(sourceURL.lastPathComponent)")
    }
    return generatedURL
}

func createTemplateMenuIcon(from sourceURL: URL, to outputURL: URL) throws {
    guard
        let sourceImage = NSImage(contentsOf: sourceURL),
        let resized = sourceImage.resized(to: NSSize(width: 44, height: 44)),
        let tiff = resized.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else {
        fatalError("Could not read rendered menu icon")
    }

    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: bitmap.pixelsWide,
        pixelsHigh: bitmap.pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not create menu icon bitmap")
    }

    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            let color = bitmap.colorAt(x: x, y: y) ?? .white
            let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
            let alpha: CGFloat

            if brightness > 0.93 {
                alpha = 0
            } else if brightness < 0.18 {
                alpha = 1
            } else {
                alpha = min(1, max(0, (0.93 - brightness) / 0.75))
            }

            output.setColor(NSColor(deviceWhite: 0, alpha: alpha), atX: x, y: y)
        }
    }

    guard let png = output.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode menu icon PNG")
    }
    try png.write(to: outputURL)
}

func run(executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        fatalError("\(executable) failed with exit code \(process.terminationStatus)")
    }
}

extension NSImage {
    func resized(to size: NSSize) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        image.unlockFocus()
        return image
    }
}
