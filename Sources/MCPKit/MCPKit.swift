import Foundation
import os

public actor MCPKit {
    let integration: MCPIntegration
    let environment: MCPEnvironment
    let logger = Logger(subsystem: "mcp-kit", category: "integration")

    public init(_ integration: MCPIntegration, environment: MCPEnvironment = .live) {
        self.integration = integration
        self.environment = environment
    }

    public func status() -> [AgentID: AgentStatus] {
        do {
            return try AgentRegistry.load().mapValues { $0.isDetected(in: environment) ? .disconnected : .agentNotFound }
        } catch {
            return Dictionary(uniqueKeysWithValues: AgentID.allCases.map { ($0, .unavailable(error.localizedDescription)) })
        }
    }
}
