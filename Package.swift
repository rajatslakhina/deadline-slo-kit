// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "deadline-slo-kit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DeadlineSLO", targets: ["DeadlineSLO"])
    ],
    targets: [
        .target(name: "DeadlineSLO"),
        .testTarget(
            name: "DeadlineSLOTests",
            dependencies: ["DeadlineSLO"]
        ),
    ]
)
