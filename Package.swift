// swift-tools-version:5.10
// NetScope Pro — native macOS network analysis, monitoring and diagnostics.
//
// Targets:
//  - NetScopeCore   : platform-independent logic (parsers, analysis engines, storage,
//                     router adapters, reporting). Builds and is unit-tested on macOS and Linux.
//  - NetScopeSystem : macOS-only platform services (CoreWLAN, SystemConfiguration,
//                     Network.framework, Keychain, notifications, PDF).
//  - NetScopePro    : SwiftUI application (macOS only).
import PackageDescription

let package = Package(
    name: "NetScopePro",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NetScopeCore", targets: ["NetScopeCore"]),
        .library(name: "NetScopeSystem", targets: ["NetScopeSystem"]),
        .executable(name: "NetScopePro", targets: ["NetScopePro"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(
            name: "NetScopeCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
            path: "Sources/NetScopeCore"
        ),
        .target(
            name: "NetScopeSystem",
            dependencies: ["NetScopeCore"],
            path: "Sources/NetScopeSystem"
        ),
        .executableTarget(
            name: "NetScopePro",
            dependencies: ["NetScopeCore", "NetScopeSystem"],
            path: "Sources/NetScopeApp",
            exclude: ["Resources/Info.plist", "Resources/NetScopePro.entitlements"]
        ),
        .testTarget(
            name: "NetScopeCoreTests",
            dependencies: ["NetScopeCore"],
            path: "Tests/NetScopeCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
