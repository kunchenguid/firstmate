#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates from this fleet's fork.
#
# Mechanical half of the /updatefirstmate skill. This fleet runs a FORK: origin
# is the shared upstream, and the fork remote's default branch carries upstream
# plus this fleet's private adaptations. Every home runs the fork, so upstream
# reaches a home in two hops, never one:
#   1. INGEST: merge origin/<default> into fork/<default> and push it to the fork.
#      A conflicting merge STOPS the run and is reported for hand resolution;
#      nothing is forced and nothing is pushed.
#   2. ADVANCE: fast-forward the running firstmate repo's default branch and every
#      registered secondmate home (each a treehouse worktree of this same repo, or
#      a standalone clone) to fork/<default>.
# Homes advance from the FORK, never from origin: an origin advance would strip
# the fleet's adaptations, which is why ff-lib's origin base mode is ingest-only.
#
# The advance is FAST-FORWARD ONLY, exactly like fm-fleet-sync.sh: never force,
# never create a merge commit, never stash; advance a target only when it is a
# clean fast-forward, otherwise skip and report. Only the ingest merge creates a
# commit, and it is written with plumbing (merge-tree/commit-tree) straight into
# the object store, so no working tree is touched and no checkout can be left
# mid-merge. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "fork" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one ingest status line (upstream: ...)
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Exit status is 1 when the ingest could not complete (conflict, missing remote,
# fetch or push failure), leaving every home untouched on its current commit.
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- upstream ingest -------------------------------------------------------
# Conflicted paths from `git merge-tree --write-tree` output: the tree OID line,
# then one "<mode> <oid> <stage>\t<path>" row per conflicted stage, then a blank
# line and free-form messages. Report each path once.
conflict_paths() {
  sed -n '2,/^$/p' | awk -F'\t' 'NF > 1 && !seen[$2]++ { print $2 }'
}

# Merge origin/<default> into fork/<default> and publish it, so the homes below
# have a fork tip that already contains upstream. The merge is built with
# plumbing rather than a checkout: merge-tree writes the merged tree straight
# into the object store and reports conflicts without touching a working tree,
# so a conflicting upstream can never leave FM_ROOT (or any home) stranded
# mid-merge. Echoes one "upstream: ..." status line. Returns 1 to STOP the run.
ingest_upstream() {
  local dir=$1 default up fk merged commit before out remote ref rc
  default=$(default_branch "$dir") || {
    echo "upstream: failed: cannot determine default branch"
    return 1
  }
  for remote in fork origin; do
    if ! git -C "$dir" remote get-url "$remote" >/dev/null 2>&1; then
      echo "upstream: failed: no $remote remote"
      return 1
    fi
    if ! fetch_once "$dir" "$remote"; then
      echo "upstream: failed: $remote fetch failed"
      return 1
    fi
  done

  up="origin/$default"
  fk="fork/$default"
  for ref in "$up" "$fk"; do
    if ! git -C "$dir" rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
      echo "upstream: failed: $ref does not exist"
      return 1
    fi
  done

  # Upstream already contained in the fork: nothing to ingest.
  if git -C "$dir" merge-base --is-ancestor "$up" "$fk" 2>/dev/null; then
    echo "upstream: already merged into $fk"
    return 0
  fi

  before=$(git -C "$dir" rev-parse --short "$fk")
  if git -C "$dir" merge-base --is-ancestor "$fk" "$up" 2>/dev/null; then
    # The fork carries no commits of its own yet, so the ingest is itself a
    # fast-forward and needs no merge commit.
    commit=$(git -C "$dir" rev-parse "$up")
  else
    # merge-tree exits 1 for a genuine conflict and >1 for a failed invocation;
    # only the former is the captain-facing "resolve by hand" case.
    merged=$(git -C "$dir" merge-tree --write-tree "$fk" "$up" 2>/dev/null) && rc=0 || rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "upstream: CONFLICT merging $up into $fk - nothing pushed, nothing advanced"
      printf '%s\n' "$merged" | conflict_paths | sed 's/^/upstream:   conflict: /'
      echo "upstream: resolve by hand on a checkout of $fk, then re-run"
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      echo "upstream: failed: cannot merge $up into $fk"
      return 1
    fi
    merged=$(printf '%s\n' "$merged" | head -1)
    commit=$(git -C "$dir" commit-tree "$merged" -p "$fk" -p "$up" \
      -m "Merge $up into $default") || {
      echo "upstream: failed: cannot write merge commit"
      return 1
    }
  fi

  if ! out=$(git -C "$dir" push fork "$commit:refs/heads/$default" 2>&1); then
    # A rejected push means the fork moved under us; never force past it.
    echo "upstream: failed: push to fork rejected: $(first_line "$out")"
    return 1
  fi
  # Point the local remote-tracking ref at what we just published, so the
  # advances below resolve the new tip without a second network round trip.
  # A failure here would leave the advances resolving the stale pre-ingest tip
  # and report every home "already current", so it stops the run instead.
  if ! out=$(git -C "$dir" update-ref "refs/remotes/$fk" "$commit" 2>&1); then
    echo "upstream: failed: pushed $commit to fork but could not update $fk locally: $(first_line "$out")"
    return 1
  fi
  echo "upstream: merged $up into $fk ($before..$(git -C "$dir" rev-parse --short "$commit"))"
  return 0
}

if ! ingest_upstream "$FM_ROOT"; then
  # Homes deliberately stay where they are: advancing them to a fork tip that
  # does not yet contain upstream would silently half-apply the update.
  echo "reread-firstmate: no"
  echo "nudge-secondmates: none"
  exit 1
fi

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" fork no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" fork no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    process_secondmate "$id" "$home" "" fork no
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
