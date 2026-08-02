#!/usr/bin/env bash
# Behavior tests for terminal-state auto-reaping and crashed acquisition recovery.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTO_REAP="$ROOT/bin/fm-auto-reap.sh"
WATCH="$ROOT/bin/fm-watch.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP=$(fm_test_tmproot fm-auto-reap)
FAKEBIN=$(fm_fakebin "$TMP")
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
fm_git_identity

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'pull_request:\n  state: %s\n' "${FM_FAKE_PR_STATE:-open}"
SH

cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "axi status") printf '%s\n' "${FM_FAKE_NM_STATUS:-}" ;;
  "runs --limit 200") printf '%s\n' "${FM_FAKE_NM_RUNS:-}" ;;
  "axi abort --run "*)
    printf '%s\n' "$*" >> "$FM_FAKE_NM_LOG"
    ;;
  *) exit 2 ;;
esac
SH

cat > "$FAKEBIN/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
id=$1
printf '%s\n' "$id" >> "$FM_FAKE_TEARDOWN_LOG"
if [ "${FM_FAKE_TEARDOWN_ASSERT_ORPHAN:-0}" = 1 ]; then
  meta="$FM_STATE_OVERRIDE/$id.meta"
  grep -qx 'window=' "$meta" || exit 31
  grep -qx 'direct_spawn_endpoint=not-created' "$meta" || exit 32
  grep -qx 'direct_spawn_cleanup=pending' "$meta" || exit 33
  grep -qx 'tasktmp_phase=not-created' "$meta" || exit 34
fi
if [ "${FM_FAKE_TEARDOWN_ASSERT_HERDR:-0}" = 1 ]; then
  meta="$FM_STATE_OVERRIDE/$id.meta"
  grep -qx 'backend=herdr' "$meta" || exit 41
  grep -qx 'window=lab-session:pane-41' "$meta" || exit 42
  grep -qx 'herdr_session=lab-session' "$meta" || exit 43
  grep -qx 'herdr_workspace_id=workspace-41' "$meta" || exit 44
  grep -qx 'herdr_tab_id=tab-41' "$meta" || exit 45
  grep -qx 'herdr_pane_id=pane-41' "$meta" || exit 46
  ! grep -q '^direct_spawn_endpoint=' "$meta" || exit 47
fi
if [ "${FM_FAKE_TEARDOWN_STATUS:-0}" -ne 0 ]; then
  printf 'REFUSED: synthetic teardown refusal\n' >&2
  exit "$FM_FAKE_TEARDOWN_STATUS"
fi
rm -f "$FM_STATE_OVERRIDE/$id.meta"
printf 'teardown complete for %s\n' "$id"
SH
chmod +x "$FAKEBIN/gh-axi" "$FAKEBIN/no-mistakes" "$FAKEBIN/fm-teardown.sh"

export FM_AUTO_REAP_TEST_HOOKS=firstmate-auto-reap-tests-v1
export FM_AUTO_REAP_GH_AXI_BIN="$FAKEBIN/gh-axi"
export FM_AUTO_REAP_NO_MISTAKES_BIN="$FAKEBIN/no-mistakes"
export FM_AUTO_REAP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh"
export FM_FAKE_NM_LOG="$TMP/no-mistakes.log"
export FM_FAKE_TEARDOWN_LOG="$TMP/teardown.log"
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$HOME_DIR/state"

reset_logs() {
  : > "$FM_FAKE_NM_LOG"
  : > "$FM_FAKE_TEARDOWN_LOG"
  FM_FAKE_PR_STATE=merged
  FM_FAKE_NM_STATUS=
  FM_FAKE_NM_RUNS=
  FM_FAKE_TEARDOWN_STATUS=0
  FM_FAKE_TEARDOWN_ASSERT_ORPHAN=0
  FM_FAKE_TEARDOWN_ASSERT_HERDR=0
  export FM_FAKE_PR_STATE FM_FAKE_NM_STATUS FM_FAKE_NM_RUNS
  export FM_FAKE_TEARDOWN_STATUS FM_FAKE_TEARDOWN_ASSERT_ORPHAN FM_FAKE_TEARDOWN_ASSERT_HERDR
}

make_task() {  # <id> <mode>
  local id=$1 mode=$2 worktree
  worktree="$TMP/$id"
  fm_git_init_commit "$worktree"
  git -C "$worktree" checkout -qb "fm/$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=fm:$id" "worktree=$worktree" "project=$worktree" \
    "kind=ship" "mode=$mode" "pr=https://github.com/acme/repo/pull/7"
  printf 'done: PR checks green\n' > "$HOME_DIR/state/$id.status"
}

test_merged_task_cancels_exact_run_then_tears_down() {
  local out rc
  reset_logs
  make_task merged-run no-mistakes
  FM_FAKE_NM_STATUS=$(printf '%s\n' \
    'run:' \
    '  id: "01EXACT"' \
    '  branch: fm/merged-run' \
    '  status: running')
  export FM_FAKE_NM_STATUS
  out=$("$AUTO_REAP" task merged-run pr-merged 2>&1); rc=$?
  expect_code 0 "$rc" "merged task auto-reap"
  assert_contains "$out" "auto-reaped merged-run" "merged task reports reaping"
  assert_contains "$(cat "$FM_FAKE_NM_LOG")" "axi abort --run 01EXACT" "exact no-mistakes run canceled"
  assert_contains "$(cat "$FM_FAKE_TEARDOWN_LOG")" "merged-run" "ordinary teardown invoked"
  pass "merged terminal task cancels its exact no-mistakes run before teardown"
}

test_open_pr_refuses_without_teardown() {
  local out rc
  reset_logs
  make_task open-pr direct
  FM_FAKE_PR_STATE=open
  export FM_FAKE_PR_STATE
  out=$("$AUTO_REAP" task open-pr pr-merged 2>&1); rc=$?
  expect_code 1 "$rc" "open PR auto-reap refusal"
  assert_contains "$out" "not provably merged" "open PR refusal reason"
  [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "open PR invoked teardown"
  [ -f "$HOME_DIR/state/open-pr.meta" ] || fail "open PR metadata was removed"
  rm -f "$HOME_DIR/state/open-pr.meta" "$HOME_DIR/state/open-pr.status"
  pass "unmerged PR retains all task state"
}

test_cross_branch_active_run_refuses_without_guessing_id() {
  local out rc
  reset_logs
  make_task cross-run no-mistakes
  FM_FAKE_NM_STATUS=$(printf '%s\n' \
    'run:' \
    '  id: "01OTHER"' \
    '  branch: fm/other' \
    '  status: running')
  FM_FAKE_NM_RUNS='running    fm/cross-run abc1234  2026-07-26 12:00'
  export FM_FAKE_NM_STATUS FM_FAKE_NM_RUNS
  out=$("$AUTO_REAP" task cross-run pr-merged 2>&1); rc=$?
  expect_code 1 "$rc" "cross-branch active run refusal"
  assert_contains "$out" "exact run ID is unavailable" "cross-branch refusal reason"
  [ ! -s "$FM_FAKE_NM_LOG" ] || fail "cross-branch run was aborted by guess"
  [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "cross-branch task invoked teardown"
  rm -f "$HOME_DIR/state/cross-run.meta" "$HOME_DIR/state/cross-run.status"
  pass "active cross-branch validation is retained when its exact run ID is unavailable"
}

test_x_link_and_teardown_refusal_remain_visible() {
  local out rc
  reset_logs
  make_task x-linked direct
  printf 'x_request=req-1\n' >> "$HOME_DIR/state/x-linked.meta"
  out=$("$AUTO_REAP" task x-linked pr-merged 2>&1); rc=$?
  expect_code 1 "$rc" "X-linked task refusal"
  assert_contains "$out" "final follow-up" "X-linked refusal reason"
  [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "X-linked task invoked teardown"
  rm -f "$HOME_DIR/state/x-linked.meta" "$HOME_DIR/state/x-linked.status"

  reset_logs
  make_task teardown-refusal direct
  FM_FAKE_TEARDOWN_STATUS=1
  export FM_FAKE_TEARDOWN_STATUS
  out=$("$AUTO_REAP" task teardown-refusal pr-merged 2>&1); rc=$?
  expect_code 1 "$rc" "ordinary teardown refusal"
  assert_contains "$out" "ordinary teardown refused" "teardown refusal surfaced"
  [ -f "$HOME_DIR/state/teardown-refusal.meta" ] || fail "refused teardown lost metadata"
  rm -f "$HOME_DIR/state/teardown-refusal.meta" "$HOME_DIR/state/teardown-refusal.status"
  pass "follow-up obligations and ordinary teardown refusals stay visible"
}

make_treehouse_fixture() {  # <name>
  local name=$1 project pool worktree
  project="$TMP/$name-project"
  pool="$TMP/$name-pool"
  worktree="$TMP/$name-pool/1/worktree"
  fm_git_init_commit "$project"
  mkdir -p "$pool/1"
  git -C "$project" worktree add -q --detach "$worktree" HEAD
  python3 - "$pool/treehouse-state.json" "$worktree" "firstmate-$name" <<'PY'
import json
import sys

path, worktree, holder = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(
        {
            "worktrees": [
                {
                    "path": worktree,
                    "leased": True,
                    "lease_holder": holder,
                    "destroying": False,
                }
            ]
        },
        stream,
    )
PY
  printf '%s\t%s\n' "$project" "$worktree"
}

write_dead_acquisition() {  # <id> <project> <worktree> <mode> [endpoint-phase] [backend] [tasktmp-phase]
  local id=$1 project=$2 worktree=$3 mode=$4 endpoint_phase=${5:-not-created} backend=${6:-tmux} tasktmp_phase=${7:-not-created}
  local record home_real
  record="$HOME_DIR/state/.worktree-acquire-$id.pending"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  {
    printf '999999\nMon Jan  1 00:00:00 2001\n'
    printf 'id=%s\nproject=%s\nholder=firstmate-%s\n' "$id" "$project" "$id"
    printf 'home=%s\n' "$home_real"
    printf 'kind=ship\nmode=%s\nyolo=off\ngeneration_id=orphan-test\n' "$mode"
    printf 'tasktmp=/tmp/fm-%s-orphan-test\ntasktmp_phase=%s\n' "$id" "$tasktmp_phase"
    printf 'backend=%s\nendpoint_phase=%s\n' "$backend" "$endpoint_phase"
    printf 'worktree=%s\n' "$worktree"
  } > "$record"
  touch -t 202001010000 "$record"
}

test_dead_acquisition_recovers_but_live_owner_is_untouched() {
  local fixture project worktree out rc start live_record
  reset_logs
  fixture=$(make_treehouse_fixture crashed-slot)
  project=${fixture%%$'\t'*}
  worktree=${fixture#*$'\t'}
  write_dead_acquisition crashed-slot "$project" "$worktree" direct
  FM_FAKE_TEARDOWN_ASSERT_ORPHAN=1
  export FM_FAKE_TEARDOWN_ASSERT_ORPHAN
  out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  expect_code 0 "$rc" "dead acquisition recovery"
  assert_contains "$out" "auto-reaped crashed-slot" "dead acquisition reaped"
  [ ! -e "$HOME_DIR/state/.worktree-acquire-crashed-slot.pending" ] || fail "dead acquisition record survived success"
  assert_contains "$(cat "$FM_FAKE_TEARDOWN_LOG")" "crashed-slot" "dead acquisition delegated to teardown"

  reset_logs
  start=$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  live_record="$HOME_DIR/state/.worktree-acquire-live-slot.pending"
  {
    printf '%s\n%s\n' "$$" "$start"
    printf 'id=live-slot\nproject=%s\nholder=firstmate-live-slot\n' "$project"
    printf 'home=%s\n' "$(cd "$HOME_DIR" && pwd -P)"
    printf 'kind=ship\nmode=direct\nyolo=off\ngeneration_id=live\ntasktmp=/tmp/fm-live-slot-live\n'
    printf 'tasktmp_phase=not-created\nbackend=tmux\nendpoint_phase=not-created\nworktree=\n'
  } > "$live_record"
  touch -t 202001010000 "$live_record"
  out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  expect_code 0 "$rc" "live acquisition maintenance"
  [ -z "$out" ] || fail "live acquisition produced auto-reap output: $out"
  [ -f "$live_record" ] || fail "live acquisition record was removed"
  [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "live acquisition invoked teardown"
  pass "crashed acquisition is recovered only after exact owner death proof"
}

test_dirty_stranded_worktree_is_retained_by_real_teardown() {
  local fixture project worktree out rc
  reset_logs
  fixture=$(make_treehouse_fixture dirty-slot)
  project=${fixture%%$'\t'*}
  worktree=${fixture#*$'\t'}
  printf 'uncommitted\n' > "$worktree/dirty.txt"
  write_dead_acquisition dirty-slot "$project" "$worktree" local-only
  unset FM_AUTO_REAP_TEARDOWN_BIN
  out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  export FM_AUTO_REAP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh"
  expect_code 0 "$rc" "dirty acquisition maintenance remains a successful sweep"
  assert_contains "$out" "uncommitted changes" "real teardown dirty refusal"
  assert_contains "$out" "ordinary teardown refused" "dirty refusal surfaced by auto-reap"
  [ -f "$HOME_DIR/state/dirty-slot.meta" ] || fail "dirty worktree recovery metadata was removed"
  [ -f "$HOME_DIR/state/.worktree-acquire-dirty-slot.pending" ] || fail "dirty acquisition authority was removed"
  rm -f "$HOME_DIR/state/dirty-slot.meta" "$HOME_DIR/state/.worktree-acquire-dirty-slot.pending"
  pass "ordinary teardown preserves a dirty stranded worktree and its recovery authority"
}

test_unregistered_treehouse_lease_retains_acquisition_authority() {
  local fixture project worktree record out rc log
  reset_logs
  fixture=$(make_treehouse_fixture hidden-slot)
  project=${fixture%%$'\t'*}
  worktree=${fixture#*$'\t'}
  write_dead_acquisition hidden-slot "$project" "$worktree" direct
  record="$HOME_DIR/state/.worktree-acquire-hidden-slot.pending"
  git -C "$project" worktree remove --force "$worktree"
  out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  expect_code 0 "$rc" "unregistered Treehouse lease maintenance"
  assert_contains "$out" "lease absence could not be proven" "uncertain lease retention diagnostic"
  [ -f "$record" ] || fail "uncertain Treehouse acquisition authority was removed"
  [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "uncertain Treehouse lease invoked teardown"
  log=$(cat "$HOME_DIR/state/.auto-reap.log")
  assert_contains "$log" "retained owner-dead acquisition hidden-slot" "uncertain lease retention log"
  pass "unregistered Treehouse leases retain acquisition authority visibly"
}

test_malformed_treehouse_leases_retain_acquisition_authority() {
  local defect fixture project worktree record out rc log id
  for defect in holder path; do
    reset_logs
    id="malformed-$defect"
    fixture=$(make_treehouse_fixture "$id")
    project=${fixture%%$'\t'*}
    worktree=${fixture#*$'\t'}
    write_dead_acquisition "$id" "$project" "$worktree" direct
    record="$HOME_DIR/state/.worktree-acquire-$id.pending"
    git -C "$project" worktree remove --force "$worktree"
    python3 - "$(dirname "$(dirname "$worktree")")/treehouse-state.json" "$defect" <<'PY'
import json
import sys

state_path, defect = sys.argv[1:]
with open(state_path, encoding="utf-8") as stream:
    state = json.load(stream)
entry = state["worktrees"][0]
entry["leased"] = False
entry["lease_holder"] = "unexpected-holder" if defect == "holder" else None
if defect == "path":
    entry["path"] = None
with open(state_path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
PY
    out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
    expect_code 0 "$rc" "malformed Treehouse $defect maintenance"
    assert_contains "$out" "CORRUPT authoritative Treehouse lease state" "malformed $defect diagnostic"
    [ -f "$record" ] || fail "malformed Treehouse $defect removed acquisition authority"
    [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "malformed Treehouse $defect invoked teardown"
    log=$(cat "$HOME_DIR/state/.auto-reap.log")
    assert_contains "$log" "CORRUPT authoritative Treehouse lease state retained owner-dead acquisition $id" "malformed $defect log"
    rm -f "$record"
  done
  pass "malformed Treehouse holders and paths retain acquisition authority visibly"
}

test_destroying_treehouse_entry_retains_acquisition_authority() {
  local fixture project worktree record out rc log id=destroying-entry
  reset_logs
  fixture=$(make_treehouse_fixture "$id")
  project=${fixture%%$'\t'*}
  worktree=${fixture#*$'\t'}
  write_dead_acquisition "$id" "$project" "$worktree" direct
  record="$HOME_DIR/state/.worktree-acquire-$id.pending"
  git -C "$project" worktree remove --force "$worktree"
  python3 - "$(dirname "$(dirname "$worktree")")/treehouse-state.json" <<'PY'
import json
import sys

state_path = sys.argv[1]
with open(state_path, encoding="utf-8") as stream:
    state = json.load(stream)
entry = state["worktrees"][0]
entry["leased"] = False
entry["lease_holder"] = None
entry["destroying"] = True
with open(state_path, "w", encoding="utf-8") as stream:
    json.dump(state, stream)
PY
  out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  expect_code 0 "$rc" "destroying Treehouse entry maintenance"
  assert_contains "$out" "lease absence could not be proven" "destroying entry diagnostic"
  [ -f "$record" ] || fail "destroying Treehouse entry removed acquisition authority"
  [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "destroying Treehouse entry invoked teardown"
  log=$(cat "$HOME_DIR/state/.auto-reap.log")
  assert_contains "$log" "retained owner-dead acquisition $id" "destroying entry retention log"
  rm -f "$record"
  pass "transitional Treehouse destruction never proves lease absence"
}

test_ambiguous_endpoint_phase_retains_acquisition_authority() {
  local fixture project worktree record out rc id=ambiguous-endpoint
  reset_logs
  fixture=$(make_treehouse_fixture "$id")
  project=${fixture%%$'\t'*}
  worktree=${fixture#*$'\t'}
  write_dead_acquisition "$id" "$project" "$worktree" direct creating herdr
  record="$HOME_DIR/state/.worktree-acquire-$id.pending"
  out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  expect_code 1 "$rc" "ambiguous endpoint maintenance"
  assert_contains "$out" "endpoint creation phase is ambiguous" "ambiguous endpoint diagnostic"
  [ -f "$record" ] || fail "ambiguous endpoint phase removed acquisition authority"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "ambiguous endpoint phase invented cleanup metadata"
  [ ! -s "$FM_FAKE_TEARDOWN_LOG" ] || fail "ambiguous endpoint phase invoked teardown"
  rm -f "$record"
  pass "an interrupted endpoint creation remains fail-closed for exact reconciliation"
}

test_created_herdr_endpoint_identity_is_preserved_for_teardown() {
  local fixture project worktree record tmp out rc id=created-herdr
  reset_logs
  fixture=$(make_treehouse_fixture "$id")
  project=${fixture%%$'\t'*}
  worktree=${fixture#*$'\t'}
  write_dead_acquisition "$id" "$project" "$worktree" direct created herdr
  record="$HOME_DIR/state/.worktree-acquire-$id.pending"
  tmp=$(mktemp "$HOME_DIR/state/.created-herdr.XXXXXX")
  awk '!/^(window|herdr_session|herdr_workspace_id|herdr_tab_id|herdr_pane_id)=/' "$record" > "$tmp"
  printf '%s\n' \
    'window=lab-session:pane-41' \
    'herdr_session=lab-session' \
    'herdr_workspace_id=workspace-41' \
    'herdr_tab_id=tab-41' \
    'herdr_pane_id=pane-41' >> "$tmp"
  mv "$tmp" "$record"
  touch -t 202001010000 "$record"
  FM_FAKE_TEARDOWN_ASSERT_HERDR=1
  export FM_FAKE_TEARDOWN_ASSERT_HERDR
  out=$(FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  expect_code 0 "$rc" "created Herdr endpoint recovery"
  assert_contains "$out" "auto-reaped $id" "created Herdr endpoint was not delegated to teardown"
  [ ! -e "$record" ] || fail "created Herdr endpoint record survived successful teardown"
  assert_contains "$(cat "$FM_FAKE_TEARDOWN_LOG")" "$id" "created Herdr endpoint did not invoke teardown"
  pass "a post-launch crash retains exact Herdr endpoint identity for quiescence"
}

test_pre_tasktmp_crash_reaps_with_real_teardown() {
  local fixture project worktree record out rc id=pre-tasktmp realbin treehouse_state treehouse_log
  reset_logs
  fixture=$(make_treehouse_fixture "$id")
  project=${fixture%%$'\t'*}
  worktree=${fixture#*$'\t'}
  write_dead_acquisition "$id" "$project" "$worktree" direct not-created tmux not-created
  record="$HOME_DIR/state/.worktree-acquire-$id.pending"
  realbin="$TMP/pre-tasktmp-bin"
  treehouse_state="$(dirname "$(dirname "$worktree")")/treehouse-state.json"
  treehouse_log="$TMP/pre-tasktmp-treehouse.log"
  mkdir -p "$realbin"
  ln "$ROOT/tests/fixtures/treehouse-return-fixture.sh" "$realbin/treehouse"
  unset FM_AUTO_REAP_TEARDOWN_BIN
  out=$(PATH="$realbin:$PATH" \
    FM_AUTO_REAP_E2E_WORKTREE="$worktree" \
    FM_AUTO_REAP_E2E_PROJECT="$project" \
    FM_AUTO_REAP_E2E_TREEHOUSE_STATE="$treehouse_state" \
    FM_AUTO_REAP_E2E_TREEHOUSE_LOG="$treehouse_log" \
    FM_AUTO_REAP_STALE_SECS=1 "$AUTO_REAP" maintenance 2>&1); rc=$?
  export FM_AUTO_REAP_TEARDOWN_BIN="$FAKEBIN/fm-teardown.sh"
  expect_code 0 "$rc" "pre-tasktmp real teardown recovery"
  assert_contains "$out" "auto-reaped $id" "pre-tasktmp crash did not complete real teardown"
  [ ! -e "$record" ] || fail "pre-tasktmp acquisition record became a permanent zombie"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "pre-tasktmp recovery retained synthetic metadata"
  [ ! -e "$worktree" ] || fail "pre-tasktmp recovery retained the returned worktree"
  assert_contains "$(cat "$treehouse_log")" "returned $worktree" "pre-tasktmp recovery did not return the exact lease"
  pass "a pre-tasktmp crash completes ordinary teardown without synthetic owner state"
}

test_watcher_routes_merge_checks_and_scout_done_events_to_auto_reap() {
  local fake_root watch_home state calls out check pid i
  fake_root="$TMP/watch-root"
  watch_home="$TMP/watch-home"
  state="$watch_home/state"
  calls="$TMP/watch-auto-reap.calls"
  out="$TMP/watch.out"
  mkdir -p "$fake_root/bin" "$state"
  cat > "$fake_root/bin/fm-auto-reap.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_AUTO_REAP_CALLS"
case "$*" in
  maintenance) ;;
  *) printf 'auto-reaped by watcher: %s\n' "$*" ;;
esac
SH
  cat > "$fake_root/bin/fm-account-session-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fake_root/bin/fm-report-stack.mjs" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/"*
  check="$state/merged-watch.check.sh"
  printf '#!/usr/bin/env bash\nprintf "merged\\n"\n' > "$check"
  chmod +x "$check"
  fm_write_meta "$state/merged-watch.meta" "kind=ship"
  printf 'done: checks green\n' > "$state/merged-watch.status"
  FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$watch_home" FM_STATE_OVERRIDE="$state" \
    FM_FAKE_AUTO_REAP_CALLS="$calls" FM_CHECK_INTERVAL=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 "$WATCH" > "$out"
  assert_contains "$(cat "$calls")" "maintenance" "watcher maintenance route"
  assert_contains "$(cat "$calls")" "task merged-watch pr-merged" "watcher merged route"
  assert_contains "$(cat "$out")" "auto-reaped by watcher" "watcher merge wake result"

  : > "$calls"
  rm -f "$state/merged-watch.check.sh" "$state/merged-watch.meta" "$state/merged-watch.status" \
    "$state/.watch.lock" "$state/.last-watcher-beat"
  rm -rf "$state/.watch.lock"
  touch "$state/.last-check" "$state/.last-heartbeat" "$state/.last-report-retention" \
    "$state/.last-account-session-sync"
  fm_write_meta "$state/scout-watch.meta" "kind=scout"
  printf 'done: report written\n' > "$state/scout-watch.status"
  FM_ROOT_OVERRIDE="$fake_root" FM_HOME="$watch_home" FM_STATE_OVERRIDE="$state" \
    FM_FAKE_AUTO_REAP_CALLS="$calls" FM_CHECK_INTERVAL=999999 FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "watcher did not route scout done signal"
  fi
  wait "$pid" 2>/dev/null || true
  assert_contains "$(cat "$calls")" "task scout-watch scout-done" "watcher scout route"
  assert_contains "$(cat "$out")" "auto-reaped by watcher" "watcher scout wake result"
  pass "watcher continuously routes merged checks and scout terminal signals to auto-reap"
}

test_local_merge_immediately_auto_reaps() {
  local project worktree id out rc
  reset_logs
  id=local-merge-reap
  project="$TMP/local-project"
  worktree="$TMP/local-worktree"
  fm_git_init_commit "$project"
  git -C "$project" branch -M main
  git -C "$project" worktree add -qb "fm/$id" "$worktree"
  printf 'landed\n' > "$worktree/change.txt"
  git -C "$worktree" add change.txt
  git -C "$worktree" commit -qm change
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=fm:$id" "worktree=$worktree" "project=$project" \
    "kind=ship" "mode=local-only"
  printf 'done: ready in branch\n' > "$HOME_DIR/state/$id.status"
  out=$("$MERGE_LOCAL" "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "local merge plus auto-reap"
  assert_contains "$out" "auto-reaped $id" "local merge auto-reap output"
  assert_contains "$(cat "$FM_FAKE_TEARDOWN_LOG")" "$id" "local merge invoked teardown"
  [ "$(git -C "$project" rev-parse main)" = "$(git -C "$worktree" rev-parse HEAD)" ] \
    || fail "local merge did not fast-forward main"
  pass "approved local merge immediately invokes automatic teardown"
}

test_merged_task_cancels_exact_run_then_tears_down
test_open_pr_refuses_without_teardown
test_cross_branch_active_run_refuses_without_guessing_id
test_x_link_and_teardown_refusal_remain_visible
test_dead_acquisition_recovers_but_live_owner_is_untouched
test_dirty_stranded_worktree_is_retained_by_real_teardown
test_unregistered_treehouse_lease_retains_acquisition_authority
test_malformed_treehouse_leases_retain_acquisition_authority
test_destroying_treehouse_entry_retains_acquisition_authority
test_ambiguous_endpoint_phase_retains_acquisition_authority
test_created_herdr_endpoint_identity_is_preserved_for_teardown
test_pre_tasktmp_crash_reaps_with_real_teardown
test_watcher_routes_merge_checks_and_scout_done_events_to_auto_reap
test_local_merge_immediately_auto_reaps

printf 'all fm-auto-reap tests passed\n'
