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

The adapter's polling path depends on none of this: it uses only the published poll shape above.

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
| adapter-owned silence verdict | an armed Lavish source driven against a stand-in poll that returns an empty ended session captures its result, records it durably handled, appends no wake, and stays silent through a later `reconcile` that would otherwise republish it, while still retiring its ended source; the same real path with a `Send & End` response carrying the captain's choice still publishes its `check` wake and is left unacknowledged for the handler |
| silence fails closed | the adapter's published `silent` command suppresses only an `ended` session with no queued content block, and announces a real answer, freeform prose, any recognized content block regardless of its declared count, a malformed top-level content header, a `waiting` or `missing` session, a server error, an unreadable result, and indented payload text imitating an empty content block; the `remote-reply` and `when` adapters, which implement no `silent` command, announce every result |
| terminal retirement preserves the result | the retired source's captured output, its announced event, its handled acknowledgement, and later explicit `retire` all still behave normally |
| registration-generation retirement | an old terminal runner preserves a concurrently replaced registration and releases ownership so the replacement runs independently; injected registration-removal failure retains a terminal claim, performs no second poll, and completes idempotently once removal recovers |
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
| condition->action single-fire and trust | `tests/fm-procevent-when.test.sh` drives the public `when` adapter and generic runner with real commands, proving stable true fires once, a claimed fire restarts as ambiguous without a second action, concurrent arms publish one complete watch, and mutated specs or action executables are refused before execution |
| condition->action terminal outcomes | the same suite proves flapping true polls do not fire, action failure, condition error budget, deadline expiry, and a true poll completing after its deadline each produce the expected terminal captured result without an unsafe action |
| condition->action process bounds | the same suite proves action timeout terminates descendants and command-output staging remains within `FM_WHEN_OUTPUT_TAIL_BYTES` while the command runs |
| silent failure handling | a nonzero exit with no output publishes nothing and leaves the source registered for retry |
| inertness | a home with no registered source generates no state, starts no process, and does not need supervision |
| absent extension registry parity | `tests/fm-extension-binding.test.sh` drives `list` and `verify` in a fresh home while the current directory contains project files and Pi packages and an environment variable names fake package data; both commands report no bindings, create no home path, and discover nothing outside `config/extensions.d` |
| complete package and binding identity | the same suite drives the public bind and verify commands through manifest duplicate/unknown/version failures, project and task-copy confinement, canonical path and symlink rejection, hard-link rejection, owner/mode checks, a non-executable entrypoint, binding mode drift, complete-tree mutation, exact executable mutation, and a missing executable; the foreign-owner fixture executes when the platform permits constructing another uid and otherwise reports that privilege limitation, while ordinary non-privileged CI does not exercise it or claim it ran |
| external evidence write confinement | the same suite substitutes `state/procevent/` and `state/procevent-inbox/` with post-registration symlinks and proves an external start fails before bytes reach either outside target; it proves public lifecycle entry, environment, paths, and descriptors cannot forge capture authority; it proves claim release and dead-owner reconciliation remove pending or consumed capture reservations only from the recorded revalidated state root; and it proves the absent-registry built-in capture path retains its legacy state-path behavior |
| strict handshake and negotiation | manifests offering versions 2 and 1 select host protocol 1 and `process-event-adapter/1`, unknown-only versions refuse, and wrong request ids, unknown or duplicate fields, malformed JSON, and nonzero handshake exits publish no binding |
| strict invocation envelope | malformed UTF-8, a byte-order mark, unescaped controls, malformed or multiple JSON documents, duplicate or unknown fields, oversized stdout, oversized stderr, wrong request ids, crashes, nonzero exits, a successful parent that leaves a foreground descendant in its host-created invocation group, and authority-shaped result fields are rejected; leaked group members are reaped and package diagnostic text is not copied into the bounded host-produced error evidence |
| extension timeout and process-group cleanup | a bound adapter that ignores `TERM`, spawns a foreground descendant that ignores `TERM`, and exceeds its invocation timeout returns deterministic timeout evidence only after its exact invocation group is gone; deliberate process-group escape is outside this trusted-same-user protocol guarantee |
| static launch and interruption recovery | the focused extension suite runs the public host under Node's no-dynamic-code guard, interrupts a host with an active TERM-resistant package group and observes host exit only after exact-group extinction, then kills a host at the post-release crash cut and proves identity-safe binding retirement reaps that recorded group before ownership is removed |
| exact replay identity | two public host invocations carrying the same request id return the same result and advance the fixture package's request-id-keyed effect ledger once; two generic-runner starts that produce no capturable result also reuse one registration-and-next-sequence-derived request id and apply that fixture effect once |
| complete external adapter path | the shipped external `file-signal` package is copied outside the Git project, explicitly bound with its required artifact-reference consent, discovered, verified, registered with one file reference, started through the generic runner, completed by a real file appearance, durably captured, published through the existing bounded event, classified through its immutable package identity, left unhandled, and terminally retired |
| owner-matched replacement safety | two registrations for the same external source receive distinct owner tokens; unconditional external retirement and the first token cannot retire the replacement, the replacement token can, bounded home sweep derives and uses that exact token, and legacy built-in registrations retain unconditional behavior plus exact `--if-matches` retirement |
| independent homes | two homes bind the same package id/version to different content-addressed absolute paths and independently capture results and extension state, with no cross-home fallback or result path |

Run the focused external-binding evidence with:

```sh
node --version
bin/fm-test-run.sh tests/fm-extension-binding.test.sh
FM_EXTENSION_BINDING_SEGMENT=lifecycle-invocation-cleanup bin/fm-test-run.sh tests/fm-extension-binding.test.sh
bin/fm-test-run.sh tests/fm-procevent.test.sh
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

## Lavish reviewer links and the browser connection pool

Verified on 2026-09-04 with Lavish 0.1.64, Windows Chrome 152.0.7977.66, and a WSL server listening on IPv4 loopback.
The reviewer used a fresh Chrome profile with six distinct session keys, one tab per board, on the same HTTP origin.
CDP recorded six unfinished `GET /events/<key>` responses with `protocol: http/1.1` and `remoteIPAddress: 127.0.0.1`.
The artifact SDK returned a DOM snapshot, but the subsequent Send request and another tab's reload waited for a free connection.
The measured Send timing was:

```json
{"sendStart":60644.562,"sendEnd":60644.665,"receiveHeadersStart":60701.444,"receiveHeadersEnd":60701.485}
```

These CDP timing fields are milliseconds relative to the request, so nearly all of the delay preceded transmission.
Closing two fixture tabs released the unchanged pending requests; the prompt returned 200 and the listener captured the queued text.
This motivates the current hostname mitigation without requiring duplicate reviewer tabs or a broken listener.

A separate server on port 4399 accepted an explicitly allow-listed `scout-one.localhost` host and rejected an unlisted localhost subdomain.
With six `localhost:4399` fixture streams still open, Windows Chrome opened a seventh session on `scout-one.localhost:4399`, loaded its SDK, and submitted its prompt successfully:

```text
POST /api/4970fe917f997d57/prompts
Host: scout-one.localhost:4399
Origin: http://scout-one.localhost:4399
Status: 200
```

```json
{"status":"queued","pending_prompts":1}
```

The isolated poll captured the exact submitted text and its DOM snapshot.
No hosts-file change was required for that Windows Chrome browser.
This is Chrome evidence; Edge was not verified.

The adapter's `link` command was also exercised through the real Lavish 0.1.64 session listing and real HTTP health probes on an isolated server.
Two fixture artifacts were served with `--no-open`, only the first artifact's alias was explicitly allowed, and the public commands were repeated unchanged:

```sh
bin/fm-procevent-lavish.sh link "$first_artifact"
bin/fm-procevent-lavish.sh link "$second_artifact"
```

Exact outputs from that fixture:

```text
http://lavish-a75a2963d7b87591.localhost:4399/session/a75a2963d7b87591
http://127.0.0.1:4399/session/d795f09774321d4b
```

Both repeated calls returned the same output, preserved the nondefault port, and left the served sessions and listeners unchanged.
All fixture sessions and the isolated server were ended after the checks.

The portable executable regression is refreshed with:

```sh
bin/fm-test-run.sh tests/fm-procevent.test.sh tests/fm-bearings-board.test.sh tests/fm-bearings-board-render.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

It covers stable first-come round-robin fallback allocation across two Firstmate homes, exact 200-only alias preference, failed probes, quoted listing fields, served ports and queries, missing or ended sessions, and the bearings producer's serve-before-arm ordering with automatic browser opening suppressed.
It also checks that remote, IPv6, and HTTPS session URLs retain their original authority, avoiding an unverified endpoint or TLS hostname rewrite.
The command is independent of the primary harness and runtime backend: it reads the CLI session listing and probes HTTP health, without starting an agent, invoking a backend adapter, opening a browser, or consuming feedback.
The script header owns exact link mechanics; the process-event skill owns the hosting procedure and capacity limit.
The private per-port fallback map lives beside Lavish's shared user state and is written under an OS flock, so first-time assignments from every Firstmate home stay balanced and stable across reruns.
Six boards on one Lavish server therefore use no more than three connections on either accepted address even when different homes produce their links.
This mitigation is bounded to six boards per server until the event-stream transport fix lands.
A seventh fallback board emits a one-line warning with the three-board-per-address limit and the exact alias path that must be enabled.

The 2026-09-04 portable run completed with:

```text
FM_TEST_SUMMARY total=3 failed=0 skipped_gate=0 duration_ms=71135
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
fm-doc-audience-check: ok surfaces=92 local_links=318
```
