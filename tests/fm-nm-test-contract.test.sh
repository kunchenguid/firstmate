#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
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

test_nm_has_no_deterministic_test_command

test_nm_has_herdr_test_instructions() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local missing
  missing=$(ruby -ryaml -e '
required = [
  "bin/fm-herdr-lab.sh",
  "fm-lab-*",
  "prepare",
  "provision",
  "run",
  "teardown",
  "default Herdr session",
  "fleet panes",
  "primary checkout",
  "real fleet FM_HOME state",
  "production credentials",
  "docs/herdr-backend.md",
  "--herdr-lab"
]
doc = YAML.load_file(ARGV[0]) || {}
test = doc["test"] || {}
instructions = test.is_a?(Hash) ? test["instructions"] : nil
abort "test.instructions must be a non-empty string" unless instructions.is_a?(String) && !instructions.empty?
puts required.reject { |needle| instructions.include?(needle) }
' "$NM") || fail "failed to parse test.instructions from .no-mistakes.yaml"
  if [ -n "$missing" ]; then
    fail "test.instructions is missing required safeguards: $missing"
  fi
  pass "no-mistakes test instructions authorize only isolated Herdr labs"
}

test_nm_has_herdr_test_instructions
