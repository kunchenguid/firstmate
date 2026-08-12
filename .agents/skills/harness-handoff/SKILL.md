---
name: harness-handoff
description: >-
  Agent-only recovery procedure for a Claude or Codex usage-window death, a primary supervisor disappearing mid-flight, or an intentional cross-harness transfer of in-flight Firstmate work.
  Use when a provider window expires or is about to expire, when several lanes lose supervision together, or before moving an active task between Claude and Codex because of capacity.
user-invocable: false
metadata:
  internal: true
---

# harness-handoff

Reconstruct the handoff entirely from durable records.
Never use conversation memory as evidence, because the lost conversation is the failure this procedure exists to survive.

Load [`harness-adapters`](../harness-adapters/SKILL.md) before any spawn, recovery, skill invocation, interrupt, exit, or resume operation.
Use [`stuck-crewmate-recovery`](../stuck-crewmate-recovery/SKILL.md) for an isolated stale or missing ordinary direct report whose failure is not a provider-window event.
Use [`secondmate-provisioning`](../secondmate-provisioning/SKILL.md) instead for a secondmate.

Keep these companion backlog items as separate owners rather than absorbing their contracts here:

- `fm-usage-window-resume` owns the future one-command mechanical recovery.
- `fm-brief-harness-neutral` owns removing old-harness assumptions from generated briefs.
- `fm-brief-compaction-note` owns the worker-side durable instruction note that becomes handoff input.

## Recover the supervisor first

When the expired window belonged to firstmate itself, start a fresh firstmate on the other available harness and treat it as a cold start with no conversation history.

1. Confirm that the complete session-start digest is present, and run `bin/fm-session-start.sh` exactly once only when the harness did not already run it.
2. Stop in read-only mode if the session lock is refused.
3. Treat the wake queue, open decisions, task metadata, status-event tails, backend endpoint inventory, and context digest as the starting fleet record.
4. Reconcile each affected direct report with `bin/fm-crew-state.sh <task-id>` before acting.
5. Resume supervision with the protocol emitted for the new primary harness, never the protocol remembered from the expired one.

A provider-window death does not prove that every lane on that provider died.
It also does not stop workers on the other provider.
The primary may be gone while workers and pipeline processes continue unsupervised, so classify each task independently.

Treat the no-mistakes gate agent as a separate provider axis from the worker harness.
On this installation, `~/.no-mistakes/config.yaml` line 10 sets `agent: claude`, so review, test, document, and later gate agents consume Claude even when the task worker runs on Codex.
That same setting supports `agent: codex` or an ordered fallback list such as `agent: [codex, claude]`.
Read the current config during recovery and record its selected gate agent in the packet; never infer pipeline-provider consumption from the worker harness.
Do not change the global no-mistakes config as part of a handoff, because it affects other live lanes and remains the captain's decision.

- `fine` means its worker endpoint and authoritative pipeline state remain healthy and the task still has supervision.
- `unsupervised` means work remains live or an authoritative pipeline run remains active, but the primary that owned supervision disappeared.
- `dead` means durable endpoint inspection proves the agent is gone, or the authoritative run ended because its selected provider became unavailable.
- `unknown` remains unknown and authorizes inspection only, never relaunch or teardown.

## Build one durable recovery packet per task

Read the task's exact records rather than bulk-scanning unrelated tasks.
Use the active firstmate home explicitly when commands require it.
Write the completed packet to `data/<task-id>/harness-handoff.md` so another cold-start supervisor can recover the same evidence without reconstructing it again.

```sh
task_id=<task-id>
fm_home=<absolute-firstmate-home>
meta="$fm_home/state/$task_id.meta"
worktree=$(sed -n 's/^worktree=//p' "$meta" | head -1)
[ -n "$worktree" ] || { echo "no recorded worktree for $task_id; stop and escalate" >&2; exit 1; }

sed -n '1,240p' "$meta"
sed -n '1,260p' "$fm_home/state/$task_id.status"
FM_HOME="$fm_home" bin/fm-crew-state.sh "$task_id"
```

Derive `$worktree` from the meta and refuse to continue while it is empty.
`git -C ""` silently runs in the current directory instead of failing, so an unset worktree records whatever repository you happen to be standing in as this task's durable evidence.

Take the worktree, project, harness, backend, kind, delivery mode, yolo posture, and endpoint only from `state/<id>.meta`.
Treat `state/<id>.status` as an event log, not current-state truth.
Read `data/<id>/brief.md` for the durable task instruction and any recorded progress note.

Prove the local copy without changing it:

```sh
git -C "$worktree" status --short
git -C "$worktree" rev-parse HEAD
git -C "$worktree" symbolic-ref --quiet --short HEAD
git -C "$worktree" branch --contains HEAD
```

Empty output from `symbolic-ref --quiet --short HEAD` means detached HEAD, not lost work.
Do not read detachment from `rev-parse --abbrev-ref HEAD`, which prints the literal string `HEAD` at a detached head and never prints an empty name.
`git branch --contains HEAD` lists a detached head as the placeholder row `* (no branch)`; record the real branch rows and never that placeholder.
Record every branch that contains the commit and do not move HEAD while reconstructing.
Record every uncommitted file from `git status`; uncommitted work must remain in place.

For a no-mistakes task, inspect the run named by durable records from the recorded worktree:

```sh
(cd "$worktree" && no-mistakes axi)
(cd "$worktree" && no-mistakes axi status --run <run-id>)
```

Bare `no-mistakes axi` reports the active-or-most-recent run for the current branch when one exists, and otherwise displays some other branch's run purely as informational output.
Before recording custody, confirm that the displayed run's branch and head match this worktree's branch and HEAD.
When they do not match, attribute by branch from the repository-wide listing instead:

```sh
(cd "$worktree" && no-mistakes runs)
```

A run you cannot positively attribute to this worktree's branch and head is not this task's run.
Record `unknown` for pipeline custody rather than supervising, resuming, or acting on another task's run.

Record the run id, outcome, submitted head, current pipeline head, pushed head, and the complete `branch_sync.next_action` object.
An active run positively attributed to this worktree's branch remains authoritative even when the worker endpoint is dead.
Do not create a duplicate run or act on custody until structured status tells you the next action.

When status names a preserved or current pipeline head, prove that it is a real commit object in the gate repository before trusting recovery:

```sh
gate_repo=$(git -C "$worktree" remote get-url no-mistakes)
preserved_head=<full-object-id>
git --git-dir="$gate_repo" cat-file -e "$preserved_head^{commit}"
git --git-dir="$gate_repo" cat-file -t "$preserved_head"
```

Derive the gate repository from the worktree's `no-mistakes` remote rather than guessing a directory hash, because a machine holds one gate repository per registered project and the wrong one fails every object check.
When `remote get-url no-mistakes` itself fails, the worktree is not gate-registered; that is a registration gap, and `cat-file` proves nothing until you hold the correct repository.
Resolve the repository before classifying anything, because a failed check in the wrong repository looks exactly like a missing object.

A recorded head whose `cat-file -e` check fails in the correctly derived gate repository is the known phantom-custody class tracked by `fm-nomistakes-phantom-custody`.
Do not run custody recovery, invent the object, or treat the record as preserved work.
Leave the branch, worktree, run, and gate records intact and escalate the blocked recovery with the exact missing object id.

Complete the packet with only durable facts:

- Task identity, project, worktree, recorded endpoint, old harness, backend, kind, mode, and yolo posture.
- Current branch or detached commit, full HEAD, containing branches, and the exact dirty-file summary.
- Pipeline run id and outcome, all recorded heads, `branch_sync.next_action`, and the successful or failed `cat-file` proof.
- The no-mistakes gate agent selected by `~/.no-mistakes/config.yaml`, kept separate from the worker harness.
- PR number and state when one exists.
- Still-open decisions and already-recorded resolutions from the status log and brief.
- One exact next action that follows the current structured state.

If a fact is absent from those records, write `unknown` in the packet.
Never fill the gap from the expired conversation.

## Choose the least invasive recovery

1. Keep supervising an active authoritative pipeline run instead of spawning another worker or run.
2. Keep a healthy worker running when only supervision lapsed.
3. For a live, positively attributed endpoint that needs a harness change, use `bin/fm-control.sh <task-id> relaunch --harness <target> --note-file <packet>`.
4. For a positively agent-free endpoint that is still present and sitting in the recorded worktree, add the packet to the task brief, then use `bin/fm-spawn.sh <task-id> --relaunch --harness <target>` only when the control-plane transaction has already stopped the old agent or the operator is deliberately relaunching an already-stopped task.
5. Use the fresh-spawn fallback below only when the recorded endpoint is gone or the preserved endpoint cannot launch from the recorded worktree.

`bin/fm-control.sh relaunch` deliberately refuses when the recorded endpoint is gone because there is no agent it can stop.
Its launch half also refuses when the endpoint shell is not sitting in the recorded worktree.
These refusals both occurred in the 2026-08-11 incident and are safety boundaries, not instructions to force the control plane.

After either refusal, first prove that no live agent owns the task and that the recorded worktree still exists with the same physical path, HEAD, containing branches, and dirty state captured in the packet.
Append the packet to `data/<task-id>/brief.md` under a clearly labeled harness-handoff heading so the replacement is guaranteed to read it.
Then use a normal `bin/fm-spawn.sh <task-id> <project>` invocation with the existing task id, recorded task kind and delivery posture, and explicit target harness.
For a ship task, pass the recorded `--mode` and `--yolo`; for a scout, pass `--scout`.
Read current `bin/fm-spawn.sh --help` before composing the invocation because that executable owns the exact flags.

The normal spawn path creates a replacement endpoint and, in the incident this skill codifies, reused the existing task worktree for the same task id.
Immediately verify that the newly recorded physical worktree equals the packet's worktree and that exactly one live agent owns the task before sending any follow-up.
If the path differs, the endpoint is ambiguous, or another agent may still be live, stop and preserve both copies without teardown.

Never use `--force`, discard a dirty worktree, delete an endpoint to make a check pass, tear down unlanded work, or bypass a lifecycle refusal.

## Translate the handoff across harnesses

[`harness-adapters`](../harness-adapters/SKILL.md) remains the owner of current adapter behavior.
Apply these handoff-critical differences explicitly:

| Concern | Claude | Codex |
|---|---|---|
| Skill invocation | `/<skill>`, such as `/no-mistakes` | `$<skill>`, such as `$no-mistakes` |
| Busy-state trust | Verified semantic lifecycle hooks | Unverified, so peek the endpoint and inspect the authoritative run instead of trusting a busy verdict |
| Primary supervision | Use the Claude protocol emitted at session start | Use the Codex protocol emitted at session start |

Inspect the brief and packet for an instruction that assumed the old harness, including skill syntax, lifecycle keys, hook paths, or a harness-private session command.
Translate only that instruction into the target harness's current form.
Do not rewrite task intent, prior decisions, or delivery posture during the transfer.
Do not carry a provider-specific model name to the other harness; resolve the target harness, model, and effort through the normal dispatch rules.

## Finish the handoff

The handoff is complete only when all of these are true:

1. Every affected task is classified from current durable evidence.
2. Every local branch, commit, uncommitted change, pipeline head, open decision, and PR is accounted for.
3. Every preserved pipeline head used for recovery passed `cat-file -e` in the correct gate repository.
4. Exactly one worker owns each resumed task, and its recorded worktree matches the recovery packet.
5. The replacement worker received the durable packet, and the fresh primary resumed the supervision protocol for its own harness.

Leave blocked and ambiguous tasks intact with their exact evidence.
Recovery preserves work; it never destroys evidence to make the fleet look healthy.
