#!/usr/bin/env bash
# Focused transition tests for canonical per-task records.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-atomicity)

make_home() { # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' 'retained legacy backlog bytes' >"$home/data/backlog.md"
  printf '%s\n' "$home"
}

run_tasks() { # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

test_canonical_transitions_ignore_legacy_backend_configuration() (
  local home before after
  home=$(make_home canonical-owner)
  ln -s missing-config "$home/.tasks.toml"
  run_tasks "$home" add task-a 'Canonical transition' --kind ship >/dev/null     || fail 'could not create canonical transition fixture'
  before=$(sha256sum "$home/data/backlog.md" | awk '{print $1}')

  FM_HOME="$home"
  FM_DATA_OVERRIDE="$home/data"
  FM_STATE_OVERRIDE="$home/state"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$ROOT/bin/fm-backlog-transition-lib.sh"

  fm_backlog_transition_applies "$home/config" "$home/data" ship     || fail "canonical transition was gated by legacy backend configuration: $FM_BACKLOG_TRANSITION_ERROR"
  fm_backlog_row_probe "$home/data" task-a || fail "canonical row probe failed: $FM_BACKLOG_ROW_ERROR"
  [ "$FM_BACKLOG_ROW_STATE" = 'queued no no' ]     || fail "canonical row probe returned the wrong state: $FM_BACKLOG_ROW_STATE"
  fm_backlog_start "$home/data" task-a || fail "canonical start failed: $FM_BACKLOG_TRANSITION_ERROR"
  fm_backlog_done "$home/data" task-a --pr https://github.com/example/repo/pull/7     || fail "canonical completion failed: $FM_BACKLOG_TRANSITION_ERROR"

  jq -e '
    .state == "done"
      and .links.pr == "https://github.com/example/repo/pull/7"
  ' "$home/data/task-a/task.json" >/dev/null || fail 'canonical transition lost state or artifact'
  after=$(sha256sum "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail 'canonical transition rewrote retained backlog evidence'
  pass 'canonical transitions ignore legacy backend configuration and leave legacy bytes unchanged'
)

test_dispatch_commit_moves_the_named_record_only() (
  local home other_before
  home=$(make_home dispatch)
  run_tasks "$home" add task-a 'Dispatch me' --kind ship >/dev/null
  run_tasks "$home" add task-b 'Leave me queued' --kind ship >/dev/null
  printf '%s\n' 'kind=ship' 'spawn_gen=g1' >"$home/state/task-a.meta"
  other_before=$(sha256sum "$home/data/task-b/task.json" | awk '{print $1}')

  FM_HOME="$home"
  FM_DATA_OVERRIDE="$home/data"
  FM_STATE_OVERRIDE="$home/state"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  fm_backlog_dispatch_transition "$home/state/task-a.meta" "$home/data" task-a "$home/state"     || fail "canonical dispatch transition failed: $FM_BACKLOG_TRANSITION_ERROR"

  [ "$(jq -r .state "$home/data/task-a/task.json")" = in_flight ]     || fail 'dispatch did not move the named record in flight'
  [ "$(sha256sum "$home/data/task-b/task.json" | awk '{print $1}')" = "$other_before" ]     || fail 'dispatch changed an unrelated task record'
  pass 'dispatch commit updates only the named canonical task record'
)

test_captain_retention_reopens_the_same_record() (
  local home
  home=$(make_home retain)
  run_tasks "$home" add held-task 'Held work' --kind scout --start >/dev/null
  run_tasks "$home" hold held-task --reason 'captain choice pending' --kind captain >/dev/null

  FM_HOME="$home"
  FM_DATA_OVERRIDE="$home/data"
  FM_STATE_OVERRIDE="$home/state"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  fm_backlog_retain "$home/data" held-task --report data/held-task/report.md     || fail "canonical retention failed: $FM_BACKLOG_TRANSITION_ERROR"

  jq -e '
    .state == "queued"
      and .hold.kind == "captain"
      and .links.report == "data/held-task/report.md"
      and (.body | contains("Deliverable of the finished work: report data/held-task/report.md"))
  ' "$home/data/held-task/task.json" >/dev/null     || fail 'retention did not preserve the captain hold and deliverable on one record'
  [ "$(find "$home/data/held-task" -maxdepth 1 -type f -printf '%f\n')" = task.json ]     || fail 'retention created a second live task-state file'
  pass 'captain retention reopens the same canonical task record with its deliverable'
)

test_terminal_effect_guard_requires_explicit_reopen() (
  local home rc
  home=$(make_home terminal-guard)
  run_tasks "$home" add task-a 'Terminal work' --kind ship --start >/dev/null
  run_tasks "$home" 'done' task-a >/dev/null

  FM_HOME="$home"
  FM_DATA_OVERRIDE="$home/data"
  FM_STATE_OVERRIDE="$home/state"
  . "$ROOT/bin/fm-task-disposition-lib.sh"
  rc=0
  fm_task_disposition_effect_guard "$home/data" task-a steer >"$home/out" 2>"$home/err" || rc=$?
  [ "$rc" -eq 6 ] || fail "terminal effect guard exited $rc instead of 6"
  assert_grep 'explicitly terminal (done)' "$home/err" 'terminal refusal did not name canonical disposition'

  run_tasks "$home" reopen task-a >/dev/null || fail 'explicit reopen failed'
  fm_task_disposition_effect_guard "$home/data" task-a steer     || fail 'explicitly reopened work remained terminal'
  run_tasks "$home" archive task-a >/dev/null || fail 'explicit archive failed'
  rc=0
  fm_task_disposition_effect_guard "$home/data" task-a steer >"$home/archive-out" 2>"$home/archive-err" || rc=$?
  [ "$rc" -eq 6 ] || fail "archived effect guard exited $rc instead of 6"
  assert_grep 'explicitly terminal (archive_done)' "$home/archive-err" \
    'archived refusal did not name canonical disposition'
  pass 'done and archived effects remain refused until MAIN explicitly reopens the canonical record'
)

test_canonical_transitions_ignore_legacy_backend_configuration
test_dispatch_commit_moves_the_named_record_only
test_captain_retention_reopens_the_same_record
test_terminal_effect_guard_requires_explicit_reopen
