#!/usr/bin/env bash
# Opt-in credentialed Codex live regression for the Stop-owned auto-arm
# (bin/fm-codex-stop-autoarm.sh + bin/fm-turnend-guard.sh --codex).
# Proves, against the real installed Codex interactive TUI and the real tracked
# hook registration: at a real turn end the async auto-arm arms the watcher
# with no model-issued arm command; an actionable close is delivered as a
# queued `codex queue` user turn that wakes the idle session into a handling
# turn; the wake turn's own Stop re-arms; and the cooperative guard consumes
# no forced continuation while the auto-arm is healthy.
# The project and FM_HOME are isolated; Codex keeps using its existing managed
# authentication and shared app-server daemon. No live fleet home, worktree,
# or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_AUTOARM_LIVE_E2E codex

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.codex-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
CODEX_VERSION=$(codex --version)

LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
LAB_HOME=$("$LAB_HOME_HELPER" create "$LAB/labhome") || fail "could not mint the lab home"
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$LAB_HOME") || fail "could not mint the lab tmux dir"
LAB_SOCKET=fmcodexautoarm$$

cleanup() {
  [ "${FM_KEEP_LAB:-0}" = 1 ] && { printf 'fm-codex-autoarm-live-e2e: lab kept at %s\n' "$LAB" >&2; return 0; }
  TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" kill-server 2>/dev/null || true
  "$LAB_HOME_HELPER" teardown "$LAB_HOME" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# A git clone carries only committed state, so copy the working-tree surfaces
# under test (same pattern as the Claude auto-arm live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.codex/hooks.json" "$PROJECT/.codex/hooks.json"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"

# Rapid-death arm fixture: runs 1-2 close actionable; run 3 closes clean and
# ends the in-flight need, so a misbehaving session can never loop forever.
# A handling successor (FM_WATCH_PREDECESSOR_ARM_PID set) only confirms a
# started watcher and never consumes a numbered run.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: the model invokes it once per delivered wake. The third total
# drain ends the in-flight need after two complete Stop-owned cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

pane_capture() {
  TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" capture-pane -p -t lab 2>/dev/null || true
}

# Launch the real TUI in the lab pane, then record the TUI's codex pid as the
# home's session-lock owner: the Stop hook runs as a descendant of that pid,
# which is exactly the production identity shape.
TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" new-session -d -s lab -x 200 -y 50 \
  "cd \"$PROJECT\" && FM_HOME=\"$HOME_DIR\" exec codex --dangerously-bypass-hook-trust -c model_reasoning_effort=\\\"low\\\"" \
  || fail "could not launch the Codex TUI in the lab pane"
pane_pid=""
for _ in $(seq 1 60); do
  pane_pid=$(TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" list-panes -t lab -F '#{pane_pid}' 2>/dev/null | head -n 1)
  [ -n "$pane_pid" ] && break
  sleep 0.5
done
[ -n "$pane_pid" ] || fail "the lab pane never reported its shell pid"
codex_pid=""
for _ in $(seq 1 60); do
  codex_pid=$(pgrep -P "$pane_pid" 2>/dev/null | head -n 1)
  [ -n "$codex_pid" ] && break
  sleep 0.5
done
[ -n "$codex_pid" ] || fail "no codex process appeared under the lab pane shell"
printf '%s\n' "$codex_pid" > "$HOME_DIR/state/.lock"

PROMPT='Reply with exactly CYCLE0 and stop. Whenever a message arrives that starts with a watcher envelope, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh and never use background tasks.'

# Wait for the composer to exist before typing, answering the one folder-trust
# dialog if it appears, then submit with a settled second Enter; the TUI drops
# keystrokes sent during early initialization.
ready=0
for _ in $(seq 1 120); do
  pane=$(pane_capture)
  if printf '%s' "$pane" | grep -q "GPT-6.1"; then
    ready=1
    break
  fi
  if printf '%s' "$pane" | grep -q "Trust this folder"; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" send-keys -t lab Enter
  fi
  sleep 1
done
[ "$ready" = 1 ] || fail "the Codex TUI never reached its ready composer"
TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" send-keys -t lab "$PROMPT"
sleep 1
TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" send-keys -t lab Enter
sleep 3
TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L "$LAB_SOCKET" send-keys -t lab Enter

# Wait for two complete hook-owned cycles: each actionable close arms, queues
# one wake, the model drains in the woken turn, and that turn's Stop re-arms.
deadline=$(( $(date +%s) + 420 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  arms=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
  drains=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
  [ "${arms:-0}" -ge 2 ] && [ "${drains:-0}" -ge 2 ] && break
  sleep 2
done 2>/dev/null

pane_capture > "$LAB/pane-final.txt"
arms=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
drains=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "${arms:-0}" -ge 2 ] || fail "expected at least 2 hook-owned arm cycles, got ${arms:-0}: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
[ "${drains:-0}" -ge 2 ] || fail "expected at least 2 model wake drains from queued deliveries, got ${drains:-0}"
pane_capture > "$LAB/pane-final.txt"
grep -q 'fixture-rapid-1' "$LAB/pane-final.txt" || fail "the first actionable reason never appeared in the lab pane"
grep -q 'FIRSTMATE_OP' "$LAB/pane-final.txt" || fail "the queued wake did not carry the operational envelope into the pane"
! grep -q 'TURN WOULD END BLIND' "$LAB/pane-final.txt" \
  || fail "the cooperative guard consumed a forced continuation while the auto-arm was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" != arming ] \
  || fail "the auto-arm epoch ledger was left mid-claim"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "the auto-arm owner lock was left behind"
if [ -e "$HOME_DIR/state/.claude-autoarm-epoch" ]; then
  grep -q 'outcome=rewake\|outcome=clean' "$HOME_DIR/state/.claude-autoarm-epoch" \
    || fail "the epoch ledger recorded neither a delivered rewake nor a clean close: $(sed -n '1p' "$HOME_DIR/state/.claude-autoarm-epoch")"
fi

printf 'ok - Codex %s live E2E armed at a real turn end, delivered two actionable closes as queued wake turns, re-armed through the wake Stops, and kept the cooperative guard silent\n' "$CODEX_VERSION"
