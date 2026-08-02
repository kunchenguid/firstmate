#!/usr/bin/env bash
# Behavior tests for the minimal Herdr sibling that waits for and execs the
# native no-mistakes attach dashboard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
git -C "$REPO" checkout -q -b fm/dashboard-test

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:?}"
case "${1:-} ${2:-}" in
  "axi status")
    count=$(wc -l < "${FM_FAKE_NM_CALLS:?}")
    if [ -e "${FM_FAKE_NM_WRONG_BRANCH:-}" ]; then
      printf '%s\n' 'run:' '  id: "OTHER123"' '  branch: fm/other' '  status: running'
    elif [ "$count" -le 1 ] && [ -e "${FM_FAKE_NM_TERMINAL_FIRST:-}" ]; then
      printf '%s\n' 'run:' '  id: "OLD123"' '  branch: fm/dashboard-test' '  status: failed' 'outcome: failed'
      exit 1
    else
      printf '%s\n' 'run:' '  id: "RUN123"' '  branch: fm/dashboard-test' '  status: running'
    fi
    ;;
  "attach --run")
    [ "${3:-}" = RUN123 ] || exit 3
    printf '%s\n' RUN123 > "${FM_FAKE_NM_ATTACHED:?}"
    ;;
  *) exit 4 ;;
esac
SH
chmod +x "$FAKEBIN/no-mistakes"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_CALLS:?}"
case "${1:-} ${2:-}" in
  "pane get")
    case "${3:-}" in
      w1:p7) printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p7","tab_id":"w1:t7","workspace_id":"w1"}}}' ;;
      w1:p8) printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p8","tab_id":"w1:t7","workspace_id":"w1"}}}' ;;
      *) exit 3 ;;
    esac
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
export FM_FAKE_NM_ATTACHED="$FIXTURE/attached"
export FM_FAKE_HERDR_CALLS="$FIXTURE/herdr.calls"
: > "$FM_FAKE_NM_CALLS"
: > "$FM_FAKE_HERDR_CALLS"

help=$($HELPER --help) || fail 'help failed'
assert_contains "$help" 'creates no journal, performs no recovery or' 'help omitted the intentionally absent lifecycle'
assert_contains "$help" '<no-mistakes-executable> attach --run <run-id>' 'help omitted the exact native attach argv'
pass 'fm-no-mistakes-attach: help owns the complete narrow contract'

output=$(cd "$REPO" && HERDR_ENV=0 "$HELPER" prepare) || fail 'non-Herdr prepare failed'
assert_contains "$output" 'not-applicable: runtime is not Herdr' 'non-Herdr path was not explicit'
[ ! -s "$FM_FAKE_HERDR_CALLS" ] || fail 'non-Herdr prepare called Herdr'
pass 'fm-no-mistakes-attach: non-Herdr behavior is unchanged'

output=$(cd "$REPO" && \
  HERDR_ENV=1 HERDR_SESSION=test HERDR_PANE_ID=w1:p7 \
  HERDR_SOCKET_PATH="$FIXTURE/herdr.sock" "$HELPER" prepare) || fail_with_output 'Herdr prepare failed' "$output"
assert_contains "$output" 'prepared: pane w1:p8 waiting for no-mistakes on branch fm/dashboard-test' \
  'prepare did not report the response-derived sibling and branch'
assert_grep 'pane get w1:p7 --session test' "$FM_FAKE_HERDR_CALLS" 'prepare did not verify the injected pane in the exact session'
assert_grep "pane split w1:p7 --direction right --ratio 0.5 --cwd $REPO --no-focus --session test" \
  "$FM_FAKE_HERDR_CALLS" 'prepare did not make the required unfocused sibling split'
assert_grep 'pane get w1:p8 --session test' "$FM_FAKE_HERDR_CALLS" 'prepare did not verify the response-derived sibling'
grep -F 'pane run w1:p8 ' "$FM_FAKE_HERDR_CALLS" | grep -F ' wait ' | grep -F "'fm/dashboard-test'" >/dev/null \
  || fail 'prepare did not start the waiter in the sibling pane'
assert_no_grep ' focus ' "$FM_FAKE_HERDR_CALLS" 'prepare attempted to change focus'
pass 'fm-no-mistakes-attach: Herdr prepare creates and binds one exact sibling without focus theft'

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/terminal-first"
export FM_FAKE_NM_TERMINAL_FIRST="$FIXTURE/terminal-first"
FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FAKEBIN/no-mistakes" || fail 'wait did not exec native attach'
[ "$(cat "$FM_FAKE_NM_ATTACHED")" = RUN123 ] || fail 'wait did not bind attach to the exact active run'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'wait did not poll status until the active run appeared'
assert_grep 'attach --run RUN123' "$FM_FAKE_NM_CALLS" 'wait did not use exact native attach argv'
assert_no_grep 'axi run' "$FM_FAKE_NM_CALLS" 'wait became a second AXI driver'
assert_no_grep 'axi respond' "$FM_FAKE_NM_CALLS" 'wait answered an AXI gate'
pass 'fm-no-mistakes-attach: waiter ignores terminal history and execs native attach for the exact active run'

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/wrong-branch"
export FM_FAKE_NM_WRONG_BRANCH="$FIXTURE/wrong-branch"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=2 FM_NM_ATTACH_POLL_SECONDS=0 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail_with_output 'wrong-branch wait did not time out' "$output"
assert_contains "$output" 'no active no-mistakes run appeared for branch fm/dashboard-test' \
  'wrong-branch timeout was not explicit'
assert_no_grep 'attach ' "$FM_FAKE_NM_CALLS" 'wrong-branch run was attached'
pass 'fm-no-mistakes-attach: waiter refuses a run from another branch'
