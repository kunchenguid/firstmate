#!/usr/bin/env bash
# tests/fm-project-mode-branches.test.sh - the --branches accessor reads the
# (home, repo)-scoped gitflow branches declared inside a registry entry's
# annotation, and reports empty production for a branch-less entry so nothing
# breaks mid-migration (gflow-01).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-mode-branches)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"

cat > "$DATA/projects.md" <<'REG'
# Projects (fixture)

- alpha [local-only production=main] - branch-less mode plus production only (added 260817)
- beta [direct-PR production=master staging=release] - both branches (added 260817)
- gamma [no-mistakes +yolo production=main staging=dev] - branches with yolo (added 260817)
- delta [direct-PR] - registered but no branch fields yet (added 260817)
- epsilon - legacy entry, no annotation at all (added 260817)
REG

pm() { FM_DATA_OVERRIDE="$DATA" "$ROOT/bin/fm-project-mode.sh" "$@" 2>/dev/null; }

# --branches reports "<production> <staging>".
assert_contains "$(pm --branches alpha)" "main" "alpha production not read"
[ "$(pm --branches alpha)" = "main " ] || fail "alpha should be production=main, empty staging"
[ "$(pm --branches beta)" = "master release" ] || fail "beta should be master/release"
[ "$(pm --branches gamma)" = "main dev" ] || fail "gamma should be main/dev"

# Branch-less registered entry parses, production reported empty.
[ "$(pm --branches delta)" = " " ] || fail "delta should report empty production/staging, got '$(pm --branches delta)'"
[ "$(pm --branches epsilon)" = " " ] || fail "legacy epsilon should report empty branches"

# Unknown project: empty branches, no crash.
[ "$(pm --branches nope)" = " " ] || fail "unknown project should report empty branches"

# Adding branch fields must not disturb the mode/yolo accessor.
[ "$(pm alpha)" = "local-only off" ] || fail "alpha mode/yolo regressed"
[ "$(pm beta)" = "direct-PR off" ] || fail "beta mode/yolo regressed"
[ "$(pm gamma)" = "no-mistakes on" ] || fail "gamma mode/yolo regressed (yolo alongside branches)"
[ "$(pm delta)" = "direct-PR off" ] || fail "delta mode/yolo regressed"
[ "$(pm epsilon)" = "no-mistakes off" ] || fail "legacy epsilon mode/yolo regressed"

pass "--branches reads production/staging per entry; empty for branch-less; mode/yolo unaffected"
echo "ALL TESTS PASSED"
