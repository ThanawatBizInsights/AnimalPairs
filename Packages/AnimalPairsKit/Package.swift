// swift-tools-version:5.9
// AnimalPairsKit: the UI-independent game engine for Animal Pairs.
// Builds and tests on macOS, iPadOS and Linux (Foundation only).
import PackageDescription

let package = Package(
    name: "AnimalPairsKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AnimalPairsCore", targets: ["AnimalPairsCore"]),
    ],
    targets: [
        .target(name: "AnimalPairsCore"),
        .testTarget(name: "AnimalPairsCoreTests", dependencies: ["AnimalPairsCore"]),
    ]
)
