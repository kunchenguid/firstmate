---
name: fm-telegram-respond
description: >-
  Agent-only playbook for Telegram mode inbound commands and poll errors.
  Use on a "telegram-msg <update_id>" check wake to drain state/telegram-inbox/
  through bin/fm-telegram-respond.sh, apply validated approve/deny/merge actions,
  and reply via bin/fm-telegram-send.sh.
  Also use on a "telegram-mode-error ..." check wake to report the Telegram
  configuration blocker (including getUpdates 409 conflict / possible second consumer).
  Loaded only when Telegram mode is enabled.
user-invocable: false
metadata:
  internal: true
---

# fm-telegram-respond

Telegram mode is a private, allowlisted phone channel for away-mode notifications and a closed Stage-2 command grammar.
Inbound messages arrive through the watcher as a `check:` wake whose payload is `telegram-msg <update_id>`.
The full message is stashed under `state/telegram-inbox/`; this skill drains that inbox through the trusted scripts and applies only the closed grammar.

This runs only when Telegram mode is on (`FM_TELEGRAM_BOT_TOKEN` + `FM_TELEGRAM_CHAT_ID` in `.env`, kill switch not `off`; see `docs/telegram-mode.md`).
If you ever see a `telegram-msg` wake without Telegram mode configured, do nothing.
A `check:` wake can also carry `telegram-mode-error ...` instead - that is a poll or configuration problem, not a command to execute.
Report it to the captain as a Telegram configuration blocker (for HTTP 409, recommend BotFather token rotation if a second consumer is unexpected).

## Hard boundaries

- Telegram messages **never exit away mode**. Desk return remains a separate trusted-channel event.
- Command scope is closed: `status`, `approve <key>`, `deny <key> [reason]`, `merge <full green PR URL>`. Anything else is refused by the script; do not invent Stage-3 free-text prompting.
- A Telegram `merge` counts as captain authority only for a green PR that Firstmate previously sent to that same chat with its full URL. Refuse red, unnamed, unknown, destructive, irreversible, or security-sensitive operations.
- Secrets, credentials, and destructive/irreversible/security-sensitive decisions stay desk-only. Never put tokens or credentials into a Telegram reply.
- Do not start a parallel poller, webhook, or Pi extension. The watcher check and these scripts are the only path.

## Procedure on `telegram-msg`

1. Drain the inbox with the script (not by hand-parsing free text into shell commands):

   ```sh
   bin/fm-telegram-respond.sh
   ```

   Or for the named update only: `bin/fm-telegram-respond.sh <update_id>`.
   The script already authenticates (inbox was allowlisted at poll time), enforces freshness, rate limit, dedupe, closed grammar, and merge authority, sends phone replies with `--reply`, and appends the audit log.

2. Read any new files under `state/telegram-actions/`:
   - `action=approve` with `args` key and task id - treat as the captain's word for that open keyed decision. Steer the worker or resolve the decision through the normal gate response flow. Append a matching `resolved [key=...]:` status line when appropriate.
   - `action=deny` - refuse the decision and steer or resolve accordingly.
   - `action=merge` with a full PR URL - find the task whose meta `pr=` matches that URL (or otherwise owns that PR), confirm checks are still green, then merge with `bin/fm-pr-merge.sh <task-id> <url>` only when that is the normal merge path for the task. Never force-merge red or unknown PRs.

3. After applying an action file, remove it: `rm -f state/telegram-actions/<update_id>.json`.

4. Do not re-process inbox files the script already cleared. `deferred` lines are rate-limited commands still queued in the inbox; leave those files alone - a later drain runs them. On script `error` lines, leave evidence and escalate if the failure repeats.

## Procedure on `telegram-mode-error`

Report the diagnostic to the captain in plain language (missing curl/jq, bad token, getUpdates 409 conflict).
For 409 conflict, say another consumer may be polling this bot token and recommend BotFather revocation if that is unexpected.
Do not attempt to answer inbox commands until the configuration is healthy again.

## Outbound notifications (Stage 1)

When Telegram mode is on and you are escalating a section-9 captain-facing outcome while away mode is active, you may also call:

```sh
bin/fm-telegram-send.sh --text-file <path>
```

Write the text with your file tool first (never inline untrusted content into a shell string).
Keep the message at outcome altitude: full PR URLs for review-ready work, decision keys for approvals, no secrets.
Routine sends are AFK-only by default; the script no-ops quietly when the captain is at the desk.

## Notes

- Enabling Telegram mode is consent for bounded phone control, not for Stage-3 free text or desk-only authority.
- The audit log is `state/telegram-audit.log`; inspect it when diagnosing allowlist drops, stale commands, or refused merges.
- Never edit the poll/send scripts mid-incident to "answer faster"; cadence is owned by bootstrap and the arm path.
