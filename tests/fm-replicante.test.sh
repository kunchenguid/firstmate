#!/usr/bin/env bash
# Behavioral tests for the incremental, content-addressed replicante backup.
#
# Every case uses a temporary source Git worktree and backup destination.
# Fixture mode is the only path override and never reaches the real H: volume.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

REPLICANTE="$ROOT/bin/fm-replicante.sh"

make_source() {
  local source=$1
  mkdir -p "$source"
  git init -q -b main "$source"
  git -C "$source" config user.name 'Replicante Tests'
  git -C "$source" config user.email 'replicante-tests@example.invalid'
  printf 'canonical Firstmate backup fixture\n' >"$source/README.md"
  printf '%s\n' 'projects/' 'data/' 'config/' 'state/' '.no-mistakes/' >"$source/.gitignore"
  printf 'source secret\n' >"$source/.env"
  printf 'source-owned policy\n' >"$source/.shadow-policy"
  mkdir -p "$source/projects/alpha/src" \
    "$source/projects/alpha/config" \
    "$source/data/decisions" \
    "$source/config" \
    "$source/state" \
    "$source/.no-mistakes"
  printf 'project source\n' >"$source/projects/alpha/src/app.txt"
  printf 'project private config\n' >"$source/projects/alpha/config/private.txt"
  printf 'durable decision\n' >"$source/data/decisions/choice.md"
  printf 'local config\n' >"$source/config/local"
  printf 'local state\n' >"$source/state/live"
  printf 'local no-mistakes\n' >"$source/.no-mistakes/live"
  ln -s ../src/app.txt "$source/projects/alpha/config/app-link"
  chmod 0400 "$source/projects/alpha/config/private.txt"
  git -C "$source" add README.md .gitignore .env .shadow-policy
  git -C "$source" commit -qm initial
}

new_fixture() {
  local root=$1
  mkdir -p "$root/destination-parent"
  make_source "$root/source"
}

run_replicante() {
  local source=$1 destination=$2
  shift 2
  REPLICANTE_TEST_MODE=1 \
    REPLICANTE_TEST_SOURCE="$source" \
    REPLICANTE_TEST_DESTINATION="$destination" \
    "$REPLICANTE" "$@"
}

snapshot_count() {
  find "$1/snapshots" -mindepth 1 -maxdepth 1 -type d -print | wc -l
}

object_count() {
  find "$1/objects" -mindepth 1 -maxdepth 1 -type f -print | wc -l
}

test_first_backup_and_verify() {
  local root source destination out snapshot
  root=$(fm_test_tmproot replicante-first)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"

  out=$(run_replicante "$source" "$destination" run)
  assert_contains "$out" 'replicated: snapshot=' 'first backup did not publish a snapshot'
  assert_present "$destination/.replicante-root.json" 'backup identity marker was not created'
  assert_present "$destination/latest" 'latest snapshot marker was not created'
  assert_present "$destination/objects" 'backup object store was not created'
  assert_present "$destination/snapshots" 'backup snapshot store was not created'
  [ "$(snapshot_count "$destination")" = 1 ] || fail 'first backup did not create exactly one snapshot'
  snapshot=$(cat "$destination/latest")
  assert_present "$destination/snapshots/$snapshot/manifest.json" 'snapshot manifest was not created'

  out=$(run_replicante "$source" "$destination" verify --restore-test)
  assert_contains "$out" 'with restore test' \
    'first snapshot restore verification did not pass'
  pass 'first backup creates a complete verifiable snapshot'
}

test_repeat_is_idempotent() {
  local root source destination out objects_before
  root=$(fm_test_tmproot replicante-repeat)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  run_replicante "$source" "$destination" run >/dev/null
  objects_before=$(object_count "$destination")

  out=$(run_replicante "$source" "$destination" run)
  assert_contains "$out" 'already current: snapshot=' 'repeated backup was not idempotent'
  [ "$(snapshot_count "$destination")" = 1 ] || fail 'repeated backup created a duplicate snapshot'
  [ "$(object_count "$destination")" = "$objects_before" ] || fail 'repeated backup recopied unchanged objects'
  pass 'repeated backup is idempotent'
}

test_incremental_changes_and_deletion_history() {
  local root source destination old_snapshot changed_snapshot deleted_snapshot out
  root=$(fm_test_tmproot replicante-incremental)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  run_replicante "$source" "$destination" run >/dev/null
  old_snapshot=$(cat "$destination/latest")

  printf 'updated project source\n' >"$source/projects/alpha/src/app.txt"
  printf 'new incremental file\n' >"$source/projects/alpha/src/new.txt"
  out=$(run_replicante "$source" "$destination" run)
  assert_contains "$out" 'replicated: snapshot=' 'incremental content change was not published'
  changed_snapshot=$(cat "$destination/latest")
  [ "$changed_snapshot" != "$old_snapshot" ] || fail 'content change reused the old snapshot'
  [ "$(snapshot_count "$destination")" = 2 ] || fail 'incremental change did not preserve both snapshots'

  rm "$source/projects/alpha/src/app.txt"
  out=$(run_replicante "$source" "$destination" run)
  assert_contains "$out" 'replicated: snapshot=' 'source deletion was not published'
  deleted_snapshot=$(cat "$destination/latest")
  [ "$deleted_snapshot" != "$changed_snapshot" ] || fail 'source deletion reused the old snapshot'

  run_replicante "$source" "$destination" restore \
    --snapshot "$changed_snapshot" --output "$root/restored-before-delete" --apply-modes >/dev/null
  assert_present "$root/restored-before-delete/projects/alpha/src/app.txt" \
    'historical snapshot did not preserve the deleted source file'
  assert_grep 'updated project source' "$root/restored-before-delete/projects/alpha/src/app.txt" \
    'historical snapshot restored the wrong file content'
  [ "$(stat -c '%a' "$root/restored-before-delete/projects/alpha/config/private.txt")" = 400 ] \
    || fail 'restoration did not apply the recorded source mode'
  run_replicante "$source" "$destination" restore \
    --snapshot "$deleted_snapshot" --output "$root/restored-after-delete" >/dev/null
  assert_absent "$root/restored-after-delete/projects/alpha/src/app.txt" \
    'latest snapshot resurrected a deleted source file'
  assert_present "$root/restored-after-delete/projects/alpha/src/new.txt" \
    'latest snapshot lost an incremental file'
  out=$(run_replicante "$source" "$destination" verify --all)
  assert_contains "$out" 'verified: snapshots=3' 'historical snapshots did not verify'
  pass 'incremental changes and deletions preserve historical restoration'
}

test_retention_is_configurable() {
  local root source destination
  root=$(fm_test_tmproot replicante-retention)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  run_replicante "$source" "$destination" run --retain 2 >/dev/null
  printf 'retention one\n' >"$source/README.md"
  run_replicante "$source" "$destination" run --retain 2 >/dev/null
  printf 'retention two\n' >"$source/README.md"
  run_replicante "$source" "$destination" run --retain 2 >/dev/null
  [ "$(snapshot_count "$destination")" = 2 ] || fail 'configured retention did not prune old snapshots'
  run_replicante "$source" "$destination" verify --all >/dev/null
  pass 'snapshot retention is configurable and retained snapshots remain verifiable'
}

test_retention_keeps_current_after_rollback() {
  local root source destination first_snapshot out
  root=$(fm_test_tmproot replicante-retention-rollback)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"

  run_replicante "$source" "$destination" run --retain 3 >/dev/null
  first_snapshot=$(cat "$destination/latest")
  printf 'rollback state one\n' >"$source/README.md"
  run_replicante "$source" "$destination" run --retain 3 >/dev/null
  printf 'rollback state two\n' >"$source/README.md"
  run_replicante "$source" "$destination" run --retain 3 >/dev/null
  printf 'canonical Firstmate backup fixture\n' >"$source/README.md"
  out=$(run_replicante "$source" "$destination" run --retain 2)

  assert_contains "$out" 'replicated: snapshot=' 'rollback to an existing snapshot was not published'
  [ "$(cat "$destination/latest")" = "$first_snapshot" ] \
    || fail 'rollback did not make the historical snapshot current'
  [ "$(snapshot_count "$destination")" = 2 ] \
    || fail 'retention skipped the current rollback snapshot'
  run_replicante "$source" "$destination" verify --all >/dev/null
  pass 'retention keeps the current snapshot when source state rolls back'
}

test_metadata_symlinks_are_refused() {
  local root source destination snapshot manifest external latest_target out
  root=$(fm_test_tmproot replicante-metadata-symlinks)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  run_replicante "$source" "$destination" run >/dev/null
  snapshot=$(cat "$destination/latest")
  manifest="$destination/snapshots/$snapshot/manifest.json"
  external="$root/external-manifest.json"
  cp "$manifest" "$external"
  rm "$manifest"
  ln -s "$external" "$manifest"

  if out=$(run_replicante "$source" "$destination" verify 2>&1); then
    fail 'manifest symlink was accepted'
  fi
  assert_contains "$out" 'snapshot is missing its manifest' \
    'manifest symlink refusal did not identify the unsafe metadata'

  rm "$manifest"
  cp "$external" "$manifest"
  latest_target="$root/external-latest"
  printf '%s\n' "$snapshot" >"$latest_target"
  rm "$destination/latest"
  ln -s "$latest_target" "$destination/latest"
  if out=$(run_replicante "$source" "$destination" verify 2>&1); then
    fail 'latest marker symlink was accepted'
  fi
  assert_contains "$out" 'latest snapshot marker must not be a symbolic link' \
    'latest marker symlink refusal did not identify the unsafe metadata'
  pass 'manifest and latest metadata symlinks are refused'
}

test_wrong_destination_is_refused() {
  local root source destination out
  root=$(fm_test_tmproot replicante-wrong-destination)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  mkdir "$destination"
  printf 'unrelated destination\n' >"$destination/unrelated.txt"

  if out=$(run_replicante "$source" "$destination" run 2>&1); then
    fail 'uninitialized nonempty destination was accepted'
  fi
  assert_contains "$out" 'no matching replicante identity marker' \
    'wrong destination refusal did not identify the identity boundary'
  assert_grep 'unrelated destination' "$destination/unrelated.txt" \
    'wrong destination content was changed'
  pass 'wrong destination identity is refused without touching its content'
}

test_concurrent_lock_is_refused() {
  local root source destination lock out
  root=$(fm_test_tmproot replicante-lock)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  lock="$root/destination-parent/.Firstmate-Backup.replicante.lock"
  mkdir "$lock"
  printf 'other process\n' >"$lock/owner"

  if out=$(run_replicante "$source" "$destination" run 2>&1); then
    fail 'concurrent backup was accepted'
  fi
  assert_contains "$out" 'holds the lock' 'concurrent backup refusal did not identify the lock'
  assert_absent "$destination" 'locked backup created a destination'
  pass 'concurrent backup execution is serialized by an atomic lock'
}

test_unsupported_source_preserves_absent_destination() {
  local root source destination out
  root=$(fm_test_tmproot replicante-special)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  mkfifo "$source/projects/alpha/unsupported-fifo"

  if out=$(run_replicante "$source" "$destination" run 2>&1); then
    fail 'unsupported source entry was accepted'
  fi
  assert_contains "$out" 'special file is not supported' \
    'unsupported source refusal did not identify the source limitation'
  assert_absent "$destination" 'unsupported source entry left a partial first backup'
  pass 'unsupported source entry fails closed before creating a first backup'
}

test_corruption_is_refused() {
  local root source destination object latest out
  root=$(fm_test_tmproot replicante-corrupt)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/Firstmate-Backup"
  run_replicante "$source" "$destination" run >/dev/null
  latest=$(cat "$destination/latest")
  object=$(find "$destination/objects" -type f -print -quit)
  printf 'corrupt object\n' >"$object"

  if out=$(run_replicante "$source" "$destination" verify 2>&1); then
    fail 'corrupt object passed verification'
  fi
  assert_contains "$out" 'object hash or size is corrupt' \
    'corruption refusal did not identify the object integrity failure'
  if out=$(run_replicante "$source" "$destination" run 2>&1); then
    fail 'corrupt prior backup was accepted for incremental run'
  fi
  assert_contains "$out" 'object hash or size is corrupt' \
    'incremental corruption refusal did not preserve the integrity boundary'
  [ "$(cat "$destination/latest")" = "$latest" ] || fail 'corruption changed latest snapshot'
  pass 'corrupt backup objects are refused without advancing the backup'
}

test_first_backup_and_verify
test_repeat_is_idempotent
test_incremental_changes_and_deletion_history
test_retention_is_configurable
test_retention_keeps_current_after_rollback
test_metadata_symlinks_are_refused
test_wrong_destination_is_refused
test_concurrent_lock_is_refused
test_unsupported_source_preserves_absent_destination
test_corruption_is_refused
