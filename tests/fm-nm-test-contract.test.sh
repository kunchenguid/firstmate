#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# and its Test-agent instructions must forbid a temporary-HOME no-mistakes run.
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

# A real no-mistakes run under a temporary HOME or NM_HOME leaves a respawning
# launchd job in the real user domain; the Test agent must know to boot it out.
test_nm_test_instructions_forbid_temp_home_daemon() {
  local text
  text=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
test = doc["test"].is_a?(Hash) ? doc["test"] : {}
print test["instructions"].to_s
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  assert_contains "$text" 'Never run the real no-mistakes with a temporary HOME or NM_HOME' \
    "test.instructions must forbid a temporary-HOME no-mistakes run"
  # shellcheck disable=SC2016 # the instructions must carry this command unexpanded
  assert_contains "$text" 'launchctl bootout gui/$(id -u)/com.kunchenguid.no-mistakes.daemon.$(printf %s "$(cd "$NM_HOME" && pwd -P)" | shasum -a 256 | cut -c1-8)' \
    "test.instructions must name the exact launchd bootout command"
  pass "no-mistakes Test instructions forbid a temporary-HOME daemon"
}

test_nm_has_no_deterministic_test_command
test_nm_test_instructions_forbid_temp_home_daemon
