#!/usr/bin/env bash
# Tests for Docker Sandbox bridge lifecycle and watcher bridge synchronization.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE_LIB="$ROOT/bin/fm-sandbox-bridge-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-sandbox-bridge)
STATE="$TMP_ROOT/state"
WORKTREE="$TMP_ROOT/worktree"
BRIEF="$TMP_ROOT/brief.md"
ENCODER="$TMP_ROOT/encoder.sh"
TASK_ID='bridge-task'

mkdir -p "$STATE" "$WORKTREE"
printf '# Bridge fixture\n' > "$BRIEF"
chmod 600 "$BRIEF"
cat > "$ENCODER" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*"
SH
chmod 700 "$ENCODER"

# shellcheck source=/dev/null
. "$BRIDGE_LIB"

file_mode() {
  perl -e 'my @s = lstat($ARGV[0]) or exit 1; printf "%04o\n", $s[2] & 07777;' "$1"
}

expect_mode() {
  local path=$1 expected=$2 actual
  actual=$(file_mode "$path") || fail "could not inspect permissions for $path"
  [ "$actual" = "$expected" ] || fail "$path has mode $actual, expected $expected"
}

file_signature() {
  perl -e 'my @s = lstat($ARGV[0]) or exit 1; print "$s[7]:$s[9]";' "$1"
}

assert_no_entry() {
  [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$2"
}

status=0
fm_sandbox_bridge_create "$STATE" "$TASK_ID" "$WORKTREE" "$BRIEF" "$ENCODER" || status=$?
expect_code 0 "$status" "bridge creation"
state_real=$(cd "$STATE" && pwd -P)
bridge=$(fm_sandbox_bridge_expected_path "$STATE" "$TASK_ID") \
  || fail "bridge path resolution failed"
cursor=$(fm_sandbox_bridge_cursor_path "$STATE" "$TASK_ID") \
  || fail "cursor path resolution failed"
expected="$state_real/sandbox-bridge/$TASK_ID"
[ "$bridge" = "$expected" ] || fail "bridge path was not canonical: $bridge"
[ "$FM_SANDBOX_BRIDGE_PATH" = "$expected" ] || fail "create did not publish canonical bridge path"
[ "$FM_SANDBOX_BRIDGE_CURSOR" = "$cursor" ] || fail "create did not publish canonical cursor path"

assert_present "$bridge/binding" "bridge binding was not created"
assert_present "$bridge/status" "bridge status was not created"
assert_present "$bridge/runtime-brief.md" "bridge runtime brief was not created"
assert_present "$bridge/fm-operational-input.sh" "bridge encoder was not created"
assert_present "$cursor" "host-private cursor was not created"
expect_mode "$state_real/sandbox-bridge" 0700
expect_mode "$state_real/sandbox-bridge-cursor" 0700
expect_mode "$bridge" 0700
expect_mode "$bridge/binding" 0600
expect_mode "$bridge/status" 0600
expect_mode "$bridge/runtime-brief.md" 0600
expect_mode "$bridge/fm-operational-input.sh" 0700
expect_mode "$cursor" 0600
[ "$(fm_sandbox_bridge_read_cursor "$cursor")" = 0 ] || fail "new bridge cursor was not zero"

printf 'working: first delta\n' >> "$bridge/status"
status=0
fm_sandbox_bridge_sync "$bridge" "$STATE" "$TASK_ID" "$WORKTREE" || status=$?
expect_code 0 "$status" "first bridge status sync"
first_size=$(wc -c < "$bridge/status" | tr -d ' ')
[ "$(fm_sandbox_bridge_read_cursor "$cursor")" = "$first_size" ] \
  || fail "first sync did not advance the host-private cursor"

printf 'done: second delta\n' >> "$bridge/status"
status=0
fm_sandbox_bridge_sync "$bridge" "$STATE" "$TASK_ID" "$WORKTREE" || status=$?
expect_code 0 "$status" "second bridge status sync"
canonical_status="$state_real/$TASK_ID.status"
[ "$(cat "$canonical_status")" = $'working: first delta\ndone: second delta' ] \
  || fail "canonical status did not contain each delta exactly once"
[ "$(fm_sandbox_bridge_read_cursor "$cursor")" = "$(wc -c < "$bridge/status" | tr -d ' ')" ] \
  || fail "second sync did not consume the complete bridge status"
full_size=$(wc -c < "$bridge/status" | tr -d ' ')
fm_sandbox_bridge_touch_turnend "$bridge/turn-ended" \
  || fail "could not touch bridge turn-ended marker"
status=0
fm_sandbox_bridge_sync "$bridge" "$STATE" "$TASK_ID" "$WORKTREE" || status=$?
expect_code 0 "$status" "turn-ended bridge sync"
canonical_turnend="$state_real/$TASK_ID.turn-ended"
assert_present "$canonical_turnend" "canonical turn-ended marker was not created"
assert_no_entry "$bridge/turn-ended" "bridge turn-ended marker was not consumed"
turnend_signature=$(file_signature "$canonical_turnend") \
  || fail "could not inspect canonical turn-ended marker"
status=0
fm_sandbox_bridge_sync "$bridge" "$STATE" "$TASK_ID" "$WORKTREE" || status=$?
expect_code 0 "$status" "repeat bridge sync"
[ "$(file_signature "$canonical_turnend")" = "$turnend_signature" ] \
  || fail "repeat sync changed the canonical turn-ended marker"

: > "$bridge/status"
status=0
fm_sandbox_bridge_sync "$bridge" "$STATE" "$TASK_ID" "$WORKTREE" || status=$?
expect_code 1 "$status" "truncated bridge status rejection"
[ "$(fm_sandbox_bridge_read_cursor "$cursor")" = "$full_size" ] \
  || fail "truncated status changed the host-private cursor"
outside_status="$TMP_ROOT/outside-status"
printf 'outside status\n' > "$outside_status"
chmod 600 "$outside_status"
rm -f "$bridge/status"
ln -s "$outside_status" "$bridge/status"
status=0
fm_sandbox_bridge_sync "$bridge" "$STATE" "$TASK_ID" "$WORKTREE" || status=$?
expect_code 1 "$status" "symlinked bridge status rejection"
[ -L "$bridge/status" ] || fail "symlink substitution fixture was not retained"

WATCH_ID='watch-task'
status=0
fm_sandbox_bridge_create "$STATE" "$WATCH_ID" "$WORKTREE" "$BRIEF" "$ENCODER" || status=$?
expect_code 0 "$status" "watcher bridge creation"
watch_bridge=$(fm_sandbox_bridge_expected_path "$STATE" "$WATCH_ID") \
  || fail "watcher bridge path resolution failed"
watch_meta="$STATE/$WATCH_ID.meta"
fm_write_meta "$watch_meta" \
  "window=firstmate:fm-$WATCH_ID" \
  "endpoint_task_id=$WATCH_ID" \
  "worktree=$WORKTREE" \
  "project=$WORKTREE" \
  "harness=claude" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off" \
  "tasktmp=$TMP_ROOT/tasktmp" \
  "model=default" \
  "effort=default" \
  "placement=docker-sandbox" \
  "placement_mode=direct" \
  "placement_handle=docker-sandbox:$WATCH_ID:fm-$WATCH_ID" \
  "placement_bridge=$watch_bridge"
chmod 600 "$watch_meta"

source_status=0
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$STATE" \
  . "$ROOT/bin/fm-watch.sh" || source_status=$?
expect_code 0 "$source_status" "watcher source guard"
assert_no_entry "$STATE/.watch.lock/pid" "sourcing watcher functions acquired the runtime lock"
printf 'watcher: canonical delta\n' >> "$watch_bridge/status"
status=0
watch_sync_sandbox_bridges || status=$?
expect_code 0 "$status" "watcher bridge synchronization"
watch_canonical="$state_real/$WATCH_ID.status"
[ "$(cat "$watch_canonical")" = 'watcher: canonical delta' ] \
  || fail "watcher sync did not make bridge status canonical"

cp "$watch_bridge/binding" "$TMP_ROOT/watch-binding.good"
sed 's/^task_id=watch-task$/task_id=other-task/' "$watch_bridge/binding" > "$watch_bridge/binding.tmp"
mv "$watch_bridge/binding.tmp" "$watch_bridge/binding"
status=0
watch_sync_sandbox_bridges || status=$?
expect_code 1 "$status" "mismatched bridge binding rejection"
assert_present "$watch_bridge" "mismatched bridge binding removed the bridge"
mv "$TMP_ROOT/watch-binding.good" "$watch_bridge/binding"

cp "$watch_meta" "$TMP_ROOT/watch-meta.good"
fm_write_meta "$watch_meta" \
  "window=firstmate:fm-$WATCH_ID" "endpoint_task_id=$WATCH_ID" \
  "worktree=$WORKTREE" "placement=docker-sandbox" \
  "placement_bridge=$watch_bridge" "placement_bridge=$watch_bridge"
chmod 600 "$watch_meta"
status=0
watch_sync_sandbox_bridges || status=$?
expect_code 1 "$status" "malformed bridge metadata rejection"
assert_present "$watch_bridge" "malformed metadata removed the bridge"
mv "$TMP_ROOT/watch-meta.good" "$watch_meta"

fm_write_meta "$watch_meta" \
  "window=firstmate:fm-$WATCH_ID" "endpoint_task_id=$WATCH_ID" \
  "worktree=$WORKTREE" "placement=docker-sandbox" \
  "placement_bridge=$STATE/sandbox-bridge/not-recorded"
chmod 600 "$watch_meta"
status=0
watch_sync_sandbox_bridges || status=$?
expect_code 1 "$status" "mismatched bridge path rejection"
assert_no_entry "$STATE/sandbox-bridge/not-recorded" \
  "watcher adopted or recreated an unrecorded bridge path"
assert_present "$watch_bridge" "mismatched metadata removed the recorded bridge"

pass "Docker Sandbox bridge creation, bounded sync, turn-end consumption, watcher sync, and fail-closed metadata handling"
