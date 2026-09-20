#!/usr/bin/env bash
# tests/fm-control-stop.test.sh - the NON-TYPING stop path (bin/fm-control.sh
# `stop`) against REAL processes on a REAL private tmux server.
#
# `exit` types the harness's exit command, so it must refuse whenever the
# composer is not proven empty. A worker whose screen cannot be classified is
# then unreachable by every verb, which is how a wedged agent stays pinned to
# the fleet: unresponsive, unstoppable, costing a supervision turn every few
# minutes. `stop` signals the agent PROCESS instead, so nothing is typed and
# nothing can concatenate - and what replaces the composer guard is a proof of
# process identity. That proof is what this suite pins.
#
# Real processes, no harness: a stand-in executable named for a verified
# harness is what the backend's own foreground classifier calls an agent, so
# these cases exercise the real resolution, the real signal, and the real
# postconditions without launching a vendor CLI or spending a token. The pane
# is a shell with the process as its foreground job, which is exactly how
# bin/backends/tmux.sh creates a task window (no command, launch typed in).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-stop-$$"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-stop.XXXXXX")

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  [ -z "${WORK:-}" ] || rm -rf "$WORK"
}
trap cleanup EXIT

SHIM="$WORK/shim"
mkdir -p "$SHIM" "$WORK/home/state" "$WORK/home/data/t1" "$WORK/bin"
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

# The stand-in agent: a REAL binary, copied rather than scripted so its process
# name is genuinely `opencode` - the backend's foreground classifier reads the
# process name, and a shell script would present as its interpreter and be
# classified (correctly) as a shell. `sleep` is the whole behaviour needed: run
# until signalled, and die on SIGTERM as any ordinary process does.
SLEEP_BIN=$(command -v sleep) || { echo "skip: sleep not found"; exit 0; }
cp "$SLEEP_BIN" "$WORK/bin/opencode" || { echo "skip: cannot stage a stand-in agent"; exit 0; }
chmod +x "$WORK/bin/opencode"

fm_git_worktree "$WORK/proj" "$WORK/wt" stop-branch
printf 'uncommitted\n' > "$WORK/wt/dirty.txt"

write_meta() {  # <worktree>
  {
    echo "window=fmses:fm-t1"
    echo "endpoint_task_id=t1"
    echo "worktree=$1"
    echo "project=$WORK/proj"
    echo "harness=opencode"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$WORK/home/state/t1.meta"
}
write_meta "$WORK/wt"
printf '# brief\n' > "$WORK/home/data/t1/brief.md"

run_stop() { env PATH="$SHIM:$PATH" FM_HOME="$WORK/home" bash "$ROOT/bin/fm-control.sh" t1 stop 2>&1; }

start_agent() {  # <cwd> [shell-command to run once the agent exits]
  "$REAL_TMUX" -L "$SOCKET" kill-window -t fmses:fm-t1 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t fmses: -n fm-t1 -c "$1" >/dev/null
  "$REAL_TMUX" -L "$SOCKET" send-keys -t fmses:fm-t1 "PATH=$WORK/bin:\$PATH opencode 600${2:+; $2}" Enter
  # Wait until the pane's FOREGROUND is the stand-in rather than the shell that
  # is about to launch it; the resolver reports whichever is in front, and it is
  # the caller's not-a-shell proof that tells them apart.
  local i=0 pid shell_pid
  shell_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t fmses:fm-t1 '#{pane_pid}')
  while [ "$i" -lt 150 ]; do
    pid=$(agent_pid 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      "$shell_pid") ;;
      *) return 0 ;;
    esac
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

agent_pid() {
  # shellcheck disable=SC2016 # The $1 expansions belong to the inner bash -c, which receives $ROOT as its own positional.
  env PATH="$SHIM:$PATH" bash -c '
    . "$1/bin/fm-backend.sh"; . "$1/bin/fm-tmux-lib.sh"
    fm_tmux_agent_process fmses:fm-t1' _ "$ROOT"
}

"$REAL_TMUX" -L "$SOCKET" new-session -d -s fmses -x 120 -y 40 -c "$WORK/wt"

# --- 1. the resolved pid is the AGENT, never the pane's own shell -----------
start_agent "$WORK/wt" || fail "stand-in agent never reached the pane's foreground"
PID=$(agent_pid) || fail "the agent process could not be resolved from a real pane"
SHELL_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t fmses:fm-t1 '#{pane_pid}')
[ "$PID" != "$SHELL_PID" ] || fail "resolution returned the pane's shell ($SHELL_PID), not its agent"
pass "fm-control stop: the resolved pid is the pane's foreground agent, not its shell"

# --- 2. THE GUARD. A process outside the task's worktree is never signalled --
# The worktree binding is what ties a pid to THIS task; without it `stop` would
# be signalling whatever happened to be in a pane.
write_meta "$WORK/elsewhere"
mkdir -p "$WORK/elsewhere"
out=$(run_stop) && fail "stop must refuse an agent working outside the recorded worktree, got: $out"
case "$out" in
  *"not the task's recorded worktree"*) ;;
  *) fail "stop's worktree refusal must name the mismatch, got: $out" ;;
esac
kill -0 "$PID" 2>/dev/null || fail "stop signalled a process it had just refused to claim"
pass "fm-control stop: an agent outside the recorded worktree refuses and is left running"
write_meta "$WORK/wt"

# --- 3. the stop itself, with every postcondition proven --------------------
HEAD_BEFORE=$(git -C "$WORK/wt" rev-parse HEAD)
out=$(run_stop) || fail "stop failed against a real agent: $out"
case "$out" in
  "stopped pid=$PID "*) ;;
  *) fail "stop must report the exact pid it signalled, got: $out" ;;
esac
case "$out" in *"endpoint-state=preserved"*) ;; *) fail "stop must report the endpoint preserved, got: $out" ;; esac
# The result line is written for a firstmate agent to read, so each key on it
# has to mean one thing. The verb's own OUTCOMES are endpoint-state=/
# worktree-state=; the shared trailing pair carries the endpoint ADDRESS and the
# worktree PATH, and a supervisor needs both.
[ "$(printf '%s' "$out" | grep -o 'endpoint=' | grep -c '')" = 1 ] \
  || fail "the result line must carry exactly one endpoint= (the address), got: $out"
[ "$(printf '%s' "$out" | grep -o 'worktree=' | grep -c '')" = 1 ] \
  || fail "the result line must carry exactly one worktree= (the path), got: $out"
case "$out" in
  *"endpoint=fmses:fm-t1"*) ;;
  *) fail "the result line must still carry the endpoint address, got: $out" ;;
esac
case "$out" in
  *"worktree=$WORK/wt"*) ;;
  *) fail "the result line must still carry the worktree path, got: $out" ;;
esac
i=0
while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
! kill -0 "$PID" 2>/dev/null || fail "the agent process survived a reported stop"
"$REAL_TMUX" -L "$SOCKET" list-windows -t fmses -F '#{window_name}' | grep -qx fm-t1 \
  || fail "stop destroyed the endpoint it promised to preserve"
kill -0 "$SHELL_PID" 2>/dev/null || fail "stop killed the pane's shell, not just its agent"
[ "$(git -C "$WORK/wt" rev-parse HEAD)" = "$HEAD_BEFORE" ] || fail "stop moved the worktree's HEAD"
[ "$(cat "$WORK/wt/dirty.txt")" = uncommitted ] || fail "stop did not preserve uncommitted work"
pass "fm-control stop: the agent stops while its endpoint, shell, and uncommitted work survive"

# --- 4. idempotent: a pane holding only its shell is already stopped --------
out=$(run_stop) || fail "stop on an already-stopped task must succeed, got: $out"
case "$out" in
  already-stopped*) ;;
  *) fail "stop must be idempotent on an already-stopped task, got: $out" ;;
esac
kill -0 "$SHELL_PID" 2>/dev/null || fail "an already-stopped stop killed the pane's shell"
pass "fm-control stop: an already-stopped task is idempotent and never signals the shell"

# --- 4a. AN AGENT THAT EXITED ON ITS OWN still leaves a task pinging busy ---
# This is the likeliest real path into the state the verb exists to clear: a
# worker wedged at authentication exhausts its retries and exits before anyone
# gets to it. fm_busy_classify reads the busy RECORD and never consults
# liveness, so the task keeps classifying `busy` with nothing behind it. A
# `stop` that reports `already-stopped` and touches nothing leaves it costing a
# supervision turn every few minutes, and calls that success.
bash "$ROOT/bin/fm-busy-event.sh" arm "$WORK/home/state" t1 >/dev/null 2>&1 \
  || fail "could not arm a busy incarnation for the already-stopped case"
[ -f "$WORK/home/state/t1.busy-state" ] || fail "arming did not write a busy record"
[ -f "$WORK/home/state/t1.busy-gen" ] || fail "arming did not write a busy generation"
out=$(run_stop) || fail "stop on an already-stopped task must succeed, got: $out"
case "$out" in
  already-stopped*) ;;
  *) fail "stop must report already-stopped for an agent that exited on its own, got: $out" ;;
esac
[ ! -e "$WORK/home/state/t1.busy-state" ] \
  || fail "an already-stopped stop left the task recorded busy with no agent behind it"
[ ! -e "$WORK/home/state/t1.busy-gen" ] \
  || fail "an already-stopped stop left an orphaned busy generation"
kill -0 "$SHELL_PID" 2>/dev/null || fail "the already-stopped busy case killed the pane's shell"
pass "fm-control stop: an agent that exited on its own stops pinging busy, not just reports already-stopped"

# --- 4b. THE CONTENT GATE. A visible draft is never signalled away ----------
# A signal destroys whatever the composer holds, so the stop path is reachable
# only where the classifier positively establishes that nothing was observed.
# Here the pane genuinely shows a left-bar composer holding an unsent draft
# while the stand-in agent runs in front of it: something WAS observed, so the
# only correct outcome is a refusal that leaves both the draft and the process
# exactly where they are.
start_agent_with_draft() {
  "$REAL_TMUX" -L "$SOCKET" kill-window -t fmses:fm-t1 2>/dev/null || true
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t fmses: -n fm-t1 -c "$WORK/wt" >/dev/null
  "$REAL_TMUX" -L "$SOCKET" send-keys -t fmses:fm-t1 \
    "printf '  \\u2503\\n  \\u2503  a draft the human has not sent yet\\n  \\u2503\\n  \\u2503  Build \\u00b7 m p\\n  \\u2579\\u2580\\u2580\\u2580\\u2580\\u2580\\u2580\\u2580\\u2580\\u2580\\u2580\\u2580\\n'" Enter
  sleep 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t fmses:fm-t1 "PATH=$WORK/bin:\$PATH opencode 600" Enter
  local i=0 pid shell_pid
  shell_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t fmses:fm-t1 '#{pane_pid}')
  while [ "$i" -lt 150 ]; do
    pid=$(agent_pid 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      "$shell_pid") ;;
      *) return 0 ;;
    esac
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
start_agent_with_draft || fail "could not stage a pane showing an unsent draft"
DRAFT_PID=$(agent_pid) || fail "the agent process could not be resolved with a draft on screen"
out=$(run_stop) && fail "stop must refuse while the composer shows content, got: $out"
printf '%s\n' "$out" | grep -q 'not established to be free of content' \
  || fail "the refusal must name the content gate, got: $out"
kill -0 "$DRAFT_PID" 2>/dev/null || fail "stop signalled an agent whose composer still held a draft"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t fmses:fm-t1 | grep -q 'a draft the human has not sent yet' \
  || fail "the draft did not survive the refusal"
pass "fm-control stop: an observed draft refuses, and neither the draft nor the agent is touched"

# --- 4c. THE WORKTREE POSTCONDITION discriminates ONE destroyed dirty file --
# `stop` reports `worktree-state=entries-preserved`, so that claim has to be able to FAIL for
# the smallest real loss there is: the single uncommitted file a shutting-down
# harness discards. A dirty-entry count that cannot tell 0 from 1 reports that
# loss as unchanged, which is a wrong label emitted without erroring.
[ -e "$WORK/wt/dirty.txt" ] || printf 'uncommitted\n' > "$WORK/wt/dirty.txt"
[ "$(git -C "$WORK/wt" status --porcelain | grep -c '')" = 1 ] \
  || fail "this case needs the worktree to hold exactly one dirty entry"
# The pane discards that file the moment its agent dies, then holds a SECOND
# short-lived agent, so the recovery-grade classifier cannot reach `dead` until
# the discard has certainly landed. That orders the race the incident describes
# without changing what is being measured.
start_agent "$WORK/wt" "rm -f '$WORK/wt/dirty.txt'; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that discards uncommitted work as it stops"
out=$(run_stop) && fail "stop must not report a worktree that lost its only dirty file as unchanged, got: $out"
case "$out" in
  *worktree-state=CHANGED*) ;;
  *) fail "stop must report the destroyed dirty file as a changed worktree, got: $out" ;;
esac
[ ! -e "$WORK/wt/dirty.txt" ] || fail "this case never actually discarded the worktree's only dirty file"
pass "fm-control stop: a worktree that loses its single dirty file is reported CHANGED, never preserved"
printf 'uncommitted\n' > "$WORK/wt/dirty.txt"

# --- 4d. THE ENDPOINT POSTCONDITION is established, not sampled -------------
# The fleet's tmux path types the launch line into a shell, so the shell
# outlives the agent and the window really is preserved - every case above
# covers that shape. A pane whose own COMMAND is the agent tears the window
# down after the process exits, and a single read taken the moment the agent
# state settles can still see a window that is already going away. `stop` must
# report the outcome it can establish, not the one it happened to sample first.
start_agent_as_pane_command() {
  "$REAL_TMUX" -L "$SOCKET" kill-window -t fmses:fm-t1 2>/dev/null || true
  # `sh -c` execs into the stand-in, so the pane process IS the agent (same pid,
  # comm `opencode`) and the window closes with it - while the printed line
  # keeps the pane readable, which the content gate requires.
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t fmses: -n fm-t1 -c "$WORK/wt" \
    "sh -c 'printf \"session ready\\n\"; exec opencode 600'" >/dev/null
  local i=0 pid pane_pid comm
  while [ "$i" -lt 150 ]; do
    pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t fmses:fm-t1 '#{pane_pid}' 2>/dev/null || true)
    pid=$(agent_pid 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        comm=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d '[:space:]')
        # The exec has landed only once the pane process itself reports the
        # stand-in's name; before that `sh` is still in front of it.
        [ "$comm" != opencode ] || { [ "$pid" = "$pane_pid" ] && return 0; }
        ;;
    esac
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
PATH="$WORK/bin:$PATH" start_agent_as_pane_command \
  || { echo "skip: could not stage an agent as the pane's own command"; DIRECT_LAUNCH=skip; }
if [ "${DIRECT_LAUNCH:-}" != skip ]; then
  DIRECT_PID=$(agent_pid) || fail "the agent process could not be resolved from a direct-launch pane"
  out=$(run_stop) || fail "stop failed against a direct-launch agent: $out"
  # The window really is gone - but on tmux that cannot be PROVEN, because a
  # task record carries no socket identity and a window absent from the server
  # this seat addresses is indistinguishable from a destroyed one. So the one
  # honest report is that the endpoint's fate could not be established: not the
  # `preserved` a single loose read would have claimed, and not a `gone` the
  # backend has no way to prove.
  case "$out" in
    "stopped-endpoint-unverified pid=$DIRECT_PID "*) ;;
    *) fail "stop must report a tmux endpoint's fate as unestablished, got: $out" ;;
  esac
  case "$out" in
    *endpoint-state=unestablished*) ;;
    *) fail "stop must name the endpoint outcome it established, got: $out" ;;
  esac
  case "$out" in
    *endpoint-state=preserved*) fail "stop claimed a survival it could not establish, got: $out" ;;
    *endpoint-state=did-not-survive*) fail "stop claimed a destruction tmux cannot prove, got: $out" ;;
  esac
  "$REAL_TMUX" -L "$SOCKET" list-windows -t fmses -F '#{window_name}' | grep -qx fm-t1 \
    && fail "the direct-launch window outlived the stop"
  ! kill -0 "$DIRECT_PID" 2>/dev/null || fail "the direct-launch agent survived a reported stop"
  [ "$(cat "$WORK/wt/dirty.txt")" = uncommitted ] || fail "the direct-launch stop lost uncommitted work"
  pass "fm-control stop: a window that WAS the agent reports its fate unestablished, never preserved or proven gone"
fi

# --- 4e. THE WORKTREE POSTCONDITION compares CONTENT, not a summary ---------
# A shutting-down harness that removes one untracked file it owns and writes
# another - a session lock traded for a crash log - leaves the entry count, and
# every other summary derived from the status, exactly as it was. Uncommitted
# work is gone and `worktree-state=entries-preserved` would be claimed over it.
[ -e "$WORK/wt/dirty.txt" ] || printf 'uncommitted\n' > "$WORK/wt/dirty.txt"
rm -f "$WORK/wt/crash.log"
# Enough dirty entries that the refusal would bury its own sentence under two
# full porcelain listings if the fingerprints it quotes were not bounded.
for n in 1 2 3 4 5 6 7; do printf 'noise\n' > "$WORK/wt/noise$n.txt"; done
BEFORE_COUNT=$(git -C "$WORK/wt" status --porcelain | grep -c '')
[ "$BEFORE_COUNT" -gt 6 ] || fail "this case needs more dirty entries than the refusal quotes"
start_agent "$WORK/wt" "rm -f '$WORK/wt/dirty.txt'; : > '$WORK/wt/crash.log'; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that trades one uncommitted file for another"
# The agent is proven stopped before the worktree is ever compared, so the
# incarnation is over whatever that comparison says. A busy record that outlives
# it keeps the task classifying `busy` with no agent behind it - the pings-
# forever state this verb exists to clear.
bash "$ROOT/bin/fm-busy-event.sh" arm "$WORK/home/state" t1 >/dev/null 2>&1 \
  || fail "could not arm a busy incarnation for the failing-postcondition case"
[ -f "$WORK/home/state/t1.busy-state" ] || fail "arming did not write a busy record"
out=$(run_stop) && fail "stop must not report a worktree whose uncommitted contents were traded as unchanged, got: $out"
case "$out" in
  *worktree-state=CHANGED*) ;;
  *) fail "stop must report the traded file as a changed worktree, got: $out" ;;
esac
[ ! -e "$WORK/home/state/t1.busy-state" ] \
  || fail "a stop that reported a changed worktree left the task recorded busy with no agent behind it"
[ ! -e "$WORK/home/state/t1.busy-gen" ] \
  || fail "a stop that reported a changed worktree left an orphaned busy generation"
[ ! -e "$WORK/wt/dirty.txt" ] || fail "this case never actually removed the original uncommitted file"
[ -e "$WORK/wt/crash.log" ] || fail "this case never actually wrote the replacement file"
[ "$(git -C "$WORK/wt" status --porcelain | grep -c '')" = "$BEFORE_COUNT" ] \
  || fail "this case must leave the dirty-entry count identical, or it proves nothing about content"
# The refusal quotes both fingerprints, so each must be bounded rather than
# reprinting the whole listing and pushing the sentence that follows it off the
# end of the line.
case "$out" in
  *'(+'*' more)'*) ;;
  *) fail "the refusal must bound the fingerprints it quotes, got: $out" ;;
esac
case "$out" in
  *"noise7.txt"*) fail "the refusal reprinted the whole porcelain listing, got: $out" ;;
esac
case "$out" in
  *"did not survive"*) ;;
  *) fail "the refusal's own sentence must survive the fingerprints it quotes, got: $out" ;;
esac
pass "fm-control stop: a worktree whose uncommitted contents were traded is CHANGED, though its entry count is not"
rm -f "$WORK/wt/crash.log" "$WORK/wt"/noise*.txt
printf 'uncommitted\n' > "$WORK/wt/dirty.txt"

# --- 4e2. A PURE ADDITION DESTROYS NOTHING, so the stop succeeds ------------
# This verb sends SIGTERM precisely so the harness gets its chance to flush. A
# harness that writes a transcript or a crash file on the way out, or an
# unsignalled child that drops a build artifact, has destroyed nothing - and a
# postcondition that failed on it would turn the verb's own design into a
# reported failed stop.
[ -e "$WORK/wt/dirty.txt" ] || printf 'uncommitted\n' > "$WORK/wt/dirty.txt"
rm -f "$WORK/wt/flushed.log"
start_agent "$WORK/wt" ": > '$WORK/wt/flushed.log'; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that flushes a new file as it stops"
out=$(run_stop) || fail "stop must succeed when the harness only ADDED a file, got: $out"
case "$out" in
  *worktree-state=entries-preserved*) ;;
  *) fail "a pure addition must report the worktree intact, got: $out" ;;
esac
[ -e "$WORK/wt/flushed.log" ] || fail "this case never actually flushed a new file"
[ "$(cat "$WORK/wt/dirty.txt")" = uncommitted ] \
  || fail "the uncommitted work this case was protecting did not survive"
pass "fm-control stop: a file the harness flushed on its way out is not a destroyed worktree"
rm -f "$WORK/wt/flushed.log"

# --- 4e0. WORK INSIDE AN UNTRACKED DIRECTORY is entries, not one summary ----
# Git's default untracked mode collapses a whole untracked directory to a single
# `dir/` entry, so a worker drafting into a not-yet-added `notes/` can lose a
# file inside it and both fingerprints still read `?? notes/`. That is the same
# proxy the postcondition already refuses everywhere else, arriving through the
# porcelain text itself rather than through a count.
rm -f "$WORK/wt/dirty.txt"
mkdir -p "$WORK/wt/notes"
printf 'plan\n' > "$WORK/wt/notes/plan.md"
printf 'draft\n' > "$WORK/wt/notes/draft.md"
[ "$(git -C "$WORK/wt" status --porcelain)" = '?? notes/' ] \
  || fail "this case needs git to collapse the untracked directory, got: $(git -C "$WORK/wt" status --porcelain)"
start_agent "$WORK/wt" "rm -f '$WORK/wt/notes/draft.md'; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that destroys a file inside an untracked directory"
out=$(run_stop) && fail "stop must not report work destroyed inside an untracked directory as intact, got: $out"
case "$out" in
  *worktree-state=CHANGED*) ;;
  *) fail "stop must report the lost draft as a changed worktree, got: $out" ;;
esac
[ ! -e "$WORK/wt/notes/draft.md" ] || fail "this case never actually destroyed the draft"
[ -e "$WORK/wt/notes/plan.md" ] || fail "this case destroyed more than it meant to"
pass "fm-control stop: a file lost inside an untracked directory is CHANGED, not a collapsed summary"
rm -rf "$WORK/wt/notes"
printf 'uncommitted\n' > "$WORK/wt/dirty.txt"

# --- 4e1. AN ALTERED ENTRY is destroyed work too, not a benign write --------
# "Every entry present before must still be present after WITH THE SAME STATUS"
# has two halves, and the cases around this one only pin the first. A tracked
# file the agent had modified, reverted during shutdown, leaves the path present
# and its porcelain status changed - nothing was added or removed, so an
# entry-presence test alone would call that intact.
printf 'edited by the agent\n' >> "$WORK/wt/README.md"
git -C "$WORK/wt" add README.md
[ "$(git -C "$WORK/wt" status --porcelain -- README.md)" = "M  README.md" ] \
  || fail "this case needs README.md staged-modified, got: $(git -C "$WORK/wt" status --porcelain -- README.md)"
start_agent "$WORK/wt" "git -C '$WORK/wt' reset -q -- README.md; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that alters an entry's status as it stops"
out=$(run_stop) && fail "stop must not report an altered entry as preserved, got: $out"
case "$out" in
  *worktree-state=CHANGED*) ;;
  *) fail "stop must report an entry whose status changed as a changed worktree, got: $out" ;;
esac
[ "$(git -C "$WORK/wt" status --porcelain -- README.md)" = " M README.md" ] \
  || fail "this case never actually altered the entry's status"
pass "fm-control stop: an entry whose status changed is CHANGED, though the path is still there"
git -C "$WORK/wt" checkout -q -- README.md

# --- 4e1b. WHERE THE CHECK STOPS, said out loud ----------------------------
# The porcelain entry of an ALREADY-dirty file does not move when its contents
# change: ` M README.md` before, ` M README.md` after, whatever happened to the
# bytes. So this is the boundary of what the comparison can prove, and the verb
# has to report that boundary rather than a guarantee it never earned. The
# assertion below is deliberately NOT that the file survived - it did not - but
# that the verb completes and names what it actually checked.
printf 'edited by the agent\n' >> "$WORK/wt/README.md"
BEFORE_ENTRY=$(git -C "$WORK/wt" status --porcelain -- README.md)
[ "$BEFORE_ENTRY" = " M README.md" ] \
  || fail "this case needs README.md dirty-unstaged, got: $BEFORE_ENTRY"
start_agent "$WORK/wt" ": > '$WORK/wt/README.md'; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that destroys a dirty file's contents as it stops"
out=$(run_stop) || fail "stop must complete when every entry kept its status, got: $out"
case "$out" in
  *worktree-state=entries-preserved*) ;;
  *) fail "stop must name what it checked - the entry set and its statuses, got: $out" ;;
esac
case "$out" in
  *worktree-state=intact*) fail "stop must not claim an intact worktree it cannot prove, got: $out" ;;
esac
[ "$(git -C "$WORK/wt" status --porcelain -- README.md)" = "$BEFORE_ENTRY" ] \
  || fail "this case needs the porcelain entry identical on both sides, or it proves nothing"
[ ! -s "$WORK/wt/README.md" ] \
  || fail "this case never actually destroyed the file's contents"
pass "fm-control stop: a preserved entry set is reported as exactly that, not as intact contents"
git -C "$WORK/wt" checkout -q -- README.md

# --- 4e3. THE SAME RULE ON A CLEAN WORKTREE, which is the headline case -----
# 4e2 above staged a dirty file first, so its `before` fingerprint always
# carried an entry and it could not fail on a defect that only bites when there
# are none. A worker wedged at authentication has produced no commits and no
# dirty files, so its worktree is CLEAN - and that is precisely the worker this
# verb exists to stop. A pure addition on top of nothing must still report that
# nothing was destroyed.
rm -f "$WORK/wt/dirty.txt" "$WORK/wt/flushed.log"
[ -z "$(git -C "$WORK/wt" status --porcelain)" ] \
  || fail "this case needs a genuinely clean worktree, got: $(git -C "$WORK/wt" status --porcelain)"
start_agent "$WORK/wt" ": > '$WORK/wt/flushed.log'; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that flushes a new file into a clean worktree"
out=$(run_stop) || fail "stop must succeed when a CLEAN worktree only gained a file, got: $out"
case "$out" in
  *worktree-state=entries-preserved*) ;;
  *) fail "a pure addition to a clean worktree must report the worktree intact, got: $out" ;;
esac
[ -e "$WORK/wt/flushed.log" ] || fail "this case never actually flushed a new file"
pass "fm-control stop: a clean worktree that only gained a flushed file keeps its entry set"
rm -f "$WORK/wt/flushed.log"
printf 'uncommitted\n' > "$WORK/wt/dirty.txt"

# --- 4g. THE IDENTITY PROOF asks about the directory, not its spelling ------
# The process's working directory comes back from the kernel with every symlink
# already resolved, while the recorded worktree is whatever string the spawn
# wrote. If the proof compared those two spellings a single symlinked component
# would refuse every worker on the host - leaving this verb's headline case
# exactly as unstoppable as it was before. macOS puts $TMPDIR under
# /var/folders, which is a symlink, so that host reaches this on every task.
mkdir -p "$WORK/linkroot"
ln -sfn "$WORK/wt" "$WORK/linkroot/wt-link"
write_meta "$WORK/linkroot/wt-link"
start_agent "$WORK/wt" || fail "could not stage an agent for the symlinked-worktree case"
LINK_PID=$(agent_pid) || fail "the agent process could not be resolved for the symlinked case"
out=$(run_stop) || fail "stop must claim an agent whose worktree is recorded through a symlink, got: $out"
case "$out" in
  "stopped pid=$LINK_PID "*) ;;
  *) fail "stop must signal the agent when the recorded worktree resolves to its cwd, got: $out" ;;
esac
case "$out" in
  *"not the task's recorded worktree"*) fail "stop refused an agent that IS in its worktree, got: $out" ;;
esac
i=0
while kill -0 "$LINK_PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
! kill -0 "$LINK_PID" 2>/dev/null || fail "the agent survived a reported stop in the symlinked case"
pass "fm-control stop: a worktree recorded through a symlink is still the agent's own worktree"
write_meta "$WORK/wt"

# --- 4f. A WORKTREE THAT COULD NOT BE READ is not a worktree left alone -----
# Reading nothing is not evidence of nothing changing. If the postcondition
# read fails the verb must say it could not check, never claim `unchanged`.
GITFILE=$(cat "$WORK/wt/.git")
start_agent "$WORK/wt" "rm -f '$WORK/wt/.git'; PATH=$WORK/bin:\$PATH opencode 1" \
  || fail "could not stage an agent that leaves its worktree unreadable"
out=$(run_stop) && fail "stop must not claim anything about a worktree it could not read, got: $out"
case "$out" in
  *worktree-state=unverified*) ;;
  *) fail "stop must say the worktree could not be verified, got: $out" ;;
esac
case "$out" in
  *worktree-state=entries-preserved*) fail "stop claimed preserved entries it never read, got: $out" ;;
esac
printf '%s\n' "$GITFILE" > "$WORK/wt/.git"
git -C "$WORK/wt" status --porcelain >/dev/null 2>&1 || fail "the worktree was not restored for the cases that follow"
pass "fm-control stop: a worktree that could not be read is reported unverified, never preserved"

# --- 5. a backend that cannot name a pane's process refuses, never guesses --
sed 's|^window=.*|window=zjses:fm-t1|' "$WORK/home/state/t1.meta" > "$WORK/home/state/t1.meta.new"
{ cat "$WORK/home/state/t1.meta.new"; echo "backend=zellij"; } > "$WORK/home/state/t1.meta"
out=$(run_stop) && fail "stop must refuse a backend with no process-identity surface, got: $out"
printf '%s\n' "$out" | grep -qi 'refus\|error' || fail "the refusal must say so plainly, got: $out"
pass "fm-control stop: a backend that cannot identify the agent process refuses rather than guessing"

printf 'ok - fm-control stop: real-process identity, signal, postconditions, and refusals\n'
