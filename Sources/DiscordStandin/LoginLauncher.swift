import Foundation

struct LoginLauncher: Sendable {
  struct LaunchReceipt: Codable, Sendable {
    let launched: Bool
    let processID: Int32
    let message: String
  }

  func launch() throws -> LaunchReceipt {
    let executable = try executableURL()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["login"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return LaunchReceipt(
      launched: true,
      processID: process.processIdentifier,
      message:
        "Discord login window opened. Complete login and 2FA there, then call discord_login_status."
    )
  }

  private func executableURL() throws -> URL {
    if let bundled = Bundle.main.executableURL,
      FileManager.default.isExecutableFile(atPath: bundled.path)
    {
      return bundled
    }

    let argument = CommandLine.arguments[0]
    let candidate: URL
    if argument.hasPrefix("/") {
      candidate = URL(fileURLWithPath: argument)
    } else {
      candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(argument)
    }
    let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
    guard FileManager.default.isExecutableFile(atPath: resolved.path) else {
      throw LoginLaunchError.executableNotFound
    }
    return resolved
  }
}

private enum LoginLaunchError: LocalizedError {
  case executableNotFound

  var errorDescription: String? {
    "Could not locate the DiscordStandin executable for the login helper."
  }
}
