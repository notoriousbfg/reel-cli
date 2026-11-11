// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "reel",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "reel", targets: ["reel"]),
        .library(name: "ReelKit", targets: ["ReelKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "ReelKit"),
        .executableTarget(
            name: "reel",
            dependencies: [
                "ReelKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "ReelKitTests", dependencies: ["ReelKit"]),
    ],
    swiftLanguageModes: [.v5]
)
