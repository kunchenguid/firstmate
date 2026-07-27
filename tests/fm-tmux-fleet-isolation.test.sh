#!/usr/bin/env bash
# Every `bash -c '...'` below is deliberately single-quoted: the body runs in a
# CHILD shell whose own environment is what the case is about.
# shellcheck disable=SC2016
# tests/fm-tmux-fleet-isolation.test.sh - the fleet's tmux server must not be
# reachable from a crewmate pane, and every reader must address the server a task
# actually lives on.
#
# Incident behind it (2026-07-28 00:47, and 2026-07-27 20:16 before it): the
# whole fleet shared one tmux server on the default socket and every pane
# inherited $TMUX, so a bare `tmux` typed inside any crew pane operated on the
# fleet's own server. One `kill-server` from an agent experimenting with tmux
# ended the server cleanly (exit code 0) and took five agents with it.
#
# Two halves are covered here:
#   1. the pane sandbox (bin/fm-spawn.sh's `unset TMUX; export TMUX_TMPDIR=...`),
#      exercised against a REAL tmux server on a private socket;
#   2. socket resolution and per-task binding (bin/fm-tmux-lib.sh), including the
#      compatibility rule for metas written before `tmux_socket=` existed.
#
# It also covers the endpoint-existence fix (bin/backends/tmux.sh's
# fm_backend_tmux_target_exists): tmux exits 0 with empty output for a target
# that does not resolve, so the exit code alone reported every dead window alive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMPROOT=$(fm_test_tmproot fm-tmux-fleet-isolation)
# fm_test_tmproot registers its cleanup trap inside the command-substitution
# subshell, so the directory it just made is removed when that subshell exits.
# Every suite here re-creates what it needs afterwards; this one does the same.
mkdir -p "$TMPROOT"
trap 'rm -rf "$TMPROOT"' EXIT

# --- unit: socket resolution -------------------------------------------------
#
# Sourced in a subshell per case so a memoized FM_TMUX_SOCKET never leaks between
# cases.
resolve() {  # <env-assignments...> -> prints the resolved fleet socket
  env "$@" bash -c '
    set -u
    . "$1/bin/fm-tmux-lib.sh"
    fm_tmux_socket_resolve
  ' _ "$ROOT"
}

got=$(resolve TMUX= FM_TMUX_SOCKET=/tmp/explicit.sock TMUX_TMPDIR=/tmp)
[ "$got" = /tmp/explicit.sock ] || fail "FM_TMUX_SOCKET must win: got '$got'"
pass "explicit FM_TMUX_SOCKET wins resolution"

got=$(resolve FM_TMUX_SOCKET= TMUX=/tmp/ambient.sock,999,3 TMUX_TMPDIR=/tmp)
[ "$got" = /tmp/ambient.sock ] || fail "\$TMUX's socket must be used: got '$got'"
pass "ambient \$TMUX socket is the fleet socket"

got=$(resolve FM_TMUX_SOCKET=/tmp/explicit.sock TMUX=/tmp/ambient.sock,999,3)
[ "$got" = /tmp/explicit.sock ] || fail "explicit binding must beat \$TMUX: got '$got'"
pass "explicit binding beats ambient \$TMUX"

got=$(resolve FM_TMUX_SOCKET= TMUX= TMUX_TMPDIR="$TMPROOT")
[ "$got" = "$TMPROOT/tmux-$(id -u)/default" ] \
  || fail "no ambient tmux must fall back to tmux's own default socket: got '$got'"
pass "fallback is tmux's own default socket (attach stays unchanged)"

# --- unit: per-task binding and the pre-field compatibility rule -------------

bind_socket() {  # <meta-file> <ambient-socket> -> prints the bound socket
  env FM_TMUX_SOCKET= TMUX="$2,999,3" bash -c '
    set -u
    . "$1/bin/fm-tmux-lib.sh"
    fm_tmux_bind_meta "$2"
    printf "%s" "$FM_TMUX_SOCKET"
  ' _ "$ROOT" "$1"
}

meta_recorded="$TMPROOT/recorded.meta"
fm_write_meta "$meta_recorded" 'window=firstmate:fm-a' 'tmux_socket=/tmp/recorded.sock'
got=$(bind_socket "$meta_recorded" /tmp/ambient.sock)
[ "$got" = /tmp/recorded.sock ] \
  || fail "a recorded tmux_socket= must be honored over the ambient one: got '$got'"
pass "recorded tmux_socket= is honored"

meta_legacy="$TMPROOT/legacy.meta"
fm_write_meta "$meta_legacy" 'window=firstmate:fm-b' 'worktree=/tmp/wt'
got=$(bind_socket "$meta_legacy" /tmp/ambient.sock)
[ "$got" = /tmp/ambient.sock ] \
  || fail "a meta without tmux_socket= must resolve to the ambient socket (pre-field compatibility): got '$got'"
pass "meta without tmux_socket= keeps resolving to the ambient socket"

got=$(bind_socket /nonexistent/none.meta /tmp/ambient.sock)
[ "$got" = /tmp/ambient.sock ] \
  || fail "a missing meta must resolve to the ambient socket: got '$got'"
pass "missing meta resolves to the ambient socket"

# Two tasks in a row: binding must always assign, never carry over.
got=$(env FM_TMUX_SOCKET= TMUX=/tmp/ambient.sock,999,3 bash -c '
  set -u
  . "$1/bin/fm-tmux-lib.sh"
  fm_tmux_bind_meta "$2"
  fm_tmux_bind_meta "$3"
  printf "%s" "$FM_TMUX_SOCKET"
' _ "$ROOT" "$meta_recorded" "$meta_legacy")
[ "$got" = /tmp/ambient.sock ] \
  || fail "binding must not carry the previous task's socket over: got '$got'"
pass "binding a second task clears the first task's socket"

# --- unit: fm_tmux only adds -S when it changes the target -------------------
#
# The default in-fleet path must stay byte-identical, so anything that observes
# these commands (including every fake tmux in this suite) sees what it did
# before. Uses an argv-recording fake, not a real server.
argvbin=$(fm_fakebin "$TMPROOT")
cat > "$argvbin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*"
SH
chmod +x "$argvbin/tmux"

got=$(env PATH="$argvbin:$PATH" FM_TMUX_SOCKET= TMUX=/tmp/ambient.sock,999,3 bash -c '
  set -u
  . "$1/bin/fm-tmux-lib.sh"
  fm_tmux list-windows -a
' _ "$ROOT")
[ "$got" = "list-windows -a" ] \
  || fail "in-fleet call must stay byte-identical (no -S): got '$got'"
pass "fm_tmux adds no -S when the fleet socket is already tmux's own"

got=$(env PATH="$argvbin:$PATH" FM_TMUX_SOCKET=/tmp/other.sock TMUX=/tmp/ambient.sock,999,3 bash -c '
  set -u
  . "$1/bin/fm-tmux-lib.sh"
  fm_tmux list-windows -a
' _ "$ROOT")
[ "$got" = "-S /tmp/other.sock list-windows -a" ] \
  || fail "a bound socket that differs must be addressed with -S: got '$got'"
pass "fm_tmux addresses a differing socket explicitly with -S"

# --- unit: kill-server is refused -------------------------------------------

out=$(env PATH="$argvbin:$PATH" FM_TMUX_SOCKET=/tmp/other.sock bash -c '
  set -u
  . "$1/bin/fm-tmux-lib.sh"
  fm_tmux kill-server
' _ "$ROOT" 2>&1) && fail "fm_tmux kill-server must fail"
assert_contains "$out" "refuses kill-server" "fm_tmux must explain the refusal"
[ -z "$(printf '%s' "$out" | grep -F 'kill-server' | grep -v refuses || true)" ] \
  || fail "fm_tmux must not have executed tmux at all"
pass "fm_tmux refuses kill-server"

# --- real tmux from here on --------------------------------------------------

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
FLEET_SOCK="$TMPROOT/fleet.sock"
SANDBOX="$TMPROOT/sandbox"
mkdir -p "$SANDBOX"

fleet() { "$REAL_TMUX" -S "$FLEET_SOCK" "$@"; }
kill_fleet() { "$REAL_TMUX" -S "$FLEET_SOCK" kill-server >/dev/null 2>&1 || true; }
trap 'kill_fleet; rm -rf "$TMPROOT"' EXIT

fleet new-session -d -s fleet || fail "could not start the test fleet server"
fleet new-window -d -t fleet: -n fm-probe || fail "could not create the crew window"

# --- endpoint existence: the exit code is not the answer ---------------------

probe_exists() {  # <target> -> 0/1 through the real adapter
  env FM_TMUX_SOCKET="$FLEET_SOCK" bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_target_exists tmux "$2"
  ' _ "$ROOT" "$1"
}

# The raw behavior this fix exists for, asserted directly so the test fails loudly
# if a future tmux ever starts reporting it correctly on its own.
raw=$(fleet display-message -p -t 'totally:bogus' '#{pane_id}' 2>/dev/null); raw_rc=$?
[ "$raw_rc" -eq 0 ] && [ -z "$raw" ] \
  || fail "expected tmux to exit 0 with empty output for a bogus target (got rc=$raw_rc out='$raw'); the existence check's premise changed"
pass "tmux exits 0 with empty output for an unresolvable target (the bug's cause)"

# The nastier half of the same bug: with the SESSION still live, tmux answers a
# gone window with some other window's pane id, so "output is non-empty" would
# also report it alive (issue #1130).
raw=$(fleet display-message -p -t 'fleet:gone-window' '#{pane_id}' 2>/dev/null); raw_rc=$?
[ "$raw_rc" -eq 0 ] && [ -n "$raw" ] \
  || fail "expected tmux to answer a gone window in a live session with another pane's id (got rc=$raw_rc out='$raw')"
pass "tmux answers a gone window with another window's pane id (the bug's second half)"

probe_exists 'fleet:fm-probe' || fail "a live window must read as existing"
pass "live window reads as existing"

! probe_exists 'totally:bogus' || fail "a bogus session:window must read as gone"
pass "bogus session:window reads as gone"

! probe_exists '%9999' || fail "a bogus pane id must read as gone"
pass "bogus pane id reads as gone"

fleet kill-window -t fleet:fm-probe || fail "could not remove the crew window"
! probe_exists 'fleet:fm-probe' || fail "a killed window must read as gone while the server is still up"
pass "killed window reads as gone while the server is still up"

! env FM_TMUX_SOCKET="$TMPROOT/no-such-server.sock" bash -c '
    set -u
    . "$1/bin/fm-backend.sh"
    fm_backend_target_exists tmux fleet:fm-probe
  ' _ "$ROOT" 2>/dev/null \
  || fail "a target on a server that is not running must read as gone"
[ ! -e "$TMPROOT/no-such-server.sock" ] || fail "the existence probe must never start a server"
pass "no server: reads as gone and starts nothing"

# --- the acceptance criterion: kill-server inside a pane -------------------
#
# Recreate the pane and give it exactly the environment bin/fm-spawn.sh sends,
# then run the command that killed the fleet.

# The pane is created exactly the way bin/fm-spawn.sh creates one: the private
# tmux namespace is part of `new-window`, not something typed in afterwards.
fleet new-window -d -t fleet: -n fm-probe -e "TMUX_TMPDIR=$SANDBOX" -e TMUX= \
  || fail "could not recreate the crew window with its private tmux namespace"
PANE_OUT="$TMPROOT/pane.out"

pane_run() {  # <shell-line>
  fleet send-keys -t fleet:fm-probe "$1" Enter
}


wait_for_file() {  # <file> <timeout-secs>
  local f=$1 deadline=$((SECONDS + $2))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -s "$f" ] && return 0
    sleep 0.1
  done
  return 1
}

pane_run "{ echo \"TMUX=[\${TMUX:-empty}]\"; echo \"TMUX_TMPDIR=[\$TMUX_TMPDIR]\"; echo \"TMUX_PANE=[\${TMUX_PANE:-unset}]\"; } > '$PANE_OUT'"
wait_for_file "$PANE_OUT" 15 || fail "the pane never ran the sandbox probe"
assert_grep 'TMUX=[empty]' "$PANE_OUT" "the pane must not carry a usable \$TMUX any more"
assert_grep "TMUX_TMPDIR=[$SANDBOX]" "$PANE_OUT" "the pane must use its private tmux namespace"
assert_no_grep 'TMUX_PANE=[unset]' "$PANE_OUT" \
  "\$TMUX_PANE must stay set - a secondmate finds its own supervisor pane through it"
pass "spawned pane has no usable \$TMUX, a private TMUX_TMPDIR, and its \$TMUX_PANE"

: > "$PANE_OUT"
pane_run "{ tmux new-session -d -s fmrepro; tmux ls; tmux kill-server; echo \"kill-server rc=\$?\"; } > '$PANE_OUT' 2>&1"
wait_for_file "$PANE_OUT" 20 || fail "the pane never ran kill-server"
assert_grep 'fmrepro' "$PANE_OUT" "the pane's own tmux must see only its sandbox session"
assert_no_grep 'fleet:' "$PANE_OUT" "the pane's tmux must not see the fleet's sessions"
assert_grep 'kill-server rc=0' "$PANE_OUT" "kill-server must succeed inside the sandbox"
pass "a bare tmux in the pane sees only its own sandbox server"

fleet_windows=$(fleet list-windows -a -F '#{window_name}' 2>&1) \
  || fail "THE FLEET DIED: 'tmux kill-server' inside a pane took the fleet server with it"$'\n'"$fleet_windows"
assert_contains "$fleet_windows" "fm-probe" "the crew window must survive the pane's kill-server"
pass "fleet survives 'tmux kill-server' run inside a crewmate pane"

# --- teardown cleans up the sandbox server ----------------------------------

TASK_TMP="$TMPROOT/task-tmp"
mkdir -p "$TASK_TMP/tmux"
"$REAL_TMUX" -S "$TASK_TMP/tmux/leftover.sock" new-session -d -s orphan \
  || fail "could not create the leftover sandbox server"
[ -S "$TASK_TMP/tmux/leftover.sock" ] || fail "expected a socket at the sandbox path"

env FM_TMUX_SOCKET="$FLEET_SOCK" BACKEND=tmux TASK_TMP="$TASK_TMP" bash -c '
  set -u
  . "$1/bin/fm-tmux-lib.sh"
  '"$(sed -n '/^cleanup_task_tmux_sandbox() {/,/^}/p' "$ROOT/bin/fm-teardown.sh")"'
  cleanup_task_tmux_sandbox "$TASK_TMP"
' _ "$ROOT" || fail "the sandbox cleanup helper failed"

"$REAL_TMUX" -S "$TASK_TMP/tmux/leftover.sock" list-sessions >/dev/null 2>&1 \
  && fail "teardown must stop a sandbox server left behind by the crewmate"
pass "teardown stops a leftover sandbox tmux server"

fleet list-windows -a >/dev/null 2>&1 \
  || fail "THE FLEET DIED: the sandbox cleanup reached the fleet socket"
pass "sandbox cleanup leaves the fleet server alone"

# --- full chain: peek / send / crew-state / teardown address the recorded server
#
# The dangerous failure is not "endpoint unreadable", it is "read the wrong
# one". A DECOY server carries a session and window with the SAME names as the
# fleet's, and the ambient $TMUX points at the decoy, so any reader that resolves
# its socket from the environment instead of the task's own metadata lands on it.

DECOY_SOCK="$TMPROOT/decoy.sock"
decoy() { "$REAL_TMUX" -S "$DECOY_SOCK" "$@"; }
trap 'kill_fleet; "$REAL_TMUX" -S "$DECOY_SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$TMPROOT"' EXIT

HOME_DIR="$TMPROOT/home"
STATE_DIR="$HOME_DIR/state"
WT_DIR="$TMPROOT/wt"
mkdir -p "$STATE_DIR" "$WT_DIR"
SES=${HOME_DIR##*/}

fleet new-session -d -s "$SES" || fail "could not create the fleet session"
fleet new-window -d -t "$SES:" -n fm-chain || fail "could not create the fleet task window"
decoy new-session -d -s "$SES" || fail "could not create the decoy session"
decoy new-window -d -t "$SES:" -n fm-chain || fail "could not create the decoy task window"

fleet send-keys -t "$SES:fm-chain" "echo THIS-IS-THE-FLEET-PANE" Enter
decoy send-keys -t "$SES:fm-chain" "echo THIS-IS-THE-DECOY-PANE" Enter
sleep 1

fm_write_meta "$STATE_DIR/chain.meta" \
  "window=$SES:fm-chain" \
  "worktree=$WT_DIR" \
  "project=$WT_DIR" \
  "harness=claude" \
  "kind=ship" \
  "mode=direct-PR" \
  "yolo=off" \
  "tmux_socket=$FLEET_SOCK"

# Every reader below runs with the ambient environment pointing at the DECOY.
as_reader() {  # <script> <args...>
  env -u FM_TMUX_SOCKET TMUX="$DECOY_SOCK,999,0" TMUX_TMPDIR="$TMPROOT" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$@"
}

out=$(as_reader "$ROOT/bin/fm-peek.sh" chain 40 2>&1) || fail "fm-peek failed: $out"
assert_contains "$out" "THIS-IS-THE-FLEET-PANE" "fm-peek must read the recorded server's pane"
assert_not_contains "$out" "THIS-IS-THE-DECOY-PANE" "fm-peek must not read the ambient server's same-named window"
pass "fm-peek reads the task's recorded tmux server, not the ambient one"

out=$(as_reader "$ROOT/bin/fm-send.sh" chain --key Escape 2>&1) || fail "fm-send failed: $out"
as_reader "$ROOT/bin/fm-send.sh" chain "echo SENT-BY-FM-SEND" >/dev/null 2>&1 || true
sleep 1
fleet_pane=$(fleet capture-pane -p -t "$SES:fm-chain")
decoy_pane=$(decoy capture-pane -p -t "$SES:fm-chain")
assert_contains "$fleet_pane" "SENT-BY-FM-SEND" "fm-send must deliver to the recorded server's pane"
assert_not_contains "$decoy_pane" "SENT-BY-FM-SEND" "fm-send must never deliver to the ambient server's same-named window"
pass "fm-send delivers to the task's recorded tmux server"

# crew-state: with the task's own window killed on the FLEET while the decoy
# keeps an identically-named one, the pane must read as gone.
fleet kill-window -t "$SES:fm-chain" || fail "could not kill the fleet task window"
out=$(as_reader "$ROOT/bin/fm-crew-state.sh" chain 2>&1) || fail "fm-crew-state failed: $out"
assert_contains "$out" "state: unknown" \
  "fm-crew-state must not adopt the ambient server's same-named window as this task's pane"
pass "fm-crew-state judges the recorded server's endpoint"

decoy_windows=$(decoy list-windows -a -F '#{window_name}')
assert_contains "$decoy_windows" "fm-chain" "the decoy window must still be there before teardown"

# teardown must kill the window on the RECORDED server and leave the decoy's
# identically-named window untouched. The real bin/fm-teardown.sh runs against a
# fake home whose bin/ mirrors the repo's, with the few fleet-touching helpers
# stubbed out (the fixture shape tests/fm-gotmp.test.sh established).
FAKE="$TMPROOT/fake-home"
mkdir -p "$FAKE/bin/backends" "$FAKE/state" "$FAKE/data"
for f in "$ROOT"/bin/*.sh; do ln -sf "$f" "$FAKE/bin/$(basename "$f")"; done
for f in "$ROOT"/bin/backends/*; do ln -sf "$f" "$FAKE/bin/backends/$(basename "$f")"; done
for stub in fm-guard.sh fm-fleet-sync.sh; do
  rm -f "$FAKE/bin/$stub"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/bin/$stub"
  chmod +x "$FAKE/bin/$stub"
done
rm -f "$FAKE/bin/fm-tasks-axi-lib.sh"
printf 'fm_tasks_axi_backend_available() { return 1; }\n' > "$FAKE/bin/fm-tasks-axi-lib.sh"

fleet new-window -d -t "$SES:" -n fm-chain || fail "could not recreate the fleet task window"
fm_write_meta "$FAKE/state/chain.meta" \
  "window=$SES:fm-chain" \
  "worktree=$TMPROOT/no-such-worktree" \
  "project=$TMPROOT/no-such-project" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off" \
  "tmux_socket=$FLEET_SOCK"

out=$(env -u FM_TMUX_SOCKET TMUX="$DECOY_SOCK,999,0" TMUX_TMPDIR="$TMPROOT" \
  FM_HOME="$FAKE" FM_ROOT_OVERRIDE="$FAKE" "$FAKE/bin/fm-teardown.sh" chain 2>&1) \
  || fail "fm-teardown failed: $out"

fleet_windows=$(fleet list-windows -a -F '#{window_name}' 2>&1)
decoy_windows=$(decoy list-windows -a -F '#{window_name}' 2>&1)
assert_not_contains "$fleet_windows" "fm-chain" "teardown must remove the window on the recorded server"
assert_contains "$decoy_windows" "fm-chain" "teardown must NOT touch the ambient server's same-named window"
pass "fm-teardown removes the window on the task's recorded tmux server only"

# --- fm-spawn side: the contract lines that create the sandbox ---------------
#
# Structural, like tests/fm-gotmp.test.sh's spawn-side checks: a real spawn needs
# a treehouse pool and a live harness, so what is asserted here is that fm-spawn
# still creates the sandbox directory, sends the sandbox environment into the
# pane, records the socket, and hands the socket to a secondmate.
SPAWN="$ROOT/bin/fm-spawn.sh"
# shellcheck disable=SC2016  # literal source strings
grep -F 'mkdir -p "$TASK_TMP/gotmp" "$TASK_TMP/tmux"' "$SPAWN" >/dev/null \
  || fail "fm-spawn no longer creates the per-task tmux sandbox directory"
# shellcheck disable=SC2016
grep -F 'SANDBOX_ENV=("TMUX_TMPDIR=$TASK_TMP/tmux" "TMUX=")' "$SPAWN" >/dev/null \
  || fail "fm-spawn no longer gives the pane its private tmux namespace at creation"
# shellcheck disable=SC2016
grep -F 'fm_backend_tmux_create_task "$SES" "$W" "$PROJ_ABS" "${SANDBOX_ENV[@]}"' "$SPAWN" >/dev/null \
  || fail "fm-spawn no longer passes the sandbox environment into window creation"
# The old-tmux fallback must be decided by asking the adapter, never by a
# variable set inside a command substitution (which cannot survive the subshell).
grep -F 'if [ "$BACKEND" = tmux ] && ! fm_backend_tmux_pane_env_supported; then' "$SPAWN" >/dev/null \
  || fail "fm-spawn no longer gates its typed fallback on the adapter's capability check"
grep -F 'FM_BACKEND_TMUX_PANE_ENV_APPLIED' "$SPAWN" "$ROOT/bin/backends/tmux.sh" >/dev/null \
  && fail "a create-task-set applied flag cannot escape the command substitution; use the capability check"
# shellcheck disable=SC2016
grep -F 'echo "tmux_socket=$(fm_tmux_socket)"' "$SPAWN" >/dev/null \
  || fail "fm-spawn no longer records tmux_socket= in the task meta"
# shellcheck disable=SC2016
grep -F 'SANDBOX_ENV+=("FM_TMUX_SOCKET=$(fm_tmux_socket)")' "$SPAWN" >/dev/null \
  || fail "fm-spawn no longer hands the fleet socket to a secondmate pane"
grep -F 'TMUX_PANE' "$SPAWN" >/dev/null \
  || fail "fm-spawn must still document why \$TMUX_PANE is left in place"
pass "fm-spawn keeps the pane-sandbox and socket-recording contract"

# --- the pane namespace is applied at window creation ------------------------

env_probe=$(env FM_TMUX_SOCKET="$FLEET_SOCK" bash -c '
  set -u
  . "$1/bin/fm-backend.sh"
  fm_backend_source tmux
  fm_backend_tmux_pane_env_supported && printf yes || printf no
' _ "$ROOT")
[ "$env_probe" = yes ] \
  || fail "this tmux ($( "$REAL_TMUX" -V )) was expected to support new-window -e; the rest of this section assumes it"
pass "installed tmux supports creation-time pane environment"

env FM_TMUX_SOCKET="$FLEET_SOCK" bash -c '
  set -u
  . "$1/bin/fm-backend.sh"
  fm_backend_source tmux
  fm_backend_tmux_create_task fleet fm-created "$2" "TMUX_TMPDIR=$3" "TMUX=" >/dev/null
' _ "$ROOT" "$TMPROOT" "$SANDBOX" || fail "adapter could not create the sandboxed window"
CREATED_OUT="$TMPROOT/created.out"
fleet send-keys -t fleet:fm-created "printf 'created=%s|%s\n' \"\$TMUX_TMPDIR\" \"\${TMUX:-empty}\" > '$CREATED_OUT'" Enter
wait_for_file "$CREATED_OUT" 15 || fail "the created pane never answered"
assert_grep "created=$SANDBOX|empty" "$CREATED_OUT" \
  "a window created through the adapter must come up already sandboxed"
pass "fm_backend_tmux_create_task applies the pane namespace at creation"
