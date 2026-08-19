#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# After the origin fast-forward it also DETECTS whether the fork's main repo is
# behind the `upstream` remote (the repo this fork tracks). This is DETECTION
# ONLY: a fork-to-upstream sync is a real 3-way merge with likely conflicts on
# shared files, needs judgment, and must ship through no-mistakes plus a
# captain-approved PR - so this script never branches, merges, resolves
# conflicts, or pushes for upstream. It emits a single caller-action verdict and
# leaves the actual merge to the /updatefirstmate skill's dispatched crewmate.
# The upstream check is a repo-level concern evaluated ONCE for FM_ROOT only;
# secondmates are worktrees of the same repo and fast-forward from origin on the
# next update after the upstream merge PR lands.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#   - upstream-merge: <verdict>   (FM_ROOT vs the upstream remote; see below)
#       none                       no upstream remote configured (feature inert)
#       skipped: <reason>          could not evaluate (offline/tangle/dirty)
#       current                    upstream has nothing the fork lacks
#       needed (<N> behind, <M> ahead)   open an upstream merge PR
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

# --- upstream divergence detection (FM_ROOT only) --------------------------
# DETECT whether the fork's main repo is behind its `upstream` remote and REPORT
# the verdict; never branch, merge, or push. Upstream-divergence detection is a
# concern owned by this script, deliberately kept out of fm-ff-lib.sh, which is
# the single implementation of fast-forward. Verdicts:
#   none                             no upstream remote (feature inert here)
#   skipped: <reason>                could not evaluate (fetch failed/offline,
#                                    wrong branch/tangle, or dirty tree)
#   current                          upstream has nothing the fork lacks
#   needed (<N> behind, <M> ahead)   caller should open an upstream merge PR
upstream_merge_verdict() {
  local dir=$1 default cur behind ahead
  if ! git -C "$dir" remote get-url upstream >/dev/null 2>&1; then
    echo "none"
    return 0
  fi
  default=$(default_branch "$dir") || {
    echo "skipped: cannot determine default branch"
    return 0
  }
  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ "$cur" != "$default" ]; then
    echo "skipped: firstmate not on its default branch"
    return 0
  fi
  if [ -n "$(dirty_status "$dir")" ]; then
    echo "skipped: dirty working tree"
    return 0
  fi
  if ! git -C "$dir" fetch upstream --prune --quiet 2>/dev/null; then
    echo "skipped: upstream fetch failed"
    return 0
  fi
  if ! git -C "$dir" rev-parse --verify --quiet "refs/remotes/upstream/$default^{commit}" >/dev/null; then
    echo "skipped: upstream/$default does not exist"
    return 0
  fi
  behind=$(git -C "$dir" rev-list --count "$default..upstream/$default" 2>/dev/null) || {
    echo "skipped: cannot count upstream commits"
    return 0
  }
  ahead=$(git -C "$dir" rev-list --count "upstream/$default..$default" 2>/dev/null) || {
    echo "skipped: cannot count upstream commits"
    return 0
  }
  if [ "$behind" -eq 0 ]; then
    echo "current"
    return 0
  fi
  echo "needed ($behind behind, $ahead ahead)"
}

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# Detect (never merge) upstream divergence for the main repo, once. Runs after
# the origin fast-forward so the behind/ahead counts reflect the just-updated
# fork tip. Secondmates are worktrees of the same repo and are not checked.
upstream_merge=$(upstream_merge_verdict "$FM_ROOT")

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    if ! secondmate_registry_parse_line "$line"; then
      echo "secondmate registry: skipped malformed entry: $line" >&2
      continue
    fi
    id=$SECONDMATE_REGISTRY_ID
    home=$SECONDMATE_REGISTRY_HOME
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
        remote_result=$(printf '%s\n' "$remote_out" | tail -1)
        case "$remote_result" in
          synced:*)
            echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST (${remote_result#synced: })"
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta"; then
              FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
            fi
            ;;
          current:*) echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })" ;;
          *) echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_secondmate "$id" "$home" "" origin no
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
echo "upstream-merge: $upstream_merge"
