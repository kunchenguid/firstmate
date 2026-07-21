#!/usr/bin/env bash
# Behavior tests for GitHub Copilot CLI recognition: session-lock acquisition and
# holder detection, own-harness detection, anchored non-matches against unrelated
# copilot-flavored argv, and the dispatch refusal that keeps copilot lock/detection
# only (never a crew/secondmate harness).
# Empirical shape (copilot 1.0.73, 2026-07-21): `ps -o comm=` reports "MainThread"
# (the bundled ELF renames its main thread) and `ps -o args=` is exactly "copilot".
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

  # MainThread comm with copilot as a mid-argv word (not at argv start) must
  # not match either - lock recognition aligns with fm-harness.sh detection.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"ppid="*) exit 1 ;;
  *"comm="*) printf '%s\n' 'MainThread'; exit 0 ;;
  *"args="*) printf '%s\n' 'node runner.js copilot'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FM_HOME="$home" PATH="$fakebin:$PATH" "$LOCK" status)
  assert_contains "$out" "lock: stale" "MainThread holder with mid-argv copilot should read as stale"
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
  pass "fm-harness reports copilot distinctly for both observed process shapes"
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

test_spawn_refuses_copilot_dispatch() {
  local case_dir home proj wt fakebin id out status
  case_dir="$TMP_ROOT/spawn-refuse"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  id="copilot-refuse-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  fm_fake_exit0 "$fakebin" tmux treehouse gh-axi gh

  # Explicit harness argument.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" copilot 2>&1)
  status=$?
  expect_code 1 "$status" "explicit copilot harness must be refused"
  assert_contains "$out" "unknown harness 'copilot'" "spawn did not refuse the explicit copilot harness"

  # Configured crew harness resolving to copilot.
  printf 'copilot\n' > "$home/config/crew-harness"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1)
  status=$?
  expect_code 1 "$status" "crew-harness copilot must be refused"
  assert_contains "$out" "no launch template for harness 'copilot'" "spawn did not refuse the configured copilot crew harness"
  pass "crew/secondmate dispatch of copilot is still refused fail-closed"
}

test_fm_lock_acquires_under_copilot_ancestor
test_fm_lock_overwrites_stale_dead_copilot_holder
test_fm_lock_recognizes_copilot_holder
test_fm_lock_ignores_unrelated_copilot_argv
test_fm_lock_holder_argv_only_matters_for_interpreters
test_fm_lock_acquires_under_renamed_copilot_wrapper
test_fm_harness_reports_copilot
test_fm_harness_existing_detection_unchanged
test_spawn_refuses_copilot_dispatch
