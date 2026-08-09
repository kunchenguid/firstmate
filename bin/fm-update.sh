#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates from both the configured
# fork origin and canonical https://github.com/kunchenguid/firstmate main.
#
# Mechanical half of the /updatefirstmate skill. It fetches both sources before
# choosing an update target. When one source contains the other, their newer
# descendant is the one candidate; when they diverge, every automatic update
# stops without moving a checkout. The running firstmate and every registered
# secondmate then advance to that candidate only through a clean fast-forward.
# Local homes are treehouse worktrees or standalone clones; a standalone clone
# imports the exact selected commit from the primary code root before the same
# guarded advance. Remote routes run this source comparison in their configured
# code root on that host, then fast-forward the persistent home to that root.
#
# FAST-FORWARD ONLY, exactly like fm-fleet-sync.sh: never force a checkout,
# never create a merge commit, never stash, and never push. A tracked-files
# fast-forward never touches the gitignored operational dirs (data/, state/,
# config/, projects/, .no-mistakes/), so a secondmate's in-flight work is never
# disrupted. Secondmate homes are leased at a detached HEAD on the default
# branch, so a fast-forward there advances HEAD only and never touches another
# worktree's checkout or the shared default branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh. The same library drives
# the local-HEAD secondmate sync used by fm-spawn.sh and fm-bootstrap.sh, so
# there is one fast-forward implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - distinct fork-origin and canonical-upstream relationship lines
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
CANONICAL_UPSTREAM_URL=https://github.com/kunchenguid/firstmate
CANONICAL_UPSTREAM_BRANCH=main
CANONICAL_UPSTREAM_REF=refs/remotes/firstmate-canonical/main
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
default=$(default_branch "$FM_ROOT" 2>/dev/null || true)
if [ -z "$default" ]; then
  echo "firstmate: skipped: cannot determine default branch"
  echo "firstmate fork origin: unavailable"
  echo "firstmate canonical upstream: not checked"
  echo "reread-firstmate: no"
  echo "nudge-secondmates: none"
  exit 0
fi

origin_ok=no
canonical_ok=no
if git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1 && fetch_once "$FM_ROOT"; then
  origin_ok=yes
fi
if git -C "$FM_ROOT" fetch --quiet --no-tags "$CANONICAL_UPSTREAM_URL" \
  "+refs/heads/$CANONICAL_UPSTREAM_BRANCH:$CANONICAL_UPSTREAM_REF" 2>/dev/null; then
  canonical_ok=yes
fi

origin_ref="origin/$default"
if [ "$origin_ok" != yes ] \
  || ! git -C "$FM_ROOT" rev-parse --verify --quiet "$origin_ref^{commit}" >/dev/null; then
  origin_ok=no
fi
if [ "$canonical_ok" != yes ] \
  || ! git -C "$FM_ROOT" rev-parse --verify --quiet "$CANONICAL_UPSTREAM_REF^{commit}" >/dev/null; then
  canonical_ok=no
fi
if [ "$origin_ok" != yes ] || [ "$canonical_ok" != yes ]; then
  echo "firstmate: skipped: both fork origin and canonical upstream must be fetched before updating"
  if [ "$origin_ok" = yes ]; then
    echo "firstmate fork origin: fetched $(git -C "$FM_ROOT" rev-parse --short "$origin_ref")"
  else
    echo "firstmate fork origin: unavailable"
  fi
  if [ "$canonical_ok" = yes ]; then
    echo "firstmate canonical upstream: fetched $(git -C "$FM_ROOT" rev-parse --short "$CANONICAL_UPSTREAM_REF")"
  else
    echo "firstmate canonical upstream: unavailable"
  fi
  echo "reread-firstmate: no"
  echo "nudge-secondmates: none"
  exit 0
fi

origin_rev=$(git -C "$FM_ROOT" rev-parse "$origin_ref")
canonical_rev=$(git -C "$FM_ROOT" rev-parse "$CANONICAL_UPSTREAM_REF")
origin_short=$(git -C "$FM_ROOT" rev-parse --short "$origin_ref")
canonical_short=$(git -C "$FM_ROOT" rev-parse --short "$CANONICAL_UPSTREAM_REF")
relation=
effective_rev=
if [ "$origin_rev" = "$canonical_rev" ]; then
  relation=equal
  effective_rev=$origin_rev
elif git -C "$FM_ROOT" merge-base --is-ancestor "$origin_ref" "$CANONICAL_UPSTREAM_REF" 2>/dev/null; then
  relation=canonical-ahead
  effective_rev=$canonical_rev
elif git -C "$FM_ROOT" merge-base --is-ancestor "$CANONICAL_UPSTREAM_REF" "$origin_ref" 2>/dev/null; then
  relation=fork-ahead
  effective_rev=$origin_rev
else
  echo "firstmate: skipped: fork origin and canonical upstream diverged; automatic update requires a clean fast-forward"
  echo "firstmate fork origin: diverged at $origin_short"
  echo "firstmate canonical upstream: diverged at $canonical_short"
  echo "reread-firstmate: no"
  echo "nudge-secondmates: none"
  exit 0
fi

ff_target "$FM_ROOT" "firstmate" "$effective_rev" no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

case "$relation" in
  equal)
    echo "firstmate fork origin: current with canonical upstream at $origin_short"
    echo "firstmate canonical upstream: current with fork origin at $canonical_short"
    ;;
  canonical-ahead)
    source_ahead=$(git -C "$FM_ROOT" rev-list --count "$origin_ref..$CANONICAL_UPSTREAM_REF")
    echo "firstmate fork origin: behind canonical upstream by $source_ahead commit(s) at $origin_short"
    echo "firstmate canonical upstream: current at $canonical_short"
    ;;
  fork-ahead)
    source_ahead=$(git -C "$FM_ROOT" rev-list --count "$CANONICAL_UPSTREAM_REF..$origin_ref")
    echo "firstmate fork origin: current at $origin_short"
    echo "firstmate canonical upstream: incorporated in fork origin; fork adds $source_ahead commit(s) after $canonical_short"
    ;;
esac

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" "$effective_rev" no "$SECONDMATES_MD" "$FM_ROOT"

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
        while IFS= read -r remote_source_line; do
          case "$remote_source_line" in
            'firstmate fork origin:'*|'firstmate canonical upstream:'*)
              echo "remote secondmate $id on $SECONDMATE_REGISTRY_HOST: ${remote_source_line#firstmate }"
              ;;
          esac
        done <<< "$remote_out"
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
      process_secondmate "$id" "$home" "" "$effective_rev" no "$FM_ROOT"
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
