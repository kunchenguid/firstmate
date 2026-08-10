#!/usr/bin/env bash
# Check the Linux AI-workspace toolchain for stable upgrades and, in an
# interactive terminal, offer each safe upgrade separately.
#
# This command is advisory unless the operator answers yes to an individual
# prompt. It never upgrades in a non-interactive shell, never batches consent,
# and never edits GitHub Actions: checkout major-version drift is reported as
# repository PR work. Lifecycle-sensitive runtimes are deferred while their
# processes/sessions are active. Firstmate updates use fm-update.sh's guarded,
# fast-forward-only path and run last so this script cannot change underneath
# the remaining checks.
#
# Linux package policy:
#   - Debian/Ubuntu packages are compared with the locally cached APT candidate
#     and upgraded with apt-get. This script does not refresh package indexes.
#   - NVM-managed Node stays on its installed major line; patch/minor upgrades
#     reinstall that version's global packages and update the default alias.
#   - Self-updating CLIs keep their upstream guarded update commands.
#   - macOS-only cmux and moshi-hook checks are intentionally absent.
#
# Usage: fm-deps.sh [--check]
#   --check  Check and report only; do not prompt.
#
# Test seams:
#   FM_DEPS_INTERACTIVE=1|0 overrides terminal detection when source-only.
#   FM_DEPS_PROBE_TIMEOUT bounds each read-only dependency probe.
#   FM_DEPS_LOCK_TIMEOUT bounds checker ownership acquisition.
#   FM_DEPS_HOST_LOCK_DIR overrides the private firstmate-deps-$UID lock directory.
#   FM_ROOT_OVERRIDE points at an isolated Firstmate fixture.
#   FM_DEPS_HERDR_MANIFEST_URL and FM_DEPS_NODE_INDEX_URL override release data.
#   FM_DEPS_NVM_DIR points at an isolated NVM fixture.
set -u

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}"
CHECK_ONLY=0
FAILURES=0
UPDATES=0
DEFERRED=0
AVAILABLE=0
FIRSTMATE_UPDATE_RESULT=""
HERDR_MANIFEST_URL=${FM_DEPS_HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}
NODE_INDEX_URL=${FM_DEPS_NODE_INDEX_URL:-https://nodejs.org/dist/index.json}
_FM_DEPS_ACTION_LOCK_HELD=0
_FM_DEPS_LOADED_SOURCE_ONLY=${FM_DEPS_SOURCE_ONLY:-0}

# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-update-action-lib.sh
. "$SCRIPT_DIR/fm-update-action-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  echo "usage: fm-deps.sh [--check]" >&2
}

case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 1 ;;
esac
[ "$#" -le 1 ] || { usage; exit 1; }

is_interactive() {
  if [ "${FM_DEPS_SOURCE_ONLY:-0}" = 1 ]; then
    case "${FM_DEPS_INTERACTIVE:-}" in
      1) return 0 ;;
      0) return 1 ;;
    esac
  fi
  [ -t 0 ] && [ -t 1 ]
}

positive_integer_is_valid() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *[1-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

probe_timeout_is_valid() {
  positive_integer_is_valid "${FM_DEPS_PROBE_TIMEOUT:-30}"
}

run_probe() {
  local bound=${FM_DEPS_PROBE_TIMEOUT:-30}
  probe_timeout_is_valid || return 124
  fm_run_timed "$bound" "$@"
}

run_git_probe() {
  run_probe env GIT_TERMINAL_PROMPT=0 git "$@"
}

first_version() {
  sed -nE 's/^[^0-9]*[vV]?([0-9]+([.][0-9A-Za-z]+)+).*/\1/p' | head -n 1
}

normalize_version() {
  sed -E 's/^[^0-9]*//; s/[^0-9A-Za-z.+:~-].*$//'
}

version_is_older() {
  local installed latest
  installed=$(printf '%s\n' "$1" | normalize_version)
  latest=$(printf '%s\n' "$2" | normalize_version)
  command -v dpkg >/dev/null 2>&1 || return 1
  dpkg --compare-versions "$installed" lt "$latest"
}

command_version() {
  local command_name=$1 out
  command -v "$command_name" >/dev/null 2>&1 || return 1
  out=$(run_probe "$command_name" --version 2>&1) || return 1
  printf '%s\n' "$out" | first_version
}

apt_package_versions() {
  local package=$1 installed candidate installed_out candidate_out installed_status=0
  command -v dpkg-query >/dev/null 2>&1 || return 1
  command -v apt-cache >/dev/null 2>&1 || return 1
  installed_out=$(run_probe dpkg-query -W -f='${Status}\t${Version}\n' "$package" 2>/dev/null) \
    || installed_status=$?
  case "$installed_status" in
    0) ;;
    1) installed_out="" ;;
    *) return 1 ;;
  esac
  installed=$(printf '%s\n' "$installed_out" \
    | awk -F '\t' '$1 == "install ok installed" {print $2; exit}')
  candidate_out=$(run_probe apt-cache policy "$package" 2>/dev/null) || return 1
  candidate=$(printf '%s\n' "$candidate_out" \
    | sed -nE 's/^[[:space:]]*Candidate:[[:space:]]*([^[:space:]]+).*/\1/p' \
    | head -n 1)
  [ "$candidate" != '(none)' ] || candidate=""
  printf '%s\t%s\n' "$installed" "$candidate"
}

npm_latest() {
  local out
  command -v npm >/dev/null 2>&1 || return 1
  out=$(run_probe npm view "$1" version 2>/dev/null) || return 1
  printf '%s\n' "$out" | head -n 1
}

release_latest() {
  local repo=$1 out
  command -v gh-axi >/dev/null 2>&1 || return 1
  out=$(run_probe gh-axi release list --repo "$repo" --exclude-drafts \
    --exclude-pre-releases --limit 1 2>/dev/null) || return 1
  printf '%s\n' "$out" \
    | sed -nE 's/^[[:space:]]+([^,[:space:]]+),.*/\1/p' \
    | head -n 1 \
    | normalize_version
}

json_url() {
  command -v curl >/dev/null 2>&1 || return 1
  run_probe curl -fsSL --connect-timeout 10 --max-time 30 "$1"
}

herdr_latest() {
  local out
  command -v jq >/dev/null 2>&1 || return 1
  out=$(json_url "$HERDR_MANIFEST_URL") || return 1
  printf '%s\n' "$out" \
    | jq -er '.version | select(type == "string" and length > 0)' 2>/dev/null
}

node_latest_same_major() {
  local installed=$1 major out
  command -v jq >/dev/null 2>&1 || return 1
  major=${installed#v}
  major=${major%%.*}
  out=$(json_url "$NODE_INDEX_URL") || return 1
  printf '%s\n' "$out" | jq -er --arg major "$major" '
    first(
      .[]
      | select(.lts != false)
      | .version | ltrimstr("v")
      | select(split(".")[0] == $major)
    )
  ' 2>/dev/null
}

prompt_yes() {
  local label=$1 reply
  [ "$CHECK_ONLY" -eq 0 ] && is_interactive || return 1
  printf 'Upgrade %s now? [y/N] ' "$label"
  IFS= read -r reply || reply=""
  case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

process_active() {
  local status
  command -v pgrep >/dev/null 2>&1 || return 2
  run_probe pgrep -x "$1" >/dev/null 2>&1
  status=$?
  case "$status" in
    0|1) return "$status" ;;
    *) return 2 ;;
  esac
}

quiet_process_blocker() {
  local process_name=$1 active_message=$2 status
  process_active "$process_name"
  status=$?
  case "$status" in
    0) printf '%s' "$active_message"; return 0 ;;
    1) return 1 ;;
    *) printf 'Cannot confirm quiet window because pgrep failed for %s' "$process_name"; return 2 ;;
  esac
}

quiet_window_blocker() {
  local out running status
  case "$1" in
    codex)
      quiet_process_blocker codex 'Codex process is active; close Codex and rerun'
      return $?
      ;;
    herdr)
      if ! command -v herdr >/dev/null 2>&1; then
        printf 'Cannot confirm quiet window because Herdr inspection is unavailable'
        return 2
      fi
      out=$(run_probe herdr session list --json 2>/dev/null)
      status=$?
      if [ "$status" -ne 0 ] || [ -z "$out" ] \
        || ! printf '%s\n' "$out" | jq -e '
          type == "object"
          and (.sessions | type == "array")
          and all(.sessions[]; type == "object"
            and has("running")
            and (.running | type == "boolean"))
        ' >/dev/null 2>&1; then
        printf 'Cannot confirm quiet window because Herdr session inspection failed'
        return 2
      fi
      running=$(printf '%s\n' "$out" | jq -r 'any(.sessions[]; .running == true)')
      status=$?
      if [ "$status" -ne 0 ]; then
        printf 'Cannot confirm quiet window because Herdr session inspection failed'
        return 2
      fi
      if [ "$running" = true ]; then
        printf 'Herdr session is running; finish/stop Herdr-backed work and rerun'
        return 0
      fi
      return 1
      ;;
    opencode)
      quiet_process_blocker opencode 'OpenCode process is active; close it and rerun'
      return $?
      ;;
    tmux)
      if ! command -v tmux >/dev/null 2>&1; then
        printf 'Cannot confirm quiet window because tmux inspection is unavailable'
        return 2
      fi
      out=$(run_probe env LC_ALL=C tmux list-sessions 2>&1)
      status=$?
      if [ "$status" -eq 0 ]; then
        printf 'tmux session is running; finish tmux-backed work and rerun'
        return 0
      fi
      if [ "$status" -eq 1 ] && printf '%s\n' "$out" \
        | grep -Eq '^(no server running on|failed to connect to server: No such file or directory)'; then
        return 1
      fi
      printf 'Cannot confirm quiet window because tmux session inspection failed'
      return 2
      ;;
    node)
      quiet_process_blocker node 'Node process is active; stop shared Node workloads and rerun'
      return $?
      ;;
  esac
  printf 'Cannot confirm quiet window for unknown dependency %s' "$1"
  return 2
}

run_apt_upgrade() {
  local package=$1
  if [ "$(id -u)" -eq 0 ]; then
    apt-get install --only-upgrade "$package"
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get install --only-upgrade "$package"
  else
    printf 'sudo is required to upgrade APT package %s\n' "$package" >&2
    return 1
  fi
}

load_nvm() {
  local nvm_dir
  nvm_dir=${FM_DEPS_NVM_DIR:-${NVM_DIR:-$HOME/.nvm}}
  [ -s "$nvm_dir/nvm.sh" ] || return 1
  # shellcheck source=/dev/null
  . "$nvm_dir/nvm.sh"
  command -v nvm >/dev/null 2>&1
}

nvm_manages_active_node() {
  local nvm_dir nvm_real node_path node_real relative
  nvm_dir=${FM_DEPS_NVM_DIR:-${NVM_DIR:-$HOME/.nvm}}
  [ -s "$nvm_dir/nvm.sh" ] || return 1
  node_path=$(type -P node) || return 1
  nvm_real=$(readlink -f -- "$nvm_dir") || return 1
  node_real=$(readlink -f -- "$node_path") || return 1
  case "$node_real" in
    "$nvm_real"/versions/node/*/bin/node) ;;
    *) return 1 ;;
  esac
  relative=${node_real#"$nvm_real"/versions/node/}
  [ "${relative#*/}" = bin/node ]
}

deps_state_dir() {
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_STATE_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/state\n' "$FM_HOME"
  else
    printf '%s/state\n' "$FM_ROOT"
  fi
}

deps_pending_dir() {
  local state
  state=$(deps_state_dir) || return 1
  printf '%s/.fm-deps-pending\n' "$state"
}

ensure_deps_state_dir() {
  local state
  state=$(deps_state_dir) || return 1
  if [ -e "$state" ] || [ -L "$state" ]; then
    [ -d "$state" ] && [ ! -L "$state" ]
  else
    mkdir -p "$state"
  fi
}

ensure_deps_pending_dir() {
  local state pending
  state=$(deps_state_dir) || return 1
  pending=$(deps_pending_dir) || return 1
  ensure_deps_state_dir || return 1
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    [ -d "$pending" ] && [ ! -L "$pending" ] || return 1
  else
    mkdir "$pending" || return 1
    chmod 700 "$pending" || return 1
  fi
}

validate_firstmate_action_storage() {
  local state pending shared
  state=$(deps_state_dir) || return 1
  pending=$(deps_pending_dir) || return 1
  shared="$state/.secondmate-nudge-pending"
  if [ -e "$state" ] || [ -L "$state" ]; then
    if [ ! -d "$state" ] || [ -L "$state" ]; then
      printf 'Firstmate dependency state directory is invalid\n' >&2
      return 1
    fi
  fi
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    if [ ! -d "$pending" ] || [ -L "$pending" ]; then
      printf 'Firstmate pending action directory is invalid\n' >&2
      return 1
    fi
  fi
  if [ -e "$shared" ] || [ -L "$shared" ]; then
    if [ ! -d "$shared" ] || [ -L "$shared" ]; then
      printf 'Firstmate pending secondmate nudge directory is invalid\n' >&2
      return 1
    fi
  fi
}

write_deps_pending_marker() {
  local marker=$1 parent tmp line
  shift
  ensure_deps_pending_dir || return 1
  parent=$(deps_pending_dir) || return 1
  case "$marker" in "$parent"/*.pending) ;; *) return 1 ;; esac
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  fi
  tmp=$(umask 077; mktemp "$parent/.action.XXXXXX" 2>/dev/null) || return 1
  for line in "$@"; do
    case "$line" in *$'\n'*|*$'\r'*) rm -f -- "$tmp"; return 1 ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  done
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 1; }
}

pending_marker_value() {
  local marker=$1 key=$2
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  awk -v key="$key" '
    index($0, key "=") == 1 {
      count += 1
      value = substr($0, length(key) + 2)
    }
    END {
      if (count != 1) exit 1
      print value
    }
  ' "$marker"
}

firstmate_reread_marker_path() {
  local pending
  pending=$(deps_pending_dir) || return 1
  printf '%s/firstmate-reread.pending\n' "$pending"
}

firstmate_action_manifest_path() {
  local pending
  pending=$(deps_pending_dir) || return 1
  printf '%s/firstmate-actions.pending\n' "$pending"
}

deps_home_dir() {
  printf '%s\n' "${FM_HOME:-$FM_ROOT}"
}

deps_data_dir() {
  local home
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_DATA_OVERRIDE"
  else
    home=$(deps_home_dir) || return 1
    printf '%s/data\n' "$home"
  fi
}

with_firstmate_action_lock() {
  local callback=$1 state lock action_root action_home lock_status rc=0
  shift
  if [ "$_FM_DEPS_ACTION_LOCK_HELD" -eq 1 ]; then
    "$callback" "$@"
    return
  fi
  state=$(deps_state_dir) || return 1
  action_root=$FM_ROOT
  action_home=$(deps_home_dir) || return 1
  ensure_deps_state_dir || {
    printf 'fm-deps.sh: dependency checker state directory is invalid\n' >&2
    return 2
  }
  local FM_ROOT_OVERRIDE FM_ROOT FM_HOME STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_ROOT_OVERRIDE=$action_root
  FM_ROOT=$action_root
  FM_HOME=$action_home
  STATE=$state
  lock="$state/.fm-deps-actions.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_dependency_acquire_lock "$lock"
  lock_status=$?
  [ "$lock_status" -eq 0 ] || return "$lock_status"
  local _FM_DEPS_ACTION_LOCK_HELD=1
  "$callback" "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

declare -A PENDING_FIRSTMATE_BOUND=()
declare -A PENDING_FIRSTMATE_HOME=()
declare -A PENDING_FIRSTMATE_COMMIT=()
declare -A PENDING_FIRSTMATE_REMOTE=()
declare -A PENDING_FIRSTMATE_REMOTE_HOST=()
declare -A PENDING_FIRSTMATE_REMOTE_ROOT=()

reset_firstmate_action_inventory() {
  PENDING_FIRSTMATE_BOUND=()
  PENDING_FIRSTMATE_HOME=()
  PENDING_FIRSTMATE_COMMIT=()
  PENDING_FIRSTMATE_REMOTE=()
  PENDING_FIRSTMATE_REMOTE_HOST=()
  PENDING_FIRSTMATE_REMOTE_ROOT=()
}

write_firstmate_action_manifest() {
  local reread=$1 targets=$2 marker selector id bound
  local -a lines=('action=firstmate-update' "reread=$reread" "targets=$targets")
  marker=$(firstmate_action_manifest_path) || return 1
  if [ "$targets" != none ]; then
    for selector in $targets; do
      id=${selector#fm-}
      bound=${PENDING_FIRSTMATE_BOUND[$id]:-}
      case "$bound" in yes|no) ;; *) return 1 ;; esac
      lines+=("target.$id.bound=$bound")
      if [ "$bound" = yes ]; then
        lines+=(
          "target.$id.home=${PENDING_FIRSTMATE_HOME[$id]:-}"
          "target.$id.commit=${PENDING_FIRSTMATE_COMMIT[$id]:-}"
          "target.$id.remote=${PENDING_FIRSTMATE_REMOTE[$id]:-}"
          "target.$id.remote-host=${PENDING_FIRSTMATE_REMOTE_HOST[$id]:-}"
          "target.$id.remote-root=${PENDING_FIRSTMATE_REMOTE_ROOT[$id]:-}"
        )
      fi
    done
  fi
  write_deps_pending_marker "$marker" "${lines[@]}"
}

load_firstmate_action_manifest() {
  local marker=$1 action selector id bound home commit remote remote_host remote_root seen=""
  reset_firstmate_action_inventory
  action=$(pending_marker_value "$marker" action 2>/dev/null || true)
  PENDING_FIRSTMATE_REREAD=$(pending_marker_value "$marker" reread 2>/dev/null || true)
  PENDING_FIRSTMATE_TARGETS=$(pending_marker_value "$marker" targets 2>/dev/null || true)
  [ "$action" = firstmate-update ] || return 1
  case "$PENDING_FIRSTMATE_REREAD" in yes|no) ;; *) return 1 ;; esac
  [ -n "$PENDING_FIRSTMATE_TARGETS" ] || return 1
  if [ "$PENDING_FIRSTMATE_TARGETS" != none ]; then
    for selector in $PENDING_FIRSTMATE_TARGETS; do
      case "$selector" in fm-*) ;; *) return 1 ;; esac
      id=${selector#fm-}
      case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
      case " $seen " in *" $id "*) return 1 ;; esac
      seen="${seen}${seen:+ }$id"
      bound=$(pending_marker_value "$marker" "target.$id.bound" 2>/dev/null || true)
      case "$bound" in
        no)
          PENDING_FIRSTMATE_BOUND[$id]=no
          ;;
        yes)
          home=$(pending_marker_value "$marker" "target.$id.home" 2>/dev/null) || return 1
          commit=$(pending_marker_value "$marker" "target.$id.commit" 2>/dev/null) || return 1
          remote=$(pending_marker_value "$marker" "target.$id.remote" 2>/dev/null) || return 1
          remote_host=$(pending_marker_value "$marker" "target.$id.remote-host" 2>/dev/null) \
            || return 1
          remote_root=$(pending_marker_value "$marker" "target.$id.remote-root" 2>/dev/null) \
            || return 1
          [ -n "$home" ] || return 1
          case "$remote" in
            0) [ -n "$commit" ] && [ -z "$remote_host" ] \
              && [ -z "$remote_root" ] || return 1 ;;
            1) [ -z "$commit" ] && [ -n "$remote_host" ] \
              && [ -n "$remote_root" ] || return 1 ;;
            *) return 1 ;;
          esac
          PENDING_FIRSTMATE_BOUND[$id]=yes
          PENDING_FIRSTMATE_HOME[$id]=$home
          PENDING_FIRSTMATE_COMMIT[$id]=$commit
          PENDING_FIRSTMATE_REMOTE[$id]=$remote
          PENDING_FIRSTMATE_REMOTE_HOST[$id]=$remote_host
          PENDING_FIRSTMATE_REMOTE_ROOT[$id]=$remote_root
          ;;
        *) return 1 ;;
      esac
    done
  fi
}

current_secondmate_home() {
  local id=$1 meta=$2 data home
  home=$(pending_marker_value "$meta" home 2>/dev/null || true)
  if [ -z "$home" ]; then
    data=$(deps_data_dir) || return 1
    home=$(secondmate_registry_field "$data/secondmates.md" "$id" home 2>/dev/null || true)
  fi
  [ -n "$home" ] || return 1
  printf '%s\n' "$home"
}

capture_secondmate_nudge_identity() {
  local selector=$1 id state meta kind home remote_host remote_root active_home commit
  case "$selector" in fm-*) ;; *) return 1 ;; esac
  id=${selector#fm-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  state=$(deps_state_dir) || return 1
  meta="$state/$id.meta"
  kind=$(pending_marker_value "$meta" kind 2>/dev/null || true)
  [ "$kind" = secondmate ] || return 1
  home=$(current_secondmate_home "$id" "$meta") || return 1
  remote_host=$(pending_marker_value "$meta" remote_host 2>/dev/null || true)
  remote_root=$(pending_marker_value "$meta" remote_root 2>/dev/null || true)
  if [ -n "$remote_host" ]; then
    [ -n "$remote_root" ] || return 1
    commit=""
    SECOND_MATE_IDENTITY_REMOTE=1
  else
    [ -z "$remote_root" ] || return 1
    active_home=$(deps_home_dir) || return 1
    if ! FM_HOME="$active_home" validate_secondmate_home "$id" "$home"; then
      return 1
    fi
    home=$VALIDATED_HOME
    commit=$(run_git_probe -C "$home" rev-parse HEAD 2>/dev/null) || return 1
    [ -n "$commit" ] || return 1
    SECOND_MATE_IDENTITY_REMOTE=0
  fi
  SECOND_MATE_IDENTITY_HOME=$home
  SECOND_MATE_IDENTITY_COMMIT=$commit
  SECOND_MATE_IDENTITY_REMOTE_HOST=$remote_host
  SECOND_MATE_IDENTITY_REMOTE_ROOT=$remote_root
}

capture_firstmate_action_inventory() {
  local targets=$1 selector id seen=""
  reset_firstmate_action_inventory
  [ "$targets" != none ] || return 0
  for selector in $targets; do
    case "$selector" in fm-*) ;; *) return 1 ;; esac
    id=${selector#fm-}
    case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    case " $seen " in *" $id "*) return 1 ;; esac
    seen="${seen}${seen:+ }$id"
    if capture_secondmate_nudge_identity "$selector"; then
      PENDING_FIRSTMATE_BOUND[$id]=yes
      PENDING_FIRSTMATE_HOME[$id]=$SECOND_MATE_IDENTITY_HOME
      PENDING_FIRSTMATE_COMMIT[$id]=$SECOND_MATE_IDENTITY_COMMIT
      PENDING_FIRSTMATE_REMOTE[$id]=$SECOND_MATE_IDENTITY_REMOTE
      PENDING_FIRSTMATE_REMOTE_HOST[$id]=$SECOND_MATE_IDENTITY_REMOTE_HOST
      PENDING_FIRSTMATE_REMOTE_ROOT[$id]=$SECOND_MATE_IDENTITY_REMOTE_ROOT
    else
      PENDING_FIRSTMATE_BOUND[$id]=no
    fi
  done
}

secondmate_nudge_record_is_valid() {
  local marker=$1 id home commit remote remote_host remote_root owner
  owner=$(pending_marker_value "$marker" owner 2>/dev/null || true)
  case "$owner" in ''|fm-deps) ;; *) return 1 ;; esac
  id=$(pending_marker_value "$marker" id 2>/dev/null || true)
  home=$(pending_marker_value "$marker" home 2>/dev/null || true)
  commit=$(pending_marker_value "$marker" commit 2>/dev/null || true)
  remote=$(pending_marker_value "$marker" remote 2>/dev/null || true)
  remote_host=$(pending_marker_value "$marker" remote_host 2>/dev/null || true)
  remote_root=$(pending_marker_value "$marker" remote_root 2>/dev/null || true)
  case "$remote" in
    0)
      fm_secondmate_local_nudge_matches "$marker" "$id" "$home" "$commit" "$owner"
      ;;
    1)
      if [ -n "$remote_host" ] && [ -n "$remote_root" ]; then
        fm_secondmate_remote_nudge_matches "$marker" "$id" "$home" \
          "$remote_host" "$remote_root" "$owner"
      elif [ -z "$owner" ] && [ -z "$remote_host" ] && [ -z "$remote_root" ]; then
        fm_secondmate_legacy_remote_nudge_matches "$marker" "$id" "$home"
      else
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

secondmate_nudge_matches_identity() {
  local marker=$1 id=$2 home=$3 commit=$4 remote=$5 remote_host=$6 remote_root=$7 owner
  owner=$(pending_marker_value "$marker" owner 2>/dev/null || true)
  case "$owner" in ''|fm-deps) ;; *) return 1 ;; esac
  case "$remote" in
    0) fm_secondmate_local_nudge_matches "$marker" "$id" "$home" "$commit" "$owner" ;;
    1)
      fm_secondmate_remote_nudge_matches "$marker" "$id" "$home" \
        "$remote_host" "$remote_root" "$owner" \
        || { [ -z "$owner" ] \
          && fm_secondmate_legacy_remote_nudge_matches "$marker" "$id" "$home"; }
      ;;
    *) return 1 ;;
  esac
}

ensure_secondmate_nudge_retired_dir() {
  local state=$1 retired
  retired="$state/.secondmate-nudge-retired"
  if [ -e "$retired" ] || [ -L "$retired" ]; then
    [ -d "$retired" ] && [ ! -L "$retired" ] || return 1
  else
    mkdir "$retired" || return 1
    chmod 700 "$retired" || return 1
  fi
  printf '%s\n' "$retired"
}

quarantine_secondmate_nudge() {
  local marker=$1 state=$2 id=$3 retired slot
  retired=$(ensure_secondmate_nudge_retired_dir "$state") || return 1
  slot=$(umask 077; mktemp -d "$retired/$id.XXXXXX" 2>/dev/null) || return 1
  if mv -- "$marker" "$slot/action.pending" 2>/dev/null; then
    return 0
  fi
  rmdir "$slot" 2>/dev/null || true
  [ ! -e "$marker" ] && [ ! -L "$marker" ]
}

with_secondmate_nudge_lock() {
  local state=$1 id=$2 callback=$3 lock root home lock_status rc=0
  shift 3
  lock=$(fm_secondmate_nudge_transaction_lock_path "$state" "$id") || return 1
  root=$FM_ROOT
  home=$(deps_home_dir) || return 1
  local FM_ROOT_OVERRIDE FM_ROOT FM_HOME FM_STATE_OVERRIDE STATE FM_WAKE_QUEUE
  local FM_WAKE_QUEUE_LOCK
  FM_ROOT_OVERRIDE=$root
  FM_ROOT=$root
  FM_HOME=$home
  FM_STATE_OVERRIDE=$state
  STATE=$state
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_dependency_acquire_lock "$lock"
  lock_status=$?
  [ "$lock_status" -eq 0 ] || return "$lock_status"
  "$callback" "$@" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

publish_secondmate_nudge_action_locked() {
  local state=$1 id=$2 home=$3 commit=$4 instructions=$5 message=$6 remote=$7
  local remote_host=$8 remote_root=$9 marker write_status active_home marker_status
  marker=$(fm_secondmate_nudge_marker_path "$state" "$id") || return 1
  fm_secondmate_nudge_write "$state" "$id" "$home" "$commit" \
    "$instructions" "$message" "$remote" fm-deps "$remote_host" "$remote_root" create
  write_status=$?
  [ "$write_status" -eq 0 ] && return 0
  [ "$write_status" -eq 2 ] || return 1
  if secondmate_nudge_matches_identity "$marker" "$id" "$home" "$commit" \
    "$remote" "$remote_host" "$remote_root"; then
    return 0
  fi
  active_home=$(deps_home_dir) || return 1
  secondmate_nudge_is_actionable "$marker" "$state" "$active_home"
  marker_status=$?
  case "$marker_status" in
    0) return 1 ;;
    1) quarantine_secondmate_nudge "$marker" "$state" "$id" || return 1 ;;
    *) return 1 ;;
  esac
  fm_secondmate_nudge_write "$state" "$id" "$home" "$commit" \
    "$instructions" "$message" "$remote" fm-deps "$remote_host" "$remote_root" create
}

publish_secondmate_nudge_action() {
  local state=$1 id=$2
  with_secondmate_nudge_lock "$state" "$id" publish_secondmate_nudge_action_locked "$@"
}

record_secondmate_nudge_action() {
  local selector=$1 id state meta kind current_home current_remote_host current_remote_root
  local active_home head home commit remote remote_host remote_root instructions message
  id=${selector#fm-}
  [ "${PENDING_FIRSTMATE_BOUND[$id]:-}" = yes ] || return 1
  home=${PENDING_FIRSTMATE_HOME[$id]:-}
  commit=${PENDING_FIRSTMATE_COMMIT[$id]:-}
  remote=${PENDING_FIRSTMATE_REMOTE[$id]:-}
  remote_host=${PENDING_FIRSTMATE_REMOTE_HOST[$id]:-}
  remote_root=${PENDING_FIRSTMATE_REMOTE_ROOT[$id]:-}
  state=$(deps_state_dir) || return 1
  meta="$state/$id.meta"
  kind=$(pending_marker_value "$meta" kind 2>/dev/null || true)
  [ "$kind" = secondmate ] || return 1
  current_home=$(current_secondmate_home "$id" "$meta") || return 1
  current_remote_host=$(pending_marker_value "$meta" remote_host 2>/dev/null || true)
  current_remote_root=$(pending_marker_value "$meta" remote_root 2>/dev/null || true)
  active_home=$(deps_home_dir) || return 1
  case "$remote" in
    0)
      [ -z "$current_remote_host" ] && [ -z "$current_remote_root" ] || return 1
      FM_HOME="$active_home" validate_secondmate_home "$id" "$current_home" || return 1
      [ "$VALIDATED_HOME" = "$home" ] || return 1
      head=$(run_git_probe -C "$home" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || return 1
      instructions=AGENTS.md
      message=$FM_SECOND_MATE_NUDGE_MESSAGE
      ;;
    1)
      [ "$current_home" = "$home" ] && [ "$current_remote_host" = "$remote_host" ] \
        && [ "$current_remote_root" = "$remote_root" ] || return 1
      instructions=remote
      message=$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE
      ;;
    *) return 1 ;;
  esac
  publish_secondmate_nudge_action "$state" "$id" "$home" "$commit" \
    "$instructions" "$message" "$remote" "$remote_host" "$remote_root"
}

firstmate_update_commit_is_valid() {
  fm_update_action_commit_is_valid "$1"
}

firstmate_update_commit_state() {
  local repo=$1 phase=$2 before=$3 after=$4 head
  JOURNALED_FIRSTMATE_COMMIT=""
  head=$(run_git_probe -C "$repo" rev-parse HEAD 2>/dev/null) || return 1
  firstmate_update_commit_is_valid "$head" || return 1
  if [ "$phase" = prepared ] && [ "$head" = "$before" ]; then
    return 10
  fi
  if [ "$head" = "$after" ] \
    || run_git_probe -C "$repo" merge-base --is-ancestor "$after" "$head" >/dev/null 2>&1; then
    JOURNALED_FIRSTMATE_COMMIT=$head
    return 0
  fi
  return 1
}

process_journaled_firstmate_reread() {
  local marker=$1 action phase path before after commit_status=0
  action=$(fm_update_action_value "$marker" action 2>/dev/null || true)
  phase=$(fm_update_action_value "$marker" phase 2>/dev/null || true)
  path=$(fm_update_action_value "$marker" path 2>/dev/null || true)
  before=$(fm_update_action_value "$marker" before 2>/dev/null || true)
  after=$(fm_update_action_value "$marker" after 2>/dev/null || true)
  if [ "$action" != firstmate-update-reread ] \
    || { [ "$phase" != prepared ] && [ "$phase" != updated ]; } \
    || [ "$path" != "$FM_ROOT/AGENTS.md" ] \
    || ! firstmate_update_commit_is_valid "$before" \
    || ! firstmate_update_commit_is_valid "$after" \
    || [ "$before" = "$after" ]; then
    printf 'Firstmate update reread journal is invalid\n' >&2
    return 2
  fi
  firstmate_update_commit_state "$FM_ROOT" "$phase" "$before" "$after" \
    || commit_status=$?
  if [ "$commit_status" -eq 10 ]; then
    rm -f -- "$marker"
    return
  fi
  if [ "$commit_status" -ne 0 ]; then
    printf 'Firstmate update reread journal no longer matches the checkout\n' >&2
    return 2
  fi
  printf 'REREAD_REQUIRED: %s/AGENTS.md changed\n' "$FM_ROOT"
  confirm_firstmate_reread || return 2
  rm -f -- "$marker" || {
    printf 'Firstmate update reread journal could not be cleared\n' >&2
    return 1
  }
}

process_journaled_secondmate_update() {
  local marker=$1 action phase id selector home before after remote remote_host remote_root
  local expected state meta kind current_home current_remote_host current_remote_root active_home head=""
  local instructions message commit_status=0 remote_out remote_result remote_commit
  local publish_status
  action=$(fm_update_action_value "$marker" action 2>/dev/null || true)
  phase=$(fm_update_action_value "$marker" phase 2>/dev/null || true)
  id=$(fm_update_action_value "$marker" id 2>/dev/null || true)
  selector=$(fm_update_action_value "$marker" selector 2>/dev/null || true)
  home=$(fm_update_action_value "$marker" home 2>/dev/null || true)
  before=$(fm_update_action_value "$marker" before 2>/dev/null || true)
  after=$(fm_update_action_value "$marker" after 2>/dev/null || true)
  remote=$(fm_update_action_value "$marker" remote 2>/dev/null || true)
  remote_host=$(fm_update_action_value "$marker" remote_host 2>/dev/null || true)
  remote_root=$(fm_update_action_value "$marker" remote_root 2>/dev/null || true)
  expected=$(fm_update_action_secondmate_path "$id" 2>/dev/null || true)
  if [ "$action" != firstmate-update-secondmate ] \
    || { [ "$phase" != prepared ] && [ "$phase" != updated ]; } \
    || [ "$marker" != "$expected" ] || [ "$selector" != "fm-$id" ] \
    || [ -z "$home" ]; then
    printf 'Firstmate secondmate update journal is invalid: %s\n' "$marker" >&2
    return 2
  fi
  state=$(deps_state_dir) || return 1
  meta="$state/$id.meta"
  kind=$(pending_marker_value "$meta" kind 2>/dev/null || true)
  current_home=$(current_secondmate_home "$id" "$meta" 2>/dev/null || true)
  current_remote_host=$(pending_marker_value "$meta" remote_host 2>/dev/null || true)
  current_remote_root=$(pending_marker_value "$meta" remote_root 2>/dev/null || true)
  active_home=$(deps_home_dir) || return 1
  if [ "$kind" != secondmate ] || [ -z "$current_home" ]; then
    printf 'Firstmate post-update nudge identity changed for %s\n' "$selector" >&2
    return 1
  fi
  case "$remote" in
    0)
      if [ -n "$remote_host" ] || [ -n "$remote_root" ] \
        || [ -n "$current_remote_host" ] || [ -n "$current_remote_root" ] \
        || ! firstmate_update_commit_is_valid "$before" \
        || ! firstmate_update_commit_is_valid "$after" \
        || [ "$before" = "$after" ] \
        || ! FM_HOME="$active_home" validate_secondmate_home "$id" "$current_home" \
        || [ "$VALIDATED_HOME" != "$home" ]; then
        printf 'Firstmate local secondmate update journal is invalid for %s\n' "$selector" >&2
        return 2
      fi
      firstmate_update_commit_state "$home" "$phase" "$before" "$after" \
        || commit_status=$?
      if [ "$commit_status" -eq 10 ]; then
        rm -f -- "$marker"
        return
      fi
      if [ "$commit_status" -ne 0 ]; then
        printf 'Firstmate post-update nudge commit changed for %s\n' "$selector" >&2
        return 1
      fi
      head=$JOURNALED_FIRSTMATE_COMMIT
      instructions=AGENTS.md
      message=$FM_SECOND_MATE_NUDGE_MESSAGE
      ;;
    1)
      if [ -n "$before" ] || [ -z "$remote_host" ] || [ -z "$remote_root" ] \
        || [ "$current_home" != "$home" ] \
        || [ "$current_remote_host" != "$remote_host" ] \
        || [ "$current_remote_root" != "$remote_root" ]; then
        printf 'Firstmate remote secondmate update journal is invalid for %s\n' "$selector" >&2
        return 2
      fi
      if [ "$phase" = prepared ] || [ -z "$after" ]; then
        if ! remote_out=$(FM_ON_EXPECTED_HOST="$remote_host" \
          FM_ON_EXPECTED_ROOT="$remote_root" FM_ON_EXPECTED_HOME="$home" \
          "$FM_ROOT/bin/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" \
          < /dev/null 2>&1); then
          printf 'Firstmate remote secondmate update retry failed for %s: %s\n' \
            "$selector" "${remote_out%%$'\n'*}" >&2
          return 1
        fi
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*) remote_commit=${remote_result#synced: } ;;
          current:*) remote_commit=${remote_result#current: } ;;
          *)
            printf 'Firstmate remote secondmate update retry was invalid for %s\n' "$selector" >&2
            return 1
            ;;
        esac
        if ! firstmate_update_commit_is_valid "$remote_commit" \
          || ! fm_update_action_write_secondmate updated "$id" "$home" "" \
            "$remote_commit" 1 "$remote_host" "$remote_root"; then
          printf 'Firstmate remote secondmate update retry could not be recorded for %s\n' \
            "$selector" >&2
          return 1
        fi
        phase=updated
        after=$remote_commit
      fi
      if [ "$phase" != updated ] || ! firstmate_update_commit_is_valid "$after"; then
        printf 'Firstmate remote secondmate update journal is invalid for %s\n' "$selector" >&2
        return 2
      fi
      instructions=remote
      message=$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE
      ;;
    *)
      printf 'Firstmate secondmate update journal placement is invalid for %s\n' "$selector" >&2
      return 2
      ;;
  esac
  publish_secondmate_nudge_action "$state" "$id" "$home" "$head" \
    "$instructions" "$message" "$remote" "$remote_host" "$remote_root"
  publish_status=$?
  [ "$publish_status" -eq 0 ] || return "$publish_status"
  rm -f -- "$marker" || {
    printf 'Firstmate secondmate update journal could not be cleared for %s\n' "$selector" >&2
    return 1
  }
}

process_firstmate_update_journal() {
  local pending firstmate_marker marker status failed=0
  pending=$(deps_pending_dir) || return 1
  local FM_UPDATE_ACTION_DIR=$pending
  firstmate_marker=$(fm_update_action_firstmate_path) || return 1
  if [ -e "$firstmate_marker" ] || [ -L "$firstmate_marker" ]; then
    process_journaled_firstmate_reread "$firstmate_marker" || return $?
  fi
  for marker in "$pending"/firstmate-update-secondmate-*.pending; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    status=0
    process_journaled_secondmate_update "$marker" || status=$?
    case "$status" in
      0) ;;
      75) return 75 ;;
      *) failed=1 ;;
    esac
  done
  [ "$failed" -eq 0 ]
}

identity_bound_nudge_claim_path() {
  local id=$1 pending
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  pending=$(deps_pending_dir) || return 1
  printf '%s/secondmate-nudge-%s.claimed\n' "$pending" "$id"
}

restore_identity_bound_nudge_claim() {
  local claim=$1 marker=$2
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    rm -f -- "$claim"
    return $?
  fi
  if ln -- "$claim" "$marker" 2>/dev/null; then
    rm -f -- "$claim"
    return $?
  fi
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    rm -f -- "$claim"
    return $?
  fi
  return 1
}

process_identity_bound_nudge_claim() {
  local claim=$1 marker=$2 state=$3 active_home=$4
  local id selector home commit instructions message remote owner recorded_remote_host
  local recorded_remote_root expected_marker meta kind current_home current_remote_host
  local current_remote_root head
  if [ ! -f "$claim" ] || [ -L "$claim" ]; then
    printf 'Firstmate claimed secondmate nudge is invalid: %s\n' "$claim" >&2
    return 1
  fi
  owner=$(pending_marker_value "$claim" owner 2>/dev/null || true)
  if [ "$owner" != fm-deps ]; then
    restore_identity_bound_nudge_claim "$claim" "$marker"
    return $?
  fi
  id=$(pending_marker_value "$claim" id 2>/dev/null || true)
  selector=$(pending_marker_value "$claim" selector 2>/dev/null || true)
  home=$(pending_marker_value "$claim" home 2>/dev/null || true)
  commit=$(pending_marker_value "$claim" commit 2>/dev/null || true)
  instructions=$(pending_marker_value "$claim" instructions 2>/dev/null || true)
  message=$(pending_marker_value "$claim" message 2>/dev/null || true)
  remote=$(pending_marker_value "$claim" remote 2>/dev/null || true)
  recorded_remote_host=$(pending_marker_value "$claim" remote_host 2>/dev/null || true)
  recorded_remote_root=$(pending_marker_value "$claim" remote_root 2>/dev/null || true)
  expected_marker=$(fm_secondmate_nudge_marker_path "$state" "$id" 2>/dev/null || true)
  if [ "$expected_marker" != "$marker" ] || [ "$selector" != "fm-$id" ] \
    || [ -z "$home" ] || [ -z "$instructions" ]; then
    printf 'Firstmate pending secondmate nudge is invalid: %s\n' "$claim" >&2
    restore_identity_bound_nudge_claim "$claim" "$marker" || true
    return 1
  fi
  meta="$state/$id.meta"
  kind=$(pending_marker_value "$meta" kind 2>/dev/null || true)
  current_home=$(current_secondmate_home "$id" "$meta" 2>/dev/null || true)
  current_remote_host=$(pending_marker_value "$meta" remote_host 2>/dev/null || true)
  current_remote_root=$(pending_marker_value "$meta" remote_root 2>/dev/null || true)
  if [ "$kind" != secondmate ] || [ -z "$current_home" ]; then
    printf 'Firstmate post-update nudge target changed for %s\n' "$selector" >&2
    restore_identity_bound_nudge_claim "$claim" "$marker" || true
    return 1
  fi
  case "$remote" in
    0)
      if [ -n "$current_remote_host" ] || [ -n "$current_remote_root" ] \
        || [ -n "$recorded_remote_host" ] || [ -n "$recorded_remote_root" ] \
        || [ "$instructions" != AGENTS.md ] \
        || [ "$message" != "$FM_SECOND_MATE_NUDGE_MESSAGE" ] \
        || ! FM_HOME="$active_home" validate_secondmate_home "$id" "$current_home" \
        || [ "$VALIDATED_HOME" != "$home" ]; then
        printf 'Firstmate post-update nudge identity is invalid for %s\n' "$selector" >&2
        restore_identity_bound_nudge_claim "$claim" "$marker" || true
        return 1
      fi
      head=$(run_git_probe -C "$home" rev-parse HEAD 2>/dev/null || true)
      if [ -z "$head" ] || [ "$head" != "$commit" ]; then
        printf 'Firstmate post-update nudge commit changed for %s\n' "$selector" >&2
        restore_identity_bound_nudge_claim "$claim" "$marker" || true
        return 1
      fi
      ;;
    1)
      if [ -z "$recorded_remote_host" ] || [ -z "$recorded_remote_root" ] \
        || [ "$current_home" != "$home" ] \
        || [ "$current_remote_host" != "$recorded_remote_host" ] \
        || [ "$current_remote_root" != "$recorded_remote_root" ] \
        || [ -n "$commit" ] || [ "$instructions" != remote ] \
        || [ "$message" != "$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" ]; then
        printf 'Firstmate post-update remote nudge identity is invalid for %s\n' "$selector" >&2
        restore_identity_bound_nudge_claim "$claim" "$marker" || true
        return 1
      fi
      ;;
    *)
      printf 'Firstmate pending secondmate nudge placement is invalid for %s\n' "$selector" >&2
      restore_identity_bound_nudge_claim "$claim" "$marker" || true
      return 1
      ;;
  esac
  if FM_ON_EXPECTED_HOST="$recorded_remote_host" \
    FM_ON_EXPECTED_ROOT="$recorded_remote_root" FM_ON_EXPECTED_HOME="$home" \
    FM_HOME="$active_home" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$state" \
    "$FM_ROOT/bin/fm-send.sh" "$selector" "$message"; then
    if ! rm -f -- "$claim"; then
      printf 'Firstmate post-update nudge could not be cleared for %s\n' "$selector" >&2
      return 1
    fi
    return 0
  fi
  printf 'Firstmate post-update nudge failed for %s\n' "$selector" >&2
  restore_identity_bound_nudge_claim "$claim" "$marker" || {
    printf 'Firstmate post-update nudge could not be restored for %s\n' "$selector" >&2
  }
  return 1
}

process_identity_bound_nudge_marker_locked() {
  local marker=$1 claim=$2 state=$3 active_home=$4 id owner
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  owner=$(pending_marker_value "$marker" owner 2>/dev/null || true)
  [ "$owner" = fm-deps ] || return 0
  id=$(pending_marker_value "$marker" id 2>/dev/null || true)
  [ "$marker" = "$(fm_secondmate_nudge_marker_path "$state" "$id" 2>/dev/null || true)" ] \
    || return 1
  [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 1
  mv -- "$marker" "$claim" 2>/dev/null || {
    [ ! -e "$marker" ] && [ ! -L "$marker" ]
    return
  }
  process_identity_bound_nudge_claim "$claim" "$marker" "$state" "$active_home"
}

process_identity_bound_nudges() {
  local state active_home pending claims marker claim id owner processed_ids="" failed=0
  local lock_status
  state=$(deps_state_dir) || return 1
  active_home=$(deps_home_dir) || return 1
  pending="$state/.secondmate-nudge-pending"
  claims=$(deps_pending_dir) || return 1
  if [ -e "$claims" ] || [ -L "$claims" ]; then
    [ -d "$claims" ] && [ ! -L "$claims" ] || return 1
  fi
  if [ -d "$claims" ]; then
    for claim in "$claims"/secondmate-nudge-*.claimed; do
      [ -e "$claim" ] || [ -L "$claim" ] || continue
      id=$(pending_marker_value "$claim" id 2>/dev/null || true)
      [ -z "$id" ] || processed_ids="${processed_ids}${processed_ids:+ }$id"
      marker=$(fm_secondmate_nudge_marker_path "$state" "$id" 2>/dev/null || true)
      if [ -z "$marker" ]; then
        failed=1
        continue
      fi
      with_secondmate_nudge_lock "$state" "$id" process_identity_bound_nudge_claim \
        "$claim" "$marker" "$state" "$active_home"
      lock_status=$?
      case "$lock_status" in
        0) ;;
        75) return 75 ;;
        *) failed=1 ;;
      esac
    done
  fi
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    [ -d "$pending" ] && [ ! -L "$pending" ] || return 1
  else
    [ "$failed" -eq 0 ]
    return
  fi
  for marker in "$pending"/*.pending; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    if [ ! -f "$marker" ] || [ -L "$marker" ]; then
      printf 'Firstmate pending secondmate nudge is invalid: %s\n' "$marker" >&2
      failed=1
      continue
    fi
    owner=$(pending_marker_value "$marker" owner 2>/dev/null || true)
    [ "$owner" = fm-deps ] || continue
    id=$(pending_marker_value "$marker" id 2>/dev/null || true)
    if [ -n "$id" ]; then
      case " $processed_ids " in *" $id "*) continue ;; esac
    fi
    claim=$(identity_bound_nudge_claim_path "$id" 2>/dev/null || true)
    if [ -z "$claim" ]; then
      printf 'Firstmate post-update nudge could not be claimed for fm-%s\n' "${id:-unknown}" >&2
      failed=1
      continue
    fi
    with_secondmate_nudge_lock "$state" "$id" process_identity_bound_nudge_marker_locked \
      "$marker" "$claim" "$state" "$active_home"
    lock_status=$?
    case "$lock_status" in
      0) ;;
      75) return 75 ;;
      *)
        printf 'Firstmate post-update nudge could not be processed for fm-%s\n' "$id" >&2
        failed=1
        ;;
    esac
  done
  [ "$failed" -eq 0 ]
}

npm_hook_marker_path() {
  local id=$1 pending
  case "$id" in gh-axi|chrome-devtools-axi|lavish-axi) ;; *) return 1 ;; esac
  pending=$(deps_pending_dir) || return 1
  printf '%s/npm-hooks-%s.pending\n' "$pending" "$id"
}

versions_match() {
  local left right
  left=$(printf '%s\n' "$1" | normalize_version)
  right=$(printf '%s\n' "$2" | normalize_version)
  [ -n "$left" ] && [ "$left" = "$right" ]
}

npm_hook_action_pending() {
  local marker
  marker=$(npm_hook_marker_path "$1") || return 1
  [ -e "$marker" ] || [ -L "$marker" ]
}

persist_npm_hook_action() {
  local id=$1 version=$2 marker
  marker=$(npm_hook_marker_path "$id") || return 1
  write_deps_pending_marker "$marker" \
    'action=npm-hook-setup' "tool=$id" "version=$version"
}

clear_npm_hook_action() {
  local marker
  marker=$(npm_hook_marker_path "$1") || return 1
  rm -f -- "$marker"
}

verify_npm_tool_version() {
  local command_name=$1 expected=$2 actual
  if ! actual=$(command_version "$command_name") || [ -z "$actual" ]; then
    printf 'Installed %s cannot be resolved from the active PATH\n' "$command_name" >&2
    return 1
  fi
  if ! versions_match "$actual" "$expected"; then
    printf 'Installed %s resolved to %s instead of approved version %s\n' \
      "$command_name" "$actual" "$expected" >&2
    return 1
  fi
}

run_npm_upgrade() {
  local id=$1 latest=$2
  if npm_hook_marker_path "$id" >/dev/null 2>&1; then
    persist_npm_hook_action "$id" "$latest" || {
      printf 'Cannot record pending %s hook setup\n' "$id" >&2
      return 1
    }
  fi
  npm install -g "$id@$latest" || return 1
  verify_npm_tool_version "$id" "$latest" || return 1
  if npm_hook_marker_path "$id" >/dev/null 2>&1; then
    "$id" setup hooks || return 1
    clear_npm_hook_action "$id" || {
      printf 'Cannot clear completed %s hook setup\n' "$id" >&2
      return 1
    }
  fi
}

retry_pending_npm_hook() {
  local id=$1 label=$2 command_name=$3 installed=$4 latest=$5 marker action tool version reply
  local supersede=0
  marker=$(npm_hook_marker_path "$id") || return 0
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  action=$(pending_marker_value "$marker" action 2>/dev/null || true)
  tool=$(pending_marker_value "$marker" tool 2>/dev/null || true)
  version=$(pending_marker_value "$marker" version 2>/dev/null || true)
  if [ "$action" != npm-hook-setup ] || [ "$tool" != "$id" ] || [ -z "$version" ]; then
    printf 'PENDING: %s hook setup record is invalid\n' "$label" >&2
    return 1
  fi
  if ! versions_match "$installed" "$version"; then
    if ! versions_match "$installed" "$latest"; then
      printf 'PENDING: %s hook setup requires version %s but active version is %s\n' \
        "$label" "$version" "$installed" >&2
      return 1
    fi
    printf 'PENDING: %s hook setup for %s is superseded by active approved version %s\n' \
      "$label" "$version" "$installed"
    supersede=1
  else
    printf 'PENDING: %s %s hook setup is incomplete\n' "$label" "$version"
  fi
  [ "$CHECK_ONLY" -eq 0 ] && is_interactive || return 1
  printf 'Complete pending %s hook setup now? [y/N] ' "$label"
  IFS= read -r reply || reply=""
  case "$reply" in y|Y|yes|YES|Yes) ;; *) return 1 ;; esac
  if [ "$supersede" -eq 1 ] && ! persist_npm_hook_action "$id" "$installed"; then
    printf 'Cannot supersede pending %s hook setup\n' "$label" >&2
    return 1
  fi
  if ! "$command_name" setup hooks; then
    printf 'Pending %s hook setup failed\n' "$label" >&2
    return 1
  fi
  clear_npm_hook_action "$id" || {
    printf 'Cannot clear completed %s hook setup\n' "$label" >&2
    return 1
  }
  printf 'COMPLETED: %s hook setup\n' "$label"
}

confirm_firstmate_reread() {
  local reply
  if [ "$CHECK_ONLY" -ne 0 ] || ! is_interactive; then
    printf 'Cannot confirm the required Firstmate instruction reread\n' >&2
    return 1
  fi
  printf 'Re-read %s/AGENTS.md now, then confirm completion before secondmates are nudged. [y/N] ' \
    "$FM_ROOT"
  IFS= read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES|Yes)
      printf '\nREREAD_CONFIRMED: %s/AGENTS.md\n' "$FM_ROOT"
      return 0
      ;;
    *)
      printf '\nFirstmate instruction reread was not confirmed\n' >&2
      return 1
      ;;
  esac
}

persist_firstmate_update_actions() {
  local reread=$1 targets=$2
  capture_firstmate_action_inventory "$targets" || return 1
  write_firstmate_action_manifest "$reread" "$targets"
}

secondmate_nudge_is_actionable() {
  local marker=$1 state=$2 active_home=$3 id owner meta kind
  local home current_home commit remote remote_host remote_root current_remote_host
  local current_remote_root head
  owner=$(pending_marker_value "$marker" owner 2>/dev/null || true)
  case "$owner" in ''|fm-deps) ;; *) return 2 ;; esac
  secondmate_nudge_record_is_valid "$marker" || return 2
  id=$(pending_marker_value "$marker" id 2>/dev/null || true)
  meta="$state/$id.meta"
  kind=$(pending_marker_value "$meta" kind 2>/dev/null || true)
  [ "$kind" = secondmate ] || return 1
  home=$(pending_marker_value "$marker" home 2>/dev/null || true)
  current_home=$(current_secondmate_home "$id" "$meta" 2>/dev/null || true)
  [ -n "$current_home" ] || return 1
  commit=$(pending_marker_value "$marker" commit 2>/dev/null || true)
  remote=$(pending_marker_value "$marker" remote 2>/dev/null || true)
  remote_host=$(pending_marker_value "$marker" remote_host 2>/dev/null || true)
  remote_root=$(pending_marker_value "$marker" remote_root 2>/dev/null || true)
  current_remote_host=$(pending_marker_value "$meta" remote_host 2>/dev/null || true)
  current_remote_root=$(pending_marker_value "$meta" remote_root 2>/dev/null || true)
  case "$remote" in
    0)
      [ -z "$current_remote_host" ] && [ -z "$current_remote_root" ] || return 1
      FM_HOME="$active_home" validate_secondmate_home "$id" "$current_home" || return 2
      [ "$VALIDATED_HOME" = "$home" ] || return 1
      head=$(run_git_probe -C "$home" rev-parse HEAD 2>/dev/null) || return 2
      [ -n "$head" ] || return 2
      [ "$head" = "$commit" ] || return 1
      ;;
    1)
      [ "$current_home" = "$home" ] || return 1
      [ -n "$current_remote_host" ] && [ -n "$current_remote_root" ] || return 1
      if [ -n "$remote_host" ] || [ -n "$remote_root" ]; then
        [ "$current_remote_host" = "$remote_host" ] \
          && [ "$current_remote_root" = "$remote_root" ] || return 1
      fi
      remote_host=$current_remote_host
      remote_root=$current_remote_root
      ;;
    *) return 2 ;;
  esac
  secondmate_nudge_matches_identity "$marker" "$id" "$home" "$commit" \
    "$remote" "$remote_host" "$remote_root" || return 2
  return 0
}

cleanup_stale_secondmate_nudge_locked() {
  local marker=$1 state=$2 active_home=$3 expected_id=$4 id marker_status
  [ -e "$marker" ] || [ -L "$marker" ] || return 0
  id=$(pending_marker_value "$marker" id 2>/dev/null || true)
  [ "$id" = "$expected_id" ] || return 2
  secondmate_nudge_is_actionable "$marker" "$state" "$active_home"
  marker_status=$?
  case "$marker_status" in
    0) return 0 ;;
    1) quarantine_secondmate_nudge "$marker" "$state" "$id" ;;
    *) return 2 ;;
  esac
}

cleanup_stale_secondmate_nudges() {
  local state active_home pending shared marker id owner status failed=0
  state=$(deps_state_dir) || return 1
  active_home=$(deps_home_dir) || return 1
  pending=$(deps_pending_dir) || return 1
  shared="$state/.secondmate-nudge-pending"
  for marker in "$pending"/secondmate-nudge-*.claimed "$shared"/*.pending; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    id=$(pending_marker_value "$marker" id 2>/dev/null || true)
    case "$id" in ''|*[!A-Za-z0-9._-]*) return 2 ;; esac
    case "$marker" in
      "$pending/secondmate-nudge-$id.claimed")
        owner=$(pending_marker_value "$marker" owner 2>/dev/null || true)
        [ "$owner" = fm-deps ] || return 2
        ;;
      "$shared/$id.pending") ;;
      *) return 2 ;;
    esac
    with_secondmate_nudge_lock "$state" "$id" cleanup_stale_secondmate_nudge_locked \
      "$marker" "$state" "$active_home" "$id"
    status=$?
    case "$status" in
      0) ;;
      2) return 2 ;;
      75) return 75 ;;
      *) failed=1 ;;
    esac
  done
  [ "$failed" -eq 0 ]
}

firstmate_update_actions_pending() {
  local pending marker state shared active_home marker_status id expected
  pending=$(deps_pending_dir) || return 1
  validate_firstmate_action_storage || return 2
  marker=$(firstmate_action_manifest_path) || return 1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    return 0
  fi
  marker=$(firstmate_reread_marker_path) || return 1
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    return 0
  fi
  for marker in "$pending"/firstmate-update-*.pending; do
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      return 0
    fi
  done
  for marker in "$pending"/secondmate-*.pending; do
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      return 0
    fi
  done
  state=$(deps_state_dir) || return 1
  active_home=$(deps_home_dir) || return 2
  for marker in "$pending"/secondmate-nudge-*.claimed; do
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      id=$(pending_marker_value "$marker" id 2>/dev/null || true)
      expected=$(identity_bound_nudge_claim_path "$id" 2>/dev/null || true)
      [ "$expected" = "$marker" ] || return 2
      [ "$(pending_marker_value "$marker" owner 2>/dev/null || true)" = fm-deps ] \
        || return 2
      secondmate_nudge_is_actionable "$marker" "$state" "$active_home"
      marker_status=$?
      case "$marker_status" in
        0) return 0 ;;
        1) ;;
        *) return 2 ;;
      esac
    fi
  done
  shared="$state/.secondmate-nudge-pending"
  for marker in "$shared"/*.pending; do
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      id=$(pending_marker_value "$marker" id 2>/dev/null || true)
      expected=$(fm_secondmate_nudge_marker_path "$state" "$id" 2>/dev/null || true)
      [ "$expected" = "$marker" ] || return 2
      secondmate_nudge_is_actionable "$marker" "$state" "$active_home"
      marker_status=$?
      case "$marker_status" in
        0) return 0 ;;
        1) ;;
        2) return 2 ;;
        *) return 2 ;;
      esac
    fi
  done
  return 1
}

process_pending_firstmate_actions() {
  local pending manifest reread_marker action path marker targets selector failed_targets=""
  local record_failed=0 send_failed=0 journal_failed=0 journal_status=0
  local record_status send_status
  validate_firstmate_action_storage || return 3
  pending=$(deps_pending_dir) || return 1
  if [ -e "$pending" ] || [ -L "$pending" ]; then
    [ -d "$pending" ] && [ ! -L "$pending" ] || {
      printf 'Firstmate pending action directory is invalid\n' >&2
      return 1
    }
  else
    pending=""
  fi

  cleanup_stale_secondmate_nudges || return $?

  if [ -n "$pending" ]; then
    process_firstmate_update_journal || journal_status=$?
    if [ "$journal_status" -eq 75 ]; then
      return 75
    elif [ "$journal_status" -eq 2 ]; then
      return 2
    elif [ "$journal_status" -ne 0 ]; then
      journal_failed=1
    fi
  fi

  reread_marker=$(firstmate_reread_marker_path) || return 1
  if [ -e "$reread_marker" ] || [ -L "$reread_marker" ]; then
    action=$(pending_marker_value "$reread_marker" action 2>/dev/null || true)
    path=$(pending_marker_value "$reread_marker" path 2>/dev/null || true)
    if [ "$action" != firstmate-reread ] || [ "$path" != "$FM_ROOT/AGENTS.md" ]; then
      printf 'Firstmate pending reread action is invalid\n' >&2
      return 2
    fi
    printf 'REREAD_REQUIRED: %s/AGENTS.md changed\n' "$FM_ROOT"
    if confirm_firstmate_reread; then
      rm -f -- "$reread_marker" || {
        printf 'Firstmate pending reread action could not be cleared\n' >&2
        return 1
      }
    else
      return 2
    fi
  fi

  if [ -n "$pending" ]; then
    for marker in "$pending"/secondmate-*.pending; do
      if [ -e "$marker" ] || [ -L "$marker" ]; then
        printf 'Firstmate pending selector-only nudge is unsafe: %s\n' "$marker" >&2
        return 2
      fi
    done
  fi

  manifest=$(firstmate_action_manifest_path) || return 1
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    if ! load_firstmate_action_manifest "$manifest"; then
      printf 'Firstmate pending action inventory is invalid\n' >&2
      return 2
    fi
    targets=$PENDING_FIRSTMATE_TARGETS
    if [ "$PENDING_FIRSTMATE_REREAD" = yes ]; then
      printf 'REREAD_REQUIRED: %s/AGENTS.md changed\n' "$FM_ROOT"
      if ! confirm_firstmate_reread; then
        return 2
      fi
      if ! write_firstmate_action_manifest no "$targets"; then
        printf 'Firstmate pending reread action could not be cleared\n' >&2
        return 2
      fi
    fi
    if [ "$targets" != none ]; then
      for selector in $targets; do
        record_status=0
        record_secondmate_nudge_action "$selector" || record_status=$?
        if [ "$record_status" -eq 75 ]; then
          return 75
        elif [ "$record_status" -ne 0 ]; then
          printf 'Firstmate post-update nudge identity no longer matches for %s\n' \
            "$selector" >&2
          failed_targets="${failed_targets}${failed_targets:+ }$selector"
          record_failed=1
        fi
      done
    fi
    if [ "$record_failed" -eq 1 ]; then
      if ! write_firstmate_action_manifest no "$failed_targets"; then
        printf 'Firstmate pending action inventory could not be narrowed safely\n' >&2
        return 1
      fi
    elif ! rm -f -- "$manifest"; then
      printf 'Firstmate pending action inventory could not be cleared\n' >&2
      return 1
    fi
  fi

  process_identity_bound_nudges
  send_status=$?
  if [ "$send_status" -eq 75 ]; then
    return 75
  elif [ "$send_status" -ne 0 ]; then
    send_failed=1
  fi
  [ "$journal_failed" -eq 0 ] && [ "$record_failed" -eq 0 ] && [ "$send_failed" -eq 0 ]
}

validate_firstmate_update_journal_summary() {
  local reread=$1 targets=$2 pending marker selector id
  pending=$(deps_pending_dir) || return 1
  local FM_UPDATE_ACTION_DIR=$pending
  if [ "$reread" = yes ]; then
    marker=$(fm_update_action_firstmate_path) || return 1
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  fi
  if [ "$targets" != none ]; then
    for selector in $targets; do
      id=${selector#fm-}
      marker=$(fm_update_action_secondmate_path "$id") || return 1
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    done
  fi
}

handle_firstmate_update_actions() {
  local update_out=$1 journaled=${2:-no} reread_line nudge_line reread targets selector
  reread_line=$(printf '%s\n' "$update_out" | grep '^reread-firstmate: ' | tail -n 1)
  nudge_line=$(printf '%s\n' "$update_out" | grep '^nudge-secondmates:' | tail -n 1)
  if [ -z "$reread_line" ] || [ -z "$nudge_line" ]; then
    printf 'Firstmate updater did not return its required caller actions\n' >&2
    return 1
  fi
  reread=${reread_line#reread-firstmate: }
  case "$reread" in
    yes|no) ;;
    *) printf 'Firstmate updater returned an invalid reread action\n' >&2; return 1 ;;
  esac
  targets=${nudge_line#nudge-secondmates:}
  targets=${targets# }
  [ -n "$targets" ] || {
    printf 'Firstmate updater returned an invalid secondmate nudge action\n' >&2
    return 1
  }
  if [ "$targets" != none ]; then
    for selector in $targets; do
      case "$selector" in
        fm-*) ;;
        *)
          printf 'Firstmate updater returned an invalid secondmate selector: %s\n' "$selector" >&2
          return 1
          ;;
      esac
      case "${selector#fm-}" in
        ''|*[!A-Za-z0-9._-]*)
          printf 'Firstmate updater returned an invalid secondmate selector: %s\n' "$selector" >&2
          return 1
          ;;
      esac
    done
  fi
  if [ "$journaled" = yes ]; then
    validate_firstmate_update_journal_summary "$reread" "$targets" || {
      printf 'Firstmate updater did not journal its reported caller actions\n' >&2
      return 1
    }
  else
    persist_firstmate_update_actions "$reread" "$targets" || {
      printf 'Firstmate post-update actions could not be recorded\n' >&2
      return 1
    }
  fi
  process_pending_firstmate_actions
}

run_firstmate_upgrade_locked() {
  local firstmate_line update_out update_status update_tmp pending_status
  local journal_dir="" journaled=no
  process_pending_firstmate_actions
  pending_status=$?
  if [ "$pending_status" -ne 0 ]; then
    printf 'Firstmate update deferred until prior post-update actions complete\n' >&2
    return "$pending_status"
  fi
  if [ "$_FM_DEPS_LOADED_SOURCE_ONLY" != 1 ] \
    || [ "${FM_DEPS_TEST_LEGACY_UPDATE_ACTIONS:-0}" != 1 ]; then
    ensure_deps_pending_dir || {
      printf 'Firstmate updater action journal could not be prepared\n' >&2
      return 1
    }
    journal_dir=$(deps_pending_dir) || return 1
    journaled=yes
  fi
  update_tmp=$(mktemp "${TMPDIR:-/tmp}/fm-deps-update.XXXXXX" 2>/dev/null) || {
    printf 'Firstmate updater output could not be captured\n' >&2
    return 1
  }
  update_status=0
  FM_UPDATE_ACTION_DIR="$journal_dir" FM_DEPENDENCY_LOCK_PARENT_PID="${BASHPID:-$$}" \
    "$FM_ROOT/bin/fm-update.sh" >"$update_tmp" 2>&1 || update_status=$?
  update_out=$(< "$update_tmp")
  rm -f "$update_tmp"
  if [ "$update_status" -ne 0 ]; then
    printf '%s\n' "$update_out"
    return 1
  fi
  printf '%s\n' "$update_out"
  handle_firstmate_update_actions "$update_out" "$journaled" || return 1
  firstmate_line=$(printf '%s\n' "$update_out" | grep '^firstmate: ' || true)
  if [ -z "$firstmate_line" ] || [[ "$firstmate_line" == *$'\n'* ]]; then
    printf 'Firstmate updater returned an invalid primary outcome\n' >&2
    return 1
  fi
  case "$firstmate_line" in
    'firstmate: updated '*) FIRSTMATE_UPDATE_RESULT=updated ;;
    'firstmate: already current') FIRSTMATE_UPDATE_RESULT=current ;;
    'firstmate: skipped:'*) FIRSTMATE_UPDATE_RESULT=skipped; return 1 ;;
    *)
      printf 'Firstmate updater returned an invalid primary outcome: %s\n' "$firstmate_line" >&2
      return 1
      ;;
  esac
}

run_upgrade() {
  local id=$1 installed=${2:-} latest=${3:-} lock_status
  case "$id" in
    codex) codex update ;;
    github-cli) run_apt_upgrade gh ;;
    gh-axi|chrome-devtools-axi|lavish-axi|quota-axi|tasks-axi)
      run_npm_upgrade "$id" "$latest"
      ;;
    treehouse) treehouse update ;;
    no-mistakes) no-mistakes update ;;
    herdr) herdr update ;;
    opencode) opencode upgrade --method curl ;;
    tmux) run_apt_upgrade tmux ;;
    node)
      load_nvm || { printf 'NVM is required to upgrade Node safely\n' >&2; return 1; }
      nvm install "$latest" --reinstall-packages-from="$installed" \
        && nvm alias default "$latest"
      ;;
    github-actions) return 1 ;;
    firstmate)
      FIRSTMATE_UPDATE_RESULT=""
      with_firstmate_action_lock run_firstmate_upgrade_locked
      lock_status=$?
      if [ "$lock_status" -eq 75 ]; then
        printf 'Firstmate update deferred because another dependency check is running\n' >&2
      fi
      return "$lock_status"
      ;;
    *) return 1 ;;
  esac
}

offer_update() {
  local id=$1 label=$2 installed=$3 latest=$4 class=$5 blocker="" blocker_status
  if ! version_is_older "$installed" "$latest"; then
    printf 'OK: %s %s\n' "$label" "$installed"
    return 0
  fi
  AVAILABLE=$((AVAILABLE + 1))
  printf 'UPDATE: %s %s -> %s' "$label" "$installed" "$latest"
  [ "$class" = quiet ] && printf ' [quiet window]'
  printf '\n'

  if [ "$class" = quiet ]; then
    blocker=$(quiet_window_blocker "$id")
    blocker_status=$?
    if [ "$blocker_status" -ne 1 ]; then
      [ -n "$blocker" ] || blocker='quiet-window inspection failed'
      printf 'DEFER: %s - %s\n' "$label" "$blocker"
      DEFERRED=$((DEFERRED + 1))
      return 0
    fi
  fi
  if prompt_yes "$label"; then
    if [ "$class" = quiet ]; then
      blocker=$(quiet_window_blocker "$id")
      blocker_status=$?
      if [ "$blocker_status" -ne 1 ]; then
        [ -n "$blocker" ] || blocker='quiet-window inspection failed'
        printf 'DEFER: %s - %s\n' "$label" "$blocker"
        DEFERRED=$((DEFERRED + 1))
        return 0
      fi
    fi
    if run_upgrade "$id" "$installed" "$latest"; then
      printf 'UPGRADED: %s\n' "$label"
      UPDATES=$((UPDATES + 1))
    else
      printf 'FAILED: %s upgrade command failed\n' "$label" >&2
      FAILURES=$((FAILURES + 1))
    fi
  fi
}

check_npm_tool() {
  local id=$1 label=$2 command_name=$3 installed latest hook_incomplete=0
  if ! installed=$(command_version "$command_name") || [ -z "$installed" ]; then
    printf 'MISSING: %s (%s)\n' "$label" "$command_name"
    return 0
  fi
  if ! latest=$(npm_latest "$id") || [ -z "$latest" ]; then
    printf 'UNKNOWN: %s %s; npm registry check failed\n' "$label" "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  if npm_hook_marker_path "$id" >/dev/null 2>&1 \
    && ! retry_pending_npm_hook "$id" "$label" "$command_name" "$installed" "$latest"; then
    hook_incomplete=1
  fi
  offer_update "$id" "$label" "$installed" "$latest" normal
  if [ "$hook_incomplete" -eq 1 ] && npm_hook_action_pending "$id"; then
    FAILURES=$((FAILURES + 1))
  fi
}

check_apt_package() {
  local id=$1 label=$2 package=$3 class=$4 versions installed latest
  if ! versions=$(apt_package_versions "$package") || [[ "$versions" != *$'\t'* ]]; then
    printf 'UNKNOWN: %s; APT metadata check failed\n' "$label"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  installed=${versions%%$'\t'*}
  latest=${versions#*$'\t'}
  if [ -z "$installed" ]; then
    printf 'MISSING: %s (sudo apt-get install %s)\n' "$label" "$package"
  elif [ -z "$latest" ]; then
    printf 'UNKNOWN: %s %s; APT candidate check failed\n' "$label" "$installed"
    FAILURES=$((FAILURES + 1))
  else
    offer_update "$id" "$label" "$installed" "$latest" "$class"
  fi
}

check_release_tool() {
  local id=$1 label=$2 command_name=$3 repo=$4 class=$5 installed latest
  if ! installed=$(command_version "$command_name") || [ -z "$installed" ]; then
    printf 'MISSING: %s (%s)\n' "$label" "$command_name"
    return 0
  fi
  if ! latest=$(release_latest "$repo") || [ -z "$latest" ]; then
    printf 'UNKNOWN: %s %s; stable release check failed\n' "$label" "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  offer_update "$id" "$label" "$installed" "$latest" "$class"
}

check_herdr() {
  local installed latest
  if ! installed=$(command_version herdr) || [ -z "$installed" ]; then
    printf 'MISSING: Herdr (instructions: https://herdr.dev)\n'
    return 0
  fi
  if ! latest=$(herdr_latest) || [ -z "$latest" ]; then
    printf 'UNKNOWN: Herdr %s; stable manifest check failed\n' "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  offer_update herdr Herdr "$installed" "$latest" quiet
}

check_node() {
  local installed latest
  if ! installed=$(command_version node) || [ -z "$installed" ]; then
    printf 'MISSING: Node (install with NVM)\n'
    return 0
  fi
  if ! nvm_manages_active_node; then
    printf 'MANUAL: Node %s is not NVM-managed; update it with its owning package manager\n' "$installed"
    return 0
  fi
  if ! latest=$(node_latest_same_major "$installed") || [ -z "$latest" ]; then
    printf 'UNKNOWN: Node %s; same-major LTS release check failed\n' "$installed"
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  offer_update node "Node ${installed%%.*}" "$installed" "$latest" quiet
}

check_zellij() {
  local installed latest
  if ! installed=$(command_version zellij) || [ -z "$installed" ]; then
    printf 'MISSING: Zellij (optional; install from https://zellij.dev)\n'
    return 0
  fi
  if ! latest=$(release_latest zellij-org/zellij) || [ -z "$latest" ]; then
    printf 'UNKNOWN: Zellij %s; stable release check failed\n' "$installed"
    FAILURES=$((FAILURES + 1))
  elif version_is_older "$installed" "$latest"; then
    printf 'MANUAL: Zellij %s -> %s; update it with its owning package manager\n' "$installed" "$latest"
    AVAILABLE=$((AVAILABLE + 1))
  else
    printf 'OK: Zellij %s\n' "$installed"
  fi
}

check_shellcheck_pin() {
  local installed required
  required=$(run_probe "$FM_ROOT/bin/fm-lint.sh" --required-version 2>/dev/null \
    || printf '0.11.0')
  if ! installed=$(command_version shellcheck) || [ -z "$installed" ]; then
    printf 'MISSING: ShellCheck (repository requires %s)\n' "$required"
  elif [ "$installed" = "$required" ]; then
    printf 'OK: ShellCheck %s (repository pin)\n' "$installed"
  else
    printf 'PIN_MISMATCH: ShellCheck %s; repository requires %s (not auto-upgraded)\n' "$installed" "$required"
  fi
}

check_github_actions() {
  local latest major pins
  if ! latest=$(release_latest actions/checkout) || [ -z "$latest" ]; then
    printf 'UNKNOWN: actions/checkout; stable release check failed\n'
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  major=${latest%%.*}
  pins=$(grep -Rho 'actions/checkout@v[0-9][0-9]*' "$FM_ROOT/.github/workflows" 2>/dev/null \
    | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  if [ -z "$pins" ]; then
    printf 'OK: actions/checkout has no workflow call sites\n'
  elif [ "$pins" = "actions/checkout@v$major" ]; then
    printf 'OK: actions/checkout %s (latest stable %s)\n' "$pins" "$latest"
  else
    printf 'REPO_UPDATE: %s -> actions/checkout@v%s (latest %s); create a normal repository PR\n' "$pins" "$major" "$latest"
    AVAILABLE=$((AVAILABLE + 1))
  fi
}

check_firstmate() {
  local branch branch_out local_sha remote_sha status_out pending_status
  if branch_out=$(run_git_probe -C "$FM_ROOT" symbolic-ref --short \
    refs/remotes/origin/HEAD 2>/dev/null); then
    branch=${branch_out#origin/}
  else
    branch=main
  fi
  [ -n "$branch" ] || branch=main
  if ! local_sha=$(run_git_probe -C "$FM_ROOT" rev-parse HEAD 2>/dev/null); then
    printf 'UNKNOWN: Firstmate checkout is not a Git repository\n'
    FAILURES=$((FAILURES + 1))
    return 0
  fi
  remote_sha=$(run_git_probe -C "$FM_ROOT" ls-remote origin "refs/heads/$branch" \
    2>/dev/null | awk 'NR == 1 {print $1}')
  if [ -z "$remote_sha" ]; then
    printf 'UNKNOWN: Firstmate %s; origin/%s check failed\n' "$(printf '%.12s' "$local_sha")" "$branch"
    FAILURES=$((FAILURES + 1))
  elif [ "$local_sha" = "$remote_sha" ]; then
    printf 'OK: Firstmate %s\n' "$(printf '%.12s' "$local_sha")"
  else
    printf 'UPDATE: Firstmate %s -> origin/%s %s [guarded fast-forward]\n' \
      "$(printf '%.12s' "$local_sha")" "$branch" "$(printf '%.12s' "$remote_sha")"
    AVAILABLE=$((AVAILABLE + 1))
    firstmate_update_actions_pending
    pending_status=$?
    case "$pending_status" in
      0)
        printf 'DEFER: Firstmate - previous post-update actions remain incomplete; complete them and rerun\n'
        DEFERRED=$((DEFERRED + 1))
        return 0
        ;;
      1) ;;
      *)
        printf 'DEFER: Firstmate - pending action storage is invalid; repair it and rerun\n'
        DEFERRED=$((DEFERRED + 1))
        return 0
        ;;
    esac
    if ! status_out=$(run_git_probe -C "$FM_ROOT" status --porcelain 2>/dev/null); then
      printf 'DEFER: Firstmate - checkout status inspection failed; rerun when Git is responsive\n'
      DEFERRED=$((DEFERRED + 1))
      return 0
    fi
    if [ -n "$status_out" ]; then
      printf 'DEFER: Firstmate - working tree is not clean; commit or remove local changes, then rerun\n'
      DEFERRED=$((DEFERRED + 1))
      return 0
    fi
    if [ "$(run_git_probe -C "$FM_ROOT" symbolic-ref --short HEAD 2>/dev/null || true)" != "$branch" ]; then
      printf 'DEFER: Firstmate - checkout is not on %s; switch back safely, then rerun\n' "$branch"
      DEFERRED=$((DEFERRED + 1))
      return 0
    fi
    if prompt_yes Firstmate; then
      if run_upgrade firstmate; then
        case "$FIRSTMATE_UPDATE_RESULT" in
          updated)
            printf 'UPGRADED: Firstmate\n'
            UPDATES=$((UPDATES + 1))
            ;;
          current)
            printf 'CURRENT: Firstmate became current before the guarded update completed\n'
            AVAILABLE=$((AVAILABLE - 1))
            ;;
          *)
            printf 'FAILED: Firstmate updater returned no successful outcome\n' >&2
            FAILURES=$((FAILURES + 1))
            ;;
        esac
      else
        printf 'FAILED: Firstmate guarded update failed or was skipped\n' >&2
        FAILURES=$((FAILURES + 1))
      fi
    fi
  fi
}

run_dependency_check_body() {
  local pending_action_status
  if [ "$CHECK_ONLY" -eq 0 ] && ! is_interactive; then
    printf 'INFO: non-interactive shell detected; running checks without upgrade prompts\n'
  fi

  printf 'AI workspace dependency check (Linux)\n'
  printf '%s\n' '----------------------------------------'

  if [ "$CHECK_ONLY" -eq 1 ]; then
    firstmate_update_actions_pending
    pending_action_status=$?
    if [ "$pending_action_status" -eq 0 ]; then
      printf 'DEFER: dependency check - Firstmate post-update actions remain pending; rerun without --check\n'
      DEFERRED=$((DEFERRED + 1))
    elif [ "$pending_action_status" -eq 2 ]; then
      printf 'FAILED: Firstmate pending action storage is invalid\n' >&2
      return 1
    elif [ "$pending_action_status" -ne 1 ]; then
      printf 'FAILED: Firstmate pending actions could not be inspected\n' >&2
      return 1
    fi
  else
    with_firstmate_action_lock process_pending_firstmate_actions
    pending_action_status=$?
    if [ "$pending_action_status" -eq 75 ]; then
      printf 'DEFER: dependency check - Firstmate actions are being processed; retry later\n'
      printf '%s\n' '----------------------------------------'
      printf 'SUMMARY: 0 update(s) available; 0 completed; 1 deferred; 0 check/upgrade failure(s)\n'
      return 0
    elif [ "$pending_action_status" -eq 2 ]; then
      printf 'FAILED: required Firstmate instruction reread remains incomplete\n' >&2
      return 1
    elif [ "$pending_action_status" -eq 3 ]; then
      printf 'FAILED: Firstmate pending action storage is invalid\n' >&2
      return 1
    elif [ "$pending_action_status" -ne 0 ]; then
      printf 'FAILED: Firstmate post-update actions remain incomplete\n' >&2
      FAILURES=$((FAILURES + 1))
    fi
  fi

  check_release_tool codex Codex codex openai/codex quiet
  check_apt_package github-cli 'GitHub CLI' gh normal
  check_npm_tool gh-axi gh-axi gh-axi
  check_npm_tool chrome-devtools-axi chrome-devtools-axi chrome-devtools-axi
  check_npm_tool lavish-axi lavish-axi lavish-axi
  check_npm_tool quota-axi quota-axi quota-axi
  check_npm_tool tasks-axi tasks-axi tasks-axi
  check_release_tool no-mistakes no-mistakes no-mistakes kunchenguid/no-mistakes normal
  check_release_tool treehouse Treehouse treehouse kunchenguid/treehouse normal
  check_herdr
  check_release_tool opencode OpenCode opencode anomalyco/opencode quiet
  check_apt_package tmux tmux tmux quiet
  check_node
  check_zellij
  check_shellcheck_pin
  check_github_actions
  check_firstmate

  printf '%s\n' '----------------------------------------'
  printf 'SUMMARY: %s update(s) available; %s completed; %s deferred; %s check/upgrade failure(s)\n' \
    "$AVAILABLE" "$UPDATES" "$DEFERRED" "$FAILURES"
  [ "$FAILURES" -eq 0 ]
}

run_dependency_check() {
  local run_status
  if [ "${FM_DEPS_RUN_LOCKED:-0}" = 1 ] && [ "${FM_DEPS_SOURCE_ONLY:-0}" != 1 ]; then
    fm_dependency_resume_host_lock run_dependency_check_body
  elif [ "${FM_DEPS_SOURCE_ONLY:-0}" = 1 ]; then
    fm_dependency_with_host_lock run_dependency_check_body
  else
    fm_dependency_with_host_lock exec_current_dependency_checker
  fi
  run_status=$?
  if [ "$run_status" -eq 75 ]; then
    if [ "$CHECK_ONLY" -eq 0 ] && ! is_interactive; then
      printf 'INFO: non-interactive shell detected; running checks without upgrade prompts\n'
    fi
    printf 'AI workspace dependency check (Linux)\n'
    printf '%s\n' '----------------------------------------'
    printf 'DEFER: dependency check - another invocation is still running; retry later\n'
    printf '%s\n' '----------------------------------------'
    printf 'SUMMARY: 0 update(s) available; 0 completed; 1 deferred; 0 check/upgrade failure(s)\n'
    return 0
  fi
  if [ "$run_status" -eq 2 ]; then
    printf 'fm-deps.sh: host dependency lock is unavailable or invalid\n' >&2
  fi
  return "$run_status"
}

exec_current_dependency_checker() {
  export FM_DEPS_RUN_LOCKED=1
  if [ "$CHECK_ONLY" -eq 1 ]; then
    exec "$SCRIPT_DIR/fm-deps.sh" --check
  else
    exec "$SCRIPT_DIR/fm-deps.sh"
  fi
}

if [ "${FM_DEPS_SOURCE_ONLY:-0}" = 1 ]; then
  # shellcheck disable=SC2317 # exit is the direct-execution fallback; sourcing uses return.
  return 0 2>/dev/null || exit 0
fi

if [ "$(uname -s)" != Linux ]; then
  printf 'fm-deps.sh: this variant supports Linux only\n' >&2
  exit 1
fi
if ! probe_timeout_is_valid; then
  printf 'fm-deps.sh: FM_DEPS_PROBE_TIMEOUT must be a positive integer\n' >&2
  exit 1
fi
if ! fm_dependency_lock_timeout_is_valid; then
  printf 'fm-deps.sh: FM_DEPS_LOCK_TIMEOUT must be a positive integer\n' >&2
  exit 1
fi
for required_command in dpkg dpkg-query apt-cache; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'fm-deps.sh: Debian/Ubuntu command %s is required\n' "$required_command" >&2
    exit 1
  fi
done

run_dependency_check
