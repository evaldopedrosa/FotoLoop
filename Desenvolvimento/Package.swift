// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FotoLoop",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FotoLoop", targets: ["FotoLoop"])],
    targets: [
        .executableTarget(name: "FotoLoop"),
        .testTarget(name: "FotoLoopTests", dependencies: ["FotoLoop"])
    ]
)
