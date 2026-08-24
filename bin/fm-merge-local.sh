#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# landing branch to the crewmate's recorded branch.
# The crew branch is `Crew branch: branch=<name>` in data/<id>/brief.md
# (written by bin/fm-brief.sh --branch-name). The landing branch is
# `Base branch contract: base_branch=<branch>` in that same brief (written by
# --base-branch). For both lines the last match wins, because the generated
# contract is appended after free-form {TASK} text that may mention the same
# phrase. Both lookups read the `# Definition of done` section so a later
# relaunch progress note cannot override the generated contract; if that
# section is missing, the last matching line in the brief still wins so older
# one-line records keep working. When the crew-branch line is absent, this
# script still uses fm/<id>. When the base-branch line is absent, it still
# lands on the project's default branch. Omitted flags therefore stay
# identical to today. An invalid recorded name refuses rather than falling back.
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
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"
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

# Generated contracts live in `# Definition of done`. Stop at the next heading
# so a relaunch `## Progress note` cannot override them. A brief with no DOD
# section (older one-line records) falls back to the whole file.
brief_dod_section() {
  awk '
    /^# Definition of done[[:space:]]*$/ { grab=1; next }
    /^#{1,6}[[:space:]]/ { if (grab) exit }
    grab { print }
  ' "$1"
}

brief_last_contract() {
  local file=$1 prefix=$2 section value
  section=$(brief_dod_section "$file")
  value=$(printf '%s\n' "$section" | sed -n "s/^${prefix}//p" | tail -n 1)
  if [ -z "$value" ]; then
    value=$(sed -n "s/^${prefix}//p" "$file" | tail -n 1)
  fi
  printf '%s' "$value"
}

BRIEF="$DATA/$ID/brief.md"
BRANCH="fm/$ID"
if [ -f "$BRIEF" ]; then
  recorded_branch=$(brief_last_contract "$BRIEF" 'Crew branch: branch=')
  if [ -n "$recorded_branch" ]; then
    git check-ref-format --branch "$recorded_branch" >/dev/null 2>&1 || {
      echo "error: $BRIEF records an invalid crew branch: $recorded_branch" >&2
      exit 1
    }
    BRANCH=$recorded_branch
  fi
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
TARGET=$DEFAULT
if [ -f "$BRIEF" ]; then
  recorded_base=$(brief_last_contract "$BRIEF" 'Base branch contract: base_branch=')
  if [ -n "$recorded_base" ]; then
    git check-ref-format --branch "$recorded_base" >/dev/null 2>&1 || {
      echo "error: $BRIEF records an invalid base branch: $recorded_base" >&2
      exit 1
    }
    TARGET=$recorded_base
  fi
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$TARGET" >/dev/null || { echo "error: landing branch $TARGET does not exist in $PROJ" >&2; exit 1; }

# The project's main checkout must stay on its default branch unless it is
# already on the landing target. firstmate never writes here otherwise.
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$cur" != "$DEFAULT" ] && [ "$cur" != "$TARGET" ]; then
  echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT' or landing branch '$TARGET'; cannot merge safely" >&2
  exit 1
fi
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: TARGET must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$TARGET" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $TARGET (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $TARGET, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$TARGET")
if [ "$cur" = "$TARGET" ]; then
  git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null
else
  # Stay on the default checkout and fast-forward the named base in place.
  git -C "$PROJ" update-ref -m "fm-merge-local: fast-forward $TARGET to $BRANCH" \
    "refs/heads/$TARGET" "$(git -C "$PROJ" rev-parse "$BRANCH")" "$(git -C "$PROJ" rev-parse "$TARGET")"
fi
after=$(git -C "$PROJ" rev-parse --short "$TARGET")
echo "merged $BRANCH into local $TARGET ($before -> $after) in $PROJ"
