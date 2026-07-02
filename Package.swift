// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sort",
    platforms: [
        // The modern Vision Swift API (DetectFaceRectanglesRequest.perform, ImageRequestHandler)
        // and the latest Core ML compute-plan APIs require macOS 15+.
        .macOS(.v15)
    ],
    products: [
        .library(name: "SortKit", targets: ["SortKit"]),
        .executable(name: "sort", targets: ["sort"]),
        .executable(name: "sort-app", targets: ["SortApp"]),
    ],
    dependencies: [
        // D5: GRDB.swift — WAL DatabasePool, ValueObservation, migrations.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SortKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "sort",
            dependencies: [
                "SortKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "SortApp",
            dependencies: ["SortKit"]
        ),
        .testTarget(
            name: "SortKitTests",
            dependencies: ["SortKit"]
        ),
    ]
)
