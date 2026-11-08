// swift-tools-version: 6.0
import PackageDescription

let language: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "ChargeKeeper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Shared", swiftSettings: language),
        .executableTarget(name: "ChargeKeeper", dependencies: ["Shared"], swiftSettings: language),
        .executableTarget(name: "ChargeKeeperService", dependencies: ["Shared"], swiftSettings: language),
        .testTarget(name: "SharedTests", dependencies: ["Shared"], swiftSettings: language),
    ]
)
