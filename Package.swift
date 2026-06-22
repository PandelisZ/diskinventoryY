// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DiskInventoryY",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DiskInventoryY", targets: ["DiskInventoryY"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "DiskInventoryY",
            dependencies: [],
            path: "Sources"
        )
    ]
)
