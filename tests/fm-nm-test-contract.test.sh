#!/usr/bin/env bash
# Contract: local no-mistakes Test is intent-targeted; CI owns broad regression.
#
# Firstmate must not configure commands.test as a complete tests/*.test.sh walk
# (that duplicated CI and burned local pipeline time). Lint stays pinned to
# bin/fm-lint.sh. Remote CI owns broad regression through separate portable and
# required real-Herdr Behavior lanes composed around bin/fm-test-run.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
CI="$ROOT/.github/workflows/ci.yml"

test_nm_yaml_tracked() {
  assert_present "$NM" "tracked .no-mistakes.yaml is missing"
  git -C "$ROOT" ls-files --error-unmatch .no-mistakes.yaml >/dev/null 2>&1 \
    || fail ".no-mistakes.yaml is not tracked by git"
  pass ".no-mistakes.yaml is present and tracked"
}

test_yaml_contracts() {
  assert_present "$CI" "ci.yml is missing"
  # shellcheck disable=SC2016
  ruby -ryaml -rshellwords -e '
    nm = YAML.safe_load(File.read(ARGV.fetch(0))) || {}
    commands = nm.fetch("commands", {})
    abort "commands must be a mapping" unless commands.is_a?(Hash)
    abort "commands.lint must remain exactly bin/fm-lint.sh" unless commands["lint"] == "bin/fm-lint.sh"
    test_command = commands["test"]
    unless test_command.nil? || test_command == false || test_command == ""
      abort "commands.test must be absent or empty so Test stays intent-targeted"
    end

    workflow = YAML.safe_load(File.read(ARGV.fetch(1))) || {}
    jobs = workflow.fetch("jobs")
    abort "jobs must be a mapping" unless jobs.is_a?(Hash)

    logical_commands = lambda do |run|
      commands = []
      pending = ""
      run.to_s.each_line do |line|
        stripped = line.strip
        next if pending.empty? && (stripped.empty? || stripped.start_with?("#"))
        pending << " " unless pending.empty?
        if stripped.end_with?("\\")
          pending << stripped.delete_suffix("\\")
          next
        end
        pending << stripped
        begin
          tokens = Shellwords.shellsplit(pending)
        rescue ArgumentError
          next
        end
        tokens.shift while tokens.first&.match?(/\A[A-Za-z_][A-Za-z0-9_]*=/)
        commands << tokens unless tokens.empty?
        pending = ""
      end
      abort "workflow run block ends with a continuation" unless pending.empty?
      commands
    end

    normalized_commands = lambda do |run|
      logical_commands.call(run).map do |tokens|
        normalized = tokens.dup
        normalized[0] = normalized.first.delete_prefix("./")
        normalized
      end
    end

    expected_sequences = {
      lint: normalized_commands.call(%q~bin/fm-lint.sh~),
      coverage: normalized_commands.call(%q~bin/fm-test-run.sh --check-coverage~),
      parallel: {
        1 => normalized_commands.call(%q~
set -eu
mkdir -p "$RUNNER_TEMP/fm-test"
bin/fm-test-run.sh --lane portable-parallel-1 \
  --json "$RUNNER_TEMP/fm-test/fm-test-timing-portable-parallel-1.json"
~),
        2 => normalized_commands.call(%q~
set -eu
mkdir -p "$RUNNER_TEMP/fm-test"
bin/fm-test-run.sh --lane portable-parallel-2 \
  --json "$RUNNER_TEMP/fm-test/fm-test-timing-portable-parallel-2.json"
~)
      },
      serial: normalized_commands.call(%q~
set -eu
mkdir -p "$RUNNER_TEMP/fm-test"
bin/fm-test-run.sh --lane "$FM_SERIAL_LANE" \
  --json "$RUNNER_TEMP/fm-test/fm-test-timing-portable-serial-${FM_SERIAL_SHARD}.json"
~),
      herdr: normalized_commands.call(%q~
set -eu
mkdir -p "$RUNNER_TEMP/fm-test"
bin/fm-test-run.sh --family real-herdr-gated \
  --fail-on-gate-skip "herdr not found" \
  --json "$RUNNER_TEMP/fm-test/fm-test-timing-herdr.json"
~),
      stock: normalized_commands.call(%q~
set -eu
case "$BASH_VERSION" in
  3.2.57*) ;;
  *) echo "::error::expected stock macOS Bash 3.2.57, got $BASH_VERSION"; exit 1 ;;
esac
/bin/bash --version | head -1
command -v jq >/dev/null || { echo "::error::jq is required"; exit 1; }

shell_inventory="$RUNNER_TEMP/fm-shell-inventory"
bin/fm-lint.sh --list-files > "$shell_inventory"
parse_fail=0
while IFS= read -r f; do
  /bin/bash -n "$f" || { echo "::error::stock macOS Bash 3.2 failed to parse $f"; parse_fail=1; }
done < "$shell_inventory"
[ "$parse_fail" -eq 0 ] || { echo "::error::stock macOS Bash 3.2 parse sweep failed"; exit 1; }

snapshot_output=$(/bin/bash tests/fm-fleet-snapshot-view.test.sh)
printf "%s\n" "$snapshot_output"
snapshot_count=$(printf "%s\n" "$snapshot_output" | grep -c "^ok - ")
[ "$snapshot_count" -eq 15 ] || {
  echo "::error::expected 15 snapshot/fleet-view tests, got $snapshot_count"
  exit 1
}

bearings_output=$(/bin/bash tests/fm-bearings-snapshot.test.sh)
printf "%s\n" "$bearings_output"
bearings_count=$(printf "%s\n" "$bearings_output" | grep -c "^ok - ")
[ "$bearings_count" -eq 42 ] || {
  echo "::error::expected 42 Bearings tests, got $bearings_count"
  exit 1
}
~),
      invariant: normalized_commands.call(%q~
set -eu
[ ! -L CLAUDE.md ] || { echo "::error::CLAUDE.md must be a real @AGENTS.md pointer file, not a symlink"; exit 1; }
tmp=$(mktemp)
trap "rm -f \"$tmp\"" EXIT
printf "%s\n" \
  "<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->" \
  "@AGENTS.md" >"$tmp"
cmp -s CLAUDE.md "$tmp" || { echo "::error::CLAUDE.md must be the canonical @AGENTS.md pointer"; exit 1; }
[ "$(readlink .claude/skills)" = "../.agents/skills" ] || { echo "::error::.claude/skills must be a symlink to ../.agents/skills"; exit 1; }
~)
    }

    step_sequences = lambda do |job|
      job.fetch("steps", []).each_with_object([]) do |step, sequences|
        run = step["run"]
        sequences << normalized_commands.call(run) if run.is_a?(String)
      end
    end

    enabled = lambda do |node|
      condition = node["if"]
      condition.nil? || condition == true
    end

    failure_propagating = lambda do |step|
      setting = step["continue-on-error"]
      setting.nil? || setting == false
    end

    default_shell = lambda do |node|
      node.dig("defaults", "run", "shell")
    end

    standard_shell = lambda do |workflow_node, job, step|
      step["shell"].nil? && default_shell.call(job).nil? && default_shell.call(workflow_node).nil?
    end

    required_lint_step = lambda do |workflow_node, job, step|
      run = step["run"]
      enabled.call(job) && enabled.call(step) && failure_propagating.call(step) &&
        standard_shell.call(workflow_node, job, step) &&
        run.is_a?(String) && normalized_commands.call(run) == expected_sequences.fetch(:lint)
    end

    lint_fixture = { "run" => "bin/fm-lint.sh" }
    no_op_defaults = { "defaults" => { "run" => { "shell" => "true {0}" } } }
    abort "enabled lint metadata fixture was rejected" unless required_lint_step.call({}, {}, lint_fixture)
    abort "disabled lint job metadata was accepted" if required_lint_step.call({}, { "if" => false }, lint_fixture)
    abort "disabled lint step metadata was accepted" if required_lint_step.call({}, {}, lint_fixture.merge("if" => false))
    if required_lint_step.call({}, {}, lint_fixture.merge("continue-on-error" => true))
      abort "non-propagating lint step metadata was accepted"
    end
    if required_lint_step.call({}, {}, lint_fixture.merge("shell" => "true {0}"))
      abort "no-op lint step shell was accepted"
    end
    abort "no-op lint job shell was accepted" if required_lint_step.call({}, no_op_defaults, lint_fixture)
    abort "no-op lint workflow shell was accepted" if required_lint_step.call(no_op_defaults, {}, lint_fixture)

    lint_job = jobs.values.find do |job|
      job.fetch("steps", []).any? { |step| required_lint_step.call(workflow, job, step) }
    end
    abort "lint job running bin/fm-lint.sh is missing" unless lint_job

    unless step_sequences.call(jobs.fetch("test-coverage")).include?(expected_sequences.fetch(:coverage))
      abort "coverage job does not directly invoke fm-test-run.sh --check-coverage"
    end

    [1, 2].each do |shard|
      expected = expected_sequences.fetch(:parallel).fetch(shard)
      unless step_sequences.call(jobs.fetch("tests-portable-parallel-#{shard}")).include?(expected)
        abort "portable parallel shard #{shard} does not directly invoke its lane"
      end
    end

    serial_job = jobs.fetch("tests-portable-serial")
    unless serial_job.dig("strategy", "matrix", "shard") == [1, 2, 3, 4]
      abort "serial shard matrix is not 1..4"
    end
    expected_lane = "portable-serial-${{ matrix.shard }}of${{ strategy.job-total }}"
    serial_step = serial_job.fetch("steps").find do |step|
      step.dig("env", "FM_SERIAL_LANE") == expected_lane &&
        step["run"].is_a?(String) &&
        normalized_commands.call(step["run"]) == expected_sequences.fetch(:serial)
    end
    abort "serial shards do not directly invoke their derived lane" unless serial_step

    unless step_sequences.call(jobs.fetch("tests-herdr")).include?(expected_sequences.fetch(:herdr))
      abort "Herdr job does not directly invoke the required real-Herdr family"
    end

    macos_job = jobs.fetch("macos-stock-bash")
    abort "stock Bash job must run on macos-latest" unless macos_job["runs-on"] == "macos-latest"
    stock_bash_step = macos_job.fetch("steps").find do |step|
      step["shell"] == "/bin/bash {0}" &&
        step["run"].is_a?(String) &&
        normalized_commands.call(step["run"]) == expected_sequences.fetch(:stock)
    end
    abort "stock Bash job lacks its /bin/bash parse-sweep step" unless stock_bash_step

    invariants_job = jobs.fetch("invariants")
    invariant_steps = invariants_job.fetch("steps")
    has_checkout = invariant_steps.any? { |step| step["uses"].to_s.start_with?("actions/checkout@") }
    has_behavior = step_sequences.call(invariants_job).include?(expected_sequences.fetch(:invariant))
    abort "invariants job lacks checkout or executable behavior" unless has_checkout && has_behavior
  ' "$NM" "$CI" || fail "no-mistakes and CI YAML contracts must remain intact"
  pass "no-mistakes stays targeted and CI owns broad behavior coverage"
}

test_nm_yaml_tracked
test_yaml_contracts
