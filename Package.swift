// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftMixNominal",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwiftMixCore", targets: ["SwiftMixCore"]),
        .executable(name: "SwiftMixNominal", targets: ["SwiftMixNominal"]),
        .executable(name: "SwiftMixFaderProbe", targets: ["SwiftMixFaderProbe"]),
        .executable(name: "SwiftMixCaptureReplay", targets: ["SwiftMixCaptureReplay"])
    ],
    targets: [
        .target(
            name: "SwiftMixCore",
            path: "Sources/SwiftMixCore"
        ),
        .executableTarget(
            name: "SwiftMixNominal",
            dependencies: ["SwiftMixCore"],
            path: "Sources/SwiftMixNominal",
            linkerSettings: [
                .linkedFramework("CoreMIDI"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "SwiftMixFaderProbe",
            dependencies: ["SwiftMixCore"],
            path: "Sources/SwiftMixFaderProbe",
            linkerSettings: [
                .linkedFramework("CoreMIDI")
            ]
        ),
        .executableTarget(
            name: "SwiftMixCaptureReplay",
            dependencies: ["SwiftMixCore"],
            path: "Sources/SwiftMixCaptureReplay",
            linkerSettings: [
                .linkedFramework("CoreMIDI")
            ]
        ),
        .executableTarget(
            name: "SwiftMixCoreSelfTests",
            dependencies: ["SwiftMixCore"],
            path: "Tests/SwiftMixCoreSelfTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
