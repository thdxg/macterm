// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Macterm",
    platforms: [
        .macOS("26.0"),
    ],
    dependencies: [],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Macterm",
            dependencies: [
                "GhosttyKit",
            ],
            path: "Macterm",
            exclude: ["Info.plist", "Macterm.entitlements"],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
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
        .testTarget(
            name: "MactermTests",
            dependencies: ["Macterm"],
            path: "MactermTests"
        ),
    ]
)
