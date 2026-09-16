#!/usr/bin/env bash
# Live drift guard for the HumanLayer CLI adapter's vendor-controlled surface:
# process identity, the pinned bare-`>` busy anchor, interrupt, and exit.
# Opt-in because it submits real prompts (the codex provider is a live model;
# there is no echo provider for humanlayer).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HL_BIN=$(command -v humanlayer 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-humanlayer-signals-$$"
SESSION=humanlayer-signals
TARGET="$SESSION:humanlayer"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -n "$LAB" ]; then
    "$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -J -t "$TARGET" -S - >&2 2>/dev/null || true
  fi
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_HUMANLAYER_SIGNALS_LIVE humanlayer tmux
[ -n "$HL_BIN" ] || fail "humanlayer is not installed"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-humanlayer-signals.XXXXXX") || fail "could not create the isolated humanlayer lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" || fail "could not create the isolated lab workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated humanlayer workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated humanlayer workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated humanlayer workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated humanlayer workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated humanlayer workspace"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-task-inbox-lib.sh"
# Keep backend calls on this guard's isolated server as well.
tmux() { "$REAL_TMUX" -L "$SOCKET" "$@"; }

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n humanlayer -c "$WORKSPACE" \
  "$HL_BIN codelayer --provider codex" \
  || fail "could not start the isolated tmux server"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -J -t "$TARGET" -S - 2>/dev/null || true
}

last_nonblank() {
  printf '%s' "$1" | grep -v '^[[:space:]]*$' | tail -1 | sed 's/[[:space:]]*$//'
}

# Launch the interactive codelayer TUI on the verified provider. The TUI draws
# its provider banner and then the pinned bare `>` composer row.

ready=
for _ in $(seq 1 120); do
  screen=$(capture)
  if printf '%s\n' "$screen" | grep -Fq 'codelayer - provider:' \
    && [ "$(last_nonblank "$screen")" = '>' ]; then
    ready=1
    break
  fi
  sleep 0.5
done
[ -n "$ready" ] || fail "the real humanlayer TUI never rendered its banner plus bare-> composer"
[ "$(fm_humanlayer_capture tmux "$TARGET" | fm_humanlayer_screen_state)" = idle ] \
  || fail "the fresh real humanlayer composer is not recognized as safe for initial delivery"
pass "the real humanlayer TUI reaches its verified ready signal"

# Bracketed paste reproduces an unsubmitted multiline composer, including
# transcript-shaped content and a literal final prompt glyph.
for draft in $'Investigate this log:\n[Done] complete\n>' $'\n[Done] complete\n>'; do
  printf '%s' "$draft" > "$LAB/draft"
  "$REAL_TMUX" -L "$SOCKET" load-buffer "$LAB/draft" || fail "could not load draft"
  "$REAL_TMUX" -L "$SOCKET" paste-buffer -p -t "$TARGET" || fail "could not paste draft"
  sleep 0.5
  before=$(capture)
  state=$(fm_humanlayer_capture tmux "$TARGET" | fm_humanlayer_screen_state)
  [ "$state" = unknown ] || fail "literal > draft must remain unsafe"
  if fm_backend_send_text_submit tmux "$TARGET" SHOULD-NOT-SUBMIT 1 0.2 0.1 '' humanlayer >/dev/null; then
    fail "direct steering accepted an unsubmitted draft"
  fi
  if fm_task_inbox_ring tmux "$TARGET" "$LAB/instruction.msg" '' humanlayer; then
    fail "inbox steering accepted an unsubmitted draft"
  fi
  [ "$(capture)" = "$before" ] || fail "steering mutated the unsubmitted draft"
  # Restart this disposable pane: HumanLayer leaves stale multiline rows
  # behind when its input is cleared, which must remain ambiguous too.
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION" -n fresh -c "$WORKSPACE" \
    "$HL_BIN codelayer --provider codex" || fail "could not reset the draft lab"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$TARGET" || fail "could not close the draft pane"
  "$REAL_TMUX" -L "$SOCKET" rename-window -t "$SESSION:fresh" humanlayer || fail "could not name the fresh pane"
  ready=
  for _ in $(seq 1 120); do
    screen=$(capture)
    if printf '%s' "$screen" | grep -Fq 'codelayer - provider:' \
      && [ "$(fm_humanlayer_capture tmux "$TARGET" | fm_humanlayer_screen_state)" = idle ]; then
      ready=1
      break
    fi
    sleep 0.5
  done
  [ -n "$ready" ] || fail "reset worker did not restore an empty composer"
done
pass "direct and inbox steering preserve real multiline drafts ending with >"

prompt="Add 12345 and 67890. Reply with exactly the sum and nothing else"
verdict=$(FM_HUMANLAYER_CONFIRM_POLLS=120 FM_HUMANLAYER_CONFIRM_INTERVAL=0.5 \
  fm_backend_send_text_submit tmux "$TARGET" "$prompt" 1 0.2 0.1 '' humanlayer)
[ "$verdict" = empty ] || fail "shared submission did not confirm the initial instruction: $verdict"
pass "the shared submission boundary confirms the initial instruction"

busy_live=
for _ in $(seq 1 120); do
  screen=$(capture)
  printf '%s' "$screen" | fm_humanlayer_submission_seen "$prompt" && { busy_live=1; break; }
  sleep 0.5
done
[ -n "$busy_live" ] || fail "the real humanlayer turn never produced submission evidence"
pass "the real humanlayer turn produces submission evidence"

idle_settled=
for _ in $(seq 1 240); do
  screen=$(capture)
  [ "$(last_nonblank "$screen")" = '>' ] && { idle_settled=1; break; }
  sleep 0.5
done
[ -n "$idle_settled" ] || fail "the humanlayer anchor never returned after the reply"
case "$screen" in
  *80235*|*80,235*) pass "the real humanlayer worker processed its prompt and settled idle" ;;
  *) fail "the real humanlayer worker never answered its prompt" ;;
esac
printf '%s' "$screen" | fm_busy_humanlayer_tail_idle \
  || fail "the settled humanlayer tail must read idle through fm_busy_humanlayer_tail_idle"
[ "$(fm_humanlayer_capture tmux "$TARGET" | fm_humanlayer_screen_state)" = idle ] \
  || fail "styled completion did not restore safe submission after a real turn"
pass "the settled humanlayer tail reads idle through the anchor fold"

# Interrupt a genuinely long turn: poll until busy is observed, then send
# exactly one Ctrl+C - the adapter's verified interrupt key - and wait for the
# `[Done] Agent interrupted` row it prints; a busy anchor that merely
# disappears is not cancellation and no further key is sent.
prompt="Run: sleep 90; then reply LATE-GUARD"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$prompt" \
  || fail "could not type the long humanlayer prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the long humanlayer prompt"
for _ in $(seq 1 100); do
  screen=$(capture)
  printf '%s' "$screen" | fm_humanlayer_submission_seen "$prompt" && break
  sleep 0.5
done
printf '%s' "$screen" | fm_humanlayer_submission_seen "$prompt" \
  || fail "the long humanlayer turn never produced submission evidence"
[ "$(last_nonblank "$screen")" != '>' ] \
  || fail "the long humanlayer turn already settled before interruption"
process_busy=
for _ in $(seq 1 40); do
  pane_tty=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_tty}')
  foreground=$(ps -t "${pane_tty#/dev/}" -o pid=,pgid=,tpgid= \
    | awk '$2 == $3 { print $1 }')
  if ps -axo pid=,ppid=,pgid=,stat=,comm= | fm_humanlayer_processes_active "$foreground"; then
    process_busy=1
    break
  fi
  sleep 0.5
done
if [ -z "$process_busy" ]; then
  printf 'Foreground pids: %s\n' "$foreground" >&2
  ps -t "${pane_tty#/dev/}" -o pid=,ppid=,pgid=,tpgid=,stat=,comm= >&2
  ps -axo pid=,ppid=,pgid=,stat=,comm= | FM_HL_DIAGNOSTIC_ROOTS="$foreground" awk '
    BEGIN { split(ENVIRON["FM_HL_DIAGNOSTIC_ROOTS"], ids, /[[:space:]]+/); for (i in ids) root[ids[i]] = 1 }
    { parent[$1] = $2; row[$1] = $0 }
    END {
      for (pid in parent) {
        ancestor = pid
        for (depth = 0; depth < 128 && ancestor > 1; depth++) {
          if (root[ancestor]) { print row[pid]; break }
          ancestor = parent[ancestor]
        }
      }
    }
  ' >&2
  fail "HumanLayer did not expose the running tool as foreground worker activity"
fi
[ "$(fm_busy_classify tmux "$TARGET" humanlayer hl-live "$LAB")" = 'busy humanlayer-process' ] \
  || fail "the shared lifecycle classifier did not recognize the running tool"
pass "HumanLayer running-tool activity is attributable to its foreground process"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c \
  || fail "could not send Ctrl+C to the real humanlayer turn"
cancelled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"Agent interrupted"*) cancelled=1; break ;; esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "a single Ctrl+C never cancelled the real humanlayer turn"
pass "a single Ctrl+C cancels the real humanlayer turn"

# The same key at the now-idle composer exits the process: the verified
# key-based exit, and the fact fm_control_exit_key records.
idle=
for _ in $(seq 1 60); do
  screen=$(capture)
  [ "$(last_nonblank "$screen")" = '>' ] && { idle=1; break; }
  sleep 0.5
done
[ -n "$idle" ] || fail "the humanlayer composer never settled idle after the interrupt"
[ "$(fm_busy_classify tmux "$TARGET" humanlayer hl-live "$LAB")" = 'idle humanlayer-anchor' ] \
  || fail "the shared lifecycle classifier did not recognize idle after cancellation"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c \
  || fail "could not send the Ctrl+C exit key"
gone=
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in
    *humanlayer*|*node*) sleep 0.5 ;;
    *) gone=1; break ;;
  esac
done
[ -n "$gone" ] || fail "the Ctrl+C exit key never stopped the real humanlayer process"
pass "a single Ctrl+C at the idle composer stops the real humanlayer process"

cleanup
trap - EXIT
