#!/usr/bin/env bash
# tests/fm-trace-context-spawn.test.sh - spawn-path integration regressions for
# native W3C trace context using fake Herdr panes and real isolated git worktrees.
# See docs/verification/trace-context.md for the maintained coverage inventory.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-trace-context-spawn)

write_ship_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise trace propagation for $2.

## Firstmate spec
Verify the spawned process receives the expected trace context.
EOF
}

# Fake Herdr: answers the pane-path query and logs every `pane run` payload
# (the GOTMPDIR export, the TRACEPARENT export, and the launch command)
# one per line, in send order, so ordering is observable.
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  mv "$fakebin/herdr" "$fakebin/herdr-fixture"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$1 ${2:-}" = 'pane run' ]; then
  case "${4:-}" in
    'export TRACEPARENT='*)
      [ "${FM_FAKE_TRACEPARENT_SEND_FAIL:-0}" != 1 ] || exit 1
      [ "${FM_FAKE_TRACEPARENT_SEND_UNSAFE:-0}" != 1 ] || exit 2
      [ "${FM_FAKE_TRACE_METADATA_APPEND_FAIL:-0}" != 1 ] || chmod a-w "$FM_FAKE_META_PATH" ;;
  esac
  [ -z "${FM_FAKE_LAUNCH_LOG:-}" ] || printf '%s\n' "${4:-}" >> "$FM_FAKE_LAUNCH_LOG"
fi
exec "$(dirname "$0")/herdr-fixture" "$@"
SH
  chmod +x "$fakebin/herdr"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin launchlog id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s off\n' "$$" > "$home/state/.trace-context-effective"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  id=$name-z1
  mkdir -p "$home/data/$id"
  write_ship_brief "$home/data/$id/brief.md" "$id"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$launchlog|$id"
}

# Hermetic against an ambient FM_TRACE_CONTEXT: `env -u` unsets it so enablement
# is decided ONLY by the home's config/trace-context, whether the runner's own
# environment enables or disables trace context.
run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # A codex spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-codex-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.codex.json.
  mkdir -p "$home/user-home"
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_BACKEND=herdr HERDR_ENV='' HERDR_PANE_ID='' HERDR_SESSION=fixture \
    FM_FAKE_TRACEPARENT_SEND_FAIL="${FM_FAKE_TRACEPARENT_SEND_FAIL:-0}" \
    FM_FAKE_TRACEPARENT_SEND_UNSAFE="${FM_FAKE_TRACEPARENT_SEND_UNSAFE:-0}" \
    FM_FAKE_TRACE_METADATA_APPEND_FAIL="${FM_FAKE_TRACE_METADATA_APPEND_FAIL:-0}" \
    FM_FAKE_META_PATH="$home/state/$1.meta" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode review-PR --yolo off 2>&1
}

# Same, but with an explicit FM_TRACE_CONTEXT override, to prove the env decides.
run_spawn_tc() {
  local tc=$1 home=$2 wt=$3 fakebin=$4 launchlog=$5
  shift 5
  : > "$launchlog"
  # A codex spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-codex-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.codex.json.
  mkdir -p "$home/user-home"
  env FM_TRACE_CONTEXT="$tc" \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_BACKEND=herdr HERDR_ENV='' HERDR_PANE_ID='' HERDR_SESSION=fixture \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode review-PR --yolo off 2>&1
}

start_trace_session() {
  local home=$1 tc=${2-}
  printf '%s\n' "$$" > "$home/state/.lock"
  if [ -n "$tc" ]; then
    FM_TRACE_CONTEXT="$tc" fm_trace_context_session_start \
      "$home/config" "$home/state/.trace-context-effective"
  else
    (
      unset FM_TRACE_CONTEXT
      fm_trace_context_session_start \
        "$home/config" "$home/state/.trace-context-effective"
    )
  fi
}

read_case_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

meta_traceparent() { sed -n 's/^traceparent=//p' "$1"; }
injected_traceparent() { sed -n 's/^export TRACEPARENT=//p' "$1"; }

test_enabled_records_and_injects_identical_carrier_before_launch() {
  local rec out status meta mtp itp gl tl ll
  rec=$(make_spawn_case tc-on)
  read_case_record "$rec"
  : > "$HOME_DIR/config/launch-env-allowlist"
  : > "$HOME_DIR/config/trace-context"   # enable via the real config path
  start_trace_session "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "enabled trace-context spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "enabled spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  mtp=$(meta_traceparent "$meta")
  fm_trace_context_valid "$mtp" || fail "enabled spawn must record a valid traceparent= in meta (got '$mtp')"
  itp=$(injected_traceparent "$LAUNCH_LOG")
  fm_trace_context_valid "$itp" || fail "enabled spawn must inject a valid TRACEPARENT export (got '$itp')"
  [ "$mtp" = "$itp" ] || fail "the recorded and injected carriers must be identical (meta='$mtp' injected='$itp')"

  gl=$(grep -n '^export GOTMPDIR=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  tl=$(grep -n '^export TRACEPARENT=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  ll=$(grep -n 'codex' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  [ -n "$gl" ] && [ -n "$tl" ] && [ -n "$ll" ] || fail "launch log missing GOTMPDIR/TRACEPARENT/launch lines"
  [ "$tl" -gt "$gl" ] || fail "TRACEPARENT export must ride the GOTMPDIR pre-launch site (gotmp=$gl tp=$tl)"
  [ "$tl" -lt "$ll" ] || fail "TRACEPARENT export must be sent before the launch literal (tp=$tl launch=$ll)"
  pass "enabled: one resolved carrier is recorded in meta and the identical TRACEPARENT is exported before launch"
}

test_disabled_writes_and_injects_neither() {
  local rec out status meta
  rec=$(make_spawn_case tc-off)
  read_case_record "$rec"
  # No config/trace-context and no FM_TRACE_CONTEXT: default-off.

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "default-off spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "default-off spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  # Anchored regex checks (the assert_grep helpers are fixed-string).
  ! grep -q '^traceparent=' "$meta" || fail "default-off spawn must not write a traceparent= line to meta"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" || fail "default-off spawn must not inject a TRACEPARENT export"
  grep -q '^export GOTMPDIR=' "$LAUNCH_LOG" || fail "the spawn should still run (GOTMPDIR is always injected)"
  pass "disabled: neither traceparent= in meta nor a TRACEPARENT export is produced"
}

test_failed_delivery_omits_metadata_and_still_launches() {
  local rec out status meta
  rec=$(make_spawn_case tc-send-failure)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"

  out=$(FM_FAKE_TRACEPARENT_SEND_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "failed traceparent delivery must not abort spawn"
  assert_contains "$out" "spawned $CASE_ID" "spawn should report success after failed traceparent delivery"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  ! grep -q '^traceparent=' "$meta" \
    || fail "failed traceparent delivery must not leave a traceparent= claim in meta"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" \
    || fail "the failed TRACEPARENT export must not be recorded as delivered"
  grep -q 'codex' "$LAUNCH_LOG" || fail "the source task must still launch"
  pass "failed TRACEPARENT delivery omits metadata while the source task still launches"
}

test_unsafe_delivery_refuses_to_append_launch() {
  local rec out status
  rec=$(make_spawn_case tc-send-unsafe)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"

  out=$(FM_FAKE_TRACEPARENT_SEND_UNSAFE=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "uncleared traceparent input must stop spawn"
  assert_contains "$out" "refusing to append the launch command" \
    "unsafe traceparent delivery should report why spawn stopped"
  ! grep -q 'codex' "$LAUNCH_LOG" \
    || fail "unsafe traceparent delivery must not append the launch command"
  pass "uncleared TRACEPARENT input stops before the launch command is appended"
}

test_failed_metadata_append_unsets_carrier_and_still_launches() {
  local rec out status meta
  rec=$(make_spawn_case tc-metadata-failure)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"

  out=$(FM_FAKE_TRACE_METADATA_APPEND_FAIL=1 \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "failed traceparent metadata append must not abort spawn"
  assert_contains "$out" "spawned $CASE_ID" "spawn should report success after failed metadata append"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  ! grep -q '^traceparent=' "$meta" \
    || fail "failed metadata append must not leave a traceparent= claim in meta"
  grep -q '^unset TRACEPARENT; .*codex' "$LAUNCH_LOG" \
    || fail "failed metadata append must unset TRACEPARENT in the launch command"
  pass "failed traceparent metadata append removes the carrier from the launched task"
}


test_relaunch_reuses_recorded_carrier() {
  local rec out status meta first second injected
  rec=$(make_spawn_case tc-relaunch)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR"
  meta="$HOME_DIR/state/$CASE_ID.meta"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "first trace-context spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "first spawn should report success"
  first=$(meta_traceparent "$meta")
  fm_trace_context_valid "$first" || fail "first spawn must record a valid carrier (got '$first')"

  # Relaunch the same task: the recorded carrier must be reused verbatim for both
  # the meta and the injected export, so an observer keeps one identity across
  # restarts.
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "relaunch spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "relaunch spawn should report success"
  second=$(meta_traceparent "$meta")
  injected=$(injected_traceparent "$LAUNCH_LOG")
  [ "$second" = "$first" ] || fail "relaunch must reuse the recorded carrier in meta (first='$first' second='$second')"
  [ "$injected" = "$first" ] || fail "relaunch must inject the same recorded carrier (first='$first' injected='$injected')"
  pass "relaunch reuses the recorded carrier verbatim for both the meta record and the injected export"
}

test_session_start_freezes_env_override_and_ignores_later_edits() {
  local rec out status meta
  rec=$(make_spawn_case tc-envoff)
  read_case_record "$rec"
  : > "$HOME_DIR/config/trace-context"
  start_trace_session "$HOME_DIR" off
  out=$(run_spawn_tc on "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-off spawn should succeed"
  assert_contains "$out" "spawned $CASE_ID" "env-off spawn should report success"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  ! grep -q '^traceparent=' "$meta" || fail "session-frozen off must ignore a later FM_TRACE_CONTEXT=on"
  ! grep -q '^export TRACEPARENT=' "$LAUNCH_LOG" || fail "session-frozen off must remain disabled after launch-time edits"

  rec=$(make_spawn_case tc-envon)
  read_case_record "$rec"
  start_trace_session "$HOME_DIR" on
  : > "$HOME_DIR/config/trace-context"
  out=$(run_spawn_tc off "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "env-on spawn should succeed"
  meta="$HOME_DIR/state/$CASE_ID.meta"
  fm_trace_context_valid "$(meta_traceparent "$meta")" \
    || fail "session-frozen on must ignore a later FM_TRACE_CONTEXT=off"
  pass "session start freezes the env override and later config or environment edits do not alter spawns"
}

test_enabled_records_and_injects_identical_carrier_before_launch
test_disabled_writes_and_injects_neither
test_failed_delivery_omits_metadata_and_still_launches
test_unsafe_delivery_refuses_to_append_launch
test_failed_metadata_append_unsets_carrier_and_still_launches
test_relaunch_reuses_recorded_carrier
test_session_start_freezes_env_override_and_ignores_later_edits

echo "# all fm-trace-context-spawn tests passed"
