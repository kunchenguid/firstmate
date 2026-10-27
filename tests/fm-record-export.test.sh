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
  [ "$(find "$home" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')" = "config data state stderr stdout " ] \
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
  printf 'old bytes\n' > "$home/data/projects.md"
  run_export "$home" sync > "$home/initial.out" 2> "$home/initial.err" \
    || fail "atomic snapshot setup failed: $(cat "$home/initial.err")"
  printf 'new bytes\n' > "$home/data/projects.md"
  chmod 000 "$home/data/projects.md"
  run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
  chmod 0644 "$home/data/projects.md"
  [ "$rc" -ne 0 ] || fail "sync accepted an unreadable source"
  assert_grep 'old bytes' "$export_root/live/data/projects.md" "failed sync replaced the prior complete file"
  pass "record export sync leaves the prior live snapshot intact when capture fails"
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

test_sync_requires_a_dedicated_disjoint_single_home_root() {
  local scope home other export_root rc case_name
  for case_name in home ancestor descendant nonempty; do
    scope="$TMP_ROOT/root-boundary-$case_name"
    mkdir -p "$scope"
    home="$scope/home"
    mkdir -p "$home/config" "$home/data" "$home/state"
    printf 'projects\n' > "$home/data/projects.md"
    case "$case_name" in
      home) export_root=$home ;;
      ancestor) export_root=$scope ;;
      descendant) export_root="$home/export" ;;
      nonempty)
        export_root="$scope/export"
        mkdir -p "$export_root"
        printf 'unowned sentinel\n' > "$export_root/unowned"
        ;;
    esac
    printf '%s\n' "$export_root" > "$home/config/record-export-root"
    rc=0
    run_export "$home" sync > "$scope/stdout" 2> "$scope/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "sync accepted a non-dedicated $case_name export root"
    if [ "$case_name" = nonempty ]; then
      assert_grep 'unowned sentinel' "$export_root/unowned" \
        "sync changed an unknown artifact in an unowned root"
    fi
  done

  scope="$TMP_ROOT/root-boundary-other-home"
  home="$scope/home-one"
  other="$scope/home-two"
  export_root="$scope/export"
  mkdir -p "$home/config" "$home/data" "$home/state" \
    "$other/config" "$other/data" "$other/state"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf '%s\n' "$export_root" > "$other/config/record-export-root"
  printf 'home one\n' > "$home/data/projects.md"
  printf 'home two\n' > "$other/data/projects.md"
  run_export "$home" sync > "$scope/first.out" 2> "$scope/first.err" \
    || fail "first home could not initialize its dedicated export root: $(cat "$scope/first.err")"
  rc=0
  run_export "$other" sync > "$scope/second.out" 2> "$scope/second.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "sync accepted an export root owned by another home"
  assert_grep 'home one' "$export_root/live/data/projects.md" \
    "second home changed the first home's live snapshot"
  pass "record export requires a dedicated root disjoint from and owned by exactly one home"
}

test_sync_does_not_mutate_an_unowned_root_before_rejecting_it() {
  local home export_root rc=0
  home=$(make_home root-unowned-mode)
  export_root="$TMP_ROOT/export-root-unowned-mode"
  mkdir -p "$export_root"
  chmod 0777 "$export_root"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf 'projects\n' > "$home/data/projects.md"

  run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "sync accepted an unowned export root"
  [ "$(mode_of "$export_root")" = 777 ] \
    || fail "sync changed the mode of an unowned export root before rejecting it"
  pass "record export rejects an unowned root without changing its mode"
}

test_live_publication_staging_cannot_wedge_archives_or_sync() {
  local home export_root live_target rc=0 legacy_stage internal_stage
  home=$(make_home live-staging-recovery)
  export_root="$TMP_ROOT/export-live-staging-recovery"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf 'projects\n' > "$home/data/projects.md"
  run_export "$home" sync > "$home/initial.out" 2> "$home/initial.err" \
    || fail "live staging setup sync failed: $(cat "$home/initial.err")"
  live_target=$(readlink "$export_root/live")

  mkdir -p "$home/state/task-a.inbox"
  printf 'spawn_gen=live-staging-generation\n' > "$home/state/task-a.meta"
  printf 'pending\n' > "$home/state/task-a.inbox/001.msg"
  legacy_stage="$export_root/.live-next-1234-0123456789abcdef0123456789abcdef"
  ln -s "$live_target" "$legacy_stage"
  run_export "$home" archive-task task-a > "$home/archive.out" 2> "$home/archive.err" || rc=$?
  expect_code 0 "$rc" "archive after interrupted live publication: $(cat "$home/archive.err")"
  assert_absent "$legacy_stage" "archive left a stale root publication link behind"

  internal_stage="$export_root/.live-generations/.live-next-1234-0123456789abcdef0123456789abcdef"
  ln -s "$live_target" "$internal_stage"
  run_export "$home" sync > "$home/sync.out" 2> "$home/sync.err" || rc=$?
  expect_code 0 "$rc" "sync after interrupted live publication: $(cat "$home/sync.err")"
  assert_absent "$internal_stage" "sync left a stale internal publication link behind"
  pass "interrupted live publication staging cannot wedge archive or sync"
}

test_sync_retracts_stale_records_as_one_live_snapshot() {
  local home export_root first_generation rc=0
  home=$(make_home sync-converges)
  export_root="$TMP_ROOT/export-sync-converges"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  mkdir -p "$home/state/task-a.inbox/handled"
  printf 'meta\n' > "$home/state/task-a.meta"
  printf 'status\n' > "$home/state/task-a.status"
  printf 'pending\n' > "$home/state/task-a.inbox/001.msg"
  run_export "$home" sync > "$home/first.out" 2> "$home/first.err" \
    || fail "first convergent sync failed: $(cat "$home/first.err")"
  first_generation=$(readlink "$export_root/live")

  mv "$home/state/task-a.inbox/001.msg" "$home/state/task-a.inbox/handled/001.msg"
  rm "$home/state/task-a.meta" "$home/state/task-a.status"
  run_export "$home" sync > "$home/second.out" 2> "$home/second.err" || rc=$?
  expect_code 0 "$rc" "second convergent sync: $(cat "$home/second.err")"
  assert_absent "$export_root/live/state/task-a.meta" "sync retained retired metadata"
  assert_absent "$export_root/live/state/task-a.status" "sync retained retired status"
  assert_absent "$export_root/live/state/task-a.inbox/001.msg" "sync retained a moved pending message"
  assert_grep 'pending' "$export_root/live/state/task-a.inbox/handled/001.msg" \
    "sync omitted the handled destination of a moved message"
  assert_present "$export_root/$first_generation" \
    "sync removed the prior immutable generation before a consumer could finish it"
  pass "record export sync publishes the exact current allowlist as one live snapshot"
}

test_sync_refuses_unknown_managed_artifacts_before_publication() {
  local home export_root rc=0
  home=$(make_home sync-unknown-managed)
  export_root="$TMP_ROOT/export-sync-unknown-managed"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf 'old snapshot\n' > "$home/data/projects.md"
  run_export "$home" sync > "$home/initial.out" 2> "$home/initial.err" \
    || fail "unknown-artifact setup sync failed: $(cat "$home/initial.err")"
  printf 'intruder\n' > "$export_root/.live-generations/unknown"
  printf 'new snapshot\n' > "$home/data/projects.md"
  run_export "$home" sync > "$home/stdout" 2> "$home/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "sync accepted an unknown artifact in its managed generation tree"
  assert_grep 'old snapshot' "$export_root/live/data/projects.md" \
    "sync published a new snapshot before refusing an unknown managed artifact"
  assert_grep 'intruder' "$export_root/.live-generations/unknown" \
    "sync changed an unknown managed artifact"
  pass "record export refuses unknown managed artifacts before publishing a snapshot"
}

test_sync_detects_destination_parent_replacement() {
  local home export_root outside pid rc=0 wait_count=0 stage='' live_target prior_snapshot
  home=$(make_home sync-destination-race)
  export_root="$TMP_ROOT/export-sync-destination-race"
  outside="$TMP_ROOT/outside-sync-destination-race"
  mkdir -p "$outside"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf 'initial\n' > "$home/data/projects.md"
  run_export "$home" sync > "$home/initial.out" 2> "$home/initial.err" \
    || fail "destination-race setup sync failed: $(cat "$home/initial.err")"
  live_target=$(readlink "$export_root/live" 2>/dev/null || true)
  dd if=/dev/zero of="$home/data/projects.md" bs=1048576 count=64 status=none

  run_export "$home" sync > "$home/race.out" 2> "$home/race.err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    stage=$(find "$export_root/live/data" -maxdepth 1 -name '.record-export.*' -print -quit 2>/dev/null || true)
    [ -n "$stage" ] || stage=$(find "$export_root/.live-generations" -maxdepth 1 -name '.stage-*' -print -quit 2>/dev/null || true)
    [ -z "$stage" ] || break
    wait_count=$((wait_count + 1))
    [ "$wait_count" -le 500 ] || break
    sleep 0.01
  done
  [ -n "$stage" ] || { wait "$pid" || true; fail "destination-race fixture never observed a staged snapshot"; }
  kill -STOP "$pid"
  case "$stage" in
    "$export_root/live/data"/*)
      mv "$export_root/live/data" "$export_root/live/data.saved"
      ln -s "$outside" "$export_root/live/data"
      prior_snapshot="$export_root/live/data.saved/projects.md"
      ;;
    "$export_root/.live-generations"/*)
      mv "$export_root/.live-generations" "$export_root/.live-generations.saved"
      ln -s "$outside" "$export_root/.live-generations"
      prior_snapshot="$export_root/.live-generations.saved/${live_target#.live-generations/}/data/projects.md"
      ;;
    *) kill -CONT "$pid"; wait "$pid" || true; fail "destination-race fixture observed an unknown staging path" ;;
  esac
  kill -CONT "$pid"
  wait "$pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "sync committed after its destination parent was replaced"
  assert_absent "$outside/projects.md" "sync wrote through a replacement destination symlink"
  assert_grep 'initial' "$prior_snapshot" \
    "failed destination-race sync changed the prior published snapshot"
  pass "record export sync binds destination validation to descriptor-safe publication"
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

test_archive_retry_accepts_sources_already_retired_after_commit() {
  local home export_root manifest before rc=0
  home=$(make_home archive-retired-retry)
  export_root="$TMP_ROOT/export-archive-retired-retry"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" retired-retry-generation
  run_export "$home" archive-task task-a > "$home/first.out" 2> "$home/first.err" || rc=$?
  expect_code 0 "$rc" "initial archive before partial teardown"
  manifest="$export_root/archive/task-a/retired-retry-generation/manifest.v1.json"
  before=$(shasum -a 256 "$manifest" | awk '{print $1}')
  rm -f "$home/state/task-a.status"
  rm -rf "$home/state/task-a.inbox"
  rc=0
  run_export "$home" archive-task task-a > "$home/retry.out" 2> "$home/retry.err" || rc=$?
  expect_code 0 "$rc" "archive retry after status and inbox retirement: $(cat "$home/retry.err")"
  [ "$before" = "$(shasum -a 256 "$manifest" | awk '{print $1}')" ] \
    || fail "partial-teardown retry rewrote the committed manifest"
  pass "teardown archive retry accepts sources already retired after a committed capture"
}

test_archive_refuses_a_corrupt_committed_manifest() {
  local home export_root manifest rc case_name
  for case_name in wrong-task trailing-garbage duplicate-key wrong-type extra-root extra-entry; do
    home=$(make_home "archive-corrupt-manifest-$case_name")
    export_root="$TMP_ROOT/export-archive-corrupt-manifest-$case_name"
    printf '%s\n' "$export_root" > "$home/config/record-export-root"
    write_archive_fixture "$home" committed-generation
    rc=0
    run_export "$home" archive-task task-a > "$home/first.out" 2> "$home/first.err" || rc=$?
    expect_code 0 "$rc" "initial archive for $case_name manifest case"
    manifest="$export_root/archive/task-a/committed-generation/manifest.v1.json"
    case "$case_name" in
      wrong-task) sed 's/"task": "task-a"/"task": "another-task"/' "$manifest" > "$home/manifest.tmp" ;;
      trailing-garbage) cp "$manifest" "$home/manifest.tmp"; printf 'not-json\n' >> "$home/manifest.tmp" ;;
      duplicate-key) sed '/"captured_at":/a\  "captured_at": "2000-01-01T00:00:00Z",' "$manifest" > "$home/manifest.tmp" ;;
      wrong-type) sed 's/"captured_at": "[^"]*"/"captured_at": 1/' "$manifest" > "$home/manifest.tmp" ;;
      extra-root) sed '/"complete": true/a\  "unexpected": true,' "$manifest" > "$home/manifest.tmp" ;;
      extra-entry) sed '0,/"sha256": "[^"]*"/s//& , "unexpected": true/' "$manifest" > "$home/manifest.tmp" ;;
    esac
    mv "$home/manifest.tmp" "$manifest"
    rc=0
    run_export "$home" archive-task task-a > "$home/retry.out" 2> "$home/retry.err" || rc=$?
    [ "$rc" -ne 0 ] || fail "archive retry accepted a $case_name committed manifest"
    assert_present "$home/state/task-a.meta" "$case_name manifest retry removed live metadata"
  done
  pass "teardown archive rejects a corrupt committed manifest"
}

test_archive_detects_a_source_change_during_capture() {
  local home export_root archive outside archive_pid worker_pid rc=0 wait_count=0 stage=
  home=$(make_home archive-source-race)
  export_root="$TMP_ROOT/export-archive-source-race"
  outside="$TMP_ROOT/outside-archive-source-race"
  archive="$export_root/archive/task-a/racing-generation"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" racing-generation
  mkdir -p "$outside"
  printf 'outside sentinel\n' > "$outside/sentinel"
  dd if=/dev/zero of="$home/state/task-a.status" bs=1048576 count=64 status=none
  run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" &
  archive_pid=$!
  while kill -0 "$archive_pid" 2>/dev/null; do
    stage=$(find "$export_root/archive/task-a" -maxdepth 1 -name '.archive-stage-*' -print -quit 2>/dev/null || true)
    [ -z "$stage" ] || break
    wait_count=$((wait_count + 1))
    [ "$wait_count" -le 500 ] || break
    sleep 0.01
  done
  [ -n "$stage" ] || { wait "$archive_pid" || true; fail "archive source-race fixture never observed staging"; }
  worker_pid=$(ps -eo pid=,args= | awk -v pattern="$ROOT/bin/fm-record-export.py archive-task task-a" \
    'index($0, pattern) { print $1; exit }')
  [ -n "$worker_pid" ] || { wait "$archive_pid" || true; fail "archive source-race fixture could not identify the filesystem worker"; }
  kill -STOP "$worker_pid"
  rm "$home/state/task-a.status"
  ln -s "$outside/sentinel" "$home/state/task-a.status"
  kill -CONT "$worker_pid"
  wait "$archive_pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "archive committed while a source changed during capture"
  assert_absent "$archive/manifest.v1.json" "source race committed a manifest"
  assert_present "$home/state/task-a.meta" "source race removed live metadata"
  assert_grep 'outside sentinel' "$outside/sentinel" "source race changed the replacement target"
  pass "teardown archive refuses to commit when a source changes during capture"
}

test_archive_repairs_only_an_uncommitted_same_generation() {
  local home export_root archive rc=0
  home=$(make_home archive-partial)
  export_root="$TMP_ROOT/export-archive-partial"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" partial-generation
  run_export "$home" sync > "$home/sync.out" 2> "$home/sync.err" \
    || fail "partial generation setup could not initialize its root: $(cat "$home/sync.err")"
  archive="$export_root/archive/task-a/partial-generation"
  mkdir -p "$archive"
  printf 'stale partial bytes\n' > "$archive/meta"
  run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "partial generation retry: $(cat "$home/stderr")"
  cmp -s "$home/state/task-a.meta" "$archive/meta" || fail "retry did not repair the uncommitted same generation"
  assert_present "$archive/manifest.v1.json" "retry did not commit the repaired generation"
  pass "teardown archive safely repairs an uncommitted same-generation attempt"
}

test_archive_retry_removes_stale_files_from_a_partial_generation() {
  local home export_root archive rc=0
  home=$(make_home archive-partial-stale)
  export_root="$TMP_ROOT/export-archive-partial-stale"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  run_export "$home" sync > "$home/sync.out" 2> "$home/sync.err" \
    || fail "partial retry setup could not initialize its root: $(cat "$home/sync.err")"
  write_archive_fixture "$home" partial-stale-generation
  mv "$home/state/task-a.inbox/001.msg" "$home/state/task-a.inbox/handled/001.msg"
  archive="$export_root/archive/task-a/partial-stale-generation"
  mkdir -p "$archive/inbox"
  printf 'stale pending bytes\n' > "$archive/inbox/001.msg"
  run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" || rc=$?
  expect_code 0 "$rc" "partial stale generation retry: $(cat "$home/stderr")"
  assert_absent "$archive/inbox/001.msg" "partial retry committed an unmanifested stale pending message"
  assert_grep 'pending captain text' "$archive/inbox/handled/001.msg" \
    "partial retry omitted the message's current handled path"
  jq -e '[.files[].archive] | index("inbox/001.msg") == null and index("inbox/handled/001.msg") != null' \
    "$archive/manifest.v1.json" >/dev/null || fail "partial retry manifest did not match the repaired generation"
  pass "teardown archive retry publishes a fresh generation without stale partial files"
}

test_archive_revalidates_sources_immediately_before_publication() {
  local home export_root archive archive_pid rc=0 wait_count=0 index
  home=$(make_home archive-final-revalidate)
  export_root="$TMP_ROOT/export-archive-final-revalidate"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" final-revalidate-generation
  run_export "$home" sync > "$home/sync.out" 2> "$home/sync.err" \
    || fail "final revalidation setup could not initialize its root: $(cat "$home/sync.err")"
  archive="$export_root/archive/task-a/final-revalidate-generation"
  mkdir -p "$archive/inbox"
  index=0
  while [ "$index" -lt 10000 ]; do
    printf 'stale %s\n' "$index" > "$archive/inbox/$(printf '%05d' "$index").msg"
    index=$((index + 1))
  done

  run_export "$home" archive-task task-a > "$home/archive.out" 2> "$home/archive.err" &
  archive_pid=$!
  while [ -e "$archive/inbox/00000.msg" ]; do
    kill -0 "$archive_pid" 2>/dev/null || break
    wait_count=$((wait_count + 1))
    [ "$wait_count" -le 1000 ] || break
    sleep 0.01
  done
  [ ! -e "$archive/inbox/00000.msg" ] \
    || { wait "$archive_pid" || true; fail "archive did not begin replacing its stale partial generation"; }
  printf 'changed after final comparison\n' >> "$home/state/task-a.status"
  wait "$archive_pid" || rc=$?
  [ "$rc" -ne 0 ] || fail "archive committed after a source changed during stale-generation replacement"
  assert_absent "$archive/manifest.v1.json" "archive committed a manifest after its final source comparison"
  assert_present "$home/state/task-a.meta" "final comparison race removed live metadata"
  pass "teardown archive revalidates sources immediately before publication"
}

test_archive_waits_for_the_task_lock_before_enumerating_sources() {
  local home export_root archive lock holder_pid archive_pid rc=0 wait_count=0
  home=$(make_home archive-source-lock)
  export_root="$TMP_ROOT/export-archive-source-lock"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  write_archive_fixture "$home" locked-generation
  lock="$home/state/.meta-task-a.lock"
  FM_HOME="$home" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    touch "$3"
    while [ ! -e "$4" ]; do sleep 0.02; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$home/lock-held" "$home/lock-release" &
  holder_pid=$!
  while [ ! -e "$home/lock-held" ]; do
    kill -0 "$holder_pid" 2>/dev/null || fail "archive lock fixture exited before acquiring the task lock"
    wait_count=$((wait_count + 1))
    [ "$wait_count" -le 250 ] || fail "archive lock fixture never acquired the task lock"
    sleep 0.02
  done

  run_export "$home" archive-task task-a > "$home/archive.out" 2> "$home/archive.err" &
  archive_pid=$!
  sleep 0.2
  kill -0 "$archive_pid" 2>/dev/null || fail "archive bypassed the task metadata lock"
  printf 'late locked message\n' > "$home/state/task-a.inbox/003.msg"
  touch "$home/lock-release"
  wait "$holder_pid" || fail "archive lock fixture could not release the task lock"
  wait "$archive_pid" || rc=$?
  expect_code 0 "$rc" "archive after task-lock release: $(cat "$home/archive.err")"
  archive="$export_root/archive/task-a/locked-generation"
  assert_grep 'late locked message' "$archive/inbox/003.msg" \
    "archive enumerated its source set before acquiring the task lock"
  jq -e 'any(.files[]; .archive == "inbox/003.msg")' "$archive/manifest.v1.json" >/dev/null \
    || fail "archive manifest omitted a source published before the task lock was released"
  pass "teardown archive holds the task producer lock through source enumeration and commit"
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
      destination-link|unknown-partial)
        run_export "$home" sync > "$home/setup.out" 2> "$home/setup.err" \
          || fail "unsafe $case_name setup could not initialize its root: $(cat "$home/setup.err")"
        ;;
    esac
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
  run_export "$home" sync > "$home/sync.out" 2> "$home/sync.err" \
    || fail "retention setup could not initialize its root: $(cat "$home/sync.err")"
  printf 'spawn_gen=old-generation\n' > "$home/state/old-task.meta"
  run_export "$home" archive-task old-task > "$home/old.out" 2> "$home/old.err" \
    || fail "retention setup could not create a valid old generation: $(cat "$home/old.err")"
  touch -t 200001010000 "$archive_root/old-task/old-generation/manifest.v1.json"
  write_archive_fixture "$home" current-generation
  mkdir -p "$archive_root/current-task/current-generation" \
    "$archive_root/incomplete-task/incomplete-generation" \
    "$archive_root/invalid-task/invalid-generation" \
    "$archive_root/unknown-task/unknown-generation" \
    "$archive_root/unreadable-task"
  printf '{}\n' > "$archive_root/current-task/current-generation/manifest.v1.json"
  printf 'partial\n' > "$archive_root/incomplete-task/incomplete-generation/meta"
  printf '{}\n' > "$archive_root/invalid-task/invalid-generation/manifest.v1.json"
  printf '{}\n' > "$archive_root/unknown-task/unknown-generation/manifest.v1.json"
  printf 'unknown\n' > "$archive_root/unknown-task/unknown-generation/extra"
  touch -t 200001010000 "$archive_root/incomplete-task/incomplete-generation/meta" \
    "$archive_root/invalid-task/invalid-generation/manifest.v1.json" \
    "$archive_root/unknown-task/unknown-generation/manifest.v1.json"
  chmod 000 "$archive_root/unreadable-task"
  run_export "$home" archive-task task-a > "$home/stdout" 2> "$home/stderr" || rc=$?
  chmod 0750 "$archive_root/unreadable-task"
  expect_code 0 "$rc" "archive retention"
  assert_absent "$archive_root/old-task/old-generation" "retention kept an expired committed generation"
  assert_present "$archive_root/current-task/current-generation" "retention removed a current generation"
  assert_present "$archive_root/incomplete-task/incomplete-generation" "retention removed an incomplete generation"
  assert_present "$archive_root/invalid-task/invalid-generation" "retention removed an invalid old manifest"
  assert_present "$archive_root/unknown-task/unknown-generation" "retention removed a generation with unknown artifacts"
  assert_grep 'warning: refusing to prune unsafe record export archive' "$home/stderr" \
    "unsafe retention candidate did not warn"
  assert_grep 'warning: could not scan record export archive' "$home/stderr" \
    "unreadable retention subtree did not warn"
  pass "record export retention mirrors 30 completed days and prunes only owned committed generations"
}

test_export_root_stays_cold_to_firstmate_readers() {
  local home export_root output rc=0
  home=$(make_home cold-readers)
  export_root="$home/export-must-remain-absent"
  printf '%s\n' "$export_root" > "$home/config/record-export-root"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
  : > "$home/data/projects.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash "$ROOT/bin/fm-wake-drain.sh" \
    > "$home/drain.out" 2> "$home/drain.err" || rc=$?
  expect_code 0 "$rc" "wake presentation with record export configured"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash -c '
      . "$1/bin/fm-watch.sh"
      scan_signals
      status_presentation_snapshot "$STATE"
    ' _ "$ROOT" > "$home/watch.out" 2> "$home/watch.err" \
    || fail "watch classification or snapshot failed with record export configured"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" bash "$ROOT/bin/fm-fleet-snapshot.sh" --json \
    > "$home/snapshot.out" 2> "$home/snapshot.err" \
    || fail "fleet snapshot failed with record export configured"
  assert_absent "$export_root" "a presentation, wake, classification, or snapshot reader materialized the export root"
  output=$(cat "$home/drain.out" "$home/drain.err" "$home/watch.out" "$home/watch.err" \
    "$home/snapshot.out" "$home/snapshot.err")
  assert_not_contains "$output" "$export_root" "a Firstmate reader exposed the configured export root"
  pass "presentation, wake, classification, and snapshot readers leave the export root cold"
}

test_sync_is_off_when_config_is_absent
test_sync_copies_only_the_v1_allowlist
test_sync_replaces_files_atomically
test_sync_accepts_an_absolute_export_root_with_spaces
test_sync_refuses_malformed_config_and_unsafe_paths
test_sync_requires_a_dedicated_disjoint_single_home_root
test_sync_does_not_mutate_an_unowned_root_before_rejecting_it
test_live_publication_staging_cannot_wedge_archives_or_sync
test_sync_retracts_stale_records_as_one_live_snapshot
test_sync_refuses_unknown_managed_artifacts_before_publication
test_sync_detects_destination_parent_replacement
test_archive_commits_manifest_last_with_integrity_metadata
test_archive_is_off_before_any_state_read_when_config_is_absent
test_archive_retry_is_idempotent_and_generations_never_overwrite
test_archive_retry_accepts_sources_already_retired_after_commit
test_archive_refuses_a_corrupt_committed_manifest
test_archive_detects_a_source_change_during_capture
test_archive_repairs_only_an_uncommitted_same_generation
test_archive_retry_removes_stale_files_from_a_partial_generation
test_archive_revalidates_sources_immediately_before_publication
test_archive_waits_for_the_task_lock_before_enumerating_sources
test_archive_allows_missing_optional_records
test_archive_refuses_unsafe_sources_and_destinations
test_archive_retention_prunes_only_old_committed_generations
test_export_root_stays_cold_to_firstmate_readers

echo "ALL TESTS PASSED"
