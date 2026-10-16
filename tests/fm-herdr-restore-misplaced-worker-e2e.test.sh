#!/usr/bin/env bash
# Real Herdr regression for where a session restore resumes a task agent.
#
# Herdr persists a pane's top-level shell directory and re-runs the agent's
# resume command there. Two task panes are created in the main project copy:
# t2 in today's spawn shape, whose top-level shell `cd`s into its leased
# worktree, and t1 in the older shape, where only a `treehouse get` subshell
# entered the worktree. A token-free stand-in agent named `claude` registers its
# session through Herdr's own session API. After a restore, t2 must resume in
# its worktree and read as in place, while t1 resumes in the main copy and the
# production guards hold: the misplaced-worker proof names the main copy, the
# doorbell types nothing, and the watcher surfaces the worker once.
#
# Every Herdr call runs in one guarded named non-default lab, and lab teardown
# verifies the default fleet session is unchanged.
# shellcheck disable=SC2016 # Single-quoted scripts expand in the child bash or eval that runs them.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
command -v git >/dev/null 2>&1 || { echo 'skip: git not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
SLEEP_BIN=$(command -v sleep) || { echo 'skip: sleep not found'; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-restore-misplaced.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
AGENTBIN="$TMP_ROOT/agentbin"
HOME_DIR="$TMP_ROOT/home"
MAIN="$TMP_ROOT/main"
WT="$TMP_ROOT/pool/wt"
WT2="$TMP_ROOT/pool/wt2"
AGENT_LOG="$TMP_ROOT/agent.log"
SID=0f1e2d3c-4b5a-4697-8877-665544332211
SID2=1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d
mkdir -p "$FAKEBIN" "$AGENTBIN/libexec" "$HOME_DIR/state" "$HOME_DIR/config"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-restore-misplaced)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer stop "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

git init -q "$MAIN" || fail 'could not create the main copy'
git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init \
  || fail 'could not commit in the main copy'
mkdir -p "${WT%/*}"
git -C "$MAIN" worktree add -q "$WT" -b task || fail 'could not create the task worktree'
git -C "$MAIN" worktree add -q "$WT2" -b task2 || fail 'could not create the second task worktree'

# The stand-in agent: logs where it runs and with what arguments, registers
# its session the way Herdr's Claude integration does, then becomes a process
# named `claude` so both Herdr and the harness-process classifier see an agent.
# A fresh launch takes its session id from FM_STANDIN_SID; a resume reuses the
# id it was given.
cp "$SLEEP_BIN" "$AGENTBIN/libexec/claude"
cat > "$AGENTBIN/claude" <<SH
#!/usr/bin/env bash
printf 'pwd=%s args=%s\n' "\$PWD" "\$*" >> '$AGENT_LOG'
sid=\${FM_STANDIN_SID:-}
[ "\${1:-}" != --resume ] || sid=\${2:-}
( sleep 1
  env PATH='$HERDR_ORIGINAL_PATH' '$HERDR_LAB_HELPER' run '$HERDR_LAB_SESSION' pane report-agent-session \
    "\$HERDR_PANE_ID" --source herdr:claude --agent claude --agent-session-id "\$sid" >/dev/null 2>&1 ) &
exec '$AGENTBIN/libexec/claude' 100000
SH
# Panes start this shell, so a restored pane resolves `claude` to the stand-in
# without reading the operator's shell startup files.
cat > "$AGENTBIN/labshell" <<SH
#!/usr/bin/env bash
export PATH='$AGENTBIN':"\$PATH"
exec /bin/bash --norc "\$@"
SH
chmod +x "$AGENTBIN/claude" "$AGENTBIN/labshell"

# Production adapter calls append the exact lab session; this shim strips that
# pair, refuses every other caller-supplied session, and delegates to helper run.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
if [ "${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
provision() {
  env SHELL="$AGENTBIN/labshell" PATH="$AGENTBIN:$HERDR_ORIGINAL_PATH" \
    "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null
}
pane_field() {  # <pane> <jq-filter>
  lab pane get "$1" 2>/dev/null | jq -r "$2" 2>/dev/null
}
production() {  # <bash-script> [args...]
  local script=$1
  shift
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_ROOT_OVERRIDE="$ROOT" HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
    bash -c "$script" _ "$ROOT" "$@"
}
outside() {  # <task-id>
  production '. "$1/bin/fm-backend.sh"; fm_backend_task_outside_worktree "$2"' "$HOME_DIR/state/$1.meta"
}
wait_for() {  # <tries> <command...>
  local tries=$1 i=0
  shift
  while [ "$i" -lt "$tries" ]; do
    "$@" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

session_recorded() {  # <pane> <session-id>
  [ "$(pane_field "$1" ".result.pane.agent_session.value // empty")" = "$2" ] && return 0
  lab pane report-agent-session "$1" --source herdr:claude --agent claude --agent-session-id "$2" >/dev/null 2>&1
  return 1
}

# start_task <id> <subshell|top-level> <worktree> <session-id>: create the
# task's tab in the main copy, enter the worktree in the given shape, start the
# stand-in agent there, and write the task record. Sets PANE and TAB.
start_task() {
  local id=$1 shape=$2 wt=$3 sid=$4 tab_json
  tab_json=$(lab tab create --workspace "$WS" --cwd "$MAIN" --label "fm-$id" --no-focus) || fail "could not create $id's tab"
  PANE=$(printf '%s' "$tab_json" | jq -r '.result.root_pane.pane_id')
  TAB=$(printf '%s' "$tab_json" | jq -r '.result.tab.tab_id')
  [ -n "$PANE" ] && [ "$PANE" != null ] || fail "tab create returned no pane: $tab_json"
  if [ "$shape" = subshell ]; then
    lab pane send-text "$PANE" "bash --norc -c 'cd \"\$1\" && exec bash --norc -i' _ '$wt'" >/dev/null || fail "could not type $id's subshell"
  else
    lab pane send-text "$PANE" "cd -- '$wt'" >/dev/null || fail "could not type $id's cd"
  fi
  lab pane send-keys "$PANE" Enter >/dev/null || fail "could not enter $id's worktree"
  wait_for 30 eval '[ "$(pane_field "$PANE" ".result.pane.foreground_cwd // empty")" = "$wt" ]' \
    || fail "$id's pane never entered its worktree (foreground $(pane_field "$PANE" .result.pane.foreground_cwd))"
  lab pane send-text "$PANE" "FM_STANDIN_SID=$sid claude --dangerously-skip-permissions" >/dev/null || fail "could not type $id's agent launch"
  lab pane send-keys "$PANE" Enter >/dev/null || fail "could not start $id's agent"
  # Herdr applies a session report only once it sees the agent, which can trail
  # the stand-in's own report, so repeat it until the session is recorded.
  wait_for 40 session_recorded "$PANE" "$sid" \
    || fail "$id's stand-in agent never registered its session: $(lab pane get "$PANE")"
  {
    printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$PANE"
    printf 'endpoint_task_id=fm-%s\n' "$id"
    printf 'worktree=%s\n' "$wt"
    printf 'project=%s\n' "$MAIN"
    printf 'harness=claude\nkind=ship\nbackend=herdr\n'
    printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
      "$HERDR_LAB_SESSION" "$WS" "$TAB" "$PANE"
  } > "$HOME_DIR/state/$id.meta"
}

provision || fail 'could not provision the named lab'
WS_JSON=$(lab workspace create --cwd "$MAIN" --label restore-misplaced --no-focus) || fail 'could not create the workspace'
WS=$(printf '%s' "$WS_JSON" | jq -r '.result.workspace.workspace_id')
start_task t2 top-level "$WT2" "$SID2"
# shellcheck disable=SC2034 # Read inside the eval wait below.
PANE2=$PANE
TAB2=$TAB
start_task t1 subshell "$WT" "$SID"

out=$(outside t1) && fail "an agent running in its worktree subshell was reported outside it: $out"
out=$(outside t2) && fail "an agent running in its worktree was reported outside it: $out"
pass 'a live agent in its worktree is not reported, in either shape'

env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail 'could not stop the named lab'
provision || fail 'could not restore the named lab'
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" viewer start "$HERDR_LAB_SESSION" >/dev/null \
  || fail 'could not attach a viewer to the restored lab'
lab tab focus "$TAB2" >/dev/null 2>&1 || true
wait_for 60 grep -qF "args=--resume $SID2" "$AGENT_LOG" \
  || fail "the restore never resumed the top-level-shell agent: $(cat "$AGENT_LOG" 2>/dev/null)"
grep -qxF "pwd=$WT2 args=--resume $SID2" "$AGENT_LOG" \
  || fail "the agent whose top-level shell was in its worktree did not resume there: $(cat "$AGENT_LOG")"
wait_for 40 eval '[ "$(pane_field "$PANE2" ".result.pane.foreground_cwd // empty")" = "$WT2" ]' \
  || fail "the restored top-level-shell pane is not in its worktree"
rc=0
out=$(outside t2) || rc=$?
[ "$rc" -eq 1 ] || fail "the agent resumed in its worktree should read positively in place, got rc=$rc '$out'"
pass 'a pane whose top-level shell is in its worktree is restored and resumed in that worktree'

lab tab focus "$TAB" >/dev/null 2>&1 || true
wait_for 60 grep -qF "args=--resume $SID" "$AGENT_LOG" \
  || fail "the restore never resumed the agent: $(cat "$AGENT_LOG" 2>/dev/null)"
grep -qxF "pwd=$MAIN args=--resume $SID" "$AGENT_LOG" \
  || fail "the restored agent did not resume in the main copy, which this regression depends on: $(cat "$AGENT_LOG")"
pass 'a Herdr restore resumes a subshell-shaped agent in the main copy the pane was created in'

wait_for 40 eval 'out=$(outside t1)' || fail "the resumed agent in the main copy was never reported outside its worktree"
[ "$out" = "$MAIN" ] || fail "the misplaced agent should be reported in '$MAIN', got '$out'"
pass 'the resumed agent is reported outside its recorded worktree, naming the main copy'

REC=$(production '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" t1 "please continue"' "$HOME_DIR/state") \
  || fail 'could not write a steering record'
rc=0
production '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_ring herdr "$2" "$3" fm-t1; rc=$?; printf "%s" "$FM_TASK_INBOX_MISPLACED_DIR" > "$4"; exit "$rc"' \
  "$HERDR_LAB_SESSION:$PANE" "$REC" "$TMP_ROOT/ring-dir" || rc=$?
[ "$rc" -eq 4 ] || fail "the doorbell to a misplaced agent should return 4, got $rc"
[ "$(cat "$TMP_ROOT/ring-dir")" = "$MAIN" ] || fail "the refused ring should name the main copy, got '$(cat "$TMP_ROOT/ring-dir")'"
sleep 1
if lab pane read "$PANE" --source recent --lines 40 2>/dev/null | grep -qF 'Firstmate instruction waiting'; then
  fail 'the doorbell was typed into the misplaced agent'
fi
[ -f "$REC" ] || fail 'the refused ring must leave the steering record in place'
pass 'the doorbell types nothing into the misplaced agent and keeps the record'

WATCH_CHECK='
  . "$1/bin/fm-watch.sh"
  wake() { printf "WAKE %s\n" "$1"; exit 0; }
  misplaced_worker_check "$2" t1
  printf "QUIET %s\n" "$?"'
first=$(production "$WATCH_CHECK" "$HERDR_LAB_SESSION:$PANE") || fail "the watcher check failed: $first"
case "$first" in
  "WAKE stale: $HERDR_LAB_SESSION:$PANE (worker agent runs in $MAIN, outside its recorded worktree $WT,"*) ;;
  *) fail "the watcher should surface the misplaced worker once, got: $first" ;;
esac
second=$(production "$WATCH_CHECK" "$HERDR_LAB_SESSION:$PANE") || fail "the repeated watcher check failed: $second"
[ "$second" = 'QUIET 0' ] || fail "the same misplaced directory must be surfaced only once, got: $second"
pass 'the watcher surfaces a misplaced worker once and skips its other checks'
