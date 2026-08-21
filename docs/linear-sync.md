# Linear synchronization

Audience: operator, current behavior.

Firstmate can hold one rule mechanically: work is not complete until the corresponding Linear issue is current.
A task is explicitly bound to one or more Linear issues, every handback is a durable record, delivery is idempotent, and cleanup refuses while a bound task still owes one.

It is off unless a home creates the credential file below and binds at least one task.
A home that never binds a Linear issue gains no state, runs no extra command, and prints nothing.

`bin/fm-linear-sync.sh --help` owns the exact commands and flags.
`bin/fm-linear-transport.sh --help` owns the transport contract.

## What it guarantees

- **A target is established, never inferred.** There is no transcript scraping and no prose matching. A task with no binding refuses to queue anything, a task bound to more than one issue refuses until one is named, and a comment is exactly the bytes you supplied.
- **Delivery is idempotent.** A delivery's identity is derived from its own content, so re-queueing the same handback after a retry, a crash, a context compaction, or a restart resolves to the same record and changes nothing.
- **A lost acknowledgement cannot duplicate a comment.** Every posted comment carries a marker derived from that delivery. Before posting, the issue's own comments are read back and searched for it, so Linear's copy - not the local receipt - is what proves the comment landed. A local receipt alone would miss the interval where Linear commits the comment and the response never arrives.
- **A disconnected Linear never becomes a completion.** With no credential, an unreachable API, or an unconfirmed status change, the handback is preserved untouched, one concise blocker is printed, and the command exits non-zero. Repeated runs converge with no duplicate comment and no second status change.
- **Two deliveries cannot race into a duplicate.** A per-delivery lock serializes the read-then-post sequence, and an abandoned lock is taken over after `FM_LINEAR_LOCK_STALE_SECS` so a crashed delivery stays retryable rather than stranded.
- **Cleanup enforces it.** `bin/fm-teardown.sh` refuses to clean up a task while exactly that task still owes a handback, unless `--force` carries explicit discard approval.

## Setup

1. Create a Linear API key. In Linear, open Settings, then Security & access, then Personal API keys, and create one scoped to the workspace whose issues firstmate should update. An OAuth access token works too; paste it as `Bearer <token>`.
2. Write it into this firstmate home's gitignored credential file, which must be mode 0600:

   ```sh
   ( umask 077; printf 'LINEAR_API_KEY=%s\n' '<your-key>' > "$FM_HOME/config/linear.env" )
   chmod 600 "$FM_HOME/config/linear.env"
   ```

3. Confirm the home can see it:

   ```sh
   bin/fm-linear-sync.sh status
   ```

`config/linear.env` is the single credential and configuration owner.
It accepts `LINEAR_API_KEY` and an optional `LINEAR_API_URL` (an `https://` endpoint; the default is `https://api.linear.app/graphql`).
The file is refused rather than used when it is a symlink, has more than one hard link, is not mode 0600, or holds a key with whitespace or control characters, so a world-readable paste fails loudly instead of leaking.
`config/` is gitignored in full, so the key is never committed.

The key never reaches a command line, a log, a request body, a durable record, or a report.
`bin/fm-linear-transport.sh` writes it to a mode-0600 temp file as a complete header line, hands `curl` that file, and removes it on every exit path.

## Using it

```sh
# Bind the work to its issue, once.
bin/fm-linear-sync.sh bind <task-id> ENG-123

# Queue the exact handback the issue should receive.
bin/fm-linear-sync.sh queue <task-id> --comment-file handback.md --status Done

# Deliver everything this home still owes.
bin/fm-linear-sync.sh deliver --all

# See what is still owed.
bin/fm-linear-sync.sh pending
```

`--status` is a Linear workflow state name exactly as the team spells it, such as `In Progress` or `Done`.
Omit it to post a comment and change nothing else.
A status change is applied only when the issue is not already in that state, and it is confirmed by reading the state back.

`bin/fm-linear-sync.sh guard-work <task-id>` is the completion gate cleanup calls.
`bin/fm-linear-sync.sh hook` is the passive surface described below.
`bin/fm-linear-sync.sh discard <delivery-id> --reason <why> --yes` is the only way to drop an owed handback without delivering it, and the discard itself is recorded.

## Where it is enforced

Two integration points, both independent of which harness the primary session runs.

`bin/fm-teardown.sh` runs the completion gate before it removes anything.
The refusal names the task, the issue, and the delivery, and preserves every record.

The session-start digest prints a "Linear issues awaiting synchronization" subsection whenever, and only when, this home still owes a handback.
It is read from disk, so a compaction or a restart is a non-event.

Both gates start with one `[ -d ]` test on `state/linear`, so a home that never bound an issue pays nothing for either.

No harness hook file registers Linear synchronization, and none needs to.
Every supported primary harness turn-end surface (Claude and Codex `Stop`, OpenCode `session.idle`, Pi `agent_settled`, Grok `Stop`, Cursor `stop`) is already owned by a single continuation state machine documented in [`turnend-guard.md`](turnend-guard.md), whose job is watcher liveness and whose failure modes are per-harness.
Adding a second, unrelated verdict to that boundary would put an unfinished Linear handback in a position to hold a turn open, on six separately-behaving surfaces, for no gain over the harness-independent gates above.
`bin/fm-linear-sync.sh hook` exists for an operator who does want that nag: it is scoped to a genuine firstmate primary home, prints nothing in an ordinary project repo, a crewmate or scout task worktree, or a home with no owed handback, and never blocks.

## Private state

All of it lives under `state/linear` (mode 0700), created only by `bind`:

| Path | What it holds |
| --- | --- |
| `bindings/<task-id>` | the durable task-to-issue binding |
| `outbox/<delivery-id>.json` | typed pending deliveries, immutable once written |
| `sent/<delivery-id>` | the receipt ledger for confirmed handbacks |
| `attempts/<delivery-id>` | retry state for a held delivery, kept beside the record so its identity never moves |
| `refused/<delivery-id>.json` and `.reason` | a delivery Linear rejected, preserved with a one-line reason |
| `discarded/<delivery-id>` | explicitly authorized discards |
| `.lock.<delivery-id>` | a delivery in progress, taken over after `FM_LINEAR_LOCK_STALE_SECS` |

A refused delivery still blocks cleanup.
A refusal is an unfinished handback that needs a decision, not a discarded one.

## Tuning

| Variable | Default | Effect |
| --- | --- | --- |
| `FM_LINEAR_COMMENT_MAX` | 6000 | maximum characters in one handback comment |
| `FM_LINEAR_COMMENT_PAGE_SIZE` | 100 | comments fetched per read-back page |
| `FM_LINEAR_COMMENT_PAGE_MAX` | 10 | read-back pages walked before the delivery holds instead of posting |
| `FM_LINEAR_RETRY_BACKOFF_SECS` | 900 | recorded next-attempt spacing for a held delivery |
| `FM_LINEAR_LOCK_STALE_SECS` | 300 | age at which a per-delivery lock is treated as abandoned and taken over |
| `FM_LINEAR_HTTP_TIMEOUT` | 20 | per-request timeout in `bin/fm-linear-transport.sh` |
| `FM_LINEAR_TRANSPORT` | `bin/fm-linear-transport.sh` | an executable satisfying the transport contract, used instead of the real one |

`FM_LINEAR_TRANSPORT` is what makes the whole path testable with no credential and no network; `tests/fm-linear-sync.test.sh` points it at a hermetic fake workspace.

## Supported limits

- One credential per home. Cross-workspace issues need separate homes.
- An issue with more comment pages than `FM_LINEAR_COMMENT_PAGE_MAX` holds rather than posting, because an unproven absence is treated as unknown. Raise the bound for a very long issue.
- Only the comment body and the workflow state are synchronized. Assignees, labels, estimates, relations, and attachments are not.
- `jq` is required. Without it, every command that builds or reads a typed record holds rather than proceeding.
- The GraphQL documents are written against Linear's published API and are exercised end to end only against the hermetic fake. They have not been run against the live service from this repository. If Linear's schema differs, a delivery holds with the API's own message and no handback is lost; correcting the documents is a one-file change in `bin/fm-linear-sync.sh`.

See [verification/linear-sync.md](verification/linear-sync.md) for the current maintainer evidence.
