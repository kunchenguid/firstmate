#!/usr/bin/env bash
# Shared validation, state hydration, and pure ranking for fm-route.sh.

FM_ROUTING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROUTE_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_ROUTING_LIB_DIR/.." && pwd)}"
FM_ROUTE_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROUTE_ROOT}}"
FM_ROUTE_STATE="${FM_ROUTE_STATE_OVERRIDE:-${FM_STATE_OVERRIDE:-$FM_ROUTE_HOME/state}/routing}"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_ROUTING_LIB_DIR/fm-wake-lib.sh"

fm_route_diagnostic() {
  printf 'fm-route: %s\n' "$1" >&2
}

fm_route_json_is_single_value() {
  jq -se 'length == 1' "$1" >/dev/null 2>&1
}

fm_route_validate_request() {
  local file=$1 reason
  fm_route_json_is_single_value "$file" || {
    fm_route_diagnostic 'invalid request JSON'
    return 1
  }
  reason=$(jq -r '
    def expected: ["taskId","taskClass","workType","risk","independent","requestedWorkers","requiredReasoningClass","estimatedSeconds"];
    def missing: . as $document | [expected[] as $key | select($document | has($key) | not) | $key];
    def unexpected: [(keys_unsorted - expected)[]];
    if type != "object" then "top-level value must be an object"
    elif (missing | length) > 0 then "missing \(missing[0])"
    elif (unexpected | length) > 0 then "unexpected field \(unexpected[0])"
    elif (.taskId | type) != "string" or (.taskId | length) == 0 then "taskId"
    elif (.taskClass | IN("trivial","standard","decomposable","ambiguous","high_risk") | not) then "taskClass"
    elif (.workType | type) != "string" or (.workType | length) == 0 then "workType"
    elif (.risk | IN("low","medium","high") | not) then "risk"
    elif (.independent | type) != "boolean" then "independent"
    elif (.requestedWorkers | type) != "number" or (.requestedWorkers | floor) != .requestedWorkers or .requestedWorkers < 1 or .requestedWorkers > 8 then "requestedWorkers"
    elif (.requiredReasoningClass | IN("basic","standard","strong","maximum") | not) then "requiredReasoningClass"
    elif (.estimatedSeconds | type) != "number" or (.estimatedSeconds | floor) != .estimatedSeconds or .estimatedSeconds < 1 then "estimatedSeconds"
    else "ok"
    end
  ' "$file" 2>/dev/null) || {
    fm_route_diagnostic 'invalid request JSON'
    return 1
  }
  [ "$reason" = ok ] || {
    fm_route_diagnostic "invalid request schema: $reason"
    return 1
  }
}

fm_route_validate_candidates() {
  local file=$1 reason
  fm_route_json_is_single_value "$file" || {
    fm_route_diagnostic 'invalid candidates JSON'
    return 1
  }
  reason=$(jq -r '
    def expected: ["profile","harness","model","provider","lane","account","fitTier","reasoningClass","catalogSupported","authState","spendPriority","runwaySeconds","activeLane","historySuccesses","historyAttempts","costTier"];
    def item_error:
      . as $candidate
      | ([expected[] | select(. as $k | $candidate | has($k) | not)]) as $missing
      | ([$candidate | keys_unsorted[] | select(. as $k | expected | index($k) | not)]) as $unexpected
      | if ($missing | length) > 0 then "missing \($missing[0])"
        elif ($unexpected | length) > 0 then "unexpected field \($unexpected[0])"
        elif (.profile | type) != "string" or (.profile | length) == 0 then "profile"
        elif (.harness | IN("claude","codex","pi","pi-signed") | not) then "harness"
        elif (.model | type) != "string" or (.model | length) == 0 then "model"
        elif (.provider | type) != "string" or (.provider | length) == 0 then "provider"
        elif (.lane | type) != "string" or (.lane | length) == 0 then "lane"
        elif (.account | type) != "string" or (.account | test("^(none|[a-z0-9][a-z0-9-]*)$") | not) then "account"
        elif ((.harness == "pi" or .harness == "pi-signed") and .account != "none") then "account"
        elif ((.harness == "claude" or .harness == "codex") and .account == "none") then "account"
        elif (.fitTier | type) != "number" or (.fitTier | floor) != .fitTier or .fitTier < 0 then "fitTier"
        elif (.reasoningClass | IN("basic","standard","strong","maximum") | not) then "reasoningClass"
        elif (.catalogSupported | type) != "boolean" then "catalogSupported"
        elif (.authState != null and (.authState | IN("usable","unusable","unknown") | not)) then "authState"
        elif (.spendPriority != null and (.spendPriority | type) != "number") then "spendPriority"
        elif (.runwaySeconds != null and ((.runwaySeconds | type) != "number" or .runwaySeconds < 0)) then "runwaySeconds"
        elif (.activeLane | type) != "number" or (.activeLane | floor) != .activeLane or .activeLane < 0 then "activeLane"
        elif (.historySuccesses | type) != "number" or (.historySuccesses | floor) != .historySuccesses or .historySuccesses < 0 then "historySuccesses"
        elif (.historyAttempts | type) != "number" or (.historyAttempts | floor) != .historyAttempts or .historyAttempts < 0 then "historyAttempts"
        elif .historySuccesses > .historyAttempts then "historySuccesses"
        elif (.costTier != null and ((.costTier | type) != "number" or (.costTier | floor) != .costTier or .costTier < 0)) then "costTier"
        else "ok"
        end;
    if type != "array" then "top-level value must be an array"
    else ([to_entries[] | select(.value | item_error != "ok") | "at index \(.key): \(.value | item_error)"]) as $errors
      | if ($errors | length) > 0 then $errors[0]
        else ([group_by(.profile)[] | select(length > 1) | .[0].profile][0]) as $duplicate
          | if $duplicate != null then "duplicate profile \($duplicate)" else "ok" end
        end
    end
  ' "$file" 2>/dev/null) || {
    fm_route_diagnostic 'invalid candidates JSON'
    return 1
  }
  [ "$reason" = ok ] || {
    fm_route_diagnostic "invalid candidate schema: $reason"
    return 1
  }
}

fm_route_worker_budget() {
  local task_class=$1 independent=$2 requested=$3 cap=1
  case "$task_class:$independent" in
    decomposable:true) cap=4 ;;
    ambiguous:true|high_risk:true) cap=2 ;;
  esac
  if [ "$requested" -lt "$cap" ]; then
    printf '%s\n' "$requested"
  else
    printf '%s\n' "$cap"
  fi
}

fm_route_read_reservations() {
  local first
  set -- "$FM_ROUTE_STATE"/reservations/*.json
  first=${1:-}
  if [ ! -e "$first" ]; then
    printf '[]\n'
    return 0
  fi
  jq -s 'if all(type == "object") then . else error("invalid") end' "$@" 2>/dev/null
}

fm_route_read_outcomes() {
  local file="$FM_ROUTE_STATE/outcomes.jsonl"
  if [ ! -s "$file" ]; then
    printf '[]\n'
    return 0
  fi
  jq -s 'if all(type == "object") then . else error("invalid") end' "$file" 2>/dev/null
}

fm_route_select_ranked() {
  local request=$1 candidates=$2 reservations=$3 outcomes=$4 max_workers=$5
  jq -n \
    --slurpfile req "$request" \
    --slurpfile pool "$candidates" \
    --argjson reservations "$reservations" \
    --argjson outcomes "$outcomes" \
    --argjson maxWorkers "$max_workers" '
      def reason_rank: {basic:1,standard:2,strong:3,maximum:4}[.] // 0;
      def primary_key: [.fitTier, (if .spendPriority == null then 0 else 1 end), (.spendPriority // 0), (-.activeLane)];
      def rank_key: [-.fitTier, (if .spendPriority == null then 1 else 0 end), (-(.spendPriority // 0)), .activeLane, .profile];
      def reasons($request):
        [if .catalogSupported != true then "catalog-unsupported" else empty end,
         if .authState == "unusable" then "auth-unusable" else empty end,
         if (.reasoningClass | reason_rank) < ($request.requiredReasoningClass | reason_rank) then "reasoning-insufficient" else empty end,
         if .runwaySeconds != null and .runwaySeconds < $request.estimatedSeconds then "runway-insufficient" else empty end];
      def uncertainty:
        . as $candidate
        |
        [if .authState == null or .authState == "unknown" then "auth" else empty end,
         if .spendPriority == null then "quota" else empty end,
         if .runwaySeconds == null then "runway" else empty end,
         if .costTier == null then "cost" else empty end]
        | if length == 0 then empty else "\($candidate.profile):\(join(","))" end;
      ($req[0]) as $request
      | ($pool[0] | map(
          . as $candidate
          | .activeLane = ([$reservations[] | select(.lane? == $candidate.lane)] | length)
          | .historyAttempts = ([$outcomes[] | select(.profile? == $candidate.profile and .workType? == $request.workType)] | length)
          | .historySuccesses = ([$outcomes[] | select(.profile? == $candidate.profile and .workType? == $request.workType and .terminal? == "completed")] | length)
        )) as $hydrated
      | ([$hydrated[] | select((reasons($request) | length) == 0)] | sort_by(rank_key)) as $eligible
      | ([$hydrated[] | (reasons($request)) as $why | select(($why | length) > 0) | {profile:.profile,reasons:$why}]) as $rejected
      | ([$eligible[] | uncertainty]) as $uncertainty
      | if ($eligible | length) == 0 then
          {action:"escalate",reason:"no-qualified-profile",selected:null,ranked:[],rejected:$rejected,uncertainty:$uncertainty,maxWorkers:$maxWorkers}
        else
          ($eligible | map(primary_key) | max) as $best
          | ($eligible | map(select(primary_key == $best))) as $primary
          | (if ($primary | length) > 1 and ($primary | map(.historyAttempts) | unique | length) == 1 then
               ($primary | map(.historySuccesses) | max) as $wins
               | $primary | map(select(.historySuccesses == $wins))
             else $primary end) as $history
          | (if ($history | length) > 1 and ($history | all(.costTier != null)) then
               ($history | map(.costTier) | min) as $cost
               | $history | map(select(.costTier == $cost))
             else $history end) as $finalists
          | if ($finalists | length) == 1 then
              {action:"selected",reason:"lexicographic-policy",selected:$finalists[0],ranked:$eligible,rejected:$rejected,uncertainty:$uncertainty,maxWorkers:$maxWorkers}
            else
              {action:"escalate",reason:"evidence-tie",selected:null,ranked:$eligible,rejected:$rejected,uncertainty:$uncertainty,maxWorkers:$maxWorkers}
            end
        end
    '
}

fm_route_select() {
  local request=$1 candidates=$2 max_workers reservations outcomes rc lock
  max_workers=$(jq -r '[.taskClass,.independent,.requestedWorkers] | @tsv' "$request") || return 1
  # shellcheck disable=SC2086
  max_workers=$(fm_route_worker_budget $max_workers) || return 1
  mkdir -p "$FM_ROUTE_STATE/reservations"
  lock="$FM_ROUTE_STATE/.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if ! reservations=$(fm_route_read_reservations) || ! outcomes=$(fm_route_read_outcomes); then
    fm_lock_release "$lock"
    fm_route_diagnostic 'invalid routing state'
    return 1
  fi
  if fm_route_select_ranked "$request" "$candidates" "$reservations" "$outcomes" "$max_workers"; then
    rc=0
  else
    rc=$?
  fi
  fm_lock_release "$lock"
  return "$rc"
}
