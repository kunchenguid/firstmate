#!/usr/bin/env bash
# Focused portable coverage for native Windows Herdr's durable Treehouse lease.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-treehouse)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
LOG="$TMP_ROOT/calls.log"
: > "$LOG"

cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse\t%s\t%s\n' "$PWD" "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?}"
case "${1:-}" in
  get) printf '%s\n' "${FM_FAKE_TREEHOUSE_PATH:?}" ;;
  return) exit "${FM_FAKE_TREEHOUSE_RETURN_EXIT:-0}" ;;
esac
SH
chmod +x "$FAKEBIN/treehouse"

test_acquisition_mode_leases_only_on_native_windows() {
  [ "$(fm_backend_herdr_treehouse_acquisition_mode 'MSYS_NT-10.0-26100')" = lease ] \
    || fail "Git for Windows Herdr should use a durable Treehouse lease"
  [ "$(fm_backend_herdr_treehouse_acquisition_mode 'MINGW64_NT-10.0-26100')" = lease ] \
    || fail "MinGW Herdr should use a durable Treehouse lease"
  [ "$(fm_backend_herdr_treehouse_acquisition_mode 'CYGWIN_NT-10.0')" = lease ] \
    || fail "Cygwin Herdr should use a durable Treehouse lease"
  [ "$(fm_backend_herdr_treehouse_acquisition_mode Linux)" = interactive ] \
    || fail "Linux Herdr should preserve interactive treehouse get"
  [ "$(fm_backend_herdr_treehouse_acquisition_mode Darwin)" = interactive ] \
    || fail "macOS Herdr should preserve interactive treehouse get"
  pass "native Windows Herdr alone selects a durable Treehouse lease"
}

test_enter_worktree_command_quotes_literal_path() {
  local command
  command=$(fm_backend_herdr_windows_enter_worktree_command "C:\\Crew O'Brien\\task")
  [ "$command" = "Set-Location -LiteralPath 'C:\\Crew O''Brien\\task'" ] \
    || fail "Windows worktree entry command did not PowerShell-quote the literal path: $command"
  pass "the PowerShell worktree command quotes a literal native path"
}

test_acquire_lease_uses_project_and_holder() {
  local project worktree expected
  project="$TMP_ROOT/project"
  worktree="$TMP_ROOT/leased-worktree"
  mkdir -p "$project"
  output=$(FM_FAKE_TREEHOUSE_LOG="$LOG" FM_FAKE_TREEHOUSE_PATH="$worktree" PATH="$FAKEBIN:$PATH" \
    fm_backend_herdr_acquire_treehouse_lease "$project" task-109)
  [ "$output" = "$worktree" ] || fail "lease acquisition did not return Treehouse's path"
  expected=$(printf 'treehouse\t%s\tget --lease --lease-holder task-109' "$project")
  [ "$(tail -n 1 "$LOG")" = "$expected" ] \
    || fail "lease acquisition did not run in the project with the exact holder"
  pass "lease acquisition runs in the project with the exact task holder"
}

test_unpublished_lease_closes_endpoint_before_return() {
  local worktree expected
  worktree="$TMP_ROOT/unpublished-worktree"
  fm_backend_herdr_kill() {
    printf 'kill\t%s\n' "$1" >> "$LOG"
  }
  FM_FAKE_TREEHOUSE_LOG="$LOG" FM_FAKE_TREEHOUSE_PATH="$worktree" PATH="$FAKEBIN:$PATH" \
    fm_backend_herdr_return_unpublished_treehouse_lease default:w1:p2 "$worktree" \
    || fail "unpublished lease cleanup should succeed"
  expected=$(printf 'kill\tdefault:w1:p2\ntreehouse\t%s\treturn --force %s' "$PWD" "$worktree")
  [ "$(tail -n 2 "$LOG")" = "$expected" ] \
    || fail "unpublished lease cleanup did not close the endpoint before returning the lease"
  pass "an unpublished lease closes its endpoint before Treehouse return"
}

test_unpublished_lease_return_failure_is_visible() {
  local worktree
  worktree="$TMP_ROOT/failed-return-worktree"
  fm_backend_herdr_kill() {
    printf 'kill\t%s\n' "$1" >> "$LOG"
  }
  if FM_FAKE_TREEHOUSE_LOG="$LOG" FM_FAKE_TREEHOUSE_PATH="$worktree" \
    FM_FAKE_TREEHOUSE_RETURN_EXIT=9 PATH="$FAKEBIN:$PATH" \
    fm_backend_herdr_return_unpublished_treehouse_lease default:w1:p3 "$worktree"; then
    fail "unpublished lease cleanup hid Treehouse return failure"
  fi
  pass "an unpublished lease return failure remains visible to spawn recovery"
}

test_acquisition_mode_leases_only_on_native_windows
test_enter_worktree_command_quotes_literal_path
test_acquire_lease_uses_project_and_holder
test_unpublished_lease_closes_endpoint_before_return
test_unpublished_lease_return_failure_is_visible

echo "# all native Windows Herdr Treehouse tests passed"
