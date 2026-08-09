#!/usr/bin/env bash
# Behavior tests for bin/fm-decision-surface.sh - the fleet-side operational
# decision surface, and the refusal of a claim structured state contradicts.
#
# The cases that carry the weight are the three seeds this command exists to
# satisfy, each a sentence firstmate has said or could say that the records
# already refute:
#   - work is "waiting on capacity" while the fleet accepts another task;
#   - a decision is "still with the captain" while its record is ruled;
#   - work is dispatched under an identity that is already live.
#
# Every seed is paired with its negative control, because a check that only ever
# answers "contradicted" enforces nothing: the control drives the same code path
# to the opposite verdict from the opposite structured state.
#
# Fleet state is supplied as canned fm-fleet-snapshot.v1 documents through
# FM_DECISION_SURFACE_SNAPSHOT, so no case depends on a live fleet, a spawned
# worker, or a real platform.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-decision-surface-tests)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

SURFACE="$ROOT/bin/fm-decision-surface.sh"

# --- fixtures ---------------------------------------------------------------

make_home() {  # <name> -> prints home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/state" "$home/data" "$home/projects"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

# A census with one live task, one open captain decision, and one ruled decision.
write_snapshot() {  # <path>
  cat > "$1" <<'JSON'
{
  "schema": "fm-fleet-snapshot.v1",
  "generated": "2026-08-09T00:00:00Z",
  "tasks": [
    {"id": "alpha", "kind": "ship", "mode": "no-mistakes", "yolo": "0",
     "project": "demo", "harness": "claude", "backend": "tmux",
     "current_state": {"state": "working", "source": "run-step", "detail": "running", "raw": "state: working · source: run-step · running"},
     "endpoint": {"target": "demo:0", "exists": true, "status": "present"},
     "pr": {"url": null, "source": "absent"},
     "hints": {"open_decisions": []}}
  ],
  "backlog": {"records": [
    {"order": 1, "state": "in_flight", "structured": true, "id": "alpha", "title": "live ship task", "hold_kind": null},
    {"order": 2, "state": "queued", "structured": true, "id": "beta", "title": "queued but never dispatched", "hold_kind": null},
    {"order": 3, "state": "queued", "structured": true, "id": "demo-decision-open", "title": "Open ruling", "hold_kind": "captain", "hold_reason": "awaiting captain"},
    {"order": 4, "state": "done", "structured": true, "id": "demo-decision-ruled", "title": "Ruled decision", "hold_kind": "captain", "hold_reason": "was awaiting captain"}
  ]},
  "main_inventory": {"valid": true, "reason": null, "orphan_in_flight": [], "unstructured_current_count": 0}
}
JSON
}

# The same census with an inventory that contradicts itself: an in-flight row
# whose child record is missing. This is exactly the shape a duplicate hides in.
write_incoherent_snapshot() {  # <path>
  write_snapshot "$1"
  jq '.main_inventory = {"valid": false, "reason": "in-flight backlog item has no child metadata", "orphan_in_flight": ["ghost"], "unstructured_current_count": 0}' \
    "$1" > "$1.patched" && mv "$1.patched" "$1"
}

# A complete, valid, all-null-threshold admission policy: the shape that ships.
# With no session lock held, its single-primary authority rule bands to hard, so
# the fleet genuinely refuses another task and the capacity claim is supported.
write_policy() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_scheduling": {
    "admission_control": {
      "schema_version": 1,
      "enabled": true,
      "enforcement_mode": "safety-only",
      "fleet_id": "decision-surface-test-fleet",
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
      "authority": {"mode": "single-primary", "authority_id": "decision-surface-test-authority", "config_mismatch_band": "hard", "unreachable_band": "hard"},
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

# Run the surface against a home and a canned census; publishes OUT and RC.
run_surface() {  # <home> <snapshot-or-empty> [args...]
  local home=$1 snap=$2 rc=0
  shift 2
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" "$SURFACE" "$@" 2>&1) || rc=$?
  RC=$rc
}

# --- seed 1: a capacity claim the fleet contradicts -------------------------

test_capacity_claim_is_contradicted_while_the_fleet_admits_work() {
  local home snap
  home=$(make_home capacity-admit)
  snap="$home/snap.json"; write_snapshot "$snap"

  run_surface "$home" "$snap" check capacity-blocked
  expect_code 3 "$RC" "a capacity claim against an admitting fleet must be refused"
  assert_contains "$OUT" "contradicted" "the verdict must name the contradiction"
  assert_contains "$OUT" "action=admit" "the refusal must name the admission reading that refutes the claim"
  assert_contains "$OUT" "accepts another task" \
    "the refusal must say plainly that the fleet has room, not just print a band"

  # NEGATIVE CONTROL: the same command, the same code path, a fleet that really
  # is refusing. Without this the check could be a constant.
  home=$(make_home capacity-refuse)
  snap="$home/snap.json"; write_snapshot "$snap"
  write_policy "$home"
  rm -f "$home/state/.lock"
  run_surface "$home" "$snap" check capacity-blocked
  expect_code 0 "$RC" "a capacity claim must stand when admission actually refuses"
  assert_contains "$OUT" "not-contradicted" "a genuinely refusing fleet must not refute the claim"
  assert_contains "$OUT" "action=refuse" "the supporting evidence must name the refusing band"

  pass "a capacity claim is refused against an admitting fleet and stands against a refusing one"
}

test_an_unevaluable_admission_forbids_the_claim_rather_than_passing_it() {
  local home snap
  home=$(make_home capacity-broken)
  snap="$home/snap.json"; write_snapshot "$snap"
  # A malformed policy: admission cannot decide, so capacity is unknown.
  printf '%s\n' '{"_scheduling":{"admission_control":{"schema_version":1,"enabled":true}}}' \
    > "$home/config/crew-dispatch.json"

  run_surface "$home" "$snap" check capacity-blocked
  expect_code 4 "$RC" "an undecidable admission must be unevaluable, never a quiet pass"
  assert_contains "$OUT" "unevaluable" "the verdict must say the fact is unknown"
  assert_contains "$OUT" "may be asserted" \
    "unevaluable must state that the claim cannot be made, not merely that a read failed"
  assert_not_contains "$OUT" "not-contradicted" \
    "an unreadable owner must never render as permission to make the claim"

  pass "an undecidable admission forbids the capacity claim instead of passing it"
}

# --- seed 2: a ruled decision reported as pending ---------------------------

test_a_ruled_decision_cannot_be_reported_pending() {
  local home snap
  home=$(make_home decisions)
  snap="$home/snap.json"; write_snapshot "$snap"

  run_surface "$home" "$snap" check decision-pending demo-decision-ruled
  expect_code 3 "$RC" "reporting a ruled decision as pending must be refused"
  assert_contains "$OUT" "contradicted" "the verdict must name the contradiction"
  assert_contains "$OUT" "ruled, not pending" "the refusal must say what the record actually holds"

  # NEGATIVE CONTROL: a decision that genuinely is still open.
  run_surface "$home" "$snap" check decision-pending demo-decision-open
  expect_code 0 "$RC" "a genuinely open decision must not be refuted"
  assert_contains "$OUT" "not-contradicted" "an open record must support the claim"

  # A decision with no durable record at all is unknown, not open: firstmate
  # must open the hold rather than narrate a status it cannot read.
  run_surface "$home" "$snap" check decision-pending never-recorded
  expect_code 4 "$RC" "an unrecorded decision must be unevaluable"
  assert_contains "$OUT" "no durable decision record" "the verdict must name the missing record"
  assert_contains "$OUT" "fm-decision-hold.sh" "it must point at the owner that creates one"

  pass "a ruled decision refutes a pending report, an open one supports it, and an absent one is unknown"
}

# --- seed 3: a duplicate dispatch -------------------------------------------

test_dispatching_an_identity_already_in_flight_is_contradicted() {
  local home snap
  home=$(make_home duplicates)
  snap="$home/snap.json"; write_snapshot "$snap"

  run_surface "$home" "$snap" check duplicate-dispatch alpha
  expect_code 3 "$RC" "dispatching a live identity must be refused"
  assert_contains "$OUT" "contradicted" "the verdict must name the contradiction"
  assert_contains "$OUT" "already exists under this identity" \
    "the refusal must say the work exists, not merely that a record matched"
  assert_contains "$OUT" "state: working" \
    "the refusal must carry the live state so the reader can steer instead of dispatch"

  # NEGATIVE CONTROL: an identity with no live task and no in-flight row.
  run_surface "$home" "$snap" check duplicate-dispatch brand-new
  expect_code 0 "$RC" "a genuinely new identity must dispatch"
  assert_contains "$OUT" "not-contradicted" "an unused identity must not be refused"

  pass "a live identity refuses a second dispatch and an unused one does not"
}

test_an_incoherent_inventory_cannot_answer_the_duplicate_question() {
  local home snap
  home=$(make_home duplicates-incoherent)
  snap="$home/snap.json"; write_incoherent_snapshot "$snap"

  # The identity looks free, and under a coherent census it would be. A census
  # that contradicts itself is exactly where a duplicate hides, so the answer is
  # unknown rather than the convenient one.
  run_surface "$home" "$snap" check duplicate-dispatch brand-new
  expect_code 4 "$RC" "an incoherent inventory must not answer the duplicate question"
  assert_contains "$OUT" "unevaluable" "the verdict must say the census cannot answer"
  assert_contains "$OUT" "incoherent" "the reason must name the contradiction to repair"
  assert_not_contains "$OUT" "not-contradicted" \
    "an incoherent census must never render as clearance to dispatch"

  pass "an incoherent inventory refuses to clear a dispatch"
}

test_an_unreadable_census_is_unevaluable_for_every_census_backed_check() {
  local home
  home=$(make_home census-gone)

  run_surface "$home" "$home/absent.json" check duplicate-dispatch alpha
  expect_code 4 "$RC" "an unreadable census must be unevaluable for duplicate dispatch"
  assert_contains "$OUT" "unevaluable" "the duplicate verdict must say so"

  run_surface "$home" "$home/absent.json" check decision-pending demo-decision-open
  expect_code 4 "$RC" "an unreadable census must be unevaluable for decision status"
  assert_contains "$OUT" "unevaluable" "the decision verdict must say so"

  pass "an unreadable census makes every census-backed check unevaluable"
}

# --- the compensation ledger ------------------------------------------------

test_every_ledger_row_names_either_its_owner_or_the_capability_it_waits_for() {
  local home rows owned_without_owner pending_without_owner
  home=$(make_home ledger)

  run_surface "$home" "" owners --json
  expect_code 0 "$RC" "the ledger must render"
  rows=$(printf '%s' "$OUT" | jq '.rows')

  [ "$(printf '%s' "$rows" | jq 'length')" -gt 0 ] || fail "the ledger must not be empty"

  owned_without_owner=$(printf '%s' "$rows" \
    | jq '[.[] | select(.status == "owned" and (.owner == null or .owner == ""))] | length')
  [ "$owned_without_owner" = 0 ] \
    || fail "an owned row with no owner is a claim with no source"

  pending_without_owner=$(printf '%s' "$rows" \
    | jq '[.[] | select(.status == "pending" and (.pending_owner == null or .pending_owner == ""))] | length')
  [ "$pending_without_owner" = 0 ] \
    || fail "a pending row with no named capability is a silent gap, which is what the ledger exists to prevent"

  # Every row is one of the two states; an unclassified row would be an
  # unowned compensation nobody is accountable for.
  [ "$(printf '%s' "$rows" | jq '[.[] | select(.status != "owned" and .status != "pending")] | length')" = 0 ] \
    || fail "every ledger row must be owned or pending"

  # The pending set must be visible on the surface itself, so a reader who never
  # runs `owners` still sees which facts firstmate is still deriving.
  local snap
  snap="$home/snap.json"; write_snapshot "$snap"
  run_surface "$home" "$snap" --json
  expect_code 0 "$RC" "the surface must render"
  [ "$(printf '%s' "$OUT" | jq '[.owner_pending[] | select(.pending_owner == null)] | length')" = 0 ] \
    || fail "the surface must carry a named capability for every pending row"
  [ "$(printf '%s' "$OUT" | jq -r '.consumption_contract.firstmate_must_not_reconstruct_deterministic_truth')" = true ] \
    || fail "the surface must state the consumption contract it is published under"

  pass "every ledger row names its owner or the capability it waits for"
}

# --- the platform seam ------------------------------------------------------

test_the_platform_seam_is_wired_only_when_it_resolves_this_fleet_work() {
  local home snap launcher
  home=$(make_home seam)
  snap="$home/snap.json"; write_snapshot "$snap"

  # Unconfigured: the shipped default. No probe, no claim of reachability.
  run_surface "$home" "$snap" platform-seam --json
  expect_code 0 "$RC" "an unconfigured seam must render"
  [ "$(printf '%s' "$OUT" | jq -r '.configured')" = absent ] || fail "an unconfigured seam must say absent"
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = not_checked ] \
    || fail "reachability must never be assumed without a probe"
  [ "$(printf '%s' "$OUT" | jq -r '.wiring')" = not-wired ] || fail "an unconfigured seam is not wired"

  # A launcher that fails is unreachable, and unreachable is not wired.
  launcher="$home/broken-launcher"
  printf '#!/bin/sh\nexit 7\n' > "$launcher"; chmod +x "$launcher"
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    FM_DECISION_SURFACE_PLATFORM="$launcher" "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = false ] || fail "a failing launcher must probe unreachable"
  [ "$(printf '%s' "$OUT" | jq -r '.wiring')" = not-wired ] || fail "an unreachable launcher is not wired"

  # A launcher that answers, but projects identities this fleet does not run.
  # This is the live case today, and treating it as wired would reintroduce the
  # contradiction the surface exists to prevent.
  launcher="$home/foreign-launcher"
  printf '#!/bin/sh\necho "surfaces: WRK-AAAA1111,WRK-BBBB2222"\n' > "$launcher"; chmod +x "$launcher"
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    FM_DECISION_SURFACE_PLATFORM="$launcher" "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = true ] || fail "a responding launcher must probe reachable"
  [ "$(printf '%s' "$OUT" | jq -r '.fleet_identities_resolved')" = 0 ] \
    || fail "a foreign projection must resolve none of this fleet's identities"
  [ "$(printf '%s' "$OUT" | jq -r '.wiring')" = not-wired ] \
    || fail "reachable but foreign must not be reported as wired"

  # A projection where the fleet id occurs only inside a longer identifier and
  # inside a prose word. A coincidental substring is not a resolved identity,
  # and counting one would flip the seam to wired on foreign work.
  launcher="$home/embedded-launcher"
  printf '#!/bin/sh\necho "surfaces: WRK-alpha-0001 (alphabetical listing)"\n' > "$launcher"; chmod +x "$launcher"
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    FM_DECISION_SURFACE_PLATFORM="$launcher" "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = true ] \
    || fail "a launcher answering with embedded ids must still probe reachable"
  [ "$(printf '%s' "$OUT" | jq -r '.fleet_identities_resolved')" = 0 ] \
    || fail "a fleet id embedded in a longer token or in prose must not resolve"
  [ "$(printf '%s' "$OUT" | jq -r '.wiring')" = not-wired ] \
    || fail "an embedded occurrence of a fleet id must not report the seam wired"

  # NEGATIVE CONTROL: the same probe against a launcher that does resolve this
  # home's work. Without it, "not-wired" could be hard-coded.
  launcher="$home/live-launcher"
  printf '#!/bin/sh\necho "surfaces: alpha"\n' > "$launcher"; chmod +x "$launcher"
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    FM_DECISION_SURFACE_PLATFORM="$launcher" "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ "$(printf '%s' "$OUT" | jq -r '.fleet_identities_resolved')" = 1 ] \
    || fail "a projection naming this fleet's task must resolve it"
  [ "$(printf '%s' "$OUT" | jq -r '.wiring')" = wired ] \
    || fail "a projection that resolves this fleet's work is the wired case"

  pass "the platform seam is wired only when it resolves this fleet's own work"
}

test_the_seam_takes_a_launcher_path_and_never_a_shell_command_line() {
  local home snap dir launcher marker
  home=$(make_home seam-path)
  snap="$home/snap.json"; write_snapshot "$snap"

  # A launcher path containing a space must work unquoted and unescaped: word
  # splitting it would be the same defect as interpreting it as a command line.
  dir="$home/platform dir"; mkdir -p "$dir"
  launcher="$dir/launcher.sh"
  printf '#!/bin/sh\necho "surfaces: alpha"\n' > "$launcher"; chmod +x "$launcher"
  printf '# operator note\n\n%s\n' "$launcher" > "$home/config/decision-surface-platform"

  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ "$(printf '%s' "$OUT" | jq -r '.configured')" = present ] \
    || fail "a configured launcher must be read past comments and blank lines"
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = true ] \
    || fail "a launcher path containing a space must run without quoting in the config"

  # The configured value is a path, not a command line: appending shell syntax
  # must not execute it. If it did, a private config file would be an execution
  # seam rather than a pointer.
  marker="$home/injected"
  printf '%s\n' "$launcher; touch '$marker'" > "$home/config/decision-surface-platform"
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ ! -e "$marker" ] || fail "the launcher value must never be interpreted as a shell command line"
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = false ] \
    || fail "a value that is not an executable path must probe unreachable"

  pass "the seam reads one launcher path and never interprets it as a shell command line"
}

test_a_probe_that_cannot_be_bounded_does_not_run() {
  local home snap launcher minbin tool
  home=$(make_home seam-unbounded)
  snap="$home/snap.json"; write_snapshot "$snap"
  launcher="$home/live-launcher"
  printf '#!/bin/sh\necho "surfaces: alpha"\n' > "$launcher"; chmod +x "$launcher"

  # A PATH with everything the seam read needs EXCEPT a bounding tool. An
  # unbounded probe against an unresponsive platform would wedge the read, so
  # the probe must not run at all rather than run without a bound.
  command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 \
    || { printf 'skip: host has no bounding tool to withhold\n'; return 0; }
  minbin="$home/minbin"; mkdir -p "$minbin"
  for tool in bash dirname cat sed awk date jq; do
    ln -sf "$(command -v "$tool")" "$minbin/$tool"
  done

  OUT=$(PATH="$minbin" FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    FM_DECISION_SURFACE_PLATFORM="$launcher" \
    "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = false ] \
    || fail "with no bounding tool the probe must report unreachable, never run unbounded"
  [ "$(printf '%s' "$OUT" | jq -r '.wiring')" = not-wired ] \
    || fail "an unrunnable probe must leave the seam not wired"

  # NEGATIVE CONTROL: the same launcher and the same read, with the bounding
  # tool back on PATH, does reach it. Otherwise the case above proves nothing
  # beyond a broken PATH.
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    FM_DECISION_SURFACE_PLATFORM="$launcher" \
    "$SURFACE" platform-seam --probe-platform --json 2>&1)
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = true ] \
    || fail "the same launcher must be reachable once a bounding tool is available"

  pass "a probe that cannot be bounded does not run"
}

test_a_launcher_that_ignores_term_cannot_outlive_the_probe_bound() {
  local home snap launcher bound rc=0
  home=$(make_home seam-term-immune)
  snap="$home/snap.json"; write_snapshot "$snap"
  bound=timeout
  command -v timeout >/dev/null 2>&1 || bound=gtimeout
  command -v "$bound" >/dev/null 2>&1 \
    || { printf 'skip: host has no bounding tool\n'; return 0; }

  # A launcher that traps TERM and never exits on its own: the shape a merely
  # TERM-based bound cannot stop. The probe must still return, because a wedged
  # command substitution would hold the whole read hostage.
  launcher="$home/stubborn-launcher"
  cat > "$launcher" <<SH
#!/bin/sh
trap '' TERM
echo \$\$ > "$home/launcher.pid"
echo "surfaces: alpha"
exec >/dev/null 2>&1
while :; do sleep 1; done
SH
  chmod +x "$launcher"

  # The outer bound converts a regression into a failure instead of a hang.
  OUT=$(FM_HOME="$home" FM_DECISION_SURFACE_SNAPSHOT="$snap" \
    FM_DECISION_SURFACE_PLATFORM="$launcher" FM_DECISION_SURFACE_PROBE_TIMEOUT=1 \
    "$bound" 30 "$SURFACE" platform-seam --probe-platform --json 2>&1) || rc=$?
  [ ! -f "$home/launcher.pid" ] || fm_test_reap "$(cat "$home/launcher.pid")"
  expect_code 0 "$rc" "the probe must return within its bound against a launcher that ignores TERM"
  [ "$(printf '%s' "$OUT" | jq -r '.reachable')" = false ] \
    || fail "a launcher killed at the bound must probe unreachable"
  [ "$(printf '%s' "$OUT" | jq -r '.wiring')" = not-wired ] \
    || fail "a launcher killed at the bound must leave the seam not wired"

  pass "a launcher that ignores TERM cannot outlive the probe bound"
}

# --- surface rendering and usage --------------------------------------------

test_the_surface_renders_both_scopes_and_refuses_an_unknown_task() {
  local home snap
  home=$(make_home render)
  snap="$home/snap.json"; write_snapshot "$snap"

  run_surface "$home" "$snap"
  expect_code 0 "$RC" "the fleet surface must render"
  assert_contains "$OUT" "scope: fleet" "the fleet surface must name its scope"
  assert_contains "$OUT" "alpha" "the fleet surface must list live work"

  # An active admission record has no top-level reason field: the capacity line
  # must fall back to the controlling rules, never render a literal null.
  write_policy "$home"
  run_surface "$home" "$snap"
  expect_code 0 "$RC" "the fleet surface must render under an active admission policy"
  assert_not_contains "$OUT" "· null" \
    "the capacity line must carry a reason for an active admission record"

  run_surface "$home" "$snap" alpha --json
  expect_code 0 "$RC" "the task surface must render"
  [ "$(printf '%s' "$OUT" | jq -r '.scope')" = task ] || fail "a task read must be task-scoped"
  [ "$(printf '%s' "$OUT" | jq -r '.work.id')" = alpha ] || fail "the task surface must carry the task"
  [ "$(printf '%s' "$OUT" | jq -r '.work.status_log_is_event_history_only')" = true ] \
    || fail "the surface must keep the status log marked as event history, never current state"

  # An id with no live record cannot be described. Rendering an empty surface
  # would invite exactly the confident-but-unsourced narration this prevents.
  run_surface "$home" "$snap" ghost-task
  expect_code 4 "$RC" "an unknown task must be unevaluable"
  assert_contains "$OUT" "no live record" "the refusal must name the missing record"

  pass "both scopes render and an unknown task is refused rather than narrated"
}

test_usage_errors_are_refused_before_any_read() {
  local home
  home=$(make_home usage)

  run_surface "$home" "" check
  expect_code 2 "$RC" "check with no claim is a usage error"
  run_surface "$home" "" check invented-claim
  expect_code 2 "$RC" "an unknown claim is a usage error"
  assert_contains "$OUT" "capacity-blocked" "the usage error must list the claims that exist"
  run_surface "$home" "" check decision-pending
  expect_code 2 "$RC" "a claim needing an id must refuse without one"
  run_surface "$home" "" alpha beta
  expect_code 2 "$RC" "two task ids is a usage error"
  run_surface "$home" "" --nonsense
  expect_code 2 "$RC" "an unknown option is a usage error"

  # A named subcommand after a task id must be refused in that order too, never
  # silently drop the task scope or reassign the target.
  run_surface "$home" "" alpha owners
  expect_code 2 "$RC" "a task id followed by owners is a usage error"
  run_surface "$home" "" alpha platform-seam
  expect_code 2 "$RC" "a task id followed by platform-seam is a usage error"
  run_surface "$home" "" alpha check decision-pending demo-decision-open
  expect_code 2 "$RC" "a task id followed by check must be refused, not silently retargeted"
  run_surface "$home" "" owners platform-seam
  expect_code 2 "$RC" "two named subcommands is a usage error"

  pass "usage errors are refused before any state is read"
}

# --- runner -----------------------------------------------------------------

test_capacity_claim_is_contradicted_while_the_fleet_admits_work
test_an_unevaluable_admission_forbids_the_claim_rather_than_passing_it
test_a_ruled_decision_cannot_be_reported_pending
test_dispatching_an_identity_already_in_flight_is_contradicted
test_an_incoherent_inventory_cannot_answer_the_duplicate_question
test_an_unreadable_census_is_unevaluable_for_every_census_backed_check
test_every_ledger_row_names_either_its_owner_or_the_capability_it_waits_for
test_the_platform_seam_is_wired_only_when_it_resolves_this_fleet_work
test_the_seam_takes_a_launcher_path_and_never_a_shell_command_line
test_a_probe_that_cannot_be_bounded_does_not_run
test_a_launcher_that_ignores_term_cannot_outlive_the_probe_bound
test_the_surface_renders_both_scopes_and_refuses_an_unknown_task
test_usage_errors_are_refused_before_any_read
