#!/usr/bin/env bash
# tests/fm-backend-herdr-prompt-command-scrub.test.sh - real herdr regression
# coverage for the 2026-09-21 fleet-wide launch wedge (see
# FM_BACKEND_PROMPT_COMMAND_SCRUB in bin/fm-backend.sh): a fleet that runs
# inside a tool (Herdr itself) exporting a bash-preexec PROMPT_COMMAND into
# its own process environment hands that same exported string, minus the
# matching __bp_* function definitions, to every fresh pane a Herdr session
# server creates. Mirrors tests/fm-backend-herdr-smoke.test.sh's real-herdr,
# always-isolated-lab-session technique (never the default session).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-pc-scrub-$$"
export HERDR_SESSION="$SESSION"
cleanup_all() {
  [ -n "${SCRATCH:-}" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT

# The poisoned string from the incident transcripts: bash-preexec's
# PROMPT_COMMAND with none of its __bp_* function definitions along for the
# ride (shell functions never propagate through the environment). Exported
# before ANY herdr call for this brand-new session name, so whichever call
# first starts this session's own dedicated server captures it - exactly
# mirroring Herdr exporting it into the primary's own environment.
POISON=$'history -a; __bp_precmd_invoke_cmd\nhistory -a\n:\n__bp_interactive_mode'
export PROMPT_COMMAND="$POISON"

fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
[ -n "$FM_BACKEND_PROMPT_COMMAND_SCRUB" ] || fail "FM_BACKEND_PROMPT_COMMAND_SCRUB is not set after sourcing bin/fm-backend.sh"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-pc-scrub.XXXXXX")

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_herdr_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_for_file() {  # <path> [samples]
  local path=$1 samples=${2:-100} i=0
  while [ "$i" -lt "$samples" ]; do
    [ -f "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$SCRATCH") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WSID=${CONTAINER#*:}

# --- mechanism (a): fm_backend_herdr_create_task overrides the new tab's own
# launched-process PROMPT_COMMAND, so a task pane never inherits the poison in
# the first place. ------------------------------------------------------------

LABEL_A="fm-pcscrub-a"
TASK_IDS_A=$(fm_backend_herdr_create_task "$CONTAINER" "$LABEL_A" "$SCRATCH" "$SEEDED_TAB_ID") \
  || fail "fm_backend_herdr_create_task failed to create the task tab"
read -r _TAB_A PANE_A <<EOF
$TASK_IDS_A
EOF
[ -n "$PANE_A" ] || fail "mechanism (a): create_task did not return a pane id"
TARGET_A="$SESSION:$PANE_A"

# The healthy gate is "no bash-preexec error ever fires", not "PROMPT_COMMAND
# reads empty": on a machine whose shell profile installs bash-preexec
# correctly, the pane's own rc files re-populate PROMPT_COMMAND with a
# legitimate, function-backed value once they run after the --env override
# clears the inherited poison - and that must keep working exactly as before.
fm_backend_herdr_send_text_line "$TARGET_A" "printf 'ready-%s\\n' a" \
  || fail "mechanism (a): send_text_line failed"
wait_for_capture_text "$TARGET_A" "ready-a" \
  || fail "mechanism (a): the task tab's shell did not become ready"
out=$(fm_backend_herdr_capture "$TARGET_A" 200)
case "$out" in
  *'command not found'*) fail "mechanism (a): a task tab created by fm_backend_herdr_create_task still shows a bash-preexec error"$'\n'"$out" ;;
esac
pass "real herdr: fm_backend_herdr_create_task creates a task tab that never shows a bash-preexec error, whether or not the pane's own profile re-installs PROMPT_COMMAND afterward"
fm_backend_herdr_kill "$TARGET_A"

# Closing a workspace's LAST remaining tab deletes the whole workspace on
# real herdr (bin/backends/herdr.sh's fm_backend_herdr_create_task header),
# and mechanism (a)'s task tab was the only one left once its create_task call
# pruned the seeded default tab - so $WSID is stale now. Real firstmate
# spawns always re-run container_ensure immediately before create_task
# rather than reusing an earlier reference (mirrors
# tests/fm-backend-herdr-smoke.test.sh); do the same here.
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$SCRATCH") || fail "container_ensure for mechanism (b) failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
WSID=${CONTAINER#*:}

# --- mechanism (b): the universal floor. Simulate a pane that inherited the
# poison DESPITE mechanism (a) (an installed herdr without --env support, or a
# creation path this brief did not touch) and prove the scrub line
# fm-spawn.sh sends - FM_BACKEND_PROMPT_COMMAND_SCRUB - clears it before the
# launch command is parsed, and a launch command shaped like the real one (a
# pre-launch export, then a two-step literal+Enter source of a staged file
# containing a command substitution) is delivered as one closed command. ----

LABEL_B="fm-pcscrub-b"
RAW_OUT=$(fm_backend_herdr_cli "$SESSION" tab create --workspace "$WSID" --cwd "$SCRATCH" --label "$LABEL_B" --no-focus 2>/dev/null) \
  || fail "mechanism (b) setup: plain herdr tab create failed"
PANE_B=$(printf '%s' "$RAW_OUT" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE_B" ] || fail "mechanism (b) setup: could not parse the unpatched-shape tab's pane id"
TARGET_B="$SESSION:$PANE_B"

# Best-effort sanity check: on a machine whose default pane shell is a login
# shell, its own profile can reinstall a working PROMPT_COMMAND before the
# very first prompt ever renders, which legitimately hides the inherited
# poison here (the same healthy self-repair the mechanism (a) assertion above
# depends on) - so this is a note, not a hard requirement, for this scenario
# to still be meaningful; the load-bearing assertions are the delivery-intact
# checks below, which exercise the real production primitives regardless.
fm_backend_herdr_send_text_line "$TARGET_B" "printf 'ready-%s\\n' b"
wait_for_capture_text "$TARGET_B" "ready-b" \
  || fail "mechanism (b): the unpatched-shape pane's shell did not become ready"
out=$(fm_backend_herdr_capture "$TARGET_B" 200)
case "$out" in
  *'__bp_precmd_invoke_cmd: command not found'*) : ;;
  *) echo "note: the unpatched-shape pane did not show the poisoned PROMPT_COMMAND before its scrub - this pane shell's own profile likely reinstalled it first; the delivery-intact assertions below still cover the fix" >&2 ;;
esac

# The exact scrub line fm-spawn.sh sends as the very first text into the pane.
fm_backend_herdr_send_text_line "$TARGET_B" "$FM_BACKEND_PROMPT_COMMAND_SCRUB" \
  || fail "mechanism (b): could not send the scrub line"
# A marker line so later assertions can look only at what the pane showed
# AFTER the scrub, not at this scenario's own deliberately-poisoned
# scrollback from moments ago.
fm_backend_herdr_send_text_line "$TARGET_B" 'printf "post-scrub-marker-%s\n" ready'
wait_for_capture_text "$TARGET_B" "post-scrub-marker-ready" \
  || fail "mechanism (b): the pane did not execute the post-scrub marker line"

# The rest of fm-spawn.sh's pre-launch sequence: an export line via
# send_text_line, then the launch command via the two-step
# send_literal + send_key(Enter) form, sourcing a staged file (exactly what
# LAUNCH_FILE is) whose single logical command embeds a real command
# substitution - the shape the incident report says never closed.
fm_backend_herdr_send_text_line "$TARGET_B" "export GOTMPDIR=$SCRATCH/gotmp"

BRIEF_MARKER="$SCRATCH/brief-marker"
printf 'launch-brief-payload\n' > "$BRIEF_MARKER"
LAUNCH_OUT="$SCRATCH/launch-out"
DONE_MARKER="$SCRATCH/launch-done"
LAUNCH_FILE="$SCRATCH/launch.sh"
cat > "$LAUNCH_FILE" <<EOF
echo "brief=\$(cat '$BRIEF_MARKER')" > '$LAUNCH_OUT' && touch '$DONE_MARKER'
EOF

fm_backend_herdr_send_literal "$TARGET_B" ". '$LAUNCH_FILE'" \
  || fail "mechanism (b): fm_backend_herdr_send_literal failed"
fm_backend_herdr_send_key "$TARGET_B" Enter \
  || fail "mechanism (b): fm_backend_herdr_send_key Enter failed"

wait_for_file "$DONE_MARKER" \
  || fail "mechanism (b): the launch command (sourced from the staged file) never completed - the agent endpoint never came up"
[ "$(cat "$LAUNCH_OUT")" = "brief=launch-brief-payload" ] \
  || fail "mechanism (b): the embedded command substitution in the launch command did not resolve correctly - got: $(cat "$LAUNCH_OUT" 2>/dev/null)"

out=$(fm_backend_herdr_capture "$TARGET_B" 200 | awk '/post-scrub-marker-ready/{found=1; next} found')
case "$out" in
  *'command not found'*) fail "mechanism (b): a bash-preexec error still appeared after the scrub line"$'\n'"$out" ;;
esac
pass "real herdr: the scrub line clears an inherited poisoned PROMPT_COMMAND, and the launch command (export + two-step literal/Enter source of a file with an embedded command substitution) is delivered as one closed command and completes"

fm_backend_herdr_kill "$TARGET_B"

cleanup_all
trap - EXIT
