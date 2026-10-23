// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaptopBridgeApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LaptopBridgeApp", targets: ["LaptopBridgeApp"])
    ],
    targets: [
        .executableTarget(name: "LaptopBridgeApp", resources: [.process("Assets")]),
        .testTarget(name: "LaptopBridgeAppTests", dependencies: ["LaptopBridgeApp"])
    ]
)
