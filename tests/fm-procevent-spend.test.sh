#!/usr/bin/env bash
# Behavioral tests for bin/fm-procevent-spend.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BIN="$FM_ROOT/bin"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-procevent-spend.XXXXXX")
HOME_DIR="$LAB/home"
STATE_DIR="$HOME_DIR/state"
FAKEBIN="$LAB/fakebin"

cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$FAKEBIN" "$STATE_DIR" "$HOME_DIR/config"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

# A ledger stub: `task <id>` answers TASK_TOKENS, `week` answers WEEK_TOKENS
# (per family when WEEK_FAMILY_TOKENS is set); both fail when LEDGER_FAIL=1.
LEDGER="$FAKEBIN/fm-spend-ledger.py"
cat > "$LEDGER" <<'SH'
#!/usr/bin/env bash
if [ "${LEDGER_FAIL:-0}" = 1 ]; then
  exit 1
fi
# Mirror the real CLI: global options precede the subcommand.
while [ $# -gt 0 ]; do
  case "$1" in
    --state|--sessions-root|--scan-budget) shift 2 ;;
    *) break ;;
  esac
done
case "${1:-}" in
  task)
    case "${LEDGER_STATUS:-ok}" in
      empty)
        printf '{"status":"empty","totals":{"tokens":0}}\n'
        ;;
      partial)
        printf '{"status":"ok","partial":true,"totals":{"tokens":%s}}\n' "${TASK_TOKENS:-0}"
        ;;
      unavailable)
        printf '{"status":"unavailable","totals":{"tokens":0}}\n'
        ;;
      *)
        printf '{"status":"ok","partial":false,"totals":{"tokens":%s}}\n' "${TASK_TOKENS:-0}"
        ;;
    esac
    ;;
  week)
    if [ -n "${WEEK_FAMILY:-}" ]; then
      printf '{"totalTokens":%s,"families":{"%s":{"tokens":%s}}}\n' \
        "${WEEK_TOKENS:-0}" "$WEEK_FAMILY" "${WEEK_FAMILY_TOKENS:-0}"
    else
      printf '{"totalTokens":%s,"families":{}}\n' "${WEEK_TOKENS:-0}"
    fi
    ;;
  *)
    printf '{"status":"unavailable"}\n'
    ;;
esac
SH
chmod +x "$LEDGER"

# A control stub recording every invocation; fails when CONTROL_FAIL=1.
CONTROL="$FAKEBIN/fm-control.sh"
cat > "$CONTROL" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$CONTROL_COUNT" ] || read -r count < "$CONTROL_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$CONTROL_COUNT"
printf '%s %s\n' "$1" "$2" >> "$CONTROL_ARGS"
if [ "${CONTROL_FAIL:-0}" = 1 ]; then
  echo "error: control plane refused" >&2
  exit 1
fi
SH
chmod +x "$CONTROL"
CONTROL_COUNT="$LAB/control-count"
CONTROL_ARGS="$LAB/control-args"

write_meta() {  # <id> <spawn_gen> [harness]
  printf 'endpoint_task_id=%s\nworktree=/wt/%s\nspawn_gen=%s\nharness=%s\n' "$1" "$1" "$2" "${3:-pi}" \
    > "$STATE_DIR/$1.meta"
}

write_config() {  # <json>
  printf '%s\n' "$1" > "$HOME_DIR/config/spend-ceilings.json"
}

write_result() {  # <file> <status> [extra-lines...]
  local file=$1 status=$2; shift 2
  {
    printf 'spend: test\n'
    printf 'status: %s\n' "$status"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$file"
}

# capture_result <sid> <seq> <status> [extra-lines...] -> prints the result path.
# Fabricates the durable procevent-inbox layout the runner would have written,
# so fm-procevent.sh handled can acknowledge it.
capture_result() {
  local sid=$1 seq=$2 status=$3; shift 3
  local inbox="$STATE_DIR/procevent-inbox" file="$STATE_DIR/procevent-inbox/$sid.$seq.result"
  mkdir -p "$inbox"
  write_result "$file" "$status" "$@"
  printf 'spend\n' > "$STATE_DIR/procevent-inbox/$sid.$seq.adapter"
  printf '%s\n' "$file"
}

run_adapter() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_SPEND_LEDGER="$LEDGER" FM_CONTROL="$CONTROL" \
    CONTROL_COUNT="$CONTROL_COUNT" CONTROL_ARGS="$CONTROL_ARGS" \
    "$BIN/fm-procevent-spend.sh" "$@"
}

# --- help --------------------------------------------------------------------
if help=$("$BIN/fm-procevent-spend.sh" --help 2>&1); then
  fail "help unexpectedly exited zero"
fi
printf '%s\n' "$help" | grep -Fq 'fm-procevent-spend.sh autohandle <source-id> <sequence> <result-file>' \
  || fail "help omitted the autohandle usage"
if printf '%s\n' "$help" | grep -Fq 'set -u'; then
  fail "help leaked executable source"
fi
ok "help renders only the complete header"

# --- arm ---------------------------------------------------------------------
out=$(run_adapter arm --task t1)
printf '%s\n' "$out" | grep -Fq 'not arming' || fail "arm without config armed anyway: $out"
[ ! -e "$STATE_DIR/procevent/spend-task-t1.source" ] || fail "arm without config registered a source"
ok "arm is a no-op without a configured ceiling"

write_config '{"taskCeilingTokens": 5000, "pollIntervalSeconds": 7}'
if err=$(run_adapter arm --task t1 2>&1); then
  fail "arm unexpectedly succeeded without a task record: $err"
fi
printf '%s\n' "$err" | grep -Fq 'no task record' || fail "arm without meta returned: $err"
ok "arm refuses a task with no meta record"

write_meta t1 11
out=$(run_adapter arm --task t1)
printf '%s\n' "$out" | grep -Fq 'armed: spend-task-t1 ceiling=5000 interval=7s' \
  || fail "task arm output unexpected: $out"
grep -qx 'poll' "$STATE_DIR/procevent/spend-task-t1.source" 2>/dev/null \
  || grep -q 'poll' "$STATE_DIR/procevent/spend-task-t1.source" \
  || fail "task registration lacks the poll argv"
grep -Fq -- '--ceiling' "$STATE_DIR/procevent/spend-task-t1.source" \
  || fail "task registration lacks the ceiling"
ok "arm registers the per-task spend source"

out=$(run_adapter arm --task t1)
printf '%s\n' "$out" | grep -Fq 'already armed' || fail "second arm did not skip: $out"
ok "arm is idempotent for an already-registered task"

if err=$(run_adapter arm --task '../evil' 2>&1); then
  fail "arm accepted an unsafe task id"
fi
ok "arm rejects an unsafe task id"

write_config '{"taskCeilingTokens": 5000}'
write_meta t-codex 1 codex
out=$(run_adapter arm --task t-codex)
printf '%s\n' "$out" | grep -Fq 'not arming' || fail "codex harness armed a ceiling: $out"
[ ! -e "$STATE_DIR/procevent/spend-task-t-codex.source" ] || fail "codex harness registered a spend source"
ok "arm skips an unmeasured non-Pi harness"

write_meta t-signed 1 pi-signed
out=$(run_adapter arm --task t-signed)
printf '%s\n' "$out" | grep -Fq 'armed: spend-task-t-signed' || fail "pi-signed harness did not arm: $out"
ok "arm registers a pi-signed task"

write_config '{"fleetWindow": {"ceilingTokens": 9000, "hours": 24, "family": "codex"}}'
out=$(run_adapter arm --fleet)
printf '%s\n' "$out" | grep -Fq 'armed: spend-fleet' || fail "fleet arm output unexpected: $out"
grep -Fq -- '--family' "$STATE_DIR/procevent/spend-fleet.source" \
  || fail "fleet registration lacks the family"
grep -Fq -- 'codex' "$STATE_DIR/procevent/spend-fleet.source" \
  || fail "fleet registration lacks the family value"
ok "arm registers the fleet-window source"

out=$(run_adapter arm --fleet)
printf '%s\n' "$out" | grep -Fq 'already armed' || fail "second fleet arm did not skip: $out"
ok "fleet arm is idempotent"

write_config '{"fleetWindow": {}}'
rm -f "$STATE_DIR/procevent/spend-fleet.source"
out=$(run_adapter arm --fleet)
printf '%s\n' "$out" | grep -Fq 'not arming' || fail "fleet arm without ceiling armed anyway: $out"
[ ! -e "$STATE_DIR/procevent/spend-fleet.source" ] || fail "fleet arm without ceiling registered"
ok "fleet arm is a no-op without fleetWindow.ceilingTokens"

# --- poll: task --------------------------------------------------------------
write_meta t2 3
out=$(TASK_TOKENS=6000 run_adapter poll --task t2 --ceiling 5000 --interval 1)
printf '%s\n' "$out" | grep -qx 'status: ceiling' || fail "over-ceiling task did not fire: $out"
printf '%s\n' "$out" | grep -qx 'observed_tokens: 6000' || fail "result lacks observed tokens: $out"
printf '%s\n' "$out" | grep -qx 'task: t2' || fail "result lacks the task id: $out"
printf '%s\n' "$out" | grep -qx 'condition_polls: 1' || fail "over-ceiling task did not fire on the first poll"
ok "task poll fires on a crossed ceiling"

out=$(TASK_TOKENS=10 run_adapter poll --task t-missing --ceiling 5000 --interval 1)
printf '%s\n' "$out" | grep -qx 'status: gone' || fail "missing meta did not emit gone: $out"
ok "task poll reports gone when the task record is removed"

printf '{"version":1,"task":"t3","spawnGen":"9","actionResult":"ok"}\n' > "$STATE_DIR/t3.spend-stop"
write_meta t3 9
out=$(TASK_TOKENS=999999 run_adapter poll --task t3 --ceiling 5000 --interval 1)
printf '%s\n' "$out" | grep -qx 'status: stopped' || fail "stopped marker did not quiet the poll: $out"
ok "task poll stays quiet for the incarnation it already stopped"

write_meta t3 10
out=$(TASK_TOKENS=999999 run_adapter poll --task t3 --ceiling 5000 --interval 1)
printf '%s\n' "$out" | grep -qx 'status: ceiling' || fail "relaunched incarnation did not fire again: $out"
ok "task poll governs a relaunched incarnation again"

out=$(LEDGER_FAIL=1 run_adapter poll --task t2 --ceiling 5000 --interval 0.01)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "persistent ledger failure did not error: $out"
printf '%s\n' "$out" | grep -qx 'condition_polls: 5' || fail "ledger failure did not stop after the bound: $out"
ok "task poll reports an error after bounded ledger failures"

write_meta t-empty 1
LEDGER_STATUS=empty run_adapter poll --task t-empty --ceiling 5000 --interval 0.05 \
  > "$LAB/empty.out" 2>&1 &
empty_pid=$!
sleep 0.4
kill "$empty_pid" 2>/dev/null
wait "$empty_pid" 2>/dev/null
[ ! -s "$LAB/empty.out" ] || fail "empty ledger status produced a capture: $(cat "$LAB/empty.out")"
ok "task poll treats empty ledger status as unknown, not zero"

write_meta t-partial 1
LEDGER_STATUS=partial TASK_TOKENS=99999 run_adapter poll --task t-partial --ceiling 5000 --interval 0.05 \
  > "$LAB/partial.out" 2>&1 &
partial_pid=$!
sleep 0.4
kill "$partial_pid" 2>/dev/null
wait "$partial_pid" 2>/dev/null
[ ! -s "$LAB/partial.out" ] || fail "partial ledger total produced a capture: $(cat "$LAB/partial.out")"
ok "task poll does not treat a partial total as under-ceiling"

# --- poll: fleet -------------------------------------------------------------
out=$(WEEK_TOKENS=9500 run_adapter poll --fleet --ceiling 9000 --hours 24 --interval 1)
printf '%s\n' "$out" | grep -qx 'status: ceiling' || fail "fleet poll did not fire: $out"
printf '%s\n' "$out" | grep -qx 'observed_tokens: 9500' || fail "fleet result lacks observed tokens: $out"
printf '%s\n' "$out" | grep -qx 'family: all' || fail "fleet result lacks the all-family marker: $out"
ok "fleet poll fires on a crossed window ceiling"

out=$(WEEK_FAMILY=codex WEEK_TOKENS=99999 WEEK_FAMILY_TOKENS=9600 \
  run_adapter poll --fleet --ceiling 9000 --hours 24 --family codex --interval 1)
printf '%s\n' "$out" | grep -qx 'status: ceiling' || fail "fleet poll ignored the family filter"
printf '%s\n' "$out" | grep -qx 'observed_tokens: 9600' || fail "fleet poll summed the wrong scope: $out"
printf '%s\n' "$out" | grep -qx 'family: codex' || fail "fleet result lacks the family: $out"
ok "fleet poll scopes the window to a configured family"

# A fresh fired marker suppresses a re-fire: run briefly and expect silence.
jq -n --argjson fired "$(date +%s)" '{firedAtEpoch: $fired}' > "$STATE_DIR/spend-fleet-fired.json"
WEEK_TOKENS=9500 run_adapter poll --fleet --ceiling 9000 --hours 24 --interval 0.05 \
  > "$LAB/suppressed.out" 2>&1 &
suppressed_pid=$!
sleep 0.4
kill "$suppressed_pid" 2>/dev/null
wait "$suppressed_pid" 2>/dev/null
[ ! -s "$LAB/suppressed.out" ] || fail "fresh fleet marker did not suppress re-fire: $(cat "$LAB/suppressed.out")"
ok "fleet poll suppresses a re-fire inside the same window"

rm -f "$STATE_DIR/spend-fleet-fired.json"
out=$(LEDGER_FAIL=1 run_adapter poll --fleet --ceiling 9000 --hours 24 --interval 0.01)
printf '%s\n' "$out" | grep -qx 'status: error' || fail "fleet ledger failure did not error: $out"
ok "fleet poll reports an error after bounded ledger failures"

# --- classify / terminal / silent ---------------------------------------------
write_result "$LAB/r-ceiling" ceiling "observed_tokens: 5" "ceiling_tokens: 4"
write_result "$LAB/r-gone" gone "task: t9"
write_result "$LAB/r-stopped" stopped "task: t9"
write_result "$LAB/r-error" error "detail: x"
write_result "$LAB/r-garbage" nonsense

[ "$(run_adapter classify "$LAB/r-ceiling")" = ceiling ] || fail "classify missed ceiling"
[ "$(run_adapter classify "$LAB/r-garbage")" = unknown ] || fail "classify missed unknown"
run_adapter terminal "$LAB/r-ceiling" || fail "ceiling result is not terminal"
run_adapter terminal "$LAB/r-gone" || fail "gone result is not terminal"
run_adapter silent "$LAB/r-gone" || fail "gone result is not silent"
run_adapter silent "$LAB/r-stopped" || fail "stopped result is not silent"
if run_adapter silent "$LAB/r-ceiling"; then
  fail "ceiling result must not be silent"
fi
if run_adapter terminal "$LAB/r-garbage"; then
  fail "unknown result must not be terminal"
fi
ok "classify, terminal, and silent implement the result contract"

# --- autohandle: task ceiling -------------------------------------------------
write_meta t4 7
r_t4=$(capture_result spend-task-t4 1 ceiling "task: t4" "observed_tokens: 6100" "ceiling_tokens: 5000")
run_adapter autohandle spend-task-t4 1 "$r_t4" || fail "task autohandle failed"
[ "$(cat "$CONTROL_COUNT")" = 1 ] || fail "autohandle did not deliver one control stop"
grep -qx 't4 exit' "$CONTROL_ARGS" || fail "control stop used the wrong verb: $(cat "$CONTROL_ARGS")"
jq -e '.actionResult == "ok" and .spawnGen == "7" and .observedTokens == 6100' \
  "$STATE_DIR/t4.spend-stop" >/dev/null || fail "stop marker is wrong: $(cat "$STATE_DIR/t4.spend-stop")"
last_status=$(tail -1 "$STATE_DIR/t4.status")
case "$last_status" in
  "failed: spend ceiling crossed"*) ;;
  *) fail "status report is wrong: $last_status" ;;
esac
[ -f "$STATE_DIR/procevent-inbox/spend-task-t4.1.handled" ] \
  || fail "autohandle did not acknowledge the capture"
ok "task ceiling autohandle stops, reports, and acknowledges"

# Idempotent: a repeat call for the same incarnation stops nothing again.
r_t4b=$(capture_result spend-task-t4 2 ceiling "task: t4" "observed_tokens: 6100" "ceiling_tokens: 5000")
run_adapter autohandle spend-task-t4 2 "$r_t4b" || fail "repeat autohandle failed"
[ "$(cat "$CONTROL_COUNT")" = 1 ] || fail "repeat autohandle delivered a second stop"
ok "task autohandle is idempotent for the stopped incarnation"

# A relaunched incarnation (new spawn_gen) is governed again.
write_meta t4 8
r_t4c=$(capture_result spend-task-t4 3 ceiling "task: t4" "observed_tokens: 7000" "ceiling_tokens: 5000")
run_adapter autohandle spend-task-t4 3 "$r_t4c" || fail "relaunch autohandle failed"
[ "$(cat "$CONTROL_COUNT")" = 2 ] || fail "relaunched incarnation was not stopped again"
jq -e '.spawnGen == "8"' "$STATE_DIR/t4.spend-stop" >/dev/null \
  || fail "stop marker did not rebind to the new incarnation"
ok "task autohandle governs a relaunched incarnation again"

# A failed stop is reported but left unhandled for the check wake.
write_meta t5 1
r_t5=$(capture_result spend-task-t5 1 ceiling "task: t5" "observed_tokens: 8000" "ceiling_tokens: 5000")
if CONTROL_FAIL=1 run_adapter autohandle spend-task-t5 1 "$r_t5"; then
  fail "failed stop was autohandled"
fi
jq -e '.actionResult == "failed"' "$STATE_DIR/t5.spend-stop" >/dev/null \
  || fail "failed stop marker is wrong"
last_status=$(tail -1 "$STATE_DIR/t5.status")
case "$last_status" in
  "blocked: spend ceiling crossed"*) ;;
  *) fail "failed-stop status is wrong: $last_status" ;;
esac
[ ! -e "$STATE_DIR/procevent-inbox/spend-task-t5.1.handled" ] \
  || fail "failed stop acknowledged the capture"
ok "a failed stop reports blocked and stays unhandled"

# --- autohandle: fleet ---------------------------------------------------------
r_fleet=$(capture_result spend-fleet 4 ceiling "observed_tokens: 9500" "ceiling_tokens: 9000" \
  "window_hours: 24" "family: codex")
if run_adapter autohandle spend-fleet 4 "$r_fleet"; then
  fail "fleet autohandle acknowledged a report-only capture"
fi
jq -e '.observedTokens == 9500 and .ceilingTokens == 9000 and .family == "codex"' \
  "$STATE_DIR/spend-fleet-fired.json" >/dev/null \
  || fail "fleet fired marker is wrong: $(cat "$STATE_DIR/spend-fleet-fired.json")"
[ ! -e "$STATE_DIR/procevent-inbox/spend-fleet.4.handled" ] \
  || fail "fleet capture was acknowledged"
ok "fleet autohandle records the fire and leaves the wake to publish"

# Unknown sources and non-ceiling classes are not the adapter's to handle.
if run_adapter autohandle other-source 1 "$r_t4"; then
  fail "autohandle accepted a foreign source id"
fi
r_gone=$(capture_result spend-task-t4 9 gone "task: t4")
run_adapter autohandle spend-task-t4 9 "$r_gone" \
  || fail "gone autohandle failed"
ok "autohandle refuses foreign sources and quiets gone captures"

printf '# all fm-procevent-spend tests passed\n'
