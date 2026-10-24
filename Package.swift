// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwapBot",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "SwapBot"),
    ]
)
