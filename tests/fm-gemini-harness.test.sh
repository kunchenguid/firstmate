#!/usr/bin/env bash
# Behavior tests for the Gemini harness adapter.
#
# The facts pinned here are the ones a Gemini release could silently change and
# the ones a wrong guess would make dangerous:
#   1. GEMINI_CLI=1 is Gemini's own child/tool-process marker, and it outranks an
#      inherited CLAUDECODE, because gemini does NOT clear one (verified live on
#      gemini-cli 0.58.0 under a claude primary, where a gemini tool process
#      carried GEMINI_CLI=1 and CLAUDECODE=1 together).
#   2. AI_AGENT is NOT a Gemini identity. That same process carried the claude
#      primary's AI_AGENT value, so it is an inherited launcher marker and must
#      never be promoted to a detection source.
#   3. The installed CLI is a node bundle whose live process reports comm as
#      MainThread on modern Node/Linux, so ancestry does NOT reach it and the
#      marker is the only detection path. The comm-name arm is pinned for a
#      future natively-named binary.
#   4. Gemini is a crewmate/scout adapter only: it has no primary supervision
#      protocol, so its control mechanics are verified while a secondmate launch
#      on it is refused.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-gemini-lib.sh
. "$ROOT/bin/fm-gemini-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-gemini-harness)

test_gemini_marker_outranks_inherited_claudecode() {
  local out
  # This is the exact hazard: gemini does not clear an inherited CLAUDECODE, so
  # a gemini worker under a claude primary carries both markers at once.
  out=$(CLAUDECODE=1 GEMINI_CLI=1 "$HARNESS")
  [ "$out" = gemini ] || fail "CLAUDECODE + GEMINI_CLI must detect gemini, got '$out'"
  # Drive the two signals apart so the case above cannot go quietly vacuous:
  # each marker alone must still produce its own verdict.
  out=$(env -u CLAUDECODE GEMINI_CLI=1 "$HARNESS")
  [ "$out" = gemini ] || fail "GEMINI_CLI alone must detect gemini, got '$out'"
  out=$(env -u GEMINI_CLI CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  # Cursor's marker still outranks gemini's, preserving the documented order.
  out=$(CURSOR_AGENT=1 GEMINI_CLI=1 "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT must still outrank GEMINI_CLI, got '$out'"
  pass "fm-harness.sh: gemini's marker outranks an inherited CLAUDECODE"
}

test_gemini_does_not_claim_inherited_ai_agent() {
  local out
  # AI_AGENT was observed carrying the CLAUDE primary's value inside a gemini
  # tool process, so it proves nothing about which harness is running. A session
  # with AI_AGENT but no GEMINI_CLI must not be read as gemini.
  out=$(env -u GEMINI_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u PI_CODING_AGENT -u GROK_AGENT AI_AGENT=gemini-cli_0-58-0_agent "$HARNESS")
  [ "$out" != gemini ] \
    || fail "AI_AGENT must never claim the gemini identity, got '$out'"
  # A non-1 GEMINI_CLI is not the verified marker value either.
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
        -u PI_CODING_AGENT -u GROK_AGENT GEMINI_CLI=0 "$HARNESS")
  [ "$out" != gemini ] \
    || fail "GEMINI_CLI=0 must not claim the gemini identity, got '$out'"
  pass "fm-harness.sh: an inherited AI_AGENT never claims the gemini identity"
}

test_gemini_ancestry_matches_only_a_native_command_name() {
  local fakebin out
  # The comm-name arm is reachable only by a natively-named gemini binary. Pin
  # it with a fake ps so the arm cannot rot, and clear every marker so ONLY
  # ancestry can produce the verdict.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/gemini'; exit 0 ;;
  *"args="*) printf '%s\n' 'gemini -y'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(env -u GEMINI_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u PI_CODING_AGENT -u GROK_AGENT PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = gemini ] \
    || fail "a natively-named gemini command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named gemini command"
}

test_gemini_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"

  out=$(env -u GEMINI_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u PI_CODING_AGENT -u GROK_AGENT FAKE_PS_COMM=gemini-helper \
        FAKE_PS_ARGS='gemini-helper --serve' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != gemini ] \
    || fail "an unrelated gemini-helper command must not detect gemini, got '$out'"

  out=$(env -u GEMINI_CLI -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        -u PI_CODING_AGENT -u GROK_AGENT FAKE_PS_COMM=node \
        FAKE_PS_ARGS='node server.js --model gemini' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != gemini ] \
    || fail "a later node argument naming gemini must not detect gemini, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated gemini mentions"
}

test_gemini_node_bundle_is_not_ancestry_detectable() {
  command -v node >/dev/null 2>&1 || return 0
  local dir="$TMP_ROOT/ancestry" out comm
  mkdir -p "$dir"
  # This is the reason GEMINI_CLI is load-bearing for gemini rather than the
  # fast path it is for grok: the shipped CLI is a node bundle, and modern Node
  # on Linux reports comm as MainThread, so the interpreter arm never fires.
  # Pin the actual behaviour rather than a hoped-for one, so nobody later
  # documents ancestry as covering gemini or "fixes" it by matching MainThread.
  comm=$(node -e 'const{execSync}=require("child_process");process.stdout.write(execSync("ps -o comm= -p "+process.pid).toString().trim())' 2>/dev/null)
  [ -n "$comm" ] || return 0
  if [ "$comm" = node ]; then
    # A platform whose node DOES report `node` reaches the interpreter arm, and
    # there the gemini script path must win.
    cat > "$dir/gemini" <<'JS'
const { spawnSync } = require('child_process');
const env = { ...process.env };
for (const k of ['GEMINI_CLI', 'CLAUDECODE', 'CURSOR_AGENT', 'CURSOR_INVOKED_AS',
                 'PI_CODING_AGENT', 'GROK_AGENT']) delete env[k];
const r = spawnSync(process.env.FM_HARNESS_BIN, { env, encoding: 'utf8' });
process.stdout.write(r.stdout || '');
JS
    out=$(FM_HARNESS_BIN="$HARNESS" node "$dir/gemini" 2>/dev/null | tr -d '\n')
    [ "$out" = gemini ] \
      || fail "where node reports comm=node, a gemini script path must detect gemini, got '$out'"
    pass "fm-harness.sh: this platform's node reports comm=node and ancestry reaches gemini"
    return 0
  fi
  # The measured case: comm is not `node`, so ancestry cannot see the bundle and
  # the marker is the only detection path.
  cat > "$dir/gemini" <<'JS'
const { spawnSync } = require('child_process');
const env = { ...process.env };
for (const k of ['GEMINI_CLI', 'CLAUDECODE', 'CURSOR_AGENT', 'CURSOR_INVOKED_AS',
                 'PI_CODING_AGENT', 'GROK_AGENT']) delete env[k];
const r = spawnSync(process.env.FM_HARNESS_BIN, { env, encoding: 'utf8' });
process.stdout.write(r.stdout || '');
JS
  out=$(FM_HARNESS_BIN="$HARNESS" node "$dir/gemini" 2>/dev/null | tr -d '\n')
  [ "$out" != gemini ] \
    || fail "node reports comm=$comm here, so ancestry must not be claiming gemini; got '$out'"
  # And the marker closes exactly that gap on the same process shape.
  out=$(FM_HARNESS_BIN="$HARNESS" GEMINI_CLI=1 node -e '
const { spawnSync } = require("child_process");
const r = spawnSync(process.env.FM_HARNESS_BIN, { encoding: "utf8" });
process.stdout.write(r.stdout || "");' 2>/dev/null | tr -d '\n')
  [ "$out" = gemini ] \
    || fail "GEMINI_CLI must identify a node-bundle gemini worker, got '$out'"
  pass "fm-harness.sh: the node bundle is marker-detected, never ancestry-detected"
}

test_gemini_process_identity_reads_the_script_argument() {
  # The live shape measured on gemini-cli 0.58.0 / Node v24.20.0: comm is
  # MainThread and argv[0] is the interpreter, so only argv[1] identifies it.
  fm_gemini_args_are_gemini 'node /home/u/.local/bin/gemini -y' \
    || fail "the installed launcher shape must be recognized as gemini"
  fm_gemini_args_are_gemini '/home/u/.local/node/bin/node --max-old-space-size=10000 /home/u/.local/bin/gemini --skip-trust -y' \
    || fail "node option flags before the script must be skipped"
  fm_gemini_args_are_gemini '/opt/node/lib/node_modules/@google/gemini-cli/bundle/gemini.js' \
    || fail "the published package tree must be recognized as gemini"
  fm_gemini_args_are_gemini 'gemini -y' \
    || fail "a natively-named gemini command must be recognized"

  # Divergence: the negatives are what keep the positives from being vacuous.
  # A bare interpreter is the exact shape that must NOT be claimed, because
  # claiming it would report a stranger's node pane as a live gemini agent.
  ! fm_gemini_args_are_gemini '/home/u/.local/node/bin/node' \
    || fail "a bare node process must not be claimed as gemini"
  ! fm_gemini_args_are_gemini 'node /home/u/app/server.js' \
    || fail "an unrelated node script must not be claimed as gemini"
  # Only argv[0] and the script argument are consulted, so a command that
  # merely mentions gemini later on its line proves nothing.
  ! fm_gemini_args_are_gemini 'node /home/u/app/server.js --model gemini' \
    || fail "a later flag value naming gemini must not claim the identity"
  ! fm_gemini_args_are_gemini 'tail -f /var/log/gemini.log' \
    || fail "an unrelated command reading a gemini-named file must not match"
  # A directory component alone is not evidence.
  ! fm_gemini_args_are_gemini 'node /home/u/gemini/other.js' \
    || fail "a gemini directory component alone must not claim the identity"
  pass "fm-gemini-lib.sh: identity comes from the script argument, never a bare interpreter"
}

test_gemini_control_mechanics_are_the_verified_ones() {
  local out
  fm_control_harness_supported gemini || fail "gemini must be a supported control harness"
  out=$(fm_control_harness_family gemini-0.58.0)
  [ "$out" = gemini ] || fail "a recorded gemini* harness must resolve to gemini, got '$out'"
  out=$(fm_control_interrupt_key gemini)
  [ "$out" = Escape ] || fail "gemini interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat gemini)
  [ "$out" = 1 ] || fail "gemini interrupts on a single press, got '$out'"
  out=$(fm_control_interrupt_clear_key gemini)
  [ -z "$out" ] || fail "gemini needs no composer clear key, got '$out'"
  out=$(fm_control_exit_command gemini)
  [ "$out" = /quit ] || fail "gemini exits with /quit, got '$out'"
  pass "fm-control-lib.sh: gemini carries its verified interrupt and exit mechanics"
}

test_gemini_is_crewmate_and_scout_only() {
  fm_control_harness_supports_kind gemini ship \
    || fail "gemini must be verified for ship work"
  fm_control_harness_supports_kind gemini scout \
    || fail "gemini must be verified for scout work"
  ! fm_control_harness_supports_kind gemini secondmate \
    || fail "gemini has no primary supervision protocol and must be refused for secondmates"
  pass "fm-control-lib.sh: gemini is a crewmate/scout adapter only"
}

test_gemini_wiring_stays_outside_the_worktree() {
  local out
  out=$(fm_control_harness_wiring_paths gemini /wt /state task-1)
  [ "$out" = "/state/task-1.gemini-settings.json" ] \
    || fail "gemini's per-task wiring is its firstmate-owned settings file, got '$out'"
  case "$out" in
    /wt/*) fail "gemini must never claim a path inside the worktree: '$out'" ;;
  esac
  pass "fm-control-lib.sh: gemini's wiring stays outside the project worktree"
}

test_gemini_marker_outranks_inherited_claudecode
test_gemini_does_not_claim_inherited_ai_agent
test_gemini_ancestry_matches_only_a_native_command_name
test_gemini_ancestry_rejects_unrelated_mentions
test_gemini_node_bundle_is_not_ancestry_detectable
test_gemini_process_identity_reads_the_script_argument
test_gemini_control_mechanics_are_the_verified_ones
test_gemini_is_crewmate_and_scout_only
test_gemini_wiring_stays_outside_the_worktree
