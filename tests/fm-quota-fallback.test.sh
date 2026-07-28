#!/usr/bin/env bash
# Behavior tests for the read-only Baby Menu quota fallback.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FALLBACK="$ROOT/bin/fm-quota-fallback.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-quota-fallback.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
DB="$TMP_ROOT/baby-menu.db"

make_fixture() {
  sqlite3 "$DB" <<'SQL'
CREATE TABLE claude_code_quota_snapshot (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  snapshot TEXT NOT NULL,
  saved_at TEXT NOT NULL
);
CREATE TABLE codex_quota_snapshot (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  snapshot TEXT NOT NULL,
  saved_at TEXT NOT NULL
);
CREATE TABLE grok_quota_snapshot (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  binding TEXT NOT NULL,
  snapshot TEXT NOT NULL,
  saved_at TEXT NOT NULL
);
CREATE TABLE kimi_quota_cache (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
INSERT INTO claude_code_quota_snapshot
  VALUES (1, '{"windows":[{"id":"five_hour","percentUsed":41},{"id":"seven_day","percentUsed":63}],"stale":false}', datetime('now', '-2 minutes'));
INSERT INTO codex_quota_snapshot
  VALUES (1, '{"accountEmail":"private@example.invalid","windows":[{"id":"weekly","percentUsed":72,"windowSeconds":604800}],"stale":false}', datetime('now', '-3 minutes'));
INSERT INTO grok_quota_snapshot
  VALUES (1, 'binding', '{"windows":[{"id":"credits","percentUsed":24}],"stale":false}', datetime('now', '-4 minutes'));
INSERT INTO kimi_quota_cache
  VALUES ('current_result', '{"status":"fresh","windows":[{"id":"weekly","percentUsed":18}]}', (unixepoch('now') - 300) * 1000);
SQL
}

file_signature() {
  local path=$1
  if [ "$(uname)" = Darwin ]; then
    stat -f '%z:%m' "$path"
  else
    stat -c '%s:%Y' "$path"
  fi
  shasum -a 256 "$path" | awk '{print $1}'
}

test_fresh_primary_is_unchanged() {
  local fakebin marker out status
  fakebin=$(fm_fakebin "$TMP_ROOT/fresh")
  marker="$TMP_ROOT/sqlite-invoked"
  cat > "$fakebin/sqlite3" <<SH
#!/usr/bin/env bash
touch '$marker'
exit 99
SH
  chmod +x "$fakebin/sqlite3"

  out=$(PATH="$fakebin:$PATH" "$FALLBACK" claude fresh "$DB")
  status=$?
  expect_code 0 "$status" "fresh primary"
  [ -z "$out" ] || fail "fresh primary produced fallback output: $out"
  assert_absent "$marker" "fresh primary inspected Baby Menu"
  pass "fresh primary result bypasses the fallback unchanged"
}

test_stale_and_auth_required_emit_sourced_aged_snapshots() {
  local claude codex claude_age codex_age
  claude=$("$FALLBACK" claude stale "$DB")
  codex=$("$FALLBACK" codex auth_required "$DB")

  printf '%s\n' "$claude" | jq -e '
    .provider == "claude"
    and .primaryStatus == "stale"
    and .source == "baby-menu-sqlite"
    and .sourceTable == "claude_code_quota_snapshot"
    and .historyAvailable == false
    and .snapshot.windows[0].id == "five_hour"
    and .snapshot.windows[1].id == "seven_day"
  ' >/dev/null || fail "stale Claude fallback lost source or snapshot evidence: $claude"
  printf '%s\n' "$codex" | jq -e '
    .provider == "codex"
    and .primaryStatus == "auth_required"
    and .source == "baby-menu-sqlite"
    and .sourceTable == "codex_quota_snapshot"
    and .historyAvailable == false
    and .snapshot.windows[0].id == "weekly"
    and .snapshot.windows[0].windowSeconds == 604800
    and (.snapshot | has("accountEmail") | not)
  ' >/dev/null || fail "auth-required Codex fallback remapped the Baby Menu window: $codex"

  claude_age=$(printf '%s\n' "$claude" | jq -r '.ageSeconds')
  codex_age=$(printf '%s\n' "$codex" | jq -r '.ageSeconds')
  [ "$claude_age" -ge 115 ] && [ "$claude_age" -le 180 ] \
    || fail "Claude fallback age is not derived from saved_at: $claude_age"
  [ "$codex_age" -ge 175 ] && [ "$codex_age" -le 240 ] \
    || fail "Codex fallback age is not derived from saved_at: $codex_age"
  pass "stale and auth-required primaries expose sourced, aged Baby Menu snapshots"
}

test_missing_or_unopenable_database_preserves_primary_behavior() {
  local out status locked="$TMP_ROOT/locked.db"
  out=$("$FALLBACK" claude stale "$TMP_ROOT/missing.db")
  status=$?
  expect_code 0 "$status" "missing fallback database"
  [ -z "$out" ] || fail "missing fallback database produced output: $out"

  cp "$DB" "$locked"
  chmod 000 "$locked"
  out=$("$FALLBACK" claude stale "$locked")
  status=$?
  chmod 600 "$locked"
  expect_code 0 "$status" "unopenable fallback database"
  [ -z "$out" ] || fail "unopenable fallback database produced output: $out"
  pass "missing and unopenable Baby Menu databases leave primary behavior unchanged"
}

test_database_is_never_written() {
  local before after out
  before=$(file_signature "$DB")
  chmod 444 "$DB"
  out=$("$FALLBACK" kimi stale "$DB")
  after=$(file_signature "$DB")
  [ "$before" = "$after" ] || fail "fallback changed the database bytes, size, or mtime"
  printf '%s\n' "$out" | jq -e '
    .source == "baby-menu-sqlite"
    and .sourceTable == "kimi_quota_cache"
    and .ageSeconds >= 295
    and .historyAvailable == false
    and .snapshot.windows[0].id == "weekly"
  ' >/dev/null || fail "read-only Kimi fallback did not return the fixture snapshot: $out"
  pass "fallback reads a non-writable database without modifying it"
}

make_fixture
test_fresh_primary_is_unchanged
test_stale_and_auth_required_emit_sourced_aged_snapshots
test_missing_or_unopenable_database_preserves_primary_behavior
test_database_is_never_written
