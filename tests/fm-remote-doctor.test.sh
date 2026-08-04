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
LABEL=dev.firstmate.herdr
CASE_N=0

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
  CASE_N=$((CASE_N + 1))
  CASE_DIR="$TMP_ROOT/case$CASE_N"
  CASE_BIN="$CASE_DIR/bin"
  CASE_HOME="$CASE_DIR/home"
  CASE_STATE="$CASE_DIR/state"
  CASE_LAUNCHCTL_LOG="$CASE_STATE/launchctl.log"
  CASE_FORBIDDEN_LOG="$CASE_STATE/forbidden.log"
  CASE_HERDR_RUNNING="$CASE_STATE/herdr.running"
  CASE_PLIST="$CASE_HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$CASE_BIN" "$CASE_HOME" "$CASE_STATE"
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
case "${1:-}" in
  print)
    case "$domain" in
      */*/*) [ -f "$FM_FAKE_STATE/loaded" ] || exit 113 ;;
      *) [ -f "$FM_FAKE_STATE/gui-session" ] || exit 113 ;;
    esac
    exit 0
    ;;
  bootout) rm -f "$FM_FAKE_STATE/loaded"; exit 0 ;;
  bootstrap)
    # launchd refuses a gui/<uid> domain that has no login session.
    [ -f "$FM_FAKE_STATE/gui-session" ] || { printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 5; }
    touch "$FM_FAKE_STATE/loaded"
    printf 'true\n' > "$FM_FAKE_HERDR_RUNNING"
    exit 0
    ;;
  kickstart) printf 'true\n' > "$FM_FAKE_HERDR_RUNNING"; exit 0 ;;
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
  chmod +x "$CASE_BIN/uname" "$CASE_BIN/launchctl"
}

# doctor [args...] -> runs the real doctor against the current fixture,
# capturing merged output in DOCTOR_OUT and its status in DOCTOR_RC.
doctor() {
  set +e
  DOCTOR_OUT=$(
    HOME="$CASE_HOME" \
    PATH="$CASE_BIN:$BASE_PATH" \
    FM_FAKE_STATE="$CASE_STATE" \
    FM_FAKE_LAUNCHCTL_LOG="$CASE_LAUNCHCTL_LOG" \
    FM_FAKE_FORBIDDEN_LOG="$CASE_FORBIDDEN_LOG" \
    FM_FAKE_HERDR_RUNNING="$CASE_HERDR_RUNNING" \
    "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1
  )
  DOCTOR_RC=$?
  set -e
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
doctor
expect_code 1 "$DOCTOR_RC" "a host with no launch agent was reported ready"
assert_contains "$DOCTOR_OUT" 'check herdr=ok:' "the fake herdr CLI was not detected"
assert_contains "$DOCTOR_OUT" 'check gui-session=ok:' "an existing login session was not detected"
assert_contains "$DOCTOR_OUT" 'check launchagent=fixable:' "an absent launch agent was not tagged fixable"
assert_contains "$DOCTOR_OUT" "$LABEL.plist" "the gap did not name the launch agent path"
assert_contains "$DOCTOR_OUT" 'check herdr-server=fixable:' "a stopped herdr server was not tagged fixable"
assert_absent "$CASE_PLIST" "a read-only doctor run installed a launch agent"
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
assert_present "$CASE_PLIST" "--fix reported success without writing the plist"
assert_grep '<string>Aqua</string>' "$CASE_PLIST" "the written plist is not Aqua-scoped"
assert_grep "<string>$LABEL</string>" "$CASE_PLIST" "the written plist does not carry the Firstmate label"
assert_grep '<string>server</string>' "$CASE_PLIST" "the written plist does not run a herdr server"
assert_grep "gui/$(id -u)" "$CASE_LAUNCHCTL_LOG" "the launch agent was not bootstrapped into the GUI domain"
assert_no_dangerous_calls "the repair reached for auto-login, FileVault, or the keychain"
pass "--fix installs, Aqua-scopes, loads, and starts the Firstmate herdr launch agent"

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
assert_contains "$DOCTOR_OUT" 'check launchagent=ok:' "an existing plist was reported absent"
assert_contains "$DOCTOR_OUT" 'check launchagent-scope=fixable:' "a non-Aqua session scope was not tagged fixable"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix could not re-scope an existing launch agent"
assert_contains "$DOCTOR_OUT" 'check launchagent-scope=ok: LimitLoadToSessionType=Aqua' \
  "--fix did not re-scope the launch agent to Aqua"
assert_no_grep 'Background' "$CASE_PLIST" "the Background session scope survived the repair"
pass "a launch agent outside the Aqua session scope is rewritten in place"

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
