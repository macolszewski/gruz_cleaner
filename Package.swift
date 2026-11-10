// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GRUZ",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "GRUZ", targets: ["GRUZ"]),
        .executable(name: "gruz-scan", targets: ["gruz-scan"]),
    ],
    targets: [
        // Read-only: discovers and measures items. Must never depend on CleanerKit.
        .target(
            name: "ScannerKit",
            resources: [.copy("Rules"), .process("Resources")]
        ),
        // The only module allowed to remove data, driven exclusively by the GUI.
        .target(
            name: "CleanerKit",
            dependencies: ["ScannerKit"],
            resources: [.copy("Helpers"), .process("Resources")]
        ),
        // The app's own strings are copied into the .app by scripts/build-app.sh so that
        // SwiftUI resolves them from the main bundle without passing `bundle:` everywhere.
        .executableTarget(
            name: "GRUZ",
            dependencies: ["ScannerKit", "CleanerKit"],
            exclude: ["Resources"]
        ),
        // Report-only CLI; intentionally has no access to CleanerKit.
        .executableTarget(
            name: "gruz-scan",
            dependencies: ["ScannerKit"]
        ),
        .testTarget(name: "ScannerKitTests", dependencies: ["ScannerKit"]),
        .testTarget(name: "CleanerKitTests", dependencies: ["CleanerKit", "ScannerKit"]),
    ]
)
