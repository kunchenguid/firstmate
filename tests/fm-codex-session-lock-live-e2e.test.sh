#!/usr/bin/env bash
# Opt-in live Codex TUI regression for the native /quit -> SessionEnd lock
# lifecycle. It sends /quit before any model turn and uses no provider request.
set -u

if [ "${FM_CODEX_LOCK_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LOCK_LIVE_E2E=1 to run the Codex /quit lock regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"
command -v script >/dev/null 2>&1 || fail "script not found"
command -v timeout >/dev/null 2>&1 || fail "timeout not found"

LAB="$ROOT/.codex-session-lock-live-e2e.$$"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.typescript"
CODEX_VERSION=$(codex --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$HOME_DIR/state"

# `script` supplies the PTY required by Codex's TUI. The leading unset prevents
# the parent test session's thread marker from being mistaken for the nested
# session; Codex publishes the nested marker to its own lifecycle hooks.
printf '/quit\r' \
  | timeout 30 env -u CODEX_THREAD_ID FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      script -qfec "codex --dangerously-bypass-hook-trust -C '$ROOT'" "$TRANSCRIPT" \
      >/dev/null 2>&1 \
  || fail "Codex /quit session did not close cleanly: $(tail -20 "$TRANSCRIPT" 2>/dev/null)"

[ ! -e "$HOME_DIR/state/.lock" ] \
  || fail "Codex /quit left the session lock behind: $(cat "$HOME_DIR/state/.lock" 2>/dev/null)"
grep -F '/quit' "$TRANSCRIPT" >/dev/null \
  || fail "Codex PTY transcript did not contain the real /quit command"

printf 'ok - %s live /quit fired SessionEnd and released the per-home lock\n' "$CODEX_VERSION"
