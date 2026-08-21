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

Amended by the owner on 2026-08-19: the crosscheck requirement is that no author's work is
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

Status: PARTIAL. Both lanes are code-complete pending their live acceptance runs.

Two lanes exist.
The validation-cell lane (`docs/azure-validation.md`) has never closed a cell; there is no
`azure-validation` state under `$FM_HOME/state`.
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

Work remaining: the two live acceptance runs, operator-driven after merge - one no-mistakes run
offloading a selected test class to Azure end to end, and one validation cell driven from
dispatch through `close`.

First live cell attempt, 2026-08-20 (`azv-36b2726cbcf3`, task `r4-cell-acceptance`, head
`c094cc38`, `validation-standard`): submit, dispatch, boot, review, and the full four-shard
behavior round all executed, and the run reached its test gate carrying a complete shard round
rather than the empty receipt set that used to strand every multi-attempt cell. The gate was a
genuinely red test step (host-coupled units that cannot pass inside a Linux cell: passwordless
sudo, tmux window creation, Keychain approval markers), the operator answered `approve`, and
attempt 2 then ended without an authenticated result marker. The cell took the retain lane:
compute zero, worktree disk and evidence retained, control reservation released.

That attempt exposed two blockers that stand between this lane and its acceptance sentence, and
neither is the receipts strand:

1. `respond` does not answer a gate. It reports success and starts a new attempt, but the guest
   re-publishes the byte-identical previous result: attempt 2's `result.json` matched attempt 1
   exactly (sha256 prefix `330ddea31bfbbb05` both times, `run.log` identical at 3056 bytes, same
   `run_id`, same `needs-decision`, same gate), after which the control command reported Failed.
   The runtime bundle carried no-mistakes v1.48.0, so this is not the v1.41.2-era behavior. Until
   the operator action reaches the in-cell pipeline, a parked cell can only be retained, and an
   unchanged republished result should be refused as a non-answer rather than surfacing as a
   generic failure.
2. The sealed suite is not Linux-clean, so every cell run parks. Shard 2 failed on host-coupled
   units that cannot pass inside a Linux cell (passwordless sudo, tmux window creation, Keychain
   approval markers), alongside 377 passing units. Until those units skip loudly off macOS, no
   intent reaches a green test step here.

So the receipts fix is exercised live up to the gate, which is exactly what used to be
impossible, and `close` stays unproven: the acceptance sentence below is not yet met.

Acceptance: a no-mistakes run offloads a test class to Azure and returns a real verdict; and,
separately, one validation cell reaches `close` with its worktree disk released.

## R5. All of it runs on the pi multi-profile fleet

Status: PARTIAL.

Crosscheck on the pi fleet is done at the roster level: eight pi profiles across eight distinct
upstream accounts, projected into single-profile account homes by `bin/fm-pi-account-home.py`,
with the roster repointed and read back through the real `bin/fm-crosscheck.py` reader and
policy screen. Under the second 2026-08-19 amendment this roster is now the dormant crosscheck
fallback; the pi fleet's primary duties are authors and no-mistakes.
Crewmate placement now selects across the pool. The controller chooses one free profile inside the
same lock hold and the same durable write that creates the queue entry, so selection and the lease
are one act and the queue entry IS the lease; the unit of exclusion is the UPSTREAM ACCOUNT rather
than the profile name, because two profiles can be re-logged into one account and what a crewmate
contends for belongs to the account. The chosen profile is projected with `bin/fm-pi-account-home.py`
into a controller-owned account home, and `bin/fm-spawn.sh` narrows the staged provider credential
to it, so the worker receives exactly one account rather than the pooled `auth.json`. An exhausted
pool refuses by name, listing every leased profile and the task holding it. Mechanics are owned by
`docs/azure-workers.md` ("Provider-account placement across the Pi fleet").

Proven locally against a fixture provider by `tests/fm-worker-placement.test.sh` (eight concurrent
placements racing the controller lock take eight distinct upstream accounts, read back from
`controller.json`; exhaustion refuses; a compartment child, its compartment and an ordinary crewmate
hold three distinct accounts; killing placements between selection and the durable lease orphans no
account) and end to end through the real `bin/fm-spawn.sh` by `tests/fm-spawn-cloud.test.sh`, which
asserts the staged credential is the leased single profile.

Operational consequence the owner must know: concurrent placements are now bounded by
`min(FM_AZURE_WORKER_MAX, distinct upstream accounts in the pool)`. With eight Pi accounts the
ninth concurrent placement refuses although MAX_WORKERS is 16, and compartments compete in the
same pool. Sixteen crewmates never could run on eight accounts without sharing one; they used
to do it silently. Raising the ceiling means adding profiles on distinct accounts.

Still owed for DONE: the acceptance sentence on real compute. No leg of this has run against a live
Azure worker, so "concurrent crewmates RUN on distinct pi profiles" is proven up to the credential
the worker is handed and no further; what the guest agent does with that credential is unobserved
here, and R9 (no crewmate has returned an outcome) still gates it.

Acceptance: concurrent crewmates run on distinct pi profiles with no account collision.

## R6. Crosscheck reviews outside the author's model family

Status: BUILT 2026-08-20; no GLM review has ever completed. The lane below was built and merged
(#264) and the deployment is live, but the primary reviewer is 0 for 6. Six GLM attempts are
recorded against PR #220 in the crosscheck ledger on 2026-08-20, and all six ended in
`tool-failure` with no citations and no execution proof; a seventh attempt, against PR #266, sits
in the archived ledger beside it and also failed. GLM has produced no verdict at all. The one
verdict this lane has produced came from the pi-codex fallback reviewer.

The roster was GLM-only when those attempts ran. As of 2026-08-20 it is not: the operator restored
the pi-codex fallback entries alongside GLM with `config/crosscheck-same-model` on, the sanctioned
degraded mode while GLM cannot finish a review, so crosscheck can return verdicts again. It returns
them from the fallback, which means codex-authored work is being reviewed by its own family again
for the duration, exactly the degradation this requirement exists to remove.

The deployment carries two per-minute limits, not one: 25,000 tokens and 25 requests (`FW-GLM-5.2`,
DataZoneStandard, capacity 25). The 429 body names neither, reading only that requests to
`FW-GLM-5.2` in eastus have "exceeded rate limit". Attributing the blocker to the token-per-minute
limit specifically is therefore inference rather than measurement. Raising either is an owner
action in the Foundry portal; the Microsoft.Quota API does not cover Cognitive Services.

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
author fleet consume. The pi-codex roster (which R5 records as proven at the roster level while
R9 still owes the live proof) is retained as a dormant fallback behind a config flip, never
deleted; every review must name the lane that produced it, and a status read must show whether
GLM is serving or the fallback is active, so a silent fallback is impossible.
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
  records. This run is still the only verdict this requirement's lane has produced.

Still owed, and honestly so:

- The live end-to-end GLM review. The six attempts did not all die of the quota, and the record
  should not be read as if they did. Attempts 0 and 1 (05:54Z) died before reaching the provider
  at all, on a local harness fault in an operator-authored instrumentation shim whose `/dev/fd`
  redirect was refused under the reviewer sandbox. Attempts 2, 3 and 4 (05:55Z to 05:59Z) each
  recorded only `Pi reviewer emitted a turn after agent completion`, the parser defect #268 then
  fixed (pi continues a retried attempt after `agent_end` via `auto_retry_start`, and the stream
  parser read that continuation as a turn after completion, masking whatever the provider had
  actually returned). Because the parser masked it, no retained artifact records what killed those
  three. Attempt 6 (06:25Z), two minutes after #268 landed, is the only review run anywhere that
  records an actual 429. The remaining ledger slot, index 5 at 06:08Z, is not a GLM run at all: it
  is the pi-codex fallback demonstration. What is measured rather than inferred is the traffic
  shape: in the deployment's metrics the 06:00Z hour shows 35 model requests and 23 client errors.
  One real GLM review end to end closes this item, and the quota is the leading suspect for what
  stands in the way, not an established cause.
- The startup-credit decrement check. Deployment metrics for `aif-fm7c799d-eus01` record 727,136
  tokens on 2026-08-20: 515,965 in the 04:00Z hour, 135,911 in 05:00Z, 75,260 in 06:00Z. (An
  earlier draft of this section reported roughly 510K for the day; that was the 04:00Z hour alone.)
  Cost Management shows no charge against the resource yet. That absence carries no information
  either way at this range: C3 records that Cost Management actual lags hours, which is why its
  own bound is a backstop on recorded spend. This needs the portal's cost view.
- The Azure-compartment GLM lane, which is switched off rather than unbuildable. The serving lane
  today is the local pi reviewer. The reason recorded here previously, that the `fm-ccm` image
  carries no `pi` binary and needs a rebake, is stale and is corrected below.
- A spend signal for the new primary reviewer. The GLM provider entry declares `cost` as zeros for
  `input`, `output`, `cacheRead` and `cacheWrite` (`tests/fm-crosscheck.test.sh:1046`), so a GLM
  review prices at zero and the crosscheck ledger records no per-review cost for it. That is the
  same ledger R10's `daily_budget_usd` waits on, and the reason it does not bind today. It leaves
  C3's daily bound as the only guard over this lane's spend, and C3's own caveat is that the bound
  is a backstop on Cost-Management-recorded spend rather than a real-time meter.
- Three items from the Work list above that neither landed nor were separately tracked. The status
  command that answers whether GLM is serving or the fallback is active does not exist:
  `bin/fm-crosscheck.py` exposes `run`, `verify` and `merge` and nothing else. This one is
  substantive rather than cosmetic, because the stated reason for it was that a silent fallback
  must be impossible, and the fallback is active right now. Second, that pi tolerates
  `reasoning_content` in streamed deltas was never verified; the string appears nowhere in the
  repository outside this document. Third, review guards sized to the model's context window at
  deploy time: the generic guards pre-exist, and the one size that exists, `MAX_PROMPT_BYTES` in
  `bin/fm-crosscheck-azure.py`, was set in #130 on 2026-08-13 and was not revisited for a
  1M-token model.

Correcting the Azure-compartment blocker, 2026-08-20: the current `fm-ccm` image does carry `pi`,
and the lane is off because it was switched off. `$FM_HOME/config/crosscheck-azure.json` has
`"enabled": false`, set by an operator on 2026-08-20; that switch, not the image, is why no
compartment review runs today. The image claim was already stale when it was written: it entered
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
at a HEAD already landed on public main. What remains genuinely unproven is a pi review completing
on this image, which is what R9 records; the binary's presence and a working lane are separate
claims. `docs/azure-crosscheck.md`, where the sentence originated, is corrected in the same change,
as are the claims C1 had built on it.

Acceptance: a codex-authored change and a claude-authored change are each reviewed by a
GLM-backed reviewer with bound reviewer identity and the same evidence discipline as the codex
lane; the fallback flip to pi-codex is demonstrated once, its activation is visible in the review
evidence and the status read, and the demonstration records the degraded same-family mode it
accepts for codex-authored work.

## R7. Everything is logged in

Status: HOLDS, through R8.

The eight pi profiles renew on their own now, which is R8.
Two of the three profiles in `~/.local/share/agent-fleet/accounts/claude/` hold blanked,
length-zero tokens; the third is `refreshable` with material declared valid to 2026-09-10.
None of the three is needed for R6 anymore: the GLM lane authenticates with a Foundry
deployment key and reviews all authors, so R7 holds with no owner login outstanding.

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

## R10. Crosscheck is exposed to team engineers through Slack

Status: BUILT, ready-to-flip; awaiting the three owner inputs (the Slack app's
two tokens, the GitHub read credential, and the metering numbers). Directed
by the owner 2026-08-19; builds after R6. The lane is
`bin/fm-crosscheck-slack.sh` and its owning document is
`docs/crosscheck-slack.md`; a missing token environment variable refuses
startup naming the exact variable, so flipping it on is supplying tokens, not
changing code. Live acceptance still requires those inputs and an engineer
other than the owner.

What DK must click: create a Slack app in the workspace with Socket Mode on;
mint the app-level token with `connections:write` and the bot token with
`app_mentions:read`, `chat:write`, `channels:history`, and `reactions:write`;
subscribe it to the `app_mention` event, install it, and invite the bot to the
channel(s) going into `channel_allowlist`; mint a read-only GitHub credential
scoped to the allowlisted repositories; export the three values under the
environment variable names in `$FM_HOME/config/crosscheck-slack.json`; and
pick the two metering numbers: `daily_request_cap` (the control that binds
today, counting each submitter's started reviews per day) and
`daily_budget_usd` (the USD bound, which binds only once the crosscheck
ledger records per-review cost; today it does not). Null for either stays
unmetered pass-through, still ledgered. Details and the run recipe:
`docs/crosscheck-slack.md`.

The owner's v1 shape: an engineer tags the crosscheck bot in a Slack channel with a pull request
link; the GLM lane reviews it; the bot posts the findings as a thread reply on the engineer's
own message. No engineer wires up a harness or touches an endpoint, and the same path works for
deliberate on-demand use. Cursor Bugbot continues to run for engineers' pull requests (it stays
disabled on the owner's), so this lane complements rather than replaces it.

Constraints the build must honor:

- The listener uses Slack Socket Mode, so no public inbound endpoint is added to the private
  lane posture. It is a resident process; where it runs is decided at build time and its
  standing cost is recorded under C3.
- v1 accepts pull request links only, and only for repositories in the organization allowlist.
  The bot's repository read credential must never be pointed at a repository outside that
  allowlist, because a review pulls untrusted content into a credentialed context.
- Every thread reply names the lane that produced it (GLM, or the pi-codex fallback), the same
  visibility R6 requires, so engineers and the owner can always see what is serving.
- Team usage is metered per submitter under a daily cost bound (C3); when the bound is reached
  the bot says so in the thread instead of silently dropping the request.

Acceptance: an engineer other than the owner tags the bot with a pull request link and receives
threaded findings produced by the GLM lane, with the lane named in the reply, the request
metered, and an out-of-allowlist link refused with a clear message.

## C1. Crosscheck completes in 20 to 30 minutes

Status: INSTRUMENTED 2026-08-20; the one measured serving-lane review is FASTER than the band, not
inside it, and the compartment lane's phase numbers remain unmeasured because that lane is switched
off.

What was measured, and what is inference.

**The 75 minutes has never been broken down.**
That figure is the owner's stated premise of 2026-08-18 (see the requirement at the top of this
document), not a measurement recorded anywhere in this repository; nothing in the repo records its
provenance. Treat the 75 minutes as the target this requirement was written against, not as
evidence.
An earlier version of this paragraph also argued the figure could not have come from a compartment
run on or after 2026-08-16, on the grounds that `docs/azure-crosscheck.md` recorded the lane as
non-executable for want of a `pi` binary. That premise was false and has been corrected in that
document: the current `fm-ccm` image does carry `pi`, and the lane is off because
`$FM_HOME/config/crosscheck-azure.json` carries `"enabled": false`. The date argument is therefore
withdrawn rather than restated; what stands is that no compartment timing is recorded anywhere.

Inference, clearly labeled as such: the compartment lane is the only plausible owner of a duration
that large, because it is the only lane that creates a model VM, stages a credential archive and
request into blob storage, boots a Managed Run Command, and collects a digest-bound result. That
reasoning is from the shape of the code, not from a timing. It is not proof, and this build has not
turned it into proof, because the lane it would have to measure is switched off rather than run.
Unlike the earlier reading, that is a reversible condition: switching the lane on and taking one
compartment review would settle it. Four parallel lanes
(`FM_AZURE_CROSSCHECK_LANES`, default 4) always bounded concurrency, never one review's clock.

What is fact rather than inference is that the serving lane changed: R6 made GLM-5.2 the sole
primary reviewer running through the LOCAL pi lane, so today's serving path performs no create,
boot, stage, or collect at all, and the compartment lane is disabled in the operator home. It is
disabled by `"enabled": false` in `$FM_HOME/config/crosscheck-azure.json`, which does exist and
also names a current `model_image_id`; it is neither absent nor waiting on an image. Whether
that change is what moved the duration is again inference; none of the three candidate levers this
requirement listed (warm reviewer VMs, a faster SKU, more lanes) was tried, so none of them was
ruled out by measurement either.

One local-lane review has been measured end to end: 6m13s on 2026-08-20, pi-codex fallback family,
PR #220, verdict clear. That was an external wall-clock observation of the invocation taken before
this instrumentation landed, so it carries no recorded phase breakdown of its own. It is one run,
not a distribution, and a GLM-5.2 primary review is a different reviewer from the pi-codex fallback
that served it. It is the only crosscheck duration this repository can point to.

What is now instrumented.

Every crosscheck run record carries `durations_ms`, integer milliseconds on `time.monotonic()`,
covering `snapshot`, `reviewer`, `proofs`, `ledger`, and `total` for the local lane, plus `create`,
`stage`, `boot`, and `collect` recorded only when the compartment lane performed them. A phase is
present only if the run entered it, so an absent phase means the lane did not do that work rather
than that the work was free. Phases never nest, named phases round down and `total` rounds up, so
`total >= sum(named phases)` holds exactly and the difference is real unattributed time. The
readable report and the run's own output name the total and the largest phases on one line, and
`bin/fm-crosscheck.sh timings <task-id>` prints the full per-run table read-only, taking no lock.
The field is additive: a run recorded before it existed still validates and renders, showing `-`
rather than a fabricated zero. Contracts live in `docs/crosscheck.md` and `docs/azure-crosscheck.md`.

Acceptance: a measured review completes in 20 to 30 minutes, with the breakdown recorded.

Honest reading against that acceptance. Taken literally, the acceptance is not met: 6m13s is
FASTER than the 20-to-30-minute band, not inside it, and no live review has yet been recorded
through the instrumentation, because the one measured review predates it. Read as the outcome the
band was standing in for - a review that is not about 75 minutes - the duration side is satisfied
by that single run, and the breakdown side is landed and proven hermetically, with the next live
crosscheck run recording its own. Both readings are stated because the difference decides whether
this is DONE, and that call belongs to the owner rather than to this section.

The compartment lane's create, boot, stage, and collect numbers are unmeasured, because that lane
is switched off; they are not unmeasurable, and the earlier claim that they were, pending an image
rebake, rested on a premise that has since been refuted. This section does not claim that lane is
fixed. If the compartment lane is ever restored to serving,
C1 has to be re-measured against it, and the three original candidate levers become live again at
that point.

The contradiction this section previously flagged is resolved: R6's status line no longer reads
NOT DONE. Note the correction that came with it, since this section leans on R6's serving lane:
GLM is the primary reviewer on paper but has never completed a review, so the lane that actually
served the one measured run, and that serves reviews today, is the pi-codex fallback.

## C2. Many crewmates, no-mistakes, and crosschecks run in parallel without contention

Status: NOT DONE.

All three C2 changes are landed: the transactional apply, the per-slot `pending_actions` map
with its load fence and revision CAS, and the lock discipline that runs every provider mutation
outside the fleet lock under a non-blocking per-slot lease, with the drain after convergence and
`abandon-claim` as the evidence-preserving exit from a deterministically refused claim.
What remains for DONE is the acceptance itself: many crewmates, no-mistakes runs, and
crosschecks demonstrated running in parallel against live capacity without contention.

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

Status: BUILT 2026-08-20; live acceptance pending.

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

R10 metering and standing-cost booking: the Slack listener runs on the operator mac in v1, so
its standing Azure cost is approximately zero; its per-submitter daily request ledger lives
under `$FM_HOME/state/crosscheck-slack`, with `daily_request_cap` binding today and
`daily_budget_usd` binding once that ledger records per-review cost.

Acceptance: a day cannot cross the bound without an explicit operator override, and a worker
whose task ended deallocates unattended.
The hermetic legs are covered in `tests/fm-worker-lifecycle.test.sh`; the live demonstration on
billable capacity has not run yet.

## Order of work

1. R8, done 2026-08-19.
2. C2, because contention blocks demonstrating anything at scale. One of its three changes landed.
3. R2/R3, the largest architectural gap and the requirement most misread by the current build.
4. R6, whose direction is decided (GLM-5.2 on the Fireworks Foundry lane) and which no longer
   needs an owner login.
5. R4, which needs the runner caller built and one validation cell closed.
6. R5.
7. C1, instrumented 2026-08-20; the one measured serving-lane review is faster than the band rather
   than inside it, and the compartment lane's phases wait on that lane being switched back on.
8. R9, which is the proof of the rest.
9. R10, the Slack team exposure, which needs R6's lane and can be pulled forward right after R6
   if the owner wants engineers on it sooner.

## Standing constraints

Everything enters `main` through a pull request with green CI, and CI is verified to have run
against the head commit rather than against an earlier one.
Every pull request gets a fresh adversarial review before merge, which mutates the production call
site, proves the mutation applied, and confirms the test that should catch it is invoked.
`require_landed_code()` and `require_landed_clean()` are never weakened.
No token value is ever printed or logged; digests, paths, and expiry instants only.
