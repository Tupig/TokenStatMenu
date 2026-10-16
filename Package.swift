// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenStatMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenStatMenu", targets: ["TokenStatMenu"])],
    dependencies: [.package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6")],
    targets: [
        .target(name: "TokenStatCore"),
        .executableTarget(name: "TokenStatMenu", dependencies: ["TokenStatCore"]),
        .executableTarget(name: "TokenStatCoreChecks", dependencies: ["TokenStatCore"], path: "Tests/TokenStatCoreTests"),
        .testTarget(name: "TokenStatUITests", dependencies: ["TokenStatMenu", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")], path: "Tests/TokenStatUITests", exclude: ["__Snapshots__"])
    ]
)
