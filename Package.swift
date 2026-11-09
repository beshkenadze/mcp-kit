// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MCPKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MCPKit", targets: ["MCPKit"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .target(
            name: "MCPKit",
            path: ".",
            exclude: ["Tests", "docs", "spec/README.md", "spec/fixtures", "README.md"],
            sources: ["Sources/MCPKit"],
            resources: [.copy("spec/agents.json")]
        ),
        .testTarget(name: "MCPKitTests", dependencies: ["MCPKit"])
    ],
    swiftLanguageModes: [.v6]
)
