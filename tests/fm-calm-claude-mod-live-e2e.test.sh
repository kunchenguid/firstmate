#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code Calm mod
# (.claude/mods/firstmate-calm) in a real Claude Code TUI under tmux, mirroring the
# Pi interactive case in tests/fm-calm-pi-extension.test.sh. It proves, against the
# installed Claude Code and the shipped project auto-load path (.claude/skills):
#   1. With CLAUDE_CODE_ENABLE_FUNCTION_HOOKS unset, the mod is a complete no-op even
#      with the per-home preference already on, whether or not Claude Code loaded the
#      module through its own rollout flag: /calm is not a command, no effort cue draws,
#      the stock working row shows, and tool rows draw as stock.
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
#   5. The effort cue, in two parts, neither of which writes the captain's settings.
#      In a throwaway CLAUDE_CONFIG_DIR with no login, so every level a step saves lands
#      in the lab: the cue draws above the prompt and names no level before a request, and
#      ctrl+tab bound to command:effort-cycle, /effort-cycle, the captain's own /effort,
#      and the band's own focus-and-press keys each move Claude Code's real level.
#      With the login, on a model the captain already has a saved level for and started
#      with --effort so nothing is saved: a request proves a level and the cue names it,
#      each proven level paints a color of its own, and the step after a reply asks only
#      for max, which Claude Code never saves. The section fails if the captain's
#      settings.json or keybindings.json changed while it ran, and prints the login part
#      as NOT RUN where that model has no saved level.
# The project and FM_HOME are isolated; outside the throwaway part of section 5 Claude
# keeps using its existing managed authentication and one trusted temporary folder. A few
# Haiku turns are submitted, and up to four turns on claude-sonnet-5 for the effort cue,
# because Haiku has no effort parameter. Every launch sets DISABLE_AUTOUPDATER=1: a
# configuration directory without the captain's own autoUpdates preference would otherwise
# let Claude Code upgrade the shared install in the background.
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
DEBUG_LOG_EFFORT_LOW="$LAB/debug-effort-low.log"
DEBUG_LOG_EFFORT_XHIGH="$LAB/debug-effort-xhigh.log"
EFFORT_CONFIG="$LAB/claude-config"
SOCKET="fm-calm-claude-$$"
SESSION="fm-calm-claude-e2e"
# Haiku has no effort parameter, so the effort section launches on models that do. The
# throwaway part takes the `sonnet` alias, because nothing it saves is the captain's. The
# login part names an explicit id: the alias moves between releases (2.1.289 resolves it to
# claude-sonnet-5-5), and that part runs only on a model the captain already has a saved
# level for.
MODEL=haiku
EFFORT_MODEL=sonnet
EFFORT_LOGIN_MODEL=claude-sonnet-5
HULL='╲▁▁▁╱'
SAIL='◿│◣'
# The cue's rule, the run of box-drawing dashes it fills its row with. The composer draws
# full-width rules of its own, so a row counts as the cue only when it also carries one of
# the level glyphs the cue leads with.
EFFORT_RULE='────────'

# Claude Code 2.1.280 asks to confirm the first change of effort after a reply while the
# conversation's prompt cache is warm; its cursor starts on the option that switches.
EFFORT_CONFIRM='Change effort level?'

effort_confirmation_open() {  # <screen text>
  case "$1" in
    *"$EFFORT_CONFIRM"*) return 0 ;;
  esac
  return 1
}

# The captain's settings.json and keybindings.json as the effort section found them. That
# section must write neither, so it compares them when it ends, and the exit trap compares
# them too when a case fails in between. The launches drop any inherited CLAUDE_CONFIG_DIR,
# so the logged-in sessions read both from the home directory.
CAPTAIN_CONFIG="$HOME/.claude"
EFFORT_SECTION_OPEN=0
settings_before=''
keybindings_before=''

config_digest() {  # <file>
  if [ ! -e "$1" ]; then
    printf 'absent'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

captain_config_unchanged() {
  local name before after changed=0
  for name in settings keybindings; do
    case "$name" in
      settings) before=$settings_before ;;
      *) before=$keybindings_before ;;
    esac
    after=$(config_digest "$CAPTAIN_CONFIG/$name.json")
    if [ "$after" != "$before" ]; then
      printf 'warning: %s changed while the effort section ran: sha256 %s before, %s after\n' \
        "$CAPTAIN_CONFIG/$name.json" "$before" "$after" >&2
      changed=1
    fi
  done
  return "$changed"
}

cleanup() {
  local i=0
  [ "$EFFORT_SECTION_OPEN" -eq 1 ] && { captain_config_unchanged || true; }
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

# What the next launches add to their environment, and how tall their pane is. The
# throwaway part of the effort section sets both: a configuration directory of the lab's
# own, and room for every `/effort` row it raises under Claude Code's header.
LAUNCH_ENV=''
LAUNCH_ROWS=44

launch() {  # <debug-log> <flag: 1|0> [claude args...]
  local log=$1 flag=$2 flag_env=''
  shift 2
  [ "$flag" = 1 ] && flag_env="CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1"
  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y "$LAUNCH_ROWS" -c "$PROJECT" \
    "env $(unset_inherited) $flag_env $LAUNCH_ENV DISABLE_AUTOUPDATER=1 FM_HOME='$FM_HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model $MODEL --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --debug-file '$log' $*; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
  # Without extended keys tmux hands ctrl+tab to the session as a plain tab, so the server
  # is told to report them before Claude Code asks for them; a tmux too old for the format
  # option keeps its own.
  tmux -L "$SOCKET" set-option -s extended-keys on 2>/dev/null || true
  tmux -L "$SOCKET" set-option -s extended-keys-format csi-u 2>/dev/null || true
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
# Whether Claude Code loads the module with the flag unset is the engine's own choice: its
# rollout flag loads it on some builds and accounts (2.1.289 did here) and not on others
# (2.1.280 did not). The mod's contract is the same either way, so this section judges only
# what the captain can see and records which case the engine took.
launch "$DEBUG_LOG_OFF" 0
wait_idle
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
if grep -Eq "$MODULE_LOADED" "$DEBUG_LOG_OFF"; then
  flag_off_engine='the engine loaded the hooks module through its own rollout flag and the mod stayed inert'
else
  flag_off_engine='the engine loaded no hooks module'
fi
pass "Claude Code $CLAUDE_VERSION with the flag unset ($flag_off_engine): no /calm, no effort cue, stock working row, stock tool rows, preference on ignored"

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

# --- 5. The effort cue: its cycle and key paths, what proves a level, and its colors --
# `/effort` saves the level it selects as the operator's default for new sessions, and no
# lab directory isolates that file in a logged-in session. So the steps that save run in a
# throwaway CLAUDE_CONFIG_DIR, which has no login and therefore no request to prove a level,
# and the checks that need a request run with the login in sessions started with `--effort`,
# whose only step asks for `max`, the one level Claude Code keeps for the session alone.
# The cue does not depend on Calm; section 4 left it off, so this section runs with it on.
printf 'on\n' >"$FM_HOME_DIR/config/calm"

# The captain's own configuration, which nothing below may write.
settings_before=$(config_digest "$CAPTAIN_CONFIG/settings.json")
keybindings_before=$(config_digest "$CAPTAIN_CONFIG/keybindings.json")
EFFORT_SECTION_OPEN=1

# The cue row, with its escapes, so the color the surface actually paints is readable.
cue_row() {
  cue_row_of "$(tmux -L "$SOCKET" capture-pane -p -e -t "$SESSION" 2>/dev/null || true)"
}

# The 256-color code the cue's rule is painted in, or empty when it carries none.
cue_color() {
  cue_row | sed -n 's/.*\[38;5;\([0-9]*\)m[^[]*'"$EFFORT_RULE"'.*/\1/p' | head -1
}

# The band draws once the module has loaded, a moment after the prompt does.
wait_cue() {  # <what>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ -n "$(cue_row)" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "the effort cue drew no rule above the prompt $1"
}

# The cue claims no level: nothing has proved one since the last thing that could move it.
cue_unproven() {  # <what>
  local shown
  shown=$(cue_row)
  case "$shown" in
    *◌*) return 0 ;;
  esac
  printf '%s\n' "$shown" >&2
  fail "the effort cue does not draw its unestablished row $1, where no request has carried a level"
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

# The level Claude Code's own header names once the session holds an explicit one:
# `Sonnet 5.5 with xhigh effort`. No row `/effort` prints reads that way.
header_level() {  # <screen text>
  printf '%s\n' "$1" | sed -n 's/.* with \([a-z]*\) effort.*/\1/p' | head -1
}

# Wait until Claude Code itself reports the session at <level>: the row `/effort` prints
# names it and the header has moved to it.
wait_level() {  # <level> <what>
  local want=$1 what=$2 i=0 shot
  while [ "$i" -lt 150 ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited after $what"
        ;;
      *"Set effort level to $want"*)
        [ "$(header_level "$shot")" = "$want" ] && return 0
        ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never reported the level at $want after $what"
}

# --- 5a. Throwaway configuration, no login: the cycle and every key path -----------
# The saved default makes the first step deterministic, the accepted bypass notice keeps
# this fresh configuration from opening that dialog over the prompt, and the binding is the
# one line docs/effort-cue.md asks a captain to add for a single keystroke.
mkdir -p "$EFFORT_CONFIG"
printf '%s\n' '{"hasCompletedOnboarding":true,"theme":"dark","installMethod":"global"}' >"$EFFORT_CONFIG/.claude.json"
printf '%s\n' '{"effortLevel":"high","skipDangerousModePermissionPrompt":true}' >"$EFFORT_CONFIG/settings.json"
printf '%s\n' '{"bindings":[{"context":"Chat","bindings":{"ctrl+tab":"command:effort-cycle"}}]}' >"$EFFORT_CONFIG/keybindings.json"
MODEL=$EFFORT_MODEL
LAUNCH_ENV="CLAUDE_CONFIG_DIR='$EFFORT_CONFIG'"
LAUNCH_ROWS=60
launch "$DEBUG_LOG_EFFORT" 1
wait_idle

# The cue draws above the prompt, painted, and names no level before any request.
wait_cue 'in the throwaway configuration'
cue_unproven 'at the idle prompt'
[ -n "$(cue_color)" ] || fail "the effort cue's rule carries no color before a request, so the unestablished state is not shown as one"

# ctrl+tab, bound to command:effort-cycle, steps up from the saved level and wraps at the top.
ctrl_tab() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" C-Tab
}
ctrl_tab
wait_level xhigh 'ctrl+tab stepped up from the saved level high'
cue_unproven 'after ctrl+tab asked for xhigh'
ctrl_tab
wait_level max 'a second ctrl+tab stepped up from xhigh'
cue_unproven 'after ctrl+tab asked for max'
ctrl_tab
wait_level low 'a third ctrl+tab wrapped from max'
cue_unproven 'after ctrl+tab asked for low'

# The command the chord runs steps the same way when typed.
send '/effort-cycle'
enter
wait_level medium '/effort-cycle stepped up from low'
cue_unproven 'after /effort-cycle asked for medium'

# A level the captain selects himself is the level the next step climbs from.
send '/effort max'
enter
wait_level max 'the captain typed /effort max'
cue_unproven 'after the captain typed /effort max'

# The key path that needs no keybindings file: focus the band, then press. The focus chord
# is answered by the surface rather than by a hook, so it is given a settled prompt and one
# retry before the case is called a regression; the level it lands on is still exact.
pressed=0
attempt=0
reached=''
while [ "$attempt" -lt 2 ]; do
  tmux -L "$SOCKET" send-keys -t "$SESSION" C-x Tab
  sleep 2
  enter
  i=0
  while [ "$i" -lt 60 ]; do
    reached=$(header_level "$(screen)")
    [ -n "$reached" ] && [ "$reached" != max ] && { pressed=1; break; }
    sleep 0.25
    i=$((i + 1))
  done
  [ "$pressed" -eq 1 ] && break
  tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
  sleep 1
  attempt=$((attempt + 1))
done
[ "$pressed" -eq 1 ] || fail "Claude Code $CLAUDE_VERSION never moved the level from the band's own focus-and-press keys"
[ "$reached" = low ] || fail "the band's press moved the level to $reached, not from the captain's max around to low"
tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
sleep 1
cue_unproven "after the band's press asked for low"

# The steps moved Claude Code's real setting: its settings file, here the lab's, holds the
# last level it saves, which `max` never is.
saved_in_lab=$(jq -r '[.modelSettings[]?.effortLevel] | join(",")' "$EFFORT_CONFIG/settings.json" 2>/dev/null || true)
[ "$saved_in_lab" = low ] \
  || fail "the steps left the throwaway configuration's saved level at '${saved_in_lab:-nothing}', not low, so they did not move Claude Code's own setting"
send '/exit'
enter
sleep 2
LAUNCH_ENV=''
LAUNCH_ROWS=44

# --- 5b. With the login: what proves a level, and a color per proven level ---------
# These need a request, so they need the login. They run only on a model the captain
# already has a saved level for, in sessions started with `--effort`, which saves nothing.

# The footer badge of the captain's own status line, where he has one.
badge_level() {  # <screen text>
  printf '%s\n' "$1" | sed -n 's/.*think:\([a-z]*\).*/\1/p' | head -1
}

# The level a badge word names: the footer abbreviates medium.
level_for() {  # <badge word>
  case "$1" in
    med) printf 'medium' ;;
    *) printf '%s' "$1" ;;
  esac
}

# The cue names the level the footer names, or claims none; never another level. A footer
# with no badge has nothing to disagree with.
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

# Submit the prompt and wait the turn out. An earlier answer may still be on screen, so
# the wait for the settled turn starts only once this turn's working ship is up; the
# prompt's own five-second command keeps the ship there long enough to be seen.
effort_turn() {  # <what>
  send "$PROMPT"
  enter
  wait_screen "$HULL" "the working ship of $1" 200
  wait_settled "$1"
}

# The cue names <level>, and no other, once a request has carried it.
cue_names() {  # <level> <what>
  local shown
  shown=$(cue_row)
  case "$shown" in
    *"$(cue_label_for "$1")"*) : ;;
    *)
      printf '%s\n' "$shown" >&2
      fail "the effort cue does not name $1 $2"
      ;;
  esac
  cue_agrees_with_badge "$2"
}

# Start a session at <level> and prove it: no level before a request, that level after one.
prove_level() {  # <debug-log> <level>
  launch "$1" 1 --effort "$2"
  wait_idle
  wait_cue "in the session started with --effort $2"
  cue_unproven "before the session started with --effort $2 sent a request"
  effort_turn "the turn that proves $2"
  cue_names "$2" "after a request carried it"
}

if jq -e --arg model "$EFFORT_LOGIN_MODEL" '.modelSettings[$model].effortLevel | type == "string"' \
  "$CAPTAIN_CONFIG/settings.json" >/dev/null 2>&1; then
  MODEL=$EFFORT_LOGIN_MODEL
  prove_level "$DEBUG_LOG_EFFORT_LOW" low
  color_low=$(cue_color)
  [ -n "$color_low" ] || fail "the effort cue lost its color at low"
  send '/exit'
  enter
  sleep 2

  prove_level "$DEBUG_LOG_EFFORT_XHIGH" xhigh
  color_xhigh=$(cue_color)
  [ -n "$color_xhigh" ] || fail "the effort cue lost its color at xhigh"
  [ "$color_xhigh" != "$color_low" ] \
    || fail "low and xhigh paint the cue the same 256-color code ($color_xhigh), so the color says nothing"

  # One step after a reply. From a proved xhigh it asks for max, which Claude Code applies
  # to this session only, so the step saves nothing whichever way it goes. Running the
  # command is not proof it took, so the cue claims no level until a request carries max.
  send '/effort-cycle'
  enter
  sleep 2
  turned_down='this build asked no confirmation, so no change was turned down'
  # Where Claude Code confirms the change, turning it down keeps the level, and the next
  # step after a request has proved that offers the same level again: the cycle never
  # passes a level over, because nothing it can see tells a turned-down change from a level
  # the model refused.
  if effort_confirmation_open "$(screen)"; then
    asked=$(screen | sed -n 's/.*Yes, switch to \([a-z]*\).*/\1/p' | head -1)
    [ "$asked" = max ] \
      || fail "after a request proved xhigh the cycle asked Claude Code for ${asked:-no level}, not max"
    tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
    wait_screen 'Kept effort level' 'Claude Code keeping the level after the change was turned down' 80
    effort_turn 'the turn after a change was turned down'
    cue_names xhigh 'after the change to max was turned down and a request carried xhigh again'
    send '/effort-cycle'
    enter
    wait_screen "$EFFORT_CONFIRM" 'the confirmation for the step after the turned-down one' 80
    offered=$(screen | sed -n 's/.*Yes, switch to \([a-z]*\).*/\1/p' | head -1)
    [ "$offered" = max ] \
      || fail "after max was turned down the cycle offered ${offered:-nothing}, passing max over as declined"
    enter
    turned_down="offers max again after its change was turned down at Claude Code's confirmation"
  fi
  wait_screen 'Set effort level to max' 'Claude Code setting max after the step from xhigh' 120
  cue_unproven 'after the step asked for max'
  effort_turn 'the turn after the step to max'
  cue_names max 'after a request carried it'
  color_max=$(cue_color)
  [ -n "$color_max" ] || fail "the effort cue lost its color at max"
  if [ "$color_max" = "$color_xhigh" ] || [ "$color_max" = "$color_low" ]; then
    fail "max paints the cue a 256-color code ($color_max) another proven level already has, so the color says nothing"
  fi
  send '/exit'
  enter
  sleep 2
  login_part="with the login on $EFFORT_LOGIN_MODEL, started with --effort so nothing is saved: a request proves low and xhigh and the cue names each in a color of its own, the step after a reply asks for max, which the cue names in a third color only once a request has carried it, and $turned_down; NOT RUN on this engine: the cue under /effort auto after a proven level, because that command would rewrite the captain's saved level"
else
  login_part="NOT RUN on this engine: a request proving a level, a color per proven level, the step after a reply, and the cue under /effort auto, because the captain's settings hold no saved level for $EFFORT_LOGIN_MODEL and those checks run only on a model that has one"
fi
MODEL=haiku

# A press must never leave the engine reporting a skipped hook of this mod, named by its
# plugin name `fm` or its folder.
for effort_log in "$DEBUG_LOG_EFFORT" "$DEBUG_LOG_EFFORT_LOW" "$DEBUG_LOG_EFFORT_XHIGH"; do
  [ -e "$effort_log" ] || continue
  if grep -E 'hook skipped|threw' "$effort_log" | grep -E 'plugin fm[:@ ]|\[fm\]|module fm@|fm@|firstmate-calm' >&2; then
    fail "Claude Code $CLAUDE_VERSION skipped a Calm mod hook while the effort cue was driven"
  fi
done

EFFORT_SECTION_OPEN=0
captain_config_unchanged \
  || fail "the captain's Claude Code configuration changed while the effort section ran, which must write none of it"
pass "Claude Code $CLAUDE_VERSION effort cue, in a throwaway configuration with no login: the cue draws above the prompt and names no level before a request, ctrl+tab bound to command:effort-cycle steps the real level from the saved high to xhigh, max, and around to low, /effort-cycle steps it to medium, the band's own focus-and-press keys step from the captain's own /effort max around to low, the cue claims no level after any of them, and no hook of the mod is skipped; $login_part; the captain's settings.json (sha256 $settings_before) and keybindings.json (sha256 $keybindings_before) are unchanged"
