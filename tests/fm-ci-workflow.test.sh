#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy), so no job drifts back to a one-off number.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='changes test-coverage invariants tests-timing-aggregate ci-result'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash'
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

# Resolve one job's runs-on under a simulated event, head repository, and
# FM_REVIEW_BOX value, printing "<job><TAB><comma-joined labels>". Only the
# constructs this workflow uses are resolved: a parenthesized || / && chain,
# == comparisons, and fromJSON('[...]'); a plain runner string passes through.
resolve_runs_on() {
  local event=$1 head_repo=$2 variable=$3
  shift 3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
event, head_repo, variable = ARGV[1], ARGV[2], ARGV[3]
context = {
  "github.event_name" => event,
  "github.event.pull_request.head.repo.full_name" => head_repo,
  "github.repository" => "umeranjum17/firstmate",
  "vars.FM_REVIEW_BOX" => variable,
}
ARGV[4..].each do |job|
  raw = doc.fetch("jobs").fetch(job).fetch("runs-on").to_s.strip
  match = raw.match(/\A\s*\$\{\{\s*(.*?)\s*\}\}\s*\z/m)
  labels =
    if match
      inner = match[1]
      inner = inner.gsub(%r{fromJSON\(([^)]*)\)}) { Regexp.last_match(1).gsub("\x27", "") }
      context.each { |key, value| inner = inner.gsub(key, value.inspect) }
      value = eval(inner) # rubocop:disable Security/Eval
      value.is_a?(Array) ? value.join(",") : value.to_s
    else
      raw
    end
  puts "#{job}\t#{labels}"
end
' "$CI_WORKFLOW" "$event" "$head_repo" "$variable" "$@"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

# Print ci.yml's real changes-job classify step script: the decision text the
# Actions runner executes, extracted through the YAML, not a copy of it.
classify_step_script() {
  ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("changes").fetch("steps")
index = steps.index { |s| s["id"] == "scope" }
raise "changes job has no scope-classifying step" unless index
puts steps[index].fetch("run")
' "$CI_WORKFLOW"
}

# Run ci.yml's classify step inside a fixture repository with a pull_request
# event and print the heavy value it writes to GITHUB_OUTPUT.
run_classify_step() {  # <fixture-repo> <step-script>
  local repo=$1 step=$2 out value
  out="$repo/../classify-output"
  rm -f "$out"
  (cd "$repo" && EVENT_NAME=pull_request GITHUB_OUTPUT="$out" bash -c "$step") 1>&2 \
    || { echo "classify step failed in $repo" >&2; return 1; }
  value=$(sed -n 's/^heavy=//p' "$out")
  [ -n "$value" ] || { echo "classify step wrote no heavy output" >&2; return 1; }
  printf '%s\n' "$value"
}

# Build a fixture repository under the registered temp root with bin/ tracked
# (the classify step calls bin/fm-test-run.sh) and one tracked payload file.
build_classify_repo() {  # <repo> <payload-rel-path> <payload-content>
  local repo=$1 path=$2 content=$3 dir
  dir=$(dirname "$path")
  mkdir -p "$repo/bin" "$repo/$dir"
  cp "$ROOT/bin/fm-test-run.sh" "$repo/bin/"
  printf '%s\n' "$content" >"$repo/$path"
  git -C "$repo" -c init.defaultBranch=main init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.email=ci@firstmate.test -c user.name=ci commit -qm base
}

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly three
# distinct job-level timeouts: one per tier, no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 3 ] \
    || fail "ci.yml must carry exactly three distinct job timeouts (fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the three timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 30-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

# The self-hosted review box backs a public repository, so untrusted fork pull
# requests must never select it, while trusted runs use it only when the
# FM_REVIEW_BOX repository variable opts in, so a maintainer can fall back to
# GitHub-hosted runners by clearing that one variable instead of reverting.
test_review_box_runner_selection_is_fork_safe() {
  local moved job line
  moved='changes test-coverage invariants ci-result'
  for job in $moved; do
    # Fork PR: never the box, even with the opt-in variable set.
    line=$(resolve_runs_on pull_request "someuser/firstmate" 1 "$job") \
      || fail "could not resolve $job runs-on"
    [ "$(printf '%s' "$line" | cut -f2)" = "ubuntu-latest" ] \
      || fail "a fork pull_request must never run $job on the review box, got $(printf '%s' "$line" | cut -f2)"
    # Trusted PR with the opt-in variable set: the box.
    line=$(resolve_runs_on pull_request "umeranjum17/firstmate" 1 "$job") \
      || fail "could not resolve $job runs-on"
    [ "$(printf '%s' "$line" | cut -f2)" = "self-hosted,review-box" ] \
      || fail "a trusted PR must run $job on the review box when opted in, got $(printf '%s' "$line" | cut -f2)"
    # Push to main with the opt-in variable set: the box.
    line=$(resolve_runs_on push "" 1 "$job") \
      || fail "could not resolve $job runs-on"
    [ "$(printf '%s' "$line" | cut -f2)" = "self-hosted,review-box" ] \
      || fail "a push to main must run $job on the review box when opted in, got $(printf '%s' "$line" | cut -f2)"
    # Fallback: clearing the variable returns trusted runs to GitHub-hosted.
    line=$(resolve_runs_on pull_request "umeranjum17/firstmate" 0 "$job") \
      || fail "could not resolve $job runs-on"
    [ "$(printf '%s' "$line" | cut -f2)" = "ubuntu-latest" ] \
      || fail "clearing FM_REVIEW_BOX must fall back to ubuntu-latest for $job, got $(printf '%s' "$line" | cut -f2)"
  done

  # The lint partitions (ShellCheck peaks above the box's memory cap), the
  # heavyweight shards, and the Herdr lane stay on GitHub-hosted runners.
  for job in lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial tests-herdr; do
    line=$(resolve_runs_on pull_request "umeranjum17/firstmate" 1 "$job") \
      || fail "could not resolve $job runs-on"
    [ "$(printf '%s' "$line" | cut -f2)" = "ubuntu-latest" ] \
      || fail "$job must stay on ubuntu-latest, got $(printf '%s' "$line" | cut -f2)"
  done
  pass "review-box runner selection stays fork-safe and falls back on one variable"
}

# The docs-only skip decides from an empty test selection, but a deleted
# tests/ or bin/ path also selects nothing by design, so deleting coverage
# must not ride that skip to a green required check. This executes ci.yml's
# real classify step against fixture repositories and asserts the decision.
test_changes_decision_runs_everything_for_deleted_tests() {
  local step repo root heavy
  step=$(classify_step_script) || fail "could not read the changes job's classify step"

  # A pull request that only deletes a test file must run the heavy lanes.
  root=$(fm_test_tmproot fm-ci-delete-test)
  repo="$root/repo"
  build_classify_repo "$repo" tests/fm-deleted-classify.test.sh 'exit 0'
  git -C "$repo" rm -q tests/fm-deleted-classify.test.sh
  git -C "$repo" -c user.email=ci@firstmate.test -c user.name=ci commit -qm "delete the test"
  heavy=$(run_classify_step "$repo" "$step") || fail "classify step failed for a deleted test"
  [ "$heavy" = true ] \
    || fail "a deletion-only pull request must run the heavy lanes, got heavy=$heavy"

  # Deleting a docs-only path keeps the skip: docs changes select nothing.
  root=$(fm_test_tmproot fm-ci-delete-doc)
  repo="$root/repo"
  build_classify_repo "$repo" docs/notes.md notes
  git -C "$repo" rm -q docs/notes.md
  git -C "$repo" -c user.email=ci@firstmate.test -c user.name=ci commit -qm "delete the note"
  heavy=$(run_classify_step "$repo" "$step") || fail "classify step failed for a deleted doc"
  [ "$heavy" = false ] \
    || fail "deleting a docs-only path must stay skippable, got heavy=$heavy"

  # An ordinary docs-only pull request (edit, no deletion) keeps the skip.
  root=$(fm_test_tmproot fm-ci-edit-doc)
  repo="$root/repo"
  build_classify_repo "$repo" docs/notes.md notes
  printf '%s\n' edited >"$repo/docs/notes.md"
  git -C "$repo" -c user.email=ci@firstmate.test -c user.name=ci commit -qam "edit the note"
  heavy=$(run_classify_step "$repo" "$step") || fail "classify step failed for an edited doc"
  [ "$heavy" = false ] \
    || fail "an ordinary docs-only pull request must stay skippable, got heavy=$heavy"

  # A pull request that carries the runner itself must not be classified by
  # it: the head commit swaps in a runner that reports an empty selection,
  # so only the untrusted-source rule can keep the heavy lanes running.
  root=$(fm_test_tmproot fm-ci-touch-runner)
  repo="$root/repo"
  build_classify_repo "$repo" docs/notes.md notes
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  git -C "$repo" -c user.email=ci@firstmate.test -c user.name=ci commit -qam "swap in a lying runner"
  heavy=$(run_classify_step "$repo" "$step") || fail "classify step failed for a runner change"
  [ "$heavy" = true ] \
    || fail "a pull request changing bin/fm-test-run.sh must run the heavy lanes, got heavy=$heavy"

  # The same holds when the pull request touches the workflow files, whose
  # text also comes from the merge commit. The fixture's base already runs a
  # stub that reports an empty selection, and the head commit changes only
  # the workflow file, so heavy=true can come from the workflow arm alone.
  root=$(fm_test_tmproot fm-ci-touch-workflow)
  repo="$root/repo"
  build_classify_repo "$repo" docs/notes.md notes
  printf '#!/usr/bin/env bash\nexit 0\n' >"$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  git -C "$repo" -c user.email=ci@firstmate.test -c user.name=ci commit -q --amend -am "base with a lying runner" \
    || fail "could not rebuild the workflow fixture's base"
  mkdir -p "$repo/.github/workflows"
  printf '%s\n' 'name: other' >"$repo/.github/workflows/other.yml"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=ci@firstmate.test -c user.name=ci commit -qm "add a workflow file"
  heavy=$(run_classify_step "$repo" "$step") || fail "classify step failed for a workflow change"
  [ "$heavy" = true ] \
    || fail "a pull request changing .github/workflows/ must run the heavy lanes, got heavy=$heavy"

  pass "the changes job runs everything for deleted tests, never trusts the pull request's own classifier, and keeps the docs-only skip"
}

test_ci_matrices_match_executable_partitions
test_review_box_runner_selection_is_fork_safe
test_changes_decision_runs_everything_for_deleted_tests
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
