#!/usr/bin/env bash
# Opt-in credentialed live guard for the two Claude permission-prompt signals,
# against the installed Claude Code in a real TUI under an isolated tmux server:
#   1. the rendered dialog a PreToolUse hook's "ask" opens matches
#      fm_composer_permission_prompt (bin/fm-composer-lib.sh), names the prompted
#      command's first line, and is a blocking dialog, which is what the watcher's
#      permission-prompt wake and the delivery guards read;
#   2. the tracked PermissionRequest registration (bin/fm-main-prompt-alarm.sh)
#      fires for that prompt in a lock-owning primary session, prints no
#      decision, and alerts through the wedge-alarm seam while the prompt waits.
# Every failure names the Claude Code version. The prompt is cancelled, never
# approved. The project, FM_HOME, and alert sink are isolated; Claude keeps its
# existing managed authentication and trusts one temporary folder. One Haiku
# turn is submitted.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PERMISSION_PROMPT_LIVE_E2E claude tmux jq

# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

# The lab pane runs this exact binary, so the version named in every failure is
# the one under test even when the pane's login shell would resolve another.
# FM_PERMISSION_PROMPT_LIVE_CLAUDE_BIN points the guard at another installed copy.
CLAUDE_BIN=${FM_PERMISSION_PROMPT_LIVE_CLAUDE_BIN:-$(command -v claude)}
CLAUDE_VERSION=$("$CLAUDE_BIN" --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-permission-prompt-live)
PRIMARY="$LAB/primary"
SOCKET="fm-permission-prompt-$$"
SESSION="fm-permission-prompt-e2e"
MARKER=fm-live-ask-marker

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# A primary checkout whose own state holds the session lock, so the tracked
# registration is in scope exactly as it is for a real primary.
mkdir -p "$PRIMARY/state" "$PRIMARY/config"
git init -q "$PRIMARY"
: > "$PRIMARY/AGENTS.md"
ln -s "$ROOT/bin" "$PRIMARY/bin"
: > "$LAB/alerts"
cat > "$LAB/recorder" <<SH
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> '$LAB/alerts'
SH
cat > "$LAB/ask-hook" <<SH
#!/usr/bin/env bash
case "\$(cat)" in
  *$MARKER*) printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"live guard asks"}}' ;;
esac
exit 0
SH
chmod +x "$LAB/recorder" "$LAB/ask-hook"
REGISTRATION=$(jq -c '.hooks.PermissionRequest' "$ROOT/.claude/settings.json")
[ "$REGISTRATION" != null ] || fail "the tracked settings register no PermissionRequest hook"
jq -n --arg ask "$LAB/ask-hook" --argjson reg "$REGISTRATION" '{feedbackDrafts: "off", hooks: {
  PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $ask}]}],
  PermissionRequest: $reg}}' > "$LAB/settings.json"

# Claude Code refuses to nest inside another Claude session, so the inherited
# session markers are dropped from the lab's environment.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -40 2>/dev/null || true
}

# The folder-trust dialog opens with its cursor on "No, exit": move onto the
# trusting option before confirming.
answer_trust_dialog() {  # <screen text>
  case "$1" in *'Yes, I trust this folder'*) ;; *) return 1 ;; esac
  case "$(printf '%s\n' "$1" | grep -F '❯' | head -1)" in
    *'Yes, I trust this folder'*) tmux -L "$SOCKET" send-keys -t "$SESSION" Enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
}

wait_screen() {  # <text> <what> [iterations]
  local text=$1 what=$2 limit=${3:-480} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in *'CLAUDE_EXIT='*) printf '%s\n' "$shot" >&2; fail "Claude Code $CLAUDE_VERSION exited while waiting for $what" ;; esac
    if ! answer_trust_dialog "$shot"; then
      case "$shot" in *"$text"*) return 0 ;; esac
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed $what"
}

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 44 -c "$PRIMARY" \
  "env $(unset_inherited) FM_HOME='$PRIMARY' FM_MAIN_PROMPT_ALARM_SECS=10 FM_WEDGE_ALARM_EXEC='$LAB/recorder' FM_WEDGE_ALARM_CHANNEL=command:unused CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 '$CLAUDE_BIN' --model haiku --dangerously-skip-permissions --settings '$LAB/settings.json'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
wait_screen 'bypass permissions on' 'the composer'
# The lock names Claude itself, the pane shell's child.
pgrep -P "$(tmux -L "$SOCKET" list-panes -t "$SESSION" -F '#{pane_pid}')" claude > "$PRIMARY/state/.lock" \
  || fail "Claude Code $CLAUDE_VERSION: no claude process under the lab pane"

tmux -L "$SOCKET" send-keys -t "$SESSION" -l "Use the Bash tool to run exactly this one command and nothing else: echo $MARKER && echo second-line"
sleep 0.5
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_screen 'Do you want to proceed?' 'the permission prompt for the hook ask'
sleep 1
shot=$(screen)

subject=$(fm_composer_permission_prompt "$shot") || {
  printf '%s\n' "$shot" >&2
  fail "Claude Code $CLAUDE_VERSION: fm_composer_permission_prompt does not match the live permission prompt"
}
[ "$subject" = "echo $MARKER && echo second-line" ] || {
  printf '%s\n' "$shot" >&2
  fail "Claude Code $CLAUDE_VERSION: the live prompt's subject was '$subject', not the prompted command's first line"
}
name=$(fm_composer_blocking_dialog "$shot") || fail "Claude Code $CLAUDE_VERSION: the live permission prompt is not a blocking dialog"
[ "$name" = "Claude permission prompt: echo $MARKER && echo second-line" ] \
  || fail "Claude Code $CLAUDE_VERSION: the live prompt's dialog name was '$name'"
pass "Claude Code $CLAUDE_VERSION: the live hook-ask permission prompt matches and names the prompted command"

i=0
while [ "$i" -lt 160 ] && [ ! -s "$LAB/alerts" ]; do sleep 0.25; i=$((i + 1)); done
[ -s "$LAB/alerts" ] || fail "Claude Code $CLAUDE_VERSION: the PermissionRequest registration raised no alert; log: $(cat "$PRIMARY/state/.main-permission-prompt.log" 2>/dev/null)"
case "$(cat "$LAB/alerts")" in
  *"permission prompt for Bash: echo $MARKER && echo second-line; supervision is paused until it is answered") ;;
  *) fail "Claude Code $CLAUDE_VERSION: the alert did not name the prompted command: $(cat "$LAB/alerts")" ;;
esac
screen | grep -F 'Do you want to proceed?' >/dev/null \
  || fail "Claude Code $CLAUDE_VERSION: the prompt was answered by something other than this guard"
pass "Claude Code $CLAUDE_VERSION: the PermissionRequest registration alerts on a waiting prompt and leaves it unanswered"

tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
