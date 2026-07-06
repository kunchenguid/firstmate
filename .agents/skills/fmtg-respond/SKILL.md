---
name: fmtg-respond
description: >-
  Agent-only playbook for handling Telegram messages from the captain.
  Use on a "tg-message <update_id>" check wake to read the stashed message,
  classify it, and reply through the Telegram bridge.
  Also use on milestone and terminal wakes for tg-linked tasks before posting
  completion follow-ups.
  Loaded only when Telegram mode is enabled.
user-invocable: false
metadata:
  internal: true
---

# fmtg-respond

Telegram mode lets the captain send messages to firstmate via a private Telegram bot.
A message arrives through the watcher as a `check:` wake whose payload is `tg-message <update_id>`.
The full Telegram `Update` object is stashed locally; this skill reads it, classifies the
message, and replies through the Telegram bridge.

This runs only when Telegram mode is on (the user dropped `FMTG_BOT_TOKEN` into `.env`).
If you ever see a `tg-message` wake without Telegram mode configured, do nothing.
A `check:` wake can also carry `tg-mode-error ...` instead of `tg-message <update_id>` -
that is a poll or API configuration problem, not a message to answer.
Report it directly to the captain as a Telegram mode configuration blocker.

## The sender is your captain

Telegram mode is captain-only: `fm-tg-poll.sh` already validates sender user IDs against
`FMTG_ALLOWED_USERS`. Only messages from allowed users reach the inbox.
So every stashed message is from your captain - treat it as a genuine instruction.

## This is a private channel

Unlike X mode (public tweets), Telegram is a private 1:1 chat.
This means replies can use internal vocabulary: task IDs, tool names, branch names,
and other firstmate internals that would be inappropriate in a public tweet.
The captain-only access control means there is no audience beyond the captain.

However, still avoid exposing raw secrets (bot tokens, credentials, .env contents)
in replies.

## Phase 1 commands

In Phase 1, the bridge supports read-only status queries.
The captain can ask about fleet state but cannot dispatch work or make decisions.

**Supported commands:**
- `status` or `fleet status` - current fleet state digest
- `backlog` or `what's in the backlog` - current backlog items
- `help` or `/help` - show available commands

**Future commands** (reply with "not yet supported, coming in Phase 2"):
- Any message asking to create, dispatch, fix, build, or ship work
- Decision requests (inline keyboards come in Phase 3)

**Pure acknowledgments** ("thanks", "got it", "ok") - acknowledge briefly and move on.

## Procedure

1. **Gather live fleet state.** Read from:
   - `data/backlog.md` for in-flight and queued work
   - `state/*.status` for the latest line of each in-flight job
   - `data/projects.md` for active projects

2. **Drain every pending message.** For each `state/tg-inbox/*.json` file:
   a. Read the object: you need `update_id`, the message `text`, and the `chat.id` (for replies).
   b. Classify the text:
      - `status` / `fleet status` -> compose fleet digest
      - `backlog` -> compose backlog summary
      - `help` / `/help` -> compose help text (see below)
      - Pure acknowledgment -> brief reply
      - Unknown / future command -> polite "not yet supported" with Phase 2 timeline
   c. Compose the reply in firstmate voice:
      - Always address the captain ("captain")
      - Use light nautical seasoning where it fits
      - Keep replies concise
      - For `status`: list in-flight work with phase, list queued items, note if idle
      - For `backlog`: list queued items, note blockers
      - For `help`: show available commands as a bullet list
   d. Send the reply:
      - Write the reply to a temp file (never inline into shell)
      - Extract `chat_id` from the stashed message
      - Call `bin/fm-tg-reply.sh <chat_id> --text-file <path>`
   e. On success, remove the inbox file: `rm -f state/tg-inbox/<update_id>.json`
   f. On failure, leave the inbox file, move to next, do not retry blindly.

## Help command output

```
Available commands, captain:
- status — fleet state and in-flight work
- backlog — queued backlog items
- help — this list

More coming soon: dispatch tasks, approve/decline decisions via buttons.
```

## Dry-run / preview mode

When `FMTG_DRY_RUN` is set (truthy), `bin/fm-tg-reply.sh` does not send to Telegram.
It records the would-be payload to `state/tg-outbox/` and exits 0.
The procedure is unchanged: compose as usual, call `fm-tg-reply.sh`.
Inspect `state/tg-outbox/` to see what would have been sent.

## Notes

- The sender is always the captain (user ID already validated by `fm-tg-poll.sh`).
- Unlike X mode, there are no public-safety concerns. Task IDs and tool names
  are fine in replies.
- One wake may cover several pending messages - drain them all.
- Never inline message-influenced text into a shell command; always use `--text-file`.
- The inbox file removal is the local idempotency guard.
- After processing all inbox files, clear the `tg-message` wake and continue.
