// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fOLDERFUSE",
    platforms: [.macOS(.v15)],
    targets: [
        // Moteur de fusion et traductions, sans interface (testable seul)
        .target(name: "FusionCore"),
        .executableTarget(name: "fOLDERFUSE", dependencies: ["FusionCore"]),
        .testTarget(name: "FusionCoreTests", dependencies: ["FusionCore"]),
    ],
    swiftLanguageModes: [.v5]
)
