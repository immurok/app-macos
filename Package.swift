// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "immurokApp",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "FirmwareUpdateKit",
            path: "FirmwareUpdateKit"
        ),
        .executableTarget(
            name: "immurokApp",
            dependencies: ["FirmwareUpdateKit"],
            path: "Sources"
        ),
        .executableTarget(
            name: "imk",
            path: "CLISources"
        ),
        .testTarget(
            name: "FirmwareUpdateKitTests",
            dependencies: ["FirmwareUpdateKit"],
            path: "Tests/FirmwareUpdateKitTests"
        )
    ]
)
