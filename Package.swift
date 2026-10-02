// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AnkiNotch",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AnkiNotchKit", targets: ["AnkiNotchKit"]),
        .executable(name: "AnkiNotch", targets: ["AnkiNotch"]),
    ],
    targets: [
        .target(name: "AnkiNotchKit"),
        .executableTarget(name: "AnkiNotch", dependencies: ["AnkiNotchKit"]),
        .testTarget(name: "AnkiNotchKitTests", dependencies: ["AnkiNotchKit"]),
    ]
)
