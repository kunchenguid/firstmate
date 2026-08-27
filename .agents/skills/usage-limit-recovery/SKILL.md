---
name: usage-limit-recovery
description: >-
  Agent-only procedure for a provider usage limit: the wall that looks exactly like a fleet-wide crash.
  Use whenever a worker's endpoint is dead or stale and a usage wall has not been ruled out, whenever several workers on one provider stop within minutes of each other, on any USAGE_WALL line in the session-start digest or a diagnose run, and before dispatching when the headroom surface reads tight, wall, partial, or unknown.
  Owns the diagnose-from-the-step-log rule, the settle-custody-first rule, the endpoint-gone relaunch refusal and its safe workaround, and the resume record.
user-invocable: false
metadata:
  internal: true
---

# usage-limit-recovery

A provider usage limit is not a crash, and every expensive minute of this incident comes from that one confusion.

When an account hits its limit, every worker on that account dies inside the same minute.
The harness exits non-zero, the validation run goes terminal with findings still awaiting, nothing is pushed, and no PR appears.
The evidence reads like a fleet-wide failure and is not one: the work is intact on every branch, and the pipeline is holding fix commits the local copies never saw.

Load this before concluding anything about a dead or stale worker whose stranding has not been positively explained.

## Before the wall

`bin/fm-usage-wall.sh headroom` is the gauge, and the session-start digest and `bin/fm-fleet-view.sh` print it where dispatch decisions are made.

Read `unknown` as UNMEASURED, never as fine.
A provider reporting `auth-required` has never been read at all; approving local credential access once with `quota-axi --allow-keychain-prompt` is an operator action at a terminal, and no Firstmate command will ever run it for them, because it blocks on a dialog.

A summary verdict of `wall` is not a low reading: that provider has already stopped, and every worker on it is down.
Treat it as the incident, not as a warning about one.

`partial` is the mixed reading: some providers measured, others never read at all.
It is the normal summary on a host where most providers are unmeasurable, so read it as a live reading beside unproven ones rather than as either a clean bill or a total blackout.

When the reading is tight, wall, partial, or unknown, run `bin/fm-usage-wall.sh resume`.
It regenerates the resume record from live durable state into `state/resume-record.md`: every task's merge posture, local copy, branch, head, uncommitted and unpushed counts, pipeline run and branch custody, PR, open captain calls, and delivered instructions.
Regenerate it rather than editing it, and regenerate it again after the wall - it is generated from state that does not die with the agents, so it is never stale and never needs to have been written in advance.
Tell the captain the headroom and the consequence in plain outcome language, not the gauge output.

## Diagnosing the wall

Run `bin/fm-usage-wall.sh diagnose <task-id>`.
It reads the endpoint's own output and then the failed pipeline steps' logs, and answers `wall`, `no-signature`, or `unknown`.
`no-signature` means nothing matched in what was readable, and `unknown` means the evidence could not be read; neither is proof that the work crashed, so do not record a failure on either.
Read the verdict's own disclosure before trusting a negative: `checked=` names what was actually read, `unread=` names logs that resisted a read, and `unscanned=` names logs the scan's budget never reached.
A verdict carrying either list is a partial scan, so read those logs yourself before concluding anything.

**Diagnose from the step log, not the run status.**
A run that died on the wall reports `status: failed`, which reads like a verdict on the code and is not one.
The vendor's limit line is in the step's own log, and one `no-mistakes axi logs --run <id> --step <step> --full` separates a usage wall from a real failure in a single command.
On 2026-08-23 the review and test step logs both ended on `You've hit your weekly limit - resets Aug 26 at 10am (Europe/Rome)` followed by `claude exited: exit status 1`, while the run status said only `failed`.

Several workers on one provider going terminal within minutes of each other is itself the signature; diagnose one of them before treating any of them as broken.

## Settle pipeline custody before anything else

**The pipeline holds fix commits the local copy does not have.**
A stranded run leaves `branch_sync.state` at `pipeline_owned` with the run head ahead of, or entirely absent from, the local copy, because the pipeline commits its fixes in its own gate copy.
A worker that starts work from the local head there silently rebuilds work that already exists, and the resume record names this case explicitly on the task's pipeline line.

So the relaunched worker's first action is to settle custody, before reading code and before any commit.
It follows `branch_sync.next_action` from structured `axi status` exactly as `AGENTS.md` section 7 requires, and never improvises a reset, stash, merge, rebase, force, or branch replacement around it.
Custody is the worker's to settle, not firstmate's: firstmate never runs `no-mistakes axi sync`, `respond`, or any other state-changing pipeline command for a crew-owned run.

## When the recorded endpoint is gone

A usage wall often takes the terminal session with it, and that turns into the most expensive part of the whole incident.

`bin/fm-control.sh <id> exit` and `relaunch` both require a positively classified endpoint.
A recorded endpoint whose window is absent - or whose whole terminal server is gone - classifies as `missing`, and both verbs refuse with `recorded endpoint is gone, so there is no agent to stop`.
`bin/fm-teardown.sh` refuses too, correctly, because the work is unlanded.
That pair is a genuine deadlock, and it is [firstmate issue #3113](https://github.com/kunchenguid/firstmate/issues/3113).

The way through is to recreate the exact endpoint the task already records, and then use the ordinary control plane:

1. Read `window=` and `worktree=` from `state/<id>.meta`.
2. Recreate that exact session and window name, with the recorded local copy as its working directory, leaving a plain shell in it.
3. Confirm the endpoint now classifies as `dead` rather than `missing`.
4. Relaunch through `bin/fm-control.sh <id> relaunch --note '<what was done so far>'`, which reuses the existing local copy and every commit in it.

Never allocate a fresh worktree instead.
The recorded copy holds the work, and a second copy splits one task across two.

**This is safe only because a dead terminal server positively proves no agent still owns the task.**
That proof is the whole justification, and it does not transfer.
Never manufacture, rebind, or recreate an endpoint while a live agent might still hold it: `missing` means the endpoint could not be found, `unreadable` and `ambiguous` mean the backend could not classify it, and only the first of those excludes a live agent.
On an `unreadable` or `ambiguous` read, or any doubt about whether the original process survived, stop and reconcile ownership first - a duplicate agent on one local copy is the outcome this rule exists to prevent.

For a remote secondmate, none of the above applies: load `secondmate-provisioning` and reconcile it through its own home.

## Bringing the fleet back

Work one task at a time, from the resume record.

For each task, diagnose, settle custody, relaunch with a note that says what was already done, and let the worker resume its own pipeline.
Keep each task's recorded merge posture: a wall changes nothing about who approves the merge.
An open captain call recorded against a task is still open after the wall, and is closed only by the captain's answer under `captain-hold-lifecycle`.

Report to the captain in outcomes: which work was untouched, which is back under way, and what still needs a decision.
Do not relay the gauge, the verdict lines, or the record verbatim.
