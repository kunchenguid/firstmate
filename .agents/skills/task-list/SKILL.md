---
name: task-list
description: >-
  Show Firstmate's compact current task table in conversation when the captain asks in natural language for the task list, task table, or work underway.
  The literal /tasks command belongs to Pi's live toggleable widget and must not invoke this skill.
user-invocable: true
metadata:
  internal: true
---

# task-list

For a natural-language request that needs a task table in conversation history, run `bin/fm-tasks.sh --table` and return its stdout verbatim in a plain-text fenced block.
Do not convert the rendered borders to Markdown table source, tabs, or a prose status list.

When the captain supplies a selector in natural language, pass it to `bin/fm-tasks.sh --table` so the central resolver accepts a canonical task id, a `t1`-`t99` reference, or an unambiguous human name.
For the literal `/tasks` command, do nothing here: Pi's extension-owned command toggles the session-local live task widget without a model turn or conversation entry.

Names are concise two-to-four-token lowercase hyphenated shorthands, and are separately editable with `bin/fm-tasks.sh name <selector> <name>` when the captain explicitly asks to rename one.

[`docs/task-lifecycle.md`](../../../docs/task-lifecycle.md) owns every displayed status, route, and closure prerequisite.
The command derives that captain-facing projection from canonical task records; durable post-review rows remain visible until guarded closure, while unreviewed legacy Done rows still follow configured backlog retention.
