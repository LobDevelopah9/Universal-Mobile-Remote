// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
        .library(name: "RemoteDiscovery", targets: ["RemoteDiscovery"]),
        .library(name: "RemoteStorage", targets: ["RemoteStorage"]),
        .library(name: "RemoteDrivers", targets: ["RemoteDrivers"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "RemoteCore"),
        .target(
            name: "RemoteDrivers",
            dependencies: [
                "RemoteCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .target(name: "RemoteDiscovery", dependencies: ["RemoteCore", "RemoteDrivers"]),
        .target(name: "RemoteStorage", dependencies: ["RemoteCore"]),
        .testTarget(
            name: "RemoteKitTests",
            dependencies: ["RemoteCore", "RemoteDiscovery", "RemoteStorage", "RemoteDrivers"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
