#!/usr/bin/env bash
# fm-decision-surface.sh - the resolved operational decision surface firstmate
# reads before reasoning about work, and the executable refusal for an
# operational claim that surface contradicts.
#
# WHY THIS EXISTS. Firstmate used to reconstruct deterministic operational truth
# conversationally: counting live workers, judging capacity, remembering what was
# in flight, deciding whether a decision was still open. Reconstruction drifts
# from the records, and the drift is silent - the incident this command exists to
# make impossible was firstmate reporting that queued work would dispatch "as
# capacity frees" while nothing in the fleet was capacity-bound at all. CODE
# already held every fact needed to refute that sentence; nothing made firstmate
# read it, and nothing refused the sentence.
#
# So this command owns two things and deliberately nothing else:
#
#   1. PROJECTION. It composes the already-landed deterministic owners into one
#      read-only surface (schema fm-decision-surface.v1) so firstmate consumes a
#      machine-produced answer instead of deriving one. It is a COMPOSER, never a
#      source: every field carries the owner it was read from, and this file adds
#      no fact of its own.
#
#   2. REFUSAL. `check` answers whether structured state CONTRADICTS a claim
#      firstmate is about to make. A contradicted claim is forbidden - not
#      "discouraged" - and the refusal names the reading that contradicts it.
#
# It never mutates. It takes no lock, drains no wake, spawns nothing, writes
# nothing, and touches no project.
#
# THE COMPENSATION LEDGER. `owners` prints the durable map of the deterministic
# work firstmate must not perform, each row naming either the landed owner that
# performs it or, where no owner has landed yet, the capability that must land
# before the compensating instruction can retire. A row is marked `pending`
# precisely so the gap stays visible: prose that compensates for an unowned fact
# is retained on purpose, not by oversight. `owners --json` is the machine form.
#
# THE PLATFORM SEAM. The deterministic platform publishes a richer projection
# (FirstMateDecisionSurface: why_not_now, allowed transitions, path health)
# through its own AXI surface. This command declares that seam and reports
# whether it is wired, but does NOT depend on it: the platform projection resolves
# platform work identities, and until it resolves this home's fleet task ids there
# is no live wiring to consume. `platform-seam` prints the contract and the exact
# condition that retires the marker. Point config/decision-surface-platform at the
# platform launcher to enable `--probe-platform`; docs/configuration.md
# "Platform decision-surface seam" owns that file's format.
#
# FAIL CLOSED. An unreadable census, an invalid admission policy, or an absent
# durable record is `unevaluable`, never a quiet pass. Unevaluable means firstmate
# may not assert the fact at all - not that the claim is safe.
#
# Usage:
#   fm-decision-surface.sh [--json] [--probe-platform]
#       Fleet-scope surface: capacity, live work, and open decisions.
#   fm-decision-surface.sh <task-id> [--json] [--probe-platform]
#       Task-scope surface: the fleet-scope fields plus that task's current
#       state, delivery posture, PR, and open decisions.
#   fm-decision-surface.sh check capacity-blocked
#       Is "blocked/waiting on capacity" contradicted by admission and census?
#   fm-decision-surface.sh check decision-pending <decision-id>
#       Is "this decision is still pending" contradicted by a ruled record?
#       <decision-id> is a backlog identity; bin/fm-decision-hold.sh id builds it.
#   fm-decision-surface.sh check duplicate-dispatch <task-id>
#       Is dispatching this identity contradicted by work already in flight?
#   fm-decision-surface.sh check certified <task-id>
#       Is "this work is certified" contradicted, or unevaluable, on the
#       evidence bound to its own bytes? bin/fm-certify.sh is the owner.
#   fm-decision-surface.sh owners [--json]
#       The compensation ledger: owned deterministic work, and pending gaps.
#   fm-decision-surface.sh platform-seam [--json] [--probe-platform]
#       The platform FirstMateDecisionSurface seam contract and its wiring state.
#   fm-decision-surface.sh --help
#
# Exit status is the verdict, so a caller that ignores stdout still stops safely:
#   0  rendered, or the claim is NOT contradicted
#   2  usage error
#   3  the claim IS contradicted by structured state - firstmate must not say it
#   4  unevaluable - no landed owner could answer, so the fact may not be asserted
#
# Environment:
#   FM_HOME                          operational home to read (default: repo root)
#   FM_DECISION_SURFACE_SNAPSHOT     read this fm-fleet-snapshot.v1 file instead
#                                    of running a fresh census (tests)
#   FM_DECISION_SURFACE_PLATFORM     override the platform launcher path
#   FM_DECISION_SURFACE_PROBE_TIMEOUT  seconds bounding one platform probe (120)

# shellcheck disable=SC2016  # single-quoted `$id`/`$schema` are jq program variables, not shell expansions.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# bin/fm-pr-lib.sh owns fm_task_id_path_safe, this fleet's one predicate for
# "may this task id be used to build a path?". Sourced rather than restated so a
# target this surface forwards is held to the same rule everywhere else applies.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

EXIT_OK=0
EXIT_USAGE=2
EXIT_CONTRADICTED=3
EXIT_UNEVALUABLE=4

SCHEMA=fm-decision-surface.v1

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-decision-surface.sh"
}

die() { printf 'fm-decision-surface: %s\n' "$1" >&2; exit "$EXIT_USAGE"; }

MODE=human
PROBE=0
SUBCOMMAND=
TARGET=
CHECK_CLAIM=

while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE=json ;;
    --probe-platform) PROBE=1 ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    check)
      [ -z "$SUBCOMMAND" ] || die "unexpected argument '$1'"
      SUBCOMMAND=check
      shift
      [ $# -gt 0 ] || die "check needs a claim: capacity-blocked, decision-pending, duplicate-dispatch, or certified"
      CHECK_CLAIM=$1
      case "$CHECK_CLAIM" in
        capacity-blocked) ;;
        decision-pending|duplicate-dispatch|certified)
          shift
          [ $# -gt 0 ] || die "check $CHECK_CLAIM needs an id"
          TARGET=$1
          # The certified claim is the one that hands its target to a command
          # which builds a path from it and then runs git in whatever repository
          # that path names. This surface composes owners; composing one is not
          # a licence to pass it an id nobody checked, so the id is REFUSED here
          # too rather than relied upon to be refused downstream.
          if [ "$CHECK_CLAIM" = certified ]; then
            fm_task_id_path_safe "$TARGET" || die "unsafe task id: $TARGET"
          fi
          ;;
        *) die "unknown claim '$CHECK_CLAIM': capacity-blocked, decision-pending, duplicate-dispatch, certified" ;;
      esac
      ;;
    owners)
      [ -z "$SUBCOMMAND" ] || die "unexpected argument '$1'"
      SUBCOMMAND=owners
      ;;
    platform-seam)
      [ -z "$SUBCOMMAND" ] || die "unexpected argument '$1'"
      SUBCOMMAND=platform-seam
      ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$SUBCOMMAND" ] || die "unexpected argument '$1'"
      [ -z "$TARGET" ] || die "one task id at a time"
      SUBCOMMAND=surface
      TARGET=$1
      ;;
  esac
  shift
done

[ -n "$SUBCOMMAND" ] || SUBCOMMAND=surface

command -v jq >/dev/null 2>&1 || {
  printf 'fm-decision-surface: jq is required to read structured fleet state\n' >&2
  exit "$EXIT_UNEVALUABLE"
}

# --- deterministic sources ---------------------------------------------------
#
# Every reader below is one already-landed owner. Read failures are recorded, not
# swallowed: SNAPSHOT_OK and ADMISSION_OK gate every verdict that depends on them.

SNAPSHOT=
SNAPSHOT_OK=0
read_snapshot() {
  [ "$SNAPSHOT_OK" -eq 0 ] || return 0
  local raw
  if [ -n "${FM_DECISION_SURFACE_SNAPSHOT:-}" ]; then
    [ -r "$FM_DECISION_SURFACE_SNAPSHOT" ] || return 1
    raw=$(cat "$FM_DECISION_SURFACE_SNAPSHOT") || return 1
  else
    raw=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || return 1
  fi
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e 'has("tasks")' >/dev/null 2>&1 || return 1
  SNAPSHOT=$raw
  SNAPSHOT_OK=1
  return 0
}

ADMISSION=
ADMISSION_OK=0
read_admission() {
  [ "$ADMISSION_OK" -eq 0 ] || return 0
  local raw rc
  raw=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-admission.sh" --json 2>/dev/null)
  rc=$?
  # Exit 2 is a malformed policy or an unevaluable census. Bands 3 and 4 are
  # legitimate refusals that still carry a decision record.
  [ "$rc" -ne 2 ] || return 1
  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | jq -e '.schema == "fm-admission.v1"' >/dev/null 2>&1 || return 1
  ADMISSION=$raw
  ADMISSION_OK=1
  return 0
}

snap() { printf '%s' "$SNAPSHOT" | jq "$@"; }

# An inactive admission record explains itself in .reason; an active one
# explains itself through the rules that actually controlled the band.
JQ_ADMISSION_REASON='def admission_reason:
  .reason
  // (if (.controlling_rules // []) | length > 0
      then "controlling rules: " + (.controlling_rules | join(", "))
      else "no controlling rule recorded" end);'

# --- the compensation ledger -------------------------------------------------
#
# One row per piece of deterministic work firstmate must not perform. `owner` is
# the landed command or schema that performs it; a `pending` row has no fleet
# owner yet and names the capability that must land before the instruction
# surface may stop compensating. Keep this list and the instruction surface in
# step: retiring a compensating instruction without flipping its row here is what
# leaves a silent gap.

owners_json() {
  cat <<'JSON'
[
 {"compensation":"counting_workers","status":"owned",
  "owner":"bin/fm-fleet-snapshot.sh --json .tasks",
  "note":"the census is one row per live task record"},
 {"compensation":"checking_capacity","status":"owned",
  "owner":"bin/fm-admission.sh --json",
  "note":"task-independent band and action, with the per-rule explanation"},
 {"compensation":"polling","status":"owned",
  "owner":"bin/fm-watch.sh through the emitted supervision protocol",
  "note":"firstmate waits on wakes; it never polls for state"},
 {"compensation":"known_dependencies","status":"owned",
  "owner":"bin/fm-fleet-snapshot.sh --json .backlog.records[].unresolved_blocker_ids",
  "note":"a blocker resolves only when its own record is Done"},
 {"compensation":"pr_existence","status":"owned",
  "owner":"bin/fm-fleet-snapshot.sh --json .tasks[].pr and bin/fm-pr-check.sh",
  "note":"the recorded pr= and the forge head, not a remembered URL"},
 {"compensation":"verifier_passed","status":"owned",
  "owner":"bin/fm-crew-state.sh",
  "note":"run-step attribution bound to branch and code identity; a claim the run's own evidence does not record reports blocked"},
 {"compensation":"work_landed","status":"owned",
  "owner":"bin/fm-landed-lib.sh and bin/fm-pr-merge.sh merge_verification=",
  "note":"landing is re-verified against the current head, never remembered"},
 {"compensation":"terminal_state","status":"owned",
  "owner":"bin/fm-wake-ledger.sh task --outcome landed|failed|abandoned",
  "note":"every terminal outcome is representable, so exhaustion cannot read as success"},
 {"compensation":"remembering_in_flight_work","status":"owned",
  "owner":"bin/fm-session-start.sh digest over state/<id>.meta",
  "note":"durable records and live endpoints are authoritative, not conversation memory"},
 {"compensation":"reconciling_known_identifiers","status":"owned",
  "owner":"bin/fm-fleet-snapshot.sh --json .main_inventory",
  "note":"orphan in-flight rows and unstructured rows are reported, not inferred"},
 {"compensation":"duplicate_work","status":"owned",
  "owner":"fm-decision-surface.sh check duplicate-dispatch",
  "note":"identity-level only; semantic overlap between differently-named work is not yet derived"},
 {"compensation":"budgets","status":"owned",
  "owner":"config/models.json concurrency cap enforced at bin/fm-spawn.sh, plus quota-axi",
  "note":"a model over its recorded cap is refused at spawn, not reasoned about"},
 {"compensation":"loopspec_continuation","status":"owned",
  "owner":"bin/fm-loopspec.sh state|claim|finish",
  "note":"iteration memory is persisted; a repeated event key is refused"},
 {"compensation":"attempt_and_retry_counting","status":"owned",
  "owner":"bin/fm-attempt.sh over state/<id>.attempt",
  "note":"retry is arithmetic over a recorded count, and exhaustion is a named terminal stop rather than a judgment made inside the worker that is failing"},
 {"compensation":"verifier_independence","status":"owned",
  "owner":"bin/fm-independence-lib.sh, refused at bin/fm-certify.sh and fm-decision-surface.sh check certified",
  "note":"independence is derived per dimension from invocation-time evidence and this fleet's declared routing config; there is no argument anywhere that can assert it, and an unobservable dimension can never read as independent"},
 {"compensation":"certification_claim","status":"owned",
  "owner":"bin/fm-certify.sh",
  "note":"CERTIFIED is computed over the applicable predicates for those exact bytes; a route that structurally cannot produce a piece of evidence reports not-applicable with its route rather than being forced into a pass or a failure"},
 {"compensation":"verifier_verdict_vocabulary","status":"pending",
  "owner":null,
  "pending_owner":"a shared PASS/FAIL/NO_VERIFIER_RAN verdict contract spanning every verifier, so no unobserved result can pass",
  "note":"bin/fm-crew-state.sh already refuses an uncorroborated checks-passed claim, but each verifier still reports in its own vocabulary"},
 {"compensation":"invoking_known_next_stage","status":"pending",
  "owner":null,
  "pending_owner":"a direct pipeline invocation replacing the harness keystroke handoff, after the shared verifier verdict lands",
  "note":"firstmate still triggers validation on the worker; the keystroke transition retires with its replacement, not before"},
 {"compensation":"deadline_and_time_gate_elapsed","status":"pending",
  "owner":null,
  "pending_owner":"a backlog time-gate evaluator that reports which queued work has become eligible",
  "note":"queued time gates are still re-read by firstmate at teardown and heartbeat"},
 {"compensation":"transition_legality","status":"pending",
  "owner":null,
  "pending_owner":"the platform allowed-transition projection resolved for a fleet work identity",
  "note":"see platform-seam; the projection exists but resolves platform identities only"},
 {"compensation":"why_not_now","status":"pending",
  "owner":null,
  "pending_owner":"the platform why_not_now primitive resolved for a fleet work identity",
  "note":"check capacity-blocked is the fleet-side subset that is answerable today"},
 {"compensation":"path_health","status":"pending",
  "owner":null,
  "pending_owner":"the platform path-health invariant model resolved for a fleet work identity",
  "note":"see platform-seam"},
 {"compensation":"deterministic_progression","status":"pending",
  "owner":null,
  "pending_owner":"platform transition actuation, so a deterministic transition costs no model turn",
  "note":"firstmate still advances lifecycle steps that CODE could advance alone"}
]
JSON
}

render_owners() {
  if [ "$MODE" = json ]; then
    owners_json | jq --arg schema "$SCHEMA" \
      '{schema:$schema, record_kind:"compensation_ledger", rows:.}'
    return "$EXIT_OK"
  fi
  printf 'Deterministic work firstmate must not perform, and who performs it.\n\n'
  owners_json | jq -r '
    .[] | select(.status == "owned")
    | "  owned    \(.compensation)\n           owner: \(.owner)"'
  printf '\n'
  owners_json | jq -r '
    .[] | select(.status == "pending")
    | "  PENDING  \(.compensation)\n           needs: \(.pending_owner)\n           until then: \(.note)"'
  printf '\nA pending row means the compensating instruction is retained on purpose.\n'
  return "$EXIT_OK"
}

# --- the platform seam -------------------------------------------------------

# The configured value is ONE path to the platform AXI launcher, never a command
# line: the arguments are this script's own, so a private config file can never
# become a shell-execution seam. A launcher path may contain spaces and is always
# invoked quoted.
platform_launcher() {
  if [ -n "${FM_DECISION_SURFACE_PLATFORM:-}" ]; then
    printf '%s' "$FM_DECISION_SURFACE_PLATFORM"
    return 0
  fi
  if [ -r "$CONFIG/decision-surface-platform" ]; then
    awk 'NF && $0 !~ /^[[:space:]]*#/ { sub(/[[:space:]]+$/, ""); print; exit }' \
      "$CONFIG/decision-surface-platform"
    return 0
  fi
  return 1
}

# A probe must be bounded on every supported host, so an unresponsive platform
# cannot wedge a read. With no bounding tool available the probe does not run at
# all: reporting the seam unreachable is the honest answer, and it is also the
# answer that keeps the seam marked not-wired.
FM_DECISION_SURFACE_PROBE_TIMEOUT=${FM_DECISION_SURFACE_PROBE_TIMEOUT:-120}
run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 5 "$seconds" "$@"
  else
    return 124
  fi
}

# Reachability is only ever reported from an actual probe. Absent a probe the
# state is "not_checked", never an optimistic guess.
platform_seam_json() {
  local launcher configured reachable live_ids wiring probe_out
  configured=absent
  reachable=not_checked
  live_ids=null
  if launcher=$(platform_launcher) && [ -n "$launcher" ]; then
    configured=present
  else
    launcher=
  fi
  if [ "$PROBE" -eq 1 ] && [ -n "$launcher" ]; then
    reachable=false
    if [ -x "$launcher" ] &&
       probe_out=$(run_timed "$FM_DECISION_SURFACE_PROBE_TIMEOUT" \
         "$launcher" decision-surface --fleet 2>/dev/null) &&
       [ -n "$probe_out" ]; then
      reachable=true
      live_ids=0
      if read_snapshot; then
        local id nl tokens
        nl=$'\n'
        tokens=$nl$(printf '%s' "$probe_out" | tr -c 'A-Za-z0-9._-' "$nl")$nl
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          case "$tokens" in
            *"$nl$id$nl"*) live_ids=$((live_ids + 1)) ;;
          esac
        done <<EOF
$(snap -r '.tasks[].id')
EOF
      else
        live_ids=null
      fi
    fi
  fi
  # The seam is wired only when the platform projection actually resolves work
  # this home is running. A reachable command that names none of this fleet's
  # tasks is a projection of other identities, not live wiring.
  wiring=not-wired
  if [ "$reachable" = true ] && [ "$live_ids" != null ] && [ "${live_ids:-0}" -gt 0 ]; then
    wiring=wired
  fi
  jq -n \
    --arg schema "$SCHEMA" \
    --arg configured "$configured" \
    --arg reachable "$reachable" \
    --arg wiring "$wiring" \
    --argjson live_ids "${live_ids:-null}" \
    --arg launcher "${launcher:-}" \
    '{
      schema: $schema,
      record_kind: "platform_seam",
      surface: "FirstMateDecisionSurface",
      producer_operation: "rt.decision_surface",
      axi_commands: ["decision-surface <work_id>", "decision-surface --fleet"],
      fields_owned_there: ["why_not_now","available_transitions","forbidden_transitions","path_health","verification_state","review_state","certification_state","authority","reasoning_required","genuine_engineer_decisions"],
      launcher_config: "config/decision-surface-platform",
      launcher: (if $launcher == "" then null else $launcher end),
      configured: $configured,
      reachable: $reachable,
      fleet_identities_resolved: $live_ids,
      wiring: $wiring,
      retires_marker_when: "the platform projection resolves this home fleet task ids, so a fleet task can be looked up by identity rather than by a platform work id",
      consumption_rule: "when wired, the platform projection is authoritative for the fields it owns and this composer defers to it; it is never reconstructed here"
    }'
}

render_platform_seam() {
  local doc
  doc=$(platform_seam_json) || return "$EXIT_UNEVALUABLE"
  if [ "$MODE" = json ]; then
    printf '%s\n' "$doc"
    return "$EXIT_OK"
  fi
  printf '%s\n' "$doc" | jq -r '
    "platform surface: \(.surface) (\(.producer_operation))",
    "  commands:   \(.axi_commands | join(" | "))",
    "  launcher:   \(.launcher // "not configured (\(.launcher_config))")",
    "  configured: \(.configured)",
    "  reachable:  \(.reachable)",
    "  wiring:     \(.wiring)",
    "  owns:       \(.fields_owned_there | join(", "))",
    "  retires when: \(.retires_marker_when)"'
  return "$EXIT_OK"
}

# --- the surface -------------------------------------------------------------

surface_json() {
  local seam admission_doc task_doc
  seam=$(platform_seam_json)
  if read_admission; then
    admission_doc=$ADMISSION
  else
    admission_doc='null'
  fi
  task_doc='null'
  if [ -n "$TARGET" ]; then
    task_doc=$(snap --arg id "$TARGET" '
      (.tasks[] | select(.id == $id)) // null
      | if . == null then null else {
          id, role, deliverable, stage, mode, yolo, project, harness, backend,
          current_state,
          endpoint: {target: .endpoint.target, exists: .endpoint.exists, status: .endpoint.status},
          pr,
          open_decisions: .hints.open_decisions,
          status_log_is_event_history_only: true
        } end')
  fi
  jq -n \
    --arg schema "$SCHEMA" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg fm_home "$FM_HOME" \
    --arg scope "$([ -n "$TARGET" ] && echo task || echo fleet)" \
    --arg target "${TARGET:-}" \
    --argjson admission "$admission_doc" \
    --argjson task "${task_doc:-null}" \
    --argjson seam "$seam" \
    --argjson census "$(snap '{
        live_task_count: (.tasks | length),
        live_task_ids: [.tasks[].id],
        inventory_valid: .main_inventory.valid,
        inventory_reason: .main_inventory.reason,
        orphan_in_flight: .main_inventory.orphan_in_flight,
        generated: .generated
      }')" \
    --argjson decisions "$(snap '[
        .backlog.records[]
        | select(.structured == true and .hold_kind != null and .state != "done")
        | {id, title, hold_kind, hold_reason, state}
      ]')" \
    --argjson pending "$(owners_json | jq '[.[] | select(.status == "pending") | {compensation, pending_owner}]')" \
    '{
      schema: $schema,
      record_kind: "decision_surface",
      generated: $generated,
      fm_home: $fm_home,
      scope: $scope,
      work_id: (if $target == "" then null else $target end),
      consumption_contract: {
        deterministic_truth_owner: "CODE",
        firstmate_must_consume_before_reasoning: true,
        firstmate_must_not_reconstruct_deterministic_truth: true,
        firstmate_may_interpret_and_explain: true,
        invariant: "No firstmate prose may contradict this surface capacity, dependency, decision, in-flight, verifier, or landing fields."
      },
      census: $census,
      capacity: $admission,
      work: $task,
      open_decisions: $decisions,
      owner_pending: $pending,
      platform_seam: $seam
    }'
}

render_surface() {
  read_snapshot || {
    printf 'fm-decision-surface: fleet census unreadable; no operational fact may be asserted from it\n' >&2
    return "$EXIT_UNEVALUABLE"
  }
  if [ -n "$TARGET" ] && [ "$(snap -r --arg id "$TARGET" '[.tasks[] | select(.id == $id)] | length')" = 0 ]; then
    printf 'fm-decision-surface: no live record for task %s\n' "$TARGET" >&2
    return "$EXIT_UNEVALUABLE"
  fi
  local doc
  doc=$(surface_json) || return "$EXIT_UNEVALUABLE"
  if [ "$MODE" = json ]; then
    printf '%s\n' "$doc"
    return "$EXIT_OK"
  fi
  printf '%s\n' "$doc" | jq -r "$JQ_ADMISSION_REASON"'
    "decision surface · scope: \(.scope)\(if .work_id then " · work: \(.work_id)" else "" end)",
    "  live work:  \(.census.live_task_count)\(if (.census.live_task_ids | length) > 0 then " (\(.census.live_task_ids | join(", ")))" else "" end)",
    "  census:     \(if .census.inventory_valid then "coherent" else "INCOHERENT - \(.census.inventory_reason)" end)",
    "  capacity:   \(if .capacity == null then "UNEVALUABLE" else "\(.capacity.decision_band) · \(.capacity.action) · \(.capacity | admission_reason)" end)",
    (if .work != null then "  state:      \(.work.current_state.raw)" else empty end),
    (if .work != null then "  delivery:   mode=\(.work.mode) yolo=\(.work.yolo) pr=\(.work.pr.url // "none")" else empty end),
    "  decisions:  \(if (.open_decisions | length) == 0 then "none open" else ([.open_decisions[].id] | join(", ")) end)",
    "  platform:   \(.platform_seam.wiring) (\(.platform_seam.configured))",
    "  pending:    \([.owner_pending[].compensation] | join(", "))"'
  return "$EXIT_OK"
}

# --- claim checks ------------------------------------------------------------
#
# Each check answers exactly one question: does structured state CONTRADICT this
# claim? A verdict of not-contradicted is not a warrant that the claim is true -
# it only means no landed owner refutes it.

verdict() {  # <verdict> <claim> <evidence>
  printf 'check: %s · verdict: %s · %s\n' "$2" "$1" "$3"
  case "$1" in
    contradicted) return "$EXIT_CONTRADICTED" ;;
    unevaluable) return "$EXIT_UNEVALUABLE" ;;
    *) return "$EXIT_OK" ;;
  esac
}

check_capacity_blocked() {
  read_admission || {
    verdict unevaluable capacity-blocked \
      "admission could not be evaluated; capacity is unknown, so no capacity blocker may be asserted"
    return $?
  }
  local action band reason configured
  action=$(printf '%s' "$ADMISSION" | jq -r '.action')
  band=$(printf '%s' "$ADMISSION" | jq -r '.decision_band')
  reason=$(printf '%s' "$ADMISSION" | jq -r "$JQ_ADMISSION_REASON"' admission_reason')
  configured=$(printf '%s' "$ADMISSION" | jq -r '.configured // "active"')
  local census='census unread'
  if read_snapshot; then
    census="live work=$(snap -r '.tasks | length')"
  fi
  if [ "$action" = admit ]; then
    verdict contradicted capacity-blocked \
      "admission band=$band action=admit ($configured; $reason) · $census · the fleet accepts another task now"
    return $?
  fi
  verdict not-contradicted capacity-blocked \
    "admission band=$band action=$action · $reason · $census"
}

check_decision_pending() {
  read_snapshot || {
    verdict unevaluable decision-pending "fleet census unreadable; the decision record could not be read"
    return $?
  }
  local rec
  rec=$(snap --arg id "$TARGET" '[.backlog.records[] | select(.structured == true and .id == $id)] | first // null')
  if [ "$rec" = null ] || [ -z "$rec" ]; then
    verdict unevaluable "decision-pending $TARGET" \
      "no durable decision record exists; open one with bin/fm-decision-hold.sh before reporting its status"
    return $?
  fi
  local state
  state=$(printf '%s' "$rec" | jq -r '.state')
  if [ "$state" = "done" ]; then
    verdict contradicted "decision-pending $TARGET" \
      "the decision record is Done ($(printf '%s' "$rec" | jq -r '.title // "no title"')) · it is ruled, not pending"
    return $?
  fi
  verdict not-contradicted "decision-pending $TARGET" \
    "the decision record is $state and still open"
}

# "Certified" is the claim this fleet could least afford to have been writable:
# a closure audit found the durable record asserting certified work while the
# attestation namespace held one note, for a commit not even on the trunk.
# bin/fm-certify.sh owns the predicate; this composes it, so firstmate reads a
# machine-produced answer instead of deriving one. A predicate that could not be
# observed is unevaluable, NOT a pass: unevaluable means the fact may not be
# asserted at all.
check_certified() {
  local certify out rc
  certify="$SCRIPT_DIR/fm-certify.sh"
  if [ ! -x "$certify" ]; then
    verdict unevaluable "certified $TARGET" \
      "the certification predicate is not executable at $certify; certification cannot be evaluated"
    return $?
  fi
  # BOUNDED, like every other thing this surface reaches that can leave the
  # machine. The certification predicate reads a recorded pull request's check
  # rollup through `gh`, which imposes no bound of its own, and this command is
  # contracted as a cheap local read that agents run before asserting a fact. A
  # hung network call must not be able to hold that read open, so it is bounded
  # by the same budget the platform probe uses and a timeout is reported as
  # unevaluable - never as a claim that could not be contradicted.
  out=$(run_timed "$FM_DECISION_SURFACE_PROBE_TIMEOUT" "$certify" "$TARGET" 2>&1) && rc=0 || rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    verdict unevaluable "certified $TARGET" \
      "the certification predicate could not be bounded or did not finish within ${FM_DECISION_SURFACE_PROBE_TIMEOUT}s; a read that cannot be bounded is not made from this surface"
    return $?
  fi
  case "$rc" in
    0)
      verdict not-contradicted "certified $TARGET" \
        "$(printf '%s' "$out" | head -1)"
      ;;
    3)
      verdict contradicted "certified $TARGET" \
        "a required certification predicate was observed unmet · $(printf '%s' "$out" | sed -n 's/^gap=/gap /p' | head -1)"
      ;;
    4)
      verdict unevaluable "certified $TARGET" \
        "a required certification predicate could not be observed · $(printf '%s' "$out" | sed -n 's/^gap=/gap /p' | head -1)"
      ;;
    *)
      verdict unevaluable "certified $TARGET" \
        "the certification predicate reached no verdict: $(printf '%s' "$out" | head -1)"
      ;;
  esac
}

check_duplicate_dispatch() {
  read_snapshot || {
    verdict unevaluable duplicate-dispatch "fleet census unreadable; existing work could not be enumerated"
    return $?
  }
  # An incoherent inventory cannot answer "is this already running?" - a missing
  # child record is exactly the shape a duplicate hides in.
  if [ "$(snap -r '.main_inventory.valid')" != true ]; then
    verdict unevaluable "duplicate-dispatch $TARGET" \
      "the current inventory is incoherent ($(snap -r '.main_inventory.reason // "no reason recorded"')); repair it before dispatching"
    return $?
  fi
  local live backlog_state
  live=$(snap -r --arg id "$TARGET" '[.tasks[] | select(.id == $id)] | length')
  backlog_state=$(snap -r --arg id "$TARGET" \
    '[.backlog.records[] | select(.structured == true and .id == $id) | .state] | first // ""')
  if [ "$live" != 0 ]; then
    local st
    st=$(snap -r --arg id "$TARGET" '.tasks[] | select(.id == $id) | .current_state.raw')
    verdict contradicted "duplicate-dispatch $TARGET" \
      "work already exists under this identity · $st · steer or reconcile it rather than dispatching a second"
    return $?
  fi
  if [ "$backlog_state" = in_flight ]; then
    verdict contradicted "duplicate-dispatch $TARGET" \
      "the backlog records this identity as in flight · reconcile the record before dispatching"
    return $?
  fi
  verdict not-contradicted "duplicate-dispatch $TARGET" \
    "no live task record and no in-flight backlog row under this identity"
}

case "$SUBCOMMAND" in
  owners) render_owners; exit $? ;;
  platform-seam) render_platform_seam; exit $? ;;
  surface) render_surface; exit $? ;;
  check)
    case "$CHECK_CLAIM" in
      capacity-blocked) check_capacity_blocked; exit $? ;;
      decision-pending) check_decision_pending; exit $? ;;
      duplicate-dispatch) check_duplicate_dispatch; exit $? ;;
      certified) check_certified; exit $? ;;
    esac
    ;;
esac

die "unhandled subcommand"
