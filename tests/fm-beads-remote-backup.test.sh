#!/usr/bin/env bash
# tests/fm-beads-remote-backup.test.sh - behavior tests for the off-box task
# store backup check (bin/fm-beads-remote-backup.sh).
# Drives the executable with fixture task/curl binaries on PATH, so no live
# store, network, or mini is ever touched, and asserts the script's own
# safety contract: it never force-pushes, never inits, never removes a
# remote, and never drops a database.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-beads-remote-backup-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fixture")

LOCAL_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
REMOTE_HASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REMOTE_URL="http://100.102.238.78:3310/tasks"

# --- fixture task stub --------------------------------------------------
# Dispatches on $TASK_FIXTURE_MODE and records every argv line for the
# forbidden-operation scan at the end.
cat > "$FAKEBIN/task" <<'SH'
#!/usr/bin/env bash
FIXDIR="${TASK_FIXTURE_DIR:?}"
printf '%s\n' "$*" >> "$FIXDIR/argv.log"
printf '%s\n' "$*" >> "$FIXDIR/argv.all.log"
mode=$(cat "$FIXDIR/mode")
if [ "$1" = "sql" ]; then
  q=$2
  case "$q" in
    "select 1")
      [ "$mode" = "store-down" ] && { echo "connection refused" >&2; exit 1; }
      echo "1"; exit 0 ;;
    "call dolt_push"*)
      [ "$mode" = "push-fail" ] && { echo "push failed: transport down" >&2; exit 1; }
      echo "status ok"; exit 0 ;;
    "call dolt_fetch"*)
      [ "$mode" = "fetch-fail" ] && { echo "fetch failed" >&2; exit 1; }
      exit 0 ;;
    # The real store keeps the REMOTE-tracking branch in `dolt_remote_branches`
    # and answers zero rows for it out of `dolt_branches`, so this fixture
    # reproduces that exactly: a regression back to the wrong catalog must fail
    # here rather than pass on a catch-all that hides which table was read.
    *dolt_remote_branches*)
      if [ "$mode" = "head-unreadable" ]; then printf '(0 rows)\n'; exit 0; fi
      if [ "$mode" = "diverged" ]; then echo "$REMOTE_FIXTURE_HASH"; else echo "$LOCAL_FIXTURE_HASH"; fi
      exit 0 ;;
    *"remotes/"*)
      printf '(0 rows)\n'; exit 0 ;;
    *"where name='main'"*)
      echo "$LOCAL_FIXTURE_HASH"; exit 0 ;;
  esac
  echo "unexpected sql: $q" >&2; exit 1
fi
if [ "$1" = "dolt" ] && [ "$2" = "remote" ] && [ "$3" = "list" ]; then
  case "$mode" in
    list-fail) echo "boom" >&2; exit 1 ;;
    no-remote) printf '' ;;
    url-mismatch) printf 'mini1                http://other-host:3310/tasks\n' ;;
    *) printf 'mini1                %s\nmini2                http://100.111.197.110:3310/tasks\n' "$REMOTE_FIXTURE_URL" ;;
  esac
  exit 0
fi
if [ "$1" = "dolt" ] && [ "$2" = "remote" ] && [ "$3" = "add" ]; then
  echo "added"; exit 0
fi
if [ "$1" = "dolt" ] && [ "$2" = "commit" ]; then
  if [ "$mode" = "commit-fail" ]; then
    echo "error: cannot commit: schema skew detected" >&2
    exit 1
  fi
  echo "Committed."; exit 0
fi
echo "unexpected task argv: $*" >&2; exit 1
SH
chmod +x "$FAKEBIN/task"

# --- fixture curl stub --------------------------------------------------
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s' "${CURL_FIXTURE_CODE:-401}"
exit 0
SH
chmod +x "$FAKEBIN/curl"

export TASK_FIXTURE_DIR="$TMP_ROOT/fixture/state"
mkdir -p "$TASK_FIXTURE_DIR"
export LOCAL_FIXTURE_HASH=$LOCAL_HASH REMOTE_FIXTURE_HASH=$LOCAL_HASH REMOTE_FIXTURE_URL=$REMOTE_URL
: > "$TASK_FIXTURE_DIR/argv.all.log"

set_fixture() {
  printf '%s' "$1" > "$TASK_FIXTURE_DIR/mode"
  : > "$TASK_FIXTURE_DIR/argv.log"
  export CURL_FIXTURE_CODE="${2:-401}"
}

SUBJECT="$ROOT/bin/fm-beads-remote-backup.sh"
run_subject() { PATH="$FAKEBIN:$BASE_PATH" "$SUBJECT" "$@"; }

# --- verify: healthy ------------------------------------------------------
set_fixture ok
OUT=$(run_subject --verify 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "verify on a healthy backup must exit 0: $OUT"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: ok:" || fail "verify must print an ok line: $OUT"
pass "verify exits 0 with an ok line when the remote is configured and reachable"

# --- verify: no remote ------------------------------------------------------
set_fixture no-remote
OUT=$(run_subject --verify 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "verify with no remote must exit non-zero"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: no-remote:" || fail "verify must name the no-remote posture: $OUT"
pass "verify reports no-remote and exits 1 when the remote entry is absent"

# --- verify: url mismatch is reported, never overwritten --------------------
set_fixture url-mismatch
OUT=$(run_subject --verify 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "verify on a mismatched URL must exit non-zero"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: remote-url-mismatch:" || fail "verify must name the mismatch: $OUT"
grep -Fq "remote add" "$TASK_FIXTURE_DIR/argv.log" && fail "verify must never attempt to overwrite a mismatched remote"
pass "verify reports a URL mismatch and leaves the entry alone"

# --- verify: store down -------------------------------------------------------
set_fixture store-down
OUT=$(run_subject --verify 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "verify with an unreachable store must exit non-zero"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: unreachable:" || fail "verify must name the unreachable store: $OUT"
pass "verify reports an unreachable store before touching the backup"

# --- verify: remote unreachable -------------------------------------------------
set_fixture ok 000
OUT=$(run_subject --verify 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "verify with an unreachable remote must exit non-zero"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: unreachable-remote:" || fail "verify must name the unreachable remote: $OUT"
pass "verify reports an unreachable remote as best-effort, not as healthy"

# --- repair: missing remote is re-added, pushed, and head-verified --------------
set_fixture no-remote
OUT=$(run_subject --repair 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "repair of a missing remote must exit 0: $OUT"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: repaired-verified:" || fail "repair must end verified: $OUT"
grep -Fq "dolt remote add mini1 $REMOTE_URL" "$TASK_FIXTURE_DIR/argv.log" \
  || fail "repair must re-add the canonical remote entry"
grep -Fq "call dolt_push" "$TASK_FIXTURE_DIR/argv.log" \
  || fail "repair must push after re-adding the remote"
pass "repair re-adds a missing remote, pushes, and verifies one shared head"

# --- repair: the approved remote is named explicitly on the push ---------------
# Naming it is the whole point: a bare `task dolt push` resolves to Dolt's
# implicit default remote, which this store has never had, and even an explicit
# client-side push cannot authenticate because the client holds no mesh
# credential. The push must therefore go through the server-side `dolt_push`
# with the approved name and the mesh user.
set_fixture ok
OUT=$(run_subject --repair 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "repair with the remote already correct must exit 0: $OUT"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: pushed-verified: 'mini1' now shares local main" \
  || fail "a converged remote must report pushed-verified, not a repair: $OUT"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: repaired:" \
  && fail "a converged remote was reported as repaired: $OUT"
grep -Fq "sql call dolt_push('mini1','main','--user','brainsync')" "$TASK_FIXTURE_DIR/argv.log" \
  || fail "the push must name the approved remote and the mesh user explicitly"
grep -Fxq "dolt push" "$TASK_FIXTURE_DIR/argv.log" \
  && fail "a client-side bare 'task dolt push' was issued at the default remote"
grep -Fxq "dolt pull" "$TASK_FIXTURE_DIR/argv.log" \
  && fail "a client-side 'task dolt pull' was issued at the default remote"
grep -Fq "call dolt_fetch('mini1','main','--user','brainsync')" "$TASK_FIXTURE_DIR/argv.log" \
  || fail "head equality must be verified by a post-push fetch of the approved remote"
grep -Fq "dolt remote add" "$TASK_FIXTURE_DIR/argv.log" \
  && fail "a converged remote entry must not be rewritten"
pass "repair names the approved remote explicitly and never pushes a default remote"

# --- repair: a stranded working set is reported and still exits non-zero --------
# `task dolt commit` exits 0 whether it committed or found a clean working set, so
# a non-zero commit means this home's writes are still stranded. The push and the
# verification still run - durability for already-committed work is worth
# keeping - but the exit status must not call the run healthy.
set_fixture commit-fail
OUT=$(run_subject --repair 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "a failed commit must exit non-zero even when the push verified: $OUT"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: commit-failed:" || fail "repair must report the failed commit: $OUT"
printf '%s\n' "$OUT" | grep -Fq "schema skew detected" \
  || fail "the commit failure must carry the CLI's own reason: $OUT"
grep -Fq "call dolt_push" "$TASK_FIXTURE_DIR/argv.log" \
  || fail "a failed commit abandoned the push instead of degrading best-effort"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: pushed-verified:" \
  || fail "the push that did run must still be verified: $OUT"
pass "repair reports a failed commit, keeps pushing, and still exits non-zero"

# --- repair: divergence is reported, never forced ---------------------------------
export REMOTE_FIXTURE_HASH=$REMOTE_HASH
set_fixture diverged
OUT=$(run_subject --repair 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "repair on diverged heads must exit non-zero"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: diverged:" || fail "repair must name the divergence: $OUT"
export REMOTE_FIXTURE_HASH=$LOCAL_HASH
pass "repair reports divergence for an operator instead of reconciling it"

# --- repair: push failure ----------------------------------------------------------
set_fixture push-fail
OUT=$(run_subject --repair 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "repair with a failing push must exit non-zero"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: push-failed:" || fail "repair must name the push failure: $OUT"
pass "repair reports a failed push without proceeding to verification"

# --- missing task binary --------------------------------------------------------------
OUT=$(FM_BEADS_BACKUP_TASK_BIN=/nonexistent/task PATH="$FAKEBIN:$BASE_PATH" "$SUBJECT" --verify 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "verify without a task CLI must exit non-zero"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: missing:" || fail "verify must name the missing CLI: $OUT"
pass "verify fails closed naming the missing task CLI"

# --- help ------------------------------------------------------------------------------
OUT=$(run_subject --help 2>&1); RC=$?
[ "$RC" -eq 0 ] || fail "--help must exit 0"
pass "--help exits 0"

# --- repair: an unreadable head is unverified, never a fabricated divergence ---------
# "The remote disagrees" and "I could not read the remote head" are opposite
# facts. Reporting the second as the first sends an operator hunting a
# difference that may not exist - and because the honest answer to a real
# divergence is never a force-push, that mistake is expensive to make.
set_fixture head-unreadable
OUT=$(run_subject --repair 2>&1); RC=$?
[ "$RC" -ne 0 ] || fail "an unreadable head must exit non-zero: $OUT"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: unverified:" || fail "repair must report an unreadable head: $OUT"
printf '%s\n' "$OUT" | grep -Fq "BEADS_BACKUP: diverged:" \
  && fail "an unreadable head was reported as a divergence: $OUT"
pass "repair reports an unreadable head as unverified instead of inventing a divergence"

# --- safety contract: forbidden operations never appear -------------------------------
for token in --force "bd init" "remote remove" "drop database" "remote add origin"; do
  grep -Fq -- "$token" "$TASK_FIXTURE_DIR/argv.all.log" \
    && fail "forbidden operation reached the task CLI: $token"
done
pass "no force-push, init, remote removal, database drop, or default-remote creation in any scenario"

echo "# fm-beads-remote-backup.test.sh: all assertions passed"
