#!/usr/bin/env bash
# fm-run-governor.sh - the quota reserve governor: the tested policy unit that
# turns quota-axi's data into one dispatch class per account/model lane.
#
# quota-axi stays data-only and keeps owning how model windows relate to their
# bounding account windows; this script owns only the policy the captain set, so
# the numbers and the policy can move independently and the policy stays a unit
# test rather than a paragraph.
#
# Classes, strictest last:
#   normal          eligible dispatch, still gated by fit and machine health
#   no-new-large    no new large job; a small one only if it finishes inside the
#                   reserve and adds clear value
#   checkpoint-only no new implementation or research rounds; reach the nearest
#                   durable checkpoint, preserve, report
#   emergency       stop model-consuming work on the lane; supervision, state
#                   preservation, and safety recovery only
#   unknown         quota could not be read fresh; treated as NOT available
#
# Policy inputs, in the order they can only ever tighten the result:
#   - 25 / 15 / 10 percent-remaining thresholds, with a dead-band so a lane
#     hovering on a threshold cannot flap between two classes;
#   - a per-lane percent-remaining floor (Company Codex 65%);
#   - a per-local-day consumption budget in percentage points (15pp for Company
#     Codex and Company Claude from 2026-08-14 Europe/Budapest), with day-start
#     baselines, midnight rollover, and an explicit per-lane per-day override;
#   - projected runway: a lane whose runway cannot be shown to cover the work
#     plus its verification never counts as normal, whatever the percentage says.
#
# Unknown and stale are never available. A lane whose quota needs an attended
# authorization stays unknown: this script never passes --allow-keychain-prompt
# and never prompts, because an unattended keychain unlock is not authorized.
#
# Usage:
#   fm-run-governor.sh classify --lane <lane> [--provider <p>] [--scope <s>]
#                               [--quota-json <file>] [--need-seconds <n>]
#                               [--now <epoch>] [--no-record]
#   fm-run-governor.sh observe  --lane <lane> [--provider <p>] [--scope <s>]
#                               [--quota-json <file>] [--now <epoch>]
#   fm-run-governor.sh day      --lane <lane> [--now <epoch>]
#   fm-run-governor.sh override --lane <lane> --reason <text> [--day <YYYY-MM-DD>]
#                               [--now <epoch>]
#   fm-run-governor.sh policy   --lane <lane>
#
# `classify` prints key=value lines and exits 0 whenever it produced a class,
# including `class=unknown`; exit 1 means no quota evidence could be obtained at
# all, and exit 2 is a usage error.
#
# Lane policy comes from config/run-governor.conf (LOCAL, gitignored), one record
# per line: "<lane> <provider> [scope=<s>] [floor=<pct>] [day-budget=<pp>]".
# The four lanes the captain has named carry built-in defaults. A lane with
# neither a record nor an explicit --provider is refused rather than guessed: a
# provider is never inferred from a lane, model, or harness name.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-run-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-run-lib.sh"

# The captain's reserve policy. Overridable for tests and for a captain who
# retunes the policy, but these are the defaults the program was authorized with.
FM_GOV_NO_NEW_LARGE=${FM_GOV_NO_NEW_LARGE:-25}
FM_GOV_CHECKPOINT_ONLY=${FM_GOV_CHECKPOINT_ONLY:-15}
FM_GOV_EMERGENCY=${FM_GOV_EMERGENCY:-10}
# Dead-band in percentage points. A lane that crossed down through a threshold
# must recover past threshold+band before the looser class returns.
FM_GOV_HYSTERESIS=${FM_GOV_HYSTERESIS:-3}
# The local day the per-day consumption budget starts applying, and the zone that
# defines "day". Both are captain decisions, not arithmetic.
FM_GOV_DAY_BUDGET_FROM=${FM_GOV_DAY_BUDGET_FROM:-2026-08-14}
FM_GOV_TZ=${FM_GOV_TZ:-Europe/Budapest}
FM_GOV_STATE="${FM_RUN_STATE}/run-governor"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-run-governor: %s\n' "$*" >&2
  exit 1
}

# --- numeric helpers (percentages are fractional in quota-axi output) --------

num_le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 <= b + 0) }'; }
num_gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }
num_sub() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.4g", a - b }'; }
num_is() {
  case "$1" in
    ''|*[!0-9.eE+-]*) return 1 ;;
    *) awk -v a="$1" 'BEGIN { exit !(a + 0 == a + 0) }' ;;
  esac
}

# Local calendar day for an epoch, in the policy's zone, across BSD and GNU date.
local_day() {  # <epoch>
  TZ="$FM_GOV_TZ" date -r "$1" +%F 2>/dev/null && return 0
  TZ="$FM_GOV_TZ" date -d "@$1" +%F 2>/dev/null && return 0
  return 1
}

# --- lane policy ------------------------------------------------------------

lane_policy_builtin() {  # <lane> -> "<provider> <scope> <floor|-> <day-budget|->"
  case "$1" in
    company-claude) printf 'claude all_models - 15\n' ;;
    personal-claude) printf 'claude all_models - -\n' ;;
    company-codex) printf 'codex all_models 65 15\n' ;;
    personal-codex) printf 'codex all_models - -\n' ;;
    *) return 1 ;;
  esac
}

# Prints "<provider> <scope> <floor|-> <day-budget|->" for a lane.
lane_policy() {  # <lane>
  local lane=$1 file="$FM_RUN_CONFIG/run-governor.conf" name provider rest field
  local scope=all_models floor=- budget=-
  if [ -f "$file" ]; then
    while read -r name provider rest; do
      case "$name" in ''|'#'*) continue ;; esac
      [ "$name" = "$lane" ] || continue
      [ -n "$provider" ] || fail "config/run-governor.conf record for $lane needs a provider"
      for field in $rest; do
        case "$field" in
          scope=*) scope=${field#scope=} ;;
          floor=*) floor=${field#floor=} ;;
          day-budget=*) budget=${field#day-budget=} ;;
          '#'*) break ;;
          *) fail "config/run-governor.conf: unknown field '$field' for lane $lane" ;;
        esac
      done
      printf '%s %s %s %s\n' "$provider" "$scope" "$floor" "$budget"
      return 0
    done < "$file"
  fi
  lane_policy_builtin "$lane"
}

# --- quota evidence ---------------------------------------------------------

# Reads one provider's classification-relevant facts as tab-separated fields:
#   present state_status stale semantics_status avail_status percent runway pace
quota_facts() {  # <quota-json-file> <provider> <scope>
  jq -r --arg provider "$2" --arg scope "$3" '
    ((.providers // []) | map(select(.provider == $provider)) | .[0]) as $p
    | if $p == null then ["absent","","","","","","",""]
      else
        (($p.quotaSemantics.effectiveAvailability // [])
          | map(select(.scope == $scope)) | .[0]) as $e
        | [ "present",
            ($p.state.status // "unknown"),
            (($p.state.stale // false) | tostring),
            ($p.quotaSemantics.status // "unknown"),
            (if $e == null then "missing" else ($e.status // "unknown") end),
            (if $e == null then "" else (($e.effectivePercentRemaining // "") | tostring) end),
            (if $e == null then "unknown" else ($e.runway.status // "unknown") end),
            (if $e == null then "unknown" else ($e.pace.status // "unknown") end) ]
      end
    | @tsv' "$1"
}

load_quota_json() {  # <explicit-path-or-empty> -> path on stdout
  local given=$1 tmp
  if [ -n "$given" ]; then
    [ -f "$given" ] || fail "quota JSON does not exist: $given"
    printf '%s\n' "$given"
    return 0
  fi
  command -v quota-axi >/dev/null 2>&1 || fail "quota-axi is required (or pass --quota-json)"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-run-governor.XXXXXX") || fail "could not create a temp file"
  # Deliberately never --allow-keychain-prompt: an unattended authorization
  # prompt is not authorized, and an unreadable lane is supposed to read unknown.
  if ! quota-axi --json > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    fail "quota-axi did not produce JSON"
  fi
  printf '%s\n' "$tmp"
}

# --- day budget and hysteresis state ----------------------------------------

state_file() {  # <lane> <suffix>
  printf '%s/%s.%s\n' "$FM_GOV_STATE" "$1" "$2"
}

read_kv() {  # <file> <key>
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# Records today's baseline on the first observation of a local day and returns
# "<day> <baseline> <consumed>". Rollover is implicit: a different day resets the
# baseline to the current reading, so yesterday's spend never leaks into today.
day_track() {  # <lane> <percent> <epoch> <record:0|1>
  local lane=$1 percent=$2 epoch=$3 record=$4 file day stored_day baseline consumed
  day=$(local_day "$epoch") || fail "could not resolve the local day in $FM_GOV_TZ"
  file=$(state_file "$lane" day)
  stored_day=$(read_kv "$file" day)
  baseline=$(read_kv "$file" baseline)
  if [ "$stored_day" != "$day" ] || ! num_is "$baseline"; then
    baseline=$percent
    if [ "$record" = 1 ]; then
      mkdir -p "$FM_GOV_STATE"
      printf 'day=%s\nbaseline=%s\nlast=%s\n' "$day" "$baseline" "$percent" > "$file"
    fi
  elif [ "$record" = 1 ]; then
    mkdir -p "$FM_GOV_STATE"
    printf 'day=%s\nbaseline=%s\nlast=%s\n' "$day" "$baseline" "$percent" > "$file"
  fi
  consumed=$(num_sub "$baseline" "$percent")
  num_gt "$consumed" 0 || consumed=0
  printf '%s %s %s\n' "$day" "$baseline" "$consumed"
}

class_rank() {  # <class> -> integer, higher is stricter
  case "$1" in
    normal) printf '0\n' ;;
    no-new-large) printf '1\n' ;;
    checkpoint-only) printf '2\n' ;;
    emergency) printf '3\n' ;;
    unknown) printf '4\n' ;;
    *) printf '4\n' ;;
  esac
}

# A class only ever tightens on its way through the policy.
tighten() {  # <current> <candidate>
  if [ "$(class_rank "$2")" -gt "$(class_rank "$1")" ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$1"
  fi
}

# Percent-remaining thresholds, then the dead-band. Relaxing past a threshold the
# lane previously crossed down through requires threshold + band. Prints
# "<effective-class> <raw-threshold-class>" so the caller can say which of the
# two decided the result instead of reporting a percentage that looks healthy.
threshold_class() {  # <percent> <previous-class>
  local percent=$1 previous=$2 raw class
  if num_le "$percent" "$FM_GOV_EMERGENCY"; then raw=emergency
  elif num_le "$percent" "$FM_GOV_CHECKPOINT_ONLY"; then raw=checkpoint-only
  elif num_le "$percent" "$FM_GOV_NO_NEW_LARGE"; then raw=no-new-large
  else raw=normal
  fi
  class=$raw
  case "$previous" in
    emergency)
      num_gt "$percent" "$((FM_GOV_EMERGENCY + FM_GOV_HYSTERESIS))" || class=emergency
      ;;
    checkpoint-only)
      if ! num_gt "$percent" "$((FM_GOV_CHECKPOINT_ONLY + FM_GOV_HYSTERESIS))"; then
        class=$(tighten "$class" checkpoint-only)
      fi
      ;;
    no-new-large)
      if ! num_gt "$percent" "$((FM_GOV_NO_NEW_LARGE + FM_GOV_HYSTERESIS))"; then
        class=$(tighten "$class" no-new-large)
      fi
      ;;
  esac
  printf '%s %s\n' "$class" "$raw"
}

# --- commands ---------------------------------------------------------------

command_policy() {
  local lane=${1:-} record
  [ -n "$lane" ] || { usage >&2; exit 2; }
  record=$(lane_policy "$lane") || fail "lane $lane has no governor policy; register it in config/run-governor.conf"
  # shellcheck disable=SC2086 # The policy record is four controlled fields.
  set -- $record
  printf 'lane=%s\nprovider=%s\nscope=%s\nfloor=%s\nday_budget=%s\nday_budget_from=%s\ntz=%s\n' \
    "$lane" "$1" "$2" "$3" "$4" "$FM_GOV_DAY_BUDGET_FROM" "$FM_GOV_TZ"
}

command_override() {
  local lane='' reason='' day='' now=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane) shift; lane=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --day) shift; day=${1:-} ;;
      --now) shift; now=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$lane" ] || fail "--lane is required"
  [ -n "$reason" ] || fail "--reason is required; an override is a captain decision with a stated reason"
  [ -n "$now" ] || now=$(date -u +%s)
  [ -n "$day" ] || day=$(local_day "$now")
  case "$day" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail "--day must be YYYY-MM-DD" ;;
  esac
  mkdir -p "$FM_GOV_STATE"
  printf 'lane=%s\nday=%s\nreason=%s\nrecordedAt=%s\n' \
    "$lane" "$day" "$reason" "$(fm_run_now_iso)" > "$(state_file "$lane" "$day.override")"
  printf 'override: %s %s recorded\n' "$lane" "$day"
}

command_day() {
  local lane='' now='' file day
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane) shift; lane=${1:-} ;;
      --now) shift; now=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$lane" ] || fail "--lane is required"
  [ -n "$now" ] || now=$(date -u +%s)
  day=$(local_day "$now") || fail "could not resolve the local day"
  file=$(state_file "$lane" day)
  printf 'lane=%s\nday=%s\nstored_day=%s\nbaseline=%s\nlast=%s\noverride=%s\n' \
    "$lane" "$day" "$(read_kv "$file" day)" "$(read_kv "$file" baseline)" \
    "$(read_kv "$file" last)" \
    "$([ -f "$(state_file "$lane" "$day.override")" ] && printf yes || printf no)"
}

command_classify() {
  local lane='' provider='' scope='' quota_json='' need_seconds=0 now='' record=1 observe_only=0
  local policy policy_provider policy_scope floor budget quota_file facts
  local present state_status stale semantics avail percent runway pace
  local class=normal reasons='' previous day baseline consumed day_state=not-applicable
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane) shift; lane=${1:-} ;;
      --provider) shift; provider=${1:-} ;;
      --scope) shift; scope=${1:-} ;;
      --quota-json) shift; quota_json=${1:-} ;;
      --need-seconds) shift; need_seconds=${1:-} ;;
      --now) shift; now=${1:-} ;;
      --no-record) record=0 ;;
      --observe-only) observe_only=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  fm_run_require_jq || exit 1
  [ -n "$lane" ] || fail "--lane is required"
  [ -n "$now" ] || now=$(date -u +%s)
  case "$need_seconds" in ''|*[!0-9]*) fail "--need-seconds must be a non-negative integer" ;; esac

  if policy=$(lane_policy "$lane"); then
    # shellcheck disable=SC2086 # The policy record is four controlled fields.
    set -- $policy
    policy_provider=$1; policy_scope=$2; floor=$3; budget=$4
  else
    policy_provider=''; policy_scope=all_models; floor=-; budget=-
  fi
  [ -n "$provider" ] || provider=$policy_provider
  [ -n "$provider" ] \
    || fail "lane $lane has no registered provider; add it to config/run-governor.conf or pass --provider"
  [ -n "$scope" ] || scope=$policy_scope

  quota_file=$(load_quota_json "$quota_json")
  facts=$(quota_facts "$quota_file" "$provider" "$scope") \
    || { [ -n "$quota_json" ] || rm -f "$quota_file"; fail "could not read quota evidence for $provider"; }
  [ -n "$quota_json" ] || rm -f "$quota_file"
  IFS=$'\t' read -r present state_status stale semantics avail percent runway pace <<EOF
$facts
EOF

  previous=$(read_kv "$(state_file "$lane" class)" class)

  # Unknown is a class, not a fallback to available. Every path that cannot show
  # fresh, known, in-scope evidence lands here.
  if [ "$present" != present ]; then
    class=unknown; reasons="provider-absent"
  elif [ "$state_status" != fresh ]; then
    class=unknown; reasons="state:$state_status"
  elif [ "$stale" = true ]; then
    class=unknown; reasons="stale-evidence"
  elif [ "$semantics" != known ]; then
    class=unknown; reasons="quota-semantics:$semantics"
  elif [ "$avail" != known ]; then
    class=unknown; reasons="availability:$avail"
  elif ! num_is "$percent"; then
    class=unknown; reasons="percent-unreadable"
  fi

  if [ "$class" = unknown ]; then
    printf 'lane=%s\nprovider=%s\nscope=%s\nclass=unknown\npercent=unknown\nrunway=%s\npace=%s\nday_consumed=unknown\nday_budget_state=unknown\nreasons=%s\n' \
      "$lane" "$provider" "$scope" "${runway:-unknown}" "${pace:-unknown}" "$reasons"
    return 0
  fi

  read -r day baseline consumed <<EOF
$(day_track "$lane" "$percent" "$now" "$record")
EOF
  : "$baseline"

  if [ "$observe_only" = 1 ]; then
    printf 'lane=%s\nday=%s\nbaseline=%s\npercent=%s\nday_consumed=%s\n' \
      "$lane" "$day" "$baseline" "$percent" "$consumed"
    return 0
  fi

  local raw_class
  read -r class raw_class <<EOF
$(threshold_class "$percent" "$previous")
EOF
  if [ "$class" != normal ]; then
    if [ "$class" = "$raw_class" ]; then
      reasons="${reasons:+$reasons,}threshold:$percent"
    else
      reasons="${reasons:+$reasons,}hysteresis:$percent-held-at-$class"
    fi
  fi

  if [ "$floor" != - ] && num_is "$floor" && num_le "$percent" "$floor"; then
    class=$(tighten "$class" no-new-large)
    reasons="${reasons:+$reasons,}lane-floor:$floor"
  fi

  if [ "$budget" != - ] && num_is "$budget"; then
    if [ "$day" \< "$FM_GOV_DAY_BUDGET_FROM" ]; then
      day_state=not-yet-effective
    elif [ -f "$(state_file "$lane" "$day.override")" ]; then
      day_state=overridden
      reasons="${reasons:+$reasons,}day-budget-overridden"
    elif ! num_gt "$budget" "$consumed"; then
      day_state=exhausted
      class=$(tighten "$class" checkpoint-only)
      reasons="${reasons:+$reasons,}day-budget:${consumed}pp>=${budget}pp"
    else
      day_state=within
    fi
  fi

  # Percentage is only one bound. A job with a real duration needs a runway that
  # covers finishing plus verifying it; an unmeasurable runway is not a pass.
  if [ "$need_seconds" -gt 0 ] && [ "$runway" != through_reset ]; then
    class=$(tighten "$class" no-new-large)
    reasons="${reasons:+$reasons,}runway:$runway"
  fi
  if [ "$pace" = ahead ]; then
    class=$(tighten "$class" no-new-large)
    reasons="${reasons:+$reasons,}pace:ahead"
  fi

  if [ "$record" = 1 ]; then
    mkdir -p "$FM_GOV_STATE"
    printf 'class=%s\nat=%s\npercent=%s\n' "$class" "$(fm_run_now_iso)" "$percent" \
      > "$(state_file "$lane" class)"
  fi

  printf 'lane=%s\nprovider=%s\nscope=%s\nclass=%s\npercent=%s\nrunway=%s\npace=%s\nday=%s\nday_consumed=%s\nday_budget_state=%s\nreasons=%s\n' \
    "$lane" "$provider" "$scope" "$class" "$percent" "$runway" "$pace" "$day" "$consumed" \
    "$day_state" "${reasons:-none}"
}

case "${1:-}" in
  classify) shift; command_classify "$@" ;;
  observe) shift; command_classify --observe-only "$@" ;;
  day) shift; command_day "$@" ;;
  override) shift; command_override "$@" ;;
  policy) shift; command_policy "${1:-}" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
