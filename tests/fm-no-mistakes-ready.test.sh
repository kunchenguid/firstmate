#!/usr/bin/env bash
# Behavior tests for the Firstmate no-mistakes readiness and Herdr attach
# reconciliation public interface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-ready)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

HELPER="$ROOT/bin/fm-no-mistakes-ready.sh"

fail_with_output() {
  local message=$1 output=$2
  printf 'FAIL: %s\n%s\n' "$message" "$output" >&2
  exit 1
}

assert_contains_text() {
  local haystack=$1 needle=$2 message=$3
  case "$haystack" in
    *"$needle"*) ;;
    *) fail_with_output "$message" "$haystack" ;;
  esac
}

new_repo() { # <dir> <task-id>
  local dir=$1 id=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.name test
  git -C "$dir" config user.email test@example.com
  printf 'base\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm base
  git -C "$dir" checkout -qb "fm/$id"
}

write_meta() { # <state> <task-id> <worktree> <backend>
  local state=$1 id=$2 worktree=$3 backend=$4
  mkdir -p "$state"
  if [ "$backend" = herdr ]; then
    cat > "$state/$id.meta" <<EOF
window=test:w1:p1
endpoint_task_id=$id
worktree=$worktree
project=$worktree
harness=codex
kind=ship
mode=no-mistakes
backend=herdr
herdr_session=test
herdr_workspace_id=w1
herdr_tab_id=w1:t1
herdr_pane_id=w1:p1
EOF
  elif [ "$backend" = zellij ]; then
    cat > "$state/$id.meta" <<EOF
window=test:7
endpoint_task_id=$id
worktree=$worktree
project=$worktree
harness=codex
kind=ship
mode=no-mistakes
backend=zellij
zellij_session=test
zellij_tab_id=3
zellij_pane_id=7
EOF
  elif [ "$backend" = orca ]; then
    cat > "$state/$id.meta" <<EOF
window=fm-$id
endpoint_task_id=$id
terminal=term-7
worktree=$worktree
project=$worktree
harness=codex
kind=ship
mode=no-mistakes
backend=orca
orca_worktree_id=worktree-9
EOF
  elif [ "$backend" = cmux ]; then
    cat > "$state/$id.meta" <<EOF
window=workspace-1:surface-2
endpoint_task_id=$id
worktree=$worktree
project=$worktree
harness=codex
kind=ship
mode=no-mistakes
backend=cmux
cmux_workspace_id=workspace-1
cmux_surface_id=surface-2
EOF
  else
    cat > "$state/$id.meta" <<EOF
window=test:fm-$id
endpoint_task_id=$id
worktree=$worktree
project=$worktree
harness=codex
kind=ship
mode=no-mistakes
backend=tmux
EOF
  fi
}

write_ready_record() { # <record> <head> <spec-verdict>
  local record=$1 head=$2 spec=$3 spec_evidence
  if [ "$spec" = pass ]; then
    spec_evidence="fixture Spec Kit checklist, clarification, analysis, convergence, and task reconciliation passed"
  else
    spec_evidence="not applicable because fixture Spec Kit markers were inspected and absent"
  fi
  cat > "$record" <<EOF
version	1	Firstmate readiness version
head	$head	Exact committed implementation
intent_trace	pass	accepted behavior maps to file.txt and focused evidence
self_audit	pass	git diff was inspected for omissions and stray scope
project_analysis	not-applicable	not applicable because this fixture has no project-native analyzer
spec_kit	$spec	$spec_evidence
focused_tests	pass	fixture focused test passed with exit zero
full_checks	pass	fixture relevant full check passed with exit zero
implementation_complete	pass	no accepted fixture behavior remains incomplete
decisions	clear	no unresolved fixture decision remains
design_grounding	not-applicable	not applicable because this fixture has no user-visible design surface
runtime_grounding	not-applicable	not applicable because this fixture has no runtime behavior
maestro	not-applicable	not applicable because this fixture is not NSM emulator behavior
EOF
}

test_help() {
  local output
  output=$("$HELPER" --help)
  assert_contains_text "$output" 'monitor-reconcile <task-id>' "help omitted monitor reconciliation"
  assert_contains_text "$output" 'monitor-clear-attempt <task-id> <attempt-token>' "help omitted attempt recovery"
  # shellcheck disable=SC2016 # Literal Markdown code spans are the expected help text.
  assert_contains_text "$output" 'prints `READY`, `NOT_READY`, or `ERROR`' "help omitted readiness outcomes"
  pass "fm-no-mistakes-ready: help renders the full mechanics header"
}

test_readiness_outcomes() {
  local home state data worktree id output status record head
  home="$TMP_ROOT/readiness-home"
  state="$home/state"
  data="$home/data"
  worktree="$TMP_ROOT/readiness-worktree"
  id=ready-task
  new_repo "$worktree" "$id"
  write_meta "$state" "$id" "$worktree" tmux

  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" init "$id") || \
    fail_with_output "init failed" "$output"
  record="$data/$id/no-mistakes-readiness.tsv"
  [ -f "$record" ] || fail "init did not create the durable readiness record"
  set +e
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" check "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail_with_output "pending readiness did not exit 1" "$output"
  assert_contains_text "$output" 'NOT_READY:' "pending readiness did not report NOT_READY"

  head=$(git -C "$worktree" rev-parse HEAD)
  write_ready_record "$record" "$head" not-applicable
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" check "$id") || \
    fail_with_output "complete readiness record did not pass" "$output"
  assert_contains_text "$output" "READY: task $id at $head" "ready result did not bind the exact commit"

  sed -i $'s#intent_trace\tpass\t.*#intent_trace\tpass\tdone#' "$record"
  set +e
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" check "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail_with_output "bare assertion passed evidence validation" "$output"
  assert_contains_text "$output" 'intent_trace evidence must name a concrete' "vague evidence rejection was not explicit"
  write_ready_record "$record" "$head" not-applicable

  sed -i $'s#runtime_grounding\tnot-applicable\t.*#runtime_grounding\tnot-applicable\tnot applicable#' "$record"
  set +e
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" check "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail_with_output "bare non-applicability claim passed evidence validation" "$output"
  assert_contains_text "$output" 'runtime_grounding evidence must name a concrete' "bare non-applicability rejection was not explicit"
  write_ready_record "$record" "$head" not-applicable

  set +e
  output=$(GIT_INDEX_FILE=/dev/null FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" check "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 2 ] || fail_with_output "unreadable worktree status did not produce ERROR" "$output"
  assert_contains_text "$output" 'ERROR: cannot determine whether' "worktree status failure was not explicit"

  mkdir -p "$worktree/.specify"
  set +e
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" check "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail_with_output "Spec Kit not-applicable did not fail" "$output"
  assert_contains_text "$output" 'Spec Kit markers are present' "Spec Kit applicability was not enforced"
  write_ready_record "$record" "$head" pass
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" check "$id") || \
    fail_with_output "applicable Spec Kit pass did not clear readiness" "$output"

  printf 'dirty\n' >> "$worktree/file.txt"
  set +e
  output=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" "$HELPER" check "$id" 2>&1)
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail_with_output "dirty worktree did not fail readiness" "$output"
  assert_contains_text "$output" 'worktree is not clean and committed' "dirty worktree reason was not explicit"
  git -C "$worktree" checkout -- file.txt
  pass "fm-no-mistakes-ready: READY and NOT_READY are commit-bound and project-adaptive"
}

make_fake_no_mistakes() { # <fakebin> <status-file>
  local fakebin=$1 status_file=$2
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "axi status"|"axi status --run "*) cat "$FM_FAKE_NM_STATUS" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  export FM_FAKE_NM_STATUS="$status_file"
}

make_fake_herdr() { # <fakebin> <fixture-dir>
  local fakebin=$1 fixture=$2
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
fixture=$FM_FAKE_HERDR_FIXTURE
log=$fixture/calls.log
printf '%s\n' "$*" >> "$log"
first=${1:-}
second=${2:-}
active=$(cat "$fixture/active-tab")
focused_task=false
focused_monitor=false
[ "$active" = w1:t1 ] && focused_task=true
[ "$active" = w1:t2 ] && focused_monitor=true
case "$first $second" in
  "workspace list")
    printf '{"result":{"workspaces":[{"workspace_id":"w1","focused":true,"active_tab_id":"%s"}]}}\n' "$active"
    ;;
  "tab list")
    if [ -e "$fixture/created" ] && [ ! -e "$fixture/closed" ]; then
      printf '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","focused":%s},{"tab_id":"w1:t2","workspace_id":"w1","focused":%s}]}}\n' "$focused_task" "$focused_monitor"
    else
      printf '{"result":{"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","focused":%s}]}}\n' "$focused_task"
    fi
    ;;
  "tab create")
    : > "$fixture/created"
    rm -f "$fixture/closed"
    if [ -e "$fixture/ambiguous-create" ]; then
      printf '%s\n' '{"error":{"code":"lost_response"}}'
      exit 1
    fi
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t1","workspace_id":"w1"}}}'
    ;;
  "tab focus")
    printf 'w1:t1\n' > "$fixture/active-tab"
    printf '%s\n' '{"result":{"ok":true}}'
    ;;
  "pane get")
    pane=${3:-}
    if [ "$pane" = w1:p1 ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}'
    elif [ "$pane" = w1:p2 ] && [ -e "$fixture/created" ] && [ ! -e "$fixture/closed" ]; then
      printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
      exit 1
    fi
    ;;
  "pane run")
    : > "$fixture/running"
    printf '%s\n' '{"result":{"ok":true}}'
    ;;
  "pane process-info")
    run=$(cat "$fixture/run-id")
    if [ -e "$fixture/repurposed" ] || [ -e "$fixture/attach-missing" ]; then
      printf '%s\n' '{"result":{"process_info":{"pane_id":"w1:p2","foreground_processes":[{"argv":["bash","other"]}]}}}'
    else
      printf '{"result":{"process_info":{"pane_id":"w1:p2","foreground_processes":[{"argv":["/fake/no-mistakes","attach","--run","%s"]}]}}}\n' "$run"
    fi
    ;;
  "pane close")
    : > "$fixture/closed"
    printf '%s\n' '{"result":{"ok":true}}'
    ;;
  *)
    printf 'unexpected fake herdr call: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$fakebin/herdr"
  export FM_FAKE_HERDR_FIXTURE="$fixture"
}

write_run_status() { # <file> <run> <branch> <status> <head>
  cat > "$1" <<EOF
run:
  id: "$2"
  branch: $3
  status: $4
  head: $5
EOF
}

test_monitor_backends_and_lifecycle() {
  local home state data worktree id fakebin fixture status_file head run output count journal rc backend token
  home="$TMP_ROOT/monitor-home"
  state="$home/state"
  data="$home/data"
  worktree="$TMP_ROOT/monitor-worktree"
  id=monitor-task
  new_repo "$worktree" "$id"
  head=$(git -C "$worktree" rev-parse HEAD)
  fakebin=$(fm_fakebin "$TMP_ROOT/monitor-fakes")
  fixture="$TMP_ROOT/herdr-fixture"
  status_file="$fixture/status.toon"
  mkdir -p "$fixture"
  : > "$fixture/calls.log"
  printf 'w1:t1\n' > "$fixture/active-tab"
  run=RUN123456
  printf '%s\n' "$run" > "$fixture/run-id"
  write_run_status "$status_file" "$run" "fm/$id" running "$head"
  make_fake_no_mistakes "$fakebin" "$status_file"
  make_fake_herdr "$fakebin" "$fixture"

  for backend in tmux zellij orca cmux; do
    write_meta "$state" "$id" "$worktree" "$backend"
    output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
      "$HELPER" monitor-reconcile "$id") || fail_with_output "$backend reconciliation failed" "$output"
    assert_contains_text "$output" "not-applicable: backend=$backend" "$backend did not remain explicitly not applicable"
  done
  [ ! -s "$fixture/calls.log" ] || fail "non-Herdr reconciliation called Herdr"

  write_meta "$state" "$id" "$worktree" herdr
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id") || fail_with_output "Herdr monitor creation failed" "$output"
  assert_contains_text "$output" "visible: no-mistakes run $run attached in Herdr pane w1:p2" "monitor creation did not report exact binding"
  journal="$state/$id.no-mistakes-monitor"
  [ -f "$journal" ] || fail "monitor creation did not publish its exact journal"
  grep -F "run=$run" "$journal" >/dev/null || fail "monitor journal lost exact run id"
  grep -F "pane=w1:p2" "$journal" >/dev/null || fail "monitor journal lost response-derived pane id"
  grep -F "pane run w1:p2" "$fixture/calls.log" | grep -F "attach --run '$run'" >/dev/null \
    || fail "monitor did not run supported attach against the exact run id"
  [ "$(cat "$fixture/active-tab")" = w1:t1 ] || fail "monitor creation stole focus"

  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id") || fail_with_output "idempotent monitor reconciliation failed" "$output"
  count=$(grep -c '^tab create ' "$fixture/calls.log" || true)
  [ "$count" -eq 1 ] || fail "reconciliation created a duplicate monitor pane"

  write_run_status "$status_file" "$run" fm/other-task running "$head"
  set +e
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail_with_output "journaled run branch mismatch did not stop safely" "$output"
  [ -e "$journal" ] || fail "journaled run mismatch discarded the monitor journal"
  [ "$(grep -c '^tab create ' "$fixture/calls.log" || true)" -eq "$count" ] \
    || fail "journaled run mismatch created a duplicate monitor"

  write_run_status "$status_file" "$run" "fm/$id" completed "$head"
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id") || fail_with_output "terminal monitor retirement failed" "$output"
  assert_contains_text "$output" "retired: terminal no-mistakes run $run Herdr presentation pane w1:p2" "terminal retirement did not report exact pane"
  [ ! -e "$journal" ] || fail "confirmed terminal retirement retained its journal"
  [ -e "$fixture/closed" ] || fail "terminal retirement did not close the exact pane"

  run=RUNNOATTACH
  printf '%s\n' "$run" > "$fixture/run-id"
  rm -f "$fixture/created" "$fixture/closed" "$fixture/running"
  : > "$fixture/attach-missing"
  write_run_status "$status_file" "$run" "fm/$id" running "$head"
  set +e
  output=$(PATH="$fakebin:$PATH" FM_NM_MONITOR_PROCESS_ATTEMPTS=1 \
    FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail_with_output "failed attach startup falsely reported visibility" "$output"
  assert_contains_text "$output" 'did not become the exact foreground process' "failed attach startup had no exact diagnostic"
  case "$output" in *'visible:'*) fail_with_output "failed attach startup falsely reported visible" "$output" ;; esac
  [ ! -e "$journal" ] || fail "confirmed failed attach cleanup retained its journal"
  [ -e "$fixture/closed" ] || fail "failed attach startup did not retire its created pane"
  rm -f "$fixture/attach-missing"

  run=RUN654321
  printf '%s\n' "$run" > "$fixture/run-id"
  rm -f "$fixture/created" "$fixture/closed" "$fixture/running"
  write_run_status "$status_file" "$run" "fm/$id" running "$head"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id" >/dev/null || fail "second monitor setup failed"
  printf 'w1:t2\n' > "$fixture/active-tab"
  write_run_status "$status_file" "$run" "fm/$id" completed "$head"
  set +e
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail_with_output "active monitor retirement did not stop safely" "$output"
  [ -e "$journal" ] || fail "focus-unsafe retirement discarded its journal"
  [ ! -e "$fixture/closed" ] || fail "focus-unsafe retirement closed the active monitor"

  rm -f "$journal" "$fixture/created" "$fixture/closed" "$fixture/running"
  printf 'w1:t1\n' > "$fixture/active-tab"
  : > "$fixture/ambiguous-create"
  run=RUNAMBIG1
  printf '%s\n' "$run" > "$fixture/run-id"
  write_run_status "$status_file" "$run" "fm/$id" running "$head"
  set +e
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail_with_output "ambiguous create did not stop safely" "$output"
  grep -qx 'version=0' "$journal" || fail "ambiguous create did not preserve its attempt journal"
  count=$(grep -c '^tab create ' "$fixture/calls.log" || true)
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-reconcile "$id" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "incomplete attempt did not block a duplicate reconcile"
  [ "$(grep -c '^tab create ' "$fixture/calls.log" || true)" -eq "$count" ] \
    || fail "incomplete attempt allowed a duplicate monitor create"
  token=$(sed -n 's/^token=//p' "$journal")
  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-clear-attempt "$id" wrong-token >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "attempt recovery accepted the wrong exact token"
  [ -e "$journal" ] || fail "wrong-token recovery removed the attempt journal"
  output=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$HELPER" monitor-clear-attempt "$id" "$token") || fail_with_output "inspected attempt recovery failed" "$output"
  assert_contains_text "$output" 'no pane was discovered or mutated' "attempt recovery misstated its mutation boundary"
  [ ! -e "$journal" ] || fail "inspected attempt recovery retained its journal"
  [ ! -e "$fixture/closed" ] || fail "attempt recovery mutated the ambiguous presentation pane"
  pass "fm-no-mistakes-ready: exact Herdr monitor is idempotent, terminal-only, and focus-safe"
}

test_help
test_readiness_outcomes
test_monitor_backends_and_lifecycle
