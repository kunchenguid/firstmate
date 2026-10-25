#!/usr/bin/env bash
# fm-owner-guard global hook template (install.sh stamps one copy per hook
# name, replacing __NAME__, its first line with the absolute bash path, and
# __CAT__, __MKTEMP__ and __RM__ with absolute tool paths). Runs the owner-details guard first (__NAME__
# runs it only for pre-commit and pre-push), then chains the previous global
# hooks dir's hook and the repository's own hook, so repos with their own
# hooks keep working — including bare repos' server-side hooks, which a
# global hooksPath would otherwise hide. Never touches repo-local
# core.hooksPath. Pre-push and the other stdin-fed hooks (post-rewrite,
# pre-receive, post-receive, proc-receive, reference-transaction) replay
# git's input to every chained hook on stdin.
set -u -o pipefail
unset CDPATH
# The stamped absolute paths let the hook run with a PATH that holds only git;
# the chained hooks below still get the caller's environment, PATH included.
CAT=__CAT__ MKTEMP=__MKTEMP__ RM=__RM__
HERE=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)
NAME=__NAME__
PREV=$("$CAT" "$HERE/prev-hooks-path" 2>/dev/null || true)
if [ "$NAME" = pre-commit ]; then
  "$HERE/owner-guard" pre-commit "$@" || exit $?
else
  # The stdin-fed hooks replay git's stream to everything below (the guard
  # only runs for pre-push): none of these streams is a push range, so the
  # guard must never scan it. The stream is captured to a byte-exact temp
  # file (proc-receive's pkt-lines carry NUL bytes) so every consumer's
  # exit status wins even when it stops reading early.
  case $NAME in
  pre-push|post-rewrite|pre-receive|post-receive|proc-receive|reference-transaction)
    FEED=$("$MKTEMP") || exit 1
    trap '"$RM" -f -- "$FEED"' EXIT
    "$CAT" >"$FEED"
    FED_STDIN=1 ;;
  esac
  if [ "$NAME" = pre-push ]; then
    "$HERE/owner-guard" pre-push "$@" <"$FEED" || exit $?
  fi
fi
chain() { # chain <hookfile> [args...]: run it when executable and not this wrapper.
  local f=$1
  shift
  [ -n "$f" ] && [ -f "$f" ] && [ -x "$f" ] || return 0
  [ "$f" != "$HERE/hooks/$NAME" ] || return 0
  if [ -n "${FED_STDIN:-}" ]; then
    "$f" "$@" <"$FEED" || exit $?
  else
    "$f" "$@" || exit $?
  fi
}
[ -n "$PREV" ] && [ -d "$PREV" ] && chain "$PREV/$NAME" "$@"
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
[ -n "$COMMON" ] && chain "$COMMON/hooks/$NAME" "$@"
exit 0
