// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kith",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KithApp", targets: ["KithApp"]),
        .executable(name: "kith-event", targets: ["KithEvent"]),
        .executable(name: "KithPowerHelper", targets: ["KithPowerHelper"])
    ],
    targets: [
        .target(name: "KithCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "KithEvent", dependencies: ["KithCore"]),
        .executableTarget(name: "KithApp", dependencies: ["KithCore"]),
        .executableTarget(name: "KithPowerHelper", dependencies: ["KithCore"]),
        .testTarget(name: "KithCoreTests", dependencies: ["KithCore"])
    ]
)
