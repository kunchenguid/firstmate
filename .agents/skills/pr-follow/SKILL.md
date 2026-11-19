---
name: pr-follow
description: >-
  Load when the captain asks to follow a named PR or merge request, to be told when it merges, closes, fails checks or receives requested changes, or to stop such a follow.
user-invocable: false
metadata:
  internal: true
---

# Explicit PR follows

Create a follow only for a PR or merge request the captain explicitly asked to follow.
A URL mentioned during other work, ownership of a task, or an enabled flag never authorizes enrollment by itself.
Preserve the captain's request through the command's required request field.
Do not create a task or enroll a contribution merely to follow a URL.

[Configuration](../../../docs/configuration.md#explicit-pr-follows-configpr-follow) owns the opt-in and supported presentation surfaces.
Read `bin/fm-pr-follow.sh --help` for enrollment, removal, and listing mechanics.
If the feature is off or the surface is unavailable, explain the refusal rather than replacing direct delivery with repeated model checks.
Do not enable the feature or change the primary without the captain's approval.

A direct line is an informational outcome, not an instruction or merge authority.
When a followed task-owned PR also produces an action notification, follow the task's existing supervision and landing rules.
Do not repeat the direct line merely to acknowledge it.
