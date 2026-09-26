#!/usr/bin/env bash
# fm-hold-reverify.sh - recurring re-verification of aged captain-held tasks.
#
# Usage:
#   fm-hold-reverify.sh [check]              run one bounded re-verification sweep
#   fm-hold-reverify.sh classify <facts.json> print the verdict for one hold's facts
#   fm-hold-reverify.sh arm                  write and register the standing check
#   fm-hold-reverify.sh disarm               remove the standing check
#   fm-hold-reverify.sh --help               print this help
#
# WHY THIS EXISTS
# A captain call is an ordinary backlog task held for the captain (identity: the
# task id), owned by bin/fm-captain-hold.sh and the captain-hold-lifecycle skill.
# Holds accumulate age: across the fleet hundreds sat behind a hold that nobody
# had ever re-checked, so the captain's list was mostly ghosts and every count of
# remaining work was wrong. The rot concentrates in age.
#
# This script re-checks each aged captain hold against shipped reality and reports
# it in the SAME reconciliation vocabulary captain-hold-lifecycle already owns:
# dead / still_live / not_a_decision / unestablishable. It reports only. It never
# calls `answer` and never calls `reconcile close`/`reconcile note`, so it can
# never close a captain call; only the captain's own words or an explicit
# evidence-backed reconciliation may do that. The point is that the list the
# captain reads is true, not that it is short.
#
# SCHEDULING
# `check` is a plain custom watcher check, not a process-event source. The
# process-event `when` adapter explicitly excludes "an action whose right form
# depends on what the condition finds", and this sweep both classifies each hold
# differently and defers every close to a human, so it stays in the
# check-fires-then-firstmate-decides flow that the process-event-sources skill
# names as the correct home for a plain custom check. `arm` writes
# state/hold-reverify.check.sh and binds its bytes with fm-check-register.sh, so
# the watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns its
# one line into a `check:` wake. Session-start-only scanning was rejected: a home
# that never restarts would keep its rot, which is the exact failure being fixed.
#
# THE REPORT IS THE DELIVERABLE
# A sweep writes state/hold-reverify/docket.json (schema fm-hold-reverify-docket.v1)
# listing every examined hold with its verdict, structured evidence, and a short
# reason, and prints ONE line (the wake) only when the finding set changes.
# state/.hold-reverify stores the last sweep's epoch and a digest of the
# {id:verdict} set, mirroring state/.tool-updates, so a new or changed finding
# wakes once while an unchanged sweep stays silent. A sweep killed by the
# watcher's FM_CHECK_TIMEOUT writes no record and is retried.
#
# VERDICT RULES (decided only from structured fields, never from prose)
#   not_a_decision  the row does not carry a live captain question: it is already
#                   Done, or it records no hold reason. This is the closed or
#                   superseded call that still carries the hold annotation.
#   dead            shipped reality resolves the subject: the row records a
#                   `merged` completion, or its recorded pull request is merged.
#                   dead is NEVER inferred from absence or from an unreadable
#                   source; it requires positive resolution evidence.
#   still_live      the subject is provably still open: the recorded pull request
#                   is open.
#   unestablishable everything else: no recorded subject, the forge could not be
#                   read or authenticated, a non-GitHub provider, or a closed
#                   (unmerged) pull request whose premise is ambiguous.
# The four buckets are total and mutually exclusive, and every result is a
# proposal for reconciliation, not a closure.
#
# WHAT IT READS
# Aged holds come from the canonical local backlog projection rather than a second
# parser: `fm-fleet-snapshot.sh --contribution-input` reuses the canonical backlog
# parser WITHOUT observing workers or other homes, so the sweep stays local and
# bounded. A hold's recorded pull request is read through bin/fm-pr-lib.sh, which
# is the same gh-then-gh-axi path every other surface uses. A redundant local
# origin/main fetch is deliberately NOT performed: the forge merge state and the
# row's own recorded completion are the authoritative landing signals, and a clone
# fetch would add cost and a second source of truth without new signal.
#
# BOUNDS
# AGE      FM_HOLD_REVERIFY_AGE_DAYS   default 14 (whole days, matching
#                                      FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS)
# CADENCE  FM_HOLD_REVERIFY_INTERVAL   default 21600, 0 disables the gate,
#                                      otherwise 60..604800 seconds
# SWEEP    FM_HOLD_REVERIFY_BUDGET_SECS default 20, cut to fit FM_CHECK_TIMEOUT
# PROBE    FM_HOLD_REVERIFY_PROBE_SECS default 8, valid 1..30
# COUNT    FM_HOLD_REVERIFY_MAX_HOLDS  default 12 (whole holds examined per sweep)
set -u
export LC_ALL=C
# A forge read must fail inside its bound rather than stop for credentials.
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DOCKET_DIR="$STATE/hold-reverify"
DOCKET="$DOCKET_DIR/docket.json"
RECORD="$STATE/.hold-reverify"
CHECK_ID='hold-reverify'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
SNAPSHOT_BIN="${FM_HOLD_REVERIFY_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
RECORD_SCHEMA=fm-hold-reverify-v1
DOCKET_SCHEMA=fm-hold-reverify-docket.v1
MAX_LINE=520

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-hold-reverify.sh [check]               run one bounded re-verification sweep
  fm-hold-reverify.sh classify <facts.json> print the verdict for one hold's facts
  fm-hold-reverify.sh arm                   write and register state/hold-reverify.check.sh
  fm-hold-reverify.sh disarm                remove the standing check, its trust binding, and the record
  fm-hold-reverify.sh --help                print this help

A sweep re-checks aged captain holds against shipped reality and reports them as
dead, still_live, not_a_decision, or unestablishable. It never closes a captain
call. The docket is written to state/hold-reverify/docket.json.
EOF
}

die_usage() {
  printf 'fm-hold-reverify: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# --- configuration ----------------------------------------------------------

AGE_DAYS=${FM_HOLD_REVERIFY_AGE_DAYS:-14}
case "$AGE_DAYS" in
  ''|*[!0-9]*) die_usage "FM_HOLD_REVERIFY_AGE_DAYS must be a whole number of days" ;;
esac

INTERVAL=${FM_HOLD_REVERIFY_INTERVAL:-21600}
case "$INTERVAL" in
  ''|*[!0-9]*) die_usage "FM_HOLD_REVERIFY_INTERVAL must be 0 or a whole number from 60 to 604800" ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 604800 ]; }; then
  die_usage "FM_HOLD_REVERIFY_INTERVAL must be 0 or a whole number from 60 to 604800"
fi

BUDGET_SECS=${FM_HOLD_REVERIFY_BUDGET_SECS:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0) die_usage "FM_HOLD_REVERIFY_BUDGET_SECS must be a whole number from 1 to 120" ;;
esac
if [ "$BUDGET_SECS" -gt 120 ]; then
  die_usage "FM_HOLD_REVERIFY_BUDGET_SECS must be a whole number from 1 to 120"
fi

PROBE_SECS=${FM_HOLD_REVERIFY_PROBE_SECS:-8}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0) die_usage "FM_HOLD_REVERIFY_PROBE_SECS must be a whole number from 1 to 30" ;;
esac
if [ "$PROBE_SECS" -gt 30 ]; then
  die_usage "FM_HOLD_REVERIFY_PROBE_SECS must be a whole number from 1 to 30"
fi

MAX_HOLDS=${FM_HOLD_REVERIFY_MAX_HOLDS:-12}
case "$MAX_HOLDS" in
  ''|*[!0-9]*|0) die_usage "FM_HOLD_REVERIFY_MAX_HOLDS must be a positive whole number" ;;
esac

# The watcher's per check bound, read from this check's own environment, since the
# watcher runs the check as a direct child. Keep the sweep inside it so a killed
# check does not repeat its silence every cycle.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
PROBE_MIN_SECS=1
CLOCK_ROUNDING_SECS=1
KILL_GRACE_SECS=1
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi
# The local projection is a fast bounded child of the same sweep budget, so it
# can never consume more than the sweep has left.
SNAPSHOT_BOUND=5
[ "$SNAPSHOT_BOUND" -le "$BUDGET_SECS" ] || SNAPSHOT_BOUND=$BUDGET_SECS

# --- small helpers ----------------------------------------------------------

# The record epoch is overridable so a test can drive the cadence gate; the
# sweep budget always uses real time so a frozen epoch cannot disable it.
record_epoch_now() {
  case "${FM_HOLD_REVERIFY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_HOLD_REVERIFY_NOW" ;;
  esac
}

real_epoch() { date +%s; }

digest_of() {
  local text=$1
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$text" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$text" | cksum | awk '{print $1}'
  fi
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- report record ----------------------------------------------------------

RECORD_EPOCH=0
RECORD_DIGEST=

record_read() {
  local line first=1
  RECORD_EPOCH=0
  RECORD_DIGEST=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      findings=*) RECORD_DIGEST=${line#findings=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local digest=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'findings=%s\n' "$digest"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- classifier -------------------------------------------------------------

# classify_facts <facts-json>: print the one verdict for a hold's structured
# facts. Pure: no clock, no network, no filesystem. This is the seam the tests
# drive, and action_check drives it too, so both paths classify identically.
classify_facts() {
  printf '%s\n' "$1" | jq -r '
    if (.state == "done") or ((.hold_reason // "") == "") then "not_a_decision"
    elif (.completion_merged == true) or (.pr_state == "merged") then "dead"
    elif (.pr_state == "open") then "still_live"
    else "unestablishable" end'
}

# read_record_bounded <owner> <repo> <number> <bound>: print "<STATE> <MERGED>"
# from bin/fm-pr-lib.sh under a hard bound, or nothing. The bounded child sources
# the lib itself so the global readout survives the process boundary.
read_record_bounded() {
  local owner=$1 repo=$2 number=$3 bound=$4
  # shellcheck disable=SC2016  # The child sources the lib and expands its own positionals.
  fm_run_timed "$bound" bash -c '
    . "$1" || exit 1
    fm_pr_github_read_record "$2" "$3" "$4" || exit 1
    printf "%s %s\n" "$FM_PR_RECORD_STATE" "$FM_PR_RECORD_MERGED"
  ' _ "$SCRIPT_DIR/fm-pr-lib.sh" "$owner" "$repo" "$number"
}

# gather_facts <hold-json>: emit one facts object for a selected hold.
gather_facts() {
  local hold=$1 id state reason pr_url merged pr_state=none owner repo number out record_state
  id=$(printf '%s\n' "$hold" | jq -r '.id // ""')
  state=$(printf '%s\n' "$hold" | jq -r '.state // ""')
  reason=$(printf '%s\n' "$hold" | jq -r '.hold_reason // ""')
  pr_url=$(printf '%s\n' "$hold" | jq -r '.pr_url // ""')
  merged=$(printf '%s\n' "$hold" | jq -r 'if .completion_merged == true then "true" else "false" end')
  if [ -n "$pr_url" ]; then
    if fm_pr_url_parse "$pr_url" && [ "$FM_PR_PROVIDER" = github ] \
      && [ -n "$FM_PR_OWNER" ] && [ -n "$FM_PR_REPO" ] && [ -n "$FM_PR_NUMBER" ]; then
      owner=$FM_PR_OWNER
      repo=$FM_PR_REPO
      number=$FM_PR_NUMBER
      if out=$(read_record_bounded "$owner" "$repo" "$number" "$PROBE_SECS"); then
        record_state=${out%% *}
        case "$record_state" in
          MERGED) pr_state=merged ;;
          OPEN) pr_state=open ;;
          CLOSED) pr_state=closed ;;
          *) pr_state=unreadable ;;
        esac
      else
        pr_state=unreadable
      fi
    else
      pr_state=unreadable
    fi
  fi
  jq -cn \
    --arg id "$id" \
    --arg state "$state" \
    --arg hold_reason "$reason" \
    --arg pr_url "$pr_url" \
    --arg pr_state "$pr_state" \
    --argjson completion_merged "$merged" \
    '{id:$id,state:$state,hold_reason:$hold_reason,pr_url:$pr_url,
      pr_state:$pr_state,completion_merged:$completion_merged}'
}

# --- the sweep --------------------------------------------------------------

FINDINGS_FILE=
EXAMINED=0
DEFERRED=0
DEADLINE=0
SNAPSHOT_ERROR=

budget_exhausted() { [ "$(real_epoch)" -ge "$DEADLINE" ]; }

sweep_cleanup() {
  [ -z "$FINDINGS_FILE" ] || rm -f -- "$FINDINGS_FILE"
  FINDINGS_FILE=
}

# snapshot_holds: print one compact JSON object per aged captain hold, or nothing.
snapshot_holds() {
  local snapshot
  snapshot=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    fm_run_timed "$SNAPSHOT_BOUND" "$SNAPSHOT_BIN" --contribution-input 2>/dev/null) || return 1
  [ -n "$snapshot" ] || return 1
  printf '%s\n' "$snapshot" | jq -c --argjson age "$AGE_DAYS" '
    (.backlog.records // [])[]
    | select(.structured == true)
    | select(.hold_kind == "captain")
    | select(.hold_age_days != null and .hold_age_days >= $age)
    | {id, title, state, hold_reason, hold_age_days, pr_url,
       completion_merged: (.completion.verb == "merged")}' || return 1
}

action_check() {
  [ -d "$STATE" ] || return 0
  record_read
  local now
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi

  DEADLINE=$(( $(real_epoch) + BUDGET_SECS ))
  FINDINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-hold-reverify.XXXXXX") || return 0
  : > "$FINDINGS_FILE"
  EXAMINED=0
  DEFERRED=0
  SNAPSHOT_ERROR=

  local holds='' hold facts verdict
  if ! holds=$(snapshot_holds); then
    SNAPSHOT_ERROR="could not read the aged-hold projection"
  else
    while IFS= read -r hold; do
      [ -n "$hold" ] || continue
      if [ "$EXAMINED" -ge "$MAX_HOLDS" ] || budget_exhausted; then
        DEFERRED=$((DEFERRED + 1))
        continue
      fi
      EXAMINED=$((EXAMINED + 1))
      facts=$(gather_facts "$hold")
      verdict=$(classify_facts "$facts")
      printf '%s\n' "$facts" \
        | jq -c --arg v "$verdict" '. + {verdict:$v}' >> "$FINDINGS_FILE"
    done <<EOF
$holds
EOF
  fi

  write_report
  sweep_cleanup
  return 0
}

# write_report: assemble the docket and print the one-line wake when the finding
# set is news. Writes the record even on an unchanged sweep so the cadence gate
# advances; a report that cannot be written costs a repeated report, never a lost
# one, so the print happens before the record write.
write_report() {
  local generated counts dead live notdec unest examined deferred line digest summary
  generated=$(utc_now)
  counts=$(jq -s '{
    dead:              ([.[] | select(.verdict == "dead")] | length),
    still_live:        ([.[] | select(.verdict == "still_live")] | length),
    not_a_decision:    ([.[] | select(.verdict == "not_a_decision")] | length),
    unestablishable:   ([.[] | select(.verdict == "unestablishable")] | length)
  }' "$FINDINGS_FILE" 2>/dev/null) || counts='{}'
  dead=$(printf '%s\n' "$counts" | jq -r '.dead // 0')
  live=$(printf '%s\n' "$counts" | jq -r '.still_live // 0')
  notdec=$(printf '%s\n' "$counts" | jq -r '.not_a_decision // 0')
  unest=$(printf '%s\n' "$counts" | jq -r '.unestablishable // 0')
  examined=$EXAMINED
  deferred=$DEFERRED

  if [ -d "$DOCKET_DIR" ] || mkdir -p "$DOCKET_DIR"; then
    if jq -s --arg generated "$generated" --arg schema "$DOCKET_SCHEMA" \
      --argjson age "$AGE_DAYS" --argjson examined "$examined" --argjson deferred "$deferred" \
      '{schema:$schema, generated:$generated, threshold_days:$age,
        examined:$examined, deferred:$deferred,
        counts:{dead:([.[]|select(.verdict=="dead")]|length),
                still_live:([.[]|select(.verdict=="still_live")]|length),
                not_a_decision:([.[]|select(.verdict=="not_a_decision")]|length),
                unestablishable:([.[]|select(.verdict=="unestablishable")]|length)},
        findings:(sort_by(.id))}' \
      "$FINDINGS_FILE" > "$DOCKET.tmp" 2>/dev/null; then
      mv -f -- "$DOCKET.tmp" "$DOCKET" || rm -f -- "$DOCKET.tmp"
    else
      rm -f -- "$DOCKET.tmp"
    fi
  fi

  # The digest keys the record on the finding set, so a new hold aging in or a
  # verdict changing is news while an unchanged sweep stays silent.
  digest=$(sort "$FINDINGS_FILE" | jq -sc '[.[] | .id + ":" + .verdict] | sort | join(",")' 2>/dev/null)
  digest=$(digest_of "${digest:-}")

  summary=
  line=
  if [ -n "$SNAPSHOT_ERROR" ]; then
    summary="hold re-verify: $SNAPSHOT_ERROR"
    digest=$(digest_of "error:$SNAPSHOT_ERROR")
  elif [ "$examined" -gt 0 ] || [ "$deferred" -gt 0 ]; then
    summary="hold re-verify: $dead dead, $live still live, $notdec not-a-decision, $unest unestablishable among $examined aged captain holds"
    [ "$deferred" -eq 0 ] || summary="$summary ($deferred deferred)"
    summary="$summary; docket state/hold-reverify/docket.json"
  fi
  if [ -n "$summary" ]; then
    fm_cap_line_var "$summary" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  if [ -n "$BUDGET_CUT_FROM" ] && [ -n "$line" ]; then
    line="$line [budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s]"
  fi

  if [ -n "$line" ] && [ "$digest" != "$RECORD_DIGEST" ]; then
    printf '%s\n' "$line"
  fi
  record_write "$digest" || true
}

# --- arming -----------------------------------------------------------------

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-hold-reverify.sh - aged captain-hold re-verification.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-hold-reverify.sh") check"
}

SHIM_WRITE_TMP=
ARM_BACKUP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-hold-reverify-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-hold-reverify-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

# An unregistered shim is not inert: the watcher rejects it every cycle and wakes
# about unauthenticated state checks. After a failed or interrupted arm the home
# must never hold a shim without a matching trust binding.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-hold-reverify: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-hold-reverify: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-hold-reverify: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-hold-reverify: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-hold-reverify: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

# --- dispatch ---------------------------------------------------------------

case "${1:-check}" in
  check)
    [ "$#" -le 1 ] || die_usage "check takes no arguments"
    action_check
    ;;
  classify)
    [ "$#" -eq 2 ] || die_usage "classify requires one facts JSON file"
    [ -f "$2" ] && [ ! -L "$2" ] || die_usage "classify facts file is unavailable: $2"
    classify_facts "$(cat "$2")"
    ;;
  arm)
    [ "$#" -eq 1 ] || die_usage "arm takes no arguments"
    action_arm
    ;;
  disarm)
    [ "$#" -eq 1 ] || die_usage "disarm takes no arguments"
    action_disarm
    ;;
  -h|--help)
    usage
    ;;
  *)
    die_usage "unknown command: $1"
    ;;
esac
