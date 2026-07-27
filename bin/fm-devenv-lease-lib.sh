#!/usr/bin/env bash
# Generation-token lease primitives for one devenv marker.
#
# Public functions:
#   fm_devenv_new_token
#   fm_devenv_lease_read <marker>
#   fm_devenv_lease_claim <marker> <environment> <vm> <task-id> <branch> <issued-at>
#   fm_devenv_lease_transition <marker> <generation-token> <lease-state>
#   fm_devenv_lease_release <marker> <generation-token>
#
# A read returns 3 when the marker is absent and 4 when it exists but is not a
# valid firstmate.devenv.lease.v1 document. Mutations serialize on <marker>.lock
# and stop after FM_DEVENV_LEASE_LOCK_TIMEOUT seconds, which defaults to 5.

FM_DEVENV_LEASE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$FM_DEVENV_LEASE_LIB_DIR/fm-wake-lib.sh"

fm_devenv_new_token() {
  local bytes token
  bytes=$(LC_ALL=C od -An -N32 -tx1 /dev/urandom 2>/dev/null) || return 1
  token=$(printf '%s' "$bytes" | LC_ALL=C tr -d '[:space:]') || return 1
  printf '%s\n' "$token" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s\n' "$token"
}

fm_devenv_lease_valid_state() {
  case "$1" in
    leased|takeover|cooling|unreachable|quarantined) return 0 ;;
    *) return 1 ;;
  esac
}

fm_devenv_lease_validate() {
  jq -ce '
    if (
      type == "object"
      and keys == ["branch","environment","generation_token","issued_at","lease_state","schema","task_id","vm"]
      and .schema == "firstmate.devenv.lease.v1"
      and (.generation_token | type == "string" and test("^[0-9a-f]{64}$"))
      and (.environment | type == "string" and length > 0)
      and (.vm | type == "string" and length > 0)
      and (.task_id | type == "string" and length > 0)
      and (.branch | type == "string" and length > 0)
      and (.lease_state == "leased" or .lease_state == "takeover" or .lease_state == "cooling" or .lease_state == "unreachable" or .lease_state == "quarantined")
      and (.issued_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ) then . else error("invalid devenv lease") end
  ' "$1" 2>/dev/null
}

fm_devenv_lease_read() {
  local marker=${1:-}
  [ -n "$marker" ] || return 2
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 3
  fi
  [ -f "$marker" ] && [ -r "$marker" ] || return 4
  fm_devenv_lease_validate "$marker" || return 4
}

fm_devenv_lease_lock_acquire() {
  local lock=$1 timeout=${FM_DEVENV_LEASE_LOCK_TIMEOUT:-5} attempts
  case "$timeout" in
    ''|*[!0-9]*) return 2 ;;
  esac
  attempts=$((timeout * 10 + 1))
  while ! fm_lock_try_acquire "$lock"; do
    attempts=$((attempts - 1))
    [ "$attempts" -gt 0 ] || return 1
    sleep 0.1
  done
}

fm_devenv_lease_publish() (
  local marker=$1 json=$2 dir base tmp
  dir=$(dirname "$marker")
  base=$(basename "$marker")
  [ -d "$dir" ] && [ -w "$dir" ] || return 1
  tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX") || return 1
  trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
  chmod 0600 "$tmp" || return 1
  printf '%s\n' "$json" > "$tmp" || return 1
  fm_devenv_lease_validate "$tmp" >/dev/null || return 1
  mv -f -- "$tmp" "$marker" || return 1
  tmp=
)

fm_devenv_lease_claim() (
  [ "$#" -eq 6 ] || return 2
  local marker=$1 environment=$2 vm=$3 task_id=$4 branch=$5 issued_at=$6
  local lock token json read_status=0 lock_held=
  lock="${marker}.lock"
  trap '[ -z "$lock_held" ] || fm_lock_release "$lock"' EXIT
  fm_devenv_lease_lock_acquire "$lock" || return 1
  lock_held=1

  fm_devenv_lease_read "$marker" >/dev/null 2>&1 || read_status=$?
  case "$read_status" in
    3) ;;
    *) return 1 ;;
  esac

  token=$(fm_devenv_new_token) || return 1
  printf '%s\n' "$token" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || return 1
  json=$(jq -cn \
    --arg token "$token" \
    --arg environment "$environment" \
    --arg vm "$vm" \
    --arg task_id "$task_id" \
    --arg branch "$branch" \
    --arg issued_at "$issued_at" \
    '{
      schema:"firstmate.devenv.lease.v1",
      generation_token:$token,
      environment:$environment,
      vm:$vm,
      task_id:$task_id,
      branch:$branch,
      lease_state:"leased",
      issued_at:$issued_at
    }') || return 1
  fm_devenv_lease_publish "$marker" "$json" || return 1
  printf '%s\n' "$token"
)

fm_devenv_lease_transition() (
  [ "$#" -eq 3 ] || return 2
  local marker=$1 token=$2 next_state=$3 lock current current_token updated lock_held=
  fm_devenv_lease_valid_state "$next_state" || return 1
  lock="${marker}.lock"
  trap '[ -z "$lock_held" ] || fm_lock_release "$lock"' EXIT
  fm_devenv_lease_lock_acquire "$lock" || return 1
  lock_held=1

  current=$(fm_devenv_lease_read "$marker") || return 1
  current_token=$(printf '%s\n' "$current" | jq -r '.generation_token') || return 1
  [ "$current_token" = "$token" ] || return 1
  updated=$(printf '%s\n' "$current" | jq -c --arg state "$next_state" '.lease_state = $state') || return 1
  fm_devenv_lease_publish "$marker" "$updated"
)

fm_devenv_lease_release() (
  [ "$#" -eq 2 ] || return 2
  local marker=$1 token=$2 lock current current_token lock_held=
  lock="${marker}.lock"
  trap '[ -z "$lock_held" ] || fm_lock_release "$lock"' EXIT
  fm_devenv_lease_lock_acquire "$lock" || return 1
  lock_held=1

  current=$(fm_devenv_lease_read "$marker") || return 1
  current_token=$(printf '%s\n' "$current" | jq -r '.generation_token') || return 1
  [ "$current_token" = "$token" ] || return 1
  rm -f -- "$marker" || return 1
  [ ! -e "$marker" ] && [ ! -L "$marker" ]
)
