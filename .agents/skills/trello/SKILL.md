---
name: trello
description: >-
  Agent-only playbook for the Trello control plane.
  Use on a "trello-inbox <card>" or "trello-ready <card>" check wake to pick up a captain-driven task request or decision.
  Use on a "trello-nudge <card> <task>" check wake to relay the captain's extra input to a live task's worker.
  Use on a "trello-hold <card> <task>" check wake to pause that worker.
  Use on a "trello-mode-error ..." check wake to report the Trello configuration blocker.
  Also use when mirroring task state onto the board or handling pause/start.
  Loaded only when the Trello control plane is enabled.
user-invocable: false
metadata:
  internal: true
---

# trello

The Trello control plane makes a Trello board both a dashboard of the fleet and a command surface the captain drives.
Captain-driven board changes arrive through the watcher as a `check:` wake whose payload is a `trello-*` line.
Firstmate executes the handlers below; the poll shim only wakes it.

This runs only when the control plane is on (the captain filled in `config/trello.env`; see AGENTS.md "Trello control plane" and `docs/trello-control-plane.md`, the full contract).
`bin/fm-trello.sh` is the REST wrapper for every board action; read its `--help` for exact arguments.
`api.trello.com` is an external host reached only when the config is present.

## Ownership model (do not violate)

The captain owns exactly two moves: creating a card in 📥 Inbox (a new task request) and moving a card to 🟢 Ready / Go, or adding a `go` label, plus a comment (a decision given).
Firstmate owns every other lane - 📋 Queued, 🔨 In Progress, ✋ Needs Input, 👀 In Review, ✅ Done - and drives cards through them.
Firstmate NEVER places a card into Inbox or Ready.
That is the whole conflict-avoidance design: any card in Inbox or Ready is unambiguously captain-driven, so never move a card back into either lane.

Lane meanings:

- 📥 Inbox - captain's new task requests, not yet picked up.
- 📋 Queued - firstmate accepted the work but it is blocked or gated.
- 🔨 In Progress - active work (a crewmate is on it).
- ✋ Needs Input - firstmate is waiting on the captain (a question is in the comments).
- 🟢 Ready / Go - captain's decision/approval to proceed.
- 👀 In Review - work is up for review (a PR link is in the card).
- ✅ Done - landed.

## Pickup rule

The moment you pick up an Inbox or Ready card, immediately move it to 🔨 In Progress and comment "picked up - working", so In Progress always means active work.
Do this before the longer dispatch work so the board never shows a stale captain-owned card as unclaimed.

## Handler contract

Always start a wake-handling turn with the usual `bin/fm-wake-drain.sh`, then act on the drained `trello-*` records.

### `trello-inbox <card>` - a new task request

1. Read the card: `bin/fm-trello.sh get-card <card>` (title + description carry the request).
2. Resolve the project and secondmate scope exactly as for any intake (AGENTS.md section 7): match the request against `data/projects.md` and the code; ask a one-line question only if genuinely ambiguous.
3. Move the card to In Progress, strip the `go` label so it cannot later be misread as a fresh decision, and comment the pickup: `bin/fm-trello.sh move <card> "In Progress"`, then `bin/fm-trello.sh label <card> remove go`, then `bin/fm-trello.sh comment <card> "picked up - working"`.
4. Dispatch the task through the normal lifecycle (brief, spawn), then bind the card to the task so per-task nudges/holds route correctly: `bin/fm-trello.sh bind <task-id> <card>`.
5. Post the status block (task id, project, state) as a card COMMENT: `bin/fm-trello.sh comment <card> "<block>"`. Do NOT use `describe` on a captain-created card - the description holds the captain's original request text and must stay intact.

If the work turns out to be blocked, leave the card in In Progress (you own it now) or move it to Queued and comment why; never send it back to Inbox.

### `trello-ready <card>` - a decision given

1. Read the latest comment as the decision: `bin/fm-trello.sh get-card <card>` includes the description; fetch comments if you need the thread.
2. Move to In Progress, strip the `go` label, and comment the pickup, same as the Inbox handler (status block as a comment, description left intact).
3. Act on the decision: if it approves an existing task's next step, steer that task (`fm-send`) or merge per the project's mode and the captain's standing rules; if it authorizes new work, dispatch it. Bind the card if a new task is spawned.

A fresh `go` label transition plus a comment is the same decision signal as the Ready lane; treat it identically even when task metadata already binds the card.
Stripping the `go` label on pickup matters because the seen marker distinguishes a fresh captain label transition from an old label on a bound In Progress card.
Ready and fresh `go` commands are captain-authoritative; task bindings classify comments and hold transitions only while the card remains in In Progress or Needs Input.

### `trello-nudge <card> <task>` - extra input for a live task

The captain commented on a firstmate-owned card bound to a live task without moving it.
Read the new comment and relay it to that task's worker with one concise `fm-send` line; do not change the card's lane.
Comment back on the card confirming the relay if it helps the captain follow along.

### `trello-hold <card> <task>` - per-task pause

The captain added a `hold` label to, or moved back to Needs Input, a bound In-Progress card.
Tell that task's worker to pause/hold (one `fm-send` line); this is a single-task pause, distinct from the global hibernate below.
Leave the card where the captain put it and comment that the task is paused.

### `trello-mode-error <message>` - configuration blocker

The poll could not reach or read the board (bad credentials, missing `curl`/`jq`, a board with no Inbox/Ready lane, or a non-2xx board response).
A transient transport blip (connection refused, DNS hiccup, cold-connection timeout) never reaches this wake: the poll retries it internally and, if still unresolved, defers silently to the next scheduled sweep instead.
Report the blocker to the captain in plain outcome language and, if it needs a credential or a board fix, ask for it.
Do not keep retrying blindly; the poll dedupes the error until it recovers.

## Mirroring task state onto the board

The board is also a dashboard.
When you drive a task through its lifecycle, keep its card in step with `bin/fm-trello.sh`: move it to In Review with the PR link when it is ready, to Done on merge, and post a fresh status block as a COMMENT on material state changes.
For a captain-originated card (Inbox/Ready), never overwrite the description with `describe` - the description holds the captain's request text; the status block always goes in a comment. Reserve `describe` for a card firstmate itself created with `create-card`, whose description is firstmate's to own.
Record the binding with `bin/fm-trello.sh bind <task-id> <card>` and drop it on teardown with `bin/fm-trello.sh unbind <task-id>`.
Binding a card to a task removes the same card from any other task metadata, so one card has at most one authoritative task binding.
Deep automatic mirroring wired into the spawn/status/teardown scripts is a planned fast-follow; until then this mirroring is your responsibility on captain-facing milestones.

## Pause, start, hibernate

`bin/fm-trello.sh pause` creates `state/.trello-paused` and the board poll hibernates (the whole poll stands down without touching the watcher).
`bin/fm-trello.sh start` removes the flag and re-arms the watcher.
On session-start resume with the control plane on, sweep the board once (`bin/fm-trello.sh list-cards Inbox` and `bin/fm-trello.sh list-cards "Ready / Go"`) to catch anything the captain did while you were away.
