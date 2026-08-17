#!/usr/bin/env bash
# Behavior tests for skills/bws/scripts/bws-safe.sh using synthetic bws fixtures.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/skills/bws/scripts/bws-safe.sh"
TMP_ROOT=$(fm_test_tmproot bws-safe-tests)

make_fake_bws() {
  local dir=$1 mode=${2:-authenticated}
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/bws" <<'SH'
#!/usr/bin/env bash
MODE="${FM_FAKE_BWS_MODE:-authenticated}"
case "${1:-}" in
  --version)
    if [ "$MODE" = broken_version ]; then
      exit 1
    fi
    printf 'bws 9.9.9\n'
    exit 0
    ;;
  project)
  case "${2:-}" in
    list)
      case "$MODE" in
        authenticated|read_only) exit 0 ;;
        no_token) printf "Error:\n   0: Missing access token\n" >&2; exit 1 ;;
        invalid_token) printf "Error:\n   0: Doesn't contain a decryption key\n" >&2; exit 1 ;;
        unauthorized) printf "Error:\n   0: 401 Unauthorized\n" >&2; exit 1 ;;
        forbidden) printf "Error:\n   0: 403 Forbidden\n" >&2; exit 1 ;;
        not_found) printf "Error:\n   0: 404 Not Found\n" >&2; exit 1 ;;
        local_permission) printf "Error: Permission denied reading config\n" >&2; exit 1 ;;
        absent) exit 127 ;;
        *) printf "Error: unknown mode %s\n" "$MODE" >&2; exit 1 ;;
      esac
      ;;
  esac
  ;;
  secret)
  case "${2:-}" in
    list)
      case "$MODE" in
        duplicate)
          printf '%s\n' '[{"id":"id-a","key":"dup","value":"one","projectId":"proj-1"},{"id":"id-b","key":"dup","value":"two","projectId":"proj-1"}]'
          ;;
        malformed)
          printf '%s\n' '{invalid json'
          ;;
        authenticated|read_only)
          printf '%s\n' '[{"id":"only-id","key":"ONLY","value":"secret-value","note":"sensitive-note","projectId":"proj-1"}]'
          ;;
        write_fail)
          printf '%s\n' '[]'
          ;;
        *)
          printf '%s\n' '[]'
          ;;
      esac
      exit 0
      ;;
    create)
      if [ "$MODE" = read_only ]; then
        printf "Error:\n   0: 403 Forbidden\n" >&2
        exit 1
      fi
      exit 0
      ;;
  esac
  ;;
esac
printf 'unhandled bws fake: %s\n' "$*" >&2
exit 1
SH
  chmod +x "$fakebin/bws"
  printf '%s\n' "$fakebin"
}

run_with_fake() {
  local mode=$1
  shift
  local fakebin case_dir isolated_home
  case_dir="$TMP_ROOT/$mode-${RANDOM}"
  isolated_home="$case_dir/home"
  mkdir -p "$isolated_home"
  fakebin=$(make_fake_bws "$case_dir" "$mode")
  env -u BWS_ACCESS_TOKEN -u BWS_PROFILE -u BWS_CONFIG_FILE \
    HOME="$isolated_home" FM_FAKE_BWS_MODE="$mode" PATH="$fakebin:$PATH" "$@"
}

test_probe_absent() {
  local out fakebin isolated_home
  fakebin="$TMP_ROOT/absent-only/bin"
  isolated_home="$TMP_ROOT/absent-only/home"
  mkdir -p "$fakebin" "$isolated_home"
  out=$(env -u BWS_ACCESS_TOKEN -u BWS_PROFILE -u BWS_CONFIG_FILE \
    HOME="$isolated_home" PATH="$fakebin:/usr/bin:/bin" "$HELPER" probe)
  assert_contains "$out" 'status=unavailable' 'absent bws should report unavailable'
  assert_contains "$out" 'version=none' 'absent bws should report version none'
  pass 'probe classifies absent bws'
}

test_probe_broken_version() {
  local out
  out=$(run_with_fake broken_version env BWS_ACCESS_TOKEN=set "$HELPER" probe)
  assert_contains "$out" 'status=unavailable' 'failed version command should report unavailable'
  assert_contains "$out" 'version=none' 'failed version command should report version none'
  pass 'probe classifies broken bws installation'
}

test_probe_no_token() {
  local out
  out=$(run_with_fake no_token env -u BWS_ACCESS_TOKEN "$HELPER" probe)
  assert_contains "$out" 'status=no_token' 'missing token should report no_token'
  assert_contains "$out" 'token_present=no' 'missing token should report token_present=no'
  pass 'probe classifies missing BWS_ACCESS_TOKEN'
}

test_probe_invalid_token() {
  local out
  out=$(run_with_fake invalid_token env BWS_ACCESS_TOKEN=bad "$HELPER" probe)
  assert_contains "$out" 'status=invalid_token' 'bad token should report invalid_token'
  pass 'probe classifies invalid token'
}

test_probe_unauthorized_token() {
  local out
  out=$(run_with_fake unauthorized env BWS_ACCESS_TOKEN=bad "$HELPER" probe)
  assert_contains "$out" 'status=invalid_token' '401 response should report invalid_token'
  pass 'probe classifies rejected token'
}

test_probe_authenticated_read_only() {
  local out
  out=$(run_with_fake read_only env BWS_ACCESS_TOKEN=readonly "$HELPER" probe)
  assert_contains "$out" 'status=authenticated' 'read-only token should still list projects'
  pass 'probe treats read-only list success as authenticated'
}

test_probe_not_found() {
  local out
  out=$(run_with_fake not_found env BWS_ACCESS_TOKEN=set "$HELPER" probe)
  assert_contains "$out" 'status=indeterminate' '404 response should report indeterminate'
  pass 'probe leaves ambiguous not-found response indeterminate'
}

test_probe_local_permission_failure() {
  local out
  out=$(run_with_fake local_permission env BWS_ACCESS_TOKEN=set "$HELPER" probe)
  assert_contains "$out" 'status=indeterminate' 'local permission failure should report indeterminate'
  pass 'probe leaves local permission failures indeterminate'
}

test_redact_metadata() {
  local out
  out=$(printf '%s\n' '{"id":"x","key":"k","value":"secret","note":"credential note"}' | "$HELPER" redact-json)
  assert_contains "$out" '[REDACTED]' 'redact-json should replace value'
  assert_not_contains "$out" 'secret' 'redact-json must not leak original value'
  assert_not_contains "$out" 'credential note' 'redact-json must not leak notes'
  pass 'redact-json redacts secret values and notes'
}

test_list_metadata_redacts() {
  local out
  out=$(run_with_fake authenticated env BWS_ACCESS_TOKEN=ok "$HELPER" list-metadata proj-1)
  assert_contains "$out" '[REDACTED]' 'list-metadata should redact values'
  assert_contains "$out" '"key": "ONLY"' 'list-metadata should keep metadata'
  assert_not_contains "$out" 'secret-value' 'list-metadata must not leak values'
  assert_not_contains "$out" 'sensitive-note' 'list-metadata must not leak notes'
  pass 'list-metadata returns redacted secret metadata'
}

test_resolve_duplicate_names() {
  local rc=0
  set +e
  run_with_fake duplicate env BWS_ACCESS_TOKEN=ok "$HELPER" resolve-id proj-1 dup >/dev/null 2>"$TMP_ROOT/dup.err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "duplicate key should exit 2, got $rc"
  assert_contains "$(<"$TMP_ROOT/dup.err")" 'duplicate secret key' 'duplicate should explain ambiguity'
  pass 'resolve-id refuses duplicate secret names'
}

test_resolve_malformed_json() {
  local rc=0
  set +e
  run_with_fake malformed env BWS_ACCESS_TOKEN=ok "$HELPER" resolve-id proj-1 ONLY >/dev/null 2>"$TMP_ROOT/malformed.err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "malformed JSON should exit 3, got $rc"
  assert_not_contains "$(<"$TMP_ROOT/malformed.err")" 'duplicate secret key' 'malformed JSON must not report duplicates'
  pass 'resolve-id rejects malformed CLI JSON'
}

test_probe_absent
test_probe_broken_version
test_probe_no_token
test_probe_invalid_token
test_probe_unauthorized_token
test_probe_authenticated_read_only
test_probe_not_found
test_probe_local_permission_failure
test_redact_metadata
test_list_metadata_redacts
test_resolve_duplicate_names
test_resolve_malformed_json
