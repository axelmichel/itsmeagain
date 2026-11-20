// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "Providers", targets: ["Providers"]),
        .library(name: "Persistence", targets: ["Persistence"]),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "Providers", dependencies: ["CompanionCore"]),
        .target(name: "Persistence", dependencies: ["CompanionCore"]),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionCore", "Providers", "Persistence"]
        ),
    ]
)
