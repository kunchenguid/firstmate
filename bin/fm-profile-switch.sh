#!/usr/bin/env bash
# fm-profile-switch.sh - choose a live Pi switch or a harness relaunch from
# crew-dispatch.json at a bounded checkpoint.
#
# Usage:
#   fm-profile-switch.sh --checkpoint <complexity|stall|phase|quota>
#                        --current <harness:model:effort[:provider]>
#                        --rules <crew-dispatch.json>
#                        --history <task.model-switch.log>
#                        [--routine]
#                        [--candidates <harness:model:effort[:provider],...>]
#                        [--evidence <checkpoint text>]
#                        [--decision <escalate|move-provider|reduce|stay>]
#                        [--rule <zero-based-index|default>]
#                        [--selected <harness:model:effort[:provider]>]
#                        [--confirm-unmeasured-quota]
#
# Prints one action block:
#   action=hold|live-switch|relaunch
#   jev=off|unused|on|ambiguous|error|never-send
#   reason=<text>
#   harness=... model=... effort=... provider=...   (when not hold)
#
# Jev classifies only bounded decisions when configured; otherwise hold for
# firstmate judgment. --decision supplies that explicit judgment.
# --rule selects a zero-based rule index or default after reassessment.
# --candidates restricts that rule's alternatives. --selected supplies the
# profile chosen by firstmate through quota-array-dispatch, including every
# candidate's capability, authentication, context and quota evidence.
# No array ordering or effort rank is used as a capability classifier.
# --selected and --decision use the same profile/decision tokens as output.
# --history must name this task's switch log, even before it exists; a missing
# file means zero attempts. Attempted, applied, refused, failed, partial,
# timeout, and cancelled entries count, deduplicated by request for the bound.
# FM_PROFILE_SWITCH_COOLDOWN_SECS sets the selector cooldown (default 600).
# FM_PROFILE_SWITCH_MAX_PER_HOUR sets its hourly attempt bound (default 3).
# These bounds apply to selection; the direct control verb does not run them.
# An unmeasured destination quota holds unless --confirm-unmeasured-quota
# records the supervisor's explicit confirmation; a confirmed live-switch must
# pass the same flag to fm-control.sh switch-model. Measured exhaustion holds.
set -eu

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pi-switch-lib.sh
. "$SCRIPT_DIR/fm-pi-switch-lib.sh"
# shellcheck source=bin/fm-env-lib.sh
. "$SCRIPT_DIR/fm-env-lib.sh"

TS_MODEL=jev-latest
TS_BASE=https://api.typesafe.ai
TS_TIMEOUT=5
JEV_FLOOR=0.6

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

CHECKPOINT=
CURRENT=
RULES=
HISTORY=
ROUTINE=0
CANDIDATES=
EVIDENCE=
DECISION=
RULE=
SELECTED=
CONFIRM_UNMEASURED=0

want=
for arg in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      checkpoint) CHECKPOINT=$arg ;;
      current) CURRENT=$arg ;;
      rules) RULES=$arg ;;
      history) HISTORY=$arg ;;
      candidates) CANDIDATES=$arg ;;
      evidence) EVIDENCE=$arg ;;
      decision) DECISION=$arg ;;
      rule) RULE=$arg ;;
      selected) SELECTED=$arg ;;
    esac
    want=
    continue
  fi
  case "$arg" in
    --checkpoint) want=checkpoint ;;
    --checkpoint=*) CHECKPOINT=${arg#--checkpoint=} ;;
    --current) want=current ;;
    --current=*) CURRENT=${arg#--current=} ;;
    --rules) want=rules ;;
    --rules=*) RULES=${arg#--rules=} ;;
    --history) want=history ;;
    --history=*) HISTORY=${arg#--history=} ;;
    --candidates) want=candidates ;;
    --candidates=*) CANDIDATES=${arg#--candidates=} ;;
    --evidence) want=evidence ;;
    --evidence=*) EVIDENCE=${arg#--evidence=} ;;
    --decision) want=decision ;;
    --rule) want=rule ;;
    --selected) want=selected ;;
    --routine) ROUTINE=1 ;;
    --confirm-unmeasured-quota) CONFIRM_UNMEASURED=1 ;;
    *) echo "error: unexpected argument '$arg'" >&2; exit 2 ;;
  esac
done
[ -z "$want" ] || { echo "error: --$want requires a value" >&2; exit 2; }

case "$CHECKPOINT" in
  complexity|stall|phase|quota) ;;
  *) echo "error: --checkpoint must be complexity, stall, phase, or quota" >&2; exit 2 ;;
esac
[ -n "$CURRENT" ] || { echo "error: --current is required" >&2; exit 2; }
[ -n "$HISTORY" ] || { echo "error: --history must name the task switch history (even before its first switch)" >&2; exit 2; }
if [ -e "$HISTORY" ] || [ -L "$HISTORY" ]; then
  [ -f "$HISTORY" ] && [ -r "$HISTORY" ] || { echo "error: --history must be a readable file" >&2; exit 2; }
fi
[ -n "$RULES" ] && [ -f "$RULES" ] || { echo "error: --rules must be an existing crew-dispatch.json" >&2; exit 2; }

CUR_HARNESS=${CURRENT%%:*}
[ -n "$CUR_HARNESS" ] || { echo "error: --current needs harness:model:effort" >&2; exit 2; }

if [ -z "$TYPESAFE_API_KEY_PRIVATE" ]; then
  TYPESAFE_API_KEY_PRIVATE=$(fmx_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
fi
if [ -n "$TYPESAFE_API_KEY_PRIVATE" ]; then
  JEV=unused
else
  JEV=off
fi

emit() {  # <action> <reason> [harness model effort provider]
  local action=$1 reason=$2
  printf 'action=%s\n' "$action"
  printf 'jev=%s\n' "$JEV"
  printf 'reason=%s\n' "$reason"
  if [ "$#" -ge 6 ]; then
    printf 'harness=%s\n' "$3"
    printf 'model=%s\n' "$4"
    printf 'effort=%s\n' "$5"
    printf 'provider=%s\n' "$6"
  fi
}

decision=$DECISION
case "$CHECKPOINT:$decision:$ROUTINE" in
  *::*) ;;
  *:stay:*) ;;
  complexity:escalate:*|stall:escalate:*|phase:escalate:*|quota:move-provider:*|phase:reduce:1) ;;
  *) echo "error: decision is not allowed at this checkpoint" >&2; exit 2 ;;
esac

if [ -f "$HISTORY" ]; then
  now=$(date +%s)
  cooldown=${FM_PROFILE_SWITCH_COOLDOWN_SECS:-600}
  max_hour=${FM_PROFILE_SWITCH_MAX_PER_HOUR:-3}
  last=$(awk '
    $0 ~ / status=(attempted|applied|refused|failed|partial|timeout|cancelled)($| )/ {
      ts = 0
      if (match($0, /ts=[0-9]+/)) ts = substr($0, RSTART + 3, RLENGTH - 3) + 0
      if (ts > last) last = ts
    }
    END { print last + 0 }
  ' "$HISTORY")
  if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$cooldown" ]; then
    emit hold "cooldown $((cooldown - (now - last)))s remaining"
    exit 0
  fi
  hour_ago=$((now - 3600))
  count=$(awk -v since="$hour_ago" '
    $0 ~ / status=(attempted|applied|refused|failed|partial|timeout|cancelled)($| )/ {
      ts = 0
      if (match($0, /ts=[0-9]+/)) ts = substr($0, RSTART + 3, RLENGTH - 3) + 0
      req = $0; sub(/^.* req=/, "", req); sub(/ .*/, "", req)
      if (ts >= since && !seen[req]++) n++
    }
    END { print n + 0 }
  ' "$HISTORY")
  if [ "$count" -ge "$max_hour" ]; then
    emit hold "retry bound $max_hour switches in the last hour"
    exit 0
  fi
fi

# Succeeds when the request must not be sent: a never-send line matches one
# of its strings, or the list exists but cannot be checked.
never_send_hit() {  # <request-json>
  local list="$CONFIG/dispatch-never-send" text lines value rc
  [ -e "$list" ] || [ -L "$list" ] || return 1
  { [ -f "$list" ] && [ -r "$list" ]; } || return 0
  text=$(jq -r '.. | strings | gsub("\\s+"; " ")' <<<"$1" 2>/dev/null) || return 0
  lines=$(jq -Rr 'gsub("\\s+"; " ")' "$list" 2>/dev/null) || return 0
  while IFS= read -r value; do
    value=${value# }
    value=${value% }
    case "$value" in
      ''|'#'*) continue ;;
    esac
    rc=0
    printf '%s\n' "$text" | grep -qiF -e "$value" 2>/dev/null || rc=$?
    [ "$rc" = 1 ] || return 0
  done <<<"$lines"
  return 1
}

jev_classify() {
  local allowed request resp http answer
  allowed='["escalate","stay"]'
  case "$CHECKPOINT" in
    quota) allowed='["move-provider","stay"]' ;;
    phase) [ "$ROUTINE" = 1 ] && allowed='["escalate","reduce","stay"]' ;;
  esac
  request=$(jq -n --arg model "$TS_MODEL" --arg kind "$CHECKPOINT" \
    --argjson routine "$([ "$ROUTINE" = 1 ] && echo true || echo false)" \
    --arg evidence "$EVIDENCE" --argjson allowed "$allowed" '
    {
      escalate: "The evidence shows the current worker profile is inadequate for the remaining work: newly discovered complexity or repeated failure without progress.",
      "move-provider": "The current provider quota is constrained enough that the worker should continue on another provider of equal capability.",
      reduce: "The remaining phase is explicitly routine and independently verifiable, so a lower-cost profile is sufficient.",
      stay: "The evidence does not justify changing the worker profile now."
    } as $all |
    {
      model: $model,
      state: {checkpoint: {kind: $kind, routine: $routine, evidence: $evidence}},
      questions: {
        decision: {
          type: "choice",
          instructions: "A coding worker reported `checkpoint`. Which ONE decision does its evidence support? Prefer `stay` unless the evidence clearly supports another option.",
          criteria: ($all | with_entries(select(.key as $k | $allowed | index($k))))
        }
      }
    }') || { JEV=error; return; }
  if never_send_hit "$request"; then
    JEV=never-send
    return
  fi
  command -v curl >/dev/null 2>&1 || { JEV=error; return; }
  resp=$(mktemp) || { JEV=error; return; }
  http=$(printf '%s' "$request" | curl -sS --max-time "$TS_TIMEOUT" -o "$resp" -w '%{http_code}' \
    -X POST "$TS_BASE/v1/systemone" -H 'Content-Type: application/json' \
    -H @/dev/fd/3 3< <(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY_PRIVATE") \
    --data-binary @- 2>/dev/null) || http=000
  answer=$(jq -r --argjson allowed "$allowed" --argjson floor "$JEV_FLOOR" '
    .answers.decision as $a
    | if ($a.choice | type) != "string" or ($allowed | index($a.choice)) == null
         or ($a.confidence | type) != "number" then "error"
      elif $a.confidence < $floor then "ambiguous"
      else "on " + $a.choice end
  ' "$resp" 2>/dev/null) || answer=error
  rm -f "$resp"
  [ "$http" = 200 ] || answer=error
  case "$answer" in
    on\ *) JEV=on; decision=${answer#on } ;;
    ambiguous) JEV=ambiguous ;;
    *) JEV=error ;;
  esac
}

if [ -z "$decision" ] && [ -n "$TYPESAFE_API_KEY_PRIVATE" ]; then
  jev_classify
fi

if [ "$decision" = stay ]; then
  emit hold "checkpoint $CHECKPOINT does not authorize a profile change"
  exit 0
fi

if [ -z "$decision" ]; then
  emit hold "firstmate judgment required: supply --decision after reviewing checkpoint evidence"
  exit 0
fi
if [ -z "$RULE" ] || [ -z "$SELECTED" ]; then
  emit hold "firstmate must reassess the matched rule and select through quota-array-dispatch; supply --rule and --selected"
  exit 0
fi

pick=$(jq -ce --arg rule "$RULE" --arg candidates "$CANDIDATES" --arg selected "$SELECTED" '
  def profile:
    split(":") | if length < 3 or length > 4 then error("invalid profile") else
    {harness: .[0], model: .[1], effort: .[2], provider: (.[3] // "")} end;
  def norm: {harness, model: (.model // ""), effort: (.effort // ""), provider: (.provider // "")};
  (if $rule == "default" then .default
   elif ($rule | test("^[0-9]+$")) then .rules[$rule | tonumber].use
   else error("invalid rule") end) |
  (if type == "object" then [.] else . end) |
  if type != "array" or length == 0 then error("missing rule profiles") else . end |
  map(norm) as $eligible |
  (if $candidates == "" then $eligible else $candidates | split(",") | map(profile) end) as $subset |
  if any($subset[]; . as $p | ($eligible | index($p)) == null) then error("candidate outside matched rule") else . end |
  ($selected | profile) as $pick |
  if ($subset | index($pick)) == null then error("selection outside candidates") else $pick end
' "$RULES") || { echo "error: invalid matched-rule selection" >&2; exit 1; }

PICK_HARNESS=$(printf '%s' "$pick" | jq -r '.harness')
PICK_MODEL=$(printf '%s' "$pick" | jq -r '.model // empty')
PICK_EFFORT=$(printf '%s' "$pick" | jq -r '.effort // empty')
PICK_PROVIDER=$(printf '%s' "$pick" | jq -r '.provider // empty')

if [ "$decision" = move-provider ]; then
  # Compare quota providers across harnesses, including native profiles whose
  # provider is implicit. A harness change alone does not escape a quota bound.
  # shellcheck source=bin/fm-quota-axi-lib.sh
  . "$SCRIPT_DIR/fm-quota-axi-lib.sh"
  IFS=: read -r _cur_harness _cur_model _cur_effort current_provider <<< "$CURRENT"
  if [ -z "$current_provider" ]; then
    case "$CUR_HARNESS" in
      pi|pi-signed)
        if parsed_current=$(fm_pi_switch_parse_model "$_cur_model"); then
          current_provider=${parsed_current%%$'\t'*}
          case "$current_provider" in
            openai-codex) current_provider=codex ;;
            xai) current_provider=grok ;;
            anthropic) current_provider=claude ;;
          esac
        fi
        ;;
      *) current_provider=$(fm_quota_single_provider_for_harness "$CUR_HARNESS" || true) ;;
    esac
  fi
  selected_provider=${PICK_PROVIDER:-$(fm_quota_single_provider_for_harness "$PICK_HARNESS" || true)}
  if [ -z "$current_provider" ] || [ -z "$selected_provider" ] || [ "$current_provider" = "$selected_provider" ]; then
    emit hold "quota move requires an eligible replacement on a different provider"
    exit 0
  fi
fi

quota_rc=0
quota_note=
quota_err=$(fm_pi_switch_quota_ready "$PICK_HARNESS" "$PICK_MODEL" "$PICK_PROVIDER" 2>&1) || quota_rc=$?
if [ "$quota_rc" = 2 ] && [ "$CONFIRM_UNMEASURED" = 1 ]; then
  quota_note="; unmeasured destination quota confirmed by supervisor"
elif [ "$quota_rc" = 2 ]; then
  printf '%s\n' "$quota_err" >&2
  emit hold "selected destination quota is unmeasured; supervisor must confirm with --confirm-unmeasured-quota"
  exit 0
elif [ "$quota_rc" != 0 ]; then
  printf '%s\n' "$quota_err" >&2
  emit hold "selected destination failed quota preflight"
  exit 0
fi

if [ "$PICK_HARNESS" = "$CUR_HARNESS" ] && { [ "$PICK_HARNESS" = pi ] || [ "$PICK_HARNESS" = pi-signed ]; }; then
  [ -z "$quota_note" ] || quota_note="$quota_note; pass --confirm-unmeasured-quota to switch-model"
  emit live-switch "checkpoint $CHECKPOINT decision $decision$quota_note" \
    "$PICK_HARNESS" "$PICK_MODEL" "$PICK_EFFORT" "$PICK_PROVIDER"
  exit 0
fi

emit relaunch "checkpoint $CHECKPOINT decision $decision requires a harness change$quota_note" \
  "$PICK_HARNESS" "$PICK_MODEL" "$PICK_EFFORT" "$PICK_PROVIDER"
