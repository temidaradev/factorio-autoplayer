// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FactorioAutoplayer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "factorio-player", targets: ["FactorioPlayer"])
    ],
    targets: [
        .executableTarget(name: "FactorioPlayer"),
        .testTarget(name: "FactorioPlayerTests", dependencies: ["FactorioPlayer"])
    ]
)
