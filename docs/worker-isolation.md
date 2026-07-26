# Worker isolation

Audience: maintainer architecture.

This document is the authoritative contract for keeping a launched agent out of the home and the pooled slot it does not own.
The four shared libraries below each own one mechanism; their script headers own the exact functions, arguments, and record shapes, and this document owns how they fit together and why the boundaries sit where they do.
[`docs/verification/worker-isolation.md`](verification/worker-isolation.md) owns the dated empirical evidence.

## What it guarantees

- A task child never resolves, acquires, or acts against the operational home that launched it, and a secondmate resolves only its own home.
- "Where is this agent actually running?" is answered from the agent process itself, never from a session provider's pane field.
- A pooled worktree slot is never released while any other task still references it, including a paused or quarantined one.

## Why it exists

Three defects were observed live, not hypothesized.
Each one defeated a guard that looked sufficient until it was tested against real fleet behavior.

**A worker inherited the primary's home (2026-07-24).**
An audit agent launched from a primary's pane inherited that primary's exported `FM_HOME`.
Every firstmate script it then ran resolved the primary's state directory, and running session start took the primary's own session-owner record.
The real primary was suspended and resumed, came back locked out of its own home, and stopped monitoring.
The lesson is that ownership cannot be inferred downstream from cwd, pane, or process tree; it has to be declared at launch.

**The spawn-time isolation assertion did not survive a restore (2026-07-24).**
After a reboot the session provider restored every pane by resuming its recorded agent session, but resolved each working directory back to the repository the worktree was derived from.
All 17 isolated worktrees collapsed onto their origin, four of them into the firstmate primary checkout.
No writes occurred before they were retired, verified from pre-reboot mtimes.
The lesson is that an assertion made once at launch is not a property that holds afterwards; isolation has to be re-established from live evidence on every resume.

**Recorded `worktree=` is not proof of ownership (2026-07-24, fired 2026-07-25).**
A census found ten pooled slots recorded by more than one task, up to six each.
The hazard then fired: tearing down one task released a lease that a still-live quarantined-paused task also recorded, and the pool reissued that exact slot to a new spawn.
No work was lost, because a task's work lives on its branch and because teardown had been run records-and-panes-only.
The lesson is that disposal has to be gated on live evidence about the slot, and that the records-and-panes-only policy which made the collision harmless should be the deterministic default rather than a manual choice.

A fourth finding corrected the method used to investigate the others.
A pane listing reported a worker's cwd as the primary checkout while `/proc/<pid>/cwd` showed it correctly isolated, because the pane field had picked up a different process sharing the workspace.
A pane read is therefore a hint and never evidence.

## The four mechanisms

### Declared agent identity

`bin/fm-worker-isolation-lib.sh` owns the launch-time declaration.
`bin/fm-spawn.sh` prepends it to every launch command, so the declaration is part of the command the provider runs rather than state the child has to look up.

Two roles exist.
A `crewmate` covers every ship, scout, and audit child; it is never a primary anywhere, so it is launched with every operational-home variable cleared.
A `secondmate` is the primary of its own home and only there, so it keeps a concrete `FM_HOME` while every inheritable override is cleared.
A secondmate's own crewmates are launched by that home's own `bin/fm-spawn.sh` and get the crewmate treatment against the secondmate's home, which is what stops a secondmate's child from ever reaching the primary.

The declaration is a refusal point, not a best effort: an unknown role, an empty id, or a non-absolute home fails rather than emitting a partial prefix, because a partial prefix is exactly the inheritance the mechanism exists to prevent.

Three enforcement points consume the declaration.
`bin/fm-lock.sh` refuses acquisition before it resolves or creates a state directory, so a worker cannot even publish a probe file into a home it inherited, while read-only `status` stays available.
`bin/fm-primary-scope-lib.sh` reports a declared worker as non-primary whatever root and state it was handed, which keeps every tracked project-local startup and turn-end adapter inert for workers.
`bin/fm-spawn.sh` and `bin/fm-teardown.sh` refuse outright, because a worker acting on an inherited home would create or destroy direct reports the real primary never recorded.

### The method of record for an agent's working directory

`bin/fm-agent-cwd-lib.sh` owns the answer and its per-provider limits.
Resolution is most-authoritative-first: the root-most live process carrying the task's declaration marker, then the provider's pane process id descended to the running agent, then `unknown`.
It never falls back to a pane value, so a caller that wants a hint has to ask its provider for one and label it as a hint.

The declaration marker matters here beyond home isolation: it is the provider-independent identity key, and it is the only source that survives a restore which re-parents or relabels panes.

Per-provider process id availability:

| Provider | Per-pane process id | Consequence |
|---|---|---|
| tmux | `#{pane_pid}`, a real shell pid | Authoritative reading available even for an agent with no declaration marker. |
| herdr | none; the pane API exposes `foreground_cwd` only | Authoritative reading requires the declaration marker. |
| zellij | none exposed at all | Same. |
| cmux | none on the control socket | Same. |
| orca | none on the terminal endpoint | Same. |

A provider with no process id is not a failure of the library.
It means a task that also lacks the declaration marker has only a hint, which is reported as `unknown` rather than promoted to evidence.

A tmux target is resolved to its stable window id by exact enumeration before any pane is read.
`display-message` given a window name it cannot find silently answers for the *active client's* window instead, so a task whose window name was lost or auto-renamed would hand back firstmate's own pane, whose working directory is the primary checkout - a healthy worker reported as collapsed.
No exact match reports `unknown`, which is why a caller must never re-derive the pane pid from a name itself.

A caller that asks about many tasks passes one process index built from a single `/proc` walk.
Asking per task instead re-walks every process for every task, and the resume sweep runs on the session-start critical path over a home that has held seventeen concurrent tasks.

Reading another process's environment needs care that is easy to get wrong.
The mode bits on `/proc/<pid>/environ` are not sufficient permission, because the kernel additionally requires ptrace read access; a same-uid but privileged process passes a readability test and still fails at open.
The failing redirect has to be silenced with the group form, since redirections are applied left to right and a trailing `2>/dev/null` on the same command is set up only after the input redirect has already printed to stderr.
Getting this wrong turns unrelated host processes into stderr noise on a read-only sweep.

### Pooled-slot ownership

`bin/fm-slot-owner-lib.sh` owns the release-or-retain verdict.
Disposal is gated on positive evidence of a conflict in three independent forms, any one of which retains the lease: another task recorded in the same home naming the same physical slot, an ownership stamp naming a different task or home, or a live agent declared for a different task running inside the slot.

The stamp is written by `bin/fm-spawn.sh` into the worktree's private git directory, never into the working tree, so it can never dirty a status check or reach a commit.
Writing is refused for anything that is not a linked worktree, so a primary checkout can never be marked as a disposable slot.

Two boundaries are deliberate.
Absence of evidence is not evidence: a slot with no stamp and no conflicting reference disposes normally, which is what keeps every task spawned before stamping existed working unchanged.
`--force` does not waive the gate: it is the captain's authority to discard *this* task's work, never authority to release another task's slot.

Retaining means the lease is retired rather than returned.
`bin/fm-teardown.sh` leaves the directory completely untouched - no branch delete, no hook-file removal, no pool return - and still completes the rest of the teardown, reporting the retained slot on its completion line.
A conflicting secondmate home or Orca worktree refuses outright instead, because silently skipping their removal would strand a registry entry or an Orca-owned worktree.

Retention is not a one-way door.
A task that retains because another task's metadata still names the slot *and then completes its own teardown* gives up its own ownership stamp on the way out, so the holder left behind can release the slot normally once nothing else references it.
That clear is deliberately narrow in two directions.
A stamp naming a *different* task is always preserved, because it is the evidence that stops a stale task from disposing of a slot whose real occupant is merely paused or between processes, and destroying preserved work would be strictly worse than leaking a slot.
A caller that refuses outright preserves the stamp too, because a refused operation mutates nothing: its records all stay, ownership did not change, and stripping the evidence there would set up exactly that same destructive sequence once those records are reconciled away.
Each call site therefore states which of the two it is, so a new caller cannot silently inherit the wrong behaviour.
The live-occupant check stays a blocking condition and is never weakened to compensate.

#### Reclaiming an already-leaked slot

A slot leaked before that rule existed has no record left to release it: no metadata in any home names it, and its stamp names a task that no longer exists.
Reclaim it by hand, in this order, and stop at the first step that fails.

1. Confirm nothing records the slot: `grep -l "worktree=<slot>" <home>/state/*.meta` across every home, including secondmate homes, must find nothing.
2. Confirm nothing lives in it: no process under `/proc` declaring `FM_AGENT_TASK` may have that slot as its `cwd`, and `git -C <slot> status` must show no work worth keeping.
3. Read the stamp at `$(git -C <slot> rev-parse --absolute-git-dir)/fm-slot-owner` and confirm the task it names is gone from every home's state directory.
4. Delete that stamp file, then return the slot from its project with `cd <project> && treehouse return --force <slot>`.

`--force` on `bin/fm-teardown.sh` is deliberately not a shortcut for this.
It is the captain's authority to discard *this* task's work, never authority to release another task's slot, so the gate stays in place and the reclaim stays a deliberate, evidence-checked operator act.

### Restore-time re-assertion

`bin/fm-isolation-sweep.sh` re-establishes at session start what spawn could only assert at launch.
It is read-only, always exits 0, and prints one `ISOLATION:` line per task whose live agent is provably not where its record says it is.
`bin/fm-bootstrap.sh` runs it in the same place as the worktree-tangle check and surfaces those lines in the session-start digest; the `bootstrap-diagnostics` skill owns what the agent does about each shape.

It reports only from an authoritative process reading.
A task with no such reading is silent by default and reported as an unproven `BOOTSTRAP_INFO` fact under `FM_ISOLATION_VERBOSE=1`, because reporting a violation from a pane path is precisely the false positive that corrected the method in the first place.

Which home a record expects is read from the record, never assumed to be the home running the sweep.
A secondmate declares its own home while its record lives in the launching primary's state directory, so comparing every declaration against this home would report every healthy secondmate in the fleet as a foreign worker on every session start.
A sweep that cries wolf on a normal fleet is worse than no sweep, because the `bootstrap-diagnostics` skill tells the agent to treat these lines as proven.

## Extension points

- A new operational-home variable belongs in `FM_WORKER_ISOLATION_HOME_VARS` in `bin/fm-worker-isolation-lib.sh`, not at a call site, or task children will inherit it.
- A new runtime provider that exposes a per-pane process id belongs in `fm_agent_backend_shell_pid` and in the matrix above; one that does not needs no change, because the declaration marker already covers it.
- A new verified harness needs no isolation-specific work, because the declaration is prepended to whatever launch command the adapter builds; the regression suite asserts that for every verified harness so an adapter cannot quietly opt out.

## Regression coverage

`tests/fm-worker-isolation.test.sh` covers all four mechanisms: the declaration's exact bytes and its refusals, the launch declaration for every verified harness, each consuming refusal, the process-cwd method of record against a deliberately lying pane path, the provider matrix, the stable-window-id resolution and its refusal to answer from a lost window name, all three slot-conflict forms plus the clean-disposal case, teardown retiring a contested lease under `--force`, the contested-then-released and still-blocked stamp sequences, and the sweep outcomes including a healthy secondmate staying silent.
Kimi's launch declaration is asserted in `tests/fm-kimi-harness.test.sh`, which owns that adapter's readiness and delivery gates.

## Maintaining this file

Keep this file to stable ownership, mechanism boundaries, and the safety rationale a future maintainer needs before changing one of the four libraries.
Exact functions, arguments, flags, and record shapes belong in each script's own header and `--help`, not here.
Dated commands and captured output belong in [`docs/verification/worker-isolation.md`](verification/worker-isolation.md).
Task chronology and delivery proof belong in private task reports or PR evidence.
