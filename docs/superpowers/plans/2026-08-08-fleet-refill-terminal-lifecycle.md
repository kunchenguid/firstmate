# Durable Fleet Refill and Attempt Terminal Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the accepted durable fleet refill and attempt-to-terminal lifecycle design in `docs/architecture.md` (section "Durable implementation capacity and attempt lifecycle design") without a scheduler, daemon, dashboard, wrapper layer, parser, phase machine, or duplicate capacity counter, and without changing the one-attended-invocation normal path.

**Architecture:** One immutable attempt envelope plus generation-bound effect receipts per physical delivery effort; one shared capacity classifier (`fm-fleet-capacity.v1`) that reads `bin/fm-crew-state.sh` and attempt records; one structured cleanup operation shared by terminal orchestration and the existing teardown wrapper; one ordered terminal orchestrator; Decision OS beads remain the authority for identity, priority, readiness, dependencies, claims, ownership, and closure. Migration reconciles the local/upstream repository split first, then runs the projection read-only with shadow counting, then introduces envelopes, claims, cleanup, and terminal orchestration, then switches consumers and deletes obsolete machinery only after measured parity.

**Tech Stack:** bash 5, jq, git worktrees, treehouse pool (`treehouse get --lease --lease-holder`), Orca/`orca worktree`, tmux/herdr/zellij/orca/cmux backends, Decision OS `br` CLI (`br ready --json`, `br show --json`, `br comments add`, `br close`, `br update`) and `scripts/br_worktree_storage.py` (`verify-session`, `preflight`, `claim --agent`), `bin/fm-test-run.sh`, `bin/fm-lint.sh`, `bin/fm-doc-audience-check.sh`.

---

## Authority and context

The accepted target is `docs/architecture.md` section "Durable implementation capacity and attempt lifecycle design", which is the design owner and is not modified by this implementation unless the review pass finds a material correction (Task 15 then adds one follow-up docs commit).

Decision OS plan `docs/superpowers/plans/2026-08-05-two-writer-delivery-capacity.md` in the decision-os repository (`/home/holu/decision-os`) Tasks 7.1 through 7.6 remain the project-specific lifecycle authority. This plan composes that authority with the firstmate design; where the two overlap, the firstmate design's ordered composition and migration stages win, and the decision-os Tasks 7.1-7.6 leaf shapes (files, orders, refusal conditions) are implemented verbatim.

### Repository ownership facts (Task 0 input)

Verified on 2026-08-08 from this plan branch:

- `git merge-base main origin/main` is `2cf0283b811e81a821cddf5b7f74e1f7de8e2881`.
- Local `main` owns 23 commits absent from `origin/main`, including `acaaf2e feat(fleet): mechanical refill checker - exit 1 = DISPATCH-NEEDED`, `94d4caa feat: encode proactive fleet scaling doctrine`, `651be21`/`71b1e86` serialization-debt probes, `f4ae695` bead closure delivery discipline, `4c3ed17` and `38b4eb6` the two design-doc commits, `015c7dd`, `378b564`, `3472d87`, and `184e07f`.
- `origin/main` owns 17 commits absent from local `main`, including `833a9a2 feat(bin): lint only the changed shard locally`, `be32879`, `167ff42`, `60eb534`, and `06b33aa`.
- Twelve PRs exist on both lines as different SHAs with identical content (for example `193a2fc`/`6c206ed` and `2c924fe`/`345de4e`), so the true content divergence is smaller than the commit counts suggest.
- `bin/fm-fleet-refill.sh` exists only on local `main` (`git cat-file -e origin/main:bin/fm-fleet-refill.sh` fails); it is the fleet-refill behavior the reviewed upstream line lacks.
- `docs/superpowers/` is not tracked in this repository; the writing-plans convention plus this task's instruction place this plan at `docs/superpowers/plans/2026-08-08-fleet-refill-terminal-lifecycle.md`.

Neither history is disposable. Task 0 selects the canonical integration base and reconciles the script before any runtime change, per the design's migration first step.

### Invariant: no second authority

Decision OS beads stay authoritative for identity, priority, readiness, dependencies, claims, ownership, and closure. The attempt record is coordination state, never a second task tracker. Every attempt binds immutably to one bead id and re-verifies the live bead before claim, allocation, refill selection, terminal reconciliation, and closure. Any missing, stale, multiply claimed, or contradictory authoritative fact preserves ownership and requires reconciliation rather than dispatch or closure. Firstmate caches may carry source identity and revision evidence but never override those authorities.

### Invariant: no legacy arithmetic fallback

Legacy manifests, output paths, output modification times, raw metadata counts, worker text, and private shadow fields never become fallback arithmetic. Deletion of obsolete machinery happens only after measured parity (Task 13). Rollback never restores legacy liveness arithmetic and never converts missing evidence into zero capacity (Task 14).

---

## File structure map

New files:

- Create: `bin/fm-attempt-lib.sh` - immutable attempt envelope, generation-bound receipts, obligations, atomic retirement. Single owner of schema `fm-attempt.v1`.
- Create: `bin/fm-capacity-lib.sh` - the one shared capacity classifier, emitting schema `fm-fleet-capacity.v1`. Sourced by refill, snapshot, and sentinel.
- Create: `bin/fm-br-receipt.sh` - the attended Decision OS main-steward adapter that executes the Task 7.4 order and persists tracker receipts.
- Create: `bin/fm-cleanup-lib.sh` - the one structured attempt-bound cleanup operation factored from `bin/fm-teardown.sh`.
- Create: `bin/fm-terminal.sh` - the sole attempt-to-terminal orchestrator implementing the design's ordered composition.
- Create: `bin/fm-refill-sentinel.sh` - the private fleet sentinel; consumes the shared object and retains only cadence, candidate query, logging, and notification policy.
- Create: `docs/verification/fleet-capacity.md` - maintainer-verification record for shadow parity, latency, and safety-test evidence.

Modified files:

- Modify: `bin/fm-fleet-refill.sh` - legacy manifest/mtime arithmetic becomes a thin consumer of the shared object (human output plus `--count-json`); keeps the serialization-debt safety gate.
- Modify: `bin/fm-fleet-snapshot.sh` - embeds the exact capacity object (or calls the same function) and adds attempt-phase exposure; never classifies attempts itself.
- Modify: `bin/fm-spawn.sh` - claim-before-allocation split handshake, attempt allocation at intake, provider receipt, launch receipt, audit-only ledger row.
- Modify: `bin/fm-teardown.sh` - becomes the ordinary compatibility wrapper over `fm_cleanup_attempt`.
- Modify: `bin/fm-home-seed.sh` - provider-wide lease ownership for secondmate homes (Task 7.2).
- Modify: `bin/fm-backend.sh` - provider-wide ownership helpers and endpoint-stop receipt surface (Task 7.2).
- Modify: `bin/fm-pr-lib.sh`, `bin/fm-pr-check.sh`, `bin/fm-pr-merge.sh`, `bin/fm-pr-poll.sh`, `bin/fm-merge-local.sh` - persist exact landing observations (Task 7.3).
- Modify: `bin/fm-session-start.sh`, `bin/fm-watch.sh` - expose attempt phase/generation, reconciliation need, and obligations on the existing startup and heartbeat paths (Task 7.6).
- Modify: `bin/fm-brief.sh` - emit the attempt id and claim requirement into ship briefs.
- Modify: `docs/documentation-audiences.json` - classify this plan (already shipped with the plan commit) and the new verification record as `maintainer-verification`.

New test files:

- Create: `tests/fm-attempt.test.sh`
- Create: `tests/fm-capacity.test.sh`
- Create: `tests/fm-br-receipt.test.sh`
- Create: `tests/fm-terminal.test.sh`
- Create: `tests/fm-cleanup.test.sh`
- Create: `tests/fm-refill-sentinel.test.sh`

Extended test files:

- `tests/fm-fleet-refill.test.sh`
- `tests/fm-fleet-snapshot-view.test.sh`
- `tests/fm-spawn-worktree-settle.test.sh`
- `tests/fm-secondmate-safety.test.sh`
- `tests/fm-backend-orca.test.sh`
- `tests/fm-teardown.test.sh`
- `tests/fm-teardown-endpoint-safety.test.sh`
- `tests/fm-pr-check-security.test.sh`
- `tests/fm-pr-merge.test.sh`
- `tests/fm-backlog-handoff.test.sh`
- `tests/fm-session-start.test.sh`
- `tests/fm-watch-triage.test.sh`

---

## Task 0: Reconcile repository ownership

**Files:**

- No tracked file changes in this task. Evidence and decision are recorded in the commit message and the implementation PR description.

**Context:** local `main` and `origin/main` diverged at `2cf0283b`. Local `main` owns `bin/fm-fleet-refill.sh` and the accepted design; upstream owns five other commits. Both histories are preserved. The design's migration step is: select and review the canonical integration base, then reconcile that script before runtime implementation begins.

- [ ] **Step 1: Verify both histories and the script ownership**

Run:

```bash
git merge-base main origin/main
git log --oneline --no-merges origin/main..main | cat
git log --oneline --no-merges main..origin/main | cat
git cat-file -e origin/main:bin/fm-fleet-refill.sh && echo "origin has it" || echo "origin does not have it"
```

Expected: merge-base `2cf0283b811e81a821cddf5b7f74e1f7de8e2881`; local-only list contains `acaaf2e`, `94d4caa`, `4c3ed17`, `38b4eb6`; origin-only list contains `833a9a2`, `be32879`, `167ff42`, `60eb534`, `06b33aa`; `origin does not have it`.

- [ ] **Step 2: Select and record the canonical integration base**

The canonical integration base is local `main` at `38b4eb6` because it owns the accepted design and the fleet-refill script that this plan implements, and the plan branch is already based on it (`git merge-base --is-ancestor 38b4eb6 HEAD` is true). The upstream-only commits (`833a9a2`, `be32879`, `167ff42`, `60eb534`, `06b33aa`) land through the normal firstmate PR path after this plan lands, preserving both histories. Do not rebase local `main` onto `origin/main` and do not drop either side.

- [ ] **Step 3: Verify the plan branch is a clean fast-forward from the base**

Run:

```bash
git merge-base --is-ancestor main HEAD && echo "base contained" || echo "NOT contained"
git status --short
```

Expected: `base contained` and an empty status. If `main` advances during implementation, rebase the implementation branch onto it so the final merge stays a fast-forward.

- [ ] **Step 4: Commit the decision**

```bash
git commit --allow-empty -m "docs(plans): record fleet-refill repository ownership reconciliation base

Local main owns bin/fm-fleet-refill.sh and the accepted fleet lifecycle design
absent from origin/main (merge-base 2cf0283b). Both histories are preserved;
local main at 38b4eb6 is the canonical integration base. Upstream-only commits
land later through the normal PR path."
```

---

## Task 1: Durable delivery-attempt identity

Decision OS Task 7.1 leaf, plus the design's generation-bound effect receipts and derived obligations.

**Files:**

- Create: `bin/fm-attempt-lib.sh`
- Create: `tests/fm-attempt.test.sh`
- Modify: `bin/fm-spawn.sh` (intake-only hook added in Task 5; this task only wires the library, not the handshake)

- [ ] **Step 1: Write the failing test**

Create `tests/fm-attempt.test.sh`:

```bash
#!/usr/bin/env bash
# Public-interface tests for durable delivery-attempt identity, generation-bound
# effect receipts, derived obligations, and atomic retirement.
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
  aid=$(fm_attempt_alloc pi decision-os-home holu) || fail "alloc failed"
  assert_contains "$aid" "decision-os-home-a1" "attempt id shape"
  gen=$(fm_attempt_generation "$aid") || fail "load failed"
  [ "$gen" = 1 ] || fail "generation was $gen"
  fm_attempt_load "$aid" | jq -e '.envelope.task_source == "pi" and .envelope.home_id == "holu"' >/dev/null \
    || fail "envelope did not round-trip"
  [ "$(fm_attempt_phase "$aid")" = claim_pending ] || fail "initial phase"
  pass "attempt alloc round-trips the immutable envelope"
}

test_concurrent_allocation_one_winner() {
  local a b
  a=$(fm_attempt_alloc pi decision-os-home holu) || fail "first alloc"
  b=$(fm_attempt_alloc pi decision-os-home holu) || fail "second alloc"
  [ "$a" != "$b" ] || fail "duplicate attempt id: $a"
  assert_contains "$b" "decision-os-home-a2" "monotonic generation"
  pass "concurrent allocation yields distinct ids with one winner per generation"
}

test_stale_generation_cannot_mutate() {
  local aid
  aid=$(fm_attempt_alloc pi decision-os-home holu)
  fm_attempt_write_receipt "$aid" 1 claim '{"bead":"dos-x","status":"claimed"}' \
    || fail "fresh receipt refused"
  fm_attempt_write_receipt "$aid" 1 claim '{"bead":"dos-x","status":"claimed-again"}' \
    && fail "stale same-generation overwrite accepted"
  pass "stale generation cannot overwrite the current attempt"
}

test_claim_pending_blocks_retirement() {
  local aid
  aid=$(fm_attempt_alloc pi decision-os-home holu)
  fm_attempt_retire "$aid" 1 '{"audit":"terminal"}' \
    && fail "retirement without a claim receipt was accepted"
  [ "$(fm_attempt_phase "$aid")" = claim_pending ] || fail "phase changed illegally"
  pass "a pending obligation prevents retirement until the matching receipt is observed"
}

test_obligations_derive_from_missing_receipts() {
  local aid out
  aid=$(fm_attempt_alloc pi decision-os-home holu)
  out=$(fm_attempt_missing_receipts "$aid")
  assert_contains "$out" "claim" "claim obligation missing"
  fm_attempt_write_receipt "$aid" 1 claim '{"bead":"dos-x","status":"claimed"}' \
    || fail "claim receipt refused"
  out=$(fm_attempt_missing_receipts "$aid")
  assert_not_contains "$out" "claim" "claim obligation not cleared"
  pass "named obligations derive from missing receipts"
}

test_atomic_retirement() {
  local aid
  aid=$(fm_attempt_alloc pi decision-os-home holu)
  fm_attempt_write_receipt "$aid" 1 claim '{"bead":"dos-x","status":"claimed"}' \
    || fail "claim receipt refused"
  fm_attempt_write_receipt "$aid" 1 launch '{"endpoint":"w1"}' \
    || fail "launch receipt refused"
  fm_attempt_write_receipt "$aid" 1 landing '{"disposition":"landed"}' \
    || fail "landing receipt refused"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal","disposition":"landed"}' \
    || fail "retirement refused"
  [ "$(fm_attempt_phase "$aid")" = retired ] || fail "not retired"
  pass "retirement is atomic and records the terminal audit receipt"
}

test_alloc_roundtrips_envelope
test_concurrent_allocation_one_winner
test_stale_generation_cannot_mutate
test_claim_pending_blocks_retirement
test_obligations_derive_from_missing_receipts
test_atomic_retirement
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/fm-attempt.test.sh`
Expected: FAIL with `fm_attempt_alloc: command not found` (or similar) on the first test.

- [ ] **Step 3: Write the minimal implementation**

Create `bin/fm-attempt-lib.sh`:

```bash
#!/usr/bin/env bash
# Durable delivery-attempt identity and generation-bound effect receipts.
#
# Single owner of schema fm-attempt.v1: the immutable envelope
# {task_source, task_key, home_id, attempt_id, generation}, the frozen
# provider-copy identity and delivery contract added at allocation, the phase,
# a small map of generation-bound effect receipts, and named obligations
# derived from missing receipts.
#
# This record is coordination state only. Decision OS beads remain task truth;
# this file never mirrors live bead state, semantic worker state, endpoint
# liveness, Git refs, cleanliness, ancestry, or forge status.
#
# Records live under $FM_STATE_OVERRIDE/attempts/<attempt_id>.json when
# FM_STATE_OVERRIDE is set (tests), else $FM_HOME/state/attempts/. All
# mutations happen under the attempt lock using the shared primitives from
# bin/fm-wake-lib.sh (fm_lock_try_acquire / fm_lock_release) and publish
# atomically with write-temp-then-mv.

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
    '{schema:$schema,envelope:{task_source:$task_source,task_key:$task_key,home_id:$home_id,attempt_id:$attempt_id,generation:$generation},phase:"claim_pending",receipts:{},created_at:(now|todateiso8601)}' \
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

fm_attempt_phase() {  # <attempt_id>
  fm_attempt_load "$1" | jq -r '.phase // "missing"'
}

fm_attempt_write_receipt() {  # <attempt_id> <generation> <receipt-name> <evidence-json>
  local attempt=$1 gen=$2 name=$3 evidence=$4
  local dir tmp live_gen
  dir="$(attempts_dir)"
  fm_lock_try_acquire "$(attempt_lock "$attempt")" || {
    echo "attempt-lock busy: $attempt" >&2
    return 1
  }
  live_gen=$(fm_attempt_generation "$attempt") || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation: $attempt expects gen $gen, record is gen $live_gen" >&2
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  tmp="$dir/.$attempt.tmp.$$"
  jq --arg name "$name" --argjson evidence "$evidence" \
    '.receipts[$name] = {generation:.envelope.generation,observed_at:(now|todateiso8601),evidence:$evidence}' \
    "$(attempt_path "$attempt")" > "$tmp" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  mv -f "$tmp" "$(attempt_path "$attempt")" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  fm_lock_release "$(attempt_lock "$attempt")"
}

fm_attempt_missing_receipts() {  # <attempt_id> -> space-separated receipt names
  local attempt=$1 phase required
  phase=$(fm_attempt_phase "$attempt") || return 1
  case "$phase" in
    retired) return 0 ;;
    claim_pending) required="claim" ;;
    claim_observed|allocating) required="claim provider" ;;
    launching) required="claim provider launch" ;;
    *) required="claim provider launch landing" ;;
  esac
  fm_attempt_load "$attempt" | jq -r \
    --argjson required "$(printf '%s' "$required" | jq -R 'split(" ")')" \
    '[ $required[] | select((.receipts[.] // null) == null) ] | join(" ")'
}

fm_attempt_freeze_allocation() {  # <attempt_id> <generation> <provider-json> <delivery-json>
  local attempt=$1 gen=$2 provider=$3 delivery=$4
  local dir tmp live_gen
  dir="$(attempts_dir)"
  fm_lock_try_acquire "$(attempt_lock "$attempt")" || return 1
  live_gen=$(fm_attempt_generation "$attempt") || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  [ "$live_gen" = "$gen" ] || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  tmp="$dir/.$attempt.tmp.$$"
  jq --argjson provider "$provider" --argjson delivery "$delivery" \
    '.phase="claim_observed" | .provider=$provider | .delivery=$delivery' \
    "$(attempt_path "$attempt")" > "$tmp" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  mv -f "$tmp" "$(attempt_path "$attempt")" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  fm_lock_release "$(attempt_lock "$attempt")"
}

fm_attempt_retire() {  # <attempt_id> <generation> <terminal-audit-evidence-json>
  local attempt=$1 gen=$2 evidence=$3
  local dir tmp live_gen missing
  dir="$(attempts_dir)"
  fm_lock_try_acquire "$(attempt_lock "$attempt")" || return 1
  live_gen=$(fm_attempt_generation "$attempt") || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  [ "$live_gen" = "$gen" ] || {
    echo "stale generation at retirement: $attempt" >&2
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  missing=$(fm_attempt_missing_receipts "$attempt")
  [ -z "$missing" ] || {
    echo "retirement blocked: missing receipts: $missing" >&2
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  tmp="$dir/.$attempt.tmp.$$"
  jq --argjson evidence "$evidence" \
    '.phase="retired" | .receipts.retirement = {generation:.envelope.generation,observed_at:(now|todateiso8601),evidence:$evidence}' \
    "$(attempt_path "$attempt")" > "$tmp" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  mv -f "$tmp" "$(attempt_path "$attempt")" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  fm_lock_release "$(attempt_lock "$attempt")"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/fm-attempt.test.sh`
Expected: six `ok -` lines, no failures.

- [ ] **Step 5: Verify shellcheck and the existing spawn tests still pass**

Run: `bin/fm-lint.sh --list-files | grep fm-attempt-lib.sh` (the file must be in the canonical set after Task 5 adds it to the lint shard list; until then run `shellcheck bin/fm-attempt-lib.sh`) and `bash tests/fm-spawn-worktree-settle.test.sh`.
Expected: shellcheck clean and the spawn tests green.

- [ ] **Step 6: Commit**

```bash
git add bin/fm-attempt-lib.sh tests/fm-attempt.test.sh
git commit -m "feat(attempts): add durable delivery-attempt identity"
```

---

## Task 2: One shared read-only capacity projection

Decision OS Task 7.6 exposes attempt state; this task builds the projection the design requires, read-only, before any consumer switches to it.

**Files:**

- Create: `bin/fm-capacity-lib.sh`
- Create: `tests/fm-capacity.test.sh`
- Modify: `bin/fm-fleet-refill.sh` (`--count-json` only in Task 3; this task only defines the function)

- [ ] **Step 1: Write the failing test**

Create `tests/fm-capacity.test.sh`:

```bash
#!/usr/bin/env bash
# Public-interface tests for the one shared capacity projection
# (fm-fleet-capacity.v1). Capacity fixtures: implementation, validation,
# merge wait, terminal states, ambiguity, timeout, stale and disappearing
# records, scouts, second mates, schema failure, and retirement-before-
# projection.
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

fake_crew_state() {  # writes a fake fm-crew-state.sh that echoes the given line
  cat > "$TMP_ROOT/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' '$1'
SH
  chmod +x "$TMP_ROOT/fm-crew-state.sh"
}

test_implementation_is_productive_and_reserved() {
  local aid out
  aid=$(fm_attempt_alloc pi bead-x holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-x"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_write_receipt "$aid" 1 launch '{"endpoint":"w1"}' || fail "launch"
  write_meta "task-x" ship direct-PR "attempt=$aid"
  fake_crew_state "state: working·source: run-step·validating x"
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 1' >/dev/null || fail "productive != 1"
  echo "$out" | jq -e '.aggregate.reserved_ownership_count == 1' >/dev/null || fail "reserved != 1"
  echo "$out" | jq -e '.aggregate.refill_safe == true' >/dev/null || fail "not refill safe"
  pass "active implementation is productive and reserved"
}

test_merge_wait_stays_reserved() {
  local aid out
  aid=$(fm_attempt_alloc pi bead-y holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-y"}' \
    '{"mode":"no-mistakes","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_write_receipt "$aid" 1 launch '{"endpoint":"w2"}' || fail "launch"
  fm_attempt_write_receipt "$aid" 1 landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  write_meta "task-y" ship no-mistakes "attempt=$aid"
  fake_crew_state "state: done·source: status-log·done: PR https://github.com/kunchenguid/firstmate/pull/1 checks green"
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 0' >/dev/null || fail "merge wait counted productive"
  echo "$out" | jq -e '.aggregate.reserved_ownership_count == 1' >/dev/null || fail "merge wait not reserved"
  echo "$out" | jq -e '.aggregate.reconciliation_required == true' >/dev/null || fail "merge wait did not need reconciliation"
  pass "merge-waiting delivery stays reserved until retirement"
}

test_retired_attempt_contributes_nothing() {
  local aid out
  aid=$(fm_attempt_alloc pi bead-z holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-z"}' \
    '{"mode":"local-only","base":"main","target":"local-main"}' || fail "freeze"
  fm_attempt_write_receipt "$aid" 1 launch '{"endpoint":"w3"}' || fail "launch"
  fm_attempt_write_receipt "$aid" 1 landing '{"disposition":"landed","local_main":"abc123"}' || fail "landing"
  fm_attempt_retire "$aid" 1 '{"audit":"terminal"}' || fail "retire"
  write_meta "task-z" ship local-only "attempt=$aid"
  fake_crew_state "state: done·source: status-log·done: ready in branch"
  out=$(fm_capacity_project)
  echo "$out" | jq -e '.aggregate.productive_count == 0 and .aggregate.reserved_ownership_count == 0' >/dev/null \
    || fail "retired attempt still counted"
  pass "only an atomically retired attempt contributes neither productive nor reserved capacity"
}

test_legacy_row_without_envelope_needs_reconciliation() {
  local out
  write_meta "legacy-1" ship direct-PR
  fake_crew_state "state: working·source: pane·busy"
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
  fake_crew_state "state: working·source: run-step·investigating"
  out=$(fm_capacity_project)
  [ "$(echo "$out" | jq '.rows | length')" = 0 ] || fail "scouts/secondmates appeared in rows"
  pass "scouts and persistent second mates are excluded from implementation capacity"
}

test_timeout_yields_ambiguous_row_not_free_slot() {
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
  pass "a timed-out worker read yields an incomplete observation and alert-only refill"
}

test_schema_failure_is_alert_only() {
  local out
  write_meta "bad-1" ship direct-PR
  fake_crew_state "state: working·source: run-step·busy"
  out=$(FM_CAPACITY_FORCE_SCHEMA_MISMATCH=1 fm_capacity_project 2>/dev/null || true)
  echo "$out" | jq -e '.schema == "fm-fleet-capacity.v1"' >/dev/null || fail "schema changed"
  echo "$out" | jq -e '.schema_ok == false and .alert_only == true and .aggregate.refill_safe == false' >/dev/null \
    || fail "schema mismatch did not make consumers alert-only"
  pass "a schema mismatch makes both automatic consumers alert-only while preserving ownership"
}

test_aggregates_are_exactly_derivable_from_rows() {
  local out derived
  write_meta "r1" ship direct-PR
  fake_crew_state "state: blocked·source: status-log·blocked: need credential"
  out=$(fm_capacity_project)
  derived=$(echo "$out" | jq '{pc:([.rows[]|select(.productive)]|length),rc:([.rows[]|select(.reserved)]|length),ac:([.rows[]|select((.ambiguity_reasons|length)>0)]|length)}')
  echo "$out" | jq -e --argjson d "$derived" \
    '.aggregate.productive_count == $d.pc and .aggregate.reserved_ownership_count == $d.rc and .aggregate.ambiguous_count == $d.ac' >/dev/null \
    || fail "aggregate not derivable from rows: $derived"
  pass "every aggregate is exactly derivable from the emitted rows"
}

test_implementation_is_productive_and_reserved
test_merge_wait_stays_reserved
test_retired_attempt_contributes_nothing
test_legacy_row_without_envelope_needs_reconciliation
test_scout_and_secondmate_are_excluded
test_timeout_yields_ambiguous_row_not_free_slot
test_schema_failure_is_alert_only
test_aggregates_are_exactly_derivable_from_rows
```

The fixtures above use the literal `·` middle-dot byte because the fake `fm-crew-state.sh` scripts are standalone and never source `tests/lib.sh`; the byte matches the real `bin/fm-crew-state.sh` output contract `state: <state> · source: <source> · <detail>`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/fm-capacity.test.sh`
Expected: FAIL with `fm_capacity_project: command not found`.

- [ ] **Step 3: Write the minimal implementation**

Create `bin/fm-capacity-lib.sh`:

```bash
#!/usr/bin/env bash
# The one shared capacity and attempt projection (schema fm-fleet-capacity.v1).
#
# This library is the ONLY classifier of implementation rows and aggregate
# capacity. It calls bin/fm-crew-state.sh for semantic worker state and
# combines that result with the attempt envelope and effect receipts from
# bin/fm-attempt-lib.sh. It defines no second worker state machine and never
# reads legacy manifests, output paths, output modification times, raw
# metadata counts, worker text, or private shadow fields.
#
# Consumers: bin/fm-fleet-refill.sh (--count-json and human output),
# bin/fm-fleet-snapshot.sh (embed), and bin/fm-refill-sentinel.sh. All three
# consume the exact object emitted here.

set -u

FM_CAPACITY_READ_TIMEOUT_SECS="${FM_CAPACITY_READ_TIMEOUT_SECS:-5}"
FM_CAPACITY_TOTAL_TIMEOUT_SECS="${FM_CAPACITY_TOTAL_TIMEOUT_SECS:-30}"

# shellcheck disable=SC2034
FM_CAPACITY_LIB_SOURCED=1

fm_capacity_rows_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

fm_capacity_meta_list() {  # -> one state/<id>.meta path per line, sorted
  local dir
  dir="$(fm_capacity_rows_dir)"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -name '*.meta' -printf '%f\n' 2>/dev/null \
    | sed 's/\.meta$//' | sort
}

fm_capacity_row() {  # <task-id> -> one fm-fleet-capacity.v1 row object
  local id=$1 meta attempt phase gen classification source
  local productive reserved missing ambiguity reconciliation
  local crew_state line state_detail
  meta="$dir/$id.meta"
  kind=$(sed -n 's/^kind=//p' "$meta" | head -1)
  [ "$kind" = ship ] || return 0
  attempt=$(sed -n 's/^attempt=//p' "$meta" | head -1)
  crew_state=$(timeout "$FM_CAPACITY_READ_TIMEOUT_SECS" \
    FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" FM_HOME="${FM_HOME:-}" \
    FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" FM_DATA_OVERRIDE="${FM_DATA_OVERRIDE:-}" \
    FM_PROJECTS_OVERRIDE="${FM_PROJECTS_OVERRIDE:-}" FM_CONFIG_OVERRIDE="${FM_CONFIG_OVERRIDE:-}" \
    "$(dirname "${BASH_SOURCE[0]}")/fm-crew-state.sh" "$id" 2>/dev/null | head -1 || true)
  if [ -z "$crew_state" ]; then
    jq -n --arg attempt "${attempt:-null}" --arg id "$id" \
      '{attempt_id:$attempt,task_key:$id,generation:null,kind:"ship",classification:"unknown",source:"none",productive:false,reserved:true,ambiguity_reasons:["worker_read_timeout"],missing_receipts:[],reconciliation_required:true}'
    return 0
  fi
  source=$(printf '%s' "$crew_state" | sed -n 's/.*source: \([^·]*\).*/\1/p' | tr -d ' ')
  case "$crew_state" in
    state:\ working*) classification="working" ;;
    state:\ blocked*) classification="blocked" ;;
    state:\ paused*) classification="paused" ;;
    state:\ done*) classification="done" ;;
    state:\ failed*) classification="failed" ;;
    state:\ parked*) classification="parked" ;;
    *) classification="unknown" ;;
  esac
  if [ -n "$attempt" ] && [ -f "$(attempt_path "$attempt")" ]; then
    gen=$(fm_attempt_generation "$attempt")
    phase=$(fm_attempt_phase "$attempt")
    missing=$(fm_attempt_missing_receipts "$attempt")
    if [ "$phase" = retired ]; then
      jq -n --arg attempt "$attempt" --arg gen "$gen" --arg phase "$phase" \
        '{attempt_id:$attempt,generation:($gen|tonumber),kind:"ship",classification:"retired",source:$source,productive:false,reserved:false,ambiguity_reasons:[],missing_receipts:[],reconciliation_required:false}'
      return 0
    fi
    case "$classification" in
      working)
        productive=true; reserved=true; reconciliation=false
        ambiguity=[] ;;
      blocked|paused|parked|done|failed|unknown)
        productive=false; reserved=true
        if [ -n "$missing" ]; then
          ambiguity=$(printf '%s' "$missing" | jq -R 'split(" ") | map("missing_receipt:" + .)')
          reconciliation=true
        else
          ambiguity=["not_retired"]; reconciliation=true
        fi ;;
    esac
    jq -n --arg attempt "$attempt" --arg gen "$gen" --arg phase "$phase" --arg source "$source" \
      --argjson productive "$productive" --argjson reserved "$reserved" \
      --argjson ambiguity "$ambiguity" --argjson reconciliation "$reconciliation" \
      --arg missing "$missing" \
      '{attempt_id:$attempt,generation:($gen|tonumber),kind:"ship",classification:$phase,source:$source,productive:$productive,reserved:$reserved,ambiguity_reasons:$ambiguity,missing_receipts:($missing|split(" ")|map(select(.!=""))),reconciliation_required:$reconciliation}'
    return 0
  fi
  # legacy row: no attempt envelope
  case "$classification" in
    working) productive=true; reserved=true ;;
    *) productive=false; reserved=true ;;
  esac
  jq -n --arg id "$id" --arg source "$source" \
    --argjson productive "$productive" --argjson reserved "$reserved" \
    '{attempt_id:null,task_key:$id,generation:null,kind:"ship",classification:$classification,source:$source,productive:$productive,reserved:$reserved,ambiguity_reasons:["missing_attempt_envelope"],missing_receipts:[],reconciliation_required:true}'
}

fm_capacity_project() {  # -> fm-fleet-capacity.v1 JSON on stdout
  local dir id rows generated schema_ok
  dir="$(fm_capacity_rows_dir)"
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  schema_ok=true
  if [ "${FM_CAPACITY_FORCE_SCHEMA_MISMATCH:-0}" = 1 ]; then schema_ok=false; fi
  rows=$(mktemp "${TMPDIR:-/tmp}/fm-capacity-rows.XXXXXX")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    fm_capacity_row "$id" >> "$rows"
  done < <(fm_capacity_meta_list)
  jq -s --arg generated "$generated" \
    --arg home "${FM_HOME:-local}" \
    --argjson schema_ok "$schema_ok" \
    '. as $rows |
     def has_timeout: ([$rows[] | select(.ambiguity_reasons | index("worker_read_timeout") != null)] | length) > 0;
     def incomplete: (has_timeout) or ($schema_ok | not);
     def reconciliation: ([$rows[] | select(.reconciliation_required == true)] | length > 0);
     def complete: (has_timeout | not);
     {
       schema:"fm-fleet-capacity.v1",
       generated:$generated,
       home_id:$home,
       observation_complete:complete,
       total_timeout:false,
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

The aggregate `refill_safe` is false whenever any row is unobserved (`worker_read_timeout`), the schema is not OK, or any row needs reconciliation; `observation_complete` is false exactly when any row is unobserved or the total read phase exceeded `FM_CAPACITY_TOTAL_TIMEOUT_SECS` (the total-timeout verdict is threaded through the same `has_timeout` row set by the bounded read wrapper, which marks every not-yet-read row with `worker_read_timeout` when the budget expires). The composition fixture in Task 12 pins the exact JSON so this derivation must match it byte-for-byte.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/fm-capacity.test.sh`
Expected: eight `ok -` lines.

- [ ] **Step 5: Verify the projection is read-only**

Run: `bash tests/fm-capacity.test.sh` again with `git status --short` before and after.
Expected: no tracked or state change beyond the test temp root; the projection mutates nothing.

- [ ] **Step 6: Commit**

```bash
git add bin/fm-capacity-lib.sh tests/fm-capacity.test.sh
git commit -m "feat(capacity): add the one shared capacity projection"
```

---

## Task 3: Shared-object consumers, shadow counting, and latency

Human refill output, the fleet snapshot, and the private sentinel all consume the exact object from Task 2. Shadow counting runs read-only next to the legacy arithmetic and measures hot-path latency.

**Files:**

- Modify: `bin/fm-fleet-refill.sh`
- Modify: `bin/fm-fleet-snapshot.sh`
- Create: `bin/fm-refill-sentinel.sh`
- Create: `tests/fm-refill-sentinel.test.sh`
- Extend: `tests/fm-fleet-refill.test.sh`
- Extend: `tests/fm-fleet-snapshot-view.test.sh`
- Create: `docs/verification/fleet-capacity.md` (shadow + latency record, completed in Task 12)

- [ ] **Step 1: Write the failing tests**

Append to `tests/fm-fleet-refill.test.sh`:

```bash
test_count_json_emits_shared_object() {
  local out
  write_meta_fixture ship direct-PR
  out=$(PATH="$FAKEBIN:$PATH" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$clean_probe" \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  echo "$out" | jq -e '.schema == "fm-fleet-capacity.v1"' >/dev/null || fail "schema"
  echo "$out" | jq -e '.aggregate.refill_safe == true' >/dev/null || fail "not refill safe"
  pass "fleet refill --count-json emits the shared capacity object"
}

test_human_output_derives_from_object() {
  local out
  write_meta_fixture ship direct-PR
  out=$(PATH="$FAKEBIN:$PATH" FM_REFILL_PROJECT="$PROJECT" \
    FM_SERIALIZATION_DEBT_PROBE="$clean_probe" \
    "$ROOT/bin/fm-fleet-refill.sh" 2>&1)
  assert_contains "$out" "fleet-refill:" "human summary line missing"
  assert_not_contains "$out" "active=" "legacy active counter leaked into human output"
  pass "human refill output derives from the shared object, not legacy counters"
}

test_count_json_emits_shared_object
test_human_output_derives_from_object
```

The two new tests need `write_meta_fixture` and the `clean_probe` fixture that already exist in the file (`clean_probe` is defined inside `test_refill_cadence_propagates_serialization_debt`; hoist it to file scope in the same edit). `write_meta_fixture` writes a `$TMP_ROOT/fake-state/<id>.meta` with `kind=ship`, `mode=direct-PR`, and points the refill script at it through a new `FM_STATE_OVERRIDE` env pass-through added in Step 3.

Extend `tests/fm-fleet-snapshot-view.test.sh`:

```bash
test_capacity_object_is_embedded_byte_identical() {
  local snap cap
  snap=$(FM_STATE_OVERRIDE="$STATE" FM_HOME="$HOME" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null)
  cap=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  [ "$(echo "$snap" | jq -c '.capacity')" = "$(echo "$cap" | jq -c '.')" ] \
    || fail "snapshot capacity differs from --count-json"
  pass "fleet snapshot embeds the exact capacity object"
}
```

Create `tests/fm-refill-sentinel.test.sh`:

```bash
#!/usr/bin/env bash
# Public-interface tests for the private fleet sentinel: it consumes the
# shared capacity object and owns only cadence, candidate query, logging, and
# notification policy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-refill-sentinel)
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"
export FM_STATE_OVERRIDE="$STATE"
export FM_REFILL_SENTINEL_LOG="$TMP_ROOT/sentinel.log"

test_sentinel_is_silent_when_refill_is_safe() {
  local out rc
  out=$(FM_CAPACITY_FIXTURE="$TMP_ROOT/safe.json" \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "safe sentinel should exit 0"
  [ -z "$out" ] || fail "safe sentinel printed: $out"
  pass "sentinel stays silent when the projection is refill-safe"
}

test_sentinel_notifies_on_reconciliation_or_alert() {
  local out rc
  out=$(FM_CAPACITY_FIXTURE="$TMP_ROOT/alert.json" \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1); rc=$?
  expect_code 1 "$rc" "alerting sentinel should exit 1"
  assert_contains "$out" "REFILL-ALERT" "alert line missing"
  pass "sentinel emits one alert line when reconciliation or alert-only applies"
}

test_sentinel_never_counts() {
  local out
  out=$(FM_CAPACITY_FIXTURE="$TMP_ROOT/safe.json" FM_REFILL_SENTINEL_VERBOSE=1 \
    "$ROOT/bin/fm-refill-sentinel.sh" 2>&1)
  assert_not_contains "$out" "productive_count" "sentinel recomputed capacity"
  pass "sentinel never classifies or recounts; it only consumes the object"
}

test_sentinel_is_silent_when_refill_is_safe
test_sentinel_notifies_on_reconciliation_or_alert
test_sentinel_never_counts
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/fm-fleet-refill.test.sh; bash tests/fm-fleet-snapshot-view.test.sh; bash tests/fm-refill-sentinel.test.sh`
Expected: FAIL on the new tests (`--count-json` unrecognized, `capacity` key absent, sentinel script missing).

- [ ] **Step 3: Rewrite `bin/fm-fleet-refill.sh` as a shared-object consumer**

Replace the body of `bin/fm-fleet-refill.sh`:

```bash
#!/usr/bin/env bash
# Fleet refill - run this as the FIRST action of ANY turn (before review
# polls, folds, landings, or completion processing). The dispatch decision is
# not a judgment call, it is a count - but the count comes from the one shared
# capacity projection (fm-fleet-capacity.v1), never from manifest mtimes.
#
# Prints a live status line + the exact next-wave dispatch commands. The
# serialization-debt probe stays a safety gate on dispatch; it is not capacity
# arithmetic. --count-json prints the shared object for the hot path.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-capacity-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"

PROJECT="${FM_REFILL_PROJECT:-/home/holu/decision-os}"
SERIALIZATION_DEBT_PROBE="${FM_SERIALIZATION_DEBT_PROBE:-$FM_HOME/bin/fm-serialization-debt.sh}"
FM_REFILL_TARGET_PRODUCTIVE="${FM_REFILL_TARGET_PRODUCTIVE:-6}"
FM_REFILL_RESERVED_CEILING="${FM_REFILL_RESERVED_CEILING:-10}"

if [ "${1:-}" = "--count-json" ]; then
  fm_capacity_project
  exit 0
fi

"$SERIALIZATION_DEBT_PROBE" --project "$PROJECT" || exit 1

cap=$(fm_capacity_project)
echo "$cap" | jq -r --argjson target "$FM_REFILL_TARGET_PRODUCTIVE" \
  --argjson ceiling "$FM_REFILL_RESERVED_CEILING" '
  def verdict:
    if (.aggregate.refill_safe | not) then "REFILL-UNSAFE"
    elif (.aggregate.productive_count < $target) and
         (.aggregate.reserved_ownership_count < $ceiling) then "DISPATCH-NEEDED"
    else "fleet-ok" end;
  "fleet-refill: productive=\(.aggregate.productive_count) reserved=\(.aggregate.reserved_ownership_count) ambiguous=\(.aggregate.ambiguous_count) (target=\($target) ceiling=\($ceiling)) verdict=\(verdict)"
'
```

The exact next-wave dispatch commands (the `br show` verification plus launch commands) are printed by Task 10's refill admission path; this task only changes the verdict line and adds `--count-json`. The old manifest read, `TASKS_DIR`, `ACTIVE_WINDOW_MIN`, `QUEUE_WINDOW_MIN`, `MIN_BATTERY`, `MIN_OPEN`, and the `br list --status open --json` open-count arithmetic are deleted in Task 13; until then they must not be re-added and must not influence this script.

- [ ] **Step 4: Embed the capacity object in `bin/fm-fleet-snapshot.sh`**

Modify `bin/fm-fleet-snapshot.sh`:

- Source the library near line 133 (`# shellcheck source=bin/fm-capacity-lib.sh` then `. "$SCRIPT_DIR/fm-capacity-lib.sh"`).
- Before the final jq emit (around line 1383), compute `CAPACITY_JSON=$(fm_capacity_project)` with the same `FM_ROOT_OVERRIDE`/`FM_HOME`/`FM_STATE_OVERRIDE`/`FM_DATA_OVERRIDE`/`FM_PROJECTS_OVERRIDE`/`FM_CONFIG_OVERRIDE` env pass-through that `crew_state_json` already uses at line 195.
- Add `capacity: ($capacity | fromjson)` to the emitted object, where `$capacity` is passed as `--argjson capacity "$CAPACITY_JSON"`.
- Do not classify or recount anything in the snapshot: the embedded object is the exact output of `fm_capacity_project`.

- [ ] **Step 5: Create `bin/fm-refill-sentinel.sh`**

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

# Candidate query is the same authoritative query the refill path uses; the
# sentinel only logs a bounded digest, it never launches.
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

Cadence policy lives home-local: `config/refill-sentinel` (gitignored) may set `FM_REFILL_SENTINEL_CADENCE_SECS`; the away-mode daemon heartbeat review invokes this script at that cadence instead of its own empty review. Notification policy is the single `REFILL-ALERT:` line, surfaced through the existing watcher/daemon digest path; no new channel.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bash tests/fm-fleet-refill.test.sh; bash tests/fm-fleet-snapshot-view.test.sh; bash tests/fm-refill-sentinel.test.sh`
Expected: all green, including the legacy refill tests (serialization-debt propagation stays).

- [ ] **Step 7: Measure hot-path latency (shadow)**

Run on the real home with the fleet at rest:

```bash
/usr/bin/time -f 'count-json wall=%e s' bin/fm-fleet-refill.sh --count-json >/dev/null
```

Expected: wall time below 2000 ms with default timeouts at the current fleet size. Record the date, firstmate version (the branch commit), command, and exact output in `docs/verification/fleet-capacity.md` under a `## Latency (shadow)` heading, in the maintainer-verification format used by `docs/verification/runtime-backends.md`.

- [ ] **Step 8: Commit**

```bash
git add bin/fm-fleet-refill.sh bin/fm-fleet-snapshot.sh bin/fm-refill-sentinel.sh
git add tests/fm-fleet-refill.test.sh tests/fm-fleet-snapshot-view.test.sh tests/fm-refill-sentinel.test.sh
git add docs/verification/fleet-capacity.md
git commit -m "feat(capacity): shadow counting and shared-object consumers with measured latency"
```

---

## Task 4: Reconcile stale records individually

One-time migration helper that classifies every legacy task (no attempt envelope) from live bead, worker, Git, forge, copy, and queue facts, then either creates an envelope for the in-flight attempt or retires it with a named disposition. It never migrates or retires branches (Decision OS Task 7.7 boundary) and never discards unknown or unlanded work.

**Files:**

- Create: `bin/fm-attempt-migrate.sh`
- Create: `tests/fm-attempt-migrate.test.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/fm-attempt-migrate.test.sh` with fixtures for: landed task with a merged PR (retired, disposition `landed`), live task with a running worker (envelope created, phase `running`), unknown worker and unknown forge state (left untouched, `reconciliation_required`), and a closed-unmerged PR (preserved, disposition `preserved_unlanded`). The fixture reads `state/<id>.meta`, `state/<id>.status`, a fake `br show --json` output, and a fake git branch list.

Key assertions:

```bash
test_landed_legacy_task_is_retired_with_disposition() {
  # meta kind=ship mode=direct-PR, status done: PR <url>, fake br show merged,
  # fake git: branch fm/x merged into origin/main
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_PROJECT="$PROJECT" \
    "$ROOT/bin/fm-attempt-migrate.sh" legacy-1 2>&1)
  assert_contains "$out" "retired disposition=landed" "landed task not retired"
  local f="$STATE/attempts/legacy-1-a1.json"
  [ -f "$f" ] || fail "no envelope written for $f"
  jq -e '.phase == "retired" and .receipts.landing.evidence.disposition == "landed"' "$f" >/dev/null \
    || fail "landing receipt missing"
  pass "landed legacy task is retired with a landing receipt"
}

test_unknown_work_is_preserved() {
  # fake br show unknown, fake git unknown head, worker state unknown
  local out
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_PROJECT="$PROJECT" \
    "$ROOT/bin/fm-attempt-migrate.sh" legacy-2 2>&1)
  assert_contains "$out" "preserved" "unknown work was not preserved"
  local f="$STATE/attempts/legacy-2-a1.json"
  jq -e '.phase != "retired" and .receipts.landing.evidence.disposition == "unknown"' "$f" >/dev/null \
    || fail "unknown disposition not recorded"
  pass "unknown or unlanded work is preserved, never discarded"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-attempt-migrate.test.sh`
Expected: FAIL with `fm-attempt-migrate.sh: No such file`.

- [ ] **Step 3: Implement `bin/fm-attempt-migrate.sh`**

```bash
#!/usr/bin/env bash
# One-time migration helper: classify each legacy task (no attempt envelope)
# from live bead, worker, Git, forge, copy, and queue facts, then create the
# envelope for the in-flight attempt or retire it with an exact disposition.
# Never migrates or retires branches, never discards unknown or unlanded work,
# and never writes to the tracker. Re-run-safe: a task with an envelope is
# skipped.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"

PROJECT="${FM_REFILL_PROJECT:-/home/holu/decision-os}"

disposition_for() {  # <task-id> -> landed | preserved_unlanded | unknown
  local id=$1 state_line pr
  state_line=$(tail -1 "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.status" 2>/dev/null || true)
  pr=$(printf '%s' "$state_line" | sed -n 's/.*PR \([^ ]*\)/https:\/\/\1/p' | head -1)
  if [ -n "$pr" ]; then
    # forge authority: br/gh state is authoritative; a merged PR proves landing
    local merged
    merged=$(cd "$PROJECT" && br show "${id%%-*}" --json 2>/dev/null \
      | jq -r 'if .status == "closed" and (.state // .closure_reason // "") != "unmerged" then "yes" else "no" end')
    [ "$merged" = yes ] && { echo landed; return; }
    echo preserved_unlanded
    return
  fi
  echo unknown
}

migrate_one() {  # <task-id>
  local id=$1
  [ -f "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta" ] || { echo "skip: no meta for $id"; return 0; }
  [ -d "$(attempts_dir)" ] || mkdir -p "$(attempts_dir)"
  local attempt=$(sed -n 's/^attempt=//p' "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta" | head -1)
  [ -n "$attempt" ] && [ -f "$(attempt_path "$attempt")" ] && { echo "skip: $id already has $attempt"; return 0; }
  local disp; disp=$(disposition_for "$id")
  local aid; aid=$(fm_attempt_alloc pi "$id" "${FM_HOME:-local}") || return 1
  if [ "$disp" = unknown ]; then
    echo "preserved: $id disposition=unknown (reconcile from live facts)"
    return 0
  fi
  fm_attempt_write_receipt "$aid" 1 landing "{\"disposition\":\"$disp\",\"migrated\":true}" || return 1
  fm_attempt_retire "$aid" 1 "{\"audit\":\"migration\",\"disposition\":\"$disp\"}" \
    && echo "retired: $id disposition=$disp" || echo "preserved: $id disposition=$disp"
}

for id in "$@"; do migrate_one "$id"; done
```

The disposition classifier reads only authoritative owners (forge state, git branch state, worker status) and never infers landing from output paths or mtimes. `br show --json` state fields are verified against the installed `br` version during implementation (Task 4 Step 4) and the exact field names pinned in the test fixtures.

- [ ] **Step 4: Verify**

Run: `bash tests/fm-attempt-migrate.test.sh` then `bash tests/fm-attempt.test.sh` and `bash tests/fm-capacity.test.sh`.
Expected: all green. Also run `br show <any-open-bead> --json | jq 'keys'` against the real decision-os workspace and record the exact state fields used by `disposition_for` in the test fixtures so the classifier matches the installed `br` 0.2.19.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-attempt-migrate.sh tests/fm-attempt-migrate.test.sh
git commit -m "feat(attempts): reconcile stale records individually without migrating branches"
```

---

## Task 5: Claim-before-allocation and the Decision OS steward adapter

Decision OS Task 7.4 leaf: the split pre-dispatch handshake and the attended `fm-br-receipt.sh` adapter.

**Files:**

- Create: `bin/fm-br-receipt.sh`
- Create: `tests/fm-br-receipt.test.sh`
- Modify: `bin/fm-spawn.sh` (intake handshake)
- Extend: `tests/fm-backlog-handoff.test.sh`
- Extend: `tests/fm-spawn-worktree-settle.test.sh`

- [ ] **Step 1: Write the failing tests**

Create `tests/fm-br-receipt.test.sh` with a fake decision-os clone (`.beads/issues.jsonl`, a fake `scripts/br_worktree_storage.py` that records invocations and returns canned verdicts, and a fake `br` in PATH). Cover, per Task 7.4: tracker digest/revision mismatch refuses mutation; only an explicitly authorized current-session semantic transition is accepted; only the registered project clone is used; only `.beads/issues.jsonl` is staged; a valid `Closure-Receipt:` comment precedes every close; receipt-only commit is produced; refresh/push is fast-forward-only; conflicts and push failure become durable pending obligations; claim refusal, stale expected state/hash, steward unavailability, retry before receipt, replay after receipt, and an already truthfully claimed task - none may double-claim or launch early.

Representative preamble and assertions:

```bash
TMP_ROOT=$(fm_test_tmproot fm-br-receipt)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
ORDER="$TMP_ROOT/order.log"
REMOTE="$TMP_ROOT/remote.git"
mkdir -p "$STATE" "$FAKEBIN"

# fake registered decision-os main clone: real git repo on main with a bare
# origin so the adapter's pathspec commit + push succeed, plus the storage
# script and a .venv/bin/python shim
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

fake_storage() {  # <exit-code>
  cat > "$PROJECT/scripts/br_worktree_storage.py" <<'SH'
#!/usr/bin/env python3
import sys, os
with open(os.environ["ORDER_FILE"], "a") as f:
    f.write(" ".join(sys.argv[1:]) + "\n")
sys.exit(int(os.environ.get("STORAGE_EXIT", sys.argv[1] if len(sys.argv) > 1 else "0")))
SH
  chmod +x "$PROJECT/scripts/br_worktree_storage.py"
}

fake_br() {
  cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
set -u
echo "$*" >> "${ORDER_FILE:?}"
case "$1" in
  comments)
    # real br comments add writes .beads/issues.jsonl; mirror that so the
    # adapter's pathspec commit + push have a real diff
    if [ "$2" = add ]; then
      printf '%s\n' "{\"id\":\"$3\",\"comment\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}" \
        >> "${ISSUES_FILE:?}"
      git -C "${PROJECT_DIR:?}" add .beads/issues.jsonl >/dev/null
    fi
    printf '%s\n' "[{\"text\":\"Closure-Receipt: landed authority attempt=${FAKE_ATTEMPT:?}\"}]" ;;
  close) exit "${BR_CLOSE_EXIT:-0}" ;;
  show) printf '%s\n' '{"id":"dos-x","status":"open"}' ;;
  *) exit "${BR_OTHER_EXIT:-0}" ;;
esac
SH
  chmod +x "$FAKEBIN/br"
}

test_claim_refusal_keeps_claim_pending() {
  local req aid rc out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-x holu) || fail "alloc"
  REQ="$TMP_ROOT/claim.json"
  cat > "$REQ" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-x","transition":"claim","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"intake","authority":"captain:dispatch","agent":"pi-primary","repo":"$PROJECT"}
JSON
  fake_storage 1
  fake_br
  out=$(FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" \
    STORAGE_EXIT=1 "$ROOT/bin/fm-br-receipt.sh" "$REQ" 2>&1); rc=$?
  expect_code 1 "$rc" "refused claim should fail"
  [ "$(fm_attempt_phase "$aid")" = claim_pending ] || fail "attempt left claim_pending"
  [ ! -e "$PROJECT/worktree-created" ] || fail "provider copy created before claim receipt"
  pass "a refused claim keeps the attempt claim_pending with no provider copy"
}

test_closure_receipt_precedes_close() {
  local aid rc out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-y holu) || fail "alloc"
  REQ="$TMP_ROOT/close.json"
  cat > "$REQ" <<JSON
{"attempt_id":"$aid","generation":1,"bead_id":"dos-y","transition":"close","expected_state":"open","expected_source_hash":"$(sha256sum "$PROJECT/.beads/issues.jsonl" | cut -d' ' -f1)","evidence":"landed pr https://github.com/kunchenguid/firstmate/pull/1","authority":"captain:merge","agent":"pi-primary","repo":"$PROJECT"}
JSON
  fake_storage 0
  fake_br
  out=$(FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" ORDER_FILE="$ORDER" FAKE_ATTEMPT="$aid" \
    ISSUES_FILE="$PROJECT/.beads/issues.jsonl" PROJECT_DIR="$PROJECT" \
    STORAGE_EXIT=0 "$ROOT/bin/fm-br-receipt.sh" "$REQ" 2>&1); rc=$?
  expect_code 0 "$rc" "close should succeed"
  assert_contains "$(cat "$ORDER")" "comments add dos-y -m Closure-Receipt:" "closure receipt comment missing"
  assert_contains "$(cat "$ORDER")" "close dos-y" "close missing"
  local i1 i2
  i1=$(grep -n "comments add" "$ORDER" | head -1 | cut -d: -f1)
  i2=$(grep -n "close dos-y" "$ORDER" | head -1 | cut -d: -f1)
  [ "$i1" -lt "$i2" ] || fail "close ran before the Closure-Receipt comment"
  pass "the operative Closure-Receipt comment precedes br close"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-br-receipt.test.sh`
Expected: FAIL with `fm-br-receipt.sh: No such file`.

- [ ] **Step 3: Implement `bin/fm-br-receipt.sh`**

```bash
#!/usr/bin/env bash
# Attended Decision OS main-steward adapter. Executes one authorized tracker
# mutation request (schema fm-tracker-request.v1) against the registered
# decision-os main clone and persists the authoritative receipt into the
# attempt record. Only the attended Decision OS main steward invokes this
# script. It never infers or enlarges authority.
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
PY=PYTHONPATH=src
STORAGE="$repo/scripts/br_worktree_storage.py"

fail_tracker() {  # <reason>
  echo "tracker_pending: $*" >&2
  exit 1
}

[ -n "$authority" ] || fail_tracker "missing current-session authority"
[ -n "$agent" ] || fail_tracker "missing bound agent identity"

# 1. durable pause receipt: stop new decision-os worktree creation and all
#    admitted tracker writers for this attempt.
PAUSE="$FM_HOME/state/.tracker-pause"
printf '%s\n' "attempt=$attempt transition=$transition started=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$PAUSE"

# 2. enter the canonical registered main clone, never a linked worktree
cd "$repo" || fail_tracker "not the registered clone: $repo"
[ -d .beads ] || fail_tracker "no .beads in $repo"

# 3. verify session, identity, authority, clean preflight, expected commit and
#    pre-mutation source hash
out=$("$PY" .venv/bin/python "$STORAGE" verify-session 2>&1) || fail_tracker "verify-session: $out"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || fail_tracker "clone not on main"
actual_hash=$(sha256sum .beads/issues.jsonl | cut -d' ' -f1)
[ "$actual_hash" = "$expected_hash" ] || fail_tracker "source hash mismatch $actual_hash != $expected_hash"

case "$transition" in
  claim)
    out=$("$PY" .venv/bin/python "$STORAGE" claim "$bead" --agent "$agent" 2>&1) \
      || fail_tracker "claim refused: $out"
    post_state="claimed" ;;
  close)
    # Closure-Receipt must be operative BEFORE br close
    br comments add "$bead" -m "Closure-Receipt: landed $authority attempt=$attempt" >/dev/null 2>&1 \
      || fail_tracker "closure receipt comment failed"
    br comments show "$bead" --json 2>/dev/null | jq -e --arg s "attempt=$attempt" \
      '.[] | select(.text | contains("Closure-Receipt:")) | select(.text | contains($s))' >/dev/null \
      || fail_tracker "operative Closure-Receipt comment not verified"
    br close "$bead" >/dev/null 2>&1 || fail_tracker "br close failed"
    post_state="closed" ;;
  status)
    # bounded status transition: only the exact authorized semantic transition
    br update "$bead" --status "$expected_state" >/dev/null 2>&1 \
      || fail_tracker "status transition refused" ;;
  *) fail_tracker "unknown transition $transition" ;;
esac

# 4. JSONL + unique-ID validation, then commit ONLY .beads/issues.jsonl
"$PY" .venv/bin/python "$STORAGE" preflight >/dev/null 2>&1 \
  || fail_tracker "post-mutation preflight failed"
git diff --name-only | grep -qx '.beads/issues.jsonl' || {
  [ -z "$(git diff --name-only | grep -v '^\.beads/issues\.jsonl$')" ] \
    || fail_tracker "staged path outside .beads/issues.jsonl"
}
post_hash=$(sha256sum .beads/issues.jsonl | cut -d' ' -f1)
git add .beads/issues.jsonl
git commit -m "tracker: $transition $bead attempt=$attempt" >/dev/null 2>&1 \
  || fail_tracker "receipt-only commit failed"
git push origin main >/dev/null 2>&1 || fail_tracker "push failed (pending obligation)"

# 5. verify committed blob hash equals the validated post-mutation source hash
committed=$(git rev-parse HEAD:.beads/issues.jsonl | xargs -I{} git cat-file blob {} | sha256sum | cut -d' ' -f1)
[ "$committed" = "$post_hash" ] || fail_tracker "committed blob hash mismatch"

# 6. persist the receipt before releasing the pause
recv=$(jq -n --arg bead "$bead" --arg post "$post_state" --arg commit "$(git rev-parse HEAD)" \
  --arg source_hash "$actual_hash" --arg post_hash "$post_hash" --arg authority "$authority" \
  '{bead:$bead,status:$post,commit:$commit,source_hash:$source_hash,post_hash:$post_hash,authority:$authority,agent:"'"$agent"'"}')
fm_attempt_write_receipt "$attempt" "$gen" tracker "$recv" || fail_tracker "receipt persist failed"
rm -f "$PAUSE"
echo "tracker_receipt: $attempt $transition $bead $post_state $(git rev-parse HEAD)"
```

The push-failure path writes the pending obligation into `state/attempts/<attempt>.obligation.tracker.json` (a durable pending-obligation record, Task 11 retries it idempotently) before failing; the pause is released by the attended steward only after the receipt persists or the failure is recorded. Only the canonical registered clone path is ever used; no raw `br --claim` is ever executed (Task 7.4 boundary).

- [ ] **Step 4: Wire the split pre-dispatch handshake into `bin/fm-spawn.sh`**

Modify `bin/fm-spawn.sh` intake, before any workspace allocation and before any endpoint creation (the exact anchor is the existing `validate_spawn_worktree`-adjacent intake block around lines 1821-1958 where `treehouse get` runs):

1. Allocate the immutable attempt: `attempt_id=$(fm_attempt_alloc pi "$task_key" "$home_id")` where `task_key` is the bead id for a bead-backed task and the backlog item id otherwise, `home_id` the resolved home.
2. Persist the exact claim request at `state/attempts/$attempt_id.request.claim.json` with `{attempt_id, generation, bead_id, transition:"claim", expected_state:"open", expected_source_hash:<sha256 of the registered clone's .beads/issues.jsonl>, evidence:"intake", authority:"<session authority>", agent:"<bound agent>", repo:"<registered clone>"}`.
3. Call `fm-br-receipt.sh "$REQ"` synchronously. On success, the tracker receipt is already persisted and the phase is advanced by Task 6's freeze. On refusal or steward unavailability, keep `claim_pending`, print `claim_pending: <reason>`, and return without allocating any workspace or launching any endpoint.
4. Write `attempt=<attempt_id>` into `state/<id>.meta` (append to the existing meta write at lines 568-694).
5. Add the ledger append: after runtime launch and required instruction-delivery confirmation succeed, append one row `{attempt_id, launched_at, endpoint}` to `state/launch-ledger.jsonl`, guarded so a row for that attempt id is appended at most once; recovery of a crash before ledger publication relies on the attempt envelope, never the ledger.

- [ ] **Step 5: Verify**

Run: `bash tests/fm-br-receipt.test.sh; bash tests/fm-backlog-handoff.test.sh; bash tests/fm-spawn-worktree-settle.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green. The spawn tests must prove the new order: no workspace or endpoint exists before `claim_observed`; a refused claim leaves no copy and no endpoint; replay after receipt does not double-claim.

- [ ] **Step 6: Commit**

```bash
git add bin/fm-br-receipt.sh tests/fm-br-receipt.test.sh bin/fm-spawn.sh
git add tests/fm-backlog-handoff.test.sh tests/fm-spawn-worktree-settle.test.sh
git commit -m "feat(tracker): add authoritative br receipts with claim-before-allocation"
```

---

## Task 6: Make physical-copy ownership provider-wide

Decision OS Task 7.2 leaf.

**Files:**

- Modify: `bin/fm-spawn.sh`
- Modify: `bin/fm-home-seed.sh`
- Modify: `bin/fm-backend.sh`
- Modify: `bin/fm-teardown.sh` (receipt surface only; full factoring in Task 8)
- Extend: `tests/fm-spawn-worktree-settle.test.sh`, `tests/fm-secondmate-safety.test.sh`, `tests/fm-backend-orca.test.sh`

- [ ] **Step 1: Write the failing tests**

Extend `tests/fm-spawn-worktree-settle.test.sh`:

```bash
claim_copy() {  # <home-id> <attempt-id>
  # fake treehouse get that records the lease holder per copy and fails when
  # the copy is already held by a different home
  if [ -e "$COPY_HOLDER" ] && [ "$(cat "$COPY_HOLDER")" != "$1" ]; then
    echo "treehouse: copy already leased to $(cat "$COPY_HOLDER")" >&2
    return 1
  fi
  printf '%s\n' "$1" > "$COPY_HOLDER"
  echo "$COPY_PATH"
}

test_two_homes_cannot_acquire_same_copy() {
  local out1 out2
  out1=$(FM_HOME=home-a claim_copy home-a a1)
  out2=$(FM_HOME=home-b claim_copy home-b a2 2>&1); rc=$?
  expect_code 1 "$rc" "second home acquired the same copy"
  assert_contains "$out2" "already leased" "second home did not name the holder"
  [ "$(cat "$COPY_HOLDER")" = home-a ] || fail "lease holder changed"
  pass "two homes cannot acquire the same physical copy"
}

test_crash_after_allocation_retains_pending_release_obligation() {
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-c holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-c"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  # simulate a crash after the provider receipt: the provider receipt exists,
  # the launch receipt is missing, and the required set derives the release
  # obligation
  assert_contains "$(fm_attempt_missing_receipts "$aid")" "launch" "no pending obligation after crash"
  pass "a crash after allocation retains a pending release obligation"
}

test_replay_releases_only_the_exact_owning_attempt() {
  local aid1 aid2
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid1=$(fm_attempt_alloc pi dos-d holu)
  aid2=$(fm_attempt_alloc pi dos-e holu)
  fm_attempt_freeze_allocation "$aid1" 1 '{"provider":"tmux","copy":"wt-d"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}'
  fm_attempt_freeze_allocation "$aid2" 1 '{"provider":"tmux","copy":"wt-e"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}'
  # replay of a2 must not release wt-d owned by a1
  [ "$(fm_attempt_load "$aid2" | jq -r '.provider.copy')" = wt-e ] || fail "a2 owns wrong copy"
  [ "$(fm_attempt_load "$aid1" | jq -r '.provider.copy')" = wt-d ] || fail "a1 lost its copy"
  pass "replay releases only the exact owning attempt"
}
```

Extend `tests/fm-backend-orca.test.sh` with the same three shapes against the Orca worktree claim surface, and `tests/fm-secondmate-safety.test.sh` for the secondmate lease (`treehouse get --lease --lease-holder <id>`).

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-spawn-worktree-settle.test.sh; bash tests/fm-secondmate-safety.test.sh; bash tests/fm-backend-orca.test.sh`
Expected: FAIL on the new tests.

- [ ] **Step 3: Implement provider-wide ownership**

In `bin/fm-spawn.sh` after the claim receipt is observed:

1. Acquire the physical copy with a provider-wide claim: for treehouse use `treehouse get --lease --lease-holder "$home_id"` (the same primitive `fm-home-seed.sh` already uses at lines 392-400), for Orca use the existing `orca worktree` claim path, for herdr/zellij/cmux the pool path with the same lease-holder binding. One physical copy is owned by exactly one `(home_id, attempt_id)`.
2. On success, call `fm_attempt_freeze_allocation "$attempt" "$gen" '{"provider":"<backend>","copy":"<path>"}' '{"mode":"<mode>","base":"<base>","target":"<target>"}'` and write a `provider` receipt with the exact copy identity.
3. A crash after allocation leaves the `provider` receipt in place; the pending release obligation is derived from it (`fm_attempt_missing_receipts` already reports `provider`-derived obligations; extend the required sets so `allocating` requires `provider`, and add a `release` receipt name that cleanup records in Task 8).
4. Replay after a crash verifies the attempt owns the exact copy before touching it; it never releases a copy owned by a different attempt or home.

In `bin/fm-home-seed.sh`, change the secondmate lease to record `attempt=`-bound ownership through the same attempt record when the secondmate seed is itself an attempt (Task 7.2's "no second Treehouse lease store" boundary: the attempt record is the coordination owner, the treehouse lease remains the provider store).

In `bin/fm-backend.sh`, add `fm_backend_stop_receipt <backend> <id>` that returns the durable endpoint-stop evidence JSON (window/tab/pane identity plus confirmed-gone verdict) that cleanup records as the `cleanup.endpoint` effect.

- [ ] **Step 4: Verify**

Run: `bash tests/fm-spawn-worktree-settle.test.sh; bash tests/fm-secondmate-safety.test.sh; bash tests/fm-backend-orca.test.sh; bash tests/fm-teardown.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-spawn.sh bin/fm-home-seed.sh bin/fm-backend.sh
git add tests/fm-spawn-worktree-settle.test.sh tests/fm-secondmate-safety.test.sh tests/fm-backend-orca.test.sh
git commit -m "feat(attempts): make workspace claims provider-wide"
```

---

## Task 7: Persist exact forge and landing observations

Decision OS Task 7.3 leaf.

**Files:**

- Modify: `bin/fm-pr-lib.sh`
- Modify: `bin/fm-pr-check.sh`
- Modify: `bin/fm-pr-merge.sh`
- Modify: `bin/fm-pr-poll.sh`
- Modify: `bin/fm-merge-local.sh`
- Extend: `tests/fm-pr-check-security.test.sh`, `tests/fm-pr-merge.test.sh`

- [ ] **Step 1: Write the failing tests**

Extend `tests/fm-pr-check-security.test.sh` with fixtures for open, merged, closed-unmerged, and unknown forge states; exact provider/repository/source/target/head identity; full local before/after SHAs; crash/replay after each persisted receipt; and GitLab missing-head behavior remaining unknown, never guessed. Extend `tests/fm-pr-merge.test.sh` for squash-merge landing proof and local-only merge proof.

Representative assertion:

```bash
test_landing_observation_persisted_with_exact_identity() {
  local aid rc out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-f holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-f"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  # fake gh-axi pr view returns merged with pr_head abc123; run fm-pr-check
  # against a fake meta carrying attempt=$aid, then assert the landing receipt
  FAKEBIN="$TMP_ROOT/fakebin"
  mkdir -p "$FAKEBIN"
  cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"state":"MERGED","headRefOid":"abc123","mergeCommit":{"oid":"new"},"baseRefOid":"old"}'
SH
  chmod +x "$FAKEBIN/gh-axi"
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\n' "$aid" > "$STATE/task-f.meta"
  out=$(FM_STATE_OVERRIDE="$STATE" PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-f "https://github.com/kunchenguid/firstmate/pull/9" 2>&1); rc=$?
  expect_code 0 "$rc" "pr-check failed"
  jq -e '.receipts.landing.evidence.provider == "github" and
         .receipts.landing.evidence.head == "abc123" and
         .receipts.landing.evidence.before_sha == "old" and
         .receipts.landing.evidence.after_sha == "new"' \
    "$STATE/attempts/$aid.json" >/dev/null \
    || fail "landing identity not exact"
  pass "landing observations persist exact identity and SHAs"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-pr-check-security.test.sh; bash tests/fm-pr-merge.test.sh`
Expected: FAIL on the new tests.

- [ ] **Step 3: Implement**

For each of `fm-pr-check.sh`, `fm-pr-merge.sh`, `fm-pr-poll.sh`, and `fm-merge-local.sh`: after the authoritative observation is made, write the exact landing observation into the attempt record through `fm_attempt_write_receipt "$attempt" "$gen" landing '<evidence>'` when the task meta carries `attempt=`; the evidence object contains `{provider, repo, source, target, head, state, before_sha, after_sha}` with every field populated or explicitly null, never inferred. A crash after a forge write but before the receipt persists is recovered by re-reading the forge (the receipt write is idempotent). `bin/fm-pr-lib.sh` owns the landing-evidence schema and the `pr_head=`/`pr=` meta fields remain as today.

A squash merge is recorded `landed` only when existing Git and forge proof establishes content equivalence (the existing `patch_id_for_commit`/`unpushed_patches_are_in_pr_head` logic in `bin/fm-teardown.sh` at lines 734-770 is the exact-equivalence owner; reuse it, do not duplicate it).

- [ ] **Step 4: Verify**

Run: `bash tests/fm-pr-check-security.test.sh; bash tests/fm-pr-merge.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-pr-lib.sh bin/fm-pr-check.sh bin/fm-pr-merge.sh bin/fm-pr-poll.sh bin/fm-merge-local.sh
git add tests/fm-pr-check-security.test.sh tests/fm-pr-merge.test.sh
git commit -m "feat(delivery): persist exact landing observations"
```

---

## Task 8: One structured cleanup operation and the teardown compatibility wrapper

Factor the existing teardown owner into one structured attempt-bound cleanup operation; `bin/fm-teardown.sh` becomes the ordinary compatibility wrapper so terminal orchestration and direct cleanup cannot drift into parallel policies.

**Files:**

- Create: `bin/fm-cleanup-lib.sh`
- Create: `tests/fm-cleanup.test.sh`
- Modify: `bin/fm-teardown.sh`
- Extend: `tests/fm-teardown.test.sh`, `tests/fm-teardown-endpoint-safety.test.sh`

- [ ] **Step 1: Write the failing tests**

Create `tests/fm-cleanup.test.sh` with per-provider fixtures (tmux, herdr, zellij, orca, cmux), exact recovery refs, live-process and quiet refusal, cleanup crashes, structured per-effect receipts, branch-disposition failure, and compatibility-wrapper identity:

```bash
setup_cleanup_attempt() {  # -> prints attempt id with claim+launch receipts and a tmux provider copy
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-g holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 "{\"provider\":\"tmux\",\"copy\":\"$TMP_ROOT/wt-g\"}" \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_write_receipt "$aid" 1 launch '{"endpoint":"w-g"}' || fail "launch"
  printf '%s\n' "$aid"
}

test_cleanup_refuses_live_processes_and_immature_quiet() {
  local aid out
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  # a fake live process whose cwd is the copy
  (cd "$TMP_ROOT/wt-g" && sleep 300) &
  local pid=$!
  out=$(FM_STATE_OVERRIDE="$STATE" FM_TERMINAL_QUIET_SECS=100 \
    "$ROOT/bin/fm-cleanup-lib.sh" --run "$aid" landed 2>&1 || true)
  kill "$pid" 2>/dev/null || true
  assert_contains "$out" "refused" "cleanup did not refuse"
  [ -d "$TMP_ROOT/wt-g" ] || fail "copy was removed on refusal"
  pass "live processes and immature quiet preserve the copy"
}

test_cleanup_records_branch_disposition_failure() {
  local aid out
  aid=$(setup_cleanup_attempt)
  mkdir -p "$TMP_ROOT/wt-g"
  out=$(FM_STATE_OVERRIDE="$STATE" FM_TERMINAL_QUIET_SECS=0 FM_BRANCH_DELETE_FAIL=1 \
    "$ROOT/bin/fm-cleanup-lib.sh" --run "$aid" landed 2>&1 || true)
  jq -e '.receipts["cleanup.branch"].evidence.failed == true' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "branch-disposition failure suppressed"
  pass "branch-disposition failure is recorded, never suppressed"
}

test_teardown_wrapper_identity() {
  local aid out
  aid=$(setup_cleanup_attempt)
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\nworktree=%s/wt-g\n' "$aid" "$TMP_ROOT" > "$STATE/task-g.meta"
  out=$(FM_STATE_OVERRIDE="$STATE" FM_TERMINAL_QUIET_SECS=0 \
    "$ROOT/bin/fm-teardown.sh" task-g --force 2>&1 || true)
  jq -e '.receipts["cleanup.runtime"] != null' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "teardown wrapper did not run the shared operation"
  pass "fm-teardown.sh is a compatibility wrapper over the same operation"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-cleanup.test.sh`
Expected: FAIL with `fm-cleanup-lib.sh: No such file`.

- [ ] **Step 3: Implement `bin/fm-cleanup-lib.sh`**

```bash
#!/usr/bin/env bash
# One structured attempt-bound cleanup operation, factored from
# bin/fm-teardown.sh. Reuses the current safety and provider logic; owns no
# product-landing policy. Accepts an already classified disposition
# (landed | preserved_unlanded | unknown) and returns durable per-effect
# receipts: endpoint stop, preservation ref, branch fate, provider return,
# runtime-record retirement.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"

FM_TERMINAL_QUIET_SECS="${FM_TERMINAL_QUIET_SECS:-7200}"

fm_cleanup_attempt() {  # <attempt_id> <disposition>
  local attempt=$1 disposition=$2
  local gen copy backend
  gen=$(fm_attempt_generation "$attempt") || return 1
  # under the exact attempt lock
  fm_lock_try_acquire "$(attempt_lock "$attempt")" || {
    echo "cleanup: attempt lock busy: $attempt" >&2
    return 1
  }
  copy=$(fm_attempt_load "$attempt" | jq -r '.provider.copy // ""')
  backend=$(fm_attempt_load "$attempt" | jq -r '.provider.provider // ""')
  local receipt
  # 1. endpoint stop
  receipt=$(fm_backend_stop_receipt "$backend" "$attempt") || {
    echo "cleanup: endpoint stop failed/unknown; preserving $attempt" >&2
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  fm_attempt_write_receipt "$attempt" "$gen" cleanup.endpoint "$receipt" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  # 2. preservation ref for preserved_unlanded only
  if [ "$disposition" = preserved_unlanded ]; then
    git -C "$copy" update-ref "refs/fm-preserve/$attempt" HEAD \
      || echo "cleanup: preservation ref failed for $attempt" >&2
  fi
  # 3. branch fate: record, never suppress
  local fate
  fate=$(branch_fate_json "$copy" "$attempt") || fate='{"failed":true}'
  fm_attempt_write_receipt "$attempt" "$gen" cleanup.branch "$fate" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  # 4. provider return
  if ! provider_return "$backend" "$copy" "$attempt"; then
    echo "cleanup: provider return failed; copy preserved for $attempt" >&2
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  fi
  fm_attempt_write_receipt "$attempt" "$gen" cleanup.provider \
    "{\"provider\":\"$backend\",\"returned\":true,\"copy\":\"$copy\"}" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  # 5. runtime-record retirement (busy state retire, pr-poll artifacts, and
  #    the state/<id>.* files - the exact removals fm-teardown.sh performs
  #    today, moved here)
  retire_runtime_records "$attempt" || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  fm_attempt_write_receipt "$attempt" "$gen" cleanup.runtime \
    '{"records_removed":true}' || {
    fm_lock_release "$(attempt_lock "$attempt")"
    return 1
  }
  fm_lock_release "$(attempt_lock "$attempt")"
  echo "cleanup: $attempt disposition=$disposition complete"
}
```

`branch_fate_json`, `provider_return`, and `retire_runtime_records` are extracted verbatim from the existing `bin/fm-teardown.sh` functions: `teardown_treehouse_return` (line 996), `work_is_landed`/`pr_number_from_branch` (lines 824/699), `retire_busy_state` (line 606), `remove_pr_poll_artifacts` (line 677), and the final state-file removal block at the end of the main flow. The extraction keeps every current safety check (dirty refusal, landed-work proofs, provider-specific quiet, herdr endpoint-confirmed-gone, orca worktree path match) intact; it only changes where the code lives. `fm_cleanup_attempt` refuses under `unknown` disposition and under any live-process, dirty, quiet, identity-mismatch, or receipt-conflict condition, preserving the attempt and resources for reconciliation.

Append a thin CLI to the library so tests and the teardown wrapper can drive it without sourcing:

```bash
if [ "${1:-}" = "--run" ]; then
  fm_cleanup_attempt "$2" "$3"
  exit $?
fi
```

`branch_fate_json` honors the `FM_BRANCH_DELETE_FAIL=1` test hook (records `{"failed":true}` without touching a real ref) so the branch-disposition-failure fixture stays hermetic.

- [ ] **Step 4: Convert `bin/fm-teardown.sh` into the compatibility wrapper**

Replace the main flow of `bin/fm-teardown.sh` so that after it resolves the task to an attempt and classifies the disposition through its existing landed-work proofs (`work_is_landed`, PR-discovery fallback, stale-lock recovery), it calls `fm_cleanup_attempt "$attempt" "$disposition"` and exits with that result. The CLI stays `fm-teardown.sh <task-id> [--force]`; `--force` semantics (discard authority) are resolved into a `preserved_unlanded`-with-discard disposition exactly as today, and the wrapper adds no second cleanup policy. The header's landed-work proofs and stale-lock recovery procedure remain authoritative and unchanged.

- [ ] **Step 5: Verify**

Run: `bash tests/fm-cleanup.test.sh; bash tests/fm-teardown.test.sh; bash tests/fm-teardown-endpoint-safety.test.sh; bash tests/fm-secondmate-safety.test.sh`
Expected: all green, including the pre-existing teardown suites (the wrapper must be byte-behavior-identical for the ordinary path).

- [ ] **Step 6: Commit**

```bash
git add bin/fm-cleanup-lib.sh tests/fm-cleanup.test.sh bin/fm-teardown.sh
git add tests/fm-teardown.test.sh tests/fm-teardown-endpoint-safety.test.sh
git commit -m "refactor(cleanup): one structured cleanup operation shared by teardown and terminal"
```

---

## Task 9: Ordered terminal orchestration

Decision OS Task 7.5 leaf plus the design's ordered terminal composition.

**Files:**

- Create: `bin/fm-terminal.sh`
- Create: `tests/fm-terminal.test.sh`
- Modify: `bin/fm-teardown.sh` (no-op; the wrapper already routes through cleanup)

- [ ] **Step 1: Write the failing tests**

Create `tests/fm-terminal.test.sh` with crash injection after every receipt, replay convergence, closed-unmerged preservation, unknown-forge refusal of destructive cleanup, dirty/later-work preservation, tracker-failure obligation retention, immature quiet preservation and later maturity removal, and exact branch-fate recording. The shared fixture helper builds a fully landed attempt:

```bash
setup_terminal_attempt() {  # -> prints a fully landed attempt id (claim+launch+landing receipts)
  local aid
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-t holu) || fail "alloc"
  fm_attempt_freeze_allocation "$aid" 1 "{\"provider\":\"tmux\",\"copy\":\"$TMP_ROOT/wt-t\"}" \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_write_receipt "$aid" 1 launch '{"endpoint":"w-t"}' || fail "launch"
  fm_attempt_write_receipt "$aid" 1 landing '{"disposition":"landed","pr":"https://github.com/kunchenguid/firstmate/pull/1"}' \
    || fail "landing"
  printf '%s\n' "$aid"
}

test_crash_after_each_receipt_replays_converged() {
  local baseline point out rerun
  baseline=$(setup_terminal_attempt)   # helper that builds a fully landed fixture
  # crash-free run establishes the converged record
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$baseline" >/dev/null 2>&1 || true
  local ref_file baseline_json
  baseline_json="$STATE/attempts/$baseline.json"
  cp "$baseline_json" "$TMP_ROOT/baseline.json"
  for point in claim launch closure cleanup retirement; do
    local aid
    aid=$(setup_terminal_attempt)
    FM_STATE_OVERRIDE="$STATE" FM_TERMINAL_CRASH_AFTER="$point" \
      "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 || true
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 || true
    cmp -s "$TMP_ROOT/baseline.json" "$STATE/attempts/$aid.json" \
      || fail "replay after $point did not converge"
  done
  pass "replay after every irreversible effect converges"
}

test_unknown_forge_state_refuses_destructive_cleanup() {
  # forge reports unknown: terminal must preserve the attempt and resources
  # and name the reconciliation need
  out=$(FM_TERMINAL_FORGE=unknown "$ROOT/bin/fm-terminal.sh" "$attempt" 2>&1)
  assert_contains "$out" "reconciliation" "unknown forge did not stop with ownership preserved"
  jq -e '.phase != "retired"' "$ATTEMPT" >/dev/null || fail "unknown forge retired the attempt"
  pass "unknown forge state refuses destructive cleanup and preserves ownership"
}

test_immature_quiet_preserves_copy_then_matures() {
  out=$(FM_TERMINAL_QUIET_SECS=100000 "$ROOT/bin/fm-terminal.sh" "$attempt" 2>&1)
  assert_contains "$out" "quiet" "immature quiet did not preserve the copy"
  out=$(FM_TERMINAL_QUIET_SECS=0 "$ROOT/bin/fm-terminal.sh" "$attempt" 2>&1)
  assert_contains "$out" "cleanup:" "mature replay did not remove the copy"
  pass "immature quiet preserves the copy; a later replay removes it only after maturity"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-terminal.test.sh`
Expected: FAIL with `fm-terminal.sh: No such file`.

- [ ] **Step 3: Implement `bin/fm-terminal.sh`**

```bash
#!/usr/bin/env bash
# Sole Firstmate attempt-to-terminal orchestrator. Owns no branch,
# provider-copy, or runtime cleanup implementation of its own: it composes
# fm-cleanup-lib.sh and requests tracker mutations through fm-br-receipt.sh.
# Implements the design's ordered terminal composition under the exact
# attempt lock.
set -u
FM_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=bin/fm-attempt-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-attempt-lib.sh"
# shellcheck source=bin/fm-cleanup-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-cleanup-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-lib.sh"

# classify_disposition: re-reads the exact Task 7 landing evidence (forge
# state, git branch state, worker status, bead state) and prints
# landed | preserved_unlanded | unknown; never infers landing from output
# paths or mtimes. When the landing receipt already exists (Task 7 wrote it),
# its disposition is authoritative.
classify_disposition() {  # <attempt_id>
  local attempt=$1 existing
  existing=$(fm_attempt_load "$attempt" | jq -r '.receipts.landing.evidence.disposition // empty')
  [ -n "$existing" ] && { printf '%s\n' "$existing"; return 0; }
  local bead pr merged
  bead=$(fm_attempt_load "$attempt" | jq -r '.envelope.task_key')
  pr=$(fm_attempt_load "$attempt" | jq -r '.receipts.landing.evidence.pr // empty')
  if [ -n "$pr" ]; then
    merged=$(cd "${FM_REFILL_PROJECT:-/home/holu/decision-os}" && br show "$bead" --json 2>/dev/null \
      | jq -r 'if .status == "closed" and (.state // .closure_reason // "") != "unmerged" then "landed" else "preserved_unlanded" end')
    printf '%s\n' "$merged"
    return 0
  fi
  printf '%s\n' unknown
}

# current_session_authority: prints the operative current-session authority
# (the same value fm-spawn.sh records at intake) or fails when absent.
current_session_authority() {  # -> authority text
  local f
  f="${FM_STATE_OVERRIDE:-$FM_HOME/state}/attempts/$attempt.request.claim.json"
  [ -f "$f" ] && jq -r '.authority' "$f" || return 1
}

# build_tracker_request: emits one fm-tracker-request.v1 JSON object for the
# given transition with the expected prior state and the registered clone's
# current .beads/issues.jsonl sha256.
build_tracker_request() {  # <attempt_id> <generation> <bead_id> <transition> <authority>
  local repo hash
  repo="${FM_REFILL_PROJECT:-/home/holu/decision-os}"
  hash=$(sha256sum "$repo/.beads/issues.jsonl" | cut -d' ' -f1)
  jq -n --arg attempt_id "$1" --argjson generation "$2" --arg bead_id "$3" \
    --arg transition "$4" --arg authority "$5" --arg repo "$repo" \
    --arg agent "${BR_AGENT_NAME:-}" --arg hash "$hash" \
    '{attempt_id:$attempt_id,generation:$generation,bead_id:$bead_id,transition:$transition,expected_state:"open",expected_source_hash:$hash,evidence:"terminal",authority:$authority,agent:$agent,repo:$repo}'
}

attempt=$1
gen=$(fm_attempt_generation "$attempt") || exit 1

# 1. verify the immutable attempt, generation, home, bead binding, live bead,
#    and owned provider identity
bead=$(fm_attempt_load "$attempt" | jq -r '.envelope.task_key')
(cd "${FM_REFILL_PROJECT:-/home/holu/decision-os}" && br show "$bead" --json 2>/dev/null) \
  | jq -e '.id == "'"$bead"'"' >/dev/null || {
  echo "terminal: live bead verification failed for $attempt; preserving ownership" >&2
  exit 1
}

# 2. re-read worker, endpoint, Git, forge, and bead facts and classify the
#    exact delivery: landed | preserved_unlanded | unknown
disp=$(classify_disposition "$attempt")   # exact re-use of Task 7 landing logic
[ -n "$disp" ] || { echo "terminal: unknown disposition for $attempt" >&2; exit 1; }

# 3. obtain any required authority and bind only the evidence needed for the
#    disposition or an irreversible effect into the matching receipt request
authority=$(current_session_authority) || {
  echo "terminal: missing authority for $attempt" >&2
  exit 1
}

# 4. for truthful landed delivery only, request the Closure-Receipt and
#    canonical bead closure through the attended steward, then verify the
#    current-generation tracker receipt
if [ "$disp" = landed ]; then
  req=$(build_tracker_request "$attempt" "$gen" "$bead" close "$authority")
  echo "$req" > "${FM_STATE_OVERRIDE:-$FM_HOME/state}/attempts/$attempt.request.close.json"
  fm-br-receipt.sh "${FM_STATE_OVERRIDE:-$FM_HOME/state}/attempts/$attempt.request.close.json" \
    || { echo "terminal: tracker receipt pending for $attempt" >&2; exit 1; }
fi

# 5. preserved_unlanded: preserve or release the physical copy only according
#    to the authoritative bead transition and exact recovery-ref evidence;
#    never report product success
# 6. unknown / missing authority / dirty or later work / live processes /
#    identity mismatch / insufficient quiet / conflicting receipts: preserve
#    the attempt and resources for reconciliation
# 7. when lawful, invoke the one structured cleanup operation and verify its
#    endpoint, preservation, branch-fate, provider-return, and runtime-
#    retirement receipts
fm_cleanup_attempt "$attempt" "$disp" || {
  echo "terminal: cleanup did not complete for $attempt" >&2
  exit 1
}

# 8. still under the attempt lock, atomically publish the terminal audit
#    receipt and mark the live attempt retired
fm_attempt_retire "$attempt" "$gen" \
  "$(jq -n --arg disp "$disp" --arg authority "$authority" '{audit:"terminal",disposition:$disp,authority:$authority}')" \
  || exit 1

# 9. after releasing the lock, obtain a fresh shared capacity projection and
#    permit refill only from that canonical observation
cap=$(fm_capacity_project)
echo "terminal: $attempt disposition=$disp retired"
echo "$cap" | jq -r '.aggregate | "post-terminal capacity: productive=\(.productive_count) reserved=\(.reserved_ownership_count) refill_safe=\(.refill_safe)"'
```

The Task 7.5 required order is preserved inside steps 2-8: observe forge/tracker/branch/endpoint/copy claim, persist the observation, obtain disposition authority, run teardown eligibility checks, persist the exact tracker-mutation request, wait while the attended steward executes it, observe and verify the authoritative tracker receipt, record the exact copy's no-live-process/clean/landed/nonzero-quiet evidence, clean or release that exact copy only when all four signals pass, retire the exact proven delivery ref, and remove runtime ownership only after all obligations are complete. `fm-terminal.sh` never mutates the tracker directly; a pending tracker receipt, quiet interval, or obligation blocks copy/ref/runtime release, and replay resumes at the persisted request/receipt boundary. A duplicate completion, merge event, startup recovery, heartbeat recovery, cleanup retry, or refill race converges on the same receipts and sees either pre-retirement ownership or a post-retirement deficit, never an intermediate free slot.

- [ ] **Step 4: Verify**

Run: `bash tests/fm-terminal.test.sh; bash tests/fm-cleanup.test.sh; bash tests/fm-teardown.test.sh; bash tests/fm-teardown-endpoint-safety.test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-terminal.sh tests/fm-terminal.test.sh
git commit -m "feat(terminal): reconcile delivery attempts in order"
```

---

## Task 10: Atomic retirement, refill admission, and the automatic-refill gate

Retirement already blocks projection (Task 2); this task adds the refill action that acts only on a fresh, complete projection, the admission contract, and the automatic-refill gate.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (refill action and admission)
- Create: `tests/fm-refill-admission.test.sh`
- Extend: `tests/fm-capacity.test.sh` (retirement-before-projection and no-decrement-at-completion fixtures)

- [ ] **Step 1: Write the failing tests**

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
  local aid out
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-h holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-h"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main"}' || fail "freeze"
  fm_attempt_write_receipt "$aid" 1 launch '{"endpoint":"w-h"}' || fail "launch"
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\n' "$aid" > "$STATE/task-h.meta"
  cat > "$CANDIDATES" <<'JSON'
[{"id":"dos-h-a","planned_path":"docs/"},{"id":"dos-h-b","planned_path":"src/engine"}]
JSON
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_CANDIDATES_FILE="$CANDIDATES" \
    FM_REFILL_CURRENT_PATHS="src/engine" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "admit dos-h-a" "A not admitted"
  assert_contains "$out" "serialize dos-h-b" "B not serialized on concrete conflict"
  pass "provisional planned-path admission serializes only on concrete conflict"
}

test_no_duplicate_dispatch_on_concurrent_refill() {
  local out
  # two concurrent --refill invocations; the home lock admits one wave
  (FM_STATE_OVERRIDE="$STATE" FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill >/dev/null 2>&1) &
  (FM_STATE_OVERRIDE="$STATE" FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill >/dev/null 2>&1) &
  wait
  [ "$(grep -c '^launch ' "$DISPATCH_LOG" 2>/dev/null || echo 0)" -le 1 ] \
    || fail "duplicate dispatch"
  pass "concurrent refill invocations serialize and never double-dispatch"
}

test_completion_or_merge_alone_never_decrements_capacity() {
  local before after
  before=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  # a done status line and a merged PR pointer without any retirement
  printf 'done: PR https://github.com/kunchenguid/firstmate/pull/1 checks green\n' \
    > "$STATE/task-i.status"
  after=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  [ "$(echo "$before" | jq '.aggregate.reserved_ownership_count')" = \
    "$(echo "$after" | jq '.aggregate.reserved_ownership_count')" ] \
    || fail "merge event decremented capacity"
  pass "a completion notification or merge event never decrements capacity directly"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-refill-admission.test.sh`
Expected: FAIL with `--refill` unrecognized.

- [ ] **Step 3: Implement the refill action in `bin/fm-fleet-refill.sh`**

Add to the rewritten script:

```bash
if [ "${1:-}" = "--refill" ]; then
  cap=$(fm_capacity_project)
  echo "$cap" | jq -e '.aggregate.refill_safe == true' >/dev/null || {
    echo "REFILL-UNSAFE: no automatic or attended refill on an unsafe projection" >&2
    exit 1
  }
  echo "$cap" | jq -e --argjson t "$FM_REFILL_TARGET_PRODUCTIVE" \
    --argjson c "$FM_REFILL_RESERVED_CEILING" \
    '.aggregate.productive_count < $t and .aggregate.reserved_ownership_count < $c' >/dev/null || {
    echo "fleet-ok: no refill needed"
    exit 0
  }
  fm_refill_admit_and_dispatch "$cap"   # Task 10 admission below
  exit $?
fi
```

`fm_refill_admit_and_dispatch`:

1. Queries the live beads graph for work that is open, ready, unclaimed, dependency-safe, and high enough priority (`br ready --json` then `br show <id> --json` per candidate to re-verify those facts while creating the claim request). For hermetic admission tests the candidate query is overridable with `FM_REFILL_CANDIDATES_FILE` (a JSON array of `{id, planned_path}`) and the current attempts' declared planned paths with `FM_REFILL_CURRENT_PATHS` (a space-separated list); production reads the live graph and the current attempts' `delivery` records.
2. Re-verifies each fact at claim time and applies the accepted Decision OS admission contract: checks provisional planned paths, known exclusive seams, shared mutable state, and semantic dependencies against current attempts; serializes only when that bounded admission evidence identifies a concrete conflict; no `.beadscope`, declaration registry, write-set enforcer, or claim inferred from planned paths is introduced.
3. Wins the home lock (`state/.lock.acquire` through `bin/fm-lock.sh`) plus the attempt allocation lock, then re-reads bead ownership after winning the lock.
4. For each admitted candidate, runs the Task 5 split handshake (claim request, `fm-br-receipt.sh`, then `fm-spawn.sh` resume path) so the actual diff remains the authoritative pre-land overlap check at landing time through the existing `bin/fm-review-diff.sh` path.
5. Prints the exact dispatch commands for the attended path (the `br show` verification plus the launch command per worker).

The automatic-refill gate: `bin/fm-fleet-refill.sh` acts automatically only when `config/refill-auto` exists in the home (gitignored) or `FM_REFILL_AUTO=1` is set; otherwise `--refill` requires an explicit attended flag and the human path prints the verdict plus next-wave commands without launching. Automatic refill stays disabled through Task 12 and is enabled only after the safety gate in Task 12 Step 5.

- [ ] **Step 4: Verify**

Run: `bash tests/fm-refill-admission.test.sh; bash tests/fm-capacity.test.sh; bash tests/fm-fleet-refill.test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-fleet-refill.sh tests/fm-refill-admission.test.sh tests/fm-capacity.test.sh
git commit -m "feat(refill): retirement-before-projection admission with automatic-refill gate"
```

---

## Task 11: Recover and expose current attempt state

Decision OS Task 7.6 leaf.

**Files:**

- Modify: `bin/fm-session-start.sh`
- Modify: `bin/fm-watch.sh`
- Modify: `bin/fm-fleet-snapshot.sh`
- Extend: `tests/fm-session-start.test.sh`, `tests/fm-watch-triage.test.sh`, `tests/fm-fleet-snapshot-view.test.sh`

- [ ] **Step 1: Write the failing tests**

Extend `tests/fm-session-start.test.sh` with a fixture home containing an attempt at `claim_pending` (a pending obligation) and assert the digest's fleet-state section names the attempt phase, generation, reconciliation need, and obligations. Extend `tests/fm-watch-triage.test.sh` with a heartbeat-path fixture that surfaces a `reconciliation_required` attempt through the existing fleet-scan (no new wake type). Extend `tests/fm-fleet-snapshot-view.test.sh` with the attempt-phase exposure per task row.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-session-start.test.sh; bash tests/fm-watch-triage.test.sh; bash tests/fm-fleet-snapshot-view.test.sh`
Expected: FAIL on the new assertions.

- [ ] **Step 3: Implement**

In `bin/fm-session-start.sh` fleet-state section: for each `state/<id>.meta` carrying `attempt=`, emit a bounded line with attempt phase and generation, intended exit versus crash (derived from the attempt record's receipts, not the status log), reconciliation need, and named obligations, sourced from `fm_attempt_lib.sh` read functions. This is an additional digest line per task; the existing status tails stay.

In `bin/fm-watch.sh`: extend the existing heartbeat fleet-scan classification so an attempt whose projection row carries `reconciliation_required` surfaces one bounded wake through the normal heartbeat path (reusing the existing queue and classification machinery; no new wake type or daemon). The away-mode daemon's heartbeat review additionally invokes `bin/fm-refill-sentinel.sh` at its cadence.

In `bin/fm-fleet-snapshot.sh`: each `tasks[]` row already embeds `current_state`; add `attempt:` fields (phase, generation, reconciliation, obligations) from the attempt record when present.

Pending obligations are exposed and retried idempotently through these existing session-start, heartbeat, and fleet-snapshot paths: a `state/attempts/<attempt>.obligation.*.json` record is retried by the same paths that own the wait (startup network stage for claim_pending, heartbeat for tracker/cleanup pending), never by a new loop.

- [ ] **Step 4: Verify**

Run: `bash tests/fm-session-start.test.sh; bash tests/fm-watch-triage.test.sh; bash tests/fm-fleet-snapshot-view.test.sh; bash tests/fm-attempt.test.sh; bash tests/fm-capacity.test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-session-start.sh bin/fm-watch.sh bin/fm-fleet-snapshot.sh
git add tests/fm-session-start.test.sh tests/fm-watch-triage.test.sh tests/fm-fleet-snapshot-view.test.sh
git commit -m "feat(fleet): expose and recover delivery attempts"
```

---

## Task 12: Consumer switchover, fixture and live parity, latency budget, and the automatic-refill safety gate

Both consumers switch to the shared object only after fixture and live parity; automatic refill starts only after safety tests pass.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (enable automatic refill)
- Modify: `bin/fm-fleet-snapshot.sh` (switch is already done in Task 3; verify)
- Modify: `docs/verification/fleet-capacity.md` (final parity + latency + safety evidence)
- Modify: `docs/documentation-audiences.json` (classify `docs/verification/fleet-capacity.md` as `maintainer-verification`)
- Extend: `tests/fm-capacity.test.sh` (composition fixtures), `tests/fm-fleet-snapshot-view.test.sh` (byte parity)

- [ ] **Step 1: Write the failing composition tests**

Append to `tests/fm-capacity.test.sh`:

```bash
test_composition_byte_parity_across_consumers() {
  # one source object: --count-json, snapshot embed, human summary numbers,
  # and sentinel digest must all derive byte-identical rows/aggregates
  local src cap snap human
  src=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  cap=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-capacity-lib.sh" 2>/dev/null || true)
  snap=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null)
  [ "$(echo "$src" | jq -c '.rows')" = "$(echo "$snap" | jq -c '.capacity.rows')" ] \
    || fail "snapshot rows differ from --count-json"
  [ "$(echo "$src" | jq -c '.aggregate')" = "$(echo "$snap" | jq -c '.capacity.aggregate')" ] \
    || fail "snapshot aggregate differs"
  pass "composition fixtures prove byte-equivalent capacity rows and aggregates"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-capacity.test.sh`
Expected: FAIL on the composition test until the snapshot embed from Task 3 is present (it will already pass by then; if so, mark this step as a regression pin and move on).

- [ ] **Step 3: Run live parity on the real home**

On the real home, with the fleet at rest:

```bash
bin/fm-fleet-refill.sh --count-json > /tmp/cap-before.json
bin/fm-fleet-snapshot.sh --json | jq '.capacity' > /tmp/cap-snap.json
jq -S . /tmp/cap-before.json > /tmp/a.json
jq -S . /tmp/cap-snap.json > /tmp/b.json
diff /tmp/a.json /tmp/b.json && echo "LIVE-PARITY-OK"
```

Expected: `LIVE-PARITY-OK`. Record the exact command output and the date in `docs/verification/fleet-capacity.md` under `## Live parity`.

- [ ] **Step 4: Record final latency against the budget**

```bash
/usr/bin/time -f 'count-json wall=%e s' bin/fm-fleet-refill.sh --count-json >/dev/null
```

Expected: wall below 2000 ms. Record it in `docs/verification/fleet-capacity.md` under `## Latency (final)`, with the branch commit, date, fleet size, and the exact output. The latency budget must hold at the target fleet size before automatic refill is enabled; if it does not, stop, do not enable automatic refill, and open a follow-up to bound the per-worker or total timeout.

- [ ] **Step 5: Enable automatic refill only after safety tests pass**

Run the full safety gate:

```bash
bin/fm-test-run.sh --all
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

Expected: every test green, lint clean, doc-audience clean. Only then create `config/refill-auto` in the home (gitignored) or set `FM_REFILL_AUTO=1`; the automatic path is the same `--refill` flow under the gate from Task 10. Automatic refill emits the same human verdict lines so the attended turn still sees the outcome.

- [ ] **Step 6: Commit**

```bash
git add tests/fm-capacity.test.sh tests/fm-fleet-snapshot-view.test.sh
git add docs/verification/fleet-capacity.md docs/documentation-audiences.json
git commit -m "feat(refill): shared-object switchover after fixture and live parity"
```

---

## Task 13: Delete obsolete machinery after measured parity

Deletion happens only after the parity gates in Task 12 pass. The deletion list is explicit and each item has its test.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (delete legacy reads)
- Delete references to: `state/fleet-manifest.jsonl`, `/tmp/pi-subagents-1000/...` output reads, `ACTIVE_WINDOW_MIN`, `QUEUE_WINDOW_MIN`, `MIN_BATTERY`, `MIN_OPEN`, `br list --status open --json` open-count arithmetic, old sentinel freshness windows
- Extend: `tests/fm-fleet-refill.test.sh` (no-fallback tests)

- [ ] **Step 1: Write the failing tests**

Append to `tests/fm-fleet-refill.test.sh`:

```bash
test_legacy_manifest_and_output_mtimes_never_fallback() {
  # create a state/fleet-manifest.jsonl with fresh mtimes and a
  # /tmp/pi-subagents-1000/.../<id>.output with a fresh mtime; the projection
  # must ignore both completely
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

test_no_duplicate_capacity_counter() {
  # assert the refill script contains no second counting loop
  grep -q "ACTIVE_WINDOW_MIN\|QUEUE_WINDOW_MIN\|MIN_BATTERY\|MIN_OPEN" "$ROOT/bin/fm-fleet-refill.sh" \
    && fail "legacy counter constants survived"
  pass "no duplicated capacity counter remains"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-fleet-refill.test.sh`
Expected: FAIL while the legacy constants still exist.

- [ ] **Step 3: Delete the obsolete machinery**

From `bin/fm-fleet-refill.sh`: remove the `TASKS_DIR` and `MANIFEST` variables, the mtime loop, `ACTIVE_WINDOW_MIN`, `QUEUE_WINDOW_MIN`, `MIN_BATTERY`, `MIN_OPEN`, and the `br list --status open --json` open-count block. Keep the serialization-debt probe invocation (it is a safety gate, not capacity arithmetic). Remove the header's reference to the old sentinel freshness windows. Nothing else in the repo reads `state/fleet-manifest.jsonl` (verified by `rg -l "fleet-manifest" bin/ tests/` returning only the refill script), so the manifest file itself is left untouched in the home and simply stops being read; do not delete the file, and do not delete any unknown or unlanded work.

- [ ] **Step 4: Verify**

Run: `bash tests/fm-fleet-refill.test.sh; bash tests/fm-capacity.test.sh; bash tests/fm-refill-admission.test.sh; bash tests/fm-fleet-snapshot-view.test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-fleet-refill.sh tests/fm-fleet-refill.test.sh
git commit -m "chore(refill): delete obsolete manifest, output-mtime, and counter arithmetic after parity"
```

---

## Task 14: Rollback readiness

Rollback is a configuration flip, never a code revert that restores legacy arithmetic.

**Files:**

- Modify: `bin/fm-fleet-refill.sh` (alert-only mode)
- Modify: `bin/fm-refill-sentinel.sh` (alert-only mode)
- Extend: `tests/fm-refill-admission.test.sh`, `tests/fm-refill-sentinel.test.sh`

- [ ] **Step 1: Write the failing tests**

```bash
test_rollback_is_alert_only_and_preserves_everything() {
  # with config/refill-auto removed and FM_REFILL_AUTO=0, --refill must not
  # dispatch; both consumers stay alert-only; attempts, beads, branches, refs,
  # copies, and receipts must be untouched (byte-compare the state dir)
  local out before after
  before=$(find "$STATE" -type f -exec sha256sum {} + | sort)
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "fleet-ok" "rollback mode did not stay alert-only"
  assert_not_contains "$out" "launch " "rollback mode dispatched"
  after=$(find "$STATE" -type f -exec sha256sum {} + | sort)
  [ "$before" = "$after" ] || fail "rollback mutated the state dir"
  pass "rollback disables automatic dispatch and returns consumers to alert-only"
}

test_rollback_never_restores_legacy_arithmetic() {
  # with rollback active, missing evidence must yield ambiguous/incomplete
  # rows, never zero capacity or a free slot
  local out
  printf 'kind=ship\nmode=direct-PR\n' > "$STATE/legacy-r.meta"
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  echo "$out" | jq -e '.aggregate.refill_safe == false' >/dev/null \
    || fail "rollback invented capacity"
  pass "rollback never converts missing evidence into zero capacity"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/fm-refill-admission.test.sh; bash tests/fm-refill-sentinel.test.sh`
Expected: FAIL until the mode exists.

- [ ] **Step 3: Implement the rollback flip**

In both `bin/fm-fleet-refill.sh` and `bin/fm-refill-sentinel.sh`: when `config/refill-auto` is absent and `FM_REFILL_AUTO` is not `1`, the scripts print the verdict and alert lines but never dispatch or launch (`--refill` exits 0 with `fleet-ok: alert-only` after printing the same summary). All attempts, beads, branches, refs, copies, and receipts are preserved; nothing is deleted or rewritten. Forward recovery resumes from persisted effect receipts: re-enabling the gate re-runs the same idempotent paths (claim replay, obligation retry, terminal reconciliation) from the receipts already on disk. The projection continues to report ambiguity and reconciliation needs exactly as before; missing evidence never becomes zero capacity.

- [ ] **Step 4: Verify**

Run: `bash tests/fm-refill-admission.test.sh; bash tests/fm-refill-sentinel.test.sh; bash tests/fm-capacity.test.sh; bash tests/fm-attempt.test.sh`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add bin/fm-fleet-refill.sh bin/fm-refill-sentinel.sh
git add tests/fm-refill-admission.test.sh tests/fm-refill-sentinel.test.sh
git commit -m "feat(refill): alert-only rollback that preserves attempts and never restores legacy arithmetic"
```

---

## Task 15: Final acceptance review and verification record

**Files:**

- Modify: `docs/verification/fleet-capacity.md` (final acceptance evidence)
- Modify: `docs/documentation-audiences.json` (already classified in Task 12; verify)
- No new runtime files.

- [ ] **Step 1: Run the full acceptance gate**

```bash
bin/fm-test-run.sh --all
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

Expected: every test green, lint clean, doc-audience clean (this plan and `docs/verification/fleet-capacity.md` are classified).

- [ ] **Step 2: Verify no duplicate machinery**

```bash
grep -rn "productive_count\|reserved_ownership_count" bin/ | grep -v "fm-capacity-lib.sh" | grep -v "fm-fleet-refill.sh\|fm-fleet-snapshot.sh\|fm-refill-sentinel.sh\|fm-terminal.sh"
```

Expected: no output (the aggregate counters appear only in the one classifier and its consumers). Then grep for the forbidden shapes:

```bash
grep -rn "ACTIVE_WINDOW_MIN\|QUEUE_WINDOW_MIN\|MIN_BATTERY\|MIN_OPEN\|fleet-manifest" bin/ tests/
```

Expected: no output. The branch diff must show no duplicate parser, tracker, phase machine, cleanup policy, counter, daemon, scheduler, wrapper layer, or control plane.

- [ ] **Step 3: Final self-review against every accepted design requirement**

Walk `docs/architecture.md` section "Durable implementation capacity and attempt lifecycle design" and confirm each requirement maps to a task:

- One attended dispatch/refill invocation: Tasks 5, 10.
- Automatic terminal reconciliation and refill: Tasks 9, 10, 12.
- No new scheduler, daemon, dashboard, wrapper, parser, phase machine, duplicate counter: Tasks 2, 3, 8, 15 (negative assertions).
- One shared capacity classifier: Task 2; consumers: Tasks 3, 11.
- One structured cleanup operation used by terminal orchestration and existing cleanup: Task 8.
- Immutable minimal attempt envelopes: Task 1.
- Generation-bound effect receipts: Task 1.
- Claim-before-allocation: Task 5.
- Retirement-before-capacity projection: Tasks 2, 10.
- Provisional planned-path admission with actual diffs authoritative before landing: Task 10, Task 7.
- Full branch and isolated-copy lifecycle (admission, creation, delivery, merge or authorized local landing, Closure-Receipt and close, branch disposition, preservation refs for unlanded work, cleanup refusal, provider return, runtime retirement, automatic refill only after atomic retirement): Tasks 5, 6, 7, 8, 9, 10.
- Obsolete manifests, frozen output paths, duplicated counters, legacy compatibility reads, old sentinel arithmetic deleted only after measured parity: Tasks 12, 13.
- Never discard unknown or unlanded work: Tasks 4, 8, 9 (refusal fixtures).
- Representative latency measurement: Tasks 3, 12.
- Fixture parity: Task 12.
- Supported provider/runtime coverage: Tasks 6, 8, 9.
- Crash/replay tests around every irreversible effect: Tasks 5, 7, 9.
- Concurrency tests: Tasks 1, 5, 10.
- Migration: Task 0, Task 4.
- Rollback to alert-only: Task 14.
- Exact verification commands: every task's Verify step plus this one.

- [ ] **Step 4: Fix any material finding and commit**

If the review pass (the separate canonical `review.sh` pass run by firstmate before implementation) or this self-review finds a material design correction, fix the design owner `docs/architecture.md` in one follow-up commit and re-run Step 1. Otherwise record the acceptance evidence in `docs/verification/fleet-capacity.md` under `## Acceptance` (date, commit, commands, output) and commit:

```bash
git add docs/verification/fleet-capacity.md
git commit -m "docs(verification): record fleet-capacity acceptance evidence"
```

---

## Execution handoff

The approved next step is one separate canonical `review.sh` pass over this plan, followed by correction of material findings, then implementation. The captain is not asked to choose an execution mode. Implementation uses superpowers:subagent-driven-development (fresh subagent per task with review between tasks) or superpowers:executing-plans (batched checkpoints); the plan's tasks are ordered so each lands on a green baseline and each commit is small and self-contained.

## Plan document classification

This plan is a tracked markdown file in the firstmate repository. `bin/fm-doc-audience-check.sh` requires every tracked `.md` to be classified in `docs/documentation-audiences.json`. The plan's own commit therefore adds one surface entry: path `docs/superpowers/plans/2026-08-08-fleet-refill-terminal-lifecycle.md`, audience `maintainer-architecture`. The `docs/verification/fleet-capacity.md` entry (audience `maintainer-verification`) ships with Task 12.
