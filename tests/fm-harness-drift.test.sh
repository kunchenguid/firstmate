#!/usr/bin/env bash
# Behavior tests for fm-harness-drift.sh, the detect-only comparison between the
# harness build stamps recorded in harness-adapters/SKILL.md and the harness
# binaries installed on this machine.
#
# The three per-harness outcomes are pinned: stamp equals installed build
# (silent), stamp differs in EITHER direction (drift), and harness absent
# (drift). The version parser is exercised against the real `--version` output
# shapes of all five verified harnesses, because a shape this parser cannot read
# would silently report every build as unreadable. The detect-only property is
# pinned too: the check must never write to its own stamp source.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIFT="$ROOT/bin/fm-harness-drift.sh"
SKILL="$ROOT/.agents/skills/harness-adapters/SKILL.md"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-harness-drift-tests)

# Write a stamp source shaped like the real skill: the fenced block sits among
# ordinary prose and other fenced blocks, so the parser must key on the info
# string rather than on "the first fence".
write_stamps() {  # <file> <"harness version">...
  local file=$1
  shift
  # shellcheck disable=SC2016 # Literal Markdown fence backticks, not substitution.
  {
    printf '# harness-adapters\n\nProse before the block.\n\n'
    printf '```\nan unrelated fenced block\n```\n\n'
    printf '```fm-harness-builds\n'
    printf '%s\n' "$@"
    printf '```\n\nProse after the block.\n'
  } > "$file"
}

# A fake harness binary printing one exact `--version` line.
fake_harness() {  # <fakebin> <name> <version-output>
  local fakebin=$1 name=$2 out=$3
  cat > "$fakebin/$name" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = --version ] && { printf '%s\n' '$out'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/$name"
}

run_drift() {  # <fakebin> <stampfile>
  PATH="$1:$BASE_PATH" FM_HARNESS_DRIFT_SKILL="$2" "$DRIFT" 2>&1
}

test_matching_stamp_is_silent() {
  local dir="$TMP_ROOT/match" fakebin out rc
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fake_harness "$fakebin" claude '2.1.220 (Claude Code)'
  write_stamps "$dir/skill.md" 'claude 2.1.220'

  out=$(run_drift "$fakebin" "$dir/skill.md")
  rc=$?
  [ "$rc" -eq 0 ] || fail "a matching stamp must exit 0, got $rc"
  [ -z "$out" ] || fail "a matching stamp must print nothing, got: $out"
  pass "a stamp equal to the installed build is silent"
}

test_installed_newer_is_drift() {
  local dir="$TMP_ROOT/newer" fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fake_harness "$fakebin" codex 'codex-cli 0.145.0'
  write_stamps "$dir/skill.md" 'codex 0.144.4'

  out=$(run_drift "$fakebin" "$dir/skill.md")
  assert_contains "$out" 'HARNESS_DRIFT: codex recorded 0.144.4, installed 0.145.0' \
    "a stamp behind the installed build must report drift"
  pass "a stamp behind the installed build reports drift"
}

test_doc_ahead_of_installed_is_drift() {
  local dir="$TMP_ROOT/ahead" fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  # Today's real opencode case: the doc records a build newer than the one
  # installed. That is drift, not a match.
  fake_harness "$fakebin" opencode '1.18.3'
  write_stamps "$dir/skill.md" 'opencode 1.18.4'

  out=$(run_drift "$fakebin" "$dir/skill.md")
  assert_contains "$out" 'HARNESS_DRIFT: opencode recorded 1.18.4, installed 1.18.3' \
    "a stamp ahead of the installed build must report drift, not a match"
  pass "a stamp ahead of the installed build reports drift"
}

test_absent_harness_is_distinguished() {
  local dir="$TMP_ROOT/absent" fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  write_stamps "$dir/skill.md" 'pi 0.80.6'

  out=$(run_drift "$fakebin" "$dir/skill.md")
  assert_contains "$out" 'HARNESS_DRIFT: pi recorded 0.80.6, not installed here' \
    "an absent harness must be distinguished from a version mismatch"
  assert_not_contains "$out" 'installed 0' \
    "an absent harness must not report an installed version"
  pass "an absent harness is distinguished from a version mismatch"
}

test_unreadable_version_is_reported() {
  local dir="$TMP_ROOT/unreadable" fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fake_harness "$fakebin" grok 'no version here'
  write_stamps "$dir/skill.md" 'grok 0.2.103'

  out=$(run_drift "$fakebin" "$dir/skill.md")
  assert_contains "$out" 'HARNESS_DRIFT: grok recorded 0.2.103, installed build unreadable' \
    "an installed harness with no parseable version must be reported, not silently matched"
  pass "an installed harness with an unreadable version is reported"
}

test_version_shapes_of_every_verified_harness() {
  local dir="$TMP_ROOT/shapes" fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  # The exact `--version` first lines observed on 2026-07-25.
  fake_harness "$fakebin" claude '2.1.220 (Claude Code)'
  fake_harness "$fakebin" codex 'codex-cli 0.145.0'
  fake_harness "$fakebin" opencode '1.18.3'
  fake_harness "$fakebin" grok 'grok 0.2.112 (9bbd559437aa) [stable]'
  fake_harness "$fakebin" pi 'pi 0.80.6'
  write_stamps "$dir/skill.md" \
    'claude 2.1.220' 'codex 0.145.0' 'opencode 1.18.3' 'grok 0.2.112' 'pi 0.80.6'

  out=$(run_drift "$fakebin" "$dir/skill.md")
  [ -z "$out" ] || fail "every verified harness version shape must parse, got: $out"
  pass "the version parser reads every verified harness --version shape"
}

test_malformed_and_missing_block_are_reported() {
  local dir="$TMP_ROOT/malformed" fakebin out
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")

  printf '# no stamps here\n' > "$dir/none.md"
  out=$(run_drift "$fakebin" "$dir/none.md")
  assert_contains "$out" 'HARNESS_DRIFT: recorded build stamps unreadable' \
    "a stamp source with no block must report itself unreadable, not pass silently"

  # Blank spacing inside the block is not a malformed stamp.
  fake_harness "$fakebin" claude '2.1.220 (Claude Code)'
  write_stamps "$dir/spaced.md" 'claude 2.1.220' '' '   '
  out=$(run_drift "$fakebin" "$dir/spaced.md")
  [ -z "$out" ] || fail "blank lines inside the block must not raise a false alarm, got: $out"

  write_stamps "$dir/bad.md" 'claude'
  out=$(run_drift "$fakebin" "$dir/bad.md")
  assert_contains "$out" 'HARNESS_DRIFT: recorded build stamps unreadable' \
    "a malformed stamp line must report the source unreadable"

  out=$(run_drift "$fakebin" "$dir/missing.md")
  assert_contains "$out" 'HARNESS_DRIFT: recorded build stamps unreadable' \
    "a missing stamp source must report itself unreadable"
  pass "a missing, empty, or malformed stamp source is reported"
}

test_check_never_writes_to_its_source() {
  local dir="$TMP_ROOT/readonly" fakebin before after
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  write_stamps "$dir/skill.md" 'codex 0.144.4' 'pi 0.80.6'
  before=$(cksum < "$dir/skill.md")

  run_drift "$fakebin" "$dir/skill.md" >/dev/null
  after=$(cksum < "$dir/skill.md")
  [ "$before" = "$after" ] || fail "the drift check must never edit its stamp source"
  pass "the drift check leaves its stamp source untouched"
}

# --- contract against the real tracked skill --------------------------------

test_tracked_skill_stamps_cover_the_verified_harnesses() {
  local stamps names
  stamps=$("$DRIFT" --stamps)
  [ -n "$stamps" ] || fail "the tracked skill has no parseable recorded-build-stamps block"
  names=$(printf '%s\n' "$stamps" | awk '{print $1}' | LC_ALL=C sort | tr '\n' ' ')
  [ "$names" = "claude codex grok opencode pi " ] \
    || fail "recorded stamps must cover exactly AGENTS.md section 4's verified harnesses, got: $names"
  # Heredoc, not a pipe: fail() exits, and an exit inside a pipeline subshell
  # would let a malformed stamp pass silently.
  while IFS= read -r line; do
    case "$line" in
      *' '[0-9]*.[0-9]*) : ;;
      *) fail "malformed recorded stamp: $line" ;;
    esac
  done <<EOF
$stamps
EOF
  pass "the tracked skill records one parseable build stamp per verified harness"
}

test_bootstrap_wires_the_check_and_owns_the_label() {
  assert_grep 'fm-harness-drift.sh' "$ROOT/bin/fm-bootstrap.sh" \
    "bootstrap does not run the harness build-drift check"
  assert_grep 'HARNESS_DRIFT:' "$ROOT/bin/fm-bootstrap.sh" \
    "bootstrap's header does not own the HARNESS_DRIFT line format"
  assert_grep 'HARNESS_DRIFT' "$ROOT/.agents/skills/bootstrap-diagnostics/SKILL.md" \
    "bootstrap-diagnostics has no response entry for HARNESS_DRIFT"
  assert_grep 'HARNESS_DRIFT:' "$ROOT/AGENTS.md" \
    "AGENTS.md section 13 does not list HARNESS_DRIFT as a bootstrap-diagnostics trigger"
  pass "the drift check is wired into bootstrap with a documented response"
}

test_skill_keeps_one_owner_for_each_stamp() {
  local fences
  fences=$(grep -c '^```fm-harness-builds' "$SKILL")
  [ "$fences" -eq 1 ] \
    || fail "exactly one recorded-build-stamps block must own the stamps, found $fences"
  pass "exactly one block owns the recorded build stamps"
}

test_matching_stamp_is_silent
test_installed_newer_is_drift
test_doc_ahead_of_installed_is_drift
test_absent_harness_is_distinguished
test_unreadable_version_is_reported
test_version_shapes_of_every_verified_harness
test_malformed_and_missing_block_are_reported
test_check_never_writes_to_its_source
test_tracked_skill_stamps_cover_the_verified_harnesses
test_bootstrap_wires_the_check_and_owns_the_label
test_skill_keeps_one_owner_for_each_stamp
