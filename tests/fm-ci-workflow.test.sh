#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while close main pushes keep only
# the newest run, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy), so no job drifts back to a one-off number.
#
# They also hold the outside pull request gate the maintainer approved in
# DOP-167 (keep public CI within GitHub's 40-job limit): a PR from an author
# without write access runs only the quick checks and a failing Full suite
# verdict until the full-ci label is added, the label and later pushes run the
# whole suite, any other label neither starts nor cancels a run, and close main
# pushes keep only the newest run.
#
# They also hold the fork opt-out: the repository variables FM_CI_SKIP_PUSH and
# FM_CI_SKIP_MACOS let a fork skip the push run and the macOS job through a
# job-level condition, while with neither set every job runs exactly as before.
#
# The workflow is parsed as YAML and its concurrency and job-level `if`
# expressions are resolved against simulated pull_request and push contexts,
# so the assertions describe what GitHub would do, not how the file happens
# to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Evaluate the subset of GitHub's expression language that ci.yml uses -
# string literals, context lookups (including object filters such as
# labels.*.name, simulated as arrays), the status functions, contains(), !,
# ==, !=, &&, ||, and parentheses - against a simulated context hash, following the
# documented operator precedence, the case-insensitive string comparison, and
# the `a || b` fallback that returns the first truthy operand rather than a
# boolean. The status functions read the simulated outcome of the needed jobs
# from the context key "needs.status" (success, failure, or cancelled), which
# defaults to success. Each ruby -e below prepends this so every resolver shares one
# evaluator.
# shellcheck disable=SC2016  # the ${{ }} below is Ruby text, not a shell expansion
EXPRESSION_RUBY='
require "strscan"
class Expression
  def self.evaluate(source, context)
    new(source, context).parse
  end

  STATUS_FUNCTIONS = %w[always() success() failure() cancelled()].freeze

  # A job or step `if` is a bare expression or one wrapped in ${{ }}, an
  # absent condition means the job runs, and a condition that calls no status
  # function gets the implicit success() check GitHub documents.
  def self.condition(raw, context)
    source = raw.to_s.strip
    source = Regexp.last_match(1) if source =~ /\A\$\{\{(.*)\}\}\z/m
    source = "success()" if source.empty?
    source = "success() && (#{source})" unless new(source, context).status_check?
    truthy?(evaluate(source, context))
  end

  # A result is truthy unless it is false, nil, or the empty string.
  def self.truthy?(value)
    value != false && !value.nil? && value != ""
  end

  def initialize(source, context)
    @context = context
    @tokens = []
    scanner = StringScanner.new(source)
    until scanner.eos?
      next if scanner.skip(/\s+/)
      if scanner.scan(/\x27([^\x27]*)\x27/) then @tokens << [:string, scanner[1]]
      elsif scanner.scan(/\|\||&&|==|!=|[()!,]/) then @tokens << [:operator, scanner.matched]
      elsif scanner.scan(/[A-Za-z_][\w.\-*]*(?:\(\))?/) then @tokens << [:name, scanner.matched]
      else raise "unsupported expression syntax at: #{scanner.rest}"
      end
    end
  end

  def status_check?
    @tokens.any? { |kind, value| kind == :name && STATUS_FUNCTIONS.include?(value) }
  end

  def parse
    result = parse_or
    raise "unexpected trailing token: #{@tokens.first.inspect}" unless @tokens.empty?
    result
  end

  private

  def take?(operator)
    return false unless @tokens.first == [:operator, operator]
    @tokens.shift
    true
  end

  def parse_or
    left = parse_and
    while take?("||")
      right = parse_and
      left = Expression.truthy?(left) ? left : right
    end
    left
  end

  def parse_and
    left = parse_comparison
    while take?("&&")
      right = parse_comparison
      left = Expression.truthy?(left) ? right : left
    end
    left
  end

  def parse_comparison
    left = parse_unary
    loop do
      operator = ["==", "!="].find { |candidate| take?(candidate) } or break
      right = parse_unary
      unless left.class == right.class
        raise "the resolver only compares operands of one type: #{left.inspect} #{operator} #{right.inspect}"
      end
      equal = left.is_a?(String) ? left.casecmp?(right) : left == right
      left = operator == "==" ? equal : !equal
    end
    left
  end

  def parse_unary
    return !Expression.truthy?(parse_unary) if take?("!")
    parse_primary
  end

  def parse_primary
    if take?("(")
      inner = parse_or
      raise "missing closing parenthesis" unless take?(")")
      return inner
    end
    kind, value = @tokens.shift
    raise "expected an operand, got #{kind.inspect}" unless kind == :string || kind == :name
    return value if kind == :string
    if STATUS_FUNCTIONS.include?(value)
      status = @context.fetch("needs.status", "success")
      return value == "always()" || value == "#{status}()"
    end
    if value == "contains" && take?("(")
      haystack = parse_or
      raise "contains() takes two arguments" unless take?(",")
      needle = parse_or
      raise "missing closing parenthesis" unless take?(")")
      return Array(haystack).any? { |item| item.to_s.casecmp?(needle.to_s) } if haystack.is_a?(Array)
      return haystack.to_s.downcase.include?(needle.to_s.downcase)
    end
    raise "unresolvable context reference: #{value}" unless @context.key?(value)
    @context.fetch(value)
  end
end
'

# Build a simulated GitHub context from KEY=VALUE overrides on top of an
# outside contributor's fork PR synchronize event: no labels, no write access,
# fork variables unset, and needed jobs successful. Short keys: event, action,
# label (the label an event adds), labels (comma-separated labels on the PR),
# association, head (head repository), number, run_id, skip_push, skip_macos,
# needs (success, failure, or cancelled: the needed jobs' results that job
# conditions and the Full suite verdict read), outcome (how every job that runs
# concludes, read only by published_checks). A push event clears the PR fields,
# which GitHub leaves empty there. Each resolver prepends this.
# shellcheck disable=SC2016  # Ruby text, not shell expansions
CONTEXT_RUBY='
def simulated_context(workflow_name, overrides)
  o = {
    "event" => "pull_request", "action" => "synchronize", "label" => "",
    "labels" => "", "association" => "NONE", "head" => "contributor/firstmate",
    "number" => "108", "run_id" => "900001", "skip_push" => "", "skip_macos" => "",
    "needs" => "success", "outcome" => "success",
  }
  if overrides.any? { |pair| pair == "event=push" }
    o.merge!("action" => "", "association" => "", "head" => "", "number" => "")
  end
  overrides.each do |pair|
    key, value = pair.split("=", 2)
    raise "unknown context key #{key}" unless o.key?(key)
    o[key] = value.to_s
  end
  {
    "github.workflow" => workflow_name,
    "github.repository" => "kunchenguid/firstmate",
    "github.event_name" => o["event"],
    "github.event.action" => o["action"],
    "github.event.label.name" => o["label"],
    "github.event.pull_request.labels.*.name" => o["labels"].split(","),
    "github.event.pull_request.author_association" => o["association"],
    "github.event.pull_request.head.repo.full_name" => o["head"],
    "github.event.pull_request.number" => o["number"],
    "github.run_id" => o["run_id"],
    "vars.FM_CI_SKIP_PUSH" => o["skip_push"],
    "vars.FM_CI_SKIP_MACOS" => o["skip_macos"],
    "needs.status" => o["needs"],
    "needs.*.result" => [o["needs"]],
    "simulated.outcome" => o["outcome"],
  }
end

# Whether the workflow triggers start a run for this simulated event at all:
# a pull_request action outside on.pull_request.types (the GitHub default when
# absent is opened, synchronize, reopened) starts no run and publishes nothing.
# Psych reads the bare key `on` as true.
def triggered?(doc, context)
  return true unless context["github.event_name"] == "pull_request"
  triggers = doc[true] || doc["on"]
  types = triggers.fetch("pull_request", nil).to_h.fetch("types", %w[opened synchronize reopened])
  types.include?(context["github.event.action"])
end

def interpolate(raw, context)
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/m) { Expression.evaluate(Regexp.last_match(1), context).to_s }
end
'

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>".
resolve_concurrency() {  # [KEY=VALUE]...
  ruby -ryaml -e "$EXPRESSION_RUBY" -e "$CONTEXT_RUBY" -e '
doc = YAML.load_file(ARGV.shift)
concurrency = doc.fetch("concurrency")
context = simulated_context(doc.fetch("name"), ARGV)
puts [interpolate(concurrency.fetch("group"), context),
      interpolate(concurrency.fetch("cancel-in-progress"), context)].join("\t")
' "$CI_WORKFLOW" "$@"
}

# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated context; an unset repository variable
# reads as the empty string, as GitHub documents.
jobs_running_under() {  # [KEY=VALUE]...
  ruby -ryaml -e "$EXPRESSION_RUBY" -e "$CONTEXT_RUBY" -e '
doc = YAML.load_file(ARGV.shift)
context = simulated_context(doc.fetch("name"), ARGV)
exit unless triggered?(doc, context)
doc.fetch("jobs").each do |name, job|
  puts name if Expression.condition(job["if"], context)
end
' "$CI_WORKFLOW" "$@"
}

# Run the Full suite job's steps under one simulated context exactly as the
# runner would: each step's env expressions are resolved, then its script runs
# under bash with that environment. Prints the scripts' output; the exit status
# is the job's.
run_full_suite_verdict() {  # [KEY=VALUE]...
  local script
  script=$(ruby -ryaml -rshellwords -e "$EXPRESSION_RUBY" -e "$CONTEXT_RUBY" -e '
doc = YAML.load_file(ARGV.shift)
context = simulated_context(doc.fetch("name"), ARGV)
doc.fetch("jobs").fetch("full-suite").fetch("steps").each do |step|
  env = step.fetch("env", {}).map { |k, v| "#{k}=#{interpolate(v, context).shellescape}" }.join(" ")
  puts "#{env} bash -c #{step.fetch("run").shellescape} || exit $?"
end
' "$CI_WORKFLOW" "$@") || fail "could not resolve the Full suite steps"
  bash -c "$script" 2>&1
}

# Print the checks one simulated run publishes, one "<name><TAB><conclusion>"
# per line: GitHub publishes a check for every job, running or skipped, so a
# skipped job still appears with conclusion skipped. Matrix jobs are expanded
# even when skipped, the stricter assumption about how GitHub names them. Job
# conditions read the needs prerequisite status as given; every running job
# concludes with the simulated outcome, and the Full suite verdict is executed
# by run_full_suite_verdict with that outcome as its needed jobs' results.
published_checks() {  # [KEY=VALUE]...
  local rows name conclusion outcome=success arg
  for arg in "$@"; do
    case $arg in outcome=*) outcome=${arg#outcome=} ;; esac
  done
  rows=$(ruby -ryaml -e "$EXPRESSION_RUBY" -e "$CONTEXT_RUBY" -e '
doc = YAML.load_file(ARGV.shift)
context = simulated_context(doc.fetch("name"), ARGV)
exit unless triggered?(doc, context)
doc.fetch("jobs").each do |id, job|
  runs = Expression.condition(job["if"], context)
  matrix = job.dig("strategy", "matrix") || {}
  expansions = matrix.empty? ? [{}] : matrix.flat_map { |k, values| values.map { |v| { "matrix.#{k}" => v.to_s } } }
  expansions.each do |extra|
    name = interpolate(job.fetch("name", id), context.merge(extra))
    conclusion = !runs ? "skipped" : id == "full-suite" ? "verdict" : context.fetch("simulated.outcome")
    puts [name, conclusion].join("\t")
  end
end
' "$CI_WORKFLOW" "$@") || fail "could not resolve the published checks"
  [ -n "$rows" ] || return 0
  while IFS=$'\t' read -r name conclusion; do
    if [ "$conclusion" = verdict ]; then
      if run_full_suite_verdict "$@" needs="$outcome" >/dev/null; then conclusion=success; else conclusion=failure; fi
    fi
    printf '%s\t%s\n' "$name" "$conclusion"
  done <<<"$rows"
}

# Print the PR's visible checks after several runs on one head, given in the
# order their checks finish: per check name, the later run's check replaces
# the earlier one, as GitHub and bin/fm-pr-merge.sh's newest-check handling
# both read it. Each argument is one run's KEY=VALUE list.
checks_after_runs() {  # <run KEY=VALUE list>...
  local run all=
  for run in "$@"; do
    # shellcheck disable=SC2086  # each argument is a deliberate word list
    all=$all$(published_checks $run)$'\n' || exit 1
  done
  printf '%s' "$all" | awk -F '\t' 'NF { latest[$1] = $2; if (!($1 in seen)) { seen[$1] = 1; names[n++] = $1 } }
    END { for (i = 0; i < n; i++) print names[i] "\t" latest[names[i]] }'
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate full-suite'
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

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency number=108 run_id=900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency number=108 run_id=900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency number=108 run_id=900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency number=109 run_id=900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

# DOP-167 "newest merge's run only": main pushes share one group that cancels
# the older run, and never share a group with a PR run.
test_main_pushes_keep_only_the_newest_run() {
  local first second pr
  first=$(resolve_concurrency event=push run_id=900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency event=push run_id=900011) || fail "could not resolve push concurrency"
  pr=$(resolve_concurrency number=108 run_id=900012) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "main pushes must share one concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "a newer main push must cancel the older main run, got $(cancel_of "$first")"
  [ "$(group_of "$first")" != "$(group_of "$pr")" ] \
    || fail "a PR run must never share the main push group ($(group_of "$first"))"
  pass "close main pushes keep only the newest run, apart from every PR group"
}

# DOP-167: adding any other label neither starts nor cancels a run, while the
# full-ci label joins the PR's group so it replaces the quick-check run.
test_only_the_full_ci_label_joins_the_pr_group() {
  local push other another full
  push=$(resolve_concurrency number=108 run_id=900020) || fail "could not resolve PR concurrency"
  other=$(resolve_concurrency number=108 run_id=900021 action=labeled label=bug labels=bug) \
    || fail "could not resolve unrelated label concurrency"
  another=$(resolve_concurrency number=108 run_id=900022 action=labeled label=documentation labels=bug,documentation) \
    || fail "could not resolve unrelated label concurrency"
  full=$(resolve_concurrency number=108 run_id=900023 action=labeled label=full-ci labels=full-ci) \
    || fail "could not resolve full-ci label concurrency"
  [ "$(group_of "$other")" != "$(group_of "$push")" ] && [ "$(group_of "$other")" != "$(group_of "$another")" ] \
    || fail "an unrelated label event must get its own group, got $(group_of "$other")"
  [ "$(cancel_of "$other")" = false ] \
    || fail "an unrelated label event must not cancel anything, got $(cancel_of "$other")"
  [ "$(group_of "$full")" = "$(group_of "$push")" ] && [ "$(cancel_of "$full")" = true ] \
    || fail "the full-ci label must supersede within the PR group, got $full"
  pass "only the full-ci label joins and supersedes the PR's group; other labels cancel nothing"
}

QUICK_JOBS='test-coverage invariants full-suite'

# DOP-167 direction A: an outside PR without the label runs only the quick
# checks and the Full suite verdict, which fails naming the label.
test_outside_pr_without_label_runs_only_quick_checks() {
  local action association actual out
  # The associations open fork PRs to firstmate carried on 2026-10-29.
  for association in CONTRIBUTOR FIRST_TIME_CONTRIBUTOR NONE; do
    for action in opened synchronize reopened; do
      actual=$(jobs_running_under action="$action" association="$association" | tr '\n' ' ') \
        || fail "could not resolve outside $association $action jobs"
      [ "$actual" = "$QUICK_JOBS " ] \
        || fail "an unlabelled outside PR ($association, $action) must run only $QUICK_JOBS, ran: $actual"
    done
  done
  if out=$(run_full_suite_verdict); then
    fail "the Full suite verdict must fail on an unlabelled outside PR:"$'\n'"$out"
  fi
  printf '%s\n' "$out" | grep -q 'full-ci' \
    || fail "the Full suite failure must name the full-ci label, got:"$'\n'"$out"
  pass "an unlabelled outside PR runs only the quick checks and a failing Full suite naming full-ci"
}

# DOP-167: the full-ci label and every later push run the whole suite, and the
# verdict then follows the lanes.
test_full_ci_label_runs_the_whole_suite() {
  local all actual out
  all=$(workflow_jobs | tr '\n' ' ') || fail "could not list ci.yml jobs"
  actual=$(jobs_running_under action=labeled label=full-ci labels=full-ci | tr '\n' ' ') \
    || fail "could not resolve full-ci label jobs"
  [ "$actual" = "$all" ] || fail "adding full-ci must run every job, ran: $actual"
  actual=$(jobs_running_under labels=bug,full-ci | tr '\n' ' ') || fail "could not resolve labelled push jobs"
  [ "$actual" = "$all" ] || fail "a later push to a full-ci PR must run every job, ran: $actual"
  out=$(run_full_suite_verdict labels=full-ci) \
    || fail "the Full suite verdict must pass on a labelled PR whose lanes passed:"$'\n'"$out"
  if out=$(run_full_suite_verdict labels=full-ci needs=failure); then
    fail "the Full suite verdict must fail when a lane failed:"$'\n'"$out"
  fi
  if out=$(run_full_suite_verdict labels=full-ci needs=cancelled); then
    fail "the Full suite verdict must fail when a lane was cancelled:"$'\n'"$out"
  fi
  pass "the full-ci label and later pushes run every job, and the verdict follows the lanes"
}

# DOP-167: main, own branches and write-access authors run everything as today.
test_trusted_runs_are_unchanged() {
  local all context actual out
  all=$(workflow_jobs | tr '\n' ' ') || fail "could not list ci.yml jobs"
  for context in event=push association=OWNER association=MEMBER association=COLLABORATOR head=kunchenguid/firstmate; do
    actual=$(jobs_running_under "$context" | tr '\n' ' ') || fail "could not resolve jobs for $context"
    [ "$actual" = "$all" ] || fail "$context must run every job as before, ran: $actual"
    out=$(run_full_suite_verdict "$context") \
      || fail "the Full suite verdict must pass for $context when its lanes passed:"$'\n'"$out"
  done
  pass "main pushes, own branches and write-access authors still run every job and pass the verdict"
}

# DOP-167: another label neither starts nor cancels a run: no job runs, not
# even the Full suite verdict, whose waiting failure the PR's push already
# published (Greptile review on PR #7949: a verdict from that never-cancelled
# run could otherwise finish after, and mask, a later full-ci pass).
test_unrelated_label_starts_no_job() {
  local labels association actual
  while read -r labels association; do
    actual=$(jobs_running_under action=labeled label=bug labels="$labels" association="$association") \
      || fail "could not resolve unrelated label jobs for labels=$labels association=$association"
    [ -z "$actual" ] \
      || fail "an unrelated label (labels=$labels association=$association) must run no job, ran: $(printf '%s' "$actual" | tr '\n' ' ')"
  done <<'TABLE'
bug         NONE
full-ci,bug NONE
bug         OWNER
TABLE
  pass "an unrelated label runs no job on a waiting, labelled or owner PR"
}

# Greptile review on PR #7949: an unrelated label added before full-ci starts
# a run that is never cancelled; even if its checks finish after the approved
# full-ci run, the passing Full suite must stay the visible verdict.
test_late_unrelated_label_run_never_masks_a_full_ci_pass() {
  local after
  after=$(checks_after_runs "outcome=success" \
    "action=labeled label=full-ci labels=bug,full-ci outcome=success" \
    "action=labeled label=bug labels=bug outcome=success") \
    || fail "could not merge the three runs"
  printf '%s\n' "$after" | grep -qx $'Full suite\tsuccess' \
    || fail "a late unrelated label run must leave Full suite passing, got:"$'\n'"$after"
  printf '%s\n' "$after" | grep -qx $'Lint 1\tsuccess' \
    || fail "a late unrelated label run must leave the lanes passing, got:"$'\n'"$after"
  pass "a late-finishing unrelated label run leaves a full-ci pass visible"
}

# sequence must leave the earlier failure visible under its own check names.
test_unrelated_label_never_masks_an_earlier_failure() {
  local first label expect want before after name conclusion
  while IFS='|' read -r first label expect; do
    # shellcheck disable=SC2086  # each column is a deliberate word list
    before=$(published_checks $first) || fail "could not resolve the first run for $first"
    # Every canonical check the first run published must hold the expected
    # conclusion, so the label run below has a real failure to mask.
    while IFS=$'\t' read -r name conclusion; do
      case "$expect:$name" in
        all-failed:*) want=failure ;;
        waiting:'Full suite') want=failure ;;
        waiting:'Test coverage guard'|waiting:'Repo invariants') want=success ;;
        waiting:*) want=skipped ;;
      esac
      [ "$conclusion" = "$want" ] \
        || fail "the first run ($first) must publish $name as $want before the label event, got $conclusion"
    done <<<"$before"
    after=$(checks_after_runs "$first" "$label") || fail "could not merge runs for $first"
    while IFS=$'\t' read -r name conclusion; do
      printf '%s\n' "$after" | grep -qxF "$name"$'\t'"$conclusion" \
        || fail "after an unrelated label, $name must still read $conclusion (first run: $first), got:"$'\n'"$after"
    done <<<"$before"
  done <<'TABLE'
labels=full-ci outcome=failure|action=labeled label=bug labels=full-ci,bug|all-failed
association=OWNER outcome=failure|action=labeled label=bug labels=bug association=OWNER|all-failed
outcome=success|action=labeled label=bug labels=bug|waiting
TABLE
  pass "an unrelated label after a failed or waiting suite leaves every earlier check as it was"
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

# The fork opt-out is opt-in: with neither variable set every job runs on both
# events, FM_CI_SKIP_PUSH=1 empties only the push run, and FM_CI_SKIP_MACOS=1
# removes only the macOS job. A "-" in the table means the variable is unset.
test_fork_skip_variables_are_opt_in() {
  local all event skip_push skip_macos expected want actual
  all=$(workflow_jobs) || fail "could not list ci.yml jobs"
  printf '%s\n' "$all" | grep -qx macos-stock-bash \
    || fail "the macOS job is missing from ci.yml, so the table below would prove nothing"
  while read -r event skip_push skip_macos expected; do
    [ "$skip_push" != - ] || skip_push=
    [ "$skip_macos" != - ] || skip_macos=
    case $expected in
      all) want=$all ;;
      none) want= ;;
      all-but-macos) want=$(printf '%s\n' "$all" | grep -vx macos-stock-bash) ;;
      *) fail "unknown expectation $expected" ;;
    esac
    actual=$(jobs_running_under event="$event" association=OWNER skip_push="$skip_push" skip_macos="$skip_macos") \
      || fail "could not resolve the job conditions for $event FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos"
    [ "$actual" = "$want" ] \
      || fail "$event with FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos must run $expected jobs"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"wanted: $(printf '%s' "$want" | tr '\n' ' ')"
  done <<'TABLE'
push         - - all
pull_request - - all
push         1 - none
pull_request 1 - all
pull_request - 1 all-but-macos
push         - 1 all-but-macos
TABLE
  pass "the fork skip variables change nothing unless set, and each skips only its own run or job"
}

# Print true or false: whether one job's job-level `if` resolves true under
# one simulated context.
job_runs_under() {  # <job> [KEY=VALUE]...
  ruby -ryaml -e "$EXPRESSION_RUBY" -e "$CONTEXT_RUBY" -e '
doc = YAML.load_file(ARGV.shift)
job = ARGV.shift
context = simulated_context(doc.fetch("name"), ARGV)
puts Expression.condition(doc.fetch("jobs").fetch(job)["if"], context)
' "$CI_WORKFLOW" "$@"
}

# The aggregate must keep running after a failed lane so its timing summary
# still lands, while the push skip still removes it from a skipped push run.
test_timing_aggregate_still_runs_after_a_failed_lane() {
  local event skip_push expected actual
  while read -r event skip_push expected; do
    [ "$skip_push" != - ] || skip_push=
    actual=$(job_runs_under tests-timing-aggregate event="$event" association=OWNER skip_push="$skip_push" needs=failure) \
      || fail "could not resolve the aggregate condition for $event FM_CI_SKIP_PUSH=$skip_push"
    [ "$actual" = "$expected" ] \
      || fail "after a failed lane, the aggregate on $event with FM_CI_SKIP_PUSH=$skip_push must resolve $expected, got $actual"
  done <<'TABLE'
pull_request - true
push         - true
push         1 false
TABLE
  pass "the timing aggregate still runs after a failed lane unless the push run is skipped"
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

test_ci_matrices_match_executable_partitions
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_keep_only_the_newest_run
test_only_the_full_ci_label_joins_the_pr_group
test_outside_pr_without_label_runs_only_quick_checks
test_full_ci_label_runs_the_whole_suite
test_trusted_runs_are_unchanged
test_unrelated_label_starts_no_job
test_late_unrelated_label_run_never_masks_a_full_ci_pass
test_unrelated_label_never_masks_an_earlier_failure
test_fork_skip_variables_are_opt_in
test_timing_aggregate_still_runs_after_a_failed_lane
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
