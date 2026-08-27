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

fm_routing_with_lock() {
  local lock="$FM_ROUTE_STATE/.lock" rc
  mkdir -p "$FM_ROUTE_STATE"
  fm_lock_acquire_wait "$lock" || return 1
  if "$@"; then rc=0; else rc=$?; fi
  fm_lock_release "$lock"
  return "$rc"
}

fm_route_atomic_json_value() {
  local destination=$1 value=$2 directory temporary
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.routing-json.XXXXXX") || return 1
  if printf '%s\n' "$value" | jq -e . >"$temporary" 2>/dev/null; then
    mv -f "$temporary" "$destination"
  else
    rm -f "$temporary"
    return 1
  fi
}

fm_route_validate_identifier() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_route_validate_route_tuple() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 risk=$8 mode=$9
  fm_route_validate_identifier "$task" || { fm_route_diagnostic 'invalid task identifier'; return 1; }
  fm_route_validate_identifier "$generation" || { fm_route_diagnostic 'invalid generation identifier'; return 1; }
  fm_route_validate_identifier "$profile" || { fm_route_diagnostic 'invalid profile identifier'; return 1; }
  fm_route_validate_identifier "$provider" || { fm_route_diagnostic 'invalid provider identifier'; return 1; }
  fm_route_validate_identifier "$lane" || { fm_route_diagnostic 'invalid lane identifier'; return 1; }
  fm_route_validate_identifier "$account" || { fm_route_diagnostic 'invalid account identifier'; return 1; }
  case "$task_class" in trivial|standard|decomposable|ambiguous|high_risk) ;; *) fm_route_diagnostic 'invalid task class'; return 1 ;; esac
  case "$risk" in low|medium|high) ;; *) fm_route_diagnostic 'invalid risk'; return 1 ;; esac
  case "$mode" in off|simulate|canary|automatic) ;; *) fm_route_diagnostic 'invalid routing mode'; return 1 ;; esac
}

fm_route_read_circuits() {
  local file="$FM_ROUTE_STATE/circuits.json"
  if [ ! -s "$file" ]; then
    printf '{"lanes":{}}\n'
    return 0
  fi
  jq -ce 'select(type == "object" and (.lanes | type) == "object")' "$file" 2>/dev/null
}

fm_route_write_circuits() {
  fm_route_atomic_json_value "$FM_ROUTE_STATE/circuits.json" "$1"
}

fm_route_reserve_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 risk=$8 mode=$9 burst=${10} now=${11}
  local reservation="$FM_ROUTE_STATE/reservations/$task.json" reservations circuits existing total lane_total account_total cap updated
  mkdir -p "$FM_ROUTE_STATE/reservations"
  if [ -e "$reservation" ]; then
    existing=$(jq -c . "$reservation" 2>/dev/null) || { fm_route_diagnostic 'invalid routing state'; return 1; }
    if jq -e --arg generation "$generation" --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" --arg account "$account" --arg class "$task_class" --arg risk "$risk" --arg mode "$mode" --argjson burst "$burst" '
      .generation == $generation and .profile == $profile and .provider == $provider and .lane == $lane and .account == $account and .taskClass == $class and .risk == $risk and .mode == $mode and .burst == $burst
    ' <<<"$existing" >/dev/null; then
      printf '%s\n' "$existing"
      return 0
    fi
    fm_route_diagnostic 'reservation-conflict'
    return 1
  fi
  case "$mode" in
    off|simulate) fm_route_diagnostic "mode-does-not-reserve:$mode"; return 1 ;;
    canary) cap=3 ;;
    automatic) cap=6 ;;
  esac
  if [ "$burst" = true ]; then
    [ "$mode" = automatic ] && [ "$task_class" = decomposable ] && [ "$risk" = low ] || {
      fm_route_diagnostic 'burst-requires-decomposable-low-risk'
      return 1
    }
    cap=8
  fi
  reservations=$(fm_route_read_reservations) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  circuits=$(fm_route_read_circuits) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  if jq -e --arg lane "$lane" --argjson now "$now" '.lanes[$lane].openUntil? > $now' <<<"$circuits" >/dev/null; then
    fm_route_diagnostic 'circuit-open'
    return 1
  fi
  if jq -e --arg lane "$lane" --argjson now "$now" '.lanes[$lane].openUntil? != null and .lanes[$lane].openUntil <= $now' <<<"$circuits" >/dev/null; then
    circuits=$(jq -c --arg lane "$lane" 'del(.lanes[$lane])' <<<"$circuits")
    fm_route_write_circuits "$circuits" || return 1
  fi
  total=$(jq 'length' <<<"$reservations")
  [ "$total" -lt "$cap" ] || { fm_route_diagnostic "global-cap:$cap"; return 1; }
  lane_total=$(jq --arg lane "$lane" '[.[] | select(.lane == $lane)] | length' <<<"$reservations")
  [ "$lane_total" -lt 2 ] || { fm_route_diagnostic 'lane-cap:2'; return 1; }
  if [ "$account" != none ]; then
    account_total=$(jq --arg account "$account" '[.[] | select(.account == $account)] | length' <<<"$reservations")
    [ "$account_total" -lt 2 ] || { fm_route_diagnostic 'account-cap:2'; return 1; }
  fi
  updated=$(jq -cn --arg task "$task" --arg generation "$generation" --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" --arg account "$account" --arg class "$task_class" --arg risk "$risk" --arg mode "$mode" --argjson burst "$burst" --argjson now "$now" \
    '{taskId:$task,generation:$generation,profile:$profile,provider:$provider,lane:$lane,account:$account,taskClass:$class,risk:$risk,mode:$mode,burst:$burst,createdAt:$now,score:null}')
  fm_route_atomic_json_value "$reservation" "$updated" || return 1
  printf '%s\n' "$updated"
}

fm_route_verify_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 risk=$8 mode=$9 reservation="$FM_ROUTE_STATE/reservations/$1.json"
  [ -s "$reservation" ] || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  jq -e --arg generation "$generation" --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" --arg account "$account" --arg class "$task_class" --arg risk "$risk" --arg mode "$mode" '
    .generation == $generation and .profile == $profile and .provider == $provider and .lane == $lane and .account == $account and .taskClass == $class and .risk == $risk and .mode == $mode
  ' "$reservation" >/dev/null 2>&1 || { fm_route_diagnostic 'reservation-mismatch'; return 1; }
  jq -c . "$reservation"
}

fm_route_release_locked() {
  local generation=$2 reservation="$FM_ROUTE_STATE/reservations/$1.json"
  if [ ! -e "$reservation" ]; then
    printf '{"released":false,"idempotent":true}\n'
    return 0
  fi
  [ "$(jq -r '.generation // empty' "$reservation" 2>/dev/null)" = "$generation" ] || {
    fm_route_diagnostic 'reservation-generation-mismatch'
    return 1
  }
  rm -f -- "$reservation"
  printf '{"released":true,"idempotent":false}\n'
}

fm_routing_failure_action() {
  case "$1" in
    transient) [ "$2" -lt 1 ] && printf 'retry\n' || printf 'fallback\n' ;;
    quota|auth|model) printf 'fallback\n' ;;
    unsafe) printf 'escalate\n' ;;
  esac
}

fm_route_failure_locked() {
  local task=$1 generation=$2 provider=$3 lane=$4 kind=$5 now=$6 circuits existing prior_transients action failures open_until updated
  circuits=$(fm_route_read_circuits) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  existing=$(jq -c --arg lane "$lane" --arg task "$task" --arg generation "$generation" '.lanes[$lane].failures // [] | map(select(.taskId == $task and .generation == $generation)) | first // empty' <<<"$circuits")
  if [ -n "$existing" ]; then
    jq -cn --arg action "$(jq -r .action <<<"$existing")" --argjson until "$(jq -r '.until // null' <<<"$existing")" '{action:$action} + (if $until == null then {} else {until:$until} end)'
    return 0
  fi
  if jq -e --arg lane "$lane" --argjson now "$now" '.lanes[$lane].openUntil? > $now' <<<"$circuits" >/dev/null; then
    jq -cn --argjson until "$(jq -r --arg lane "$lane" '.lanes[$lane].openUntil' <<<"$circuits")" '{action:"circuit-open",until:$until}'
    return 0
  fi
  prior_transients=$(jq --arg lane "$lane" --arg task "$task" '[.lanes[$lane].failures[]? | select(.taskId == $task and .kind == "transient")] | length' <<<"$circuits")
  action=$(fm_routing_failure_action "$kind" "$prior_transients")
  failures=$(jq -c --arg lane "$lane" --argjson cutoff "$((now - 900))" '[.lanes[$lane].failures[]? | select(.timestamp >= $cutoff)]' <<<"$circuits")
  if [ "$(jq 'length' <<<"$failures")" -ge 2 ]; then
    action=circuit-open
    open_until=$((now + 1800))
  else
    open_until=null
  fi
  updated=$(jq -c --arg lane "$lane" --arg provider "$provider" --arg task "$task" --arg generation "$generation" --arg kind "$kind" --arg action "$action" --argjson now "$now" --argjson until "$open_until" --argjson failures "$failures" '
    .lanes[$lane] = {provider:$provider,failures:($failures + [{taskId:$task,generation:$generation,kind:$kind,timestamp:$now,action:$action,until:$until}]),openUntil:$until}
  ' <<<"$circuits")
  fm_route_write_circuits "$updated" || return 1
  jq -cn --arg action "$action" --argjson until "$open_until" '{action:$action} + (if $until == null then {} else {until:$until} end)'
}

fm_route_forbidden_outcome_field() {
  jq -r '[paths as $path | ($path[-1] | tostring) as $key | select(["prompt","source","sourceCode","code","apiKey","token","secret","password","cookie","authorization","toolOutput","payload"] | index($key)) | $key] | first // empty' 2>/dev/null
}

fm_route_validate_extra_json() {
  local extra=$1 forbidden unexpected
  jq -e 'type == "object"' <<<"$extra" >/dev/null 2>&1 || { fm_route_diagnostic 'invalid outcome JSON'; return 1; }
  forbidden=$(fm_route_forbidden_outcome_field <<<"$extra") || { fm_route_diagnostic 'invalid outcome JSON'; return 1; }
  [ -z "$forbidden" ] || { fm_route_diagnostic "forbidden outcome field: $forbidden"; return 1; }
  unexpected=$(jq -r 'keys_unsorted[0] // empty' <<<"$extra")
  [ -z "$unexpected" ] || { fm_route_diagnostic "unexpected outcome field: $unexpected"; return 1; }
}

fm_route_score_locked() {
  local task=$1 generation=$2 terminal=$3 tests=$4 review=$5 redundant=$6 now=$7 reservation="$FM_ROUTE_STATE/reservations/$1.json" current updated
  [ -s "$reservation" ] || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  current=$(jq -c . "$reservation" 2>/dev/null) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  [ "$(jq -r '.generation' <<<"$current")" = "$generation" ] || { fm_route_diagnostic 'reservation-generation-mismatch'; return 1; }
  if jq -e '.score != null' <<<"$current" >/dev/null; then
    jq -e --arg terminal "$terminal" --arg tests "$tests" --arg review "$review" --arg redundant "$redundant" '.score.terminal == $terminal and .score.tests == $tests and .score.review == $review and .score.redundant == $redundant' <<<"$current" >/dev/null \
      || { fm_route_diagnostic 'score-conflict'; return 1; }
    jq -c '.score' <<<"$current"
    return 0
  fi
  updated=$(jq -c --arg terminal "$terminal" --arg tests "$tests" --arg review "$review" --arg redundant "$redundant" --argjson now "$now" '.score={terminal:$terminal,tests:$tests,review:$review,redundant:$redundant,timestamp:$now}' <<<"$current")
  fm_route_atomic_json_value "$reservation" "$updated" || return 1
  jq -c '.score' <<<"$updated"
}

fm_routing_rotate_ledger() {
  local file=$1 max_lines=2000 keep_lines=1500 directory temporary lines
  directory=$(dirname "$file")
  mkdir -p "$directory"
  lines=0
  [ ! -f "$file" ] || lines=$(wc -l <"$file")
  [ "$lines" -le "$max_lines" ] || {
    temporary=$(mktemp "$directory/.routing-ledger.XXXXXX") || return 1
    if tail -n "$keep_lines" "$file" >"$temporary"; then
      mv -f "$temporary" "$file"
    else
      rm -f "$temporary"
      return 1
    fi
  }
}

fm_route_append_outcome_locked() {
  local record=$1 file="$FM_ROUTE_STATE/outcomes.jsonl" directory temporary
  directory=$(dirname "$file")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.routing-ledger.XXXXXX") || return 1
  { [ ! -f "$file" ] || cat "$file"; printf '%s\n' "$record"; } >"$temporary" || { rm -f "$temporary"; return 1; }
  jq -s 'all(type == "object")' "$temporary" >/dev/null 2>&1 || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$file" || return 1
  fm_routing_rotate_ledger "$file"
}

fm_route_finalize_locked() {
  local task=$1 generation=$2 terminal=$3 reservation="$FM_ROUTE_STATE/reservations/$1.json" outcomes current score record
  outcomes=$(fm_route_read_outcomes) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  if jq -e --arg task "$task" --arg generation "$generation" 'any(.taskId == $task and .generation == $generation)' <<<"$outcomes" >/dev/null; then
    jq -c --arg task "$task" --arg generation "$generation" '.[] | select(.taskId == $task and .generation == $generation)' <<<"$outcomes" | head -n 1
    return 0
  fi
  [ -s "$reservation" ] || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  current=$(jq -c . "$reservation" 2>/dev/null) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  [ "$(jq -r .generation <<<"$current")" = "$generation" ] || { fm_route_diagnostic 'reservation-generation-mismatch'; return 1; }
  score=$(jq -c '.score // {terminal:null,tests:"unknown",review:"unknown",redundant:"no",timestamp:.createdAt}' <<<"$current")
  if [ "$(jq -r '.terminal // empty' <<<"$score")" != "" ] && [ "$(jq -r .terminal <<<"$score")" != "$terminal" ]; then
    fm_route_diagnostic 'terminal-outcome-mismatch'
    return 1
  fi
  record=$(jq -cn --argjson reservation "$current" --argjson score "$score" --arg terminal "$terminal" '
    {kind:"terminal",timestamp:$score.timestamp,taskId:$reservation.taskId,generation:$reservation.generation,profile:$reservation.profile,provider:$reservation.provider,lane:$reservation.lane,account:$reservation.account,taskClass:$reservation.taskClass,risk:$reservation.risk,mode:$reservation.mode,elapsedSeconds:([$score.timestamp-$reservation.createdAt,0]|max),tests:$score.tests,review:$score.review,redundant:$score.redundant,terminal:$terminal}
  ')
  fm_route_append_outcome_locked "$record" || return 1
  rm -f -- "$reservation"
  printf '%s\n' "$record"
}

fm_route_observe_locked() {
  local request=$1 decision=$2 now=$3 forbidden reason record
  forbidden=$(fm_route_forbidden_outcome_field <"$decision") || { fm_route_diagnostic 'invalid decision JSON'; return 1; }
  [ -z "$forbidden" ] || { fm_route_diagnostic "forbidden outcome field: $forbidden"; return 1; }
  reason=$(jq -r '
    def expected: ["action","maxWorkers","ranked","reason","rejected","selected","uncertainty"];
    if type != "object" then "top-level value must be an object"
    elif (keys_unsorted - expected | length) > 0 then "unexpected field \((keys_unsorted - expected)[0])"
    elif .action != "selected" then "decision must select a profile"
    elif (.selected | type) != "object" then "selected profile is required"
    else "ok" end
  ' "$decision" 2>/dev/null) || { fm_route_diagnostic 'invalid decision JSON'; return 1; }
  [ "$reason" = ok ] || { fm_route_diagnostic "invalid decision schema: $reason"; return 1; }
  record=$(jq -cn --slurpfile request "$request" --slurpfile decision "$decision" --argjson now "$now" '
    ($request[0]) as $r | ($decision[0].selected) as $d |
    {kind:"simulation",timestamp:$now,taskId:$r.taskId,taskClass:$r.taskClass,workType:$r.workType,risk:$r.risk,profile:$d.profile,provider:$d.provider,lane:$d.lane,account:$d.account,elapsedSeconds:$r.estimatedSeconds,terminal:"observed"}
  ')
  fm_route_append_outcome_locked "$record" || return 1
  printf '%s\n' "$record"
}

fm_route_evidence_locked() {
  local work_type=$1 outcomes
  outcomes=$(fm_route_read_outcomes) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  jq -cn --arg workType "$work_type" --argjson outcomes "$outcomes" '$outcomes | map(select(.workType? == $workType)) | group_by(.profile) | map({profile:.[0].profile,successes:([.[] | select(.terminal == "completed")] | length),attempts:length}) | sort_by(.profile)'
}

fm_route_status_locked() {
  local now=$1 reservations circuits mode=off config=${FM_CONFIG_OVERRIDE:-$FM_ROUTE_HOME/config}/crew-dispatch.json
  reservations=$(fm_route_read_reservations) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  circuits=$(fm_route_read_circuits) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  if [ -r "$config" ]; then
    mode=$("$FM_ROUTE_ROOT/bin/fm-dispatch-policy.sh" mode "$config" 2>/dev/null || printf off)
  elif [ "$(jq 'length' <<<"$reservations")" -gt 0 ]; then
    mode=$(jq -r '.[0].mode' <<<"$reservations")
  fi
  jq -cn --arg mode "$mode" --argjson reservations "$reservations" --argjson circuits "$circuits" --argjson now "$now" '
    {mode:$mode,caps:{canary:3,automatic:6,burst:8,perLane:2},active:{total:($reservations|length),byLane:($reservations|group_by(.lane)|map({key:.[0].lane,value:length})|from_entries),byAccount:($reservations|map(select(.account != "none"))|group_by(.account)|map({key:.[0].account,value:length})|from_entries)},openCircuits:([$circuits.lanes|to_entries[]|select(.value.openUntil? > $now)|{lane:.key,provider:.value.provider,until:.value.openUntil}]|sort_by(.lane))}
  '
}

fm_route_report_locked() {
  local stage=$1 minimum=$2 outcomes
  outcomes=$(fm_route_read_outcomes) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  jq -cn --arg stage "$stage" --argjson minimum "$minimum" --argjson outcomes "$outcomes" '
    def median:
      sort as $s | length as $n |
      if $n == 0 then null elif ($n % 2) == 1 then $s[($n/2|floor)] else (($s[$n/2-1]+$s[$n/2])/2) end;
    (if $stage == "simulation" then [$outcomes[] | select(.kind == "simulation")] else [$outcomes[] | select(.kind == "terminal" and .mode == "canary")] end) as $rows |
    {stage:$stage,minimum:$minimum,count:($rows|length),meetsMinimum:(($rows|length)>=$minimum),terminalCounts:($rows|group_by(.terminal)|map({key:.[0].terminal,value:length})|from_entries),testCounts:($rows|map(select(.tests? != null))|group_by(.tests)|map({key:.[0].tests,value:length})|from_entries),reviewCounts:($rows|map(select(.review? != null))|group_by(.review)|map({key:.[0].review,value:length})|from_entries),redundantCount:([$rows[]|select(.redundant? == "yes")]|length),medianElapsedSeconds:([$rows[].elapsedSeconds]|median)}
  '
}
