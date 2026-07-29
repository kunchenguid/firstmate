#!/usr/bin/env bash
# Behavior tests for fleet admission control: bin/fm-admission.sh,
# bin/fm-admission-lib.sh, and the seams that consume them in bin/fm-bootstrap.sh,
# bin/fm-session-start.sh, and bin/fm-teardown.sh.
#
# The cases that matter most are the layer invariants, because they are what
# keeps admission from collapsing into scheduling:
#   - admission takes no task argument and refuses one;
#   - the same snapshot and config always produce the same record;
#   - a backlog contradiction is its own signal and never reads as saturation;
#   - no numeric threshold enforces, and the schema refuses one that tries;
#   - a band comes from configuration, never from a constant in the script.
#
# Bands are exercised through the deterministic safety conditions (authority,
# census integrity, snapshot freshness) with a canned fm-fleet-snapshot.v1
# document, so no case depends on a live fleet.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-admission-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
# A real bash symlinked under a verified harness name, so the session-lock
# ancestry walk in fm-session-lock-lib.sh resolves this test's own process as
# the lock owner - the same fixture shape the Claude Stop auto-arm suite uses.
ln -sf /bin/bash "$FAKEBIN/claude"

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

SNAP_GENERATED=2026-07-29T00:00:00Z
SNAP_EPOCH=1785283200  # 2026-07-29T00:00:00Z

# --- fixtures ---------------------------------------------------------------

# The complete valid policy every case starts from. Deliberately all-null
# thresholds and enforce:false, matching what ships.
write_policy() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_scheduling": {
    "admission_control": {
      "_note": "operator note, ignored by validation",
      "schema_version": 1,
      "enabled": true,
      "enforcement_mode": "safety-only",
      "fleet_id": "test-fleet",
      "combine": "most_restrictive",
      "severity_order": ["preferred", "soft", "hard"],
      "unknown_band": "hard",
      "bands": {
        "preferred": {"action": "admit"},
        "soft": {"action": "queue", "hold_kind": "load", "auto_reconsider": true},
        "hard": {"action": "refuse", "hold_kind": "load", "auto_reconsider": true}
      },
      "signals": {
        "census_integrity": {"enabled": true, "required": true, "source": "fresh-authority-census", "unknown_band": "hard", "max_snapshot_age_seconds": null},
        "backlog_consistency": {"enabled": true, "enforce": false, "source": "main-inventory", "unknown_band": "hard"},
        "admission_queue_pressure": {"enabled": true, "enforce": false, "source": "tasks-axi-load-holds-plus-ledger", "queued_soft_count": null, "queued_hard_count": null, "oldest_wait_soft_seconds": null, "oldest_wait_hard_seconds": null},
        "coordination_debt": {"enabled": false, "enforce": false, "source": "wake-outcome-ledger", "pending_wakes_soft_count": null, "pending_wakes_hard_count": null, "oldest_unhandled_wake_soft_seconds": null, "oldest_unhandled_wake_hard_seconds": null, "handled_wake_latency_window_seconds": null, "handled_wake_latency_soft_seconds": null, "handled_wake_latency_hard_seconds": null},
        "active_workers": {"enabled": true, "enforce": false, "source": "fresh-authority-census", "soft_count": null, "hard_count": null},
        "host_resources": {"enabled": false, "enforce": false, "source": "node-summaries", "metrics": {}},
        "reservation_pressure": {"enabled": false, "enforce": false, "source": "admission-registry", "soft_count": null, "hard_count": null}
      },
      "authority": {"mode": "single-primary", "authority_id": "test-authority", "config_mismatch_band": "hard", "unreachable_band": "hard"},
      "reservations": {"enabled": false, "ttl_seconds": null, "heartbeat_seconds": null, "clock_skew_tolerance_seconds": null, "release_on": ["spawn-failure", "teardown"], "reconcile_on": ["session-start"]},
      "queue": {"substrate": "tasks-axi hold --kind load", "release_triggers": ["teardown", "session-start"], "already_empty_fleet_recheck": "session-start-only"},
      "notifications": {"policy_ref": "/_scheduling/notification_bands", "episode_dedupe_seconds": null},
      "telemetry": {"sink": "wake-outcome-ledger", "record_every_decision": true, "record_signal_values": true, "record_config_paths": true, "record_config_digest": true, "credentials_forbidden": true},
      "dormant_triggers": {"numeric_admission_enforcement": {"ledger_observation_days_gte": 30, "checkpoint": "first fleet review after the observation period completes"}}
    }
  }
}
JSON
}

# A coherent census with a deliberately INCOHERENT backlog inventory: the exact
# shape observed in production, where task metadata was fine but one historical
# backlog row had no child metadata.
write_snapshot() {  # <path>
  cat > "$1" <<JSON
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "$SNAP_GENERATED",
  "tasks": [
    {"id": "alpha", "kind": "crewmate", "current_state": {"state": "working"}},
    {"id": "beta", "kind": "scout", "current_state": {"state": "working"}},
    {"id": "gamma", "kind": "secondmate", "current_state": {"state": ""}}
  ],
  "backlog": {"records": [
    {"id": "held-1", "hold_kind": "load"},
    {"id": "held-2", "hold_kind": "load"},
    {"id": "decide-1", "hold_kind": "captain"}
  ]},
  "main_inventory": {"valid": false, "reason": "in-flight backlog item has no child metadata", "orphan_in_flight": ["old-task"]}
}
JSON
}

make_home() {  # <name> -> prints home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

# Run fm-admission.sh as a child of a fake harness that owns the home's session
# lock, publishing its output as OUT and its exit code as ADMISSION_RC. The
# trailing rc dance stops bash from exec-ing the script into the fake harness
# pid, which would erase the very ancestry the lock check reads.
run_owned() {  # <home> [args...]
  local home=$1 rc=0
  shift
  # shellcheck disable=SC2016 # the -c body expands inside the fake harness
  OUT=$(FM_HOME="$home" FM_ADMISSION_NOW_EPOCH="${NOW_EPOCH:-$SNAP_EPOCH}" \
    "$FAKEBIN/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      rc=0; "$0" "$@" || rc=$?; exit $rc
    ' "$ROOT/bin/fm-admission.sh" "$@" 2>&1) || rc=$?
  ADMISSION_RC=$rc
}

# Run without any session lock: this caller is not the admission authority.
run_unowned() {  # <home> [args...]
  local home=$1 rc=0
  shift
  rm -f "$home/state/.lock"
  OUT=$(FM_HOME="$home" FM_ADMISSION_NOW_EPOCH="${NOW_EPOCH:-$SNAP_EPOCH}" \
    "$ROOT/bin/fm-admission.sh" "$@" 2>&1) || rc=$?
  ADMISSION_RC=$rc
}

# Mutate the policy in place with a jq filter.
patch_policy() {  # <home> <jq-filter>
  local home=$1 filter=$2
  jq "$filter" "$home/config/crew-dispatch.json" > "$home/config/.patched" \
    && mv "$home/config/.patched" "$home/config/crew-dispatch.json"
}

# Print the schema failure reason for a home's policy, or nothing when valid.
policy_reason() {  # <home>
  ( # shellcheck source=/dev/null
    . "$ROOT/bin/fm-admission-lib.sh"
    fm_admission_validate_reason "$1/config/crew-dispatch.json" )
}

# --- cases ------------------------------------------------------------------

test_absent_and_inert_policies_leave_dispatch_unchanged() {
  local home out
  home=$(make_home absent)
  out=$(FM_HOME="$home" "$ROOT/bin/fm-admission.sh"); expect_code 0 $? "absent policy"
  assert_contains "$out" "not configured (absent)" "an unconfigured home must say so plainly"

  # The shape the standing config actually ships: an admission_control object
  # holding nothing but an operator note.
  printf '%s\n' '{"_scheduling":{"admission_control":{"_note":"tracked as fleet-admission-control"}}}' \
    > "$home/config/crew-dispatch.json"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-admission.sh"); expect_code 0 $? "note-only policy"
  assert_contains "$out" "not configured (inert)" "a note-only policy must stay inert, not fail"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-admission.sh" --json)
  [ "$(printf '%s' "$out" | jq -r '.active')" = false ] || fail "inert policy must record active=false"
  [ "$(printf '%s' "$out" | jq -r '.decision_band')" = preferred ] \
    || fail "an unconfigured home must never refuse work"

  # Disabling an otherwise complete policy is also inert, not an error.
  write_policy "$home"
  patch_policy "$home" '._scheduling.admission_control.enabled = false'
  out=$(FM_HOME="$home" "$ROOT/bin/fm-admission.sh"); expect_code 0 $? "disabled policy"
  assert_contains "$out" "not configured (inert)" "enabled=false must be inert"

  pass "absent, note-only, and disabled admission policies leave dispatch unchanged"
}

test_admission_refuses_a_task_argument() {
  local home out rc=0
  home=$(make_home taskindep)
  write_policy "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-admission.sh" some-task-id 2>&1) || rc=$?
  expect_code 2 "$rc" "task argument"
  assert_contains "$out" "takes no task argument" \
    "admission must refuse a task argument rather than silently ignoring it"
  assert_contains "$out" "never the incoming task" \
    "the refusal must name the invariant it protects"
  pass "admission structurally refuses a task argument"
}

test_same_snapshot_and_config_give_the_same_record() {
  local home snap a b
  home=$(make_home invariance)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"

  run_owned "$home" --json --snapshot "$snap"; a=$OUT
  run_owned "$home" --json --snapshot "$snap"; b=$OUT
  [ "$a" = "$b" ] || fail "two evaluations of one snapshot produced different records"
  [ "$(printf '%s' "$a" | jq -r '.task_id')" = null ] || fail "the record must not bind a task"
  [ "$(printf '%s' "$a" | jq -r '.task_independent')" = true ] \
    || fail "the record must assert its task independence"
  pass "the same snapshot and configuration always produce the same record"
}

test_backlog_contradiction_is_its_own_signal_not_saturation() {
  local home snap rec rule
  home=$(make_home backlogsignal)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"

  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 0 "$ADMISSION_RC" "backlog contradiction alone"
  [ "$(printf '%s' "$rec" | jq -r '.decision_band')" = preferred ] \
    || fail "an unrelated backlog contradiction must not close the fleet"

  rule=$(printf '%s' "$rec" | jq -r '.rules[] | select(.rule_id == "backlog_consistency.main_inventory")')
  [ -n "$rule" ] || fail "the backlog contradiction must still be reported as its own signal"
  [ "$(printf '%s' "$rule" | jq -r '.observed')" = false ] \
    || fail "the contradiction must be recorded, not swallowed"
  assert_contains "$(printf '%s' "$rule" | jq -r '.detail')" "no child metadata" \
    "the record must carry the repairable reason"
  [ "$(printf '%s' "$rule" | jq -r '.signal_band')" = preferred ] \
    || fail "backlog consistency must not contribute a capacity band"

  # Census integrity, evaluated from the same snapshot, stays clean.
  [ "$(printf '%s' "$rec" | jq -r '.rules[] | select(.rule_id == "census_integrity.inventory") | .signal_band')" = preferred ] \
    || fail "a coherent worker census must stay valid despite the backlog contradiction"
  pass "a backlog contradiction is reported as its own signal and never reads as saturation"
}

test_census_integrity_enforces_deterministic_safety_conditions() {
  local home snap rec
  home=$(make_home census)
  write_policy "$home"
  snap="$home/snap.json"

  printf 'this is not a fleet snapshot\n' > "$snap"
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 4 "$ADMISSION_RC" "unreadable census"
  [ "$(printf '%s' "$rec" | jq -r '.decision_band')" = hard ] \
    || fail "an unreadable census must map to the configured unknown band"
  assert_contains "$(printf '%s' "$rec" | jq -c '.controlling_rules')" "census_integrity.inventory" \
    "the unreadable census must be named as the controlling rule"

  write_snapshot "$snap"
  jq '.tasks += [{"id": "alpha", "kind": "crewmate", "current_state": {"state": "working"}}]' \
    "$snap" > "$snap.dup" && mv "$snap.dup" "$snap"
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 4 "$ADMISSION_RC" "duplicate identities"
  assert_contains "$(printf '%s' "$rec" | jq -c '.controlling_rules')" "census_integrity.duplicate_identities" \
    "duplicate task identities must be a census failure"
  pass "census integrity enforces unreadable inventory and duplicate identities"
}

test_bands_come_from_configuration_not_from_constants() {
  local home snap rec
  home=$(make_home configdriven)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"
  NOW_EPOCH=$(( SNAP_EPOCH + 30 ))

  # No configured freshness limit: age is recorded, nothing enforces.
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 0 "$ADMISSION_RC" "null freshness limit"
  [ "$(printf '%s' "$rec" | jq -r '.snapshot_freshness_seconds')" = 30 ] \
    || fail "snapshot age must be observed even when no limit is configured"

  # A limit the snapshot exceeds moves the band, and the band it moves to is the
  # configured one - proving the value is read, not embedded.
  patch_policy "$home" '._scheduling.admission_control.signals.census_integrity.max_snapshot_age_seconds = 10'
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 4 "$ADMISSION_RC" "stale snapshot, unknown_band hard"
  [ "$(printf '%s' "$rec" | jq -r '.decision_band')" = hard ] || fail "stale snapshot must map to hard"

  patch_policy "$home" '._scheduling.admission_control.signals.census_integrity.unknown_band = "soft"'
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 3 "$ADMISSION_RC" "stale snapshot, unknown_band soft"
  [ "$(printf '%s' "$rec" | jq -r '.decision_band')" = soft ] \
    || fail "changing the configured band must change the result"
  [ "$(printf '%s' "$rec" | jq -r '.action')" = queue ] \
    || fail "the action must come from the configured band binding"
  [ "$(printf '%s' "$rec" | jq -r '.hold_kind')" = load ] \
    || fail "a deferred request must be queued under the load hold kind"

  # A limit the snapshot satisfies restores preferred.
  patch_policy "$home" '._scheduling.admission_control.signals.census_integrity.max_snapshot_age_seconds = 600'
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 0 "$ADMISSION_RC" "fresh enough snapshot"
  [ "$(printf '%s' "$rec" | jq -r '.decision_band')" = preferred ] || fail "a fresh snapshot must admit"
  unset NOW_EPOCH
  pass "bands are read from configuration, never from constants in the script"
}

test_single_primary_authority_is_the_existing_session_lock() {
  local home snap rec
  home=$(make_home authority)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"

  run_owned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 0 "$ADMISSION_RC" "lock owner"
  [ "$(printf '%s' "$rec" | jq -r '.authority_held')" = true ] \
    || fail "the session holding the home lock is the admission authority"

  run_unowned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 4 "$ADMISSION_RC" "no lock"
  [ "$(printf '%s' "$rec" | jq -r '.decision_band')" = hard ] \
    || fail "a session that is not the authority must not admit work"
  assert_contains "$(printf '%s' "$rec" | jq -c '.controlling_rules')" "authority.single_primary" \
    "the authority failure must be named"

  # The consequence is configuration, like every other band.
  patch_policy "$home" '._scheduling.admission_control.authority.unreachable_band = "soft"'
  run_unowned "$home" --json --snapshot "$snap"; rec=$OUT
  expect_code 3 "$ADMISSION_RC" "configured unreachable band"
  [ "$(printf '%s' "$rec" | jq -r '.decision_band')" = soft ] \
    || fail "the unreachable-authority consequence must come from configuration"
  pass "single-primary authority reuses the existing per-home session lock"
}

test_every_rule_carries_the_five_part_explanation() {
  local home snap rec missing
  home=$(make_home explanation)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT

  missing=$(printf '%s' "$rec" | jq -r '
    [.rules[]
     | select((has("observed") | not)
              or (has("source") | not)
              or (has("freshness_seconds") | not)
              or ((.config_path // "") | startswith("/_scheduling/admission_control") | not)
              or (has("configured_value") | not)
              or ((.signal_band // "") == "")
              or ((.fleet_band // "") == ""))
     | .rule_id] | join(", ")')
  [ -z "$missing" ] || fail "rules missing part of the five-part explanation: $missing"

  [ "$(printf '%s' "$rec" | jq -r '.config_digest')" != "" ] \
    || fail "every decision must name the configuration it acted on"
  [ "$(printf '%s' "$rec" | jq -r '.snapshot_id')" != "" ] \
    || fail "every decision must name the fleet view it used"

  # The human rendering carries the same five parts on one line per rule.
  run_owned "$home" --snapshot "$snap"
  assert_contains "$OUT" "/_scheduling/admission_control/signals/census_integrity/unknown_band" \
    "the human explanation must name the exact configuration path"
  assert_contains "$OUT" "source=fresh-authority-census" \
    "the human explanation must name the signal source"
  pass "every rule carries observed value, source and freshness, config path, configured value, and band"
}

test_active_workers_are_observed_and_never_capped() {
  local home snap rec rule
  home=$(make_home observeonly)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT

  [ "$(printf '%s' "$rec" | jq -r '.active_worker_count')" = 3 ] \
    || fail "the active worker count must be recorded"
  rule=$(printf '%s' "$rec" | jq -r '.rules[] | select(.rule_id == "active_workers.count")')
  [ "$(printf '%s' "$rule" | jq -r '.operator')" = observe ] \
    || fail "active workers must be observation only"
  [ "$(printf '%s' "$rule" | jq -r '.signal_band')" = preferred ] \
    || fail "an observation must never move the band"
  assert_contains "$(printf '%s' "$rule" | jq -r '.detail')" "crewmate=1" \
    "the worker breakdown must be recorded as an explanatory dimension"

  # A worker whose current state is ambiguous stays counted as present: no
  # threshold may treat an unreadable pane as an absent worker.
  [ "$(printf '%s' "$rec" | jq -r '.unknown_state_count')" = 1 ] \
    || fail "an ambiguous worker must be surfaced, not silently dropped"

  # Load-hold depth is observed; wait age stays honestly unmeasured.
  [ "$(printf '%s' "$rec" | jq -r '.load_queue_depth')" = 2 ] \
    || fail "load-held requests must be counted from the backlog"
  [ "$(printf '%s' "$rec" | jq -r '.oldest_load_wait_seconds')" = null ] \
    || fail "admission wait age is not collectable yet and must not be invented"
  assert_contains "$(printf '%s' "$rec" | jq -r '.rules[] | select(.rule_id == "admission_queue_pressure.oldest_wait") | .unmeasured_reason')" \
    "task age, not admission wait age" "the unmeasured reason must be explicit"
  pass "active workers and queue depth are observed with no cap and no invented values"
}

test_uncollectable_signals_are_recorded_as_unmeasured() {
  local home snap rec name
  home=$(make_home unmeasured)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT

  for name in coordination_debt host_resources reservation_pressure; do
    [ "$(printf '%s' "$rec" | jq -r --arg n "$name" '.rules[] | select(.rule_id == "\($n).unavailable") | .valid')" = false ] \
      || fail "$name must be recorded as unmeasured, not as zero"
    [ "$(printf '%s' "$rec" | jq -r --arg n "$name" '.rules[] | select(.rule_id == "\($n).unavailable") | .signal_band')" = preferred ] \
      || fail "$name must not move the band while it is uncollectable"
  done
  pass "signals with no collector are recorded as unmeasured rather than assumed"
}

test_ledger_extension_seam_is_named_but_not_integrated() {
  local home snap rec
  home=$(make_home ledger)
  write_policy "$home"
  snap="$home/snap.json"
  write_snapshot "$snap"
  run_owned "$home" --json --snapshot "$snap"; rec=$OUT

  [ "$(printf '%s' "$rec" | jq -r '.record_kind')" = admission \
    ] || fail "the record must be distinguishable from wake and terminal records"
  [ "$(printf '%s' "$rec" | jq -r '.telemetry.sink')" = wake-outcome-ledger ] \
    || fail "the telemetry sink must come from configuration"
  [ "$(printf '%s' "$rec" | jq -r '.telemetry.integrated')" = false ] \
    || fail "the ledger seam must report honestly that it is not integrated yet"
  [ "$(printf '%s' "$rec" | jq -r '.decision_id')" != "" ] \
    || fail "the record needs an idempotent decision identity"

  # No competing evidence store is created anywhere under the home.
  [ -z "$(find "$home/state" -name '*admission*' -print -quit)" ] \
    || fail "admission must not open its own store"
  pass "the ledger extension seam is named and no competing store is created"
}

test_schema_validation_refuses_every_named_failure() {
  local home reason filter label
  home=$(make_home schema)
  write_policy "$home"
  cp "$home/config/crew-dispatch.json" "$home/policy.json"

  check_invalid() {  # <jq-filter> <expected-substring> <label>
    filter=$1; label=$3
    jq "$filter" "$home/policy.json" > "$home/config/crew-dispatch.json"
    reason=$(policy_reason "$home")
    assert_contains "$reason" "$2" "$label was not refused with an actionable reason"
    if FM_HOME="$home" "$ROOT/bin/fm-admission.sh" validate >/dev/null 2>&1; then
      fail "$label must make the evaluator refuse"
    fi
  }

  check_invalid '._scheduling.admission_control.mystery = 1' \
    'unknown field: mystery' 'an unknown top-level field'
  check_invalid '._scheduling.admission_control.schema_version = 2' \
    'schema_version must be 1' 'an unsupported schema version'
  check_invalid '._scheduling.admission_control.combine = "average"' \
    'no averaging can hide a hard result' 'an averaging combine rule'
  check_invalid '._scheduling.admission_control.severity_order = ["hard","soft","preferred"]' \
    'severity_order must be' 'a reordered severity ladder'
  check_invalid '._scheduling.admission_control.unknown_band = "preferred"' \
    'unknown_band must be soft or hard' 'unknown mapped to preferred'
  check_invalid '._scheduling.admission_control.enforcement_mode = "wide-open"' \
    'enforcement_mode must be' 'an unrecognized enforcement mode'
  check_invalid '._scheduling.admission_control.bands.soft.hold_kind = "captain"' \
    'bands.soft.hold_kind must be "load"' 'a queue action naming another hold kind'
  check_invalid '._scheduling.admission_control.queue.substrate = "admission-queue.json"' \
    'admission adds no second queue' 'a second queue substrate'
  check_invalid '._scheduling.admission_control.signals.active_workers.enforce = true' \
    'numeric enforcement is evidence-gated' 'numeric enforcement under safety-only'
  check_invalid '._scheduling.admission_control.signals.active_workers.soft_count = 9
                 | ._scheduling.admission_control.signals.active_workers.hard_count = 3' \
    'soft threshold must not be more restrictive than hard' 'an inverted threshold pair'
  check_invalid '._scheduling.admission_control.signals.active_workers.soft_count = "four"' \
    'must be null or a non-negative number' 'a threshold that is not a number'
  check_invalid '._scheduling.admission_control.signals.active_workers.source = "guesswork"' \
    'source must be "fresh-authority-census"' 'an unrecognized signal source'
  check_invalid '._scheduling.admission_control.signals.coordination_debt.enabled = true' \
    'source is not collectable yet' 'a signal enabled without a collector'
  check_invalid '._scheduling.admission_control.signals.mystery = {"enabled": false}' \
    'unknown signal: mystery' 'an unknown signal'
  check_invalid '._scheduling.admission_control.reservations.enabled = true' \
    'reservations are dormant' 'reservations enabled before their trigger'
  check_invalid '._scheduling.admission_control.authority.mode = "multi-writer"' \
    'authority.mode must be "single-primary"' 'a second admission authority'
  check_invalid '._scheduling.admission_control.telemetry.record_every_decision = false' \
    'record_every_decision must be true' 'telemetry disabled while admission is enabled'
  check_invalid '._scheduling.admission_control.dormant_triggers.numeric_admission_enforcement.checkpoint = null' \
    'needs a named checkpoint' 'a dormant trigger with no checkpoint'
  check_invalid 'del(._scheduling.admission_control.bands)' \
    'an enabled policy needs bands' 'an enabled policy missing a required section'

  cp "$home/policy.json" "$home/config/crew-dispatch.json"
  reason=$(policy_reason "$home")
  [ -z "$reason" ] || fail "the complete shipped policy shape must validate: $reason"
  pass "schema validation refuses every named failure with an actionable reason"
}

test_bootstrap_reports_malformed_policy_and_stays_silent_otherwise() {
  local home out
  home=$(make_home bootstrap)

  out=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_not_contains "$out" "ADMISSION_CONTROL" "a home with no policy must be silent"

  write_policy "$home"
  out=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_not_contains "$out" "ADMISSION_CONTROL" "a valid policy must be silent"

  out=$(FM_BOOTSTRAP_VERBOSE_FACTS=1 FM_BOOTSTRAP_DETECT_ONLY=1 FM_HOME="$home" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_contains "$out" "BOOTSTRAP_INFO: fleet admission control active" \
    "the verbose fact must report the configured state"

  patch_policy "$home" '._scheduling.admission_control.unknown_band = "preferred"'
  out=$(FM_BOOTSTRAP_DETECT_ONLY=1 FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_contains "$out" "ADMISSION_CONTROL: invalid config/crew-dispatch.json _scheduling.admission_control - unknown_band must be soft or hard" \
    "a malformed policy must be an actionable bootstrap diagnostic"

  # The diagnostic is read-only, so it still prints for a session that could not
  # take the fleet lock - malformed policy must stop safely in both modes.
  out=$(FM_HOME="$home" "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_contains "$out" "ADMISSION_CONTROL: invalid" \
    "the policy diagnostic must not depend on the mutating sweeps"
  pass "bootstrap reports a malformed policy and stays silent for valid or absent ones"
}

test_release_seams_appear_only_for_an_active_policy() {
  local home out
  home=$(make_home seams)

  out=$(FM_HOME="$home" "$ROOT/bin/fm-session-start.sh" 2>&1)
  assert_not_contains "$out" "Fleet admission" "an unconfigured home must add nothing to the digest"

  write_policy "$home"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-session-start.sh" 2>&1)
  assert_contains "$out" "Fleet admission" "session start is one of the two release triggers"
  assert_contains "$out" "admission: " "the digest must carry the current band"
  assert_contains "$out" "admit at most one at a time" \
    "the digest must state the one-at-a-time release rule"

  # Teardown's reminder is the other release trigger. Assert on the emitting
  # function directly: driving a full teardown would exercise worktree and
  # endpoint machinery this suite does not own.
  assert_grep 'admission_release_reminder' "$ROOT/bin/fm-teardown.sh" \
    "teardown lost its admission release seam"
  out=$(
    CONFIG="$home/config" KIND=ship ID=demo-task
    export CONFIG KIND ID
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-admission-lib.sh"
    # shellcheck disable=SC2016
    eval "$(awk '/^admission_release_reminder\(\) \{/,/^\}/' "$ROOT/bin/fm-teardown.sh")"
    admission_release_reminder
  )
  assert_contains "$out" "recompute the fleet band" \
    "cleanup must prompt a fresh band before releasing held work"
  assert_contains "$out" "one at a time" \
    "each release must change the snapshot before the next is evaluated"
  pass "both release triggers fire only for a home with an active policy"
}

# --- runner -----------------------------------------------------------------

test_absent_and_inert_policies_leave_dispatch_unchanged
test_admission_refuses_a_task_argument
test_same_snapshot_and_config_give_the_same_record
test_backlog_contradiction_is_its_own_signal_not_saturation
test_census_integrity_enforces_deterministic_safety_conditions
test_bands_come_from_configuration_not_from_constants
test_single_primary_authority_is_the_existing_session_lock
test_every_rule_carries_the_five_part_explanation
test_active_workers_are_observed_and_never_capped
test_uncollectable_signals_are_recorded_as_unmeasured
test_ledger_extension_seam_is_named_but_not_integrated
test_schema_validation_refuses_every_named_failure
test_bootstrap_reports_malformed_policy_and_stays_silent_otherwise
test_release_seams_appear_only_for_an_active_policy
