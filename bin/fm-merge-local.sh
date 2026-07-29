#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's fm/<id> branch.
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true
ID=${1:?usage: fm-merge-local.sh <task-id>}
META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH="fm/$ID"
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

# Telegram publish gate.
#
# Same rule as bin/fm-pr-merge.sh, enforced here because this is the other way a
# prepared change actually reaches the world: a task carrying a Telegram link
# may not land without a live confirmation the paired person gave for exactly
# the revision about to be fast-forwarded. The revision is resolved from the
# branch itself in trusted code, and the authorization is consumed before the
# merge so one approval can never land twice. Whether the gate applies is
# decided by durable evidence - the task's immutable Telegram origin, or an
# armed publish record for it - rather than by the open conversation, so ending
# the exchange cannot end the gate. A task that never came from the bridge is
# unaffected.
# shellcheck source=bin/fm-tg-lib.sh
. "$FM_ROOT/bin/fm-tg-lib.sh"
if fmtg_landing_gate_applies "$ID" "$META"; then
  TG_REQUEST=$(fmtg_meta_get "$META" tg_request) \
    || TG_REQUEST=$(fmtg_meta_get "$META" tg_origin) || TG_REQUEST='<malformed>'
  fmtg_load_config
  TG_NOW=$(fmtg_now) || { echo "error: cannot read the current time" >&2; exit 1; }
  TG_HEAD=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH") || TG_HEAD=
  TG_REASON=$(fmtg_landing_guard "$ID" "$PROJ" "local:$DEFAULT" "$TG_HEAD" "$TG_NOW") || {
    TG_RC=$?
    printf 'REFUSED: %s\n' "$(fmtg_landing_refusal_text "$TG_REASON" "$ID" "local:$DEFAULT")" >&2
    printf 'This task answers Telegram request %s. Preview the change to the paired person and have them confirm publishing it before merging.\n' \
      "$TG_REQUEST" >&2
    exit "$TG_RC"
  }
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
