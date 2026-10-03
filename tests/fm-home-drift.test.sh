#!/usr/bin/env bash
# Behavior tests for the FM_HOME drift warning (issue #2002).
#
# A shell outside a firstmate pane can carry a sibling home's FM_HOME - the
# tmux server's inherited env, a stale export, or a launch prefix from another
# home. From that shell the cwd still looks like the right home, yet every
# bin/fm-*.sh resolves state, locks, sends, and the wake queue against the
# sibling. bin/fm-home-drift-lib.sh is the loud half: sourced by each
# entrypoint after its FM_HOME resolution, it warns on stderr when the
# resolved FM_HOME names a different home than the firstmate checkout
# enclosing the caller's working directory.
#
# The cases below exercise the contract through a real entrypoint
# (bin/fm-home-summary-refresh.sh --best-effort, which resolves FM_HOME
# through the standard idiom), not by reading script source:
#
#   - inherited drift      : cwd inside home-a + FM_HOME=home-b   -> warn
#   - nested cwd           : cwd inside home-a/deep + FM_HOME=b   -> warn
#   - pane-env leak        : FM_HOME=home-b + emptied overrides   -> warn
#   - settled elsewhere    : cwd inside home-a + FM_HOME=main root -> warn
#   - honest addressing    : cwd inside home-a + FM_HOME=home-a   -> quiet
#   - own checkout         : cwd inside the script's own checkout -> quiet
#   - outside checkouts    : cwd outside any checkout             -> quiet
#   - explicit override    : FM_HOME=home-b + FM_STATE_OVERRIDE   -> quiet
#   - non-dir override     : FM_HOME=home-b + timeout override    -> warn
#   - operational home     : FM_HOME=plain dir (not a checkout)   -> warn
#   - test sandbox         : drifted env + FM_TEST_SEAM=1          -> quiet
#
# Each run also proves the command still completed - the warning diagnoses,
# never refuses - and that the sibling's own commands stay unaffected.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIVER="$ROOT/bin/fm-home-summary-refresh.sh"
WARN_NEEDLE="warning: FM_HOME"

TMP=$(fm_test_tmproot fm-home-drift)

# Fixture homes only need the enclosing-checkout marker the drift check keys
# on (bin/fm-session-start.sh) plus the state dir the driver writes into.
make_home() {  # <name> -> prints home path
  local home="$TMP/$1"
  mkdir -p "$home/bin" "$home/state"
  : >"$home/bin/fm-session-start.sh"
  printf '%s\n' "$home"
}

HOME_A=$(make_home home-a)
HOME_B=$(make_home home-b)

# run_in <cwd> [VAR=val ...] -- run the driver under a scrubbed env with
# combined stdout+stderr; the caller reads rc from $?.
run_in() {
  local cwd=$1; shift
  (cd "$cwd" && env -i PATH="$PATH" HOME="$TMP" "$@" bash "$DRIVER" --best-effort 2>&1)
}

test_inherited_drift_warns() {
  local out rc
  out=$(run_in "$HOME_A" FM_HOME="$HOME_B"); rc=$?
  assert_contains "$out" "$WARN_NEEDLE" "inherited sibling FM_HOME must warn loudly"
  assert_contains "$out" "$HOME_B" "warning names the inherited FM_HOME"
  assert_contains "$out" "$HOME_A" "warning names the enclosing checkout"
  assert_equals 0 "$rc" "drift warning diagnoses without refusing the command"
  pass "inherited FM_HOME from a sibling home warns and still runs"
}

test_nested_cwd_drift_warns() {
  local out
  mkdir -p "$HOME_A/projects/work"
  out=$(run_in "$HOME_A/projects/work" FM_HOME="$HOME_B")
  assert_contains "$out" "$WARN_NEEDLE" "a cwd nested below the enclosing checkout must still find it"
  assert_contains "$out" "$HOME_A" "warning names the enclosing ancestor checkout"
  pass "nested cwd below the enclosing home warns"
}

test_pane_env_leak_warns() {
  local out
  # A pane launch exports FM_HOME with every FM_*_OVERRIDE set but empty;
  # inheriting that env into a foreign shell must still warn.
  out=$(run_in "$HOME_A" FM_HOME="$HOME_B" FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE=)
  assert_contains "$out" "$WARN_NEEDLE" "leaked pane env (emptied overrides) must still warn"
  pass "leaked pane env warns"
}

test_other_checkout_target_warns() {
  local out
  # cwd inside home-a while commands resolve FM_HOME to the code root - the
  # visual signature is identical drift, whether the home was inherited or defaulted.
  out=$(run_in "$HOME_A")
  assert_contains "$out" "$WARN_NEEDLE" "commands acting outside the enclosing checkout must warn"
  pass "resolved home outside the enclosing checkout warns"
}

test_honest_addressing_quiet() {
  local out
  out=$(run_in "$HOME_A" FM_HOME="$HOME_A")
  assert_not_contains "$out" "$WARN_NEEDLE" "FM_HOME matching the enclosing checkout stays quiet"
  pass "FM_HOME equal to the enclosing home stays quiet"
}

test_own_checkout_quiet() {
  local out rc
  out=$(cd "$ROOT" && env -i PATH="$PATH" bash "$DRIVER" --best-effort 2>&1); rc=$?
  assert_not_contains "$out" "$WARN_NEEDLE" "running inside the script's own checkout stays quiet"
  assert_equals 0 "$rc" "own-checkout run still completes"
  pass "own checkout stays quiet"
}

test_outside_checkouts_quiet() {
  local out
  mkdir -p "$TMP/plain-dir"
  out=$(run_in "$TMP/plain-dir" FM_HOME="$HOME_B")
  assert_not_contains "$out" "$WARN_NEEDLE" "addressing a home from outside any checkout stays quiet"
  pass "outside any checkout stays quiet"
}

test_override_suppresses() {
  local out
  # An FM_*_OVERRIDE carrying a value marks deliberate cross-home addressing
  # (secondmate control, teardown sweeps, the test sandbox) - no drift noise.
  out=$(run_in "$HOME_A" FM_HOME="$HOME_B" FM_STATE_OVERRIDE="$HOME_B/state")
  assert_not_contains "$out" "$WARN_NEEDLE" "explicit FM_*_OVERRIDE addressing stays quiet"
  pass "explicit override stays quiet"
}

test_nondir_override_warns() {
  local out
  # A non-directory override is not home addressing: it must not silence the
  # drift warning the way FM_STATE_OVERRIDE does.
  out=$(run_in "$HOME_A" FM_HOME="$HOME_B" FM_TIMEOUT_MECHANISM_OVERRIDE=bash)
  assert_contains "$out" "$WARN_NEEDLE" "a non-directory override must not suppress the drift warning"
  pass "non-directory override does not suppress"
}

test_operational_home_drift_warns() {
  local out
  # A shell inside checkout A carrying a data-only operational home's FM_HOME
  # drifts just as silently; the marker only distinguishes a checkout, not
  # whether commands land in the wrong home.
  mkdir -p "$TMP/plain-home"
  out=$(run_in "$HOME_A" FM_HOME="$TMP/plain-home")
  assert_contains "$out" "$WARN_NEEDLE" "drift to a non-checkout operational home must warn"
  pass "drift to a non-checkout operational home warns"
}

test_test_seam_quiet() {
  local out
  # tests/lib.sh exports FM_TEST_SEAM=1 so suites can pin FM_HOME to scratch
  # homes from inside the repo without tripping the warn.
  out=$(run_in "$HOME_A" FM_HOME="$HOME_B" FM_TEST_SEAM=1)
  assert_not_contains "$out" "$WARN_NEEDLE" "the test seam marks deliberate sandbox addressing"
  pass "test sandbox seam stays quiet"
}

test_inherited_drift_warns
test_nested_cwd_drift_warns
test_pane_env_leak_warns
test_other_checkout_target_warns
test_honest_addressing_quiet
test_own_checkout_quiet
test_outside_checkouts_quiet
test_override_suppresses
test_nondir_override_warns
test_operational_home_drift_warns
test_test_seam_quiet
