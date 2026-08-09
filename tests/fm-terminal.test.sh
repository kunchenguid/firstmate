#!/usr/bin/env bash
# Public-interface tests for the ordered attempt-to-terminal orchestrator
# (bin/fm-terminal.sh): one outer non-reentrant attempt lock spans steps 1-8
# and releases before the fresh step-9 projection; a crash at every receipt
# boundary replays to a semantically equivalent record; a concurrent terminal
# run and refill projection never observe an intermediate free slot; unknown
# forge state, a stale claim-only closure authority, an immature quiet
# interval, and a pre-land actual-diff conflict all refuse before any
# destructive effect.
#
# Every external owner is faked; the fixture never touches the real
# decision-os tracker, the real gh/br CLIs, or the real treehouse. A fake gh
# reports the forge MERGED (landed); a fake br answers `show` with the live
# open bead; a fake treehouse accepts the provider return; and the fake
# attended steward (FM_BR_RECEIPT_BIN) observes the tracker receipt through
# the LOCK-HELD primitive: the terminal holds the attempt lock throughout the
# steward step, and the public observe wrapper is non-reentrant, so it would
# refuse inside the outer lock exactly as a subprocess reacquire must.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The fake attended steward and other fixture subprocesses need ROOT in their
# environment (lib.sh sets it but does not export it).
export ROOT

TMP_ROOT=$(fm_test_tmproot fm-terminal)
STATE="$TMP_ROOT/state"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$PROJECT/.beads"

# shellcheck source=bin/fm-attempt-lib.sh
. "$ROOT/bin/fm-attempt-lib.sh"

# Fixture tracker source file: the close-request hash reads it; the fake
# steward never mutates it.
printf '%s\n' '{"id":"dos-t","status":"open"}' > "$PROJECT/.beads/issues.jsonl"

# --- fake external owners ---------------------------------------------------

# fake gh: the forge reports the PR merged, so fm_disposition_live classifies
# the delivery landed
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
head=$(git -C "$FM_TEST_TERMINAL_COPY" rev-parse HEAD)
printf '%s\n' "{\"state\":\"${FM_TEST_PR_STATE:-MERGED}\",\"headRefOid\":\"$head\",\"baseRefName\":\"main\"}"
SH
chmod +x "$FAKEBIN/gh"

# fake br: live-bead verification (step 1) and the disposition's bead-state
# read answer the open-bead array shape the real br 0.2.19 emits
cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  if [ -e "$FM_STATE_OVERRIDE/tracker-closed" ]; then status=closed; else status=open; fi
  printf '[{"id":"dos-t","status":"%s"}]\n' "$status"
fi
SH
chmod +x "$FAKEBIN/br"

# fake treehouse: the structured cleanup's tmux provider return must stay
# hermetic (the real binary refuses copies it does not manage)
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = return ] || exit 1
copy=${3:-}
rm -rf -- "$copy"
SH
chmod +x "$FAKEBIN/treehouse"

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 0 ;;
  list-windows) exit 0 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/tmux"

# fake attended steward: on success it observes the tracker effect receipt
# through the lock-held primitive (the terminal holds the attempt lock for the
# whole steward step; the public wrapper is non-reentrant) and exits 0
cat > "$FAKEBIN/fm-br-receipt.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-attempt-lib.sh"
REQ=$(cat "$1")
attempt=$(echo "$REQ" | jq -r '.attempt_id')
gen=$(echo "$REQ" | jq -r '.generation')
bead=$(echo "$REQ" | jq -r '.bead_id')
if [ "${FM_TEST_STEWARD_CRASH_AFTER_MUTATION:-0}" = 1 ] \
  && [ ! -e "$FM_STATE_OVERRIDE/steward-mutation-crashed" ]; then
  printf '%s\n' '{"id":"dos-t","status":"closed"}' > "$FM_REFILL_PROJECT/.beads/issues.jsonl"
  : > "$FM_STATE_OVERRIDE/tracker-closed"
  : > "$FM_STATE_OVERRIDE/steward-mutation-crashed"
  exit 1
fi
fm_attempt_effect_observe_held "$attempt" "$gen" tracker \
  "$(jq -n --arg bead "$bead" '{bead:$bead,status:"closed"}')" || exit 1
[ "${FM_TEST_SKIP_TRACKER_CLOSE:-0}" = 1 ] || : > "$FM_STATE_OVERRIDE/tracker-closed"
echo "tracker_receipt: $attempt close $bead closed"
SH
chmod +x "$FAKEBIN/fm-br-receipt.sh"

cat > "$FAKEBIN/fm-fleet-refill.sh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --refill ] || exit 2
[ -f "${FM_CAPACITY_OBSERVATION_FILE:-}" ] || exit 3
jq -e '.schema == "fm-fleet-capacity.v1"' "$FM_CAPACITY_OBSERVATION_FILE" >/dev/null || exit 4
printf '%s\n' "$(jq -c '.aggregate' "$FM_CAPACITY_OBSERVATION_FILE")" >> "${FM_TERMINAL_REFILL_LOG:?}"
[ "${FM_TEST_REFILL_FAIL:-0}" != 1 ] || exit 9
if mkdir "${FM_STATE_OVERRIDE:?}/attempts/${FM_TERMINAL_ATTEMPT:?}.lock" 2>/dev/null; then
  rmdir "${FM_STATE_OVERRIDE:?}/attempts/${FM_TERMINAL_ATTEMPT:?}.lock"
  printf '%s\n' lock-released >> "${FM_TERMINAL_REFILL_LOG:?}"
else
  printf '%s\n' lock-held >> "${FM_TERMINAL_REFILL_LOG:?}"
  exit 5
fi
SH
chmod +x "$FAKEBIN/fm-fleet-refill.sh"

# fake crew-state: the shared capacity projection (terminal step 9 and the
# concurrent refill samples) needs a fast, deterministic fm-crew-state.v1 read
FAKE_CREW="$FAKEBIN/fm-crew-state.sh"
cat > "$FAKE_CREW" <<'SH'
#!/usr/bin/env bash
id="${!#}"
jq -nc --arg id "$id" '{schema:"fm-crew-state.v1",id:$id,state:"working",source:"fake",detail:"working"}'
SH
chmod +x "$FAKE_CREW"

cat > "$FAKEBIN/fm-crew-state-invalid.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-crew-state.v1","id":"wrong","state":"working","source":"fake","detail":"wrong identity"}'
SH
chmod +x "$FAKEBIN/fm-crew-state-invalid.sh"

export FM_STATE_OVERRIDE="$STATE"
export FM_REFILL_PROJECT="$PROJECT"
export FM_BR_RECEIPT_BIN="$FAKEBIN/fm-br-receipt.sh"
export FM_AUTHORITY_FILE="$STATE/authority-current.json"
export FM_TERMINAL_QUIET_SECS=0
export FM_CREW_STATE_BIN="$FAKE_CREW"
export FM_REFILL_BIN="$FAKEBIN/fm-fleet-refill.sh"
export FM_TERMINAL_REFILL_LOG="$TMP_ROOT/refill.log"
export PATH="$FAKEBIN:$PATH"
export FM_HOME="$TMP_ROOT/home-override"
export FM_TEST_TERMINAL_COPY="$TMP_ROOT/wt-t"

# A ship meta named after the envelope task_key (with no attempt= binding) keeps
# the retired attempt visible to the shared capacity projection: the capacity
# row reads kind=ship and the attempt record (which outlives the meta), while
# the structured cleanup, which resolves task ids by scanning for attempt=<id>,
# never removes a meta that does not bind the attempt.
printf 'kind=ship\nmode=direct-PR\n' > "$STATE/dos-t.meta"

# The provider copy must be a real git repo so cleanup's preflight dirty check
# and branch-fate evidence behave deterministically on every replay. Cleanup
# detaches HEAD and deletes the current branch, so the fixture re-creates a
# named branch at HEAD each time: the branch-fate receipt is then identical
# across the baseline and every replayed attempt.
ensure_landed_copy() {
  local dir=$TMP_ROOT/wt-t
  mkdir -p "$dir"
  if [ ! -d "$dir/.git" ]; then
    fm_git_init_commit "$dir"
  fi
  git -C "$dir" checkout -q -B main 2>/dev/null || true
  if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git init -q --bare "$TMP_ROOT/terminal-remote.git"
    git -C "$dir" remote add origin "$TMP_ROOT/terminal-remote.git"
  fi
  git -C "$dir" push -q --force origin HEAD:main
  git -C "$dir" fetch -q origin main
}

setup_terminal_attempt() {  # -> prints a fully landed attempt id
  local aid gen head endpoint_id
  rm -f "$STATE/tracker-closed"
  aid=$(fm_attempt_alloc pi dos-t holu) || fail "alloc"
  gen=$(fm_attempt_generation "$aid") || fail "generation"
  fm_attempt_effect_observe "$aid" "$gen" claim '{"bead":"dos-t","status":"claimed","agent":"pi-primary"}' || fail "claim"
  fm_attempt_freeze_allocation "$aid" "$gen" "{\"provider\":\"tmux\",\"copy\":\"$TMP_ROOT/wt-t\"}" \
    '{"mode":"direct-PR","base":"main","target":"origin/main","repo_identity":"https://github.com/kunchenguid/firstmate.git","planned_path":"docs/"}' || fail "freeze"
  fm_attempt_effect_observe "$aid" "$gen" launch '{"endpoint":"w-t"}' || fail "launch"
  ensure_landed_copy
  head=$(git -C "$TMP_ROOT/wt-t" rev-parse HEAD)
  fm_attempt_observe "$aid" "$gen" forge "$(jq -nc --arg head "$head" \
    '{provider:"github",repo:"kunchenguid/firstmate",source:"dos-t",target:null,head:$head,state:"merged",before_sha:null,after_sha:null,pr:"https://github.com/kunchenguid/firstmate/pull/1"}')" \
    || fail "forge journal"
  endpoint_id="run-$aid"
  printf 'window=s:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\nattempt=%s\n' \
    "$endpoint_id" "$endpoint_id" "$TMP_ROOT/wt-t" "$TMP_ROOT/wt-t" "$aid" > "$STATE/$endpoint_id.meta"
  printf '%s\n' "{\"transition\":\"close\",\"task_key\":\"dos-t\",\"attempt_id\":\"$aid\",\"generation\":$gen,\"authority\":\"captain:merge\"}" > "$STATE/authority-current.json"
  printf '%s\n' "$aid"
}

semantic_equiv() {  # <file-a> <file-b>; receipt names/states/evidence with timestamps and attempt ids stripped
  local norm
  # attempt ids differ between the baseline and replayed attempts (each replay
  # allocates a fresh id), so evidence strings are normalized before compare
  norm='walk(if type == "object" then del(.attempt_id,.generation) elif type == "string" then (gsub("-a[0-9]+$"; "-aN") | gsub("^[0-9a-f]{40}$"; "SHA")) else . end) | [.receipts | to_entries[] | {name:.key, entries:[.value[] | {state,evidence}]}]'
  jq -S "$norm" "$1" > "$TMP_ROOT/sem-a.json"
  jq -S "$norm" "$2" > "$TMP_ROOT/sem-b.json"
  if ! cmp -s "$TMP_ROOT/sem-a.json" "$TMP_ROOT/sem-b.json"; then
    diff -u "$TMP_ROOT/sem-a.json" "$TMP_ROOT/sem-b.json" >&2 || true
    return 1
  fi
}

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
  local baseline aid point
  baseline=$(setup_terminal_attempt)
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$baseline" >/dev/null 2>&1 || true
  for point in claim launch landing closure cleanup retirement; do
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
  # intermediate free slot
  local aid out bad pid
  aid=$(setup_terminal_attempt)
  FM_TERMINAL_QUIET_SECS=0 FM_STATE_OVERRIDE="$STATE" \
    "$ROOT/bin/fm-terminal.sh" "$aid" >/dev/null 2>&1 &
  pid=$!
  bad=0
  for _ in 1 2 3 4 5; do
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
  local aid out
  aid=$(setup_terminal_attempt)
  printf '%s\n' '{"transition":"claim","task_key":"dos-t","authority":"captain:dispatch"}' > "$STATE/authority-current.json"
  out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "authority" "closure without fresh authority proceeded"
  pass "claim authorization never authorizes later bead closure or destructive cleanup"
}

test_landed_requires_confirmed_tracker_closure() {
  local aid out
  aid=$(setup_terminal_attempt)
  out=$(FM_TEST_SKIP_TRACKER_CLOSE=1 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "tracker closure is not confirmed" "landed attempt accepted only a receipt without tracker closure"
  jq -e '.receipts.cleanup == null and .receipts["cleanup.endpoint"] == null' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "cleanup ran without confirmed tracker closure"
  pass "landed cleanup requires both close authority and confirmed tracker closure"
}

test_tracker_mutation_replay_preserves_the_original_close_request() {
  local aid out request original_hash replay_hash
  aid=$(setup_terminal_attempt)
  request="$STATE/attempts/requests/$aid.close.json"
  out=$(FM_TEST_STEWARD_CRASH_AFTER_MUTATION=1 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "tracker receipt pending" "simulated post-mutation steward crash did not stop terminal"
  original_hash=$(jq -r '.expected_source_hash' "$request")
  rm -f "$STATE/authority-current.json"
  out=$("$ROOT/bin/fm-terminal.sh" "$aid" 2>&1) || fail "close-request replay failed: $out"
  replay_hash=$(jq -r '.expected_source_hash' "$request")
  [ "$original_hash" = "$replay_hash" ] || fail "terminal replaced the pre-mutation tracker hash during replay"
  fm_attempt_is_retired "$aid" || fail "replayed tracker transition did not reach retirement"
  pass "tracker recovery reuses the exact persisted pre-mutation close request"
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

test_terminal_persists_landing_without_preseed() {
  local aid out
  aid=$(setup_terminal_attempt)
  jq -e '.receipts.landing == null' "$STATE/attempts/$aid.json" >/dev/null || fail "fixture preseeded landing"
  out=$("$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  jq -e --arg worker "run-$aid" '
    .receipts.landing[0].evidence.reason == "merged-exact-pr-head"
    and .receipts.landing[0].evidence.facts.bead == {id:"dos-t",status:"open",owner:""}
    and .receipts.landing[0].evidence.facts.worker.id == $worker
    and .receipts.landing[0].evidence.facts.endpoint.backend == "tmux"
    and .receipts.landing[0].evidence.facts.endpoint.state == "missing"
  ' "$STATE/attempts/$aid.json" >/dev/null \
    || fail "terminal did not persist exact landing evidence: $out"
  pass "terminal creates the exact landing receipt under its held lock"
}

test_terminal_requires_structured_worker_evidence_before_landing() {
  local aid out
  aid=$(setup_terminal_attempt)
  out=$(FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state-invalid.sh" \
    "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "worker evidence unavailable" "invalid worker evidence did not stop terminal"
  jq -e '.receipts.landing == null and .receipts["cleanup.endpoint"] == null' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "terminal persisted effects without valid worker evidence"
  pass "terminal binds valid structured worker evidence before landing"
}

test_preserved_unlanded_needs_no_close_authority_or_tracker_closure() {
  local aid out
  aid=$(setup_terminal_attempt)
  rm -f "$STATE/authority-current.json"
  out=$(FM_TEST_PR_STATE=CLOSED "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "preserved_unlanded" "closed delivery did not retire as preserved-unlanded"
  jq -e '.receipts.landing[0].evidence.disposition == "preserved_unlanded" and (.receipts.tracker == null)' \
    "$STATE/attempts/$aid.json" >/dev/null || fail "preserved delivery required landed-only tracker work"
  pass "preserved-unlanded requires neither close authority nor tracker closure"
}

test_real_review_diff_failure_is_propagated() {
  local aid out meta
  aid=$(setup_terminal_attempt)
  for meta in "$STATE"/*.meta; do
    [ "$(sed -n 's/^attempt=//p' "$meta")" = "$aid" ] || continue
    printf 'window=s:fm-run-%s\nendpoint_task_id=run-%s\nworktree=%s\nproject=%s\nkind=ship\nmode=direct-PR\nattempt=%s\n' \
      "$aid" "$aid" "$TMP_ROOT/wt-t" "$TMP_ROOT/missing-project" "$aid" > "$meta"
  done
  out=$("$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "project for task" "real fm-review-diff failure output was swallowed"
  jq -e '.receipts["cleanup.endpoint"] == null' "$STATE/attempts/$aid.json" >/dev/null || fail "cleanup ran after review-diff refusal"
  pass "real fm-review-diff nonzero refusal propagates before cleanup"
}

test_post_retirement_refill_uses_fresh_projection_after_unlock() {
  local aid out
  aid=$(setup_terminal_attempt)
  : > "$FM_TERMINAL_REFILL_LOG"
  out=$(FM_TERMINAL_ATTEMPT="$aid" "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1) || fail "$out"
  assert_contains "$(cat "$FM_TERMINAL_REFILL_LOG")" '"productive_count":' "refill did not receive the fresh projection"
  assert_contains "$(cat "$FM_TERMINAL_REFILL_LOG")" "lock-released" "refill ran before terminal released the attempt lock"
  pass "terminal invokes refill from the exact fresh post-retirement projection after unlocking"
}

test_post_retirement_refill_failure_preserves_terminal_success() {
  # a nonzero post-retirement refill is a best-effort notification step: the
  # refusal is logged, the terminal outcome stays success, and the attempt
  # stays retired
  local aid out rc
  aid=$(setup_terminal_attempt)
  : > "$FM_TERMINAL_REFILL_LOG"
  out=$(FM_TEST_REFILL_FAIL=1 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1); rc=$?
  expect_code 0 "$rc" "refused post-retirement refill failed the terminal: $out"
  assert_contains "$out" "post-retirement refill unavailable or refused" "refill refusal was not logged"
  fm_attempt_is_retired "$aid" || fail "terminal did not retire the attempt"
  assert_contains "$(cat "$FM_TERMINAL_REFILL_LOG")" '"productive_count":' "refill did not run from the fresh projection"
  pass "a refused post-retirement refill is logged and never fails the terminal outcome"
}

test_preland_actual_diff_conflict_refuses_landing() {
  # FM_REVIEW_DIFF_CONFLICT=1 makes the existing fm-review-diff.sh path report
  # a concrete overlap with another attempt; landing must refuse and serialize
  local out
  out=$(FM_REVIEW_DIFF_CONFLICT=1 "$ROOT/bin/fm-terminal.sh" "$(setup_terminal_attempt)" 2>&1 || true)
  assert_contains "$out" "pre-land" "pre-land actual-diff conflict not enforced"
  pass "the pre-land actual-diff recheck refuses landing on a concrete overlap"
}

test_runtime_record_crash_replays_from_endpoint_receipt() {
  local aid out rc
  aid=$(setup_terminal_attempt)
  out=$(FM_CLEANUP_CRASH_AFTER_RUNTIME_REMOVE=1 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "runtime-record crash point did not stop terminal"
  [ ! -e "$STATE/run-$aid.meta" ] || fail "runtime-record crash did not remove task metadata"
  jq -e '
    ([.receipts["cleanup.endpoint"][]?
      | select(.state == "observed" and .evidence.confirmed_gone == true)] | length) == 1
    and (.receipts["cleanup.runtime"] == null)
  ' "$STATE/attempts/$aid.json" >/dev/null || fail "runtime-record crash fixture lacks the endpoint replay boundary"
  out=$("$ROOT/bin/fm-terminal.sh" "$aid" 2>&1)
  rc=$?
  expect_code 0 "$rc" "terminal should replay after runtime metadata removal: $out"
  fm_attempt_is_retired "$aid" || fail "runtime-record replay did not retire the attempt"
  jq -e '
    ([.receipts["cleanup.runtime"][]?
      | select(.state == "observed" and .evidence.confirmed_absent == true)] | length) == 1
  ' "$STATE/attempts/$aid.json" >/dev/null || fail "runtime-record replay did not publish exact absence evidence"
  pass "endpoint receipt resumes terminal after runtime metadata removal"
}

test_mismatched_endpoint_receipt_does_not_bypass_diff_gate() {
  local aid gen out
  aid=$(setup_terminal_attempt)
  gen=$(fm_attempt_generation "$aid") || fail "generation"
  fm_attempt_effect_observe "$aid" "$gen" cleanup.endpoint \
    "$(jq -nc --arg copy "$TMP_ROOT/wt-t" \
      '{backend:"tmux",endpoint:"firstmate:fm-other",task_id:"other",copy:$copy,confirmed_gone:true}')" \
    || fail "mismatched endpoint receipt fixture"
  out=$(FM_REVIEW_DIFF_CONFLICT=1 "$ROOT/bin/fm-terminal.sh" "$aid" 2>&1 || true)
  assert_contains "$out" "pre-land" "mismatched endpoint receipt bypassed the strict diff gate"
  fm_attempt_is_retired "$aid" && fail "mismatched endpoint receipt retired the attempt"
  pass "only the exact stopped endpoint receipt bypasses the unavailable diff gate"
}

test_outer_lock_spans_verification_through_retirement
test_crash_after_every_effect_replays_to_semantic_equivalence
test_concurrent_terminal_and_refill_are_deterministic
test_unknown_forge_state_refuses_destructive_cleanup
test_fresh_closure_authority_is_required
test_landed_requires_confirmed_tracker_closure
test_tracker_mutation_replay_preserves_the_original_close_request
test_immature_quiet_preserves_copy_then_matures
test_terminal_persists_landing_without_preseed
test_terminal_requires_structured_worker_evidence_before_landing
test_preserved_unlanded_needs_no_close_authority_or_tracker_closure
test_real_review_diff_failure_is_propagated
test_post_retirement_refill_uses_fresh_projection_after_unlock
test_post_retirement_refill_failure_preserves_terminal_success
test_preland_actual_diff_conflict_refuses_landing
test_runtime_record_crash_replays_from_endpoint_receipt
test_mismatched_endpoint_receipt_does_not_bypass_diff_gate
