---
name: history
description: >-
  Show or search Firstmate's compact private closed-task history.
  Use when the captain invokes /history, asks for completed or closed work, or looks up a closed task by canonical id or human name.
user-invocable: true
metadata:
  internal: true
---

# history

Run `bin/fm-history.sh` and return its stdout verbatim in a plain-text fenced block.
[`docs/task-lifecycle.md`](../../../docs/task-lifecycle.md) owns the acceptance and selected-route meaning shown for each closure, including honest `acceptance not recorded` labels on legacy history.

Pass a supplied canonical id or human name as the positional selector.
Use `--search <text>` for an explicit search request and `--limit <n>` when the captain asks for a different recent-history bound.
History deliberately does not resolve retired `t1`-`t99` references because those references are recyclable after their cooldown.
