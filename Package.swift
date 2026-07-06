// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PMM",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "PMMApp", targets: ["PMMApp"]),
        .executable(name: "PMMMenuBar", targets: ["PMMMenuBar"]),
        .executable(name: "pmmctl", targets: ["pmmctl"]),
        .library(name: "PMMCore", targets: ["PMMCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mxcl/AppUpdater.git", from: "2.1.1"),
    ],
    targets: [
        .target(name: "PMMCore"),
        .executableTarget(
            name: "PMMApp",
            dependencies: ["PMMCore"],
            resources: [.copy("Resources/AppIcon.icon")]
        ),
        .executableTarget(
            name: "PMMMenuBar",
            dependencies: ["PMMCore", "AppUpdater"]
        ),
        .executableTarget(
            name: "pmmctl",
            dependencies: ["PMMCore"]
        ),
        .testTarget(
            name: "PMMCoreTests",
            dependencies: ["PMMCore"]
        ),
        .testTarget(
            name: "PMMAppTests",
            dependencies: ["PMMApp"]
        ),
        .testTarget(
            name: "PMMMenuBarTests",
            dependencies: ["PMMMenuBar"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
