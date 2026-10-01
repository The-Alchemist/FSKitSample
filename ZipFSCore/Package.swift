// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ZipFSCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "ZipFSCore", targets: ["ZipFSCore"]),
        .executable(name: "zipfs", targets: ["zipfs"]),
        .executable(name: "ZipFSCoreCheck", targets: ["ZipFSCoreCheck"]),
    ],
    dependencies: [
        .package(path: "Vendor/PLzmaSDK"),
    ],
    targets: [
        .target(
            name: "ZipFSCore",
            dependencies: [
                .product(name: "PLzmaSDK", package: "PLzmaSDK"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "zipfs",
            dependencies: ["ZipFSCore"]
        ),
        .executableTarget(
            name: "ZipFSCoreCheck",
            dependencies: ["ZipFSCore"],
            resources: [
                .copy("Fixtures"),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
    ]
)
