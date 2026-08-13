import Foundation
import Testing

@testable import DiscordStandinCore

@Suite("Discord REST client")
struct DiscordRESTClientTests {
  private let baseURL = URL(string: "https://example.test/api/v9")!
  private let profile = DiscordClientProfile(
    userAgent: "DiscordStandinTests/1",
    superProperties: "test-properties"
  )

  @Test("Authenticates as a user token and decodes the current user")
  func currentUser() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/users/@me": [
        .json(
          #"{"id":"42","username":"andreas","global_name":"Andreas","discriminator":"0","avatar":null}"#
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let user = try await client.currentUser()

    #expect(user.id == "42")
    #expect(user.displayName == "Andreas")
    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "secret-user-token")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") != "Bot secret-user-token")
    #expect(requests[0].value(forHTTPHeaderField: "X-Super-Properties") == "test-properties")
  }

  @Test("Retries a bounded Discord rate limit")
  func rateLimitRetry() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/users/@me": [
        .json(#"{"retry_after":0.1}"#, status: 429),
        .json(
          #"{"id":"42","username":"andreas","global_name":null,"discriminator":"0","avatar":null}"#),
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let user = try await client.currentUser()

    #expect(user.id == "42")
    #expect(await transport.recordedRequests().count == 2)
  }

  @Test("Waits proactively when a successful response exhausts a rate-limit bucket")
  func proactiveRateLimitWait() async throws {
    let response =
      #"{"id":"42","username":"andreas","global_name":null,"discriminator":"0","avatar":null}"#
    let transport = StubTransport(routes: [
      "/api/v9/users/@me": [
        .json(
          response,
          headers: [
            "X-RateLimit-Bucket": "current-user",
            "X-RateLimit-Remaining": "0",
            "X-RateLimit-Reset-After": "0.1",
          ]
        ),
        .json(response),
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile,
      rateLimiter: DiscordRateLimiter()
    )

    _ = try await client.currentUser()
    let clock = ContinuousClock()
    let start = clock.now
    _ = try await client.currentUser()

    #expect(start.duration(to: clock.now) >= .milliseconds(80))
    #expect(await transport.recordedRequests().count == 2)
  }

  @Test("Posts a message with suppressed automatic mentions")
  func postMessage() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages": [
        .json(
          #"{"id":"200","channel_id":"100","guild_id":"300","content":"Release ready","timestamp":"2026-07-26T00:00:00.000000+00:00","author":null,"flags":0}"#
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let message = try await client.postMessage(
      channelID: "100",
      content: "Release ready"
    )

    #expect(message.id == "200")
    let body = try #require(await transport.recordedRequests().first?.httpBody)
    let object = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["content"] as? String == "Release ready")
    #expect((object["nonce"] as? String)?.count == 25)
    let mentions = try #require(object["allowed_mentions"] as? [String: Any])
    #expect((mentions["parse"] as? [String]) == [])
  }

  @Test("Posts a message with an explicitly enabled everyone mention")
  func postMessageEveryoneMention() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages": [
        .json(
          #"{"id":"200","channel_id":"100","guild_id":"300","content":"Release ping: @everyone","mention_everyone":true,"timestamp":"2026-07-26T00:00:00.000000+00:00","author":null,"flags":0}"#
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let message = try await client.postMessage(
      channelID: "100",
      content: "Release ping: @everyone",
      allowEveryoneMention: true
    )

    #expect(message.mentionEveryone == true)
    let body = try #require(await transport.recordedRequests().first?.httpBody)
    let object = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let mentions = try #require(object["allowed_mentions"] as? [String: Any])
    #expect((mentions["parse"] as? [String]) == ["everyone"])
  }

  @Test("Crossposts a message from an announcement channel")
  func crosspostMessage() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages/200/crosspost": [
        .json(
          #"{"id":"200","channel_id":"100","guild_id":"300","content":"Release ready","mention_everyone":true,"timestamp":"2026-07-26T00:00:00.000000+00:00","author":null,"flags":1}"#
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let message = try await client.crosspostMessage(
      channelID: "100",
      messageID: "200"
    )

    #expect(message.flags == 1)
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "POST")
    #expect(request.httpBody == nil)
  }

  @Test("Edits a message with a PATCH and suppressed automatic mentions")
  func editMessage() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages/200": [
        .json(
          #"{"id":"200","channel_id":"100","guild_id":"300","content":"Standard content","timestamp":"2026-07-26T00:00:00.000000+00:00","author":null,"flags":0}"#
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let message = try await client.editMessage(
      channelID: "100",
      messageID: "200",
      content: "Standard content"
    )

    #expect(message.id == "200")
    #expect(message.content == "Standard content")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "PATCH")
    let body = try #require(request.httpBody)
    let object = try #require(
      JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(object["content"] as? String == "Standard content")
    let mentions = try #require(object["allowed_mentions"] as? [String: Any])
    #expect((mentions["parse"] as? [String]) == [])
  }

  @Test("Edits a message with a multipart replacement image")
  func editMessageImage() async throws {
    let image = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
    let imageURL = try temporaryImage(data: image)
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages/200": [
        .json(
          """
          {
            "id":"200",
            "channel_id":"100",
            "guild_id":"300",
            "content":"Standard content",
            "timestamp":"2026-07-26T00:00:00.000000+00:00",
            "author":null,
            "flags":0,
            "attachments":[{
              "id":"201",
              "filename":"Preview.png",
              "content_type":"image/png",
              "size":7,
              "url":"https://cdn.example/Preview.png",
              "proxy_url":"https://media.example/Preview.png"
            }]
          }
          """
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile,
      rateLimiter: DiscordRateLimiter()
    )

    let message = try await client.editMessage(
      channelID: "100",
      messageID: "200",
      content: "Standard content",
      imagePath: imageURL.path
    )

    #expect(message.attachments?.first?.filename == "Preview.png")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "PATCH")
    let body = try #require(request.httpBody)
    #expect(body.range(of: image) != nil)
    let payload = try multipartPayload(from: request)
    #expect(payload["content"] as? String == "Standard content")
    let attachments = try #require(payload["attachments"] as? [[String: Any]])
    #expect(attachments.first?["id"] as? Int == 0)
    #expect(attachments.first?["filename"] as? String == "Preview.png")
  }

  @Test("Deletes one exact message with no request body")
  func deleteMessage() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages/200": [
        .json("", status: 204)
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile,
      rateLimiter: DiscordRateLimiter()
    )

    try await client.deleteMessage(channelID: "100", messageID: "200")

    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "DELETE")
    #expect(request.httpBody == nil)
  }

  @Test("Creates a forum thread with a multipart starter image")
  func createForumPostImage() async throws {
    let image = Data([0x89, 0x50, 0x4E, 0x47, 0x04, 0x05, 0x06])
    let imageURL = try temporaryImage(data: image)
    defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }
    let transport = StubTransport(routes: [
      "/api/v9/channels/50/threads": [
        .json(
          #"{"id":"400","type":11,"guild_id":"300","parent_id":"50","owner_id":"42","name":"[1.6] Mod","position":0,"thread_metadata":{"archived":false}}"#
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile,
      rateLimiter: DiscordRateLimiter()
    )

    let thread = try await client.createForumPost(
      channelID: "50",
      title: "[1.6] Mod",
      content: "Standard content",
      appliedTagIDs: [],
      autoArchiveDuration: 4_320,
      imagePath: imageURL.path
    )

    #expect(thread.id == "400")
    let request = try #require(await transport.recordedRequests().first)
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    #expect(body.range(of: image) != nil)
    let payload = try multipartPayload(from: request)
    #expect(payload["name"] as? String == "[1.6] Mod")
    let message = try #require(payload["message"] as? [String: Any])
    #expect(message["content"] as? String == "Standard content")
    let attachments = try #require(message["attachments"] as? [[String: Any]])
    #expect(attachments.first?["id"] as? Int == 0)
    #expect(attachments.first?["filename"] as? String == "Preview.png")
  }

  @Test("Reads one exact message around its snowflake")
  func getMessage() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages": [
        .json(
          """
          [
            {
              "id":"200",
              "channel_id":"100",
              "guild_id":"300",
              "content":"Reference release post",
              "timestamp":"2026-07-26T00:00:00.000000+00:00",
              "author":null,
              "flags":0,
              "attachments":[],
              "embeds":[{"title":"Release","type":"rich","description":"Details","url":null,"timestamp":null,"fields":[]}]
            }
          ]
          """
        )
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let message = try await client.message(channelID: "100", messageID: "200")

    #expect(message.content == "Reference release post")
    #expect(message.embeds?.first?.title == "Release")
    let request = try #require(await transport.recordedRequests().first)
    let components = try #require(
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
    )
    #expect(components.queryItems?.contains(URLQueryItem(name: "around", value: "200")) == true)
  }

  @Test("Retries Discord search indexing and preserves channel scope")
  func searchMessages() async throws {
    let searchJSON = """
      {
        "total_results": 1,
        "messages": [
          [
            {
              "id":"200",
              "channel_id":"100",
              "guild_id":"300",
              "content":"Sheep Happens 1.7",
              "timestamp":"2026-07-26T00:00:00.000000+00:00",
              "author":{"id":"42","username":"andreas","global_name":"Andreas","discriminator":"0","avatar":null},
              "flags":0
            },
            {
              "id":"199",
              "channel_id":"100",
              "guild_id":"300",
              "content":"Context",
              "timestamp":"2026-07-25T00:00:00.000000+00:00",
              "author":null,
              "flags":0
            }
          ]
        ],
        "doing_deep_historical_index": false,
        "documents_indexed": 123
      }
      """
    let transport = StubTransport(routes: [
      "/api/v9/guilds/300/messages/search": [
        .json("", status: 202, headers: ["Retry-After": "0.1"]),
        .json(searchJSON),
      ]
    ])
    let client = DiscordRESTClient(
      token: "secret-user-token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let results = try await client.searchMessages(
      guildID: "300",
      content: "Sheep Happens",
      channelID: "100",
      offset: 25,
      sortBy: "relevance"
    )

    #expect(results.totalResults == 1)
    #expect(results.hits.first?.message.id == "200")
    #expect(results.hits.first?.context.map(\.id) == ["199"])
    #expect(results.hits.first?.url == "https://discord.com/channels/300/100/200")
    let requests = await transport.recordedRequests()
    #expect(requests.count == 2)
    let firstQuery = URLComponents(
      url: requests[0].url!,
      resolvingAgainstBaseURL: false
    )?.queryItems
    let secondQuery = URLComponents(
      url: requests[1].url!,
      resolvingAgainstBaseURL: false
    )?.queryItems
    #expect(firstQuery?.contains(URLQueryItem(name: "channel_id", value: "100")) == true)
    #expect(firstQuery?.contains(URLQueryItem(name: "offset", value: "25")) == true)
    #expect(secondQuery?.contains(URLQueryItem(name: "attempts", value: "1")) == true)
  }
}

@Suite("Discord operations")
struct DiscordOperationsTests {
  private let baseURL = URL(string: "https://example.test/api/v9")!
  private let profile = DiscordClientProfile(
    userAgent: "DiscordStandinTests/1",
    superProperties: "test-properties"
  )

  @Test("Reports a missing session without making a request")
  func missingSession() async {
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: nil),
      baseURL: baseURL,
      transport: StubTransport(routes: [:]),
      profile: profile
    )

    let status = await operations.sessionStatus()

    #expect(status.hasStoredCredential == false)
    #expect(status.authenticated == false)
    #expect(status.error == nil)
  }

  @Test("Temporarily unarchives a thread while editing its starter message")
  func editArchivedThreadMessage() async throws {
    let threadJSON =
      #"{"id":"100","type":11,"guild_id":"300","parent_id":"50","owner_id":"42","name":"Mod","position":0,"thread_metadata":{"archived":%ARCHIVED%}}"#
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages/100": [
        .json(#"{"message":"Thread is archived","code":50083}"#, status: 400),
        .json(
          #"{"id":"100","channel_id":"100","guild_id":"300","content":"Standard content","timestamp":"2026-07-26T00:00:00.000000+00:00","author":null,"flags":0}"#
        ),
      ],
      "/api/v9/channels/100": [
        .json(threadJSON.replacingOccurrences(of: "%ARCHIVED%", with: "false")),
        .json(threadJSON.replacingOccurrences(of: "%ARCHIVED%", with: "true")),
      ],
    ])
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: "token"),
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let result = try await operations.editMessage(
      channelID: "100",
      messageID: "100",
      content: "Standard content"
    )

    #expect(result.message.content == "Standard content")
    let requests = await transport.recordedRequests()
    #expect(requests.map(\.httpMethod) == ["PATCH", "PATCH", "PATCH", "PATCH"])
    #expect(
      requests.map(\.url?.path) == [
        "/api/v9/channels/100/messages/100",
        "/api/v9/channels/100",
        "/api/v9/channels/100/messages/100",
        "/api/v9/channels/100",
      ])
    let unarchiveBody = try #require(requests[1].httpBody)
    let restoreBody = try #require(requests[3].httpBody)
    let unarchive = try #require(
      JSONSerialization.jsonObject(with: unarchiveBody) as? [String: Bool]
    )
    let restore = try #require(
      JSONSerialization.jsonObject(with: restoreBody) as? [String: Bool]
    )
    #expect(unarchive["archived"] == false)
    #expect(restore["archived"] == true)
  }

  @Test("Treats publishing an already-crossposted message as successful")
  func publishAlreadyCrosspostedMessage() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages": [
        .json(
          #"[{"id":"200","channel_id":"100","guild_id":"300","content":"Release ready","mention_everyone":true,"timestamp":"2026-07-26T00:00:00.000000+00:00","author":null,"flags":1}]"#
        )
      ]
    ])
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: "token"),
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let result = try await operations.publishMessage(
      channelID: "100",
      messageID: "200"
    )

    #expect(result.alreadyPublished)
    #expect(result.message.flags == 1)
    #expect(await transport.recordedRequests().count == 1)
  }

  @Test("Dry-runs an exact deletion batch without mutating Discord")
  func planMessageDeletion() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages": [
        .json(messageListJSON(id: "200", content: "First")),
        .json(messageListJSON(id: "201", content: "Second")),
      ]
    ])
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: "token"),
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let plan = try await operations.planMessageDeletion(
      channelID: "100",
      messageIDs: ["200", "201"]
    )

    #expect(plan.channelID == "100")
    #expect(plan.messageCount == 2)
    #expect(plan.messages.map(\.id) == ["200", "201"])
    let requests = await transport.recordedRequests()
    #expect(requests.map(\.httpMethod) == ["GET", "GET"])
  }

  @Test("Preflights the complete deletion batch before deleting")
  func deleteMessages() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages": [
        .json(messageListJSON(id: "200", content: "First")),
        .json(messageListJSON(id: "201", content: "Second")),
      ],
      "/api/v9/channels/100/messages/200": [.json("", status: 204)],
      "/api/v9/channels/100/messages/201": [.json("", status: 204)],
    ])
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: "token"),
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    let receipt = try await operations.deleteMessages(
      channelID: "100",
      messageIDs: ["200", "201"],
      expectedMessageCount: 2
    )

    #expect(receipt.success)
    #expect(receipt.deletedMessageIDs == ["200", "201"])
    #expect(receipt.failures.isEmpty)
    let requests = await transport.recordedRequests()
    #expect(requests.map(\.httpMethod) == ["GET", "GET", "DELETE", "DELETE"])
    #expect(
      requests.map(\.url?.path) == [
        "/api/v9/channels/100/messages",
        "/api/v9/channels/100/messages",
        "/api/v9/channels/100/messages/200",
        "/api/v9/channels/100/messages/201",
      ])
  }

  @Test("Does not delete when any preflight target is missing")
  func deletionPreflightFailure() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/100/messages": [
        .json(messageListJSON(id: "200", content: "First")),
        .json("[]"),
      ]
    ])
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: "token"),
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    do {
      _ = try await operations.deleteMessages(
        channelID: "100",
        messageIDs: ["200", "201"],
        expectedMessageCount: 2
      )
      Issue.record("Expected the missing message to fail the preflight")
    } catch let error as DiscordStandinError {
      guard case .invalidDeletion(let message) = error else {
        Issue.record("Expected invalidDeletion, got \(error)")
        return
      }
      #expect(message.contains("201"))
    }

    let requests = await transport.recordedRequests()
    #expect(requests.map(\.httpMethod) == ["GET", "GET"])
  }

  @Test("Rejects duplicate IDs and an incorrect expected count before requests")
  func deletionInputGuards() async throws {
    let transport = StubTransport(routes: [:])
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: "token"),
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    do {
      _ = try await operations.planMessageDeletion(
        channelID: "100",
        messageIDs: ["200", "200"]
      )
      Issue.record("Expected duplicate IDs to be rejected")
    } catch let error as DiscordStandinError {
      guard case .invalidDeletion(let message) = error else {
        Issue.record("Expected invalidDeletion, got \(error)")
        return
      }
      #expect(message.contains("duplicates"))
    }

    do {
      _ = try await operations.deleteMessages(
        channelID: "100",
        messageIDs: ["200"],
        expectedMessageCount: 2
      )
      Issue.record("Expected the count mismatch to be rejected")
    } catch let error as DiscordStandinError {
      guard case .invalidDeletion(let message) = error else {
        Issue.record("Expected invalidDeletion, got \(error)")
        return
      }
      #expect(message.contains("does not match"))
    }

    #expect(await transport.recordedRequests().isEmpty)
  }

  @Test("Filters active threads to the requested forum")
  func forumPosts() async throws {
    let archivedJSON = """
        {
          "threads": [
            {
              "id":"12",
              "type":11,
              "guild_id":"1",
              "parent_id":"10",
              "owner_id":"42",
              "name":"Older Sheep Happens",
              "position":2,
              "thread_metadata":{
                "archived":true,
                "archive_timestamp":"2026-07-20T12:00:00.000000+00:00"
              }
            }
          ],
          "has_more": true
        }
      """
    let transport = StubTransport(routes: [
      "/api/v9/channels/10/threads/archived/public": [.json(archivedJSON)]
    ])
    let operations = DiscordOperations(
      credentials: MemoryCredentialStore(token: "token"),
      baseURL: baseURL,
      transport: transport,
      profile: profile,
      gateway: StubGatewaySnapshotProvider(
        snapshot: DiscordServerChannels(
          channels: [],
          activeThreads: [
            try JSONDecoder().decode(
              DiscordChannel.self,
              from: Data(
                #"{"id":"11","type":11,"guild_id":"1","parent_id":"10","name":"Sheep Happens","position":1}"#
                  .utf8
              )
            ),
            try JSONDecoder().decode(
              DiscordChannel.self,
              from: Data(
                #"{"id":"21","type":11,"guild_id":"1","parent_id":"20","name":"Other","position":2}"#
                  .utf8
              )
            ),
          ]
        )
      )
    )

    let posts = try await operations.listForumPosts(
      serverID: "1",
      forumChannelID: "10",
      includeArchived: true
    )

    #expect(posts.active.map(\.id) == ["11"])
    #expect(posts.archived.map(\.id) == ["12"])
    #expect(posts.archived.first?.ownerID == "42")
    #expect(posts.archivedHasMore)
    #expect(posts.nextArchivedBefore == "2026-07-20T12:00:00.000000+00:00")
    let requests = await transport.recordedRequests()
    let requestURL = try #require(requests.first?.url)
    let queryItems = URLComponents(
      url: requestURL,
      resolvingAgainstBaseURL: false
    )?.queryItems
    #expect(queryItems?.first(where: { $0.name == "limit" })?.value == "100")
    #expect(queryItems?.contains(where: { $0.name == "before" }) == false)
  }

  @Test("Encodes archived thread timestamp cursors without changing plus signs")
  func archivedThreadCursor() async throws {
    let transport = StubTransport(routes: [
      "/api/v9/channels/10/threads/archived/public": [
        .json(#"{"threads":[],"has_more":false}"#)
      ]
    ])
    let client = DiscordRESTClient(
      token: "token",
      baseURL: baseURL,
      transport: transport,
      profile: profile
    )

    _ = try await client.publicArchivedThreads(
      channelID: "10",
      beforeArchiveTimestamp: "2026-07-25T12:00:00.000000+00:00"
    )

    let requests = await transport.recordedRequests()
    let requestURL = try #require(requests.first?.url)
    let queryItems = URLComponents(
      url: requestURL,
      resolvingAgainstBaseURL: false
    )?.queryItems
    #expect(
      queryItems?.first(where: { $0.name == "before" })?.value
        == "2026-07-25T12:00:00.000000+00:00")
    #expect(requestURL.absoluteString.contains("%2B00:00"))
  }
}

private func temporaryImage(data: Data) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("DiscordStandinTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory,
    withIntermediateDirectories: true
  )
  let imageURL = directory.appendingPathComponent("Preview.png")
  try data.write(to: imageURL)
  return imageURL
}

private func messageListJSON(id: String, content: String) -> String {
  """
  [{
    "id":"\(id)",
    "channel_id":"100",
    "guild_id":"300",
    "content":"\(content)",
    "timestamp":"2026-07-26T00:00:00.000000+00:00",
    "author":null,
    "flags":0
  }]
  """
}

private func multipartPayload(from request: URLRequest) throws -> [String: Any] {
  let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
  let boundary = try #require(
    contentType.split(separator: "boundary=").last.map(String.init)
  )
  let body = try #require(request.httpBody)
  let text = String(decoding: body, as: UTF8.self)
  let prefix = "Content-Type: application/json\r\n\r\n"
  let payloadStart = try #require(text.range(of: prefix)?.upperBound)
  let payloadEnd = try #require(
    text.range(of: "\r\n--\(boundary)", range: payloadStart..<text.endIndex)?.lowerBound
  )
  let payload = Data(text[payloadStart..<payloadEnd].utf8)
  return try #require(
    JSONSerialization.jsonObject(with: payload) as? [String: Any]
  )
}

private struct StubResponse: Sendable {
  let status: Int
  let data: Data
  let headers: [String: String]

  static func json(
    _ text: String,
    status: Int = 200,
    headers: [String: String] = [:]
  ) -> Self {
    Self(status: status, data: Data(text.utf8), headers: headers)
  }
}

private actor StubTransport: DiscordHTTPTransport {
  private var routes: [String: [StubResponse]]
  private var requests: [URLRequest] = []

  init(routes: [String: [StubResponse]]) {
    self.routes = routes
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let path = request.url?.path ?? ""
    guard var responses = routes[path], !responses.isEmpty else {
      throw StubError.noResponse(path)
    }
    let next = responses.removeFirst()
    routes[path] = responses
    var headers = next.headers
    headers["Content-Type"] = "application/json"
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: next.status,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
    return (next.data, response)
  }

  func recordedRequests() -> [URLRequest] {
    requests
  }
}

private enum StubError: Error {
  case noResponse(String)
}

private final class MemoryCredentialStore: CredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: String?

  init(token: String?) {
    self.token = token
  }

  func loadToken() throws -> String? {
    lock.withLock { token }
  }

  func saveToken(_ token: String) throws {
    lock.withLock {
      self.token = token
    }
  }

  func deleteToken() throws {
    lock.withLock {
      token = nil
    }
  }
}

private struct StubGatewaySnapshotProvider:
  DiscordGatewaySnapshotProviding, Sendable
{
  let snapshot: DiscordServerChannels

  func channels(
    token: String,
    profile: DiscordClientProfile,
    guildID: String
  ) async throws -> DiscordServerChannels {
    snapshot
  }
}
