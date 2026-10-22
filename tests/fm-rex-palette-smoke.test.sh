#!/usr/bin/env bash
# tests/fm-rex-palette-smoke.test.sh - token-free real-binary guard for
# Firstmate's Rex command palette (bin/fm-rex-palette.sh,
# bin/backends/rex-palette.lua, bin/fm-rex-popup.sh). It provisions a private
# headless Rex server through bin/fm-rex-lab.sh (never the live server; the
# lab's tripwire checks the live server is untouched), installs the palette
# into that lab server's own config file next to a stand-in for the captain's
# lines, and drives the actions with `rex do`: a popup that shows the focused
# worker and closes on Enter, an answer typed into a popup landing in the
# captain inbox, goto's selection, the away pane shown and hidden, a broken
# module surfacing as a palette error, and a byte-identical uninstall.
# Runs by default where rex and jq are installed; FM_REX_PALETTE_SMOKE=0
# disables it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_REX_PALETTE_SMOKE rex jq

unset TMUX HERDR_ENV REX_SESSION REX_BLOCK REX_SERVER REX_CLIENT FM_BACKEND_REX_SERVER 2>/dev/null || true

LAB_HELPER="$ROOT/bin/fm-rex-lab.sh"
LAB=$("$LAB_HELPER" name palette)
TMP_ROOT=$(fm_test_tmproot fm-rex-palette-smoke)
REX_VERSION=$(rex version 2>/dev/null | head -1)

cleanup() {
  "$LAB_HELPER" teardown "$LAB" || printf 'not ok - the Rex lab teardown or its live-server tripwire failed\n' >&2
}
trap cleanup EXIT

smoke_fail() { fail "$1 ($REX_VERSION)"; }
L() { "$LAB_HELPER" run "$LAB" "$@"; }

"$LAB_HELPER" provision "$LAB" || smoke_fail "could not provision a private Rex lab server"
FM_REX_SERVER=$("$LAB_HELPER" server "$LAB")
export FM_REX_SERVER
export FM_HOME="$TMP_ROOT/home"
STATE="$FM_HOME/state"
mkdir -p "$STATE" "$FM_HOME/data" "$FM_HOME/config"

CFG=$(L keymap --json | jq -r '.config.path') || smoke_fail "the lab server reported no config path"
printf -- '-- captain\nrex.action{ name = "captain_scratch", title = "Captain Scratch", run = function() return { mine = true } end }\n' >"$CFG"
cp "$CFG" "$TMP_ROOT/orig.lua"

OUT=$(L new fm-local -c /tmp --window "Ship · demo" --keep-open --json) || smoke_fail "could not open the lab session"
SID=$(printf '%s' "$OUT" | jq -r .session_id)
BID=$(printf '%s' "$OUT" | jq -r '.initial_windows[0].block_ids[0]')
WID=$(printf '%s' "$OUT" | jq -r '.initial_windows[0].window_id')
printf 'window=%s:%s\nbackend=rex\nkind=ship\nproject=demo\nrex_server=%s\nrex_session_id=%s\nrex_window_id=%s\nrex_block_id=%s\n' \
  "${SID#session:}" "${BID#block:}" "$FM_REX_SERVER" "${SID#session:}" "${WID#window:}" "${BID#block:}" >"$STATE/demo.meta"
printf 'needs-decision [at=%s] [key=pick-db]: Postgres (A) or SQLite (B)?\n' "$(date +%s)" >"$STATE/demo.status"

"$ROOT/bin/fm-rex-palette.sh" install >/dev/null || smoke_fail "install into the lab config failed"
ACTIONS=$(L actions --json | jq -r '[.actions[].name] | join(" ")')
for a in fm_fleet fm_this fm_peek fm_goto fm_away fm_answer fm_note fm_merge captain_scratch; do
  assert_contains "$ACTIONS" "$a" "the lab server lists $a after install"
done
assert_equals '{"mine":true}' "$(L "do" captain_scratch --json | jq -c .)" "the captain's own action still runs"
assert_equals "" "$(L keymap --json | jq -r '[.bindings[]? | select(.action | startswith("fm_"))] | .[].key')" "the palette binds no key"
pass "rex palette smoke: install loads every Firstmate action beside the captain's own, with no key bound"

popup() { # newest floating block in the lab session
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

L "do" -s "$SID" -b "$BID" fm_this --json >/dev/null || smoke_fail "fm_this failed on the worker pane"
P=$(popup)
[ -n "$P" ] || smoke_fail "fm_this opened no popup"
wait_text "$P" "Decision:  [pick-db]" || smoke_fail "the This Worker popup did not show the open decision"
L send-key -s "$SID" -b "$P" Enter >/dev/null || smoke_fail "could not press Enter in the popup"
for _ in $(seq 1 50); do [ "$(floating)" = 0 ] && break; sleep 0.1; done
assert_equals 0 "$(floating)" "the popup closes itself when its body ends"
pass "rex palette smoke: This Worker opens a popup over the worker that closes on Enter"

L "do" -s "$SID" -b "$BID" fm_answer --json >/dev/null || smoke_fail "fm_answer failed"
P=$(popup)
wait_text "$P" "Answer which" || smoke_fail "the answer popup did not list the decision"
printf '1\n' | L send -s "$SID" -b "$P" >/dev/null
wait_text "$P" "Your answer for demo" || smoke_fail "the answer popup did not ask for the answer"
printf 'B, SQLite is fine\n' | L send -s "$SID" -b "$P" >/dev/null
wait_text "$P" "Filed for Firstmate" || smoke_fail "the answer popup did not file the note"
assert_contains "$(cat "$STATE"/inbox/*.note)" "Answer for demo [key=pick-db]: B, SQLite is fine" "the typed answer lands in the captain inbox"
L send-key -s "$SID" -b "$P" Enter >/dev/null
pass "rex palette smoke: an answer typed into the popup lands in the captain inbox"

OUT=$(L "do" -s "$SID" -b "$BID" fm_goto --json) || smoke_fail "fm_goto failed"
assert_equals "demo $WID" "$(printf '%s' "$OUT" | jq -r '"\(.task) \(.select.window_id)"')" "goto selects the waiting worker's tab"
assert_equals null "$(printf '%s' "$OUT" | jq -c '.selected // null')" "a CLI run never queues a view change"
pass "rex palette smoke: goto selects the waiting worker's tab"

# The away pane: a detached block recorded as the away daemon's terminal.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source rex || smoke_fail "could not source the rex adapter"
AWAY=$(FM_BACKEND_REX_SERVER=$FM_REX_SERVER fm_backend_rex_detached_create "$SID" fm-afk-daemon-smoke /tmp $'echo away daemon\n') \
  || smoke_fail "could not create a detached block"
printf 'rex\t%s\t%s\n' "$AWAY" "$FM_REX_SERVER" >"$STATE/.afk-daemon-terminal"
placement() { L block inspect "block:${AWAY#*:}" --json | jq -r '.block.placement'; }
assert_equals detached "$(placement)" "the away pane starts hidden"
L "do" -s "$SID" -b "$BID" fm_away --json >/dev/null || smoke_fail "fm_away (show) failed"
assert_equals placed "$(placement)" "fm_away shows the hidden away pane"
L "do" -s "$SID" -b "$BID" fm_away --json >/dev/null || smoke_fail "fm_away (hide) failed"
assert_equals detached "$(placement)" "fm_away hides it again"
wait_text "block:${AWAY#*:}" "away daemon" || smoke_fail "the away pane stopped running while hidden"
pass "rex palette smoke: the away pane is shown and hidden without stopping it"

# A broken module surfaces as a palette error; the captain's config still loads.
BROKEN="$TMP_ROOT/broken-root"
mkdir -p "$BROKEN/bin/backends"
printf 'this is not lua\n' >"$BROKEN/bin/backends/rex-palette.lua"
FM_ROOT_OVERRIDE=$BROKEN "$ROOT/bin/fm-rex-palette.sh" install >/dev/null || smoke_fail "install with a broken module failed"
ACTIONS=$(L actions --json | jq -r '[.actions[].name] | join(" ")')
assert_contains "$ACTIONS" "fm_load_error" "a broken module shows the load-error entry"
assert_contains "$ACTIONS" "captain_scratch" "the captain's action survives a broken module"
OUT=$(L "do" fm_load_error 2>&1) && smoke_fail "fm_load_error succeeded"
assert_contains "$OUT" "Firstmate palette not loaded" "the load-error entry says why"
pass "rex palette smoke: a broken module becomes a palette error and the captain's config still loads"

"$ROOT/bin/fm-rex-palette.sh" uninstall >/dev/null || smoke_fail "uninstall failed"
cmp -s "$CFG" "$TMP_ROOT/orig.lua" || smoke_fail "uninstall did not restore the captain's config byte for byte"
assert_equals "" "$(L actions --json | jq -r '[.actions[].name | select(startswith("fm_"))] | join(" ")')" "uninstall unloads every Firstmate action"
pass "rex palette smoke: uninstall restores the config byte for byte and unloads the actions"
