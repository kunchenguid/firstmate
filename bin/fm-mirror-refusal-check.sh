#!/usr/bin/env bash
# Diagnose a no-mistakes private-mirror refusal without changing branches or remotes.
# Usage: fm-mirror-refusal-check.sh <task-id> [--run <run-id>]
# Fetches origin and no-mistakes refs in the recorded worktree, then reports
# SAFE only when the cited pipeline head is absent from all fetched refs,
# every refused commit is on both branch tips, and those tips agree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  echo "Usage: fm-mirror-refusal-check.sh <task-id> [--run <run-id>]" >&2
  exit 2
}

inconclusive() {
  echo "INCONCLUSIVE / UNSAFE - 수동 검토 필요: $*"
  exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage
TASK_ID=$1
shift
RUN_ID=
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --run ] || usage
  RUN_ID=$2
fi
case "$TASK_ID" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
if [ -n "$RUN_ID" ]; then
  case "$RUN_ID" in *[!A-Za-z0-9_-]*|'') usage ;; esac
fi

META="$STATE/$TASK_ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || inconclusive "task metadata not found: $META"
WORKTREE=$(fm_backend_meta_exact_value "$META" worktree) || inconclusive "task metadata has no unique worktree"
[ -d "$WORKTREE" ] || inconclusive "recorded worktree is unavailable: $WORKTREE"
BRANCH=$(git -C "$WORKTREE" symbolic-ref --quiet --short HEAD) || inconclusive "recorded worktree is detached"
git -C "$WORKTREE" check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1 || inconclusive "invalid branch name in worktree"

if [ -n "$RUN_ID" ]; then
  STATUS=$(cd "$WORKTREE" && no-mistakes axi status --run "$RUN_ID" 2>&1) || inconclusive "could not read run $RUN_ID status: $STATUS"
else
  STATUS=$(cd "$WORKTREE" && no-mistakes axi status 2>&1) || inconclusive "could not read current-branch run status: $STATUS"
  RUN_ID=$(printf '%s\n' "$STATUS" | sed -n 's/^[[:space:]]*id: "\([A-Za-z0-9_-][A-Za-z0-9_-]*\)"$/\1/p' | head -n 1)
  if [ -z "$RUN_ID" ]; then
    RUN_ID=$(printf '%s\n' "$STATUS" | awk -F, -v branch="$BRANCH" '/^  "[A-Za-z0-9_-]+"/ { id=$1; row_branch=$2; gsub(/^[[:space:]]*"/, "", id); gsub(/"$/, "", id); if (row_branch == branch) { print id; exit } }')
    [ -n "$RUN_ID" ] || inconclusive "no current or listed run matches task branch $BRANCH"
    STATUS=$(cd "$WORKTREE" && no-mistakes axi status --run "$RUN_ID" 2>&1) || inconclusive "could not read selected run $RUN_ID status: $STATUS"
  fi
fi
[ -n "$RUN_ID" ] || inconclusive "no run is selected for task $TASK_ID"
RUN_BRANCH=$(printf '%s\n' "$STATUS" | sed -n 's/^[[:space:]]*branch: \(.*\)$/\1/p' | head -n 1)
RUN_STATE=$(printf '%s\n' "$STATUS" | sed -n 's/^[[:space:]]*status: \(.*\)$/\1/p' | head -n 1)
[ "$RUN_BRANCH" = "$BRANCH" ] || inconclusive "run branch '$RUN_BRANCH' does not match task branch '$BRANCH'"
[ "$RUN_STATE" = failed ] || inconclusive "run $RUN_ID is not failed (status: ${RUN_STATE:-unknown})"

LOGS=$(cd "$WORKTREE" && no-mistakes axi logs --run "$RUN_ID" --step push --full 2>&1) || inconclusive "could not read push log for run $RUN_ID"
case "$LOGS" in *"refusing to reconcile private mirror ref"*"at-risk commit(s) contain content absent from live head"*) ;; *) inconclusive "run $RUN_ID does not contain the targeted mirror-refusal pattern" ;; esac
ERROR=$(printf '%s\n' "$STATUS" | sed -n 's/^[[:space:]]*error: "\(.*\)"$/\1/p' | head -n 1)
case "$ERROR" in *"refusing to reconcile private mirror ref"*"at-risk commit(s) contain content absent from live head"*) ;; *) inconclusive "run status does not contain the targeted mirror-refusal error" ;; esac

REFUSAL_REF=$(printf '%s\n' "$ERROR" | grep -Eo 'refs/heads/[A-Za-z0-9._/-]+' | head -n 1 || true)
CITED_HEAD=$(printf '%s\n' "$ERROR" | grep -Eo 'live head [0-9a-f]{40}' | awk '{print $3}' | head -n 1 || true)
[ -n "$REFUSAL_REF" ] && [ -n "$CITED_HEAD" ] || inconclusive "could not parse refusal branch and cited head"
[ "$REFUSAL_REF" = "refs/heads/$BRANCH" ] || inconclusive "refusal branch $REFUSAL_REF does not match task branch $BRANCH"
AT_RISK_TEXT=${ERROR#*"live head $CITED_HEAD:"}
AT_RISK_TEXT=${AT_RISK_TEXT%\"}
DECLARED_COUNT=$(printf '%s\n' "$ERROR" | grep -Eo '[0-9]+ at-risk commit\(s\)' | awk '{print $1}' | head -n 1 || true)
AT_RISK_SHAS=$(printf '%s\n' "$AT_RISK_TEXT" | grep -Eo '[0-9a-f]{40}' | sort -u || true)
AT_RISK_COUNT=$(printf '%s\n' "$AT_RISK_SHAS" | awk 'NF { n++ } END { print n+0 }')
[ -n "$DECLARED_COUNT" ] && [ "$DECLARED_COUNT" -eq "$AT_RISK_COUNT" ] || inconclusive "could not parse all at-risk commit IDs ($AT_RISK_COUNT found; ${DECLARED_COUNT:-unknown} declared)"

git -C "$WORKTREE" remote get-url origin >/dev/null 2>&1 || inconclusive "origin remote is missing"
git -C "$WORKTREE" remote get-url no-mistakes >/dev/null 2>&1 || inconclusive "no-mistakes private mirror remote is missing"
git -C "$WORKTREE" fetch --quiet --no-tags origin || inconclusive "origin fetch failed"
git -C "$WORKTREE" fetch --quiet --no-tags no-mistakes || inconclusive "private mirror fetch failed"

# The quoted head must be a known commit so missing objects cannot be treated
# as proof of safety. Local no-mistakes mirrors may retain the pipeline object
# even when no advertised branch ref points to it.
if ! git -C "$WORKTREE" cat-file -e "$CITED_HEAD^{commit}" 2>/dev/null; then
  MIRROR_URL=$(git -C "$WORKTREE" remote get-url no-mistakes)
  case "$MIRROR_URL" in
    /*) git --git-dir="$MIRROR_URL" cat-file -e "$CITED_HEAD^{commit}" 2>/dev/null || inconclusive "cited head object is unavailable from the worktree and private mirror" ;;
    *) inconclusive "cited head object is unavailable from fetched objects" ;;
  esac
fi

FOUND_REFS=$(git -C "$WORKTREE" for-each-ref --contains="$CITED_HEAD" --format='%(refname)' 2>/dev/null) || inconclusive "could not check cited head reachability across worktree refs"
[ -z "$FOUND_REFS" ] || inconclusive "cited head $CITED_HEAD is reachable from fetched ref(s): $(printf '%s' "$FOUND_REFS" | tr '\n' ' ')"

ORIGIN_REF="refs/remotes/origin/$BRANCH"
MIRROR_REF="refs/remotes/no-mistakes/$BRANCH"
ORIGIN_TIP=$(git -C "$WORKTREE" rev-parse --verify "$ORIGIN_REF^{commit}" 2>/dev/null) || inconclusive "origin branch ref is unavailable: $ORIGIN_REF"
MIRROR_TIP=$(git -C "$WORKTREE" rev-parse --verify "$MIRROR_REF^{commit}" 2>/dev/null) || inconclusive "private mirror branch ref is unavailable: $MIRROR_REF"
[ "$ORIGIN_TIP" = "$MIRROR_TIP" ] || inconclusive "origin and private mirror tips differ: $ORIGIN_TIP vs $MIRROR_TIP"

while IFS= read -r SHA; do
  [ -n "$SHA" ] || continue
  git -C "$WORKTREE" cat-file -e "$SHA^{commit}" 2>/dev/null || inconclusive "at-risk commit object is unavailable: $SHA"
  git -C "$WORKTREE" merge-base --is-ancestor "$SHA" "$ORIGIN_TIP" || inconclusive "at-risk commit is not an ancestor of origin/$BRANCH: $SHA"
  git -C "$WORKTREE" merge-base --is-ancestor "$SHA" "$MIRROR_TIP" || inconclusive "at-risk commit is not an ancestor of no-mistakes/$BRANCH: $SHA"
done <<EOF
$AT_RISK_SHAS
EOF

echo "SAFE - phantom head 확인됨, 데이터 유실 위험 없음"
echo "run: $RUN_ID"
echo "cited pipeline head: $CITED_HEAD (commit object known; absent from worktree refs after fetch)"
echo "origin tip: $ORIGIN_TIP"
echo "no-mistakes tip: $MIRROR_TIP"
echo "safe base for a new branch: $ORIGIN_TIP"
