import Foundation

public protocol DiscordGatewaySnapshotProviding: Sendable {
  func channels(
    token: String,
    profile: DiscordClientProfile,
    guildID: String
  ) async throws -> DiscordServerChannels
}

public struct LiveDiscordGatewaySnapshotProvider:
  DiscordGatewaySnapshotProviding, Sendable
{
  public init() {}

  public func channels(
    token: String,
    profile: DiscordClientProfile,
    guildID: String
  ) async throws -> DiscordServerChannels {
    try await DiscordGatewaySnapshotClient(
      token: token,
      profile: profile
    ).channels(guildID: guildID)
  }
}

public struct DiscordGatewaySnapshotClient: Sendable {
  private static let gatewayURL = URL(
    string: "wss://gateway.discord.gg/?v=9&encoding=json"
  )!

  private let token: String
  private let profile: DiscordClientProfile
  private let session: URLSession

  public init(
    token: String,
    profile: DiscordClientProfile = .current,
    session: URLSession = .shared
  ) {
    self.token = token
    self.profile = profile
    self.session = session
  }

  public func channels(
    guildID: String,
    timeout: Duration = .seconds(20)
  ) async throws -> DiscordServerChannels {
    let socket = session.webSocketTask(with: Self.gatewayURL)
    socket.maximumMessageSize = 32 * 1_024 * 1_024
    socket.resume()
    defer {
      socket.cancel(with: .normalClosure, reason: nil)
    }

    let helloMessage = try await receive(from: socket, timeout: timeout)
    let helloData = try Self.data(from: helloMessage)
    let hello = try Self.decode(GatewayHelloEnvelope.self, from: helloData)
    guard hello.op == 10 else {
      throw DiscordStandinError.gateway(
        "expected HELLO opcode 10, received \(hello.op)"
      )
    }

    let identify = GatewayOutgoing(
      op: 2,
      d: GatewayIdentify(
        token: token,
        capabilities: 1_734_653,
        properties: GatewayProperties(profile: profile),
        compress: false,
        clientState: GatewayClientState(guildVersions: [:])
      )
    )
    let identifyData = try JSONEncoder().encode(identify)
    try await socket.send(.data(identifyData))

    while true {
      let message = try await receive(from: socket, timeout: timeout)
      let data = try Self.data(from: message)
      let header = try Self.decode(GatewayHeader.self, from: data)

      if header.op == 1 {
        let heartbeat = GatewayOutgoing(
          op: 1,
          d: GatewayHeartbeat(sequence: header.s)
        )
        try await socket.send(.data(JSONEncoder().encode(heartbeat)))
        continue
      }

      if header.op == 9 {
        throw DiscordStandinError.gateway("Discord rejected the Gateway session.")
      }
      if header.op == 7 {
        throw DiscordStandinError.gateway(
          "Discord requested a Gateway reconnect before the snapshot arrived."
        )
      }
      guard header.op == 0, header.t == "READY" else {
        continue
      }

      return try Self.snapshot(fromReadyData: data, guildID: guildID)
    }
  }

  static func snapshot(
    fromReadyData data: Data,
    guildID: String
  ) throws -> DiscordServerChannels {
    let ready = try decode(GatewayReadyEnvelope.self, from: data)
    guard let guild = ready.d.guilds.first(where: { $0.id == guildID }) else {
      throw DiscordStandinError.gateway(
        "the requested server was not present in the READY snapshot"
      )
    }
    guard let channels = guild.channels else {
      throw DiscordStandinError.gateway(
        "Discord marked the requested server unavailable in the READY snapshot"
      )
    }
    return DiscordServerChannels(
      channels: channels,
      activeThreads: guild.threads ?? []
    )
  }

  private func receive(
    from socket: URLSessionWebSocketTask,
    timeout: Duration
  ) async throws -> URLSessionWebSocketTask.Message {
    try await withThrowingTaskGroup(
      of: URLSessionWebSocketTask.Message.self
    ) { group in
      group.addTask {
        try await socket.receive()
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw DiscordStandinError.gateway("timed out waiting for Discord Gateway")
      }
      guard let first = try await group.next() else {
        throw DiscordStandinError.gateway("Discord Gateway closed without a message")
      }
      group.cancelAll()
      return first
    }
  }

  private static func data(
    from message: URLSessionWebSocketTask.Message
  ) throws -> Data {
    switch message {
    case .data(let data):
      return data
    case .string(let text):
      return Data(text.utf8)
    @unknown default:
      throw DiscordStandinError.gateway("received an unknown Gateway message type")
    }
  }

  private static func decode<Value: Decodable>(
    _ type: Value.Type,
    from data: Data
  ) throws -> Value {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw DiscordStandinError.decoding("Gateway \(String(describing: error))")
    }
  }
}

private struct GatewayHelloEnvelope: Decodable, Sendable {
  let op: Int
  let d: GatewayHello
}

private struct GatewayHello: Decodable, Sendable {
  let heartbeatInterval: Double

  enum CodingKeys: String, CodingKey {
    case heartbeatInterval = "heartbeat_interval"
  }
}

private struct GatewayHeader: Decodable, Sendable {
  let op: Int
  let t: String?
  let s: Int?
}

private struct GatewayReadyEnvelope: Decodable, Sendable {
  let d: GatewayReady
}

private struct GatewayReady: Decodable, Sendable {
  let guilds: [GatewayGuild]
}

private struct GatewayGuild: Decodable, Sendable {
  let id: String
  let channels: [DiscordChannel]?
  let threads: [DiscordChannel]?
}

private struct GatewayOutgoing<Payload: Encodable & Sendable>: Encodable, Sendable {
  let op: Int
  let d: Payload
}

private struct GatewayHeartbeat: Encodable, Sendable {
  let sequence: Int?

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(sequence)
  }
}

private struct GatewayIdentify: Encodable, Sendable {
  let token: String
  let capabilities: Int
  let properties: GatewayProperties
  let compress: Bool
  let clientState: GatewayClientState

  enum CodingKeys: String, CodingKey {
    case token
    case capabilities
    case properties
    case compress
    case clientState = "client_state"
  }
}

private struct GatewayProperties: Encodable, Sendable {
  let os = "Mac OS X"
  let browser = "Chrome"
  let device = ""
  let systemLocale: String
  let hasClientMods = false
  let browserUserAgent: String
  let browserVersion = "149.0.0.0"
  let osVersion = "10.15.7"
  let referrer = ""
  let referringDomain = ""
  let referrerCurrent = ""
  let referringDomainCurrent = ""
  let releaseChannel = "stable"
  let clientBuildNumber = 556_969
  let clientLaunchID = UUID().uuidString.lowercased()
  let clientAppState = "unfocused"
  let isFastConnect = false
  let gatewayConnectReasons = ""

  init(profile: DiscordClientProfile) {
    self.systemLocale = profile.locale
    self.browserUserAgent = profile.userAgent
  }

  enum CodingKeys: String, CodingKey {
    case os
    case browser
    case device
    case systemLocale = "system_locale"
    case hasClientMods = "has_client_mods"
    case browserUserAgent = "browser_user_agent"
    case browserVersion = "browser_version"
    case osVersion = "os_version"
    case referrer
    case referringDomain = "referring_domain"
    case referrerCurrent = "referrer_current"
    case referringDomainCurrent = "referring_domain_current"
    case releaseChannel = "release_channel"
    case clientBuildNumber = "client_build_number"
    case clientLaunchID = "client_launch_id"
    case clientAppState = "client_app_state"
    case isFastConnect = "is_fast_connect"
    case gatewayConnectReasons = "gateway_connect_reasons"
  }
}

private struct GatewayClientState: Encodable, Sendable {
  let guildVersions: [String: Int]

  enum CodingKeys: String, CodingKey {
    case guildVersions = "guild_versions"
  }
}
