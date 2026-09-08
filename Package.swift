// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenithCrownUpdater",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ZenithCrownUpdater", targets: ["ZenithCrownUpdater"])
    ],
    targets: [
        .executableTarget(name: "ZenithCrownUpdater")
    ]
)
