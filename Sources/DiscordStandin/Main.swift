import DiscordStandinCore
import Dispatch
import Foundation

@main
enum DiscordStandinMain {
  static func main() {
    let command = CommandLine.arguments.dropFirst().first ?? "help"
    switch command {
    case "login":
      MainActor.assumeIsolated {
        LoginApplication.run()
      }
    case "help", "--help", "-h":
      print(help)
    case "server", "status", "logout":
      runAsync(command)
    default:
      writeError("DiscordStandin: Unknown command. Run DiscordStandin help.\n")
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func runAsync(_ command: String) -> Never {
    Task {
      do {
        switch command {
        case "server":
          try await MCPServerRuntime.run()
        case "status":
          let status = await DiscordOperations().sessionStatus()
          try writeJSON(status)
        case "logout":
          try DiscordOperations().logout()
          print("Stored Discord session deleted.")
        default:
          throw CommandError.unknownCommand
        }
        Foundation.exit(EXIT_SUCCESS)
      } catch {
        writeError("DiscordStandin: \(error.localizedDescription)\n")
        Foundation.exit(EXIT_FAILURE)
      }
    }
    dispatchMain()
  }

  private static func writeJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
  }

  private static func writeError(_ text: String) {
    guard let data = text.data(using: .utf8) else { return }
    try? FileHandle.standardError.write(contentsOf: data)
  }

  private static let help = """
    DiscordStandin 0.1.0

    Usage:
      DiscordStandin server   Run the stdio MCP server
      DiscordStandin login    Open the interactive Discord login window
      DiscordStandin status   Validate and describe the stored session
      DiscordStandin logout   Delete the stored session from Keychain
      DiscordStandin help     Show this help
    """
}

private enum CommandError: LocalizedError {
  case unknownCommand

  var errorDescription: String? {
    "Unknown command. Run DiscordStandin help."
  }
}
