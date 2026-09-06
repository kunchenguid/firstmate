#!/usr/bin/env bash
# tests/fm-spawn-override-reset.test.sh - regression coverage for the
# FM_*_OVERRIDE reset in the launch line bin/fm-spawn.sh sends into a fresh
# pane (AGENTS.md "Layout and state": FM_ROOT_OVERRIDE, FM_HOME,
# FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_PROJECTS_OVERRIDE,
# FM_CONFIG_OVERRIDE).
#
# Before this fix, that reset lived only inside the `KIND = secondmate`
# branch, so an ordinary ship/scout worker's pane received no reset at all: a
# pane that inherits environment from elsewhere in the launching process tree
# (for example a secondmate context still live in that tree) could carry a
# foreign home's override values straight into the worker's own watcher and
# fm-*.sh helpers, which then looked at the wrong home. The fix hoists the
# five-variable reset out of the KIND-specific branch so it applies to every
# spawn regardless of kind, while the FM_HOME redirect (and the
# secondmate-only extras riding with it) stays secondmate-exclusive.
#
# These tests drive a REAL fm-spawn.sh ship spawn (and a real secondmate
# spawn) against a fake tmux pane that logs the literal `send-keys -l`
# payload, exactly as tests/fm-trace-context-spawn.test.sh does, and then
# REPLAY that captured launch line through a fake agent that reports its own
# environment - a launch line that merely mentions the variables proves
# nothing, only the launched process's environment does.
#
# The replay runs under each pane shell family the backends recognize
# (bin/backends/tmux.sh shell classification): the POSIX family, where the
# reset must clear every override without writing a word into the pane, and
# fish, where `unset` is not a builtin at all and a POSIX-only reset would
# silently leave the pane inheriting the overrides.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-override-reset)
export FM_BACKEND=tmux

write_ship_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise the override reset for $2.

## Firstmate spec
Verify the spawned process's launch line clears the FM_*_OVERRIDE variables.
EOF
}

# Fake tmux: answers the pane-path query and logs every literal `send-keys -l`
# argument (the launch command) one per line, mirroring
# tests/fm-trace-context-spawn.test.sh's fixture.
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
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
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

# Stands in for the launched agent binary and reports, per variable, whether it
# is ABSENT from the launched process's environment or present (with its
# value). Running the captured launch line through this probe is what proves
# the reset is a real unset: an empty assignment prefix would still hand the
# variable down as present-but-empty, which bin/fm-check-unregister.sh
# (`${FM_STATE_OVERRIDE-...}`) refuses.
make_env_probe() {  # <dir>
  local dir=$1 probe
  probe="$dir/probe"
  mkdir -p "$probe"
  cat > "$probe/claude" <<'SH'
#!/usr/bin/env bash
set -u
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_HOME; do
  if eval "[ \"\${${v}+x}\" = x ]"; then
    eval "printf '%s=present:%s\n' \"\$v\" \"\$$v\""
  else
    printf '%s=absent\n' "$v"
  fi
done
SH
  chmod +x "$probe/claude"
  printf '%s\n' "$probe"
}

# Runs a captured launch line in a shell whose environment carries the given
# override values, and echoes the probe's report of what the launched process
# actually received. The pane's shell is whichever login shell the operator
# runs, so the interpreter is a parameter: every shell the backends recognize
# as a pane shell has to reach the same result.
run_launch_under_probe() {  # <probe-dir> <home> <launch-line> [shell-argv...]
  local probe=$1 home=$2 line=$3
  shift 3
  [ "$#" -gt 0 ] || set -- bash -c
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$probe:$SHIP_FAKEBIN:$PATH" "$@" "$line" 2>&1
}

# Same run, but echoes only what the launch line wrote to STDERR. The reset has
# to stay quiet on a pane whose shell is not fish: the fish spelling is reached
# through a `status` guard that no POSIX shell provides, and an unsuppressed
# "command not found" would land in the pane the operator watches.
run_launch_stderr() {  # <probe-dir> <home> <launch-line> [shell-argv...]
  local probe=$1 home=$2 line=$3
  shift 3
  [ "$#" -gt 0 ] || set -- bash -c
  { env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$probe:$SHIP_FAKEBIN:$PATH" "$@" "$line" >/dev/null; } 2>&1
}

assert_overrides_absent() {  # <probe-output> <label>
  local out=$1 label=$2 v
  for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE; do
    assert_contains "$out" "$v=absent" \
      "$label: $v must be unset - not present-but-empty - in the launched process"
  done
}

# Drives one real ship spawn in <case-dir> and publishes what the cross-shell
# tests below replay: SHIP_HOME (the launching firstmate's home), SHIP_LINE
# (the captured launch line) and SHIP_PROBE (the env-reporting fake agent).
spawn_ship_case() {  # <case-dir> <id>
  local case_dir=$1 id=$2 home proj wt fakebin launchlog out status
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  write_ship_brief "$home/data/$id/brief.md" "$id"
  : > "$launchlog"

  # The parent env sets every override to a real, correctly-resolving value
  # (matching this test's own home fixtures) - the same shape a genuine
  # invoking firstmate process has. Nothing here is empty going in.
  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "ship spawn with parent-env overrides set should succeed"
  assert_contains "$out" "spawned $id" "ship spawn should report success"
  [ -s "$launchlog" ] || fail "ship spawn logged no launch line"

  SHIP_HOME="$home"
  SHIP_FAKEBIN="$fakebin"
  # The pane receives several literal lines (a treehouse get, the GOTMPDIR
  # export, then the launch command). The launch command is the last of them
  # and the only one this file is about.
  SHIP_LINE=$(tail -n 1 "$launchlog")
  SHIP_PROBE=$(make_env_probe "$case_dir")
}

# A ship spawn: the launching (parent) environment carries live, non-empty
# FM_*_OVERRIDE values that correctly resolve fm-spawn.sh's own home, exactly
# as an ordinary crewmate spawn's invoking environment does. The captured
# launch line must still clear all five, proving the reset does not depend on
# KIND.
test_ship_spawn_clears_overrides_set_in_parent_env() {
  local home log_line probe probe_out
  spawn_ship_case "$TMP_ROOT/ship" ship-override-z1
  home="$SHIP_HOME"
  log_line="$SHIP_LINE"
  probe="$SHIP_PROBE"
  assert_contains "$log_line" "$FM_TEST_SPAWN_RESET_PREFIX" \
    "ship spawn's launch line must clear all five FM_*_OVERRIDE variables even though the parent environment set them"
  assert_not_contains "$log_line" "FM_ROOT_OVERRIDE=$ROOT" \
    "ship spawn's launch line must not carry the parent's FM_ROOT_OVERRIDE value into the pane"
  assert_not_contains "$log_line" "FM_STATE_OVERRIDE=$home/state" \
    "ship spawn's launch line must not carry the parent's FM_STATE_OVERRIDE value into the pane"

  # Execute the captured launch line: the launched process must see the five
  # overrides as ABSENT (an empty assignment prefix would leave them present),
  # while FM_HOME - which a ship worker is meant to resolve exactly as its
  # launching firstmate does - must still come through.
  probe_out=$(run_launch_under_probe "$probe" "$home" "$log_line") \
    || fail "ship launch line did not run: $probe_out"
  assert_overrides_absent "$probe_out" "ship spawn"
  assert_contains "$probe_out" "FM_HOME=present:$home" \
    "ship spawn must still hand the launching firstmate's FM_HOME to the worker"
  pass "ship spawn unsets FM_*_OVERRIDE for the launched process regardless of what the parent environment set"
}

# The pane runs whichever login shell the operator uses, and the backends
# recognize a fish pane next to the POSIX family (bin/backends/tmux.sh shell
# classification). `unset` is not a fish builtin, so a launch line carrying
# only the POSIX spelling clears nothing on a fish pane and leaves that pane
# inheriting a foreign home's overrides - the very failure this reset exists to
# stop. Replay the REAL captured launch line under fish and demand the same
# result the bash replay above demands.
test_fish_pane_launch_line_clears_overrides() {
  local probe_out bare with without
  command -v fish >/dev/null 2>&1 || { echo "skip: fish not found (fish pane replay)"; return 0; }
  # A launch line uses `"$(...)"` to type the brief pointer, which fish only
  # parses from 3.4 on; an older fish would fail the line for an unrelated
  # reason and say nothing about the reset.
  # shellcheck disable=SC2016  # fish, not this shell, must expand the probe.
  fish -c 'set -l probe "$(printf ok)"; test "$probe" = ok' >/dev/null 2>&1 \
    || { echo "skip: fish too old for \"\$(...)\" (fish pane replay)"; return 0; }

  probe_out=$(run_launch_under_probe "$SHIP_PROBE" "$SHIP_HOME" "$SHIP_LINE" fish -c) \
    || fail "ship launch line did not run under fish: $probe_out"
  assert_overrides_absent "$probe_out" "fish pane"
  assert_contains "$probe_out" "FM_HOME=present:$SHIP_HOME" \
    "fish pane must still hand the launching firstmate's FM_HOME to the worker"

  # The POSIX half of the reset is no more a fish builtin than `status` is a
  # POSIX one, so it has to swallow its own diagnostic too: otherwise every
  # single spawn writes fish's unknown-command error into the pane the operator
  # watches. Measured the same way as the POSIX pane above - the identical
  # launch line with the reset prefix stripped is the baseline, so what is
  # compared is the reset's own contribution.
  bare=${SHIP_LINE#"$FM_TEST_SPAWN_RESET_PREFIX" }
  [ "$bare" != "$SHIP_LINE" ] \
    || fail "the captured launch line does not start with the reset prefix: $SHIP_LINE"
  with=$(run_launch_stderr "$SHIP_PROBE" "$SHIP_HOME" "$SHIP_LINE" fish -c)
  without=$(run_launch_stderr "$SHIP_PROBE" "$SHIP_HOME" "$bare" fish -c)
  [ "$with" = "$without" ] \
    || fail "the reset wrote its own diagnostic into a fish pane: ${with#"$without"}"
  pass "a fish pane's launch line unsets FM_*_OVERRIDE quietly for the launched process"
}

# The fish spelling rides behind a `status` guard, and `status` is a builtin no
# POSIX shell has. On a POSIX pane the guard must therefore fail quietly and
# leave the POSIX `unset` as the only reset that runs: nothing extra written
# into the pane the operator watches, and no `set --erase` reaching a shell
# that would read shell options out of that word. The comparison run is the
# same launch line with the reset prefix stripped off, so what is measured is
# the reset's own contribution rather than whatever the launched command says.
test_posix_pane_reset_is_quiet_and_complete() {
  local sh probe_out bare with without
  bare=${SHIP_LINE#"$FM_TEST_SPAWN_RESET_PREFIX" }
  [ "$bare" != "$SHIP_LINE" ] \
    || fail "the captured launch line does not start with the reset prefix: $SHIP_LINE"
  for sh in sh dash bash; do
    command -v "$sh" >/dev/null 2>&1 || continue
    probe_out=$(run_launch_under_probe "$SHIP_PROBE" "$SHIP_HOME" "$SHIP_LINE" "$sh" -c) \
      || fail "ship launch line did not run under $sh: $probe_out"
    assert_overrides_absent "$probe_out" "$sh pane"
    assert_contains "$probe_out" "FM_HOME=present:$SHIP_HOME" \
      "$sh pane must still hand the launching firstmate's FM_HOME to the worker"
    with=$(run_launch_stderr "$SHIP_PROBE" "$SHIP_HOME" "$SHIP_LINE" "$sh" -c)
    without=$(run_launch_stderr "$SHIP_PROBE" "$SHIP_HOME" "$bare" "$sh" -c)
    [ "$with" = "$without" ] \
      || fail "the reset wrote its own diagnostic into a $sh pane: ${with#"$without"}"
  done
  pass "the reset clears every override and stays silent on a POSIX pane shell"
}

# A secondmate spawn: the same five-variable reset must still apply, AND the
# secondmate-only FM_HOME redirect (to the secondmate's own home) must still
# ride alongside it - proving the refactor split the two concerns without
# dropping either.
test_secondmate_spawn_still_clears_overrides_and_redirects_home() {
  local base prim sm sm_id fakebin launchlog out status log_line probe probe_out
  base="$TMP_ROOT/secondmate"
  prim="$base/primary"
  sm="$base/sm"
  mkdir -p "$prim/config" "$prim/data" "$prim/state" "$prim/projects"
  printf 'claude\n' > "$prim/config/crew-harness"
  printf '%s\n' "$$" > "$prim/state/.lock"
  touch "$prim/state/.last-watcher-beat"

  sm_id='sm-override-z1'
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$sm_id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"

  mkdir -p "$prim/data/$sm_id"
  printf 'charter brief\n' > "$prim/data/$sm_id/brief.md"
  fakebin=$(make_spawn_fakebin "$base/fake")
  launchlog="$base/launch.log"
  : > "$launchlog"

  out=$(env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$prim" \
    FM_STATE_OVERRIDE="$prim/state" FM_DATA_OVERRIDE="$prim/data" \
    FM_PROJECTS_OVERRIDE="$prim/projects" FM_CONFIG_OVERRIDE="$prim/config" \
    FM_SPAWN_NO_GUARD=1 CLAUDECODE=1 TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launchlog" PATH="$fakebin:$PATH" \
    "$SPAWN" "$sm_id" "$sm" --secondmate 2>&1)
  status=$?
  expect_code 0 "$status" "secondmate spawn with parent-env overrides set should succeed"
  assert_contains "$out" "spawned $sm_id" "secondmate spawn should report success"

  [ -s "$launchlog" ] || fail "secondmate spawn logged no launch line"
  log_line=$(cat "$launchlog")
  assert_contains "$log_line" "$FM_TEST_SPAWN_RESET_PREFIX" \
    "secondmate spawn's launch line must still clear all five FM_*_OVERRIDE variables"
  assert_contains "$log_line" "FM_HOME='$sm'" \
    "secondmate spawn's launch line must still redirect FM_HOME to the secondmate's own home"
  assert_not_contains "$log_line" "FM_HOME='$prim'" \
    "secondmate spawn's launch line must not leave FM_HOME pointed at the primary's home"

  probe=$(make_env_probe "$base")
  probe_out=$(run_launch_under_probe "$probe" "$prim" "$log_line") \
    || fail "secondmate launch line did not run: $probe_out"
  assert_overrides_absent "$probe_out" "secondmate spawn"
  assert_contains "$probe_out" "FM_HOME=present:$sm" \
    "secondmate spawn must hand the secondmate's own home to the launched process"
  pass "secondmate spawn keeps both the override reset and its own FM_HOME redirect"
}

test_ship_spawn_clears_overrides_set_in_parent_env
test_posix_pane_reset_is_quiet_and_complete
test_fish_pane_launch_line_clears_overrides
test_secondmate_spawn_still_clears_overrides_and_redirects_home

echo "# all fm-spawn-override-reset tests passed"
