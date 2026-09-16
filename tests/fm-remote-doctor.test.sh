#!/usr/bin/env bash
# tests/fm-remote-doctor.test.sh - the remote second-mate readiness gate.
#
# Drives the real bin/fm-remote-doctor.sh against a controlled account fixture:
# a private HOME, a fake launchctl backed by state files, a fake herdr CLI, a
# fake lsof that names a real holder process as the fm-remote socket owner, and
# a fake uname that selects the platform under test. The holders are real
# non-platform processes (jq blocked on a fifo) whose environment carries the
# birth markers bin/fm-remote-herdr-owner-lib.sh reads, so the Aqua-versus-SSH
# verdict is exercised for real. Nothing here touches the runner's own launch
# agents, login session, or herdr server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the herdr adapter parses its JSON)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (plistlib parses the owned launch-agent contract)"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "skip: perl not found (a holder runs under the launch agent's perl supervisor)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-doctor)
LABEL=dev.firstmate.herdr.fm-remote
INTERACTIVE_LABEL=dev.firstmate.herdr
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
JOB_LABEL=dev.firstmate.remote-job
CASE_N=0
DOCTOR_WORKER_PID=
HOLDER_PIDS=()
trap 'if [ -n "$DOCTOR_WORKER_PID" ]; then kill "$DOCTOR_WORKER_PID" 2>/dev/null || true; fi; if [ "${#HOLDER_PIDS[@]}" -gt 0 ]; then kill "${HOLDER_PIDS[@]}" 2>/dev/null || true; fi; fm_test_cleanup || true' EXIT
GUARD="$ROOT/bin/fm-remote-herdr-guard.sh"

# A fixture must be able to present a host with NO herdr, so the doctor never
# sees the runner's own PATH. Only the two required tools are re-exposed, by
# symlink, alongside the system directories the doctor's own helpers need.
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
ln -sf "$(command -v git)" "$TOOLS/git"
ln -sf "$(command -v jq)" "$TOOLS/jq"
BASE_PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

# Real socket-owner holders for the Darwin birth check: jq blocked on a fifo
# this test keeps open, with exactly the marker environment each birth needs.
JQ=$(command -v jq)
HOLDER_FD=5
hold() { # <marker-env...> -> HOLDER_PID
  local fifo="$TMP_ROOT/holder-$HOLDER_FD.fifo"
  mkfifo "$fifo"
  env -i "$@" "$JQ" . "$fifo" &
  HOLDER_PID=$!
  HOLDER_PIDS+=("$HOLDER_PID")
  eval "exec ${HOLDER_FD}>\"\$fifo\""
  HOLDER_FD=$((HOLDER_FD + 1))
}
hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
AQUA_HOLDER_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote
BACKGROUND_HOLDER_PID=$HOLDER_PID
hold XPC_SERVICE_NAME=0
XPC_ZERO_HOLDER_PID=$HOLDER_PID
hold FM_REMOTE_JOB_ACTIVE=1
WORKER_HOLDER_PID=$HOLDER_PID
hold SSH_CONNECTION='100.102.217.78 51234 100.100.1.2 22' SSH_CLIENT='100.102.217.78 51234 22'
SSH_HOLDER_PID=$HOLDER_PID
# The launchd marker again, on a holder bin/fm-remote-herdr-supervisor.pl
# started as the leader of its own session, the shape the launch agent gives
# the server.
SUPERVISED_FIFO="$TMP_ROOT/holder-$HOLDER_FD.fifo"
mkfifo "$SUPERVISED_FIFO"
eval "exec ${HOLDER_FD}<>\"\$SUPERVISED_FIFO\""
HOLDER_FD=$((HOLDER_FD + 1))
perl "$ROOT/bin/fm-remote-herdr-supervisor.pl" env -i XPC_SERVICE_NAME=dev.firstmate.herdr.fm-remote "$JQ" . "$SUPERVISED_FIFO" 2>> "$TMP_ROOT/supervisor.log" &
SUPERVISOR_PID=$!
HOLDER_PIDS+=("$SUPERVISOR_PID")
SESSION_LEADER_HOLDER_PID=
for _ in $(seq 1 100); do
  SESSION_LEADER_HOLDER_PID=$(ps -A -o pid=,ppid=,command= | awk -v parent="$SUPERVISOR_PID" -v jq="$JQ" '$2 == parent && $3 == jq { print $1; exit }')
  [ -z "$SESSION_LEADER_HOLDER_PID" ] || break
  sleep 0.05
done
[ -n "$SESSION_LEADER_HOLDER_PID" ] || fail "the supervisor did not start its holder"
HOLDER_PIDS+=("$SESSION_LEADER_HOLDER_PID")

# new_case <Darwin|Linux> [with-herdr] [gui] [login-shell]
# Builds one isolated account fixture and points the module-level CASE_*
# variables at it. "with-herdr" installs the fake herdr CLI; "gui" makes the
# fake launchctl report an existing Aqua login session. login-shell is the
# Directory Services UserShell the fake dscl reports (default /bin/sh so the
# fixture is portable to hosts without /bin/zsh).
new_case() {
  local platform=$1 want_herdr=${2:-with-herdr} want_gui=${3:-gui}
  unset CASE_REMOTE_JOB_ACTIVE
  unset CASE_PLATFORM_OVERRIDE
  unset CASE_DSCL_FAIL
  unset CASE_DSCL_HANG
  unset CASE_SECOND_LOGIN_SHELL
  unset CASE_ENV_SHELL
  unset CASE_RESOLVE_DSCL
  CASE_N=$((CASE_N + 1))
  CASE_LOGIN_SHELL=${4:-/bin/sh}
  CASE_DIR="$TMP_ROOT/case$CASE_N"
  CASE_BIN="$CASE_DIR/bin"
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJECT_HOME="$CASE_DIR/project-home"
  CASE_STATE="$CASE_DIR/state"
  CASE_LAUNCHCTL_LOG="$CASE_STATE/launchctl.log"
  CASE_FORBIDDEN_LOG="$CASE_STATE/forbidden.log"
  CASE_HERDR_RUNNING="$CASE_STATE/herdr.running"
  CASE_PLIST="$CASE_HOME/Library/LaunchAgents/$LABEL.plist"
  CASE_INTERACTIVE_PLIST="$CASE_HOME/Library/LaunchAgents/$INTERACTIVE_LABEL.plist"
  CASE_JOB_PLIST="$CASE_HOME/Library/LaunchAgents/$JOB_LABEL.plist"
  mkdir -p "$CASE_BIN" "$CASE_HOME" "$CASE_PROJECT_HOME" "$CASE_STATE"
  printf 'false\n' > "$CASE_HERDR_RUNNING"
  : > "$CASE_LAUNCHCTL_LOG"
  : > "$CASE_FORBIDDEN_LOG"
  [ "$want_gui" != gui ] || touch "$CASE_STATE/gui-session"

  cat > "$CASE_BIN/uname" <<SH
#!/usr/bin/env bash
printf '%s\n' '$platform'
SH

  cat > "$CASE_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
domain=${2:-}
label=${domain##*/}
loaded="$FM_FAKE_STATE/loaded-$label"
case "${1:-}" in
  print)
    case "$domain" in
      user/*/*)
        [ -f "$FM_FAKE_STATE/user-loaded-$label" ] || exit 113
        cat "$FM_FAKE_STATE/user-loaded-$label"
        ;;
      */dev.firstmate.herdr.fm-remote)
        [ -f "$loaded" ] || exit 113
        cat "$loaded"
        ;;
      */dev.firstmate.herdr)
        [ -f "$FM_FAKE_STATE/interactive-loaded" ] || exit 113
        printf 'interactive default job\n'
        ;;
      */*/*) [ -f "$loaded" ] || exit 113; cat "$loaded" ;;
      *) [ -f "$FM_FAKE_STATE/gui-session" ] || exit 113 ;;
    esac
    exit 0
    ;;
  bootout)
    [ ! -f "$FM_FAKE_STATE/bootout-fail" ] || { printf 'Boot-out failed: operation not permitted\n' >&2; exit 6; }
    case "$domain" in
      */dev.firstmate.herdr.fm-remote) rm -f "$loaded" ;;
      */dev.firstmate.herdr) rm -f "$FM_FAKE_STATE/interactive-loaded" ;;
      *) rm -f "$loaded" ;;
    esac
    exit 0
    ;;
  bootstrap)
    # launchd refuses a gui/<uid> domain that has no login session.
    [ -f "$FM_FAKE_STATE/gui-session" ] || { printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 5; }
    [ ! -f "$loaded" ] || { printf 'Bootstrap failed: service already loaded\n' >&2; exit 5; }
    plist=${3:-}
    label=${plist##*/}
    label=${label%.plist}
    loaded="$FM_FAKE_STATE/loaded-$label"
    [ ! -f "$loaded" ] || { printf 'Bootstrap failed: service already loaded\n' >&2; exit 5; }
    case "$label" in
      dev.firstmate.remote-job)
        cat > "$loaded" <<EOF
path = $FM_FAKE_JOB_PLIST
program = $FM_FAKE_JOB_WORKER
properties = keepalive | runatload | inferred program
EOF
        ;;
      *)
        cat > "$loaded" <<EOF
path = $FM_FAKE_PLIST
program = $FM_FAKE_LOGIN_SHELL
arguments = {
	$FM_FAKE_LOGIN_SHELL
	-l
	-c
	exec '$FM_FAKE_GUARD' '$FM_FAKE_HERDR_BIN' 'fm-remote'
}
stdout path = $FM_FAKE_LAUNCH_AGENT_LOG
stderr path = $FM_FAKE_LAUNCH_AGENT_LOG
semaphores = {
	successful exit => 0
}
properties = runatload | inferred program
EOF
        if [ ! -f "$FM_FAKE_STATE/bootstrap-does-not-start" ]; then
          printf 'true\n' > "$FM_FAKE_HERDR_RUNNING"
          printf '%s\n' "$FM_FAKE_AQUA_PID" > "$FM_FAKE_STATE/socket-owner"
        fi
        ;;
    esac
    exit 0
    ;;
  kickstart)
    [ ! -f "$FM_FAKE_STATE/kickstart-fail" ] || { printf 'Kickstart failed: service unavailable\n' >&2; exit 6; }
    case "$label" in
      dev.firstmate.remote-job) : ;;
      *)
        # The real job execs the guard, which stops a foreign server and
        # becomes the Aqua-born owner; the fixture models that outcome.
        printf '%s\n' "$FM_FAKE_AQUA_PID" > "$FM_FAKE_STATE/socket-owner"
        if [ -f "$FM_FAKE_STATE/kickstart-delay" ]; then
          cp "$FM_FAKE_STATE/kickstart-delay" "$FM_FAKE_STATE/herdr-delay"
        else
          printf 'true\n' > "$FM_FAKE_HERDR_RUNNING"
        fi
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH

  # Any attempt to reach for auto-login, FileVault, or the keychain records
  # itself here so the test can prove the doctor never goes near them.
  local forbidden
  for forbidden in fdesetup security defaults; do
    cat > "$CASE_BIN/$forbidden" <<SH
#!/usr/bin/env bash
printf '$forbidden %s\n' "\$*" >> "\$FM_FAKE_FORBIDDEN_LOG"
exit 0
SH
    chmod +x "$CASE_BIN/$forbidden"
  done

  # The socket owner the birth check sees: the pid in socket-owner, or the
  # Aqua holder when a case never chose one.
  cat > "$CASE_BIN/lsof" <<'SH'
#!/usr/bin/env bash
pid=$(cat "$FM_FAKE_STATE/socket-owner" 2>/dev/null || printf '%s' "$FM_FAKE_AQUA_PID")
[ -n "$pid" ] || exit 0
printf 'p%s\n' "$pid"
printf 'n%s\n' "$FM_FAKE_HERDR_SOCKET"
SH
  chmod +x "$CASE_BIN/lsof"

  cat > "$CASE_BIN/dscl" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_DSCL_FAIL:-0}" != 1 ] || exit 1
[ "${FM_FAKE_DSCL_HANG:-0}" != 1 ] || exec /bin/sleep 30
if [ "${1:-}" = . ] && [ "${2:-}" = -read ] && [ "${4:-}" = UserShell ]; then
  count_file="$FM_FAKE_STATE/dscl-count"
  count=$(cat "$count_file" 2>/dev/null || printf 0)
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  shell=${FM_FAKE_LOGIN_SHELL:-/bin/sh}
  if [ "$count" -gt 1 ] && [ -n "${FM_FAKE_SECOND_LOGIN_SHELL:-}" ]; then
    shell=$FM_FAKE_SECOND_LOGIN_SHELL
  fi
  printf 'UserShell: %s\n' "$shell"
  exit 0
fi
exit 1
SH

  if [ "$want_herdr" = with-herdr ]; then
    cat > "$CASE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
running=$(cat "$FM_FAKE_HERDR_RUNNING" 2>/dev/null || printf 'false')
case "${1:-} ${2:-}" in
  "status --json")
    if [ -f "$FM_FAKE_STATE/herdr-delay" ]; then
      delay=$(cat "$FM_FAKE_STATE/herdr-delay")
      if [ "$delay" -gt 0 ]; then
        printf '%s\n' "$((delay - 1))" > "$FM_FAKE_STATE/herdr-delay"
        running=false
      else
        rm -f "$FM_FAKE_STATE/herdr-delay"
        printf 'true\n' > "$FM_FAKE_HERDR_RUNNING"
        running=true
      fi
    fi
    printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":%s,"socket":"%s"}}\n' "$running" "$FM_FAKE_HERDR_SOCKET"
    ;;
  "server "*|"server ")
    printf 'true\n' > "$FM_FAKE_HERDR_RUNNING"
    ;;
esac
exit 0
SH
    chmod +x "$CASE_BIN/herdr"
  fi
  cat > "$CASE_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.4\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  cat > "$CASE_BIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$CASE_BIN/claude" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE_BIN/uname" "$CASE_BIN/launchctl" "$CASE_BIN/dscl" "$CASE_BIN/tasks-axi" "$CASE_BIN/treehouse" "$CASE_BIN/claude"
  cat > "$CASE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE_BIN/sleep"
}

# doctor [args...] -> runs the real doctor against the current fixture,
# capturing merged output in DOCTOR_OUT and its status in DOCTOR_RC.
doctor_env() { # -> DOCTOR_ENV: the environment every doctor run gets in this case
  DOCTOR_ENV=(
    HOME="$CASE_HOME"
    FM_HOME="$CASE_PROJECT_HOME"
    PATH="$CASE_HOME/.local/bin:$CASE_BIN:$BASE_PATH"
    FM_FAKE_STATE="$CASE_STATE"
    FM_FAKE_LAUNCHCTL_LOG="$CASE_LAUNCHCTL_LOG"
    FM_FAKE_FORBIDDEN_LOG="$CASE_FORBIDDEN_LOG"
    FM_FAKE_HERDR_RUNNING="$CASE_HERDR_RUNNING"
    FM_FAKE_HERDR_BIN="$CASE_BIN/herdr"
    FM_FAKE_HERDR_SOCKET="$CASE_STATE/herdr.sock"
    FM_FAKE_GUARD="$GUARD"
    FM_FAKE_AQUA_PID="$AQUA_HOLDER_PID"
    FM_FAKE_PLIST="$CASE_PLIST"
    FM_FAKE_JOB_PLIST="$CASE_JOB_PLIST"
    FM_FAKE_JOB_WORKER="$ROOT/bin/fm-remote-job-worker.sh"
    FM_FAKE_LAUNCH_AGENT_LOG="$CASE_HOME/Library/Logs/$LABEL.log"
    FM_FAKE_LOGIN_SHELL="${CASE_LOGIN_SHELL:-/bin/sh}"
    FM_FAKE_SECOND_LOGIN_SHELL="${CASE_SECOND_LOGIN_SHELL:-}"
    FM_FAKE_DSCL_FAIL="${CASE_DSCL_FAIL:-0}"
    FM_FAKE_DSCL_HANG="${CASE_DSCL_HANG:-0}"
    FM_LAUNCH_AGENT_SHELL="$([ "${CASE_RESOLVE_DSCL:-0}" = 1 ] || printf '%s' "$CASE_LOGIN_SHELL")"
    SHELL="${CASE_ENV_SHELL-${SHELL-}}"
    FM_REMOTE_JOB_PLATFORM_OVERRIDE="${CASE_PLATFORM_OVERRIDE-}"
    FM_REMOTE_JOB_ACTIVE="${CASE_REMOTE_JOB_ACTIVE-1}"
  )
}

doctor() {
  doctor_env
  set +e
  DOCTOR_OUT=$(env "${DOCTOR_ENV[@]}" "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1)
  DOCTOR_RC=$?
  set -e
}

# doctor_route <dir>: an fm-on.sh in <dir> that runs this case's doctor for
# any route, so bin/fm-remote-readiness-lib.sh can be driven against the case.
doctor_route() {
  local assignment
  doctor_env
  mkdir -p "$1"
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # ${2:-} belongs to the generated fm-on.sh and expands when it runs.
    printf '[ "${2:-}" = fm-remote-doctor.sh ] || exit 64\n'
    printf 'shift 2\n'
    printf 'exec env'
    for assignment in "${DOCTOR_ENV[@]}"; do printf ' %q' "$assignment"; done
    printf ' %q "$@"\n' "$ROOT/bin/fm-remote-doctor.sh"
  } > "$1/fm-on.sh"
  chmod +x "$1/fm-on.sh"
}

# login_shell_with_path <path>: a login shell for this case that runs its -c
# command through /bin/sh with exactly <path> on PATH, so a case can present a
# login shell whose PATH has no perl, or a perl that cannot compile anything.
login_shell_with_path() {
  CASE_LOGIN_SHELL="$CASE_DIR/login-shell"
  cat > "$CASE_LOGIN_SHELL" <<SH
#!/bin/sh
[ "\$1" = -l ] && [ "\$2" = -c ] || exit 64
PATH='$1' exec /bin/sh -c "\$3"
SH
  chmod +x "$CASE_LOGIN_SHELL"
}

write_loaded_contract() { # <herdr-path> [properties] [exec-command]
  local herdr_bin=$1 properties=${2:-'runatload | inferred program'} exec_cmd
  exec_cmd=${3:-"exec '$GUARD' '$herdr_bin' 'fm-remote'"}
  cat > "$CASE_STATE/loaded-$LABEL" <<EOF
path = $CASE_PLIST
program = $CASE_LOGIN_SHELL
arguments = {
	$CASE_LOGIN_SHELL
	-l
	-c
	$exec_cmd
}
stdout path = $CASE_HOME/Library/Logs/$LABEL.log
stderr path = $CASE_HOME/Library/Logs/$LABEL.log
semaphores = {
	successful exit => 0
}
properties = $properties
EOF
}

# Parse the doctor's owned launch-agent plist and assert the login-shell
# argv contract. The plist is Firstmate's output, so semantic structure is
# in bounds; never match the XML source as a substring.
plist_value() { # <plist> <key>
  python3 -c 'import plistlib,sys; value=plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]]; print(value)' "$1" "$2"
}

plist_first_value() { # <plist> <array-key>
  python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]][0])' "$1" "$2"
}

assert_herdr_launch_agent_contract() { # <plist> <herdr-bin> [login-shell]
  local plist=$1 herdr_bin=$2 expected_shell=${3:-$CASE_LOGIN_SHELL} json argv0 argv1 argv2 cmd
  json=$(python3 -c 'import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1], "rb"))))' "$plist") \
    || fail "could not parse $plist as a plist"
  argv0=$(printf '%s' "$json" | jq -r '.ProgramArguments[0]')
  argv1=$(printf '%s' "$json" | jq -r '.ProgramArguments[1]')
  argv2=$(printf '%s' "$json" | jq -r '.ProgramArguments[2]')
  cmd=$(printf '%s' "$json" | jq -r '.ProgramArguments[3]')
  [ "$argv0" = "$expected_shell" ] || fail "ProgramArguments[0] is $argv0, not the resolved login shell $expected_shell"
  [ "$argv1" = -l ] || fail "ProgramArguments[1] is $argv1, not -l"
  [ "$argv2" = -c ] || fail "ProgramArguments[2] is $argv2, not -c"
  [ "$cmd" = "exec '$GUARD' '$herdr_bin' 'fm-remote'" ] \
    || fail "ProgramArguments[3] is not exec of the guard with $herdr_bin for session fm-remote: $cmd"
  [ "$(printf '%s' "$json" | jq -r '.LimitLoadToSessionType')" = Aqua ] \
    || fail "LimitLoadToSessionType is not Aqua"
  [ "$(printf '%s' "$json" | jq -r '.RunAtLoad')" = true ] \
    || fail "RunAtLoad is not true"
  [ "$(printf '%s' "$json" | jq -r '.KeepAlive.SuccessfulExit')" = false ] \
    || fail "KeepAlive is not {SuccessfulExit=false}: $(printf '%s' "$json" | jq -c '.KeepAlive')"
  [ "$(printf '%s' "$json" | jq -r '.ThrottleInterval')" = 10 ] \
    || fail "ThrottleInterval is not 10"
  [ "$(printf '%s' "$json" | jq -r '.Label')" = "$LABEL" ] \
    || fail "Label is not $LABEL"
}

assert_no_dangerous_calls() { # <msg>
  [ ! -s "$CASE_FORBIDDEN_LOG" ] \
    || fail "$1"$'\n'"--- attempted ---"$'\n'"$(cat "$CASE_FORBIDDEN_LOG")"
  assert_absent "$CASE_HOME/Library/Preferences/com.apple.loginwindow.plist" \
    "the doctor wrote a loginwindow preference"
  assert_absent "$CASE_HOME/kcpassword" "the doctor wrote an auto-login password"
}

# --- a host with no herdr is never ready, and --fix cannot install one -------

new_case Darwin no-herdr gui
doctor
expect_code 1 "$DOCTOR_RC" "a host without herdr was reported ready"
assert_contains "$DOCTOR_OUT" 'check herdr=human:' "a missing herdr CLI was not tagged as a human gap"
assert_contains "$DOCTOR_OUT" 'action: herdr:' "a missing herdr CLI came with no operator action"
doctor --fix
expect_code 1 "$DOCTOR_RC" "--fix reported a host without herdr as ready"
assert_contains "$DOCTOR_OUT" 'check herdr=human:' "--fix stopped reporting the missing herdr CLI"
assert_not_contains "$DOCTOR_OUT" 'fix herdr=applied' "--fix claimed to have installed herdr"
assert_no_dangerous_calls "the doctor reached for auto-login, FileVault, or the keychain"
pass "a missing herdr CLI is a human gap that --fix never claims to close"

# --- an absent launch agent is a fixable gap that --fix installs -------------

new_case Darwin with-herdr gui
mkdir -p "$(dirname "$CASE_INTERACTIVE_PLIST")"
cat > "$CASE_INTERACTIVE_PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$INTERACTIVE_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$CASE_BIN/herdr</string>
		<string>server</string>
		<string>--session</string>
		<string>default</string>
	</array>
</dict>
</plist>
XML
cp "$CASE_INTERACTIVE_PLIST" "$CASE_STATE/interactive-before.plist"
touch "$CASE_STATE/interactive-loaded"
doctor
expect_code 1 "$DOCTOR_RC" "a host with no launch agent was reported ready"
assert_contains "$DOCTOR_OUT" 'check herdr=ok:' "the fake herdr CLI was not detected"
assert_contains "$DOCTOR_OUT" 'check gui-session=ok:' "an existing login session was not detected"
assert_contains "$DOCTOR_OUT" 'check launchagent=fixable:' "an absent launch agent was not tagged fixable"
assert_contains "$DOCTOR_OUT" "$LABEL.plist" "the gap did not name the launch agent path"
assert_contains "$DOCTOR_OUT" 'check herdr-server=fixable:' "a stopped herdr server was not tagged fixable"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=fixable:' "an absent remote job worker was not tagged fixable"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker-loaded=fixable:' "an unloaded remote job worker was not tagged fixable"
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=ok:' "the controlled job-worker probe was not reported"
assert_absent "$CASE_PLIST" "a read-only doctor run installed a launch agent"
assert_absent "$CASE_JOB_PLIST" "a read-only doctor run installed a remote job worker"
[ ! -s "$CASE_LAUNCHCTL_LOG" ] || assert_not_contains "$(cat "$CASE_LAUNCHCTL_LOG")" bootstrap \
  "a read-only doctor run loaded a launch agent"
pass "an absent launch agent is a fixable gap and the read-only run changes nothing"

doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix left a repairable host unready"
assert_contains "$DOCTOR_OUT" 'fix launchagent=applied:' "--fix did not report installing the launch agent"
assert_contains "$DOCTOR_OUT" 'check launchagent=ok:' "--fix did not re-check the installed launch agent"
assert_contains "$DOCTOR_OUT" 'check launchagent-scope=ok: LimitLoadToSessionType=Aqua' \
  "the installed launch agent was not Aqua-scoped"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=ok:' "--fix did not load the launch agent"
assert_contains "$DOCTOR_OUT" 'check herdr-server=ok:' "--fix did not leave the herdr server running"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=ok:' "--fix did not install the remote job worker contract"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker-loaded=ok:' "--fix did not load the remote job worker"
assert_present "$CASE_PLIST" "--fix reported success without writing the plist"
assert_present "$CASE_JOB_PLIST" "--fix reported success without writing the remote job worker plist"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr"
[ "$(plist_value "$CASE_JOB_PLIST" Label)" = "$JOB_LABEL" ] \
  || fail "the worker plist does not carry the Firstmate label"
[ "$(plist_value "$CASE_JOB_PLIST" LimitLoadToSessionType)" = Aqua ] \
  || fail "the worker plist is not Aqua-scoped"
[ "$(plist_first_value "$CASE_JOB_PLIST" ProgramArguments)" = "$ROOT/bin/fm-remote-job-worker.sh" ] \
  || fail "the worker plist does not use the configured code root"
assert_absent "$CASE_STATE/dscl-count" "the injected login shell still consulted Directory Services"
assert_grep "gui/$(id -u)" "$CASE_LAUNCHCTL_LOG" "the launch agent was not bootstrapped into the GUI domain"
cmp -s "$CASE_STATE/interactive-before.plist" "$CASE_INTERACTIVE_PLIST" \
  || fail "the fm-remote repair rewrote the interactive default launch agent"
assert_present "$CASE_STATE/interactive-loaded" "the fm-remote repair unloaded the interactive default launch agent"
assert_no_grep "gui/$(id -u)/$INTERACTIVE_LABEL$" "$CASE_LAUNCHCTL_LOG" \
  "the fm-remote repair inspected or controlled the interactive default launch agent"
assert_no_dangerous_calls "the repair reached for auto-login, FileVault, or the keychain"
pass "--fix installs the dedicated fm-remote launch agent without touching default"

PLIST_BEFORE=$(cat "$CASE_PLIST")
: > "$CASE_LAUNCHCTL_LOG"
doctor --fix
expect_code 0 "$DOCTOR_RC" "a second --fix on a ready host reported a gap"
assert_not_contains "$DOCTOR_OUT" 'fix launchagent=applied:' "a second --fix rewrote a healthy launch agent"
assert_not_contains "$DOCTOR_OUT" 'fix launchagent-loaded=applied:' "a second --fix reloaded a healthy launch agent"
[ "$(cat "$CASE_PLIST")" = "$PLIST_BEFORE" ] || fail "a second --fix changed the installed plist"
[ ! -s "$CASE_LAUNCHCTL_LOG" ] || assert_not_contains "$(cat "$CASE_LAUNCHCTL_LOG")" bootstrap \
  "a second --fix re-bootstrapped a loaded launch agent"
pass "--fix is idempotent once the host is ready"

# --- a loaded, running launch agent with contract drift is repaired ----------

new_case Darwin with-herdr gui
mkdir -p "$(dirname "$CASE_PLIST")"
cat > "$CASE_PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/obsolete/bin/herdr</string>
		<string>server</string>
		<string>--session</string>
		<string>default</string>
	</array>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
XML
write_loaded_contract /obsolete/bin/herdr 'keepalive | runatload | inferred program' "exec '/obsolete/bin/herdr' server --session 'fm-remote'"
printf 'true\n' > "$CASE_HERDR_RUNNING"
doctor
expect_code 1 "$DOCTOR_RC" "a stale launch-agent contract was reported ready"
assert_contains "$DOCTOR_OUT" 'check launchagent=fixable:' "launch-agent contract drift was not tagged fixable"
assert_contains "$DOCTOR_OUT" 'check launchagent-scope=ok:' "the independent Aqua scope was not recognized"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=fixable:' "the stale effective launch-agent contract was not tagged fixable"
assert_contains "$DOCTOR_OUT" 'check herdr-server=ok:' "the running fixture was not recognized"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not repair launch-agent contract drift"
assert_contains "$DOCTOR_OUT" 'check launchagent=ok:' "the repaired launch-agent contract was not confirmed"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr"
pass "a loaded and running launch agent must match the complete owned contract"

# --- failed replacement cannot hide a stale loaded launch-agent contract -----

new_case Darwin with-herdr gui
mkdir -p "$(dirname "$CASE_PLIST")"
cat > "$CASE_PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/obsolete/bin/herdr</string>
		<string>server</string>
		<string>--session</string>
		<string>default</string>
	</array>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
XML
write_loaded_contract /obsolete/bin/herdr 'keepalive | runatload | inferred program' "exec '/obsolete/bin/herdr' server --session 'fm-remote'"
printf 'true\n' > "$CASE_HERDR_RUNNING"
touch "$CASE_STATE/bootout-fail"
doctor --fix
expect_code 1 "$DOCTOR_RC" "a stale loaded job passed after its replacement failed"
assert_contains "$DOCTOR_OUT" 'fix launchagent-loaded=failed: launchctl bootstrap' "the failed replacement was not reported"
assert_contains "$DOCTOR_OUT" 'check launchagent=ok:' "the repaired disk contract was not confirmed"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=fixable:' "the stale loaded contract did not remain a readiness gap"
assert_contains "$DOCTOR_OUT" 'check herdr-server=ok:' "the existing server masking condition was not preserved"

rm -f "$CASE_STATE/bootout-fail"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not replace the stale loaded launch-agent contract"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=ok:' "the replacement loaded contract was not confirmed"
assert_no_grep '/obsolete/bin/herdr' "$CASE_STATE/loaded-$LABEL" "the stale effective program survived replacement"
pass "a failed reload leaves stale effective launch-agent state unready"

# --- a launch agent that is not Aqua-scoped is repaired in place -------------

new_case Darwin with-herdr gui
mkdir -p "$(dirname "$CASE_PLIST")"
cat > "$CASE_PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>LimitLoadToSessionType</key>
	<string>Background</string>
</dict>
</plist>
XML
doctor
expect_code 1 "$DOCTOR_RC" "a Background-scoped launch agent was reported ready"
assert_contains "$DOCTOR_OUT" 'check launchagent=fixable:' "an incomplete launch agent was not tagged fixable"
assert_contains "$DOCTOR_OUT" 'check launchagent-scope=fixable:' "a non-Aqua session scope was not tagged fixable"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix could not re-scope an existing launch agent"
assert_contains "$DOCTOR_OUT" 'check launchagent-scope=ok: LimitLoadToSessionType=Aqua' \
  "--fix did not re-scope the launch agent to Aqua"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr"
pass "a launch agent outside the Aqua session scope is rewritten in place"

# --- launchd start failures are reported and delayed readiness is awaited ----

new_case Darwin with-herdr gui
doctor --fix
expect_code 0 "$DOCTOR_RC" "the launch-agent startup fixture could not be initialized"
printf 'false\n' > "$CASE_HERDR_RUNNING"
touch "$CASE_STATE/bootstrap-does-not-start" "$CASE_STATE/kickstart-fail"
doctor --fix
expect_code 1 "$DOCTOR_RC" "a failed launchctl kickstart was reported ready"
assert_contains "$DOCTOR_OUT" 'fix herdr-server=failed: launchctl kickstart' "kickstart failure was not reported"
assert_contains "$DOCTOR_OUT" 'Kickstart failed: service unavailable' "kickstart diagnostic was discarded"
assert_not_contains "$DOCTOR_OUT" 'fix herdr-server=applied:' "a failed kickstart was reported as applied"
assert_contains "$DOCTOR_OUT" 'check herdr-server=fixable:' "the stopped server was not preserved as a readiness gap"

rm -f "$CASE_STATE/kickstart-fail"
printf '2\n' > "$CASE_STATE/kickstart-delay"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not wait for delayed launchd startup"
assert_contains "$DOCTOR_OUT" 'fix herdr-server=applied:' "delayed launchd startup was not reported as applied"
assert_contains "$DOCTOR_OUT" 'check herdr-server=ok:' "delayed launchd startup was not confirmed"
assert_absent "$CASE_STATE/herdr-delay" "the readiness poll stopped before the delayed server became reachable"
pass "launchd failures are reported and delayed server readiness is awaited"

# --- a running session served outside the Aqua login session is not ready ---

new_case Darwin with-herdr gui
doctor --fix
expect_code 0 "$DOCTOR_RC" "the Aqua-owner fixture could not be initialized"
assert_contains "$DOCTOR_OUT" "check herdr-server=ok: session fm-remote is running in the Aqua login session (pid $AQUA_HOLDER_PID, launchd)" \
  "a launchd-born owner was not reported with its pid and birth"
assert_contains "$DOCTOR_OUT" "check herdr-server=ok: session fm-remote is running in the Aqua login session (pid $AQUA_HOLDER_PID, launchd), which is all a remote second mate needs; that server does not lead its own session, so Herdr saved SSH machines refuse it until it is restarted" \
  "an owner that does not lead its own session was not reported ready with the saved-machine difference"
assert_contains "$DOCTOR_OUT" "run 'herdr server stop --session fm-remote && launchctl kickstart -k gui/$(id -u)/$LABEL' on that account" \
  "the consent-required restart was not named with the account's uid and the agent label"
assert_contains "$DOCTOR_OUT" 'neither updating Firstmate nor --fix restarts a running Aqua-born server because the restart closes its panes' \
  "the report did not say that no automatic path restarts the server, or what the restart costs"
assert_not_contains "$DOCTOR_OUT" 'action: herdr-server:' "a running Aqua-born server was presented as a readiness gap"
: > "$CASE_LAUNCHCTL_LOG"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix over a running Aqua-born server that does not lead its own session was not ready"
assert_not_contains "$DOCTOR_OUT" 'fix herdr-server=' "--fix acted on a running Aqua-born server that does not lead its own session"
assert_no_grep "kickstart -k gui/$(id -u)/$LABEL" "$CASE_LAUNCHCTL_LOG" \
  "--fix restarted a running Aqua-born server that does not lead its own session"
assert_no_grep "bootout gui/$(id -u)/$LABEL" "$CASE_LAUNCHCTL_LOG" \
  "--fix booted out the launch agent over a running Aqua-born server that does not lead its own session"
assert_contains "$DOCTOR_OUT" "(pid $AQUA_HOLDER_PID, launchd), which is all a remote second mate needs" \
  "--fix changed the verdict on a running Aqua-born server that does not lead its own session"

printf '%s\n' "$SESSION_LEADER_HOLDER_PID" > "$CASE_STATE/socket-owner"
doctor
expect_code 0 "$DOCTOR_RC" "an Aqua-born owner that leads its own session was not reported ready"
assert_contains "$DOCTOR_OUT" "check herdr-server=ok: session fm-remote is running in the Aqua login session (pid $SESSION_LEADER_HOLDER_PID, launchd); it leads its own session, as Herdr saved SSH machines require" \
  "an Aqua-born owner that leads its own session was not reported as Herdr saved SSH machines require"
pass "session leadership is reported on an Aqua-born owner without changing its readiness, and the restart that would give it one is named, never applied"

printf '%s\n' "$BACKGROUND_HOLDER_PID" > "$CASE_STATE/socket-owner"
printf 'background job\n' > "$CASE_STATE/user-loaded-$LABEL"
doctor
expect_code 1 "$DOCTOR_RC" "a label loaded in the user domain was reported Aqua-born"
assert_contains "$DOCTOR_OUT" "check herdr-server=fixable: session fm-remote is served by pid $BACKGROUND_HOLDER_PID born outside the Aqua login session (unknown)" \
  "the user-domain owner was not tagged fixable"
rm -f "$CASE_STATE/user-loaded-$LABEL"

printf '%s\n' "$XPC_ZERO_HOLDER_PID" > "$CASE_STATE/socket-owner"
doctor
expect_code 1 "$DOCTOR_RC" "an XPC_SERVICE_NAME=0 owner was reported Aqua-born"
assert_contains "$DOCTOR_OUT" "check herdr-server=fixable: session fm-remote is served by pid $XPC_ZERO_HOLDER_PID born outside the Aqua login session (unknown)" \
  "the inherited XPC marker was not tagged fixable"

printf '%s\n' "$WORKER_HOLDER_PID" > "$CASE_STATE/socket-owner"
doctor
expect_code 0 "$DOCTOR_RC" "the gui-only remote-job worker owner was not reported ready"
assert_contains "$DOCTOR_OUT" "check herdr-server=ok: session fm-remote is running in the Aqua login session (pid $WORKER_HOLDER_PID, worker)" \
  "the gui-only worker was not recognized"

printf '%s\n' "$SSH_HOLDER_PID" > "$CASE_STATE/socket-owner"
: > "$CASE_LAUNCHCTL_LOG"
doctor
expect_code 1 "$DOCTOR_RC" "a session served by an SSH-born server was reported ready"
assert_contains "$DOCTOR_OUT" "check herdr-server=fixable: session fm-remote is served by pid $SSH_HOLDER_PID born outside the Aqua login session (ssh)" \
  "an SSH-born owner was not tagged fixable with its pid and birth"
assert_contains "$DOCTOR_OUT" 'cannot reach the login keychain' "the consequence of the foreign birth was not named"
assert_contains "$DOCTOR_OUT" 'action: herdr-server:' "the foreign-birth gap came with no operator action"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=ok:' "a healthy loaded contract was blamed for the foreign server"
[ ! -s "$CASE_LAUNCHCTL_LOG" ] || assert_not_contains "$(cat "$CASE_LAUNCHCTL_LOG")" kickstart \
  "a read-only doctor run restarted the launch agent"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not hand the session back to the launch agent"
assert_contains "$DOCTOR_OUT" 'fix herdr-server=applied:' "--fix did not report the takeover through the launch agent"
assert_grep "kickstart -k gui/$(id -u)/$LABEL" "$CASE_LAUNCHCTL_LOG" "the takeover did not go through launchd"
assert_contains "$DOCTOR_OUT" "check herdr-server=ok: session fm-remote is running in the Aqua login session (pid $AQUA_HOLDER_PID, launchd)" \
  "the launch-agent-owned server was not confirmed after the takeover"
assert_no_dangerous_calls "the takeover reached for auto-login, FileVault, or the keychain"

# A RunAtLoad job also runs at bootstrap; hold that back so the takeover
# depends on the kickstart that is about to fail.
printf '%s\n' "$SSH_HOLDER_PID" > "$CASE_STATE/socket-owner"
touch "$CASE_STATE/kickstart-fail" "$CASE_STATE/bootstrap-does-not-start"
doctor --fix
expect_code 1 "$DOCTOR_RC" "a failed takeover was reported ready"
assert_contains "$DOCTOR_OUT" 'fix herdr-server=failed: launchctl kickstart' "the failed takeover was not reported"
assert_contains "$DOCTOR_OUT" "check herdr-server=fixable: session fm-remote is served by pid $SSH_HOLDER_PID" \
  "a still-foreign server was reported ready after a failed takeover"
rm -f "$CASE_STATE/kickstart-fail" "$CASE_STATE/bootstrap-does-not-start"

rm -f "$CASE_STATE/socket-owner"
: > "$CASE_STATE/socket-owner"
doctor
expect_code 1 "$DOCTOR_RC" "a session with no provable owner was reported ready"
assert_contains "$DOCTOR_OUT" 'check herdr-server=fixable: session fm-remote is running but no herdr process can be shown to own its socket' \
  "an unprovable owner was not tagged fixable"
pass "a session served outside the Aqua login session is fixable and --fix retakes it through launchd"

# --- no GUI login session: every dependent gap stays human -------------------

new_case Darwin with-herdr no-gui
doctor --fix
expect_code 1 "$DOCTOR_RC" "a host with no login session was reported ready"
assert_contains "$DOCTOR_OUT" 'check gui-session=human:' "an absent login session was not tagged human"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=human:' "loading without a login session was not tagged human"
assert_contains "$DOCTOR_OUT" 'check herdr-server=human:' "starting a server without a login session was not tagged human"
assert_not_contains "$DOCTOR_OUT" 'fix gui-session=applied' "--fix claimed to have created a login session"
assert_not_contains "$DOCTOR_OUT" 'fix launchagent-loaded=applied' "--fix claimed to have loaded an unloadable launch agent"
assert_not_contains "$DOCTOR_OUT" 'fix herdr-server=applied' "--fix claimed to have started an unstartable server"
assert_contains "$DOCTOR_OUT" 'action: gui-session:' "the login-session gap came with no operator action"
assert_contains "$DOCTOR_OUT" 'automatic login' "the login-session action did not name the operator step"
assert_present "$CASE_PLIST" "--fix skipped the automatable launch-agent gap because a human gap existed"
assert_contains "$DOCTOR_OUT" 'error: this host is not ready for a remote second mate' \
  "a remaining human gap did not fail the readiness verdict"
assert_no_dangerous_calls "the doctor tried to create a login session by force"
pass "human gaps are reported with their operator step and never claimed as fixed"

# --- a login shell without a usable perl is a human gap, never a --fix loop -

# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$ROOT/bin/fm-remote-readiness-lib.sh"
SUPERVISOR="$ROOT/bin/fm-remote-herdr-supervisor.pl"
mkdir -p "$TMP_ROOT/empty-bin" "$TMP_ROOT/broken-perl"
printf '#!/bin/sh\nexit 2\n' > "$TMP_ROOT/broken-perl/perl"
chmod +x "$TMP_ROOT/broken-perl/perl"

new_case Darwin with-herdr gui
login_shell_with_path "$TMP_ROOT/empty-bin"
touch "$CASE_STATE/bootstrap-does-not-start" "$CASE_STATE/kickstart-fail"
doctor --fix
expect_code 1 "$DOCTOR_RC" "a host whose login shell has no perl was reported ready"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr" "$CASE_LOGIN_SHELL"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=ok:' "the launch agent, which converges once perl resolves, was not installed and loaded"
assert_contains "$DOCTOR_OUT" "check herdr-server=human: the herdr server for session fm-remote is not running; the launch agent starts a server only through a perl that compiles $SUPERVISOR, and '$CASE_LOGIN_SHELL -l -c' found none (exit 127)" \
  "a login shell with no perl was not reported as a human gap naming the interpreter"
assert_contains "$DOCTOR_OUT" 'action: herdr-server: install perl on that account (macOS ships /usr/bin/perl) or put a working one on the login-shell PATH of' \
  "the interpreter gap came with no operator step"
assert_not_contains "$DOCTOR_OUT" 'rerun this command with --fix to start it' "a server the launch agent cannot start was offered to --fix"
assert_not_contains "$DOCTOR_OUT" 'fix herdr-server=' "--fix tried to start a server the launch agent cannot start"
assert_no_dangerous_calls "the interpreter gap sent the doctor toward the keychain or login settings"

rm -f "$CASE_STATE/kickstart-fail"
: > "$CASE_LAUNCHCTL_LOG"
doctor
expect_code 1 "$DOCTOR_RC" "the read-only run reported a host whose launch agent cannot start a server as ready"
assert_contains "$DOCTOR_OUT" 'check herdr-server=human: the herdr server for session fm-remote is not running; the launch agent starts a server only through a perl' \
  "the read-only run lost the interpreter gap"
for mutation in bootstrap bootout kickstart; do
  assert_no_grep "$mutation" "$CASE_LAUNCHCTL_LOG" "a read-only run ran launchctl $mutation over an interpreter gap"
done

doctor_route "$CASE_DIR/route-bin"
: > "$CASE_LAUNCHCTL_LOG"
set +e
FM_REMOTE_READINESS_OUT=
fm_remote_readiness_ensure "$CASE_DIR/route-bin" ios
rc=$?
set -e
expect_code 1 "$rc" "the readiness gate passed a host whose launch agent cannot start a server"
assert_contains "$FM_REMOTE_READINESS_OUT" "check herdr-server=human: the herdr server for session fm-remote is not running; the launch agent starts a server only through a perl that compiles $SUPERVISOR" \
  "the readiness gate's verdict does not carry the interpreter gap"
assert_contains "$FM_REMOTE_READINESS_OUT" 'action: herdr-server: install perl on that account' \
  "the readiness gate's verdict does not carry the operator step"
assert_not_contains "$FM_REMOTE_READINESS_OUT" 'rerun this command with --fix' \
  "the readiness gate recommends another --fix for a gap --fix cannot close"
for mutation in bootstrap bootout kickstart; do
  assert_no_grep "$mutation" "$CASE_LAUNCHCTL_LOG" "the readiness gate's --fix pass ran launchctl $mutation over an interpreter gap"
done

printf 'true\n' > "$CASE_HERDR_RUNNING"
printf '%s\n' "$SSH_HOLDER_PID" > "$CASE_STATE/socket-owner"
: > "$CASE_LAUNCHCTL_LOG"
doctor --fix
expect_code 1 "$DOCTOR_RC" "a foreign server the launch agent cannot replace was reported ready"
assert_contains "$DOCTOR_OUT" "check herdr-server=human: session fm-remote is served by pid $SSH_HOLDER_PID born outside the Aqua login session (ssh), so its panes cannot reach the login keychain; the launch agent starts a server only through a perl" \
  "a foreign server the launch agent cannot replace was not reported as the interpreter gap"
assert_not_contains "$DOCTOR_OUT" 'fix herdr-server=' "--fix tried to take over a session the launch agent cannot serve"
assert_no_grep kickstart "$CASE_LAUNCHCTL_LOG" "--fix restarted the launch agent over a foreign server it cannot replace"
assert_no_grep bootout "$CASE_LAUNCHCTL_LOG" "--fix booted out the launch agent over a foreign server it cannot replace"

new_case Darwin with-herdr gui
login_shell_with_path "$TMP_ROOT/broken-perl"
doctor
expect_code 1 "$DOCTOR_RC" "a host whose perl cannot compile the supervisor was reported ready"
assert_contains "$DOCTOR_OUT" "check herdr-server=human: the herdr server for session fm-remote is not running; the launch agent starts a server only through a perl that compiles $SUPERVISOR, and '$CASE_LOGIN_SHELL -l -c' found none (exit 2)" \
  "a perl that cannot compile the supervisor was not reported as a human gap with its exit status"

new_case Darwin with-herdr gui
CASE_LOGIN_SHELL="$CASE_DIR/login-shell"
printf '#!/bin/sh\nexec /bin/sleep 30\n' > "$CASE_LOGIN_SHELL"
chmod +x "$CASE_LOGIN_SHELL"
SECONDS=0
doctor
elapsed=$SECONDS
expect_code 1 "$DOCTOR_RC" "a host whose login shell stalls at startup was reported ready"
[ "$elapsed" -lt 20 ] || fail "a stalled login shell blocked doctor for ${elapsed}s"
assert_contains "$DOCTOR_OUT" "check herdr-server=human: the herdr server for session fm-remote is not running; the launch agent starts a server only through a perl that compiles $SUPERVISOR, and '$CASE_LOGIN_SHELL -l -c' did not finish running perl -c on it within 5s" \
  "a login shell that stalls at startup was not reported as an unverified interpreter within the bound"
assert_contains "$DOCTOR_OUT" "action: herdr-server: inspect what makes '$CASE_LOGIN_SHELL -l' slow or block at startup on that account" \
  "a stalled login shell's action does not point at its startup"
assert_contains "$DOCTOR_OUT" 'the perl there is unverified rather than missing' \
  "a stalled login shell's action does not say the interpreter is unverified"
assert_not_contains "$DOCTOR_OUT" 'install perl' "a stalled login shell was prescribed a perl install"

new_case Darwin with-herdr gui
login_shell_with_path "$TMP_ROOT/empty-bin:/usr/bin:/bin"
doctor --fix
expect_code 0 "$DOCTOR_RC" "a login shell whose PATH has a working perl was not ready"
assert_contains "$DOCTOR_OUT" 'check herdr-server=ok:' "a login shell whose PATH has a working perl did not get its server started"
pass "a login shell without a perl that compiles the supervisor is a human gap the readiness gate preserves, a stalled one is an unverified gap, and --fix never loops on either"

# --- a non-zsh login shell is rendered with separate -l and -c --------------

new_case Darwin with-herdr gui /bin/bash
CASE_RESOLVE_DSCL=1
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix left a bash-login-shell host unready"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr" /bin/bash
pass "a bash Directory Services login shell is rendered with -l -c"

new_case Darwin with-herdr gui
CASE_LOGIN_SHELL="$CASE_DIR/My Shell/fish&dev"
mkdir -p "$(dirname "$CASE_LOGIN_SHELL")"
printf '#!/bin/sh\nexit 0\n' > "$CASE_LOGIN_SHELL"
chmod +x "$CASE_LOGIN_SHELL"
CASE_RESOLVE_DSCL=1
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix rejected a valid custom Directory Services shell"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr" "$CASE_LOGIN_SHELL"
pass "custom Directory Services shell paths remain valid plist arguments"

# --- shell resolution falls back to an executable environment shell, then sh -

new_case Darwin with-herdr gui /bin/bash
CASE_RESOLVE_DSCL=1
CASE_DSCL_FAIL=1
CASE_ENV_SHELL=/bin/bash
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix rejected an executable SHELL fallback"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr" /bin/bash

new_case Darwin with-herdr gui /bin/sh
CASE_RESOLVE_DSCL=1
CASE_DSCL_FAIL=1
CASE_ENV_SHELL="$CASE_DIR/not-a-shell"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix rejected the POSIX shell fallback"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr" /bin/sh

new_case Darwin with-herdr gui /bin/sh
CASE_RESOLVE_DSCL=1
CASE_DSCL_HANG=1
CASE_ENV_SHELL=/bin/sh
SECONDS=0
doctor --fix
elapsed=$SECONDS
expect_code 0 "$DOCTOR_RC" "--fix did not fall back after a stalled Directory Services lookup"
[ "$elapsed" -lt 10 ] || fail "a stalled Directory Services lookup blocked doctor for ${elapsed}s"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr" /bin/sh
pass "shell resolution bounds Directory Services and uses executable SHELL and POSIX fallbacks"

# --- one shell resolution is shared by render, validation, and reporting ----

new_case Darwin with-herdr gui /bin/sh
CASE_RESOLVE_DSCL=1
doctor --fix
expect_code 0 "$DOCTOR_RC" "initial repair did not install a healthy login-shell agent"
assert_herdr_launch_agent_contract "$CASE_PLIST" "$CASE_BIN/herdr" /bin/sh
: > "$CASE_LAUNCHCTL_LOG"
rm -f "$CASE_STATE/dscl-count"
CASE_SECOND_LOGIN_SHELL=/bin/bash
doctor --fix
expect_code 0 "$DOCTOR_RC" "repeated repair drifted when a second shell lookup would differ"
assert_contains "$DOCTOR_OUT" 'check launchagent=ok:' "the installed login-shell plist was reported as drifted"
assert_contains "$DOCTOR_OUT" 'check launchagent-loaded=ok:' "the loaded login-shell agent was reported as drifted"
[ "$(cat "$CASE_STATE/dscl-count")" = 1 ] || fail "doctor resolved the account login shell more than once"
assert_no_grep '^bootout\|^bootstrap\|^kickstart' "$CASE_LAUNCHCTL_LOG" \
  "repeated repair reloaded an already healthy login-shell agent"
pass "repeated repair reuses one resolved login shell and remains a no-op"

# --- linux has no launch agent, and --fix starts the server directly ---------

new_case Linux with-herdr no-gui
doctor
expect_code 1 "$DOCTOR_RC" "a linux host with a stopped herdr server was reported ready"
assert_contains "$DOCTOR_OUT" 'platform=linux' "the platform was misreported"
assert_contains "$DOCTOR_OUT" 'check launchagent=skip:' "launch agents were checked on linux"
assert_contains "$DOCTOR_OUT" 'check gui-session=skip:' "an Aqua login session was required on linux"
assert_contains "$DOCTOR_OUT" 'check herdr-server=fixable:' "a stopped linux herdr server was not tagged fixable"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not start the herdr server on linux"
assert_contains "$DOCTOR_OUT" 'fix herdr-server=applied:' "--fix did not report starting the server"
assert_contains "$DOCTOR_OUT" 'check herdr-server=ok:' "the started server was not confirmed by the re-check"
[ ! -s "$CASE_LAUNCHCTL_LOG" ] || fail "the linux path invoked launchctl"
pass "a non-darwin host skips launch agents and starts its herdr server directly"

# --- --fix may add only owned wrappers for version-manager tools -------------

new_case Linux with-herdr no-gui
MANAGER_BIN="$CASE_HOME/.nvm/versions/node/v24/bin"
mkdir -p "$MANAGER_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MANAGER_BIN/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MANAGER_BIN/grok"
chmod +x "$MANAGER_BIN/codex" "$MANAGER_BIN/grok"
mv "$CASE_BIN/tasks-axi" "$MANAGER_BIN/tasks-axi"
doctor
expect_code 1 "$DOCTOR_RC" "a version-manager-only required tool was reported ready"
assert_contains "$DOCTOR_OUT" 'required tasks-axi=MISSING' "the missing managed tool was not reported"
assert_contains "$DOCTOR_OUT" 'tools in an unselected nvm version or outside the discovered asdf or mise paths need an absolute wrapper' \
  "the missing-tool diagnostic contradicted filesystem version-manager discovery"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not create a wrapper for the discoverable managed tool"
assert_contains "$DOCTOR_OUT" 'fix required-tasks-axi=applied:' "--fix did not report the owned wrapper"
assert_contains "$DOCTOR_OUT" "required tasks-axi=$CASE_HOME/.local/bin/tasks-axi" \
  "the worker PATH did not resolve the generated wrapper"
assert_grep '# Firstmate remote tool wrapper v1' "$CASE_HOME/.local/bin/tasks-axi" \
  "the generated wrapper is not marked Firstmate-owned"
assert_grep "$MANAGER_BIN/tasks-axi" "$CASE_HOME/.local/bin/tasks-axi" \
  "the generated wrapper does not execute the discovered absolute target"
assert_absent "$CASE_HOME/.local/bin/codex" "--fix wrapped an alternate harness when claude already satisfied readiness"
assert_absent "$CASE_HOME/.local/bin/grok" "--fix wrapped an alternate harness when claude already satisfied readiness"

rm -f "$CASE_BIN/claude"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not wrap one discoverable harness when none resolved"
assert_present "$CASE_HOME/.local/bin/codex" "--fix did not create the first needed harness wrapper"
assert_absent "$CASE_HOME/.local/bin/grok" "--fix created more harness wrappers than readiness requires"

mv "$CASE_BIN/treehouse" "$MANAGER_BIN/treehouse"
mkdir -p "$CASE_HOME/.local/bin"
printf 'operator wrapper\n' > "$CASE_HOME/.local/bin/treehouse"
doctor --fix
expect_code 1 "$DOCTOR_RC" "--fix overwrote an operator-owned reserved wrapper"
assert_contains "$DOCTOR_OUT" 'fix required-treehouse=failed:' \
  "the non-Firstmate wrapper refusal was not reported"
[ "$(cat "$CASE_HOME/.local/bin/treehouse")" = 'operator wrapper' ] \
  || fail "--fix overwrote an operator-owned wrapper"
pass "--fix creates only owned version-manager wrappers and never clobbers an operator file"

new_case Linux with-herdr no-gui
CASE_REMOTE_JOB_ACTIVE=
CASE_PLATFORM_OVERRIDE=Linux
rm -f "$CASE_BIN/sleep" "$CASE_BIN/uname"
mkdir -p "$CASE_HOME/.local/bin"
for tool in herdr tasks-axi treehouse claude; do
  ln -s "$CASE_BIN/$tool" "$CASE_HOME/.local/bin/$tool"
done
HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$ROOT/bin/fm-remote-job-worker.sh" > "$CASE_STATE/worker.out" 2> "$CASE_STATE/worker.err" &
DOCTOR_WORKER_PID=$!
for _ in $(seq 1 100); do
  [ -f "$CASE_HOME/.firstmate/remote-job/worker.ready" ] && break
  sleep 0.05
done
assert_present "$CASE_HOME/.firstmate/remote-job/worker.ready" "the stale-identity fixture worker did not start"
printf 'stale-worker-identity\n' > "$CASE_HOME/.firstmate/remote-job/worker.identity"
doctor
expect_code 1 "$DOCTOR_RC" "doctor accepted a live worker with stale code identity"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=fixable: the running remote job worker does not match the current Firstmate code' \
  "doctor did not classify stale worker identity as fixable"
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=fixable: the remote job worker identity is stale' \
  "doctor probed through stale worker code"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not replace the stale worker identity"
assert_contains "$DOCTOR_OUT" 'fix remote-job-worker=applied:' "--fix did not report refreshing the stale worker"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=ok:' "the refreshed worker was not confirmed ready"
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' \
  "doctor did not probe tools through the refreshed worker"
DOCTOR_WORKER_PID=$(cat "$CASE_HOME/.firstmate/remote-job/worker.pid")
kill -TERM "$DOCTOR_WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null; then
  kill -KILL "$DOCTOR_WORKER_PID" 2>/dev/null || true
fi
DOCTOR_WORKER_PID=
pass "doctor refreshes stale worker identity before probing tools"

# --- the entrypoint symlink is recreated when it is missing ------------------

new_case Linux with-herdr no-gui
REMOTE_ROOT="$CASE_DIR/remote-root"
mkdir -p "$REMOTE_ROOT/bin"
printf '#!/usr/bin/env bash\n' > "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh"
export FM_ROOT_OVERRIDE="$REMOTE_ROOT"
doctor
assert_contains "$DOCTOR_OUT" 'check entrypoint-link=fixable:' "a missing entrypoint symlink was not tagged fixable"
doctor --fix
assert_contains "$DOCTOR_OUT" 'fix entrypoint-link=applied:' "--fix did not report linking the entrypoint"
assert_contains "$DOCTOR_OUT" 'check entrypoint-link=ok:' "the recreated entrypoint symlink was not confirmed"
[ "$(readlink "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh")" = "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" ] \
  || fail "the entrypoint symlink does not point at this code root"
printf 'not a symlink\n' > "$CASE_HOME/.local/bin/other"
rm -f "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh"
printf 'operator wrapper\n' > "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh"
doctor --fix
assert_contains "$DOCTOR_OUT" 'check entrypoint-link=human:' "an operator-owned entrypoint file was not left to the operator"
[ "$(cat "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh")" = 'operator wrapper' ] \
  || fail "--fix overwrote a file it did not create"
unset FM_ROOT_OVERRIDE
pass "the entrypoint symlink is recreated when absent and never overwritten when operator-owned"

