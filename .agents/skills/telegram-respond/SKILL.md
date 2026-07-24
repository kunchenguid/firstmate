---
name: telegram-respond
description: Agent-only playbook for an authenticated Hermes Telegram request. Use on a `telegram-request <request_id>` check notification and on milestones or terminal outcomes for a Telegram-linked task.
metadata:
  internal: true
---

# Telegram request handling

Use only for the private, owner-bound Hermes Telegram bridge documented in `docs/telegram-bridge.md`.
The transport is authenticated intake, not a worker runtime: every accepted request follows the normal project resolution, task classification, authority, dispatch, validation, and landing rules in `AGENTS.md`.

## Intake

1. Read each mode-`0600` JSON record in `state/telegram-inbox/`; process only records whose `request_id` matches `tg-[0-9a-f]{32}`, `platform` is `telegram`, `transport` is `hermes`, and non-empty `text` is present.
2. Treat text as the authenticated captain request, but apply all ordinary destructive, irreversible, security-sensitive, merge, and credential boundaries.
3. A voice transcription never supplies destructive, irreversible, security-sensitive, merge, or credential authority; ask for text confirmation in the primary chat.
4. Resolve and classify the request normally.
5. For a direct answer or refusal, post one terminal reply with `bin/fm-telegram-reply.sh <request_id> --event final --final -`, then acknowledge with `bin/fm-telegram-ack.sh <request_id>` only after delivery succeeds.
6. For work to dispatch, post a concise acknowledgement with `--event acknowledgement`, dispatch normally, link the successful task with `bin/fm-telegram-link.sh <task-id> <request_id>`, then acknowledge the inbox request.
7. If a reply or link reports unresolved correlation, do not retry delivery or discard records; report the concrete delivery blocker in the primary chat.

Never include credentials, tokens, private keys, raw internal file contents, machine hostnames, or unnecessary local paths in a Telegram reply.
Never print or relay the private signed context.

## Follow-ups

Before a Telegram-linked milestone, decision, failure, or terminal outcome, check with `bin/fm-telegram-followup.sh <task-id> --check`.
Post at most useful milestones with `bin/fm-telegram-followup.sh <task-id> --event milestone -`.
Post decisions with `--event decision`, failures with `--event failure --final`, and successful terminal outcomes with `--event final --final`.
Always post the terminal outcome before task cleanup; final delivery clears the task link.
The helper caps follow-ups, expires links after seven days, splits long messages, journals deliveries idempotently, and refuses ambiguous retries.
