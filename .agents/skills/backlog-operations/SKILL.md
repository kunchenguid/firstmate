---
name: backlog-operations
description: >-
  Agent-only intake reference for deciding what to do with a captain request.
  Load before using the opt-in System One intake classifier.
user-invocable: false
metadata:
  internal: true
---

# backlog-operations

Before classifying a captain request, run the opt-in `bin/fm-intake-classify.sh` directly on the request file in the same turn.
Its result recommends only `ship`, `scout`, or `answer_now` with urgency and never authorizes a spawn or replaces your intake judgment.
`docs/configuration.md` "Typed intake classification" owns the complete contract and every status meaning.
