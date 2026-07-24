---
name: topic-board
description: >-
  Agent-only procedure for handling durable Telegram topic-board messages and linked worker returns.
user-invocable: false
metadata:
  internal: true
---

# Telegram topic board

Load this skill on a `check: topic-board: topic-message ...` wake and before acting on a worker return that names a `topic-item`.
The durable item and its local topic map are authoritative for origin and routing.

## Intake

1. Drain the normal firstmate wake queue before inspecting the topic inbox, as required by the supervision contract.
2. Run `bin/fm-topic-inbox.sh list` and inspect every listed item with `bin/fm-topic-inbox.sh show <update-id>`.
3. Claim an item before starting work with `bin/fm-topic-inbox.sh claim <update-id> <owner>`.
4. Use `main` as the owner for work handled directly, or use the routed secondmate or task id for delegated work.
5. Include the exact marker `topic-item <update-id>` in routed instructions and require that marker in every milestone or terminal return.

The listener retains claimed items in the inbox until a successful answer is recorded.
Never delete or bulk-clear inbox files.

## Routing

Read each item's `route` field.
For a route naming a registered secondmate, load `secondmate-provisioning`, route the request to that secondmate, and include the `topic-item` marker.
For `main`, handle the request under the normal firstmate project and task lifecycle.
For an unknown route, stop safely and treat it as `main` only after reporting that the local map needs correction.

An optional acknowledgement may be sent without closing the item by using a stable follow-up key such as `acknowledgement`.
The worker's actual outcome must still be returned into the originating topic.

## Reply

Write captain-facing response text to a private temporary file, then use the tracked sender so shell interpolation cannot alter the message.

```bash
bin/fm-topic-reply.sh <update-id> --text-file <private-response-file>
```

A successful initial reply archives the item as answered.
For later milestones or completion updates, use a stable idempotency key against the archived item.

```bash
bin/fm-topic-reply.sh <update-id> --follow-up completion --text-file <private-response-file>
```

If the sender reports that delivery is unknown, inspect the originating Telegram topic before choosing either `--confirm-sent` or `--retry-unknown`.
Never retry an ambiguous send automatically because Telegram has no idempotency key for `sendMessage`.

## Safety

This feature owns only the separate topic-board bot configured under `data/fm-telegram-topics/`.
Never point it at the direct-message firstmate bot or touch that bot's plugin poller.
Telegram permits only one `getUpdates` consumer per token, so sharing the direct-message token would let the topic listener steal the captain's lifeline messages.
