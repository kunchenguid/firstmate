#!/usr/bin/env bash
# pg-safe.sh - safe helper for PostgreSQL administration.
#
# Owned by skills/postgres-admin/SKILL.md.
# Never prints passwords, connection strings, or secret material.
#
# Usage:
#   pg-safe.sh role-attrs <ROLE>
#   pg-safe.sh dump-verify <DUMP_FILE>
#   pg-safe.sh restore-guard <ALLOWED_TEST_DB> <TARGET_DB>
#   pg-safe.sh grant-check <ROLE> <SCHEMA>
#
# Connection settings come from the standard PG* environment variables or a
# .pgpass file configured outside chat.
# Never pass passwords on the command line.
set -u

usage() {
  cat <<'EOF'
pg-safe.sh - safe helper for PostgreSQL administration

Usage:
  pg-safe.sh role-attrs <ROLE>
  pg-safe.sh dump-verify <DUMP_FILE>
  pg-safe.sh restore-guard <ALLOWED_TEST_DB> <TARGET_DB>
  pg-safe.sh grant-check <ROLE> <SCHEMA>

Never prints passwords, connection strings, or secret material.
EOF
}

die_usage() {
  printf 'pg-safe: %s\n' "$1" >&2
  usage >&2
  exit 2
}

require_psql() {
  command -v psql >/dev/null 2>&1 || die_usage "psql is required"
}

redact_line() {
  local line=$1
  line=${line//password=[^[:space:]]*/password=[REDACTED]}
  line=${line//postgresql:\/\/[^[:space:]]*/postgresql://[REDACTED]}
  line=${line//$'PGPASSWORD='*/PGPASSWORD=[REDACTED]}
  printf '%s\n' "$line"
}

run_psql() {
  local sql=$1
  local output
  if ! output=$(psql -v ON_ERROR_STOP=1 -At -c "$sql" 2>&1); then
    printf '%s\n' "$output" | while IFS= read -r line || [ -n "$line" ]; do
      redact_line "$line" >&2
    done
    return 1
  fi
  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi
}

cmd_role_attrs() {
  local role=$1 sql
  [ -n "$role" ] || die_usage "role-attrs requires ROLE"
  require_psql
  sql="SELECT rolname,
              rolsuper,
              rolcreatedb,
              rolcreaterole,
              rolcanlogin,
              rolreplication,
              rolbypassrls
       FROM pg_roles
       WHERE rolname = '${role//\'/\'\'}';"
  local line
  if ! line=$(run_psql "$sql"); then
    exit 3
  fi
  if [ -z "$line" ]; then
    printf 'status=absent role=%s\n' "$role"
    exit 1
  fi
  IFS='|' read -r rolname rolsuper rolcreatedb rolcreaterole rolcanlogin rolreplication rolbypassrls <<<"$line"
  printf 'status=ok role=%s rolsuper=%s rolcreatedb=%s rolcreaterole=%s rolcanlogin=%s rolreplication=%s rolbypassrls=%s\n' \
    "$rolname" "$rolsuper" "$rolcreatedb" "$rolcreaterole" "$rolcanlogin" "$rolreplication" "$rolbypassrls"
}

cmd_dump_verify() {
  local file=$1 size sha magic
  [ -n "$file" ] || die_usage "dump-verify requires DUMP_FILE"
  if [ ! -f "$file" ]; then
    printf 'status=missing file=%s\n' "$file" >&2
    exit 1
  fi
  size=$(wc -c <"$file" | tr -d '[:space:]')
  if [ "${size:-0}" -eq 0 ]; then
    printf 'status=empty file=%s\n' "$file" >&2
    exit 1
  fi
  magic=$(head -c 5 "$file" 2>/dev/null || true)
  if [ "$magic" = 'PGDMP' ]; then
  :
  elif head -n 1 "$file" | grep -q '^--'; then
  :
  else
    printf 'status=unrecognized file=%s\n' "$file" >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    sha=$(sha256sum "$file" | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sha=$(shasum -a 256 "$file" | awk '{print $1}')
  else
    die_usage "sha256sum or shasum is required for dump-verify"
  fi
  printf 'status=ok size=%s sha256=%s\n' "$size" "$sha"
}

cmd_restore_guard() {
  local allowed=$1 target=$2
  [ -n "$allowed" ] && [ -n "$target" ] || die_usage "restore-guard requires ALLOWED_TEST_DB and TARGET_DB"
  if [ "$target" = "$allowed" ]; then
    printf 'status=allowed target=%s\n' "$target"
    exit 0
  fi
  if [ "${PG_SAFE_LIVE_RESTORE_AUTH:-}" = yes ]; then
    printf 'status=live_authorized target=%s allowed=%s\n' "$target" "$allowed" >&2
    exit 0
  fi
  printf 'status=refused target=%s allowed=%s\n' "$target" "$allowed" >&2
  exit 1
}

cmd_grant_check() {
  local role=$1 schema=$2 sql line out_file err_file
  [ -n "$role" ] && [ -n "$schema" ] || die_usage "grant-check requires ROLE and SCHEMA"
  require_psql
  out_file=$(mktemp)
  err_file=$(mktemp)
  chmod 600 "$out_file" "$err_file"
  sql="SELECT table_schema,
              table_name,
              privilege_type
       FROM information_schema.role_table_grants
       WHERE grantee = '${role//\'/\'\'}'
         AND table_schema = '${schema//\'/\'\'}'
       ORDER BY table_schema, table_name, privilege_type;"
  if ! run_psql "$sql" >"$out_file" 2>"$err_file"; then
    while IFS= read -r line || [ -n "$line" ]; do
      redact_line "$line" >&2
    done <"$err_file"
    rm -f "$out_file" "$err_file"
    exit 3
  fi
  printf 'status=ok role=%s schema=%s\n' "$role" "$schema"
  if [ -s "$out_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      redact_line "$line"
    done <"$out_file"
  else
    printf 'grants=none\n'
  fi
  rm -f "$out_file" "$err_file"
}

CMD=${1:-}
shift || true

case "$CMD" in
  -h|--help|'')
    usage
    [ -n "$CMD" ] || exit 2
    exit 0
    ;;
  role-attrs)
    [ $# -eq 1 ] || die_usage "role-attrs requires exactly one ROLE"
    cmd_role_attrs "$1"
    ;;
  dump-verify)
    [ $# -eq 1 ] || die_usage "dump-verify requires exactly one DUMP_FILE"
    cmd_dump_verify "$1"
    ;;
  restore-guard)
    [ $# -eq 2 ] || die_usage "restore-guard requires ALLOWED_TEST_DB and TARGET_DB"
    cmd_restore_guard "$1" "$2"
    ;;
  grant-check)
    [ $# -eq 2 ] || die_usage "grant-check requires ROLE and SCHEMA"
    cmd_grant_check "$1" "$2"
    ;;
  *)
    die_usage "unknown command: $CMD"
    ;;
esac
