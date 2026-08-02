#!/usr/bin/env bash
# Behavioral probe for Herdr submit retries at an empty composer versus a
# permission modal. The fixture records the actual text/key stream delivered
# by the production fm-send -> Herdr adapter boundary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
STUB="$ROOT/tests/fixtures/herdr-permission-tui.py"
TMP_ROOT=$(mktemp -d "$ROOT/.fm-send-permission-modal.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
STATE_FILE="$TMP_ROOT/tui-state.json"
SESSION=permission-stub
TARGET="$SESSION:w1:p1"
MESSAGE='permission boundary probe'

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/data"
cp "$STUB" "$FAKEBIN/herdr"
chmod 0500 "$FAKEBIN/herdr"
chmod 0700 "$FAKEBIN" "$HOME_DIR" "$HOME_DIR/state" "$HOME_DIR/data"

stub() {
  FM_PERMISSION_TUI_STATE="$STATE_FILE" FM_PERMISSION_TUI_SESSION="$SESSION" \
    python3 "$STUB" "$@"
}

send_to_stub() {
  FM_PERMISSION_TUI_STATE="$STATE_FILE" FM_PERMISSION_TUI_SESSION="$SESSION" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_HOME="$HOME_DIR" FM_SEND_RETRIES=3 FM_SEND_SLEEP=0.01 FM_SEND_SETTLE=0 \
    PATH="$FAKEBIN:$PATH" "$SEND" "$TARGET" "$MESSAGE"
}

stub stub-init composer
send_to_stub >/dev/null 2>"$TMP_ROOT/composer.err" \
  || fail "empty-composer control did not submit: $(cat "$TMP_ROOT/composer.err")"
COMPOSER=$(stub stub-snapshot)
jq -e --arg message "$MESSAGE" '
  .approved == false
  and .turn_started == true
  and ([.events[] | select(.event == "text" and .value == $message)] | length == 1)
  and ([.events[] | select(.event == "key" and .value == "enter")] | length == 1)
  and ([.events[] | select(.event == "turn-started")] | length == 1)
' >/dev/null <<<"$COMPOSER" \
  || fail "empty-composer control did not receive one text and one submitting Enter: $COMPOSER"
printf 'composer-events=%s\n' "$COMPOSER"
pass "permission TUI: empty composer accepts staged text and one submitting Enter"

stub stub-init modal
if send_to_stub >/dev/null 2>"$TMP_ROOT/modal.err"; then
  fail "permission-modal guard allowed the send path to continue"
fi
MODAL=$(stub stub-snapshot)
jq -e '
  .approved == false
  and .turn_started == false
  and .mode == "modal"
  and .events == []
' >/dev/null <<<"$MODAL" \
  || fail "permission-modal refusal delivered text or a key: $MODAL"
assert_contains "$(cat "$TMP_ROOT/modal.err")" "could not prove an empty Herdr composer" \
  "permission-modal refusal did not surface the fail-closed blocker"
printf 'modal-events=%s\n' "$MODAL"
pass "permission TUI: modal refusal sends neither staged text nor Enter"

stub stub-init pending
if send_to_stub >/dev/null 2>"$TMP_ROOT/pending.err"; then
  fail "pending-composer guard allowed the send path to continue"
fi
PENDING=$(stub stub-snapshot)
jq -e '
  .approved == false
  and .turn_started == false
  and .mode == "composer"
  and .composer_text == "existing unsent input"
  and .events == []
' >/dev/null <<<"$PENDING" \
  || fail "pending-composer refusal changed the existing input or delivered a key: $PENDING"
assert_contains "$(cat "$TMP_ROOT/pending.err")" "composer already contains pending input" \
  "pending-composer refusal did not surface its distinct blocker"
printf 'pending-events=%s\n' "$PENDING"
pass "permission TUI: pending composer refuses without changing input or pressing Enter"

stub stub-init unreadable
if send_to_stub >/dev/null 2>"$TMP_ROOT/unreadable.err"; then
  fail "unreadable-composer guard allowed the send path to continue"
fi
UNREADABLE=$(stub stub-snapshot)
jq -e '
  .approved == false
  and .turn_started == false
  and .mode == "unreadable"
  and .events == []
' >/dev/null <<<"$UNREADABLE" \
  || fail "unreadable-composer refusal delivered text or a key: $UNREADABLE"
assert_contains "$(cat "$TMP_ROOT/unreadable.err")" "could not prove an empty Herdr composer" \
  "unreadable-composer refusal did not surface the UNKNOWN blocker"
printf 'unreadable-events=%s\n' "$UNREADABLE"
pass "permission TUI: unreadable composer refuses without staging text or pressing Enter"

stub stub-init malformed
if send_to_stub >/dev/null 2>"$TMP_ROOT/malformed.err"; then
  fail "malformed-composer guard allowed the send path to continue"
fi
MALFORMED=$(stub stub-snapshot)
jq -e '
  .approved == false
  and .turn_started == false
  and .mode == "malformed"
  and .events == []
' >/dev/null <<<"$MALFORMED" \
  || fail "malformed-composer refusal delivered text or a key: $MALFORMED"
assert_contains "$(cat "$TMP_ROOT/malformed.err")" "could not prove an empty Herdr composer" \
  "malformed-composer refusal did not surface the UNKNOWN blocker"
printf 'malformed-events=%s\n' "$MALFORMED"
pass "permission TUI: malformed composer refuses without staging text or pressing Enter"
