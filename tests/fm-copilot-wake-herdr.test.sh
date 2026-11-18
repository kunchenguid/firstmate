#!/usr/bin/env bash
# Portable regression for bin/fm-copilot-wake.sh on a Herdr pane. A real Herdr
# server runs in a throwaway named lab session (never default), a stand-in pane with
# argv[0] `copilot` draws the block-glyph composer pinned by
# tests/captures/copilot-1.0.105-herdr and logs every submitted line, and a real
# watcher drives the wake. Vendor facts are in docs/verification/copilot.md; no
# Copilot install is needed. Skips when herdr or jq is missing.
# shellcheck disable=SC2016 # single-quoted conditions are expanded by wait_until's eval
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

herdr_forget_inherited_pane
TMP_ROOT=$(fm_test_tmproot fm-copilot-wake-herdr)
SESSION="fm-lab-cwake-$$"
export HERDR_SESSION="$SESSION"
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
WAKE="$ROOT/bin/fm-copilot-wake.sh"
SUBMITTED="$TMP_ROOT/submitted"
FOOTER="$TMP_ROOT/footer"
MODE="$TMP_ROOT/mode"
GEN_RING=0
WAKE_PID=
PANE=

# shellcheck disable=SC2329 # Invoked by the EXIT trap below.
cleanup_all() {
  [ -z "$WAKE_PID" ] || kill "$WAKE_PID" 2>/dev/null
  herdr_safe_stop_and_delete "$SESSION" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

mkdir -p "$STATE"
git init -q "$HOME_DIR"
: > "$HOME_DIR/AGENTS.md"
export FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_GUARD_GRACE=300
export FM_COPILOT_WAKE_POLL=1 FM_COPILOT_WAKE_GRACE=2 FM_COPILOT_WAKE_MAX=3 FM_COPILOT_WAKE_INTERRUPT_GRACE=3 FM_COPILOT_WAKE_START_WAIT=30
: > "$SUBMITTED"
printf ' ◎ Working · 130 B esc esc interrupt\n' > "$FOOTER"
printf 'box\n' > "$MODE"

# Argv[0] `copilot` is what bin/fm-agent-process-lib.sh reads as the live agent.
# The pane shell is $SHELL, or plain sh when that is unset, and dash has no
# `exec -a`, so the stand-in is started through an explicit bash.
cat > "$TMP_ROOT/pane.sh" <<'SH'
#!/usr/bin/env bash
dir=$1
buf=
top=$(printf '╻'; printf '▄%.0s' $(seq 1 60))
bottom=$(printf '╹'; printf '▀%.0s' $(seq 1 60))
draw() {
  printf '\033[2J\033[H'
  case "$(cat "$dir/mode")" in
    box) printf ' <worktree>\n%s\n┃ %s\n%s\n%s\n' "$top" "$buf" "$bottom" "$(cat "$dir/footer")" ;;
    *) printf 'Pick something\n  1. one\n  2. two\n' ;;
  esac
}
stty -echo 2>/dev/null
while :; do
  draw
  if IFS= read -rsn1 -t 0.2 ch; then
    case "$ch" in
      '') printf '%s\n' "$buf" >> "$dir/submitted"; buf= ;;
      $'\x15') buf= ;;
      *) buf=$buf$ch ;;
    esac
  fi
done
SH
chmod +x "$TMP_ROOT/pane.sh"

. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
IDS=$(fm_backend_herdr_create_task "${CONTAINER_RAW%%$'\t'*}" "fm-cwake-pane" /tmp "${CONTAINER_RAW#*$'\t'}") || fail "create_task failed"
read -r _TAB PANE <<EOF2
$IDS
EOF2
TARGET="$SESSION:$PANE"
ready=0
for _ in $(seq 1 100); do
  fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>/dev/null | jq -e '.result.process_info as $p | ($p.foreground_processes | length == 1) and ($p.foreground_processes[0].pid == $p.shell_pid)' >/dev/null 2>&1 && ready=$((ready + 1)) || ready=0
  [ "$ready" -ge 10 ] && break
  sleep 0.1
done
[ "$ready" -ge 10 ] || fail "the pane shell never became ready: $(fm_backend_herdr_cli "$SESSION" pane process-info --pane "$PANE" 2>&1)"
fm_backend_herdr_send_text_line "$TARGET" "LC_ALL=C.UTF-8 exec bash -c 'exec -a copilot bash \"\$0\" \"\$@\"' '$TMP_ROOT/pane.sh' '$TMP_ROOT'" || fail "could not start the stand-in"
export FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET"

# While $INJECT exists, the first styled pane read (the ring's composer read) is
# followed by one typed key, drawn before the ring goes on: a keystroke landing
# right after the composer read.
INJECT="$TMP_ROOT/inject-key"
REAL_HERDR=$(command -v herdr)
mkdir -p "$TMP_ROOT/herdr-shim"
cat > "$TMP_ROOT/herdr-shim/herdr" <<SH
#!/usr/bin/env bash
"$REAL_HERDR" "\$@"
rc=\$?
case " \$* " in
  *" pane read "*" ansi "*)
    if [ -e "$INJECT" ]; then
      rm -f "$INJECT"
      "$REAL_HERDR" pane send-text "$PANE" Q --session "$SESSION" >/dev/null 2>&1
      sleep 0.5
    fi
    ;;
esac
exit \$rc
SH
chmod +x "$TMP_ROOT/herdr-shim/herdr"
export PATH="$TMP_ROOT/herdr-shim:$PATH"

count() { grep -c 'operational input waiting' "$SUBMITTED" 2>/dev/null; }
row() { GEN_RING=$((GEN_RING + 1)); printf '%s\t%s\tsignal\tk\tp\n' "$(date +%s)" "$((1000 + GEN_RING))" >> "$STATE/.wake-queue"; }
wait_until() { local end=$(( $(date +%s) + $1 )); while [ "$(date +%s)" -lt "$end" ]; do eval "$2" && return 0; sleep 0.2; done; return 1; }
pane_text() { fm_backend_herdr_visible_capture "$TARGET"; }
send() { fm_backend_herdr_cli "$SESSION" pane send-text "$PANE" "$1" >/dev/null; }
hook() { printf '{"sessionId":"s"}' | "$WAKE" turn "$1" "$2"; }
wait_until 20 'pane_text | grep -q "Working"' || fail "the stand-in never drew: $(pane_text)"

out=$("$WAKE" start 2>&1) || fail "start failed on a Herdr pane: $out; log: $(cat "$STATE/.copilot-wake.log" 2>/dev/null)"
case "$out" in 'copilot wake: running pid='*) ;; *) fail "start must report a running process: $out" ;; esac
WAKE_PID=$(cat "$STATE/.copilot-wake.lock/pid")
pass "fm-copilot-wake start: accepts a live Herdr pane"

row
n=$(count)
! wait_until 5 "[ \"\$(count)\" -gt $n ]" || fail "a running turn was rung: $(cat "$SUBMITTED")"
hook idle agent-stop
printf '\n' > "$FOOTER"
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "an idle Herdr pane was never woken; log: $(cat "$STATE/.copilot-wake.log")"
line=$(sed -n 1p "$SUBMITTED")
kind=$(printf '%s' "$line" | FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-operational-input.sh" doorbell-kind) || fail "not a verifiable doorbell: $line"
[ "$kind" = watcher ] || fail "the doorbell record must be a watcher input: $kind"
pass "fm-copilot-wake: a running turn defers the wake and an idle Herdr pane gets the typed doorbell"

n=$(count)
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "an unacknowledged wake was not re-rung"
: > "$STATE/.wake-queue"
sleep 1
n=$(count)
! wait_until 5 "[ \"\$(count)\" -gt $n ]" || fail "an acknowledged queue was rung"
pass "fm-copilot-wake: an unacknowledged wake is re-rung until the queue row is gone"

send 'half written'
wait_until 5 'pane_text | grep -q "┃ half written"' || fail "the draft did not reach the composer"
row
n=$(count)
! wait_until 5 "[ \"\$(count)\" -gt $n ]" || fail "a half-written line was typed over: $(cat "$SUBMITTED")"
pane_text | grep -q '┃ half written$' || fail "the draft changed: $(pane_text)"
fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" ctrl+u >/dev/null
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the draft cleared"
grep -q 'half written' "$SUBMITTED" && fail "the wake merged with the draft"
pass "fm-copilot-wake: a half-written line is left intact and the wake lands after it clears"

: > "$STATE/.wake-queue"
: > "$INJECT"
row
n=$(count)
wait_until 15 '[ ! -e "$INJECT" ]' || fail "the key was never injected"
wait_until 15 'grep -q "the composer changed before the doorbell landed" "$STATE/.copilot-wake.log"' \
  || fail "the ring did not refuse after the key landed; log: $(cat "$STATE/.copilot-wake.log")"
pane_text | grep -q '┃ Q$' || fail "the operator's key was not left alone: $(pane_text)"
# The doorbell names a mktemp path that can itself contain a Q.
sed "s#${TMP_ROOT}[^ ']*##g" "$SUBMITTED" | grep -q 'Q' && fail "the key merged with the doorbell: $(cat "$SUBMITTED")"
fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" ctrl+u >/dev/null
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the refused ring"
pass "fm-copilot-wake: a key landing right after the composer read makes the ring refuse and stay out of the draft"

: > "$STATE/.wake-queue"
printf 'picker\n' > "$MODE"
sleep 1
row
n=$(count)
! wait_until 5 "[ \"\$(count)\" -gt $n ]" || fail "an unrecognized screen was rung"
printf 'box\n' > "$MODE"
wait_until 15 "[ \"\$(count)\" -gt $n ]" || fail "the wake was lost after the picker closed"
pass "fm-copilot-wake: an unrecognized screen defers the wake"

fm_backend_herdr_cli "$SESSION" pane send-keys "$PANE" ctrl+c >/dev/null
wait_until 30 'grep -q "stopped: the pane agent is gone" "$STATE/.copilot-wake.log"' || fail "the wake did not stand down after the agent left: $(cat "$STATE/.copilot-wake.log")"
wait_until 10 '! kill -0 "$WAKE_PID" 2>/dev/null' || fail "the stood-down process kept running"
pass "fm-copilot-wake: it stands down when Copilot leaves the Herdr pane"


out=$(FM_SUPERVISOR_TARGET="$SESSION:w9:p9" "$WAKE" start 2>&1) && fail "a missing pane must be refused: $out"
pass "fm-copilot-wake start: a missing Herdr pane is refused"

# The captured process-info body of a live Copilot pane names argv[0] `copilot`.
SHIM="$TMP_ROOT/shim"
mkdir -p "$SHIM"
cat > "$SHIM/herdr" <<SH
#!/usr/bin/env bash
cat "$ROOT/tests/captures/copilot-1.0.105-herdr/process-info.json"
SH
chmod +x "$SHIM/herdr"
got=$(PATH="$SHIM:$PATH" fm_backend_herdr_foreground_argv0s "fake:w1:p1")
[ "$got" = copilot ] || fail "the captured foreground should read argv[0] copilot: $got"
got=$(PATH="$SHIM:$PATH" fm_backend_herdr_foreground_argv0s "fake:w9:p9")
[ -z "$got" ] || fail "a pane id that does not round-trip must read as empty: $got"
pass "fm_backend_herdr_foreground_argv0s: reads argv[0] from a captured live process-info body"
