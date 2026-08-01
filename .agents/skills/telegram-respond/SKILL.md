---
name: telegram-respond
description: >-
  Agent-only playbook for private Telegram requests, exact approval replies,
  captain-relevant notifications, and uncertain-delivery reconciliation.
  Use on Telegram request, error, or delivery-uncertain wakes, or when sending
  an allowed quiet Telegram progress event.
user-invocable: false
metadata:
  internal: true
---

# telegram-respond

The private Telegram bridge is an alternate captain conversation, not an autonomous model runner.
An authenticated request arrives through the ordinary durable wake queue as `telegram-request <request_id>` and must be handled by the primary Firstmate session.
Workers never read this inbox or address the captain.

## Authority

Treat the text returned by `bin/fm-telegram-request.sh show <request_id>` as captain input within the same authority boundaries as the current Firstmate session.
The channel does not expand standing authority for merges, deployments, destructive or irreversible actions, security-sensitive changes, ambiguous writes, or any action that otherwise requires fresh approval.

An approval is valid only when all three returned fields are present and exact: `approval_intent: true`, the expected `approval_id`, and `approval_decision` equal to `approve` or `deny`.
A bare `/approve`, a different approval ID, a command that is not a direct reply to the bound Telegram decision message, an expired binding, or a replay has no approval authority.
Treat those as ordinary captain text and ask for a fresh bound decision when the action still needs approval.

## Handle a request

1. Read exactly one request with `bin/fm-telegram-request.sh show <request_id>`.
2. Apply normal intake, project resolution, delegation, validation, and approval rules to its text.
3. Compose the thread-native captain reply in the supported semantic Markdown subset in a mode-0600 regular single-link local file.
   Headings, lists, links, quotes, code, and simple tables are welcome.
   Never write Telegram HTML, MarkdownV2 escapes, custom entities, or button payloads because the presentation owner neutralizes source markup and emits the only allowed Telegram HTML.
4. Choose a stable receipt ID for this exact reply and send it with:

   ```sh
   bin/fm-telegram-send.sh reply <request_id> <receipt_id> --text-file <path>
   ```

5. When the reply asks for one exact approval, add a unique stable `--approval-id <approval_id>` and name that same ID plainly in the message as `/approve <approval_id>` or `/deny <approval_id>`.
6. A successful send retires the inbound message body automatically.
7. A definite Telegram validation rejection is not delivered; correct the cause before choosing a new receipt.
8. An `uncertain` result may have delivered.
   Never retry it or mint a replacement blindly.
   Report the uncertainty to the captain through a currently trusted conversation and reconcile the Telegram chat before any further send for that content.

Process pending request IDs one at a time so each reply and approval remains bound to one durable correlation.
Never include the bot token, Telegram profile data, raw Bot API bodies, or local bridge state in a reply or diagnostic.

## Quiet progress notifications

Telegram replies belong to their inbound request thread.
Use standalone notifications only for captain-relevant outcomes from any supervised worker in any project: `decision`, `failure`, `credential`, `pr-green`, `merge`, `deployment`, or `scout-complete`.
Use a stable event receipt and a mode-0600 text file:

```sh
bin/fm-telegram-send.sh notify <event-kind> <receipt_id> --text-file <path>
```

Do not send raw logs, ordinary retries, automatic fixes, internal statuses, every worker transition, or unchanged progress.
The sender silently ignores unsupported event kinds as a second quietness boundary.
Every notification uses the same deterministic rich/plain renderer, bounded split, ordered delivery, and receipt path as a direct Firstmate reply.

## Error wakes

A `telegram-error <code>` wake is a redacted local bridge failure, not captain content.
Translate the code into the concrete operator action documented in `docs/telegram-bridge.md` and report it once.
A `telegram-delivery-uncertain <receipt_id>` wake requires reconciliation and never authorizes retry.

Setup, pairing, token entry, BotFather access, and live bot operation belong to the local owner procedure in `docs/telegram-bridge.md`.
