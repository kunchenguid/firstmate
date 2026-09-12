#!/usr/bin/env bash
# Retrieval regression for the AGENTS.md state/<id>.meta owner pointer: it
# names bin/fm-spawn.sh's header as the owner of the base task-metadata fields,
# so that header (exercised through the public --help surface) must actually
# name the keys the script emits.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-meta-header)
HELP=$("$ROOT/bin/fm-spawn.sh" --help) || fail "fm-spawn.sh --help failed"

test_spawn_header_names_base_meta_keys() {
  local key
  for key in window= endpoint_task_id= worktree= project= harness= kind= \
    mode= yolo= tasktmp= model= effort=; do
    assert_contains "$HELP" "$key" \
      "spawn header does not document base meta key $key"
  done
  pass "spawn header documents every ordinary base meta key it emits"
}

test_spawn_header_names_routing_and_remote_meta_keys() {
  local key
  for key in matched_rule= quota_decision= quota_headroom= quota_runway= \
    dispatch_provider= dispatch_model_family= routing_source= \
    dispatch_override_reason= remote_host= remote_root= remote_backend= \
    remote_herdr_session= remote_target=; do
    assert_contains "$HELP" "$key" \
      "spawn header does not document routing/remote meta key $key"
  done
  pass "spawn header documents the routing and remote-route meta keys"
}

test_spawn_publishes_dispatched_pipeline_record() {
  local case_dir="$TMP_ROOT/spawn-record" home project worktree fakebin id out rc=0 record
  id=spawn-record-s2c
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
  fm_git_worktree "$project" "$worktree" "pool-s2c"

  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "real spawn should publish its task record"
  assert_contains "$out" "spawned $id" "real spawn did not complete"
  record=$(cat "$home/state/$id.pipeline")
  assert_contains "$record" "schema=fm-pipeline.v3 task=$id" \
    "spawn did not create the v3 pipeline header"
  assert_contains "$record" "kind=ship" "spawn pipeline header lost the metadata kind"
  assert_contains "$record" "gen=" "spawn pipeline header lost the metadata generation"
  assert_contains "$record" "rev=1 " "spawn did not record the first revision"
  assert_contains "$record" "step=dispatched" "spawn did not record dispatch"
  pass "real spawn publishes a dispatched owner record"
}

test_spawn_warns_and_preserves_unsafe_pipeline_record() {
  local case_dir="$TMP_ROOT/spawn-unsafe-pipeline" home project worktree fakebin id out rc=0 outside
  id=spawn-unsafe-s2c
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
  fm_git_worktree "$project" "$worktree" "pool-s2c"
  outside="$case_dir/outside.pipeline"
  printf 'sentinel\n' > "$outside"
  ln -s "$outside" "$home/state/$id.pipeline"

  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "unsafe pipeline cache must not block a real spawn"
  assert_contains "$out" "warning: pipeline record for $id was not reconciled" \
    "spawn did not report the owner refusal"
  assert_contains "$out" "refused:unsafe-record-path" \
    "spawn warning omitted the owner refusal"
  [ -L "$home/state/$id.pipeline" ] \
    || fail "spawn followed or replaced the unsafe pipeline cache path"
  [ "$(readlink "$home/state/$id.pipeline")" = "$outside" ] \
    || fail "spawn changed the unsafe pipeline cache target"
  [ "$(cat "$outside")" = sentinel ] \
    || fail "spawn changed bytes behind the unsafe pipeline cache path"
  pass "spawn completes while preserving an unsafe pipeline cache path"
}

test_spawn_relaunch_warns_and_preserves_foreign_pipeline_record() {
  local case_dir="$TMP_ROOT/spawn-relaunch" home project worktree fakebin id out rc=0 before_file
  id=spawn-relaunch-s2c
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
  fm_git_worktree "$project" "$worktree" "pool-s2c"
  cat > "$fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$worktree"; exit 0 ;;
  *"#{pane_tty}"*) printf '/dev/pts/0\n'; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ -e "$case_dir/live" ] && printf 'fm-$id\n'; exit 0 ;;
  send-keys) : > "$case_dir/live"; exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-t pts/0'*) printf ' 123 123 123 bash\n'; exit 0 ;;
  *) exec /bin/ps "$@" ;;
esac
EOF
  chmod +x "$fakebin/ps"

  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "relaunch fixture's first spawn should complete"
  before_file="$case_dir/pipeline.before"
  cp -- "$home/state/$id.pipeline" "$before_file"
  rc=0
  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" "$id" --relaunch) || rc=$?
  expect_code 0 "$rc" "relaunch should complete when its endpoint is agent-free"
  assert_contains "$out" "warning: pipeline record for $id was not reconciled" \
    "relaunch did not report the foreign-generation owner refusal"
  assert_contains "$out" "refused:foreign-gen" \
    "relaunch warning omitted the foreign-generation refusal"
  cmp -s "$before_file" "$home/state/$id.pipeline" \
    || fail "relaunch changed the prior-generation lifecycle record after owner refusal"
  pass "relaunch preserves a prior-generation pipeline record when reconciliation is fenced"
}

test_spawn_reclaims_stale_owner_lock_and_preserves_temp() {
  local case_dir="$TMP_ROOT/spawn-recovery" home project worktree fakebin id out rc=0 temp temp_before
  id=spawn-recovery-s2c
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
  fm_git_worktree "$project" "$worktree" "pool-s2c"
  temp="$home/state/.fm-pipeline-record.killed-writer"
  temp_before="$case_dir/temp.before"
  printf 'abandoned writer bytes\n' > "$temp"
  cp -- "$temp" "$temp_before"
  chmod 600 "$temp"
  mkdir "$home/state/pipeline-events.log.lock"
  touch -t 202001010000 "$home/state/pipeline-events.log.lock"

  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "stale-owner recovery must not block a real spawn"
  assert_contains "$(cat "$home/state/$id.pipeline")" "step=dispatched" \
    "stale-owner recovery did not publish dispatch"
  [ ! -e "$home/state/pipeline-events.log.lock" ] \
    || fail "stale-owner recovery left the dead owner lock behind"
  cmp -s "$temp_before" "$temp" \
    || fail "stale-owner recovery consumed or changed the abandoned temp"
  pass "spawn reclaims stale owner state without consuming an abandoned temp"
}

test_spawn_recovers_an_interrupted_owner_on_relaunch() {
  local case_dir="$TMP_ROOT/spawn-interrupted-owner" home project worktree fakebin id out rc=0 temp temp_before_file record gen
  id=spawn-interrupted-s2c
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
  fm_git_worktree "$project" "$worktree" "pool-s2c"
  cat > "$fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\\n' "$worktree"; exit 0 ;;
  *"#{pane_tty}"*) printf '/dev/pts/0\\n'; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\\n'; exit 0 ;;
  list-windows) [ -e "$case_dir/live" ] && printf 'fm-$id\\n'; exit 0 ;;
  send-keys) : > "$case_dir/live"; exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'-t pts/0'*) printf ' 123 123 123 bash\n'; exit 0 ;;
  *) exec /bin/ps "$@" ;;
esac
EOF
  chmod +x "$fakebin/ps"
  cat > "$fakebin/mv" <<EOF
#!/usr/bin/env bash
target=\${4:-\${3:-}}
if [ "\$target" = "$home/state/$id.pipeline" ] && [ ! -e "$case_dir/killed" ]; then
  : > "$case_dir/killed"
  kill -KILL "\$PPID" 2>/dev/null || true
  exit 137
fi
exec /bin/mv "\$@"
EOF
  chmod +x "$fakebin/mv"

  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "spawn should finish after an interrupted owner call"
  [ -e "$case_dir/killed" ] || fail "the recovery fixture did not interrupt the real owner"
  temp=$(find "$home/state" -maxdepth 1 -type f -name '.fm-pipeline-record.*' -print -quit)
  [ -n "$temp" ] || fail "the interrupted owner did not leave its private temp"
  temp_before_file="$case_dir/temp.before"
  cp -- "$temp" "$temp_before_file"
  [ ! -e "$home/state/$id.pipeline" ] \
    || fail "the interrupted owner published a canonical record"

  rc=0
  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" "$id" --relaunch) || rc=$?
  expect_code 0 "$rc" "relaunch should recover the interrupted owner state"
  gen=$(awk -F= '$1 == "spawn_gen" { print $2 }' "$home/state/$id.meta")
  record=$(cat "$home/state/$id.pipeline")
  assert_contains "$record" "schema=fm-pipeline.v3 task=$id kind=ship gen=$gen" \
    "recovery did not bind the record to the newly published generation"
  assert_contains "$record" "rev=1 " "recovery did not append the first revision"
  assert_contains "$record" "step=dispatched" "recovery did not append dispatch"
  cmp -s "$temp_before_file" "$temp" \
    || fail "recovery consumed or changed the interrupted writer temp"
  [ ! -e "$home/state/pipeline-events.log.lock" ] \
    || fail "recovery left the interrupted writer lock behind"
  pass "relaunch recovers a real interrupted owner without consuming its temp"
}

test_spawn_publishes_phase_timings() {
  local case_dir="$TMP_ROOT/spawn-timing" home project worktree fakebin id out rc=0 timing
  id=spawn-timing-s2c
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  timing="$case_dir/timings.tsv"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
  fm_git_worktree "$project" "$worktree" "pool-s2c"

  out=$(FM_SPAWN_TIMING_LOG="$timing" fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "timed spawn should complete"
  assert_contains "$out" "spawn timing: total=" "spawn did not print its timing summary"
  for phase in dispatch brief lease launch busy; do
    grep -F $'v1\tphase\t'"$phase" "$timing" >/dev/null \
      || fail "timing sink missed phase $phase"
  done
  grep -F $'v1\tspawn\tsummary\t' "$timing" >/dev/null \
    || fail "timing sink missed the spawn summary"
  pass "spawn publishes phase timings and a stderr summary"
}

test_spawn_refuses_corrupt_pipeline_record_without_changing_bytes() {
  local case_dir="$TMP_ROOT/spawn-corrupt-pipeline" home project worktree fakebin id out rc=0 pipeline expected
  id=spawn-corrupt-s2c
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  pipeline="$home/state/$id.pipeline"
  expected="$case_dir/expected.pipeline"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
  fm_git_worktree "$project" "$worktree" "pool-s2c"
  cat > "$fakebin/mv" <<EOF
#!/usr/bin/env bash
if [ "\${3:-}" = "$home/state/$id.meta" ]; then
  /bin/mv "\$@"
  gen=\$(awk -F= '\$1 == "spawn_gen" { print \$2 }' "$home/state/$id.meta")
  {
    printf 'schema=fm-pipeline.v3 task=%s kind=ship gen=%s\\n' "$id" "\$gen"
    printf 'rev=1 ts=2026-09-06T00:00:00Z step=dispatched evidence=meta:state/%s.meta gen=%s head=unknown\\n' "$id" "\$gen"
  } > "$pipeline"
  cp "$pipeline" "$expected"
  exit 0
fi
exec /bin/mv "\$@"
EOF
  chmod +x "$fakebin/mv"

  out=$(fm_test_run_spawn "$home" "$worktree" "$fakebin" \
    "$id" "$project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "corrupt pipeline state must not block a real spawn"
  assert_contains "$out" "warning: pipeline record for $id was not reconciled" \
    "spawn did not report the corrupt-record owner refusal"
  assert_contains "$out" "refused:malformed-record-line" \
    "spawn warning omitted the corrupt-record refusal"
  cmp -s "$expected" "$pipeline" \
    || fail "spawn changed corrupt canonical pipeline bytes"
  pass "spawn preserves corrupt pipeline bytes after the owner refusal"
}

test_delivery_modes_stand_down_no_mistakes() {
  local mode case_dir home project worktree fakebin id launch_log path_log resolved_log real_hit
  local launch out rc resolved shim effective invoke
  for mode in direct-PR local-only no-mistakes; do
    case_dir="$TMP_ROOT/no-mistakes-$mode"
    home="$case_dir/home"
    project="$case_dir/project"
    worktree="$case_dir/worktree"
    id="no-mistakes-$mode-z1"
    launch_log="$case_dir/launch.log"
    path_log="$case_dir/path.log"
    resolved_log="$case_dir/resolved.log"
    real_hit="$case_dir/real-hit"
    fm_test_spawn_home "$home" codex
    fm_test_spawn_brief "$home" "$id"
    fakebin=$(make_spawn_fakebin "$case_dir/fake")
    fm_test_write_active_treehouse_fake "$fakebin" "$worktree"
    fm_git_worktree "$project" "$worktree" "pool-$mode"
    cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PATH" > "$FM_FAKE_PATH_LOG"
command -v no-mistakes > "$FM_FAKE_RESOLVED_LOG"
[ "${FM_FAKE_INVOKE_NO_MISTAKES:-0}" = 1 ] || exit 0
exec no-mistakes
SH
    cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
: > "$FM_FAKE_REAL_HIT"
exit 73
SH
    chmod +x "$fakebin/codex" "$fakebin/no-mistakes"

    out=$(FM_FAKE_LAUNCH_LOG="$launch_log" fm_test_run_spawn "$home" "$worktree" "$fakebin" \
      "$id" "$project" codex --mode "$mode" --yolo off) || fail "spawn failed for $mode: $out"
    launch=$(<"$launch_log")
    invoke=1
    [ "$mode" != no-mistakes ] || invoke=0
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_FAKE_PATH_LOG="$path_log" FM_FAKE_RESOLVED_LOG="$resolved_log" \
      FM_FAKE_REAL_HIT="$real_hit" FM_FAKE_INVOKE_NO_MISTAKES="$invoke" /bin/sh -c "$launch" 2>&1) || rc=$?
    resolved=$(<"$resolved_log")
    if [ "$mode" = no-mistakes ]; then
      expect_code 0 "$rc" "no-mistakes launch should keep the real binary reachable: $out"
      [ "$resolved" = "$fakebin/no-mistakes" ] \
        || fail "no-mistakes launch resolved '$resolved' instead of the real binary"
      continue
    fi
    expect_code 2 "$rc" "$mode launch should refuse no-mistakes: $out"
    shim=$(dirname "$resolved")
    effective=$(<"$path_log")
    case "$effective" in "$shim":*) ;; *) fail "$mode shim was not first on PATH: $effective" ;; esac
    assert_contains "$out" "no-mistakes is stood down for $mode delivery (repository owner 09-03/09-07); use the direct path" \
      "$mode wrapper did not explain the refusal"
    [ ! -e "$real_hit" ] || fail "$mode launch reached the real no-mistakes binary"
    jq -e --arg mode "$mode" 'select(.op == "no-mistakes-refused" and .mode == $mode)' \
      "$home/data/telemetry/checks.jsonl" >/dev/null \
      || fail "$mode refusal did not reach checks telemetry"
  done
  pass "direct delivery launches put a refusing no-mistakes shim first while no-mistakes launches keep the real binary"
}

test_spawn_header_names_base_meta_keys
test_spawn_header_names_routing_and_remote_meta_keys
test_spawn_publishes_dispatched_pipeline_record
test_spawn_warns_and_preserves_unsafe_pipeline_record
test_spawn_relaunch_warns_and_preserves_foreign_pipeline_record
test_spawn_reclaims_stale_owner_lock_and_preserves_temp
test_spawn_recovers_an_interrupted_owner_on_relaunch
test_spawn_publishes_phase_timings
test_spawn_refuses_corrupt_pipeline_record_without_changing_bytes
test_delivery_modes_stand_down_no_mistakes
