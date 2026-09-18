// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftMixNominal",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .library(name: "SwiftMixCore", targets: ["SwiftMixCore"]),
        .library(name: "SwiftMixNativeUDP", targets: ["SwiftMixNativeUDP"]),
        .executable(name: "SwiftMixNominal", targets: ["SwiftMixNominal"]),
        .executable(name: "SwiftMixFaderProbe", targets: ["SwiftMixFaderProbe"]),
        .executable(name: "SwiftMixCaptureReplay", targets: ["SwiftMixCaptureReplay"]),
        .executable(name: "SwiftMixSineWave", targets: ["SwiftMixSineWave"]),
        .executable(name: "SwiftMixNativeSineWave", targets: ["SwiftMixNativeSineWave"])
    ],
    targets: [
        .target(
            name: "SwiftMixCore",
            path: "Sources/SwiftMixCore"
        ),
        .target(
            name: "SwiftMixNativeUDP",
            dependencies: ["SwiftMixCore"],
            path: "Sources/SwiftMixNativeUDP"
        ),
        .executableTarget(
            name: "SwiftMixNominal",
            dependencies: ["SwiftMixCore", "SwiftMixNativeUDP"],
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
            name: "SwiftMixSineWave",
            dependencies: ["SwiftMixCore"],
            path: "Sources/SwiftMixSineWave",
            linkerSettings: [
                .linkedFramework("CoreMIDI")
            ]
        ),
        .executableTarget(
            name: "SwiftMixNativeSineWave",
            dependencies: ["SwiftMixCore", "SwiftMixNativeUDP"],
            path: "Sources/SwiftMixNativeSineWave"
        ),
        .executableTarget(
            name: "SwiftMixCoreSelfTests",
            dependencies: ["SwiftMixCore", "SwiftMixNativeUDP"],
            path: "Tests/SwiftMixCoreSelfTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
