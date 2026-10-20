#!/usr/bin/env bash
# Behavior tests for bin/fm-pi-trust.sh and the pi/pi-signed spawn that calls it.
#
# The contract has two halves and both are proven here: the registration writes
# Pi's own trust store for exactly the worktree path a spawn will use (and only
# that path), and every failure mode stops the spawn instead of launching a
# worker that would park on "Trust project folder?" with nobody to press Enter.
#
# NO TEST TOUCHES THE REAL USER STORE. Every script-level case runs with an
# isolated HOME and an explicit --agent-dir under the fixture root, and every
# spawn case runs under tests/fixtures.sh's throwaway spawn HOME, whose Pi agent
# root is `$home/user-home/.pi/agent`. PI_CODING_AGENT_DIR is cleared at the top
# so the invoking shell cannot redirect a case at the developer's ~/.pi.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-trust)
TRUST="$ROOT/bin/fm-pi-trust.sh"
unset PI_CODING_AGENT_DIR

# make_case <name>: a project with one linked worktree, an isolated user HOME,
# and an isolated Pi agent root. Echoes "<dir>|<proj>|<wt>|<home>|<agent>".
make_case() {
  local name=$1 dir proj wt home agent
  dir="$TMP_ROOT/$name"
  proj="$dir/project"
  wt="$dir/wt"
  home="$dir/home"
  agent="$dir/agent"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s|%s\n' "$dir" "$proj" "$wt" "$home" "$agent"
}

read_case() {
  IFS='|' read -r CASE PROJ WT USER_HOME AGENT <<EOF
$1
EOF
}

# run_trust <worktree> <project> [extra args...]: invoke with the isolated HOME.
run_trust() {
  HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$@" 2>&1
}

wt_real() { (cd -P -- "$WT" && pwd -P); }

# trust_entry <store> <path>: prints the JSON value recorded for one path.
trust_entry() {
  node -e 'const fs=require("node:fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(j[process.argv[2]]===undefined?"absent":JSON.stringify(j[process.argv[2]]));' "$1" "$2"
}

trust_keys() {
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(Object.keys(j).join("\n"));' "$1"
}

assert_trusted() {  # <store> <path> <msg>
  [ "$(trust_entry "$1" "$2")" = true ] || fail "$3"
}

assert_trusted_only() {  # <store> <path> <msg>: exactly one key, this path, true
  assert_trusted "$1" "$2" "$3"
  [ "$(trust_keys "$1")" = "$2" ] || fail "$3 (store also carries: $(trust_keys "$1" | tr '\n' ' '))"
}

# --- the registration itself ------------------------------------------------

test_fresh_worktree_is_registered() {
  local rec out store
  rec=$(make_case fresh)
  read_case "$rec"
  store="$AGENT/trust.json"

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be registered: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  assert_trusted_only "$store" "$(wt_real)" "the worktree was not recorded as a trusted path"
  assert_contains "$out" "$(wt_real)" "registration did not report the resolved path it recorded"
  # The staged write is renamed into place, so no temporary store may survive it.
  [ -z "$(find "$AGENT" -maxdepth 1 -name '.trust.json.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the agent root"
  pass "a fresh task worktree is registered in Pi's own trust store"
}

# Pi keys its store by canonical path and writes sorted, two-space JSON, so the
# registration must name the realpath (a symlinked fixture root proves the
# difference) and must leave the vendor's own file shape readable.
test_symlinked_fixture_registers_the_realpath() {
  local rec out real link store
  rec=$(make_case symlink)
  read_case "$rec"
  store="$AGENT/trust.json"
  real=$(wt_real)
  link="$CASE/wt-link"
  ln -s "$WT" "$link"

  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$link" "$PROJ" 2>&1)
  expect_code 0 $? "a worktree reached through a symlink must be registered: $out"
  assert_trusted_only "$store" "$real" "the store must carry the canonical path, not the logical one"
  pass "registration records the canonical worktree path Pi itself would key on"
}

test_existing_registration_is_a_noop() {
  local rec out store before after
  rec=$(make_case existing)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  cat > "$store" <<EOF
{
  "$(wt_real)": true,
  "/somewhere/else": false,
  "/another/place": null
}
EOF
  before=$(cat "$store")

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "an already-registered worktree must succeed: $out"
  assert_contains "$out" "already trusted:" "an existing entry must be reported as already trusted"
  after=$(cat "$store")
  [ "$after" = "$before" ] || fail "an already-registered worktree must not rewrite the store:"$'\n'"before: $before"$'\n'"after:  $after"
  [ "$(trust_entry "$store" /somewhere/else)" = false ] || fail "an unrelated declined entry must stay false"
  [ "$(trust_entry "$store" /another/place)" = null ] || fail "an unrelated undecided entry must stay null"
  pass "an existing registration is idempotent and leaves every other entry untouched"
}

test_unrelated_entries_survive_a_new_registration() {
  local rec out store
  rec=$(make_case preserve)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  printf '{\n  "/keep/me": true,\n  "/keep/me/too": false\n}\n' > "$store"

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a registration beside existing entries must succeed: $out"
  assert_trusted "$store" "$(wt_real)" "the new worktree was not recorded"
  [ "$(trust_entry "$store" /keep/me)" = true ] || fail "an unrelated trusted entry was lost"
  [ "$(trust_entry "$store" /keep/me/too)" = false ] || fail "an unrelated declined entry was lost"
  pass "a new registration preserves every existing trust entry"
}

# The dialog gate reads a recorded decision before it ever prompts, so a
# recorded "Do not trust" is a human decision - the spawn stops and reports
# instead of reversing it or launching into the dialog anyway.
test_recorded_decline_is_refused() {
  local rec out store before
  rec=$(make_case decline)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  printf '{\n  "%s": false\n}\n' "$(wt_real)" > "$store"
  before=$(cat "$store")

  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "a recorded decline must refuse rather than be reversed: $out"
  assert_contains "$out" "Do not trust" "the refusal must name the recorded decision it will not reverse"
  [ "$(cat "$store")" = "$before" ] || fail "a refused registration must not rewrite the store"
  pass "a recorded 'Do not trust' decision refuses the spawn instead of being reversed"
}

# --- failure is loud --------------------------------------------------------

test_write_failure_refuses_loudly() {
  local rec out store
  rec=$(make_case unwritable)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  chmod 500 "$AGENT"

  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "a store that cannot be written must refuse: $out"
  assert_contains "$out" "refusing to pre-register Pi trust" "the refusal must say what it was doing"
  assert_contains "$out" "$store" "the refusal must name the store it could not write"
  chmod 700 "$AGENT"
  assert_absent "$store" "a failed registration must not leave a partial store"
  pass "an unwritable store fails loudly and leaves nothing behind"
}

test_malformed_store_refuses_loudly() {
  local rec out store
  rec=$(make_case malformed)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  printf '[]\n' > "$store"

  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "a non-object store must refuse: $out"
  assert_contains "$out" "$store" "the refusal must name the store it could not read"
  [ "$(cat "$store")" = '[]' ] || fail "a refused registration must not overwrite the store"
  pass "a malformed store fails loudly instead of being rewritten"

  printf '{"%s": "yes"}\n' "$(wt_real)" > "$store"
  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "a non-boolean value must refuse: $out"
  assert_contains "$out" "non-boolean value" "the refusal must name the invalid value"
  pass "a non-boolean trust value fails loudly instead of being silently rewritten"
}

# --- scope: only this spawn's isolated worktree -----------------------------

test_out_of_scope_paths_are_refused() {
  local rec out other
  rec=$(make_case scope)
  read_case "$rec"

  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$PROJ" "$PROJ" 2>&1)
  expect_code 1 $? "a primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the primary-checkout refusal must name the reason"

  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$WT/.git" "$PROJ" 2>&1)
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"

  mkdir -p "$CASE/plain"
  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$CASE/plain" "$PROJ" 2>&1)
  expect_code 1 $? "a plain directory must be refused: $out"
  assert_contains "$out" "not inside a git repository" "the plain-directory refusal must name the reason"

  other="$CASE/other"
  fm_git_worktree "$other" "$CASE/other-wt" other-wt
  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$CASE/other-wt" "$PROJ" 2>&1)
  expect_code 1 $? "a worktree of an unrelated project must be refused: $out"
  assert_contains "$out" "not a worktree of project" "the unrelated-worktree refusal must name the reason"

  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$USER_HOME" "$PROJ" 2>&1)
  expect_code 1 $? "the home directory must be refused: $out"
  assert_contains "$out" "home directory" "the home-directory refusal must name the reason"

  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" / "$PROJ" 2>&1)
  expect_code 1 $? "the filesystem root must be refused: $out"

  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir relative/agent "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative agent root must be refused: $out"
  assert_contains "$out" "relative path" "the relative-agent-root refusal must name the reason"

  assert_absent "$AGENT/trust.json" "a refused registration must write nothing"
  pass "primary checkouts, subdirectories, plain directories, unrelated worktrees, home, /, and relative roots are refused"
}

# --- which agent root the worker will read ----------------------------------

test_agent_root_resolution() {
  local rec out
  rec=$(make_case roots)
  read_case "$rec"

  # 1. PI_CODING_AGENT_DIR when no --agent-dir is given.
  out=$(HOME="$USER_HOME" PI_CODING_AGENT_DIR="$CASE/env-agent" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "a PI_CODING_AGENT_DIR root must be registered: $out"
  assert_trusted "$CASE/env-agent/trust.json" "$(wt_real)" "PI_CODING_AGENT_DIR was not the store root"

  # 2. The user-level ~/.pi/agent default when neither is set.
  out=$(env -u PI_CODING_AGENT_DIR HOME="$USER_HOME" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "the default user-level root must be registered: $out"
  assert_trusted "$USER_HOME/.pi/agent/trust.json" "$(wt_real)" "the default ~/.pi/agent root was not the store root"

  # 3. An explicit --agent-dir wins over the environment, because a pinned
  #    worker account names that root on the launch line itself.
  out=$(HOME="$USER_HOME" PI_CODING_AGENT_DIR="$CASE/env-agent" "$TRUST" --agent-dir "$AGENT" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "an explicit agent root must be registered: $out"
  assert_trusted "$AGENT/trust.json" "$(wt_real)" "--agent-dir did not decide the store root"
  pass "the store root follows the pinned agent dir, then PI_CODING_AGENT_DIR, then ~/.pi/agent"
}

# --- the spawn that calls it ------------------------------------------------

# make_pi_spawn_case <name> <harness> <id>: a spawn world with a fake pi-family
# executable that answers the version probes the way the real CLI does.
make_pi_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode> --approve'
fi
exit 0
SH
  chmod +x "$fakebin/pi"
  cp "$fakebin/pi" "$fakebin/pi-signed"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

test_pi_spawn_registers_the_worktree() {
  local rec harness id out store launch
  for harness in pi pi-signed; do
    id="pi-trust-$harness"
    rec=$(make_pi_spawn_case "spawn-$harness" "$harness" "$id")
    IFS='|' read -r CASE HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
    store="$HOME_DIR/user-home/.pi/agent/trust.json"

    out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
      fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
      --mode no-mistakes --yolo off)
    expect_code 0 $? "$harness ship spawn should succeed: $out"
    assert_trusted "$store" "$(cd -P -- "$WT_DIR" && pwd -P)" \
      "$harness spawn did not register its worktree in the user-level trust store"
    launch=$(cat "$CASE/launch.log")
    assert_not_contains "$launch" "--approve" \
      "$harness crewmate launches must keep the session-only --approve off"
    pass "$harness ship spawn registers its worktree before launch"
  done
}

# A registration failure is a spawn refusal: launching anyway would recreate
# the exact stall this control exists to remove.
test_pi_spawn_refuses_when_registration_fails() {
  local rec id out store
  id=pi-trust-refuse
  rec=$(make_pi_spawn_case spawn-refuse pi "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  store="$HOME_DIR/user-home/.pi/agent/trust.json"
  mkdir -p "$(dirname "$store")"
  printf '[]\n' > "$store"

  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off)
  expect_code 1 $? "a spawn whose trust registration fails must refuse: $out"
  assert_contains "$out" "refusing to launch a pi worker" "the refusal must say it would not launch the worker"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  [ ! -s "$CASE/launch.log" ] || fail "a refused spawn must not launch a worker: $(cat "$CASE/launch.log")"
  pass "a failed registration stops the spawn with a named error"
}

test_other_harnesses_get_no_pi_trust_write() {
  local rec id out store
  id=pi-trust-codex
  rec=$(make_pi_spawn_case spawn-codex codex "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  store="$HOME_DIR/user-home/.pi/agent/trust.json"
  fm_fake_exit0 "$FAKEBIN_DIR" codex >/dev/null

  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "a codex ship spawn should still succeed: $out"
  assert_absent "$store" "a non-Pi harness must not register anything in Pi's trust store"
  pass "a non-Pi harness leaves Pi's trust store untouched"
}

test_fresh_worktree_is_registered
test_symlinked_fixture_registers_the_realpath
test_existing_registration_is_a_noop
test_unrelated_entries_survive_a_new_registration
test_recorded_decline_is_refused
test_write_failure_refuses_loudly
test_malformed_store_refuses_loudly
test_out_of_scope_paths_are_refused
test_agent_root_resolution
test_pi_spawn_registers_the_worktree
test_pi_spawn_refuses_when_registration_fails
test_other_harnesses_get_no_pi_trust_write

echo "# all fm-pi-trust tests passed"
