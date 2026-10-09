// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TransitHub",
    platforms: [.iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        .target(
            name: "TransitHub",
            dependencies: [
                "ZIPFoundation",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/TransitHub",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TransitHubTests",
            dependencies: ["TransitHub"],
            path: "Tests/TransitHubTests"
        ),
    ]
)
