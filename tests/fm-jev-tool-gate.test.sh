#!/usr/bin/env bash
# Behavior tests for bin/fm-jev-tool-gate.sh.
#
# Drives the remainder gate through its public CLI. A fake curl on PATH is
# Jev: a deterministic deny must never invoke it, and a deterministic allow
# must append $FM_HOME/state/jev-tool-gate.jsonl. No case touches the network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-jev-tool-gate.sh"

unset TYPESAFE_API_KEY OPENROUTER_API_KEY TYPESAFE_API_KEY_PRIVATE \
  OPENROUTER_API_KEY_PRIVATE JEV_ROUTE JEV_MODEL JEV_TIMEOUT \
  JEV_CONFIDENCE_FLOOR JEV_STATE_MAX_BYTES FM_JEV_TOOL_GATE

TMP_ROOT=$(fm_test_tmproot fm-jev-tool-gate)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/curl-log"
BASE_PATH=$PATH
TS_KEY='ts-test-key-not-for-argv'
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$LOG"

write_choice() {
  local choice=$1
  cat > "$TMP_ROOT/response.json" <<JSON
{ "model": "jev-latest",
  "answers": { "gate": { "type": "choice", "choice": "$choice", "confidence": 0.91,
    "probabilities": { "allow": 0.05, "deny": 0.9, "need_human": 0.05 } } },
  "usage": { "input_tokens": 20, "output_tokens": 8 } }
JSON
}

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
mkdir -p "${FAKE_CURL_LOG:?}"
printf 'called\n' >> "$FAKE_CURL_LOG/called"
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat > "$FAKE_CURL_LOG/body"
if [ -n "$out" ]; then
  cp "${FAKE_CURL_RESPONSE:?}" "$out"
fi
printf '%s' "${FAKE_CURL_HTTP:-200}"
SH
chmod +x "$FAKEBIN/curl"

write_choice deny
export FAKE_CURL_LOG="$LOG" FAKE_CURL_RESPONSE="$TMP_ROOT/response.json"

reset_log() {
  rm -rf "$LOG" "$HOME_DIR/state/jev-tool-gate.jsonl"
  mkdir -p "$LOG" "$HOME_DIR/state"
}

# run_gate <exit-var> <err-var> <command>
run_gate() {
  local __exit=$1 __err=$2 _cmd=$3 _errfile _code
  _errfile="$TMP_ROOT/stderr"
  reset_log
  _code=0
  PATH="$FAKEBIN:$BASE_PATH" FM_HOME="$HOME_DIR" \
    TYPESAFE_API_KEY="${TYPESAFE_API_KEY-}" \
    FM_JEV_TOOL_GATE="${FM_JEV_TOOL_GATE-}" \
    "$GATE" --command "$_cmd" >/dev/null 2> "$_errfile" || _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__err" '%s' "$(cat "$_errfile")"
}

test_help_mentions_do_not() {
  local out
  out=$("$GATE" --help)
  assert_contains "$out" 'do-not' "help warns that hard-shipping live deny is a do-not"
  assert_contains "$out" 'shadow' "help names the shadow default"
  pass "help names shadow default and the live hard-ship do-not"
}

test_deterministic_deny_never_reaches_jev() {
  local code err
  TYPESAFE_API_KEY=$TS_KEY FM_JEV_TOOL_GATE=shadow \
    run_gate code err 'pkill -f fm-watch'
  expect_code 2 "$code" "deterministic deny exits 2"
  assert_contains "$err" 'deterministic deny' "stderr names the deterministic deny"
  [ ! -e "$LOG/called" ] || fail "fake Jev must not be invoked on a deterministic deny"
  [ ! -e "$HOME_DIR/state/jev-tool-gate.jsonl" ] || fail "deny must not write the remainder log"
  pass "deterministic deny never reaches fake Jev and does not log"
}

test_allow_reaches_log() {
  local code err line
  write_choice allow
  TYPESAFE_API_KEY=$TS_KEY FM_JEV_TOOL_GATE=shadow \
    run_gate code err 'echo hello'
  expect_code 0 "$code" "deterministic allow exits 0 in shadow"
  [ -f "$LOG/called" ] || fail "fake Jev must be invoked after a deterministic allow"
  [ -f "$HOME_DIR/state/jev-tool-gate.jsonl" ] || fail "allow must write $FM_HOME/state/jev-tool-gate.jsonl"
  line=$(cat "$HOME_DIR/state/jev-tool-gate.jsonl")
  assert_contains "$line" '"event":"jev-tool-gate"' "log line is a tool-gate event"
  assert_contains "$line" '"mode":"shadow"' "log records shadow mode"
  assert_contains "$line" '"policy":"allow"' "log records the deterministic allow"
  assert_contains "$line" '"choice":"allow"' "log records the Jev choice"
  assert_contains "$line" 'echo hello' "log keeps the allowed command"
  assert_not_contains "$line" "$TS_KEY" "log must not contain the API key"
  pass "deterministic allow reaches fake Jev and the remainder log"
}

test_shadow_jev_deny_still_allows() {
  local code err line
  write_choice deny
  TYPESAFE_API_KEY=$TS_KEY FM_JEV_TOOL_GATE=shadow \
    run_gate code err 'echo hello'
  expect_code 0 "$code" "shadow Jev deny must not become a hard deny"
  [ -f "$LOG/called" ] || fail "shadow allow path must still call fake Jev"
  line=$(cat "$HOME_DIR/state/jev-tool-gate.jsonl")
  assert_contains "$line" '"choice":"deny"' "shadow logs the Jev deny"
  assert_contains "$line" '"applied":false' "shadow must not apply a Jev deny"
  pass "shadow mode logs a Jev deny and still allows"
}

test_live_without_both_files_stays_shadow() {
  local code err line
  write_choice deny
  rm -f "$HOME_DIR/config/jev-tool-gate-live" "$HOME_DIR/config/jev-tool-gate-live-ack"
  TYPESAFE_API_KEY=$TS_KEY FM_JEV_TOOL_GATE=live \
    run_gate code err 'echo hello'
  expect_code 0 "$code" "live env without both opt-in files stays shadow"
  line=$(cat "$HOME_DIR/state/jev-tool-gate.jsonl")
  assert_contains "$line" '"mode":"shadow"' "missing opt-in files keep shadow mode"
  assert_contains "$line" '"applied":false' "Jev deny is not applied without both files"
  pass "live env without both opt-in files stays shadow"
}

test_live_double_opt_in_applies_jev_deny() {
  local code err line
  write_choice deny
  mkdir -p "$HOME_DIR/config"
  : > "$HOME_DIR/config/jev-tool-gate-live"
  : > "$HOME_DIR/config/jev-tool-gate-live-ack"
  TYPESAFE_API_KEY=$TS_KEY FM_JEV_TOOL_GATE=live \
    run_gate code err 'echo hello'
  expect_code 2 "$code" "live remainder deny exits 2"
  assert_contains "$err" 'live remainder deny' "stderr names the live remainder deny"
  line=$(cat "$HOME_DIR/state/jev-tool-gate.jsonl")
  assert_contains "$line" '"mode":"live"' "log records live mode"
  assert_contains "$line" '"applied":true' "live Jev deny is applied"
  rm -f "$HOME_DIR/config/jev-tool-gate-live" "$HOME_DIR/config/jev-tool-gate-live-ack"
  pass "live mode with both opt-in files applies a Jev deny after allow"
}

test_live_still_cannot_override_deterministic_deny() {
  local code err
  write_choice allow
  mkdir -p "$HOME_DIR/config"
  : > "$HOME_DIR/config/jev-tool-gate-live"
  : > "$HOME_DIR/config/jev-tool-gate-live-ack"
  TYPESAFE_API_KEY=$TS_KEY FM_JEV_TOOL_GATE=live \
    run_gate code err 'pkill -f fm-watch'
  expect_code 2 "$code" "deterministic deny still exits 2 in live"
  assert_contains "$err" 'deterministic deny' "live cannot replace the deterministic deny"
  [ ! -e "$LOG/called" ] || fail "live mode must not send a deterministic deny to Jev"
  rm -f "$HOME_DIR/config/jev-tool-gate-live" "$HOME_DIR/config/jev-tool-gate-live-ack"
  pass "live mode cannot override or forward a deterministic deny"
}

test_help_mentions_do_not
test_deterministic_deny_never_reaches_jev
test_allow_reaches_log
test_shadow_jev_deny_still_allows
test_live_without_both_files_stays_shadow
test_live_double_opt_in_applies_jev_deny
test_live_still_cannot_override_deterministic_deny
