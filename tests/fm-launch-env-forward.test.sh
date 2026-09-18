#!/usr/bin/env bash
# tests/fm-launch-env-forward.test.sh - behavior tests for config/launch-env-forward
# (bin/fm-spawn.sh --help "Launch environment forwarding";
# docs/configuration.md "Launch environment forwarding (config/launch-env-forward)").
#
# Measured 08.09.2026: a variable exported into firstmate's own process (e.g. by
# its launcher script) does not reach a freshly spawned worker on its own,
# because a long-lived backend session or daemon keeps its own environment,
# captured once, independent of later changes to the launching process's
# environment (tests/fm-backend-tmux-smoke.test.sh demonstrates that gap
# against a real tmux server). This suite pins the fix: fm-spawn.sh reads
# config/launch-env-forward and sends each named, currently-set variable's
# value into the fresh pane as an explicit `export NAME=value`, through the
# same pre-launch channel already proven for GOTMPDIR/FM_TASK_ID/TRACEPARENT
# (which is why it works regardless of backend-environment staleness).
#
# Uses a fake tmux pane that logs every send-keys payload - both the literal
# launch (`-l`) and a text line (`... Enter`) - one per line, in order, so the
# export sent before the launch command is directly observable (the same
# approach tests/fm-trace-context-spawn.test.sh uses for the same reason).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-launch-env-forward)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    # Capture the text payload of both send forms: the literal launch
    # (`send-keys -t <target> -l <text>`) and a text line
    # (`send-keys -t <target> <text> Enter`). Skip the flags, the target, and
    # the trailing key so only the payload is logged, one per line, in order.
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) continue ;;
          Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
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
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  id="$name-z1"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise launch-env-forward for $id.

## Firstmate spec
Verify the spawned pane receives the forwarded value.
EOF
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG CASE_ID <<EOF
$1
EOF
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  mkdir -p "$home/user-home"
  env FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

exported_value() {  # <launchlog> <name>
  sed -n "s/^export $2=//p" "$1" | tail -1
}

test_forward_sends_export_with_current_process_value_before_launch() {
  local rec out status el ll decoded
  rec=$(make_spawn_case forward-basic)
  read_case_record "$rec"
  printf 'FM_TEST_FORWARD\n' > "$HOME_DIR/config/launch-env-forward"

  out=$(FM_TEST_FORWARD="synthetic-value" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "forward-enabled spawn should succeed"$'\n'"$out"

  el=$(grep -n '^export FM_TEST_FORWARD=' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  ll=$(grep -n 'codex' "$LAUNCH_LOG" | tail -1 | cut -d: -f1)
  [ -n "$el" ] || fail "launch log missing the forwarded export"$'\n'"$(cat "$LAUNCH_LOG")"
  [ -n "$ll" ] || fail "launch log missing the launch command"
  [ "$el" -lt "$ll" ] || fail "forwarded export must be sent before the launch command (export=$el launch=$ll)"

  decoded=$(exported_value "$LAUNCH_LOG" FM_TEST_FORWARD)
  eval "decoded=$decoded"
  [ "$decoded" = "synthetic-value" ] \
    || fail "forwarded export did not carry the process's current value (got '$decoded')"
  pass "a variable set in firstmate's own process and listed in launch-env-forward is exported into the pane before the launch command"
}

test_forward_value_with_shell_metacharacters_is_safe() {
  local rec out status decoded marker
  rec=$(make_spawn_case forward-unsafe)
  read_case_record "$rec"
  printf 'FM_TEST_FORWARD\n' > "$HOME_DIR/config/launch-env-forward"
  marker="$HOME_DIR/SHOULD_NOT_EXIST"

  # shellcheck disable=SC2016
  out=$(FM_TEST_FORWARD="synthetic; touch $marker; \$(touch $marker) \`touch $marker\` \"quoted\" 'quoted2'" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "forward-enabled spawn with metacharacters should succeed"$'\n'"$out"
  [ ! -e "$marker" ] || fail "the forwarded export text executed shell metacharacters instead of staying a literal value"

  decoded=$(exported_value "$LAUNCH_LOG" FM_TEST_FORWARD)
  eval "decoded=$decoded"
  case "$decoded" in
    "synthetic; touch"*'quoted'*'quoted2'*) : ;;
    *) fail "decoded forwarded value was mangled: '$decoded'" ;;
  esac
  pass "a forwarded value containing shell metacharacters is sent as a safely quoted literal, never executed"
}

test_forward_unset_name_is_skipped() {
  local rec out status
  rec=$(make_spawn_case forward-unset)
  read_case_record "$rec"
  printf 'FM_TEST_FORWARD_UNSET\n' > "$HOME_DIR/config/launch-env-forward"
  unset FM_TEST_FORWARD_UNSET

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn should succeed even when the forwarded name is unset"$'\n'"$out"
  grep -q '^export FM_TEST_FORWARD_UNSET=' "$LAUNCH_LOG" \
    && fail "a name unset in firstmate's own process must not be forced empty into the pane"
  pass "a launch-env-forward name absent from firstmate's own process is skipped, never forced empty"
}

test_forward_absent_config_changes_nothing() {
  local rec out status
  rec=$(make_spawn_case forward-absent)
  read_case_record "$rec"
  [ ! -e "$HOME_DIR/config/launch-env-forward" ] || fail "test setup: launch-env-forward should not exist yet"

  out=$(FM_TEST_FORWARD="synthetic-value" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn without launch-env-forward should succeed unchanged"$'\n'"$out"
  grep -q 'FM_TEST_FORWARD' "$LAUNCH_LOG" \
    && fail "an absent launch-env-forward must forward nothing (unchanged ambient behavior)"
  pass "an absent config/launch-env-forward changes nothing, matching every home that predates this option"
}

test_forward_invalid_config_refuses() {
  local rec out status bad
  rec=$(make_spawn_case forward-invalid)
  read_case_record "$rec"
  for bad in 'FM_TEST=value' 'NAME;false' '1INVALID' '*'; do
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-env-forward"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$CASE_ID" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "invalid launch-env-forward content '$bad' must refuse the spawn"
    assert_contains "$out" 'launch-env-forward' "refusal must identify the config file for '$bad'"
    [ ! -s "$LAUNCH_LOG" ] || fail "an invalid config must refuse before any pane send for '$bad'"
  done
  pass "malformed config/launch-env-forward content refuses the spawn before any pane exists"
}

# Execute the actual emitted export + launch text in a synthetic pane shell, in
# the same order fm-spawn.sh sends them, exactly as a real pane would: the
# forwarded export first (setting the shell's own variable), then the
# env-allowlist-filtered launch command reading it back. Proves the forwarded
# name survives the exec-boundary filter when both options are enabled together.
test_forward_survives_allowlist_filter() {
  local rec out status probe result pane_shell
  rec=$(make_spawn_case forward-with-allowlist)
  read_case_record "$rec"
  printf 'FM_TEST_FORWARD\n' > "$HOME_DIR/config/launch-env-forward"
  : > "$HOME_DIR/config/launch-env-allowlist"
  probe="$CASE_DIR/probe.sh"
  cat > "$probe" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_FORWARD-unset}"
SH

  out=$(FM_TEST_FORWARD="forwarded-through-filter" \
    run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$CASE_ID" "$PROJ_DIR" --harness "/bin/sh '$probe'")
  status=$?
  expect_code 0 "$status" "forward+allowlist spawn should succeed"$'\n'"$out"

  for pane_shell in /bin/sh /bin/bash; do
    [ -x "$pane_shell" ] || continue
    result=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin \
      "$pane_shell" -c "$(cat "$LAUNCH_LOG")") \
      || fail "replaying the sent pane text in $pane_shell failed"
    [ "$result" = "forwarded-through-filter" ] \
      || fail "the forwarded value did not survive the launch-env-allowlist filter in $pane_shell (got '$result')"
  done
  pass "a launch-env-forward name automatically survives an enabled launch-env-allowlist filter"
}

test_forward_sends_export_with_current_process_value_before_launch
test_forward_value_with_shell_metacharacters_is_safe
test_forward_unset_name_is_skipped
test_forward_absent_config_changes_nothing
test_forward_invalid_config_refuses
test_forward_survives_allowlist_filter

echo "# all fm-launch-env-forward tests passed"
