import DiscordStandinCore
import MCP

enum MCPServerRuntime {
  static func run() async throws {
    let router = DiscordToolRouter()
    let server = Server(
      name: "DiscordStandin",
      version: "0.1.0",
      capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: DiscordToolRouter.tools)
    }
    await server.withMethodHandler(CallTool.self) { parameters in
      await router.call(name: parameters.name, arguments: parameters.arguments)
    }

    let transport = InitializationCompatibleTransport()
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
  }
}
