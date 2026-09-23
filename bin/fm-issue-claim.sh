#!/usr/bin/env bash
# Screen GitHub issues for an existing claim or fix before work is spent on one.
#
# Limits, first: this command closes, labels, and comments on nothing - every
# forge call is a read, including in --sweep - and it never fetches into the
# local clone. A fix that cites the issue number nowhere - no PR body, branch,
# or title, no commit message, and no --symbol the caller supplied - stays
# invisible to every check. It is the evidence half of claim hygiene, not
# governance: acting on a verdict stays with the caller and the forge's own
# policy, and it reads and writes no backlog.
#
# Usage:
#   fm-issue-claim.sh --repo <owner/name> [options] <issue>...
#   fm-issue-claim.sh --repo <owner/name> --sweep [options] [<issue>...]
#   fm-issue-claim.sh --repo <owner/name> --save-corpus <file>
#
# Options:
#   --git-dir <dir>      local clone searched by the history check (default: .)
#   --ref <ref>          history ref (default: <remote>/<default-branch>, where
#                        <remote> is the clone's remote whose URL names the repo)
#   --symbol <n>:<text>  also search history for commits adding or removing
#                        <text> (git log -S) for issue <n>; repeatable
#   --corpus <file>      reuse an open-PR corpus written by --save-corpus
#   --save-corpus <file> write the fetched open-PR corpus for later reuse
#   --sweep              opt-in, report-only: print one disposition line per
#                        issue instead of the evidence block; with no issue
#                        numbers it screens every open issue of the repo
#
# Each issue runs five checks, and one open-PR corpus is shared by every issue
# in the run:
#   timeline  cross-referenced events (GET issues/<n>/timeline): a pull request
#             in this repository that is open or merged; a cross-reference
#             from an issue or another repository is only a hint.
#   stamps    maintainer triage stamps: comments by OWNER, MEMBER, or
#             COLLABORATOR carrying <!-- triage: ... outcome=... -->. When the
#             outcome is existing-pr, each "existing-pr -> #X" (ASCII arrow or
#             U+2192) in that comment names a claiming PR whose current state
#             is read; a stamp naming no PR is still a claim. Stamps from other
#             authors are only hints.
#   corpus    every open pull request, fetched by paginated REST because the
#             search API does not index bare numbers. A PR matches when its
#             body cites #<n> (not owner/repo#<n> of another repository), the
#             repo's own owner/name#<n>, or github.com/<owner/name>/issues/<n>,
#             or its head branch or title contains <n> as a whole number, so
#             4018 never matches 40181. The fetched count is compared with the
#             search API's open-PR total_count; a short or unverified corpus is
#             disclosed and never treated as complete.
#   fork      head branches containing <n> in <author>/<name>, the issue
#             author's fork under the upstream repository's name. A missing
#             repository there is disclosed: a renamed fork is not searched.
#   history   commits on the history ref since the issue was opened whose
#             message cites the issue with the same body rule, plus any
#             --symbol pickaxe matches. The ref is used as it is; fetch first.
# Assignees and comments that claim the issue in prose are reported as hints
# and never change a verdict.
#
# Output, per issue, one block:
#   === #<n> state=<state> author=<login> labels=<a,b> :: <title>
#   verdict: <open|claimed|partially-covered|fixed-on-main|unknown>
#   checks: issue=.. timeline=.. stamps=.. corpus=.. fork=.. history=..
#   coverage: complete | incomplete (<checks that could not look>)
#   claim: / merged: / closed: <evidence> [<checks that found it>]
#   hint: / disclose: <context that never decides a verdict>
# Verdicts:
#   claimed            an open or draft PR, a fork branch, or a maintainer
#                      existing-pr stamp claims the issue; nothing merged.
#   partially-covered  merged evidence exists and an open claim remains.
#   fixed-on-main      merged evidence (a merged PR, or a history commit
#                      citing the issue or matching a --symbol) and no open
#                      claim. It is evidence to inspect, not proof that every
#                      part of the issue is resolved.
#   open               every check looked and found nothing.
#   unknown            the issue could not be read, or nothing was found while
#                      at least one check could not look. A failed or
#                      rate-limited read never yields open.
# A positive verdict reached with incomplete coverage keeps its verdict and
# says so on its coverage line.
#
# --sweep prints, per issue:
#   sweep: #<n> <disposition> state=<s> verdict=<v> coverage=<complete|incomplete>
#          link=<items|-> evidence=<items|->
# Dispositions, judged only from durable evidence - a merged PR that
# cross-references the issue, a history commit, or an open PR - and never from
# PR checks, reviews, or mergeability, which stay forge-owned:
#   close-candidate  fixed-on-main with complete coverage.
#   leave-open       any open claim remains, including every issue with a live
#                    PR stamped existing-pr; never a close candidate.
#   no-action        verdict open, or the issue is no longer open.
#   undetermined     verdict unknown, or merged evidence with incomplete
#                    coverage that could hide a live claim.
# link= names durable evidence the issue page does not show: a PR whose body
# cites the issue, or a commit whose message does, found by neither the
# timeline nor a stamp. A title, branch, fork-branch, or --symbol match is
# never a link candidate. Screening every open issue costs about five API
# reads per issue plus one shared corpus; the open-issue list is checked
# against the search API total the same way the corpus is.
#
# The corpus file is JSON (schema fm-issue-claim-corpus.v1) carrying repo,
# fetched_at, fetched, total_count, and slim prs[]; a reused corpus keeps its
# own completeness verdict and discloses its age.
#
# Exit status: 0 when every issue got a verdict other than unknown, 1 when any
# verdict is unknown, 2 on a usage or setup refusal.
set -eu

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'
}

die() {
  printf 'fm-issue-claim: %s\n' "$*" >&2
  exit 2
}

REPO=
GIT_DIR_ARG=.
REF=
CORPUS_IN=
CORPUS_OUT=
SWEEP=0
ISSUES=()
SYMBOLS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) [ "$#" -ge 2 ] || die "--repo needs <owner/name>"; REPO=$2; shift 2 ;;
    --git-dir) [ "$#" -ge 2 ] || die "--git-dir needs a directory"; GIT_DIR_ARG=$2; shift 2 ;;
    --ref) [ "$#" -ge 2 ] || die "--ref needs a ref"; REF=$2; shift 2 ;;
    --symbol) [ "$#" -ge 2 ] || die "--symbol needs <n>:<text>"; SYMBOLS+=("$2"); shift 2 ;;
    --corpus) [ "$#" -ge 2 ] || die "--corpus needs a file"; CORPUS_IN=$2; shift 2 ;;
    --save-corpus) [ "$#" -ge 2 ] || die "--save-corpus needs a file"; CORPUS_OUT=$2; shift 2 ;;
    --sweep) SWEEP=1; shift ;;
    --) shift; while [ "$#" -gt 0 ]; do ISSUES+=("$1"); shift; done ;;
    -*) die "unknown option: $1" ;;
    *) ISSUES+=("$1"); shift ;;
  esac
done

case "$REPO" in
  ''|*[!A-Za-z0-9_./-]*|/*|*/|*/*/*) die "--repo must be <owner/name>" ;;
  */*) ;;
  *) die "--repo must be <owner/name>" ;;
esac
[ "${#ISSUES[@]}" -gt 0 ] || [ -n "$CORPUS_OUT" ] || [ "$SWEEP" = 1 ] \
  || die "name at least one issue number, --sweep, or --save-corpus <file>"
[ "$SWEEP" = 0 ] || [ -z "$CORPUS_OUT" ] || die "--sweep and --save-corpus are exclusive"
SWEEP_ALL=0
[ "$SWEEP" = 0 ] || [ "${#ISSUES[@]}" -gt 0 ] || SWEEP_ALL=1
for n in ${ISSUES[@]+"${ISSUES[@]}"}; do
  case "$n" in
    ''|0*|*[!0-9]*) die "not an issue number: $n" ;;
  esac
done
for s in ${SYMBOLS[@]+"${SYMBOLS[@]}"}; do
  case "$s" in
    *:?*) ;;
    *) die "--symbol must be <n>:<text>: $s" ;;
  esac
  sn=${s%%:*}
  found=0
  for n in ${ISSUES[@]+"${ISSUES[@]}"}; do [ "$n" != "$sn" ] || found=1; done
  [ "$found" = 1 ] || [ "$SWEEP_ALL" = 1 ] \
    || die "--symbol names issue $sn, which is not being screened"
done
[ -z "$CORPUS_IN" ] || [ -z "$CORPUS_OUT" ] || die "--corpus and --save-corpus are exclusive"
command -v gh >/dev/null 2>&1 || die "gh is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"

OWNER=${REPO%%/*}
NAME=${REPO#*/}
# Regex-escape the slug's dots; owner/name characters are otherwise literal.
REPO_RE=$(printf '%s' "$REPO" | sed 's/\./\\./g')

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-issue-claim.XXXXXX") \
  || die "could not create a temporary directory"
trap 'rm -rf "$WORK"' EXIT INT TERM

# gh_read <outfile> <gh args...>: capture stdout, keep stderr for diagnosis.
gh_read() {
  local out=$1
  shift
  gh "$@" >"$out" 2>"$out.err"
}

# gh_reason <outfile>: one short line explaining a failed read.
gh_reason() {
  local line
  line=$(grep -v '^[[:space:]]*$' "$1.err" 2>/dev/null | head -n 1 | tr -d '\r' | cut -c1-160)
  printf '%s' "${line:-gh exited non-zero}"
}

is_404() {
  grep -q 'HTTP 404' "$1.err" 2>/dev/null
}

# Pages of a --paginate read are concatenated JSON arrays; merge them.
slurp_pages() {
  jq -s 'map(if type == "array" then . else error("not a page array") end) | add // []' "$1"
}

one_line() {
  tr '\t\n\r' '   ' | cut -c1-"${1:-80}"
}

# --- open-PR corpus -------------------------------------------------------

CORPUS="$WORK/corpus.json"
CORPUS_STATUS=
CORPUS_NOTE=

load_corpus_file() {
  local file=$1
  [ -r "$file" ] || die "cannot read corpus file: $file"
  jq -e --arg repo "$REPO" '
    .schema == "fm-issue-claim-corpus.v1"
    and ((.repo | ascii_downcase) == ($repo | ascii_downcase))
    and (.prs | type == "array")
    and (.fetched | type == "number")
  ' "$file" >/dev/null 2>&1 \
    || die "corpus file is not an fm-issue-claim-corpus.v1 corpus for $REPO: $file"
  cp "$file" "$CORPUS"
}

fetch_corpus() {
  local total='' incomplete='' now
  if gh_read "$WORK/search" api "search/issues?q=repo:$REPO+is:pr+is:open&per_page=1" \
    && total=$(jq -er '.total_count | numbers' "$WORK/search" 2>/dev/null); then
    incomplete=$(jq -r '.incomplete_results // false' "$WORK/search")
  else
    total=
    CORPUS_NOTE="open-PR total could not be read: $(gh_reason "$WORK/search")"
  fi
  if ! gh_read "$WORK/pulls" api "repos/$REPO/pulls?state=open&per_page=100" --paginate; then
    CORPUS_STATUS="failed"
    CORPUS_NOTE="open-PR corpus could not be fetched: $(gh_reason "$WORK/pulls")"
    return 0
  fi
  if ! slurp_pages "$WORK/pulls" > "$WORK/pulls.json" 2>/dev/null; then
    CORPUS_STATUS="failed"
    CORPUS_NOTE="open-PR corpus pages were not JSON arrays"
    return 0
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg repo "$REPO" --arg now "$now" --arg total "$total" --arg inc "$incomplete" '{
      schema: "fm-issue-claim-corpus.v1",
      repo: $repo,
      fetched_at: $now,
      fetched: length,
      total_count: (if $total == "" then null else ($total | tonumber) end),
      search_incomplete: ($inc == "true"),
      prs: map({number, title: (.title // ""), body: (.body // ""),
        head: (.head.ref // ""), author: (.user.login // "?"),
        head_owner: (.head.repo.owner.login // .user.login // "?"),
        draft: (.draft // false)})
    }' "$WORK/pulls.json" > "$CORPUS"
}

# Sets CORPUS_STATUS (ok|truncated|unverified|failed) from a loaded corpus.
judge_corpus() {
  local fetched total inc
  fetched=$(jq -r .fetched "$CORPUS")
  total=$(jq -r '.total_count // ""' "$CORPUS")
  inc=$(jq -r '.search_incomplete // false' "$CORPUS")
  if [ -z "$total" ]; then
    CORPUS_STATUS="unverified($fetched/?)"
    [ -n "$CORPUS_NOTE" ] || CORPUS_NOTE="open-PR total was not recorded, so corpus completeness is unverified"
  elif [ "$fetched" -lt "$total" ]; then
    CORPUS_STATUS="truncated($fetched/$total)"
    CORPUS_NOTE="open-PR corpus is short: fetched $fetched of $total open PRs; a claim may be missing"
  elif [ "$inc" = true ]; then
    CORPUS_STATUS="unverified($fetched/$total)"
    CORPUS_NOTE="search reported incomplete results, so the open-PR total is not trusted"
  else
    CORPUS_STATUS="ok($fetched/$total)"
  fi
}

if [ -n "$CORPUS_IN" ]; then
  load_corpus_file "$CORPUS_IN"
  judge_corpus
  CORPUS_AGE_NOTE="open-PR corpus reused from $(jq -r .fetched_at "$CORPUS"); PRs opened since then are not in it"
else
  CORPUS_AGE_NOTE=
  fetch_corpus
  [ "$CORPUS_STATUS" = failed ] || judge_corpus
fi

if [ -n "$CORPUS_OUT" ]; then
  [ -s "$CORPUS" ] || die "no corpus to save: $CORPUS_NOTE"
  cp "$CORPUS" "$CORPUS_OUT" || die "could not write corpus file: $CORPUS_OUT"
  printf 'corpus: %s %s -> %s\n' "$REPO" "$CORPUS_STATUS" "$CORPUS_OUT"
  [ -z "$CORPUS_NOTE" ] || printf 'disclose: %s\n' "$CORPUS_NOTE"
  [ "${#ISSUES[@]}" -gt 0 ] || exit 0
fi

# --- history ref ----------------------------------------------------------

HISTORY_STATUS=
HISTORY_NOTE=

resolve_history() {
  local remote='' url norm want lower_repo default sha date
  if ! git -C "$GIT_DIR_ARG" rev-parse --git-dir >/dev/null 2>&1; then
    HISTORY_STATUS=failed
    HISTORY_NOTE="history check could not look: $GIT_DIR_ARG is not a git repository"
    return 0
  fi
  if [ -z "$REF" ]; then
    lower_repo=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
    want="github.com/$lower_repo"
    while IFS=' ' read -r name url; do
      norm=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]' | sed -e 's#\.git$##' -e 's#/$##' -e 's#^git@github\.com:#github.com/#')
      case "$norm" in
        *"://$want"|"$want"|*"@$want") remote=$name; break ;;
      esac
    done <<EOF
$(git -C "$GIT_DIR_ARG" config --get-regexp '^remote\..*\.url$' 2>/dev/null | sed -e 's/^remote\.//' -e 's/\.url / /')
EOF
    if [ -z "$remote" ]; then
      HISTORY_STATUS=failed
      HISTORY_NOTE="history check could not look: no remote of $GIT_DIR_ARG points at github.com/$REPO (pass --ref)"
      return 0
    fi
    if ! gh_read "$WORK/repo" api "repos/$REPO" \
      || ! default=$(jq -er '.default_branch | strings' "$WORK/repo" 2>/dev/null); then
      HISTORY_STATUS=failed
      HISTORY_NOTE="history check could not look: default branch of $REPO could not be read (pass --ref)"
      return 0
    fi
    REF="$remote/$default"
  fi
  if ! sha=$(git -C "$GIT_DIR_ARG" rev-parse --verify --quiet "$REF^{commit}" 2>/dev/null); then
    HISTORY_STATUS=failed
    HISTORY_NOTE="history check could not look: ref $REF does not resolve in $GIT_DIR_ARG"
    return 0
  fi
  date=$(git -C "$GIT_DIR_ARG" log -1 --format=%cs "$sha")
  HISTORY_STATUS="ok($REF@$(printf '%s' "$sha" | cut -c1-8) $date)"
}
resolve_history

# --- per-issue screen -----------------------------------------------------

# The cite rule shared by PR bodies and commit messages. It is valid in both
# jq's Oniguruma and git's POSIX ERE.
cite_pattern() {
  local n=$1
  printf '(^|[^A-Za-z0-9_/&])#%s([^0-9]|$)|(^|[^A-Za-z0-9_.-])%s#%s([^0-9]|$)|github\\.com/%s/issues/%s([^0-9]|$)' \
    "$n" "$REPO_RE" "$n" "$REPO_RE" "$n"
}

ANY_UNKNOWN=0

screen_issue() {
  local n=$1
  local d="$WORK/issue-$n" ev failed=() checks state author title labels created
  local timeline_st stamps_st corpus_st fork_st history_st pat
  mkdir -p "$d"
  ev="$d/evidence.tsv"
  : > "$ev"
  : > "$d/notes"

  # Issue itself: nothing else can be judged without it.
  if ! gh_read "$d/issue" api "repos/$REPO/issues/$n" \
    || ! jq -e '.number | numbers' "$d/issue" >/dev/null 2>&1; then
    {
      printf '=== #%s\n' "$n"
      printf 'verdict: unknown\n'
      printf 'checks: issue=failed\n'
      printf 'coverage: incomplete (issue)\n'
      printf 'disclose: issue could not be read: %s\n' "$(gh_reason "$d/issue")"
    } > "$d/block"
    printf 'unknown\n' > "$d/verdict"
    : > "$d/lines"
    ANY_UNKNOWN=1
    return 0
  fi
  if jq -e '.pull_request' "$d/issue" >/dev/null 2>&1; then
    {
      printf '=== #%s\n' "$n"
      printf 'verdict: unknown\n'
      printf 'checks: issue=pull-request\n'
      printf 'coverage: incomplete (issue)\n'
      printf 'disclose: #%s is a pull request, not an issue\n' "$n"
    } > "$d/block"
    printf 'unknown\n' > "$d/verdict"
    : > "$d/lines"
    ANY_UNKNOWN=1
    return 0
  fi
  state=$(jq -r '.state // "?"' "$d/issue")
  author=$(jq -r '.user.login // ""' "$d/issue")
  title=$(jq -r '.title // ""' "$d/issue" | one_line 100)
  labels=$(jq -r '[.labels[]? | .name] | join(",")' "$d/issue")
  created=$(jq -r '.created_at // ""' "$d/issue")
  [ "$state" = open ] || printf 'disclose: issue is %s, not open\n' "$state" >> "$d/notes"
  jq -r '[.assignees[]? | .login] | if length > 0 then "hint: assigned to " + join(",") else empty end' \
    "$d/issue" >> "$d/notes"

  # 1. timeline cross-references.
  if gh_read "$d/timeline" api "repos/$REPO/issues/$n/timeline?per_page=100" --paginate \
    && slurp_pages "$d/timeline" > "$d/timeline.json" 2>/dev/null; then
    timeline_st=ok
    jq -r --arg repo "$REPO" '
      .[] | select(.event == "cross-referenced") | .source.issue // empty
      | (.repository.full_name // "?") as $src
      | ((.title // "") | gsub("[\t\n\r]"; " ") | .[0:80]) as $t
      | if .pull_request and (($src | ascii_downcase) == ($repo | ascii_downcase)) then
          ["pr", (.number | tostring),
           (if .pull_request.merged_at then "merged"
            elif .state == "open" then (if .draft then "open(draft)" else "open" end)
            else "closed" end),
           "timeline", (.user.login // "?"), $t] | @tsv
        elif .pull_request then
          ["hint", "", "", "", "", "PR \($src)#\(.number) (\(.state)) in another repository cross-references this issue"] | @tsv
        else
          ["hint", "", "", "", "", "issue \($src)#\(.number) (\(.state)) cross-references this issue"] | @tsv
        end' "$d/timeline.json" >> "$ev"
  else
    timeline_st=failed
    failed+=(timeline)
    printf 'disclose: timeline could not be read: %s\n' "$(gh_reason "$d/timeline")" >> "$d/notes"
  fi

  # 2. maintainer triage stamps, plus prose-claim hints from the same comments.
  if gh_read "$d/comments" api "repos/$REPO/issues/$n/comments?per_page=100" --paginate \
    && slurp_pages "$d/comments" > "$d/comments.json" 2>/dev/null; then
    stamps_st=ok
    jq -r '
      .[] | (.body // "") as $b
      | (.author_association // "NONE") as $a
      | (.user.login // "?") as $u
      | ($a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR") as $maint
      | ($b | [match("<!--[ \t]*triage:[^>]*-->"; "g") | .string]) as $stamps
      | if ($stamps | length) > 0 then
          ($stamps[-1] | (capture("outcome=(?<o>[^ \t>]+)").o // "?")) as $o
          | if $maint and ($o | startswith("existing-pr")) then
              ([$b | match("existing-pr[ \t]*(->|\u2192)[ \t]*\\**#([0-9]+)"; "g") | .captures[1].string] | unique) as $prs
              | if ($prs | length) > 0 then
                  ($prs[] | ["stamp-pr", ., "", "stamp", $u, ""] | @tsv)
                else
                  ["stamp-claim", "", "", "stamp", $u, "maintainer stamp outcome=existing-pr names no PR (\(.html_url // "?"))"] | @tsv
                end
            elif $maint then
              ["hint", "", "", "", "", "maintainer stamp outcome=\($o) by \($u) (\($a)) \(.created_at // "")"] | @tsv
            else
              ["hint", "", "", "", "", "triage-style stamp outcome=\($o) by \($u) (\($a)) is not a maintainer stamp"] | @tsv
            end
        elif ($b | test("\\b(i'\''?ll|i will|i'\''?m going to|i am going to|let me) (take|pick up|work on|tackle|grab|fix)\\b|\\bworking on (this|it|a fix)\\b|\\bi'\''?m on it\\b|\\bclaim(ing)? (this|it)\\b|\\bassign (this|it) to me\\b"; "i")) then
          ["hint", "", "", "", "", "prose claim in a comment by \($u) (\(.html_url // "?")); not a verdict"] | @tsv
        else empty end' "$d/comments.json" >> "$ev"
  else
    stamps_st=failed
    failed+=(stamps)
    printf 'disclose: comments could not be read: %s\n' "$(gh_reason "$d/comments")" >> "$d/notes"
  fi

  # 3. open-PR corpus.
  corpus_st=$CORPUS_STATUS
  if [ "$CORPUS_STATUS" = failed ]; then
    failed+=(corpus)
  else
    case "$CORPUS_STATUS" in ok*) ;; *) failed+=(corpus) ;; esac
    pat=$(cite_pattern "$n")
    jq -r --arg n "$n" --arg cite "$pat" '
      ("(^|[^0-9])" + $n + "([^0-9]|$)") as $whole
      | .prs[]
      | [ (if (.body | test($cite; "i")) then "body" else empty end),
          (if (.head | test($whole)) then "branch" else empty end),
          (if (.title | test($whole)) then "title" else empty end) ] as $m
      | select(($m | length) > 0)
      | ["pr", (.number | tostring), (if .draft then "open(draft)" else "open" end),
         "corpus:" + ($m | join("+")), .author,
         ((.title | gsub("[\t\n\r]"; " ")) | .[0:80])] | @tsv' "$CORPUS" >> "$ev"
  fi
  [ -z "$CORPUS_NOTE" ] || printf 'disclose: %s\n' "$CORPUS_NOTE" >> "$d/notes"
  [ -z "$CORPUS_AGE_NOTE" ] || printf 'disclose: %s\n' "$CORPUS_AGE_NOTE" >> "$d/notes"

  # 4. the issue author's fork branches.
  if [ -z "$author" ]; then
    fork_st=failed
    failed+=(fork)
    printf 'disclose: issue author is unknown, so no fork was searched\n' >> "$d/notes"
  elif [ "$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')" ]; then
    fork_st=owner
    printf 'disclose: issue author %s owns %s, so there is no fork to search\n' "$author" "$REPO" >> "$d/notes"
  elif ! gh_read "$d/fork" api "repos/$author/$NAME"; then
    if is_404 "$d/fork"; then
      fork_st=none
      printf 'disclose: no repository %s/%s; a fork under another name is not searched\n' "$author" "$NAME" >> "$d/notes"
    else
      fork_st=failed
      failed+=(fork)
      printf 'disclose: fork %s/%s could not be read: %s\n' "$author" "$NAME" "$(gh_reason "$d/fork")" >> "$d/notes"
    fi
  elif ! jq -e --arg repo "$REPO" '.fork == true and (([.parent.full_name, .source.full_name] | map(ascii_downcase? // "")) | index($repo | ascii_downcase))' "$d/fork" >/dev/null 2>&1; then
    fork_st=not-fork
    printf 'disclose: %s/%s is not a fork of %s, so its branches were not searched\n' "$author" "$NAME" "$REPO" >> "$d/notes"
  elif gh_read "$d/branches" api "repos/$author/$NAME/branches?per_page=100" --paginate \
    && slurp_pages "$d/branches" > "$d/branches.json" 2>/dev/null; then
    fork_st=ok
    local br pulls_of
    while IFS= read -r br; do
      [ -n "$br" ] || continue
      # A branch that heads a known PR is that PR's evidence, not a new claim.
      pulls_of=$(jq -r --arg b "$br" --arg who "$author" '
        .prs[]? | select(.head == $b and (((.head_owner // .author) | ascii_downcase) == ($who | ascii_downcase)))
        | ["pr", (.number | tostring), (if .draft then "open(draft)" else "open" end), "fork", .author,
           ((.title | gsub("[\t\n\r]"; " ")) | .[0:80])] | @tsv' "$CORPUS" 2>/dev/null || true)
      if [ -z "$pulls_of" ]; then
        if gh_read "$d/headpr" api -X GET "repos/$REPO/pulls" -f head="$author:$br" -f state=all -F per_page=10 \
          && slurp_pages "$d/headpr" > "$d/headpr.json" 2>/dev/null; then
          pulls_of=$(jq -r '.[] | ["pr", (.number | tostring),
            (if .merged_at then "merged" elif .state == "open" then (if .draft then "open(draft)" else "open" end) else "closed" end),
            "fork", (.user.login // "?"), ((.title // "") | gsub("[\t\n\r]"; " ") | .[0:80])] | @tsv' "$d/headpr.json")
        else
          fork_st=partial
          failed+=(fork)
          printf 'disclose: PRs headed by %s:%s could not be read: %s\n' "$author" "$br" "$(gh_reason "$d/headpr")" >> "$d/notes"
        fi
      fi
      if [ -n "$pulls_of" ]; then
        printf '%s\n' "$pulls_of" >> "$ev"
      else
        printf 'branch\t%s:%s\t\tfork\t%s\t\n' "$author" "$br" "$author" >> "$ev"
      fi
    done <<EOF
$(jq -r --arg n "$n" '("(^|[^0-9])" + $n + "([^0-9]|$)") as $whole | .[] | .name | select(test($whole))' "$d/branches.json")
EOF
  else
    fork_st=failed
    failed+=(fork)
    printf 'disclose: fork branches of %s/%s could not be read: %s\n' "$author" "$NAME" "$(gh_reason "$d/branches")" >> "$d/notes"
  fi

  # 5. main history since the issue opened.
  history_st=$HISTORY_STATUS
  if [ "$HISTORY_STATUS" = failed ]; then
    failed+=(history)
    printf 'disclose: %s\n' "$HISTORY_NOTE" >> "$d/notes"
  else
    local since=() s sym
    [ -z "$created" ] || since=(--since="$created")
    pat=$(cite_pattern "$n")
    if git -C "$GIT_DIR_ARG" log -E --regexp-ignore-case --grep="$pat" ${since[@]+"${since[@]}"} \
        --format='%h%x09%cs %s' "$REF" > "$d/history" 2>"$d/history.err"; then
      awk -F '\t' '{ printf "commit\t%s\tmerged\thistory:cites\t\t%s\n", $1, substr($2, 1, 90) }' "$d/history" >> "$ev"
    else
      history_st=failed
      failed+=(history)
      printf 'disclose: history search failed: %s\n' "$(head -n 1 "$d/history.err" | one_line 160)" >> "$d/notes"
    fi
    for s in ${SYMBOLS[@]+"${SYMBOLS[@]}"}; do
      [ "${s%%:*}" = "$n" ] || continue
      sym=${s#*:}
      if git -C "$GIT_DIR_ARG" log -S"$sym" ${since[@]+"${since[@]}"} \
          --format='%h%x09%cs %s' "$REF" > "$d/pickaxe" 2>"$d/pickaxe.err"; then
        SYM=$sym awk -F '\t' '{ printf "commit\t%s\tmerged\thistory:-S %s\t\t%s\n", $1, ENVIRON["SYM"], substr($2, 1, 90) }' "$d/pickaxe" >> "$ev"
      else
        history_st=failed
        failed+=(history)
        printf 'disclose: history -S %s failed: %s\n' "$sym" "$(head -n 1 "$d/pickaxe.err" | one_line 160)" >> "$d/notes"
      fi
    done
  fi

  # Resolve the current state of every stamped PR not already seen.
  local x known
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    known=$(awk -F '\t' -v x="$x" '$1 == "pr" && $2 == x { print $3; exit }' "$ev")
    if [ -n "$known" ]; then
      printf 'pr\t%s\t%s\tstamp\t\t\n' "$x" "$known" >> "$ev"
    elif gh_read "$d/pr-$x" api "repos/$REPO/pulls/$x" \
      && jq -e '.number | numbers' "$d/pr-$x" >/dev/null 2>&1; then
      jq -r '["pr", (.number | tostring),
        (if .merged_at then "merged" elif .state == "open" then (if .draft then "open(draft)" else "open" end) else "closed" end),
        "stamp", (.user.login // "?"), ((.title // "") | gsub("[\t\n\r]"; " ") | .[0:80])] | @tsv' "$d/pr-$x" >> "$ev"
    else
      printf 'pr\t%s\tunknown\tstamp\t\t\n' "$x" >> "$ev"
      stamps_st=partial
      failed+=(stamps)
      printf 'disclose: stamped PR #%s could not be read: %s\n' "$x" "$(gh_reason "$d/pr-$x")" >> "$d/notes"
    fi
  done <<EOF
$(awk -F '\t' '$1 == "stamp-pr" { print $2 }' "$ev" | sort -un)
EOF

  # Aggregate evidence per item, then judge.
  awk -F '\t' '
    $1 == "pr" || $1 == "commit" || $1 == "branch" {
      k = $1 SUBSEP $2
      if (!(k in seen)) { seen[k] = 1; order[++count] = k; kind[k] = $1; id[k] = $2 }
      if ($3 != "" && (st[k] == "" || st[k] == "unknown")) st[k] = $3
      if (index("," src[k] ",", "," $4 ",") == 0) src[k] = (src[k] == "" ? $4 : src[k] "," $4)
      if (who[k] == "" && $5 != "") who[k] = $5
      if (what[k] == "" && $6 != "") what[k] = $6
    }
    $1 == "stamp-claim" { claims[++nclaims] = $6 }
    $1 == "hint" { hints[++nhints] = $6 }
    END {
      # A squash commit whose subject ends in (#X) for a PR already in evidence
      # is that PR landing; fold it in rather than listing it twice.
      for (i = 1; i <= count; i++) {
        k = order[i]
        if (kind[k] != "commit" || match(what[k], /\(#[0-9]+\)$/) == 0) continue
        pk = "pr" SUBSEP substr(what[k], RSTART + 2, RLENGTH - 3)
        if (!(pk in seen)) continue
        folded[k] = 1
        split(src[k], parts, ",")
        for (j in parts) if (index("," src[pk] ",", "," parts[j] ",") == 0) src[pk] = src[pk] "," parts[j]
        landed[pk] = (landed[pk] == "" ? "" : landed[pk] ",") id[k]
      }
      for (i = 1; i <= count; i++) {
        k = order[i]
        if (k in folded) continue
        if (kind[k] == "pr") {
          s = st[k]
          label = (s ~ /^open/ || s == "unknown") ? "claim" : (s == "merged" ? "merged" : "closed")
          line = "PR #" id[k] " " s
          if (who[k] != "") line = line " by " who[k]
          if (landed[k] != "") line = line " landed as " landed[k]
          if (what[k] != "") line = line " :: " what[k]
        } else if (kind[k] == "commit") {
          label = "merged"
          line = "commit " id[k] " " what[k]
        } else {
          label = "claim"
          line = "fork branch " id[k] " (no PR found for it)"
        }
        printf "%s: %s [%s]\n", label, line, src[k]
      }
      for (i = 1; i <= nclaims; i++) printf "claim: %s [stamp]\n", claims[i]
      for (i = 1; i <= nhints; i++) printf "hint: %s\n", hints[i]
    }' "$ev" > "$d/lines"

  local has_open=0 has_merged=0 verdict coverage uniq_failed
  ! grep -q '^claim: ' "$d/lines" || has_open=1
  ! grep -q '^merged: ' "$d/lines" || has_merged=1
  uniq_failed=$(printf '%s\n' ${failed[@]+"${failed[@]}"} | awk 'NF && !seen[$0]++' | paste -sd, -)
  if [ -n "$uniq_failed" ]; then
    coverage="incomplete ($uniq_failed)"
  else
    coverage=complete
  fi
  if [ "$has_open" = 1 ] && [ "$has_merged" = 1 ]; then
    verdict=partially-covered
  elif [ "$has_merged" = 1 ]; then
    verdict=fixed-on-main
  elif [ "$has_open" = 1 ]; then
    verdict=claimed
  elif [ -z "$uniq_failed" ]; then
    verdict=open
  else
    verdict=unknown
    ANY_UNKNOWN=1
  fi
  checks="issue=ok timeline=$timeline_st stamps=$stamps_st corpus=$corpus_st fork=$fork_st history=$history_st"

  {
    printf '=== #%s state=%s author=%s labels=%s :: %s\n' "$n" "$state" "${author:-?}" "${labels:--}" "$title"
    printf 'verdict: %s\n' "$verdict"
    printf 'checks: %s\n' "$checks"
    printf 'coverage: %s\n' "$coverage"
    grep -E '^(claim|merged|closed): ' "$d/lines" || true
    grep -E '^hint: ' "$d/lines" || true
    grep -E '^hint: ' "$d/notes" || true
    grep -E '^disclose: ' "$d/notes" || true
  } > "$d/block"
  printf '%s\n' "$verdict" > "$d/verdict"
  printf '%s\n' "$state" > "$d/state"
  printf '%s\n' "$coverage" > "$d/coverage"
}

# --- sweep ----------------------------------------------------------------

SWEEP_NOTE=
list_open_issues() {
  local total='' inc=false fetched
  if gh_read "$WORK/isearch" api "search/issues?q=repo:$REPO+is:issue+is:open&per_page=1" \
    && total=$(jq -er '.total_count | numbers' "$WORK/isearch" 2>/dev/null); then
    inc=$(jq -r '.incomplete_results // false' "$WORK/isearch")
  else
    total=
  fi
  gh_read "$WORK/issues" api "repos/$REPO/issues?state=open&per_page=100" --paginate \
    || die "open issues of $REPO could not be listed: $(gh_reason "$WORK/issues")"
  slurp_pages "$WORK/issues" > "$WORK/issues.json" 2>/dev/null \
    || die "open issues of $REPO were not JSON pages"
  jq -r '.[] | select(.pull_request | not) | .number' "$WORK/issues.json" > "$WORK/issue-numbers"
  fetched=$(wc -l < "$WORK/issue-numbers" | tr -d ' ')
  if [ -z "$total" ]; then
    SWEEP_NOTE="open-issue total could not be read: $(gh_reason "$WORK/isearch"); the list of $fetched may be short"
  elif [ "$fetched" -lt "$total" ]; then
    SWEEP_NOTE="open-issue list is short: listed $fetched of $total; unlisted issues were not screened"
  elif [ "$inc" = true ]; then
    SWEEP_NOTE="search reported incomplete results, so the open-issue total of $total is not trusted"
  fi
  while IFS= read -r n; do
    [ -z "$n" ] || ISSUES+=("$n")
  done < "$WORK/issue-numbers"
}

# sweep_line <n>: one disposition line from the stored screen of issue <n>.
sweep_line() {
  local n=$1
  local d="$WORK/issue-$n" verdict state coverage disposition link evidence
  verdict=$(cat "$d/verdict")
  state=$(cat "$d/state" 2>/dev/null || printf '?')
  coverage=$(cat "$d/coverage" 2>/dev/null || printf 'incomplete')
  case "$coverage" in complete) ;; *) coverage=incomplete ;; esac
  if [ "$verdict" = unknown ]; then
    disposition=undetermined
  elif [ "$state" != open ]; then
    disposition=no-action
  else
    case "$verdict" in
      claimed|partially-covered) disposition=leave-open ;;
      open) disposition=no-action ;;
      fixed-on-main)
        if [ "$coverage" = complete ]; then disposition=close-candidate; else disposition=undetermined; fi ;;
      *) disposition=undetermined ;;
    esac
  fi
  link=$(awk '
    /^(claim|merged): / {
      src = $0; sub(/.*\[/, "", src); sub(/\]$/, "", src)
      if (src ~ /(^|,)(timeline|stamp)(,|$)/) next
      if (src !~ /corpus:[^,]*body|history:cites/) next
      item = $0; sub(/^[a-z]+: /, "", item); split(item, w, " ")
      out = out (out == "" ? "" : ",") w[2]
    }
    END { print (out == "" ? "-" : out) }' "$d/lines")
  evidence=$(awk '
    /^(claim|merged): / {
      item = $0; sub(/ ::.*\[/, " [", item); sub(/ by [^ ]+/, "", item)
      out = out (out == "" ? "" : "; ") item
    }
    END { print (out == "" ? "-" : out) }' "$d/lines")
  printf 'sweep: #%s %s state=%s verdict=%s coverage=%s link=%s evidence=%s\n' \
    "$n" "$disposition" "$state" "$verdict" "$coverage" "$link" "$evidence"
}

[ "$SWEEP_ALL" = 0 ] || list_open_issues

for n in ${ISSUES[@]+"${ISSUES[@]}"}; do
  screen_issue "$n"
  if [ "$SWEEP" = 1 ]; then
    sweep_line "$n"
  else
    cat "$WORK/issue-$n/block"
    printf '\n'
  fi
done

if [ "$SWEEP" = 1 ]; then
  [ -z "$SWEEP_NOTE" ] || printf 'disclose: %s\n' "$SWEEP_NOTE"
  [ -z "$CORPUS_NOTE" ] || printf 'disclose: %s\n' "$CORPUS_NOTE"
  [ -z "$CORPUS_AGE_NOTE" ] || printf 'disclose: %s\n' "$CORPUS_AGE_NOTE"
  [ "$HISTORY_STATUS" != failed ] || printf 'disclose: %s\n' "$HISTORY_NOTE"
  printf 'sweep: %s issue(s) screened; nothing was written to the forge - no issue closed, labelled, or commented on\n' \
    "${#ISSUES[@]}"
fi

[ "$ANY_UNKNOWN" = 0 ] || exit 1
exit 0
