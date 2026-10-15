// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwapBot",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AccountsCore"),
        .executableTarget(name: "SwapBot", dependencies: ["AccountsCore"]),
        .testTarget(name: "AccountsCoreTests", dependencies: ["AccountsCore"]),
    ]
)
