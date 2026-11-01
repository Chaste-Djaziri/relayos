// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LaptopBridgeApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LaptopBridgeApp", targets: ["LaptopBridgeApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .executableTarget(
            name: "LaptopBridgeApp",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            resources: [.process("Assets")]
        ),
        .testTarget(name: "LaptopBridgeAppTests", dependencies: ["LaptopBridgeApp"])
    ],
    swiftLanguageVersions: [.v5]
)
