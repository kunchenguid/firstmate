# Telegram mode - phone notifications and bounded approvals

Telegram mode gives a Firstmate home an opt-in phone channel for away-mode
escalations and a closed Stage-2 command grammar.
It rides the existing watcher, durable wake queue, and away-mode machinery.
There is no parallel supervisor and no Pi extension of its own.

This document owns activation mechanics, security controls, the closed command
grammar, and kill-switch behavior.
`docs/configuration.md` owns the env-key summary and generated-artifact list.

## Activation (inert by default)

Telegram mode is off until the home's gitignored `.env` contains both:

- `FM_TELEGRAM_BOT_TOKEN` - BotFather bot token
- `FM_TELEGRAM_CHAT_ID` - private chat id of the captain's 1:1 bot chat

Recommended `.env` mode is `0600`, matching the X-mode pairing-token practice.
Optional keys:

| Key | Default | Purpose |
| --- | --- | --- |
| `FM_TELEGRAM_ALLOW_FROM` | same as chat id | Comma-separated Telegram user ids allowed to command |
| `FM_TELEGRAM_API_URL` | `https://api.telegram.org` | Bot API base (tests/local overrides) |
| `FM_TELEGRAM_ENV_FILE` | `$FM_HOME/.env` | Alternate env file for direct client calls only |
| `FM_TELEGRAM_DRY_RUN` | off | Record outbound to `state/telegram-outbox/` without posting |
| `FM_TELEGRAM_ALWAYS_NOTIFY` | off | Send routine outbound even when not AFK |
| `FM_TELEGRAM_FRESHNESS_SECS` | `900` | Max age of approve/deny/merge commands |
| `FM_TELEGRAM_RATE_MAX` | `10` | Max authenticated updates accepted per poll sweep and commands processed per rate window |
| `FM_TELEGRAM_RATE_WINDOW_SECS` | `60` | Rate-limit window |
| `FM_TELEGRAM_DEDUPE_WINDOW_SECS` | `120` | Identical-command dedupe window |

Environment values override `.env` for direct client invocations.
Bootstrap activation still keys only off `$FM_HOME/.env` so watcher artifacts are explicit local opt-in state.

### Kill switch

Three independent layers:

1. Remove or empty the token/chat keys from `.env` - the next locked bootstrap removes the poll shim and cadence file.
2. Write `off` alone into `config/telegram-mode` - honored even when tokens remain.
3. Revoke the bot token at BotFather - hard kill even if the host is compromised.

A repeated `getUpdates` HTTP 409 conflict surfaces once as `telegram-mode-error ...` and recommends rotating the token (another consumer may hold it).

## Generated local state

On locked session-start bootstrap, when tokens are present and the kill switch is not `off`:

- `state/telegram-watch.check.sh` - byte-static identity shim; the watcher validates its bytes and runs `bin/fm-telegram-poll.sh`
- `config/telegram-mode.env` - exports `FM_CHECK_INTERVAL=30` for the watcher cadence

`bin/fm-watch-arm.sh` and `bin/fm-watch-checkpoint.sh` source that cadence file when present, so every harness inherits the 30s interval without Pi extension changes.
While away mode is active the sub-supervisor daemon owns the watcher and the default check cadence applies; inbound polling still runs, just on the slower default interval (the same deferred follow-up as X-mode away cadence, see `docs/configuration.md` "X mode (.env)").

Runtime private artifacts (all gitignored, typically mode 0600/0700):

| Path | Role |
| --- | --- |
| `state/telegram-inbox/<update_id>.json` | Stashed authenticated inbound messages |
| `state/telegram-inbox-quarantine/` | Permanently-unprocessable inbox files (invalid envelope, unsafe perms); never reprocessed or silently deleted |
| `state/telegram-offset` | Persisted getUpdates offset (advances past drops and accepts; not past deferred over-cap authenticated updates) |
| `state/telegram-audit.log` | Append-only inbound/outbound/respond/quarantine audit |
| `state/telegram-notified-prs.log` | Timestamp, chat id, and full PR URL for successful live non-reply sends |
| `state/telegram-notified-pr-recovery/` | Confirmed sends whose primary merge-authority record could not be written |
| `state/telegram-actions/<update_id>.json` | Validated approve/deny/merge actions for firstmate |
| `state/telegram-outbox/` | Dry-run outbound previews |
| `state/telegram-poll.error` | Deduped poll diagnostic marker |
| `state/telegram-rate-*.log` / `state/telegram-dedupe.log` | Rate limit and dedupe windows |
| `state/telegram-rate-quarantine/` | Permanently-corrupt rate logs set aside so a bad file cannot fail-close every command |

## Stage 1 - outbound notifications

`bin/fm-telegram-send.sh` posts `sendMessage` to the configured chat.

- Routine notifications send only while `state/.afk` exists, unless `FM_TELEGRAM_ALWAYS_NOTIFY` is set or the caller passes `--force`.
- Command replies use `--reply` and always send (so phone acks work at the desk).
- Text that looks like secrets, tokens, or credentials is refused (desk-only).
- Successful non-reply sends that contain full `https://github.com/.../pull/N` URLs record those URLs for Stage-2 merge authority.
- A confirmed send whose primary authority record fails attempts private recovery, audits any persistence warning, and returns non-retryable exit 4.
- Dry-run previews do not grant merge authority because Telegram received no message.
- Telegram's 4096-character limit is enforced with truncation.

### Wedge-alarm example

`config/wedge-alarm` already supports `command:` channels.
Point one at the sender so a wedged away-mode primary reaches the phone without new daemon code:

```
osascript
command: FM_HOME="$HOME/path-to-this-firstmate-home" /path/to/firstmate/bin/fm-telegram-send.sh --force -
```

Or a one-shot curl wrapper that reads the token from `.env` (never inline the token in the config file).
See `docs/examples/wedge-alarm` for a copyable starting config.

## Stage 2 - bounded inbound replies and approvals

`bin/fm-telegram-poll.sh` short-polls `getUpdates`, drops non-allowlisted senders and non-private chats (audited, never replied to; those drops advance the offset so attackers cannot pin the backlog), stashes accepted messages, and prints `telegram-msg <update_id>` so the watcher queues a `check:` wake.
Authenticated messages beyond `FM_TELEGRAM_RATE_MAX` per sweep are deferred, not dropped: the offset does not advance past them, so the next sweep re-fetches (captain decision key=`telegram-rate-cap`).

Firstmate loads the `fm-telegram-respond` skill on that wake (and on `telegram-mode-error ...`), then runs `bin/fm-telegram-respond.sh` to drain the inbox.

### Closed command grammar

| Command | Effect |
| --- | --- |
| `status` | Reply with a short local fleet summary (always allowed; no freshness window) |
| `approve <key>` | Record an approve action for an open keyed decision |
| `deny <key> [reason]` | Record a deny action for an open keyed decision |
| `merge <full green PR URL>` | Authorize merge only if that full URL was previously sent to this chat and the PR is green |

Anything else is refused with an audit entry and a short reply.
Stage 3 free-text prompting is not implemented.

### Authority boundaries

- Telegram messages never exit away mode.
- `approve` / `deny` only apply to open keyed decisions already recorded in `state/*.status`.
- Decisions whose summary looks security-sensitive (credentials, secrets, destructive, irreversible) are refused as desk-only.
- `merge` requires (1) a full GitHub PR URL previously outbound-notified to this chat and (2) a green open PR (via `gh-axi` or `FM_TELEGRAM_PR_CHECK_HOOK` in tests).
- Red, unnamed, unknown, destructive, irreversible, or security-sensitive operations are refused.

### Replay, rate limit, audit

- Offset advances past confirmed accepts and auth/empty drops only after the new offset is durably persisted.
- An offset-persistence failure emits a deduplicated `telegram-mode-error`, leaves the update unconfirmed for the next `getUpdates` sweep, and can therefore re-fetch an already-stashed command.
- Over-cap authenticated updates are deferred (offset holds before them) for at-least-once delivery of allowlisted commands.
- Commands beyond the inbound rate limit stay queued in the inbox (audited `deferred`, replied "rate limited" once per dedupe window), never dropped; every poll sweep re-emits `telegram-msg` wakes for pending inbox files, so queued commands drain once the window frees without requiring a new message.
- Permanently-unprocessable inbox inputs (malformed envelope, unsafe file permissions) are quarantined once under `state/telegram-inbox-quarantine/` and never re-emitted as wakes; the move is audited and never silently deleted.
- A successful quarantine sends a generic phone acknowledgment only (no command content, envelope body, or secrets); captain decision key=`no-reply-on-quarantine`.
- A corrupt `state/telegram-rate-*.log` is quarantined once under `state/telegram-rate-quarantine/` and replaced by a fresh window so it cannot fail-close every command forever; well-formed logs keep their legitimate rate-window state.
- Missing `curl`/`jq` emit a deduplicated `telegram-mode-error` and skip pending re-wakes until the tool returns (transient, not quarantined).
- Approve/deny/merge older than `FM_TELEGRAM_FRESHNESS_SECS` (default 15 minutes) are not executed; deferred approvals can still go stale and are re-surfaced for re-confirmation.
- Identical commands are deduped inside a short window.
- Every inbound verdict, quarantine action, and outbound send appends to `state/telegram-audit.log` (tokens redacted).

## Scripts

| Script | Role |
| --- | --- |
| `bin/fm-telegram-lib.sh` | Config, allowlist, offset, audit, grammar, PR registry (sourced) |
| `bin/fm-telegram-send.sh` | Outbound `sendMessage` |
| `bin/fm-telegram-poll.sh` | Inbound `getUpdates` poll for the watcher |
| `bin/fm-telegram-respond.sh` | Closed-grammar drain of `state/telegram-inbox/` |

Skill: `.agents/skills/fm-telegram-respond/SKILL.md` (firstmate load trigger).

## Setup checklist

1. Create a bot with BotFather; copy the token.
2. Start a private chat with the bot; obtain your chat id (for example via a temporary getUpdates after messaging the bot).
3. Put both values in `$FM_HOME/.env` with mode `0600`.
4. Optionally set `FM_TELEGRAM_ALLOW_FROM` if the user id differs from the chat id.
5. Run a locked session-start (or `bin/fm-bootstrap.sh`) and confirm a `FMT: Telegram mode on` line.
6. While away mode is active, escalations that call `fm-telegram-send.sh` reach the phone.
7. Reply with `status` to verify the inbound path.

## Security notes (threat model summary)

- Stolen phone: attacker gets routine-scope authority only; desk-only actions stay desk-only; BotFather revocation recovers.
- Leaked bot token: attacker can read pending updates and spoof bot-authored messages, but cannot forge an allowlisted `from.id`; 409 detection surfaces a concurrent consumer.
- Telegram platform sees message content (no E2E for bots) - never put secrets on this channel.
- Host compromise is out of scope for this channel.
