# Direct-message line

The direct-message line gives the captain a session-independent private Telegram channel to firstmate through the direct-message bot (`@example_direct_bot` in the examples below).
It replaces a chat-session-coupled direct-message plugin poller, whose inbound messages die with the session that spawned it and need manual reconnection.
It never uses the topic-board bot's token or touches the topic-board service.

## Architecture

`bin/fm-dm-listener.sh` runs continuously as a systemd user service and uses Telegram `getUpdates` long polling with a default 25 second timeout.
It reuses the topic-board store conventions from `bin/fm-topic-lib.sh` against `$FM_HOME/data/fm-telegram-dm`, so durability, atomic persistence, idempotent replay, and the answered archive behave exactly as documented in `docs/topic-board.md`.
A direct chat has no forum topics: every item carries `thread_id: null`, topic `Direct message`, and route `main`.
Only private-chat messages whose sender and chat both equal the configured captain user id are persisted; everything else is logged and skipped.

Direct-message wakes ride the watcher's existing always-actionable `topic-board` queue key with a payload naming the direct-message inbox, so `bin/fm-watch.sh` needs no new wake vocabulary.
On such a wake, run `bin/fm-dm-inbox.sh list` in addition to the topic-board inbox; the two stores are separate.
The listener repeats pending notifications on a bounded default 300 second cadence (`FM_DM_REMIND_SECONDS`).
Claimed items repeat on a separate default four-hour cadence (`FM_DM_CLAIMED_REMIND_SECONDS`).

`bin/fm-dm-inbox.sh` lists, shows, claims, and releases items (same commands and claimed-versus-pending semantics as `fm-topic-inbox.sh`).
`bin/fm-dm-reply.sh <update-id>` answers an item with the full topic-board reply semantics, including keyed idempotent intents, the ambiguous-delivery stop, and the `answered/` archive.
`bin/fm-dm-reply.sh send` sends a standalone message to the captain chat with no inbox item, for announcements; it records `outbox/send-<epoch>-<id>.json`.

## Single-consumer safety

Telegram permits only one `getUpdates` consumer per bot token.
The listener checks the direct-message plugin's pid file (default `~/.claude/channels/telegram/bot.pid`, override `FM_DM_PLUGIN_PID_FILE`) before every poll.
While that pid is alive the listener logs and waits on a bounded cadence (`FM_DM_CONFLICT_WAIT`, default 30 seconds); it never kills the other consumer.
The service is therefore incompatible with launching any chat session that starts the direct-message plugin poller.
Before relying on the service, remove every `--channels plugin:telegram@...` flag from session launchers and disable the telegram plugin in the harness settings that enable it, because some plugin versions kill and replace whatever pid the pid file names and then steal the token.
Configuration validation refuses to run if the direct-message token equals the topic-board bot token, mirroring the topic board's lifeline guard in the opposite direction.

## Local data

All runtime data is gitignored under `$FM_HOME/data/fm-telegram-dm/`.

```text
config.env                 private bot token and captain user id, mode 0600
topic-map.json             auto-created empty map satisfying the shared reply-path validation
.poll-offset               next Telegram update id to request
.last-wake                 last successfully signaled notification epoch
inbox/update-<id>.json     unanswered or claimed captain messages
answered/update-<id>.json  answered messages retained for follow-ups
outbox/*.json              durable keyed reply intents, delivery results, and standalone sends
locks/                     listener and per-reply singleton locks
```

The credential file uses the same exact unquoted keys as the topic board.

```dotenv
FM_TOPIC_BOT_TOKEN=<direct-message-bot-token>
FM_TOPIC_CAPTAIN_ID=<captain-telegram-user-id>
```

The listener refuses a credential file that is a symlink or exposes any group or other permission bits.

## Installation

Run installation only from the landed main firstmate copy so the service does not point at a disposable branch.
Copy the token into the private credential file without printing it, validate, then install.

```bash
bin/fm-dm-listener.sh --check-config
bin/fm-dm-service.sh install
```

The generated `firstmate-dm.service` is enabled under the user's `default.target`, restarts automatically, and relies on user linger to survive logout and reboot.

```bash
bin/fm-dm-service.sh status
journalctl --user -u firstmate-dm.service -f
bin/fm-dm-service.sh restart
```

Uninstalling the unit preserves credentials, offsets, inbox items, answered items, and reply intents.

```bash
bin/fm-dm-service.sh uninstall
```

## Health checks

A machine-local health scan should cover, at minimum: the service unit is active, the plugin pid file names no live process (consumer singularity), the bot API answers `getMe`, and no inbox item older than 15 minutes still has `"status": "pending"`.
A claimed item is being worked and must not alarm; only an unclaimed pending item indicates a stalled drain.
