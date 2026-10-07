#!/usr/bin/env bash
# Behavior tests for per-project no-mistakes home routing
# (config/no-mistakes-homes; bin/fm-nm-home-lib.sh).
#
# Spawn cases drive the real fm-spawn.sh through the shared fake tmux, which
# records the launch command, then run that command in a synthetic pane whose
# ambient environment names another no-mistakes home. Each mapped home is a
# directory holding a config.yaml whose agent_path_override.claude names a fake
# account wrapper; the wrapper answers `auth status` from a marker file in its
# own directory, so no test reads a credential, and no test starts, stops, or
# restarts a daemon. Reader cases source bin/fm-nm-run-lib.sh and observe the
# NM_HOME a fake no-mistakes receives.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-home)
unset NM_HOME LAVISH_AXI_HOST ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN

# new_case <name> -> sets CASE HOME_DIR PROJ WT FAKEBIN
# The project clone is named bookie, so the routing key is "bookie".
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/bookie"
  WT="$CASE/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE/fake")
  cat > "$FAKEBIN/claude" <<SH
#!/usr/bin/env bash
printf 'NM_HOME=%s\n' "\${NM_HOME-unset}" > '$CASE/worker'
SH
  chmod +x "$FAKEBIN/claude"
  fm_test_spawn_home "$HOME_DIR" claude
  fm_git_worktree "$PROJ" "$WT" "wt-$1"
  : > "$CASE/launch.log"
}

# make_nm_home <dir> [signed-in|signed-out]
# A no-mistakes home whose config.yaml routes Claude to an executable account
# wrapper. The wrapper logs every sign-in check with the environment it saw.
make_nm_home() {
  local dir=$1 login=${2:-signed-in}
  mkdir -p "$dir/bin"
  cat > "$dir/bin/claude-account" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = auth ] && [ "\${2:-}" = status ]; then
  printf 'key=%s\n' "\${ANTHROPIC_API_KEY-unset}" >> '$dir/checks'
  [ -f '$dir/bin/signed-in' ]
  exit
fi
exit 0
SH
  chmod +x "$dir/bin/claude-account"
  [ "$login" != signed-in ] || : > "$dir/bin/signed-in"
  cat > "$dir/config.yaml" <<YAML
# no-mistakes global configuration
agent: claude

# agent_path_override:
#   claude: /not/this/one
agent_path_override:
  # the personal account
  claude: "$dir/bin/claude-account"  # wrapper
  codex: /opt/codex

ci_timeout: "168h"
YAML
}

map_project() { # <project> <root>
  printf '%s %s\n' "$1" "$2" >> "$HOME_DIR/config/no-mistakes-homes"
}

# spawn_ship <id> [fm-spawn args...]: a ship spawn whose invoking process
# carries an ambient NM_HOME and an ambient Claude credential.
spawn_ship() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id"
  : > "$CASE/launch.log"
  FM_FAKE_LAUNCH_LOG="$CASE/launch.log" NM_HOME="$CASE/ambient-nm" ANTHROPIC_API_KEY=ambient-key \
    fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$id" "$PROJ" --yolo off "$@"
}

# run_pane: execute the recorded launch in a pane whose ambient environment
# names another no-mistakes home.
run_pane() {
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" TERM=xterm NM_HOME="$CASE/pane-nm" \
    bash -c "$(cat "$CASE/launch.log")" || fail "the recorded launch failed in the synthetic pane"
}

# assert_refused_before_launch <id> <out> <needle>
assert_refused_before_launch() {
  local id=$1 out=$2 needle=$3
  assert_contains "$out" "$needle" "the refusal should say: $needle"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
}

test_unmapped_project_launches_unchanged() {
  local out rc
  new_case unmapped
  out=$(spawn_ship nm-unmapped --mode no-mistakes); rc=$?
  expect_code 0 "$rc" "a spawn with no routing file should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "NM_HOME" "a launch with no routing file must not name a no-mistakes home"
  run_pane
  assert_grep "NM_HOME=$CASE/pane-nm" "$CASE/worker" "an unrouted worker keeps its pane's own environment"

  new_case other-project
  make_nm_home "$CASE/nm-work"
  map_project vibrantly "$CASE/nm-work"
  out=$(spawn_ship nm-other --mode no-mistakes); rc=$?
  expect_code 0 "$rc" "a spawn of a project the file does not name should succeed: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "NM_HOME" "another project's route must not reach this launch"
  assert_absent "$CASE/nm-work/checks" "another project's account must not be checked"
  pass "an unmapped project launches exactly as before"
}

test_mapped_project_launches_on_its_home() {
  local out rc
  new_case mapped
  make_nm_home "$CASE/nm-personal"
  make_nm_home "$CASE/nm-work"
  printf '# local routing\n\n' > "$HOME_DIR/config/no-mistakes-homes"
  map_project bookie "$CASE/nm-personal/"
  map_project vibrantly "$CASE/nm-work"
  out=$(spawn_ship nm-mapped --mode no-mistakes); rc=$?
  expect_code 0 "$rc" "a routed no-mistakes ship should spawn: $out"
  run_pane
  assert_equals "NM_HOME=$CASE/nm-personal" "$(cat "$CASE/worker")" "a routed worker must run on its project's no-mistakes home"
  assert_grep "key=unset" "$CASE/nm-personal/checks" "the account check must not see the caller's credentials"
  assert_absent "$CASE/nm-work/checks" "only the routed project's account is checked"

  git -C "$PROJ" remote add no-mistakes "$CASE/nm-personal/repos/abc123.git"
  out=$(spawn_ship nm-mapped-gate --mode no-mistakes); rc=$?
  expect_code 0 "$rc" "a routed ship whose gate already sits under that home should spawn: $out"
  run_pane
  assert_equals "NM_HOME=$CASE/nm-personal" "$(cat "$CASE/worker")" "the gate under the routed home keeps the route"
  pass "a mapped project's no-mistakes ship launches on that project's home"
}

test_route_applies_only_to_no_mistakes_ships() {
  local out rc
  new_case direct
  make_nm_home "$CASE/nm-personal" signed-out
  map_project bookie "$CASE/nm-personal"
  out=$(spawn_ship nm-direct --mode direct-PR); rc=$?
  expect_code 0 "$rc" "a direct-PR ship of a routed project should spawn: $out"
  assert_not_contains "$(cat "$CASE/launch.log")" "NM_HOME" "a ship that runs no pipeline must not name a no-mistakes home"
  assert_absent "$CASE/nm-personal/checks" "a ship that runs no pipeline must not check the pipeline account"
  pass "only a no-mistakes ship is routed"
}

test_malformed_routing_refuses() {
  local out
  new_case malformed
  make_nm_home "$CASE/nm-personal"
  printf 'bookie relative/path\n' > "$HOME_DIR/config/no-mistakes-homes"
  out=$(spawn_ship nm-bad-path --mode no-mistakes)
  assert_refused_before_launch nm-bad-path "$out" "line 1 must be <project> <absolute NM_HOME>"

  printf 'bookie %s\nbookie %s\n' "$CASE/nm-personal" "$CASE/nm-personal" > "$HOME_DIR/config/no-mistakes-homes"
  out=$(spawn_ship nm-dup --mode no-mistakes)
  assert_refused_before_launch nm-dup "$out" "maps project bookie more than once"

  rm -f "$HOME_DIR/config/no-mistakes-homes"
  mkdir "$HOME_DIR/config/no-mistakes-homes"
  out=$(spawn_ship nm-dir --mode no-mistakes)
  assert_refused_before_launch nm-dir "$out" "must be a readable regular file"
  pass "a malformed routing file refuses before launch"
}

test_unavailable_home_refuses() {
  local out
  new_case missing-home
  map_project bookie "$CASE/nowhere"
  out=$(spawn_ship nm-missing --mode no-mistakes)
  assert_refused_before_launch nm-missing "$out" "not a readable no-mistakes home holding config.yaml"

  new_case no-override
  make_nm_home "$CASE/nm-personal"
  printf 'agent: claude\n' > "$CASE/nm-personal/config.yaml"
  map_project bookie "$CASE/nm-personal"
  out=$(spawn_ship nm-no-override --mode no-mistakes)
  assert_refused_before_launch nm-no-override "$out" "does not set agent_path_override.claude"

  new_case flow-override
  make_nm_home "$CASE/nm-personal"
  printf 'agent_path_override: {claude: %s}\n' "$CASE/nm-personal/bin/claude-account" > "$CASE/nm-personal/config.yaml"
  map_project bookie "$CASE/nm-personal"
  out=$(spawn_ship nm-flow --mode no-mistakes)
  assert_refused_before_launch nm-flow "$out" "does not set agent_path_override.claude (block form)"

  new_case alias-wrapper
  make_nm_home "$CASE/nm-personal"
  chmod -x "$CASE/nm-personal/bin/claude-account"
  map_project bookie "$CASE/nm-personal"
  out=$(spawn_ship nm-noexec --mode no-mistakes)
  assert_refused_before_launch nm-noexec "$out" "is not an executable file"
  pass "an unusable no-mistakes home or account wrapper refuses before launch"
}

test_signed_out_account_refuses_despite_ambient_credentials() {
  local out
  new_case signed-out
  make_nm_home "$CASE/nm-personal" signed-out
  map_project bookie "$CASE/nm-personal"
  out=$(spawn_ship nm-signed-out --mode no-mistakes)
  assert_refused_before_launch nm-signed-out "$out" "is not signed in"
  assert_grep "key=unset" "$CASE/nm-personal/checks" "an ambient credential must not answer the account check"
  pass "a signed-out account refuses even when the caller holds a credential"
}

test_gate_under_another_home_refuses() {
  local out
  new_case gate-mismatch
  make_nm_home "$CASE/nm-personal"
  map_project bookie "$CASE/nm-personal"
  git -C "$PROJ" remote add no-mistakes "$CASE/default-nm/repos/abc123.git"
  out=$(spawn_ship nm-gate --mode no-mistakes)
  assert_refused_before_launch nm-gate "$out" "its gate is registered under $CASE/default-nm"

  git -C "$PROJ" remote set-url no-mistakes https://example.invalid/gate.git
  out=$(spawn_ship nm-gate-foreign --mode no-mistakes)
  assert_refused_before_launch nm-gate-foreign "$out" "not a managed gate path"
  pass "a gate registered under another home refuses before launch"
}

test_raw_command_cannot_override_the_route() {
  local out rc
  new_case raw
  make_nm_home "$CASE/nm-personal"
  map_project bookie "$CASE/nm-personal"
  out=$(spawn_ship nm-raw-override --mode no-mistakes "NM_HOME=$CASE/elsewhere claude")
  assert_refused_before_launch nm-raw-override "$out" "the raw launch command sets NM_HOME"

  out=$(spawn_ship nm-raw --mode no-mistakes "claude"); rc=$?
  expect_code 0 "$rc" "a raw command that leaves NM_HOME alone should spawn: $out"
  run_pane
  assert_equals "NM_HOME=$CASE/nm-personal" "$(cat "$CASE/worker")" "a raw launch must receive the route"
  pass "a raw launch command receives the route and cannot override it"
}

# --- Firstmate's own no-mistakes reads -------------------------------------

# reader_world -> sets RW (a checkout) and RFAKE (a fakebin whose no-mistakes
# prints the NM_HOME it received).
reader_world() {
  RW="$TMP_ROOT/reader/repo"
  RFAKE=$(fm_fakebin "$TMP_ROOT/reader")
  mkdir -p "$RW"
  git -C "$RW" init --quiet
  cat > "$RFAKE/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${NM_HOME-unset}"
SH
  chmod +x "$RFAKE/no-mistakes"
}

# reader <args...>: run one fm-nm-run-lib function from checkout RW under bash.
reader() {
  # shellcheck disable=SC2016  # $1 and $@ expand in the inner bash.
  env -u NM_HOME PATH="$RFAKE:$PATH" bash -c '. "$1/bin/fm-nm-run-lib.sh"; shift; "$@"' _ "$ROOT" "$@"
}

test_reads_follow_the_checkout_gate() {
  local out
  reader_world
  out=$(reader fm_nm_run_checked "$RW" 10 axi status)
  assert_equals "unset" "$out" "a checkout with no gate reads the default home"
  assert_equals "$HOME/.no-mistakes/state.sqlite" "$(reader fm_nm_state_db "$RW")" "no gate means the default database"

  git -C "$RW" remote add no-mistakes "$TMP_ROOT/nm-personal/repos/abc123.git"
  out=$(reader fm_nm_run_checked "$RW" 10 axi status)
  assert_equals "$TMP_ROOT/nm-personal" "$out" "a read must reach the home that owns the checkout's gate"
  assert_equals "$TMP_ROOT/nm-personal/state.sqlite" "$(reader fm_nm_state_db "$RW")" \
    "the run database must come from the gate's home"

  # shellcheck disable=SC2016  # $1 and $2 expand in the inner bash.
  out=$(NM_HOME="$TMP_ROOT/explicit" PATH="$RFAKE:$PATH" bash -c '. "$1/bin/fm-nm-run-lib.sh"; fm_nm_run_checked "$2" 10 axi status' _ "$ROOT" "$RW")
  assert_equals "$TMP_ROOT/explicit" "$out" "an explicit NM_HOME still wins"

  git -C "$RW" remote set-url no-mistakes https://example.invalid/gate.git
  out=$(reader fm_nm_run_checked "$RW" 10 axi status)
  assert_equals "unset" "$out" "a remote that is not a managed gate leaves the default home"
  pass "Firstmate's no-mistakes reads follow the home that owns the checkout's gate"
}

test_unmapped_project_launches_unchanged
test_mapped_project_launches_on_its_home
test_route_applies_only_to_no_mistakes_ships
test_malformed_routing_refuses
test_unavailable_home_refuses
test_signed_out_account_refuses_despite_ambient_credentials
test_gate_under_another_home_refuses
test_raw_command_cannot_override_the_route
test_reads_follow_the_checkout_gate
