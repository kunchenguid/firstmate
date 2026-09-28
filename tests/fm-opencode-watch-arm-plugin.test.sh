#!/usr/bin/env bash
# tests/fm-opencode-watch-arm-plugin.test.sh - the OpenCode primary plugin's
# arm-need decision (.opencode/plugins/fm-primary-watch-arm.js's shouldArm).
#
# shouldArm decides whether the plugin auto-arms a watcher on session.idle.
# It used to reimplement a partial copy of "does this home need supervision"
# (only state/*.meta or config/x-mode.env), which drifted from the canonical
# predicate in bin/fm-supervision-lib.sh (fm_supervision_needed) that the
# turn-end guard uses. A home with a registered custom check and no in-flight
# task then satisfied the guard's need but not the plugin's, so the plugin
# never armed and every idle re-triggered "TURN WOULD END BLIND" until a human
# manually ran bin/fm-watch-arm.sh. These are real-process tests: the plugin's
# exported coordinator (globalThis.__firstmateOpenCodeWatchArm, the same one
# fm-primary-turnend-guard.js calls) drives the real bin/fm-watch-arm.sh and
# bin/fm-watch.sh against an isolated state directory, with no live harness or
# model call.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export NODE_NO_WARNINGS=1

PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"
CHECK_REGISTER="$ROOT/bin/fm-check-register.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-watch-arm)

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

wait_for_pid_file() {  # <path> <timeout-seconds>
  local path=$1 timeout=$2 i=0
  while [ "$i" -lt "$timeout" ]; do
    [ -s "$path" ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

register_fixture_check() {  # <state>
  local state=$1
  local check="$state/fixture-check.check.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$check"
  chmod 700 "$check"
  FM_STATE_OVERRIDE="$state" "$CHECK_REGISTER" fixture-check >/dev/null \
    || fail "could not register the fixture custom check"
}

# setup_repo_root <dir>: a plain (never a worktree) git-init'ed directory
# satisfying isPrimaryRoot's own-checkout check, with bin/ symlinked to this
# checkout's real bin/ so the plugin execs the genuine, current
# fm-watch-arm.sh, fm-watch.sh, and fm-supervision-lib.sh - not a fixture.
# $ROOT itself cannot stand in for this: these tests may run from a
# disposable task worktree, where $ROOT's own git-dir sits under
# .git/worktrees/ and diverges from git-common-dir, so isPrimaryRoot would
# always report not-primary regardless of what shouldArm decides.
setup_repo_root() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git init -q "$dir"
  ln -s "$ROOT/bin" "$dir/bin"
  : > "$dir/AGENTS.md"
}

# drive_watch_arm_plugin <root> <state> <config>: load the real OpenCode
# watch-arm plugin in a plain Node host, fire a session.idle event through the
# same exported coordinator fm-primary-turnend-guard.js calls, and print the
# resolved arm status (armed|not-needed|not-primary|read-only|...).
drive_watch_arm_plugin() {
  local root=$1 state=$2 config=$3
  FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$config" \
    FM_HOME="$root" FM_ROOT_OVERRIDE="$root" PLUGIN_PATH="$PLUGIN" \
    node --input-type=module - <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";

// Satisfies sessionOwnsLock: this process's own pid is trivially its own
// ancestor, so no real primary session lock is needed for the check.
writeFileSync(`${process.env.FM_STATE_OVERRIDE}/.lock`, `${process.pid}\n`);

const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({ client, directory: process.env.FM_ROOT_OVERRIDE });

const status = await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("test-session", client);
// console.log + immediate process.exit can truncate a piped stdout write;
// wait for the write's own callback instead.
process.stdout.write(`${status}\n`, () => process.exit(0));
EOF
}

test_arms_for_registered_check_with_no_in_flight_work() {
  local root state config status pid
  root="$TMP_ROOT/check-only/root"
  state="$TMP_ROOT/check-only/state"
  config="$TMP_ROOT/check-only/config"
  fm_test_track_watcher_state "$state"
  mkdir -p "$state" "$config"
  setup_repo_root "$root"
  register_fixture_check "$state"

  status=$(drive_watch_arm_plugin "$root" "$state" "$config") \
    || fail "plugin driver failed for the registered-check case: $status"
  [ "$status" = armed ] \
    || fail "a registered custom check with no in-flight work must still arm a watcher, got '$status'"

  wait_for_pid_file "$state/.watch.lock/pid" 10 \
    || fail "plugin reported armed but no watcher lock ever appeared"
  pid=$(cat "$state/.watch.lock/pid")
  kill -0 "$pid" 2>/dev/null \
    || fail "plugin reported armed but the watcher pid is not alive"
  pass "OpenCode watch-arm plugin arms a watcher for a registered custom check with no in-flight work"
}

test_does_not_arm_with_nothing_registered() {
  local root state config status
  root="$TMP_ROOT/nothing/root"
  state="$TMP_ROOT/nothing/state"
  config="$TMP_ROOT/nothing/config"
  fm_test_track_watcher_state "$state"
  mkdir -p "$state" "$config"
  setup_repo_root "$root"

  status=$(drive_watch_arm_plugin "$root" "$state" "$config") \
    || fail "plugin driver failed for the nothing-registered case: $status"
  [ "$status" = not-needed ] \
    || fail "a home with no in-flight work, no registered check, and no X-mode must not arm, got '$status'"
  [ ! -e "$state/.watch.lock" ] \
    || fail "plugin reported not-needed but still created a watcher lock"
  pass "OpenCode watch-arm plugin does not arm when nothing needs supervision"
}

test_arms_for_registered_check_with_no_in_flight_work
test_does_not_arm_with_nothing_registered
