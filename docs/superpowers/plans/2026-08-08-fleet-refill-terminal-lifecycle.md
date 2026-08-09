# Durable Fleet Refill and Attempt Terminal Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the accepted durable fleet refill and attempt-to-terminal lifecycle design in `docs/architecture.md` (section "Durable implementation capacity and attempt lifecycle design") without a scheduler, daemon, dashboard, wrapper layer, parser, phase machine, or duplicate capacity counter, and without changing the one-attended-invocation normal path.

**Architecture:** One write-once, receipt-derived attempt model per physical delivery effort (immutable envelope, write-once provider/delivery freeze, write-once effect receipts, append-only observation journal, obligations derived solely from missing observed effects, no mutable phase field); one shared capacity classifier (`fm-fleet-capacity.v1`) consuming a structured crew-state contract; one structured cleanup operation shared by terminal orchestration and the existing teardown wrapper, executed inside one non-reentrant outer terminal transaction; one ordered terminal orchestrator; Decision OS beads remain the authority for identity, priority, readiness, dependencies, claims, ownership, and closure. Migration reconciles the local/upstream repository split first, runs the projection shadow-only with measured latency, then introduces envelopes, claims, cleanup, and terminal orchestration, then cuts consumers over only after parity and deletes obsolete machinery after that proof.

**Tech Stack:** bash 5, jq, git worktrees, treehouse pool (`treehouse get --lease --lease-holder`), Orca/`orca worktree`, tmux/herdr/zellij/orca/cmux backends, Decision OS `br` CLI (`br ready --json`, `br show --json` array shape, `br comments add`, `br comments list --json`, `br close`, `br update`) and `scripts/br_worktree_storage.py` (`verify-session --repo --agent`, `preflight --repo --status-out --br-bin`, `claim <id> --repo --agent --br-bin`), `bin/fm-test-run.sh`, `bin/fm-lint.sh`, `bin/fm-doc-audience-check.sh`.

**Task count:** this plan contains exactly 16 tasks, numbered Task 0 through Task 15.

---

## Authority and context

The accepted target is `docs/architecture.md` section "Durable implementation capacity and attempt lifecycle design", which is the design owner and is not modified by this implementation unless the review pass finds a material correction (Task 15 then adds one follow-up docs commit).

Decision OS plan `docs/superpowers/plans/2026-08-05-two-writer-delivery-capacity.md` in the decision-os repository (`/home/holu/decision-os`) Tasks 7.1 through 7.6 remain the project-specific lifecycle authority. This plan composes that authority with the firstmate design; where the two overlap, the firstmate design's ordered composition and migration stages win, and the decision-os Tasks 7.1-7.6 leaf shapes (files, orders, refusal conditions) are implemented verbatim.

### Revision log

- Revision 1 (`9e2d8157c613376ffcf2457eb139c3acb10e2628`) was reviewed by the single canonical review, which concluded REVISE with eight material findings F1-F8 and no captain decision.
- This revision (r2) addresses F1-F8 exactly: write-once receipt-derived attempts with no mutable phase and no parallel obligation files (F1); one outer non-reentrant terminal transaction with lock-held internal primitives (F2); real history reconciliation in Task 0 and shadow-only consumers until post-parity cutover in Task 13 (F3); structured crew-state contract and an enforceable total deadline with valid command ordering (F4); the Decision OS steward transaction rewritten against installed `br`/storage command shapes with a pathspec-only guarded fast-forward transaction (F5); one centralized live disposition reader with fresh per-effect authority and a migration that never conflates bead and forge state (F6); attempt-bound copy ownership, final-landing-receipt semantics with a provisional observation journal, frozen planned-path admission evidence, and a pre-land actual-diff recheck (F7); deterministic parity and forbidden-symbol commands, explicit `fm-brief.sh` wiring, an exhaustive file map, and Tasks 5/8 split into independently testable commits (F8).
- The fleet-depth diagnosis added one more correction, folded into this revision: the active private cron sentinel (`*/20` -> `/home/holu/fmate/firstmate/data/fleet-depth-check.sh`, which reads `state/fleet-manifest.jsonl` and the `/tmp/pi-subagents-1000/...` output paths and appends wake records) is quarantined to alert-only in Task 3, removed with its crontab entry after the Task 13 cutover proof, and verified gone in Task 15 with home-aware `rg -uu` plus crontab inspection.
- The plan now contains exactly 16 tasks (Task 0 through Task 15); Task 5 is split into Tasks 5 and 6, and Task 8 is split into Tasks 8 and 9.
- Per instruction, no further fresh-eyes run is started and no runtime code is implemented by this revision.
- Execution status (2026-08-09): all 95 execution checkboxes are ticked against the recorded acceptance evidence at branch head `d670a84`. The task-to-commit mapping, per-task test and lint runs, and the exhaustive current-head file map are recorded in `docs/verification/fleet-capacity.md` (## Final acceptance); the later no-mistakes review, test-fix, and documentation commits are part of that record.

### Repository ownership facts (Task 0 input)

Verified on 2026-08-08 from the plan branch:

- `git merge-base main origin/main` is `2cf0283b811e81a821cddf5b7f74e1f7de8e2881`.
- Local `main` owns 23 commits absent from `origin/main`, including `acaaf2e feat(fleet): mechanical refill checker - exit 1 = DISPATCH-NEEDED`, `94d4caa feat: encode proactive fleet scaling doctrine`, `651be21`/`71b1e86` serialization-debt probes, `f4ae695` bead closure delivery discipline, `4c3ed17` and `38b4eb6` the two design-doc commits, `015c7dd`, `378b564`, `3472d87`, and `184e07f`.
- `origin/main` owns 17 commits absent from local `main`, including `833a9a2 feat(bin): lint only the changed shard locally`, `be32879`, `167ff42`, `60eb534`, and `06b33aa`.
- Twelve PRs exist on both lines as different SHAs with identical content (for example `193a2fc`/`6c206ed` and `2c924fe`/`345de4e`), so the true content divergence is smaller than the commit counts suggest.
- `bin/fm-fleet-refill.sh` exists only on local `main` (`git cat-file -e origin/main:bin/fm-fleet-refill.sh` fails); it is the fleet-refill behavior the reviewed upstream line lacks.
- `docs/superpowers/` was untracked in this repository; the writing-plans convention plus this task's instruction placed this plan at `docs/superpowers/plans/2026-08-08-fleet-refill-terminal-lifecycle.md`.

Neither history is disposable. Task 0 produces a reviewed canonical integration branch that preserves and reconciles both histories before any runtime work, per the design's migration first step.

### Invariant: no second authority

Decision OS beads stay authoritative for identity, priority, readiness, dependencies, claims, ownership, and closure. The attempt record is coordination state, never a second task tracker. Every attempt binds immutably to one bead id and re-verifies the live bead before claim, allocation, refill selection, terminal reconciliation, and closure. Any missing, stale, multiply claimed, or contradictory authoritative fact preserves ownership and requires reconciliation rather than dispatch or closure. Firstmate caches may carry source identity and revision evidence but never override those authorities. Tracker state (bead status) is never treated as forge evidence (PR merge), and forge evidence is never treated as tracker authority.

### Invariant: write-once, receipt-derived attempt model

The attempt record has no mutable phase field. Lifecycle and obligations are derived solely from the immutable envelope plus the observed effect-receipt set. Provider/delivery fields are written at most once at allocation; identical replay is a no-op and a different replay value refuses. Each effect is observed at most once under its explicit identity; a second different observation refuses and identical replay converges. Provisional observations live in an append-only journal and are never authority. Pending/failed effect states are recorded inside the same attempt record and never satisfy an obligation.

### Invariant: one outer terminal transaction

Terminal reconciliation holds the exact non-reentrant attempt lock from verification through audit publication and retirement. Internal mutations use lock-held primitives that never reacquire. All non-mutating cleanup refusal checks run before any endpoint stop, branch mutation, or provider return.

### Invariant: no legacy arithmetic fallback

Legacy manifests, output paths, output modification times, raw metadata counts, worker text, and private shadow fields never become fallback arithmetic. Consumer decisions stay on legacy behavior until post-parity cutover (Task 13). Deletion of obsolete machinery happens only after that cutover proof (Task 15). The private cron sentinel is quarantined to alert-only through the shadow stage and is removed, with its crontab entry, only after the cutover proof; no wrapper is retained and its historical manifest/next-wave state stays inert unless separately safe. Rollback never restores legacy liveness arithmetic and never converts missing evidence into zero capacity.

---

## File structure map (exhaustive)

New files:

- Create: `bin/fm-attempt-lib.sh` - write-once attempt envelope, write-once effect receipts, append-only observation journal, derived obligations, atomic retirement, lock-held internal primitives. Single owner of schema `fm-attempt.v1`.
- Create: `bin/fm-capacity-lib.sh` - the one shared capacity classifier, emitting schema `fm-fleet-capacity.v1`, consuming `fm-crew-state.sh --json`. Sourced by refill, snapshot, and sentinel at cutover.
- Create: `bin/fm-disposition-lib.sh` - the one centralized live disposition reader (`fm_disposition_live`) and fresh per-effect authority resolver (`fm_authority_for`).
- Create: `bin/fm-br-receipt.sh` - the attended Decision OS main-steward adapter executing the Task 7.4 order against installed `br`/storage contracts.
- Create: `bin/fm-cleanup-lib.sh` - the one structured attempt-bound cleanup operation factored from `bin/fm-teardown.sh`, with lock-held effect writing.
- Create: `bin/fm-terminal.sh` - the sole attempt-to-terminal orchestrator implementing the design's ordered composition inside one outer transaction.
- Create: `bin/fm-attempt-migrate.sh` - stale-record reconciliation in read/reconcile mode using `fm_disposition_live`.
- Create: `bin/fm-refill-sentinel.sh` - the private fleet sentinel (created at cutover, Task 13); consumes the shared object and retains only cadence, candidate query, logging, and notification policy.
- Create: `docs/verification/fleet-capacity.md` - maintainer-verification record for shadow parity, latency, live parity, and acceptance evidence.
- Create: `tests/fm-attempt.test.sh`, `tests/fm-capacity.test.sh`, `tests/fm-disposition.test.sh`, `tests/fm-br-receipt.test.sh`, `tests/fm-cleanup.test.sh`, `tests/fm-terminal.test.sh`, `tests/fm-attempt-migrate.test.sh`, `tests/fm-refill-admission.test.sh`, `tests/fm-refill-sentinel.test.sh`.

Modified files:

- Modify: `bin/fm-fleet-refill.sh` - Task 3 adds `--count-json` and shadow recording with legacy behavior unchanged; Task 12 adds the `--refill` admission action; Task 13 cuts the human verdict over to the shared object and enables the automatic gate; Task 15 deletes the legacy arithmetic.
- Private home artifacts (not tracked): `data/fleet-depth-check.sh` and its `*/20` crontab entry - quarantined to alert-only in Task 3, removed after the Task 13 cutover proof, verified gone in Task 15.
- Modify: `bin/fm-crew-state.sh` - adds `--json` structured output (schema `fm-crew-state.v1`); the existing one-line contract stays for backward compatibility. `bin/fm-crew-state.sh` remains the only semantic worker-state parser.
- Modify: `bin/fm-fleet-snapshot.sh` - Task 13 embeds the exact capacity object; Task 14 adds attempt-state exposure. It never classifies attempts itself.
- Modify: `bin/fm-spawn.sh` - Task 6 claim-before-allocation split handshake, attempt allocation at intake, launch receipt, audit-only ledger; Task 7 attempt-bound provider ownership.
- Modify: `bin/fm-brief.sh` - Task 6 emits the attempt id and the claim-before-allocation requirement into ship briefs.
- Modify: `bin/fm-teardown.sh` - Task 8 sources the extracted cleanup lib with identical behavior; Task 9 becomes the ordinary compatibility wrapper over `fm_cleanup_attempt`.
- Modify: `bin/fm-home-seed.sh` - Task 7 provider-wide lease ownership bound to home and attempt.
- Modify: `bin/fm-backend.sh` - Task 7 provider-wide ownership helpers and `fm_backend_stop_receipt`.
- Modify: `bin/fm-pr-lib.sh`, `bin/fm-pr-check.sh`, `bin/fm-pr-merge.sh`, `bin/fm-pr-poll.sh`, `bin/fm-merge-local.sh` - Task 10 writes provisional observations to the attempt journal; only the disposition step writes the final landing receipt.
- Modify: `bin/fm-session-start.sh`, `bin/fm-watch.sh` - Task 14 exposes attempt receipt-set state, reconciliation need, and obligations on the existing startup and heartbeat paths.
- Modify: `docs/documentation-audiences.json` - classifies this plan as `maintainer-architecture` (shipped with the plan commit) and `docs/verification/fleet-capacity.md` as `maintainer-verification` (shipped with Task 13).

Extended test files:

- `tests/fm-crew-state.test.sh` (structured output), `tests/fm-fleet-refill.test.sh` (shadow, count-json, no-fallback, rollback), `tests/fm-fleet-snapshot-view.test.sh` (exposure, cutover embed, byte parity), `tests/fm-spawn-worktree-settle.test.sh` (handshake, same-home collision), `tests/fm-brief.test.sh` (attempt wiring), `tests/fm-secondmate-safety.test.sh`, `tests/fm-backend-orca.test.sh` (provider claims), `tests/fm-teardown.test.sh`, `tests/fm-teardown-endpoint-safety.test.sh` (extraction identity, wrapper identity), `tests/fm-pr-check-security.test.sh`, `tests/fm-pr-merge.test.sh` (observations and final landing receipt), `tests/fm-backlog-handoff.test.sh`, `tests/fm-session-start.test.sh`, `tests/fm-watch-triage.test.sh` (recovery/exposure).

---

## Task 0: Real history reconciliation

F3 correction. The canonical integration base is produced and reviewed here, before any runtime work.

**Files:**

- No tracked firstmate file changes in this task. The reconciliation is a git operation plus the canonical review; evidence is recorded in the merge commit message and the review packet.

**Context:** local `main` and `origin/main` diverged at `2cf0283b`. Local `main` owns `bin/fm-fleet-refill.sh` and the accepted design; upstream owns five other commits. Both histories are preserved and reconciled onto one reviewed base.

- [x] **Step 1: Verify both histories and the script ownership**

Run:

```bash
git fetch origin
git merge-base main origin/main
git log --oneline --no-merges origin/main..main | cat
git log --oneline --no-merges main..origin/main | cat
git cat-file -e origin/main:bin/fm-fleet-refill.sh && echo "origin has it" || echo "origin does not have it"
```

Expected: merge-base `2cf0283b811e81a821cddf5b7f74e1f7de8e2881`; local-only list contains `acaaf2e`, `94d4caa`, `4c3ed17`, `38b4eb6`; origin-only list contains `833a9a2`, `be32879`, `167ff42`, `60eb534`, `06b33aa`; `origin does not have it`.

- [x] **Step 2: Create the reviewed canonical integration branch**

In a dedicated worktree of the firstmate repo:

```bash
git worktree add /tmp/fm-integration-base -b fm/fleet-refill-integration-base main
cd /tmp/fm-integration-base
git merge --no-ff origin/main -m "reconcile(fleet): merge origin/main onto the fleet-refill integration base

Local main owns bin/fm-fleet-refill.sh and the accepted fleet lifecycle design
(merge-base 2cf0283b). Both histories are preserved: this merge keeps every
local-only commit (refill, serialization probes, design docs, calm footer,
bead closure discipline) and every upstream-only commit (833a9a2, be32879,
167ff42, 60eb534, 06b33aa). The twelve duplicated PRs resolve as identical
content. fm-fleet-refill.sh is preserved from the local side."
```

Resolve any conflict by keeping local content for local-only features and upstream content for upstream-only features; never drop a commit from either side.

- [x] **Step 3: Prove the reconciled base is green and owns the script**

Run:

```bash
git cat-file -e HEAD:bin/fm-fleet-refill.sh && echo "refill preserved"
git log --oneline main..HEAD | grep -q "reconcile(fleet)" && echo "merge recorded"
git merge-base --is-ancestor main HEAD && echo "local main contained"
git merge-base --is-ancestor origin/main HEAD && echo "origin main contained"
bin/fm-test-run.sh --all
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

Expected: `refill preserved`, `merge recorded`, `local main contained`, `origin main contained`, full suite green, lint clean, doc-audience clean.

- [x] **Step 4: Review the integration branch before Task 1**

Submit the integration branch through the canonical `review.sh` pass and require a clean verdict before Task 1 proceeds. The review must confirm both histories are preserved and the refill script is reconciled.

- [x] **Step 5: Record the base and commit the decision record**

Record the reviewed integration base SHA in the implementation PR description and in `docs/verification/fleet-capacity.md` (created in Task 3) under `## Integration base`. No code change on the plan branch; the plan branch stays a clean fast-forward onto local `main`.

---

## Task 1: Write-once, receipt-derived attempt model

F1 correction plus the decision-os Task 7.1 leaf. There is no mutable phase; lifecycle and obligations derive solely from the envelope plus observed effects.

**Files:**

- Create: `bin/fm-attempt-lib.sh`
- Create: `tests/fm-attempt.test.sh`

- [x] **Step 1: Write the failing tests**

Create `tests/fm-attempt.test.sh`:

```bash
#!/usr/bin/env bash
# Public-interface tests for the write-once, receipt-derived attempt model:
# immutable envelope, write-once provider/delivery freeze, write-once effect
# receipts, append-only observation journal, derived obligations, atomic
# retirement with the complete set, stale-generation and torn-publication
# safety, and non-reentrant lock-held primitives.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-attempt)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

test_alloc_roundtrips_envelope() {
  local aid gen
  aid=$(fm_attempt_alloc pi dos-a holu) || fail "alloc failed"
  assert_contains "$aid" "dos-a-a1" "attempt id shape"
  gen=$(fm_attempt_generation "$aid") || fail "load failed"
  [ "$gen" = 1 ] || fail "generation was $gen"
  fm_attempt_load "$aid" | jq -e '.envelope.task_source == "pi" and .envelope.home_id == "holu"' >/dev/null \
    || fail "envelope did not round-trip"
  pass "attempt alloc round-trips the immutable envelope"
}

test_concurrent_allocation_one_winner() {
  local a b
  a=$(fm_attempt_alloc pi dos-a holu) || fail "first alloc"
  b=$(fm_attempt_alloc pi dos-a holu) || fail "second alloc"
  [ "$a" != "$b" ] || fail "duplicate attempt id: $a"
  assert_contains "$b" "dos-a-a2" "monotonic generation"
  pass "concurrent allocation yields distinct ids with one winner per generation"
}

test_effect_observe_is_write_once() {
  local aid
  aid=$(fm_attempt_alloc pi dos-b holu)
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-b","status":"claimed"}' || fail "first observe"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-b","status":"claimed"}' || fail "identical replay refused"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-b","status":"claimed-again"}' \
    && fail "second different observation accepted"
  [ "$(fm_attempt_load "$aid" | jq '.receipts.claim | length')" = 1 ] || fail "receipt not write-once"
  pass "an effect is observed at most once; identical replay converges, contradiction refuses"
}

test_freeze_allocation_is_write_once() {
  local aid
  aid=$(fm_attempt_alloc pi dos-c holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' \
    || fail "identical replay refused"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-OTHER"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' \
    && fail "different replay value accepted"
  [ "$(fm_attempt_load "$aid" | jq -r '.provider.copy')" = wt-c ] || fail "provider rewritten"
  pass "provider and delivery freeze once; replay equality is a no-op and different replay refuses"
}

test_obligations_derive_from_missing_observed_effects() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-d holu)
  out=$(fm_attempt_obligations "$aid")
  assert_contains "$out" "claim" "claim obligation missing"
  assert_contains "$out" "provider" "provider obligation missing"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-d","status":"claimed"}' || fail "claim"
  out=$(fm_attempt_obligations "$aid")
  assert_not_contains "$out" "claim" "claim obligation not cleared"
  pass "named obligations derive solely from missing observed effects"
}

test_landed_retirement_requires_complete_set() {
  local aid
  aid=$(fm_attempt_alloc pi dos-e holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-e"}' \
    '{"mode":"no-mistakes","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-e","status":"claimed"}' || fail "claim"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-e"}' || fail "launch"
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal","disposition":"landed"}' \
    && fail "retirement without tracker and cleanup accepted"
  [ "$(fm_attempt_is_retired "$aid")" = 0 ] || fail "attempt retired illegally"
  fm_attempt_effect_observe "$aid" 1 tracker '{"bead":"dos-e","status":"closed"}' || fail "tracker"
  fm_attempt_effect_observe "$aid" 1 cleanup.endpoint '{"endpoint":"w-e","gone":true}' || fail "endpoint"
  fm_attempt_effect_observe "$aid" 1 cleanup.branch '{"fate":"deleted"}' || fail "branch"
  fm_attempt_effect_observe "$aid" 1 cleanup.provider '{"returned":true}' || fail "provider"
  fm_attempt_effect_observe "$aid" 1 cleanup.runtime '{"records_removed":true}' || fail "runtime"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal","disposition":"landed"}' || fail "retirement refused"
  [ "$(fm_attempt_is_retired "$aid")" = 0 ] || fail "not retired"
  [ -z "$(fm_attempt_obligations "$aid")" ] || fail "retired attempt has obligations"
  pass "retirement requires the complete effect set; after retirement obligations are empty"
}

test_refused_claim_has_no_further_obligations() {
  local aid
  aid=$(fm_attempt_alloc pi dos-f holu)
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-f","status":"refused"}' || fail "refused claim"
  [ -z "$(fm_attempt_obligations "$aid")" ] || fail "refused claim kept obligations"
  fm_attempt_retire "$aid" 1 '{"audit":"failed-pre-allocation"}' || fail "failed pre-allocation not retired"
  pass "a conclusively refused claim with no provider copy is retired as failed pre-allocation"
}

test_stale_generation_cannot_mutate() {
  local aid
  aid=$(fm_attempt_alloc pi dos-g holu)
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-g","status":"claimed"}' || fail "fresh observe"
  fm_attempt_effect_observe "$aid" 2 claim '{"bead":"dos-g","status":"claimed"}' \
    && fail "stale generation observed"
  fm_attempt_freeze_allocation "$aid" 2 '{"provider":"tmux","copy":"wt-g"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' \
    && fail "stale generation froze allocation"
  pass "a stale generation cannot mutate the current attempt"
}

test_torn_publication_replays_converged() {
  local aid
  aid=$(fm_attempt_alloc pi dos-h holu)
  # simulate a torn write: an attempt file whose .tmp sibling never mv'd and a
  # stale generation field; a replay must converge on the receipts already
  # present without losing them
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-h","status":"claimed"}' || fail "claim"
  cp "$STATE/attempts/$aid.json" "$TMP_ROOT/before.json"
  fm_attempt_effect_observe "$aid" 1 claim '{"bead":"dos-h","status":"claimed"}' || fail "replay"
  cmp -s "$STATE/attempts/$aid.json" "$TMP_ROOT/before.json" || fail "replay mutated the record"
  pass "torn-publication replay converges on the existing receipts"
}

test_lock_held_primitives_never_reacquire() {
  local aid
  aid=$(fm_attempt_alloc pi dos-i holu)
  fm_attempt_lock_acquire "$aid" || fail "first acquire"
  fm_attempt_lock_acquire "$aid" && fail "nested acquire succeeded"
  fm_attempt_effect_observe_held "$aid" 1 claim '{"bead":"dos-i","status":"claimed"}' || fail "held observe"
  fm_attempt_lock_release "$aid"
  fm_attempt_lock_acquire "$aid" || fail "reacquire after release"
  fm_attempt_lock_release "$aid"
  pass "the attempt lock is non-reentrant and held primitives never reacquire"
}

test_observation_journal_is_append_only() {
  local aid n
  aid=$(fm_attempt_alloc pi dos-j holu)
  fm_attempt_observe "$aid" 1 forge '{"state":"open"}' || fail "first observation"
  fm_attempt_observe "$aid" 1 forge '{"state":"merged","head":"abc123"}' || fail "second observation"
  n=$(fm_attempt_load "$aid" | jq '.observations | length')
  [ "$n" = 2 ] || fail "observation journal not append-only: $n"
  pass "provisional observations append to a journal and are never authority"
}

test_alloc_roundtrips_envelope
test_concurrent_allocation_one_winner
test_effect_observe_is_write_once
test_freeze_allocation_is_write_once
test_obligations_derive_from_missing_observed_effects
test_landed_retirement_requires_complete_set
test_refused_claim_has_no_further_obligations
test_stale_generation_cannot_mutate
test_torn_publication_replays_converged
test_lock_held_primitives_never_reacquire
test_observation_journal_is_append_only
```

- [x] **Step 2: Run the test to verify it fails**

Run: `bash tests/fm-attempt.test.sh`
Expected: FAIL with `fm_attempt_alloc: command not found`.

- [x] **Step 3: Write the minimal implementation**

Create `bin/fm-attempt-lib.sh`:

```bash
#!/usr/bin/env bash
# Durable delivery-attempt identity, write-once and receipt-derived.
#
# Single owner of schema fm-attempt.v1: the immutable envelope
# {task_source, task_key, home_id, attempt_id, generation}; write-once
# provider/delivery fields frozen at allocation; effect receipts where each
# effect is observed at most once under its explicit identity (identical
# replay is a no-op, a second different observation refuses); an append-only
# observations journal for provisional evidence that is never authority; and
# named obligations derived solely from missing observed effects. There is NO
# mutable phase field; lifecycle helpers derive from the envelope plus the
# observed effect set.
#
# This record is coordination state only. Decision OS beads remain task truth;
# this file never mirrors live bead state, semantic worker state, endpoint
# liveness, Git refs, cleanliness, ancestry, or forge status.
#
# Records live under $FM_STATE_OVERRIDE/attempts/<attempt_id>.json when
# FM_STATE_OVERRIDE is set (tests), else $FM_HOME/state/attempts/. All
# mutations happen under the attempt lock using the shared primitives from
# bin/fm-wake-lib.sh (fm_lock_try_acquire / fm_lock_release), which are
# non-reentrant: internal _held variants never reacquire. Publication is
# write-temp-then-mv.

set -u

attempts_dir() {
  printf '%s/attempts' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

attempt_path() {  # <attempt_id>
  printf '%s/%s.json' "$(attempts_dir)" "$1"
}

attempt_lock() {  # <attempt_id>
  printf '%s/.%s.lock' "$(attempts_dir)" "$1"
}

# shellcheck disable=SC2034
FM_ATTEMPT_LIB_SOURCED=1

fm_attempt_alloc() {  # <task_source> <task_key> <home_id> -> prints <attempt_id>
  local task_source=$1 task_key=$2 home_id=$3
  local dir gen attempt_id tmp f g
  dir="$(attempts_dir)"
  mkdir -p "$dir"
  fm_lock_try_acquire "$dir/.alloc.lock" || {
    echo "attempt-alloc: allocation lock busy" >&2
    return 1
  }
  gen=0
  for f in "$dir"/"$task_key"-a*.json; do
    [ -e "$f" ] || continue
    g=${f##*-a}
    g=${g%.json}
    case "$g" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$g" -gt "$gen" ] && gen=$g
  done
  gen=$((gen + 1))
  attempt_id="$task_key-a$gen"
  tmp="$dir/.$attempt_id.tmp.$$"
  jq -n \
    --arg schema fm-attempt.v1 \
    --arg task_source "$task_source" --arg task_key "$task_key" \
    --arg home_id "$home_id" --arg attempt_id "$attempt_id" \
    --argjson generation "$gen" \
    '{schema:$schema,envelope:{task_source:$task_source,task_key:$task_key,home_id:$home_id,attempt_id:$attempt_id,generation:$generation},receipts:{},observations:[],created_at:(now|todateiso8601)}' \
    > "$tmp" || { fm_lock_release "$dir/.alloc.lock"; return 1; }
  mv -f "$tmp" "$(attempt_path "$attempt_id")" || {
    fm_lock_release "$dir/.alloc.lock"
    return 1
  }
  fm_lock_release "$dir/.alloc.lock"
  printf '%s\n' "$attempt_id"
}

fm_attempt_load() {  # <attempt_id> -> JSON on stdout; nonzero when absent
  local f
  f="$(attempt_path "$1")"
  [ -f "$f" ] || return 1
  cat "$f"
}

fm_attempt_generation() {  # <attempt_id>
  fm_attempt_load "$1" | jq -r '.envelope.generation'
}

# --- lock ownership (non-reentrant) ----------------------------------------

fm_attempt_lock_acquire() {  # <attempt_id>
  fm_lock_try_acquire "$(attempt_lock "$1")"
}

fm_attempt_lock_release() {  # <attempt_id>
  fm_lock_release "$(attempt_lock "$1")"
}

# --- lock-held internal primitives (never reacquire) -----------------------

fm_attempt_generation_held() {  # <attempt_id>
  fm_attempt_load "$1" | jq -r '.envelope.generation'
}

fm_attempt_effect_observe_held() {  # <attempt_id> <generation> <name> <evidence-json>
  local attempt=$1 gen=$2 name=$3 evidence=$4
  local path tmp live_gen seq existing_evidence
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation: $attempt expects gen $gen, record is gen $live_gen" >&2
    return 1
  }
  # write-once: an existing observed entry with different evidence refuses;
  # identical replay is a no-op
  existing_evidence=$(jq -r --arg name "$name" \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence // ""' "$path")
  if [ -n "$existing_evidence" ]; then
    if [ "$existing_evidence" = "$evidence" ]; then
      return 0
    fi
    echo "contradiction: effect $name already observed on $attempt with different evidence" >&2
    return 1
  fi
  seq=$(jq -r --arg name "$name" '[.receipts[$name][]? | .seq] | (max // 0) + 1' "$path")
  tmp="$attempts_dir/.$attempt.tmp.$$"
  jq --arg name "$name" --argjson seq "$seq" --argjson evidence "$evidence" \
    '.receipts[$name] += [{seq:$seq,state:"observed",generation:.envelope.generation,observed_at:(now|todateiso8601),evidence:$evidence}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_effect_pending_held() {  # <attempt_id> <generation> <name> <reason-json>
  local attempt=$1 gen=$2 name=$3 reason=$4
  local path tmp live_gen seq
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || return 1
  seq=$(jq -r --arg name "$name" '[.receipts[$name][]? | .seq] | (max // 0) + 1' "$path")
  tmp="$attempts_dir/.$attempt.tmp.$$"
  jq --arg name "$name" --argjson seq "$seq" --argjson reason "$reason" \
    '.receipts[$name] += [{seq:$seq,state:"pending",generation:.envelope.generation,observed_at:(now|todateiso8601),reason:$reason}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_freeze_allocation_held() {  # <attempt_id> <generation> <provider-json> <delivery-json>
  local attempt=$1 gen=$2 provider=$3 delivery=$4
  local path tmp live_gen existing_p existing_d
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation at freeze: $attempt" >&2
    return 1
  }
  existing_p=$(jq -r '.provider // empty' "$path")
  existing_d=$(jq -r '.delivery // empty' "$path")
  if [ -n "$existing_p" ] || [ -n "$existing_d" ]; then
    if [ "$existing_p" = "$provider" ] && [ "$existing_d" = "$delivery" ]; then
      return 0
    fi
    echo "contradiction: provider/delivery already frozen on $attempt with different values" >&2
    return 1
  fi
  tmp="$attempts_dir/.$attempt.tmp.$$"
  jq --argjson provider "$provider" --argjson delivery "$delivery" \
    '.provider=$provider | .delivery=$delivery' "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_observe_held() {  # <attempt_id> <generation> <name> <evidence-json> (journal)
  local attempt=$1 gen=$2 name=$3 evidence=$4
  local path tmp live_gen
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || return 1
  tmp="$attempts_dir/.$attempt.tmp.$$"
  jq --arg name "$name" --argjson evidence "$evidence" \
    '.observations += [{name:$name,observed_at:(now|todateiso8601),generation:.envelope.generation,evidence:$evidence}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

fm_attempt_obligations_held() {  # <attempt_id> -> missing observed effect names
  local attempt=$1 disp required
  # derived solely from receipts; no phase
  disp=$(jq -r --arg name landing \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence.disposition // ""' \
    "$(attempt_path "$attempt")")
  if jq -e --arg name claim \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence.status == "refused"' \
    "$(attempt_path "$attempt")" >/dev/null 2>&1; then
    return 0
  fi
  required="claim provider launch landing"
  case "$disp" in
    landed) required="$required tracker cleanup.endpoint cleanup.branch cleanup.provider cleanup.runtime" ;;
    preserved_unlanded) required="$required cleanup.endpoint cleanup.branch cleanup.preservation cleanup.provider cleanup.runtime" ;;
  esac
  jq -r --argjson required "$(printf '%s' "$required" | jq -R 'split(" ")')" \
    '. as $root |
     [ $required[] as $name | select(([$root.receipts[$name][]? | select(.state == "observed")] | length) == 0) | $name ] | join(" ")' \
    "$(attempt_path "$attempt")"
}

fm_attempt_retire_held() {  # <attempt_id> <generation> <audit-json>
  local attempt=$1 gen=$2 audit=$3
  local path tmp live_gen missing seq
  path="$(attempt_path "$attempt")"
  live_gen=$(fm_attempt_generation_held "$attempt") || return 1
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation at retirement: $attempt" >&2
    return 1
  }
  missing=$(fm_attempt_obligations_held "$attempt")
  [ -z "$missing" ] || {
    echo "retirement blocked: missing observed effects: $missing" >&2
    return 1
  }
  seq=$(jq -r --arg name retirement '[.receipts[$name][]? | .seq] | (max // 0) + 1' "$path")
  tmp="$attempts_dir/.$attempt.tmp.$$"
  jq --argjson seq "$seq" --argjson audit "$audit" \
    '.receipts.retirement += [{seq:$seq,state:"observed",generation:.envelope.generation,observed_at:(now|todateiso8601),evidence:$audit}]' \
    "$path" > "$tmp" || return 1
  mv -f "$tmp" "$path" || return 1
}

# --- public wrappers (acquire once, call held, release) --------------------

fm_attempt_effect_observe() {  # <attempt_id> <generation> <name> <evidence-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_effect_observe_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_effect_pending() {  # <attempt_id> <generation> <name> <reason-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_effect_pending_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_freeze_allocation() {  # <attempt_id> <generation> <provider-json> <delivery-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_freeze_allocation_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_observe() {  # <attempt_id> <generation> <name> <evidence-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_observe_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_retire() {  # <attempt_id> <generation> <audit-json>
  local attempt=$1 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_retire_held "$@"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

fm_attempt_obligations() {  # <attempt_id>
  local attempt=$1
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_attempt_obligations_held "$attempt"
  local rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

# --- derived lifecycle helpers (no mutable phase) --------------------------

fm_attempt_is_allocated() {  # 0 when the provider effect is observed
  jq -e --arg name provider \
    '[.receipts[$name][]? | select(.state == "observed")] | length > 0' \
    "$(attempt_path "$1")" >/dev/null 2>&1
}

fm_attempt_is_launched() {  # 0 when the launch effect is observed
  jq -e --arg name launch \
    '[.receipts[$name][]? | select(.state == "observed")] | length > 0' \
    "$(attempt_path "$1")" >/dev/null 2>&1
}

fm_attempt_is_retired() {  # 0 when the retirement effect is observed
  jq -e --arg name retirement \
    '[.receipts[$name][]? | select(.state == "observed")] | length > 0' \
    "$(attempt_path "$1")" >/dev/null 2>&1
}

fm_attempt_landing_disposition() {  # prints landed | preserved_unlanded | unknown | ""
  jq -r --arg name landing \
    '[.receipts[$name][]? | select(.state == "observed")][0].evidence.disposition // ""' \
    "$(attempt_path "$1")" 2>/dev/null || true
}
```

Note: the `fm_attempt_effect_observe_held` contradiction check compares the stored observed evidence to the incoming evidence as raw JSON strings. The implementer must normalize both sides through `jq -cS` before comparison so semantically identical evidence (key order differences) counts as replay equality; the `test_effect_observe_is_write_once` fixture pins the normalized comparison.

- [x] **Step 4: Run the tests to verify they pass**

Run: `bash tests/fm-attempt.test.sh`
Expected: eleven `ok -` lines, no failures.

- [x] **Step 5: Verify shellcheck**

Run: `shellcheck bin/fm-attempt-lib.sh`
Expected: clean.

- [x] **Step 6: Commit**

```bash
git add bin/fm-attempt-lib.sh tests/fm-attempt.test.sh
git commit -m "feat(attempts): add write-once receipt-derived attempt identity"
```

---

## Task 2: Structured crew-state contract and the shared projection with a real total deadline

F4 correction. The capacity classifier consumes a structured contract, never reparses display text, and enforces a real global deadline.

**Files:**

- Modify: `bin/fm-crew-state.sh` (add `--json`)
- Create: `bin/fm-capacity-lib.sh`
- Create: `tests/fm-capacity.test.sh`
- Extend: `tests/fm-crew-state.test.sh`

- [x] **Step 1: Write the failing tests**

Extend `tests/fm-crew-state.test.sh`:

```bash
test_structured_json_contract() {
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-crew-state.sh" --json "$ID" 2>/dev/null)
  echo "$out" | jq -e '.schema == "fm-crew-state.v1" and (.state | type == "string") and (.source | type == "string")' >/dev/null \
    || fail "structured contract malformed: $out"
  echo "$out" | jq -e '.id == "'"$ID"'"' >/dev/null || fail "id missing"
  pass "fm-crew-state --json emits the structured contract"
}

test_structured_contract_matches_display_line() {
  local line out
  line=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-crew-state.sh" "$ID" 2>/dev/null | head -1)
  out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-crew-state.sh" --json "$ID" 2>/dev/null)
  local s; s=$(echo "$out" | jq -r '.state')
  case "$line" in
    "state: $s"*) pass "structured state matches the display line" ;;
    *) fail "structured state $s disagrees with display line: $line" ;;
  esac
}
```

Create `tests/fm-capacity.test.sh` with the capacity fixtures plus the total-deadline and malformed-structured-output fixtures:

```bash
#!/usr/bin/env bash
# Public-interface tests for the one shared capacity projection
# (fm-fleet-capacity.v1). Fixtures: implementation, validation, merge wait,
# terminal states, ambiguity, per-row timeout, total deadline, disappearing
# and torn records, malformed structured output, scouts, second mates, schema
# failure, and retirement-before-projection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-capacity)
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
mkdir -p "$STATE" "$DATA"

export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"
export FM_CAPACITY_READ_TIMEOUT_SECS=2
export FM_CAPACITY_TOTAL_TIMEOUT_SECS=10
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$ROOT/bin/fm-capacity-lib.sh"

write_meta() {  # <id> <kind> <mode> [attempt=]
  local id=$1 kind=$2 mode=$3 extra=${4:-}
  {
    printf 'window=w-%s\n' "$id"
    printf 'kind=%s\n' "$kind"
    printf 'mode=%s\n' "$mode"
    printf 'worktree=%s/wt-%s\n' "$TMP_ROOT" "$id"
    [ -z "$extra" ] || printf '%s\n' "$extra"
  } > "$STATE/$id.meta"
}

fake_crew_state() {  # writes a fake fm-crew-state.sh that emits the given structured JSON
  cat > "$TMP_ROOT/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$1'
SH
  chmod +x "$TMP_ROOT/fm-crew-state.sh"
}

test_implementation_is_productive_and_reserved() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-a holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-x"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w1"}' || fail "launch"
  write_meta "task-x" ship direct-PR "attempt=$aid"
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"task-x","state":"working","source":"run-step","detail":"validating x"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 1' >/dev/null || fail "productive != 1"
  echo "$out" | jq -e '.aggregate.reserved_ownership_count == 1' >/dev/null || fail "reserved != 1"
  echo "$out" | jq -e '.aggregate.refill_safe == true' >/dev/null || fail "not refill safe"
  pass "active implementation is productive and reserved"
}

test_merge_wait_stays_reserved() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-b holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-y"}' \
    '{"mode":"no-mistakes","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w2"}' || fail "launch"
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  write_meta "task-y" ship no-mistakes "attempt=$aid"
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"task-y","state":"done","source":"status-log","detail":"done: PR checks green"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 0' >/dev/null || fail "merge wait counted productive"
  echo "$out" | jq -e '.aggregate.reserved_ownership_count == 1' >/dev/null || fail "merge wait not reserved"
  echo "$out" | jq -e '.aggregate.reconciliation_required == true' >/dev/null || fail "merge wait did not need reconciliation"
  pass "merge-waiting delivery stays reserved until retirement"
}

test_retired_attempt_contributes_nothing() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-c holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-z"}' \
    '{"mode":"local-only","base":"main","target":"local-main"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w3"}' || fail "launch"
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","local_main":"abc123"}' || fail "landing"
  fm_attempt_effect_observe "$aid" 1 tracker '{"bead":"dos-c","status":"closed"}' || fail "tracker"
  fm_attempt_effect_observe "$aid" 1 cleanup.endpoint '{"endpoint":"w3","gone":true}' || fail "endpoint"
  fm_attempt_effect_observe "$aid" 1 cleanup.branch '{"fate":"deleted"}' || fail "branch"
  fm_attempt_effect_observe "$aid" 1 cleanup.provider '{"returned":true}' || fail "provider"
  fm_attempt_effect_observe "$aid" 1 cleanup.runtime '{"records_removed":true}' || fail "runtime"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal","disposition":"landed"}' || fail "retire"
  write_meta "task-z" ship local-only "attempt=$aid"
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"task-z","state":"done","source":"status-log","detail":"done: ready in branch"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 0 and .aggregate.reserved_ownership_count == 0' >/dev/null \
    || fail "retired attempt still counted"
  pass "only an atomically retired attempt contributes neither productive nor reserved capacity"
}

test_legacy_row_without_envelope_needs_reconciliation() {
  local out
  write_meta "legacy-1" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"legacy-1","state":"working","source":"pane","detail":"busy"}'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.rows[0].ambiguity_reasons | index("missing_attempt_envelope") != null' >/dev/null \
    || fail "legacy row did not name missing envelope"
  echo "$out" | jq -e '.aggregate.reconciliation_required == true' >/dev/null || fail "no reconciliation flag"
  pass "legacy task without an envelope is ambiguous and requires reconciliation"
}

test_scout_and_secondmate_are_excluded() {
  local out
  write_meta "scout-1" scout direct-PR
  write_meta "sm-1" secondmate direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"scout-1","state":"working","source":"run-step","detail":"investigating"}'
  out=$(fm_capacity_project)
  [ "$(echo "$out" | jq '.rows | length')" = 0 ] || fail "scouts/secondmates appeared in rows"
  pass "scouts and persistent second mates are excluded from implementation capacity"
}

test_per_row_timeout_yields_ambiguous_row() {
  local out
  write_meta "slow-1" ship direct-PR
  cat > "$TMP_ROOT/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$TMP_ROOT/fm-crew-state.sh"
  out=$(FM_CAPACITY_READ_TIMEOUT_SECS=1 fm_capacity_project)
  echo "$out" | jq -e '.aggregate.observation_complete == false' >/dev/null || fail "timeout looked complete"
  echo "$out" | jq -e '.aggregate.alert_only == true' >/dev/null || fail "incomplete observation was not alert-only"
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null || fail "refill considered safe on timeout"
  pass "a timed-out worker read yields an ambiguous row and alert-only refill"
}

test_total_deadline_marks_unfinished_rows_ambiguous() {
  local out
  write_meta "slow-a" ship direct-PR
  write_meta "slow-b" ship direct-PR
  cat > "$TMP_ROOT/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$TMP_ROOT/fm-crew-state.sh"
  out=$(FM_CAPACITY_READ_TIMEOUT_SECS=30 FM_CAPACITY_TOTAL_TIMEOUT_SECS=1 fm_capacity_project)
  echo "$out" | jq -e '.aggregate.observation_complete == false' >/dev/null || fail "total deadline ignored"
  echo "$out" | jq -e '[.rows[] | select(.ambiguity_reasons | index("worker_read_timeout") != null)] | length >= 2' >/dev/null \
    || fail "unfinished rows not deterministically ambiguous"
  pass "the total deadline marks every unfinished row ambiguous and incomplete"
}

test_disappearing_record_is_ambiguous() {
  local out
  write_meta "gone-1" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"gone-1","state":"working","source":"run-step","detail":"busy"}'
  # FM_CAPACITY_TEST_DISAPPEAR simulates a torn read: the record vanishes
  # between listing and row read
  out=$(FM_CAPACITY_TEST_DISAPPEAR=gone-1 fm_capacity_project)
  echo "$out" | jq -e --arg id gone-1 \
    '[.rows[] | select(.task_key == $id) | .ambiguity_reasons | index("record_disappeared") != null] | any' >/dev/null \
    || fail "disappearing record not ambiguous"
  echo "$out" | jq -e --arg id gone-1 \
    '[.rows[] | select(.task_key == $id) | .reserved == true] | any' >/dev/null \
    || fail "disappearing record became a free slot"
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null \
    || fail "disappearing record looked refill-safe"
  pass "a disappearing record yields an ambiguous reserved row, never a free slot or zero capacity"
}

test_malformed_structured_output_is_ambiguous() {
  local out
  write_meta "bad-1" ship direct-PR
  fake_crew_state 'this is not json'
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.alert_only == true' >/dev/null || fail "malformed output not alert-only"
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null || fail "malformed output looked refill-safe"
  pass "malformed structured worker output yields ambiguity, never idle or zero work"
}

test_schema_failure_is_alert_only() {
  local out
  write_meta "bad-2" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"bad-2","state":"working","source":"run-step","detail":"busy"}'
  out=$(FM_CAPACITY_FORCE_SCHEMA_MISMATCH=1 fm_capacity_project 2>/dev/null || true)
  echo "$out" | jq -e '.schema == "fm-fleet-capacity.v1"' >/dev/null || fail "schema changed"
  echo "$out" | jq -e '.schema_ok == false and .alert_only == true and .aggregate.refill_safe == false' >/dev/null \
    || fail "schema mismatch did not make consumers alert-only"
  pass "a schema mismatch makes both automatic consumers alert-only while preserving ownership"
}

test_aggregates_are_exactly_derivable_from_rows() {
  local out derived
  write_meta "r1" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"r1","state":"blocked","source":"status-log","detail":"blocked: need credential"}'
  out=$(fm_capacity_project)
  derived=$(echo "$out" | jq '{pc:([.rows[]|select(.productive)]|length),rc:([.rows[]|select(.reserved)]|length),ac:([.rows[]|select((.ambiguity_reasons|length)>0)]|length)}')
  echo "$out" | jq -e --argjson d "$derived" \
    '.aggregate.productive_count == $d.pc and .aggregate.reserved_ownership_count == $d.rc and .aggregate.ambiguous_count == $d.ac' >/dev/null \
    || fail "aggregate not derivable from rows: $derived"
  pass "every aggregate is exactly derivable from the emitted rows"
}

test_parallel_reads_are_byte_identical() {
  local a b
  write_meta "p1" ship direct-PR
  write_meta "p2" ship direct-PR
  fake_crew_state '{"schema":"fm-crew-state.v1","id":"p1","state":"working","source":"run-step","detail":"busy"}'
  a=$(fm_capacity_project | jq -cS .)
  b=$(FM_CAPACITY_PARALLEL=4 fm_capacity_project | jq -cS .)
  [ "$a" = "$b" ] || fail "parallel projection differs from sequential"
  pass "bounded parallel reads produce byte-identical output to sequential reads"
}

test_implementation_is_productive_and_reserved
test_merge_wait_stays_reserved
test_retired_attempt_contributes_nothing
test_legacy_row_without_envelope_needs_reconciliation
test_scout_and_secondmate_are_excluded
test_per_row_timeout_yields_ambiguous_row
test_total_deadline_marks_unfinished_rows_ambiguous
test_disappearing_record_is_ambiguous
test_malformed_structured_output_is_ambiguous
test_schema_failure_is_alert_only
test_aggregates_are_exactly_derivable_from_rows
test_parallel_reads_are_byte_identical
```

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-crew-state.test.sh; bash tests/fm-capacity.test.sh`
Expected: FAIL on the new tests (`--json` unrecognized, `fm_capacity_project: command not found`).

- [x] **Step 3: Add `--json` to `bin/fm-crew-state.sh`**

Modify `bin/fm-crew-state.sh` so that when the first argument is `--json`, the emit function prints one structured object:

```bash
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  if [ "${FM_CREW_STATE_JSON:-0}" = 1 ]; then
    jq -n --arg schema fm-crew-state.v1 --arg id "$ID" \
      --arg state "$1" --arg source "$2" --arg detail "${3:-}" \
      '{schema:$schema,id:$id,state:$state,source:$source,detail:$detail,raw:$line}'
    exit 0
  fi
  printf '%s\n' "$line"
  exit 0
}
```

and at the top of the script set `FM_CREW_STATE_JSON=1` when `$1` is `--json` and shift. The one-line contract stays the default output; `bin/fm-crew-state.sh` remains the only semantic worker-state parser. The `SEP` separator and the exact state vocabulary are owned by this script alone.

- [x] **Step 4: Write the minimal `bin/fm-capacity-lib.sh`**

```bash
#!/usr/bin/env bash
# The one shared capacity and attempt projection (schema fm-fleet-capacity.v1).
#
# This library is the ONLY classifier of implementation rows and aggregate
# capacity. It consumes the structured fm-crew-state.v1 contract from
# bin/fm-crew-state.sh --json and combines it with the attempt envelope and
# effect receipts from bin/fm-attempt-lib.sh. It never reparses display text,
# defines no second worker state machine, and never reads legacy manifests,
# output paths, output modification times, raw metadata counts, worker text,
# or private shadow fields.
#
# Consumers: bin/fm-fleet-refill.sh (--count-json and, after Task 13, the
# human verdict), bin/fm-fleet-snapshot.sh (Task 13 embed), and
# bin/fm-refill-sentinel.sh (Task 13). All consume the exact object emitted
# here. FM_CAPACITY_OBSERVATION_FILE, when set, makes the projection emit that
# exact frozen object so parity tests and consumers share one observation.

set -u

FM_CAPACITY_READ_TIMEOUT_SECS="${FM_CAPACITY_READ_TIMEOUT_SECS:-2}"
FM_CAPACITY_TOTAL_TIMEOUT_SECS="${FM_CAPACITY_TOTAL_TIMEOUT_SECS:-10}"
FM_CAPACITY_PARALLEL="${FM_CAPACITY_PARALLEL:-1}"

# shellcheck disable=SC2034
FM_CAPACITY_LIB_SOURCED=1

fm_capacity_rows_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

fm_capacity_entity_list() {  # -> one "attempt:<id>" or "meta:<id>" line per row source, sorted
  local dir
  dir="$(fm_capacity_rows_dir)"
  {
    # attempt records are the primary row source: they outlive the task meta
    # (cleanup removes the meta before retirement publishes), so a retired
    # attempt still shows as retired, never as an intermediate free slot
    if [ -d "$dir/attempts" ]; then
      find "$dir/attempts" -maxdepth 1 -name '*.json' -printf 'attempt:%f\n' 2>/dev/null \
        | sed 's/\.json$//'
    fi
    # legacy meta-only tasks (no attempt record)
    if [ -d "$dir" ]; then
      find "$dir" -maxdepth 1 -name '*.meta' -printf 'meta:%f\n' 2>/dev/null \
        | sed 's/\.meta$//'
    fi
  } | sort
}

fm_capacity_crew_state() {  # <task-id> -> fm-crew-state.v1 JSON or empty
  local id=$1
  env \
    FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
    FM_HOME="${FM_HOME:-}" \
    FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" \
    FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-}" \
    FM_PROJECTS_OVERRIDE="${FM_PROJECTS_OVERRIDE:-}" \
    FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" \
    timeout --kill-after=1 "$FM_CAPACITY_READ_TIMEOUT_SECS" \
    "$(dirname "${BASH_SOURCE[0]}")/fm-crew-state.sh" --json "$id" 2>/dev/null \
    | head -1 || true
}

fm_capacity_row() {  # <entity> where entity is attempt:<id> or meta:<id> -> row JSON
  local entity=$1 id meta kind attempt crew state source
  case "$entity" in
    attempt:*)
      attempt=${entity#attempt:}
      id=$(fm_attempt_load "$attempt" | jq -r '.envelope.task_key // empty')
      meta="$(fm_capacity_rows_dir)/$id.meta"
      [ -f "$meta" ] || meta=""
      ;;
    meta:*)
      id=${entity#meta:}
      meta="$(fm_capacity_rows_dir)/$id.meta"
      attempt=$(sed -n 's/^attempt=//p' "$meta" | head -1)
      # a meta pointing at an existing attempt is covered by the attempt row
      [ -z "$attempt" ] || { [ -f "$(attempt_path "$attempt")" ] && return 0; }
      attempt=""
      ;;
    *) return 0 ;;
  esac
  [ -n "$meta" ] || meta="$(fm_capacity_rows_dir)/$id.meta"
  [ -f "$meta" ] || return 0
  kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  [ "$kind" = ship ] || return 0
  [ -n "$attempt" ] || attempt=$(sed -n 's/^attempt=//p' "$meta" | head -1)
  crew=$(fm_capacity_crew_state "$id")
  if [ -z "$crew" ] || ! echo "$crew" | jq -e '.schema == "fm-crew-state.v1"' >/dev/null 2>&1; then
    jq -n --arg attempt "${attempt:-null}" --arg id "$id" \
      '{attempt_id:$attempt,task_key:$id,generation:null,kind:"ship",classification:"unknown",source:"none",productive:false,reserved:true,ambiguity_reasons:["worker_read_timeout"],missing_receipts:[],reconciliation_required:true}'
    return 0
  fi
  state=$(echo "$crew" | jq -r '.state')
  source=$(echo "$crew" | jq -r '.source')
  if [ -n "$attempt" ] && [ -f "$(attempt_path "$attempt")" ]; then
    local gen disp
    gen=$(fm_attempt_generation "$attempt")
    disp=$(fm_attempt_landing_disposition "$attempt")
    if fm_attempt_is_retired "$attempt"; then
      jq -n --arg attempt "$attempt" --arg gen "$gen" --arg source "$source" \
        '{attempt_id:$attempt,generation:($gen|tonumber),kind:"ship",classification:"retired",source:$source,productive:false,reserved:false,ambiguity_reasons:[],missing_receipts:[],reconciliation_required:false}'
      return 0
    fi
    local missing
    missing=$(fm_attempt_obligations "$attempt")
    local productive=false reserved=true
    case "$state" in
      working) productive=true ;;
    esac
    # reconciliation is needed only when a non-working attempt cannot reach
    # terminal on its own: done/failed/unknown with outstanding obligations or
    # not yet retired. Missing receipts on a mid-flight (working/blocked/
    # paused) attempt are ordinary obligations, not reconciliation.
    local ambiguity=[] reconciliation=false
    case "$state" in
      done|failed|unknown)
        reconciliation=true
        if [ -n "$missing" ]; then
          ambiguity=$(printf '%s' "$missing" | jq -R 'split(" ") | map("missing_receipt:" + .) + ["not_retired"]')
        else
          ambiguity=["not_retired"]
        fi ;;
      *)
        if [ -n "$missing" ]; then
          ambiguity=$(printf '%s' "$missing" | jq -R 'split(" ") | map("missing_receipt:" + .)')
        fi ;;
    esac
    jq -n --arg attempt "$attempt" --arg gen "$gen" --arg source "$source" \
      --argjson productive "$productive" --argjson reserved "$reserved" \
      --argjson ambiguity "$ambiguity" --argjson reconciliation "$reconciliation" \
      --arg missing "$missing" \
      '{attempt_id:$attempt,generation:($gen|tonumber),kind:"ship",classification:"active",source:$source,productive:$productive,reserved:$reserved,ambiguity_reasons:$ambiguity,missing_receipts:($missing|split(" ")|map(select(.!=""))),reconciliation_required:$reconciliation}'
    return 0
  fi
  # legacy row: no attempt envelope
  local prod=false
  case "$state" in
    working) prod=true ;;
  esac
  jq -n --arg id "$id" --arg source "$source" --argjson productive "$prod" \
    '{attempt_id:null,task_key:$id,generation:null,kind:"ship",classification:"legacy",source:$source,productive:$productive,reserved:true,ambiguity_reasons:["missing_attempt_envelope"],missing_receipts:[],reconciliation_required:true}'
}

fm_capacity_collect_rows() {  # writes rows to $1 and the listed-entity set to $2
  local out=$1 listed=$2 entity
  : > "$listed"
  if [ "$FM_CAPACITY_PARALLEL" -gt 1 ]; then
    fm_capacity_entity_list | tee "$listed" | xargs -P "$FM_CAPACITY_PARALLEL" -I{} \
      bash -c 'FM_CAPACITY_LIB_SOURCED=1; . "$0"; fm_capacity_row "$1"' \
      "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh" {} > "$out"
  else
    while IFS= read -r entity; do
      [ -n "$entity" ] || continue
      printf '%s\n' "$entity" >> "$listed"
      # deterministic torn-read hook for tests: the record vanishes between
      # listing and read
      case "$entity" in
        meta:*) [ "${entity#meta:}" = "${FM_CAPACITY_TEST_DISAPPEAR:-}" ] \
                  && rm -f "$(fm_capacity_rows_dir)/${entity#meta:}.meta" ;;
      esac
      fm_capacity_row "$entity" >> "$out"
    done < <(fm_capacity_entity_list)
  fi
}

fm_capacity_ambiguous_for() {  # <task-id> <reason> -> ambiguous row JSON
  jq -n --arg id "$1" --arg reason "$2" \
    '{attempt_id:null,task_key:$id,generation:null,kind:"ship",classification:"unknown",source:"none",productive:false,reserved:true,ambiguity_reasons:[$reason],missing_receipts:[],reconciliation_required:true}'
}

fm_capacity_project() {  # -> fm-fleet-capacity.v1 JSON on stdout
  local dir rows listed generated schema_ok deadline_ok id
  if [ -n "${FM_CAPACITY_OBSERVATION_FILE:-}" ] && [ -f "${FM_CAPACITY_OBSERVATION_FILE}" ]; then
    cat "$FM_CAPACITY_OBSERVATION_FILE"
    return 0
  fi
  dir="$(fm_capacity_rows_dir)"
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  schema_ok=true
  if [ "${FM_CAPACITY_FORCE_SCHEMA_MISMATCH:-0}" = 1 ]; then schema_ok=false; fi
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-capacity-rows.XXXXXX")
  listed=$(mktemp "${TMPDIR:-/tmp}/fm-capacity-listed.XXXXXX")
  # real total deadline: the whole collection phase runs under timeout; on
  # expiry every listed id without an observed row becomes deterministically
  # ambiguous. A listed id whose record disappeared mid-read is likewise
  # ambiguous (torn read), never silently absent.
  if FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" \
      FM_CAPACITY_READ_TIMEOUT_SECS="${FM_CAPACITY_READ_TIMEOUT_SECS:-}" \
      FM_CAPACITY_TOTAL_TIMEOUT_SECS="${FM_CAPACITY_TOTAL_TIMEOUT_SECS:-}" \
      FM_CAPACITY_PARALLEL="${FM_CAPACITY_PARALLEL:-}" \
      timeout "$FM_CAPACITY_TOTAL_TIMEOUT_SECS" \
      bash -c '. "$1"; fm_capacity_collect_rows "$2" "$3"' \
      _ "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh" "$rows" "$listed" >/dev/null 2>&1; then
    deadline_ok=true
  else
    deadline_ok=false
  fi
  # deterministic post-pass: every listed entity without a row is ambiguous
  while IFS= read -r entity; do
    [ -n "$entity" ] || continue
    local key=${entity#attempt:}
    key=${key#meta:}
    if ! jq -e --arg key "$key" '[.[] | select(.task_key == $key or .attempt_id == $key)] | length > 0' "$rows" >/dev/null 2>&1; then
      fm_capacity_ambiguous_for "$key" "$([ "$deadline_ok" = true ] && echo record_disappeared || echo worker_read_timeout)" >> "$rows"
    fi
  done < "$listed"
  rm -f "$listed"
  jq -s --arg generated "$generated" \
    --arg home "${FM_HOME:-local}" \
    --argjson schema_ok "$schema_ok" \
    --argjson deadline_ok "$deadline_ok" \
    '. as $rows |
     def has_timeout: ([$rows[] | select(.ambiguity_reasons | index("worker_read_timeout") != null)] | length) > 0;
     def incomplete: (has_timeout) or ($schema_ok | not) or ($deadline_ok | not);
     def reconciliation: ([$rows[] | select(.reconciliation_required == true)] | length > 0);
     def complete: ((has_timeout | not) and ($deadline_ok));
     {
       schema:"fm-fleet-capacity.v1",
       generated:$generated,
       home_id:$home,
       observation_complete:complete,
       total_timeout:($deadline_ok | not),
       schema_ok:$schema_ok,
       alert_only:incomplete,
       reconciliation_required:reconciliation,
       rows:($rows | sort_by(.attempt_id // .task_key)),
       aggregate:{
         productive_count:([$rows[]|select(.productive == true)]|length),
         reserved_ownership_count:([$rows[]|select(.reserved == true)]|length),
         ambiguous_count:([$rows[]|select((.ambiguity_reasons|length) > 0)]|length),
         observation_complete:complete,
         reconciliation_required:reconciliation,
         refill_safe:(complete and (incomplete | not) and (reconciliation | not))
       }
     }' "$rows"
  rm -f "$rows"
}
```

Notes pinned for the implementer: `env VAR=value timeout --kill-after=1 "$secs" command args` is the valid ordering (environment assignments before the executable). `FM_CAPACITY_TOTAL_TIMEOUT_SECS` is enforced by the outer `timeout` around the collection phase; the deterministic post-pass marks every unfinished meta ambiguous. Parallelism (`FM_CAPACITY_PARALLEL > 1`) is enabled only after `test_parallel_reads_are_byte_identical` and the backend-concurrency proof in Step 5 pass; until then it stays 1. The latency budget is achievable at target fleet size because a real `fm-crew-state.sh --json` read is sub-150ms; with `FM_CAPACITY_READ_TIMEOUT_SECS=2` and a 12-row fleet the sequential phase stays far below the 2000 ms budget, and the total deadline of 10s bounds the worst case.

- [x] **Step 5: Prove bounded concurrency before enabling parallelism**

Run `test_parallel_reads_are_byte_identical` with `FM_CAPACITY_PARALLEL=4` against a 12-row fixture; then run the same fixture against the real tmux backend (`bash tests/fm-backend-tmux-smoke.test.sh`) and confirm the projection output is unchanged. Only after both pass may `FM_CAPACITY_PARALLEL` default above 1.

- [x] **Step 6: Run the tests to verify they pass**

Run: `bash tests/fm-crew-state.test.sh; bash tests/fm-capacity.test.sh`
Expected: all green (structured contract tests plus the twelve capacity fixtures).

- [x] **Step 7: Verify the projection is read-only**

Run `bash tests/fm-capacity.test.sh` again with `git status --short` before and after.
Expected: no state change beyond the test temp root.

- [x] **Step 8: Commit**

```bash
git add bin/fm-crew-state.sh bin/fm-capacity-lib.sh
git add tests/fm-crew-state.test.sh tests/fm-capacity.test.sh
git commit -m "feat(capacity): structured crew-state contract and shared projection with total deadline"
```

---

## Task 3: Shadow-only parallel run and latency measurement

F3 and F8 corrections. Consumer decisions stay on legacy behavior; the new object is emitted and recorded alongside for measurement and parity, with one frozen observation shared by all consumers.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (add `--count-json` and `--shadow`; legacy verdict unchanged)
- Extend: `tests/fm-fleet-refill.test.sh`
- Create: `docs/verification/fleet-capacity.md` (shadow + latency + integration-base sections)

- [x] **Step 1: Write the failing tests**

Append to `tests/fm-fleet-refill.test.sh`:

```bash
test_count_json_emits_shared_object() {
  local out
  write_meta_fixture ship direct-PR
  out=$(PATH="$FAKEBIN:$PATH" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$clean_probe" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  echo "$out" | jq -e '.schema == "fm-fleet-capacity.v1"' >/dev/null || fail "schema"
  pass "fleet refill --count-json emits the shared capacity object"
}

test_legacy_verdict_is_unchanged_in_shadow_mode() {
  local out
  write_meta_fixture ship direct-PR
  out=$(PATH="$FAKEBIN:$PATH" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$clean_probe" \
    FM_REFILL_SHADOW="$TMP_ROOT/shadow.json" \
    "$ROOT/bin/fm-fleet-refill.sh" 2>&1)
  assert_contains "$out" "fleet-refill:" "legacy summary line missing"
  assert_contains "$out" "active=" "legacy active counter changed before cutover"
  [ -f "$TMP_ROOT/shadow.json" ] || fail "shadow object not recorded"
  jq -e '.schema == "fm-fleet-capacity.v1"' "$TMP_ROOT/shadow.json" >/dev/null || fail "shadow not capacity object"
  pass "shadow mode records the object while the legacy verdict stays authoritative"
}

test_frozen_observation_parity() {
  # one frozen observation drives every consumer; rows/aggregates compare
  # byte-identically without timing dependence
  local frozen refill
  write_meta_fixture ship direct-PR
  frozen="$TMP_ROOT/frozen.json"
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null > "$frozen"
  refill=$(FM_STATE_OVERRIDE="$STATE" FM_CAPACITY_OBSERVATION_FILE="$frozen" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  [ "$(echo "$refill" | jq -c '.rows')" = "$(jq -c '.rows' "$frozen")" ] \
    || fail "frozen observation rows differ"
  [ "$(echo "$refill" | jq -c '.aggregate')" = "$(jq -c '.aggregate' "$frozen")" ] \
    || fail "frozen observation aggregate differs"
  pass "one frozen observation gives deterministic rows and aggregates across consumers"
}

test_count_json_emits_shared_object
test_legacy_verdict_is_unchanged_in_shadow_mode
test_frozen_observation_parity
```

The new tests need `write_meta_fixture` and a file-scope `clean_probe` (hoist the existing per-test fixture to file scope in the same edit), plus `FM_REFILL_SHADOW` support from Step 2.

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-fleet-refill.test.sh`
Expected: FAIL on the new tests (`--count-json` unrecognized, shadow file absent).

- [x] **Step 3: Add `--count-json` and `--shadow` to `bin/fm-fleet-refill.sh` without touching the legacy verdict**

Add to the top of the existing legacy script (which keeps its manifest/mtime arithmetic verbatim through this task):

```bash
if [ "${1:-}" = "--count-json" ]; then
  FM_HOME_SAVED="${FM_HOME:-}"
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  fm_capacity_project
  exit 0
fi
if [ -n "${FM_REFILL_SHADOW:-}" ]; then
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  fm_capacity_project > "$FM_REFILL_SHADOW"
fi
```

The human verdict and dispatch decision remain the legacy arithmetic until Task 13; the shadow object is recorded alongside for parity and latency measurement only. The snapshot is NOT modified in this task.

- [x] **Step 4: Quarantine the private cron sentinel to alert-only**

The active private cron sentinel (`*/20 * * * * /home/holu/fmate/firstmate/data/fleet-depth-check.sh`, which reads `state/fleet-manifest.jsonl` and `/tmp/pi-subagents-1000/.../tasks/<id>.output` and appends wake records through `fm_wake_append`) stays alive through the shadow stage but is quarantined to alert-only: its capacity arithmetic is never authoritative, no dispatch decision depends on it, and the shadow object is measured independently of it. Concretely:

1. Record the quarantine decision in the home (`config/fleet-depth-quarantined` marker, gitignored) so the diagnosis and later removal are auditable.
2. Leave the crontab entry and the script in place (removal happens only after the Task 13 cutover proof).
3. Assert the quarantine in the shadow record: run `bin/fm-fleet-refill.sh --count-json` and verify the object's aggregate does not change whether or not the cron sentinel has recently appended a wake record (the object never reads the manifest or output paths).
4. Record the quarantine and the assertion in `docs/verification/fleet-capacity.md` under `## Cron sentinel quarantine`.

Do not repoint the crontab at anything and do not create a wrapper for the old sentinel.

- [x] **Step 5: Measure hot-path latency (shadow) and record it**

Run on the real home with the fleet at rest:

```bash
/usr/bin/time -f 'count-json wall=%e s' bin/fm-fleet-refill.sh --count-json >/dev/null
```

Expected: wall time below 2000 ms with the default timeouts at the current fleet size. Record the date, the integration-base SHA from Task 0, the command, and the exact output in `docs/verification/fleet-capacity.md` under `## Latency (shadow)`, in the maintainer-verification format used by `docs/verification/runtime-backends.md`. Also record the Task 0 integration-base SHA under `## Integration base`.

- [x] **Step 6: Run the tests to verify they pass**

Run: `bash tests/fm-fleet-refill.test.sh`
Expected: all green, including the legacy refill tests (serialization-debt propagation and the legacy verdict).

- [x] **Step 7: Commit**

```bash
git add bin/fm-fleet-refill.sh tests/fm-fleet-refill.test.sh docs/verification/fleet-capacity.md
git commit -m "feat(capacity): shadow-only count-json and latency measurement with legacy verdict unchanged"
```

---

## Task 4: Centralized live disposition and read/reconcile migration

F6 correction. One disposition reader re-reads all named owners with explicit unknown branches; fresh per-effect authority is required for every irreversible transition; migration uses the same API in read/reconcile mode and never conflates bead and forge state.

**Files:**

- Create: `bin/fm-disposition-lib.sh`
- Create: `tests/fm-disposition.test.sh`
- Create: `bin/fm-attempt-migrate.sh`
- Create: `tests/fm-attempt-migrate.test.sh`

- [x] **Step 1: Write the failing tests**

Create `tests/fm-disposition.test.sh`:

```bash
#!/usr/bin/env bash
# Public-interface tests for the centralized live disposition reader and the
# fresh per-effect authority resolver.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-disposition)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN"

export FM_STATE_OVERRIDE="$STATE"
export FM_REFILL_PROJECT="$PROJECT"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$ROOT/bin/fm-disposition-lib.sh"

fake_gh() {  # <merged|unmerged|unknown>; emits the gh-axi pr view JSON shape
  local body
  case "$1" in
    merged) body='{"state":"MERGED","headRefOid":"abc123","baseRefOid":"old"}' ;;
    unmerged) body='{"state":"CLOSED","headRefOid":"abc123","baseRefOid":"old"}' ;;
    unknown) body='not json' ;;
  esac
  cat > "$FAKEBIN/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$body'
SH
  chmod +x "$FAKEBIN/gh-axi"
}

journal_forge_observation() {  # <attempt_id> <state>
  fm_attempt_observe "$1" 1 forge "{\"provider\":\"github\",\"pr\":\"https://github.com/kunchenguid/firstmate/pull/1\",\"state\":\"$2\"}"
}

test_live_merge_proof_is_forge_authority_not_bead_closure() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-a holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-a"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  journal_forge_observation "$aid" open
  # bead open but PR merged: forge wins for landing truth
  fake_gh merged
  out=$(PATH="$FAKEBIN:$PATH" fm_disposition_live "$aid")
  [ "$out" = landed ] || fail "forge merge proof not honored: $out"
  pass "forge merge proof decides landed; bead closure is tracker truth, not forge truth"
}

test_bead_closed_alone_never_retires_preserved_unlanded() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-b holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-b"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  journal_forge_observation "$aid" open
  fake_gh unmerged
  out=$(PATH="$FAKEBIN:$PATH" fm_disposition_live "$aid")
  [ "$out" = preserved_unlanded ] || fail "closed-unmerged not preserved: $out"
  pass "a closed-unmerged delivery is preserved_unlanded, never landed"
}

test_unknown_owners_yield_unknown() {
  local aid out
  aid=$(fm_attempt_alloc pi dos-c holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  journal_forge_observation "$aid" open
  fake_gh unknown
  out=$(PATH="$FAKEBIN:$PATH" fm_disposition_live "$aid")
  [ "$out" = unknown ] || fail "unknown forge should be unknown: $out"
  pass "missing or unreadable owner evidence yields unknown, never a guess"
}

test_claim_authority_never_authorizes_closure() {
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" fm_authority_for close dos-c 2>&1 || true)
  assert_contains "$out" "missing" "closure without fresh authority accepted"
  pass "claim authorization cannot authorize later bead closure"
}

test_authority_is_per_transition() {
  local out
  printf '%s\n' '{"transition":"claim","authority":"captain:dispatch"}' > "$STATE/authority-current.json"
  out=$(FM_AUTHORITY_FILE="$STATE/authority-current.json" fm_authority_for claim dos-d 2>&1) || fail "claim authority"
  assert_contains "$out" "captain:dispatch" "claim authority not returned"
  out=$(FM_AUTHORITY_FILE="$STATE/authority-current.json" fm_authority_for close dos-d 2>&1 || true)
  assert_contains "$out" "missing" "claim authority leaked to close"
  pass "each irreversible transition requires its own fresh current-session authority"
}

test_live_merge_proof_is_forge_authority_not_bead_closure
test_bead_closed_alone_never_retires_preserved_unlanded
test_unknown_owners_yield_unknown
test_claim_authority_never_authorizes_closure
test_authority_is_per_transition
```

Create `tests/fm-attempt-migrate.test.sh` (fixtures: landed task with merged PR retired; live task with running worker gets an envelope; unknown worker and unknown forge preserved; closed-unmerged preserved even when the bead is closed; the migration uses the same `fm_disposition_live` in read/reconcile mode and never migrates or retires branches):

```bash
test_landed_legacy_task_is_retired_with_disposition() {
  # meta kind=ship mode=direct-PR, live disposition=landed (forge proof)
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_PROJECT="$PROJECT" \
    "$ROOT/bin/fm-attempt-migrate.sh" legacy-1 2>&1)
  assert_contains "$out" "retired disposition=landed" "landed task not retired"
  local f="$STATE/attempts/legacy-1-a1.json"
  [ -f "$f" ] || fail "no envelope written"
  jq -e '.receipts.landing[0].state == "observed" and .receipts.landing[0].evidence.disposition == "landed"' "$f" >/dev/null \
    || fail "landing receipt missing"
  pass "landed legacy task is retired with a landing receipt"
}

test_unknown_work_is_preserved() {
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_PROJECT="$PROJECT" \
    "$ROOT/bin/fm-attempt-migrate.sh" legacy-2 2>&1)
  assert_contains "$out" "preserved" "unknown work was not preserved"
  local f="$STATE/attempts/legacy-2-a1.json"
  jq -e '.receipts.landing[0].evidence.disposition == "unknown"' "$f" >/dev/null \
    || fail "unknown disposition not recorded"
  pass "unknown or unlanded work is preserved, never discarded"
}

test_closed_unmerged_is_preserved_even_when_bead_closed() {
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_PROJECT="$PROJECT" \
    "$ROOT/bin/fm-attempt-migrate.sh" legacy-3 2>&1)
  assert_contains "$out" "preserved" "closed-unmerged work retired on bead closure"
  pass "preserved-unlanded work is never retired merely because a bead is closed"
}
```

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-disposition.test.sh; bash tests/fm-attempt-migrate.test.sh`
Expected: FAIL with the libs and script missing.

- [x] **Step 3: Implement `bin/fm-disposition-lib.sh`**

```bash
#!/usr/bin/env bash
# One centralized live disposition reader and fresh per-effect authority
# resolver. Receipts are bound effect evidence, never live truth. This library
# re-reads exact worker, endpoint, Git, forge, bead, owned-copy, and queue
# evidence with explicit unknown branches, and returns landed |
# preserved_unlanded | unknown.
set -u

# shellcheck disable=SC2034
FM_DISPOSITION_LIB_SOURCED=1

fm_authority_for() {  # <transition> <task_key> -> prints fresh authority or fails
  local transition=$1 key=$2 file
  file="${FM_AUTHORITY_FILE:-${FM_STATE_OVERRIDE:-$FM_HOME/state}/authority-current.json}"
  [ -f "$file" ] || { echo "missing current-session authority for $transition on $key" >&2; return 1; }
  jq -e --arg t "$transition" '.transition == $t' "$file" >/dev/null 2>&1 \
    || { echo "missing fresh $transition authority for $key (only other-transition authority present)" >&2; return 1; }
  jq -r '.authority' "$file"
}

fm_disposition_live() {  # <attempt_id> -> landed | preserved_unlanded | unknown
  local attempt=$1
  local bead pr merged copy repo branch_state
  bead=$(fm_attempt_load "$attempt" | jq -r '.envelope.task_key')
  copy=$(fm_attempt_load "$attempt" | jq -r '.provider.copy // ""')
  repo="${FM_REFILL_PROJECT:-/home/holu/decision-os}"
  pr=$(fm_attempt_load "$attempt" | jq -r '[.observations[]? | select(.name == "forge")][-1].evidence.pr // ""')
  # forge authority: PR merge state decides landing; bead state is tracker truth
  if [ -n "$pr" ]; then
    merged=$(gh-axi pr view "$pr" --json state,headRefOid,baseRefOid 2>/dev/null \
      | jq -r 'if .state == "MERGED" then "landed" else "preserved_unlanded" end' \
      || echo unknown)
    [ "$merged" = unknown ] && { echo unknown; return 0; }
    echo "$merged"
    return 0
  fi
  # owned-copy authority: branch/ref state in the exact copy
  if [ -n "$copy" ] && [ -d "$copy/.git" ]; then
    branch_state=$(git -C "$copy" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
    [ "$branch_state" = unknown ] && { echo unknown; return 0; }
  fi
  # bead state is tracker truth, never forge truth; it can only confirm "not
  # landing" or leave the disposition unknown
  bead_state=$(br show --json "$bead" 2>/dev/null | jq -r '.[0].status // "unknown"')
  case "$bead_state" in
    closed|done) echo preserved_unlanded ;;
    *) echo unknown ;;
  esac
}
```

The exact `gh-axi pr view` JSON shape and `br show --json` array fields are pinned in Task 5's contract step and recorded in the test fixtures; any field that does not exist in the installed version yields unknown, never a guess.

- [x] **Step 4: Implement `bin/fm-attempt-migrate.sh`**

```bash
#!/usr/bin/env bash
# One-time migration helper: classify each legacy task (no attempt envelope)
# through fm_disposition_live in read/reconcile mode, then create the
# envelope for the in-flight attempt or retire it with an exact disposition.
# Never migrates or retires branches, never discards unknown or unlanded
# work, and never treats bead closure as forge proof. Re-run-safe: a task
# with an attempt is skipped.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-disposition-lib.sh"

migrate_one() {  # <task-id>
  local id=$1
  [ -f "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta" ] || { echo "skip: no meta for $id"; return 0; }
  [ -d "$(attempts_dir)" ] || mkdir -p "$(attempts_dir)"
  local attempt
  attempt=$(sed -n 's/^attempt=//p' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta" | head -1)
  [ -n "$attempt" ] && [ -f "$(attempt_path "$attempt")" ] && { echo "skip: $id already has $attempt"; return 0; }
  local aid disp
  aid=$(fm_attempt_alloc pi "$id" "${FM_HOME:-local}") || return 1
  disp=$(fm_disposition_live "$aid")
  case "$disp" in
    unknown)
      echo "preserved: $id disposition=unknown (reconcile from live facts)"
      return 0 ;;
    landed)
      fm_attempt_effect_observe "$aid" 1 landing "{\"disposition\":\"landed\",\"migrated\":true}" || return 1
      fm_attempt_retire "$aid" 1 "{\"audit\":\"migration\",\"disposition\":\"landed\"}" \
        && echo "retired: $id disposition=landed" || echo "preserved: $id disposition=landed"
      ;;
    preserved_unlanded)
      fm_attempt_effect_observe "$aid" 1 landing "{\"disposition\":\"preserved_unlanded\",\"migrated\":true}" || return 1
      echo "preserved: $id disposition=preserved_unlanded (never retired on bead closure)"
      ;;
  esac
}

for id in "$@"; do migrate_one "$id"; done
```

- [x] **Step 5: Verify**

Run: `bash tests/fm-disposition.test.sh; bash tests/fm-attempt-migrate.test.sh; bash tests/fm-attempt.test.sh; bash tests/fm-capacity.test.sh`
Expected: all green. Also record the exact installed `gh-axi pr view --json` and `br show --json` field names in the fixtures during implementation (Task 5 Step 4 pins them).

- [x] **Step 6: Commit**

```bash
git add bin/fm-disposition-lib.sh tests/fm-disposition.test.sh
git add bin/fm-attempt-migrate.sh tests/fm-attempt-migrate.test.sh
git commit -m "feat(disposition): centralize live disposition and reconcile stale records without conflating authorities"
```

---

## Task 5: The Decision OS steward transaction

F5 correction plus decision-os Task 7.4. Written against the installed `br` 0.2.19 and `br_worktree_storage.py` command contracts, with a pathspec-only guarded fast-forward transaction and durable pending through the single attempt record. This task covers the steward transaction only; the spawn handshake is Task 6.

**Files:**

- Create: `bin/fm-br-receipt.sh`
- Create: `tests/fm-br-receipt.test.sh`
- Create: `tests/live-decision-os-contract.test.sh` (live guard, env-gated)

- [x] **Step 1: Pin the installed command contracts**

Run against the registered clone:

```bash
br --version
br comments --help
br show --help
br_worktree_storage_help="$(cd /home/holu/decision-os && PYTHONPATH=src .venv/bin/python scripts/br_worktree_storage.py --help)"
printf '%s\n' "$br_worktree_storage_help"
```

Record in the test fixtures: `br comments add|list` (no `show`); `br show --json` returns an array; `preflight --repo <path> --status-out <path> --br-bin <path>`; `verify-session --repo <path> [--agent]`; `claim <issue_id> --repo <path> --agent <name> --br-bin <path>`.

- [x] **Step 2: Write the failing tests**

Create `tests/fm-br-receipt.test.sh` with the fake clone fixture and these assertions:

```bash
TMP_ROOT=$(fm_test_tmproot fm-br-receipt)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
ORDER="$TMP_ROOT/order.log"
REMOTE="$TMP_ROOT/remote.git"
mkdir -p "$STATE" "$FAKEBIN"

# fake registered decision-os main clone: real git repo on main with a bare
# origin so the pathspec commit + push succeed
git init -q -b main "$PROJECT"
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name Test
git init -q --bare "$REMOTE"
git -C "$PROJECT" remote add origin "$REMOTE"
mkdir -p "$PROJECT/.beads" "$PROJECT/scripts" "$PROJECT/.venv/bin"
printf '%s\n' '{"id":"dos-x","status":"open"}' > "$PROJECT/.beads/issues.jsonl"
ln -s "$(command -v python3)" "$PROJECT/.venv/bin/python"
git -C "$PROJECT" add .beads/issues.jsonl
git -C "$PROJECT" commit -q -m base
git -C "$PROJECT" push -q -u origin main

# fake storage script records invocations and honors STORAGE_EXIT
cat > "$PROJECT/scripts/br_worktree_storage.py" <<'SH'
#!/usr/bin/env python3
import sys, os
with open(os.environ["ORDER_FILE"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ.get("STORAGE_EXIT", "0")))
SH
chmod +x "$PROJECT/scripts/br_worktree_storage.py"

# fake br: records invocations; comments add mutates .beads/issues.jsonl so
# the pathspec commit has a real diff; show emits the array shape
cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
set -u
echo "$*" >> "${ORDER_FILE:?}"
case "$1" in
  comments)
    if [ "$2" = add ]; then
      printf '%s\n' "{\"id\":\"$3\",\"comment\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}" \
        >> "${ISSUES_FILE:?}"
      git -C "${PROJECT_DIR:?}" add .beads/issues.jsonl >/dev/null
      printf '%s\n' "[{\"text\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}]"
    else
      printf '%s\n' "[{\"text\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}]"
    fi ;;
  show) printf '%s\n' '[{"id":"dos-x","status":"open"}]' ;;
  close) exit "${BR_CLOSE_EXIT:-0}" ;;
  *) exit "${BR_OTHER_EXIT:-0}" ;;
esac
SH
chmod +x "$FAKEBIN/br"

test_claim_refusal_keeps_attempt_without_copy() {
  local aid rc out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-x holu) || fail "alloc"
  local req="$TMP_ROOT/claim.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-x","transition":"claim","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"intake","authority":"captain:dispatch","agent":"pi-primary","repo":"$PROJECT"}
JSON
  out=$(FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" \
    STORAGE_EXIT=1 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 1 "$rc" "refused claim should fail"
  [ "$(fm_attempt_obligations "$aid")" = claim ] || fail "claim obligation not pending"
  jq -e '[.receipts.tracker[]? | select(.state == "pending")] | length == 1' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "pending not recorded in the single attempt record"
  [ ! -e "$PROJECT/worktree-created" ] || fail "provider copy created before claim receipt"
  pass "a refused claim leaves the attempt pending with the failure inside the attempt record"
}

test_closure_receipt_precedes_close_and_list_is_used() {
  local aid rc out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-y holu) || fail "alloc"
  local req="$TMP_ROOT/close.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-y","transition":"close","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"landed pr https://github.com/kunchenguid/firstmate/pull/1","authority":"captain:merge","agent":"pi-primary","repo":"$PROJECT"}
JSON
  out=$(FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 0 "$rc" "close should succeed"
  assert_contains "$(cat "$ORDER")" "comments add dos-y -m Closure-Receipt:" "closure receipt comment missing"
  assert_contains "$(cat "$ORDER")" "comments list" "verification did not use br comments list"
  assert_contains "$(cat "$ORDER")" "close dos-y" "close missing"
  local i1 i2
  i1=$(grep -n "comments add" "$ORDER" | head -1 | cut -d: -f1)
  i2=$(grep -n "close dos-y" "$ORDER" | head -1 | cut -d: -f1)
  [ "$i1" -lt "$i2" ] || fail "close ran before the Closure-Receipt comment"
  pass "the operative Closure-Receipt comment precedes br close and is verified via comments list"
}

test_only_beads_issues_jsonl_is_committed() {
  local aid rc out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-z holu) || fail "alloc"
  printf '%s\n' unrelated > "$PROJECT/unrelated.txt"
  git -C "$PROJECT" add unrelated.txt
  local req="$TMP_ROOT/status.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-z","transition":"status","expected_state":"in-progress","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"intake","authority":"captain:dispatch","agent":"pi-primary","repo":"$PROJECT"}
JSON
  out=$(FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 1 "$rc" "unrelated staged path accepted"
  assert_contains "$out" "outside .beads/issues.jsonl" "unrelated staged path not refused"
  pass "only .beads/issues.jsonl may be staged or committed"
}

test_push_conflict_records_durable_pending() {
  # remote main diverges: push origin/main fails; the guarded fast-forward
  # refresh records a durable pending obligation before the pause releases
  local aid rc out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-w holu) || fail "alloc"
  local req="$TMP_ROOT/close-w.json"
  cat > "$req" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-w","transition":"close","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"landed pr https://github.com/kunchenguid/firstmate/pull/2","authority":"captain:merge","agent":"pi-primary","repo":"$PROJECT"}
JSON
  # make origin/main diverge after the preamble push
  (git clone -q --bare "$PROJECT" "$REMOTE.alt" 2>/dev/null || true)
  git -C "$REMOTE" update-ref refs/heads/main "$(git -C "$PROJECT" rev-parse HEAD~0)" 2>/dev/null || true
  out=$(FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" FAKE_ATTEMPT="$aid" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$req" 2>&1); rc=$?
  expect_code 1 "$rc" "push conflict should fail"
  jq -e '[.receipts.tracker[]? | select(.state == "pending")] | length >= 1' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "push conflict did not record a durable pending obligation"
  pass "conflicts and push failure become durable pending obligations in the attempt record"
}

test_br_show_array_shape_is_handled() {
  # a malformed non-array br show output fails closed (the live guard pins the
  # real array shape; the adapter's jq requires an array)
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-v holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-v"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  pass "br show array shape is pinned in the live guard and the adapter fails closed on non-arrays"
}

test_claim_refusal_keeps_attempt_without_copy
test_closure_receipt_precedes_close_and_list_is_used
test_only_beads_issues_jsonl_is_committed
test_push_conflict_records_durable_pending
test_br_show_array_shape_is_handled
```

Create `tests/live-decision-os-contract.test.sh` (the live guard):

```bash
#!/usr/bin/env bash
# Live contract guard for the Decision OS steward transaction. Exercised only
# when FM_LIVE_DECISION_OS=1 (env-gated, self-skipping otherwise, like the
# live-harness-optin family). Runs against the real registered clone and the
# installed br/storage CLIs and fails naming the exact missing contract.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_LIVE_DECISION_OS:-0}" != 1 ]; then
  echo "skip: FM_LIVE_DECISION_OS not set (live Decision OS contract guard)"
  exit 0
fi

REPO="${FM_REFILL_PROJECT:-/home/holu/decision-os}"
[ -d "$REPO/.beads" ] || fail "registered clone missing: $REPO"
[ -x "$REPO/scripts/br_worktree_storage.py" ] || fail "storage script missing"
command -v br >/dev/null || fail "br not installed"

test_verify_session_contract() {
  local out
  out=$(cd "$REPO" && PYTHONPATH=src .venv/bin/python scripts/br_worktree_storage.py \
    verify-session --repo "$REPO" --agent "${BR_AGENT_NAME:-live-guard}" 2>&1)
  case "$out" in
    *"verify-session: OK"*) pass "verify-session --repo --agent works" ;;
    *) fail "verify-session contract failed: $out" ;;
  esac
}

test_br_show_is_array_shaped() {
  local out
  out=$(br show --json "$(br ready --json | jq -r '.[0].id // empty')" 2>/dev/null | jq -r 'type')
  [ "$out" = array ] || fail "br show --json is not array-shaped: $out"
  pass "br show --json returns an array"
}

test_br_comments_has_list_not_show() {
  br comments list --help >/dev/null 2>&1 || fail "br comments list missing"
  br comments show --help >/dev/null 2>&1 && fail "br comments show exists (contract changed)"
  pass "br comments list exists and comments show does not"
}

test_preflight_requires_full_args() {
  local tmp
  tmp=$(mktemp -d)
  (cd "$REPO" && PYTHONPATH=src .venv/bin/python scripts/br_worktree_storage.py \
    preflight --repo "$REPO" --status-out "$tmp/status.json" --br-bin "$(command -v br)") \
    || fail "preflight --repo --status-out --br-bin failed"
  rm -rf "$tmp"
  pass "preflight requires and accepts --repo --status-out --br-bin"
}

test_verify_session_contract
test_br_show_is_array_shaped
test_br_comments_has_list_not_show
test_preflight_requires_full_args
```

- [x] **Step 3: Run to verify failure**

Run: `bash tests/fm-br-receipt.test.sh`
Expected: FAIL with `fm-br-receipt.sh: No such file`.

- [x] **Step 4: Implement `bin/fm-br-receipt.sh`**

```bash
#!/usr/bin/env bash
# Attended Decision OS main-steward adapter. Executes one authorized tracker
# mutation request (schema fm-tracker-request.v1) against the registered
# decision-os main clone and persists the authoritative receipt into the
# attempt record. Only the attended Decision OS main steward invokes this
# script. Written against the installed br 0.2.19 and br_worktree_storage.py
# command contracts. Never infers or enlarges authority.
#
# Usage: fm-br-receipt.sh <request-json-file>
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"

REQ_FILE=$1
REQ=$(cat "$REQ_FILE")
attempt=$(echo "$REQ" | jq -r '.attempt_id')
gen=$(echo "$REQ" | jq -r '.generation')
bead=$(echo "$REQ" | jq -r '.bead_id')
transition=$(echo "$REQ" | jq -r '.transition')
expected_state=$(echo "$REQ" | jq -r '.expected_state')
expected_hash=$(echo "$REQ" | jq -r '.expected_source_hash')
authority=$(echo "$REQ" | jq -r '.authority')
agent=$(echo "$REQ" | jq -r '.agent')
repo=$(echo "$REQ" | jq -r '.repo')
BR_BIN="$(command -v br)"
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-br-receipt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

run_storage() {  # <args...>
  (cd "$repo" && PYTHONPATH=src .venv/bin/python "$repo/scripts/br_worktree_storage.py" "$@")
}

fail_tracker() {  # <reason>; records a durable pending obligation and refuses
  echo "tracker_pending: $*" >&2
  fm_attempt_effect_pending "$attempt" "$gen" tracker \
    "$(jq -n --arg reason "$*" --arg transition "$transition" \
      '{status:"pending",reason:$reason,transition:$transition,authority:"'"$authority"'"}')" \
    || echo "tracker: failed to record pending obligation for $attempt" >&2
  rm -f "$STATE_DIR/.tracker-pause"
  exit 1
}

[ -n "$authority" ] || fail_tracker "missing current-session authority"
[ -n "$agent" ] || fail_tracker "missing bound agent identity"

# 1. durable pause receipt: stop new decision-os worktree creation and all
#    admitted tracker writers for this attempt.
printf '%s\n' "attempt=$attempt transition=$transition started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$STATE_DIR/.tracker-pause"

# 2. enter the canonical registered main clone, never a linked worktree
cd "$repo" || fail_tracker "not the registered clone: $repo"
[ -d .beads ] || fail_tracker "no .beads in $repo"

# 3. guarded fast-forward refresh: fetch, then verify local main is not behind
git fetch origin >/dev/null 2>&1 || fail_tracker "fetch failed"
if ! git merge-base --is-ancestor origin/main HEAD; then
  if ! git merge --ff-only origin/main >/dev/null 2>&1; then
    fail_tracker "local main diverged from origin/main; refresh refused"
  fi
fi

# 4. verify session, identity, authority, clean preflight, expected commit and
#    pre-mutation source hash
run_storage verify-session --repo "$repo" --agent "$agent" >/dev/null 2>&1 \
  || fail_tracker "verify-session failed"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail_tracker "clone not on main"
actual_hash=$(sha256sum .beads/issues.jsonl | cut -d' ' -f1)
[ "$actual_hash" = "$expected_hash" ] || fail_tracker "source hash mismatch $actual_hash != $expected_hash"

case "$transition" in
  claim)
    run_storage claim "$bead" --repo "$repo" --agent "$agent" --br-bin "$BR_BIN" >/dev/null 2>&1 \
      || fail_tracker "claim refused"
    post_state="claimed" ;;
  close)
    # Closure-Receipt must be operative BEFORE br close; verified via the
    # installed br comments list (array-shaped)
    br comments add "$bead" -m "Closure-Receipt: landed $authority attempt=$attempt" >/dev/null 2>&1 \
      || fail_tracker "closure receipt comment failed"
    br comments list "$bead" --json 2>/dev/null | jq -e --arg s "attempt=$attempt" \
      '.[] | select(.text | contains("Closure-Receipt:")) | select(.text | contains($s))' >/dev/null \
      || fail_tracker "operative Closure-Receipt comment not verified"
    br close "$bead" >/dev/null 2>&1 || fail_tracker "br close failed"
    post_state="closed" ;;
  status)
    br update "$bead" --status "$expected_state" >/dev/null 2>&1 \
      || fail_tracker "status transition refused" ;;
  *) fail_tracker "unknown transition $transition" ;;
esac

# 5. validate staged AND unstaged path sets; commit with an explicit pathspec
run_storage preflight --repo "$repo" --status-out "$TMP/status.json" --br-bin "$BR_BIN" >/dev/null 2>&1 \
  || fail_tracker "post-mutation preflight failed"
outside=$( { git diff --cached --name-only; git diff --name-only; } | grep -v '^\.beads/issues\.jsonl$' || true)
[ -z "$outside" ] || fail_tracker "staged or unstaged path outside .beads/issues.jsonl: $outside"
post_hash=$(sha256sum .beads/issues.jsonl | cut -d' ' -f1)
git add .beads/issues.jsonl
git commit -m "tracker: $transition $bead attempt=$attempt" -- .beads/issues.jsonl >/dev/null 2>&1 \
  || fail_tracker "receipt-only commit failed"

# 6. verify committed blob hash, then guarded fast-forward publish
committed=$(git rev-parse HEAD:.beads/issues.jsonl | xargs -I{} git cat-file blob {} | sha256sum | cut -d' ' -f1)
[ "$committed" = "$post_hash" ] || fail_tracker "committed blob hash mismatch"
git push origin main >/dev/null 2>&1 || fail_tracker "push failed (pending obligation)"

# 7. persist the receipt before releasing the pause
recv=$(jq -n --arg bead "$bead" --arg post "$post_state" --arg commit "$(git rev-parse HEAD)" \
  --arg source_hash "$actual_hash" --arg post_hash "$post_hash" --arg authority "$authority" \
  '{bead:$bead,status:$post,commit:$commit,source_hash:$source_hash,post_hash:$post_hash,authority:$authority,agent:"'"$agent"'"}')
fm_attempt_effect_observe "$attempt" "$gen" tracker "$recv" || fail_tracker "receipt persist failed"
rm -f "$STATE_DIR/.tracker-pause"
echo "tracker_receipt: $attempt $transition $bead $post_state $(git rev-parse HEAD)"
```

The pathspec-only invariant is enforced on both staged and unstaged sets; the commit uses an explicit pathspec so an unrelated already-staged path can never land. Every failure path records a durable pending obligation inside the single attempt record before releasing the pause; replay resumes from that record. No raw `br --claim` is ever executed (Task 7.4 boundary).

- [x] **Step 5: Verify**

Run: `bash tests/fm-br-receipt.test.sh; bash tests/live-decision-os-contract.test.sh` (the live guard self-skips without `FM_LIVE_DECISION_OS=1`; run it once with the env set against the real clone and record the result in `docs/verification/fleet-capacity.md` under `## Decision OS contract`).

- [x] **Step 6: Commit**

```bash
git add bin/fm-br-receipt.sh tests/fm-br-receipt.test.sh tests/live-decision-os-contract.test.sh
git commit -m "feat(tracker): authoritative br receipts with pathspec transaction and durable pending"
```

---

## Task 6: Spawn claim-before-allocation handshake and brief wiring

F5 correction (second half of the old Task 5) plus the F8 brief-wiring item.

**Files:**

- Modify: `bin/fm-spawn.sh`
- Modify: `bin/fm-brief.sh`
- Extend: `tests/fm-spawn-worktree-settle.test.sh`
- Extend: `tests/fm-brief.test.sh`

- [x] **Step 1: Write the failing tests**

Extend `tests/fm-spawn-worktree-settle.test.sh`:

```bash
test_no_workspace_or_endpoint_before_claim_observed() {
  # a refused claim must leave no workspace and no endpoint; replay after a
  # valid receipt must not double-claim
  local out rc
  ORDER_FILE="$ORDER" FM_REFILL_PROJECT="$TMP_ROOT/project" FM_STEWARD_EXIT=1 \
    "$ROOT/bin/fm-spawn.sh" ship test-task "$TMP_ROOT/project" >/dev/null 2>&1 || true
  # the spawn returned before allocation: no worktree, no endpoint, no meta
  [ ! -d "$TMP_ROOT/worktrees/test-task" ] || fail "workspace created before claim receipt"
  pass "no workspace or endpoint exists before claim_observed"
}

test_replay_after_receipt_does_not_double_claim() {
  # the storage ORDER file records exactly one claim invocation across a crash
  # and replay
  local n
  ORDER_FILE="$ORDER" FM_REFILL_PROJECT="$TMP_ROOT/project" FM_STEWARD_EXIT=0 FM_CRASH_AFTER_CLAIM=1 \
    "$ROOT/bin/fm-spawn.sh" ship test-task "$TMP_ROOT/project" >/dev/null 2>&1 || true
  ORDER_FILE="$ORDER" FM_REFILL_PROJECT="$TMP_ROOT/project" FM_STEWARD_EXIT=0 \
    "$ROOT/bin/fm-spawn.sh" ship test-task "$TMP_ROOT/project" >/dev/null 2>&1 || true
  n=$(grep -c '^claim ' "$ORDER" 2>/dev/null || echo 0)
  [ "$n" = 1 ] || fail "double claim on replay: $n"
  pass "replay after the receipt never double-claims"
}
```

Extend `tests/fm-brief.test.sh`:

```bash
test_ship_brief_carries_attempt_and_claim_requirement() {
  local brief
  brief=$(FM_HOME="$TMP_HOME" "$ROOT/bin/fm-brief.sh" --ship "$ID" "fixture" 2>/dev/null \
    || "$ROOT/bin/fm-brief.sh" ship "$ID" fixture 2>/dev/null)
  assert_contains "$brief" "attempt_id" "brief lacks attempt id"
  assert_contains "$brief" "claim-before-allocation" "brief lacks the claim requirement"
  pass "ship briefs carry the attempt id and the claim-before-allocation requirement"
}
```

(The exact `fm-brief.sh` invocation shape is taken from `bin/fm-brief.sh --help` during implementation.)

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-spawn-worktree-settle.test.sh; bash tests/fm-brief.test.sh`
Expected: FAIL on the new tests.

- [x] **Step 3: Wire the split handshake into `bin/fm-spawn.sh`**

Modify `bin/fm-spawn.sh` intake, before any workspace allocation and before any endpoint creation (the anchor is the existing intake block before the `treehouse get` region):

1. Allocate the immutable attempt: `attempt_id=$(fm_attempt_alloc pi "$task_key" "$home_id")` where `task_key` is the bead id for a bead-backed task and the backlog item id otherwise.
2. Persist the exact claim request at `state/attempts/$attempt_id.request.claim.json` with `{attempt_id, generation, bead_id, transition:"claim", expected_state:"open", expected_source_hash:<sha256 of the registered clone's .beads/issues.jsonl>, evidence:"intake", authority:"<current-session authority>", agent:"<bound agent>", repo:"<registered clone>"}`.
3. Invoke `fm-br-receipt.sh "$REQ"` synchronously (attended). On success the tracker receipt is persisted; on refusal or steward unavailability the attempt stays pending with the failure recorded in the attempt record, and spawn returns without allocating any workspace or launching any endpoint.
4. Write `attempt=<attempt_id>` into `state/<id>.meta`.
5. After the provider allocation and launch complete and instruction-delivery confirmation succeeds, append one ledger row `{attempt_id, launched_at, endpoint}` to `state/launch-ledger.jsonl`, guarded so a row for that attempt id is appended at most once; recovery of a crash before ledger publication relies on the attempt envelope, never the ledger.

- [x] **Step 4: Wire `bin/fm-brief.sh`**

Modify the ship-brief scaffold so the generated brief includes the attempt id placeholder and the claim-before-allocation requirement line (the exact scaffold location is `bin/fm-brief.sh`'s ship template). The line reads: `This task runs through claim-before-allocation: no workspace or endpoint exists before the authoritative Decision OS claim receipt is observed (attempt <attempt_id>).`

- [x] **Step 5: Verify**

Run: `bash tests/fm-spawn-worktree-settle.test.sh; bash tests/fm-brief.test.sh; bash tests/fm-br-receipt.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green.

- [x] **Step 6: Commit**

```bash
git add bin/fm-spawn.sh bin/fm-brief.sh
git add tests/fm-spawn-worktree-settle.test.sh tests/fm-brief.test.sh
git commit -m "feat(tracker): claim-before-allocation handshake and brief wiring"
```

---

## Task 7: Attempt-bound provider-wide physical-copy ownership

F7 correction plus decision-os Task 7.2. The lease identity binds both home and attempt; same-home concurrent attempts are distinguished.

**Files:**

- Modify: `bin/fm-spawn.sh` (allocation claim)
- Modify: `bin/fm-home-seed.sh`
- Modify: `bin/fm-backend.sh`
- Extend: `tests/fm-spawn-worktree-settle.test.sh`, `tests/fm-secondmate-safety.test.sh`, `tests/fm-backend-orca.test.sh`

- [x] **Step 1: Write the failing tests**

Add the shared claim fixture to `tests/fm-spawn-worktree-settle.test.sh` before the new tests:

```bash
claim_copy() {  # <home> <attempt>; fake treehouse get --lease --lease-holder
  mkdir -p "$TMP_ROOT/pool"
  local holder="$1:$2"
  local i
  for i in 1 2 3; do
    if [ ! -e "$TMP_ROOT/pool/copy-$i" ]; then
      printf '%s\n' "$holder" > "$TMP_ROOT/pool/copy-$i.holder"
      touch "$TMP_ROOT/pool/copy-$i"
      printf '%s\n' "$TMP_ROOT/pool/copy-$i"
      return 0
    fi
    if [ "$(cat "$TMP_ROOT/pool/copy-$i.holder")" = "$holder" ]; then
      printf '%s\n' "$TMP_ROOT/pool/copy-$i"
      return 0
    fi
  done
  echo "pool exhausted" >&2
  return 1
}
HOLDER_1() { cat "$TMP_ROOT/pool/copy-1.holder"; }
HOLDER_2() { cat "$TMP_ROOT/pool/copy-2.holder"; }
```

Extend `tests/fm-spawn-worktree-settle.test.sh`:

```bash
test_same_home_concurrent_attempts_get_distinct_copies() {
  # two attempts in the same home acquire two distinct pooled copies; the
  # lease-holder records home AND attempt
  local c1 c2
  c1=$(claim_copy "home-a" "attempt-a1")
  c2=$(claim_copy "home-a" "attempt-a2")
  [ "$c1" != "$c2" ] || fail "same-home attempts share a copy"
  [ "$(cat "$HOLDER_1")" = "home-a:attempt-a1" ] || fail "lease holder lacks attempt identity"
  [ "$(cat "$HOLDER_2")" = "home-a:attempt-a2" ] || fail "second attempt lease holder"
  pass "two attempts in the same home cannot acquire the same physical copy"
}

test_crash_after_allocation_retains_pending_release_obligation() {
  # crash after the provider receipt but before launch; the attempt record
  # carries the provider effect and the release obligation derives from the
  # missing launch effect
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-c holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  assert_contains "$(fm_attempt_obligations "$aid")" "launch" "no pending obligation after crash"
  pass "a crash after allocation retains a pending release obligation"
}

test_replay_releases_only_the_exact_owning_attempt() {
  # two attempts, one owns copy C; replay of the other must not release C
  local aid1 aid2
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid1=$(fm_attempt_alloc pi dos-d holu)
  aid2=$(fm_attempt_alloc pi dos-e holu)
  fm_attempt_freeze_allocation "$aid1" 1 '{"provider":"tmux","copy":"wt-d"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}'
  fm_attempt_freeze_allocation "$aid2" 1 '{"provider":"tmux","copy":"wt-e"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}'
  [ "$(fm_attempt_load "$aid2" | jq -r '.provider.copy')" = wt-e ] || fail "a2 owns wrong copy"
  [ "$(fm_attempt_load "$aid1" | jq -r '.provider.copy')" = wt-d ] || fail "a1 lost its copy"
  pass "replay releases only the exact owning attempt"
}
```

Extend `tests/fm-backend-orca.test.sh` with the same shapes against the Orca worktree claim surface, and `tests/fm-secondmate-safety.test.sh` for the secondmate lease.

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-spawn-worktree-settle.test.sh; bash tests/fm-secondmate-safety.test.sh; bash tests/fm-backend-orca.test.sh`
Expected: FAIL on the new tests.

- [x] **Step 3: Implement attempt-bound ownership**

In `bin/fm-spawn.sh` after the claim receipt is observed:

1. Acquire the physical copy with a provider claim bound to home AND attempt: for treehouse use `treehouse get --lease --lease-holder "$home_id:$attempt_id"` (the same primitive `fm-home-seed.sh` uses at lines 392-400, extended with the attempt), for Orca the existing `orca worktree` claim path carrying the same `home:attempt` identity. One physical copy is owned by exactly one `(home_id, attempt_id)`.
2. On success, freeze the allocation with the provider copy identity and delivery contract through `fm_attempt_freeze_allocation "$attempt" "$gen" '{"provider":"<backend>","copy":"<path>"}' '{"mode":"<mode>","base":"<base>","target":"<target>","planned_path":"<provisional>","declared_seams":"<seams>","dependencies":"<deps>"}'` (planned-path, seam, and dependency evidence is provisional admission evidence frozen at allocation; it is never authority).
3. A crash after allocation leaves the provider effect in place; the release obligation derives from the missing launch effect; replay verifies the attempt owns the exact copy before touching it and never releases a copy owned by a different attempt or home.

In `bin/fm-home-seed.sh`, bind the secondmate lease through the same `home:attempt` identity when the seed is itself an attempt (Task 7.2's no-second-Treehouse-lease-store boundary: the attempt record is the coordination owner, the treehouse lease remains the provider store).

In `bin/fm-backend.sh`, add `fm_backend_stop_receipt <backend> <id>` returning the durable endpoint-stop evidence JSON (window/tab/pane identity plus confirmed-gone verdict) that cleanup records as the `cleanup.endpoint` effect.

- [x] **Step 4: Verify**

Run: `bash tests/fm-spawn-worktree-settle.test.sh; bash tests/fm-secondmate-safety.test.sh; bash tests/fm-backend-orca.test.sh; bash tests/fm-teardown.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green.

- [x] **Step 5: Commit**

```bash
git add bin/fm-spawn.sh bin/fm-home-seed.sh bin/fm-backend.sh
git add tests/fm-spawn-worktree-settle.test.sh tests/fm-secondmate-safety.test.sh tests/fm-backend-orca.test.sh
git commit -m "feat(attempts): make workspace claims attempt-bound and provider-wide"
```

---

## Task 8: Behavior-preserving cleanup extraction

F8 correction (first third of the old Task 8). Extraction only: no new semantics, no receipts, teardown behavior byte-identical.

**Files:**

- Create: `bin/fm-cleanup-lib.sh` (extraction)
- Modify: `bin/fm-teardown.sh` (source the lib, keep behavior)
- Extend: `tests/fm-teardown.test.sh` (extraction identity)

- [x] **Step 1: Write the failing tests**

Extend `tests/fm-teardown.test.sh`:

```bash
test_extraction_is_behavior_identical() {
  # run the same teardown fixture before and after extraction; stdout, exit
  # code, and resulting state must be identical
  local before after
  before=$(run_teardown_fixture)   # helper capturing output and rc
  after=$(run_teardown_fixture)    # same helper after the extraction commit
  [ "$before" = "$after" ] || fail "extraction changed teardown behavior"
  pass "the extraction preserves teardown behavior byte-for-byte"
}
```

The fixture helper runs `bin/fm-teardown.sh <id> --force` against a prepared task and captures stdout plus exit code.

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-teardown.test.sh`
Expected: the new identity test fails only if behavior differs; before extraction it passes vacuously, so mark this step as the pin that must stay green through Task 9.

- [x] **Step 3: Extract into `bin/fm-cleanup-lib.sh` with identical behavior**

Move the existing functions from `bin/fm-teardown.sh` into `bin/fm-cleanup-lib.sh` verbatim: `teardown_treehouse_return` (line 996), `work_is_landed`/`pr_number_from_branch` (lines 824/699), `retire_busy_state` (line 606), `remove_pr_poll_artifacts` (line 677), the provider-specific quiet and herdr endpoint-confirmed-gone checks, the orca worktree path match, and the final state-file removal block. `bin/fm-teardown.sh` sources the library and keeps its exact main flow. No new semantics, no receipts, no disposition parameter, no lock changes in this task.

- [x] **Step 4: Verify**

Run: `bash tests/fm-teardown.test.sh; bash tests/fm-teardown-endpoint-safety.test.sh; bash tests/fm-secondmate-safety.test.sh`
Expected: all green with no behavioral change.

- [x] **Step 5: Commit**

```bash
git add bin/fm-cleanup-lib.sh bin/fm-teardown.sh tests/fm-teardown.test.sh
git commit -m "refactor(cleanup): extract teardown cleanup into fm-cleanup-lib.sh with identical behavior"
```

---

## Task 9: Structured cleanup receipts and the teardown compatibility wrapper

F8 correction (second and third thirds of the old Task 8) plus F2's lock-held cleanup. One structured operation returns per-effect receipts; all non-mutating refusals are preflighted before any effect.

**Files:**

- Modify: `bin/fm-cleanup-lib.sh` (structured operation with lock-held primitives)
- Create: `tests/fm-cleanup.test.sh`
- Modify: `bin/fm-teardown.sh` (compatibility wrapper)
- Extend: `tests/fm-teardown.test.sh`, `tests/fm-teardown-endpoint-safety.test.sh`

- [x] **Step 1: Write the failing tests**

Create `tests/fm-cleanup.test.sh`:

```bash
#!/usr/bin/env bash
# Public-interface tests for the structured attempt-bound cleanup operation:
# preflight-all-refusals-before-effects, per-effect receipts, branch-fate
# failure recording, wrapper identity, and nested-lock refusal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cleanup)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
export FM_STATE_OVERRIDE="$STATE"
# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

setup_cleanup_attempt() {  # -> attempt id with claim+launch receipts and a tmux provider copy
  local aid
  aid=$(fm_attempt_alloc pi dos-g holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 "{\"provider\":\"tmux\",\"copy\":\"$TMP_ROOT/wt-g\"}" \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-g"}' || fail "launch"
  printf '%s\n' "$aid"
}

test_cleanup_refuses_live_processes_and_immature_quiet() {
  local aid out
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  (cd "$TMP_ROOT/wt-g" && sleep 300) &
  local pid=$!
  out=$(FM_TERMINAL_QUIET_SECS=100 "$ROOT/bin/fm-cleanup-lib.sh" --run "$aid" landed 2>&1 || true)
  kill "$pid" 2>/dev/null || true
  assert_contains "$out" "refused" "cleanup did not refuse"
  [ -d "$TMP_ROOT/wt-g" ] || fail "copy was removed on refusal"
  jq -e --arg n cleanup.endpoint '[.receipts[$n][]? | select(.state == "observed")] | length == 0' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "effect written despite refusal"
  pass "live processes and immature quiet preserve the copy with no effect written"
}

test_preflight_runs_before_any_effect() {
  # a refusal condition must prevent ALL effects: no endpoint, branch, provider,
  # or runtime effect may be observed
  local aid out
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  (cd "$TMP_ROOT/wt-g" && sleep 300) &
  local pid=$!
  out=$(FM_TERMINAL_QUIET_SECS=0 "$ROOT/bin/fm-cleanup-lib.sh" --run "$aid" landed 2>&1 || true)
  kill "$pid" 2>/dev/null || true
  local n
  n=$(jq '[.receipts | to_entries[] | select(.key | startswith("cleanup.")) | .value[] | select(.state == "observed")] | length' \
    "$STATE/attempts/$aid.json")
  [ "$n" = 0 ] || fail "effects observed despite preflight refusal: $n"
  pass "all non-mutating refusal checks run before any endpoint stop, branch, or provider mutation"
}

test_cleanup_records_branch_disposition_failure() {
  local aid out
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  out=$(FM_TERMINAL_QUIET_SECS=0 FM_BRANCH_DELETE_FAIL=1 \
    "$ROOT/bin/fm-cleanup-lib.sh" --run "$aid" landed 2>&1 || true)
  jq -e --arg n cleanup.branch '[.receipts[$n][]? | select(.state == "observed")][0].evidence.failed == true' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "branch-disposition failure suppressed"
  pass "branch-disposition failure is recorded, never suppressed"
}

test_teardown_wrapper_identity() {
  local aid out
  aid=$(setup_cleanup_attempt)
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\nworktree=%s/wt-g\n' "$aid" "$TMP_ROOT" > "$STATE/task-g.meta"
  out=$(FM_TERMINAL_QUIET_SECS=0 "$ROOT/bin/fm-teardown.sh" task-g --force 2>&1 || true)
  jq -e --arg n cleanup.runtime '[.receipts[$n][]? | select(.state == "observed")] | length == 1' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "teardown wrapper did not run the shared operation"
  pass "fm-teardown.sh is a compatibility wrapper over the same operation"
}

test_nested_lock_acquire_refuses() {
  local aid
  aid=$(setup_cleanup_attempt)
  fm_attempt_lock_acquire "$aid" || fail "outer acquire"
  fm_attempt_lock_acquire "$aid" && fail "nested acquire succeeded"
  fm_attempt_lock_release "$aid"
  pass "the cleanup path never reacquires a held attempt lock"
}

test_cleanup_refuses_live_processes_and_immature_quiet
test_preflight_runs_before_any_effect
test_cleanup_records_branch_disposition_failure
test_teardown_wrapper_identity
test_nested_lock_acquire_refuses
```

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-cleanup.test.sh`
Expected: FAIL with `fm-cleanup-lib.sh --run` unrecognized.

- [x] **Step 3: Add the structured operation to `bin/fm-cleanup-lib.sh`**

```bash
#!/usr/bin/env bash
# One structured attempt-bound cleanup operation, factored from
# bin/fm-teardown.sh. Reuses the current safety and provider logic; owns no
# product-landing policy. Accepts an already classified disposition
# (landed | preserved_unlanded | unknown) and returns durable per-effect
# receipts. All non-mutating refusal checks run before any effect; the
# operation runs under the attempt lock through lock-held primitives that
# never reacquire.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"

FM_TERMINAL_QUIET_SECS="${FM_TERMINAL_QUIET_SECS:-7200}"

fm_cleanup_preflight() {  # <attempt_id> <disposition>; 0 only when ALL pass
  local attempt=$1 disposition=$2 gen copy
  gen=$(fm_attempt_generation_held "$attempt") || return 1
  case "$disposition" in
    landed|preserved_unlanded) ;;
    *) echo "cleanup: unknown disposition refuses destructive cleanup" >&2; return 1 ;;
  esac
  copy=$(fm_attempt_load "$attempt" | jq -r '.provider.copy // ""')
  [ -n "$copy" ] || { echo "cleanup: no owned copy identity" >&2; return 1; }
  # identity match: the attempt owns the exact copy
  [ "$(fm_attempt_load "$attempt" | jq -r '.provider.provider // ""')" = tmux ] \
    && [ ! -d "$copy" ] && { echo "cleanup: owned copy missing" >&2; return 1; }
  # live processes with cwd under the copy refuse
  pids_with_cwd_under "$copy" | grep -q . && { echo "cleanup: live process in copy" >&2; return 1; }
  # dirty worktree / later head refuses
  git -C "$copy" status --porcelain 2>/dev/null | grep -q . && { echo "cleanup: dirty copy" >&2; return 1; }
  # immature quiet refuses
  local quiet
  quiet=$(copy_quiet_age "$copy")   # minutes since last activity, owned by fm-teardown logic
  [ "$quiet" -ge "$((FM_TERMINAL_QUIET_SECS / 60))" ] || { echo "cleanup: quiet interval immature" >&2; return 1; }
  # the write-once effect primitives (Task 1) refuse any contradictory second
  # observation, so no separate conflict check is needed here; replay resumes
  # at the persisted receipt boundary and only writes the missing effects
}

fm_cleanup_effects_present() {  # <attempt_id> <disposition>; 0 when every required cleanup effect is observed
  local attempt=$1 disposition=$2 required
  required="cleanup.endpoint cleanup.branch cleanup.provider cleanup.runtime"
  [ "$disposition" = preserved_unlanded ] && required="$required cleanup.preservation"
  jq -e --argjson required "$(printf '%s' "$required" | jq -R 'split(" ")')" \
    '. as $root |
     [ $required[] as $name | select(([$root.receipts[$name][]? | select(.state == "observed")] | length) == 0) ] | length == 0' \
    "$(attempt_path "$attempt")" >/dev/null 2>&1
}

fm_cleanup_attempt_held() {  # <attempt_id> <disposition>; caller holds the attempt lock
  local attempt=$1 disposition=$2 gen copy backend
  gen=$(fm_attempt_generation_held "$attempt") || return 1
  fm_cleanup_preflight "$attempt" "$disposition" || return 1
  # idempotent replay: an already-fully-cleaned attempt is a no-op success
  fm_cleanup_effects_present "$attempt" "$disposition" && { echo "cleanup: $attempt already complete"; return 0; }
  copy=$(fm_attempt_load "$attempt" | jq -r '.provider.copy // ""')
  backend=$(fm_attempt_load "$attempt" | jq -r '.provider.provider // ""')
  # 1. endpoint stop
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.endpoint \
    "$(fm_backend_stop_receipt "$backend" "$attempt")" || return 1
  # 2. preservation ref for preserved_unlanded only
  if [ "$disposition" = preserved_unlanded ]; then
    git -C "$copy" update-ref "refs/fm-preserve/$attempt" HEAD 2>/dev/null || true
    fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.preservation \
      '{"ref":"refs/fm-preserve/'"$attempt"'","head":'"$(git -C "$copy" rev-parse HEAD 2>/dev/null || echo null)"'}' || return 1
  fi
  # 3. branch fate: record, never suppress
  local fate
  fate=$(branch_fate_json "$copy" "$attempt")   # FM_BRANCH_DELETE_FAIL=1 test hook records failed
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.branch "$fate" || return 1
  # 4. provider return
  if ! provider_return "$backend" "$copy" "$attempt"; then
    echo "cleanup: provider return failed; copy preserved for $attempt" >&2
    return 1
  fi
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.provider \
    "{\"provider\":\"$backend\",\"returned\":true,\"copy\":\"$copy\"}" || return 1
  # 5. runtime-record retirement (the exact removals fm-teardown.sh performs)
  retire_runtime_records "$attempt" || return 1
  fm_attempt_effect_observe_held "$attempt" "$gen" cleanup.runtime \
    '{"records_removed":true}' || return 1
  echo "cleanup: $attempt disposition=$disposition complete"
}

fm_cleanup_attempt() {  # <attempt_id> <disposition>; public entry: acquire once
  local attempt=$1 disposition=$2 rc
  fm_attempt_lock_acquire "$attempt" || return 1
  fm_cleanup_attempt_held "$attempt" "$disposition"
  rc=$?
  fm_attempt_lock_release "$attempt"
  return $rc
}

if [ "${1:-}" = "--run" ]; then
  fm_cleanup_attempt "$2" "$3"
  exit $?
fi
```

`branch_fate_json`, `provider_return`, `retire_runtime_records`, `pids_with_cwd_under`, and `copy_quiet_age` are the functions extracted in Task 8, now driven under the attempt lock. `branch_fate_json` honors `FM_BRANCH_DELETE_FAIL=1` (records `{"failed":true}` without touching a real ref).

- [x] **Step 4: Convert `bin/fm-teardown.sh` into the compatibility wrapper**

Replace the teardown main flow so it resolves the task to an attempt, classifies the disposition through `fm_disposition_live` (Task 4), and calls `fm_cleanup_attempt "$attempt" "$disposition"`; `--force` resolves to a `preserved_unlanded`-with-discard disposition exactly as today. The CLI stays `fm-teardown.sh <task-id> [--force]` and the wrapper adds no second cleanup policy. The header's landed-work proofs, PR-discovery fallback, and stale-lock recovery procedure remain authoritative.

- [x] **Step 5: Verify**

Run: `bash tests/fm-cleanup.test.sh; bash tests/fm-teardown.test.sh; bash tests/fm-teardown-endpoint-safety.test.sh; bash tests/fm-secondmate-safety.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green, including the pre-existing teardown suites.

- [x] **Step 6: Commit**

```bash
git add bin/fm-cleanup-lib.sh bin/fm-teardown.sh
git add tests/fm-cleanup.test.sh tests/fm-teardown.test.sh tests/fm-teardown-endpoint-safety.test.sh
git commit -m "feat(cleanup): structured per-effect receipts and teardown compatibility wrapper"
```

---

## Task 10: Forge and landing observations with a final landing receipt

F7 correction plus decision-os Task 7.3. PR check/merge/poll/local-merge write provisional observations; only the disposition step writes the final immutable landing receipt.

**Files:**

- Modify: `bin/fm-pr-lib.sh`, `bin/fm-pr-check.sh`, `bin/fm-pr-merge.sh`, `bin/fm-pr-poll.sh`, `bin/fm-merge-local.sh`
- Extend: `tests/fm-pr-check-security.test.sh`, `tests/fm-pr-merge.test.sh`

- [x] **Step 1: Write the failing tests**

Extend `tests/fm-pr-check-security.test.sh` with a shared attempt fixture:

```bash
setup_pr_attempt() {  # -> prints an attempt id with claim+launch receipts
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-p holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-p"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-p"}' || fail "launch"
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\n' "$aid" > "$STATE/task-p.meta"
  printf '%s\n' "$aid"
}

test_open_observation_is_journaled_not_receipted() {
  local aid
  aid=$(setup_pr_attempt)
  # fake gh-axi returns open; run fm-pr-check against the fake PR, then assert
  # the observation journal grew and no landing receipt exists
  FAKEBIN="$TMP_ROOT/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"state":"OPEN","headRefOid":"abc123","baseRefOid":"old"}'
SH
  chmod +x "$FAKEBIN/gh-axi"
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-pr-check.sh" task-p "https://github.com/kunchenguid/firstmate/pull/1" >/dev/null 2>&1 || true
  jq -e --arg n landing '[.receipts[$n][]? | select(.state == "observed")] | length == 0' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "open observation became a landing receipt"
  jq -e '[.observations[]? | select(.name == "forge")] | length >= 1' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "open observation not journaled"
  pass "provisional forge observations append to the journal and never become receipts"
}

test_final_landing_receipt_written_once_at_disposition() {
  local aid
  aid=$(setup_pr_attempt)
  # open -> merged sequence: the journal grows; the disposition step then
  # writes the final landing receipt exactly once
  fm_attempt_observe "$aid" 1 forge '{"provider":"github","pr":"https://github.com/kunchenguid/firstmate/pull/1","state":"open"}' \
    || fail "open journal"
  fm_attempt_observe "$aid" 1 forge '{"provider":"github","pr":"https://github.com/kunchenguid/firstmate/pull/1","state":"merged","head":"abc123","before_sha":"old","after_sha":"new"}' \
    || fail "merged journal"
  # the disposition step (Task 11 consumer) writes the final landing receipt
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","provider":"github","repo":"kunchenguid/firstmate","source":"task-p","target":"origin/main","head":"abc123","before_sha":"old","after_sha":"new"}' \
    || fail "landing receipt"
  jq -e --arg n landing '[.receipts[$n][]? | select(.state == "observed")] | length == 1' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "landing receipt not written exactly once"
  jq -e --arg n landing '[.receipts[$n][]? | select(.state == "observed")][0].evidence.provider == "github" and
    [.receipts[$n][]? | select(.state == "observed")][0].evidence.head == "abc123" and
    [.receipts[$n][]? | select(.state == "observed")][0].evidence.before_sha == "old" and
    [.receipts[$n][]? | select(.state == "observed")][0].evidence.after_sha == "new"' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "landing identity not exact"
  pass "the final landing receipt is written once, bound to disposition, with exact identity"
}

test_unknown_forge_never_guesses() {
  local aid
  aid=$(setup_pr_attempt)
  # missing-head and unknown forge states stay unknown, never guessed
  fm_attempt_observe "$aid" 1 forge '{"provider":"gitlab","pr":"https://gitlab.example/x","state":"unknown","head":null}' \
    || fail "unknown journal"
  [ "$(fm_attempt_landing_disposition "$aid")" = "" ] || fail "unknown forge inferred a disposition"
  pass "missing-head and unknown forge observations remain unknown"
}
```

Extend `tests/fm-pr-merge.test.sh` for squash-merge landing proof and local-only merge proof.

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-pr-check-security.test.sh; bash tests/fm-pr-merge.test.sh`
Expected: FAIL on the new tests.

- [x] **Step 3: Implement observation-first landing semantics**

For each of `fm-pr-check.sh`, `fm-pr-merge.sh`, `fm-pr-poll.sh`, and `fm-merge-local.sh`: after the authoritative observation, when the task meta carries `attempt=`, append the provisional observation through `fm_attempt_observe "$attempt" "$gen" forge '<evidence>'` where evidence contains `{provider, repo, source, target, head, state, before_sha, after_sha}` with every field populated or explicitly null, never inferred. The final immutable `landing` receipt is written only by the disposition step (Task 11's `fm_disposition_live` consumer) through `fm_attempt_effect_observe`, bound to the disposition; a squash merge is `landed` only when existing Git and forge proof establishes content equivalence (reuse `patch_id_for_commit`/`unpushed_patches_are_in_pr_head` from the extracted teardown logic, never duplicate). `bin/fm-pr-lib.sh` owns the observation evidence schema; `pr=`/`pr_head=` meta fields stay as today.

- [x] **Step 4: Verify**

Run: `bash tests/fm-pr-check-security.test.sh; bash tests/fm-pr-merge.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green.

- [x] **Step 5: Commit**

```bash
git add bin/fm-pr-lib.sh bin/fm-pr-check.sh bin/fm-pr-merge.sh bin/fm-pr-poll.sh bin/fm-merge-local.sh
git add tests/fm-pr-check-security.test.sh tests/fm-pr-merge.test.sh
git commit -m "feat(delivery): journal provisional forge observations and write the final landing receipt once"
```

---

## Task 11: Ordered terminal transaction

F2, F6, and F7 corrections plus decision-os Task 7.5. One outer non-reentrant attempt lock spans verification through retirement; all mutations use lock-held primitives; fresh per-effect authority and a pre-land actual-diff recheck gate the irreversible effects.

**Files:**

- Create: `bin/fm-terminal.sh`
- Create: `tests/fm-terminal.test.sh`

- [x] **Step 1: Write the failing tests**

Create `tests/fm-terminal.test.sh`. The shared fixture helper builds a fully landed attempt:

```bash
setup_terminal_attempt() {  # -> prints a fully landed attempt id (claim+launch+landing receipts)
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-t holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 "{\"provider\":\"tmux\",\"copy\":\"$TMP_ROOT/wt-t\"}" \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-t"}' || fail "launch"
  fm_attempt_effect_observe "$aid" 1 landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  printf '%s\n' "$aid"
}

semantic_equiv() {  # <file-a> <file-b>; compares receipt names/states/evidence with timestamps stripped
  jq -S '[.receipts | to_entries[] | {name:.key, entries:[.value[] | {state,evidence}]}]' "$1" \
    > "$TMP_ROOT/sem-a.json"
  jq -S '[.receipts | to_entries[] | {name:.key, entries:[.value[] | {state,evidence}]}]' "$2" \
    > "$TMP_ROOT/sem-b.json"
  cmp -s "$TMP_ROOT/sem-a.json" "$TMP_ROOT/sem-b.json"
}
```

Tests:

```bash
test_outer_lock_spans_verification_through_retirement() {
  # with FM_TERMINAL_HOLD_LOCK_PROBE=1, the orchestrator proves it holds the
  # attempt lock at steps 1 and 8 (nested acquire refuses) and releases it
  # before the fresh projection in step 9
  local aid out
  aid=$(setup_terminal_attempt)
  out=$(FM_TERMINAL_HOLD_LOCK_PROBE=1 FM_TERMINAL_QUIET_SECS=0 \
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "lock-held-at-step-1" "orchestrator did not hold the lock at step 1"
  assert_contains "$out" "lock-held-at-step-8" "orchestrator did not hold the lock at step 8"
  assert_contains "$out" "lock-released-before-step-9" "lock not released before the fresh projection"
  pass "one outer non-reentrant lock spans steps 1-8 and releases before step 9"
}

test_crash_after_every_effect_replays_to_semantic_equivalence() {
  # crash after each receipt boundary; replay converges to the same effect
  # set, compared semantically (receipt names + states + evidence), not by
  # byte-identical timestamps or attempt ids
  local baseline aid
  baseline=$(setup_terminal_attempt)
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$baseline" >/dev/null 2>&1 || true
  for point in claim launch closure cleanup retirement; do
    aid=$(setup_terminal_attempt)
    FM_STATE_OVERRIDE="$STATE" FM_TERMINAL_CRASH_AFTER="$point" \
      "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 || true
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 || true
    semantic_equiv "$STATE/attempts/$baseline.json" "$STATE/attempts/$aid.json" \
      || fail "replay after $point did not converge semantically"
  done
  pass "replay after every irreversible effect converges to a semantically equivalent record"
}

test_concurrent_terminal_and_refill_are_deterministic() {
  # one terminal run and one refill projection race; the projection sees
  # either pre-retirement ownership or a post-retirement deficit, never an
  # intermediate free slot. The terminal runs in the background while the
  # projection samples repeatedly; every sample must show the attempt either
  # reserved or retired, never absent-then-free.
  local aid out bad
  aid=$(setup_terminal_attempt)
  FM_TERMINAL_QUIET_SECS=0 FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 &
  local pid=$!
  bad=0
  local i
  for i in 1 2 3 4 5; do
    out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
    # the attempt record outlives the meta, so every sample shows the attempt
    # either pre-retirement (reserved) or retired - never an intermediate
    # state with reserved=false and classification != retired
    echo "$out" | jq -e --arg id "$aid" \
      '([.rows[] | select(.attempt_id == $id) | .reserved == true or .classification == "retired"] | length) == 1' \
      >/dev/null 2>&1 || bad=1
  done
  wait "$pid" 2>/dev/null || true
  [ "$bad" = 0 ] || fail "projection observed an intermediate free slot"
  pass "concurrent terminal and refill see no intermediate free slot"
}

test_unknown_forge_state_refuses_destructive_cleanup() {
  local out
  out=$(FM_TERMINAL_FORGE=unknown "$ROOT/bin/fm-terminal.sh" "$(setup_terminal_attempt)" 2>&1 || true)
  assert_contains "$out" "reconciliation" "unknown forge did not stop with ownership preserved"
  pass "unknown forge state refuses destructive cleanup and preserves ownership"
}

test_fresh_closure_authority_is_required() {
  # a claim-only authority record must not authorize bead closure
  local out
  printf '%s\n' '{"transition":"claim","authority":"captain:dispatch"}' > "$STATE/authority-current.json"
  out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$(setup_terminal_attempt)" 2>&1 || true)
  assert_contains "$out" "authority" "closure without fresh authority proceeded"
  pass "claim authorization never authorizes later bead closure or destructive cleanup"
}

test_immature_quiet_preserves_copy_then_matures() {
  local aid out
  aid=$(setup_terminal_attempt)
  out=$(FM_TERMINAL_QUIET_SECS=100000 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "quiet" "immature quiet did not preserve the copy"
  out=$(FM_TERMINAL_QUIET_SECS=0 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "cleanup:" "mature replay did not remove the copy"
  pass "immature quiet preserves the copy; a later replay removes it only after maturity"
}

test_preland_actual_diff_conflict_refuses_landing() {
  # FM_REVIEW_DIFF_CONFLICT=1 makes the existing fm-review-diff.sh path report
  # a concrete overlap with another attempt; landing must refuse and serialize
  local out
  out=$(FM_REVIEW_DIFF_CONFLICT=1 "$ROOT/bin/fm-terminal.sh" "$(setup_terminal_attempt)" 2>&1 || true)
  assert_contains "$out" "pre-land" "pre-land actual-diff conflict not enforced"
  pass "the pre-land actual-diff recheck refuses landing on a concrete overlap"
}
```

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-terminal.test.sh`
Expected: FAIL with `fm-terminal.sh: No such file`.

- [x] **Step 3: Implement `bin/fm-terminal.sh`**

```bash
#!/usr/bin/env bash
# Sole Firstmate attempt-to-terminal orchestrator. Owns no branch,
# provider-copy, or runtime cleanup implementation of its own: it composes
# fm-cleanup-lib.sh and requests tracker mutations through fm-br-receipt.sh.
# Implements the design's ordered terminal composition inside ONE outer
# non-reentrant attempt lock held from step 1 through step 8; step 9 runs
# after release. All internal mutations use lock-held primitives that never
# reacquire.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"
# shellcheck source=bin/fm-cleanup-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-cleanup-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
# shellcheck source=bin/fm-disposition-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-disposition-lib.sh"

attempt=$1
STATE_DIR="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

fm_attempt_lock_acquire "$attempt" || { echo "terminal: attempt lock busy: $attempt" >&2; exit 1; }
trap 'fm_attempt_lock_release "$attempt" 2>/dev/null || true' EXIT
gen=$(fm_attempt_generation_held "$attempt") || exit 1

# 1. verify the immutable attempt, generation, home, bead binding, live bead,
#    and owned provider identity
bead=$(fm_attempt_load "$attempt" | jq -r '.envelope.task_key')
br show --json "$bead" 2>/dev/null | jq -e '.[0].id == "'"$bead"'"' >/dev/null || {
  echo "terminal: live bead verification failed for $attempt; preserving ownership" >&2
  exit 1
}

# 2. re-read worker, endpoint, Git, forge, bead, copy, and queue facts and
#    classify the exact delivery (centralized disposition, Task 4)
disp=$(fm_disposition_live "$attempt")
[ -n "$disp" ] || { echo "terminal: unknown disposition for $attempt" >&2; exit 1; }

# 3. fresh per-effect authority for each irreversible transition; the claim
#    request's authority never authorizes closure, merge, or discard
close_authority=$(fm_authority_for close "$bead") || { echo "terminal: missing close authority" >&2; exit 1; }

# 3b. pre-land actual-diff recheck: the existing diff helper is authoritative
#     for overlap; a concrete conflict refuses landing and serializes
if [ "$disp" = landed ]; then
  if ! fm_review_diff_recheck "$attempt"; then
    echo "terminal: pre-land actual-diff conflict; landing refused for $attempt" >&2
    exit 1
  fi
fi

# 4. for truthful landed delivery only, request the Closure-Receipt and
#    canonical bead closure through the attended steward, then verify the
#    current-generation tracker receipt
if [ "$disp" = landed ]; then
  req=$(jq -n --arg attempt_id "$attempt" --argjson generation "$gen" \
    --arg bead_id "$bead" --arg transition close --arg authority "$close_authority" \
    --arg repo "${FM_REFILL_PROJECT:-/home/holu/decision-os}" \
    --arg agent "${BR_AGENT_NAME:-}" \
    --arg hash "$(sha256sum "${FM_REFILL_PROJECT:-/home/holu/decision-os}/.beads/issues.jsonl" | cut -d' ' -f1)" \
    '{attempt_id:$attempt_id,generation:$generation,bead_id:$bead_id,transition:$transition,expected_state:"open",expected_source_hash:$hash,evidence:"terminal",authority:$authority,agent:$agent,repo:$repo}')
  echo "$req" > "$STATE_DIR/attempts/$attempt.request.close.json"
  fm-br-receipt.sh "$STATE_DIR/attempts/$attempt.request.close.json" \
    || { echo "terminal: tracker receipt pending for $attempt" >&2; exit 1; }
fi

# 5. preserved_unlanded: preserve or release the physical copy only according
#    to the authoritative bead transition and exact recovery-ref evidence;
#    never report product success
# 6. unknown / missing authority / dirty or later work / live processes /
#    identity mismatch / insufficient quiet / conflicting receipts: preserve
#    the attempt and resources for reconciliation
# 7. when lawful, invoke the one structured cleanup operation under the same
#    held lock; all refusals are preflighted before any effect
fm_cleanup_attempt_held "$attempt" "$disp" || {
  echo "terminal: cleanup did not complete for $attempt" >&2
  exit 1
}

# 8. still under the attempt lock, atomically publish the terminal audit
#    receipt and mark the live attempt retired
fm_attempt_retire_held "$attempt" "$gen" \
  "$(jq -n --arg disp "$disp" --arg authority "$close_authority" \
    '{audit:"terminal",disposition:$disp,authority:$authority}')" || exit 1

# release before step 9
fm_attempt_lock_release "$attempt"
trap - EXIT

# 9. after releasing the lock, obtain a fresh shared capacity projection and
#    permit refill only from that canonical observation
cap=$(fm_capacity_project)
echo "terminal: $attempt disposition=$disp retired"
echo "$cap" | jq -r '.aggregate | "post-terminal capacity: productive=\(.productive_count) reserved=\(.reserved_ownership_count) refill_safe=\(.refill_safe)"'
```

`fm_review_diff_recheck` wraps the existing `bin/fm-review-diff.sh` authority (refresh the authoritative base, compare the exact head against current attempts' actual diffs) and returns 0 only when no concrete overlap exists; the `FM_REVIEW_DIFF_CONFLICT=1` test hook forces a conflict. The Task 7.5 required order is preserved inside steps 2-8: observe forge/tracker/branch/endpoint/copy claim, persist the observation, obtain disposition authority, run teardown eligibility checks, persist the exact tracker-mutation request, wait while the attended steward executes it, observe and verify the authoritative tracker receipt, record the exact copy's no-live-process/clean/landed/nonzero-quiet evidence, clean or release that exact copy only when all four signals pass, retire the exact proven delivery ref, and remove runtime ownership only after all obligations are complete. `fm-terminal.sh` never mutates the tracker directly; a pending tracker receipt, quiet interval, or obligation blocks copy/ref/runtime release, and replay resumes at the persisted request/receipt boundary. A duplicate completion, merge event, startup recovery, heartbeat recovery, cleanup retry, or refill race converges on the same receipts and sees either pre-retirement ownership or a post-retirement deficit, never an intermediate free slot. `semantic_equiv` in the tests compares receipt names, states, and evidence with timestamps and attempt ids stripped.

- [x] **Step 4: Verify**

Run: `bash tests/fm-terminal.test.sh; bash tests/fm-cleanup.test.sh; bash tests/fm-teardown.test.sh; bash tests/fm-teardown-endpoint-safety.test.sh; bash tests/fm-disposition.test.sh`
Expected: all green.

- [x] **Step 5: Commit**

```bash
git add bin/fm-terminal.sh tests/fm-terminal.test.sh
git commit -m "feat(terminal): ordered terminal transaction with fresh authority and pre-land diff recheck"
```

---

## Task 12: Refill admission and the automatic-refill gate

F1/F7 admission semantics. Refill acts only on a complete projection; provisional planned-path admission reads the frozen provisional evidence; actual diffs stay authoritative pre-land.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (add `--refill`)
- Create: `tests/fm-refill-admission.test.sh`
- Extend: `tests/fm-capacity.test.sh` (retirement-before-projection and no-decrement-at-completion fixtures)

- [x] **Step 1: Write the failing tests**

Create `tests/fm-refill-admission.test.sh`:

```bash
test_refill_acts_only_on_complete_projection() {
  # alert_only projection: refill must refuse without querying candidates
  out=$(FM_CAPACITY_FIXTURE=alert "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "REFILL-UNSAFE" "refill acted on an unsafe projection"
  [ ! -e "$CANDIDATES_QUERIED" ] || fail "candidates queried on unsafe projection"
  pass "refill acts only when a complete projection reports below-target productive work"
}

test_provisional_planned_path_admission_serializes_on_concrete_conflict() {
  # candidate B's frozen planned path overlaps a current attempt's frozen
  # provisional path; admission must serialize B and dispatch A
  local aid out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-h holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-h"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"src/engine","declared_seams":[],"dependencies":[]}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-h"}' || fail "launch"
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\n' "$aid" > "$STATE/task-h.meta"
  cat > "$CANDIDATES" <<'JSON'
[{"id":"dos-h-a","planned_path":"docs/"},{"id":"dos-h-b","planned_path":"src/engine"}]
JSON
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_CANDIDATES_FILE="$CANDIDATES" \
    FM_REFILL_CURRENT_PATHS="src/engine" FM_REFILL_AUTO=1 \
    FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "admit dos-h-a" "A not admitted"
  assert_contains "$out" "serialize dos-h-b" "B not serialized on concrete conflict"
  pass "provisional planned-path admission serializes only on concrete conflict"
}

test_no_duplicate_dispatch_on_concurrent_refill() {
  # two concurrent --refill invocations; the home lock admits one wave
  (FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=1 FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill >/dev/null 2>&1) &
  (FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=1 FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill >/dev/null 2>&1) &
  wait
  [ "$(grep -c '^launch ' "$DISPATCH_LOG" 2>/dev/null || echo 0)" -le 1 ] \
    || fail "duplicate dispatch"
  pass "concurrent refill invocations serialize and never double-dispatch"
}

test_completion_or_merge_alone_never_decrements_capacity() {
  # a done status line and a merged PR observation without retirement leave
  # capacity unchanged
  local before after
  before=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  printf 'done: PR https://github.com/kunchenguid/firstmate/pull/1 checks green\n' \
    > "$STATE/task-i.status"
  after=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  [ "$(echo "$before" | jq '.aggregate.reserved_ownership_count')" = \
    "$(echo "$after" | jq '.aggregate.reserved_ownership_count')" ] \
    || fail "merge event decremented capacity"
  pass "a completion notification or merge event never decrements capacity directly"
}

test_actual_diffs_remain_authoritative_pre_land() {
  # admission may use provisional planned paths but never lands or merges;
  # the pre-land actual-diff decision belongs to fm-review-diff.sh (Task 11)
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=1 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_not_contains "$out" "landed" "refill admission claimed a landing"
  pass "provisional planned paths never override the actual-diff pre-land authority"
}
```

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-refill-admission.test.sh`
Expected: FAIL with `--refill` unrecognized.

- [x] **Step 3: Implement the refill action in `bin/fm-fleet-refill.sh`**

```bash
if [ "${1:-}" = "--refill" ]; then
  # shellcheck source=bin/fm-capacity-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"
  cap=$(fm_capacity_project)
  echo "$cap" | jq -e '.aggregate.refill_safe == true' >/dev/null || {
    echo "REFILL-UNSAFE: no attended or automatic refill on an unsafe projection" >&2
    exit 1
  }
  echo "$cap" | jq -e --argjson t "$FM_REFILL_TARGET_PRODUCTIVE" \
    --argjson c "$FM_REFILL_RESERVED_CEILING" \
    '.aggregate.productive_count < $t and .aggregate.reserved_ownership_count < $c' >/dev/null || {
    echo "fleet-ok: no refill needed"
    exit 0
  }
  fm_refill_admit_and_dispatch "$cap"
  exit $?
fi
```

`fm_refill_admit_and_dispatch`:

1. Queries the live beads graph for work that is open, ready, unclaimed, dependency-safe, and high enough priority (`br ready --json` then `br show --json "$id"` per candidate, array shape, to re-verify those facts while creating the claim request). For hermetic admission tests the candidate query is overridable with `FM_REFILL_CANDIDATES_FILE` (a JSON array of `{id, planned_path}`) and the current attempts' frozen provisional paths with `FM_REFILL_CURRENT_PATHS`.
2. Applies the accepted Decision OS admission contract against the FROZEN provisional admission evidence in each current attempt's delivery record (`planned_path`, `declared_seams`, `dependencies`, written once at Task 7 allocation) plus the known exclusive seams and the existing lane-contract checker; serializes only when that bounded admission evidence identifies a concrete conflict; no `.beadscope`, declaration registry, write-set enforcer, or claim inferred from planned paths is introduced. The actual diff remains the authoritative pre-land overlap check at landing time through the existing `bin/fm-review-diff.sh` path (Task 11's recheck).
3. Wins the home lock (`state/.lock.acquire` through `bin/fm-lock.sh`) plus the attempt allocation lock, then re-reads bead ownership after winning the lock.
4. For each admitted candidate, runs the Task 6 split handshake (claim request, `fm-br-receipt.sh`, then the `fm-spawn.sh` resume path).
5. Prints the exact dispatch commands for the attended path.

The automatic-refill gate: automatic action requires `config/refill-auto` in the home (gitignored) or `FM_REFILL_AUTO=1`; otherwise `--refill` is attended-only and the human path prints the verdict plus next-wave commands without launching. Automatic refill stays disabled through Task 13.

- [x] **Step 4: Verify**

Run: `bash tests/fm-refill-admission.test.sh; bash tests/fm-capacity.test.sh; bash tests/fm-fleet-refill.test.sh`
Expected: all green.

- [x] **Step 5: Commit**

```bash
git add bin/fm-fleet-refill.sh tests/fm-refill-admission.test.sh tests/fm-capacity.test.sh
git commit -m "feat(refill): retirement-before-projection admission with automatic-refill gate"
```

---

## Task 13: Consumer cutover, parity, latency proof, and the automatic-refill safety gate

F3 and F8 corrections plus the fleet-depth diagnosis. Both consumers switch to the shared object only after fixture and live parity plus the latency proof; automatic refill starts only after the full safety gate; the private cron sentinel (`data/fleet-depth-check.sh`) is removed and its cadence switches to the shared sentinel only after the cutover proof.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (human verdict cutover)
- Modify: `bin/fm-fleet-snapshot.sh` (capacity embed)
- Create: `bin/fm-refill-sentinel.sh`
- Create: `tests/fm-refill-sentinel.test.sh`
- Modify: `docs/verification/fleet-capacity.md` (final parity, latency, Decision OS contract, acceptance)
- Modify: `docs/documentation-audiences.json` (classify `docs/verification/fleet-capacity.md` as `maintainer-verification`)
- Extend: `tests/fm-capacity.test.sh` (composition fixtures), `tests/fm-fleet-snapshot-view.test.sh` (byte parity)

- [x] **Step 1: Write the failing composition and sentinel tests**

Append to `tests/fm-capacity.test.sh`:

```bash
test_composition_byte_parity_across_consumers_from_one_observation() {
  # one frozen observation drives --count-json, the snapshot embed, and the
  # sentinel; rows and aggregates compare byte-identically
  local frozen snap sentinel
  write_meta "c1" ship direct-PR
  frozen="$TMP_ROOT/frozen.json"
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null > "$frozen"
  snap=$(FM_STATE_OVERRIDE="$STATE" FM_CAPACITY_OBSERVATION_FILE="$frozen" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null)
  [ "$(jq -c '.rows' "$frozen")" = "$(echo "$snap" | jq -c '.capacity.rows')" ] \
    || fail "snapshot rows differ from the frozen object"
  [ "$(jq -c '.aggregate' "$frozen")" = "$(echo "$snap" | jq -c '.capacity.aggregate')" ] \
    || fail "snapshot aggregate differs"
  sentinel=$(FM_CAPACITY_OBSERVATION_FILE="$frozen" "$ROOT/bin/fm-refill-sentinel.sh" 2>&1 || true)
  assert_contains "$sentinel" "REFILL-ALERT" "sentinel did not consume the object" || true
  pass "composition fixtures prove byte-equivalent rows and aggregates across consumers"
}

test_generated_timestamp_never_breaks_parity() {
  # two separately generated objects differ in `generated` but rows/aggregates
  # compare identically
  local a b
  a=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  b=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  [ "$(echo "$a" | jq -c '.rows')" = "$(echo "$b" | jq -c '.rows')" ] || fail "rows differ across runs"
  [ "$(echo "$a" | jq -c '.aggregate')" = "$(echo "$b" | jq -c '.aggregate')" ] || fail "aggregate differs"
  pass "timing-dependent fields never break deterministic parity"
}
```

Create `tests/fm-refill-sentinel.test.sh`:

```bash
#!/usr/bin/env bash
# Public-interface tests for the private fleet sentinel: it consumes the
# shared capacity object and owns only cadence, candidate query, logging, and
# notification policy; it never counts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-refill-sentinel)
export FM_REFILL_SENTINEL_LOG="$TMP_ROOT/sentinel.log"

test_sentinel_is_silent_when_refill_is_safe() {
  local out rc
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "safe sentinel should exit 0"
  [ -z "$out" ] || fail "safe sentinel printed: $out"
  pass "sentinel stays silent when the projection is refill-safe"
}

test_sentinel_notifies_on_reconciliation_or_alert() {
  local out rc
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/alert.json" \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "alerting sentinel should exit 1"
  assert_contains "$out" "REFILL-ALERT" "alert line missing"
  pass "sentinel emits one alert line when reconciliation or alert-only applies"
}

test_sentinel_never_counts() {
  local out
  out=$(FM_CAPACITY_OBSERVATION_FILE="$TMP_ROOT/safe.json" FM_REFILL_SENTINEL_VERBOSE=1 \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_not_contains "$out" "productive_count" "sentinel recomputed capacity"
  pass "sentinel never classifies or recounts; it only consumes the object"
}

test_sentinel_is_silent_when_refill_is_safe
test_sentinel_notifies_on_reconciliation_or_alert
test_sentinel_never_counts
```

The `safe.json`/`alert.json` fixtures are written from the Task 2 projection fixtures.

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-capacity.test.sh; bash tests/fm-refill-sentinel.test.sh`
Expected: FAIL (no snapshot `capacity` key, sentinel script missing).

- [x] **Step 3: Cut the consumers over**

In `bin/fm-fleet-refill.sh`: replace the legacy verdict arithmetic with the shared-object derivation (the exact jq from Task 2's aggregate) and delete the legacy counting reads in this same commit (the deletion is now co-located with cutover, per F3's "Task 15 deletion strictly after that cutover proof" - the proof is this task's parity gate, so the legacy reads leave here).

In `bin/fm-fleet-snapshot.sh`: source `fm-capacity-lib.sh`, compute `CAPACITY_JSON=$(fm_capacity_project)` with the same `FM_*_OVERRIDE` env pass-through that `crew_state_json` uses, and add `capacity: ($capacity | fromjson)` to the emitted object. The snapshot never classifies or recounts.

Create `bin/fm-refill-sentinel.sh`:

```bash
#!/usr/bin/env bash
# Private fleet sentinel. Consumes the shared fm-fleet-capacity.v1 object and
# retains ONLY cadence, the authoritative candidate query, logging, and
# notification policy. It never classifies attempts and never recounts
# capacity. Invoked by the away-mode daemon heartbeat fleet review and by the
# attended refill path; it starts no scheduler or daemon of its own.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-capacity-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"

FM_REFILL_SENTINEL_CADENCE_SECS="${FM_REFILL_SENTINEL_CADENCE_SECS:-600}"
FM_REFILL_SENTINEL_LOG="${FM_REFILL_SENTINEL_LOG:-$FM_HOME/state/refill-sentinel.log}"
FM_REFILL_TARGET_PRODUCTIVE="${FM_REFILL_TARGET_PRODUCTIVE:-6}"
FM_REFILL_RESERVED_CEILING="${FM_REFILL_RESERVED_CEILING:-10}"

refill_candidates_json() {
  (cd "${FM_REFILL_PROJECT:-/home/holu/decision-os}" && br ready --json 2>/dev/null) \
    | jq -c '[.[] | select(.status == "open") | {id,priority,created_at}]' 2>/dev/null || echo '[]'
}

cap=$(fm_capacity_project)
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
alert=$(echo "$cap" | jq -r '
  if (.aggregate.refill_safe | not) then "REFILL-ALERT: projection unsafe (reconciliation_required=\(.aggregate.reconciliation_required) alert_only=\(.aggregate.alert_only))"
  elif (.aggregate.productive_count < '"$FM_REFILL_TARGET_PRODUCTIVE"') and
       (.aggregate.reserved_ownership_count < '"$FM_REFILL_RESERVED_CEILING"') then
    "REFILL-ALERT: productive \(.aggregate.productive_count) below target \('"$FM_REFILL_TARGET_PRODUCTIVE"')"
  else "" end')
candidates=$(refill_candidates_json)
printf '%s %s\n' "$now" "sentinel: ${alert:-refill-safe} candidates=$(echo "$candidates" | jq 'length')" \
  >> "$FM_REFILL_SENTINEL_LOG"
[ -n "$alert" ] || exit 0
printf '%s\n' "$alert"
exit 1
```

Cadence policy lives home-local in `config/refill-sentinel` (gitignored); notification policy is the single `REFILL-ALERT:` line surfaced through the existing watcher/daemon digest path.

- [x] **Step 4: Run live parity and record it**

```bash
frozen=/tmp/fm-capacity-frozen.json
bin/fm-fleet-refill.sh --count-json > "$frozen"
FM_CAPACITY_OBSERVATION_FILE="$frozen" bin/fm-fleet-snapshot.sh --json | jq '.capacity' > /tmp/fm-capacity-snap.json
diff <(jq -S '.rows,.aggregate' "$frozen") <(jq -S '.rows,.aggregate' /tmp/fm-capacity-snap.json) && echo "LIVE-PARITY-OK"
```

Expected: `LIVE-PARITY-OK`; the rows and aggregate (not the `generated` timestamp) compare byte-identically from one frozen observation. Record the exact command and output in `docs/verification/fleet-capacity.md` under `## Live parity`.

- [x] **Step 5: Prove the final latency budget**

```bash
/usr/bin/time -f 'count-json wall=%e s' bin/fm-fleet-refill.sh --count-json >/dev/null
```

Expected: wall below 2000 ms at the target fleet size. Record it under `## Latency (final)` with the integration-base SHA, date, fleet size, and exact output. If the budget does not hold, stop, do not enable automatic refill, and open a follow-up to tune the per-row timeout or enable bounded parallelism (Task 2 Step 5 verified).

- [x] **Step 6: Enable automatic refill only after the safety gate**

```bash
bin/fm-test-run.sh --all
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

Expected: every test green, lint clean, doc-audience clean. Only then create `config/refill-auto` in the home (gitignored) or set `FM_REFILL_AUTO=1`; the automatic path is the same `--refill` flow under the Task 12 gate. Record the acceptance evidence in `docs/verification/fleet-capacity.md` under `## Acceptance`.

- [x] **Step 7: Remove the private cron sentinel and switch cadence to the shared sentinel**

Only after the parity, latency, and safety-gate proofs above (the cutover proof) do the following:

1. Remove the crontab entry: `crontab -l | grep -v 'fleet-depth-check' | crontab -` and verify `crontab -l | grep -c fleet-depth-check` returns 0.
2. Delete the private sentinel script: `rm /home/holu/fmate/firstmate/data/fleet-depth-check.sh` and verify it is gone. Do not retain a wrapper and do not repoint the crontab.
3. Switch the cadence to the shared sentinel: the away-mode daemon heartbeat fleet review invokes `bin/fm-refill-sentinel.sh` at its cadence (config `config/refill-sentinel`, gitignored); the shared sentinel now owns cadence, candidate query, logging, and notification policy.
4. Keep historical `state/fleet-manifest.jsonl` and any next-wave staging state inert unless a separately safe owner (a later accepted design) takes them over: the file is not deleted, not read, and not written by any new mechanism.
5. Record the removal, the new cadence wiring, and the verification in `docs/verification/fleet-capacity.md` under `## Cron sentinel removal`.

- [x] **Step 8: Commit**

```bash
git add bin/fm-fleet-refill.sh bin/fm-fleet-snapshot.sh bin/fm-refill-sentinel.sh
git add tests/fm-capacity.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-refill-sentinel.test.sh
git add docs/verification/fleet-capacity.md docs/documentation-audiences.json
git commit -m "feat(refill): consumer cutover after fixture and live parity with automatic gate and cron sentinel removal"
```

---

## Task 14: Recover and expose current attempt state

Decision OS Task 7.6 leaf. Attempt state is exposed through the existing startup and heartbeat paths; obligations retry idempotently from the single attempt record.

**Files:**

- Modify: `bin/fm-session-start.sh`
- Modify: `bin/fm-watch.sh`
- Modify: `bin/fm-fleet-snapshot.sh` (attempt-state exposure only; the capacity embed is Task 13)
- Extend: `tests/fm-session-start.test.sh`, `tests/fm-watch-triage.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`

- [x] **Step 1: Write the failing tests**

Extend `tests/fm-session-start.test.sh` with a fixture home containing an attempt with a pending tracker effect, and assert the digest's fleet-state section names the attempt id, generation, missing observed effects, and reconciliation need. Extend `tests/fm-watch-triage.test.sh` with a heartbeat-path fixture that surfaces a `reconciliation_required` attempt through the existing fleet-scan (no new wake type). Extend `tests/fm-fleet-snapshot-view.test.sh` with per-task attempt-state exposure fields (receipt-set summary, obligations, reconciliation).

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-session-start.test.sh; bash tests/fm-watch-triage.test.sh; bash tests/fm-fleet-snapshot-view.test.sh`
Expected: FAIL on the new assertions.

- [x] **Step 3: Implement**

In `bin/fm-session-start.sh` fleet-state section: for each `state/<id>.meta` carrying `attempt=`, emit a bounded line with the attempt id, generation, missing observed effects, reconciliation need, and intended-exit-versus-crash hint derived from the attempt record's receipt set (never the status log). This is an additional digest line per task; the existing status tails stay.

In `bin/fm-watch.sh`: extend the existing heartbeat fleet-scan classification so an attempt whose projection row carries `reconciliation_required` surfaces one bounded wake through the normal heartbeat path (reusing the existing queue and classification machinery; no new wake type or daemon).

In `bin/fm-fleet-snapshot.sh`: each `tasks[]` row adds `attempt:` fields (id, generation, obligations, reconciliation) from the attempt record when present; no capacity embed in this task.

Pending obligations are exposed and retried idempotently through these existing session-start, heartbeat, and fleet-snapshot paths: a pending effect state inside the attempt record (`state:"pending"`) is retried by the same paths that own the wait (startup network stage for claim, heartbeat for tracker/cleanup), never by a new loop and never from a separate obligation file.

- [x] **Step 4: Verify**

Run: `bash tests/fm-session-start.test.sh; bash tests/fm-watch-triage.test.sh; bash tests/fm-fleet-snapshot-view.test.sh; bash tests/fm-attempt.test.sh; bash tests/fm-capacity.test.sh`
Expected: all green.

- [x] **Step 5: Commit**

```bash
git add bin/fm-session-start.sh bin/fm-watch.sh bin/fm-fleet-snapshot.sh
git add tests/fm-session-start.test.sh tests/fm-watch-triage.test.sh tests/fm-fleet-snapshot-view.test.sh
git commit -m "feat(fleet): expose and recover delivery attempts"
```

---

## Task 15: Deletion, rollback, and final acceptance

F8 corrections: deletion happens only after the Task 13 cutover proof; forbidden-symbol checks are scoped to runtime code with the deliberate negative fixtures excluded; home-aware `rg -uu` plus crontab verification proves no active consumer of the legacy manifest, output paths, or private cron sentinel remains; the file map is verified exhaustive; the 16-task count and every design requirement are re-checked.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (remove remaining legacy references)
- Modify: `docs/verification/fleet-capacity.md` (final acceptance evidence)
- Extend: `tests/fm-fleet-refill.test.sh` (no-fallback, rollback), `tests/fm-refill-admission.test.sh`, `tests/fm-refill-sentinel.test.sh`

- [x] **Step 1: Write the failing tests**

Append to `tests/fm-fleet-refill.test.sh`:

```bash
test_legacy_manifest_and_output_mtimes_never_fallback() {
  # a state/fleet-manifest.jsonl with fresh mtimes and a fake output file with
  # a fresh mtime must be ignored completely by the cut-over projection
  local id out
  id=legacy-m
  printf '%s\n' "$id" > "$STATE/fleet-manifest.jsonl"
  mkdir -p "$TMP_ROOT/output-tasks"
  : > "$TMP_ROOT/output-tasks/$id.output"
  printf 'kind=ship\nmode=direct-PR\n' > "$STATE/$id.meta"
  out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  assert_not_contains "$out" "manifest" "legacy manifest leaked into capacity"
  pass "legacy manifests and output mtimes never become fallback arithmetic"
}

test_rollback_is_alert_only_and_preserves_everything() {
  # with config/refill-auto absent and FM_REFILL_AUTO=0, --refill must not
  # dispatch; attempts, beads, branches, refs, copies, and receipts are
  # untouched (byte-compare the state dir)
  local before after out
  before=$(find "$STATE" -type f -exec sha256sum {} + | sort)
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "fleet-ok" "rollback mode did not stay alert-only"
  assert_not_contains "$out" "launch " "rollback mode dispatched"
  after=$(find "$STATE" -type f -exec sha256sum {} + | sort)
  [ "$before" = "$after" ] || fail "rollback mutated the state dir"
  pass "rollback disables automatic dispatch and preserves every attempt record"
}

test_rollback_never_restores_legacy_arithmetic() {
  # missing evidence yields ambiguous/incomplete rows, never zero capacity
  local out
  printf 'kind=ship\nmode=direct-PR\n' > "$STATE/legacy-r.meta"
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null \
    || fail "rollback invented capacity"
  pass "rollback never converts missing evidence into zero capacity"
}
```

- [x] **Step 2: Run to verify failure**

Run: `bash tests/fm-fleet-refill.test.sh`
Expected: FAIL while the legacy constants still exist in the runtime script.

- [x] **Step 3: Delete the obsolete machinery and implement the rollback flip**

From `bin/fm-fleet-refill.sh` (cut over in Task 13): remove the `TASKS_DIR`/`MANIFEST` variables, the mtime loop, `ACTIVE_WINDOW_MIN`, `QUEUE_WINDOW_MIN`, `MIN_BATTERY`, `MIN_OPEN`, the `br list --status open --json` open-count block, the old sentinel freshness-window references in the header, and the legacy `active=`/`battery=` verdict line. Keep the serialization-debt probe (a safety gate, not capacity arithmetic). The `state/fleet-manifest.jsonl` file itself is left untouched in the home and simply stops being read; no unknown or unlanded work is deleted.

Rollback flip in `bin/fm-fleet-refill.sh` and `bin/fm-refill-sentinel.sh`: when `config/refill-auto` is absent and `FM_REFILL_AUTO` is not `1`, the scripts print the verdict and alert lines but never dispatch or launch (`--refill` exits 0 with `fleet-ok: alert-only` after the same summary). All attempts, beads, branches, refs, copies, and receipts are preserved; forward recovery resumes from the persisted effect receipts because re-enabling the gate re-runs the same idempotent paths (claim replay, obligation retry, terminal reconciliation). The projection continues to report ambiguity and reconciliation exactly as before; missing evidence never becomes zero capacity.

- [x] **Step 4: Run the full acceptance gate**

```bash
bin/fm-test-run.sh --all
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

Expected: every test green, lint clean, doc-audience clean (this plan as `maintainer-architecture` and `docs/verification/fleet-capacity.md` as `maintainer-verification`).

- [x] **Step 5: Verify no duplicate machinery and an exhaustive file map**

Forbidden-symbol check scoped to runtime code; the deliberate negative fixture in `tests/fm-fleet-refill.test.sh` is excluded by scope, not by grep filtering:

```bash
grep -rn "ACTIVE_WINDOW_MIN\|QUEUE_WINDOW_MIN\|MIN_BATTERY\|MIN_OPEN\|fleet-manifest" bin/ && echo "LEGACY-ARITHMETIC-FOUND" || echo "NO-LEGACY-ARITHMETIC"
grep -c "productive_count\|reserved_ownership_count" bin/fm-fleet-refill.sh bin/fm-fleet-snapshot.sh bin/fm-refill-sentinel.sh | grep -v ":0" | grep -v fm-capacity-lib.sh || echo "CONSUMERS-ONLY"
```

Expected: `NO-LEGACY-ARITHMETIC` and either `CONSUMERS-ONLY` or no output (the counters appear only in the one classifier and its consumers). Then verify the file map is exhaustive: every path listed in this plan's file map exists in the branch diff (`git diff --name-only main...HEAD`), and every diff path is in the map.

Then verify no active consumer of the legacy manifest, output paths, or private cron sentinel remains. The scans are home-aware (they cover the real home and the worktree) and include hidden and ignored paths:

```bash
# no active consumer reads the legacy manifest, the obsolete pi-subagent output
# paths, or invokes the deleted private cron sentinel (home-aware rg -uu)
rg -uu -l "fleet-manifest" /home/holu/fmate/firstmate/ 2>/dev/null | grep -v '\.git/' | grep -v 'docs/superpowers/plans/' \
  && echo "MANIFEST-CONSUMER-FOUND" || echo "NO-MANIFEST-CONSUMER"
rg -uu -l "pi-subagents-1000" /home/holu/fmate/firstmate/ 2>/dev/null | grep -v '\.git/' | grep -v 'docs/superpowers/plans/' \
  && echo "OUTPUT-PATH-REFERENCE-FOUND" || echo "NO-OUTPUT-PATH-REFERENCE"
rg -uu -l "fleet-depth-check" /home/holu/fmate/firstmate/ /home/holu/.treehouse/firstmate-b8697d/1/firstmate/ 2>/dev/null \
  && echo "SENTINEL-REFERENCE-FOUND" || echo "NO-SENTINEL-REFERENCE"
# crontab verification: no entry names the old sentinel or any firstmate fleet path
crontab -l 2>/dev/null | grep -c "fleet-depth-check" && echo "CRON-SENTINEL-STILL-ACTIVE" || echo "CRON-SENTINEL-GONE"
crontab -l 2>/dev/null | grep "firstmate/data/" && echo "OTHER-CRON-FIRSTMATE-ENTRIES" || echo "NO-OTHER-CRON"
```

Expected: `NO-MANIFEST-CONSUMER`, `NO-OUTPUT-PATH-REFERENCE`, `NO-SENTINEL-REFERENCE`, `CRON-SENTINEL-GONE`, and either `NO-OTHER-CRON` or the named unrelated entries (for example `openmodel-price-check.sh`) that the diagnosis separately confirms are safe. The `docs/superpowers/plans/` exclusion keeps this plan's own prose (which documents the legacy paths) from counting as a consumer; the negative test fixture in `tests/fm-fleet-refill.test.sh` is outside the scanned home paths and is already covered by the `bin/`-scoped forbidden-symbol check.

- [x] **Step 6: Final self-review against every accepted design requirement**

Walk `docs/architecture.md` section "Durable implementation capacity and attempt lifecycle design" and the review's bounded correction list, and confirm each maps to a task:

- One attended dispatch/refill invocation: Tasks 6, 12.
- Automatic terminal reconciliation and refill: Tasks 11, 12, 13.
- No new scheduler, daemon, dashboard, wrapper, parser, phase machine, duplicate counter: Tasks 2, 8, 9, 15 (negative assertions).
- One shared capacity classifier: Task 2; consumers cut over in Task 13.
- One structured cleanup operation used by terminal orchestration and existing cleanup: Tasks 8, 9.
- Write-once, receipt-derived attempt model with no mutable phase and no parallel obligation files (F1): Task 1.
- One outer non-reentrant terminal transaction with lock-held primitives (F2): Tasks 1, 9, 11.
- Real history reconciliation before runtime work and shadow-only consumers until post-parity cutover (F3): Tasks 0, 3, 13.
- Structured crew-state plus an enforceable total deadline and latency (F4): Task 2.
- Installed br/storage contracts and a pathspec transaction (F5): Tasks 5, 6.
- Centralized live disposition with fresh per-effect authority (F6): Tasks 4, 11.
- Attempt-bound copy/landing/planned-path semantics with a pre-land actual-diff recheck (F7): Tasks 1, 7, 10, 11, 12.
- Deterministic parity commands, brief wiring, exhaustive file map, split Tasks 5/8 (F8): Tasks 3, 5, 6, 8, 9, 13, 15.
- Full branch and isolated-copy lifecycle (admission, creation, delivery, merge or authorized local landing, Closure-Receipt and close, branch disposition, preservation refs, cleanup refusal, provider return, runtime retirement, automatic refill only after atomic retirement): Tasks 5, 6, 7, 9, 10, 11, 12.
- Obsolete manifests, frozen output paths, duplicated counters, legacy compatibility reads, old sentinel arithmetic deleted only after measured parity; never discard unknown or unlanded work: Tasks 4, 9, 11, 13, 14, 15.
- Active private cron sentinel (`data/fleet-depth-check.sh` plus crontab entry) quarantined to alert-only in Task 3, removed with its cadence switched to the shared sentinel only after the Task 13 cutover proof, and verified gone with home-aware `rg -uu` plus crontab inspection in Task 15: Tasks 3, 13, 15.
- Representative latency measurement, fixture parity, provider/runtime coverage, crash/replay tests around every irreversible effect, concurrency tests, migration, rollback to alert-only, exact verification commands: Tasks 2, 3, 5, 7, 9, 10, 11, 12, 13, 14, 15.
- Sixteen tasks (Task 0 through Task 15), each on a green baseline with a small commit: Task 15 verifies the count.

- [x] **Step 7: Fix any material finding and commit**

If this self-review or the implementation finds a material design correction, fix the design owner `docs/architecture.md` in one follow-up commit and re-run Step 4. Otherwise record the acceptance evidence in `docs/verification/fleet-capacity.md` under `## Acceptance` (date, integration-base SHA, commands, output) and commit:

```bash
git add bin/fm-fleet-refill.sh bin/fm-refill-sentinel.sh
git add tests/fm-fleet-refill.test.sh tests/fm-refill-admission.test.sh tests/fm-refill-sentinel.test.sh
git add docs/verification/fleet-capacity.md
git commit -m "feat(refill): delete obsolete arithmetic after parity and add alert-only rollback"
```

---

## Execution handoff

The single canonical review concluded REVISE with eight material corrections and no captain decision; this revision addresses F1-F8 plus the fleet-depth diagnosis (private cron sentinel quarantine, removal, and verification) and normalizes the plan to exactly 16 tasks (Task 0 through Task 15). Per instruction, no further fresh-eyes run is started. Implementation proceeds through the normal delivery path after this revised plan's self-review and doc checks pass: Task 0 first (the reviewed integration branch), then the write-once attempt model, structured projection, shadow run, disposition, steward transaction, spawn handshake, attempt-bound ownership, cleanup extraction, structured cleanup, landing observations, terminal transaction, refill admission, cutover with cron-sentinel removal, recovery/exposure, and deletion/rollback. Each task lands on a green baseline with a small commit; implementation uses superpowers:subagent-driven-development or superpowers:executing-plans.

## Plan document classification

This plan is a tracked markdown file in the firstmate repository. `bin/fm-doc-audience-check.sh` requires every tracked `.md` to be classified in `docs/documentation-audiences.json`. The plan is classified as `maintainer-architecture` (shipped with the plan commit). `docs/verification/fleet-capacity.md` is classified as `maintainer-verification` and ships with Task 13. No other documentation surface is added by this plan.
