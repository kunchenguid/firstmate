#!/usr/bin/env bash
# tests/fm-omp-harness.test.sh - regression for Oh My Pi (omp) own-harness
# detection in bin/fm-harness.sh.
#
# omp deliberately sets CLAUDECODE=1 on every bash-tool child process for
# Claude-Code bash-tool compatibility, alongside its own OMPCODE=1. Before this
# fix, fm-harness.sh tested CLAUDECODE first and silently misidentified every
# omp session or worker as claude - the exact same precedence hazard already
# fixed for Cursor. This suite pins:
#   1. OMPCODE=1 outranks a coexisting CLAUDECODE=1.
#   2. CLAUDECODE alone (no OMPCODE) still detects claude - omp is not
#      over-matched.
#   3. Process-ancestry detection (ps -o comm= reporting the bare name `omp`)
#      identifies omp even with no env markers at all, as a second layer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-omp-harness)
trap 'rm -rf "$TMP_ROOT"' EXIT

test_omp_marker_outranks_coexisting_claudecode() {
  local out
  out=$(env -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        OMPCODE=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = omp ] \
    || fail "OMPCODE=1 + CLAUDECODE=1 (omp's own bash-compat coexistence shape) must detect omp, got '$out'"
  pass "fm-harness.sh: OMPCODE outranks a coexisting CLAUDECODE"
}

test_claudecode_alone_still_detects_claude() {
  local out
  out=$(env -u OMPCODE -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
        CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone (no OMPCODE) must still detect claude, got '$out'"
  pass "fm-harness.sh: a plain claude session is unaffected by the omp precedence fix"
}

test_ancestry_detects_bare_omp_process_name() {
  local bindir out
  bindir="$TMP_ROOT/bin"
  mkdir -p "$bindir"
  # A real process literally named `omp`, shaped like the bun-launched
  # `bun /path/to/omp` process that reports comm=omp (verified live, omp
  # v18.0.4; see .agents/skills/harness-adapters/SKILL.md). It forks the
  # harness as a CHILD (not exec) so the ancestry walk climbs from the
  # harness's own pid up to this omp-named parent, with no env markers at all.
  cat > "$bindir/omp" <<EOF
#!/bin/sh
env -u OMPCODE -u CLAUDECODE -u PI_CODING_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GROK_AGENT \
  "$HARNESS" > "$TMP_ROOT/out"
EOF
  chmod +x "$bindir/omp"
  "$bindir/omp"
  out=$(cat "$TMP_ROOT/out")
  [ "$out" = omp ] \
    || fail "a real ancestor process named 'omp' with no env markers must detect omp via ancestry, got '$out'"
  pass "fm-harness.sh: process ancestry reporting the bare name 'omp' detects omp as a fallback layer"
}

test_omp_marker_outranks_coexisting_claudecode
test_claudecode_alone_still_detects_claude
test_ancestry_detects_bare_omp_process_name
