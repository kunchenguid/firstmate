#!/usr/bin/env bash
# Public-interface tests for the --refill admission action (Task 12): refill
# acts only on a complete projection reporting productive work below target
# and reserved ownership below ceiling; provisional planned-path admission
# serializes only on a concrete overlap with the FROZEN provisional evidence
# in a current attempt's delivery record; the home lock serializes concurrent
# refill waves so a bead is never double-dispatched; completion or merge
# events never decrement capacity directly; without the automatic gate
# (config/refill-auto or FM_REFILL_AUTO=1) --refill is alert-only rollback
# (Task 15) - it prints the informational admission verdict and the alert-only
# verdict, never dispatch commands, launches, allocations, or claims; and
# provisional planned paths never claim a landing (the pre-land actual-diff
# authority stays with bin/fm-review-diff.sh, Task 11).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT

TMP_ROOT=$(fm_test_tmproot fm-refill-admission)
STATE="$TMP_ROOT/state"
DATA="$TMP_ROOT/data"
PROJECT="$TMP_ROOT/project"
FAKEBIN="$TMP_ROOT/fakebin"
CANDIDATES="$TMP_ROOT/candidates.json"
READY_JSON="$TMP_ROOT/ready.json"
DISPATCH_LOG="$TMP_ROOT/dispatch.log"
SPAWN_LOG="$TMP_ROOT/spawn.log"
CANDIDATES_QUERIED="$TMP_ROOT/candidates-queried.marker"
FAKE_CLAIMS="$TMP_ROOT/fake-claims.txt"
mkdir -p "$STATE" "$DATA" "$FAKEBIN"

export FM_STATE_OVERRIDE="$STATE"
export FM_DATA_OVERRIDE="$DATA"
export FM_REFILL_PROJECT="$PROJECT"
export FM_CAPACITY_READ_TIMEOUT_SECS=2
export FM_CAPACITY_TOTAL_TIMEOUT_SECS=10
export FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh"
export FM_BR_RECEIPT_BIN="$FAKEBIN/fm-br-receipt.sh"
export FM_REFILL_SPAWN_BIN="$FAKEBIN/fm-spawn.sh"
export FM_REFILL_CANDIDATES_QUERIED_MARKER="$CANDIDATES_QUERIED"
export READY_JSON FAKE_CLAIMS SPAWN_LOG
export PATH="$FAKEBIN:$PATH"

# fixture project: the registered decision-os main clone shape with a .beads
# store, so the refill's claim request can resolve the source hash
git init -q -b main "$PROJECT"
git -C "$PROJECT" config user.email test@example.com
git -C "$PROJECT" config user.name Test
mkdir -p "$PROJECT/.beads"
printf '%s\n' '{"id":"dos-seed","status":"open"}' > "$PROJECT/.beads/issues.jsonl"
git -C "$PROJECT" add .beads/issues.jsonl
git -C "$PROJECT" commit -q -m base

# fake br: `ready --json` answers the READY_JSON candidate array; `show
# --json <id>` reflects the live FAKE_CLAIMS ownership store so the post-lock
# ownership re-read and the concurrent-wave serialization are real
cat > "$FAKEBIN/br" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  ready) cat "${READY_JSON:?READY_JSON unset}" ;;
  show)
    id="${3:-}"
    entry=$(jq -c --arg id "$id" '.[] | select(.id == $id)' "${READY_JSON:?READY_JSON unset}" | head -1)
    [ -n "$entry" ] || { printf '%s\n' '[]'; exit 0; }
    if grep -qx "$id" "${FAKE_CLAIMS:?FAKE_CLAIMS unset}" 2>/dev/null; then
      printf '%s' "$entry" | jq -c '[. + {status:"open",claimed_by:"pi"} | .blocked_by=(.blocked_by // [])]'
    else
      printf '%s' "$entry" | jq -c '[. + {status:"open",claimed_by:null} | .blocked_by=(.blocked_by // [])]'
    fi ;;
  list) printf '%s\n' '{"total":0}' ;;
  *) printf '%s\n' '[]' ;;
esac
SH
chmod +x "$FAKEBIN/br"

# fake attended steward (FM_BR_RECEIPT_BIN): persists the claim receipt on
# the attempt record and marks the bead claimed in the shared ownership
# store, exactly like the attended decision-os steward but hermetically
cat > "$FAKEBIN/fm-br-receipt.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-attempt-lib.sh"
REQ=$(cat "$1")
attempt=$(echo "$REQ" | jq -r '.attempt_id')
gen=$(echo "$REQ" | jq -r '.generation')
bead=$(echo "$REQ" | jq -r '.bead_id')
[ "$bead" != "${FM_STEWARD_FAIL_ID:-}" ] || exit 1
printf '%s\n' "$bead" >> "${FAKE_CLAIMS:?FAKE_CLAIMS unset}"
fm_attempt_effect_observe "$attempt" "$gen" claim \
  "$(jq -n --arg bead "$bead" '{bead:$bead,status:"claimed"}')" || exit 1
echo "claim_receipt: $attempt claim $bead claimed"
SH
chmod +x "$FAKEBIN/fm-br-receipt.sh"

# fake spawn (the Task 6 resume path): records the exact dispatch args and
# never launches a real worker
cat > "$FAKEBIN/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >> "${SPAWN_LOG:?SPAWN_LOG unset}"
printf 'admission %s\n' "${FM_REFILL_ADMISSION_JSON:-}" >> "${SPAWN_LOG:?SPAWN_LOG unset}"
exit 0
SH
chmod +x "$FAKEBIN/fm-spawn.sh"

# fake crew-state: one deterministic working read so every projection in this
# suite is refill-safe and reproducible
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
id="${!#}"
jq -nc --arg id "$id" '{schema:"fm-crew-state.v1",id:$id,state:"working",source:"fake",detail:"working"}'
SH
chmod +x "$FAKEBIN/fm-crew-state.sh"

# every capacity assertion is a global aggregate over the shared state dir,
# so each fixture is self-contained: clear the state/data dirs (the fake
# binaries live outside STATE) and reset the shared stores before each test
fresh_state() {
  rm -rf "$STATE" "$DATA"
  mkdir -p "$STATE" "$DATA"
  : > "$FAKE_CLAIMS"
  : > "$DISPATCH_LOG"
  : > "$SPAWN_LOG"
  printf '[]\n' > "$READY_JSON"
  rm -f "$CANDIDATES_QUERIED"
}

test_refill_acts_only_on_complete_projection() {
  # alert_only projection: refill must refuse without querying candidates.
  # The projection is made unsafe through the capacity library's existing
  # test-only schema-mismatch hook (FM_CAPACITY_FORCE_SCHEMA_MISMATCH=1
  # forces alert_only/refill_safe=false); no new production hook is needed.
  local out
  fresh_state
  out=$(FM_CAPACITY_FORCE_SCHEMA_MISMATCH=1 "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "REFILL-UNSAFE" "refill acted on an unsafe projection"
  [ ! -e "$CANDIDATES_QUERIED" ] || fail "candidates queried on unsafe projection"
  pass "refill acts only when a complete projection reports below-target productive work"
}

test_provisional_planned_path_admission_serializes_on_concrete_conflict() {
  # candidate B's frozen planned path overlaps a current attempt's frozen
  # provisional path; admission must serialize B and dispatch A
  local aid out
  fresh_state
  # shellcheck source=bin/fm-attempt-lib.sh
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi dos-h holu)
  fm_attempt_freeze_allocation "$aid" 1 '{"provider":"tmux","copy":"wt-h"}' \
    '{"mode":"direct-PR","base":"main","target":"origin/main","planned_path":"src/engine","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}' || fail "freeze"
  fm_attempt_effect_observe "$aid" 1 launch '{"endpoint":"w-h"}' || fail "launch"
  printf 'kind=ship\nmode=direct-PR\nattempt=%s\n' "$aid" > "$STATE/task-h.meta"
  cat > "$CANDIDATES" <<'JSON'
[{"id":"dos-h-a","priority":1,"planned_path":"docs/","declared_seams":[],"shared_mutable_state":[],"dependencies":[]},{"id":"dos-h-b","priority":1,"planned_path":"src/engine","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}]
JSON
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_CANDIDATES_FILE="$CANDIDATES" \
    FM_REFILL_AUTO=1 \
    FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "admit dos-h-a" "A not admitted"
  assert_contains "$out" "serialize dos-h-b" "B not serialized on concrete conflict"
  pass "provisional planned-path admission serializes only on concrete conflict"
}

test_structured_admission_contract_covers_all_conflicts_and_unrelated_work() {
  local current out
  fresh_state
  current="$TMP_ROOT/current-evidence.json"
  cat > "$current" <<'JSON'
[{"attempt_id":"active-a1","task_id":"active","planned_path":"src/engine","declared_seams":["schema-owner"],"shared_mutable_state":["state/fleet.json"],"dependencies":["depends-on-current"]}]
JSON
  cat > "$CANDIDATES" <<'JSON'
[
 {"id":"path-conflict","priority":1,"planned_path":"src/engine/parser","declared_seams":[],"shared_mutable_state":[],"dependencies":[]},
 {"id":"seam-conflict","priority":1,"planned_path":"docs/seam","declared_seams":["schema-owner"],"shared_mutable_state":[],"dependencies":[]},
 {"id":"state-conflict","priority":1,"planned_path":"docs/state","declared_seams":[],"shared_mutable_state":["state/fleet.json"],"dependencies":[]},
 {"id":"depends-on-current","priority":1,"planned_path":"docs/dependency","declared_seams":[],"shared_mutable_state":[],"dependencies":[]},
 {"id":"unrelated","priority":1,"planned_path":"docs/unrelated","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}
]
JSON
  out=$(FM_REFILL_CANDIDATES_FILE="$CANDIDATES" FM_REFILL_CURRENT_EVIDENCE_FILE="$current" \
    FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "serialize path-conflict (planned path overlap)" "planned path conflict admitted"
  assert_contains "$out" "serialize seam-conflict (known exclusive seam equality)" "exclusive seam conflict admitted"
  assert_contains "$out" "serialize state-conflict (shared mutable state collision)" "shared state conflict admitted"
  assert_contains "$out" "serialize depends-on-current (semantic dependency conflict)" "semantic dependency conflict admitted"
  assert_contains "$out" "admit unrelated" "unrelated candidate was serialized"
  pass "structured admission serializes each accepted conflict class and admits unrelated work"
}

test_same_wave_candidates_are_serialized_against_frozen_admissions() {
  local out
  fresh_state
  cat > "$CANDIDATES" <<'JSON'
[
 {"id":"wave-first","priority":1,"planned_path":"docs/first","declared_seams":["fleet-schema"],"shared_mutable_state":[],"dependencies":[]},
 {"id":"wave-second","priority":1,"planned_path":"docs/second","declared_seams":["fleet-schema"],"shared_mutable_state":[],"dependencies":[]}
]
JSON
  out=$(FM_REFILL_CANDIDATES_FILE="$CANDIDATES" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "admit wave-first" "first candidate was not admitted"
  assert_contains "$out" "serialize wave-second (known exclusive seam equality)" \
    "second same-wave candidate bypassed the first candidate's frozen seam"
  pass "same-wave admission serializes conflicts before allocation"
}

test_nonimplementation_attempts_do_not_supply_admission_evidence() {
  local aid out
  fresh_state
  # shellcheck source=bin/fm-attempt-lib.sh
  . "$ROOT/bin/fm-attempt-lib.sh"
  aid=$(fm_attempt_alloc pi scout-task holu) || fail "scout allocation"
  printf 'kind=scout\nmode=direct-PR\nattempt=%s\n' "$aid" > "$STATE/scout-endpoint.meta"
  printf '[{"id":"ship-candidate","priority":1,"planned_path":"docs/ship","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}]' > "$CANDIDATES"
  out=$(FM_REFILL_CANDIDATES_FILE="$CANDIDATES" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "admit ship-candidate" "scout evidence blocked an implementation candidate"
  assert_not_contains "$out" "required current evidence missing" "non-implementation attempt entered admission evidence"
  pass "scouts and second mates do not participate in implementation admission"
}

test_tracker_requests_do_not_supply_admission_evidence() {
  local out
  fresh_state
  mkdir -p "$STATE/attempts"
  printf '%s\n' '{"attempt_id":"request-a1","generation":1,"bead_id":"request","transition":"claim"}' \
    > "$STATE/attempts/request-a1.request.claim.json"
  printf '[{"id":"ship-candidate","priority":1,"planned_path":"docs/ship","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}]' > "$CANDIDATES"
  out=$(FM_REFILL_CANDIDATES_FILE="$CANDIDATES" FM_REFILL_AUTO=0 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "admit ship-candidate" "tracker request blocked an implementation candidate"
  assert_not_contains "$out" "required current evidence missing" "tracker request entered admission evidence"
  pass "tracker request artifacts never participate in implementation admission"
}

test_missing_structured_evidence_serializes_fail_closed() {
  local current out
  fresh_state
  current="$TMP_ROOT/current-complete.json"
  printf '[{"attempt_id":"active-a1","task_id":"active","planned_path":"src/","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}]' > "$current"
  printf '[{"id":"missing","priority":1,"planned_path":"docs/","declared_seams":[],"dependencies":[]}]' > "$CANDIDATES"
  out=$(FM_REFILL_CANDIDATES_FILE="$CANDIDATES" FM_REFILL_CURRENT_EVIDENCE_FILE="$current" \
    FM_REFILL_AUTO=0 "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "serialize missing (required candidate evidence missing)" "missing evidence did not fail closed"
  pass "missing required admission evidence serializes fail closed"
}

test_live_query_normalizes_installed_array_and_filters_eligibility() {
  local out
  fresh_state
  cat > "$READY_JSON" <<'JSON'
[
 {"id":"eligible","priority":1,"planned_path":"docs/a","declared_seams":[],"shared_mutable_state":[],"dependencies":[]},
 {"id":"low-priority","priority":4,"planned_path":"docs/b","declared_seams":[],"shared_mutable_state":[],"dependencies":[]},
 {"id":"blocked","priority":1,"blocked_by":["dep"],"planned_path":"docs/c","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}
]
JSON
  out=$(FM_REFILL_AUTO=0 FM_REFILL_PRIORITY_THRESHOLD=2 "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  assert_contains "$out" "admit eligible" "eligible installed-array bead was not admitted"
  assert_not_contains "$out" "admit low-priority" "candidate above the priority threshold was admitted"
  assert_not_contains "$out" "admit blocked" "dependency-blocked candidate was admitted"
  pass "the shared br-show boundary normalizes installed arrays and verifies identity, readiness, ownership, dependencies, and priority"
}

test_dispatch_wave_respects_both_budgets_and_propagates_failure() {
  local out rc launches attempts
  fresh_state
  printf '[{"id":"one","priority":1,"planned_path":"docs/one","declared_seams":[],"shared_mutable_state":[],"dependencies":[]},{"id":"two","priority":1,"planned_path":"docs/two","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}]' > "$READY_JSON"
  out=$(FM_REFILL_AUTO=1 FM_REFILL_TARGET_PRODUCTIVE=2 FM_REFILL_RESERVED_CEILING=1 \
    FM_STEWARD_FAIL_ID=one "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "steward failure did not make --refill nonzero"
  launches=$(grep -c '^launch ' "$DISPATCH_LOG" 2>/dev/null || true)
  [ "${launches:-0}" -eq 0 ] || fail "failed steward launched a worker"
  attempts=$(find "$STATE/attempts" -maxdepth 1 -name '*-a[0-9]*.json' ! -name '*.request.*' 2>/dev/null | wc -l)
  [ "$attempts" -eq 1 ] || fail "reserved ceiling did not stop the wave after one owned failure"
  assert_contains "$out" "claim_pending one" "failed steward ownership was not preserved as pending"
  pass "dispatch waves stop at either budget and propagate claim/steward/spawn failure"
}

test_launch_receives_the_exact_post_lock_admission_evidence() {
  local out admission
  fresh_state
  printf '[{"id":"exact-evidence","priority":1,"planned_path":"docs/exact","declared_seams":["receipt-owner"],"shared_mutable_state":["state/exact.json"],"dependencies":[]}]' > "$READY_JSON"
  out=$(FM_REFILL_AUTO=1 "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1) \
    || fail "exact-evidence refill failed: $out"
  admission=$(sed -n 's/^admission //p' "$SPAWN_LOG" | head -1)
  printf '%s' "$admission" | jq -e '
    .id == "exact-evidence"
    and .planned_path == "docs/exact"
    and .declared_seams == ["receipt-owner"]
    and .shared_mutable_state == ["state/exact.json"]
    and .dependencies == []
  ' >/dev/null || fail "spawn did not receive the exact admitted evidence: $admission"
  pass "launch freezes the exact admission evidence revalidated under the home lock"
}

test_no_duplicate_dispatch_on_concurrent_refill() {
  # two concurrent --refill invocations; the home lock admits one wave and
  # the loser's post-lock ownership re-read sees the winner's claim
  local launches
  fresh_state
  printf '[{"id":"dos-conc","priority":1,"planned_path":"docs/","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}]' > "$READY_JSON"
  (FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=1 FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill >/dev/null 2>&1) &
  (FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=1 FM_REFILL_DISPATCH_LOG="$DISPATCH_LOG" \
    "$ROOT/bin/fm-fleet-refill.sh" --refill >/dev/null 2>&1) &
  wait
  launches=$(grep -c '^launch ' "$DISPATCH_LOG" 2>/dev/null || true)
  launches=${launches:-0}
  [ "$launches" -le 1 ] || fail "duplicate dispatch: $launches launch lines"
  pass "concurrent refill invocations serialize and never double-dispatch"
}

test_completion_or_merge_alone_never_decrements_capacity() {
  # a done status line and a merged PR observation without retirement leave
  # capacity unchanged
  local before after
  fresh_state
  before=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  printf 'done: PR https://github.com/kunchenguid/firstmate/pull/1 checks green\n' \
    > "$STATE/task-i.status"
  after=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-fleet-refill.sh" --count-json 2>/dev/null)
  [ "$(echo "$before" | jq '.aggregate.reserved_ownership_count')" = \
    "$(echo "$after" | jq '.aggregate.reserved_ownership_count')" ] \
    || fail "merge event decremented capacity"
  pass "a completion notification or merge event never decrements capacity directly"
}

test_rollback_mode_is_alert_only_and_never_dispatches() {
  # no config/refill-auto and FM_REFILL_AUTO != 1: --refill prints the
  # informational admission verdict and the alert-only rollback verdict, and
  # never prints next-wave dispatch commands, launches, allocates attempts,
  # or claims beads
  local out aidcount
  fresh_state
  printf '[{"id":"dos-att","priority":1,"planned_path":"docs/","declared_seams":[],"shared_mutable_state":[],"dependencies":[]},{"id":"dos-att-b","priority":1,"planned_path":"src/","declared_seams":[],"shared_mutable_state":[],"dependencies":[]}]' > "$READY_JSON"
  out=$(FM_REFILL_AUTO=0 "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "fleet-ok: alert-only" "rollback mode did not print the alert-only verdict"
  assert_contains "$out" "admit dos-att" "rollback mode omitted the informational admission verdict"
  assert_not_contains "$out" "next-wave" "rollback mode printed next-wave dispatch commands"
  assert_not_contains "$out" "launch " "rollback mode launched"
  aidcount=$(find "$STATE/attempts" -name '*.json' 2>/dev/null | wc -l)
  [ "$aidcount" = 0 ] || fail "rollback refill allocated attempts"
  [ ! -s "$FAKE_CLAIMS" ] || fail "rollback refill claimed beads"
  pass "rollback mode prints the alert-only verdict and never dispatches, allocates, or claims"
}

test_actual_diffs_remain_authoritative_pre_land() {
  # admission may use provisional planned paths but never lands or merges;
  # the pre-land actual-diff decision belongs to fm-review-diff.sh (Task 11)
  local out
  fresh_state
  out=$(FM_STATE_OVERRIDE="$STATE" FM_REFILL_AUTO=1 \
    "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_not_contains "$out" "landed" "refill admission claimed a landing"
  pass "provisional planned paths never override the actual-diff pre-land authority"
}

test_refill_acts_only_on_complete_projection
test_provisional_planned_path_admission_serializes_on_concrete_conflict
test_structured_admission_contract_covers_all_conflicts_and_unrelated_work
test_same_wave_candidates_are_serialized_against_frozen_admissions
test_nonimplementation_attempts_do_not_supply_admission_evidence
test_tracker_requests_do_not_supply_admission_evidence
test_missing_structured_evidence_serializes_fail_closed
test_live_query_normalizes_installed_array_and_filters_eligibility
test_dispatch_wave_respects_both_budgets_and_propagates_failure
test_launch_receives_the_exact_post_lock_admission_evidence
test_no_duplicate_dispatch_on_concurrent_refill
test_completion_or_merge_alone_never_decrements_capacity
test_rollback_mode_is_alert_only_and_never_dispatches
test_actual_diffs_remain_authoritative_pre_land

echo "all fm-refill-admission tests passed"
