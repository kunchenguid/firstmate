#!/usr/bin/env bash
# Behavioral coverage for manual task-data pruning and its safety exclusions.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-data-prune)
command -v tasks-axi >/dev/null 2>&1 || { printf 'SKIP: tasks-axi required\n'; exit 0; }
HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$HOME_FIXTURE/data" "$HOME_FIXTURE/state" "$HOME_FIXTURE/config"
fm_test_tasks_toml "$HOME_FIXTURE/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_FIXTURE/data/backlog.md"

task_command() {
  (cd "$HOME_FIXTURE" && tasks-axi "$@" >/dev/null)
}

seed() {
  local task=$1
  task_command add "$task" 'Prune fixture' --kind ship
  task_command 'done' "$task" --note 'landed on local main'
  mkdir -p "$HOME_FIXTURE/data/$task/scratch"
  python3 - "$HOME_FIXTURE/data/$task" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
(root / 'scratch' / 'bulk.bin').write_bytes(b'\0' * 1048576)
for name in ('brief.md', 'launch-brief.md', 'report.md', 'status.log', 'result.status', 'small-record'):
    (root / name).write_text('durable record\n')
(root / 'large.log').write_bytes(b'X' * 1048576)
for name in ('stdout', 'status', 'worker.log.1'):
    (root / name).write_bytes(b'X' * 1048576)
(root / 'logs').mkdir()
(root / 'logs' / '1').write_bytes(b'X' * 1048576)
PY
  printf 'fm-prune-safe-v1\n' > "$HOME_FIXTURE/state/$task.prune-safe"
}

run_prune() {
  local output rc=0
  output=$(FM_HOME="$HOME_FIXTURE" FM_DATA_OVERRIDE="$HOME_FIXTURE/data" \
    FM_STATE_OVERRIDE="$HOME_FIXTURE/state" "$ROOT/bin/fm-data-prune.sh" "$@") || rc=$?
  printf '%s\n' "$output"
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$output" >&2; fi
  return "$rc"
}

seed eligible
run_prune eligible > "$TMP_ROOT/preview"
assert_present "$HOME_FIXTURE/data/eligible/scratch/bulk.bin" 'dry run removed scratch'
assert_grep 'bytes: 1048576' "$TMP_ROOT/preview" 'preview byte count is wrong'
assert_grep 'scratch/bulk.bin' "$TMP_ROOT/preview" 'preview omitted file path'
run_prune --confirm eligible > "$TMP_ROOT/confirmed"
assert_absent "$HOME_FIXTURE/data/eligible/scratch/bulk.bin" 'confirm retained bulk'
for record in brief.md launch-brief.md report.md status.log result.status small-record large.log stdout status worker.log.1 logs/1; do
  assert_present "$HOME_FIXTURE/data/eligible/$record" "confirm removed $record"
done
pass 'dry run preserves bytes; confirm removes only bulky scratch'

for task in live held closed-held unlanded pending legacy; do seed "$task"; done
printf 'window=live-endpoint\n' > "$HOME_FIXTURE/state/live.meta"
task_command reopen held
task_command hold held --reason 'decision required' --kind captain
task_command reopen closed-held
task_command hold closed-held --reason 'retained decision' --kind captain
task_command 'done' closed-held
rm "$HOME_FIXTURE/state/unlanded.prune-safe" "$HOME_FIXTURE/state/legacy.prune-safe"
printf 'pending\n' > "$HOME_FIXTURE/state/pending.backlog-close"
run_prune --confirm live held closed-held unlanded pending legacy > "$TMP_ROOT/excluded"
for task in live held closed-held unlanded pending legacy; do
  assert_present "$HOME_FIXTURE/data/$task/scratch/bulk.bin" "$task lost scratch"
done
pass 'live, held, unlanded, pending, and legacy tasks remain untouched'

seed links
mkdir -p "$TMP_ROOT/outside"
printf 'outside\n' > "$TMP_ROOT/outside/record"
ln -s "$TMP_ROOT/outside" "$HOME_FIXTURE/data/links/escape"
ln -s "$TMP_ROOT/outside/record" "$HOME_FIXTURE/data/links/symlink"
ln -s "$TMP_ROOT/outside" "$HOME_FIXTURE/data/linked-folder"
printf 'loose\n' > "$HOME_FIXTURE/data/loose-file"
run_prune --confirm > "$TMP_ROOT/all"
assert_present "$TMP_ROOT/outside/record" 'symlink target was removed'
[ -L "$HOME_FIXTURE/data/links/escape" ] || fail 'directory symlink was removed'
[ -L "$HOME_FIXTURE/data/links/symlink" ] || fail 'file symlink was removed'
assert_present "$HOME_FIXTURE/data/loose-file" 'loose data file was removed'
pass 'symlinks and loose files remain untouched'

seed binary-tree
rm "$HOME_FIXTURE/data/binary-tree/scratch/bulk.bin"
python3 - "$HOME_FIXTURE/data/binary-tree/scratch" <<'PY'
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
for i in range(4):
    (root / str(i)).write_bytes(b'\0' * 262144)
(root / 'notes').write_text('keep me\n')
PY
run_prune --confirm binary-tree > "$TMP_ROOT/tree"
for file in 0 1 2 3; do
  assert_absent "$HOME_FIXTURE/data/binary-tree/scratch/$file" 'binary scratch tree retained'
done
assert_present "$HOME_FIXTURE/data/binary-tree/scratch/notes" 'small text record removed'
run_prune --confirm binary-tree > "$TMP_ROOT/empty"
assert_grep 'bytes: 0' "$TMP_ROOT/empty" 'repeated confirm was not a no-op'
pass 'binary trees are pruned while small text survives; repeated confirm is harmless'

if run_prune --confim eligible > "$TMP_ROOT/invalid"; then fail 'unknown flag accepted'; fi
assert_grep 'unknown argument' "$TMP_ROOT/invalid" 'usage error has no diagnosis'
pass 'invalid arguments fail before pruning'

seed locked
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
control_lock="$HOME_FIXTURE/state/.control-locked.lock"
fm_lock_acquire_wait "$control_lock"
mkdir "$TMP_ROOT/fakebin"
REAL_SLEEP=$(command -v sleep)
export REAL_SLEEP
cat > "$TMP_ROOT/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf 'waiting\n' > "$FM_PRUNE_LOCK_WAIT"
exec "$REAL_SLEEP" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/sleep"
PATH="$TMP_ROOT/fakebin:$PATH" FM_PRUNE_LOCK_WAIT="$TMP_ROOT/lock-wait" \
  run_prune --confirm locked > "$TMP_ROOT/locked" &
prune_pid=$!
for ((attempt=0; attempt<300; attempt++)); do
  [ ! -e "$TMP_ROOT/lock-wait" ] || break
  kill -0 "$prune_pid" 2>/dev/null || break
  "$REAL_SLEEP" 0.1
done
blocked=0
if [ -e "$TMP_ROOT/lock-wait" ] && [ -f "$HOME_FIXTURE/data/locked/scratch/bulk.bin" ]; then blocked=1; fi
fm_lock_release "$control_lock"
wait "$prune_pid"
[ "$blocked" = 1 ] || fail 'prune ignored task control lock'
assert_absent "$HOME_FIXTURE/data/locked/scratch/bulk.bin" 'prune did not resume after control lock release'
pass 'prune serializes with task control operations before deleting scratch'

seed livelock
printf 'window=live\n' > "$HOME_FIXTURE/state/livelock.meta"
fm_lock_acquire_wait "$HOME_FIXTURE/state/.control-livelock.lock"
live_rc=0
timeout 20 env FM_HOME="$HOME_FIXTURE" FM_DATA_OVERRIDE="$HOME_FIXTURE/data" \
  FM_STATE_OVERRIDE="$HOME_FIXTURE/state" "$ROOT/bin/fm-data-prune.sh" livelock > "$TMP_ROOT/livelock" || live_rc=$?
fm_lock_release "$HOME_FIXTURE/state/.control-livelock.lock"
[ "$live_rc" = 0 ] || fail 'preview of live task blocked on its control lock'
assert_grep 'skipped' "$TMP_ROOT/livelock" 'live task was not skipped'
assert_present "$HOME_FIXTURE/data/livelock/scratch/bulk.bin" 'live task scratch changed'
pass 'preview skips a live task without taking its control lock'

seed archived
task_command prune --keep 0
run_prune --confirm archived > "$TMP_ROOT/archived"
assert_absent "$HOME_FIXTURE/data/archived/scratch/bulk.bin" 'archived task retained scratch'
pass 'archived closed tasks remain eligible through the backlog adapter'
