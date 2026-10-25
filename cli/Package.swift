// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wipe",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "wipe", path: "Sources/wipe")
    ]
)
