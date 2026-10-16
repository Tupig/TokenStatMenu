// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenStatMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenStatMenu", targets: ["TokenStatMenu"])],
    targets: [
        .target(name: "TokenStatCore"),
        .executableTarget(name: "TokenStatMenu", dependencies: ["TokenStatCore"]),
        .executableTarget(name: "TokenStatCoreChecks", dependencies: ["TokenStatCore"], path: "Tests/TokenStatCoreTests")
    ]
)
