#!/usr/bin/env bash
# Load the Claude Code OAuth token (CLAUDE_CODE_OAUTH_TOKEN) from a secure
# source and export it into the user's launchd session domain so the processes
# firstmate spawns (terminal shells, tmux servers, crewmate agents) inherit it
# across reboots without a manual re-export.
#
# This is the helper the com.firstmate.oauth-token LaunchAgent runs at login
# (see bin/fm-oauth-token-install.sh and docs/oauth-token.md). It never logs,
# echoes, or commits the token value in its default mode; only the controlled
# --print/--export modes emit it, for operator use during rotation or manual
# refresh.
#
# Secure source resolution (first match wins):
#   1. FM_OAUTH_TOKEN_FILE          env path to a file holding just the token
#   2. config/oauth-token-source    gitignored local file; first non-comment line
#                                    is either a path to a token file, "cmd:<sh>"
#                                    whose stdout is the token, or "op:<ref>"
#                                    resolved with `op read <ref>` (1Password CLI)
#   3. ~/.config/firstmate/claude-code-oauth-token
#                                    default gitignored token file (0600)
#
# Modes:
#   --setenv    Read the token and call `launchctl setenv CLAUDE_CODE_OAUTH_TOKEN`
#               (default; what the LaunchAgent runs). Best-effort
#               `tmux set-environment -g` when a tmux server is reachable, so a
#               running tmux picks up a rotated token without a restart.
#   --export    Print `export CLAUDE_CODE_OAUTH_TOKEN=<value>` for sourcing.
#   --print     Print just the token value (for piping into other tooling).
#   --check     Exit 0 if the token is present in the launchd user domain, 1
#               otherwise; prints a one-line status. Does not read the source.
#   --help      Show this help.
#
# Security: the token is a secret. It is read into a shell variable and passed
# to launchctl setenv. `launchctl setenv` exposes the value in the process list
# briefly; this is inherent to launchctl and the standard login-time approach.
# The helper never writes the token to any file, log, or committed artifact, and
# error messages never include the value.
#
# Override:
#   FM_LAUNCHCTL  default `launchctl`; the binary name used for every launchctl
#                call, so tests can exercise the no-launchctl path.
# Usage: fm-oauth-token-load.sh [--setenv|--export|--print|--check|--help]
set -u

LABEL='CLAUDE_CODE_OAUTH_TOKEN'
LAUNCHCTL="${FM_LAUNCHCTL:-launchctl}"

usage() {
  sed -n '2,/^# Usage:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# resolve_source: echo the source descriptor per the resolution order above.
# Echoes a literal path, "cmd:<command>", or "op:<reference>".
resolve_source() {
  if [ -n "${FM_OAUTH_TOKEN_FILE:-}" ]; then
    printf '%s\n' "$FM_OAUTH_TOKEN_FILE"
    return 0
  fi
  local src_file="$CONFIG/oauth-token-source"
  if [ -f "$src_file" ]; then
    local line
    line=$(grep -v '^[[:space:]]*#' "$src_file" 2>/dev/null | grep -v '^[[:space:]]*$' | head -n 1 || true)
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi
  printf '%s\n' "${HOME}/.config/firstmate/claude-code-oauth-token"
}

# read_token: echo the token value (no trailing newline) from the resolved
# source. Errors go to stderr and never include the value. Returns non-zero on
# any failure.
read_token() {
  local src value perms
  src=$(resolve_source) || return 1
  case "$src" in
    cmd:*)
      local cmd=${src#cmd:}
      value=$(sh -c "$cmd" 2>/dev/null) || { echo "error: oauth-token-source cmd failed" >&2; return 1; }
      ;;
    op:*)
      local ref=${src#op:}
      command -v op >/dev/null 2>&1 || { echo "error: oauth-token-source uses op: but the op CLI is not on PATH" >&2; return 1; }
      value=$(op read "$ref" 2>/dev/null) || { echo "error: op read failed for the configured reference" >&2; return 1; }
      ;;
    *)
      if [ ! -f "$src" ]; then
        echo "error: no token file at $src; create it (chmod 600) or set config/oauth-token-source" >&2
        return 1
      fi
      value=$(cat -- "$src") || { echo "error: could not read token file $src" >&2; return 1; }
      if [ -O "$src" ]; then
        perms=$(stat -f '%Lp' "$src" 2>/dev/null || stat -c '%a' "$src" 2>/dev/null || true)
        case "$perms" in
          600|"") ;;
          *) echo "warn: token file $src is mode ${perms:-?}, expected 600; tighten with chmod 600 \"$src\"" >&2 ;;
        esac
      fi
      ;;
  esac
  # strip leading and trailing whitespace (spaces, tabs, newlines)
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  if [ -z "$value" ]; then
    echo "error: resolved token is empty" >&2
    return 1
  fi
  printf '%s' "$value"
}

run_setenv() {
  local token
  token=$(read_token) || return 1
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl not found (looked for $LAUNCHCTL); this helper is macOS-only" >&2; return 1; }
  "$LAUNCHCTL" setenv "$LABEL" "$token" || { echo "error: launchctl setenv failed" >&2; return 1; }
  # Best-effort: push into a running tmux server so a rotated token reaches new
  # tmux windows without restarting tmux. Ignore all tmux failures silently.
  if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
    tmux set-environment -g "$LABEL" "$token" 2>/dev/null || true
  fi
  echo "oauth-token: set $LABEL in the launchd user domain"
}

run_export() {
  local token escaped
  token=$(read_token) || return 1
  escaped=${token//\'/\'\\\'\'}
  printf "export %s='%s'\n" "$LABEL" "$escaped"
}

run_print() {
  local token
  token=$(read_token) || return 1
  printf '%s\n' "$token"
}

run_check() {
  command -v "$LAUNCHCTL" >/dev/null 2>&1 || { echo "error: launchctl not found (looked for $LAUNCHCTL); this helper is macOS-only" >&2; return 1; }
  if "$LAUNCHCTL" getenv "$LABEL" 2>/dev/null | grep -q .; then
    echo "$LABEL: present in the launchd user domain"
    return 0
  fi
  echo "$LABEL: absent from the launchd user domain"
  return 1
}

case "${1:---setenv}" in
  --setenv) run_setenv ;;
  --export) run_export ;;
  --print)  run_print ;;
  --check)  run_check ;;
  -h|--help) usage; exit 0 ;;
  *) echo "usage: fm-oauth-token-load.sh [--setenv|--export|--print|--check|--help]" >&2; exit 2 ;;
esac
