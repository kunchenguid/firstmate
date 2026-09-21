#!/usr/bin/env bash
# Behavior tests for bin/fm-openviking-retire.sh.
#
# launchctl, pgrep, pkill, and curl are PATH/env shims; the OV home is a
# fixture dir. The test asserts the bootout/disable sequence, process kill,
# log rotation, verification, dry-run, and the nothing-to-do path - no real
# launchd or process is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ov-retire)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
OV_HOME_DIR="$TMP_ROOT/ov"
CALLS="$TMP_ROOT/calls.log"
LABELS="$TMP_ROOT/labels"
mkdir -p "$OV_HOME_DIR/logs" "$OV_HOME_DIR/data"

# Fake launchctl: `list` prints the labels fixture (header + labels) minus
# anything already booted out; `bootout <label>` removes it; `disable` and
# `enable` are recorded no-ops.
cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
printf 'launchctl %s\n' "$*" >> "${CALLS_LOG:?}"
case "${1:-}" in
  list)
    printf 'PID\tStatus\tLabel\n'
    [ -f "${LABELS_FILE:?}" ] && cat "$LABELS_FILE"
    ;;
  bootout)
    label=${2##*/}
    if [ -f "${LABELS_FILE:?}" ]; then
      grep -v "$label" "$LABELS_FILE" > "$LABELS_FILE.tmp" || true
      mv "$LABELS_FILE.tmp" "$LABELS_FILE"
    fi
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/launchctl"

# Fake pgrep: exit 0 while the pid file exists.
cat > "$FAKEBIN/pgrep" <<'SH'
#!/usr/bin/env bash
printf 'pgrep %s\n' "$*" >> "${CALLS_LOG:?}"
[ -f "${OV_PIDS:?}" ]
SH
chmod +x "$FAKEBIN/pgrep"

# Fake pkill: removes the pid file (the process dies).
cat > "$FAKEBIN/pkill" <<'SH'
#!/usr/bin/env bash
printf 'pkill %s\n' "$*" >> "${CALLS_LOG:?}"
rm -f "${OV_PIDS:?}"
exit 0
SH
chmod +x "$FAKEBIN/pkill"

# Fake curl: exit 7 (port closed) by default; with PORT_UP=1 answer 2xx (exit
# 0), except under -f where an HTTP >= 400 answer exits 22 as real curl does.
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${CALLS_LOG:?}"
[ "${PORT_UP:-0}" = 1 ] || exit 7
case "$*" in
  *-sf*) exit 22 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/curl"

RETIRE="$ROOT/bin/fm-openviking-retire.sh"
run_retire() {
  CALLS_LOG=$CALLS LABELS_FILE=$LABELS OV_PIDS="$TMP_ROOT/pids" \
    PORT_UP=${PORT_UP:-0} \
    FM_OV_HOME=$OV_HOME_DIR \
    FM_OV_LAUNCHCTL=$FAKEBIN/launchctl FM_OV_PGREP=$FAKEBIN/pgrep \
    FM_OV_PKILL=$FAKEBIN/pkill FM_OV_CURL=$FAKEBIN/curl \
    "$RETIRE" "$@"
}

# --- full retire: label, process, log, port all cleaned ------------------------

printf -- '-\t0\torg.nix-community.home.openviking\n' > "$LABELS"
: > "$TMP_ROOT/pids"
printf 'log payload\n' > "$OV_HOME_DIR/logs/server.log"
: > "$CALLS"

out=$(run_retire)
assert_contains "$out" 'bootout gui/' 'boots the label out'
assert_contains "$out" 'org.nix-community.home.openviking' 'names the label'
assert_contains "$out" 'disable gui/' 'disables the label'
assert_contains "$out" 'rollback:' 'prints a rollback hint'
assert_contains "$out" 'residual openviking server' 'kills the server process'
assert_contains "$out" 'rotate' 'rotates the log'
assert_contains "$out" 'retired' 'reports success'
assert_grep 'pkill -f' "$CALLS" 'pkill invoked'
assert_absent "$OV_HOME_DIR/logs/server.log" 'log moved away'
assert_present "$OV_HOME_DIR/data" 'data dir untouched'
ls "$OV_HOME_DIR/logs"/server.log.* >/dev/null 2>&1 || fail 'rotated log file exists'

# --- nothing to do ------------------------------------------------------------

rm -f "$LABELS" "$TMP_ROOT/pids"
rm -f "$OV_HOME_DIR"/logs/server.log.*
: > "$CALLS"
out=$(run_retire)
assert_contains "$out" 'no launchd label' 'no labels case'
assert_contains "$out" 'retired' 'still exits cleanly'
assert_no_grep 'bootout' "$CALLS" 'no bootout without labels'

# --- a failed launchctl disable is a leftover ---------------------------------

printf -- '-\t0\torg.nix-community.home.openviking\n' > "$LABELS"
rm -f "$TMP_ROOT/pids"
cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
printf 'launchctl %s\n' "$*" >> "${CALLS_LOG:?}"
case "${1:-}" in
  list)
    printf 'PID\tStatus\tLabel\n'
    [ -f "${LABELS_FILE:?}" ] && cat "$LABELS_FILE"
    ;;
  bootout)
    label=${2##*/}
    if [ -f "${LABELS_FILE:?}" ]; then
      grep -v "$label" "$LABELS_FILE" > "$LABELS_FILE.tmp" || true
      mv "$LABELS_FILE.tmp" "$LABELS_FILE"
    fi
    ;;
  disable) exit 1 ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/launchctl"
rc=0; out=$(run_retire 2>&1) || rc=$?
expect_code 1 "$rc" 'failed launchctl disable is a leftover'
assert_contains "$out" 'launchctl disable failed' 'reports the failed disable'

# --- a failed log rotation is a leftover --------------------------------------

rm -f "$LABELS" "$TMP_ROOT/pids"
rm -f "$OV_HOME_DIR"/logs/server.log.*
printf 'rotate me\n' > "$OV_HOME_DIR/logs/server.log"
FAKEMV="$TMP_ROOT/fakemv"; mkdir -p "$FAKEMV"
cat > "$FAKEMV/mv" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEMV/mv"
rc=0; out=$(PATH="$FAKEMV:$PATH" run_retire 2>&1) || rc=$?
expect_code 1 "$rc" 'failed log rotation is a leftover'
assert_contains "$out" 'failed to rotate' 'reports the failed rotation'
assert_present "$OV_HOME_DIR/logs/server.log" 'failed rotation leaves the log in place'

# --- leftovers are reported ---------------------------------------------------

printf -- '-\t0\torg.nix-community.home.openviking\n' > "$LABELS"
cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
printf 'launchctl %s\n' "$*" >> "${CALLS_LOG:?}"
if [ "${1:-}" = list ]; then
  printf 'PID\tStatus\tLabel\n'
  [ -f "${LABELS_FILE:?}" ] && cat "$LABELS_FILE"
fi
exit 0
SH
chmod +x "$FAKEBIN/launchctl"
rc=0; out=$(run_retire 2>&1) || rc=$?
expect_code 1 "$rc" 'label surviving bootout is a failure'
assert_contains "$out" 'still loaded' 'reports the surviving label'

# --- a listener answering on the port is a failure ----------------------------

rm -f "$LABELS" "$TMP_ROOT/pids"
rc=0; out=$(PORT_UP=1 run_retire 2>&1) || rc=$?
expect_code 1 "$rc" 'port still answering is a failure'
assert_contains "$out" 'still answers' 'reports the answering port'

# --- a missing curl probe is unverified, not success ---------------------------

rc=0; out=$(CALLS_LOG=$CALLS LABELS_FILE=$LABELS OV_PIDS="$TMP_ROOT/pids" \
  FM_OV_HOME=$OV_HOME_DIR \
  FM_OV_LAUNCHCTL=$FAKEBIN/launchctl FM_OV_PGREP=$FAKEBIN/pgrep \
  FM_OV_PKILL=$FAKEBIN/pkill FM_OV_CURL="$TMP_ROOT/no-such-curl" \
  "$RETIRE" 2>&1) || rc=$?
expect_code 1 "$rc" 'missing curl is unverified'
assert_contains "$out" 'cannot verify port' 'reports the unverified port'

# --- dry-run changes nothing ---------------------------------------------------

printf -- '-\t0\torg.nix-community.home.openviking\n' > "$LABELS"
printf 'keep me\n' > "$OV_HOME_DIR/logs/server.log"
out=$(run_retire --dry-run)
assert_contains "$out" 'dry-run:' 'dry-run narrates actions'
assert_present "$OV_HOME_DIR/logs/server.log" 'dry-run keeps the log'
assert_grep 'org.nix-community.home.openviking' "$LABELS" 'dry-run keeps the label'

rc=0; run_retire --bogus >/dev/null 2>&1 || rc=$?
expect_code 2 "$rc" 'unknown option'

# --- launchctl list failure is unverifiable, not "no label" -------------------

cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKEBIN/launchctl"
rc=0; out=$(run_retire 2>&1) || rc=$?
expect_code 1 "$rc" 'launchctl list failure is unverifiable'
assert_contains "$out" 'launchctl list failed' 'reports the launchctl list failure'
assert_not_contains "$out" 'no launchd label' 'does not claim no label when the list failed'

pass 'fm-openviking-retire behavior suite'
