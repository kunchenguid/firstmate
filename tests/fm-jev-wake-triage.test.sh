#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-wake-triage.sh and its hook in bin/fm-watch.sh.
#
# The helper is driven with a fake curl that records argv, the request body,
# and the header on fd 3, and answers with a canned typesafe.ai response.
# Watcher cases replace the helper through FM_JEV_WAKE_TRIAGE_BIN. No case
# touches the network.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

TOOL="$ROOT/bin/fm-jev-wake-triage.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-jev-wake-triage)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
HOME_DIR="$TMP_ROOT/home"
RESPONSE="$TMP_ROOT/response.json"
STATUS="$TMP_ROOT/task.status"
BASE_PATH=$PATH
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$LOG"
printf 'working: still monitoring ci\n' > "$STATUS"

KEY='test-key-jev-wake-never-on-argv'

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${TYPESAFE_API_KEY+x}" ] || [ -n "${TYPESAFE_API_KEY_PRIVATE+x}" ]; then
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

write_choice_response() {  # <choice> [noul] [confidence]
  local choice=$1 noul=${2:-0.5} confidence=${3:-0.9} p_wait=0.01 p_wedge=0.01 p_idle=0.01
  case "$choice" in
    pipeline_wait) p_wait=0.98 ;;
    true_wedge) p_wedge=0.98 ;;
    healthy_idle) p_idle=0.98 ;;
  esac
  cat > "$RESPONSE" <<JSON
{ "model": "jev-1.13.0",
  "answers": {
    "class": { "type": "choice", "choice": "$choice", "confidence": $confidence,
      "probabilities": { "pipeline_wait": $p_wait, "true_wedge": $p_wedge, "healthy_idle": $p_idle } },
    "wedge_probability": { "type": "noul", "noul": $noul }
  },
  "usage": { "input_tokens": 80, "output_tokens": 20 } }
JSON
}

reset_log() {
  rm -rf "$LOG"
  mkdir -p "$LOG"
  rm -f "$HOME_DIR/state/.jev-triage-telemetry" "$HOME_DIR/state/.jev-triage-calibration.jsonl" \
    "$HOME_DIR/state/.jev-triage-pending"
}

run_tool() {  # <exit-var> <out-var> [args...]
  local __exit=$1 __out=$2 _out _code
  shift 2
  _out=$(PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
}

code='' out=''
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$RESPONSE" CHILD_ENV_LOG="$LOG/child-env"

# --- absent key: unavailable, no network ------------------------------------
reset_log
code=''; out=''
run_tool code out --class ship --age 500 --escalation-count 2 --task wedged --status-file "$STATUS"
[ "$code" = 0 ] || fail "absent key must exit 0, got $code"
assert_contains "$out" 'action=unavailable' "absent key fail-opens to unavailable"
[ ! -e "$LOG/argv" ] || fail "absent key must not call curl"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-telemetry")" 'jev_triage.unavailable	ship' \
  "absent key stamps unavailable telemetry with the task class"
[ ! -e "$HOME_DIR/.env" ] || true
printf '%s\n' "TYPESAFE_API_KEY=$KEY" > "$HOME_DIR/.env"
reset_log
run_tool code out --class ship --age 500 --escalation-count 2 --task wedged --status-file "$STATUS"
[ ! -e "$LOG/argv" ] || fail "a .env key must not turn the helper on"
assert_contains "$out" 'action=unavailable' "a .env key still fail-opens"
pass "absent key and .env-only key fail open without a network call"

# --- true_wedge escalates ---------------------------------------------------
reset_log
write_choice_response true_wedge 0.91
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 2 \
  --task wedged --status-file "$STATUS"
[ "$code" = 0 ] || fail "wedge answer must exit 0, got $code"
assert_contains "$out" 'action=escalate' "true_wedge escalates"
assert_contains "$out" 'choice=true_wedge' "wedge choice is reported"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-telemetry")" 'jev_triage.escalated	ship' \
  "wedge stamps escalated telemetry"
assert_contains "$(cat "$LOG/argv")" 'https://api.typesafe.ai/v1/systemone' "the request uses the fixed endpoint"
assert_contains "$(cat "$LOG/body")" '"type": "choice"' "the request asks a Choice"
assert_contains "$(cat "$LOG/body")" '"type": "noul"' "the request asks a Noul"
assert_contains "$(cat "$LOG/body")" '"pipeline_wait"' "Choice criteria include pipeline_wait"
assert_contains "$(cat "$LOG/header")" "Authorization: Bearer $KEY" "the key arrives as the bearer header"
[ ! -f "$LOG/child-env" ] || assert_contains "$(cat "$LOG/child-env")" 'curl:clean' \
  "the key is absent from curl's environment"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-calibration.jsonl")" '"choice":"true_wedge"' \
  "calibration logs the Jev answer"
pass "true_wedge escalates, stamps telemetry, and logs calibration"

# --- pipeline_wait suppresses ----------------------------------------------
reset_log
write_choice_response pipeline_wait 0.12
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 1 \
  --task ship-ci --status-file "$STATUS"
[ "$code" = 0 ] || fail "pipeline_wait must exit 0, got $code"
assert_contains "$out" 'action=suppress' "pipeline_wait suppresses"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-telemetry")" 'jev_triage.suppressed	ship' \
  "pipeline_wait stamps suppressed telemetry"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-calibration.jsonl")" '"outcome":"pending"' \
  "a suppress is logged as pending outcome for later audit"
pass "pipeline_wait suppresses and stamps suppressed telemetry"

# --- healthy_idle suppresses -----------------------------------------------
reset_log
write_choice_response healthy_idle 0.08
TYPESAFE_API_KEY=$KEY run_tool code out --class secondmate --age 800 --escalation-count 0 \
  --task mate --status-file "$STATUS"
assert_contains "$out" 'action=suppress' "healthy_idle suppresses"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-telemetry")" 'jev_triage.suppressed	secondmate' \
  "healthy_idle stamps class secondmate"
pass "healthy_idle suppresses with the secondmate class"

# --- HTTP / transport error fail-opens -------------------------------------
reset_log
write_choice_response true_wedge 0.9
FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 \
  --escalation-count 2 --task wedged --status-file "$STATUS"
assert_contains "$out" 'action=unavailable' "HTTP 500 fail-opens"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-telemetry")" 'jev_triage.unavailable	ship' \
  "HTTP 500 stamps unavailable"
reset_log
write_choice_response true_wedge 0.9
FAKE_CURL_FAIL=1 TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 \
  --escalation-count 2 --task wedged --status-file "$STATUS"
assert_contains "$out" 'action=unavailable' "transport failure fail-opens"
pass "Jev HTTP and transport errors fail open to unavailable"

# --- malformed answer fail-opens -------------------------------------------
reset_log
printf '%s\n' '{"answers":{"class":{"choice":"maybe"}}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 0 \
  --task wedged --status-file "$STATUS"
assert_contains "$out" 'action=unavailable' "a malformed Choice fail-opens"
pass "a malformed Jev answer fail-opens"

# --- missing or below-floor confidence must not suppress --------------------
reset_log
write_choice_response pipeline_wait 0.2 0.34
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 2 \
  --task wedged --status-file "$STATUS"
assert_contains "$out" 'action=unavailable' "below-floor pipeline_wait must not suppress"
pass "below-floor confidence fail-opens instead of suppressing"

reset_log
write_choice_response true_wedge 0.91 0.34
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 2 \
  --task wedged --status-file "$STATUS"
assert_contains "$out" 'action=escalate' "below-floor true_wedge still escalates"
pass "below-floor true_wedge still pages"

reset_log
printf '%s\n' '{"answers":{"class":{"type":"choice","choice":"pipeline_wait","probabilities":{"pipeline_wait":0.98,"true_wedge":0.01,"healthy_idle":0.01}},"wedge_probability":{"type":"noul","noul":0.2}}}' > "$RESPONSE"
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 2 \
  --task wedged --status-file "$STATUS"
assert_contains "$out" 'action=unavailable' "missing confidence fail-opens"
pass "missing confidence fail-opens instead of suppressing"

# --- calibration caps at the first 20 decisions ----------------------------
reset_log
write_choice_response pipeline_wait 0.2
i=1
while [ "$i" -le 3 ]; do
  TYPESAFE_API_KEY=$KEY FM_JEV_WAKE_TRIAGE_CALIBRATION_LIMIT=2 run_tool code out \
    --class ship --age 500 --escalation-count 1 --task "t$i" --status-file "$STATUS"
  i=$((i + 1))
done
cal_n=$(grep -c '"summary"' "$HOME_DIR/state/.jev-triage-calibration.jsonl")
[ "$cal_n" = 2 ] || fail "calibration must stop after the limit, got $cal_n"
tel_n=$(grep -c 'jev_triage.suppressed' "$HOME_DIR/state/.jev-triage-telemetry")
[ "$tel_n" = 3 ] || fail "telemetry must keep counting after the calibration cap, got $tel_n"
pass "calibration logs the first N decisions; telemetry keeps counting"

# --- later_escalated must not append after the calibration cap -------------
reset_log
write_choice_response pipeline_wait 0.2
TYPESAFE_API_KEY=$KEY FM_JEV_WAKE_TRIAGE_CALIBRATION_LIMIT=2 run_tool code out \
  --class ship --age 500 --escalation-count 1 --task t1 --status-file "$STATUS"
TYPESAFE_API_KEY=$KEY FM_JEV_WAKE_TRIAGE_CALIBRATION_LIMIT=2 run_tool code out \
  --class ship --age 500 --escalation-count 1 --task t2 --status-file "$STATUS"
write_choice_response pipeline_wait 0.2
TYPESAFE_API_KEY=$KEY FM_JEV_WAKE_TRIAGE_CALIBRATION_LIMIT=2 run_tool code out \
  --class ship --age 500 --escalation-count 1 --task Z --status-file "$STATUS"
write_choice_response true_wedge 0.91
TYPESAFE_API_KEY=$KEY FM_JEV_WAKE_TRIAGE_CALIBRATION_LIMIT=2 run_tool code out \
  --class ship --age 500 --escalation-count 2 --task Z --status-file "$STATUS"
cal_n=$(grep -c '"summary"' "$HOME_DIR/state/.jev-triage-calibration.jsonl")
[ "$cal_n" = 2 ] || fail "cap must still hold after a post-cap later escalate, got $cal_n"
grep -F '"outcome":"later_escalated"' "$HOME_DIR/state/.jev-triage-calibration.jsonl" >/dev/null \
  && fail "later_escalated must not append after the calibration cap"
pass "later_escalated does not append after the calibration cap"

# --- the status tail is not repackaged as run-step evidence -----------------
reset_log
printf 'working: validating (running)\n' > "$TMP_ROOT/says-validating.status"
write_choice_response pipeline_wait 0.2
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 1 \
  --task says --status-file "$TMP_ROOT/says-validating.status"
jq -e '.state | has("run_step") | not' "$LOG/body" >/dev/null \
  || fail "the request presents the status tail as a separate run_step: $(cat "$LOG/body")"
jq -e '.state.last_status == "working: validating (running)"' "$LOG/body" >/dev/null \
  || fail "the request lost the status line it does carry"
jq -e '.questions.class.instructions | test("run_step") | not' "$LOG/body" >/dev/null \
  || fail "the Choice instructions still point Jev at a run_step field"
jq -se 'all(.[]; .summary | has("run_step") | not)' "$HOME_DIR/state/.jev-triage-calibration.jsonl" >/dev/null \
  || fail "calibration still records the status line as run_step"
pass "a status tail that says validating is never presented as run-step evidence"

# --- suppress -> unavailable -> escalate still records later_escalated -----
reset_log
write_choice_response pipeline_wait 0.2
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 1 \
  --task H --status-file "$STATUS"
FAKE_CURL_HTTP=500 TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 \
  --escalation-count 1 --task H --status-file "$STATUS"
assert_contains "$out" 'action=unavailable' "the middle call is unavailable"
write_choice_response true_wedge 0.91
TYPESAFE_API_KEY=$KEY run_tool code out --class ship --age 500 --escalation-count 2 \
  --task H --status-file "$STATUS"
later_n=$(grep -c '"outcome":"later_escalated"' "$HOME_DIR/state/.jev-triage-calibration.jsonl")
[ "$later_n" = 1 ] || fail "suppress -> unavailable -> escalate must record one later_escalated, got $later_n"
pass "an unavailable answer does not erase an earlier suppression"

# --- telemetry is capped like the watcher triage log ------------------------
reset_log
i=0
while [ "$i" -lt 2100 ]; do printf 'jev_triage.old\tship\n'; i=$((i + 1)); done > "$HOME_DIR/state/.jev-triage-telemetry"
FM_WATCH_TRIAGE_LOG_MAX_BYTES=4096 run_tool code out --class scout --age 1 --escalation-count 0 \
  --task cap --status-file "$STATUS"
tel_lines=$(wc -l < "$HOME_DIR/state/.jev-triage-telemetry" | tr -d ' ')
[ "$tel_lines" -le 2000 ] || fail "telemetry past the cap kept $tel_lines lines"
[ "$(tail -n 1 "$HOME_DIR/state/.jev-triage-telemetry")" = "$(printf 'jev_triage.unavailable\tscout')" ] \
  || fail "telemetry rotation dropped the newest entry"
pass "telemetry past the size cap keeps the newest 2000 lines"

# --- unknown class is coerced so telemetry never carries free text ---------
reset_log
run_tool code out --class 'not-a-kind' --age 1 --escalation-count 0 --task x --status-file "$STATUS"
assert_contains "$out" 'class=unknown' "an unknown kind is coerced"
assert_contains "$(cat "$HOME_DIR/state/.jev-triage-telemetry")" 'jev_triage.unavailable	unknown' \
  "telemetry uses the coerced class only"
pass "telemetry class is coerced to the known set"

# --- watcher: pipeline_wait suppresses the stale escalation ----------------
ack_stopped_cycle() {
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation"
}

wait_poll_cycle() {
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

file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

install_fake_jev() {  # <fakebin> <action>
  local fakebin=$1 action=$2
  cat > "$fakebin/fm-jev-wake-triage.sh" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$@" >> "$fakebin/jev.argv"
printf 'action=$action\nclass=ship\nchoice=pipeline_wait\nnoul=0.1\n'
exit 0
SH
  chmod +x "$fakebin/fm-jev-wake-triage.sh"
}

start_stale_watch() {  # <state> <fakebin> <out> <window> <capture_file>
  local state=$1 fakebin=$2 out=$3 window=$4 capture_file=$5
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

prime_stale_case() {  # <name> -> prints dir; sets up classified stale hash past threshold
  local name=$1 dir state fakebin capture_file window key pane_hash
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
  capture_file="$dir/pane.txt"; window="test:fm-jev-$name"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  prime_status_seen "$state" "$state/wedged.status" || fail "could not prime status seen for $name"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '%s\n' "$dir"
}

test_watcher_pipeline_wait_suppresses() {
  local dir state fakebin out capture_file window key pid back
  dir=$(prime_stale_case jev-suppress)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-suppress"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  back=$(cat "$state/.stale-since-$key")
  install_fake_jev "$fakebin" suppress
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=on
  FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; unset FM_JEV_WAKE_TRIAGE; fail "watcher escalated a pipeline_wait pane: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "pipeline_wait printed a wake reason: $(cat "$out")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "pipeline_wait advanced the escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "pipeline_wait did not restart the idle timer"; }
  [ -s "$fakebin/jev.argv" ] || { reap "$pid"; fail "pipeline_wait never invoked Jev"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the pipeline_wait watcher stop"
  unset FM_FAKE_CREW_STATE FM_JEV_WAKE_TRIAGE
  pass "watcher pipeline_wait suppresses the stale escalation and restarts the idle timer"
}

# Suppression streaks are capped at FM_WEDGE_DEMAND_INSPECT_COUNT (default 3)
# per window while the last status line is unchanged. The streak marker is the
# watcher's persisted per-window state: "<status-line-hash> <count>".
seed_streak() {  # <state> <key> <status-line> <count>
  printf '%s %s\n' "$(hash_text "$3")" "$4" > "$1/.jev-suppress-$2"
}

test_watcher_short_streak_still_suppresses() {
  local dir state fakebin out capture_file window key pid
  dir=$(prime_stale_case jev-short)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-short"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  seed_streak "$state" "$key" "working: still monitoring ci" 2
  install_fake_jev "$fakebin" suppress
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=on
  FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; unset FM_JEV_WAKE_TRIAGE; fail "a streak below the cap escalated: $(cat "$out")"
  fi
  unset FM_JEV_WAKE_TRIAGE
  [ ! -s "$out" ] || { reap "$pid"; fail "a streak below the cap printed a wake reason: $(cat "$out")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "a streak below the cap advanced the escalation counter"; }
  [ -s "$fakebin/jev.argv" ] || { reap "$pid"; fail "a streak below the cap never invoked Jev"; }
  [ "$(cut -d' ' -f2 "$state/.jev-suppress-$key")" = 3 ] || { reap "$pid"; fail "suppression did not extend the streak: $(cat "$state/.jev-suppress-$key")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the short-streak watcher stop"
  unset FM_FAKE_CREW_STATE
  pass "a suppression streak below the cap stays quiet and extends the streak"
}

test_watcher_capped_streak_pages() {
  local dir state fakebin out capture_file window key pid
  dir=$(prime_stale_case jev-capped)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-capped"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  seed_streak "$state" "$key" "working: still monitoring ci" 3
  printf '2\n' > "$state/.wedge-escalations-$key"
  install_fake_jev "$fakebin" suppress
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=on
  FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  wait_for_exit "$pid" 100 || { unset FM_JEV_WAKE_TRIAGE; fail "a capped streak did not escalate: $(cat "$out")"; }
  unset FM_JEV_WAKE_TRIAGE
  grep -F "demand-deep-inspection" "$out" >/dev/null || fail "a capped streak did not reach the demand-inspect page: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 3 ] || fail "a capped streak did not advance the escalation counter"
  [ ! -e "$fakebin/jev.argv" ] || fail "a capped streak still spent a Jev call"
  ack_stopped_cycle "$state" || fail "could not acknowledge the capped-streak escalation"
  unset FM_FAKE_CREW_STATE
  pass "a capped suppression streak escalates without Jev and reaches demand-deep-inspection"
}

test_watcher_new_status_line_resets_streak() {
  local dir state fakebin out capture_file window key pid
  dir=$(prime_stale_case jev-reset)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-reset"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  seed_streak "$state" "$key" "working: an older status line" 3
  install_fake_jev "$fakebin" suppress
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=on
  FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; unset FM_JEV_WAKE_TRIAGE; fail "a new status line inherited the old streak and escalated: $(cat "$out")"
  fi
  unset FM_JEV_WAKE_TRIAGE
  [ ! -s "$out" ] || { reap "$pid"; fail "a new status line printed a wake reason: $(cat "$out")"; }
  [ -s "$fakebin/jev.argv" ] || { reap "$pid"; fail "a new status line did not consult Jev"; }
  [ "$(cat "$state/.jev-suppress-$key")" = "$(hash_text "working: still monitoring ci") 1" ] \
    || { reap "$pid"; fail "a new status line did not restart the streak: $(cat "$state/.jev-suppress-$key")"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the streak-reset watcher stop"
  unset FM_FAKE_CREW_STATE
  pass "a changed last status line restarts the suppression streak"
}

test_watcher_true_wedge_escalates() {
  local dir state fakebin out capture_file window key pid
  dir=$(prime_stale_case jev-escalate)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-escalate"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  cat > "$fakebin/fm-jev-wake-triage.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'action=escalate\nclass=ship\nchoice=true_wedge\nnoul=0.9\n'
exit 0
SH
  chmod +x "$fakebin/fm-jev-wake-triage.sh"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=on
  FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  wait_for_exit "$pid" 100 || { unset FM_JEV_WAKE_TRIAGE; fail "true_wedge did not escalate: $(cat "$out")"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "true_wedge did not print a possible-wedge reason: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "true_wedge was not counted"
  ack_stopped_cycle "$state" || fail "could not acknowledge the true_wedge escalation"
  unset FM_FAKE_CREW_STATE FM_JEV_WAKE_TRIAGE
  pass "watcher true_wedge still escalates on today's stale reason"
}

test_watcher_jev_error_fails_open() {
  local dir state fakebin out capture_file window key pid
  dir=$(prime_stale_case jev-error)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-error"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  cat > "$fakebin/fm-jev-wake-triage.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'action=unavailable\nclass=ship\n'
exit 0
SH
  chmod +x "$fakebin/fm-jev-wake-triage.sh"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=on
  FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  wait_for_exit "$pid" 100 || { unset FM_JEV_WAKE_TRIAGE; fail "unavailable Jev did not fail open to escalate: $(cat "$out")"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "unavailable Jev lost today's escalate reason: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "unavailable Jev was not counted as today's escalation"
  ack_stopped_cycle "$state" || fail "could not acknowledge the fail-open escalation"
  unset FM_FAKE_CREW_STATE FM_JEV_WAKE_TRIAGE
  pass "watcher Jev error fails open to today's escalate path"
}

# The gate matrix: no file and no env is off; a present file or a non-empty
# FM_JEV_WAKE_TRIAGE is on only for on/1/true/yes (any case), and the env
# value beats the file. The fake Jev escalates, so the watcher exits either way
# and only the Jev call differs.
gate_case() {  # <name> <file-first-line|-> <env> <expect on|off>
  local name=$1 line=$2 env=$3 expect=$4 dir state fakebin out capture_file window pid
  dir=$(prime_stale_case "$name")
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-$name"
  mkdir -p "$dir/config"
  case "$line" in
    -) ;;
    '') : > "$dir/config/jev-wake-triage" ;;
    *) printf '%s\n' "$line" > "$dir/config/jev-wake-triage" ;;
  esac
  install_fake_jev "$fakebin" escalate
  export FM_JEV_WAKE_TRIAGE=$env
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  FM_CONFIG_OVERRIDE="$dir/config" FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  unset FM_JEV_WAKE_TRIAGE
  wait_for_exit "$pid" 100 || fail "gate file='$line' env='$env' did not escalate: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null || fail "gate file='$line' env='$env' lost today's escalate reason: $(cat "$out")"
  if [ "$expect" = on ]; then
    [ -s "$fakebin/jev.argv" ] || fail "gate file='$line' env='$env' did not call Jev"
  else
    [ ! -e "$fakebin/jev.argv" ] || fail "gate file='$line' env='$env' called Jev while the gate should be off"
  fi
  ack_stopped_cycle "$state" || fail "could not acknowledge the gate file='$line' env='$env' escalation"
  unset FM_FAKE_CREW_STATE
}

test_watcher_gate_matrix() {
  local i=0 v
  gate_case gate-default - '' off
  for v in off '' garbage ONN tru 1x of; do
    i=$((i + 1)); gate_case "cfg-off-$i" "$v" '' off
  done
  for v in on 1 true yes ON True YES; do
    i=$((i + 1)); gate_case "cfg-on-$i" "$v" '' on
  done
  gate_case env-off-file-on on off off
  gate_case env-garbage - garbage off
  gate_case env-typo-file-on on of off
  pass "Jev gate: default off; file and env on only for on/1/true/yes; env beats file"
}

# FM_JEV_WAKE_TRIAGE is the documented override of config/jev-wake-triage in
# both directions. The watcher reads the env value before it opens the file, so
# the off case needs no config fixture; the on case pins a config directory that
# says off, which is the only way to prove the env value wins over a file.
test_watcher_env_off_skips_jev() {
  local dir state fakebin out capture_file window key pid
  dir=$(prime_stale_case jev-env-off)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-env-off"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  install_fake_jev "$fakebin" suppress
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=off
  FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  wait_for_exit "$pid" 100 || { unset FM_JEV_WAKE_TRIAGE; fail "FM_JEV_WAKE_TRIAGE=off did not keep today's escalate path: $(cat "$out")"; }
  unset FM_JEV_WAKE_TRIAGE
  grep -F "possible wedge" "$out" >/dev/null || fail "FM_JEV_WAKE_TRIAGE=off lost today's escalate reason: $(cat "$out")"
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || true)" = 1 ] || fail "FM_JEV_WAKE_TRIAGE=off did not count today's escalation"
  [ ! -e "$fakebin/jev.argv" ] || fail "FM_JEV_WAKE_TRIAGE=off still invoked Jev"
  ack_stopped_cycle "$state" || fail "could not acknowledge the env-off escalation"
  unset FM_FAKE_CREW_STATE
  pass "FM_JEV_WAKE_TRIAGE=off disables triage with no config file present"
}

test_watcher_env_on_beats_config_off() {
  local dir state fakebin out capture_file window key pid back
  dir=$(prime_stale_case jev-env-on)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  capture_file="$dir/pane.txt"; window="test:fm-jev-jev-env-on"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  back=$(cat "$state/.stale-since-$key")
  mkdir -p "$dir/config"
  printf 'off\n' > "$dir/config/jev-wake-triage"
  install_fake_jev "$fakebin" suppress
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  export FM_JEV_WAKE_TRIAGE=on
  FM_CONFIG_OVERRIDE="$dir/config" FM_JEV_WAKE_TRIAGE_BIN="$fakebin/fm-jev-wake-triage.sh" \
    start_stale_watch "$state" "$fakebin" "$out" "$window" "$capture_file"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; unset FM_JEV_WAKE_TRIAGE; fail "FM_JEV_WAKE_TRIAGE=on did not suppress over a config file that says off: $(cat "$out")"
  fi
  unset FM_JEV_WAKE_TRIAGE
  [ ! -s "$out" ] || { reap "$pid"; fail "FM_JEV_WAKE_TRIAGE=on printed a wake reason: $(cat "$out")"; }
  [ -s "$fakebin/jev.argv" ] || { reap "$pid"; fail "FM_JEV_WAKE_TRIAGE=on never invoked Jev over the config file"; }
  [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; fail "FM_JEV_WAKE_TRIAGE=on advanced the escalation counter"; }
  [ "$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)" -gt "$back" ] \
    || { reap "$pid"; fail "FM_JEV_WAKE_TRIAGE=on did not restart the idle timer"; }
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the env-on watcher stop"
  unset FM_FAKE_CREW_STATE
  pass "FM_JEV_WAKE_TRIAGE=on re-enables triage over config/jev-wake-triage=off"
}

test_watcher_pipeline_wait_suppresses
test_watcher_short_streak_still_suppresses
test_watcher_capped_streak_pages
test_watcher_new_status_line_resets_streak
test_watcher_true_wedge_escalates
test_watcher_jev_error_fails_open
test_watcher_gate_matrix
test_watcher_env_off_skips_jev
test_watcher_env_on_beats_config_off

echo "# all fm-jev-wake-triage tests passed"
