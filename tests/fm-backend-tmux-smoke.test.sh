#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

if [ "$(uname -s)" = Linux ] && [ "${FM_TMUX_TEST_NAMESPACE:-0}" = 0 ]; then
  exec unshare --user --map-root-user --pid --fork --mount-proc \
    env FM_TMUX_TEST_NAMESPACE=1 bash "${BASH_SOURCE[0]}"
fi

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

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "${FOREIGN_SOCKET:-}" ] || "$REAL_TMUX" -S "$FOREIGN_SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\${FM_TEST_TMUX_FAIL_SESSION:-0}:\$*" in 1:*new-session*) exit 1 ;; esac
exec "$REAL_TMUX" -f /dev/null -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
TMUX_TMPDIR="$SHIM_DIR"
export TMUX_TMPDIR
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
tmux set-option -g default-command 'exec /bin/bash --noprofile --norc' \
  || fail "private server deterministic shell setup failed"
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

# --- recorded server identity and legacy migration --------------------------

[ "$(uname -s)" = Linux ] || { echo "skip - kernel ownership recovery requires Linux"; cleanup_all; exit 0; }
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
LAB_HOME="$SHIM_DIR/home"
LAB_WT="$SHIM_DIR/work"
LAB_PROJ="$SHIM_DIR/project"
mkdir -p "$LAB_HOME/state" "$LAB_HOME/data/identity"
fm_git_worktree "$LAB_PROJ" "$LAB_WT" fm/identity || fail "private isolated worktree fixture failed"
printf 'retained dirty work\n' > "$LAB_WT/dirty"
printf "# Task\n## Captain's intent\nretained instructions\n## Firstmate spec\nPrivate local-only recovery fixture.\n" > "$LAB_HOME/data/identity/brief.md"
cp "$LAB_HOME/data/identity/brief.md" "$SHIM_DIR/brief-original"
printf 'working: retained status\n' > "$LAB_HOME/state/identity.status"
printf 'retained poll\n' > "$LAB_HOME/state/identity.poll"
mkdir -p "$LAB_HOME/state/identity.inbox"
printf 'retained steer\n' > "$LAB_HOME/state/identity.inbox/001.msg"
LAB_TARGET="$SESSION:fm-identity"
LAB_WID=$(fm_backend_tmux_create_task "$SESSION" fm-identity "$LAB_WT") \
  || fail "private legacy endpoint failed"
LAB_META="$LAB_HOME/state/identity.meta"
{
  printf 'window=%s\nworktree=%s\nproject=%s\n' "$LAB_TARGET" "$LAB_WT" "$LAB_PROJ"
  printf 'harness=codex\nkind=ship\nmode=local-only\nyolo=off\nbranch=fm/identity\n'
  printf 'tasktmp=%s\n' "$SHIM_DIR/tasktmp"
  printf 'spawn_gen=s%s.123.456\n' "$(date +%s)"
} > "$LAB_META"
printf 'Independently retained private tmux server and window read.\n' > "$SHIM_DIR/proof"
LAB_SOCKET=$(tmux display-message -p '#{socket_path}')
LAB_PID=$(tmux display-message -p '#{pid}')
LAB_START=$(tmux display-message -p '#{start_time}')
identity_bind() {
  FM_HOME="$LAB_HOME" bash "$ROOT/bin/fm-control.sh" identity bind-tmux \
    --socket "$LAB_SOCKET" --server-pid "$LAB_PID" --server-start "$LAB_START" \
    --window-id "$LAB_WID" --note-file "$SHIM_DIR/proof"
}
for _ in $(seq 1 100); do
  [ "$(fm_backend_tmux_agent_state "$LAB_TARGET")" != dead ] || break
  sleep 0.1
done
[ "$(fm_backend_tmux_agent_state "$LAB_TARGET")" = dead ] || fail "private shell did not become idle"
cp "$LAB_META" "$SHIM_DIR/legacy-original"
cat > "$SHIM_DIR/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "axi") cat "$FM_TEST_NM_OVERVIEW" ;;
  "axi status --run "*) cat "$FM_TEST_NM_DETAIL.${4}" ;;
  *) exit 2 ;;
esac
SH
chmod +x "$SHIM_DIR/no-mistakes"
export FM_TEST_NM_OVERVIEW="$SHIM_DIR/nm-overview" FM_TEST_NM_DETAIL="$SHIM_DIR/nm-detail"
printf 'unavailable\n' > "$FM_TEST_NM_OVERVIEW"
cp /bin/sleep "$SHIM_DIR/codex-agent"
fm_backend_tmux_send_text_line "$LAB_TARGET" "'$SHIM_DIR/codex-agent' 30"
for _ in $(seq 1 100); do
  [ "$(fm_backend_tmux_agent_state "$LAB_TARGET")" != alive ] || break
  sleep 0.1
done
[ "$(fm_backend_tmux_agent_state "$LAB_TARGET")" = alive ] || fail "private live-agent fixture failed"
if identity_bind > "$SHIM_DIR/live-bind.out" 2>&1; then fail "a live agent authorized migration"; fi
cmp "$LAB_META" "$SHIM_DIR/legacy-original" || fail "live-agent refusal changed metadata"
fm_backend_tmux_send_key "$LAB_TARGET" C-c
sleep 0.1
fm_backend_tmux_send_text_line "$LAB_TARGET" 'sleep 30'
sleep 0.1
[ "$(fm_backend_tmux_agent_state "$LAB_TARGET")" = ambiguous ] || fail "private ambiguous-owner fixture failed"
if identity_bind > "$SHIM_DIR/ambiguous-bind.out" 2>&1; then fail "ambiguous ownership authorized migration"; fi
fm_backend_tmux_send_key "$LAB_TARGET" C-c
sleep 0.1
pass "real tmux: live agents and ambiguous owners refuse migration without changing metadata"
identity_bind > "$SHIM_DIR/bind.out" 2>&1 \
  || fail "verified legacy migration failed: $(cat "$SHIM_DIR/bind.out")"
fm_backend_tmux_bind_meta "$LAB_META" || fail "native recorded identity did not bind"
fm_backend_validate_task_endpoint "$LAB_META" identity || fail "recorded native metadata is invalid"
[ "$FM_TMUX_SOCKET" = "$LAB_SOCKET" ] || fail "migration recorded the wrong server"
[ "$FM_TMUX_WINDOW_ID" = "$LAB_WID" ] || fail "migration recorded the wrong stable window"
pass "real tmux: independently verified legacy idle endpoint migrates without changing dirty work"

# An idle pane is not sufficient when a detached task agent or validation
# allocation still owns the task. Only its verified idle shell is exempted.
FM_TASK_INBOX="$LAB_HOME/state/identity.inbox" "$SHIM_DIR/codex-agent" 30 &
LAB_JOB=$!
sleep 0.1
if fm_backend_tmux_idle_custody "$LAB_META" "$LAB_TARGET"; then
  fail "idle pane bypassed a detached task-marked agent"
fi
kill "$LAB_JOB"; wait "$LAB_JOB" 2>/dev/null || true
sed 's/^mode=.*/mode=no-mistakes/' "$LAB_META" > "$SHIM_DIR/idle-validation-meta"
printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  newer,fm/identity,failed,abcdef0,null\n  older,fm/identity,running,abcdef0,null\n' > "$FM_TEST_NM_OVERVIEW"
printf 'branch: fm/identity\nstatus: failed\n' > "$FM_TEST_NM_DETAIL.newer"
printf 'branch: fm/identity\nstatus: running\n' > "$FM_TEST_NM_DETAIL.older"
if fm_backend_tmux_idle_custody "$SHIM_DIR/idle-validation-meta" "$LAB_TARGET"; then
  fail "idle pane bypassed an older active validation allocation"
fi
printf 'branch: fm/identity\nstatus: completed\n' > "$FM_TEST_NM_DETAIL.older"
fm_backend_tmux_idle_custody "$SHIM_DIR/idle-validation-meta" "$LAB_TARGET" \
  || fail "terminal validation history refused an otherwise owner-free idle pane"
printf 'branch: fm/identity\nstatus: parked\n' > "$FM_TEST_NM_DETAIL.older"
if fm_backend_tmux_idle_custody "$SHIM_DIR/idle-validation-meta" "$LAB_TARGET"; then
  fail "parked validation custody authorized idle adoption"
fi
printf 'unavailable\n' > "$FM_TEST_NM_OVERVIEW"
pass "real tmux: idle adoption checks detached agents and every same-branch validation candidate"

# A different live socket cannot authorize the record, even if its labels match.
cp "$LAB_META" "$SHIM_DIR/bound-meta"
sed "s/^tmux_server_pid=.*/tmux_server_pid=1/" "$LAB_META" > "$SHIM_DIR/reused-meta"
if fm_backend_tmux_bind_meta "$SHIM_DIR/reused-meta" 2>/dev/null; then
  fail "a reused server identity was accepted"
fi
sed "s|^tmux_socket=.*|tmux_socket=$SHIM_DIR/nonexistent|" "$LAB_META" > "$SHIM_DIR/unreachable-meta"
if fm_backend_tmux_bind_meta "$SHIM_DIR/unreachable-meta" 2>/dev/null; then
  fail "an inaccessible socket was accepted"
fi
sed "s|^tmux_socket=.*|tmux_socket=$SHIM_DIR/foreign|" "$LAB_META" > "$SHIM_DIR/foreign-meta"
FOREIGN_SOCKET="$SHIM_DIR/foreign"
"$REAL_TMUX" -S "$FOREIGN_SOCKET" -f /dev/null new-session -d -s foreign -n fm-identity \
  || fail "private foreign server fixture failed"
if fm_backend_tmux_bind_meta "$SHIM_DIR/foreign-meta" 2>/dev/null; then
  fail "a different live server was accepted"
fi
fm_backend_tmux_bind_meta "$LAB_META" || fail "original binding did not survive refusal cases"
pass "real tmux: reused, foreign, and unreachable server bindings refuse"

# Window names can be reused; stable ids on the same live server cannot.
tmux rename-window -t "$LAB_WID" renamed-identity || fail "private rename failed"
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$LAB_META")
case "$absence" in unproven$'\t'*) ;; *) fail "a renamed window authorized replacement" ;; esac
tmux rename-window -t "$LAB_WID" fm-identity || fail "private rename restore failed"
tmux kill-window -t "$LAB_WID" || fail "private recorded window close failed"
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$LAB_META")
[ "$absence" = gone$'\t' ] || fail "positive window absence was not proven: $absence"
pass "real tmux: server-wide stable identity refuses a renamed window and proves positive absence"

# Kernel cwd evidence must contradict absence when a detached job survives.
( cd "$LAB_WT" && exec sleep 30 ) &
LAB_JOB=$!
sleep 0.1
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$LAB_META")
kill "$LAB_JOB" 2>/dev/null || true
wait "$LAB_JOB" 2>/dev/null || true
case "$absence" in unproven$'\t'*) ;; *) fail "a live validation job authorized replacement" ;; esac
pass "real tmux: a detached validation job prevents replacement of an absent window"

# A surviving task-marked agent remains an owner after moving its cwd away.
FM_TASK_INBOX="$LAB_HOME/state/identity.inbox" "$SHIM_DIR/codex-agent" 30 &
LAB_JOB=$!
sleep 0.1
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$LAB_META")
kill "$LAB_JOB" 2>/dev/null || true
wait "$LAB_JOB" 2>/dev/null || true
case "$absence" in unproven$'\t'*) ;; *) fail "a moved task-marked agent authorized replacement" ;; esac
pass "real tmux: task-marked agents outside the worktree still prevent replacement"

# A missing legacy record still refuses; no metadata is fabricated from the
# caller's server. Active validation custody remains a separate refusal.
sed '/^tmux_/d' "$LAB_META" > "$SHIM_DIR/legacy-meta"
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$SHIM_DIR/legacy-meta")
case "$absence" in unproven$'\t'*) ;; *) fail "legacy missing endpoint guard weakened" ;; esac
sed 's/^mode=.*/mode=no-mistakes/' "$LAB_META" > "$SHIM_DIR/validation-meta"
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$SHIM_DIR/validation-meta")
case "$absence" in unproven$'\t'*) ;; *) fail "unreleased validation custody authorized replacement" ;; esac
pass "real tmux: legacy missing endpoints and unproven validation custody remain refused"

[ "$(cat "$LAB_WT/dirty")" = "retained dirty work" ] || fail "dirty work changed"
cmp "$LAB_HOME/data/identity/brief.md" "$SHIM_DIR/brief-original" || fail "brief changed"
[ "$(cat "$LAB_HOME/state/identity.status")" = "working: retained status" ] || fail "status changed"
[ "$(cat "$LAB_HOME/state/identity.poll")" = "retained poll" ] || fail "poll changed"
[ "$(cat "$LAB_HOME/state/identity.inbox/001.msg")" = "retained steer" ] || fail "inbox changed"
pass "real tmux: migration and absence proofs preserve brief, inbox, poll, status, and dirty work"

# Destroy only this suite's private server. A retained native receipt supports
# dead legacy migration; a missing receipt still preserves the original guard.
cp "$LAB_META" "$SHIM_DIR/native-receipt"
tmux kill-server || fail "private server death fixture failed"
for _ in $(seq 1 100); do
  [ -e "/proc/$LAB_PID" ] || break
  sleep 0.1
done
[ ! -e "/proc/$LAB_PID" ] || fail "private server PID was not reaped"
fm_backend_tmux_bind_meta "$LAB_META" || fail "proven-dead server binding failed"
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$LAB_META")
[ "$absence" = gone$'\t' ] || fail "positive server death was not proved: $absence"
sed '/^tmux_/d' "$LAB_META" > "$SHIM_DIR/legacy-dead"
cp "$SHIM_DIR/legacy-dead" "$LAB_META"
if identity_bind > "$SHIM_DIR/dead-unbound.out" 2>&1; then fail "dead legacy migration guessed provenance"; fi
FM_HOME="$LAB_HOME" bash "$ROOT/bin/fm-control.sh" identity bind-tmux \
  --identity-file "$SHIM_DIR/native-receipt" --note-file "$SHIM_DIR/proof" \
  > "$SHIM_DIR/dead-bind.out" 2>&1 || fail "dead legacy native receipt migration failed: $(cat "$SHIM_DIR/dead-bind.out")"
pass "real tmux: kernel-confirmed server death supports retained-receipt migration and refuses missing provenance"

# Simulate a legacy record persisted before reboot. Current boot observations
# are explicitly recovery evidence; no historical boot or start field is made up.
cp "$SHIM_DIR/legacy-dead" "$LAB_META"
BOOT_EPOCH=$(awk '$1 == "btime" {print $2}' /proc/stat)
sed "s/^spawn_gen=.*/spawn_gen=s$((BOOT_EPOCH - 10)).123.456/" "$LAB_META" > "$SHIM_DIR/preboot-meta"
cp "$SHIM_DIR/preboot-meta" "$LAB_META"
FM_HOME="$LAB_HOME" bash "$ROOT/bin/fm-control.sh" identity bind-tmux \
  --original-host --socket "$LAB_SOCKET" --server-pid "$LAB_PID" --note-file "$SHIM_DIR/proof" \
  > "$SHIM_DIR/reboot-bind.out" 2>&1 || fail "confirmed-original-host reboot migration failed: $(cat "$SHIM_DIR/reboot-bind.out")"
fm_backend_validate_task_endpoint "$LAB_META" identity || fail "reboot binding metadata is invalid"
grep -q '^tmux_reboot_boot_id=' "$LAB_META" || fail "current reboot proof was not recorded"
if grep -q '^tmux_boot_id=' "$LAB_META"; then fail "historical boot identity was fabricated"; fi
cp "$LAB_META" "$SHIM_DIR/reboot-bound"
sed "s/^spawn_gen=.*/spawn_gen=s$(date +%s).123.456/" "$LAB_META" > "$SHIM_DIR/inconsistent-meta"
absence=$(fm_control_endpoint_absence_verdict tmux "$LAB_TARGET" "$SHIM_DIR/inconsistent-meta")
case "$absence" in unproven$'\t'*) ;; *) fail "changed launch provenance authorized recovery" ;; esac
pass "real tmux: confirmed-host reboot proof migrates pre-boot legacy metadata and rejects inconsistent provenance"

# Retain a sibling before starting the successor server. Its launch generation
# differs, while its independently migrated predecessor server is the same.
LAB_WT2="$SHIM_DIR/work-sibling"
LAB_PROJ2="$SHIM_DIR/project-sibling"
fm_git_worktree "$LAB_PROJ2" "$LAB_WT2" fm/sibling || fail "sibling isolated worktree fixture failed"
mkdir -p "$LAB_HOME/data/sibling"
sed -e "s|window=.*|window=$SESSION:fm-sibling|" \
  -e "s|worktree=.*|worktree=$LAB_WT2|" -e "s|project=.*|project=$LAB_PROJ2|" \
  -e 's|branch=.*|branch=fm/sibling|' \
  -e "s|spawn_gen=.*|spawn_gen=s$((BOOT_EPOCH - 20)).456.789|" \
  -e "s|tmux_reboot_spawn_gen=.*|tmux_reboot_spawn_gen=s$((BOOT_EPOCH - 20)).456.789|" \
  "$LAB_META" > "$LAB_HOME/state/sibling.meta"
cp "$LAB_HOME/data/identity/brief.md" "$LAB_HOME/data/sibling/brief.md"
printf 'sibling dirty work\n' > "$LAB_WT2/dirty"

# Fail after native startup and before session/window/metadata publication.
# The unchanged record can authorize exactly the durably recorded successor.
if FM_TEST_TMUX_FAIL_SESSION=1 fm_backend_tmux_recover_server "$LAB_META" "$LAB_WT" "$SESSION"; then
  fail "startup-before-publication failure injection did not fire"
fi
cmp "$LAB_META" "$SHIM_DIR/reboot-bound" || fail "partial server startup changed task metadata"
fm_backend_tmux_bind_meta "$LAB_META" || fail "durable startup receipt did not authorize the exact successor"
SUCCESSOR_PID=$FM_TMUX_SERVER_PID
[ "$SUCCESSOR_PID" != "$LAB_PID" ] || fail "recovery retained dead predecessor identity"
fm_backend_tmux_bind_meta "$LAB_HOME/state/sibling.meta" \
  || fail "verified sibling predecessor did not recognize the shared successor"
[ "$FM_TMUX_SERVER_PID" = "$SUCCESSOR_PID" ] || fail "sibling adopted a different server"
mkdir -p "$SHIM_DIR/unrelated/state"
cp "$LAB_META" "$SHIM_DIR/unrelated/state/identity.meta"
if fm_backend_tmux_bind_meta "$SHIM_DIR/unrelated/state/identity.meta" 2>/dev/null; then
  fail "unrelated home without successor provenance adopted a reused socket"
fi
pass "real tmux: durable startup provenance survives partial failure and recognizes only recorded same-home siblings"

cat > "$SHIM_DIR/codex" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  --version) printf 'codex-cli 0.134.0\\n'; exit 0 ;;
esac
exec "$SHIM_DIR/codex-agent" 120
SH
chmod +x "$SHIM_DIR/codex"
mkdir -p "$SHIM_DIR/user-home"
RETAINED_HEAD=$(git -C "$LAB_WT" rev-parse HEAD)
FM_HOME="$LAB_HOME" HOME="$SHIM_DIR/user-home" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_LAUNCH_WAIT=20 bash "$ROOT/bin/fm-control.sh" identity relaunch --note 'Resume preserved work after verified private server death.' \
  > "$SHIM_DIR/recover.out" 2>&1 || fail "dead-server same-task recovery failed: $(cat "$SHIM_DIR/recover.out")"
fm_backend_tmux_bind_meta "$LAB_META" || fail "replacement identity did not bind"
[ "$(fm_backend_tmux_agent_state "$LAB_TARGET")" = alive ] || fail "native replacement agent was not confirmed"
[ "$(git -C "$LAB_WT" rev-parse HEAD)" = "$RETAINED_HEAD" ] || fail "recovery moved committed work"
[ "$(git -C "$LAB_WT" symbolic-ref --short HEAD)" = fm/identity ] || fail "recovery changed branch"
[ "$(cat "$LAB_WT/dirty")" = "retained dirty work" ] || fail "recovery changed dirty work"
[ "$(cat "$LAB_HOME/state/identity.status")" = "working: retained status" ] || fail "recovery truncated status"
[ "$(cat "$LAB_HOME/state/identity.poll")" = "retained poll" ] || fail "recovery changed poll"
[ "$(cat "$LAB_HOME/state/identity.inbox/001.msg")" = "retained steer" ] || fail "recovery changed inbox"
grep -Fqx 'retained instructions' "$LAB_HOME/data/identity/brief.md" || fail "recovery lost the brief"
grep -Fq 'Resume preserved work' "$LAB_HOME/data/identity/brief.md" || fail "replacement missed the progress note"
grep -q '^tmux_boot_id=' "$LAB_META" || fail "native replacement server identity was not recorded"
if grep -q '^tmux_reboot_' "$LAB_META"; then fail "replacement retained obsolete reboot binding"; fi
pass "real tmux: dead-server recovery launches the same task and preserves commits, branch, dirty work, brief, inbox, poll, and status"
FM_HOME="$LAB_HOME" HOME="$SHIM_DIR/user-home" FM_SPAWN_NO_GUARD=1 \
  FM_CONTROL_LAUNCH_WAIT=20 bash "$ROOT/bin/fm-control.sh" sibling relaunch --note 'Resume the preserved sibling on the verified shared successor.' \
  > "$SHIM_DIR/sibling-recover.out" 2>&1 || fail "same-socket sibling recovery failed: $(cat "$SHIM_DIR/sibling-recover.out")"
fm_backend_tmux_bind_meta "$LAB_HOME/state/sibling.meta" || fail "sibling replacement identity did not bind"
[ "$FM_TMUX_SERVER_PID" = "$SUCCESSOR_PID" ] || fail "sibling recovery replaced the shared successor"
[ "$(fm_backend_tmux_agent_state "$SESSION:fm-sibling")" = alive ] || fail "sibling agent was not confirmed"
[ "$(cat "$LAB_WT2/dirty")" = "sibling dirty work" ] || fail "sibling dirty work changed"
[ "$(fm_backend_tmux_agent_state "$LAB_TARGET")" = alive ] || fail "sibling recovery disturbed the first task"
pass "real tmux: two tasks recover on the same successor socket without disturbing the first live task"
unset FM_TMUX_SOCKET FM_TMUX_SERVER_PID FM_TMUX_SERVER_START FM_TMUX_WINDOW_ID FM_TMUX_HOST_ID FM_TMUX_BOOT_ID FM_TMUX_PID_NAMESPACE FM_TMUX_PROCESS_IDENTITY

cleanup_all
trap - EXIT
