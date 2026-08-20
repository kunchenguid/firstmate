#!/usr/bin/env bash
# tests/fm-harness-detect.test.sh - detect_own precedence: concrete process
# ancestry outranks inheritable environment markers, and markers remain the
# fallback when no harness ancestry is visible.
#
# The break these cases catch (observed live, 2026-08-20): a codex primary
# launched from a cursor-agent context inherits CURSOR_AGENT and
# CURSOR_INVOKED_AS, fm-harness.sh answered "cursor", and session start
# emitted the cursor supervision protocol to a session that has no cursor
# stop hook - so the watcher never re-armed and the fleet sat unsupervised
# with a task in flight. Markers are inheritable and can lie about which
# harness is actually running; the innermost harness-named ancestor cannot.
#
# Each case drives the real fm-harness.sh under a REAL renamed process (the
# same technique as tests/fm-muse-harness.test.sh), so the verdicts come from
# live ps ancestry, never from string inspection of the script.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-detect)

# probe_under <ancestor-executable> [VAR=VAL ...]: run fm-harness.sh as a child
# of a real process running <ancestor-executable>. Every verified harness
# marker is cleared first so each case controls exactly the markers it names;
# later VAR=VAL assignments win over the clearing (env applies -u first).
# The harness runs inside a command substitution, never as the -c script's
# only command: bash exec-optimizes a lone command, which would REPLACE the
# named ancestor and make the ancestry under test disappear.
probe_under() {
  local anc=$1
  shift
  env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE -u PI_CODING_AGENT \
    -u FM_PI_HARNESS -u GROK_AGENT FM_HARNESS_ANCESTRY_BOUNDARY=$$ "$@" \
    "$anc" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\""
}

# make_named_ancestor <name>: a real executable with a harness name, so the
# probe's parent chain contains a genuinely running process by that name.
make_named_ancestor() {
  local name=$1 dir="$TMP_ROOT/anc"
  mkdir -p "$dir"
  [ -x "$dir/$name" ] || cp "$(command -v bash)" "$dir/$name"
  printf '%s' "$dir/$name"
}

# --- 1. Ancestry outranks inherited foreign markers --------------------------

test_codex_ancestry_outranks_inherited_cursor_markers() {
  local codex out
  codex=$(make_named_ancestor codex)
  out=$(probe_under "$codex" CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent)
  [ "$out" = codex ] \
    || fail "a codex ancestor with inherited CURSOR markers must detect codex, got '$out'"
  pass "codex ancestry outranks inherited CURSOR_AGENT/CURSOR_INVOKED_AS"
}

test_codex_ancestry_outranks_inherited_claudecode() {
  local codex out
  codex=$(make_named_ancestor codex)
  out=$(probe_under "$codex" CLAUDECODE=1)
  [ "$out" = codex ] \
    || fail "a codex ancestor with inherited CLAUDECODE must detect codex, got '$out'"
  pass "codex ancestry outranks an inherited CLAUDECODE"
}

test_cursor_ancestry_detects_cursor_even_with_inherited_claudecode() {
  # A real cursor install-tree shape: the versioned executable identifies by
  # both its name and its install path (tests/fm-cursor-harness.test.sh pins
  # the identity logic itself; this pins that detect_own reaches it through
  # ancestry when the marker layer would have said claude).
  local ver="$TMP_ROOT/share/cursor-agent/versions/2026.08.11-e8db854" out
  mkdir -p "$ver"
  cp "$(command -v bash)" "$ver/cursor-agent"
  out=$(probe_under "$ver/cursor-agent" CLAUDECODE=1)
  [ "$out" = cursor ] \
    || fail "real cursor ancestry with inherited CLAUDECODE must detect cursor, got '$out'"
  pass "cursor ancestry detects cursor even when only a foreign CLAUDECODE marker is present"
}

test_non_harness_basename_falls_back_to_markers() {
  local name out
  for name in codex-helper my-claude-wrapper; do
    out=$(probe_under "$(make_named_ancestor "$name")" CLAUDECODE=1)
    [ "$out" = claude ] \
      || fail "non-harness basename '$name' must fall back to CLAUDECODE, got '$out'"
  done
  pass "non-harness command basenames do not establish ancestry identity"
}

test_interpreter_arguments_do_not_establish_ancestry() {
  local out module_dir node_dir
  if command -v python3 >/dev/null 2>&1; then
    module_dir="$TMP_ROOT/python-module"
    mkdir -p "$module_dir"
    printf '%s\n' \
      'import os, subprocess' \
      'print(subprocess.check_output([os.environ["HARNESS"]], env=os.environ, text=True), end="")' \
      > "$module_dir/codex.py"
    out=$(cd "$module_dir" && env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
      -u FM_PI_HARNESS -u GROK_AGENT CLAUDECODE=1 \
      FM_HARNESS_ANCESTRY_BOUNDARY=$$ HARNESS="$HARNESS" python3 -m codex)
    [ "$out" = claude ] \
      || fail "python -m codex must fall back to CLAUDECODE, got '$out'"
  else
    echo "skip: python3 not found for interpreter module ancestry test"
  fi
  if command -v node >/dev/null 2>&1; then
    node_dir="$TMP_ROOT/node-script"
    mkdir -p "$node_dir"
    printf '%s\n' \
      'const cp = require("child_process");' \
      'process.stdout.write(cp.execFileSync(process.env.HARNESS, {env: process.env, encoding: "utf8"}));' \
      > "$node_dir/codex"
    out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u PI_CODING_AGENT \
      -u FM_PI_HARNESS -u GROK_AGENT CLAUDECODE=1 \
      FM_HARNESS_ANCESTRY_BOUNDARY=$$ HARNESS="$HARNESS" node "$node_dir/codex")
    [ "$out" = claude ] \
      || fail "node script arguments must fall back to CLAUDECODE, got '$out'"
  else
    echo "skip: node not found for interpreter script ancestry test"
  fi
  pass "interpreter arguments do not establish ancestry identity"
}

# --- 2. Markers remain the fallback when no harness ancestry is visible ------

test_markers_remain_fallback_without_harness_ancestry() {
  # FM_HARNESS_ANCESTRY_BOUNDARY stops the walk at this test shell, so the
  # harness actually running this suite can never leak into the verdict and
  # these cases behave identically on CI and inside any agent session.
  local out
  out=$(env -u CURSOR_INVOKED_AS -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    CURSOR_AGENT=1 FM_HARNESS_ANCESTRY_BOUNDARY=$$ "$HARNESS")
  [ "$out" = cursor ] \
    || fail "with no harness ancestry the CURSOR_AGENT marker must still win, got '$out'"
  # Cursor-before-CLAUDECODE ordering inside the fallback: both markers present
  # is the verified cursor-worker-under-claude-primary shape.
  out=$(env -u CURSOR_INVOKED_AS -u PI_CODING_AGENT -u GROK_AGENT \
    CURSOR_AGENT=1 CLAUDECODE=1 FM_HARNESS_ANCESTRY_BOUNDARY=$$ "$HARNESS")
  [ "$out" = cursor ] \
    || fail "cursor marker must outrank inherited CLAUDECODE in the fallback, got '$out'"
  # Control proving the boundary itself works: no ancestry, no markers, no verdict.
  out=$(env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u CLAUDECODE -u PI_CODING_AGENT \
    -u FM_PI_HARNESS -u GROK_AGENT FM_HARNESS_ANCESTRY_BOUNDARY=$$ "$HARNESS")
  [ "$out" = unknown ] \
    || fail "no ancestry and no markers must detect unknown (boundary leak?), got '$out'"
  pass "markers stay authoritative as the fallback when ancestry shows no harness"
}

# --- 3. Same-family marker refinement survives ancestry-first ----------------

test_pi_signed_refinement_survives_ancestry_detection() {
  # Ancestry alone can only say "pi" (the walk maps a pi-signed ancestor to
  # pi); the FM_PI_HARNESS marker refines it. An ancestry-first detector that
  # drops the refinement would regress every pi-signed session to plain pi.
  local pi out
  pi=$(make_named_ancestor pi)
  out=$(probe_under "$pi" PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed)
  [ "$out" = pi-signed ] \
    || fail "pi ancestry with pi-signed markers must detect pi-signed, got '$out'"
  out=$(probe_under "$pi" PI_CODING_AGENT=true)
  [ "$out" = pi ] \
    || fail "pi ancestry without the pi-signed refinement must detect pi, got '$out'"
  pass "pi-signed marker refinement survives ancestry-first detection"
}

test_codex_ancestry_outranks_inherited_cursor_markers
test_codex_ancestry_outranks_inherited_claudecode
test_cursor_ancestry_detects_cursor_even_with_inherited_claudecode
test_non_harness_basename_falls_back_to_markers
test_interpreter_arguments_do_not_establish_ancestry
test_markers_remain_fallback_without_harness_ancestry
test_pi_signed_refinement_survives_ancestry_detection
