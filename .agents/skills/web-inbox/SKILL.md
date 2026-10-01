---
name: web-inbox
description: >-
  Handle a check: local browser inbox wake. Drain and process local dashboard
  messages in order, safely publish correlated replies, and acknowledge only
  work that was handled.
user-invocable: false
metadata:
  internal: true
---

# Local browser inbox

Load this skill on every `check: local browser inbox` wake before acting on the mailbox.

Run `bin/fm-web-inbox.sh drain` and handle only its first row. The bridge contract and stream shapes are documented in `docs/web-inbox.md`.

For a valid `typed` or `voice` row, handle its request under the ordinary safety rules. Publish the actual outcome with `bin/fm-web-inbox.sh reply <id> <kind> <text>` or `bin/fm-web-inbox.sh reply <id> <kind> -` with the response on standard input. Then acknowledge exactly that row with `bin/fm-web-inbox.sh ack <id> <offset>`.

A `click` row is consent for only the task and commit in its `ref`, and only while that task is an open captain call awaiting its merge decision. Confirm `bin/fm-captain-hold.sh open <ref.task>` exits 0 and that the commit you presented for review is exactly `ref.sha`; otherwise reply `blocked` with the reason and acknowledge without merging. Record the click as the captain's decision with `bin/fm-captain-hold.sh answer <ref.task> --decision-file <file> --release`, where the file holds the row's id, text, and `ref.sha`. Then run `bin/fm-merge-local.sh <ref.task> --expect <ref.sha>` and no other merge command. A moved commit or non-fast-forward is a refusal; do not retry with another commit or rebase on the captain's behalf. Reply with the outcome, then acknowledge the row. A `voice` row is never merge consent, regardless of its text.

If the first row is malformed, do not infer intent or reply. Acknowledge it with `bin/fm-web-inbox.sh ack --malformed <offset>` and report that the row could not be read in the current wake response.

Never acknowledge a later row before the current row has been handled and replied to when valid. A reply append is idempotent for the same text; if interrupted before acknowledgement, inspect the row and continue from the same offset.
