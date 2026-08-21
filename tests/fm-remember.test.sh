#!/usr/bin/env bash
# tests/fm-remember.test.sh - guard behavior of bin/fm-remember.sh, the
# best-effort fleet-memory push wired into decision-hold and /stow (memval-04).
#
# fm-remember.sh is a side-effect that must NEVER block or fail its caller. The
# cases here drive the REAL script over a fake per-home memory CLI and assert:
#   - absent CLI (home has no memory wiring) -> no call, no output, exit 0;
#   - present CLI -> the decision text reaches the CLI verbatim;
#   - a slow/hung CLI is bounded by FM_REMEMBER_TIMEOUT and still exits 0;
#   - empty text -> no call, exit 0;
#   - node missing -> no call, exit 0.
# The write path itself (memhub-remember.mjs) is memval-03's and is not retested.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REMEMBER="$ROOT/bin/fm-remember.sh"
TMP_ROOT=$(fm_test_tmproot fm-remember-tests)

# Build a fake home whose memory CLI records each decision text (one per line)
# to <home>/config/memory/recorded, so a test can assert what reached the CLI.
# <mode> shapes the stub: "record" writes and exits 0; "hang" never returns.
make_home() {  # <name> <mode>
  local name=$1 mode=$2 home mjs
  home="$TMP_ROOT/$name"
  mjs="$home/config/memory/memhub-remember.mjs"
  mkdir -p "$home/config/memory"
  case "$mode" in
    record)
      cat > "$mjs" <<'JS'
import { appendFileSync } from "node:fs";
appendFileSync(new URL("./recorded", import.meta.url), process.argv[2] + "\n");
JS
      ;;
    hang)
      cat > "$mjs" <<'JS'
setInterval(() => {}, 1000); // never exits on its own
JS
      ;;
  esac
  printf '%s\n' "$home"
}

test_absent_cli_does_nothing() {
  local home="$TMP_ROOT/no-memory" out rc
  mkdir -p "$home"                        # a home with NO config/memory/
  out=$(FM_HOME="$home" "$REMEMBER" "chose X over Y because Z" 2>&1); rc=$?
  expect_code 0 "$rc" "absent CLI must exit 0"
  [ -z "$out" ] || fail "absent CLI must emit nothing, got: $out"
  pass "absent memory CLI: no call, no output, exit 0"
}

test_present_cli_receives_text() {
  local home out rc recorded
  home=$(make_home wired record)
  out=$(FM_HOME="$home" "$REMEMBER" "chose SQLite over Postgres for the seed" 2>&1); rc=$?
  expect_code 0 "$rc" "present CLI call must exit 0"
  [ -z "$out" ] || fail "present CLI must not print to the caller, got: $out"
  recorded="$home/config/memory/recorded"
  assert_present "$recorded" "wired CLI should have recorded the decision"
  assert_grep "chose SQLite over Postgres for the seed" "$recorded" \
    "the decision text must reach the CLI verbatim"
  pass "wired memory CLI receives the decision text verbatim"
}

test_slow_cli_is_bounded() {
  local home rc start end elapsed
  home=$(make_home slow hang)
  start=$(date +%s)
  FM_HOME="$home" FM_REMEMBER_TIMEOUT=1 "$REMEMBER" "a decision the hub cannot ack" >/dev/null 2>&1
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  expect_code 0 "$rc" "a hung CLI must still exit 0 (fail open)"
  [ "$elapsed" -lt 8 ] \
    || fail "a hung CLI must be bounded by the timeout, took ${elapsed}s"
  pass "slow/hung CLI is bounded and still exits 0"
}

test_empty_text_is_a_noop() {
  local home out rc
  home=$(make_home empty record)
  out=$(FM_HOME="$home" "$REMEMBER" "" 2>&1); rc=$?
  expect_code 0 "$rc" "empty text must exit 0"
  [ -z "$out" ] || fail "empty text must emit nothing, got: $out"
  assert_absent "$home/config/memory/recorded" "empty text must not invoke the CLI"
  pass "empty decision text: no call, exit 0"
}

test_node_missing_does_nothing() {
  local home out rc
  home=$(make_home nonode record)
  # A PATH without node (nvm's node is not under /usr/bin or /bin) still has the
  # coreutils fm-remember.sh needs before its node check.
  out=$(PATH=/usr/bin:/bin FM_HOME="$home" "$REMEMBER" "a decision with no node" 2>&1); rc=$?
  expect_code 0 "$rc" "missing node must exit 0"
  [ -z "$out" ] || fail "missing node must emit nothing, got: $out"
  assert_absent "$home/config/memory/recorded" "missing node must not invoke the CLI"
  pass "node missing: no call, exit 0"
}

test_absent_cli_does_nothing
test_present_cli_receives_text
test_slow_cli_is_bounded
test_empty_text_is_a_noop
test_node_missing_does_nothing
