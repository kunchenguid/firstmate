#!/usr/bin/env bash
# Regression tests for bin/fm-herdr-legacy-repair.sh, the guarded bind-only
# repair path for legacy Herdr records that predate endpoint_task_id=.
# Covers: a modern bound record left untouched; a fully provable synthetic
# legacy landed task repaired exactly once; idempotent rerun; every
# task/worktree/project/session/workspace/tab/pane mismatch; dirty and
# unlanded work; active and nonterminal agents; missing and ambiguous fields;
# unrelated-record and default-session preservation; and refusal before any
# lifecycle mutation (the script must never issue a mutating Herdr command).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPAIR="$ROOT/bin/fm-herdr-legacy-repair.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-legacy-repair)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

SESSION=fm-lab-repair-test
WSID=wG
TABID=wG:t38
PANEID=wG:p38

# One fake herdr for every case: canned JSON per subcommand through env vars,
# and a complete argv log so tests can prove exactly which calls ran.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_HERDR_LOG:?}"
default='{"error":{"code":"unexpected"}}'
case "$1 $2" in
  "pane get") printf '%s\n' "${FAKE_PANE_GET:-$default}" ;;
  "agent get") printf '%s\n' "${FAKE_AGENT_GET:-$default}" ;;
  "tab list") printf '%s\n' "${FAKE_TAB_LIST:-$default}" ;;
  *) printf '%s\n' "$default" ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

# make_case <name>: a fresh home plus a real origin/project/worktree git triad
# whose worktree sits clean on the landed default branch. Echoes the case dir.
make_case() {  # <name>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state"
  : > "$dir/herdr.log"
  git init -q --bare "$dir/origin.git"
  git clone -q "$dir/origin.git" "$dir/project" 2>/dev/null
  (
    cd "$dir/project" || exit 1
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    git push -q origin HEAD:main
    if ! git checkout -q main 2>/dev/null; then
      git checkout -q -b main
    fi
  ) 2>/dev/null
  git clone -q "$dir/origin.git" "$dir/worktree" 2>/dev/null
  ( cd "$dir/worktree" && git checkout -q main ) 2>/dev/null
  printf '%s\n' "$dir"
}

# write_legacy_meta <case-dir> <task-id> [extra-lines...]: the pre-hardening
# record shape - full Herdr endpoint fields, no endpoint_task_id=.
write_legacy_meta() {
  local dir=$1 id=$2
  shift 2
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=$SESSION:$PANEID" \
    "worktree=$dir/worktree" \
    "project=$dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "backend=herdr" \
    "herdr_session=$SESSION" \
    "herdr_workspace_id=$WSID" \
    "herdr_tab_id=$TABID" \
    "herdr_pane_id=$PANEID" \
    "$@"
}

run_repair() {  # <case-dir> <task-id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FAKE_HERDR_LOG="$dir/herdr.log" \
    PATH="$FAKEBIN:$PATH" \
    "$REPAIR" "$id" > "$dir/stdout" 2> "$dir/stderr"
}

assert_no_lifecycle_mutation() {  # <case-dir> <description>
  local dir=$1 description=$2
  ! grep -qE '(^| )(close|stop|delete|kill|create|run|send|move)( |$)' "$dir/herdr.log" \
    || fail "$description: a mutating Herdr command ran: $(cat "$dir/herdr.log")"
}

assert_refused_unchanged() {  # <case-dir> <task-id> <needle> <description>
  local dir=$1 id=$2 needle=$3 description=$4 rc=0
  cp "$dir/home/state/$id.meta" "$dir/meta.before"
  run_repair "$dir" "$id" || rc=$?
  [ "$rc" -ne 0 ] || fail "$description: repair unexpectedly succeeded"
  cmp -s "$dir/meta.before" "$dir/home/state/$id.meta" \
    || fail "$description: refusal changed the task metadata"
  assert_grep "$needle" "$dir/stderr" "$description: missing concrete diagnostic"
  assert_no_lifecycle_mutation "$dir" "$description"
}

test_help_and_missing_state_preserve_home() {
  local dir="$TMP_ROOT/no-state" rc=0
  mkdir -p "$dir/home"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$REPAIR" --help > "$dir/help.out" 2> "$dir/help.err" || rc=$?
  expect_code 0 "$rc" "help should succeed"
  assert_grep "Usage: fm-herdr-legacy-repair.sh <task-id>" "$dir/help.out" \
    "help should expose usage"
  assert_grep "Independent evidence" "$dir/help.out" \
    "help should expose evidence mechanics"
  assert_grep "atomic" "$dir/help.out" \
    "help should expose mutation and locking mechanics"
  [ ! -e "$dir/home/state" ] || fail "help created a state directory"

  rc=0
  run_repair "$dir" ghost-task || rc=$?
  [ "$rc" -ne 0 ] || fail "missing state should refuse"
  assert_grep "state directory" "$dir/stderr" "missing state diagnostic"
  [ ! -e "$dir/home/state" ] || fail "missing-state refusal created durable state"
  pass "help exposes mechanics and preflight refusals preserve a missing state directory"
}

pane_present_json() {  # <tab-id> <foreground-cwd>
  printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","foreground_cwd":"%s"}}}' \
    "$PANEID" "$1" "$2"
}

test_modern_bound_record_untouched() {
  local dir rc=0
  dir=$(make_case modern-bound)
  write_legacy_meta "$dir" bound-task "endpoint_task_id=bound-task"
  cp "$dir/home/state/bound-task.meta" "$dir/meta.before"
  run_repair "$dir" bound-task || rc=$?
  expect_code 0 "$rc" "modern bound record should be an idempotent no-op"
  assert_grep "already-bound" "$dir/stdout" "modern bound record should report already-bound"
  cmp -s "$dir/meta.before" "$dir/home/state/bound-task.meta" \
    || fail "modern bound record was modified"
  [ ! -s "$dir/herdr.log" ] || fail "modern bound record triggered Herdr calls: $(cat "$dir/herdr.log")"
  pass "a proven modern bound record is untouched and reports already-bound"
}

test_legacy_landed_gone_pane_repaired_once_and_idempotent() {
  local dir rc=0
  dir=$(make_case legacy-gone)
  write_legacy_meta "$dir" legacy-gone
  cp "$dir/home/state/legacy-gone.meta" "$dir/meta.before"
  FAKE_PANE_GET='{"error":{"code":"pane_not_found"}}' run_repair "$dir" legacy-gone || rc=$?
  expect_code 0 "$rc" "provable legacy landed task with a gone pane should repair"
  assert_grep "repaired" "$dir/stdout" "repair outcome not reported"
  [ "$(grep -c '^endpoint_task_id=' "$dir/home/state/legacy-gone.meta")" -eq 1 ] \
    || fail "repair did not add exactly one binding"
  [ "$(grep '^endpoint_task_id=' "$dir/home/state/legacy-gone.meta")" = "endpoint_task_id=legacy-gone" ] \
    || fail "repair bound the wrong task id"
  cmp -s <(grep -v '^endpoint_task_id=' "$dir/home/state/legacy-gone.meta") "$dir/meta.before" \
    || fail "repair changed more than the single binding line"
  assert_no_lifecycle_mutation "$dir" "successful repair"

  cp "$dir/home/state/legacy-gone.meta" "$dir/meta.repaired"
  : > "$dir/herdr.log"
  rc=0
  FAKE_PANE_GET='{"error":{"code":"pane_not_found"}}' run_repair "$dir" legacy-gone || rc=$?
  expect_code 0 "$rc" "idempotent rerun should succeed"
  assert_grep "already-bound" "$dir/stdout" "rerun should report already-bound"
  cmp -s "$dir/meta.repaired" "$dir/home/state/legacy-gone.meta" \
    || fail "idempotent rerun changed the repaired record"
  [ ! -s "$dir/herdr.log" ] || fail "idempotent rerun triggered Herdr calls"
  pass "a fully provable legacy landed task repairs exactly once and reruns as a no-op"
}

test_legacy_landed_idle_agent_and_husk_repair() {
  local dir rc=0
  dir=$(make_case legacy-idle)
  write_legacy_meta "$dir" legacy-idle
  rc=0
  FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/worktree") \
    FAKE_AGENT_GET='{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}' \
    FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-legacy-idle\"}]}}" \
    run_repair "$dir" legacy-idle || rc=$?
  expect_code 0 "$rc" "finished idle agent with exact topology should repair"
  assert_no_lifecycle_mutation "$dir" "idle-agent repair"
  grep -qE '^pane get ' "$dir/herdr.log" || fail "idle-agent repair read no live pane evidence"

  dir=$(make_case legacy-husk)
  write_legacy_meta "$dir" legacy-husk
  rc=0
  FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/project") \
    FAKE_AGENT_GET='{"error":{"code":"agent_not_found"}}' \
    FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-legacy-husk\"}]}}" \
    run_repair "$dir" legacy-husk || rc=$?
  expect_code 0 "$rc" "restored husk shell at the creation cwd should repair"
  pass "a live finished agent and a restored husk both repair with exact topology"
}

test_active_and_nonterminal_agents_refuse() {
  local dir status
  for status in working blocked; do
    dir=$(make_case "agent-$status")
    write_legacy_meta "$dir" active-task
    FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/worktree") \
      FAKE_AGENT_GET="{\"result\":{\"agent\":{\"agent\":\"claude\",\"agent_status\":\"$status\"}}}" \
      FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-active-task\"}]}}" \
      assert_refused_unchanged "$dir" active-task "$status" "$status agent"
  done
  dir=$(make_case agent-unreadable)
  write_legacy_meta "$dir" active-task
  FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/worktree") \
    FAKE_AGENT_GET='not json at all' \
    FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-active-task\"}]}}" \
    assert_refused_unchanged "$dir" active-task "agent state" "unreadable agent"

  dir=$(make_case agent-missing-identity)
  write_legacy_meta "$dir" missing-agent-task
  FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/worktree") \
    FAKE_AGENT_GET='{"result":{"agent":{"agent_status":"idle"}}}' \
    FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-missing-agent-task\"}]}}" \
    assert_refused_unchanged "$dir" missing-agent-task "agent identity is unreadable" \
      "missing agent identity"
  pass "working, blocked, and malformed agents refuse and preserve everything"
}

test_dirty_and_unlanded_work_refuse() {
  local dir
  dir=$(make_case dirty)
  write_legacy_meta "$dir" dirty-task
  echo scratch > "$dir/worktree/scratch.txt"
  assert_refused_unchanged "$dir" dirty-task "uncommitted changes" "dirty worktree"
  [ ! -s "$dir/herdr.log" ] || fail "dirty refusal still contacted Herdr"

  dir=$(make_case unlanded)
  write_legacy_meta "$dir" unlanded-task
  ( cd "$dir/worktree" && git checkout -qb fm/unlanded \
    && echo work > w.txt && git add w.txt \
    && git -c user.email=t@t -c user.name=t commit -qm work )
  assert_refused_unchanged "$dir" unlanded-task "not proven landed" "unlanded work"
  [ ! -s "$dir/herdr.log" ] || fail "unlanded refusal still contacted Herdr"
  pass "dirty and unlanded worktrees refuse before any Herdr call"
}

test_squash_landed_content_repairs() {
  local dir rc=0
  dir=$(make_case squash-landed)
  write_legacy_meta "$dir" squash-task
  ( cd "$dir/worktree" && git checkout -qb fm/squash \
    && echo squash-content > sq.txt && git add sq.txt \
    && git -c user.email=t@t -c user.name=t commit -qm "feat: sq" )
  ( cd "$dir/project" && git pull -q origin main \
    && echo squash-content > sq.txt && git add sq.txt \
    && git -c user.email=t@t -c user.name=t commit -qm "feat: sq (squash)" \
    && git push -q origin main )
  FAKE_PANE_GET='{"error":{"code":"pane_not_found"}}' run_repair "$dir" squash-task || rc=$?
  expect_code 0 "$rc" "squash-landed branch content should prove landed via the shared predicates"
  pass "squash-merged content proves landed through the shared landed-work owner"
}

test_missing_and_ambiguous_fields_refuse() {
  local dir
  dir=$(make_case missing-pane-field)
  fm_write_meta "$dir/home/state/broken-task.meta" \
    "window=$SESSION:$PANEID" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=ship" \
    "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WSID" \
    "herdr_tab_id=$TABID"
  assert_refused_unchanged "$dir" broken-task "malformed or inconsistent" "missing herdr_pane_id"

  dir=$(make_case window-mismatch)
  write_legacy_meta "$dir" window-task
  fm_write_meta "$dir/home/state/window-task.meta" \
    "window=other-session:$PANEID" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=ship" \
    "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WSID" \
    "herdr_tab_id=$TABID" "herdr_pane_id=$PANEID"
  assert_refused_unchanged "$dir" window-task "malformed or inconsistent" "window/session mismatch"

  dir=$(make_case duplicate-binding)
  write_legacy_meta "$dir" dup-task "endpoint_task_id=dup-task" "endpoint_task_id=dup-task"
  assert_refused_unchanged "$dir" dup-task "endpoint task bindings" "duplicate binding"

  dir=$(make_case empty-binding)
  write_legacy_meta "$dir" empty-task "endpoint_task_id="
  assert_refused_unchanged "$dir" empty-task "empty endpoint task binding" "empty binding"

  dir=$(make_case foreign-binding)
  write_legacy_meta "$dir" mine-task "endpoint_task_id=other-task"
  assert_refused_unchanged "$dir" mine-task "belongs to task other-task" "foreign binding"

  dir=$(make_case duplicate-backend)
  write_legacy_meta "$dir" dupback-task "backend=herdr"
  assert_refused_unchanged "$dir" dupback-task "backend= records" "duplicate backend"

  dir=$(make_case duplicate-kind)
  fm_write_meta "$dir/home/state/dupkind-task.meta" \
    "window=$SESSION:$PANEID" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=secondmate" "kind=ship" \
    "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WSID" \
    "herdr_tab_id=$TABID" "herdr_pane_id=$PANEID"
  assert_refused_unchanged "$dir" dupkind-task "kind= records" "duplicate kind"

  dir=$(make_case duplicate-pr)
  write_legacy_meta "$dir" duppr-task \
    "pr=https://github.com/example/project/pull/1" \
    "pr=https://github.com/example/project/pull/2"
  FAKE_PANE_GET='{"error":{"code":"pane_not_found"}}' \
    assert_refused_unchanged "$dir" duppr-task "pr= records" "duplicate PR"

  dir=$(make_case no-meta)
  local rc=0
  run_repair "$dir" ghost-task || rc=$?
  [ "$rc" -ne 0 ] || fail "missing metadata should refuse"
  assert_grep "no metadata" "$dir/stderr" "missing metadata diagnostic"
  pass "missing, duplicate, empty, foreign, and ambiguous fields all refuse unchanged"
}

test_scope_refusals() {
  local dir
  dir=$(make_case tmux-record)
  fm_write_meta "$dir/home/state/tmux-task.meta" \
    "window=iso:fm-tmux-task" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=ship" "backend=tmux" "endpoint_task_id=tmux-task"
  assert_refused_unchanged "$dir" tmux-task "covers only Herdr records" "tmux record"

  dir=$(make_case zellij-record)
  fm_write_meta "$dir/home/state/z-task.meta" \
    "window=zses:1" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=ship" "backend=zellij"
  assert_refused_unchanged "$dir" z-task "covers only Herdr records" "zellij record"

  dir=$(make_case secondmate-kind)
  fm_write_meta "$dir/home/state/sm-task.meta" \
    "window=$SESSION:$PANEID" "worktree=$dir/worktree" "project=$dir/project" \
    "kind=secondmate" \
    "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WSID" \
    "herdr_tab_id=$TABID" "herdr_pane_id=$PANEID"
  assert_refused_unchanged "$dir" sm-task "never touches secondmates" "secondmate record"

  dir=$(make_case remote-route)
  write_legacy_meta "$dir" remote-task "remote_host=host.example"
  assert_refused_unchanged "$dir" remote-task "remote route" "remote record"

  dir=$(make_case secondmate-home)
  write_legacy_meta "$dir" home-task
  printf 'sm\n' > "$dir/home/.fm-secondmate-home"
  assert_refused_unchanged "$dir" home-task "secondmate home" "secondmate home"

  dir=$(make_case dangling-secondmate-home)
  write_legacy_meta "$dir" dangling-home-task
  ln -s "$dir/missing-secondmate-marker-target" "$dir/home/.fm-secondmate-home"
  assert_refused_unchanged "$dir" dangling-home-task "secondmate home" \
    "dangling secondmate home marker"
  pass "tmux, other opaque backends, secondmates, and remote routes refuse by name"
}

test_worktree_project_mismatches_refuse() {
  local dir
  dir=$(make_case missing-worktree)
  write_legacy_meta "$dir" mw-task
  rm -rf "$dir/worktree"
  assert_refused_unchanged "$dir" mw-task "does not exist" "missing worktree"

  dir=$(make_case foreign-origin)
  git init -q --bare "$dir/other-origin.git"
  rm -rf "$dir/worktree"
  git clone -q "$dir/other-origin.git" "$dir/worktree" 2>/dev/null
  ( cd "$dir/worktree" \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
    && git push -q origin HEAD:main && git checkout -q main ) 2>/dev/null
  write_legacy_meta "$dir" fo-task
  assert_refused_unchanged "$dir" fo-task "does not match the recorded project" "foreign-origin worktree"

  dir=$(make_case worktree-is-project)
  write_legacy_meta "$dir" wp-task
  fm_write_meta "$dir/home/state/wp-task.meta" \
    "window=$SESSION:$PANEID" "worktree=$dir/project" "project=$dir/project" \
    "kind=ship" \
    "backend=herdr" "herdr_session=$SESSION" "herdr_workspace_id=$WSID" \
    "herdr_tab_id=$TABID" "herdr_pane_id=$PANEID"
  assert_refused_unchanged "$dir" wp-task "isolated copy" "worktree equals project"
  pass "missing, foreign, and non-isolated worktrees refuse unchanged"
}

test_live_topology_mismatches_refuse() {
  local dir
  dir=$(make_case live-pane-mismatch)
  write_legacy_meta "$dir" pm-task
  FAKE_PANE_GET="{\"result\":{\"pane\":{\"pane_id\":\"wG:p99\",\"tab_id\":\"$TABID\",\"foreground_cwd\":\"$dir/worktree\"}}}" \
    FAKE_AGENT_GET='{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}' \
    FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-pm-task\"}]}}" \
    assert_refused_unchanged "$dir" pm-task "unreadable or the session is unreachable" \
      "live pane mismatch"

  dir=$(make_case live-tab-mismatch)
  write_legacy_meta "$dir" tm-task
  FAKE_PANE_GET=$(pane_present_json "wG:t99" "$dir/worktree") \
    assert_refused_unchanged "$dir" tm-task "not the recorded tab" "live tab mismatch"

  dir=$(make_case tab-not-in-workspace)
  write_legacy_meta "$dir" tw-task
  FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/worktree") \
    FAKE_TAB_LIST='{"result":{"tabs":[]}}' \
    assert_refused_unchanged "$dir" tw-task "missing from workspace" "tab not in recorded workspace"

  dir=$(make_case wrong-label)
  write_legacy_meta "$dir" wl-task
  FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/worktree") \
    FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-other-task\"}]}}" \
    assert_refused_unchanged "$dir" wl-task "not labeled" "wrong tab label"

  dir=$(make_case cwd-mismatch)
  write_legacy_meta "$dir" cw-task
  mkdir -p "$dir/elsewhere"
  FAKE_PANE_GET=$(pane_present_json "$TABID" "$dir/elsewhere") \
    FAKE_AGENT_GET='{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}' \
    FAKE_TAB_LIST="{\"result\":{\"tabs\":[{\"tab_id\":\"$TABID\",\"label\":\"fm-cw-task\"}]}}" \
    assert_refused_unchanged "$dir" cw-task "not the recorded worktree" "foreground cwd mismatch"

  dir=$(make_case unreadable-endpoint)
  write_legacy_meta "$dir" ue-task
  FAKE_PANE_GET='total garbage' \
    assert_refused_unchanged "$dir" ue-task "unreadable or the session is unreachable" "unreadable endpoint"
  pass "every live session/workspace/tab/pane/cwd mismatch refuses unchanged"
}

test_unrelated_records_and_default_session_preserved() {
  local dir rc=0
  dir=$(make_case unrelated-preserved)
  write_legacy_meta "$dir" target-task
  # An unrelated modern task on the captain's default session, plus a foreign
  # status record: a successful repair of target-task must not touch either,
  # and must never address any session but the recorded one.
  fm_write_meta "$dir/home/state/other-task.meta" \
    "window=default:wA:p1" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=default" "herdr_workspace_id=wA" \
    "herdr_tab_id=wA:t1" "herdr_pane_id=wA:p1" "endpoint_task_id=other-task"
  printf 'working: unrelated\n' > "$dir/home/state/other-task.status"
  cp "$dir/home/state/other-task.meta" "$dir/other.before"
  FAKE_PANE_GET='{"error":{"code":"pane_not_found"}}' run_repair "$dir" target-task || rc=$?
  expect_code 0 "$rc" "repair beside unrelated records should succeed"
  cmp -s "$dir/other.before" "$dir/home/state/other-task.meta" \
    || fail "repair modified an unrelated task's metadata"
  [ "$(cat "$dir/home/state/other-task.status")" = "working: unrelated" ] \
    || fail "repair modified an unrelated task's status record"
  ! grep -q 'session default' "$dir/herdr.log" \
    || fail "repair addressed the default session: $(cat "$dir/herdr.log")"
  grep -qE -- "--session $SESSION" "$dir/herdr.log" \
    || fail "repair did not scope its Herdr reads to the recorded session"
  pass "unrelated records and the default session are preserved by a successful repair"
}

test_refusal_precedes_lifecycle_and_teardown_accepts_repaired_record() {
  local dir rc=0
  dir=$(make_case teardown-after-repair)
  write_legacy_meta "$dir" e2e-task
  # Before repair: ordinary teardown must refuse the unbound legacy record.
  rc=0
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
    PATH="$FAKEBIN:$PATH" FAKE_HERDR_LOG="$dir/herdr.log" \
    "$ROOT/bin/fm-teardown.sh" e2e-task > "$dir/td.out" 2> "$dir/td.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown accepted an unbound legacy Herdr record"
  assert_grep "lacks an exact task binding" "$dir/td.err" \
    "teardown's legacy refusal changed shape; update the repair contract"
  # After repair: the same record passes teardown's first authorization check
  # (it then proceeds into teardown's own later safety machinery).
  rc=0
  FAKE_PANE_GET='{"error":{"code":"pane_not_found"}}' run_repair "$dir" e2e-task || rc=$?
  expect_code 0 "$rc" "repair of the teardown case failed"
  rc=0
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
    PATH="$FAKEBIN:$PATH" FAKE_HERDR_LOG="$dir/herdr.log" \
    FAKE_PANE_GET='{"error":{"code":"pane_not_found"}}' \
    "$ROOT/bin/fm-teardown.sh" e2e-task > "$dir/td2.out" 2> "$dir/td2.err" || rc=$?
  assert_no_grep "lacks an exact task binding" "$dir/td2.err" \
    "teardown still refuses the repaired record's binding"
  pass "teardown refuses the legacy record before repair and accepts its binding after"
}

test_lock_contention_refuses() {
  local dir rc=0 holder lock i=0
  dir=$(make_case lock-contention)
  write_legacy_meta "$dir" locked-task
  lock="$dir/home/state/.control-locked-task.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null || true; fail "could not stage a held control lock"; }
  cp "$dir/home/state/locked-task.meta" "$dir/meta.before"
  run_repair "$dir" locked-task || rc=$?
  [ "$rc" -ne 0 ] || fail "repair ran under a held lifecycle lock"
  assert_grep "another lifecycle action" "$dir/stderr" "lock contention diagnostic"
  cmp -s "$dir/meta.before" "$dir/home/state/locked-task.meta" \
    || fail "lock-contended repair changed the metadata"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "a concurrent lifecycle action refuses the repair before any change"
}

test_help_and_missing_state_preserve_home
test_modern_bound_record_untouched
test_legacy_landed_gone_pane_repaired_once_and_idempotent
test_legacy_landed_idle_agent_and_husk_repair
test_active_and_nonterminal_agents_refuse
test_dirty_and_unlanded_work_refuse
test_squash_landed_content_repairs
test_missing_and_ambiguous_fields_refuse
test_scope_refusals
test_worktree_project_mismatches_refuse
test_live_topology_mismatches_refuse
test_unrelated_records_and_default_session_preserved
test_refusal_precedes_lifecycle_and_teardown_accepts_repaired_record
test_lock_contention_refuses

printf 'all fm-herdr-legacy-repair tests passed\n'
