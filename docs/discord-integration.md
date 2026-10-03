# Discord integration

Direct first-class Discord bot channel for Firstmate. This integration talks
only to Discord's own APIs (`discord.com`) and never to myfirstmate.io: no
Relay pairing token, poll shim, or Relay wake is involved in Discord traffic.
(`docs/configuration.md` "Relay" remains the owner of the separate hosted
X/Discord-mention Relay; the two integrations share only the bash-contract
conventions below, never credentials or transport.)

## Architecture fit

Firstmate has no TypeScript `ChatIntegration` interface; the existing
abstraction is the Relay bash contract (`.env` secrets via
`bin/fm-env-lib.sh`, env wins over file; private `state/` artifacts at
600/700; inbox/outbox JSON; thread splitting; watcher wakes shaped as
`<kind> <id>`). Discord adapts that contract instead of adding a parallel
one:

| Relay | Discord |
| --- | --- |
| `FMX_PAIRING_TOKEN` | `DISCORD_BOT_TOKEN` (+ client id/secret) |
| `state/x-inbox/<id>.json` + `x-mention <id>` | `state/discord-inbox/<id>.json` + `discord-message <id>` |
| `fmx_split_thread` (280/X, 1900/Discord) | `discord_chunk_text` (1990-unit budget under Discord's 2000-unit limit) |
| Private `state/x-context`, `x-poll.error` | Private `state/discord-seen`, `state/discord-oauth` |

Incoming Discord messages preserve guild, channel, user, message id,
timestamps, and reply/thread context, are deduplicated, ignore the bot's own
messages, are refused outside the configured guild, and are refused unless
the author is the configured owner (see below). These scripts never execute
asks.

## Authorization: owner-only for this pass

Only the linked Firstmate owner may drive the agent through Discord. Set
`DISCORD_OWNER_USER_ID` to that owner's Discord user id (right-click the
user in Discord with Developer Mode on, Copy User ID). Every inbound path
(`fm-discord-poll.sh` message routing and `fm-discord-commands.sh handle`)
checks `discord_authorize_sender` before stashing or waking, and the check
fails closed: an unknown sender, guild, channel, or missing owner/guild
configuration refuses the message. Do not broaden this to other server
members without a new authorization decision. The single
`discord_authorize_sender` function in `bin/fm-discord-lib.sh` is the plug
point where broader policies attach later without rewriting the callers.

## Discord Developer Portal setup

1. Create an application at <https://discord.com/developers/applications>.
2. Bot tab: create/reset the bot token -> `DISCORD_BOT_TOKEN`.
3. General Information: copy Application ID -> `DISCORD_CLIENT_ID`, and the
   client secret -> `DISCORD_CLIENT_SECRET`. Copy the public key ->
   `DISCORD_PUBLIC_KEY` (key schema in `docs/configuration.md`; retained
   only for the `verify` test helper, never consulted on the live path).
4. OAuth2 -> Redirects: add the redirect URI (see below), e.g.
   `http://localhost:8787/discord/callback` (local) or
   `https://<host>/discord/callback` (production).
5. OAuth2 URL Generator: scopes `bot` + `applications.commands`, permissions
   `Send Messages` + `Read Message History` only (bits `67584`). Use
   `fm-discord-setup.sh init` to build this URL instead of hand-writing it.
6. Bot tab -> Privileged Gateway Intents: leave all OFF unless the server
   genuinely needs arbitrary message text (see below). The standard
   `GUILD_MESSAGES` intent below is not privileged.
7. Install the bot into the target server (administrator), set
   `DISCORD_OWNER_USER_ID` in `.env`, then run
   `fm-discord-setup.sh callback` + `verify`, then `register` the slash
   commands. Do NOT set an interactions endpoint URL in the Portal: this
   integration answers slash commands over the gateway (below), so no
   public HTTPS endpoint is needed or used.

## OAuth redirect URL

Local: `http://localhost:8787/discord/callback`. Production:
`https://<your-host>/discord/callback`. The exact URI must match the Portal
entry and `DISCORD_REDIRECT_URI`. The setup flow validates `state`
(CSRF token in `state/discord-oauth/state`) and refuses mismatches closed. State
tokens are single-use (consumed on first success) and expire after ten
minutes; the token itself is never printed, it travels in the operator's
own browser redirect.

## Required scopes, permissions, intents

- Scopes: `bot applications.commands` only.
- Bot permissions: `Send Messages` (2048) + `Read Message History` (65536) =
  `67584`. No administrator, no manage-server, no privileged bits.
- Gateway intents: `GUILDS` (`1`) + `GUILD_MESSAGES` (`512`) = `513`.
  `GUILD_MESSAGES` is the intent that delivers `MESSAGE_CREATE`; without it
  the Gateway connects but no message events ever arrive.

### Message Content intent (isolated opt-in)

Reading arbitrary message content requires Discord's privileged Message
Content intent, because without it the Gateway only delivers message text for
mentions/replies to the bot. To enable: flip the intent in the Portal, set
`DISCORD_MESSAGE_CONTENT=1` in `.env`, and restart the gateway. The flag is
normalized in exactly one place (`discord_load_config`) and only adds the
`1<<15` intent bit, so the default stays minimal and the requirement stays
isolated and auditable.

## Configuration

Secrets live in the home's gitignored `.env` (env wins, same as Relay):

```text
DISCORD_CLIENT_ID=
DISCORD_CLIENT_SECRET=
DISCORD_BOT_TOKEN=
DISCORD_PUBLIC_KEY=
DISCORD_GUILD_ID=
DISCORD_OWNER_USER_ID=
DISCORD_REDIRECT_URI=http://localhost:8787/discord/callback
DISCORD_MESSAGE_CONTENT=
DISCORD_CHANNEL_IDS=
DISCORD_CHANNEL_ID=
DISCORD_NOTIFY_CHANNEL_ID=
DISCORD_SEND_CHANNEL_IDS=
```

`DISCORD_OWNER_USER_ID` is required for inbound routing; until it is set,
every message is refused. `DISCORD_CHANNEL_IDS` is an optional
comma-separated inbound channel allowlist (empty means any channel in the
authorized guild). `DISCORD_CHANNEL_ID` names the REST fallback poll
channel used by the watcher shim when the Gateway is unavailable.
`DISCORD_NOTIFY_CHANNEL_ID` names the outbound-tap notify channel (see
"Outbound tap" below); when unset, the tap falls back to the existing
send-channel behavior (`DISCORD_CHANNEL_ID`, then the first entry of
`DISCORD_CHANNEL_IDS`, then config `poll_channel_id`).
`DISCORD_SEND_CHANNEL_IDS` is an optional outbound channel allowlist for
`fm-discord-send.sh` (empty means any channel the bot can post to).

Non-secret binding (guild name, bot user id, owner id, connected flag)
lives in `config/discord.json` (mode 600, inside a 0700 config dir).
`fm-discord-setup.sh status` prints the clear connected/disconnected line,
including whether the owner is set. `disconnect` removes the binding
(revoke the token in the Portal to fully revoke).

## Reply path is outbound-only (Relay-style)

Everything the bot hears and answers arrives over connections the home
opens itself, exactly like the hosted Relay: the gateway websocket
(outbound `wss://` client) plus the bounded REST poll fallback are the
only inbound mechanisms. Nothing in this integration listens on a socket,
requires a public URL, or needs extra permission grants beyond the
minimal scopes/bits above. Chosen shape, and why: slash interactions are
handled where Discord already delivers them without any endpoint -
over the gateway as `INTERACTION_CREATE` (already authenticated by the
gateway session, so no Ed25519 signature check applies there) and
answered through the REST interaction callback
(`POST /interactions/{id}/{token}/callback`) — plus message-based
equivalents (`!fm ask <question>`, `!fm status`, also after a bot
mention) parsed from plain `MESSAGE_CREATE` content that need no
interaction delivery at all. Both shapes were kept because each covers
the other's gap: gateway interactions give native slash UX with zero
hosting, while `!fm` commands keep ask/status working wherever only
message content arrives (e.g. REST-fallback polls, or servers where
slash delivery lags). Either shape alone would satisfy the "plain
messages plus an ask/status equivalent with zero inbound hosting"
bar; together they share one `discord_authorize_sender` gate, one
inbox, and one `discord-command` wake, so there is still only one
command pipeline, not two.

The old self-hosted HTTPS interaction path (receive an interaction body
on a public endpoint, pipe it to a handler with `X-Signature-Ed25519` /
`X-Signature-Timestamp` headers for Ed25519 verification) is explicitly
unsupported and has no handler: `fm-discord-commands.sh handle`
requires `--gateway` and refuses anything else, and `DISCORD_PUBLIC_KEY`
is retained only for the `verify` test helper, never consulted on the
live path. Slash commands over a self-hosted endpoint are not part of
this integration.

## Operations

- Connect: set `DISCORD_OWNER_USER_ID`, then `init` -> open URL ->
  `callback --code ... --state ... [--guild ...]` -> `verify` (also runs
  inside callback) -> `register`. The callback exchanges the code with a
  form-encoded POST to the unversioned `https://discord.com/api/oauth2/token`
  endpoint, reads the installed guild from the bot-flow response (or
  `--guild`), and `verify` proves the bot token itself can read that guild
  before anything is persisted. `verify` also resolves and persists the bot
  user id; polling refuses until that id is known, so a half-configured
  home can never loop on its own replies.
- Outbound: `bin/fm-discord-send.sh <channel> [--reply-to <msg>] [--allow-user <user-id>] <text>` (repeat `--allow-user` to let named user mentions parse; without it mentions are suppressed).
  Long responses chunk (never truncate); multi-message replies carry
  ` (k/n)` thread suffixes like the Relay splitter; 429s honor
  Retry-After; 401/403/404 are structured failures.
- Outbound tap: `bin/fm-discord-notify.sh --event <key>
  --class decision|completion|blocker --text <summary> [--link <url>]
  [--decision-key <key>]` posts one short plain-language message
  mentioning the owner (`<@owner-id>`) so the phone pings, on exactly
  three event classes: a decision waiting on the captain, finished work
  (including review and merge calls), and blockers or failures. Routine
  progress never sends. `--wake-line <line>` (or `--wake` on stdin)
  classifies a watcher wake or supervision outcome reason line into one
  of those classes so the supervision flow can pipe wakes through the
  script; unrecognized lines stay silent. One message per event key:
  repeats for the same key (re-wakes for the same open decision) are
  silent, markers live in `state/discord-notify/`, and a failed send
  releases its marker so a retry can still deliver. Delivery reuses the
  `fm-discord-send.sh` authenticated path, so 429 Retry-After is
  honored. Text is redacted for secret shapes before sending.
- Inbound: `bin/fm-discord-gateway.py` (primary; reconnect + resume +
  dedup + self-filter) routes each MESSAGE_CREATE and each
  INTERACTION_CREATE through `bin/fm-discord-poll.sh --event-file`.
  Where websockets are unavailable,
  `fm-discord-poll.sh` runs config-gated under the watcher shim as the
  bounded REST fallback. The gateway loop holds
  `state/discord-gateway.lock`; a second loop refuses to start, and
  `fm-discord-gateway.py --stop` ends the running one.
- Slash commands: `/firstmate ask <question>`, `/firstmate status`
  (registered by `fm-discord-commands.sh register`; interactions arrive
  over the gateway via `handle --gateway`, are owner-, guild-, and
  channel-checked
  before mapping, and are answered through the REST interaction
  callback), plus message equivalents `!fm ask <question>` and
  `!fm status` (`handle-message`, routed automatically from `!fm`- or
  mention-prefixed message content by `fm-discord-poll.sh`) that need no
  interaction delivery at all. Both shapes stash to
  `state/discord-inbox/` and wake as `discord-command <id> <sub>` (see
  below); a failed interaction callback only logs, it never drops the
  wake, because the agent follows up with `fm-discord-send.sh` anyway.

## Watcher wiring and the wake consumer

Bootstrap arms `state/discord-watch.check.sh` (byte-static shim) plus
`config/discord-mode.env` (`FM_CHECK_INTERVAL=30`) whenever the home's
`.env` carries a bot token, and removes both on opt-out. `fm-watch.sh`
validates the shim bytes and dispatches the trusted
`bin/fm-discord-poll.sh` directly; `fm-supervision-lib.sh` treats a live
shim as needing supervision; the emitted supervision block sources the
cadence file before the watcher starts. There is no second execution
mechanism: authorized messages enter Firstmate only as watcher wakes.

- `discord-message <id>`: the full message object is stashed at
  `state/discord-inbox/<id>.json` (guild, channel, `user_id`, timestamps,
  `reply_context` preserved). The on-call agent reads that file, treats
  `content` as untrusted third-party input, and answers through the normal
  lifecycle, replying with `fm-discord-send.sh <channel> --reply-to <id>`.
- `discord-command <iid> <sub>`: the gateway-authenticated interaction
  (or `!fm` message equivalent, stashed as `cmd-<msgid>` with `via` set
  to `"message"`) is stashed at `state/discord-inbox/<iid>.json` with
  `firstmate_command`, `user_id`, and `guild_id`. The `ask` subcommand's
  question text is the interaction option value (or the `!fm ask`
  remainder as `question`); the agent answers the same way.
- `fm-discord-gateway.py --once` is the health check: it reports the
  gateway session-limit lookup, and reports "not configured" (non-zero)
  instead of succeeding while inert.

## Security, rate limits, reliability

- Tokens are never logged (`discord_redact` covers token shapes plus the
  literal loaded secrets), never enter the agent context, and live only in
  `.env`/memory; gateway-delivered interactions need no signature check
  because the gateway session itself is the authentication, while the
  legacy Ed25519 `verify` helper stays available for tests only and is
  never consulted on the live path.
- Guild/user/channel are checked before routing; unknown senders,
  guilds, channels, and missing owner/guild configuration all refuse
  closed. Privileged actions stay behind Firstmate's captain-hold model.
- REST honors 429 Retry-After with bounded retries, transient 5xx backoff,
  timeouts (`-m 15`), structured logging to stderr, and health via
  `fm-discord-setup.sh status` / `fm-discord-gateway.py --once`.
- The Gateway preserves handshake bytes past the HTTP headers, answers
  PING with masked PONG, schedules heartbeats (including on server
  request) with ACK-liveness reconnect, and resets reconnect backoff on
  READY.

## What needs a live server

Mocked in the normal suite: OAuth exchange, Gateway lookup, REST,
chunking, dedup, rate limits, permissions, authorization gates,
self-filtering, shim arming/validation, intent bits, gateway
INTERACTION_CREATE routing without signatures, the REST interaction
callback, `!fm` message equivalents, and the no-listen static check. A
live Discord application + server is required to prove: real OAuth
install, real Gateway delivery (messages and interactions) and resume,
real slash command registration/interaction, real permission bits, and
real 429 shape.
