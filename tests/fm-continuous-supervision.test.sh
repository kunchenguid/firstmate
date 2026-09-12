#!/usr/bin/env bash
# Behavioral lifecycle coverage for the per-home continuous-supervision opt-in.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
CMD=$ROOT/bin/fm-continuous-supervision.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-continuous-test.XXXXXX") || exit 1
export TMUX_TMPDIR=/tmp/fmct.$$
mkdir -p "$TMUX_TMPDIR"
HOME_DIR=$TMP/home
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"

cleanup() {
  TMUX_TMPDIR=$TMUX_TMPDIR tmux kill-server 2>/dev/null || true
  rm -rf "$TMUX_TMPDIR"
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

cat > "$TMP/fake-daemon.sh" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-wake-lib.sh"
state=\$FM_HOME/state
lock=\$state/.supervise-daemon.lock
mkdir -p "\$state"
fm_lock_try_acquire "\$lock" || exit 1
printf '%s\n' "\$\$" > "\$state/.supervise-daemon.pid"
fm_pid_identity "\$\$" > "\$lock/pid-identity"
date +%s > "\$state/.last-watcher-beat"
trap 'fm_lock_release "\$lock"; rm -f "\$state/.supervise-daemon.pid"; exit 0' TERM INT EXIT
while :; do date +%s > "\$state/.last-watcher-beat"; sleep 1; done
SH
chmod +x "$TMP/fake-daemon.sh"

tmux new-session -d -s cap1
tmux new-session -d -s cap2

out=$(FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=cap1:0 \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure) || fail "disabled ensure failed"
[ "$out" = "continuous-supervision: disabled" ] || fail "disabled ensure changed behavior: $out"
[ ! -e "$HOME_DIR/state/.continuous-supervision-terminal" ] || fail "disabled ensure created service state"
pass "opt-in absence is unchanged"

mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects"
: > "$HOME_DIR/config/continuous-supervision"
FM_HOME=$HOME_DIR FM_BOOTSTRAP_NETWORK=skip FM_SUPERVISOR_BACKEND=tmux \
  FM_SUPERVISOR_TARGET=cap1:0 FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh \
  "$ROOT/bin/fm-bootstrap.sh" >/dev/null || fail "bootstrap auto-start failed"
[ -f "$HOME_DIR/config/continuous-supervision" ] || fail "enable did not persist opt-in"
first=$(cat "$HOME_DIR/state/.continuous-supervision-terminal")
FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=cap1:0 \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure >/dev/null || fail "idempotent ensure failed"
[ "$(cat "$HOME_DIR/state/.continuous-supervision-terminal")" = "$first" ] || fail "ensure replaced a healthy singleton"
FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=cap1:0 \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure > "$TMP/ensure-1" & p1=$!
FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=cap1:0 \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure > "$TMP/ensure-2" & p2=$!
wait "$p1" || fail "first concurrent ensure failed"
wait "$p2" || fail "second concurrent ensure failed"
[ "$(cat "$HOME_DIR/state/.continuous-supervision-terminal")" = "$first" ] || fail "concurrent ensure replaced the singleton"
pass "enabled bootstrap auto-start and concurrent ensure keep one identity-matched daemon"

service=${first%%$'\t'*}
tmux kill-session -t "$service"
sleep 1
FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=cap1:0 \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure >/dev/null || fail "dead service recovery failed"
recovered=$(cat "$HOME_DIR/state/.continuous-supervision-terminal")
service=${recovered%%$'\t'*}
tmux has-session -t "$service" 2>/dev/null || fail "ensure did not recover service"
pass "enabled bootstrap-style ensure recovers a dead service"

FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=cap2:0 \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure >/dev/null || fail "relaunch retarget failed"
second=$(cat "$HOME_DIR/state/.continuous-supervision-terminal")
[ "${second#*$'\t'}" = cap2:0 ] || fail "service retained the pre-relaunch target: $second"
pass "service continuity retargets after a Firstmate relaunch"

# A daemon launched by another lifecycle is authoritative evidence that this
# helper must stand down. A missing local record cannot authorize adopting or
# killing that process, and starting a duplicate would race one home lock.
FM_HOME=$HOME_DIR "$CMD" disable >/dev/null || fail "pre-foreign disable failed"
: > "$HOME_DIR/config/continuous-supervision"
tmux new-session -d -s foreign-supervisor env FM_HOME="$HOME_DIR" "$TMP/fake-daemon.sh"
sleep 1
rm -f "$HOME_DIR/state/.continuous-supervision-terminal"
if FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=cap2:0 \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure > "$TMP/foreign.out" 2> "$TMP/foreign.err"; then
  fail "ensure adopted a live unrecorded daemon"
fi
tmux has-session -t foreign-supervisor 2>/dev/null || fail "ensure killed the foreign daemon terminal"
[ ! -e "$HOME_DIR/state/.continuous-supervision-terminal" ] || fail "ensure recorded a second owner"
grep -F 'refusing a second owner' "$TMP/foreign.err" >/dev/null \
  || fail "foreign-owner refusal was not explained"
tmux kill-session -t foreign-supervisor
sleep 1
pass "a live unrecorded daemon prevents duplicate successor ownership"

mkdir -p "$HOME_DIR/state/task.inbox"
printf 'preserve me\n' > "$HOME_DIR/state/task.inbox/0001"
FM_HOME=$HOME_DIR "$CMD" disable >/dev/null || fail "disable failed"
[ ! -e "$HOME_DIR/config/continuous-supervision" ] || fail "disable retained opt-in"
[ ! -e "$HOME_DIR/state/.continuous-supervision-terminal" ] || fail "disable retained service record"
[ "$(cat "$HOME_DIR/state/task.inbox/0001")" = "preserve me" ] || fail "disable touched task inbox work"
pass "disable stops only its recorded service and preserves task work"

: > "$HOME_DIR/config/continuous-supervision"
tmux new-session -d -s 'cap@odd'
if FM_HOME=$HOME_DIR FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET='cap@odd:0' \
  FM_CONTINUOUS_DAEMON=$TMP/fake-daemon.sh "$CMD" ensure > "$TMP/odd.out" 2> "$TMP/odd.err"; then
  fail "ensure accepted a target its record cannot round-trip"
fi
[ ! -e "$HOME_DIR/state/.continuous-supervision-terminal" ] || fail "unrecordable target was recorded"
if tmux list-sessions -F '#{session_name}' | grep '^fm-continuous-' >/dev/null; then
  fail "unrecordable target launched a daemon"
fi
FM_HOME=$HOME_DIR "$CMD" disable >/dev/null || fail "disable wedged after an unrecordable target"
[ ! -e "$HOME_DIR/config/continuous-supervision" ] || fail "disable retained opt-in after rejected target"
pass "an unrecordable supervisor target fails before launch and stays disableable"

echo "All continuous-supervision lifecycle tests passed."
