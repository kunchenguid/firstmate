#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. Promotion also writes the crewmate's ship instructions to
# data/<task-id>/ship-instructions.md and prints the fm-send.sh command that
# delivers them. Those instructions carry the scratch-state inventory, the clean
# default-branch base, the fm/<task-id> branch, and - rendered from
# bin/fm-dod-lib.sh, the single owner an ordinary ship brief also uses - the
# universal batched-findings rule and mode-specific Definition of done, so a
# promoted worker receives the same review and delivery contracts as a briefed
# one, including the no-mistakes mode's ask-user escalation rule and --yes ban.
# The instructions also carry `# Task` with `## Captain's intent` preserved
# from the scout brief and promotion's ship-time instructions under
# `## Firstmate spec`; the scout-time spec remains context but is not
# relabeled as the ship spec. Promotion refuses leftover `{TASK}` /
# `{FIRSTMATE_SPEC}` placeholders (bin/fm-dod-lib.sh). A pre-subsection scout
# brief contributes only Task lines explicitly marked as captain words to intent.
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_directory_input() {
  local name=$1 path=$2 resolved
  case "$path" in
    /*) printf '%s\n' "$path"; return 0 ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME=$(resolve_directory_input FM_HOME "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}") || exit 1
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  FM_STATE_OVERRIDE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
fi
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  FM_DATA_OVERRIDE=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
  echo "error: task record for $ID is unsafe or missing ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

SCOUT_BRIEF="$DATA/$ID/brief.md"
if fm_brief_task_placeholders_present "$SCOUT_BRIEF"; then
  echo "error: $SCOUT_BRIEF still contains {TASK} or {FIRSTMATE_SPEC}; preserve the original ask in ## Captain's intent and fill the scout-time ## Firstmate spec; promotion generates a separate ship-time spec" >&2
  exit 1
fi
if ! fm_brief_task_content_valid "$SCOUT_BRIEF"; then
  echo "error: $SCOUT_BRIEF must contain nonempty ## Captain's intent and ## Firstmate spec subsections (or a nonempty legacy # Task body) before promotion" >&2
  exit 1
fi
if fm_brief_task_heading_present "$SCOUT_BRIEF" "## Captain's intent"; then
  INTENT_BODY=$(fm_brief_task_heading_body "$SCOUT_BRIEF" "## Captain's intent")
else
  TASK_BODY=$(fm_brief_heading_body "$SCOUT_BRIEF" "# Task")
  INTENT_BODY=$(fm_brief_marked_captain_words "$TASK_BODY")
fi
if [ -z "$(printf '%s' "$INTENT_BODY" | tr -d '[:space:]')" ]; then
  echo "error: $SCOUT_BRIEF has no provenance-marked Captain's intent; add the captain's actual words before promotion" >&2
  exit 1
fi

# The promoted worker must receive the same delivery contract an ordinary ship
# brief carries, so the mode-specific Definition of done is rendered from its
# single owner (bin/fm-dod-lib.sh) rather than summarised into a hint line. A
# promoted no-mistakes worker that never received the ask-user escalation rule or
# the --yes ban is the delivery hole this file used to leave open.
INSTRUCTIONS="$DATA/$ID/ship-instructions.md"
PROMOTION_ASK_USER_BLOCK=
if [ "$MODE" = no-mistakes ]; then
  PROMOTION_ASK_USER_BLOCK=$(fm_ask_user_escalation_block "$DATA" "$ID")
fi
mkdir -p "$DATA/$ID"
[ ! -d "$INSTRUCTIONS" ] || { echo "error: ship instructions path is a directory: $INSTRUCTIONS" >&2; exit 1; }
TMP="$DATA/$ID/.ship-instructions.md.${BASHPID:-$$}"
{
  cat <<EOF
Your scout task has been promoted to a ship task, mode=$MODE. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
EOF
  printf '%s\n' "$INTENT_BODY"
  cat <<EOF

## Firstmate spec
1. **Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with \`git status\` and \`git log\` before changing anything.
3. Return to a clean default-branch base, then create your branch: \`git checkout -b fm/$ID\`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. These ship instructions supersede the scout delivery rules and report-based Definition of done. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule.
$PROMOTION_ASK_USER_BLOCK
7. Treat the scout-time Firstmate spec and any unmarked legacy \`# Task\` text as investigation context, not captain intent or ship-time instructions.
EOF
  fm_ship_batch_rule_block 8 9
  printf '\n'
  fm_dod_block "$MODE" "$ID" "$META"
} > "$TMP" || { echo "error: could not render ship instructions for mode=$MODE" >&2; exit 1; }
mv "$TMP" "$INSTRUCTIONS"
TMP=
[ -f "$INSTRUCTIONS" ] && [ -r "$INSTRUCTIONS" ] || { echo "error: ship instructions were not published as a readable file: $INSTRUCTIONS" >&2; exit 1; }

TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
if ! fm_backlog_atomic_transition publish "$TMP" "$META" "task record" "$STATE"; then
  rm -f -- "$TMP"
  TMP=
  echo "error: task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
  exit 1
fi
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$FM_HOME")
INSTRUCTIONS_Q=$(printf '%q' "$INSTRUCTIONS")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "wrote ship instructions for mode=$MODE: $INSTRUCTIONS"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID \"\$(cat $INSTRUCTIONS_Q)\""

promote_print_rechain_hint() {
  local consent_home=$1 work_home=$2 task_id=$3 id prefix
  prefix=
  [ "$consent_home" = "$FM_HOME" ] || prefix="FM_HOME=$(printf '%q' "$consent_home") "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(fm_pf_registry_get "$consent_home/state" "$id" state)" = delivered ] || continue
    echo "next: ${prefix}bin/fm-public-followup.sh rechain <new-obligation-id> --from $id --work-home $work_home --work-id $task_id --expected pr-merged"
  done <<EOF
$(fm_pf_registry_ids_for_work "$consent_home/state" "$work_home" "$task_id")
EOF
}

promote_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}

promote_resolve_primary_home() {
  local parent=$1 child=$2 mate_id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$mate_id" || return 1
  parent=$(promote_canonical_home "$parent") || return 1
  child=$(promote_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$mate_id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fmx_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fmx_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key \
    "$mate_id" "$child" || return 1
  printf '%s\n' "$parent"
}

promote_warn_parent_unresolved() {
  echo "warning: could not resolve the consent-holding parent home for secondmate $1; promotion succeeded, but any open public loop must be inspected and rechained from the parent." >&2
}

if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
  PROMOTE_MATE_ID=$(sed -n '1p' "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)
  PROMOTE_PARENT_RECORD=absent
  PROMOTE_PARENT_ROUTE=
  PROMOTE_DURABLE_PARENT=
  if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
    PROMOTE_PARENT_RECORD=invalid
    if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent"; then
      PROMOTE_PARENT_RECORD=valid
      PROMOTE_PARENT_ROUTE=$FM_SECONDMATE_PARENT_ROUTE
      PROMOTE_DURABLE_PARENT=$FM_SECONDMATE_PARENT_HOME
    fi
  fi
  if [ "$PROMOTE_PARENT_RECORD" = invalid ]; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  elif [ "$PROMOTE_PARENT_ROUTE" = local ]; then
    PROMOTE_PARENT_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$PROMOTE_DURABLE_PARENT}
    PROMOTE_PARENT_BINDINGS_MATCH=1
    if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
      PROMOTE_LIVE_PARENT=$(promote_canonical_home "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      PROMOTE_RECORDED_PARENT=$(promote_canonical_home "$PROMOTE_DURABLE_PARENT") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
          && [ "$PROMOTE_LIVE_PARENT" != "$PROMOTE_RECORDED_PARENT" ]; then
        PROMOTE_PARENT_BINDINGS_MATCH=0
      fi
    fi
    if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
        && PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$PROMOTE_PARENT_CANDIDATE" "$FM_HOME" "$PROMOTE_MATE_ID"); then
      if fm_pf_relay_active "$PROMOTE_PARENT"; then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      fi
    else
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ "$PROMOTE_PARENT_ROUTE" = remote ]; then
    PROMOTE_HOME_ENV_TOKEN=
    if [ -f "$FM_HOME/.env" ]; then
      PROMOTE_HOME_ENV_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$FM_HOME/.env")
    fi
    if [ -n "$PROMOTE_HOME_ENV_TOKEN" ]; then
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
    if fm_pf_relay_active "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME"; then
      if PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME" "$FM_HOME" "$PROMOTE_MATE_ID"); then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      else
        promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
      fi
    fi
  elif fm_pf_relay_active "$FM_HOME"; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  fi
elif fm_pf_relay_active "$FM_HOME"; then
  promote_print_rechain_hint "$FM_HOME" main "$ID"
fi
