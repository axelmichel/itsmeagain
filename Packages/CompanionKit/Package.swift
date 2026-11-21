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
        .library(name: "AppleIntelligence", targets: ["AppleIntelligence"]),
        .library(name: "Tools", targets: ["Tools"]),
        .library(name: "Knowledge", targets: ["Knowledge"]),
        .library(name: "Commands", targets: ["Commands"]),
        .library(name: "Automation", targets: ["Automation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.14.0"),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "Providers", dependencies: ["CompanionCore"]),
        .target(name: "Routing", dependencies: ["CompanionCore"]),
        .target(name: "AppleIntelligence", dependencies: ["CompanionCore", "Routing"]),
        .target(name: "Tools", dependencies: ["CompanionCore", "SwiftSoup"]),
        .target(name: "Knowledge", dependencies: ["CompanionCore", "Tools"]),
        .target(name: "Commands", dependencies: ["CompanionCore", "Routing"]),
        .target(name: "Automation"),
        .target(name: "Persistence", dependencies: ["CompanionCore", "Routing", "Tools", "Automation"]),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionCore", "Providers", "Persistence", "Routing", "AppleIntelligence", "Tools", "Knowledge", "Commands", "Automation"]
        ),
    ]
)
