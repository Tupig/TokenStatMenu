// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenStatMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenStatMenu", targets: ["TokenStatMenu"])],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
        // 1.7.x switches package identities across toolchains, creating
        // duplicate IssueReporting targets on older SwiftPM. Use one graph.
        .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.11.0"),
    ],
    targets: [
        .target(name: "TokenStatCore"),
        // Shared between the menu-bar app and its embedded widget extension.
        // Kept dependency-free of WidgetKit so both processes can link it.
        .target(name: "TokenStatWidgetShared"),
        .executableTarget(name: "TokenStatMenu", dependencies: ["TokenStatCore", "TokenStatWidgetShared"]),
        .executableTarget(name: "TokenStatCoreChecks", dependencies: ["TokenStatCore"], path: "Tests/TokenStatCoreTests",
                          swiftSettings: [.define("TOKENSTAT_BP38_C01"), .define("TOKENSTAT_BP38_C02"), .define("TOKENSTAT_BP38_C03")]),
        // BP38 C01/C02/C03 conditioning tests are guarded by these flags. They
        // must be enabled here: the product already implements the new
        // semantics, so leaving the flags undefined would silently skip those
        // checks and let older fallback assertions fail instead.
        .testTarget(name: "TokenStatUITests", dependencies: ["TokenStatMenu", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")], path: "Tests/TokenStatUITests", exclude: ["__Snapshots__"],
                    swiftSettings: [.define("TOKENSTAT_BP38_C01"), .define("TOKENSTAT_BP38_C02"), .define("TOKENSTAT_BP38_C03")]),
        // Pure-logic coverage for the shared widget protocol: codec round
        // trips, rejection cases, and container-unavailable degradation.
        .testTarget(name: "TokenStatWidgetSharedTests",
                    dependencies: ["TokenStatWidgetShared", "TokenStatMenu"]),
        // Development-only widget probe. It is not a product and is not linked
        // into the menu-bar executable. The AppKit host and WidgetKit extension
        // stay in the generated Xcode project.
        .target(name: "TokenStatDevWidgetShared", path: "Sources/TokenStatDevWidgetShared"),
        .testTarget(name: "TokenStatDevWidgetSharedTests",
                    dependencies: ["TokenStatDevWidgetShared"])
    ]
)
