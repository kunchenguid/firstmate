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

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  jq -r --arg event "$event" --arg pr_number "$pr_number" --arg run_id "$run_id" "$CI_JQ_LIB"'
fetch("concurrency") as $concurrency
| {
    "github.workflow": fetch("name"),
    "github.event_name": $event,
    "github.event.pull_request.number": $pr_number,
    "github.run_id": $run_id
  } as $context
| def value:
    strip as $token
    | if ($token | startswith("\u0027")) and ($token | endswith("\u0027")) then $token[1:-1]
      elif $context | has($token) then $context[$token]
      else error("unresolvable context reference: \($token)") end;
  # Split like a fallback chain, dropping trailing empty operands.
  def operands: split("||") | until(length == 0 or .[-1] != ""; .[:-1]);
  def evaluate:
    strip as $expression
    | if $expression | contains("==") then
        ($expression | split("==")) as $sides
        | if ($sides[0] | value) == ($sides[1:] | join("==") | value) then "true" else "false" end
      else
        ([$expression | operands[] | value] | map(select(. != "")) | first) // "" | tostring
      end;
  def interpolate:
    (if . == null then "" else tostring end)
    | gsub("\\$\\{\\{(?<expression>.+?)\\}\\}"; .expression | evaluate);
  [($concurrency | fetch("group") | interpolate),
   ($concurrency | fetch("cancel-in-progress") | interpolate)]
  | join("\t")
' <<<"$CI_JSON"
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
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate'
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
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
