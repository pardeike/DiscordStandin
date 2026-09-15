# DiscordStandin contributor notes

- Preserve the stdio protocol boundary: MCP messages are the only data written to stdout while `server` is running. Diagnostics belong on stderr.
- Never log, print, return, or serialize the Discord account token.
- Keep Discord REST behavior in `DiscordStandinCore`; keep MCP schemas and routing in the executable target.
- Keep message search and retrieval request/response only. A short-lived Gateway connection for an on-demand channel snapshot is allowed; Gateway observation, subscriptions, and a background daemon remain future scope.
- When maintaining an existing `mod-updates` forum entry, edit its starter message in place. Only post a new message in the thread when publishing actual release notes.
- Keep mention parsing opt-in. Only set `allow_everyone_mention` when the final visible content deliberately contains `@everyone` or `@here`; announcement-channel release posts should then be published with `discord_publish_message`.
- Before creating a `mod-updates` entry, exhaustively check active and archived forum titles to prevent duplicates. For a new mod, derive the starter text from `ModDescription.md` and `About/PublishedFileId.txt`, and upload `About/Preview.png` when present.
- Preserve multipart attachment semantics: omitting `image_path` during edit keeps existing attachments; supplying it deliberately replaces them with one image.
- Preserve the process-wide adaptive Discord rate limiter and conservative deterministic pacing. Learn bucket/reset headers, honor the full `retry_after` period, and do not add randomized timing intended to mimic a human.
- Editing a message in an archived thread must temporarily unarchive it and restore the archived state after either success or failure.
- Build, test, sign, install, and verify with `./scripts/build-quiet.sh`. A successful run must print only `ok`; failures must surface the captured diagnostics.
- Use `./scripts/build-quiet.sh --verify` for local tests without installation. Both modes exercise real stdio initialization with object-valued experimental capabilities, tool discovery, and malformed-request rejection. Full workflow logs stay in ignored `.build/logs/`.
- Keep the app signed with a persistent Developer ID identity discovered by `Makefile` or supplied through `CODESIGN_IDENTITY`. Do not use ad-hoc signing because it invalidates the Keychain authorization identity on every build.
