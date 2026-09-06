#!/usr/bin/env bash
# Contract: .no-mistakes.yaml must never configure commands.test.
#
# no-mistakes runs commands.test verbatim and unconditionally after every fix
# round, so any deterministic walk pinned there (a full tests/*.test.sh sweep,
# a --family/--changed selection, or a fixed script list) multiplies by round
# count. PR #3644 pinned `fm-test-run.sh --changed` and measured 32.7 minutes
# per validation versus 3.6 minutes intent-targeted. Regression origin:
# tests/fm-nm-test-contract.test.sh (PR #823) first pinned this, but its
# fallback path grepped .no-mistakes.yaml's own comment text, which PR #1282
# then removed along with every other source-text assertion in the suite. This
# restores the guard using only a real YAML parse of the file's semantic
# content - .no-mistakes.yaml is firstmate's own owned config contract, so
# reading it through a typed model rather than grepping its bytes stays inside
# the suite's no-source-assertion rule.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_yaml_tracked() {
  assert_present "$NM" "tracked .no-mistakes.yaml is missing"
  git -C "$ROOT" ls-files --error-unmatch .no-mistakes.yaml >/dev/null 2>&1 \
    || fail ".no-mistakes.yaml is not tracked by git"
  pass ".no-mistakes.yaml is present and tracked"
}

test_nm_keeps_lint_pin() {
  grep -Fqx "  lint: 'bin/fm-lint.sh'" "$NM" \
    || fail "commands.lint must remain exactly bin/fm-lint.sh"
  pass "commands.lint stays pinned to bin/fm-lint.sh"
}

test_nm_has_no_deterministic_test_command() {
  # Ruby's bundled yaml (Psych) needs no install step, matching the parser
  # tests/fm-test-run.test.sh already uses to read ci.yml as YAML rather than
  # grepping it.
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_yaml_tracked
test_nm_keeps_lint_pin
test_nm_has_no_deterministic_test_command
