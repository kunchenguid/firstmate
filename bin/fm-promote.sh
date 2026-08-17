#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then follow this
# task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--issue-key <key>] [--delivery-title-rule <template> --delivery-link-rule <template>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=
YOLO=
ISSUE_KEY=
DELIVERY_TITLE_RULE=
DELIVERY_LINK_RULE=
MODE_SET=0
YOLO_SET=0
ISSUE_KEY_SET=0
DELIVERY_TITLE_RULE_SET=0
DELIVERY_LINK_RULE_SET=0
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
      issue-key) ISSUE_KEY=$a; ISSUE_KEY_SET=1 ;;
      delivery-title-rule) DELIVERY_TITLE_RULE=$a; DELIVERY_TITLE_RULE_SET=1 ;;
      delivery-link-rule) DELIVERY_LINK_RULE=$a; DELIVERY_LINK_RULE_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --issue-key) want_value=issue-key ;;
    --issue-key=*) ISSUE_KEY=${a#--issue-key=}; ISSUE_KEY_SET=1 ;;
    --delivery-title-rule) want_value=delivery-title-rule ;;
    --delivery-title-rule=*) DELIVERY_TITLE_RULE=${a#--delivery-title-rule=}; DELIVERY_TITLE_RULE_SET=1 ;;
    --delivery-link-rule) want_value=delivery-link-rule ;;
    --delivery-link-rule=*) DELIVERY_LINK_RULE=${a#--delivery-link-rule=}; DELIVERY_LINK_RULE_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--issue-key <key>] [--delivery-title-rule <template> --delivery-link-rule <template>]" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
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
[ "$ISSUE_KEY_SET" -eq 0 ] || [ -n "$ISSUE_KEY" ] || { echo "error: --issue-key requires a non-empty value" >&2; exit 1; }
if [ "$ISSUE_KEY_SET" -eq 1 ] && ! fm_pr_delivery_issue_key_valid "$ISSUE_KEY"; then
  echo "error: --issue-key must be a non-empty single-line value without whitespace or control characters" >&2
  exit 1
fi
if [ "$DELIVERY_TITLE_RULE_SET" -ne "$DELIVERY_LINK_RULE_SET" ] \
  || { [ "$DELIVERY_TITLE_RULE_SET" -eq 1 ] \
    && { [ -z "$ISSUE_KEY" ] \
      || ! fm_pr_delivery_rule_valid "$DELIVERY_TITLE_RULE" \
      || ! fm_pr_delivery_rule_valid "$DELIVERY_LINK_RULE"; }; }; then
  echo "error: delivery rules require an issue key and valid title and link templates containing {issue_key}" >&2
  exit 1
fi

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
BRIEF_TMP=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "$BRIEF_TMP" ] || rm -f -- "$BRIEF_TMP" 2>/dev/null || true
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
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }
BRIEF="$FM_HOME/data/$ID/brief.md"
if [ -n "$ISSUE_KEY" ]; then
  [ -f "$BRIEF" ] || { echo "error: issue-backed promotion requires the scout brief at $BRIEF" >&2; exit 1; }
  BRIEF_TMP="$FM_HOME/data/$ID/.brief.promote.${BASHPID:-$$}"
  awk '
    { lines[NR] = $0; if ($0 == "# Definition of done") last_dod = NR }
    END {
      for (i = 1; i <= NR; i++) {
        if (last_dod > 0 && i > last_dod && \
          (lines[i] ~ /^Delivery issue: / || lines[i] ~ /^Delivery title rule: / || lines[i] ~ /^Delivery link rule: /)) {
          continue
        }
        print lines[i]
      }
    }
  ' "$BRIEF" > "$BRIEF_TMP"
  {
    printf 'Delivery issue: %s\n' "$ISSUE_KEY"
    [ -z "$DELIVERY_TITLE_RULE" ] || printf 'Delivery title rule: %s\n' "$DELIVERY_TITLE_RULE"
    [ -z "$DELIVERY_LINK_RULE" ] || printf 'Delivery link rule: %s\n' "$DELIVERY_LINK_RULE"
  } >> "$BRIEF_TMP"
  grep -Fx "Delivery issue: $ISSUE_KEY" "$BRIEF_TMP" >/dev/null || {
    echo "error: could not record the issue key in $BRIEF" >&2
    exit 1
  }
  mv "$BRIEF_TMP" "$BRIEF"
  BRIEF_TMP=
fi
TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' -e '^issue_key=' -e '^delivery_title_rule=' -e '^delivery_link_rule=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  [ -z "$ISSUE_KEY" ] || echo "issue_key=$ISSUE_KEY"
  [ -z "$DELIVERY_TITLE_RULE" ] || echo "delivery_title_rule=$DELIVERY_TITLE_RULE"
  [ -z "$DELIVERY_LINK_RULE" ] || echo "delivery_link_rule=$DELIVERY_LINK_RULE"
} >> "$TMP"
mv "$TMP" "$META"
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
case "$MODE" in
  no-mistakes) SHIP_FINISH='after the implementation commit invoke and drive no-mistakes immediately; report the checks-green PR handoff, never a commit-only done event' ;;
  direct-PR) SHIP_FINISH='commit, open the PR, and report its URL' ;;
  local-only) SHIP_FINISH='commit the clean local branch and report it ready for the guarded local merge' ;;
esac
ISSUE_GUIDANCE=
if [ -n "$ISSUE_KEY" ]; then
  ISSUE_GUIDANCE="; expected issue $ISSUE_KEY"
  if [ -n "$DELIVERY_TITLE_RULE" ] && [ -n "$DELIVERY_LINK_RULE" ]; then
    TITLE_RULE_TEXT=$(fm_pr_delivery_rule_expand "$DELIVERY_TITLE_RULE" "$ISSUE_KEY")
    LINK_RULE_TEXT=$(fm_pr_delivery_rule_expand "$DELIVERY_LINK_RULE" "$ISSUE_KEY")
    ISSUE_GUIDANCE="$ISSUE_GUIDANCE; PR title must begin with $TITLE_RULE_TEXT and the PR body must link $LINK_RULE_TEXT"
  fi
fi
INSTRUCTION="<ship instructions for mode=$MODE$ISSUE_GUIDANCE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; $SHIP_FINISH>"
case "$INSTRUCTION" in
  *"'"*) INSTRUCTION_Q=$(printf '%q' "$INSTRUCTION") ;;
  *) INSTRUCTION_Q="'$INSTRUCTION'" ;;
esac
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID $INSTRUCTION_Q"
