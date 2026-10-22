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

test_sync_is_off_when_config_is_absent
test_sync_copies_only_the_v1_allowlist
test_sync_replaces_files_atomically
test_sync_refuses_malformed_config_and_unsafe_paths

echo "ALL TESTS PASSED"
