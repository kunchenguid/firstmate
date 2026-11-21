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
#      WINTERMOLT_MODEL from the model axis exactly as given, a slash-namespaced
#      gateway id included, and an effort request is recorded but omitted (no
#      such setting exists).
#   4. wintermolt is a crewmate/scout adapter on tmux and rex: a secondmate
#      launch and every other backend are refused, and nothing is armed as busy
#      wiring because no writer could ever clear it. The rex surfaces this
#      depends on are pinned below too - the composer scope gated on the block's
#      foreground process, the scoped delivery busy read, the submit confirmation
#      on the idle-to-busy transition, and the prefix-by-prefix proof that
#      refuses a headless fragment on a row narrower than the payload.
#   5. The busy verdict is the pinned footer row alone - `Esc stop` or a
#      spinner-plus-`working` status cell ending the pane's LAST non-empty row -
#      so conversation output containing the word can never read busy, and an
#      idle or dead pane never reads busy either.
#   6. The composer is a rounded bordered box with the anchored
#      `Type a message, or /help` idle placeholder (reverse-video cursor cell
#      plus a de-emphasized palette run) and the keybind/status footer row
#      below it; the placeholder reads empty only through the wintermolt-scoped
#      rule, a draft with the same words stays pending, and the busy
#      `working…` row stays pending/unproven.
#   7. A submitted steer is confirmed by the idle-to-busy transition read
#      through that anchored footer: an idle pane that goes busy across our
#      Enter confirms, while a pane already busy, an idle footer under
#      conversation output ending in the busy word, and a draft that stays
#      pending never do.
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
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/rex.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"

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

# The composer rows a wintermolt box renders for <text>, wrapped at
# <inner-width> with the cursor cell after the last character. The submit
# fixtures below embed this definition in their fake tmux, so the shipped text
# extractor reads exactly what a live draft renders.
wm_fake_draft_rows() {  # <inner-width> <text>
  local width=$1 rest=$2 chunk pad
  while :; do
    chunk=${rest:0:$((width - 4))}
    rest=${rest:$((width - 4))}
    if [ -n "$rest" ]; then
      # A wrapped row keeps the box's full inner width: the live TUI re-wraps
      # what was typed rather than drawing a short row.
      pad=$((width - 2 - ${#chunk}))
      printf '│\033[39m  %s%*s\033[38;5;8m│\n' "$chunk" "$pad" ''
    else
      pad=$((width - 3 - ${#chunk}))
      printf '│\033[39m  %s\033[48;5;6m \033[49m%*s\033[38;5;8m│\n' "$chunk" "$pad" ''
    fi
    [ -n "$rest" ] || break
  done
}

# The submit cores read the pane through tmux and the anchored wintermolt
# process name. The fake below serves the real classifier both of those, so the
# reads under test are the shipped ones: the styled box plus footer, the cursor
# parked on the footer row, and the pane's foreground process. `Enter` moves an
# idle pane that holds text to FM_FAKE_WM_AFTER (the render a submitted steer
# produces) and leaves any other state alone; `idle`, `busy`, `draft`, and
# `stale` are the renders those reads must tell apart. A literal burst models
# what the live TUI does with it: FM_FAKE_WM_SWALLOW=N drops the first N bursts,
# FM_FAKE_WM_LOSE=1 drops every burst, FM_FAKE_WM_TRUNCATE=N keeps only the
# tail of burst N, FM_FAKE_WM_DEFER_BURST=N echoes burst N only after
# FM_FAKE_WM_DEFER_READS more pane reads, and FM_FAKE_WM_HEAD_DROP=N loses the
# head of one literal write longer than N characters, the shape a single
# `send-keys -l` of a whole message takes on the live 0.7.0 input loop. One
# burst is the run of literal writes between two pane reads, so a text written
# in chunks is still one burst. The pane records every submitted turn in
# `<state>.submitted`, what the model would receive.
make_wintermolt_pane_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
INNER=$WM_INNER_WIDTH
state=\$(cat "\${FM_FAKE_WM_STATE:?}" 2>/dev/null || printf 'idle')
styled=
mode=key
previous=
payload=
bad_flag=
literal_next=0
for arg in "\$@"; do
  [ "\$arg" = "-e" ] && styled=1
  # After -l the next argument is the literal payload; tmux ends flag parsing
  # only at the double-dash marker, so a payload that still starts with a dash
  # is refused as an unknown flag exactly as the real command refuses it.
  if [ "\$literal_next" = 1 ] && [ "\$arg" = "--" ]; then
    literal_next=2
  elif [ "\$literal_next" = 1 ]; then
    case "\$arg" in -?*) bad_flag=\$arg ;; esac
    mode=literal; payload=\$arg; literal_next=0
  elif [ "\$literal_next" = 2 ]; then
    mode=literal; payload=\$arg; literal_next=0
  elif [ "\$arg" = "-l" ]; then
    literal_next=1
  fi
  previous=\$arg
done
draft_file="\${FM_FAKE_WM_STATE:?}.draft"
bursts_file="\${FM_FAKE_WM_STATE:?}.bursts"
draft=\$(cat "\$draft_file" 2>/dev/null || printf '')
$(declare -f wm_fake_draft_rows)
composer_text() {
  if [ -n "\$draft" ]; then printf '%s' "\$draft"
  elif [ "\$state" = draft ]; then printf '%s' 'draft text never sent'
  fi
}
# The real composer holds the whole draft but shows only the tail once the
# draft outgrows its single row. FM_FAKE_WM_SCROLL is that row's character
# capacity: the fixture renders (and counts rows for) only the visible tail,
# while the submitted text stays the whole draft.
composer_render() {
  local text kept
  text=\$(composer_text)
  if [ "\${FM_FAKE_WM_SCROLL:-0}" -gt 0 ] && [ "\${#text}" -gt "\${FM_FAKE_WM_SCROLL:-0}" ]; then
    kept=\${FM_FAKE_WM_SCROLL:-0}
    printf '%s' "\${text: \$((\${#text} - kept))}"
  else
    printf '%s' "\$text"
  fi
}
draft_row_count() {
  local text=\$1 n
  [ -n "\$text" ] || { printf '1'; return 0; }
  n=\$(( (\${#text} + INNER - 5) / (INNER - 4) ))
  [ "\$n" -ge 1 ] || n=1
  printf '%s' "\$n"
}
inner_plain() {
  printf '│%s%s%*s│' '  ' "\$1" "\$((INNER - 2 - \${#1}))" ''
}
screen() {
  local text
  text=\$(composer_render)
  if [ -n "\$styled" ]; then
    case "\$state" in
      # The pane rendering its working row while its footer still reads idle,
      # under conversation output that ends in the busy word.
      stale) printf '%s\n' "$(wm_transcript_top)" "$(wm_inner_plain '  conversation history')" "$(wm_inner_plain '  still working')" "$WM_BOTTOM" "$WM_TOP" "$WM_BUSY_COMPOSER_RAW" "$WM_BOTTOM" "$WM_FOOTER_IDLE" ;;
      busy) printf '%s\n' "$(wm_transcript_top)" "$(wm_inner_plain '  conversation history')" "$WM_BOTTOM" "$WM_TOP" "$WM_BUSY_COMPOSER_RAW" "$WM_BOTTOM" "$WM_FOOTER_BUSY" ;;
      *)
        printf '%s\n' "$(wm_transcript_top)" "$(wm_inner_plain '  conversation history')" "$WM_BOTTOM" "$WM_TOP"
        if [ -z "\$text" ]; then printf '%s\n' "$WM_IDLE_COMPOSER_RAW"; else wm_fake_draft_rows "\$INNER" "\$text"; fi
        printf '%s\n%s\n' "$WM_BOTTOM" "$WM_FOOTER_IDLE"
        ;;
    esac
  else
    case "\$state" in
      stale) printf 'conversation\n%s\n%s\n%s\n%s\n' "still working" "$WM_TOP" "$(wm_inner_plain '  working… (Esc stops, Ctrl+C quits)')" "$WM_BOTTOM" "$WM_FOOTER_IDLE" ;;
      busy) printf 'conversation\n%s\n%s\n%s\n%s\n' "$WM_TOP" "$(wm_inner_plain '  working… (Esc stops, Ctrl+C quits)')" "$WM_BOTTOM" "$WM_FOOTER_BUSY" ;;
      *)
        [ -n "\$text" ] || text='Type a message, or /help'
        printf 'conversation\n%s\n%s\n%s\n%s\n' "$WM_TOP" "\$(inner_plain "\$text")" "$WM_BOTTOM" "$WM_FOOTER_IDLE"
        ;;
    esac
  fi
}
case "\${1:-}" in
  display-message)
    case "\$*" in
      *'#{cursor_y}'*) printf '%s\n' "\$((5 + \$(draft_row_count "\$(composer_render)")))"; exit 0 ;;
      *'#{pane_width}'*) [ -n "\${FM_FAKE_WM_PANE_WIDTH:-}" ] && printf '%s\n' "\$FM_FAKE_WM_PANE_WIDTH"; exit 0 ;;
      *'#{pane_tty}'*) printf '/dev/ttys99999'; exit 0 ;;
      *'#{pane_current_command}'*) printf '%s' "\${FM_FAKE_WM_COMMAND:-wintermolt}"; exit 0 ;;
    esac
    exit 0 ;;
  capture-pane)
    # A read ends the run of literal writes: the next write starts a new burst.
    rm -f "\${FM_FAKE_WM_STATE:?}.typing"
    if [ -f "\${FM_FAKE_WM_STATE:?}.deferred" ]; then
      left=\$(cat "\${FM_FAKE_WM_STATE:?}.deferred-reads")
      left=\$((left - 1))
      if [ "\$left" -le 0 ]; then
        draft="\$(cat "\${FM_FAKE_WM_STATE:?}.deferred")\$draft"
        printf '%s' "\$draft" > "\$draft_file"
        rm -f "\${FM_FAKE_WM_STATE:?}.deferred" "\${FM_FAKE_WM_STATE:?}.deferred-reads"
      else
        printf '%s\n' "\$left" > "\${FM_FAKE_WM_STATE:?}.deferred-reads"
      fi
    fi
    if [ -f "\${FM_FAKE_WM_STATE:?}.delay" ]; then
      left=\$(cat "\${FM_FAKE_WM_STATE:?}.delay")
      left=\$((left - 1))
      if [ "\$left" -le 0 ]; then
        rm -f "\${FM_FAKE_WM_STATE:?}.delay"
        printf '%s\n' "\${FM_FAKE_WM_AFTER:-busy}" > "\${FM_FAKE_WM_STATE:?}"
      else
        printf '%s\n' "\$left" > "\${FM_FAKE_WM_STATE:?}.delay"
      fi
    fi
    screen; exit 0 ;;
  send-keys)
    if [ "\$mode" = literal ]; then
      if [ -n "\$bad_flag" ]; then
        printf 'command send-keys: unknown flag %s\n' "\${bad_flag:0:2}" >&2
        exit 1
      fi
      typing_file="\${FM_FAKE_WM_STATE:?}.typing"
      bursts=\$(cat "\$bursts_file" 2>/dev/null || printf '0')
      if [ ! -f "\$typing_file" ]; then
        bursts=\$((bursts + 1))
        printf '%s\n' "\$bursts" > "\$bursts_file"
        printf '%s' "\$payload" > "\$typing_file"
      fi
      if [ "\${FM_FAKE_WM_LOSE:-0}" = 1 ] \
         || [ "\$bursts" -le "\${FM_FAKE_WM_SWALLOW:-0}" ]; then
        exit 0
      fi
      if [ "\$bursts" = "\${FM_FAKE_WM_DEFER_BURST:-0}" ]; then
        # The TUI accepted the bytes but echoes them only after a few more
        # reads, the settling window a single stale read can be fooled by.
        printf '%s' "\$payload" >> "\${FM_FAKE_WM_STATE:?}.deferred"
        printf '%s\n' "\${FM_FAKE_WM_DEFER_READS:-2}" > "\${FM_FAKE_WM_STATE:?}.deferred-reads"
        exit 0
      fi
      if [ "\${FM_FAKE_WM_TRUNCATE:-0}" -ge "\$bursts" ] \
         && [ "\${FM_FAKE_WM_TRUNCATE:-0}" -gt 0 ]; then
        keep=\$(( \${#payload} / 2 ))
        draft=\${payload:\$((\${#payload} - keep))}
      elif [ "\${FM_FAKE_WM_HEAD_DROP:-0}" -gt 0 ] \
           && [ "\${#payload}" -gt "\${FM_FAKE_WM_HEAD_DROP}" ]; then
        # A write the input loop cannot keep whole arrives as its tail.
        draft=\$draft\${payload:\$((\${#payload} - \${FM_FAKE_WM_HEAD_DROP}))}
      else
        draft=\$draft\$payload
      fi
      printf '%s' "\$draft" > "\$draft_file"
      exit 0
    fi
    if [ "\$previous" = Enter ] && [ "\$state" = idle ] && [ -n "\$(composer_text)" ]; then
      printf '%s\n' "\$(composer_text)" >> "\${FM_FAKE_WM_STATE:?}.submitted"
      : > "\$draft_file"
      rm -f "\${FM_FAKE_WM_STATE:?}.typing"
      if [ "\${FM_FAKE_WM_AFTER_DELAY:-0}" -gt 0 ]; then
        # The working row replaces the composer at once while the footer takes
        # a few more reads to render busy, the slow-footer shape the
        # confirmation budget must tolerate.
        printf 'stale\n' > "\${FM_FAKE_WM_STATE:?}"
        printf '%s\n' "\${FM_FAKE_WM_AFTER_DELAY}" > "\${FM_FAKE_WM_STATE:?}.delay"
      else
        printf '%s\n' "\${FM_FAKE_WM_AFTER:-busy}" > "\${FM_FAKE_WM_STATE:?}"
      fi
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
[ "${FM_FAKE_PS_WINTERMOLT:-1}" = 1 ] || exit 0
case "$*" in
  *'-t ttys99999'*) printf '4242 4242 4242 wintermolt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_wintermolt_submit_busy_read_resolves_its_own_signature() {
  local case_dir fakebin state busy_harness scoped
  case_dir="$TMP_ROOT/submit-busy-read"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'busy\n' > "$state"
  busy_harness=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" \
    fm_tmux_submit_busy_harness win)
  [ "$busy_harness" = wintermolt ] \
    || fail "a submit on a wintermolt pane must resolve wintermolt's own busy signature, got '$busy_harness'"
  scoped=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" fm_pane_busy_state win "$busy_harness")
  [ "$scoped" = busy ] \
    || fail "the submit core's busy read must see wintermolt's pinned footer, got '$scoped'"
  printf 'idle\n' > "$state"
  scoped=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" fm_pane_busy_state win "$busy_harness")
  [ "$scoped" = idle ] \
    || fail "an idle wintermolt pane must read idle through the resolved signature, got '$scoped'"
  # The resolved read is wintermolt's pinned footer alone: a pane rendering its
  # working row above an idle footer still reads idle, which no borrowed
  # wording from another harness may override.
  printf 'stale\n' > "$state"
  scoped=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" fm_pane_busy_state win "$busy_harness")
  [ "$scoped" = idle ] \
    || fail "the resolved wintermolt read must follow its own footer, got '$scoped'"
  # A pane whose foreground process is not the anchored wintermolt name claims
  # no signature and keeps the harness-less union.
  printf 'busy\n' > "$state"
  busy_harness=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" \
    FM_FAKE_PS_WINTERMOLT=0 FM_FAKE_WM_COMMAND=bash fm_tmux_submit_busy_harness win)
  [ -z "$busy_harness" ] \
    || fail "a non-wintermolt pane must keep the harness-less union, got '$busy_harness'"
  pass "fm-tmux-lib: a wintermolt submit resolves the wintermolt busy signature"
}

test_wintermolt_steer_confirmation_uses_the_busy_transition() {
  local case_dir fakebin state verdict
  case_dir="$TMP_ROOT/submit-transition"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  submit() {  # <pre-state> <post-enter-state>
    printf '%s\n' "$1" > "$state"
    rm -f "$state.draft" "$state.bursts" "$state.delay" "$state.typing" \
      "$state.deferred" "$state.deferred-reads" "$state.submitted"
    PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_AFTER="$2" \
      FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
      fm_tmux_submit_core win 'steer text' 2 0.05 0.05
  }
  verdict=$(submit idle busy)
  [ "$verdict" = empty ] \
    || fail "a steer that turns an idle wintermolt worker busy must confirm delivery, got '$verdict'"
  # The busy row replaced the composer, so the composer read alone is
  # pending-unproven; only the idle-before-typing baseline plus the anchored
  # footer may confirm it.
  verdict=$(submit busy busy)
  [ "$verdict" = pending-unproven ] \
    || fail "a pane already busy before typing must not confirm the submit, got '$verdict'"
  verdict=$(submit idle stale)
  [ "$verdict" = pending-unproven ] \
    || fail "conversation output ending in the busy word over an idle footer must not confirm a submit, got '$verdict'"
  verdict=$(submit idle draft)
  [ "$verdict" = pending ] \
    || fail "a proven pending draft that stays pending must stay unconfirmed, got '$verdict'"
  # The transition evidence is harness-scoped: the harness-less union never
  # confirms an unproven composer, even with the baseline.
  printf 'busy\n' > "$state"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" fm_tmux_submit_enter_core win 2 0.05 1 '')
  [ "$verdict" = pending-unproven ] \
    || fail "the harness-less union must not confirm an unproven composer, got '$verdict'"
  pass "fm-tmux-lib: a wintermolt steer confirms through the idle-to-busy transition"
}

test_wintermolt_swallowed_burst_is_retyped_before_submit() {
  local case_dir fakebin state verdict bursts
  case_dir="$TMP_ROOT/submit-swallow"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # The first burst is exactly what a freshly launched 0.7.0 TUI drops, and a
  # dropped burst leaves the idle placeholder, which reads like a submitted
  # turn. The composer's own content is what tells the two apart.
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_SWALLOW=1 \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    fm_tmux_submit_core win 'steer text' 2 0.05 0.05)
  [ "$verdict" = empty ] \
    || fail "a steer swallowed by a fresh pane and retyped must confirm delivery, got '$verdict'"
  bursts=$(cat "$state.bursts")
  [ "$bursts" = 2 ] \
    || fail "a swallowed burst must be replayed exactly once, got $bursts bursts"
  pass "fm-tmux-lib: a burst the fresh wintermolt TUI swallows is retyped and then confirmed"
}

test_wintermolt_slow_footer_still_confirms_the_steer() {
  local case_dir fakebin state verdict
  case_dir="$TMP_ROOT/submit-slow-footer"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # A footer that renders after the shared Enter budget is still a landed
  # steer: the read is granted the same poll budget the spawn gate grants it.
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_AFTER_DELAY=6 \
    FM_WINTERMOLT_DELIVERY_POLLS=10 FM_WINTERMOLT_POLL_INTERVAL=0.01 \
    fm_tmux_submit_core win 'steer text' 2 0.05 0.05)
  [ "$verdict" = empty ] \
    || fail "a footer that renders after the shared Enter budget must still confirm its steer, got '$verdict'"
  [ "$(cat "$state")" = busy ] \
    || fail "the slow footer should have rendered busy, pane state read '$(cat "$state")'"
  pass "fm-tmux-lib: a slow wintermolt footer still confirms the steer"
}

test_wintermolt_late_echo_is_not_replayed() {
  local case_dir fakebin state verdict bursts
  case_dir="$TMP_ROOT/submit-late-echo"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # The TUI takes the burst and echoes it a couple of reads later. One read
  # taken after the settle cannot prove nothing landed, so the replay is
  # authorised only by a read taken immediately before it - here that read sees
  # the echo, and the text is never written twice.
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" \
    FM_FAKE_WM_DEFER_BURST=1 FM_FAKE_WM_DEFER_READS=2 \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    fm_tmux_submit_core win 'steer text' 2 0.05 0.05)
  [ "$verdict" = empty ] \
    || fail "a burst the TUI echoes late must submit normally, got '$verdict'"
  bursts=$(cat "$state.bursts")
  [ "$bursts" = 1 ] \
    || fail "an echoing burst must never be replayed, got $bursts bursts"
  [ "$(cat "$state")" = busy ] \
    || fail "the late echo should still have been submitted, pane state read '$(cat "$state")'"
  pass "fm-tmux-lib: a wintermolt burst the TUI echoes late is never replayed"
}

test_wintermolt_unreadable_composer_keeps_the_caller_retry_budget() {
  local case_dir vfile polls
  case_dir="$TMP_ROOT/unknown-composer-budget"; mkdir -p "$case_dir"
  vfile="$case_dir/verdict"
  polls="$case_dir/polls"
  : > "$polls"
  # `bin/fm-control.sh exit` types /quit and the TUI leaves a shell whose bare
  # prompt reads unknown. That branch keeps the caller's Enter-retry budget: the
  # enlarged footer budget is only for the confirmation that follows a
  # submitted turn, so an exit must not poll a footer that can never render 60
  # times (~30s) before reporting the pane gone.
  (
    unset FM_COMPOSER_DIALOG_SINK
    # shellcheck disable=SC2329 # Invoked by fm_tmux_submit_enter_core below.
    fm_tmux_composer_state() { printf 'unknown'; }
    # shellcheck disable=SC2329 # Invoked by fm_tmux_submit_enter_core below.
    fm_pane_is_busy() { printf 'poll\n' >> "$polls"; return 1; }
    fm_tmux_submit_enter_core win 2 0.01 1 wintermolt
  ) > "$vfile" 2>/dev/null
  [ "$(cat "$vfile")" = unknown ] \
    || fail "an unreadable wintermolt composer must keep its unknown verdict, got '$(cat "$vfile")'"
  [ "$(wc -l < "$polls" | tr -d ' ')" = 2 ] \
    || fail "the unreadable-composer branch must keep the caller's retry budget, polled $(wc -l < "$polls") times"
  pass "fm-tmux-lib: an unreadable wintermolt composer keeps the caller retry budget"
}

test_wintermolt_last_permitted_burst_gets_the_grace_read() {
  local case_dir fakebin state verdict bursts
  case_dir="$TMP_ROOT/submit-last-burst"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # The swallow budget's last burst lands but echoes after the single read
  # taken at the settle, so only the same grace re-read every earlier burst
  # gets can see it. It must submit, not report a failed delivery.
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_SWALLOW=1 \
    FM_FAKE_WM_DEFER_BURST=2 FM_FAKE_WM_DEFER_READS=2 FM_WINTERMOLT_SUBMIT_ATTEMPTS=2 \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    fm_tmux_submit_core win 'steer text' 2 0.05 0.05)
  [ "$verdict" = empty ] \
    || fail "the last permitted burst that lands must submit, got '$verdict'"
  bursts=$(cat "$state.bursts")
  [ "$bursts" = 2 ] \
    || fail "the burst budget must stay at its configured count, got $bursts bursts"
  [ "$(cat "$state")" = busy ] \
    || fail "the last burst should have been submitted, pane state read '$(cat "$state")'"
  pass "fm-tmux-lib: the last permitted wintermolt burst is judged by the grace re-read"
}

test_wintermolt_burst_that_never_lands_does_not_confirm() {
  local case_dir fakebin state verdict bursts
  case_dir="$TMP_ROOT/submit-never-lands"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_LOSE=1 \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    fm_tmux_submit_core win 'steer text' 2 0.05 0.05)
  [ "$verdict" = send-failed ] \
    || fail "a steer that never reaches the composer must not confirm a submit, got '$verdict'"
  bursts=$(cat "$state.bursts")
  [ "$bursts" = 3 ] \
    || fail "the swallow retry must stop at its burst budget, got $bursts bursts"
  pass "fm-tmux-lib: a wintermolt burst that never lands never confirms a submit"
}

test_wintermolt_truncated_burst_is_never_submitted() {
  local case_dir fakebin state verdict bursts
  case_dir="$TMP_ROOT/submit-truncated"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # Live, the TUI kept only the tail of the burst and the submit reported a
  # confirmed steer for the fragment. A composer holding a fragment is neither
  # ours nor untouched, so it is never replayed onto and never submitted.
  # A pane width is passed too: the scroll-tail proof must never accept a
  # short fragment as the visible end of a long draft.
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_TRUNCATE=1 \
    FM_FAKE_WM_PANE_WIDTH=80 \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    fm_tmux_submit_core win 'steer text' 2 0.05 0.05)
  [ "$verdict" = send-failed ] \
    || fail "a truncated burst must not confirm a submit, got '$verdict'"
  bursts=$(cat "$state.bursts")
  [ "$bursts" = 1 ] \
    || fail "a composer holding a fragment must never be replayed onto, got $bursts bursts"
  [ "$(cat "$state")" = idle ] \
    || fail "a fragment must never be submitted as a turn, pane state read '$(cat "$state")'"
  pass "fm-tmux-lib: a wintermolt burst the TUI truncates is never submitted as a fragment"
}

test_wintermolt_long_steer_is_typed_in_chunks_that_land() {
  local case_dir fakebin state verdict text submitted
  case_dir="$TMP_ROOT/submit-chunked"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # Live, the 0.7.0 input loop keeps only the tail of one large literal write,
  # so a whole-message write reached the model as a fragment. The burst is
  # therefore typed in chunks its loop keeps, and the whole message - once -
  # is what the model receives. The chunk that starts at offset 32 begins with
  # `-`, so the write also has to keep tmux from reading it as a flag.
  text='Read the brief at /tmp/wm/launch-brief.md and follow it exactly.'
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_HEAD_DROP=16 \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    FM_WINTERMOLT_TYPE_INTERVAL=0 \
    fm_tmux_submit_core win "$text" 2 0.05 0.05)
  [ "$verdict" = empty ] \
    || fail "a long steer the TUI keeps only in chunks must submit, got '$verdict'"
  submitted=$(cat "$state.submitted")
  [ "$submitted" = "$text" ] \
    || fail "the model must receive the whole message, got '$submitted'"
  [ "$(wc -l < "$state.submitted" | tr -d ' ')" = 1 ] \
    || fail "the message must be submitted exactly once, got $(cat "$state.submitted")"
  [ "$(cat "$state.bursts")" = 1 ] \
    || fail "a landed chunked burst must never be replayed, got $(cat "$state.bursts") bursts"
  pass "fm-tmux-lib: a long wintermolt steer is typed in chunks the TUI keeps"
}

test_wintermolt_short_dash_steer_is_delivered() {
  local case_dir fakebin state verdict text submitted
  case_dir="$TMP_ROOT/submit-dash-steer"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # A short steer - at most the chunk size, so it takes the one-shot write -
  # that begins with a dash must still be delivered: tmux reads a leading `-`
  # as a flag unless the payload follows the end-of-flags marker.
  text='-1 retry'
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    fm_tmux_submit_core win "$text" 2 0.05 0.05)
  [ "$verdict" = empty ] \
    || fail "a short steer beginning with a dash must submit, got '$verdict'"
  submitted=$(cat "$state.submitted")
  [ "$submitted" = "$text" ] \
    || fail "the model must receive the dash-initial steer verbatim, got '$submitted'"
  pass "fm-tmux-lib: a short wintermolt steer beginning with a dash is delivered"
}

test_wintermolt_malformed_chunk_setting_still_delivers() {
  local bad case_dir fakebin state verdict text submitted
  text='Read the brief at /tmp/wm/launch-brief.md and follow it exactly.'
  # The chunk size is an operator knob, and its value is used both as a
  # substring length and as an arithmetic operand. A value that is not a plain
  # decimal integer used to stall the write loop (abc) or abort the process
  # (8x), wedging every wintermolt submit. It falls back to the verified
  # default instead, and the head-drop fixture proves the fallback still
  # chunks: a write longer than 16 characters loses its head and the message
  # would reach the model as a fragment.
  for bad in abc 8x 08 -8; do
    case_dir="$TMP_ROOT/submit-bad-chunk-$bad"; mkdir -p "$case_dir"
    fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
    state="$case_dir/wm.state"
    printf 'idle\n' > "$state"
    # shellcheck disable=SC2016 # $1/$2 expand inside the child shell.
    verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" FM_FAKE_WM_HEAD_DROP=16 \
      FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
      FM_WINTERMOLT_TYPE_INTERVAL=0 FM_WINTERMOLT_TYPE_CHUNK="$bad" \
      fm_run_timed 30 bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_tmux_submit_core win "$2" 2 0.05 0.05' \
      _ "$ROOT" "$text")
    [ "$verdict" = empty ] \
      || fail "chunk setting '$bad' must fall back to the default and submit, got '$verdict'"
    submitted=$(cat "$state.submitted")
    [ "$submitted" = "$text" ] \
      || fail "chunk setting '$bad' must still deliver the whole message, got '$submitted'"
    [ "$(wc -l < "$state.submitted" | tr -d ' ')" = 1 ] \
      || fail "chunk setting '$bad' must submit the message exactly once"
  done
  pass "fm-tmux-lib: a malformed wintermolt chunk setting falls back and still delivers"
}

test_wintermolt_scrolled_composer_confirms_the_whole_steer() {
  local case_dir fakebin state verdict text submitted
  case_dir="$TMP_ROOT/submit-scrolled"; mkdir -p "$case_dir"
  fakebin=$(make_wintermolt_pane_fakebin "$case_dir")
  state="$case_dir/wm.state"
  printf 'idle\n' > "$state"
  # Live, the composer is one row that scrolls horizontally: a wholly landed
  # long message shows only its tail. The exact comparison read that tail as
  # foreign content and refused the submit after it had already landed, so
  # `bin/fm-send.sh` exited 1 and the operator's resend was the duplicate.
  # The row's measured capacity turns the tail into proof, and the model still
  # receives the whole message exactly once.
  text='Read the brief at /tmp/wm/launch-brief.md and follow it exactly.'
  verdict=$(PATH="$fakebin:$PATH" FM_FAKE_WM_STATE="$state" \
    FM_FAKE_WM_SCROLL=30 FM_FAKE_WM_PANE_WIDTH=40 \
    FM_WINTERMOLT_DELIVERY_POLLS=2 FM_WINTERMOLT_POLL_INTERVAL=0 \
    FM_WINTERMOLT_TYPE_INTERVAL=0 \
    fm_tmux_submit_core win "$text" 2 0.05 0.05)
  [ "$verdict" = empty ] \
    || fail "a long steer a scrolling composer shows only the tail of must submit, got '$verdict'"
  submitted=$(cat "$state.submitted")
  [ "$submitted" = "$text" ] \
    || fail "the model must receive the whole message, got '$submitted'"
  [ "$(wc -l < "$state.submitted" | tr -d ' ')" = 1 ] \
    || fail "the message must be submitted exactly once, got $(cat "$state.submitted")"
  pass "fm-tmux-lib: a long steer the scrolled composer shows only the tail of still submits whole"
}

test_wintermolt_busy_classification_reads_only_the_last_row() {
  printf 'the build is still working\n%s\n' "$WM_FOOTER_IDLE" | fm_busy_lines_match wintermolt \
    && fail "a conversation row ending in the busy word above an idle footer must not read busy" || true
  printf 'the build is still working\n%s\n' "$WM_FOOTER_BUSY" | fm_busy_lines_match wintermolt \
    || fail "the busy footer below a conversation row must still read busy"
  printf '%s\n' "$WM_FOOTER_IDLE" | fm_busy_lines_match wintermolt \
    && fail "the idle footer must not read busy" || true
  pass "fm-composer-lib: wintermolt busy classification reads the pane's last row only"
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
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' \
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

# The rex backend surfaces the same claim depends on (docs/verification/
# wintermolt.md owns the live evidence): the idle placeholder resolves through
# the same scoped rule on rex's reset-separated cell shape, the composer reads
# empty only when the block's foreground process is wintermolt, and a wintermolt
# submit is confirmed through the turn-started transition on its own footer
# rather than through any other harness's verdict.
REX_IDLE_COMPOSER_RAW="│${WM_ESC}[0m${WM_ESC}[38;5;8m  ${WM_ESC}[0m${WM_ESC}[48;5;6mT${WM_ESC}[0m${WM_ESC}[38;5;8mype a message, or /help${WM_ESC}[0m$(wm_pad 14)│"
REX_DRAFT_COMPOSER_RAW="│${WM_ESC}[0m${WM_ESC}[38;5;8m  ${WM_ESC}[0mType a message, or /help${WM_ESC}[0m${WM_ESC}[48;5;6m ${WM_ESC}[49m$(wm_pad 12)│"

# _rex_foreground: one fake rex process chain for <name>.
_rex_foreground() {  # <name>
  printf 'foreground\t4242\t%s\t/tmp/%s\t%s\n' "$1" "$1" "$1"
}

test_wintermolt_rex_idle_placeholder_reads_empty_and_draft_stays_pending() {
  local screen verdict
  screen=$(wm_composer_screen "$REX_IDLE_COMPOSER_RAW" "$WM_FOOTER_IDLE")
  verdict=$(
    RSTATE_SCREEN=$screen
    fm_backend_rex_screen_read() { FM_BACKEND_REX_SCREEN=$RSTATE_SCREEN; FM_BACKEND_REX_CURSOR_Y=''; }
    fm_backend_rex_process_chain() { FM_BACKEND_REX_CHAIN=$(printf 'foreground\t4242\twintermolt\t/tmp/wintermolt\twintermolt'); }
    fm_backend_rex_composer_state probe
  )
  [ "$verdict" = empty ] \
    || fail "a rex wintermolt pane on its idle placeholder must read empty, got '$verdict'"
  screen=$(wm_composer_screen "$REX_DRAFT_COMPOSER_RAW" "$WM_FOOTER_IDLE")
  verdict=$(
    RSTATE_SCREEN=$screen
    fm_backend_rex_screen_read() { FM_BACKEND_REX_SCREEN=$RSTATE_SCREEN; FM_BACKEND_REX_CURSOR_Y=''; }
    fm_backend_rex_process_chain() { FM_BACKEND_REX_CHAIN=$(printf 'foreground\t4242\twintermolt\t/tmp/wintermolt\twintermolt'); }
    fm_backend_rex_composer_state probe
  )
  # The draft carries rex's trailing cursor cell, so the shared classifier may
  # answer pending or pending-unproven; what must never happen is empty.
  [ "$verdict" = pending ] || [ "$verdict" = pending-unproven ] \
    || fail "a rex draft spelling the placeholder must read its own draft, got '$verdict'"
  pass "rex: the wintermolt idle placeholder reads empty and a draft never does"
}

test_wintermolt_rex_scope_is_gated_on_its_own_foreground_process() {
  local screen verdict
  screen=$(wm_composer_screen "$REX_IDLE_COMPOSER_RAW" "$WM_FOOTER_IDLE")
  # A pane whose foreground process is another harness keeps the plain read, so
  # the wintermolt placeholder rule never moves that harness's verdict.
  verdict=$(
    RSTATE_SCREEN=$screen
    fm_backend_rex_screen_read() { FM_BACKEND_REX_SCREEN=$RSTATE_SCREEN; FM_BACKEND_REX_CURSOR_Y=''; }
    fm_backend_rex_process_chain() { FM_BACKEND_REX_CHAIN=$(printf 'foreground\t4242\tbash\t/bin/bash\tbash'); }
    fm_backend_rex_composer_state probe
  )
  [ "$verdict" != empty ] \
    || fail "only a wintermolt foreground may take the wintermolt composer scope, got '$verdict'"
  pass "rex: the wintermolt composer scope is gated on the block's foreground process"
}

test_wintermolt_rex_delivery_busy_is_scoped_to_its_own_footer() {
  local seen
  seen=$(
    fm_backend_rex_busy_state() { printf 'unknown'; }
    fm_backend_rex_rendered_busy_state() { printf '%s' "${2:-}"; }
    fm_backend_rex_process_chain() { FM_BACKEND_REX_CHAIN=$(printf 'foreground\t4242\twintermolt\t/tmp/wintermolt\twintermolt'); }
    fm_backend_rex_delivery_busy probe
  )
  [ "$seen" = wintermolt ] \
    || fail "a wintermolt pane must read its own footer signature, got '$seen'"
  seen=$(
    fm_backend_rex_busy_state() { printf 'unknown'; }
    fm_backend_rex_rendered_busy_state() { printf '[%s]' "${2:-}"; }
    fm_backend_rex_process_chain() { FM_BACKEND_REX_CHAIN=$(printf 'foreground\t4242\tbash\t/bin/bash\tbash'); }
    fm_backend_rex_delivery_busy probe
  )
  [ "$seen" = '[]' ] \
    || fail "a non-wintermolt pane must keep the harness-less busy union, got '$seen'"
  pass "rex: the delivery busy read is wintermolt-scoped only on a wintermolt pane"
}

# _rex_submit_verdict <composer-state-after-enter> <busy-after-enter> <foreground>
# The pane stands idle before the write and renders <busy-after-enter> after it.
_rex_submit_verdict() {  # <after-enter> <after-busy> <foreground>
  local after=$1 after_busy=$2 fg=$3 phase=before
  (
    fm_backend_rex_parse_target() { return 0; }
    fm_backend_rex_process_chain() { FM_BACKEND_REX_CHAIN=$(printf 'foreground\t4242\t%s\t/tmp/%s\t%s' "$fg" "$fg" "$fg"); }
    fm_backend_rex_type_literal() { phase=after; return 0; }
    fm_backend_rex_composer_text() { printf ''; }
    fm_backend_rex_typed_state() { printf 'held'; }
    fm_backend_rex_send_key() { return 0; }
    fm_backend_rex_composer_state() { printf '%s' "$after"; }
    fm_backend_rex_busy_state() { printf 'unknown'; }
    fm_backend_rex_rendered_busy_state() {
      case "$phase" in
        before) printf 'idle' ;;
        *) printf '%s' "$after_busy" ;;
      esac
    }
    fm_backend_rex_send_text_submit probe 'the brief pointer' 1 0.01 0.01
  )
}

# The measured narrow-block geometry: an 80-column block leaves a 70-character
# composer row, and the brief pointer is wider than that. A suffix read once at
# the end cannot tell that whole payload from a headless fragment of the same
# width, so the writer proves each prefix as it lands instead.
WM_REX_LONG_PAYLOAD="Read the brief at /Users/philipp/.treehouse/firstmate-b8697d/4/firstmate/data/fm-wintermolt-rex/brief.md"
WM_REX_NARROW_CAPACITY=70

# _rex_shim_writer <mode> <payload> <chunk> <capacity>
# <mode> faithful lands every chunk; headloss drops the head of the first burst
# the way the real block does on a large single write.
_rex_shim_writer() {  # <mode> <payload> <chunk> <capacity>
  local mode=$1 payload=$2 chunk=$3 cap=$4 state
  state=$(mktemp "${TMPDIR:-/tmp}/fm-rex-shim.XXXXXX")
  (
    REX_SIM_STATE=$state
    REX_SIM_MODE=$mode
    fm_backend_rex_parse_target() { return 0; }
    fm_backend_rex_type_literal() {  # <target> <slice> [chunk] [interval]
      local slice=$2
      if [ "$REX_SIM_MODE" = headloss ] && [ ! -s "$REX_SIM_STATE" ]; then
        printf '%s' "${slice: -2}" >>"$REX_SIM_STATE"
      else
        printf '%s' "$slice" >>"$REX_SIM_STATE"
      fi
      return 0
    }
    fm_backend_rex_composer_state() {
      [ -s "$REX_SIM_STATE" ] && printf 'pending' || printf 'empty'
    }
    fm_backend_rex_composer_text() { cat "$REX_SIM_STATE" 2>/dev/null; }
    fm_backend_rex_type_literal_verified probe "$payload" "$chunk" 0 "$cap"
  )
  rm -f "$state"
}

test_wintermolt_rex_long_payload_is_proved_prefix_by_prefix() {
  local out
  out=$(_rex_shim_writer faithful "$WM_REX_LONG_PAYLOAD" 8 "$WM_REX_NARROW_CAPACITY")
  [ "$out" = held ] \
    || fail "a payload wider than the row that lands whole must prove held, got '$out'"
  # The head of the first burst is lost, so the composer's tail fills the row but
  # is not the payload's. A single end read would accept that suffix; the prefix
  # proof refuses it.
  out=$(_rex_shim_writer headloss "$WM_REX_LONG_PAYLOAD" 8 "$WM_REX_NARROW_CAPACITY")
  [ "$out" = other ] \
    || fail "a headless fragment must never be read as held, got '$out'"
  pass "rex: a long payload is proved prefix by prefix and a headless fragment is refused"
}

test_wintermolt_rex_submit_confirms_through_the_turn_started_transition() {
  local verdict
  verdict=$(_rex_submit_verdict pending-unproven busy wintermolt)
  [ "$verdict" = empty ] \
    || fail "an idle wintermolt pane that goes busy across our Enter must confirm, got '$verdict'"
  verdict=$(_rex_submit_verdict pending-unproven idle wintermolt)
  [ "$verdict" = pending-unproven ] \
    || fail "a wintermolt pane that never goes busy must stay unproven, got '$verdict'"
  verdict=$(_rex_submit_verdict pending-unproven busy bash)
  [ "$verdict" = pending-unproven ] \
    || fail "another harness's pending-unproven must never be converted, got '$verdict'"
  pass "rex: a wintermolt submit confirms only on the idle-to-busy transition"
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
INNER=$WM_INNER_WIDTH
printf '%s\n' "\$*" >> "\${FM_FAKE_TMUX_CALL_LOG:-/dev/null}"
state=\$(cat "\${FM_FAKE_WM_STATE:-/dev/null}" 2>/dev/null || printf 'shell')
styled=
for arg in "\$@"; do
  [ "\$arg" = "-e" ] && styled=1
done
$(declare -f wm_fake_draft_rows)
fake_draft() {
  [ -f "\${FM_FAKE_WM_STATE}.draft" ] || return 1
  cat "\${FM_FAKE_WM_STATE}.draft"
}
fake_screen() {
  if [ -n "\$styled" ]; then
    case "\$state" in
      launched)
        printf '%s\n' "$WM_TOP"
        if draft=\$(fake_draft); then wm_fake_draft_rows "\$INNER" "\$draft"; else printf '%s\n' "$WM_IDLE_COMPOSER_RAW"; fi
        printf '%s\n%s\n' "$WM_BOTTOM" "$WM_FOOTER_IDLE"
        ;;
      busy) printf '%s\n' "$WM_TOP" "$WM_BUSY_COMPOSER_RAW" "$WM_BOTTOM" "$WM_FOOTER_BUSY" ;;
      *) printf 'shell prompt\n\$ \n' ;;
    esac
  else
    case "\$state" in
      launched)
        if draft=\$(fake_draft); then
          printf 'conversation\n%s\n%s\n%s\n%s\n' "$WM_TOP" "  \$draft" "$WM_BOTTOM" "$WM_FOOTER_IDLE"
        else
          printf 'conversation\n%s\n%s\n%s\n%s\n' "$WM_TOP" "$(wm_inner_plain '  Type a message, or /help')" "$WM_BOTTOM" "$WM_FOOTER_IDLE"
        fi
        ;;
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
    # where the whole text is ONE positional argument. tmux ends flag parsing
    # at the double-dash marker, so a literal write's marker is consumed and
    # the argument after it is still the payload, never a positional.
    literal=
    prev=
    skip=
    pos=()
    for arg in "\$@"; do
      if [ -n "\$skip" ]; then skip=""; continue; fi
      if [ "\$prev" = "-l" ]; then
        [ "\$arg" = "--" ] && continue
        literal=\$arg; prev=""; continue
      fi
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
          # The brief pointer: the composer holds it until the Enter that
          # starts the brief turn, so the submit core can verify the typed
          # text, and the plain-Enter branch below submits it.
          printf '%s' "\$literal" > "\${FM_FAKE_WM_STATE:?}.draft"
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
        rm -f "\${FM_FAKE_WM_STATE:?}.pending" "\${FM_FAKE_WM_STATE:?}.draft"
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

test_wintermolt_accepts_a_slash_namespaced_model_id() {
  local id rec out rc launch meta
  id="wm-model-z2-$$"
  rec=$(make_wintermolt_spawn_case model-slash "$id")
  read_wintermolt_spawn_record "$rec"
  # An OpenAI-compatible gateway names its own models, and those names carry a
  # slash (OpenRouter's anthropic/claude-sonnet-4, LiteLLM's openai/gpt-4o, a
  # vLLM repo id). The id is the backend's, never a firstmate provider prefix,
  # so it is accepted and carried verbatim.
  out=$(run_wintermolt_spawn "$CASE_DIR" "$HOME_DIR" "$PROJ_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" \
    --model anthropic/claude-sonnet-4)
  rc=$?
  expect_code 0 "$rc" "a slash-namespaced wintermolt model id must launch: $out"
  launch=$(cat "$CASE_DIR/launch.log")
  assert_contains "$launch" "WINTERMOLT_MODEL='anthropic/claude-sonnet-4'" \
    "the model id must reach the launch unchanged"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=anthropic/claude-sonnet-4' "$meta" \
    "the recorded model must be the id as given"
  pass "fm-spawn: wintermolt accepts a slash-namespaced backend model id verbatim"
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
  expect_code 1 "$rc" "a wintermolt launch on a backend without proven surfaces must be refused"
  assert_contains "$out" "verified on the tmux and rex backends only" "the refusal must name the verified-backend boundary"
  assert_not_contains "$out" "backend=rex is unsupported" "rex must not be refused any more"
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
test_wintermolt_submit_busy_read_resolves_its_own_signature
test_wintermolt_steer_confirmation_uses_the_busy_transition
test_wintermolt_swallowed_burst_is_retyped_before_submit
test_wintermolt_slow_footer_still_confirms_the_steer
test_wintermolt_late_echo_is_not_replayed
test_wintermolt_unreadable_composer_keeps_the_caller_retry_budget
test_wintermolt_last_permitted_burst_gets_the_grace_read
test_wintermolt_burst_that_never_lands_does_not_confirm
test_wintermolt_truncated_burst_is_never_submitted
test_wintermolt_long_steer_is_typed_in_chunks_that_land
test_wintermolt_short_dash_steer_is_delivered
test_wintermolt_malformed_chunk_setting_still_delivers
test_wintermolt_scrolled_composer_confirms_the_whole_steer
test_wintermolt_busy_classification_reads_only_the_last_row
test_wintermolt_classify_reads_the_rendered_tail
test_wintermolt_idle_composer_reads_empty_only_through_the_scope
test_wintermolt_draft_and_busy_rows_stay_pending
test_wintermolt_footer_furniture_bounds_the_box
test_wintermolt_idle_placeholder_is_fleet_wide
test_wintermolt_rex_idle_placeholder_reads_empty_and_draft_stays_pending
test_wintermolt_rex_scope_is_gated_on_its_own_foreground_process
test_wintermolt_rex_delivery_busy_is_scoped_to_its_own_footer
test_wintermolt_rex_long_payload_is_proved_prefix_by_prefix
test_wintermolt_rex_submit_confirms_through_the_turn_started_transition
test_wintermolt_launch_pins_the_env_contract_and_delivers_the_pointer
test_wintermolt_accepts_a_slash_namespaced_model_id
test_wintermolt_refuses_a_secondmate_and_other_backends
test_wintermolt_spawn_fails_loudly_when_the_tui_never_becomes_ready
test_wintermolt_xhigh_effort_is_recorded_but_omitted
