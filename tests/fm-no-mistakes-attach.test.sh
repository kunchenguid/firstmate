#!/usr/bin/env bash
# Behavior tests for the native no-mistakes attach surface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail_with_output() {
  printf '%s\n' "$2" >&2
  fail "$1"
}

TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-attach)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

HELPER="$ROOT/bin/fm-no-mistakes-attach.sh"
REPO="$TMP_ROOT/repo"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
FIXTURE="$TMP_ROOT/fixture"
mkdir -p "$REPO" "$FIXTURE"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name Test
git -C "$REPO" commit -q --allow-empty -m initial
git -C "$REPO" checkout -q -b fm/native-attach-test
git -C "$REPO" commit -q --allow-empty -m current

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:?}"
exit 99
SH
chmod +x "$FAKEBIN/no-mistakes"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_CALLS:?}"
case "${1:-} ${2:-}" in
  "session list")
    printf '%s\n' "{\"sessions\":[{\"name\":\"test\",\"running\":true,\"socket_path\":\"${FM_FAKE_HERDR_SOCKET:?}\"}]}"
    ;;
  "pane get")
    case "${3:-}" in
      w1:p7) printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p7","tab_id":"w1:t7","workspace_id":"w1"}}}' ;;
      w1:p8) printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p8","tab_id":"w1:t7","workspace_id":"w1"}}}' ;;
      *) exit 3 ;;
    esac
    ;;
  "tab get")
    [ "${3:-}" = w1:t7 ] || exit 3
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t7","workspace_id":"w1"}}}'
    ;;
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1"}]}}'
    ;;
  "pane split")
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p8"}}}'
    ;;
  "pane run")
    printf '%s\n' '{"result":{"ok":true}}'
    ;;
  *) exit 4 ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

export PATH="$FAKEBIN:$PATH"
export FM_FAKE_NM_CALLS="$FIXTURE/no-mistakes.calls"
export FM_FAKE_HERDR_CALLS="$FIXTURE/herdr.calls"
export FM_FAKE_HERDR_SOCKET="$FIXTURE/herdr.sock"
FM_FAKE_NM_RUN_HEAD=$(git -C "$REPO" rev-parse HEAD)
export FM_FAKE_NM_RUN_HEAD
FM_FAKE_NM_STALE_HEAD=$(git -C "$REPO" rev-parse HEAD^)
export FM_FAKE_NM_STALE_HEAD
: > "$FM_FAKE_NM_CALLS"
: > "$FM_FAKE_HERDR_CALLS"

help=$($HELPER --help) || fail 'help failed'
assert_contains "$help" 'attach <run-id> <expected-head>' 'help omitted the exact attach inputs'
assert_contains "$help" 'The headless driver alone starts, polls, retries, aborts' \
  'help omitted the single-driver boundary'
assert_contains "$help" '<no-mistakes-executable> attach --run <run-id>' \
  'help omitted the exact native attach argv'
pass 'fm-no-mistakes-attach: help owns the attach-only contract'

output=$(cd "$REPO" && HERDR_ENV=0 "$HELPER" attach RUN123 "$FM_FAKE_NM_RUN_HEAD") \
  || fail 'non-Herdr attach failed'
assert_contains "$output" 'not-applicable: runtime is not Herdr' 'non-Herdr path was not explicit'
[ ! -s "$FM_FAKE_HERDR_CALLS" ] || fail 'non-Herdr attach called Herdr'
pass 'fm-no-mistakes-attach: non-Herdr behavior is unchanged'

set +e
output=$(cd "$REPO" && HERDR_ENV=1 HERDR_SESSION=test HERDR_PANE_ID=w1:p7 \
  HERDR_SOCKET_PATH="$FM_FAKE_HERDR_SOCKET" "$HELPER" attach RUN123 "$FM_FAKE_NM_STALE_HEAD" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'mismatched HEAD did not refuse' "$output"
assert_contains "$output" 'implementation commit does not match attach expected head' \
  'mismatched HEAD refusal was not explicit'
[ ! -s "$FM_FAKE_HERDR_CALLS" ] || fail 'mismatched HEAD created a visible surface'
pass 'fm-no-mistakes-attach: exact checked-out HEAD is required before placement'

set +e
output=$(cd "$REPO" && HERDR_ENV=1 HERDR_SESSION=test HERDR_PANE_ID=w1:p7 \
  HERDR_SOCKET_PATH="$FM_FAKE_HERDR_SOCKET" "$HELPER" attach 'RUN123;OTHER' "$FM_FAKE_NM_RUN_HEAD" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'invalid run id did not refuse' "$output"
assert_contains "$output" 'attach run id is invalid' 'invalid run id refusal was not explicit'
[ ! -s "$FM_FAKE_HERDR_CALLS" ] || fail 'invalid run id created a visible surface'
pass 'fm-no-mistakes-attach: exact run identity is required before placement'

output=$(cd "$REPO" && HERDR_ENV=1 HERDR_SESSION=test HERDR_PANE_ID=w1:p7 \
  HERDR_SOCKET_PATH="$FM_FAKE_HERDR_SOCKET" "$HELPER" attach RUN123 "$FM_FAKE_NM_RUN_HEAD") \
  || fail_with_output 'native attach placement failed' "$output"
assert_contains "$output" "attached: pane w1:p8 run RUN123 at head $FM_FAKE_NM_RUN_HEAD" \
  'attach did not report the exact pane, run, and HEAD'
assert_grep 'pane get w1:p7 --session test' "$FM_FAKE_HERDR_CALLS" \
  'attach did not verify the current pane identity'
assert_grep "pane split w1:p7 --direction right --ratio 0.5 --cwd $REPO --no-focus --session test" \
  "$FM_FAKE_HERDR_CALLS" 'attach did not make the required unfocused sibling split'
assert_grep 'pane get w1:p8 --session test' "$FM_FAKE_HERDR_CALLS" \
  'attach did not verify the response-derived sibling'
grep -F "pane run w1:p8 exec '$FAKEBIN/no-mistakes' attach --run 'RUN123'" "$FM_FAKE_HERDR_CALLS" >/dev/null \
  || fail 'attach did not launch the exact native attach command'
assert_no_grep 'axi ' "$FM_FAKE_HERDR_CALLS" 'visible surface attempted an AXI operation'
assert_no_grep 'codex\|transcript\|conversation' "$FM_FAKE_HERDR_CALLS" \
  'visible surface included a reconstructed agent UI'
[ ! -s "$FM_FAKE_NM_CALLS" ] || fail 'attach helper executed a second pipeline driver'
pass 'fm-no-mistakes-attach: only the native exact-run attach surface is placed'

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
lock_path=$(PATH="$FAKEBIN:$PATH" HERDR_SESSION=test HERDR_SOCKET_PATH="$FM_FAKE_HERDR_SOCKET" \
  fm_backend_herdr_presentation_session_lock_path test) || fail 'could not derive fixture presentation lock'
fm_lock_try_acquire "$lock_path" || fail 'could not hold fixture presentation lock'
: > "$FM_FAKE_HERDR_CALLS"
set +e
output=$(cd "$REPO" && HERDR_ENV=1 HERDR_SESSION=test HERDR_PANE_ID=w1:p7 \
  HERDR_SOCKET_PATH="$FM_FAKE_HERDR_SOCKET" FM_NM_ATTACH_LOCK_ATTEMPTS=1 \
  FM_NM_ATTACH_LOCK_SLEEP_SECONDS=0 "$HELPER" attach RUN123 "$FM_FAKE_NM_RUN_HEAD" 2>&1)
rc=$?
set -e
fm_lock_release "$lock_path"
[ "$rc" -eq 2 ] || fail_with_output 'contended presentation lock did not refuse' "$output"
assert_contains "$output" 'cannot acquire the Herdr session presentation lock' \
  'lock contention refusal was not explicit'
assert_no_grep 'pane split' "$FM_FAKE_HERDR_CALLS" 'lock contention allowed an unlocked sibling split'
pass 'fm-no-mistakes-attach: native surface placement serializes with presentation mutations'
