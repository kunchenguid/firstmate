#!/usr/bin/env bash
# fm-epic-ship.sh - Stage-3 ship of an epic per repo via the 2-PR gitflow
# (gflow "cổng #3", epic gitflow enforcement).
#
# The epic gitflow convention (docs/epic-convention.md, seeded by the gflow epic)
# ships each epic on an epic/<slug> branch (cut by bin/fm-epic-branch.sh). This
# script turns that finished epic branch into pull requests:
#
#   - A repo WITH a declared staging branch ships in two PRs, in order:
#       1. epic/<slug> -> staging   (the "test vehicle": staging exercises the
#          epic before it reaches production).
#       2. epic/<slug> -> production (delivery), opened only AFTER the staging
#          test vehicle has merged.
#   - A repo WITHOUT staging (a personal repo) ships one epic/<slug> -> production
#     PR (delivery).
#
# Staging conflict path: when epic/<slug> does not merge cleanly into staging,
# the test vehicle is opened from a resolve-epic/<slug> branch cut FROM staging
# (so epic/<slug> stays clean for the production PR). This script cuts that
# branch; a human/agent merges epic/<slug> into it and resolves the conflicts,
# then re-runs and the staging PR opens from resolve-epic/<slug>.
#
# It NEVER merges: the captain / configured merge authority merges. It only opens
# (or re-reports) PRs and records their URLs.
#
# Single, idempotent, re-runnable command. The 2-PR sequence is driven by live
# git truth, not stored state, so re-running always does the next right thing:
#   - staging does not yet contain the epic  -> ensure the staging test-vehicle PR.
#   - staging now contains the epic (its PR merged) -> ensure the production PR.
#   - a PR for the same head->base is already open -> report it, never duplicate.
# "staging contains the epic" is `epic/<slug>` being an ancestor of staging - the
# remote-truth signal that the test vehicle merged (gh's merged_at is unreliable
# and its state cannot tell a merged PR from a plain-closed one).
#
# Reads run through git against origin refs and gh-axi list (never a working
# checkout switch). Every git network call is bounded (bin/fm-timeout-lib.sh).
# gflow itself is the bootstrap exception and ships on main with no epic branch;
# every later epic uses this.
#
# The <project> argument is a bare name resolved against this home's projects dir
# (or a path), same as bin/fm-epic-branch.sh.
#
# Usage:
#   fm-epic-ship.sh <epic-slug> <project> [--dry-run]
#   fm-epic-ship.sh -h | --help
#
# --dry-run performs every read-only check for real but prints the mutating
# gh-axi / git commands instead of running them, so the flow is exercisable
# without a live remote.
#
# Overrides (mechanical/test seams, same style as bin/fm-project-mode.sh):
#   FM_PROJECT_MODE_BIN  path to fm-project-mode.sh (default $FM_ROOT/bin/…).
#   FM_GH_BIN            gh wrapper (default gh-axi).
#   FM_EPIC_GIT_TIMEOUT  per git-network-op bound in seconds (default 60).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECT_MODE_BIN="${FM_PROJECT_MODE_BIN:-$FM_ROOT/bin/fm-project-mode.sh}"
GH="${FM_GH_BIN:-gh-axi}"
GIT_NET_TIMEOUT="${FM_EPIC_GIT_TIMEOUT:-60}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_ROOT/bin/fm-timeout-lib.sh"

DRY_RUN=0

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*"; }

usage() {  # <exit-code> (default 2); code 0 prints to stdout for --help
  local code=${1:-2} out=/dev/stderr
  [ "$code" -eq 0 ] && out=/dev/stdout
  cat > "$out" <<'EOF'
usage:
  fm-epic-ship.sh <epic-slug> <project> [--dry-run]   ship an epic via the 2-PR gitflow
  fm-epic-ship.sh -h | --help

Opens the epic gitflow pull requests for one repo and reports their URLs:
  - staging declared:  epic/<slug> -> staging (test vehicle) first; then, once
                       that PR has merged, epic/<slug> -> production (delivery).
  - no staging:        a single epic/<slug> -> production PR.
Conflict with staging cuts resolve-epic/<slug> from staging for the test vehicle,
keeping epic/<slug> clean for the production PR. Idempotent and re-runnable; NEVER
merges (the captain / merge authority merges). --dry-run prints the mutating
gh-axi / git commands instead of running them.
EOF
  exit "$code"
}

# --- bounded git ------------------------------------------------------------
# Turns the shared timeout convention (exit 124 = bound hit) into a clear error,
# and otherwise passes the command's own exit status through.
git_bounded() {
  local rc=0
  fm_run_timed "$GIT_NET_TIMEOUT" git "$@" || rc=$?
  [ "$rc" -ne 124 ] || die "a git operation timed out after ${GIT_NET_TIMEOUT}s: git $*"
  return "$rc"
}

# resolve_clone <arg>: a path used as-is when it exists, or a bare/"projects/<name>"
# name resolved against $PROJECTS. Mirrors bin/fm-epic-branch.sh's resolver.
resolve_clone() {
  local arg=$1 candidate
  case "$arg" in
    projects/*) candidate="$PROJECTS/${arg#projects/}" ;;
    */*)        candidate="$arg" ;;
    *)          candidate="$PROJECTS/$arg" ;;
  esac
  [ -d "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  [ -d "$arg" ] && { printf '%s\n' "$arg"; return 0; }
  return 1
}

origin_has_branch() {  # <clone> <branch> -> 0 exists, 1 absent, die on error
  local clone=$1 branch=$2 rc=0
  git_bounded -C "$clone" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) return 1 ;;
    *) die "cannot reach origin for $clone (git ls-remote failed)" ;;
  esac
}

# fetch_branch <clone> <branch> <localref>: fetch origin/<branch> into a local
# ref so its objects are present for ancestry / merge-tree checks. Echoes the sha.
fetch_branch() {
  local clone=$1 branch=$2 localref=$3
  git_bounded -C "$clone" fetch --quiet origin "+$branch:$localref" \
    || die "cannot fetch origin/$branch for $clone (does the branch exist on origin?)"
  git -C "$clone" rev-parse "$localref" || die "cannot resolve $branch tip"
}

# ahead_count <clone> <headref> <baseref>: commits in head not in base.
ahead_count() { git -C "$1" rev-list --count "$3..$2"; }

# merges_cleanly <clone> <baseref> <headref>: 0 if head merges into base with no
# conflict, 1 if it conflicts. Pure object test - no working-tree checkout.
merges_cleanly() {
  local clone=$1 base=$2 head=$3 rc=0
  git -C "$clone" merge-tree --write-tree --name-only "$base" "$head" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) die "merge-tree failed for $clone ($base <- $head); need git >= 2.38" ;;
  esac
}

# --- gh ---------------------------------------------------------------------
PR_URL_RE='https?://[^[:space:])"]+/pull/[0-9]+'

# open_pr_url <clone> <head> <base>: echo the URL of an already-open head->base
# PR, or nothing. Read-only; runs even under --dry-run.
open_pr_url() {
  local clone=$1 head=$2 base=$3
  ( cd "$clone" && "$GH" pr list --state open --base "$base" --head "$head" --fields url 2>/dev/null ) \
    | grep -Eo "$PR_URL_RE" | head -1 || true
}

# create_pr <clone> <head> <base> <title> <body>: open the PR, echo its URL.
# Honors --dry-run by printing the command and echoing a placeholder.
create_pr() {
  local clone=$1 head=$2 base=$3 title=$4 body=$5 bodyfile out url
  if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] (cd $clone && $GH pr create --base $base --head $head --title \"$title\" --body-file -)" >&2
    printf '%s\n' "[dry-run:$head->$base]"
    return 0
  fi
  bodyfile=$(mktemp "${TMPDIR:-/tmp}/fm-epic-ship-body.XXXXXX") || die "cannot create temp body file"
  printf '%s\n' "$body" > "$bodyfile"
  # ponytail: gh-axi infers the repo from the clone's default remote; a clone with
  # multiple remotes (e.g. firstmate itself) could target the wrong one, but epic
  # ship runs on single-origin project clones, not on firstmate's own repo.
  out=$( cd "$clone" && "$GH" pr create --base "$base" --head "$head" --title "$title" --body-file "$bodyfile" 2>&1 ) \
    || { rm -f "$bodyfile"; die "gh pr create failed for $head -> $base:"$'\n'"$out"; }
  rm -f "$bodyfile"
  url=$(printf '%s\n' "$out" | grep -Eo "$PR_URL_RE" | head -1 || true)
  [ -n "$url" ] || die "gh pr create returned no PR URL for $head -> $base:"$'\n'"$out"
  printf '%s\n' "$url"
}

# ensure_pr <clone> <head> <base> <role>: idempotently ensure the head->base PR,
# echo "<role>|<url>" (or "<role>|none" when there is nothing to ship). Records
# any newly opened PR to the epic. Returns via stdout; reporting is the caller's.
ensure_pr() {
  local clone=$1 head=$2 base=$3 role=$4 url title body
  if [ "$(ahead_count "$clone" "refs/fm-epic-ship/head-$head" "refs/fm-epic-ship/base-$base")" -eq 0 ]; then
    printf '%s|none\n' "$role"
    return 0
  fi
  url=$(open_pr_url "$clone" "$head" "$base")
  if [ -n "$url" ]; then
    printf '%s|%s\n' "$role" "$url"
    return 0
  fi
  title="Epic $SLUG: $role ($head -> $base)"
  body="Automated $role PR for epic \`$SLUG\` (bin/fm-epic-ship.sh).

Head: \`$head\` -> Base: \`$base\`. Do NOT merge without the captain / configured
merge authority. See docs/epic-convention.md for the epic gitflow."
  url=$(create_pr "$clone" "$head" "$base" "$title" "$body")
  record_ship "$role" "$head" "$base" "$url"
  printf '%s|%s\n' "$role" "$url"
}

# --- epic recording (best-effort) -------------------------------------------
# Find this home's epic dir by its canonical identity: epic.md frontmatter
# `epic: <slug>`. Best-effort - a miss warns but never fails the ship, because
# the opened PRs and the stdout report are the authoritative deliverable.
find_epic_dir() {
  local plans="$DATA/plans" d
  [ -d "$plans" ] || return 1
  for d in "$plans"/*/; do
    [ -f "${d}epic.md" ] || continue
    if awk -v s="$SLUG" 'NR<=25 && $1=="epic:" && $2==s{ok=1} END{exit !ok}' "${d}epic.md"; then
      printf '%s\n' "${d%/}"
      return 0
    fi
  done
  return 1
}

record_ship() {  # <role> <head> <base> <url>
  local role=$1 head=$2 base=$3 url=$4 dir line date
  date=$(date -u +%Y-%m-%d)
  line="- $date: $role $url ($head -> $base) [$PROJECT]"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] record to epic ships.md: $line" >&2
    return 0
  fi
  dir=$(find_epic_dir) || { echo "warn: no epic dir for slug \"$SLUG\" under $DATA/plans; PR not recorded" >&2; return 0; }
  printf '%s\n' "$line" >> "$dir/ships.md"
}

# --- resolve-epic (staging conflict path) -----------------------------------
# Cut resolve-epic/<slug> from staging on origin, idempotent and never-clobber,
# same discipline as bin/fm-epic-branch.sh create.
ensure_resolve_branch() {  # <clone> <resolve-branch> <staging-sha>
  local clone=$1 rb=$2 staging_sha=$3
  if origin_has_branch "$clone" "$rb"; then
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    say "[dry-run] git -C $clone push origin $staging_sha:refs/heads/$rb" >&2
    return 0
  fi
  git_bounded -C "$clone" push origin "$staging_sha:refs/heads/$rb" \
    || die "failed to cut $rb from staging for $PROJECT"
  say "cut $rb from staging ($staging_sha) in $PROJECT" >&2
}

# --- arg parse --------------------------------------------------------------
SLUG=""; PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|help) usage 0 ;;
    --dry-run) DRY_RUN=1 ;;
    -*) die "unknown option: $1" ;;
    *)
      if [ -z "$SLUG" ]; then SLUG=$1
      elif [ -z "$PROJECT" ]; then PROJECT=$1
      else usage; fi
      ;;
  esac
  shift
done
[ -n "$SLUG" ] && [ -n "$PROJECT" ] || usage
case "$SLUG" in -*) die "invalid epic slug: $SLUG" ;; esac
git check-ref-format "refs/heads/epic/$SLUG" 2>/dev/null || die "invalid epic slug: $SLUG (not a valid branch name)"

CLONE=$(resolve_clone "$PROJECT") || die "project \"$PROJECT\" not found under $PROJECTS (or as a path)"

EPIC_BRANCH="epic/$SLUG"
RESOLVE_BRANCH="resolve-epic/$SLUG"

# --- resolve branches -------------------------------------------------------
read -r PRODUCTION STAGING < <("$PROJECT_MODE_BIN" --branches "$PROJECT") || true
[ -n "${PRODUCTION:-}" ] || die "production branch undeclared for \"$PROJECT\"; register it first (--production, gflow-02)"
origin_has_branch "$CLONE" "$EPIC_BRANCH" \
  || die "$EPIC_BRANCH missing on origin for $PROJECT; cut it first: bin/fm-epic-branch.sh create $SLUG $PROJECT"

# Fetch the branches we reason about into local refs (objects present locally).
EPIC_SHA=$(fetch_branch "$CLONE" "$EPIC_BRANCH" "refs/fm-epic-ship/head-$EPIC_BRANCH")
fetch_branch "$CLONE" "$PRODUCTION" "refs/fm-epic-ship/base-$PRODUCTION" >/dev/null

# ============================================================================
# No staging: single delivery PR to production.
# ============================================================================
if [ -z "${STAGING:-}" ]; then
  # Epic (head) and production (base) refs were both fetched above.
  result=$(ensure_pr "$CLONE" "$EPIC_BRANCH" "$PRODUCTION" "delivery")
  url=${result#*|}
  if [ "$url" = none ]; then
    say "$PROJECT: nothing to ship - $EPIC_BRANCH is already in $PRODUCTION."
  else
    say "$PROJECT: production PR ($EPIC_BRANCH -> $PRODUCTION): $url"
  fi
  exit 0
fi

# ============================================================================
# Staging declared: 2-PR gitflow, driven by whether staging contains the epic.
# ============================================================================
STAGING_SHA=$(fetch_branch "$CLONE" "$STAGING" "refs/fm-epic-ship/base-$STAGING")

# Has the staging test vehicle merged? -> staging contains the epic work.
if git -C "$CLONE" merge-base --is-ancestor "$EPIC_SHA" "$STAGING_SHA"; then
  # Stage 2: delivery to production.
  result=$(ensure_pr "$CLONE" "$EPIC_BRANCH" "$PRODUCTION" "delivery")
  url=${result#*|}
  if [ "$url" = none ]; then
    say "$PROJECT: nothing to ship - $EPIC_BRANCH is already in $PRODUCTION."
  else
    say "$PROJECT: staging test vehicle merged; production PR ($EPIC_BRANCH -> $PRODUCTION): $url"
  fi
  exit 0
fi

# Stage 1: open the staging test vehicle. Clean merge ships from the epic branch;
# a conflict ships from resolve-epic/<slug> (keeping epic clean for production).
if merges_cleanly "$CLONE" "refs/fm-epic-ship/base-$STAGING" "$EPIC_SHA"; then
  STAGING_HEAD=$EPIC_BRANCH  # head ref already fetched above
else
  STAGING_HEAD=$RESOLVE_BRANCH
  ensure_resolve_branch "$CLONE" "$RESOLVE_BRANCH" "$STAGING_SHA"
  if [ "$DRY_RUN" -eq 1 ] && ! origin_has_branch "$CLONE" "$RESOLVE_BRANCH"; then
    say "$PROJECT: [dry-run] $EPIC_BRANCH conflicts with $STAGING; would cut $RESOLVE_BRANCH, resolve, then open the staging PR from it."
    exit 0
  fi
  fetch_branch "$CLONE" "$RESOLVE_BRANCH" "refs/fm-epic-ship/head-$RESOLVE_BRANCH" >/dev/null
  if [ "$(ahead_count "$CLONE" "refs/fm-epic-ship/head-$RESOLVE_BRANCH" "refs/fm-epic-ship/base-$STAGING")" -eq 0 ]; then
    say "$PROJECT: $EPIC_BRANCH conflicts with $STAGING. Cut $RESOLVE_BRANCH from $STAGING."
    say "  Next: merge $EPIC_BRANCH into $RESOLVE_BRANCH, resolve the conflicts, push it, then re-run this command to open the staging PR."
    exit 0
  fi
fi

result=$(ensure_pr "$CLONE" "$STAGING_HEAD" "$STAGING" "staging test vehicle")
url=${result#*|}
if [ "$url" = none ]; then
  say "$PROJECT: nothing to ship to $STAGING from $STAGING_HEAD."
else
  say "$PROJECT: staging PR ($STAGING_HEAD -> $STAGING): $url"
  say "  Production PR opens after this staging PR merges; re-run then."
fi
exit 0
