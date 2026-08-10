#!/usr/bin/env bash
# bin/fm-worker-isolation-lib.sh - the ONE owner of the launched-agent home
# declaration contract.
#
# A firstmate script resolves its operational home from ambient environment
# (FM_HOME, then the FM_*_OVERRIDE family, then its own FM_ROOT). That
# resolution is correct for a firstmate primary and catastrophic for a task
# child: a crewmate, scout, or audit agent launched from a primary's pane
# inherits that primary's exported FM_HOME, so every firstmate script it runs -
# including bin/fm-lock.sh - resolves the PRIMARY's state directory. A worker
# that then runs session start acquires the primary's session-owner record and
# the real primary is locked out of its own home (incident 2026-07-24).
#
# The fix is a DECLARATION, not a guess: every task child is launched with an
# explicit home environment, and declares which home owns it and in what role.
# Nothing downstream has to infer ownership from cwd, pane, or process tree.
#
#   FM_AGENT_ROLE        crewmate | secondmate  (the declared role)
#   FM_AGENT_TASK        the owning task or secondmate id
#   FM_AGENT_OWNER_HOME  absolute path of the home that launched this agent
#
# `crewmate` covers every ship/scout/audit task child. Such an agent is never a
# firstmate primary anywhere, so it must never own a home, acquire a session
# lock, or fire a primary-home hook - see fm_worker_refuse_primary_operation and
# bin/fm-primary-scope-lib.sh.
#
# `secondmate` is a primary IN ITS OWN HOME and only there, so it keeps a
# concrete FM_HOME while every inheritable override is cleared. Its own
# crewmates are launched by its own bin/fm-spawn.sh and get the crewmate
# treatment against the secondmate's home, which is what keeps a secondmate
# child from ever reaching the primary's home.
#
# The markers are also the backend-independent identity key that
# bin/fm-agent-cwd-lib.sh uses to find the real agent process, so a launch that
# omits them costs authoritative cwd proof as well as home isolation.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three.
#
# This file is sourced by scripts and hook entrypoints and has no side effects
# on source.

# Every operational-home variable a firstmate script reads. Extend here, not at
# a call site, when a new home override is introduced.
_FM_WORKER_ISOLATION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_FM_WORKER_ISOLATION_LIB_DIR/fm-process-environ-lib.sh"
FM_WORKER_ISOLATION_HOME_VARS="FM_HOME FM_ROOT FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_PENDING_REPLY_DIR_OVERRIDE STATE"
if [ "${_FM_WORKER_ISOLATION_SNAPSHOT_READY:-0}" != 1 ]; then
  _FM_WORKER_ISOLATION_SNAPSHOT_READY=1
  _FM_WORKER_INITIAL_AGENT_ROLE=${FM_AGENT_ROLE:-}
  _FM_WORKER_INITIAL_AGENT_TASK=${FM_AGENT_TASK:-}
  _FM_WORKER_INITIAL_AGENT_OWNER_HOME=${FM_AGENT_OWNER_HOME:-}
  _FM_WORKER_INITIAL_PRIMARY_ATTESTATION=${FM_PRIMARY_ATTESTATION:-}
  for _fm_worker_var in $FM_WORKER_ISOLATION_HOME_VARS; do
    printf -v "_FM_WORKER_INITIAL_${_fm_worker_var}" '%s' "${!_fm_worker_var-}"
  done
  unset _fm_worker_var
fi

fm_worker_shell_quote() {  # <text>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# fm_worker_treehouse_lease_command <task-id> [proof-file]
# Print the pane command that durably leases a pooled slot and enters it. The
# lease remains held even if the worker process exits, so only Firstmate's
# ownership-gated teardown can return and recycle the slot.
fm_worker_treehouse_lease_command() {
  local id=$1 proof=${2:-} quoted proof_quoted
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  quoted=$(fm_worker_shell_quote "$id") || return 1
  if [ -n "$proof" ]; then
    proof_quoted=$(fm_worker_shell_quote "$proof") || return 1
    printf 'fm_wt=$(treehouse get --lease --lease-holder %s) && cd -- "$fm_wt" && printf "%%s\\n" "$fm_wt" > %s && unset fm_wt' \
      "$quoted" "$proof_quoted"
  else
    printf 'fm_wt=$(treehouse get --lease --lease-holder %s) && cd -- "$fm_wt" && unset fm_wt' \
      "$quoted"
  fi
}

# fm_worker_launch_env_prefix <role> <task-id> <owner-home>
# Print the exact env-assignment prefix a launch command must carry, with one
# trailing space, so a caller composes `<prefix><launch command>`. Refuses an
# unknown role, an empty id, or a non-absolute home rather than emitting a
# partial prefix that would leave the child inheriting a home.
fm_worker_launch_env_prefix() {
  local role=$1 id=$2 home=$3 var
  case "$role" in
    crewmate|secondmate) ;;
    *) echo "error: unknown agent role '$role'; expected crewmate or secondmate" >&2; return 1 ;;
  esac
  [ -n "$id" ] || { echo "error: agent role $role requires a task id" >&2; return 1; }
  case "$home" in
    /*) ;;
    *) echo "error: agent role $role requires an absolute owning home, got '${home:-<empty>}'" >&2; return 1 ;;
  esac
  for var in $FM_WORKER_ISOLATION_HOME_VARS; do
    if [ "$var" = FM_HOME ] && [ "$role" = secondmate ]; then
      printf 'FM_HOME=%s ' "$(fm_worker_shell_quote "$home")"
    else
      printf '%s= ' "$var"
    fi
  done
  printf 'FM_PRIMARY_ATTESTATION= '
  printf 'FM_AGENT_ROLE=%s ' "$role"
  printf 'FM_AGENT_TASK=%s ' "$(fm_worker_shell_quote "$id")"
  printf 'FM_AGENT_OWNER_HOME=%s ' "$(fm_worker_shell_quote "$home")"
}

fm_worker_declaration_present() {
  [ -n "${_FM_WORKER_INITIAL_AGENT_ROLE:-}" ] \
    || [ -n "${_FM_WORKER_INITIAL_AGENT_TASK:-}" ] \
    || [ -n "${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-}" ]
}

fm_worker_canonical_path() {
  local path=${1:-}
  [ -n "$path" ] && [ -d "$path" ] || return 1
  ( cd "$path" 2>/dev/null && pwd -P )
}

fm_worker_primary_default_branch() {
  local root ref branch
  root=$1
  ref=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s' "$branch"
      return 0
    fi
  done
  return 1
}

fm_worker_paths_same() {
  local left=${1:-} right=${2:-} left_real right_real
  [ -n "$left" ] && [ -n "$right" ] || return 1
  [ "$left" = "$right" ] && return 0
  left_real=$(fm_worker_canonical_path "$left" 2>/dev/null || true)
  right_real=$(fm_worker_canonical_path "$right" 2>/dev/null || true)
  [ -n "$left_real" ] && [ "$left_real" = "$right_real" ]
}

fm_worker_process_environ() {
  fm_process_environ "$1"
}

fm_worker_process_ppid() {
  local pid=$1 ppid
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if [ -r "/proc/$pid/status" ]; then
    ppid=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)
  else
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  fi
  case "$ppid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s' "$ppid"
}

fm_worker_primary_attestation_matches() {
  local expected_root=$1 state file token content
  token=${_FM_WORKER_INITIAL_PRIMARY_ATTESTATION:-}
  [ -n "$token" ] || return 1
  state=${_FM_WORKER_INITIAL_FM_STATE_OVERRIDE:-${_FM_WORKER_INITIAL_FM_HOME:-$expected_root}/state}
  file="$state/.primary-attestation"
  [ -f "$file" ] && [ ! -L "$file" ] && [ -O "$file" ] || return 1
  content=$(cat "$file" 2>/dev/null) || return 1
  [ "$content" = "$(printf 'root=%s\ntoken=%s' "$expected_root" "$token")" ]
}

fm_worker_secondmate_home_proven() {
  local task owner home owner_real home_real marker
  task=${_FM_WORKER_INITIAL_AGENT_TASK:-}
  owner=${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-}
  home=${_FM_WORKER_INITIAL_FM_HOME:-}
  owner_real=$(fm_worker_canonical_path "$owner") || return 1
  home_real=$(fm_worker_canonical_path "$home") || return 1
  [ "$owner_real" = "$home_real" ] || return 1
  [ -f "$home_real/.fm-secondmate-home" ] || return 1
  [ ! -L "$home_real/.fm-secondmate-home" ] || return 1
  marker=$(cat "$home_real/.fm-secondmate-home" 2>/dev/null || true)
  [ "$marker" = "$task" ] || return 1
  [ -f "$home_real/AGENTS.md" ] || return 1
  [ -d "$home_real/bin" ] || return 1
  [ -d "$home_real/data" ] && [ -d "$home_real/state" ] || return 1
  [ -d "$home_real/config" ] && [ -d "$home_real/projects" ] || return 1
  return 0
}

fm_worker_secondmate_ancestry_proven() {
  local pid=${PPID:-} ppid env role task owner home found=0 depth=0
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 256 ]; do
    env=$(fm_worker_process_environ "$pid") || return 1
    role=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_ROLE=//p' | head -1)
    case "$role" in
      crewmate) return 1 ;;
      secondmate)
        task=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_TASK=//p' | head -1)
        owner=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_OWNER_HOME=//p' | head -1)
        home=$(printf '%s\n' "$env" | sed -n 's/^FM_HOME=//p' | head -1)
        [ "$task" = "${_FM_WORKER_INITIAL_AGENT_TASK:-}" ] || return 1
        fm_worker_paths_same "$owner" "${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-}" || return 1
        fm_worker_paths_same "$home" "${_FM_WORKER_INITIAL_FM_HOME:-}" || return 1
        found=1
        ;;
    esac
    ppid=$(fm_worker_process_ppid "$pid") || return 1
    [ "$ppid" != "$pid" ] || return 1
    pid=$ppid
    depth=$((depth + 1))
  done
  [ "$found" -eq 1 ] && [ "$pid" -le 1 ]
}

fm_worker_primary_ancestry_clear() {
  local pid=${BASHPID:-$$} ppid env depth=0
  while [ "$pid" -gt 1 ] && [ "$depth" -lt 256 ]; do
    env=$(fm_worker_process_environ "$pid") || return 1
    printf '%s\n' "$env" | grep -Eq '^(FM_AGENT_ROLE|FM_AGENT_TASK|FM_AGENT_OWNER_HOME)=.+$' && return 1
    ppid=$(fm_worker_process_ppid "$pid") || return 1
    [ "$ppid" != "$pid" ] || return 1
    pid=$ppid
    depth=$((depth + 1))
  done
  [ "$pid" -le 1 ]
}

fm_worker_primary_origin_proven() {
  local root home state root_real home_real state_real git_dir git_common
  local var value expected
  case "${_FM_WORKER_INITIAL_AGENT_ROLE:-}" in
    "") ;;
    *) return 1 ;;
  esac
  [ -z "${_FM_WORKER_INITIAL_AGENT_TASK:-}" ] \
    && [ -z "${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-}" ] || return 1
  root=${_FM_WORKER_INITIAL_FM_ROOT_OVERRIDE:-$(cd "$_FM_WORKER_ISOLATION_LIB_DIR/.." && pwd)}
  home=${_FM_WORKER_INITIAL_FM_HOME:-$root}
  state=${_FM_WORKER_INITIAL_FM_STATE_OVERRIDE:-$home/state}
  root_real=$(fm_worker_canonical_path "$root") || return 1
  home_real=$(fm_worker_canonical_path "$home") || return 1
  state_real=$(fm_worker_canonical_path "$state") || return 1
  [ "$state_real" = "$home_real/state" ] || return 1
  [ "$(pwd -P 2>/dev/null || true)" = "$root_real" ] || return 1
  [ ! -e "$root_real/.fm-secondmate-home" ] || return 1
  [ ! -L "$root_real/.fm-secondmate-home" ] || return 1
  fm_worker_primary_attestation_matches "$root_real" || return 1
  git_dir=$(git -C "$root_real" rev-parse --git-dir 2>/dev/null) || return 1
  git_common=$(git -C "$root_real" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$git_common" ] || return 1
  [ -f "$root_real/AGENTS.md" ] || return 1
  [ -d "$root_real/bin" ] || return 1
  [ -d "$home_real/state" ] || return 1
  [ -d "$home_real/data" ] || return 1
  [ -d "$home_real/config" ] || return 1
  fm_worker_primary_ancestry_clear "$root_real" || return 1
  for var in $FM_WORKER_ISOLATION_HOME_VARS STATE; do
    case "$var" in
      FM_HOME) expected=$home_real ;;
      FM_ROOT|FM_ROOT_OVERRIDE) expected=$root_real ;;
      FM_STATE_OVERRIDE|STATE) expected=$home_real/state ;;
      FM_DATA_OVERRIDE) expected=$home_real/data ;;
      FM_PROJECTS_OVERRIDE) expected=$home_real/projects ;;
      FM_CONFIG_OVERRIDE) expected=$home_real/config ;;
      FM_PENDING_REPLY_DIR_OVERRIDE) expected=$home_real/state/pending-replies ;;
      *) continue ;;
    esac
    case "$var" in
      FM_HOME) value=${_FM_WORKER_INITIAL_FM_HOME:-} ;;
      FM_ROOT) value=${_FM_WORKER_INITIAL_FM_ROOT:-} ;;
      FM_ROOT_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_ROOT_OVERRIDE:-} ;;
      FM_STATE_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_STATE_OVERRIDE:-} ;;
      FM_DATA_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_DATA_OVERRIDE:-} ;;
      FM_PROJECTS_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_PROJECTS_OVERRIDE:-} ;;
      FM_CONFIG_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_CONFIG_OVERRIDE:-} ;;
      FM_PENDING_REPLY_DIR_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_PENDING_REPLY_DIR_OVERRIDE:-} ;;
      STATE) value=${_FM_WORKER_INITIAL_STATE:-} ;;
    esac
    if [ -n "$value" ]; then
      fm_worker_paths_same "$value" "$expected" || return 1
    elif [ "$home_real" = "$root_real" ]; then
      continue
    fi
  done
  return 0
}

fm_worker_identity_is_complete() {
  local effective_home owner var value expected
  case "${_FM_WORKER_INITIAL_AGENT_ROLE:-}" in
    crewmate) ;;
    secondmate)
      effective_home=${_FM_WORKER_INITIAL_FM_HOME:-}
      [ -n "$effective_home" ] || return 1
      [ "$effective_home" = "${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-}" ] || return 1
      owner=${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-}
      for var in $FM_WORKER_ISOLATION_HOME_VARS; do
        case "$var" in
          FM_HOME|FM_ROOT|FM_ROOT_OVERRIDE) expected=$owner ;;
          FM_STATE_OVERRIDE) expected=$owner/state ;;
          FM_DATA_OVERRIDE) expected=$owner/data ;;
          FM_PROJECTS_OVERRIDE) expected=$owner/projects ;;
          FM_CONFIG_OVERRIDE) expected=$owner/config ;;
          FM_PENDING_REPLY_DIR_OVERRIDE) expected=$owner/state/pending-replies ;;
          STATE) expected=$owner/state ;;
          *) continue ;;
        esac
        case "$var" in
          FM_HOME) value=${_FM_WORKER_INITIAL_FM_HOME:-} ;;
          FM_ROOT) value=${_FM_WORKER_INITIAL_FM_ROOT:-} ;;
          FM_ROOT_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_ROOT_OVERRIDE:-} ;;
          FM_STATE_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_STATE_OVERRIDE:-} ;;
          FM_DATA_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_DATA_OVERRIDE:-} ;;
          FM_PROJECTS_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_PROJECTS_OVERRIDE:-} ;;
          FM_CONFIG_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_CONFIG_OVERRIDE:-} ;;
          FM_PENDING_REPLY_DIR_OVERRIDE) value=${_FM_WORKER_INITIAL_FM_PENDING_REPLY_DIR_OVERRIDE:-} ;;
          STATE) value=${_FM_WORKER_INITIAL_STATE:-} ;;
        esac
        [ -z "$value" ] || [ "$value" = "$expected" ] || return 1
      done
      ;;
    *) return 1 ;;
  esac
  [ -n "${_FM_WORKER_INITIAL_AGENT_TASK:-}" ] || return 1
  case "${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-}" in
    /*) ;;
    *) return 1 ;;
  esac
  return 0
}

# fm_worker_is_task_worker: 0 unless this process has a complete secondmate
# identity or a proven primary origin.
fm_worker_is_task_worker() {
  if [ "${_FM_WORKER_INITIAL_AGENT_ROLE:-}" = secondmate ] \
    && fm_worker_identity_is_complete \
    && fm_worker_secondmate_home_proven \
    && fm_worker_secondmate_ancestry_proven; then
    return 1
  fi
  if fm_worker_primary_origin_proven; then
    return 1
  fi
  return 0
}

# fm_worker_refuse_primary_operation <operation>
# Fail closed with one actionable line when a declared task worker attempts an
# operation only a home's primary may perform. Silent and successful for every
# other process, so a call site can guard unconditionally.
fm_worker_refuse_primary_operation() {
  local operation=$1
  fm_worker_is_task_worker || return 0
  echo "error: $operation refused: this process is task worker '${_FM_WORKER_INITIAL_AGENT_TASK:-unnamed}' launched by ${_FM_WORKER_INITIAL_AGENT_OWNER_HOME:-an unrecorded home}; a task worker never owns a firstmate operational home" >&2
  return 1
}
