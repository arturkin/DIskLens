// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskLensCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DiskLensCore", targets: ["DiskLensCore"])
    ],
    targets: [
        .target(
            name: "DiskLensCore"
        ),
        .testTarget(
            name: "DiskLensCoreTests",
            dependencies: ["DiskLensCore"]
        )
    ]
)
