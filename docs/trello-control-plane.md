# Trello control plane

The Trello control plane turns a Trello board into both a visual dashboard of firstmate's fleet and a two-way command surface the captain drives.
Firstmate mirrors task state onto cards, and the captain drives the fleet by creating and moving cards.
It ships inside this repo for every user but is inert until opted in, exactly like X mode: a user who never enables it sees zero behavior change.

This doc is the single owner of the control-plane contract.
`AGENTS.md` keeps only the load trigger and the ownership-model summary; the `/trello` agent skill owns the handler procedure firstmate executes on a wake.

## Activation is config presence, not a command

The control plane is off unless the firstmate home's gitignored `config/trello.env` supplies all three of `TRELLO_API_KEY`, `TRELLO_TOKEN`, and `TRELLO_BOARD_SHORTLINK`.
Copy `docs/examples/trello.env` to `config/trello.env` and fill in the values.
`config/trello.env` is gitignored; never commit a real token.
An incomplete file (any of the three missing) is treated as off.
`TRELLO_API_BASE` is optional and defaults to `https://api.trello.com`, mainly for developers pointing at a mock.
For direct client invocations, environment values override the file; `FM_TRELLO_ENV_FILE` can point a direct call at another config file, but bootstrap activation still keys off `$FM_HOME/config/trello.env`.

`api.trello.com` is an external host.
Firstmate reaches it only when the config is present.
The Trello CLI and the Atlassian gateway cannot post comments, so the control plane talks to the REST API directly, authed with `?key=<TRELLO_API_KEY>&token=<TRELLO_TOKEN>`.
`bin/fm-trello-lib.sh` writes those credentials into a `0600` `-K` curl config file rather than the command line, so a token never appears in `ps`/argv - the same discipline as X mode's bearer-header temp file.

## Bootstrap wiring

The locked session-start bootstrap step turns the config into local generated state, purely additively, without touching any watcher-backbone file.
It writes `state/trello-watch.check.sh`, registers that shim in `state/trello-watch.check-trust`, and writes `config/trello-mode.env`, which exports `FM_CHECK_INTERVAL=60` for watcher processes in that home.
The watcher runs every `*.check.sh` shim each check cycle and turns any stdout into a `check:` wake, so the poll needs no watcher edit.
A Trello home polls once per minute instead of the default 300; only a Trello (or X) home speeds up because a non-Trello home has no `config/trello-mode.env`.
Every watcher startup, guard repair, session-start next step, and native harness arm path sources `config/trello-mode.env` when present.
When both control planes are active, Trello cadence is sourced first and X cadence is sourced second, so the faster X setting remains authoritative.
`bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, so a cadence transition (opt-in while a watcher is already running, or opt-out) is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap never restarts the watcher itself.
When the config is removed or incomplete, the next locked session-start bootstrap step removes those artifacts; steady-state off is silent and writes nothing.
Because Trello mode is a reason to keep the watcher armed even with no fleet work, a Trello-only user is still served.

## Board layout and lanes

The board uses seven lanes, left to right:

- 📥 Inbox
- 📋 Queued
- 🔨 In Progress
- ✋ Needs Input
- 🟢 Ready / Go
- 👀 In Review
- ✅ Done

Lane name-to-list-id resolution is dynamic: `bin/fm-trello-lib.sh` queries `GET /1/boards/<shortLink>/lists` and matches a lane by its normalized name (lowercased, alphanumeric only, so the emoji prefix and separators do not matter).
No list id is ever hardcoded, because every user's board has different ids.
The card description holds a structured status block (task id, project, state, PR/report link); comments are the question-and-answer channel.

## Ownership model

The ownership split is what prevents bidirectional-sync conflicts.

The captain owns exactly two moves:

- creating a card in 📥 Inbox - a new task request; and
- moving a card to 🟢 Ready / Go (or adding a `go` label) plus a comment - a decision given.

Firstmate owns every other lane (Queued, In Progress, Needs Input, In Review, Done) and drives cards through them.
Firstmate never places a card into Inbox or Ready, so any card there is unambiguously captain-driven - that is what lets the poll treat lane membership as a trust signal.

Pickup rule: the moment firstmate picks up an Inbox or Ready card, it immediately moves the card to 🔨 In Progress and comments "picked up - working", so In Progress always means active work.
The `/trello` skill owns the pickup and mirror procedure firstmate executes.

## Inbound poll: captain-driven triggers

`bin/fm-trello-poll.sh` is the body of the check shim.
It is a hard no-op without the config, and also while `state/.trello-paused` exists (the global hibernate; see below).
One board-cards fetch (`GET /1/boards/<shortLink>/cards`) gives every open card's lane, labels, and comment count, enough to classify all triggers without per-card round-trips.
It emits at most ONE trigger line per sweep, which becomes the watcher's `check:` wake payload:

- `trello-inbox <cardid>` - a new or updated card in Inbox (a new task request).
- `trello-ready <cardid>` - any card in Ready / Go, or a card with a fresh captain-applied `go` label transition plus a comment (a decision given), regardless of task binding.
- `trello-nudge <cardid> <taskid>` - a new captain comment on a firstmate-owned card that is bound to a live task and sits in In Progress or Needs Input (extra input; firstmate relays it to that task's worker without changing the lane).
- `trello-hold <cardid> <taskid>` - a `hold` label on, or a captain move back to Needs Input of, a bound In-Progress card (a per-task pause; firstmate tells that worker to pause).

Only ONE trigger is emitted per sweep, matching `fm-x-poll.sh`'s one-line-per-sweep contract: the watcher captures all of the shim's stdout as a single wake payload and `fm_wake_clean_field` flattens newlines to spaces, so emitting several differing-arity trigger lines at once would collapse into an unparseable blob. Any other firing-eligible card keeps its marker and fires on a later sweep, so no trigger is dropped.

Captain-owned Ready and fresh `go` commands outrank task bindings, including current bindings and metadata left behind by completed or dead tasks.
Bindings classify only firstmate-owned In Progress and Needs Input activity as `trello-nudge` or `trello-hold`, so a leftover `go` label on an already-seen bound card does not turn a later In Progress comment into a Ready command.
`bin/fm-trello.sh bind` makes its target task the only authoritative metadata binding for a card by removing that exact card from other task metadata.
The poll also resolves any legacy duplicate bindings deterministically by task id as a fail-safe read behavior.

### Idempotency

A per-card seen marker `state/.trello-seen-<cardid>` records the card's `dateLastActivity`, current list id, `go` label state, and comment count.
A card fires only when activity advanced past the marker (or the marker is absent, for the inherently-new Inbox and Ready cases), so the same activity never wakes firstmate twice.
Every `bin/fm-trello.sh` mutation bumps the marker to the card's post-change state, so firstmate's own edits never wake it - only a genuine captain edit advances `dateLastActivity` beyond the marker.
The poll sweep and every board mutation or binding change hold the same portable `state/.trello-sync.lock` through their marker update, so another process cannot observe a firstmate edit in the post-mutation/pre-marker window.
The poll distinguishes a per-task pause (a captain move back to Needs Input) from a nudge (a comment on a card firstmate already parked in Needs Input) using the marker's recorded prior list id.
Legacy two-field markers remain readable and treat an existing `go` label as pre-existing rather than fresh.
Cards in firstmate-owned lanes that are not bound leave no marker, so marker files stay bounded to relevant cards.

## `bin/fm-trello.sh`

The REST wrapper is inert (a silent exit-0 no-op) for every subcommand when the config is absent; `--help` always works.
Subcommands: `comment`, `move`, `describe`, `create-card`, `label add|remove`, `list-cards`, `get-card`, `bind`, `unbind`, `card-for`, `pause`, `start`.
Lane names resolve to list ids dynamically; card ids are a shortLink or a full card id and are validated against a path-traversal guard.
`move` and `create-card` refuse an Inbox or Ready target lane (`deny_captain_lane`), enforcing in code that firstmate never writes a card into a captain-owned lane.
Mutating calls fail loudly (non-zero, stderr) on a non-2xx response.
See the script header for the exact endpoints and argument shapes.

## Pause, start, and hibernate

`bin/fm-trello.sh pause` creates `state/.trello-paused`; the poll no-ops while it exists, so the whole control plane hibernates without touching the watcher backbone.
`bin/fm-trello.sh start` removes the flag and arms the watcher so the poll runs again even with no fleet work.
When paused with no other fleet work, the watcher stands down.
Session-start bootstrap re-arms the poll shim, and firstmate should sweep the board once on resume to catch anything the captain did while paused.
Auto-hibernate-after-idle is a documented follow-up, not yet implemented.

## Outbound mirror

The outbound mirror (firstmate reflecting task state onto cards) is agent-driven: the `/trello` skill instructs firstmate to run `bin/fm-trello.sh` at lifecycle points (create/move a card, post a fresh status block as a comment, move to Done on merge) and to record the `trello_card=` binding with `bin/fm-trello.sh bind`.
`describe` is reserved for a card firstmate itself created with `create-card`; a captain-originated card's description holds the captain's request text and is never overwritten.
Deep automatic mirroring wired directly into the spawn, status-change, and teardown scripts - so every task, not only board-originated ones, mirrors without an agent step - is a planned fast-follow.

## Webhooks (future enhancement)

The current design polls the board on the watcher's once-per-minute cadence, which is simple, stateless, and needs no inbound network exposure.
A future enhancement could register a Trello webhook (`POST /1/webhooks` with a callback URL) so board changes push to firstmate instead of being polled, cutting latency and API calls.
That requires a reachable HTTPS callback endpoint and webhook-signature verification, so it is deferred; the poll remains the reference mechanism.

See also `docs/configuration.md` ("Trello control plane") for the environment-variable reference.
