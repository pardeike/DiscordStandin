import Foundation

public struct DiscordOperations: Sendable {
  private let credentials: any CredentialStore
  private let baseURL: URL
  private let transport: any DiscordHTTPTransport
  private let profile: DiscordClientProfile
  private let gateway: any DiscordGatewaySnapshotProviding

  public init(
    credentials: any CredentialStore = KeychainCredentialStore(),
    baseURL: URL = DiscordRESTClient.defaultBaseURL,
    transport: any DiscordHTTPTransport = URLSessionDiscordHTTPTransport(),
    profile: DiscordClientProfile = .current,
    gateway: any DiscordGatewaySnapshotProviding = LiveDiscordGatewaySnapshotProvider()
  ) {
    self.credentials = credentials
    self.baseURL = baseURL
    self.transport = transport
    self.profile = profile
    self.gateway = gateway
  }

  public func sessionStatus() async -> DiscordSessionStatus {
    let token: String
    do {
      guard let storedToken = try credentials.loadToken() else {
        return DiscordSessionStatus(
          hasStoredCredential: false,
          authenticated: false,
          user: nil,
          error: nil
        )
      }
      token = storedToken
    } catch {
      return DiscordSessionStatus(
        hasStoredCredential: false,
        authenticated: false,
        user: nil,
        error: error.localizedDescription
      )
    }

    do {
      let user = try await client(token: token).currentUser()
      return DiscordSessionStatus(
        hasStoredCredential: true,
        authenticated: true,
        user: user,
        error: nil
      )
    } catch {
      return DiscordSessionStatus(
        hasStoredCredential: true,
        authenticated: false,
        user: nil,
        error: error.localizedDescription
      )
    }
  }

  public func logout() throws {
    try credentials.deleteToken()
  }

  public func listServers() async throws -> [DiscordGuild] {
    try await authenticatedClient().guilds()
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  public func listChannels(
    serverID: String,
    includeActiveThreads: Bool
  ) async throws -> DiscordServerChannels {
    let token = try authenticatedToken()
    let snapshot = try await gateway.channels(
      token: token,
      profile: profile,
      guildID: serverID
    )
    return DiscordServerChannels(
      channels: snapshot.channels.sorted(by: Self.channelOrder),
      activeThreads:
        includeActiveThreads
        ? snapshot.activeThreads.sorted(by: Self.channelOrder)
        : []
    )
  }

  public func listForumPosts(
    serverID: String,
    forumChannelID: String,
    includeArchived: Bool,
    archivedBefore: String? = nil
  ) async throws -> DiscordForumPosts {
    let token = try authenticatedToken()
    let client = client(token: token)
    let active: [DiscordChannel]
    if archivedBefore == nil {
      let snapshot = try await gateway.channels(
        token: token,
        profile: profile,
        guildID: serverID
      )
      active = snapshot.activeThreads
        .filter { $0.parentID == forumChannelID }
        .sorted(by: Self.channelOrder)
    } else {
      active = []
    }

    if includeArchived {
      let archived = try await client.publicArchivedThreads(
        channelID: forumChannelID,
        beforeArchiveTimestamp: archivedBefore
      )
      return DiscordForumPosts(
        active: active,
        archived: archived.threads.sorted(by: Self.channelOrder),
        archivedHasMore: archived.hasMore ?? false,
        nextArchivedBefore:
          archived.hasMore == true
          ? archived.threads.last?.threadMetadata?.archiveTimestamp
          : nil
      )
    }

    return DiscordForumPosts(
      active: active,
      archived: [],
      archivedHasMore: false,
      nextArchivedBefore: nil
    )
  }

  public func getChannelMessages(
    channelID: String,
    limit: Int,
    before: String?,
    after: String?,
    around: String?
  ) async throws -> [DiscordMessage] {
    guard (1...100).contains(limit) else {
      throw DiscordStandinError.invalidSearch("limit must be between 1 and 100")
    }
    let cursors = [before, after, around].compactMap { $0 }
    guard cursors.count <= 1 else {
      throw DiscordStandinError.invalidSearch(
        "only one of before_message_id, after_message_id, or around_message_id can be supplied"
      )
    }
    return try await authenticatedClient().messages(
      channelID: channelID,
      limit: limit,
      before: before,
      after: after,
      around: around
    )
  }

  public func getMessage(
    channelID: String,
    messageID: String
  ) async throws -> DiscordMessageResult {
    let message = try await authenticatedClient().message(
      channelID: channelID,
      messageID: messageID
    )
    let url = message.guildID.map {
      "https://discord.com/channels/\($0)/\(message.channelID)/\(message.id)"
    }
    return DiscordMessageResult(message: message, url: url)
  }

  public func searchMessages(
    serverID: String,
    query: String,
    channelID: String?,
    authorID: String?,
    offset: Int,
    sortBy: String,
    sortOrder: String
  ) async throws -> DiscordMessageSearchResults {
    guard (0...9_975).contains(offset), offset.isMultiple(of: 25) else {
      throw DiscordStandinError.invalidSearch(
        "offset must be a multiple of 25 between 0 and 9975"
      )
    }
    guard ["timestamp", "relevance"].contains(sortBy) else {
      throw DiscordStandinError.invalidSearch(
        "sort_by must be timestamp or relevance"
      )
    }
    guard ["asc", "desc"].contains(sortOrder) else {
      throw DiscordStandinError.invalidSearch("sort_order must be asc or desc")
    }
    return try await authenticatedClient().searchMessages(
      guildID: serverID,
      content: query,
      channelID: channelID,
      authorID: authorID,
      offset: offset,
      sortBy: sortBy,
      sortOrder: sortOrder
    )
  }

  public func postMessage(
    channelID: String,
    content: String,
    replyToMessageID: String?,
    allowEveryoneMention: Bool = false
  ) async throws -> DiscordPostReceipt {
    let message = try await authenticatedClient().postMessage(
      channelID: channelID,
      content: content,
      replyToMessageID: replyToMessageID,
      allowEveryoneMention: allowEveryoneMention
    )
    let url = message.guildID.map {
      "https://discord.com/channels/\($0)/\(message.channelID)/\(message.id)"
    }
    return DiscordPostReceipt(message: message, url: url)
  }

  public func publishMessage(
    channelID: String,
    messageID: String
  ) async throws -> DiscordPublishReceipt {
    let client = try authenticatedClient()
    let existing = try await client.message(
      channelID: channelID,
      messageID: messageID
    )
    let alreadyPublished = (existing.flags ?? 0) & 1 == 1
    let message =
      alreadyPublished
      ? existing
      : try await client.crosspostMessage(
        channelID: channelID,
        messageID: messageID
      )
    let url = message.guildID.map {
      "https://discord.com/channels/\($0)/\(message.channelID)/\(message.id)"
    }
    return DiscordPublishReceipt(
      message: message,
      url: url,
      alreadyPublished: alreadyPublished
    )
  }

  public func editMessage(
    channelID: String,
    messageID: String,
    content: String,
    imagePath: String? = nil
  ) async throws -> DiscordMessageResult {
    let client = try authenticatedClient()
    let message: DiscordMessage
    do {
      message = try await client.editMessage(
        channelID: channelID,
        messageID: messageID,
        content: content,
        imagePath: imagePath
      )
    } catch let error as DiscordStandinError {
      guard Self.isArchivedThreadError(error) else { throw error }
      _ = try await client.setThreadArchived(channelID: channelID, archived: false)
      do {
        message = try await client.editMessage(
          channelID: channelID,
          messageID: messageID,
          content: content,
          imagePath: imagePath
        )
      } catch {
        _ = try? await client.setThreadArchived(channelID: channelID, archived: true)
        throw error
      }
      do {
        _ = try await client.setThreadArchived(channelID: channelID, archived: true)
      } catch {
        throw DiscordStandinError.threadArchiveRestoreFailed(error.localizedDescription)
      }
    }
    let url = message.guildID.map {
      "https://discord.com/channels/\($0)/\(message.channelID)/\(message.id)"
    }
    return DiscordMessageResult(message: message, url: url)
  }

  public func createForumPost(
    serverID: String,
    forumChannelID: String,
    title: String,
    content: String,
    appliedTagIDs: [String],
    autoArchiveDuration: Int,
    imagePath: String? = nil
  ) async throws -> DiscordForumPostReceipt {
    let thread = try await authenticatedClient().createForumPost(
      channelID: forumChannelID,
      title: title,
      content: content,
      appliedTagIDs: appliedTagIDs,
      autoArchiveDuration: autoArchiveDuration,
      imagePath: imagePath
    )
    return DiscordForumPostReceipt(
      thread: thread,
      url: "https://discord.com/channels/\(serverID)/\(thread.id)"
    )
  }

  private func authenticatedClient() throws -> DiscordRESTClient {
    try client(token: authenticatedToken())
  }

  private func authenticatedToken() throws -> String {
    guard let token = try credentials.loadToken() else {
      throw DiscordStandinError.noStoredSession
    }
    return token
  }

  private func client(token: String) -> DiscordRESTClient {
    DiscordRESTClient(
      token: token,
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )
  }

  private static func channelOrder(_ lhs: DiscordChannel, _ rhs: DiscordChannel) -> Bool {
    let lhsPosition = lhs.position ?? Int.max
    let rhsPosition = rhs.position ?? Int.max
    if lhsPosition != rhsPosition {
      return lhsPosition < rhsPosition
    }
    return (lhs.name ?? lhs.id).localizedStandardCompare(rhs.name ?? rhs.id) == .orderedAscending
  }

  private static func isArchivedThreadError(_ error: DiscordStandinError) -> Bool {
    guard case .http(let statusCode, let message) = error else { return false }
    let compactMessage = message.replacingOccurrences(of: " ", with: "")
    return statusCode == 400 && compactMessage.contains(#""code":50083"#)
  }
}
