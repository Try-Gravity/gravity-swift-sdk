// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GravitySDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "GravitySDK", targets: ["GravitySDK"]),
    ],
    targets: [
        .target(
            name: "GravitySDK",
            path: "Sources/GravitySDK"
        ),
        .testTarget(
            name: "GravitySDKTests",
            dependencies: ["GravitySDK"],
            path: "Tests/GravitySDKTests"
        ),
    ]
)
