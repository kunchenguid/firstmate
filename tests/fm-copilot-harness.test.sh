#!/usr/bin/env bash
# Behavior tests for the verified GitHub Copilot CLI crewmate/scout adapter.
#
# The facts pinned here are the ones a copilot release could silently change
# and the ones a wrong guess would make dangerous:
#   1. copilot publishes COPILOT_CLI=1 on its tool children (verified live on
#      1.0.88 through a model-executed env probe), and does NOT scrub an
#      inherited CLAUDECODE (verified through a non-interactive probe with
#      CLAUDECODE=1 exported), so the marker must be tested before CLAUDECODE
#      and the spawn must clear foreign markers at the launch boundary.
#      AGENT=1 is present in the launching environment too, so it must never
#      promote to a copilot identity. tests/fm-harness-precedence.test.sh
#      owns the general boundary.
#   2. The loader shim presents as comm=node with the identity in argv[1]
#      (basename copilot, or a path under @github/copilot/), while the native
#      darwin-arm64 child is literally named copilot. The anchored match must
#      never claim unrelated commands containing the fragment, and only
#      argv[0] and the first non-flag script argument are ever consulted, so
#      an unrelated command that merely talks about copilot never matches.
#   3. The launch carries the brief via -i with --model, --reasoning-effort,
#      and --yolo, plus COPILOT_ALLOW_ALL=true trusting the worktree for the
#      run; --yolo alone does not suppress the trust dialog, so the env
#      prefix is load-bearing rather than cosmetic.
#   4. A fresh worktree would park copilot on its Confirm folder trust
#      dialog, so the post-launch gate is the backstop: it answers a dialog
#      that renders anyway exactly once, then requires the session-events
#      fold - and only that verdict, because the fold binds the turn to the
#      worktree - before the spawn reports success, and fails the spawn with
#      endpoint cleanup when the brief cannot be confirmed to run there.
#   5. copilot is a crewmate/scout adapter only: a secondmate launch is
#      refused, and nothing is armed as busy wiring because no writer could
#      clear it; the spawn writes only the session binding sidecar.
#   6. The busy fold is last-boundary-wins over the session events: opens are
#      user.message, model.turn_started, and assistant.turn_start, closes are
#      assistant.turn_end, abort, and session.shutdown, and extraction is
#      anchored on the structural line prefix so worker output naming a
#      boundary can never close the turn.
#   7. Interrupt is a single Ctrl+C (Escape showed no verifiable effect live),
#      with no clear key and no ack source, and exit is /exit.
#   8. Herdr's registry already tracks copilot, and exit detection proves the
#      agent at process level before trusting any registration (the shared
#      post-#4115 contract in bin/backends/herdr.sh): the node loader shim is
#      proven through its structural argv, not its comm.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI COPILOT_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-copilot-harness)

test_copilot_marker_claims_the_identity() {
  local fakebin out base_path
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-blind")
  fm_fake_blind_ancestry "$fakebin"
  base_path=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
  # This is the exact hazard: copilot does not scrub an inherited CLAUDECODE,
  # so a copilot worker under a claude primary carries both markers at once.
  out=$(PATH="$fakebin:$base_path" CLAUDECODE=1 COPILOT_CLI=1 "$HARNESS")
  [ "$out" = copilot ] \
    || fail "CLAUDECODE + COPILOT_CLI must detect copilot, got '$out'"
  # Drive the two signals apart so the case above cannot go quietly vacuous:
  # each marker alone must still produce its own verdict.
  out=$(env -u CLAUDECODE PATH="$fakebin:$base_path" COPILOT_CLI=1 "$HARNESS")
  [ "$out" = copilot ] \
    || fail "COPILOT_CLI alone must detect copilot, got '$out'"
  out=$(env -u COPILOT_CLI PATH="$fakebin:$base_path" CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] \
    || fail "CLAUDECODE alone must still detect claude, got '$out'"
  pass "fm-harness.sh: the copilot marker claims the identity before CLAUDECODE"
}

test_copilot_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/u/.npm-global/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot'; exit 0 ;;
  *"args="*) printf '%s\n' '/Users/u/.npm-global/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot -i hi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = copilot ] \
    || fail "a natively-named copilot command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named copilot command"
}

test_copilot_ancestry_reaches_the_loader_shim_through_argv() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-shim")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /Users/u/.npm-global/bin/copilot -i hi --model auto'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = copilot ] \
    || fail "the node loader shim must be detected through its script argument, got '$out'"
  pass "fm-harness.sh: ancestry reaches the node loader shim through argv"
}

test_copilot_ancestry_rejects_unrelated_mentions() {
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

  out=$(FAKE_PS_COMM=copilot-helper FAKE_PS_ARGS='copilot-helper --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != copilot ] \
    || fail "an unrelated copilot-helper command must not detect copilot, got '$out'"

  out=$(FAKE_PS_COMM=mycopilot FAKE_PS_ARGS='mycopilot --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != copilot ] \
    || fail "an unrelated mycopilot command must not detect copilot, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo copilot --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != copilot ] \
    || fail "a later shell argument naming copilot must not detect copilot, got '$out'"

  out=$(FAKE_PS_COMM=node FAKE_PS_ARGS='node /opt/work/server.js --mode copilot' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != copilot ] \
    || fail "a node script merely talking about copilot must not detect copilot, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated copilot mentions"
}

test_copilot_claims_no_inherited_launcher_marker() {
  local fakebin out
  # AGENT=1 is present in ordinary launching environments, so it must never
  # promote to a copilot identity the way COPILOT_CLI does. Blind the real
  # ancestry so the verdict cannot pass vacuously on the suite's own
  # launcher.
  fakebin=$(fm_fakebin "$TMP_ROOT/marker-agent")
  fm_fake_blind_ancestry "$fakebin"
  out=$(PATH="$fakebin:${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" AGENT=1 "$HARNESS")
  [ "$out" != copilot ] \
    || fail "an inherited AGENT=1 must never claim the copilot identity, got '$out'"
  # Drive the hazard the other way: copilot does not scrub an inherited
  # CLAUDECODE, so a structural copilot ancestor must still outrank the
  # retained marker rather than being renamed away from it. Pin both halves
  # so neither can rot silently.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' copilot; exit 0 ;;
  *"args="*) printf '%s\n' 'copilot -i hi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = copilot ] \
    || fail "a structural copilot ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: no inherited launcher marker claims the copilot identity"
}

test_copilot_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported copilot || fail "copilot must be a supported control harness"
  [ "$(fm_control_harness_family copilot)" = copilot ] || fail "copilot must map to its own family"
  fm_control_harness_supports_kind copilot scout || fail "copilot must run scouts"
  fm_control_harness_supports_kind copilot ship || fail "copilot must run ships"
  fm_control_harness_supports_kind copilot secondmate \
    && fail "copilot must refuse secondmates" || true
  [ "$(fm_control_interrupt_key copilot)" = C-c ] || fail "copilot must interrupt on Ctrl+C"
  [ "$(fm_control_interrupt_repeat copilot)" = 1 ] || fail "copilot must interrupt on a single press"
  [ -z "$(fm_control_interrupt_clear_key copilot)" ] || fail "copilot must need no clear key"
  [ "$(fm_control_interrupt_ack_source copilot)" = none ] || fail "copilot must have no ack source"
  [ "$(fm_control_exit_command copilot)" = /exit ] || fail "copilot must exit on /exit"
  pass "fm-control-lib: copilot mechanics are Ctrl+C once, no clear key, and /exit"
}

test_copilot_delivery_signature_is_harness_scoped() {
  printf 'Working · esc interrupt\n' | fm_busy_lines_match copilot \
    || fail "harness=copilot must match its own esc token"
  printf 'Waiting for background shells · esc interrupt\n' | fm_busy_lines_match copilot \
    || fail "harness=copilot must match the background-shells row too"
  printf 'esc interrupt\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow copilot's esc token" || true
  printf 'Ctrl+c:cancel\n' | fm_busy_lines_match copilot \
    && fail "harness=copilot must never borrow grok's token" || true
  printf 'esc interrupt\n' | fm_busy_lines_match kimi \
    && fail "harness=kimi must never borrow copilot's token" || true
  printf 'esc interrupt\n' | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  pass "fm-composer-lib: copilot delivery signatures never cross harnesses"
}

copilot_events_fixture() {  # <file> <scenario>
  local file=$1
  case "$2" in
    open)
      cat > "$file" <<'EOF'
{"type":"session.start","data":{},"id":"a","timestamp":"2026-09-24T08:00:00.000Z","parentId":null}
{"type":"user.message","data":{},"id":"b","timestamp":"2026-09-24T08:00:01.000Z","parentId":"a"}
{"type":"assistant.turn_start","data":{},"id":"c","timestamp":"2026-09-24T08:00:05.000Z","parentId":"b"}
{"type":"tool.execution_start","data":{},"id":"d","timestamp":"2026-09-24T08:00:06.000Z","parentId":"c"}
EOF
      ;;
    closed)
      cat > "$file" <<'EOF'
{"type":"session.start","data":{},"id":"a","timestamp":"2026-09-24T08:00:00.000Z","parentId":null}
{"type":"user.message","data":{},"id":"b","timestamp":"2026-09-24T08:00:01.000Z","parentId":"a"}
{"type":"assistant.turn_start","data":{},"id":"c","timestamp":"2026-09-24T08:00:05.000Z","parentId":"b"}
{"type":"assistant.message","data":{"content":"done"},"id":"d","timestamp":"2026-09-24T08:00:09.000Z","parentId":"c"}
{"type":"assistant.turn_end","data":{},"id":"e","timestamp":"2026-09-24T08:00:10.000Z","parentId":"d"}
{"type":"session.usage_checkpoint","data":{},"id":"f","timestamp":"2026-09-24T08:00:11.000Z","parentId":"e"}
EOF
      ;;
    model-gap)
      cat > "$file" <<'EOF'
{"type":"session.start","data":{},"id":"a","timestamp":"2026-09-24T08:00:00.000Z","parentId":null}
{"type":"user.message","data":{},"id":"b","timestamp":"2026-09-24T08:00:01.000Z","parentId":"a"}
{"type":"model.turn_started","data":{},"id":"c","timestamp":"2026-09-24T08:00:02.000Z","parentId":"b"}
{"type":"model.model_call_started","data":{},"id":"d","timestamp":"2026-09-24T08:00:03.000Z","parentId":"c"}
EOF
      ;;
    content-trap)
      cat > "$file" <<'EOF'
{"type":"session.start","data":{},"id":"a","timestamp":"2026-09-24T08:00:00.000Z","parentId":null}
{"type":"user.message","data":{},"id":"b","timestamp":"2026-09-24T08:00:01.000Z","parentId":"a"}
{"type":"assistant.turn_start","data":{},"id":"c","timestamp":"2026-09-24T08:00:05.000Z","parentId":"b"}
{"type":"assistant.message","data":{"content":"to close a turn the CLI writes {\"type\":\"assistant.turn_end\"} at line start"},"id":"d","timestamp":"2026-09-24T08:00:09.000Z","parentId":"c"}
EOF
      ;;
    aborted)
      cat > "$file" <<'EOF'
{"type":"session.start","data":{},"id":"a","timestamp":"2026-09-24T08:00:00.000Z","parentId":null}
{"type":"user.message","data":{},"id":"b","timestamp":"2026-09-24T08:00:01.000Z","parentId":"a"}
{"type":"assistant.turn_start","data":{},"id":"c","timestamp":"2026-09-24T08:00:05.000Z","parentId":"b"}
{"type":"tool.execution_start","data":{},"id":"d","timestamp":"2026-09-24T08:00:06.000Z","parentId":"c"}
{"type":"assistant.turn_end","data":{},"id":"e","timestamp":"2026-09-24T08:00:20.000Z","parentId":"d"}
{"type":"abort","data":{"reason":"user_initiated"},"id":"f","timestamp":"2026-09-24T08:00:21.000Z","parentId":"e"}
EOF
      ;;
    empty)
      : > "$file"
      ;;
  esac
}

test_copilot_fold_reads_the_turn_boundaries() {
  local dir events got
  dir="$TMP_ROOT/fold"; mkdir -p "$dir"
  events="$dir/events.jsonl"
  copilot_events_fixture "$events" open
  got=$(fm_busy_copilot_turn_state "$events")
  [ "$got" = busy ] || fail "an open turn must fold busy, got '$got'"
  copilot_events_fixture "$events" closed
  got=$(fm_busy_copilot_turn_state "$events")
  [ "$got" = settled ] || fail "a closed turn must fold settled, got '$got'"
  copilot_events_fixture "$events" model-gap
  got=$(fm_busy_copilot_turn_state "$events")
  [ "$got" = busy ] || fail "a model-call gap must still fold busy, got '$got'"
  copilot_events_fixture "$events" aborted
  got=$(fm_busy_copilot_turn_state "$events")
  [ "$got" = settled ] || fail "an aborted turn must fold settled, got '$got'"
  copilot_events_fixture "$events" empty
  got=$(fm_busy_copilot_turn_state "$events")
  [ "$got" = none ] || fail "a boundary-free log must fold none, got '$got'"
  pass "fm-busy-lib: the copilot fold reads opens, closes, gaps, and aborts"
}

test_copilot_fold_ignores_worker_output_naming_a_boundary() {
  local dir events got
  dir="$TMP_ROOT/trap"; mkdir -p "$dir"
  events="$dir/events.jsonl"
  copilot_events_fixture "$events" content-trap
  got=$(fm_busy_copilot_turn_state "$events")
  [ "$got" = busy ] || fail "message content naming a boundary must not close the turn, got '$got'"
  pass "fm-busy-lib: worker output cannot fake a copilot turn boundary"
}

make_copilot_home_case() {  # <name> -> "<case-dir>|<home>|<worktree>"
  local name=$1 case_dir home wt
  case_dir="$TMP_ROOT/home-$name"
  home="$case_dir/home"
  wt="$case_dir/wt"
  mkdir -p "$home" "$wt"
  printf '%s|%s|%s\n' "$case_dir" "$home" "$wt"
}

read_copilot_home_case() {
  IFS='|' read -r CASE_DIR HOME_DIR WT_DIR <<EOF
$1
EOF
}

seed_copilot_session() {  # <home> <uuid> <cwd> <scenario>
  local dir=$1/session-state/$2
  mkdir -p "$dir"
  printf 'id: %s\ncwd: %s\n' "$2" "$3" > "$dir/workspace.yaml"
  copilot_events_fixture "$dir/events.jsonl" "$4"
}

write_copilot_sidecar() {  # <state-dir> <id> <home> <worktree> [prior-uuid...]
  local statedir=$1 id=$2 home=$3 wt=$4 prior
  {
    printf 'copilot_home=%s\n' "$home/.copilot"
    printf 'workspace_root=%s\n' "$wt"
    printf 'binding_id=%s\n' "test-binding-$$"
    shift 4
    for prior in "$@"; do
      printf 'prior_session=%s\n' "$prior"
    done
  } > "$statedir/$id.copilot-session"
}

test_copilot_session_binding_matches_the_resolved_worktree() {
  local rec statedir got link
  rec=$(make_copilot_home_case match)
  read_copilot_home_case "$rec"
  statedir="$CASE_DIR/state"; mkdir -p "$statedir"
  seed_copilot_session "$HOME_DIR/.copilot" aaaabbbb-1111-2222-3333-444455556666 "$WT_DIR" open
  seed_copilot_session "$HOME_DIR/.copilot" ccccdddd-1111-2222-3333-444455556666 "/nowhere/else" closed
  write_copilot_sidecar "$statedir" copilot-case-1 "$HOME_DIR" "$WT_DIR"
  got=$(fm_busy_copilot_session_dir "$statedir" copilot-case-1)
  [ "$got" = "$HOME_DIR/.copilot/session-state/aaaabbbb-1111-2222-3333-444455556666" ] \
    || fail "the binding must resolve the session in this worktree, got '$got'"
  link="$CASE_DIR/wt-link"
  ln -s "$WT_DIR" "$link"
  write_copilot_sidecar "$statedir" copilot-case-2 "$HOME_DIR" "$link"
  got=$(fm_busy_copilot_session_dir "$statedir" copilot-case-2)
  [ "$got" = "$HOME_DIR/.copilot/session-state/aaaabbbb-1111-2222-3333-444455556666" ] \
    || fail "the binding must match through a symlinked worktree path, got '$got'"
  pass "fm-busy-lib: copilot session binding matches the (resolved) worktree"
}

test_copilot_session_binding_excludes_priors_and_refuses_ambiguity() {
  local rec statedir got rc
  rec=$(make_copilot_home_case priors)
  read_copilot_home_case "$rec"
  statedir="$CASE_DIR/state"; mkdir -p "$statedir"
  seed_copilot_session "$HOME_DIR/.copilot" aaaabbbb-1111-2222-3333-444455556666 "$WT_DIR" closed
  seed_copilot_session "$HOME_DIR/.copilot" ccccdddd-1111-2222-3333-444455556666 "$WT_DIR" open
  write_copilot_sidecar "$statedir" copilot-case-3 "$HOME_DIR" "$WT_DIR" aaaabbbb-1111-2222-3333-444455556666
  got=$(fm_busy_copilot_session_dir "$statedir" copilot-case-3)
  [ "$got" = "$HOME_DIR/.copilot/session-state/ccccdddd-1111-2222-3333-444455556666" ] \
    || fail "the binding must fold the new session, not its predecessor, got '$got'"
  write_copilot_sidecar "$statedir" copilot-case-4 "$HOME_DIR" "$WT_DIR"
  rc=0; got=$(fm_busy_copilot_session_dir "$statedir" copilot-case-4) || rc=$?
  [ "$rc" -ne 0 ] || fail "two indistinguishable sessions must fail closed, got '$got'"
  pass "fm-busy-lib: copilot binding excludes priors and refuses ambiguity"
}

test_copilot_classify_folds_the_bound_session() {
  local rec statedir busy idle unknown
  rec=$(make_copilot_home_case classify)
  read_copilot_home_case "$rec"
  statedir="$CASE_DIR/state"; mkdir -p "$statedir"
  seed_copilot_session "$HOME_DIR/.copilot" aaaabbbb-1111-2222-3333-444455556666 "$WT_DIR" open
  write_copilot_sidecar "$statedir" copilot-case-5 "$HOME_DIR" "$WT_DIR"
  busy=$(fm_busy_classify tmux fake:win copilot copilot-case-5 "$statedir")
  [ "$busy" = "busy copilot-session-log" ] || fail "an open session must classify busy copilot-session-log, got '$busy'"
  copilot_events_fixture "$HOME_DIR/.copilot/session-state/aaaabbbb-1111-2222-3333-444455556666/events.jsonl" closed
  idle=$(fm_busy_classify tmux fake:win copilot copilot-case-5 "$statedir")
  [ "$idle" = "idle copilot-session-log" ] || fail "a settled session must classify idle copilot-session-log, got '$idle'"
  unknown=$(fm_busy_classify tmux fake:win copilot copilot-case-6 "$statedir")
  [ "$unknown" = "unknown copilot-session-log" ] || fail "a missing sidecar must classify unknown, got '$unknown'"
  pass "fm-busy-lib: copilot classifies busy, idle, and unknown through the fold"
}

test_copilot_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name copilot)
  [ "$got" = agent ] || fail "tmux liveness must read the copilot binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name copilot-helper)
  [ "$got" = other ] || fail "tmux liveness must not read copilot-helper as an agent, got '$got'"
  got=$(fm_agent_process_classify_name mycopilot)
  [ "$got" = other ] || fail "tmux liveness must not read mycopilot as an agent, got '$got'"
  got=$(fm_agent_process_classify_name node)
  [ "$got" = other ] || fail "tmux liveness must not read a bare node as an agent, got '$got'"
  got=$(fm_agent_process_classify node node 'node /Users/u/.npm-global/bin/copilot -i hi --model auto')
  [ "$got" = agent ] || fail "tmux liveness must read the loader shim through its argv as an agent, got '$got'"
  got=$(fm_agent_process_classify node node 'node /opt/work/server.js --mode copilot')
  [ "$got" = other ] || fail "tmux liveness must not read an unrelated node script as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: copilot is an agent, fragments and strangers are not"
}

# Canned `pane process-info` bodies for the herdr fixtures. The shared
# exit-detection contract proves a registered agent at process level before
# trusting it (bin/backends/herdr.sh fm_backend_herdr_pane_process_state), and
# the copilot loader shim (comm=node) is proven through its structural argv,
# not its name - the same split the tmux probe above pins.
copilot_herdr_process_info_body() {  # <shell-pid> <name> <argv0> <cmdline> -> JSON
  printf '%s\n' "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w9:p1\",\"shell_pid\":$1,\"foreground_processes\":[{\"pid\":$(( $1 + 1 )),\"name\":\"$2\",\"argv\":[\"$3\"],\"argv0\":\"$3\",\"cmdline\":\"$4\"}]}}}"
}

copilot_herdr_agent_state() {  # <fixture-dir> -> verdict; logs every CLI call
  local dir=$1
  : > "$dir/calls.log"
  COPILOT_FIX_RESP="$dir/agent-get.json" COPILOT_FIX_PROC="$dir/process-info.json" \
    COPILOT_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$COPILOT_FIX_LOG"
      case "$*" in
        *"agent get"*) cat "$COPILOT_FIX_RESP" ;;
        *"pane process-info"*) cat "$COPILOT_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_pane_agent_state testsession w9:p1' "$ROOT" 2>&1
}

copilot_herdr_process_sample() {  # <fixture-dir> -> sample verdict
  local dir=$1
  COPILOT_FIX_PROC="$dir/process-info.json" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      case "$*" in
        *"pane process-info"*) cat "$COPILOT_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_pane_process_state_sample testsession w9:p1' "$ROOT" 2>&1
}

test_herdr_registered_status_with_a_copilot_foreground_stays_live() {
  local dir out
  dir="$TMP_ROOT/herdr-native"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"copilot","agent_status":"idle","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  copilot_herdr_process_info_body 424242 copilot copilot "copilot -i hi" > "$dir/process-info.json"
  out=$(copilot_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered status with a copilot foreground must stay live, got '$out'"
  grep -q "process-info" "$dir/calls.log" \
    || fail "the shared contract proves a registered agent at process level; the verdict trusted the registration alone"
  pass "herdr exit detection: a registered pane with a copilot foreground stays live"
}

test_herdr_loader_shim_is_proven_through_its_argv() {
  local dir out
  dir="$TMP_ROOT/herdr-shim"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"copilot","agent_status":"working","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  copilot_herdr_process_info_body 424242 node node "node /Users/u/.npm-global/bin/copilot -i hi --model auto" > "$dir/process-info.json"
  out=$(copilot_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered status over the node loader shim must stay live, got '$out'"
  # The shim-vs-stranger distinction lives one layer down: the process sample
  # proves the shim an agent through its structural argv, while an unrelated
  # node script samples as other (never agent). The agent_state verdict above
  # stays fail-safe toward live for either, by the shared contract's design.
  out=$(copilot_herdr_process_sample "$dir")
  [ "$out" = agent ] || fail "the loader shim must sample as an agent, got '$out'"
  dir="$TMP_ROOT/herdr-stranger"; mkdir -p "$dir"
  copilot_herdr_process_info_body 424242 node node "node /opt/work/server.js --mode copilot" > "$dir/process-info.json"
  out=$(copilot_herdr_process_sample "$dir")
  [ "$out" != agent ] || fail "an unrelated node script must never sample as an agent, got '$out'"
  pass "herdr exit detection: the loader shim proves through argv, strangers do not"
}

# The fake tmux renders a copilot-shaped screen that advances through
# launched -> (trust dialog ->) busy as the real spawn drives it, so the
# launch command, the trust bypass, the single Enter that answers a dialog,
# and the readiness gate are exercised through their real code paths.
# Whether the dialog renders is decided the way copilot decides it: the env
# prefix on the launch command carries COPILOT_ALLOW_ALL=true, and the fake
# honors it exactly like the CLI (no dialog); FM_FAKE_COPILOT_DIALOG=1 models
# a pane where the dialog renders anyway (a lost env), answered once before
# the session materializes; FM_FAKE_COPILOT_ANSWER=stuck models a dialog
# whose answer never turns into a busy turn. Session materialization writes
# real session-state files under the fake COPILOT_HOME, so the gate folds
# them through the genuine classifier path, not a stub verdict.
make_copilot_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_COPILOT_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    dialog)
      printf 'Confirm folder trust\n\n%s\n\nCopilot can read files in this folder and, with your permission, edit them or run code and shell commands.\n\nDo you trust the files in this folder?\n\n  1. Yes\n  2. Yes, and remember this folder for future sessions\n  3. No (Esc)\n' "$FM_FAKE_PANE_PATH"
      ;;
    busy)
      printf 'PONG\n\n/private/tmp/fake\n\n                                                                Session: 0.1 AIC used\n________________________________________________________________________________\n\n\n <- open sidebar\n'
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
materialize_session() {
  local uuid=11111111-2222-3333-4444-555555555555 dir
  dir="$FM_FAKE_COPILOT_HOME/session-state/$uuid"
  mkdir -p "$dir"
  printf 'id: %s\ncwd: %s\n' "$uuid" "$FM_FAKE_PANE_PATH" > "$dir/workspace.yaml"
  cat > "$dir/events.jsonl" <<'EOF'
{"type":"session.start","data":{},"id":"a","timestamp":"2026-09-24T08:00:00.000Z","parentId":null}
{"type":"user.message","data":{},"id":"b","timestamp":"2026-09-24T08:00:01.000Z","parentId":"a"}
{"type":"assistant.turn_start","data":{},"id":"c","timestamp":"2026-09-24T08:00:05.000Z","parentId":"b"}
EOF
}
launch_trusted() {
  grep -q "COPILOT_ALLOW_ALL=true" "$FM_FAKE_LAUNCH_LOG" 2>/dev/null
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    literal=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        ". '"*"'") staged=${literal#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || literal=$(cat "$staged") ;;
      esac
      case "$literal" in
        *' -i '*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_COPILOT_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_COPILOT_DIALOG:-0}" = 1 ] || ! launch_trusted; then
              printf 'dialog\n' > "$FM_FAKE_COPILOT_STATE"
            else
              materialize_session
              printf 'busy\n' > "$FM_FAKE_COPILOT_STATE"
            fi
            ;;
          dialog)
            if [ "${FM_FAKE_COPILOT_ANSWER:-works}" = works ]; then
              materialize_session
              printf 'busy\n' > "$FM_FAKE_COPILOT_STATE"
            fi
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/copilot" <<'SH'
#!/usr/bin/env bash
set -u
echo "fake copilot must never execute" >&2
exit 9
SH
  chmod +x "$fakebin/copilot"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_copilot_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_copilot_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Copilot dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'copilot\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/copilot.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_copilot_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# The spawn drives the real launch template and the fake tmux under this base
# PATH. Carry the directory the invoking environment resolves node from only
# where a fake needs it; the copilot fake executes nothing.
NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

run_copilot_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_COPILOT_STATE="$case_dir/copilot.state" \
    FM_FAKE_COPILOT_HOME="$home/.copilot" \
    FM_FAKE_COPILOT_DIALOG="${FM_FAKE_COPILOT_DIALOG:-0}" \
    FM_FAKE_COPILOT_ANSWER="${FM_FAKE_COPILOT_ANSWER:-works}" \
    FM_COPILOT_READY_POLLS=8 FM_COPILOT_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness copilot --mode no-mistakes --yolo off "$@" 2>&1
}

test_copilot_launch_carries_the_brief_with_model_effort_and_autonomy() {
  local id rec out rc launch meta
  id="copilot-launch-z1-$$"
  rec=$(make_copilot_spawn_case launch "$id")
  read_copilot_spawn_record "$rec"
  out=$(run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto --effort low)
  rc=$?
  expect_code 0 "$rc" "copilot spawn with model auto should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/copilot" "copilot launch did not pin the resolved absolute binary"
  assert_contains "$launch" " -i " "copilot launch did not carry the brief via -i"
  assert_contains "$launch" "--model 'auto'" "copilot launch did not carry the requested model"
  assert_contains "$launch" "--reasoning-effort 'low'" "copilot launch did not carry the requested effort"
  assert_contains "$launch" "--yolo" "copilot launch omitted unattended autonomy"
  assert_contains "$launch" "COPILOT_ALLOW_ALL=true" "copilot launch omitted the workspace trust bypass"
  assert_contains "$launch" "env -u CLAUDECODE" "copilot launch did not clear the inherited launcher marker"
  assert_contains "$launch" "env -u CURSOR_AGENT" "copilot launch did not clear the cursor/gemini markers"
  assert_not_contains "$launch" "__COPILOTBIN__" "copilot launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "copilot launch left its model placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "copilot launch left its brief placeholder unsubstituted"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=copilot' "$meta" "copilot meta did not record its harness"
  assert_grep 'model=auto' "$meta" "copilot meta did not record its model"
  assert_grep 'effort=low' "$meta" "copilot meta did not record its effort"
  pass "fm-spawn: copilot launch carries brief, model, effort, trust, and autonomy with cleared markers"
}

test_copilot_effort_max_maps_and_default_omits() {
  local id rec out rc launch meta
  id="copilot-effort-z2-$$"
  rec=$(make_copilot_spawn_case effort "$id")
  read_copilot_spawn_record "$rec"
  out=$(run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto --effort max)
  rc=$?
  expect_code 0 "$rc" "copilot spawn with max effort should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--reasoning-effort 'max'" "copilot launch did not map max effort across"
  id="copilot-noeffort-z3-$$"
  rec=$(make_copilot_spawn_case noeffort "$id")
  read_copilot_spawn_record "$rec"
  out=$(run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto)
  rc=$?
  expect_code 0 "$rc" "copilot spawn with default effort should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--reasoning-effort" "copilot launch passed an effort flag nobody requested"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=default' "$meta" "copilot meta did not record the default effort axis"
  pass "fm-spawn: copilot maps max effort and omits the flag by default"
}

test_copilot_launch_writes_only_the_binding_sidecar() {
  local id rec out rc statedir
  id="copilot-sidecar-z4-$$"
  rec=$(make_copilot_spawn_case sidecar "$id")
  read_copilot_spawn_record "$rec"
  out=$(run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto)
  rc=$?
  expect_code 0 "$rc" "copilot spawn should succeed"
  statedir="$HOME_DIR/state"
  [ -e "$statedir/$id.busy-gen" ] && fail "copilot spawn armed a busy generation nothing could clear" || true
  [ -f "$statedir/$id.copilot-session" ] || fail "copilot spawn did not write its session binding sidecar"
  assert_grep "copilot_home=$HOME_DIR/.copilot" "$statedir/$id.copilot-session" \
    "copilot sidecar did not pin the copilot home"
  assert_grep "workspace_root=$WT_DIR" "$statedir/$id.copilot-session" \
    "copilot sidecar did not pin the worktree"
  assert_grep "binding_id=" "$statedir/$id.copilot-session" \
    "copilot sidecar did not mint a binding identity"
  pass "fm-spawn: copilot arms no busy wiring and writes only its binding sidecar"
}

# Bare Enter key presses only: shell setup rides its Enter on the typed text
# (`send-keys -t <target> export X=Y Enter`), while the launch submit and the
# trust-dialog answer are lone key sends (`send-keys -t <target> Enter`).
count_enter_sends() {  # <tmux-call-log>
  grep -c '^send-keys -t [^ ]* Enter$' "$1" || true
}

test_copilot_trusted_launch_needs_only_the_launch_enter() {
  local id rec out rc enters
  id="copilot-trust-z5-$$"
  rec=$(make_copilot_spawn_case trust "$id")
  read_copilot_spawn_record "$rec"
  out=$(run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto)
  rc=$?
  expect_code 0 "$rc" "a copilot spawn with the trust bypass should succeed"
  assert_contains "$out" "spawned $id harness=copilot" "copilot spawn did not report success"
  enters=$(count_enter_sends "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 1 ] \
    || fail "a trusted launch must receive only the launch Enter, got $enters Enter sends"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful copilot spawn must never tear down the endpoint it just launched"
  pass "fm-spawn: copilot launches straight into a busy turn with no dialog"
}

test_copilot_dialog_despite_bypass_is_answered_once() {
  local id rec out rc enters
  id="copilot-vendor-z6-$$"
  rec=$(make_copilot_spawn_case vendor-dialog "$id")
  read_copilot_spawn_record "$rec"
  out=$(FM_FAKE_COPILOT_DIALOG=1 run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model auto)
  rc=$?
  expect_code 0 "$rc" "a copilot spawn whose dialog renders despite the bypass should succeed"
  enters=$(count_enter_sends "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 2 ] \
    || fail "expected exactly one launch Enter plus one trust-dialog Enter, got $enters Enter sends"
  pass "fm-spawn: copilot answers a dialog that renders anyway exactly once, then confirms busy"
}

test_copilot_dialog_that_never_turns_busy_fails_the_spawn() {
  local id rec out rc
  id="copilot-stuck-z7-$$"
  rec=$(make_copilot_spawn_case stuck "$id")
  read_copilot_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_COPILOT_DIALOG=1 FM_FAKE_COPILOT_ANSWER=stuck run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model auto) || rc=$?
  [ "$rc" -ne 0 ] || fail "a dialog that never turns into a busy turn must fail the spawn"
  assert_contains "$out" "did not start processing its brief after the folder-trust dialog was answered" \
    "a stuck trust dialog failed without its concrete reason"
  [ "$(count_enter_sends "$CASE_DIR/tmux-calls.log")" -eq 2 ] \
    || fail "the gate must answer the dialog exactly once and never hammer Enter"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed copilot readiness gate left its launched endpoint running"
  assert_grep 'failed: copilot did not start processing its brief' <(sed -E 's/ \[at=[0-9]+\]//' "$HOME_DIR/state/$id.status") \
    "a failed copilot readiness gate did not record the failure in the task status"
  pass "fm-spawn: a copilot dialog that never turns busy fails the spawn and closes the endpoint"
}

test_copilot_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id="copilot-missing-z8-$$"
  rec=$(make_copilot_spawn_case missing "$id")
  read_copilot_spawn_record "$rec"
  rm "$FAKEBIN_DIR/copilot"
  rc=0
  out=$(run_copilot_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing copilot executable should refuse the spawn"
  assert_contains "$out" "copilot executable not found on PATH" "missing copilot diagnostic lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing copilot executable created a launch command" || true
  pass "fm-spawn: a missing copilot executable refuses before pane creation"
}

test_copilot_secondmate_is_refused() {
  local id rec out rc
  id="copilot-secondmate-z9-$$"
  rec=$(make_copilot_spawn_case secondmate-refuse "$id")
  read_copilot_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate copilot 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a copilot secondmate spawn should be refused"
  assert_contains "$out" "copilot is a verified crewmate/scout adapter only" \
    "copilot secondmate refusal lacked its concrete reason"
  pass "fm-spawn: copilot cannot be launched as a secondmate"
}

test_copilot_marker_claims_the_identity
test_copilot_ancestry_detects_the_native_command_name
test_copilot_ancestry_reaches_the_loader_shim_through_argv
test_copilot_ancestry_rejects_unrelated_mentions
test_copilot_claims_no_inherited_launcher_marker
test_copilot_control_mechanics_are_the_verified_ones
test_copilot_delivery_signature_is_harness_scoped
test_copilot_fold_reads_the_turn_boundaries
test_copilot_fold_ignores_worker_output_naming_a_boundary
test_copilot_session_binding_matches_the_resolved_worktree
test_copilot_session_binding_excludes_priors_and_refuses_ambiguity
test_copilot_classify_folds_the_bound_session
test_copilot_tmux_names_the_native_binary_an_agent
test_herdr_registered_status_with_a_copilot_foreground_stays_live
test_herdr_loader_shim_is_proven_through_its_argv
test_copilot_launch_carries_the_brief_with_model_effort_and_autonomy
test_copilot_effort_max_maps_and_default_omits
test_copilot_launch_writes_only_the_binding_sidecar
test_copilot_trusted_launch_needs_only_the_launch_enter
test_copilot_dialog_despite_bypass_is_answered_once
test_copilot_dialog_that_never_turns_busy_fails_the_spawn
test_copilot_missing_binary_refuses_before_pane_creation
test_copilot_secondmate_is_refused
