---
name: tasks
description: >-
  Show Firstmate's compact current task table with short references, editable human names, normalized status, and current outcome.
  Use when the captain invokes /tasks, asks what tasks are underway, or refers to a task by its short reference.
user-invocable: true
metadata:
  internal: true
---

# tasks

Run `bin/fm-tasks.sh --table` and relay its compact table without inventing another status list.

When the captain supplies a selector, pass it to `bin/fm-tasks.sh` so the central resolver accepts a canonical task id, a `t1`-`t99` reference, or an unambiguous human name.

Names are separately editable with `bin/fm-tasks.sh name <selector> <lowercase-hyphenated-name>` when the captain explicitly asks to rename one.

The command derives status from the canonical backlog and current-state reconciler, and keeps retained Done rows only as long as the backlog does.
