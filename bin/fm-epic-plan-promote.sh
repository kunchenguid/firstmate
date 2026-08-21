#!/usr/bin/env bash
# fm-epic-plan-promote.sh - PROMOTE a worker's committed task-time plan back into
# the epic's canonical `stories/<id>-plan/` dir, so downstream stories read the
# fresh, HEAD-bound plan instead of the stale design-time draft (epwf-02 #4).
#
# The epic pipeline authors an UPFRONT plan per story at design time (/epic-plan).
# By dispatch, HEAD has usually moved: a refactor landed, a scout superseded the
# design section, line anchors drifted. So a worker REFRESHES the upfront plan
# against current HEAD, commits it under its worktree `plans/<id>-plan/`, and stops
# at the captain plan-review gate. On approval, THIS script promotes that approved,
# HEAD-bound plan over the canonical draft, closing the loop the aimica `lh` epic
# ran by hand (lh-14 plan committed 17:44 -> promoted 17:47 -> lh-15/16 consumed
# the promoted plan). Without it, a downstream story reads a plan pinned to a HEAD
# that no longer exists.
#
# It writes ONLY under the home's own `data/plans/` (firstmate-private operational
# state, not a project) - never into any project worktree. After the swap it
# re-runs the epic lint on the canonical dir so a promotion can never leave the
# epic contract broken (the plan pointer must still resolve); a red lint fails the
# promotion loudly with the exact problem rather than silently shipping a broken
# epic.
#
# Usage:
#   fm-epic-plan-promote.sh <epic-slug> <story-id> [--from <src-plan-dir>]
#   fm-epic-plan-promote.sh -h | --help
#
# <epic-slug>   epic.md's canonical `epic:` value (locates the epic dir).
# <story-id>    the story whose plan is being promoted (must be a story in the epic).
# --from <dir>  the source plan dir to promote. Default (no --from): the story's
#               committed plan in this home's clone of the story's repo, at
#               $FM_HOME/projects/<repo>/plans/<story-id>-plan/. Pass --from to
#               promote a plan that has not yet landed in the clone - e.g. the
#               worker's disposable worktree plan dir at plan-review-approval time,
#               before the story's PR merges.
#
# The source must be a directory containing a plan.md. It replaces the canonical
# stories/<story-id>-plan/ atomically (staged sibling + mv), so a re-run with the
# same source is idempotent.
#
# Overrides (mechanical/test seams, same style as bin/fm-epic-status.sh):
#   FM_ROOT_OVERRIDE     firstmate code root (default: this script's ..).
#   FM_HOME              the home that owns the epic (default: FM_ROOT).
#   FM_DATA_OVERRIDE     data dir (default $FM_HOME/data); holds plans/.
#   FM_PROJECTS_DIR      clones root for default source resolution
#                        (default $FM_HOME/projects).
#   FM_EPIC_LINT_BIN     epic lint used for the post-promote re-check
#                        (default $FM_ROOT/bin/fm-epic-lint.sh).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_DIR:-$FM_HOME/projects}"
EPIC_LINT_BIN="${FM_EPIC_LINT_BIN:-$FM_ROOT/bin/fm-epic-lint.sh}"
PLANS="$DATA/plans"

# shellcheck source=bin/fm-epic-status-lib.sh
. "$FM_ROOT/bin/fm-epic-status-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-epic-plan-promote.sh <epic-slug> <story-id> [--from <src-plan-dir>]
  fm-epic-plan-promote.sh -h | --help

Promote a worker's committed, plan-review-approved task-time plan over the epic's
canonical stories/<story-id>-plan/ draft, so downstream stories read the fresh
HEAD-bound plan. Writes only under the home's data/plans/; never into a project.
Default source is the story's plan in this home's clone
($FM_HOME/projects/<repo>/plans/<story-id>-plan/); --from promotes a plan not yet
landed in the clone (the worker's worktree plan at gate-approval time). Re-runs the
epic lint after the swap and fails loudly if the promotion would break the epic.
Run WITH FM_HOME set to the home that owns the epic.
EOF
  exit "$code"
}

SLUG="" STORY="" FROM="" FROM_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage 0 ;;
    --from) shift; [ $# -gt 0 ] || die "--from needs a directory"; FROM=$1; FROM_SET=1 ;;
    --from=*) FROM=${1#--from=}; FROM_SET=1 ;;
    -*) die "unknown option: $1" ;;
    *)
      if [ -z "$SLUG" ]; then SLUG=$1
      elif [ -z "$STORY" ]; then STORY=$1
      else usage; fi ;;
  esac
  shift
done
[ -n "$SLUG" ] && [ -n "$STORY" ] || usage
case "$SLUG" in *[!A-Za-z0-9._/-]*|-*) die "invalid epic slug: $SLUG" ;; esac
case "$STORY" in *[!A-Za-z0-9._-]*|-*) die "invalid story id: $STORY" ;; esac

EPIC_DIR="$(epic_status_find_dir "$PLANS" "$SLUG")" \
  || die "no epic with slug \"$SLUG\" under $PLANS (epic.md must carry \`epic: $SLUG\`)"

STORY_FILE="$EPIC_DIR/stories/$STORY.md"
[ -f "$STORY_FILE" ] || die "story \"$STORY\" is not in epic \"$SLUG\" (no $STORY_FILE)"

# Resolve the source: explicit --from, else the story's committed plan in the
# home's clone of the story's own repo.
if [ "$FROM_SET" -eq 1 ]; then
  SRC=$FROM
else
  REPO="$(epic_fm_get "$STORY_FILE" repo)"
  [ -n "$REPO" ] || die "story \"$STORY\" has no repo: in its frontmatter; pass --from"
  SRC="$PROJECTS/$REPO/plans/$STORY-plan"
fi

[ -d "$SRC" ] || die "source plan dir does not exist: $SRC (has the worker committed its task-time plan under plans/$STORY-plan/ ?)"
[ -f "$SRC/plan.md" ] || die "source plan dir $SRC has no plan.md - not a real plan directory"

DEST="$EPIC_DIR/stories/$STORY-plan"

# Refuse a no-op self-promotion (source IS the canonical dir): nothing to do, and
# the stage-then-swap below would delete then fail to restore it.
if [ "$(cd "$SRC" && pwd -P)" = "$(cd "$DEST" 2>/dev/null && pwd -P || echo "")" ]; then
  die "source is already the canonical plan dir ($DEST); nothing to promote"
fi

# Stage a copy beside the destination, then swap in one mv. rm the stage on any
# failure so a half-finished promote never lingers.
STAGE="$DEST.promote.$$"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
rm -rf "$STAGE"
cp -R "$SRC" "$STAGE"
rm -rf "$DEST"
mv "$STAGE" "$DEST"
trap - EXIT

# Re-run the epic contract lint on the canonical dir: a promotion must never leave
# the epic invalid (e.g. the plan pointer no longer resolving). Fail loudly if it does.
if ! LINT_OUT="$("$EPIC_LINT_BIN" "$EPIC_DIR" 2>&1)"; then
  echo "$LINT_OUT" >&2
  die "promoted plan leaves the epic lint RED (see above) - promotion applied, fix the epic before dispatch"
fi

echo "promoted: $STORY task-time plan -> $DEST (from $SRC); epic lint OK"
