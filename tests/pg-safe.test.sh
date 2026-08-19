#!/usr/bin/env bash
# Behavior tests for skills/postgres-admin/scripts/pg-safe.sh using synthetic psql fixtures.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/skills/postgres-admin/scripts/pg-safe.sh"
TMP_ROOT=$(fm_test_tmproot pg-safe-tests)

make_fake_psql() {
  local dir=$1 mode=${2:-ok}
  local fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/psql" <<'SH'
#!/usr/bin/env bash
MODE="${FM_FAKE_PSQL_MODE:-ok}"
SQL="${FM_FAKE_PSQL_SQL:-}"
case "${1:-}" in
  -v)
    shift
    ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -c)
      SQL="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
case "$MODE" in
  absent)
    exit 127
    ;;
  error)
    printf 'psql: connection failed password=secret postgresql://user:pass@host/db\n' >&2
    exit 1
    ;;
  absent_role)
    exit 0
    ;;
  app_role)
    if [[ "$SQL" == *"pg_roles"* ]]; then
      printf '%s\n' 'app_role|f|f|f|t|f|f'
      exit 0
    fi
    if [[ "$SQL" == *"role_table_grants"* ]]; then
      printf '%s\n' 'app|users|SELECT'
      printf '%s\n' 'app|users|INSERT'
      exit 0
    fi
    ;;
  migration_role)
    if [[ "$SQL" == *"pg_roles"* ]]; then
      printf '%s\n' 'migration_role|f|f|f|t|f|f'
      exit 0
    fi
    ;;
  no_grants)
    if [[ "$SQL" == *"role_table_grants"* ]]; then
      exit 0
    fi
    ;;
esac
printf 'unhandled psql fake mode=%s sql=%s\n' "$MODE" "$SQL" >&2
exit 1
SH
  chmod +x "$fakebin/psql"
  printf '%s\n' "$fakebin"
}

run_with_fake_psql() {
  local mode=$1
  shift
  local fakebin case_dir
  case_dir="$TMP_ROOT/$mode-${RANDOM}"
  fakebin=$(make_fake_psql "$case_dir" "$mode")
  FM_FAKE_PSQL_MODE="$mode" PATH="$fakebin:$PATH" "$@"
}

test_role_attrs_present() {
  local out
  out=$(run_with_fake_psql app_role "$HELPER" role-attrs app_role)
  assert_contains "$out" 'status=ok' 'present role should report status=ok'
  assert_contains "$out" 'rolsuper=f' 'app role should not be superuser'
  assert_contains "$out" 'rolcreaterole=f' 'app role should not create roles'
  pass 'role-attrs reports role attributes without secrets'
}

test_role_attrs_absent() {
  local rc=0 out
  set +e
  out=$(run_with_fake_psql absent_role "$HELPER" role-attrs missing_role)
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "absent role should exit 1, got $rc"
  assert_contains "$out" 'status=absent' 'absent role should report status=absent'
  pass 'role-attrs reports absent roles'
}

test_role_attrs_redacts_errors() {
  local rc=0 err
  set +e
  run_with_fake_psql error "$HELPER" role-attrs app_role >/dev/null 2>"$TMP_ROOT/psql-error.err"
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "psql error should exit 3, got $rc"
  err=$(<"$TMP_ROOT/psql-error.err")
  assert_contains "$err" '[REDACTED]' 'psql errors should be redacted'
  assert_not_contains "$err" 'secret' 'psql errors must not leak passwords'
  pass 'role-attrs redacts credential-shaped psql errors'
}

test_dump_verify_plain_sql() {
  local dump out
  dump="$TMP_ROOT/backup.sql"
  printf '%s\n' '-- PostgreSQL database dump' 'SELECT 1;' >"$dump"
  out=$("$HELPER" dump-verify "$dump")
  assert_contains "$out" 'status=ok' 'valid plain dump should pass'
  assert_contains "$out" 'sha256=' 'dump verify should print checksum'
  pass 'dump-verify accepts plain SQL dumps'
}

test_dump_verify_custom_format() {
  local dump out
  dump="$TMP_ROOT/backup.dump"
  printf 'PGDMP' >"$dump"
  out=$("$HELPER" dump-verify "$dump")
  assert_contains "$out" 'status=ok' 'valid custom dump should pass'
  pass 'dump-verify accepts custom-format dumps'
}

test_dump_verify_empty() {
  local dump rc=0
  dump="$TMP_ROOT/empty.dump"
  : >"$dump"
  set +e
  "$HELPER" dump-verify "$dump" >/dev/null 2>"$TMP_ROOT/empty.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "empty dump should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/empty.err")" 'status=empty' 'empty dump should report status=empty'
  pass 'dump-verify rejects empty dumps'
}

test_dump_verify_missing() {
  local rc=0
  set +e
  "$HELPER" dump-verify "$TMP_ROOT/no-such.dump" >/dev/null 2>"$TMP_ROOT/missing.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "missing dump should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/missing.err")" 'status=missing' 'missing dump should report status=missing'
  pass 'dump-verify rejects missing dumps'
}

test_restore_guard_allows_test_db() {
  local out
  out=$("$HELPER" restore-guard restore_test restore_test)
  assert_contains "$out" 'status=allowed' 'matching target should be allowed'
  pass 'restore-guard allows declared test database'
}

test_restore_guard_refuses_live_db() {
  local rc=0 err
  set +e
  "$HELPER" restore-guard restore_test production_db >/dev/null 2>"$TMP_ROOT/restore.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "live target should exit 1, got $rc"
  assert_contains "$(<"$TMP_ROOT/restore.err")" 'status=refused' 'mismatched target should be refused'
  pass 'restore-guard refuses undeclared restore targets'
}

test_restore_guard_live_authorized() {
  local out
  out=$(PG_SAFE_LIVE_RESTORE_AUTH=yes "$HELPER" restore-guard restore_test production_db 2>&1)
  assert_contains "$out" 'status=live_authorized' 'live auth should allow explicit override'
  pass 'restore-guard honors PG_SAFE_LIVE_RESTORE_AUTH'
}

test_grant_check_lists_grants() {
  local out
  out=$(run_with_fake_psql app_role "$HELPER" grant-check app_role app)
  assert_contains "$out" 'status=ok' 'grant-check should succeed'
  assert_contains "$out" 'users|SELECT' 'grant-check should list grants'
  pass 'grant-check reports effective grants'
}

test_grant_check_none() {
  local out
  out=$(run_with_fake_psql no_grants "$HELPER" grant-check app_role app)
  assert_contains "$out" 'grants=none' 'grant-check should report no grants'
  pass 'grant-check reports empty grant sets'
}

test_role_attrs_present
test_role_attrs_absent
test_role_attrs_redacts_errors
test_dump_verify_plain_sql
test_dump_verify_custom_format
test_dump_verify_empty
test_dump_verify_missing
test_restore_guard_allows_test_db
test_restore_guard_refuses_live_db
test_restore_guard_live_authorized
test_grant_check_lists_grants
test_grant_check_none
