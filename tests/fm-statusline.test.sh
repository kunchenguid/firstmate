#!/usr/bin/env bash
# Behavior tests for the read-only Claude Code status-line fleet readout.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SL="$ROOT/bin/fm-statusline.sh"
TMP_ROOT=$(fm_test_tmproot fm-statusline)

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_sl() {  # <home> [extra-env...]
  local home=$1
  shift
  env NO_COLOR=1 "$@" FM_HOME="$home" "$SL" </dev/null
}

# --- zero tasks and absent state never error ---------------------------------

home=$(make_home empty)
out=$(run_sl "$home"); code=$?
expect_code 0 "$code" "empty state dir exits 0"
assert_contains "$out" "fleet idle" "empty state dir reports fleet idle"

out=$(env NO_COLOR=1 FM_HOME="$TMP_ROOT/does-not-exist" "$SL" </dev/null); code=$?
expect_code 0 "$code" "absent state dir exits 0"
assert_contains "$out" "fleet idle" "absent state dir reports fleet idle"
pass "zero tasks and absent state degrade to fleet idle"

# --- working task renders id, note, and count --------------------------------

home=$(make_home working)
fm_write_meta "$home/state/fm-alpha.meta" "window=w:fm-alpha" "kind=ship"
printf 'working: adding regression tests\n' > "$home/state/fm-alpha.status"
out=$(run_sl "$home")
assert_contains "$out" "1 crew" "working task counted"
assert_contains "$out" "alpha" "task id shown"
assert_not_contains "$out" "fm-alpha" "fm- prefix stripped from id"
assert_contains "$out" "adding regression tests" "doing note shown"
assert_not_contains "$out" "needs you" "healthy task never flagged"
pass "working task renders quietly with stripped id and note"

# --- needs-decision pops and survives a later unrelated event ----------------

home=$(make_home decision)
fm_write_meta "$home/state/beta.meta" "window=w:fm-beta" "kind=ship"
printf 'needs-decision: pick API shape\nworking: still poking\n' > "$home/state/beta.status"
out=$(run_sl "$home")
assert_contains "$out" "1 needs you" "open decision counted in summary"
assert_contains "$out" "beta needs you: pick API shape" "open decision not masked by later working event"
pass "keyed open decision survives a later unrelated event"

# --- resolved closes the decision --------------------------------------------

printf 'resolved: captain chose v2\nworking: implementing\n' >> "$home/state/beta.status"
out=$(run_sl "$home")
assert_not_contains "$out" "needs you" "resolved decision no longer flagged"
assert_contains "$out" "implementing" "task back to quiet working note"
pass "resolved closes the open decision"

# --- blocked, failed, done, paused classes -----------------------------------

home=$(make_home classes)
fm_write_meta "$home/state/blk.meta" "window=w" "kind=ship"
printf 'blocked: missing credential\n' > "$home/state/blk.status"
fm_write_meta "$home/state/fail.meta" "window=w" "kind=ship"
printf 'failed: build broke\n' > "$home/state/fail.status"
fm_write_meta "$home/state/fin.meta" "window=w" "kind=ship"
printf 'done: PR https://example.invalid/pull/7\n' > "$home/state/fin.status"
fm_write_meta "$home/state/wait.meta" "window=w" "kind=ship"
printf 'paused: upstream release expected tomorrow\n' > "$home/state/wait.status"
out=$(run_sl "$home")
assert_contains "$out" "4 crew" "all four tasks counted"
assert_contains "$out" "2 needs you" "blocked and failed both need the captain"
assert_contains "$out" "blk blocked: missing credential" "blocked segment"
assert_contains "$out" "fail failed: build broke" "failed segment"
assert_contains "$out" "fin done:" "done segment"
assert_contains "$out" "wait waiting: upstream release" "paused segment"
pass "blocked/failed/done/paused classify correctly"

# --- needs-attention segments sort first -------------------------------------

case "$out" in
  *"blk blocked"*"fin done"*) : ;;
  *) fail "needs-attention segments must sort before done segments" ;;
esac
pass "needs-attention segments sort first"

# --- sanitization and truncation ---------------------------------------------

home=$(make_home hostile)
fm_write_meta "$home/state/evil.meta" "window=w" "kind=ship"
printf 'working: \033[31mred\033[0m\ttext\rand a very long note that keeps going well past the display budget for one task\n' \
  > "$home/state/evil.status"
out=$(run_sl "$home")
case "$out" in
  *$'\033'*) fail "NO_COLOR output must contain no escape bytes" ;;
esac
case "$out" in
  *$'\t'*|*$'\r'*) fail "sanitized note must contain no tab or carriage return" ;;
esac
assert_contains "$out" "red" "sanitized note keeps printable text"
assert_contains "$out" "…" "over-budget note hard-truncated"
assert_not_contains "$out" "display budget" "note truncated before its tail"
pass "status text is sanitized and hard-truncated"

# --- colors present by default, dropped with NO_COLOR ------------------------

out=$(env -u NO_COLOR FM_HOME="$home" "$SL" </dev/null)
case "$out" in
  *$'\033['*) : ;;
  *) fail "colored output must contain ANSI sequences" ;;
esac
pass "ANSI colors emitted by default and dropped under NO_COLOR"

# --- statusline JSON on stdin is drained and ignored -------------------------

piped=$(printf '{"model":{"display_name":"x"}}' | env NO_COLOR=1 FM_HOME="$home" "$SL")
bare=$(run_sl "$home")
[ "$piped" = "$bare" ] || fail "piped stdin output must match bare output"
pass "session JSON on stdin is ignored safely"

# --- idle secondmate omitted; secondmate decision still pops -----------------

home=$(make_home secondmate)
fm_write_secondmate_meta "$home/state/sm.meta" "$home"
printf 'working: idle\n' > "$home/state/sm.status"
out=$(run_sl "$home")
assert_contains "$out" "fleet idle" "idle secondmate omitted from readout"
printf 'needs-decision: retire stale project clone?\n' >> "$home/state/sm.status"
out=$(run_sl "$home")
assert_contains "$out" "1 needs you" "secondmate decision surfaces"
assert_contains "$out" "sm needs you: retire stale project clone?" "secondmate decision segment"
pass "idle secondmate quiet, secondmate decision pops"

# --- afk flag shown ----------------------------------------------------------

home=$(make_home afk)
touch "$home/state/.afk"
out=$(run_sl "$home")
assert_contains "$out" "afk" "away marker shown when state/.afk exists"
pass "away flag surfaces in the summary"

# --- oversized status log degrades to newest-event classification ------------

home=$(make_home oversized)
fm_write_meta "$home/state/big.meta" "window=w" "kind=ship"
{
  printf 'working: early filler\n'
  printf 'needs-decision: buried decision\n'
  printf 'working: newest event\n'
} > "$home/state/big.status"
out=$(run_sl "$home" FM_STATUSLINE_FOLD_MAX_BYTES=8)
assert_contains "$out" "newest event" "oversized log classifies from newest event"
assert_not_contains "$out" "needs you" "oversized log skips the whole-file fold"
pass "oversized status log degrades honestly to the newest event"

# --- strictly read-only against state/ ---------------------------------------

home=$(make_home readonly)
fm_write_meta "$home/state/ro.meta" "window=w" "kind=ship"
printf 'working: checking read-only contract\n' > "$home/state/ro.status"
before=$(find "$home/state" | LC_ALL=C sort)
run_sl "$home" >/dev/null
after=$(find "$home/state" | LC_ALL=C sort)
[ "$before" = "$after" ] || fail "statusline must not create or remove files under state/"
pass "statusline is read-only against state/"

# --- help and argument handling ----------------------------------------------

help_out=$("$SL" --help </dev/null); code=$?
expect_code 0 "$code" "--help exits 0"
assert_contains "$help_out" "statusLine" "--help documents the Claude Code wiring"
"$SL" --bogus </dev/null >/dev/null 2>&1; code=$?
expect_code 2 "$code" "unknown flag exits 2"
pass "help documents wiring and unknown flags are refused"

printf 'ok - fm-statusline behavior suite complete\n'
