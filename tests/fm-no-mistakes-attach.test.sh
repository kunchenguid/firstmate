#!/usr/bin/env bash
# Behavior tests for the minimal Herdr sibling that waits for and execs the
# native no-mistakes attach dashboard.
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
git -C "$REPO" checkout -q -b fm/dashboard-test
git -C "$REPO" commit -q --allow-empty -m current

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:?}"
case "${1:-} ${2:-}" in
  "axi status")
    count=$(wc -l < "${FM_FAKE_NM_CALLS:?}")
    if [ -e "${FM_FAKE_NM_STATUS_FAIL:-}" ]; then
      printf '%s\n' 'simulated status transport failure' >&2
      exit 42
    elif [ -e "${FM_FAKE_NM_STATUS_MALFORMED:-}" ]; then
      printf '%s\n' 'not a no-mistakes status payload'
    elif [ -e "${FM_FAKE_NM_STATUS_EMPTY:-}" ]; then
      :
    elif [ -e "${FM_FAKE_NM_STATUS_NO_HEAD:-}" ]; then
      printf '%s\n' 'run:' '  id: "NOHEAD123"' '  branch: fm/dashboard-test' '  status: running'
    elif [ -e "${FM_FAKE_NM_NO_RUN_LEADING_MIXED:-}" ]; then
      printf '%s\n' 'unexpected leading payload' 'No active run. Push through the gate to start a pipeline:'
    elif [ -e "${FM_FAKE_NM_NO_RUN_TRAILING_MIXED:-}" ]; then
      printf '%s\n' 'No active run. Push through the gate to start a pipeline:' 'unexpected trailing payload'
    elif [ -e "${FM_FAKE_NM_NO_RUN_LEADING_BLANK:-}" ]; then
      printf '\n%s\n' 'No active run. Push through the gate to start a pipeline:'
    elif [ -e "${FM_FAKE_NM_NO_RUN_TRAILING_BLANK:-}" ]; then
      printf '%s\n\n' 'No active run. Push through the gate to start a pipeline:'
    elif [ "$count" -le 1 ] && [ -e "${FM_FAKE_NM_NO_RUN_CRLF_FIRST:-}" ]; then
      printf '%s\r\n' 'No active run. Push through the gate to start a pipeline:'
    elif [ -e "${FM_FAKE_NM_NO_RUN_ALWAYS:-}" ]; then
      printf '%s\n' 'No active run. Push through the gate to start a pipeline:'
    elif [ "$count" -le 1 ] && [ -e "${FM_FAKE_NM_NO_RUN_FIRST:-}" ]; then
      printf '%s\n' 'No active run. Push through the gate to start a pipeline:'
    elif [ -n "${FM_FAKE_NM_TRANSIENT_FAILURES:-}" ] && [ "$count" -le "$FM_FAKE_NM_TRANSIENT_FAILURES" ]; then
      printf '%s\n' 'simulated transient status failure' >&2
      exit 42
    elif [ -e "${FM_FAKE_NM_WRONG_BRANCH:-}" ]; then
      printf '%s\n' 'run:' '  id: "OTHER123"' '  branch: fm/other' '  head: "deadbeef"' '  status: running'
    elif [ "$count" -le 1 ] && [ -e "${FM_FAKE_NM_TERMINAL_FIRST:-}" ]; then
      printf '%s\n' 'run:' '  id: "OLD123"' '  branch: fm/dashboard-test' "  head: \"${FM_FAKE_NM_RUN_HEAD:?}\"" '  status: failed' 'outcome: failed'
    elif [ "$count" -le 1 ] && [ -e "${FM_FAKE_NM_STALE_HEAD_FIRST:-}" ]; then
      printf '%s\n' 'run:' '  id: "STALE123"' '  branch: fm/dashboard-test' "  head: \"${FM_FAKE_NM_STALE_HEAD:?}\"" '  status: running'
    else
      printf '%s\n' 'run:' '  id: "RUN123"' '  branch: fm/dashboard-test' "  head: \"${FM_FAKE_NM_RUN_HEAD:?}\"" '  status: running'
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
export FM_FAKE_NM_ATTACHED="$FIXTURE/attached"
export FM_FAKE_HERDR_CALLS="$FIXTURE/herdr.calls"
export FM_FAKE_HERDR_SOCKET="$FIXTURE/herdr.sock"
FM_FAKE_NM_RUN_HEAD=$(git -C "$REPO" rev-parse HEAD)
export FM_FAKE_NM_RUN_HEAD
FM_FAKE_NM_STALE_HEAD=$(git -C "$REPO" rev-parse HEAD^)
export FM_FAKE_NM_STALE_HEAD
fixture_tree=$(git -C "$REPO" write-tree)
FM_FAKE_NM_DESCENDANT_HEAD=$(git -C "$REPO" commit-tree "$fixture_tree" -p "$FM_FAKE_NM_RUN_HEAD" -m pipeline)
export FM_FAKE_NM_DESCENDANT_HEAD
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
grep -F 'pane run w1:p8 ' "$FM_FAKE_HERDR_CALLS" | grep -F "'$FM_FAKE_NM_RUN_HEAD'" >/dev/null \
  || fail 'prepare did not bind the waiter to the current implementation commit'
assert_no_grep ' focus ' "$FM_FAKE_HERDR_CALLS" 'prepare attempted to change focus'
pass 'fm-no-mistakes-attach: Herdr prepare creates and binds one exact sibling without focus theft'

: > "$FM_FAKE_HERDR_CALLS"
set +e
output=$(cd "$REPO" && \
  HERDR_ENV=1 HERDR_SESSION=test HERDR_PANE_ID=w1:p7 \
  HERDR_SOCKET_PATH="$FIXTURE/other.sock" "$HELPER" prepare 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'cross-socket prepare did not refuse' "$output"
assert_contains "$output" 'cannot verify current Herdr identity' \
  'cross-socket refusal did not identify the binding failure'
assert_no_grep 'pane split' "$FM_FAKE_HERDR_CALLS" 'cross-socket identity created a sibling'
pass 'fm-no-mistakes-attach: prepare reuses canonical live Herdr identity verification'

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
lock_path=$(PATH="$FAKEBIN:$PATH" HERDR_SESSION=test HERDR_SOCKET_PATH="$FM_FAKE_HERDR_SOCKET" \
  fm_backend_herdr_presentation_session_lock_path test) || fail 'could not derive fixture presentation lock'
fm_lock_try_acquire "$lock_path" || fail 'could not hold fixture presentation lock'
: > "$FM_FAKE_HERDR_CALLS"
set +e
output=$(cd "$REPO" && \
  HERDR_ENV=1 HERDR_SESSION=test HERDR_PANE_ID=w1:p7 \
  HERDR_SOCKET_PATH="$FM_FAKE_HERDR_SOCKET" FM_NM_ATTACH_LOCK_ATTEMPTS=1 \
  FM_NM_ATTACH_LOCK_SLEEP_SECONDS=0 "$HELPER" prepare 2>&1)
rc=$?
set -e
fm_lock_release "$lock_path"
[ "$rc" -eq 2 ] || fail_with_output 'contended presentation lock did not refuse' "$output"
assert_contains "$output" 'cannot acquire the Herdr session presentation lock' \
  'lock contention refusal was not explicit'
assert_no_grep 'pane split' "$FM_FAKE_HERDR_CALLS" 'lock contention allowed an unlocked sibling split'
pass 'fm-no-mistakes-attach: sibling creation serializes with canonical Herdr presentation mutations'

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/terminal-first"
export FM_FAKE_NM_TERMINAL_FIRST="$FIXTURE/terminal-first"
FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" || fail 'wait did not exec native attach'
[ "$(cat "$FM_FAKE_NM_ATTACHED")" = RUN123 ] || fail 'wait did not bind attach to the exact active run'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'wait did not poll status until the active run appeared'
assert_grep 'attach --run RUN123' "$FM_FAKE_NM_CALLS" 'wait did not use exact native attach argv'
assert_no_grep 'axi run' "$FM_FAKE_NM_CALLS" 'wait became a second AXI driver'
assert_no_grep 'axi respond' "$FM_FAKE_NM_CALLS" 'wait answered an AXI gate'
pass 'fm-no-mistakes-attach: waiter ignores terminal history and execs native attach for the exact active run'
unset FM_FAKE_NM_TERMINAL_FIRST

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/stale-head-first"
export FM_FAKE_NM_STALE_HEAD_FIRST="$FIXTURE/stale-head-first"
FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" || fail 'wait did not skip stale same-branch run'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'stale same-branch run was not skipped'
[ "$(cat "$FM_FAKE_NM_ATTACHED")" = RUN123 ] || fail 'stale same-branch run was attached'
pass 'fm-no-mistakes-attach: waiter rejects an older same-branch run before attaching the current one'
unset FM_FAKE_NM_STALE_HEAD_FIRST

: > "$FM_FAKE_NM_CALLS"
export FM_FAKE_NM_RUN_HEAD="$FM_FAKE_NM_DESCENDANT_HEAD"
FM_NM_ATTACH_MAX_POLLS=1 FM_NM_ATTACH_POLL_SECONDS=0 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$(git -C "$REPO" rev-parse HEAD)" "$FAKEBIN/no-mistakes" || fail 'wait did not accept pipeline-descendant run head'
[ "$(cat "$FM_FAKE_NM_ATTACHED")" = RUN123 ] || fail 'pipeline-descendant run was not attached'
pass 'fm-no-mistakes-attach: waiter accepts the canonical pipeline-descendant run head'
FM_FAKE_NM_RUN_HEAD=$(git -C "$REPO" rev-parse HEAD)
export FM_FAKE_NM_RUN_HEAD

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/status-fail"
export FM_FAKE_NM_STATUS_FAIL="$FIXTURE/status-fail"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=5 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=2 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'persistent status failure did not stop the waiter' "$output"
assert_contains "$output" 'axi status failed 2 consecutive times: simulated status transport failure' \
  'persistent status failure did not preserve the diagnostic'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'persistent status failure exceeded the bounded retry limit'
assert_no_grep 'attach ' "$FM_FAKE_NM_CALLS" 'persistent status failure attached a run'
pass 'fm-no-mistakes-attach: persistent status failure exits with a bounded diagnostic'
unset FM_FAKE_NM_STATUS_FAIL

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/status-malformed"
export FM_FAKE_NM_STATUS_MALFORMED="$FIXTURE/status-malformed"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=5 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=2 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'malformed status did not stop the waiter' "$output"
assert_contains "$output" 'axi status failed 2 consecutive times: not a no-mistakes status payload' \
  'malformed status failure was not explicit'
pass 'fm-no-mistakes-attach: malformed status is not misreported as an absent run'
unset FM_FAKE_NM_STATUS_MALFORMED

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/status-empty"
export FM_FAKE_NM_STATUS_EMPTY="$FIXTURE/status-empty"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=5 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=2 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'empty status did not stop the waiter' "$output"
assert_contains "$output" 'axi status failed 2 consecutive times: empty output' \
  'empty status failure was not explicit'
pass 'fm-no-mistakes-attach: empty status is not misreported as an absent run'
unset FM_FAKE_NM_STATUS_EMPTY

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/status-no-head"
export FM_FAKE_NM_STATUS_NO_HEAD="$FIXTURE/status-no-head"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=5 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=2 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'status without a head did not stop the waiter' "$output"
assert_contains "$output" 'axi status failed 2 consecutive times: status output is missing required run id, branch, or head' \
  'missing head was not reported as unusable status output'
pass 'fm-no-mistakes-attach: status without a code identity is not misreported as an absent run'
unset FM_FAKE_NM_STATUS_NO_HEAD

: > "$FM_FAKE_NM_CALLS"
export FM_FAKE_NM_TRANSIENT_FAILURES=1
FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=2 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" || fail 'transient status failure did not recover'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'transient status recovery did not retry once'
[ "$(cat "$FM_FAKE_NM_ATTACHED")" = RUN123 ] || fail 'transient status recovery did not attach the matching run'
pass 'fm-no-mistakes-attach: transient status failure recovers before the bounded limit'
unset FM_FAKE_NM_TRANSIENT_FAILURES

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/no-run-first"
export FM_FAKE_NM_NO_RUN_FIRST="$FIXTURE/no-run-first"
FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=1 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" || fail 'explicit no-run response did not continue polling'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'explicit no-run response did not poll until the matching run appeared'
assert_grep 'attach --run RUN123' "$FM_FAKE_NM_CALLS" 'explicit no-run response prevented attachment to the matching run'
pass 'fm-no-mistakes-attach: canonical LF no-run response polls until the matching run appears'
unset FM_FAKE_NM_NO_RUN_FIRST

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/no-run-crlf-first"
export FM_FAKE_NM_NO_RUN_CRLF_FIRST="$FIXTURE/no-run-crlf-first"
FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=1 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" || fail 'canonical CRLF no-run response did not continue polling'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'canonical CRLF no-run response did not poll until the matching run appeared'
assert_grep 'attach --run RUN123' "$FM_FAKE_NM_CALLS" 'canonical CRLF no-run response prevented attachment to the matching run'
pass 'fm-no-mistakes-attach: canonical CRLF no-run response polls until the matching run appears'
unset FM_FAKE_NM_NO_RUN_CRLF_FIRST

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/no-run-always"
export FM_FAKE_NM_NO_RUN_ALWAYS="$FIXTURE/no-run-always"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=2 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=1 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail_with_output 'explicit no-run response did not reach the normal absence timeout' "$output"
assert_contains "$output" 'no active no-mistakes run appeared for branch fm/dashboard-test after 2 polls' \
  'explicit no-run response did not report the normal absence timeout'
[ "$(grep -c '^axi status$' "$FM_FAKE_NM_CALLS")" -eq 2 ] || fail 'explicit no-run response did not consume the normal poll budget'
assert_no_grep 'attach ' "$FM_FAKE_NM_CALLS" 'explicit no-run response attached a run'
pass 'fm-no-mistakes-attach: persistent explicit no-run response reaches the normal absence timeout'
unset FM_FAKE_NM_NO_RUN_ALWAYS

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/no-run-leading-blank"
export FM_FAKE_NM_NO_RUN_LEADING_BLANK="$FIXTURE/no-run-leading-blank"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=1 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'leading blank no-run payload bypassed the status error limit' "$output"
assert_contains "$output" 'axi status failed 1 consecutive times: No active run. Push through the gate to start a pipeline:' \
  'leading blank no-run payload did not preserve the malformed diagnostic'
pass 'fm-no-mistakes-attach: leading blank no-run payload is malformed'
unset FM_FAKE_NM_NO_RUN_LEADING_BLANK

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/no-run-trailing-blank"
export FM_FAKE_NM_NO_RUN_TRAILING_BLANK="$FIXTURE/no-run-trailing-blank"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=1 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'trailing blank no-run payload bypassed the status error limit' "$output"
assert_contains "$output" 'axi status failed 1 consecutive times: No active run. Push through the gate to start a pipeline:' \
  'trailing blank no-run payload did not preserve the malformed diagnostic'
pass 'fm-no-mistakes-attach: trailing blank no-run payload is malformed'
unset FM_FAKE_NM_NO_RUN_TRAILING_BLANK

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/no-run-leading-mixed"
export FM_FAKE_NM_NO_RUN_LEADING_MIXED="$FIXTURE/no-run-leading-mixed"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=1 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'leading mixed no-run payload bypassed the status error limit' "$output"
assert_contains "$output" 'axi status failed 1 consecutive times: unexpected leading payload' \
  'leading mixed no-run payload did not preserve the malformed diagnostic'
pass 'fm-no-mistakes-attach: leading mixed no-run payload is malformed'
unset FM_FAKE_NM_NO_RUN_LEADING_MIXED

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/no-run-trailing-mixed"
export FM_FAKE_NM_NO_RUN_TRAILING_MIXED="$FIXTURE/no-run-trailing-mixed"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=3 FM_NM_ATTACH_POLL_SECONDS=0 FM_NM_ATTACH_STATUS_ERROR_LIMIT=1 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail_with_output 'trailing mixed no-run payload bypassed the status error limit' "$output"
assert_contains "$output" 'axi status failed 1 consecutive times: No active run. Push through the gate to start a pipeline:' \
  'trailing mixed no-run payload did not preserve the malformed diagnostic'
pass 'fm-no-mistakes-attach: trailing mixed no-run payload is malformed'
unset FM_FAKE_NM_NO_RUN_TRAILING_MIXED

: > "$FM_FAKE_NM_CALLS"
: > "$FIXTURE/wrong-branch"
export FM_FAKE_NM_WRONG_BRANCH="$FIXTURE/wrong-branch"
set +e
output=$(FM_NM_ATTACH_MAX_POLLS=2 FM_NM_ATTACH_POLL_SECONDS=0 \
  "$HELPER" wait "$REPO" fm/dashboard-test "$FM_FAKE_NM_RUN_HEAD" "$FAKEBIN/no-mistakes" 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail_with_output 'wrong-branch wait did not time out' "$output"
assert_contains "$output" 'no active no-mistakes run appeared for branch fm/dashboard-test' \
  'wrong-branch timeout was not explicit'
assert_no_grep 'attach ' "$FM_FAKE_NM_CALLS" 'wrong-branch run was attached'
pass 'fm-no-mistakes-attach: waiter refuses a run from another branch'
