#!/usr/bin/env bash
# Real Herdr regression for automatic terminal teardown.
#
# This opt-in test starts one task-local agent process in a named non-default
# Herdr lab session, lands its local-only branch, and exercises the operator's
# normal fm-merge-local.sh path. The merge must synchronously auto-reap the exact
# endpoint and return the exact Treehouse lease through ordinary teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

if [ "${FM_AUTO_REAP_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_AUTO_REAP_HERDR_E2E=1 to run the real Herdr auto-reap regression"
  exit 0
fi

for tool in git herdr jq python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool not found"
    exit 0
  }
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=${HERDR_LAB_SESSION:-$("$LAB_HELPER" name fm-auto-reap-herdr-e2e)}
PREPROVISIONED=${FM_AUTO_REAP_HERDR_E2E_PREPROVISIONED:-0}
ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$ROOT/.fm-auto-reap-herdr-e2e.XXXXXX")
FAKE_ROOT="$TMP_ROOT/fm-root"
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
POOL="$TMP_ROOT/pool"
WORKTREE="$POOL/1/worktree"
TREEHOUSE_STATE="$POOL/treehouse-state.json"
TREEHOUSE_LOG="$TMP_ROOT/treehouse.log"
ID=auto-reap-herdr-e2e
PROVISIONED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$PROVISIONED" = 1 ] && ! "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

herdr_test_lab_available "$SESSION" || exit 0
if [ "$PREPROVISIONED" != 1 ]; then
  "$LAB_HELPER" provision "$SESSION"
  PROVISIONED=1
fi

mkdir -p "$FAKE_ROOT" "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$POOL/1"
ln -s "$ROOT/bin" "$FAKE_ROOT/bin"
cp "$ROOT/tests/fixtures/herdr-lab-wrapper.sh" "$FAKEBIN/herdr"
ln "$ROOT/tests/fixtures/treehouse-return-fixture.sh" "$FAKEBIN/treehouse"
chmod 700 "$FAKEBIN/herdr"

fm_git_init_commit "$PROJECT"
git -C "$PROJECT" branch -M main
git -C "$PROJECT" worktree add -qb "fm/$ID" "$WORKTREE"
printf 'landed by the real auto-reap E2E\n' > "$WORKTREE/e2e.txt"
git -C "$WORKTREE" add e2e.txt
git -C "$WORKTREE" commit -qm "exercise automatic reaping"

python3 - "$TREEHOUSE_STATE" "$WORKTREE" "$ID" <<'PY'
import json
import sys

state_path, worktree, task_id = sys.argv[1:]
with open(state_path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "worktrees": [
                {
                    "path": worktree,
                    "leased": True,
                    "lease_holder": f"firstmate-{task_id}",
                    "destroying": False,
                }
            ]
        },
        stream,
    )
PY

export FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1
export HERDR_LAB_HELPER="$LAB_HELPER"
export HERDR_LAB_SESSION="$SESSION"
export HERDR_LAB_REAL_PATH="$ORIGINAL_PATH"
export HERDR_LAB_WRAPPER_LOG="$TMP_ROOT/herdr-wrapper.log"
export HERDR_SESSION="$SESSION"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
export FM_ROOT_OVERRIDE="$FAKE_ROOT"
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"
export FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_AUTO_REAP_E2E_WORKTREE="$WORKTREE"
export FM_AUTO_REAP_E2E_PROJECT="$PROJECT"
export FM_AUTO_REAP_E2E_TREEHOUSE_STATE="$TREEHOUSE_STATE"
export FM_AUTO_REAP_E2E_TREEHOUSE_LOG="$TREEHOUSE_LOG"
export FM_GATE_REFUSE_BYPASS=1

fm_backend_source herdr || fail "could not load the production Herdr adapter"
WORKSPACE_LABEL=$(fm_backend_herdr_workspace_label_for_home "$HOME_DIR")
workspace_out=$("$LAB_HELPER" run "$SESSION" workspace create \
  --cwd "$WORKTREE" --label "$WORKSPACE_LABEL" --no-focus)
WORKSPACE_ID=$(printf '%s' "$workspace_out" | jq -r '.result.workspace.workspace_id // empty')
[ -n "$WORKSPACE_ID" ] || fail "real Herdr workspace create returned no workspace id"

if task_endpoint=$(fm_backend_herdr_create_task \
    "$SESSION:$WORKSPACE_ID" "fm-$ID" "$WORKTREE" ""); then
  :
else
  printf '%s\n' "--- production Herdr adapter trace ---" >&2
  cat "$HERDR_LAB_WRAPPER_LOG" >&2
  fail "real Herdr task create failed through the production adapter"
fi
TAB_ID=${task_endpoint%% *}
PANE_ID=${task_endpoint#* }
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "real Herdr task create returned incomplete identity"
"$LAB_HELPER" run "$SESSION" pane send-text "$PANE_ID" "exec sleep 600" >/dev/null
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE_ID" enter >/dev/null
"$LAB_HELPER" run "$SESSION" pane get "$PANE_ID" >/dev/null \
  || fail "real Herdr task endpoint was not alive before auto-reap"

fm_write_meta "$HOME_DIR/state/$ID.meta" \
  "window=$SESSION:$PANE_ID" \
  "worktree=$WORKTREE" \
  "project=$PROJECT" \
  "backend=herdr" \
  "herdr_session=$SESSION" \
  "herdr_workspace_id=$WORKSPACE_ID" \
  "herdr_tab_id=$TAB_ID" \
  "herdr_pane_id=$PANE_ID" \
  "harness=bash" \
  "kind=ship" \
  "mode=local-only" \
  "yolo=off" \
  "tasktmp=" \
  "generation_id=real-herdr-auto-reap"
printf 'done: local branch ready for approved merge\n' > "$HOME_DIR/state/$ID.status"

if out=$("$ROOT/bin/fm-merge-local.sh" "$ID" 2>&1); then
  :
else
  printf '%s\n' "$out" >&2
  printf '%s\n' "--- production Herdr adapter trace ---" >&2
  cat "$HERDR_LAB_WRAPPER_LOG" >&2
  fail "real local merge landed but automatic teardown refused"
fi
assert_contains "$out" "auto-reaped $ID" "real local merge did not report automatic reaping"
[ ! -e "$HOME_DIR/state/$ID.meta" ] || fail "automatic teardown retained task metadata"
[ ! -e "$WORKTREE" ] || fail "automatic teardown retained the Treehouse worktree"
assert_contains "$(cat "$TREEHOUSE_LOG")" "returned $WORKTREE" "exact Treehouse return was not invoked"
jq -e '.worktrees | length == 1 and .[0].leased == false and .[0].lease_holder == null' \
  "$TREEHOUSE_STATE" >/dev/null || fail "Treehouse lease was not released"

if "$LAB_HELPER" run "$SESSION" pane get "$PANE_ID" >/dev/null 2>&1; then
  fail "automatic teardown retained the real Herdr task endpoint"
fi
[ "$(git -C "$PROJECT" rev-parse main)" = "$(git -C "$PROJECT" rev-parse HEAD)" ] \
  || fail "local default branch did not receive the task commit"

printf 'evidence: endpoint=%s:%s removed; Treehouse lease released; task metadata removed\n' \
  "$SESSION" "$PANE_ID"
pass "real Herdr terminal task is automatically reaped after its work lands"
