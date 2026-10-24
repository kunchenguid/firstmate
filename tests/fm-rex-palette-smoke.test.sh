#!/usr/bin/env bash
# tests/fm-rex-palette-smoke.test.sh - token-free real-Rex guard for
# Firstmate's Rex command palette (bin/fm-rex-palette.sh,
# bin/backends/rex-palette.lua, bin/fm-rex-popup.sh). On
# tests/rex-test-safety.sh's private server it installs the palette into that
# server's own config file next to a stand-in for the captain's lines, and
# drives the actions with `rex do`: a popup that shows the focused worker and
# closes on Enter, an answer typed into a popup landing in the captain inbox,
# goto's selection, a broken module surfacing as a palette error, and a
# byte-identical uninstall. Only a plain shell and the popup bodies run.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  rex_test_cleanup
  exit 1
}
pass() { printf 'ok - %s\n' "$1"; }
assert_equals() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (missing: '$2')" ;; esac; }

# shellcheck source=tests/rex-test-safety.sh
. "$ROOT/tests/rex-test-safety.sh"
trap rex_test_cleanup EXIT
rex_test_prepare || { rc=$?; [ "$rc" = 1 ] && exit 0; exit "$rc"; }

L() { fm_backend_rex_cli "$@"; }
export FM_HOME="$REX_TEST_WORK/home"
STATE="$FM_HOME/state"
mkdir -p "$STATE" "$FM_HOME/data" "$FM_HOME/config"

CFG=$(L keymap --json | jq -r '.config.path') || fail "the private server reported no config path"
printf -- '-- captain\nrex.action{ name = "captain_scratch", title = "Captain Scratch", run = function() return { mine = true } end }\n' >"$CFG"
cp "$CFG" "$REX_TEST_WORK/orig.lua"

PAIR=$(rex_test_new_session palette) || fail "could not create the test's own fm-test- session"
read -r SID BID <<<"$PAIR"
WID=$(L api call -s "$SID" session.view | jq -r '.windows[0].window_id')
printf 'window=%s:%s\nbackend=rex\nkind=ship\nproject=demo\nrex_server=%s\nrex_session_id=%s\nrex_window_id=%s\nrex_block_id=%s\n' \
  "${SID#session:}" "${BID#block:}" "$REX_TEST_ENDPOINT" "$SID" "$WID" "$BID" >"$STATE/demo.meta"
printf 'needs-decision [at=%s] [key=pick-db]: Postgres (A) or SQLite (B)?\n' "$(date +%s)" >"$STATE/demo.status"

"$ROOT/bin/fm-rex-palette.sh" install --server "$REX_TEST_ENDPOINT" >/dev/null || fail "install into the private server's config failed"
ACTIONS=$(L actions --json | jq -r '[.actions[].name] | join(" ")')
for a in fm_fleet fm_this fm_peek fm_goto fm_answer fm_note fm_merge captain_scratch; do
  assert_contains "$ACTIONS" "$a" "the server lists $a after install"
done
assert_equals '{"mine":true}' "$(L "do" -s "$SID" captain_scratch --json | jq -c .)" "the captain's own action still runs"
assert_equals "" "$(L keymap --json | jq -r '[.bindings[]? | select(.action | startswith("fm_"))] | .[].key')" "the palette binds no key"
pass "real rex: palette install loads every Firstmate action beside the captain's own, with no key bound"

popup() { # newest floating block in the test session
  L session inspect "$SID" --json | jq -r '[.windows[].layers[] | select(.kind == "floating") | .blocks[].block_id] | last // empty'
}
floating() {
  L session inspect "$SID" --json | jq '[.windows[].layers[] | select(.kind == "floating")] | length'
}
wait_text() { # <block> <needle>
  local _
  for _ in $(seq 1 50); do
    L capture -s "$SID" -b "$1" --trim 2>/dev/null | grep -qF -- "$2" && return 0
    sleep 0.1
  done
  return 1
}

L "do" -s "$SID" -b "$BID" fm_this --json >/dev/null || fail "fm_this failed on the worker pane"
P=$(popup)
[ -n "$P" ] || fail "fm_this opened no popup"
wait_text "$P" "Decision:  [pick-db]" || fail "the This Worker popup did not show the open decision"
L send-key -s "$SID" -b "$P" Enter >/dev/null || fail "could not press Enter in the popup"
for _ in $(seq 1 50); do [ "$(floating)" = 0 ] && break; sleep 0.1; done
assert_equals 0 "$(floating)" "the popup closes itself when its body ends"
pass "real rex: This Worker opens a popup over the worker that closes on Enter"

L "do" -s "$SID" -b "$BID" fm_answer --json >/dev/null || fail "fm_answer failed"
P=$(popup)
wait_text "$P" "Answer which" || fail "the answer popup did not list the decision"
printf '1\n' | L send -s "$SID" -b "$P" >/dev/null
wait_text "$P" "Your answer for demo" || fail "the answer popup did not ask for the answer"
printf 'B, SQLite is fine\n' | L send -s "$SID" -b "$P" >/dev/null
wait_text "$P" "Filed for Firstmate" || fail "the answer popup did not file the note"
assert_contains "$(cat "$STATE"/inbox/*.note)" "Answer for demo [key=pick-db]: B, SQLite is fine" "the typed answer lands in the captain inbox"
L send-key -s "$SID" -b "$P" Enter >/dev/null
pass "real rex: an answer typed into the popup lands in the captain inbox"

OUT=$(L "do" -s "$SID" -b "$BID" fm_goto --json) || fail "fm_goto failed"
assert_equals "demo $WID" "$(printf '%s' "$OUT" | jq -r '"\(.task) \(.select.window_id)"')" "goto selects the waiting worker's tab"
assert_equals null "$(printf '%s' "$OUT" | jq -c '.selected // null')" "a CLI run never queues a view change"
pass "real rex: goto selects the waiting worker's tab"

# A broken module surfaces as a palette error; the captain's config still loads.
BROKEN="$REX_TEST_WORK/broken-root"
mkdir -p "$BROKEN/bin/backends"
printf 'this is not lua\n' >"$BROKEN/bin/backends/rex-palette.lua"
FM_ROOT_OVERRIDE=$BROKEN "$ROOT/bin/fm-rex-palette.sh" install --server "$REX_TEST_ENDPOINT" >/dev/null || fail "install with a broken module failed"
ACTIONS=$(L actions --json | jq -r '[.actions[].name] | join(" ")')
assert_contains "$ACTIONS" "fm_load_error" "a broken module shows the load-error entry"
assert_contains "$ACTIONS" "captain_scratch" "the captain's action survives a broken module"
OUT=$(L "do" -s "$SID" fm_load_error 2>&1) && fail "fm_load_error succeeded"
assert_contains "$OUT" "Firstmate palette not loaded" "the load-error entry says why"
pass "real rex: a broken module becomes a palette error and the captain's config still loads"

"$ROOT/bin/fm-rex-palette.sh" uninstall --server "$REX_TEST_ENDPOINT" >/dev/null || fail "uninstall failed"
cmp -s "$CFG" "$REX_TEST_WORK/orig.lua" || fail "uninstall did not restore the captain's config byte for byte"
assert_equals "" "$(L actions --json | jq -r '[.actions[].name | select(startswith("fm_"))] | join(" ")')" "uninstall unloads every Firstmate action"
pass "real rex: uninstall restores the config byte for byte and unloads the actions"

rex_test_assert_isolated
