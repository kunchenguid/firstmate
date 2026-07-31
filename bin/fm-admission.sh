#!/usr/bin/env bash
# fm-admission.sh - read-only fleet admission decision from a fresh census.
#
# Admission control is the third layer above routing and scheduling: it answers
# "should the fleet accept another task right now?" from properties of the FLEET
# ALONE. It is deliberately task-independent - this command takes no task
# argument and refuses one - so the same snapshot returns the same band for every
# incoming task. Anything that varies per task (tier, project, model, priority,
# urgency, token estimate, file overlap) belongs to routing or scheduling.
#
# The command is read-only: it does not acquire the session lock, hold or unhold
# backlog items, spawn, mutate task state, or write any record. It observes and
# explains; the caller applies the outcome. The decision procedure for each band
# is owned by .agents/skills/fleet-admission/SKILL.md, and the policy schema by
# docs/configuration.md "Fleet admission control".
#
# Usage:
#   fm-admission.sh                    human-readable band and per-rule explanation
#   fm-admission.sh --brief            one summary line (session-start/teardown use)
#   fm-admission.sh --json             the decision record (schema fm-admission.v1)
#   fm-admission.sh --snapshot <path>  evaluate an already-taken fleet snapshot
#                                      instead of running fm-fleet-snapshot.sh;
#                                      its age is then checked against the
#                                      configured freshness limit
#   fm-admission.sh validate           validate policy only; print the reason on
#                                      stdout and exit 2 when malformed
#   fm-admission.sh --help             print this header
#
# Exit status is the band, so a caller that ignores the output still stops safely:
#   0  admit      - preferred, or admission is not configured for this home
#   2  refuse     - policy is malformed or the census could not be evaluated
#   3  defer      - soft
#   4  refuse     - hard
#
# Every non-preferred result names, for each rule: the observed value, its source
# and freshness, the exact JSON configuration path, the configured value, and the
# resulting band. Numbers are never embedded here; a threshold this file cannot
# read from configuration does not exist.
#
# Stage 1 scope: only deterministic safety conditions enforce (authority,
# census integrity, snapshot freshness). Every other signal is recorded as an
# observation and cannot change the band - see the policy schema's
# enforcement_mode. Backlog consistency is its own signal precisely so an
# unrelated backlog contradiction is reported and repaired without being
# misread as physical fleet saturation.
#
# Telemetry seam: the decision record printed by --json is the unit of admission
# telemetry. When the wake-outcome ledger exposes its extension seam, append this
# record in the ledger owner's format; admission never opens a competing store.
#
# Environment:
#   FM_ADMISSION_NOW_EPOCH   override the decision clock (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-admission-lib.sh
. "$SCRIPT_DIR/fm-admission-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-admission.sh"
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

MODE=human
SNAPSHOT_FILE=
VALIDATE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) MODE=json ;;
    --brief) MODE=brief ;;
    --snapshot) shift; [ $# -gt 0 ] || die "--snapshot needs a path"; SNAPSHOT_FILE=$1 ;;
    --snapshot=*) SNAPSHOT_FILE=${1#--snapshot=} ;;
    validate) VALIDATE_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option $1" ;;
    # A task id here would make admission task-dependent, which is the one thing
    # this layer must never be. Refuse loudly rather than silently ignoring it.
    *) die "fm-admission.sh takes no task argument: admission inspects fleet state only, never the incoming task" ;;
  esac
  shift
done

CONFIG_FILE=$(fm_admission_config_file "$CONFIG")
REASON=$(fm_admission_validate_reason "$CONFIG_FILE") || true
if [ -n "$REASON" ]; then
  printf 'admission policy invalid: config/crew-dispatch.json - %s\n' "$REASON"
  exit 2
fi
[ "$VALIDATE_ONLY" -eq 1 ] && exit 0

STATE_KIND=$(fm_admission_state "$CONFIG_FILE")
if [ "$STATE_KIND" != active ]; then
  case "$MODE" in
    json)
      printf '{"schema":"fm-admission.v1","record_kind":"admission","active":false,'
      printf '"configured":"%s","decision_band":"preferred","action":"admit",' "$STATE_KIND"
      printf '"config_path":"/_scheduling/admission_control",'
      printf '"reason":"admission control is not configured for this home",'
      printf '"notification_band":"silent","task_id":null}\n'
      ;;
    *)
      printf 'admission: not configured (%s) - dispatch is unchanged\n' "$STATE_KIND"
      ;;
  esac
  exit 0
fi

command -v jq >/dev/null 2>&1 || die "jq is required to evaluate admission policy"

NOW_EPOCH=${FM_ADMISSION_NOW_EPOCH:-$(date -u +%s)}
TIMESTAMP=$(date -u -r "$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$NOW_EPOCH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u +%Y-%m-%dT%H:%M:%SZ)

# --- fresh census ----------------------------------------------------------
# bin/fm-fleet-snapshot.sh is the single owner of reading task metadata, current
# state, and backlog structure; admission composes its output rather than
# re-parsing state files.
if [ -n "$SNAPSHOT_FILE" ]; then
  [ -f "$SNAPSHOT_FILE" ] || die "snapshot file not found: $SNAPSHOT_FILE"
  SNAPSHOT=$(cat "$SNAPSHOT_FILE") || die "cannot read snapshot: $SNAPSHOT_FILE"
else
  SNAPSHOT=$("$FM_ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null) || SNAPSHOT=
fi

CENSUS_READABLE=true
if [ -z "$SNAPSHOT" ] || ! printf '%s' "$SNAPSHOT" | jq -e '.schema == "fm-fleet-snapshot.v1"' >/dev/null 2>&1; then
  CENSUS_READABLE=false
  SNAPSHOT='{"schema":"fm-fleet-snapshot.v1","generated":null,"tasks":[],"backlog":{"records":[]},"main_inventory":{"valid":null,"reason":"census unreadable"}}'
fi

SNAPSHOT_GENERATED=$(printf '%s' "$SNAPSHOT" | jq -r '.generated // empty')
if [ -n "$SNAPSHOT_GENERATED" ]; then
  SNAPSHOT_EPOCH=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$SNAPSHOT_GENERATED" +%s 2>/dev/null \
    || date -u -d "$SNAPSHOT_GENERATED" +%s 2>/dev/null || printf '')
else
  SNAPSHOT_EPOCH=
fi
case "$SNAPSHOT_EPOCH" in
  ''|*[!0-9]*) SNAPSHOT_AGE=null ;;
  *) SNAPSHOT_AGE=$(( NOW_EPOCH - SNAPSHOT_EPOCH )); [ "$SNAPSHOT_AGE" -lt 0 ] && SNAPSHOT_AGE=0 ;;
esac

POLICY=$(fm_admission_object "$CONFIG_FILE")
CONFIG_DIGEST=$(fm_admission_digest "$POLICY")
SNAPSHOT_ID=$(fm_admission_digest "$(printf '%s' "$SNAPSHOT" | jq -S -c .)")

# --- single-primary authority ----------------------------------------------
# The per-home session lock already serializes intake, so it IS the admission
# authority. No new process, daemon, or reservation store is introduced.
if fm_session_lock_owned_by_self "$STATE"; then
  AUTHORITY_HELD=true
  AUTHORITY_DETAIL="session lock held by this session"
elif [ -f "$STATE/.lock" ]; then
  AUTHORITY_HELD=false
  AUTHORITY_DETAIL="session lock is not held by this session"
else
  AUTHORITY_HELD=false
  AUTHORITY_DETAIL="no session lock is held for this home"
fi

DECISION_ID=$(fm_admission_digest "$SNAPSHOT_ID|$CONFIG_DIGEST|$TIMESTAMP")

RECORD=$(printf '%s' "$SNAPSHOT" | jq \
  --argjson policy "$POLICY" \
  --arg timestamp "$TIMESTAMP" \
  --argjson snapshot_age "$SNAPSHOT_AGE" \
  --argjson census_readable "$CENSUS_READABLE" \
  --argjson authority_held "$AUTHORITY_HELD" \
  --arg authority_detail "$AUTHORITY_DETAIL" \
  --arg config_digest "$CONFIG_DIGEST" \
  --arg snapshot_id "$SNAPSHOT_ID" \
  --arg decision_id "$DECISION_ID" \
  --arg home "$FM_HOME" '
  def rank: {"preferred":0,"soft":1,"hard":2};
  def worse($a; $b): if rank[$a] >= rank[$b] then $a else $b end;
  def cfg($path): "/_scheduling/admission_control" + $path;

  . as $snap
  | $policy as $p
  | ($p.signals // {}) as $sig
  | ($snap.tasks // []) as $tasks
  | ([$tasks[].id] | group_by(.) | map(select(length > 1) | .[0])) as $dupes
  | ([$snap.backlog.records[]? | select(.hold_kind == "load")] | length) as $load_holds
  | ([$tasks[] | select((.current_state.state // "") == "")] | length) as $unknown_state
  | ($snapshot_age != null and ($sig.census_integrity.max_snapshot_age_seconds != null)
     and ($snapshot_age > $sig.census_integrity.max_snapshot_age_seconds)) as $stale
  | ($snapshot_age == null and ($sig.census_integrity.max_snapshot_age_seconds != null)) as $age_unmeasurable

  # Every rule carries the same five parts: observed value, source and
  # freshness, config path, configured value, resulting band.
  | ([
      {
        rule_id: "authority.single_primary",
        signal: "authority.session_lock",
        observed: (if $authority_held then "held" else "not-held" end),
        detail: $authority_detail,
        unit: "state",
        source: "per-home-session-lock",
        observed_at: $timestamp,
        freshness_seconds: 0,
        valid: true,
        config_path: cfg("/authority/unreachable_band"),
        operator: "authority-held",
        configured_value: ($p.authority.unreachable_band // "hard"),
        result: (if $authority_held then "preferred" else ($p.authority.unreachable_band // "hard") end)
      },
      {
        rule_id: "census_integrity.inventory",
        signal: "census_integrity.inventory_readable",
        observed: $census_readable,
        unit: "boolean",
        source: ($sig.census_integrity.source // "fresh-authority-census"),
        observed_at: ($snap.generated // $timestamp),
        freshness_seconds: $snapshot_age,
        valid: $census_readable,
        config_path: cfg("/signals/census_integrity/unknown_band"),
        operator: "readable",
        configured_value: ($sig.census_integrity.unknown_band // $p.unknown_band),
        result: (if $census_readable then "preferred"
                 else ($sig.census_integrity.unknown_band // $p.unknown_band) end)
      },
      {
        rule_id: "census_integrity.duplicate_identities",
        signal: "census_integrity.duplicate_task_ids",
        observed: ($dupes | length),
        detail: ($dupes | join(", ")),
        unit: "count",
        source: ($sig.census_integrity.source // "fresh-authority-census"),
        observed_at: ($snap.generated // $timestamp),
        freshness_seconds: $snapshot_age,
        valid: $census_readable,
        config_path: cfg("/signals/census_integrity/unknown_band"),
        operator: "==0",
        configured_value: ($sig.census_integrity.unknown_band // $p.unknown_band),
        result: (if ($dupes | length) == 0 then "preferred"
                 else ($sig.census_integrity.unknown_band // $p.unknown_band) end)
      },
      {
        rule_id: "census_integrity.snapshot_age",
        signal: "census_integrity.snapshot_age_seconds",
        observed: $snapshot_age,
        unit: "seconds",
        source: ($sig.census_integrity.source // "fresh-authority-census"),
        observed_at: ($snap.generated // $timestamp),
        freshness_seconds: $snapshot_age,
        valid: ($snapshot_age != null),
        config_path: cfg("/signals/census_integrity/max_snapshot_age_seconds"),
        operator: ">",
        configured_value: $sig.census_integrity.max_snapshot_age_seconds,
        result: (if $stale or $age_unmeasurable then ($sig.census_integrity.unknown_band // $p.unknown_band)
                 else "preferred" end)
      },
      {
        rule_id: "backlog_consistency.main_inventory",
        signal: "backlog_consistency.main_inventory_valid",
        observed: ($snap.main_inventory.valid),
        detail: ($snap.main_inventory.reason // ""),
        unit: "boolean",
        source: ($sig.backlog_consistency.source // "main-inventory"),
        observed_at: ($snap.generated // $timestamp),
        freshness_seconds: $snapshot_age,
        valid: true,
        config_path: cfg("/signals/backlog_consistency/enforce"),
        operator: "observe",
        configured_value: ($sig.backlog_consistency.enforce // false),
        result: "preferred",
        note: "backlog consistency is a separate health signal; a contradiction here must be repaired but is not physical fleet saturation"
      },
      {
        rule_id: "admission_queue_pressure.load_hold_depth",
        signal: "admission_queue_pressure.queued_count",
        observed: $load_holds,
        unit: "count",
        source: ($sig.admission_queue_pressure.source // "tasks-axi-load-holds-plus-ledger"),
        observed_at: ($snap.generated // $timestamp),
        freshness_seconds: $snapshot_age,
        valid: true,
        config_path: cfg("/signals/admission_queue_pressure/enforce"),
        operator: "observe",
        configured_value: ($sig.admission_queue_pressure.enforce // false),
        result: "preferred"
      },
      {
        rule_id: "admission_queue_pressure.oldest_wait",
        signal: "admission_queue_pressure.oldest_wait_seconds",
        observed: null,
        unit: "seconds",
        source: ($sig.admission_queue_pressure.source // "tasks-axi-load-holds-plus-ledger"),
        observed_at: $timestamp,
        freshness_seconds: null,
        valid: false,
        unmeasured_reason: "backlog age is task age, not admission wait age; wait age needs the wake-outcome ledger",
        config_path: cfg("/signals/admission_queue_pressure/oldest_wait_soft_seconds"),
        operator: "observe",
        configured_value: $sig.admission_queue_pressure.oldest_wait_soft_seconds,
        result: "preferred"
      },
      {
        rule_id: "active_workers.count",
        signal: "active_workers.count",
        observed: ($tasks | length),
        detail: ([$tasks[] | .kind // "crewmate"] | group_by(.) | map("\(.[0])=\(length)") | join(" ")),
        unit: "count",
        source: ($sig.active_workers.source // "fresh-authority-census"),
        observed_at: ($snap.generated // $timestamp),
        freshness_seconds: $snapshot_age,
        valid: $census_readable,
        unknown_state_count: $unknown_state,
        config_path: cfg("/signals/active_workers/enforce"),
        operator: "observe",
        configured_value: ($sig.active_workers.enforce // false),
        result: "preferred",
        note: "observation only; an ambiguous worker is counted as present, never dropped"
      }
    ]
    + [ ("coordination_debt", "host_resources", "reservation_pressure")
        | . as $name
        | {
            rule_id: "\($name).unavailable",
            signal: $name,
            observed: null,
            unit: "none",
            source: ($sig[$name].source // "unmeasured"),
            observed_at: $timestamp,
            freshness_seconds: null,
            valid: false,
            unmeasured_reason: "signal source is not collectable in this home yet",
            config_path: cfg("/signals/\($name)/enabled"),
            operator: "observe",
            configured_value: ($sig[$name].enabled // false),
            result: "preferred"
          }
      ]) as $rules
  | ($rules | map(.result) | reduce .[] as $r ("preferred"; worse(.; $r))) as $band
  | ($rules | map(select(.result == $band and $band != "preferred") | .rule_id)) as $controlling
  | {
      schema: "fm-admission.v1",
      record_kind: "admission",
      active: true,
      decision_id: $decision_id,
      timestamp: $timestamp,
      task_id: null,
      task_independent: true,
      fleet_id: $p.fleet_id,
      authority_id: ($p.authority.authority_id // $home),
      node_id: $home,
      home: $home,
      snapshot_id: $snapshot_id,
      snapshot_generated: $snap.generated,
      snapshot_freshness_seconds: $snapshot_age,
      config_digest: $config_digest,
      authority_held: $authority_held,
      enforcement_mode: $p.enforcement_mode,
      combine: $p.combine,
      decision_band: $band,
      action: ($p.bands[$band].action // "admit"),
      hold_kind: ($p.bands[$band].hold_kind // null),
      auto_reconsider: ($p.bands[$band].auto_reconsider // null),
      notification_band: (if $band == "preferred" then "silent" else "immediate" end),
      active_worker_count: ($tasks | length),
      unknown_state_count: $unknown_state,
      load_queue_depth: $load_holds,
      oldest_load_wait_seconds: null,
      override_authority: null,
      release_triggers: ($p.queue.release_triggers // []),
      rules: ($rules | map(. + {signal_band: .result, fleet_band: $band})),
      controlling_rules: $controlling,
      telemetry: {
        sink: ($p.telemetry.sink // null),
        integrated: false,
        reason: "wake-outcome ledger extension seam is not available yet; this record is the unit to append when it lands"
      }
    }
') || die "admission evaluation failed"

BAND=$(printf '%s' "$RECORD" | jq -r '.decision_band')

case "$MODE" in
  json)
    printf '%s\n' "$RECORD"
    ;;
  brief)
    printf '%s' "$RECORD" | jq -r '
      "admission: \(.decision_band) (\(.action); \(.active_worker_count) worker(s), "
      + "\(.load_queue_depth) load-held; authority \(if .authority_held then "held" else "not held" end); config \(.config_digest))"
      + (if .decision_band == "preferred" then "" else "\n  controlling: \(.controlling_rules | join(", "))" end)'
    ;;
  *)
    printf '%s' "$RECORD" | jq -r '
      "admission: \(.decision_band) -> \(.action)   fleet=\(.fleet_id) authority=\(.authority_id) config=\(.config_digest)",
      "snapshot: \(.snapshot_id) generated=\(.snapshot_generated) age=\(.snapshot_freshness_seconds)s  mode=\(.enforcement_mode) combine=\(.combine)",
      "",
      (.rules[]
       | "  \(.rule_id): observed=\(.observed | tostring)\(if (.unit // "none") == "none" then "" else " \(.unit)" end)"
         + "  source=\(.source)/age=\(if .freshness_seconds == null then "unknown" else "\(.freshness_seconds)s" end) valid=\(.valid)"
         + "  \(.config_path) \(.operator) \(.configured_value | tostring)"
         + "  -> \(.signal_band)"),
      "",
      "notification: \(.notification_band)"
      + (if .decision_band == "preferred" then "" else "   controlling: \(.controlling_rules | join(", "))" end)'
    ;;
esac

case "$BAND" in
  preferred) exit 0 ;;
  soft) exit 3 ;;
  hard) exit 4 ;;
  *) exit 2 ;;
esac
