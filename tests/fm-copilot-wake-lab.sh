#!/usr/bin/env bash
# Shared lab for tests/fm-copilot-wake.test.sh and tests/fm-copilot-wake-restart.test.sh: sourced, not run.
# A real tmux pane on a private socket runs a stand-in that draws Copilot's rule-box composer
# (tests/captures/copilot-1.0.105-tmux) and logs every submitted line. Vendor facts are recorded in
# docs/verification/copilot.md; no Copilot install is needed.
# shellcheck disable=SC2016 # single-quoted conditions are expanded by wait_until's eval
set -u


# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-copilot-wake)
# The shim below execs REAL_TMUX, so it must be a binary: a version-manager shim (a script with a
# shebang) first on PATH would resolve back to this test's own shim and recurse without end.
REAL_TMUX=
while IFS= read -r candidate; do
  [ "$(head -c 2 "$candidate" 2>/dev/null)" = '#!' ] || { REAL_TMUX=$candidate; break; }
done < <(type -aP tmux)
[ -n "$REAL_TMUX" ] || { echo "skip: no real tmux binary on PATH (only shebang shims); put the tmux binary's directory first on PATH"; exit 0; }
SOCKET="copilot-wake-$$"
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
WAKE="$ROOT/bin/fm-copilot-wake.sh"
SUBMITTED="$TMP_ROOT/submitted"
FOOTER="$TMP_ROOT/footer"
MODE="$TMP_ROOT/mode"
DROP="$TMP_ROOT/drop-enters"
GEN_RING=0
WAKE_PID=

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_all() {
  [ -z "$WAKE_PID" ] || kill "$WAKE_PID" 2>/dev/null
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_all EXIT

SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM" "$STATE" "$HOME_DIR/bin"
# While $INJECT exists, the first composer read (capture-pane -e) is followed by one typed key: a
# keystroke landing right after the ring's composer read, drawn before the ring goes on.
INJECT="$TMP_ROOT/inject-key"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
"$REAL_TMUX" -L "$SOCKET" "\$@"
rc=\$?
if [ "\$1 \$2" = "capture-pane -e" ] && [ -e "$INJECT" ]; then
  rm -f "$INJECT"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t lab:main -l Q
  sleep 0.5
fi
exit \$rc
SH
chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE
git init -q "$HOME_DIR"
: > "$HOME_DIR/AGENTS.md"
export FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_GUARD_GRACE=300
export COPILOT_HOME="$TMP_ROOT/copilot-home"
export FM_COPILOT_WAKE_POLL=1 FM_COPILOT_WAKE_GRACE=2 FM_COPILOT_WAKE_MAX=3 FM_COPILOT_WAKE_INTERRUPT_GRACE=3 FM_COPILOT_WAKE_START_WAIT=30

: > "$SUBMITTED"
printf ' Working · 130 B esc esc interrupt\n' > "$FOOTER"
printf 'box\n' > "$MODE"
printf '0\n' > "$DROP"

# Argv[0] `copilot` is what bin/fm-agent-process-lib.sh reads as the live agent.
cat > "$TMP_ROOT/pane.sh" <<'SH'
#!/usr/bin/env bash
dir=$1
buf=
rule=$(printf '─%.0s' $(seq 1 60))
draw() {
  printf '\033[2J\033[H'
  case "$(cat "$dir/mode")" in
    # The cursor rests at the end of the composer line, as in Copilot, so a typed key moves it.
    box) printf '  <worktree>\n%s\n❯ %s\n%s\n%s\033[3;%dH' "$rule" "$buf" "$rule" "$(cat "$dir/footer")" "$((3 + ${#buf}))" ;;
    *) printf 'Pick something\n  1. one\n  2. two\n' ;;
  esac
}
while :; do
  draw
  if IFS= read -rsn1 -t 0.2 ch; then
    case "$ch" in
      '')
        drop=$(cat "$dir/drop-enters")
        if [ "$drop" -gt 0 ]; then
          printf '%s\n' "$((drop - 1))" > "$dir/drop-enters"
        else
          printf '%s\n' "$buf" >> "$dir/submitted"
          buf=
        fi
        ;;
      $'\x15') buf= ;;
      *) buf=$buf$ch ;;
    esac
  fi
done
SH
chmod +x "$TMP_ROOT/pane.sh"
# shellcheck disable=SC2016 # expanded by the pane's own bash
LC_ALL=C.UTF-8 tmux new-session -d -s lab -n main -x 100 -y 20 "bash -c 'exec -a copilot bash \"\$0\" \"\$1\"' $TMP_ROOT/pane.sh $TMP_ROOT"
tmux new-window -d -t lab:1 'sleep 600'
export FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=lab:main

count() { grep -c 'operational input waiting' "$SUBMITTED" 2>/dev/null; }
hook() { printf '{"sessionId":"s"%s}' "${3:-}" | "$WAKE" turn "$1" "$2"; }
row() {  # one queued wake with a fresh sequence number
  GEN_RING=$((GEN_RING + 1))
  printf '%s\t%s\tsignal\tk\tp\n' "$(date +%s)" "$((1000 + GEN_RING))" >> "$STATE/.wake-queue"
}
clear_queue() { : > "$STATE/.wake-queue"; }
wait_until() {  # <seconds> <bash condition>
  local end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    eval "$2" && return 0
    sleep 0.2
  done
  return 1
}
expect_no_ring_for() {  # <seconds> <from-count> <label>
  ! wait_until "$1" "[ \"\$(count)\" -gt $2 ]" || fail "$3: a wake was typed, submitted: $(cat "$SUBMITTED")"
}
pane_text() { tmux capture-pane -p -t lab:main; }
