import Foundation
import Security

public enum DiscordStandinError: LocalizedError, Sendable {
  case noStoredSession
  case emptyContent
  case invalidImage(String)
  case invalidResponse
  case invalidURL
  case sessionRejected
  case invalidSearch(String)
  case invalidDeletion(String)
  case messageNotFound
  case threadArchiveRestoreFailed(String)
  case searchIndexing(retryAfter: Double)
  case gateway(String)
  case http(statusCode: Int, message: String)
  case decoding(String)
  case keychain(operation: String, status: OSStatus)

  public var errorDescription: String? {
    switch self {
    case .noStoredSession:
      "No Discord session is stored. Run the login flow first."
    case .emptyContent:
      "Discord message content cannot be empty."
    case .invalidImage(let message):
      "Invalid Discord image upload: \(message)"
    case .invalidResponse:
      "Discord returned an invalid HTTP response."
    case .invalidURL:
      "Could not construct the Discord API URL."
    case .sessionRejected:
      "Discord rejected the stored session. Run the login flow again."
    case .invalidSearch(let message):
      "Invalid Discord message search: \(message)"
    case .invalidDeletion(let message):
      "Invalid Discord message deletion: \(message)"
    case .messageNotFound:
      "Discord did not return the requested message."
    case .threadArchiveRestoreFailed(let message):
      "The message was edited, but DiscordStandin could not restore the thread's archived state: \(message)"
    case .searchIndexing(let retryAfter):
      "Discord is still indexing this server's messages. Retry after \(retryAfter) seconds."
    case .gateway(let message):
      "Discord Gateway snapshot failed: \(message)"
    case .http(let statusCode, let message):
      "Discord API request failed with HTTP \(statusCode): \(message)"
    case .decoding(let message):
      "Could not decode the Discord response: \(message)"
    case .keychain(let operation, let status):
      "Keychain \(operation) failed with status \(status)."
    }
  }
}
