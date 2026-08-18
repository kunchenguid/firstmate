#!/usr/bin/env bash
# Own the durable two-phase approval record for a material software ship task.
# Usage:
#   fm-ship-end-to-end.sh publish-direct <task-id> --contract-file <path>
#   fm-ship-end-to-end.sh approve-direct <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh verify <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh verify-current <task-id>
#   fm-ship-end-to-end.sh verify-dispatched <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh verify-recovery <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh validate <task-id>
#
# The record is data/<task-id>/ship-preflight.json, mode 0600. Its schema is
# `{schema_version,workflow,task_id,fingerprint,origin,state,contract,producer_revision,created_at|approval}`.
# Records require a positive integer producer_revision that advances each bridge publication.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NOW=${FM_SHIP_PREFLIGHT_NOW:-$(date +%s)}
MAX_AGE=${FM_SHIP_PREFLIGHT_MAX_AGE:-86400}
# shellcheck source=bin/fm-ship-preflight-lib.sh
. "$SCRIPT_DIR/fm-ship-preflight-lib.sh"

usage() { sed -n '2,10p' "$0" | sed -e 's/^#$//' -e 's/^# //'; }
die() { echo "fm-ship-end-to-end: $*" >&2; exit 1; }
sha256_text() { if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'; else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
links_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %l "$1"; else stat -c %h "$1"; fi; }
owner_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %u "$1"; else stat -c %u "$1"; fi; }
valid_private() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ] && [ "$(links_of "$1" 2>/dev/null || true)" = 1 ]; }
valid_data_dir() {
  local path=$1 mode owner group other
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  owner=$(owner_of "$path" 2>/dev/null || true)
  [ "$owner" = "$(id -u)" ] || return 1
  mode=$(mode_of "$path" 2>/dev/null || true)
  case "$mode" in [0-7][0-7][0-7]) ;; *) return 1 ;; esac
  group=${mode#?}; group=${group%?}
  other=${mode#??}
  case "$group$other" in *[2367]*) return 1 ;; esac
}
valid_private_dir() {
  local path=$1 mode
  valid_data_dir "$path" || return 1
  mode=$(mode_of "$path" 2>/dev/null || true)
  case "$mode" in [0-7]00) ;; *) return 1 ;; esac
}
valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
valid_fingerprint() { case "$1" in ????????*) [ "${#1}" -eq 64 ] && ! printf '%s' "$1" | grep -q '[^0-9a-f]' ;; *) return 1;; esac; }

COMMAND=${1:-}
case "$COMMAND" in publish-direct|approve-direct|verify|verify-current|verify-dispatched|verify-recovery|validate) shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac
ID=${1:-}; shift || true
valid_id "$ID" || die "unsafe task id"
case "$NOW" in ''|*[!0-9]*) die "FM_SHIP_PREFLIGHT_NOW must be an epoch";; esac
case "$MAX_AGE" in ''|*[!0-9]*|0) die "FM_SHIP_PREFLIGHT_MAX_AGE must be a positive integer";; esac
fm_ship_preflight_validate_limit || die "FM_SHIP_PREFLIGHT_MAX_BYTES must be a positive integer no greater than 1048576"

FINGERPRINT=''
CONTRACT_FILE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fingerprint)
      key=${1#--}; shift; [ "$#" -gt 0 ] || die "--$key needs a value"
      case "$key" in
        fingerprint) FINGERPRINT=$1;;
      esac
      ;;
    --contract-file)
      shift; [ "$#" -gt 0 ] || die "--contract-file needs a value"
      CONTRACT_FILE=$1
      ;;
    *) usage >&2; exit 2;;
  esac
  shift
done

REC_DIR="$DATA/$ID"
RECORD="$REC_DIR/ship-preflight.json"
DIRECT_LOCK=
DIRECT_LOCK_HELD=0
DIRECT_CONTRACT_TMP=

contract_valid() {
  jq -e '
    type == "object" and
    (. as $contract | ["recommendation","outcome","scope","non_goals","delivery_boundary","external_boundaries","questions"] | all(.[]; . as $k | $contract | has($k))) and
    (.recommendation | type == "string" and length > 0) and
    (.outcome | type == "string" and length > 0) and
    (.scope | type == "string" and length > 0) and
    (.non_goals | type == "string") and
    (.delivery_boundary | type == "string" and length > 0) and
    (.external_boundaries | type == "string" and length > 0) and
    (.questions | type == "array" and all(.[]; type == "string" and length > 0))
  ' "${1:--}" >/dev/null
}
contract_boundary_is_pr_only() {
  jq -e '.delivery_boundary == "pr-only"' "${1:--}" >/dev/null
}
preflight_fingerprint() {
  local contract=$1 bound
  bound=$(jq -cn --arg id "$ID" --argjson contract "$contract" '{task_id:$id,contract:$contract}' | jq -cS .) || return 1
  sha256_text "$bound"
}
prepare_record_dir() {
  if [ -e "$DATA" ] || [ -L "$DATA" ]; then
    valid_data_dir "$DATA" || die "unsafe task record directory"
  else
    (umask 077; mkdir -p "$DATA") || die "could not create task record directory"
    valid_data_dir "$DATA" || die "unsafe task record directory"
  fi
  if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
    valid_private_dir "$REC_DIR" || die "unsafe task record directory"
  else
    (umask 077; mkdir "$REC_DIR") || die "could not create task record directory"
    valid_private_dir "$REC_DIR" || die "unsafe task record directory"
  fi
}
require_record_dir() {
  if ! { [ -e "$DATA" ] || [ -L "$DATA" ]; }; then
    die "no valid private preflight record"
  fi
  valid_data_dir "$DATA" || die "unsafe task record directory"
  if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
    valid_private_dir "$REC_DIR" || die "unsafe task record directory"
  else
    die "no valid private preflight record"
  fi
}
release_direct_lock() {
  local status=$?
  trap - EXIT
  if [ "$DIRECT_LOCK_HELD" = 1 ]; then
    DIRECT_LOCK_HELD=0
    fm_lock_release "$DIRECT_LOCK" || true
  fi
  [ -z "$DIRECT_CONTRACT_TMP" ] || rm -f -- "$DIRECT_CONTRACT_TMP" || true
  exit "$status"
}
acquire_direct_lock() {
  STATE="$REC_DIR" FM_STATE_OVERRIDE="$REC_DIR" . "$SCRIPT_DIR/fm-wake-lib.sh"
  DIRECT_LOCK="$REC_DIR/.ship-preflight.lock"
  fm_lock_acquire_wait "$DIRECT_LOCK" || die "could not lock preflight record"
  DIRECT_LOCK_HELD=1
  trap release_direct_lock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
next_producer_revision() {
  if [ -e "$RECORD" ] || [ -L "$RECORD" ]; then
    read_record
    jq -r '.producer_revision + 1' "$RECORD"
  else
    printf '1\n'
  fi
}
publish_direct_record() {
  local contract=$1 state=$2 revision=$3 bypass=$4 approval tmp record
  case "$revision" in ''|*[!0-9]*) die "preflight producer revision is malformed";; esac
  [ "$revision" -le 9007199254740991 ] || die "preflight producer revision is malformed"
  case "$bypass" in true|false) ;; *) die "direct approval bypass state is malformed";; esac
  preflight_fingerprint "$contract" >/dev/null || die "could not fingerprint direct preflight"
  FINGERPRINT=$(preflight_fingerprint "$contract")
  if [ "$state" = approved ]; then
    approval=$(jq -cn --argjson now "$NOW" --argjson bypass "$bypass" '{authority:"direct-captain",evidence:"direct-captain",approved_at:$now,complete_plan_bypass:$bypass}') || die "could not create direct approval"
    record=$(jq -cn --arg id "$ID" --arg fp "$FINGERPRINT" --argjson contract "$contract" --argjson revision "$revision" --argjson approval "$approval" '{schema_version:1,workflow:"ship-end-to-end",task_id:$id,fingerprint:$fp,origin:"direct",state:"approved",contract:$contract,producer_revision:$revision,approval:$approval}') || die "could not create direct preflight"
  else
    record=$(jq -cn --arg id "$ID" --arg fp "$FINGERPRINT" --argjson contract "$contract" --argjson revision "$revision" --argjson now "$NOW" '{schema_version:1,workflow:"ship-end-to-end",task_id:$id,fingerprint:$fp,origin:"direct",state:"awaiting_approval",contract:$contract,producer_revision:$revision,created_at:$now}') || die "could not create direct preflight"
  fi
  tmp=$(umask 077; mktemp "$REC_DIR/.ship-preflight.XXXXXX") || die "could not prepare direct preflight"
  if ! printf '%s\n' "$record" > "$tmp" || ! chmod 600 "$tmp" || ! valid_private "$tmp"; then
    rm -f -- "$tmp"
    die "could not prepare direct preflight"
  fi
  if ! fm_ship_preflight_within_limit "$tmp"; then
    rm -f -- "$tmp"
    die "direct preflight record exceeds the bounded size"
  fi
  mv -f -- "$tmp" "$RECORD" || die "could not publish direct preflight"
  read_record
}
read_record() {
  local record_contract
  if ! { [ -e "$DATA" ] || [ -L "$DATA" ]; }; then
    die "no valid private preflight record"
  fi
  valid_data_dir "$DATA" || die "unsafe task record directory"
  if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
    valid_private_dir "$REC_DIR" || die "unsafe task record directory"
  else
    die "no valid private preflight record"
  fi
  valid_private "$RECORD" || die "no valid private preflight record"
  fm_ship_preflight_within_limit "$RECORD" || die "preflight record exceeds the bounded size"
  jq -e --arg id "$ID" '
    .schema_version == 1 and
    .workflow == "ship-end-to-end" and
    .task_id == $id and
    (.fingerprint | type == "string" and test("^[0-9a-f]{64}$")) and
    (.origin == "direct" or .origin == "bridge") and
    (.state == "awaiting_approval" or .state == "approved") and
    (.contract | type == "object") and
    (.producer_revision | type == "number" and floor == . and . >= 1 and . <= 9007199254740991)
  ' "$RECORD" >/dev/null || die "malformed preflight record"
  record_contract=$(jq -cS '.contract' "$RECORD") || die "malformed preflight contract"
  printf '%s\n' "$record_contract" | contract_valid || die "malformed preflight contract"
  printf '%s\n' "$record_contract" | contract_boundary_is_pr_only || die "delivery boundary must be pr-only"
  [ "$(preflight_fingerprint "$record_contract")" = "$(jq -r '.fingerprint' "$RECORD")" ] || die "preflight record fingerprint does not match its contract"
}
verify_record() {
  local fingerprint=$1 require_fresh=${2:-1} bypass approved_at
  [ "$(jq -r '.state' "$RECORD")" = approved ] || die "preflight approval is missing"
  [ "$(jq -r '.fingerprint' "$RECORD")" = "$fingerprint" ] || die "preflight fingerprint does not match the approved contract"
  jq -e '
    (.approval | type == "object") and
    (.approval.approved_at | type == "number") and
    (.approval.complete_plan_bypass | type == "boolean") and
    ((.origin == "direct" and .approval.authority == "direct-captain" and .approval.evidence == "direct-captain") or
     (.origin == "bridge" and .approval.authority == "agent-bridge" and .approval.evidence == "bridge-submission"))
  ' "$RECORD" >/dev/null || die "preflight lacks typed approval authority evidence"
  bypass=$(jq -r 'if (.approval | has("complete_plan_bypass")) then .approval.complete_plan_bypass else "" end' "$RECORD")
  case "$bypass" in
    true) jq -e '.contract.complete_plan_approved == true and (.contract.questions | length == 0)' "$RECORD" >/dev/null || die "approved-complete-plan record has unresolved questions" ;;
    false) ;;
    *) die "approval bypass state is malformed" ;;
  esac
  approved_at=$(jq -r '.approval.approved_at // 0' "$RECORD")
  case "$approved_at" in ''|*[!0-9]*) die "approval timestamp is malformed";; esac
  [ "$approved_at" -le "$NOW" ] || die "preflight approval timestamp is in the future"
  [ "$require_fresh" = 0 ] || [ $((NOW - approved_at)) -le "$MAX_AGE" ] || die "preflight approval is stale"
}

case "$COMMAND" in
  publish-direct)
    [ -n "$CONTRACT_FILE" ] || die "--contract-file is required"
    [ -f "$CONTRACT_FILE" ] && [ ! -L "$CONTRACT_FILE" ] || die "contract file is unsafe"
    prepare_record_dir
    acquire_direct_lock
    DIRECT_CONTRACT_TMP=$(umask 077; mktemp "$REC_DIR/.ship-contract.XXXXXX") || die "could not prepare direct contract"
    if ! fm_ship_preflight_copy_bounded_file "$CONTRACT_FILE" "$DIRECT_CONTRACT_TMP" || ! chmod 600 "$DIRECT_CONTRACT_TMP" || ! valid_private "$DIRECT_CONTRACT_TMP"; then
      die "preflight input exceeds the bounded size"
    fi
    CONTRACT=$(jq -cS . "$DIRECT_CONTRACT_TMP") || die "malformed preflight contract"
    rm -f -- "$DIRECT_CONTRACT_TMP" || die "could not remove direct contract"
    DIRECT_CONTRACT_TMP=
    printf '%s\n' "$CONTRACT" | contract_valid || die "malformed preflight contract"
    printf '%s\n' "$CONTRACT" | contract_boundary_is_pr_only || die "delivery boundary must be pr-only"
    REVISION=$(next_producer_revision)
    if printf '%s\n' "$CONTRACT" | jq -e '.complete_plan_approved == true and (.questions | length == 0)' >/dev/null; then
      publish_direct_record "$CONTRACT" approved "$REVISION" true
    else
      publish_direct_record "$CONTRACT" awaiting_approval "$REVISION" false
    fi
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    ;;
  approve-direct)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    require_record_dir
    acquire_direct_lock
    read_record
    [ "$(jq -r '.origin' "$RECORD")" = direct ] || die "direct approval requires a direct preflight"
    [ "$(jq -r '.state' "$RECORD")" = awaiting_approval ] || die "direct preflight is not awaiting approval"
    [ "$(jq -r '.fingerprint' "$RECORD")" = "$FINGERPRINT" ] || die "preflight fingerprint does not match the awaiting contract"
    CONTRACT=$(jq -cS '.contract' "$RECORD") || die "malformed preflight contract"
    REVISION=$(next_producer_revision)
    publish_direct_record "$CONTRACT" approved "$REVISION" false
    printf 'approved\n'
    ;;
  validate)
    read_record
    if [ "$(jq -r '.state' "$RECORD")" = approved ]; then
      verify_record "$(jq -r '.fingerprint' "$RECORD")" 0
    else
      jq -e '.created_at | type == "number" and . >= 0' "$RECORD" >/dev/null || die "preflight creation timestamp is malformed"
    fi
    ;;
  verify)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    verify_record "$FINGERPRINT"
    printf 'approved\n'
    ;;
  verify-current)
    read_record
    FINGERPRINT=$(jq -r '.fingerprint' "$RECORD")
    verify_record "$FINGERPRINT"
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    ;;
  verify-dispatched)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    verify_record "$FINGERPRINT"
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    ;;
  verify-recovery)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    if [ "$(jq -r '.state' "$RECORD")" = awaiting_approval ]; then
      exit 4
    fi
    verify_record "$FINGERPRINT"
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    ;;
esac
