#!/usr/bin/env bash
# tests/fm-t3-delegation.test.sh - T3 main-thread delegation record and import behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-t3-delegation-lib.sh"

PARENT=c60e583f-1fd9-4e97-ae6e-5c7a7e052e8a
OTHER_PARENT=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
CLIENT=round-ship-001
TASK=fm-ship-t3-1

setup_home() {
  HOME_DIR=$1
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"
  : > "$HOME_DIR/config/t3-main-thread-lead"
  export FM_HOME=$HOME_DIR
  export FM_STATE_OVERRIDE=$HOME_DIR/state
  unset FM_CONFIG_OVERRIDE
}

TMP=$(fm_test_tmproot fm-t3-delegation)
setup_home "$TMP/home"
ROOT_PROJ=$TMP/project
WT=$TMP/wt
fm_git_worktree "$ROOT_PROJ" "$WT" fm/t3-test

fm_t3_delegation_enabled "$TMP/home/config" || fail "presence flag should enable mode"
pass "mode enables with config/t3-main-thread-lead"

out=$(fm_t3_delegation_record_intent "$CLIENT" "$TASK" "$PARENT" ship no-mistakes off \
  "$ROOT_PROJ" main fm/ "$ROOT_PROJ" true fm/t3-ship)
echo "$out" | jq -e '.phase == "intent" and .taskId == "'"$TASK"'"' >/dev/null || fail "intent record"
pass "record-intent creates intent phase"

if fm_t3_delegation_record_intent "$CLIENT" other-task "$PARENT" ship '' off '' '' fm/ '' true '' 2>/dev/null; then
  fail "duplicate clientRequestId with different task must refuse"
fi
pass "ownership mismatch on clientRequestId refuses"

DISPATCH=$TMP/dispatch.json
printf '{"taskId":"t3-task-99","childThreadId":"child-abc","target":{"providerInstanceId":"cursor","model":"composer-2.5"}}' >"$DISPATCH"
bound=$(fm_t3_delegation_bind_dispatch "$CLIENT" "$PARENT" "$DISPATCH")
echo "$bound" | jq -e '.phase == "dispatch_accepted" and .t3TaskId == "t3-task-99"' >/dev/null || fail "bind dispatch"
pass "bind-dispatch records t3 ids"

if fm_t3_delegation_bind_dispatch "$CLIENT" "$OTHER_PARENT" "$DISPATCH" 2>/dev/null; then
  fail "parent thread mismatch must refuse bind"
fi
pass "parentThreadId mismatch refuses bind"

UNCERTAIN=$TMP/uncertain.json
printf '{"accepted":false}' >"$UNCERTAIN"
CLIENT2=round-uncertain
fm_t3_delegation_record_intent "$CLIENT2" "$TASK" "$PARENT" scout '' off "$ROOT_PROJ" '' fm/ '' false '' >/dev/null
unc=$(fm_t3_delegation_bind_dispatch "$CLIENT2" "$PARENT" "$UNCERTAIN")
echo "$unc" | jq -e '.phase == "dispatch_uncertain"' >/dev/null || fail "uncertain dispatch"
pass "uncertain dispatch preserved"

STATUS1=$TMP/status-working.json
printf '{"state":"running"}' >"$STATUS1"
imp=$(fm_t3_delegation_import_status "$CLIENT" "$PARENT" "$STATUS1")
echo "$imp" | jq -e '.phase == "working"' >/dev/null || fail "import working"
pass "import maps running to working"

STATUS2=$TMP/status-done-nested.json
printf '{"state":"completed","waitingForChildren":true}' >"$STATUS2"
imp2=$(fm_t3_delegation_import_status "$CLIENT" "$PARENT" "$STATUS2")
echo "$imp2" | jq -e '.phase == "waiting_for_children"' >/dev/null || fail "nested live"
pass "completed with nested live work is not terminal completion"

STATUS3=$TMP/status-pr.json
printf '{"state":"completed","pullRequestUrl":"https://github.com/o/r/pull/1"}' >"$STATUS3"
imp3=$(fm_t3_delegation_import_status "$CLIENT" "$PARENT" "$STATUS3")
echo "$imp3" | jq -e '.outcomeKind == "ready_pr"' >/dev/null || fail "ready pr"
pass "completed with PR maps to ready_pr"

dup=$(fm_t3_delegation_import_status "$CLIENT" "$PARENT" "$STATUS3")
digest=$(echo "$imp3" | jq -r '.lastImportDigest')
echo "$dup" | jq -e --arg d "$digest" '.lastImportDigest == $d and .phase == "completed"' >/dev/null || fail "idempotent import digest"
pass "duplicate status import is idempotent"

STATUS4=$TMP/status-fail.json
printf '{"state":"failed"}' >"$STATUS4"
fm_t3_delegation_import_status "$CLIENT" "$PARENT" "$STATUS4" >/dev/null
line=$(fm_t3_delegation_status_line_for_record "$(fm_t3_delegation_read "$CLIENT")")
echo "$line" | grep -q '^failed:' || fail "failed status line"
pass "failed maps to failed status line"

mkdir -p "$TMP/home/state"
: > "$TMP/home/state/${TASK}.status"
rec=$(fm_t3_delegation_read "$CLIENT")
fm_t3_delegation_publish_supervision "$TASK" "$rec" || fail "publish supervision"
grep -q 'failed ' "$TMP/home/state/${TASK}.status" || fail "status file append"
pass "notify publishes status and wake"

fm_t3_worktree_isolated "$ROOT_PROJ" "$ROOT_PROJ" && fail "primary must not pass isolation"
pass "primary checkout fails isolation"

fm_t3_worktree_isolated "$ROOT_PROJ" "$WT" || fail "linked worktree should isolate"
pass "linked worktree passes isolation"

CLIENT3=round-iso
fm_t3_delegation_record_intent "$CLIENT3" "$TASK" "$PARENT" ship no-mistakes off \
  "$ROOT_PROJ" main fm/ "$ROOT_PROJ" true fm/iso >/dev/null
FM_HOME=$TMP/home FM_STATE_OVERRIDE=$TMP/home/state \
  "$ROOT/bin/fm-t3-delegation.sh" record-isolated-worktree \
  --client-request-id "$CLIENT3" --project "$ROOT_PROJ" --worktree "$ROOT_PROJ" 2>/dev/null && \
  fail "record-isolated-worktree must refuse primary"
pass "record-isolated-worktree refuses primary checkout"

FM_HOME=$TMP/home FM_STATE_OVERRIDE=$TMP/home/state \
  "$ROOT/bin/fm-t3-delegation.sh" record-isolated-worktree \
  --client-request-id "$CLIENT3" --project "$ROOT_PROJ" --worktree "$WT" >/dev/null || fail "record isolated wt"

stored=$(fm_t3_delegation_read "$CLIENT3")
echo "$stored" | jq -e '.isolatedWorktree | length > 0' >/dev/null || fail "isolated path stored"
pass "isolated worktree recorded"

rec_path=$(fm_t3_delegation_record_path "$CLIENT")
grep -qiE 'credential|secret|TOKEN=' "$rec_path" && fail "record must not store credentials"
pass "records exclude credential fields by schema"

FM_HOME=$TMP/home FM_STATE_OVERRIDE=$TMP/home/state \
  "$ROOT/bin/fm-t3-delegation.sh" cancel-bind --client-request-id "$CLIENT" --parent-thread-id "$PARENT" >/dev/null
cancelled=$(fm_t3_delegation_read "$CLIENT")
echo "$cancelled" | jq -e '.phase == "cancelled"' >/dev/null || fail "cancel bind"
pass "cancel-bind marks cancelled without deleting record"

outstanding=$(fm_t3_delegation_list_outstanding "$PARENT" | grep -c "$CLIENT" || true)
[ "$outstanding" -eq 0 ] || fail "cancelled should not stay outstanding"
pass "cancelled delegations drop from outstanding list"

echo "# fm-t3-delegation.test.sh: all assertions passed"
