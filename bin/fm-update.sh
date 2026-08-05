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
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - nudge-secondmates: fm-<id>...|none   (updated live secondmates to nudge)
#
# The origin for every target must be the official kunchenguid/firstmate
# repository.
# `--expected-sha` pins a previously assessed candidate and refuses an origin
# movement rather than broadening the update to a newer commit.
# A remote route carries no pinned-candidate contract, so a pinned run reports
# it as skipped instead of updating that host to a later commit.
#
# Usage: fm-update.sh [--expected-sha <40-hex-sha>] [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-update.sh
  fm-update.sh --expected-sha <40-hex-sha>

Fast-forward the official kunchenguid/firstmate default branch into this
firstmate home and its registered second-mate homes.

Options:
  --expected-sha SHA  Apply only this exact, previously assessed candidate.
                      The update is refused if the official origin has moved,
                      and a remote second-mate route is reported as skipped
                      because it carries no pinned-candidate contract.
  -h, --help          Show this help.

The updater never forces, stashes, resets, creates a merge commit, or touches
operational private data.
EOF
}

EXPECTED_SHA=
case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --expected-sha)
    [ $# -eq 2 ] || { usage; exit 1; }
    EXPECTED_SHA=$2
    case "$EXPECTED_SHA" in *[!0-9a-f]*|'') usage; exit 1 ;; esac
    [ "${#EXPECTED_SHA}" -eq 40 ] || { usage; exit 1; }
    ;;
  '')
    [ $# -eq 0 ] || { usage; exit 1; }
    ;;
  *)
    usage
    exit 1
    ;;
esac

fm_update_origin_literal_allowed() {
  case "$1" in
    https://github.com/kunchenguid/firstmate.git|https://github.com/kunchenguid/firstmate|git@github.com:kunchenguid/firstmate.git|ssh://git@github.com/kunchenguid/firstmate.git) return 0 ;;
  esac
  return 1
}

# Test fixtures may route an exact official-looking URL to a local bare repo.
# The seam is accepted only under the repository test-mode marker and is not a
# public updater option.
fm_ff_origin_allowed() {
  local dir=$1 configured resolved count
  configured=$(git -C "$dir" config --get-all remote.origin.url 2>/dev/null) || return 1
  count=$(printf '%s\n' "$configured" | awk 'NF { n++ } END { print n+0 }')
  [ "$count" -eq 1 ] || return 1
  fm_update_origin_literal_allowed "$configured" || return 1
  [ -z "$(git -C "$dir" config --get-all remote.origin.uploadpack 2>/dev/null || true)" ] || return 1
  resolved=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  if [ "$resolved" != "$configured" ]; then
    [ "${FM_DAILY_TEST_MODE:-0}" = 1 ] && [ "${FM_DAILY_TEST_ALLOW_URL_REWRITE:-0}" = 1 ] || return 1
  fi
  return 0
}

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no "$EXPECTED_SHA"
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# A pinned scheduled update is one transaction boundary: if the primary did
# not reach the reviewed candidate, leave every second-mate home untouched.
if [ -n "$EXPECTED_SHA" ] && [ "$FF_STATUS" = skipped ]; then
  echo "reread-firstmate: $reread_firstmate"
  echo "nudge-secondmates: none"
  exit 1
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no "$SECONDMATES_MD" "$EXPECTED_SHA"

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
      # A remote route updates that host's code root from its own origin and
      # carries no pinned-candidate contract, so a pinned run reports it
      # instead of broadening the reviewed update to a later commit.
      if [ -n "$EXPECTED_SHA" ]; then
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: pinned candidate is not supported on a remote route" >&2
      elif remote_out=$("$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh update "$id" < /dev/null 2>&1); then
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
      process_secondmate "$id" "$home" "" origin no "$EXPECTED_SHA"
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
