// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FocusGuard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FocusGuardCore", targets: ["FocusGuardCore"]),
        .executable(name: "focusguardd", targets: ["focusguardd"]),
    ],
    targets: [
        .target(name: "FocusGuardCore"),
        .executableTarget(name: "focusguardd", dependencies: ["FocusGuardCore"]),
        .testTarget(name: "FocusGuardCoreTests", dependencies: ["FocusGuardCore"]),
    ]
)
