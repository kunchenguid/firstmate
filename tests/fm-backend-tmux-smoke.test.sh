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

wait_for_current_path() {  # <target> <path> [samples]
  local target=$1 path=$2 samples=${3:-100} current i=0
  while [ "$i" -lt "$samples" ]; do
    current=$(fm_backend_tmux_current_path "$target" 2>/dev/null || true)
    [ "$current" = "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
ATELIER_SOCKET="fm-backend-atelier-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$ATELIER_SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
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

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
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

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

# --- optional atelier placement ---------------------------------------------
# A configured atelier is still ordinary tmux, but its socket must travel with
# each task endpoint so control, capture, liveness, and teardown never fall back
# to the caller's ambient/default server.
ATELIER_ROOT="$SHIM_DIR/atelier"
ATELIER_CONFIG="$SHIM_DIR/config"
ATELIER_SESSION="gouverneur-atelier"
mkdir -p "$ATELIER_ROOT/bin" "$ATELIER_CONFIG" "$SHIM_DIR/task-one" "$SHIM_DIR/task-two"
TASK_ONE_REAL=$(cd "$SHIM_DIR/task-one" && pwd -P)
TASK_TWO_REAL=$(cd "$SHIM_DIR/task-two" && pwd -P)
touch "$ATELIER_ROOT/bin/atelier"
chmod +x "$ATELIER_ROOT/bin/atelier"
cat > "$ATELIER_CONFIG/tmux-atelier" <<EOF
root=$ATELIER_ROOT
socket=$ATELIER_SOCKET
session=$ATELIER_SESSION
EOF
"$REAL_TMUX" -L "$ATELIER_SOCKET" new-session -d -s "$ATELIER_SESSION" -n 10-active -c "$SHIM_DIR" \
  || fail "real tmux: could not create the configured atelier fixture"

FM_BACKEND_CONFIG_DIR=$ATELIER_CONFIG
export FM_BACKEND_CONFIG_DIR
container=$(fm_backend_tmux_container_ensure) \
  || fail "configured atelier container resolution failed"
[ "$container" = "tmux+$ATELIER_SOCKET/$ATELIER_SESSION" ] \
  || fail "configured atelier resolved '$container', expected 'tmux+$ATELIER_SOCKET/$ATELIER_SESSION'"

stable_one=$(fm_backend_tmux_create_task "$container" fm-one "$SHIM_DIR/task-one") \
  || fail "configured atelier failed to create first isolated task"
stable_two=$(fm_backend_tmux_create_task "$container" fm-two "$SHIM_DIR/task-two") \
  || fail "configured atelier failed to create second isolated task"
case "$stable_one:$stable_two" in
  "tmux+$ATELIER_SOCKET"/@*:"tmux+$ATELIER_SOCKET"/@*) : ;;
  *) fail "configured atelier did not return socket-qualified stable targets: '$stable_one' '$stable_two'" ;;
esac
[ "$stable_one" != "$stable_two" ] \
  || fail "configured atelier reused one endpoint for two tasks"

atelier_one="$container:fm-one"
atelier_two="$container:fm-two"
wait_for_current_path "$stable_one" "$TASK_ONE_REAL" \
  || fail "configured atelier first task did not retain its own cwd"
wait_for_current_path "$stable_two" "$TASK_TWO_REAL" \
  || fail "configured atelier second task did not retain its own cwd"
fm_backend_tmux_target_exists "$atelier_one" \
  || fail "configured atelier endpoint was not reachable through its recorded socket"
fm_backend_tmux_target_exists "$atelier_two" \
  || fail "configured atelier sibling endpoint was not reachable through its recorded socket"
if "$REAL_TMUX" -L "$SOCKET" list-windows -a -F '#{window_name}' | grep -qx fm-one; then
  fail "configured atelier task leaked onto the ordinary tmux server"
fi

meta="$SHIM_DIR/atelier.meta"
cat > "$meta" <<EOF
window=$atelier_one
endpoint_task_id=one
worktree=$SHIM_DIR/task-one
project=$SHIM_DIR
EOF
fm_backend_validate_task_endpoint "$meta" one \
  || fail "socket-qualified atelier metadata failed task-endpoint validation"
fm_backend_tmux_kill "$atelier_one"
if "$REAL_TMUX" -L "$ATELIER_SOCKET" list-windows -t "$ATELIER_SESSION" -F '#{window_name}' | grep -qx fm-one; then
  fail "configured atelier kill did not remove only the requested task window"
fi
"$REAL_TMUX" -L "$ATELIER_SOCKET" list-windows -t "$ATELIER_SESSION" -F '#{window_name}' | grep -qx fm-two \
  || fail "configured atelier kill removed another task's endpoint"
pass "real tmux: configured atelier placement keeps socket-qualified endpoints, isolated cwd values, direct control, and exact-task teardown"

# The atelier is optional presentation placement.
# If its public root or named session is absent, the historical detached
# `firstmate` session remains fully usable on ordinary tmux.
rm -f "$ATELIER_ROOT/bin/atelier"
fallback=$(TMUX='' fm_backend_tmux_container_ensure 2>"$SHIM_DIR/atelier-fallback.err") \
  || fail "absent atelier should fall back to ordinary tmux"
[ "$fallback" = firstmate ] \
  || fail "absent atelier fallback resolved '$fallback', expected historical 'firstmate'"
grep -q 'configured tmux atelier is absent' "$SHIM_DIR/atelier-fallback.err" \
  || fail "absent atelier fallback did not explain why ordinary tmux was selected"
pass "real tmux: absent configured atelier falls back to the historical detached firstmate session"

cleanup_all
trap - EXIT
