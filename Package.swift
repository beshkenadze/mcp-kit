// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MCPKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCPKit", targets: ["MCPKit"]),
        .library(name: "MCPKitServer", targets: ["MCPKitServer"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "MCPKit",
            path: ".",
            exclude: ["Tests", "docs", "spec/README.md", "spec/fixtures", "README.md", "Sources/MCPKitServer", "Sources/ExampleHelper"],
            sources: ["Sources/MCPKit"],
            resources: [.copy("spec/agents.json")]
        ),
        .testTarget(name: "MCPKitTests", dependencies: ["MCPKit"]),
        .target(name: "MCPKitServer", dependencies: [.product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "ExampleHelper", dependencies: ["MCPKitServer"]),
        .testTarget(name: "MCPKitServerTests", dependencies: ["MCPKitServer"])
    ],
    swiftLanguageModes: [.v6]
)
