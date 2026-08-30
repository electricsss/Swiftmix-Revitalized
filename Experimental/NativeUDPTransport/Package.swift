// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "NativeUDPTransportExperiment",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "NativeUDPTransport",
            targets: ["NativeUDPTransport"]
        ),
        .executable(
            name: "swiftmix-udp-capture",
            targets: ["SwiftMixUDPCapture"]
        ),
        .executable(
            name: "native-udp-self-tests",
            targets: ["NativeUDPTransportSelfTests"]
        )
    ],
    dependencies: [
        .package(name: "SwiftMixNominal", path: "../..")
    ],
    targets: [
        .target(
            name: "NativeUDPTransport",
            dependencies: [
                .product(name: "SwiftMixCore", package: "SwiftMixNominal")
            ]
        ),
        .executableTarget(
            name: "SwiftMixUDPCapture",
            dependencies: ["NativeUDPTransport"]
        ),
        .executableTarget(
            name: "NativeUDPTransportSelfTests",
            dependencies: [
                "NativeUDPTransport",
                .product(name: "SwiftMixCore", package: "SwiftMixNominal")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
