#!/usr/bin/env bash
# Provision a freshly-cut crewmate/scout worktree so it is run-ready: copy the
# project's canonical (gitignored, never-in-GitHub) env AND credential/key files
# into the worktree and install its dependencies. Driven by a per-project,
# fleet-LOCAL config so provisioning is strictly opt-in: a project with no config
# is a silent no-op.
#
# Usage: fm-provision-worktree.sh <project> <worktree-path>
#
# Config location (personal fleet state, gitignored - see .gitignore):
#   config/provision/<project>.toml
# where <project> is the registered project name (the projects/<name> basename
# fm-spawn passes). See docs/examples/provision.toml for a documented template
# and AGENTS.md "Worktree provisioning" for the full contract.
#
# Config format (a minimal TOML subset, parsed here without a TOML dependency):
#   env_source_dir = "~/Documents/Code/question-wheel"   # absolute source dir; a
#                                                         # leading ~ / ~/ expands to $HOME
#   env_files = [".env", "backend/.env", "backend/key.json"] # single-line array of
#                                                         # repo-relative paths to copy;
#                                                         # each preserves its relative
#                                                         # path. A general files-to-copy
#                                                         # list, not just .env: include
#                                                         # any credential/key file a .env
#                                                         # references (e.g. a service-
#                                                         # account JSON) so the worktree
#                                                         # backend can actually start.
#   setup_cmd = "npm install && (cd backend && npm install)"  # run in the worktree root
#   setup_timeout = 600  # optional; positive integer seconds bounding setup_cmd
# Blank lines and lines starting with # are ignored. Keys may be quoted with
# single or double quotes. env_files must be a single-line array.
#
# setup_cmd is bounded by a timeout so a hanging/interactive install can never
# block a spawn indefinitely (best-effort intent). The bound defaults to 600s.
# Precedence: env FM_PROVISION_SETUP_TIMEOUT overrides the per-project
# setup_timeout config key, which overrides the 600s default. Only a positive
# integer number of seconds is accepted; an invalid/empty value warns and falls
# back to the default. On expiry the whole setup process group is killed and the
# timeout is treated as a best-effort failure (rc=1), never an abort.
#
# Behavior:
#   - No config for <project>: exit 0 silently (provisioning is opt-in per project).
#   - Copy each listed env file, preserving its relative path (parent dirs created).
#     A source file that does not exist is skipped with a noted warning, not a failure.
#     Env file CONTENTS are never read or printed - only cp'd and named.
#   - Run setup_cmd in the worktree root, bounded by setup_timeout.
#   - Progress goes to stderr. Idempotent (overwriting copies, re-runnable installs).
#   - Exit non-zero only on a real failure: the configured env_source_dir is missing,
#     a present source file fails to copy, or setup_cmd exits non-zero or times out.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

PROJECT=${1:?usage: fm-provision-worktree.sh <project> <worktree-path>}
WT=${2:?usage: fm-provision-worktree.sh <project> <worktree-path>}

CONFIG_FILE="$CONFIG/provision/$PROJECT.toml"
# Opt-in: no config means nothing to provision. Silent no-op.
[ -f "$CONFIG_FILE" ] || exit 0

if [ ! -d "$WT" ]; then
  echo "provision[$PROJECT]: worktree path does not exist: $WT" >&2
  exit 1
fi

log() { echo "provision[$PROJECT]: $*" >&2; }

# Strip a single pair of surrounding matching quotes from a value.
dequote() {
  local v=$1
  case "$v" in
    '"'*'"') v=${v#\"}; v=${v%\"} ;;
    "'"*"'") v=${v#\'}; v=${v%\'} ;;
  esac
  printf '%s' "$v"
}

# Trim leading and trailing whitespace.
trim() {
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  printf '%s' "$v"
}

ENV_SOURCE_DIR=
SETUP_CMD=
SETUP_TIMEOUT_CONFIG=
ENV_FILES=()

parse_array() {  # <bracketed-array-value> -> appends to ENV_FILES
  local v=$1 elem
  v=$(trim "$v")
  v=${v#\[}
  v=${v%\]}
  local IFS=','
  # shellcheck disable=SC2206  # deliberate comma-split of a config array line
  local parts=($v)
  for elem in ${parts[@]+"${parts[@]}"}; do
    elem=$(trim "$elem")
    elem=$(dequote "$elem")
    [ -n "$elem" ] && ENV_FILES+=("$elem")
  done
}

line=
while IFS= read -r line || [ -n "$line" ]; do
  line=$(trim "$line")
  case "$line" in
    ''|'#'*) continue ;;
    *=*) : ;;
    *) continue ;;
  esac
  key=$(trim "${line%%=*}")
  val=$(trim "${line#*=}")
  case "$key" in
    env_source_dir) ENV_SOURCE_DIR=$(dequote "$val") ;;
    setup_cmd) SETUP_CMD=$(dequote "$val") ;;
    setup_timeout) SETUP_TIMEOUT_CONFIG=$(dequote "$val") ;;
    env_files) parse_array "$val" ;;
    *) log "ignoring unknown config key: $key" ;;
  esac
done < "$CONFIG_FILE"

# Expand a leading ~ / ~/ in env_source_dir to $HOME (strip the leading ~, then
# prepend $HOME; done this way so no literal tilde sits inside a parameter
# expansion, where it would never expand anyway).
# shellcheck disable=SC2088  # the ~ here is a literal pattern to MATCH, not to expand
case "$ENV_SOURCE_DIR" in
  '~') ENV_SOURCE_DIR=$HOME ;;
  '~/'*) ENV_SOURCE_DIR=$HOME${ENV_SOURCE_DIR#\~} ;;
esac

rc=0

# --- copy env files ---------------------------------------------------------
if [ "${#ENV_FILES[@]}" -gt 0 ]; then
  if [ -z "$ENV_SOURCE_DIR" ]; then
    log "env_files listed but env_source_dir is not set; skipping env copy"
    rc=1
  elif [ ! -d "$ENV_SOURCE_DIR" ]; then
    log "env_source_dir does not exist: $ENV_SOURCE_DIR; skipping env copy"
    rc=1
  else
    for rel in "${ENV_FILES[@]}"; do
      # Guard against a config typo escaping the worktree (or the source dir):
      # entries must be plain relative paths, never absolute and never with `..`.
      case "$rel" in
        /*|*/../*|../*|*/..|..)
          log "refusing unsafe env_files entry (absolute or contains ..): $rel"
          rc=1
          continue
          ;;
      esac
      src="$ENV_SOURCE_DIR/$rel"
      dst="$WT/$rel"
      if [ ! -f "$src" ]; then
        log "source file missing, skipping: $rel"
        continue
      fi
      if ! mkdir -p "$(dirname "$dst")" 2>/dev/null; then
        log "failed to create parent dir for: $rel"
        rc=1
        continue
      fi
      # Copy only - never read or echo the file's contents.
      if cp "$src" "$dst" 2>/dev/null; then
        log "copied file: $rel"
      else
        log "failed to copy file: $rel"
        rc=1
      fi
    done
  fi
fi

# --- run setup command ------------------------------------------------------

# A positive integer (in seconds) or nothing.
is_positive_int() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

# Resolve the setup_cmd timeout: FM_PROVISION_SETUP_TIMEOUT env, then the
# per-project setup_timeout config key, then a 600s default. An invalid value at
# either level warns and falls back to the default.
resolve_setup_timeout() {
  local default=600
  if [ -n "${FM_PROVISION_SETUP_TIMEOUT:-}" ]; then
    if is_positive_int "$FM_PROVISION_SETUP_TIMEOUT"; then
      printf '%s' "$FM_PROVISION_SETUP_TIMEOUT"; return 0
    fi
    log "invalid FM_PROVISION_SETUP_TIMEOUT (not a positive integer); using ${default}s"
    printf '%s' "$default"; return 0
  fi
  if [ -n "$SETUP_TIMEOUT_CONFIG" ]; then
    if is_positive_int "$SETUP_TIMEOUT_CONFIG"; then
      printf '%s' "$SETUP_TIMEOUT_CONFIG"; return 0
    fi
    log "invalid setup_timeout in config (not a positive integer); using ${default}s"
    printf '%s' "$default"; return 0
  fi
  printf '%s' "$default"
}

# Run setup_cmd bounded by <timeout> seconds. Portable (no timeout/gtimeout
# binary): job control makes the backgrounded subshell its own process-group
# leader, so on expiry the WHOLE group (setup_cmd plus any children it spawned)
# is signalled. Returns the command's exit status, or 1 on timeout.
run_setup_with_timeout() {
  local timeout=$1 pid pgid waited=0
  set -m
  ( cd "$WT" && bash -c "$SETUP_CMD" ) &
  pid=$!
  set +m
  pgid=$pid  # job control put the subshell in its own group, led by its own pid
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      log "setup_cmd exceeded ${timeout}s timeout; killed"
      kill -TERM -"$pgid" 2>/dev/null || true
      sleep 2
      kill -KILL -"$pgid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

if [ -n "$SETUP_CMD" ]; then
  SETUP_TIMEOUT=$(resolve_setup_timeout)
  log "running setup in worktree root (timeout ${SETUP_TIMEOUT}s)"
  if run_setup_with_timeout "$SETUP_TIMEOUT"; then
    log "setup complete"
  else
    log "setup_cmd failed"
    rc=1
  fi
fi

exit "$rc"
