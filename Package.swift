// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SwiftMixNominal",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwiftMixCore", targets: ["SwiftMixCore"]),
        .executable(name: "SwiftMixNominal", targets: ["SwiftMixNominal"])
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
                .linkedFramework("ServiceManagement")
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
