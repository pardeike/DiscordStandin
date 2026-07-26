import Foundation

public struct DiscordUser: Codable, Sendable, Equatable {
  public let id: String
  public let username: String
  public let globalName: String?
  public let discriminator: String?
  public let avatar: String?

  public var displayName: String {
    globalName ?? username
  }

  enum CodingKeys: String, CodingKey {
    case id
    case username
    case globalName = "global_name"
    case discriminator
    case avatar
  }
}

public struct DiscordGuild: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let icon: String?
  public let owner: Bool?
  public let permissions: String?
}

public struct DiscordForumTag: Codable, Sendable, Equatable {
  public let id: String
  public let name: String
  public let moderated: Bool?
  public let emojiID: String?
  public let emojiName: String?

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case moderated
    case emojiID = "emoji_id"
    case emojiName = "emoji_name"
  }
}

public struct DiscordThreadMetadata: Codable, Sendable, Equatable {
  public let archived: Bool
  public let archiveTimestamp: String?
  public let autoArchiveDuration: Int?
  public let locked: Bool?
  public let invitable: Bool?
  public let createTimestamp: String?

  enum CodingKeys: String, CodingKey {
    case archived
    case archiveTimestamp = "archive_timestamp"
    case autoArchiveDuration = "auto_archive_duration"
    case locked
    case invitable
    case createTimestamp = "create_timestamp"
  }
}

public struct DiscordChannel: Codable, Sendable, Equatable {
  public let id: String
  public let type: Int
  public let guildID: String?
  public let parentID: String?
  public let ownerID: String?
  public let name: String?
  public let position: Int?
  public let lastMessageID: String?
  public let threadMetadata: DiscordThreadMetadata?
  public let availableTags: [DiscordForumTag]?
  public let appliedTags: [String]?

  public var kind: String {
    switch type {
    case 0: "text"
    case 1: "dm"
    case 2: "voice"
    case 3: "group_dm"
    case 4: "category"
    case 5: "announcement"
    case 10: "announcement_thread"
    case 11: "public_thread"
    case 12: "private_thread"
    case 13: "stage"
    case 14: "directory"
    case 15: "forum"
    case 16: "media"
    default: "unknown_\(type)"
    }
  }

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case guildID = "guild_id"
    case parentID = "parent_id"
    case ownerID = "owner_id"
    case name
    case position
    case lastMessageID = "last_message_id"
    case threadMetadata = "thread_metadata"
    case availableTags = "available_tags"
    case appliedTags = "applied_tags"
  }

  enum OutputCodingKeys: String, CodingKey {
    case id
    case type
    case kind
    case guildID
    case parentID
    case ownerID
    case name
    case position
    case lastMessageID
    case threadMetadata
    case availableTags
    case appliedTags
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: OutputCodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(type, forKey: .type)
    try container.encode(kind, forKey: .kind)
    try container.encodeIfPresent(guildID, forKey: .guildID)
    try container.encodeIfPresent(parentID, forKey: .parentID)
    try container.encodeIfPresent(ownerID, forKey: .ownerID)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(position, forKey: .position)
    try container.encodeIfPresent(lastMessageID, forKey: .lastMessageID)
    try container.encodeIfPresent(threadMetadata, forKey: .threadMetadata)
    try container.encodeIfPresent(availableTags, forKey: .availableTags)
    try container.encodeIfPresent(appliedTags, forKey: .appliedTags)
  }
}

public struct DiscordMessage: Codable, Sendable, Equatable {
  public let id: String
  public let channelID: String
  public let guildID: String?
  public let content: String
  public let mentionEveryone: Bool?
  public let timestamp: String?
  public let editedTimestamp: String?
  public let author: DiscordUser?
  public let flags: Int?
  public let pinned: Bool?
  public let attachments: [DiscordAttachment]?
  public let embeds: [DiscordEmbed]?

  enum CodingKeys: String, CodingKey {
    case id
    case channelID = "channel_id"
    case guildID = "guild_id"
    case content
    case mentionEveryone = "mention_everyone"
    case timestamp
    case editedTimestamp = "edited_timestamp"
    case author
    case flags
    case pinned
    case attachments
    case embeds
  }
}

public struct DiscordAttachment: Codable, Sendable, Equatable {
  public let id: String
  public let filename: String
  public let description: String?
  public let contentType: String?
  public let size: Int?
  public let url: String
  public let proxyURL: String?

  enum CodingKeys: String, CodingKey {
    case id
    case filename
    case description
    case contentType = "content_type"
    case size
    case url
    case proxyURL = "proxy_url"
  }
}

public struct DiscordEmbedField: Codable, Sendable, Equatable {
  public let name: String
  public let value: String
  public let inline: Bool?
}

public struct DiscordEmbed: Codable, Sendable, Equatable {
  public let title: String?
  public let type: String?
  public let description: String?
  public let url: String?
  public let timestamp: String?
  public let fields: [DiscordEmbedField]?
}

public struct DiscordThreadList: Codable, Sendable, Equatable {
  public let threads: [DiscordChannel]
  public let hasMore: Bool?

  enum CodingKeys: String, CodingKey {
    case threads
    case hasMore = "has_more"
  }
}

public struct DiscordServerChannels: Codable, Sendable, Equatable {
  public let channels: [DiscordChannel]
  public let activeThreads: [DiscordChannel]
}

public struct DiscordForumPosts: Codable, Sendable, Equatable {
  public let active: [DiscordChannel]
  public let archived: [DiscordChannel]
  public let archivedHasMore: Bool
  public let nextArchivedBefore: String?
}

public struct DiscordSessionStatus: Codable, Sendable, Equatable {
  public let hasStoredCredential: Bool
  public let authenticated: Bool
  public let user: DiscordUser?
  public let error: String?
}

public struct DiscordPostReceipt: Codable, Sendable, Equatable {
  public let message: DiscordMessage
  public let url: String?
}

public struct DiscordMessageResult: Codable, Sendable, Equatable {
  public let message: DiscordMessage
  public let url: String?
}

public struct DiscordPublishReceipt: Codable, Sendable, Equatable {
  public let message: DiscordMessage
  public let url: String?
  public let alreadyPublished: Bool
}

public struct DiscordMessageSearchHit: Codable, Sendable, Equatable {
  public let message: DiscordMessage
  public let context: [DiscordMessage]
  public let url: String?
}

public struct DiscordMessageSearchResults: Codable, Sendable, Equatable {
  public let totalResults: Int
  public let hits: [DiscordMessageSearchHit]
  public let doingDeepHistoricalIndex: Bool?
  public let documentsIndexed: Int?
}

public struct DiscordForumPostReceipt: Codable, Sendable, Equatable {
  public let thread: DiscordChannel
  public let url: String?
}
