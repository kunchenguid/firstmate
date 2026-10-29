#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FM_GATE_REFUSE_BYPASS=1

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  if [ -n "${PANE_WATCH_PID:-}" ]; then
    kill "$PANE_WATCH_PID" 2>/dev/null || true
    wait "$PANE_WATCH_PID" 2>/dev/null || true
    PANE_WATCH_PID=
  fi
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"
OTHER_SESSION="smoke-other"
PREFIX_SESSION="smoke-prefix-live"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
tmux new-session -d -s "$OTHER_SESSION" -x 200 -y 50 \
  || fail "real tmux: second new-session failed"
tmux new-session -d -s "$PREFIX_SESSION" -n "$WINDOW" -x 200 -y 50 \
  || fail "real tmux: prefix-sharing session failed"
tmux new-session -d -s firstmate -n supervisor -x 200 -y 50 \
  || fail "real tmux: default supervisor session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- target_exists requires exact window and pane membership ----------------

fm_backend_target_exists tmux "$TARGET" \
  || fail "fm_backend_target_exists should report the existing window present"
pass "real tmux: fm_backend_target_exists finds an existing window"

LIVE_PANE=$(tmux display-message -p -t "$TARGET" '#{pane_id}') \
  || fail "could not read the existing pane id"
fm_backend_target_exists tmux "$LIVE_PANE" \
  || fail "fm_backend_target_exists should report the existing pane present"
pass "real tmux: fm_backend_target_exists finds an existing pane"

LIVE_WINDOW_ID=$(tmux display-message -p -t "$TARGET" '#{window_id}') \
  || fail "could not read the existing window id"
LIVE_WINDOW_INDEX=$(tmux display-message -p -t "$TARGET" '#{window_index}') \
  || fail "could not read the existing window index"
LIVE_PANE_INDEX=$(tmux display-message -p -t "$TARGET" '#{pane_index}') \
  || fail "could not read the existing pane index"

for exact_target in "$LIVE_WINDOW_ID" "$SESSION:$LIVE_WINDOW_ID"; do
  fm_backend_target_exists tmux "$exact_target" \
    || fail "fm_backend_target_exists rejected live window-id target $exact_target"
done
pass "real tmux: fm_backend_target_exists accepts bare and session-scoped window ids"

for indexed_target in "$SESSION:$LIVE_WINDOW_INDEX" firstmate:0; do
  fm_backend_target_exists tmux "$indexed_target" \
    || fail "fm_backend_target_exists rejected live window-index target $indexed_target"
done
pass "real tmux: fm_backend_target_exists accepts window indexes including firstmate:0"

fm_backend_target_exists tmux "$SESSION:$LIVE_WINDOW_INDEX.$LIVE_PANE_INDEX" \
  || fail "fm_backend_target_exists rejected live index.pane target"
pass "real tmux: fm_backend_target_exists accepts index.pane targets"

for exact_target in "$SESSION" "=$SESSION:=$WINDOW"; do
  fm_backend_target_exists tmux "$exact_target" \
    || fail "fm_backend_target_exists rejected exact target $exact_target"
done
pass "real tmux: fm_backend_target_exists accepts a bare session and explicit exact markers"

if fm_backend_target_exists tmux "smoke-prefix:$WINDOW"; then
  fail "fm_backend_target_exists prefix-matched a missing session"
fi
pass "real tmux: fm_backend_target_exists anchors the session name"

for malformed_target in '' : "$SESSION:" ":$WINDOW" "$SESSION:$WINDOW:extra"; do
  if fm_backend_target_exists tmux "$malformed_target"; then
    fail "fm_backend_target_exists accepted malformed target '$malformed_target'"
  fi
done
pass "real tmux: fm_backend_target_exists rejects malformed targets"

# A gone name that prefixes a live neighbor is the dangerous send-keys case:
# tmux itself would fall through to the neighbor, so the adapter must stop first.
tmux new-window -d -t "$SESSION:" -n fm-t10 \
  || fail "real tmux: prefix-neighbor window failed"
tmux new-window -d -t "$SESSION:" -n fm-t1 \
  || fail "real tmux: gone-prefix window failed"
tmux kill-window -t "=$SESSION:=fm-t1" \
  || fail "real tmux: could not remove the gone-prefix window"
tmux send-keys -t "$SESSION:fm-t10" \
  "bash -c 'printf \"prefix-neighbor-ready\\n\"; read -r -n 1 key; printf \"%s\" \"\$key\" > \"$SHIM_DIR/key-capture\"'" Enter
wait_for_capture_text "$SESSION:fm-t10" prefix-neighbor-ready \
  || fail "real tmux: prefix-neighbor reader did not become ready"
if fm_backend_tmux_send_key "$SESSION:fm-t1" X; then
  fail "fm_backend_tmux_send_key accepted a gone prefix target"
fi
sleep 0.1
[ ! -e "$SHIM_DIR/key-capture" ] \
  || fail "fm_backend_tmux_send_key delivered a key to the prefix neighbor"
pass "real tmux: fm_backend_tmux_send_key withholds a key from a gone prefix target"

# A gone dotted task window must not resolve as a pane of its undotted neighbor.
tmux new-window -d -t "$SESSION:" -n fm-v1 \
  || fail "real tmux: undotted neighbor window failed"
DOTTED_WINDOW_ID=$(tmux new-window -d -P -F '#{window_id}' -t "$SESSION:" -n fm-v1.0) \
  || fail "real tmux: dotted window failed"
tmux kill-window -t "$DOTTED_WINDOW_ID" \
  || fail "real tmux: could not remove the dotted window"
if fm_backend_target_exists tmux "$SESSION:fm-v1.0"; then
  fail "fm_backend_target_exists reported a gone dotted window present beside fm-v1"
fi
if fm_backend_tmux_send_key "$SESSION:fm-v1.0" X; then
  fail "fm_backend_tmux_send_key accepted a gone dotted target"
fi
pass "real tmux: a gone dotted window reads absent beside its undotted neighbor"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
if fm_backend_target_exists tmux "$TARGET"; then
  fail "fm_backend_target_exists still reports the killed window present"
fi
pass "real tmux: fm_backend_target_exists rejects a killed window while another session stays alive"

if fm_backend_target_exists tmux "smoke-missing:$WINDOW"; then
  fail "fm_backend_target_exists reports a window in a missing session present"
fi
tmux has-session -t "$OTHER_SESSION" \
  || fail "the second session should remain alive while missing-session membership is checked"
pass "real tmux: fm_backend_target_exists rejects a missing session while another session stays alive"

# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- container resolution under a grouped session ---------------------------

# An external client attached through a grouped session (`new-session -t`) is
# the most recently used member of the group; the container must still be the
# session of firstmate's own pane.
OWN_SID=$(tmux display-message -p -t "$SESSION" '#{session_id}')
OWN_SID=${OWN_SID#\$}
tmux new-session -d -s smoke-viewer -t "$SESSION" \
  || fail "real tmux: grouped viewer session failed"
tmux select-window -t smoke-viewer:0 >/dev/null 2>&1 || true
got=$(TMUX="/fake,0,$OWN_SID" fm_backend_tmux_container_ensure)
[ "$got" = "$SESSION" ] \
  || fail "container_ensure chose '$got' instead of the pane's own session '$SESSION' beside a grouped session"
pass "real tmux: container_ensure names the pane's own session, not a more recent grouped session"

# A pane opened from the viewer's session keeps the viewer's id in $TMUX after
# the viewer closes; tmux answers that stale id with empty output and exit 0,
# so the container must come from the pane's surviving session instead.
VIEWER_SID=$(tmux display-message -p -t smoke-viewer '#{session_id}')
VIEWER_SID=${VIEWER_SID#\$}
OWN_PANE=$(tmux display-message -p -t "$SESSION:0" '#{pane_id}')
tmux kill-session -t smoke-viewer || fail "real tmux: killing the grouped viewer session failed"
got=$(TMUX="/fake,0,$VIEWER_SID" TMUX_PANE="$OWN_PANE" fm_backend_tmux_container_ensure)
[ "$got" = "$SESSION" ] \
  || fail "container_ensure chose '$got' instead of the pane's surviving session '$SESSION' for a stale \$TMUX session id"
pass "real tmux: container_ensure falls back to the pane's surviving session when the \$TMUX session id is stale"

# --- task pane identity survives splits and focus changes -------------------

# These are transport tests with raw byte collectors, not simulated agents or
# vendor-screen drift checks. All reads and writes use this suite's real server.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"
PANE_HOME="$SHIM_DIR/home"
mkdir -p "$PANE_HOME/state" "$PANE_HOME/config"
export FM_PANE_TEST_SOCKET="$SOCKET" FM_PANE_TEST_TMUX="$REAL_TMUX" FM_PANE_TEST_LAB="$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<'SHIM'
#!/usr/bin/env bash
target=
previous=
for arg in "$@"; do
  [ "$previous" != -t ] || target=$arg
  previous=$arg
done
printf '%s\t%s\t%s\n' "$1" "$target" "${!#}" >> "$FM_PANE_TEST_LAB/io.log"
if [ "$1" = list-panes ] && [ -f "$FM_PANE_TEST_LAB/fail-global-pane-inventory" ]; then
  for arg in "$@"; do
    [ "$arg" != -a ] || exit 1
  done
fi
if [ "$1" = list-windows ] && [ -f "$FM_PANE_TEST_LAB/fail-global-window-inventory" ]; then
  for arg in "$@"; do
    [ "$arg" != -a ] || exit 1
  done
fi
# Change focus after literal typing, before submission and every retry.
if [ "$1" = send-keys ] && [ -f "$FM_PANE_TEST_LAB/focus" ]; then
  "$FM_PANE_TEST_TMUX" -L "$FM_PANE_TEST_SOCKET" select-pane -t "$(cat "$FM_PANE_TEST_LAB/focus")"
fi
exec "$FM_PANE_TEST_TMUX" -L "$FM_PANE_TEST_SOCKET" "$@"
SHIM
cat > "$SHIM_DIR/collect" <<'COLLECT'
#!/usr/bin/env bash
stty raw -echo
: > "$1"
mode=${2:-}
if [ "$mode" = pending-agent ]; then
  printf '\033[H\033[2J╭────────────╮\r\n│ pending    │\r\n╰────────────╯\033[2;4H'
else
  printf 'collector-ready\r\n'
fi
case "$mode" in
  agent|pending-agent) exec -a codex cat >> "$1" ;;
  *) exec cat >> "$1" ;;
esac
COLLECT
chmod +x "$SHIM_DIR/collect"
PANE_WINDOW="$SESSION:fm-pane"
printf -v collector_cmd 'bash %q %q agent' "$SHIM_DIR/collect" "$SHIM_DIR/agent.bytes"
AGENT_PANE=$(tmux new-window -dP -F '#{pane_id}' -t "$SESSION:" -n fm-pane "$collector_cmd") \
  || fail "real tmux: could not start original byte collector"
wait_for_capture_text "$AGENT_PANE" collector-ready || fail "original collector did not start"
printf 'window=%s\nharness=codex\nkind=scout\n' "$PANE_WINDOW" > "$PANE_HOME/state/pane.meta"
[ "$(fm_backend_io_target_of_meta "$PANE_HOME/state/pane.meta")" = "$PANE_WINDOW" ] \
  || fail "legacy single-pane task lost its window target"
printf 'tmux_pane_id=%s\n' "$AGENT_PANE" >> "$PANE_HOME/state/pane.meta"
printf -v collector_cmd 'bash %q %q' "$SHIM_DIR/collect" "$SHIM_DIR/monitor.bytes"
MONITOR_PANE=$(tmux split-window -t "$AGENT_PANE" -P -F '#{pane_id}' "$collector_cmd") \
  || fail "real tmux: could not start monitor byte collector"
wait_for_capture_text "$MONITOR_PANE" collector-ready || fail "monitor collector did not start"
[ "$(tmux display-message -p -t "$PANE_WINDOW" '#{pane_id}')" = "$MONITOR_PANE" ] \
  || fail "regression setup did not make the monitor active"

pane_send() {
  FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
    FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" FM_SEND_SETTLE=0 \
    bash "$ROOT/bin/fm-send.sh" pane "$@" > "$SHIM_DIR/send.out" 2> "$SHIM_DIR/send.err"
}
assert_agent_only_reads_and_writes() {
  local command target rest
  while IFS=$'\t' read -r command target rest; do
    case "$command" in
      capture-pane|display-message|send-keys)
        [ "$target" = "$AGENT_PANE" ] \
          || fail "task I/O used $command on $target instead of $AGENT_PANE"
        ;;
    esac
  done < "$SHIM_DIR/io.log"
}

: > "$SHIM_DIR/io.log"
pane_send 'first steer' || fail "bound task steer failed: $(cat "$SHIM_DIR/send.err")"
pane_send --key Escape || fail "bound task key failed: $(cat "$SHIM_DIR/send.err")"
grep -q 'Firstmate instruction waiting' "$SHIM_DIR/agent.bytes" || fail "doorbell missed original pane"
grep -q $'\033' "$SHIM_DIR/agent.bytes" || fail "Escape missed original pane"
[ ! -s "$SHIM_DIR/monitor.bytes" ] || fail "monitor received task input"
assert_agent_only_reads_and_writes
pass "real tmux: task doorbell, keys and guarding reads stay on the recorded pane with the monitor active"

# Common ring entry point is also used by the watcher and remote-host delivery.
# Start on the agent, then switch focus inside the literal send before Enter.
tmux select-pane -t "$AGENT_PANE"
printf '%s\n' "$MONITOR_PANE" > "$SHIM_DIR/focus"
: > "$SHIM_DIR/io.log"
fm_task_inbox_ring tmux "$PANE_WINDOW" "$PANE_HOME/state/pane.inbox/001.msg" fm-pane \
  || fail "window-addressed retry ring failed"
assert_agent_only_reads_and_writes
[ ! -s "$SHIM_DIR/monitor.bytes" ] || fail "focus race redirected retry ring input"
[ "$(tmux display-message -p -t "$PANE_WINDOW" '#{pane_id}')" = "$MONITOR_PANE" ] \
  || fail "focus-race hook did not run"
pass "real tmux: re-rings and a focus change between typing and Enter preserve the agent pane"

tmux respawn-pane -k -t "$MONITOR_PANE" "env PS1='monitor-shell-ready> ' bash --noprofile --norc -i"
wait_for_capture_text "$MONITOR_PANE" monitor-shell-ready || fail "idle-shell monitor did not start"
tmux select-pane -t "$MONITOR_PANE"
[ "$(fm_backend_agent_state tmux "$PANE_WINDOW")" = dead ] \
  || fail "focused idle-shell monitor was not classified dead through the window target"
[ "$(fm_backend_agent_state tmux "$AGENT_PANE")" = alive ] \
  || fail "recorded agent pane was not classified alive"

cp "$SHIM_DIR/agent.bytes" "$SHIM_DIR/before-watch.bytes"
touch -t 202001010000 "$PANE_HOME/state/pane.inbox/001.msg"
: > "$SHIM_DIR/io.log"
FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
  FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" \
  FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_TASK_INBOX_GRACE_SECS=1 \
  bash "$ROOT/bin/fm-watch.sh" > "$SHIM_DIR/watch.out" 2>&1 &
PANE_WATCH_PID=$!
for _ in $(seq 1 100); do
  # Wait for delivery bookkeeping, not just literal bytes: stopping mid-submit
  # could leave an in-flight Enter crossing into the next fixture incarnation.
  [ ! -s "$PANE_HOME/state/pane.inbox/.ring-state" ] || break
  sleep 0.1
done
[ -s "$PANE_HOME/state/pane.inbox/.ring-state" ] || fail "watcher did not complete its delivery attempt"
cmp -s "$SHIM_DIR/before-watch.bytes" "$SHIM_DIR/agent.bytes" \
  && fail "watcher did not deliver the aged steer: $(cat "$SHIM_DIR/watch.out")"
assert_agent_only_reads_and_writes
monitor_capture=$(fm_backend_tmux_capture "$MONITOR_PANE" 40)
printf '%s\n' "$monitor_capture" | grep -F 'Firstmate instruction waiting' >/dev/null \
  && fail "ordinary watcher delivery reached the focused idle-shell monitor"
pass "real tmux: ordinary watcher delivery ignores a focused idle-shell monitor"

mv "$PANE_HOME/state/pane.inbox/001.msg" "$PANE_HOME/state/pane.inbox/handled/" \
  || fail "could not acknowledge the ordinary delivery fixture"
: > "$PANE_HOME/config/wait-no-turns"
retry_rec=$(fm_task_inbox_write "$PANE_HOME/state" pane "retry this one-shot steer" fire-and-forget) \
  || fail "could not write the explicit retry-ring fixture"
fm_task_inbox_mark_retry "$PANE_HOME/state" pane "$retry_rec" \
  || fail "could not arm the explicit retry-ring fixture"
touch -t 202001010000 "$PANE_HOME/state/pane.inbox/.retry-ring"
cp "$SHIM_DIR/agent.bytes" "$SHIM_DIR/before-watch.bytes"
: > "$SHIM_DIR/io.log"
for _ in $(seq 1 100); do
  [ -e "$PANE_HOME/state/pane.inbox/.retry-ring" ] || break
  sleep 0.1
done
kill "$PANE_WATCH_PID" 2>/dev/null || true
wait "$PANE_WATCH_PID" 2>/dev/null || true
PANE_WATCH_PID=
[ ! -e "$PANE_HOME/state/pane.inbox/.retry-ring" ] \
  || fail "watcher did not complete the explicit retry ring: $(cat "$SHIM_DIR/watch.out")"
cmp -s "$SHIM_DIR/before-watch.bytes" "$SHIM_DIR/agent.bytes" \
  && fail "focused idle-shell monitor vetoed the explicit retry ring: $(cat "$SHIM_DIR/watch.out")"
assert_agent_only_reads_and_writes
monitor_capture=$(fm_backend_tmux_capture "$MONITOR_PANE" 40)
printf '%s\n' "$monitor_capture" | grep -F 'Firstmate instruction waiting' >/dev/null \
  && fail "explicit watcher retry reached the focused idle-shell monitor"
pass "real tmux: explicit watcher retry ignores a focused idle-shell monitor"
mv "$retry_rec" "$PANE_HOME/state/pane.inbox/handled/" \
  || fail "could not retire the explicit retry fixture"
mv "$PANE_HOME/state/pane.inbox/handled/001.msg" "$PANE_HOME/state/pane.inbox/" \
  || fail "could not restore the ordinary delivery fixture"
rm "$PANE_HOME/config/wait-no-turns"

printf -v collector_cmd 'bash %q %q' "$SHIM_DIR/collect" "$SHIM_DIR/monitor.bytes"
tmux respawn-pane -k -t "$MONITOR_PANE" "$collector_cmd"
wait_for_capture_text "$MONITOR_PANE" collector-ready || fail "monitor collector did not restart"
tmux select-pane -t "$MONITOR_PANE"

# Force the existing submit core to retry Enter against a static bordered
# pending composer. This only exercises routing, not a vendor's screen shape.
printf -v collector_cmd 'bash %q %q pending-agent' "$SHIM_DIR/collect" "$SHIM_DIR/agent.bytes"
tmux respawn-pane -k -t "$AGENT_PANE" "$collector_cmd"
wait_for_capture_text "$AGENT_PANE" pending || fail "retry collector did not start"
[ "$(fm_backend_composer_state tmux "$AGENT_PANE")" = pending ] || fail "retry fixture lacks a proven pending composer"
: > "$SHIM_DIR/io.log"
for peek_selector in pane "$PANE_WINDOW"; do
  peek=$(FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
    FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" \
    bash "$ROOT/bin/fm-peek.sh" "$peek_selector" 10) || fail "metadata-routed peek failed for $peek_selector"
  printf '%s\n' "$peek" | grep -q pending || fail "metadata-routed peek did not read the agent pane for $peek_selector"
  printf '%s\n' "$peek" | grep -q collector-ready && fail "metadata-routed peek read the active monitor for $peek_selector"
done
assert_agent_only_reads_and_writes
: > "$SHIM_DIR/io.log"
resolved=$(fm_backend_io_target_of_meta "$PANE_HOME/state/pane.meta") || fail "could not resolve retry target"
verdict=$(fm_backend_send_text_submit tmux "$resolved" typed-once 3 0.05 0)
[ "$verdict" = pending ] || fail "retry fixture unexpectedly cleared: $verdict"
assert_agent_only_reads_and_writes
[ "$(tr -cd '\r' < "$SHIM_DIR/agent.bytes" | wc -c | tr -d ' ')" = 3 ] \
  || fail "submit did not retry exactly three Enters in the original pane"
[ ! -s "$SHIM_DIR/monitor.bytes" ] || fail "Enter retry reached the monitor"
cp "$SHIM_DIR/agent.bytes" "$SHIM_DIR/before.bytes"
fm_task_inbox_ring tmux "$PANE_WINDOW" "$PANE_HOME/state/pane.inbox/001.msg" fm-pane
rc=$?
[ "$rc" = 1 ] || fail "pending original composer should defer ring, got $rc"
cmp -s "$SHIM_DIR/before.bytes" "$SHIM_DIR/agent.bytes" || fail "pending composer was typed into"
pass "real tmux: Enter retries and the pending-composer guard use the bound pane despite focus changes"
rm "$SHIM_DIR/focus"

cp "$PANE_HOME/state/pane.meta" "$SHIM_DIR/bound.meta"
sed '/^tmux_pane_id=/d' "$SHIM_DIR/bound.meta" > "$PANE_HOME/state/pane.meta"
[ "$(fm_backend_io_target_of_meta "$PANE_HOME/state/pane.meta")" = "$PANE_WINDOW" ] \
  || fail "legacy split window lost its window-based I/O target"
pane_send --key Enter || fail "legacy split window no longer accepts active-pane I/O"
for _ in $(seq 1 100); do
  [ ! -s "$SHIM_DIR/monitor.bytes" ] || break
  sleep 0.01
done
[ -s "$SHIM_DIR/monitor.bytes" ] || fail "legacy I/O did not reach the active pane"
: > "$SHIM_DIR/monitor.bytes"
pass "real tmux: unbound split windows retain active-pane I/O"
cp "$SHIM_DIR/bound.meta" "$PANE_HOME/state/pane.meta"
FOREIGN_PANE=$(tmux display-message -p -t "$OTHER_SESSION:" '#{pane_id}')
sed "s/^tmux_pane_id=.*/tmux_pane_id=$FOREIGN_PANE/" "$SHIM_DIR/bound.meta" > "$PANE_HOME/state/pane.meta"
fm_backend_io_target_of_meta "$PANE_HOME/state/pane.meta" >/dev/null 2>&1
[ "$?" = 1 ] || fail "a foreign live pane was mistaken for a missing endpoint"
pane_send --key Enter && fail "pane belonging to another window accepted a key"
sed 's/^tmux_pane_id=.*/tmux_pane_id=%999999/' "$SHIM_DIR/bound.meta" > "$PANE_HOME/state/pane.meta"
touch "$SHIM_DIR/fail-global-pane-inventory"
fm_backend_io_target_of_meta "$PANE_HOME/state/pane.meta" >/dev/null 2>&1
[ "$?" = 1 ] || fail "an unreadable pane inventory was mistaken for proven absence"
rm "$SHIM_DIR/fail-global-pane-inventory"
fm_backend_io_target_of_meta "$PANE_HOME/state/pane.meta" >/dev/null 2>&1
[ "$?" = 2 ] || fail "a readable pane inventory did not prove an absent binding"
cp "$SHIM_DIR/bound.meta" "$PANE_HOME/state/pane.meta"
printf 'tmux_pane_id=%s\n' "$MONITOR_PANE" >> "$PANE_HOME/state/pane.meta"
pane_send --key Enter && fail "duplicate pane bindings accepted a key"
cp "$SHIM_DIR/bound.meta" "$PANE_HOME/state/pane.meta"
tmux respawn-pane -k -t "$AGENT_PANE" 'bash --noprofile --norc'
for _ in $(seq 1 100); do
  [ "$(fm_backend_agent_state tmux "$AGENT_PANE")" != dead ] || break
  sleep 0.1
done
[ "$(fm_backend_agent_state tmux "$AGENT_PANE")" = dead ] || fail "original pane did not become an idle shell"
fm_task_inbox_ring tmux "$PANE_WINDOW" "$PANE_HOME/state/pane.inbox/001.msg" fm-pane
[ "$?" = 2 ] || fail "a dead bound pane did not refuse I/O without declaring the window dead"
: > "$SHIM_DIR/io.log"
(
  export FM_STATE_OVERRIDE="$PANE_HOME/state"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-supervise-daemon.sh"
  stale_window_is_busy "$PANE_WINDOW" "$PANE_HOME/state"
) || true
assert_agent_only_reads_and_writes
pass "real tmux: stale triage reads the recorded agent with the monitor active"
tmux kill-pane -t "$AGENT_PANE"
fm_backend_io_target_of_meta "$PANE_HOME/state/pane.meta" >/dev/null 2>&1
[ "$?" = 2 ] || fail "a removed original pane was not proven missing with its monitor alive"
snapshot=$(FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
  FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" \
  bash "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed for a removed bound pane"
printf '%s' "$snapshot" | jq -e --arg window "$PANE_WINDOW" '
  .tasks[] | select(.id == "pane")
  | .endpoint.target == $window and .endpoint.exists == true
' >/dev/null || fail "fleet snapshot changed lifecycle health when only the bound pane disappeared: $snapshot"
bearings=$(FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
  FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" \
  bash "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "Bearings failed for a live window with a removed bound pane"
printf '%s' "$bearings" | jq -e '
  [.unhealthy_endpoints[]? | select(.id == "pane")] | length == 0
' >/dev/null || fail "Bearings marked a live lifecycle window unhealthy for a missing bound pane: $bearings"
fm_task_inbox_ring tmux "$PANE_WINDOW" "$PANE_HOME/state/pane.inbox/001.msg" fm-pane
[ "$?" = 2 ] || fail "a missing recorded pane did not remain an I/O-only refusal"
pane_send --key Enter && fail "stale original pane fell back to surviving monitor"
pane_send 'after pane exit' && fail "stale original pane accepted a steer"
[ ! -s "$SHIM_DIR/monitor.bytes" ] || fail "a refused binding typed into monitor"
[ -f "$PANE_HOME/state/pane.inbox/001.msg" ] || fail "pane refusal lost an existing durable steer"
pass "real tmux: mismatched, duplicate and stale pane bindings fail closed"

# Window lifecycle identity remains separate: cleanup closes the whole window,
# including its remaining split, and leaves a different session intact.
fm_backend_tmux_kill "$(fm_backend_target_of_meta "$PANE_HOME/state/pane.meta")" \
  || fail "lifecycle cleanup lost its window target"
fm_backend_target_exists tmux "$MONITOR_PANE" && fail "window cleanup left monitor pane"
tmux has-session -t "$OTHER_SESSION" || fail "cleanup touched another session"
snapshot=$(FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
  FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" \
  bash "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed for a missing lifecycle window"
printf '%s' "$snapshot" | jq -e --arg window "$PANE_WINDOW" '
  .tasks[] | select(.id == "pane")
  | .endpoint.target == $window and .endpoint.exists == false
' >/dev/null || fail "fleet snapshot lost main's missing-window lifecycle health: $snapshot"
bearings=$(FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
  FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" \
  bash "$ROOT/bin/fm-bearings-snapshot.sh" --json) || fail "Bearings failed for a missing lifecycle window"
printf '%s' "$bearings" | jq -e '
  [.unhealthy_endpoints[]? | select(.id == "pane" and .exists == false)] | length == 1
' >/dev/null || fail "Bearings did not retain main's missing-window health result: $bearings"
pass "real tmux: lifecycle cleanup retains the whole-window target"

MOVED_WINDOW="$SESSION:fm-moved"
MOVED_PANE=$(tmux new-window -dP -F '#{pane_id}' -t "$SESSION:" -n fm-moved 'sleep 60') \
  || fail "real tmux: could not start moved-pane fixture"
printf 'window=%s\ntmux_pane_id=%s\nharness=codex\nkind=scout\n' \
  "$MOVED_WINDOW" "$MOVED_PANE" > "$PANE_HOME/state/moved.meta"
sed '/^tmux_pane_id=/d' "$PANE_HOME/state/moved.meta" > "$PANE_HOME/state/moved-legacy.meta"
tmux join-pane -d -s "$MOVED_PANE" -t "$FOREIGN_PANE" \
  || fail "real tmux: could not move the recorded pane"
fm_backend_target_exists tmux "$MOVED_WINDOW" && fail "moved pane left its original window alive"
fm_backend_io_target_of_meta "$PANE_HOME/state/moved.meta" >/dev/null 2>&1
[ "$?" = 1 ] || fail "a moved live pane was mistaken for a missing endpoint"
[ "$(fm_backend_io_target_of_meta "$PANE_HOME/state/moved-legacy.meta")" = "$MOVED_WINDOW" ] || fail "legacy missing-window target changed"
tmux kill-pane -t "$MOVED_PANE"
touch "$SHIM_DIR/fail-global-pane-inventory"
fm_backend_io_target_of_meta "$PANE_HOME/state/moved.meta" >/dev/null 2>&1
[ "$?" = 1 ] || fail "an unreadable global inventory proved a missing window binding absent"
rm "$SHIM_DIR/fail-global-pane-inventory"
fm_backend_io_target_of_meta "$PANE_HOME/state/moved.meta" >/dev/null 2>&1
[ "$?" = 2 ] || fail "a readable global inventory did not prove a missing window binding absent"
pass "real tmux: moved, absent and unreadable missing-window bindings remain distinct"

LEGACY_LIVE_WINDOW="$SESSION:fm-legacy-moved"
LEGACY_LIVE_AGENT=$(tmux new-window -dP -F '#{pane_id}' -t "$SESSION:" -n fm-legacy-moved \
  "bash -c 'exec -a codex sleep 60'") \
  || fail "real tmux: could not start legacy moved-agent fixture"
LEGACY_LIVE_MONITOR=$(tmux split-window -dP -F '#{pane_id}' -t "$LEGACY_LIVE_AGENT" \
  "bash -c 'printf \"legacy-monitor-ready\\n\"; sleep 60'") \
  || fail "real tmux: could not start surviving legacy monitor"
wait_for_capture_text "$LEGACY_LIVE_MONITOR" legacy-monitor-ready \
  || fail "legacy surviving monitor did not start"
printf 'window=%s\nharness=codex\nkind=secondmate\n' "$LEGACY_LIVE_WINDOW" \
  > "$PANE_HOME/state/legacy-moved.meta"
tmux join-pane -d -s "$LEGACY_LIVE_AGENT" -t "$FOREIGN_PANE" \
  || fail "real tmux: could not move the legacy agent away from its monitor"
[ "$(fm_backend_io_target_of_meta "$PANE_HOME/state/legacy-moved.meta")" = "$LEGACY_LIVE_WINDOW" ] \
  || fail "legacy-compatible I/O did not follow the recorded window's remaining pane"
peek=$(FM_HOME="$PANE_HOME" FM_ROOT_OVERRIDE="$PANE_HOME" FM_STATE_OVERRIDE="$PANE_HOME/state" \
  FM_CONFIG_OVERRIDE="$PANE_HOME/config" FM_DATA_OVERRIDE="$PANE_HOME/data" \
  bash "$ROOT/bin/fm-peek.sh" legacy-moved 10) \
  || fail "legacy-compatible peek could not read the remaining monitor"
printf '%s\n' "$peek" | grep -q legacy-monitor-ready \
  || fail "legacy-compatible peek no longer matches baseline remaining-pane behavior"
# Recovery remains window-based for both unbound and bound records, including
# bindings whose pane has moved. Compare the public probe's observable result.
legacy_probe=$(STATE="$PANE_HOME/state" FM_ROOT="$ROOT" bash -c '
  . "$1"
  fm_secondmate_liveness_probe "$2" legacy-moved poll
  printf "%s|%s|%s|%s" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" "$FM_SM_LIVE_REASON"
' _ "$ROOT/bin/fm-secondmate-liveness-lib.sh" "$PANE_HOME/state/legacy-moved.meta")
printf 'tmux_pane_id=%s\n' "$LEGACY_LIVE_AGENT" >> "$PANE_HOME/state/legacy-moved.meta"
bound_probe=$(STATE="$PANE_HOME/state" FM_ROOT="$ROOT" bash -c '
  . "$1"
  fm_secondmate_liveness_probe "$2" legacy-moved poll
  printf "%s|%s|%s|%s" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" "$FM_SM_LIVE_REASON"
' _ "$ROOT/bin/fm-secondmate-liveness-lib.sh" "$PANE_HOME/state/legacy-moved.meta")
[ "$bound_probe" = "$legacy_probe" ] || fail "pane metadata changed recovery behavior: $bound_probe versus $legacy_probe"
fm_backend_target_exists tmux "$LEGACY_LIVE_AGENT" || fail "read-only recovery probe touched the agent"
pass "real tmux: recovery retains window-based behavior for bound and unbound records"

tmux kill-server
fm_backend_io_target_of_meta "$PANE_HOME/state/moved.meta" >/dev/null 2>&1
[ "$?" = 2 ] || fail "an authoritatively absent tmux server became an unreadable pane binding"
[ "$(fm_backend_io_target_of_meta "$PANE_HOME/state/moved-legacy.meta")" = "$MOVED_WINDOW" ] || fail "legacy target resolution changed after server exit"
pass "real tmux: whole-server absence remains a proven missing endpoint"

cleanup_all
trap - EXIT
