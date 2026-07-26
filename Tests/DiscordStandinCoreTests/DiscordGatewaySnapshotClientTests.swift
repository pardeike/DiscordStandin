import Foundation
import Testing

@testable import DiscordStandinCore

@Suite("Discord Gateway snapshot")
struct DiscordGatewaySnapshotClientTests {
  @Test("Decodes channels and active threads from a user READY snapshot")
  func readySnapshot() throws {
    let data = Data(
      """
      {
        "op": 0,
        "t": "READY",
        "s": 1,
        "d": {
          "guilds": [
            {
              "id": "1",
              "channels": [
                {
                  "id": "10",
                  "type": 15,
                  "guild_id": "1",
                  "name": "mod-updates",
                  "position": 2,
                  "available_tags": []
                }
              ],
              "threads": [
                {
                  "id": "11",
                  "type": 11,
                  "guild_id": "1",
                  "parent_id": "10",
                  "owner_id": "42",
                  "name": "Sheep Happens",
                  "position": 0,
                  "thread_metadata": {
                    "archived": false,
                    "archive_timestamp": "2026-07-26T00:00:00.000000+00:00",
                    "auto_archive_duration": 4320,
                    "locked": false
                  }
                }
              ]
            }
          ]
        }
      }
      """.utf8
    )

    let snapshot = try DiscordGatewaySnapshotClient.snapshot(
      fromReadyData: data,
      guildID: "1"
    )

    #expect(snapshot.channels.count == 1)
    #expect(snapshot.channels[0].kind == "forum")
    #expect(snapshot.channels[0].name == "mod-updates")
    #expect(snapshot.activeThreads.count == 1)
    #expect(snapshot.activeThreads[0].parentID == "10")
    #expect(snapshot.activeThreads[0].ownerID == "42")
    #expect(snapshot.activeThreads[0].name == "Sheep Happens")
  }
}
