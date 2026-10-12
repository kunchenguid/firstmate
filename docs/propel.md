# Beads propulsion dispatcher

The bounded propulsion dispatcher turns ready Beads work into accountable assignment.
It is a small change controller, not a scheduling framework: firstmate remains the accountable owner of every dispatch, and the dispatcher only computes a plan and surfaces decision points.
The behavioral contract below is the single owner; `bin/fm-propel.sh`'s header cross-references this page instead of restating it.

## State machine

Each run walks the same six stages in order.

1. **DISCOVER.** Reads this home's ready beads from the `.beads` store configured in `config/propel-beads-dir` (the home itself when it holds `.beads`), intersected with the shared board (`FM_BOARD`, default `/Users/jubin/Git/jubin-marut/beads`) `bd --readonly --sandbox list --status open`.
   When this home has no board of its own, the shared board is the discover surface too.
2. **FILTER.** A bead is dropped when `bd ready` did not name it, when the title already sits `in_flight` or `queued` in this home's tasks-axi backlog, when a `state/<task-id>.meta` names matching work already under way in any local home, or when the roster has zero idle panes (a capacity gate, never silently an external wait).
3. **CLASSIFY.** Labels route each surviving bead to `ship`, `scout`, or `captain`.
   `captain` beads are surfaced as decision lines in the plan, never dispatched; `scout` needs a window of measured headroom plus an idle roster pane; everything else is `ship`.
4. **ASSIGN.** Pairs a ship- or scout-class bead with one stable assignee: an idle roster pane first, then a registered secondmate whose `data/secondmates.md` scope covers the bead's domain, then at most one fresh crewmate per run via `bin/fm-spawn.sh`.
   Assignment happens only while bin/fm-quota-choose.sh still shows measured codex/claude headroom; the overflow lane (MAIpro) needs the bead to ask for it or the captain to extend the evidence.
   `config/project-capacity` capacity is `bin/fm-propel-pane-check.sh`'s verdict, delegated to `bin/fm-project-capacity-lib.sh`.
5. **RECURSE.** A readiness blocked on an open bead routes the blocker as the new actionable item; the waiter keeps waiting.
6. **TIME GATES.** `deferred` beads, or `defer_until`-gated ones, are external waits surfaced through the durable wake queue at their gate date instead of active assignment.

## Surface

A dry run is the default and writes `state/.propel-plan.json` (private mode 0600) and a one-line-per-action plan.
`--only-tasks=<id>[,<id>...]` pins the plan to the named board beads.
`--emit-wakes` (the mode the registered custom check uses) additionally prints each fresh captain decision and each fresh time gate surface exactly once, gated by `state/.propel-wake-gates/`, so the watcher emits nothing for an unchanged surface.
Every source read is read-only: `bd` always runs with `--readonly --sandbox`, `tasks-axi` only lists, the roster only observes, and the dispatcher writes only inside this home's own `state/`.
An unknown source anywhere sets the verdict to `unknown` and emits no dispatch at all.

## Registered check

The custom watcher check `state/propel-ready.check.sh` is this dispatcher invoked with `--emit-wakes`; it trips only when the plan carries a fresh captain decision or a fresh time gate.
Registration binds the check to its bytes through `bin/fm-check-register.sh propel-ready`; `docs/configuration.md`'s custom-check section owns the trust model.

## Why bounded

The dispatcher never mass-spawns, never claims a dispatch without an observable pane/worktree/branch attached, and never reinterprets a capacity gate as an external wait.
Autoscaling, fair queueing across projects, and shadow-vs-liveness plurality stays with firstmate supervision; the dispatcher only names what firstmate would notice next.
