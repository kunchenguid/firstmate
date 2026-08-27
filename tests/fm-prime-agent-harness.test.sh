#!/usr/bin/env bash
# Behavior tests for the prime-agent (Prime Agent) adapter: Pi-family harness
# disambiguation and the crewmate/scout launch shape.
#
# Detection here is a safety boundary rather than a convenience, and it is
# driven from BOTH directions so neither case can go quietly vacuous:
# prime-agent exports the same PI_CODING_AGENT=true as pi, so detection has to
# split the family on a second signal and must still answer `pi` when no such
# signal is present, and `claude` when a stale prime-agent marker appears with
# no Pi-family marker at all.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-prime-agent-harness)

# --- detection --------------------------------------------------------------

detect() {  # <env assignment>...
  env -u CLAUDECODE -u GROK_AGENT -u FM_PI_HARNESS \
    -u PRIME_AGENT_CODING_AGENT_DIR -u PRIME_AGENT_INTERNAL_DAEMON_WORKER \
    "$@" "$HARNESS"
}

test_detection_splits_the_pi_family() {
  local out

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=prime-agent)
  [ "$out" = prime-agent ] || fail "FM_PI_HARNESS=prime-agent did not select prime-agent (got '$out')"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/home/x/.prime/agent)
  [ "$out" = prime-agent ] || fail "prime-agent's own tool-subprocess marker did not select it (got '$out')"

  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_INTERNAL_DAEMON_WORKER=1)
  [ "$out" = prime-agent ] || fail "prime-agent's daemon-worker marker did not select it (got '$out')"

  # The other direction: the SAME PI_CODING_AGENT marker with no prime-agent
  # signal must still be pi, or every existing Pi worker would be relabelled.
  out=$(detect PI_CODING_AGENT=true)
  [ "$out" = pi ] || fail "unmarked Pi-family ancestry stopped resolving to pi (got '$out')"

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)
  [ "$out" = pi-signed ] || fail "pi-signed selection regressed (got '$out')"

  # FM_PI_HARNESS is subject to the SAME supervisor inheritance as CLAUDECODE:
  # a supervisor first started from a pi-signed worker hands it to every later
  # prime-agent worker. The per-tool-call vendor marker must therefore outrank
  # it too, or that worker reports itself as a Pi it is not.
  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = prime-agent ] \
    || fail "an inherited FM_PI_HARNESS outranked prime-agent's own marker (got '$out')"

  out=$(detect PI_CODING_AGENT=true FM_PI_HARNESS=pi PRIME_AGENT_INTERNAL_DAEMON_WORKER=1 CLAUDECODE=1)
  [ "$out" = prime-agent ] \
    || fail "an inherited launch stamp plus CLAUDECODE outranked the daemon-worker marker (got '$out')"

  # An empty marker value is not a marker.
  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=)
  [ "$out" = pi ] || fail "an empty prime-agent marker was treated as present (got '$out')"

  # prime-agent's resident worker inherits the long-lived daemon supervisor's
  # environment, so a CLAUDECODE captured by that supervisor reaches every
  # later prime-agent tool subprocess and no launch-side clear can remove it.
  # The vendor marker must therefore outrank it.
  out=$(detect PI_CODING_AGENT=true PRIME_AGENT_CODING_AGENT_DIR=/x CLAUDECODE=1)
  [ "$out" = prime-agent ] \
    || fail "an inherited CLAUDECODE outranked prime-agent's own marker (got '$out')"

  # The other direction, so the precedence flip is not a blanket one: a lone
  # stale PRIME_AGENT_* with no Pi-family marker must not relabel claude.
  out=$(detect CLAUDECODE=1 PRIME_AGENT_CODING_AGENT_DIR=/x)
  [ "$out" = claude ] \
    || fail "a stale prime-agent marker alone outranked claude (got '$out')"

  out=$(detect CLAUDECODE=1)
  [ "$out" = claude ] || fail "claude detection regressed (got '$out')"

  pass "detection splits prime-agent from pi without relabelling unmarked Pi or claude sessions"
}

# --- spawn ------------------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -z "${FM_FAKE_EXISTING_WINDOW:-}" ] || printf '%s\n' "$FM_FAKE_EXISTING_WINDOW"
    exit 0
    ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> -> case_dir|home|proj|wt|fakebin|id
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="prime-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <launch-log> <args>...
  local home=$1 proj=$2 wt=$3 fakebin=$4 log=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" FM_FAKE_LAUNCH_LOG="$log" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_spawn_crewmate_launch_shape() {
  local case_dir home proj wt fakebin id log out status launch ext
  IFS='|' read -r case_dir home proj wt fakebin id < <(make_case launch)
  log="$case_dir/launch.log"
  : > "$log"

  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$log" \
    "$id" "$proj" --scout --harness prime-agent \
    --model gpt-5.6-luna --effort low) && status=0 || status=$?
  expect_code 0 "$status" "prime-agent scout spawn failed: $out"

  launch=$(grep -F 'prime-agent' "$log" | tail -1)
  [ -n "$launch" ] || fail "no prime-agent launch command was sent to the pane"

  ext="$home/state/$id.prime-ext.ts"
  assert_present "$ext" "spawn did not write the prime-agent extension"
  # The launch must load the extension file the spawn actually wrote: a path
  # disagreement would silently leave the pane with no busy source at all.
  assert_contains "$launch" "-e '$ext'" "launch does not load the extension spawn wrote"
  # The launch-boundary identity marker is what lets a tool subprocess tell
  # prime-agent apart from pi (see test_detection_splits_the_pi_family).
  assert_contains "$launch" 'FM_PI_HARNESS=prime-agent' "launch does not stamp the Pi-family identity"
  # A foreign primary marker left in the backend daemon's stored environment
  # outranks the whole Pi family in bin/fm-harness.sh, so the launch must clear
  # it or the crewmate reports itself as that other harness.
  assert_contains "$launch" 'env -u CLAUDECODE -u GROK_AGENT' \
    "launch does not clear foreign primary harness markers"
  assert_not_contains "$launch" '-u FM_PI_HARNESS' \
    "launch clears the very identity marker it just set"
  assert_contains "$launch" "--model 'gpt-5.6-luna'" "model flag missing"
  assert_contains "$launch" "--thinking 'low'" "effort did not map onto --thinking"

  assert_grep 'harness=prime-agent' "$home/state/$id.meta" "meta does not record the harness"
  # Deliberately NOT armed: the crew extension carries only the turn-end wake
  # touch, so there is no firstmate writer that could ever clear a seeded busy
  # record.
  assert_absent "$home/state/$id.busy-gen" \
    "spawn armed a busy record prime-agent has no writer to clear"

  pass "prime-agent crewmate spawn loads its own extension and stamps its identity"
}

# --- composer ---------------------------------------------------------------
#
# prime-agent draws NO composer border: its editor renders a full-width
# background surface and puts its own `> ` prompt prefix on it. Under the shared
# bare-glyph safety rule that idle row would read `unknown` (a dead shell), and
# fm-send accepts only an exact `empty` as proof a steer was submitted, so every
# steer to a prime-agent crewmate would report delivery unconfirmed. These cases
# drive the real tmux row classifier - the same entry point fm_tmux_composer_state
# uses for a borderless pane - over rows built the way prime-agent renders them.

# shellcheck source=bin/fm-tmux-lib.sh
. "$ROOT/bin/fm-tmux-lib.sh"

ESC=$(printf '\033')
PRIME_BG="${ESC}[48;2;24;24;27m"
PRIME_BG_OFF="${ESC}[49m"
PRIME_HINT_FG="${ESC}[38;2;113;113;122m"
PRIME_CURSOR="${ESC}[7m ${ESC}[27m"

# row_state <raw-row>: the borderless-pane verdict, with the busy-footer
# shortcut off so the composer classification is what is under test.
row_state() { fm_tmux_composer_row_state "$1" 0 0; }

test_prime_agent_composer_proves_empty_and_pending() {
  local out

  out=$(row_state "$PRIME_BG > $PRIME_HINT_FG"'Try "refactor @<filepath>"'"$PRIME_BG_OFF")
  [ "$out" = empty ] \
    || fail "an idle prime-agent composer must prove empty so fm-send can confirm delivery (got '$out')"

  out=$(row_state "$PRIME_BG > $PRIME_CURSOR$PRIME_BG_OFF")
  [ "$out" = empty ] \
    || fail "a hintless idle prime-agent composer must prove empty (got '$out')"

  # The placeholder is registered as an idle pattern as well as ghost-stripped,
  # so a theme that renders it too bright to strip still reads empty rather than
  # pinning the composer at pending forever.
  out=$(row_state "$PRIME_BG > ${ESC}[38;2;200;200;200m"'Try "explain how @<filepath> works"'"$PRIME_BG_OFF")
  [ "$out" = empty ] \
    || fail "a bright-themed prime-agent start hint must still read empty (got '$out')"

  out=$(row_state "$PRIME_BG > hello steer$PRIME_CURSOR$PRIME_BG_OFF")
  [ "$out" = pending ] \
    || fail "unsubmitted text in a prime-agent composer must read pending (got '$out')"

  pass "prime-agent's borderless composer proves empty when idle and pending when typed"
}

test_prime_agent_surface_does_not_weaken_the_dead_shell_rule() {
  local out

  # The pane prime-agent leaves behind on exit: a plain shell prompt with no
  # background surface. It must stay unknown - never a safe injection target.
  out=$(row_state '> ')
  [ "$out" = unknown ] \
    || fail "a bare shell prompt with no composer surface must stay unknown (got '$out')"

  out=$(row_state "${ESC}[0m> ")
  [ "$out" = unknown ] \
    || fail "a styled but unfilled shell prompt row must stay unknown (got '$out')"

  # A dead shell that happens to colour its prompt FOREGROUND is still a dead
  # shell: only a background surface identifies the composer container.
  out=$(row_state "${ESC}[38;2;148;2;53m> ${ESC}[39m")
  [ "$out" = unknown ] \
    || fail "a foreground-coloured shell prompt must not be read as a composer surface (got '$out')"

  # A foreground run carries arbitrary colour components, so 48 appears inside
  # one as an ordinary red/green/blue value. Only a 48 in a real SGR PARAMETER
  # position introduces a background, and reading it as a substring would
  # promote any coloured dead-shell prompt to a safe injection target.
  out=$(row_state "${ESC}[38;2;48;120;200m> ")
  [ "$out" = unknown ] \
    || fail "a 48 inside a foreground colour payload must not read as a background surface (got '$out')"

  out=$(row_state "${ESC}[1;38;2;200;48;10m>")
  [ "$out" = unknown ] \
    || fail "a 48 in a later foreground colour component must not read as a background surface (got '$out')"

  out=$(row_state "${ESC}[38:2::48:120:200m> ")
  [ "$out" = unknown ] \
    || fail "a 48 inside a colon-form foreground colour must not read as a background surface (got '$out')"

  # Basic 40-47 backgrounds stay outside the promotion: prime-agent's theme
  # emits the truecolor or 256-colour form, so an unrecognized surface degrades
  # to unknown rather than widening the rule past the verified evidence.
  out=$(row_state "${ESC}[44m> ")
  [ "$out" = unknown ] \
    || fail "a basic background colour is not prime-agent's verified surface (got '$out')"

  # The verified shape is a `> ` prompt drawn ON the surface. The opposite
  # arrangement - a foreground-coloured shell prompt with background-filled
  # padding after it - is a dead shell, and promoting it would hand
  # fm_pane_input_pending the exact proof it accepts before an escalation is
  # typed into the pane.
  out=$(row_state "${ESC}[1;32m> ${ESC}[48;2;40;40;40m ${ESC}[0m")
  [ "$out" = unknown ] \
    || fail "a background opening AFTER the prompt glyph must not read as a composer surface (got '$out')"

  # A background that is already CLOSED at the glyph is not a surface the glyph
  # sits on either: a shell prompt that paints a coloured segment, resets, and
  # then draws `>` is still a dead shell.
  out=$(row_state "${ESC}[48;2;40;40;40m ${ESC}[0m> ")
  [ "$out" = unknown ] \
    || fail "a background closed by SGR 0 before the glyph must not read as a composer surface (got '$out')"

  out=$(row_state "${ESC}[48;5;236m ${ESC}[49m> ")
  [ "$out" = unknown ] \
    || fail "a background closed by SGR 49 before the glyph must not read as a composer surface (got '$out')"

  # Terminals read SGR parameters numerically, and zero padding is ordinary in
  # real prompts (Debian's stock .bashrc PS1 emits ESC[00m), so a padded
  # parameter must carry the same meaning as its bare form.
  out=$(row_state "${ESC}[48;2;40;40;40m ${ESC}[00m> ")
  [ "$out" = unknown ] \
    || fail "a zero-padded SGR 0 must close the background like a bare 0 (got '$out')"

  out=$(row_state "${ESC}[48;5;236m ${ESC}[049m> ")
  [ "$out" = unknown ] \
    || fail "a zero-padded SGR 49 must close the background like a bare 49 (got '$out')"

  out=$(row_state "${ESC}[48;2;40;40;40m ${ESC}[039;049m> ")
  [ "$out" = unknown ] \
    || fail "a zero-padded 49 after a padded 39 must close the background (got '$out')"

  # A padded foreground introducer must still consume its own payload, or the
  # 48 inside it is walked as a parameter and opens a background that no
  # terminal ever painted.
  out=$(row_state "${ESC}[038;2;48;120;200m> ")
  [ "$out" = unknown ] \
    || fail "a zero-padded foreground introducer must skip its colour payload (got '$out')"

  pass "prime-agent's composer surface does not weaken the shared dead-shell rule"
}

# The surface is identified from the SGR parameter list, not from one hard-coded
# theme colour, so every form prime-agent's theme can emit for `userMessageBg`
# has to land on the same verdict.
test_prime_agent_surface_covers_every_background_form() {
  local out

  out=$(row_state "${ESC}[48;5;235m> $PRIME_CURSOR$PRIME_BG_OFF")
  [ "$out" = empty ] \
    || fail "a 256-colour composer surface must prove empty (got '$out')"

  out=$(row_state "${ESC}[48:2::24:24:27m> $PRIME_CURSOR$PRIME_BG_OFF")
  [ "$out" = empty ] \
    || fail "a colon-form truecolor composer surface must prove empty (got '$out')"

  out=$(row_state "${ESC}[38;2;200;200;200;48;2;24;24;27m> $PRIME_CURSOR$PRIME_BG_OFF")
  [ "$out" = empty ] \
    || fail "a background introduced after a foreground run must prove empty (got '$out')"

  pass "prime-agent's composer surface is recognized in every background SGR form"
}

test_detection_splits_the_pi_family
test_spawn_crewmate_launch_shape
test_prime_agent_composer_proves_empty_and_pending
test_prime_agent_surface_does_not_weaken_the_dead_shell_rule
test_prime_agent_surface_covers_every_background_form
