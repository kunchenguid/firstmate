#!/usr/bin/env bash
# tests/fm-record-export.test.sh - fixed allowlist live export and teardown archives.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPORTER="$ROOT/bin/fm-record-export.sh"
TMP_ROOT=$(fm_test_tmproot fm-record-export)

mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '%s\n' "$home"
}

run_export() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$EXPORTER" "$@"
}

test_sync_is_off_when_config_is_absent() {
  local home rc=0
  home=$(make_home sync-off)
  printf 'private\n' > "$home/data/projects.md"
  run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "record export without config"
  [ ! -s "$home/stdout" ] || fail "config-absent sync wrote stdout"
  [ ! -s "$home/stderr" ] || fail "config-absent sync wrote stderr"
  [ "$(LC_ALL=C ls -1A "$home" | tr '\n' ' ')" = "config data state stderr stdout " ] \
    || fail "config-absent sync created an export artifact"
  pass "record export sync is inert when config is absent"
}

test_sync_copies_only_the_v1_allowlist() {
  local home export_root rc=0 rel
  home=$(make_home sync-allowlist)
  export_root="$TMP_ROOT/export-allowlist"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  mkdir -p "$home/data/task-a" "$home/data/unrelated" \
    "$home/state/task-a.inbox/handled" "$home/state/other.inbox/handled"
  printf 'projects\n' > "$home/data/projects.md"
  printf 'backlog\n' > "$home/data/backlog.md"
  printf 'done archive\n' > "$home/data/done-archive.md"
  printf 'brief\n' > "$home/data/task-a/brief.md"
  printf 'report\n' > "$home/data/task-a/report.md"
  printf 'status zero\n' > "$home/data/task-a/status.log"
  printf 'status one\n' > "$home/data/task-a/status.1.log"
  printf 'do not copy\n' > "$home/data/task-a/notes.txt"
  printf 'do not scan\n' > "$home/data/unrelated/private.md"
  printf 'ledger\n' > "$home/state/fleet-ledger.jsonl"
  printf 'meta\n' > "$home/state/task-a.meta"
  printf 'status\n' > "$home/state/task-a.status"
  printf 'pending\n' > "$home/state/task-a.inbox/001.msg"
  printf 'handled\n' > "$home/state/task-a.inbox/handled/002.msg"
  printf 'internal\n' > "$home/state/task-a.inbox/.ring-state"
  printf 'unknown\n' > "$home/state/task-a.inbox/not-a-record"
  printf 'other internal\n' > "$home/state/other.inbox/.ring-state"
  run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "allowlisted live sync: $(cat "$home/stderr")"
  for rel in \
    data/projects.md data/backlog.md data/done-archive.md \
    data/task-a/brief.md data/task-a/report.md data/task-a/status.log data/task-a/status.1.log \
    state/fleet-ledger.jsonl state/task-a.meta state/task-a.status \
    state/task-a.inbox/001.msg state/task-a.inbox/handled/002.msg; do
    cmp -s "$home/$rel" "$export_root/live/$rel" || fail "sync did not copy $rel byte-exact"
    [ "$(mode_of "$export_root/live/$rel")" = 640 ] || fail "sync did not set mode 0640 on $rel"
  done
  for rel in data/task-a/notes.txt data/unrelated/private.md \
    state/task-a.inbox/.ring-state state/task-a.inbox/not-a-record state/other.inbox/.ring-state; do
    assert_absent "$export_root/live/$rel" "sync copied non-allowlisted $rel"
  done
  while IFS= read -r rel; do
    [ "$(mode_of "$rel")" = 750 ] || fail "sync did not set mode 0750 on directory $rel"
  done < <(find "$export_root" -type d)
  pass "record export sync copies only the fixed v1 allowlist with restrictive modes"
}

test_sync_replaces_files_atomically() {
  local home export_root rc=0
  home=$(make_home sync-atomic)
  export_root="$TMP_ROOT/export-atomic"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  mkdir -p "$export_root/live/data" "$home/fakebin"
  printf 'new bytes\n' > "$home/data/projects.md"
  printf 'old bytes\n' > "$export_root/live/data/projects.md"
  cat > "$home/fakebin/cp" <<'SH'
#!/usr/bin/env bash
printf 'partial' > "${*: -1}"
exit 1
SH
  chmod +x "$home/fakebin/cp"
  PATH="$home/fakebin:$PATH" run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "sync accepted a failed staged copy"
  assert_grep 'old bytes' "$export_root/live/data/projects.md" "failed sync replaced the prior complete file"
  [ "$(find "$export_root/live/data" -maxdepth 1 -name '.record-export.*' | wc -l | tr -d ' ')" = 0 ] \
    || fail "failed sync left a staging file"
  pass "record export sync stages before atomically replacing a live file"
}

test_sync_accepts_an_absolute_export_root_with_spaces() {
  local home export_root rc=0
  home=$(make_home sync-root-spaces)
  export_root="$TMP_ROOT/export root with spaces"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf 'projects\n' > "$home/data/projects.md"
  run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "absolute export root with spaces: $(cat "$home/stderr")"
  assert_grep 'projects' "$export_root/live/data/projects.md" "sync did not use an absolute export root with spaces"
  pass "record export accepts an absolute export root with spaces"
}

test_sync_refuses_malformed_config_and_unsafe_paths() {
  local home export_root outside rc case_name
  for case_name in relative multiline config-link root-link source-link source-fifo destination-link unsafe-task; do
    home=$(make_home "sync-unsafe-$case_name")
    export_root="$TMP_ROOT/export-unsafe-$case_name"
    outside="$TMP_ROOT/outside-$case_name"
    mkdir -p "$outside"
    printf 'outside sentinel\n' > "$outside/sentinel"
    printf '%s\n' "$export_root" > "$home/config/record-export-root"
    printf 'projects\n' > "$home/data/projects.md"
    case "$case_name" in
      relative) printf 'relative/path\n' > "$home/config/record-export-root" ;;
      multiline) printf '%s\n%s\n' "$export_root" "$outside" > "$home/config/record-export-root" ;;
      config-link)
        printf '%s\n' "$export_root" > "$home/config/export-target"
        rm "$home/config/record-export-root"
        ln -s "$home/config/export-target" "$home/config/record-export-root"
        ;;
      root-link)
        rm -rf "$export_root"
        ln -s "$outside" "$export_root"
        ;;
      source-link)
        rm "$home/data/projects.md"
        ln -s "$outside/sentinel" "$home/data/projects.md"
        ;;
      source-fifo)
        rm "$home/data/projects.md"
        mkfifo "$home/data/projects.md"
        ;;
      destination-link)
        mkdir -p "$export_root/live/data"
        ln -s "$outside/sentinel" "$export_root/live/data/projects.md"
        ;;
      unsafe-task)
        mkdir -p "$home/data/task space"
        printf 'brief\n' > "$home/data/task space/brief.md"
        ;;
    esac
    rc=0
    run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "sync accepted unsafe $case_name input"
    assert_grep 'outside sentinel' "$outside/sentinel" "unsafe $case_name input changed its target"
  done
  pass "record export sync refuses malformed config, traversal-shaped names, symlinks, and non-regular files"
}

write_archive_fixture() {  # <home> <spawn-gen>
  local home=$1 spawn_gen=$2
  mkdir -p "$home/state/task-a.inbox/handled"
  printf 'task=task-a\nspawn_gen=%s\nkind=ship\n' "$spawn_gen" > "$home/state/task-a.meta"
  printf 'working: underway\ndone: landed\n' > "$home/state/task-a.status"
  printf 'pending captain text\n' > "$home/state/task-a.inbox/001.msg"
  printf 'handled captain text\n' > "$home/state/task-a.inbox/handled/002.msg"
}

test_archive_commits_manifest_last_with_integrity_metadata() {
  local home export_root archive rc=0 rel source_rel bytes digest
  home=$(make_home archive-manifest)
  export_root="$TMP_ROOT/export-archive-manifest"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" s1700000000.1.abc
  FM_STATE_OVERRIDE="$home/state" run_export "$home" archive-task task-a \
    > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "archive task: $(cat "$home/stderr")"
  archive="$export_root/archive/task-a/s1700000000.1.abc"
  assert_present "$archive/manifest.v1.json" "archive did not commit its manifest"
  for rel in meta status inbox/001.msg inbox/handled/002.msg; do
    assert_present "$archive/$rel" "archive omitted $rel"
    [ "$(mode_of "$archive/$rel")" = 640 ] || fail "archive did not set mode 0640 on $rel"
  done
  while IFS= read -r rel; do
    [ "$(mode_of "$rel")" = 750 ] || fail "archive did not set mode 0750 on directory $rel"
  done < <(find "$export_root" -type d)
  jq -e '
    .schema == "firstmate-record-export-archive.v1"
    and .schema_version == 1
    and .task == "task-a"
    and .spawn_gen == "s1700000000.1.abc"
    and (.captured_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
    and .complete == true
    and ([.files[].source] == [
      "state/task-a.meta",
      "state/task-a.status",
      "state/task-a.inbox/001.msg",
      "state/task-a.inbox/handled/002.msg"
    ])
  ' "$archive/manifest.v1.json" >/dev/null || fail "archive manifest schema or ordered source list is wrong"
  for rel in meta status inbox/001.msg inbox/handled/002.msg; do
    case "$rel" in
      meta) source_rel=state/task-a.meta ;;
      status) source_rel=state/task-a.status ;;
      *) source_rel="state/task-a.$rel" ;;
    esac
    bytes=$(wc -c < "$home/$source_rel" | tr -d ' ')
    digest=$(shasum -a 256 "$home/$source_rel" | awk '{print $1}')
    jq -e --arg source "$source_rel" --argjson bytes "$bytes" --arg digest "$digest" '
      any(.files[]; .source == $source and .bytes == $bytes and .sha256 == $digest)
    ' "$archive/manifest.v1.json" >/dev/null || fail "archive manifest integrity is wrong for $source_rel"
  done
  pass "teardown archive commits a complete v1 manifest after every allowlisted source"
}

test_archive_is_off_before_any_state_read_when_config_is_absent() {
  local home rc=0
  home=$(make_home archive-off)
  rm -rf "$home/state"
  FM_STATE_OVERRIDE="$home/missing-state" run_export "$home" archive-task task-a \
    > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "config-absent archive"
  [ ! -s "$home/stdout" ] || fail "config-absent archive wrote stdout"
  [ ! -s "$home/stderr" ] || fail "config-absent archive wrote stderr"
  assert_absent "$home/missing-state" "config-absent archive touched the state path"
  pass "teardown archive is inert before any state read when config is absent"
}

test_archive_retry_is_idempotent_and_generations_never_overwrite() {
  local home export_root first second before rc=0
  home=$(make_home archive-retry)
  export_root="$TMP_ROOT/export-archive-retry"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" generation-one
  run_export "$home" archive-task task-a > "$home/first.out" 2> "$home/first.err" || rc=$?
  expect_code 0 "$rc" "first generation archive"
  first="$export_root/archive/task-a/generation-one"
  before=$(shasum -a 256 "$first/manifest.v1.json" | awk '{print $1}')
  rc=0
  run_export "$home" archive-task task-a > "$home/retry.out" 2> "$home/retry.err" || rc=$?
  expect_code 0 "$rc" "idempotent archive retry"
  [ "$before" = "$(shasum -a 256 "$first/manifest.v1.json" | awk '{print $1}')" ] \
    || fail "idempotent retry rewrote the committed manifest"
  printf 'done: changed after commit\n' >> "$home/state/task-a.status"
  rc=0
  run_export "$home" archive-task task-a > "$home/changed.out" 2> "$home/changed.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "archive retry accepted changed sources for a committed generation"
  assert_grep 'committed archive differs from current sources' "$home/changed.err" \
    "changed-source retry did not report the immutable generation conflict"
  printf 'task=task-a\nspawn_gen=generation-two\nkind=ship\n' > "$home/state/task-a.meta"
  rc=0
  run_export "$home" archive-task task-a > "$home/second.out" 2> "$home/second.err" || rc=$?
  expect_code 0 "$rc" "second generation archive"
  second="$export_root/archive/task-a/generation-two"
  assert_present "$second/manifest.v1.json" "reused task id did not create a new generation"
  [ "$before" = "$(shasum -a 256 "$first/manifest.v1.json" | awk '{print $1}')" ] \
    || fail "new generation overwrote the prior generation"
  pass "teardown archive retries idempotently and reused task IDs stay separated by spawn_gen"
}

test_archive_refuses_a_corrupt_committed_manifest() {
  local home export_root manifest rc=0
  home=$(make_home archive-corrupt-manifest)
  export_root="$TMP_ROOT/export-archive-corrupt-manifest"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" committed-generation
  run_export "$home" archive-task task-a > "$home/first.out" 2> "$home/first.err" || rc=$?
  expect_code 0 "$rc" "initial archive for corrupt manifest case"
  manifest="$export_root/archive/task-a/committed-generation/manifest.v1.json"
  sed 's/"task": "task-a"/"task": "another-task"/' "$manifest" > "$home/manifest.tmp"
  mv "$home/manifest.tmp" "$manifest"
  rc=0
  run_export "$home" archive-task task-a > "$home/retry.out" 2> "$home/retry.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "archive retry accepted a corrupt committed manifest"
  assert_present "$home/state/task-a.meta" "corrupt manifest retry removed live metadata"
  pass "teardown archive rejects a corrupt committed manifest"
}

test_archive_detects_a_source_change_during_capture() {
  local home export_root archive rc=0
  home=$(make_home archive-source-race)
  export_root="$TMP_ROOT/export-archive-source-race"
  archive="$export_root/archive/task-a/racing-generation"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" racing-generation
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/cp" <<'SH'
#!/usr/bin/env bash
/bin/cp "$@" || exit $?
case "$2" in
  */task-a.status) printf 'late append\n' >> "$2" ;;
esac
SH
  chmod +x "$home/fakebin/cp"
  PATH="$home/fakebin:$PATH" run_export "$home" archive-task task-a \
    > "$home/stdout" 2> "$home/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "archive committed while a source changed during capture"
  assert_absent "$archive/manifest.v1.json" "source race committed a manifest"
  assert_present "$home/state/task-a.meta" "source race removed live metadata"
  assert_grep 'late append' "$home/state/task-a.status" "source-race fixture did not mutate the source"
  pass "teardown archive refuses to commit when a source changes during capture"
}

test_archive_repairs_only_an_uncommitted_same_generation() {
  local home export_root archive rc=0
  home=$(make_home archive-partial)
  export_root="$TMP_ROOT/export-archive-partial"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" partial-generation
  archive="$export_root/archive/task-a/partial-generation"
  mkdir -p "$archive"
  printf 'stale partial bytes\n' > "$archive/meta"
  run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "partial generation retry: $(cat "$home/stderr")"
  cmp -s "$home/state/task-a.meta" "$archive/meta" || fail "retry did not repair the uncommitted same generation"
  assert_present "$archive/manifest.v1.json" "retry did not commit the repaired generation"
  pass "teardown archive safely repairs an uncommitted same-generation attempt"
}

test_archive_allows_missing_optional_records() {
  local home export_root archive rc=0
  home=$(make_home archive-optional)
  export_root="$TMP_ROOT/export-archive-optional"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf 'spawn_gen=no-status\n' > "$home/state/task-a.meta"
  run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "archive without optional records"
  archive="$export_root/archive/task-a/no-status"
  assert_present "$archive/meta" "archive without status lost mandatory metadata"
  assert_absent "$archive/status" "archive fabricated a missing status"
  jq -e '.complete == true and [.files[].source] == ["state/task-a.meta"]' \
    "$archive/manifest.v1.json" >/dev/null || fail "missing optional records made the archive incomplete"
  pass "teardown archive treats absent status and inbox records as a complete capture"
}

test_archive_refuses_unsafe_sources_and_destinations() {
  local home export_root outside rc case_name
  for case_name in missing-gen duplicate-gen unsafe-gen meta-link status-fifo inbox-link destination-link unknown-partial; do
    home=$(make_home "archive-unsafe-$case_name")
    export_root="$TMP_ROOT/export-archive-unsafe-$case_name"
    outside="$TMP_ROOT/archive-outside-$case_name"
    mkdir -p "$outside"
    printf 'outside sentinel\n' > "$outside/sentinel"
    printf '%s\n' "$export_root" > "$home/config/record-export-root"
    write_archive_fixture "$home" safe-generation
    case "$case_name" in
      missing-gen) grep -v '^spawn_gen=' "$home/state/task-a.meta" > "$home/state/meta.tmp"; mv "$home/state/meta.tmp" "$home/state/task-a.meta" ;;
      duplicate-gen) printf 'spawn_gen=other\n' >> "$home/state/task-a.meta" ;;
      unsafe-gen) sed 's/safe-generation/../' "$home/state/task-a.meta" > "$home/state/meta.tmp"; mv "$home/state/meta.tmp" "$home/state/task-a.meta" ;;
      meta-link) rm "$home/state/task-a.meta"; ln -s "$outside/sentinel" "$home/state/task-a.meta" ;;
      status-fifo) rm "$home/state/task-a.status"; mkfifo "$home/state/task-a.status" ;;
      inbox-link) rm "$home/state/task-a.inbox/001.msg"; ln -s "$outside/sentinel" "$home/state/task-a.inbox/001.msg" ;;
      destination-link)
        mkdir -p "$export_root/archive/task-a"
        ln -s "$outside" "$export_root/archive/task-a/safe-generation"
        ;;
      unknown-partial)
        mkdir -p "$export_root/archive/task-a/safe-generation"
        printf 'unknown\n' > "$export_root/archive/task-a/safe-generation/unknown"
        ;;
    esac
    rc=0
    run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "archive accepted unsafe $case_name input"
    assert_present "$home/state/task-a.meta" "unsafe $case_name archive removed metadata"
    assert_grep 'outside sentinel' "$outside/sentinel" "unsafe $case_name archive changed its target"
  done
  pass "teardown archive refuses malformed generations, unknown artifacts, symlinks, and non-regular files"
}

test_archive_retention_prunes_only_old_committed_generations() {
  local home export_root archive_root rc=0
  home=$(make_home archive-retention)
  export_root="$TMP_ROOT/export-archive-retention"
  archive_root="$export_root/archive"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" current-generation
  mkdir -p "$archive_root/old-task/old-generation" \
    "$archive_root/current-task/current-generation" \
    "$archive_root/incomplete-task/incomplete-generation" \
    "$archive_root/unknown-task/unknown-generation"
  printf '{}\n' > "$archive_root/old-task/old-generation/manifest.v1.json"
  printf '{}\n' > "$archive_root/current-task/current-generation/manifest.v1.json"
  printf 'partial\n' > "$archive_root/incomplete-task/incomplete-generation/meta"
  printf '{}\n' > "$archive_root/unknown-task/unknown-generation/manifest.v1.json"
  printf 'unknown\n' > "$archive_root/unknown-task/unknown-generation/extra"
  touch -t 200001010000 "$archive_root/old-task/old-generation/manifest.v1.json" \
    "$archive_root/incomplete-task/incomplete-generation/meta" \
    "$archive_root/unknown-task/unknown-generation/manifest.v1.json"
  run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "archive retention"
  assert_absent "$archive_root/old-task/old-generation" "retention kept an expired committed generation"
  assert_present "$archive_root/current-task/current-generation" "retention removed a current generation"
  assert_present "$archive_root/incomplete-task/incomplete-generation" "retention removed an incomplete generation"
  assert_present "$archive_root/unknown-task/unknown-generation" "retention removed a generation with unknown artifacts"
  assert_grep 'warning: refusing to prune unsafe record export archive' "$home/stderr" \
    "unsafe retention candidate did not warn"
  pass "record export retention mirrors 30 completed days and prunes only owned committed generations"
}

test_sync_is_off_when_config_is_absent
test_sync_copies_only_the_v1_allowlist
test_sync_replaces_files_atomically
test_sync_accepts_an_absolute_export_root_with_spaces
test_sync_refuses_malformed_config_and_unsafe_paths
test_archive_commits_manifest_last_with_integrity_metadata
test_archive_is_off_before_any_state_read_when_config_is_absent
test_archive_retry_is_idempotent_and_generations_never_overwrite
test_archive_refuses_a_corrupt_committed_manifest
test_archive_detects_a_source_change_during_capture
test_archive_repairs_only_an_uncommitted_same_generation
test_archive_allows_missing_optional_records
test_archive_refuses_unsafe_sources_and_destinations
test_archive_retention_prunes_only_old_committed_generations

echo "ALL TESTS PASSED"
