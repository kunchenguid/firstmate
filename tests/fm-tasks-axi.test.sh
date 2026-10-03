#!/usr/bin/env bash
# Canonical per-task record compatibility tests for bin/fm-tasks-axi.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-tasks-axi)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_split() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/code/data" "$dir/home/data" "$dir/home/state" "$dir/home/config"
  cp "$ROOT/.tasks.toml" "$dir/code/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
  ln -s "$dir/home/data/backlog.md" "$dir/code/data/backlog.md"
  printf '%s\n' "$dir"
}

wrapper_from_code() {
  local dir=$1
  shift
  (cd "$dir/code" && FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/code" "$WRAPPER" "$@")
}

bootstrap_backlog_lines() {
  local code=$1 home=$2
  PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$code" FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK=skip "$BOOTSTRAP" 2>&1 | grep '^BACKLOG_RECONCILE: code-root' || true
}

test_canonical_record_local_writes() {
  local dir before first_mtime second_mtime snapshot
  dir=$(make_split canonical)
  before=$(sha256sum "$dir/home/data/backlog.md")
  printf 'fixture body\n' > "$dir/code/body.md"
  wrapper_from_code "$dir" add ship-1 'ship one' --kind ship --body-file body.md --start
  [ "$(jq -r '.body' "$dir/home/data/ship-1/task.json")" = 'fixture body' ] \
    || fail 'caller-relative body did not reach the canonical task record'
  [ "$before" = "$(sha256sum "$dir/home/data/backlog.md")" ] \
    || fail 'canonical add rewrote retained legacy backlog bytes'
  first_mtime=$(stat -c %Y "$dir/home/data/ship-1/task.json")
  sleep 1
  wrapper_from_code "$dir" "done" ship-1 --pr https://example.invalid/pull/1
  second_mtime=$(stat -c %Y "$dir/home/data/ship-1/task.json")
  [ "$second_mtime" -gt "$first_mtime" ] || fail 'done did not update the task record'
  [ "$(jq -r '.completion.verb' "$dir/home/data/ship-1/task.json")" = merged ] \
    || fail 'PR completion did not retain the merged verb'
  snapshot=$(FM_HOME="$dir/home" FM_DATA_OVERRIDE="$dir/home/data" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail 'canonical completion snapshot failed'
  printf '%s' "$snapshot" | jq -e '
    any(.backlog.records[];.id=="ship-1" and .completion.verb=="merged" and .completion.date!=null)' \
    >/dev/null || fail 'canonical snapshot lost the merged completion fact'
  first_mtime=$second_mtime
  sleep 1
  wrapper_from_code "$dir" "done" ship-1 --pr https://example.invalid/pull/1
  second_mtime=$(stat -c %Y "$dir/home/data/ship-1/task.json")
  [ "$first_mtime" = "$second_mtime" ] || fail 'idempotent done replay rewrote the record'
  pass 'fm-tasks-axi compatibility writes one canonical record and preserves legacy bytes'
}

test_ambient_file_cannot_redirect() {
  local dir
  dir=$(make_split ambient)
  printf 'decoy\n' > "$dir/decoy.md"
  (cd "$dir/code" && TASKS_AXI_FILE="$dir/decoy.md" FM_HOME="$dir/home" \
    "$WRAPPER" add task-1 ambient >/dev/null) || fail 'canonical add under ambient file failed'
  assert_present "$dir/home/data/task-1/task.json" 'ambient file diverted canonical write'
  [ "$(cat "$dir/decoy.md")" = decoy ] || fail 'ambient file was rewritten'
  pass 'ambient shared-backlog variables cannot redirect canonical task writes'
}

test_task_directory_symlink_refuses() {
  local dir rc=0
  dir=$(make_split symlink)
  mkdir -p "$dir/outside"
  ln -s "$dir/outside" "$dir/home/data/task-1"
  wrapper_from_code "$dir" add task-1 unsafe >/dev/null 2>"$dir/error" || rc=$?
  [ "$rc" -ne 0 ] || fail 'symlinked task directory was accepted'
  assert_absent "$dir/outside/task.json" 'symlink refusal wrote outside the task data root'
  pass 'canonical wrapper refuses a symlinked task directory'
}

test_shadow_backlog_diagnostic_remains() {
  local dir out
  dir=$(make_split shadow)
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  [ -z "$out" ] || fail 'home-owned backlog link was reported as a shadow'
  rm "$dir/code/data/backlog.md"
  printf 'retained shadow\n' > "$dir/code/data/backlog.md"
  out=$(bootstrap_backlog_lines "$dir/code" "$dir/home")
  assert_contains "$out" 'is not this home' 'foreign code-root backlog was not reported'
  pass 'bootstrap retains the legacy shadow-file diagnostic without making it canonical'
}

test_canonical_record_local_writes
test_ambient_file_cannot_redirect
test_task_directory_symlink_refuses
test_shadow_backlog_diagnostic_remains
