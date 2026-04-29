// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ContextBuddy",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ContextBuddyCore", targets: ["ContextBuddyCore"]),
        .executable(name: "ContextBuddy", targets: ["ContextBuddyApp"]),
    ],
    targets: [
        .target(
            name: "ContextBuddyCore",
            path: "Sources/ContextBuddyCore"
        ),
        .executableTarget(
            name: "ContextBuddyApp",
            dependencies: ["ContextBuddyCore"],
            path: "Sources/ContextBuddyApp"
        ),
        .testTarget(
            name: "ContextBuddyCoreTests",
            dependencies: ["ContextBuddyCore"],
            path: "Tests/ContextBuddyCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
