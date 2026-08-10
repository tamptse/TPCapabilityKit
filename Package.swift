// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "TPCapabilityKit",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "TPCapabilityKit",
            targets: ["TPCapabilityKit"],
        )
    ],
    targets: [
        .target(
            name: "TPCapabilityKit",
            path: "Sources/TPCapabilityKit",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TPCapabilityKitBridge",
            dependencies: ["TPCapabilityKit"],
            path: "Sources/TPCapabilityKitBridge",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TPCapabilityKitSample",
            dependencies: ["TPCapabilityKit", "TPCapabilityKitBridge"],
            path: "Sources/TPCapabilityKitSample",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "TPCapabilityKitTests",
            dependencies: ["TPCapabilityKit", "TPCapabilityKitBridge", "TPCapabilityKitSample"],
            path: "Tests/TPCapabilityKitTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
