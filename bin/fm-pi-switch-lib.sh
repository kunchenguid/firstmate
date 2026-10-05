#!/usr/bin/env bash
# fm-pi-switch-lib.sh - the ONE executable owner of Firstmate's live Pi
# model/effort/provider switch protocol.
#
# Sourced by bin/fm-control.sh (the control-plane verb) and tests. Header plus
# --help on bin/fm-control.sh own caller-facing flags. This file owns:
#   - the per-task request/ack/ready/history paths
#   - request and ack JSON schema fm-pi-switch-model.v1
#   - catalog, effort-token, auth, and quota helpers
#   - request publication and ack correlation
#   - post-confirmation metadata and history writes
# The control verb owns account-pin checks and idle waiting; the generated
# Pi extension owns model-specific effort/context checks and turn admission.
#
# Ready JSON names busy_gen, a runtime incarnation UUID, session_id, and the
# observed model/effort. Requests bind that incarnation and session, with an
# epoch deadline and optional cancelled=true. Acknowledgements bind the same
# identity and carry status plus actual model/effort; absent fields are unknown.
# Requests retire only after locked metadata reconciliation. A missing result
# cancels the request and blocks further switching/relaunch until reconciled.
# Quota joins reuse fm-quota-axi-lib.sh with the configured profile provider;
# capability and completion-horizon selection remain quota-array-dispatch's
# responsibility before the direct control verb is called.
#
# Live switching uses the per-task Pi extension already loaded with -e on a
# ship or scout TUI launch (bin/fm-spawn.sh). It does not switch the pane to
# RPC mode and does not replace the running harness. A harness change remains
# bin/fm-control.sh relaunch.
#
# Caller timeout knobs belong to fm-control.sh; selector bounds belong to
# fm-profile-switch.sh. FM_PI_BIN selects the helper executable (default pi);
# fm-control sets it from the task's recorded Pi-family harness so catalog
# and authentication checks use the same adapter as launch.

FM_PI_SWITCH_SCHEMA=fm-pi-switch-model.v1

fm_pi_switch_req_path() { printf '%s/%s.model-switch.req' "$1" "$2"; }
fm_pi_switch_ack_path() { printf '%s/%s.model-switch.ack' "$1" "$2"; }
fm_pi_switch_ready_path() { printf '%s/%s.model-switch.ready' "$1" "$2"; }
fm_pi_switch_log_path() { printf '%s/%s.model-switch.log' "$1" "$2"; }

fm_pi_switch_harness_supported() {  # <harness-family>
  case "${1-}" in
    pi|pi-signed) return 0 ;;
  esac
  return 1
}

fm_pi_switch_effort_ok() {  # <effort>
  case "${1-}" in
    ''|default|low|medium|high|xhigh|max) return 0 ;;
  esac
  return 1
}

# fm_pi_switch_parse_model <model>
# Prints "provider<TAB>id" for a provider-qualified model. Returns 1 otherwise.
fm_pi_switch_parse_model() {
  local model=${1-}
  case "$model" in
    */*)
      [ -n "${model%%/*}" ] && [ -n "${model#*/}" ] || return 1
      printf '%s\t%s\n' "${model%%/*}" "${model#*/}"
      ;;
    *) return 1 ;;
  esac
}

# fm_pi_switch_catalog_row <provider> <id>
# Prints "provider<TAB>id<TAB>context" when the installed Pi catalog lists that
# exact pair. Override the listing with FM_PI_SWITCH_LISTING (file) for tests.
fm_pi_switch_catalog_row() {
  local provider=$1 id=$2 listing bin
  if [ -n "${FM_PI_SWITCH_LISTING-}" ]; then
    listing=$(cat "$FM_PI_SWITCH_LISTING")
  else
    bin=${FM_PI_BIN:-pi}
    listing=$("$bin" --list-models "$provider/$id" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$listing" | awk -v p="$provider" -v i="$id" '
    NR == 1 { next }
    $1 == p && $2 == i { print $1 "\t" $2 "\t" $3; found = 1; exit }
    END { exit !found }
  '
}

# fm_pi_switch_auth_ready <provider>
# Returns 0 when Pi reports the provider ready. Override with
# FM_PI_SWITCH_AUTH_JSON (file of `pi auth check --json` output).
fm_pi_switch_auth_ready() {
  local provider=$1 out bin
  if [ -n "${FM_PI_SWITCH_AUTH_JSON-}" ]; then
    out=$(cat "$FM_PI_SWITCH_AUTH_JSON")
  else
    bin=${FM_PI_BIN:-pi}
    out=$("$bin" auth check --provider "$provider" --json --no-refresh 2>/dev/null </dev/null) || return 1
  fi
  printf '%s' "$out" | jq -e '.status == "ready"' >/dev/null 2>&1
}

fm_pi_switch_new_id() {
  printf '%s.%s.%s' "$(date +%s)" "${BASHPID:-$$}" "$RANDOM"
}

# fm_pi_switch_write_json <path> <json-object>
# Atomic replace of one JSON file.
fm_pi_switch_write_json() {
  local path=$1 json=$2 tmp
  tmp=$(mktemp "${path}.XXXXXX") || return 1
  printf '%s\n' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path"
}

# fm_pi_switch_write_request <state> <id> <req-id> <provider> <model-id> <effort>
fm_pi_switch_write_request() {
  local state=$1 task=$2 req_id=$3 provider=$4 model_id=$5 effort=${6-}
  local path json ts ready deadline
  ts=$(date +%s)
  deadline=$(awk -v now="$ts" -v wait="${FM_CONTROL_SWITCH_ACK_WAIT:-20}" 'BEGIN {printf "%.0f", now + wait + 1}')
  ready=$(cat "$(fm_pi_switch_ready_path "$state" "$task")") || return 1
  path=$(fm_pi_switch_req_path "$state" "$task")
  json=$(jq -nec --arg schema "$FM_PI_SWITCH_SCHEMA" --arg id "$req_id" \
    --arg provider "$provider" --arg model_id "$model_id" --arg effort "$effort" \
    --argjson ready "$ready" --argjson ts "$ts" --argjson deadline "$deadline" '
    if ($ready.session_id // "") == "" or ($ready.incarnation // "") == "" then error("invalid handshake") else
    {schema: $schema, id: $id, provider: $provider, model_id: $model_id,
     model: ($provider + "/" + $model_id), effort: $effort, ts: $ts, deadline: $deadline,
     session_id: $ready.session_id, incarnation: $ready.incarnation} end') || return 1
  fm_pi_switch_write_json "$path" "$json"
}

# fm_pi_switch_read_ack <state> <id> <req-id>
# Prints the ack JSON when it exists, matches the schema, and names req-id.
# Returns 1 when absent or unmatched.
fm_pi_switch_read_ack() {
  local state=$1 task=$2 req_id=$3 path json req ready
  path=$(fm_pi_switch_ack_path "$state" "$task")
  [ -f "$path" ] || return 1
  json=$(cat "$path") || return 1
  req=$(cat "$(fm_pi_switch_req_path "$state" "$task")") || return 1
  if [ -f "$(fm_pi_switch_ready_path "$state" "$task")" ]; then
    ready=$(cat "$(fm_pi_switch_ready_path "$state" "$task")") || return 1
    printf '%s' "$req" | jq -e --argjson ready "$ready" \
      '.incarnation == $ready.incarnation and .session_id == $ready.session_id' >/dev/null || return 1
  fi
  printf '%s' "$json" | jq -e --argjson req "$req" --arg schema "$FM_PI_SWITCH_SCHEMA" --arg id "$req_id" '
    type == "object"
    and .schema == $schema
    and .id == $id
    and .session_id == $req.session_id
    and .incarnation == $req.incarnation
    and ((.status | type) == "string")
  ' >/dev/null 2>&1 || return 1
  printf '%s\n' "$json"
}

fm_pi_switch_append_history() {  # <state> <id> <line>
  local log
  log=$(fm_pi_switch_log_path "$1" "$2")
  printf '%s\n' "$3" >> "$log"
}

fm_pi_switch_confirm_meta() {
  local meta=$1 model=${2:-unknown} effort=${3:-unknown} provider lock tmp rc=0
  case "$model" in */*) provider=${model%%/*} ;; *) provider=unknown ;; esac
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp=$(mktemp "${meta}.XXXXXX") || { fm_lock_release "$lock"; return 1; }
  awk -F= -v model="$model" -v effort="$effort" -v provider="$provider" '
    $1 ~ /^(model|effort|account_provider)$/ {next}
    {print}
    END {print "model=" model; print "effort=" effort; print "account_provider=" provider}
  ' "$meta" > "$tmp" && mv -f "$tmp" "$meta" || rc=1
  rm -f "$tmp"
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

fm_pi_switch_cancel() {
  local path json
  path=$(fm_pi_switch_req_path "$1" "$2")
  json=$(jq -c '.cancelled = true' "$path") || return 1
  fm_pi_switch_write_json "$path" "$json"
}

fm_pi_switch_reconcile() {
  local state=$1 task=$2 meta=$3 req ack model effort path
  path=$(fm_pi_switch_req_path "$state" "$task")
  [ -f "$path" ] || return 0
  req=$(jq -er '.id' "$path") || return 1
  ack=$(fm_pi_switch_read_ack "$state" "$task" "$req") || {
    fm_pi_switch_cancel "$state" "$task" || return 1
    fm_pi_switch_confirm_meta "$meta" unknown unknown
    echo "error: pending live-switch outcome; runtime unknown, wait for cancellation/readback before switch or relaunch" >&2
    return 1
  }
  model=$(printf '%s' "$ack" | jq -r '.model // empty')
  effort=$(printf '%s' "$ack" | jq -r '.effort // empty')
  fm_pi_switch_confirm_meta "$meta" "$model" "$effort" || return 1
  fm_pi_switch_append_history "$state" "$task" \
    "ts=$(date +%s) req=$req to=${model:-unknown}:${effort:-unknown} status=$(printf '%s' "$ack" | jq -r '.status')"
  rm -f "$path"
}

# fm_pi_switch_quota_ready <harness> <model> <provider> [confirmed-unmeasured]
# Measured exhaustion refuses (1). Unmeasured quota stays an eligible
# candidate but refuses (2) unless the supervisor passed explicit confirmation.
fm_pi_switch_quota_ready() {
  local harness=$1 model=$2 provider=$3 confirmed=${4:-0} snapshot result
  # shellcheck source=bin/fm-quota-axi-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-quota-axi-lib.sh"
  if [ -z "$provider" ]; then
    provider=$(fm_quota_single_provider_for_harness "$harness") || {
      echo "error: no authoritative quota provider for $harness; declare one on the profile" >&2
      return 1
    }
  fi
  snapshot=$(quota-axi --json 2>/dev/null) || { echo "error: quota snapshot unavailable" >&2; return 1; }
  printf '%s' "$snapshot" | fm_quota_json_valid || { echo "error: invalid quota snapshot" >&2; return 1; }
  result=$(printf '%s' "$snapshot" | jq -r --arg h "$harness" --arg m "$model" --arg p "$provider" "$FM_QUOTA_ROW_JQ"'
    quota_row(.; $p; quota_lane($h; $m)) as $row |
    [$row.quotaSemantics.effectiveAvailability[]? | select(
      .scope == "all_models" or .scope == "all_products" or
      .scope == ("model:" + ($m | split("/") | last)) or
      .scope == ("product:" + ($m | split("/") | last)))] as $bounds |
    if any($bounds[]; .runway.status == "exhausted_now" or
        (.status == "known" and .effectivePercentRemaining <= 0)) then "exhausted"
    elif ($bounds | length) == 0 or any($bounds[]; .status != "known") then "unknown"
    else "available" end') || return 1
  case "$result" in
    exhausted) echo "error: $provider quota exhausted for $model" >&2; return 1 ;;
    unknown)
      if [ "$confirmed" != 1 ]; then
        echo "error: $provider/$model quota is unmeasured; explicit supervisor confirmation required (--confirm-unmeasured-quota)" >&2
        return 2
      fi
      echo "quota: $provider/$model unmeasured; proceeding on explicit supervisor confirmation" >&2
      ;;
  esac
}

# fm_pi_switch_wait_file <path> <timeout-seconds> <poll>
fm_pi_switch_wait_file() {
  local path=$1 timeout=$2 poll=$3 elapsed=0
  while :; do
    [ -f "$path" ] && return 0
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || return 1
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
}
