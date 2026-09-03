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
# the same library drives local and remote parent-targeted secondmate sync, so
# there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - restart-secondmates: fm-<id>...|none (advanced live secondmates whose
#     AGENTS.md or .agents/skills/ changed AND whose recorded runtime can prove a
#     restart, so their agents must be replaced to actually reload)
#   - nudge-secondmates: fm-<id>...|none   (the residual: advanced live
#     secondmates that changed instructions but cannot be restarted provably, so
#     the older re-read steer is all that is honest for them; a legacy remote
#     advance that cannot report its instruction diff also lands here because
#     the unknown surface cannot safely authorize a restart)
#
# The two sets are disjoint. Normally both require a CHANGED INSTRUCTION SURFACE,
# which is stricter than this command's older "any advance" nudge and matches what
# the session-start sweep has always used; the one compatibility exception is the
# legacy remote unknown above. Restart is stricter again: a bin/-only advance
# reloads itself on the next call and never costs a conversation
# (bin/fm-ff-lib.sh's ff_instr_needs_reload), and bin/fm-secondmate-restart-lib.sh
# owns the capability half.
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
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

usage() { echo "usage: fm-update.sh [--help]" >&2; }

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
ff_target "$FM_ROOT" "firstmate" origin no no
if [ "$FF_STATUS" = "updated" ] && [ -n "$FF_INSTR" ]; then
  reread_firstmate="yes"
fi

# --- secondmates -----------------------------------------------------------
# An advanced live secondmate is reached only when its INSTRUCTION SURFACE moved
# (nudge_requires_instr is "yes" on every sweep below), the same threshold the
# session-start sweep uses: an advance that touched only README.md, docs/, or the
# installer-facing skills/ changes nothing the agent is running on.
#
# Of those, the ones whose AGENTS.md or .agents/skills/ changed need a restart
# rather than a steer, because a running agent holds both frozen from launch and
# no harness offers a reload. The rest keep the re-read nudge.

FF_NUDGE_WINDOWS=""
FF_SEEN_HOMES=""
FF_RESTART_WINDOWS=""

remove_secondmate_action() {  # <id>
  local id=$1 selector next=""
  for selector in $FF_NUDGE_WINDOWS; do
    [ "$selector" = "fm-$id" ] || next="$next $selector"
  done
  FF_NUDGE_WINDOWS=$next
}

secondmate_agent_may_be_alive() {  # <id>
  local id=$1 meta="$STATE/$1.meta" remote_host state=unreadable
  remote_host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$remote_host" ]; then
    state=$("$SCRIPT_DIR/fm-on.sh" "$id" \
      fm-remote-secondmate-control.sh state "$id" < /dev/null 2>/dev/null) || state=unreadable
  elif fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
    state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" \
      "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null) || state=unreadable
  fi
  case "$state" in
    dead|missing) return 1 ;;
    *) return 0 ;;
  esac
}

# Classify one advanced local secondmate. bin/fm-ff-lib.sh calls this for each
# home that advanced with a changed instruction surface and a live endpoint.
fm_ff_after_instruction_update() {  # <id> <home> <window> <instr>
  local id=$1 instr=$4
  if ! secondmate_agent_may_be_alive "$id"; then
    remove_secondmate_action "$id"
    return 0
  fi
  ff_instr_needs_reload "$instr" || return 0
  fm_secondmate_restart_capable "$STATE/$id.meta" || return 0
  FF_RESTART_WINDOWS="$FF_RESTART_WINDOWS fm-$id"
}

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin yes

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
            remote_detail=${remote_result#synced: }
            # The host reports its advance as "<commit> instr=<paths>". A host
            # whose Firstmate copy predates that suffix reports the commit alone,
            # which is UNKNOWN rather than "nothing changed" and therefore earns
            # the safe re-read steer rather than an unprovable restart.
            case "$remote_detail" in
              *' instr='*)
                remote_instr=${remote_detail##* instr=}
                remote_commit=${remote_detail%% instr=*}
                remote_instr_known=1
                ;;
              *) remote_instr=""; remote_commit=$remote_detail; remote_instr_known=0 ;;
            esac
            if [ -n "$remote_instr" ]; then
              echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST ($remote_commit, instructions changed: $remote_instr)"
            else
              echo "remote secondmate $id: updated on $SECONDMATE_REGISTRY_HOST ($remote_commit)"
            fi
            if [ -f "$STATE/$id.meta" ] && grep -qx 'kind=secondmate' "$STATE/$id.meta" \
              && secondmate_agent_may_be_alive "$id"; then
              if [ "$remote_instr_known" -eq 0 ]; then
                FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
              elif [ -n "$remote_instr" ]; then
                if ff_instr_needs_reload "$remote_instr" \
                  && fm_secondmate_restart_capable "$STATE/$id.meta"; then
                  FF_RESTART_WINDOWS="$FF_RESTART_WINDOWS fm-$id"
                else
                  FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS fm-$id"
                fi
              fi
            fi
            ;;
          current:*) echo "remote secondmate $id: already current on $SECONDMATE_REGISTRY_HOST (${remote_result#current: })" ;;
          *) echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: malformed update result" >&2 ;;
        esac
      else
        echo "remote secondmate $id: skipped on $SECONDMATE_REGISTRY_HOST: ${remote_out%%$'\n'*}" >&2
      fi
    else
      process_secondmate "$id" "$home" "" origin yes
    fi
  done < "$SECONDMATES_MD"
fi

# --- caller action summary -------------------------------------------------

# The local sweep accumulates every advanced instruction-surface change into
# FF_NUDGE_WINDOWS and the classifier above promotes the restartable ones, so the
# nudge line is the residual. Keeping the sets disjoint is what stops a mate from
# being restarted and then steered about the instructions it just relaunched on.
nudge_residual=""
for selector in $FF_NUDGE_WINDOWS; do
  case " $FF_RESTART_WINDOWS " in
    *" $selector "*) continue ;;
  esac
  nudge_residual="$nudge_residual $selector"
done

echo "reread-firstmate: $reread_firstmate"
echo "restart-secondmates:${FF_RESTART_WINDOWS:- none}"
echo "nudge-secondmates:${nudge_residual:- none}"
