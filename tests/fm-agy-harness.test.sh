#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI crewmate/scout adapter.
#
# The facts pinned here are the ones an agy release could silently change and
# the ones a wrong guess would make dangerous:
#   1. agy publishes no harness-identity marker of its own (a live 1.2.0 TUI
#      carries no AGY_* variable; AGENT=1 there is inherited launcher state),
#      so detection is ancestry alone on the anchored process name `agy`.
#   2. The anchored match must never claim unrelated commands containing the
#      fragment, and a structural agy ancestor now outranks a retained or
#      inherited CLAUDECODE - tests/fm-harness-precedence.test.sh owns the
#      general boundary.
#   3. The launch carries the brief via --prompt-interactive with --model,
#      --effort, and --dangerously-skip-permissions; a requested model a
#      reachable `agy models` omits refuses loudly instead of wedging a pane,
#      while a hung or unreachable listing is cut off and never blocks.
#   4. A fresh worktree would park agy on its folder-trust dialog, so the spawn
#      pre-registers the worktree in agy's own trustedWorkspaces store through
#      bin/fm-agy-trust.sh (scope-refused for anything but a linked worktree
#      of the project) and the post-launch gate is the backstop: it answers a
#      dialog that renders anyway exactly once, never counts a busy turn as
#      ready on an unregistered path until the dialog has been answered (the
#      Herdr native-busy-before-dialog race), and fails the spawn with endpoint
#      cleanup when the brief cannot be confirmed to run in the worktree.
#   5. agy is a crewmate/scout adapter only and a secondmate launch is refused.
#      Its turn-end hook is GLOBAL, so the spawn arms a busy generation and
#      attributes a firing through a private per-task token: the hook must be
#      inert for every session that token does not name, and a forged token
#      must never escape the registry directory.
#   6. The busy signature is the pinned `esc to cancel` status row alone; the
#      free-floating `Generating...` word must never read busy on its own.
#   7. Herdr's registry already tracks agy, and exit detection proves the
#      agent at process level before trusting any registration (the shared
#      post-#4115 contract in bin/backends/herdr.sh): a registered status plus
#      a process view naming agy is live and refuses replacement, a registered
#      status over a proven shell-only pane is the explicit stale-agent state,
#      and nothing short of that shared proof flips an agy pane to agent-free.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TRUST="$ROOT/bin/fm-agy-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# The store is agy's own persisted settings JSON, so trust is asserted against
# the parsed trustedWorkspaces array and preservation against parsed values.
agy_trusted_paths() {  # <store>
  node -e 'const fs=require("node:fs");const j=fs.existsSync(process.argv[1])?JSON.parse(fs.readFileSync(process.argv[1],"utf8")):{};for(const p of (j.trustedWorkspaces||[]))console.log(p);' "$1"
}

agy_store_value() {  # <store> <key>
  node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify(j[process.argv[2]]));' "$1" "$2"
}

assert_agy_trusted() {  # <store> <path> <msg>
  agy_trusted_paths "$1" | grep -Fqx "$2" || fail "$3"
}

assert_agy_not_trusted() {  # <store> <path> <msg>
  agy_trusted_paths "$1" | grep -Fqx "$2" && fail "$3"
  return 0
}

test_agy_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/usr/local/bin/agy'; exit 0 ;;
  *"args="*) printf '%s\n' 'agy --prompt-interactive hello'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = agy ] \
    || fail "a natively-named agy command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named agy command"
}

test_agy_ancestry_rejects_unrelated_mentions() {
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

  out=$(FAKE_PS_COMM=magyk FAKE_PS_ARGS='magyk --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != agy ] \
    || fail "an unrelated magyk command must not detect agy, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo agy --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != agy ] \
    || fail "a later shell argument naming agy must not detect agy, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated agy mentions"
}

test_agy_claims_no_inherited_launcher_marker() {
  local fakebin out
  # AGENT=1 was observed on a live agy TUI as inherited launcher state, so it
  # must never promote to an agy identity the way GEMINI_CLI does for gemini.
  out=$(AGENT=1 "$HARNESS")
  [ "$out" != agy ] \
    || fail "an inherited AGENT=1 must never claim the agy identity, got '$out'"
  # Drive the hazard the other way: agy does not clear an inherited CLAUDECODE,
  # so a structural agy ancestor must still outrank the retained marker rather
  # than being renamed away from it. Pin both halves so neither can rot
  # silently.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' agy; exit 0 ;;
  *"args="*) printf '%s\n' 'agy --prompt-interactive hi'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = agy ] \
    || fail "a structural agy ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: no inherited launcher marker claims the agy identity"
}

test_agy_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported agy || fail "agy must be a supported control harness"
  [ "$(fm_control_harness_family agy)" = agy ] || fail "agy must map to its own family"
  fm_control_harness_supports_kind agy scout || fail "agy must run scouts"
  fm_control_harness_supports_kind agy ship || fail "agy must run ships"
  fm_control_harness_supports_kind agy secondmate \
    && fail "agy must refuse secondmates" || true
  [ "$(fm_control_interrupt_key agy)" = Escape ] || fail "agy must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat agy)" = 1 ] || fail "agy must interrupt on a single press"
  [ -z "$(fm_control_interrupt_clear_key agy)" ] || fail "agy must need no clear key"
  [ "$(fm_control_interrupt_ack_source agy)" = none ] || fail "agy must have no ack source"
  [ "$(fm_control_exit_command agy)" = /quit ] || fail "agy must exit on /quit"
  # agy's Stop hook does not fire on a manual interrupt and agy has no
  # session-end event, so firstmate must close the record itself. The adapters
  # that DO close their own must stay out, or firstmate would overwrite a
  # verdict their own hook already recorded.
  fm_control_interrupt_clears_busy agy     || fail "agy must have its busy record closed by firstmate on interrupt"
  fm_control_interrupt_clears_busy claude     && fail "claude closes its own interrupt state and must not be overwritten here" || true
  fm_control_interrupt_clears_busy gemini     && fail "gemini's AfterAgent fires on interrupt, so firstmate must not overwrite it" || true
  pass "fm-control-lib: agy mechanics are Escape once, no clear key, /quit, and a firstmate-closed interrupt"
}

test_agy_turnend_registry_paths_are_scoped_to_agy() {
  local token_path auth_path
  token_path=$(fm_control_harness_turnend_token_path agy /st t9)
  [ "$token_path" = "/st/t9.agy-turnend-token" ]     || fail "agy's turn-end token sidecar path is wrong: $token_path"
  auth_path=$(fm_control_harness_turnend_auth_path agy fm.aaaaaaaaaaaa)
  [ "$auth_path" = "$HOME/.gemini/antigravity-cli/fm-turn-end.d/fm.aaaaaaaaaaaa" ]     || fail "agy's turn-end registry path is wrong: $auth_path"
  # A token carrying a separator must never resolve to a path at all.
  [ -z "$(fm_control_harness_turnend_auth_path agy '../escape')" ]     || fail "a traversal token resolved to an agy registry path"
  [ -z "$(fm_control_harness_turnend_auth_path agy '')" ]     || fail "an empty token resolved to an agy registry path"
  pass "fm-control-lib: agy's turn-end token and registry paths are scoped and traversal-safe"
}

test_agy_busy_tail_needs_the_pinned_status_row() {
  printf 'working\nesc to cancel\n' | fm_busy_agy_tail_busy \
    || fail "the esc-to-cancel status row must read busy"
  printf 'working\n  Generating...\n' | fm_busy_agy_tail_busy \
    && fail "the free-floating Generating word alone must not read busy" || true
  printf 'Generating report...\ndone\n? for shortcuts\n>\n' | fm_busy_agy_tail_busy \
    && fail "echoed worker output naming Generating must not read busy" || true
  printf 'idle\n? for shortcuts\n>\n' | fm_busy_agy_tail_busy \
    && fail "an idle footer must not read busy" || true
  printf 'Generating report...\ndone\n? for shortcuts\n>\n' | fm_busy_lines_match agy \
    && fail "the delivery guard must not acknowledge on echoed Generating output" || true
  FM_BUSY_AGY_REGEX='idle' bash -c '. "$0/bin/fm-busy-lib.sh"; printf "idle\n" | fm_busy_agy_tail_busy' "$ROOT" \
    && fail "an environment override must not change the agy busy signature" || true
  pass "fm-busy-lib: only the pinned esc-to-cancel row carries the agy busy verdict"
}

test_agy_busy_signatures_are_harness_scoped() {
  printf 'esc to cancel\n' | fm_busy_lines_match agy \
    || fail "harness=agy must match its own esc token"
  printf 'esc to cancel\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow agy's esc token" || true
  printf 'Ctrl+c:cancel\n' | fm_busy_lines_match agy \
    && fail "harness=agy must never borrow grok's token" || true
  printf 'esc to cancel\n' | fm_busy_lines_match kimi \
    && fail "harness=kimi must never borrow agy's token" || true
  printf 'esc to cancel\n' | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  pass "fm-composer-lib: agy delivery signatures never cross harnesses"
}

test_agy_classify_reports_unknown_when_the_marker_scrolls_out() {
  local statedir busy idle
  statedir="$TMP_ROOT/classify"; mkdir -p "$statedir"
  busy=$(fm_busy_classify tmux fake:win agy agy-case-1 "$statedir" 'turn running
esc to cancel                                                           Gemini 3.8 Flash · low')
  [ "$busy" = "busy agy-regex" ] || fail "a busy tail must classify busy agy-regex, got '$busy'"
  idle=$(fm_busy_classify tmux fake:win agy agy-case-2 "$statedir" 'reply landed
? for shortcuts                                                         Gemini 3.8 Flash · low')
  [ "$idle" = "unknown agy-regex" ] || fail "a scrolled-out marker must classify unknown, got '$idle'"
  pass "fm-busy-lib: agy classifies busy on its marker and unknown without it"
}

test_agy_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name agy)
  [ "$got" = agent ] || fail "tmux liveness must read the agy binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name magyk)
  [ "$got" = other ] || fail "tmux liveness must not read magyk as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: agy is an agent, fragments are not"
}

# Canned `pane process-info` bodies for the herdr fixtures. The shared
# exit-detection contract proves a registered agent at process level before
# trusting it (bin/backends/herdr.sh fm_backend_herdr_pane_process_state), so
# every registered-status fixture pairs its `agent get` body with a process
# view. The agy-shaped body names the foreground process exactly `agy`, which
# is the same identity surface the tmux liveness probe and the ancestry
# detector use - no real agy process is needed because the foreground branch
# answers before the descendant walk touches the process table.
agy_herdr_process_info_body() {  # <shell-pid> <foreground-name> -> JSON
  printf '%s\n' "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w9:p1\",\"shell_pid\":$1,\"foreground_processes\":[{\"pid\":$(( $1 + 1 )),\"name\":\"$2\",\"argv\":[\"$2\",\"--prompt-interactive\"],\"argv0\":\"$2\",\"cmdline\":\"$2 --prompt-interactive\"}]}}}"
}

agy_herdr_agent_state() {  # <fixture-dir> -> verdict; logs every CLI call
  local dir=$1
  : > "$dir/calls.log"
  AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_PROC="$dir/process-info.json" \
    AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$AGY_FIX_LOG"
      case "$*" in
        *"agent get"*) cat "$AGY_FIX_RESP" ;;
        *"pane process-info"*) cat "$AGY_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_pane_agent_state testsession w9:p1' "$ROOT" 2>&1
}

test_herdr_done_with_live_registry_stays_live() {
  local dir out
  dir="$TMP_ROOT/herdr-done"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"done","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  agy_herdr_process_info_body 424242 agy > "$dir/process-info.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered done status with an agy process view must stay live, got '$out'"
  grep -q "process-info" "$dir/calls.log" \
    || fail "the shared contract proves a registered agent at process level; the verdict trusted the registration alone"
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_PROC="$dir/process-info.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      case "$*" in
        *"agent get"*) cat "$AGY_FIX_RESP" ;;
        *"pane process-info"*) cat "$AGY_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_tab_is_husk testsession w9:p1 && printf husk || printf refused' "$ROOT" 2>&1)
  [ "$out" = refused ] || fail "a live pane must refuse husk replacement, got '$out'"
  pass "herdr exit detection: done with a live registry and an agy process view stays live and refuses replacement"
}

test_herdr_registered_status_over_a_shell_only_pane_is_stale_not_live() {
  local dir out shell_pid
  dir="$TMP_ROOT/herdr-stale"; mkdir -p "$dir"
  # The descendant walk reads the REAL process table, so the canned pane shell
  # must be a process this test owns and can prove alive: a short-lived sleep.
  sleep 30 & shell_pid=$!
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"done","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  agy_herdr_process_info_body "$shell_pid" bash > "$dir/process-info.json"
  out=$(agy_herdr_agent_state "$dir")
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = stale-agent ] || fail "a registered status over a proven shell-only pane must read stale-agent, got '$out'"
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_PROC="$dir/process-info.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      case "$*" in
        *"agent get"*) cat "$AGY_FIX_RESP" ;;
        *"pane process-info"*) cat "$AGY_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_tab_is_husk testsession w9:p1 && printf husk || printf refused' "$ROOT" 2>&1)
  [ "$out" = refused ] || fail "a stale registration must still refuse husk replacement, got '$out'"
  pass "herdr exit detection: a registered status over a shell-only pane is stale-agent and still refuses closing"
}

test_herdr_shell_first_with_live_registry_stays_live() {
  local dir out
  dir="$TMP_ROOT/herdr-idle"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"idle","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  # The pane shell is present in the process view too (shell_pid), but the
  # foreground names agy: the verified harness identity outranks shell-first
  # ranking, and the shared contract's process proof is satisfied.
  agy_herdr_process_info_body 424242 agy > "$dir/process-info.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered idle status with an agy foreground must stay live, got '$out'"
  grep -q "process-info" "$dir/calls.log" \
    || fail "the shared contract proves a registered agent at process level; the verdict trusted the registration alone"
  pass "herdr exit detection: a registered pane with an agy foreground stays live however its shell ranks"
}

test_herdr_lone_unregistered_pane_is_agent_free() {
  local dir out
  dir="$TMP_ROOT/herdr-gone"; mkdir -p "$dir"
  printf '%s\n' '{"error":{"code":"agent_not_found","message":"agent target w9:p1 not found"}}' > "$dir/agent-get.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = no-agent ] || fail "an unregistered pane must read no-agent, got '$out'"
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      case "$*" in *"agent get"*) cat "$AGY_FIX_RESP" ;; *) exit 0 ;; esac
    }
    fm_backend_herdr_tab_is_husk testsession w9:p1 && printf husk || printf refused' "$ROOT" 2>&1)
  [ "$out" = husk ] || fail "an agent-free pane must allow husk replacement, got '$out'"
  pass "herdr exit detection: only a positively unregistered pane is agent-free"
}

test_herdr_malformed_and_failed_reads_stay_unknown() {
  local dir out
  dir="$TMP_ROOT/herdr-malformed"; mkdir -p "$dir"
  printf '%s\n' '{not json at all' > "$dir/agent-get.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = unknown ] || fail "a malformed registry response must read unknown, got '$out'"
  dir="$TMP_ROOT/herdr-failed"; mkdir -p "$dir"
  printf '%s\n' '{"result":{}}' > "$dir/agent-get.json"
  export AGY_FIX_FAIL=1
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$AGY_FIX_LOG"
      case "$*" in *"agent get"*) [ "${AGY_FIX_FAIL:-0}" = 1 ] && exit 3; cat "$AGY_FIX_RESP" ;; *) exit 0 ;; esac
    }
    fm_backend_herdr_pane_agent_state testsession w9:p1' "$ROOT" 2>&1)
  unset AGY_FIX_FAIL
  [ "$out" = unknown ] || fail "a failed registry query must read unknown, got '$out'"
  pass "herdr exit detection: malformed and failed reads stay unknown"
}

make_agy_trust_case() {  # <name> -> "<case>|<proj>|<wt>|<home>"
  local name=$1 case_dir proj wt home
  case_dir="$TMP_ROOT/trust-$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  home="$case_dir/home"
  mkdir -p "$home"
  fm_git_worktree "$proj" "$wt" "wt-trust-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$home"
}

read_agy_trust_case() {
  IFS='|' read -r CASE_DIR PROJ_DIR WT_DIR HOME_DIR <<EOF
$1
EOF
}

run_agy_trust() {  # <home> <worktree> <project>
  HOME="$1" "$TRUST" "$2" "$3" 2>&1
}

test_agy_trust_registers_the_logical_and_resolved_worktree_paths() {
  local rec store out link
  rec=$(make_agy_trust_case fresh)
  read_agy_trust_case "$rec"
  store="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"model":"Gemini 3.8 Flash (High)","allowNonWorkspaceAccess":true,"trustedWorkspaces":["/home/someone/elsewhere"]}' > "$store"
  link="$CASE_DIR/wt-link"
  ln -s "$WT_DIR" "$link"
  out=$(run_agy_trust "$HOME_DIR" "$link" "$PROJ_DIR") || fail "a fresh linked worktree must be trusted: $out"
  assert_agy_trusted "$store" "$link" "the logical (symlinked) pane path agy compares against was not registered"
  assert_agy_trusted "$store" "$WT_DIR" "the resolved worktree path was not registered alongside the logical one"
  assert_agy_trusted "$store" "/home/someone/elsewhere" "registration dropped an existing trustedWorkspaces entry"
  [ "$(agy_store_value "$store" model)" = '"Gemini 3.8 Flash (High)"' ] \
    || fail "registration did not preserve an unrelated store key"
  [ "$(agy_store_value "$store" allowNonWorkspaceAccess)" = true ] \
    || fail "registration did not preserve an unrelated boolean key"
  out=$(run_agy_trust "$HOME_DIR" "$link" "$PROJ_DIR") || fail "repeat registration must succeed: $out"
  [ "$(agy_trusted_paths "$store" | grep -Fcx "$WT_DIR")" -eq 1 ] \
    || fail "repeat registration duplicated the worktree entry"
  pass "fm-agy-trust.sh: registers the logical and resolved worktree paths and preserves the store"
}

test_agy_trust_creates_a_missing_store() {
  local rec store out
  rec=$(make_agy_trust_case nostore)
  read_agy_trust_case "$rec"
  store="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  out=$(run_agy_trust "$HOME_DIR" "$WT_DIR" "$PROJ_DIR") || fail "a missing store must be created: $out"
  [ -f "$store" ] || fail "no settings store was created at $store"
  assert_agy_trusted "$store" "$WT_DIR" "the worktree was not registered in the created store"
  pass "fm-agy-trust.sh: creates agy's settings store when none exists"
}

test_agy_trust_refuses_out_of_scope_paths() {
  local rec store out rc plain before after
  rec=$(make_agy_trust_case scope)
  read_agy_trust_case "$rec"
  store="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  mkdir -p "$(dirname "$store")"
  printf '%s\n' '{"trustedWorkspaces":[]}' > "$store"
  rc=0; out=$(run_agy_trust "$HOME_DIR" "$PROJ_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "the primary checkout must be refused"
  assert_contains "$out" "primary checkout" "primary-checkout refusal lacked its reason"
  assert_agy_not_trusted "$store" "$PROJ_DIR" "a refused primary checkout was still registered"
  rc=0; out=$(run_agy_trust "$HOME_DIR" "$HOME_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "the home directory must be refused"
  assert_agy_not_trusted "$store" "$HOME_DIR" "a refused home directory was still registered"
  plain="$CASE_DIR/plain"; mkdir -p "$plain"
  rc=0; out=$(run_agy_trust "$HOME_DIR" "$plain" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a plain directory must be refused"
  assert_agy_not_trusted "$store" "$plain" "a refused plain directory was still registered"
  rc=0; out=$(run_agy_trust "$HOME_DIR" "$WT_DIR/.git" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "a path below the worktree root must be refused"
  printf '%s\n' '{not json' > "$store"
  before=$(cat "$store")
  rc=0; out=$(run_agy_trust "$HOME_DIR" "$WT_DIR" "$PROJ_DIR") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unparseable store must be refused"
  after=$(cat "$store")
  [ "$before" = "$after" ] || fail "an unparseable store was rewritten"
  pass "fm-agy-trust.sh: refuses every out-of-scope path and never rewrites a broken store"
}

# The fake tmux renders an agy-shaped screen that advances through
# launched -> (trust dialog ->) busy as the real spawn drives it, so the launch
# command, the pre-registration, the single Enter that answers a dialog, and
# the readiness gate are exercised through their real code paths. Whether the
# dialog renders is decided the way agy decides it: the pane path is looked up
# in the trustedWorkspaces array of the store the spawn just wrote.
# FM_FAKE_AGY_IGNORE_TRUST=1 models a vendor that stopped honouring the store;
# FM_FAKE_AGY_ASSUME_TRUSTED=1 models a pane that never shows the dialog even
# though firstmate could not register the path (a busy verdict with no proof
# of where the turn runs);
# FM_FAKE_AGY_RACE=1 models Herdr's native busy verdict rendering one capture
# before the dialog paints; FM_FAKE_AGY_ANSWER=stuck models a dialog whose
# answer never turns into a busy turn; FM_FAKE_AGY_NEVER_BUSY=1 models a
# pre-trusted pane that takes the launch line and then renders nothing, the
# shape a launch that died on start leaves behind.
make_agy_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_AGY_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    dialog)
      printf 'Accessing workspace:\n\n%s\n\nDo you trust the contents of this project?\n\nAntigravity CLI requires permission to read, edit, and execute files here.\n\n> Yes, I trust this folder\n  No, exit\n' "$FM_FAKE_PANE_PATH"
      ;;
    busy)
      printf 'Generating...\n└ Tip: press f to see the full diff.\n\nesc to cancel                                Gemini 3.8 Flash · low\n'
      ;;
    racing)
      printf 'esc to cancel                                Gemini 3.8 Flash · low\n'
      printf 'dialog\n' > "$FM_FAKE_AGY_STATE"
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
fake_path_trusted() {
  [ "${FM_FAKE_AGY_ASSUME_TRUSTED:-0}" = 1 ] && return 0
  [ "${FM_FAKE_AGY_IGNORE_TRUST:-0}" = 1 ] && return 1
  node -e 'const fs=require("node:fs");let j={};try{j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));}catch(e){process.exit(1);}process.exit(Array.isArray(j.trustedWorkspaces)&&j.trustedWorkspaces.includes(process.argv[2])?0:1);' \
    "$FM_FAKE_AGY_SETTINGS" "$FM_FAKE_PANE_PATH"
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
        *--prompt-interactive*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_AGY_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_AGY_NEVER_BUSY:-0}" = 1 ]; then
              :
            elif fake_path_trusted; then
              printf 'busy\n' > "$FM_FAKE_AGY_STATE"
            elif [ "${FM_FAKE_AGY_RACE:-0}" = 1 ]; then
              printf 'racing\n' > "$FM_FAKE_AGY_STATE"
            else
              printf 'dialog\n' > "$FM_FAKE_AGY_STATE"
            fi
            ;;
          dialog)
            if [ "${FM_FAKE_AGY_ANSWER:-works}" = works ]; then
              printf 'busy\n' > "$FM_FAKE_AGY_STATE"
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
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = models ]; then
  if [ "${FM_FAKE_AGY_MODELS_FAIL:-0}" = 1 ]; then exit 3; fi
  if [ "${FM_FAKE_AGY_MODELS_HANG:-0}" = 1 ]; then cat > /dev/null; sleep 30; exit 0; fi
  printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
  printf 'gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\n'
  printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n'
  exit 0
fi
echo "fake agy must never execute" >&2
exit 9
SH
  chmod +x "$fakebin/agy"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_agy_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_agy_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Antigravity dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'agy\n' > "$home/config/crew-harness"
  mkdir -p "$home/.gemini/antigravity-cli"
  printf '%s\n' '{"model":"Gemini 3.8 Flash (High)","trustedWorkspaces":["/home/someone/elsewhere"]}' \
    > "$home/.gemini/antigravity-cli/settings.json"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/agy.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_agy_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# The spawn drives the real bin/fm-agy-trust.sh and the fake tmux's trust
# lookup under this base PATH, and both read agy's settings store with node,
# which runners do not keep in the system bin dirs. Carry the directory the
# invoking environment resolves node from, the fm-kimi-harness shape.
NODE_BIN=$(command -v node) || fail "test needs node"
# Carry node WITHOUT carrying its whole directory: agy installs to ~/.local/bin,
# which is also where many runners resolve node from, so putting that directory
# on the base PATH leaks the host's real agy into cases that must see none - the
# missing-binary case then found it and the spawn correctly refused to refuse.
# A shim holding only node keeps the fixture's agy the only agy on PATH.
NODE_SHIM_DIR="$TMP_ROOT/node-shim"
mkdir -p "$NODE_SHIM_DIR"
ln -sf "$NODE_BIN" "$NODE_SHIM_DIR/node"
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

run_agy_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_AGY_STATE="$case_dir/agy.state" \
    FM_FAKE_AGY_SETTINGS="$home/.gemini/antigravity-cli/settings.json" \
    FM_FAKE_AGY_MODELS_FAIL="${FM_FAKE_AGY_MODELS_FAIL:-0}" \
    FM_FAKE_AGY_MODELS_HANG="${FM_FAKE_AGY_MODELS_HANG:-0}" \
    FM_FAKE_AGY_IGNORE_TRUST="${FM_FAKE_AGY_IGNORE_TRUST:-0}" \
    FM_FAKE_AGY_ASSUME_TRUSTED="${FM_FAKE_AGY_ASSUME_TRUSTED:-0}" \
    FM_FAKE_AGY_RACE="${FM_FAKE_AGY_RACE:-0}" \
    FM_FAKE_AGY_ANSWER="${FM_FAKE_AGY_ANSWER:-works}" \
    FM_FAKE_AGY_NEVER_BUSY="${FM_FAKE_AGY_NEVER_BUSY:-0}" \
    FM_AGY_READY_POLLS=4 FM_AGY_POLL_INTERVAL=0 FM_AGY_MODELS_TIMEOUT=${FM_AGY_MODELS_TIMEOUT:-1} \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness agy --mode no-mistakes --yolo off "$@" 2>&1
}

test_agy_launch_carries_the_brief_with_model_effort_and_autonomy() {
  local id rec out rc launch meta
  id="agy-launch-z1-$$"
  rec=$(make_agy_spawn_case launch "$id")
  read_agy_spawn_record "$rec"
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.8-flash-low --effort low)
  rc=$?
  expect_code 0 "$rc" "agy spawn with a listed model should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/agy" "agy launch did not pin the resolved absolute binary"
  assert_contains "$launch" "--prompt-interactive" "agy launch did not carry the brief via --prompt-interactive"
  assert_contains "$launch" "--model 'gemini-3.8-flash-low'" "agy launch did not carry the requested model"
  assert_contains "$launch" "--effort 'low'" "agy launch did not carry the requested effort"
  assert_contains "$launch" "--dangerously-skip-permissions" "agy launch omitted unattended autonomy"
  assert_contains "$launch" "env -u CLAUDECODE" "agy launch did not clear the inherited launcher marker"
  assert_not_contains "$launch" "__AGYBIN__" "agy launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "agy launch left its model placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "agy launch left its brief placeholder unsubstituted"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=agy' "$meta" "agy meta did not record its harness"
  assert_grep 'model=gemini-3.8-flash-low' "$meta" "agy meta did not record its model"
  assert_grep 'effort=low' "$meta" "agy meta did not record its effort"
  pass "fm-spawn: agy launch carries brief, model, effort, and autonomy with cleared markers"
}

test_agy_effort_xhigh_is_recorded_but_omitted() {
  local id rec out rc launch meta
  id="agy-xhigh-z2-$$"
  rec=$(make_agy_spawn_case xhigh "$id")
  read_agy_spawn_record "$rec"
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.8-flash-low --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "agy spawn with an unsupported effort should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--effort" "agy launch passed a known-bad effort value"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "agy meta did not retain the unsupported effort axis"
  pass "fm-spawn: agy omits xhigh from the launch but records it in task metadata"
}

test_agy_unlisted_model_refuses_before_pane_creation() {
  local id rec out rc
  id="agy-badmodel-z3-$$"
  rec=$(make_agy_spawn_case badmodel "$id")
  read_agy_spawn_record "$rec"
  rc=0
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.8-flash) || rc=$?
  [ "$rc" -ne 0 ] || fail "an unlisted agy model should refuse the spawn"
  assert_contains "$out" "not listed by 'agy models'" "unlisted model refusal lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "an unlisted model created a launch command" || true
  pass "fm-spawn: an unlisted agy model refuses before pane creation"
}

test_agy_unreachable_listing_launches_unvalidated() {
  local id rec out rc
  id="agy-nolisting-z4-$$"
  rec=$(make_agy_spawn_case nolisting "$id")
  read_agy_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_AGY_MODELS_FAIL=1 run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low) || rc=$?
  expect_code 0 "$rc" "an unreachable model listing must not block the spawn"
  [ -s "$CASE_DIR/launch.log" ] || fail "an unreachable listing produced no launch command"
  assert_contains "$out" "listing is unreachable" "an unreachable listing launched without its notice"
  pass "fm-spawn: an unreachable agy listing establishes nothing and launches"
}

test_agy_hung_listing_is_cut_off_and_launches() {
  local id rec out rc started elapsed
  id="agy-hanglisting-z8-$$"
  rec=$(make_agy_spawn_case hanglisting "$id")
  read_agy_spawn_record "$rec"
  rc=0
  started=$(date +%s)
  out=$(FM_FAKE_AGY_MODELS_HANG=1 run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "a hung model listing must not block the spawn"
  [ "$elapsed" -lt 20 ] || fail "the model probe was not cut off by its bound (took ${elapsed}s)"
  assert_contains "$out" "did not answer within 1s" "a hung listing launched without its timeout notice"
  [ -s "$CASE_DIR/launch.log" ] || fail "a hung listing produced no launch command"
  assert_contains "$(cat "$CASE_DIR/launch.log")" "--model 'gemini-3.8-flash-low'" \
    "a hung listing dropped the requested model instead of launching it unvalidated"
  pass "fm-spawn: a hung agy listing is cut off by the shared bound and launches unvalidated"
}

test_agy_zero_model_timeout_is_clamped_to_the_default_bound() {
  local id rec out rc started elapsed
  id="agy-zerobound-z14-$$"
  rec=$(make_agy_spawn_case zerobound "$id")
  read_agy_spawn_record "$rec"
  rc=0
  started=$(date +%s)
  out=$(FM_FAKE_AGY_MODELS_HANG=1 FM_AGY_MODELS_TIMEOUT=0 \
    run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 0 "$rc" "a hung listing with a zero bound must not block the spawn"
  [ "$elapsed" -lt 25 ] || fail "a zero model bound disabled the deadline (took ${elapsed}s)"
  assert_contains "$out" "did not answer within 15s" \
    "a zero model bound was not clamped to the documented default"
  [ -s "$CASE_DIR/launch.log" ] || fail "a zero model bound produced no launch command"
  pass "fm-spawn: a zero FM_AGY_MODELS_TIMEOUT is clamped to the default bound"
}

# Bare Enter key presses only: shell setup rides its Enter on the typed text
# (`send-keys -t <target> export X=Y Enter`), while the launch submit and the
# trust-dialog answer are lone key sends (`send-keys -t <target> Enter`).
count_enter_sends() {  # <tmux-call-log>
  grep -c '^send-keys -t [^ ]* Enter$' "$1" || true
}

test_agy_fresh_worktree_is_pre_trusted_and_launches_without_a_dialog() {
  local id rec out rc enters store
  id="agy-trust-z9-$$"
  rec=$(make_agy_spawn_case trust "$id")
  read_agy_spawn_record "$rec"
  store="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.8-flash-low)
  rc=$?
  expect_code 0 "$rc" "an agy spawn into a fresh worktree should succeed"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"
  assert_not_contains "$out" "could not pre-register" "a legitimate worktree failed trust pre-registration"
  assert_agy_trusted "$store" "$WT_DIR" "the spawn did not pre-register the worktree in agy's trust store"
  assert_agy_trusted "$store" "/home/someone/elsewhere" "the spawn dropped an existing trustedWorkspaces entry"
  [ "$(agy_store_value "$store" model)" = '"Gemini 3.8 Flash (High)"' ] \
    || fail "the spawn did not preserve an unrelated agy setting"
  [ "$(cat "$CASE_DIR/agy.state")" = busy ] \
    || fail "the spawn reported success before the pane reached a busy turn (state: $(cat "$CASE_DIR/agy.state"))"
  enters=$(count_enter_sends "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 1 ] \
    || fail "a pre-trusted worktree must receive only the launch Enter, got $enters Enter sends"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful agy spawn must never tear down the endpoint it just launched"
  pass "fm-spawn: agy pre-registers the worktree and launches straight into a busy turn"
}

test_agy_dialog_despite_registration_is_answered_once() {
  local id rec out rc enters
  id="agy-vendor-z10-$$"
  rec=$(make_agy_spawn_case vendor-dialog "$id")
  read_agy_spawn_record "$rec"
  out=$(FM_FAKE_AGY_IGNORE_TRUST=1 run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low)
  rc=$?
  expect_code 0 "$rc" "an agy spawn whose dialog renders despite registration should succeed"
  [ "$(cat "$CASE_DIR/agy.state")" = busy ] \
    || fail "the spawn reported success before the pane reached a busy turn (state: $(cat "$CASE_DIR/agy.state"))"
  enters=$(count_enter_sends "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 2 ] \
    || fail "expected exactly one launch Enter plus one trust-dialog Enter, got $enters Enter sends"
  pass "fm-spawn: agy answers a dialog that renders anyway exactly once, then confirms busy"
}

test_agy_unregistered_path_ignores_busy_until_the_dialog_is_answered() {
  local id rec out rc enters store before after
  id="agy-race-z11-$$"
  rec=$(make_agy_spawn_case race "$id")
  read_agy_spawn_record "$rec"
  store="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  printf '%s\n' '{not json' > "$store"
  before=$(cat "$store")
  out=$(FM_FAKE_AGY_RACE=1 run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low)
  rc=$?
  expect_code 0 "$rc" "an agy spawn that meets the dialog after a premature busy verdict should still succeed"
  assert_contains "$out" "could not pre-register agy workspace trust" \
    "a broken store did not surface the registration warning"
  after=$(cat "$store")
  [ "$before" = "$after" ] || fail "the spawn rewrote an unparseable agy store"
  [ "$(cat "$CASE_DIR/agy.state")" = busy ] \
    || fail "the spawn reported success before the answered dialog turned busy (state: $(cat "$CASE_DIR/agy.state"))"
  enters=$(count_enter_sends "$CASE_DIR/tmux-calls.log")
  [ "$enters" -eq 2 ] \
    || fail "a busy verdict before the dialog must not count as ready on an unregistered path; expected the dialog Enter, got $enters Enter sends"
  pass "fm-spawn: on an unregistered path a premature busy verdict waits for the dialog to be answered"
}

test_agy_unregistered_path_without_a_dialog_fails_the_spawn() {
  local id rec out rc store
  id="agy-nodialog-z12-$$"
  rec=$(make_agy_spawn_case nodialog "$id")
  read_agy_spawn_record "$rec"
  store="$HOME_DIR/.gemini/antigravity-cli/settings.json"
  printf '%s\n' '{not json' > "$store"
  rc=0
  out=$(FM_FAKE_AGY_ASSUME_TRUSTED=1 run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low) || rc=$?
  [ "$rc" -ne 0 ] || fail "a busy verdict on an unregistered path with no dialog must not pass the gate"
  assert_contains "$out" "never showed its folder-trust dialog on an unregistered worktree" \
    "the failure did not name the unconfirmed workspace"
  assert_not_contains "$out" "spawned $id" "an unconfirmed workspace still reported a successful spawn"
  [ "$(count_enter_sends "$CASE_DIR/tmux-calls.log")" -eq 1 ] \
    || fail "the gate must not send Enter into a pane that shows no dialog"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed agy readiness gate left its launched endpoint running"
  assert_grep 'failed: agy never showed its folder-trust dialog' "$HOME_DIR/state/$id.status" \
    "a failed agy readiness gate did not record the failure in the task status"
  pass "fm-spawn: a busy verdict on an unregistered path without a dialog fails and closes the endpoint"
}

test_agy_pre_trusted_path_that_never_turns_busy_fails_the_spawn() {
  local id rec out rc
  id="agy-idle-z13-$$"
  rec=$(make_agy_spawn_case idle "$id")
  read_agy_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_AGY_IGNORE_TRUST=1 FM_FAKE_AGY_ANSWER=stuck run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low) || rc=$?
  [ "$rc" -ne 0 ] || fail "a dialog that never turns into a busy turn must fail the spawn"
  assert_contains "$out" "did not start processing its brief after the folder-trust dialog was answered" \
    "a stuck trust dialog failed without its concrete reason"
  [ "$(count_enter_sends "$CASE_DIR/tmux-calls.log")" -eq 2 ] \
    || fail "the gate must answer the dialog exactly once and never hammer Enter"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed agy readiness gate left its launched endpoint running"
  pass "fm-spawn: an agy dialog that never turns busy fails the spawn and closes the endpoint"
}

test_agy_missing_binary_refuses_before_pane_creation() {
  local id rec out rc
  id="agy-missing-z5-$$"
  rec=$(make_agy_spawn_case missing "$id")
  read_agy_spawn_record "$rec"
  rm "$FAKEBIN_DIR/agy"
  rc=0
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing agy executable should refuse the spawn"
  assert_contains "$out" "agy executable not found on PATH" "missing agy diagnostic lacked its concrete reason"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing agy executable created a launch command" || true
  pass "fm-spawn: a missing agy executable refuses before pane creation"
}

test_agy_secondmate_is_refused() {
  local id rec out rc
  id="agy-secondmate-z6-$$"
  rec=$(make_agy_spawn_case secondmate-refuse "$id")
  read_agy_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate agy 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an agy secondmate spawn should be refused"
  assert_contains "$out" "agy is a verified crewmate/scout adapter only" \
    "agy secondmate refusal lacked its concrete reason"
  pass "fm-spawn: agy cannot be launched as a secondmate"
}

# A raw launch mints no token, so its hook firing could never resolve one. The
# global store is shared with the captain's own agy sessions and the Antigravity
# IDE, so writing the key there would only add two synchronous subprocesses to
# every one of their turns for a task that can never use them.
test_agy_raw_launch_installs_no_global_hook() {
  local id rec out rc
  id="agy-rawlaunch-z16-$$"
  rec=$(make_agy_spawn_case rawlaunch "$id")
  read_agy_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" \
    FM_FAKE_AGY_STATE="$CASE_DIR/agy.state" \
    FM_FAKE_AGY_SETTINGS="$HOME_DIR/.gemini/antigravity-cli/settings.json" \
    FM_AGY_READY_POLLS=4 FM_AGY_POLL_INTERVAL=0 \
    PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "agy --prompt-interactive hi" --mode no-mistakes --yolo off 2>&1) || rc=$?
  expect_code 0 "$rc" "a raw agy launch should spawn"
  assert_contains "$out" "spawned $id harness=agy" "the raw agy launch did not report its harness"
  [ ! -e "$HOME_DIR/.gemini/config/hooks.json" ] \
    || fail "a raw agy launch wrote firstmate's key into the shared global hooks store"
  assert_agy_home_untouched "$HOME_DIR" "raw launch"
  [ ! -e "$HOME_DIR/state/$id.busy-gen" ] \
    || fail "a raw agy launch armed a busy generation no hook could ever clear"
  [ ! -e "$HOME_DIR/state/$id.agy-turnend-token" ] \
    || fail "a raw agy launch minted a turn-end token no hook could ever read"
  pass "fm-spawn: a raw agy launch installs no global hook and arms no wiring"
}

test_agy_spawn_arms_the_turnend_wiring() {
  local id rec out rc statedir token auth launch
  id="agy-wiring-z7-$$"
  rec=$(make_agy_spawn_case wiring "$id")
  read_agy_spawn_record "$rec"
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.8-flash-low)
  rc=$?
  expect_code 0 "$rc" "agy spawn should succeed"
  statedir="$HOME_DIR/state"
  [ -s "$statedir/$id.busy-gen" ] || fail "agy spawn did not arm a busy generation for its hook to clear"
  [ -s "$statedir/$id.agy-turnend-token" ] || fail "agy spawn did not record its turn-end token sidecar"
  IFS= read -r token <"$statedir/$id.agy-turnend-token"
  case "$token" in
  fm.????????????) ;;
  *) fail "agy turn-end token '$token' is not a registry-minted name" ;;
  esac
  auth="$HOME_DIR/.gemini/antigravity-cli/fm-turn-end.d/$token"
  [ -f "$auth" ] || fail "agy spawn did not mint its private turn-end registry entry"
  assert_grep "gen=" "$auth" "the agy turn-end token carries no busy generation"
  assert_grep "id=$id" "$auth" "the agy turn-end token names the wrong task"
  assert_grep "turnend=" "$auth" "the agy turn-end token carries no turn-end marker path"
  assert_grep "busy_event=" "$auth" "the agy turn-end token carries no busy-state writer path"
  # The whole point of the env route: nothing is written into the project.
  for stray in "$WT_DIR"/.fm-agy*; do
    [ -e "$stray" ] || continue
    fail "agy spawn wrote a pointer into the worktree: $stray"
  done
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "FM_TASK_ID=" \
    "the inline launch prefix must carry only the token the allowlist cannot pass; FM_TASK_ID already reaches the pane through the launch environment"
  assert_contains "$launch" "FM_AGY_TURNEND_TOKEN='$token'" "agy launch did not export its turn-end token"
  assert_not_contains "$launch" "__AGYTOKEN__" "agy launch left its token placeholder unsubstituted"
  pass "fm-spawn: agy arms busy wiring and exports its token without touching the worktree"
}

# The installed hook is global and shared with the captain's own agy sessions
# and the Antigravity IDE, so these cases pin the two properties that keep that
# safe: it edits only its own key, and it is inert without a registry-backed
# token. They exercise the real installer and the real generated hook script.
agy_turnend_install() {  # <home>
  HOME="$1" "$ROOT/bin/fm-agy-turnend-hook.sh" install
}

# hooks.json is agy's own machine-read configuration, so these assertions parse
# it and check the meaning agy acts on - which handler runs which command, under
# which timeout - rather than matching text that could sit anywhere in the file.
agy_registered_command() {  # <store> <event>
  node -e 'const fs=require("node:fs");const r=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const h=r["firstmate-turn-end"];if(!h||!h[process.argv[2]])process.exit(1);process.stdout.write(h[process.argv[2]][0].command);' \
    "$1" "$2"
}

assert_agy_hooks_store() {  # <store> <expect: installed|removed> <detail>
  node - "$1" "$2" <<'NODE' || fail "$3"
const fs = require("node:fs");
const path = require("node:path");
const [store, expect] = process.argv.slice(2);
const root = JSON.parse(fs.readFileSync(store, "utf8"));
const bad = (m) => { console.error(m); process.exit(1); };
const hook = path.join(path.dirname(path.dirname(store)), "antigravity-cli", "fm-turn-end.sh");
if (root === null || typeof root !== "object" || Array.isArray(root)) bad("root is not an object");
const foreign = root["someone-elses-hook"];
if (!foreign || foreign.Stop[0].command !== "echo hi") bad("the foreign hook key did not survive intact");
const own = root["firstmate-turn-end"];
if (expect === "removed") {
  if (Object.prototype.hasOwnProperty.call(root, "firstmate-turn-end")) bad("the firstmate key is still present");
  process.exit(0);
}
if (!own) bad("the firstmate key is absent");
if (Object.keys(root).length !== 2) bad(`expected exactly 2 hook keys, found ${Object.keys(root).length}`);
for (const [event, arg] of [["PreInvocation", "pre-invocation"], ["Stop", "stop"]]) {
  const handlers = own[event];
  if (!Array.isArray(handlers) || handlers.length !== 1) bad(`${event} is not a single handler`);
  const h = handlers[0];
  if (h.type !== "command") bad(`${event} is not a command handler`);
  const want = `'${hook}' ${arg}`;
  if (h.command !== want) bad(`${event} runs ${JSON.stringify(h.command)}, not ${JSON.stringify(want)}`);
  if (h.timeout !== 5) bad(`${event} carries timeout ${h.timeout}, not the bounded 5`);
}
NODE
}

# The spawn seeds this task's own busy record before the launch line is typed,
# so the readiness gate must not answer from the semantic classifier: doing so
# reports a launch that never started as ready. Here the pane is pre-trusted
# (no dialog) and takes the launch line but never renders a turn, which is the
# exact shape a dead launch leaves, and the gate must refuse it.
test_agy_pre_trusted_pane_that_never_renders_a_turn_fails_the_spawn() {
  local id rec out rc
  id="agy-deadlaunch-z14-$$"
  rec=$(make_agy_spawn_case deadlaunch "$id")
  read_agy_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_AGY_NEVER_BUSY=1 run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" \
    "$FAKEBIN_DIR" "$id" --model gemini-3.8-flash-low) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pre-trusted pane that never renders a turn must fail the readiness gate, not pass on the spawn's own seeded busy record"
  assert_contains "$out" "did not start processing its brief in the pre-trusted worktree" \
    "the failure did not name the unproven pre-trusted launch"
  assert_not_contains "$out" "spawned $id" "a launch that never started still reported a successful spawn"
  assert_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a failed agy readiness gate left its launched endpoint running"
  pass "fm-spawn: a pre-trusted agy pane that never renders a turn fails the gate"
}

# A hooks.json firstmate does not own is the dotfiles-managed shape. The
# installer refuses it without a write, and the spawn must degrade to the
# unwired shape rather than die: no busy arm, no token, the rendered-tail read
# alone - and it must say so, because the supervisor cannot see it otherwise.
test_agy_refused_hook_install_degrades_the_spawn_visibly() {
  local id rec out rc launch
  id="agy-unwired-z15-$$"
  rec=$(make_agy_spawn_case unwired "$id")
  read_agy_spawn_record "$rec"
  mkdir -p "$HOME_DIR/.gemini/config" "$HOME_DIR/elsewhere"
  printf '%s\n' '{}' >"$HOME_DIR/elsewhere/hooks.json"
  ln -s "$HOME_DIR/elsewhere/hooks.json" "$HOME_DIR/.gemini/config/hooks.json"
  rc=0
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.8-flash-low) || rc=$?
  expect_code 0 "$rc" "a refused turn-end hook install must not kill the agy spawn"
  assert_contains "$out" "spawned $id" "the degraded agy spawn did not report success"
  assert_contains "$out" "is a symlink" "the degradation did not carry the installer's own refusal reason"
  assert_contains "$out" "rendered-tail idle read" \
    "the spawn did not tell the supervisor this worker runs on the weaker detection"
  # The installer must not have written through the symlink.
  assert_contains "$(cat "$HOME_DIR/elsewhere/hooks.json")" "{}" \
    "the refused installer wrote through the symlink it refused"
  [ -e "$HOME_DIR/state/$id.busy-gen" ] \
    && fail "an unwired agy spawn armed a busy generation no hook could ever clear" || true
  [ -e "$HOME_DIR/state/$id.agy-turnend-token" ] \
    && fail "an unwired agy spawn minted a turn-end token no hook could ever read" || true
  assert_agy_home_untouched "$HOME_DIR" "refused install on the spawn path"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "FM_AGY_TURNEND_TOKEN" "an unwired agy launch still exported a turn-end token"
  assert_not_contains "$launch" "__AGYTOKEN__" "an unwired agy launch left its token placeholder unsubstituted"
  pass "fm-spawn: a refused agy hook install degrades the spawn visibly instead of killing it"
}

test_agy_turnend_installer_owns_only_its_own_key() {
  local home store
  home="$TMP_ROOT/turnend-install"
  rm -rf "$home"
  mkdir -p "$home/.gemini/config"
  store="$home/.gemini/config/hooks.json"
  printf '%s\n' '{"someone-elses-hook":{"Stop":[{"type":"command","command":"echo hi"}]}}' >"$store"
  agy_turnend_install "$home" || fail "the agy turn-end installer refused a clean store"
  assert_agy_hooks_store "$store" installed "the installed hooks.json does not register the bounded firstmate handlers beside the foreign key"
  [ -x "$home/.gemini/antigravity-cli/fm-turn-end.sh" ] || fail "the installer did not install an executable hook script"
  # Installing twice must converge rather than duplicate.
  agy_turnend_install "$home" || fail "the agy turn-end installer is not idempotent"
  assert_agy_hooks_store "$store" installed "installing twice did not converge on one bounded firstmate entry"
  HOME="$home" "$ROOT/bin/fm-agy-turnend-hook.sh" remove || fail "the agy turn-end installer could not remove its key"
  assert_agy_hooks_store "$store" removed "remove did not leave the store with the foreign key alone"
  pass "fm-agy-turnend-hook.sh: owns only its own key and installs idempotently"
}

# The header's contract is that each refusal happens WITHOUT a write, so every
# refusal below also asserts the home is exactly as the installer found it: no
# hook script and no registry directory left for the next spawn to rewrite.
assert_agy_home_untouched() {  # <home> <detail>
  [ ! -e "$1/.gemini/antigravity-cli/fm-turn-end.sh" ] \
    || fail "$2: a refused install left its hook script behind"
  [ ! -e "$1/.gemini/antigravity-cli/fm-turn-end.d" ] \
    || fail "$2: a refused install left its token registry behind"
}

test_agy_turnend_installer_refuses_a_store_it_does_not_own() {
  local home store rc before after
  home="$TMP_ROOT/turnend-refuse"
  rm -rf "$home"
  mkdir -p "$home/.gemini/config"
  store="$home/.gemini/config/hooks.json"
  printf '%s\n' '["not","an","object"]' >"$store"
  before=$(cat "$store")
  rc=0
  agy_turnend_install "$home" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the installer accepted a non-object hooks.json root"
  after=$(cat "$store")
  [ "$before" = "$after" ] || fail "the installer rewrote a store it should have refused"
  assert_agy_home_untouched "$home" "non-object root"
  printf '%s\n' '{}' >"$TMP_ROOT/turnend-refuse-target.json"
  rm -f "$store"
  ln -s "$TMP_ROOT/turnend-refuse-target.json" "$store"
  rc=0
  agy_turnend_install "$home" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the installer followed a symlinked hooks.json"
  assert_agy_home_untouched "$home" "symlinked store"
  pass "fm-agy-turnend-hook.sh: refuses a non-object root and a symlinked store without writing"
}

# The ownership guards refuse before any write, but the store edit itself can
# still fail once they pass - a config directory this uid cannot write is the
# reachable shape, because the writability guard only runs when the store
# already exists. That refusal must leave the home as it found it too.
test_agy_turnend_installer_leaves_nothing_behind_when_the_store_edit_fails() {
  local home rc
  if [ "$(id -u)" = 0 ]; then
    pass "fm-agy-turnend-hook.sh: a failed store edit leaves nothing behind (skipped as root)"
    return 0
  fi
  home="$TMP_ROOT/turnend-edit-fails"
  rm -rf "$home"
  mkdir -p "$home/.gemini/config"
  chmod 500 "$home/.gemini/config"
  rc=0
  agy_turnend_install "$home" >/dev/null 2>&1 || rc=$?
  chmod 700 "$home/.gemini/config"
  [ "$rc" -ne 0 ] || fail "the installer reported success against a hooks.json directory it cannot write"
  [ ! -e "$home/.gemini/config/hooks.json" ] || fail "a refused store edit still left a store behind"
  assert_agy_home_untouched "$home" "failed store edit"
  pass "fm-agy-turnend-hook.sh: a failed store edit leaves no hook script or registry behind"
}

# agy runs a hook `command` through `sh -c`, so the registered string is the
# real interface, not the script path. This runs the string the installer wrote
# exactly as agy would, from a home whose path contains a space: an unquoted
# path resolves to a nonexistent binary and the record silently never moves.
test_agy_turnend_command_fires_from_a_home_whose_path_has_a_space() {
  local home store statedir gen token auth cmd record
  home="$TMP_ROOT/turnend space home"
  rm -rf "$home"
  mkdir -p "$home/.gemini/config"
  agy_turnend_install "$home" >/dev/null || fail "the installer refused a home whose path contains a space"
  store="$home/.gemini/config/hooks.json"
  statedir="$TMP_ROOT/turnend-space-state"
  rm -rf "$statedir"
  mkdir -p "$statedir"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$statedir" t1) || fail "could not arm a busy generation"
  token="fm.bbbbbbbbbbbb"
  auth="$home/.gemini/antigravity-cli/fm-turn-end.d/$token"
  {
    printf 'turnend=%s\n' "$statedir/t1.turn-ended"
    printf 'busy_event=%s\n' "$ROOT/bin/fm-busy-event.sh"
    printf 'state=%s\n' "$statedir"
    printf 'id=%s\n' t1
    printf 'gen=%s\n' "$gen"
  } >"$auth"

  cmd=$(agy_registered_command "$store" Stop) || fail "could not read the registered Stop command"
  printf '{}' | FM_AGY_TURNEND_TOKEN="$token" sh -c "$cmd" >/dev/null \
    || fail "agy's registered Stop command exited non-zero"
  record=$(cat "$statedir/t1.busy-state")
  assert_contains "$record" "state=idle" \
    "the registered Stop command did not close the turn from a home whose path contains a space"
  [ -f "$statedir/t1.turn-ended" ] \
    || fail "the registered Stop command did not touch the watcher's turn-end marker"

  cmd=$(agy_registered_command "$store" PreInvocation) || fail "could not read the registered PreInvocation command"
  printf '{}' | FM_AGY_TURNEND_TOKEN="$token" sh -c "$cmd" >/dev/null \
    || fail "agy's registered PreInvocation command exited non-zero"
  assert_contains "$(cat "$statedir/t1.busy-state")" "state=busy" \
    "the registered PreInvocation command did not open the turn"
  pass "fm-agy-turnend-hook.sh: the registered command fires through sh -c from a spaced home"
}

test_agy_turnend_hook_is_inert_without_a_registry_token() {
  local home hook out rc bad
  home="$TMP_ROOT/turnend-inert"
  rm -rf "$home"
  mkdir -p "$home/.gemini/config"
  agy_turnend_install "$home" >/dev/null || fail "installer setup failed"
  hook="$home/.gemini/antigravity-cli/fm-turn-end.sh"
  rc=0
  out=$(printf '{}' | "$hook" stop) || rc=$?
  expect_code 0 "$rc" "the agy hook must exit 0 with no token"
  [ "$out" = '{"decision":"stop"}' ] || fail "the agy hook did not answer Stop with agy's required JSON: $out"
  rc=0
  out=$(printf '{}' | "$hook" pre-invocation) || rc=$?
  expect_code 0 "$rc" "the agy hook must exit 0 on PreInvocation with no token"
  [ "$out" = '{}' ] || fail "the agy hook did not answer PreInvocation with an empty JSON object: $out"
  # A forged token must never resolve outside the registry directory.
  for bad in "../escape" "/etc/passwd" "fm.short" "fm.WAYTOOLONGTOKEN" "fm.abc/../def"; do
    rc=0
    out=$(printf '{}' | FM_AGY_TURNEND_TOKEN="$bad" "$hook" stop) || rc=$?
    expect_code 0 "$rc" "the agy hook must exit 0 for forged token '$bad'"
    [ "$out" = '{"decision":"stop"}' ] || fail "forged token '$bad' changed the agy hook's answer: $out"
  done
  pass "fm-agy-turnend-hook.sh: the installed hook is inert without a registry-backed token"
}

test_agy_turnend_hook_records_both_turn_boundaries() {
  local home hook reg statedir gen token auth record
  home="$TMP_ROOT/turnend-record"
  rm -rf "$home"
  mkdir -p "$home/.gemini/config"
  agy_turnend_install "$home" >/dev/null || fail "installer setup failed"
  hook="$home/.gemini/antigravity-cli/fm-turn-end.sh"
  reg="$home/.gemini/antigravity-cli/fm-turn-end.d"
  statedir="$TMP_ROOT/turnend-record-state"
  rm -rf "$statedir"
  mkdir -p "$statedir"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$statedir" t1) || fail "could not arm a busy generation"
  token="fm.aaaaaaaaaaaa"
  auth="$reg/$token"
  {
    printf 'turnend=%s\n' "$statedir/t1.turn-ended"
    printf 'busy_event=%s\n' "$ROOT/bin/fm-busy-event.sh"
    printf 'state=%s\n' "$statedir"
    printf 'id=%s\n' t1
    printf 'gen=%s\n' "$gen"
  } >"$auth"

  printf '{}' | FM_AGY_TURNEND_TOKEN="$token" "$hook" stop >/dev/null || fail "the agy Stop hook exited non-zero"
  record=$(cat "$statedir/t1.busy-state")
  assert_contains "$record" "state=idle" "agy's Stop hook did not close the turn"
  assert_contains "$record" "source=agy-hook" "agy's Stop hook did not record its own source"
  [ -f "$statedir/t1.turn-ended" ] || fail "agy's Stop hook did not touch the watcher's turn-end marker"

  printf '{}' | FM_AGY_TURNEND_TOKEN="$token" "$hook" pre-invocation >/dev/null || fail "the agy PreInvocation hook exited non-zero"
  record=$(cat "$statedir/t1.busy-state")
  assert_contains "$record" "state=busy" "agy's PreInvocation hook did not open the turn"
  assert_contains "$record" "source=agy-hook" "agy's PreInvocation hook did not record its own source"

  # A superseded incarnation must fail closed rather than rewrite the record.
  printf 'turnend=%s\nbusy_event=%s\nstate=%s\nid=%s\ngen=%s\n' \
    "$statedir/t1.turn-ended" "$ROOT/bin/fm-busy-event.sh" "$statedir" t1 "g-stale" >"$auth"
  printf '{}' | FM_AGY_TURNEND_TOKEN="$token" "$hook" stop >/dev/null || fail "the agy hook exited non-zero on a stale generation"
  assert_contains "$(cat "$statedir/t1.busy-state")" "state=busy" \
    "a stale generation was allowed to rewrite the agy busy record"

  # The token name is validated before the registry is read, but the values
  # inside a token are data too. fm-spawn only ever writes absolute paths.
  printf 'turnend=%s\nbusy_event=%s\nstate=%s\nid=%s\ngen=%s\n' \
    "relative/turn-ended" "relative/fm-busy-event.sh" "relative/state" t1 "$gen" >"$auth"
  printf '{}' | FM_AGY_TURNEND_TOKEN="$token" "$hook" stop >/dev/null \
    || fail "the agy hook exited non-zero on a relative-path token"
  assert_contains "$(cat "$statedir/t1.busy-state")" "state=busy" \
    "a relative-path token was allowed to rewrite the agy busy record"
  pass "fm-agy-turnend-hook.sh: PreInvocation opens and Stop closes, and a stale generation or relative path is refused"
}

test_agy_ancestry_detects_the_native_command_name
test_agy_ancestry_rejects_unrelated_mentions
test_agy_claims_no_inherited_launcher_marker
test_agy_control_mechanics_are_the_verified_ones
test_agy_turnend_registry_paths_are_scoped_to_agy
test_agy_busy_tail_needs_the_pinned_status_row
test_agy_busy_signatures_are_harness_scoped
test_agy_classify_reports_unknown_when_the_marker_scrolls_out
test_agy_tmux_names_the_native_binary_an_agent
test_herdr_done_with_live_registry_stays_live
test_herdr_registered_status_over_a_shell_only_pane_is_stale_not_live
test_herdr_shell_first_with_live_registry_stays_live
test_herdr_lone_unregistered_pane_is_agent_free
test_herdr_malformed_and_failed_reads_stay_unknown
test_agy_launch_carries_the_brief_with_model_effort_and_autonomy
test_agy_effort_xhigh_is_recorded_but_omitted
test_agy_unlisted_model_refuses_before_pane_creation
test_agy_unreachable_listing_launches_unvalidated
test_agy_hung_listing_is_cut_off_and_launches
test_agy_zero_model_timeout_is_clamped_to_the_default_bound
test_agy_trust_registers_the_logical_and_resolved_worktree_paths
test_agy_trust_creates_a_missing_store
test_agy_trust_refuses_out_of_scope_paths
test_agy_fresh_worktree_is_pre_trusted_and_launches_without_a_dialog
test_agy_dialog_despite_registration_is_answered_once
test_agy_unregistered_path_ignores_busy_until_the_dialog_is_answered
test_agy_unregistered_path_without_a_dialog_fails_the_spawn
test_agy_pre_trusted_path_that_never_turns_busy_fails_the_spawn
test_agy_missing_binary_refuses_before_pane_creation
test_agy_secondmate_is_refused
test_agy_spawn_arms_the_turnend_wiring
test_agy_raw_launch_installs_no_global_hook
test_agy_pre_trusted_pane_that_never_renders_a_turn_fails_the_spawn
test_agy_refused_hook_install_degrades_the_spawn_visibly
test_agy_turnend_installer_owns_only_its_own_key
test_agy_turnend_installer_refuses_a_store_it_does_not_own
test_agy_turnend_installer_leaves_nothing_behind_when_the_store_edit_fails
test_agy_turnend_command_fires_from_a_home_whose_path_has_a_space
test_agy_turnend_hook_is_inert_without_a_registry_token
test_agy_turnend_hook_records_both_turn_boundaries
