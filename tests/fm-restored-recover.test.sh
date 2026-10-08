#!/usr/bin/env bash
# tests/fm-restored-recover.test.sh - portable regression for recovering a
# worker that a machine restart brought back in the wrong state
# (bin/fm-restored-recover.sh), and for the control-plane stop it relies on
# (bin/fm-control.sh exit on an agent parked on a startup gate).
#
# It runs REAL processes in a REAL tmux server on a private socket (`-L`) and
# needs no harness and no credentials. The "agent" is fm_agent_standin's
# long-running native process under the name `claude`, so the recovery-grade
# classifier attributes it exactly as it does a real Claude Code process; the
# startup gate is the viewport Claude Code 2.1.293 draws, printed by the
# wrapper that then runs the stand-in. The wrapper falls back to a shell when
# the stand-in dies, which is what a restored Herdr or tmux pane does too.
# The real-harness counterpart is tests/fm-restored-recover-live-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-restored-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-restored.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SESSION=fmses
RECOVER="$ROOT/bin/fm-restored-recover.sh"
CONTROL="$ROOT/bin/fm-control.sh"

# A relaunch writes per-task runtime directories under /tmp keyed by task id,
# so the relaunched task's id is unique to this run and its directories are
# removed with the lab.
OK_ID="ok-$$"
cleanup_all() {
  local d
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && fm_test_remove_tree "$LAB"
  for d in "/tmp/fm-$OK_ID" "/tmp/fm-$OK_ID+"*; do
    [ -e "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap cleanup_all EXIT

# A `tmux` shim on PATH so every bare `tmux` call reaches the private socket
# and never touches the host's real sessions. While $LAB/inventory-broken
# exists, its window inventory fails the way a server mid-restart answers, which
# the classifier reads as `unreadable`.
mkdir -p "$LAB/shim" "$LAB/bin" "$LAB/user-home"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = list-windows ] && [ -e "$LAB/inventory-broken" ]; then
  echo 'lost server' >&2
  exit 1
fi
exec "$REAL_TMUX" -u -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"

STANDIN_BIN=$(fm_agent_standin "$LAB/standin") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}
ln -s "$STANDIN_BIN" "$LAB/bin/claude"

# The external CLAUDE.md imports gate exactly as Claude Code 2.1.293 rendered
# it on a restored pane (docs/verification/runtime-backends.md "Claude startup
# gates").
cat > "$LAB/imports-gate.txt" <<'EOF'
────────────────────────────────────────────────────────────────────────────────
  Allow external CLAUDE.md file imports?

  This project's CLAUDE.md or .claude/rules imports files outside the current working directory. Never allow this for
  third-party repositories.

  External imports:
    /tmp/outside.md

  Important: Only use Claude Code with files you trust. Accessing untrusted files may pose security risks
  https://code.claude.com/docs/en/security

  ❯ No, disable external imports
    Yes, allow external imports

  Enter to confirm · Esc to cancel
EOF

# An ordinary Claude Code composer, so a healthy agent's viewport is not empty.
cat > "$LAB/composer.txt" <<'EOF'
────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)
EOF

# The pane wrapper: draw <screen>, run the stand-in agent, and fall back to an
# interactive-looking shell once the agent is gone.
cat > "$LAB/agent-pane.sh" <<SH
#!/bin/sh
clear
cat "\$1"
"$LAB/bin/claude" 600 </dev/null
exec /bin/sh
SH
chmod +x "$LAB/agent-pane.sh"

# The same pane, but with an agent that ignores SIGTERM (an ignored signal
# stays ignored across exec), so stopping it takes fm-control's full TERM wait
# before KILL: a worker whose recovery is slow.
cat > "$LAB/stubborn-pane.sh" <<SH
#!/bin/sh
clear
cat "\$1"
trap '' TERM
"$LAB/bin/claude" 600 </dev/null
exec /bin/sh
SH
chmod +x "$LAB/stubborn-pane.sh"

# A gate whose TERM tears it down without stopping the agent: a second agent
# process that does die on TERM clears the screen when it goes, while the
# foreground agent ignores TERM and so outlives it until KILL.
cat > "$LAB/fading-gate-pane.sh" <<SH
#!/bin/sh
clear
cat "\$1"
( "$LAB/bin/claude" 600 </dev/null; clear ) &
trap '' TERM
"$LAB/bin/claude" 600 </dev/null
exec /bin/sh
SH
chmod +x "$LAB/fading-gate-pane.sh"

# An agent in its worktree that is busy running a command in another
# directory: the agent starts in the pane's directory, and the pane's
# foreground process then moves to the task's primary checkout, which is where
# the endpoint's own path reads.
cat > "$LAB/busy-pane.sh" <<SH
#!/bin/sh
clear
cat "\$1"
"$LAB/bin/claude" 600 </dev/null &
cd "$LAB/busy/proj" || exit 1
exec sleep 600
SH
chmod +x "$LAB/busy-pane.sh"

"$REAL_TMUX" -u -L "$SOCKET" new-session -d -s "$SESSION" -n idle -x 200 -y 50 -c "$LAB" -- /bin/sh \
  || fail "could not start the private tmux server"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"
# The stand-in is on PATH too: a pane's shell inherits the PATH of the tmux
# client that created it, and a relaunch types a bare `claude` into that
# reused shell, so without it a host with Claude Code installed would run the
# real one there.
PATH="$LAB/shim:$LAB/bin:$PATH"
export PATH

wait_for_state() {  # <target> <expected>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(fm_backend_agent_state tmux "$1")" = "$2" ] && return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

wait_for_screen() {  # <target> <text>
  local i=0
  while [ "$i" -lt 100 ]; do
    case "$(tmux capture-pane -p -t "$1" 2>/dev/null)" in *"$2"*) return 0 ;; esac
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

# new_task <id> <cwd> <screen-file> [extra meta lines...]: a ship task whose
# recorded worktree is $LAB/<id>/wt, with its agent pane started in <cwd>
# (proj, wt, or a path under wt).
# An empty <screen-file> starts a pane with no agent at all.
new_task() {  # <id> <cwd> <screen-file> [meta...]
  local id=$1 cwd=$2 screen=$3 home="$LAB/home"
  shift 3
  mkdir -p "$home/state" "$home/data/$id"
  [ -d "$LAB/$id/wt" ] || fm_git_worktree "$LAB/$id/proj" "$LAB/$id/wt" "task-$id" \
    || fail "could not build $id's worktree"
  printf '# Task\n## Captain'"'"'s intent\nRecover %s.\n\n## Firstmate spec\nContinue.\n' "$id" \
    > "$home/data/$id/brief.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=$SESSION:fm-$id" "endpoint_task_id=$id" "worktree=$LAB/$id/wt" \
    "project=$LAB/$id/proj" harness=claude kind=ship mode=no-mistakes yolo=off \
    "tasktmp=$LAB/$id/tmp" model=default effort=default backend=tmux "$@"
  case "$cwd" in
    proj|wt|wt/*) cwd="$LAB/$id/$cwd"; mkdir -p "$cwd" ;;
  esac
  if [ -n "$screen" ]; then
    tmux new-window -d -t "$SESSION:" -n "fm-$id" -c "$cwd" -- "${PANE_WRAPPER:-$LAB/agent-pane.sh}" "$screen" \
      || fail "could not create $id's window"
    wait_for_state "$SESSION:fm-$id" alive || fail "$id's stand-in agent never read alive"
    wait_for_screen "$SESSION:fm-$id" "$(sed -n 2p "$screen" | sed 's/^ *//')" \
      || fail "$id's pane never drew its screen"
  else
    tmux new-window -d -t "$SESSION:" -n "fm-$id" -c "$cwd" -- /bin/sh \
      || fail "could not create $id's window"
  fi
}

run_recover() {  # [args...]
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
    FM_RESTORED_RECOVER_RECHECK=0.2 \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=3 FM_CONTROL_LAUNCH_WAIT=0.5 \
    "$RECOVER" "$@" 2>&1
}

run_control() {  # <args...>
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=3 \
    "$CONTROL" "$@" 2>&1
}

# --- detection -----------------------------------------------------------
#
# Every shape a restore can leave, in one home, read once: a gate-parked agent
# inside its worktree, a healthy agent in the primary checkout, a healthy
# agent in its worktree and in a subdirectory of it, a shell-only pane outside
# it, and a remote secondmate that names a local endpoint.
new_task gate wt "$LAB/imports-gate.txt"
new_task drift proj "$LAB/composer.txt"
new_task healthy wt "$LAB/composer.txt"
new_task sub wt/pkg "$LAB/composer.txt"
new_task husk proj ""
new_task remote proj "$LAB/imports-gate.txt" remote_host=example.invalid
PANE_WRAPPER="$LAB/busy-pane.sh" new_task busy wt "$LAB/composer.txt"

[ "$(fm_backend_agent_state tmux "$SESSION:fm-husk")" = dead ] \
  || fail "the shell-only pane does not read dead, so the husk case below proves nothing"

OUT=$(run_recover --dry-run) || fail "the dry run exited nonzero: $OUT"
EXPECTED="RESTORED_WORKER: drift: was running in $LAB/drift/proj instead of its recorded worktree; not relaunched (dry run)
RESTORED_WORKER: gate: was parked on the Claude external CLAUDE.md imports prompt; not relaunched (dry run)"
EXPECTED=$(printf '%s\n' "$EXPECTED" | sort)
[ "$(printf '%s\n' "$OUT" | sort)" = "$EXPECTED" ] || fail "the dry run should name exactly the gate-parked and drifted workers, got:
$OUT"
pass "a restored worker is flagged when parked on a startup gate or running outside its worktree, and no other shape is"

[ "$(fm_backend_agent_state tmux "$SESSION:fm-gate")" = alive ] \
  || fail "a dry run must not stop anything"

[ "$(cd "$(tmux display-message -p -t "$SESSION:fm-busy" '#{pane_current_path}')" && pwd -P)" = "$LAB/busy/proj" ] \
  || fail "the busy pane's foreground does not read outside the worktree, so the busy case proves nothing"
OUT=$(run_recover --dry-run) || fail "the dry run exited nonzero: $OUT"
case "$OUT" in
  *busy*) fail "an agent in its worktree running a command elsewhere was flagged: $OUT" ;;
esac
[ "$(fm_backend_agent_state tmux "$SESSION:fm-busy")" = alive ] \
  || fail "the sweep stopped an agent that was running a command outside its worktree"
tmux kill-window -t "$SESSION:fm-busy"
pass "an agent in its worktree that runs a command in another directory is not flagged or relaunched"

# --- fm-control exit on a gate-parked agent ------------------------------
#
# The composer reads the gate as text the operator has not submitted, which is
# why exit used to refuse and leave relaunch stuck. It now stops the process
# without typing anything into the gate: the stand-in reads nothing, so any
# key fm-control sent would surface in the shell that takes over the pane.
OUT=$(run_control gate exit) || fail "exit on a gate-parked agent should succeed: $OUT"
case "$OUT" in
  *stopped-at-startup-gate*) : ;;
  *) fail "exit on a gate-parked agent should report stopped-at-startup-gate, got: $OUT" ;;
esac
[ "$(fm_backend_agent_state tmux "$SESSION:fm-gate")" = dead ] \
  || fail "the gate-parked agent is still running after exit"
sleep 0.5
case "$(tmux capture-pane -p -t "$SESSION:fm-gate")" in
  *'/exit'*) fail "exit typed the harness exit command into a startup gate" ;;
esac
pass "fm-control exit stops an agent parked on a startup gate without answering it"

OUT=$(run_control gate exit) || fail "a second exit should be idempotent: $OUT"
case "$OUT" in
  "already-stopped gate"*) : ;;
  *) fail "a second exit should report already-stopped, got: $OUT" ;;
esac
pass "fm-control exit stays idempotent once the gate-parked agent is gone"

PANE_WRAPPER="$LAB/fading-gate-pane.sh" new_task fading wt "$LAB/imports-gate.txt"
OUT=$(run_control fading exit) || fail "exit should KILL an agent whose TERM closed its gate but did not stop it: $OUT"
case "$OUT" in
  *stopped-at-startup-gate*) : ;;
  *) fail "exit on a gate TERM closed should report stopped-at-startup-gate, got: $OUT" ;;
esac
[ "$(fm_backend_agent_state tmux "$SESSION:fm-fading")" = dead ] \
  || fail "the agent whose gate TERM closed is still running after exit"
tmux kill-window -t "$SESSION:fm-fading"
pass "fm-control exit sends KILL to a gate-parked agent that TERM did not stop, even once the gate is gone"

# --- recovery outcome ----------------------------------------------------
#
# Neither a drifted tmux endpoint nor a relaunch that cannot complete may cost
# the worker its running agent or its work. A tmux relaunch never moves an
# endpoint back into its worktree, so a drifted one is reported rather than
# stopped. A gate-parked worker whose instructions are gone is relaunched, and
# the relaunch refuses before it stops anything; the sweep reports that as one
# actionable line naming the cause and the relaunch's own error.
tmux kill-window -t "$SESSION:fm-gate"
tmux kill-window -t "$SESSION:fm-remote"
new_task nobrief wt "$LAB/imports-gate.txt"
rm -f "$LAB/home/data/nobrief/brief.md"
printf 'unlanded\n' > "$LAB/nobrief/wt/work-in-progress.txt"
OUT=$(run_recover) || fail "the sweep exited nonzero: $OUT"
EXPECTED="RESTORED_WORKER: drift: was running in $LAB/drift/proj instead of its recorded worktree; not relaunched: a tmux relaunch cannot move its endpoint back into $LAB/drift/wt
RESTORED_WORKER: nobrief: was parked on the Claude external CLAUDE.md imports prompt; relaunch failed: task nobrief has no instructions at $LAB/home/data/nobrief/brief.md; refusing to relaunch a worker with nothing to work from"
EXPECTED=$(printf '%s\n' "$EXPECTED" | sort)
[ "$(printf '%s\n' "$OUT" | sort)" = "$EXPECTED" ] || fail "the sweep should report the drifted tmux worker and the failed relaunch, got:
$OUT"
for id in drift nobrief; do
  [ "$(fm_backend_agent_state tmux "$SESSION:fm-$id")" = alive ] \
    || fail "the sweep stopped $id's agent without relaunching it"
done
[ -f "$LAB/nobrief/wt/work-in-progress.txt" ] \
  || fail "the worktree's uncommitted work is gone"
pass "a worker the sweep cannot relaunch is reported with its cause and keeps its agent and its work"

# A gate-parked worker in its worktree is stopped without answering the gate
# and relaunched in place through the ordinary relaunch, with the cause
# explained in the instructions the replacement reads.
new_task "$OK_ID" wt "$LAB/imports-gate.txt"
OK_PANE=$(tmux display-message -p -t "$SESSION:fm-$OK_ID" '#{pane_id}')
OUT=$(PATH="$LAB/bin:$PATH" run_recover) || fail "the sweep exited nonzero: $OUT"
case "$OUT" in
  *"BOOTSTRAP_INFO: worker $OK_ID was parked on the Claude external CLAUDE.md imports prompt; relaunched in its recorded worktree $LAB/$OK_ID/wt"*) : ;;
  *) fail "a gate-parked worker should be relaunched and reported as a fact, got:
$OUT" ;;
esac
grep -Fqx 'exit_result=stopped-at-startup-gate' "$LAB/home/state/$OK_ID.control-relaunch" \
  || fail "the relaunch did not stop the old agent through the startup-gate path"
grep -Fq 'Your terminal was found with your previous session parked on the Claude external CLAUDE.md imports prompt' "$LAB/home/data/$OK_ID/brief.md" \
  || fail "the replacement's instructions do not explain why it was relaunched"
wait_for_state "$SESSION:fm-$OK_ID" alive || fail "the relaunched agent is not running"
[ "$(tmux display-message -p -t "$SESSION:fm-$OK_ID" '#{pane_id}')" = "$OK_PANE" ] \
  || fail "the relaunch replaced the endpoint instead of reusing it"
[ "$(cd "$(tmux display-message -p -t "$SESSION:fm-$OK_ID" '#{pane_current_path}')" && pwd -P)" = "$LAB/$OK_ID/wt" ] \
  || fail "the relaunched agent is not running in its recorded worktree"
OUT=$(PATH="$LAB/bin:$PATH" run_recover --dry-run)
case "$OUT" in
  *"$OK_ID"*) fail "a relaunched worker is flagged again: $OUT" ;;
esac
pass "a gate-parked worker is relaunched in its worktree with the cause explained, and is healthy afterwards"

# --- an endpoint that is not readable yet --------------------------------
#
# Right after a resume Herdr reports the agent as unknown for a moment, and
# after a reboot the primary resumes together with its workers. The sweep keeps
# re-reading an unreadable endpoint for its settle window and goes on once it
# reads definitely; one that never does is reported rather than passed over.
new_task settle wt "$LAB/imports-gate.txt"
: > "$LAB/inventory-broken"
[ "$(fm_backend_agent_state tmux "$SESSION:fm-settle")" = unreadable ] \
  || fail "the broken inventory does not read unreadable, so the settle cases prove nothing"
FM_RESTORED_RECOVER_SETTLE=20 FM_RESTORED_RECOVER_SETTLE_POLL=0.3 run_recover --dry-run > "$LAB/settle.out" &
SETTLE_PID=$!
sleep 1.5
rm -f "$LAB/inventory-broken"
wait "$SETTLE_PID"
grep -Fqx "RESTORED_WORKER: settle: was parked on the Claude external CLAUDE.md imports prompt; not relaunched (dry run)" "$LAB/settle.out" \
  || fail "a gate-parked worker that became readable inside the settle window was not flagged; got:
$(cat "$LAB/settle.out")"
pass "an endpoint that turns readable inside the settle window is still checked"

: > "$LAB/inventory-broken"
OUT=$(FM_RESTORED_RECOVER_SETTLE=1 FM_RESTORED_RECOVER_SETTLE_POLL=0.3 run_recover --dry-run)
rm -f "$LAB/inventory-broken"
case "$OUT" in
  *"RESTORED_WORKER: settle: its endpoint stayed unreadable for 1s, so it was not checked"*) : ;;
  *) fail "an endpoint that never became readable should be reported, got:
$OUT" ;;
esac
pass "an endpoint that stays unreadable past the settle window is reported as not checked"

# --- the detached, separately bounded job ------------------------------
#
# Bootstrap starts the sweep with --background from inside the deferred startup
# stage, whose deadline kills its whole process group. The job must outlive
# that group, run under its own bound, publish each worker's line as soon as it
# is settled, and raise a wake for anything actionable. The launcher here runs
# in its own process group and is killed the moment --background returns. One
# worker is reported quickly (a drifted tmux endpoint); the other ignores TERM,
# so its stop outlasts the job's 3s bound.
for w in $(tmux list-windows -t "$SESSION" -F '#{window_name}'); do
  [ "$w" = idle ] || tmux kill-window -t "$SESSION:$w"
done
rm -f "$LAB/home/state/"*.meta "$LAB/home/state/.wake-queue"
new_task quick proj "$LAB/composer.txt"
PANE_WRAPPER="$LAB/stubborn-pane.sh" new_task slow wt "$LAB/imports-gate.txt"
results_files() {
  ls -1t "$LAB/home/state/.restored-recover.results."* 2>/dev/null
}
SWEEP_LOCK="$LAB/home/state/.restored-recover.lock"
set -m
(
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
    FM_RESTORED_RECOVER_RECHECK=0.2 FM_RESTORED_RECOVER_TIMEOUT=3 \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=10 \
    "$RECOVER" --background
  : > "$LAB/launched"
  sleep 60
) &
LAUNCHER=$!
set +m
i=0
while [ ! -e "$LAB/launched" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ -e "$LAB/launched" ] || fail "--background did not return promptly"
kill -KILL -- "-$LAUNCHER" 2>/dev/null || fail "could not kill the launcher's process group"
wait "$LAUNCHER" 2>/dev/null

i=0
RESULTS=
while ! grep -q '^RESTORED_WORKER: quick: ' "$RESULTS" 2>/dev/null && [ "$i" -lt 50 ]; do
  sleep 0.1
  i=$((i + 1))
  RESULTS=$(results_files | sed -n 1p)
done
grep -Fqx "RESTORED_WORKER: quick: was running in $LAB/quick/proj instead of its recorded worktree; not relaunched: a tmux relaunch cannot move its endpoint back into $LAB/quick/wt" "$RESULTS" \
  || fail "the quick worker's line was never published; results:
$(cat "$RESULTS" 2>/dev/null)"
[ -e "$SWEEP_LOCK" ] || fail "the job had already finished when the quick worker's line appeared, so this proves nothing about publishing early"
grep -q '^RESTORED_WORKER: slow: ' "$RESULTS" && fail "the slow worker settled before the job's bound, so the bound below proves nothing"
pass "the detached job outlives its launcher's process group and publishes each worker's line before the sweep finishes"

i=0
while [ -e "$SWEEP_LOCK" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
[ ! -e "$SWEEP_LOCK" ] || fail "the job outlived its own bound"
grep -Fqx "RESTORED_WORKER: sweep: stopped by its 3s bound (FM_RESTORED_RECOVER_TIMEOUT); a worker with no line above was not confirmed recovered" "$RESULTS" \
  || fail "the expired bound was not recorded; results:
$(cat "$RESULTS")"
[ "$(grep -c 'check: restored-workers' "$LAB/home/state/.wake-queue" 2>/dev/null)" = 1 ] \
  || fail "actionable results should enqueue exactly one restored-workers wake; queue:
$(cat "$LAB/home/state/.wake-queue" 2>/dev/null)"
pass "the job honors its own bound, records that it expired, and raises one wake for actionable results"

# A later job writes its own results file and never rewrites the one an
# earlier wake names, and only the newest five results files are kept.
FIRST_RESULTS=$RESULTS
tmux kill-window -t "$SESSION:fm-slow"
rm -f "$LAB/home/state/slow.meta"
run_job() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
    FM_RESTORED_RECOVER_RECHECK=0.2 "$RECOVER" --job
}
run_job || fail "a second job exited nonzero"
SECOND_RESULTS=$(results_files | sed -n 1p)
[ "$SECOND_RESULTS" != "$FIRST_RESULTS" ] || fail "the second job reused the first job's results file"
grep -Fq 'RESTORED_WORKER: sweep: stopped by its 3s bound' "$FIRST_RESULTS" \
  || fail "the second job rewrote the results file the first wake names:
$(cat "$FIRST_RESULTS" 2>/dev/null)"
grep -q '^RESTORED_WORKER: quick: ' "$SECOND_RESULTS" \
  || fail "the second job's results file lacks its own line:
$(cat "$SECOND_RESULTS" 2>/dev/null)"
tail -n 1 "$LAB/home/state/.wake-queue" | grep -Fq "read $SECOND_RESULTS" \
  || fail "the second job's wake does not name its own results file; queue:
$(cat "$LAB/home/state/.wake-queue")"
for i in 1 2 3 4 5; do run_job || fail "job $i exited nonzero"; done
[ "$(results_files | wc -l | tr -d ' ')" = 5 ] \
  || fail "only the newest five results files should be kept, found:
$(results_files)"
[ ! -e "$FIRST_RESULTS" ] || fail "the oldest results file was not pruned"
pass "each job publishes to its own results file, named in its wake, and old results files are pruned"

OUT=$(env -u FM_HOME "$RECOVER" 2>&1) && fail "the sweep must refuse without an explicit home: $OUT"
pass "the sweep refuses without an explicit home"
