#!/usr/bin/env bash
# fm-quota-fallback.sh - read one Baby Menu quota snapshot as a best-effort
# fallback after quota-axi reports stale or auth_required for that provider.
#
# Fresh primary results produce no output and do not inspect Baby Menu.
# A missing sqlite3, database, table, row, or valid snapshot also produces no
# output with exit 0, preserving the primary quota-axi result as the only
# evidence. A snapshot whose saved timestamp is unreadable or ahead of the
# current clock is not a valid snapshot: every emitted reading carries a real
# non-negative age rather than a guessed or clamped one.
#
# Successful output is one JSON object with source=Baby Menu SQLite, snapshot
# age, and quota-only fields from the Baby Menu payload.
# Account identity and other unrelated payload fields are never printed.
# historyAvailable is always false: the three snapshot tables enforce id=1,
# while Kimi stores its current result under one key rather than keeping quota
# history.
#
# The database is opened with SQLite's read-only mode and PRAGMA query_only.
# Usage:
#   fm-quota-fallback.sh <claude|codex|grok|kimi> <stale|auth_required> [database]
set -u

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  printf 'usage: fm-quota-fallback.sh <claude|codex|grok|kimi> <stale|auth_required> [database]\n' >&2
  exit 2
fi

provider=$1
primary_status=$2
database=${3:-${HOME:-}/.baby-menu/baby-menu.db}

case "$primary_status" in
  stale|auth_required) ;;
  *) exit 0 ;;
esac

case "$provider" in
  claude)
    source_table=claude_code_quota_snapshot
    row_query="
      SELECT
        snapshot AS payload,
        saved_at
      FROM claude_code_quota_snapshot
      WHERE id = 1
      LIMIT 1"
    ;;
  codex)
    source_table=codex_quota_snapshot
    row_query="
      SELECT
        snapshot AS payload,
        saved_at
      FROM codex_quota_snapshot
      WHERE id = 1
      LIMIT 1"
    ;;
  grok)
    source_table=grok_quota_snapshot
    row_query="
      SELECT
        snapshot AS payload,
        saved_at
      FROM grok_quota_snapshot
      WHERE id = 1
      LIMIT 1"
    ;;
  kimi)
    source_table=kimi_quota_cache
    row_query="
      SELECT
        value AS payload,
        strftime('%Y-%m-%dT%H:%M:%SZ', updated_at / 1000, 'unixepoch') AS saved_at
      FROM kimi_quota_cache
      WHERE key = 'current_result'
      LIMIT 1"
    ;;
  *) exit 0 ;;
esac

command -v sqlite3 >/dev/null 2>&1 || exit 0
[ -f "$database" ] && [ -r "$database" ] || exit 0

query="
  PRAGMA query_only=ON;
  WITH fallback_row AS ($row_query),
  aged_row AS (
    SELECT
      payload,
      saved_at,
      CAST(strftime('%s', 'now') AS INTEGER) - CAST(strftime('%s', saved_at) AS INTEGER) AS age_seconds
    FROM fallback_row
  )
  SELECT json_object(
    'schemaVersion', 1,
    'provider', '$provider',
    'primaryStatus', '$primary_status',
    'source', 'baby-menu-sqlite',
    'sourceTable', '$source_table',
    'savedAt', saved_at,
    'ageSeconds', age_seconds,
    'historyAvailable', json('false'),
    'snapshot', json_object(
      'status', json_extract(payload, '$.status'),
      'plan', json_extract(payload, '$.plan'),
      'upstreamSource', json_extract(payload, '$.source'),
      'refreshedAt', json_extract(payload, '$.refreshedAt'),
      'checkedAt', json_extract(payload, '$.checkedAt'),
      'stale', json_extract(payload, '$.stale'),
      'windows', json(COALESCE(json_extract(payload, '$.windows'), '[]')),
      'credits', json(COALESCE(json_extract(payload, '$.credits'), 'null')),
      'errorCode', json_extract(payload, '$.error.code')
    )
  )
  FROM aged_row
  WHERE saved_at IS NOT NULL AND age_seconds IS NOT NULL AND age_seconds >= 0;"

sqlite3 -readonly -batch -noheader "$database" "$query" 2>/dev/null || true
