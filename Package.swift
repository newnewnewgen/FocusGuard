// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FocusGuard",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "FocusGuardCore", targets: ["FocusGuardCore"]),
        .executable(name: "focusguardd", targets: ["focusguardd"]),
        .executable(name: "FocusGuard", targets: ["FocusGuard"]),
    ],
    targets: [
        .target(name: "FocusGuardCore"),
        .executableTarget(name: "focusguardd", dependencies: ["FocusGuardCore"]),
        .executableTarget(name: "FocusGuard", dependencies: ["FocusGuardCore"], exclude: ["Info.plist"]),
        .testTarget(name: "FocusGuardCoreTests", dependencies: ["FocusGuardCore"]),
    ]
)
