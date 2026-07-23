# Telegram topic board

The topic board gives the captain a real-time Telegram forum channel with one project stream per topic.
It uses the dedicated `@secondmate_kingbot` bot in the `DevBois II` forum group.
It never uses the `@firstmate_kingbot` token or changes that bot's direct-message plugin poller.

## Architecture

`bin/fm-topic-listener.sh` runs continuously as a systemd user service and uses Telegram `getUpdates` long polling with a default 25 second timeout.
Each accepted update is written atomically to a deterministic `update-<id>.json` inbox file before the durable Telegram offset advances.
If the listener stops after writing the item but before advancing the offset, Telegram redelivers the update and the deterministic filename makes that replay idempotent.
If the listener stops after advancing the offset but before notifying firstmate, the retained inbox item is found again and notification is retried.

The listener appends a `topic-board` record to firstmate's durable wake queue before sending `USR1` to the identity-verified watcher for the same `FM_HOME`.
The signal returns the active harness supervision cycle immediately, while the queued record remains the authority for recovery after a crash or restart.
The watcher also checks for a queued topic-board record at each poll boundary, so an ignored or missed signal cannot strand an actionable message behind benign wake absorption.
No state check or 300 second check sweep participates in the delivery path.
The listener repeats unanswered notifications on a bounded default 300 second cadence so a crash after a queue drain cannot strand an inbox item.

`bin/fm-topic-inbox.sh` lists, shows, claims, and releases individual items.
Claiming records ownership but leaves the item in the inbox until a successful initial answer.
`bin/fm-topic-reply.sh` sends through Telegram `sendMessage` with the item's recorded `message_thread_id`, so the response lands in the originating topic.
A successful initial answer moves only that item into `answered/` and never bulk-deletes the inbox.

Telegram does not provide an idempotency key for `sendMessage`.
The reply helper therefore records a durable send intent before calling Telegram and refuses automatic retry after an ambiguous transport result.
An operator must inspect the topic and choose `--confirm-sent` or `--retry-unknown`, which avoids silently creating duplicate answers after a crash.

## Lifeline safety

Telegram permits only one `getUpdates` consumer per bot token.
Pointing this service at `@firstmate_kingbot` would compete with the direct-message plugin and could steal the captain's private messages.
The separate `@secondmate_kingbot` token gives the project board its own single consumer and keeps the direct-message lifeline isolated.
Configuration validation compares against the direct-message plugin token when it is locally available and refuses if the two tokens match.
The group bot must have privacy mode disabled through BotFather so normal topic messages are visible to it.

## Local data

All runtime data is gitignored under `$FM_HOME/data/fm-telegram-topics/`.

```text
config.env                 private bot token and captain user id, mode 0600
test-bot-token.txt         accepted legacy prototype credential filename
topic-map.json             chat, topic, project, and route map
.poll-offset               next Telegram update id to request
.last-wake                 last successfully signaled notification epoch
inbox/update-<id>.json     unanswered or claimed messages
answered/update-<id>.json  answered messages retained for follow-ups
outbox/*.json              durable keyed reply intents and delivery results
locks/                     listener and per-reply singleton locks
```

The credential file accepts the following exact unquoted keys.

```dotenv
FM_TOPIC_BOT_TOKEN=<dedicated-topic-bot-token>
FM_TOPIC_CAPTAIN_ID=<captain-telegram-user-id>
```

The legacy prototype keys `TEST_BOT_TOKEN` and `CAPTAIN_CHAT_ID` remain accepted so the existing private token file can be used without copying its secret.
The listener refuses a credential file that is a symlink or exposes any group or other permission bits.

The current project map is represented locally with this schema.

```json
{
  "chat_id": "-1004497246253",
  "group": "DevBois II",
  "bot": "@secondmate_kingbot",
  "topics": {
    "3": {"name": "LMoonDev", "project": "L'Moon", "route": "lmoon-mate"},
    "2": {"name": "KoruDev", "project": "Koru", "route": "koru-mate"},
    "4": {"name": "VisDev", "project": "Vintage in Style", "route": "main"},
    "5": {"name": "DevOps", "project": "General DevOps", "route": "main"},
    "9": {"name": "MiscDev", "project": "Misc", "route": "main"}
  }
}
```

Messages in an unknown thread are retained with route `main` and an explicit unmapped-topic label.
They are never silently discarded because the map is stale.

## Installation and migration

Run installation only from the landed main firstmate copy so the service does not point at a disposable branch.
The installer validates the private credentials and map before writing or starting the unit.

```bash
bin/fm-topic-listener.sh --check-config
bin/fm-topic-service.sh install
```

The installer refuses while the prototype `state/topic-watch.check.sh` still exists because starting the service first would create two `getUpdates` consumers for the topic bot.
Disable or archive that legacy check, wait for any one-second prototype poll to finish, then run the installer.
Do not remove `.poll-offset` or any inbox file during migration.

The generated `firstmate-topic-board.service` is enabled under the user's `default.target`, restarts automatically, and uses the machine's existing user linger configuration to survive logout and reboot.
It deliberately has no `After=default.target` ordering edge, which avoids the user-service ordering cycle previously seen on this host.

```bash
bin/fm-topic-service.sh status
journalctl --user -u firstmate-topic-board.service -f
bin/fm-topic-service.sh restart
```

Uninstalling the unit preserves credentials, offsets, inbox items, answered items, and reply intents.

```bash
bin/fm-topic-service.sh uninstall
```

## Firstmate handling

The agent-only `topic-board` skill owns intake, route selection, claiming, reply, and ambiguous-delivery recovery.
L'Moon and Koru items route to `lmoon-mate` and `koru-mate` respectively.
VIS, DevOps, Misc, and unmapped topics remain with main firstmate.
Worker instructions and returns carry `topic-item <update-id>` so the final outcome can be sent back to the correct originating topic.

An enabled topic board requires one live harness supervision cycle even when no project task is running.
Session-start instructions, the turn-end guard, the normal liveness guard, and the OpenCode idle-arm plugin all treat the local topic credential file as supervision demand.
