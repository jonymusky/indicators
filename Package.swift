// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Indicators",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Indicators", targets: ["Indicators"]),
        .executable(name: "indicators-cli", targets: ["IndicatorsCLI"]),
        .library(name: "IndicatorsCore", targets: ["IndicatorsCore"]),
    ],
    targets: [
        .target(name: "IndicatorsCore", path: "Sources/IndicatorsCore"),
        .executableTarget(
            name: "Indicators",
            dependencies: ["IndicatorsCore"],
            path: "Sources/Indicators"
        ),
        .executableTarget(
            name: "IndicatorsCLI",
            dependencies: ["IndicatorsCore"],
            path: "Sources/IndicatorsCLI"
        ),
        .testTarget(
            name: "IndicatorsCoreTests",
            dependencies: ["IndicatorsCore"],
            path: "Tests/IndicatorsCoreTests"
        ),
    ]
)
