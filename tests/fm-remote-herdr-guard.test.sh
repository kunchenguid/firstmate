#!/usr/bin/env bash
# tests/fm-remote-herdr-guard.test.sh - the fm-remote launch agent's guard.
#
# Drives the real bin/fm-remote-herdr-guard.sh (with the owner library it
# sources and the fm-remote-herdr-supervisor.pl it starts the server through)
# against a fake herdr CLI, a fake lsof that names a real holder process as the
# session-socket owner, and real holder processes whose environment and
# ancestry carry the birth markers the guard reads. It pins the decision table:
# no server -> start; an Aqua-born owner -> leave it; an SSH-born or unprovable
# owner -> stop it, wait for the socket, start. It also pins how a started
# server runs: leading its own session as the child of the process launchd
# supervises, which carries the server's exit status and stop signals and
# leaves no process of the server's group behind, and that without a perl able
# to run the supervisor the guard starts nothing, stops nothing, and exits 1
# naming the prerequisite. Nothing here touches the
# runner's own herdr servers, launch agents, or login session, and no live
# harness guard applies: the verdict comes from process environment, ancestry,
# and session membership, which are kernel facts rather than vendor output.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the guard parses herdr's JSON, and jq is the holder process)"; exit 0; }
command -v mkfifo >/dev/null 2>&1 || { echo "skip: mkfifo not found (holder processes block on a fifo)"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (the guard starts the server through a perl supervisor)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-herdr-guard)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
HOLDER_PIDS=()
HOLDER_FD=5
trap 'if [ "${#HOLDER_PIDS[@]}" -gt 0 ]; then kill "${HOLDER_PIDS[@]}" 2>/dev/null || true; fi; fm_test_cleanup || true' EXIT

GUARD="$ROOT/bin/fm-remote-herdr-guard.sh"
JQ=$(command -v jq)
SESSION=fm-remote

# The guard must see only the fixture and the system tools it really needs,
# so a case can also present a host with NO lsof.
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
for tool in ps awk sed grep tr dirname basename sleep cat cp mv rm env bash sh id head; do
  real=$(command -v "$tool") || fail "test host lacks $tool"
  ln -sf "$real" "$TOOLS/$tool"
done
ln -sf "$JQ" "$TOOLS/jq"
# perl gets its own directory so a case can present a host without it.
PERL_TOOLS="$TMP_ROOT/perl-tools"
mkdir -p "$PERL_TOOLS"
ln -sf "$(command -v perl)" "$PERL_TOOLS/perl"
SUPERVISOR="$ROOT/bin/fm-remote-herdr-supervisor.pl"
FAKE="$TMP_ROOT/fake"
mkdir -p "$FAKE"
cat > "$FAKE/lsof" <<'SH'
#!/usr/bin/env bash
# Prints the -F pn shape for every pid listed in the owner file.
[ -f "$FM_FAKE_SOCKET_OWNER" ] || exit 0
while IFS= read -r pid; do
  [ -n "$pid" ] || continue
  printf 'p%s\n' "$pid"
  printf 'n%s\n' "$FM_FAKE_HERDR_SOCKET"
done < "$FM_FAKE_SOCKET_OWNER"
SH
cat > "$FAKE/launchctl" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = print ] || exit 0
domain=${2:-}
scope=${domain%%/*}
label=${domain#*/}
label=${label#*/}
state="$FM_FAKE_STATE/launchctl-$scope-$label"
[ -f "$state" ] || exit 113
cat "$state"
SH
cat > "$FAKE/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
running=$(cat "$FM_FAKE_HERDR_RUNNING" 2>/dev/null || printf 'false')
case "$*" in
  "status --json --session "*)
    if [ -f "$FM_FAKE_STATE/release-after" ]; then
      left=$(cat "$FM_FAKE_STATE/release-after")
      if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" > "$FM_FAKE_STATE/release-after"
      else
        rm -f "$FM_FAKE_STATE/release-after"
        printf 'false\n' > "$FM_FAKE_HERDR_RUNNING"
        running=false
      fi
    fi
    printf '{"server":{"running":%s,"socket":"%s","version":"0.9.0"},"client":{"version":"0.9.0"}}\n' \
      "$running" "$FM_FAKE_HERDR_SOCKET"
    ;;
  "server stop --session "*)
    if [ -f "$FM_FAKE_STATE/stop-ignored" ]; then
      exit 0
    elif [ -f "$FM_FAKE_STATE/stop-releases-after" ]; then
      cp "$FM_FAKE_STATE/stop-releases-after" "$FM_FAKE_STATE/release-after"
    else
      printf 'false\n' > "$FM_FAKE_HERDR_RUNNING"
    fi
    ;;
  "server --session "*)
    trap 'printf "TERM\n" >> "$FM_FAKE_STATE/signals"; exit 0' TERM
    trap 'printf "USR1\n" >> "$FM_FAKE_STATE/signals"' USR1
    printf 'pid=%s ppid=%s stat=%s xpc=%s session=%s\n' "$$" "$PPID" "$(ps -o stat= -p "$$" | tr -d ' ')" \
      "${XPC_SERVICE_NAME:-unset}" "${3:-}" > "$FM_FAKE_STATE/started.tmp"
    mv "$FM_FAKE_STATE/started.tmp" "$FM_FAKE_STATE/started"
    behavior=$(cat "$FM_FAKE_STATE/server-behavior" 2>/dev/null || true)
    case "$behavior" in
      exit\ *) exit "${behavior#exit }" ;;
      crash) kill -KILL "$$" ;;
      run) while :; do sleep 0.1; done ;;
      straggler)
        sleep 30 >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$FM_FAKE_STATE/straggler"
        ;;
    esac
    ;;
esac
exit 0
SH
chmod +x "$FAKE/lsof" "$FAKE/launchctl" "$FAKE/herdr"
cp "$FAKE/lsof" "$TMP_ROOT/lsof.fake"

# hold <marker-env...> -> HOLDER_PID: a real non-platform process (jq blocked
# on a fifo this test keeps open) whose environment is exactly the markers.
hold() {
  local fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo"
  rm -f "$fifo"
  mkfifo "$fifo"
  # Open read-write so this never blocks on the reader; the holder sees EOF
  # only when the descriptor closes at exit.
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  env -i "$@" "$JQ" . "$fifo" &
  HOLDER_PID=$!
  HOLDER_PIDS+=("$HOLDER_PID")
  HOLDER_FD=$((HOLDER_FD + 1))
}

# hold_under <argv0> <arg...> -- : a marker-free holder whose PARENT process
# carries the given argv[0] and arguments (the ancestry the guard inspects).
hold_under() {
  local argv0=$1 fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo" pidfile="$TMP_ROOT/holder-$HOLDER_FD.pid"
  shift
  rm -f "$fifo" "$pidfile"
  mkfifo "$fifo"
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  ( export FM_HOLDER_JQ="$JQ" FM_HOLDER_FIFO="$fifo" FM_HOLDER_PIDFILE="$pidfile"
    exec -a "$argv0" bash -c 'env -i FM_HOLDER=1 "$FM_HOLDER_JQ" . "$FM_HOLDER_FIFO" & printf "%s\n" "$!" > "$FM_HOLDER_PIDFILE"; wait' "$@" ) &
  HOLDER_PIDS+=("$!")
  HOLDER_FD=$((HOLDER_FD + 1))
  local i=0
  while [ ! -s "$pidfile" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$pidfile" ] || fail "holder under $argv0 did not report its pid"
  HOLDER_PID=$(cat "$pidfile")
  HOLDER_PIDS+=("$HOLDER_PID")
}

# hold_supervised <marker-env...> -> HOLDER_PID, SUPERVISOR_PID: a holder that
# bin/fm-remote-herdr-supervisor.pl started as the leader of its own session,
# the shape the launch agent gives the fm-remote server.
hold_supervised() {
  local fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo" i=0
  rm -f "$fifo"
  mkfifo "$fifo"
  eval "exec ${HOLDER_FD}<>\"\$fifo\""
  perl "$SUPERVISOR" env -i "$@" "$JQ" . "$fifo" 2>> "$TMP_ROOT/supervisor.log" &
  SUPERVISOR_PID=$!
  HOLDER_PIDS+=("$SUPERVISOR_PID")
  HOLDER_FD=$((HOLDER_FD + 1))
  HOLDER_PID=
  while [ -z "$HOLDER_PID" ] && [ "$i" -lt 100 ]; do
    HOLDER_PID=$(ps -A -o pid=,ppid=,command= | awk -v parent="$SUPERVISOR_PID" -v jq="$JQ" '$2 == parent && $3 == jq { print $1; exit }')
    [ -n "$HOLDER_PID" ] || sleep 0.05
    i=$((i + 1))
  done
  [ -n "$HOLDER_PID" ] || fail "the supervisor did not start its holder"
  HOLDER_PIDS+=("$HOLDER_PID")
}

CASE_N=0
new_case() { # [running|stopped]
  CASE_N=$((CASE_N + 1))
  CASE_STATE="$TMP_ROOT/case$CASE_N"
  mkdir -p "$CASE_STATE"
  CASE_LOG="$CASE_STATE/herdr.log"
  : > "$CASE_LOG"
  CASE_RUNNING="$CASE_STATE/running"
  printf '%s\n' "$([ "${1:-running}" = running ] && printf true || printf false)" > "$CASE_RUNNING"
  CASE_OWNER="$CASE_STATE/socket-owner"
  CASE_SOCKET="$CASE_STATE/herdr.sock"
  CASE_PATH="$FAKE:$TOOLS:$PERL_TOOLS"
}

load_job() { # <gui|user> <label> [pid]
  if [ -n "${3:-}" ]; then
    printf 'pid = %s\n' "$3" > "$CASE_STATE/launchctl-$1-$2"
  else
    printf 'state = running\n' > "$CASE_STATE/launchctl-$1-$2"
  fi
}

guard_env() { # -> GUARD_ENV: the environment every guard run gets in this case
  GUARD_ENV=(
    PATH="$CASE_PATH" HOME="$TMP_ROOT"
    FM_FAKE_STATE="$CASE_STATE" FM_FAKE_HERDR_LOG="$CASE_LOG" FM_FAKE_HERDR_RUNNING="$CASE_RUNNING"
    FM_FAKE_SOCKET_OWNER="$CASE_OWNER" FM_FAKE_HERDR_SOCKET="$CASE_SOCKET"
    FM_HOLDER_JQ="$JQ"
    FM_REMOTE_HERDR_GUARD_STOP_WAIT_TENTHS=8
  )
}

guard() { # [extra env assignments...]
  guard_env
  set +e
  GUARD_OUT=$(env -i "${GUARD_ENV[@]}" "$@" "$GUARD" "$FAKE/herdr" "$SESSION" 2>&1)
  GUARD_RC=$?
  set -e
}

# guard_background [extra env assignments...] -> GUARD_PID: env execs the
# guard, which execs the supervisor, so GUARD_PID is the process launchd would
# supervise and the case can signal it. wait_guard collects its outcome.
guard_background() {
  guard_env
  env -i "${GUARD_ENV[@]}" "$@" "$GUARD" "$FAKE/herdr" "$SESSION" > "$CASE_STATE/guard.out" 2>&1 &
  GUARD_PID=$!
  HOLDER_PIDS+=("$GUARD_PID")
}

wait_guard() { # -> GUARD_RC, GUARD_OUT
  set +e
  wait "$GUARD_PID" 2>/dev/null
  GUARD_RC=$?
  set -e
  GUARD_OUT=$(cat "$CASE_STATE/guard.out")
}

wait_for() { # <tenths> <command...>: succeeds as soon as the command does
  local limit=$1 i=0
  shift
  until "$@"; do
    [ "$i" -lt "$limit" ] || return 1
    sleep 0.1
    i=$((i + 1))
  done
}

started_field() { # <name>: a name=value field the fake server recorded at start
  tr ' ' '\n' < "$CASE_STATE/started" | sed -n "s/^$1=//p"
}

process_gone() { # <pid>: nothing runs as <pid>; a zombie awaiting its reaper counts as gone
  local stat
  stat=$(ps -o stat= -p "$1" 2>/dev/null) || return 0
  case "$stat" in ''|*Z*) return 0 ;; esac
  return 1
}

group_gone() { # <pgid>: no live process is left in that process group
  ps -A -o pgid=,stat= | awk -v group="$1" '$1 == group && $2 !~ /Z/ { found = 1 } END { exit found ? 1 : 0 }'
}

herdr_calls() { cat "$CASE_LOG"; }
assert_started() { # <msg>
  [ -f "$CASE_STATE/started" ] || fail "$1"
  assert_grep "session=$SESSION" "$CASE_STATE/started" "the server was started for the wrong session"
}
assert_not_started() { assert_absent "$CASE_STATE/started" "$1"; }
assert_stop_before_start() {
  local calls stop_line start_line
  calls=$(herdr_calls)
  stop_line=$(printf '%s\n' "$calls" | grep -n "^server stop --session $SESSION$" | head -1 | cut -d: -f1)
  start_line=$(printf '%s\n' "$calls" | grep -n "^server --session $SESSION$" | head -1 | cut -d: -f1)
  [ -n "$stop_line" ] || fail "the guard never asked the foreign server to stop"
  [ -n "$start_line" ] || fail "the guard never started its own server"
  [ "$stop_line" -lt "$start_line" ] || fail "the guard started its server before stopping the foreign one"
}

# Prove the holder construction on this host: the environment of a jq holder
# must be readable, or every marker case would be vacuous.
hold FM_PROBE_MARKER=1
PROBE_PID=$HOLDER_PID
sleep 0.2
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$ROOT/bin/fm-remote-herdr-owner-lib.sh"
probe_env=$(fm_remote_herdr_process_env "$PROBE_PID")
case "$probe_env" in
  *FM_PROBE_MARKER=1*) ;;
  *) fail "this host does not expose a holder's environment (macOS hides platform-binary environments; jq at $JQ must be a non-platform binary): $probe_env" ;;
esac
pass "holder processes expose their environment to the owner library"

# --- no server: the guard becomes the server ---------------------------------

new_case stopped
guard
expect_code 0 "$GUARD_RC" "the guard failed when no server owned the session"
assert_started "the guard did not start the server when none owned the session"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped something when no server owned the session"
assert_contains "$GUARD_OUT" "no server owns session $SESSION" "the guard did not report the empty session"
pass "an empty session is started inside the launch agent"

# --- a started server leads its own session under the supervised process ----

new_case stopped
guard_background XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
wait_guard
expect_code 0 "$GUARD_RC" "the guard failed to start a server that exited cleanly"
assert_started "the guard did not start the server through its supervisor"
assert_equals "$GUARD_PID" "$(started_field ppid)" \
  "the server is not the child of the process launchd supervises"
# macOS sets XPC_SERVICE_NAME to 0 in a forked child, which would hide the
# launchd label the owner library proves a launchd birth from.
assert_equals dev.firstmate.herdr.fm-remote "$(started_field xpc)" \
  "the server lost the launchd label the process launchd supervises was started with"
case "$(started_field stat)" in
  *s*) ;;
  *) fail "the server does not lead its own session: $(cat "$CASE_STATE/started")" ;;
esac
assert_contains "$GUARD_OUT" "as the leader of its own session under this launch agent (pid $GUARD_PID)" \
  "the guard did not report the supervised start"
pass "the server leads its own session as the child of the process launchd supervises"

for outcome in 'exit 3|3' 'crash|137'; do
  new_case stopped
  printf '%s\n' "${outcome%%|*}" > "$CASE_STATE/server-behavior"
  guard
  assert_started "the server did not start for the ${outcome%%|*} outcome"
  expect_code "${outcome##*|}" "$GUARD_RC" "the launch agent did not exit with the server's ${outcome%%|*} outcome"
done
pass "the launch agent exits with the server's own status or signal, so launchd still tells a clean stop from a crash"

new_case stopped
printf 'run\n' > "$CASE_STATE/server-behavior"
guard_background
wait_for 50 test -s "$CASE_STATE/started" || fail "the supervised server never started"
kill -USR1 "$GUARD_PID"
wait_for 50 grep -qs '^USR1$' "$CASE_STATE/signals" \
  || fail "SIGUSR1 sent to the process launchd supervises never reached the server"
kill -TERM "$GUARD_PID"
wait_guard
expect_code 0 "$GUARD_RC" "a server that stopped cleanly on SIGTERM did not make the launch agent exit 0"
assert_grep TERM "$CASE_STATE/signals" "SIGTERM sent to the process launchd supervises never reached the server"
wait_for 20 group_gone "$(started_field pid)" || fail "the server's process group outlived its clean stop"
pass "signals sent to the process launchd supervises reach the server"

new_case stopped
printf 'run\n' > "$CASE_STATE/server-behavior"
guard_background
wait_for 50 test -s "$CASE_STATE/started" || fail "the supervised server never started"
SERVER_PID=$(started_field pid)
HOLDER_PIDS+=("$SERVER_PID")
kill -KILL "$GUARD_PID"
wait_guard
expect_code 137 "$GUARD_RC" "the case did not SIGKILL the process launchd supervises"
wait_for 50 group_gone "$SERVER_PID" \
  || fail "the server's process group outlived the SIGKILLed launch agent process: $(ps -A -o pid=,pgid=,command= | awk -v group="$SERVER_PID" '$2 == group')"
assert_grep "the supervisor of process group $SERVER_PID is gone" "$CASE_STATE/guard.out" \
  "the watcher did not say why it killed the server"
pass "a SIGKILLed launch agent process leaves no server or watcher behind"

new_case stopped
printf 'straggler\n' > "$CASE_STATE/server-behavior"
guard
expect_code 0 "$GUARD_RC" "a server that left a process behind did not exit cleanly"
[ -s "$CASE_STATE/straggler" ] || fail "the fake server did not leave a process behind"
STRAGGLER_PID=$(cat "$CASE_STATE/straggler")
HOLDER_PIDS+=("$STRAGGLER_PID")
wait_for 20 process_gone "$STRAGGLER_PID" || fail "a process the server left in its process group outlived the server"
pass "a process the server leaves in its process group ends with the server"

BROKEN_PERL="$TMP_ROOT/broken-perl"
mkdir -p "$BROKEN_PERL"
printf '#!/bin/sh\nexit 2\n' > "$BROKEN_PERL/perl"
chmod +x "$BROKEN_PERL/perl"
PERL_LESS_HOSTS=("no perl|$FAKE:$TOOLS" "a perl that cannot compile the supervisor|$FAKE:$BROKEN_PERL:$TOOLS")
for host in "${PERL_LESS_HOSTS[@]}"; do
  new_case stopped
  CASE_PATH=${host#*|}
  guard
  expect_code 1 "$GUARD_RC" "the guard did not exit 1 for a launchd retry on a host with ${host%%|*}"
  assert_not_started "the guard started a server on a host with ${host%%|*}"
  assert_not_contains "$(herdr_calls)" "server --session" "the guard ran herdr server on a host with ${host%%|*}"
  assert_contains "$GUARD_OUT" "no perl on this PATH can run $SUPERVISOR" \
    "the guard did not name the missing prerequisite on a host with ${host%%|*}"
  assert_contains "$GUARD_OUT" 'exiting 1 without starting or stopping any server so launchd retries' \
    "the guard did not say what its exit 1 means on a host with ${host%%|*}"
done
pass "without a perl that can run the supervisor, an empty session gets no server and the guard names the prerequisite for a launchd retry"

# --- an Aqua-born owner is left alone ----------------------------------------

hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
LAUNCHD_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
BACKGROUND_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=0
XPC_ZERO_PID=$HOLDER_PID
hold FM_REMOTE_JOB_ACTIVE=1
WORKER_PID=$HOLDER_PID
hold SSH_CONNECTION='100.102.217.78 51234 100.100.1.2 22' SSH_CLIENT='100.102.217.78 51234 22'
SSH_PID=$HOLDER_PID
hold FM_NOTHING_TO_SEE=1
UNMARKED_PID=$HOLDER_PID
hold_under herdr --session "$SESSION" remote-client-bridge
BRIDGE_CHILD_PID=$HOLDER_PID
hold_under 'sshd-session:' kunchen@notty
SSHD_CHILD_PID=$HOLDER_PID
hold_supervised XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
SUPERVISED_PID=$HOLDER_PID
SUPERVISED_PARENT_PID=$SUPERVISOR_PID
sleep 0.3

new_case running
printf '%s\n' "$LAUNCHD_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for a gui-domain launchd owner"
assert_not_started "the guard started a second server over a gui-domain launchd owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a gui-domain launchd owner"
assert_contains "$GUARD_OUT" "pid $LAUNCHD_PID born in the Aqua login session (launchd)" \
  "the guard did not name the launchd owner"

new_case running
printf '%s\n' "$WORKER_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.remote-job
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for the gui-domain worker owner"
assert_not_started "the guard started a second server over a gui-domain worker owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a gui-domain worker owner"
assert_contains "$GUARD_OUT" "pid $WORKER_PID born in the Aqua login session (worker)" \
  "the guard did not name the worker owner"
pass "launchd and worker markers require gui-domain launchctl proof"

fm_remote_herdr_process_leads_session "$SUPERVISED_PID" \
  || fail "the supervised holder does not lead its own session, so the owner-parent cases below prove nothing"
if fm_remote_herdr_process_leads_session "$LAUNCHD_PID"; then
  fail "a plain holder leads its own session, so session leadership cannot tell the launch shapes apart"
fi

new_case running
printf '%s\n' "$SUPERVISED_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$SUPERVISED_PARENT_PID"
load_job user dev.firstmate.herdr.fm-remote
guard
expect_code 0 "$GUARD_RC" "the guard did not exit 0 for a server the gui-domain launchd job supervises"
assert_not_started "the guard started a second server over a supervised launchd owner"
assert_not_contains "$(herdr_calls)" 'server stop' "the guard stopped a supervised launchd owner"
assert_contains "$GUARD_OUT" "pid $SUPERVISED_PID born in the Aqua login session (launchd)" \
  "a gui-domain job running the owner's parent did not prove a launchd birth"

new_case running
printf '%s\n' "$SUPERVISED_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
load_job user dev.firstmate.herdr.fm-remote
guard
expect_code 0 "$GUARD_RC" "the guard failed to take over an owner the gui-domain job does not run"
assert_stop_before_start
assert_contains "$GUARD_OUT" "pid $SUPERVISED_PID born outside the Aqua login session (unknown)" \
  "a gui-domain job running an unrelated pid was trusted as the owner's parent"
pass "a gui-domain launchd job proves the server it supervises, and only that server"

# --- without perl, a running server is neither stopped nor replaced ---------

for host in "${PERL_LESS_HOSTS[@]}"; do
  new_case running
  CASE_PATH=${host#*|}
  printf '%s\n' "$LAUNCHD_PID" > "$CASE_OWNER"
  load_job gui dev.firstmate.herdr.fm-remote "$LAUNCHD_PID"
  guard
  expect_code 0 "$GUARD_RC" "on a host with ${host%%|*} the guard did not leave an Aqua-born owner alone"
  assert_not_started "on a host with ${host%%|*} the guard started a second server over an Aqua-born owner"
  assert_not_contains "$(herdr_calls)" 'server stop' "on a host with ${host%%|*} the guard stopped an Aqua-born owner"
  assert_contains "$GUARD_OUT" "pid $LAUNCHD_PID born in the Aqua login session (launchd); nothing to do" \
    "on a host with ${host%%|*} the guard did not report the Aqua-born owner"

  new_case running
  CASE_PATH=${host#*|}
  printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
  guard
  expect_code 1 "$GUARD_RC" "on a host with ${host%%|*} the guard did not exit 1 for a launchd retry over a foreign owner"
  assert_not_contains "$(herdr_calls)" 'server stop' \
    "on a host with ${host%%|*} the guard stopped a foreign server it could not replace"
  assert_not_started "on a host with ${host%%|*} the guard started a server over a foreign owner"
  assert_contains "$GUARD_OUT" "no perl on this PATH can run $SUPERVISOR" \
    "on a host with ${host%%|*} the guard did not name the missing prerequisite before the takeover"
done
pass "without a perl that can run the supervisor, an Aqua-born owner is left alone and a foreign one is not stopped"

# --- a foreign owner is stopped, then the guard becomes the server -----------

new_case running
printf '%s\n' "$BACKGROUND_PID" > "$CASE_OWNER"
load_job gui dev.firstmate.herdr.fm-remote
load_job user dev.firstmate.herdr.fm-remote
guard
expect_code 0 "$GUARD_RC" "the guard failed to take over a label also loaded in the user domain"
assert_stop_before_start
assert_contains "$GUARD_OUT" "pid $BACKGROUND_PID born outside the Aqua login session (unknown)" \
  "a user-domain label was trusted as Aqua"

new_case running
printf '%s\n' "$XPC_ZERO_PID" > "$CASE_OWNER"
guard
expect_code 0 "$GUARD_RC" "the guard failed to take over an XPC_SERVICE_NAME=0 owner"
assert_stop_before_start
assert_contains "$GUARD_OUT" "pid $XPC_ZERO_PID born outside the Aqua login session (unknown)" \
  "XPC_SERVICE_NAME=0 was trusted as Aqua"

for foreign in "ssh $SSH_PID" "ssh $BRIDGE_CHILD_PID" "ssh $SSHD_CHILD_PID" "unknown $UNMARKED_PID"; do
  new_case running
  printf '%s\n' "${foreign#* }" > "$CASE_OWNER"
  guard
  expect_code 0 "$GUARD_RC" "the guard failed to take over from a ${foreign%% *} owner (pid ${foreign#* })"
  assert_stop_before_start
  assert_started "the guard did not start its own server after the ${foreign%% *} owner released the socket"
  assert_contains "$GUARD_OUT" "pid ${foreign#* } born outside the Aqua login session (${foreign%% *})" \
    "the guard did not name the foreign owner and its birth"
done
pass "background, inherited-XPC, SSH-born, SSH-descended, and unprovable owners are taken over"

# --- an owner nobody can prove is treated as foreign -------------------------

new_case running
guard
expect_code 0 "$GUARD_RC" "the guard failed when lsof listed no owner"
assert_contains "$GUARD_OUT" 'no herdr process could be proven to own' "the guard did not report the unprovable owner"
assert_stop_before_start
pass "a running session with no provable owner is taken over rather than trusted"

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
rm -f "$FAKE/lsof"
guard
cp "$TMP_ROOT/lsof.fake" "$FAKE/lsof"
chmod +x "$FAKE/lsof"
expect_code 0 "$GUARD_RC" "the guard failed when lsof was absent"
assert_contains "$GUARD_OUT" 'lsof does not resolve' "the guard did not report the missing lsof"
assert_stop_before_start
pass "a host without lsof cannot prove an Aqua birth, so the session is taken over"

# --- a foreign owner that keeps the socket makes the guard fail for a retry --

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
touch "$CASE_STATE/stop-ignored"
guard
expect_code 1 "$GUARD_RC" "the guard did not exit 1 when the foreign server kept its socket"
assert_not_started "the guard started a server while the foreign one still held the socket"
assert_contains "$(herdr_calls)" "server stop --session $SESSION" "the guard never asked the foreign server to stop"
assert_contains "$GUARD_OUT" 'did not release its socket within 8 tenths' "the guard did not report the bounded wait"
pass "a foreign server that never releases the socket yields exit 1 so launchd retries"

# --- the release wait is polled, not assumed ---------------------------------

new_case running
printf '%s\n' "$SSH_PID" > "$CASE_OWNER"
printf '3\n' > "$CASE_STATE/stop-releases-after"
guard
expect_code 0 "$GUARD_RC" "the guard gave up on a server that released its socket after a few polls"
assert_started "the guard did not start after the delayed release"
assert_contains "$GUARD_OUT" 'released its socket after' "the guard did not report the observed release"
[ "$(grep -c "^status --json --session $SESSION$" "$CASE_LOG")" -ge 4 ] \
  || fail "the guard did not keep polling the session status until the socket was released"
pass "the guard starts as soon as the foreign server releases the socket"

# --- usage errors never touch a server ---------------------------------------

new_case running
set +e
env -i PATH="$CASE_PATH" "$GUARD" "$FAKE/herdr" >/dev/null 2>&1
rc=$?
set -e
expect_code 2 "$rc" "a missing session argument was not a usage error"
set +e
env -i PATH="$CASE_PATH" "$GUARD" "$TMP_ROOT/no-such-herdr" "$SESSION" >/dev/null 2>&1
rc=$?
set -e
expect_code 1 "$rc" "a non-executable herdr path was not refused"
[ ! -s "$CASE_LOG" ] || fail "a refused invocation still called herdr"
pass "argument errors are refused before any herdr call"
