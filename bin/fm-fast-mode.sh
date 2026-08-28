#!/usr/bin/env bash
# fm-fast-mode.sh - bring one project up as a single clickable local instance,
# and take it down again.
#
# Usage:
#   fm-fast-mode.sh up <task-id> [<config-name>]
#   fm-fast-mode.sh stop
#   fm-fast-mode.sh --help
#
# Run it from the root of the task's isolated worktree. `up` starts a backend, a
# frontend dev server, and a same-origin proxy in front of both, records the
# ports it actually used in <worktree>/.fast-mode/ports, and registers them in
# the background-task ledger (bin/fm-bg-registry.sh) so a recycled worktree
# still leaves an auditable trail. `stop` kills only the ports in that file.
#
# The per-project part - machine paths, project-private commands, credentials
# sources - lives in a LOCAL, untracked config file, so only the logic is shared:
#
#   $FM_HOME/config/fast-mode/<name>.sh
#
# <name> defaults to the basename of the worktree's `origin` remote, so a
# worktree of ai-lesson-plan-mvp finds ai-lesson-plan-mvp.sh with no argument.
# Start one by copying docs/examples/fast-mode-config.sh.
#
# The config is sourced by this script and may set:
#   FAST_PREF_API FAST_PREF_WEB FAST_PREF_PROXY   preferred ports (required)
#   FAST_PRIMARY        primary checkout path; running there is refused
#   FAST_REQUIRE_DIRS   space-separated dirs that must exist in the worktree
#   FAST_WEB_CACHE      space-separated build-cache paths cleared before start
#   FAST_API_PREFIX     request prefix routed to the backend (default /api/)
#   FAST_READY_PATH     path polled until the instance answers (default /)
#   FAST_READY_TIMEOUT  seconds to wait for that (default 120)
# and must define:
#   fast_start_api      start the backend on $FAST_API_PORT
#   fast_start_web      start the frontend dev server on $FAST_WEB_PORT
#   fast_prepare        optional, runs first: env files, credentials, deps
#
# Hooks run with $FAST_WT (worktree root), $FAST_RUN (log and scratch dir),
# $FAST_TASK, the three chosen ports, and $FAST_ORIGIN exported, and can call
# `fast_bg <log-name> <cmd>...` to background a command with its log in
# $FAST_RUN.
#
# Three environment lessons are wired in here rather than left to each config,
# because each one cost a debugging session:
#
#   1. Ports bump, they never preempt. A busy preferred port is skipped, never
#      killed - the captain may be running their own instance on it - and `stop`
#      only touches the ports this worktree recorded.
#   2. $FAST_ORIGIN is the browser-visible origin (the proxy), not the dev server
#      port. Give it to the backend as the allowed origin: getting that wrong
#      looks like a broken feature, because pages load fine while every write is
#      rejected.
#   3. $FAST_WEB_CACHE is cleared before the frontend starts. Worktrees are
#      recycled, the previous task's gitignored build cache survives in them, and
#      the page then reports a missing file that is plainly there.
#
# A same-origin proxy is the default shape because backends commonly hand out
# site-relative asset paths; served from two ports those assets 404 in the
# browser.
set -euo pipefail

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fast-mode"
TEMPLATE="$FM_ROOT/docs/examples/fast-mode-config.sh"
REGISTRY="$FM_ROOT/bin/fm-bg-registry.sh"
PROXY_JS="$FM_ROOT/bin/fm-fast-proxy.js"

FAST_WT="$(pwd)"
FAST_RUN="$FAST_WT/.fast-mode"
PORTS_FILE="$FAST_RUN/ports"

usage() {
  awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"
}

die() {
  printf 'fm-fast-mode: %s\n' "$1" >&2
  exit 1
}

port_busy() { lsof -ti "tcp:$1" >/dev/null 2>&1; }

# Bump past a busy port, never kill its owner: it is very often the captain's own
# instance, and a silent kill is indistinguishable from their app crashing.
pick_port() {
  local p=$1 _
  for _ in $(seq 0 20); do
    port_busy "$p" || { printf '%s\n' "$p"; return 0; }
    p=$((p + 1))
  done
  die "no free port in $1..$((p - 1))"
}

stop_recorded() {
  [ -f "$PORTS_FILE" ] || { echo "no fast-mode instance recorded in $FAST_WT"; return 0; }
  local name port pids
  while read -r name port; do
    [ -n "${port:-}" ] || continue
    pids=$(lsof -ti "tcp:$port" 2>/dev/null || true)
    if [ -n "$pids" ]; then
      # shellcheck disable=SC2086
      kill $pids 2>/dev/null || true
      echo "stopped $name :$port"
    fi
  done <"$PORTS_FILE"
  rm -f "$PORTS_FILE"
}

config_name_from_origin() {
  local url
  url=$(git -C "$FAST_WT" remote get-url origin 2>/dev/null) || return 1
  [ -n "$url" ] || return 1
  basename "${url%.git}"
}

no_config() { # <name> <path>
  cat >&2 <<EOF
fm-fast-mode: no fast-mode config for '$1'.

  expected: $2
  template: $TEMPLATE

Configs stay local and untracked because they carry machine paths and
project-private commands; only the logic in bin/ is shared. Create one with:

  mkdir -p '$CONFIG_DIR'
  cp '$TEMPLATE' '$2'
  \$EDITOR '$2'

Then run this command again, or pass another config name as the third argument.
EOF
  exit 1
}

fast_bg() { # <log-name> <cmd>...
  local name=$1
  shift
  ( nohup "$@" >"$FAST_RUN/$name.log" 2>&1 & )
}

cmd_up() {
  local task=${1:-} name=${2:-} config
  [ -n "$task" ] || die "up needs a task id: fm-fast-mode.sh up <task-id>"
  [ -n "$name" ] || name=${FM_FAST_MODE_CONFIG:-$(config_name_from_origin || true)}
  [ -n "$name" ] || die "no config name given and no origin remote to derive one from"
  config="$CONFIG_DIR/$name.sh"
  [ -f "$config" ] || no_config "$name" "$config"

  # shellcheck disable=SC1090
  . "$config"

  local hook
  for hook in fast_start_api fast_start_web; do
    declare -F "$hook" >/dev/null || die "$config defines no $hook (see $TEMPLATE)"
  done
  local pref
  for pref in FAST_PREF_API FAST_PREF_WEB FAST_PREF_PROXY; do
    [ -n "${!pref:-}" ] || die "$config sets no $pref (see $TEMPLATE)"
  done
  if [ -n "${FAST_PRIMARY:-}" ] && [ "$FAST_WT" = "${FAST_PRIMARY%/}" ]; then
    die "this is the primary checkout; run in the task's isolated worktree instead"
  fi
  local dir
  for dir in ${FAST_REQUIRE_DIRS:-}; do
    [ -d "$FAST_WT/$dir" ] || die "no $dir/ here - run from the $name worktree root (now: $FAST_WT)"
  done

  mkdir -p "$FAST_RUN"
  stop_recorded >/dev/null 2>&1 || true

  FAST_API_PORT=$(pick_port "$FAST_PREF_API")
  FAST_WEB_PORT=$(pick_port "$FAST_PREF_WEB")
  FAST_PROXY_PORT=$(pick_port "$FAST_PREF_PROXY")
  printf 'api %s\nweb %s\nproxy %s\n' "$FAST_API_PORT" "$FAST_WEB_PORT" "$FAST_PROXY_PORT" >"$PORTS_FILE"
  "$REGISTRY" add "$task" port "$FAST_API_PORT" "fast-mode backend ($name)" >/dev/null
  "$REGISTRY" add "$task" port "$FAST_WEB_PORT" "fast-mode frontend dev ($name)" >/dev/null
  "$REGISTRY" add "$task" port "$FAST_PROXY_PORT" "fast-mode same-origin proxy ($name)" >/dev/null
  local role prefer chosen
  for pref in "api $FAST_PREF_API $FAST_API_PORT" "web $FAST_PREF_WEB $FAST_WEB_PORT" \
    "proxy $FAST_PREF_PROXY $FAST_PROXY_PORT"; do
    read -r role prefer chosen <<<"$pref"
    [ "$prefer" = "$chosen" ] || echo "note: $role port $prefer is busy, using $chosen instead"
  done

  FAST_TASK=$task
  FAST_ORIGIN="http://localhost:$FAST_PROXY_PORT"
  export FAST_WT FAST_RUN FAST_TASK FAST_API_PORT FAST_WEB_PORT FAST_PROXY_PORT FAST_ORIGIN

  if declare -F fast_prepare >/dev/null; then
    fast_prepare
  fi

  local cache
  for cache in ${FAST_WEB_CACHE:-}; do
    rm -rf "${FAST_WT:?}/$cache"
  done

  echo "starting backend :$FAST_API_PORT ..."
  fast_start_api
  echo "starting frontend :$FAST_WEB_PORT ..."
  fast_start_web
  echo "starting proxy :$FAST_PROXY_PORT ..."
  FAST_API_PREFIX=${FAST_API_PREFIX:-/api/}
  export FAST_API_PREFIX
  fast_bg proxy node "$PROXY_JS"

  local waited=0 limit=${FAST_READY_TIMEOUT:-120}
  echo "waiting for $FAST_ORIGIN${FAST_READY_PATH:-/} ..."
  while [ "$waited" -lt "$limit" ]; do
    if curl -fsS -o /dev/null --max-time 5 "$FAST_ORIGIN${FAST_READY_PATH:-/}" 2>/dev/null; then
      echo
      echo "  ready -> $FAST_ORIGIN"
      echo "  logs:  $FAST_RUN/*.log"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  die "started but not ready within ${limit}s; see $FAST_RUN/*.log"
}

case "${1:-}" in
  up) shift; cmd_up "$@" ;;
  stop) stop_recorded ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
