// swift-tools-version: 5.9
import PackageDescription

func linuxOnly<T>(_ items: [T]) -> [T] {
    #if os(Linux)
    return items
    #else
    return []
    #endif
}

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
    // SHA-256 for PII hashing on non-Apple platforms (Linux CI); Apple
    // platforms use CryptoKit directly. The manifest is host-compiled, so
    // gating on os(Linux) keeps swift-crypto entirely out of the dependency
    // graph that Apple-platform consumers resolve.
    dependencies: linuxOnly(
        [.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0")]
    ),
    targets: [
        .target(
            name: "GravitySDK",
            dependencies: linuxOnly(
                [.product(name: "Crypto", package: "swift-crypto")]
            ),
            path: "Sources/GravitySDK"
        ),
        .testTarget(
            name: "GravitySDKTests",
            dependencies: ["GravitySDK"],
            path: "Tests/GravitySDKTests",
            resources: [
                .copy("SpecFixtures")
            ]
        ),
    ]
)
