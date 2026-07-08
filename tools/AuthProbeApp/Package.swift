// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AuthProbeApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "AuthProbeApp", path: "Sources/AuthProbeApp")
    ]
)
