#!/usr/bin/env bash
# Behavioral contract for the isolated Lavish board launcher and its one-shot
# submit-marker check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOARD="$ROOT/bin/fm-lavish-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-board-tests)
HOME_PATH="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
LOG="$TMP_ROOT/calls.log"
DOWNLOADS_PATH="$TMP_ROOT/Downloads"
mkdir -p "$HOME_PATH/data/decisions/example" "$HOME_PATH/state" "$FAKEBIN" \
  "$DOWNLOADS_PATH"

cat > "$FAKEBIN/lavish" <<'SH'
#!/usr/bin/env bash
printf 'lavish:%s\n' "$*" >> "$FM_TEST_LOG"
[ "${1:-}" = board ] || exit 2
shift 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) shift 2 ;;
    --out) output=$2; shift 2 ;;
    *) exit 2 ;;
  esac
done
printf '<!doctype html><title>Lavish board</title>\n' > "$output"
SH

cat > "$FAKEBIN/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
printf 'chrome:%s session=%s headed=%s auto=%s browser=%s profile=%s args=%s port=%s headers=%s\n' \
  "$*" "${CHROME_DEVTOOLS_AXI_SESSION:-}" "${CHROME_DEVTOOLS_AXI_HEADED:-}" \
  "${CHROME_DEVTOOLS_AXI_AUTO_CONNECT-unset}" \
  "${CHROME_DEVTOOLS_AXI_BROWSER_URL-unset}" \
  "${CHROME_DEVTOOLS_AXI_USER_DATA_DIR-unset}" \
  "${CHROME_DEVTOOLS_AXI_CHROME_ARGS-unset}" \
  "${CHROME_DEVTOOLS_AXI_PORT-unset}" \
  "${CHROME_DEVTOOLS_AXI_WS_HEADERS-unset}" >> "$FM_TEST_LOG"
case "${1:-}" in
  open|stop) exit 0 ;;
  eval)
    [ "${FM_TEST_PAGE_CLOSED:-0}" != 1 ] || exit 1
    FAKE_MARKER=${FM_TEST_MARKER:-absent} node -e '
      const present = process.env.FAKE_MARKER === "present";
      const snapshot = present
        ? {
            title: "LAVISH-SUBMIT v2",
            payload: {
              schema_version: 2,
              decision_id: "example",
              request_sha256: `sha256:${"a".repeat(64)}`,
              answers: [{
                key: "choice",
                value: "a",
                question_note: "whole question",
                option_comments: { a: "this option" },
              }],
              note: "complete batch",
            },
          }
        : { title: "Lavish - Example", payload: null };
      console.log(`result: ${JSON.stringify(JSON.stringify(JSON.stringify(snapshot)))}`);
    '
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$FAKEBIN/lavish" "$FAKEBIN/chrome-devtools-axi"

run_board() {
  env -u FM_HOME \
    FM_TEST_LOG="$LOG" \
    CHROME_DEVTOOLS_AXI_AUTO_CONNECT=1 \
    CHROME_DEVTOOLS_AXI_BROWSER_URL=http://captain-main.invalid \
    CHROME_DEVTOOLS_AXI_CHROME_ARGS=--user-data-dir=/captain/main/profile \
    CHROME_DEVTOOLS_AXI_PORT=9222 \
    CHROME_DEVTOOLS_AXI_USER_DATA_DIR=/captain/main/profile \
    CHROME_DEVTOOLS_AXI_WS_HEADERS=secret \
    FM_LAVISH_BIN="$FAKEBIN/lavish" \
    PATH="$FAKEBIN:$PATH" \
    "$BOARD" example --home "$HOME_PATH" --downloads "$DOWNLOADS_PATH"
}

test_launcher_isolates_chrome_and_arms_check() {
  local output check
  output=$(run_board) || fail "board launcher failed: $output"
  check="$HOME_PATH/state/lavish-board-example.check.sh"
  assert_contains "$output" 'Opened Lavish board example in isolated Chrome session' \
    "launcher did not report the isolated browser"
  assert_contains "$output" "Armed submission check: $check" \
    "launcher did not report the check path"
  assert_present "$check" "launcher did not create the check script"
  [ -x "$check" ] || fail "launcher check script is not executable"
  assert_grep "lavish:board example --home $HOME_PATH --out $HOME_PATH/state/lavish-board-example.html" \
    "$LOG" "launcher did not pass an explicit home to lavish"
  assert_grep 'headed=1 auto=unset browser=unset profile=unset args=unset port=unset headers=unset' "$LOG" \
    "launcher inherited a captain Chrome connection or profile"
  pass "fm-lavish-board opens a headed named session with an isolated throwaway profile"
}

test_download_survives_closed_page_and_precedes_live_read() {
  local check downloaded durable output lines
  check="$HOME_PATH/state/lavish-board-example.check.sh"
  downloaded="$DOWNLOADS_PATH/lavish-answer-example.json"
  durable="$HOME_PATH/state/lavish-board-example.payload.json"
  printf '%s\n' '{"schema_version":2,"decision_id":"example","request_sha256":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","answers":[{"key":"choice","value":"a","question_note":"survives close","option_comments":{"a":"download first"}}],"note":"closed-page proof"}' > "$downloaded"
  : > "$LOG"

  output=$(
    FM_TEST_PAGE_CLOSED=1 FM_TEST_LOG="$LOG" PATH="$FAKEBIN:$PATH" "$check"
  ) || fail "download-first closed-page check failed"
  lines=$(printf '%s\n' "$output" | awk 'NF { count++ } END { print count + 0 }')
  [ "$lines" -eq 1 ] || fail "download-first check printed $lines lines"
  [ "$output" = "lavish-submit: example $durable" ] \
    || fail "download-first check printed the wrong wake line: $output"
  assert_absent "$check" "download-first check did not disarm itself"
  assert_present "$durable" "download-first check did not persist the payload"
  assert_no_grep 'chrome:eval' "$LOG" \
    "download-first check tried to read the already closed page"
  node -e '
    const fs = require("node:fs");
    const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (payload.answers[0].question_note !== "survives close") process.exit(1);
    if (payload.answers[0].option_comments.a !== "download first") process.exit(1);
    if (payload.note !== "closed-page proof") process.exit(1);
  ' "$durable" || fail "downloaded payload was not recovered intact after page close"
  rm -f "$downloaded" "$durable"
  pass "Lavish board download remains recoverable after the page closes"
}

test_check_is_silent_until_marker_then_prints_once() {
  local check absent present payload lines
  run_board >/dev/null || fail "could not rearm live-page fallback check"
  check="$HOME_PATH/state/lavish-board-example.check.sh"
  absent=$(
    FM_TEST_MARKER=absent FM_TEST_LOG="$LOG" PATH="$FAKEBIN:$PATH" "$check"
  ) || fail "absent-marker check failed"
  [ -z "$absent" ] || fail "absent-marker check printed output: $absent"
  assert_present "$check" "absent-marker check disarmed itself"

  present=$(
    FM_TEST_MARKER=present FM_TEST_LOG="$LOG" PATH="$FAKEBIN:$PATH" "$check"
  ) || fail "present-marker check failed"
  lines=$(printf '%s\n' "$present" | awk 'NF { count++ } END { print count + 0 }')
  [ "$lines" -eq 1 ] || fail "present-marker check printed $lines lines"
  payload="$HOME_PATH/state/lavish-board-example.payload.json"
  [ "$present" = "lavish-submit: example $payload" ] \
    || fail "present-marker check printed the wrong wake line: $present"
  assert_absent "$check" "present-marker check did not disarm itself"
  assert_present "$payload" "present-marker check did not save the browser payload"
  node -e '
    const fs = require("node:fs");
    const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (payload.answers[0].question_note !== "whole question") process.exit(1);
    if (payload.answers[0].option_comments.a !== "this option") process.exit(1);
  ' "$payload" || fail "captured payload lost structured annotations"
  pass "Lavish board check stays silent without the marker and emits one durable wake line with it"
}

test_launcher_isolates_chrome_and_arms_check
test_download_survives_closed_page_and_precedes_live_read
test_check_is_silent_until_marker_then_prints_once
