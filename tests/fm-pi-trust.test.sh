#!/usr/bin/env bash
# Behavior tests for bin/fm-pi-trust.sh and the pi/pi-signed spawn that calls it.
#
# The contract has two halves and both are proven here: the registration writes
# Pi's own trust store for exactly the worktree path a spawn will use (and only
# that path), and every failure mode stops the spawn instead of launching a
# worker that would park on "Trust project folder?" with nobody to press Enter.
# It also proves that an Orca launch-env source's supplied HOME, not the
# spawning process's, selects the store an unpinned worker reads.
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
  assert_contains "$out" "$store" "the refusal must name the store to change"
  [ "$(cat "$store")" = "$before" ] || fail "a refused registration must not rewrite the store"
  pass "a recorded 'Do not trust' decision refuses the spawn instead of being reversed"
}

# Pi resolves trust through the nearest ancestor entry, so the script must too:
# an inherited decision is the operator's decision, not a missing entry.
test_trusted_ancestor_is_already_trusted() {
  local rec out store before
  rec=$(make_case ancestor-true)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  printf '{\n  "%s": true\n}\n' "$CASE" > "$store"
  before=$(cat "$store")

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a worktree under a trusted ancestor must succeed: $out"
  assert_contains "$out" "already trusted:" "an inherited trust must be reported as already trusted"
  [ "$(cat "$store")" = "$before" ] || fail "an inherited trust must not rewrite the store"
  [ "$(trust_entry "$store" "$(wt_real)")" = absent ] \
    || fail "an inherited trust must not add a narrower entry"
  pass "a trusted ancestor counts as already trusted and writes nothing"
}

# A null entry records "undecided", so it must be skipped and the next recorded
# decision above it must win, exactly as Pi's own walk does.
test_undecided_ancestor_is_skipped() {
  local dir proj wt home agent store out
  dir="$TMP_ROOT/ancestor-null"
  proj="$dir/project"
  wt="$dir/pool/wt"
  home="$dir/home"
  agent="$dir/agent"
  store="$agent/trust.json"
  mkdir -p "$home" "$dir/pool" "$agent"
  fm_git_worktree "$proj" "$wt" wt-ancestor-null
  printf '{\n  "%s": true,\n  "%s/pool": null\n}\n' "$dir" "$dir" > "$store"

  out=$(HOME="$home" "$TRUST" --agent-dir "$agent" "$wt" "$proj" 2>&1)
  expect_code 0 $? "a null ancestor entry must be skipped: $out"
  assert_contains "$out" "already trusted:" "a true decision above a null entry must be honoured"
  pass "an undecided ancestor entry is skipped and the nearest recorded decision wins"
}

test_declined_ancestor_is_refused() {
  local rec out store before
  rec=$(make_case ancestor-false)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  printf '{\n  "%s": false\n}\n' "$CASE" > "$store"
  before=$(cat "$store")

  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "an inherited 'Do not trust' must refuse: $out"
  assert_contains "$out" "Do not trust" "the refusal must name the recorded decision it will not reverse"
  assert_contains "$out" "for $CASE," "the refusal must name the ancestor that records the decline"
  assert_contains "$out" "$store" "the refusal must name the store to change"
  [ "$(cat "$store")" = "$before" ] || fail "a refused registration must not rewrite the store"
  [ "$(trust_entry "$store" "$(wt_real)")" = absent ] \
    || fail "a refused registration must not add a narrower entry"
  pass "an inherited 'Do not trust' refuses the spawn instead of being overridden"
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

# A store a dotfile manager or synced folder leaves read-only, or one another
# account owns, is not a reason to refuse a spawn whose outcome writes nothing:
# a recorded decision, an `always` policy and a `never` policy all launch
# against it unchanged.
test_read_only_store_still_allows_no_write_outcomes() {
  local rec out store before
  rec=$(make_case readonly-store)
  read_case "$rec"
  store="$AGENT/trust.json"
  mkdir -p "$AGENT"
  settings_write "$AGENT" '{"defaultProjectTrust": "ask"}'
  printf '{\n  "%s": true\n}\n' "$(wt_real)" > "$store"
  before=$(cat "$store")
  chmod 444 "$store"

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a read-only store must still count a recorded trust: $out"
  assert_contains "$out" "already trusted:" "a read-only store must still report the saved decision"
  [ "$(cat "$store")" = "$before" ] || fail "a recorded trust must leave a read-only store untouched"

  chmod 600 "$store"
  printf '{}\n' > "$store"
  before=$(cat "$store")
  chmod 444 "$store"
  settings_write "$AGENT" '{"defaultProjectTrust": "always"}'
  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a read-only store must not refuse an 'always' policy: $out"
  assert_contains "$out" 'defaultProjectTrust to "always"' \
    "an 'always' policy must still be reported against a read-only store"
  [ "$(cat "$store")" = "$before" ] || fail "an 'always' policy must not write into a read-only store"

  settings_write "$AGENT" '{"defaultProjectTrust": "never"}'
  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a read-only store must not refuse a 'never' policy: $out"
  assert_contains "$out" 'defaultProjectTrust to "never"' \
    "a 'never' policy must still be reported against a read-only store"
  [ "$(cat "$store")" = "$before" ] || fail "a 'never' policy must not write into a read-only store"
  chmod 600 "$store"
  pass "a read-only store still allows the three outcomes that write nothing"
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

  mkdir -p "$WT/sub"

  out=$(HOME="$USER_HOME" "$TRUST" --agent-dir "$AGENT" "$WT/sub" "$PROJ" 2>&1)
  expect_code 1 $? "a subdirectory of the worktree must be refused: $out"
  assert_contains "$out" "not a worktree root" "the subdirectory refusal must name the worktree-root check"

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

  # 1. The invoking process's PI_CODING_AGENT_DIR is not evidence: panes are
  #    created by a daemon that does not inherit it, and an unpinned launch line
  #    unsets it, so that worker reads Pi's default ~/.pi/agent.
  out=$(HOME="$USER_HOME" PI_CODING_AGENT_DIR="$CASE/env-agent" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "a registration under an ambient PI_CODING_AGENT_DIR must succeed: $out"
  assert_trusted "$USER_HOME/.pi/agent/trust.json" "$(wt_real)" \
    "an unpinned registration must use the default ~/.pi/agent root"
  assert_absent "$CASE/env-agent/trust.json" \
    "the invoking process's PI_CODING_AGENT_DIR must not receive the entry"

  # 2. An explicit --agent-dir names the root a pinned worker account puts on
  #    the launch line, and wins over the environment.
  out=$(HOME="$USER_HOME" PI_CODING_AGENT_DIR="$CASE/env-agent" "$TRUST" --agent-dir "$AGENT" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "an explicit agent root must be registered: $out"
  assert_trusted "$AGENT/trust.json" "$(wt_real)" "--agent-dir did not decide the store root"

  # 3. Neither names a root, so the user-level ~/.pi/agent default applies.
  out=$(env -u PI_CODING_AGENT_DIR HOME="$USER_HOME" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "the default user-level root must be registered: $out"
  assert_trusted "$USER_HOME/.pi/agent/trust.json" "$(wt_real)" "the default ~/.pi/agent root was not the store root"

  # 4. A spawn process without HOME does not block the root its launch already
  #    names; only the default root would need that home.
  out=$(env -u HOME "$TRUST" --agent-dir "$AGENT" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "an explicit agent root must register with HOME unset: $out"
  assert_trusted "$AGENT/trust.json" "$(wt_real)" "--agent-dir did not decide the store root with HOME unset"

  # 5. An empty HOME gives Pi a root under the worker's own directory, which no
  #    default here can name, so it is refused unless --agent-dir names one.
  out=$(env HOME= "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "an empty HOME with no explicit root must refuse: $out"
  assert_contains "$out" "HOME is set but empty" "the empty-HOME refusal must name the reason"
  out=$(env HOME= "$TRUST" --agent-dir "$AGENT" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "an explicit agent root must register with an empty HOME: $out"
  assert_trusted "$AGENT/trust.json" "$(wt_real)" "--agent-dir did not decide the store root with an empty HOME"
  pass "the store root follows the pinned agent dir and else ~/.pi/agent, never the invoking environment"
}

# --- the operator's own Pi trust policy -------------------------------------

# settings_write <agent-dir> <json>: the selected root's Pi settings file, which
# is where Pi reads defaultProjectTrust from.
settings_write() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/settings.json"
}

# Pi consults a saved decision first and defaultProjectTrust only when none
# exists. An operator who configured Pi never to auto-trust project folders must
# therefore get no entry and a report of the degraded launch Pi itself applies,
# without any promise of a dialog Pi will not render.
test_default_trust_never_writes_nothing() {
  local rec out store settings
  rec=$(make_case trust-never)
  read_case "$rec"
  store="$AGENT/trust.json"
  settings="$AGENT/settings.json"
  settings_write "$AGENT" '{"defaultProjectTrust": "never"}'

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a 'never' policy must not refuse the spawn: $out"
  assert_contains "$out" 'defaultProjectTrust to "never"' \
    "the report must name the setting that suppressed the write"
  assert_contains "$out" "$settings" "the report must name the settings file it read"
  assert_contains "$out" "renders no dialog" \
    "the report must say Pi renders no dialog under 'never'"
  assert_contains "$out" "project settings" \
    "the report must explain what the 'never' worker launches without"
  assert_not_contains "$out" "human confirmation" \
    "a 'never' policy must not promise a confirmation Pi never renders"
  assert_not_contains "$out" "will need" \
    "a 'never' policy must not promise a confirmation Pi never renders"
  assert_not_contains "$out" "needs a human" \
    "a 'never' policy must not promise a confirmation Pi never renders"
  assert_not_contains "$out" "trusted:" "a 'never' policy must not report the worktree as trusted"
  assert_absent "$store" "a 'never' policy must write no trust entry"
  pass "defaultProjectTrust never is reported and never overridden"
}

test_default_trust_always_writes_nothing() {
  local rec out store
  rec=$(make_case trust-always)
  read_case "$rec"
  store="$AGENT/trust.json"
  settings_write "$AGENT" '{"defaultProjectTrust": "always"}'

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "an 'always' policy must not refuse the spawn: $out"
  assert_contains "$out" 'defaultProjectTrust to "always"' \
    "the report must name the policy that already trusts the directory"
  assert_contains "$out" "nothing was written" "an 'always' policy must not claim this script wrote the entry"
  assert_not_contains "$out" "trusted:" "an 'always' policy must not claim this script wrote the entry"
  assert_absent "$store" "an 'always' policy needs no trust entry"
  pass "defaultProjectTrust always is reported without a redundant write"
}

test_default_trust_ask_writes_the_entry() {
  local rec out store
  rec=$(make_case trust-ask)
  read_case "$rec"
  store="$AGENT/trust.json"
  settings_write "$AGENT" '{"theme": "dark", "defaultProjectTrust": "ask"}'

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "an 'ask' policy must register the worktree: $out"
  assert_contains "$out" "trusted:" "an 'ask' policy must report the registration"
  assert_trusted_only "$store" "$(wt_real)" "an 'ask' policy did not record the worktree"
  pass "defaultProjectTrust ask registers the worktree, replacing the interactive confirmation"
}

# A saved decision outranks defaultProjectTrust in Pi, so it must here too: the
# policy is only consulted when the nearest entry is undecided.
test_saved_decision_outranks_the_policy() {
  local rec out store before
  rec=$(make_case trust-saved-wins)
  read_case "$rec"
  store="$AGENT/trust.json"
  settings_write "$AGENT" '{"defaultProjectTrust": "never"}'
  mkdir -p "$AGENT"
  printf '{\n  "%s": true\n}\n' "$(wt_real)" > "$store"
  before=$(cat "$store")

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a saved trust must win over a 'never' policy: $out"
  assert_contains "$out" "already trusted:" "a saved trust must be reported as already trusted"
  [ "$(cat "$store")" = "$before" ] || fail "a saved trust must not be rewritten"
  pass "a saved trust decision outranks defaultProjectTrust"
}

# Under a pin the policy is the PINNED root's, never the default root's.
test_policy_follows_the_pinned_root() {
  local rec out pinned_store default_store pinned_settings
  rec=$(make_case trust-pinned-policy)
  read_case "$rec"
  pinned_store="$AGENT/trust.json"
  default_store="$USER_HOME/.pi/agent/trust.json"
  pinned_settings="$AGENT/settings.json"
  settings_write "$AGENT" '{"defaultProjectTrust": "never"}'
  settings_write "$USER_HOME/.pi/agent" '{"defaultProjectTrust": "ask"}'

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a pinned 'never' policy must not refuse the spawn: $out"
  assert_contains "$out" "$pinned_settings" "the report must name the pinned root's settings file"
  assert_absent "$pinned_store" "a pinned 'never' policy must write no trust entry"
  assert_absent "$default_store" "the registration must not fall back to the default store"
  pass "a pinned root's defaultProjectTrust decides its own store, not the default root's"

  settings_write "$AGENT" '{"defaultProjectTrust": "ask"}'
  settings_write "$USER_HOME/.pi/agent" '{"defaultProjectTrust": "never"}'

  out=$(run_trust "$WT" "$PROJ")
  expect_code 0 $? "a pinned 'ask' policy must register: $out"
  assert_trusted_only "$pinned_store" "$(wt_real)" "a pinned 'ask' policy did not record the worktree"
  assert_absent "$default_store" "the default root's 'never' policy must not speak for the pinned root"
  pass "the pinned root's own 'ask' policy registers the worktree"
}

# Fail loudly instead of reading an unparseable policy as anything at all.
test_unreadable_settings_refuses_loudly() {
  local rec out store settings
  rec=$(make_case trust-settings-malformed)
  read_case "$rec"
  store="$AGENT/trust.json"
  settings="$AGENT/settings.json"
  settings_write "$AGENT" '{"defaultProjectTrust": '

  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "a malformed settings file must refuse: $out"
  assert_contains "$out" "$settings" "the refusal must name the settings file it could not read"
  assert_absent "$store" "a refused registration must write nothing"

  settings_write "$AGENT" '[]'
  out=$(run_trust "$WT" "$PROJ")
  expect_code 1 $? "a non-object settings file must refuse: $out"
  assert_contains "$out" "$settings" "the refusal must name the settings file it could not read"
  assert_absent "$store" "a refused registration must write nothing"
  pass "an unreadable or malformed Pi settings file refuses loudly, never as 'never'"
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

# make_pi_orca_spawn_case <name> <id>: a pi spawn on backend=orca whose
# config/launch-env-tmux-session supplies HOME from a different home, the shape
# an Orca home allowlist uses. Echoes
# "<case>|<home>|<proj>|<worker-home>|<fakebin>".
make_pi_orca_spawn_case() {
  local name=$1 id=$2 case_dir home proj worker_home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  worker_home="$case_dir/worker-home"
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
  cat > "$fakebin/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show") exit 1 ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal send")
    prev=
    for a in "$@"; do
      if [ "$prev" = --text ]; then
        case "$a" in
          *"'"*/launch.*)
            f=${a#*"'"}; f=${f%%"'"*}
            cp "$f" "$f.copy" && rm -f "$f"
            ;;
        esac
      fi
      prev=$a
    done
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/orca"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *show-environment*)
    name=
    for a in "$@"; do name=$a; done
    case "$name" in
      HOME)
        if [ "${FM_TEST_TMUX_HOME_UNSET:-0}" = 1 ]; then
          printf -- '-HOME\n'
        else
          printf 'HOME=%s\n' "${FM_TEST_TMUX_HOME-}"
        fi
        ;;
      *) printf '%s=stub\n' "$name" ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_spawn_home "$home" pi
  fm_git_init_commit "$proj"
  mkdir -p "$worker_home"
  printf 'HOME\n' > "$home/config/launch-env-allowlist"
  printf 'scoped-source\n' > "$home/config/launch-env-tmux-session"
  fm_test_spawn_brief "$home" "$id"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$worker_home" "$fakebin"
}

# An Orca launch-env source replaces HOME inside the cleared launch environment.
# An unpinned pi worker reads Pi's default <home>/.pi/agent under that value, so
# the registration must land there, not in the spawning process's home.
test_pi_spawn_registers_the_launch_env_home_store() {
  local rec id out store spawn_store wt_recorded staged launch
  id=pi-trust-launch-env-home
  rec=$(make_pi_orca_spawn_case spawn-launch-env "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WORKER_HOME FAKEBIN_DIR <<EOF
$rec
EOF
  store="$WORKER_HOME/.pi/agent/trust.json"
  spawn_store="$HOME_DIR/user-home/.pi/agent/trust.json"

  out=$(FM_TEST_ORCA_DIR="$CASE" FM_TEST_TMUX_HOME="$WORKER_HOME" \
    fm_test_run_spawn "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --backend orca)
  expect_code 0 $? "an Orca launch-env HOME spawn should succeed: $out"
  wt_recorded=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
  [ -n "$wt_recorded" ] || fail "the spawn did not record the worktree Orca created"
  assert_trusted "$store" "$(cd -P -- "$wt_recorded" && pwd -P)" \
    "the spawn registered the spawning process's home, not the HOME its launch line carries"
  assert_absent "$spawn_store" \
    "the unpinned worker does not read the spawning process's store"
  launch=
  for staged in /tmp/fm-"$id"+*/launch.*.sh.copy; do
    [ -e "$staged" ] || continue
    if grep -Fq "HOME='$WORKER_HOME'" "$staged"; then
      launch=$staged
      break
    fi
  done
  [ -n "$launch" ] \
    || fail "the fake Orca pane did not receive a launch line carrying HOME='$WORKER_HOME'"
  pass "an Orca launch-env HOME registers the store its unpinned pi worker reads"
}

# The same case's refusal: when that effective store cannot be written, the
# spawn stops instead of launching a worker that would park on the dialog.
test_pi_spawn_refuses_an_unwritable_launch_env_home_store() {
  local rec id out store
  id=pi-trust-launch-env-refuse
  rec=$(make_pi_orca_spawn_case spawn-launch-env-refuse "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WORKER_HOME FAKEBIN_DIR <<EOF
$rec
EOF
  store="$WORKER_HOME/.pi/agent/trust.json"
  mkdir -p "$store"

  out=$(FM_TEST_ORCA_DIR="$CASE" FM_TEST_TMUX_HOME="$WORKER_HOME" \
    fm_test_run_spawn "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --backend orca)
  expect_code 1 $? "a spawn whose effective trust store cannot be written must refuse: $out"
  assert_contains "$out" "refusing to launch a pi worker" \
    "the refusal must say it would not launch the worker"
  assert_contains "$out" "$store" "the refusal must name the effective store"
  pass "an unwritable launch-env HOME store refuses the spawn"
}

# A source that owns HOME but leaves it unset (tmux set-environment -r) gives
# that launch a Pi agent root derived from the account database, which this spawn
# cannot select as the launch line's HOME. Registering anywhere else would leave
# the worker on the dialog this control removes, so the spawn refuses.
test_pi_spawn_refuses_a_launch_env_without_home() {
  local rec id out store
  id=pi-trust-launch-env-no-home
  rec=$(make_pi_orca_spawn_case spawn-launch-env-no-home "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WORKER_HOME FAKEBIN_DIR <<EOF
$rec
EOF
  store="$WORKER_HOME/.pi/agent/trust.json"

  out=$(FM_TEST_ORCA_DIR="$CASE" FM_TEST_TMUX_HOME_UNSET=1 FM_TEST_TMUX_HOME="$WORKER_HOME" \
    fm_test_run_spawn "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --backend orca)
  expect_code 1 $? "a launch whose source leaves HOME unset must refuse: $out"
  assert_contains "$out" "could not resolve the HOME" \
    "the unset refusal must name what it could not resolve"
  assert_contains "$out" "refusing to launch a pi worker" \
    "the unset refusal must say it would not launch the worker"
  assert_absent "$HOME_DIR/user-home/.pi/agent/trust.json" \
    "a launch without HOME must not register in the spawning process's store"
  assert_absent "$store" "a launch without HOME must not register in the supplied home's store"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  pass "an unpinned launch whose source leaves HOME unset refuses instead of registering elsewhere"
}

# An empty HOME value makes Pi resolve its agent root relative to the worker's
# own directory, which is no store this spawn can name either.
test_pi_spawn_refuses_an_empty_launch_env_home() {
  local rec id out store
  id=pi-trust-launch-env-empty-home
  rec=$(make_pi_orca_spawn_case spawn-launch-env-empty-home "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WORKER_HOME FAKEBIN_DIR <<EOF
$rec
EOF
  store="$WORKER_HOME/.pi/agent/trust.json"

  out=$(FM_TEST_ORCA_DIR="$CASE" FM_TEST_TMUX_HOME='' \
    fm_test_run_spawn "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off --backend orca)
  expect_code 1 $? "a launch whose source sets HOME empty must refuse: $out"
  assert_contains "$out" "could not resolve the HOME" \
    "the empty refusal must name what it could not resolve"
  assert_contains "$out" "refusing to launch a pi worker" \
    "the empty refusal must say it would not launch the worker"
  assert_absent "$HOME_DIR/user-home/.pi/agent/trust.json" \
    "a launch with an empty HOME must not register in the spawning process's store"
  assert_absent "$store" "a launch with an empty HOME must not register in the supplied home's store"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must not publish a task record"
  pass "an unpinned launch whose source sets HOME empty refuses instead of registering elsewhere"
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
    assert_contains "$launch" "-u PI_CODING_AGENT_DIR" \
      "an unpinned $harness launch must unset the pane's ambient agent root"
    pass "$harness ship spawn registers its worktree before launch"
  done
}

# The spawning process's PI_CODING_AGENT_DIR is not the store an unpinned
# launch reads: the launch line unsets the variable, so no pane daemon
# environment can redirect it, and the default store is the only possibility.
# Registering the spawning root instead would leave the dialog exactly where it
# was.
test_pi_spawn_ignores_the_spawning_process_agent_root() {
  local rec id out store launch
  id=pi-trust-divergent-root
  rec=$(make_pi_spawn_case spawn-divergent pi "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  store="$HOME_DIR/user-home/.pi/agent/trust.json"

  out=$(PI_CODING_AGENT_DIR="$CASE/work-root" FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "an unpinned pi spawn must succeed with an ambient agent root: $out"
  assert_trusted "$store" "$(cd -P -- "$WT_DIR" && pwd -P)" \
    "the unpinned spawn did not register in Pi's default store"
  assert_absent "$CASE/work-root/trust.json" \
    "the spawning process's PI_CODING_AGENT_DIR must not receive the entry"
  launch=$(cat "$CASE/launch.log")
  assert_not_contains "$launch" "PI_CODING_AGENT_DIR=" \
    "an unpinned launch line must still carry no agent root"
  assert_contains "$launch" "-u PI_CODING_AGENT_DIR" \
    "an unpinned launch line must unset the pane's ambient agent root"
  pass "an unpinned pi spawn registers Pi's default store even when the spawn environment names another root"
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

# A 'never' policy is the operator's own decision, so the spawn still launches:
# it just carries no pre-registered entry and says so.
test_pi_spawn_respects_the_never_policy() {
  local rec id out store settings
  id=pi-trust-never
  rec=$(make_pi_spawn_case spawn-never pi "$id")
  IFS='|' read -r CASE HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$rec
EOF
  store="$HOME_DIR/user-home/.pi/agent/trust.json"
  settings="$HOME_DIR/user-home/.pi/agent/settings.json"
  mkdir -p "$(dirname "$store")"
  printf '{\n  "defaultProjectTrust": "never"\n}\n' > "$settings"

  out=$(FM_FAKE_LAUNCH_LOG="$CASE/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    --mode no-mistakes --yolo off)
  expect_code 0 $? "a 'never' policy must not refuse the spawn: $out"
  assert_contains "$out" "$settings" "the spawn must name the settings file that suppressed the write"
  assert_contains "$out" "renders no dialog" "the spawn must explain that Pi renders no dialog under 'never'"
  assert_not_contains "$out" "human confirmation" \
    "the spawn must not promise a confirmation Pi never renders"
  assert_absent "$store" "a 'never' policy must leave the trust store unwritten"
  [ -s "$CASE/launch.log" ] || fail "a 'never' policy must still launch the worker"
  pass "a pi spawn under defaultProjectTrust never launches without pre-registering trust"
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
test_trusted_ancestor_is_already_trusted
test_undecided_ancestor_is_skipped
test_declined_ancestor_is_refused
test_write_failure_refuses_loudly
test_read_only_store_still_allows_no_write_outcomes
test_malformed_store_refuses_loudly
test_out_of_scope_paths_are_refused
test_agent_root_resolution
test_default_trust_never_writes_nothing
test_default_trust_always_writes_nothing
test_default_trust_ask_writes_the_entry
test_saved_decision_outranks_the_policy
test_policy_follows_the_pinned_root
test_unreadable_settings_refuses_loudly
test_pi_spawn_registers_the_worktree
test_pi_spawn_registers_the_launch_env_home_store
test_pi_spawn_refuses_an_unwritable_launch_env_home_store
test_pi_spawn_refuses_a_launch_env_without_home
test_pi_spawn_refuses_an_empty_launch_env_home
test_pi_spawn_ignores_the_spawning_process_agent_root
test_pi_spawn_refuses_when_registration_fails
test_pi_spawn_respects_the_never_policy
test_other_harnesses_get_no_pi_trust_write

echo "# all fm-pi-trust tests passed"
