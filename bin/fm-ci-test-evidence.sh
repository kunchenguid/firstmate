#!/usr/bin/env bash
# fm-ci-test-evidence.sh - verify required GitHub Actions test jobs from their
# own logs rather than their green check conclusions.
#
# Usage:
#   fm-ci-test-evidence.sh --pr https://github.com/OWNER/REPO/pull/N --required-job NAME [--required-job NAME ...]
#   fm-ci-test-evidence.sh --run https://github.com/OWNER/REPO/actions/runs/RUN --required-job NAME [--required-job NAME ...]
#
# A required job is matched by its exact GitHub Actions job name.
# A PR measures each required job in the most recent Actions run for its current
# head commit that contains that job, while --run examines that exact run.
# Every job with a required name there is measured from the pytest, Jest, Vitest,
# and Playwright summaries in its full log; executed counts passed plus failed
# tests, with Playwright flaky tests counted as passed.
# The checker prints nothing and exits zero when every required job has a
# positive executed count with zero skipped, deselected, errored, and interrupted
# tests. It prints only violations: absent jobs, unreadable logs, unmeasured
# logs, collection errors, interrupted tests, or nonzero skipped/deselected counts.
#
# An unavailable GitHub read is deliberately non-fatal outside CI, where a
# contributor may lack the services or credentials required to inspect a run.
# The same condition fails closed when GITHUB_ACTIONS=true or CI=true, so configuration
# drift cannot turn a required measurement into a green skip.
set -u

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

ci_mode() {
  [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]
}

TARGET_KIND=
TARGET=
REQUIRED_JOBS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr|--run)
      [ -z "$TARGET_KIND" ] || die 'choose exactly one of --pr or --run'
      [ "$#" -ge 2 ] || die "$1 requires a URL"
      TARGET_KIND=${1#--}
      TARGET=$2
      shift 2
      ;;
    --required-job)
      [ "$#" -ge 2 ] || die '--required-job requires a job name'
      REQUIRED_JOBS+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$TARGET_KIND" ] || die 'choose --pr or --run'
[ "${#REQUIRED_JOBS[@]}" -gt 0 ] || die 'name at least one --required-job'
command -v gh-axi >/dev/null 2>&1 || {
  if ci_mode; then
    printf 'unverified: GitHub Actions evidence could not be read because gh-axi is unavailable\n' >&2
    exit 1
  fi
  printf 'not checked: GitHub Actions evidence could not be read because gh-axi is unavailable\n' >&2
  exit 0
}

OWNER=
REPO=
PR_NUMBER=
RUN_ID=
if [ "$TARGET_KIND" = pr ]; then
  if [[ "$TARGET" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)(/)?$ ]]; then
    OWNER=${BASH_REMATCH[1]}
    REPO=${BASH_REMATCH[2]}
    PR_NUMBER=${BASH_REMATCH[3]}
  else
    die 'invalid GitHub pull request URL'
  fi
else
  if [[ "$TARGET" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/actions/runs/([0-9]+)(/)?$ ]]; then
    OWNER=${BASH_REMATCH[1]}
    REPO=${BASH_REMATCH[2]}
    RUN_ID=${BASH_REMATCH[3]}
  else
    die 'invalid GitHub Actions run URL'
  fi
fi

api_rows() {  # <row-kind> <path> <jq-expression emitting "<row-kind>\t..." rows>
  local output
  output=$(gh-axi api "$2" --paginate --full --jq "$3") || return 1
  python3 -c '
import json
import sys
lines = sys.stdin.read().splitlines()
if not lines or lines[0] != "api_response:":
    raise SystemExit(1)
for line in lines[1:]:
    if line.startswith("  body: "):
        value = line[len("  body: "):]
        body = json.loads(value) if value.startswith("\"") else value
        break
else:
    raise SystemExit(1)
for row in body.splitlines():
    kind, tab, fields = row.partition("\t")
    if kind != sys.argv[1] or not tab:
        raise SystemExit(1)
    print(fields)
' "$1" <<< "$output"
}

log_counts() {  # <gh-axi run view --log output file>
  python3 - "$1" <<'PY'
import json
import re
import sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
if not lines or lines[0] != "run_log:":
    raise SystemExit(1)
fields = {}
for line in lines[1:]:
    if not line.startswith("  "):
        break
    key, _, value = line[2:].partition(": ")
    fields[key] = json.loads(value) if value.startswith("\"") else value
if "output" not in fields:
    raise SystemExit(1)
if fields.get("truncated") == "true":
    text = open(fields["full_log"], encoding="utf-8", errors="replace").read()
else:
    text = fields["output"]
labels = {"passed": "passed", "flaky": "passed", "failed": "failed", "skipped": "skipped", "todo": "skipped", "did not run": "skipped", "deselected": "deselected", "error": "errors", "errors": "errors", "interrupted": "interrupted"}
summaries = (
    re.compile(r"((?:\d+ [a-z]+, )*\d+ [a-z]+) in \d+(?:\.\d+)?s\b"),
    re.compile(r"^Tests:\s+((?:\d+ [a-z]+, )*\d+ [a-z]+), \d+ total\s*$"),
    re.compile(r"^\s*Tests\s+((?:\d+ [a-z]+ \| )*\d+ [a-z]+) \(\d+\)\s*$"),
    re.compile(r"^\s+(\d+ (?:passed|failed|flaky|skipped|did not run|interrupted))(?: \([^)]*\))?\s*$"),
    re.compile(r"^\s*Errors\s+(\d+ errors?)\s*$"),
)
totals = dict.fromkeys(("passed", "failed", "skipped", "deselected", "errors", "interrupted"), 0)
measured = False
jest_failure_recap = False
for line in text.splitlines():
    entry = re.match(r"[^\t]*\t[^\t]*\t﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ?(.*)", line)
    if not entry:
        continue
    content = re.sub(r"(?:\x1b|\^\[)\[[0-9;]*m", "", entry.group(1))
    if content.startswith("Summary of all failing tests"):
        jest_failure_recap = True
    elif content.startswith("Test Suites:"):
        jest_failure_recap = False
    failed_suites = re.match(r"\s*⎯+ Failed Suites (\d+) ⎯+\s*$", content)
    if failed_suites or (re.match(r"\s*● Test suite failed to run\s*$", content) and not jest_failure_recap):
        measured = True
        totals["errors"] += int(failed_suites.group(1)) if failed_suites else 1
        continue
    summary = next(filter(None, (pattern.search(content) for pattern in summaries)), None)
    if not summary:
        continue
    counts = [(int(number), labels[label]) for number, label in re.findall(r"(\d+) (did not run|[a-z]+)", summary.group(1)) if label in labels]
    if not counts:
        continue
    measured = True
    for number, label in counts:
        totals[label] += number
if measured:
    print(totals["passed"] + totals["failed"], totals["skipped"], totals["deselected"], totals["errors"], totals["interrupted"])
PY
}

unreadable() {
  local detail=$1
  if ci_mode; then
    printf 'unverified: %s\n' "$detail" >&2
    return 1
  fi
  printf 'not checked: %s\n' "$detail" >&2
  return 0
}

stop_unreadable() {
  unreadable "$1" || exit 1
  exit 0
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-ci-test-evidence.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

RUNS_FILE="$TMP/runs"
if [ "$TARGET_KIND" = pr ]; then
  if ! HEAD_SHA=$(api_rows head "/repos/$OWNER/$REPO/pulls/$PR_NUMBER" '"head\t" + (.head.sha // "")' 2>/dev/null); then
    stop_unreadable "pull request $TARGET could not be read"
  fi
  [ -n "$HEAD_SHA" ] || {
    stop_unreadable "pull request $TARGET did not provide a head commit"
  }
  if ! api_rows run "/repos/$OWNER/$REPO/actions/runs?event=pull_request&head_sha=$HEAD_SHA&per_page=100" \
    '.workflow_runs[] | "run\t\(.id)"' > "$RUNS_FILE" 2>/dev/null; then
    stop_unreadable "Actions runs for pull request $TARGET could not be read"
  fi
else
  printf '%s\n' "$RUN_ID" > "$RUNS_FILE"
fi

: > "$TMP/jobs"
while IFS= read -r run; do
  [ -n "$run" ] || continue
  if ! api_rows job "/repos/$OWNER/$REPO/actions/runs/$run/jobs?per_page=100" \
    '.jobs[] | ["job", .created_at, .run_id, .id, .name, (.conclusion // "")] | @tsv' >> "$TMP/jobs" 2>/dev/null; then
    stop_unreadable "Actions jobs for run $run could not be read"
  fi
done < "$RUNS_FILE"

violations=0
for required in "${REQUIRED_JOBS[@]}"; do
  awk -F '\t' -v name="$required" '
    NR == FNR { if ($4 == name) { if ($1 > newest[$2]) newest[$2] = $1; if ($1 > latest) latest = $1 } next }
    $4 == name && newest[$2] == latest { print $2 "\t" $3 "\t" $4 "\t" $5 }
  ' "$TMP/jobs" "$TMP/jobs" > "$TMP/matches"
  if [ ! -s "$TMP/matches" ]; then
    printf 'absent: required job %s was not present in %s\n' "$required" "$TARGET" >&2
    violations=1
    continue
  fi
  while IFS=$'\t' read -r job_run job_id _ job_conclusion <&3; do
    if [ "$job_conclusion" = skipped ]; then
      printf 'test evidence violation: %s executed=0 skipped=unknown deselected=unknown (job skipped before producing a test log)\n' "$required" >&2
      violations=1
      continue
    fi
    if ! TMPDIR="$TMP" gh-axi run view "$job_run" --job "$job_id" --log -R "$OWNER/$REPO" > "$TMP/log-$job_id" 2>/dev/null ||
      ! counts=$(log_counts "$TMP/log-$job_id" 2>/dev/null); then
      unreadable "required job $required log could not be read" || violations=1
      continue
    fi
    if [ -z "$counts" ]; then
      printf 'not measured: required job %s log contained no pytest, Jest, Vitest, or Playwright test summary\n' "$required" >&2
      violations=1
      continue
    fi
    read -r executed skipped deselected errors interrupted <<EOF
$counts
EOF
    if [ "$errors" -ne 0 ]; then
      printf 'test evidence violation: %s errors=%s (collection errors are not executed tests)\n' "$required" "$errors" >&2
      violations=1
    fi
    if [ "$interrupted" -ne 0 ]; then
      printf 'test evidence violation: %s interrupted=%s (interrupted tests did not finish)\n' "$required" "$interrupted" >&2
      violations=1
    fi
    if [ "$executed" -eq 0 ] || [ "$skipped" -ne 0 ] || [ "$deselected" -ne 0 ]; then
      printf 'test evidence violation: %s executed=%s skipped=%s deselected=%s\n' "$required" "$executed" "$skipped" "$deselected" >&2
      violations=1
    fi
  done 3< "$TMP/matches"
done

exit "$violations"
