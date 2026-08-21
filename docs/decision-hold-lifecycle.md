# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records the deterministic mechanism, structured surfaces, and privacy-safe regression evidence.

## Mechanism

`bin/fm-decision-hold.sh` is the only lifecycle command for an investigation or visual review's unresolved captain decisions.
The command runs tasks-axi in the active `FM_HOME`, so the existing backlog remains the only durable work database and a secondmate-owned decision stays in the secondmate home.
It never reads report bodies, review artifacts, terminal output, or chat.

The `hold` subcommand maps an originating work id and stable decision key to `<origin-id>-decision-<decision-key>`.
It creates a kind `captain` backlog item when absent and invokes `tasks-axi hold <id> --reason <reason> --kind captain` on every retry.
It rejects an identity collision, a changed title, and attempts to reopen an already resolved identity.

The `complete` subcommand unions the reviewed keys into `decision_keys=` and appends `decisions_reviewed=1` while originating task metadata is live.
A post-teardown visual review can complete against the surviving report and durable holds without recreating volatile task metadata.
It accepts `--none` as an explicit semantic inventory result, not as inferred absence.
It verifies every listed identity against tasks-axi before recording completion.
For an open keyed status decision, it appends a `captain-held [key=<key>]: ...` transfer event only after the matching backlog hold is durable.
`bin/fm-classify-lib.sh` recognizes that transfer as closing the live status copy without claiming that the captain has answered it.

Scout teardown calls the script's read-only `verify` subcommand after checking for the report and before removing any source state.
The `--force` path remains the explicit captain-approved discard escape hatch.

The `resolve`, `answer`, and `decline` subcommands close active holds, while `repair` attests a hold already closed outside the script.
All four require a non-empty captain decision file and record the same resolution block in the hold body with the decision digest, routed identities, and a `Resolution mode:` naming the path.
An exact retry is idempotent, while a changed decision or, for `resolve`, a changed routed-task set is rejected.

The `resolve` subcommand is the routed path and additionally requires at least one existing dependent task whose structured `blocked-by` edge points to the hold.
It clears each dependency edge through tasks-axi and marks the hold Done only after those writes succeed.
An exact retry can finish a partial routing operation, and a failed intermediate step leaves the hold open.

The public `answer` and `decline` subcommands share one unrouted close implementation and differ only in the `Resolution mode:` they record and the outcome word they print, so neither can drift into a weaker ordinary close than the other.
Both ordinarily record `(none)` as the routed identities and refuse while any task in the same backlog is still blocked by the hold, because releasing routed work without recording it is `resolve`'s job.
The keyed-answer intake's reserved drop is the sole exception: its internal decline invocation closes only the stale hold and deliberately leaves existing dependents as independent queued work.
Every candidate found in the listing prefilter is confirmed against its own structured record before the refusal is reported.
`answer` exists so the act carrying a captain answer can also be the act that closes its hold; an ordinary `decline` continues to mean the stronger claim that the answer routes no follow-up work at all.

The `repair` subcommand records the resolution block on a hold that was already closed outside the script, such as by a direct `tasks-axi done`, so an origin whose decision was genuinely answered stops failing `verify`.
It refuses a hold that is still actively held, never reopens a closed hold, and never clears a dependency edge, so an unanswered decision keeps blocking teardown until the captain's word closes it.
It also requires the identity to carry the captain-hold provenance that tasks-axi preserves through a close, so an ordinary captain-kind task that was never held cannot be repaired into a resolved decision.

## Answer-time closure

The live status-log decision ledger has always had answer-time closure through `bin/fm-send.sh --resolve-key`: answering a keyed decision closes it in the same act.
The durable hold ledger did not, so an answer could be captured, believed, and even implemented while its hold stayed open, and the captain could then be asked to re-answer a decision already on disk.

"A keyed answer closes its matching hold" is now one capability with one owner.
`answers` is its channel-agnostic entry point: it reads a key, answer, and label on each input line and closes the matching hold through the same `answer` path, except that the exact reserved answer `__drop__` closes with a declined, "dropped by captain" decision record rather than as a substantive choice.
For a single-origin intake the key is the decision key mapped under that bound origin; for the cross-origin intake it is the full hold identity, while keys that do not name a full decision hold feed nothing.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch and no knowledge of chat, review decks, or any transport.
A channel's only job is to turn whatever it received into those keyed lines and pipe them in; it never maps keys to holds, builds decision records, chooses between the close paths, or closes a hold itself.
Emitting `__drop__` is how a channel reports that the captain dropped the decision; the intake, not the channel, chooses `decline`.
The decision text is a pure function of source, key, answer, and label, which is what makes a replayed delivery an idempotent no-op rather than a rejected different decision.
A key whose hold is absent or already closed is reported as skipped, as is a substantive answer whose hold still blocks routed work; a reserved drop instead closes only that hold while existing dependents remain independent queued work.
The command exits nonzero when any key was skipped.

`bind`, `unbind`, and `binding` record whether a captured-answer source belongs to one origin or uses the cross-origin intake, for a channel whose answers arrive detached from the origin.
The binding is a private record under `state/decision-bindings/`, and a source with no binding feeds nothing, so the path is opt-in per source.
`bind` deliberately does not require the source to exist yet, so a channel can be bound before it is armed and never produce an answer that has nowhere to go.
The script header and `--help` own the exact cross-origin marker, identity split, limits, and refusal behavior.

Two channels feed that one intake today, and both are ordinary callers rather than special cases.

`bin/fm-send.sh --resolve-key` is the chat channel.
Its existing status-log close is unchanged for a key the status log still owns.
For a key the status log no longer owns it checks whether that key names an active captain hold on the target task, and feeds the answer as one keyed line if so, which is what lets chat answer a decision already transferred to its hold.
A key open in neither ledger is still refused before anything is sent.
Because `complete` closes the live status copy at the moment it transfers a decision to its hold, the two ledgers are the two sides of one transfer and never both own a key at once, so the common path still performs no backlog read.

`bin/fm-procevent.sh` is the captured-result channel, and its wiring is generic.
After capture, a bound source has its result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>` and whatever that prints is piped into the intake, so any adapter with an `answers` command works and the runner names no adapter, parses no result, and carries no decision rule.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, so recording the captain's answer cannot retire the notification firstmate needs in order to act on it.
`bin/fm-procevent-lavish.sh answers` is one such adapter command; it reports the structured choices a review captured and stops there, reading only rows tagged `choice` so freeform captain prose can never forge a decision key.

## Structured read surfaces

`bin/fm-fleet-snapshot.sh` parses canonical tasks-axi `(hold: ...)` and `(hold-kind: captain)` metadata alongside existing backlog fields.
It resolves every repeated `blocked-by:` edge against structured Done records, keeps missing blockers unresolved, and classifies only an unblocked captain hold as actionable.
Its secondmate-home summary classifies an actionable captain hold as `captain_decision` and preserves blocked captain holds as queued work in the owning home.

`bin/fm-bearings-snapshot.sh` projects actionable captain holds into `decisions_open` and leaves blocked captain holds in ordinary queued gates.
It excludes completed kind `captain` records from Recently Landed.
The projection remains read-only and does not inspect historical prose.

## Verification record

Verification date: 2026-07-14.
Additional quoted `blocked_by` regression verification date: 2026-07-17.
Plural blocker-readiness and mixed-home projection verification date: 2026-07-22.
Unrouted close-path verification date: 2026-08-13.
Answer-time closure verification date: 2026-08-16.
Cross-origin answer-time closure verification date: 2026-08-19.
Reserved close/drop answer verification date: 2026-08-20.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

Three further regressions cover the close paths that route no work.
A declined decision closes with a recorded answer, satisfies `verify`, leaves Bearings' Captain's Call, and is refused while the hold still blocks routed work.
A hold closed by a direct `tasks-axi done` reproduces the shape that fails `verify` and blocks teardown, and `repair` with a captain decision file clears both.
An unanswered decision still blocks completion and teardown, and neither `decline` nor `repair` can close a hold that is still actively held or supply an answer with a missing or empty decision file.
`repair` also refuses a closed captain-kind task that was never held for the captain.

Three answer-time closure regressions run against the published poll response shape, with synthetic `sample` identities.
A bound source whose origin exposes six holds captures one review carrying five structured choices plus one freeform message, and the runner feeds it through a fixture adapter that is not the review adapter at all, so what is proven is that any bound channel with an `answers` command gets closure rather than that one channel is wired specially.
Four holds whose answers route no work close, the one still blocking routed work is skipped and stays available to `resolve`, and the one whose key appears only inside the freeform prose never closes.
The capture is left unacknowledged throughout, so the wake firstmate needs in order to act on the answers is never retired.
A replayed delivery closes nothing new and is not rejected as a different decision, a source with no binding closes nothing at all, and the `answer` subcommand itself refuses an empty or missing decision file, an absent hold, and a drifted retry.
A separate regression drives the real `fm-send` over a stubbed transport to prove the chat channel reaches the same intake for a decision already transferred to its hold, which the status ledger alone can no longer close.
The cross-origin regression drives a bound source through the real runner and adapter interface, closes full-identity holds from different origins, and proves that over-limit, malformed, non-decision, routed-work, absent-hold, and replayed answers all fail or skip without weakening the existing guards.
A reserved `__drop__` answer through that same published poll shape declines the matching hold with a dropped-by-captain record and leaves Bearings' Captain's Call even when existing independent work is routed behind it; that dependent work remains queued and is not closed.

The final verification commands and their exact summarized outputs follow.

```text
$ bash tests/fm-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced scout teardown always requires durable inventory verification
ok - a declined decision closes with a recorded answer and no routed work
ok - a decision closed outside the script is repairable and then clears teardown
ok - an unanswered decision still blocks completion and resists both unrouted close paths
ok - captain holds are idempotent, distinct, teardown-safe, Bearings-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a bound channel's captured answers close their captain holds at answer time
ok - a channel source with no decision binding closes nothing
ok - an any-origin bound source closes full-identity holds across origins
ok - the answer path keeps every guard the unrouted close path already had
ok - the chat channel feeds the same keyed-answer intake a captured review does

$ bash tests/fm-bearings-board.test.sh
ok - path prints the stable home-scoped board location
ok - build refuses malformed payloads before touching the board
ok - build keeps freeform-only credential cards valid
ok - build injects the payload, binds any-origin, then arms the source
ok - registration can consume answers only after any-origin binding exists
ok - build establishes the Lavish session before binding and arming
ok - rebuild refreshes the board in place without double-arming
ok - build refuses a template without exactly one data slot
ok - a reserved close/drop answer declines the hold and leaves Captain's Call

$ bash tests/fm-fleet-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable captain-held transfer closes the duplicate live status decision
ok - snapshot parses tasks-axi rows and respects operational overrides

$ bash tests/fm-bearings-snapshot.test.sh
ok - a completed scout with decision-like report prose is a pointer, not pending
ok - an authoritative captain hold surfaces end-to-end
ok - action-free items (working/done/queued/landed) do not leak into Captain's Call
ok - main and secondmate captain actionability use the same blocker readiness

$ bash tests/fm-send-resolve-key.test.sh
ok - fm-send --resolve-key: the answer send itself closes the open decision
ok - fm-send --resolve-key: a key that is not open refuses loudly before anything is sent
(13 assertions total; the status-log ledger's behavior is unchanged)

$ bash tests/fm-brief.test.sh
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/fm-teardown.test.sh
ok - the run abort and the leaked-process reap both complete before the destructive worktree return

$ bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/fm-doc-audience-check.sh
fm-doc-audience-check: ok surfaces=68 local_links=253

$ git diff --check
(no output)
```
