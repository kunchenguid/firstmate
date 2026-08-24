---
name: decision-hold-lifecycle
description: >-
  Renamed pointer kept for in-flight briefs: the decisions concept collapsed into one captain-held primitive backed by two stores (backlog task for existing work, firstmate-private register at state/decisions/ for composed decision questions).
  Load captain-hold-lifecycle instead; this stub only redirects and will be removed one release after the collapse.
user-invocable: false
metadata:
  internal: true
---

# decision-hold-lifecycle (renamed)

The separate decision concept was collapsed into one captain-held primitive dispatched across two stores.
An existing story-task held for the captain lives in `data/backlog.md` unchanged; a composed `<origin>-decision-<key>` question with no work item to gate lives in the firstmate-private register at `state/decisions/<id>.md` (story fmops-07 §5, 2026-08-24; invariant "backlog task == story").
Both stores go through the same completion gate, recorded-answer rule, and keyed-answer intake.
Read and follow `.agents/skills/captain-hold-lifecycle/SKILL.md`; it owns those rules and every command this skill used to describe.
Where an older brief says `bin/fm-decision-hold.sh`, that command still works as a one-release compatibility shim over `bin/fm-captain-hold.sh` and routes composed identities into the register automatically.
