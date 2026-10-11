#!/usr/bin/env bash
# The OpenCode watcher-arm plugin's arming predicate.
#
# A home whose only supervision need is a registered process-event source or a
# trust-bound custom check must arm the watcher after the last task ends, so the
# turn-end guard stops reporting supervision as off and the session is still
# woken. The predicate module the plugin imports is under test, each
# registered-need case is cross-checked against the bash predicate it mirrors
# (bin/fm-supervision-lib.sh's fm_supervision_status FM_SUP_NEEDED; the "a
# registered check is itself a reason to watch" contract lives in
# docs/configuration.md), and the real plugin factory is driven end to end to
# prove it consults the predicate. No OpenCode harness is spawned; the plugin's
# own arm child is a stub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"

# The predicate is its own module because OpenCode treats every export of a
# loaded plugin file as a plugin, so shouldArm cannot be exported from the
# plugin module for testing.
PREDICATE="$ROOT/.opencode/plugins/lib/fm-watch-arm-predicate.js"
TMP_ROOT=$(fm_test_tmproot fm-opencode-watch-arm-predicate)

# arm_verdict <state> <config>: print "true" or "false" from the real predicate
# module, loaded in a plain Node host.
arm_verdict() {
  STATE_DIR=$1 CONFIG_DIR=$2 PREDICATE_PATH="$PREDICATE" node --input-type=module 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PREDICATE_PATH).href);
const armed = mod.shouldArm({ state: process.env.STATE_DIR, config: process.env.CONFIG_DIR });
process.stdout.write(armed ? "true" : "false");
JS
}

# make_home <name>: create a fresh state/config pair and echo its state dir.
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  printf '%s\n' "$dir/state"
}

expect_arm() {  # <label> <state> <config> <expected>
  local label=$1 state=$2 config=$3 expected=$4 out
  out=$(arm_verdict "$state" "$config")
  [ "$out" = "$expected" ] || fail "$label: shouldArm returned '$out', expected '$expected'"
}

# assert_bash_needs <label> <state> <expected>: the bash FM_SUP_NEEDED predicate
# this plugin mirrors must agree on the fixture.
assert_bash_needs() {
  local label=$1 state=$2 expected=$3
  fm_supervision_status "$state" 300
  [ "$FM_SUP_NEEDED" = "$expected" ] \
    || fail "$label: fm_supervision_status reported FM_SUP_NEEDED=$FM_SUP_NEEDED, expected $expected"
}

test_registered_check_arms() {
  local state
  state=$(make_home check-only)
  : > "$state/tool-updates.check.sh"
  : > "$state/tool-updates.check-trust"
  expect_arm "registered custom check" "$state" "$TMP_ROOT/check-only/config" true
  assert_bash_needs "registered custom check" "$state" true
  pass "shouldArm: a home with only a registered custom check arms"
}

test_registered_source_arms() {
  local state
  state=$(make_home source-only)
  mkdir -p "$state/procevent"
  : > "$state/procevent/job.source"
  expect_arm "registered process-event source" "$state" "$TMP_ROOT/source-only/config" true
  assert_bash_needs "registered process-event source" "$state" true
  pass "shouldArm: a home with only a registered process-event source arms"
}

test_untrusted_check_does_not_arm() {
  local state
  state=$(make_home untrusted-check)
  : > "$state/tool-updates.check.sh"
  expect_arm "untrusted custom check" "$state" "$TMP_ROOT/untrusted-check/config" false
  assert_bash_needs "untrusted custom check" "$state" false
  pass "shouldArm: a custom check without its trust binding does not arm"
}

test_x_watch_shim_is_excluded() {
  local state
  state=$(make_home x-watch)
  # X-mode's relay poll owns this shim; the plugin reads X-mode from
  # config/x-mode.env, so the check-scan must skip x-watch rather than treat it
  # as a registered custom check.
  : > "$state/x-watch.check.sh"
  : > "$state/x-watch.check-trust"
  expect_arm "x-watch shim only" "$state" "$TMP_ROOT/x-watch/config" false
  pass "shouldArm: X-mode's x-watch shim is not counted as a registered custom check"
}

test_x_mode_env_arms() {
  local state
  state=$(make_home x-mode)
  : > "$TMP_ROOT/x-mode/config/x-mode.env"
  expect_arm "config/x-mode.env" "$state" "$TMP_ROOT/x-mode/config" true
  pass "shouldArm: config/x-mode.env still arms (X-mode relay preserved)"
}

test_in_flight_task_arms() {
  local state
  state=$(make_home in-flight)
  : > "$state/task1.meta"
  expect_arm "in-flight task" "$state" "$TMP_ROOT/in-flight/config" true
  pass "shouldArm: an in-flight task still arms"
}

test_afk_record_still_wins() {
  local state
  state=$(make_home afk)
  : > "$state/.afk"
  : > "$state/tool-updates.check.sh"
  : > "$state/tool-updates.check-trust"
  expect_arm "away record with a registered check" "$state" "$TMP_ROOT/afk/config" false
  pass "shouldArm: state/.afk still suppresses arming"
}

test_empty_home_does_not_arm() {
  local state
  state=$(make_home empty)
  expect_arm "empty home" "$state" "$TMP_ROOT/empty/config" false
  assert_bash_needs "empty home" "$state" false
  pass "shouldArm: an empty home does not arm"
}

# --- plugin wiring -----------------------------------------------------------
#
# The predicate unit cases above would still pass if the plugin stopped calling
# shouldArm, so drive the real plugin factory end to end. ensureArm returns
# "not-needed" exactly when shouldArm is false, and otherwise starts a stub arm
# (the plugin must arm for the fixture, which is the regression).

PLUGIN="$ROOT/.opencode/plugins/fm-primary-watch-arm.js"

# make_primary_root <name>: a primary-shaped checkout (plain git repo, AGENTS.md,
# bin/ with a stub arm) plus its state/config dirs, echoing the resolved root.
make_primary_root() {
  local dir="$TMP_ROOT/$1" stub
  mkdir -p "$dir/bin" "$dir/state" "$dir/config"
  git init -q "$dir"
  : > "$dir/AGENTS.md"
  stub="$dir/bin/fm-watch-arm.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub"
  chmod +x "$stub"
  (cd "$dir" && pwd -P)
}

# make_linked_root <name>: a genuine linked `git worktree` (git-dir !=
# git-common-dir) shaped like a primary checkout (AGENTS.md, bin/ with a stub
# arm) plus its state/config dirs, echoing the resolved root. This is the shape
# a treehouse lease hands a second-mate home or a crewmate/scout worktree.
make_linked_root() {
  local dir="$TMP_ROOT/$1" base="$TMP_ROOT/$1-base" stub
  fm_git_worktree "$base" "$dir" "fm/watcher-$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/bin"
  : > "$dir/AGENTS.md"
  stub="$dir/bin/fm-watch-arm.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$stub"
  chmod +x "$stub"
  (cd "$dir" && pwd -P)
}

# assert_linked_worktree <label> <root>: the fixture must really have git-dir
# distinct from git-common-dir, or the case cannot exercise the linked-worktree
# branch and could pass vacuously on a plain checkout.
assert_linked_worktree() {
  local label=$1 root=$2
  [ "$(git -C "$root" rev-parse --git-dir)" != "$(git -C "$root" rev-parse --git-common-dir)" ] \
    || fail "$label: fixture is not a linked worktree (git-dir == git-common-dir)"
}

# drive_plugin_arm <root> <state> <config>: write the lock that names this Node
# process, load the plugin factory, and print the ensureArm status it returns.
drive_plugin_arm() {
  FIXTURE_ROOT=$1 STATE_DIR=$2 CONFIG_DIR=$3 PLUGIN_PATH="$PLUGIN" \
    FM_ROOT_OVERRIDE=$1 FM_HOME=$1 FM_STATE_OVERRIDE=$2 FM_CONFIG_OVERRIDE=$3 \
    FM_OPENCODE_ARM_READY_TIMEOUT_MS=500 \
    node --input-type=module 2>&1 <<'JS'
import { mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
mkdirSync(process.env.STATE_DIR, { recursive: true });
writeFileSync(`${process.env.STATE_DIR}/.lock`, String(process.pid));
const mod = await import(pathToFileURL(process.env.PLUGIN_PATH).href);
const client = { session: { promptAsync: async () => {} } };
await mod.FmPrimaryWatchArm({ client, directory: process.env.FIXTURE_ROOT, worktree: process.env.FIXTURE_ROOT });
process.stdout.write(String(await globalThis.__firstmateOpenCodeWatchArm.ensureArmed("ses_test", client)));
JS
}

test_plugin_arms_for_registered_check() {
  local root status
  root=$(make_primary_root plugin-check)
  : > "$root/state/tool-updates.check.sh"
  : > "$root/state/tool-updates.check-trust"
  status=$(drive_plugin_arm "$root" "$root/state" "$root/config")
  [ "$status" != "not-needed" ] \
    || fail "plugin reported 'not-needed' for a home with only a registered check"
  pass "plugin: a home with only a registered custom check arms"
}

test_plugin_arms_for_registered_source() {
  local root status
  root=$(make_primary_root plugin-source)
  mkdir -p "$root/state/procevent"
  : > "$root/state/procevent/job.source"
  status=$(drive_plugin_arm "$root" "$root/state" "$root/config")
  [ "$status" != "not-needed" ] \
    || fail "plugin reported 'not-needed' for a home with only a registered source"
  pass "plugin: a home with only a registered process-event source arms"
}

test_plugin_not_needed_for_empty_home() {
  local root status
  root=$(make_primary_root plugin-empty)
  status=$(drive_plugin_arm "$root" "$root/state" "$root/config")
  [ "$status" = "not-needed" ] \
    || fail "plugin armed for an empty home (status '$status')"
  pass "plugin: an empty home reports not-needed"
}

# A treehouse-leased OpenCode SECOND MATE home is a genuine linked worktree
# carrying .fm-secondmate-home. It must arm its OWN watcher despite git-dir !=
# git-common-dir; the marker is what distinguishes it from a crewmate/scout
# worktree. The stub arm sits at the home's own bin/, which is what the turn-end
# guard requires.
test_plugin_arms_for_secondmate_linked_home() {
  local root status
  root=$(make_linked_root plugin-sm-home)
  printf 'sm-test-1\n' > "$root/.fm-secondmate-home"
  : > "$root/state/task1.meta"
  assert_linked_worktree "secondmate home" "$root"
  status=$(drive_plugin_arm "$root" "$root/state" "$root/config")
  [ "$status" != "not-primary" ] \
    || fail "plugin rejected a treehouse-leased secondmate home (status '$status')"
  [ "$status" != "not-needed" ] \
    || fail "plugin reported 'not-needed' for a secondmate home with an in-flight task"
  pass "plugin: a treehouse-leased secondmate home (linked worktree with marker) arms"
}

# A plain linked worktree with no .fm-secondmate-home is a crewmate/scout
# worktree and must stay silent: isPrimaryRoot rejects it before any arm.
test_plugin_silent_in_linked_worktree() {
  local root status
  root=$(make_linked_root plugin-crew-wt)
  : > "$root/state/task1.meta"
  assert_linked_worktree "crewmate worktree" "$root"
  status=$(drive_plugin_arm "$root" "$root/state" "$root/config")
  [ "$status" = "not-primary" ] \
    || fail "plugin did not reject a plain linked worktree (status '$status')"
  pass "plugin: a plain linked crewmate/scout worktree does not arm"
}

test_registered_check_arms
test_registered_source_arms
test_untrusted_check_does_not_arm
test_x_watch_shim_is_excluded
test_x_mode_env_arms
test_in_flight_task_arms
test_afk_record_still_wins
test_empty_home_does_not_arm
test_plugin_arms_for_registered_check
test_plugin_arms_for_registered_source
test_plugin_not_needed_for_empty_home
test_plugin_arms_for_secondmate_linked_home
test_plugin_silent_in_linked_worktree
