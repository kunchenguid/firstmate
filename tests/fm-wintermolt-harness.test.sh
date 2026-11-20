#!/usr/bin/env bash
# Behavior tests for the verified Wintermolt crewmate/scout adapter.
#
# The facts pinned here are the ones a wintermolt release could silently change
# and the ones a wrong guess would make dangerous:
#   1. wintermolt publishes no harness-identity marker of its own (a live 0.7.0
#      bash tool subprocess carried only backend-config variables), so
#      detection is ancestry alone on the anchored process name `wintermolt`.
#   2. The anchored match must never claim unrelated commands containing the
#      fragment, and a structural wintermolt ancestor outranks a retained or
#      inherited CLAUDECODE - tests/fm-harness-precedence.test.sh owns the
#      general boundary.
#   3. The launch is a bare full-screen TUI with no initial-prompt argument:
#      the brief arrives as a typed absolute pointer only after a readiness
#      gate, then a delivery-confirmation gate that requires the pinned busy
#      footer. The launch pins WINTERMOLT_NO_FALLBACK=1 and carries
#      WINTERMOLT_MODEL from the model axis, never a provider-prefixed id, and
#      an effort request is recorded but omitted (no such setting exists).
#   4. wintermolt is a crewmate/scout adapter on tmux only: a secondmate launch
#      and any other backend are refused, and nothing is armed as busy wiring
#      because no writer could ever clear it.
#   5. The busy verdict is the pinned footer row alone - `Esc stop` or a
#      spinner-plus-`working` status cell ending the pane's LAST non-empty row -
#      so conversation output containing the word can never read busy, and an
#      idle or dead pane never reads busy either.
#   6. The composer is a rounded bordered box with the anchored
#      `Type a message, or /help` idle placeholder (reverse-video cursor cell
#      plus a de-emphasized palette run) and the keybind/status footer row
#      below it; the placeholder reads empty only through the wintermolt-scoped
#      rule, a draft with the same words stays pending, and the busy
#      `working…` row stays pending.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside another harness inherits those markers, which outrank the fake
# ancestry the detection cases set up. Drop the ambient markers so the asserted
# verdict does not depend on which harness launched the suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS FM_COMPOSER_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-wintermolt-harness)

# The byte-exact styled rows below are the live capture shapes verified on
# wintermolt 0.7.0 (docs/verification/wintermolt.md): the composer row opens
# with a reverse-video cursor cell on the placeholder's first character and
# carries the rest as one de-emphasized palette run, while a typed draft
# renders default-foreground text with the cursor cell AFTER it. Every box
# row is padded to the same inner width so the real composer classifier's
# geometry proof holds exactly as it does on a live pane.
WM_ESC=$'\033'
WM_INNER_WIDTH=40
wm_pad() { printf '%*s' "$1" ''; }
wm_rule_top() { printf '╭%s╮' "$(wm_pad "$WM_INNER_WIDTH" | sed 's/ /─/g')"; }
wm_rule_bottom() { printf '╰%s╯' "$(wm_pad "$WM_INNER_WIDTH" | sed 's/ /─/g')"; }
wm_transcript_top() { printf '╭─ Transcript %s╮' "$(wm_pad "$((WM_INNER_WIDTH - 13))" | sed 's/ /─/g')"; }
wm_inner_plain() {
  local text=$1 pad
  pad=$(wm_pad "$((WM_INNER_WIDTH - ${#text}))")
  printf '│%s%s│' "$pad" "$text"
}
WM_TOP="$(wm_rule_top)"
WM_BOTTOM="$(wm_rule_bottom)"
WM_IDLE_COMPOSER_RAW="│${WM_ESC}[39m  ${WM_ESC}[48;5;6mT${WM_ESC}[38;5;8m${WM_ESC}[49mype a message, or /help${WM_ESC}[39m$(wm_pad 14)${WM_ESC}[38;5;8m│"
WM_BUSY_COMPOSER_RAW="│${WM_ESC}[39m  ${WM_ESC}[48;5;6mw${WM_ESC}[38;5;8m${WM_ESC}[49morking… (Esc stops, Ctrl+C quits)${WM_ESC}[39m$(wm_pad 4)${WM_ESC}[38;5;8m│"
WM_DRAFT_COMPOSER_RAW="│${WM_ESC}[39m  draft text never sent${WM_ESC}[48;5;6m ${WM_ESC}[49m$(wm_pad 16)${WM_ESC}[38;5;8m│"
WM_FOOTER_IDLE=" Enter send  ↑↓ PgUp/PgDn scroll  Esc quit                                    openai · deepseek-v4.1-flash-1017  ● ready"
WM_FOOTER_BUSY=" Enter send  ↑↓ PgUp/PgDn scroll  Esc stop                                    openai · deepseek-v4.1-flash-1017  ⠴ working"

test_wintermolt_ancestry_detects_the_native_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-native")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' '/Users/someone/.nix-profile/bin/wintermolt'; exit 0 ;;
  *"args="*) printf '%s\n' 'wintermolt'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = wintermolt ] \
    || fail "a natively-named wintermolt command must be detected by ancestry, got '$out'"
  pass "fm-harness.sh: ancestry detects a natively-named wintermolt command"
}

test_wintermolt_ancestry_rejects_unrelated_mentions() {
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

  out=$(FAKE_PS_COMM=wintermolt-tools FAKE_PS_ARGS='wintermolt-tools run' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != wintermolt ] \
    || fail "an unrelated wintermolt-tools command must not detect wintermolt, got '$out'"

  out=$(FAKE_PS_COMM=wm-helper FAKE_PS_ARGS='wm-helper glm-5.3' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != wintermolt ] \
    || fail "the wm-helper helper must not detect wintermolt, got '$out'"

  out=$(FAKE_PS_COMM=bash FAKE_PS_ARGS='bash -c "echo wintermolt --help"' \
    PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" != wintermolt ] \
    || fail "a later shell argument naming wintermolt must not detect wintermolt, got '$out'"
  pass "fm-harness.sh: ancestry rejects unrelated wintermolt mentions"
}

test_wintermolt_claims_no_inherited_launcher_marker() {
  local fakebin out
  # AGENT=1 is inherited launcher state (verified live on other panes), so it
  # must never promote to a wintermolt identity.
  out=$(AGENT=1 "$HARNESS")
  [ "$out" != wintermolt ] \
    || fail "an inherited AGENT=1 must never claim the wintermolt identity, got '$out'"
  # Drive the hazard the other way: a structural wintermolt ancestor must
  # outrank a retained CLAUDECODE rather than being renamed away from it.
  fakebin=$(fm_fakebin "$TMP_ROOT/anc-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' wintermolt; exit 0 ;;
  *"args="*) printf '%s\n' 'wintermolt'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(CLAUDECODE=1 PATH="$fakebin:$PATH" "$HARNESS")
  [ "$out" = wintermolt ] \
    || fail "a structural wintermolt ancestor must outrank an inherited CLAUDECODE, got '$out'"
  pass "fm-harness.sh: no inherited launcher marker claims the wintermolt identity"
}

test_wintermolt_control_mechanics_are_the_verified_ones() {
  fm_control_harness_supported wintermolt || fail "wintermolt must be a supported control harness"
  [ "$(fm_control_harness_family wintermolt)" = wintermolt ] || fail "wintermolt must map to its own family"
  fm_control_harness_supports_kind wintermolt scout || fail "wintermolt must run scouts"
  fm_control_harness_supports_kind wintermolt ship || fail "wintermolt must run ships"
  fm_control_harness_supports_kind wintermolt secondmate \
    && fail "wintermolt must refuse a secondmate" || true
  [ "$(fm_control_interrupt_transport wintermolt)" = key ] || fail "wintermolt must interrupt through the keyplane"
  [ "$(fm_control_interrupt_key wintermolt)" = Escape ] || fail "wintermolt must interrupt on Escape"
  [ "$(fm_control_interrupt_repeat wintermolt)" = 1 ] || fail "wintermolt must interrupt on a single press"
  [ -z "$(fm_control_interrupt_clear_key wintermolt)" ] || fail "wintermolt must need no clear key"
  [ "$(fm_control_interrupt_ack_source wintermolt)" = none ] || fail "wintermolt must have no ack source"
  [ "$(fm_control_exit_command wintermolt)" = /quit ] || fail "wintermolt must exit on /quit"
  pass "fm-control-lib: wintermolt mechanics are Escape once, no clear key, and /quit"
}

test_wintermolt_busy_tail_needs_the_pinned_footer_row() {
  printf 'reply text\n%s\n' "$WM_FOOTER_BUSY" | fm_busy_wintermolt_tail_busy \
    || fail "the busy footer row must read busy"
  printf 'reply text\n%s\n' "$WM_FOOTER_IDLE" | fm_busy_wintermolt_tail_busy \
    && fail "the idle footer row must not read busy" || true
  printf 'The build is working\n%s\n' "$WM_FOOTER_IDLE" | fm_busy_wintermolt_tail_busy \
    && fail "conversation output containing the word must not read busy over an idle footer" || true
  printf 'working\n' | fm_busy_wintermolt_tail_busy \
    && fail "a free-floating working word alone must not read busy" || true
  printf 'reply text\nworking\n' | fm_busy_wintermolt_tail_busy \
    && fail "a working word inside the conversation area must not read busy" || true
  printf '$ \n' | fm_busy_wintermolt_tail_busy \
    && fail "a dead shell must not read busy" || true
  FM_BUSY_WINTERMOLT_REGEX='always-busy-token' \
    bash -c '. "$0/bin/fm-busy-lib.sh"; printf "always-busy-token\n" | fm_busy_wintermolt_tail_busy' "$ROOT" \
    || fail "the operator override must be able to change the wintermolt busy signature"
  pass "fm-busy-lib: only the pinned footer row carries the wintermolt busy verdict"
}

test_wintermolt_busy_signatures_are_harness_scoped() {
  printf '%s\n' "$WM_FOOTER_BUSY" | fm_busy_lines_match wintermolt \
    || fail "harness=wintermolt must match its own footer"
  printf '%s\n' "$WM_FOOTER_BUSY" | fm_busy_lines_match agy \
    && fail "harness=agy must never borrow wintermolt's footer" || true
  printf '%s\n' "$WM_FOOTER_BUSY" | fm_busy_lines_match grok \
    && fail "harness=grok must never borrow wintermolt's footer" || true
  printf 'esc to cancel\n' | fm_busy_lines_match wintermolt \
    && fail "harness=wintermolt must never borrow agy's token" || true
  printf '%s\n' "$WM_FOOTER_BUSY" | fm_busy_lines_match spaceship \
    && fail "an unverified harness must match nothing" || true
  pass "fm-composer-lib: wintermolt delivery signatures never cross harnesses"
}

test_wintermolt_classify_reads_the_rendered_tail() {
  local statedir verdict
  statedir="$TMP_ROOT/classify"; mkdir -p "$statedir"
  verdict=$(fm_busy_classify tmux fake:win wintermolt wm-case-1 "$statedir" "conversation
$WM_FOOTER_BUSY")
  [ "$verdict" = "busy wintermolt-regex" ] || fail "a busy footer must classify busy wintermolt-regex, got '$verdict'"
  verdict=$(fm_busy_classify tmux fake:win wintermolt wm-case-2 "$statedir" "conversation
$WM_FOOTER_IDLE")
  [ "$verdict" = "unknown wintermolt-regex" ] || fail "an idle footer must classify unknown, never idle, got '$verdict'"
  pass "fm-busy-lib: wintermolt classify reads busy from the footer and never claims idle"
}

# The screen rows the composer classifier reads: the real classifier, the real
# shapes. The footer furniture recognition keeps the box selectable, the
# wintermolt-scoped placeholder rule reads the idle row empty, and neither the
# draft nor the busy row can reach empty.
wm_composer_screen() {  # <composer-raw-row> <footer-row>
  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$(wm_transcript_top)" \
    "$(wm_inner_plain '  conversation history')" \
    "$WM_BOTTOM" \
    "$WM_TOP" "$1" "$WM_BOTTOM" "$2"
}

test_wintermolt_idle_composer_reads_empty_only_through_the_scope() {
  local screen verdict
  screen=$(wm_composer_screen "$WM_IDLE_COMPOSER_RAW" "$WM_FOOTER_IDLE")
  verdict=$(FM_COMPOSER_HARNESS=wintermolt \
    fm_composer_classify_screen "styled=1
cursor=0
identity=0
rows=8" "$screen")
  [ "$verdict" = empty ] \
    || fail "the scoped read must classify the idle wintermolt composer empty, got '$verdict'"
  verdict=$(fm_composer_classify_screen "styled=1
cursor=0
identity=0
rows=8" "$screen")
  [ "$verdict" != empty ] \
    || fail "without the wintermolt scope the palette-dim placeholder must not read empty, got '$verdict'"
  pass "fm-composer-lib: the wintermolt idle placeholder reads empty only in scope"
}

test_wintermolt_draft_and_busy_rows_stay_pending() {
  local screen verdict
  screen=$(wm_composer_screen "$WM_DRAFT_COMPOSER_RAW" "$WM_FOOTER_IDLE")
  verdict=$(FM_COMPOSER_HARNESS=wintermolt \
    fm_composer_classify_screen "styled=1
cursor=0
identity=0
rows=8" "$screen")
  [ "$verdict" = pending ] \
    || fail "a typed draft must classify pending, got '$verdict'"
  # A draft carrying exactly the placeholder words stays pending too: the
  # draft renders default-foreground text with the cursor cell after it, never
  # the reverse-video leading cell the scoped rule demands.
  screen=$(wm_composer_screen "│${WM_ESC}[39m  Type a message, or /help${WM_ESC}[48;5;6m ${WM_ESC}[49m$(wm_pad 13)${WM_ESC}[38;5;8m│" "$WM_FOOTER_IDLE")
  verdict=$(FM_COMPOSER_HARNESS=wintermolt \
    fm_composer_classify_screen "styled=1
cursor=0
identity=0
rows=8" "$screen")
  [ "$verdict" = pending ] \
    || fail "a draft spelling the placeholder must classify pending, got '$verdict'"
  screen=$(wm_composer_screen "$WM_BUSY_COMPOSER_RAW" "$WM_FOOTER_BUSY")
  verdict=$(FM_COMPOSER_HARNESS=wintermolt \
    fm_composer_classify_screen "styled=1
cursor=0
identity=0
rows=8" "$screen")
  # The busy row reads pending-unproven on the live pane too: the `…` cell
  # defeats the ASCII geometry proof, which only ever moves the verdict toward
  # refusing. What matters is that it can never reach empty.
  [ "$verdict" = pending ] || [ "$verdict" = pending-unproven ] \
    || fail "the busy working row must classify pending or pending-unproven, got '$verdict'"
  pass "fm-composer-lib: wintermolt drafts and the busy row never read empty"
}

test_wintermolt_footer_furniture_bounds_the_box() {
  local screen verdict
  # An unrecognized activity row below the box still stales it: the furniture
  # exemption may not swallow arbitrary content.
  screen=$(wm_composer_screen "$WM_IDLE_COMPOSER_RAW" "Working on request...")
  verdict=$(FM_COMPOSER_HARNESS=wintermolt \
    fm_composer_classify_screen "styled=1
cursor=0
identity=0
rows=8" "$screen")
  [ "$verdict" != empty ] \
    || fail "an unclaimed activity row below the box must not read empty, got '$verdict'"
  # The furniture signature is the composer's own keybind row; a row that
  # merely contains the words is not furniture because the anchor demands the
  # keybind words at the row's start.
  screen=$(wm_composer_screen "$WM_IDLE_COMPOSER_RAW" "some output mentioning Enter send and Esc quit mid-sentence")
  verdict=$(FM_COMPOSER_HARNESS=wintermolt \
    fm_composer_classify_screen "styled=1
cursor=0
identity=0
rows=8" "$screen")
  [ "$verdict" != empty ] \
    || fail "an unanchored mention of the keybind words must not read empty, got '$verdict'"
  pass "fm-composer-lib: the wintermolt footer exemption stays anchored"
}

test_wintermolt_idle_placeholder_is_fleet_wide() {
  fm_composer_idle_matches 'Type a message, or /help' \
    "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive \
    || fail "the wintermolt placeholder must be in the fleet-wide idle set"
  pass "fm-composer-lib: the wintermolt idle placeholder is fleet-wide"
}

# --- spawn-world cases -------------------------------------------------------

make_wintermolt_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_TMUX_CALL_LOG:-/dev/null}"
state=\$(cat "\${FM_FAKE_WM_STATE:-/dev/null}" 2>/dev/null || printf 'shell')
styled=
for arg in "\$@"; do
  [ "\$arg" = "-e" ] && styled=1
done
fake_screen() {
  if [ -n "\$styled" ]; then
    case "\$state" in
      launched) printf '%s\n' "$WM_TOP" "$WM_IDLE_COMPOSER_RAW" "$WM_BOTTOM" "$WM_FOOTER_IDLE" ;;
      busy) printf '%s\n' "$WM_TOP" "$WM_BUSY_COMPOSER_RAW" "$WM_BOTTOM" "$WM_FOOTER_BUSY" ;;
      *) printf 'shell prompt\n\$ \n' ;;
    esac
  else
    case "\$state" in
      launched) printf 'conversation\n%s\n%s\n%s\n%s\n' "$WM_TOP" "$(wm_inner_plain '  Type a message, or /help')" "$WM_BOTTOM" "$WM_FOOTER_IDLE" ;;
      busy) printf 'conversation\n%s\n%s\n%s\n%s\n' "$WM_TOP" "$(wm_inner_plain '  working… (Esc stops, Ctrl+C quits)')" "$WM_BOTTOM" "$WM_FOOTER_BUSY" ;;
      *) printf 'shell prompt\n\$ \n' ;;
    esac
  fi
}
case "\$*" in
  *"#{pane_current_path}"*) printf '%s\n' "\${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{cursor_y}"*) printf '4\n'; exit 0 ;;
  *"#{pane_tty}"*) printf '/dev/ttys99999'; exit 0 ;;
esac
case "\${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ ! -s "\${FM_FAKE_WM_STATE}.window" ] || cat "\${FM_FAKE_WM_STATE}.window"
    exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "\$@"; do
      [ "\$previous" = -n ] && name=\$arg
      previous=\$arg
    done
    printf '%s\n' "\$name" > "\${FM_FAKE_WM_STATE}.window"
    exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys)
    # Two shapes reach this stub: send-keys -t <target> -l <literal> from
    # the submit cores, and send-keys -t <target> <text> Enter from the
    # spawn's typed lines (bin/backends/tmux.sh fm_backend_tmux_send_text_line),
    # where the whole text is ONE positional argument.
    literal=
    prev=
    skip=
    pos=()
    for arg in "\$@"; do
      if [ -n "\$skip" ]; then skip=""; continue; fi
      if [ "\$prev" = "-l" ]; then literal=\$arg; prev=""; continue; fi
      case "\$arg" in
        -t) skip=1; continue ;;
        -l) prev=\$arg; continue ;;
      esac
      case "\$arg" in
        send-keys) continue ;;
      esac
      pos+=("\$arg")
    done
    if [ -n "\$literal" ]; then
      case "\$literal" in
        ". '"*"'")
          staged=\${literal#". '"}; staged=\${staged%"'"}
          [ ! -f "\$staged" ] || literal=\$(cat "\$staged")
          ;;
      esac
      case "\$literal" in
        *WINTERMOLT_NO_FALLBACK=1*)
          printf '%s\n' "\$literal" >> "\${FM_FAKE_LAUNCH_LOG:?}"
          # FM_FAKE_WM_NEVER_READY simulates a backend that exits at startup:
          # the launch is typed but the TUI never draws, so the readiness
          # gate must fail the spawn loudly.
          [ "\${FM_FAKE_WM_NEVER_READY:-0}" = 1 ] \
            || printf 'launched\n' > "\${FM_FAKE_WM_STATE:?}"
          ;;
        *Read*the*brief*at*)
          # The brief pointer: the Enter that follows it is the one that
          # starts the brief turn, so mark it for the plain-Enter branch.
          printf 'pointer\n' > "\${FM_FAKE_WM_STATE:?}.pending"
          ;;
      esac
      exit 0
    fi
    count=\${#pos[@]}
    text=
    if [ "\$count" -gt 1 ] && [ "\${pos[\$((count - 1))]}" = Enter ]; then
      text=\${pos[0]}
    fi
    case "\$text" in
      *WINTERMOLT_NO_FALLBACK=1*)
        printf '%s\n' "\$text" >> "\${FM_FAKE_LAUNCH_LOG:?}"
        [ "\${FM_FAKE_WM_NEVER_READY:-0}" = 1 ] \
          || printf 'launched\n' > "\${FM_FAKE_WM_STATE:?}"
        exit 0
        ;;
    esac
    if [ "\$count" -eq 1 ] && [ "\${pos[0]}" = Enter ]; then
      if [ -f "\${FM_FAKE_WM_STATE:?}.pending" ]; then
        rm -f "\${FM_FAKE_WM_STATE:?}.pending"
        case "\$state" in
          launched) printf 'busy\n' > "\${FM_FAKE_WM_STATE:?}" ;;
        esac
      fi
    fi
    exit 0
    ;;
  capture-pane) fake_screen; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/wintermolt" <<'SH'
#!/usr/bin/env bash
echo "fake wintermolt must never execute" >&2
exit 9
SH
  chmod +x "$fakebin/wintermolt"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_wintermolt_spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_wintermolt_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Wintermolt dispatch.

## Firstmate spec
Verify launch and delivery behavior.
EOF
  printf 'wintermolt\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  printf 'shell\n' > "$case_dir/wm.state"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_wintermolt_spawn_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_wintermolt_spawn() {
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    FM_FAKE_WM_STATE="$case_dir/wm.state" \
    FM_WINTERMOLT_READY_POLLS=6 FM_WINTERMOLT_DELIVERY_POLLS=6 FM_WINTERMOLT_POLL_INTERVAL=0 \
    PATH="$fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$proj" --harness wintermolt --mode no-mistakes --yolo off "$@" 2>&1
}

test_wintermolt_launch_pins_the_env_contract_and_delivers_the_pointer() {
  local id rec out rc launch meta state
  id="wm-launch-z1-$$"
  rec=$(make_wintermolt_spawn_case launch "$id")
  read_wintermolt_spawn_record "$rec"
  out=$(run_wintermolt_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model deepseek-v4.1-flash-1017 --effort low)
  rc=$?
  expect_code 0 "$rc" "wintermolt spawn should succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "$FAKEBIN_DIR/wintermolt" "wintermolt launch did not pin the resolved absolute binary"
  assert_contains "$launch" "WINTERMOLT_MODEL='deepseek-v4.1-flash-1017'" "wintermolt launch did not carry the model axis"
  assert_contains "$launch" "WINTERMOLT_NO_FALLBACK=1" "wintermolt launch did not pin the no-fallback contract"
  assert_contains "$launch" "env -u CLAUDECODE" "wintermolt launch did not clear the inherited launcher marker"
  assert_not_contains "$launch" "--effort" "wintermolt launch passed an effort flag it does not have"
  assert_not_contains "$launch" "__WINTERMOLTBIN__" "wintermolt launch left its binary placeholder unsubstituted"
  assert_not_contains "$launch" "__MODELFLAG__" "wintermolt launch left its model placeholder unsubstituted"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'harness=wintermolt' "$meta" "wintermolt meta did not record its harness"
  assert_grep 'model=deepseek-v4.1-flash-1017' "$meta" "wintermolt meta did not record its model"
  assert_grep 'effort=low' "$meta" "wintermolt meta did not record its effort axis"
  # No busy record is armed: no writer could ever clear it, matching grok,
  # rovo, and agy.
  state="$HOME_DIR/state"
  [ ! -e "$state/$id.busy-gen" ] || fail "wintermolt must not arm a busy-state record"
  [ ! -e "$state/$id.busy-state" ] || fail "wintermolt must not seed a busy-state record"
  for sidecar in "$state/$id.wintermolt-"*; do
    [ -e "$sidecar" ] || continue
    fail "wintermolt spawn left an adapter sidecar behind: $sidecar"
  done
  # The brief arrived as a typed pointer, confirmed by the delivery gate's
  # requirement of the busy footer (the fake flips to busy only on the pointer
  # Enter, so reaching success proves both gates passed).
  assert_grep 'Read the brief at ' "$CASE_DIR/tmux-calls.log" \
    "wintermolt spawn did not type the absolute brief pointer"
  assert_grep 'and follow it exactly.' "$CASE_DIR/tmux-calls.log" \
    "wintermolt spawn did not type the pointer's instruction"
  pass "fm-spawn: wintermolt launch pins the env contract and confirms pointer delivery"
}

test_wintermolt_refuses_a_provider_prefixed_model() {
  local id rec out rc
  id="wm-model-z2-$$"
  rec=$(make_wintermolt_spawn_case model-refusal "$id")
  read_wintermolt_spawn_record "$rec"
  out=$(run_wintermolt_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model provider/deepseek-v4.1-flash-1017)
  rc=$?
  expect_code 1 "$rc" "a provider-prefixed model must refuse the spawn"
  assert_contains "$out" "provider-prefixed" "the refusal must name the provider-prefix mistake"
  pass "fm-spawn: wintermolt refuses a provider-prefixed model"
}

test_wintermolt_refuses_a_secondmate_and_other_backends() {
  local id rec out rc
  id="wm-second-z3-$$"
  rec=$(make_wintermolt_spawn_case secondmate-refusal "$id")
  read_wintermolt_spawn_record "$rec"
  out=$(HOME="$HOME_DIR/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    FM_FAKE_TMUX_CALL_LOG="$CASE_DIR/tmux-calls.log" \
    FM_FAKE_WM_STATE="$CASE_DIR/wm.state" \
    PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$HOME_DIR" --secondmate --harness wintermolt 2>&1)
  # A secondmate spawn takes no --mode/--yolo delivery contract, so this one
  # case runs the spawn without the ship flags run_wintermolt_spawn pins.
  rc=$?
  expect_code 1 "$rc" "a wintermolt secondmate must be refused"
  assert_contains "$out" "crewmate/scout adapter only" "the refusal must name the missing primary protocol"

  out=$(run_wintermolt_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --backend herdr)
  rc=$?
  expect_code 1 "$rc" "a wintermolt launch on a non-tmux backend must be refused"
  assert_contains "$out" "verified on the tmux backend only" "the refusal must name the tmux-only boundary"
  pass "fm-spawn: wintermolt refuses secondmates and non-tmux backends"
}

test_wintermolt_spawn_fails_loudly_when_the_tui_never_becomes_ready() {
  local id rec out rc state
  id="wm-dead-z4-$$"
  rec=$(make_wintermolt_spawn_case never-ready "$id")
  read_wintermolt_spawn_record "$rec"
  # An unusable backend exits before the TUI draws, so the fake never leaves
  # its shell state and the readiness gate must fail the spawn loudly.
  out=$(FM_FAKE_WM_NEVER_READY=1 run_wintermolt_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id")
  rc=$?
  expect_code 1 "$rc" "a launch that never shows the ready footer must fail the spawn"
  assert_contains "$out" "did not show its TUI ready footer" "the failure must name the readiness gate"
  assert_contains "$out" "WINTERMOLT_BACKEND" "the failure must point at the backend environment"
  state="$HOME_DIR/state"
  assert_grep 'did not show its TUI ready footer' "$state/$id.status" \
    "the failed launch must record a status line"
  pass "fm-spawn: a never-ready wintermolt launch fails loudly with cleanup"
}

test_wintermolt_xhigh_effort_is_recorded_but_omitted() {
  local id rec out rc launch meta
  id="wm-xhigh-z5-$$"
  rec=$(make_wintermolt_spawn_case xhigh "$id")
  read_wintermolt_spawn_record "$rec"
  out=$(run_wintermolt_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model deepseek-v4.1-flash-1017 --effort xhigh)
  rc=$?
  expect_code 0 "$rc" "wintermolt spawn with an effort request should still succeed: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_not_contains "$launch" "effort" "wintermolt launch passed an effort value"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'effort=xhigh' "$meta" "wintermolt meta did not retain the effort axis"
  pass "fm-spawn: wintermolt omits effort from the launch but records it in task metadata"
}

# --- run ---------------------------------------------------------------------

test_wintermolt_ancestry_detects_the_native_command_name
test_wintermolt_ancestry_rejects_unrelated_mentions
test_wintermolt_claims_no_inherited_launcher_marker
test_wintermolt_control_mechanics_are_the_verified_ones
test_wintermolt_busy_tail_needs_the_pinned_footer_row
test_wintermolt_busy_signatures_are_harness_scoped
test_wintermolt_classify_reads_the_rendered_tail
test_wintermolt_idle_composer_reads_empty_only_through_the_scope
test_wintermolt_draft_and_busy_rows_stay_pending
test_wintermolt_footer_furniture_bounds_the_box
test_wintermolt_idle_placeholder_is_fleet_wide
test_wintermolt_launch_pins_the_env_contract_and_delivers_the_pointer
test_wintermolt_refuses_a_provider_prefixed_model
test_wintermolt_refuses_a_secondmate_and_other_backends
test_wintermolt_spawn_fails_loudly_when_the_tui_never_becomes_ready
test_wintermolt_xhigh_effort_is_recorded_but_omitted
