# Azure fleet requirements

This document owns what running Firstmate on Azure is required to do, and how far the build has
got toward each requirement.
The five component documents (`docs/azure-pilot.md`, `docs/azure-runner.md`,
`docs/azure-validation.md`, `docs/azure-crosscheck.md`, `docs/azure-workers.md`) own the
mechanics of what is built.
Where a component document contradicts a requirement here, the requirement is authoritative and
that document is corrected as the requirement lands.

## Rule of construction

The owner stated these requirements and knows what the fleet must do.
A built design that contradicts one of them is a misinterpretation to be corrected, not a
constraint to report back.
Two such contradictions were found on 2026-08-18 and both are recorded below as design defects,
in R2/R3 and in R6.

Every state line in this document is a claim about the build that must be re-checked before it is
relied on, and a status is only moved to DONE with the acceptance criterion actually met.

## The requirements

Stated by the owner on 2026-08-18:

> "firstmate can spawn secondmates and crewmates in azure (and those secondmates can spawn
> crewmates in azure), and no-mistakes runs on azure, and all of this on pi-codex multi-profile,
> and cross-check works (with codex reviewing claude work and claude reviewing codex work), and
> everything is logged in, auth refreshes on its own, everything is set up and proven"

Added the same day:

- Crosscheck wall time must drop from about 75 minutes to 20 to 30 minutes.
- "The only requirement is that we can run many crewmates and no-mistakes/cross-checks in
  parallel without resource contention."
- A cost guard, so that a day's spend cannot quietly reach 100 dollars.
- "For cross-check, just use the same pi fleet (or copy it in, whatever works)."

The following dated Crosscheck amendments are historical; [Crosscheck's reviewer contract](crosscheck.md#reviewer-harness) owns the current policy and supersedes their author-family requirements.

Amended by the owner on 2026-08-19: the crosscheck requirement was that no author's work was
reviewed only by its own model family, not the literal codex/claude pairing quoted above.
The second reviewer family is GLM-5.2 on Azure AI Foundry.
pi-anthropic was rejected the same day (API pricing), as was an interim same-day
Claude-Code-CLI-subscription direction, and an interim Kimi-K2.7-Code pick was revised to
GLM-5.2 the same day on model quality. Details and work in R6.

Amended again by the owner later on 2026-08-19: crosscheck routes through GLM only. A single
reviewer family outside both author families satisfies the paradigm for every author, unbinds
review capacity from the pi-codex subscription profiles the fleet's own work depends on, and
makes the lane scalable for firstmate and for engineers' on-demand use. pi-codex stays as an
explicit fallback whose activation must be easy to see. no-mistakes stays on pi-codex.
The owner also directed a Slack v1 team exposure of crosscheck, recorded as R10.

## R1. Crewmates run in Azure

Status: DONE.

`config/spawn-cloud=azure` is set and accepted by `bin/fm-spawn.sh`'s own parser, and a crewmate
has been created, staged, and executed in Azure with exit 0.
Crewmates now return outcomes, which the earlier revision of this line recorded as outstanding.
On 2026-08-22 the compartment child `azaccept-cf242c626` (task generation
`spawn:a73823d99b3cab33`, assignment `asg-00000019`) returned exit 0, `timed_out false`, result
digest `1f238e42...`, and an outcome bundle of one commit
(`60-frozen-child-worker-result.json`); the two ordinary crewmates
`r5-accept-readme-v3-20260822` (`asg-00000020`) and `r5-accept-package-v3-20260822`
(`asg-00000021`) each returned exit 0, `timed_out false`, and `outcome_commits 0` for their
read-only briefs. Evidence and paths are in R2/R3 and R5.
Provider-profile placement is R5, where live Pi execution and deterministic reusable assignment-private snapshots are recorded separately.

## R2/R3. Secondmates run in Azure, and can spawn crewmates in Azure

Status: DONE, met live on 2026-08-22.

Acceptance: a secondmate running on an Azure worker requests a crewmate worker, the controller
creates it, the crewmate completes a task, and both release cleanly.

The compact tracked record is [`docs/evidence/azure-live-acceptance-2026-08-22/evidence.json`](evidence/azure-live-acceptance-2026-08-22/evidence.json), derived from frozen manifest revision 12 at the SHA-256 recorded in `frozen_manifest.sha256`.
Its [README](evidence/azure-live-acceptance-2026-08-22/README.md) maps claims to field paths and gives reproducible frozen-digest and authenticated live-ref checks.

- Parent compartment: task `azaccept`, task generation `spawn:a632e0aaaa34a6ff`, assignment `asg-00000018` on slot 1 with its exact account-binding digest (`simultaneous_assignments[0]`).
- It emitted child request `7970c2936d499c8525bbb1a91adddba7a3452afd3182be257c225995fea25c29` (sequence 2, `child_kind` `ship`, `child_request`) into the controller's durable outbox, and the controller created the child worker.
- Child: task `azaccept-cf242c626`, task generation `spawn:a73823d99b3cab33`, assignment `asg-00000019` on slot 2 with its exact account-binding digest (`simultaneous_assignments[1]`).
- The child completed its documentation brief: exit 0, `timed_out false`, result digest `1f238e423056b6193f80e826638a1aa19158dac4997c10af457defc9842ddff3`, outcome bundle `7e812cd519426a7e5990244c28eda033bf98be510f18e013b51a12270f39edb3` carrying one commit (`executions[0]`).
- That commit is live on origin: `refs/heads/fm-child/azaccept-cf242c626-20260822` at `818e018d8dbb7b8d5bccae2b1d93192364533d1b`, with the frozen heads digest and authenticated exact-ref-line digest in `origin`.
- The compartment then ended terminal: monitor status `closed`, `legs_completed: 1`, verified chain tip at sequence 7 (`parent_monitor`).
- Both released cleanly (`release_proofs[0]` and `release_proofs[1]`).
  Each `fm.worker-release/v2` record contains the complete `account`, `endpoint`, `landing`, `report`, and `worktree` authority map, with every verdict `proved` and every evidence and receipt digest retained.
- Aftercare proves the 60 enumerated acceptance resources absent, zero provider workers, zero active specialized reservations, zero regional worker vCPUs, zero VMs, and no assigned controller queue entry (`post_reset`).
  The final verifier string is retained exactly at `post_reset.final_verifier`.

History, kept because the defect and its correction are what this section was written for.
`docs/azure-workers.md` stated that a worker never runs Firstmate, a secondmate, another
supervisor, or a nested team, and `bin/fm-spawn.sh` stated that secondmate and account-recovery
spawns always stay local, so the build refused this requirement outright.

The fear behind that rule was sound: a worker must not be able to create unbounded child compute.
It was written as a blanket refusal of the requested architecture rather than as a bound on child
compute, and that was the defect.

The correction is a secondmate compartment class distinct from the crewmate worker.
It runs a secondmate in Azure, and its child spawns go through the local controller's durable
queue: the secondmate enqueues a worker request and the controller reconciles and creates it.
No child-worker launcher exists on the worker, and the requested hierarchy works, with
firstmate spawning secondmates in Azure and those secondmates obtaining crewmates in Azure.

The work this took: a new compartment role and lifecycle class; endpoint and steering
reachability for a compartment that outlives one task; a guest-to-controller request path; cost
and capacity accounting for that longer life; and a rewrite of the two statements above.

## R4. no-mistakes runs on Azure

Status: DONE, met live on 2026-08-23.
The validation-cell lane completed its amended acceptance in cell `azv-c1bb1c5ff906` on exact
head `bb96be9ebfd7562773fd8c8d9e5cb10af5e232a9`.
The protected Claude-provider run completed all four behavior shards and its lint shard with exit
0, produced `checks-passed` for pull request 319 with 13 of 13 checks green, collected the exact
submitted/current/remote head, and reached `close` with the worktree disk, cell storage scope,
and exact cell resources absent.
The compact tracked proof is
[`docs/evidence/azure-r4-live-acceptance-2026-08-23/evidence.json`](evidence/azure-r4-live-acceptance-2026-08-23/evidence.json),
with its claim map and verification commands in the adjacent
[README](evidence/azure-r4-live-acceptance-2026-08-23/README.md).
The runner-offload lane is code-complete too, and it is an optimisation rather than a second
required leg, so its own live run is not owed against this requirement.

Two lanes exist.
Before the accepted 2026-08-23 run, the validation-cell lane (`docs/azure-validation.md`) had
never closed a cell.
Its state is not absent: `$FM_HOME/state/azure-validation/azv-36b2726cbcf3.json` holds the
complete record of the first live attempt, including its transition timestamps, and is the
ground truth correcting the account below. An earlier revision of this line claimed no
`azure-validation` state existed; that was never re-checked against the directory.
A stranding strand was fixed: a passed run carrying a short receipt set is now demoted to failed
so the cell collects and retains legibly.
The root cause behind "an in-cell bridge producing no receipts" is now found and fixed: the
bridge emits receipts in the one attempt whose test step executes, no-mistakes does not
re-execute an already-green test step when a resumed attempt (reattach or respond) continues the
same run, and the guest wiped the shard exchange's receipts at the start of EVERY attempt - so
every multi-attempt run assembled its final result with zero receipts, demoted, and could never
`close`. The wipe is now scoped to run boundaries (start mode only); the controller's collect
gate stays the binding authority (receipt head must be the published head or a verified ancestor
with its tree bound), proven hermetically through the real bridge, guest emission, collect
identity gate, and close gate in `tests/fm-azure-validation.test.sh`.
The one stranded work disk that sat on the subscription was deleted by the owner's direction on
2026-08-19 after no cell record could be found anywhere for the sanctioned close, so the lane
has no live residue.
The runner-offload lane (`FM_AZURE_RUNNER_REMOTE_CLASSES`) now has its caller:
`bin/fm-azure-runner-dispatch.sh` derives `FM_AZURE_RUNNER_TASK` and
`FM_AZURE_RUNNER_GENERATION` from the ambient no-mistakes run (the task-worktree
`$FM_HOME/state/<task>.meta` authority, or the gate worktree's own run id and snapshot HEAD)
and passes `FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION` through from the operator environment's
`FM_AZURE_SUBSCRIPTION_ID`, never inventing it. Any underivable binding fails closed with an
exact error naming what is missing and the command runs nowhere; the `docs/azure-runner.md`
exports remain an operator override, and `FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES` remains the
only explicit local opt-out.

No R4 acceptance work remains.
Before the accepted run, the remaining work was one operator-driven live run in which a
validation cell moved from dispatch through `close` and released its worktree disk.
The other live run this section used to owe, a no-mistakes run offloading a selected test class to
Azure end to end, is worth taking on the optimisation lane's own merits and no longer gates this
requirement.

First live cell attempt, 2026-08-20 (`azv-36b2726cbcf3`, task `r4-cell-acceptance`, head
`c094cc38`, `validation-standard`): submit, dispatch, boot, review, and the full four-shard
behavior round all executed, and the run reached its test gate carrying a complete shard round
rather than the empty receipt set that used to strand every multi-attempt cell. The gate was a
genuinely red test step (host-coupled units that cannot pass inside a Linux cell: passwordless
sudo, tmux window creation, Keychain approval markers), the operator answered `approve`, and
attempt 2 then ended without an authenticated result marker. The cell took the retain lane:
compute zero, worktree disk and evidence retained, control reservation released.

At the time, that attempt exposed two blockers between the lane and its acceptance sentence, and
neither was the receipts strand:

1. `observe` took a terminal decision on a control view it never bound to the attempt, and the
   decision was unrecoverable. This was recorded here as "`respond` does not answer a gate" plus
   "the guest re-publishes the byte-identical previous result". The second is wrong under every
   reading of the evidence. The first is NOT ESTABLISHED rather than confirmed: it was inferred
   from a control-plane read that cannot support it. Ground truth is the cell's own state file
   (`$FM_HOME/state/azure-validation/azv-36b2726cbcf3.json`), whose events read `responding` at
   09:47:51, `failed-retained` at 09:48:00, and compute removed at 09:50:30. The host declared the
   attempt dead NINE SECONDS after creating its Run Command and deleted the VM 2m39s in; attempt 1
   had taken 1h57m. `observe` treated a terminal `executionState` whose output carried no result
   marker as proof the attempt had died, and nothing bound the view it read to the attempt it had
   just created. The marker is the guest's LAST action, so its absence proves nothing about an
   attempt still working, and `failed-retained` is a phase `observe` itself refuses, so one
   premature read was terminal.
   The byte-identical result was never a republish, and that does not depend on which hypothesis
   below is true. The result blob has one fixed name per cell (`staging.result_blob` is
   `control/result.tar.gz`), overwritten by each attempt's upload, and attempt 2 never reached its
   upload, so any later download necessarily returned attempt 1's archive unchanged. That is the
   whole of the reported evidence: the same sha256 prefix `330ddea31bfbbb05`, the same 3056-byte
   `run.log`, the same `run_id`, the same `needs-decision`, the same gate. `collect` never ran at
   all, the state file carries no `result` and `state/azure-validation/results/` is empty, so the
   comparison was made by downloading the one blob directly, twice.
   TWO HYPOTHESES REMAIN OPEN for what produced that view, and the evidence to date does not
   separate them. Neither is settled:
   (a) the view was stale, describing something other than the nine-second-old attempt; or
   (b) attempt 2's guest genuinely failed fast, after its auth-home write-back and before its
   marker. `control_error` carries exactly two lines, the auth-home pull and push warnings, and
   those are emitted from the guest's own SEQUENTIAL path rather than from a trap: the sealed
   guest staged at `payloads/azv-36b2726cbcf3/guest.sh` calls `auth_home_pull` at line 504 and
   `auth_home_push` at line 895, its only trap is `cleanup_mounts EXIT`, and its marker is at line
   1102. A guest that got past 895 and died before 1102 produces exactly that stderr.
   On resource identity (b) is the better-supported reading: `resources.run_commands` records two
   distinct Azure resources, `start-a1` and `respond-a2`, and `respond` rebinds `run_command_id`
   to `respond-a2` inside `create_run_command` BEFORE the `responding` transition at 09:47:51, so
   the 09:48:00 read addressed a resource nine seconds old, which cannot inherit `start-a1`'s
   stderr. An earlier revision of this section asserted (a) as fact and ruled (b) out. That was
   wrong, and ruling (b) out risks sending the next operator away from a real respond-path bug.
   Separating the two needs a live cell.
   What IS established holds under both, and is what the fix rests on: the operator's response was
   delivered to the cell as a protected run-command parameter, and `observe` then ended the
   attempt on a view it had never bound to it.
   The latent defect this exposed is worse than the reported one. Had that view carried attempt
   1's MARKER rather than no marker, `observe` would have accepted it, `collect` would have
   downloaded attempt 1's archive, matched its digest, and PASSED `verify_result_identity`,
   because on a resumed attempt the VM, boot id, run id, heads and every other verified field are
   identical and `result.json` carried no attempt number. A silent false verdict is categorically
   worse than a generic failure.
   Fixed: the guest stamps `attempt` into `result.json` and appends `attempt=<n>` to its marker;
   `observe` accepts any marker naming the attempt it is observing, refuses a stamped marker that
   names another attempt, refuses two conflicting results claiming one attempt, and never accepts
   an unbound view, deferring the terminal decision behind a settling window
   (`FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS`, default 300 seconds, re-armed for every attempt
   in `create_run_command`) so silence means "could not tell" and never authorizes the destructive
   action, including when the recorded stamp is itself unreadable; `observe` refuses a result
   byte-identical to an earlier attempt's as an explicit non-answer rather than a generic failure;
   and `verify_result_identity` refuses a result that declares no attempt or another attempt's.
   A cell whose SEALED guest predates the stamp is not stranded by any of that: its unstamped
   marker is still read, and its result is held to the pre-stamp contract. Nor does a guest edit
   brick a cell in flight: `create_run_command` now runs the guest the request was SEALED with,
   taken from the copy `submit` stages beside the request and accepted only when its digest is the
   sealed digest, so `respond`, `reattach` and `replace` keep working across any edit to the
   working tree while the seal itself still binds exactly what may execute.
   Residual, not fixed: `observe` still drives into `failed-retained`, a phase it refuses, so a
   false negative that outlasts the settling window is recoverable only through `replace`.
   Upgrading no-mistakes on the HOST is NOT the fix and cannot reach a running cell. The cell's
   version comes from the `runtime.tar.gz` handed to `submit --runtime-bundle`; nothing in this
   repo BUILDS that bundle, it is extracted only on a `start` boot, and the request is
   digest-sealed. The staged payload copy for `azv-36b2726cbcf3` declares
   `no_mistakes_version: 1.48.0` across 110 files, read from that bundle rather than from the
   state file, which records only its digest. Host 1.48.0 to 1.53.0 changes what runs in a cell
   only by rebuilding the bundle from the upgraded binary and submitting a NEW cell. Do not spend
   time waiting on a host upgrade here.

2. The sealed suite was not Linux-clean, so every cell run parked. Shard 2 failed on host-coupled
   units that cannot pass inside a Linux cell (passwordless sudo, tmux window creation, Keychain
   approval markers), alongside 377 passing units. Until those units skipped loudly off macOS, no
   intent could reach a green test step there.

   Partially closed.
   The retained shard responses under `$FM_HOME/state/azure-validation/shards/azv-36b2726cbcf3/*/response/` are the measurement, and they name eleven failing test files, not three.
   Four classes are genuine host capabilities the cell does not have, and those are now gated: a real tmux server it can create windows in (`server exited unexpectedly` on the shard-2 and shard-4 workers), passwordless sudo with `systemd-run` (`Linux systemd integration requires passwordless sudo`), the `/usr/bin/cpp` binding `bin/fm-account-directory.sh` needs before it can validate any Claude quota-axi Keychain approval marker (`system openat binding unavailable`), and outbound reach to the origin remote's host (`origin-egress`).
   Fifty-two units across seven test files are bound to those four capabilities in `tests/host-capabilities.tsv`; the cell declares the four absences by name in `bin/fm-azure-validation-shard-bridge.py`, and `tests/host-capability-gate.sh` turns each into a loud `FM_HOST_CAPABILITY_SKIP`.
   The gate refuses that declaration on Darwin, so macOS coverage is unchanged and cannot be switched off, and CI declares nothing, so its coverage is unchanged too.

   The other five failing files have now been MEASURED rather than inferred, by running the
   whole sealed suite in a local reproduction of the cell's own package closure (Ubuntu 24.04
   with `bin/fm-azure-cell-image.sh`'s apt set, unprivileged, no build toolchain, four parallel
   shards). That run executed 121 test files and failed six, and every failing assertion matched
   the cell's own text. They are three different kinds of thing.

   FIXED, because it was a hermeticity defect in the test rather than a host capability:
   `fm-session-start`. Two of its units forced a `MISSING: node` diagnostic by deleting a fakebin
   `node`. Bootstrap detects a tool with `command -v` against a real system base PATH, so that
   only works on a host where node lives outside `/usr/bin`. On macOS it does; on the Linux the
   cell runs, nodesource installs `/usr/bin/node` and the deletion changed nothing, so both units
   failed for a reason that had nothing to do with what they test. They now choose the first
   bootstrap-required tool this host does not already provide, and FAIL loudly if the host
   provides all of them.

   NOT GATED, because they are capacity rather than capability: `fm-pi-watch-extension` fails
   under four-way parallel load and PASSES on its own in the same container, and
   `fm-watcher-lock` failed in the cell with exit 124, a timeout, next to `Killed` lines in the
   same shard log. A skip in either would hide a real regression.

   GATED, as a fourth declared capability: `fm-teardown-a` and `fm-teardown-b` refuse with
   `secondmate home upstream probe cleanup is unverified`. Instrumenting
   `run_secondmate_remote_probe` showed the probe never runs at all; `secondmate_remote_identity`
   fails first, because it needs outbound DNS resolution and network reach to the origin remote's
   host. With network both files pass all 143 units; with `--network none` the identical refusal
   returns. The cell's repository-command egress is deny-all BY DESIGN
   (`bin/fm-azure-runner-command.sh`), so this is a genuine and permanent capability absence
   there, and no package fixes it. That is `origin-egress`.

   The affected units were enumerated to CONVERGENCE, in one deterministic pass rather than by
   iteration: the suite invokes every case through a single choke point, `run_partitioned_test`,
   so running each case in a subshell there reports every failure in one run instead of stopping
   at the first. Both files were run to completion with the network off - 143 of 143 cases - and
   the result is exactly 37 units, all in the secondmate teardown/retirement family. An earlier
   one-at-a-time iteration had found only 19 and had not converged; the difference is why the
   partial set was not shipped.

   BE CLEAR ABOUT WHAT THIS COSTS. Those 37 units are SKIPPED in the cell, not preserved by some
   other route. The cell does not verify secondmate teardown or retirement authority at all: not
   the landed-work refusals, not the registry locking, not the network-authority pinning, not the
   child quiescence ordering. macOS and CI still run every one of them, and CI is where that
   coverage now lives for any change touching `bin/fm-teardown.sh`.

   The alternative the owner could choose later is to permit the upstream-authority probe a
   narrow egress path to the origin host, which would give the cell this coverage back. That was
   deliberately NOT done here: deny-all egress in that cell is a security property, and trading
   it for a green check is an owner-level decision about the cell's security posture, not a test
   suite's call.

Historical finding from the same attempt, later superseded: the guest's `adjudicate_gates`
polls `control/gate-response-a<n>-<i>.txt` through `fetch_gate_response`, and nothing in this
repo ever writes that blob, so the loop can only ever time out at its
`FM_AZURE_VALIDATION_GATE_WAIT_SECONDS` default of 5400 seconds. That is 90 minutes of billable
cell per gate for nothing, and it is consistent with attempt 1's 1h57m wall time. The remedy is
a scope decision between wiring the host to publish the blob and deleting the loop; the
in-attempt response path the guest already has does not need it.

The accepted run did not rely on that plaintext response path.
It used the protected owner-decision protocol from no-mistakes source
`3eb261add486516995df0791f7dcf815acfbaf5d`, recorded an immutable genesis head and signed history
head, and completed the same daemon run after the owner decision.

At the time of that earlier attempt the receipts fix was exercised only up to the gate, which was
exactly what used to be impossible, and `close` remained unproven.
The 2026-08-23 accepted run supersedes that state and meets the sentence below.

Acceptance (amended by the owner 2026-08-21): one validation cell reaches `close` with its
worktree disk released.
That is no-mistakes running on Azure: the cell executes the whole pipeline in-cell.
The runner-offload lane - a hybrid that keeps the pipeline on the local daemon and ships one test
class to a cell - is an OPTIMISATION, not an acceptance criterion; its per-run routing-file
mechanism is implemented on branch `fm/azure-runner-routing-file`.

The superseded sentence, kept here so the change of bar is visible, read: "a no-mistakes run
offloads a test class to Azure and returns a real verdict; and, separately, one validation cell
reaches `close` with its worktree disk released".

## R5. All of it runs on the pi multi-profile fleet

Status: DONE, met live on 2026-08-22.

The Pi multi-profile requirement applies to ordinary Codex/Pi workers, nested supervisors, and no-mistakes author work.
Crosscheck's primary reviewer is GLM 5.2 through the separately staged `fireworks-glm` provider credential in its Azure model compartment.
Pi is only the bounded guest CLI in that compartment, so Crosscheck consumes neither a Codex/Pi worker profile nor a worker slot.
No-mistakes runs in its separate Azure runner environment.
Both specialized lanes still consume the shared 40-vCPU specialized envelope and 128-vCPU regional ledger.

Crewmate placement now load-balances the least-active usable profile with a stable tie-break, then reuses profiles through the independent sixteen-worker ceiling.
The reusable `account_binding` remains a digest of upstream identity and is visible with per-profile active load, but it is not an exclusive lease.
Every task generation receives a distinct writable projection keyed by an assignment-private binding, and the pooled `auth.json` never reaches a guest.
The controller durably owns an interrupted projection before writing credential bytes, so exact replay keeps the same profile and path and `withdraw` can clean it.
The host remains the sole OAuth refresh authority because the canonical profile must retain twelve hours of headroom before snapshot and the guest VM shuts down within six hours.
Mechanics are owned by `docs/azure-workers.md` under "Provider-account placement across the Pi fleet".

`tests/fm-worker-placement.test.sh` admits sixteen concurrent requests from three profiles, proves balanced loads of six/five/five, distinct projection homes, exact replay, interrupted-write recovery, same-profile cleanup isolation, host-only refresh, and concurrent specialized reservations.
`tests/fm-spawn-cloud.test.sh` proves the staged credential is the one selected snapshot and repeats the twelve-hour preflight before use.
The release lane deliberately does not run a sixteen-VM live campaign; C2's bounded live acceptance owner consumes this deterministic result separately.

Acceptance: concurrent Codex/Pi workers use digest-bound reusable profile snapshots without sharing writable account homes, while specialized no-mistakes and GLM Crosscheck capacity remains outside the worker/profile ceiling.

Met on real compute, which is what an earlier revision of this section still owed.
The tracked evidence `simultaneous_assignments` array is derived from one controller snapshot holding four assignments simultaneously in `assigned` state, on four slots and four distinct upstream account bindings:

| task | task generation | assignment | slot | account binding |
|---|---|---|---|---|
| `azaccept` (parent compartment) | `spawn:a632e0aaaa34a6ff` | `asg-00000018` | 1 | `2242ad73...` |
| `azaccept-cf242c626` (compartment child) | `spawn:a73823d99b3cab33` | `asg-00000019` | 2 | `d48d22a8...` |
| `r5-accept-readme-v3-20260822` | `spawn:a6e066062139056b` | `asg-00000020` | 3 | `82b2c485...` |
| `r5-accept-package-v3-20260822` | `spawn:abcda52fbf779687` | `asg-00000021` | 4 | `dadc7a39...` |

The two ordinary crewmates executed successfully: each returned exit 0, `timed_out false` and `outcome_commits 0` for its read-only inspection brief, with result digests `77c43f95...` and `55151c48...` (`executions[1]` and `executions[2]`).
Each record in `release_proofs` records the `account` authority `proved` against exactly the binding above, so what the worker held is proved on release rather than only at staging.
That historical snapshot used four live workers with four bindings, so it proves the Pi placement path but does not exercise reusable same-profile snapshots.

What this does NOT prove, stated so nobody reads more into it: four concurrent accounts were exercised, not profile reuse at sixteen, and the two ordinary briefs were read-only inspections.
The committing leg is the compartment child, recorded in R2/R3.
These limits are machine-readable in `limitations`.

## R6. Crosscheck uses the configured independent reviewer lane

Current reviewer policy is owned by [Crosscheck](crosscheck.md#reviewer-harness).
The remainder of R6 is historical acceptance evidence, not current configuration or operating instructions.
Its author-family screens, declaration advice, same-model toggles, and launch attestations are retired; preserve the dated observations only as evidence of those earlier runs.

Status: DONE, met live on 2026-08-22. Accepted Azure review `azure-r4-respond-285` recorded a
`cross-family-primary` verdict against the codex-declared PR #285 head. Accepted Azure review
`azure-r6-claude-acceptance` recorded a completed `codex-fallback` verdict against the
non-codex-model declaration on PR #300, with no same-model marker or relaxation required.
Together they complete the two evidenceable declaration legs below. The second verdict was
blocking, not merge approval, and its finding is absorbed by the tracked evidence commit that is
an ancestor of this record. The compact projection and exact source digests are in
`docs/evidence/azure-crosscheck-r6-2026-08-22/`. Read "Where the lane actually stands" before
treating DONE as a claim that every primary reviewer attempt succeeds.

Context: see "The Azure Foundry Fireworks lane is unusable on this subscription" and "The lane is a
named registry, now serving GLM-5.2 direct from Fireworks" below, both 2026-08-20. The retired
Azure Foundry deployment never completed a review and cannot on this subscription. Direct
Fireworks is a different provider path, and it has now produced an accepted GLM review from an
Azure model compartment.

The earlier record stands as history: the lane was built and merged (#264), the `FW-GLM-5.2`
deployment is live, and the primary reviewer went 0 for 6 against PR #220 plus a seventh failed
attempt against PR #266, all `tool-failure` with no citations and no execution proof. The one
verdict this requirement's lane had produced before today came from the pi-codex fallback
reviewer, which is same-family review for codex-authored work and exactly the degradation this
requirement exists to remove.

The quota reading in the earlier draft was wrong about the cause. The deployment does carry two
per-minute limits (25,000 tokens and 25 requests, `FW-GLM-5.2`, DataZoneStandard, capacity 25) and
one attempt did record a 429, but neither limit is what stops this lane. The measured cause is
below.

### The Azure Foundry Fireworks lane is unusable on this subscription (2026-08-20, root-caused)

This is the durable finding. It is not a quota, a route, a region, a credential, or a vendor
problem. It is Azure Marketplace billing.

Measured, not inferred:

- Every request to the Foundry deployment `FW-GLM-5.2` returns HTTP 500
  `invalid_model_endpoint_authentication` ("Failed to authenticate to backend endpoint") in roughly
  0.2 seconds, at every input size.
- The credential is fine. A bad key returns 401. These 500s carry fully computed, DECREMENTING
  `x-ratelimit-*` headers, which only happens after the caller is authenticated and metered. The
  failure is one hop past us, Foundry to Fireworks.
- Not a route problem: `services.ai.azure.com/models/chat/completions` and
  `cognitiveservices.azure.com/openai/v1/chat/completions` fail identically, with both Bearer and
  api-key auth.
- Not region- or resource-specific: a brand-new AIServices account in eastus2 with a fresh
  deployment failed identically.
- The clean discriminator is the PUBLISHER, not the vendor's models. On the same account, same key,
  same subscription, `DeepSeek-V4-Pro` (publisher DeepSeek) and `Kimi-K2.7-Code` (publisher
  MoonshotAI) both returned HTTP 200 on the same endpoint. Every `FW-*` deployment is published by
  Fireworks AI through Marketplace and fails.

The mechanism, with a citable source. Microsoft Learn, "Foundry Models from partners and
community"
(https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-from-partners)
states that Student, Visual Studio Enterprise and Free-credit subscriptions cannot purchase
software-as-a-service offers in Marketplace, and lists as unsupported both subscriptions without an
active pay-as-you-go billing method (student, free trial, startup credit-based) and sponsored
subscriptions that only use Azure credits. This subscription is named "Microsoft Azure
Sponsorship". Partner models require Azure Marketplace, meaning a `Microsoft.SaaS` resource plus an
accepted `Microsoft.MarketplaceOrdering` agreement; BOTH were verified to be ZERO on this
subscription even after the owner deployed `FW-GLM-5.2` through the Foundry portal. The deployment
exists, but the marketplace linkage to the publisher backend can never be established, which is
what `invalid_model_endpoint_authentication` reports.

GLM-5.2 exists only in the Fireworks flavor in the Foundry catalog, which is why GLM specifically
was unreachable there, and why `FW-Kimi-K2.7-Code` would have failed for the same reason while
`Kimi-K2.7-Code` worked.

The two remedies were owner-owned: put a payment method on the subscription (the doc notes a card
on file is charged instead of credits), or reach the model without Azure Marketplace. The owner
took the second. This section exists so nobody re-litigates the Azure partner lane in three weeks.

### The lane is a named registry selecting regular GLM 5.2 direct from Fireworks

The owner opened a direct Fireworks account, which bypasses Azure Marketplace entirely, so GLM-5.2
is the reviewer again on its merits rather than on what Azure would serve.

`bin/fm-crosscheck.py` carries `CROSS_FAMILY_LANES`, a code-side registry of vetted reviewer lanes.
Each entry is a complete endpoint allowlist entry: deployment/model id, Pi provider slot,
chat-completions api surface, endpoint host, the one accepted base URL, and the exact model-level
`compat` the credential may carry. The roster (`$FM_HOME/config/crosscheck-reviewer.json`) selects
the serving lane by naming the model, so substituting among registered lanes is a config change.
Admitting a NEW endpoint stays a reviewed code change on purpose: the allowlist is the security
control, and a credential file must never be able to introduce an endpoint the policy never named.

The registered lane:

| field | value |
|---|---|
| provider slot | `fireworks-glm` |
| model selector | `accounts/fireworks/models/glm-5p2` |
| endpoint | `https://api.fireworks.ai/inference/v1` (chat completions only) |
| api | `openai-completions` |
| pinned model-level compat | strict mode, OpenAI-format session-affinity header |
| declared cost | input 1.40, cached input 0.14, cache write 1.40, output 4.40 per million tokens |
| provider serving contract | regular GLM 5.2 through direct Fireworks chat completions |

The exact regular selector is code-pinned and is therefore the reviewer identity the gate records.
The final Pi terminal event must read back the same `fireworks-glm` provider and regular selector before a verdict is accepted.
The former Fast selector `accounts/fireworks/routers/glm-5p2-fast` remains readable only for historical durable records and is refused for every new roster entry.

Reviewer identity binds the provider slot, the pinned host, and the regular selector `fireworks-glm:api.fireworks.ai/accounts/fireworks/models/glm-5p2`.
The recorded credential identifier is a digest of host, model, and endpoint.
Neither contains nor is derived from the api key: two credentials differing only in `apiKey` produce byte-identical identifiers.

The Azure `azure-glm` slot, the `FW-GLM-5.2` deployment, and the two Azure R6 attempt deployments
(`Kimi-K2.7-Code`, `DeepSeek-V4-Pro`) are retired. Nothing in the code or config points at them.
The legacy `glm-primary` ledger provenance value stays readable for durable records already
carrying it, bound to exactly that retired model, which is no longer registered and so can never be
claimed by a new run.

`config/crosscheck-same-model` is `off`. That relaxation existed only because no cross-family lane
could finish a review, so the codex fallback had to be allowed to review codex-authored work. With
a working non-OpenAI primary, leaving it on would mean a transient provider hiccup silently drops
back to same-family review, which is the exact defect this requirement removes. With it off, the
fallback still serves any author outside the codex family, and a codex-authored PR whose primary is
down FAILS CLOSED rather than being self-reviewed. That single-primary risk is accepted
deliberately; flipping the relaxation back on is an operator act, not a silent degradation.

Reviewer independence is now a FAMILY comparison, not an exact model-id one. The first completed
cross-family review of this work found that a `gpt-5.5` author admitted a `gpt-5.6-sol` codex
reviewer with no same-model marker recorded, which is same-family review of exactly the kind this
requirement exists to prevent (crosscheck finding cc-4dcd7873f71a, reproduced 2026-08-21). A
registered lane is its own family; `gpt-*`/`o1-`/`o3-`/`o4-`/`codex-*` are one OpenAI family and
`claude-*` one Anthropic family; an unrecognized model stays its own family, so nothing that
previously passed starts failing while everything recognized is strictly tightened.

**Truncation is a failed review, not a verdict.**
GLM-5.2 is a reasoning model and can spend its output budget on reasoning before a verdict is complete.
The lane declares `maxTokens` 32000, requires a final `toolUse` stop, and accepts exactly one strict verdict call from the successful final attempt.
The Pi generation schema uses optional non-null structured update fields and a bounded path/content evidence array so both local and Azure schemas pass Pi strict-schema preparation.
The host restores nullable fields, refuses duplicate evidence paths, and applies the unchanged full verdict and evidence validation.
A `length`, `error`, missing, multiple, malformed, or truncated submission records no verdict.
The narrow stringified tool-argument recovery accepts only exactly one complete top-level object and never weakens the outer schema or terminal-state validation.

**Crosscheck now records review economics but does not impose a new spend cap.**
The regular selector's declared rates are 1.40 input, 0.14 cached input, and 4.40 output per million tokens.
The declaration tracks Fireworks serverless pricing at https://docs.fireworks.ai/serverless/pricing.
Fireworks publishes no separate cache-write rate, so emitted cache-write tokens use the uncached input rate of 1.40 per million.
Each new ledger run records Pi usage tokens when available, Pi-calculated cost, declared-rate cost, and provider-reported cost as separate provenance fields.
Pi's event stream does not currently expose a provider billing value, so that field remains null instead of being inferred.
`bin/fm-crosscheck.sh economics <task-id>` reports the durable values without taking a task lock or changing state.
This observability does not turn R10 `daily_budget_usd` into a real-time control and does not add a new spend cap.

The Work list below is retained as the record of what was asked for; the state of each item is in
"What landed" or "Still owed" below.

The requirement is that no author's work is reviewed only by its own model family.
The roster was instead made eight reviewers all on `openai-codex`, by reading "just use the same
pi fleet" as a restriction to one provider.
It was not one, and that is the defect.

The provider question was settled on 2026-08-19.
pi-anthropic is dead twice over: pi's anthropic OAuth authenticates as its own client against its
own token endpoint, so a Claude CLI refresh token cannot be spent by pi, and a fresh pi-anthropic
login would bill at API pricing, which the owner rejected.
An interim directive the same day routed claude reviews through the Claude Code CLI on the
owner's subscription profile; a later interim pick was Kimi-K2.7-Code; the standing decision is
GLM-5.2 through the Fireworks AI lane on Foundry (`FW-GLM-5.2`, pay-per-token Data Zone Standard
US; at decision time it carries tool calling, a 1M-token context, and `reasoning_effort` with
`max` as the default - re-verify at deploy time), chosen on model quality with lineage
independent of both OpenAI and Anthropic.
The custody trade was accepted by the owner on 2026-08-19 knowing its exact shape: Microsoft
disclaims data handling for the Fireworks lane (data is shared between Microsoft and Fireworks
and processed on Fireworks infrastructure inside the US data zone), and the zero-data-retention
promise (volatile memory only, no logging by default, on the chat-completions surface) is
Fireworks' own policy, not Microsoft's. The lane must therefore use plain chat completions
only; the Responses API retains data for 30 days under its default store flag and is forbidden
here.
Billing was verified before acceptance: Fireworks pay-per-token on Foundry bills as Azure
consumption (a feature registration, not a Marketplace SaaS purchase), is MACC-eligible, and
Microsoft's own Startups material states startup credits apply to exactly this SKU; a small live
spend must confirm the credit decrement before volume. Fireworks pay-per-token models can retire
on 15 days notice, which is an accepted operational risk and one more reason the fallback below
stays armed.
Later the same day the owner simplified the routing: ALL crosscheck reviews route through the
GLM lane, for codex-authored and claude-authored work alike. GLM belongs to neither author
family, so single-family review is avoided for every author with one reviewer lane, and review
capacity stops competing with the pi-codex subscription profiles that no-mistakes and the
author fleet consume. The pi-codex roster (which R5 records as proven at the roster level) is
retained as a dormant fallback behind a config flip, never
deleted; every review must name the lane that produced it, and a status read must show whether
GLM is serving or the fallback is active, so a silent fallback is impossible.
(Correction, 2026-08-21: "behind a config flip" held for the LOCAL fallback only. For the
Azure-compartment lane it was false - the codex-family path was additionally broken in code and no
flip would have restored it. See the compartment bullet under "Still owed".)
Fallback operation is a recorded degradation, not free service restoration: with the fallback
active, codex-authored work is reviewed by its own family again (the flip therefore includes
`config/crosscheck-same-model` on for the duration, which the policy screen otherwise refuses),
which is exactly the defect this requirement removes - accepted only while GLM is unavailable,
and one more reason fallback activation must be loud.
The model pick is explicitly provisional: reevaluate after live review data (Kimi-K2.7-Code was
the prior same-day pick; the comparison and the custody/billing verification are in the owner's
evidence folder, R6-FOUNDRY-RESEARCH-2026-08-19.md).

No owner login is needed anymore: the GLM lane authenticates with a Foundry deployment and an
api-key, not a subscription session.
The GLM credential is an api-key, not a pi OAuth slot, so the literal `openai-codex` slot key in
`bin/fm-pi-account-home.py`, `bin/fm-crosscheck.py` (`inspect_pi_credential`,
`account_identity`), and the Azure credential archive in `bin/fm-crosscheck-azure.py` stays as it
is - those three still refuse any non-codex pi OAuth slot, which no longer blocks R6 and remains
the recorded constraint if a second pi OAuth provider is ever added.
The identity question those tools answered with `accountId` still needs an answer for an api-key
credential: reviewer identity for the GLM lane must bind the Foundry resource and deployment,
since an api-key carries no account identity of its own.

Work: register the `Fireworks.EnableDeploy` subscription feature, deploy `FW-GLM-5.2`
(pay-per-token Data Zone Standard) and store the key in the fleet's secret custody, never in
the repo; confirm by a small live spend that the charge decrements startup credit; verify the
endpoint passes `reasoning_effort` through and pin the lane to chat completions only; a pi
custom provider entry (`models.json` `baseUrl` +
`openai-completions` api) pointing at the resource's OpenAI-compatible `/openai/v1` endpoint
with the deployment name as the model id; verify pi tolerates `reasoning_content` in streamed
deltas before rollout; extend `bin/fm-crosscheck.py` `allowed_profiles` and roster validation to
carry the GLM lane (today they pin pi to `("pi", "gpt-5.6-sol", "xhigh")` and would refuse it)
with `config/crosscheck-same-model` off; extend the `bin/fm-crosscheck-azure.py` endpoint
allowlist and credential archive for the Foundry host and api-key shape; define reviewer
identity for api-key credentials as above; retire or re-point the interim claude reviewer
artifacts (the `("claude", "claude-opus-5", "xhigh")` `allowed_profiles` entry, the
`api.anthropic.com` allowlist entry, and the claude-profile boot copy described in
`docs/azure-crosscheck.md`); review guards sized to the model's context window at deploy time: a
strict findings schema, path-existence validation before filing, and a per-review context cap;
routing so every crosscheck draws the GLM reviewer, with the pi-codex roster behind a config
flip as fallback (the flip sets `config/crosscheck-same-model` on, accepting same-family review
of codex-authored work as the recorded degraded mode while it is active); and lane visibility:
the review evidence and report name the reviewing lane, and a status command answers whether
GLM is serving or the fallback is active.

What landed, 2026-08-20 (#264, plus #268 for a defect the live runs exposed):

- `Fireworks.EnableDeploy` registered; Foundry resource `aif-fm7c799d-eus01` created in the
  program's resource group; `FW-GLM-5.2` deployed pay-per-token Data Zone Standard in eastus.
  The key lives in the fleet's secret custody, never in the repo.
- Exercised live against the deployment: chat completions answer, and a pi custom provider
  (`models.json` with a top-level `providers` wrapper, `openai-completions` api, the resource's
  `/openai/v1` baseUrl, the deployment name as the model id) drives it end to end. A probe of
  `reasoning_effort` at low, high, xhigh and max was run and each was observed to be accepted and
  to return reasoning tokens, but no request or response capture was retained, so that one is an
  unretained observation rather than evidence. Re-run it and keep the artifact if it matters.
- `allowed_profiles` carries `("pi", "FW-GLM-5.2", "xhigh")`; the model decides the provider;
  the GLM credential is validated for shape and pinned to one exact endpoint, with any
  model-level `baseUrl` or `api` override refused (pi's provider composer lets a model-level
  field outrank the provider-level pin, so a provider-level-only check was bypassable).
- Reviewer identity binds the Foundry resource and deployment and is provably independent of the
  key: two configs differing only in `apiKey` produce byte-identical identifiers.
- The three interim claude artifacts are retired: the `allowed_profiles` entry, the
  `api.anthropic.com` allowlist entry, and the claude-profile boot copy in the model guest.
  `validate_ledger` now binds `review_family_mode` to the reviewer model in both directions.
- Fallback demonstrated end to end on 2026-08-20 against PR #220: the roster flipped to
  pi-codex with `config/crosscheck-same-model` on, the run printed the exact degraded warning
  naming the standing-in reviewer and the relaxation, the ledger recorded
  `review_family_mode: codex-fallback` and `model_independence: same-model`, and the review reached
  a real clear verdict with citations and an execution proof. The roster was flipped back
  afterwards; the operator has since restored the fallback entries again, as the status above
  records. This was the only verdict this requirement's lane had produced before accepted Azure
  review `azure-r4-respond-285`; it is no longer the only verdict.

### The acceptance sentence is not evidenceable as written, and is amended (2026-08-21)

R6's acceptance says "a codex-authored change AND a claude-authored change are each reviewed by a
GLM-backed reviewer". **The system cannot evidence that sentence, and this must be said before any
run is recorded against it.**

What the code actually does, traced rather than assumed:

- Eligibility derives from `model` in the task meta and NEVER from `harness`
  (`bin/fm-crosscheck.py`, `model_family(meta["model"])`). `parse_meta` requires `harness` to be
  present and non-empty, then nothing in reviewer selection reads it.
- The ledger records **no author identity at all**. The one call site passes
  `author_account_identity=""`, with an inline comment saying task metadata carries no upstream
  authorship account record.
- Git carries no harness signal either, by design: the no-self-attribution rule means no trailer
  ever distinguishes a claude crewmate from a codex one.

So the task meta is the only authorship input, and a task meta is a DECLARATION, not a record.
Anyone can write `harness=claude` over any change. "A claude-authored change" is therefore not a
checkable property of any artifact this system produces.

**Amendment, and the reading to use.** The acceptance becomes what the system can actually
evidence, which is also what the 2026-08-19 amendment's own reasoning needs ("one reviewer family
outside both author families satisfies the paradigm for EVERY author"):

> The cross-family lane completes a review end to end, and the family screen admits that reviewer
> against BOTH a codex-model author and a non-codex-model author, with the ledger recording the
> reviewer model, the review family mode, and whether the `crosscheck-same-model` relaxation was
> required.

Every clause there is checkable from the ledger. Nothing in it claims to know who wrote the code.
This is deliberately weaker than the original sentence, and it is weaker in the only direction
available: the original was never provable, so leaving it in place would have meant marking R6 DONE
on an assertion.

Making authorship genuinely recordable was the alternative, and at the time of this amendment it
was out of scope. Resumed R10 later added a signed pre-agent launch record plus an exact-head
binding for centrally configured Firstmate tasks. That newer producer does not retroactively make
the historical R6 declaration runs into authorship evidence.

**Declaring a codex author is the SAFE error; declaring a claude author is the dangerous one.** A
codex declaration can only narrow eligibility: against a codex-family reviewer it forces the
`crosscheck-same-model` relaxation to appear in the record, and with the relaxation off it fails
closed. A claude declaration widens eligibility silently and makes the run print "relaxation was
not required" and record clean cross-family separation that may never have happened. When the real
author is unknown, declare codex and take the louder record.

**Correction to this program's own artifacts.** The two runs in
`$FM_HOME/data/crossfamily-r6-281/` were driven by a hand-written two-line meta asserting
`harness=claude` / `model=claude-opus-5` over a PR whose real author harness is not recorded
anywhere. Those runs are real reviews and their findings were real and acted on, but their
authorship claim is a declaration, and **they must not be counted toward the acceptance above**.
Later probe runs declare a codex author instead, per the asymmetry.

### Where the lane actually stands, 2026-08-21

Stated plainly, because wiring being right is not the acceptance.

**Has the cross-family lane completed both evidenceable declaration legs? YES.** Azure review
`azure-r4-respond-285` completed against the codex-declared PR #285 head and recorded
`review_family_mode: cross-family-primary`. Azure review `azure-r6-claude-acceptance` completed
against the non-codex-model declaration on PR #300 and recorded `model: gpt-5.6-sol`,
`review_family_mode: codex-fallback`, and no `model_independence: same-model` marker. Its blocking
verdict carried three citations and an executed Azure reproduction. The tracked compact record is
`docs/evidence/azure-crosscheck-r6-2026-08-22/evidence.json`.

The earlier local attempts against PR #281 on the direct Fireworks lane remain useful failure
history:

| # | outcome |
|---|---|
| 1 | GLM produced a COMPLETE turn; final text was not bare JSON, refused as `malformed verdict artifact`. Fell through to the codex fallback, which reached a real blocking verdict |
| 2 | `Pi reviewer: bounded command timed out after 1800 seconds` |
| 3 | GLM produced a real verdict naming the exact head and the exact account home, in BARE JSON, refused as `Unterminated string starting at: line 1 column 3045` |
| 4 | GLM completed a full 424s review and produced a COMPLETE, SCHEMA-VALID verdict. Refused `UNREVIEWED` because the reviewer's own `executed_reproduction.command` did not name both SHAs |
| 5 | Identical to 4, same refusal. So attempt 4 was not a lucky run and this failure is not variance |

Attempt 1 was never a hang: the model went through pi, completed a turn, and produced text, and was
rejected at the LAST step on output SHAPE. That fact also disproved the suspect this document
previously named. Measured since:

- **`reasoning_content` in streamed deltas is NOT the problem, and that Work item is answered.**
  Streaming the review-shaped prompt reaches `[DONE]` in 21-24s carrying 390 and 867 reasoning
  deltas, at default and `high` reasoning effort, with a maximum inter-chunk gap of 3.4s. A large
  reasoning stream streams fine.
- **The output shape was a Markdown fence, confirmed byte for byte.** Asked for this gate's exact
  review instruction and schema, GLM returns ` ```json\n{...}\n``` `, and a bare parse of that fails
  with `Expecting value: line 1 column 1 (char 0)` - precisely attempt 1's recorded error. The
  extractor now unwraps exactly one complete fenced block, and attempt 3 duly got past it.
- **The remaining failure is a TRUNCATED verdict carrying a SUCCESSFUL stop reason.** Attempt 3's
  JSON breaks mid-string at char 3044 while pi reported `stopReason: stop`, so the stop-reason
  guard never fired and only the JSON parse caught it. That is the strongest possible argument for
  keeping BOTH refusal grounds rather than treating either as redundant, and both stay pinned by
  tests.
- **It is not the token cap.** Both `max_completion_tokens` (what pi sends for this provider) and
  `max_tokens` are honored at 20000 and both return complete, parseable verdicts of 3212 and 3775
  completion tokens; the lane declares `maxTokens` 32000.

Attempt 4 is the milestone: **the lane executes a complete review and produces a schema-valid
verdict.** The ledger recorded a genuine cross-family reviewer record against a codex-model author
- `model: accounts/fireworks/models/glm-5p2`, `review_family_mode: cross-family-primary`, NO
`model_independence` marker (so clean family separation with no relaxation required),
`credential_source: pi-fireworks-glm-models-file`, and the non-secret
`credential_identifier: provider-binding:fireworks-glm:d2a164ff...`, over 424s of reviewer time.
Under the amended acceptance above, the family-screen clause is now EVIDENCED for a codex-model
author.

What remains is NOT transport, shape, or policy wiring. It is the reviewer obeying the review's own
evidence discipline: the gate refused the verdict because the model's `executed_reproduction`
command did not name both the base and head SHAs, which the prompt requires. That is the gate
working exactly as designed, and it must NOT be relaxed to get a green verdict - a lane that earns
its first verdict by lowering the evidence bar would be worth less than no lane. Attempt 5 repeated attempt 4 exactly, so this is
REPRODUCED behavior rather than a flaky run: GLM-5.2 reliably omits the SHAs from its reproduction
command. The remaining risk is therefore instruction compliance by this model on the evidence
contract, plus the intermittent truncation attempt 3 showed, and neither is a reason to weaken a
refusal.

The obvious next step is to strengthen the reproduction-command INSTRUCTION rather than the check,
which is legitimate prompt work and not a relaxation. It is deliberately NOT done here: that prompt
is shared with the codex lane, which currently satisfies the clause, and changing a contract that
every merge depends on to accommodate one model is a decision to take deliberately rather than at
the end of a long session.

**What #281 closes:**

- The lane is executable at all. `azure-glm` / `FW-GLM-5.2` on main are dead references: the Foundry
  account `aif-fm7c799d-eus01` has ZERO deployments as of 2026-08-21, so the pre-existing lane could
  not have served a review under any circumstances.
- Two reproduced high-severity policy bypasses, both found by a real completed review of the branch
  (codex-family fallback lane) and both fixed with tests: provider-qualified authors bypassing
  family separation (cc-4dcd7873f71a and cc-5ec330d3c74d) and the model-level `compat` pin missing
  the provider and `modelOverrides` layers pi also composes (cc-ca5848b19ac3).
- Operator documentation that told captains to provision an `openai-codex` `auth.json` for every Pi
  reviewer, which misprovisions a cross-family lane home (cc-769d7eba2ded).
- The startup-credit item above, retired as moot.

**What #281 did NOT close by itself, and must not be read as closing:**

- The acceptance itself was not closed by #281. The later accepted Azure review
  `azure-r4-respond-285` completed the codex-model leg. The second leg was completed later by
  `azure-r6-claude-acceptance`; it is not retroactive evidence for #281.
- The status item was not closed by #281, but it was closed by #287.
  `bin/fm-crosscheck.sh status` is a lock-free, state-free read that reports the roster's first
  serving family, the current `crosscheck-same-model` policy, and the latest durable ledger run's
  `review_family_mode`. It reports configuration and durable history, not proof of acceptance by
  itself; the two accepted ledger records and their tracked evidence are the proof that closes R6.
- Review guards sized to the model's context window. Two of the three the Work list names DO
  exist and are stronger than asked: the findings schema is strict (`additionalProperties: false`,
  enum'd severities, `maxItems` caps), and citations are validated before filing by escape check,
  `git ls-files --error-unmatch` tracked-at-head check, and a line-in-range check. The third, a
  per-review context cap actually SIZED to the serving model, does not exist:
  `MAX_LEDGER_PROMPT_BYTES` (64,000) and `MAX_PROJECTED_FINDINGS` (512) are fixed constants, and
  nothing reads the lane's declared `contextWindow`. This change does not re-size them.
- A per-review spend meter is now durable telemetry rather than a live budget control.
  New Pi runs record input, output, cache-read, and cache-write tokens when available, Pi-calculated cost, declared-rate cost, and explicit provider-cost provenance.
  R10's `daily_budget_usd` still has no real-time enforcement path and must not be described as one.

Still owed, and honestly so:

- CLOSED as far as the retired Azure Foundry GLM deployment is concerned, and the earlier reading
  of it was wrong. No live end-to-end review is obtainable through that deployment, for the
  Marketplace reason root-caused above. The accepted Azure compartment review
  `azure-r4-respond-285` uses the direct Fireworks path instead. The historical detail stands:
  attempts 0 and 1 (05:54Z)
  died before reaching the provider at all, on a local harness fault in an operator-authored
  instrumentation shim whose `/dev/fd` redirect was refused under the reviewer sandbox; attempts
  2, 3 and 4 (05:55Z to 05:59Z) each recorded only `Pi reviewer emitted a turn after agent
  completion`, the parser defect #268 then fixed, which masked whatever the provider actually
  returned; attempt 6 (06:25Z) is the only review run anywhere that records an actual 429; ledger
  slot 5 at 06:08Z is the pi-codex fallback demonstration, not a GLM run. The quota was named as
  the leading suspect. It was not the cause. The acceptance now rests on a completed review from a
  registered, reachable cross-family lane instead.
- The startup-credit decrement check is MOOT, retired rather than left standing. It asked for a
  small live spend confirming the charge decrements Azure startup credit. That premise died with
  the lane move. Fireworks pay-per-token ON FOUNDRY billed as Azure consumption; Fireworks DIRECT
  bills a Fireworks account and touches no Azure credit at all, so no charge for this lane can ever
  appear in Azure Cost Management. Nobody should go hunting for one. The historical Azure numbers
  are kept only as a record of what the dead lane consumed: deployment metrics for
  `aif-fm7c799d-eus01` recorded 727,136 tokens on 2026-08-20 (515,965 in the 04:00Z hour, 135,911
  in 05:00Z, 75,260 in 06:00Z; an earlier draft reported roughly 510K for the day, which was the
  04:00Z hour alone). That resource now has ZERO deployments, verified 2026-08-21, so it can serve
  nothing. If a spend signal is still wanted it is a Fireworks-side number, and the meter it would
  need does not exist here either: see the spend bullet below.
- The Azure-compartment lane was not merely switched off. "Switched off rather than unbuildable"
  was TOO KIND, and this is the
  second time this requirement has had to retract a merely-disabled claim without anyone reaching
  the code (the first was the stale `pi`-binary reason). `enabled: false` was MASKING an
  independent in-code blocker: the compartment archive gate derived the executing-account identity
  separately from `account_identity` and compared a bare account id against a prefixed one, so the
  codex-family path refused ITSELF and no codex-family compartment review has ever run. Fixed
  2026-08-21 with a single shared derivation and a test that is red on the old code; the default
  switch is still off, but explicit Azure execution has now produced accepted review
  `azure-r4-respond-285`. Recorded because the first fix was itself incomplete:
  it unified the two HOST derivations while the model guest kept a third, moving the refusal from
  staging into a booted, paid VM. The guest is covered by an executing test now rather than
  substring assertions, which is why that was invisible. The serving lane
  today is the local pi reviewer. The reason recorded here previously, that the `fm-ccm` image
  carries no `pi` binary and needs a rebake, is stale and is corrected below.
- The spend signal for the primary reviewer is closed as durable per-run observability, not as a budget control.
  The regular Fireworks lane declares input 1.40, cached input 0.14, cache write 1.40, and output 4.40 per million tokens.
  The ledger stores available Pi token usage, Pi-calculated cost, declared-rate cost, and explicit provider-reported provenance.
  The read-only `economics` command reports those values and finding disposition without a dashboard.
  R10 still has no real-time enforcement path, and C3's daily bound remains a recorded-spend backstop rather than a live per-review cap.
- Of three formerly untracked Work-list items, two are now closed. #287 added the lock-free,
  state-free `bin/fm-crosscheck.sh status` read of serving family, same-model policy, and latest
  durable ledger family. Pi's handling of `reasoning_content` was verified live as recorded above.
  The remaining item is review guards sized to the model's context window at deploy time: the
  generic guards pre-exist, and the one size that exists, `MAX_PROMPT_BYTES` in
  `bin/fm-crosscheck-azure.py`, was set in #130 on 2026-08-13 and was not revisited for a
  1M-token model.

Correcting the Azure-compartment blocker, 2026-08-20: the current `fm-ccm` image does carry `pi`,
and the lane defaults off because it was switched off. `$FM_HOME/config/crosscheck-azure.json` has
`"enabled": false`, set by an operator on 2026-08-20; explicit Azure execution can override that
default and has now completed accepted review `azure-r4-respond-285`. The image claim was already
stale when it was written: it entered
`docs/azure-crosscheck.md` in #264 on 2026-08-20, citing a diagnostic boot taken on 2026-08-16
against an image the config had stopped naming two days earlier. That measurement was correct
about gallery version `1.0.1786915905`, whose source managed image `img-fm7c799d-ccm-1.0.0` was
built from the pre-Pi declaration and carries no `pi-tarball-sha256` tag. The config now names
`1.0.1787092687`, published 2026-08-18T22:38:08Z from managed image
`img-fm7c799d-ccm-1.0.1787091895`, which does carry both `pi-tarball-sha256` and
`node-tarball-sha256`, matching the digests tracked in `docs/azure-crosscheck/model-image-closure.json`
for `pi-coding-agent-0.84.1` and Node v22.23.2. Those tags exist only on an image built from the
Pi-carrying declaration that #246 added to `docs/azure-crosscheck/model-image.json`, whose build
asserts that `/usr/local/bin/pi --version` equals the tracked version twice, once before and once
after the credential purge, so a build that reached distribution could not have omitted `pi`. That
Image Builder run succeeded between 22:26:20Z and 22:36:46Z on 2026-08-18, after #246 landed on
main at 20:51:35Z, and `bin/fm-crosscheck-azure-image.sh` builds only from the tracked declaration
at a HEAD already landed on public main. A Pi-harness review completing on this image is now proven
by accepted Azure review `azure-r4-respond-285`; it completes R6's codex-model leg. The separate
accepted Azure review `azure-r6-claude-acceptance` completes the non-codex-model declaration leg
on the same current image family.

Acceptance (the evidenceable amendment above): the cross-family lane completes a review end to
end, and the family screen admits it against both a codex-model declaration and a non-codex-model
declaration, with the ledger recording reviewer model, review family mode, and whether the
same-model relaxation was required. The fallback flip to pi-codex is demonstrated once, its
activation is visible in the review evidence and status read, and the demonstration records its
degraded same-family mode. The codex-model leg is complete through `azure-r4-respond-285`; the
non-codex-model declaration leg is complete through `azure-r6-claude-acceptance`. The latter used
the screened Codex fallback outside the declared Claude family, recorded that fallback family
mode, omitted the same-model marker, and completed with a blocking verdict and executed proof.

## R7. Everything is logged in

Status: DONE.

Re-checked 2026-08-21 against `bin/fm-credential-expiry.py report` and the live roster rather
than against an earlier note. Every credential a live lane reads is present and current, and no
owner login is outstanding. Authors and no-mistakes run on the eight pi profiles `openai-codex`
and `-2` through `-5`, `-7`, `-8`, `-9`, all `usable` to 2026-08-29; the numbering skips 6, and
those eight names are exactly the slots `~/.pi/agent/auth.json` holds, which is what
`bin/fm-pi-refresh.py` renews. R8 keeps them moving: its LaunchAgent
`com.firstmate.pi-auth-refresh` is active with seven runs and last exit code 0. The crosscheck
roster reads its GLM primary plus three of those same pi profiles, and the GLM lane
authenticates with an api key rather than an owner login, so it adds no login to this
requirement; whether that lane returns verdicts is R6 and not this.

Nothing on a live path reads a claude credential, an `accounts/codex/*` profile, or
`accounts/pi/1` through `6`. No script under `bin/`, `tools/` or `skills/` names the claude or
codex pools at all outside the expiry reporter, no live file under `$FM_HOME/config` names them,
and the pi slot list comes from pi's own `auth.json` rather than a scan of the account
directory, so the numbered leftovers are never selected. Their state is recorded here rather
than owed. An earlier revision of this section called the third claude profile "refreshable with
material declared valid to 2026-09-10", which read the REFRESH token's horizon as readiness.
What is true: two of the three profiles in `~/.local/share/agent-fleet/accounts/claude/` hold
blanked, length-zero access AND refresh tokens, and the third's ACCESS token expired
2026-08-17T20:31:18Z behind a refresh token good to 2026-09-10. `refreshable` states that a
refresh token is held, never that the profile is ready to use. Renewing it is an OWNER LOGIN:
nothing refreshes claude on a schedule, `bin/fm-pi-refresh.py` is hardcoded to `accounts/pi` and
names claude nowhere, and `bin/fm-credential-expiry.py` only reads. None of it is needed, which
is what makes this requirement met rather than blocked.

This status stands on R8 continuing to hold, because the pi horizon is 2026-08-29 and the
LaunchAgent is what advances it. Re-read `bin/fm-credential-expiry.py report` in full before
relying on this line: a truncated listing miscounts the pool, and the profile numbering is not
contiguous.

## R8. Auth refreshes on its own

Status: DONE.

`bin/fm-pi-refresh.py` selects the profiles whose access token dies inside a horizon, copies the
pool, hands the due slots to `bin/fm-pi-refresh.mjs`, republishes each renewed slot into the
account home its consumers read, and re-reads that home through the expiry owner before reporting
success, so its exit code means the fleet is live rather than that an HTTP call returned 200.

The rotation runs through pi's own OAuth flow inside pi's own credential lock, because the
write-back has to land under the lock a running pi takes and the refresh has to happen inside that
same lock or two refreshers spend one refresh token.
It runs host-side because the reviewer compartment's egress allowlist carries the provider's API
host and deliberately not its auth host.

The schedule is one machine-global macOS LaunchAgent, `com.firstmate.pi-auth-refresh`, running
`run-once --all --scheduled` every six hours against a horizon of half the observed ten-day
credential life.
It is machine-global because the pool is: one `auth.json` serves all nine Firstmate homes on this
machine, and every home reads the same job because the installed schedule is identified by what it
runs rather than by which checkout is asking.
A heartbeat counts only when it carries the activation nonce baked into the installed plist, which
reaches a process only through launchd's copy of the job environment, so a hand-typed
`--scheduled` writes nothing and can neither forge proof of life nor destroy the real one.

Acceptance met on 2026-08-19: all eight profiles renewed from 2026-08-25 to 2026-08-29 through the
tool, `bin/fm-credential-expiry.py report` shows eight `usable`, `bin/fm-crosscheck.py`'s own
reader still derives eight distinct accounts, and launchd's own first fire ran a renewal pass and
stamped a matching nonce with `scheduler-status` reporting `installed`.

Residual: the profiles have not yet crossed an expiry boundary unattended, because the first one
they will cross is 2026-08-29. The mechanism is proven; the calendar is not.

## R9. Everything is set up and proven

Status: DONE, met live on 2026-08-23.

Proven by the subset of the 2026-08-22 live acceptance recorded in the tracked evidence linked from R2/R3:

- The worker landing path.
  The compartment child's outcome landed as commit `818e018d8dbb7b8d5bccae2b1d93192364533d1b` on `refs/heads/fm-child/azaccept-cf242c626-20260822` at origin (`origin`).
- Execution on the leased Pi provider accounts.
  All four records in `release_proofs` record the `account` authority `proved` against the account binding the controller leased for that task.
- Secondmate-in-Azure, formerly blocked on R2/R3, which is now DONE:
  `release_proofs[0]` records all five authorities `proved` for the compartment.
- Resource cleanup.
  `post_reset.final_verifier` reads `PASS post-reset 60 exact resources absent; queue complete; no workers or VMs`, with the digest-bound inventory, VM-list, resource-list, and controller source artifacts named in `source_artifacts`.

An accepted Pi-harness review on the current model image is proven by Azure review
`azure-r4-respond-285`.

The former outstanding dependency is now complete: R4 cell `azv-c1bb1c5ff906` reached `close`
with its worktree disk released, as recorded in
[`docs/evidence/azure-r4-live-acceptance-2026-08-23/evidence.json`](evidence/azure-r4-live-acceptance-2026-08-23/evidence.json).
R6's second declaration leg was already complete, so that tracked evidence closes the previously
accepted Azure core through R9.
Resumed R10 has its own Slack activation and live-team acceptance below.

The landing path used to be recorded here as unprovable synthetically, and that was correct
behavior rather than a gap to route around.
`--outcome-dir` requires full staging, and `request` derives every binding from
`$FM_HOME/state/<task>.meta`, with caller-supplied bindings refused outside the hermetic test
backstop.
The existing smoke assignments could not be reused because their `repository_generation` is not a
commit that exists.
Proving it required a real spawned crewmate task that commits, which is what `azaccept-cf242c626`
did.

## R10. Crosscheck is exposed to team engineers through Slack

Status: DEFERRED 2026-08-21, RESUMED 2026-08-26; implementation complete, central activation and live-team acceptance pending.

Historical explanation: the owner dropped R10 from the August 21 critical path only to ship the
core Crosscheck lane sooner.
The original listener remained in-tree and inert without credentials.
That deferral was not a rejection of Slack access, and this resumed work preserves that history.

The resumed lane is owned by `docs/crosscheck-slack.md`.
It keeps outbound-only Slack Socket Mode and the existing direct CLI, while four listener workers
enter the same central four-lane FIFO allocator as direct requests.
Exact channel and repository allowlists, durable event dedupe, atomic per-engineer daily caps,
visible saturation, central reports, and a launchd restart owner remain required.

The original build's branch-prefix authorship screen, unconditional `model=human-authored` staging, and signed launch/exact-head author attestations are retired.
[Exact-head admission](crosscheck-slack.md#exact-head-admission) owns the replacement admission policy and reviewer-contract reference.

Activation still requires the Slack app's two credential values, one repository-scoped read-only
GitHub credential, exact approved channel IDs, exact approved repositories, and a binding daily
request cap on the coordinator.
Credential names and locations are recorded in `docs/crosscheck-slack.md`; values never enter this
document, Slack replies, logs, state, or artifacts.

Acceptance: an internal engineer other than the owner tags the bot in an approved channel with one
allowlisted PR URL and receives an admitted exact-head CLEAR or findings reply in the same thread.
The reply names the reviewed SHA, reviewer lane, task ID, and durable artifact; the meter records
the engineer; duplicate delivery starts exactly one review; head movement invalidates the verdict;
out-of-allowlist requests and requests without a resolvable exact live head refuse; infrastructure failure never reads CLEAR.

## C1. Crosscheck completes in 20 to 30 minutes

Status: REMEDIATION IMPLEMENTED; LIVE ACCEPTANCE PENDING; NOT ACCEPTED.
C1 remains NOT ACCEPTED until a fresh post-merge adversarial review from clean public `main` completes in 20 to 30 minutes and retains its phase breakdown.
The first fresh released regular GLM 5.2 measurement also missed below the band: a substantive 19-file PR completed clear in 654.190 seconds total, with 649.119 seconds inside `reviewer`.
The two earlier accepted baseline measurements missed above the band at 35m33s and 44m25s total, with 99.7 percent and 99.6 percent respectively inside `reviewer`.

### Measured critical path

The original 75-minute premise has no retained phase breakdown and is historical context only.
The instrumented 35m33s, 44m25s, and 654.190-second local-lane runs are the relevant baselines because they carry `durations_ms`.
All three put effectively the whole clock inside the synchronous model reviewer rather than snapshot, proof execution, or ledger work.
Warm Azure VMs, a faster Azure SKU, and additional lanes do not shorten that measured critical path: they affect compartment startup or concurrency, not one local reviewer's model turns.
The family that produced those two historical readings was not retained, so this document does not manufacture an attribution for them.

At the exact code revision this remediation started from, the registered primary selector was the Fast router `accounts/fireworks/routers/glm-5p2-fast` on the `fireworks-glm` custom Pi provider.
The standing decision is to use regular GLM 5.2 instead.
The globally enabled Pi Fast Mode is not part of this lane because Crosscheck loads only its explicit verdict extension and the installed fast-mode package targets OpenAI providers.

### Remediation

New reviews now admit only the regular Fireworks GLM 5.2 selector `accounts/fireworks/models/glm-5p2` at the same direct Fireworks chat-completions endpoint.
The reasoning level remains `xhigh`, the complete exact-base/exact-head review stays intact, and every reproduction, mutation, ledger, family, fallback, and refusal contract is unchanged.
The final Pi terminal event must report the exact `fireworks-glm` provider and regular selector requested by the roster before its verdict is accepted.
A terminal event reporting the historical Fast selector, another provider, or no model identity becomes a tool failure.
The same readback check runs in both the local Pi lane and the Azure model guest.

The local regular lane now performs one substantive full-diff pass with an in-session skeptical re-challenge before finalization.
The reviewer uses bounded exact-head repository search/read, records findings and suspicions provisionally, retracts disproved items during its in-session re-check, and finalizes once.
The controller replays the accepted digest-bound event log independently before any review becomes durable.
The reviewer record binds the one-pass depth mode and exact terminal provider/model readback fail-closed to the registered regular cross-family lane, while exact-head reuse remains available only under its existing unchanged contract.

The former Fast selector remains readable only as historical provenance, including local and Azure ledgers written before this change.
It is not in the new-review allowlist and cannot silently continue serving from an old roster.
The status read names the exact selector at roster entry one, so rollout can distinguish the regular path from both the historical Fast path and the Codex fallback before spending on acceptance.

The regular selector is declared at 1.40 dollars per million input tokens, 0.14 dollars per million cached input tokens, and 4.40 dollars per million output tokens.
Cache-write tokens use the uncached input rate because Fireworks publishes no separate cache-write rate.
Crosscheck records token and cost telemetry but adds no spend cap, so C3's recorded-spend caveat remains unchanged.

### Instrumentation and acceptance still owed

Every run record retains integer-millisecond `durations_ms` measured with `time.monotonic()`.
The local lane records `snapshot`, `reviewer`, `proofs`, `ledger`, and `total`.
The compartment lane additionally records `create`, `stage`, `boot`, and `collect` only when that lane performed them.
A missing phase means the work did not run rather than that it took zero time, and `bin/fm-crosscheck.sh timings <task-id>` remains the read-only table.
`bin/fm-crosscheck.sh economics <task-id>` is the parallel read-only table for tokens, costs, turns, reviewer latency, finding disposition, outcomes, and reuse provenance.

After this implementation lands on public `main`, the acceptance owner must update the operator roster and the dedicated `models.json` to the exact regular selector, compat, and declared costs, then read `bin/fm-crosscheck.sh status` back before launch.
The owner must run one real fresh adversarial review of a current exact PR head under the single-pass skeptical-rechallenge protocol, retain the complete phase breakdown and economics, and verify the final ledger still carries the exact-head clear or blocking verdict, evidence execution, mutation proof where required, cross-family primary identity, terminal route, and review-depth fields.
Only a genuine 20-to-30-minute completion closes C1.
A run below 20 minutes or above 30 minutes is recorded honestly and leaves C1 NOT MET.
The implementation never sleeps to enter the band, truncates work, narrows the diff, lowers reasoning, or weakens a gate.
Acceptance must use a fresh review rather than the exact-head reuse optimization.

## C2. Many crewmates, no-mistakes, and crosschecks run in parallel without contention

Status: NOT DONE.

All three C2 changes are landed: the transactional apply, the per-slot `pending_actions` map
with its load fence and revision CAS, and the lock discipline that runs every provider mutation
outside the fleet lock under a non-blocking per-slot lease, with the drain after convergence and
`abandon-claim` as the evidence-preserving exit from a deterministically refused claim.
What remains for DONE is the acceptance itself: many crewmates, no-mistakes runs, and
crosschecks demonstrated running in parallel against live capacity without contention.

The completed implementation uses per-assignment pending state so reconcile drives many workers
concurrently, with idempotency preserved per action rather than globally, and a lock discipline
that puts provider calls outside the fleet lock.
The first of the three changes landed on 2026-08-19: a provider mutation applies into a copy,
commits only on success, and is refused if its effects reach outside the one compartment its slot
owns.
The later per-slot pending map and lock-discipline changes completed that work.
The profile ceiling defect is also corrected in this implementation: sixteen ordinary worker/supervisor requests can reuse fewer host-owned Pi profiles through assignment-private snapshots.
No-mistakes reservations and `fireworks-glm` Crosscheck model/tool/verifier reservations do not consume those sixteen worker slots or any Codex/Pi worker profile.
They still share specialized-envelope, regional, exact-family, and spend admission with the worker fleet.
`tests/fm-worker-placement.test.sh` proves that separation deterministically, while the live concurrent campaign remains the acceptance owed here.

Crosscheck model admission now retains the shipped four-lane FIFO model while transient exact-family or shared-capacity pressure polls one durable allocator reservation identity within the configured queue wait.
Timeout releases that exact queued identity, non-capacity refusals remain immediate, and reviewer credentials are rechecked after admission before staging or billable compute.

One thing not to do, found while designing this: the three capacity commands stay fully locked.
`merged_specialized_reservations` ignores local reservations whose status is not `reserved`, so a
candidate parked by one concurrent reserve is invisible to another's admission arithmetic and two
of them can each admit against a budget that fits one.

Acceptance: several crewmates, a no-mistakes offload, and a crosscheck run concurrently without
the controller serializing them.

## C3. Cost guard

Status: DONE, met live on 2026-08-24.

The requirement is that a day's spend cannot quietly reach 100 dollars.

The daily spend bound is landed in `bin/fm-worker-lifecycle.py`: `FM_AZURE_WORKER_DAILY_BOUND_USD`
(default 100; zero, negative, or non-numeric values refuse loudly rather than meaning unbounded)
refuses every lane that commits new money once the day's recorded spend crosses it - worker
`create` and `resume` AND new specialized reservation admissions through `capacity-reserve` and
`capacity-reserve-shape`, which the disposable runner performs automatically and which would
otherwise let crosscheck/validation compute quietly cross the bound with no human anywhere.
Releases, `capacity-release`, deallocates, deletions, resets, the message lane, `execute` on
already-held capacity, and lineage re-admission of already-reserved constituents stay allowed so
wind-down and held work are never blocked.
The only way past it is the explicit operator override
`FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE=<utc-day>` naming the exact current UTC day, printed loudly
and recorded durably - only after the admission decision actually admitted - every time it takes
effect.
Honest caveat: Cost Management gives month-to-date actual that lags hours, so day spend is
current actual minus a durable baseline snapshotted at the first observation of each UTC day,
and the bound is a backstop on RECORDED spend rather than a real-time meter; the same-day
protectors ahead of it are the per-mutation cumulative admission and the idle deallocate path.

Idle release is landed as idle DEALLOCATE: an assigned worker whose newest durable activity
stamp (last recorded execution or steer) is older than `FM_AZURE_WORKER_IDLE_RELEASE_SECONDS`
(default 14,400 - the four hours wkr-04 idled - floor 600), with no pending claim on its slot
and its queue item still assigned, gets an automatic deallocate planned by reconcile, and status
loudly lists it until a human releases it properly.
Deallocation, not release: releasing requires authority receipts a machine cannot mint, while
deallocation is reversible at the VM level and stops the spend, which is what this requirement
needs; for the ASSIGNMENT it is terminal (no power-on lane exists; release or surrender is the
exit), and compartments whose legs must live longer - the pending secondmate monitor renews at
exactly the 14,400-second default - must raise the knob above their renewal cadence.
A worker with no recorded execution is never idle-deallocated (nothing proves its task ended);
its TTL remains the backstop.
The adjacent cooldown gap is also closed: a release-proved worker whose VM was deallocated
operator-side (surrender's dark-compute gate) now gets `cooldown_started_at` stamped on first
observation, so `delete-compute` becomes due instead of waiting forever.

Resumed R10 runs its outbound Socket Mode listener on the coordinator Mac with approximately zero
standing Azure cost.
Its per-submitter daily request ledger lives under `$FM_HOME/state/crosscheck-slack`.
`daily_request_cap` is binding and atomically enforced across concurrent workers.
`daily_budget_usd` remains optional and binds only when a review exposes compatible cost data.

Acceptance: a day cannot cross the bound without an explicit operator override, and a worker
whose task ended deallocates unattended.
The 600-second idle-deallocation subject remained assigned without release proof until ordinary
authority-backed cleanup.
Positive recorded spend 2.983466 USD crossed a controlled 1 USD bound and refused new compute
with `override=none`, after which the default 100 USD/no-override zero state was re-proved.
The compact tracked record is
[`docs/evidence/azure-c3-cost-guard-2026-08-24/evidence.json`](evidence/azure-c3-cost-guard-2026-08-24/evidence.json),
with its claim map and verification commands in the adjacent
[README](evidence/azure-c3-cost-guard-2026-08-24/README.md).
Cost Management still lags by hours, so this acceptance remains a backstop on recorded spend,
not a claim of real-time metering.

## Order of work

1. R8, done 2026-08-19.
2. C2, whose three implementation changes are landed but whose live parallel acceptance remains.
3. R2/R3, done 2026-08-22. It was the largest architectural gap and the requirement the build had
   most misread.
4. R6, done 2026-08-22 under its evidenceable two-declaration amendment; the accepted records keep
   the actual primary or fallback family mode visible.
5. R4, done 2026-08-23 with one protected validation cell closed and its worktree disk released;
   the offload lane remains an optimisation rather than part of the acceptance.
6. R5, done 2026-08-22.
7. C1, instrumented 2026-08-20; the measured local-lane runs are above the band rather than
   inside it, and the compartment lane's phases wait on that lane being switched back on.
8. R9, done 2026-08-23 after R4's final cell close completed the tracked proof set.
9. R10, deferred on 2026-08-21 to ship core Crosscheck sooner and resumed on 2026-08-26 for
   central Slack activation and live team acceptance.

## Standing constraints

Everything enters `main` through a pull request with green CI, and CI is verified to have run
against the head commit rather than against an earlier one.
Every pull request gets a fresh adversarial review before merge, which mutates the production call
site, proves the mutation applied, and confirms the test that should catch it is invoked.
`require_landed_code()` and `require_landed_clean()` are never weakened.
No token value is ever printed or logged; digests, paths, and expiry instants only.
