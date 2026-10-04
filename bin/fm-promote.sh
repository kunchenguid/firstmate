#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. Promotion also writes the crewmate's ship instructions to
# data/<task-id>/ship-instructions.md, appends that same superseding contract to
# data/<task-id>/brief.md for future relaunches, and prints the fm-send.sh command
# that delivers it to the current worker. Those instructions carry the
# scratch-state inventory, the clean
# default-branch base, the fm/<task-id> branch, and - rendered from
# bin/fm-dod-lib.sh, the single owner an ordinary ship brief also uses - the
# mode-specific Definition of done, so a promoted worker receives exactly the same
# delivery contract as a briefed one, including the native-review identity and
# finding-authority boundaries. The instructions also carry `# Task` with
# `## Captain's intent` preserved from the scout brief and promotion's ship-time
# instructions under `## Firstmate spec`; the scout-time spec remains context but
# is not relabeled as the ship spec. Promotion refuses leftover `{TASK}` /
# `{FIRSTMATE_SPEC}` placeholders and a `## Captain's intent` line opening with
# a Captain label or address (bin/fm-dod-lib.sh). A pre-subsection scout
# brief contributes only Task lines explicitly marked as captain words to intent.
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# review-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <review-PR|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
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
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <review-PR|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <review-PR|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  review-PR|direct-PR|local-only) ;;
  review-prod-only|no-mistakes|no-mistakes-prod-only)
    echo "error: legacy or conditional delivery posture '$MODE' is not a task mode; resolve it to review-PR or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of review-PR, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
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
META=
SCOUT_BRIEF=
BRIEF_ORIGINAL=
BRIEF_REPLACEMENT=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "$BRIEF_REPLACEMENT" ] || rm -f -- "$BRIEF_REPLACEMENT" 2>/dev/null || true
  if [ -n "$BRIEF_ORIGINAL" ] && [ -e "$BRIEF_ORIGINAL" ]; then
    mv -f -- "$BRIEF_ORIGINAL" "$SCOUT_BRIEF" 2>/dev/null || true
  fi
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
if ADDRESS_LINE=$(fm_brief_intent_address_line "$SCOUT_BRIEF"); then
  echo "error: $SCOUT_BRIEF ## Captain's intent has an operator-address line: $ADDRESS_LINE; write the captain's actual words without a Captain label or address before promotion, since the heading already records provenance" >&2
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
# single owner (bin/fm-dod-lib.sh) rather than summarised into a hint line.
# Native-review mechanics stay with the executable owner named there.
INSTRUCTIONS="$DATA/$ID/ship-instructions.md"
IFS= read -r -d '' PROMOTION_SHIP_SPEC <<EOF || true
If these promotion steps were already completed before a relaunch, preserve the existing \`fm/$ID\` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run \`pwd -P\` and \`git rev-parse --show-toplevel\`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with \`git status\` and \`git log\` before changing anything.
3. Return to a clean default-branch base, then create your branch: \`git checkout -b fm/$ID\`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy \`# Task\` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the general escalation rules; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.
EOF
promote_delivery_contract() {
  cat <<EOF
# Current delivery mode contract
This task is now kind=ship with mode=$MODE.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
EOF
  fm_ship_rule_one "$MODE" "$ID"
  printf '\n'
  fm_dod_block "$MODE" "$ID" "$TASK_DATA_DIR"
}
mkdir -p "$DATA/$ID"
TASK_DATA_DIR=$(CDPATH='' cd -- "$DATA/$ID" && pwd -P) || { echo "error: task data directory cannot be resolved: $DATA/$ID" >&2; exit 1; }
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
$PROMOTION_SHIP_SPEC

EOF
  promote_delivery_contract
} > "$TMP" || { echo "error: could not render ship instructions for mode=$MODE" >&2; exit 1; }
mv "$TMP" "$INSTRUCTIONS"
TMP=
[ -f "$INSTRUCTIONS" ] && [ -r "$INSTRUCTIONS" ] || { echo "error: ship instructions were not published as a readable file: $INSTRUCTIONS" >&2; exit 1; }

# The current worker receives the instructions through fm-send, but a replacement
# worker is launched from brief.md. Publish the same explicit precedence contract
# there so a later relaunch cannot revive the original scout delivery rules.
BRIEF_REPLACEMENT="$DATA/$ID/.brief.md.promote.${BASHPID:-$$}"
{
  cat "$SCOUT_BRIEF"
  printf '\n\n'
  printf '# Current ship Firstmate spec\n%s\n\n' "$PROMOTION_SHIP_SPEC"
  promote_delivery_contract
} > "$BRIEF_REPLACEMENT" || {
  echo "error: could not render the promoted brief for mode=$MODE" >&2
  exit 1
}
BRIEF_ORIGINAL="$DATA/$ID/.brief.md.scout.${BASHPID:-$$}"
mv "$SCOUT_BRIEF" "$BRIEF_ORIGINAL" || {
  echo "error: could not stage the scout brief for promotion: $SCOUT_BRIEF" >&2
  exit 1
}
if ! mv "$BRIEF_REPLACEMENT" "$SCOUT_BRIEF"; then
  if mv "$BRIEF_ORIGINAL" "$SCOUT_BRIEF" 2>/dev/null; then
    BRIEF_ORIGINAL=
  fi
  echo "error: could not publish the promoted brief: $SCOUT_BRIEF" >&2
  exit 1
fi
BRIEF_REPLACEMENT=

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
rm -f -- "$BRIEF_ORIGINAL" 2>/dev/null || true
BRIEF_ORIGINAL=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$FM_HOME")
INSTRUCTIONS_Q=$(printf '%q' "$INSTRUCTIONS")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "wrote ship instructions for mode=$MODE: $INSTRUCTIONS"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID \"\$(cat $INSTRUCTIONS_Q)\""
