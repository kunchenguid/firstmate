#!/usr/bin/env bash
# Behavioral tests for the fail-closed fm-shadow replica command.
#
# Every case uses a temporary source Git worktree and destination parent.
# No test reaches the configured Windows destination or the live Firstmate home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

SHADOW="$ROOT/bin/fm-shadow.sh"

make_source() {
  local source=$1
  mkdir -p "$source"
  git init -q -b main "$source"
  git -C "$source" config user.name 'Firstmate Shadow Tests'
  git -C "$source" config user.email 'shadow-tests@example.invalid'
  printf 'canonical Firstmate fixture\n' >"$source/README.md"
  printf 'source-owned manifest name\n' >"$source/.shadow-manifest"
  printf 'source-owned policy name\n' >"$source/.shadow-policy"
  printf '%s\n' 'projects/' 'data/' 'config/' 'state/' '.no-mistakes/' '.env' >"$source/.gitignore"
  git -C "$source" add README.md .gitignore .shadow-manifest .shadow-policy
  git -C "$source" commit -qm initial

  mkdir -p "$source/projects/alpha/src" \
    "$source/projects/alpha/config" \
    "$source/projects/alpha/.treehouse" \
    "$source/projects/alpha/logs" \
    "$source/projects/RocoData" \
    "$source/data/decisions" \
    "$source/config" \
    "$source/state" \
    "$source/.no-mistakes"
  printf 'visible project file\n' >"$source/projects/alpha/src/app.txt"
  printf 'private project config\n' >"$source/projects/alpha/config/private.txt"
  mkdir -p "$source/projects/alpha/.git"
  printf 'nested project Git metadata\n' >"$source/projects/alpha/.git/config"
  printf 'agent worktree\n' >"$source/projects/alpha/.treehouse/agent.txt"
  printf 'volatile log\n' >"$source/projects/alpha/logs/run.log"
  printf 'live RocoData\n' >"$source/projects/RocoData/live.sqlite"
  printf 'durable decision\n' >"$source/data/decisions/choice.md"
  printf 'non-document data\n' >"$source/data/decisions/private.txt"
  printf 'local config\n' >"$source/config/local"
  printf 'local state\n' >"$source/state/live"
  printf 'local no-mistakes state\n' >"$source/.no-mistakes/live"
  printf 'local secret\n' >"$source/.env"
}

new_fixture() {
  local root=$1
  mkdir -p "$root/destination-parent"
  make_source "$root/source"
}

run_shadow() {
  # Git's test hook emulates a foreign-owned checkout without changing fixture ownership.
  GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$SHADOW" --source "$1" --destination "$2"
}

test_first_replica_copies_identity_and_complete_tree() {
  local root source destination controls out source_head
  root=$(fm_test_tmproot shadow-first)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  controls="$root/destination-parent/.shadow-control.shadow"
  source_head=$(git -C "$source" rev-parse HEAD)

  out=$(run_shadow "$source" "$destination")
  assert_contains "$out" 'replicated:' 'first replica reports a completed publish'
  [ "$(git -C "$destination" rev-parse HEAD)" = "$source_head" ] \
    || fail 'first replica commit identity differs from source HEAD'
  [ "$(git -C "$destination" symbolic-ref --short HEAD)" = main ] \
    || fail 'first replica is not checked out on the default branch'
  assert_present "$destination/projects/alpha/src/app.txt" \
    'project working-tree content was not mirrored'
  assert_present "$destination/projects/alpha/config/private.txt" \
    'project config was not mirrored'
  assert_present "$destination/projects/alpha/.treehouse/agent.txt" \
    'project .treehouse content was not mirrored'
  assert_present "$destination/projects/alpha/logs/run.log" \
    'project log was not mirrored'
  assert_present "$destination/projects/alpha/.git/config" \
    'nested project Git metadata was not mirrored'
  assert_present "$destination/projects/RocoData/live.sqlite" \
    'RocoData content inside the source root was not mirrored'
  assert_present "$destination/data/decisions/choice.md" \
    'durable Markdown decision was not mirrored'
  assert_present "$destination/data/decisions/private.txt" \
    'non-Markdown data was not mirrored'
  assert_present "$destination/config/local" 'config content was not mirrored'
  assert_present "$destination/state/live" 'state content was not mirrored'
  assert_present "$destination/.no-mistakes/live" '.no-mistakes content was not mirrored'
  assert_present "$destination/.env" '.env content was not mirrored'
  assert_grep 'source-owned manifest name' "$destination/.shadow-manifest" \
    'source-owned manifest path was not preserved'
  assert_grep 'source-owned policy name' "$destination/.shadow-policy" \
    'source-owned policy path was not preserved'
  assert_present "$controls/manifest" 'replica manifest sidecar was not written'
  assert_present "$controls/policy" 'replica policy sidecar was not written'
  assert_grep '.shadow-manifest' "$controls/manifest" \
    'manifest did not enumerate the source-owned manifest path'
  assert_grep '.shadow-policy' "$controls/manifest" \
    'manifest did not enumerate the source-owned policy path'
  assert_present "$destination/.git/index" 'source Git metadata was not mirrored'
  pass 'first replica preserves commit identity and mirrors the complete source tree'
}

test_9p_content_fixture_ignores_source_metadata_restrictions() {
  local root source destination out
  root=$(fm_test_tmproot shadow-9p-content)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  chmod 0444 "$source/projects/alpha/config/private.txt"
  ln -s ../src/app.txt "$source/projects/alpha/config/app-link"

  out=$(run_shadow "$source" "$destination")
  assert_contains "$out" 'replicated:' '9p content fixture was not published'
  assert_grep 'private project config' "$destination/projects/alpha/config/private.txt" \
    'content copy failed for a metadata-restricted source file'
  [ -L "$destination/projects/alpha/config/app-link" ] \
    || fail 'content fixture did not preserve the source symlink'
  pass '9p content fixture copies bytes and symlinks without source metadata updates'
}

test_mode_only_destination_drift_is_ignored_on_9p() {
  local root source destination out
  root=$(fm_test_tmproot shadow-mode-drift)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  run_shadow "$source" "$destination" >/dev/null
  chmod 0777 "$destination/README.md"

  out=$(run_shadow "$source" "$destination")
  assert_contains "$out" 'already current:' \
    '9p mode-only destination drift was treated as content drift'
  assert_grep 'canonical Firstmate fixture' "$destination/README.md" \
    'mode-only destination validation changed file content'
  pass '9p mode-only destination drift is ignored while content remains validated'
}

test_repeated_replica_is_idempotent_and_tracks_complete_working_tree() {
  local root source destination controls out manifest_before
  root=$(fm_test_tmproot shadow-repeat)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  controls="$root/destination-parent/.shadow-control.shadow"
  run_shadow "$source" "$destination" >/dev/null
  manifest_before=$(cat "$controls/manifest")

  out=$(run_shadow "$source" "$destination")
  assert_contains "$out" 'already current:' 'repeated replica was not idempotent'
  [ "$(cat "$controls/manifest")" = "$manifest_before" ] \
    || fail 'idempotent replica changed its manifest'

  printf 'updated project snapshot\n' >"$source/projects/alpha/src/app.txt"
  out=$(run_shadow "$source" "$destination")
  assert_contains "$out" 'replicated:' 'changed source content was not published'
  assert_grep 'updated project snapshot' "$destination/projects/alpha/src/app.txt" \
    'changed source content did not reach destination'
  pass 'repeated replica is stable and refreshes complete source content'
}

test_dirty_destination_is_preserved() {
  local root source destination before out
  root=$(fm_test_tmproot shadow-dirty)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  run_shadow "$source" "$destination" >/dev/null
  before=$(git -C "$destination" rev-parse HEAD)
  printf 'captain changed the output\n' >"$destination/README.md"

  if out=$(run_shadow "$source" "$destination" 2>&1); then
    fail 'dirty destination was accepted'
  fi
  assert_contains "$out" 'destination content differs from manifest' \
    'dirty destination refusal did not explain the safety boundary'
  assert_grep 'captain changed the output' "$destination/README.md" \
    'dirty destination content was overwritten'
  [ "$(git -C "$destination" rev-parse HEAD)" = "$before" ] \
    || fail 'dirty destination commit changed during refusal'
  pass 'dirty destination is refused and preserved byte-for-byte'
}

test_divergent_destination_is_preserved() {
  local root source destination before out
  root=$(fm_test_tmproot shadow-divergent)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  run_shadow "$source" "$destination" >/dev/null
  git -C "$destination" -c user.name='Shadow Test' \
    -c user.email='shadow-tests@example.invalid' commit --allow-empty -qm divergent
  before=$(git -C "$destination" rev-parse HEAD)

  if out=$(run_shadow "$source" "$destination" 2>&1); then
    fail 'divergent destination was accepted'
  fi
  assert_contains "$out" 'diverges from source commit' \
    'divergent destination refusal did not identify the ancestry failure'
  [ "$(git -C "$destination" rev-parse HEAD)" = "$before" ] \
    || fail 'divergent destination commit changed during refusal'
  pass 'divergent destination is refused without rewriting its history'
}

test_concurrent_lock_is_fail_closed() {
  local root source destination lock out
  root=$(fm_test_tmproot shadow-lock)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  lock="$root/destination-parent/.shadow.lock"
  mkdir "$lock"
  printf 'other process\n' >"$lock/owner"

  if out=$(run_shadow "$source" "$destination" 2>&1); then
    fail 'concurrent lock was not enforced'
  fi
  assert_contains "$out" 'holds the lock' 'lock refusal did not identify the active lock'
  assert_absent "$destination" 'locked first replica created destination output'
  pass 'concurrent execution is serialized by an atomic lock directory'
}

test_external_symlink_target_is_not_traversed() {
  local root source destination controls external out
  root=$(fm_test_tmproot shadow-external)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  controls="$root/destination-parent/.shadow-control.shadow"
  external="$root/external-RocoData"
  mkdir "$external"
  printf 'outside source root\n' >"$external/outside.sqlite"
  ln -s "$external" "$source/projects/alpha/external-roco-data"

  out=$(run_shadow "$source" "$destination")
  assert_contains "$out" 'replicated:' 'external symlink fixture was not published'
  [ -L "$destination/projects/alpha/external-roco-data" ] \
    || fail 'external symlink was followed instead of mirrored as a link'
  assert_grep 'external-roco-data' "$controls/manifest" \
    'external symlink path was not recorded in the manifest'
  assert_no_grep 'outside.sqlite' "$controls/manifest" \
    'content outside the source root was traversed into the manifest'
  pass 'symlink targets outside the source root are not traversed'
}

test_staging_failure_preserves_previous_replica() {
  local root source destination before out
  root=$(fm_test_tmproot shadow-recovery)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  run_shadow "$source" "$destination" >/dev/null
  before=$(git -C "$destination" rev-parse HEAD)
  mkfifo "$source/projects/alpha/unsupported-fifo"

  if out=$(run_shadow "$source" "$destination" 2>&1); then
    fail 'unsupported source entry was accepted'
  fi
  assert_contains "$out" 'special file is not allowed in source tree' \
    'unsupported source entry did not stop the mirror'
  [ "$(git -C "$destination" rev-parse HEAD)" = "$before" ] \
    || fail 'staging failure changed destination history'
  assert_grep 'canonical Firstmate fixture' "$destination/README.md" \
    'staging failure changed destination content'
  [ -z "$(find "$root/destination-parent" -maxdepth 1 -name '.shadow-stage.*' -print -quit)" ] \
    || fail 'staging failure left a partial staging directory'
  pass 'unsupported source entry leaves the prior replica intact and cleans temporary output'
}

test_manifest_tamper_is_refused() {
  local root source destination controls before out
  root=$(fm_test_tmproot shadow-manifest)
  new_fixture "$root"
  source="$root/source"
  destination="$root/destination-parent/shadow"
  controls="$root/destination-parent/.shadow-control.shadow"
  run_shadow "$source" "$destination" >/dev/null
  before=$(git -C "$destination" rev-parse HEAD)
  sed -i '2s/$/tampered/' "$controls/manifest"

  if out=$(run_shadow "$source" "$destination" 2>&1); then
    fail 'tampered manifest was accepted'
  fi
  assert_contains "$out" 'manifest hash does not match' \
    'manifest tamper refusal did not identify the integrity failure'
  [ "$(git -C "$destination" rev-parse HEAD)" = "$before" ] \
    || fail 'manifest tamper changed destination history'
  pass 'manifest hash tamper is refused without touching destination output'
}

test_first_replica_copies_identity_and_complete_tree
test_9p_content_fixture_ignores_source_metadata_restrictions
test_mode_only_destination_drift_is_ignored_on_9p
test_repeated_replica_is_idempotent_and_tracks_complete_working_tree
test_dirty_destination_is_preserved
test_divergent_destination_is_preserved
test_concurrent_lock_is_fail_closed
test_external_symlink_target_is_not_traversed
test_staging_failure_preserves_previous_replica
test_manifest_tamper_is_refused
