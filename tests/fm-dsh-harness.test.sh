#!/usr/bin/env bash
# Behavior tests for the DeepSeek Harness primary adapter.
#
# The facts pinned here are the ones a DSH release could silently change and the
# ones a wrong guess would make dangerous:
#   1. A live DSH host is a node process, so `ps` reports comm=node and the
#      launcher name is visible ONLY in argv. Detection is therefore an anchored
#      match on the dsh launcher path, never a bare *dsh* glob an unrelated node
#      command could satisfy.
#   2. DSH publishes no harness-identity marker, so FM_DSH_HARNESS=dsh is a
#      Firstmate-OWNED precedence override, honored only when a genuine dsh
#      process is in the ancestry (the FM_OMP_HARNESS contract).
#   3. Because the ancestry verdict is `args` strength, an inherited CLAUDECODE
#      outranks it; the launch marker is what keeps a DSH session identified as
#      dsh. Pin both halves so neither can rot silently.
#   4. DSH reports stop_hook_active=false on every Stop and has no async re-wake
#      hook, so the guard owns a session-scoped block budget and emits one
#      attended fail-open instead of re-blocking without limit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry these cases set up. Drop the ambient markers so the asserted verdict
# does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_DSH_HARNESS

HARNESS="$ROOT/bin/fm-harness.sh"
GUARD="$ROOT/bin/fm-turnend-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-dsh-harness)

# A fake `ps` answering per-pid comm/args/ppid, the fm-agy-harness shape. The
# walk starts at the script's own pid, so the first answer must be the node
# host and the second must end the walk.
make_ps_fakebin() {  # <dir> <comm> <args>
  local dir=$1 comm=$2 args=$3 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"args="*) printf '%s\n' '$args'; exit 0 ;;
  *"comm="*) printf '%s\n' '$comm'; exit 0 ;;
  *"ppid="*) printf '1\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# A fake `ps` that answers nothing, so the ancestry walk finds no harness. The
# suite itself frequently runs inside a real DSH session, whose genuine ancestry
# would otherwise satisfy every dsh query - the same blinding the agy suite
# needs for the same reason.
make_ps_blind() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/ps"
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_dsh_ancestry_detects_the_launcher_path() {
  local fakebin out
  fakebin=$(make_ps_fakebin "$TMP_ROOT/anc-node" node \
    'node /Users/x/.npm/_npx/abc/node_modules/.bin/dsh web')
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = dsh ] \
    || fail "a DSH host must be detected from its launcher path in argv, got '$out'"
  pass "fm-harness.sh: ancestry detects the dsh launcher path"
}

test_dsh_ancestry_detects_the_installed_bin_js() {
  local fakebin out
  fakebin=$(make_ps_fakebin "$TMP_ROOT/anc-binjs" node \
    'node /g/node_modules/@deepseek-ai/dsh/lib/bin.js web')
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = dsh ] \
    || fail "a DSH host must be detected from its installed bin.js path, got '$out'"
  pass "fm-harness.sh: ancestry detects the installed dsh bin.js"
}

test_dsh_ancestry_rejects_unrelated_node_commands() {
  local fakebin out
  fakebin=$(make_ps_fakebin "$TMP_ROOT/anc-neg" node 'node /x/other-tool.js --dsh-flavoured')
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != dsh ] \
    || fail "an unrelated node command mentioning dsh must not be detected, got '$out'"
  fakebin=$(make_ps_fakebin "$TMP_ROOT/anc-neg2" node 'node /x/dshish.js run')
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != dsh ] \
    || fail "a bare dsh fragment in a path must not be detected, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated dsh mentions"
}

test_dsh_marker_requires_real_ancestry() {
  local fakebin out
  # The marker is a precedence override, never evidence: with no dsh ancestor it
  # must not claim the identity on its own.
  fakebin=$(make_ps_blind "$TMP_ROOT/anc-blind")
  out=$(FM_DSH_HARNESS=dsh PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != dsh ] \
    || fail "FM_DSH_HARNESS without a dsh ancestor must not claim the identity, got '$out'"
  pass "fm-harness.sh: the DSH launch marker is not evidence on its own"
}

test_dsh_marker_outranks_an_inherited_claudecode() {
  local fakebin out
  # A DSH host launched from a Claude pane retains CLAUDECODE, and because the
  # dsh verdict is args strength that marker would otherwise rename the session.
  # The Firstmate-owned launch marker is what keeps it identified as dsh.
  fakebin=$(make_ps_fakebin "$TMP_ROOT/anc-claude" node 'node /x/.bin/dsh web')
  out=$(FM_DSH_HARNESS=dsh CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = dsh ] \
    || fail "the DSH launch marker must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: the DSH launch marker outranks an inherited CLAUDECODE"
}

# --- the bounded Stop guard --------------------------------------------------

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/,
# state/ - everything the guard's scoping check requires to treat it as primary.
# The whole bin/ tree is copied so the guard's own library sourcing resolves
# inside the fixture rather than back into the real checkout.
make_guard_home() {  # <name> -> dir with AGENTS.md, bin/, state/
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  printf '%s\n' "$dir"
}

run_dsh_stop() {  # <home> <session-id> -> exit code, stderr in $STOP_ERR
  local home=$1 sid=$2
  STOP_ERR="$home/stderr.txt"
  ( cd "$home" && printf '{"session_id":"%s"}' "$sid" \
    | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$home/bin/fm-turnend-guard.sh" --dsh 2>"$STOP_ERR" )
}

test_dsh_guard_blocks_under_budget_then_fails_open() {
  local home rc
  home=$(make_guard_home guard-budget)
  printf 'task\n' > "$home/state/t1.meta"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "a blind turn end under budget must block"
  assert_contains "$(cat "$home/stderr.txt")" "TURN WOULD END BLIND" \
    "the blocked stop did not carry its banner"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "the second stop must still block under budget"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "the third stop must still block under budget"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 0 "$rc" "an exhausted budget must fail open instead of re-blocking"
  pass "fm-turnend-guard --dsh: blocks under budget, then fails open"
}

test_dsh_guard_budget_is_session_scoped() {
  local home rc
  home=$(make_guard_home guard-session)
  printf 'task\n' > "$home/state/t1.meta"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "the first session's stop must block"
  rc=0; run_dsh_stop "$home" s2 || rc=$?
  expect_code 2 "$rc" "a new session must start its own budget and block"
  assert_grep 'session=s2' "$home/state/.turnend-dsh-blocks" \
    "the budget file did not adopt the new session id"
  pass "fm-turnend-guard --dsh: the block budget is session-scoped"
}

test_dsh_guard_clears_the_budget_when_supervision_is_not_needed() {
  local home rc
  home=$(make_guard_home guard-cleared)
  printf 'task\n' > "$home/state/t1.meta"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "a stop with work in flight must block"
  rm -f "$home/state/t1.meta"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 0 "$rc" "a stop needing no supervision must be allowed"
  [ -e "$home/state/.turnend-dsh-blocks" ] \
    && fail "the budget was not cleared once supervision was no longer needed" || true
  pass "fm-turnend-guard --dsh: the budget clears when supervision is not needed"
}

test_dsh_guard_fails_open_on_unusable_input() {
  local home rc
  home=$(make_guard_home guard-input)
  printf 'task\n' > "$home/state/t1.meta"
  rc=0
  ( cd "$home" && : | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" "$home/bin/fm-turnend-guard.sh" --dsh 2>/dev/null ) || rc=$?
  expect_code 0 "$rc" "empty stdin must fail open"
  rc=0
  ( cd "$home" && printf 'not json' | FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" "$home/bin/fm-turnend-guard.sh" --dsh 2>/dev/null ) || rc=$?
  expect_code 0 "$rc" "an unreadable payload must fail open"
  pass "fm-turnend-guard --dsh: unusable input fails open"
}

test_dsh_stop_wrapper_fails_open_without_a_root() {
  local rc
  rc=0
  printf '{"session_id":"s1"}' | env -u FM_ROOT_OVERRIDE -u CLAUDE_PROJECT_DIR \
    "$ROOT/bin/fm-turnend-guard-dsh.sh" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "an unresolvable root must fail open"
  pass "fm-turnend-guard-dsh.sh: an unresolvable root fails open"
}

test_dsh_ancestry_detects_the_launcher_path
test_dsh_ancestry_detects_the_installed_bin_js
test_dsh_ancestry_rejects_unrelated_node_commands
test_dsh_marker_requires_real_ancestry
test_dsh_marker_outranks_an_inherited_claudecode
test_dsh_guard_blocks_under_budget_then_fails_open
test_dsh_guard_budget_is_session_scoped
test_dsh_guard_clears_the_budget_when_supervision_is_not_needed
test_dsh_guard_fails_open_on_unusable_input
test_dsh_stop_wrapper_fails_open_without_a_root
