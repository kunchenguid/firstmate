#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-queue-triage.sh and its heartbeat caller.
#
# Drives the helper with a fake curl on PATH that records argv, the request
# body, and the header read from file descriptor 3. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_JEV_QUEUE_TRIAGE_BIN

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
HELPER="$ROOT/bin/fm-jev-queue-triage.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-queue-triage)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$LOG"

write_response() {
  cat > "$1" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": {
    "next": { "type": "choice", "choice": "dispatch_next", "confidence": 0.86,
      "probabilities": { "dispatch_next": 0.86, "blocked": 0.05, "needs_captain": 0.04, "nothing_ready": 0.05 } },
    "task": { "type": "choice", "choice": "ready-1", "confidence": 0.81,
      "probabilities": { "ready-1": 0.81, "none": 0.19 } }
  },
  "usage": { "input_tokens": 40, "output_tokens": 12 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ] \
  || [ -n "${OPENROUTER_API_KEY+x}" ] || [ -n "${OPENROUTER_API_KEY_PRIVATE+x}" ]; then
  printf 'curl:secret-present\n' >> "${CHILD_ENV_LOG:?}"
else
  printf 'curl:clean\n' >> "${CHILD_ENV_LOG:?}"
fi
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
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

RESPONSE="$TMP_ROOT/response.json"
write_response "$RESPONSE"
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
}

fresh_home() {
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  : > "$HOME_DIR/data/backlog.md"
}

add_task() {  # <id> <title> [extra tasks-axi args...]
  local id=$1 title=$2
  shift 2
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi add "$id" "$title" \
    --file data/backlog.md "$@") >/dev/null
}

# run_triage <exit-var> <out-var> <err-var> [args...]
run_triage() {
  local __exit=$1 __out=$2 __err=$3 _out _errfile _code
  shift 3
  _errfile="$TMP_ROOT/stderr"
  reset_log
  _code=0
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    FAKE_CURL_HTTP="${FAKE_CURL_HTTP:-200}" FAKE_CURL_FAIL="${FAKE_CURL_FAIL:-0}" \
    "$HELPER" "$@" </dev/null 2> "$_errfile") || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
  unset FAKE_CURL_HTTP FAKE_CURL_FAIL
}

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(LC_ALL=C wc -c < "$1" | tr -d '[:space:]')
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

test_help_exits_0() {
  local code out err
  run_triage code out err --help
  expect_code 0 "$code" "--help exits 0"
  assert_contains "$out" 'advisory next-work signal' "--help prints the header"
  pass "--help prints usage and exits 0"
}

test_empty_ready_set_makes_no_call() {
  local code out err
  fresh_home
  TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  expect_code 0 "$code" "empty ready exits 0"
  assert_contains "$out" 'jev-queue-triage: skipped' "empty ready prints skipped"
  [ ! -e "$LOG/argv" ] || fail "empty ready must not call curl"
  [ ! -e "$HOME_DIR/state/jev-queue-triage.jsonl" ] \
    || fail "empty ready must not append JSONL"
  [ ! -e "$HOME_DIR/state/jev-queue-triage.line" ] \
    || fail "empty ready must not leave a recommendation line"
  pass "an empty ready set makes no Jev call"
}

test_normal_suggestion_is_recorded() {
  local code out err record
  fresh_home
  add_task ready-1 'Ship a widget' --kind ship --repo firstmate
  add_task ready-2 'Scout the widget' --kind scout --repo wiki-tool
  TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  expect_code 0 "$code" "ready suggestion exits 0"
  record="$HOME_DIR/state/jev-queue-triage.jsonl"
  [ -f "$record" ] || fail "a Jev call must append JSONL"
  jq -e '.purpose == "queue-triage" and .advisory == true and .dispatch == false
      and .status == "clear" and .recommendation == "ready-1"
      and .next == "dispatch_next" and .confidence == 0.81
      and .route == "typesafe" and .http == "200"
      and (.latency_ms | type == "number" and . >= 0)' "$record" >/dev/null \
    || fail "JSONL must record an advisory dispatch_next recommendation: $(cat "$record")"
  assert_contains "$out" 'advisory, never dispatch' "stdout is the surface line"
  assert_contains "$out" 'task=ready-1' "stdout names the picked task"
  [ -f "$HOME_DIR/state/jev-queue-triage.line" ] || fail "recommendation writes the line file"
  assert_equals 'curl:clean' "$(cat "$LOG/child-env")" "the API key is absent from the curl environment"
  assert_contains "$(cat "$LOG/body")" '"dispatch_next"' "Choice includes dispatch_next"
  assert_contains "$(cat "$LOG/body")" '"needs_captain"' "Choice includes needs_captain"
  assert_contains "$(cat "$LOG/body")" '"ready-1"' "ready ids are Choice options"
  pass "a normal suggestion is recorded and surfaced"
}

test_captain_held_item_never_in_state() {
  local code out err body
  fresh_home
  add_task ready-1 'Ship a widget' --kind ship --repo firstmate
  add_task held-secret 'Captain private question' --kind ship --repo firstmate
  (cd "$HOME_DIR" && BEADS_ACTOR=fixture tasks-axi hold held-secret \
    --file data/backlog.md --reason 'SECRET_HOLD_REASON' --kind captain) >/dev/null
  TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  expect_code 0 "$code" "mixed queue exits 0"
  [ -f "$LOG/body" ] || fail "ready item should still produce a Jev call"
  body=$(cat "$LOG/body")
  assert_not_contains "$body" 'held-secret' "captain-held id must not enter Jev state"
  assert_not_contains "$body" 'Captain private question' "captain-held title must not enter Jev state"
  assert_not_contains "$body" 'SECRET_HOLD_REASON' "hold reason must not enter Jev state"
  assert_contains "$body" 'ready-1' "the ready item remains in state"
  pass "a captain-held item never appears in Jev state"
}

test_jev_failure_records_no_recommendation() {
  local code out err record
  fresh_home
  add_task ready-1 'Ship a widget' --kind ship --repo firstmate
  FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  expect_code 0 "$code" "Jev failure exits 0"
  record="$HOME_DIR/state/jev-queue-triage.jsonl"
  [ -f "$record" ] || fail "a failed Jev call must still append JSONL"
  jq -e '.status == "error" and .recommendation == null and .dispatch == false
      and .route == "typesafe" and .http == "000"
      and (.latency_ms | type == "number" and . >= 0)' \
    "$record" >/dev/null \
    || fail "failure record must not recommend: $(cat "$record")"
  assert_contains "$out" 'no-recommendation' "failure prints no-recommendation"
  [ ! -e "$HOME_DIR/state/jev-queue-triage.line" ] \
    || fail "failure must not leave a recommendation line"
  pass "a Jev failure records no recommendation"
}

test_low_confidence_is_not_a_recommendation() {
  local code out err
  fresh_home
  add_task ready-1 'Ship a widget' --kind ship --repo firstmate
  cat > "$RESPONSE" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": {
    "next": { "type": "choice", "choice": "dispatch_next", "confidence": 0.4,
      "probabilities": { "dispatch_next": 0.4, "blocked": 0.2, "needs_captain": 0.2, "nothing_ready": 0.2 } },
    "task": { "type": "choice", "choice": "ready-1", "confidence": 0.4,
      "probabilities": { "ready-1": 0.6, "none": 0.4 } }
  },
  "usage": { "input_tokens": 8, "output_tokens": 4 } }
JSON
  TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  write_response "$RESPONSE"
  expect_code 0 "$code" "low confidence exits 0"
  jq -e '.status == "no-recommendation" and .recommendation == null' \
    "$HOME_DIR/state/jev-queue-triage.jsonl" >/dev/null \
    || fail "below 0.7 must not recommend"
  [ ! -e "$HOME_DIR/state/jev-queue-triage.line" ] \
    || fail "low confidence must not leave a recommendation line"
  pass "confidence below 0.7 records no recommendation"
}

test_task_metadata_is_redacted_in_the_request() {
  local code out err body
  fresh_home
  add_task ready-1 'Ship GH_TOKEN=secret' --kind ship --repo firstmate
  mkdir -p "$HOME_DIR/data/ready-1"
  printf 'PRIVATE_REPORT_BODY\n' > "$HOME_DIR/data/ready-1/report.md"
  TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  expect_code 0 "$code" "redacted metadata exits 0"
  body=$(cat "$LOG/body")
  assert_not_contains "$body" 'secret' "no request path leaks the title secret"
  assert_not_contains "$body" 'PRIVATE_REPORT_BODY' "reports never enter the request"
  jq -e '(.state | contains("title=Ship [redacted]"))
      and .questions.task.criteria["ready-1"] == "Ship [redacted] (ship, firstmate)"' \
    "$LOG/body" >/dev/null || fail "both request paths must use the sanitized title"
  pass "state and criteria share sanitized task metadata"
}

test_both_confidences_must_meet_the_floor() {
  local code out err value answer
  fresh_home
  add_task ready-1 'Ship a widget' --kind ship --repo firstmate
  for answer in next task; do
    for value in 0.1 null '"0.95"' true -0.1 1.1 '{}'; do
      write_response "$RESPONSE"
      jq --arg answer "$answer" --argjson value "$value" \
        '.answers.next.confidence = 0.95 | .answers.task.confidence = 0.95
         | .answers[$answer].confidence = $value' "$RESPONSE" > "$TMP_ROOT/edited.json"
      mv "$TMP_ROOT/edited.json" "$RESPONSE"
      TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
      expect_code 0 "$code" "invalid or low confidence exits 0"
      jq -e '.status == "no-recommendation" and .recommendation == null' \
        "$HOME_DIR/state/jev-queue-triage.json" >/dev/null \
        || fail "$answer confidence $value must not recommend"
      [ ! -e "$HOME_DIR/state/jev-queue-triage.line" ] \
        || fail "invalid or low confidence must clear the line"
    done
  done
  write_response "$RESPONSE"
  jq '.answers.next.confidence = 0.8 | .answers.task.confidence = 0.8' \
    "$RESPONSE" > "$TMP_ROOT/edited.json"
  mv "$TMP_ROOT/edited.json" "$RESPONSE"
  JEV_CONFIDENCE_FLOOR=0.8 TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  jq -e '.status == "clear" and .confidence == 0.8' \
    "$HOME_DIR/state/jev-queue-triage.json" >/dev/null || fail "the configured floor is inclusive"
  JEV_CONFIDENCE_FLOOR=0.9 TYPESAFE_API_KEY=$TS_KEY run_triage code out err --heartbeat
  jq -e '.status == "no-recommendation"' "$HOME_DIR/state/jev-queue-triage.json" >/dev/null \
    || fail "both answers must meet the configured floor"
  write_response "$RESPONSE"
  pass "both numeric confidences must meet the configured floor"
}

test_drain_prints_line_only_on_heartbeat() {
  local dir state drain_out err
  dir=$(make_case triage-drain)
  state="$dir/state"
  printf 'JEV QUEUE TRIAGE (advisory, never dispatch): dispatch_next task=ready-1 confidence=0.86\n' \
    > "$state/jev-queue-triage.line"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  drain_out="$dir/drain.out"
  err="$dir/drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$err" || fail "heartbeat drain failed"
  assert_contains "$(cat "$drain_out")" 'advisory, never dispatch' \
    "heartbeat drain prints the advisory line"
  ack_drain_err "$state" "$err" >/dev/null || fail "heartbeat drain ack failed"
  append_wake "$state" signal task.status 'signal: task.status' || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$err" || fail "signal drain failed"
  assert_not_contains "$(cat "$drain_out")" 'advisory, never dispatch' \
    "a non-heartbeat drain does not print the advisory line"
  pass "drain prints the advisory line only on a heartbeat row"
}

test_watcher_records_a_suggestion_on_heartbeat() {
  local dir state fakebin out pid i
  dir=$(make_case triage-hb-record)
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  : > "$dir/data/backlog.md"
  (cd "$dir" && BEADS_ACTOR=fixture tasks-axi add ready-1 'Ship a widget' \
    --kind ship --repo firstmate --file data/backlog.md) >/dev/null
  printf 'working: routine heartbeat history\n' > "$state/routine.status"
  printf '%s' "$(seen_sig "$state/routine.status")" > "$state/.seen-routine_status"
  cp "$FAKEBIN/curl" "$fakebin/curl"
  chmod +x "$fakebin/curl"
  PATH="$fakebin:$FAKEBIN:$BASE_PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    TYPESAFE_API_KEY=$TS_KEY FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" \
    CHILD_ENV_LOG="$LOG/child-env" \
    "$WATCH" > "$dir/watch.out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited before a heartbeat: $(cat "$dir/watch.out")"
  fi
  i=0
  while [ "$i" -lt 200 ]; do
    [ -f "$state/jev-queue-triage.jsonl" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/jev-queue-triage.jsonl" ] \
    || { reap "$pid"; fail "heartbeat did not write JSONL"; }
  jq -e '.purpose == "queue-triage" and .recommendation == "ready-1" and .dispatch == false' \
    "$state/jev-queue-triage.jsonl" >/dev/null \
    || { reap "$pid"; fail "heartbeat JSONL was not a recommendation: $(cat "$state/jev-queue-triage.jsonl")"; }
  reap "$pid"
  pass "an actual heartbeat records a suggestion"
}

test_jev_failure_leaves_heartbeat_unaffected() {
  local dir state fakebin out pid i
  dir=$(make_case triage-hb-fail)
  state="$dir/state"
  fakebin="$dir/fakebin"
  cat > "$fakebin/jev-fail" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/jev-fail"
  printf 'working: routine heartbeat history\n' > "$state/routine.status"
  printf '%s' "$(seen_sig "$state/routine.status")" > "$state/.seen-routine_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    FM_JEV_QUEUE_TRIAGE_BIN="$fakebin/jev-fail" \
    "$WATCH" > "$dir/watch.out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a failed Jev helper: $(cat "$dir/watch.out")"
  fi
  i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -s "$dir/watch.out" ] || { reap "$pid"; fail "failed helper printed a wake: $(cat "$dir/watch.out")"; }
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] \
    || { reap "$pid"; fail "heartbeat backoff streak did not advance after a helper failure"; }
  reap "$pid"
  pass "a Jev failure leaves the heartbeat absorb path unaffected"
}

test_help_exits_0
test_empty_ready_set_makes_no_call
test_normal_suggestion_is_recorded
test_captain_held_item_never_in_state
test_jev_failure_records_no_recommendation
test_low_confidence_is_not_a_recommendation
test_task_metadata_is_redacted_in_the_request
test_both_confidences_must_meet_the_floor
test_drain_prints_line_only_on_heartbeat
test_watcher_records_a_suggestion_on_heartbeat
test_jev_failure_leaves_heartbeat_unaffected
