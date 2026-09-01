#!/usr/bin/env bash
# Wait a bounded number of times for terminal successful GitHub checks on one
# exact pull-request head SHA.
#
# Required contexts and provider identities combine classic branch protection
# with every effective repository or organization ruleset for the PR base.
# Check runs and commit statuses are read directly for the expected SHA, while
# the PR head, base, and combined requirement set are confirmed around each snapshot.
# Missing, pending, skipped, failed, ambiguous, stale, or different-head
# results are never green, regardless of a CLI's exit status.
# Usage: fm-pr-ci.sh <full-pr-url> <exact-head-sha> [--attempts <1-60>] [--interval <0-60>]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  echo "usage: fm-pr-ci.sh <full-pr-url> <exact-head-sha> [--attempts <1-60>] [--interval <0-60>]" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
RAW_URL=$1
EXPECTED_HEAD=$2
shift 2
ATTEMPTS=30
INTERVAL=10
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attempts) [ "$#" -ge 2 ] || usage; ATTEMPTS=$2; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || usage; INTERVAL=$2; shift 2 ;;
    *) usage ;;
  esac
done

fm_pr_url_parse "$RAW_URL" && [ "$FM_PR_PROVIDER" = github ] || usage
URL=$FM_PR_URL
OWNER=$FM_PR_OWNER
REPO=$FM_PR_REPO
fm_pr_head_valid "$EXPECTED_HEAD" || usage
case "$ATTEMPTS" in ''|*[!0-9]*) usage ;; esac
case "$INTERVAL" in ''|*[!0-9]*) usage ;; esac
[ "$ATTEMPTS" -ge 1 ] && [ "$ATTEMPTS" -le 60 ] || usage
[ "$INTERVAL" -le 60 ] || usage
command -v gh >/dev/null 2>&1 || {
  echo "error: exact-head verification requires gh on PATH" >&2
  exit 1
}

read_head() {
  gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null
}

read_base() {
  gh pr view "$URL" --json baseRefName -q .baseRefName 2>/dev/null
}

base_valid() {
  local base=${1-}
  [ -n "$base" ] && [ "${#base}" -le 255 ] || return 1
  case "$base" in *$'\n'*|*$'\r'*) return 1 ;; esac
}

read_classic_required_checks() {
  local base_path response status=0
  base_path=$(fm_pr_urlencode_path_segment "$1") || return 1
  # shellcheck disable=SC2016
  response=$(gh api -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "repos/$OWNER/$REPO/branches/$base_path/protection" \
    --jq '
      if type != "object" or
         (has("required_status_checks") | not) or
         (.required_status_checks != null and
          ((.required_status_checks | type) != "object" or
           (.required_status_checks.checks | type) != "array" or
           (.required_status_checks.contexts | type) != "array"))
      then error("required status checks are unavailable")
      elif .required_status_checks == null then empty
      else
        .required_status_checks as $required |
        (($required.checks | map(.context)) // []) as $bound_contexts |
        (($required.checks | map({context: .context, app_id: (.app_id // -1)})) +
         ($required.contexts |
          map(select(. as $context | ($bound_contexts | index($context) | not)) |
              {context: ., app_id: -1})))[] |
        ["require", "required", "none", .context, "none", "none",
         (if .app_id == -1 then "any" else (.app_id | tostring) end), "none"] |
        @tsv
      end
    ' 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s\n' "$response"
    return 0
  fi
  [ "$response" = 'gh: Branch not protected (HTTP 404)' ]
}

read_ruleset_required_checks() {
  local base_path
  base_path=$(fm_pr_urlencode_path_segment "$1") || return 1
  # shellcheck disable=SC2016
  gh api --paginate -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "repos/$OWNER/$REPO/rules/branches/$base_path?per_page=100" \
    --jq '
      if type != "array" then error("effective branch rules are unavailable")
      else
        .[] |
        if (.type | type) != "string" then error("effective branch rule type is unavailable")
        elif .type != "required_status_checks" then empty
        elif (.parameters | type) != "object" or
             (.parameters.required_status_checks | type) != "array"
        then error("required ruleset status checks are unavailable")
        else
          .parameters.required_status_checks[] |
          if (.context | type) != "string" or .context == "" then
            error("ruleset status check context is unavailable")
          elif .integration_id == null then
            {context: .context, provider: "any"}
          elif (.integration_id | type) == "number" and
               .integration_id > 0 and .integration_id == (.integration_id | floor) then
            {context: .context, provider: (.integration_id | tostring)}
          else
            error("ruleset status check provider is unavailable")
          end |
          ["require", "required", "none", .context, "none", "none", .provider, "none"] |
          @tsv
        end
      end
    ' 2>/dev/null
}

combine_required_checks() {
  awk -F '\t' '
    NF == 0 { next }
    NF != 8 {
      print
      next
    }
    {
      name = $4
      provider = $7
      if (!(name in seen)) {
        seen[name] = 1
        selected[name] = provider
        next
      }
      if (selected[name] == provider) next
      if (selected[name] == "any") {
        selected[name] = provider
        next
      }
      if (provider == "any") next
      conflicts[name SUBSEP provider] = 1
    }
    END {
      for (name in seen) {
        printf "require\trequired\tnone\t%s\tnone\tnone\t%s\tnone\n", name, selected[name]
      }
      for (item in conflicts) {
        split(item, parts, SUBSEP)
        printf "require\trequired\tnone\t%s\tnone\tnone\t%s\tnone\n", parts[1], parts[2]
      }
    }
  '
}

read_required_checks() {
  local classic rules
  classic=$(read_classic_required_checks "$1") || return 1
  rules=$(read_ruleset_required_checks "$1") || return 1
  printf '%s\n%s\n' "$classic" "$rules" | combine_required_checks | LC_ALL=C sort
}

read_check_runs() {
  # shellcheck disable=SC2016
  gh api --paginate -H 'Accept: application/vnd.github+json' \
    "repos/$OWNER/$REPO/commits/$EXPECTED_HEAD/check-runs?filter=latest&per_page=100" \
    --jq '.check_runs[] | ["result", "check", .head_sha, .name, .status, (.conclusion // "none"), ((.app.id // -1) | tostring), (.app.slug // "none")] | @tsv' 2>/dev/null
}

read_commit_statuses() {
  # shellcheck disable=SC2016
  gh api --paginate -H 'Accept: application/vnd.github+json' \
    "repos/$OWNER/$REPO/commits/$EXPECTED_HEAD/status?per_page=100" \
    --jq '[{head: .sha, item: .statuses[]}][] | ["result", "status", .head, .item.context, "completed", .item.state, "none", "none"] | @tsv' 2>/dev/null
}

validate_exact_head_evidence() {
  awk -F '\t' -v expected="$EXPECTED_HEAD" '
    function reject(reason) {
      if (problem == "") problem = reason
    }
    NF == 0 { next }
    NF != 8 {
      reject("malformed exact-head requirement or result evidence")
      next
    }
    $1 == "require" {
      if ($2 != "required" || $3 != "none" || $4 == "" ||
          $5 != "none" || $6 != "none" || $8 != "none") {
        reject("malformed required-check evidence")
        next
      }
      name = $4
      provider = $7
      if (provider != "any" && provider !~ /^[1-9][0-9]*$/) {
        reject("malformed required-check provider for " name)
      }
      if (++required_seen[name] > 1) {
        reject("ambiguous required-check evidence for " name)
      }
      required_provider[name] = provider
      required_total++
      if (name == "Verify exact PR head") canonical_required++
      next
    }
    $1 == "result" {
      kind = $2
      sha = $3
      name = $4
      status = $5
      conclusion = $6
      app_id = $7
      app_slug = $8
      if (kind != "check" && kind != "status") reject("unknown exact-head result type")
      if (sha != expected) reject("different-head check evidence for " name)
      if (name == "") reject("unnamed exact-head check evidence")
      if (++result_seen[name] > 1) reject("ambiguous exact-head check evidence for " name)
      if (kind == "check") {
        if (app_id !~ /^[1-9][0-9]*$/ || app_slug == "" || app_slug == "none") {
          reject("malformed check-run provider for " name)
        }
      } else if (app_id != "none" || app_slug != "none") {
        reject("malformed commit-status provider for " name)
      }
      result_kind[name] = kind
      result_app_id[name] = app_id
      result_app_slug[name] = app_slug
      if (status != "completed" || conclusion != "success") {
        if (name == "Verify exact PR head") {
          reject("canonical Verify exact PR head check is not terminal-successful")
        } else {
          reject("check is not terminal-successful: " name)
        }
      }
      result_total++
      next
    }
    { reject("unknown exact-head evidence record") }
    END {
      if (required_total == 0) reject("no effective required checks were found for the PR base branch")
      if (canonical_required == 0) reject("canonical Verify exact PR head requirement is missing")
      if (canonical_required > 1) reject("canonical Verify exact PR head requirement is ambiguous")
      if (result_total == 0) reject("no exact-head checks or statuses were found")
      for (name in required_seen) {
        if (!(name in result_seen)) {
          if (name == "Verify exact PR head") {
            reject("canonical Verify exact PR head check is missing")
          } else {
            reject("required check is missing: " name)
          }
          continue
        }
        provider = required_provider[name]
        if (provider != "any" &&
            (result_kind[name] != "check" || result_app_id[name] != provider)) {
          reject("required check provider mismatch: " name)
        }
      }
      canonical = "Verify exact PR head"
      if (canonical in result_seen) {
        if (result_kind[canonical] != "check" ||
            result_app_id[canonical] !~ /^[1-9][0-9]*$/ ||
            result_app_slug[canonical] != "github-actions") {
          reject("canonical Verify exact PR head result is not an authorized GitHub Actions check run")
        }
      }
      if (problem != "") {
        print "not-green: " problem
        exit 1
      }
      print "green: " result_total
    }
  '
}

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  head_before=$(read_head) || head_before=
  base_before=$(read_base) || base_before=
  if ! fm_pr_head_valid "$head_before"; then
    echo "not-green: attempt=$attempt/$ATTEMPTS could not read a valid PR head" >&2
  elif [ "$head_before" != "$EXPECTED_HEAD" ]; then
    echo "error: PR $URL is at head $head_before; expected head $EXPECTED_HEAD" >&2
    exit 1
  elif ! base_valid "$base_before"; then
    echo "not-green: attempt=$attempt/$ATTEMPTS could not read a valid PR base branch" >&2
  else
    requirements_before_status=0
    requirements_before=$(read_required_checks "$base_before") || requirements_before_status=$?
    check_runs_status=0
    check_runs=$(read_check_runs) || check_runs_status=$?
    statuses_status=0
    statuses=$(read_commit_statuses) || statuses_status=$?
    requirements_after_status=0
    requirements_after=$(read_required_checks "$base_before") || requirements_after_status=$?
    base_after=$(read_base) || base_after=
    head_after=$(read_head) || head_after=
    if [ "$head_after" != "$EXPECTED_HEAD" ]; then
      echo "error: PR $URL changed head while checks were read; expected head $EXPECTED_HEAD, observed ${head_after:-unknown}" >&2
      exit 1
    elif [ "$base_after" != "$base_before" ]; then
      echo "error: PR $URL changed base while checks were read; expected base $base_before, observed ${base_after:-unknown}" >&2
      exit 1
    elif [ "$requirements_before_status" -ne 0 ] || [ "$requirements_after_status" -ne 0 ]; then
      echo "not-green: attempt=$attempt/$ATTEMPTS required checks are unavailable for base branch $base_before" >&2
    elif [ "$(printf '%s\n' "$requirements_before" | LC_ALL=C sort)" != "$(printf '%s\n' "$requirements_after" | LC_ALL=C sort)" ]; then
      echo "not-green: attempt=$attempt/$ATTEMPTS required checks changed while exact-head evidence was read" >&2
    elif [ "$check_runs_status" -ne 0 ] || [ "$statuses_status" -ne 0 ]; then
      echo "not-green: attempt=$attempt/$ATTEMPTS exact-head check evidence is unavailable for head $EXPECTED_HEAD" >&2
    else
      evidence_status=0
      evidence_result=$(printf '%s\n%s\n%s\n' "$requirements_after" "$check_runs" "$statuses" \
        | validate_exact_head_evidence) || evidence_status=$?
      if [ "$evidence_status" -eq 0 ]; then
        total=${evidence_result#green: }
        echo "green: $URL head=$EXPECTED_HEAD checks=$total"
        exit 0
      fi
      echo "not-green: attempt=$attempt/$ATTEMPTS head=$EXPECTED_HEAD ${evidence_result#not-green: }" >&2
    fi
  fi
  [ "$attempt" -ge "$ATTEMPTS" ] || [ "$INTERVAL" -eq 0 ] || sleep "$INTERVAL"
  attempt=$((attempt + 1))
done

echo "error: PR $URL did not reach exact-head green within $ATTEMPTS attempt(s)" >&2
exit 1
