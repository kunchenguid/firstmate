#!/usr/bin/env bash
# Opt-in credentialed live guard for Claude's background-task exit picker
# (docs/verification/runtime-backends.md "Claude background-task exit picker").
# Against the real installed Claude Code in an isolated tmux server, a worker
# with a background shell is driven through both recorded answers:
#   park  closes the picker with Escape, leaves the agent and its background
#         shell running, writes no parked marker, and exits 3;
#   exit  confirms "Exit and stop tasks" with Enter, the agent stops, and the
#         background shell stops with it.
# A picker that no longer renders, or renders in a shape the recognizer misses,
# fails naming the Claude version. Claude keeps its existing authentication;
# the firstmate home, worktree, and tmux server are throwaway.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_EXIT_PICKER_LIVE_E2E,FM_CLAUDE_LIVE_E2E claude tmux

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(fm_test_tmproot fm-claude-exit-picker-live)
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd -P)
SOCKET="fmpicker$$"
REAL_TMUX=$(command -v tmux)
MARK=$(( 600 + $$ % 300 ))
HOME_DIR="$LAB/home"
WT="$LAB/wt"
FAKEBIN="$LAB/bin"
ID=pk1

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  pkill -f "sleep $MARK\$" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

lfail() {
  fail "Claude $CLAUDE_VERSION: $1"
}

# Every firstmate tmux call reaches the lab server only.
mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCKET" > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"
LAB_TMUX="$FAKEBIN/tmux"

screen() {
  "$LAB_TMUX" capture-pane -p -t "lab:fm-$ID" 2>/dev/null
}

fm_git_init_commit "$WT" >/dev/null
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$HOME_DIR/config"
printf '# brief for %s\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
fm_write_meta "$HOME_DIR/state/$ID.meta" "window=lab:fm-$ID" "endpoint_task_id=$ID" \
  "worktree=$WT" "project=$WT" "harness=claude" "kind=ship"

"$LAB_TMUX" new-session -d -s lab -n "fm-$ID" -c "$WT" -x 160 -y 50 \
  || lfail "the lab tmux server did not start"
"$LAB_TMUX" send-keys -t "lab:fm-$ID" -l \
  "claude --model haiku --allowedTools 'Bash(sleep:*)'"
"$LAB_TMUX" send-keys -t "lab:fm-$ID" Enter
# A new folder asks for trust once, with the cursor on "No, exit": move it onto
# the trusting option, then confirm. These are the only keys the guard types
# outside firstmate's own commands, and only in this throwaway folder.
i=0 ready=0
while [ "$i" -lt 180 ]; do
  shot=$(screen)
  case "$shot" in
    *'Yes, I trust this folder'*)
      case "$(printf '%s\n' "$shot" | grep -E '^ +❯ ' | head -n 1)" in
        *'Yes, I trust this folder'*) "$LAB_TMUX" send-keys -t "lab:fm-$ID" Enter ;;
        *) "$LAB_TMUX" send-keys -t "lab:fm-$ID" Down ;;
      esac
      ;;
    *)
      printf '%s\n' "$shot" | grep -Eq '^(│ )?>( |$)|^❯' && { ready=1; break; }
      ;;
  esac
  sleep 0.5
  i=$((i + 1))
done
[ "$ready" -eq 1 ] || lfail "the composer never rendered: $(screen | tail -n 15)"

"$LAB_TMUX" send-keys -t "lab:fm-$ID" -l \
  "Start the shell command \`sleep $MARK\` with the Bash tool's run_in_background option, then reply with exactly STARTED and nothing else."
# Typed text settles before the submit key, or Claude takes Enter as part of it.
sleep 1
"$LAB_TMUX" send-keys -t "lab:fm-$ID" Enter
# The prompt itself shows STARTED, so the process, not the screen, proves the
# background shell runs; the agent is then back at an empty composer with its
# shell counted in the footer.
i=0
until pgrep -f "sleep $MARK\$" >/dev/null; do
  [ "$i" -lt 240 ] || lfail "the agent did not start the background shell: $(screen | tail -n 15)"
  sleep 0.5
  i=$((i + 1))
done
i=0
until shot=$(screen) && printf '%s\n' "$shot" | grep -Eq '^❯[^A-Za-z0-9]*$' \
  && printf '%s\n' "$shot" | grep -Eq '[0-9]+ shells?'; do
  [ "$i" -lt 240 ] || lfail "the agent did not finish its reply: $(screen | tail -n 15)"
  sleep 0.5
  i=$((i + 1))
done
sleep 3

# A park-eligible record: idle for two hours, latest status a declared wait.
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$ID")
printf 'busy_gen=%s\n' "$GEN" >> "$HOME_DIR/state/$ID.meta"
printf 'v1 gen=%s seq=9 state=idle source=claude-hook event=stop ts=%s\n' \
  "$GEN" "$(( $(date +%s) - 7200 ))" > "$HOME_DIR/state/$ID.busy-state"
printf 'paused [at=1]: waiting on review\n' > "$HOME_DIR/state/$ID.status"

control() {
  env PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

out=$(control "$ID" park); rc=$?
[ "$rc" -eq 3 ] || lfail "park should leave a worker with background work running (exit 3), got $rc: $out"
[ ! -e "$HOME_DIR/state/$ID.cold-parked" ] || lfail "park wrote a marker for a worker it left running"
pgrep -f "sleep $MARK\$" >/dev/null || lfail "park stopped the background shell"
[ "$("$LAB_TMUX" display-message -p -t "lab:fm-$ID" '#{pane_current_command}')" != zsh ] \
  || lfail "park stopped the agent"
screen | grep -q 'Background work is running' && lfail "park left the picker open"

out=$(control "$ID" exit); rc=$?
[ "$rc" -eq 0 ] || lfail "exit should confirm the picker and stop the agent, got $rc: $out"
case "$out" in *stopped*) ;; *) lfail "exit did not report the stop: $out" ;; esac
i=0
while pgrep -f "sleep $MARK\$" >/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
pgrep -f "sleep $MARK\$" >/dev/null && lfail "the background shell survived the confirmed exit"

pass "Claude $CLAUDE_VERSION live: park closes the background-task exit picker with Escape and keeps the worker, exit confirms it and stops agent and shell"
