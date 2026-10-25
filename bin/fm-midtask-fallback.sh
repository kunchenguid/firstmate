#!/usr/bin/env bash
# Opt-in mid-task fallback for a crew-dispatch profile array.
#
# Usage:
#   fm-midtask-fallback.sh bind <task-id> (--rule <index> | --default)
#   fm-midtask-fallback.sh consider <task-id> [--snapshot <quota-json>] [--pane-text-file <path>]
#
# bind     Copy one profile array from config/crew-dispatch.json onto the task
#          record. The index is zero-based among rules. --default records the
#          top-level default array. This refuses to record anything unless the
#          file-wide mid_task_fallback setting is on, and it appends to an
#          existing task record rather than replacing it. Run it after spawn:
#          a fresh spawn rewrites the record and would drop the array.
# consider When the setting is still on and this task has a recorded array,
#          detect a stop on a usage limit and relaunch onto the next eligible
#          candidate through bin/fm-control.sh relaunch. The recorded array is
#          the one bind stored. Later edits to the file do not rewrite it.
#          Turning the setting off stops further switches at once.
#          Nothing is deleted. The worktree path on the task record is not
#          changed. A relaunch keeps the keys this command wrote because
#          bin/fm-spawn.sh's relaunch preserve list omits them.
#
# The setting lives only in config/crew-dispatch.json. docs/configuration.md
# (Crew dispatch profiles) owns its shape. Absent, false, or a task with no
# recorded array does nothing.
#
# Detection, in order:
#   1. A quota snapshot passed with --snapshot marks the runway of the task's
#      current profile exhausted_now.
#   2. Otherwise a per-harness adapter under FM_LIMIT_MESSAGE_DIR matches the
#      text passed with --pane-text-file, and only when that adapter's observed
#      version is one of the versions it pins. An adapter whose version does
#      not match is not a signal. No adapter ships with firstmate.
# Status line text is never a signal.
# A quota snapshot, when passed, also vetoes a candidate whose applicable runway
# is exhausted_now. A missing snapshot does not invent exhaustion. Unknown
# quota stays eligible. A lower effort than the effort on the task record is
# ineligible unless the setting is the allow_lower_reasoning_class object.
# An unspecified effort is not a lower class.
#
# Selection walks the recorded array after the current profile and takes the
# first candidate that passes those gates. It does not re-rank by spendPriority.
# No such candidate appends one needs-decision line and exits 2.
# A successful switch appends midtask_switch= (from, to, reason, at) and a
# switched status line, and prints relaunched: <harness> <model> <effort> on
# stdout for firstmate to relay to the captain. A control failure appends midtask_switch_failed= for
# that candidate and a blocked: line, and a later consider does not retry it.
#
# Exit 0 is a no-op or a completed relaunch. Exit 2 is no eligible candidate.
# Exit 1 is a bad argument, a broken record, or a failed relaunch.
#
# FM_MIDTASK_CONTROL_BIN overrides the control command. Tests point it at a
# stub. Production leaves it unset and calls bin/fm-control.sh beside this file.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}

DISPATCH_FILE="$CONFIG/crew-dispatch.json"
CONTROL_BIN="${FM_MIDTASK_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
LIMIT_DIR="${FM_LIMIT_MESSAGE_DIR:-$SCRIPT_DIR/limit-messages}"

task_id_or_die() {
  fm_task_id_creation_valid "${1-}" || die "not a valid task id"
  printf '%s' "$1"
}

meta_path() {
  printf '%s/%s.meta' "$STATE" "$1"
}

status_path() {
  printf '%s/%s.status' "$STATE" "$1"
}

append_status() {
  local id=$1 line=$2 statusf
  statusf=$(status_path "$id")
  printf '%s\n' "$line" >> "$statusf"
  if [ -e "$CONFIG/fleet-ledger" ]; then
    "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$statusf" >/dev/null 2>&1 || true
  fi
}

# off, same, or lower. invalid is a broken file, not an opt-out.
fallback_mode() {
  local mode
  [ -f "$DISPATCH_FILE" ] || { printf 'off'; return 0; }
  mode=$(jq -r '
    if .mid_task_fallback == true then "same"
    elif .mid_task_fallback == false then "off"
    elif has("mid_task_fallback") | not then "off"
    elif (.mid_task_fallback | type) == "object"
      and ((.mid_task_fallback | keys) == ["allow_lower_reasoning_class"])
      and (.mid_task_fallback.allow_lower_reasoning_class == true) then "lower"
    else "invalid"
    end
  ' "$DISPATCH_FILE" 2>/dev/null) || die "config/crew-dispatch.json is not readable JSON"
  case "$mode" in
    off|same|lower) printf '%s' "$mode" ;;
    *) die "config/crew-dispatch.json mid_task_fallback is invalid" ;;
  esac
}

limit_adapter_matches() {
  local harness=$1 textfile=$2 adapter
  case "$harness" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  adapter=$LIMIT_DIR/$harness.sh
  [ -f "$adapter" ] && [ -f "$textfile" ] || return 1
  bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1" || exit 1
    command -v fm_limit_message_versions >/dev/null 2>&1 || exit 1
    command -v fm_limit_message_observed_version >/dev/null 2>&1 || exit 1
    command -v fm_limit_message_match >/dev/null 2>&1 || exit 1
    observed=$(fm_limit_message_observed_version) || exit 1
    [ -n "$observed" ] || exit 1
    matched=1
    while IFS= read -r pinned; do
      [ "$pinned" = "$observed" ] && matched=0
    done < <(fm_limit_message_versions)
    [ "$matched" -eq 0 ] || exit 1
    fm_limit_message_match < "$2"
  ' bash "$adapter" "$textfile"
}

effort_rank() {
  case "$1" in
    low) printf 1 ;;
    medium) printf 2 ;;
    high) printf 3 ;;
    xhigh) printf 4 ;;
    max) printf 5 ;;
    ultra) printf 6 ;;
    *) printf 0 ;;
  esac
}

lower_effort() {
  local current=$1 candidate=$2 cur cand
  cur=$(effort_rank "$current")
  cand=$(effort_rank "$candidate")
  [ "$cur" -gt 0 ] && [ "$cand" -gt 0 ] && [ "$cand" -lt "$cur" ]
}

quota_exhausted() {
  local snapshot=$1 provider=$2 harness=$3 model=$4 evidence
  [ -n "$provider" ] || return 1
  evidence=$(jq -c --arg provider "$provider" --arg harness "$harness" --arg model "$model" "$FM_QUOTA_ROW_JQ"'
    (if $harness == "omp" then ($model | sub("^[^/]*/"; "")) else ($model | sub("^model:"; "")) end) as $scope_model |
    quota_lane($harness; $model) as $lane |
    quota_row(.; $provider; $lane) as $p |
    if $p == null then {status: "unknown"}
    else
      ($p.quotaSemantics.effectiveAvailability // [])
      | map(select(.scope as $scope |
          $scope == "all_models" or $scope == "all_products" or
          ($scope_model != "" and $scope_model != "default" and
           (($scope | startswith("model:")) or ($scope | startswith("product:"))) and
           ($scope_model == ($scope | sub("^(model|product):"; ""))))))
      | if length == 0 then {status: "unknown"}
        elif any(.[]; (.runway.status // "") == "exhausted_now") then
          (map(select((.runway.status // "") == "exhausted_now")) | first)
        else {status: "known"}
        end
    end
  ' "$snapshot") || return 2
  printf '%s\n' "$evidence" | jq -e '(.runway.status // "") == "exhausted_now"' >/dev/null 2>&1
}

current_exhausted() {
  local array_json=$1 snapshot=$2 harness=$3 model=$4 effort=$5 provider
  provider=$(printf '%s\n' "$array_json" | jq -r \
    --arg h "$harness" --arg m "$model" --arg e "$effort" '
    [.[] | select(type == "object" and .harness == $h)
      | {p: (.provider // ""), m: (.model // "default"), e: (.effort // "default")}]
    | ([.[] | select(.m == $m and .e == $e)]) as $exact
    | (if ($exact | length) > 0 then $exact
       else [.[] | select((.m == "default" or .m == $m) and (.e == "default" or .e == $e))] end)
    | last.p // ""
  ' 2>/dev/null) || return 1
  if [ -z "$provider" ]; then
    provider=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null || true)
  fi
  quota_exhausted "$snapshot" "$provider" "$harness" "$model"
}

profile_rows() {
  local array_json=$1
  printf '%s\n' "$array_json" | jq -r '
    if type != "array" or length == 0 then error("dispatch array is empty") else . end
    | to_entries[]
    | select((.value | type) == "object")
    | select((.value.harness | type) == "string" and (.value.harness | length) > 0)
    | [.key, .value.harness, (.value.model // "default"), (.value.effort // "default"), (.value.provider // "")]
    | @tsv
  '
}

switch_object() {
  jq -nc \
    --arg fh "$1" --arg fm "$2" --arg fe "$3" \
    --arg th "$4" --arg tm "$5" --arg te "$6" \
    --arg reason "$7" --argjson at "$8" \
    '{from:{harness:$fh,model:$fm,effort:$fe},to:{harness:$th,model:$tm,effort:$te},reason:$reason,at:$at}'
}

already_switched() {
  local meta=$1 fh=$2 fm=$3 fe=$4 th=$5 tm=$6 te=$7 last
  last=$(fm_meta_get "$meta" midtask_switch)
  [ -n "$last" ] || return 1
  printf '%s\n' "$last" | jq -e \
    --arg fh "$fh" --arg fm "$fm" --arg fe "$fe" \
    --arg th "$th" --arg tm "$tm" --arg te "$te" \
    '.from.harness == $fh and .from.model == $fm and .from.effort == $fe and .to.harness == $th and .to.model == $tm and .to.effort == $te' \
    >/dev/null 2>&1
}

failed_candidate() {
  local meta=$1 th=$2 tm=$3 te=$4 line value
  [ -f "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      midtask_switch_failed=*)
        value=${line#*=}
        if printf '%s\n' "$value" | jq -e \
          --arg th "$th" --arg tm "$tm" --arg te "$te" \
          '.to.harness == $th and .to.model == $tm and .to.effort == $te' \
          >/dev/null 2>&1; then
          return 0
        fi
        ;;
    esac
  done < "$meta"
  return 1
}

status_has_key() {
  local id=$1 verb=$2 key=$3 line
  line=$(last_status_line "$(status_path "$id")")
  [ "$(status_line_verb "$line")" = "$verb" ] || return 1
  case "$line" in
    *"[key=$key]"*) return 0 ;;
    *) return 1 ;;
  esac
}

worker_finished_or_waiting() {
  local line verb
  line=$(last_status_line "$(status_path "$1")")
  case "$line" in
    *"[key=midtask-fallback]"*) return 1 ;;
  esac
  verb=$(status_line_verb "$line")
  case "$verb" in
    done|failed|needs-decision|blocked) return 0 ;;
    *) return 1 ;;
  esac
}

report_no_candidate() {
  local id=$1 reason=$2 epoch line
  status_has_key "$id" needs-decision midtask-fallback && return 0
  epoch=$(date +%s)
  line="needs-decision [at=$epoch] [key=midtask-fallback]: no eligible next profile after ${reason}; the current profile stays"
  append_status "$id" "$line"
  printf '%s\n' 'no eligible candidate'
}

cmd_bind() {
  local id source='' rule='' mode array meta
  [ "$#" -ge 1 ] || usage
  id=$(task_id_or_die "$1")
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rule)
        [ -n "${2-}" ] || die "--rule needs an index"
        case "$2" in ''|*[!0-9]*) die "--rule needs a zero-based index" ;; esac
        rule=$2
        source=rule
        shift 2
        ;;
      --default)
        source=default
        shift
        ;;
      *) usage ;;
    esac
  done
  [ -n "$source" ] || usage
  [ "$source" != rule ] || [ -n "$rule" ] || usage
  meta=$(meta_path "$id")
  [ -f "$meta" ] || die "no task record for $id"
  mode=$(fallback_mode)
  if [ "$mode" = off ]; then
    printf '%s\n' 'mid-task fallback: off'
    return 0
  fi
  [ -f "$DISPATCH_FILE" ] || die "config/crew-dispatch.json is absent"
  if [ "$source" = default ]; then
    array=$(jq -ce '
      if has("default") | not then empty
      elif (.default | type) == "array" then .default
      elif (.default | type) == "object" then [.default]
      else empty end
    ' "$DISPATCH_FILE") || die "config/crew-dispatch.json has no default profile array"
  else
    array=$(jq -ce --argjson i "$rule" '
      .rules[$i].use as $u |
      if $u == null then empty
      elif ($u | type) == "array" then $u
      elif ($u | type) == "object" then [$u]
      else empty end
    ' "$DISPATCH_FILE") || die "rule $rule has no use profile"
  fi
  printf '%s\n' "$array" | jq -e 'type == "array" and length > 0 and all(.[]; (.harness | type) == "string" and (.harness | length) > 0)' >/dev/null \
    || die "the matched profile set is empty or has no harness"
  printf 'dispatch_array=%s\ndispatch_fallback=on\n' "$array" >> "$meta"
  printf 'bound: %s\n' "$id"
}

cmd_consider() {
  local id snapshot='' pane='' mode meta kind array cur_h cur_m cur_e
  local rows='' idx harness model effort provider last_match=-1 exact_match=-1 wild_match=-1
  local ch='' cm='' ce='' reason='' epoch note rc=0
  [ "$#" -ge 1 ] || usage
  id=$(task_id_or_die "$1")
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot)
        [ -n "${2-}" ] || die "--snapshot needs a path"
        snapshot=$2
        shift 2
        ;;
      --pane-text-file)
        [ -n "${2-}" ] || die "--pane-text-file needs a path"
        pane=$2
        shift 2
        ;;
      *) usage ;;
    esac
  done
  mode=$(fallback_mode)
  [ "$mode" != off ] || return 0
  meta=$(meta_path "$id")
  [ -f "$meta" ] || return 0
  [ "$(fm_meta_get "$meta" dispatch_fallback)" = on ] || return 0
  kind=$(fm_meta_get "$meta" kind)
  case "$kind" in
    ship|scout) ;;
    *) return 0 ;;
  esac
  array=$(fm_meta_get "$meta" dispatch_array)
  [ -n "$array" ] || return 0
  if [ -n "$snapshot" ]; then
    [ -f "$snapshot" ] || die "quota snapshot is missing: $snapshot"
    fm_quota_json_valid < "$snapshot" || die "quota snapshot is not a valid quota-axi document"
  fi
  worker_finished_or_waiting "$id" && return 0
  cur_h=$(fm_meta_get "$meta" harness)
  cur_m=$(fm_meta_get "$meta" model)
  cur_e=$(fm_meta_get "$meta" effort)
  [ -n "$cur_h" ] || die "task $id has no harness on its record"
  [ -n "$cur_m" ] || cur_m=default
  [ -n "$cur_e" ] || cur_e=default
  reason=''
  if [ -n "$snapshot" ] && current_exhausted "$array" "$snapshot" "$cur_h" "$cur_m" "$cur_e"; then
    reason=usage-limit
  elif [ -n "$pane" ] && limit_adapter_matches "$cur_h" "$pane"; then
    reason=limit-message
  else
    return 0
  fi
  rows=$(profile_rows "$array") || die "task $id dispatch array is unreadable"
  [ -n "$rows" ] || die "task $id dispatch array is empty"
  while IFS=$'\t' read -r idx harness model effort provider; do
    [ "$harness" = "$cur_h" ] || continue
    if [ "$model" = "$cur_m" ] && [ "$effort" = "$cur_e" ]; then
      exact_match=$idx
    elif { [ "$model" = default ] || [ "$model" = "$cur_m" ]; } \
      && { [ "$effort" = default ] || [ "$effort" = "$cur_e" ]; }; then
      wild_match=$idx
    fi
  done <<< "$rows"
  last_match=$wild_match
  [ "$exact_match" -lt 0 ] || last_match=$exact_match
  if [ "$last_match" -lt 0 ]; then
    report_no_candidate "$id" "a $reason"
    return 2
  fi
  while IFS=$'\t' read -r idx harness model effort provider; do
    [ "$idx" -gt "$last_match" ] || continue
    if [ "$mode" != lower ] && lower_effort "$cur_e" "$effort"; then
      continue
    fi
    fm_control_harness_supported "$harness" || continue
    fm_control_harness_supports_kind "$harness" "$kind" || continue
    failed_candidate "$meta" "$harness" "$model" "$effort" && continue
    if [ -n "$snapshot" ]; then
      if [ -z "$provider" ]; then
        provider=$(fm_quota_provider_for_harness "$harness" "$model" 2>/dev/null || true)
      fi
      if [ -n "$provider" ]; then
        quota_exhausted "$snapshot" "$provider" "$harness" "$model"
        rc=$?
        if [ "$rc" -eq 0 ]; then
          continue
        fi
        [ "$rc" -ne 2 ] || die "quota snapshot could not be read for $harness"
      fi
    fi
    ch=$harness
    cm=$model
    ce=$effort
    break
  done <<< "$rows"
  if [ -z "$ch" ]; then
    report_no_candidate "$id" "a $reason"
    return 2
  fi
  if already_switched "$meta" "$cur_h" "$cur_m" "$cur_e" "$ch" "$cm" "$ce"; then
    return 0
  fi
  epoch=$(date +%s)
  note='The previous run stopped on a usage limit. Continue this task from the existing local copy, including uncommitted work.'
  if ! "$CONTROL_BIN" "$id" relaunch --harness "$ch" --model "$cm" --effort "$ce" --note "$note"; then
    printf 'midtask_switch_failed=%s\n' \
      "$(switch_object "$cur_h" "$cur_m" "$cur_e" "$ch" "$cm" "$ce" "$reason" "$epoch")" >> "$meta"
    if ! status_has_key "$id" blocked midtask-fallback; then
      append_status "$id" "blocked [at=$epoch] [key=midtask-fallback]: relaunch onto the next profile failed; the local copy was kept"
    fi
    return 1
  fi
  printf 'midtask_switch=%s\n' \
    "$(switch_object "$cur_h" "$cur_m" "$cur_e" "$ch" "$cm" "$ce" "$reason" "$epoch")" >> "$meta"
  append_status "$id" "switched [at=$epoch]: $cur_h $cur_m $cur_e -> $ch $cm $ce because a usage limit stopped the worker"
  printf 'relaunched: %s %s %s\n' "$ch" "$cm" "$ce"
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift
case "$cmd" in
  bind) cmd_bind "$@" ;;
  consider) cmd_consider "$@" ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac
