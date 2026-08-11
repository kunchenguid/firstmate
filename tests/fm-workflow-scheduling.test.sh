#!/usr/bin/env bash
# Contract tests for GitHub Actions scheduling and lifecycle selection.
#
# The workflows are executable configuration, so this test parses their public
# YAML contract rather than matching source text. It protects the cost boundary:
# complete Ubuntu coverage remains on every PR, the only current macOS job uses
# native path filtering plus a daily run, and no-mistakes records every lifecycle
# event while failing only a marker-absent body edit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
MACOS_WORKFLOW="$ROOT/.github/workflows/macos-stock-bash.yml"
NO_MISTAKES_WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

assert_workflow_contract() {
  ruby - "$CI_WORKFLOW" "$MACOS_WORKFLOW" "$NO_MISTAKES_WORKFLOW" <<'RUBY'
require "yaml"

ci_path, macos_path, no_mistakes_path = ARGV
ci = YAML.load_file(ci_path)
macos = YAML.load_file(macos_path)
no_mistakes = YAML.load_file(no_mistakes_path)
trigger = true

def require_equal(actual, expected, label)
  return if actual == expected

  raise "#{label}: expected #{expected.inspect}, got #{actual.inspect}"
end

def require_present(value, label)
  return unless value.nil? || value == false || value == ""

  raise "#{label}: missing"
end

ci_events = ci.fetch(trigger)
require_equal(ci_events.keys, ["pull_request"], "CI events")
require_equal(ci_events.fetch("pull_request").fetch("branches"), ["main"], "CI PR target")

ubuntu_jobs = %w[
  lint
  test-coverage
  tests-portable-parallel-1
  tests-portable-parallel-2
  tests-portable-serial
  tests-herdr
  tests-native-backends
  tests-timing-aggregate
  invariants
]
require_equal(ci.fetch("jobs").keys.sort, ubuntu_jobs.sort, "CI job inventory")
ci.fetch("jobs").each do |name, job|
  require_equal(job.fetch("runs-on"), "ubuntu-latest", "CI job #{name} runner")
end
native_job = ci.fetch("jobs").fetch("tests-native-backends")
require_equal(native_job.fetch("timeout-minutes"), 15, "native backend job timeout")
require_equal(native_job.fetch("steps").first.fetch("uses"), "actions/checkout@v6", "native backend checkout")
native_run_steps = native_job.fetch("steps").filter_map { |step| step["run"] }
require_present(
  native_run_steps.any? { |run| run.include?("bin/fm-install-zellij.sh") },
  "native backend Zellij provisioning"
)
require_present(
  native_run_steps.any? { |run| run.include?("--family native-backend-gated") },
  "native backend gate scheduling"
)

macos_events = macos.fetch(trigger)
require_equal(macos_events.keys.sort, %w[pull_request schedule], "macOS workflow events")
macos_pr = macos_events.fetch("pull_request")
require_equal(macos_pr.fetch("branches"), ["main"], "macOS PR target")
paths = macos_pr.fetch("paths")
macos_paths = %w[
  .github/workflows/macos-stock-bash.yml
  bin/**
  tests/**
]
require_equal(paths, macos_paths, "macOS PR paths")
require_equal(macos_events.fetch("schedule"), [{"cron" => "17 5 * * *"}], "macOS daily schedule")
macos_jobs = macos.fetch("jobs")
require_equal(macos_jobs.keys, ["macos-stock-bash"], "macOS job inventory")
macos_job = macos_jobs.fetch("macos-stock-bash")
require_equal(macos_job.fetch("runs-on"), "macos-latest", "macOS runner")
require_equal(macos_job.fetch("steps")[1].fetch("shell"), "/bin/bash {0}", "macOS stock Bash shell")

types = no_mistakes.fetch(trigger).fetch("pull_request").fetch("types")
require_equal(types, %w[opened edited synchronize reopened], "no-mistakes lifecycle events")
check = no_mistakes.fetch("jobs").fetch("check")
require_present(check.fetch("if").include?("github-actions[bot]"), "no-mistakes bot exemption")
require_present(check.fetch("if").include?("dependabot[bot]"), "no-mistakes Dependabot exemption")
require_present(
  check.fetch("steps").any? { |step| step.dig("env", "PR_BODY") == "${{ github.event.pull_request.body }}" },
  "no-mistakes signature body input"
)
require_present(
  check.fetch("steps").any? { |step| step.dig("env", "PR_ACTION") == "${{ github.event.action }}" },
  "no-mistakes lifecycle action input"
)
concurrency = no_mistakes.fetch("concurrency").fetch("group")
require_present(concurrency.include?("github.event.action == 'opened'"), "no-mistakes opening isolation")
require_present(concurrency.include?("github.event.action == 'edited'"), "no-mistakes body-edit isolation")
RUBY
}

no_mistakes_step() {
  ruby - "$NO_MISTAKES_WORKFLOW" <<'RUBY'
require "yaml"

workflow = YAML.load_file(ARGV.fetch(0))
step = workflow.fetch("jobs").fetch("check").fetch("steps").fetch(0)
print step.fetch("run")
RUBY
}

run_no_mistakes_fixture() {
  local action=$1 body=$2 expected_code=$3 expected_message=$4 expected_detail=${5:-} output code
  output=$(PR_ACTION="$action" PR_BODY="$body" PR_AUTHOR=fixture PR_NUMBER=123 /bin/bash -s <<< "$(no_mistakes_step)" 2>&1)
  code=$?
  expect_code "$expected_code" "$code" "no-mistakes $action fixture"
  assert_contains "$output" "$expected_message" "no-mistakes $action fixture did not report expected result"
  [ -z "$expected_detail" ] || assert_contains "$output" "$expected_detail" "no-mistakes $action fixture did not report lifecycle detail"
}

test_workflow_event_and_runner_contract() {
  assert_workflow_contract || fail "workflow scheduling contract failed"
  pass "workflow scheduling retains Ubuntu PR coverage and gates macOS natively"
}

test_no_mistakes_lifecycle_fixtures() {
  local action marker
  marker='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'

  for action in opened edited synchronize reopened; do
    run_no_mistakes_fixture "$action" "$marker" 0 "Found no-mistakes signature"
  done

  for action in opened synchronize reopened; do
    run_no_mistakes_fixture "$action" "" 0 "::notice::No no-mistakes signature" "during $action"
  done
  run_no_mistakes_fixture edited "" 1 "::error::This PR was not raised through no-mistakes."
  pass "no-mistakes lifecycle fixtures preserve notices and meaningful body-edit enforcement"
}

test_workflow_event_and_runner_contract
test_no_mistakes_lifecycle_fixtures
