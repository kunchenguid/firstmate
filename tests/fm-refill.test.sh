#!/usr/bin/env bash
# Behavioral tests for durable desired-concurrency deficit detection.
set -u

ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
CMD="$ROOT/bin/fm-refill.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-refill-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data"
BACKLOG="$HOME_DIR/data/backlog.md"
printf 'sentinel backlog bytes\n' > "$BACKLOG"
before=$(cksum "$BACKLOG")

cat > "$TMP/crew-state" <<'EOF'
#!/usr/bin/env bash
state=$(awk -F= -v id="$1" '$1 == id { print $2; exit }' "$FM_REFILL_STATE_MAP")
[ -n "$state" ] || state=unknown
printf 'state: %s · source: fixture · test\n' "$state"
EOF
chmod +x "$TMP/crew-state"

cat > "$TMP/tasks-axi" <<'EOF'
#!/usr/bin/env bash
[ "$1" = ready ] || exit 2
count=$(cat "$FM_REFILL_READY_FILE")
printf 'count: %s\nready: %s unblocked queued tasks\n' "$count" "$count"
i=1
while [ "$i" -le "$count" ]; do
  printf '  task-%s\n' "$i"
  i=$((i + 1))
done
EOF
chmod +x "$TMP/tasks-axi"

run() {
  local now=$1
  shift
  FM_HOME="$HOME_DIR" \
  FM_REFILL_CREW_STATE_BIN="$TMP/crew-state" \
  FM_REFILL_TASKS_AXI="$TMP/tasks-axi" \
  FM_REFILL_STATE_MAP="$TMP/states" \
  FM_REFILL_READY_FILE="$TMP/ready" \
  FM_REFILL_RESURFACE_SECS=60 \
  FM_REFILL_CHECK_SECS="${FM_REFILL_CHECK_SECS:-1}" \
  FM_REFILL_NOW="$now" \
  "$CMD" "$@"
}

out=$(run 100 check) || fail "disabled check failed"
[ -z "$out" ] || fail "disabled check emitted: $out"
[ ! -e "$HOME_DIR/state/refill-deficit" ] || fail "disabled check wrote observation state"
pass "absent target is a silent no-op"

run 100 set 3 >/dev/null || fail "could not set target"
cat > "$HOME_DIR/state/a.meta" <<EOF
kind=ship
EOF
cat > "$HOME_DIR/state/b.meta" <<EOF
kind=scout
EOF
cat > "$HOME_DIR/state/ambiguous.meta" <<EOF
kind=ship
EOF
cat > "$HOME_DIR/state/mate.meta" <<EOF
kind=secondmate
EOF
printf 'a=working\nb=working\nambiguous=unknown\nmate=working\n' > "$TMP/states"
printf '2\n' > "$TMP/ready"

out=$(run 100 check) || fail "initial deficit check failed"
[ "$out" = 'refill-deficit: active=2 desired=3 ready=2 terminal=0 other=1' ] \
  || fail "unexpected initial deficit: $out"
grep -F 'phase=deficit' "$HOME_DIR/state/refill-deficit" >/dev/null || fail "deficit was not persisted"
[ "$(cksum "$BACKLOG")" = "$before" ] || fail "detector changed the backlog"
pass "an ambiguous record does not hide a productive deficit or mutate work"

out=$(run 101 check) || fail "duplicate check failed"
[ -z "$out" ] || fail "unchanged deficit emitted twice: $out"
pass "an unchanged deficit is deduplicated"

printf '1\n' > "$TMP/ready"
out=$(run 102 check) || fail "changed-ready check failed"
[ -n "$out" ] || fail "changed ready-work fingerprint did not emit"
out=$(run 161 check) || fail "pre-resurface check failed"
[ -z "$out" ] || fail "deficit resurfaced before its bound: $out"
out=$(run 162 check) || fail "bounded resurface check failed"
[ -n "$out" ] || fail "unchanged deficit did not resurface at its bound"
pass "material change wakes immediately and unchanged deficit resurfaces on its bound"

printf 'a=working\nb=working\nambiguous=working\nmate=working\n' > "$TMP/states"
out=$(run 163 check) || fail "satisfied check failed"
[ -z "$out" ] || fail "satisfied target emitted: $out"
grep -F 'phase=satisfied' "$HOME_DIR/state/refill-deficit" >/dev/null || fail "satisfied state was not persisted"
pass "a satisfied target stays silent"

cat > "$HOME_DIR/state/finished.meta" <<EOF
kind=ship
EOF
printf 'a=working\nb=working\nambiguous=working\nfinished=done\nmate=working\n' > "$TMP/states"
printf '0\n' > "$TMP/ready"
out=$(run 164 check) || fail "terminal reconciliation check failed"
[ "$out" = 'refill-deficit: active=3 desired=3 ready=0 terminal=1 other=0' ] \
  || fail "terminal work did not wake reconciliation: $out"
pass "terminal work wakes reconciliation even when the productive target is full"

printf '2\n' > "$TMP/ready"
out=$(FM_REFILL_CHECK_SECS=30 run 170 check) || fail "cadence-gated check failed"
[ -z "$out" ] || fail "check snapshotted inside its cadence window: $out"
grep -Fx 'observed_epoch=164' "$HOME_DIR/state/refill-deficit" >/dev/null \
  || fail "cadence-gated check rewrote the observation"
out=$(FM_REFILL_CHECK_SECS=30 run 194 check) || fail "post-cadence check failed"
[ -n "$out" ] || fail "changed deficit was not observed once the cadence elapsed"
run 195 set 5 >/dev/null || fail "could not change target inside cadence window"
out=$(FM_REFILL_CHECK_SECS=30 run 196 check) || fail "target-change check failed"
[ "$out" = 'refill-deficit: active=3 desired=5 ready=2 terminal=1 other=0' ] \
  || fail "a changed target was not checked immediately: $out"
pass "snapshots are cadence-bounded while target changes are checked immediately"

# Exercise the public foreground watcher path rather than treating the detector
# output as a proxy for delivery. A changed target clears the prior fingerprint,
# and the real watcher must publish the typed check wake before it exits.
run 165 set 4 >/dev/null || fail "could not change target for watcher integration"
printf 'a=working\nb=working\nambiguous=working\nfinished=done\nmate=working\n' > "$TMP/states"
printf '1\n' > "$TMP/ready"
rm -f "$HOME_DIR/state/mate.meta"
rm -f "$HOME_DIR/state/refill-deficit"
touch "$HOME_DIR/state/.inactive-outcome-reconcile" "$HOME_DIR/state/.last-check" "$HOME_DIR/state/.last-heartbeat"
probe=$(run 165 check) || fail "pre-watcher detector probe failed"
[ -n "$probe" ] || fail "pre-watcher detector probe was unexpectedly silent"
rm -f "$HOME_DIR/state/refill-deficit"
set +e
FM_HOME="$HOME_DIR" \
FM_REFILL_CREW_STATE_BIN="$TMP/crew-state" \
FM_REFILL_TASKS_AXI="$TMP/tasks-axi" \
FM_REFILL_STATE_MAP="$TMP/states" \
FM_REFILL_READY_FILE="$TMP/ready" \
FM_REFILL_NOW=165 \
FM_HEARTBEAT=99999 FM_CHECK_INTERVAL=99999 FM_INACTIVE_RECONCILE_SECS=1800 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$TMP/watch.out" 2> "$TMP/watch.err"
watch_rc=$?
set -e
[ "$watch_rc" -eq 0 ] || fail "watcher checkpoint did not deliver the deficit (rc=$watch_rc out=$(cat "$TMP/watch.out") err=$(cat "$TMP/watch.err") triage=$(cat "$HOME_DIR/state/.watch-triage.log" 2>/dev/null))"
grep -F 'check: refill-deficit' "$TMP/watch.out" >/dev/null \
  || fail "watcher did not emit the typed deficit reason: $(cat "$TMP/watch.out")"
grep -F $'check\trefill-deficit\tcheck: refill-deficit' "$HOME_DIR/state/.wake-queue" >/dev/null \
  || fail "watcher did not durably queue the deficit wake"
pass "the real watcher publishes a durable refill-deficit wake"

FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$2/.refill-deficit.lock" || exit 1
  : > "$3"
  sleep 1
  printf "phase=deficit\n" > "$2/refill-deficit"
  fm_lock_release "$2/.refill-deficit.lock"
' _ "$ROOT" "$HOME_DIR/state" "$TMP/holder-ready" &
holder=$!
i=0
until [ -e "$TMP/holder-ready" ]; do
  i=$((i + 1)); [ "$i" -lt 100 ] || fail "lock holder never started"
  sleep 0.05
done
run 166 disable >/dev/null || fail "disable failed"
wait "$holder" || fail "concurrent check holder failed"
[ ! -e "$HOME_DIR/config/desired-concurrency" ] || fail "disable retained target"
[ ! -e "$HOME_DIR/state/refill-deficit" ] || fail "disable retained observation"
pass "disable waits for a concurrent check and retires only owned target state"

ALT_CONFIG="$TMP/alt-config"
ALT_STATE="$TMP/elsewhere/alt-state"
mkdir -p "$ALT_STATE"
FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$ALT_CONFIG" FM_STATE_OVERRIDE="$ALT_STATE" \
  "$CMD" set 2 >/dev/null || fail "override set failed"
[ -f "$ALT_CONFIG/desired-concurrency" ] || fail "set ignored FM_CONFIG_OVERRIDE"
refill=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_status "$2" 300 "$3"; printf "%s" "$FM_SUP_REFILL"' \
  _ "$ROOT" "$ALT_STATE" "$ALT_CONFIG")
[ "$refill" = true ] || fail "supervision predicate did not see the overridden refill target"
pass "an overridden config target is the one supervision checks"

MATE_HOME="$TMP/mate-home"
PARENT_HOME="$TMP/parent-home"
mkdir -p "$MATE_HOME/config" "$MATE_HOME/state" "$MATE_HOME/data" "$PARENT_HOME/state/mate-1.inbox/handled"
printf 'mate-1\n' > "$MATE_HOME/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT_HOME" > "$MATE_HOME/.fm-secondmate-parent"
printf '3\n' > "$MATE_HOME/config/desired-concurrency"
printf '1\n' > "$TMP/ready"
printf 'schema=fm-task-inbox.v1\n--\npersist the update and restart\n' > "$PARENT_HOME/state/mate-1.inbox/001.msg"
mate_check() {
  FM_HOME="$MATE_HOME" FM_REFILL_CREW_STATE_BIN="$TMP/crew-state" FM_REFILL_TASKS_AXI="$TMP/tasks-axi" \
    FM_REFILL_STATE_MAP="$TMP/states" FM_REFILL_READY_FILE="$TMP/ready" FM_REFILL_RESURFACE_SECS=60 \
    FM_REFILL_CHECK_SECS=1 FM_REFILL_NOW="$1" "$CMD" check
}
out=$(mate_check 300) || fail "mate check with a pending parent instruction failed"
[ -z "$out" ] || fail "refill deficit preempted a pending parent instruction: $out"
[ ! -e "$MATE_HOME/state/refill-deficit" ] || fail "preempted check advanced the dedup observation"
[ -f "$PARENT_HOME/state/mate-1.inbox/001.msg" ] || fail "refill check acknowledged the parent instruction"
mv "$PARENT_HOME/state/mate-1.inbox/001.msg" "$PARENT_HOME/state/mate-1.inbox/handled/"
out=$(mate_check 301) || fail "mate check after acknowledgement failed"
[ "$out" = 'refill-deficit: active=0 desired=3 ready=1 terminal=0 other=0' ] \
  || fail "deficit did not surface once the parent instruction was acknowledged: $out"
pass "a pending parent instruction preempts refill until acknowledged, then the deficit surfaces"

echo "All desired-concurrency refill tests passed."
