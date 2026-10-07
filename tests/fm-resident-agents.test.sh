#!/usr/bin/env bash
# Behavior tests for bin/fm-resident-agents.sh - the report-only listing of
# resident direct-report agent sessions and which are safe to release.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIST="$ROOT/bin/fm-resident-agents.sh"
TMP_ROOT=$(fm_test_tmproot fm-resident-agents)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
mkdir -p "$STATE_DIR"

# A fake state reader: serves the canned line for the id from FM_FAKE_STATES,
# and logs every call so the test can prove the listing only reads.
cat > "$TMP_ROOT/crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_FAKE_CALLS"
sed -n "s/^$1=//p" "$FM_FAKE_STATES" | head -1
SH
chmod +x "$TMP_ROOT/crew-state"

: > "$TMP_ROOT/states"
: > "$TMP_ROOT/procs"
add_task() {  # <id> <kind> <rss-kb> <secs> <state-line>
  local id=$1 kind=$2 rss=$3 secs=$4 line=$5
  mkdir -p "$TMP_ROOT/wt/$id"
  fm_write_meta "$STATE_DIR/$id.meta" "kind=$kind" "worktree=$TMP_ROOT/wt/$id"
  [ "$rss" = none ] || echo "100$RANDOM $rss $secs $TMP_ROOT/wt/$id" >> "$TMP_ROOT/procs"
  echo "$id=$line" >> "$TMP_ROOT/states"
}

add_task small-run ship 100000 600 "state: working · source: run-step · validating (running)"
add_task big-pr ship 480000 11000 "state: done · source: run-step · checks green: PR ready for review"
add_task mid-failed ship 300000 20000 "state: failed · source: run-step · run failed"
add_task mid-unread ship 350000 5000 "state: unknown · source: none · unreachable"
add_task empty-state ship 200000 5000 ""
add_task parked-one scout 250000 5000 "state: parked · source: run-step · parked at review"
add_task mate secondmate 400000 90000 "state: done · source: status-log"
add_task gone-pr ship none 0 "state: done · source: run-step · PR merged"

run_list() {
  FM_HOME="$HOME_DIR" FM_RESIDENT_PROC_TABLE="$TMP_ROOT/procs" \
    FM_RESIDENT_CREW_STATE="$TMP_ROOT/crew-state" FM_FAKE_STATES="$TMP_ROOT/states" \
    FM_FAKE_CALLS="$TMP_ROOT/calls" bash "$LIST"
}

before=$(find "$TMP_ROOT" -type f -exec cksum {} + | sort)
OUT=$(run_list)
after=$(find "$TMP_ROOT" -type f ! -name calls -exec cksum {} + | sort)
before=$(printf '%s\n' "$before" | grep -v '/calls$')

row() { printf '%s\n' "$OUT" | awk -v id="$1" '$1 == id {f=1; print; next} f && /^    / {print; next} {f=0}'; }

# Ordering: largest resident memory first.
order=$(printf '%s\n' "$OUT" | grep -E '^[a-z-]+  kind=' | awk '{print $1}' | tr '\n' ' ')
[ "$order" = "big-pr mate mid-unread mid-failed parked-one empty-state small-run gone-pr " ] \
  || fail "ordering by memory wrong: $order"

# Terminal-but-held ship work is flagged safe, in words.
row big-pr | grep -q 'SAFE TO RELEASE: work delivered' || fail "done ship not flagged"
row mid-failed | grep -q 'SAFE TO RELEASE: the run failed' || fail "failed run not flagged"

# A running task is never flagged; neither is a parked scout or a secondmate.
for id in small-run parked-one mate; do
  row "$id" | grep -q '>>' && fail "$id must not be flagged"
done

# An unreadable state (reported unknown, or empty output) is never flagged safe.
for id in mid-unread empty-state; do
  row "$id" | grep -q 'SAFE TO RELEASE' && fail "$id unreadable state flagged safe"
  row "$id" | grep -q '>> unknown' || fail "$id not reported unknown"
done

# Memory and runtime are reported; a task with no resident process says so.
row big-pr | grep -q 'memory=469 MB' || fail "memory missing: $(row big-pr)"
row big-pr | grep -q 'running=3h3m' || fail "runtime missing: $(row big-pr)"
row gone-pr | grep -q 'memory=not found' || fail "absent process not shown"

# The listing acts on nothing: it only read state, and wrote no file.
[ "$before" = "$after" ] || fail "listing changed files"
sort -u "$TMP_ROOT/calls" | wc -l | grep -q '^8$' || fail "did not read each task's state once"
[ -z "$(find "$TMP_ROOT/wt" -type f)" ] || fail "worktrees touched"

# Only this home's records: an id outside the state dir is never listed.
printf '%s\n' "$OUT" | grep -q 'other-home' && fail "foreign task listed"

# Real process table: a real agent-named process in a worktree is found.
mkdir -p "$TMP_ROOT/real/wt" "$TMP_ROOT/real/state"
cp "$(command -v bash)" "$TMP_ROOT/real/claude"
fm_write_meta "$TMP_ROOT/real/state/live.meta" "kind=ship" "worktree=$TMP_ROOT/real/wt"
( cd "$TMP_ROOT/real/wt" && exec "$TMP_ROOT/real/claude" -c "read -t 30 x <> /dev/zero" ) &
pid=$!
sleep 1
real=$(FM_HOME="$TMP_ROOT/real" FM_RESIDENT_CREW_STATE="$TMP_ROOT/crew-state" \
  FM_FAKE_STATES="$TMP_ROOT/states" FM_FAKE_CALLS="$TMP_ROOT/calls" bash "$LIST")
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
printf '%s\n' "$real" | grep -q 'live  kind=ship  memory=[0-9]* MB' || fail "real process not found: $real"

pass "fm-resident-agents"
