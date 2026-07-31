# Private Telegram bridge

Audience: operator current.

The Telegram bridge lets one captain send private text requests to a running Firstmate session and receive replies in the same direct bot conversation.
It is disabled by default, uses Telegram Bot API long polling, opens no listening port, and does not use a public webhook.

## V1 boundary

V1 supports one dedicated bot, one exact Telegram user ID, and that user's matching direct private chat ID.
It supports text only.
Attachments, edited messages, group chats, channels, multiple users, and multiple chats are rejected without a reply.
The bridge does not run Firstmate or a model while the primary session is offline.
It only places authenticated text into Firstmate's existing durable supervision queue.

Telegram delivery does not relax Firstmate's authority rules.
Merges, deployments, destructive or irreversible operations, security-sensitive changes, and ambiguous writes still require whatever fresh approval they require in the primary session.
An approval reply is accepted only when it names the exact approval ID and directly replies to the Telegram decision message that created that binding.

## Create a dedicated bot

Use Telegram's official [BotFather procedure](https://core.telegram.org/bots/features#botfather) from your own Telegram account to create a bot used only for this Firstmate home.
Do not reuse a bot that has a webhook, another poller, a group membership, or another application owner.
Do not paste the token into a Telegram chat, issue, PR, report, task instruction, or shell command line.

Send the new bot one ordinary private text message from the captain account before pairing.
That message lets the local setup command display the numeric candidate IDs without retaining Telegram names, usernames, or profile data.

## Pair locally

Create a temporary owner-only token file outside the repository with a local password manager or editor, and verify its mode is `0600`.
The file must be a regular single-link file rather than a symlink or hard link.

From the Firstmate repository, run:

```sh
bin/fm-telegram-setup.sh pair --token-file /absolute/path/to/owner-only-token-file
```

The command verifies the bot with `getMe`, reads pending direct messages with `getUpdates`, and prints numeric user/chat candidates only.
Type the exact confirmation it requests:

```text
PAIR <user_id> <chat_id>
```

V1 accepts only a candidate whose user and direct-chat IDs are equal.
On success, the command writes `config/telegram/bridge.json` as a local owner-only mode-`0600` file inside an owner-only directory.
Never copy, commit, print, or hand-edit that file.
Remove the temporary token file through your normal secure local-file procedure after the config is confirmed.

Run `bin/fm-session-start.sh` once in the lock-owning primary session to generate the trusted poll shim and cadence file.
Follow the emitted harness-specific supervision instructions so the new cadence reaches the next watcher process.
The bridge uses Telegram's documented [`getUpdates` offset](https://core.telegram.org/bots/api#getupdates) and long-poll timeout contract.

## Check or disable

Status reports only whether the local bridge is safely enabled:

```sh
bin/fm-telegram-setup.sh status
```

Disable it locally with:

```sh
bin/fm-telegram-setup.sh disable
bin/fm-session-start.sh
```

The first command changes only the protected local config.
The next lock-owning session start removes the generated polling artifacts without restarting a shared daemon.
Use BotFather separately if you also need to revoke the bot token.

## Requests, replies, and notifications

Accepted inbound text is persisted before the long-poll offset advances, assigned an exact `tg-<update_id>-<message_id>` correlation, and queued once.
Firstmate replies through a durable outbound receipt and Telegram's [`sendMessage`](https://core.telegram.org/bots/api#sendmessage) reply parameters so the answer stays threaded to the request.
Every reply and every allowed captain-relevant supervised worker update from every project crosses one deterministic presentation boundary.
The supported source semantics are headings, lists, HTTP or HTTPS links, quotes, inline and fenced code, and simple tables.
The renderer escapes all source entities, creates Telegram HTML itself, and never accepts model-authored Telegram markup, custom entities, or buttons.
Tables remain compact only when they fit a mobile-width budget; wider tables become labeled records.
Emoji, combining marks, CJK characters, and UTF-16 message limits are measured before bounded splitting.
Each split is delivered sequentially to the same chat under one receipt.
The restart-stable protected snapshot contains both safe rich text and a readable plain version whose links include their full URLs.
A definite Telegram entity-validation rejection may fall back once to that plain version, while an ambiguous send never retries.
The inbound message body and rendered snapshot are deleted after a matching sent receipt and otherwise expire after seven days with an operator notification.
Telegram names, usernames, and profile fields are not retained.

Optional standalone updates are quiet by default.
The allowed classes across all supervised projects are decisions, failures, credential needs, green PRs, merges, deployments, and completed scout results.
Raw logs, retries, automatic fixes, unchanged state, and ordinary worker progress are not sent.

Outbound requests use bounded timeouts, rate limiting, and Telegram's bounded `retry_after` guidance only for definite HTTP 429 responses.
A transport failure, server failure, malformed success body, or interrupted dispatch is `uncertain` because Telegram may have accepted it.
Firstmate wakes for reconciliation and never retries uncertain content blindly.

## Safe failure behavior

Unsafe permissions, a symlink or hard link, an incomplete config, a mismatched user/chat pair, a webhook or competing poller, malformed Bot API data, duplicate or out-of-order update IDs, an edited update, unsupported media, or oversized text disables or rejects the affected path.
Unauthorized senders and chats receive no reply.
Diagnostics contain stable redacted codes only and never include the token, Telegram response body, message body, or profile data.

Maintainer evidence and exact current test commands live in [the Telegram bridge verification record](verification/telegram-bridge.md).
