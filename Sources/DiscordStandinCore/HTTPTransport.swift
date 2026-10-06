import Foundation

public protocol DiscordHTTPTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
  func upload(file: URL, to request: URLRequest) async throws -> (Data, URLResponse)
  func download(from url: URL) async throws -> (URL, URLResponse)
}

public struct URLSessionDiscordHTTPTransport: DiscordHTTPTransport, Sendable {
  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.data(for: request)
  }

  public func upload(file: URL, to request: URLRequest) async throws -> (Data, URLResponse) {
    try await session.upload(for: request, fromFile: file)
  }

  public func download(from url: URL) async throws -> (URL, URLResponse) {
    try await session.download(from: url)
  }
}
