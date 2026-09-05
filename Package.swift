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
        .target(
            name: "AuthInjectionKit",
            path: "AuthInjectionKit"
        ),
        .executableTarget(
            name: "immurokApp",
            dependencies: ["FirmwareUpdateKit", "AuthInjectionKit"],
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
        ),
        .testTarget(
            name: "AuthInjectionKitTests",
            dependencies: ["AuthInjectionKit"],
            path: "Tests/AuthInjectionKitTests"
        ),
        .testTarget(
            name: "LocalizationTests",
            dependencies: ["immurokApp"],
            path: "Tests/LocalizationTests"
        ),
        .testTarget(
            name: "PamMacTests",
            dependencies: ["immurokApp"],
            path: "Tests/PamMacTests"
        )
    ]
)
