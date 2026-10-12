// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CableLab",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CableLab", targets: ["CableLab"]),
    ],
    targets: [
        .target(
            name: "CableLabCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .executableTarget(name: "CableLab", dependencies: ["CableLabCore"]),
        .testTarget(name: "CableLabCoreTests", dependencies: ["CableLabCore"]),
    ],
    swiftLanguageModes: [.v5]
)
