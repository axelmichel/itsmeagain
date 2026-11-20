// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "Providers", targets: ["Providers"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "Routing", targets: ["Routing"]),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "Providers", dependencies: ["CompanionCore"]),
        .target(name: "Routing", dependencies: ["CompanionCore"]),
        .target(name: "Persistence", dependencies: ["CompanionCore", "Routing"]),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionCore", "Providers", "Persistence", "Routing"]
        ),
    ]
)
