#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI crewmate/scout adapter.
#
# The facts pinned here are the ones an agy release could silently change and
# the ones a wrong guess would make dangerous:
#   1. agy publishes no harness-identity marker of its own (a live 1.2.0 TUI
#      carries no AGY_* variable; AGENT=1 there is inherited launcher state),
#      so detection is ancestry alone on the anchored process name `agy`.
#   2. The anchored match must never claim unrelated commands containing the
#      fragment, and an inherited CLAUDECODE still outranks ancestry until the
#      spawn clears it - the clearing is load-bearing, not cosmetic.
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
#   5. agy is a crewmate/scout adapter only: a secondmate launch is refused,
#      and nothing is armed as busy wiring because no writer could clear it.
#   6. The busy signature is the pinned `esc to cancel` status row alone; the
#      free-floating `Generating...` word must never read busy on its own.
#   7. Herdr's registry already tracks agy, so exit detection stays
#      registry-driven: a registered status (even done) is live, and no
#      process-name shortcut may flip it to agent-free.
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
  local out
  # AGENT=1 was observed on a live agy TUI as inherited launcher state, so it
  # must never promote to an agy identity the way GEMINI_CLI does for gemini.
  out=$(AGENT=1 "$HARNESS")
  [ "$out" != agy ] \
    || fail "an inherited AGENT=1 must never claim the agy identity, got '$out'"
  # Drive the hazard the other way: agy does not clear an inherited CLAUDECODE,
  # so the marker still wins over a real agy ancestor until the spawn clears it
  # at the launch boundary. Pin both halves so neither can rot silently.
  out=$(CLAUDECODE=1 FAKE_PS_COMM=agy FAKE_PS_ARGS='agy --prompt-interactive hi' \
    PATH="$(fm_fakebin "$TMP_ROOT/anc-claude"):$PATH" "$HARNESS")
  [ "$out" = claude ] \
    || fail "an inherited CLAUDECODE must still outrank agy ancestry, got '$out'"
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
  pass "fm-control-lib: agy mechanics are Escape once, no clear key, and /quit"
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

agy_herdr_agent_state() {  # <fixture-dir> -> verdict; logs every CLI call
  local dir=$1
  : > "$dir/calls.log"
  AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$AGY_FIX_LOG"
      case "$*" in *"agent get"*) cat "$AGY_FIX_RESP" ;; *) exit 0 ;; esac
    }
    fm_backend_herdr_pane_agent_state testsession w9:p1' "$ROOT" 2>&1
}

test_herdr_done_with_live_registry_stays_live() {
  local dir out
  dir="$TMP_ROOT/herdr-done"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"done","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered done status must stay live, got '$out'"
  grep -q "process-info" "$dir/calls.log" \
    && fail "the registry verdict consulted process state" || true
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      case "$*" in *"agent get"*) cat "$AGY_FIX_RESP" ;; *) exit 0 ;; esac
    }
    fm_backend_herdr_tab_is_husk testsession w9:p1 && printf husk || printf refused' "$ROOT" 2>&1)
  [ "$out" = refused ] || fail "a live pane must refuse husk replacement, got '$out'"
  pass "herdr exit detection: done with a live registry stays live and refuses replacement"
}

test_herdr_shell_first_with_live_registry_stays_live() {
  local dir out
  dir="$TMP_ROOT/herdr-idle"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"idle","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered idle status must stay live, got '$out'"
  grep -q "process-info" "$dir/calls.log" \
    && fail "the registry verdict consulted process state" || true
  pass "herdr exit detection: a registered pane stays live however its shell ranks"
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
# answer never turns into a busy turn.
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
            if fake_path_trusted; then
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

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

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
    FM_AGY_READY_POLLS=4 FM_AGY_POLL_INTERVAL=0 FM_AGY_MODELS_TIMEOUT=1 \
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

test_agy_spawn_arms_no_busy_wiring() {
  local id rec out rc statedir
  id="agy-nowiring-z7-$$"
  rec=$(make_agy_spawn_case nowiring "$id")
  read_agy_spawn_record "$rec"
  out=$(run_agy_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gemini-3.8-flash-low)
  rc=$?
  expect_code 0 "$rc" "agy spawn should succeed"
  statedir="$HOME_DIR/state"
  [ -e "$statedir/$id.busy-gen" ] && fail "agy spawn armed a busy generation nothing could clear" || true
  for sidecar in "$statedir/$id.agy-"*; do
    [ -e "$sidecar" ] || continue
    fail "agy spawn left an adapter sidecar behind: $sidecar"
  done
  pass "fm-spawn: agy arms no busy wiring and writes no sidecar"
}

test_agy_ancestry_detects_the_native_command_name
test_agy_ancestry_rejects_unrelated_mentions
test_agy_claims_no_inherited_launcher_marker
test_agy_control_mechanics_are_the_verified_ones
test_agy_busy_tail_needs_the_pinned_status_row
test_agy_busy_signatures_are_harness_scoped
test_agy_classify_reports_unknown_when_the_marker_scrolls_out
test_agy_tmux_names_the_native_binary_an_agent
test_herdr_done_with_live_registry_stays_live
test_herdr_shell_first_with_live_registry_stays_live
test_herdr_lone_unregistered_pane_is_agent_free
test_herdr_malformed_and_failed_reads_stay_unknown
test_agy_launch_carries_the_brief_with_model_effort_and_autonomy
test_agy_effort_xhigh_is_recorded_but_omitted
test_agy_unlisted_model_refuses_before_pane_creation
test_agy_unreachable_listing_launches_unvalidated
test_agy_hung_listing_is_cut_off_and_launches
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
test_agy_spawn_arms_no_busy_wiring
