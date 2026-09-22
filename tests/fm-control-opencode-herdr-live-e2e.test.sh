#!/usr/bin/env bash
# tests/fm-control-opencode-herdr-live-e2e.test.sh - live OpenCode-on-Herdr
# guard for the wedged-worker stop path.
#
# The 2026-09-20 incident: `fm-control exit` refused an OpenCode worker on
# Herdr with composer state `unknown`, including a genuinely idle empty
# composer, because OpenCode 1.18 draws status chrome immediately under its
# `╹▀` floor. This guard launches a real installed OpenCode in an isolated
# Herdr lab, requires the shared classifier to read `empty`, then stops it
# through `bin/fm-control.sh exit` and requires the agent gone, the pane
# still there, and the local copy untouched. No prompt is submitted.
#
# Default-on wherever herdr, jq, and opencode are installed. A guard that
# spends no model tokens runs by default; FM_CONTROL_OPENCODE_HERDR_LIVE=0
# (or FM_LIVE=0) turns it off.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CONTROL_OPENCODE_HERDR_LIVE herdr jq opencode

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-oc-stop-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-oc-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/ocstop"
printf '# brief\n' > "$HOME_DIR/data/ocstop/brief.md"

PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b ocstop "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-ocstop" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
TARGET="$SESSION:$PANE_ID"

{
  echo "window=$TARGET"
  echo "endpoint_task_id=ocstop"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=opencode"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/ocstop.meta"

OPENCODE_BIN=$(command -v opencode)
printf -v OPENCODE_Q '%q' "$OPENCODE_BIN"
fm_backend_herdr_send_text_line "$TARGET" "$OPENCODE_Q" \
  || fail "could not launch OpenCode in the lab pane"

OC_VERSION=$(opencode --version 2>/dev/null | head -1 || printf 'version-unknown')
# Nothing is ever sent to this pane before the verdict is read. A screen this
# guard cannot classify fails loudly; it is never keyed at in the hope of
# clearing something, which is the behaviour the change under test exists to
# prevent.
verdict=
screen=
i=0
budget=${FM_CONTROL_OPENCODE_HERDR_LIVE_POLLS:-45}
while [ "$i" -lt "$budget" ]; do
  verdict=$(fm_backend_herdr_composer_state "$TARGET")
  if [ "$verdict" = empty ]; then
    # The SAME frame the verdict was read from: fm_backend_herdr_composer_state
    # classifies the ANSI capture at $FM_COMPOSER_CAPTURE_LINES rows, so a
    # longer plain scrollback would let rows the classifier never saw vouch for
    # rows it did.
    screen=$(fm_backend_herdr_capture_ansi "$TARGET" "$FM_COMPOSER_CAPTURE_LINES" 2>/dev/null \
      | fm_composer_strip_ansi || true)
    break
  fi
  i=$((i + 1))
  sleep 1
done

if [ "$verdict" != empty ]; then
  printf '# OpenCode pane tail at failure (verdict=%s):\n' "${verdict:-unreadable}" >&2
  fm_backend_herdr_capture "$TARGET" 20 2>/dev/null | sed 's/^/#   /' >&2
  fail "opencode ($OC_VERSION) on herdr: idle composer classified '${verdict:-unreadable}', expected empty (the original unknown refusal)"
fi

# `empty` alone proves nothing: a bare shell prompt using an agent glyph reads
# empty too. The verdict counts only if the screen behind it is the layout this
# regression is about - OpenCode's `╹▀` left-bar floor with its status row
# directly under it, the two facts the classifier change rests on.
FLOOR_SEEN=no
STATUS_SEEN=no
printf '%s\n' "$screen" | grep -qF '╹▀' && FLOOR_SEEN=yes
printf '%s\n' "$screen" | grep -qF 'ctrl+p commands' && STATUS_SEEN=yes
printf '# opencode layout behind the empty verdict: floor=%s status-row=%s\n' \
  "$FLOOR_SEEN" "$STATUS_SEEN"
if [ "$FLOOR_SEEN" != yes ] || [ "$STATUS_SEEN" != yes ]; then
  printf '# OpenCode pane tail (verdict=empty but layout unproven):\n' >&2
  printf '%s\n' "$screen" | tail -n 20 | sed 's/^/#   /' >&2
  fail "opencode ($OC_VERSION) on herdr: composer read empty without OpenCode's left-bar floor and status row on screen, so this run did not exercise the regression"
fi
pass "opencode ($OC_VERSION) on herdr: idle empty composer classifies empty under the ╹▀ floor and its status row"

# Register the live process so the recovery-grade classifier can attribute
# the pane. OpenCode's TUI is up (composer empty); report-agent plus
# process-info is how the smoke test proves `alive`.
herdr pane report-agent "$PANE_ID" --source fm-oc-stop-live --agent opencode \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register the live OpenCode process on the lab pane"
alive_i=0
state=
while [ "$alive_i" -lt 20 ]; do
  state=$(fm_backend_agent_state herdr "$TARGET")
  [ "$state" = alive ] && break
  sleep 0.2
  alive_i=$((alive_i + 1))
done
if [ "$state" != alive ]; then
  printf '# agent_state=%s process_state=%s\n' "$state" \
    "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" >&2
  herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>&1 | sed 's/^/#   /' >&2
  fail "OpenCode pane never classified alive (last state: ${state:-none})"
fi

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=20 \
  "$ROOT/bin/fm-control.sh" ocstop exit 2>&1) \
  || fail "fm-control exit should stop the live OpenCode worker: $OUT"
case "$OUT" in
  "stopped ocstop"*) : ;;
  *) fail "expected 'stopped ocstop', got: $OUT" ;;
esac

STATE=$(fm_backend_agent_state herdr "$TARGET")
[ "$STATE" = dead ] || fail "after exit the OpenCode pane reads '$STATE' rather than dead"
fm_backend_herdr_cli "$SESSION" pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "exit must not remove the OpenCode pane"
[ -d "$WT" ] || fail "exit must not remove the local copy"
pass "opencode ($OC_VERSION) on herdr: fm-control exit stops the worker and preserves the pane and local copy"
