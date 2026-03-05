// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "immurokApp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "immurokApp",
            path: "Sources"
        ),
        .executableTarget(
            name: "imk",
            path: "CLISources"
        )
    ]
)
