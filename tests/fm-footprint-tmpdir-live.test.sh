#!/usr/bin/env bash
# Live guard for the redirected task temp directory (bin/fm-footprint-lib.sh).
#
# Spawn points TMPDIR, TMP and TEMP at a task's scratch area only for the worker
# tools named in FM_FOOTPRINT_TMPDIR_HARNESSES. Whether a vendor binary still
# starts, runs a shell command, and keeps its own temp files under a redirected
# temp directory is the vendor's behavior, so only the real binary can prove it.
# For every listed tool this launches the installed binary once with the three
# variables pointing at a fresh short directory and asks its shell tool to
# create a file under "$TMPDIR", then requires a zero exit and that file inside
# that directory; any temp entries of the tool's own found there are reported.
# The probe deliberately avoids mktemp(1), which on current macOS ignores
# TMPDIR. A listed tool that is not installed is reported absent by name, and a
# run that checked no tool fails rather than passing.
#
# It submits a prompt, so it spends tokens and is opt-in:
# FM_FOOTPRINT_TMPDIR_LIVE=1 (or FM_LIVE=1) runs it, and an absent listed tool
# then fails. The dated result per tool is recorded in
# docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_FOOTPRINT_TMPDIR_LIVE bash

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=bin/fm-footprint-lib.sh
. "$ROOT/bin/fm-footprint-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-footprint-tmpdir-live)
# shellcheck disable=SC2016 # the prompt is literal shell for the worker tool to run.
PROMPT='Run exactly this shell command with your shell tool: f="$TMPDIR/fm-live-probe.$$"; : > "$f"; echo "$f". Then reply with only the path it printed, nothing else.'

check_tool() {  # <harness>
  local tool=$1 dir work out rc version path own
  dir=$(mktemp -d /tmp/fmtl.XXXXXX) || fail "cannot create a short temp directory"
  dir=$(cd -P "$dir" && pwd -P)
  FM_TEST_CLEANUP_DIRS+=("$dir")
  mkdir -p "$dir/tmp"
  work="$TMP_ROOT/$tool-work"
  mkdir -p "$work"
  version=$("$tool" --version 2>/dev/null | head -n 1)
  case "$tool" in
    claude)
      out=$(cd "$work" && TMPDIR="$dir/tmp" TMP="$dir/tmp" TEMP="$dir/tmp" \
        fm_run_timed 240 claude -p "$PROMPT" --dangerously-skip-permissions --max-turns 4 </dev/null 2>&1)
      rc=$? ;;
    codex)
      out=$(cd "$work" && TMPDIR="$dir/tmp" TMP="$dir/tmp" TEMP="$dir/tmp" \
        fm_run_timed 240 codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT" </dev/null 2>&1)
      rc=$? ;;
    *) fail "no live launch is defined for listed tool $tool; add one before listing it" ;;
  esac
  [ "$rc" -eq 0 ] || fail "$tool $version did not finish under a redirected TMPDIR (exit $rc): $(printf '%s' "$out" | tail -5)"
  path=$(printf '%s\n' "$out" | grep -o "$dir/tmp/[^[:space:]\`'\"]*" | tail -1)
  [ -n "$path" ] && [ -f "$path" ] ||
    fail "$tool $version did not see the redirected TMPDIR in its shell tool: $(printf '%s' "$out" | tail -5)"
  own=$(find "$dir/tmp" -mindepth 1 -maxdepth 1 ! -path "$path" | sed "s#^$dir/tmp/##" | tr '\n' ' ')
  printf '# %s %s: started, its shell tool wrote %s, own temp entries: %s\n' "$tool" "$version" "$path" "${own:-none}"
}

checked=0
for tool in $FM_FOOTPRINT_TMPDIR_HARNESSES; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    [ "${FM_FOOTPRINT_TMPDIR_LIVE:-${FM_LIVE:-}}" != 1 ] || fail "listed tool $tool is not installed"
    printf '# absent: %s\n' "$tool"
    continue
  fi
  check_tool "$tool"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "no listed worker tool was installed, so nothing was checked"

test_every_listed_tool_keeps_working_under_a_redirected_tmpdir() {
  pass "every installed listed worker tool starts, runs a command, and keeps its temp under a redirected TMPDIR ($checked checked)"
}

fm_test_run test_every_listed_tool_keeps_working_under_a_redirected_tmpdir
