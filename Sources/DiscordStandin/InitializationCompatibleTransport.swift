import Foundation
import Logging
import MCP

/// Remove when the SDK accepts object-valued experimental client capabilities.
/// Swift MCP SDK 0.12.1 decodes these as [String: String], contrary to the schema.
/// DiscordStandin does not implement any experimental client capabilities.
actor InitializationCompatibleTransport: Transport {
  private let base = StdioTransport()

  nonisolated var logger: Logger { base.logger }

  func connect() async throws {
    try await base.connect()
  }

  func disconnect() async {
    await base.disconnect()
  }

  func send(_ data: Data) async throws {
    try await base.send(data)
  }

  func receive() -> AsyncThrowingStream<Data, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for try await data in await base.receive() {
            try Task.checkCancellation()
            continuation.yield(Self.normalizeInitialization(data))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private static func normalizeInitialization(_ data: Data) -> Data {
    guard var request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      request["method"] as? String == "initialize",
      var params = request["params"] as? [String: Any],
      var capabilities = params["capabilities"] as? [String: Any],
      capabilities["experimental"] is [String: Any]
    else {
      return data
    }

    // Ignore unsupported extensions, while leaving every other field and all
    // malformed envelopes to the SDK's normal decoding and validation.
    capabilities.removeValue(forKey: "experimental")
    params["capabilities"] = capabilities
    request["params"] = params
    return (try? JSONSerialization.data(withJSONObject: request)) ?? data
  }
}
