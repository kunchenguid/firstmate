#!/usr/bin/env bash
# Behavior tests for fm-gate-fork-assert.sh, the fork-push pre-flight guard.
#
# The guard reads the local no-mistakes gate DB (~/.no-mistakes/state.sqlite,
# overridable via FM_GATE_STATE_DB) and, for each gate-initialized repo whose
# upstream the current gh user cannot push to, asserts a push-writable fork_url.
# It prints one GATE_FORK: line per offending repo and exits non-zero, or stays
# silent and exits 0 when every repo is healthy or it cannot decide.
#
# gh is stubbed via a PATH shim: the current user is `zachlandes`, whose own
# forks (repos/zachlandes/*) are push-writable and everything else is not. sqlite3
# is required (the guard's data source); the suite skips if it is absent.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
SCRIPT="$ROOT/bin/fm-gate-fork-assert.sh"

command -v sqlite3 >/dev/null 2>&1 || { pass "sqlite3 absent - guard is a silent no-op, nothing to test"; exit 0; }

TMP=$(fm_test_tmproot fm-gate-fork-tests)

# A fake gh: authenticated as zachlandes; only repos/zachlandes/* are writable.
FAKEBIN=$(fm_fakebin "$TMP")
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then echo zachlandes; exit 0; fi
if [ "${1:-}" = api ]; then
  case "$2" in
    repos/zachlandes/*) echo true ;;
    repos/*)            echo false ;;
    *)                  echo false ;;
  esac
  exit 0
fi
exit 0
SH
chmod +x "$FAKEBIN/gh"

# Build a gate DB with the real repos schema and the given INSERT rows.
make_db() {
  local db=$1; shift
  sqlite3 "$db" "CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL, fork_url TEXT, default_branch TEXT NOT NULL DEFAULT 'main', created_at INTEGER NOT NULL);"
  local row
  for row in "$@"; do
    sqlite3 "$db" "INSERT INTO repos VALUES ($row);"
  done
}

run_guard() {
  local db=$1
  PATH="$FAKEBIN:$BASE_PATH" FM_GATE_STATE_DB="$db" "$SCRIPT" 2>/dev/null
}

# --- Case 1: fork_url unset + unwritable upstream -> fires -------------------
db1="$TMP/case1.sqlite"
make_db "$db1" "'a','/code/firstmate','https://github.com/kunchenguid/firstmate',NULL,'main',0"
out=$(run_guard "$db1"); rc=$?
[ "$rc" -ne 0 ] || fail "unset fork_url on unwritable upstream must exit non-zero (got $rc)"
case $out in
  *"GATE_FORK: /code/firstmate: no push access to kunchenguid/firstmate and no fork target"*) ;;
  *) fail "expected GATE_FORK no-fork line, got: $out" ;;
esac
case $out in
  *"no-mistakes init --fork-url git@github.com:zachlandes/firstmate.git"*) ;;
  *) fail "expected remediation with the derived fork url, got: $out" ;;
esac
pass "fires with a GATE_FORK remediation when fork_url is unset and upstream is unwritable"

# --- Case 2: fork_url set + writable -> quiet -------------------------------
db2="$TMP/case2.sqlite"
make_db "$db2" "'a','/code/firstmate','https://github.com/kunchenguid/firstmate','https://github.com/zachlandes/firstmate.git','main',0"
out=$(run_guard "$db2"); rc=$?
[ "$rc" -eq 0 ] || fail "writable fork_url must exit 0 (got $rc)"
[ -z "$out" ] || fail "writable fork_url must stay silent, got: $out"
pass "stays quiet when a push-writable fork_url is set"

# --- Case 3: writable upstream (no fork needed) -> quiet --------------------
db3="$TMP/case3.sqlite"
make_db "$db3" "'a','/code/mine','https://github.com/zachlandes/mine.git',NULL,'main',0"
out=$(run_guard "$db3"); rc=$?
[ "$rc" -eq 0 ] || fail "writable upstream must exit 0 (got $rc)"
[ -z "$out" ] || fail "writable upstream must stay silent, got: $out"
pass "stays quiet when the upstream itself is push-writable"

# --- Case 4: fork_url set but not writable -> fires -------------------------
db4="$TMP/case4.sqlite"
make_db "$db4" "'a','/code/lav','https://github.com/kunchenguid/lavish-axi','https://github.com/kunchenguid/lavish-axi.git','main',0"
out=$(run_guard "$db4"); rc=$?
[ "$rc" -ne 0 ] || fail "non-writable fork_url must exit non-zero (got $rc)"
case $out in
  *"fork kunchenguid/lavish-axi not push-writable"*) ;;
  *) fail "expected non-writable-fork line, got: $out" ;;
esac
pass "fires when fork_url is set but not push-writable"

# --- Case 5: non-github upstream -> unverifiable, quiet ---------------------
db5="$TMP/case5.sqlite"
make_db "$db5" "'a','/code/gl','https://gitlab.com/foo/bar.git',NULL,'main',0"
out=$(run_guard "$db5"); rc=$?
[ "$rc" -eq 0 ] || fail "non-github upstream must exit 0 (got $rc)"
[ -z "$out" ] || fail "non-github upstream must stay silent, got: $out"
pass "stays quiet for a non-github upstream it cannot verify"

# --- Case 6: missing DB / unauthenticated gh -> silent no-op ---------------
out=$(PATH="$FAKEBIN:$BASE_PATH" FM_GATE_STATE_DB="$TMP/does-not-exist.sqlite" "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] || fail "missing gate DB must exit 0 (got $rc)"
[ -z "$out" ] || fail "missing gate DB must stay silent, got: $out"

cat > "$FAKEBIN/gh-noauth" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then exit 1; fi
exit 0
SH
chmod +x "$FAKEBIN/gh-noauth"
NOAUTH=$(fm_fakebin "$TMP/noauth")
cp "$FAKEBIN/gh-noauth" "$NOAUTH/gh"
out=$(PATH="$NOAUTH:$BASE_PATH" FM_GATE_STATE_DB="$db1" "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] || fail "unauthenticated gh must exit 0 - NEEDS_GH_AUTH owns that case (got $rc)"
[ -z "$out" ] || fail "unauthenticated gh must stay silent, got: $out"
pass "is a silent no-op when the gate DB is absent or gh is unauthenticated"

# --- Case 7: transient gh api failure -> cannot decide, silent no-op --------
# A rate-limited / offline `gh api repos/<slug>` probe must NOT be read as
# push:false and flagged as needing a fork (the transient-false-positive
# regression): a failed probe is undecidable, so the guard stays silent.
FAILBIN=$(fm_fakebin "$TMP/ghfail")
cat > "$FAILBIN/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = api ] && [ "${2:-}" = user ]; then echo zachlandes; exit 0; fi
if [ "${1:-}" = api ]; then echo "gh: API rate limit exceeded" >&2; exit 1; fi
exit 0
SH
chmod +x "$FAILBIN/gh"
out=$(PATH="$FAILBIN:$BASE_PATH" FM_GATE_STATE_DB="$db1" "$SCRIPT" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] || fail "a failed gh push probe must not flag the repo (got $rc)"
[ -z "$out" ] || fail "a failed gh push probe must stay silent, got: $out"
pass "stays silent when the gh push probe fails instead of flagging a false positive"
