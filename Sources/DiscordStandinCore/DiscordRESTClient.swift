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
    allowEveryoneMention: Bool = false
  ) async throws -> DiscordMessage {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DiscordStandinError.emptyContent
    }

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
      attachments: nil
    )
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
    imagePath: String? = nil
  ) async throws -> DiscordMessage {
    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DiscordStandinError.emptyContent
    }

    let image = try imagePath.map(Self.imageFile)
    let payload = EditMessage(
      content: content,
      allowedMentions: AllowedMentions(parse: []),
      attachments: image.map {
        [UploadAttachment(id: 0, filename: $0.filename)]
      }
    )
    if let image {
      return try await multipart(
        method: "PATCH",
        path: "channels/\(channelID)/messages/\(messageID)",
        body: payload,
        file: image
      )
    }
    return try await patch(
      path: "channels/\(channelID)/messages/\(messageID)",
      body: payload
    )
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
    imagePath: String? = nil
  ) async throws -> DiscordChannel {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DiscordStandinError.emptyContent
    }

    let image = try imagePath.map(Self.imageFile)
    let starter = NewMessage(
      content: content,
      nonce: Self.nonce(),
      tts: false,
      allowedMentions: AllowedMentions(parse: []),
      messageReference: nil,
      attachments: image.map {
        [UploadAttachment(id: 0, filename: $0.filename)]
      }
    )
    let payload = NewForumPost(
      name: title,
      autoArchiveDuration: autoArchiveDuration,
      message: starter,
      appliedTags: appliedTagIDs
    )
    let path = "channels/\(channelID)/threads"
    if let image {
      return try await multipart(
        method: "POST",
        path: path,
        body: payload,
        file: image
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
    file: ImageFile
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
    bodyData.append(file.data)
    bodyData.appendUTF8("\r\n--\(boundary)--\r\n")
    guard bodyData.count <= 25 * 1_024 * 1_024 else {
      throw DiscordStandinError.invalidImage(
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

  private static func imageFile(atPath path: String) throws -> ImageFile {
    let expandedPath = (path as NSString).expandingTildeInPath
    guard (expandedPath as NSString).isAbsolutePath else {
      throw DiscordStandinError.invalidImage("image_path must be absolute")
    }
    let url = URL(fileURLWithPath: expandedPath, isDirectory: false)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw DiscordStandinError.invalidImage("file does not exist: \(expandedPath)")
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
    default:
      throw DiscordStandinError.invalidImage(
        "supported extensions are png, jpg, jpeg, gif, and webp"
      )
    }
    let data: Data
    do {
      data = try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw DiscordStandinError.invalidImage(error.localizedDescription)
    }
    guard !data.isEmpty else {
      throw DiscordStandinError.invalidImage("file is empty")
    }
    let filename = url.lastPathComponent
      .replacingOccurrences(of: "\"", with: "_")
      .replacingOccurrences(of: "\r", with: "_")
      .replacingOccurrences(of: "\n", with: "_")
    return ImageFile(data: data, filename: filename, contentType: contentType)
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
}

private struct ImageFile: Sendable {
  let data: Data
  let filename: String
  let contentType: String
}

private struct ThreadArchiveUpdate: Codable, Sendable {
  let archived: Bool
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
