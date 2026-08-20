#!/usr/bin/env bash
# tests/fm-agy-model-switch-live-e2e.test.sh - the LIVE guard for the in-session
# agy model switch the live ladder descent is built on.
#
# WHY THIS EXISTS SEPARATELY. tests/fm-agy-live-descent.test.sh pins the picker
# classifier and the walk arithmetic against captured agy output, with no
# harness, so CI enforces them everywhere. It cannot notice the one thing that
# would silently break the whole mechanism: agy changing the picker. The
# classifier would keep passing against a fixture agy no longer draws, and the
# descent would refuse in production - safely, but silently and permanently.
# This guard is what catches that, against the agy actually installed.
#
# It is opt-in and on demand because it spends real quota on a real account and
# standard CI has neither the binary nor the credentials. Run it after every agy
# upgrade, and refresh docs/verification/agy-model-switch.md from what it prints.
#
# What it proves, end to end, in a disposable Herdr lab session:
#   1. Driving `/model` into a RUNNING agy pane opens the picker this fleet's
#      classifier recognises.
#   2. The walk computed from that live picker lands on the intended rung.
#   3. Both confirmation signals appear and name that rung.
#   4. The worker's conversation and context SURVIVE the switch, which is the
#      entire reason this is preferred over relaunching the worker.
#
# A missing agy, herdr, or jq is reported and skipped, never passed over
# silently: a guard that checked nothing must not look like a guard that passed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_AGY_MODEL_SWITCH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AGY_MODEL_SWITCH_LIVE_E2E=1 to run the credentialed live agy model-switch guard"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-agy-descent-lib.sh
. "$ROOT/bin/fm-agy-descent-lib.sh"

for tool in agy herdr jq; do
  command -v "$tool" >/dev/null 2>&1 \
    || fail "$tool is not installed, so this guard checked nothing; install it or do not claim this evidence"
done

AGY_VERSION=$(agy --version 2>/dev/null | head -1)
[ -n "$AGY_VERSION" ] || fail "agy did not report a version; refusing to record evidence against an unknown build"
echo "# agy $AGY_VERSION"

# The rungs this guard moves between. Deliberately NOT rung 1: the captain's
# reserved quarter of Opus 4.6 is exactly what the descent protects, and a test
# must never be the thing that spends it.
FROM_KEBAB=gemini-3.1-pro-high
FROM_DISPLAY='Gemini 3.1 Pro (High)'
TO_DISPLAY='Gemini 3.7 Flash (High)'
CODEWORD="FM-LIVE-$$"

HELPER="$ROOT/bin/fm-herdr-lab.sh"
[ -x "$HELPER" ] || fail "the Herdr lab helper is missing; this guard must never touch the live default session"
SESSION=$(FM_HERDR_LAB_LABEL=agy-switch "$HELPER" name agy-switch)
WORK=$(fm_test_tmproot fm-agy-switch)/work
mkdir -p "$WORK"

cleanup() { "$HELPER" teardown "$SESSION" >/dev/null 2>&1 || true; }
trap cleanup EXIT

L() { "$HELPER" run "$SESSION" "$@"; }
CAP() { L pane read "$PANE" --source recent --lines 200 2>/dev/null | tail -n 60; }

"$HELPER" provision "$SESSION" >/dev/null || fail "could not provision the isolated Herdr lab session"
WS=$(L workspace create --cwd "$WORK" --label agyswitch --no-focus 2>&1) \
  || fail "could not create the lab workspace: $WS"
PANE=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
[ -n "$PANE" ] || fail "the lab workspace reported no pane to drive"

L pane run "$PANE" agy --model "$FROM_KEBAB" --dangerously-skip-permissions >/dev/null
for _ in $(seq 1 30); do
  sleep 3
  case "$(CAP)" in *'trust the contents'*|*'quota:'*) break ;; esac
done
case "$(CAP)" in
  *'trust the contents'*) L pane send-keys "$PANE" Enter >/dev/null; sleep 6 ;;
esac

BEFORE=$(CAP)
[ "$(fm_agy_footer_model "$BEFORE")" = "$FROM_DISPLAY" ] \
  || fail "the worker did not come up on $FROM_DISPLAY; got '$(fm_agy_footer_model "$BEFORE")'"
pass "a live agy worker is running on $FROM_DISPLAY"

# Give the worker something only its conversation can answer, so "the
# conversation survived" is a fact this guard establishes rather than assumes.
L pane send-text "$PANE" "Remember this codeword: $CODEWORD. Reply with only the word ACK." >/dev/null
sleep 1
L pane send-keys "$PANE" Enter >/dev/null
for _ in $(seq 1 40); do
  sleep 3
  case "$(CAP)" in *ACK*) break ;; esac
done
case "$(CAP)" in
  *ACK*) : ;;
  *) fail "the worker never answered on $FROM_DISPLAY, so nothing downstream would mean anything" ;;
esac
pass "the worker holds a conversation this guard can check afterwards"

# --- the mechanism ----------------------------------------------------------

L pane send-text "$PANE" '/model' >/dev/null
sleep 1
L pane send-keys "$PANE" Enter >/dev/null
PICKER=
for _ in $(seq 1 12); do
  sleep 2
  PICKER=$(CAP)
  fm_agy_descent_is_picker "$PICKER" && break
done
fm_agy_descent_is_picker "$PICKER" \
  || fail "agy $AGY_VERSION did not draw a picker this fleet recognises; the live descent is disabled until fm_agy_descent_is_picker is taught the new shape. Pane was:"$'\n'"$PICKER"
pass "driving /model into a running pane opens the picker the classifier recognises"

PLAN=$(fm_agy_descent_plan "$PICKER" "$TO_DISPLAY") \
  || fail "agy $AGY_VERSION offers no walk from the live picker to $TO_DISPLAY. Pane was:"$'\n'"$PICKER"
echo "# live plan: $PLAN"

KEY=${PLAN%% *}
COUNT=${PLAN#* }
EFFORT=${COUNT#* }
COUNT=${COUNT%% *}

i=0
while [ "$i" -lt "$COUNT" ]; do
  L pane send-keys "$PANE" "$KEY" >/dev/null
  sleep 0.4
  i=$((i + 1))
done
if [ "$EFFORT" = high ]; then
  i=0
  while [ "$i" -lt "$FM_AGY_DESCENT_EFFORT_KEYS" ]; do
    L pane send-keys "$PANE" Right >/dev/null
    sleep 0.3
    i=$((i + 1))
  done
fi

sleep 1
LANDED=$(CAP)
ROWS=$(fm_agy_descent_picker_rows "$LANDED")
SELECTED=$(fm_agy_descent_selected_row "$ROWS") || SELECTED=
RESOLVED=$(fm_agy_descent_row_for "$ROWS" "$TO_DISPLAY") || RESOLVED=
[ -n "$SELECTED" ] && [ "$SELECTED" = "${RESOLVED%%	*}" ] \
  || fail "the walk computed from the live picker landed on '${SELECTED:-nothing}', not on $TO_DISPLAY. Pane was:"$'\n'"$LANDED"
pass "the walk computed from the live picker lands on $TO_DISPLAY"

L pane send-keys "$PANE" Enter >/dev/null
AFTER=
for _ in $(seq 1 15); do
  sleep 2
  AFTER=$(CAP)
  fm_agy_descent_confirms "$AFTER" "$TO_DISPLAY" && break
done
fm_agy_descent_confirms "$AFTER" "$TO_DISPLAY" \
  || fail "agy $AGY_VERSION did not confirm the switch to $TO_DISPLAY from both signals. Pane was:"$'\n'"$AFTER"
pass "the switch is confirmed by agy's own acknowledgement and by the footer"

# --- the whole point --------------------------------------------------------

L pane send-text "$PANE" 'What was the codeword I gave you? Reply with only the codeword.' >/dev/null
sleep 1
L pane send-keys "$PANE" Enter >/dev/null
RECALL=
for _ in $(seq 1 40); do
  sleep 3
  RECALL=$(CAP)
  case "$RECALL" in *"$CODEWORD"*) break ;; esac
done
case "$RECALL" in
  *"$CODEWORD"*) : ;;
  *) fail "the worker lost its conversation across the switch, so an in-session switch buys nothing over a relaunch. Pane was:"$'\n'"$RECALL" ;;
esac
[ "$(fm_agy_footer_model "$RECALL")" = "$TO_DISPLAY" ] \
  || fail "the worker did not stay on $TO_DISPLAY after answering"
pass "the worker keeps its conversation across the switch and answers on the new model"

echo "# evidence captured against agy $AGY_VERSION"
