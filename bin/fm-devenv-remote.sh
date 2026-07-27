#!/usr/bin/env bash
# fm-devenv-remote.sh - one-request helper for firstmate.devenv.v1.
#
# Reads exactly one bounded JSON request from stdin and writes exactly one JSON
# response. Supported operations are inspect, claim, status, and release. The
# environment state lives at ~/.local/state/firstmate-expanly/<environment>.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-devenv-lib.sh
. "$SCRIPT_DIR/fm-devenv-lib.sh"
# shellcheck source=bin/fm-devenv-lease-lib.sh
. "$SCRIPT_DIR/fm-devenv-lease-lib.sh"

PROTOCOL_SCHEMA=firstmate.devenv.v1
MAX_REQUEST_BYTES=65536
UNKNOWN_REQUEST_ID=00000000000000000000000000000000
request_id=$UNKNOWN_REQUEST_ID
request_file=

remote_error() {
  jq -cn \
    --arg schema "$PROTOCOL_SCHEMA" \
    --arg request_id "$request_id" \
    --arg code "$1" \
    --arg message "$2" \
    '{schema:$schema,request_id:$request_id,ok:false,result:null,error:{code:$code,message:$message}}'
  exit 0
}

remote_success() {
  jq -cn \
    --arg schema "$PROTOCOL_SCHEMA" \
    --arg request_id "$request_id" \
    --argjson result "$1" \
    '{schema:$schema,request_id:$request_id,ok:true,result:$result,error:null}'
  exit 0
}

request_file=$(mktemp "${TMPDIR:-/tmp}/fm-devenv-request.XXXXXX") \
  || remote_error internal_error 'could not read request'
trap 'rm -f -- "$request_file"' EXIT
LC_ALL=C head -c "$((MAX_REQUEST_BYTES + 1))" > "$request_file" \
  || remote_error invalid_request 'could not read request'
request_bytes=$(LC_ALL=C wc -c < "$request_file" | tr -d '[:space:]') \
  || remote_error invalid_request 'could not read request'
[ "$request_bytes" -le "$MAX_REQUEST_BYTES" ] \
  || remote_error invalid_request 'request exceeds byte limit'

candidate_id=$(jq -er -s '
  if (
    length == 1
    and (.[0] | type == "object")
    and (.[0].request_id | type == "string" and test("^[0-9a-f]{32}$"))
  ) then .[0].request_id else error("invalid request id") end
' "$request_file" 2>/dev/null) || candidate_id=
[ -z "$candidate_id" ] || request_id=$candidate_id

request=$(jq -ce -s '
  if (
    length == 1
    and (.[0] | type == "object")
    and (.[0] | keys == ["environment","lease","operation","payload","request_id","schema","vm"])
    and .[0].schema == "firstmate.devenv.v1"
    and (.[0].request_id | type == "string" and test("^[0-9a-f]{32}$"))
    and (.[0].operation | type == "string")
    and (.[0].environment | type == "string" and test("^[A-Za-z0-9_-]+$"))
    and (.[0].vm | type == "string" and test("^expanly-[A-Za-z0-9_-]+$"))
    and (.[0].payload | type == "object")
  ) then .[0] else error("invalid request") end
' "$request_file" 2>/dev/null) || remote_error invalid_request 'invalid request envelope'

operation=$(printf '%s\n' "$request" | jq -r '.operation') \
  || remote_error invalid_request 'invalid operation'
environment=$(printf '%s\n' "$request" | jq -r '.environment') \
  || remote_error invalid_request 'invalid environment'
vm=$(printf '%s\n' "$request" | jq -r '.vm') \
  || remote_error invalid_request 'invalid VM'
state_dir="$HOME/.local/state/firstmate-expanly/$environment"
marker="$state_dir/lease.json"

case "$operation" in
  inspect|claim|status|release) ;;
  *) remote_error unknown_operation 'unknown operation' ;;
esac

[ -d "$state_dir" ] && [ ! -L "$state_dir" ] \
  || remote_error identity_mismatch 'environment is not installed on this VM'
local_vm=$(hostname -s 2>/dev/null) \
  || remote_error identity_mismatch 'could not identify this VM'
[ "$local_vm" = "$vm" ] \
  || remote_error identity_mismatch 'request VM does not match this VM'

runtime_version=
runtime_marker="$SCRIPT_DIR/../.firstmate-runtime-commit"
if [ -f "$runtime_marker" ]; then
  runtime_version=$(LC_ALL=C head -c 65 "$runtime_marker" | tr -d '\r\n')
  case "$runtime_version" in
    *[!0-9a-f]*) runtime_version= ;;
  esac
  if [ "${#runtime_version}" -ne 40 ] && [ "${#runtime_version}" -ne 64 ]; then
    runtime_version=
  fi
fi

remote_lease_summary() {
  local lease=$1
  printf '%s\n' "$lease" | jq -ce '
    if (
      (.environment | length <= 64)
      and (.vm | length <= 128)
      and (.task_id | length <= 128)
      and (.branch | length <= 256)
      and (.lease_state | length <= 32)
      and (.issued_at | length <= 20)
    ) then del(.schema, .generation_token) else error("unbounded lease") end
  ' 2>/dev/null
}

# herdr_session_present is scoped to the explicit firstmate-expanly-<environment>
# session. agent_present stays null because that one session cannot prove the
# absence of a human or agent working in any other session; the resident process
# classifier supplies that fact later.
remote_result() {
  local lease_summary=$1 branch='' clean=null sessions session_present=null
  if git -C "$HOME/expanly-platform" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$HOME/expanly-platform" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
    [ "${#branch}" -le 256 ] || branch=
    if git -C "$HOME/expanly-platform" diff --quiet -- \
      && git -C "$HOME/expanly-platform" diff --cached --quiet -- \
      && [ -z "$(git -C "$HOME/expanly-platform" ls-files --others --exclude-standard | head -1)" ]; then
      clean=true
    else
      clean=false
    fi
  fi
  if command -v herdr >/dev/null 2>&1; then
    sessions=$(herdr session list --json 2>/dev/null | LC_ALL=C head -c 65537)
    if [ "$(printf '%s' "$sessions" | LC_ALL=C wc -c | tr -d '[:space:]')" -le 65536 ] \
      && printf '%s' "$sessions" | jq -e '.sessions | type == "array"' >/dev/null 2>&1; then
      if printf '%s' "$sessions" | jq -e --arg name "firstmate-expanly-$environment" \
        '.sessions[]? | select(.name == $name and .running == true)' >/dev/null 2>&1; then
        session_present=true
      else
        session_present=false
      fi
    fi
  fi
  jq -cn \
    --arg runtime_version "$runtime_version" \
    --arg branch "$branch" \
    --argjson lease "$lease_summary" \
    --argjson clean "$clean" \
    --argjson session_present "$session_present" \
    '{
      runtime_version:(if $runtime_version == "" then null else $runtime_version end),
      lease:$lease,
      git:{branch:(if $branch == "" then null else $branch end),clean:$clean},
      agent_present:null,
      herdr_session_present:$session_present
    }'
}

payload_is_empty=$(printf '%s\n' "$request" | jq -e '.payload | keys == []' 2>/dev/null) \
  || remote_error invalid_payload 'payload must be an empty object'
[ "$payload_is_empty" = true ] || remote_error invalid_payload 'payload must be an empty object'

case "$operation" in
  inspect)
    printf '%s\n' "$request" | jq -e '.lease == null' >/dev/null 2>&1 \
      || remote_error invalid_lease 'inspect requires a null lease'
    read_status=0
    current=$(fm_devenv_lease_read "$marker" 2>/dev/null) || read_status=$?
    case "$read_status" in
      0)
        current_environment=$(printf '%s\n' "$current" | jq -r '.environment')
        current_vm=$(printf '%s\n' "$current" | jq -r '.vm')
        [ "$current_environment" = "$environment" ] && [ "$current_vm" = "$vm" ] \
          || remote_error identity_mismatch 'local lease identity does not match request'
        lease_summary=$(remote_lease_summary "$current") \
          || remote_error invalid_local_state 'local lease marker exceeds response limits'
        ;;
      3) lease_summary=null ;;
      *) remote_error invalid_local_state 'local lease marker is malformed' ;;
    esac
    remote_success "$(remote_result "$lease_summary")"
    ;;
  claim)
    lease_file=$(mktemp "${TMPDIR:-/tmp}/fm-devenv-claim.XXXXXX") \
      || remote_error internal_error 'could not validate lease'
    trap 'rm -f -- "$request_file" "$lease_file"' EXIT
    printf '%s\n' "$request" | jq -c '.lease' > "$lease_file" \
      || remote_error invalid_lease 'claim requires a valid lease'
    requested_lease=$(fm_devenv_lease_validate "$lease_file") \
      || remote_error invalid_lease 'claim requires a valid lease'
    remote_lease_summary "$requested_lease" >/dev/null \
      || remote_error invalid_lease 'claim lease exceeds field limits'
    printf '%s\n' "$requested_lease" | jq -e \
      --arg environment "$environment" --arg vm "$vm" \
      '.environment == $environment and .vm == $vm and .lease_state == "leased"' >/dev/null \
      || remote_error identity_mismatch 'claim lease identity does not match request'
    claim_token=$(printf '%s\n' "$requested_lease" | jq -r '.generation_token')
    claim_task=$(printf '%s\n' "$requested_lease" | jq -r '.task_id')
    claim_branch=$(printf '%s\n' "$requested_lease" | jq -r '.branch')
    claim_issued_at=$(printf '%s\n' "$requested_lease" | jq -r '.issued_at')
    fm_devenv_new_token() { printf '%s\n' "$claim_token"; }
    published_token=$(fm_devenv_lease_claim \
      "$marker" "$environment" "$vm" "$claim_task" "$claim_branch" "$claim_issued_at") \
      || remote_error claim_refused 'environment already has a lease or cannot be claimed'
    [ "$published_token" = "$claim_token" ] \
      || remote_error claim_refused 'published lease token did not match request'
    current=$(fm_devenv_lease_read "$marker") \
      || remote_error invalid_local_state 'published lease is unreadable'
    current_token=$(printf '%s\n' "$current" | jq -r '.generation_token')
    [ "$current_token" = "$claim_token" ] \
      || remote_error invalid_local_state 'published lease token does not match request'
    lease_summary=$(remote_lease_summary "$current") \
      || remote_error invalid_local_state 'published lease exceeds response limits'
    remote_success "$(remote_result "$lease_summary")"
    ;;
  status|release)
    token=$(printf '%s\n' "$request" | jq -er '
      if (
        (.lease | type == "object")
        and (.lease | keys == ["generation_token"])
        and (.lease.generation_token | type == "string" and test("^[0-9a-f]{64}$"))
      ) then .lease.generation_token else error("invalid token") end
    ' 2>/dev/null) || remote_error invalid_lease "$operation requires one generation token"
    current=$(fm_devenv_lease_read "$marker") \
      || remote_error invalid_local_state 'local lease marker is missing or malformed'
    current_token=$(printf '%s\n' "$current" | jq -r '.generation_token')
    current_environment=$(printf '%s\n' "$current" | jq -r '.environment')
    current_vm=$(printf '%s\n' "$current" | jq -r '.vm')
    [ "$current_environment" = "$environment" ] && [ "$current_vm" = "$vm" ] \
      || remote_error identity_mismatch 'local lease identity does not match request'
    [ "$current_token" = "$token" ] \
      || remote_error stale_token 'generation token does not match current lease'
    if [ "$operation" = status ]; then
      lease_summary=$(remote_lease_summary "$current") \
        || remote_error invalid_local_state 'local lease marker exceeds response limits'
      remote_success "$(remote_result "$lease_summary")"
    fi
    fm_devenv_lease_release "$marker" "$token" \
      || remote_error release_refused 'lease changed before release'
    remote_success "$(remote_result null)"
    ;;
esac
