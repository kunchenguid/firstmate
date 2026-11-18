---
name: change-watch
description: >-
  Agent-only procedure for the post-merge change watch.
  Use on a `check: change-watch <task-id> <pr-url> <metric> regressed` wake, on a
  `check: change-watch <task-id> <pr-url> beta <metric> regressed` wake, on a
  `check: change-watch <task-id> <pr-url> interrupted at +Nm` wake, on a
  `check: change-watch <task-id> <pr-url> unmeasurable (<reason>)` wake, on a
  `check: change-watch <task-id> <pr-url|claim> absent (<reason>)` wake, on a
  `procevent when-cw-... <sequence>` completion wake for an armed change watch,
  or when deciding whether a merged change needs a by-effect watch.
  Owns how a regression is read, routed, and closed, what a clean completion
  still owes, and the one durable row every merge writes.
user-invocable: false
metadata:
  internal: true
---

# change-watch

Load this on a `check: change-watch <task-id> <pr-url> <metric> regressed` wake, on a `check: change-watch <task-id> <pr-url> beta <metric> regressed` wake, on a `check: change-watch <task-id> <pr-url> interrupted at +Nm` wake, on a `check: change-watch <task-id> <pr-url> unmeasurable (<reason>)` wake, on a `check: change-watch <task-id> <pr-url|claim> absent (<reason>)` wake, on a `procevent when-cw-<hash> <sequence>` completion wake, or when deciding whether a merged change needs a by-effect watch.

## What the watch is

A merge is verified at merge time by content - the new env values or image tag are read on the live pods - which proves the change arrived and says nothing about the service afterwards.
`bin/fm-change-watch.sh` watches the change by effect instead: it samples the affected Deployment's own signals against a pre-deploy baseline at +5m, +15m, +30m, then hourly to +12h.
A watch's targets come from what the PR's repository deploys: an H-DevOps PR watches the Deployment documents its diff hunks land in, under each document's own `metadata.namespace` (a Deployment declaring none is skipped with its reason, and when a hunk cannot be placed the whole manifest is watched and the registration line says so), while an application repository watches the Deployments that run its image in a production namespace, ranked by replicas and capped at the busiest few with the cap stated and limited to the services a monorepo's diff actually touches, and a diff that touches no deployable path completes clean rather than unmeasured, saying so when the map keeps no deploy workflow run; plus its Sentry project and its own deploy workflow when the map names them, kept whatever the diff touches.
A Kubernetes target is not scored until its rollout fingerprint (pod images plus pod-template hash) differs from registration or that unchanged rollout is proven built from the merge, so a sample taken between the merge and the rollout says `awaiting the deploy` rather than reading the code it replaced, while a manifest change that rolls pods without touching any image still counts as landed.
A Sentry read waits for that same landing, taking it from whichever kind the watch has: the Deployments' rollout when the watch has any, otherwise its mapped deploy workflow's run for this merge, so a repository deployed by its own workflow is not read before that deploy has landed either.
The per-sample budget bounds the cluster reads and the image-build and containment reads; each build read is also capped at one forge timeout and cut when the sample deadline is spent, recorded as unreadable with the read named rather than consuming the target's other metrics. The Sentry and deploy-workflow reads go over the network under their own bounds and are never costed against a budget the pod reads spent.
A registration that could not read a manifest says `could not read N manifest(s)`: that is a measurement gap to re-register once the forge answers, not a PR without a service; it writes the unmeasurable row and queues the unmeasurable wake even though no watch directory exists. A manifest the PR deleted is named `manifest removed` and needs no watch. A Deployment that declares no namespace is a gap too, never `not-applicable`.
`bin/fm-change-watch.sh`'s header is the one owner of the exact commands, metrics, bars, schedule, target resolution, beta stage, and test seams; read it before acting.

The watch is armed automatically when a merged PR touches a deployable service, from both `bin/fm-pr-merge.sh` and the watcher's merged-poll landing path.
Registration is additive: a registration failure never turns a successful merge into a reported failure, and a PR that touches no deployable service registers nothing.
Never register a watch by hand for a merge the hooks already covered; check `bin/fm-change-watch.sh status` first.

## The beta stage

Registration reads the change against the pre-production copy of the service that serves it before it reads any production target, so a change that breaks something is caught while it is still only in beta rather than after it is live.
The beta map is the built-in `web-credits-next -> muso-dev/credits-gate` plus the home's own `config/change-watch-beta`; a key matches a changed path or the repository name.
Registration runs seconds after the merge, so the beta target is still running the pre-change code: the stage records the target's pre-merge pod fingerprint, captures its baseline from that pre-change state, waits for the merged sha to reach the target, and only then reads.
It scores against that beta baseline rather than an absolute bar, and a metric whose baseline could not be read is left unscored and named in the verdict rather than scored absolutely.
The stage records its verdict in the watch's `beta` record, and `bin/fm-change-watch.sh status` states it beside the production verdict; `bin/fm-change-watch.sh verdict` exits non-zero on a beta regression, so a beta failure is never read as a pass.
A change touching no beta-served path completes the stage clean with the reason stated, and the production watch arms as before.
A beta failure is a beta failure: it is reported on its own `beta` wake and its own steer, records the merge's `regressed` row, and the production watch is never armed for it, so it is never read as a production regression and never upgraded to a production pass.
The ordering is the contract, not an accident of layout: a test asserts it from the `FM_CW_TRACE` read record rather than inferring it from the outcome.

## Handling a beta failure wake

`check: change-watch <task-id> <pr-url> beta <metric> regressed`

1. Read the recorded verdict with `bin/fm-change-watch.sh status <watch-id>`; it names the metric, the beta value, the beta baseline, and the target.
2. The mechanism already steered the owning task with those numbers, and no production watch was armed, so there is no schedule to wait on: this is the only report of the failure.
3. Route it as a live incident lead against the beta environment, and say plainly that the reading is from beta.
   Never restate it as a production regression, and never treat the absent production watch as a pass.
4. The wake is handled when the owning lane has the numbers and the verdict has been read; acknowledge it like any other `check` wake.

## Handling a regression wake

`check: change-watch <task-id> <pr-url> <metric> regressed`

1. Read the verdict with `bin/fm-change-watch.sh verdict <watch-id>`, where the watch id is `<task-id>-<pr-number>`; it names the metric, the measured value, the baseline, and the tick.
2. The mechanism already steered the owning task through `bin/fm-send.sh` with the numbers.
   A regression on the earliest samples usually still finds that task alive; a later one may not, and then the wake is the only route to a lane.
   Route to whichever lane owns the affected service rather than assuming the merged task still exists.
3. Treat it as a live incident lead, not a report: the affected Deployment, the metric, and the timing are the evidence, and the next scheduled sample is already running.
   A captain-facing escalation states the service, the metric and its numbers, the time since the merge, and the next decision.
4. The wake is handled when the lane has the numbers and the watch's verdict has been read; acknowledge it through the ordinary wake acknowledgement like any other `check` wake.

## Handling an interruption wake

`check: change-watch <task-id> <pr-url> interrupted at +Nm`

The drive stopped before the end of its schedule (a stale runner group stopped, a host reboot, an action timeout) and the verdict is `change-watch interrupted at +Nm`, never clean.
1. Read `bin/fm-change-watch.sh verdict <watch-id>` and the samples it did take; a regression it had already recorded is the check wake above, not this one.
2. Run the generic acknowledgement for the `procevent` outcome and `bin/fm-procevent-when.sh retire <name>` as `process-event-sources` requires.
3. Re-register with `bin/fm-change-watch.sh register <task-id> <pr-url>`: on an interrupted watch it retires the stopped source itself, re-arms exactly the remaining samples, prints how many are left, and rewrites the watch's durable row back to `open` so the re-armed watch never leaves a stale terminal row behind.
   A watch with no samples left completes instead, as clean or as unmeasurable-with-reason.

## Handling an unmeasurable wake

`check: change-watch <task-id> <pr-url> unmeasurable (<reason>)`

An unmeasurable watch is a FAILURE, not a quiet completion: the merge landed and nothing proved it was safe.
It is the one change-watch outcome that is captain-facing, because it means a release is running with no evidence behind it.
1. Read `bin/fm-change-watch.sh verdict <watch-id>`; it exits non-zero for this state, which is the done-claim block.
2. Read the row at `state/change-watch/rows/<watch-id>.json` for the readings that did and did not happen, and `bin/fm-change-watch.sh doctor <watch-id>` for why each read failed.
3. Route the gap to the lane that owns the affected service: either the read path is broken (fix it and re-register) or the service genuinely exposes nothing this watch can read (say so, and say what would have to exist).
4. Escalate to the captain with the service, the reason, and what is unverified - this is the case the watch exists to make loud.
5. Acknowledge the wake through the ordinary `check` acknowledgement.

## Handling an absent wake

`check: change-watch <task-id> <pr-url|claim> absent (<reason>)`

Absent is a FAILURE: the change is not on the live surface, so the done claim is false.
For a merge watch the deploy run carrying the merge failed, and the owning task has already been steered with that; for a claim row the task's acceptance probe still did not pass at its last reading.
1. Read the row at `state/change-watch/rows/<watch-id>.json` for the readings and, on a claim row, the acceptance binding.
2. Route it to the owning task, or to a fresh task when that one is gone, to get the change deployed or fixed; a merged PR is not landed while its row reads absent.
3. Teardown refuses the task until evidence clears the row: re-register a merge watch, or claim again for a claim row, then record a passing reading; never delete the row to clear it.
4. Escalate to the captain only when the fix needs a decision, with the service and what is not live.
5. Acknowledge the wake through the ordinary `check` acknowledgement.

## Handling a completion wake

`procevent when-cw-<hash> <sequence>`

The armed watch drives itself through `bin/fm-procevent-when.sh`, so its one terminal outcome is a routine completion, not news.
Load `process-event-sources` for the `classify` and `handled` mechanics; the adapter commands and the acknowledgement contract are owned there.

- `fired` means the drive ran to the end of its schedule.
  Read `bin/fm-change-watch.sh verdict <watch-id>`: `change-watch clean` is the clean +12h completion, `change-watch unmeasurable-with-reason: <reason>` means the schedule ended without the evidence a clean verdict needs and the change is unverified by effect, an `absent ...` line means the deploy run carrying the merge failed so the change never reached production, and a `regressed ...` line means the check wake above is the real signal.
  An unmeasurable watch is a measurement gap to raise with the owning lane, never a pass, and it has already queued its own check wake.
- `action-failed`, `condition-error`, `never-true`, `rejected`, or `ambiguous` means the watch stopped without completing its schedule.
  Report what it actually says and re-register through the interruption path above when the verdict is `interrupted at +Nm`; a `rejected` watch is usually one whose script bytes changed under it, and an `ambiguous` one needs its verdict read before anything else.
- After handling, run the generic acknowledgement, then `bin/fm-procevent-when.sh retire <name>` before any re-register, as `process-event-sources` requires.

## What a clean completion still owes

A clean +12h watch appends one `note: change-watch clean for <pr-url>` line to the task's status log; clean means every target had at least one scored reading across the schedule, and the note itself names every metric no sample ever scored and any rollout that was never proven, so a thin watch reads as thin. The wiki observation is recorded only when that note has no such gap to name - a thin clean ending is stated in the note and elsewhere nothing.
An unmeasurable watch writes NO status note at all: it is a failure, so it queues the `unmeasurable` check wake above and records the row, and the literal `change-watch completed unmeasured` line must never appear in a status log again.
A clean completion is not captain-facing news, so never surface it to the captain on its own; an unmeasurable one is.

## The durable row and the 7-day acceptance

Every merge writes exactly one row at `state/change-watch/rows/<watch-id>.json`, holding a reading for every scheduled offset, the real-user check, a `deploy` field (`expected`, or `not-applicable` when the diff touched nothing deployable), and a terminal state of `proven`, `regressed`, `absent`, or `unmeasurable-with-reason` (plus `open` while the watch runs, and `not-applicable` for a merge that touched no deployable surface at all; a merge whose surface could not be read is `unmeasurable-with-reason`, never `not-applicable`). `absent` means the deploy run carrying the merge failed, so the change never reached production: a failure, never a regression of the running service; a merge whose diff touches nothing deployable keeps no deploy-workflow target and records `"deploy": "not-applicable"` in its row. A done claim registered before any PR exists writes a `claim` row with a null `pr_url` and its acceptance probe binding (`bin/fm-change-watch.sh claim`; the script's "claim rows" section owns it). `bin/fm-change-watch.sh acceptance <watch-id> <offset-seconds>` re-hashes the bound probe, runs it from `/` under `env -i` with a bounded timeout, and records its exit status; a probe whose bytes changed records 125 without running.
`state/change-watch/` is not a task record, so `bin/fm-teardown.sh` never removes it and the row outlives the task; the schema is owned by the `durable row` section of `bin/fm-change-watch.sh`.
`proven` needs all three readings present, every one of them measured, and every target measured at least once; a missing reading is never a pass.
A reading counts as measured when it scored something, or when everything it could not score was only waiting for the rollout to land - a sample taken before the deploy landed has nothing to read yet, so it is recorded as awaiting rather than as a failed read.
A watch whose rollout never landed at all still ends unmeasurable, because no target ever scored.
The real-user check is `observed` when `http_5xx_per_min` - the only metric read from the pods' own access logs - was scored, `not-observed` when it was never scored, and `not-applicable` when the watch has no such target; it is recorded, never a gate on `proven`.

`bin/fm-change-watch.sh gate <task-id>` is the done-claim gate: it exits 0 only when every watch and claim row that task registered is terminal and not a measurement gap, so a task cannot claim done while its merge has no evidence.
`bin/fm-teardown.sh` is the boundary that enforces it: it runs `bin/fm-change-watch.sh gate <task-id> --terminal-gap` on every teardown and REFUSES a task whose watch ended `unmeasurable-with-reason`, `absent`, or `interrupted`, naming the watch, the reason, and the recovery commands (`verdict <watch-id>`, `doctor <watch-id>`, then re-registering once the read path is fixed). Both gate modes decide from the durable row, so deleting a watch's verdict file cannot turn a failing row into a pass, and a row whose merge never created a watch directory is still seen. `not-applicable` is a valid terminal state and passes both modes, so a docs-only merge is never refused. Re-registering a watch that ended unmeasurable or absent reopens its row and re-measures from that point, clearing its samples, previous values and read failures and moving its measurement epoch to the re-registration, so no evidence from before the re-registration can score and the recovery instruction actually clears the refusal; an absent watch always resets its measurement window, so the next sample reads the deploy run that follows the fix rather than the original failed one. A watch still running does NOT block teardown, because `state/change-watch/` is not a task record: it survives the task and keeps sampling on its own.
`bin/fm-change-watch.sh audit [<days>]` is the 7-day acceptance, measured: it fails when any status log under `state/` carries the literal `change-watch completed unmeasured` line, or when any row completed inside the window ended `unmeasurable-with-reason` or `absent`.
The watch is read-only against the cluster; it writes only under the home's `state/change-watch/`, a metric it cannot read is `unmeasured` and skipped rather than scored as a pass, and a relative bar whose baseline was never read is recorded but not scored.
An unmeasured metric is never left silent: `bin/fm-change-watch.sh doctor <watch-id>` proves each target's own read live - the cluster answering under the kubeconfig in use, a Deployment's pods and their images, a pool through the pooler console, a Sentry project, a mapped workflow's run list - and states each one as `doctor: ok`, `doctor: awaiting` for a deploy that has not landed yet, or `doctor: FAIL` with its reason (unreachable cluster, unreadable kubeconfig, refused login, timed-out console, no row for the database); with no watch id it proves the documented pooler path itself answers.
It also replays the reason the last sample recorded for every metric it could not read, so "why was nothing measured" is answered with evidence instead of silence.
