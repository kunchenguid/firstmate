# Process-to-event runner verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence for the runner's active guarantees.
`docs/configuration.md` owns the operating contract, each script's header and `--help` own its mechanics, and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

Every Lavish measurement here is scoped to `lavish-axi` 0.1.45, the latest published release on 2026-08-04 (`npm view lavish-axi dist-tags`).
Each Lavish section below was re-run against that exact version on 2026-08-04 on macOS (Darwin 25.5.0 arm64) with GNU Bash 3.2.57.
The evidence names the version rather than "the installed build" on purpose: a machine's globally installed `lavish-axi` drifts, so evidence scoped to whatever happened to be installed cannot be re-checked later.
Reproduce it by pinning that published version into a scratch prefix (`npm install --prefix <dir> lavish-axi@0.1.45`) and pointing `LAVISH_AXI_PORT` and `LAVISH_AXI_STATE_DIR` at an isolated server, which also keeps the runs off any live review session.

## The published Lavish poll interface the adapter wraps

Verified against that pinned 0.1.45 install:

```sh
$ lavish-axi --version
0.1.45
$ lavish-axi poll --help | head -1
Usage: lavish-axi poll <html-file> [--agent-reply "..."]
```

The same help states that the command "long-polls indefinitely".
The adapter therefore registers the plain blocking form with no timeout flag, so a completion is a real server-side event rather than a timer expiry.

This build exposes no capabilities command and no multiplexed or subscription endpoint:

```sh
$ lavish-axi capabilities --json
error: Lavish Editor expects an HTML file
code: VALIDATION_ERROR   # exit 2
```

Exit 2 with `VALIDATION_ERROR` is positive proof the subcommand does not exist, because the word is parsed as a filename.
Note that `lavish-axi <anything> --help` exits 0 for any argument, including a nonsense subcommand, so a `--help` exit code can never be used as a capability probe.

The adapter depends on none of this: it uses only the published poll shape above.

## Why an ended Lavish review is terminal

The published poll help states the lifecycle directly:

```text
$ lavish-axi poll --help | tr '.' '\n' | grep -F 'Send & End'
 `Send & End` ends the session
$ lavish-axi poll --help | tr '.' '\n' | grep -F 'polling stops'
 After that response, polling stops, and the agent must not reopen the session uninvited
```

The sentence between those two, in the same help text, is "Its final feedback is still delivered once."

So the last useful response of an ended review is a `feedback` response, and every poll after it returns an empty ended session immediately.
That is why the adapter's terminal verdict covers a `feedback` response carrying `session_ended`, not only `status: ended` and a missing session: without it, one human `Send & End` leaves the source armed and each later cycle captures another empty ended result.
`session_ended` is a session-level field emitted beside `status` in the response's leading `session:` block, which is why the adapter reads it there and ignores identical text appearing in prompt payloads.

## The loss limitation this runner cannot close

The published poll clears feedback destructively before returning it.
Measured at the protocol layer by queueing one prompt into a live session, then consuming and discarding the response:

```text
POST prompts http=200
state.json before: status= feedback pending= 1 prompts= [{... "text":"loss-limitation probe"}]
consuming read http=200
state.json after:  status= open pending= 0 prompts= [] chat= []
```

Nothing remains on the source side to re-read, and there is no acknowledgement, cursor, or replay surface to reserve against.
A result lost after that clearing and before the runner reads the child's output is therefore unrecoverable.

**Consequence for wording:** the runner may describe only its own durability boundary.
Never at-least-once, no-loss, or lossless.

## Lavish arm live-owner confirmation

The executable regression drives a stand-in using the exact published `lavish-axi poll <html-file>` argv shape above.
It starts with a registration and no owner, invokes the public Lavish `arm`, and accepts success only after the stand-in listener has started and the exact source reports `owner=live` through the public list command.
It repeats arm against that listener to prove one process and one registration generation, forces startup to exit before a durable wait to prove a nonzero diagnostic, and then proves ordinary `reconcile` recovers that same retained source.

Liveness is confirmed only once it has held for an unbroken settle window, because the published poll does not answer instantly.
A listener talking to a session that has already ended looks alive for as long as it takes the source to answer, so a confirmation shorter than that latency reports the handoff ready and only then watches the source retire itself.
Measured on 0.1.45, `lavish-axi poll` on an artifact with no session returns `NOT_FOUND` after 1.12s, 1.12s, and 1.13s, and an ended session answers after 1.23s, 1.13s, and 1.12s.
`FM_PROCEVENT_LIVE_SETTLE_SECONDS` therefore defaults to 2 seconds of live ownership, inside the `FM_PROCEVENT_LIVE_CONFIRM_TIMEOUT` bound that defaults to 8.
Driven end-to-end against 0.1.45, a session the agent had ended fails in 3 of 3 attempts naming the ended target - 4.44s, 5.58s, and 4.91s - each attempt still capturing and retiring its own terminal result, and an artifact that never had a session fails the same way:

```text
$ bin/fm-procevent-lavish.sh arm .../work/never-opened.html   # exit=1 elapsed=3.47s
registered: lavish-8c92c83d970fa869 (lavish)
error: the Lavish session for /private/.../never-opened.html ended or was missing before a live listener was established, so it cannot accept feedback and this handoff did not arm: lavish-8c92c83d970fa869
$ bin/fm-procevent.sh list
no sources registered
```

A real open review still arms on the same path: `arm` returns `armed:` with `owner=live` after 4.24s, an identical repeat converges after 3.79s on that one listener process, and ending the session yields exactly one captured result and automatic retirement.
Reopening that same artifact and arming it again succeeds on the reopened session's own live listener after 4.52s, with four terminal results from earlier ended reviews already captured under the same canonical id, so the attempt baseline holds against the real CLI and not only against stand-ins.
The executable coverage holds both halves at that timing: stand-ins that answer ended after 1.4s and missing after 1.2s must fail, and a healthy listener is reported ready only after the whole settle window.

The window bounds latency; it does not prove the target can answer, and the measured margin is under a second.
On a host loaded to a 68 load average the same missing-session verdict took longer than the settle window - measured at 2.42s, 2.71s, and once 10.67s - and 1 arm of 3 then printed `armed:` for an artifact that never had a session, with the source retiring itself moments later.
At load averages of 47-56, where that verdict stayed at 1.3s, 15 of 15 arms of a missing session failed correctly with the target-session diagnostic.
So the default holds while the target answers inside the settle window, and a saturated host is exactly where it does not.
Raising `FM_PROCEVENT_LIVE_SETTLE_SECONDS` past the worst verdict latency a host actually shows is the operator-side lever for that case.

A session that already ended is covered as its own end-user case, because it cannot accept the feedback the handoff waits for.
Against a stand-in that returns an ended session at once, `arm` fails and names the target session as what ended, never firstmate's own state, while that terminal result is still captured once, announced once, and left retired.
The same distinction is proved directly on the runner's public `await-live`: exit 3 for a source its adapter classified terminal - whether its registration is already gone or its terminal retirement is still pending - and the separate missing-registration diagnostic for a source that was never registered.
That ended verdict is proved to be scoped to the attempt reporting it.
Arming the same artifact again once its review is reopened succeeds on its own listener with `owner=live`, and on the runner's own boundary a registration that disappears during confirmation reports the missing registration rather than an ending when the only terminal result predates that attempt's baseline, while the identical state with a baseline of 0 still reports the ending.
The bound is proved to be elapsed time by holding the per-source boundary from another process while the confirmation runs: it returns nonzero with a concrete diagnostic and its registration intact instead of waiting out the holder.
Measured directly against a holder that kept that boundary for 30 seconds:

```text
timeout=1s rc=1 elapsed=1.51s
timeout=5s rc=1 elapsed=5.95s
```

The overshoot is the one-second resolution of the configured unit plus process startup, never the holder.

```text
$ tests/fm-procevent.test.sh
...
ok - failed terminal retirement is fail-closed and idempotently recoverable
ok - Lavish arm reports success only after the exact source listener is live, and repeated arm stays idempotent
ok - failed Lavish listener startup is reported and the durable source recovers through reconcile
ok - Lavish arm fails with a target-session diagnostic when that session already ended, and still arms the same artifact once it is reopened
ok - a target session that answers ended or missing at real listener latency is still a diagnosed arm failure
ok - await-live distinguishes a source that ended terminally from a registration that is not there
ok - the ended verdict is backed by a result newer than the baseline taken for this attempt
ok - the liveness confirmation bound is elapsed time that a held source boundary cannot stretch
ok - liveness is confirmed only after the exact source holds live ownership for the whole settle window
...
all procevent tests passed
```

## What the runner does prove

Exercised by `tests/fm-procevent.test.sh` against a fake blocking source whose completion is a process event, not a timer, and - for the two supervision-delivery rows below - by `tests/fm-watch-triage.test.sh` driving a real `bin/fm-watch.sh` over a real capture:

| Guarantee | How it is proven |
| --- | --- |
| capture before publication | the captured result exists at `0600` and its event names its committed sequence only afterward |
| proactive delivery of a captured result | a real capture into an isolated home queues its `check` record, and a healthy watcher with a fresh beacon then exits reporting that queued result as an actionable check, before any manual drain |
| single delivery per source and sequence | after that first proactive wake, a still-unhandled result keeps being re-announced onto the durable queue but never wakes the watcher again; once existing records are drained and the result is acknowledged, it is neither re-announced nor reported |
| proactive-delivery crash and drain boundaries | dotted and underscored source ids at the same sequence receive distinct markers; a concurrent drain cannot consume between queue revalidation and marker commit; failed output, failed marker commit, and a crash before marker commit leave replay available, while successful output still ends the actionable cycle and a crash after marker commit suppresses a duplicate |
| adapter-owned terminal verdict | two fixture adapters - one that ends on any result, one with no terminal knowledge - decide the outcome alone: the first has its registration and claim retired automatically after one capture and is never restarted, the second stays armed |
| terminal retirement preserves the result | the retired source's captured output, its announced event, its handled acknowledgement, and later explicit `retire` all still behave normally |
| registration-generation retirement | an old terminal runner preserves a concurrently replaced registration and releases ownership so the replacement runs independently; injected registration-removal failure retains a terminal claim, reports that claim as `terminal` through both `list` and the liveness confirmation, performs no second poll, and completes idempotently once removal recovers |
| one `Send & End`, one result | an armed Lavish source driven against a stand-in for the published poll, which delivers the final `session_ended` feedback once and empty ended sessions afterward, polls exactly once, captures exactly one result, publishes one distinct event, and retires itself |
| live Lavish arm handoff | the public arm command starts the exact source through ordinary reconciliation, withholds success until the listener is invoked and ownership is stably live, converges an identical repeat on one owner and registration generation, returns nonzero when startup cannot hold liveness, and leaves that failed registration recoverable by ordinary reconciliation |
| an ended target session is a diagnosed arm failure | a stand-in session that has already ended makes the public arm command fail naming the ended target rather than missing firstmate state, polls exactly once, and still captures, announces, and retires that one terminal result; the runner's own `await-live` reports it as exit 3 whether retirement finished or is still pending, and keeps a separate diagnostic for a registration that is simply not there |
| that failure holds at real verdict latency | stand-ins that answer ended after 1.4s and missing after 1.2s - at or above the verdict latencies measured on 0.1.45 - still fail the public arm command with the target-session diagnostic, capture their one terminal result, announce it, and retire, so a listener that is merely alive while its session is already gone is never reported ready |
| readiness requires an unbroken settle window | the public arm command reports ready no sooner than its settle window, the runner's own `await-live` confirms a continuously live owner only after that window has elapsed, and a live owner observed for less than a longer configured window fails with a diagnostic naming that window and keeps its registration for reconcile |
| the ended verdict names one attempt | arming the same artifact after its earlier review ended succeeds on the reopened session's own live listener without re-polling the ended one; on the runner's boundary the same disappearing-registration state reports the missing registration when the only terminal result predates that attempt's `latest-sequence` baseline and the ending when it does not, and a non-numeric baseline is refused |
| liveness confirmation bound | holding the per-source boundary from another process while a one-second confirmation runs returns nonzero at that bound with a concrete diagnostic and the registration retained, so the configured bound is elapsed time rather than a count of reads a concurrent ownership change can stretch |
| bounded re-announcement until handled | a durably captured result with no handled acknowledgement is re-announced by `reconcile` with the same source and sequence on every call - not only the first restart after a crash - and a drained-but-unhandled wake resurfaces identically after a simulated replacement session |
| handled acknowledgement | `fm-procevent.sh handled <source-id> <sequence>` atomically and idempotently records handling at mode `0600`, fails without leaving a marker when private-mode enforcement fails, reports the first call distinctly from every repeat, stops further re-announcement once recorded, and never authorizes a paired effect twice across repeat calls |
| publication-and-acknowledgement serialization | a concurrent `reconcile` cannot append a wake after `handled` wins the shared per-source boundary, so an acknowledged result is not re-announced by a publication race |
| acknowledgement precondition | `handled` is refused, with no marker created, unless matching captured result and adapter records already exist, so a premature or mistyped acknowledgement cannot suppress a future result |
| immutable adapter identity | a captured result retains its adapter after its mutable registration is removed |
| trusted classification boundary | Lavish lifecycle classification reads the leading response envelope, so prompt payload text that resembles a missing-session error cannot override a valid session status |
| result identity and ordering | each wake names the committed sequence to read, and pending sequences 1, 2, and 10 publish in numeric order |
| one owner per canonical source | a second home's `start` for the same source id reports `already owned` and publishes nothing |
| canonical physical identity | a final-component symlink and its target produce the same Lavish source id |
| isolated public start boundary | direct `start` establishes a new runner-led process group before claiming the source, so retirement cannot signal an unrelated process inherited from the caller's group |
| stale reclaim without displacement | concurrent contenders replacing one stale claim start exactly one runner, and cross-home replacement removes the old generation's staging file from its recorded state directory |
| crashed leader with a live owned group | `SIGKILL` on only the runner leader leaves its blocking child group alive; reconcile then stops that surviving group before any replacement starts, never leaves two source processes running for one canonical source, and a generation with no leader and no surviving group is still reclaimed |
| PID-reuse safety | retirement refuses to signal a live PID whose identity differs from the claim, and a reused PID never reaches the group-stop path because its leader is alive |
| coherent ownership reads | a claim replacement held inside the source boundary blocks `list` until one complete generation is visible |
| retire-start exclusion | a queued start revalidates registration after the serialized retirement boundary and executes no child |
| uncertain identity | a live owner whose identity probe transiently fails is not signaled or released, and its registration remains for retry |
| bounded home sweep | a non-mutating full-tree preflight precedes teardown, then registrations and claim-only owned sources retire through the ordinary safe path at each home-removal boundary |
| sweep refusal | uncertain identity preserves the runner, claim, registration, home, lease, and parent retirement evidence for retry |
| foreign ownership | sweeping one home removes its registration without signaling or releasing another home's live claim |
| nested and force cleanup | normal, force, and nested secondmate removal invoke each target home's sweep at its final removal boundary, a failed removal restores and rearms registrations, and failed rearming at any nested level retains and reports its recovery backup with a distinct status |
| teardown refusal ordering | a later public-followup refusal retains the home and its active process-event registration without invoking its sweep |
| healthy-home invariance | homes with no registration or owned runner claim retain ordinary registration-only supervision and teardown behavior |
| source-only supervision | a registered source with no task metadata trips the shared predicate and general guard |
| argv integrity | an argument containing spaces survives as one argument, a shell-looking argument is passed literally with no interpretation, and an unrepresentable newline is rejected at registration |
| bounded output | output beyond `FM_PROCEVENT_MAX_OUTPUT_BYTES` is drained while only the bound is staged, then truncated and captured |
| silent failure handling | a nonzero exit with no output publishes nothing and leaves the source registered for retry |
| inertness | a home with no registered source generates no state, starts no process, and does not need supervision |

## Runner lifetime and cleanup

A runner started by `reconcile` is its own process group leader and is reparented to init, so it outlives the shell that started it by design.
That means nothing about the starting context can reap it: removing a home's state directory does not stop an already-running child, and signalling only the runner leaves the blocking child alive.

Two paths therefore stop a runner, and both verify the runner-owned process group, escalate to `KILL` while that group still exists, and refuse to release ownership until the whole group is gone:

- `retire` resolves the runner PID and identity from this home's machine-wide claim, so retirement still works when the home's state is already gone.
- `reconcile` stops a runner this home owns whose source registration has been removed, and reports it as `stopped=N`.

The same group rule decides when a claim may be reclaimed, not only when a runner may be signalled.
A leader that died while its owned group kept running is not a stale generation, so `reconcile` stops that surviving group and releases its generation before starting any replacement, and preserves the claim for a later retry when it cannot prove the group stopped or another home owns it.
Signalling that group is safe precisely because only an absent leader reaches this state: a reused PID leaves the leader alive, which the identity comparison classifies as stale or uncertain, and no group signal follows.

This was found by four orphaned runners, elapsed 6-13 minutes, left by a suite whose fixture source never completed.
`tests/fm-procevent.test.sh` now covers both paths, and three consecutive suite runs leave zero runners, zero fixture children, and zero stray claims.

## Portability finding

`setsid` is **not present on macOS**, so it cannot establish the runner's process group.
Both direct `start` and `reconcile` use a Perl launcher that forks the runner, calls `setpgrp(0, 0)` in that child, marks the expected group leader, and then executes the private start path.
The private path verifies that the runner PID is also its process-group id before it records a claim, so neither entry point can inherit and claim the caller's process group.
Without this launcher, reconcile would silently fail to start a runner on macOS and direct start could make retirement signal unrelated caller-group processes.

## Scope

The runner is domain-neutral and creates no endpoint, task metadata, or backlog item, so the supported primary harnesses and runtime backends are unaffected except through the `check` wake they already consume.
Lavish is the first adapter; adding another requires only a new `bin/fm-procevent-<adapter>.sh`, whose `terminal` command is optional and defaults to keeping the source armed.

Proactive delivery is inside that same boundary.
The watcher reports a queued process-event result through the one shared actionable-exit path (`wake` in `bin/fm-push-transition-lib.sh`) that every existing signal, stale, and check wake already uses, so it reads no pane, queries no backend, and names no harness.
Both axes are therefore unaffected by construction rather than by assumption: every supported primary harness re-arms from that same exit, and every runtime backend supplies endpoint state only to the pane paths this change does not touch.
While `state/.afk` exists the watcher stays one-shot as before, because this delivery ends the cycle exactly like the existing check path and leaves classification to the daemon.
