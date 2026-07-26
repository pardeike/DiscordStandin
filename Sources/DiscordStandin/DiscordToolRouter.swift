import DiscordStandinCore
import Foundation
import MCP

struct DiscordToolRouter: Sendable {
  private let operations: DiscordOperations
  private let loginLauncher: LoginLauncher

  init(
    operations: DiscordOperations = DiscordOperations(),
    loginLauncher: LoginLauncher = LoginLauncher()
  ) {
    self.operations = operations
    self.loginLauncher = loginLauncher
  }

  static var tools: [Tool] {
    [
      Tool(
        name: "discord_login_start",
        description:
          "Open the native Discord login window. The user completes Discord login, 2FA, and challenges manually; the token stays in Keychain.",
        inputSchema: schema(properties: [:]),
        annotations: .init(
          title: "Start Discord Login",
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: true
        )
      ),
      Tool(
        name: "discord_login_status",
        description:
          "Validate the Keychain session and return the authenticated Discord user without exposing the token.",
        inputSchema: schema(properties: [:]),
        annotations: .init(
          title: "Discord Login Status",
          readOnlyHint: true,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: true
        )
      ),
      Tool(
        name: "discord_logout",
        description:
          "Delete the Discord account token from macOS Keychain. Requires confirmed=true.",
        inputSchema: schema(
          properties: [
            "confirmed": booleanProperty("Must be true to delete the stored session.")
          ],
          required: ["confirmed"]
        ),
        annotations: .init(
          title: "Log Out DiscordStandin",
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: true,
          openWorldHint: false
        )
      ),
      Tool(
        name: "discord_list_servers",
        description: "List Discord servers visible to the authenticated account.",
        inputSchema: schema(properties: [:]),
        annotations: readOnlyAnnotations(title: "List Discord Servers")
      ),
      Tool(
        name: "discord_list_channels",
        description: "List channels in a Discord server, with active threads included by default.",
        inputSchema: schema(
          properties: [
            "server_id": stringProperty("Discord server/guild snowflake."),
            "include_active_threads": booleanProperty(
              "Include active server threads. Defaults to true."),
          ],
          required: ["server_id"]
        ),
        annotations: readOnlyAnnotations(title: "List Discord Channels")
      ),
      Tool(
        name: "discord_list_forum_posts",
        description:
          "List active posts and one page of up to 100 public archived posts for a Discord forum channel. When archivedHasMore is true, pass nextArchivedBefore as archived_before to read the next page; cursor pages omit the unchanged active-post list.",
        inputSchema: schema(
          properties: [
            "server_id": stringProperty("Discord server/guild snowflake."),
            "forum_channel_id": stringProperty("Forum channel snowflake."),
            "include_archived": booleanProperty(
              "Include public archived forum posts. Defaults to true."),
            "archived_before": stringProperty(
              "Optional archive timestamp cursor returned as nextArchivedBefore by the previous page."
            ),
          ],
          required: ["server_id", "forum_channel_id"]
        ),
        annotations: readOnlyAnnotations(title: "List Discord Forum Posts")
      ),
      Tool(
        name: "discord_get_channel_messages",
        description:
          "Read messages from a text channel or thread. Returns newest messages by default and supports one before/after/around cursor.",
        inputSchema: schema(
          properties: [
            "channel_id": stringProperty("Text channel or thread snowflake."),
            "limit": integerProperty("Number of messages from 1 through 100. Defaults to 50."),
            "before_message_id": stringProperty("Return messages before this message snowflake."),
            "after_message_id": stringProperty("Return messages after this message snowflake."),
            "around_message_id": stringProperty("Return messages around this message snowflake."),
          ],
          required: ["channel_id"]
        ),
        annotations: readOnlyAnnotations(title: "Read Discord Channel Messages")
      ),
      Tool(
        name: "discord_get_message",
        description:
          "Read one exact Discord message by channel/thread ID and message ID, including text, embeds, and attachments.",
        inputSchema: schema(
          properties: [
            "channel_id": stringProperty("Text channel or thread snowflake."),
            "message_id": stringProperty("Exact message snowflake."),
          ],
          required: ["channel_id", "message_id"]
        ),
        annotations: readOnlyAnnotations(title: "Read Discord Message")
      ),
      Tool(
        name: "discord_search_messages",
        description:
          "Search messages across one Discord server, or narrow the search to one text channel or thread with channel_id. Discord returns pages of 25 results and may briefly build an index.",
        inputSchema: schema(
          properties: [
            "server_id": stringProperty("Discord server/guild snowflake."),
            "query": stringProperty("Text to search for."),
            "channel_id": stringProperty(
              "Optional text channel or thread snowflake that narrows the server-wide search."
            ),
            "author_id": stringProperty("Optional author user snowflake."),
            "offset": integerProperty(
              "Result offset, a multiple of 25 from 0 through 9975. Defaults to 0."
            ),
            "sort_by": stringProperty(
              "timestamp or relevance. Defaults to timestamp."
            ),
            "sort_order": stringProperty("asc or desc. Defaults to desc."),
          ],
          required: ["server_id", "query"]
        ),
        annotations: readOnlyAnnotations(title: "Search Discord Messages")
      ),
      Tool(
        name: "discord_post_message",
        description:
          "Post a complete message as the authenticated user in an existing text channel or thread. Mentions are suppressed unless allow_everyone_mention is explicitly true. Requires confirmed=true.",
        inputSchema: schema(
          properties: [
            "channel_id": stringProperty("Destination text channel or thread snowflake."),
            "content": stringProperty("Complete message content."),
            "reply_to_message_id": stringProperty("Optional message snowflake to reply to."),
            "allow_everyone_mention": booleanProperty(
              "Allow a visible @everyone or @here in content to notify the channel. Defaults to false."
            ),
            "confirmed": booleanProperty("Must be true after destination and content are final."),
          ],
          required: ["channel_id", "content", "confirmed"]
        ),
        annotations: mutationAnnotations(title: "Post Discord Message")
      ),
      Tool(
        name: "discord_publish_message",
        description:
          "Publish/crosspost one existing message from a Discord announcement channel to its followers. Already-published messages return successfully without publishing twice. Requires confirmed=true.",
        inputSchema: schema(
          properties: [
            "channel_id": stringProperty("Announcement channel snowflake."),
            "message_id": stringProperty("Message snowflake to publish."),
            "confirmed": booleanProperty(
              "Must be true after the announcement channel and message are final."),
          ],
          required: ["channel_id", "message_id", "confirmed"]
        ),
        annotations: .init(
          title: "Publish Discord Announcement",
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: true,
          openWorldHint: true
        )
      ),
      Tool(
        name: "discord_edit_message",
        description:
          "Replace the complete content of a message authored by the authenticated user. An optional local image replaces all existing attachments. Archived threads are temporarily unarchived and restored. Requires confirmed=true.",
        inputSchema: schema(
          properties: [
            "channel_id": stringProperty("Channel or thread snowflake containing the message."),
            "message_id": stringProperty("Message snowflake to edit."),
            "content": stringProperty("Complete replacement message content."),
            "image_path": stringProperty(
              "Optional absolute local path to one replacement PNG, JPEG, GIF, or WebP image."
            ),
            "confirmed": booleanProperty(
              "Must be true after the target message and replacement content are final."),
          ],
          required: ["channel_id", "message_id", "content", "confirmed"]
        ),
        annotations: .init(
          title: "Edit Discord Message",
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: true,
          openWorldHint: true
        )
      ),
      Tool(
        name: "discord_create_forum_post",
        description:
          "Create a Discord forum post and starter message as the authenticated user, optionally uploading one local image. Requires confirmed=true.",
        inputSchema: schema(
          properties: [
            "server_id": stringProperty("Discord server/guild snowflake."),
            "forum_channel_id": stringProperty("Destination forum channel snowflake."),
            "title": stringProperty("Forum post title."),
            "content": stringProperty("Complete starter message content."),
            "image_path": stringProperty(
              "Optional absolute local path to one starter PNG, JPEG, GIF, or WebP image."
            ),
            "applied_tag_ids": arrayProperty("Optional forum tag snowflakes.", itemType: "string"),
            "auto_archive_duration": integerProperty(
              "Minutes until inactivity archives the post: 60, 1440, 4320, or 10080. Defaults to 4320."
            ),
            "confirmed": booleanProperty("Must be true after destination and content are final."),
          ],
          required: ["server_id", "forum_channel_id", "title", "content", "confirmed"]
        ),
        annotations: mutationAnnotations(title: "Create Discord Forum Post")
      ),
    ]
  }

  func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
    let arguments = arguments ?? [:]
    do {
      switch name {
      case "discord_login_start":
        return try result(loginLauncher.launch())

      case "discord_login_status":
        return try result(await operations.sessionStatus())

      case "discord_logout":
        try requireConfirmation(arguments)
        try operations.logout()
        return try result(ActionReceipt(success: true, message: "Stored Discord session deleted."))

      case "discord_list_servers":
        return try result(await operations.listServers())

      case "discord_list_channels":
        let serverID = try requiredString("server_id", in: arguments)
        let includeThreads = arguments["include_active_threads"]?.boolValue ?? true
        return try result(
          await operations.listChannels(
            serverID: serverID,
            includeActiveThreads: includeThreads
          )
        )

      case "discord_list_forum_posts":
        let serverID = try requiredString("server_id", in: arguments)
        let forumChannelID = try requiredString("forum_channel_id", in: arguments)
        let includeArchived = arguments["include_archived"]?.boolValue ?? true
        return try result(
          await operations.listForumPosts(
            serverID: serverID,
            forumChannelID: forumChannelID,
            includeArchived: includeArchived,
            archivedBefore: arguments["archived_before"]?.stringValue
          )
        )

      case "discord_get_channel_messages":
        return try result(
          await operations.getChannelMessages(
            channelID: requiredString("channel_id", in: arguments),
            limit: arguments["limit"]?.intValue ?? 50,
            before: arguments["before_message_id"]?.stringValue,
            after: arguments["after_message_id"]?.stringValue,
            around: arguments["around_message_id"]?.stringValue
          )
        )

      case "discord_get_message":
        return try result(
          await operations.getMessage(
            channelID: requiredString("channel_id", in: arguments),
            messageID: requiredString("message_id", in: arguments)
          )
        )

      case "discord_search_messages":
        return try result(
          await operations.searchMessages(
            serverID: requiredString("server_id", in: arguments),
            query: requiredString("query", in: arguments),
            channelID: arguments["channel_id"]?.stringValue,
            authorID: arguments["author_id"]?.stringValue,
            offset: arguments["offset"]?.intValue ?? 0,
            sortBy: arguments["sort_by"]?.stringValue ?? "timestamp",
            sortOrder: arguments["sort_order"]?.stringValue ?? "desc"
          )
        )

      case "discord_post_message":
        try requireConfirmation(arguments)
        return try result(
          await operations.postMessage(
            channelID: requiredString("channel_id", in: arguments),
            content: requiredString("content", in: arguments),
            replyToMessageID: arguments["reply_to_message_id"]?.stringValue,
            allowEveryoneMention: arguments["allow_everyone_mention"]?.boolValue ?? false
          )
        )

      case "discord_publish_message":
        try requireConfirmation(arguments)
        return try result(
          await operations.publishMessage(
            channelID: requiredString("channel_id", in: arguments),
            messageID: requiredString("message_id", in: arguments)
          )
        )

      case "discord_edit_message":
        try requireConfirmation(arguments)
        return try result(
          await operations.editMessage(
            channelID: requiredString("channel_id", in: arguments),
            messageID: requiredString("message_id", in: arguments),
            content: requiredString("content", in: arguments),
            imagePath: arguments["image_path"]?.stringValue
          )
        )

      case "discord_create_forum_post":
        try requireConfirmation(arguments)
        let duration = arguments["auto_archive_duration"]?.intValue ?? 4_320
        guard [60, 1_440, 4_320, 10_080].contains(duration) else {
          throw ToolArgumentError.invalid(
            "auto_archive_duration",
            "expected 60, 1440, 4320, or 10080"
          )
        }
        let tagIDs = try stringArray("applied_tag_ids", in: arguments)
        return try result(
          await operations.createForumPost(
            serverID: requiredString("server_id", in: arguments),
            forumChannelID: requiredString("forum_channel_id", in: arguments),
            title: requiredString("title", in: arguments),
            content: requiredString("content", in: arguments),
            appliedTagIDs: tagIDs,
            autoArchiveDuration: duration,
            imagePath: arguments["image_path"]?.stringValue
          )
        )

      default:
        return errorResult("Unknown DiscordStandin tool: \(name)")
      }
    } catch {
      return errorResult(error.localizedDescription)
    }
  }

  private func result<Output: Codable>(_ output: Output) throws -> CallTool.Result {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(output)
    let text = String(decoding: data, as: UTF8.self)
    return try CallTool.Result(
      content: [.text(text: text, annotations: nil, _meta: nil)],
      structuredContent: output,
      isError: false
    )
  }

  private func errorResult(_ message: String) -> CallTool.Result {
    CallTool.Result(
      content: [.text(text: message, annotations: nil, _meta: nil)],
      structuredContent: .object(["error": .string(message)]),
      isError: true
    )
  }

  private func requiredString(_ name: String, in arguments: [String: Value]) throws -> String {
    guard let value = arguments[name]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw ToolArgumentError.missing(name)
    }
    return value
  }

  private func stringArray(_ name: String, in arguments: [String: Value]) throws -> [String] {
    guard let value = arguments[name] else { return [] }
    guard let values = value.arrayValue else {
      throw ToolArgumentError.invalid(name, "expected an array of strings")
    }
    return try values.map { item in
      guard let string = item.stringValue else {
        throw ToolArgumentError.invalid(name, "expected an array of strings")
      }
      return string
    }
  }

  private func requireConfirmation(_ arguments: [String: Value]) throws {
    guard arguments["confirmed"]?.boolValue == true else {
      throw ToolArgumentError.invalid("confirmed", "must be true")
    }
  }

  private static func schema(
    properties: [String: Value],
    required: [String] = []
  ) -> Value {
    var schema: [String: Value] = [
      "type": .string("object"),
      "properties": .object(properties),
      "additionalProperties": .bool(false),
    ]
    if !required.isEmpty {
      schema["required"] = .array(required.map(Value.string))
    }
    return .object(schema)
  }

  private static func stringProperty(_ description: String) -> Value {
    .object(["type": .string("string"), "description": .string(description)])
  }

  private static func booleanProperty(_ description: String) -> Value {
    .object(["type": .string("boolean"), "description": .string(description)])
  }

  private static func integerProperty(_ description: String) -> Value {
    .object(["type": .string("integer"), "description": .string(description)])
  }

  private static func arrayProperty(_ description: String, itemType: String) -> Value {
    .object([
      "type": .string("array"),
      "description": .string(description),
      "items": .object(["type": .string(itemType)]),
    ])
  }

  private static func readOnlyAnnotations(title: String) -> Tool.Annotations {
    .init(
      title: title,
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: true
    )
  }

  private static func mutationAnnotations(title: String) -> Tool.Annotations {
    .init(
      title: title,
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: true
    )
  }
}

private struct ActionReceipt: Codable, Sendable {
  let success: Bool
  let message: String
}

private enum ToolArgumentError: LocalizedError {
  case missing(String)
  case invalid(String, String)

  var errorDescription: String? {
    switch self {
    case .missing(let name):
      "Missing required argument: \(name)"
    case .invalid(let name, let explanation):
      "Invalid argument \(name): \(explanation)"
    }
  }
}
