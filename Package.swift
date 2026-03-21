// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "attic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AtticCore", targets: ["AtticCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/tijs/ladder.git", from: "0.3.4"),
    ],
    targets: [
        .target(
            name: "AtticCore",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "LadderKit", package: "ladder"),
            ],
            path: "Sources/AtticCore"
        ),
        .executableTarget(
            name: "AtticCLI",
            dependencies: [
                "AtticCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AtticCLI"
        ),
        .testTarget(
            name: "AtticCoreTests",
            dependencies: ["AtticCore"],
            path: "Tests/AtticCoreTests"
        ),
    ]
)
