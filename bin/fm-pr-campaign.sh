#!/usr/bin/env bash
# fm-pr-campaign.sh - one-command mechanical steps for a parallel-PR merge campaign.
#
# Parallel independent PRs plus a hand-rederived digest and restack/merge-next
# check every turn burned context during the firstmate-port campaign. This
# script owns those mechanical reads so a later campaign is one command plus a
# short decision instead of a one-liner and a wall of GitHub JSON.
#
# Subcommands (all read-only except restack, which only retargets PR bases):
#   digest --repo OWNER/NAME [--limit N]
#     One line per open PR: number, base, head, mergeable, check summary, URL.
#   restack --repo OWNER/NAME BOTTOM [NEXT...]
#     Given PR numbers bottom-first, set each higher PR's GitHub base to the
#     head branch of the PR below it. The bottom PR is never touched. Prints
#     the resulting stack bottom-first. Never rewrites git history; workers
#     still rebase.
#   merge-next --repo OWNER/NAME [N...]
#     Print the first eligible PR in the given order (or all open PRs oldest
#     first): mergeable, a clean mergeable-state, and checks all-green or
#     absent. Prints NONE and exits 1 when nothing is eligible. Never merges;
#     firstmate still calls fm-pr-check.sh and fm-pr-merge.sh.
#
# A PR counts as eligible with no checks configured when GitHub still reports
# it mergeable and clean; the printed summary says "none" in that case so the
# operator sees the difference. A null mergeable (GitHub still computing) is
# reported as unknown and never counts as eligible.
#
# All GitHub reads go through gh-axi's REST surface. Restack retargets through
# gh-axi pr edit --base. Nothing here merges, so there is no second merge path
# around fm-pr-merge.sh.
#
# Usage:
#   fm-pr-campaign.sh digest --repo OWNER/NAME [--limit N]
#   fm-pr-campaign.sh restack --repo OWNER/NAME BOTTOM [NEXT...]
#   fm-pr-campaign.sh merge-next --repo OWNER/NAME [N...]
#   fm-pr-campaign.sh --help | help [subcommand]
set -eu

usage() {
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

need_gh_axi() {
  command -v gh-axi >/dev/null 2>&1 || fail "gh-axi is required on PATH" 1
}

# Owner and repository rules mirror bin/fm-pr-lib.sh's GitHub URL pattern.
repo_valid() {
  local repo=${1-} owner name
  local LC_ALL=C
  case "$repo" in
    */*) owner=${repo%%/*}; name=${repo#*/} ;;
    *) return 1 ;;
  esac
  [[ "$owner" =~ ^([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9-]{0,37}[A-Za-z0-9])$ ]] || return 1
  [[ "$owner" != *--* ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9._-]{1,100}$ ]] || return 1
  [ "$name" != . ] && [ "$name" != .. ] && [[ "$repo" != *//* ]]
}

pr_number_valid() {
  [[ "${1-}" =~ ^[1-9][0-9]*$ ]]
}

# api_body <path> <jq>: print gh-axi's projected response as plain lines.
# gh-axi renders small projections as bare key: value lines and larger ones
# inside an api_response body envelope with backslash escapes; both shapes
# normalize to the same lines. A truncated envelope refuses rather than
# reporting on partial data.
api_body() {
  local path=$1 jqexpr=$2 out first rest body
  out=$(gh-axi api "$path" --jq "$jqexpr" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  first=${out%%$'\n'*}
  if [ "$first" != api_response: ]; then
    printf '%s\n' "$out"
    return 0
  fi
  case "$out" in
    *$'\n  truncated: true'*) return 1 ;;
  esac
  rest=${out#*$'\n  body: '}
  body=${rest%%$'\n'*}
  body=${body#\"}
  body=${body%\"}
  [ -n "$body" ] || return 0
  printf '%b\n' "$body"
}

# api_field <text> <key>: value of a top-level "key: value" line, unquoted.
api_field() {
  local text=$1 key=$2 line value
  line=$(printf '%s\n' "$text" | grep -m1 "^$key: " || true)
  [ -n "$line" ] || return 1
  value=${line#*: }
  value=${value#\"}
  value=${value%\"}
  printf '%s' "$value"
}

# pr_detail <repo> <number>: number, base, head, sha, mergeable, state, url.
pr_detail() {
  api_body "/repos/$1/pulls/$2" \
    '{number: .number, base: .base.ref, head: .head.ref, sha: .head.sha, mergeable: .mergeable, mstate: .mergeable_state, state: .state, url: .html_url}'
}

mergeable_word() {
  case "${1-}" in
    true) printf 'yes' ;;
    false) printf 'no' ;;
    *) printf 'unknown' ;;
  esac
}

# check_summary <repo> <sha>: pending, fail, all-green, or none.
# Combines check-runs conclusions with legacy commit-status contexts; a sha
# with neither is "none", which the digest reports apart from "all-green".
check_summary() {
  local repo=$1 sha=$2 runs st sstate scount
  local total=0 pending=0 failed=0 line status conclusion
  runs=$(api_body "/repos/$repo/commits/$sha/check-runs" \
    '.check_runs[] | "\(.status)/\(.conclusion)"') || return 1
  st=$(api_body "/repos/$repo/commits/$sha/status" \
    '"\(.state)/\(.total_count)"') || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    status=${line%%/*}
    conclusion=${line#*/}
    if [ "$status" != completed ]; then
      pending=$((pending + 1))
      continue
    fi
    case "$conclusion" in
      success|neutral|skipped) ;;
      *) failed=$((failed + 1)) ;;
    esac
  done <<RUNS
$runs
RUNS
  sstate=${st%%/*}
  scount=${st#*/}
  case "$scount" in
    ''|*[!0-9]*) return 1 ;;
  esac
  total=$((total + scount))
  case "$sstate" in
    pending) [ "$scount" -eq 0 ] || pending=$((pending + 1)) ;;
    success) ;;
    *) failed=$((failed + 1)) ;;
  esac
  if [ "$total" -eq 0 ]; then
    printf 'none'
  elif [ "$failed" -gt 0 ]; then
    printf 'fail'
  elif [ "$pending" -gt 0 ]; then
    printf 'pending'
  else
    printf 'all-green'
  fi
}

# digest_line <repo> <number>: one compact line for a PR, or return 1.
digest_line() {
  local repo=$1 number=$2 detail base head sha mergeable url summary
  detail=$(pr_detail "$repo" "$number") || return 1
  base=$(api_field "$detail" base) || return 1
  head=$(api_field "$detail" head) || return 1
  sha=$(api_field "$detail" sha) || return 1
  mergeable=$(api_field "$detail" mergeable) || return 1
  url=$(api_field "$detail" url) || return 1
  [ -n "$base" ] && [ -n "$head" ] && [ -n "$sha" ] && [ -n "$url" ] || return 1
  summary=$(check_summary "$repo" "$sha") || return 1
  printf '#%s base:%s head:%s mergeable:%s checks:%s %s\n' \
    "$number" "$base" "$head" "$(mergeable_word "$mergeable")" "$summary" "$url"
}

open_numbers() {
  local repo=$1 limit=$2 body n
  body=$(api_body "/repos/$repo/pulls?state=open&per_page=$limit" '.[].number') || return 1
  while IFS= read -r n; do
    pr_number_valid "$n" || return 1
    printf '%s\n' "$n"
  done <<NUMS | sort -n
$body
NUMS
}

cmd_digest() {
  local repo="" limit=30 listed n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=${2-}; shift 2 ;;
      --repo=*) repo=${1#--repo=}; shift ;;
      --limit) limit=${2-}; shift 2 ;;
      --limit=*) limit=${1#--limit=}; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "digest: unexpected argument '$1'" 2 ;;
    esac
  done
  [ -n "$repo" ] || fail "digest: --repo OWNER/NAME is required" 2
  repo_valid "$repo" || fail "digest: invalid repo '$repo', want OWNER/NAME" 2
  case "$limit" in
    ''|*[!0-9]*|0*) fail "digest: --limit must be a positive number" 2 ;;
  esac
  listed=$(open_numbers "$repo" "$limit") || fail "digest: could not list open PRs for $repo"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    digest_line "$repo" "$n" || fail "digest: could not read PR $n in $repo"
  done <<NUMS
$listed
NUMS
  return 0
}

cmd_restack() {
  local repo="" numbers=() n
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=${2-}; shift 2 ;;
      --repo=*) repo=${1#--repo=}; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) fail "restack: unexpected flag '$1'" 2 ;;
      *) numbers+=("$1"); shift ;;
    esac
  done
  [ -n "$repo" ] || fail "restack: --repo OWNER/NAME is required" 2
  repo_valid "$repo" || fail "restack: invalid repo '$repo', want OWNER/NAME" 2
  [ "${#numbers[@]}" -ge 1 ] || fail "restack: at least one PR number is required, bottom first" 2
  local seen=" " detail heads=() bases=() urls=()
  for n in "${numbers[@]}"; do
    pr_number_valid "$n" || fail "restack: invalid PR number '$n'" 2
    case "$seen" in
      *" $n "*) fail "restack: duplicate PR number '$n'" 2 ;;
    esac
    seen="$seen$n "
    detail=$(pr_detail "$repo" "$n") || fail "restack: could not read PR $n in $repo"
    heads+=("$(api_field "$detail" head)") || fail "restack: could not read PR $n in $repo"
    bases+=("$(api_field "$detail" base)") || fail "restack: could not read PR $n in $repo"
    urls+=("$(api_field "$detail" url)") || fail "restack: could not read PR $n in $repo"
    [ -n "${heads[${#heads[@]} - 1]}" ] && [ -n "${bases[${#bases[@]} - 1]}" ] \
      && [ -n "${urls[${#urls[@]} - 1]}" ] \
      || fail "restack: could not read PR $n in $repo"
  done
  local i want
  for i in "${!numbers[@]}"; do
    if [ "$i" -eq 0 ]; then
      printf 'bottom: #%s base:%s head:%s %s\n' \
        "${numbers[$i]}" "${bases[$i]}" "${heads[$i]}" "${urls[$i]}"
      continue
    fi
    want=${heads[$((i - 1))]}
    if [ "${bases[$i]}" = "$want" ]; then
      printf 'keep: #%s base:%s head:%s %s\n' \
        "${numbers[$i]}" "${bases[$i]}" "${heads[$i]}" "${urls[$i]}"
    else
      gh-axi pr edit "${numbers[$i]}" --repo "$repo" --base "$want" >/dev/null 2>&1 \
        || fail "restack: could not retarget PR ${numbers[$i]} onto $want"
      printf 'retargeted: #%s base:%s head:%s %s\n' \
        "${numbers[$i]}" "$want" "${heads[$i]}" "${urls[$i]}"
    fi
  done
  return 0
}

# eligible_detail <repo> <number>: print the digest line when the PR is the
# merge-next answer, else return 1 without output.
eligible_detail() {
  local repo=$1 number=$2 detail state mergeable mstate base head sha url summary line
  detail=$(pr_detail "$repo" "$number") || return 1
  state=$(api_field "$detail" state) || return 1
  [ "$state" = open ] || return 1
  mergeable=$(api_field "$detail" mergeable) || return 1
  [ "$mergeable" = true ] || return 1
  mstate=$(api_field "$detail" mstate) || return 1
  [ "$mstate" = clean ] || return 1
  base=$(api_field "$detail" base) || return 1
  head=$(api_field "$detail" head) || return 1
  sha=$(api_field "$detail" sha) || return 1
  url=$(api_field "$detail" url) || return 1
  [ -n "$base" ] && [ -n "$head" ] && [ -n "$sha" ] && [ -n "$url" ] || return 1
  summary=$(check_summary "$repo" "$sha") || return 1
  case "$summary" in
    all-green|none) ;;
    *) return 1 ;;
  esac
  line=$(printf '#%s base:%s head:%s mergeable:yes checks:%s %s\n' \
    "$number" "$base" "$head" "$summary" "$url")
  printf '%s\n' "$line"
}

cmd_merge_next() {
  local repo="" numbers=() n line
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo) repo=${2-}; shift 2 ;;
      --repo=*) repo=${1#--repo=}; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) fail "merge-next: unexpected flag '$1'" 2 ;;
      *) numbers+=("$1"); shift ;;
    esac
  done
  [ -n "$repo" ] || fail "merge-next: --repo OWNER/NAME is required" 2
  repo_valid "$repo" || fail "merge-next: invalid repo '$repo', want OWNER/NAME" 2
  if [ "${#numbers[@]}" -eq 0 ]; then
    local listed
    listed=$(open_numbers "$repo" 100) || fail "merge-next: could not list open PRs for $repo"
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      numbers+=("$n")
    done <<NUMS
$listed
NUMS
  else
    for n in "${numbers[@]}"; do
      pr_number_valid "$n" || fail "merge-next: invalid PR number '$n'" 2
    done
  fi
  for n in "${numbers[@]}"; do
    if line=$(eligible_detail "$repo" "$n"); then
      printf '%s\n' "$line"
      return 0
    fi
  done
  printf 'NONE\n'
  return 1
}

need_gh_axi
case "${1-}" in
  digest) shift; cmd_digest "$@" ;;
  restack) shift; cmd_restack "$@" ;;
  merge-next) shift; cmd_merge_next "$@" ;;
  help) shift; usage; exit 0 ;;
  -h|--help) usage; exit 0 ;;
  ''|-*) usage >&2; exit 2 ;;
  *) fail "unknown subcommand '$1' (want digest, restack, or merge-next)" 2 ;;
esac
