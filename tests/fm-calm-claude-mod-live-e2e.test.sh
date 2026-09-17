#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code Calm mod
# (.claude/mods/firstmate-calm) in a real Claude Code TUI under tmux, mirroring the
# Pi interactive case in tests/fm-calm-pi-extension.test.sh. It proves, against the
# installed Claude Code and the shipped project auto-load path (.claude/skills):
#   1. With CLAUDE_CODE_ENABLE_FUNCTION_HOOKS unset, the mod is a complete no-op even
#      with the per-home preference already on: no hooks module loads, /calm is not a
#      command, the stock working row shows, and tool rows draw as stock.
#   2. With the flag on, the sailboat replaces the working row and moves, tool rows and
#      an exact operational user row draw at zero height, /calm restores them and
#      persists off, /calm hides them again and persists on, all without a Calm output
#      row in the transcript.
#   3. `claude --continue` restores the transcript with those rows still hidden.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication and one trusted temporary folder. A few Haiku turns are submitted.
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
SOCKET="fm-calm-claude-$$"
SESSION="fm-calm-claude-e2e"
HULL='╲▁▁▁╱'
SAIL='◿│◣'

cleanup() {
  local i=0
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
    "env $(unset_inherited) $flag_env FM_HOME='$FM_HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --debug-file '$log' $*; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
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

# --- 1. Flag off: a complete no-op even with the preference on --------------------
launch "$DEBUG_LOG_OFF" 0
wait_idle
grep -q 'hooks modules not loaded' "$DEBUG_LOG_OFF" \
  || fail "Claude Code $CLAUDE_VERSION did not report hooks modules off with the flag unset"
if grep -q 'hooks module firstmate-calm loaded' "$DEBUG_LOG_OFF"; then
  fail "Claude Code $CLAUDE_VERSION loaded the Calm hooks module although the flag was unset"
fi
if command_listed calm; then
  fail "Claude Code $CLAUDE_VERSION lists /calm although the flag is unset"
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
pass "Claude Code $CLAUDE_VERSION with the flag unset: no hooks module, no /calm, stock working row, stock tool rows, preference on ignored"

# --- 2. Flag on: the boat, the hidden rows, the toggle, the persisted choice -------
launch "$DEBUG_LOG_ON" 1
wait_idle
i=0
while [ "$i" -lt 100 ] && ! grep -q 'hooks module firstmate-calm loaded' "$DEBUG_LOG_ON"; do
  sleep 0.1
  i=$((i + 1))
done
grep -q 'hooks module firstmate-calm loaded' "$DEBUG_LOG_ON" \
  || fail "Claude Code $CLAUDE_VERSION did not load the Calm hooks module from the project's .claude/skills path with the flag on"
# The engine logs one benign notice for every options-less hooks module ("options
# requested but its manifest declares no userConfig"); anything else is a real problem.
if grep -E '\[(WARN|ERROR)\].*firstmate-calm' "$DEBUG_LOG_ON" | grep -v 'declares no userConfig' >&2; then
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

# An exact operational user row draws at zero height while the answer stays visible.
operational=$(printf 'signal: %s/state/probe.status changed. Reply with exactly OPERATIONAL_PROCESSED and nothing else.' "$LAB" | "$OPERATIONAL_INPUT" encode watcher) \
  || fail "could not encode the operational probe"
send "$operational"
enter
wait_screen 'OPERATIONAL_PROCESSED' 'the operational answer' 600
sleep 1
operational_screen=$(screen)
case "$operational_screen" in
  *'probe.status changed'*)
    printf '%s\n' "$operational_screen" >&2
    fail "the operational user row drew while Calm was on"
    ;;
esac

# /calm off: rows restore, the preference persists off, no Calm output row.
send '/calm'
enter
wait_screen 'shell command' 'the restored tool row after /calm off' 200
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "/calm did not persist off"
restored=$(screen)
case "$restored" in
  *'probe.status changed'*) : ;;
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
    *'firstmate-calm'*|*'Calm off'*) ;;
    *) break ;;
  esac
  sleep 0.25
  i=$((i + 1))
done
case "$restored" in
  *'firstmate-calm'*|*'Calm off'*)
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
    *'Bash('*|*'probe.status changed'*) ;;
    *) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$hidden_again" in
  *'Bash('*|*'probe.status changed'*)
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
pass "Claude Code $CLAUDE_VERSION with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool and operational rows draw at zero height, /calm restores and re-hides them while persisting the shared preference"

# --- 3. Resume: the restored transcript keeps the hidden rows hidden ---------------
launch "$DEBUG_LOG_RESUME" 1 --continue
wait_screen 'gamma' 'the resumed transcript' 400
sleep 1
resumed=$(screen)
case "$resumed" in
  *'Bash('*|*'probe.status changed'*)
    printf '%s\n' "$resumed" >&2
    fail "the resumed transcript drew a row Calm hides"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "resume changed the persisted choice"
send '/exit'
enter
sleep 1
pass "Claude Code $CLAUDE_VERSION resumes the transcript with Calm's hidden rows still hidden and the preference intact"
