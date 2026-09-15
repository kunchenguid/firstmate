# Private Telegram away notifications

Firstmate can send a small, private set of Telegram notifications while the captain is in a confirmed away posture.
This is a notification channel only: it adds no Telegram commands, no inbound message handling, and no authority.
The away posture remains hold-for-return, an unspecified return time remains unspecified, and the default limit remains four concurrent workers.

## Local setup

The setup is deliberately local and one-way.
Place the already-provisioned bot token in `config/telegram-bot-token` as one line, with mode `0600`.
The containing `config/` directory must be an owner-only `0700` directory.
Do not put the token in a command, environment variable, tracked file, worker instruction, log, or chat message.

Run:

```sh
printf '%s\n' '<your-private-chat-id>' | bin/fm-telegram.sh setup
```

The placeholder above represents input only; never replace it with the bot token.
When `config/telegram-chat-id` is absent, `setup` reads exactly one positive numeric private-chat id from standard input and stores it as another `0600` regular file.
The command verifies the bot with Telegram `getMe` and verifies the binding with `getChat`, refusing group or channel chats.
It does not call `getUpdates` and does not send a setup message.
A setup failure does not print the token or the API response.

`bin/fm-telegram.sh ready` performs the local permission and value checks without a network call.
Removing or renaming either private file opts the channel out for future away entries; an active posture keeps its recorded reach profile and should be returned normally first.

## Delivery contract

The contract compiler records `reach_channels: telegram` only when both private files pass the local checks.
The channel is active only while that confirmed record exists, and quiet mode does not send these away notifications.
The sender accepts only these fixed event classes:

- `boundary` - a captain-facing completion, readiness, or merge boundary.
- `error` - an error or actionable check result.
- `stalled` - a worker or supervision path waiting too long.
- `wedge` - away escalation delivery could not be submitted.
- `quota` - Codex weekly quota is at or below 70% remaining.

Watcher reasons are classified internally and are never placed in the Telegram message.
Routine heartbeats, ordinary progress, and status signals without a classified boundary or error are suppressed.
API calls use bounded timeouts, do not expose the token in process arguments, and are best-effort with one in-call retry.
Failures are not persisted in a durable Telegram retry queue.
Successful events are deduplicated by event identity per away session in a private, bounded journal, so a later distinct completion or error is still delivered.
The completion path is owned by Firstmate's classified watcher event; there is no public command that lets a worker send a completion notification directly.

## Weekly Codex protection

The AFK path registers the existing quota process-event adapter as `afk-codex-weekly`.
It polls the structured `quota-axi --json` result with provider `codex`, scope `weekly`, and an inclusive threshold of `70`.
Only an availability record whose `boundedBy` list contains `weekly` can trigger it, so the current five-hour window may be consumed below 70% without sending this notification.
Missing or unknown weekly quota data does not trigger a false low-quota message.
Only `afk-codex-weekly` results can produce this notification; generic quota sources remain unrelated to the private AFK channel.
The source is retired when the away posture returns.

## Validation

Tests use `FM_TELEGRAM_TRANSPORT` to replace HTTP.
The fake transport receives only the method and private request/response file paths, and writes a structured response without receiving the bot token.
Tests cover setup verification, strict permissions, no command polling, fixed message text, AFK gating, event-identity deduplication, one in-call failed-send retry, generic quota-source rejection, and the weekly-vs-five-hour quota boundary.
Use `bin/fm-lint.sh` for shell and documentation validation before delivery.
