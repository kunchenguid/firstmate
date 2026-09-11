# Decision hold lifecycle mechanism

The normative policy is owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and is not restated here.
This document records integration context, structured surfaces, and privacy-safe regression evidence.

## Mechanism

The executable interface, identity and retry rules, operation ordering, retained-history validation, path and file protections, and legacy compatibility mechanics are owned by `bin/fm-decision-hold.sh`; run `bin/fm-decision-hold.sh --help` for that contract.
The project-scoped `bin/tasks-axi` entrypoint delegates retention-affecting tasks-axi commands to that owner.
Scout teardown points to the script's `verify` command, and the shared classifier points to its durable transfer record.
This document intentionally keeps only integration context and regression evidence rather than duplicating those owners.

## Answer-time closure

The live status-log decision ledger has always had answer-time closure through `bin/fm-send.sh --resolve-key`: answering a keyed decision closes it in the same act.
The durable hold ledger did not, so an answer could be captured, believed, and even implemented while its hold stayed open, and the captain could then be asked to re-answer a decision already on disk.

"A keyed answer closes its matching hold" is now one capability with one owner.
`answers` is its channel-agnostic entry point: it reads `<decision-key>`, answer, and label lines on stdin, maps each key to `<origin-id>-decision-<key>`, and closes it through the same `answer` path, so every guard applies identically no matter which channel the answer arrived on.
`--source` is provenance text recorded in the durable decision, never a behavior switch, and the command carries no per-channel branch and no knowledge of chat, review decks, or any transport.
A channel's only job is to turn whatever it received into those keyed lines and pipe them in; it never maps keys to holds, builds decision records, chooses between the close paths, or closes a hold itself.
The decision text is a pure function of source, key, answer, and label, which is what makes a replayed delivery an idempotent no-op rather than a rejected different decision.
A key whose hold is absent, already closed, or still blocking routed work is reported as skipped and left for `resolve`, and the command exits nonzero when any key was skipped.

`bind`, `unbind`, and `binding` record which origin a captured-answer source belongs to, for a channel whose answers arrive detached from the origin.
The binding is a private record under `state/decision-bindings/`, and a source with no binding feeds nothing, so the path is opt-in per source.
`bind` deliberately does not require the source to exist yet, so a channel can be bound before it is armed and never produce an answer that has nowhere to go.

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
Retained-history completion verification date: 2026-08-17.

The focused end-to-end regression uses only synthetic `sample` identities and decision text.
It begins with a completed investigation and visual review whose genuine unresolved choice exists only in the report.
The initial Bearings snapshot correctly has no open decision, and the new teardown gate refuses to erase the source.
A later regression covers tasks-axi's quoted multi-entry `blocked_by` output so `resolve` matches the first, middle, and last ids and rejects a genuinely absent id.

Three further regressions cover the close paths that route no work.
A declined decision closes with a recorded answer, satisfies `verify`, leaves Bearings' Captain's Call, and is refused while the hold still blocks routed work.
A hold closed by a direct `tasks-axi done` reproduces the shape that fails `verify` and blocks teardown, and `repair` with a captain decision file clears both.
An unanswered decision still blocks completion and teardown, and neither `decline` nor `repair` can close a hold that is still actively held or supply an answer with a missing or empty decision file.
`repair` also refuses a closed captain-kind task that was never held for the captain.

A retained-history regression resolves two synthetic decisions, proves retained released-version metadata first, moves both records into a non-default configured archive through the public executable's normal-retention interface, and then completes and verifies a later decision repeatedly.
It repeats the exact completion command after that later decision resolves, and a companion existing-metadata case proves an unclassified pre-upgrade inventory cannot mistake an older archive row for a missing current generation until the caller explicitly migrates its provenance.
A live-completion case proves that provenance survives normal metadata teardown, preserves an exact resolved retry, and keeps a missing previously inventoried hold from being forgotten by a later review.
The same explicit unresolved inventory is required to have an active hold even when no matching status event exists, so status text cannot select historical fallback.
After normal teardown removes origin metadata and its generated attestation is removed to reproduce a pre-upgrade home, repeated completion still recognizes the uniquely decomposable legacy record and a hold retry cannot recreate it.
It proves the bounded Done window and archive stay byte-identical across repeated completion and verification instead of oscillating through row restoration.
The archive-boundary cases also configure a contained root-level backlog, migrate its configured archive while exact retained Done proof survives, prove that an edited copy of a tasks-axi note snapshot cannot establish Done retention, migrate an exact pre-boundary archive only with independent authorization, reject nested public retention re-entry, and reject dangling or future case-variant note-archive aliases according to the active filesystem.
Companion failure cases reopen an archived key without an active owner, surface a backlog read error while matching history exists, remove an active decision record, mismatch an active record's origin and key, normally prune an out-of-band close with no resolution block, collide two origin/key pairs onto one concatenated id, refuse automatic or claimant-derived migration of that collision, spoof captain metadata in an ordinary captain-kind title, exceed the captain decision size bound, mismatch resolution modes, digests, and routed-work lists, and point archive, state, metadata, or report ownership evidence across unsafe boundaries; none can masquerade as historical resolution.
An ambiguous released-version record remains fail-closed when only claimant metadata and the recorded answer survive, while an independently authorized exact mapping migrates its original identity compatibly from durable post-teardown evidence.
A queued repair-only resolution is separately rejected and a uniquely decomposable queued released-version resolution remains retryable after teardown.
Another case proves overlong released task identities use bounded attestation filenames, authenticated interrupted publication recovers, and unrelated hardlinks remain untouched and rejected.
The public completion gate also accepts option-shaped decision keys and verifies active and resolved records while `jq` is unavailable, relying only on the universal toolchain.

Three answer-time closure regressions run against the published poll response shape, with synthetic `sample` identities.
A bound source whose origin exposes six holds captures one review carrying five structured choices plus one freeform message, and the runner feeds it through a fixture adapter that is not the review adapter at all, so what is proven is that any bound channel with an `answers` command gets closure rather than that one channel is wired specially.
Four holds whose answers route no work close, the one still blocking routed work is skipped and stays available to `resolve`, and the one whose key appears only inside the freeform prose never closes.
The capture is left unacknowledged throughout, so the wake firstmate needs in order to act on the answers is never retired.
A replayed delivery closes nothing new and is not rejected as a different decision, a source with no binding closes nothing at all, and the `answer` subcommand itself refuses an empty or missing decision file, an absent hold, and a drifted retry.
A separate regression drives the real `fm-send` over a stubbed transport to prove the chat channel reaches the same intake for a decision already transferred to its hold, which the status ledger alone can no longer close.

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
ok - pruned resolved history permits later decisions without retention oscillation
ok - pre-boundary retention history requires exact explicit migration
ok - completion provenance distinguishes missing current and historical generations
ok - current generations cannot fall back to older archive owners
ok - current generations cannot fall back to older retained Done owners
ok - current generations cannot fall back to older queued owners
ok - source-verifiable legacy inventories migrate without weakening archive generations
ok - metadata-free completion provenance makes resolved retries idempotent
ok - live completion provenance survives teardown and enforces ownership
ok - queued legacy resolution identity survives teardown and retry
ok - legacy migration rejects missing, conflicting, and foreign ownership
ok - legacy compatibility stays bounded and ambiguous migration requires independent authorization
ok - only canonical retention sections and owned archives prove historical decisions
ok - project-bin retention re-entry emits provenance exactly once
ok - dangling note-archive aliases fail before retention
ok - future archive aliases follow filesystem case semantics
ok - queued holds reject the repair-only resolution mode
ok - retained resolutions enforce the captain decision size bound
ok - pruned-history fallback rejects missing, malformed, and mismatched decisions
ok - historical resolution proof is exact, structured, and home-bound
ok - retained history requires safe state records
ok - origin ownership rejects linked metadata and report evidence
ok - contained operational overrides remain supported
ok - effective contained backlog paths own their derived retention archives
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and secondmate-home captain holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id
ok - a bound channel's captured answers close their captain holds at answer time
ok - immediately pruned answers and exact retries use proven retention history
ok - a channel source with no decision binding closes nothing
ok - the answer path keeps every guard the unrouted close path already had
ok - the chat channel feeds the same keyed-answer intake a captured review does
ok - option-shaped keys and jq-free decision verification stay compatible

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
fm-doc-audience-check: ok surfaces=68 local_links=252

$ git diff --check
(no output)
```
