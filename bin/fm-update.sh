#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards an ordinary
# running default branch from origin, or verifies an intentional installed
# prompt overlay and stops for exact installation approval, then fast-forwards
# every registered secondmate home. Local homes are treehouse worktrees or standalone
# clones; remote routes update their configured code root on that host and then
# fast-forward the persistent home to that root. Ordinary mirrors remain
# FAST-FORWARD ONLY, exactly like fm-fleet-sync.sh: never force, never create a
# merge commit, never stash; advance a target only when it is a clean
# fast-forward, otherwise skip and report. The overlay exception never merges,
# rebases, forces, stashes, or resets; its candidate is installed only after
# verification and explicit exact-candidate approval. A tracked-files update
# never touches the gitignored operational
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
# A diverged running main that proves itself to be the installed prompt overlay
# is reconciled through bin/fm-prompt-overlay.py instead of weakening ff_target.
# Lineage binds semantic provenance and authority, while the overlay and target's
# unique actual Git merge base binds changed-path ownership and three-way input.
# Before ownership composition, fm-prompt-semantic-refresh.py proves every changed
# upstream AGENTS.md, internal skill, and role instruction has exactly one optimized
# owner; an unresolved mapping refuses before candidate construction.
# The ordinary invocation builds and verifies a private candidate but never moves
# main. A second invocation with the exact printed approval arguments installs
# that candidate and atomically refreshes the live and rollback overlay refs.
#
# Usage: fm-update.sh [--help]
#        fm-update.sh --install-overlay --plan PATH --candidate-ref REF \
#          --token TOKEN --approve-candidate COMMIT
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
  echo "usage: fm-update.sh [--help]" >&2
  echo "       fm-update.sh --install-overlay --plan PATH --candidate-ref REF --token TOKEN --approve-candidate COMMIT" >&2
}

disclosure_token() { # <operation> <task> <exact child args...>
  local operation=$1 task=$2 output
  shift 2
  output=$(python3 "$FM_ROOT/bin/fm-operation-disclosure.py" disclose "$operation" "$task" -- "$@") || return
  printf '%s\n' "${output##*FM_DISCLOSURE_TOKEN=}"
}

overlay_install() { # exact approval arguments from a prior ordinary run
  local plan=$1 candidate_ref=$2 token=$3 approved=$4 receipt
  set -- install --plan "$plan" --candidate-ref "$candidate_ref" --token "$token" --approve-candidate "$approved"
  receipt=$(disclosure_token overlay-install "$candidate_ref" "$@") || return
  (cd "$FM_ROOT" && FM_DISCLOSURE_TOKEN=$receipt python3 bin/fm-prompt-overlay.py "$@")
  echo "reread-firstmate: yes"
  echo "nudge-secondmates: none"
}

overlay_prepare() {
  local installed upstream previous short plan candidate_ref receipt verify token candidate
  installed=$(git -C "$FM_ROOT" rev-parse HEAD)
  upstream=$(git -C "$FM_ROOT" rev-parse origin/main)
  previous=$(python3 - "$FM_ROOT/docs/verification/prompt-lineage.json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(next(item["upstream_commit"] for item in value["generations"] if item.get("kind") == "live-overlay"))
PY
) || return
  short=$(printf '%.12s' "$upstream")
  mkdir -p "$STATE/overlay-updates"
  chmod 700 "$STATE/overlay-updates"
  plan="$STATE/overlay-updates/$short.json"
  candidate_ref="refs/firstmate/overlays/candidates/origin-$short"
  (cd "$FM_ROOT" && python3 bin/fm-prompt-overlay.py check --previous-upstream "$previous" --upstream "$upstream" --overlay "$installed" --output "$plan") || return
  set -- rebuild --plan "$plan" --candidate-ref "$candidate_ref"
  receipt=$(disclosure_token overlay-rebuild "$candidate_ref" "$@") || return
  (cd "$FM_ROOT" && FM_DISCLOSURE_TOKEN=$receipt python3 bin/fm-prompt-overlay.py "$@") || return
  verify=$(cd "$FM_ROOT" && python3 bin/fm-prompt-overlay.py verify --plan "$plan" --candidate-ref "$candidate_ref") || return
  token=${verify##*token=}
  (cd "$FM_ROOT" && python3 bin/fm-prompt-overlay.py ready --plan "$plan" --candidate-ref "$candidate_ref" --token "$token") || return
  candidate=$(git -C "$FM_ROOT" rev-parse "$candidate_ref")
  echo "firstmate: verified prompt overlay candidate $candidate for origin/main"
  echo "overlay-install: approval-required candidate=$candidate ref=$candidate_ref plan=$plan token=$token"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "${1:-}" = "--install-overlay" ]; then
  [ $# -eq 9 ] && [ "$2" = --plan ] && [ "$4" = --candidate-ref ] && [ "$6" = --token ] && [ "$8" = --approve-candidate ] \
    || { usage; exit 1; }
  overlay_install "$3" "$5" "$7" "$9"
  exit
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
main_result=$(mktemp "${TMPDIR:-/tmp}/fm-update-main.XXXXXX")
trap 'rm -f "$main_result"' EXIT INT TERM
ff_target "$FM_ROOT" "firstmate" origin no no > "$main_result"
if [ "$FF_STATUS" = "updated" ]; then
  [ -z "$FF_INSTR" ] || reread_firstmate="yes"
  cat "$main_result"
elif [ "$FF_STATUS" = "skipped" ] && [ -f "$FM_ROOT/bin/fm-prompt-overlay.py" ] && [ -f "$FM_ROOT/docs/verification/prompt-lineage.json" ]; then
  if ! overlay_prepare; then
    cat "$main_result"
    echo "firstmate overlay: skipped: reconciliation refused" >&2
  fi
else
  cat "$main_result"
fi

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
