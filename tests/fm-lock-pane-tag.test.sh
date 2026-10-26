#!/usr/bin/env bash
# Behavior tests for bin/fm-lock-pane-tag.sh and its session-start wiring, using
# a recording fake Herdr client. No live pane or session is ever touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-pane-tag)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/herdr.log"
TAG="$ROOT/bin/fm-lock-pane-tag.sh"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
[ "${FM_FAKE_HERDR_FAIL:-0}" = 1 ] && { echo "herdr exploded" >&2; exit 1; }
exit 0
SH
chmod +x "$FAKEBIN/herdr"

export FM_FAKE_HERDR_LOG="$LOG"
export PATH="$FAKEBIN:$PATH"
export HERDR_PANE_ID=w9:p9
unset HERDR_SESSION

run_tag() { : > "$LOG"; "$TAG" "$@"; }

# set: holder
run_tag holder || fail "holder exits 0"
line=$(cat "$LOG")
case "$line" in
  *"pane report-metadata w9:p9 --source fm-lock"*"--token fm_lock=LOCK HOLDER"*"--clear-token fm_readonly"*"--display-agent firstmate (lock)"*"--session default") ;;
  *) fail "holder call shape: $line" ;;
esac
pass "holder sets the lock token, clears read-only, labels the border"

# flip: read-only after holder
run_tag readonly || fail "readonly exits 0"
line=$(cat "$LOG")
case "$line" in
  *"--token fm_readonly=READ-ONLY"*"--clear-token fm_lock"*"--display-agent firstmate (read-only)"*) ;;
  *) fail "readonly call shape: $line" ;;
esac
case "$line" in *"fm_lock=LOCK HOLDER"*) fail "readonly must not set the lock token" ;; esac
pass "readonly flips the tag and never carries the lock token"

# clear
run_tag clear || fail "clear exits 0"
line=$(cat "$LOG")
case "$line" in
  *"--clear-token fm_lock"*"--clear-token fm_readonly"*"--clear-display-agent"*) ;;
  *) fail "clear call shape: $line" ;;
esac
case "$line" in *"--token "*) fail "clear must set no token" ;; esac
pass "clear drops both tokens and the border label"

# named session
HERDR_SESSION=fm-lab-x run_tag holder
case "$(cat "$LOG")" in *"--session fm-lab-x") ;; *) fail "named session not honored: $(cat "$LOG")" ;; esac
pass "HERDR_SESSION selects the session"

# never blocks: herdr failure, outside herdr, no herdr binary, bad usage
FM_FAKE_HERDR_FAIL=1 run_tag holder || fail "herdr failure must still exit 0"
pass "herdr failure is silent"

: > "$LOG"
( unset HERDR_PANE_ID; "$TAG" holder ) || fail "outside a pane must exit 0"
[ ! -s "$LOG" ] || fail "outside a pane must not call herdr"
pass "outside a herdr pane does nothing"

"$TAG" bogus 2>/dev/null && fail "unknown mode must be refused"
pass "unknown mode refused"

