// swift-tools-version:6.0
// Warden. Brand strings live ONLY in Sources/GuardCore/Brand.swift and scripts/brand.env.
// Target/module names are generic on purpose so a rename touches just those two files.
import PackageDescription

let package = Package(
    name: "Guard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "App", targets: ["App"]),
        .executable(name: "Hook", targets: ["Hook"]),
        .executable(name: "SelfTest", targets: ["SelfTest"]),
    ],
    targets: [
        // Rules, adapters, shell lexer, storage, IPC, installer. Foundation only (used by the hook CLI).
        .target(name: "GuardCore", path: "Sources/GuardCore"),
        // The hook CLI agents spawn per tool call (installed as `warden-hook`). No AppKit.
        .executableTarget(name: "Hook", dependencies: ["GuardCore"], path: "Sources/Hook"),
        // Menu-bar app.
        .executableTarget(name: "App", dependencies: ["GuardCore"], path: "Sources/App",
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("UserNotifications")]),
        // CLT-only test runner (no XCTest without Xcode). Run via scripts/selftest.
        .executableTarget(name: "SelfTest", dependencies: ["GuardCore"], path: "Sources/SelfTest"),
    ],
    swiftLanguageModes: [.v5]
)
