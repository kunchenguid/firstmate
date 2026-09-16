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

test_dsh_session_lock_matcher_detects_launcher_paths() {
  # state/.lock is acquired through this matcher, and a host that cannot be
  # named there leaves every DSH session permanently read-only.
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_harness_process_matches node "node /Users/x/.npm/_npx/abc/node_modules/.bin/dsh web" \
    || fail "the npx .bin/dsh launcher must be a harness process"
  fm_harness_process_matches node "node /g/node_modules/@deepseek-ai/dsh/lib/bin.js web" \
    || fail "the installed dsh bin.js must be a harness process"
  fm_harness_process_matches node "/Users/x/apps/cli/src/bin.ts" \
    || fail "the source-launch bin.ts must be a harness process"
  pass "fm-session-lock-lib: dsh launcher paths are harness processes"
}

test_dsh_session_lock_matcher_rejects_firstmate_paths() {
  # A bare `dsh` alternative would claim firstmate's own scripts and reopen the
  # false positives the anchored pi/omp arms exist to prevent.
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_harness_process_matches node "node /Users/x/bin/fm-dsh-sessionstart.sh" \
    && fail "firstmate's own fm-dsh-*.sh path must not claim the dsh identity" || true
  fm_harness_process_matches node "node /Users/x/dshish.js" \
    && fail "an unrelated dshish path must not claim the dsh identity" || true
  fm_harness_process_matches claude claude || fail "claude must still be a harness process"
  fm_harness_process_matches omp omp || fail "omp must still be a harness process"
  pass "fm-session-lock-lib: dsh matching adds no false positives"
}

# A stub firstmate home whose session-start prints whatever the case wants.
make_digest_home() {  # <name> <stdout-text>
  local name=$1 text=$2 dir
  dir="$TMP_ROOT/digest-$name"
  mkdir -p "$dir/bin" "$dir/state"
  cat > "$dir/bin/fm-session-start.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' '$text'
exit 0
SH
  chmod +x "$dir/bin/fm-session-start.sh"
  printf '%s\n' "$dir"
}

run_digest() {  # <home> <session-id> -> stdout in $DIGEST_OUT
  local home=$1 sid=$2
  DIGEST_OUT=$(printf '{"session_id":"%s"}' "$sid" \
    | env -u CLAUDE_PROJECT_DIR FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      "$ROOT/bin/fm-dsh-sessionstart.sh" 2>/dev/null)
}

test_dsh_guard_healthy_reset_clears_the_alarm_latch() {
  local home rc
  home=$(make_guard_home guard-latch)
  printf 'task\n' > "$home/state/t1.meta"
  printf 'session=s1\ncount=99\n' > "$home/state/.turnend-dsh-blocks"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "an exhausted budget must alarm"
  [ -f "$home/state/.dsh-turnend-fail-open" ] || fail "the alarm was not latched"
  rm -f "$home/state/t1.meta"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 0 "$rc" "a stop needing no supervision is allowed"
  [ -e "$home/state/.dsh-turnend-fail-open" ] \
    && fail "a recovered home kept its alarm latch and could never alarm again" || true
  pass "fm-turnend-guard --dsh: recovery clears the alarm latch with the budget"
}

test_dsh_digest_delivers_session_start_stdout_whole() {
  local home
  # The digest IS fm-session-start.sh's stdout: a refused-lock banner, the
  # read-once contract and the operating block all ride it. Rendering only the
  # operating block would hand the agent instructions without the diagnosis.
  home=$(make_digest_home whole 'READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED')
  run_digest "$home" s1
  assert_contains "$DIGEST_OUT" "READ-ONLY SESSION" \
    "the digest did not carry the session-start banner"
  assert_contains "$DIGEST_OUT" "additionalContext" \
    "the digest was not emitted as UserPromptSubmit additionalContext"
  assert_contains "$DIGEST_OUT" "UserPromptSubmit" \
    "the emitted payload named the wrong hook event"
  [ -f "$home/state/.dsh-sessionstart-delivered" ] \
    || fail "a delivered digest did not record its once-per-session gate"
  pass "fm-dsh-sessionstart.sh: the whole session-start stdout is delivered"
}

test_dsh_digest_surfaces_a_durable_alarm() {
  local home
  # A session that died before the agent relayed the guard's alarm must still
  # report it: the latch is durable and the next digest carries it.
  home=$(make_digest_home alarm 'DIGEST-BODY')
  printf 'blocked 1789557000\n' > "$home/state/.dsh-turnend-fail-open"
  run_digest "$home" s1
  assert_contains "$DIGEST_OUT" "FIRSTMATE SUPERVISION ALARM" \
    "a durable alarm was not surfaced in the next session-start digest"
  assert_contains "$DIGEST_OUT" "DIGEST-BODY" \
    "the alarm replaced the digest instead of preceding it"
  [ -f "$home/state/.dsh-turnend-fail-open" ] \
    || fail "the adapter cleared a latch the guard's healthy-reset owns"
  pass "fm-dsh-sessionstart.sh: a durable alarm is surfaced, not lost"
}

test_dsh_digest_gate_is_per_session() {
  local home
  home=$(make_digest_home gate 'DIGEST-BODY')
  run_digest "$home" s1
  assert_contains "$DIGEST_OUT" "DIGEST-BODY" "the first prompt must receive the digest"
  run_digest "$home" s1
  [ -z "$DIGEST_OUT" ] || fail "a second prompt in the same session must not re-deliver the digest"
  run_digest "$home" s2
  assert_contains "$DIGEST_OUT" "DIGEST-BODY" "a new session must receive its own digest"
  pass "fm-dsh-sessionstart.sh: the gate is per session and re-arms for a new one"
}

test_dsh_digest_retries_when_nothing_was_produced() {
  local home
  # fm-session-start.sh exits 0 on every path including a refused lock, so an
  # empty digest is the only signal that nothing was produced. Recording the
  # gate before the run would swallow the failure for the whole session.
  home=$(make_digest_home empty '')
  run_digest "$home" s1
  [ -z "$DIGEST_OUT" ] || fail "an empty digest must emit nothing"
  [ -e "$home/state/.dsh-sessionstart-delivered" ] \
    && fail "an empty digest must not record the gate; the next prompt must retry" || true
  pass "fm-dsh-sessionstart.sh: an empty digest leaves the gate unset and retries"
}

test_dsh_guard_alarms_when_the_budget_lock_is_unavailable() {
  local home rc
  # An unacquirable budget lock is not proof that budget remains. Falling
  # through to block_stop made the loop unbounded exactly when the guard could
  # prove the least; silently allowing lost the alarm instead.
  home=$(make_guard_home guard-lockheld)
  printf 'task\n' > "$home/state/t1.meta"
  mkdir -p "$home/state/.turnend-dsh-blocks.lock"
  printf '%s\n' "$$" > "$home/state/.turnend-dsh-blocks.lock/pid"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "an unprovable budget must raise the alarm, never re-block silently"
  assert_contains "$(cat "$home/stderr.txt")" "SUPERVISION IS GENUINELY DOWN" \
    "the unprovable-budget alarm did not name the condition"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 0 "$rc" "and then allow, so the loop stays bounded"
  pass "fm-turnend-guard --dsh: an unavailable budget lock alarms once, then allows"
}

test_dsh_guard_budget_is_an_episode_not_a_session() {
  local home rc
  home=$(make_guard_home guard-episode)
  printf 'task\n' > "$home/state/t1.meta"
  # An exhausted ledger whose episode is older than the window starts over, so
  # one lapse cannot leave a long-lived session permanently alarming.
  printf 'session=s1\ncount=99\n' > "$home/state/.turnend-dsh-blocks"
  touch -t 202001010000 "$home/state/.turnend-dsh-blocks"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "an expired episode must start a fresh budget and block"
  assert_grep 'count=1' "$home/state/.turnend-dsh-blocks" \
    "the expired episode did not restart its count"
  # The same ledger inside the window keeps its count: one alarm, then allow.
  printf 'session=s1\ncount=99\n' > "$home/state/.turnend-dsh-blocks"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "an exhausted ledger inside the window must alarm once"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 0 "$rc" "and then allow"
  pass "fm-turnend-guard --dsh: the budget is an episode window, not a session lifetime"
}

test_dsh_protocol_and_seatbelt_agree_on_the_arm_command() {
  local policy line
  # Three owners must name the same entry point: the shipped protocol, the
  # repair line an agent is actually shown, and the PreToolUse seatbelt. Naming
  # bin/fm-watch.sh in the protocol would be denied as watcher-direct, making
  # the shipped instructions unrunnable.
  grep -q 'bin/fm-watch-arm.sh' "$ROOT/docs/supervision-protocols/dsh.md" \
    || fail "the DSH protocol must arm through bin/fm-watch-arm.sh"
  policy=$(node "$ROOT/bin/fm-arm-command-policy.mjs" --root "$ROOT" --home "$ROOT" --command 'bin/fm-watch-arm.sh')
  [ "$policy" = allow ] \
    || fail "the protocol's arm command must pass the seatbelt, got '$policy'"
  # ...and the direct form it replaced must still be denied, which is why the
  # protocol cannot name it.
  policy=$(node "$ROOT/bin/fm-arm-command-policy.mjs" --root "$ROOT" --home "$ROOT" --command 'bin/fm-watch.sh')
  case "$policy" in deny*watcher-direct*) : ;; *) fail "a direct bin/fm-watch.sh must stay denied, got '$policy'" ;; esac
  line=$(FM_DSH_HARNESS=dsh "$ROOT/bin/fm-supervision-instructions.sh" --afk 0 --x-mode 0 --repair-line 2>/dev/null | tail -1)
  assert_contains "$line" "bin/fm-watch-arm.sh" \
    "the dsh repair line must name the blessed arm script"
  pass "dsh protocol, repair line and arm seatbelt agree on bin/fm-watch-arm.sh"
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

test_dsh_guard_blocks_then_alarms_then_allows() {
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
  # A spent budget raises ONE model-visible alarm rather than silently allowing:
  # DSH's bridge logs and drops a non-blocking systemMessage, so exiting 0 here
  # produced no operator-visible record at all.
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 2 "$rc" "a spent budget must raise one visible alarm turn"
  assert_contains "$(cat "$home/stderr.txt")" "SUPERVISION IS GENUINELY DOWN" \
    "the alarm turn did not carry the alarm text"
  assert_contains "$(cat "$home/stderr.txt")" "Tell the captain" \
    "the alarm did not tell the agent to inform the captain"
  [ -f "$home/state/.dsh-turnend-fail-open" ] \
    || fail "the alarm was not latched durably"
  rc=0; run_dsh_stop "$home" s1 || rc=$?
  expect_code 0 "$rc" "after the alarm the guard must stop blocking"
  pass "fm-turnend-guard --dsh: blocks under budget, alarms once, then allows"
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
test_dsh_guard_blocks_then_alarms_then_allows
test_dsh_guard_budget_is_session_scoped
test_dsh_guard_clears_the_budget_when_supervision_is_not_needed
test_dsh_guard_fails_open_on_unusable_input
test_dsh_stop_wrapper_fails_open_without_a_root
test_dsh_session_lock_matcher_detects_launcher_paths
test_dsh_session_lock_matcher_rejects_firstmate_paths
test_dsh_digest_surfaces_a_durable_alarm
test_dsh_digest_delivers_session_start_stdout_whole
test_dsh_digest_gate_is_per_session
test_dsh_digest_retries_when_nothing_was_produced
test_dsh_guard_alarms_when_the_budget_lock_is_unavailable
test_dsh_guard_budget_is_an_episode_not_a_session
test_dsh_guard_healthy_reset_clears_the_alarm_latch
test_dsh_protocol_and_seatbelt_agree_on_the_arm_command
