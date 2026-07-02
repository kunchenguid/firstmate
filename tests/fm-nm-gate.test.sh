#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-gate.sh - the no-mistakes gate refresh helper.
#
# The gate is shared by a project's main clone and every treehouse worktree of
# it (no-mistakes keys one gate per origin URL). An older no-mistakes installed a
# post-receive hook with a RELATIVE gate path, so a worktree push failed with
# "invalid gate path: ." and no run was created. The fix is to re-run the
# idempotent `no-mistakes init` to refresh the hook. This helper does exactly
# that, guarded and best-effort, so a stale or absent gate never blocks a spawn.
# These cases pin the helper's branch behavior hermetically with a fake
# `no-mistakes`:
#   (a) usage error (no arg)                         -> exit 2
#   (b) usage error (too many args)                  -> exit 2
#   (c) non-git directory                            -> skip, exit 0
#   (d) git repo without an origin remote            -> skip, exit 0
#   (e) git repo + origin + no-mistakes installed    -> refreshed (init invoked)
#   (f) no-mistakes not on PATH                       -> skip, exit 0
#   (g) `no-mistakes init` fails                      -> warning, exit 0 (non-fatal)
#   (h) fm-spawn gate refresh stalls                  -> timeout warning, spawn continues
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM_GATE="$ROOT/bin/fm-nm-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-gate)
mkdir -p "$TMP_ROOT"
fm_git_identity fmtest fmtest@example.invalid

# A fakebin whose `no-mistakes init` records that it ran (so we can prove the
# helper invoked the refresh) and honors FM_FAKE_NM_INIT_RC for the failure case.
make_fakebin() {  # <dir> -> echoes fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = init ]; then
  printf 'init-ran\n' >> "$FM_FAKE_NM_INIT_LOG"
  exit "${FM_FAKE_NM_INIT_RC:-0}"
fi
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# A git repo with one commit; origin added only when requested.
make_repo() {  # <dir> [origin-bare]
  local dir=$1 origin=${2:-}
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  if [ -n "$origin" ]; then
    git -C "$dir" init -q --bare "$origin"
    git -C "$dir" remote add origin "file://$origin"
  fi
}

make_spawn_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
}

make_stalling_gate_root() {  # <dir> -> echoes fake firstmate root
  local root="$1/fm-root"
  mkdir -p "$root/bin"
  cat > "$root/bin/fm-project-mode.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "no-mistakes off"
SH
  cat > "$root/bin/fm-nm-gate.sh" <<'SH'
#!/usr/bin/env bash
trap '' TERM
kill -STOP $$
while :; do sleep 10; done
SH
  chmod +x "$root/bin/fm-project-mode.sh" "$root/bin/fm-nm-gate.sh"
  printf '%s\n' "$root"
}

run_with_timeout() {  # <seconds> <command> [args...]
  # shellcheck disable=SC2016  # Single quotes are deliberate: Perl expands its own variables.
  perl -e '
my $t = shift;
my $pid = fork;
die "fork failed" unless defined $pid;
if (!$pid) { setpgrp(0, 0); exec @ARGV; die "exec failed: $!" }
local $SIG{ALRM} = sub {
  kill "TERM", -$pid;
  select undef, undef, undef, 0.2;
  kill "KILL", -$pid;
  exit 124;
};
alarm $t;
waitpid $pid, 0;
exit($? >> 8);
' "$@"
}

# (a) no arg -> usage error, exit 2
out=$("$NM_GATE" 2>&1); rc=$?
expect_code 2 "$rc" "no-arg should exit 2"
assert_contains "$out" "usage:" "no-arg should print usage"

# (b) too many args -> usage error, exit 2
out=$("$NM_GATE" a b 2>&1); rc=$?
expect_code 2 "$rc" "too-many-args should exit 2"

# (c) non-git directory -> skip, exit 0
NONGIT="$TMP_ROOT/plain"
mkdir -p "$NONGIT"
out=$("$NM_GATE" "$NONGIT" 2>&1); rc=$?
expect_code 0 "$rc" "non-git dir should exit 0"
assert_contains "$out" "skipped" "non-git dir should be skipped"
assert_contains "$out" "not a git repository" "non-git dir reason"

# (d) git repo without origin -> skip, exit 0
NOORIGIN="$TMP_ROOT/noorigin"
make_repo "$NOORIGIN"
out=$("$NM_GATE" "$NOORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "no-origin repo should exit 0"
assert_contains "$out" "no origin remote" "no-origin reason"

# (e) git repo + origin + fake no-mistakes -> refreshed, init actually invoked
WITHORIGIN="$TMP_ROOT/withorigin"
make_repo "$WITHORIGIN" "$TMP_ROOT/origin.git"
FB=$(make_fakebin "$TMP_ROOT")
export FM_FAKE_NM_INIT_LOG="$TMP_ROOT/init.log"
: > "$FM_FAKE_NM_INIT_LOG"
out=$(PATH="$FB:$PATH" "$NM_GATE" "$WITHORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "healthy refresh should exit 0"
assert_contains "$out" "refreshed" "healthy path should report refreshed"
assert_grep "init-ran" "$FM_FAKE_NM_INIT_LOG" "no-mistakes init must be invoked"

# (f) no-mistakes not installed -> skip, exit 0 (PATH without the fakebin or real binary)
out=$(PATH="/usr/bin:/bin" "$NM_GATE" "$WITHORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "missing no-mistakes should exit 0"
assert_contains "$out" "no-mistakes not installed" "missing-binary reason"

# (g) no-mistakes init fails -> warning, still exit 0 (non-fatal)
: > "$FM_FAKE_NM_INIT_LOG"
out=$(PATH="$FB:$PATH" FM_FAKE_NM_INIT_RC=1 "$NM_GATE" "$WITHORIGIN" 2>&1); rc=$?
expect_code 0 "$rc" "init failure must stay non-fatal (exit 0)"
assert_contains "$out" "warning" "init failure should warn"

# (h) fm-spawn's gate refresh timeout kills a stalled helper and still spawns
SPAWN_CASE="$TMP_ROOT/spawn-timeout"
SPAWN_HOME="$SPAWN_CASE/home"
SPAWN_PROJ="$SPAWN_CASE/project"
SPAWN_WT="$SPAWN_CASE/wt"
SPAWN_ID="nm-gate-timeout-z1"
mkdir -p "$SPAWN_HOME/data/$SPAWN_ID" "$SPAWN_HOME/state" "$SPAWN_HOME/config" "$SPAWN_HOME/projects"
printf 'brief\n' > "$SPAWN_HOME/data/$SPAWN_ID/brief.md"
fm_git_worktree "$SPAWN_PROJ" "$SPAWN_WT" "wt-$SPAWN_ID"
SPAWN_FAKEBIN=$(make_spawn_fakebin "$SPAWN_CASE/fake")
STALLING_ROOT=$(make_stalling_gate_root "$SPAWN_CASE")
out=$(
  export PATH="$SPAWN_FAKEBIN:$PATH"
  export FM_ROOT_OVERRIDE="$STALLING_ROOT"
  export FM_HOME="$SPAWN_HOME"
  export FM_STATE_OVERRIDE="$SPAWN_HOME/state"
  export FM_DATA_OVERRIDE="$SPAWN_HOME/data"
  export FM_PROJECTS_OVERRIDE="$SPAWN_HOME/projects"
  export FM_CONFIG_OVERRIDE="$SPAWN_HOME/config"
  export FM_SPAWN_NO_GUARD=1
  export TMUX="fake,1,0"
  export FM_FAKE_PANE_PATH="$SPAWN_WT"
  export FM_NM_GATE_TIMEOUT=1
  run_with_timeout 5 "$ROOT/bin/fm-spawn.sh" "$SPAWN_ID" "$SPAWN_PROJ" codex 2>&1
); rc=$?
expect_code 0 "$rc" "spawn gate timeout should not hang"$'\n'"$out"
assert_contains "$out" "warning: no-mistakes gate refresh timed out after 1s; gate may be stale" \
  "spawn should warn on gate timeout"
assert_contains "$out" "spawned $SPAWN_ID harness=codex kind=ship mode=no-mistakes" \
  "spawn should continue after gate timeout"
assert_present "$SPAWN_HOME/state/$SPAWN_ID.meta" "spawn should write meta after gate timeout"
assert_no_grep "jobs -r -p" "$ROOT/bin/fm-spawn.sh" "gate timeout must not depend on running job state"
rm -rf "/tmp/fm-$SPAWN_ID"

pass "fm-nm-gate.sh: usage, skip, refresh, non-fatal failure, and spawn timeout paths hold"
