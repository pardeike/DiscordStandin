import Foundation

public struct DiscordClientProfile: Sendable {
  public let userAgent: String
  public let superProperties: String
  public let locale: String

  public init(
    userAgent: String,
    superProperties: String,
    locale: String = "en-US"
  ) {
    self.userAgent = userAgent
    self.superProperties = superProperties
    self.locale = locale
  }

  public static let current: Self = {
    let userAgent =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      + "AppleWebKit/537.36 (KHTML, like Gecko) "
      + "Chrome/149.0.0.0 Safari/537.36"
    let values: [String: Any] = [
      "os": "Mac OS X",
      "browser": "Chrome",
      "device": "",
      "system_locale": "en-US",
      "browser_user_agent": userAgent,
      "browser_version": "149.0.0.0",
      "os_version": "10.15.7",
      "referrer": "",
      "referring_domain": "",
      "release_channel": "stable",
      "client_build_number": 556_969,
      "client_event_source": NSNull(),
      "client_launch_id": UUID().uuidString.lowercased(),
      "client_app_state": "unfocused",
    ]
    let data = try? JSONSerialization.data(withJSONObject: values)
    let encoded = data?.base64EncodedString() ?? ""
    return Self(userAgent: userAgent, superProperties: encoded)
  }()
}
