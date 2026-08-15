#!/usr/bin/env bash
# bin/fm-herdr-legacy-repair.sh - the one guarded repair path for a legacy
# primary-home Herdr task record that predates endpoint_task_id= and therefore
# cannot pass fm_backend_validate_task_endpoint (bin/fm-backend.sh) until
# repaired, so ordinary teardown and control refuse it and a finished endpoint
# can keep producing watcher alerts.
#
# The repair BINDS: after every independent evidence check below agrees, it
# rewrites the task's metadata with the single missing endpoint_task_id=<id>
# line. It never closes a pane, never touches a worktree, never deletes any
# record, and never calls a mutating Herdr command - cleanup remains
# bin/fm-teardown.sh's, which re-runs its own complete landed-work test and
# confirmed-close sequence against the now-valid record. Ordinary teardown and
# control keep refusing unbound records implicitly; this explicit path is the
# only place a binding may be restored.
#
# Usage: fm-herdr-legacy-repair.sh <task-id>
#
# Exit 0: the record was repaired, or was already bound to exactly this task
# (idempotent rerun; nothing to do). Exit 1: refused, with one concrete
# diagnostic and every record preserved. Exit 2: usage error.
#
# Independent evidence, all required before the one metadata write:
#   - The record is a regular, single-link, non-symlink primary-home meta file;
#     kind=secondmate, any remote route, and a secondmate FM_HOME all refuse.
#   - backend=herdr exactly; tmux legacy records self-identify through their
#     fm-<id> window name and need no repair, and zellij/orca/cmux legacy
#     records are out of this repair's authorized scope and refuse by name.
#   - endpoint_task_id is absent (the legacy shape). A single binding equal to
#     the task id is the idempotent no-op; an empty, duplicate, or foreign
#     binding refuses.
#   - The record plus the one candidate binding line passes
#     fm_backend_validate_task_endpoint, proving the window, worktree, project,
#     and all four herdr_* fields are present exactly once and consistent.
#   - The recorded worktree is a real git worktree at its own toplevel,
#     distinct from the recorded project, and both share the same origin (or
#     the worktree's origin is the project clone itself).
#   - The worktree is clean (same uncommitted-change test as teardown, with the
#     same harness-artifact allowances) and its committed work has landed:
#     every commit reachable from a remote-tracking ref, or proven landed by
#     bin/fm-landed-lib.sh's shared merged-PR/content-in-default predicates -
#     the same owner bin/fm-teardown.sh uses.
#   - The recorded live endpoint agrees, through read-only Herdr calls against
#     the recorded named session only: either the exact pane is structurally
#     gone (a structured pane_not_found), or it is present with its live
#     tab/workspace topology matching the recorded ids, its tab labeled
#     exactly fm-<id>, its agent absent (restored husk) or registered and
#     idle/done, and its foreground cwd in the recorded worktree (or, for an
#     agent-less restored shell, the recorded creation-time project dir).
#     A working or blocked agent, an unreadable response, an unreachable
#     session, or any topology mismatch refuses.
#
# Filename/task-id agreement alone, labels alone, cwd alone, or a merged PR
# alone never authorize the repair; only the full conjunction does. Any
# missing, duplicate, stale, ambiguous, mismatched, unreadable, live-working,
# unlanded, or dirty evidence refuses with the concrete reason and changes
# nothing. The write itself is atomic (temp file + rename in state/), guarded
# by the task's control and metadata locks, and re-validated after the rename,
# so a rerun at any interruption point converges to the same repaired record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,/^set -u$/ { /^set -u$/d; s/^# \{0,1\}//; p; }' "$0"
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
if [ "$#" -ne 1 ] || ! fm_task_id_path_safe "$1"; then
  echo "error: usage: fm-herdr-legacy-repair.sh <task-id>" >&2
  exit 2
fi
ID=$1

refuse() {
  echo "REFUSED: $*" >&2
  exit 1
}

fm_refuse_if_gate_agent

[ ! -e "$FM_HOME/.fm-secondmate-home" ] && [ ! -L "$FM_HOME/.fm-secondmate-home" ] \
  || refuse "this is a secondmate home; the legacy repair path covers only primary-home records."
[ -d "$STATE" ] \
  || refuse "state directory $STATE does not exist; nothing to repair."
META="$STATE/$ID.meta"
[ -f "$META" ] || refuse "task $ID has no metadata at $META; nothing to repair."

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-landed-lib.sh
. "$SCRIPT_DIR/fm-landed-lib.sh"

CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
META_TMP=
repair_cleanup() {
  local status=$?
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  return "$status"
}
trap repair_cleanup EXIT
trap 'exit 1' HUP INT TERM

fm_lock_try_acquire "$CONTROL_LOCK" \
  || refuse "another lifecycle action is already running for task $ID; nothing was changed."
CONTROL_LOCK_HELD=1

META_LOCK=$(fm_meta_lock_path "$META") || refuse "task $ID has no resolvable metadata lock."
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1

[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || refuse "task $ID metadata at $META is not a regular single-link file."
META_DEVICE=$(fm_pr_file_device "$META") || refuse "task $ID metadata device is unreadable."
STATE_DEVICE=$(fm_pr_file_device "$STATE") || refuse "state directory device is unreadable."
[ "$META_DEVICE" = "$STATE_DEVICE" ] \
  || refuse "task $ID metadata is not on the state directory's device."

KIND_COUNT=$(grep -c '^kind=' "$META" 2>/dev/null || true)
[ "$KIND_COUNT" -eq 1 ] \
  || refuse "task $ID has $KIND_COUNT kind= records; a missing or ambiguous task kind is not a repair candidate."
KIND=$(fm_backend_meta_exact_value "$META" kind) \
  || refuse "task $ID has an empty task kind; preserved for inspection."
case "$KIND" in
  ship|scout) ;;
  secondmate)
    refuse "task $ID is a secondmate record; the legacy repair path never touches secondmates."
    ;;
  *)
    refuse "task $ID records kind=$KIND; the legacy repair path covers only primary ship and scout tasks."
    ;;
esac
[ "$(grep -c '^remote_host=' "$META" 2>/dev/null || true)" -eq 0 ] \
  || refuse "task $ID has a remote route; the legacy repair path covers only local primary-home records."

BACKEND_COUNT=$(grep -c '^backend=' "$META" 2>/dev/null || true)
[ "$BACKEND_COUNT" -eq 1 ] \
  || refuse "task $ID has $BACKEND_COUNT backend= records; a legacy tmux-default or ambiguous record is not a Herdr repair candidate."
BACKEND=$(fm_backend_meta_exact_value "$META" backend) \
  || refuse "task $ID has an empty backend identity."
[ "$BACKEND" = herdr ] \
  || refuse "task $ID records backend=$BACKEND; this repair path covers only Herdr records (tmux legacy records self-identify by window name, and other opaque backends are out of its authorized scope)."

BINDING_COUNT=$(grep -c '^endpoint_task_id=' "$META" 2>/dev/null || true)
if [ "$BINDING_COUNT" -gt 1 ]; then
  refuse "task $ID has $BINDING_COUNT endpoint task bindings; an ambiguous record is preserved for inspection."
fi
if [ "$BINDING_COUNT" -eq 1 ]; then
  BINDING=$(fm_backend_meta_exact_value "$META" endpoint_task_id) \
    || refuse "task $ID has an empty endpoint task binding; preserved for inspection."
  [ "$BINDING" = "$ID" ] \
    || refuse "endpoint metadata belongs to task $BINDING, not $ID; preserved for inspection."
  fm_backend_validate_task_endpoint "$META" "$ID" || exit 1
  echo "already-bound: task $ID endpoint metadata already carries its exact binding; nothing to do."
  exit 0
fi

# Candidate validation: the record plus the single missing binding line must
# pass the same validator every cleanup path uses, proving all endpoint fields
# exist exactly once and are consistent before any live evidence is read.
META_TMP=$(mktemp "$STATE/.fm-herdr-legacy-repair.XXXXXX") \
  || refuse "could not create a temporary candidate record in $STATE."
cp -p "$META" "$META_TMP" 2>/dev/null \
  || refuse "could not stage the candidate record."
printf 'endpoint_task_id=%s\n' "$ID" >> "$META_TMP" \
  || refuse "could not stage the candidate binding."
fm_backend_validate_task_endpoint "$META_TMP" "$ID" || exit 1

WT=$(fm_backend_meta_exact_value "$META" worktree) || refuse "task $ID worktree identity became unreadable."
PROJ=$(fm_backend_meta_exact_value "$META" project) || refuse "task $ID project identity became unreadable."
SESSION=$(fm_backend_meta_exact_value "$META" herdr_session) || refuse "task $ID herdr_session became unreadable."
WORKSPACE=$(fm_backend_meta_exact_value "$META" herdr_workspace_id) || refuse "task $ID herdr_workspace_id became unreadable."
TAB=$(fm_backend_meta_exact_value "$META" herdr_tab_id) || refuse "task $ID herdr_tab_id became unreadable."
PANE=$(fm_backend_meta_exact_value "$META" herdr_pane_id) || refuse "task $ID herdr_pane_id became unreadable."
PR_COUNT=$(grep -c '^pr=' "$META" 2>/dev/null || true)
[ "$PR_COUNT" -le 1 ] \
  || refuse "task $ID has $PR_COUNT pr= records; ambiguous landed-work evidence is preserved for inspection."
PR_URL=
if [ "$PR_COUNT" -eq 1 ]; then
  PR_URL=$(fm_backend_meta_exact_value "$META" pr) \
    || refuse "task $ID has an empty PR identity; landed-work evidence is preserved for inspection."
fi

canonical_dir() {
  local target=$1
  [ -n "$target" ] && [ -d "$target" ] || return 1
  ( CDPATH='' cd -- "$target" 2>/dev/null && pwd -P )
}

# Worktree and project evidence.
PROJ_REAL=$(canonical_dir "$PROJ") \
  || refuse "recorded project $PROJ does not exist; preserved for inspection."
git -C "$PROJ_REAL" rev-parse --git-dir >/dev/null 2>&1 \
  || refuse "recorded project $PROJ is not a git repository."
WT_REAL=$(canonical_dir "$WT") \
  || refuse "recorded worktree $WT does not exist; preserved for inspection."
WT_TOP=$(git -C "$WT_REAL" rev-parse --show-toplevel 2>/dev/null) \
  || refuse "recorded worktree $WT is not a git worktree."
WT_TOP_REAL=$(canonical_dir "$WT_TOP") \
  || refuse "recorded worktree $WT has an unreadable toplevel."
[ "$WT_TOP_REAL" = "$WT_REAL" ] \
  || refuse "recorded worktree $WT is not its own git toplevel ($WT_TOP_REAL); the record does not match a task worktree."
[ "$WT_REAL" != "$PROJ_REAL" ] \
  || refuse "recorded worktree equals the recorded project checkout; a task record must point at an isolated copy."

origin_normalize() {
  local url=$1
  url=${url%/}
  url=${url%.git}
  printf '%s' "$url"
}
WT_ORIGIN=$(git -C "$WT_REAL" remote get-url origin 2>/dev/null) \
  || refuse "recorded worktree $WT has no origin remote; cannot tie it to the recorded project."
PROJ_ORIGIN=$(git -C "$PROJ_REAL" remote get-url origin 2>/dev/null) || PROJ_ORIGIN=
WT_ORIGIN_DIR=$(canonical_dir "$WT_ORIGIN" 2>/dev/null) || WT_ORIGIN_DIR=
if [ "$WT_ORIGIN_DIR" != "$PROJ_REAL" ] \
  && { [ -z "$PROJ_ORIGIN" ] \
    || [ "$(origin_normalize "$WT_ORIGIN")" != "$(origin_normalize "$PROJ_ORIGIN")" ]; }; then
  refuse "recorded worktree origin ($WT_ORIGIN) does not match the recorded project ($PROJ); the record's worktree and project disagree."
fi

# Clean-and-landed evidence: the same dirty allowances as teardown, then full
# remote reachability or the shared landed predicates (bin/fm-landed-lib.sh).
DIRTY_RAW=$(git -C "$WT_REAL" status --porcelain 2>/dev/null) \
  || refuse "cannot inspect worktree $WT for uncommitted changes."
DIRTY=$(printf '%s\n' "$DIRTY_RAW" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)
[ -z "$DIRTY" ] \
  || refuse "worktree $WT has uncommitted changes; unlanded work is never repaired away."
git -C "$WT_REAL" rev-parse --verify HEAD >/dev/null 2>&1 \
  || refuse "worktree $WT has no readable HEAD commit."
UNPUSHED=$(git -C "$WT_REAL" log --oneline HEAD --not --remotes -- 2>/dev/null) \
  || refuse "cannot inspect worktree $WT for commits not on a remote."
if [ -n "$UNPUSHED" ]; then
  BRANCH=$(git -C "$WT_REAL" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  fm_landed_work_is_landed "$WT_REAL" "$PROJ_REAL" "$PR_URL" "$BRANCH" \
    || refuse "worktree $WT has committed work not on any remote and not proven landed; nothing was changed."
fi

# Live endpoint evidence, read-only, against the recorded named session only.
fm_backend_source herdr
fm_backend_herdr_tool_check || exit 1

PRESENCE=$(fm_backend_herdr_pane_presence_state "$SESSION" "$PANE")
ENDPOINT_EVIDENCE=
case "$PRESENCE" in
  dead)
    # Structured pane_not_found from the recorded session: the endpoint is
    # positively gone, the strongest terminal evidence there is.
    ENDPOINT_EVIDENCE="endpoint already gone (structured pane_not_found)"
    ;;
  present)
    PANE_INFO=$(fm_backend_herdr_cli "$SESSION" pane get "$PANE" 2>/dev/null) \
      || refuse "recorded pane $PANE became unreadable in session $SESSION."
    LIVE_PANE=$(printf '%s' "$PANE_INFO" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
    [ "$LIVE_PANE" = "$PANE" ] \
      || refuse "live pane identity ${LIVE_PANE:-<unreadable>} is not the recorded pane $PANE; the record does not match the live endpoint."
    LIVE_TAB=$(printf '%s' "$PANE_INFO" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
    [ "$LIVE_TAB" = "$TAB" ] \
      || refuse "live pane $PANE sits in tab ${LIVE_TAB:-<unreadable>}, not the recorded tab $TAB; the record does not match the live endpoint."
    TABS=$(fm_backend_herdr_cli "$SESSION" tab list --workspace "$WORKSPACE" 2>/dev/null) \
      || refuse "recorded workspace $WORKSPACE is unreadable in session $SESSION."
    printf '%s' "$TABS" | jq -e --arg tab "$TAB" --arg label "fm-$ID" '
      (.result.tabs | type) == "array"
      and ([.result.tabs[] | select(.tab_id == $tab)] | length) == 1
      and ([.result.tabs[] | select(.tab_id == $tab and .label == $label)] | length) == 1
    ' >/dev/null 2>&1 \
      || refuse "recorded tab $TAB is missing from workspace $WORKSPACE or is not labeled fm-$ID; the record does not match the live topology."
    AGENT_STATE=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE")
    case "$AGENT_STATE" in
      no-agent)
        ENDPOINT_EVIDENCE="restored agent-less shell at the recorded endpoint"
        ;;
      live)
        AGENT_RAW=$(fm_backend_herdr_agent_identity_raw "$SESSION" "$PANE") \
          || refuse "registered agent state for pane $PANE became unreadable."
        case "$AGENT_RAW" in
          *$'\t'*)
            AGENT_NAME=${AGENT_RAW%%$'\t'*}
            AGENT_STATUS=${AGENT_RAW#*$'\t'}
            ;;
          *)
            refuse "the recorded endpoint's registered agent identity is unreadable; preserved for inspection."
            ;;
        esac
        [ -n "$AGENT_NAME" ] \
          || refuse "the recorded endpoint's registered agent identity is unreadable; preserved for inspection."
        case "$AGENT_STATUS" in
          idle|done)
            ENDPOINT_EVIDENCE="finished agent ($AGENT_STATUS) at the recorded endpoint"
            ;;
          working|blocked)
            refuse "the recorded endpoint's agent is $AGENT_STATUS; active or undecided work is never repaired away."
            ;;
          *)
            refuse "the recorded endpoint's agent status is unreadable; preserved for inspection."
            ;;
        esac
        ;;
      *)
        refuse "the recorded endpoint's agent state is $AGENT_STATE; preserved for inspection."
        ;;
    esac
    FG_CWD=$(printf '%s' "$PANE_INFO" | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null)
    FG_REAL=$(canonical_dir "$FG_CWD" 2>/dev/null) \
      || refuse "the recorded endpoint's foreground working directory is unreadable; preserved for inspection."
    if [ "$AGENT_STATE" = no-agent ]; then
      # A restored shell starts at the pane's creation cwd (the project);
      # a shell still in the task worktree is equally consistent.
      [ "$FG_REAL" = "$WT_REAL" ] || [ "$FG_REAL" = "$PROJ_REAL" ] \
        || refuse "the restored shell's working directory ($FG_REAL) matches neither the recorded worktree nor the recorded project; the pane is not provably this task's."
    else
      [ "$FG_REAL" = "$WT_REAL" ] \
        || refuse "the finished agent's working directory ($FG_REAL) is not the recorded worktree; the pane is not provably this task's."
    fi
    ;;
  *)
    refuse "the recorded endpoint in session $SESSION is unreadable or the session is unreachable; start the recorded session and rerun, or inspect manually."
    ;;
esac

# All evidence agrees. The one mutation: atomically install the candidate
# record already validated above, then re-validate what actually landed.
mv -f -- "$META_TMP" "$META" \
  || refuse "could not install the repaired record; nothing usable was changed."
META_TMP=
fm_backend_validate_task_endpoint "$META" "$ID" || {
  echo "error: the repaired record failed re-validation; inspect $META before any cleanup." >&2
  exit 1
}
echo "repaired: task $ID endpoint binding restored ($ENDPOINT_EVIDENCE)."
echo "Cleanup remains bin/fm-teardown.sh $ID, which re-runs its own complete landed-work and confirmed-close safety."
