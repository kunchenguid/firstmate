#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# liveness and prompt-queue checks are written against.
#
# Why this file exists: the build's "is this board actually live" verdict comes
# from what lavish-axi emits, which is a surface the vendor controls and changes
# without notice. The defect this guards was exactly that - opening a session
# the captain had ended from the browser EXITS 0 while refusing to reopen, so a
# build that trusted the exit status armed a poll against a dead session and the
# board read "not listening" with nobody watching it. A stubbed lavish-axi can
# only confirm the assumption already written into the stub, so the assumption
# itself needs a run against the real tool.
#
# The captain-ended state is reached through the same server route the browser's
# End session button calls. A real browser then queues the board's explicit and
# freeform controls in both orders and sends them through the live session. The
# artifact is a scratch page in a temporary directory, and the session it opens
# is ended again before the guard returns.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's logic
# in CI against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi chrome-devtools-axi jq curl

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
BROWSER_PID=''
BROWSER_URL=''
BROWSER_SESSION="fm-bearings-live-$$"
browser_axi() {
  if [ -n "$BROWSER_URL" ]; then
    CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" \
      CHROME_DEVTOOLS_AXI_BROWSER_URL="$BROWSER_URL" chrome-devtools-axi "$@"
  else
    CHROME_DEVTOOLS_AXI_SESSION="$BROWSER_SESSION" chrome-devtools-axi "$@"
  fi
}
cleanup() {
  browser_axi stop >/dev/null 2>&1 || true
  if [ -n "$BROWSER_PID" ]; then
    kill "$BROWSER_PID" >/dev/null 2>&1 || true
    wait "$BROWSER_PID" >/dev/null 2>&1 || true
  fi
  [ -z "$LAB" ] || {
    for board in "$LAB"/.lavish/*.html; do
      [ ! -f "$board" ] || lavish-axi end "$board" >/dev/null 2>&1 || true
    done
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
BROWSER_VERSION=$(chrome-devtools-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"
note "chrome-devtools-axi ${BROWSER_VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data"

if [ "$(uname -s)" = Linux ]; then
  BROWSER_BIN=''
  for candidate in chromium chromium-browser google-chrome google-chrome-stable; do
    if command -v "$candidate" >/dev/null 2>&1; then
      BROWSER_BIN=$(command -v "$candidate")
      break
    fi
  done
  [ -n "$BROWSER_BIN" ] || fail "the live queue guard needs Chrome or Chromium"
  profile="$LAB/chrome-profile"
  mkdir -p "$profile"
  "$BROWSER_BIN" --headless=new --no-first-run --no-default-browser-check \
    --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 \
    --user-data-dir="$profile" about:blank >"$LAB/chrome.log" 2>&1 &
  BROWSER_PID=$!
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    [ -s "$profile/DevToolsActivePort" ] && break
    kill -0 "$BROWSER_PID" 2>/dev/null || fail "Chrome exited before exposing DevTools"
    sleep 0.05
    attempt=$((attempt + 1))
  done
  [ -s "$profile/DevToolsActivePort" ] \
    || fail "Chrome did not expose DevTools for the live queue guard"
  BROWSER_URL="http://127.0.0.1:$(head -1 "$profile/DevToolsActivePort")"
fi

cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "lavish-live-guard",
  "generated": "2026-01-01T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-live-guard-call",
      "type": "decision",
      "repo": "sample",
      "title": "Guard placeholder",
      "options": [{ "value": "yes", "label": "Yes" }]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON

run_board() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" "$@"
}

BOARD="$LAB/.lavish/bearings-board.html"
run_board build "$LAB/payload.json" >/dev/null 2>&1 || fail "the guard board did not build"
[ -f "$BOARD" ] || fail "the guard board was not published"

url=$(lavish-axi "$BOARD" | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
case "$url" in
  http://*/session/*) ;;
  *) fail "could not read the guard board session url: $url" ;;
esac
key=${url##*/}
base=${url%/session/*}

# End it exactly as the browser's End session button does.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain"

# ASSUMPTION UNDER GUARD: this exits 0 while reporting the session is not live.
set +e
ended_out=$(lavish-axi "$BOARD" 2>&1)
ended_rc=$?
set -e
[ "$ended_rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown} now exits $ended_rc on a captain-ended session; the board build's liveness check must be revisited"
ended_status=$(printf '%s\n' "$ended_out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
[ "$ended_status" != opened ] \
  || fail "lavish-axi ${VERSION:-version-unknown} silently reopened a captain-ended session; the board build's liveness check must be revisited"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  && fail "lavish-axi ${VERSION:-version-unknown} still lists a captain-ended session as open; the board build's liveness check must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session without reopening it and without failing"

# THE BEHAVIOR UNDER GUARD: the build must not accept that, and must recover.
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "the board build refused a recoverable captain-ended session: $out"
case "$out" in
  *"session: reopened"*) ;;
  *) fail "the board build did not reopen the captain-ended session: $out" ;;
esac
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',open,' \
  || fail "the board build reported success while the session was still not live"
pass "the board build reopens a captain-ended session against real lavish-axi instead of arming a dead one"

queue_controls() {  # <choice-first|freeform-first> <session-url>
  local order=$1 session_url=$2 browser_out
  browser_out=$(browser_axi run <<JS
console.log("opening live board");
await page.open("$session_url?no-gate=1&queue-order=$order");
console.log("waiting for live board");
await new Promise((resolve) => setTimeout(resolve, 500));
const order = "$order";
const refFor = (snapshot, role, name) => {
  const line = snapshot.split("\\n").find((entry) => entry.includes(role) && entry.includes(name));
  const match = line && line.match(/uid=([^ ]+)/);
  if (!match) throw new Error("missing " + role + " named " + name + " in:\\n" + snapshot);
  return "@" + match[1];
};
console.log("snapshotting live board");
let initial = await page.snapshot();
if (initial.includes('button "Take over here"')) {
  await page.click(refFor(initial, "button", '"Take over here"'));
  await new Promise((resolve) => setTimeout(resolve, 100));
}
const choose = async () => {
  let snapshot = await page.snapshot();
  console.log("choosing explicit answer");
  await page.click(refFor(snapshot, "radio", '"Yes"'));
  snapshot = await page.snapshot();
  console.log("queueing explicit answer");
  await page.click(refFor(snapshot, "button", '"Queue answer"'));
  await new Promise((resolve) => setTimeout(resolve, 100));
};
const followUp = async () => {
  let snapshot = await page.snapshot();
  console.log("filling freeform follow-up");
  await page.fill(refFor(snapshot, "textbox", '"Ask a question or give another instruction"'), "Need the live queue details");
  snapshot = await page.snapshot();
  console.log("queueing freeform follow-up");
  await page.click(refFor(snapshot, "button", '"Send to Firstmate"'));
  await new Promise((resolve) => setTimeout(resolve, 100));
};
if (order === "choice-first") {
  await choose();
  await followUp();
} else {
  await followUp();
  await choose();
}
let snapshot = await page.snapshot();
if (!snapshot.includes('button "Send to Agent"')) {
  await page.click(refFor(snapshot, "button", '"Show conversation"'));
  await new Promise((resolve) => setTimeout(resolve, 100));
  snapshot = await page.snapshot();
}
console.log("sending queued controls");
await page.click(refFor(snapshot, "button", '"Send to Agent"'));
await new Promise((resolve) => setTimeout(resolve, 500));
JS
) || {
    printf '%s\n' "$browser_out" >&2
    return 1
  }
}

assert_control_result() {  # <choice-first|freeform-first>
  local order=$1 result="$LAB/$1.result" out board session_out session_url
  board="$LAB/.lavish/bearings-board-$order.html"
  cp "$BOARD" "$board" || fail "could not stage the $order live board"
  session_out=$(lavish-axi "$board" --no-open --no-gate) \
    || fail "could not open the $order live board"
  session_url=$(printf '%s\n' "$session_out" \
    | sed -n 's/^[[:space:]]*url:[[:space:]]*//p' | head -1 | tr -d '"')
  case "$session_url" in
    http://*/session/*) ;;
    *) fail "could not read the $order live board session url: $session_url" ;;
  esac
  queue_controls "$order" "$session_url" \
    || fail "the real browser could not queue controls in $order order"
  fm_run_timed 15 lavish-axi poll "$board" > "$result" \
    || fail "lavish-axi did not return the $order queued controls"
  out=$("$ROOT/bin/fm-procevent-lavish.sh" answers "$result") \
    || fail "the adapter could not read the $order explicit choice"
  [ "$out" = "$(printf 'sample-live-guard-call\tyes\tGuard placeholder -> yes')" ] \
    || fail "the $order explicit choice was replaced or changed: $out"
  out=$("$ROOT/bin/fm-procevent-lavish.sh" read "$result") \
    || fail "the adapter could not present the $order live result"
  case "$out" in
    *"Need the live queue details"*) ;;
    *) fail "the $order freeform follow-up was replaced or changed: $out" ;;
  esac
}

assert_control_result choice-first
assert_control_result freeform-first
pass "real lavish-axi preserves explicit choices and freeform follow-ups in both queue orders"
