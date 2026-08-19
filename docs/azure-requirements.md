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

Amended by the owner on 2026-08-19: the crosscheck requirement is model-family bidirectionality,
not the literal codex/claude pairing quoted above. The second reviewer family is Kimi-K2.7-Code
on Azure AI Foundry, reviewing codex-authored work; claude-authored work keeps the codex
crosscheck. pi-anthropic was rejected the same day (API pricing), as was an interim same-day
Claude-Code-CLI-subscription direction. Details and work in R6.

## R1. Crewmates run in Azure

Status: DONE.

`config/spawn-cloud=azure` is set and accepted by `bin/fm-spawn.sh`'s own parser, and a crewmate
has been created, staged, and executed in Azure with exit 0.
No crewmate has returned an outcome, which is R9 rather than a residual of this item.
Placement is still single-profile; multi-profile placement is R5.

## R2/R3. Secondmates run in Azure, and can spawn crewmates in Azure

Status: NOT DONE, and the current build refuses it.

`docs/azure-workers.md` states that a worker never runs Firstmate, a secondmate, another
supervisor, or a nested team, and `bin/fm-spawn.sh` states that secondmate and account-recovery
spawns always stay local.

The fear behind that rule is sound: a worker must not be able to create unbounded child compute.
It was written as a blanket refusal of the requested architecture rather than as a bound on child
compute, and that is the defect.

The correction is a secondmate compartment class distinct from the crewmate worker.
It runs a secondmate in Azure, and its child spawns go through the local controller's durable
queue: the secondmate enqueues a worker request and the controller reconciles and creates it.
No child-worker launcher exists on the worker, and the requested hierarchy still works, with
firstmate spawning secondmates in Azure and those secondmates obtaining crewmates in Azure.

Work: a new compartment role and lifecycle class; endpoint and steering reachability for a
compartment that outlives one task; a guest-to-controller request path; cost and capacity
accounting for that longer life; and a rewrite of the two statements above.

Acceptance: a secondmate running on an Azure worker requests a crewmate worker, the controller
creates it, the crewmate completes a task, and both release cleanly.

## R4. no-mistakes runs on Azure

Status: PARTIAL, and neither lane functions today.

Two lanes exist.
The validation-cell lane (`docs/azure-validation.md`) has never closed a cell; there is no
`azure-validation` state under `$FM_HOME/state`.
A stranding strand was fixed: a passed run carrying a short receipt set is now demoted to failed
so the cell collects and retains legibly.
That buys legibility, not closing, and the root cause (an in-cell bridge producing no receipts) is
untouched, so a demoted cell still cannot `close`.
One stranded work disk is on the subscription today.
The runner-offload lane (`FM_AZURE_RUNNER_REMOTE_CLASSES`) has no caller: nothing in the
repository sets `FM_AZURE_RUNNER_TASK`, `FM_AZURE_RUNNER_GENERATION`, or
`FM_AZURE_RUNNER_CONFIRM_SUBSCRIPTION`, and the placeholders in `docs/azure-runner.md` are an
operator recipe rather than a caller.
Selecting the `test` class therefore routes every non-Herdr test to Azure and keeps only the
Herdr lifecycle scripts local; with no caller supplying the bindings the dispatch fails, so those
non-Herdr tests run nowhere and the step exits 1.
There is no automatic fallback to the host, and `FM_AZURE_RUNNER_LOCAL_RECOVERY_CLASSES` is the
explicit operator opt-out that restores the full local run.

Work: build the caller that derives the per-run bindings from the ambient no-mistakes run, then
drive one validation cell from dispatch to close.

Acceptance: a no-mistakes run offloads a test class to Azure and returns a real verdict; and,
separately, one validation cell reaches `close` with its worktree disk released.

## R5. All of it runs on the pi multi-profile fleet

Status: PARTIAL.

Crosscheck is done: eight pi profiles across eight distinct upstream accounts, projected into
single-profile account homes by `bin/fm-pi-account-home.py`, with the roster repointed and read
back through the real `bin/fm-crosscheck.py` reader and policy screen.
Crewmate placement is not wired: the cell image carries pi, but placement does not select across
the eight profiles.

Work: multi-profile account selection for crewmate and worker placement, reusing the projection
tool and the account-lease identity already present in the worker request path.

Acceptance: concurrent crewmates run on distinct pi profiles with no account collision.

## R6. Crosscheck is bidirectional across model families

Status: NOT DONE. Direction decided by the owner 2026-08-19 (see the amendment above).

The requirement is that no author's work is reviewed only by its own model family.
The roster was instead made eight reviewers all on `openai-codex`, by reading "just use the same
pi fleet" as a restriction to one provider.
It was not one, and that is the defect.

The provider question was settled on 2026-08-19.
pi-anthropic is dead twice over: pi's anthropic OAuth authenticates as its own client against its
own token endpoint, so a Claude CLI refresh token cannot be spent by pi, and a fresh pi-anthropic
login would bill at API pricing, which the owner rejected.
An interim directive the same day routed claude reviews through the Claude Code CLI on the
owner's subscription profile; the standing decision superseded it: the second reviewer family is
Kimi-K2.7-Code on Azure AI Foundry (Direct-from-Azure lane; at decision time deployable Global
Standard from eastus with tool calling and published pay-per-token pricing - re-verify at deploy
time), chosen for tool calling, the Microsoft-hosted custody lane, and lineage independent of
both OpenAI and Anthropic.
Codex-authored work is reviewed by a Kimi-backed reviewer; claude-authored work keeps the codex
crosscheck, which R5 records as proven at the roster level while R9 still owes the live proof.
The model pick is explicitly provisional: reevaluate after live review data (GLM-5.2 was the
runner-up; the comparison is in the owner's evidence folder,
R6-FOUNDRY-RESEARCH-2026-08-19.md).

No owner login is needed anymore: the Kimi lane authenticates with a Foundry deployment and an
api-key, not a subscription session.
The Kimi credential is an api-key, not a pi OAuth slot, so the literal `openai-codex` slot key in
`bin/fm-pi-account-home.py`, `bin/fm-crosscheck.py` (`inspect_pi_credential`,
`account_identity`), and the Azure credential archive in `bin/fm-crosscheck-azure.py` stays as it
is - those three still refuse any non-codex pi OAuth slot, which no longer blocks R6 and remains
the recorded constraint if a second pi OAuth provider is ever added.
The identity question those tools answered with `accountId` still needs an answer for an api-key
credential: reviewer identity for the Kimi lane must bind the Foundry resource and deployment,
since an api-key carries no account identity of its own.

Work: deploy `Kimi-K2.7-Code` in a Foundry resource and store the key in the fleet's secret
custody, never in the repo; a pi custom provider entry (`models.json` `baseUrl` +
`openai-completions` api) pointing at the resource's OpenAI-compatible `/openai/v1` endpoint
with the deployment name as the model id; verify pi tolerates `reasoning_content` in streamed
deltas before rollout; extend `bin/fm-crosscheck.py` `allowed_profiles` and roster validation to
carry the Kimi lane (today they pin pi to `("pi", "gpt-5.6-sol", "xhigh")` and would refuse it)
with `config/crosscheck-same-model` off; extend the `bin/fm-crosscheck-azure.py` endpoint
allowlist and credential archive for the Foundry host and api-key shape; define reviewer
identity for api-key credentials as above; retire or re-point the interim claude reviewer
artifacts (the `("claude", "claude-opus-5", "xhigh")` `allowed_profiles` entry, the
`api.anthropic.com` allowlist entry, and the claude-profile boot copy described in
`docs/azure-crosscheck.md`); review guards sized to the model's context window at deploy time: a
strict findings schema, path-existence validation before filing, and a per-review context cap;
and routing so codex-authored changes draw the Kimi reviewer while claude-authored changes draw
codex reviewers.

Acceptance: a codex-authored change is reviewed by a Kimi-backed reviewer and a claude-authored
change by a codex-backed reviewer, on distinct credentials with bound reviewer identities, with
the same evidence discipline as the codex lane.

## R7. Everything is logged in

Status: HOLDS, through R8.

The eight pi profiles renew on their own now, which is R8.
Two of the three profiles in `~/.local/share/agent-fleet/accounts/claude/` hold blanked,
length-zero tokens; the third is `refreshable` with material declared valid to 2026-09-10.
None of the three is needed for R6 anymore: the Kimi lane authenticates with a Foundry
deployment key, and claude-authored work is reviewed by the codex fleet, so R7 holds with no
owner login outstanding.

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

Status: NOT DONE.

Unproven today: the worker landing path; any validation cell closing; any pi review on the current
model image; and secondmate-in-Azure, which is blocked on R2/R3.

The landing path is not synthetically exercisable, and that is correct behavior rather than a gap
to route around.
`--outcome-dir` requires full staging, and `request` derives every binding from
`$FM_HOME/state/<task>.meta`, with caller-supplied bindings refused outside the hermetic test
backstop.
The existing smoke assignments cannot be reused because their `repository_generation` is not a
commit that exists.
Proving it requires a real spawned crewmate task that commits.

## C1. Crosscheck completes in 20 to 30 minutes

Status: NOT ADDRESSED.

Four parallel lanes (`FM_AZURE_CROSSCHECK_LANES`, default 4) predate this work and nothing about
duration has changed.
The 75 minutes has never been broken down.

Work: instrument create, boot, stage, review, and collect, then pull the lever the measurement
identifies.
Candidates are reviewer VMs that already exist rather than a cold create per review, a faster SKU,
or more lanes, and the choice waits on the measurement.

Acceptance: a measured review completes in 20 to 30 minutes, with the breakdown recorded.

## C2. Many crewmates, no-mistakes, and crosschecks run in parallel without contention

Status: NOT DONE.

The controller holds a single `pending_action`, so every provider mutation serializes.
That is the direct blocker on this requirement.

The lock is the other half, and the harder one: `controller_lock` is held across provider calls
and for an execute's whole guest run, and the code's own note records that fixing only the lock was
tried and reverted.

Work: per-assignment pending state, so reconcile drives many workers concurrently, with
idempotency preserved per action rather than globally, and a lock discipline that puts the provider
call outside the fleet lock.
The first of three changes landed on 2026-08-19: a provider mutation now applies into a copy,
commits only on success, and is refused if its effects reach outside the one compartment its slot
owns.
Two remain: the per-slot pending map with a revision fence, still fully serialized; then the lock
discipline, which has to ship as one change because a half-serialized controller is worse than
either end state.

One thing not to do, found while designing this: the three capacity commands stay fully locked.
`merged_specialized_reservations` ignores local reservations whose status is not `reserved`, so a
candidate parked by one concurrent reserve is invisible to another's admission arithmetic and two
of them can each admit against a budget that fits one.

Acceptance: several crewmates, a no-mistakes offload, and a crosscheck run concurrently without
the controller serializing them.

## C3. Cost guard

Status: NOT DONE.

The requirement is that a day's spend cannot quietly reach 100 dollars.
The only bound that exists is `FM_AZURE_WORKER_COMMISSIONING_CEILING_USD`, which is cumulative
rather than daily, so nothing today refuses a single expensive day.

Workers also do not deallocate on idle.
Compute is released only when an exact release receipt is followed by a controller `reconcile`,
and the sole self-acting bound is a per-VM shutdown schedule at a wall-clock deadline.
Four worker slots are assigned with no release proof, one of their VMs is running with no live
task, and one validation work disk is unattached and stranded.

Work: a daily spend bound that refuses a mutation once the day's spend crosses it, and an idle
release path so an assigned worker whose task ended returns its compute without a human.

Acceptance: a day cannot cross the bound without an explicit operator override, and a worker whose
task ended releases and deallocates unattended.

## Order of work

1. R8, done 2026-08-19.
2. C2, because contention blocks demonstrating anything at scale. One of its three changes landed.
3. R2/R3, the largest architectural gap and the requirement most misread by the current build.
4. R6, whose direction is decided (Kimi-K2.7-Code on Foundry) and which no longer needs an owner login.
5. R4, which needs the runner caller built and one validation cell closed.
6. R5.
7. C1, measured before it is changed.
8. R9, which is the proof of the rest.

## Standing constraints

Everything enters `main` through a pull request with green CI, and CI is verified to have run
against the head commit rather than against an earlier one.
Every pull request gets a fresh adversarial review before merge, which mutates the production call
site, proves the mutation applied, and confirms the test that should catch it is invoked.
`require_landed_code()` and `require_landed_clean()` are never weakened.
No token value is ever printed or logged; digests, paths, and expiry instants only.
