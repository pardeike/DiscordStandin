// swift-tools-version: 6.1

import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
  .unsafeFlags(["-warnings-as-errors"])
]

let package = Package(
  name: "DiscordStandin",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "DiscordStandin", targets: ["DiscordStandin"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk.git",
      exact: "0.12.1"
    )
  ],
  targets: [
    .target(
      name: "DiscordStandinCore",
      swiftSettings: strictSwiftSettings,
      linkerSettings: [
        .linkedFramework("Security")
      ]
    ),
    .executableTarget(
      name: "DiscordStandin",
      dependencies: [
        "DiscordStandinCore",
        .product(name: "MCP", package: "swift-sdk"),
      ],
      swiftSettings: strictSwiftSettings,
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("WebKit"),
      ]
    ),
    .testTarget(
      name: "DiscordStandinCoreTests",
      dependencies: ["DiscordStandinCore"],
      swiftSettings: strictSwiftSettings
    ),
  ],
  swiftLanguageModes: [.v6]
)
