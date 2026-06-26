// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PMM",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "PMMApp", targets: ["PMMApp"]),
        .executable(name: "pmmctl", targets: ["pmmctl"]),
        .library(name: "PMMCore", targets: ["PMMCore"]),
    ],
    targets: [
        .target(name: "PMMCore"),
        .executableTarget(
            name: "PMMApp",
            dependencies: ["PMMCore"]
        ),
        .executableTarget(
            name: "pmmctl",
            dependencies: ["PMMCore"]
        ),
        .testTarget(
            name: "PMMCoreTests",
            dependencies: ["PMMCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
