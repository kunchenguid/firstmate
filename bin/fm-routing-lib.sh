#!/usr/bin/env bash
# Shared validation, state hydration, and pure ranking for fm-route.sh.

FM_ROUTING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROUTE_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_ROUTING_LIB_DIR/.." && pwd)}"
FM_ROUTE_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROUTE_ROOT}}"
FM_ROUTE_STATE="${FM_ROUTE_STATE_OVERRIDE:-${FM_STATE_OVERRIDE:-$FM_ROUTE_HOME/state}/routing}"
FM_ROUTE_TASK_STATE="${FM_STATE_OVERRIDE:-$FM_ROUTE_HOME/state}"
FM_ROUTE_CLAIM_TIMEOUT=300

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
    elif (.taskId | type) != "string" or (.taskId | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") | not) then "taskId"
    elif (.taskClass | IN("trivial","standard","decomposable","ambiguous","high_risk") | not) then "taskClass"
    elif (.workType | type) != "string" or (.workType | test("^[a-z0-9][a-z0-9._-]{0,63}$") | not) then "workType"
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
        elif (.profile | type) != "string" or (.profile | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") | not) then "profile"
        elif (.harness | IN("claude","codex","pi","pi-signed") | not) then "harness"
        elif (.model | type) != "string" or (.model | test("^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$") | not) then "model"
        elif (.provider | type) != "string" or (.provider | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") | not) then "provider"
        elif (.lane | type) != "string" or (.lane | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$") | not) then "lane"
        elif (.account | type) != "string" or (.account | test("^(none|[a-z0-9][a-z0-9-]{0,127})$") | not) then "account"
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

fm_route_static_result() {
  jq -n '{action:"static",reason:"routing-mode-off",selected:null,ranked:[],rejected:[],uncertainty:[],maxWorkers:1}'
}

fm_route_path_has_symlink_component() {
  local path=$1 parent
  case "$path" in
    /*) ;;
    *) return 0 ;;
  esac
  while [ "$path" != / ]; do
    [ ! -L "$path" ] || return 0
    parent=$(dirname "$path")
    [ "$parent" != "$path" ] || return 0
    path=$parent
  done
  return 1
}

fm_route_capture_json_file() {
  local file=$1 label=$2 absolute parent base temporary old_umask result rc
  case "$file" in /*) absolute=$file ;; *) absolute=$PWD/$file ;; esac
  if fm_route_path_has_symlink_component "$absolute" || [ ! -f "$absolute" ] || [ ! -r "$absolute" ]; then
    fm_route_diagnostic "$label file is unsafe or unreadable"
    return 1
  fi
  old_umask=$(umask); umask 077
  temporary=$(mktemp "${TMPDIR:-/tmp}/fm-route-capture.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  parent=$(dirname "$absolute")
  base=$(basename "$absolute")
  if (
    CDPATH='' cd -- "$parent" 2>/dev/null || exit 3
    [ "$(pwd -P)" = "$parent" ] || exit 3
    perl -MFcntl=:DEFAULT -e '
      my ($path, $max, $destination) = @ARGV;
      sysopen(my $source, $path, O_RDONLY | O_NOFOLLOW) or exit 3;
      my @stat = stat $source or exit 3;
      exit 3 unless -f _;
      my $size = $stat[7];
      exit 4 if $size > $max;
      open(my $output, ">", $destination) or exit 5;
      binmode $source; binmode $output;
      my $remaining = $size;
      while ($remaining > 0) {
        my $wanted = $remaining > 65536 ? 65536 : $remaining;
        my $read = read($source, my $buffer, $wanted);
        exit 5 unless defined $read && $read > 0;
        print {$output} $buffer or exit 5;
        $remaining -= $read;
      }
      close $output or exit 5;
    ' "$base" 1048576 "$temporary"
  ); then
    :
  else
    rc=$?
    rm -f "$temporary"
    if [ "$rc" -eq 4 ]; then
      fm_route_diagnostic "$label file is too large"
    else
      fm_route_diagnostic "$label file is unsafe or unreadable"
    fi
    return 1
  fi
  if result=$(jq -c . "$temporary" 2>/dev/null); then
    rm -f "$temporary"
    printf '%s\n' "$result"
  else
    rm -f "$temporary"
    fm_route_diagnostic "invalid $label JSON"
    return 1
  fi
}

fm_route_snapshot_temp() {
  local value=$1 temporary old_umask
  old_umask=$(umask); umask 077
  temporary=$(mktemp "${TMPDIR:-/tmp}/fm-route-snapshot.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  printf '%s\n' "$value" >"$temporary" || { rm -f "$temporary"; return 1; }
  printf '%s\n' "$temporary"
}

fm_route_capture_v2_policy() {
  local config="$FM_ROUTE_HOME/config/crew-dispatch.json" value temporary description
  value=$(fm_route_capture_json_file "$config" 'active dispatch policy') || return 1
  temporary=$(fm_route_snapshot_temp "$value") || return 1
  if ! description=$("$FM_ROUTE_ROOT/bin/fm-dispatch-policy.sh" describe "$temporary" 2>/dev/null); then
    rm -f "$temporary"
    fm_route_diagnostic 'active dispatch policy is invalid'
    return 1
  fi
  rm -f "$temporary"
  jq -e '.schemaVersion == 2' <<<"$description" >/dev/null 2>&1 \
    || { fm_route_diagnostic 'active dispatch policy version 2 is required'; return 1; }
  printf '%s\n' "$value"
}

# Return 10 only for an authoritative, valid version 2 policy in off mode.
# Missing policy and version 1 retain the legacy low-level selector contract;
# an active malformed policy fails closed with a stable diagnostic.
fm_route_select_policy_guard() {
  local config_root="$FM_ROUTE_HOME/config" config="$FM_ROUTE_HOME/config/crew-dispatch.json" description schema mode path
  if { [ -n "${FM_CONFIG_OVERRIDE:-}" ] && [ "$FM_CONFIG_OVERRIDE" != "$config_root" ]; } ||
    fm_route_path_has_symlink_component "$FM_ROUTE_HOME" ||
    fm_route_path_has_symlink_component "$config_root" ||
    fm_route_path_has_symlink_component "$config"; then
    fm_route_diagnostic 'active dispatch policy path is unsafe'
    return 1
  fi
  for path in "$FM_ROUTE_HOME" "$config_root" "$config"; do
    case "/${path#/}/" in
      */../*|*/./*)
        fm_route_diagnostic 'active dispatch policy path is unsafe'
        return 1
        ;;
    esac
  done
  [ -e "$config" ] || return 0
  [ -f "$config" ] && [ -r "$config" ] || {
    fm_route_diagnostic 'active dispatch policy is unreadable'
    return 1
  }
  description=$("$FM_ROUTE_ROOT/bin/fm-dispatch-policy.sh" describe "$config" 2>/dev/null) || {
    fm_route_diagnostic 'active dispatch policy is invalid'
    return 1
  }
  schema=$(jq -r '.schemaVersion' <<<"$description" 2>/dev/null) || {
    fm_route_diagnostic 'active dispatch policy is invalid'
    return 1
  }
  mode=$(jq -r '.mode' <<<"$description" 2>/dev/null) || {
    fm_route_diagnostic 'active dispatch policy is invalid'
    return 1
  }
  [ "$schema" != 2 ] || [ "$mode" != off ] || return 10
}

fm_route_require_directory() {
  local directory=$1 parent
  if [ -L "$directory" ] || { [ -e "$directory" ] && [ ! -d "$directory" ]; }; then
    fm_route_diagnostic 'invalid routing state'
    return 1
  fi
  if [ ! -e "$directory" ]; then
    parent=$(dirname "$directory")
    [ -d "$parent" ] && [ ! -L "$parent" ] || { fm_route_diagnostic 'invalid routing state'; return 1; }
    mkdir "$directory" 2>/dev/null \
      || { [ -d "$directory" ] && [ ! -L "$directory" ]; } \
      || return 1
  fi
}

fm_route_require_state_root() {
  local parent
  parent=$(dirname "$FM_ROUTE_STATE")
  [ -d "$parent" ] && [ ! -L "$parent" ] || { fm_route_diagnostic 'invalid routing state'; return 1; }
  fm_route_require_directory "$FM_ROUTE_STATE"
}

fm_route_require_state_subdir() {
  fm_route_require_state_root || return 1
  fm_route_require_directory "$FM_ROUTE_STATE/$1"
}

fm_route_require_task_subdir() {
  local root=$1 task=$2
  fm_route_validate_identifier "$task" || { fm_route_diagnostic 'invalid routing state'; return 1; }
  fm_route_require_state_subdir "$root" || return 1
  fm_route_require_directory "$FM_ROUTE_STATE/$root/$task"
}

fm_route_read_reservations() {
  local file entry directory="$FM_ROUTE_STATE/reservations"
  fm_route_require_state_subdir reservations || return 1
  for entry in "$directory"/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ ! -L "$entry" ] || return 1
    [ ! -d "$entry" ] || fm_route_validate_identifier "${entry##*/}" || return 1
  done
  set --
  for file in "$directory"/*.json "$directory"/*/*.json; do
    [ -e "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    fm_route_validate_reservation_file "$file" || return 1
    set -- "$@" "$file"
  done
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  jq -se '
    if (group_by([.taskId,.generation]) | all(length == 1))
    then . else error("duplicate reservation") end
  ' "$@" 2>/dev/null
}

fm_route_read_outcomes() {
  local file="$FM_ROUTE_STATE/outcomes.jsonl"
  if [ ! -s "$file" ]; then
    printf '[]\n'
    return 0
  fi
  jq -s '
    def exact($keys): (keys_unsorted | sort) == ($keys | sort);
    def identifier: type == "string" and length <= 128 and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def work_type: type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def common:
      (.timestamp | type) == "number" and .timestamp >= 0
      and (.taskId | identifier) and (.profile | identifier) and (.provider | identifier)
      and (.lane | identifier) and (.account | identifier)
      and (.taskClass | IN("trivial","standard","decomposable","ambiguous","high_risk"))
      and (.workType | work_type) and (.risk | IN("low","medium","high"))
      and (.elapsedSeconds | type) == "number" and .elapsedSeconds >= 0;
    def valid:
      if .kind == "simulation" then
        exact(["kind","timestamp","taskId","taskClass","workType","risk","profile","provider","lane","account","elapsedSeconds","terminal"])
        and common and .terminal == "observed"
      elif .kind == "terminal" then
        exact(["kind","timestamp","taskId","generation","profile","provider","lane","account","taskClass","workType","risk","mode","elapsedSeconds","tests","review","redundant","terminal"])
        and common and (.generation | identifier) and (.mode | IN("canary","automatic"))
        and (.tests | IN("pass","fail","unknown")) and (.review | IN("pass","fail","unknown"))
        and (.redundant | IN("yes","no"))
        and (.terminal | IN("completed","failed_safe","escalated","cancelled","superseded"))
      else false end;
    if all(type == "object" and valid) then . else error("invalid") end
  ' "$file" 2>/dev/null
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
          | .historyAttempts = ([$outcomes[] | select(.kind? == "terminal" and .profile? == $candidate.profile and .workType? == $request.workType)] | length)
          | .historySuccesses = ([$outcomes[] | select(.kind? == "terminal" and .profile? == $candidate.profile and .workType? == $request.workType and .terminal? == "completed")] | length)
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
  fm_route_require_state_subdir reservations || return 1
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
  fm_route_require_state_root || return 1
  fm_lock_acquire_wait "$lock" || return 1
  if "$@"; then rc=0; else rc=$?; fi
  fm_lock_release "$lock"
  return "$rc"
}

fm_route_atomic_json_value() {
  local destination=$1 value=$2 directory temporary
  directory=$(dirname "$destination")
  [ -d "$directory" ] && [ ! -L "$directory" ] || { fm_route_diagnostic 'invalid routing state'; return 1; }
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
    *) [ "${#1}" -le 128 ] ;;
  esac
}

fm_route_validate_work_type() {
  case "$1" in
    ''|*[!a-z0-9._-]*|[!a-z0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 64 ]
}

fm_route_validate_claim() {
  case "$1" in
    *[!a-f0-9]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

fm_route_validate_reservation_file() {
  jq -e '
    def exact($keys): (keys_unsorted | sort) == ($keys | sort);
    def identifier: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
    def work_type: type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def hash: type == "string" and test("^[a-f0-9]{64}$");
    def harness: IN("claude","codex","pi","pi-signed");
    def model: type == "string" and . != "default" and test("^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$");
    def score:
      . == null or
      (type == "object"
       and exact(["terminal","tests","review","redundant","timestamp"])
       and (.terminal | IN("completed","failed_safe","escalated","cancelled","superseded"))
       and (.tests | IN("pass","fail","unknown"))
       and (.review | IN("pass","fail","unknown"))
       and (.redundant | IN("yes","no"))
       and (.timestamp | type) == "number" and (.timestamp | floor) == .timestamp and .timestamp >= 0);
    def base:
      (.taskId | identifier) and (.generation | identifier)
      and (.profile | identifier) and (.provider | identifier)
      and (.lane | identifier) and (.account | identifier)
      and (.taskClass | IN("trivial","standard","decomposable","ambiguous","high_risk"))
      and (.workType | work_type) and (.risk | IN("low","medium","high"))
      and (.mode | IN("canary","automatic")) and (.burst | type) == "boolean"
      and (.createdAt | type) == "number" and (.createdAt | floor) == .createdAt and .createdAt >= 0 and (.score | score);
    def base_keys: ["taskId","generation","profile","provider","lane","account","taskClass","workType","risk","mode","burst","createdAt","score"];
    def binding_keys: ["bindingVersion","launchHarness","launchModel","launchEffort","requestDigest","candidatesDigest","decisionDigest","policyDigest"];
    def binding:
      .bindingVersion == 1 and (.launchHarness | harness) and (.launchModel | model)
      and (.launchEffort == null or (.launchEffort | IN("low","medium","high","xhigh","max")))
      and (.launchHarness != "codex" or .launchEffort != "max")
      and (.requestDigest | hash) and (.candidatesDigest | hash) and (.decisionDigest | hash) and (.policyDigest | hash);
    def selected_base_keys: base_keys + (if has("bindingVersion") then binding_keys else [] end);
    def state_keys: selected_base_keys + ["admissionState"];
    type == "object" and base and ((has("bindingVersion") | not) or binding) and
    (if exact(selected_base_keys) then true
     elif .admissionState == "reserved" then exact(state_keys)
     elif .admissionState == "claimed" then
       (exact(state_keys + ["claimHash","claimedAt"])
        and (.claimHash | hash) and (.claimedAt | type) == "number" and (.claimedAt | floor) == .claimedAt and .claimedAt >= 0)
       or
       (exact(state_keys + ["claimHash","claimedAt","ownerPid","ownerStart","claimPriorState"])
        and (.claimHash | hash) and (.claimedAt | type) == "number" and (.claimedAt | floor) == .claimedAt and .claimedAt >= 0
        and (.ownerPid | type) == "number" and (.ownerPid | floor) == .ownerPid and .ownerPid > 0
        and (.ownerStart | hash) and (.claimPriorState | IN("reserved","active")))
     elif .admissionState == "active" then
       (exact(state_keys + ["claimHash"])
        or exact(state_keys + ["claimHash","claimedAt"]))
       and (.claimHash | hash)
       and ((has("claimedAt") | not) or ((.claimedAt | type) == "number" and (.claimedAt | floor) == .claimedAt and .claimedAt >= 0))
     else false end)
  ' "$1" >/dev/null 2>&1
}

fm_route_reservation_path() {
  fm_route_require_task_subdir reservations "$1" || return 1
  printf '%s/reservations/%s/%s.json\n' "$FM_ROUTE_STATE" "$1" "$2"
}

fm_route_find_reservation_path() {
  local task=$1 generation=$2 current matches path
  current=$(fm_route_read_reservations) || return 1
  matches=$(jq -r --arg task "$task" --arg generation "$generation" \
    '[.[] | select(.taskId == $task and .generation == $generation)] | length' <<<"$current")
  [ "$matches" -le 1 ] || return 1
  [ "$matches" -eq 1 ] || return 2
  path=$(fm_route_reservation_path "$task" "$generation") || return 1
  if [ -s "$path" ]; then
    printf '%s\n' "$path"
  elif [ -s "$FM_ROUTE_STATE/reservations/$task.json" ]; then
    printf '%s/reservations/%s.json\n' "$FM_ROUTE_STATE" "$task"
  else
    return 1
  fi
}

fm_route_optional_reservation_path() {
  local path rc
  if path=$(fm_route_find_reservation_path "$1" "$2"); then
    printf '%s\n' "$path"
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] || { fm_route_diagnostic 'invalid routing state'; return 1; }
}

fm_route_claim_hash() {
  local claim=$1 digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$claim" | sha256sum) || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$claim" | shasum -a 256) || return 1
  else
    fm_route_diagnostic 'claim hashing is unavailable'
    return 1
  fi
  digest=${digest%% *}
  fm_route_validate_claim "$digest" || return 1
  printf '%s\n' "$digest"
}

fm_route_hash_file() {
  local digest
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum -- "$1") || return 1
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 -- "$1") || return 1
  else
    fm_route_diagnostic 'file hashing is unavailable'
    return 1
  fi
  digest=${digest%% *}
  fm_route_validate_claim "$digest" || return 1
  printf '%s\n' "$digest"
}

fm_route_process_start() {
  local pid=$1 identity boot start
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 0 ] || return 1
  if [ -r "/proc/$pid/stat" ]; then
    start=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | awk '{print $20}') || return 1
    [ -n "$start" ] || return 1
    boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    identity="linux:$boot:$start"
  else
    start=$(LC_ALL=C ps -o lstart= -p "$pid" 2>/dev/null) || return 1
    [ -n "$start" ] || return 1
    identity="ps:$start"
  fi
  fm_route_claim_hash "$identity"
}

fm_route_claim_file_path() {
  fm_route_require_task_subdir claims "$1" || return 1
  printf '%s/claims/%s/%s.cap\n' "$FM_ROUTE_STATE" "$1" "$2"
}

fm_route_validate_claim_file_path() {
  local expected
  expected=$(fm_route_claim_file_path "$1" "$2") || return 1
  [ "$3" = "$expected" ] || {
    fm_route_diagnostic 'invalid claim file'
    return 1
  }
}

fm_route_claim_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

fm_route_claim_file_owner() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1" 2>/dev/null
}

fm_route_read_claim_file() {
  local file=$1 claim
  [ -f "$file" ] && [ ! -L "$file" ] \
    && [ "$(fm_route_claim_file_mode "$file")" = 600 ] \
    && [ "$(fm_route_claim_file_owner "$file")" = "$(id -u)" ] || {
      fm_route_diagnostic 'invalid claim file'
      return 1
    }
  IFS= read -r claim <"$file" || { fm_route_diagnostic 'invalid claim file'; return 1; }
  fm_route_validate_claim "$claim" || { fm_route_diagnostic 'invalid claim file'; return 1; }
  [ "$(wc -c <"$file" | tr -d ' ')" -eq 65 ] || { fm_route_diagnostic 'invalid claim file'; return 1; }
  printf '%s\n' "$claim"
}

fm_route_remove_claim_file() {
  local task=$1 generation=$2 file=$3
  fm_route_validate_claim_file_path "$task" "$generation" "$file" || return 1
  if [ -e "$file" ]; then
    fm_route_read_claim_file "$file" >/dev/null || return 1
    rm -f -- "$file" || return 1
  fi
}

fm_route_create_claim_file() {
  local task=$1 generation=$2 file=$3 directory temporary claim
  fm_route_validate_claim_file_path "$task" "$generation" "$file" || return 1
  directory=$(dirname "$file")
  if [ -L "$FM_ROUTE_STATE/claims" ] || [ -L "$directory" ]; then
    fm_route_diagnostic 'invalid claim file'
    return 1
  fi
  mkdir -p "$FM_ROUTE_STATE/claims" || return 1
  if [ -e "$directory" ]; then
    [ -d "$directory" ] && [ ! -L "$directory" ] || { fm_route_diagnostic 'invalid claim file'; return 1; }
  else
    mkdir "$directory" || return 1
  fi
  if [ -e "$file" ]; then
    fm_route_diagnostic 'unexpected admission capability'
    return 1
  fi
  temporary=$(umask 077; mktemp "$directory/.claim.XXXXXX") || return 1
  claim=$(LC_ALL=C od -An -N32 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || {
    rm -f -- "$temporary"
    return 1
  }
  fm_route_validate_claim "$claim" || { rm -f -- "$temporary"; return 1; }
  if (umask 077; printf '%s\n' "$claim" >"$temporary") && chmod 600 "$temporary" && mv -f "$temporary" "$file"; then
    printf '%s\n' "$claim"
  else
    rm -f -- "$temporary"
    return 1
  fi
}

fm_route_metadata_snapshot() {
  if [ -e "$1" ]; then
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    jq -cn --arg digest "$(fm_route_hash_file "$1")" '{exists:true,digest:$digest}'
  else
    printf '{"exists":false,"digest":null}\n'
  fi
}

fm_route_validate_metadata_path() {
  [ "$2" = "$FM_ROUTE_TASK_STATE/$1.meta" ] || {
    fm_route_diagnostic 'invalid metadata file'
    return 1
  }
}

fm_route_admission_path() {
  fm_route_require_state_subdir admissions || return 1
  printf '%s/admissions/%s.json\n' "$FM_ROUTE_STATE" "$1"
}

fm_route_remove_admission_file() {
  local file
  file=$(fm_route_admission_path "$1") || return 1
  rm -f -- "$file"
}

fm_route_route_object() {
  jq -c '{generation,profile,provider,lane,account,taskClass,workType,risk,mode}
    + (if has("bindingVersion") then {bindingVersion,launchHarness,launchModel,launchEffort,requestDigest,candidatesDigest,decisionDigest,policyDigest} else {} end)' <<<"$1"
}

fm_route_validate_admission_file() {
  jq -e --arg taskState "$FM_ROUTE_TASK_STATE" '
    def exact($keys): (keys_unsorted | sort) == ($keys | sort);
    def identifier: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
    def hash: type == "string" and test("^[a-f0-9]{64}$");
    def route:
      type == "object"
      and (exact(["generation","profile","provider","lane","account","taskClass","workType","risk","mode"])
        or exact(["generation","profile","provider","lane","account","taskClass","workType","risk","mode","bindingVersion","launchHarness","launchModel","launchEffort","requestDigest","candidatesDigest","decisionDigest","policyDigest"]))
      and (.generation | identifier) and (.profile | identifier) and (.provider | identifier)
      and (.lane | identifier) and (.account | identifier)
      and (.taskClass | IN("trivial","standard","decomposable","ambiguous","high_risk"))
      and (.workType | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$")) and (.risk | IN("low","medium","high"))
      and (.mode | IN("canary","automatic"))
      and (if has("bindingVersion") then
        .bindingVersion == 1 and (.launchHarness | IN("claude","codex","pi","pi-signed"))
        and (.launchModel | type == "string" and . != "default" and test("^[A-Za-z0-9][A-Za-z0-9._:/-]{0,255}$"))
        and (.launchEffort == null or (.launchEffort | IN("low","medium","high","xhigh","max")))
        and (.launchHarness != "codex" or .launchEffort != "max")
        and (.requestDigest | hash) and (.candidatesDigest | hash) and (.decisionDigest | hash) and (.policyDigest | hash)
      else true end);
    def snapshot:
      type == "object" and exact(["exists","digest"])
      and (.exists | type) == "boolean"
      and (if .exists then (.digest | hash) else .digest == null end);
    type == "object"
    and exact(["version","taskId","transition","phase","ownerPid","ownerStart","createdAt","metadataFile","metadataBefore","expectedMetadataDigest","target","prior","targetClaimHash","priorClaimHash"])
    and .version == 1 and (.taskId | identifier)
    and (.transition | IN("fresh","inherit","replacement","off"))
    and (.phase | IN("beginning","claimed","prepared","committing","rollingBack"))
    and (.ownerPid | type) == "number" and (.ownerPid | floor) == .ownerPid and .ownerPid > 0
    and (.ownerStart | hash)
    and (.createdAt | type) == "number" and (.createdAt | floor) == .createdAt and .createdAt >= 0
    and (.metadataFile | type) == "string" and (.metadataFile | length) > 0 and (.metadataFile | length) <= 4096
    and .metadataFile == ($taskState + "/" + .taskId + ".meta")
    and (.metadataBefore | snapshot)
    and (.expectedMetadataDigest == null or (.expectedMetadataDigest | hash))
    and (if .transition == "fresh" then (.target | route) and .prior == null
         elif .transition == "inherit" then (.target | route) and (.prior | route) and .target == .prior
         elif .transition == "replacement" then (.target | route) and (.prior | route) and .target.generation != .prior.generation
         else .target == null and (.prior | route) end)
    and (.targetClaimHash == null or (.targetClaimHash | hash))
    and (.priorClaimHash == null or (.priorClaimHash | hash))
    and (if .transition == "fresh" then .priorClaimHash == null
         elif .transition == "inherit" then .targetClaimHash == .priorClaimHash
         elif .transition == "replacement" then (.priorClaimHash | hash)
         else .targetClaimHash == null and (.priorClaimHash | hash) end)
    and (if .phase == "beginning" then true
         elif .transition == "off" then (.priorClaimHash | hash)
         else (.targetClaimHash | hash) end)
    and (if (.phase == "prepared" or .phase == "committing") then (.expectedMetadataDigest | hash)
         elif .phase == "rollingBack" then (.expectedMetadataDigest == null or (.expectedMetadataDigest | hash))
         else .expectedMetadataDigest == null end)
  ' "$1" >/dev/null 2>&1
}

fm_route_load_admission() {
  local file
  file=$(fm_route_admission_path "$1") || return 1
  if [ ! -f "$file" ] || [ -L "$file" ] || ! fm_route_validate_admission_file "$file"; then
    fm_route_diagnostic 'invalid admission state'
    return 1
  fi
  jq -c . "$file"
}

fm_route_owner_matches() {
  local pid=$1 expected=$2 actual
  actual=$(fm_route_process_start "$pid" 2>/dev/null) || return 1
  [ "$actual" = "$expected" ]
}

fm_route_authorize_reservation() {
  local task=$1 generation=$2 claim_file=$3 reservation=$4 claim hash
  fm_route_validate_claim_file_path "$task" "$generation" "$claim_file" || return 1
  claim=$(fm_route_read_claim_file "$claim_file") || return 1
  hash=$(fm_route_claim_hash "$claim") || return 1
  [ "$(jq -r '.claimHash // empty' <<<"$reservation")" = "$hash" ] || {
    fm_route_diagnostic 'reservation capability mismatch'
    return 1
  }
}

fm_route_admission_current_owner() {
  local journal=$1 owner_pid=$2 owner_start=$3
  if [ "$(jq -r .ownerPid <<<"$journal")" != "$owner_pid" ] \
    || [ "$(jq -r .ownerStart <<<"$journal")" != "$owner_start" ] \
    || ! fm_route_owner_matches "$owner_pid" "$owner_start"; then
      fm_route_diagnostic 'admission owner mismatch'
      return 1
  fi
}

fm_route_snapshot_matches() {
  local metadata=$1 snapshot=$2 current
  current=$(fm_route_metadata_snapshot "$metadata") || return 1
  jq -e --argjson current "$current" '. == $current' <<<"$snapshot" >/dev/null
}

fm_route_claim_reservation_value() {
  local current=$1 hash=$2 now=$3 owner_pid=$4 owner_start=$5 prior=$6
  jq -c --arg hash "$hash" --argjson now "$now" --argjson ownerPid "$owner_pid" --arg ownerStart "$owner_start" --arg prior "$prior" '
    .admissionState="claimed"
    | .claimHash=$hash
    | .claimedAt=$now
    | .ownerPid=$ownerPid
    | .ownerStart=$ownerStart
    | .claimPriorState=$prior
  ' <<<"$current"
}

fm_route_active_reservation_value() {
  jq -c '.admissionState="active" | del(.claimedAt,.ownerPid,.ownerStart,.claimPriorState)' <<<"$1"
}

fm_route_public_reservation() {
  jq -c 'del(.claimHash)' <<<"$1"
}

fm_route_validate_route_tuple() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10}
  fm_route_validate_identifier "$task" || { fm_route_diagnostic 'invalid task identifier'; return 1; }
  fm_route_validate_identifier "$generation" || { fm_route_diagnostic 'invalid generation identifier'; return 1; }
  fm_route_validate_identifier "$profile" || { fm_route_diagnostic 'invalid profile identifier'; return 1; }
  fm_route_validate_identifier "$provider" || { fm_route_diagnostic 'invalid provider identifier'; return 1; }
  fm_route_validate_identifier "$lane" || { fm_route_diagnostic 'invalid lane identifier'; return 1; }
  fm_route_validate_identifier "$account" || { fm_route_diagnostic 'invalid account identifier'; return 1; }
  case "$task_class" in trivial|standard|decomposable|ambiguous|high_risk) ;; *) fm_route_diagnostic 'invalid task class'; return 1 ;; esac
  fm_route_validate_work_type "$work_type" || { fm_route_diagnostic 'invalid work type'; return 1; }
  case "$risk" in low|medium|high) ;; *) fm_route_diagnostic 'invalid risk'; return 1 ;; esac
  case "$mode" in off|simulate|canary|automatic) ;; *) fm_route_diagnostic 'invalid routing mode'; return 1 ;; esac
}

fm_route_validate_circuits_file() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  jq --stream -n -e '
    [inputs | select(length == 2) | .[0] | @json]
    | group_by(.) | all(length == 1)
  ' "$file" >/dev/null 2>&1 || return 1
  jq -e '
    def exact($keys): (keys_unsorted | sort) == ($keys | sort);
    def identifier: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
    def natural: type == "number" and floor == . and . >= 0;
    def lane_record:
      type == "object" and exact(["provider","openUntil"])
      and (.provider | identifier)
      and (.openUntil == null or (.openUntil | natural));
    def event_record($key):
      type == "object"
      and exact(["taskId","generation","provider","lane","kind","timestamp","action","until"])
      and (.taskId | identifier) and (.generation | identifier)
      and $key == (.taskId + "|" + .generation)
      and (.provider | identifier) and (.lane | identifier)
      and (.kind | IN("transient","quota","auth","model","unsafe"))
      and (.timestamp | natural)
      and (.action | IN("retry","fallback","circuit-open","escalate"))
      and (if .kind == "unsafe" then .action == "escalate"
           elif .kind == "transient" then (.action | IN("retry","fallback","circuit-open"))
           else (.action | IN("fallback","circuit-open")) end)
      and (if .action == "circuit-open" then (.until | natural) and .until > .timestamp
           elif .action == "escalate" then (.until == null or ((.until | natural) and .until > .timestamp))
           else .until == null end);
    type == "object" and exact(["lanes","events"])
    and (.lanes | type) == "object" and (.events | type) == "object"
    and (.lanes | to_entries | all((.key | identifier) and (.value | lane_record)))
    and (.events | to_entries | all(. as $entry | $entry.value | event_record($entry.key)))
    and (.events | to_entries | group_by(.value.lane) | all((map(.value.provider) | unique | length) == 1))
    and (. as $state | .lanes | to_entries | all(
      . as $lane
      | ([$state.events[] | select(.lane == $lane.key)]) as $events
      | ($events | length) > 0
      and ($events | all(.provider == $lane.value.provider))
      and (if $lane.value.openUntil == null then true
           else ($events | any(.until == $lane.value.openUntil and (.action == "circuit-open" or .action == "escalate"))) end)
    ))
  ' "$file" >/dev/null 2>&1
}

fm_route_read_circuits() {
  local file="$FM_ROUTE_STATE/circuits.json"
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '{"lanes":{},"events":{}}\n'
    return 0
  fi
  [ -s "$file" ] || return 1
  fm_route_validate_circuits_file "$file" || return 1
  jq -ce . "$file" 2>/dev/null
}

fm_route_write_circuits() {
  local destination="$FM_ROUTE_STATE/circuits.json" directory temporary
  directory=$(dirname "$destination")
  [ -d "$directory" ] && [ ! -L "$directory" ] || { fm_route_diagnostic 'invalid routing state'; return 1; }
  temporary=$(mktemp "$directory/.routing-circuits.XXXXXX") || return 1
  if printf '%s\n' "$1" >"$temporary" && fm_route_validate_circuits_file "$temporary"; then
    mv -f "$temporary" "$destination"
  else
    rm -f "$temporary"
    fm_route_diagnostic 'invalid routing state'
    return 1
  fi
}

fm_route_reserve() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10} burst=${11} now=${12}
  local request=${13} candidates=${14} decision=${15} policy policy_mode policy_digest
  policy=$(fm_route_capture_v2_policy) || return 1
  policy_mode=$(jq -er '.routing.mode // "automatic"' <<<"$policy") || return 1
  case "$policy_mode" in
    canary|automatic) ;;
    off|simulate) fm_route_diagnostic "mode-does-not-reserve:$policy_mode"; return 1 ;;
    *) fm_route_diagnostic 'active dispatch policy is invalid'; return 1 ;;
  esac
  [ "$mode" = "$policy_mode" ] || { fm_route_diagnostic 'routing mode does not match active policy'; return 1; }
  policy_digest=$(fm_route_claim_hash "$(jq -Sc . <<<"$policy")") || return 1
  fm_routing_with_lock fm_route_reserve_locked "$task" "$generation" "$profile" "$provider" "$lane" "$account" "$task_class" "$work_type" "$risk" "$mode" "$burst" "$now" "$request" "$candidates" "$decision" "$policy_digest"
}

fm_route_reserve_binding_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10} request_file=${11} candidates_file=${12} decision_file=${13} expected_policy_digest=${14}
  local policy request candidates decision policy_digest request_digest candidates_digest decision_digest
  local request_tmp candidates_tmp decision_tmp policy_profile reservations outcomes max_workers computed normalized_decision launch_harness launch_model launch_effort policy_account
  policy=$(fm_route_capture_v2_policy) || return 1
  policy=$(jq -Sc . <<<"$policy") || return 1
  policy_digest=$(fm_route_claim_hash "$policy") || return 1
  [ "$policy_digest" = "$expected_policy_digest" ] || { fm_route_diagnostic 'active dispatch policy changed; re-evaluate'; return 1; }
  [ "$(jq -r '.routing.mode // "automatic"' <<<"$policy")" = "$mode" ] \
    || { fm_route_diagnostic 'routing mode does not match active policy'; return 1; }

  request=$(fm_route_capture_json_file "$request_file" request) || return 1
  candidates=$(fm_route_capture_json_file "$candidates_file" candidates) || return 1
  decision=$(fm_route_capture_json_file "$decision_file" decision) || return 1
  request_tmp=$(fm_route_snapshot_temp "$request") || return 1
  candidates_tmp=$(fm_route_snapshot_temp "$candidates") || { rm -f "$request_tmp"; return 1; }
  decision_tmp=$(fm_route_snapshot_temp "$decision") || { rm -f "$request_tmp" "$candidates_tmp"; return 1; }
  if ! fm_route_validate_request "$request_tmp" || ! fm_route_validate_candidates "$candidates_tmp"; then
    rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"
    return 1
  fi
  if ! jq -e --arg task "$task" --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" \
      '.taskId == $task and .taskClass == $class and .workType == $workType and .risk == $risk' "$request_tmp" >/dev/null; then
    rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"
    fm_route_diagnostic 'request-reservation-mismatch'
    return 1
  fi
  max_workers=$(jq -r '[.taskClass,.independent,.requestedWorkers] | @tsv' "$request_tmp") || { rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"; return 1; }
  # shellcheck disable=SC2086
  max_workers=$(fm_route_worker_budget $max_workers) || { rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"; return 1; }
  reservations=$(fm_route_read_reservations) || { rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"; fm_route_diagnostic 'invalid routing state'; return 1; }
  reservations=$(jq -c --arg task "$task" --arg generation "$generation" \
    '[.[] | select(.taskId != $task or .generation != $generation)]' <<<"$reservations") || { rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"; return 1; }
  outcomes=$(fm_route_read_outcomes) || { rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"; fm_route_diagnostic 'invalid routing state'; return 1; }
  computed=$(fm_route_select_ranked "$request_tmp" "$candidates_tmp" "$reservations" "$outcomes" "$max_workers") \
    || { rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"; return 1; }
  normalized_decision=$(jq -Sc . "$decision_tmp") || { rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"; return 1; }
  rm -f "$request_tmp" "$candidates_tmp" "$decision_tmp"
  [ "$(jq -Sc . <<<"$computed")" = "$normalized_decision" ] \
    || { fm_route_diagnostic 'selection-decision-mismatch'; return 1; }
  jq -e --arg profile "$profile" '.action == "selected" and .selected.profile == $profile' <<<"$computed" >/dev/null \
    || { fm_route_diagnostic 'selected profile does not match reservation'; return 1; }

  policy_profile=$(jq -ce --arg profile "$profile" '.profiles[$profile] | select(type == "object")' <<<"$policy") \
    || { fm_route_diagnostic 'selected profile is absent from active policy'; return 1; }
  launch_harness=$(jq -r '.harness' <<<"$policy_profile")
  launch_model=$(jq -er '.model | select(type == "string" and length > 0 and . != "default")' <<<"$policy_profile" 2>/dev/null) \
    || { fm_route_diagnostic 'selected policy profile requires a concrete model'; return 1; }
  launch_effort=$(jq -c '.effort // null' <<<"$policy_profile") || return 1
  policy_account=$(jq -r '.account // "none"' <<<"$policy_profile") || return 1
  jq -e --arg workType "$work_type" '.workTypes | index($workType) != null' <<<"$policy_profile" >/dev/null \
    || { fm_route_diagnostic 'work type is not allowed by selected policy profile'; return 1; }
  jq -e --arg profile "$profile" --arg harness "$launch_harness" --arg model "$launch_model" \
      --arg provider "$provider" --arg lane "$lane" --arg account "$account" \
      --arg reasoning "$(jq -r '.reasoningClass' <<<"$policy_profile")" '
      .selected.profile == $profile and .selected.harness == $harness and .selected.model == $model
      and .selected.provider == $provider and .selected.lane == $lane and .selected.account == $account
      and .selected.reasoningClass == $reasoning' <<<"$computed" >/dev/null \
    || { fm_route_diagnostic 'selected route does not match active policy'; return 1; }
  [ "$(jq -r '.provider' <<<"$policy_profile")" = "$provider" ] \
    && [ "$(jq -r '.lane' <<<"$policy_profile")" = "$lane" ] \
    && [ "$policy_account" = "$account" ] \
    || { fm_route_diagnostic 'reservation route does not match active policy'; return 1; }
  case "$launch_harness" in pi|pi-signed) [ "$account" = none ] || { fm_route_diagnostic 'Pi policy profiles require account none'; return 1; } ;; esac

  request=$(jq -Sc . <<<"$request") || return 1
  candidates=$(jq -Sc . <<<"$candidates") || return 1
  request_digest=$(fm_route_claim_hash "$request") || return 1
  candidates_digest=$(fm_route_claim_hash "$candidates") || return 1
  decision_digest=$(fm_route_claim_hash "$normalized_decision") || return 1
  jq -cn --arg harness "$launch_harness" --arg model "$launch_model" --argjson effort "$launch_effort" \
    --arg requestDigest "$request_digest" --arg candidatesDigest "$candidates_digest" \
    --arg decisionDigest "$decision_digest" --arg policyDigest "$policy_digest" \
    '{bindingVersion:1,launchHarness:$harness,launchModel:$model,launchEffort:$effort,requestDigest:$requestDigest,candidatesDigest:$candidatesDigest,decisionDigest:$decisionDigest,policyDigest:$policyDigest}'
}

fm_route_reserve_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10} burst=${11} now=${12}
  local request=${13} candidates=${14} decision=${15} policy_digest=${16}
  local reservation reservations task_reservations circuits existing total lane_total account_total cap updated binding
  binding=$(fm_route_reserve_binding_locked "$task" "$generation" "$profile" "$provider" "$lane" "$account" "$task_class" "$work_type" "$risk" "$mode" "$request" "$candidates" "$decision" "$policy_digest") || return 1
  mkdir -p "$FM_ROUTE_STATE/reservations"
  reservations=$(fm_route_read_reservations) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  existing=$(jq -c --arg task "$task" --arg generation "$generation" \
    '.[] | select(.taskId == $task and .generation == $generation)' <<<"$reservations")
  if [ -n "$existing" ]; then
    if jq -e --arg generation "$generation" --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" --arg account "$account" --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" --arg mode "$mode" --argjson burst "$burst" --argjson binding "$binding" '
      .generation == $generation and .profile == $profile and .provider == $provider and .lane == $lane and .account == $account and .taskClass == $class and .workType == $workType and .risk == $risk and .mode == $mode and .burst == $burst
      and .bindingVersion == $binding.bindingVersion and .launchHarness == $binding.launchHarness and .launchModel == $binding.launchModel and .launchEffort == $binding.launchEffort
      and .requestDigest == $binding.requestDigest and .candidatesDigest == $binding.candidatesDigest and .decisionDigest == $binding.decisionDigest and .policyDigest == $binding.policyDigest
    ' <<<"$existing" >/dev/null; then
      fm_route_public_reservation "$existing"
      return 0
    fi
    fm_route_diagnostic 'reservation-conflict'
    return 1
  fi
  task_reservations=$(jq -c --arg task "$task" '[.[] | select(.taskId == $task)]' <<<"$reservations")
  if [ "$(jq 'length' <<<"$task_reservations")" -gt 0 ]; then
    [ "$(jq 'length' <<<"$task_reservations")" -eq 1 ] \
      && [ "$(jq -r '.[0].admissionState // "reserved"' <<<"$task_reservations")" = active ] || {
        fm_route_diagnostic 'reservation-conflict'
        return 1
      }
    reservations=$(jq -c --arg task "$task" '[.[] | select(.taskId != $task)]' <<<"$reservations")
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
  updated=$(jq -cn --arg task "$task" --arg generation "$generation" --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" --arg account "$account" --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" --arg mode "$mode" --argjson burst "$burst" --argjson now "$now" --argjson binding "$binding" \
    '{taskId:$task,generation:$generation,profile:$profile,provider:$provider,lane:$lane,account:$account,taskClass:$class,workType:$workType,risk:$risk,mode:$mode,burst:$burst,createdAt:$now,score:null,admissionState:"reserved"} + $binding')
  reservation=$(fm_route_reservation_path "$task" "$generation") || return 1
  fm_route_atomic_json_value "$reservation" "$updated" || return 1
  fm_route_public_reservation "$updated"
}

# A bound route may start or restart only while the exact policy that selected it
# remains active. This runs under the routing lock and performs no routing-state
# mutation; callers invoke it before claim paths, journals, or metadata are touched.
fm_route_validate_current_policy_binding_locked() {
  local reservation=$1 policy canonical digest profile mode work_type account effort
  [ "$(jq -r '.bindingVersion // 0' <<<"$reservation")" = 1 ] \
    || { fm_route_diagnostic 'reservation-binding-required'; return 1; }
  policy=$(fm_route_capture_v2_policy) || return 1
  canonical=$(jq -Sc . <<<"$policy") || { fm_route_diagnostic 'active dispatch policy is invalid'; return 1; }
  digest=$(fm_route_claim_hash "$canonical") || return 1
  [ "$digest" = "$(jq -r .policyDigest <<<"$reservation")" ] \
    || { fm_route_diagnostic 'active dispatch policy changed; re-evaluate'; return 1; }
  mode=$(jq -r '.mode' <<<"$reservation") || return 1
  case "$(jq -r '.routing.mode // "automatic"' <<<"$canonical")" in
    canary|automatic) ;;
    off|simulate) fm_route_diagnostic 'active dispatch policy does not admit launches'; return 1 ;;
    *) fm_route_diagnostic 'active dispatch policy is invalid'; return 1 ;;
  esac
  [ "$(jq -r '.routing.mode // "automatic"' <<<"$canonical")" = "$mode" ] \
    || { fm_route_diagnostic 'routing mode does not match active policy'; return 1; }
  profile=$(jq -r '.profile' <<<"$reservation") || return 1
  work_type=$(jq -r '.workType' <<<"$reservation") || return 1
  account=$(jq -r '.account' <<<"$reservation") || return 1
  effort=$(jq -c '.launchEffort' <<<"$reservation") || return 1
  jq -e --arg profile "$profile" --arg provider "$(jq -r .provider <<<"$reservation")" \
      --arg lane "$(jq -r .lane <<<"$reservation")" --arg account "$account" \
      --arg harness "$(jq -r .launchHarness <<<"$reservation")" \
      --arg model "$(jq -r .launchModel <<<"$reservation")" --arg workType "$work_type" \
      --argjson effort "$effort" '
      .profiles[$profile] as $p
      | ($p | type) == "object"
        and $p.provider == $provider and $p.lane == $lane
        and ($p.account // "none") == $account
        and $p.harness == $harness and $p.model == $model
        and ($p.effort // null) == $effort
        and ($p.workTypes | index($workType) != null)
    ' <<<"$canonical" >/dev/null 2>&1 \
    || { fm_route_diagnostic 'reservation route no longer matches active policy'; return 1; }
}

fm_route_verify_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10} reservation
  reservation=$(fm_route_find_reservation_path "$task" "$generation") || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  jq -e --arg generation "$generation" --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" --arg account "$account" --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" --arg mode "$mode" '
    .generation == $generation and .profile == $profile and .provider == $provider and .lane == $lane and .account == $account and .taskClass == $class and .workType == $workType and .risk == $risk and .mode == $mode
  ' "$reservation" >/dev/null 2>&1 || { fm_route_diagnostic 'reservation-mismatch'; return 1; }
  jq -c 'del(.claimHash)' "$reservation"
}

fm_route_reservation_work_type_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 risk=$8 mode=$9 reservation rc source outcomes
  if reservation=$(fm_route_find_reservation_path "$task" "$generation"); then
    source=$(jq -c . "$reservation") \
      || { fm_route_diagnostic 'invalid routing state'; return 1; }
  else
    rc=$?
    [ "$rc" -eq 2 ] || { fm_route_diagnostic 'invalid routing state'; return 1; }
    outcomes=$(fm_route_read_outcomes) \
      || { fm_route_diagnostic 'invalid routing state'; return 1; }
    source=$(jq -c --arg task "$task" --arg generation "$generation" '
      [.[] | select(.kind == "terminal" and .taskId == $task and .generation == $generation)]
      | if length == 1 then .[0] else empty end
    ' <<<"$outcomes")
    [ -n "$source" ] || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  fi
  jq -er --arg generation "$generation" --arg profile "$profile" \
    --arg provider "$provider" --arg lane "$lane" --arg account "$account" \
    --arg class "$task_class" --arg risk "$risk" --arg mode "$mode" '
      select(.generation == $generation and .profile == $profile and .provider == $provider
        and .lane == $lane and .account == $account and .taskClass == $class
        and .risk == $risk and .mode == $mode)
      | .workType
    ' <<<"$source" 2>/dev/null \
    || { fm_route_diagnostic 'reservation-mismatch'; return 1; }
}

fm_route_release_locked() {
  local task=$1 generation=$2 claim_file=${3:-} reservation reservations current state admission
  if ! reservation=$(fm_route_find_reservation_path "$task" "$generation"); then
    reservations=$(fm_route_read_reservations) || { fm_route_diagnostic 'invalid routing state'; return 1; }
    if jq -e --arg task "$task" '.[] | select(.taskId == $task)' <<<"$reservations" >/dev/null; then
      fm_route_diagnostic 'reservation-generation-mismatch'
      return 1
    fi
    if [ -n "$claim_file" ]; then
      admission=$(fm_route_admission_path "$task") || return 1
      [ ! -e "$admission" ] || { fm_route_diagnostic 'admission recovery required'; return 1; }
      fm_route_validate_claim_file_path "$task" "$generation" "$claim_file" || return 1
      if [ -e "$claim_file" ]; then
        fm_route_read_claim_file "$claim_file" >/dev/null || return 1
        fm_route_remove_claim_file "$task" "$generation" "$claim_file" || return 1
      fi
    fi
    printf '{"released":false,"idempotent":true}\n'
    return 0
  fi
  current=$(jq -c . "$reservation" 2>/dev/null) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  state=$(jq -r '.admissionState // "reserved"' <<<"$current")
  case "$state" in
    reserved)
      [ -z "$claim_file" ] || { fm_route_diagnostic 'reservation is not active'; return 1; }
      ;;
    claimed)
      fm_route_diagnostic 'reservation-claim-required'
      return 1
      ;;
    active)
      [ -n "$claim_file" ] || { fm_route_diagnostic 'reservation capability required'; return 1; }
      admission=$(fm_route_admission_path "$task") || return 1
      [ ! -e "$admission" ] || { fm_route_diagnostic 'admission recovery required'; return 1; }
      fm_route_authorize_reservation "$task" "$generation" "$claim_file" "$current" || return 1
      ;;
    *) fm_route_diagnostic 'invalid routing state'; return 1 ;;
  esac
  fm_route_remove_reservation_file "$reservation" || return 1
  [ "$state" != active ] || fm_route_remove_claim_file "$task" "$generation" "$claim_file" || return 1
  printf '{"released":true,"idempotent":false}\n'
}

fm_route_begin_admission_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10} transition=${11} metadata=${12} claim_file=${13} owner_pid=${14} owner_start=${15}
  local prior_generation=${16:-} prior_claim_file=${17:-}
  local launch_harness=${18:-} launch_model=${19:-} launch_effort=${20:-}
  local reservation prior_reservation journal current prior_current state prior_state claim hash now before target prior beginning claimed expected_effort
  fm_route_validate_metadata_path "$task" "$metadata" || return 1
  reservation=$(fm_route_find_reservation_path "$task" "$generation") || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  current=$(jq -c . "$reservation") || { fm_route_diagnostic 'invalid routing state'; return 1; }
  jq -e --arg generation "$generation" --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" --arg account "$account" --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" --arg mode "$mode" '
    .generation == $generation and .profile == $profile and .provider == $provider
    and .lane == $lane and .account == $account and .taskClass == $class
    and .workType == $workType and .risk == $risk and .mode == $mode
  ' <<<"$current" >/dev/null || { fm_route_diagnostic 'reservation-mismatch'; return 1; }
  state=$(jq -r '.admissionState // "reserved"' <<<"$current")
  target=$(fm_route_route_object "$current") || return 1
  expected_effort=$(jq -r 'if .launchEffort == null then "none" else .launchEffort end' <<<"$current") || return 1
  prior=null
  case "$transition" in
    fresh)
      [ -z "$prior_generation$prior_claim_file" ] || { fm_route_diagnostic 'unexpected prior reservation'; return 1; }
      [ "$state" = reserved ] || { fm_route_diagnostic 'reservation-not-reserved'; return 1; }
      [ "$(jq -r '.bindingVersion // 0' <<<"$current")" = 1 ] \
        || { fm_route_diagnostic 'reservation-binding-required'; return 1; }
      [ "$launch_harness" = "$(jq -r .launchHarness <<<"$current")" ] \
        && [ "$launch_model" = "$(jq -r .launchModel <<<"$current")" ] \
        && [ "$launch_effort" = "$expected_effort" ] \
        || { fm_route_diagnostic 'launch-binding-mismatch'; return 1; }
      fm_route_validate_current_policy_binding_locked "$current" || return 1
      fm_route_validate_claim_file_path "$task" "$generation" "$claim_file" || return 1
      [ ! -e "$claim_file" ] || { fm_route_diagnostic 'unexpected admission capability'; return 1; }
      ;;
    inherit)
      [ -z "$prior_generation$prior_claim_file" ] || { fm_route_diagnostic 'unexpected prior reservation'; return 1; }
      [ "$state" = active ] || { fm_route_diagnostic 'reservation-not-active'; return 1; }
      [ "$(jq -r '.bindingVersion // 0' <<<"$current")" = 1 ] \
        || { fm_route_diagnostic 'legacy active reservation cannot be relaunched without an authoritative binding'; return 1; }
      [ "$launch_harness" = "$(jq -r .launchHarness <<<"$current")" ] \
        && [ "$launch_model" = "$(jq -r .launchModel <<<"$current")" ] \
        && [ "$launch_effort" = "$expected_effort" ] \
        || { fm_route_diagnostic 'launch-binding-mismatch'; return 1; }
      fm_route_validate_current_policy_binding_locked "$current" || return 1
      fm_route_authorize_reservation "$task" "$generation" "$claim_file" "$current" || return 1
      prior=$target
      ;;
    replacement)
      fm_route_validate_identifier "$prior_generation" || { fm_route_diagnostic 'invalid prior generation'; return 1; }
      [ "$prior_generation" != "$generation" ] || { fm_route_diagnostic 'replacement generation must be distinct'; return 1; }
      [ "$state" = reserved ] || { fm_route_diagnostic 'reservation-not-reserved'; return 1; }
      prior_reservation=$(fm_route_find_reservation_path "$task" "$prior_generation") || { fm_route_diagnostic 'prior reservation not found'; return 1; }
      prior_current=$(jq -c . "$prior_reservation") || { fm_route_diagnostic 'invalid routing state'; return 1; }
      prior_state=$(jq -r '.admissionState // "reserved"' <<<"$prior_current")
      [ "$prior_state" = active ] || { fm_route_diagnostic 'prior reservation not active'; return 1; }
      [ "$(jq -r '.bindingVersion // 0' <<<"$current")" = 1 ] \
        || { fm_route_diagnostic 'reservation-binding-required'; return 1; }
      [ "$launch_harness" = "$(jq -r .launchHarness <<<"$current")" ] \
        && [ "$launch_model" = "$(jq -r .launchModel <<<"$current")" ] \
        && [ "$launch_effort" = "$expected_effort" ] \
        || { fm_route_diagnostic 'launch-binding-mismatch'; return 1; }
      fm_route_validate_current_policy_binding_locked "$current" || return 1
      fm_route_validate_claim_file_path "$task" "$generation" "$claim_file" || return 1
      [ ! -e "$claim_file" ] || { fm_route_diagnostic 'unexpected admission capability'; return 1; }
      fm_route_authorize_reservation "$task" "$prior_generation" "$prior_claim_file" "$prior_current" || return 1
      prior=$(fm_route_route_object "$prior_current") || return 1
      ;;
    off)
      [ -z "$prior_generation$prior_claim_file" ] || { fm_route_diagnostic 'unexpected prior reservation'; return 1; }
      [ "$state" = active ] || { fm_route_diagnostic 'reservation-not-active'; return 1; }
      [ "$(jq -r '.bindingVersion // 0' <<<"$current")" = 1 ] \
        || { fm_route_diagnostic 'legacy active reservation cannot be relaunched without an authoritative binding'; return 1; }
      fm_route_authorize_reservation "$task" "$generation" "$claim_file" "$current" || return 1
      prior=$target
      target=null
      ;;
    *) fm_route_diagnostic 'invalid admission transition'; return 1 ;;
  esac
  journal=$(fm_route_admission_path "$task") || return 1
  [ ! -e "$journal" ] || { fm_route_diagnostic 'admission-in-progress'; return 1; }
  now=$(date +%s)
  before=$(fm_route_metadata_snapshot "$metadata") || { fm_route_diagnostic 'invalid metadata state'; return 1; }
  beginning=$(jq -cn --arg task "$task" --arg transition "$transition" --arg phase beginning --argjson ownerPid "$owner_pid" --arg ownerStart "$owner_start" --argjson createdAt "$now" --arg metadataFile "$metadata" --argjson before "$before" --argjson target "$target" --argjson prior "$prior" \
    '{version:1,taskId:$task,transition:$transition,phase:$phase,ownerPid:$ownerPid,ownerStart:$ownerStart,createdAt:$createdAt,metadataFile:$metadataFile,metadataBefore:$before,expectedMetadataDigest:null,target:$target,prior:$prior,targetClaimHash:null,priorClaimHash:null}')
  case "$transition" in
    inherit) beginning=$(jq -c --arg hash "$(jq -r .claimHash <<<"$current")" '.targetClaimHash=$hash | .priorClaimHash=$hash' <<<"$beginning") ;;
    replacement) beginning=$(jq -c --arg hash "$(jq -r .claimHash <<<"$prior_current")" '.priorClaimHash=$hash' <<<"$beginning") ;;
    off) beginning=$(jq -c --arg hash "$(jq -r .claimHash <<<"$current")" '.priorClaimHash=$hash' <<<"$beginning") ;;
  esac
  fm_route_atomic_json_value "$journal" "$beginning" || return 1
  case "$transition" in
    fresh|replacement)
      if ! claim=$(fm_route_create_claim_file "$task" "$generation" "$claim_file"); then
        rm -f -- "$journal"
        return 1
      fi
      hash=$(fm_route_claim_hash "$claim") || { rm -f -- "$journal"; return 1; }
      claimed=$(fm_route_claim_reservation_value "$current" "$hash" "$now" "$owner_pid" "$owner_start" reserved)
      if ! fm_route_atomic_json_value "$reservation" "$claimed"; then
        rm -f -- "$journal"
        rm -f -- "$claim_file"
        return 1
      fi
      beginning=$(jq -c --arg hash "$hash" '.targetClaimHash=$hash' <<<"$beginning")
      ;;
    inherit)
      hash=$(jq -r .claimHash <<<"$current")
      claimed=$(fm_route_claim_reservation_value "$current" "$hash" "$now" "$owner_pid" "$owner_start" active)
      fm_route_atomic_json_value "$reservation" "$claimed" || { rm -f -- "$journal"; return 1; }
      ;;
    off) ;;
  esac
  beginning=$(jq -c '.phase="claimed"' <<<"$beginning")
  fm_route_atomic_json_value "$journal" "$beginning" || return 1
  printf '{"state":"claimed"}\n'
}

fm_route_authorize_capability_hash() {
  local task=$1 generation=$2 file=$3 expected=$4 claim hash
  fm_route_validate_claim_file_path "$task" "$generation" "$file" || return 1
  claim=$(fm_route_read_claim_file "$file") || return 1
  hash=$(fm_route_claim_hash "$claim") || return 1
  [ "$hash" = "$expected" ] || { fm_route_diagnostic 'admission capability mismatch'; return 1; }
}

fm_route_authorize_capability_or_cleaned() {
  local task=$1 generation=$2 file=$3 expected=$4 reservation
  fm_route_validate_claim_file_path "$task" "$generation" "$file" || return 1
  if [ -e "$file" ]; then
    fm_route_authorize_capability_hash "$task" "$generation" "$file" "$expected"
    return
  fi
  reservation=$(fm_route_optional_reservation_path "$task" "$generation") || return 1
  [ -z "$reservation" ] || { fm_route_diagnostic 'admission cleanup conflict'; return 1; }
}

fm_route_authorize_admission() {
  local journal=$1 claim_file=$2 prior_claim_file=${3:-} transition phase target_generation prior_generation target_hash prior_hash task
  transition=$(jq -r .transition <<<"$journal")
  phase=$(jq -r .phase <<<"$journal")
  task=$(jq -r .taskId <<<"$journal")
  target_generation=$(jq -r '.target.generation // empty' <<<"$journal")
  prior_generation=$(jq -r '.prior.generation // empty' <<<"$journal")
  target_hash=$(jq -r '.targetClaimHash // empty' <<<"$journal")
  prior_hash=$(jq -r '.priorClaimHash // empty' <<<"$journal")
  case "$transition" in
    fresh)
      if [ "$phase" = rollingBack ]; then
        fm_route_authorize_capability_or_cleaned "$task" "$target_generation" "$claim_file" "$target_hash" || return 1
      else
        fm_route_authorize_capability_hash "$task" "$target_generation" "$claim_file" "$target_hash" || return 1
      fi
      [ -z "$prior_claim_file" ] || { fm_route_diagnostic 'unexpected prior claim file'; return 1; }
      ;;
    inherit)
      fm_route_authorize_capability_hash "$task" "$target_generation" "$claim_file" "$target_hash" || return 1
      [ -z "$prior_claim_file" ] || { fm_route_diagnostic 'unexpected prior claim file'; return 1; }
      ;;
    replacement)
      if [ "$phase" = rollingBack ]; then
        fm_route_authorize_capability_or_cleaned "$task" "$target_generation" "$claim_file" "$target_hash" || return 1
      else
        fm_route_authorize_capability_hash "$task" "$target_generation" "$claim_file" "$target_hash" || return 1
      fi
      if [ "$phase" = committing ]; then
        fm_route_authorize_capability_or_cleaned "$task" "$prior_generation" "$prior_claim_file" "$prior_hash"
      else
        fm_route_authorize_capability_hash "$task" "$prior_generation" "$prior_claim_file" "$prior_hash"
      fi
      ;;
    off)
      if [ "$phase" = committing ]; then
        fm_route_authorize_capability_or_cleaned "$task" "$prior_generation" "$claim_file" "$prior_hash" || return 1
      else
        fm_route_authorize_capability_hash "$task" "$prior_generation" "$claim_file" "$prior_hash" || return 1
      fi
      [ -z "$prior_claim_file" ] || { fm_route_diagnostic 'unexpected prior claim file'; return 1; }
      ;;
  esac
}

fm_route_authorize_beginning_target() {
  local journal=$1 claim_file=$2 task generation reservation current state claim hash
  task=$(jq -r .taskId <<<"$journal")
  generation=$(jq -r '.target.generation // empty' <<<"$journal")
  fm_route_validate_claim_file_path "$task" "$generation" "$claim_file" || return 1
  reservation=$(fm_route_find_reservation_path "$task" "$generation") \
    || { fm_route_diagnostic 'target reservation not found'; return 1; }
  current=$(jq -c . "$reservation") || { fm_route_diagnostic 'invalid routing state'; return 1; }
  state=$(jq -r '.admissionState // "reserved"' <<<"$current")
  if [ -e "$claim_file" ]; then
    claim=$(fm_route_read_claim_file "$claim_file") || return 1
    hash=$(fm_route_claim_hash "$claim") || return 1
  else
    hash=
  fi
  case "$state" in
    reserved) ;;
    claimed)
      [ -n "$hash" ] && [ "$(jq -r '.claimHash // empty' <<<"$current")" = "$hash" ] \
        || { fm_route_diagnostic 'admission capability mismatch'; return 1; }
      ;;
    *) fm_route_diagnostic 'target reservation conflict'; return 1 ;;
  esac
  if [ -n "$hash" ]; then
    jq -c --arg hash "$hash" '.targetClaimHash=$hash' <<<"$journal"
  else
    printf '%s\n' "$journal"
  fi
}

fm_route_metadata_field() {
  awk -v key="$2" '
    index($0,key "=") == 1 { count++; value=substr($0,length(key)+2) }
    END { if (count == 1) print value; else exit 1 }
  ' "$1"
}

fm_route_validate_candidate_route() {
  local file=$1 target=$2 key expected actual
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(wc -c <"$file")" -le 1048576 ] || {
    fm_route_diagnostic 'invalid admission candidate'
    return 1
  }
  if [ "$target" = null ]; then
    for key in route_generation route_profile route_provider route_lane route_account route_class route_work_type route_risk route_mode; do
      ! grep -q "^$key=" "$file" || { fm_route_diagnostic 'admission candidate route mismatch'; return 1; }
    done
    return 0
  fi
  for key in generation profile provider lane account taskClass workType risk mode; do
    expected=$(jq -r --arg key "$key" '.[$key]' <<<"$target")
    case "$key" in taskClass) key=class ;; workType) key=work_type ;; esac
    actual=$(fm_route_metadata_field "$file" "route_$key") || { fm_route_diagnostic 'admission candidate route mismatch'; return 1; }
    [ "$actual" = "$expected" ] || { fm_route_diagnostic 'admission candidate route mismatch'; return 1; }
  done
  if [ "$(jq -r '.bindingVersion // 0' <<<"$target")" = 1 ]; then
    for key in harness model effort; do
      case "$key" in
        harness) expected=$(jq -r .launchHarness <<<"$target") ;;
        model) expected=$(jq -r .launchModel <<<"$target") ;;
        effort) expected=$(jq -r 'if .launchEffort == null then "default" else .launchEffort end' <<<"$target") ;;
      esac
      actual=$(fm_route_metadata_field "$file" "$key") \
        || { fm_route_diagnostic 'admission candidate launch mismatch'; return 1; }
      [ "$actual" = "$expected" ] \
        || { fm_route_diagnostic 'admission candidate launch mismatch'; return 1; }
    done
  fi
}

fm_route_prepare_admission_locked() {
  local task=$1 candidate=$2 claim_file=$3 prior_claim_file=$4 owner_pid=$5 owner_start=$6 journal_file journal target digest updated
  journal_file=$(fm_route_admission_path "$task") || return 1
  journal=$(fm_route_load_admission "$task") || return 1
  fm_route_admission_current_owner "$journal" "$owner_pid" "$owner_start" || return 1
  fm_route_authorize_admission "$journal" "$claim_file" "$prior_claim_file" || return 1
  target=$(jq -c '.target' <<<"$journal")
  fm_route_validate_candidate_route "$candidate" "$target" || return 1
  digest=$(fm_route_hash_file "$candidate") || { fm_route_diagnostic 'invalid admission candidate'; return 1; }
  if [ "$(jq -r .phase <<<"$journal")" = prepared ]; then
    [ "$(jq -r .expectedMetadataDigest <<<"$journal")" = "$digest" ] || { fm_route_diagnostic 'admission candidate conflict'; return 1; }
    printf '{"state":"prepared","idempotent":true}\n'
    return 0
  fi
  [ "$(jq -r .phase <<<"$journal")" = claimed ] || { fm_route_diagnostic 'admission is not claimed'; return 1; }
  updated=$(jq -c --arg digest "$digest" '.phase="prepared" | .expectedMetadataDigest=$digest' <<<"$journal")
  fm_route_atomic_json_value "$journal_file" "$updated" || return 1
  printf '{"state":"prepared","idempotent":false}\n'
}

fm_route_remove_reservation_file() {
  local file=$1 directory task
  directory=$(dirname "$file")
  fm_route_require_state_subdir reservations || return 1
  if [ "$directory" != "$FM_ROUTE_STATE/reservations" ]; then
    task=${directory##*/}
    [ "$directory" = "$FM_ROUTE_STATE/reservations/$task" ] || { fm_route_diagnostic 'invalid routing state'; return 1; }
    fm_route_require_task_subdir reservations "$task" || return 1
  fi
  rm -f -- "$file" || return 1
  [ "$directory" = "$FM_ROUTE_STATE/reservations" ] || rmdir "$directory" 2>/dev/null || true
}

fm_route_mark_convergence_locked() {
  local journal=$1 phase=$2 task current updated file
  current=$(jq -r .phase <<<"$journal")
  if [ "$current" = "$phase" ]; then
    printf '%s\n' "$journal"
    return 0
  fi
  case "$phase:$current" in
    committing:prepared|rollingBack:beginning|rollingBack:claimed|rollingBack:prepared) ;;
    *) fm_route_diagnostic 'invalid admission convergence'; return 1 ;;
  esac
  task=$(jq -r .taskId <<<"$journal")
  file=$(fm_route_admission_path "$task") || return 1
  updated=$(jq -c --arg phase "$phase" '.phase=$phase' <<<"$journal")
  fm_route_atomic_json_value "$file" "$updated" || return 1
  printf '%s\n' "$updated"
}

fm_route_admission_converge_success_locked() {
  local journal=$1 claim_file=$2 prior_claim_file=$3 transition task target_generation prior_generation target_file prior_file current expected state
  transition=$(jq -r .transition <<<"$journal")
  task=$(jq -r .taskId <<<"$journal")
  journal=$(fm_route_mark_convergence_locked "$journal" committing) || return 1
  target_generation=$(jq -r '.target.generation // empty' <<<"$journal")
  prior_generation=$(jq -r '.prior.generation // empty' <<<"$journal")
  case "$transition" in
    fresh|inherit|replacement)
      target_file=$(fm_route_find_reservation_path "$task" "$target_generation") || { fm_route_diagnostic 'target reservation not found'; return 1; }
      current=$(jq -c . "$target_file") || return 1
      expected=$(jq -r .targetClaimHash <<<"$journal")
      [ "$(jq -r '.claimHash // empty' <<<"$current")" = "$expected" ] || { fm_route_diagnostic 'target reservation conflict'; return 1; }
      state=$(jq -r '.admissionState // "reserved"' <<<"$current")
      case "$state" in
        claimed) fm_route_atomic_json_value "$target_file" "$(fm_route_active_reservation_value "$current")" || return 1 ;;
        active) ;;
        *) fm_route_diagnostic 'target reservation conflict'; return 1 ;;
      esac
      ;;
  esac
  case "$transition" in
    replacement|off)
      prior_file=$(fm_route_optional_reservation_path "$task" "$prior_generation") || return 1
      if [ -n "$prior_file" ]; then
        current=$(jq -c . "$prior_file") || return 1
        [ "$(jq -r '.admissionState // "reserved"' <<<"$current")" = active ] \
          && [ "$(jq -r '.claimHash // empty' <<<"$current")" = "$(jq -r .priorClaimHash <<<"$journal")" ] \
          || { fm_route_diagnostic 'prior reservation conflict'; return 1; }
        fm_route_remove_reservation_file "$prior_file" || return 1
      fi
      ;;
  esac
  case "$transition" in
    replacement) fm_route_remove_claim_file "$task" "$prior_generation" "$prior_claim_file" || return 1 ;;
    off) fm_route_remove_claim_file "$task" "$prior_generation" "$claim_file" || return 1 ;;
  esac
  fm_route_remove_admission_file "$task" || return 1
  printf '{"state":"active","recovered":false}\n'
}

fm_route_admission_converge_rollback_locked() {
  local journal=$1 claim_file=$2 transition task target_generation target_file current state expected
  transition=$(jq -r .transition <<<"$journal")
  task=$(jq -r .taskId <<<"$journal")
  journal=$(fm_route_mark_convergence_locked "$journal" rollingBack) || return 1
  target_generation=$(jq -r '.target.generation // empty' <<<"$journal")
  case "$transition" in
    fresh|replacement)
      target_file=$(fm_route_optional_reservation_path "$task" "$target_generation") || return 1
      if [ -n "$target_file" ]; then
        current=$(jq -c . "$target_file") || return 1
        state=$(jq -r '.admissionState // "reserved"' <<<"$current")
        expected=$(jq -r '.targetClaimHash // empty' <<<"$journal")
        case "$state" in
          reserved) ;;
          claimed) [ "$(jq -r .claimHash <<<"$current")" = "$expected" ] || { fm_route_diagnostic 'target reservation conflict'; return 1; } ;;
          *) fm_route_diagnostic 'target reservation conflict'; return 1 ;;
        esac
        fm_route_remove_reservation_file "$target_file" || return 1
      fi
      ;;
    inherit)
      target_file=$(fm_route_find_reservation_path "$task" "$target_generation") || { fm_route_diagnostic 'target reservation not found'; return 1; }
      current=$(jq -c . "$target_file") || return 1
      state=$(jq -r '.admissionState // "reserved"' <<<"$current")
      case "$state" in
        claimed)
          [ "$(jq -r .claimHash <<<"$current")" = "$(jq -r .targetClaimHash <<<"$journal")" ] || { fm_route_diagnostic 'target reservation conflict'; return 1; }
          fm_route_atomic_json_value "$target_file" "$(fm_route_active_reservation_value "$current")" || return 1
          ;;
        active) ;;
        *) fm_route_diagnostic 'target reservation conflict'; return 1 ;;
      esac
      ;;
    off) ;;
  esac
  case "$transition" in
    fresh|replacement) fm_route_remove_claim_file "$task" "$target_generation" "$claim_file" || return 1 ;;
  esac
  fm_route_remove_admission_file "$task" || return 1
  printf '{"state":"rolled-back"}\n'
}

fm_route_admission_metadata_outcome() {
  local journal=$1 metadata before expected current
  metadata=$(jq -r .metadataFile <<<"$journal")
  before=$(jq -c .metadataBefore <<<"$journal")
  current=$(fm_route_metadata_snapshot "$metadata") || { fm_route_diagnostic 'invalid metadata state'; return 1; }
  if jq -e --argjson current "$current" '. == $current' <<<"$before" >/dev/null; then
    printf 'rollback\n'
    return 0
  fi
  expected=$(jq -r '.expectedMetadataDigest // empty' <<<"$journal")
  if [ -n "$expected" ] && jq -e --arg expected "$expected" '.exists == true and .digest == $expected' <<<"$current" >/dev/null; then
    printf 'commit\n'
    return 0
  fi
  fm_route_diagnostic 'admission metadata conflict'
  return 1
}

fm_route_commit_admission_locked() {
  local task=$1 claim_file=$2 prior_claim_file=$3 owner_pid=$4 owner_start=$5 journal outcome
  journal=$(fm_route_load_admission "$task") || return 1
  fm_route_admission_current_owner "$journal" "$owner_pid" "$owner_start" || return 1
  fm_route_authorize_admission "$journal" "$claim_file" "$prior_claim_file" || return 1
  [ "$(jq -r .phase <<<"$journal")" = prepared ] || { fm_route_diagnostic 'admission is not prepared'; return 1; }
  outcome=$(fm_route_admission_metadata_outcome "$journal") || return 1
  [ "$outcome" = commit ] || { fm_route_diagnostic 'admission metadata is not published'; return 1; }
  fm_route_admission_converge_success_locked "$journal" "$claim_file" "$prior_claim_file"
}

fm_route_abort_admission_locked() {
  local task=$1 claim_file=$2 prior_claim_file=$3 owner_pid=$4 owner_start=$5 journal outcome phase transition
  journal=$(fm_route_load_admission "$task") || return 1
  fm_route_admission_current_owner "$journal" "$owner_pid" "$owner_start" || return 1
  phase=$(jq -r .phase <<<"$journal")
  transition=$(jq -r .transition <<<"$journal")
  if [ "$phase" = beginning ] && [ -z "$(jq -r '.targetClaimHash // empty' <<<"$journal")" ] \
    && { [ "$transition" = fresh ] || [ "$transition" = replacement ]; }; then
    journal=$(fm_route_authorize_beginning_target "$journal" "$claim_file") || return 1
  else
    fm_route_authorize_admission "$journal" "$claim_file" "$prior_claim_file" || return 1
  fi
  outcome=$(fm_route_admission_metadata_outcome "$journal") || return 1
  if [ "$outcome" = commit ]; then
    fm_route_admission_converge_success_locked "$journal" "$claim_file" "$prior_claim_file"
  else
    fm_route_admission_converge_rollback_locked "$journal" "$claim_file"
  fi
}

fm_route_recover_admission_locked() {
  local task=$1 claim_file=$2 prior_claim_file=$3 journal_file journal now owner_pid owner_start outcome transition target_generation target_file claimed_at
  journal_file=$(fm_route_admission_path "$task") || return 1
  if [ ! -e "$journal_file" ]; then
    printf '{"state":"none","idempotent":true}\n'
    return 0
  fi
  journal=$(fm_route_load_admission "$task") || return 1
  now=$(date +%s)
  [ "$((now - $(jq -r .createdAt <<<"$journal")))" -ge "$FM_ROUTE_CLAIM_TIMEOUT" ] || {
    fm_route_diagnostic 'admission owner is not stale'
    return 1
  }
  owner_pid=$(jq -r .ownerPid <<<"$journal")
  owner_start=$(jq -r .ownerStart <<<"$journal")
  ! fm_route_owner_matches "$owner_pid" "$owner_start" || {
    fm_route_diagnostic 'admission owner is still live'
    return 1
  }
  target_generation=$(jq -r '.target.generation // empty' <<<"$journal")
  target_file=
  if [ -n "$target_generation" ]; then
    target_file=$(fm_route_optional_reservation_path "$task" "$target_generation") || return 1
  fi
  if [ -n "$target_file" ] && [ "$(jq -r '.admissionState // "reserved"' "$target_file")" = claimed ]; then
    claimed_at=$(jq -r .claimedAt "$target_file")
    [ "$((now - claimed_at))" -ge "$FM_ROUTE_CLAIM_TIMEOUT" ] || {
      fm_route_diagnostic 'admission claim is not stale'
      return 1
    }
  fi
  transition=$(jq -r .transition <<<"$journal")
  if [ "$(jq -r .phase <<<"$journal")" = beginning ] \
    && [ -z "$(jq -r '.targetClaimHash // empty' <<<"$journal")" ] \
    && { [ "$transition" = fresh ] || [ "$transition" = replacement ]; }; then
    journal=$(fm_route_authorize_beginning_target "$journal" "$claim_file") || return 1
  else
    fm_route_authorize_admission "$journal" "$claim_file" "$prior_claim_file" || return 1
  fi
  outcome=$(fm_route_admission_metadata_outcome "$journal") || return 1
  if [ "$outcome" = commit ]; then
    fm_route_admission_converge_success_locked "$journal" "$claim_file" "$prior_claim_file"
  else
    fm_route_admission_converge_rollback_locked "$journal" "$claim_file"
  fi
}

fm_routing_failure_action() {
  case "$1" in
    transient) [ "$2" -lt 1 ] && printf 'retry\n' || printf 'fallback\n' ;;
    quota|auth|model) printf 'fallback\n' ;;
    unsafe) printf 'escalate\n' ;;
  esac
}

fm_route_failure_locked() {
  local task=$1 generation=$2 provider=$3 lane=$4 kind=$5 now=$6 circuits event_key existing prior_transients action failures open_until updated event
  circuits=$(fm_route_read_circuits) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  event_key="$task|$generation"
  existing=$(jq -c --arg key "$event_key" '.events[$key] // empty' <<<"$circuits")
  if [ -n "$existing" ]; then
    jq -e --arg provider "$provider" --arg lane "$lane" --arg kind "$kind" '.provider == $provider and .lane == $lane and .kind == $kind' <<<"$existing" >/dev/null \
      || { fm_route_diagnostic 'failure-conflict'; return 1; }
    jq -cn --arg action "$(jq -r .action <<<"$existing")" --argjson until "$(jq -r '.until // null' <<<"$existing")" '{action:$action} + (if $until == null then {} else {until:$until} end)'
    return 0
  fi
  if jq -e --arg lane "$lane" --argjson now "$now" '.lanes[$lane].openUntil? > $now' <<<"$circuits" >/dev/null; then
    if [ "$kind" = unsafe ]; then action=escalate; else action=circuit-open; fi
    open_until=$(jq -r --arg lane "$lane" '.lanes[$lane].openUntil' <<<"$circuits")
  else
    prior_transients=$(jq --arg task "$task" '[.events[] | select(.taskId == $task and .kind == "transient")] | length' <<<"$circuits")
    action=$(fm_routing_failure_action "$kind" "$prior_transients")
    failures=$(jq -c --arg lane "$lane" --argjson cutoff "$((now - 900))" '[.events[] | select(.lane == $lane and .timestamp >= $cutoff)]' <<<"$circuits")
    if [ "$(jq 'length' <<<"$failures")" -ge 2 ]; then
      [ "$kind" = unsafe ] || action=circuit-open
      open_until=$((now + 1800))
    else
      open_until=null
    fi
  fi
  event=$(jq -cn --arg task "$task" --arg generation "$generation" --arg provider "$provider" --arg lane "$lane" --arg kind "$kind" --arg action "$action" --argjson now "$now" --argjson until "$open_until" \
    '{taskId:$task,generation:$generation,provider:$provider,lane:$lane,kind:$kind,timestamp:$now,action:$action,until:$until}')
  updated=$(jq -c --arg key "$event_key" --arg lane "$lane" --arg provider "$provider" --argjson event "$event" --argjson until "$open_until" '
    .events[$key] = $event
    | .lanes[$lane] = {provider:$provider,openUntil:$until}
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
  local task=$1 generation=$2 terminal=$3 tests=$4 review=$5 redundant=$6 now=$7 reservation current updated
  reservation=$(fm_route_find_reservation_path "$task" "$generation") || { fm_route_diagnostic 'reservation-not-found'; return 1; }
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
  fm_route_read_outcomes >/dev/null || { fm_route_diagnostic 'invalid routing state'; return 1; }
  directory=$(dirname "$file")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.routing-ledger.XXXXXX") || return 1
  { [ ! -f "$file" ] || cat "$file"; printf '%s\n' "$record"; } >"$temporary" || { rm -f "$temporary"; return 1; }
  jq -s 'all(type == "object")' "$temporary" >/dev/null 2>&1 || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$file" || return 1
  fm_routing_rotate_ledger "$file"
}

fm_route_finalize_locked() {
  local task=$1 generation=$2 terminal=$3 claim_file=${4:-} reservation outcomes existing current state score record admission
  reservation=$(fm_route_optional_reservation_path "$task" "$generation") || return 1
  if [ -n "$reservation" ]; then
    current=$(jq -c . "$reservation" 2>/dev/null) || { fm_route_diagnostic 'invalid routing state'; return 1; }
    state=$(jq -r '.admissionState // "reserved"' <<<"$current")
    [ "$state" = active ] || {
      admission=$(fm_route_admission_path "$task") || return 1
      if [ "$state" = claimed ] && [ -e "$admission" ]; then
        fm_route_diagnostic 'admission recovery required'
      else
        fm_route_diagnostic 'reservation-not-active'
      fi
      return 1
    }
    admission=$(fm_route_admission_path "$task") || return 1
    [ ! -e "$admission" ] || { fm_route_diagnostic 'admission recovery required'; return 1; }
    [ -n "$claim_file" ] || { fm_route_diagnostic 'reservation capability required'; return 1; }
    fm_route_authorize_reservation "$task" "$generation" "$claim_file" "$current" || return 1
  fi
  outcomes=$(fm_route_read_outcomes) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  existing=$(jq -c --arg task "$task" --arg generation "$generation" '.[] | select(.kind == "terminal" and .taskId == $task and .generation == $generation)' <<<"$outcomes" | head -n 1)
  if [ -n "$existing" ]; then
    [ "$(jq -r .terminal <<<"$existing")" = "$terminal" ] || { fm_route_diagnostic 'terminal-outcome-conflict'; return 1; }
    if [ -n "$reservation" ] && [ -e "$reservation" ]; then
      jq -e --argjson outcome "$existing" '
        .taskId == $outcome.taskId and .generation == $outcome.generation and .profile == $outcome.profile
        and .provider == $outcome.provider and .lane == $outcome.lane and .account == $outcome.account
        and .taskClass == $outcome.taskClass and .workType == $outcome.workType
        and .risk == $outcome.risk and .mode == $outcome.mode
      ' <<<"$current" >/dev/null || { fm_route_diagnostic 'reservation-outcome-mismatch'; return 1; }
      fm_route_remove_reservation_file "$reservation" || return 1
      fm_route_remove_claim_file "$task" "$generation" "$claim_file" || return 1
    elif [ -n "$claim_file" ]; then
      fm_route_validate_claim_file_path "$task" "$generation" "$claim_file" || return 1
      if [ -e "$claim_file" ]; then
        fm_route_remove_claim_file "$task" "$generation" "$claim_file" || return 1
      fi
    fi
    printf '%s\n' "$existing"
    return 0
  fi
  [ -n "$reservation" ] && [ -s "$reservation" ] || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  [ "$(jq -r .generation <<<"$current")" = "$generation" ] || { fm_route_diagnostic 'reservation-generation-mismatch'; return 1; }
  score=$(jq -c '.score // {terminal:null,tests:"unknown",review:"unknown",redundant:"no",timestamp:.createdAt}' <<<"$current")
  if [ "$(jq -r '.terminal // empty' <<<"$score")" != "" ] && [ "$(jq -r .terminal <<<"$score")" != "$terminal" ]; then
    fm_route_diagnostic 'terminal-outcome-mismatch'
    return 1
  fi
  record=$(jq -cn --argjson reservation "$current" --argjson score "$score" --arg terminal "$terminal" '
    {kind:"terminal",timestamp:$score.timestamp,taskId:$reservation.taskId,generation:$reservation.generation,profile:$reservation.profile,provider:$reservation.provider,lane:$reservation.lane,account:$reservation.account,taskClass:$reservation.taskClass,workType:$reservation.workType,risk:$reservation.risk,mode:$reservation.mode,elapsedSeconds:([$score.timestamp-$reservation.createdAt,0]|max),tests:$score.tests,review:$score.review,redundant:$score.redundant,terminal:$terminal}
  ')
  fm_route_append_outcome_locked "$record" || return 1
  fm_route_remove_reservation_file "$reservation" || return 1
  fm_route_remove_claim_file "$task" "$generation" "$claim_file" || return 1
  printf '%s\n' "$record"
}

fm_route_recover_for_cleanup_locked() {
  local task=$1 journal_file journal transition target_generation prior_generation claim_file prior_claim_file
  journal_file=$(fm_route_admission_path "$task") || return 1
  [ -e "$journal_file" ] || return 0
  journal=$(fm_route_load_admission "$task") || return 1
  transition=$(jq -r .transition <<<"$journal")
  target_generation=$(jq -r '.target.generation // empty' <<<"$journal")
  prior_generation=$(jq -r '.prior.generation // empty' <<<"$journal")
  claim_file=
  prior_claim_file=
  case "$transition" in
    fresh|inherit)
      claim_file=$(fm_route_claim_file_path "$task" "$target_generation") || return 1
      ;;
    replacement)
      claim_file=$(fm_route_claim_file_path "$task" "$target_generation") || return 1
      prior_claim_file=$(fm_route_claim_file_path "$task" "$prior_generation") || return 1
      ;;
    off)
      claim_file=$(fm_route_claim_file_path "$task" "$prior_generation") || return 1
      ;;
  esac
  fm_route_recover_admission_locked "$task" "$claim_file" "$prior_claim_file" >/dev/null
}

fm_route_cleanup_admission_ready_locked() {
  local task=$1 journal now owner_pid owner_start target_generation target_file claimed_at
  local transition phase claim_file prior_claim_file target_hash outcome future
  journal=$(fm_route_load_admission "$task") || return 1
  now=$(date +%s)
  [ "$((now - $(jq -r .createdAt <<<"$journal")))" -ge "$FM_ROUTE_CLAIM_TIMEOUT" ] \
    || { fm_route_diagnostic 'admission owner is not stale'; return 1; }
  owner_pid=$(jq -r .ownerPid <<<"$journal")
  owner_start=$(jq -r .ownerStart <<<"$journal")
  ! fm_route_owner_matches "$owner_pid" "$owner_start" \
    || { fm_route_diagnostic 'admission owner is still live'; return 1; }
  target_generation=$(jq -r '.target.generation // empty' <<<"$journal")
  target_file=
  if [ -n "$target_generation" ]; then
    target_file=$(fm_route_optional_reservation_path "$task" "$target_generation") || return 1
  fi
  if [ -n "$target_file" ] && [ "$(jq -r '.admissionState // "reserved"' "$target_file")" = claimed ]; then
    claimed_at=$(jq -r .claimedAt "$target_file")
    [ "$((now - claimed_at))" -ge "$FM_ROUTE_CLAIM_TIMEOUT" ] \
      || { fm_route_diagnostic 'admission claim is not stale'; return 1; }
  fi
  transition=$(jq -r .transition <<<"$journal")
  phase=$(jq -r .phase <<<"$journal")
  claim_file=
  prior_claim_file=
  case "$transition" in
    fresh|inherit)
      claim_file=$(fm_route_claim_file_path "$task" "$target_generation") || return 1
      ;;
    replacement)
      claim_file=$(fm_route_claim_file_path "$task" "$target_generation") || return 1
      prior_claim_file=$(fm_route_claim_file_path "$task" "$(jq -r '.prior.generation' <<<"$journal")") || return 1
      ;;
    off)
      claim_file=$(fm_route_claim_file_path "$task" "$(jq -r '.prior.generation' <<<"$journal")") || return 1
      ;;
  esac
  target_hash=$(jq -r '.targetClaimHash // empty' <<<"$journal")
  if [ "$phase" = beginning ] && [ -z "$target_hash" ] \
    && { [ "$transition" = fresh ] || [ "$transition" = replacement ]; }; then
    journal=$(fm_route_authorize_beginning_target "$journal" "$claim_file") || return 1
  else
    fm_route_authorize_admission "$journal" "$claim_file" "$prior_claim_file" || return 1
  fi
  outcome=$(fm_route_admission_metadata_outcome "$journal") || return 1
  if [ "$outcome" = commit ]; then
    future=$(jq -c .target <<<"$journal")
  else
    future=$(jq -c .prior <<<"$journal")
  fi
  [ "$future" != null ] || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  printf '%s\n' "$future"
}

fm_route_cleanup_outcome_matches() {
  local existing=$1 profile=$2 provider=$3 lane=$4 account=$5 task_class=$6 work_type=$7 risk=$8 mode=$9
  jq -e --arg profile "$profile" --arg provider "$provider" --arg lane "$lane" \
    --arg account "$account" --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" \
    --arg mode "$mode" '
      .profile == $profile and .provider == $provider and .lane == $lane
      and .account == $account and .taskClass == $class
      and .workType == $workType and .risk == $risk and .mode == $mode
    ' <<<"$existing" >/dev/null
}

fm_route_cleanup_route_matches() {
  local route=$1 task=$2 generation=$3 profile=$4 provider=$5 lane=$6 account=$7 task_class=$8 work_type=$9 risk=${10} mode=${11}
  jq -e --arg task "$task" --arg generation "$generation" --arg profile "$profile" \
    --arg provider "$provider" --arg lane "$lane" --arg account "$account" \
    --arg class "$task_class" --arg workType "$work_type" --arg risk "$risk" --arg mode "$mode" '
      ((has("taskId") | not) or .taskId == $task)
      and .generation == $generation and .profile == $profile
      and .provider == $provider and .lane == $lane and .account == $account
      and .taskClass == $class and .workType == $workType
      and .risk == $risk and .mode == $mode
    ' <<<"$route" >/dev/null
}

fm_route_cleanup_terminal_resolution() {
  local existing=${1:-} current=${2:-} existing_terminal='' score_terminal='' terminal=''
  if [ -n "$existing" ]; then
    existing_terminal=$(jq -r '.terminal' <<<"$existing") || return 1
  fi
  if [ -n "$current" ]; then
    score_terminal=$(jq -r '.score.terminal // empty' <<<"$current") || return 1
  fi
  if [ -n "$existing_terminal" ] && [ -n "$score_terminal" ] \
    && [ "$existing_terminal" != "$score_terminal" ]; then
    fm_route_diagnostic 'terminal-score-conflict'
    return 1
  fi
  if [ -n "$existing" ] && [ -n "$score_terminal" ]; then
    jq -e --argjson outcome "$existing" '
      .score.terminal == $outcome.terminal
      and .score.tests == $outcome.tests
      and .score.review == $outcome.review
      and .score.redundant == $outcome.redundant
      and .score.timestamp == $outcome.timestamp
    ' <<<"$current" >/dev/null || {
      fm_route_diagnostic 'terminal-score-conflict'
      return 1
    }
  fi
  terminal=${existing_terminal:-${score_terminal:-completed}}
  case "$terminal" in
    completed|failed_safe|escalated|cancelled|superseded) ;;
    *) fm_route_diagnostic 'invalid routing state'; return 1 ;;
  esac
  jq -cn --arg terminal "$terminal" '{terminal:$terminal}'
}

fm_route_cleanup_ready_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10}
  local reservation current admission claim_file outcomes matches existing future
  outcomes=$(fm_route_read_outcomes) || { fm_route_diagnostic 'invalid routing state'; return 1; }
  matches=$(jq -c --arg task "$task" --arg generation "$generation" \
    '[.[] | select(.kind == "terminal" and .taskId == $task and .generation == $generation)]' \
    <<<"$outcomes") || return 1
  [ "$(jq -r 'length' <<<"$matches")" -le 1 ] \
    || { fm_route_diagnostic 'terminal-outcome-conflict'; return 1; }
  existing=$(jq -c '.[0] // empty' <<<"$matches")
  if [ -n "$existing" ]; then
    fm_route_cleanup_outcome_matches "$existing" "$profile" "$provider" "$lane" "$account" "$task_class" "$work_type" "$risk" "$mode" \
      || { fm_route_diagnostic 'terminal-outcome-conflict'; return 1; }
    reservation=$(fm_route_optional_reservation_path "$task" "$generation") || return 1
  fi
  admission=$(fm_route_admission_path "$task") || return 1
  if [ -e "$admission" ]; then
    future=$(fm_route_cleanup_admission_ready_locked "$task") || return 1
    fm_route_cleanup_route_matches "$future" "$task" "$generation" "$profile" "$provider" "$lane" "$account" "$task_class" "$work_type" "$risk" "$mode" \
      || { fm_route_diagnostic 'reservation-mismatch'; return 1; }
    fm_route_cleanup_terminal_resolution "$existing" "$future"
    return $?
  fi
  if [ -n "$existing" ] && [ -z "$reservation" ]; then
    claim_file=$(fm_route_claim_file_path "$task" "$generation") || return 1
    [ ! -e "$claim_file" ] || fm_route_read_claim_file "$claim_file" >/dev/null || return 1
    fm_route_cleanup_terminal_resolution "$existing"
    return $?
  fi
  reservation=$(fm_route_find_reservation_path "$task" "$generation") \
    || { fm_route_diagnostic 'reservation-not-found'; return 1; }
  current=$(jq -c . "$reservation" 2>/dev/null) \
    || { fm_route_diagnostic 'invalid routing state'; return 1; }
  fm_route_cleanup_route_matches "$current" "$task" "$generation" "$profile" "$provider" "$lane" "$account" "$task_class" "$work_type" "$risk" "$mode" \
    && [ "$(jq -r '.admissionState // "reserved"' <<<"$current")" = active ] \
    || { fm_route_diagnostic 'reservation-mismatch'; return 1; }
  claim_file=$(fm_route_claim_file_path "$task" "$generation") || return 1
  fm_route_authorize_reservation "$task" "$generation" "$claim_file" "$current" || return 1
  fm_route_cleanup_terminal_resolution "$existing" "$current"
}

fm_route_cleanup_finalize_locked() {
  local task=$1 generation=$2 profile=$3 provider=$4 lane=$5 account=$6 task_class=$7 work_type=$8 risk=$9 mode=${10} terminal=${11}
  local claim_file resolution resolved
  resolution=$(fm_route_cleanup_ready_locked "$task" "$generation" "$profile" "$provider" "$lane" "$account" "$task_class" "$work_type" "$risk" "$mode") \
    || return 1
  resolved=$(jq -er 'select(type == "object" and keys == ["terminal"] and (.terminal | IN("completed","failed_safe","escalated","cancelled","superseded"))) | .terminal' \
    <<<"$resolution") || { fm_route_diagnostic 'invalid routing state'; return 1; }
  [ "$resolved" = "$terminal" ] || { fm_route_diagnostic 'terminal-outcome-conflict'; return 1; }
  fm_route_recover_for_cleanup_locked "$task" || return 1
  resolution=$(fm_route_cleanup_ready_locked "$task" "$generation" "$profile" "$provider" "$lane" "$account" "$task_class" "$work_type" "$risk" "$mode") \
    || return 1
  resolved=$(jq -er 'select(type == "object" and keys == ["terminal"] and (.terminal | IN("completed","failed_safe","escalated","cancelled","superseded"))) | .terminal' \
    <<<"$resolution") || { fm_route_diagnostic 'invalid routing state'; return 1; }
  [ "$resolved" = "$terminal" ] || { fm_route_diagnostic 'terminal-outcome-conflict'; return 1; }
  claim_file=$(fm_route_claim_file_path "$task" "$generation") || return 1
  fm_route_finalize_locked "$task" "$generation" "$terminal" "$claim_file"
}

fm_route_observe_locked() {
  local request=$1 decision=$2 now=$3 forbidden reason record
  forbidden=$(fm_route_forbidden_outcome_field <"$decision") || { fm_route_diagnostic 'invalid decision JSON'; return 1; }
  [ -z "$forbidden" ] || { fm_route_diagnostic "forbidden outcome field: $forbidden"; return 1; }
  reason=$(jq -r '
    def expected: ["action","maxWorkers","ranked","reason","rejected","selected","uncertainty"];
    def selected_expected: ["profile","harness","model","provider","lane","account","fitTier","reasoningClass","catalogSupported","authState","spendPriority","runwaySeconds","activeLane","historySuccesses","historyAttempts","costTier"];
    def identifier: type == "string" and length <= 128 and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
    def selected_error:
      if type != "object" then "selected profile is required"
      elif (keys_unsorted - selected_expected | length) > 0 then "unexpected field \((keys_unsorted - selected_expected)[0])"
      elif (selected_expected - keys_unsorted | length) > 0 then "missing \((selected_expected - keys_unsorted)[0])"
      elif (.profile | identifier | not) then "profile"
      elif (.harness | IN("claude","codex","pi","pi-signed") | not) then "harness"
      elif (.model | type) != "string" or (.model | length) == 0 or (.model | length) > 256 or (.model | test("^[A-Za-z0-9][A-Za-z0-9._:/-]*$") | not) then "model"
      elif (.provider | identifier | not) then "provider"
      elif (.lane | identifier | not) then "lane"
      elif (.account | identifier | not) then "account"
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
      elif (.historyAttempts | type) != "number" or (.historyAttempts | floor) != .historyAttempts or .historyAttempts < .historySuccesses then "historyAttempts"
      elif (.costTier != null and ((.costTier | type) != "number" or (.costTier | floor) != .costTier or .costTier < 0)) then "costTier"
      else "ok" end;
    if type != "object" then "top-level value must be an object"
    elif (keys_unsorted - expected | length) > 0 then "unexpected field \((keys_unsorted - expected)[0])"
    elif (expected - keys_unsorted | length) > 0 then "missing \((expected - keys_unsorted)[0])"
    elif .action != "selected" then "decision must select a profile"
    elif (.selected | selected_error) != "ok" then "selected:\(.selected | selected_error)"
    else "ok" end
  ' "$decision" 2>/dev/null) || { fm_route_diagnostic 'invalid decision JSON'; return 1; }
  if [ "$reason" != ok ]; then
    case "$reason" in selected:*) fm_route_diagnostic "invalid selected route schema: ${reason#selected:}" ;; *) fm_route_diagnostic "invalid decision schema: $reason" ;; esac
    return 1
  fi
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
  jq -cn --arg workType "$work_type" --argjson outcomes "$outcomes" '$outcomes | map(select(.kind == "terminal" and .workType == $workType)) | group_by(.profile) | map({profile:.[0].profile,successes:([.[] | select(.terminal == "completed")] | length),attempts:length}) | sort_by(.profile)'
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
    {mode:$mode,caps:{canary:3,automatic:6,burst:8,perLane:2,perAccount:2},circuitBreaker:{failures:3,windowSeconds:900,cooldownSeconds:1800},active:{total:($reservations|length),byLane:($reservations|group_by(.lane)|map({key:.[0].lane,value:length})|from_entries),byAccount:($reservations|map(select(.account != "none"))|group_by(.account)|map({key:.[0].account,value:length})|from_entries)},openCircuits:([$circuits.lanes|to_entries[]|select(.value.openUntil? > $now)|{lane:.key,provider:.value.provider,until:.value.openUntil}]|sort_by(.lane))}
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
