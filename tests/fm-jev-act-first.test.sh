#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-act-first.sh: the session-start digest's local
# ACT FIRST list and the deferred network stage's advisory Jev ranking.
#
# Drives the helper with a fake curl on PATH that records argv, the request
# body, and the header read from file descriptor 3. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT JEV_URL JEV_BASE \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_STATE_OVERRIDE

HELPER="$ROOT/bin/fm-jev-act-first.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-act-first)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
RESPONSE="$TMP_ROOT/response.json"
DRAIN="$TMP_ROOT/drain.txt"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "${FAKE_CURL_LOG:?}/argv"; shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
cat /dev/fd/3 > "$FAKE_CURL_LOG/header" 2>/dev/null || printf 'fd3 unreadable\n' > "$FAKE_CURL_LOG/header"
if [ "${FAKE_CURL_FAIL:-0}" = 1 ]; then
  exit 7
fi
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE"

respond() {  # <choice> <confidence> <probabilities-json>
  jq -n --arg c "$1" --argjson conf "$2" --argjson p "$3" \
    '{model: "jev-1.13.0", answers: {first: {type: "choice", choice: $c, confidence: $conf, probabilities: $p}}}' \
    > "$RESPONSE"
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state"
  {
    printf '1790000000\t7\tsignal\tship-a.status\tworking: tests running\n'
    printf '1790000001\t8\theartbeat\tfleet\t\n'
    printf 'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 8 --recovery-generation 3\n'
    printf 'UNREAD STATUS (new since last drain, not re-printed after this presentation):\n'
    printf 'ship-a note: captain requested keep the API stable\n'
    printf 'ship-b resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ship-b pending-reply-id=abcdef0123456789 via=status\n'
    printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
    printf 'scout-b [key=pick-lib] needs-decision: pick a library for the parser\n'
    printf "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n"
    printf 'UNFINISHED EXECUTION (task, accountable owner, next action; acknowledgement is not handling):\n'
    printf 'ship-c\tfirstmate\timplementation owner missing; dispatch or promote within approved intent\n'
  } > "$DRAIN"
  printf 'working: started\nfailed: build broke on main\n' > "$HOME_DIR/state/ship-d.status"
  printf 'kind=ship\n' > "$HOME_DIR/state/ship-d.meta"
  printf 'blocked: gone task\n' > "$HOME_DIR/state/gone-e.status"
}

run_helper() {  # <out-var> [args...]
  local __out=$1 _out
  shift
  rm -rf "$LOG"
  mkdir -p "$LOG"
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" TYPESAFE_API_KEY="${KEY-}" \
    FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" "$HELPER" "$@" </dev/null 2>"$TMP_ROOT/stderr")
  RUN_CODE=$?
  printf -v "$__out" '%s' "$_out"
}

test_usage() {
  local out
  run_helper out
  expect_code 2 "$RUN_CODE" "a missing drain file should be a usage error"
  pass "the drain file is required"
}

test_off_is_silent() {
  local out
  fresh_home
  KEY='' run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "off should exit 0"
  [ -z "$out" ] || fail "off printed output: $out"
  [ ! -e "$LOG/body" ] || fail "off made a model call"
  pass "with no key the helper is silent and makes no call"
}

test_ranks_collected_items() {
  local out lines
  fresh_home
  respond i1 0.7 '{"i1":0.7,"i2":0.12,"i3":0.1,"i4":0.05,"i5":0.03}'
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "a clear answer should exit 0"
  lines=$(printf '%s\n' "$out" | grep -c .)
  [ "$lines" -eq 5 ] || fail "printed $lines lines, want at most five"$'\n'"$out"
  assert_contains "$out" "1. decision scout-b [key=pick-lib] needs-decision: pick a library for the parser (p=0.7)" \
    "the top pick was not first"$'\n'"$out"
  assert_contains "$out" "2. execution ship-c owner=firstmate next=implementation owner missing" \
    "the execution row was not ranked second"$'\n'"$out"
  assert_contains "$out" "3. unread status ship-a note: captain requested keep the API stable (p=0.1)" \
    "the unread status item was not ranked after execution"$'\n'"$out"
  assert_contains "$out" "4. unread status ship-b resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ship-b pending-reply-id=abcdef0123456789 via=status (p=0.05)" \
    "the pending-reply resolution was not ranked after the unread note"$'\n'"$out"
  assert_contains "$out" "5. status ship-d failed: build broke on main (p=0.03)" \
    "the live task's failed status tail was not offered"$'\n'"$out"
  jq -e '.questions.first.type == "choice" and (.questions.first.criteria | length) == 7' "$LOG/body" >/dev/null \
    || fail "the request was not one Choice over the seven items"
  jq -e '[.questions.first.criteria[]] | any(startswith("wake signal ship-a.status: working"))' "$LOG/body" >/dev/null \
    || fail "a raw wake record was not offered"
  jq -e '[.questions.first.criteria[]] | any(contains("captain requested keep the API stable"))' "$LOG/body" >/dev/null \
    || fail "the unread status note was not sanitized and offered"
  jq -e '[.questions.first.criteria[]] | any(contains("pending-reply-resolved: task=ship-b"))' "$LOG/body" >/dev/null \
    || fail "the unread pending-reply resolution was not sanitized and offered"
  jq -e '[.questions.first.criteria[]] | all(test("gone task|WAKE_ACK") | not)' "$LOG/body" >/dev/null \
    || fail "a dead task's status or the ack line was offered"
  assert_no_grep "$TS_KEY" "$LOG/argv" "the key reached curl argv"
  assert_grep "Bearer $TS_KEY" "$LOG/header" "the key did not travel on fd 3"
  jq -e 'select(.purpose == "act-first" and .item_count == 7 and .choice == "i1")' \
    "$HOME_DIR/state/jev-act-first.jsonl" >/dev/null || fail "the call was not logged"
  jq -e 'select(.route == "typesafe" and .http == "200" and (.latency_ms | type) == "number")' \
    "$HOME_DIR/state/jev-act-first.jsonl" >/dev/null || fail "the call route and timing were not logged"
  pass "the collected items are ranked by Jev probabilities, at most five lines"
}

test_local_lists_priority_order_without_a_call() {
  local out
  fresh_home
  KEY='' run_helper out --local --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "--local should exit 0"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 5 ] || fail "--local did not print five lines"$'\n'"$out"
  assert_contains "$out" "1. decision scout-b [key=pick-lib] needs-decision: pick a library for the parser" \
    "--local did not put the open decision first"$'\n'"$out"
  assert_contains "$out" "3. unread status ship-a note: captain requested keep the API stable" \
    "--local did not include unread status after execution"$'\n'"$out"
  assert_contains "$out" "4. unread status ship-b resolved [key=pending-reply-abcdef0123456789]: pending-reply-resolved: task=ship-b pending-reply-id=abcdef0123456789 via=status" \
    "--local did not include the pending-reply resolution"$'\n'"$out"
  assert_contains "$out" "5. status ship-d failed: build broke on main" \
    "--local did not put status tails after unread status"$'\n'"$out"
  assert_not_contains "$out" "(p=" "--local printed a model probability"
  [ ! -e "$LOG/body" ] || fail "--local made a model call"
  pass "--local lists the items in priority order with no key and no call"
}

test_distinct_open_decision_keys_remain_separate() {
  local out
  fresh_home
  cat > "$DRAIN" <<'EOF'
OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
scout-a [key=pick-runtime] needs-decision: choose a runtime
scout-a [key=pick-license] needs-decision: choose a license
OPEN DECISIONS: close one by answering it
EOF
  KEY='' run_helper out --local --drain-file "$DRAIN"
  expect_code 0 "$RUN_CODE" "two distinct decisions should be listed"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "one of the decision keys disappeared from ACT FIRST"$'\n'"$out"
  assert_contains "$out" "scout-a [key=pick-runtime] needs-decision: choose a runtime" \
    "the runtime decision was omitted"$'\n'"$out"
  assert_contains "$out" "scout-a [key=pick-license] needs-decision: choose a license" \
    "the license decision was omitted"$'\n'"$out"
  pass "ACT FIRST keeps distinct keys for one task as separate actions"
}

test_keyed_status_wakes_and_tails_dedupe_in_both_key_positions() {
  local out
  fresh_home
  {
    printf '1790000000\t7\tsignal\ttask-z.status\tblocked [key=route]: waiting for route\n'
    printf '1790000001\t8\tsignal\ttask-z.status\tblocked: [key=access] waiting for access\n'
    printf '%s\n' \
      'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):' \
      'task-z [key=route] blocked: waiting for route' \
      'task-z blocked: [key=access] waiting for access' \
      'OPEN DECISIONS: close one by answering it'
  } > "$DRAIN"
  printf 'blocked: [key=route] waiting for route\n' > "$HOME_DIR/state/task-z.status"
  printf 'kind=ship\n' > "$HOME_DIR/state/task-z.meta"
  KEY='' run_helper out --local --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "keyed status events should deduplicate"
  [ "$(printf '%s\n' "$out" | grep -c 'task-z')" -eq 2 ] \
    || fail "keyed wakes or status tails duplicated the two decisions"$'\n'"$out"
  assert_contains "$out" "task-z [key=route] blocked: waiting for route" \
    "the route decision was omitted"$'\n'"$out"
  assert_contains "$out" "task-z blocked: [key=access] waiting for access" \
    "the access decision was omitted"$'\n'"$out"
  assert_not_contains "$out" "wake signal task-z.status" "a keyed wake was not deduplicated"$'\n'"$out"
  assert_not_contains "$out" "status task-z blocked" "a keyed status tail was not deduplicated"$'\n'"$out"
  pass "keyed status wakes and tails deduplicate across key positions"
}

test_correlated_status_wakes_dedupe_before_and_after_keys() {
  local out
  fresh_home
  {
    printf '1790000000\t7\tsignal\ttask-before.status\tneeds-decision corr=0123456789abcdef [key=choice]: choose a color\n'
    printf '1790000001\t8\tsignal\ttask-after.status\tneeds-decision [key=choice] corr=abcdef0123456789: choose a route\n'
    printf '%s\n' \
      'OPEN DECISIONS (still open):' \
      'task-before [key=choice] needs-decision: choose a color' \
      'task-after [key=choice] needs-decision: choose a route' \
      'OPEN DECISIONS: close one by answering it'
  } > "$DRAIN"
  KEY='' run_helper out --local --drain-file "$DRAIN"
  expect_code 0 "$RUN_CODE" "correlated decision wakes should deduplicate"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "correlated status wakes were ranked beside their open decisions"$'\n'"$out"
  assert_contains "$out" "decision task-before [key=choice] needs-decision: choose a color" \
    "the decision with corr before its key was omitted"$'\n'"$out"
  assert_contains "$out" "decision task-after [key=choice] needs-decision: choose a route" \
    "the decision with corr after its key was omitted"$'\n'"$out"
  assert_not_contains "$out" "wake signal" \
    "a correlated status wake was not deduplicated"$'\n'"$out"
  pass "correlated decision wakes deduplicate on either side of the key"
}

test_status_and_meta_symlinks_are_not_read() {
  local out outside_status outside_meta
  fresh_home
  rm -f "$HOME_DIR/state/"*
  outside_status="$TMP_ROOT/outside-status"
  outside_meta="$TMP_ROOT/outside-meta"
  printf 'failed: private status event\n' > "$outside_status"
  printf 'kind=ship\n' > "$outside_meta"
  ln -s "$outside_status" "$HOME_DIR/state/status-link.status"
  printf 'kind=ship\n' > "$HOME_DIR/state/status-link.meta"
  printf 'failed: private meta event\n' > "$HOME_DIR/state/meta-link.status"
  ln -s "$outside_meta" "$HOME_DIR/state/meta-link.meta"
  printf '1790000000\t7\theartbeat\talpha\t\n1790000001\t8\theartbeat\tbeta\t\n' > "$DRAIN"
  KEY='' run_helper out --local --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "symlinked state should be ignored"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "a symlinked status item was offered"$'\n'"$out"
  assert_not_contains "$out" "private status event" "a symlinked status file was read"$'\n'"$out"
  assert_not_contains "$out" "private meta event" "a symlinked meta file was accepted"$'\n'"$out"
  pass "ACT FIRST ignores symlinked status and metadata files"
}

test_local_items_ignore_network_state_limit() {
  local out long_note
  fresh_home
  long_note=$(printf 'x%.0s' $(seq 1 200))
  {
    printf '%s\n' 'OPEN DECISIONS (still open):'
    printf 'task-long needs-decision: %s\n' "$long_note"
    printf '%s\n' 'task-short needs-decision: choose a safe option' 'OPEN DECISIONS: close one by answering it'
  } > "$DRAIN"
  JEV_STATE_MAX_BYTES=32 KEY='' run_helper out --local --drain-file "$DRAIN"
  expect_code 0 "$RUN_CODE" "local output should not depend on the Jev state limit"
  assert_contains "$out" "1. decision task-long needs-decision:" "the long local item was dropped by the network-state limit"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | awk 'length($0) > 163 { print; exit }')" = "" ] || fail "a local item exceeded the 160-character display cap"$'\n'"$out"
  [ ! -e "$LOG/body" ] || fail "--local made a model call"
  pass "local ACT FIRST applies its display cap independently of the network state limit"
}

test_status_recovery_sections_are_ranked_without_wakes_or_decisions() {
  local out
  fresh_home
  {
    printf '1790000000\t7\tsignal\tworkflow-a.status\tdone: branch outcome was never recorded\n'
    cat <<'EOF'
STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):
workflow-a done: branch outcome was never recorded
RECORD DIVERGENCE (answered in the status log, still held in the backlog - nothing was closed automatically):
workflow-b [key=release] reads resolved in worker's status log but is still held for the captain
RECORD DIVERGENCE: reconcile each one - record the captain's own words
EOF
  } > "$DRAIN"
  KEY='' run_helper out --local --drain-file "$DRAIN"
  expect_code 0 "$RUN_CODE" "recovery sections should be listed locally"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "the recovery items were not both ranked without wakes or decisions"$'\n'"$out"
  assert_contains "$out" "1. status outcome workflow-a done: branch outcome was never recorded" \
    "the status outcome backstop was not the first recovery item"$'\n'"$out"
  assert_contains "$out" "2. record divergence workflow-b [key=release] reads resolved in worker's status log but is still held for the captain" \
    "the record divergence was not included after the backstop"$'\n'"$out"
  assert_not_contains "$out" "wake signal workflow-a.status" "the backstop and raw wake were not deduplicated"$'\n'"$out"
  pass "status outcome and divergence sections join the local ACT FIRST recovery items"
}

test_task_level_status_pointers_yield_to_detailed_items() {
  local out
  fresh_home
  {
    printf '1790000000\t7\tsignal\ttask-a.status\tneeds-decision: %s/state/task-a.status %s/state/task-b.status\n' "$HOME_DIR" "$HOME_DIR"
    printf '1790000001\t8\tsignal\ttask-b.status\tsignal: %s/state/task-a.status %s/state/task-b.status\n' "$HOME_DIR" "$HOME_DIR"
    printf '%s\n' \
      'OPEN DECISIONS (still open):' \
      'task-a [key=release] needs-decision: choose a release target' \
      'OPEN DECISIONS: close one by answering it' \
      'STATUS OUTCOME BACKSTOP (newest captain-facing task event has no covering branch outcome):' \
      'task-b done: branch outcome was never recorded'
  } > "$DRAIN"
  KEY='' run_helper out --local --drain-file "$DRAIN"
  expect_code 0 "$RUN_CODE" "task-level pointers should remain advisory"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "task-level pointers duplicated detailed items"$'\n'"$out"
  assert_contains "$out" "decision task-a [key=release] needs-decision: choose a release target" \
    "the detailed decision was not retained"$'\n'"$out"
  assert_contains "$out" "status outcome task-b done: branch outcome was never recorded" \
    "the detailed outcome was not retained"$'\n'"$out"
  assert_not_contains "$out" "wake signal" "a task-level pointer was retained beside its detail"$'\n'"$out"
  pass "task-level status pointers yield to detailed decision and outcome items"
}

test_unread_status_items_dedupe_task_level_wakes() {
  local out
  fresh_home
  {
    printf '1790000000\t7\tsignal\ttask-note.status\tsignal: task-note.status\n'
    printf '1790000001\t8\theartbeat\tfleet\t\n'
    printf '%s\n' \
      'UNREAD STATUS (new since last drain, not re-printed after this presentation):' \
      'task-note note: captain resolved the deployment question'
  } > "$DRAIN"
  KEY='' run_helper out --local --drain-file "$DRAIN"
  expect_code 0 "$RUN_CODE" "an unread status note should remain advisory"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "the unread status and heartbeat should be the only items"$'\n'"$out"
  assert_contains "$out" "unread status task-note note: captain resolved the deployment question" \
    "the unread status item was omitted"$'\n'"$out"
  assert_contains "$out" "wake heartbeat fleet" "the distinct heartbeat was omitted"$'\n'"$out"
  assert_not_contains "$out" "wake signal task-note.status" \
    "the task-level pointer duplicated its unread detail"$'\n'"$out"
  pass "an unread status item makes its task-level wake pointer redundant"
}

test_status_tail_items_dedupe_task_level_wakes() {
  local out
  fresh_home
  rm -f "$HOME_DIR/state/"*.status "$HOME_DIR/state/"*.meta
  printf 'failed: the deployment check failed\n' > "$HOME_DIR/state/task-tail.status"
  printf 'kind=ship\n' > "$HOME_DIR/state/task-tail.meta"
  {
    printf '1790000000\t7\tsignal\ttask-tail.status\tsignal: %s/state/task-tail.status\n' "$HOME_DIR"
    printf '1790000001\t8\theartbeat\tfleet\t\n'
  } > "$DRAIN"
  KEY='' run_helper out --local --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "a live failed status tail should remain advisory"
  [ "$(printf '%s\n' "$out" | grep -c .)" -eq 2 ] \
    || fail "the status tail, pointer, and distinct heartbeat were not deduplicated correctly"$'\n'"$out"
  assert_contains "$out" "1. status task-tail failed: the deployment check failed" \
    "the detailed status tail was not retained"$'\n'"$out"
  assert_contains "$out" "2. wake heartbeat fleet" "the distinct heartbeat was omitted"$'\n'"$out"
  assert_not_contains "$out" "wake signal task-tail.status" \
    "the failed status tail was duplicated by its task-level pointer"$'\n'"$out"
  pass "live failed status tails make task-level wake pointers redundant"
}

test_probability_maps_with_unoffered_keys_use_the_single_pick_fallback() {
  local out
  fresh_home
  respond i1 0.83 '{"i2":0.8,"unoffered":0.2}'
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "the valid single pick should remain usable"
  assert_contains "$out" "1. decision scout-b [key=pick-lib] needs-decision: pick a library for the parser (p=0.83)" \
    "an invalid probability map outranked the selected item"$'\n'"$out"
  jq -e 'select(.ranked_keys == ["i1"])' "$HOME_DIR/state/jev-act-first.jsonl" >/dev/null \
    || fail "the chosen item was not used as the single-pick fallback"
  pass "probability maps containing unoffered keys fall back to the selected item"
}

test_out_of_range_confidence_is_not_published_as_probability() {
  local out
  fresh_home
  respond i2 1.4 '{"unrelated-a":0.6,"unrelated-b":0.4}'
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "an invalid confidence should remain advisory"
  [ -z "$out" ] || fail "an out-of-range confidence was published: $out"
  jq -e 'select(.choice == "i2" and .ranked_keys == [])' "$HOME_DIR/state/jev-act-first.jsonl" >/dev/null \
    || fail "an out-of-range confidence produced a ranking"
  pass "ACT FIRST never publishes confidence outside the probability range"
}

test_unoffered_probability_keys_fall_back_to_the_chosen_item() {
  local out
  fresh_home
  respond i2 0.83 '{"unrelated-a":0.6,"unrelated-b":0.4}'
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "a valid pick should exit 0"
  assert_contains "$out" "1. execution ship-c owner=firstmate next=implementation owner missing; dispatch or promote within approved intent (p=0.83)" \
    "a valid pick vanished when probability keys did not match offered items"$'\n'"$out"
  jq -e 'select(.ranked_keys == ["i2"])' "$HOME_DIR/state/jev-act-first.jsonl" >/dev/null \
    || fail "the chosen item was not logged as the fallback ranking"
  pass "ACT FIRST falls back to the valid chosen item when probabilities do not map"
}

test_one_blocker_is_one_item() {
  local out
  fresh_home
  {
    printf '1790000000\t7\tsignal\ttask-z.status\tblocked: waiting on a key\n'
    printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
    printf 'task-z blocked: waiting on a key\n'
    printf "OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'\n"
  } > "$DRAIN"
  printf 'blocked: waiting on a key\n' > "$HOME_DIR/state/task-z.status"
  printf 'kind=ship\n' > "$HOME_DIR/state/task-z.meta"
  KEY='' run_helper out --local --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  [ "$(printf '%s\n' "$out" | grep -c 'task-z')" -eq 1 ] \
    || fail "one blocker was listed more than once"$'\n'"$out"
  assert_contains "$out" "1. decision task-z blocked: waiting on a key" \
    "the blocker did not keep its highest-priority form"$'\n'"$out"
  pass "one task in one state is one item across decisions, status tails, and wakes"
}

test_failures_are_silent() {
  local out
  fresh_home
  FAKE_CURL_FAIL=1 KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  expect_code 0 "$RUN_CODE" "a transport failure should exit 0"
  [ -z "$out" ] || fail "a transport failure printed output: $out"
  respond i99 0.9 '{"i99":0.9,"i1":0.1}'
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  [ -z "$out" ] || fail "an unoffered pick printed output: $out"
  pass "a failed call or an unoffered pick prints nothing"
}

test_single_item_makes_no_call() {
  local out
  fresh_home
  rm -f "$HOME_DIR/state/ship-d.status"
  printf '1790000000\t7\tsignal\tship-a.status\tblocked: need a key\n' > "$DRAIN"
  KEY=$TS_KEY run_helper out --drain-file "$DRAIN" --status-dir "$HOME_DIR/state"
  [ -z "$out" ] || fail "a single item printed output: $out"
  [ ! -e "$LOG/body" ] || fail "a single item made a model call"
  pass "fewer than two items makes no call"
}

test_usage
test_off_is_silent
test_ranks_collected_items
test_local_lists_priority_order_without_a_call
test_distinct_open_decision_keys_remain_separate
test_keyed_status_wakes_and_tails_dedupe_in_both_key_positions
test_correlated_status_wakes_dedupe_before_and_after_keys
test_status_and_meta_symlinks_are_not_read
test_task_level_status_pointers_yield_to_detailed_items
test_unread_status_items_dedupe_task_level_wakes
test_status_tail_items_dedupe_task_level_wakes
test_local_items_ignore_network_state_limit
test_status_recovery_sections_are_ranked_without_wakes_or_decisions
test_unoffered_probability_keys_fall_back_to_the_chosen_item
test_probability_maps_with_unoffered_keys_use_the_single_pick_fallback
test_out_of_range_confidence_is_not_published_as_probability
test_one_blocker_is_one_item
test_failures_are_silent
test_single_item_makes_no_call

echo "# all fm-jev-act-first tests passed"
