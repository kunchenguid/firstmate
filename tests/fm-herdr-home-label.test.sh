#!/usr/bin/env bash
# Focused tests for bin/fm-herdr-home-label.sh, the per-home herdr workspace +
# entrypoint-pane labeler. Covers the three behaviours that keep a home's crews
# grouped under the home name instead of a flat "firstmate" (epic hlay):
#   1. a resolved home labels the workspace + pane with the home name,
#   2. an UNRESOLVED home (FM_HOME unset) FAILS LOUD rather than silently
#      relabelling to the code-root basename "firstmate" (hlay-06),
#   3. a non-herdr runtime is a silent no-op even when FM_HOME is unset.
# The herdr CLI is a small logging fake (real binary smoke lives with the backend
# smoke tests); this pins the labeler's own decision logic with no harness.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-home-label)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
LABELER="$ROOT/bin/fm-herdr-home-label.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HERDR_LOG="$TMP_ROOT/herdr-calls.log"
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$HERDR_LOG"
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  printf '%s\n' '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}'
fi
exit 0
SH
chmod +x "$FAKEBIN/herdr"

# A home whose basename is a real home name, distinct from "firstmate".
HOME_AIMICA="$TMP_ROOT/homes/aimica"
mkdir -p "$HOME_AIMICA"

# run_labeler runs the labeler in a controlled environment: the fake herdr on
# PATH, no inherited TMUX/HERDR pane identity, and only the vars each case sets.
run_labeler() {  # <env assignments...> -- passed straight to env
  : > "$HERDR_LOG"
  env -u TMUX -u HERDR_ENV -u HERDR_WORKSPACE_ID -u HERDR_PANE_ID \
    -u FM_HOME -u FM_ROOT_OVERRIDE \
    PATH="$FAKEBIN:$BASE_PATH" "$@" bash "$LABELER" 2>&1
}

# 1. A resolved home labels the workspace and entrypoint pane with the home name.
out=$(run_labeler HERDR_ENV=1 HERDR_WORKSPACE_ID=ws1 HERDR_PANE_ID=p1 FM_HOME="$HOME_AIMICA")
log=$(cat "$HERDR_LOG")
assert_contains "$log" "workspace rename ws1 aimica" \
  "labeler did not rename the workspace to the home name"
assert_contains "$log" "pane rename p1 aimica · firstmate" \
  "labeler did not title the entrypoint pane with the home name"
[ -z "$out" ] || fail "labeler warned on a resolved home: $out"
pass "labeler labels the workspace and pane with the home name when FM_HOME is set"

# 2. An unresolved home fails loud and does NOT relabel to "firstmate".
out=$(run_labeler HERDR_ENV=1 HERDR_WORKSPACE_ID=ws1 HERDR_PANE_ID=p1)
log=$(cat "$HERDR_LOG")
assert_contains "$out" "FM_HOME is not set" \
  "labeler did not warn loudly about an unresolved home"
assert_not_contains "$log" "workspace rename" \
  "labeler silently relabelled the workspace with FM_HOME unset (the hlay-06 bug)"
assert_not_contains "$log" "pane rename" \
  "labeler renamed the entrypoint pane with FM_HOME unset"
pass "labeler refuses (warns, no rename) rather than mislabelling 'firstmate' when FM_HOME is unset"

# 3. A non-herdr runtime is a silent no-op, even with FM_HOME unset - no spurious
# warning, no rename (the labeler must never fire on tmux/other backends).
out=$(run_labeler)
log=$(cat "$HERDR_LOG")
[ -z "$out" ] || fail "labeler emitted output on a non-herdr runtime: $out"
assert_not_contains "$log" "rename" "labeler mutated a non-herdr runtime"
pass "labeler is a silent no-op on a non-herdr runtime"

printf 'all fm-herdr-home-label tests passed\n'
