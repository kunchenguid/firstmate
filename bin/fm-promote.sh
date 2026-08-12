#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--web|--no-web]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-web-gate-lib.sh
. "$SCRIPT_DIR/fm-web-gate-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
WEB=0
WEB_SET=0
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
    --web)
      [ "$WEB_SET" -eq 0 ] || { echo "error: --web and --no-web may be supplied only once" >&2; exit 1; }
      WEB=1; WEB_SET=1
      ;;
    --no-web)
      [ "$WEB_SET" -eq 0 ] || { echo "error: --web and --no-web may be supplied only once" >&2; exit 1; }
      WEB=0; WEB_SET=1
      ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--web|--no-web]" >&2; exit 1; }
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
[ "$WEB_SET" -eq 1 ] || {
  echo "error: promotion requires an explicit web-surface declaration: pass --web or --no-web" >&2
  exit 1
}

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
BRIEF_TMP=
WEB_GATE_TMP=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  [ -z "$BRIEF_TMP" ] || rm -f -- "$BRIEF_TMP" 2>/dev/null || true
  [ -z "$WEB_GATE_TMP" ] || rm -f -- "$WEB_GATE_TMP" 2>/dev/null || true
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

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
BRIEF="$DATA/$ID/brief.md"
[ -f "$BRIEF" ] || { echo "error: no brief at $BRIEF" >&2; exit 1; }

SURFACE=non-web
[ "$WEB" -eq 1 ] && SURFACE=web
surface_count=$(fm_web_gate_surface_line_count "$BRIEF")
existing_surface=$(fm_web_gate_surface_contract "$BRIEF" 2>/dev/null || true)
if [ "$surface_count" -gt 1 ] || { [ "$surface_count" -eq 1 ] && [ -z "$existing_surface" ]; }; then
  echo "error: $BRIEF contains more than one Surface contract line" >&2
  exit 1
fi
if [ -n "$existing_surface" ] && [ "$existing_surface" != "$SURFACE" ]; then
  echo "error: promotion surface $SURFACE disagrees with the brief's Surface contract: $existing_surface" >&2
  exit 1
fi
if [ -n "$existing_surface" ] && [ "$existing_surface" != web ] && [ "$existing_surface" != non-web ]; then
  echo "error: $BRIEF has an invalid Surface contract" >&2
  exit 1
fi
if [ "$WEB" -eq 1 ] && [ "$existing_surface" = web ]; then
  existing_gate_count=$(grep -Ec '^Web gate contract: custom-domain/chrome-devtools-axi/revision-marker/screenshot$' "$BRIEF" || true)
  if [ "$existing_gate_count" -ne 1 ] \
    || ! fm_web_gate_provenance_present "$BRIEF"; then
    echo "error: $BRIEF declares web but lacks the canonical Web gate contract or body; promotion refused" >&2
    exit 1
  fi
fi

BRIEF_TMP="$STATE/.$ID.brief.promote.${BASHPID:-$$}"
WEB_GATE_TMP="$STATE/.$ID.web-gate.promote.${BASHPID:-$$}"
if [ "$WEB" -eq 1 ]; then
  fm_web_gate_body_text > "$WEB_GATE_TMP"
fi
awk -v surface="$SURFACE" -v web="$WEB" -v gate="$WEB_GATE_TMP" '
  BEGIN { inserted_surface = 0; inserted_gate = 0 }
  /^# Definition of done$/ && !inserted_surface {
    print
    if (web == 1 && gate_line_count == 0) {
      while ((getline line < gate) > 0) print line
      close(gate)
    }
    if (surface_line_count == 0) print "Surface contract: " surface
    if (web == 1 && gate_line_count == 0) {
      print "Web gate contract: custom-domain/chrome-devtools-axi/revision-marker/screenshot"
      print "Web gate provenance: surface=web sha256:pending"
    }
    inserted_surface = 1
    next
  }
  { print }
  END { exit inserted_surface ? 0 : 1 }
' surface_line_count="$surface_count" gate_line_count="$(grep -Ec '^Web gate contract:' "$BRIEF" || true)" "$BRIEF" > "$BRIEF_TMP" || {
  rm -f -- "$BRIEF_TMP" "$WEB_GATE_TMP"
  echo "error: $BRIEF has no Definition of done section; promotion refused" >&2
  exit 1
}
if [ "$WEB" -eq 1 ]; then
  if grep -F 'Web gate provenance: surface=web sha256:pending' "$BRIEF_TMP" >/dev/null 2>&1; then
    fm_web_gate_stamp_file "$BRIEF_TMP" || {
      rm -f -- "$BRIEF_TMP" "$WEB_GATE_TMP"
      BRIEF_TMP=
      WEB_GATE_TMP=
      echo "error: promoted web brief could not be stamped; promotion refused" >&2
      exit 1
    }
  fi
  promoted_gate_count=$(grep -Ec '^Web gate contract: custom-domain/chrome-devtools-axi/revision-marker/screenshot$' "$BRIEF_TMP" || true)
  if [ "$promoted_gate_count" -ne 1 ] \
    || ! fm_web_gate_provenance_present "$BRIEF_TMP"; then
    rm -f -- "$BRIEF_TMP" "$WEB_GATE_TMP"
    BRIEF_TMP=
    WEB_GATE_TMP=
    echo "error: promoted web brief lacks the canonical Web gate contract or body; promotion refused" >&2
    exit 1
  fi
fi
mv "$BRIEF_TMP" "$BRIEF"
BRIEF_TMP=
rm -f -- "$WEB_GATE_TMP"
WEB_GATE_TMP=

TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
mv "$TMP" "$META"
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO surface=$SURFACE (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
