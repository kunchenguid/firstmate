# Multi-account dispatch pool

Firstmate normally launches every crewmate on whatever single account the harness CLI happens to resolve.
When that one account hits its session limit, every crewmate wedges at the same moment and the whole fleet stalls.
The dispatch pool spreads new spawns across several independent accounts and takes an exhausted one out of rotation until it resets.

This document owns the pool's configuration schema, rotation contract, limit-signature catalogue, and failover procedure.
`bin/fm-pool.sh`, `bin/fm-pool-failover.sh`, and `bin/fm-spawn.sh` own their own exact flags and mechanics in their headers and `--help`.

## Inert until opted in

The pool does nothing until `config/dispatch-pool.json` exists.
With that file absent, `bin/fm-pool.sh` exits 3 without touching state, `bin/fm-spawn.sh --pool` prints one warning and spawns exactly as an unpooled task would, and every path that does not pass `--pool` is unchanged down to the bytes written into `state/<id>.meta`.
`config/` is captain-private and gitignored, so the config never ships with the repo; `docs/examples/dispatch-pool.json` is the tracked example to copy.

## Two different axes: account and runtime backend

Firstmate already had a "backend" concept, and the pool deliberately does not reuse the word in metadata.

| Axis | Selected by | Recorded in meta | Meaning |
|---|---|---|---|
| Runtime session provider | `fm-spawn.sh --backend` | `backend=` | tmux, herdr, zellij, orca, cmux - where the pane lives |
| Agent account | `fm-spawn.sh --pool` | `pool_backend=` | which login or API key the harness authenticates as |

`backend=` is the established runtime-backend contract that `fm_backend_of_meta` and every watcher, teardown, and recovery path parses, and an absent `backend=` means tmux.
Writing an account id into that key would make every one of those readers resolve an unknown runtime backend.
So the account is always `pool_backend=`, written only for a pooled spawn.

## Configuration schema

`config/dispatch-pool.json` is an object with a `backends` array.

| Field | Where | Required | Meaning |
|---|---|---|---|
| `backends` | top level | yes | ordered array; rotation follows this order |
| `cooldown_default_seconds` | top level | no | cooldown applied when a limit report carries no reset time (default 10800) |
| `id` | backend | yes | unique account id, used in metadata, state file names, and messages |
| `harness` | backend | yes | the verified harness adapter this account launches |
| `enabled` | backend | no | only an explicit `false` disables; absent means enabled |
| `env` | backend | no | object of non-secret env assignments applied to that launch only |
| `key_env` | backend | no | env var name a secret must arrive in, for example `CURSOR_API_KEY` |
| `key_file` | backend | no | path to that secret; defaults to `~/.config/firstmate/keys/<id>.key` |
| `model` | backend | no | model this account defaults to; an explicit `--model` still wins |
| `effort` | backend | no | effort this account defaults to; an explicit `--effort` still wins |
| `note` | backend | no | free text, ignored by the tooling |

`~` and `$HOME` are expanded in `env` values and `key_file`.
No config value is ever passed to a shell for evaluation.

## Key handling

Keys live OUTSIDE this repo, at `~/.config/firstmate/keys/<backend-id>.key`, mode 600 in a mode 700 directory.
They are never relocated into `config/`, never committed, and never inlined.

`bin/fm-pool.sh` never reads a key's contents.
It reads only enough to answer "is this file non-blank", and it emits the key's *path* and the env var *name*, never the value.
`bin/fm-spawn.sh` puts that path on the launch command as `NAME="$(cat '<path>')"`, so the pane's own shell expands it at launch time.
The secret therefore never appears in this repo, in a command line firstmate constructs, in captured pane text, in `state/<id>.meta`, in a log, or in an error message - only in the launched process's own environment, which is the minimum required for it to work at all.

A backend whose key file is missing or empty is reported as unhealthy with that exact reason and skipped.
It is never a crash and never a failed spawn.

## Rotation

Rotation is equal round-robin over healthy backends.
`state/.pool-cursor` holds the last selected account id; the next selection resumes at the following config-order position and takes the first healthy account, wrapping around.
`state/.pool.lock` serializes that read-modify-write so two concurrent spawns do not both land on the same account; the lock is acquired with a bounded retry, and a busy lock degrades to an unlocked selection with a warning rather than blocking a spawn.

A backend is unhealthy when it is explicitly disabled, when its key file is missing or empty, or while it is in cooldown.
Every skipped backend is reported on stderr with its concrete reason, so a rotation that quietly narrows to one account is visible rather than silent.

When no healthy backend remains, `select` exits 4 and names the earliest reset time and the account it belongs to, rather than handing work to a dead account.
A `fm-spawn.sh --pool` that hits that exit refuses the launch; an exit 2 (malformed config, unknown account, or missing `jq`) is reported separately as a configuration error, because a broken config is not exhausted capacity.

Only crewmate and scout spawns rotate: `--pool` and `--pool-backend` are refused on a `--secondmate` spawn, whose account is pinned by its own home configuration.
A per-task harness override outranks the pool's spread: an explicit `--harness` or positional adapter name narrows rotation to accounts of that harness, while a raw launch command names no account harness and so only suppresses the account's harness default.

## Limit detection and cooldown

A cooldown is stored at `state/.pool-cooldown-<id>` holding `until=<epoch>`, `set=<epoch>`, and `reason=`.

Cooldowns expire on their own.
Every reader treats `now >= until` as expired and unlinks the file opportunistically, so a cooldown never needs manual clearing and a forgotten one cannot strand an account.
`fm-pool.sh clear` exists for tests and captain overrides, not for routine operation.

`fm-pool.sh detect` classifies agent output. Observed and handled signatures:

| Signature | Classified as | Reset |
|---|---|---|
| `You've hit your session limit · resets 2:20pm (America/Los_Angeles)` | `session-limit` | parsed from the message |
| `usage credits exhausted` | `credits-exhausted` | none; default interval |
| `Fast mode disabled · usage credits exhausted` | `credits-exhausted` | none; default interval |
| `quota exceeded`, `insufficient quota` | `quota-exceeded` | parsed when present |

The table shows the observed forms the matcher was built from; `bin/fm-pool.sh`'s classifier owns the exact patterns and also accepts close variants (for example `hit your usage limit`, `rate limit reached`, `credit balance is too low`).

A reset time is parsed in the timezone the message names (local time when it names none), in either 12-hour (`2:20pm`) or 24-hour (`14:20`) form, and rolls to tomorrow when that time has already passed today.
Two guards keep a bad parse from doing damage: a reset that resolves to the past or is absent falls back to `cooldown_default_seconds`, and every cooldown is clamped to `FM_POOL_MAX_COOLDOWN_SECONDS` (default 24 hours).

## Failover for a task already under way

`bin/fm-pool-failover.sh <task-id>` moves a running task to a different account after its current one wedges.

It follows the established recovery convention: committed work stays on the task's branch, a RESUME NOTE is appended to `data/<id>/brief.md` naming the branch and tip commit, and the task is respawned on a healthy account.
The replacement is preferably an account on the task's own harness; when none is healthy the search widens to every harness, and a cross-harness move drops the recorded model and effort so the new harness runs on its own defaults instead of a foreign model id.

**It refuses to run when the worktree has uncommitted changes.**
A respawn abandons the old worktree, so uncommitted work would be lost, and that is exactly how work was lost the day this was built.
There is deliberately no `--force`.
The refusal is a stop-and-investigate result: commit the work on the task branch, then re-run.

It also refuses a detached HEAD, a worktree sitting on a default branch, and a secondmate task.
It never force-pushes and never touches a default branch.

The dirty-worktree check runs twice: once before anything is touched, and again after the old agent is killed, because a dying agent can still write.
The second refusal stops with nothing else changed - the RESUME NOTE is appended only after that re-check passes, so a refused failover never leaves the brief claiming a move that did not happen.

`--from-file <agent-output>` supplies the limit evidence that sets the old account's cooldown.
When that file holds no signature the matcher recognizes, the failover still cools the account down for `cooldown_default_seconds` rather than leaving it healthy: a wedged account left in rotation would be handed the very next crewmate, which is worse than the evidence-free default.

## Interactive sessions are never affected

The pool only ever influences NEW spawns.
It never kills, interrupts, logs out, or re-authenticates a running agent, and it never edits a global harness config.
An account's env is applied as a prefix to one launch command and nothing else.

This matters because one pooled account may also be the account an interactive router session is running on.
Putting that account into cooldown stops new spawns from being sent to it; it does not disturb the live session at all.

## Verification

`tests/fm-pool.test.sh` covers rotation, cooldown skipping, self-expiry, limit parsing, key-file health, and the all-cooling refusal.
`tests/fm-pool-failover.test.sh` covers the dirty-worktree refusal (including work appearing during the old agent's shutdown), the clean-worktree path, the RESUME NOTE, and same-harness-first replacement selection with the cross-harness model/effort drop.
`tests/fm-spawn-pool.test.sh` covers `--pool` metadata, the pooled launch prefix, secret non-disclosure, rotation across successive spawns, the all-cooling refusal, positional-harness narrowing, the `--secondmate` refusal, and the byte-identical unpooled path.
