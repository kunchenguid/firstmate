#!/usr/bin/env bash
# Focused tests for bin/fm-crew-relabel.sh: the small standalone helper that
# refreshes one live herdr-presentation task's visible crew-label workspace
# title from its recorded crew_label without allocating a new number.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-crew-relabel)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_DATA_OVERRIDE="$FM_HOME/data"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE"

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HERDR_LOG="$TMP_ROOT/herdr-calls.log"
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HERDR_LOG"
if [ "\${FM_TEST_HERDR_RENAME_FAIL:-0}" = 1 ]; then
  exit 1
fi
exit 0
SH
chmod +x "$FAKEBIN/herdr"
export PATH="$FAKEBIN:$PATH"

RELABEL="$ROOT/bin/fm-crew-relabel.sh"

write_meta() {  # <id> <extra-lines...>
  local id=$1
  shift
  {
    printf 'backend=herdr\n'
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$FM_STATE_OVERRIDE/$id.meta"
}

write_journal() {  # <id> <token>
  local id=$1 token=$2
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
    printf 'home=%s\n' "$FM_HOME"
    printf 'session=fmtest\n'
    printf 'workspace_id=w1\n'
    printf 'tab_id=w1:t1\n'
    printf 'pane_id=w1:p1\n'
    printf 'parent_workspace_id=w0\n'
    printf 'parent_label=firstmate\n'
    printf 'workspace_label=X1 %s · p:%s\n' "$id" "$token"
    printf 'task_label=fm-%s\n' "$id"
  } > "$FM_STATE_OVERRIDE/$id.herdr-presentation"
}

reset() {
  rm -f "$FM_STATE_OVERRIDE"/*.meta "$FM_STATE_OVERRIDE"/*.herdr-presentation
  : > "$HERDR_LOG"
  unset FM_TEST_HERDR_RENAME_FAIL
}

reset
out=$("$RELABEL" no-such-task 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no task record" \
  || fail "an unknown task id should refuse with a clear error"
pass "fm-crew-relabel: an unknown task id refuses with a clear error"

reset
write_meta tmux-task
out=$("$RELABEL" tmux-task 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "a non-herdr task should be a silent no-op: rc=$rc out=[$out]"
pass "fm-crew-relabel: a non-herdr backend task is a silent no-op"

reset
: > "$FM_STATE_OVERRIDE/no-crew.meta"
printf 'backend=herdr\n' > "$FM_STATE_OVERRIDE/no-crew.meta"
out=$("$RELABEL" no-crew 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] \
  || fail "a herdr task with no recorded crew_label should be a silent no-op: rc=$rc out=[$out]"
pass "fm-crew-relabel: a herdr task with no crew_label is a silent no-op"

reset
write_meta incomplete "crew_label=X1"
out=$("$RELABEL" incomplete 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no recorded herdr_session/herdr_workspace_id" \
  || fail "crew_label with no session/workspace should refuse: rc=$rc out=[$out]"
pass "fm-crew-relabel: crew_label with no recorded herdr_session/herdr_workspace_id refuses"

reset
write_meta task-p2 "crew_label=X1" "herdr_session=fmtest" "herdr_workspace_id=w1"
out=$("$RELABEL" task-p2 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no valid presentation journal" \
  || fail "a task with no journal should refuse: rc=$rc out=[$out]"
pass "fm-crew-relabel: a task with no presentation journal refuses"

reset
write_meta task-p2 "crew_label=X1" "herdr_session=fmtest" "herdr_workspace_id=w1"
write_journal task-p2 AbCdEfGhIjKlMnOpQrStUv
out=$("$RELABEL" task-p2 2>&1); rc=$?
[ "$rc" -eq 0 ] || fail "a valid crew_label task should relabel successfully: rc=$rc out=[$out]"
[ "$out" = "X1 task-p2 · p:AbCdEfGhIjKlMnOpQrStUv" ] \
  || fail "printed label should recompute from crew_label plus concise task id fallback (no backlog): $out"
grep -q "workspace rename w1 X1 task-p2 · p:AbCdEfGhIjKlMnOpQrStUv" "$HERDR_LOG" \
  || fail "herdr workspace rename was not called with the exact workspace id and new label: $(cat "$HERDR_LOG")"
pass "fm-crew-relabel: a valid crew_label task recomputes and applies its current label"

reset
write_meta task-p2 "crew_label=X1" "herdr_session=fmtest" "herdr_workspace_id=w1"
write_journal task-p2 AbCdEfGhIjKlMnOpQrStUv
export FM_TEST_HERDR_RENAME_FAIL=1
out=$("$RELABEL" task-p2 2>&1); rc=$?
unset FM_TEST_HERDR_RENAME_FAIL
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "herdr workspace rename failed" \
  || fail "a failed herdr rename call should propagate as a refusal: rc=$rc out=[$out]"
pass "fm-crew-relabel: a failed herdr workspace rename call is reported as a refusal"
