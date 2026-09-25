// swift-tools-version: 6.0

import PackageDescription
import Foundation

let duplicateSourceExclusions = FileManager.default.fileExists(
    atPath: "Sources/MagSafeWatch/main 2.swift"
) ? ["main 2.swift"] : []

let package = Package(
    name: "MagSafeWatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MagSafeWatch", targets: ["MagSafeWatch"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "MagSafeWatch",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            exclude: duplicateSourceExclusions,
            sources: ["main.swift"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
