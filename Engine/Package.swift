// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MonitorEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MonitorEngine", targets: ["MonitorEngine"]),
        .library(name: "UsageStore", targets: ["UsageStore"]),
        .executable(name: "engine-probe", targets: ["engine-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(name: "SpawnSupport"),
        .target(name: "MonitorEngine", dependencies: ["SpawnSupport"]),
        .target(name: "UsageStore", dependencies: ["MonitorEngine", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "engine-probe", dependencies: ["MonitorEngine", "UsageStore"]),
        .testTarget(
            name: "MonitorEngineTests",
            dependencies: ["MonitorEngine", "UsageStore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
