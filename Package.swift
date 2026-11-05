// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Burrow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Burrow", targets: ["Burrow"]),
        .executable(name: "burrow-session", targets: ["burrow-session"]),
    ],
    targets: [
        .executableTarget(
            name: "Burrow",
            dependencies: ["BurrowCore"]
        ),
        .target(name: "BurrowCore"),
        .executableTarget(name: "burrow-session"),
        .testTarget(
            name: "BurrowCoreTests",
            dependencies: ["BurrowCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
