import Foundation
import Security

public protocol CredentialStore: Sendable {
  func loadToken() throws -> String?
  func saveToken(_ token: String) throws
  func deleteToken() throws
}

public struct KeychainCredentialStore: CredentialStore, Sendable {
  public static let defaultService = "net.pardeike.DiscordStandin"
  public static let defaultAccount = "discord-user-token"

  private let service: String
  private let account: String

  public init(
    service: String = Self.defaultService,
    account: String = Self.defaultAccount
  ) {
    self.service = service
    self.account = account
  }

  public func loadToken() throws -> String? {
    var query = baseQuery
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw DiscordStandinError.keychain(operation: "read", status: status)
    }
    guard let data = result as? Data,
      let token = String(data: data, encoding: .utf8),
      !token.isEmpty
    else {
      throw DiscordStandinError.keychain(operation: "decode", status: errSecDecode)
    }
    return token
  }

  public func saveToken(_ token: String) throws {
    guard !token.isEmpty, let data = token.data(using: .utf8) else {
      throw DiscordStandinError.keychain(operation: "encode", status: errSecParam)
    }

    let updateStatus = SecItemUpdate(
      baseQuery as CFDictionary,
      [kSecValueData: data] as CFDictionary
    )

    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw DiscordStandinError.keychain(operation: "update", status: updateStatus)
    }

    var attributes = baseQuery
    attributes[kSecValueData] = data
    attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let addStatus = SecItemAdd(attributes as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw DiscordStandinError.keychain(operation: "save", status: addStatus)
    }
  }

  public func deleteToken() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw DiscordStandinError.keychain(operation: "delete", status: status)
    }
  }

  private var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
    ]
  }
}
