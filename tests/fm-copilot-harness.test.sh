#!/usr/bin/env bash
# Behavior tests for GitHub Copilot CLI recognition and crew/secondmate dispatch:
# session-lock acquisition and holder detection, own-harness detection, anchored
# non-matches against unrelated copilot-flavored argv, the verified launch template
# with model/effort flags, the repo-level agentStop turn-end hook install, and its
# teardown cleanup.
# Empirical shape (copilot 1.0.73, 2026-07-21): `ps -o comm=` reports "MainThread"
# (the bundled ELF renames its main thread) and `ps -o args=` is exactly "copilot".
# Dispatch facts (same session, harness-adapters "copilot" section): -i takes the
# prompt as its value and auto-executes, --allow-all + --no-ask-user run a turn
# fully unattended, --effort accepts firstmate's full low..max vocabulary, and
# repo-level .github/hooks/*.json fire agentStop at every completed turn end.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-lock.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)

# Fake ps reproducing the observed copilot process shape for every queried pid.
make_copilot_ps() {
  local fakebin=$1
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' 'copilot'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

test_fm_lock_acquires_under_copilot_ancestor() {
  local home fakebin out status
  home="$TMP_ROOT/acquire-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/acquire-fake")
  mkdir -p "$home/state"
  make_copilot_ps "$fakebin"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK")
  status=$?
  expect_code 0 "$status" "copilot-ancestored lock acquisition should succeed"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not acquire under a copilot ancestor"
  assert_present "$home/state/.lock" "lock file was not written"
  pass "fm-lock acquires under a copilot ancestor (comm MainThread, args copilot)"
}

test_fm_lock_overwrites_stale_dead_copilot_holder() {
  local home fakebin dead out status
  home="$TMP_ROOT/stale-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/stale-fake")
  mkdir -p "$home/state"
  make_copilot_ps "$fakebin"
  dead=$(bash -c 'echo $$')
  while kill -0 "$dead" 2>/dev/null; do sleep 0.1; done
  printf '%s\n' "$dead" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK")
  status=$?
  expect_code 0 "$status" "stale dead-holder lock should be overwritten"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not overwrite the stale holder"
  [ "$(cat "$home/state/.lock")" != "$dead" ] || fail "stale holder pid survived in the lock file"
  pass "fm-lock overwrites a stale dead-holder lock under a copilot ancestor"
}

test_fm_lock_recognizes_copilot_holder() {
  local home fakebin out
  home="$TMP_ROOT/holder-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/holder-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  make_copilot_ps "$fakebin"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" "fm-lock did not recognize copilot as a live holder"
  pass "fm-lock recognizes a copilot holder as live"
}

test_fm_lock_acquires_under_path_prefixed_copilot() {
  local home fakebin out status
  home="$TMP_ROOT/pathargv-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/pathargv-fake")
  mkdir -p "$home/state"
  # A copilot primary launched via an absolute path keeps comm MainThread but
  # carries the full path in argv[0]; it must still read as a harness.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/x/.local/bin/copilot --allow-all'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK")
  status=$?
  expect_code 0 "$status" "path-prefixed copilot argv should acquire the lock"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not accept a path-prefixed copilot argv[0]"
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" "path-prefixed copilot holder should read as live"
  pass "fm-lock recognizes a path-prefixed copilot argv[0]"
}

test_fm_lock_ignores_unrelated_copilot_argv() {
  local home fakebin out status
  home="$TMP_ROOT/plugin-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/plugin-fake")
  mkdir -p "$home/state"
  # A node process whose argv only mentions copilot inside plugin paths (the
  # VS Code tsserver shape observed alongside the real copilot CLI) must not
  # be mistaken for a harness.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node tsserver.js --globalPlugins @vscode/copilot-typescript-server-plugin --pluginProbeLocations /x/extensions/copilot --locale en'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" 2>&1)
  status=$?
  expect_code 1 "$status" "plugin-path argv must not be recognized as a harness"
  assert_contains "$out" "cannot locate harness process" "fm-lock accepted vscode copilot plugin argv as a harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: stale" "holder with only plugin-path copilot argv should read as stale"
  pass "anchored copilot match ignores vscode plugin paths in unrelated argv"
}

test_fm_lock_holder_argv_only_matters_for_interpreters() {
  local home fakebin out
  home="$TMP_ROOT/recycled-home"
  fakebin=$(fm_fakebin "$TMP_ROOT/recycled-fake")
  mkdir -p "$home/state"
  printf '%s\n' "$$" > "$home/state/.lock"
  # Recycled pid: comm gh, argv merely containing the word copilot must not
  # read as a live harness holder.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'gh'; exit 0 ;;
  *"args="*) printf '%s\n' 'gh copilot suggest fix my code'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: stale" "gh-comm holder with copilot argv should read as stale"

  # comm-only path still recognizes a real harness comm.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'claude'; exit 0 ;;
  *"args="*) printf '%s\n' 'claude'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: held by live harness pid" "claude comm holder should still read as live"
  pass "holder argv is only trusted for interpreter/MainThread comms"
}

test_fm_lock_acquires_under_renamed_copilot_wrapper() {
  local home wrapper out status
  home="$TMP_ROOT/wrapper-home"
  mkdir -p "$home/state" "$TMP_ROOT/wrapper-bin"
  # Real ps, real ancestry: a wrapper process whose comm is "copilot" (a script
  # named copilot) stands in for the CLI on platforms where comm is the binary name.
  wrapper="$TMP_ROOT/wrapper-bin/copilot"
  # Direct shebang: an env shebang would exec bash and reset comm to "bash",
  # while a direct interpreter keeps comm as the script name "copilot".
  cat > "$wrapper" <<'SH'
#!/bin/bash
"$@"
SH
  chmod +x "$wrapper"
  out=$(FM_HOME="$home" "$wrapper" "$LOCK")
  status=$?
  expect_code 0 "$status" "lock acquisition under a copilot-named ancestor should succeed"
  assert_contains "$out" "lock acquired: harness pid" "fm-lock did not find the copilot-named ancestor with real ps"
  pass "fm-lock acquires under a real copilot-named ancestor process"
}

test_fm_harness_reports_copilot() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/detect-fake")
  make_copilot_ps "$fakebin"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = copilot ] || fail "fm-harness printed '$out' instead of copilot for the MainThread/args shape"

  # comm reported directly as the binary name (non-thread-renaming platforms).
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' '/home/x/.local/bin/copilot'; exit 0 ;;
  *"args="*) printf '%s\n' 'copilot'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = copilot ] || fail "fm-harness printed '$out' instead of copilot for a copilot comm"

  # MainThread comm with a path-prefixed argv[0] (absolute-path launch).
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' '/home/x/.local/bin/copilot --allow-all'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = copilot ] || fail "fm-harness printed '$out' instead of copilot for a path-prefixed argv[0]"
  pass "fm-harness reports copilot distinctly for all observed process shapes"
}

test_fm_harness_copilot_brief_argv_mentions_other_harness() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/brief-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' 'copilot --allow-all --no-ask-user -i Update CLAUDE.md per the brief'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = copilot ] || fail "fm-harness printed '$out' instead of copilot when the -i brief argv mentions claude"
  pass "copilot detection wins over unanchored harness names in the brief argv"
}

test_fm_harness_existing_detection_unchanged() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/regress-fake")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'pi'; exit 0 ;;
  *"args="*) printf '%s\n' 'pi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = pi ] || fail "fm-harness printed '$out' instead of pi (anchoring regression)"
  pass "existing pi detection is unchanged by the copilot entry"
}

# A tmux stub that behaves like the grok test's spawn stub but also captures the
# literal `send-keys -l <cmd>` launch command into FM_FAKE_LAUNCH_LOG, mirroring
# tests/fm-secondmate-harness.test.sh's make_launch_capturing_tmux.
make_copilot_spawn_fakebin() {
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_copilot_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_copilot_spawn_fakebin "$case_dir/fake")
  id="copilot-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_copilot_spawn() {
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5 launchlog=$6
  shift 6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$launchlog" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" copilot "$@" 2>&1
}

test_spawn_dispatches_copilot_with_flags_and_turnend_hook() {
  local rec case_dir home proj wt fakebin id launchlog out status launch hook excl meta
  rec=$(make_copilot_spawn_case dispatch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$launchlog" \
    --model claude-haiku-4.5 --effort low)
  status=$?
  expect_code 0 "$status" "copilot spawn should succeed"
  assert_contains "$out" "spawned $id harness=copilot" "copilot spawn did not report success"

  launch=$(cat "$launchlog")
  assert_contains "$launch" "copilot --allow-all --no-ask-user " \
    "launch command lost the verified unattended-autonomy flags"
  assert_contains "$launch" "--model 'claude-haiku-4.5'" "launch command lost the model flag"
  assert_contains "$launch" "--effort 'low'" "launch command lost the effort flag"
# shellcheck disable=SC2016  # single quotes are deliberate: the literal $(...) encoder call must appear in the launch command
  assert_contains "$launch" '-i "$(' \
    "launch command must pass the brief as -i's value (auto-executing interactive mode)"
# shellcheck disable=SC2016  # the brief rides the shared operational-input encoder like every other harness
  assert_contains "$launch" 'encode launch-brief' \
    "launch command must encode the brief through the shared operational-input encoder"

  hook="$wt/.github/hooks/fm-turn-end.json"
  assert_present "$hook" "repo-level agentStop turn-end hook was not installed"
  assert_grep 'agentStop' "$hook" "turn-end hook is not registered on the agentStop event"
  assert_grep "$id.turn-ended" "$hook" "turn-end hook does not touch the task's turn-ended file"
  excl=$(git -C "$wt" rev-parse --git-path info/exclude)
  assert_grep '.github/hooks/fm-turn-end.json' "$excl" \
    "turn-end hook file was not git-excluded (would dirty teardown's landed-work check)"

  meta="$home/state/$id.meta"
  assert_grep 'harness=copilot' "$meta" "meta did not record harness=copilot"
  pass "copilot dispatch wires the verified launch template, flags, and agentStop hook"
}

test_spawn_copilot_omits_default_model_effort() {
  local rec case_dir home proj wt fakebin id launchlog out status launch
  rec=$(make_copilot_spawn_case defaults)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$launchlog")
  status=$?
  expect_code 0 "$status" "flagless copilot spawn should succeed"
  launch=$(cat "$launchlog")
  case "$launch" in
    *--model*|*--effort*) fail "default model/effort must emit no flag, got: $launch" ;;
  esac
  pass "copilot dispatch omits model/effort flags when unset"
}

# The live-captured busy and idle footers (copilot 1.0.73, 2026-07-21). The busy
# footer must match the shared default busy regex (via its "esc (to )?interrupt"
# alternative - no copilot-specific entry exists) and the idle footer must not,
# so a working copilot crew reads busy and an idle one reads stale-eligible.
test_copilot_busy_footer_matches_default_busy_regex() {
  local regex
  regex=$(bash -c '. "$0/bin/fm-tmux-lib.sh"; printf "%s" "$FM_TMUX_BUSY_REGEX_DEFAULT"' "$ROOT")
  printf '%s' ' ◎ Working · 916 B esc interrupt' | grep -qiE "$regex" \
    || fail "copilot's live busy footer did not match the default busy regex"
  printf '%s' ' ● Working esc interrupt' | grep -qiE "$regex" \
    || fail "copilot's byte-count-free busy footer did not match the default busy regex"
  printf '%s' ' / commands · ? help · tab next tab' | grep -qiE "$regex" \
    && fail "copilot's idle footer must not match the busy regex"
  grep -qF "BUSY_REGEX=\${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\\.\\.\\.|Ctrl\\+c:cancel'}" "$ROOT/bin/fm-watch.sh" \
    || fail "fm-watch.sh BUSY_REGEX default drifted from the value these footers were verified against"
  pass "copilot busy/idle footers classify correctly under the shared busy regex"
}

test_copilot_teardown_removes_turnend_hook() {
  local rec case_dir home proj wt fakebin id launchlog out status
  rec=$(make_copilot_spawn_case teardown)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  out=$(run_copilot_spawn "$home" "$proj" "$wt" "$fakebin" "$id" "$launchlog")
  status=$?
  expect_code 0 "$status" "copilot spawn should succeed before teardown"
  assert_present "$wt/.github/hooks/fm-turn-end.json" "hook missing before teardown"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1 \
    || fail "copilot teardown failed"

  assert_absent "$wt/.github/hooks/fm-turn-end.json" \
    "agentStop hook survived teardown (a reused pool worktree would fire signals for a dead task)"
  assert_absent "$home/state/$id.turn-ended" "turn-ended state file survived teardown"
  pass "copilot teardown removes the repo-level agentStop hook"
}

test_fm_lock_acquires_under_copilot_ancestor
test_fm_lock_overwrites_stale_dead_copilot_holder
test_fm_lock_recognizes_copilot_holder
test_fm_lock_acquires_under_path_prefixed_copilot
test_fm_lock_ignores_unrelated_copilot_argv
test_fm_lock_holder_argv_only_matters_for_interpreters
test_fm_lock_acquires_under_renamed_copilot_wrapper
test_fm_harness_reports_copilot
test_fm_harness_copilot_brief_argv_mentions_other_harness
test_fm_harness_existing_detection_unchanged
test_spawn_dispatches_copilot_with_flags_and_turnend_hook
test_spawn_copilot_omits_default_model_effort
test_copilot_busy_footer_matches_default_busy_regex
test_copilot_teardown_removes_turnend_hook
