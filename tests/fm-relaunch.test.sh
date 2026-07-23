#!/usr/bin/env bash
# fm-relaunch.sh: on-demand session-resume LaunchAgent.
#
# The entire safety property of this tool is "registered but never
# self-triggering" - a regression that adds RunAtLoad/StartInterval/
# StartCalendarInterval/a watch key would silently turn it into an
# auto-scheduler, which is exactly what the captain does not want. Every test
# here runs against fake HOME/launchctl/osascript/id/uname stubs so it never
# touches the real machine's launchd namespace.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN="$ROOT/bin/fm-relaunch.sh"

assert_present "$BIN" "bin/fm-relaunch.sh is missing"
[ -x "$BIN" ] || fail "bin/fm-relaunch.sh must be executable"

# fm_relaunch_case <name> -> sets up a fake HOME/PATH world and echoes it as
# "<dir>\t<fm_home>"; the caller runs "$BIN" with FM_HOME="$fm_home" and
# PATH="$dir/fakebin:$PATH" and HOME="$dir/home".
fm_relaunch_case() {
  local name=$1 dir fakebin home fm_home
  dir=$(fm_test_tmproot "fm-relaunch-$name")
  fakebin="$dir/fakebin"
  home="$dir/home"
  fm_home="$dir/fmhome"
  mkdir -p "$fakebin" "$home/Library/LaunchAgents" "$fm_home/state"

  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Darwin
SH

  cat > "$fakebin/id" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 501
SH

  # Fake launchctl: tracks "loaded" state in a marker file next to the plist so
  # bootstrap/bootout/print/kickstart behave consistently across calls within
  # one test, without ever touching a real launchd domain.
  cat > "$fakebin/launchctl" <<'SH'
#!/usr/bin/env bash
LOADED_DIR="${FM_RELAUNCH_TEST_LOADED_DIR:?}"
mkdir -p "$LOADED_DIR"
case "$1" in
  bootstrap)
    label=$(awk '/<key>Label<\/key>/{getline; gsub(/.*<string>|<\/string>.*/,""); print; exit}' "$3")
    : > "$LOADED_DIR/$label"
    exit 0
    ;;
  bootout)
    label=${2##*/}
    rm -f -- "$LOADED_DIR/$label"
    exit 0
    ;;
  print)
    label=${2##*/}
    [ -f "$LOADED_DIR/$label" ] && exit 0
    exit 1
    ;;
  kickstart)
    label=${3##*/}
    if [ -f "$LOADED_DIR/$label" ]; then
      printf '%s\n' kickstart >> "${FM_RELAUNCH_TEST_FIRE_LOG:-/dev/null}"
      exit 0
    fi
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
SH

  cat > "$fakebin/osascript" <<'SH'
#!/usr/bin/env bash
printf '%s\n' osascript-called >> "${FM_RELAUNCH_TEST_OSASCRIPT_LOG:-/dev/null}"
exit 0
SH

  chmod +x "$fakebin/uname" "$fakebin/id" "$fakebin/launchctl" "$fakebin/osascript"
  printf '%s\t%s\t%s\t%s\n' "$dir" "$fm_home" "$home" "$fakebin"
}

# fm_relaunch_run <dir> <fm_home> <home> <fakebin> <args...>
# FM_ROOT_OVERRIDE is pinned to fm_home so this case's FM_HOME reads as the
# default (unoverridden) primary home and claims the bare
# dev.firstmate.relaunch label; test_nondefault_home_gets_a_distinct_label
# deliberately diverges FM_HOME from FM_ROOT_OVERRIDE to exercise the other
# branch.
fm_relaunch_run() {
  local dir=$1 fm_home=$2 home=$3 fakebin=$4
  shift 4
  FM_RELAUNCH_TEST_LOADED_DIR="$dir/loaded" \
    FM_RELAUNCH_TEST_FIRE_LOG="$dir/fire.log" \
    FM_RELAUNCH_TEST_OSASCRIPT_LOG="$dir/osascript.log" \
    FM_ROOT_OVERRIDE="$fm_home" FM_HOME="$fm_home" HOME="$home" PATH="$fakebin:$PATH" \
    "$BIN" "$@"
}

test_help_lists_subcommands() {
  local out
  out=$(FM_HOME=/nonexistent "$BIN" --help)
  assert_contains "$out" "install" "help must list install"
  assert_contains "$out" "status" "help must list status"
  assert_contains "$out" "uninstall" "help must list uninstall"
  assert_contains "$out" "run" "help must list run"
  pass "help lists install/status/uninstall/run"
}

test_unknown_subcommand_fails() {
  local rc=0
  FM_HOME=/nonexistent "$BIN" bogus >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown subcommand must exit 2 (got $rc)"
  pass "unknown subcommand exits 2"
}

test_non_macos_fails_closed() {
  local case_out dir fm_home home fakebin rc=0
  case_out=$(fm_relaunch_case nonmac)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
SH
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "install on a non-macOS platform must fail closed (got $rc)"
  pass "non-macOS platform fails closed rather than silently doing nothing"
}

test_install_never_writes_an_auto_trigger_key() {
  local case_out dir fm_home home fakebin plist
  case_out=$(fm_relaunch_case notrigger)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "install failed"
  plist="$home/Library/LaunchAgents/dev.firstmate.relaunch.plist"
  assert_present "$plist" "install must write a plist at the default label path"
  for key in RunAtLoad StartInterval StartCalendarInterval WatchPaths QueueDirectories KeepAlive; do
    assert_no_grep "<key>$key</key>" "$plist" \
      "generated plist must never declare $key - that would make the job self-trigger"
  done
  pass "generated plist never declares an automatic-trigger key"
}

test_status_confirms_installed_and_no_trigger() {
  local case_out dir fm_home home fakebin out
  case_out=$(fm_relaunch_case statusok)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "install failed"
  out=$(fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" status) \
    || fail "status must exit 0 once installed and loaded"
  assert_contains "$out" "no automatic trigger key present" "status must self-check for trigger keys"
  assert_contains "$out" "loaded" "status must report loaded state"
  pass "status confirms installed, loaded, and free of auto-trigger keys"
}

test_status_before_install_reports_not_installed() {
  local case_out dir fm_home home fakebin rc=0
  case_out=$(fm_relaunch_case statusmissing)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" status >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "status must fail when nothing is installed"
  pass "status reports failure when not yet installed"
}

test_install_is_idempotent() {
  local case_out dir fm_home home fakebin plist sum1 sum2
  case_out=$(fm_relaunch_case idempotent)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  plist="$home/Library/LaunchAgents/dev.firstmate.relaunch.plist"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "first install failed"
  sum1=$(cksum < "$plist")
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "second install failed"
  sum2=$(cksum < "$plist")
  [ "$sum1" = "$sum2" ] || fail "repeated install must converge to the same plist bytes"
  [ -f "$dir/loaded/dev.firstmate.relaunch" ] || fail "job must remain loaded after a repeated install"
  pass "install run twice converges safely with no duplicate/diverging plist"
}

test_run_kickstarts_the_installed_job() {
  local case_out dir fm_home home fakebin
  case_out=$(fm_relaunch_case runfires)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "install failed"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" run >/dev/null \
    || fail "run must succeed once installed"
  assert_grep kickstart "$dir/fire.log" "run must fire the job via launchctl kickstart"
  pass "run fires the installed job on demand via launchctl kickstart"
}

test_run_without_install_fails() {
  local case_out dir fm_home home fakebin rc=0
  case_out=$(fm_relaunch_case rununinstalled)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" run >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "run must refuse when the job was never installed"
  pass "run refuses when the job is not installed"
}

test_uninstall_removes_plist_and_unloads() {
  local case_out dir fm_home home fakebin plist
  case_out=$(fm_relaunch_case uninstall)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  plist="$home/Library/LaunchAgents/dev.firstmate.relaunch.plist"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "install failed"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" uninstall >/dev/null \
    || fail "uninstall failed"
  assert_absent "$plist" "uninstall must remove the plist"
  [ ! -f "$dir/loaded/dev.firstmate.relaunch" ] || fail "uninstall must unload the job"
  pass "uninstall unloads and removes the plist cleanly"
}

test_status_after_uninstall_reports_not_installed() {
  local case_out dir fm_home home fakebin rc=0
  case_out=$(fm_relaunch_case statusafteruninstall)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" install >/dev/null \
    || fail "install failed"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" uninstall >/dev/null \
    || fail "uninstall failed"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" status >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "status must report failure after uninstall"
  pass "status reports not-installed after uninstall"
}

test_nondefault_home_gets_a_distinct_label() {
  local case_out dir fm_home home fakebin default_plist other_home
  case_out=$(fm_relaunch_case distinctlabel)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  # FM_ROOT_OVERRIDE stays pinned to fm_home (the "primary home" for this
  # case); pointing FM_HOME at a genuinely different directory (a secondmate
  # home) must produce a distinctly-suffixed label instead of colliding with
  # the primary home's bare dev.firstmate.relaunch label.
  other_home="$fm_home/other-home"
  mkdir -p "$other_home/state"
  default_plist="$home/Library/LaunchAgents/dev.firstmate.relaunch.plist"
  FM_RELAUNCH_TEST_LOADED_DIR="$dir/loaded" \
    FM_RELAUNCH_TEST_FIRE_LOG="$dir/fire.log" \
    FM_RELAUNCH_TEST_OSASCRIPT_LOG="$dir/osascript.log" \
    FM_ROOT_OVERRIDE="$fm_home" FM_HOME="$other_home" HOME="$home" PATH="$fakebin:$PATH" \
    "$BIN" install >/dev/null \
    || fail "install for a non-default home failed"
  assert_absent "$default_plist" "a non-default FM_HOME must not claim the bare dev.firstmate.relaunch label"
  local suffixed=("$home/Library/LaunchAgents"/dev.firstmate.relaunch.*.plist)
  [ -f "${suffixed[0]:-}" ] \
    || fail "a non-default FM_HOME must get a distinctly-suffixed label"
  pass "a home with an explicit FM_HOME gets a distinct label from the primary home"
}

test_fire_drives_terminal_via_osascript() {
  local case_out dir fm_home home fakebin
  case_out=$(fm_relaunch_case fire)
  IFS=$'\t' read -r dir fm_home home fakebin <<<"$case_out"
  fm_relaunch_run "$dir" "$fm_home" "$home" "$fakebin" fire >/dev/null \
    || fail "fire must succeed"
  assert_grep osascript-called "$dir/osascript.log" "fire must drive the terminal/claude/message handshake through osascript"
  pass "fire opens a terminal and drives the kickoff handshake through osascript"
}

test_help_lists_subcommands
test_unknown_subcommand_fails
test_non_macos_fails_closed
test_install_never_writes_an_auto_trigger_key
test_status_confirms_installed_and_no_trigger
test_status_before_install_reports_not_installed
test_install_is_idempotent
test_run_kickstarts_the_installed_job
test_run_without_install_fails
test_uninstall_removes_plist_and_unloads
test_status_after_uninstall_reports_not_installed
test_nondefault_home_gets_a_distinct_label
test_fire_drives_terminal_via_osascript
