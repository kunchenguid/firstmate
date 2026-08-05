#!/usr/bin/env bash
# Fail-closed guard for per-task chrome-devtools-axi browser-session isolation.
#
# chrome-devtools-axi isolates concurrent browser work by the name in
# CHROME_DEVTOOLS_AXI_SESSION and defaults that name to "default". So an agent
# that never sets it silently JOINS one shared browser instance, inheriting the
# tabs, cookies, and authenticated state of every other agent on that default
# session. That exact condition caused a crewmate to see a real production
# account belonging to a different concurrent task. The upstream default cannot
# be changed from here, so this guard supplies the missing refusal: an
# unisolated browser command aborts instead of running shared.
#
# Two entry shapes, one decision owner:
#   As bin/shims/chrome-devtools-axi (a symlink to this script), it is a
#   transparent PATH shim: it enforces, then exec's the real chrome-devtools-axi
#   found further along PATH. bin/fm-spawn.sh puts that shim directory on every
#   spawned agent's PATH, so an agent's ordinary `chrome-devtools-axi ...` call
#   is checked without the agent doing anything.
#   As bin/fm-browser-session-guard.sh it exposes the same decision as a CLI for
#   preflight checks and tests.
#
# See docs/browser-session-isolation.md for the complete contract, the scope
# rules, the deliberate residual gap, and the validation record.
#
# Usage:
#   chrome-devtools-axi <args>...              (via the shim symlink)
#   bin/fm-browser-session-guard.sh check [<chrome-devtools-axi args>...]
#   bin/fm-browser-session-guard.sh exec <chrome-devtools-axi args>...
#   bin/fm-browser-session-guard.sh --help
#
# Exit contract:
#   0  ALLOW    - isolation present, or the invocation drives no browser session,
#                 or the guard is INERT for this context.
#   1  REFUSE   - a browser-driving invocation with no per-task session. The
#                 reason goes to stderr; `exec`/shim mode never runs the tool.
#   2  USAGE    - the guard itself was called wrongly, or (in exec/shim mode) the
#                 real chrome-devtools-axi could not be resolved.
#
# INERT contexts, so legitimate shared use keeps working:
#   - FM_BROWSER_SHARED_SESSION_OK=1 declares deliberate shared-session use.
#   - The working directory is a genuine firstmate primary home, which is
#     firstmate's own session rather than a task-scoped agent.
set -u

GUARD_SELF=${BASH_SOURCE[0]}
REAL_TOOL=chrome-devtools-axi

# Physical path of a file with its symlinks followed, so the shim symlink and
# the script it points at compare equal. Bounded so a symlink cycle cannot hang
# a guard that sits in front of every browser command.
guard_resolve_path() {
  local target=$1 dir link hops=0
  while [ -L "$target" ] && [ "$hops" -lt 32 ]; do
    link=$(readlink "$target") || return 1
    case "$link" in
      /*) target=$link ;;
      *) target=$(dirname "$target")/$link ;;
    esac
    hops=$((hops + 1))
  done
  dir=$(cd "$(dirname "$target")" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "$dir/$(basename "$target")"
}

# Where this script really lives, which is where its sibling libraries are,
# even when it was invoked through bin/shims/chrome-devtools-axi.
GUARD_REAL=$(guard_resolve_path "$GUARD_SELF") || GUARD_REAL=$GUARD_SELF
GUARD_DIR=$(dirname "$GUARD_REAL")

# Subcommands that report or install rather than drive a browser session. They
# stay usable without isolation so `--help`, version probes, and the bootstrap
# hook install never depend on a task binding.
guard_command_is_sessionless() {
  case "${1-}" in
    ''|--help|-h|help|-v|-V|--version|setup) return 0 ;;
    *) return 1 ;;
  esac
}

# A session name that actually isolates: set, non-blank, and not the shared
# upstream default.
guard_session_isolated() {
  local session=${CHROME_DEVTOOLS_AXI_SESSION-}
  session=${session//[[:space:]]/}
  [ -n "$session" ] || return 1
  [ "$session" != default ] || return 1
  return 0
}

# Firstmate's own primary home browses on the shared session by design; only
# task-scoped agents must be isolated from each other.
guard_context_is_inert() {
  [ "${FM_BROWSER_SHARED_SESSION_OK-}" != 1 ] || return 0
  local scope_lib=$GUARD_DIR/fm-primary-scope-lib.sh
  [ -r "$scope_lib" ] || return 1
  # shellcheck source=bin/fm-primary-scope-lib.sh
  . "$scope_lib" || return 1
  local here
  here=$(pwd -P 2>/dev/null) || return 1
  fm_primary_scope_matches "$here" "$here/state"
}

guard_refuse() {
  local shown
  if [ -n "${CHROME_DEVTOOLS_AXI_SESSION+set}" ]; then
    shown="set to '${CHROME_DEVTOOLS_AXI_SESSION}'"
  else
    shown="unset"
  fi
  cat >&2 <<EOF
$REAL_TOOL REFUSED: no per-task browser session is set.

CHROME_DEVTOOLS_AXI_SESSION is $shown, so this command would run on the
shared "default" browser session together with every other agent working right
now - inheriting their tabs, cookies, and signed-in accounts. That has already
caused one task to act on another task's real production account, so the
command is refused rather than run shared.

Fix it by binding this task's own session before running the command again:
  export CHROME_DEVTOOLS_AXI_SESSION=<this task's id>
The task id is the one in your status-file path. If a supervisor relaunched
this agent by hand, the launch dropped that binding: relaunch through the
launch command bin/fm-spawn.sh builds, which carries it.

Deliberate shared-session use must say so: FM_BROWSER_SHARED_SESSION_OK=1.
See docs/browser-session-isolation.md.
EOF
  return 1
}

# Decide only. Returns 0 to allow, 1 to refuse.
guard_check() {
  guard_command_is_sessionless "${1-}" && return 0
  guard_session_isolated && return 0
  guard_context_is_inert && return 0
  guard_refuse
}

# First executable named chrome-devtools-axi on PATH that is not this guard.
# Split PATH by hand rather than by word splitting so an entry containing a
# glob character can never be expanded.
guard_resolve_real_tool() {
  local rest=$PATH entry candidate resolved_dir resolved_tool
  while [ -n "$rest" ]; do
    entry=${rest%%:*}
    if [ "$entry" = "$rest" ]; then rest=""; else rest=${rest#*:}; fi
    [ -n "$entry" ] || entry=.
    resolved_dir=$(cd "$entry" 2>/dev/null && pwd -P) || continue
    candidate=$resolved_dir/$REAL_TOOL
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    # Any shim directory resolves back to this guard; skip it rather than
    # exec'ing ourselves.
    resolved_tool=$(guard_resolve_path "$candidate") || continue
    [ "$resolved_tool" != "$GUARD_REAL" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

guard_exec() {
  local real
  guard_check "$@" || return 1
  if [ "${FM_BROWSER_GUARD_ACTIVE-}" = 1 ]; then
    echo "fm-browser-session-guard: refusing to re-enter the guard; PATH resolves $REAL_TOOL back to the shim" >&2
    return 2
  fi
  real=$(guard_resolve_real_tool) || {
    echo "fm-browser-session-guard: no real $REAL_TOOL found on PATH outside $GUARD_DIR" >&2
    return 2
  }
  export FM_BROWSER_GUARD_ACTIVE=1
  exec "$real" "$@"
}

guard_usage() {
  cat <<'EOF'
Usage: fm-browser-session-guard.sh check [<chrome-devtools-axi args>...]
       fm-browser-session-guard.sh exec <chrome-devtools-axi args>...

Refuses a chrome-devtools-axi invocation that would drive a browser session
with no per-task CHROME_DEVTOOLS_AXI_SESSION, because the upstream default
shares one browser instance across every concurrent agent.

check  decides only: exit 0 to allow, exit 1 to refuse with a reason on stderr.
exec   enforces, then runs the real chrome-devtools-axi found on PATH.

The same script runs as bin/shims/chrome-devtools-axi, where it enforces and
then exec's transparently. It is inert in a firstmate primary home and when
FM_BROWSER_SHARED_SESSION_OK=1 declares deliberate shared use.
See docs/browser-session-isolation.md.
EOF
}

case "$(basename "$GUARD_SELF")" in
  "$REAL_TOOL")
    guard_exec "$@"
    exit $?
    ;;
esac

case "${1-}" in
  check)
    shift
    guard_check "$@"
    exit $?
    ;;
  exec)
    shift
    [ "$#" -gt 0 ] || { echo "error: exec requires a $REAL_TOOL command" >&2; exit 2; }
    guard_exec "$@"
    exit $?
    ;;
  --help|-h|help)
    guard_usage
    exit 0
    ;;
  *)
    guard_usage >&2
    exit 2
    ;;
esac
