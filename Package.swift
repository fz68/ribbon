// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ribbon",
    platforms: [.macOS("13.0")],
    targets: [
        .target(
            name: "RibbonBridge",
            path: "Sources/RibbonBridge",
            publicHeadersPath: "include"
        ),
        .target(
            name: "RibbonCore",
            dependencies: ["RibbonBridge"],
            path: "Sources",
            exclude: ["App", "RibbonBridge"]
        ),
        .executableTarget(
            name: "Ribbon",
            dependencies: ["RibbonCore"],
            path: "Sources/App"
        ),
        .testTarget(
            name: "RibbonTests",
            dependencies: ["RibbonCore"],
            path: "Tests"
        ),
    ]
)
