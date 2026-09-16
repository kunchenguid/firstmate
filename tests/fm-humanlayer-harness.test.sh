#!/usr/bin/env bash
# Behavior tests for the verified HumanLayer CLI (codelayer) crewmate/scout
# adapter.
#
# The facts pinned here are the ones a humanlayer release could silently
# change and the ones a wrong guess would make dangerous:
#   1. humanlayer publishes no harness-identity marker of its own, and its
#      tool children inherit the launching environment unchanged, so
#      detection is ancestry alone: the native child's anchored process name
#      `humanlayer` at comm strength, the node shim through its script path
#      at args strength, and a structural humanlayer ancestor outranking a
#      retained foreign marker.
#   2. The anchored matches must never claim unrelated commands containing
#      the fragment.
#   3. There is no interactive launch flag that carries a prompt (--prompt
#      runs non-interactively and exits at turn end), so the launch is BARE
#      and the brief pointer is submitted after a readiness gate and a
#      delivery gate - the kimi/rovo launch-then-confirm shape.
#   4. bin/fm-humanlayer-lib.sh owns the provenance-aware idle classifier
#      and tool-descendant busy proof; transcript-shaped drafts must never
#      authorize steering or interruption.
#   5. humanlayer is a crewmate/scout adapter only: a secondmate launch is
#      refused, and nothing is armed as busy wiring because no writer could
#      clear it.
#   6. The control plane's verified mechanics: a single Ctrl+C interrupts a
#      running turn and the same key exits at the idle composer, so the exit
#      entry is a KEY, not a composer command, and Escape is not the
#      interrupt key.
#   7. Effort maps low|medium|high|xhigh onto --thinking; max is known-bad
#      and must be omitted rather than passed (record-and-omit).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the
# asserted verdict does not depend on which harness launched the suite.
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
TMP_ROOT=$(fm_test_tmproot fm-humanlayer-harness)

# --- detection --------------------------------------------------------------

test_humanlayer_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/someone/.local/lib/node_modules/@humanlayer/cli/node_modules/@humanlayer/cli-darwin-arm64/bin/humanlayer'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /Users/someone/.local/bin/humanlayer codelayer --provider codex'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = humanlayer ] \
    || fail "the natively-named humanlayer child must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named humanlayer child at comm strength"
}

test_humanlayer_args_arm_detects_the_node_shim() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-shim")
  # A bare interpreter whose script path names humanlayer is the node shim's
  # signature: matched only at args strength, and only when no marker exists.
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' 'node'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /Users/someone/.local/bin/humanlayer codelayer --provider codex'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = humanlayer ] \
    || fail "the node shim's humanlayer script path must be detected at args strength, got '$out'"
  pass "fm-harness.sh: the interpreter args arm detects the humanlayer node shim"
}

test_humanlayer_ancestry_rejects_unrelated_mentions() {
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

  out=$(FAKE_PS_COMM=humanlayerish FAKE_PS_ARGS='humanlayerish --serve' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != humanlayer ] \
    || fail "an unrelated humanlayerish command must not detect humanlayer, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo humanlayer --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != humanlayer ] \
    || fail "a later shell argument naming humanlayer must not detect humanlayer, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated humanlayer mentions"
}

test_humanlayer_structural_ancestor_outranks_a_retained_marker() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-marker")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/someone/.local/lib/node_modules/@humanlayer/cli/node_modules/@humanlayer/cli-darwin-arm64/bin/humanlayer'; exit 0 ;;
  *"args="*) printf '%s\n' 'node /Users/someone/.local/bin/humanlayer codelayer'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  # humanlayer does not clear an inherited CLAUDECODE (verified live: its tool
  # children carried the launcher's markers unchanged), so a structural
  # humanlayer ancestor must outrank the retained marker rather than the
  # marker renaming the worker claude.
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = humanlayer ] \
    || fail "a structural humanlayer ancestor must outrank a retained CLAUDECODE, got '$out'"
  pass "fm-harness.sh: a structural humanlayer ancestor outranks a retained foreign marker"
}

# --- control tables ---------------------------------------------------------

test_humanlayer_control_tables() {
  local out
  out=$(fm_control_interrupt_key humanlayer)
  [ "$out" = C-c ] || fail "humanlayer's verified interrupt key is C-c, got '$out'"
  out=$(fm_control_interrupt_repeat humanlayer)
  [ "$out" = 1 ] || fail "humanlayer interrupts on a single press, got '$out'"
  out=$(fm_control_interrupt_clear_key humanlayer)
  [ -z "$out" ] || fail "humanlayer does not repollute its composer after an interrupt, got clear key '$out'"
  out=$(fm_control_interrupt_ack_source humanlayer)
  [ "$out" = none ] || fail "humanlayer has no adapter-owned cancellation ack, got '$out'"
  fm_control_exit_command humanlayer >/dev/null 2>&1 \
    && fail "humanlayer must refuse a typed exit command: /quit and /exit reach the model as chat"
  out=$(fm_control_exit_key humanlayer)
  [ "$out" = C-c ] || fail "humanlayer's verified exit is the C-c key at the idle composer, got '$out'"
  fm_control_harness_supported humanlayer \
    || fail "humanlayer must be a supported control-plane harness"
  out=$(fm_control_harness_family humanlayer)
  [ "$out" = humanlayer ] || fail "humanlayer's family is the exact adapter name, got '$out'"
  fm_control_harness_supports_kind humanlayer ship \
    || fail "humanlayer must support ship work"
  fm_control_harness_supports_kind humanlayer secondmate \
    && fail "humanlayer must refuse secondmate work: it has no primary supervision protocol"
  pass "control-lib: humanlayer's interrupt is C-c, its exit is a key not a command, and it refuses secondmates"
}

# --- busy anchor classification ---------------------------------------------

# fm_busy_classify <backend> <target> <harness> <id> <state-dir> [tail40]
HL_STATE="$TMP_ROOT/state"
mkdir -p "$HL_STATE"

test_humanlayer_anchor_classifies_idle_busy_unknown() {
  local verdict tail_idle tail_tool tail_echo tail_blank
  tail_idle=$(printf '\033[38;2;34;197;94m[Done]\033[39m complete\n'; cat <<'EOF'
  Model            Input   Output     Cost             Context
  gpt-6-astra      5,534        13   ~$0.06  5,542/258,400 (2%)
>
EOF
)
  tail_tool=$(cat <<'EOF'
> Run: sleep 30
[Tool] bash call_id=call_x agent=root depth=0 command=sleep 30
EOF
)
  tail_echo='> Read the brief at /tmp/brief.md and follow it exactly.'
  tail_blank='   
   '
  # Idle: the bare `>` composer row is the bottom-most non-blank row, above
  # transcript history that persists from earlier turns.
  verdict=$(fm_busy_classify tmux 'win:0' humanlayer hl-test "$HL_STATE" "$tail_idle")
  [ "${verdict%% *}" = idle ] || fail "a bare-> bottom row must classify idle, got '$verdict'"
  [ "${verdict#* }" = humanlayer-anchor ] || fail "the idle verdict must name its humanlayer-anchor source, got '$verdict'"

  verdict=$(fm_busy_classify tmux 'win:0' humanlayer hl-test "$HL_STATE" "$tail_tool")
  [ "${verdict%% *}" = unknown ] || fail "a tool-shaped row without input provenance must stay unknown, got '$verdict'"

  verdict=$(fm_busy_classify tmux 'win:0' humanlayer hl-test "$HL_STATE" "$tail_echo")
  [ "${verdict%% *}" = unknown ] || fail "a prompt echo without output must stay unknown, got '$verdict'"

  # Unknown: a blank or unreadable capture is never idle.
  verdict=$(fm_busy_classify tmux 'win:0' humanlayer hl-test "$HL_STATE" "$tail_blank")
  [ "${verdict%% *}" = unknown ] || fail "a blank capture must stay unknown, got '$verdict'"
  local content
  for content in '[Done] complete' '[Tool] bash command=sleep 30' '[Assistant] example' 'wrapped draft'; do
    verdict=$(printf '>\n> Investigate this log:\n%s\n\n  \n' "$content" | fm_humanlayer_screen_state)
    [ "$verdict" = unknown ] || fail "a content tail must not classify idle: $content"
    verdict=$(printf '> Investigate this log:\n%s\n>\n\n' "$content" | fm_humanlayer_screen_state)
    [ "$verdict" = unknown ] || fail "a literal > continuation must remain unsafe: $content"
  done
  local separator
  for separator in '' $'\n' $'\n  \n'; do
    verdict=$(printf '[codex-provider] using sse transport for model gpt-6-astra\ncodelayer - provider: codex, model: gpt-6-astra\n%s>\n' "$separator" | fm_humanlayer_screen_state)
    [ "$verdict" = idle ] || fail "fresh provider banners with blank separators must read idle"
    verdict=$(printf '[codex-provider] using sse transport for model gpt-6-astra\ncodelayer - provider: codex, model: gpt-6-astra\n%sdraft content\n>\n' "$separator" | fm_humanlayer_screen_state)
    [ "$verdict" = unknown ] || fail "content between startup banners and composer must remain unsafe"
  done
  local color
  for color in '34;197;94' '239;68;68' '234;179;8'; do
    verdict=$(printf '> prior prompt\n\033[38;2;%sm[Done]\033[39m complete\n>\n' "$color" | fm_humanlayer_screen_state)
    [ "$verdict" = idle ] || fail "styled completion must retire submitted history: $color"
    # The herdr ANSI dialect (verified live on a real settled herdr pane):
    # a leading SGR reset run precedes the color code, the reset after the
    # [Done] token is ESC[0m, and rows carry CR line endings. The fold must
    # accept it exactly as it accepts tmux's, or a settled herdr pane reads
    # unknown forever (the sandbox-reported gap).
    verdict=$(printf '> prior prompt\r\n\033[0m\033[38;2;%sm[Done]\033[0m complete\r\n> \r\n' "$color" | fm_humanlayer_screen_state)
    [ "$verdict" = idle ] || fail "the herdr completion dialect must retire submitted history: $color"
  done
  # CRLF-terminated herdr-style captures with the two completion shapes the
  # sandbox verification called out: the assistant row carrying a Done: text
  # body and the standalone [Done] row, both followed by the usage footer and
  # the bare > composer. CR stripping must be explicit, because whether CR
  # counts as [[:space:]] varies by awk implementation and locale.
  verdict=$(printf "[Assistant] Done: ready in branch.\r\n\033[0m\033[38;2;34;197;94m[Done]\033[0m complete\r\n  Model  Input  Cost\r\n  gpt-6-astra  1  ~\$0.01\r\n> \r\n" | fm_humanlayer_screen_state)
  [ "$verdict" = idle ] || fail "a CRLF herdr capture with a Done: assistant body must read idle"
  verdict=$(printf '> Investigate this log:\r\n[Tool] bash command=sleep 30\r\n' | fm_humanlayer_screen_state)
  [ "$verdict" = unknown ] || fail "a CRLF herdr capture mid-turn must not read idle"
  verdict=$(printf '> Investigate this log:\r\n\033[0m\033[38;2;34;197;94m[Done]\033[0m complete\r\n\r\n> \r\nextra output\r\n' | fm_humanlayer_screen_state)
  [ "$verdict" = unknown ] || fail "a CRLF herdr draft trailing a pasted completion must stay unsafe"
  verdict=$(printf '>\n[Done] complete\n>\n' | fm_humanlayer_screen_state)
  [ "$verdict" = unknown ] || fail "a draft with an empty first line must remain unsafe"
  pass "busy-lib: the humanlayer anchor classifies idle, busy, and unknown from the pinned composer row"
}

test_humanlayer_anchor_tolerates_trailing_whitespace_only() {
  local verdict
  verdict=$(fm_busy_classify tmux 'win:0' humanlayer hl-test "$HL_STATE" '>   ')
  [ "${verdict%% *}" = idle ] || fail "a bare-> row with trailing whitespace must still read idle, got '$verdict'"
  pass "busy-lib: the humanlayer idle anchor tolerates trailing whitespace"
}

# --- delivery guard ---------------------------------------------------------

test_humanlayer_delivery_guard_refuses_ambiguous_output() {
  local rc
  # Idle tail (bare `>` last) must NOT acknowledge a submit as busy.
  printf '[Done] complete\n\n>\n' | fm_busy_lines_match humanlayer \
    && fail "an idle bare-gt tail must not read busy through the humanlayer delivery guard"
  printf '> Run: sleep 30\n[Tool] bash command=sleep 30\n' | fm_busy_lines_match humanlayer \
    && fail "a pasted tool-shaped tail must not authorize a busy verdict"
  printf '> Read the brief and follow it exactly.\n' | fm_busy_lines_match humanlayer \
    && fail "a typed composer tail must not read busy through the humanlayer delivery guard"
  # The explicit FM_BUSY_REGEX override still wins over the anchor arm.
  rc=0
  printf '>\n' | FM_BUSY_REGEX='plugh' fm_busy_lines_match humanlayer || rc=$?
  [ "$rc" -ne 0 ] || fail "the FM_BUSY_REGEX override must take precedence over the humanlayer anchor"
  pass "composer-lib: the humanlayer delivery guard refuses ambiguous output and honors FM_BUSY_REGEX"
}

# --- spawn ------------------------------------------------------------------

# A stateful fake tmux for humanlayer's launch-then-send shape (the same shape
# kimi and rovo use): the TUI launches bare and only receives an absolute brief
# pointer after a readiness gate, then a delivery gate. This fake renders a
# humanlayer-shaped screen that advances through launched -> ready ->
# pointer-typed -> delivered as the real spawn drives it, so the launch
# command, the typed pointer, and both gates are exercised through their real
# code paths rather than asserted from static text.
make_humanlayer_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
state=$(cat "$FM_FAKE_HL_STATE" 2>/dev/null || true)
fake_screen() {
  case "$state" in
    ready)
      printf '[codex-provider] using sse transport for model gpt-6-astra\ncodelayer - provider: codex, model: gpt-6-astra\n>\n'
      ;;
    pointer-typed)
      printf '[codex-provider] using sse transport for model gpt-6-astra\ncodelayer - provider: codex, model: gpt-6-astra\n> Read the brief and follow it\n'
      ;;
    scrolled)
      printf '[Tool] bash command=running\n'
      ;;
    delivered)
      printf '[codex-provider] using sse transport for model gpt-6-astra\n> Read the brief at %s and follow it exactly.\n[Tool] bash call_id=call_x agent=root depth=0 command=echo started\n' "$FM_FAKE_BRIEF_REAL"
      if [ -n "${FM_FAKE_HL_SCROLL:-}" ]; then
        for ((row=0; row<500; row++)); do printf 'tool output %s\n' "$row"; done
      fi
      ;;
    *)
      printf 'shell starting\n$ \n'
      ;;
  esac
}
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '3\n'; exit 0 ;;
esac
case "${1:-}" in
  pipe-pane)
    if [ "$2" = -O ]; then printf '%s' "${!#}" > "$FM_FAKE_HL_STATE.pipe"; else rm -f "$FM_FAKE_HL_STATE.pipe"; fi
    exit 0 ;;
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    literal=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then literal=$arg; break; fi
      prev=$arg
    done
    if [ -n "$literal" ]; then
      case "$literal" in
        *'codelayer --provider codex'*)
          printf '%s\n' "$literal" >> "$FM_FAKE_LAUNCH_LOG"
          printf 'launched\n' > "$FM_FAKE_HL_STATE"
          ;;
        *)
          printf '%s\n' "$literal" >> "$FM_FAKE_POINTER_LOG"
          printf 'pointer-typed\n' > "$FM_FAKE_HL_STATE"
          ;;
      esac
      exit 0
    fi
    case " $* " in
      *' Enter '*)
        case "$state" in
          launched)
            if [ "${FM_FAKE_HL_READY:-yes}" = yes ]; then
              printf 'ready\n' > "$FM_FAKE_HL_STATE"
            fi
            ;;
          pointer-typed)
            if [ "${FM_FAKE_HL_DELIVERY:-yes}" = yes ]; then
              printf 'delivered\n' > "$FM_FAKE_HL_STATE"
              state=delivered
              if [ -f "$FM_FAKE_HL_STATE.pipe" ]; then fake_screen | bash -c "$(cat "$FM_FAKE_HL_STATE.pipe")"; fi
            elif [ "${FM_FAKE_HL_DELIVERY:-yes}" != swallowed ]; then
              printf 'ready\n' > "$FM_FAKE_HL_STATE"
            fi
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
    if [ "$state" = delivered ] && [ -n "${FM_FAKE_HL_SCROLL:-}" ]; then
      if [ "$start" = - ]; then
        fake_screen
      else
        fake_screen | tail -n "${start#-}"
      fi
      if [ "$FM_FAKE_HL_SCROLL" = after ]; then printf 'scrolled\n' > "$FM_FAKE_HL_STATE"; fi
      exit 0
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
  fm_fake_exit0 "$fakebin" humanlayer
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_humanlayer_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise HumanLayer dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'humanlayer\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/pointer.log"
  : > "$case_dir/hl.state"
  : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

run_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_POINTER_LOG="$case_dir/pointer.log" \
    FM_FAKE_HL_STATE="$case_dir/hl.state" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_BRIEF_REAL="$(cd "$home/data/$id" && pwd -P)/launch-brief.md" \
    FM_FAKE_HL_SCROLL="${FM_FAKE_HL_SCROLL:-}" \
    FM_FAKE_HL_READY="${FM_FAKE_HL_READY:-yes}" \
    FM_FAKE_HL_DELIVERY="${FM_FAKE_HL_DELIVERY:-yes}" \
    FM_HUMANLAYER_READY_POLLS=3 FM_HUMANLAYER_DELIVERY_POLLS=3 FM_HUMANLAYER_POLL_INTERVAL=0 \
    PATH="$fakebin:$BASE_PATH" \
    "$SPAWN" "$id" "$proj" --harness humanlayer --mode no-mistakes --yolo off "$@" 2>&1
}

test_humanlayer_launch_then_send_is_verified() {
  local id rec out rc launch pointer brief_real meta
  id="hl-success-z1-$$"
  rec=$(make_spawn_case success "$id")
  read_spawn_record "$rec"
  out=$(run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model gpt-6-astra --effort high)
  rc=$?
  expect_code 0 "$rc" "verified humanlayer launch-then-send should succeed"
  assert_contains "$out" "spawned $id harness=humanlayer" "humanlayer spawn did not report success"

  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "humanlayer' codelayer --provider codex" \
    "humanlayer launch did not use the resolved binary with the verified codelayer provider"
  assert_not_contains "$launch" "encode launch-brief" "humanlayer launch carried a positional brief instead of launching bare"
  assert_contains "$launch" "--model 'gpt-6-astra'" "humanlayer launch omitted the requested model"
  assert_contains "$launch" "--thinking 'high'" "humanlayer launch omitted the requested effort"
  assert_contains "$launch" "env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS" \
    "humanlayer launch did not clear foreign primary markers"
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS" \
    "humanlayer launch did not clear cursor's markers via the shared outer wrap"
  assert_not_contains "$launch" "turn-ended" "humanlayer launch embedded a turn-end path it does not own"
  assert_not_contains "$launch" "__HLBIN__" "humanlayer launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "humanlayer launch left its model placeholder unsubstituted"
  assert_not_contains "$launch" "__EFFORTFLAG__" "humanlayer launch left its effort placeholder unsubstituted"

  # Execute the generated launch in a retained terminal, as relaunch does.
  # The fake worker exits immediately; its replacement composer is emitted
  # after it so this checks terminal state, not launch-command spelling.
  if command -v tmux >/dev/null 2>&1; then
    local socket screen verdict
    socket="hl-relaunch-$$"
    printf 'printf "> stale shell prompt\\n"\nbash %q\nprintf ">\\n"\nsleep 10\n' \
      "$CASE_DIR/launch.log" > "$CASE_DIR/relaunch.sh"
    tmux -L "$socket" new-session -d -s regression "bash '$CASE_DIR/relaunch.sh'" \
      || fail "could not start relaunch terminal"
    sleep 1
    screen=$(tmux -L "$socket" capture-pane -e -p -J -t regression -S -)
    tmux -L "$socket" kill-server
    verdict=$(printf '%s' "$screen" | fm_humanlayer_screen_state)
    [ "$verdict" = idle ] || fail "replacement composer inherited prior-process draft history: $verdict"
  fi

  brief_real="$(cd "$HOME_DIR/data/$id" && pwd -P)/launch-brief.md"
  pointer=$(cat "$CASE_DIR/pointer.log")
  [ "$pointer" = "Read the brief at $brief_real and follow it exactly." ] \
    || fail "humanlayer pointer was not the exact absolute-path-only instruction: $pointer"

  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=humanlayer' "$meta" "humanlayer meta did not record its harness"
  assert_grep 'model=gpt-6-astra' "$meta" "humanlayer meta lost the requested model"
  assert_grep 'effort=high' "$meta" "humanlayer meta lost the requested effort"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "kill-window" \
    "a successful humanlayer spawn must never tear down the endpoint it just delivered into"
  pass "fm-spawn: humanlayer launches bare with the codex provider, waits for readiness, and delivers its brief pointer"
}

test_humanlayer_effort_max_is_recorded_but_omitted() {
  local id rec out rc launch meta
  id="hl-max-z2-$$"
  rec=$(make_spawn_case max "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort max)
  rc=$?
  expect_code 0 "$rc" "humanlayer spawn with a known-bad effort should still succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "--thinking max" "humanlayer launch passed the known-bad max effort value"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=max' "$meta" "humanlayer meta did not retain the unsupported effort axis"
  pass "fm-spawn: humanlayer omits max from the launch but records it in task metadata"
}

test_humanlayer_effort_xhigh_maps_to_thinking() {
  local id rec out rc launch meta
  id="hl-xhigh-z3-$$"
  rec=$(make_spawn_case xhigh "$id")
  read_spawn_record "$rec"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "humanlayer spawn with xhigh effort should succeed"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "--thinking 'xhigh'" "humanlayer launch did not map xhigh onto --thinking"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "humanlayer meta lost the requested effort"
  pass "fm-spawn: humanlayer maps xhigh onto --thinking, which the provider accepts"
}

test_humanlayer_never_ready_refuses_and_cleans_up() {
  local id rec out rc
  id="hl-notready-z4-$$"
  rec=$(make_spawn_case notready "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_HL_READY=no run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "a humanlayer TUI that never shows its ready signal must fail the spawn"
  assert_contains "$out" "did not show a verified ready signal" \
    "the readiness refusal did not name its reason"
  assert_grep 'failed: humanlayer did not show a verified ready signal' "$HOME_DIR/state/$id.status" \
    "humanlayer readiness failure did not leave a supervisor-visible failure"
  [ ! -s "$CASE_DIR/pointer.log" ] || fail "humanlayer pointer was sent before an observable ready signal"
  grep -q "kill-window.*fm-$id" "$CASE_DIR/tmux-calls.log" \
    || fail "a failed humanlayer spawn must tear down the exact endpoint it created instead of leaking an orphaned process"
  pass "fm-spawn: humanlayer never sends the brief pointer before an observable ready signal, and tears down the created endpoint on failure"
}

test_humanlayer_unconfirmed_delivery_refuses_and_cleans_up() {
  local id rec out rc
  id="hl-nodelivery-z5-$$"
  rec=$(make_spawn_case "nodelivery-${FM_FAKE_HL_DELIVERY:-no}" "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(FM_FAKE_HL_DELIVERY=${FM_FAKE_HL_DELIVERY:-no} run_spawn \
    "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
  [ "$rc" -ne 0 ] || fail "an unconfirmed humanlayer brief delivery must fail the spawn"
  assert_contains "$out" "delivery was not confirmed" \
    "the delivery refusal did not name its reason"
  assert_grep 'failed: humanlayer brief pointer delivery was not confirmed' "$HOME_DIR/state/$id.status" \
    "humanlayer delivery failure did not leave a supervisor-visible failure"
  grep -q "kill-window.*fm-$id" "$CASE_DIR/tmux-calls.log" \
    || fail "a failed humanlayer spawn must tear down the exact endpoint it created instead of leaking an orphaned process"
  pass "fm-spawn: humanlayer refuses loudly when brief delivery cannot be confirmed, and tears down the created endpoint"
}

test_humanlayer_missing_binary_refuses_before_pane_creation() {
  local id rec out rc bare_fakebin case_dir home proj wt
  id="hl-nobin-z6-$$"
  rec=$(make_spawn_case nobin "$id")
  read_spawn_record "$rec"
  # Strip humanlayer from the fake PATH so resolution fails the way a missing
  # install does, before any pane is created.
  bare_fakebin="$TMP_ROOT/nobin/bare-fake"
  mkdir -p "$bare_fakebin"
  cp "$FAKEBIN_DIR/tmux" "$bare_fakebin/tmux" 2>/dev/null || true
  for tool in treehouse gh-axi gh; do
    [ -e "$FAKEBIN_DIR/$tool" ] && cp "$FAKEBIN_DIR/$tool" "$bare_fakebin/$tool"
  done
  chmod +x "$bare_fakebin"/* 2>/dev/null || true
  HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    PATH="$bare_fakebin:$BASE_PATH" \
    out=$("$SPAWN" "$id" "$PROJ_DIR" --harness humanlayer --mode no-mistakes --yolo off 2>&1)
  rc=$?
  expect_code 1 "$rc" "a missing humanlayer executable must refuse the spawn"
  assert_contains "$out" "humanlayer executable not found" \
    "the missing-binary refusal did not name its reason"
  assert_not_contains "$(cat "$CASE_DIR/tmux-calls.log")" "new-window" \
    "a missing-binary refusal must refuse before any pane creation"
  pass "fm-spawn: humanlayer refuses loudly when the executable is absent"
}

# --- secondmate refusal -----------------------------------------------------

test_humanlayer_secondmate_launch_is_refused() {
  local id rec out rc
  id="hl-secondmate-z7-$$"
  rec=$(make_spawn_case secondmate "$id")
  read_spawn_record "$rec"
  rc=0
  out=$(HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN_DIR:$BASE_PATH" \
    "$SPAWN" "$id" --secondmate humanlayer 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a humanlayer secondmate spawn should be refused"
  assert_contains "$out" "humanlayer is a verified crewmate/scout adapter only" \
    "humanlayer secondmate refusal lacked its concrete reason"
  pass "fm-spawn: humanlayer cannot be launched as a secondmate, the muse/gemini/agy boundary"
}

test_humanlayer_ancestry_detects_the_native_command_name
test_humanlayer_args_arm_detects_the_node_shim
test_humanlayer_ancestry_rejects_unrelated_mentions
test_humanlayer_structural_ancestor_outranks_a_retained_marker
test_humanlayer_control_tables
test_humanlayer_anchor_classifies_idle_busy_unknown
test_humanlayer_anchor_tolerates_trailing_whitespace_only
test_humanlayer_delivery_guard_refuses_ambiguous_output
test_humanlayer_launch_then_send_is_verified
test_humanlayer_effort_max_is_recorded_but_omitted
test_humanlayer_effort_xhigh_maps_to_thinking
test_humanlayer_never_ready_refuses_and_cleans_up
test_humanlayer_unconfirmed_delivery_refuses_and_cleans_up
test_humanlayer_missing_binary_refuses_before_pane_creation
test_humanlayer_secondmate_launch_is_refused

FM_FAKE_HL_DELIVERY=swallowed test_humanlayer_unconfirmed_delivery_refuses_and_cleans_up

test_humanlayer_scrolling_delivery() {
  local mode id rec out rc
  for mode in before after; do
    id="hl-scroll-$mode-$$"
    rec=$(make_spawn_case "scroll-$mode" "$id")
    read_spawn_record "$rec"
    rc=0
    out=$(FM_FAKE_HL_SCROLL="$mode" run_spawn \
      "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id") || rc=$?
    expect_code 0 "$rc" "HumanLayer must survive scrolling $mode confirmation: $out"
    if grep -q 'kill-window' "$CASE_DIR/tmux-calls.log"; then
      fail "scrolling output must not tear down the working endpoint"
    fi
  done
  pass "HumanLayer retains delivery evidence across scrolling and honors confirmed submissions"
}
test_humanlayer_scrolling_delivery

test_humanlayer_real_process_activity() {
  local lab="$TMP_ROOT/process-activity"
  mkdir -p "$lab"
  cat > "$lab/worker.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
  (void)argv;
  pid_t child = 0;
  if (argc > 1) {
    child = fork();
    if (child < 0) return 1;
    if (child == 0) { if (setpgid(0, 0) != 0) _exit(2); execl("/bin/sleep", "sleep", "90", (char *)0); _exit(1); }
  }
  printf("%ld\n", (long)child);
  fflush(stdout);
  if (child) waitpid(child, NULL, 0);
  else pause();
  return 0;
}
C
  cc -o "$lab/humanlayer" "$lab/worker.c" || fail "could not build the process-activity fixture"
  python3 - "$ROOT" "$lab/humanlayer" <<'PYTEST' || fail "real-process HumanLayer activity checks failed"
import os
import signal
import subprocess
import sys
import time
root, executable = sys.argv[1:]
workers = []
children = []
def active(pid):
    result = subprocess.run([
        'bash', '-c', '. "$1/bin/fm-humanlayer-lib.sh"; '
        'ps -axo pid=,ppid=,pgid=,stat=,comm= | fm_humanlayer_processes_active "$2"',
        '_', root, str(pid)
    ])
    return result.returncode == 0
try:
    idle = subprocess.Popen([executable], stdout=subprocess.PIPE, text=True)
    workers.append(idle)
    assert idle.stdout.readline().strip() == '0'
    sibling = subprocess.Popen(['/bin/sleep', '90'])
    workers.append(sibling)
    assert not active(idle.pid), 'an idle worker must not borrow sibling activity'
    assert not active(sibling.pid), 'an unrelated process cannot identify HumanLayer'
    busy = subprocess.Popen([executable, 'tool'], stdout=subprocess.PIPE, text=True)
    workers.append(busy)
    child = int(busy.stdout.readline())
    children.append(child)
    deadline = time.monotonic() + 3
    while not active(busy.pid):
        assert time.monotonic() < deadline, 'the active tool must produce a busy verdict'
        time.sleep(.02)
    assert os.getpgid(child) != os.getpgid(busy.pid), 'tool must run in a separate process group'
    os.kill(child, signal.SIGTERM)
    children.remove(child)
    busy.wait(timeout=3)
    assert not active(busy.pid), 'completed tool activity must not remain busy'
finally:
    for child in children:
        try: os.kill(child, signal.SIGTERM)
        except ProcessLookupError: pass
    for worker in workers:
        if worker.poll() is None: worker.terminate()
        worker.wait(timeout=3)
PYTEST
  pass "HumanLayer activity is scoped to live tool descendants of the identified worker"
}
test_humanlayer_real_process_activity

test_humanlayer_herdr_busy_stays_unknown() {
  # herdr has no reachable busy proof: pane process-info never surfaces a
  # tool call's children and the agent registry does not register codelayer
  # (both verified against herdr 0.8.0 / humanlayer 0.31.0; the descendant
  # walk measured zero non-agent children over 60 samples of active work),
  # so the classifier must never claim busy there and supervision reads the
  # worker's status log and turn-end events instead.
  local verdict
  verdict=$(fm_busy_classify herdr 'default:whl:phl' humanlayer hl-test "$HL_STATE" \
'> Investigate this log:
[Tool] bash call_id=call_x agent=root depth=0 command=sleep 30')
  case "$verdict" in
    busy*) fail "herdr must never claim HumanLayer busy from rendered rows: $verdict" ;;
    unknown*) : ;;
    *) fail "a mid-turn herdr capture must read unknown, never idle: $verdict" ;;
  esac
  pass "herdr HumanLayer busy stays unknown; supervision reads the status log and turn-end events"
}
test_humanlayer_herdr_busy_stays_unknown
