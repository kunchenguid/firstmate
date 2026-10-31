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
fm_require_yq "parse .github/workflows/ci.yml as YAML"
CI_JSON=$(yq -o=json '.' "$CI_WORKFLOW") \
  || fail "could not parse .github/workflows/ci.yml as YAML"

# jq prelude shared by every workflow read: fetch mirrors a strict mapping
# lookup that errors on a missing key instead of yielding null, and strip trims
# surrounding whitespace.
# shellcheck disable=SC2016 # jq expands these references itself.
CI_JQ_LIB='
def fetch($key):
  if type == "object" and has($key) then .[$key]
  else error("key not found: \($key)") end;
def strip: sub("^\\s+"; "") | sub("\\s+$"; "");
'

# Evaluate the subset of GitHub's expression language that ci.yml uses -
# string literals, context lookups (including object filters such as
# labels.*.name, simulated as arrays), the status functions, contains(), !,
# ==, !=, &&, ||, and parentheses - against a simulated context object, following the
# documented operator precedence, the case-insensitive string comparison, and
# the `a || b` fallback that returns the first truthy operand rather than a
# boolean. The status functions read the simulated outcome of the needed jobs
# from the context key "needs.status" (success, failure, or cancelled), which
# defaults to success. Each resolver below appends this to CI_JQ_LIB so every
# resolver shares one evaluator.
#
# It also builds the simulated GitHub context from KEY=VALUE overrides on top of
# an outside contributor's fork PR synchronize event: no labels, no write
# access, fork variables unset, and needed jobs successful. Short keys: event,
# action, label (the label an event adds), labels (comma-separated labels on the
# PR), association, head (head repository), number, run_id, skip_push,
# skip_macos, needs (success, failure, or cancelled: the needed jobs' results
# that job conditions and the Full suite verdict read), outcome (how every job
# that runs concludes, read only by published_checks). A push event clears the
# PR fields, which GitHub leaves empty there.
# shellcheck disable=SC2016  # the ${{ }} below is jq text, not a shell expansion
CI_EXPR_JQ='
# A result is truthy unless it is false, null, or the empty string.
def truthy: . != false and . != null and . != "";
def status_functions: ["always()", "success()", "failure()", "cancelled()"];

def tokens:
  [scan("\\s+|\u0027[^\u0027]*\u0027|\\|\\||&&|==|!=|[()!,]|[A-Za-z_][\\w.\\-*]*(?:\\(\\))?|.")
   | select(test("^\\s+$") | not)
   | if length > 1 and startswith("\u0027") and endswith("\u0027") then ["string", .[1:-1]]
     elif test("^(\\|\\||&&|==|!=|[()!,])$") then ["operator", .]
     elif test("^[A-Za-z_]") then ["name", .]
     else error("unsupported expression syntax at: \(.)") end];

def evaluate($context):
  def peek($operator): .tokens[0] == ["operator", $operator];
  def drop: .tokens |= .[1:];
  def expect($operator; $message): if peek($operator) then drop else error($message) end;
  def parse_or:
    def primary:
      if peek("(") then drop | parse_or | expect(")"; "missing closing parenthesis")
      else
        .tokens[0] as $token
        | drop
        | if $token[0] != "string" and $token[0] != "name" then
            error("expected an operand, got \($token[0] | tojson)")
          elif $token[0] == "string" then .value = $token[1]
          elif any(status_functions[]; . == $token[1]) then
            .value = ($token[1] == "always()" or $token[1] == "\($context["needs.status"] // "success")()")
          elif $token[1] == "contains" and peek("(") then
            drop | parse_or | .value as $haystack
            | expect(","; "contains() takes two arguments") | parse_or | .value as $needle
            | expect(")"; "missing closing parenthesis")
            | ($needle | tostring | ascii_downcase) as $needle
            | .value = (if ($haystack | type) == "array" then
                any($haystack[]; tostring | ascii_downcase == $needle)
              else $haystack | tostring | ascii_downcase | contains($needle) end)
          elif $context | has($token[1]) then .value = $context[$token[1]]
          else error("unresolvable context reference: \($token[1])") end
      end;
    def unary: if peek("!") then drop | unary | .value |= (truthy | not) else primary end;
    def comparison:
      def more:
        if peek("==") or peek("!=") then
          .tokens[0][1] as $operator | .value as $left | drop | unary | .value as $right
          | if ($left | type) != ($right | type) then
              error("the resolver only compares operands of one type: \($left | tojson) \($operator) \($right | tojson)")
            else . end
          | (if ($left | type) == "string" then ($left | ascii_downcase) == ($right | ascii_downcase)
             else $left == $right end) as $equal
          | .value = (if $operator == "==" then $equal else ($equal | not) end)
          | more
        else . end;
      unary | more;
    def conjunction:
      def more:
        if peek("&&") then
          .value as $left | drop | comparison
          | .value = (if $left | truthy then .value else $left end) | more
        else . end;
      comparison | more;
    def more:
      if peek("||") then
        .value as $left | drop | conjunction
        | .value = (if $left | truthy then $left else .value end) | more
      else . end;
    conjunction | more;
  {tokens: tokens} | parse_or
  | if .tokens == [] then .value else error("unexpected trailing token: \(.tokens[0] | tojson)") end;

# A job or step `if` is a bare expression or one wrapped in ${{ }}, an absent
# condition means the job runs, and a condition that calls no status function
# gets the implicit success() check GitHub documents.
def condition($context):
  (if . == null then "" else tostring end | strip) as $raw
  | ($raw | capture("^\\$\\{\\{(?<expression>.*)\\}\\}$"; "p") | .expression) // $raw
  | if . == "" then "success()" else . end
  | if any(tokens[]; .[0] == "name" and (.[1] as $name | any(status_functions[]; . == $name))) then .
    else "success() && (\(.))" end
  | evaluate($context) | truthy;

def interpolate($context):
  (if . == null then "" else tostring end)
  | gsub("\\$\\{\\{(?<expression>.+?)\\}\\}"; .expression | evaluate($context) | tostring; "p");

def simulated_context($workflow; $overrides):
  {
    "event": "pull_request", "action": "synchronize", "label": "",
    "labels": "", "association": "NONE", "head": "contributor/firstmate",
    "number": "108", "run_id": "900001", "skip_push": "", "skip_macos": "",
    "needs": "success", "outcome": "success"
  }
  | if any($overrides[]; . == "event=push") then
      . + {"action": "", "association": "", "head": "", "number": ""}
    else . end
  | reduce ($overrides[] | split("=")) as $pair (.;
      $pair[0] as $key
      | if has($key) then .[$key] = ($pair[1:] | join("="))
        else error("unknown context key \($key)") end)
  | {
      "github.workflow": $workflow,
      "github.repository": "kunchenguid/firstmate",
      "github.event_name": .event,
      "github.event.action": .action,
      "github.event.label.name": .label,
      "github.event.pull_request.labels.*.name": (.labels | split(",") | until(length == 0 or .[-1] != ""; .[:-1])),
      "github.event.pull_request.author_association": .association,
      "github.event.pull_request.head.repo.full_name": .head,
      "github.event.pull_request.number": .number,
      "github.run_id": .run_id,
      "vars.FM_CI_SKIP_PUSH": .skip_push,
      "vars.FM_CI_SKIP_MACOS": .skip_macos,
      "needs.status": .needs,
      "needs.*.result": [.needs],
      "simulated.outcome": .outcome
    };

# Whether the workflow triggers start a run for this simulated event at all:
# a pull_request action outside on.pull_request.types (the GitHub default when
# absent is opened, synchronize, reopened) starts no run and publishes nothing.
def triggered($context):
  $context["github.event_name"] != "pull_request"
  or (fetch("on") | (.pull_request // {}) | (.types // ["opened", "synchronize", "reopened"])
      | any(.[]; . == $context["github.event.action"]));
'

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>".
resolve_concurrency() {  # [KEY=VALUE]...
  jq -r "$CI_JQ_LIB$CI_EXPR_JQ"'
simulated_context(fetch("name"); $ARGS.positional) as $context
| fetch("concurrency")
| [(fetch("group") | interpolate($context)), (fetch("cancel-in-progress") | interpolate($context))]
| join("\t")
' --args "$@" <<<"$CI_JSON"
}

# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated context; an unset repository variable
# reads as the empty string, as GitHub documents.
jobs_running_under() {  # [KEY=VALUE]...
  jq -r "$CI_JQ_LIB$CI_EXPR_JQ"'
simulated_context(fetch("name"); $ARGS.positional) as $context
| select(triggered($context))
| fetch("jobs") | to_entries[]
| select(.value | .["if"] | condition($context)) | .key
' --args "$@" <<<"$CI_JSON"
}

# Run the Full suite job's steps under one simulated context exactly as the
# runner would: each step's env expressions are resolved, then its script runs
# under bash with that environment. Prints the scripts' output; the exit status
# is the job's.
run_full_suite_verdict() {  # [KEY=VALUE]...
  local script
  script=$(jq -r "$CI_JQ_LIB$CI_EXPR_JQ"'
simulated_context(fetch("name"); $ARGS.positional) as $context
| fetch("jobs") | fetch("full-suite") | fetch("steps")[]
| ([if has("env") then .env else {} end | to_entries[] | "\(.key)=\(.value | interpolate($context) | @sh)"]
   | join(" ")) as $env
| "\($env) bash -c \(fetch("run") | @sh) || exit $?"
' --args "$@" <<<"$CI_JSON") || fail "could not resolve the Full suite steps"
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
  rows=$(jq -r "$CI_JQ_LIB$CI_EXPR_JQ"'
simulated_context(fetch("name"); $ARGS.positional) as $context
| select(triggered($context))
| fetch("jobs") | to_entries[]
| .key as $id | .value as $job
| ($job | .["if"] | condition($context)) as $runs
| ($job.strategy.matrix // {}) as $matrix
| (if $matrix == {} then {}
   else $matrix | to_entries[] | .key as $key | .value[] | {("matrix." + $key): tostring} end) as $extra
| [($job | if has("name") then .name else $id end | interpolate($context + $extra)),
   (if ($runs | not) then "skipped" elif $id == "full-suite" then "verdict"
    else $context["simulated.outcome"] end)]
| join("\t")
' --args "$@" <<<"$CI_JSON") || fail "could not resolve the published checks"
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
  jq -r --arg job "$1" "$CI_JQ_LIB"'
fetch("jobs") | fetch($job)
| if has("timeout-minutes") then .["timeout-minutes"] // "" else "none" end
' <<<"$CI_JSON"
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
  jq -r "$CI_JQ_LIB"'fetch("jobs") | keys_unsorted[]' <<<"$CI_JSON"
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
  local timeouts reported
  # Annotate each timeout with its YAML tag so an integer-valued float such as
  # 30.0 is still rejected after the JSON conversion.
  timeouts=$(yq -o=json '.jobs | map_values(.["timeout-minutes"] | {"tag": tag, "value": .})' "$CI_WORKFLOW") \
    || fail "could not read job timeouts from ci.yml"
  reported=$(jq -r 'to_entries[]
    | select(.value.tag != "!!int" or .value.value <= 0)
    | "\(.key): \(.value.value | tojson)"' <<<"$timeouts") \
    || fail "could not read job timeouts from ci.yml"
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
  step=$(jq -r --arg job tests-herdr "$CI_JQ_LIB"'
def step_index($id): [to_entries[] | select((.value | objects | .id) == $id) | .key] | first;
fetch("jobs") | fetch($job) | fetch("steps")
| step_index("run-real-herdr-family") as $index
| step_index("cleanup-herdr-lab-sessions") as $teardown
| if $index == null then error("no run-real-herdr-family step")
  elif $teardown == null then error("no cleanup-herdr-lab-sessions step")
  elif $teardown <= $index then error("teardown must follow the family-run step")
  elif (.[$teardown].if | if . == null then "" else tostring end | strip) != "always()" then
    error("teardown must run under always()")
  else .[$index] | if has("timeout-minutes") then .["timeout-minutes"] // "" else "none" end
  end
' <<<"$CI_JSON") || fail "could not read the Herdr family-run step"
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
  local job=$1
  shift
  jq -r --arg job "$job" "$CI_JQ_LIB$CI_EXPR_JQ"'
simulated_context(fetch("name"); $ARGS.positional) as $context
| fetch("jobs") | fetch($job) | .["if"] | condition($context)
' --args "$@" <<<"$CI_JSON"
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

# Trim surrounding whitespace from every line of a command's listing.
strip_lines() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

test_ci_matrices_match_executable_partitions() {
  local expected parts lanes actual roots canonical part out
  expected=$(jq -r "$CI_JQ_LIB"'
fetch("jobs") | fetch("tests-portable-serial") | fetch("strategy")
| if fetch("fail-fast") != false then error("serial failures must not cancel other shards") else . end
| fetch("matrix")
| if (keys_unsorted) != ["shard"] then error("unexpected serial dimensions") else . end
| fetch("shard") as $shards
| $shards[] | "portable-serial-\(.)of\($shards | length)"
' <<<"$CI_JSON") || fail "CI partition contract"
  expected=$(printf '%s' "$expected" | LC_ALL=C sort)
  lanes=$("$ROOT/bin/fm-test-run.sh" --list-lanes) || fail "CI partition contract: cannot list runner lanes"
  actual=$(printf '%s\n' "$lanes" | strip_lines | grep -E '^portable-serial-[0-9]+of[0-9]+$' | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || fail "CI partition contract: CI matrix and runner disagree"

  parts=$(jq -r "$CI_JQ_LIB"'
fetch("jobs") | fetch("lint") | fetch("strategy")
| if fetch("fail-fast") != false then error("lint failures must not cancel another partition") else . end
| fetch("matrix")
| if (keys_unsorted) != ["partition"] then error("unexpected lint dimensions") else . end
| fetch("partition") as $parts
| $parts[] | "\(.)of\($parts | length)"
' <<<"$CI_JSON") || fail "CI partition contract"
  roots=
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    out=$("$ROOT/bin/fm-lint.sh" --partition "$part" --list-files) \
      || fail "CI partition contract: unsupported lint partition"
    [ -z "$out" ] || roots+=$out$'\n'
  done <<<"$parts"
  roots=$(printf '%s' "$roots" | strip_lines | LC_ALL=C sort)
  canonical=$(CI=true "$ROOT/bin/fm-lint.sh" --list-files) \
    || fail "CI partition contract: lint matrix loses or duplicates canonical roots"
  canonical=$(printf '%s\n' "$canonical" | strip_lines | LC_ALL=C sort)
  [ "$roots" = "$canonical" ] \
    || fail "CI partition contract: lint matrix loses or duplicates canonical roots"
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
