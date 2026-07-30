# Telegram topic board

The topic board gives approved senders real-time Telegram forum channels with one project stream per topic.
It uses one dedicated board bot (`@example_board_bot` in the examples below) across one or more configured forum groups.
It never uses the direct-message bot's token (`@example_direct_bot` in the examples below) or changes that bot's direct-message plugin poller.

## Architecture

`bin/fm-topic-listener.sh` runs continuously as a systemd user service and uses Telegram `getUpdates` long polling with a default 25 second timeout.
Each accepted update is written atomically to a deterministic `update-<id>.json` inbox file before the durable Telegram offset advances.
The record carries the originating `chat_id`, configured `group`, `from_id`, and `message_thread_id`.
Routing reads the matching chat's topic map, while replies read the durable item origin rather than any default chat.
If the listener stops after writing the item but before advancing the offset, Telegram redelivers the update and the deterministic filename makes that replay idempotent.
If the listener stops after advancing the offset but before notifying firstmate, the retained inbox item is found again and notification is retried.

The listener appends a `topic-board` record to firstmate's durable wake queue before sending `USR1` to the identity-verified watcher for the same `FM_HOME`.
The signal returns the active harness supervision cycle immediately, while the queued record remains the authority for recovery after a crash or restart.
The watcher also checks for a queued topic-board record at each poll boundary, so an ignored or missed signal cannot strand an actionable message behind benign wake absorption.
No state check or 300 second check sweep participates in the delivery path.
The listener repeats pending notifications on a bounded default 300 second cadence so a crash after a queue drain cannot strand an inbox item.
Claimed items repeat on a separate default four-hour cadence, which keeps active work quiet while ensuring a forgotten claim resurfaces.

`bin/fm-topic-inbox.sh` lists, shows, claims, and releases individual items.
Claiming records ownership but leaves the item in the inbox until a successful initial answer.
`bin/fm-topic-reply.sh` sends through Telegram `sendMessage` with the item's recorded `chat_id` and `message_thread_id`, so the response lands in the originating group and topic.
A new reply intent repeats that origin and refuses reuse if its origin no longer matches the durable item.
A successful initial answer moves only that item into `answered/` and never bulk-deletes the inbox.

Telegram does not provide an idempotency key for `sendMessage`.
The reply helper therefore records a durable send intent before calling Telegram and refuses automatic retry after an ambiguous transport result.
An operator must inspect the topic and choose `--confirm-sent` or `--retry-unknown`, which avoids silently creating duplicate answers after a crash.

## Lifeline safety

Telegram permits only one `getUpdates` consumer per bot token.
Pointing this service at the direct-message bot (`@example_direct_bot`) would compete with the direct-message plugin and could steal the captain's private messages.
The separate board-bot token (`@example_board_bot`) gives the project board its own single consumer and keeps the direct-message lifeline isolated.
Configuration validation compares against the direct-message plugin token when it is locally available and refuses if the two tokens match.
The group bot must have privacy mode disabled through BotFather so normal topic messages are visible to it in every configured group.

## Local data

All runtime data is gitignored under `$FM_HOME/data/fm-telegram-topics/`.

```text
config.env                 private bot token, captain user id, and optional additional sender ids, mode 0600
test-bot-token.txt         accepted legacy prototype credential filename
topic-map.json             per-chat sender, topic, project, and route map
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
FM_TOPIC_APPROVED_SENDER_IDS=<optional-comma-separated-additional-user-ids>
```

The legacy prototype keys `TEST_BOT_TOKEN` and `CAPTAIN_CHAT_ID` remain accepted so the existing private token file can be used without copying its secret.
`FM_TOPIC_CAPTAIN_ID` remains required and is always part of the bot-wide approved set.
`FM_TOPIC_APPROVED_SENDER_IDS` adds zero or more ids to that set without changing the direct-message configuration contract.
Every id must match `^[0-9]+$` exactly, with commas and no spaces between additional ids.
The listener refuses the complete configuration if any credential id or per-chat id is malformed, if a per-chat id is absent from the credential set, or if Telegram's anonymous-admin sender id `1087968824` is listed.
The listener refuses a credential file that is a symlink or exposes any group or other permission bits.

The multi-chat map uses a `chats` object keyed by the exact Telegram chat id.
Each chat owns its display name, approved sender scope, and topic map.

```json
{
  "bot": {"id": "<BOARD_BOT_ID>", "username": "@example_board_bot"},
  "chats": {
    "<FIRST_BOARD_CHAT_ID>": {
      "group": "Example Dev Group",
      "approved_sender_ids": ["<CAPTAIN_USER_ID>"],
      "topics": {
        "3": {"name": "AlphaDev", "project": "Alpha", "route": "alpha-mate"},
        "5": {"name": "DevOps", "project": "General DevOps", "route": "main"}
      }
    },
    "<SECOND_BOARD_CHAT_ID>": {
      "group": "Second Example Group",
      "approved_sender_ids": ["<CAPTAIN_USER_ID>", "<SECOND_USER_ID>"],
      "topics": {}
    }
  }
}
```

The modern `chats` shape does not mix legacy top-level `chat_id`, `group`, or `topics` keys into the same file.
A sender approved in the credential file but omitted from a chat's `approved_sender_ids` is rejected in that chat.
An unknown chat, an unapproved sender, and Telegram's anonymous-admin sender are all rejected and logged.

The original single-chat object remains valid without any edits.

```json
{
  "chat_id": "<BOARD_CHAT_ID>",
  "group": "Example Dev Group",
  "bot": "@example_board_bot",
  "topics": {
    "3": {"name": "AlphaDev", "project": "Alpha", "route": "alpha-mate"}
  }
}
```

In the legacy shape, the credential-level approved sender set applies to its one chat.
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
Items in a topic whose route names a registered secondmate go to that secondmate.
Topics routed to `main`, and unmapped topics, remain with main firstmate.
Worker instructions and returns carry `topic-item <update-id>` so the final outcome can be sent back to the correct originating topic.

An enabled topic board requires one live harness supervision cycle even when no project task is running.
Session-start instructions, the turn-end guard, the normal liveness guard, and the OpenCode idle-arm plugin all treat the local topic credential file as supervision demand.
