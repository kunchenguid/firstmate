#!/usr/bin/env bash
# Contract tests for this fleet's tracked instruction surface.
#
# Upstream removed its own instruction-owner assertions in favour of behavioral
# coverage. These are kept because they guard fleet adaptations whose artifact IS
# the instruction text: a vendored skill's redistribution terms and consent gate,
# and the required Bearings report artifact. Neither has an executable interface
# behind which the contract could be observed, so content is the only seam.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
README="$ROOT/README.md"
BEARINGS="$ROOT/.agents/skills/bearings/SKILL.md"
WATCH="$ROOT/.agents/skills/watch/SKILL.md"
WATCH_LICENSE="$ROOT/.agents/skills/watch/LICENSE"

# The watch skill is vendored third-party material, so its redistribution terms and
# its upstream base must survive every future edit or an upstream refresh becomes
# guesswork. It is captain-invocable, so its trigger belongs in an operating
# section rather than the agent-only reference list.
test_vendored_watch_skill_keeps_license_and_upstream_pin() {
  local count script trigger pycache
  assert_present "$WATCH" "vendored watch skill is missing"
  assert_present "$WATCH_LICENSE" "vendored watch skill lost its upstream LICENSE"
  assert_grep 'MIT License' "$WATCH_LICENSE" "vendored watch LICENSE is no longer the upstream MIT terms"
  assert_grep 'name: watch' "$WATCH" "watch skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$WATCH" "watch skill must stay captain-invocable"
  assert_grep '  internal: true' "$WATCH" "watch skill must be internal"
  assert_grep '  vendored-from: "bradautomates/claude-video@' "$WATCH" \
    "watch skill lost the upstream commit pin a refresh diffs against"
  assert_grep 'To refresh: re-copy upstream skills/watch' "$WATCH" \
    "watch skill lost the vendoring banner's refresh procedure"
  # The refresh path is a re-copy from upstream, so a truncated or partial copy is
  # a realistic failure that would otherwise surface only when /watch next runs.
  # Parsing is checked instead of content so a legitimate refresh still passes.
  pycache=$(fm_test_tmproot fm-watch-pycompile)
  for script in watch.py frames.py transcribe.py whisper.py download.py setup.py config.py; do
    assert_present "$ROOT/.agents/skills/watch/scripts/$script" \
      "vendored watch skill is missing scripts/$script"
    PYTHONPYCACHEPREFIX="$pycache" python3 -m py_compile \
      "$ROOT/.agents/skills/watch/scripts/$script" ||
      fail "vendored watch scripts/$script does not parse - the upstream re-copy is truncated or partial"
  done
  [ -x "$ROOT/.agents/skills/watch/scripts/watch.py" ] || fail "scripts/watch.py is not executable"
  assert_grep 'brew install ffmpeg yt-dlp' "$WATCH" \
    "watch banner lost the macOS unattended-install disclosure"
  assert_grep 'AUDIO EGRESS:' "$WATCH" \
    "watch banner lost the third-party transcription upload disclosure"
  assert_grep 'KEY-SOURCE TRAP, DELIBERATELY NOT PATCHED:' "$WATCH" \
    "watch banner lost the working-directory .env key-source trap note"
  assert_grep 'CLEANUP TRAP, DELIBERATELY NOT PATCHED:' "$WATCH" \
    "watch banner lost the Step 5 rm -rf working-directory warning"
  # The consent gate has to bind every installer path, not just the exit-code
  # table, or a genuine first run installs before anyone is asked.
  assert_grep 'covers EVERY path below this banner that can reach the installer' "$WATCH" \
    "watch banner's install consent gate no longer binds every installer path"
  count=$(grep -Fc -- 'Load the `watch` skill' "$AGENTS")
  [ "$count" -eq 1 ] || fail "watch must have exactly one AGENTS.md trigger line, found $count"
  trigger=$(grep -F -- 'Load the `watch` skill' "$AGENTS")
  case "$trigger" in
    *"consent before that first run"*) ;;
    *) fail "the watch trigger line lost its first-run install and audio-egress consent gate" ;;
  esac
  assert_no_grep '- `watch` -' "$AGENTS" \
    "captain-invocable watch must not be listed among the agent-only reference skills"
  pass "vendored watch skill keeps its license, upstream pin, consent gate, and single trigger"
}

# This fleet's captain reads data/status-report-<YYYY-MM-DD>.md directly, so the
# dated artifact is a required deliverable of every /bearings run rather than an
# opt-in mode. Upstream made the same skill chat-only by default; guard the
# divergence so a later upstream reconciliation cannot silently drop the file.
test_bearings_always_writes_the_dated_report() {
  assert_grep 'Every run writes the dated data/status-report-<YYYY-MM-DD>.md artifact' "$BEARINGS" \
    "bearings description no longer promises the dated report on every run"
  assert_grep 'Every `/bearings` run writes the dated markdown report artifact' "$BEARINGS" \
    "bearings skill no longer writes the dated report on every run"
  assert_grep 'required deliverable of every run and this fleet has no chat-only mode' "$BEARINGS" \
    "bearings skill no longer states that the dated report is required in this fleet"
  assert_grep "replaces today's \`data/status-report-<YYYY-MM-DD>.md\` from scratch" "$BEARINGS" \
    "bearings skill lost the replace-from-scratch rule for today's report"
  assert_no_grep 'chat-only by default' "$BEARINGS" \
    "bearings skill reverted to upstream's chat-only default"
  assert_no_grep 'Plain mode stops here and writes no report artifact' "$BEARINGS" \
    "bearings skill reintroduced a mode that skips the required report"
  assert_no_grep 'in explicit file mode' "$BEARINGS" \
    "bearings skill made the required report conditional on an explicit file mode"
  assert_grep "always replacing today's dated report" "$README" \
    "README no longer documents that /bearings always writes the dated report"
  assert_no_grep '/bearings file' "$README" \
    "README still advertises an opt-in file mode this fleet does not have"
  pass "bearings writes the dated report on every run in this fleet"
}

test_vendored_watch_skill_keeps_license_and_upstream_pin
test_bearings_always_writes_the_dated_report
