#!/usr/bin/env bash
# tests/fm-project-mode.test.sh - unit tests for bin/fm-project-mode.sh's
# optional "forge:<github|gitlab|forgejo>" registry token, added alongside the
# existing "<mode>" and "+yolo" tokens. Covers the default, both bracket
# orders, an unknown forge value, and that the plain (no --forge/--raw)
# output stays exactly two words - unchanged from before this token existed -
# because tests/fm-secondmate-safety.test.sh and
# tests/fm-secondmate-lifecycle-e2e.test.sh assert that shape with strict
# string equality.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode-tests)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"

cat > "$DATA/projects.md" <<'EOF'
## Projects
- legacy - a project registered before any bracket token existed (added 2026-01-01)
- flagged [direct-PR +yolo] - mode and yolo, no forge token (added 2026-01-01)
- lab [no-mistakes forge:forgejo] - forge token after mode (added 2026-01-01)
- lead [forge:forgejo no-mistakes +yolo] - forge token first, order must not matter (added 2026-01-01)
- glabbed [local-only forge:gitlab] - a GitLab project (added 2026-01-01)
- bogus [no-mistakes forge:not-a-forge] - an invalid forge value (added 2026-01-01)
EOF

run_mode() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" "$1" 2>/dev/null
}
run_forge() {
  FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge "$1" 2>/dev/null
}

[ "$(run_mode legacy)" = "no-mistakes off" ] || fail "legacy entry's default output changed: $(run_mode legacy)"
[ "$(run_forge legacy)" = "github" ] || fail "an entry with no forge token must default to github: $(run_forge legacy)"
pass "fm-project-mode: an entry with no bracket at all defaults to forge github and keeps its two-word default output"

[ "$(run_mode flagged)" = "direct-PR on" ] || fail "flagged entry's mode/yolo output changed: $(run_mode flagged)"
[ "$(run_forge flagged)" = "github" ] || fail "an entry with mode/yolo but no forge token must default to github: $(run_forge flagged)"
pass "fm-project-mode: mode and +yolo with no forge token still default to forge github"

[ "$(run_mode lab)" = "no-mistakes off" ] || fail "lab entry's mode output changed: $(run_mode lab)"
[ "$(run_forge lab)" = "forgejo" ] || fail "forge:forgejo after the mode token did not resolve: $(run_forge lab)"
pass "fm-project-mode: forge:forgejo placed after the mode token resolves to forgejo"

[ "$(run_mode lead)" = "no-mistakes on" ] || fail "lead entry's mode/yolo output changed: $(run_mode lead)"
[ "$(run_forge lead)" = "forgejo" ] || fail "forge:forgejo placed before the mode token did not resolve: $(run_forge lead)"
pass "fm-project-mode: a forge:forgejo token placed before the mode token resolves identically (order-independent)"

[ "$(run_mode glabbed)" = "local-only off" ] || fail "glabbed entry's mode output changed: $(run_mode glabbed)"
[ "$(run_forge glabbed)" = "gitlab" ] || fail "forge:gitlab did not resolve: $(run_forge glabbed)"
pass "fm-project-mode: forge:gitlab resolves to gitlab"

[ "$(run_forge bogus)" = "github" ] || fail "an unknown forge value must fall back to github: $(run_forge bogus)"
FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge bogus 2>&1 >/dev/null | grep -q 'unknown forge' \
  || fail "an unknown forge value must warn on stderr rather than silently substituting github"
pass "fm-project-mode: an unrecognized forge value warns and falls back to github rather than failing the gate"

[ "$(run_forge missing-project)" = "github" ] || fail "a missing project must default --forge to github: $(run_forge missing-project)"
[ "$(FM_DATA_OVERRIDE="$TMP_ROOT/no-such-dir" "$PROJECT_MODE" --forge legacy 2>/dev/null)" = "github" ] \
  || fail "an absent registry file must default --forge to github"
pass "fm-project-mode: a missing project or absent registry defaults --forge to github, matching the mode/yolo fallback"

echo "# fm-project-mode.test.sh: all assertions passed"
