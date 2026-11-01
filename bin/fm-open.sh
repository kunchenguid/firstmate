#!/usr/bin/env bash
# fm-open.sh - start this one firstmate home on the Claude subscription chosen
# for this launch, from the `personal` Herdr session.
#
# Usage:
#   fm-open.sh <personal|geris> [claude args...]
#   fm-open.sh --help
#
#   personal  $HOME/.claude
#   geris     $HOME/.claude-geris
#
# Run it from an `hp` shell after /exit. The account argument is the deliberate
# operator act: it goes through `fm-home-identity.sh rebind --confirm`, which
# refuses a live session lock instead of removing it, requires the target
# store's .credentials.json to exist, keeps the old identity in
# data/home-identity.history, and reports any second mate it could not move.
# Choosing the other account on a later launch moves the home back.
#
# It selects only the Claude store. The Herdr session stays `personal`; nothing
# here runs or restarts Herdr, or starts an interactive shell, which would
# re-derive the account from the session name.
#
# EXIT CODES
#   2  usage error
#   3  refused; Claude was not started
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

refuse() {
  printf 'fm-open: %s\n' "$1" >&2
  exit 3
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  personal) store="${HOME:?}/.claude" ;;
  geris) store="${HOME:?}/.claude-geris" ;;
  *) usage >&2; exit 2 ;;
esac
shift

[ "${HERDR_SESSION:-}" = personal ] \
  || refuse "open this home from the personal Herdr session (an hp shell), not '${HERDR_SESSION:-none}'"
FM_HOME=$(cd "${FM_HOME:-$SCRIPT_DIR/..}" 2>/dev/null && pwd -P) || refuse 'FM_HOME is not an existing directory'
export FM_HOME
claude_bin=$(type -P claude) || refuse 'no claude executable on PATH'

pin=$("$SCRIPT_DIR/fm-home-identity.sh" show) || exit 3
case "$pin" in
  *$'\n'herdr_session=personal$'\n'*) ;;
  *) refuse "$FM_HOME is not pinned to the personal session; this launcher never moves a home between sessions" ;;
esac
"$SCRIPT_DIR/fm-home-identity.sh" rebind --store "$store" --confirm || exit $?

# shellcheck source=bin/fm-worker-account-lib.sh
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
for var in $FM_WORKER_ACCOUNT_CLAUDE_SHED; do unset "$var"; done
export CLAUDE_CONFIG_DIR=$store
"$SCRIPT_DIR/fm-home-identity.sh" check || exit $?

cd "$FM_HOME" || refuse "cannot enter $FM_HOME"
exec "$claude_bin" --dangerously-skip-permissions "$@"
