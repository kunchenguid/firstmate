#!/usr/bin/env bash
# Preserve no-mistakes' `gh pr checks` contract when GitHub forbids the
# check-runs read but still permits workflow-runs reads.
#
# Usage: fm-gh-ci-fallback.sh <real-gh> pr checks <pr-number-or-url> --repo <owner/repo> --json <fields>
#        fm-gh-ci-fallback.sh --supports pr checks <pr-number-or-url> --repo <owner/repo> --json <fields>
#
# Token routing is deliberately least-privilege. The original check-runs call,
# the pull-request head lookup, and the exact-head workflow-runs lookup all use
# the caller's ambient GH_TOKEN/GITHUB_TOKEN unchanged. This script never calls
# fm-gh.sh, never injects config/gh-credential's broader PR-capable credential,
# and never prints a token. It falls back only after the original command reports
# the GraphQL personal-token denial whose error path names a `statusCheckRollup`
# component, at whatever depth GitHub currently reports it; every other result,
# including a denial for any other API, is replayed unchanged.
#
# The fallback is intentionally limited to the two literal argument vectors used
# by the supported no-mistakes CI monitor: a selector, `--repo owner/repository`,
# and `--json name,state,bucket,completedAt` with or without the final `link` field.
# Other `gh pr checks` invocations keep the real gh result, so installing the
# PATH-wide shim does not silently change an interactive command's output format.
#
# A fallback verdict is tied to the PR's exact current head SHA. The PR number
# and owner/repository are strictly validated, the head is read from
# repos/<owner>/<repo>/pulls/<number>, and Actions is queried through both the
# paginated active-workflow inventory,
# repos/<owner>/<repo>/actions/runs?head_sha=<exact-sha>, and each relevant run's
# paginated Actions jobs. No branch name or local HEAD can certify green. A run
# counts only when its PR trigger, repository, head SHA, and pull-request
# association all match, and every active workflow must have one unambiguous
# latest run. The
# highest attempt of one run supersedes its older attempts. A completed
# successful workflow still requires every job in that attempt to complete
# successfully, so an unexpectedly skipped job cannot hide behind workflow-level
# success. Missing, unrelated, stale, or ambiguous evidence can never certify
# green. Pagination deliberately avoids `--slurp`, which GitHub CLI rejects
# whenever `--jq` or `--template` is present; each page is reduced to one JSON
# object per line before a bounded normalizer combines the pages.
#
# Pending or initially missing evidence is bounded across polls by
# FM_GH_CI_MAX_PENDING_SECONDS (default 3600). The first observation is stored
# under FM_GH_CI_STATE_ROOT (default
# $XDG_STATE_HOME/firstmate/gh-ci-fallback, falling back to
# $HOME/.local/state/firstmate/gh-ci-fallback). FM_GH_CI_NOW_EPOCH exists only
# for deterministic boundary tests. FM_GH_CI_ACTIONS_ONLY_REPOS is a
# comma-separated allowlist of exact owner/repository names whose merge gates
# are explicitly known to contain GitHub Actions checks only. A deadline,
# malformed evidence, API
# failure, or head drift becomes a typed synthetic failed check instead of an
# unreadable command failure that no-mistakes can warn about indefinitely. The
# state resets when the head changes or a terminal verdict is reached.
#
# The PR head is read again after pagination and any drift refuses the fallback
# result, so a verdict can never describe a head that is no longer current.
# This evidence covers GitHub Actions only; without exact repository membership
# in FM_GH_CI_ACTIONS_ONLY_REPOS, an otherwise green Actions result fails closed
# because it cannot reconstruct third-party providers hidden behind check-runs.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

fallback_shape_parse() {
  [ "$#" -eq 7 ] || return 1
  [ "${1:-}" = pr ] && [ "${2:-}" = checks ] || return 1
  [ "${4:-}" = --repo ] && [ "${6:-}" = --json ] || return 1
  SELECTOR=${3:-}
  REPO=${5:-}
  JSON_FIELDS=${7:-}

  case "$JSON_FIELDS" in
    name,state,bucket,completedAt|name,state,bucket,completedAt,link) ;;
    *) return 1 ;;
  esac

  case "$SELECTOR" in
    https://github.com/*)
      fm_pr_url_parse "$SELECTOR" || return 1
      [ "$FM_PR_PROVIDER" = github ] || return 1
      [ "$REPO" = "$FM_PR_PATH" ] || return 1
      REPO=$FM_PR_PATH
      NUMBER=$FM_PR_NUMBER
      ;;
    *)
      case "$SELECTOR" in
        ''|0|*[!0-9]*) return 1 ;;
      esac
      fm_pr_url_parse "https://github.com/$REPO/pull/$SELECTOR" || return 1
      [ "$FM_PR_PROVIDER" = github ] || return 1
      REPO=$FM_PR_PATH
      NUMBER=$FM_PR_NUMBER
      ;;
  esac
}

if [ "${1:-}" = --supports ]; then
  shift
  fallback_shape_parse "$@"
  exit $?
fi

[ "$#" -ge 5 ] || {
  echo "fm-gh-ci-fallback: invalid invocation" >&2
  exit 2
}
REAL_GH=$1
shift

ORIGINAL_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-original-out.XXXXXX")
ORIGINAL_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-original-err.XXXXXX")
FALLBACK_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-fallback-out.XXXXXX")
FALLBACK_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-fallback-err.XXXXXX")
WORKFLOWS_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-workflows-out.XXXXXX")
WORKFLOWS_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-workflows-err.XXXXXX")
JOBS_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-jobs-out.XXXXXX")
JOBS_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-jobs-err.XXXXXX")
RUN_IDS=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-run-ids.XXXXXX")
HEAD_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-head-err.XXXXXX")
NORMALIZER_OUT=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-normalizer-out.XXXXXX")
NORMALIZER_ERR=$(mktemp "${TMPDIR:-/tmp}/fm-gh-ci-normalizer-err.XXXXXX")
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  rm -f -- "$ORIGINAL_OUT" "$ORIGINAL_ERR" "$FALLBACK_OUT" "$FALLBACK_ERR" \
    "$WORKFLOWS_OUT" "$WORKFLOWS_ERR" "$JOBS_OUT" "$JOBS_ERR" "$RUN_IDS" \
    "$HEAD_ERR" "$NORMALIZER_OUT" "$NORMALIZER_ERR"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

ORIGINAL_STATUS=0
"$REAL_GH" "$@" > "$ORIGINAL_OUT" 2> "$ORIGINAL_ERR" || ORIGINAL_STATUS=$?
if [ "$ORIGINAL_STATUS" -eq 0 ]; then
  cat "$ORIGINAL_OUT"
  cat "$ORIGINAL_ERR" >&2
  exit 0
fi

replay_original() {
  cat "$ORIGINAL_OUT"
  cat "$ORIGINAL_ERR" >&2
  exit "$ORIGINAL_STATUS"
}

# Requiring GitHub's exact denial sentence together with a whole
# `statusCheckRollup` component inside its GraphQL error path keeps a changed gh
# failure from being reinterpreted as CI state, while tolerating the deeper
# property paths GitHub appends to that same denial as its check-runs selection
# set evolves. A component match is deliberate: a path that merely starts with
# those characters, and any denial for another API, still replays unchanged.
DENIAL_PATTERN='GraphQL: Resource not accessible by personal access token \(([A-Za-z0-9_]+\.)*statusCheckRollup(\.[A-Za-z0-9_]+)*\)'
if ! grep -Eq "$DENIAL_PATTERN" "$ORIGINAL_OUT" "$ORIGINAL_ERR"; then
  replay_original
fi

fallback_shape_parse "$@" || replay_original

emit_typed_failure() {
  local label=$1 state=$2
  if [ "$JSON_FIELDS" = name,state,bucket,completedAt,link ]; then
    printf '[{"name":"Firstmate CI fallback - %s","state":"%s","bucket":"fail","completedAt":"","link":""}]\n' \
      "$label" "$state"
  else
    printf '[{"name":"Firstmate CI fallback - %s","state":"%s","bucket":"fail","completedAt":""}]\n' \
      "$label" "$state"
  fi
}

if [ -n "${FM_GH_CI_STATE_ROOT:-}" ]; then
  STATE_ROOT=$FM_GH_CI_STATE_ROOT
elif [ -n "${XDG_STATE_HOME:-}" ]; then
  STATE_ROOT="$XDG_STATE_HOME/firstmate/gh-ci-fallback"
elif [ -n "${HOME:-}" ]; then
  STATE_ROOT="$HOME/.local/state/firstmate/gh-ci-fallback"
else
  echo "fm-gh-ci-fallback: configuration-error: no deadline state root is available" >&2
  emit_typed_failure "configuration error" configuration_error
  exit 0
fi
SAFE_REPO=${REPO//[^A-Za-z0-9_.-]/_}
STATE_PATH="$STATE_ROOT/${SAFE_REPO}-pr-${NUMBER}.json"

finish_terminal() {
  local label=$1 state=$2
  if ! rm -f -- "$STATE_PATH"; then
    echo "fm-gh-ci-fallback: state-error: cannot clear terminal deadline state" >&2
    label="state evidence"
    state=state_error
  fi
  emit_typed_failure "$label" "$state"
  exit 0
}

if ! command -v python3 >/dev/null 2>&1 || ! python3 -c '' >/dev/null 2>&1; then
  echo "fm-gh-ci-fallback: dependency-error: python3 is unavailable" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "dependency error" dependency_error
fi

read_exact_pr_head() {
  local error_path=$1 head
  : > "$error_path"
  head=$("$REAL_GH" api -X GET "repos/$REPO/pulls/$NUMBER" --jq .head.sha 2> "$error_path") || return 1
  head=${head//$'\r'/}
  head=${head//$'\n'/}
  fm_pr_head_valid "$head" || return 1
  printf '%s\n' "$head"
}

PR_HEAD=
if ! PR_HEAD=$(read_exact_pr_head "$HEAD_ERR"); then
  echo "fm-gh-ci-fallback: api-error: exact PR head lookup failed" >&2
  cat "$HEAD_ERR" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "API error" api_error
fi

# gh's built-in jq evaluator applies these expressions to each Actions response
# page on its own, because `--paginate` may not be combined with `--slurp` while
# `--jq` is present. The Python normalizer below validates and combines the JSONL.
# shellcheck disable=SC2016 # This is a literal jq program; its $ names belong to jq.
WORKFLOWS_JQ='.workflows[]
  | {id, name, path, state}'

# shellcheck disable=SC2016 # This is a literal jq program; its $ names belong to jq.
RUNS_JQ='.workflow_runs[]
  | {
      id,
      workflow_id,
      run_number,
      run_attempt,
      name,
      event,
      head_sha,
      status,
      conclusion,
      created_at,
      updated_at,
      html_url,
      repository: {full_name: .repository.full_name},
      pull_requests: [.pull_requests[]? | {number, head: {sha: .head.sha}}]
    }'

# shellcheck disable=SC2016 # This is a literal jq program; its $ names belong to jq.
JOBS_JQ='.jobs[]
  | {
      id,
      run_id,
      run_attempt,
      name,
      head_sha,
      status,
      conclusion,
      started_at,
      completed_at,
      html_url
    }'

WORKFLOWS_ENDPOINT="repos/$REPO/actions/workflows?per_page=100"
WORKFLOWS_STATUS=0
"$REAL_GH" api -X GET "$WORKFLOWS_ENDPOINT" --paginate --jq "$WORKFLOWS_JQ" \
  > "$WORKFLOWS_OUT" 2> "$WORKFLOWS_ERR" || WORKFLOWS_STATUS=$?
if [ "$WORKFLOWS_STATUS" -ne 0 ]; then
  echo "fm-gh-ci-fallback: api-error: active workflow inventory lookup failed" >&2
  cat "$WORKFLOWS_ERR" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "API error" api_error
fi

RUNS_ENDPOINT="repos/$REPO/actions/runs?head_sha=$PR_HEAD&per_page=100"
RUNS_STATUS=0
"$REAL_GH" api -X GET "$RUNS_ENDPOINT" --paginate --jq "$RUNS_JQ" \
  > "$FALLBACK_OUT" 2> "$FALLBACK_ERR" || RUNS_STATUS=$?
if [ "$RUNS_STATUS" -ne 0 ]; then
  echo "fm-gh-ci-fallback: api-error: exact-head workflow-runs lookup failed" >&2
  cat "$FALLBACK_ERR" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "API error" api_error
fi

RUN_ID_STATUS=0
python3 - "$FALLBACK_OUT" > "$RUN_IDS" 2> "$NORMALIZER_ERR" <<'PY' || RUN_ID_STATUS=$?
import json
import sys

seen = set()
with open(sys.argv[1], encoding="utf-8") as stream:
    for raw in stream:
        try:
            value = json.loads(raw)
        except json.JSONDecodeError:
            continue
        run_id = value.get("id") if isinstance(value, dict) else None
        if isinstance(run_id, int) and not isinstance(run_id, bool) and run_id > 0 and run_id not in seen:
            seen.add(run_id)
            print(run_id)
PY
if [ "$RUN_ID_STATUS" -ne 0 ]; then
  echo "fm-gh-ci-fallback: dependency-error: python3 run-id extraction failed" >&2
  cat "$NORMALIZER_ERR" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "dependency error" dependency_error
fi

JOBS_STATUS=0
while IFS= read -r RUN_ID; do
  [ -n "$RUN_ID" ] || continue
  if "$REAL_GH" api -X GET \
    "repos/$REPO/actions/runs/$RUN_ID/jobs?filter=all&per_page=100" \
    --paginate --jq "$JOBS_JQ" >> "$JOBS_OUT" 2>> "$JOBS_ERR"; then
    :
  else
    JOBS_STATUS=$?
    break
  fi
done < "$RUN_IDS"
if [ "$JOBS_STATUS" -ne 0 ]; then
  echo "fm-gh-ci-fallback: api-error: workflow jobs lookup failed" >&2
  cat "$JOBS_ERR" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "API error" api_error
fi

PR_HEAD_AFTER=
if ! PR_HEAD_AFTER=$(read_exact_pr_head "$HEAD_ERR"); then
  echo "fm-gh-ci-fallback: api-error: exact PR head recheck failed" >&2
  cat "$HEAD_ERR" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "API error" api_error
fi
if [ "$PR_HEAD_AFTER" != "$PR_HEAD" ]; then
  echo "fm-gh-ci-fallback: head-drift: PR head changed during workflow-runs lookup" >&2
  finish_terminal "head changed" head_drift
fi

MAX_PENDING_SECONDS=${FM_GH_CI_MAX_PENDING_SECONDS:-3600}
if [ -n "${FM_GH_CI_NOW_EPOCH:-}" ]; then
  NOW_EPOCH=$FM_GH_CI_NOW_EPOCH
elif command -v date >/dev/null 2>&1 && NOW_EPOCH=$(date +%s); then
  :
else
  echo "fm-gh-ci-fallback: dependency-error: date is unavailable" >&2
  finish_terminal "dependency error" dependency_error
fi
case "$MAX_PENDING_SECONDS" in
  '' | *[!0-9]*)
    echo "fm-gh-ci-fallback: invalid pending deadline configuration" >&2
    finish_terminal "configuration error" configuration_error
    ;;
esac
case "$NOW_EPOCH" in
  '' | *[!0-9]*)
    echo "fm-gh-ci-fallback: invalid pending deadline configuration" >&2
    finish_terminal "configuration error" configuration_error
    ;;
esac

ACTIONS_ONLY_AUTHORIZED=0
case ",${FM_GH_CI_ACTIONS_ONLY_REPOS:-}," in
  *",$REPO,"*) ACTIONS_ONLY_AUTHORIZED=1 ;;
esac

NORMALIZER_STATUS=0
python3 - "$WORKFLOWS_OUT" "$FALLBACK_OUT" "$JOBS_OUT" "$REPO" "$NUMBER" "$PR_HEAD" \
  "$STATE_PATH" "$MAX_PENDING_SECONDS" "$NOW_EPOCH" "$JSON_FIELDS" "$ACTIONS_ONLY_AUTHORIZED" \
  > "$NORMALIZER_OUT" 2> "$NORMALIZER_ERR" <<'PY' || NORMALIZER_STATUS=$?
import json
import os
import sys

workflows_path, runs_path, jobs_path, repo, number_raw, head, state_path, max_raw, now_raw, fields, actions_only_raw = sys.argv[1:]
number = int(number_raw)
max_pending = int(max_raw)
now = int(now_raw)
include_link = fields.endswith(",link")
actions_only_authorized = actions_only_raw == "1"
state_root = os.path.dirname(state_path)


class EvidenceError(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


def read_json_lines(path, label):
    values = []
    with open(path, encoding="utf-8") as stream:
        for line_number, raw in enumerate(stream, 1):
            raw = raw.strip()
            if not raw:
                continue
            try:
                value = json.loads(raw)
            except json.JSONDecodeError as error:
                raise EvidenceError("ambiguous", f"{label} page {line_number} is not valid JSON: {error.msg}") from error
            if not isinstance(value, dict):
                raise EvidenceError("ambiguous", f"{label} page {line_number} is not an object")
            values.append(value)
    return values


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def diagnostic(kind, message, bucket="pending", name=None, state=None):
    state = state or ("timed_out" if bucket == "fail" else f"{kind}_evidence")
    check = {
        "name": f"Firstmate CI fallback - {name or f'{kind} evidence'}",
        "state": state,
        "bucket": bucket,
        "completedAt": "",
    }
    if include_link:
        check["link"] = ""
    return [check], message


def classify(status, conclusion):
    if status != "completed" or conclusion is None:
        return "pending", status or "pending"
    elif conclusion == "success":
        return "pass", conclusion
    elif conclusion in {"failure", "timed_out", "action_required", "startup_failure", "cancelled", "skipped", "neutral", "stale"}:
        return "fail", conclusion
    return "pending", conclusion or "pending"


def map_run(workflow, run):
    status = run["status"]
    bucket, state = classify(status, run.get("conclusion"))
    check = {
        "name": workflow["name"],
        "state": state,
        "bucket": bucket,
        "completedAt": run.get("updated_at", "") if status == "completed" else "",
    }
    if include_link:
        check["link"] = run.get("html_url", "")
    return check


def map_successful_run_jobs(workflow, run, jobs):
    ranked = {"pass": 0, "pending": 1, "fail": 2}
    mapped = []
    for job in jobs:
        bucket, state = classify(job["status"], job.get("conclusion"))
        mapped.append((ranked[bucket], bucket, state, job))
    _, bucket, state, decisive = max(mapped, key=lambda item: item[0])
    check = {
        "name": workflow["name"],
        "state": state,
        "bucket": bucket,
        "completedAt": max((job.get("completed_at") or "") for job in jobs) if bucket != "pending" else "",
    }
    if include_link:
        check["link"] = decisive.get("html_url") or run.get("html_url", "")
    return check


try:
    active = {}
    names = {}
    for workflow in read_json_lines(workflows_path, "workflow inventory"):
        if workflow.get("state") != "active":
            continue
        workflow_id = workflow.get("id")
        name = workflow.get("name")
        path = workflow.get("path")
        if not positive_integer(workflow_id) or not isinstance(name, str) or not name.strip() or not isinstance(path, str) or not path.strip():
            raise EvidenceError("ambiguous", "an active workflow has malformed identity evidence")
        identity = {"id": workflow_id, "name": name.strip(), "path": path}
        if workflow_id in active and active[workflow_id] != identity:
            raise EvidenceError("ambiguous", f"workflow {workflow_id} has conflicting inventory records")
        if identity["name"] in names and names[identity["name"]] != workflow_id:
            raise EvidenceError("ambiguous", f"active workflows share the name {identity['name']!r}")
        active[workflow_id] = identity
        names[identity["name"]] = workflow_id
    if not active:
        raise EvidenceError("missing", "the repository exposes no active workflow inventory")

    grouped = {workflow_id: [] for workflow_id in active}
    for run in read_json_lines(runs_path, "workflow runs"):
        workflow_id = run.get("workflow_id")
        if workflow_id not in active:
            continue
        if run.get("event") not in ("pull_request", "pull_request_target"):
            continue
        if run.get("head_sha") != head:
            continue
        repository = run.get("repository")
        if not isinstance(repository, dict) or repository.get("full_name", "").lower() != repo.lower():
            continue
        associations = run.get("pull_requests")
        if not isinstance(associations, list):
            raise EvidenceError("ambiguous", f"workflow {workflow_id} has malformed pull-request association evidence")
        associated = False
        for association in associations:
            if not isinstance(association, dict) or association.get("number") != number:
                continue
            association_head = association.get("head")
            if isinstance(association_head, dict) and association_head.get("sha") == head:
                associated = True
        if not associated:
            continue
        required = ("id", "run_number", "run_attempt", "status", "created_at")
        if any(key not in run for key in required):
            raise EvidenceError("ambiguous", f"workflow {workflow_id} has incomplete run identity evidence")
        if not all(positive_integer(run[key]) for key in ("id", "run_number", "run_attempt")):
            raise EvidenceError("ambiguous", f"workflow {workflow_id} has malformed run identity evidence")
        if not isinstance(run["status"], str) or not run["status"] or not isinstance(run["created_at"], str) or not run["created_at"]:
            raise EvidenceError("ambiguous", f"workflow {workflow_id} has malformed run state evidence")
        grouped[workflow_id].append(run)

    missing = [active[workflow_id]["name"] for workflow_id, runs in grouped.items() if not runs]
    if missing:
        raise EvidenceError("missing", "no exact PR-head run exists for active workflow(s): " + ", ".join(sorted(missing)))

    selected = {}
    for workflow_id, runs in grouped.items():
        attempts_by_run = {}
        for run in runs:
            attempts_by_run.setdefault(run["id"], []).append(run)
        latest_runs = []
        for run_id, attempts in attempts_by_run.items():
            latest_attempt = max(run["run_attempt"] for run in attempts)
            latest = [run for run in attempts if run["run_attempt"] == latest_attempt]
            canonical = {json.dumps(run, sort_keys=True, separators=(",", ":")) for run in latest}
            if len(canonical) != 1:
                raise EvidenceError("ambiguous", f"workflow {workflow_id} run {run_id} has conflicting latest-attempt evidence")
            latest_runs.append(latest[0])
        newest_key = max((run["run_number"], run["created_at"]) for run in latest_runs)
        newest = [run for run in latest_runs if (run["run_number"], run["created_at"]) == newest_key]
        if len(newest) != 1:
            raise EvidenceError("ambiguous", f"workflow {workflow_id} has multiple equally current runs")
        selected[workflow_id] = newest[0]

    selected_by_run = {run["id"]: (workflow_id, run) for workflow_id, run in selected.items()}
    jobs_by_run = {run_id: [] for run_id in selected_by_run}
    for job in read_json_lines(jobs_path, "workflow jobs"):
        run_id = job.get("run_id")
        if run_id not in selected_by_run:
            continue
        _, run = selected_by_run[run_id]
        if job.get("run_attempt") != run["run_attempt"] or job.get("head_sha") != head:
            continue
        if not positive_integer(job.get("id")) or not isinstance(job.get("name"), str) or not job["name"].strip():
            raise EvidenceError("ambiguous", f"workflow run {run_id} has malformed job identity evidence")
        if not isinstance(job.get("status"), str) or not job["status"]:
            raise EvidenceError("ambiguous", f"workflow run {run_id} has malformed job state evidence")
        jobs_by_run[run_id].append(job)

    checks = []
    for workflow_id in sorted(active):
        workflow = active[workflow_id]
        run = selected[workflow_id]
        run_check = map_run(workflow, run)
        if run_check["bucket"] != "pass":
            checks.append(run_check)
            continue
        jobs = jobs_by_run[run["id"]]
        if not jobs:
            raise EvidenceError("missing", f"successful workflow {workflow['name']!r} has no jobs for its latest attempt")
        unique_jobs = {}
        for job in jobs:
            job_id = job["id"]
            encoded = json.dumps(job, sort_keys=True, separators=(",", ":"))
            if job_id in unique_jobs and unique_jobs[job_id][0] != encoded:
                raise EvidenceError("ambiguous", f"workflow run {run['id']} job {job_id} has conflicting evidence")
            unique_jobs[job_id] = (encoded, job)
        checks.append(map_successful_run_jobs(workflow, run, [item[1] for item in unique_jobs.values()]))

    evidence_kind = "pending" if any(check["bucket"] == "pending" for check in checks) else "terminal"
    reason = "one or more exact PR-head workflow runs or jobs are still pending" if evidence_kind == "pending" else ""
    if all(check["bucket"] == "pass" for check in checks) and not actions_only_authorized:
        evidence_kind = "terminal"
        reason = "no repository-level authority proves that required CI evidence is entirely in GitHub Actions"
        checks, reason = diagnostic(
            "incomplete", reason, bucket="fail", name="incomplete evidence", state="incomplete_evidence"
        )
except EvidenceError as error:
    evidence_kind = error.kind
    checks, reason = diagnostic(error.kind, str(error))
except Exception as error:
    evidence_kind = "terminal"
    reason = f"cannot normalize Actions evidence: {type(error).__name__}: {error}"
    checks, reason = diagnostic(
        "normalizer", reason, bucket="fail", name="normalizer error", state="normalizer_error"
    )
    print(f"fm-gh-ci-fallback: normalizer-error: {reason}", file=sys.stderr)

try:
    if evidence_kind == "terminal":
        try:
            os.unlink(state_path)
        except FileNotFoundError:
            pass
    else:
        os.makedirs(state_root, mode=0o700, exist_ok=True)
        first_seen = now
        try:
            with open(state_path, encoding="utf-8") as stream:
                prior = json.load(stream)
        except FileNotFoundError:
            prior = None
        if prior is not None:
            if not isinstance(prior, dict):
                raise ValueError("saved deadline state is not an object")
            prior_head = prior.get("head")
            prior_first_seen = prior.get("first_seen")
            if not isinstance(prior_head, str) or not isinstance(prior_first_seen, int) or isinstance(prior_first_seen, bool):
                raise ValueError("saved deadline state has invalid field types")
            if prior_head == head and 0 <= prior_first_seen <= now:
                first_seen = prior_first_seen
        if now - first_seen >= max_pending:
            checks, reason = diagnostic(evidence_kind, reason, bucket="fail")
            print(f"fm-gh-ci-fallback: evidence-timeout: {reason}", file=sys.stderr)
            try:
                os.unlink(state_path)
            except FileNotFoundError:
                pass
        else:
            temporary = f"{state_path}.{os.getpid()}.tmp"
            with open(temporary, "w", encoding="utf-8") as stream:
                json.dump({"head": head, "first_seen": first_seen}, stream, separators=(",", ":"))
                stream.write("\n")
            os.replace(temporary, state_path)
except Exception as error:
    reason = f"cannot manage deadline state: {type(error).__name__}: {error}"
    checks, reason = diagnostic("state", reason, bucket="fail")
    print(f"fm-gh-ci-fallback: state-error: {reason}", file=sys.stderr)
    try:
        os.unlink(state_path)
    except FileNotFoundError:
        pass
    except Exception as cleanup_error:
        reason = f"cannot clear terminal deadline state: {type(cleanup_error).__name__}: {cleanup_error}"
        checks, reason = diagnostic("state", reason, bucket="fail")
        print(f"fm-gh-ci-fallback: state-error: {reason}", file=sys.stderr)

print(json.dumps(checks, separators=(",", ":")))
PY
if [ "$NORMALIZER_STATUS" -ne 0 ]; then
  echo "fm-gh-ci-fallback: dependency-error: python3 normalizer failed" >&2
  cat "$NORMALIZER_ERR" >&2
  cat "$ORIGINAL_ERR" >&2
  finish_terminal "dependency error" dependency_error
fi
cat "$NORMALIZER_ERR" >&2
cat "$NORMALIZER_OUT"
exit 0
