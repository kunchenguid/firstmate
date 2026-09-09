# Process-to-event runner verification

Audience: maintainer verification.

This record holds reusable version-scoped evidence for the runner's active guarantees.
`docs/configuration.md` owns the operating contract, each script's header and `--help` own its mechanics, and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

Verified on 2026-07-31 on macOS (Darwin 25.5.0) with `lavish-axi` 0.1.45 installed.
Generic keyed-answer feed verified on 2026-08-16 on the same platform, against the same published poll response shape.
Cross-origin keyed-answer feed verified on 2026-08-19 through the real runner and Lavish adapter interface.
Trusted external `process-event-adapter/1` binding conformance and the runnable `file-signal` example were verified on 2026-08-27 on macOS (Darwin 25.5.0) with Node v25.9.0.

## The published Lavish poll interface the adapter wraps

Verified at implementation time without upgrading the installed build:

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

Re-verified on 2026-08-01 against the same installed build.
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

## Why an empty board close is silent

The same published lifecycle above is the whole basis for the `silent` verdict, so no new source knowledge was needed.
`Send & End` delivers the captain's final feedback once as a `feedback` response carrying `session_ended`, and every poll after it returns an empty ended session.
A board the captain closes without saying anything therefore produces exactly one `ended` response carrying no queued content block, and announcing it put a wake in front of the handler whose entire content was that nothing happened.

The verdict is confined to that one shape and fails closed everywhere else.
A `Send & End` close carrying the captain's own answer classifies `feedback`, never `ended`, so it is announced unchanged; so is any `ended` result that still carries a `prompts` or `feedback` block, which this lifecycle is not expected to produce but which must never be dropped on that expectation.
A `waiting` session, a `missing` one, an `unknown` or unreadable result, and every error stay announced, because none of them positively proves nothing was said.
The content check anchors on column zero for the same reason the terminal check reads the leading `session:` block: content headers are top-level and their rows are indented, so captain-supplied payload text can neither forge a content block nor hide behind a fake empty one.
Any recognized block counts as present even when its declared count is zero, and a malformed top-level `prompts` or `feedback` header is indeterminate and therefore announced.

## The loss limitation this runner cannot close

The published poll clears feedback destructively before returning it.
Measured at the protocol layer by consuming and discarding the response:

```text
consuming read http=200
listing after: ...,open,"...",0
state.json: status= open pending= 0 prompts= []  chat entries= []
```

Nothing remains on the source side to re-read, and there is no acknowledgement, cursor, or replay surface to reserve against.
A result lost after that clearing and before the runner reads the child's output is therefore unrecoverable.

**Consequence for wording:** the runner may describe only its own durability boundary.
Never at-least-once, no-loss, or lossless.

## What the runner does prove

Exercised by `tests/fm-procevent.test.sh` against a fake blocking source whose completion is a process event, not a timer; for the two supervision-delivery rows below, by `tests/fm-watch-triage.test.sh` driving a real `bin/fm-watch.sh` over a real capture; and for adapter-owned application, by `tests/fm-remote-reply.test.sh` driving the real remote-reply relay end to end in an isolated home:

| Guarantee | How it is proven |
| --- | --- |
| capture before publication | the captured result exists at `0600` and its event names its committed sequence only afterward |
| proactive delivery of a captured result | a real capture into an isolated home queues its `check` record, and a healthy watcher with a fresh beacon then exits reporting that queued result as an actionable check, before any manual drain |
| single delivery per source and sequence | after that first proactive wake, a still-unhandled result keeps being re-announced onto the durable queue but never wakes the watcher again; once existing records receive the drain's post-handling acknowledgement and the source result is acknowledged, it is neither re-announced nor reported |
| proactive-delivery crash and drain boundaries | dotted and underscored source ids at the same sequence receive distinct markers; a concurrent drain cannot consume between queue revalidation and marker commit; failed output, failed marker commit, and a crash before marker commit leave replay available, while successful output still ends the actionable cycle and a crash after marker commit suppresses a duplicate |
| adapter-owned terminal verdict | two fixture adapters - one that ends on any result, one with no terminal knowledge - decide the outcome alone: the first has its registration and claim retired automatically after one capture and is never restarted, the second stays armed |
| adapter-owned application of a captured result | a remote-secondmate reply captured through the real relay in an isolated home reaches that secondmate's local status mirror, settles its correlated pending-reply expectation, re-arms the next cursor-anchored source, and is acknowledged, with no handler step or duplicate `check` wake; its new mirrored bytes remain visible to the watcher's signal gate, while a cursor-loss whole-log recapture that adds no bytes is acknowledged quietly; for an already-escalated request, the same path closes the exact decision so the open-decision fold clears and remains clear; a capture whose adapter application fails because local storage for a referenced remote document is obstructed is left unacknowledged and receives the fallback `check` wake, and the handler's own `handle` still applies it in full after storage recovers |
| generic built-in keyed-answer feed | `tests/fm-captain-hold-lifecycle.test.sh` drives a bound built-in source through the real runner with a fixture adapter that only prints keyed lines, proving any bound built-in channel reaches the one keyed-answer intake: named captain-held tasks close at capture time, a card-declared release mode frees held work, keys naming no captain-held task skip, freeform prose forges nothing, matching answer-and-mode replays are idempotent while mode mismatches refuse, an unbound source closes nothing, and capture remains independent of the handler wake. |
| structured reconcile feed | The same suite drives the optional `reconciles` adapter seam through the real runner and proves only a bound captured source can create a request; the ordinary keyed-answer and chat paths refuse the reserved value without closing or creating a request, versioned selection stays separate from its note, rollout-compatible ordinary legacy answers still pass, and legacy reconcile-shaped values feed neither intake. |
| adapter-owned silence verdict | an armed Lavish source driven against a stand-in poll that returns an empty ended session captures its result, records it durably handled, appends no wake, and stays silent through a later `reconcile` that would otherwise republish it, while still retiring its ended source; the same real path with a `Send & End` response carrying the captain's choice still publishes its `check` wake and is left unacknowledged for the handler |
| silence fails closed | the adapter's published `silent` command suppresses only an `ended` session with no queued content block, and announces a real answer, freeform prose, any recognized content block regardless of its declared count, a malformed top-level content header, a `waiting` or `missing` session, a server error, an unreadable result, and indented payload text imitating an empty content block; the `remote-reply` and `when` adapters, which implement no `silent` command, announce every result |
| terminal retirement preserves the result | the retired source's captured output, its announced event, its handled acknowledgement, and later explicit `retire` all still behave normally |
| registration-generation retirement | an old terminal runner preserves a concurrently replaced registration and releases ownership so the replacement runs independently; injected registration-removal failure retains a terminal claim, performs no second poll, and completes idempotently once removal recovers; a live owner retiring its own terminal source mid-capture tolerates only its transient reservation-removal failure and still removes the registration under exact ownership |
| one `Send & End`, one result | an armed Lavish source driven against a stand-in for the published poll, which delivers the final `session_ended` feedback once and empty ended sessions afterward, polls exactly once, captures exactly one result, publishes one distinct event, and retires itself |
| bounded re-announcement until handled | a durably captured result with no handled acknowledgement is re-announced by `reconcile` with the same source and sequence on every call - not only the first restart after a crash - and a presented-but-unacknowledged wake resurfaces identically after a simulated replacement session |
| handled acknowledgement | `fm-procevent.sh handled <source-id> <sequence>` atomically and idempotently records handling at mode `0600`, fails without leaving a marker when private-mode enforcement fails, reports the first call distinctly from every repeat, stops further re-announcement once recorded, and never authorizes a paired effect twice across repeat calls |
| publication-and-acknowledgement serialization | a concurrent `reconcile` cannot append a wake after `handled` wins the shared per-source boundary, so an acknowledged result is not re-announced by a publication race |
| acknowledgement precondition | `handled` is refused, with no marker created, unless matching captured result and adapter records already exist, so a premature or mistyped acknowledgement cannot suppress a future result |
| immutable adapter identity | a captured result retains its adapter after its mutable registration is removed |
| trusted classification boundary | Lavish lifecycle classification reads the leading response envelope, so prompt payload text that resembles a missing-session error cannot override a valid session status |
| result identity and ordering | each wake names the committed sequence to read, and pending sequences 1, 2, and 10 publish in numeric order |
| one owner per canonical source | a second home's `start` for the same source id reports `already owned` and publishes nothing |
| canonical physical identity | a final-component symlink and its target produce the same Lavish source id |
| isolated public start boundary | direct `start` establishes a new runner-led process group before claiming the source, so retirement cannot signal an unrelated process inherited from the caller's group |
| guarded runner startup | the source command does not launch when the detached owner guard rejects an invalid lease configuration, proving the runner waits for positive guard readiness and fails closed when initialization fails |
| attached owner continuity | a foreground `start` with a one-second lease remains alive beyond that lease while its caller stays attached, then captures normally when the blocking source completes |
| owner-home lifetime and scope | a detached runner and its spawning descendant are observed reparented before an expired owner lease stops their whole process group and process churn; replacing the state directory at the same path cannot keep the old runner alive with a new lease because its recorded device/inode no longer matches, while an identical runner in an unchanged home whose reconcile cycle keeps its lease fresh remains alive |
| launch pacing during owner-loss grace | an immediately returning source that attempts detached self-relaunches is held to the configured minimum interval between command launches and remains bounded until its expired owner lease stops the generation; replacement starts a fresh pacing generation, prunes prior pacing state, and prevents a superseded sleeping runner from recreating it |
| stale reclaim without displacement | concurrent contenders replacing one stale claim start exactly one runner, cross-home replacement removes the old generation's staging file from its recorded state directory, and a generation whose stale owner and independently empty process group prove it gone remains reclaimable when its recorded state-root identity can no longer be revalidated |
| crashed leader with a live group | `SIGKILL` on only the runner leader leaves its blocking child group alive; reconcile treats that leaderless group as ambiguous, preserves its claim without starting a replacement, and still reclaims a generation with no leader and no surviving group |
| PID-reuse safety | retirement refuses a live PID whose identity differs from the claim before signalling, and a surviving process group prevents stale-generation cleanup on both ordinary and failed reservation-removal paths |
| coherent ownership reads | a claim replacement held inside the source boundary blocks `list` until one complete generation is visible |
| retire-start exclusion | a queued start revalidates registration after the serialized retirement boundary and executes no child |
| uncertain identity before the first signal | a live owner whose identity probe transiently fails is not signaled or released, and its registration remains for retry |
| bounded home sweep | a non-mutating full-tree preflight precedes teardown, then registrations and claim-only owned sources retire through the ordinary safe path at each home-removal boundary |
| sweep refusal | uncertain identity preserves the runner, claim, registration, home, lease, and parent retirement evidence for retry |
| foreign ownership | sweeping one home removes its registration without signaling or releasing another home's live claim |
| nested and force cleanup | normal, force, and nested secondmate removal invoke each target home's sweep at its final removal boundary, a failed removal restores and rearms registrations, and failed rearming at any nested level retains and reports its recovery backup with a distinct status |
| teardown refusal ordering | a later public-followup refusal retains the home and its active process-event registration without invoking its sweep |
| healthy-home invariance | homes with no registration or owned runner claim retain ordinary registration-only supervision and teardown behavior |
| source-only supervision | a registered source with no task metadata trips the shared predicate and general guard |
| argv integrity | an argument containing spaces survives as one argument, a shell-looking argument is passed literally with no interpretation, and an unrepresentable newline is rejected at registration |
| bounded output | output beyond `FM_PROCEVENT_MAX_OUTPUT_BYTES` is drained while only the bound is staged, then truncated and captured |
| condition->action single-fire and trust | `tests/fm-procevent-when.test.sh` drives the public `when` adapter and generic runner with real commands, proving stable true fires once, a claimed fire restarts as ambiguous without a second action, concurrent arms publish one complete watch, and mutated specs or action executables are refused before execution |
| condition->action terminal outcomes | the same suite proves flapping true polls do not fire, action failure, condition error budget, deadline expiry, and a true poll completing after its deadline each produce the expected terminal captured result without an unsafe action |
| condition->action process bounds | the same suite proves action timeout terminates descendants and command-output staging remains within `FM_WHEN_OUTPUT_TAIL_BYTES` while the command runs |
| silent failure handling | a nonzero exit with no output publishes nothing and leaves the source registered for retry |
| inertness | a home with no registered source generates no state, starts no process, and does not need supervision |
| absent extension registry parity | `tests/fm-extension-binding.test.sh` drives `list` and `verify` in a fresh home while the current directory contains project files and Pi packages and an environment variable names fake package data; both commands report no bindings, create no home path, and discover nothing outside `config/extensions.d` |
| complete package and binding identity | the same suite drives the public bind and verify commands through manifest duplicate/unknown/version failures, project and task-copy confinement, canonical path and symlink rejection, hard-link rejection, owner/mode checks, a non-executable entrypoint, binding mode drift, complete-tree mutation, exact executable mutation, and a missing executable; the foreign-owner fixture executes when the platform permits constructing another uid and otherwise reports that privilege limitation, while ordinary non-privileged CI does not exercise it or claim it ran |
| external evidence write confinement | the same suite substitutes `state/procevent/` and `state/procevent-inbox/` with post-registration symlinks and proves an external start fails before bytes reach either outside target; it proves public lifecycle entry, environment, paths, and descriptors cannot forge capture authority; it proves live-generation claim release removes pending or consumed capture reservations only from the recorded revalidated state root, while a generation independently proved gone may leave an unreachable token-keyed reservation rather than wedging ownership; and it proves the absent-registry built-in capture path retains its legacy state-path behavior |
| strict handshake and negotiation | manifests offering versions 2 and 1 select host protocol 1 and `process-event-adapter/1`, unknown-only versions refuse, and wrong request ids, unknown or duplicate fields, malformed JSON, and nonzero handshake exits publish no binding |
| strict invocation envelope | malformed UTF-8, a byte-order mark, unescaped controls, malformed or multiple JSON documents, duplicate or unknown fields, oversized stdout, oversized stderr, wrong request ids, crashes, nonzero exits, a successful parent that leaves a foreground descendant in its host-created invocation group, and authority-shaped result fields are rejected; leaked group members are reaped and package diagnostic text is not copied into the bounded host-produced error evidence |
| extension timeout and process-group cleanup | a bound adapter that ignores `TERM`, spawns a foreground descendant that ignores `TERM`, and exceeds its invocation timeout returns deterministic timeout evidence only after its exact invocation group is gone; deliberate process-group escape is outside this trusted-same-user protocol guarantee |
| static launch and interruption recovery | the focused extension suite runs the public host under Node's no-dynamic-code guard, interrupts a host with an active TERM-resistant package group and observes host exit only after exact-group extinction, then kills a host at the post-release crash cut and proves identity-safe binding retirement reaps that recorded group before ownership is removed |
| exact replay identity | two public host invocations carrying the same request id return the same result and advance the fixture package's request-id-keyed effect ledger once; two generic-runner starts that produce no capturable result also reuse one registration-and-next-sequence-derived request id and apply that fixture effect once |
| complete external adapter path | the shipped external `file-signal` package is copied outside the Git project, explicitly bound with its required artifact-reference consent, discovered, verified, registered with one file reference, started through the generic runner, completed by a real file appearance, durably captured, published through the existing bounded event, classified through its immutable package identity, left unhandled, and terminally retired |
| owner-matched replacement safety | two registrations for the same external source receive distinct owner tokens; unconditional external retirement and the first token cannot retire the replacement, the replacement token can, bounded home sweep derives and uses that exact token, and legacy built-in registrations retain unconditional behavior plus exact `--if-matches` retirement |
| independent homes | two homes bind the same package id/version to different content-addressed absolute paths and independently capture results and extension state, with no cross-home fallback or result path |

Run the focused external-binding evidence and the live Bearings session guard with:

```sh
node --version
bin/fm-test-run.sh tests/fm-extension-binding.test.sh
FM_EXTENSION_BINDING_SEGMENT=lifecycle-invocation-cleanup bin/fm-test-run.sh tests/fm-extension-binding.test.sh
bin/fm-test-run.sh tests/fm-procevent.test.sh
FM_BEARINGS_LAVISH_LIVE=1 bin/fm-test-run.sh tests/fm-bearings-board-lavish-live-e2e.test.sh
bin/fm-doc-audience-check.sh
```

## Harness and session-provider review

The external host runs in the home that owns the process-event source and publishes the same bounded `check` record as every built-in adapter.
The 2026-08-27 review inspected `bin/fm-harness.sh`, `bin/fm-supervision-instructions.sh`, `bin/fm-supervision-lib.sh`, the process-event delivery and reconcile boundaries in `bin/fm-watch.sh`, `bin/fm-backend.sh`, and `bin/fm-config-inherit-lib.sh` before marking integration axes not applicable.

| Axis | Reviewed boundary and result |
| --- | --- |
| Claude, Codex, OpenCode, Pi, pi-signed, Grok, and Cursor primaries | Applicable only at the existing watcher continuation after one shared `check` wake; no package byte, command, state path, or verdict enters a harness-specific integration. |
| Kimi | The process-event path never enters the worker runtime, and a Kimi primary retains the existing unknown-protocol supervision fallback rather than gaining extension-specific behavior. |
| Muse | Muse remains a crewmate/scout-only runtime, so no primary process-event integration exists; external adapters still run in the owning home, not in Muse. |
| Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, and Muse task workers | Not applicable after inspecting harness detection and launch ownership, because source registration has no task metadata or worker endpoint and the package is never launched through `fm-spawn`. |
| tmux, Herdr, Zellij, Orca, and cmux session providers | Not applicable after inspecting the known and spawn-capable backend dispatch sets, because process-event execution calls no backend selector, capture, send, liveness, or cleanup primitive. |
| Local and remote secondmate homes | Applicable at the home boundary only; each home owns its own binding, content-addressed package, extension state, registration, result, and watcher, and `config/extensions.d` remains outside the inherited-material allowlist. |

## Runner lifetime and cleanup

The [operating contract](../configuration.md#process-to-event-sources-stateprocevent) owns stop authority, the guard's lease and two-read debounce, claim reclamation, and the permanent leak and silent loss of listening after an unrelated leader death.

Measured on 2026-09-08 on macOS (Darwin 25.5.0) against a stand-in poll child that traps TERM, INT, and HUP and keeps blocking: before the repair the guard signalled, lost the leader to that signal, and exited leaving the child running past 70 seconds.
The guard caused the permanent leak by destroying the leader needed to prove ownership; a guard that causes that leak is worse than no guard.
After the repair, the guard cleared that child in 7.7 seconds with a 5-second lease and 1-second check, and `retire` cleared the same shape in about 2.4 seconds.
The bound is the lease term plus ONE check interval plus the stop's grace period, roughly 620 seconds at the shipped 600-second lease and 15-second check - a 601-second lease term, one 15-second interval, and up to 4 seconds of stop, with two reads still required so a single unreadable read cannot kill a live runner.
What was tightened is the spacing of those two reads, not their number: half a check interval apart they both fit inside the single interval the bound budgets, where a full interval between them cost a second one.
The lease term is the configured lease plus one second because the age comparison is in whole seconds, and that rounding is part of the bound rather than slack.
The figure and that reason belong together: a number recorded without why it is that number is the one a later reader shortens.
On the same date and host, retiring a healthy runner fell from about 2.8 seconds with a forced group signal every time to about 0.6 seconds with the ordinary signal alone.
The circular lock wait described at `release_start_claim` in [`bin/fm-procevent.sh`](../../bin/fm-procevent.sh) explains why healthy runners required the forced signal; the measured delay was the stop waiting for exit cleanup that could not acquire its lock.

Measured on 2026-09-09 on the same host, reaping an orphaned listener whose home stopped refreshing its lease and sampling the phase between the guard's check clock and the lease clock across eight runs per variant: 3.5 to 4.7 seconds with the two reads half an interval apart against 4.4 to 5.3 seconds with a full interval between them, at a 2-second lease and 1-second check, and 5.9 to 6.1 against 7.7 to 8.1 seconds at a 2-second lease and 4-second check.
The regression pins that phase rather than sampling it, because a sampled phase lets a guard spending two intervals pass on a lucky alignment; it prints its own figure, 13.2 seconds after the last owner activity against a documented 15-second bound at a 7-second lease and 6-second check, and a guard given a full interval between its two reads breached that deadline.
A guard that acted on a single failed read instead reached the same reaping in 9.9 seconds, so the UNSAFE variant is the faster one.
That is why the bound and the debounce are pinned by separate cases: a change trading one away for the other would otherwise register only as an improvement.

[`tests/fm-procevent.test.sh`](../../tests/fm-procevent.test.sh) exercises these reproductions through the executable interface: a TERM-surviving child under both `retire` and the guard, escalation with an absent or zombie leader or probes configured to become unreadable after TERM, and refusal of mismatched live identities or nonleaders before the first signal.
The healthy-runner case requires the attached `start` to return status 143 (TERM); the printed retirement duration and sampled stop windows are supplementary evidence, not a timing-based pass condition.
Two cases pin the guard's own numbers rather than only its outcome: one reaps an orphaned listener within the lease term plus a single check interval, with the lease expiry deliberately placed late in that interval, and one fails exactly one lease read against a home that is still alive and requires the runner to survive it.
They fail for opposite reasons, which is the point of keeping them apart.
The crashed-leader cases separately pin refusal and claim preservation when a leader dies outside the stop's own signal, so successful escalation cannot be mistaken for closing that limit.
Refresh the regressions with `bash tests/fm-procevent.test.sh`; the dated measurements above are recorded observations, not fixed timing thresholds.

## Portability finding

`setsid` is **not present on macOS**, so it cannot establish the runner's process group.
Both direct `start` and `reconcile` use a Perl launcher that forks the runner, calls `setpgrp(0, 0)` in that child, marks the expected group leader, and then executes the private start path.
The private path verifies that the runner PID is also its process-group id before it records a claim, so neither entry point can inherit and claim the caller's process group.
Without this launcher, reconcile would silently fail to start a runner on macOS and direct start could make retirement signal unrelated caller-group processes.

## Scope

The runner is domain-neutral and creates no endpoint, task metadata, or backlog item, so the supported primary harnesses and runtime backends are unaffected except through the existing `check` and status-signal wake paths they already consume.
Built-in adapters extend the runner through `bin/fm-procevent-<adapter>.sh`; the `when` adapter also uses the runner library's locked registration publisher so its private trust state and source registration are serialized under one source boundary.
Explicit external adapters instead use the single-capability contract in [`docs/extension-bindings.md`](../extension-bindings.md), with no filename discovery or package-supplied argv.
An adapter's `terminal` command is optional and defaults to keeping the source armed.
Its `silent` command is optional in the same way and defaults to announcing every result, so an adapter with no notion of a routine no-op is unchanged.
Its `autohandle` command is optional in the same way and defaults to leaving the captured result unacknowledged, so it keeps being announced to a handler exactly as before.
The optional `self-announcing` declaration changes ordering only for an adapter with its own durable downstream announcement; the operating contract in `docs/configuration.md` owns that boundary.

Proactive delivery is inside that same boundary.
The watcher reports a queued process-event result through the one shared actionable-exit path (`wake` in `bin/fm-push-transition-lib.sh`) that every existing signal, stale, and check wake already uses, so it reads no pane, queries no backend, and names no harness.
Both axes are therefore unaffected by construction rather than by assumption: every supported primary harness re-arms from that same exit, and every runtime backend supplies endpoint state only to the pane paths this change does not touch.
While `state/.afk` exists the watcher stays one-shot as before, because this delivery ends the cycle exactly like the existing check path and leaves classification to the daemon.
