#!/usr/bin/env bash
# Public-interface tests for the --refill admission action (Task 12): refill
# acts only on a complete projection reporting productive work below target
# and reserved ownership below ceiling; provisional planned-path admission
# serializes only on a concrete overlap with the FROZEN provisional evidence
# in a current attempt's delivery record; the home lock serializes concurrent
# refill waves so a bead is never double-dispatched; completion or merge
# events never decrement capacity directly; attended mode prints the exact
# next-wave dispatch commands without launching, allocating, or claiming; and
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
    if grep -qx "$id" "${FAKE_CLAIMS:?FAKE_CLAIMS unset}" 2>/dev/null; then
      printf '%s\n' "{\"id\":\"$id\",\"status\":\"claimed\",\"claimed_by\":\"pi\"}"
    else
      printf '%s\n' "{\"id\":\"$id\",\"status\":\"open\",\"claimed_by\":null}"
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
printf '%s\n' "$bead" >> "${FAKE_CLAIMS:?FAKE_CLAIMS unset}"
fm_attempt_effect_observe "$attempt" "$gen" tracker \
  "$(jq -n --arg bead "$bead" '{bead:$bead,status:"claimed"}')" || exit 1
echo "tracker_receipt: $attempt claim $bead claimed"
SH
chmod +x "$FAKEBIN/fm-br-receipt.sh"

# fake spawn (the Task 6 resume path): records the exact dispatch args and
# never launches a real worker
cat > "$FAKEBIN/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf 'spawn %s\n' "$*" >> "${SPAWN_LOG:?SPAWN_LOG unset}"
exit 0
SH
chmod +x "$FAKEBIN/fm-spawn.sh"

# fake crew-state: one deterministic working read so every projection in this
# suite is refill-safe and reproducible
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"schema":"fm-crew-state.v1","id":"fixture","state":"working","source":"fake"}'
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
  : > "$READY_JSON"
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
  # two concurrent --refill invocations; the home lock admits one wave and
  # the loser's post-lock ownership re-read sees the winner's claim
  local launches
  fresh_state
  printf '[{"id":"dos-conc","planned_path":"docs/"}]' > "$READY_JSON"
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

test_attended_mode_prints_commands_without_launching_or_mutating() {
  # no config/refill-auto and FM_REFILL_AUTO != 1: --refill prints the exact
  # next-wave dispatch commands and never launches, allocates attempts, or
  # claims beads
  local out aidcount
  fresh_state
  printf '[{"id":"dos-att","planned_path":"docs/"},{"id":"dos-att-b","planned_path":"src/"}]' > "$READY_JSON"
  out=$(FM_REFILL_AUTO=0 "$ROOT/bin/fm-fleet-refill.sh" --refill 2>&1 || true)
  assert_contains "$out" "next-wave" "attended refill printed no next-wave commands"
  assert_contains "$out" "dos-att" "attended refill omitted an admitted candidate"
  assert_not_contains "$out" "launch " "attended refill launched"
  aidcount=$(find "$STATE/attempts" -name '*.json' 2>/dev/null | wc -l)
  [ "$aidcount" = 0 ] || fail "attended refill allocated attempts"
  [ ! -s "$FAKE_CLAIMS" ] || fail "attended refill claimed beads"
  pass "attended mode prints the exact dispatch commands and never launches, allocates, or claims"
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
test_no_duplicate_dispatch_on_concurrent_refill
test_completion_or_merge_alone_never_decrements_capacity
test_attended_mode_prints_commands_without_launching_or_mutating
test_actual_diffs_remain_authoritative_pre_land

echo "all fm-refill-admission tests passed"
