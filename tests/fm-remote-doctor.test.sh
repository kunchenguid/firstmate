#!/usr/bin/env bash
# tests/fm-remote-doctor.test.sh - the remote second-mate readiness gate.
#
# Drives the real bin/fm-remote-doctor.sh against a controlled account fixture:
# a private HOME, a fake launchctl backed by state files, a fake herdr CLI, and
# a fake uname that selects the platform under test. Nothing here touches the
# runner's own launch agents, login session, or herdr server.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the herdr adapter parses its JSON)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-doctor)
LABEL=dev.firstmate.herdr.fm-remote
INTERACTIVE_LABEL=dev.firstmate.herdr
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
JOB_LABEL=dev.firstmate.remote-job
CASE_N=0
DOCTOR_WORKER_PID=
trap 'if [ -n "$DOCTOR_WORKER_PID" ]; then kill "$DOCTOR_WORKER_PID" 2>/dev/null || true; fi; fm_test_cleanup || true' EXIT

# A fixture must be able to present a host with NO herdr, so the doctor never
# sees the runner's own PATH. Only the two required tools are re-exposed, by
# symlink, alongside the system directories the doctor's own helpers need.
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
ln -sf "$(command -v git)" "$TOOLS/git"
ln -sf "$(command -v jq)" "$TOOLS/jq"
BASE_PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

# new_case <Darwin|Linux> [with-herdr] [gui]
# Builds one isolated account fixture and points the module-level CASE_*
# variables at it. "with-herdr" installs the fake herdr CLI; "gui" makes the
# fake launchctl report an existing Aqua login session.
new_case() {
  local platform=$1 want_herdr=${2:-with-herdr} want_gui=${3:-gui}
  unset CASE_REMOTE_JOB_ACTIVE
  unset CASE_PLATFORM_OVERRIDE
  unset CASE_PATH
  CASE_N=$((CASE_N + 1))
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
program = $FM_FAKE_HERDR_BIN
arguments = {
	$FM_FAKE_HERDR_BIN
	server
	--session
	fm-remote
}
stdout path = $FM_FAKE_LAUNCH_AGENT_LOG
stderr path = $FM_FAKE_LAUNCH_AGENT_LOG
properties = keepalive | runatload | inferred program
EOF
        [ -f "$FM_FAKE_STATE/bootstrap-does-not-start" ] || printf 'true\n' > "$FM_FAKE_HERDR_RUNNING"
        ;;
    esac
    exit 0
    ;;
  kickstart)
    [ ! -f "$FM_FAKE_STATE/kickstart-fail" ] || { printf 'Kickstart failed: service unavailable\n' >&2; exit 6; }
    case "$label" in
      dev.firstmate.remote-job) : ;;
      *)
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
    printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":%s}}\n' "$running"
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
  chmod +x "$CASE_BIN/uname" "$CASE_BIN/launchctl" "$CASE_BIN/tasks-axi" "$CASE_BIN/treehouse" "$CASE_BIN/claude"
  cat > "$CASE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE_BIN/sleep"
}

# doctor [args...] -> runs the real doctor against the current fixture,
# capturing merged output in DOCTOR_OUT and its status in DOCTOR_RC.
# A case may set CASE_PATH to present a different invoking PATH - notably one
# without ~/.local/bin, which is what a plain-SSH invocation actually inherits.
doctor() {
  set +e
  # Every case below pins the dedicated fm-remote session the assertions were
  # written for; without this the doctor takes its shared-default session,
  # where the launch-agent and herdr-server checks report skip by design.
  DOCTOR_OUT=$(
    HOME="$CASE_HOME" \
    FM_HOME="$CASE_PROJECT_HOME" \
    FM_REMOTE_HERDR_SESSION=fm-remote \
    PATH="${CASE_PATH:-$CASE_HOME/.local/bin:$CASE_BIN:$BASE_PATH}" \
    FM_FAKE_STATE="$CASE_STATE" \
    FM_FAKE_LAUNCHCTL_LOG="$CASE_LAUNCHCTL_LOG" \
    FM_FAKE_FORBIDDEN_LOG="$CASE_FORBIDDEN_LOG" \
    FM_FAKE_HERDR_RUNNING="$CASE_HERDR_RUNNING" \
    FM_FAKE_HERDR_BIN="$CASE_BIN/herdr" \
    FM_FAKE_PLIST="$CASE_PLIST" \
    FM_FAKE_JOB_PLIST="$CASE_JOB_PLIST" \
    FM_FAKE_JOB_WORKER="$ROOT/bin/fm-remote-job-worker.sh" \
    FM_FAKE_LAUNCH_AGENT_LOG="$CASE_HOME/Library/Logs/$LABEL.log" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE="${CASE_PLATFORM_OVERRIDE-}" \
    FM_REMOTE_JOB_ACTIVE="${CASE_REMOTE_JOB_ACTIVE-1}" \
    "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1
  )
  DOCTOR_RC=$?
  set -e
}

write_loaded_contract() { # <herdr-path> [properties]
  local herdr_bin=$1 properties=${2:-'keepalive | runatload | inferred program'}
  cat > "$CASE_STATE/loaded-$LABEL" <<EOF
path = $CASE_PLIST
program = $herdr_bin
arguments = {
	$herdr_bin
	server
	--session
	fm-remote
}
stdout path = $CASE_HOME/Library/Logs/$LABEL.log
stderr path = $CASE_HOME/Library/Logs/$LABEL.log
properties = $properties
EOF
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
assert_grep '<string>Aqua</string>' "$CASE_PLIST" "the written plist is not Aqua-scoped"
assert_grep "<string>$LABEL</string>" "$CASE_PLIST" "the written plist does not carry the Firstmate label"
assert_grep '<string>server</string>' "$CASE_PLIST" "the written plist does not run a herdr server"
assert_grep '<string>fm-remote</string>' "$CASE_PLIST" "the written plist does not pin the remote-secondmate session"
assert_no_grep '<string>default</string>' "$CASE_PLIST" "the written plist pins the interactive default session"
assert_grep "<string>$JOB_LABEL</string>" "$CASE_JOB_PLIST" "the worker plist does not carry the Firstmate label"
assert_grep '<string>Aqua</string>' "$CASE_JOB_PLIST" "the worker plist is not Aqua-scoped"
assert_grep "$ROOT/bin/fm-remote-job-worker.sh" "$CASE_JOB_PLIST" "the worker plist does not use the configured code root"
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
write_loaded_contract /obsolete/bin/herdr 'runatload | inferred program'
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
assert_grep "<string>$CASE_BIN/herdr</string>" "$CASE_PLIST" "the repaired launch agent does not use the resolved herdr path"
assert_grep '<key>RunAtLoad</key>' "$CASE_PLIST" "the repaired launch agent does not start at login"
assert_grep '<key>KeepAlive</key>' "$CASE_PLIST" "the repaired launch agent is not kept alive"
assert_no_grep '/obsolete/bin/herdr' "$CASE_PLIST" "the obsolete herdr path survived repair"
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
write_loaded_contract /obsolete/bin/herdr 'runatload | inferred program'
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
assert_no_grep 'Background' "$CASE_PLIST" "the Background session scope survived the repair"
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

# --- the beads store check is gated on the home's own backlog backend --------
#
# add_beads_bd <dir> <log>: a fake `bd` that refuses to answer unless something
# pinned BEADS_DIR for it, which is exactly how the real bd behaves when the
# `task` wrapper is missing - it auto-discovers from the working directory,
# finds nothing, and fails. `bootstrap` provisions the pinned store.
add_beads_bd() {
  local dir=$1 log=$2
  cat > "$dir/bd" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
store=\${BEADS_DIR:-}
[ -n "\$store" ] || exit 3
case "\${1:-}" in
  list)
    [ -f "\$store/provisioned" ] || exit 1
    printf '[]\n'
    ;;
  bootstrap)
    mkdir -p "\$store"
    : > "\$store/provisioned"
    ;;
esac
exit 0
SH
  chmod +x "$dir/bd"
}

new_case Darwin with-herdr gui
doctor
assert_contains "$DOCTOR_OUT" 'check beads-store=skip:' \
  "a home that does not select the beads backend was still checked for a store"
doctor --fix
assert_absent "$CASE_HOME/.local/bin/task" \
  "--fix provisioned a task wrapper for a home that does not use the beads backend"
pass "the beads store check skips a home whose backlog backend is not beads"

# --- beads selected with no bd binary is advisory, never a readiness gap -----
#
# A task-store gap says nothing about whether this host can start and supervise
# an agent, and --fix cannot close this one at all because the doctor installs
# no packages. Gating on it would make bin/fm-remote-readiness-lib.sh refuse
# every seed, launch, and liveness relaunch on a host whose route works today.

new_case Darwin with-herdr gui
mkdir -p "$CASE_PROJECT_HOME/config"
printf 'beads\n' > "$CASE_PROJECT_HOME/config/backlog-backend"
doctor
assert_contains "$DOCTOR_OUT" 'check beads-store=info:' \
  "a host with no bd binary was not tagged as an advisory gap"
assert_not_contains "$DOCTOR_OUT" 'check beads-store=human:' \
  "the missing bd binary was still recorded as a gating human gap"
assert_contains "$DOCTOR_OUT" 'action: beads-store:' \
  "an advisory gap came with no operator action"

# --fix closes every OTHER gap on this fixture, so what remains afterwards is
# the store gap alone. That is the case that matters: the host can start and
# supervise an agent, so the readiness verdict must be ready.
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix reported an agent-ready host as unready over its task store"
assert_contains "$DOCTOR_OUT" 'check beads-store=info:' \
  "--fix stopped reporting the missing bd binary"
assert_not_contains "$DOCTOR_OUT" 'fix beads-store=applied' \
  "--fix claimed to have installed beads"
assert_absent "$CASE_HOME/.local/bin/task" \
  "--fix wrote a task wrapper with no bd binary to point it at"
doctor
expect_code 0 "$DOCTOR_RC" "a missing beads store blocked a host that is otherwise ready"
assert_contains "$DOCTOR_OUT" 'ok: remote second-mate readiness confirmed on this host' \
  "the readiness verdict was withheld over a task-store gap"
assert_contains "$DOCTOR_OUT" 'check beads-store=info:' \
  "the still-open store gap stopped being reported once it was advisory"
assert_not_contains "$DOCTOR_OUT" 'repairable-advisory: beads-store' \
  "a gap no repair can close still asked the readiness gate to run a repair pass"
pass "a host with no bd binary is an advisory gap that neither --fix nor readiness pretends to close"

# --- bd present but unpinned is fixable, and --fix provisions the store ------

new_case Darwin with-herdr gui
mkdir -p "$CASE_PROJECT_HOME/config"
printf 'beads\n' > "$CASE_PROJECT_HOME/config/backlog-backend"
BD_LOG="$CASE_STATE/bd.log"
: > "$BD_LOG"
add_beads_bd "$CASE_BIN" "$BD_LOG"
doctor
assert_contains "$DOCTOR_OUT" 'check beads-store=fixable:' \
  "a resolvable bd with no working task CLI was not tagged fixable"
assert_absent "$CASE_HOME/.local/bin/task" \
  "a read-only doctor run wrote a task wrapper"
assert_absent "$CASE_HOME/data/tasks/.beads/provisioned" \
  "a read-only doctor run provisioned a store"
assert_not_contains "$(cat "$BD_LOG")" bootstrap \
  "a read-only doctor run bootstrapped a store"

doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix left a provisionable host unready"
assert_contains "$DOCTOR_OUT" 'fix beads-store=applied:' \
  "--fix did not report provisioning the store"
assert_contains "$DOCTOR_OUT" 'check beads-store=ok:' \
  "--fix did not re-check the provisioned store"
assert_present "$CASE_HOME/.local/bin/task" "--fix did not write the task wrapper"
assert_contains "$(cat "$CASE_HOME/.local/bin/task")" 'BEADS_DIR' \
  "the task wrapper does not pin BEADS_DIR"
assert_contains "$(cat "$BD_LOG")" bootstrap \
  "--fix did not provision the store with the bootstrap verb"
assert_not_contains "$(cat "$BD_LOG")" 'init' \
  "--fix reached for a destructive init instead of bootstrap"
assert_no_dangerous_calls "the doctor reached for auto-login, FileVault, or the keychain"
pass "an unpinned bd is a fixable gap and --fix wraps it and provisions the store non-destructively"

# --- a second --fix is a no-op that never bootstraps over the live store -----

doctor --fix
expect_code 0 "$DOCTOR_RC" "a second --fix reported a healthy host as unready"
assert_contains "$DOCTOR_OUT" 'check beads-store=ok:' \
  "the already-provisioned store was not reported healthy"
[ "$(grep -c bootstrap "$BD_LOG")" = 1 ] \
  || fail "--fix bootstrapped again over a store that already answers"
pass "a repeat --fix leaves a working store alone and never bootstraps over it"

# --- a repairable store gap is non-gating, but still asks to be repaired -----
#
# Continues the fixture above, which --fix has just left fully ready: dropping
# the wrapper reopens the store gap and nothing else, so the readiness verdict
# must still be ready. Otherwise every seed, launch, and liveness relaunch on a
# working route would refuse over a task store the agent runtime never touches.
# Not gating is not the same as not repairing, though, so this run must also
# publish the line the readiness gate repairs on: a host whose only gap is the
# one --fix can close would otherwise keep that gap for as long as it stays
# healthy in every other way.

rm -f "$CASE_HOME/.local/bin/task"
doctor
expect_code 0 "$DOCTOR_RC" "a repairable store gap blocked a host that can start and supervise an agent"
assert_contains "$DOCTOR_OUT" 'check beads-store=fixable:' \
  "the reopened store gap was not reported at all"
assert_contains "$DOCTOR_OUT" 'ok: remote second-mate readiness confirmed on this host' \
  "the readiness verdict was withheld over a repairable task-store gap"
assert_contains "$DOCTOR_OUT" 'repairable-advisory: beads-store' \
  "a non-gating gap --fix can close never asked the readiness gate to repair it"
pass "a repairable store gap is reported and asks for repair without withholding readiness"

# --- the store resolves through ~/.local/bin even when PATH omits it ---------
#
# ~/.local/bin is where this check publishes the wrapper and is always on the
# remote runtime PATH, but a plain-SSH invocation of the doctor routinely
# inherits a PATH without it - the same hole the bd probe already works around.
# Resolving `task` through the bare invoking PATH would make --fix fail to see
# the wrapper it just wrote and report a store it did provision as broken.

new_case Darwin with-herdr gui
mkdir -p "$CASE_PROJECT_HOME/config"
printf 'beads\n' > "$CASE_PROJECT_HOME/config/backlog-backend"
BD_LOG="$CASE_STATE/bd.log"
: > "$BD_LOG"
add_beads_bd "$CASE_BIN" "$BD_LOG"
CASE_PATH="$CASE_BIN:$BASE_PATH"

doctor --fix
assert_contains "$DOCTOR_OUT" 'fix beads-store=applied:' \
  "--fix did not publish the wrapper when ~/.local/bin was off PATH"
assert_not_contains "$DOCTOR_OUT" 'fix beads-store=failed:' \
  "--fix could not see the wrapper it had just written"
assert_contains "$(cat "$BD_LOG")" bootstrap \
  "--fix skipped provisioning because the fresh wrapper did not resolve"
assert_contains "$DOCTOR_OUT" 'check beads-store=ok:' \
  "a store provisioned behind ~/.local/bin was still reported unreachable"

doctor
expect_code 0 "$DOCTOR_RC" "a healthy store behind ~/.local/bin left the host unready"
assert_contains "$DOCTOR_OUT" 'check beads-store=ok:' \
  "a read-only run could not see a healthy store through ~/.local/bin"
pass "the beads store resolves through ~/.local/bin even when the invoking PATH omits it"

# --- an operator-owned task wrapper is never overwritten, and never repairable
#
# The repair refuses this wrapper by policy, so calling the gap repairable would
# make the readiness gate pay a repair pass and a re-check on every seed, launch,
# and liveness relaunch for a condition that can never converge. It is therefore
# classified informational: still reported, still non-gating, still never
# overwritten, but never advertised to the gate as something a repair can close.

new_case Darwin with-herdr gui
mkdir -p "$CASE_PROJECT_HOME/config" "$CASE_HOME/.local/bin"
printf 'beads\n' > "$CASE_PROJECT_HOME/config/backlog-backend"
BD_LOG="$CASE_STATE/bd.log"
: > "$BD_LOG"
add_beads_bd "$CASE_BIN" "$BD_LOG"
printf '#!/usr/bin/env bash\n# operator wrapper\nexit 1\n' > "$CASE_HOME/.local/bin/task"
chmod +x "$CASE_HOME/.local/bin/task"

doctor --fix
assert_not_contains "$DOCTOR_OUT" 'fix beads-store=' \
  "--fix attempted a repair it is forbidden to complete"
assert_contains "$(cat "$CASE_HOME/.local/bin/task")" 'operator wrapper' \
  "--fix overwrote a task wrapper it did not create"
assert_not_contains "$(cat "$BD_LOG")" bootstrap \
  "--fix bootstrapped a store behind an operator-owned wrapper it could not verify"

doctor
expect_code 0 "$DOCTOR_RC" \
  "an operator-owned task wrapper withheld the verdict on an otherwise ready host"
assert_contains "$DOCTOR_OUT" 'check beads-store=info:' \
  "a store gap the repair refuses by policy was not reported informational"
assert_not_contains "$DOCTOR_OUT" 'check beads-store=fixable:' \
  "a gap fix_beads_store always refuses was still advertised as fixable"
assert_not_contains "$DOCTOR_OUT" 'repairable-advisory: beads-store' \
  "an unrepairable wrapper still asked the readiness gate to run a repair pass"
assert_contains "$DOCTOR_OUT" 'action: beads-store:' \
  "the informational wrapper gap came with no operator action"
pass "an operator-owned task wrapper is informational and never overwritten, repaired, or re-tried"

# --- the readiness gate repairs a non-gating gap it does not gate on ---------
#
# The doctor deliberately exits 0 over a store gap, and the gate used to run its
# --fix pass only on a non-zero read-only run. Together that made the automatic
# provisioning path reachable solely on hosts broken in some OTHER way: a host
# whose only gap was the one --fix closes would keep it forever. The gate now
# repairs on the doctor's `repairable-advisory:` line as well, which is what
# these three cases fix in place. bin/fm-remote-doctor.sh above is the real
# publisher of that line; the stub here only replays it so the gate's own
# sequencing is what gets exercised.

# shellcheck source=bin/fm-remote-readiness-lib.sh
. "$ROOT/bin/fm-remote-readiness-lib.sh"

RG_BIN="$TMP_ROOT/readiness/bin"
export FM_RG_STATE="$TMP_ROOT/readiness/state"
export FM_RG_LOG="$FM_RG_STATE/fm-on.log"
mkdir -p "$RG_BIN" "$FM_RG_STATE"
cat > "$RG_BIN/fm-on.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_RG_LOG"
case " $* " in
  *' --fix '*)
    [ -f "$FM_RG_STATE/fix-fails" ] || touch "$FM_RG_STATE/repaired"
    printf 'fix beads-store=applied: wrote the task wrapper\n'
    exit 0
    ;;
esac
if [ ! -f "$FM_RG_STATE/advisory" ] || [ -f "$FM_RG_STATE/repaired" ]; then
  printf 'check beads-store=ok: the task CLI answers a read\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
printf 'check beads-store=fixable: bd resolves but the task CLI does not answer\n'
printf 'action: beads-store: rerun with --fix\n'
printf 'repairable-advisory: beads-store\n'
printf 'ok: remote second-mate readiness confirmed on this host\n'
exit 0
SH
chmod +x "$RG_BIN/fm-on.sh"

# rg_reset [advisory] [fix-fails]: start a fresh readiness fixture.
rg_reset() {
  rm -f "$FM_RG_STATE"/*
  : > "$FM_RG_LOG"
  for marker in "$@"; do touch "$FM_RG_STATE/$marker"; done
}

rg_reset advisory
RG_RC=0
fm_remote_readiness_ensure "$RG_BIN" sm-advisory || RG_RC=$?
expect_code 0 "$RG_RC" "a host whose only gap does not gate readiness was reported unready"
[ "$(wc -l < "$FM_RG_LOG" | tr -d ' ')" = 3 ] \
  || fail "the gate did not run check, repair, re-check over a repairable advisory: $(cat "$FM_RG_LOG")"
assert_contains "$(sed -n 2p "$FM_RG_LOG")" '--fix' \
  "the gate skipped its repair pass because the read-only run had already exited 0"
assert_not_contains "$FM_REMOTE_READINESS_OUT" 'repairable-advisory:' \
  "the gate reported a verdict that still carried the gap its repair pass closed"
pass "the readiness gate repairs a non-gating gap the doctor exits 0 over"

rg_reset
RG_RC=0
fm_remote_readiness_ensure "$RG_BIN" sm-clean || RG_RC=$?
expect_code 0 "$RG_RC" "a fully healthy host was reported unready"
[ "$(wc -l < "$FM_RG_LOG" | tr -d ' ')" = 1 ] \
  || fail "the gate ran a repair pass on a host with nothing to repair: $(cat "$FM_RG_LOG")"
pass "the readiness gate still runs no repair pass on a host with nothing to repair"

rg_reset advisory fix-fails
RG_RC=0
fm_remote_readiness_ensure "$RG_BIN" sm-unrepaired || RG_RC=$?
expect_code 0 "$RG_RC" "a failed repair of a non-gating gap withheld the readiness verdict"
assert_contains "$FM_REMOTE_READINESS_OUT" 'repairable-advisory: beads-store' \
  "the still-open gap stopped being reported once the repair failed"
pass "a non-gating gap that repair could not close still never withholds readiness"
