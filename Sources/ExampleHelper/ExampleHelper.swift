import MCPKitServer

struct RenderArgs: ToolInput {
    let frame: Int
    let format: Format?
    static let descriptions = ["frame": "Frame number", "format": "Output format"]
}

enum Format: String, ToolInputEnum { case png, jpeg }

@main struct Helper {
    static func main() async throws {
        try await MCPServer(name: "filmcraft", version: "1.0", instructions: "Edits FilmCraft projects.") {
            Tool("render_frame", "Render one frame", input: RenderArgs.self) { args, context in
                await context.progress(0.5, total: 1, message: "Rendering")
                return .text("Rendered \(args.frame)")
            }
            Tool("ping", "Health check") { _ in .text("pong") }
        }.runStdio()
    }
}
