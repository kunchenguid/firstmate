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
STUB_INTERRUPT_ONCE="$STUB_ROOT/interrupt-once"
STUB_HOLD="$STUB_ROOT/hold"
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
  # The stub dir rides along in PATH so arm and managed-poll's presence check
  # finds a lavish-axi on runners where the real one is not installed; the
  # scenarios that script responses install the stub before their first poll.
  PATH="${STUB_BIN_DIR:+$STUB_BIN_DIR:}$PATH" \
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
  rm -f "$STUB_IDX" "$STUB_LOG" "$STUB_FAIL_ONCE" "$STUB_INTERRUPT_ONCE" "$STUB_HOLD"
  cat > "$STUB_BIN_DIR/lavish-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
# A held poll blocks in the runner's own process group, so the runner's leader
# can be killed with a live child of its generation still running.
while [ -e "$STUB_HOLD" ]; do sleep 0.05; done
if [ -e "$STUB_FAIL_ONCE" ]; then
  rm -f "$STUB_FAIL_ONCE"
  exit 1
fi
if [ -e "$STUB_INTERRUPT_ONCE" ]; then
  rm -f "$STUB_INTERRUPT_ONCE"
  printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n'
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

# A prompts block that declares more rows than it delivers - what a response
# truncated in transit looks like on the wire.
stub_truncated() {  # <session-ended: true|false> <declared-rows> <rows-block>
  {
    printf 'session:\n  file: /review.html\n  status: feedback\n'
    [ "$1" = true ] && printf '  session_ended: true\n  ended_by: user\n'
    printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$2"
    printf '%s\n' "$3"
    printf '### \n'
  } >> "$STUB_QUEUE"
}

# One captured result in the published poll's shape, written where the receipt
# seam can be handed it directly.
write_result() {  # <path> <session-ended: true|false> <declared-rows> <rows-block>
  {
    printf 'session:\n  file: /review.html\n  status: feedback\n'
    [ "$2" = true ] && printf '  session_ended: true\n  ended_by: user\n'
    printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$3"
    printf '%s\n' "$4"
  } > "$1"
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

# A live capture's receipt seam may still be in flight when its result file
# appears, so anything that reads or extends that round's journal facts waits
# for the seam marker the runner writes once the seam has had its chance.
wait_seam() {  # <home> <source-id> <sequence>
  local i=0
  while [ ! -e "$1/state/procevent-inbox/$2.$3.receipted" ] && [ "$i" -lt 100 ]; do
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
wait_seam "$H4" "$RECEIPT_SID" 1
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
# The live capture's own seam may still be in flight when the result file
# appears; its journal facts must exist before the convergence count reads.
wait_i=0
while [ ! -e "$H7/state/procevent-inbox/$RECEIPT_SID.1.receipted" ] && [ "$wait_i" -lt 100 ]; do
  sleep 0.2; wait_i=$((wait_i + 1))
done
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

# --- one visible receipt per round, however many quiet retries it takes ------
# The retried condition interrupts the poll response after the server accepted
# the request, so the receipt is already on the page; a retry that re-sent it
# would leave the captain reading the same acknowledgement many times.
stub_calls_at_least() { [ "$(stub_calls)" -ge "$1" ]; }
export FM_LAVISH_POLL_RETRY_DELAY=0
H8=$(make_home h8)
RECEIPT_HOME=$H8
ART8="$TMP_ROOT/deck8.html"
printf '<h1>deck</h1>\n' > "$ART8"
RECEIPT_SID=$(run_lavish "$H8" source-id "$ART8")
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
stub_ended_empty
run_lavish "$H8" arm "$ART8" >/dev/null
reconcile_until [ -e "$H8/state/procevent-inbox/$RECEIPT_SID.1.result" ] \
  || fail "the round whose receipt is delivered was never captured"
wait_claim_free
: > "$STUB_INTERRUPT_ONCE"
reconcile_until stub_calls_at_least 3 \
  || fail "the interrupted delivery poll never completed its quiet retry"
presentations=$(grep -c -- "--agent-reply" "$STUB_LOG")
[ "$presentations" = 1 ] \
  || fail "one round's receipt was presented $presentations times across the quiet retry"
journal="$H8/state/procevent/$RECEIPT_SID.receipts"
reconcile_until grep -q "^delivered" "$journal" \
  || fail "the quietly retried delivery never journaled the displayed receipt"
pass "a quietly retried delivery presents the round's receipt exactly once"

# --- arm never registers a source whose record it could not reset ------------
H9=$(make_home h9)
RECEIPT_HOME=$H9
ART9="$TMP_ROOT/deck9.html"
printf '<h1>deck</h1>\n' > "$ART9"
RECEIPT_SID=$(run_lavish "$H9" source-id "$ART9")
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
record="$H9/state/procevent/$RECEIPT_SID.receipts"
mkdir -p "$record"
status=0
out=$(PATH="$STUB_BIN_DIR:$PATH" run_lavish "$H9" arm "$ART9" 2>&1) || status=$?
[ "$status" -ne 0 ] || fail "arm registered a source whose receipts record it could not reset"
assert_contains "$out" "cannot reset the receipts record" "the refusal names the record it could not reset"
assert_absent "$H9/state/procevent/$RECEIPT_SID.source" "a refused arm left the source registered"
rmdir "$record"
# A dangling symlink is removed rather than inherited, so the armed source can
# actually poll instead of dying on an unreadable record forever.
ln -s "$TMP_ROOT/absent-record-target" "$record"
PATH="$STUB_BIN_DIR:$PATH" run_lavish "$H9" arm "$ART9" >/dev/null \
  || fail "arm refused a source whose record was a dangling symlink"
[ ! -L "$record" ] || fail "arm inherited the planted record symlink"
[ ! -e "$TMP_ROOT/absent-record-target" ] || fail "arm wrote through the planted record symlink"
reconcile_until [ -e "$H9/state/procevent-inbox/$RECEIPT_SID.1.result" ] \
  || fail "the armed source could never poll after the planted record was reset"
pass "arm resets a planted record or refuses to register the source"

# --- a runner that died before the receipt seam is recovered by reconcile ----
# A runner killed between its durable capture and the receipt seam leaves the
# capture, its registration, and its fed answers behind, and none of the receipt
# facts. Reconcile republishes that capture, so unless it also gives the seam
# the chance the dead runner owed it, the round is announced to the handler with
# no acknowledgement and the review can retire before the captain ever sees one.
H10=$(make_home h10)
RECEIPT_HOME=$H10
ART10="$TMP_ROOT/deck10.html"
printf '<h1>deck</h1>\n' > "$ART10"
RECEIPT_SID=$(run_lavish "$H10" source-id "$ART10")
tasks_in "$H10" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H10" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
stub_ended_empty
run_captain "$H10" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H10" arm "$ART10" >/dev/null
journal="$H10/state/procevent/$RECEIPT_SID.receipts"
result="$H10/state/procevent-inbox/$RECEIPT_SID.1.result"
# Exactly one reconcile, so the round is captured and no replacement has armed.
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_claim_free
[ -e "$result" ] || fail "the submitted round was never captured"
[ "$(grep -c '^saved' "$journal")" = 1 ] || fail "the live capture never journaled its own save"
# Roll the durable state back to the instant before that runner reached the
# seam: a killed runner leaves the capture and the fed answers, but writes
# neither a receipt fact nor its note that the seam had its chance.
rm -f "$journal" "$H10/state/procevent-inbox/$RECEIPT_SID.1.receipted"
reconcile_until grep -qs '^received' "$journal" \
  || fail "reconcile never recovered the receipt seam the dead runner owed"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 1 ] \
  || fail "the recovered receipt lost the round's answer count"
[ "$(grep -c '^saved' "$journal")" = 0 ] \
  || fail "recovery presented a save it could not prove from the crashed generation"
answer_lines=$(tasks_in "$H10" show deck-alpha --full | grep -c 'Answer: go' || true)
[ "$answer_lines" = 1 ] || fail "recovery applied the answer again: recorded $answer_lines times"
# The recovered round reaches the captain: the next armed poll presents it, and
# only then may the ended review retire.
reconcile_until [ ! -e "$H10/state/procevent/$RECEIPT_SID.source" ] \
  || fail "the recovered review never retired"
[ "$(awk -F '\t' '$1 == "delivered" { print $3 }' "$journal")" = 1 ] \
  || fail "the recovered round retired without its receipt being displayed"
presented=$(grep -c -- "--agent-reply" "$STUB_LOG")
[ "$presented" = 1 ] || fail "the recovered receipt was presented $presented times"
assert_contains "$(sed -n '2p' "$STUB_LOG")" "received 1 answer" \
  "the presented receipt lost the recovered round"
pass "reconcile recovers the receipt seam a runner died before reaching"

# --- a runner that died after its intake returned keeps that round's verdict --
# The dead runner of the case above may have got one step further: far enough
# for the keyed-answer intake to return and be written down, and not far enough
# to journal it. That verdict is then a durable fact of the crashed generation,
# so recovery must present it rather than silently drop the round's Saved state
# forever - and it must only ever read it as the round it actually belongs to.
H11=$(make_home h11)
RECEIPT_HOME=$H11
ART11="$TMP_ROOT/deck11.html"
printf '<h1>deck</h1>\n' > "$ART11"
RECEIPT_SID=$(run_lavish "$H11" source-id "$ART11")
tasks_in "$H11" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H11" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
# One round only: every later poll finds nothing, so the source stays armed and
# reconcile can be run as often as the recovery needs without capturing again.
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')
$(choice_row 3 deck-beta hold 'Beta')"
run_captain "$H11" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H11" arm "$ART11" >/dev/null
journal="$H11/state/procevent/$RECEIPT_SID.receipts"
result="$H11/state/procevent-inbox/$RECEIPT_SID.1.result"
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_claim_free
[ -e "$result" ] || fail "the submitted round was never captured"
live_saved=$(awk -F '\t' '$1 == "saved" && $2 == 1 { printf "%s/%s/%s", $4, $5, $6 }' "$journal")
[ "$live_saved" = "1/1/ok" ] || fail "the live capture did not journal its own verdict: $live_saved"
# Roll the durable state back to the instant after that runner's intake returned
# and before its seam ran: the capture and the applied answers stand, the
# receipt facts and the seam's own note are gone, and the generation's staged
# intake outcome is still where the killed runner left it.
staged="$H11/state/procevent/.$RECEIPT_SID.dead-token.rcpt.output"
crash_state() {  # <generation-the-staged-outcome-claims>
  rm -f "$journal" "$H11/state/procevent-inbox/$RECEIPT_SID.1.receipted"
  printf 'fed 0\nclosed: deck-alpha\nskipped: deck-beta names no task\n' > "$staged"
  printf '%s\t%s\n' "$RECEIPT_SID" "$1" > "$staged.gen"
  chmod 0600 "$staged" "$staged.gen"
}
# An outcome that names a different generation proves nothing about this one.
crash_state 2
reconcile_until grep -qs '^received' "$journal" \
  || fail "reconcile never recovered the receipt seam the dead runner owed"
[ "$(grep -c '^saved' "$journal")" = 0 ] \
  || fail "recovery presented a save from an outcome belonging to another round"
# The same outcome, named for the round it really covers, is recovered in full.
crash_state 1
reconcile_until grep -qs '^saved' "$journal" \
  || fail "recovery dropped the verdict the dead runner had already recorded"
recovered_saved=$(awk -F '\t' '$1 == "saved" && $2 == 1 { printf "%s/%s/%s", $4, $5, $6 }' "$journal")
[ "$recovered_saved" = "$live_saved" ] \
  || fail "the recovered verdict differs from the live one: $recovered_saved vs $live_saved"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 2 ] \
  || fail "the recovered receipt lost the round's answer count"
answer_lines=$(tasks_in "$H11" show deck-alpha --full | grep -c 'Answer: go' || true)
[ "$answer_lines" = 1 ] || fail "recovery applied the answer again: recorded $answer_lines times"
text=$(run_lavish "$H11" receipt-text "$RECEIPT_SID")
assert_contains "$text" "saved 1 of 2" "the recovered receipt did not state the save it recovered"
rm -f "$staged" "$staged.gen"
pass "recovery journals the verdict a dead generation recorded, and only for that generation"

# --- a refused parse keeps the review armed, however many rounds preceded it --
# A prompts block declaring more rows than it delivers is truncated, so the
# adapter refuses to summarize it: the round is neither journaled nor fed. That
# refusal is only trustworthy if it also blocks retirement. An earlier round
# whose receipt was already delivered must not be read as proof that THIS final
# submission carried nothing - retiring here drops the captain's last round with
# no acknowledgement and no chance to apply it.
H12=$(make_home h12)
RECEIPT_HOME=$H12
ART12="$TMP_ROOT/deck12.html"
printf '<h1>deck</h1>\n' > "$ART12"
RECEIPT_SID=$(run_lavish "$H12" source-id "$ART12")
tasks_in "$H12" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H12" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
# The captain's next submission ends the review, and its block arrives truncated.
stub_truncated true 2 "$(choice_row 3 deck-beta hold 'Beta')"
run_captain "$H12" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H12" arm "$ART12" >/dev/null
journal="$H12/state/procevent/$RECEIPT_SID.receipts"
reconcile_until [ -e "$H12/state/procevent-inbox/$RECEIPT_SID.2.result" ] \
  || fail "the truncated final submission was never captured"
wait_seam "$H12" "$RECEIPT_SID" 2
grep -qs '^delivered' "$journal" \
  || fail "the first round's receipt was never delivered before the truncated round"
truncated_tries=0
while [ "$truncated_tries" -lt 4 ]; do
  reconcile_once
  truncated_tries=$((truncated_tries + 1))
done
assert_present "$H12/state/procevent/$RECEIPT_SID.source" \
  "a refused parse on a final submission retired the review unacknowledged"
[ "$(grep -c '^received' "$journal")" = 1 ] \
  || fail "the refused parse was journaled as a received round"
text=$(run_lavish "$H12" receipt-text "$RECEIPT_SID")
assert_not_contains "$text" "Round 2" "the refused parse was presented as an acknowledged round"
pass "a refused final-submission parse keeps the review armed after earlier rounds"

# --- the seam's outcome contract reaches the visible receipt -----------------
# The runner hands the seam an outcome file whose bytes are the contract
# documented in docs/configuration.md: `not-fed`, or `fed <exit>` and an
# optional quality line. These drive the seam directly with that contract, so
# each visible state is proven against the verdict that produced it.
H13=$(make_home h13)
RECEIPT_HOME=$H13
ART13="$TMP_ROOT/deck13.html"
printf '<h1>deck</h1>\n' > "$ART13"
SID13=$(run_lavish "$H13" source-id "$ART13")
J13="$H13/state/procevent/$SID13.receipts"
R13="$TMP_ROOT/r13.result"
O13="$TMP_ROOT/o13.outcome"
# An intake whose adapter could not extract its own answers reports an
# incomplete quality, never a verified save over rows nothing vouches for.
write_result "$R13" false 1 "$(choice_row 2 deck-alpha go 'Alpha')"
printf 'fed 0\nincomplete\n' > "$O13"
run_lavish "$H13" receipt "$SID13" 1 "$R13" "$O13" >/dev/null
[ "$(awk -F '\t' '$1 == "saved" { print $6 }' "$J13")" = incomplete ] \
  || fail "an answer-extractor failure was journaled as a verified save"
text=$(run_lavish "$H13" receipt-text "$SID13")
assert_contains "$text" "its saving report was incomplete" \
  "the receipt presented an incomplete verdict as a verified save"
assert_not_contains "$text" "saved 0 of 1" "the receipt claimed a save count it cannot vouch for"
# A round carrying neither an answer nor a freeform message claims neither.
R14="$TMP_ROOT/r14.result"
O14="$TMP_ROOT/o14.outcome"
write_result "$R14" false 1 '  "9","","section > p",annotation,"the footer is off"'
printf 'not-fed\n' > "$O14"
run_lavish "$H13" receipt "$SID13" 2 "$R14" "$O14" >/dev/null
text=$(run_lavish "$H13" receipt-text "$SID13")
assert_contains "$text" "Round 2: received your written comment at" \
  "a zero-answer round was not acknowledged as a written comment"
assert_not_contains "$text" "0 answers" "the acknowledgement counted answers that were not there"
# A comment-only submission - a freeform message and no answer at all - is
# acknowledged with the same wording, and equally never claims a zero count.
R17="$TMP_ROOT/r17.result"
write_result "$R17" false 1 "$(message_row 'the footer is still off')"
run_lavish "$H13" receipt "$SID13" 3 "$R17" "$O14" >/dev/null
text=$(run_lavish "$H13" receipt-text "$SID13")
assert_contains "$text" "Round 3: received your written comment at" \
  "a comment-only submission was not acknowledged as a written comment"
assert_not_contains "$text" "received 0 answers" \
  "the comment-only acknowledgement claimed a zero answer count"
# A comment-only round is a round like any other: the handler records applying
# and complete against its generation, and the receipt states both. Only the
# save clause is absent, because there are no answers to have saved.
mkdir -p "$H13/state/procevent-inbox"
cp "$R17" "$H13/state/procevent-inbox/$SID13.3.result"
chmod 0600 "$H13/state/procevent-inbox/$SID13.3.result"
run_lavish "$H13" applying "$SID13" 3 >/dev/null \
  || fail "the handler could not record applying for a comment-only round"
round3=$(run_lavish "$H13" receipt-text "$SID13" | grep '^Round 3:')
assert_contains "$round3" "firstmate is applying them" \
  "a comment-only round hid the applying state the handler recorded"
run_lavish "$H13" complete "$SID13" 3 >/dev/null \
  || fail "the handler could not record complete for a comment-only round"
round3=$(run_lavish "$H13" receipt-text "$SID13" | grep '^Round 3:')
assert_contains "$round3" "complete at" \
  "a comment-only round hid the complete state the handler recorded"
assert_not_contains "$round3" "saved" \
  "the comment-only round claimed a save over answers it never carried"
# A parse the adapter refused is no verdict at all, so it journals nothing.
R15="$TMP_ROOT/r15.result"
write_result "$R15" false 3 "$(choice_row 4 deck-alpha go 'Alpha')"
run_lavish "$H13" receipt "$SID13" 4 "$R15" "$O14" >/dev/null
[ "$(grep -c '^received' "$J13")" = 3 ] \
  || fail "a truncated block was journaled as a received round by the seam"
pass "the seam's outcome contract drives the incomplete, bare, and refused receipts"

# --- the receipts record is private whatever umask the caller brought --------
# The record holds a review's submitted answers and comments, so its privacy is
# the seam's to enforce rather than the caller's to grant. Creation is proven
# under a permissive umask with the tightening chmod removed from under it, so
# only the mode the record is born with can satisfy this.
FAIL_CHMOD_DIR="$TMP_ROOT/fail-chmod-bin"
mkdir -p "$FAIL_CHMOD_DIR"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAIL_CHMOD_DIR/chmod"
chmod +x "$FAIL_CHMOD_DIR/chmod"
H13B=$(make_home h13b)
RECEIPT_HOME=$H13B
ART13B="$TMP_ROOT/deck13b.html"
printf '<h1>deck</h1>\n' > "$ART13B"
SID13B=$(run_lavish "$H13B" source-id "$ART13B")
J13B="$H13B/state/procevent/$SID13B.receipts"
R13B="$TMP_ROOT/r13b.result"
O13B="$TMP_ROOT/o13b.outcome"
write_result "$R13B" false 1 "$(choice_row 2 deck-alpha go 'Alpha')"
printf 'fed 0\n' > "$O13B"
(umask 022; PATH="$FAIL_CHMOD_DIR:$PATH" run_lavish "$H13B" receipt "$SID13B" 1 "$R13B" "$O13B" >/dev/null) \
  || fail "the seam could not journal its round with the tightening chmod unavailable"
assert_present "$J13B" "the seam journaled no round to prove the record's mode by"
record_mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$J13B")
assert_contains "$record_mode" 600 \
  "the receipts record is private under a permissive caller umask"
pass "the receipts record is created private regardless of the caller's umask"

# --- a replay whose own outcome proves a new effect is a new action ----------
# An answer skipped on its first submission - its task was not held yet - is
# genuinely applied when the captain resubmits it. The identical digest must not
# hide that: the captain has to see the action, not an actionless "already
# received". A resubmission that really changed nothing still says so.
H14=$(make_home h14)
RECEIPT_HOME=$H14
ART14="$TMP_ROOT/deck14.html"
printf '<h1>deck</h1>\n' > "$ART14"
SID14=$(run_lavish "$H14" source-id "$ART14")
R16="$TMP_ROOT/r16.result"
write_result "$R16" false 1 "$(choice_row 2 deck-alpha go 'Alpha')"
printf 'fed 0\nskipped: deck-alpha names no held task\n' > "$TMP_ROOT/o16a.outcome"
printf 'fed 0\nclosed: deck-alpha\n' > "$TMP_ROOT/o16b.outcome"
printf 'fed 0\n' > "$TMP_ROOT/o16c.outcome"
run_lavish "$H14" receipt "$SID14" 1 "$R16" "$TMP_ROOT/o16a.outcome" >/dev/null
run_lavish "$H14" receipt "$SID14" 2 "$R16" "$TMP_ROOT/o16b.outcome" >/dev/null
text=$(run_lavish "$H14" receipt-text "$SID14")
assert_contains "$text" "Round 2: received 1 answer" \
  "a replay that really saved an answer was hidden as an actionless replay"
assert_contains "$text" "saved 1 of 1" "the newly saved replay did not state its save"
# The same submission a third time changed nothing, and is reported as such.
run_lavish "$H14" receipt "$SID14" 3 "$R16" "$TMP_ROOT/o16c.outcome" >/dev/null
text=$(run_lavish "$H14" receipt-text "$SID14")
assert_contains "$text" "Round 3: already received" \
  "a replay with no new effect was presented as a new action"
assert_contains "$text" "no new action" "the actionless replay did not say so"
pass "a replay is a new action only when its own outcome proves one"

# --- arm never resets a record whose rounds are still owed to a handler ------
# Resetting the receipts record while an earlier session's captures are still
# unhandled would orphan their Applying and Complete from the received rounds
# they speak for, so arming refuses until those generations are settled.
H15=$(make_home h15)
RECEIPT_HOME=$H15
ART15="$TMP_ROOT/deck15.html"
printf '<h1>deck</h1>\n' > "$ART15"
SID15=$(run_lavish "$H15" source-id "$ART15")
install_stub
mkdir -p "$H15/state/procevent-inbox"
printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n' \
  > "$H15/state/procevent-inbox/$SID15.1.result"
printf 'lavish\n' > "$H15/state/procevent-inbox/$SID15.1.adapter"
chmod 0600 "$H15/state/procevent-inbox/$SID15.1.result" \
  "$H15/state/procevent-inbox/$SID15.1.adapter"
arm_status=0
arm_out=$(PATH="$STUB_BIN_DIR:$PATH" run_lavish "$H15" arm "$ART15" 2>&1) || arm_status=$?
[ "$arm_status" -ne 0 ] || fail "arm reset a record whose captured rounds were still unhandled"
assert_contains "$arm_out" "unhandled captured result" \
  "the refusal names the unhandled generations it is protecting"
assert_absent "$H15/state/procevent/$SID15.source" "a refused arm left the source registered"
pe "$H15" handled "$SID15" 1 >/dev/null
PATH="$STUB_BIN_DIR:$PATH" run_lavish "$H15" arm "$ART15" >/dev/null \
  || fail "arm refused after every captured generation was handled"
assert_present "$H15/state/procevent/$SID15.source" \
  "arm did not register the source once its captures were settled"
pass "arm refuses while unhandled captured generations remain on the artifact"

# --- a crashed leader's verdict is recovered before its group is reaped ------
# SIGKILL on a runner leader alone leaves its owned group running, so the claim
# reads as the crash cut rather than as gone. That leader can never run its own
# seam, and the reap that stops its group drops the whole staging set - so a
# recovery that defers to the crash cut destroys the verdict the dead runner
# had already recorded, and the round is published with no acknowledgement and
# never appears on any receipt.
H16=$(make_home h16)
RECEIPT_HOME=$H16
ART16="$TMP_ROOT/deck16.html"
printf '<h1>deck</h1>\n' > "$ART16"
RECEIPT_SID=$(run_lavish "$H16" source-id "$ART16")
tasks_in "$H16" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H16" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
run_captain "$H16" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H16" arm "$ART16" >/dev/null
journal="$H16/state/procevent/$RECEIPT_SID.receipts"
result="$H16/state/procevent-inbox/$RECEIPT_SID.1.result"
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_claim_free
[ -e "$result" ] || fail "the round was never captured"
# The next runner blocks inside its poll, so killing its leader leaves that
# generation's own child alive - the crash cut, not a gone claim.
: > "$STUB_HOLD"
held_calls_before=$(stub_calls)
reconcile_once
claim="$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
wait_i=0
while [ ! -e "$claim" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
[ -e "$claim" ] || fail "the replacement runner never claimed the source"
# The claim is recorded before the poll is executed, so the owned child this
# scenario needs alive is waited for rather than assumed: the stub logs its
# argv and only then blocks on the hold.
wait_i=0
while [ "$(stub_calls)" -le "$held_calls_before" ] && [ "$wait_i" -lt 100 ]; do
  sleep 0.1
  wait_i=$((wait_i + 1))
done
[ "$(stub_calls)" -gt "$held_calls_before" ] \
  || fail "the replacement runner never started the held poll its group needs"
crash_leader=$(sed -n '2p' "$claim")
crash_token=$(sed -n '3p' "$claim")
case "$crash_leader" in ''|*[!0-9]*) fail "could not read the runner leader pid: $crash_leader" ;; esac
[ -n "$crash_token" ] || fail "could not read the crashed generation's claim token"
kill -KILL "$crash_leader" 2>/dev/null || fail "could not kill the runner leader"
for _ in $(seq 1 50); do kill -0 "$crash_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 "$crash_leader" 2>/dev/null && fail "the runner leader survived SIGKILL"
kill -0 -"$crash_leader" 2>/dev/null \
  || fail "fixture invalid: the crashed leader's owned group did not survive it"
# Roll the durable state back to the instant before that generation reached its
# seam, leaving behind exactly what it had already staged: its recorded verdict
# and the note pinning that verdict to this one sequence.
rm -f "$journal" "$H16/state/procevent-inbox/$RECEIPT_SID.1.receipted"
staged="$H16/state/procevent/.$RECEIPT_SID.$crash_token.rcpt.output"
printf 'fed 0\nclosed: deck-alpha\n' > "$staged"
printf '%s\t%s\n' "$RECEIPT_SID" 1 > "$staged.gen"
chmod 0600 "$staged" "$staged.gen"
reconcile_once
grep -qs '^received' "$journal" \
  || fail "the crashed leader's generation was reaped without ever running its seam"
[ "$(awk -F '\t' '$1 == "saved" && $2 == 1 { print $4 }' "$journal")" = 1 ] \
  || fail "recovery lost the verdict the crashed leader had already staged"
text=$(run_lavish "$H16" receipt-text "$RECEIPT_SID")
assert_contains "$text" "saved 1 of 1" "the recovered round never reached the visible receipt"
rm -f "$STUB_HOLD" "$staged" "$staged.gen"
pass "a crashed leader's staged verdict is recovered before its group is reaped"

# --- reclaiming a gone claim keeps the verdict its seam never consumed -------
# The ordinary recovery route for a crashed generation is a replacement runner
# whose own claim acquisition reclaims the dead claim. That reclaim owns the
# staging set, but the receipt outcome and the note pinning it to one sequence
# are still owed to a seam that never ran: dropping them there loses the round's
# Saved state for good and lets the capture be published with no acknowledgement
# at all. Everything else the dead generation staged is still reaped.
H17=$(make_home h17)
RECEIPT_HOME=$H17
ART17="$TMP_ROOT/deck17.html"
printf '<h1>deck</h1>\n' > "$ART17"
RECEIPT_SID=$(run_lavish "$H17" source-id "$ART17")
tasks_in "$H17" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H17" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
run_captain "$H17" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H17" arm "$ART17" >/dev/null
journal="$H17/state/procevent/$RECEIPT_SID.receipts"
result="$H17/state/procevent-inbox/$RECEIPT_SID.1.result"
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_claim_free
[ -e "$result" ] || fail "the submitted round was never captured"
# Roll back to a generation whose runner died after its intake returned and
# before its seam ran, with the dead claim still standing as the reclaim finds
# it, and the rest of that generation's staging beside the verdict.
rm -f "$journal" "$H17/state/procevent-inbox/$RECEIPT_SID.1.receipted"
staged="$H17/state/procevent/.$RECEIPT_SID.dead-token.rcpt.output"
printf 'fed 0\nclosed: deck-alpha\n' > "$staged"
printf '%s\t%s\n' "$RECEIPT_SID" 1 > "$staged.gen"
printf 'partial intake body\n' > "$staged.body"
printf 'half-written verdict\n' > "$staged.tmp"
printf 'stale capture\n' > "$H17/state/procevent/.$RECEIPT_SID.dead-token.output"
chmod 0600 "$staged" "$staged.gen" "$staged.body" "$staged.tmp" \
  "$H17/state/procevent/.$RECEIPT_SID.dead-token.output"
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' \
  "$H17" 999999 "$H17/state/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
# The replacement runner reclaims that dead claim. Its own poll finds nothing
# left in the queue, so it captures nothing and only the reclaim is observed.
PATH="$STUB_BIN_DIR:$PATH" pe "$H17" start "$RECEIPT_SID" >/dev/null 2>&1 || true
assert_absent "$H17/state/procevent/.$RECEIPT_SID.dead-token.output" \
  "the reclaim left the dead generation's captured output staged"
assert_absent "$staged.body" "the reclaim left the dead generation's intake body staged"
assert_absent "$staged.tmp" "the reclaim left the dead generation's half-written verdict staged"
assert_present "$staged" "the reclaim destroyed a verdict whose receipt seam never ran"
assert_present "$staged.gen" "the reclaim destroyed the note pinning that verdict to its round"
# The verdict the reclaim preserved is exactly what the recovered seam journals.
reconcile_until grep -qs '^saved' "$journal" \
  || fail "recovery never journaled the verdict the reclaim preserved"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 1 ] \
  || fail "the recovered round lost its answer count"
[ "$(awk -F '\t' '$1 == "saved" && $2 == 1 { print $4 }' "$journal")" = 1 ] \
  || fail "recovery lost the save the preserved verdict recorded"
text=$(run_lavish "$H17" receipt-text "$RECEIPT_SID")
assert_contains "$text" "saved 1 of 1" "the preserved verdict never reached the visible receipt"
rm -f "$staged" "$staged.gen"
pass "a gone-claim reclaim keeps the staged verdict its seam still owes"

# --- a retired source still owes the verdict its dead runner recorded -------
# Retirement drops the registration but deliberately leaves the receipts record
# standing. A generation whose runner died with its verdict staged, and whose
# replacement then ended the review, is therefore still owed its Received and
# Saved: without recovery after retirement nothing can ever resolve it - the
# capture is declined by publication for as long as the unconsumed verdict
# sits there, the captain's applied answers never appear on any receipt, the
# private verdict stays in the registry, and re-arming that artifact is refused
# forever because the round stays unhandled.
H18=$(make_home h18)
RECEIPT_HOME=$H18
ART18="$TMP_ROOT/deck18.html"
printf '<h1>deck</h1>\n' > "$ART18"
RECEIPT_SID=$(run_lavish "$H18" source-id "$ART18")
tasks_in "$H18" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H18" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
stub_ended_empty
run_captain "$H18" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H18" arm "$ART18" >/dev/null
journal="$H18/state/procevent/$RECEIPT_SID.receipts"
result="$H18/state/procevent-inbox/$RECEIPT_SID.1.result"
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_claim_free
[ -e "$result" ] || fail "the submitted round was never captured"
# Roll that generation back to the instant after its intake returned and before
# its seam ran: the round's own journal facts and the seam's note are gone, the
# record itself stands as retirement will leave it, and the dead claim still
# holds the verdict the runner recorded.
awk -F '\t' '$1 != "received" && $1 != "saved"' "$journal" > "$journal.rolled"
mv "$journal.rolled" "$journal"
chmod 0600 "$journal"
rm -f "$H18/state/procevent-inbox/$RECEIPT_SID.1.receipted"
# The announcement the live capture made is part of what is being rolled back:
# a runner killed before its seam never got that far.
rm -f "$H18/state/.wake-queue"
staged="$H18/state/procevent/.$RECEIPT_SID.dead-token.rcpt.output"
printf 'fed 0\nclosed: deck-alpha\n' > "$staged"
printf '%s\t%s\n' "$RECEIPT_SID" 1 > "$staged.gen"
chmod 0600 "$staged" "$staged.gen"
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' \
  "$H18" 999999 "$H18/state/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
# The replacement runner reclaims that dead claim, polls an ended review, and
# retires the source - all without ever consuming the verdict it preserved.
PATH="$STUB_BIN_DIR:$PATH" pe "$H18" start "$RECEIPT_SID" >/dev/null 2>&1 || true
assert_absent "$H18/state/procevent/$RECEIPT_SID.source" \
  "the ended review never retired, so this scenario proves nothing"
assert_present "$journal" "retirement removed the receipts record it must outlive"
assert_present "$staged" "the retiring replacement destroyed the dead runner's verdict"
grep -qs "procevent lavish $RECEIPT_SID 1" "$H18/state/.wake-queue" \
  && fail "the unacknowledged round was announced before its seam ever ran"
arm_status=0
PATH="$STUB_BIN_DIR:$PATH" run_lavish "$H18" arm "$ART18" >/dev/null 2>&1 || arm_status=$?
[ "$arm_status" -ne 0 ] || fail "arm reset a record whose captured round was still unhandled"
# Recovery after retirement journals that round from the verdict, drops the
# staging it consumed, and lets the capture finally reach the handler.
reconcile_until grep -qs '^saved' "$journal" \
  || fail "a retired source stranded the verdict its dead runner recorded"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 1 ] \
  || fail "the recovered round lost its answer count"
[ "$(awk -F '\t' '$1 == "saved" && $2 == 1 { print $4 }' "$journal")" = 1 ] \
  || fail "recovery lost the save the stranded verdict recorded"
straggler=''
for leftover in "$H18"/state/procevent/.*.rcpt.output*; do
  [ -e "$leftover" ] || continue
  straggler="$straggler $leftover"
done
[ -z "$straggler" ] || fail "recovery left its consumed staging behind:$straggler"
grep -qs "procevent lavish $RECEIPT_SID 1" "$H18/state/.wake-queue" \
  || fail "the recovered round was never announced to a handler"
text=$(run_lavish "$H18" receipt-text "$RECEIPT_SID")
assert_contains "$text" "saved 1 of 1" "the recovered round never reached the visible receipt"
pe "$H18" handled "$RECEIPT_SID" 1 >/dev/null
PATH="$STUB_BIN_DIR:$PATH" run_lavish "$H18" arm "$ART18" >/dev/null \
  || fail "arm stayed refused after the recovered round was handled"
pass "a retired source still recovers and announces the verdict its runner staged"

# --- the first round of a fresh artifact has no record to prove it by --------
# Arming unlinks the receipts record and nothing recreates it until a round is
# journaled, so an absent record is the NORMAL state while the very first
# submission is in flight. A runner killed then, whose replacement ends and
# retires the review, still owes that round: what proves the obligation is the
# verdict it staged, and the recovering seam creates the record it needs.
H19=$(make_home h19)
RECEIPT_HOME=$H19
ART19="$TMP_ROOT/deck19.html"
printf '<h1>deck</h1>\n' > "$ART19"
RECEIPT_SID=$(run_lavish "$H19" source-id "$ART19")
tasks_in "$H19" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H19" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
stub_ended_empty
run_captain "$H19" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H19" arm "$ART19" >/dev/null
journal="$H19/state/procevent/$RECEIPT_SID.receipts"
result="$H19/state/procevent-inbox/$RECEIPT_SID.1.result"
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_claim_free
[ -e "$result" ] || fail "the first submitted round was never captured"
# Roll back to the instant before that first seam ran: no record was ever
# created, no announcement was made, and the dead claim still holds the verdict
# the runner recorded for the round its intake had already applied.
rm -f "$journal" "$H19/state/procevent-inbox/$RECEIPT_SID.1.receipted" \
  "$H19/state/.wake-queue"
staged="$H19/state/procevent/.$RECEIPT_SID.dead-token.rcpt.output"
printf 'fed 0\nclosed: deck-alpha\n' > "$staged"
printf '%s\t%s\n' "$RECEIPT_SID" 1 > "$staged.gen"
chmod 0600 "$staged" "$staged.gen"
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' \
  "$H19" 999999 "$H19/state/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
PATH="$STUB_BIN_DIR:$PATH" pe "$H19" start "$RECEIPT_SID" >/dev/null 2>&1 || true
assert_absent "$H19/state/procevent/$RECEIPT_SID.source" \
  "the ended review never retired, so this scenario proves nothing"
assert_absent "$journal" "the fixture created a record this scenario must run without"
assert_present "$staged" "the retiring replacement destroyed the first round's verdict"
reconcile_until grep -qs '^saved' "$journal" \
  || fail "a first round with no record yet was dropped instead of recovered"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 1 ] \
  || fail "the recovered first round lost its answer count"
[ "$(awk -F '\t' '$1 == "saved" && $2 == 1 { print $4 }' "$journal")" = 1 ] \
  || fail "recovery lost the save the first round's verdict recorded"
straggler=''
for leftover in "$H19"/state/procevent/.*.rcpt.output*; do
  [ -e "$leftover" ] || continue
  straggler="$straggler $leftover"
done
[ -z "$straggler" ] || fail "recovery left its consumed staging behind:$straggler"
grep -qs "procevent lavish $RECEIPT_SID 1" "$H19/state/.wake-queue" \
  || fail "the recovered first round was never announced to a handler"
text=$(run_lavish "$H19" receipt-text "$RECEIPT_SID")
assert_contains "$text" "saved 1 of 1" "the recovered first round never reached the visible receipt"
pass "a first round whose record was never created is still recovered after retirement"

# --- explicit retirement never reaps a verdict its seam still owes -----------
# Retiring a source reaps the staging set of the claim it releases. That set
# includes the verdict a runner killed inside its unlocked intake left behind,
# and deleting it would both lose a round whose answers were already applied
# and re-enable the unacknowledged publication the generation note exists to
# hold back. The reap therefore takes only what has nothing left to prove.
H20=$(make_home h20)
RECEIPT_HOME=$H20
ART20="$TMP_ROOT/deck20.html"
printf '<h1>deck</h1>\n' > "$ART20"
RECEIPT_SID=$(run_lavish "$H20" source-id "$ART20")
tasks_in "$H20" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H20" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
run_captain "$H20" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H20" arm "$ART20" >/dev/null
journal="$H20/state/procevent/$RECEIPT_SID.receipts"
result="$H20/state/procevent-inbox/$RECEIPT_SID.1.result"
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_claim_free
[ -e "$result" ] || fail "the submitted round was never captured"
# Roll back to the instant before that runner's seam ran, with its dead claim
# and the whole staging set standing exactly as the reap will find them.
rm -f "$journal" "$H20/state/procevent-inbox/$RECEIPT_SID.1.receipted" \
  "$H20/state/.wake-queue"
staged="$H20/state/procevent/.$RECEIPT_SID.dead-token.rcpt.output"
printf 'fed 0\nclosed: deck-alpha\n' > "$staged"
printf '%s\t%s\n' "$RECEIPT_SID" 1 > "$staged.gen"
printf 'partial intake body\n' > "$staged.body"
printf 'half-written verdict\n' > "$staged.tmp"
printf 'stale capture\n' > "$H20/state/procevent/.$RECEIPT_SID.dead-token.output"
chmod 0600 "$staged" "$staged.gen" "$staged.body" "$staged.tmp" \
  "$H20/state/procevent/.$RECEIPT_SID.dead-token.output"
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' \
  "$H20" 999999 "$H20/state/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
pe "$H20" retire "$RECEIPT_SID" >/dev/null \
  || fail "explicit retirement refused a source whose runner had died"
assert_absent "$H20/state/procevent/$RECEIPT_SID.source" "retirement left the source registered"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim" "retirement left the dead claim behind"
assert_absent "$H20/state/procevent/.$RECEIPT_SID.dead-token.output" \
  "retirement left the dead generation's captured output staged"
assert_absent "$staged.body" "retirement left the dead generation's intake body staged"
assert_absent "$staged.tmp" "retirement left the dead generation's half-written verdict staged"
assert_present "$staged" "retirement destroyed a verdict whose receipt seam never ran"
assert_present "$staged.gen" "retirement destroyed the note pinning that verdict to its round"
# The round the retirement preserved is still journaled and still announced.
reconcile_until grep -qs '^saved' "$journal" \
  || fail "an explicitly retired source stranded the verdict its runner staged"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 1 ] \
  || fail "the recovered round lost its answer count"
[ "$(awk -F '\t' '$1 == "saved" && $2 == 1 { print $4 }' "$journal")" = 1 ] \
  || fail "recovery lost the save the preserved verdict recorded"
straggler=''
for leftover in "$H20"/state/procevent/.*.rcpt.output*; do
  [ -e "$leftover" ] || continue
  straggler="$straggler $leftover"
done
[ -z "$straggler" ] || fail "recovery left its consumed staging behind:$straggler"
grep -qs "procevent lavish $RECEIPT_SID 1" "$H20/state/.wake-queue" \
  || fail "the recovered round was never announced to a handler"
pass "explicit retirement preserves a verdict its receipt seam still owes"

# --- a live replacement never holds back an older generation's owed verdict ---
# The replacement runner that takes over a source after a crash claims it for
# its own poll, and a managed poll can stay in that claim indefinitely. The
# older generation's staged verdict is not that runner's to consume: it was
# staged under the dead claim's token, so deferring to the live claim leaves
# that round unacknowledged and its capture declined by publication for as long
# as the replacement polls.
H21=$(make_home h21)
RECEIPT_HOME=$H21
ART21="$TMP_ROOT/deck21.html"
printf '<h1>deck</h1>\n' > "$ART21"
RECEIPT_SID=$(run_lavish "$H21" source-id "$ART21")
tasks_in "$H21" add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
run_captain "$H21" hold deck-alpha --reason "alpha choice pending" >/dev/null
install_stub
stub_feedback false "$(choice_row 2 deck-alpha go 'Alpha')"
run_captain "$H21" bind "$RECEIPT_SID" >/dev/null
run_lavish "$H21" arm "$ART21" >/dev/null
journal="$H21/state/procevent/$RECEIPT_SID.receipts"
result="$H21/state/procevent-inbox/$RECEIPT_SID.1.result"
reconcile_once
wait_i=0
while [ ! -e "$result" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
wait_seam "$H21" "$RECEIPT_SID" 1
wait_claim_free
[ -e "$result" ] || fail "the submitted round was never captured"
# The replacement runner blocks inside its own poll, so its claim stays live
# for the whole recovery below - exactly the managed poll that can outlast any
# number of reconcile cycles.
: > "$STUB_HOLD"
held_calls_before=$(stub_calls)
reconcile_once
claim="$FM_PROCEVENT_CLAIM_ROOT/$RECEIPT_SID.claim"
wait_i=0
while [ ! -e "$claim" ] && [ "$wait_i" -lt 100 ]; do sleep 0.2; wait_i=$((wait_i + 1)); done
[ -e "$claim" ] || fail "the replacement runner never claimed the source"
wait_i=0
while [ "$(stub_calls)" -le "$held_calls_before" ] && [ "$wait_i" -lt 100 ]; do
  sleep 0.1
  wait_i=$((wait_i + 1))
done
[ "$(stub_calls)" -gt "$held_calls_before" ] \
  || fail "the replacement runner never started the poll it stays claimed for"
live_leader=$(sed -n '2p' "$claim")
live_token=$(sed -n '3p' "$claim")
[ -n "$live_token" ] || fail "could not read the live replacement's claim token"
[ "$live_token" != dead-token ] || fail "fixture invalid: the live claim reused the dead token"
# Roll the durable state back to the instant the crashed generation left it:
# its verdict staged under the claim token the replacement has since replaced,
# and no record that any seam ever saw that round.
rm -f "$journal" "$H21/state/procevent-inbox/$RECEIPT_SID.1.receipted"
staged="$H21/state/procevent/.$RECEIPT_SID.dead-token.rcpt.output"
printf 'fed 0\nclosed: deck-alpha\n' > "$staged"
printf '%s\t%s\n' "$RECEIPT_SID" 1 > "$staged.gen"
chmod 0600 "$staged" "$staged.gen"
reconcile_until grep -qs '^saved' "$journal" \
  || fail "a live replacement's poll stranded the verdict an older generation staged"
[ "$(awk -F '\t' '$1 == "received" { print $4 }' "$journal")" = 1 ] \
  || fail "the recovered round lost its answer count"
[ "$(awk -F '\t' '$1 == "saved" && $2 == 1 { print $4 }' "$journal")" = 1 ] \
  || fail "recovery lost the save the older generation had recorded"
# The recovery happened with that replacement still polling, not after it ended.
kill -0 "$live_leader" 2>/dev/null \
  || fail "fixture invalid: the replacement runner exited before the recovery"
[ -e "$claim" ] || fail "fixture invalid: the live claim was gone before the recovery"
text=$(run_lavish "$H21" receipt-text "$RECEIPT_SID")
assert_contains "$text" "saved 1 of 1" "the recovered round never reached the visible receipt"
assert_absent "$staged" "recovery left the superseded generation's verdict staged"
assert_absent "$staged.gen" "recovery left the superseded generation's note staged"
rm -f "$STUB_HOLD"
wait_claim_free
pass "a live replacement's claim never strands an older generation's owed verdict"

printf '\nall Lavish receipt tests passed\n'
