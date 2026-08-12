#!/usr/bin/env bash
# Prove that a preserved no-mistakes status head is the current commit in its
# matching gate repository and run worktree.
#
# Usage:
#   bin/fm-preserved-head-check.sh <data-directory> <repo-id> <run-id> <status-head>
#
# Prints the resolved full commit id on success and changes no state.
set -eu

usage() { sed -n '4,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 4 ] || usage
DATA_DIR=$1
REPO_ID=$2
RUN_ID=$3
STATUS_HEAD=$4

case "$REPO_ID" in ''|.|..|*/*) die "invalid repository id" ;; esac
case "$RUN_ID" in ''|.|..|*/*) die "invalid run id" ;; esac
case "$STATUS_HEAD" in
  ''|*[!0-9a-fA-F]*) die "status head must be a hexadecimal object id" ;;
esac
[ "${#STATUS_HEAD}" -ge 4 ] && [ "${#STATUS_HEAD}" -le 64 ] \
  || die "status head must contain 4 to 64 hexadecimal digits"

DATA_DIR=$(CDPATH='' cd -- "$DATA_DIR" 2>/dev/null && pwd -P) \
  || die "data directory does not exist: $DATA_DIR"
GATE_REPO="$DATA_DIR/repos/$REPO_ID.git"
GATE_WORKTREE="$DATA_DIR/worktrees/$REPO_ID/$RUN_ID"
[ -d "$GATE_REPO" ] || die "matching gate repository does not exist: $GATE_REPO"
[ -d "$GATE_WORKTREE" ] || die "run gate worktree does not exist: $GATE_WORKTREE"

EXPECTED_COMMON=$(CDPATH='' cd -- "$GATE_REPO" 2>/dev/null && pwd -P) \
  || die "cannot resolve matching gate repository: $GATE_REPO"
ACTUAL_COMMON=$(git -C "$GATE_WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || die "run gate worktree is not a Git worktree: $GATE_WORKTREE"
ACTUAL_COMMON=$(CDPATH='' cd -- "$ACTUAL_COMMON" 2>/dev/null && pwd -P) \
  || die "cannot resolve run gate repository: $ACTUAL_COMMON"
[ "$ACTUAL_COMMON" = "$EXPECTED_COMMON" ] \
  || die "run gate repository mismatch: expected $EXPECTED_COMMON, found $ACTUAL_COMMON"

RESOLVED_STATUS=$(git --git-dir="$EXPECTED_COMMON" rev-parse --verify "$STATUS_HEAD^{commit}" 2>/dev/null) \
  || die "status head is not a commit in matching gate repository: $STATUS_HEAD"
RESOLVED_WORKTREE=$(git -C "$GATE_WORKTREE" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
  || die "run gate worktree has no commit HEAD: $GATE_WORKTREE"
[ "$RESOLVED_STATUS" = "$RESOLVED_WORKTREE" ] \
  || die "preserved head mismatch: status $RESOLVED_STATUS, worktree $RESOLVED_WORKTREE"

printf '%s\n' "$RESOLVED_STATUS"
