#!/usr/bin/env bash
# fm-dispatch.sh - the routed front door for crewmate and scout launches.
# Usage:
#   fm-dispatch.sh new <task-id> <project-dir> [--wait] [spawn options]
# new durably queues the request and returns before resolving or launching.
# The watcher admission retry finishes it and announces the result.
# --wait requests the final verdict synchronously (also used by queue replay).
#   fm-dispatch.sh relaunch <task-id> (--note <text> | --note-file <path>) [--priority <n>]
#   fm-dispatch.sh promote <task-id> [promotion options]
# All verbs accept --pick <CODE> to finish a verified captain pick instead of
# asking Jev again, or --captain-pick to request the captain's choice.
# new reads $FM_HOME/data/<id>/brief.md; relaunch and promote read the same
# durable brief and state/<id>.meta. FM_DATA_OVERRIDE and FM_STATE_OVERRIDE
# select those directories as in the underlying commands.
# new forwards delivery/backend/scout options to fm-spawn.sh; promote forwards
# delivery options to fm-promote.sh. Their --help/header owns those options.
# Profile flags, raw launch commands, secondmates, batches, and --relaunch are
# not accepted here. The resolver alone chooses and writes the receipt, including
# its fresh quota intake through fm-quota-intake.sh; do not record a second intake
# over the one bound to that receipt. Existing launch scripts own every gate.
# A non-dispatchable answer prints its evidence and exits 3 without launching.
# After a captain answers, repeat the command with --pick CODE. Promotion has
# already written the ship contract: retry promote with no promotion options.
# An unchanged promotion sends ship-instructions.md through fm-send.sh; a changed
# profile uses fm-control.sh relaunch in the same worktree with those instructions
# as its progress note. A refused launch leaves the promoted contract on disk.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
export FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'dispatch: %s\n' "$*" >&2; exit 2; }
usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 2 ] || die 'expected new|relaunch|promote and a task id (see --help)'
VERB=$1 ID=$2
shift 2
case "$VERB" in new|relaunch|promote) ;; *) die "unknown verb $VERB" ;; esac
fm_task_id_creation_valid "$ID" || die 'invalid task id'
PROJECT=
if [ "$VERB" = new ]; then
  [ "$#" -gt 0 ] || die 'new requires a project directory'
  PROJECT=$1
  shift
  case "$PROJECT" in -*) die 'new requires a project directory, not a flag' ;; esac
fi
ORIGINAL_ARGS=(new "$ID" "$PROJECT" "$@")
WAIT=0
ARGS=() RESOLVE_ARGS=() PICK=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --wait) [ "$VERB" = new ] || die '--wait is only for new'; WAIT=1; shift ;;
    --pick) [ "$#" -ge 2 ] && [ -n "$2" ] || die '--pick needs a code'; PICK=$2; shift 2 ;;
    --captain-pick) RESOLVE_ARGS+=(--captain-pick); shift ;;
    --harness|--model|--effort|--account|--harness=*|--model=*|--effort=*|--account=*)
      die 'profile flags belong to the resolver, not the caller' ;;
    --merge-review)
      [ "$VERB" = new ] || die "unsupported $VERB option $1"
      ARGS+=("$1"); shift ;;
    --scout|--herdr-resume-lock-wait)
      [ "$VERB" != relaunch ] || die "unsupported relaunch option $1"
      case "$VERB:$1" in promote:--scout|promote:--herdr-resume-lock-wait) die "unsupported promote option $1" ;; esac
      ARGS+=("$1"); shift ;;
    --mode|--yolo|--branch-prefix|--base-branch|--upstream-consent|--backend|--priority|--note|--note-file)
      flag=$1
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$flag needs a value"
      case "$2" in --*) die "$flag needs a value, not a flag" ;; esac
      case "$VERB:$flag" in
        new:--note|new:--note-file|promote:--note|promote:--note-file|promote:--backend|promote:--base-branch|promote:--priority) die "unsupported $VERB option $flag" ;;
        relaunch:*) case "$flag" in --note|--note-file|--priority) ;; *) die "unsupported relaunch option $flag" ;; esac ;;
      esac
      ARGS+=("$flag" "$2"); shift 2 ;;
    *) die "unsupported argument $1 (see --help)" ;;
  esac
done
[ -z "$PICK" ] || [ "${#RESOLVE_ARGS[@]}" -eq 0 ] || die '--pick and --captain-pick are mutually exclusive'
BRIEF="$DATA/$ID/brief.md"
META="$STATE/$ID.meta"
meta_value() { awk -v key="$1" 'index($0, key "=") == 1 {print substr($0, length(key)+2); exit}' "$META"; }
if [ "$VERB" != new ]; then
  [ -r "$META" ] || die "missing task record $META"
  PROJECT=$(meta_value project)
fi
[ -r "$BRIEF" ] || die "unreadable brief $BRIEF"
if [ "$VERB" = new ] && [ "$WAIT" = 0 ]; then
  [ ! -e "$META" ] || die 'task already has a record'
  exec "$SCRIPT_DIR/fm-admission-queue.sh" submit "$ID" -- "${ORIGINAL_ARGS[@]}" --wait
fi
# Template bindings are checked on replay, never just when submitted. The worker
# repeats this guard before publishing because a head can move after launch.
if [ "$VERB" = new ] && grep -q '^PR start:' "$BRIEF"; then
  binding=$(grep '^PR start:' "$BRIEF")
  read -r _ _ shape url head extra <<< "$binding"
  [ -z "${extra:-}" ] && [ "$(printf '%s\n' "$binding" | wc -l)" -eq 1 ] || die 'invalid PR start binding'
  constraint=()
  case "$shape" in
    review)
      [[ " ${ARGS[*]} " = *' --scout '* ]] && [[ " ${ARGS[*]} " = *' --merge-review '* ]] || die 'review template requires --scout --merge-review'
      ;;
    follow-up) ;;
    conflict) constraint=(conflict) ;;
    *) die 'unknown PR start shape' ;;
  esac
  "$SCRIPT_DIR/fm-pr-start-template.sh" verify "$url" "$head" "${constraint[@]}"
fi
INSTRUCTIONS="$DATA/$ID/ship-instructions.md"
if [ "$VERB" = promote ]; then
  if [ "$(meta_value kind)" = scout ]; then
    "$SCRIPT_DIR/fm-promote.sh" "$ID" "${ARGS[@]}"
  else
    [ "$(meta_value kind)" = ship ] && [ -r "$INSTRUCTIONS" ] || die 'promotion requires a scout or an already-promoted ship'
    [ "${#ARGS[@]}" -eq 0 ] || die 'retry an already-promoted ship without promotion options'
  fi
fi

# Do not interpret shell text from resolver output. Read only the named receipt's
# profile as data; launch-time guards remain responsible for its admission.
if [ -n "$PICK" ]; then
  OUTPUT=$("$SCRIPT_DIR/fm-dispatch-resolve.sh" pick "$PICK") || { rc=$?; printf '%s\n' "$OUTPUT"; exit "$rc"; }
else
  OUTPUT=$("$SCRIPT_DIR/fm-dispatch-resolve.sh" "$BRIEF" --project "$(basename "$PROJECT")" --task "$ID" "${RESOLVE_ARGS[@]}") || { rc=$?; printf '%s\n' "$OUTPUT"; exit "$rc"; }
fi
printf '%s\n' "$OUTPUT"
RECEIPT=$(printf '%s\n' "$OUTPUT" | awk '$1 == "receipt:" && $3 == "(one" {print $2}')
case "$RECEIPT" in ''|*[!a-zA-Z0-9_.-]*|.*) printf 'dispatch: no launchable receipt; finish the captain pick or resolve again\n' >&2; exit 3 ;; esac
RECEIPT_FILE="$STATE/dispatch-receipt/$RECEIPT"
PROFILE=$(jq -ce --arg task "$ID" 'select(.task == $task) | .profile | {harness, model: (.model // ""), effort: (.effort // ""), account: (.account // "")} |
  select(.harness | type == "string" and length > 0) |
  select(all(.[]; type == "string" and all(explode[]; . != 0 and . != 10 and . != 13)))' "$RECEIPT_FILE") || die 'receipt profile is unreadable'
H=$(jq -r '.harness' <<<"$PROFILE")
M=$(jq -r '.model' <<<"$PROFILE")
E=$(jq -r '.effort' <<<"$PROFILE")
A=$(jq -r '.account' <<<"$PROFILE")
PROFILE_ARGS=(--harness "$H")
if [ "$VERB" = new ]; then
  [ -z "$M" ] || PROFILE_ARGS+=(--model "$M")
  [ -z "$E" ] || PROFILE_ARGS+=(--effort "$E")
else
  # Omission on control relaunch carries old axes; explicit default clears them.
  PROFILE_ARGS+=(--model "${M:-default}" --effort "${E:-default}")
  if [ -z "$A" ] && [ -n "$(meta_value account)" ]; then
    die 'fm-control cannot clear a recorded account; no worker was stopped'
  fi
fi
[ -z "$A" ] || PROFILE_ARGS+=(--account "$A")
# No recorded-meta exemption here: even same-profile recovery/promotion must
# validate the newly resolved receipt. The launch owner still consumes its own.
"$SCRIPT_DIR/fm-dispatch-resolve.sh" gate --task "$ID" --brief "$BRIEF" "${PROFILE_ARGS[@]}"
case "$VERB" in
  new) exec "$SCRIPT_DIR/fm-spawn.sh" "$ID" "$PROJECT" "${ARGS[@]}" "${PROFILE_ARGS[@]}" ;;
  relaunch) exec "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch "${ARGS[@]}" "${PROFILE_ARGS[@]}" ;;
  promote)
    old_m=$(meta_value model); old_e=$(meta_value effort)
    [ "$old_m" != default ] || old_m=
    [ "$old_e" != default ] || old_e=
    if [ "$H" = "$(meta_value harness)" ] && [ "$M" = "$old_m" ] && [ "$E" = "$old_e" ] && [ "$A" = "$(meta_value account)" ]; then
      exec "$SCRIPT_DIR/fm-send.sh" "fm-$ID" --after-done promote "$(<"$INSTRUCTIONS")"
    fi
    exec "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch "${PROFILE_ARGS[@]}" --note-file "$INSTRUCTIONS"
    ;;
esac
