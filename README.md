# DiscordStandin

DiscordStandin is a local macOS MCP server that uses an existing Discord user
account. It opens Discord's own web login, lets the user complete the normal
login and 2FA flow, stores the resulting account token in the macOS Keychain,
and exposes a deliberately small set of Discord operations to a local MCP
client.

The first iteration is request/response only. It can read and search messages
on demand. Channel discovery makes a short-lived Gateway connection for one
snapshot, then disconnects; it does not observe events or run a daemon.

## Build and install

```sh
./scripts/build-quiet.sh
```

The script runs the tests, builds a release executable, installs the app bundle,
signs it with the first persistent `Developer ID Application` identity in the
login Keychain, verifies the installed signature and MCP handshake, and prints
only `ok` on success. On failure it prints recent diagnostics and the full log
path to stderr. Logs are retained in `.build/logs/`.
`CODESIGN_IDENTITY` can select a different persistent identity.

For local verification without installation, run `./scripts/build-quiet.sh --verify`.
The stdio regression suite checks initialization, all 14 tools, ping, and invalid
request rejection without accessing Discord or account credentials. Installation
runs this suite against the signed release executable too.

Swift MCP SDK 0.12.1 incorrectly requires strings for experimental client
capability values. DiscordStandin ignores these unsupported declarations during
initialization so clients advertising object-valued extensions can connect.
Other fields retain the SDK's normal validation. Remove the transport workaround
when the SDK supports the protocol's object-valued capabilities.

Using a persistent identity is required for stable Keychain authorization
between builds. Do not replace it with ad-hoc signing (`codesign --sign -`).

The default installed executable is:

```text
~/.codex/mcp-servers/discord-standin/DiscordStandin.app/Contents/MacOS/DiscordStandin
```

The install command registers it in `~/.codex/config.toml` when the shared
`/Users/ap/Scripts/mcp-local` helper is available:

```toml
[mcp_servers.discord-standin]
command = "/absolute/home/path/.codex/mcp-servers/discord-standin/DiscordStandin.app/Contents/MacOS/DiscordStandin"
args = ["server"]
```

Restart the MCP host after a new registration or configuration change. To
verify the installed server independently of the host's current tool list, run:

```sh
/Users/ap/Scripts/mcp-local check discord-standin
```

The shared helper can also list configured local MCP servers:

```sh
/Users/ap/Scripts/mcp-local list
```

## Login

Run the installed executable so the Keychain identity is the same one used by
the MCP process:

```sh
~/.codex/mcp-servers/discord-standin/DiscordStandin.app/Contents/MacOS/DiscordStandin login
```

The helper opens `https://discord.com/login` in an ephemeral WebKit session.
Enter credentials and complete any 2FA or challenge in that window. The token
is validated with `GET /users/@me` before it is saved. It is never returned
through MCP.

Useful local checks:

```sh
~/.codex/mcp-servers/discord-standin/DiscordStandin.app/Contents/MacOS/DiscordStandin status
~/.codex/mcp-servers/discord-standin/DiscordStandin.app/Contents/MacOS/DiscordStandin logout
```

## MCP tools

| Tool | Effect |
| --- | --- |
| `discord_login_start` | Opens the interactive Discord login window. |
| `discord_login_status` | Validates the stored session and returns the current user. |
| `discord_logout` | Deletes the stored token after explicit confirmation. |
| `discord_list_servers` | Lists servers visible to the account. |
| `discord_list_channels` | Lists a server's channels and, optionally, active threads. |
| `discord_list_forum_posts` | Lists active and cursor-paginated public archived posts in a forum channel. |
| `discord_get_channel_messages` | Reads recent or cursor-relative messages in a channel or thread. |
| `discord_get_message` | Reads one exact message, including embeds and attachments. |
| `discord_search_messages` | Searches a server, optionally scoped to a channel or thread. |
| `discord_post_message` | Posts a message to a text channel or existing thread, with opt-in `@everyone`/`@here` parsing. |
| `discord_publish_message` | Publishes/crossposts an announcement-channel message, safely succeeding when it was already published. |
| `discord_edit_message` | Replaces an existing message and optionally its single image, temporarily unarchiving and restoring its thread when necessary. |
| `discord_delete_messages` | Dry-runs or permanently deletes an exact guarded batch of messages from one channel. |
| `discord_create_forum_post` | Creates a forum post with its starter message and an optional local image. |

Posting, publishing, and editing tools require `confirmed: true` in the call.
This makes the final destination and complete message explicit at the mutation
boundary. Message posting suppresses all automatic mention parsing by default;
set `allow_everyone_mention: true` only when a visible `@everyone` or `@here`
in the final content should notify the channel.
For a `mod-updates` entry, use `discord_edit_message` to maintain its starter
message; reserve `discord_post_message` comments for actual new-release notes.
In announcement channels, call `discord_publish_message` after the post is
created so following channels receive it.

`discord_delete_messages` uses `confirmed: false` for its non-mutating dry run,
which fetches and returns every exact target. Permanent deletion requires
`confirmed: true` plus an `expected_message_count` equal to the number of unique
supplied IDs. The tool rejects duplicate IDs and preflights the complete batch
before deleting its first message. Its receipt lists every deletion and any
per-message failure so a partial result is never hidden.

`discord_create_forum_post` and `discord_edit_message` accept an optional
`image_path` pointing to a local PNG, JPEG, GIF, or WebP file. `~` is expanded.
Forum creation adds that image to the starter message. On edit, omitting
`image_path` preserves existing attachments; supplying it replaces all existing
attachments with the single uploaded image. The complete multipart request must
fit Discord's 25 MiB request limit.

## Design

- `DiscordStandinCore` owns Keychain access, Discord models, REST transport,
  adaptive rate-limit and conservative request pacing, indexing retry handling,
  one-shot Gateway snapshots, and account operations.
- The executable target adapts those operations to MCP and contains the
  interactive WebKit login UI.
- The same executable launches in `server` or `login` mode so Keychain access
  is associated with one binary identity.
- Discord request headers are isolated in `DiscordClientProfile`, making client
  parity updates independent from tool implementations.

Discord's user-client REST surface is not the bot API and can change without
notice. HTTP failures are returned with bounded diagnostic text, while account
credentials remain redacted.
