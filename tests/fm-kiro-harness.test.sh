#!/usr/bin/env bash
# Behavior tests for the verified kiro-cli adapter across every kind.
#
# The facts pinned here are the ones a kiro-cli release could silently change and
# the ones a wrong guess would make dangerous:
#   1. kiro-cli publishes no harness-identity marker (the KIRO_* env family is
#      inheritable environment state, not identity), so detection is ancestry
#      alone on the anchored process names `kiro-cli` and the inner
#      `kiro-cli-chat`. The anchored match must never claim unrelated commands
#      (kiroshi, a bare bun), and a structural kiro-cli ancestor must outrank a
#      retained or inherited CLAUDECODE.
#   2. Control: interrupt is a single Escape (a single Ctrl+C does NOT quit the
#      new TUI), no clear key, no cancellation ack source, exit is /quit.
#  3. Kind coverage: kiro-cli runs ships, scouts, AND secondmates, because it
#      carries a verified primary supervision protocol
#      (docs/supervision-protocols/kiro-cli.md).
#   4. The launch is the INTERACTIVE steerable TUI carrying the brief via a
#      firstmate-encoded positional query with the trust flag (`-a` on V3,
#      `--trust-all-tools` on the explicit V2 fallback), --agent
#      firstmate-kiro, and per-task KIRO_HOME/KIRO_DATA_DIR/KIRO_CHAT_LOG_FILE,
#      with foreign markers cleared and the worktree isolated; it is NOT
#      --no-interactive and it does NOT type a pointer into the composer.
#      The agent file's tool list alone is not trust: a V3 agent declaring it
#      still stops on fs_write's Replace in File with a human approval prompt.
#   5. The turn-end signal is the TRACKED, firstmate-owned adapter
#      (bin/fm-kiro-turnend-hook.sh), never editing a captain-shared file.
#      Every Firstmate-owned hook command reaches it from any folder without
#      launcher environment, so a session resumed with plain kiro-cli keeps its
#      hooks. Its turn-ended touch fires only through a matching isolated-home
#      pointer plus registry token, a resumed worker writes busy state only
#      under its own recorded conversation, a resumed primary retakes only a
#      dead owner's lock, and its PRIMARY re-arm runs only in primary scope
#      without holding the turn end.
#   6. The launch gate refuses a rendered trust dialog (whose default is
#      "No, exit") without ever pressing Enter, and confirms a live TUI.
#   7. Busy state is the pinned rendered-tail fallback alone (nothing armed,
#      because no push writer could clear a seeded record), scoped to
#      harness=kiro-cli, busy on its anchors and unknown when they scroll out.
#   8. --model and --effort ride the launch (effort accepts the full
#      low|medium|high|xhigh|max vocabulary natively).
#   9. Teardown removes every kiro-cli artifact and the .fm-kiro-turnend pointer
#      is excluded from the unlanded-work dirty check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS KIRO_SESSION_ID

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-kiro-harness)

NODE_BIN=$(command -v node) || fail "test needs node"
NODE_BIN_DIR=$(dirname "$NODE_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$NODE_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

# --- detection --------------------------------------------------------------

test_kiro_ancestry_detects_the_native_and_inner_command_names() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-}"; exit 0 ;;
  *"ppid="*) printf '%s\n' 1; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FAKE_PS_COMM=kiro-cli FAKE_PS_ARGS='kiro-cli chat -a' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kiro-cli ] \
    || fail "a natively-named kiro-cli command must be detected by ancestry, got '$out'"
  out=$(FAKE_PS_COMM=kiro-cli-chat FAKE_PS_ARGS='kiro-cli-chat chat' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kiro-cli ] \
    || fail "the inner kiro-cli-chat wrapper must be detected as kiro-cli, got '$out'"
  pass "fm-harness.sh: ancestry detects the kiro-cli and kiro-cli-chat names"
}

test_kiro_ancestry_rejects_unrelated_mentions() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-negatives")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:-}"; exit 0 ;;
  *"ppid="*) printf '%s\n' 1; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(FAKE_PS_COMM=kiroshi FAKE_PS_ARGS='kiroshi --serve' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kiro-cli ] \
    || fail "an unrelated kiroshi command must not detect kiro-cli, got '$out'"
  # A bun frame is matched ONLY by a kiro-cli install-tree path component,
  # because a bare `bun` is also omp's and Pi's interpreter. Another bun's
  # script path must never be read as kiro-cli, while kiro's own interposed
  # bundle frame must be (that is what keeps the lock ancestry run contiguous).
  out=$(FAKE_PS_COMM=bun FAKE_PS_ARGS='bun /home/x/.bun/bin/pi-coding-agent/dist/cli.js' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kiro-cli ] \
    || fail "a non-kiro bun interpreter (Pi's) must not detect kiro-cli, got '$out'"
  out=$(FAKE_PS_COMM=bun FAKE_PS_ARGS='bun /home/x/.local/share/kiro-cli/tui.js chat -a' PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kiro-cli ] \
    || fail "kiro-cli's own interposed bun bundle frame must detect kiro-cli, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated kiro mentions and a foreign bun"
}

test_kiro_env_family_does_not_claim_identity_and_ancestry_outranks_claudecode() {
  local fakebin out
  # The KIRO_* family is inheritable, so it must never promote to a kiro-cli
  # identity the way GEMINI_CLI does for gemini: with no kiro-cli ancestry a
  # retained KIRO_SESSION_ID changes nothing.
  fakebin=$(fm_fakebin "$TMP_ROOT/env-only")
  fm_fake_blind_ancestry "$fakebin"
  out=$(KIRO_SESSION_ID=abc KIRO_VERSION=2.22.1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != kiro-cli ] \
    || fail "an inherited KIRO_* env family must never claim the kiro-cli identity, got '$out'"
  # Drive the hazard the other way: kiro-cli does not clear an inherited
  # CLAUDECODE, so a structural kiro-cli ancestor must still outrank the
  # retained marker rather than being renamed away from it.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' kiro-cli; exit 0 ;;
  *"args="*) printf '%s\n' 'kiro-cli chat -a'; exit 0 ;;
  *"ppid="*) printf '%s\n' 1; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = kiro-cli ] \
    || fail "a structural kiro-cli ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: KIRO_* never claims identity; a kiro-cli ancestor outranks CLAUDECODE"
}

test_kiro_is_in_the_session_lock_vocabulary() {
  # A session running on kiro-cli must be able to acquire this home's lock, so
  # its names are in the session-lock command vocabulary (exercised through the
  # public matcher, not by asserting source bytes).
  local out
  out=$(bash -c '. "$0/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches kiro-cli "kiro-cli chat -a" && echo native
    fm_harness_process_matches kiro-cli-chat "kiro-cli-chat chat" && echo inner
    fm_harness_process_matches kiroshi "kiroshi --serve" || echo kiroshi-rejected' "$ROOT")
  assert_contains "$out" native "session-lock vocabulary must accept kiro-cli"
  assert_contains "$out" inner "session-lock vocabulary must accept kiro-cli-chat"
  assert_contains "$out" kiroshi-rejected "session-lock vocabulary must reject unrelated kiroshi"
  pass "fm-session-lock-lib: kiro-cli names are in the lock vocabulary, kiroshi is not"
}

# --- control ----------------------------------------------------------------

test_kiro_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported kiro-cli || fail "kiro-cli must be a supported control harness"
  [ "$(fm_control_harness_family kiro-cli)" = kiro-cli ] || fail "kiro-cli must map to its own family"
  fm_control_harness_supports_kind kiro-cli scout || fail "kiro-cli must run scouts"
  fm_control_harness_supports_kind kiro-cli ship || fail "kiro-cli must run ships"
  fm_control_harness_supports_kind kiro-cli secondmate \
    || fail "kiro-cli must run secondmates (it has a verified primary supervision protocol)"
  [ "$(fm_control_interrupt_key kiro-cli)" = Escape ] || fail "kiro-cli must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat kiro-cli)" = 1 ] || fail "kiro-cli must interrupt on a single press"
  [ -z "$(fm_control_interrupt_clear_key kiro-cli)" ] || fail "kiro-cli must need no clear key"
  [ "$(fm_control_interrupt_ack_source kiro-cli)" = none ] || fail "kiro-cli must have no ack source"
  [ "$(fm_control_exit_command kiro-cli)" = /quit ] || fail "kiro-cli must exit on /quit"
  pass "fm-control-lib: kiro-cli mechanics are Escape once, no clear key, /quit, all kinds"
}

test_kiro_control_wiring_and_token_paths() {
  local wiring token auth
  wiring=$(fm_control_harness_wiring_paths kiro-cli /wt /state k1 | tr '
' ' ')
  assert_contains "$wiring" "/wt/.fm-kiro-turnend" "wiring must list the worktree pointer"
  assert_contains "$wiring" "/state/k1.kiro-home/.fm-kiro-turnend" "wiring must list the isolated-home pointer"
  assert_contains "$wiring" "/state/k1.kiro-turnend-token" "wiring must list the state token"
  assert_contains "$wiring" "/wt/.kiro/agents/firstmate-kiro-k1.json"     "wiring must list the task-specific V3 project agent"
  assert_contains "$wiring" "/wt/.kiro/hooks/fm-firstmate-k1.json"     "wiring must list the task-specific V3 project hook"
  token=$(fm_control_harness_turnend_token_path kiro-cli /state k1)
  [ "$token" = "/state/k1.kiro-turnend-token" ] || fail "token path wrong: '$token'"
  auth=$(fm_control_harness_turnend_auth_path kiro-cli fm.abc123def456)
  [ -z "$auth" ] || fail "kiro-cli auth path must be empty (registry is inside the per-task KIRO_HOME), got '$auth'"
  pass "fm-control-lib: Kiro wiring includes project-scoped V3 files and isolated-home token files"
}

# --- composer ---------------------------------------------------------------

test_kiro_idle_placeholder_is_exact_and_harness_scoped() {
  local esc caps idle typed v3 old out
  esc=$(printf '\033')
  caps=$'styled=1\ncursor=1\nidentity=1\nrows=0'
  idle="${esc}[38;2;158;158;158m› ask a question or describe a task ↵${esc}[0m"
  typed="${esc}[38;2;230;230;230m› continue with the implementation${esc}[0m"
  out=$(fm_composer_classify_screen "$caps" "$idle" 0 '' kiro-cli)
  [ "$out" = empty ] || fail "a Kiro-attributed idle placeholder must read empty, got '$out'"
  out=$(fm_composer_classify_screen "$caps" "$typed" 0 '' kiro-cli)
  [ "$out" = pending ] || fail "real Kiro composer text must stay pending, got '$out'"
  out=$(fm_composer_classify_screen "$caps" "$idle" 0 '' codex)
  [ "$out" = pending ] || fail "another harness typing Kiro's phrase must stay pending, got '$out'"
  v3=$'› ask a question or describe a task ↵\n /sessions to resume · /copy to clipboard'
  old=$'› ask a question or describe a task ↵\n /copy to clipboard'
  out=$(fm_composer_classify_screen $'styled=0\ncursor=0\nidentity=0\nrows=20' "$v3" '' '' kiro-cli)
  [ "$out" = empty ] || fail "Kiro V3's helper footer must not become wrapped input, got '$out'"
  out=$(fm_composer_classify_screen $'styled=0\ncursor=0\nidentity=0\nrows=20' "$old" '' '' kiro-cli)
  [ "$out" = empty ] || fail "Kiro's pre-V3 bare helper footer must not become wrapped input, got '$out'"
  pass "fm-composer-lib: Kiro's exact idle placeholder is empty only with its recorded harness"
}

# --- busy state -------------------------------------------------------------

test_kiro_busy_tail_needs_a_pinned_anchor() {
  printf 'working\nThinking... (esc to cancel)\n' | fm_busy_kiro_tail_busy \
    || fail "the Thinking (esc to cancel) footer must read busy"
  printf '> Kiro is working · Type to steer · Ctrl+S to queue\n' | fm_busy_kiro_tail_busy \
    || fail "the 'Kiro is working' status line must read busy"
  printf 'idle\n› ask a question or describe a task ↵\n' | fm_busy_kiro_tail_busy \
    && fail "the idle placeholder must not read busy" || true
  printf 'the model wrote the word thinking in prose\n>\n' | fm_busy_kiro_tail_busy \
    && fail "echoed prose mentioning thinking must not read busy" || true
  FM_BUSY_KIRO_REGEX='never-idle-marker' bash -c '. "$0/bin/fm-busy-lib.sh"; printf "idle\n" | fm_busy_kiro_tail_busy' "$ROOT" \
    && fail "an idle pane must not read busy even under an override" || true
  FM_BUSY_KIRO_REGEX='idle' bash -c '. "$0/bin/fm-busy-lib.sh"; printf "idle\n" | fm_busy_kiro_tail_busy' "$ROOT" \
    || fail "FM_BUSY_KIRO_REGEX override must be honored"
  pass "fm-busy-lib: only the pinned kiro-cli anchors carry the busy verdict (with override)"
}

test_kiro_busy_signatures_are_harness_scoped() {
  printf 'Kiro is working\n' | fm_busy_lines_match kiro-cli \
    || fail "harness=kiro-cli must match its own 'Kiro is working' token"
  printf 'Kiro is working\n' | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow kiro-cli's token" || true
  printf 'Kiro is working\n' | fm_busy_lines_match kimi \
    && fail "harness=kimi must never borrow kiro-cli's token" || true
  printf 'Ctrl+c:cancel\n' | fm_busy_lines_match kiro-cli \
    && fail "harness=kiro-cli must never borrow grok's token" || true
  printf 'Kiro is working\n' | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  pass "fm-composer-lib: kiro-cli delivery signatures never cross harnesses"
}

test_kiro_classify_busy_on_anchor_unknown_when_scrolled_out() {
  local statedir busy scrolled
  statedir="$TMP_ROOT/classify"; mkdir -p "$statedir"
  busy=$(fm_busy_classify tmux fake:win kiro-cli kiro-case-1 "$statedir" 'streaming reply
Thinking... (esc to cancel)')
  [ "$busy" = "busy kiro-regex" ] || fail "a busy tail must classify busy kiro-regex, got '$busy'"
  scrolled=$(fm_busy_classify tmux fake:win kiro-cli kiro-case-2 "$statedir" 'reply landed
› ask a question or describe a task ↵')
  [ "$scrolled" = "unknown kiro-regex" ] \
    || fail "a scrolled-out marker must classify unknown kiro-regex (never idle), got '$scrolled'"
  pass "fm-busy-lib: kiro-cli classifies busy on its anchor and unknown without it"
}

test_kiro_semantic_busy_source_is_registered() {
  local trusted
  trusted=$(fm_busy_sources_for_harness kiro-cli)
  case " $trusted " in *" kiro-hook "*) ;; *) fail "kiro-cli does not trust kiro-hook: '$trusted'" ;; esac
  case " $trusted " in *" fm-spawn "*) ;; *) fail "kiro-cli lost firstmate-owned seed trust: '$trusted'" ;; esac
  pass "fm-busy-lib: kiro-cli trusts its generation-bound hook writer"
}

test_kiro_hooks_drive_semantic_busy_idle_and_progress() {
  local id rec state kh hook gen out new_gen manifest busy_event
  id="kiro-semantic-z5-$$"
  rec=$(make_kiro_spawn_case semantic "$id")
  read_kiro_spawn_record "$rec"
  run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto >/dev/null 2>&1
  state="$HOME_DIR/state"
  kh="$state/$id.kiro-home"
  hook="$ROOT/bin/fm-kiro-turnend-hook.sh"
  busy_event="$ROOT/bin/fm-busy-event.sh"
  gen=$(cat "$state/$id.busy-gen" 2>/dev/null) || fail "Kiro spawn did not arm a busy generation"
  out=$(fm_busy_classify tmux fake:win kiro-cli "$id" "$state" 'no rendered anchors')
  [ "$out" = "busy fm-spawn" ] || fail "spawn seed must be semantic busy, got '$out'"

  manifest="$WT_DIR/.kiro/hooks/fm-firstmate-$id.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || fail "the worker hook must be a regular file copied from the isolated home"
  node -e '
    const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const got=j.hooks.map(h => h.trigger).sort().join(",");
    if(got !== "PostToolUse,PreToolUse,Stop,UserPromptSubmit") {
      console.error(got); process.exit(1);
    }
  ' "$manifest" || fail "V3 project hook manifest lost a semantic lifecycle trigger"

  drive_kiro_hook() {  # <event> <generation>
    local event=$1 event_gen=$2
    printf '{"hook_event_name":"%s","cwd":"%s"}
' "$event" "$WT_DIR" |       (cd "$WT_DIR" && FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$state"         KIRO_HOME="$kh" KIRO_WORKSPACE_ROOT="$WT_DIR"         FM_KIRO_TASK_ID="$id" FM_KIRO_STATE="$state" FM_KIRO_BUSY_GEN="$event_gen"         bash "$hook")
  }

  rm -f "$state/$id.turn-ended"
  drive_kiro_hook Stop "$gen"
  out=$(fm_busy_classify tmux fake:win kiro-cli "$id" "$state" 'Kiro is working')
  [ "$out" = "idle kiro-hook" ] || fail "Stop must close semantic state, got '$out'"
  assert_present "$state/$id.turn-ended" "Stop must retain the watcher notification"

  drive_kiro_hook UserPromptSubmit "$gen"
  out=$(fm_busy_classify tmux fake:win kiro-cli "$id" "$state" 'idle screen')
  [ "$out" = "busy kiro-hook" ] || fail "UserPromptSubmit must open semantic busy, got '$out'"
  rm -f "$state/$id.progress"
  drive_kiro_hook PreToolUse "$gen"
  assert_present "$state/$id.progress" "PreToolUse must publish native progress"
  rm -f "$state/$id.progress"
  drive_kiro_hook PostToolUse "$gen"
  assert_present "$state/$id.progress" "PostToolUse must publish native progress"
  drive_kiro_hook Stop "$gen"
  out=$(fm_busy_classify tmux fake:win kiro-cli "$id" "$state" 'Kiro is working')
  [ "$out" = "idle kiro-hook" ] || fail "final Stop must win over rendered busy text, got '$out'"

  rm -f "$state/$id.busy-state"
  out=$(fm_busy_classify tmux fake:win kiro-cli "$id" "$state" 'Kiro is working')
  [ "$out" = "unknown missing" ]     || fail "an armed task with a missing record must not demote to kiro-regex, got '$out'"

  new_gen=$("$busy_event" arm "$state" "$id") || fail "Kiro generation replacement failed"
  drive_kiro_hook UserPromptSubmit "$gen"
  out=$(fm_busy_classify tmux fake:win kiro-cli "$id" "$state" 'idle screen')
  [ "$out" = "busy fm-spawn" ]     || fail "a stale hook changed the replacement generation, got '$out' (new $new_gen)"
  pass "Kiro hooks report semantic busy/idle/progress and reject stale generations"
}

# --- launch / spawn ---------------------------------------------------------

make_kiro_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/kiro-cli" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = chat ] && { echo "fake kiro-cli must never enter chat in a test" >&2; exit 9; }
exit 0
SH
  chmod +x "$fakebin/kiro-cli"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
killed="${FM_FAKE_TMUX_KILLED:-/dev/null}"
state=$(cat "$FM_FAKE_KIRO_STATE" 2>/dev/null || true)

# fake_screen renders the plain viewport (capture-pane -p). The trust dialog
# case carries its three anchor strings; the idle case shows kiro-cli's live
# chrome; the busy case shows a streaming turn; the booting case shows neither.
fake_screen() {
  case "$state" in
    trust)
      printf 'Warning: Kiro is running in trust all tools mode\n\n  ❯ No, exit\n    Yes, I accept\n'
      ;;
    trust-decoy)
      # Prose that merely mentions the phrase, WITHOUT the two navigable
      # options - a dialog-free frame that must NOT read as a dialog.
      printf 'I considered whether Kiro is running in trust all tools mode and decided against it.\n› ask a question or describe a task ↵\nTrust All Tools active, confirmations are off\n'
      ;;
    busy)
      printf 'Kiro is working · Type to steer · Ctrl+S to queue\nThinking... (esc to cancel)\n'
      ;;
    booting)
      printf 'shell starting\n$ \n'
      ;;
    *)
      printf 'idle\n› ask a question or describe a task ↵\nTrust All Tools active, confirmations are off\n'
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  # After a kill, the endpoint is gone: report it absent so teardown's
  # post-close verification confirms the window closed.
  has-session) [ -f "$killed" ] && exit 1 || exit 0 ;;
  list-windows) [ -f "$killed" ] && exit 0 || printf '%s\n' fm-task; exit 0 ;;
  list-panes) [ -f "$killed" ] && exit 0 || printf '%s\n' pane; exit 0 ;;
  kill-window|kill-pane) : > "$killed"; exit 0 ;;
  new-session|new-window|select-window|set-option|set-hook|rename-window) exit 0 ;;
  send-keys)
    literal=; prev=
    for a in "$@"; do [ "$prev" = -l ] && { literal=$a; break; }; prev=$a; done
    if [ -n "$literal" ]; then
      # A spawn types a short line sourcing its staged launch file rather than
      # the command itself (bin/fm-spawn.sh's LAUNCH_FILE); resolve that
      # indirection so this suite asserts what the pane actually runs, exactly
      # as tests/fixtures.sh's fm_test_fake_tmux_spawn does.
      case "$literal" in
        ". '"*"'")
          staged=${literal#". '"}
          staged=${staged%"'"}
          [ -f "$staged" ] && literal=$(cat "$staged")
          ;;
      esac
      case "$literal" in
        *'--agent'*'firstmate-kiro'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          # The launch command carries the positional brief, so the TUI comes up
          # already working. The literal only TYPES the command; the following
          # Enter starts it, and THAT is when the pane shows what the fixture
          # asked for - mirroring the real sequence, where the trust dialog
          # appears only once kiro-cli itself has started.
          printf 'launched\n' > "$FM_FAKE_KIRO_STATE"
          ;;
        'Read the brief at '*)
          # The unified launch types NO pointer; any pointer here is a bug.
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            # The launch Enter transitions to whatever the fixture asked the
            # freshly launched pane to show.
            case "${FM_FAKE_KIRO_TRUST:-suppressed}" in
            present) printf 'trust\n' > "$FM_FAKE_KIRO_STATE" ;;
            decoy) printf 'trust-decoy\n' > "$FM_FAKE_KIRO_STATE" ;;
            *)
              if [ "${FM_FAKE_KIRO_READY:-yes}" = yes ]; then
                printf 'idle\n' > "$FM_FAKE_KIRO_STATE"
              else
                printf 'booting\n' > "$FM_FAKE_KIRO_STATE"
              fi
              ;;
            esac
            ;;
          trust)
            # firstmate must NEVER answer the trust dialog. Any Enter reaching
            # it here is a bug in the gate; record it loudly.
            printf 'enter\n' >> "$FM_FAKE_KIRO_TRUST_ENTER_LOG"
            ;;
        esac
        ;;
    esac
    exit 0
    ;;
  capture-pane)
    start= end= prev=
    for arg in "$@"; do
      case "$prev" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in -S|-E) prev=$arg ;; *) prev= ;; esac
    done
    if [ "$start" = -0 ] && [ "${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" = yes ]; then
      echo "can't find pane" >&2
      exit 1
    fi
    case "$start:$end" in
      *[!0-9:]*|'':*|*:'') fake_screen ;;
      *) fake_screen | awk -v start="$start" -v end="$end" \
           'NR - 1 >= start && NR - 1 <= end' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_kiro_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_kiro_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Kiro dispatch.

## Firstmate spec
Verify launch and wiring behavior.
EOF
  printf 'kiro-cli\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/kiro.state"
  : > "$case_dir/trust-enter.log"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_kiro_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_kiro_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_KIRO_STATE="$case_dir/kiro.state" \
    FM_FAKE_KIRO_TRUST_ENTER_LOG="$case_dir/trust-enter.log" \
    FM_FAKE_KIRO_TRUST="${FM_FAKE_KIRO_TRUST:-suppressed}" \
    FM_FAKE_KIRO_READY="${FM_FAKE_KIRO_READY:-yes}" \
    FM_FAKE_TMUX_VISIBLE_FAILS="${FM_FAKE_TMUX_VISIBLE_FAILS:-no}" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_TMUX_KILLED="$case_dir/tmux-killed" \
    FM_KIRO_READY_POLLS="${FM_KIRO_READY_POLLS:-3}" FM_KIRO_POLL_INTERVAL=0 \
    FM_KIRO_ENGINE="${FM_KIRO_ENGINE:-}" \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness kiro-cli --mode no-mistakes --yolo off "$@" 2>&1
}

# --- 1. happy path: positional brief, live TUI, no typed pointer ------------

test_kiro_launch_is_the_interactive_tui_with_brief_model_effort_and_scope() {
  local id rec out rc launch meta
  id="kiro-launch-z1-$$"
  rec=$(make_kiro_spawn_case launch "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto --effort low)
  rc=$?
  expect_code 0 "$rc" "kiro-cli spawn should succeed"
  assert_contains "$out" "spawned $id harness=kiro-cli" "kiro-cli spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/kiro-cli" "launch did not pin the resolved absolute binary"
  assert_contains "$launch" "chat --v3 -a --agent 'firstmate-kiro-$id'" \
    "launch did not carry the V3 engine, the trust flag, and the task-specific project agent"
  assert_not_contains "$launch" "--no-interactive" "launch must be the interactive steerable TUI, not the one-shot"
  assert_contains "$launch" "--model 'auto'" "launch did not carry the requested model"
  assert_contains "$launch" "--effort 'low'" "launch did not carry the requested effort"
  assert_contains "$launch" "KIRO_HOME='$HOME_DIR/state/$id.kiro-home'" "launch did not scope KIRO_HOME per task"
  assert_contains "$launch" "KIRO_DATA_DIR=" "launch did not scope KIRO_DATA_DIR per task"
  assert_contains "$launch" "KIRO_CHAT_LOG_FILE=" "launch did not scope KIRO_CHAT_LOG_FILE per task"
  assert_contains "$launch" "env -u CLAUDECODE" "launch did not clear the inherited launcher markers"
  assert_contains "$launch" "-u KIRO_ACP_PERMISSION_MODE" "launch did not clear inherited ACP permission state"
  assert_contains "$launch" "FM_KIRO_BUSY_GEN='$(cat "$HOME_DIR/state/$id.busy-gen")'" \
    "launch did not carry the armed incarnation generation"
  assert_contains "$launch" "encode launch-brief" "launch must carry the brief positionally"
  assert_not_contains "$launch" "__KIROBIN__" "launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__KIROHOME__" "launch left its KIRO_HOME placeholder unsubstituted"
  assert_not_contains "$launch" "__KIROAGENT__" "launch left its agent placeholder unsubstituted"
  assert_not_contains "$launch" "__KIROENGINEFLAG__" "launch left its engine placeholder unsubstituted"
  assert_not_contains "$launch" "__BRIEF__" "launch left its brief placeholder unsubstituted"
  # The unified launch never types a pointer into the composer.
  [ ! -s "$CASE_DIR/pointer.log" ] \
    || fail "the positional-brief launch must never type a pointer (found: $(cat "$CASE_DIR/pointer.log"))"
  [ ! -s "$CASE_DIR/trust-enter.log" ] \
    || fail "kiro-cli pressed Enter into a dialog on the dialog-free happy path"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=kiro-cli' "$meta" "meta did not record its harness"
  assert_grep 'model=auto' "$meta" "meta did not record its model"
  assert_grep 'effort=low' "$meta" "meta did not record its effort"
  pass "fm-spawn: kiro-cli defaults to V3 with a project agent, capability trust, and isolated KIRO_* scope"
}

# --- 2. trust dialog: refuse, never answer ---------------------------------

test_kiro_trust_dialog_refuses_without_answering() {
  local id rec out rc kiro_home
  id=kiro-trust-refuse-z2
  rec=$(make_kiro_spawn_case trust-refuse "$id")
  read_kiro_spawn_record "$rec"
  kiro_home="$HOME_DIR/state/$id.kiro-home"
  rc=0
  out=$(FM_FAKE_KIRO_TRUST=present FM_KIRO_READY_POLLS=3 run_kiro_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a rendered kiro-cli trust dialog should fail the spawn"
  assert_contains "$out" "chat.disableTrustAllConfirmation=true" \
    "kiro-cli trust refusal did not name the missing suppression setting"
  assert_contains "$out" "$kiro_home" \
    "kiro-cli trust refusal did not name the resolved KIRO_HOME"
  [ ! -s "$CASE_DIR/trust-enter.log" ] \
    || fail "firstmate sent Enter to the kiro-cli trust dialog instead of refusing"
  assert_grep 'failed: kiro-cli rendered the --trust-all-tools confirmation dialog' \
    "$HOME_DIR/state/$id.status" \
    "kiro-cli trust refusal left no supervisor-visible failure line"
  pass "fm-spawn: kiro-cli refuses a rendered trust dialog, names the fix, and never presses Enter"
}

test_kiro_trust_decoy_does_not_block_the_launch() {
  local id rec out rc
  id=kiro-trust-decoy-z3
  rec=$(make_kiro_spawn_case trust-decoy "$id")
  read_kiro_spawn_record "$rec"
  out=$(FM_FAKE_KIRO_TRUST=decoy FM_KIRO_READY_POLLS=4 run_kiro_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 0 "$rc" "a trust-phrase decoy without the options should not read as a dialog"
  assert_contains "$out" "spawned $id harness=kiro-cli" \
    "kiro-cli spawn did not survive a trust-phrase decoy in prose"
  [ ! -s "$CASE_DIR/trust-enter.log" ] \
    || fail "kiro-cli answered a trust-phrase decoy that was never a dialog"
  pass "fm-spawn: a kiro-cli trust-phrase decoy in prose neither answers nor blocks the spawn"
}

# --- 3. gate predicates, exercised directly --------------------------------

# The gate helpers run main() on load, so fm-spawn.sh cannot be sourced. Extract
# the pure predicates by line range (as other tests do) and exercise them
# directly; the same behavior is ALSO covered end-to-end through the spawns
# above and below.
extract_kiro_predicates() {
  local start out ready_end
  start=$(grep -n '^kiro_trust_dialog_is_visible() {' "$SPAWN" | head -1 | cut -d: -f1)
  ready_end=$(grep -n '^kiro_wait_for_launch() {' "$SPAWN" | head -1 | cut -d: -f1)
  [ -n "$start" ] && [ -n "$ready_end" ] || return 1
  ready_end=$((ready_end - 1))
  out="$TMP_ROOT/kiro-predicates.sh"
  {
    # kiro_tui_is_live calls fm_busy_kiro_tail_busy, whose owner is
    # bin/fm-busy-lib.sh; source it so the extracted predicates are
    # self-contained.
    printf '. %s\n' "$(printf '%q' "$ROOT/bin/fm-busy-lib.sh")"
    sed -n "${start},${ready_end}p" "$SPAWN"
  } > "$out"
  printf '%s\n' "$out"
}

test_kiro_predicates_require_the_complete_signals() {
  local snippet
  snippet=$(extract_kiro_predicates) || fail "could not extract kiro predicates by line range"

  # The trust dialog needs ALL THREE anchor strings.
  local complete decoy_prose partial live idle busy
  complete=$'Warning: Kiro is running in trust all tools mode\n\n  \u276f No, exit\n    Yes, I accept'
  decoy_prose='I noted that Kiro is running in trust all tools mode, nothing else.'
  partial=$'Warning: Kiro is running in trust all tools mode\nYes, I accept'
  live=$'› ask a question or describe a task ↵'
  idle='Trust All Tools active, confirmations are off'
  busy=$'Kiro is working · Type to steer · Ctrl+S to queue'

  # shellcheck source=/dev/null
  bash -c '. "$1"; kiro_trust_dialog_is_visible "$2"' _ "$snippet" "$complete" \
    || fail "kiro_trust_dialog_is_visible rejected a complete dialog"
  if bash -c '. "$1"; kiro_trust_dialog_is_visible "$2"' _ "$snippet" "$decoy_prose"; then
    fail "kiro_trust_dialog_is_visible accepted prose without the navigable options"
  fi
  if bash -c '. "$1"; kiro_trust_dialog_is_visible "$2"' _ "$snippet" "$partial"; then
    fail "kiro_trust_dialog_is_visible accepted a dialog missing 'No, exit'"
  fi

  # The live-TUI signal matches any of the persistent chrome, so a launch whose
  # first turn is already streaming is not mistaken for a dead pane.
  bash -c '. "$1"; kiro_tui_is_live "$2"' _ "$snippet" "$live" \
    || fail "kiro_tui_is_live missed the idle prompt placeholder"
  bash -c '. "$1"; kiro_tui_is_live "$2"' _ "$snippet" "$idle" \
    || fail "kiro_tui_is_live missed the trust-active footer"
  bash -c '. "$1"; kiro_tui_is_live "$2"' _ "$snippet" "$busy" \
    || fail "kiro_tui_is_live missed a streaming turn's busy footer"
  if bash -c '. "$1"; kiro_tui_is_live "$2"' _ "$snippet" "shell starting"; then
    fail "kiro_tui_is_live matched a bare booting shell"
  fi
  pass "fm-spawn: kiro trust detection needs all three anchors; live TUI matches its chrome"
}

test_kiro_launch_gate_refuses_a_dead_pane() {
  local id rec out rc
  id=kiro-not-ready-z4
  rec=$(make_kiro_spawn_case not-ready "$id")
  read_kiro_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_KIRO_READY=no run_kiro_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "kiro-cli spawn without a live TUI should fail"
  assert_contains "$out" "kiro-cli" "kiro-cli launch failure lacked a harness-named diagnostic"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "kiro-cli must never type a pointer into the pane"
  pass "fm-spawn: kiro-cli fails loudly when no live TUI appears"
}

test_kiro_unreadable_viewport_fails_loudly() {
  local id rec out rc
  id=kiro-unreadable-z5
  rec=$(make_kiro_spawn_case unreadable "$id")
  read_kiro_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_TMUX_VISIBLE_FAILS=yes run_kiro_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a kiro-cli spawn whose viewport cannot be read should fail"
  assert_contains "$out" "could not read the visible viewport" \
    "an unreadable viewport must refuse rather than guess the dialog is absent"
  pass "fm-spawn: kiro-cli refuses when the visible viewport cannot be read"
}

# --- 4. turn-end wiring: the TRACKED hook in the per-task KIRO_HOME ---------

test_kiro_turn_end_wiring_lands_in_a_per_task_kiro_home() {
  local id rec out kh token pointer regfile target v2_agent v3_agent v3_hook hook_command
  id="kiro-wire-z6-$$"
  rec=$(make_kiro_spawn_case wire "$id")
  read_kiro_spawn_record "$rec"
  out=$(run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto)
  expect_code 0 "$?" "kiro-cli spawn should succeed"
  kh="$HOME_DIR/state/$id.kiro-home"
  assert_present "$kh/settings/cli.json" "per-task KIRO_HOME settings file is missing"
  assert_grep '"chat.enableKnowledge": false' "$kh/settings/cli.json"     "isolated Kiro settings must disable knowledge indexing"
  assert_grep 'disableTrustAllConfirmation' "$kh/settings/cli.json"     "settings must retain V2 trust-dialog suppression"
  v2_agent="$kh/agents/firstmate-kiro-v2-$id.json"
  assert_absent "$v2_agent"     "a V3 home must not contain a legacy agent that triggers Kiro's migration modal"
  v3_agent="$WT_DIR/.kiro/agents/firstmate-kiro-$id.json"
  v3_hook="$WT_DIR/.kiro/hooks/fm-firstmate-$id.json"
  home_agent="$kh/project/.kiro/agents/firstmate-kiro-$id.json"
  home_hook="$kh/project/.kiro/hooks/fm-firstmate-$id.json"
  assert_present "$v3_agent" "the task-specific V3 project agent is missing"
  assert_present "$v3_hook" "the task-specific V3 project hook is missing"
  [ -f "$v3_agent" ] && [ ! -L "$v3_agent" ] || fail "the task-specific V3 project agent must be a regular isolated-home copy"
  [ -f "$v3_hook" ] && [ ! -L "$v3_hook" ] || fail "the task-specific V3 project hook must be a regular isolated-home copy"
  assert_present "$home_agent" "the task-specific V3 agent payload is missing from KIRO_HOME"
  assert_present "$home_hook" "the task-specific V3 hook payload is missing from KIRO_HOME"
  node -e '
    const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    if(!j.excludedTools?.includes("knowledge")) process.exit(1);
    if(j.includePowers !== false) process.exit(1);
    if(!j.permissions?.rules?.some(r => r.capability === "all" && r.effect === "allow")) process.exit(1);
  ' "$home_agent" || fail "V3 project agent lost knowledge containment or capability trust"
  hook_command=$(node -e '
    const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const h=j.hooks?.find(x => x.trigger === "Stop");
    if(!h?.action?.command) process.exit(1);
    process.stdout.write(h.action.command);
  ' "$home_hook") || fail "V3 project hook is invalid"
  mkdir -p "$CASE_DIR/foreign-cwd"
  rm -f "$HOME_DIR/state/$id.turn-ended"
  printf '{"session_id":"sess_wire","hook_event_name":"Stop","cwd":"%s"}' "$WT_DIR" \
    | (cd "$CASE_DIR/foreign-cwd" && env -i HOME="$HOME_DIR" PATH="$BASE_PATH" /bin/sh -c "$hook_command")
  assert_present "$HOME_DIR/state/$id.turn-ended" \
    "V3 Stop hook must reach this task from a foreign folder without launcher environment"
  token=$(cat "$HOME_DIR/state/$id.kiro-turnend-token" 2>/dev/null) || fail "state token missing"
  pointer=$(cat "$kh/.fm-kiro-turnend" 2>/dev/null) || fail "isolated-home pointer missing"
  [ "$pointer" = "token=$token" ] || fail "isolated-home pointer '$pointer' does not name the state token '$token'"
  assert_absent "$WT_DIR/.fm-kiro-turnend" "a worker launch must not write its turn-end pointer into the worktree"
  [ -z "$(git -C "$WT_DIR" status --porcelain --untracked-files=all)" ] \
    || fail "isolated Kiro wiring must leave the worktree clean for synchronization"
  regfile="$kh/agents/fm-turn-end.d/$token"
  target=$(cat "$regfile" 2>/dev/null) || fail "registry entry for the token is missing"
  [ "$target" = "$HOME_DIR/state/$id.turn-ended" ]     || fail "registry entry must name this task's turn-ended path, got '$target'"
  assert_absent "$WT_DIR/.kiro/agents/firstmate-kiro.json"     "spawn must never replace a project's fixed firstmate-kiro agent name"
  pass "fm-spawn: V3 project scope and isolated knowledge-disabled home are both task-owned"
}

test_kiro_guarded_hook_touches_turn_ended_only_on_a_matching_pointer() {
  local id rec kh hook other_home
  id="kiro-hook-z7-$$"
  rec=$(make_kiro_spawn_case hook "$id")
  read_kiro_spawn_record "$rec"
  run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto >/dev/null 2>&1
  kh="$HOME_DIR/state/$id.kiro-home"
  hook="$ROOT/bin/fm-kiro-turnend-hook.sh"
  [ -x "$hook" ] || fail "the tracked hook is missing or not executable at $hook"
  # The payload is required (the hook drains stdin), the task's KIRO_HOME is
  # passed the way the generated hook command passes it, and the home/state
  # overrides keep any ambient FM_* from leaking into the case.
  kiro_hook_stop() { # <workspace> <kiro-home>
    printf '%s\n' "{\"hook_event_name\":\"stop\",\"cwd\":\"$1\"}" \
      | (cd "$1" && env -u KIRO_HOME FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
        FM_KIRO_TASK_ID="$id" FM_KIRO_STATE="$HOME_DIR/state" bash "$hook" --kiro-home "$2")
  }
  rm -f "$HOME_DIR/state/$id.turn-ended"
  kiro_hook_stop "$WT_DIR" "$kh"
  assert_present "$HOME_DIR/state/$id.turn-ended" "a matching pointer must let the hook touch turn-ended"
  # A home carrying the registry but no pointer leaves the hook a no-op.
  other_home="$CASE_DIR/other-home"
  mkdir -p "$other_home/agents" "$CASE_DIR/other-ws"
  cp -R "$kh/agents/fm-turn-end.d" "$other_home/agents/"
  rm -f "$HOME_DIR/state/$id.turn-ended"
  kiro_hook_stop "$CASE_DIR/other-ws" "$other_home"
  assert_absent "$HOME_DIR/state/$id.turn-ended" "a home with no pointer must leave the hook a no-op"
  # A pointer naming a token the registry does not know is a no-op.
  printf 'token=fm.notarealtoken1\n' > "$other_home/.fm-kiro-turnend"
  kiro_hook_stop "$CASE_DIR/other-ws" "$other_home"
  assert_absent "$HOME_DIR/state/$id.turn-ended" "an unknown token must leave the hook a no-op"
  pass "fm-spawn: the tracked kiro-cli stop hook touches turn-ended only on a matching pointer+token"
}

test_kiro_primary_rearm_stands_down_outside_primary_scope() {
  # The same tracked hook carries the primary supervision re-arm. It must stand
  # down in a linked crew/scout worktree (a genuine linked git worktree fails
  # fm_primary_scope_matches) while still making its turn-ended touch, and it
  # must never arm a watcher for a home that is not the lock owner.
  local id rec kh hook wt arm_log
  id="kiro-rearm-z8-$$"
  rec=$(make_kiro_spawn_case rearm "$id")
  read_kiro_spawn_record "$rec"
  run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto >/dev/null 2>&1
  kh="$HOME_DIR/state/$id.kiro-home"
  hook="$ROOT/bin/fm-kiro-turnend-hook.sh"
  arm_log="$CASE_DIR/arm.log"; : > "$arm_log"
  # A shim bin/fm-watch-arm.sh alongside copies of the real libs proves whether
  # the re-arm path was reached at all: it records and exits without starting a
  # watcher. The hook is invoked with FM_ROOT_OVERRIDE pointed at the shim so it
  # resolves every sibling script there.
  local shimroot="$CASE_DIR/shimroot"
  mkdir -p "$shimroot/bin"
  cp "$ROOT"/bin/fm-primary-scope-lib.sh "$ROOT"/bin/fm-supervision-lib.sh \
    "$ROOT"/bin/fm-wake-lib.sh "$ROOT"/bin/fm-session-lock-lib.sh \
    "$ROOT"/bin/fm-cursor-lib.sh "$shimroot/bin/" 2>/dev/null || true
  cat > "$shimroot/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
printf 'armed\n' >> "$arm_log"
exit 0
SH
  chmod +x "$shimroot/bin/fm-watch-arm.sh"
  # In the linked crew/scout worktree the hook must NOT reach the arm path. A
  # genuine linked worktree fails fm_primary_scope_matches, so the hook stands
  # down after its turn-ended touch.
  rm -f "$HOME_DIR/state/$id.turn-ended"
  printf '{"hook_event_name":"stop","cwd":"%s"}\n' "$WT_DIR" \
    | FM_ROOT_OVERRIDE="$shimroot" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      KIRO_WORKSPACE_ROOT="$WT_DIR" FM_KIRO_TASK_ID="$id" FM_KIRO_STATE="$HOME_DIR/state" bash "$hook" --kiro-home "$kh"
  assert_present "$HOME_DIR/state/$id.turn-ended" "the turn-ended touch must still fire in a crew worktree"
  [ ! -s "$arm_log" ] \
    || fail "the primary re-arm must stand down in a linked crew/scout worktree"
  pass "fm-spawn: the tracked kiro-cli hook re-arms only in primary scope"
}

# --- 5. hook commands: any folder, no launcher environment ------------------

# Print every command a Kiro hook document registers: the V3 `.kiro/hooks`
# array shape or the V2 agent's per-event map.
kiro_hook_commands() {  # <hook-document>
  jq -r 'if (.hooks | type) == "array" then .hooks[].action.command else .hooks[][].command end' "$1"
}

test_every_firstmate_kiro_hook_command_works_from_any_folder_without_launch_env() {
  # Kiro runs each hook command through /bin/sh, and a session resumed with
  # plain kiro-cli carries none of the launcher's exports. Every Firstmate-owned
  # registration must therefore reach the tracked adapter from an unrelated
  # folder with a scrubbed environment: a relative script path or an env-only
  # fallback exits 127 here and leaves no probe arrival. The tracked documents
  # are enumerated, so a new tracked hook file is covered without editing this.
  local id v2_id rec foreign probe entry workspace doc cmd rc before after checked=0
  local v2_case v2_home v2_wt primary_dir primary_fake
  local -a docs=()
  id="kiro-anyfolder-z15-$$"
  rec=$(make_kiro_spawn_case anyfolder "$id")
  read_kiro_spawn_record "$rec"
  run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto >/dev/null 2>&1 \
    || fail "V3 Kiro spawn for the any-folder case failed"
  docs+=("$WT_DIR|$WT_DIR/.kiro/hooks/fm-firstmate-$id.json")

  v2_id="kiro-anyfolder-v2-z15-$$"
  rec=$(make_kiro_spawn_case anyfolder-v2 "$v2_id")
  IFS='|' read -r v2_case v2_home _ v2_wt _ <<EOF
$rec
EOF
  FM_KIRO_ENGINE=v2 run_kiro_spawn "$v2_case" "$v2_home" "$v2_case/project" "$v2_wt" "$v2_case/fake/fakebin" \
    "$v2_id" --model auto >/dev/null 2>&1 || fail "V2 Kiro spawn for the any-folder case failed"
  docs+=("$v2_wt|$v2_home/state/$v2_id.kiro-home/agents/firstmate-kiro-v2-$v2_id.json")

  primary_dir="$TMP_ROOT/anyfolder-primary"
  primary_fake=$(fm_fakebin "$primary_dir/fake")
  cat > "$primary_fake/kiro-cli" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && echo "kiro-cli 2.22.1"
exit 0
SH
  chmod +x "$primary_fake/kiro-cli"
  mkdir -p "$primary_dir/home/state"
  PATH="$primary_fake:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary_dir/home" \
    "$ROOT/bin/fm-kiro-primary.sh" --v2 >/dev/null 2>&1 || fail "V2 primary launcher failed"
  docs+=("$ROOT|$primary_dir/home/state/.kiro-primary-home/agents/firstmate-kiro-v2.json")

  while IFS= read -r doc; do
    [ -n "$doc" ] && docs+=("$ROOT|$ROOT/$doc")
  done <<EOF
$(git -C "$ROOT" ls-files -- '.kiro/hooks/*.json')
EOF

  foreign="$TMP_ROOT/anyfolder-foreign"
  probe="$TMP_ROOT/anyfolder.probe"
  mkdir -p "$foreign"
  : > "$probe"
  for entry in "${docs[@]}"; do
    workspace=${entry%%|*}
    doc=${entry#*|}
    assert_present "$doc" "Firstmate-owned Kiro hook document is missing"
    while IFS= read -r cmd; do
      [ -n "$cmd" ] || continue
      before=$(grep -c '^at=' "$probe")
      rc=0
      printf '{"session_id":"sess_anyfolder","hook_event_name":"PreToolUse","cwd":"%s"}' "$workspace" \
        | (cd "$foreign" && env -i HOME="$foreign" PATH="$BASE_PATH" \
          FM_KIRO_HOOK_PROBE_FILE="$probe" FM_STATE_OVERRIDE="$foreign/no-state" /bin/sh -c "$cmd") \
        >/dev/null 2>&1 || rc=$?
      after=$(grep -c '^at=' "$probe")
      [ "$rc" -eq 0 ] && [ "$after" -eq $((before + 1)) ] \
        || fail "a hook command in $doc did not reach the tracked adapter from $foreign without launcher environment (exit $rc): $cmd"
      checked=$((checked + 1))
    done <<EOF
$(kiro_hook_commands "$doc")
EOF
  done
  [ "$checked" -ge 17 ] || fail "only $checked Kiro hook commands were exercised; the registrations were not all found"
  grep -q "^at=.* pwd=$foreign\$" "$probe" || fail "the probe did not record the foreign folder as the hook's working directory"
  pass "every Firstmate-owned Kiro hook command ($checked) reaches the adapter from any folder without launcher environment"
}

test_kiro_resumed_worker_hooks_bind_only_through_the_recorded_session() {
  # A worker resumed with plain `kiro-cli --resume-id` has no FM_KIRO_* or
  # KIRO_HOME in its environment. Its task hook still binds through the baked
  # KIRO_HOME, and it may write busy state only under the generation a launched
  # incarnation recorded for that same conversation, so a relaunch still
  # rejects every older conversation.
  local id rec state kh doc gen new_gen out foreign
  local -a launched relaunched
  id="kiro-resume-z16-$$"
  rec=$(make_kiro_spawn_case resume "$id")
  read_kiro_spawn_record "$rec"
  run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto >/dev/null 2>&1 \
    || fail "Kiro spawn for the resume case failed"
  state="$HOME_DIR/state"
  kh="$state/$id.kiro-home"
  doc="$WT_DIR/.kiro/hooks/fm-firstmate-$id.json"
  gen=$(cat "$state/$id.busy-gen") || fail "Kiro spawn did not arm a busy generation"
  foreign="$CASE_DIR/foreign"
  mkdir -p "$foreign"
  launched=(FM_KIRO_TASK_ID="$id" FM_KIRO_STATE="$state" FM_KIRO_BUSY_GEN="$gen" KIRO_HOME="$kh")
  fire() {  # <trigger> <session-id> [launch environment...]
    local trigger=$1 session=$2 cmd
    shift 2
    cmd=$(jq -r --arg t "$trigger" '.hooks[] | select(.trigger == $t) | .action.command' "$doc")
    printf '{"session_id":"%s","hook_event_name":"%s","cwd":"%s"}' "$session" "$trigger" "$WT_DIR" \
      | (cd "$foreign" && env -i HOME="$HOME_DIR" PATH="$BASE_PATH" FM_STATE_OVERRIDE="$foreign/no-state" \
        "$@" /bin/sh -c "$cmd")
  }
  classify() { fm_busy_classify tmux fake:win kiro-cli "$id" "$state" 'no rendered anchors'; }

  rm -f "$state/$id.turn-ended"
  fire Stop sess_a
  assert_present "$state/$id.turn-ended" "a resumed worker's Stop must still notify its own task"
  out=$(classify)
  [ "$out" = "busy fm-spawn" ] || fail "no launched incarnation spoke for sess_a yet, so busy state must not move, got '$out'"

  fire UserPromptSubmit sess_a "${launched[@]}"
  [ "$(classify)" = "busy kiro-hook" ] || fail "the launched incarnation's prompt must open busy"

  rm -f "$state/$id.turn-ended" "$state/$id.progress"
  fire Stop sess_a
  [ "$(classify)" = "idle kiro-hook" ] || fail "the resumed conversation's Stop must close busy state"
  assert_present "$state/$id.turn-ended" "the resumed conversation's Stop must notify the task"
  fire UserPromptSubmit sess_a
  [ "$(classify)" = "busy kiro-hook" ] || fail "the resumed conversation's prompt must open busy state"
  fire PreToolUse sess_a
  assert_present "$state/$id.progress" "the resumed conversation's tool use must publish progress"
  fire Stop sess_a
  [ "$(classify)" = "idle kiro-hook" ] || fail "the resumed conversation's final Stop must close busy state"

  fire UserPromptSubmit sess_other
  [ "$(classify)" = "idle kiro-hook" ] || fail "a conversation the incarnation never recorded must change nothing"

  new_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id") || fail "Kiro generation replacement failed"
  relaunched=(FM_KIRO_TASK_ID="$id" FM_KIRO_STATE="$state" FM_KIRO_BUSY_GEN="$new_gen" KIRO_HOME="$kh")
  fire UserPromptSubmit sess_a
  [ "$(classify)" = "busy fm-spawn" ] || fail "an older resumed conversation must not write under a replacement generation"
  fire Stop sess_b "${relaunched[@]}"
  [ "$(classify)" = "idle kiro-hook" ] || fail "the replacement incarnation's Stop must close busy state"
  fire UserPromptSubmit sess_a
  fire UserPromptSubmit sess_a "${launched[@]}"
  [ "$(classify)" = "idle kiro-hook" ] || fail "no older conversation or incarnation may reopen busy after a relaunch"
  fire UserPromptSubmit sess_b
  [ "$(classify)" = "busy kiro-hook" ] || fail "the replacement incarnation's own conversation must bind when resumed"
  pass "Kiro: a resumed worker reaches its task and binds only through its recorded conversation"
}

test_kiro_resumed_primary_retakes_a_dead_lock_and_stop_returns_promptly() {
  # Kiro fires SessionStart only for a conversation's first prompt, so a
  # primary resumed after its old process died reaches UserPromptSubmit with a
  # dead lock owner. The tracked hook must take the helm there, never while a
  # live session holds the lock, and its Stop re-arm must not hold the turn end
  # for the watcher cycle bin/fm-watch-arm.sh waits on.
  local dir root state log harness dead owner prompt_cmd stop_cmd out elapsed i
  dir="$TMP_ROOT/resumed-primary"
  root="$dir/firstmate"
  state="$root/state"
  log="$dir/calls.log"
  mkdir -p "$root/bin" "$state" "$dir/foreign"
  git -C "$root" init -q
  : > "$root/AGENTS.md"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$root/bin/${f##*/}"; done
  rm -f "$root/bin/fm-sessionstart-run.sh" "$root/bin/fm-watch-arm.sh" "$root/bin/fm-wake-drain.sh"
  cat > "$root/bin/fm-sessionstart-run.sh" <<SH
#!/usr/bin/env bash
printf 'session-open %s\n' "\$*" >> '$log'
"\$(dirname "\$0")/fm-lock.sh" >/dev/null 2>&1 || printf 'lock refused\n' >> '$log'
printf 'DIGEST: fake session start\n'
SH
  cat > "$root/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
sleep 4
printf 'arm\n' >> '$log'
SH
  cat > "$root/bin/fm-wake-drain.sh" <<SH
#!/usr/bin/env bash
printf 'drain\n' >> '$log'
SH
  chmod +x "$root/bin/fm-sessionstart-run.sh" "$root/bin/fm-watch-arm.sh" "$root/bin/fm-wake-drain.sh"
  : > "$state/task.meta"
  : > "$log"
  harness=$(fm_fakebin "$dir/harness")
  ln -s /bin/bash "$harness/kiro-cli"
  prompt_cmd=$(jq -r '.hooks[] | select(.trigger == "UserPromptSubmit") | .action.command' "$ROOT/.kiro/hooks/fm-firstmate.json")
  stop_cmd=$(jq -r '.hooks[] | select(.trigger == "Stop") | .action.command' "$ROOT/.kiro/hooks/fm-firstmate.json")
  cat > "$dir/session.sh" <<'SH'
fire() {  # <event> <command>
  printf '{"session_id":"sess_resumed","hook_event_name":"%s","cwd":"%s"}' "$1" "$FM_TEST_ROOT" | /bin/sh -c "$2"
}
printf '%s\n' "$$" > "$FM_TEST_DIR/session.pid"
fire UserPromptSubmit "$FM_TEST_PROMPT_CMD" > "$FM_TEST_DIR/prompt.out"
fire UserPromptSubmit "$FM_TEST_PROMPT_CMD" >> "$FM_TEST_DIR/prompt.out"
[ "${FM_TEST_STOP:-0}" = 1 ] || exit 0
start=$SECONDS
fire Stop "$FM_TEST_STOP_CMD"
printf '%s\n' $((SECONDS - start)) > "$FM_TEST_DIR/stop.seconds"
SH
  run_session() {  # [FM_TEST_STOP=1]
    (cd "$dir/foreign" && env -i HOME="$dir" PATH="$BASE_PATH" FM_TEST_DIR="$dir" FM_TEST_ROOT="$root" \
      FM_TEST_PROMPT_CMD="$prompt_cmd" FM_TEST_STOP_CMD="$stop_cmd" "$@" "$harness/kiro-cli" "$dir/session.sh")
  }

  "$harness/kiro-cli" -c 'sleep 30; :' &
  owner=$!
  printf '%s\n' "$owner" > "$state/.lock"
  run_session
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  assert_not_contains "$(cat "$log")" "session-open" "a live lock owner must keep a second session read-only"
  [ "$(cat "$state/.lock")" = "$owner" ] || fail "a second session must never rewrite a live owner's lock"

  sh -c 'exit 0' &
  dead=$!
  wait "$dead" 2>/dev/null || true
  printf '%s\n' "$dead" > "$state/.lock"
  : > "$log"
  printf '{"session_id":"sess_inherited","hook_event_name":"UserPromptSubmit","cwd":"%s"}' "$dir/foreign" \
    | (cd "$dir/foreign" && env -i HOME="$dir" PATH="$BASE_PATH" FM_KIRO_PRIMARY_HOOK=1 \
      "$harness/kiro-cli" "$root/bin/fm-kiro-turnend-hook.sh") >/dev/null
  assert_not_contains "$(cat "$log")" "session-open" \
    "a primary registration declared by another workspace must never open this home's session"
  run_session FM_TEST_STOP=1
  out=$(cat "$dir/prompt.out")
  [ "$(grep -c '^session-open --source startup$' "$log")" -eq 1 ] \
    || fail "a resumed primary's first prompt must run the session-open path exactly once: $(cat "$log")"
  assert_contains "$out" "DIGEST: fake session start" "the session-open digest must reach the prompt's context"
  assert_contains "$out" "KIRO_PRIMARY_ENDPOINT:" "the session-open path must report the doorbell endpoint"
  [ "$(head -n 1 "$state/.lock")" = "$(cat "$dir/session.pid")" ] \
    || fail "the resumed primary did not retake the dead owner's lock"
  elapsed=$(cat "$dir/stop.seconds")
  [ "$elapsed" -le 2 ] || fail "the Stop re-arm held the turn end for ${elapsed}s"
  if command -v setsid >/dev/null 2>&1; then
    i=0
    while [ "$i" -lt 100 ] && ! grep -q '^arm$' "$log"; do sleep 0.1; i=$((i + 1)); done
    grep -q '^arm$' "$log" || fail "the resumed primary's Stop never reached the watcher re-arm"
  fi
  pass "Kiro: a resumed primary retakes a dead lock on its first prompt and Stop re-arms without holding the turn"
}

test_kiro_effort_xhigh_and_max_ride_the_launch() {
  local id rec launch
  id="kiro-xhigh-z9-$$"
  rec=$(make_kiro_spawn_case xhigh "$id")
  read_kiro_spawn_record "$rec"
  run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model auto --effort xhigh >/dev/null 2>&1
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--effort 'xhigh'" "kiro-cli natively supports --effort xhigh and must pass it"
  pass "fm-spawn: kiro-cli passes the native xhigh effort level"
}

test_kiro_v2_is_only_an_explicit_compatibility_fallback() {
  local id rec launch
  id="kiro-v2-fallback-z10-$$"
  rec=$(make_kiro_spawn_case v2-fallback "$id")
  read_kiro_spawn_record "$rec"
  FM_KIRO_ENGINE=v2 run_kiro_spawn     "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto >/dev/null 2>&1
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "chat --v2 --trust-all-tools --agent 'firstmate-kiro-v2-$id'"     "explicit V2 fallback lost its engine, trust flag, or distinct agent"
  assert_absent "$WT_DIR/.kiro/agents/firstmate-kiro-$id.json"     "V2 fallback must not install the V3 project agent"
  assert_absent "$WT_DIR/.kiro/hooks/fm-firstmate-$id.json"     "V2 fallback must not install expanded V3 hooks"
  assert_present "$HOME_DIR/state/$id.kiro-home/agents/firstmate-kiro-v2-$id.json"     "explicit V2 fallback did not materialize its legacy embedded-hook agent"
  pass "fm-spawn: V2 remains available only through explicit FM_KIRO_ENGINE=v2"
}

test_kiro_v3_project_files_are_regular_copies_and_refuse_different_existing() {
  local ws kh id hook rc clean_ws clean_kh agent
  id="kiro-copy-z14-$$"
  ws="$TMP_ROOT/v3-copy-refuse-ws"; kh="$TMP_ROOT/v3-copy-refuse-home"
  mkdir -p "$ws/.kiro/hooks" "$kh"
  hook="$ws/.kiro/hooks/fm-firstmate-$id.json"
  printf '%s\n' '{"captain-owned":"different"}' > "$hook"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-kiro-lib.sh"
  rc=0
  fm_kiro_install_v3_project_config "$ws" "$id" "$kh" || rc=$?
  [ "$rc" -ne 0 ] || fail "a different existing Kiro hook file must refuse installation"
  [ ! -L "$hook" ] || fail "a refused destination must not be converted to a symlink"
  [ "$(cat "$hook")" = '{"captain-owned":"different"}' ] \
    || fail "a different existing Kiro hook file must remain untouched"

  clean_ws="$TMP_ROOT/v3-copy-clean-ws"; clean_kh="$TMP_ROOT/v3-copy-clean-home"
  mkdir -p "$clean_ws" "$clean_kh"
  fm_kiro_install_v3_project_config "$clean_ws" "$id" "$clean_kh" \
    || fail "regular Kiro project copies should install"
  agent="$clean_ws/.kiro/agents/firstmate-kiro-$id.json"
  hook="$clean_ws/.kiro/hooks/fm-firstmate-$id.json"
  [ -f "$agent" ] && [ ! -L "$agent" ] || fail "the Kiro agent bridge must be a regular file"
  [ -f "$hook" ] && [ ! -L "$hook" ] || fail "the Kiro hook bridge must be a regular file"
  cmp -s "$agent" "$clean_kh/project/.kiro/agents/firstmate-kiro-$id.json" \
    || fail "the Kiro agent bridge must match its isolated-home payload"
  cmp -s "$hook" "$clean_kh/project/.kiro/hooks/fm-firstmate-$id.json" \
    || fail "the Kiro hook bridge must match its isolated-home payload"
  fm_kiro_remove_v3_project_config "$clean_ws" "$id" \
    || fail "Kiro project copy cleanup should succeed"
  assert_absent "$agent" "Kiro cleanup must remove the regular agent bridge"
  assert_absent "$hook" "Kiro cleanup must remove the regular hook bridge"
  pass "fm-kiro-lib: Kiro uses regular isolated-home copies and refuses a different file"
}

test_kiro_v3_agents_grant_concrete_tools_never_a_wildcard() {
  # Kiro's allowedTools grants no wildcard: a V3 agent declaring ["*"] still
  # stopped on fs_write's Replace in File with a human approval dialog (two
  # stalled scouts, 2026-09-21). The per-task generator and the tracked primary
  # agent must both name concrete tools, agree with each other, and keep
  # knowledge excluded; a returning wildcard fails here.
  local ws id kh agent home_agent primary generated tracked list
  ws="$TMP_ROOT/v3-agent-ws"; id="kiro-tools-$$"; kh="$TMP_ROOT/v3-agent-kiro-home"
  mkdir -p "$ws" "$kh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-kiro-lib.sh"
  fm_kiro_install_v3_project_config "$ws" "$id" "$kh" || fail "V3 project config install failed"
  agent="$ws/.kiro/agents/firstmate-kiro-$id.json"
  home_agent="$kh/project/.kiro/agents/firstmate-kiro-$id.json"
  [ -f "$agent" ] && [ ! -L "$agent" ] || fail "the worktree V3 agent must be a regular isolated-home copy"
  [ -f "$home_agent" ] && [ ! -L "$home_agent" ] || fail "the V3 agent payload must live in KIRO_HOME"
  primary="$ROOT/.kiro/agents/firstmate-kiro.json"
  assert_present "$agent" "per-task V3 agent was not generated"
  for list in tools allowedTools; do
    jq -e --arg l "$list" '.[$l] | type == "array" and length > 0 and all(. != "*") and index("fs_write") != null and index("execute_bash") != null and index("fs_read") != null' "$agent" >/dev/null \
      || fail "generated V3 agent's $list must be a concrete, wildcard-free list carrying fs_write, fs_read, and execute_bash: $(jq -c --arg l "$list" '.[$l]' "$agent")"
    jq -e --arg l "$list" '.[$l] | type == "array" and all(. != "*")' "$primary" >/dev/null \
      || fail "tracked primary V3 agent's $list must be a concrete, wildcard-free list"
  done
  generated=$(jq -c '[.tools, .allowedTools] | map(sort)' "$agent")
  tracked=$(jq -c '[.tools, .allowedTools] | map(sort)' "$primary")
  [ "$generated" = "$tracked" ] \
    || fail "per-task and primary V3 agents disagree on their tool grants: generated=$generated tracked=$tracked"
  jq -e '.excludedTools | index("knowledge") != null' "$agent" >/dev/null \
    || fail "generated V3 agent must keep knowledge excluded"
  # Token-free live confirmation when the real Kiro CLI is installed: the
  # generated agent must validate under the schema the installed binary enforces.
  if command -v kiro-cli >/dev/null 2>&1 \
     && case "$(kiro-cli --version 2>/dev/null)" in 'kiro-cli '*) true ;; *) false ;; esac; then
    KIRO_HOME="$TMP_ROOT/v3-agent-kiro-home" kiro-cli agent validate --path "$agent" >"$TMP_ROOT/v3-agent-validate.log" 2>&1 \
      || fail "installed kiro-cli rejected the generated V3 agent: $(cat "$TMP_ROOT/v3-agent-validate.log")"
    pass "fm-kiro-lib: V3 agents grant concrete, wildcard-free tools; validated by $(kiro-cli --version)"
  else
    pass "fm-kiro-lib: V3 agents grant concrete, wildcard-free tools (kiro-cli not installed; schema validation skipped)"
  fi
}

test_kiro_primary_launcher_defaults_v3_and_persists_its_home() {
  local dir fakebin log out
  dir="$TMP_ROOT/primary-launcher"; fakebin=$(fm_fakebin "$dir/fake")
  mkdir -p "$dir/home/state"; log="$dir/launch.log"
  cat > "$fakebin/kiro-cli" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'kiro-cli 2.22.1\n'; exit 0; fi
printf 'args=' >> "$FM_PRIMARY_KIRO_LOG"
printf ' <%s>' "$@" >> "$FM_PRIMARY_KIRO_LOG"
printf '\nhome=%s\ndata=%s\nlog=%s\n'   "${KIRO_HOME:-}" "${KIRO_DATA_DIR:-}" "${KIRO_CHAT_LOG_FILE:-}"   >> "$FM_PRIMARY_KIRO_LOG"
SH
  chmod +x "$fakebin/kiro-cli"
  PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home"     FM_PRIMARY_KIRO_LOG="$log" "$ROOT/bin/fm-kiro-primary.sh" --model auto
  assert_grep 'args= <chat> <--v3> <-a> <--agent> <firstmate-kiro> <--model> <auto>' "$log"     "primary launcher did not default to the trusted, tracked project-scoped V3 agent"
  assert_grep "home=$dir/home/state/.kiro-primary-home" "$log"     "primary launcher did not use its persistent isolated home"
  assert_grep '"chat.enableKnowledge": false'     "$dir/home/state/.kiro-primary-home/settings/cli.json"     "primary home did not disable knowledge"
  mkdir -p "$dir/home/state/.kiro-primary-home/sessions"
  printf 'keep\n' > "$dir/home/state/.kiro-primary-home/sessions/preserved"
  : > "$log"
  PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home"     FM_PRIMARY_KIRO_LOG="$log" "$ROOT/bin/fm-kiro-primary.sh" --v2
  assert_grep 'args= <chat> <--v2> <--trust-all-tools> <--agent> <firstmate-kiro-v2>' "$log"     "primary launcher's explicit V2 fallback lost its legacy trust or agent"
  assert_present "$dir/home/state/.kiro-primary-home/sessions/preserved"     "relaunch rewrote the persistent primary home instead of preserving sessions"
  out=$(PATH="$fakebin:$BASE_PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home"     FM_PRIMARY_KIRO_LOG="$log" "$ROOT/bin/fm-kiro-primary.sh" --agent other 2>&1) &&     fail "primary launcher accepted a caller-supplied agent: $out"
  assert_contains "$out" 'owned by fm-kiro-primary.sh'     "primary launcher did not explain its fixed agent boundary"
  pass "fm-kiro-primary: V3 is default, V2 explicit, and the isolated home persists"
}

test_kiro_secondmate_uses_v3_project_scope_and_isolated_home() {
  local id rec mate out rc launch
  id="kiro-secondmate-v3-z11-$$"
  rec=$(make_kiro_spawn_case secondmate-v3 "$id")
  read_kiro_spawn_record "$rec"
  mate="$CASE_DIR/mate"
  git clone -q "$ROOT" "$CASE_DIR/mate-base"
  git -C "$CASE_DIR/mate-base" worktree add -q --detach "$mate" HEAD
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR"     FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data"     FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config"     FM_SKIP_SECONDMATE_INHERIT=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SPAWN_NO_GUARD=1     FM_FAKE_PANE_PATH="$mate" TMUX="fake,1,0"     FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_POINTER_LOG="$CASE_DIR/pointer.log"     FM_FAKE_KIRO_STATE="$CASE_DIR/kiro.state" FM_FAKE_KIRO_TRUST_ENTER_LOG="$CASE_DIR/trust-enter.log"     FM_FAKE_KIRO_TRUST=suppressed FM_FAKE_KIRO_READY=yes     FM_FAKE_TMUX_VISIBLE_FAILS=no FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log"     FM_FAKE_TMUX_KILLED="$CASE_DIR/tmux-killed" FM_KIRO_READY_POLLS=3 FM_KIRO_POLL_INTERVAL=0     PATH="$FAKEBIN_DIR:$BASE_PATH"     "$SPAWN" "$id" "$mate" --harness kiro-cli --secondmate 2>&1); rc=$?
  expect_code 0 "$rc" "Kiro secondmate spawn should succeed"$'\n'"$out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "chat --v3 -a --agent 'firstmate-kiro-$id'"     "secondmate did not launch trusted through its task-specific V3 project agent"
  assert_present "$mate/.kiro/agents/firstmate-kiro-$id.json"     "secondmate home lacks its project-scoped V3 agent"
  assert_present "$mate/.kiro/hooks/fm-firstmate-$id.json"     "secondmate home lacks its project-scoped V3 hook"
  assert_grep '"chat.enableKnowledge": false'     "$HOME_DIR/state/$id.kiro-home/settings/cli.json"     "secondmate Kiro home did not disable knowledge"
  assert_grep 'kind=secondmate' "$HOME_DIR/state/$id.meta"     "successful Kiro launch did not record secondmate kind"
  pass "fm-spawn: Kiro secondmate uses V3 project scope plus an isolated knowledge-disabled home"
}

test_kiro_missing_binary_refuses_before_pane_creation() {
  local id rec out rc sans_path
  id="kiro-missing-z10-$$"
  rec=$(make_kiro_spawn_case missing "$id")
  read_kiro_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kiro-cli"
  # A dev host commonly has a real kiro-cli on BASE_PATH (~/.local/bin), which
  # would defeat the "binary absent" simulation; hide only kiro-cli.
  sans_path=$(fm_test_base_path_sans "$BASE_PATH" kiro-cli)
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" \
    PATH="$FAKEBIN_DIR:$sans_path" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness kiro-cli --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a missing kiro-cli executable should refuse the spawn"
  assert_contains "$out" "kiro-cli executable not found on PATH" "missing kiro-cli diagnostic lacked its concrete reason"
  assert_contains "$out" "NOT the /usr/bin/kiro" "the diagnostic must warn against the Electron IDE"
  [ -s "$CASE_DIR/launch.log" ] && fail "a missing kiro-cli executable created a launch command" || true
  pass "fm-spawn: a missing kiro-cli executable refuses before pane creation and names the IDE hazard"
}

test_kiro_secondmate_is_supported() {
  # kiro-cli carries a verified primary supervision protocol, so a secondmate
  # launch must be ACCEPTED (never refused the way muse/gemini/agy are). The
  # spawn is expected to proceed into launch composition; it is stopped by a
  # missing binary here so the case never needs a live pane, while still proving
  # the kind gate let it through.
  local id rec out rc sans_path
  id="kiro-secondmate-z11-$$"
  rec=$(make_kiro_spawn_case secondmate-ok "$id")
  read_kiro_spawn_record "$rec"
  rm "$FAKEBIN_DIR/kiro-cli"
  sans_path=$(fm_test_base_path_sans "$BASE_PATH" kiro-cli)
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$sans_path" \
    "$SPAWN" "$id" --secondmate kiro-cli 2>&1) || rc=$?
  assert_not_contains "$out" "crewmate/scout adapter only" \
    "kiro-cli must not be refused as a crewmate/scout-only adapter; it has a primary supervision protocol"
  pass "fm-spawn: kiro-cli is accepted as a secondmate harness"
}

test_kiro_refuses_outside_an_isolated_worktree() {
  # Point the fake pane at the spawning project itself so the worktree
  # isolation assertion must refuse rather than tangle the primary checkout.
  local id rec out rc
  id="kiro-isolation-z12-$$"
  rec=$(make_kiro_spawn_case isolation "$id")
  read_kiro_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$PROJ_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness kiro-cli --mode no-mistakes --yolo off 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a spawn that never reaches an isolated worktree must refuse"
  assert_contains "$out" "isolated worktree" "the refusal must name the isolation requirement"
  [ -s "$CASE_DIR/launch.log" ] && fail "an un-isolated spawn must not compose a launch command" || true
  pass "fm-spawn: kiro-cli refuses to launch outside an isolated worktree"
}

# --- teardown ---------------------------------------------------------------

test_kiro_teardown_removes_every_artifact() {
  local id rec kh
  id="kiro-teardown-z13-$$"
  rec=$(make_kiro_spawn_case teardown "$id")
  read_kiro_spawn_record "$rec"
  run_kiro_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --model auto >/dev/null 2>&1
  kh="$HOME_DIR/state/$id.kiro-home"
  assert_present "$kh" "spawn must create the per-task KIRO_HOME before teardown"
  assert_present "$WT_DIR/.kiro/agents/firstmate-kiro-$id.json" "spawn must create its V3 project agent copy"
  assert_present "$WT_DIR/.kiro/hooks/fm-firstmate-$id.json" "spawn must create its V3 project hook copy"
  [ -f "$WT_DIR/.kiro/agents/firstmate-kiro-$id.json" ] && [ ! -L "$WT_DIR/.kiro/agents/firstmate-kiro-$id.json" ] || fail "teardown fixture must use a regular isolated-home agent copy"
  [ -f "$WT_DIR/.kiro/hooks/fm-firstmate-$id.json" ] && [ ! -L "$WT_DIR/.kiro/hooks/fm-firstmate-$id.json" ] || fail "teardown fixture must use a regular isolated-home hook copy"
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" FM_FAKE_TMUX_KILLED="$CASE_DIR/tmux-killed" \
    PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$TEARDOWN" "$id" >/dev/null 2>&1 || fail "teardown of an idle kiro-cli task should succeed"
  assert_absent "$kh" "teardown must remove the per-task KIRO_HOME directory"
  assert_absent "$HOME_DIR/state/$id.kiro-turnend-token" "teardown must remove the state token"
  assert_absent "$WT_DIR/.kiro/agents/firstmate-kiro-$id.json" "teardown must remove the V3 project agent"
  assert_absent "$WT_DIR/.kiro/hooks/fm-firstmate-$id.json" "teardown must remove the V3 project hook"
  assert_absent "$HOME_DIR/state/$id.meta" "teardown must remove the task record"
  pass "fm-spawn+fm-teardown: a full kiro-cli cycle removes every artifact"
}

test_kiro_teardown_does_not_treat_the_pointer_as_unlanded_work() {
  # The .fm-kiro-turnend pointer is an untracked firstmate file; teardown must
  # exclude it from the dirty check so it is not mistaken for unlanded work.
  local out
  out=$(bash -c '
    dirty_raw="?? .fm-kiro-turnend"
    printf "%s\n" "$dirty_raw" | grep -vE "^\?\? (\.claude/|\.fm-(grok|kimi|kiro)-turnend\$)" | head -1')
  [ -z "$out" ] || fail ".fm-kiro-turnend must be excluded from the dirty check, but survived: '$out'"
  # A genuinely dirty file still survives the same exclusion.
  out=$(bash -c '
    dirty_raw="?? src/real-change.ts"
    printf "%s\n" "$dirty_raw" | grep -vE "^\?\? (\.claude/|\.fm-(grok|kimi|kiro)-turnend\$)" | head -1')
  assert_contains "$out" "src/real-change.ts" "a genuine untracked change must still be seen as unlanded work"
  pass "fm-teardown: the .fm-kiro-turnend pointer is excluded from the unlanded-work dirty check"
}

test_kiro_ancestry_detects_the_native_and_inner_command_names
test_kiro_ancestry_rejects_unrelated_mentions
test_kiro_env_family_does_not_claim_identity_and_ancestry_outranks_claudecode
test_kiro_is_in_the_session_lock_vocabulary
test_kiro_control_mechanics_are_the_verified_ones
test_kiro_control_wiring_and_token_paths
test_kiro_idle_placeholder_is_exact_and_harness_scoped
test_kiro_busy_tail_needs_a_pinned_anchor
test_kiro_busy_signatures_are_harness_scoped
test_kiro_classify_busy_on_anchor_unknown_when_scrolled_out
test_kiro_semantic_busy_source_is_registered
test_kiro_hooks_drive_semantic_busy_idle_and_progress
test_kiro_launch_is_the_interactive_tui_with_brief_model_effort_and_scope
test_kiro_trust_dialog_refuses_without_answering
test_kiro_trust_decoy_does_not_block_the_launch
test_kiro_predicates_require_the_complete_signals
test_kiro_launch_gate_refuses_a_dead_pane
test_kiro_unreadable_viewport_fails_loudly
test_kiro_turn_end_wiring_lands_in_a_per_task_kiro_home
test_kiro_guarded_hook_touches_turn_ended_only_on_a_matching_pointer
test_kiro_primary_rearm_stands_down_outside_primary_scope
test_every_firstmate_kiro_hook_command_works_from_any_folder_without_launch_env
test_kiro_resumed_worker_hooks_bind_only_through_the_recorded_session
test_kiro_resumed_primary_retakes_a_dead_lock_and_stop_returns_promptly
test_kiro_effort_xhigh_and_max_ride_the_launch
test_kiro_v2_is_only_an_explicit_compatibility_fallback
test_kiro_v3_project_files_are_regular_copies_and_refuse_different_existing
test_kiro_v3_agents_grant_concrete_tools_never_a_wildcard
test_kiro_primary_launcher_defaults_v3_and_persists_its_home
test_kiro_secondmate_uses_v3_project_scope_and_isolated_home
test_kiro_missing_binary_refuses_before_pane_creation
test_kiro_secondmate_is_supported
test_kiro_refuses_outside_an_isolated_worktree
test_kiro_teardown_removes_every_artifact
test_kiro_teardown_does_not_treat_the_pointer_as_unlanded_work
