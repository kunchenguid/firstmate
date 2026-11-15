#!/usr/bin/env bash
# The merge gate: the one place that decides whether a pull request's review
# verdict and check state authorize a merge. bin/fm-pr-merge.sh calls
# fm_merge_gate before it reaches any forge merge abstraction, and
# bin/fm-go-queue-run.sh merges only through bin/fm-pr-merge.sh, so no merge
# path can skip it.
#
# The gate refuses, naming the exact reason, when any of these hold:
#   - the live head differs from the head the caller expected, or from the head
#     recorded in the task's metadata (a GO on an older commit never authorizes
#     a newer head);
#   - a Muso-AI repository has no successful qa-review conclusion on the current
#     head - a NO-GO, a pending review, a review that never ran, and a review
#     left on an older head all refuse, because absent is not GO;
#   - a repository declared no-QA has no successful no-mistakes attestation
#     named "PR must be raised via no-mistakes" on the current head;
#   - the repository is in neither declared class, so QA coverage is unknown;
#   - any check on the current head is red, except credit-approval-guard when
#     the pull request author is adk47 (the by-design self-authorship check).
#     A check name that ran more than once is read worst-wins, except that a
#     CANCELLED run is dropped once any non-cancelled run of that name exists,
#     and within one workflowName only the newest dated run counts; runs with
#     no workflow name or no date keep worst-wins;
#   - the pull request is a master/main twin in a declared twin repository whose
#     develop/beta counterpart is not merged. The twin rule is GitHub-only and
#     applies to core-backend and web-credits-next by default; elsewhere it is
#     skipped with a note rather than refused.
# It passes otherwise and prints the head, the verdict it verified, and the
# standing allowed red, so the merge record carries what was actually checked.
#
# QA coverage is declared, never inferred from the head. The owner Muso-AI is
# qa-review-covered. The no-QA class is adk47/firstmate plus each owner/repo on
# one line of config/merge-gate-no-qa-repos, where blank lines and # comments
# are ignored. That file is local and gitignored in this repo, so its absence is
# normal; the built-in default and the Muso-AI rule still decide coverage. A
# repository on neither list is refused rather than treated as unrequired.
# The twin-repo class is core-backend and web-credits-next plus each entry on
# one line of config/merge-gate-twin-repos; an entry without a slash matches a
# repository name, and an entry with a slash matches the full owner/repo.
#
# Silence means refuse: a read that cannot be completed, a missing gh, and an
# unparseable payload are all refusals, never a pass. There is no environment
# variable that turns the gate off; the only escape is the caller's explicit
# --override-gate <reason>, which bin/fm-pr-merge.sh records durably.
#
# The gate reads the forge's own per-commit check rollup, not anything
# firstmate recorded. Declared coverage decides on every forge: a QA-covered
# repository on a forge with no qa-review verdict source refuses with that exact
# reason, a no-QA repository needs the same attestation check on GitLab and
# GitHub, and an unlisted repository refuses as coverage unknown.
#
# Usage (sourced): fm_merge_gate <owner/repo> <pr-number> <expected-head> \
#                    [--recorded-head <sha>] [--forge <github|gitlab>]
# Usage (direct):  fm-merge-gate-lib.sh <owner/repo> <pr-number> <expected-head> \
#                    [--recorded-head <sha>] [--forge <github|gitlab>] [--check-only]
# The direct form is the audit entry point; it never merges anything.
# --check-only evaluates the verdict and checks even on a pull request that is
# already merged, which is what a backfill over past merges needs: the ordinary
# path short-circuits an already-merged pull request because the merge call
# itself will report it as merged.

# The standing allow: the adk47 self-authorship credit-approval-guard is the one
# admin-bypassed red the captain named (2026-11-03 12:2xZ), and only for adk47's
# own pull requests.
FM_MERGE_GATE_STANDING_ALLOW='credit-approval-guard'
FM_MERGE_GATE_STANDING_ALLOW_AUTHOR=adk47

# Red conclusions and states. A pending check is not red; a pending qa-review is
# still a refusal, because a review that has not concluded is not a GO.
fm_merge_gate_is_red() {
  case "$1" in
    FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE|STALE|ERROR) return 0 ;;
    *) return 1 ;;
  esac
}

# Read one pull request's facts and its per-head check rollup. Sets the
# FM_MERGE_GATE_* globals and returns non-zero when the read cannot be trusted.
FM_MERGE_GATE_HEAD=
FM_MERGE_GATE_AUTHOR=
FM_MERGE_GATE_BASE=
FM_MERGE_GATE_HEADREF=
FM_MERGE_GATE_STATE=
FM_MERGE_GATE_MERGED_AT=
FM_MERGE_GATE_BODY=
FM_MERGE_GATE_CHECKS=
fm_merge_gate_read_pr() {
  local repo=$1 number=$2 forge=${3:-github} fields line
  local total=0 named=0
  local head='' author='' base='' headref='' state='' merged_at='' body=''
  local checks=''

  FM_MERGE_GATE_HEAD=
  FM_MERGE_GATE_AUTHOR=
  FM_MERGE_GATE_BASE=
  FM_MERGE_GATE_HEADREF=
  FM_MERGE_GATE_STATE=
  FM_MERGE_GATE_MERGED_AT=
  FM_MERGE_GATE_BODY=
  FM_MERGE_GATE_CHECKS=

  if [ "$forge" = gitlab ]; then
    local host=${FM_PR_HOST:-${GITLAB_HOST:-}} encoded mr statuses
    command -v glab >/dev/null 2>&1 || return 1
    command -v jq >/dev/null 2>&1 || return 1
    encoded=${repo//\//%2F}
    mr=$(GITLAB_HOST="$host" glab api "projects/$encoded/merge_requests/$number" 2>/dev/null) || return 1
    [ -n "$mr" ] || return 1
    head=$(printf '%s' "$mr" | jq -r '.sha // empty' 2>/dev/null) || return 1
    [ -n "$head" ] || return 1
    statuses=$(GITLAB_HOST="$host" glab api "projects/$encoded/repository/commits/$head/statuses?per_page=100" 2>/dev/null) || return 1
    fields=$(printf '%s\n%s\n' "$mr" "$statuses" | jq -r -s '
      def conclusion:
        if . == "success" then "SUCCESS"
        elif . == "failed" then "FAILURE"
        elif . == "canceled" then "CANCELLED"
        elif . == "skipped" then "SKIPPED"
        elif . == "manual" then "ACTION_REQUIRED"
        else "PENDING" end;
      def state:
        if . == "opened" then "OPEN"
        elif . == "merged" then "MERGED"
        elif . == "closed" then "CLOSED"
        else (. // "" | ascii_upcase) end;
      .[0] as $mr | (.[1] | if type == "array" then . else [] end) as $statuses |
      (
        ("head=" + ($mr.sha // "")),
        ("author=" + (($mr.author.username) // "")),
        ("base=" + (($mr.target_branch) // "")),
        ("headref=" + (($mr.source_branch) // "")),
        ("state=" + (($mr.state) // "" | state)),
        ("merged_at=" + (($mr.merged_at) // "" | tostring)),
        ("body=" + (($mr.description // "") | gsub("[\r\n]+"; " "))),
        ($statuses[] | ("check=" + ((.name // "") | gsub("[\r\n]+"; " ")) + "\u001f" + ((.status // "") | conclusion)))
      )' 2>/dev/null) || return 1
  else
    command -v gh >/dev/null 2>&1 || return 1
    # One read, so the head and the checks that authorize it come from the same
    # snapshot. A check name that ran more than once on this head keeps its
    # worst-wins reading (a pending re-run still outranks an older success), but
    # a CANCELLED run is dropped once any non-cancelled run of the same name
    # exists: a concurrency group cancelling the older of two runs, or a re-run,
    # supersedes it, as the forge's own merge box reads it. Within ONE workflow
    # (same workflowName) only the newest dated run of a check counts, so a
    # re-run or a label-retriggered run that passed supersedes that workflow's
    # own earlier failure; two different workflows that share a check name, or
    # runs with no date, keep worst-wins. The body is folded onto one line because the payload is parsed as
    # key=value lines.
    if ! fields=$(gh pr view "$number" --repo "$repo" \
      --json headRefOid,author,baseRefName,headRefName,state,mergedAt,body,statusCheckRollup \
      --jq '(
          ("head=" + (.headRefOid // "")),
          ("author=" + ((.author.login) // "")),
          ("base=" + (.baseRefName // "")),
          ("headref=" + (.headRefName // "")),
          ("state=" + (.state // "")),
          ("merged_at=" + ((.mergedAt // "") | tostring)),
          ("body=" + ((.body // "") | gsub("[\r\n]+"; " "))),
          (((.statusCheckRollup // [])
            | group_by((.name // .context) // "")
            | map(if any(.[]; ((.conclusion // .state) // "") != "CANCELLED")
                  then map(select(((.conclusion // .state) // "") != "CANCELLED")) else . end)
            | map(map(. + {__wf: (.workflowName // ""), __at: ((.startedAt // .completedAt // "") | tostring)})
                  | (map(select(.__wf == "" or .__at == ""))
                     + (map(select(.__wf != "" and .__at != "")) | group_by(.__wf)
                        | map(sort_by(.__at) | last))))
            | add // [])[]
            | ("check=" + ((.name // .context) // "") + "\u001f" + ((.conclusion // .state) // "")))
        )' 2>/dev/null) || [ -z "$fields" ]; then
      return 1
    fi
  fi
  [ -n "$fields" ] || return 1
  while IFS= read -r line; do
    total=$((total + 1))
    case "$line" in
      head=*) head=${line#head=} ;;
      author=*) author=${line#author=} ;;
      base=*) base=${line#base=} ;;
      headref=*) headref=${line#headref=} ;;
      state=*) state=${line#state=} ;;
      merged_at=*) merged_at=${line#merged_at=} ;;
      body=*) body=${line#body=} ;;
      check=*)
        checks="$checks${line#check=}
"
        continue
        ;;
      *) continue ;;
    esac
    named=$((named + 1))
  done <<FIELDS
$fields
FIELDS
  # Every named field exactly once, and no unnamed line: a value carrying a
  # newline would split into a line no name matches, so it is refused here
  # rather than silently truncated into a value a check could accept.
  if [ "$named" -ne 7 ] || [ "$total" -ne $((7 + $(printf '%s' "$checks" | grep -c . || true))) ]; then
    return 1
  fi
  [ -n "$head" ] || return 1

  FM_MERGE_GATE_HEAD=$head
  FM_MERGE_GATE_AUTHOR=$author
  FM_MERGE_GATE_BASE=$base
  FM_MERGE_GATE_HEADREF=$headref
  FM_MERGE_GATE_STATE=$state
  FM_MERGE_GATE_MERGED_AT=$merged_at
  FM_MERGE_GATE_BODY=$body
  FM_MERGE_GATE_CHECKS=$checks
}

# Rank a conclusion so the worst of a repeated check wins: red is worse than
# pending or unknown, which is worse than green.
fm_merge_gate_conclusion_rank() {
  if fm_merge_gate_is_red "$1"; then
    printf '3'
  else
    case "$1" in
      SUCCESS) printf '1' ;;
      *) printf '2' ;;
    esac
  fi
}

# The conclusion of the named check on the current head, or empty when the head
# carries no such check. A check that appears more than once is reported as the
# worst of its conclusions, so a stale success cannot outvote a later pending or
# failed verdict.
fm_merge_gate_check_conclusion() {
  local want=$1 line name conclusion found='' found_set=false
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%$'\x1f'*}
    conclusion=${line#*$'\x1f'}
    [ "$name" = "$want" ] || continue
    [ -n "$conclusion" ] || conclusion=PENDING
    if [ "$found_set" != true ]; then
      found=$conclusion
      found_set=true
    elif [ "$(fm_merge_gate_conclusion_rank "$conclusion")" -gt "$(fm_merge_gate_conclusion_rank "$found")" ]; then
      found=$conclusion
    fi
  done <<CHECKS
$FM_MERGE_GATE_CHECKS
CHECKS
  printf '%s' "$found"
}

# The local, gitignored config file that declares the no-QA repositories.
fm_merge_gate_no_qa_config() {
  local home
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  printf '%s/merge-gate-no-qa-repos' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

# Whether the repository is declared no-QA. adk47/firstmate is the built-in
# default so this repo merges correctly when the local config file is absent.
fm_merge_gate_is_no_qa_repo() {
  local repo=$1 file line
  repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
  [ "$repo" = adk47/firstmate ] && return 0
  file=$(fm_merge_gate_no_qa_config)
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -n "$line" ] || continue
    [ "$line" = "$repo" ] && return 0
  done < "$file"
  return 1
}

# The local, gitignored config file that declares the twin repositories.
fm_merge_gate_twin_config() {
  local home
  home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
  printf '%s/merge-gate-twin-repos' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

# Whether the repository carries the develop/beta twin rule. core-backend and
# web-credits-next are the built-in defaults; a configured entry without a slash
# matches the repository name, and one with a slash matches the full owner/repo.
fm_merge_gate_is_twin_repo() {
  local repo=$1 name file line
  repo=$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')
  name=${repo##*/}
  case "$name" in
    core-backend|web-credits-next) return 0 ;;
  esac
  file=$(fm_merge_gate_twin_config)
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    [ -n "$line" ] || continue
    case "$line" in
      */*) [ "$line" = "$repo" ] && return 0 ;;
      *) [ "$line" = "$name" ] && return 0 ;;
    esac
  done < "$file"
  return 1
}

# Print a description of an unmerged develop/beta twin of this master/main pull
# request, or nothing when there is none. A twin is either another pull request
# on the same head branch targeting develop or beta, or a pull request the body
# names whose base is develop or beta.
fm_merge_gate_unmerged_twin() {
  local repo=$1 headref=$2 body=$3
  local rows line number base state merged_at refs ref n
  local found=''

  if [ -n "$headref" ]; then
    if rows=$(gh pr list --repo "$repo" --head "$headref" --state all \
      --json number,baseRefName,state,mergedAt \
      --jq '.[] | ((.number | tostring) + "|" + (.baseRefName // "") + "|" + (.state // "") + "|" + ((.mergedAt // "") | tostring))' \
      2>/dev/null); then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        number=${line%%|*}
        line=${line#*|}
        base=${line%%|*}
        line=${line#*|}
        state=${line%%|*}
        merged_at=${line#*|}
        case "$base" in
          develop|beta|develop/*|beta/*) ;;
          *) continue ;;
        esac
        if [ "$state" != MERGED ] && [ -z "$merged_at" ]; then
          found="pull request #$number targets $base and is not merged"
          break
        fi
      done <<ROWS
$rows
ROWS
    else
      found="the develop/beta twin list could not be read"
    fi
  fi
  [ -z "$found" ] || { printf '%s' "$found"; return 0; }

  # Body references, limited to the numbers the body names alongside develop or
  # beta, deduplicated and bounded so an unrelated issue reference is not read as
  # a twin and a long body cannot turn the gate into an unbounded number of
  # forge reads.
  refs=$(printf '%s' "$body" | grep -oiE '(develop|beta)([[:space:]]*#[0-9]+|/pull/[0-9]+)' | grep -oE '[0-9]+' | sort -un | head -10 || true)
  for ref in $refs; do
    n=$ref
    if ! line=$(gh api "repos/$repo/pulls/$n" \
      --jq '((.base.ref // "") + "|" + (.state // "") + "|" + ((.merged // false) | tostring))' \
      2>/dev/null) || [ -z "$line" ]; then
      found="pull request #$n referenced by the body could not be read"
      break
    fi
    base=${line%%|*}
    line=${line#*|}
    state=${line%%|*}
    merged_at=${line#*|}
    case "$base" in
      develop|beta|develop/*|beta/*) ;;
      *) continue ;;
    esac
    if [ "$state" != closed ] || [ "$merged_at" != true ]; then
      found="pull request #$n targets $base and is not merged"
      break
    fi
  done
  printf '%s' "$found"
}

# fm_merge_gate <owner/repo> <pr-number> <expected-head> [options]
# Returns 0 when the merge is authorized, 1 when it is refused, 2 on a usage
# error. Every refusal is one plain-English line naming the exact reason.
fm_merge_gate() {
  local repo='' number='' expected='' recorded='' forge=github
  local arg
  local refusals='' allowed='' qa='' attestation='' coverage='' verdict_label='' verdict_value=''
  local line name conclusion twin='' check_only=false owner='' 

  if [ "$#" -lt 3 ]; then
    echo "error: merge gate needs <owner/repo> <pr-number> <expected-head>" >&2
    return 2
  fi
  repo=$1
  number=$2
  expected=$3
  shift 3
  while [ "$#" -gt 0 ]; do
    arg=$1
    case "$arg" in
      --recorded-head)
        [ "$#" -ge 2 ] || { echo "error: --recorded-head needs a commit" >&2; return 2; }
        recorded=$2
        shift 2
        ;;
      --recorded-head=*)
        recorded=${arg#--recorded-head=}
        shift
        ;;
      --check-only)
        # The gate never merges; the flag makes an audit of an already-merged
        # pull request evaluate its verdict instead of short-circuiting.
        check_only=true
        shift
        ;;
      --forge)
        [ "$#" -ge 2 ] || { echo "error: --forge needs a forge name" >&2; return 2; }
        forge=$2
        shift 2
        ;;
      --forge=*)
        forge=${arg#--forge=}
        shift
        ;;
      *)
        echo "error: unknown merge gate option: $arg" >&2
        return 2
        ;;
    esac
  done

  case "$repo" in
    */*) ;;
    *) echo "error: merge gate needs <owner/repo>" >&2; return 2 ;;
  esac
  case "$number" in
    ''|*[!0-9]*) echo "error: merge gate needs a numeric pull request number" >&2; return 2 ;;
  esac

  case "$forge" in
    github|gitlab) ;;
    *) echo "error: merge gate needs --forge github or --forge gitlab" >&2; return 2 ;;
  esac

  owner=$(printf '%s' "${repo%%/*}" | tr '[:upper:]' '[:lower:]')
  if [ "$owner" = muso-ai ]; then
    coverage=qa
  elif fm_merge_gate_is_no_qa_repo "$repo"; then
    coverage='no-qa'
  fi
  if [ -z "$coverage" ]; then
    printf 'error: refusing to merge %s#%s: QA coverage unknown\n' "$repo" "$number" >&2
    return 1
  fi
  if [ "$coverage" = qa ] && [ "$forge" != github ]; then
    printf 'error: refusing to merge %s#%s: QA-covered repo, no verdict source on this forge\n' \
      "$repo" "$number" >&2
    return 1
  fi

  if ! fm_merge_gate_read_pr "$repo" "$number" "$forge"; then
    printf 'error: refusing to merge %s#%s: the review verdict and check state on the current head could not be read, and an unread verdict is not a GO\n' \
      "$repo" "$number" >&2
    return 1
  fi

  # An already-merged pull request needs no authorization; the merge call itself
  # will report it as merged. A check-only audit still evaluates the verdict.
  if [ "$check_only" != true ] \
    && { [ "$FM_MERGE_GATE_STATE" = MERGED ] || [ -n "$FM_MERGE_GATE_MERGED_AT" ]; }; then
    printf 'merge gate: %s#%s is already merged at head %s\n' \
      "$repo" "$number" "$FM_MERGE_GATE_HEAD"
    return 0
  fi

  if [ -n "$expected" ] && [ "$expected" != "$FM_MERGE_GATE_HEAD" ]; then
    refusals="$refusals  - the head moved: expected $expected, the pull request is at $FM_MERGE_GATE_HEAD
"
  fi
  if [ -n "$recorded" ] && [ "$recorded" != "$FM_MERGE_GATE_HEAD" ]; then
    refusals="$refusals  - the recorded head $recorded is not the current head $FM_MERGE_GATE_HEAD, so any verdict recorded against it is stale
"
  fi

  case "$coverage" in
    qa)
      qa=$(fm_merge_gate_check_conclusion qa-review)
      if [ -z "$qa" ]; then
        refusals="$refusals  - no qa-review verdict exists on head $FM_MERGE_GATE_HEAD, and an absent verdict is not a GO
"
      elif [ "$qa" != SUCCESS ]; then
        refusals="$refusals  - the qa-review verdict on head $FM_MERGE_GATE_HEAD is $qa, not SUCCESS
"
      fi
      verdict_label='qa-review'
      verdict_value=$qa
      ;;
    no-qa)
      attestation=$(fm_merge_gate_check_conclusion 'PR must be raised via no-mistakes')
      if [ -z "$attestation" ]; then
        refusals="$refusals  - no no-mistakes attestation named 'PR must be raised via no-mistakes' exists on head $FM_MERGE_GATE_HEAD, and an absent attestation is not a GO
"
      elif [ "$attestation" != SUCCESS ]; then
        refusals="$refusals  - the no-mistakes attestation on head $FM_MERGE_GATE_HEAD is $attestation, not SUCCESS
"
      fi
      verdict_label='no-mistakes-attestation'
      verdict_value=$attestation
      ;;
  esac

  # Red checks, with only the standing adk47 self-authorship allow.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%$'\x1f'*}
    conclusion=${line#*$'\x1f'}
    fm_merge_gate_is_red "$conclusion" || continue
    if [ "$name" = "$FM_MERGE_GATE_STANDING_ALLOW" ] \
      && [ "$FM_MERGE_GATE_AUTHOR" = "$FM_MERGE_GATE_STANDING_ALLOW_AUTHOR" ]; then
      allowed="$allowed$name
"
      continue
    fi
    refusals="$refusals  - the check $name is $conclusion on head $FM_MERGE_GATE_HEAD
"
  done <<CHECKS
$FM_MERGE_GATE_CHECKS
CHECKS

  # Twin rule: a master/main pull request in a declared twin repository whose
  # develop/beta counterpart has not merged is refused, because the twin would
  # land the same change twice.
  case "$FM_MERGE_GATE_BASE" in
    master|main)
      if [ "$forge" != github ]; then
        printf 'merge gate: twin check skipped for %s#%s: the develop/beta twin rule is GitHub-only\n' \
          "$repo" "$number"
      elif ! fm_merge_gate_is_twin_repo "$repo"; then
        printf 'merge gate: twin check skipped for %s#%s: the repository is not declared a twin repository\n' \
          "$repo" "$number"
      else
        twin=$(fm_merge_gate_unmerged_twin "$repo" "$FM_MERGE_GATE_HEADREF" "$FM_MERGE_GATE_BODY")
        if [ -n "$twin" ]; then
          refusals="$refusals  - this is a $FM_MERGE_GATE_BASE twin and its develop/beta counterpart is unmerged: $twin
"
        fi
      fi
      ;;
  esac

  if [ -n "$refusals" ]; then
    printf 'error: refusing to merge %s#%s\n' "$repo" "$number" >&2
    printf '%s' "$refusals" >&2
    return 1
  fi

  printf 'merge gate: %s#%s authorized at head %s (%s=%s, allowed reds=%s)\n' \
    "$repo" "$number" "$FM_MERGE_GATE_HEAD" "$verdict_label" "${verdict_value:-not-required}" \
    "$(printf '%s' "$allowed" | tr '\n' ',' | sed 's/,$//')"
  return 0
}

# Direct execution is the check-only audit entry point.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_merge_gate "$@"
fi
