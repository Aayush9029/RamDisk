// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RamDiskKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RamDiskCore", targets: ["RamDiskCore"]),
        .library(name: "RamDiskEngine", targets: ["RamDiskEngine"]),
    ],
    targets: [
        .target(name: "RamDiskCore"),
        .target(name: "RamDiskEngine", dependencies: ["RamDiskCore"]),
        .testTarget(name: "RamDiskEngineTests", dependencies: ["RamDiskEngine"]),
    ]
)
