#!/usr/bin/env bash
# Behavior tests for the Lavish answer-receipt lifecycle (bin/fm-procevent-lavish.sh).
#
# Every visible state - Received, Saved, Applying, Complete, Already received -
# is proven to exist only after its owning fact: durable capture, the guarded
# keyed-answer intake's return, and the handler's own applying and complete
# calls. Retirement of an ended review is proven to wait for the final receipt's
# delivery poll, agent-reply failures are proven to retry without silent
# completion, exact replays are proven to be reported rather than re-applied,
# and the receipts record is proven to survive the restart-driven reconcile loop
# that re-arms each poll. Everything runs through the real runner and the real
# keyed-answer intake against a stand-in for the published poll shape; no live
# Lavish server is started.
#
# The destructive-poll loss limitation is deliberately not contradicted here:
# the only durability under test is Firstmate's own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-lavish-receipt)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

ADAPTER="$ROOT/bin/fm-procevent-lavish.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"
STUB_ROOT="$TMP_ROOT/stub"
STUB_QUEUE="$STUB_ROOT/queue"
STUB_IDX="$STUB_ROOT/idx"
STUB_LOG="$STUB_ROOT/argv.log"
STUB_FAIL_ONCE="$STUB_ROOT/fail-once"
STUB_BIN_DIR="$STUB_ROOT/bin"

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  printf '%s\n' "$home"
}

run_lavish() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ADAPTER" "$@"
}

pe() {  # <home> <args...>
  FM_HOME="$1" "$RUNNER" "${@:2}"
}

run_captain() {  # <home> <args...>
  local home=$1
  shift
  (
    cd "$home" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-captain-hold.sh" "$@"
  )
}

tasks_in() {  # <home> <args...>
  local home=$1
  shift
  (
    cd "$home" && tasks-axi "$@"
  )
}

install_stub() {
  mkdir -p "$STUB_BIN_DIR"
  : > "$STUB_QUEUE"
  rm -f "$STUB_IDX" "$STUB_LOG" "$STUB_FAIL_ONCE"
  cat > "$STUB_BIN_DIR/lavish-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
if [ -e "$STUB_FAIL_ONCE" ]; then
  rm -f "$STUB_FAIL_ONCE"
  exit 1
fi
n=\$(cat "$STUB_IDX" 2>/dev/null || echo 0)
n=\$((n + 1))
printf '%s\\n' "\$n" > "$STUB_IDX"
awk -v want="\$n" '
  /^### \$/ { seen++; next }
  seen == want - 1 { print; got = 1 }
  END { exit got ? 0 : 1 }
' "$STUB_QUEUE"
SH
  chmod +x "$STUB_BIN_DIR/lavish-axi"
}

stub_feedback() {  # <session-ended: true|false> <rows-block>
  {
    printf 'session:\n  file: /review.html\n  status: feedback\n'
    [ "$1" = true ] && printf '  session_ended: true\n  ended_by: user\n'
    printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$(printf '%s\n' "$2" | grep -c .)"
    printf '%s\n' "$2"
    printf '### \n'
  } >> "$STUB_QUEUE"
}

stub_ended_empty() {
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n### \n' >> "$STUB_QUEUE"
}

stub_missing() {
  printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n### \n' >> "$STUB_QUEUE"
}

reconcile_once() {
  PATH="$STUB_BIN_DIR:$PATH" pe "$RECEIPT_HOME" reconcile >/dev/null 2>&1
}

reconcile_until() {  # <condition-command...>: reconcile until the condition holds
  local i=0 max=40
  while [ "$i" -lt "$max" ]; do
    reconcile_once
    if "$@"; then return 0; fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

stub_calls() { wc -l < "$STUB_LOG" | tr -d ' '; }

wait_claim_free() {
  local i=0
  while [ -e "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim" ] && [ "$i" -lt 60 ]; do
    sleep 0.2
    i=$((i + 1))
  done
}

wait_stub_calls() {  # <n>: wait until the stub has been invoked n times
  local i=0
  while [ "$(stub_calls 2>/dev/null || echo 0)" -lt "$1" ] && [ "$i" -lt 60 ]; do
    sleep 0.2
    i=$((i + 1))
  done
}

RECEIPT_HOME=
RECEIPT_SID=

teardown_suite() {
  if [ -n "$RECEIPT_HOME" ]; then
    FM_HOME="$RECEIPT_HOME" "$RUNNER" sweep-home >/dev/null 2>&1 || true
  fi
  fm_test_cleanup
}
trap teardown_suite EXIT

choice_row() {  # <uid> <question-key> <answer> <label>
  printf '  "%s","%s: %s\\n\\nContext data:\\n{\\n  \\"question\\": \\"%s\\", \\"answer\\": \\"%s\\"\\n}",section > form,choice,"%s: %s"\n' \
    "$1" "$4" "$3" "$2" "$3" "$4" "$3"
}

message_row() {  # <text>
  printf '  "","%s","","message","Freeform message"\n' "$1"
}

# --- ordering: capture precedes Received, the intake precedes Saved, and the
# handler's explicit calls own Applying and Complete -------------------------
H1=$(make_home h1)
RECEIPT_HOME=$H1
ART1="$TMP_ROOT/deck1.html"
printf '<h1>deck</h1>\n' > "$ART1"
RECEIPT_SID=$(run_lavish "$H1" source-id "$ART1")
tasks_in "$H1" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H1" hold deck-alpha --reason "alpha choice pending" >/dev/null
tasks_in "$H1" add deck-gamma "Gamma call" --kind ship --repo sample --body 'Gamma plan.' >/dev/null
run_captain "$H1" hold deck-gamma --reason "gamma choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 3 deck-alpha go 'Alpha')
$(choice_row 4 deck-beta hold 'Beta')
$(choice_row 5 deck-gamma resume 'Gamma')
$(message_row 'please also look at the footer')"
stub_ended_empty
# Bind before arming, so the answers can never land nowhere.
run_captain "$H1" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H1" arm "$ART1" >/dev/null
journal="$H1/state/procevent/$RECEIPT_SID.receipts"
reconcile_until grep -q "^received" "$journal" \
  || fail "the receipt seam never journaled the received submission"
recv_line=$(grep -n "^received" "$journal" | cut -d: -f1)
saved_line=$(grep -n "^saved" "$journal" | cut -d: -f1)
[ -n "$recv_line" ] && [ -n "$saved_line" ] && [ "$recv_line" -lt "$saved_line" ] \
  || fail "Saved was journaled before Received: received=$recv_line saved=$saved_line"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 3 ] \
  || fail "the received event did not count three choice answers"
[ "$(awk -F '\t' '$1 == "received" { print $5 }' "$journal")" = 1 ] \
  || fail "the received event did not count the freeform message"
[ "$(awk -F '\t' '$1 == "saved" { print $4 }' "$journal")" = 2 ] \
  || fail "the intake verdict was not journaled as two closed keys"
[ "$(awk -F '\t' '$1 == "saved" { print $5 }' "$journal")" = 1 ] \
  || fail "the rejected key was not journaled as skipped"
text=$(run_lavish "$H1" receipt-text "$RECEIPT_SID")
assert_contains "$text" "received 3 answers and a message" "the receipt did not state the answer count"
assert_contains "$text" "saved 2 of 3" "the receipt did not state the partial save"
assert_contains "$text" "1 not saved" "the receipt did not report the rejected row"
assert_not_contains "$text" "resume" "the receipt exposed an answer value"
assert_not_contains "$text" "please also look at the footer" "the receipt exposed the captain's freeform prose"
assert_not_contains "$text" "deck-alpha" "the receipt exposed a decision key"
assert_not_contains "$text" "deck-gamma" "the receipt exposed a decision key"
assert_not_contains "$text" "$ART1" "the receipt exposed an internal path"
assert_not_contains "$text" "127.0.0.1" "the receipt exposed a host"
assert_not_contains "$text" "/" "the receipt exposed a path separator"
assert_grep "UTC" <(printf '%s\n' "$text") "the receipt carried no timestamp"
# Complete refuses without Applying, and both refuse an unknown generation.
complete_rc=0
run_lavish "$H1" complete "$RECEIPT_SID" 99 >/dev/null 2>&1 || complete_rc=$?
[ "$complete_rc" -ne 0 ] || fail "complete accepted a generation with no received submission"
applying_rc=0
run_lavish "$H1" applying "$RECEIPT_SID" 99 >/dev/null 2>&1 || applying_rc=$?
[ "$applying_rc" -ne 0 ] || fail "applying accepted a generation with no received submission"
out=$(run_lavish "$H1" applying "$RECEIPT_SID" 1)
assert_contains "$out" "applying: $RECEIPT_SID 1" "the handler could not record Applying"
out=$(run_lavish "$H1" applying "$RECEIPT_SID" 1)
assert_contains "$out" "already-applying" "a duplicate Applying was not idempotent"
out=$(run_lavish "$H1" complete "$RECEIPT_SID" 1)
assert_contains "$out" "complete: $RECEIPT_SID 1" "the handler could not record Complete"
text=$(run_lavish "$H1" receipt-text "$RECEIPT_SID")
assert_contains "$text" "complete at" "the receipt did not state Complete after the handler finished"
# The accepted answers took effect exactly once, at answer time.
show=$(tasks_in "$H1" show deck-alpha --full)
assert_contains "$show" "state: done" "the accepted answer did not close its task"
assert_contains "$show" "Answer: go" "the closed task lost the captain's answer"
show=$(tasks_in "$H1" show deck-gamma --full)
assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
show=$(tasks_in "$H1" show deck-beta --full 2>/dev/null || true)
assert_not_contains "$show" "state: done" "a key naming no task was saved anyway"
# Handling the wake acks the generation; the review then retires on its
# receipt's delivery poll.
pe "$H1" handled "$RECEIPT_SID" 1 >/dev/null
reconcile_until [ ! -e "$H1/state/procevent/$RECEIPT_SID.source" ] \
  || fail "the ended review never retired after its receipt was displayed"
[ "$(awk -F '\t' '$1 == "delivered" { print $3 }' "$journal")" = 1 ] \
  || fail "the delivery was not journaled"
assert_absent "$H1/state/procevent/$RECEIPT_SID.source" "the ended review source remains registered"
assert_present "$H1/state/procevent-inbox/$RECEIPT_SID.2.handled" "the pure delivery capture was not acknowledged"
distinct_wakes=$(awk -F '\t' '{print $5}' "$H1/state/.wake-queue" 2>/dev/null | sort -u | grep -c . || true)
[ "$distinct_wakes" = 1 ] || fail "more than the feedback wake was published: $distinct_wakes"
assert_grep "procevent lavish $RECEIPT_SID 1" "$H1/state/.wake-queue" "the feedback wake is missing"
pass "capture, intake, and explicit handler calls own Received, Saved, Applying, and Complete in order"

# --- an exact replay is reported as already received, never re-applied ------
H2=$(make_home h2)
RECEIPT_HOME=$H2
ART2="$TMP_ROOT/deck2.html"
printf '<h1>deck</h1>\n' > "$ART2"
RECEIPT_SID=$(run_lavish "$H2" source-id "$ART2")
tasks_in "$H2" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H2" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
round_rows="$(choice_row 2 deck-alpha go 'Alpha')"
stub_feedback false "$round_rows"
stub_feedback false "$round_rows"
stub_ended_empty
run_captain "$H2" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H2" arm "$ART2" >/dev/null
journal="$H2/state/procevent/$RECEIPT_SID.receipts"
reconcile_until [ ! -e "$H2/state/procevent/$RECEIPT_SID.source" ] \
  || fail "the replayed review never retired"
[ "$(grep -c '^received' "$journal")" = 2 ] || fail "the replay was not journaled as its own received generation"
replay_ref=$(awk -F '\t' '$1 == "received" && $2 == 2 { print $7 }' "$journal")
[ "$replay_ref" = 1 ] || fail "the second generation did not reference round 1 as its replay origin"
text=$(run_lavish "$H2" receipt-text "$RECEIPT_SID")
assert_contains "$text" "Round 2: already received" "the receipt did not report the replay"
assert_contains "$text" "identical to round 1" "the replay report lost its origin round"
assert_contains "$text" "no new action" "the replay was presented as new work"
answer_lines=$(tasks_in "$H2" show deck-alpha --full | grep -c 'Answer: go' || true)
[ "$answer_lines" = 1 ] || fail "the replayed answer was recorded $answer_lines times"
pass "an exact replay is journaled as already received and never re-applied"

# --- agent-reply failure retries; retirement waits for the receipt ----------
H3=$(make_home h3)
RECEIPT_HOME=$H3
ART3="$TMP_ROOT/deck3.html"
printf '<h1>deck</h1>\n' > "$ART3"
RECEIPT_SID=$(run_lavish "$H3" source-id "$ART3")
install_stub
stub_feedback true "$(choice_row 2 deck-alpha ship 'Alpha')"
stub_ended_empty
run_lavish "$H3" arm "$ART3" >/dev/null
journal="$H3/state/procevent/$RECEIPT_SID.receipts"
reconcile_until [ -e "$H3/state/procevent-inbox/$RECEIPT_SID.1.result" ] \
  || fail "the final feedback was never captured"
# The delivery poll fails once: no new capture, no delivery, no retirement.
: > "$STUB_FAIL_ONCE"
wait_claim_free
reconcile_once
wait_stub_calls 2
wait_claim_free
[ -e "$H3/state/procevent/$RECEIPT_SID.source" ] \
  || fail "a failed receipt presentation retired the review anyway"
[ "$(awk -F '\t' '$1 == "delivered"' "$journal" | grep -c .)" = 0 ] \
  || fail "a failed receipt presentation was journaled as delivered"
[ "$(stub_calls)" = 2 ] || fail "the failed presentation was not retried exactly once more: $(stub_calls) calls"
# The retry succeeds and completes the lifecycle.
reconcile_until [ ! -e "$H3/state/procevent/$RECEIPT_SID.source" ] \
  || fail "the receipt delivery never recovered from the failed presentation"
[ "$(stub_calls)" = 3 ] || fail "the retry did not stop after delivery: $(stub_calls) calls"
assert_present "$H3/state/procevent-inbox/$RECEIPT_SID.2.handled" "the retried delivery was not acknowledged"
pass "a failed agent-reply delivery retries without retiring and never fakes completion"

# --- restart recovery: every recorded state reaches the next armed receipt ---
H4=$(make_home h4)
RECEIPT_HOME=$H4
ART4="$TMP_ROOT/deck4.html"
printf '<h1>deck</h1>\n' > "$ART4"
RECEIPT_SID=$(run_lavish "$H4" source-id "$ART4")
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
stub_ended_empty
run_lavish "$H4" arm "$ART4" >/dev/null
reconcile_until [ -e "$H4/state/procevent-inbox/$RECEIPT_SID.1.result" ] \
  || fail "the first round was never captured"
# The handler acts between rounds; a fresh reconcile process (a restart) must
# still present everything recorded so far on the next armed poll.
run_lavish "$H4" applying "$RECEIPT_SID" 1 >/dev/null
run_lavish "$H4" complete "$RECEIPT_SID" 1 >/dev/null
pe "$H4" handled "$RECEIPT_SID" 1 >/dev/null
reconcile_until grep -q "^delivered" "$H4/state/procevent/$RECEIPT_SID.receipts" \
  || fail "the receipt was never displayed after the restart"
second_poll=$(sed -n '2p' "$STUB_LOG")
assert_contains "$second_poll" "--agent-reply" "the restarted poll presented no receipt"
assert_contains "$second_poll" "received 1 answer" "the restarted receipt lost the answer count"
assert_contains "$second_poll" "complete at" "the restarted receipt lost the handler's Complete"
pass "a replacement session presents every recorded receipt state on the next armed poll"

# --- a review that ends with nothing received retires exactly as before -----
H5=$(make_home h5)
RECEIPT_HOME=$H5
ART5="$TMP_ROOT/deck5.html"
printf '<h1>deck</h1>\n' > "$ART5"
RECEIPT_SID=$(run_lavish "$H5" source-id "$ART5")
install_stub
stub_ended_empty
run_lavish "$H5" arm "$ART5" >/dev/null
reconcile_until [ ! -e "$H5/state/procevent/$RECEIPT_SID.source" ] \
  || fail "a review with nothing received never retired"
[ "$(stub_calls)" = 1 ] || fail "an empty-ended review was polled more than once: $(stub_calls)"
[ -e "$H5/state/procevent-inbox/$RECEIPT_SID.1.result" ] || fail "the empty-ended capture is missing"
pass "a review that ends with nothing received still retires on one terminal capture"

# --- a missing session retires with its receipt queued, never delivered -----
H6=$(make_home h6)
RECEIPT_HOME=$H6
ART6="$TMP_ROOT/deck6.html"
printf '<h1>deck</h1>\n' > "$ART6"
RECEIPT_SID=$(run_lavish "$H6" source-id "$ART6")
install_stub
stub_feedback true "$(choice_row 2 deck-alpha ship 'Alpha')"
stub_missing
run_lavish "$H6" arm "$ART6" >/dev/null
reconcile_until [ ! -e "$H6/state/procevent/$RECEIPT_SID.source" ] \
  || fail "a missing session never retired"
[ "$(awk -F '\t' '$1 == "delivered"' "$H6/state/procevent/$RECEIPT_SID.receipts" | grep -c .)" = 0 ] \
  || fail "a missing session was journaled as having displayed its receipt"
assert_grep "procevent lavish $RECEIPT_SID 1" "$H6/state/.wake-queue" "the final feedback wake is missing"
pass "a missing session retires with its receipt durably queued and undelivered"

# --- duplicate and concurrent notifications stay idempotent -----------------
H7=$(make_home h7)
RECEIPT_HOME=$H7
ART7="$TMP_ROOT/deck7.html"
printf '<h1>deck</h1>\n' > "$ART7"
RECEIPT_SID=$(run_lavish "$H7" source-id "$ART7")
tasks_in "$H7" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H7" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
stub_ended_empty
run_captain "$H7" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H7" arm "$ART7" >/dev/null
reconcile_until [ -e "$H7/state/procevent-inbox/$RECEIPT_SID.1.result" ] \
  || fail "the duplicate-notification round was never captured"
# Duplicate seam calls, handler calls, and acknowledgements through the public
# interfaces, plus concurrent handler calls, must converge on one record each.
result="$H7/state/procevent-inbox/$RECEIPT_SID.1.result"
printf 'not-fed\n' > "$H7/dup-outcome"
run_lavish "$H7" receipt "$RECEIPT_SID" 1 "$result" "$H7/dup-outcome" >/dev/null
run_lavish "$H7" receipt "$RECEIPT_SID" 1 "$result" "$H7/dup-outcome" >/dev/null
( run_lavish "$H7" applying "$RECEIPT_SID" 1 >/dev/null 2>&1
  run_lavish "$H7" applying "$RECEIPT_SID" 1 >/dev/null 2>&1 ) &
( run_lavish "$H7" applying "$RECEIPT_SID" 1 >/dev/null 2>&1
  run_lavish "$H7" complete "$RECEIPT_SID" 1 >/dev/null 2>&1 ) &
wait
out=$(pe "$H7" handled "$RECEIPT_SID" 1)
assert_contains "$out" "handled: $RECEIPT_SID 1" "the first acknowledgement was not the authorized one"
out=$(pe "$H7" handled "$RECEIPT_SID" 1)
assert_contains "$out" "already-handled: $RECEIPT_SID 1" "a repeated acknowledgement authorized the effect again"
journal="$H7/state/procevent/$RECEIPT_SID.receipts"
for ev in received saved applying complete; do
  count=$(grep -c "^$ev" "$journal")
  [ "$count" = 1 ] || fail "duplicate notifications left $count $ev events"
done
bad_lines=$(awk -F '\t' 'NR > 1 && NF < 3 { c++ } END { print c + 0 }' "$journal")
[ "$bad_lines" = 0 ] || fail "concurrent receipt writes tore $bad_lines journal lines"
pass "duplicate and concurrent notifications converge on one journaled fact each"

# --- a planted record this adapter does not own is refused, never written to --
# The record path is private per-source state. A symlink standing in its place
# must fail closed on both sides of the seam: nothing may be presented from it,
# and no journaled event may be written through it into the link's target.
mv "$journal" "$TMP_ROOT/h7-record"
planted="$TMP_ROOT/planted-target"
: > "$planted"
ln -s "$planted" "$journal"
status=0
out=$(run_lavish "$H7" receipt "$RECEIPT_SID" 1 "$result" "$H7/dup-outcome" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "the receipt seam accepted a symlinked receipts record"
assert_contains "$out" "receipts record is unreadable" "the refusal names the unreadable record"
[ ! -s "$planted" ] || fail "an event was journaled through the symlinked record"
status=0
out=$(run_lavish "$H7" receipt-text "$RECEIPT_SID" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "receipt text was presented from a symlinked receipts record"
rm -f "$journal"
mv "$TMP_ROOT/h7-record" "$journal"
pass "a symlinked receipts record is refused rather than read or written through"

printf '\nall Lavish receipt tests passed\n'
