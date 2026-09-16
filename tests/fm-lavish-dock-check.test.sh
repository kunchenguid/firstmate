#!/usr/bin/env bash
# Behavior tests for bin/fm-lavish-dock-check.sh, the standing Lavish dock-reply
# check.
#
# Dock Send notes must reach this home as a captain-inbox wake without calling
# `lavish-axi poll`. These cases drive the public check/arm/disarm commands
# against a scratch home and a fixture session store. They never contact a live
# Lavish server and never poll.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-lavish-dock-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-lavish-dock-check)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

run_check() {
  local home=$1 lavish_dir=$2 out=$3
  shift 3
  local status=0
  env "$@" \
    FM_HOME="$home" \
    LAVISH_AXI_STATE_DIR="$lavish_dir" \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" check >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

make_lavish_dir() {
  local name=$1 dir
  dir="$TMP_ROOT/$name-lavish"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

write_state() {
  local dir=$1
  python3 - "$dir/state.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = {
  "sessions": {
    "face620c9be38af3": {
      "file": "/tmp/studio-like-mini.html",
      "status": "feedback",
      "url": "http://mac-studio.tail1c136e.ts.net:4387/session/face620c9be38af3",
      "pending_prompts": 2,
      "prompts": [
        {"uid": "4", "prompt": "Didn't we change this?", "text": "pi openai-codex/gpt-5.6-luna high", "tag": "td"},
        {"uid": "7", "prompt": "We need this fixed.", "text": "Live helm cwd is stale.", "tag": "p"}
      ]
    },
    "ecb00bed23aba957": {
      "file": "/tmp/ii-acs-packing.html",
      "status": "open",
      "url": "http://127.0.0.1:4387/session/ecb00bed23aba957",
      "pending_prompts": 0,
      "prompts": []
    }
  }
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
PY
}

install_poll_trap() {
  cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf 'poll invoked: %s\n' "$*" >> "${FM_LAVISH_POLL_LOG:-/tmp/fm-lavish-poll.log}"
exit 1
SH
  chmod +x "$FAKEBIN/lavish-axi"
}

test_help_and_usage() {
  local out rc=0
  out=$("$CHECK" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "check" "--help lists the check action"
  assert_contains "$out" "arm" "--help lists the arm action"
  assert_contains "$out" "disarm" "--help lists the disarm action"
  assert_contains "$out" "Never runs" "--help says it never polls"
  rc=0
  out=$("$CHECK" bogus 2>&1) || rc=$?
  expect_code 2 "$rc" "unknown action must exit 2"
  assert_contains "$out" "unknown action" "unknown action is refused loudly"
  pass "fm-lavish-dock-check: help and usage plumbing"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "arm must succeed: $out"
  assert_contains "$out" "armed: state/lavish-dock.check.sh" "arm names the shim it wrote"
  assert_present "$home/state/lavish-dock.check.sh" "arm writes the check shim"
  assert_present "$home/state/lavish-dock.check-trust" "arm binds the shim for the watcher"
  assert_contains "$(cat "$home/state/lavish-dock.check.sh")" "fm-lavish-dock-check.sh check" "shim dispatches the check action"
  assert_contains "$(cat "$home/state/lavish-dock.check.sh")" "FM_HOME=$home" "shim pins the absolute home"

  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || fail "re-arm must succeed: $out"
  assert_contains "$out" "armed" "re-arm stays armed"

  printf 'fm-lavish-dock-seen-v1\nface 4\n' > "$home/state/.lavish-dock-seen"
  out=$(FM_HOME="$home" "$CHECK" disarm 2>&1) || fail "disarm must succeed: $out"
  assert_absent "$home/state/lavish-dock.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/lavish-dock.check-trust" "disarm removes the trust binding"
  assert_absent "$home/state/.lavish-dock-check" "disarm removes the report record"
  assert_absent "$home/state/.lavish-dock-seen" "disarm removes the forwarded-uid cursor"
  pass "fm-lavish-dock-check: arm writes and binds, re-arm is idempotent, disarm removes"
}

test_arm_resolves_a_relative_home_into_the_shim() {
  local home rel out
  home=$(make_home relative)
  rel="$(basename "$home")"
  out=$(cd "$TMP_ROOT" && env FM_HOME="$rel" "$CHECK" arm 2>&1) || fail "arm with a relative FM_HOME must succeed: $out"
  assert_contains "$(cat "$home/state/lavish-dock.check.sh")" "export FM_HOME=$home" "the shim pins the resolved absolute home, not the relative spelling"
  pass "fm-lavish-dock-check: arm resolves a relative home into the shim"
}

test_arm_refuses_a_symlink_at_the_shim_path() {
  local home target out rc=0
  home=$(make_home symlink)
  target="$TMP_ROOT/outside"
  mkdir -p "$target"
  printf '#!/usr/bin/env bash\n' > "$target/lavish-dock.check.sh"
  ln -s "$target/lavish-dock.check.sh" "$home/state/lavish-dock.check.sh"
  out=$(FM_HOME="$home" "$CHECK" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse a symlink at the shim path"
  assert_contains "$out" "could not write" "arm reports the shim write failure"
  assert_absent "$home/state/lavish-dock.check-trust" "no trust binding is left behind by a refused arm"
  pass "fm-lavish-dock-check: arm refuses a symlink at the shim path"
}

test_arm_refuses_without_inbox() {
  local tmpbin home out rc=0
  tmpbin="$TMP_ROOT/plane/bin"
  home="$TMP_ROOT/plane/home"
  mkdir -p "$tmpbin" "$home/state"
  cp "$ROOT/bin/fm-lavish-dock-check.sh" "$tmpbin/"
  for lib in fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh; do
    [ -e "$tmpbin/$lib" ] || ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  out=$(FM_HOME="$home" "$tmpbin/fm-lavish-dock-check.sh" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must refuse when fm-inbox.sh is missing"
  assert_contains "$out" "fm-inbox.sh is missing" "arm names the missing inbox"
  assert_absent "$home/state/lavish-dock.check.sh" "a refused arm writes no shim"
  pass "fm-lavish-dock-check: arm refuses without fm-inbox.sh"
}

test_pending_dock_note_becomes_an_inbox_wake_without_polling() {
  local home lavish out note wakeq poll_log
  home=$(make_home deliver)
  lavish=$(make_lavish_dir deliver)
  write_state "$lavish"
  poll_log="$TMP_ROOT/poll.log"
  rm -f "$poll_log"
  install_poll_trap
  out="$home/out.txt"
  run_check "$home" "$lavish" "$out" FM_LAVISH_POLL_LOG="$poll_log"
  assert_contains "$(cat "$out")" "lavish-dock: queued 1 dock note" "a new dock Send prints one check line"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "a successful dock copy reports exactly one line: $(cat "$out")"
  [ ! -e "$poll_log" ] || fail "check must never invoke lavish-axi poll: $(cat "$poll_log")"

  note=$(find "$home/state/inbox" -name '*.note' -type f | head -n 1)
  [ -n "$note" ] || fail "check must queue a captain inbox note"
  assert_contains "$(cat "$note")" "Didn't we change this?" "the inbox note carries the dock prompt"
  assert_contains "$(cat "$note")" "We need this fixed." "the inbox note carries every unseen prompt from that Send"
  assert_contains "$(cat "$note")" "Open: https://mac-studio.tail1c136e.ts.net:4389/session/face620c9be38af3" "the inbox note uses the 4389 HTTPS wrap"
  if grep -q ':4387' "$note"; then
    fail "the inbox note must not name a :4387 Open: $(cat "$note")"
  fi
  if grep -q 'ii-acs-packing' "$note"; then
    fail "a session with no pending prompts must not be queued: $(cat "$note")"
  fi

  wakeq="$home/state/.wake-queue"
  assert_contains "$(cat "$wakeq" 2>/dev/null)" "captain inbox note" "queueing the note appends a Firstmate wake"
  assert_contains "$(cat "$home/state/.lavish-dock-seen")" "face620c9be38af3 4" "the cursor records the first forwarded uid"
  assert_contains "$(cat "$home/state/.lavish-dock-seen")" "face620c9be38af3 7" "the cursor records every forwarded uid"

  out="$home/out2.txt"
  run_check "$home" "$lavish" "$out" FM_LAVISH_POLL_LOG="$poll_log"
  [ ! -s "$out" ] || fail "a second check must stay silent once those prompts are forwarded: $(cat "$out")"
  [ "$(find "$home/state/inbox" -name '*.note' -type f | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail "a second check must not queue another note"
  [ ! -e "$poll_log" ] || fail "the silent re-check must still never poll"
  pass "fm-lavish-dock-check: a dock note becomes an inbox wake without poll or 4387"
}

test_missing_store_is_silent() {
  local home lavish out
  home=$(make_home missing)
  lavish=$(make_lavish_dir missing)
  out="$home/out.txt"
  run_check "$home" "$lavish" "$out"
  [ ! -s "$out" ] || fail "an absent session store must stay silent: $(cat "$out")"
  [ ! -e "$home/state/inbox" ] || [ -z "$(find "$home/state/inbox" -name '*.note' -type f 2>/dev/null)" ] \
    || fail "an absent session store must not queue notes"
  pass "fm-lavish-dock-check: a missing session store is a silent no-op"
}

test_malformed_store_is_reported_once() {
  local home lavish out
  home=$(make_home malformed)
  lavish=$(make_lavish_dir malformed)
  printf 'not-json\n' > "$lavish/state.json"
  out="$home/out.txt"
  run_check "$home" "$lavish" "$out"
  assert_contains "$(cat "$out")" "lavish-dock: unreadable lavish session store" "a malformed store reports one line"
  out="$home/out2.txt"
  run_check "$home" "$lavish" "$out"
  [ ! -s "$out" ] || fail "the same malformed-store failure must not be reported again: $(cat "$out")"
  pass "fm-lavish-dock-check: a malformed store is reported once"
}

test_help_and_usage
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_arm_resolves_a_relative_home_into_the_shim
test_arm_refuses_a_symlink_at_the_shim_path
test_arm_refuses_without_inbox
test_pending_dock_note_becomes_an_inbox_wake_without_polling
test_missing_store_is_silent
test_malformed_store_is_reported_once
