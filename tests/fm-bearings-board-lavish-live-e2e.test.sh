#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# liveness check is written against.
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
# End session button calls, so no browser is needed and nothing here depends on
# a human. The artifact is a scratch page in a temporary directory, and the
# session it opens is ended again before the guard returns. Queued-feedback
# coverage submits through the browser's prompts route and proves capture via
# the real runner, not a destructive conversational poll.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's logic
# in CI against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi jq curl

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
cleanup() {
  [ -z "$LAB" ] || {
    [ ! -f "$LAB/.lavish/bearings-board.html" ] \
      || lavish-axi end "$LAB/.lavish/bearings-board.html" >/dev/null 2>&1 || true
    fm_test_cleanup
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data"
fm_test_track_procevent_home "$LAB" "$LAB/procevent-claims"

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

run_source() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
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

# A missing receiver masks the defect until feedback has been submitted. Keep
# the synthetic session, retire only its listener, and queue three distinct
# prompts through the same route as Send to Agent. No real board is touched.
sid=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$BOARD")
run_source retire "$sid" >/dev/null || fail "cannot retire the synthetic listener"
jq -n '{prompts:[
  {uid:"1",tag:"choice",text:"Synthetic: yes",selector:"form",prompt:("Choose yes\n\nContext data:\n" + ({schema:"fm-bearings-answer.v1",question:"sample-live-guard-call",selection:"yes",note:""} | tojson))},
  {uid:"2",tag:"p",text:"Synthetic second",prompt:"Second comment: preserve (A), <tag>, & punctuation."},
  {uid:"3",tag:"message",prompt:"Third comment\nwith a second line."}
]}' > "$LAB/feedback.json"
queued=$(curl -fsS -H 'Content-Type: application/json' -H "Origin: $base" -X POST \
  --data-binary "@$LAB/feedback.json" "$base/api/$key/prompts") \
  || fail "cannot submit synthetic feedback"
printf '%s' "$queued" | jq -e '.pending_prompts == 3' >/dev/null \
  || fail "three synthetic comments were not queued: $queued"
lavish-axi 2>/dev/null | grep -F "$BOARD," | grep -q ',feedback,' \
  || fail "lavish-axi ${VERSION:-version-unknown} does not list queued feedback as expected"
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "queued feedback prevented the real board from listening: $out"
case "$out" in *"session: live"*) ;; *) fail "feedback did not keep the live session: $out" ;; esac
case "$out" in *"session: reopened"*) fail "feedback unnecessarily reopened the session" ;; esac
result="$LAB/state/procevent-inbox/$sid.1.result"
for _ in $(seq 1 200); do
  [ ! -s "$result" ] || break
  sleep 0.1
done
[ -s "$result" ] || fail "submitted feedback never reached durable capture"
readout=$("$ROOT/bin/fm-procevent-lavish.sh" read "$result")
assert_contains "$readout" 'complete: yes' 'captured feedback was incomplete'
assert_contains "$readout" 'presented_items: 3' 'not all three submitted prompts reached capture'
assert_contains "$readout" 'Second comment: preserve (A), <tag>, & punctuation.' 'annotation content was lost'
assert_contains "$readout" '| with a second line.' 'multiline message was lost'
answers=$("$ROOT/bin/fm-procevent-lavish.sh" answers "$result")
[ "$answers" = $'sample-live-guard-call\tyes\tSynthetic: yes' ] \
  || fail "synthetic answer identity changed: $answers"
[ "$(run_source list | awk -v id="$sid" '$1 == id {print $3}')" = live ] \
  || fail "feedback was captured but no receiver remains live"
# Rebuilding again must neither deliver the same feedback twice nor replace the
# source identity; handled remains an explicit, idempotent result acknowledgement.
run_board build "$LAB/payload.json" >/dev/null || fail "post-capture rebuild failed"
[ "$(find "$LAB/state/procevent-inbox" -name '*.result' | wc -l | tr -d ' ')" = 1 ] \
  || fail "the same feedback was captured twice"
[ "$(run_source handled "$sid" 1)" = "handled: $sid 1" ] || fail "first handled acknowledgement failed"
[ "$(run_source handled "$sid" 1)" = "already-handled: $sid 1" ] || fail "handled replay was not idempotent"
pass "lavish-axi ${VERSION:-version-unknown} preserves queued feedback through rebuild, captures all three prompts once, and keeps a live receiver"

# End it exactly as the browser's End session button does.
curl -fsS -H "Origin: $base" -X POST "$base/api/$key/end" >/dev/null 2>&1 \
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
