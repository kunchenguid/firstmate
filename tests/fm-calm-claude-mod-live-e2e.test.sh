#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code Calm mod
# (.claude/mods/firstmate-calm) in a real Claude Code TUI under tmux, mirroring the
# Pi interactive case in tests/fm-calm-pi-extension.test.sh. It proves, against the
# installed Claude Code and the shipped project auto-load path (.claude/skills):
#   1. With CLAUDE_CODE_ENABLE_FUNCTION_HOOKS unset, the mod is a complete no-op even
#      with the per-home preference already on: no hooks module loads, /calm is not a
#      command, the stock working row shows, and tool rows draw as stock.
#   2. With the flag on, the sailboat replaces the working row and moves, tool rows and
#      a record-backed operational doorbell (the carrier Firstmate types into Claude
#      Code, which strips U+2063 from submitted prompts) draw at zero height, /calm
#      restores them and persists off, /calm hides them again and persists on, all
#      without a Calm output row in the transcript.
#   3. `claude --continue` restores the transcript with those rows still hidden.
#   4. With Calm off, the supervision notes draw from a store bin/fm-branch-outcome.sh
#      writes: the session-start replay, new sailboat and anchor lines, and the latch
#      note, each drawn behind the plugin's `fm:` label rather than `firstmate-calm:`,
#      without moving a store marker or reaching the model, and a resume shows each
#      anchor once.
#   5. The effort cue names a level only once a request has carried it, paints each
#      level in a distinct theme color, and moves the real setting through /effort-cycle
#      and the band's own focus-and-press keys, putting the starting level back on exit.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication and one trusted temporary folder. A few Haiku turns are submitted, and
# two Sonnet turns for the effort cue, because Haiku has no effort parameter.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_CALM_LIVE_E2E claude tmux

MOD="$ROOT/.claude/mods/firstmate-calm"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-calm-claude-live)
PROJECT="$LAB/project"
FM_HOME_DIR="$LAB/fmhome"
DEBUG_LOG_OFF="$LAB/debug-off.log"
DEBUG_LOG_ON="$LAB/debug-on.log"
DEBUG_LOG_RESUME="$LAB/debug-resume.log"
DEBUG_LOG_EFFORT="$LAB/debug-effort.log"
SOCKET="fm-calm-claude-$$"
SESSION="fm-calm-claude-e2e"
# Haiku has no effort parameter, so the effort section launches on a model that does.
MODEL=haiku
EFFORT_MODEL=sonnet
HULL='╲▁▁▁╱'
SAIL='◿│◣'
# The cue's rule, the run of box-drawing dashes it fills its row with. The composer draws
# full-width rules of its own, so a row counts as the cue only when it also carries one of
# the level glyphs the cue leads with.
EFFORT_RULE='────────'

# Claude Code 2.1.280 asks to confirm the first raise of effort after a turn, because the
# conversation is cached at the level in force; its cursor starts on the option that switches.
EFFORT_CONFIRM='Change effort level?'

effort_confirmation_open() {  # <screen text>
  case "$1" in
    *"$EFFORT_CONFIRM"*) return 0 ;;
  esac
  return 1
}

# Wait a moment for that confirmation after an effort change and accept it when it opens.
settle_effort_change() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if effort_confirmation_open "$(screen)"; then
      enter
      sleep 1
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
}

# The effort level the live session was found at, recorded before anything can move it.
# `/effort` writes the operator's own `modelSettings.<model>.effortLevel`, which no lab
# directory isolates, so this level is the captain's and must be put back on every exit.
EFFORT_STARTED_AT=""

# Put that level back through the live session, which is the only way to move the setting.
# It runs from the exit trap as well as from the end of the section, so a case that fails
# between the first step and the end still restores; when no session is left to run it, the
# captain is told what to set by hand rather than left to find out later.
restore_effort_level() {
  local want i=0
  [ -n "$EFFORT_STARTED_AT" ] || return 0
  want=$(badge_for "$EFFORT_STARTED_AT")
  if tmux -L "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
    case "$(screen)" in
      *'CLAUDE_EXIT='*) : ;;
      *)
        # A focused band or an open dialog would swallow the command; leave them first.
        tmux -L "$SOCKET" send-keys -t "$SESSION" Escape 2>/dev/null || true
        sleep 0.5
        send "/effort $EFFORT_STARTED_AT"
        enter
        while [ "$i" -lt 100 ]; do
          effort_confirmation_open "$(screen)" && enter
          if [ "$(badge_level "$(screen)")" = "$want" ]; then
            EFFORT_STARTED_AT=""
            return 0
          fi
          sleep 0.1
          i=$((i + 1))
        done
        ;;
    esac
  fi
  printf 'warning: this run left the effort level moved; restore it with /effort %s\n' \
    "$EFFORT_STARTED_AT" >&2
  return 1
}

cleanup() {
  local i=0
  restore_effort_level || true
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  # Claude's debug logger may still be flushing into the lab for a moment.
  while [ "$i" -lt 20 ] && pgrep -f "debug-file '$LAB/" >/dev/null 2>&1; do
    sleep 0.25
    i=$((i + 1))
  done
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude/skills" "$FM_HOME_DIR/config"
ln -s "$MOD" "$PROJECT/.claude/skills/firstmate-calm"
printf 'alpha\nbeta\ngamma\n' >"$PROJECT/notes.txt"
printf 'on\n' >"$FM_HOME_DIR/config/calm"

# Claude Code refuses to nest inside another Claude session, so the inherited session
# markers are dropped from the lab's environment; the flag is set per launch only.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

launch() {  # <debug-log> <flag: 1|0> [claude args...]
  local log=$1 flag=$2 flag_env=''
  shift 2
  [ "$flag" = 1 ] && flag_env="CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1"
  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 44 -c "$PROJECT" \
    "env $(unset_inherited) $flag_env FM_HOME='$FM_HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model $MODEL --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --debug-file '$log' $*; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

send() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
}

enter() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

# Whether the screen is a startup dialog rather than the session: the folder-trust
# dialog draws its own option cursor with the composer's glyph, so it is answered
# before any text is matched.
dialog_open() {  # <screen text>
  case "$1" in
    *'trust this folder'*|*'Enter to confirm'*) return 0 ;;
  esac
  return 1
}

# The folder-trust dialog opens with its cursor on "No, exit", so Enter alone would
# end the session: move the cursor onto the trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
}

# Wait until the screen shows <text> (a fixed string), answering the folder-trust
# dialog on the way; the wait is iteration-counted so it stretches under load.
wait_screen() {  # <text> <what> [iterations]
  local text=$1 what=$2 limit=${3:-400} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    if dialog_open "$shot"; then
      answer_trust_dialog "$shot"
    else
      case "$shot" in
        *"$text"*) return 0 ;;
      esac
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed $what"
}

wait_idle() {  # wait for the composer prompt with no dialog over it
  wait_screen '❯' 'the composer prompt'
  # A settled composer, not a dialog cursor: give a late dialog one more chance.
  sleep 1
  if dialog_open "$(screen)"; then
    wait_screen '❯' 'the composer prompt after the startup dialog'
  fi
}

# Type a slash command prefix without submitting and report whether the typeahead
# lists the mod's command; then clear the composer.
command_listed() {  # <command>
  local listed=0 i=0 shot
  send "/$1"
  while [ "$i" -lt 40 ]; do
    shot=$(screen)
    case "$shot" in
      *"Toggle Firstmate's Calm"*) listed=1; break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  tmux -L "$SOCKET" send-keys -t "$SESSION" C-u
  sleep 0.3
  return $((1 - listed))
}

# The cue row within a capture: a row carrying both a level glyph and the cue's rule.
cue_row_of() {  # <capture text>
  local line
  while IFS= read -r line; do
    case "$line" in
      *"$EFFORT_RULE"*)
        case "$line" in
          *○*|*◔*|*◑*|*◕*|*●*|*◉*|*◌*) printf '%s\n' "$line"; return 0 ;;
        esac
        ;;
    esac
  done <<CAPTURE
$1
CAPTURE
  return 1
}

hull_column() {  # <screen text>
  printf '%s\n' "$1" | awk -v hull="$HULL" 'index($0, hull) { print index($0, hull); exit }'
}

# The answer names words that live only in notes.txt, so the settled turn is told apart
# from the echoed prompt by "gamma" on screen with no working row left.
PROMPT='Run this exact bash command with the Bash tool: sleep 5; cat notes.txt   Then reply with one short sentence naming the three words.'

# The stock working row on this build: `✢ Propagating… (1s · ↓ 114 tokens)`.
working_row_shown() {  # <screen text>
  case "$1" in
    *'… ('*) return 0 ;;
  esac
  return 1
}

# Wait until the turn has settled: the answer is on screen and no working row or
# boat remains.
wait_settled() {  # <what> [iterations]
  local what=$1 limit=${2:-600} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
      *'gamma'*)
        if ! working_row_shown "$shot"; then
          case "$shot" in
            *"$HULL"*) ;;
            *) return 0 ;;
          esac
        fi
        ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never settled $what"
}

# Claude Code 2.1.280 logs `hooks module fm@<source> loaded`; 2.1.272 had no source suffix.
MODULE_LOADED='hooks module fm(@[^ ]+)? loaded'

# --- 1. Flag off: a complete no-op even with the preference on --------------------
launch "$DEBUG_LOG_OFF" 0
wait_idle
grep -q 'hooks modules not loaded' "$DEBUG_LOG_OFF" \
  || fail "Claude Code $CLAUDE_VERSION did not report hooks modules off with the flag unset"
if grep -Eq "$MODULE_LOADED" "$DEBUG_LOG_OFF"; then
  fail "Claude Code $CLAUDE_VERSION loaded the Calm hooks module although the flag was unset"
fi
if command_listed calm; then
  fail "Claude Code $CLAUDE_VERSION lists /calm although the flag is unset"
fi
if cue_row_of "$(screen)" >/dev/null; then
  printf '%s\n' "$(screen)" >&2
  fail "the effort cue drew above the prompt although the flag is unset"
fi
send "$PROMPT"
enter
# Sample every frame until the turn settles: the boat must never appear, and the
# stock working row must have been seen, or the flag-off case proved nothing.
saw_working=0
i=0
while [ "$i" -lt 600 ]; do
  off_frame=$(screen)
  case "$off_frame" in
    *"$HULL"*|*"$SAIL"*)
      printf '%s\n' "$off_frame" >&2
      fail "the working ship appeared although the flag is unset"
      ;;
    *'CLAUDE_EXIT='*)
      printf '%s\n' "$off_frame" >&2
      fail "Claude Code $CLAUDE_VERSION exited during the flag-off turn"
      ;;
  esac
  if working_row_shown "$off_frame"; then
    saw_working=1
  elif [ "$saw_working" -eq 1 ]; then
    case "$off_frame" in
      *'gamma'*) break ;;
    esac
  fi
  sleep 0.1
  i=$((i + 1))
done
[ "$saw_working" -eq 1 ] || fail "Claude Code $CLAUDE_VERSION showed no stock working row during the flag-off turn, so the no-op case cannot be judged"
wait_settled 'the turn with the flag off'
off_settled=$(screen)
case "$off_settled" in
  *'Bash('*|*'shell command'*) : ;;
  *)
    printf '%s\n' "$off_settled" >&2
    fail "the stock tool row did not draw with the flag unset"
    ;;
esac
send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION with the flag unset: no hooks module, no /calm, no effort cue, stock working row, stock tool rows, preference on ignored"

# --- 2. Flag on: the boat, the hidden rows, the toggle, the persisted choice -------
launch "$DEBUG_LOG_ON" 1
wait_idle
i=0
while [ "$i" -lt 100 ] && ! grep -Eq "$MODULE_LOADED" "$DEBUG_LOG_ON"; do
  sleep 0.1
  i=$((i + 1))
done
grep -Eq "$MODULE_LOADED" "$DEBUG_LOG_ON" \
  || fail "Claude Code $CLAUDE_VERSION did not load the Calm hooks module from the project's .claude/skills path with the flag on"
# The engine logs one benign notice for every options-less hooks module ("options
# requested but its manifest declares no userConfig"); anything else is a real problem.
if grep -E '\[(WARN|ERROR)\].*(plugin fm[:@ ]|\[fm\]|module fm@)' "$DEBUG_LOG_ON" | grep -v 'declares no userConfig' >&2; then
  fail "Claude Code $CLAUDE_VERSION loaded the Calm mod with a warning or error"
fi
command_listed calm || fail "Claude Code $CLAUDE_VERSION does not list /calm with the flag on"
send "$PROMPT"
enter
wait_screen "$HULL" 'the working ship during a real turn' 200
boat_one=$(screen)
case "$boat_one" in
  *"$SAIL"*) : ;;
  *)
    printf '%s\n' "$boat_one" >&2
    fail "the working ship lost its sail"
    ;;
esac
column_one=$(hull_column "$boat_one")
column_two=$column_one
i=0
while [ "$i" -lt 120 ]; do
  boat_two=$(screen)
  column_two=$(hull_column "$boat_two")
  if [ -n "$column_two" ] && [ "$column_two" != "$column_one" ]; then
    break
  fi
  sleep 0.1
  i=$((i + 1))
done
[ -n "$column_two" ] && [ "$column_two" != "$column_one" ] \
  || fail "the working ship never moved (hull stayed at column $column_one)"
wait_settled 'the turn with the flag on'
on_settled=$(screen)
case "$on_settled" in
  *"$HULL"*|*"$SAIL"*) fail "the working ship stayed on screen after the turn settled" ;;
  *'Bash('*|*'shell command'*|*'notes.txt)'*)
    printf '%s\n' "$on_settled" >&2
    fail "a tool row drew while Calm was on"
    ;;
esac

# Claude Code strips U+2063 from submitted prompts, so Firstmate types a plain doorbell
# naming a record that holds the envelope; that doorbell row draws at zero height while
# the answer stays visible. The answer token lives only in the record.
DOORBELL_TEXT='Firstmate operational input waiting'
operational=$(printf 'signal: %s/state/probe.status changed. Reply with exactly OPERATIONAL_PROCESSED and nothing else.' "$LAB" \
  | FM_HOME="$FM_HOME_DIR" "$OPERATIONAL_INPUT" record watcher) \
  || fail "could not publish the operational probe record"
case "$operational" in
  *"$DOORBELL_TEXT"*) : ;;
  *) fail "the operational probe is not a record-backed doorbell: $operational" ;;
esac
send "$operational"
sleep 1
enter
# A long line typed in one burst can leave Claude Code's first Enter inside its paste
# handling; like Firstmate's own submit primitive, retry Enter only, never retype.
i=0
while [ "$i" -lt 4 ]; do
  sleep 2
  case "$(screen)" in
    *"❯ : $DOORBELL_TEXT"*) enter ;;
    *) break ;;
  esac
  i=$((i + 1))
done
wait_screen 'OPERATIONAL_PROCESSED' 'the operational answer' 600
sleep 1
operational_screen=$(screen)
case "$operational_screen" in
  *"$DOORBELL_TEXT"*|*'invisible character'*)
    printf '%s\n' "$operational_screen" >&2
    fail "the operational doorbell row drew while Calm was on"
    ;;
esac

# /calm off: rows restore, the preference persists off, no Calm output row.
send '/calm'
enter
wait_screen 'shell command' 'the restored tool row after /calm off' 200
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "/calm did not persist off"
restored=$(screen)
case "$restored" in
  *"$DOORBELL_TEXT"*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off did not restore the operational user row"
    ;;
esac
# The toggle answers with a transient toast under the prompt, never a transcript row:
# the plugin's name must leave the screen once the toast expires.
case "$restored" in
  *'Calm off'*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off showed no Calm off notice"
    ;;
esac
i=0
while [ "$i" -lt 60 ]; do
  restored=$(screen)
  case "$restored" in
    *'fm: Calm'*|*'Calm off'*) ;;
    *) break ;;
  esac
  sleep 0.25
  i=$((i + 1))
done
case "$restored" in
  *'fm: Calm'*|*'Calm off'*)
    printf '%s\n' "$restored" >&2
    fail "/calm left a Calm row in the transcript after its notice should have expired"
    ;;
esac

# /calm on: rows hide again, the preference persists on.
send '/calm'
enter
i=0
while [ "$i" -lt 200 ]; do
  hidden_again=$(screen)
  case "$hidden_again" in
    *'Bash('*|*'shell command'*|*"$DOORBELL_TEXT"*) ;;
    *) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$hidden_again" in
  *'Bash('*|*'shell command'*|*"$DOORBELL_TEXT"*)
    printf '%s\n' "$hidden_again" >&2
    fail "/calm on did not hide the rows again"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "/calm did not persist on"
case "$hidden_again" in
  *'gamma'*|*'OPERATIONAL_PROCESSED'*) : ;;
  *) fail "Calm on hid a genuine assistant reply" ;;
esac
send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool rows and the record-backed operational doorbell draw at zero height, /calm restores and re-hides them while persisting the shared preference"

# --- 3. Resume: the restored transcript keeps the hidden rows hidden ---------------
launch "$DEBUG_LOG_RESUME" 1 --continue
wait_screen 'gamma' 'the resumed transcript' 400
sleep 1
resumed=$(screen)
case "$resumed" in
  *'Bash('*|*'shell command'*|*"$DOORBELL_TEXT"*)
    printf '%s\n' "$resumed" >&2
    fail "the resumed transcript drew a row Calm hides"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "resume changed the persisted choice"
send '/exit'
enter
sleep 1
pass "Claude Code $CLAUDE_VERSION resumes the transcript with Calm's hidden rows still hidden and the preference intact"

# --- 4. Supervision notes: shown with Calm off, from the store the host writes ----
STATE_DIR="$FM_HOME_DIR/state"
DEBUG_LOG_NOTES="$LAB/debug-notes.log"
mkdir -p "$STATE_DIR"
outcome() {
  FM_HOME="$FM_HOME_DIR" bash "$ROOT/bin/fm-branch-outcome.sh" "$@" >/dev/null \
    || fail "bin/fm-branch-outcome.sh $1 failed in the lab home"
}
outcome append --task fm-live-a --verdict captain --summary 'LIVE_PROCESSED_CAPTAIN acknowledged earlier'
outcome append --task fm-live-b --verdict captain --summary 'LIVE_REPLAY_CAPTAIN still open'
outcome mark-read --through 2
outcome mark-processed --through 1
printf 'key=live-key\nerrors=0\ncooldown=0\nretry_after=0\n' >"$STATE_DIR/.supervision-host-health"
printf 'off\n' >"$FM_HOME_DIR/config/calm"
launch "$DEBUG_LOG_NOTES" 1
wait_idle
wait_screen 'fm: ⚓ [seq 2] fm-live-b: LIVE_REPLAY_CAPTAIN still open' 'the session-start replay of an unprocessed captain outcome' 200
outcome append --task fm-live-c --verdict routine --summary 'LIVE_ROUTINE_NOTE worker healthy'
outcome append --task fm-live-d --verdict routine --summary 'LIVE_SILENT_NOTE no change' --silent true
outcome append --task fm-live-e --verdict captain --summary 'LIVE_NEW_CAPTAIN PR ready for review'
wait_screen 'fm: ⛵ fm-live-c: LIVE_ROUTINE_NOTE worker healthy' 'the routine sailboat note' 200
wait_screen 'fm: ⚓ [seq 5] fm-live-e: LIVE_NEW_CAPTAIN PR ready for review' 'the new captain anchor line' 200
printf 'key=live-key\nerrors=2\ncooldown=300\nretry_after=0\n' >"$STATE_DIR/.supervision-host-health"
wait_screen 'fm: ⛵ Supervision session paused after repeated engine errors' 'the latch-trip note' 200
notes_screen=$(screen)
case "$notes_screen" in
  *'LIVE_PROCESSED_CAPTAIN'*|*'LIVE_SILENT_NOTE'*)
    printf '%s\n' "$notes_screen" >&2
    fail "a processed captain outcome or a silent routine outcome drew a supervision note"
    ;;
  *'firstmate-calm:'*)
    printf '%s\n' "$notes_screen" >&2
    fail "a supervision note drew behind the old firstmate-calm label"
    ;;
esac
[ "$(cat "$STATE_DIR/.branch-outcomes-cursor")" = 2 ] || fail "the supervision notes moved the store's read cursor"
[ "$(cat "$STATE_DIR/.branch-outcomes-processed")" = 1 ] || fail "the supervision notes moved the processed marker"
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "the supervision notes changed the Calm preference"
# The notes never reach the model: a real turn asked to quote them quotes none. The
# answer token is spelled out rather than typed, so the echoed prompt cannot match it.
send 'Quote verbatim every line of this conversation that contains a sailboat emoji or an anchor emoji, other than this request. If there are none, reply with only the words green, harbor, and lantern in uppercase joined by underscores.'
enter
wait_screen 'GREEN_HARBOR_LANTERN' 'the model reporting that it sees no supervision note' 400
sleep 2
send '/exit'
enter
sleep 2
notes_session=$(grep -rlF 'GREEN_HARBOR_LANTERN' "$HOME/.claude/projects/"*"$(basename "$LAB" | tr -c 'A-Za-z0-9\n' -)"* 2>/dev/null | head -n 1)
[ -n "$notes_session" ] || fail "could not find the session transcript Claude Code stored for the notes turn"
if jq -e 'select(.type == "assistant") | .message.content | tostring | test("LIVE_")' "$notes_session" >/dev/null 2>&1; then
  fail "the model quoted a supervision note, so the notes reached its context: $notes_session"
fi
# Claude Code 2.1.283 keeps each note in the session as a display-only entry and
# restores it on resume, so the resumed session replays only what it has not shown.
outcome append --task fm-live-f --verdict captain --summary 'LIVE_WHILE_CLOSED captain outcome'
launch "$DEBUG_LOG_NOTES" 1 --continue
wait_screen 'fm: ⚓ [seq 6] fm-live-f: LIVE_WHILE_CLOSED captain outcome' 'the replay of an outcome recorded while the session was closed' 400
sleep 4
resumed_notes=$(screen)
[ "$(printf '%s\n' "$resumed_notes" | grep -c 'LIVE_REPLAY_CAPTAIN')" = 1 ] || {
  printf '%s\n' "$resumed_notes" >&2
  fail "the resumed session did not show the earlier anchor exactly once"
}
send '/exit'
enter
sleep 1
pass "Claude Code $CLAUDE_VERSION with Calm off shows the supervision notes: the session-start anchor for an unprocessed captain outcome, a sailboat for a new routine outcome, an anchor for a new captain outcome, and the latch-trip note, each behind the fm: label, skipping processed and silent outcomes, moving no store marker, never reaching the model, and on resume showing each anchor once"

# --- 5. The effort cue: what proves a level, its color, its cycle, and the key path --
# Claude Code persists the level `/effort` selects as the operator's default for new
# sessions, and an isolated CLAUDE_CONFIG_DIR would demand a fresh login, so this section
# reads the level it starts at out of the footer badge before anything can move it and
# puts it back from the exit trap, on the failing path as well as the passing one. The cue
# names a level only once a request of the main loop has proved one, so this section
# submits two turns; the command and the band's keyboard path work at an idle prompt.
# The cue does not depend on Calm; section 4 left it off, so this section runs with it on.
printf 'on\n' >"$FM_HOME_DIR/config/calm"
MODEL=$EFFORT_MODEL
launch "$DEBUG_LOG_EFFORT" 1
wait_idle

# The badge the captain reads, as the footer spells it.
badge_level() {  # <screen text>
  printf '%s\n' "$1" | sed -n 's/.*think:\([a-z]*\).*/\1/p' | head -1
}

# The footer abbreviates medium; every other level reads there as itself.
badge_for() {  # <level>
  case "$1" in
    medium) printf 'med' ;;
    *) printf '%s' "$1" ;;
  esac
}

# The level a badge word names, which is what `/effort` accepts: `med` is not a level.
level_for() {  # <badge word>
  case "$1" in
    med) printf 'medium' ;;
    *) printf '%s' "$1" ;;
  esac
}

# The cue row, with its escapes, so the color the surface actually paints is readable.
cue_row() {
  cue_row_of "$(tmux -L "$SOCKET" capture-pane -p -e -t "$SESSION" 2>/dev/null || true)"
}

# The 256-color code the cue's rule is painted in, or empty when it carries none.
cue_color() {
  cue_row | sed -n 's/.*\[38;5;\([0-9]*\)m[^[]*'"$EFFORT_RULE"'.*/\1/p' | head -1
}

wait_badge() {  # <badge word> <what>
  local want=$1 what=$2 i=0
  while [ "$i" -lt 200 ]; do
    effort_confirmation_open "$(screen)" && enter
    [ "$(badge_level "$(screen)")" = "$want" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed think:$want after $what"
}

# The label the cue draws for a level: its glyph and its word together, so `high` cannot
# match the `xhigh` row and hide the very mismatch these checks exist to catch.
cue_label_for() {  # <level>
  case "$1" in
    low) printf '○ low' ;;
    medium) printf '◔ medium' ;;
    high) printf '◑ high' ;;
    xhigh) printf '◕ xhigh' ;;
    max) printf '● max' ;;
    ultracode) printf '◉ ultracode' ;;
    *) printf '%s' "$1" ;;
  esac
}

# The cue names the level the footer names, or claims none; never another level.
cue_agrees_with_badge() {  # <what>
  local shown level
  shown=$(cue_row)
  level=$(level_for "$(badge_level "$(screen)")")
  case "$shown" in
    *"$(cue_label_for "$level")"*|*◌*) return 0 ;;
  esac
  printf '%s\n' "$shown" >&2
  fail "the effort cue names a level the footer does not show ($level) $1"
}

started_at=$(level_for "$(badge_level "$(screen)")")
[ -n "$started_at" ] || fail "Claude Code $CLAUDE_VERSION shows no think: badge on $EFFORT_MODEL, so the effort cue cannot be judged"
# From here on every exit path restores this level, because the next steps move it.
EFFORT_STARTED_AT=$started_at

# The cue draws above the prompt and is painted, and it never names the wrong level.
cue_first=$(cue_row)
[ -n "$cue_first" ] || fail "the effort cue drew no rule above the prompt"
cue_agrees_with_badge 'at the idle prompt'
[ -n "$(cue_color)" ] || fail "the effort cue's rule carries no color, so the level is not shown as one"

# One request of the main loop is what proves a level, and the cue then names that level.
send "$PROMPT"
enter
wait_settled 'the turn that proves the starting level'
proven=$(level_for "$(badge_level "$(screen)")")
case "$(cue_row)" in
  *"$(cue_label_for "$proven")"*) : ;;
  *)
    printf '%s\n' "$(cue_row)" >&2
    fail "the effort cue does not name $proven after a request carried it"
    ;;
esac
color_proven=$(cue_color)
[ -n "$color_proven" ] || fail "the effort cue lost its color at $proven"

# One cycle step moves Claude Code's own setting; running the command is not proof it
# took, so the cue claims no level until the next request carries the new one.
send '/effort-cycle'
enter
sleep 2
turned_down='this build asked no confirmation, so no change was turned down'
# Where Claude Code confirms the change, turning it down keeps the level, and the next step
# after a request has proved that offers the same level again rather than passing it over as
# one the model declined.
if effort_confirmation_open "$(screen)"; then
  asked=$(screen | sed -n 's/.*Yes, switch to \([a-z]*\).*/\1/p' | head -1)
  [ -n "$asked" ] || fail "Claude Code $CLAUDE_VERSION confirmed an effort change without naming the level"
  tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
  wait_screen 'Kept effort level' 'Claude Code keeping the level after the change was turned down' 80
  [ "$(level_for "$(badge_level "$(screen)")")" = "$proven" ] \
    || fail "turning the change to $asked down left the footer off $proven"
  send "$PROMPT"
  enter
  # The earlier answer is still on screen, so the wait starts once this turn is under way;
  # the prompt's own five-second command keeps it running past this pause.
  sleep 3
  wait_settled 'the turn after a change was turned down'
  send '/effort-cycle'
  enter
  wait_screen "$EFFORT_CONFIRM" 'the confirmation for the step after the turned-down one' 80
  offered=$(screen | sed -n 's/.*Yes, switch to \([a-z]*\).*/\1/p' | head -1)
  [ "$offered" = "$asked" ] \
    || fail "after $asked was turned down the cycle offered ${offered:-nothing}, passing $asked over as declined"
  enter
  sleep 2
  turned_down="offers $asked again after its change was turned down at Claude Code's confirmation"
fi
moved=$(level_for "$(badge_level "$(screen)")")
[ -n "$moved" ] || fail "the footer lost its think: badge after /effort-cycle"
[ "$moved" != "$proven" ] || fail "/effort-cycle left the level at $proven"
case "$(cue_row)" in
  *◌*) : ;;
  *)
    printf '%s\n' "$(cue_row)" >&2
    fail "the effort cue named a level although no request has carried it yet"
    ;;
esac

# The next request proves the stepped level, and it paints in a color of its own.
send "$PROMPT"
enter
sleep 3
wait_settled 'the turn after one cycle step'
case "$(cue_row)" in
  *"$(cue_label_for "$moved")"*) : ;;
  *)
    printf '%s\n' "$(cue_row)" >&2
    fail "the effort cue does not name $moved after a request carried it"
    ;;
esac
color_moved=$(cue_color)
[ -n "$color_moved" ] || fail "the effort cue lost its color at $moved"
[ "$color_moved" != "$color_proven" ] \
  || fail "$proven and $moved paint the cue the same 256-color code ($color_moved), so the color says nothing"

# `auto` names no level of its own, so the cue claims none from there.
send '/effort auto'
enter
settle_effort_change
sleep 2
case "$(cue_row)" in
  *◌*) : ;;
  *)
    printf '%s\n' "$(cue_row)" >&2
    fail "the effort cue still names a level after /effort auto left the choice to Claude Code"
    ;;
esac

# A level the captain selects himself moves the setting the same way.
send '/effort low'
enter
wait_badge low 'the captain typed /effort low'
cue_agrees_with_badge 'after the captain typed /effort low'

# The key path that needs no keybindings file: focus the band, then press. The focus chord
# is answered by the surface rather than by a hook, so it is given a settled prompt and one
# retry before the case is called a regression; the level it lands on is still exact.
pressed=0
attempt=0
while [ "$attempt" -lt 2 ]; do
  tmux -L "$SOCKET" send-keys -t "$SESSION" C-x Tab
  sleep 2
  enter
  i=0
  while [ "$i" -lt 60 ]; do
    effort_confirmation_open "$(screen)" && enter
    reached=$(badge_level "$(screen)")
    [ -n "$reached" ] && [ "$reached" != low ] && { pressed=1; break; }
    sleep 0.25
    i=$((i + 1))
  done
  [ "$pressed" -eq 1 ] && break
  tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
  sleep 1
  attempt=$((attempt + 1))
done
[ "$pressed" -eq 1 ] || fail "Claude Code $CLAUDE_VERSION never moved the level from the band's own focus-and-press keys"
[ "$reached" = "$(badge_for medium)" ] || fail "the band's press moved the level to $reached, not one step up from low"
tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
sleep 1

# A press must never leave the engine reporting a skipped hook of this mod, named by its
# plugin name `fm` or its folder.
if grep -E 'hook skipped|threw' "$DEBUG_LOG_EFFORT" | grep -E 'plugin fm[:@ ]|\[fm\]|module fm@|fm@|firstmate-calm' >&2; then
  fail "Claude Code $CLAUDE_VERSION skipped a Calm mod hook while the effort cue was driven"
fi

# Put the operator's persisted default back exactly where this section found it, through
# the same restore the exit trap would have run, and prove it landed.
restore_effort_level || fail "Claude Code $CLAUDE_VERSION did not restore the starting level $started_at"
send '/exit'
enter
sleep 1
MODEL=haiku
pass "Claude Code $CLAUDE_VERSION names a level in the effort cue only once a request has carried it, paints each level in a distinct theme color, cycles the setting with /effort-cycle and with the band's own focus-and-press keys, $turned_down, follows the captain's own /effort, and leaves the starting level restored"
