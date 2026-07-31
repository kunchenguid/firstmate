#!/usr/bin/env bash
# Executable-interface tests for Firstmate's optional task lifecycle notifier.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-notify.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-notify-tests)

make_case() {  # <name>
  local name=$1 dir hook
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config" "$dir/fakebin"
  hook="$dir/hook"
  cat > "$hook" <<'SH'
#!/usr/bin/env bash
IFS= read -r payload || exit 1
printf '%s\n' "$payload" >> "${FM_NOTIFY_CAPTURE:?}"
SH
  chmod +x "$hook"
  printf '%s\n' "$hook" > "$dir/config/notification-hook"
  : > "$dir/capture"
  printf '%s\n' "$dir"
}

write_task() {  # <case> <mode> <kind> [task-id] [project]
  local dir=$1 mode=$2 kind=$3 id=${4:-task-x1} project=${5:-$dir/projects/example-project}
  fm_write_meta "$dir/state/$id.meta" \
    "window=fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$project" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$mode"
}

run_notify() {  # <case> <command> <task-id>
  local dir=$1 command=$2 id=$3
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_NOTIFY_CAPTURE="$dir/capture" \
    "$NOTIFY" "$command" "$id"
}

capture_count() {  # <case>
  awk 'END { print NR + 0 }' "$1/capture"
}

last_payload() {  # <case>
  tail -1 "$1/capture"
}

assert_payload() {  # <json> <event> <task> <project> <kind> <outcome>
  local payload=$1 event=$2 task=$3 project=$4 kind=$5 outcome=$6
  printf '%s\n' "$payload" | jq -e \
    --arg event "$event" --arg task "$task" --arg project "$project" \
    --arg kind "$kind" --arg outcome "$outcome" \
    '.schema == "firstmate.notification.v1"
     and .event == $event
     and .task_id == $task
     and .project == $project
     and .kind == $kind
     and .outcome == $outcome
     and (.event_id | test("^[0-9a-f]{64}$"))
     and (.occurred_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    >/dev/null || fail "unexpected notification payload: $payload"
}

test_absent_hook_is_silent() {
  local dir rc
  dir=$(make_case absent)
  write_task "$dir" local-only ship
  rm -f "$dir/config/notification-hook"
  set +e
  run_notify "$dir" completed task-x1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "absent hook changed notifier exit status"
  [ ! -s "$dir/stdout" ] || fail "absent hook wrote stdout"
  [ ! -s "$dir/stderr" ] || fail "absent hook wrote stderr"
  [ ! -e "$dir/state/notification-hook.log" ] || fail "absent hook wrote a diagnostic"
  pass "an absent notification hook is silent and non-fatal"
}

test_configured_hook_receives_bounded_json() {
  local dir id project payload bytes
  dir=$(make_case configured)
  id=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._
  project="$(printf 'private/%.0s' {1..30})$(printf 'project-name-with-extra-characters-%.0s' {1..4})"
  write_task "$dir" local-only ship "$id" "$project"
  run_notify "$dir" completed "$id" || fail "configured hook invocation failed"
  payload=$(last_payload "$dir")
  bytes=$(printf '%s\n' "$payload" | LC_ALL=C wc -c | tr -d '[:space:]')
  [ "$bytes" -le 512 ] || fail "payload exceeded 512 bytes: $bytes"
  [ "$(printf '%s\n' "$payload" | jq -r '.task_id | length')" -le 64 ] || fail "task id exceeded bound"
  [ "$(printf '%s\n' "$payload" | jq -r '.project | length')" -le 64 ] || fail "project exceeded bound"
  assert_no_grep 'private/' "$dir/capture" "payload leaked a project path"
  assert_payload "$payload" task.completed "$id" \
    "$(printf '%s' "${project##*/}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)" \
    ship completed
  pass "a configured hook receives bounded privacy-safe JSON on standard input"
}

test_hook_failure_and_timeout_are_nonfatal_and_inspectable() {
  local dir rc
  dir=$(make_case failure)
  write_task "$dir" local-only ship
  cat > "$dir/hook" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'secret stdout' >&1
printf '%s\n' 'secret stderr' >&2
exit 7
SH
  chmod +x "$dir/hook"
  set +e
  run_notify "$dir" completed task-x1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "failing hook changed notifier exit status"
  [ ! -s "$dir/stdout" ] || fail "failing hook output escaped to stdout"
  [ ! -s "$dir/stderr" ] || fail "failing hook output escaped to stderr"
  assert_grep 'result=hook-failed' "$dir/state/notification-hook.log" "hook failure diagnostic missing"
  assert_no_grep 'secret' "$dir/state/notification-hook.log" "hook output leaked into diagnostics"

  cat > "$dir/hook" <<'SH'
#!/usr/bin/env bash
sleep 5
SH
  chmod +x "$dir/hook"
  : > "$dir/state/notification-hook.log"
  set +e
  FM_NOTIFICATION_TIMEOUT_SECS=1 run_notify "$dir" completed task-x1 > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "timed-out hook changed notifier exit status"
  assert_grep 'result=hook-timeout' "$dir/state/notification-hook.log" "hook timeout diagnostic missing"
  pass "hook failures and timeouts stay non-fatal with privacy-safe diagnostics"
}

test_malformed_paths_never_become_commands() {
  local dir marker value
  dir=$(make_case malformed)
  write_task "$dir" local-only ship
  marker="$dir/executed"
  for value in 'relative-hook' "$dir/hook --argument" "$dir" "$dir/not-executable"; do
    printf '%s\n' "$value" > "$dir/config/notification-hook"
    printf '#!/usr/bin/env bash\ntouch %q\n' "$marker" > "$dir/not-executable"
    chmod 0600 "$dir/not-executable"
    run_notify "$dir" completed task-x1 || fail "malformed hook path changed exit status"
  done
  [ ! -e "$marker" ] || fail "malformed hook configuration was shell-evaluated"
  grep -qE 'result=(config-malformed|hook-not-executable)' "$dir/state/notification-hook.log" \
    || fail "malformed hook path diagnostic missing"
  pass "relative paths, command strings, directories, and non-executables are never evaluated"
}

test_ready_semantics_cover_every_delivery_mode_and_scouts() {
  local dir payload
  dir=$(make_case ready-matrix)

  write_task "$dir" local-only ship
  printf '%s\n' 'working: rebased onto merged main' > "$dir/state/task-x1.status"
  run_notify "$dir" status task-x1
  [ "$(capture_count "$dir")" -eq 0 ] || fail "nonterminal local-only status emitted ready"
  printf '%s\n' 'done: ready in branch fm/task-x1' >> "$dir/state/task-x1.status"
  run_notify "$dir" status task-x1
  payload=$(last_payload "$dir")
  assert_payload "$payload" task.ready task-x1 example-project ship ready

  : > "$dir/capture"
  write_task "$dir" direct-PR ship
  printf '%s\n' 'done: PR https://example.invalid/repo/pull/1' > "$dir/state/task-x1.status"
  run_notify "$dir" status task-x1
  [ "$(capture_count "$dir")" -eq 1 ] || fail "direct-PR ready status did not emit once"

  : > "$dir/capture"
  write_task "$dir" no-mistakes ship
  printf '%s\n' 'done: implementation ready for validation' > "$dir/state/task-x1.status"
  run_notify "$dir" status task-x1
  [ "$(capture_count "$dir")" -eq 0 ] || fail "pre-validation no-mistakes status emitted ready"
  printf '%s\n' 'done: PR https://example.invalid/repo/pull/2 checks green' >> "$dir/state/task-x1.status"
  run_notify "$dir" status task-x1
  [ "$(capture_count "$dir")" -eq 1 ] || fail "green no-mistakes PR did not emit ready"

  : > "$dir/capture"
  write_task "$dir" no-mistakes scout
  printf '%s\n' 'done: report complete' > "$dir/state/task-x1.status"
  run_notify "$dir" status task-x1
  payload=$(last_payload "$dir")
  assert_payload "$payload" task.ready task-x1 example-project scout ready
  pass "ready emission matches local-only, direct-PR, no-mistakes, and scout delivery boundaries"
}

test_identities_ignore_retries_harnesses_and_backends() {
  local dir first id backend harness payload
  dir=$(make_case identity)
  first=
  for harness in claude codex opencode pi pi-signed grok kimi; do
    for backend in tmux herdr zellij orca cmux; do
      : > "$dir/capture"
      write_task "$dir" local-only ship
      printf 'harness=%s\nbackend=%s\n' "$harness" "$backend" >> "$dir/state/task-x1.meta"
      printf '%s\n' 'done: ready in branch fm/task-x1' > "$dir/state/task-x1.status"
      run_notify "$dir" status task-x1
      run_notify "$dir" status task-x1
      [ "$(capture_count "$dir")" -eq 2 ] || fail "retry did not exercise hook twice for $harness/$backend"
      payload=$(last_payload "$dir")
      id=$(printf '%s\n' "$payload" | jq -r '.event_id')
      [ -n "$first" ] || first=$id
      [ "$id" = "$first" ] || fail "identity changed for $harness/$backend"
      [ "$(jq -r '.event_id' "$dir/capture" | sort -u | wc -l | tr -d '[:space:]')" -eq 1 ] \
        || fail "retry identity changed for $harness/$backend"
    done
  done
  pass "retries and every supported harness/runtime backend preserve one event identity"
}

test_completed_semantics_cover_all_modes_and_scouts() {
  local dir spec mode kind payload
  dir=$(make_case completed-matrix)
  for spec in local-only:ship direct-PR:ship no-mistakes:ship no-mistakes:scout; do
    mode=${spec%%:*}
    kind=${spec#*:}
    : > "$dir/capture"
    write_task "$dir" "$mode" "$kind"
    run_notify "$dir" completed task-x1
    payload=$(last_payload "$dir")
    assert_payload "$payload" task.completed task-x1 example-project "$kind" completed
  done
  pass "completed emission supports local-only, direct-PR, no-mistakes, and scout tasks"
}

test_watcher_is_the_ready_emission_owner() {
  local dir hook rc
  dir=$(make_case watcher-owner)
  write_task "$dir" local-only ship
  printf '%s\n' 'done: ready in branch fm/task-x1' > "$dir/state/task-x1.status"
  hook="$dir/hook"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
  set +e
  PATH="$dir/fakebin:$PATH" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_CONFIG_OVERRIDE="$dir/config" \
  FM_NOTIFY_CAPTURE="$dir/capture" \
  FM_SIGNAL_GRACE=0 FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "watcher ready-owner run failed"
  [ "$(capture_count "$dir")" -eq 1 ] || fail "watcher did not emit exactly one ready notification"
  assert_payload "$(last_payload "$dir")" task.ready task-x1 example-project ship ready
  [ -x "$hook" ] || fail "configured hook changed during watcher run"
  pass "the backend-neutral watcher owns task.ready emission from status events"
}

test_absent_hook_is_silent
test_configured_hook_receives_bounded_json
test_hook_failure_and_timeout_are_nonfatal_and_inspectable
test_malformed_paths_never_become_commands
test_ready_semantics_cover_every_delivery_mode_and_scouts
test_identities_ignore_retries_harnesses_and_backends
test_completed_semantics_cover_all_modes_and_scouts
test_watcher_is_the_ready_emission_owner
