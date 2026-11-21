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
        .library(name: "PersonalData", targets: ["PersonalData"]),
        .library(name: "Mail", targets: ["Mail"]),
        .library(name: "Memory", targets: ["Memory"]),
        .library(name: "Obsidian", targets: ["Obsidian"]),
        .library(name: "News", targets: ["News"]),
        .library(name: "Jira", targets: ["Jira"]),
        .library(name: "Weather", targets: ["Weather"]),
        .library(name: "Learning", targets: ["Learning"]),
        .library(name: "MCP", targets: ["MCP"]),
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
        .target(name: "PersonalData", dependencies: ["CompanionCore", "Tools"]),
        .target(name: "Mail", dependencies: ["CompanionCore", "Tools"]),
        .target(name: "Memory", dependencies: ["CompanionCore", "Tools"]),
        .target(name: "Obsidian", dependencies: ["CompanionCore", "Tools"]),
        .target(name: "News", dependencies: ["CompanionCore", "Tools", "SwiftSoup"]),
        .target(name: "Jira", dependencies: ["CompanionCore", "Tools"]),
        .target(name: "Weather"),
        .target(name: "Learning", dependencies: ["CompanionCore"]),
        .target(name: "MCP", dependencies: ["CompanionCore", "Tools"]),
        .target(name: "Persistence", dependencies: ["CompanionCore", "Routing", "Tools", "Automation", "PersonalData", "Mail", "Obsidian", "Jira", "Learning"]),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionCore", "Providers", "Persistence", "Routing", "AppleIntelligence", "Tools", "Knowledge", "Commands", "Automation", "PersonalData", "Mail", "Memory", "Obsidian", "News", "Jira", "Weather", "Learning", "MCP"]
        ),
    ]
)
