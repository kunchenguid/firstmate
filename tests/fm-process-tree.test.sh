#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Focused lifecycle regressions for the generic bounded process-tree runner.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib.sh disable=SC1091
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-process-tree-lib.sh
. "$ROOT/bin/fm-process-tree-lib.sh"

fm_test_tmproot_into TMP fm-process-tree-tests
REAL_PS=$(command -v ps)
ACTIVE_CASE=
ACTIVE_CALLER=
ACTIVE_CONTROLLER=
ACTIVE_ANCHOR=
ACTIVE_COMMAND=
ACTIVE_PS=

owned_process_command() {
  local process_id=$1
  "$REAL_PS" -o command= -p "$process_id" 2>/dev/null || true
}

kill_owned_process() {
  local process_id=$1 marker=$2 command
  [ -n "$process_id" ] || return 0
  command=$(owned_process_command "$process_id")
  case "$command" in
    *"$marker"*) kill -KILL "$process_id" 2>/dev/null || true ;;
  esac
}

cleanup() {
  local marker=${ACTIVE_CASE:-$TMP}
  [ -z "$ACTIVE_CASE" ] || : > "$ACTIVE_CASE/ps.release"
  kill_owned_process "$ACTIVE_COMMAND" "$marker"
  kill_owned_process "$ACTIVE_PS" "$marker"
  kill_owned_process "$ACTIVE_CONTROLLER" "$marker"
  kill_owned_process "$ACTIVE_ANCHOR" "$marker"
  kill_owned_process "$ACTIVE_CALLER" "$marker"
  [ -z "$ACTIVE_CALLER" ] || wait "$ACTIVE_CALLER" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

wait_for_file() {
  local path=$1 owner=${2:-} count=0
  while [ ! -e "$path" ] && [ "$count" -lt 400 ]; do
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      fail "fixture owner $owner exited before $path appeared"
    fi
    sleep 0.01
    count=$((count + 1))
  done
  [ -e "$path" ] || fail "fixture did not create $path"
}

wait_for_exact_exit() {
  local process_id=$1 label=$2
  if python3 - "$process_id" <<'PY'
import os
import sys
import time

process_id = int(sys.argv[1])
deadline = time.monotonic() + 2.0
while True:
    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        raise SystemExit(0)
    except PermissionError:
        pass
    if time.monotonic() >= deadline:
        raise SystemExit(1)
    time.sleep(0.01)
PY
  then
    return 0
  fi
  fail "$label did not exit within two seconds: pid=$process_id row=$("$REAL_PS" -o pid=,ppid=,pgid=,state=,command= -p "$process_id" 2>/dev/null || true)"
}

children_of() {
  local parent=$1
  "$REAL_PS" -axo pid=,ppid= | awk -v parent="$parent" '$2 == parent { print $1 }'
}

assert_group_absent() {
  local group=$1 label=$2 members
  members=$("$REAL_PS" -axo pid=,ppid=,pgid= | awk -v group="$group" '$3 == group { print $1 ":" $2 }')
  [ -z "$members" ] || fail "$label left process group $group behind: $members"
}

assert_no_runner_channels() {
  local case_dir=$1 count
  count=$(find "$case_dir" -type f -name 'fm-process-tree-*' | wc -l | tr -d '[:space:]')
  [ "$count" -eq 0 ] || fail "bounded runner left $count temporary channels under $case_dir"
}

write_controller_fixture() {
  local fixture=$TMP/controller-fixture.sh
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
set -u
root=$1
case_dir=$2
real_ps=$3
export TMPDIR=$case_dir
export FM_PROCESS_TREE_GUARD_FILE=$case_dir/process-group.guard
export FM_PROCESS_TREE_PS_ENTERED_FILE=$case_dir/ps.entered
export FM_PROCESS_TREE_PS_RELEASE_FILE=$case_dir/ps.release
export FM_PROCESS_TREE_PS_PID_FILE=$case_dir/ps.pid
export FM_PROCESS_TREE_REAL_PS=$real_ps
export PATH=$case_dir/fakebin:$PATH
# shellcheck source=bin/fm-process-tree-lib.sh
. "$root/bin/fm-process-tree-lib.sh"
status=0
fm_run_bounded 30 sh -c '
  printf "%s\n" "$$" > "$1"
  IFS= read -r _ < "$2"
  exit 23
' sh "$case_dir/command.pid" "$case_dir/command.release" || status=$?
printf '%s\t%s\n' "$status" "$FM_PROCESS_TREE_CLEANUP_STATUS" > "$case_dir/outcome"
exit 0
SH
  chmod +x "$fixture"
  printf '%s\n' "$fixture"
}

start_status_available_fixture() {
  local case_dir=$1 fixture controller_parent
  mkdir -p "$case_dir/fakebin"
  mkfifo "$case_dir/command.release"
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$*" = '-axo pid=,pgid=' ]; then
  group=$(cat "$FM_PROCESS_TREE_GUARD_FILE")
  printf '%s %s\n' "$group" "$group"
  printf '%s\n' "$$" > "$FM_PROCESS_TREE_PS_PID_FILE"
  : > "$FM_PROCESS_TREE_PS_ENTERED_FILE"
  while [ ! -e "$FM_PROCESS_TREE_PS_RELEASE_FILE" ]; do
    sleep 0.01
  done
  exit 0
fi
exec "$FM_PROCESS_TREE_REAL_PS" "$@"
SH
  chmod +x "$case_dir/fakebin/ps"
  fixture=$(write_controller_fixture)
  ACTIVE_CASE=$case_dir
  "$fixture" "$ROOT" "$case_dir" "$REAL_PS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" &
  ACTIVE_CALLER=$!
  wait_for_file "$case_dir/process-group.guard" "$ACTIVE_CALLER"
  wait_for_file "$case_dir/command.pid" "$ACTIVE_CALLER"
  ACTIVE_ANCHOR=$(cat "$case_dir/process-group.guard")
  ACTIVE_COMMAND=$(cat "$case_dir/command.pid")
  ACTIVE_CONTROLLER=$("$REAL_PS" -o ppid= -p "$ACTIVE_ANCHOR" | tr -d '[:space:]')
  controller_parent=$("$REAL_PS" -o ppid= -p "$ACTIVE_CONTROLLER" | tr -d '[:space:]')
  [ "$controller_parent" = "$ACTIVE_CALLER" ] \
    || fail "fixture controller $ACTIVE_CONTROLLER is not owned by caller $ACTIVE_CALLER"
  [ "$("$REAL_PS" -o pgid= -p "$ACTIVE_ANCHOR" | tr -d '[:space:]')" = "$ACTIVE_ANCHOR" ] \
    || fail "fixture anchor $ACTIVE_ANCHOR does not own its process group"

  printf 'finish\n' > "$case_dir/command.release"
  wait_for_file "$case_dir/ps.entered" "$ACTIVE_CONTROLLER"
  ACTIVE_PS=$(cat "$case_dir/ps.pid")
  ! kill -0 "$ACTIVE_COMMAND" 2>/dev/null \
    || fail "status handshake started before command $ACTIVE_COMMAND was reaped"
  [ -z "$(children_of "$ACTIVE_ANCHOR")" ] \
    || fail "anchor $ACTIVE_ANCHOR still had a live command child after status became available"
}

clear_active_fixture() {
  ACTIVE_CASE=
  ACTIVE_CALLER=
  ACTIVE_CONTROLLER=
  ACTIVE_ANCHOR=
  ACTIVE_COMMAND=
  ACTIVE_PS=
}

test_finish_pipe_eof_exits_exact_orphaned_anchor() {
  local case_dir=$TMP/finish-eof anchor controller caller fixture_ps
  start_status_available_fixture "$case_dir"
  anchor=$ACTIVE_ANCHOR
  controller=$ACTIVE_CONTROLLER
  caller=$ACTIVE_CALLER
  fixture_ps=$ACTIVE_PS

  # The concrete failure is a childless anchor adopted by PID 1 after its only
  # finish-pipe writer disappears before sending F.
  kill -KILL "$controller"
  : > "$case_dir/ps.release"
  wait_for_exact_exit "$fixture_ps" "fixture ps blocker"
  ACTIVE_PS=
  wait_for_exact_exit "$anchor" "finish-pipe EOF anchor"
  ACTIVE_ANCHOR=
  wait_for_exact_exit "$caller" "fixture caller"
  wait "$caller" 2>/dev/null || true
  ACTIVE_CALLER=
  assert_group_absent "$anchor" "finish-pipe EOF cleanup"
  assert_no_runner_channels "$case_dir"
  [ "$(cat "$case_dir/process-group.guard")" = "$anchor" ] \
    || fail "controller loss changed the retained exact guard identity"
  clear_active_fixture
  pass "finish-pipe EOF exits the exact childless anchor without a PPID-1 group"
}

test_signal_after_command_reap_does_not_hang() {
  local case_dir=$TMP/no-child-signal anchor controller caller
  start_status_available_fixture "$case_dir"
  anchor=$ACTIVE_ANCHOR
  controller=$ACTIVE_CONTROLLER
  caller=$ACTIVE_CALLER

  kill -TERM "$controller"
  : > "$case_dir/ps.release"
  wait_for_exact_exit "$caller" "signalled no-child bounded call"
  wait "$caller" 2>/dev/null || true
  ACTIVE_CALLER=
  wait_for_exact_exit "$anchor" "signalled no-child anchor"
  ACTIVE_ANCHOR=
  assert_group_absent "$anchor" "signalled no-child cleanup"
  wait_for_file "$case_dir/outcome"
  [ "$(cat "$case_dir/outcome")" = $'143\tverified' ] \
    || fail "no-child signal did not preserve signal status and verified cleanup: $(cat "$case_dir/outcome")"
  [ ! -e "$case_dir/process-group.guard" ] \
    || fail "verified no-child signal cleanup retained its guard"
  assert_no_runner_channels "$case_dir"
  clear_active_fixture
  pass "a signal after command reap exits promptly with verified cleanup"
}

test_real_bounded_path_preserves_status_and_cleans_live_commands() {
  local status=0 case_dir=$TMP/end-to-end command_pid group record
  mkdir -p "$case_dir"
  TMPDIR=$case_dir
  export TMPDIR

  fm_run_bounded 2 sh -c 'exit 47' || status=$?
  [ "$status" -eq 47 ] || fail "bounded runner changed command status 47 to $status"
  [ "$FM_PROCESS_TREE_CLEANUP_STATUS" = verified ] \
    || fail "normal status propagation did not verify cleanup"

  status=0
  # shellcheck disable=SC2016 # The Perl source owns its variables.
  fm_run_bounded 1 perl -MPOSIX=getpgrp -e '
    $SIG{TERM} = "IGNORE";
    open my $file, ">", $ARGV[0] or exit 90;
    print {$file} "$$ ", getpgrp(), "\n";
    close $file;
    select undef, undef, undef, 30;
  ' "$case_dir/kill.pid" || status=$?
  [ "$status" -eq 124 ] || fail "bounded live-command timeout returned $status instead of 124"
  [ "$FM_PROCESS_TREE_CLEANUP_STATUS" = verified ] \
    || fail "TERM/KILL cleanup of the live owned command was not verified"
  record=$(cat "$case_dir/kill.pid")
  command_pid=${record%% *}
  group=${record#* }
  [ -n "$command_pid" ] && [ -n "$group" ] \
    || fail "TERM/KILL fixture did not record its command and group"
  assert_group_absent "$group" "TERM/KILL timeout"
  assert_no_runner_channels "$case_dir"
  pass "real fm_run_bounded preserves status and cleans a TERM-resistant owned command"
}

test_finish_pipe_eof_exits_exact_orphaned_anchor
test_signal_after_command_reap_does_not_hang
test_real_bounded_path_preserves_status_and_cleans_live_commands
printf 'fm-process-tree tests passed\n'
