# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh`        | Detect required toolchain problems, optional capability facts, and primary-checkout `TANGLE:` problems; locally sync live secondmate homes; refresh clones best-effort; install tools only after consent |
| `fm-boot-context.sh`     | Strictly read-only `SessionStart` boot-context emitter: fleet identity for every session, steering detail only for the session that holds the lock, under a hard wall-clock budget |
| `fm-fleet-sync.sh`       | Fetch clones, clean-fast-forward their checked-out default branches, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin     |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                 |
| `fm-brief.sh`            | Scaffold a ship brief with a worktree-isolation assertion, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate` |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when a stale or missing watcher needs a prominent banner |
| `fm-home-seed.sh`        | Lease/provision a secondmate home transactionally, clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-intake.sh`           | The Wardroom gate between a filled ship brief and its spawn: foreign deep lens, then two thinker lenses under a severity bar where only a blocking defect holds the spawn and everything else rides along as a note; records `proceed:`/`revise:`/`escalate:` in `state/<id>.intake` and warns when its own proceed rate is structurally zero |
| `fm-intake-lib.sh`       | Shared intake channel grammar, strict PANEL verdict parsing, template-echo detection, and the `fm_intake_require_proceed` gate that `fm-spawn.sh` consumes |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs, or a persistent secondmate with `--secondmate`, as a `<project>-<work>` herdr tab in that project's workspace (`--name <work>` chooses the work half); stops and escalates when no herdr server is reachable; ship/scout spawns require an isolated treehouse worktree; secondmate spawns locally sync the home before launch |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch.sh`            | Singleton-safe one-shot watcher; blocks until supervision work is due, queues it durably, then exits with one reason line |
| `fm-supervise-daemon.sh` | Presence-gated sub-supervisor for walk-away (`/afk`) supervision: wraps `fm-watch.sh`, self-handles routine wakes in bash, and escalates only captain-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for `/updatefirstmate` origin pulls and no-fetch local secondmate syncs         |
| `fm-tasks-axi-lib.sh`    | Shared `tasks-axi` compatibility probe sourced by bootstrap and teardown                                            |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work                                              |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the watcher, drain, arm, guard, and daemon          |
| `fm-send.sh`             | Send one line (or `--key Escape`) to a crewmate pane through acknowledged `herdr agent prompt --wait` delivery; refuses a pane at an approval dialog or with no agent, and reports an unacknowledged steer as unconfirmed rather than re-sending it. The no-agent refusal is deliberate - a shell pane would RUN the steer - so relaunch an exited agent with `herdr pane run <pane-id> '<launch command>'` instead (see the `stuck-crewmate-recovery` skill). Pre-cutover panes keep the verified type-then-retry submit, which exits non-zero when Enter is positively swallowed and pauses `FM_SEND_SETTLE` seconds after success |
| `fm-herdr.sh`            | The herdr surface: library plus workspace-reconcile CLI. Workspace resolution, `<project>-<work>` pane naming, tab/pane verbs, acknowledged `agent prompt --wait` delivery, and the escalation when no herdr server is reachable. Not named `herdr`, which would shadow the real binary |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry. RETIRED for new use: nothing spawns onto tmux. Still sourced by the away-mode daemon and context-watch, and by `fm-send.sh` for panes that predate the herdr cutover; delete it only once no meta lacks `mux=herdr` |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane, read through herdr, or over tmux for a pane predating the cutover; a failed read says so instead of looking like a quiet crewmate |
| `fm-status.sh`           | Append one crewmate status line to a home's status file; briefs teach this verb because a shell redirect into the firstmate tree is refused as an edit |
| `fm-pr-check.sh`         | Record a PR-ready task and arm the watcher's merge poll                                                             |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Return the worktree or retire/release a secondmate home and close its pane on the surface that created it, warning rather than staying silent when a pane could not be closed and keeping the task record at `state/<id>.orphan-pane` so that leftover pane stays findable (and clearing that record once a run does close the pane); protects ship work, requires scout reports, checks child work, and prints the backlog reminder |
| `fm-harness.sh`          | Detect the running harness; resolve the effective crewmate harness                                                  |
| `fm-lock.sh`             | Per-home firstmate session lock                                                                                     |
