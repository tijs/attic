// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "attic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtticCore", targets: ["AtticCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/adam-fowler/aws-signer-v4.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(path: "../ladder"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "AtticCore",
            dependencies: [
                .product(name: "AWSSigner", package: "aws-signer-v4"),
                .product(name: "LadderKit", package: "ladder"),
            ],
            path: "Sources/AtticCore"
        ),
        .executableTarget(
            name: "AtticCLI",
            dependencies: [
                "AtticCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/AtticCLI",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "AtticCoreTests",
            dependencies: ["AtticCore"],
            path: "Tests/AtticCoreTests"
        ),
    ]
)
