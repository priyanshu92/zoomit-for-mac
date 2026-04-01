// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZoomItForMac",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "PlatformServices", targets: ["PlatformServices"]),
        .executable(name: "ZoomItForMacApp", targets: ["ZoomItForMacApp"]),
        .executable(name: "ValidationRunner", targets: ["ValidationRunner"]),
    ],
    targets: [
        .target(
            name: "AppCore"
        ),
        .target(
            name: "PlatformServices",
            dependencies: ["AppCore"]
        ),
        .executableTarget(
            name: "ZoomItForMacApp",
            dependencies: ["AppCore", "PlatformServices"]
        ),
        .executableTarget(
            name: "ValidationRunner",
            dependencies: ["AppCore"]
        ),
    ]
)
