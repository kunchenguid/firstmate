#!/usr/bin/env bash
# tests/fm-jev-done-verify.test.sh - verify Jev Definition of Done & Fake-Done Verifier
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY_SH="$ROOT/bin/fm-jev-done-verify.sh"
VERIFY_PY="$ROOT/bin/fm-jev-done-verify.py"

[ -x "$VERIFY_SH" ] || fail "bin/fm-jev-done-verify.sh missing or not executable"
[ -x "$VERIFY_PY" ] || fail "bin/fm-jev-done-verify.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-done-test)
export FM_HOME="$TDIR/home" FM_STATE_OVERRIDE="$TDIR/home/state"
mkdir -p "$FM_STATE_OVERRIDE"

# 1. Ephemeral residue rejection
set +e
out_ephem=$("$VERIFY_SH" --task "test-task" --status-line "done: transcription works via temporary relay on port 8000" 2>&1)
rc_ephem=$?
set -e
[ "$rc_ephem" -eq 2 ] || fail "ephemeral relay status was not rejected (got exit $rc_ephem)"
assert_contains "$out_ephem" "rejected [ephemeral_relay]" "detected ephemeral relay"

# 2. Dirty worktree rejection
WT_DIR="$TDIR/dirty-wt"
fm_git_identity fmtest fmtest@example.invalid
git init -q -b main "$WT_DIR"
git -C "$WT_DIR" commit -q --allow-empty -m "initial commit"
echo "uncommitted changes" > "$WT_DIR/dirty.txt"

set +e
out_dirty=$("$VERIFY_SH" --task "dirty-task" --worktree "$WT_DIR" --status-line "done: all tests passing" 2>&1)
rc_dirty=$?
set -e
[ "$rc_dirty" -eq 2 ] || fail "dirty worktree was not rejected (got exit $rc_dirty)"
assert_contains "$out_dirty" "rejected [dirty_worktree]" "detected dirty worktree"

# 3. Clean deliverable verification passes
git -C "$WT_DIR" add dirty.txt
git -C "$WT_DIR" commit -q -m "tracked deliverable"
python3 - "$VERIFY_PY" "$WT_DIR" <<'PYTEST'
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("verify", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
assert mod.inspect_git_deliverables(mod.Path(sys.argv[2]))[0]
PYTEST

# 4. Unpushed branch rejection (Tier 1)
git -C "$WT_DIR" checkout -q -b feature/unpushed
git -C "$WT_DIR" commit -q --allow-empty -m "unpushed work"
set +e
out_unpushed=$("$VERIFY_SH" --task "unpushed-task" --worktree "$WT_DIR" --status-line "done: work committed" 2>&1)
rc_unpushed=$?
set -e
[ "$rc_unpushed" -eq 2 ] || fail "unpushed commits were not rejected (got exit $rc_unpushed)"
assert_contains "$out_unpushed" "rejected [unpushed_commits]" "detected unpushed commits"

pass "all fm-jev-done-verify tests passed"
