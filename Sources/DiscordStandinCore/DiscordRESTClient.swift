import Foundation

public struct DiscordRESTClient: Sendable {
  public static let defaultBaseURL = URL(string: "https://discord.com/api/v9")!

  private let token: String
  private let baseURL: URL
  private let transport: any DiscordHTTPTransport
  private let profile: DiscordClientProfile
  private let rateLimiter: DiscordRateLimiter
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init(
    token: String,
    baseURL: URL = Self.defaultBaseURL,
    transport: any DiscordHTTPTransport = URLSessionDiscordHTTPTransport(),
    profile: DiscordClientProfile = .current,
    rateLimiter: DiscordRateLimiter = .shared
  ) {
    self.token = token
    self.baseURL = baseURL
    self.transport = transport
    self.profile = profile
    self.rateLimiter = rateLimiter
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
  }

  public func currentUser() async throws -> DiscordUser {
    try await get(path: "users/@me")
  }

  public func guilds() async throws -> [DiscordGuild] {
    try await get(
      path: "users/@me/guilds",
      query: [URLQueryItem(name: "limit", value: "200")]
    )
  }

  public func channels(guildID: String) async throws -> [DiscordChannel] {
    try await get(path: "guilds/\(guildID)/channels")
  }

  public func channel(channelID: String) async throws -> DiscordChannel {
    try await get(path: "channels/\(channelID)")
  }

  public func createChannel(guildID: String, name: String, type: Int, parentID: String? = nil) async throws -> DiscordChannel {
    try await post(path: "guilds/\(guildID)/channels", body: ChannelCreation(name: name, type: type, parentID: parentID))
  }

  public func renameChannel(channelID: String, name: String) async throws -> DiscordChannel {
    try await patch(path: "channels/\(channelID)", body: ChannelRename(name: name))
  }

  public func deleteChannel(channelID: String) async throws -> DiscordChannel {
    let (data, _) = try await requestData(method: "DELETE", path: "channels/\(channelID)")
    return try decode(data)
  }

  public func activeThreads(guildID: String) async throws -> DiscordThreadList {
    try await get(path: "guilds/\(guildID)/threads/active")
  }

  public func publicArchivedThreads(
    channelID: String,
    beforeArchiveTimestamp: String? = nil
  ) async throws -> DiscordThreadList {
    var query = [URLQueryItem(name: "limit", value: "100")]
    if let beforeArchiveTimestamp {
      query.append(URLQueryItem(name: "before", value: beforeArchiveTimestamp))
    }
    return try await get(
      path: "channels/\(channelID)/threads/archived/public",
      query: query
    )
  }

  public func messages(
    channelID: String,
    limit: Int,
    before: String? = nil,
    after: String? = nil,
    around: String? = nil
  ) async throws -> [DiscordMessage] {
    var query = [URLQueryItem(name: "limit", value: String(limit))]
    if let around {
      query.append(URLQueryItem(name: "around", value: around))
    } else if let before {
      query.append(URLQueryItem(name: "before", value: before))
    } else if let after {
      query.append(URLQueryItem(name: "after", value: after))
    }
    return try await get(path: "channels/\(channelID)/messages", query: query)
  }

  public func message(channelID: String, messageID: String) async throws -> DiscordMessage {
    let nearby = try await messages(channelID: channelID, limit: 1, around: messageID)
    guard let message = nearby.first(where: { $0.id == messageID }) else {
      throw DiscordStandinError.messageNotFound
    }
    return message
  }

  public func searchMessages(
    guildID: String,
    content: String,
    channelID: String? = nil,
    authorID: String? = nil,
    offset: Int = 0,
    sortBy: String = "timestamp",
    sortOrder: String = "desc"
  ) async throws -> DiscordMessageSearchResults {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DiscordStandinError.invalidSearch("content cannot be empty")
    }

    var baseQuery = [
      URLQueryItem(name: "content", value: content),
      URLQueryItem(name: "sort_by", value: sortBy),
      URLQueryItem(name: "sort_order", value: sortOrder),
      URLQueryItem(name: "offset", value: String(offset)),
    ]
    if let channelID {
      baseQuery.append(URLQueryItem(name: "channel_id", value: channelID))
    }
    if let authorID {
      baseQuery.append(URLQueryItem(name: "author_id", value: authorID))
    }

    var lastRetryAfter = 5.0
    for attempt in 0..<6 {
      var query = baseQuery
      if attempt > 0 {
        query.append(URLQueryItem(name: "attempts", value: String(attempt)))
      }
      let (data, response) = try await requestData(
        method: "GET",
        path: "guilds/\(guildID)/messages/search",
        query: query
      )
      if response.statusCode == 202 {
        lastRetryAfter = Self.retryAfter(from: response)
        if attempt < 5 {
          try await Task.sleep(for: .seconds(min(max(lastRetryAfter, 0.1), 5)))
          continue
        }
        throw DiscordStandinError.searchIndexing(retryAfter: lastRetryAfter)
      }

      let wire: MessageSearchWireResponse = try decode(data)
      let hits = wire.messages.compactMap { group -> DiscordMessageSearchHit? in
        guard let primary = group.first else { return nil }
        let resolvedGuildID = primary.guildID ?? guildID
        return DiscordMessageSearchHit(
          message: primary,
          context: Array(group.dropFirst()),
          url:
            "https://discord.com/channels/\(resolvedGuildID)/\(primary.channelID)/\(primary.id)"
        )
      }
      return DiscordMessageSearchResults(
        totalResults: wire.totalResults,
        hits: hits,
        doingDeepHistoricalIndex: wire.doingDeepHistoricalIndex,
        documentsIndexed: wire.documentsIndexed
      )
    }

    throw DiscordStandinError.searchIndexing(retryAfter: lastRetryAfter)
  }

  public func postMessage(
    channelID: String,
    content: String,
    replyToMessageID: String? = nil,
    allowEveryoneMention: Bool = false,
    filePath: String? = nil
  ) async throws -> DiscordMessage {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filePath != nil else {
      throw DiscordStandinError.emptyContent
    }
    let file = try filePath.map(Self.uploadFile)
    let attachment = try await uploadAttachmentIfNeeded(file, channelID: channelID)

    let reference = replyToMessageID.map {
      MessageReference(messageID: $0, channelID: channelID)
    }
    let payload = NewMessage(
      content: content,
      nonce: Self.nonce(),
      tts: false,
      allowedMentions: AllowedMentions(
        parse: allowEveryoneMention ? ["everyone"] : []
      ),
      messageReference: reference,
      attachments: attachment.map { [$0] }
    )
    if let file, attachment?.uploadedFilename == nil {
      return try await multipart(method: "POST", path: "channels/\(channelID)/messages", body: payload, file: file)
    }
    return try await post(
      path: "channels/\(channelID)/messages",
      body: payload
    )
  }

  public func crosspostMessage(
    channelID: String,
    messageID: String
  ) async throws -> DiscordMessage {
    try await postWithoutBody(
      path: "channels/\(channelID)/messages/\(messageID)/crosspost"
    )
  }

  public func editMessage(
    channelID: String,
    messageID: String,
    content: String,
    imagePath: String? = nil,
    filePath: String? = nil,
    retainAttachmentIDs: [String]? = nil
  ) async throws -> DiscordMessage {
    guard imagePath == nil || filePath == nil else {
      throw DiscordStandinError.invalidFile("supply file_path or image_path, not both")
    }
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imagePath != nil || filePath != nil else {
      throw DiscordStandinError.emptyContent
    }

    let file = try (filePath ?? imagePath).map(Self.uploadFile)
    let retained: [UploadAttachment]?
    if let retainAttachmentIDs {
      let existing = try await message(channelID: channelID, messageID: messageID).attachments ?? []
      guard Set(retainAttachmentIDs).count == retainAttachmentIDs.count,
        retainAttachmentIDs.allSatisfy({ id in existing.contains(where: { $0.id == id }) })
      else {
        throw DiscordStandinError.invalidFile("retain_attachment_ids must name unique attachments on the message")
      }
      retained = try retainAttachmentIDs.map { id in
        guard let attachment = existing.first(where: { $0.id == id }) else {
          throw DiscordStandinError.invalidFile("attachment is no longer on the message: \(id)")
        }
        guard let numericID = Int(id) else {
          throw DiscordStandinError.invalidFile("invalid attachment ID: \(id)")
        }
        return UploadAttachment(id: numericID, filename: attachment.filename)
      }
    } else {
      retained = nil
    }
    let attachment = try await uploadAttachmentIfNeeded(file, channelID: channelID)
    let payload = EditMessage(
      content: content,
      allowedMentions: AllowedMentions(parse: []),
      attachments: file == nil && retained == nil ? nil :
        (retained ?? []) + (attachment.map { [$0] } ?? [])
    )
    if let file, attachment?.uploadedFilename == nil {
      return try await multipart(
        method: "PATCH",
        path: "channels/\(channelID)/messages/\(messageID)",
        body: payload,
        file: file
      )
    }
    return try await patch(
      path: "channels/\(channelID)/messages/\(messageID)",
      body: payload
    )
  }

  public func deleteMessage(
    channelID: String,
    messageID: String
  ) async throws {
    try await deleteWithoutBody(
      path: "channels/\(channelID)/messages/\(messageID)"
    )
  }

  public func addReaction(channelID: String, messageID: String, emoji: String) async throws {
    let path = "channels/\(channelID)/messages/\(messageID)/reactions/\(emoji)/@me"
    _ = try await requestData(method: "PUT", path: path)
  }

  public func removeOwnReaction(channelID: String, messageID: String, emoji: String) async throws {
    let path = "channels/\(channelID)/messages/\(messageID)/reactions/\(emoji)/@me"
    try await deleteWithoutBody(path: path)
  }

  public func reactionUsers(channelID: String, messageID: String, emoji: String) async throws -> [DiscordUser] {
    try await get(path: "channels/\(channelID)/messages/\(messageID)/reactions/\(emoji)")
  }

  public func setThreadArchived(
    channelID: String,
    archived: Bool
  ) async throws -> DiscordChannel {
    try await patch(
      path: "channels/\(channelID)",
      body: ThreadArchiveUpdate(archived: archived)
    )
  }

  public func createForumPost(
    channelID: String,
    title: String,
    content: String,
    appliedTagIDs: [String],
    autoArchiveDuration: Int,
    imagePath: String? = nil,
    filePath: String? = nil
  ) async throws -> DiscordChannel {
    guard imagePath == nil || filePath == nil else {
      throw DiscordStandinError.invalidFile("supply file_path or image_path, not both")
    }
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DiscordStandinError.emptyContent
    }

    let file = try (filePath ?? imagePath).map(Self.uploadFile)
    let attachment = try await uploadAttachmentIfNeeded(file, channelID: channelID)
    let starter = NewMessage(
      content: content,
      nonce: Self.nonce(),
      tts: false,
      allowedMentions: AllowedMentions(parse: []),
      messageReference: nil,
      attachments: attachment.map { [$0] }
    )
    let payload = NewForumPost(
      name: title,
      autoArchiveDuration: autoArchiveDuration,
      message: starter,
      appliedTags: appliedTagIDs
    )
    let path = "channels/\(channelID)/threads"
    if let file, attachment?.uploadedFilename == nil {
      return try await multipart(
        method: "POST",
        path: path,
        body: payload,
        file: file
      )
    }
    return try await post(path: path, body: payload)
  }

  private func get<Response: Decodable & Sendable>(
    path: String,
    query: [URLQueryItem] = []
  ) async throws -> Response {
    let (data, _) = try await requestData(method: "GET", path: path, query: query)
    return try decode(data)
  }

  private func post<Response: Decodable & Sendable, Body: Encodable & Sendable>(
    path: String,
    body: Body
  ) async throws -> Response {
    let bodyData = try encoder.encode(body)
    let (data, _) = try await requestData(
      method: "POST",
      path: path,
      body: bodyData
    )
    return try decode(data)
  }

  private func postWithoutBody<Response: Decodable & Sendable>(
    path: String
  ) async throws -> Response {
    let (data, _) = try await requestData(
      method: "POST",
      path: path
    )
    return try decode(data)
  }

  private func deleteWithoutBody(path: String) async throws {
    _ = try await requestData(method: "DELETE", path: path)
  }

  private func patch<Response: Decodable & Sendable, Body: Encodable & Sendable>(
    path: String,
    body: Body
  ) async throws -> Response {
    let bodyData = try encoder.encode(body)
    let (data, _) = try await requestData(
      method: "PATCH",
      path: path,
      body: bodyData
    )
    return try decode(data)
  }

  private func multipart<Response: Decodable & Sendable, Body: Encodable & Sendable>(
    method: String,
    path: String,
    body: Body,
    file: UploadFile
  ) async throws -> Response {
    let boundary = "DiscordStandin-\(UUID().uuidString)"
    let payload = try encoder.encode(body)
    var bodyData = Data()
    bodyData.appendUTF8("--\(boundary)\r\n")
    bodyData.appendUTF8(
      "Content-Disposition: form-data; name=\"payload_json\"\r\n"
    )
    bodyData.appendUTF8("Content-Type: application/json\r\n\r\n")
    bodyData.append(payload)
    bodyData.appendUTF8("\r\n--\(boundary)\r\n")
    bodyData.appendUTF8(
      "Content-Disposition: form-data; name=\"files[0]\"; filename=\"\(file.filename)\"\r\n"
    )
    bodyData.appendUTF8("Content-Type: \(file.contentType)\r\n\r\n")
    let fileData = try Data(contentsOf: file.url)
    bodyData.append(fileData)
    bodyData.appendUTF8("\r\n--\(boundary)--\r\n")
    guard bodyData.count <= 25 * 1_024 * 1_024 else {
      throw DiscordStandinError.invalidFile(
        "multipart request exceeds Discord's 25 MiB limit"
      )
    }
    let (data, _) = try await requestData(
      method: method,
      path: path,
      body: bodyData,
      contentType: "multipart/form-data; boundary=\(boundary)"
    )
    return try decode(data)
  }

  private func uploadAttachmentIfNeeded(_ file: UploadFile?, channelID: String) async throws -> UploadAttachment? {
    guard let file else { return nil }
    // The documented message request limit is 25 MiB. Leave room for multipart headers and JSON.
    guard file.size > 24 * 1_024 * 1_024 else {
      return UploadAttachment(id: 0, filename: file.filename)
    }
    let slot: CloudUploadResponse = try await post(
      path: "channels/\(channelID)/attachments",
      body: CloudUploadRequest(files: [CloudUploadFile(filename: file.filename, fileSize: file.size)])
    )
    guard let entry = slot.attachments.first,
      let url = URL(string: entry.uploadURL), url.scheme == "https",
      url.host?.hasSuffix(".storage.googleapis.com") == true
    else {
      throw DiscordStandinError.invalidFile("Discord returned an invalid upload URL")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.timeoutInterval = 3_600
    request.setValue(file.contentType, forHTTPHeaderField: "Content-Type")
    let (_, response) = try await transport.upload(file: file.url, to: request)
    guard let httpResponse = response as? HTTPURLResponse,
      (200..<300).contains(httpResponse.statusCode)
    else {
      throw DiscordStandinError.invalidFile("Discord's file storage rejected the upload")
    }
    return UploadAttachment(id: 0, filename: file.filename, uploadedFilename: entry.uploadFilename)
  }

  private func requestData(
    method: String,
    path: String,
    query: [URLQueryItem] = [],
    body: Data? = nil,
    contentType: String = "application/json",
    retryCount: Int = 0
  ) async throws -> (Data, HTTPURLResponse) {
    guard
      var components = URLComponents(
        url: url(forPath: path),
        resolvingAgainstBaseURL: false
      )
    else {
      throw DiscordStandinError.invalidURL
    }
    if !query.isEmpty {
      components.queryItems = query
      components.percentEncodedQuery = components.percentEncodedQuery?
        .replacingOccurrences(of: "+", with: "%2B")
    }
    guard let url = components.url else {
      throw DiscordStandinError.invalidURL
    }

    let routeKey = Self.rateLimitRouteKey(method: method, url: url)
    try await rateLimiter.waitBeforeRequest(
      routeKey: routeKey,
      isMutation: method != "GET"
    )

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue(token, forHTTPHeaderField: "Authorization")
    request.setValue("https://discord.com", forHTTPHeaderField: "Origin")
    request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(profile.locale, forHTTPHeaderField: "X-Discord-Locale")
    request.setValue(profile.superProperties, forHTTPHeaderField: "X-Super-Properties")
    request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
    request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
    request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")

    if let body {
      request.httpBody = body
      request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await transport.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw DiscordStandinError.invalidResponse
    }

    let rateLimit =
      httpResponse.statusCode == 429
      ? try? decoder.decode(RateLimitResponse.self, from: data)
      : nil
    await rateLimiter.observe(
      routeKey: routeKey,
      response: httpResponse,
      retryAfter: rateLimit?.retryAfter,
      globallyLimited: rateLimit?.global ?? false
    )

    if httpResponse.statusCode == 429, retryCount < 4 {
      return try await self.requestData(
        method: method,
        path: path,
        query: query,
        body: body,
        contentType: contentType,
        retryCount: retryCount + 1
      )
    }

    if httpResponse.statusCode == 401 {
      throw DiscordStandinError.sessionRejected
    }

    guard (200..<300).contains(httpResponse.statusCode) else {
      throw DiscordStandinError.http(
        statusCode: httpResponse.statusCode,
        message: Self.boundedResponseText(data)
      )
    }

    return (data, httpResponse)
  }

  private func decode<Response: Decodable & Sendable>(_ data: Data) throws -> Response {
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw DiscordStandinError.decoding(String(describing: error))
    }
  }

  private func url(forPath path: String) -> URL {
    path.split(separator: "/").reduce(baseURL) { partial, component in
      partial.appendingPathComponent(String(component), isDirectory: false)
    }
  }

  private static func nonce() -> String {
    String(
      UUID().uuidString
        .replacingOccurrences(of: "-", with: "")
        .lowercased()
        .prefix(25)
    )
  }

  private static func uploadFile(atPath path: String) throws -> UploadFile {
    let expandedPath = (path as NSString).expandingTildeInPath
    guard (expandedPath as NSString).isAbsolutePath else {
      throw DiscordStandinError.invalidFile("file path must be absolute")
    }
    let url = URL(fileURLWithPath: expandedPath, isDirectory: false)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw DiscordStandinError.invalidFile("file does not exist: \(expandedPath)")
    }
    let contentType: String
    switch url.pathExtension.lowercased() {
    case "png":
      contentType = "image/png"
    case "jpg", "jpeg":
      contentType = "image/jpeg"
    case "gif":
      contentType = "image/gif"
    case "webp":
      contentType = "image/webp"
    case "zip":
      contentType = "application/zip"
    case "pdf":
      contentType = "application/pdf"
    case "txt":
      contentType = "text/plain"
    default:
      contentType = "application/octet-stream"
    }
    let size: Int
    do {
      size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    } catch {
      throw DiscordStandinError.invalidFile(error.localizedDescription)
    }
    guard size > 0 else {
      throw DiscordStandinError.invalidFile("file is empty")
    }
    let filename = url.lastPathComponent
      .replacingOccurrences(of: "\"", with: "_")
      .replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
    return UploadFile(url: url, size: size, filename: filename, contentType: contentType)
  }

  private static func rateLimitRouteKey(method: String, url: URL) -> String {
    let normalizedPath = url.pathComponents.map { component in
      component.allSatisfy(\.isNumber) ? ":id" : component
    }.joined(separator: "/")
    return "\(method) \(url.host ?? "")\(normalizedPath)"
  }

  private static func retryAfter(from response: HTTPURLResponse) -> Double {
    guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
      let prefix = raw.split(whereSeparator: { !$0.isNumber && $0 != "." }).first,
      let value = Double(prefix)
    else {
      return 5
    }
    return value > 0 ? value : 5
  }

  private static func boundedResponseText(_ data: Data) -> String {
    let raw = String(decoding: data.prefix(1_000), as: UTF8.self)
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? "No response body" : raw
  }
}

private struct RateLimitResponse: Decodable, Sendable {
  let retryAfter: Double
  let global: Bool?

  enum CodingKeys: String, CodingKey {
    case retryAfter = "retry_after"
    case global
  }
}

private struct MessageSearchWireResponse: Decodable, Sendable {
  let totalResults: Int
  let messages: [[DiscordMessage]]
  let doingDeepHistoricalIndex: Bool?
  let documentsIndexed: Int?

  enum CodingKeys: String, CodingKey {
    case totalResults = "total_results"
    case messages
    case doingDeepHistoricalIndex = "doing_deep_historical_index"
    case documentsIndexed = "documents_indexed"
  }
}

private struct AllowedMentions: Codable, Sendable {
  let parse: [String]
}

private struct MessageReference: Codable, Sendable {
  let messageID: String
  let channelID: String

  enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case channelID = "channel_id"
  }
}

private struct NewMessage: Codable, Sendable {
  let content: String
  let nonce: String
  let tts: Bool
  let allowedMentions: AllowedMentions
  let messageReference: MessageReference?
  let attachments: [UploadAttachment]?

  enum CodingKeys: String, CodingKey {
    case content
    case nonce
    case tts
    case allowedMentions = "allowed_mentions"
    case messageReference = "message_reference"
    case attachments
  }
}

private struct EditMessage: Codable, Sendable {
  let content: String
  let allowedMentions: AllowedMentions
  let attachments: [UploadAttachment]?

  enum CodingKeys: String, CodingKey {
    case content
    case allowedMentions = "allowed_mentions"
    case attachments
  }
}

private struct UploadAttachment: Codable, Sendable {
  let id: Int
  let filename: String
  let uploadedFilename: String?

  init(id: Int, filename: String, uploadedFilename: String? = nil) {
    self.id = id
    self.filename = filename
    self.uploadedFilename = uploadedFilename
  }

  enum CodingKeys: String, CodingKey {
    case id
    case filename
    case uploadedFilename = "uploaded_filename"
  }
}

private struct UploadFile: Sendable {
  let url: URL
  let size: Int
  let filename: String
  let contentType: String
}

private struct CloudUploadRequest: Encodable, Sendable {
  let files: [CloudUploadFile]
}

private struct CloudUploadFile: Encodable, Sendable {
  let filename: String
  let fileSize: Int

  enum CodingKeys: String, CodingKey {
    case filename
    case fileSize = "file_size"
  }
}

private struct CloudUploadResponse: Decodable, Sendable {
  let attachments: [CloudUploadEntry]
}

private struct CloudUploadEntry: Decodable, Sendable {
  let uploadURL: String
  let uploadFilename: String

  enum CodingKeys: String, CodingKey {
    case uploadURL = "upload_url"
    case uploadFilename = "upload_filename"
  }
}

private struct ThreadArchiveUpdate: Codable, Sendable {
  let archived: Bool
}

private struct ChannelCreation: Codable, Sendable {
  let name: String
  let type: Int
  let parentID: String?

  enum CodingKeys: String, CodingKey {
    case name
    case type
    case parentID = "parent_id"
  }
}

private struct ChannelRename: Codable, Sendable {
  let name: String
}

extension Data {
  fileprivate mutating func appendUTF8(_ value: String) {
    append(Data(value.utf8))
  }
}

private struct NewForumPost: Codable, Sendable {
  let name: String
  let autoArchiveDuration: Int
  let message: NewMessage
  let appliedTags: [String]

  enum CodingKeys: String, CodingKey {
    case name
    case autoArchiveDuration = "auto_archive_duration"
    case message
    case appliedTags = "applied_tags"
  }
}
