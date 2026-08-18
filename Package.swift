// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MagSafeWatch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MagSafeWatch", targets: ["MagSafeWatch"])
    ],
    targets: [
        .executableTarget(
            name: "MagSafeWatch",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
