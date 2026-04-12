// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Macterm",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
    ],
    targets: [
        .target(
            name: "GhosttyKit",
            path: "GhosttyKit",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "Macterm",
            dependencies: [
                "GhosttyKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Macterm",
            exclude: ["Info.plist", "Macterm.entitlements"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "GhosttyKit.xcframework/macos-arm64_x86_64",
                    "-lghostty",
                ]),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("c++"),
            ]
        ),
    ]
)
