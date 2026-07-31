#!/usr/bin/env bash
# tests/fm-spawn-psmux-worktree-banner.test.sh - unit test for the psmux worktree
# banner parser in bin/fm-spawn.sh (spawn_psmux_worktree_from_banner).
#
# psmux's pane_current_path cannot see the cwd of the interactive subshell
# `treehouse get` opens, so fm-spawn detects the worktree by parsing treehouse's
# "Entered worktree at <path>" banner. That parser is load-bearing (the only way
# psmux learns the worktree) and depends on treehouse's exact banner wording, so
# this test pins its behavior across the three path display forms treehouse can
# emit - with no real psmux or treehouse (fm_backend_capture and sleep stubbed).
#
# It runs the REAL parser code, extracted from fm-spawn.sh (which self-executes on
# source), and asserts its OUTPUT - not its source text.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

HELPER=$(sed -n '/^spawn_psmux_worktree_from_banner()/,/^}/p' "$ROOT/bin/fm-spawn.sh")
[ -n "$HELPER" ] || fail "could not extract spawn_psmux_worktree_from_banner from fm-spawn.sh"
eval "$HELPER"

# Stubs: return the canned banner immediately, and make the poll instant.
BANNER=""
fm_backend_capture() { printf '%s\n' "$BANNER"; }
sleep() { :; }

HOME=/home/tester

check() {  # <label> <banner> <expected>
  BANNER=$2
  local got
  got=$(spawn_psmux_worktree_from_banner "x")
  if [ "$got" = "$3" ]; then
    pass "$1"
  else
    fail "$1: expected '$3', got '$got'"
  fi
}

check "tilde + backslashes (the real Windows form)" \
  "🌳 Entered worktree at ~\\.treehouse\\proj-123\\1\\proj. Type 'exit' to return." \
  "/home/tester/.treehouse/proj-123/1/proj"

check "tilde + forward slashes" \
  "🌳 Entered worktree at ~/.treehouse/proj-123/1/proj. Type 'exit' to return." \
  "/home/tester/.treehouse/proj-123/1/proj"

# Drive-letter form: cygpath converts it on Windows; elsewhere it stays
# slash-normalized (still an absolute, cd-able path that downstream validation
# resolves).
if command -v cygpath >/dev/null 2>&1; then
  check "drive letter (cygpath -u)" \
    "🌳 Entered worktree at C:\\work\\.treehouse\\proj\\1\\proj. Type 'exit' to return." \
    "$(cygpath -u 'C:/work/.treehouse/proj/1/proj')"
else
  check "drive letter (no cygpath: slash-normalized)" \
    "🌳 Entered worktree at C:\\work\\.treehouse\\proj\\1\\proj. Type 'exit' to return." \
    "C:/work/.treehouse/proj/1/proj"
fi

# No banner in the captured pane -> nonzero (fail-fast). sleep is stubbed so the
# 60-iteration poll is instant.
BANNER="just some pane output with no worktree banner here"
if spawn_psmux_worktree_from_banner "x" >/dev/null 2>&1; then
  fail "input without a banner should return nonzero"
fi
pass "no banner -> nonzero"

echo "# psmux banner parser: all checks passed"
