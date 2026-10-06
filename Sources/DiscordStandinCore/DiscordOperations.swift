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
    allowEveryoneMention: Bool = false,
    filePath: String? = nil
  ) async throws -> DiscordPostReceipt {
    let message = try await authenticatedClient().postMessage(
      channelID: channelID,
      content: content,
      replyToMessageID: replyToMessageID,
      allowEveryoneMention: allowEveryoneMention,
      filePath: filePath
    )
    let url = message.guildID.map {
      "https://discord.com/channels/\($0)/\(message.channelID)/\(message.id)"
    }
    return DiscordPostReceipt(message: message, url: url)
  }

  public func downloadAttachment(
    channelID: String,
    messageID: String,
    attachmentID: String,
    destinationPath: String
  ) async throws -> DiscordAttachmentDownloadReceipt {
    let path = (destinationPath as NSString).expandingTildeInPath
    guard (path as NSString).isAbsolutePath else {
      throw DiscordStandinError.attachment("destination_path must be absolute")
    }
    let destination = URL(fileURLWithPath: path)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw DiscordStandinError.attachment("destination already exists: \(path)")
    }
    guard FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path) else {
      throw DiscordStandinError.attachment("destination directory does not exist: \(path)")
    }
    let message = try await authenticatedClient().message(
      channelID: channelID, messageID: messageID)
    guard let attachment = message.attachments?.first(where: { $0.id == attachmentID }) else {
      throw DiscordStandinError.attachment("attachment ID is not on the specified message")
    }
    guard let url = URL(string: attachment.url), url.scheme == "https",
      ["cdn.discordapp.com", "cdn.discord.com", "media.discordapp.net"].contains(url.host)
    else {
      throw DiscordStandinError.attachment("message returned an unexpected attachment URL")
    }
    let (temporary, response) = try await transport.download(from: url)
    guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
      throw DiscordStandinError.attachment("download returned an unsuccessful HTTP response")
    }
    do {
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
      throw DiscordStandinError.attachment(error.localizedDescription)
    }
    return DiscordAttachmentDownloadReceipt(
      attachmentID: attachmentID,
      filename: attachment.filename,
      destinationPath: destination.path,
      size: (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    )
  }

  public func addReaction(channelID: String, messageID: String, emoji: String) async throws -> Bool {
    try await authenticatedClient().addReaction(channelID: channelID, messageID: messageID, emoji: emoji)
    return true
  }

  public func removeOwnReaction(channelID: String, messageID: String, emoji: String) async throws -> Bool {
    try await authenticatedClient().removeOwnReaction(channelID: channelID, messageID: messageID, emoji: emoji)
    return true
  }

  public func reactionUsers(channelID: String, messageID: String, emoji: String) async throws -> [DiscordUser] {
    try await authenticatedClient().reactionUsers(channelID: channelID, messageID: messageID, emoji: emoji)
  }

  public func createChannel(serverID: String, name: String, type: Int, parentID: String? = nil) async throws -> DiscordChannel {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else {
      throw DiscordStandinError.channel("name must contain 1 to 100 characters")
    }
    guard [0, 2, 4, 5, 13, 15, 16].contains(type) else {
      throw DiscordStandinError.channel("unsupported channel type")
    }
    return try await authenticatedClient().createChannel(guildID: serverID, name: name, type: type, parentID: parentID)
  }

  public func renameChannel(serverID: String, channelID: String, expectedName: String, name: String) async throws -> DiscordChannel {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else {
      throw DiscordStandinError.channel("name must contain 1 to 100 characters")
    }
    let client = try authenticatedClient()
    let current = try await client.channel(channelID: channelID)
    guard current.guildID == serverID, current.name == expectedName else {
      throw DiscordStandinError.channel("channel server or current name does not match")
    }
    return try await client.renameChannel(channelID: channelID, name: name)
  }

  public func deleteChannel(serverID: String, channelID: String, expectedName: String) async throws -> DiscordChannel {
    let client = try authenticatedClient()
    let current = try await client.channel(channelID: channelID)
    guard current.guildID == serverID, current.name == expectedName else {
      throw DiscordStandinError.channel("channel server or current name does not match")
    }
    return try await client.deleteChannel(channelID: channelID)
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
    imagePath: String? = nil,
    filePath: String? = nil,
    retainAttachmentIDs: [String]? = nil
  ) async throws -> DiscordMessageResult {
    let client = try authenticatedClient()
    let message: DiscordMessage
    do {
      message = try await client.editMessage(
        channelID: channelID,
        messageID: messageID,
        content: content,
        imagePath: imagePath,
        filePath: filePath,
        retainAttachmentIDs: retainAttachmentIDs
      )
    } catch let error as DiscordStandinError {
      guard Self.isArchivedThreadError(error) else { throw error }
      _ = try await client.setThreadArchived(channelID: channelID, archived: false)
      do {
        message = try await client.editMessage(
          channelID: channelID,
          messageID: messageID,
          content: content,
          imagePath: imagePath,
          filePath: filePath,
          retainAttachmentIDs: retainAttachmentIDs
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

  public func planMessageDeletion(
    channelID: String,
    messageIDs: [String]
  ) async throws -> DiscordMessageDeletionPlan {
    let messages = try await preflightMessageDeletion(
      channelID: channelID,
      messageIDs: messageIDs
    )
    return DiscordMessageDeletionPlan(
      channelID: channelID,
      messageCount: messages.count,
      messages: messages
    )
  }

  public func deleteMessages(
    channelID: String,
    messageIDs: [String],
    expectedMessageCount: Int
  ) async throws -> DiscordMessageDeletionReceipt {
    guard expectedMessageCount == messageIDs.count else {
      throw DiscordStandinError.invalidDeletion(
        "expected_message_count \(expectedMessageCount) does not match the \(messageIDs.count) supplied message IDs"
      )
    }

    _ = try await preflightMessageDeletion(
      channelID: channelID,
      messageIDs: messageIDs
    )

    let client = try authenticatedClient()
    var deletedMessageIDs: [String] = []
    var failures: [DiscordMessageDeletionFailure] = []
    for messageID in messageIDs {
      do {
        try await client.deleteMessage(
          channelID: channelID,
          messageID: messageID
        )
        deletedMessageIDs.append(messageID)
      } catch {
        failures.append(
          DiscordMessageDeletionFailure(
            messageID: messageID,
            error: error.localizedDescription
          )
        )
      }
    }

    return DiscordMessageDeletionReceipt(
      channelID: channelID,
      requestedCount: messageIDs.count,
      deletedMessageIDs: deletedMessageIDs,
      failures: failures,
      success: failures.isEmpty
    )
  }

  public func createForumPost(
    serverID: String,
    forumChannelID: String,
    title: String,
    content: String,
    appliedTagIDs: [String],
    autoArchiveDuration: Int,
    imagePath: String? = nil,
    filePath: String? = nil
  ) async throws -> DiscordForumPostReceipt {
    let thread = try await authenticatedClient().createForumPost(
      channelID: forumChannelID,
      title: title,
      content: content,
      appliedTagIDs: appliedTagIDs,
      autoArchiveDuration: autoArchiveDuration,
      imagePath: imagePath,
      filePath: filePath
    )
    return DiscordForumPostReceipt(
      thread: thread,
      url: "https://discord.com/channels/\(serverID)/\(thread.id)"
    )
  }

  private func authenticatedClient() throws -> DiscordRESTClient {
    try client(token: authenticatedToken())
  }

  private func preflightMessageDeletion(
    channelID: String,
    messageIDs: [String]
  ) async throws -> [DiscordMessage] {
    guard channelID.allSatisfy(\.isNumber), !channelID.isEmpty else {
      throw DiscordStandinError.invalidDeletion("channel_id must be a Discord snowflake")
    }
    guard (1...100).contains(messageIDs.count) else {
      throw DiscordStandinError.invalidDeletion(
        "message_ids must contain between 1 and 100 snowflakes"
      )
    }
    guard Set(messageIDs).count == messageIDs.count else {
      throw DiscordStandinError.invalidDeletion("message_ids must not contain duplicates")
    }
    guard messageIDs.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
      throw DiscordStandinError.invalidDeletion(
        "every message_id must be a Discord snowflake"
      )
    }

    let client = try authenticatedClient()
    var messages: [DiscordMessage] = []
    for messageID in messageIDs {
      do {
        let message = try await client.message(
          channelID: channelID,
          messageID: messageID
        )
        guard message.channelID == channelID else {
          throw DiscordStandinError.invalidDeletion(
            "message \(messageID) resolved outside channel \(channelID)"
          )
        }
        messages.append(message)
      } catch {
        throw DiscordStandinError.invalidDeletion(
          "could not preflight message \(messageID): \(error.localizedDescription)"
        )
      }
    }
    return messages
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
