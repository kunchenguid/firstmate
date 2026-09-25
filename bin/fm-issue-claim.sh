#!/usr/bin/env bash
# Screen GitHub issues for an existing claim or fix before work is spent on one.
#
# Limits, first: this command closes, labels, and comments on nothing - every
# forge call is a read, including in --sweep - and it never fetches into the
# local clone. Work with no issue reference, discoverable PR or fork branch,
# commit citation, or caller-supplied --symbol stays invisible to these checks.
# It is the evidence half of claim hygiene, not
# governance: acting on a verdict stays with the caller and the forge's own
# policy, and it reads and writes no backlog.
#
# Usage:
#   fm-issue-claim.sh --repo <owner/name> [options] <issue>...
#   fm-issue-claim.sh --repo <owner/name> --sweep [options] [<issue>...]
#
# Options:
#   --git-dir <dir>      local clone searched by the history check (default: .)
#   --ref <ref>          history ref (default: <remote>/<default-branch>, where
#                        <remote> is the clone's remote whose URL names the repo)
#   --symbol <n>:<text>  also search history for commits adding or removing
#                        <text> (git log -S) for issue <n>; repeatable;
#                        report matches as suspected fixes to verify
#   --sweep              opt-in, report-only: print one disposition line per
#                        issue instead of the evidence block; with no issue
#                        numbers it screens every open issue of the repo
#   --if-enabled         screen only when this home has opted in with the
#                        config/issue-claim-screen presence flag; otherwise
#                        exit 0 with no output and no forge or git read. This
#                        is the form workflows such as Bearings call, so an
#                        unconfigured home never runs the screen. Without it
#                        an explicit operator invocation always screens.
#                        FM_HOME and FM_CONFIG_OVERRIDE resolve the config
#                        directory exactly as the other bin/ scripts do.
#
# Each issue runs five checks, and one open-PR corpus is shared by every issue
# in the run:
#   timeline  cross-referenced events (GET issues/<n>/timeline): a pull request
#             in this repository that is open or merged; a cross-reference
#             from an issue or another repository is only a hint. Development
#             links are resolved through GraphQL connected/disconnected events;
#             the latest event for each linked item applies. Active links to
#             open PRs are claims, including across repositories. Unresolved
#             events or linked PRs make timeline coverage incomplete.
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
#             4018 never matches 40181. PR numbers are deduplicated; duplicates,
#             a unique count different from the search total, or a total that
#             changes across the fetch make coverage unverified.
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
#   checks: issue=.. timeline=.. stamps=.. corpus=.. fork=.. history=.. prs=..
#           issues=.. (when sweeping the open-issue list)
#   coverage: complete | incomplete (<checks that could not look>)
#   claim: / merged: / closed: <evidence> [<checks that found it>]
#   hint: / disclose: <context that never decides a verdict>
# Verdicts:
#   claimed            an open or draft PR, a fork branch, or a maintainer
#                      existing-pr stamp claims the issue; no merged fix found.
#   partially-covered  merged fixing evidence exists and an open claim remains.
#   fixed-on-main      fixing evidence and no open claim: a history-ref commit
#                      with a closing keyword naming this issue, or a PR merged
#                      into the repository's default branch whose body has such
#                      a keyword or whose GitHub closingIssuesReferences include
#                      this issue. It is not proof that every part is resolved.
#   open               every check looked and found no claim or fixing evidence.
#   unknown            the issue could not be read, or nothing was found while
#                      at least one check could not look. A failed or
#                      rate-limited read never yields open.
# A positive verdict reached with incomplete coverage keeps its verdict and
# says so on its coverage line.
# Closing keywords are close/closes/closed, fix/fixes/fixed, and
# resolve/resolves/resolved, followed by #<n>, owner/name#<n>, or the issue URL
# in this repository; case and an optional colon are ignored.
# Every discovered merged PR in this repository has its current state and
# base.ref resolved before classification. Other-base merges name their base
# in a hint. When a default-base merged PR has no closing keyword, a read-only
# GraphQL query checks its closingIssuesReferences. Failed lookups make
# coverage incomplete.
# Incidental PR references and commit citations are hints. Symbol matches are
# labelled "suspected fix to verify" and never establish a fix on their own.
#
# --sweep prints, per issue:
#   sweep: #<n> <disposition> state=<s> verdict=<v> coverage=<complete|incomplete>
#          link=<items|-> evidence=<items|->
# evidence= includes claim:, merged:, and hint: items with their labels;
# hints remain inspection context and never determine link= or disposition.
# Dispositions, judged only from fixing evidence and live claims, never from
# PR checks, reviews, or mergeability, which stay forge-owned:
#   close-candidate  fixed-on-main with complete coverage.
#   leave-open       any open claim remains, including every issue with a live
#                    PR stamped existing-pr; never a close candidate.
#   no-action        verdict open, or the issue is no longer open.
#   undetermined     verdict unknown, or merged evidence with incomplete
#                    coverage that could hide a live claim.
# link= names fixing evidence the issue page does not show: a PR whose body
# has a fixing reference, a merged PR with a closing-issue reference, or a
# commit whose message has a fixing reference, found by neither the
# timeline nor a stamp. A title, branch, fork-branch, or --symbol match alone
# supplies no linking evidence. Screening shares one fresh PR corpus; merged
# and stamped PRs need additional reads. The open-issue list uses the same
# identity and total checks as the corpus; an unverified list prevents open
# verdicts and close recommendations and makes the sweep exit 1.
#
# Exit status: 0 when every issue got a verdict other than unknown and the
# sweep list is verified, 1 for unknown verdicts or an unverified sweep list,
# 2 on a usage/setup refusal or failure to fetch the sweep's open-issue list.
#
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
SWEEP=0
IF_ENABLED=0
ISSUES=()
SYMBOLS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) [ "$#" -ge 2 ] || die "--repo needs <owner/name>"; REPO=$2; shift 2 ;;
    --git-dir) [ "$#" -ge 2 ] || die "--git-dir needs a directory"; GIT_DIR_ARG=$2; shift 2 ;;
    --ref) [ "$#" -ge 2 ] || die "--ref needs a ref"; REF=$2; shift 2 ;;
    --symbol) [ "$#" -ge 2 ] || die "--symbol needs <n>:<text>"; SYMBOLS+=("$2"); shift 2 ;;
    --sweep) SWEEP=1; shift ;;
    --if-enabled) IF_ENABLED=1; shift ;;
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
[ "${#ISSUES[@]}" -gt 0 ] || [ "$SWEEP" = 1 ] \
  || die "name at least one issue number or --sweep"
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
if [ "$IF_ENABLED" = 1 ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
  FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  [ -e "$CONFIG/issue-claim-screen" ] || exit 0
fi
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

fetch_list() {
  local kind=$1 endpoint=$2 out=$3 label=$4 before='' after='' inc_before=true inc_after=true rows fetched
  LIST_NOTE=
  if gh_read "$out.before" api "search/issues?q=repo:$REPO+is:$kind+is:open&per_page=1" \
    && before=$(jq -er '.total_count | numbers' "$out.before" 2>/dev/null); then
    inc_before=$(jq -r '.incomplete_results // false' "$out.before")
  fi
  if ! gh_read "$out.pages" api "$endpoint" --paginate; then
    LIST_STATUS=failed
    LIST_NOTE="$label could not be fetched: $(gh_reason "$out.pages")"
    return 0
  fi
  if ! slurp_pages "$out.pages" > "$out.rows" 2>/dev/null; then
    LIST_STATUS=failed
    LIST_NOTE="$label pages were not JSON arrays"
    return 0
  fi
  if gh_read "$out.after" api "search/issues?q=repo:$REPO+is:$kind+is:open&per_page=1" \
    && after=$(jq -er '.total_count | numbers' "$out.after" 2>/dev/null); then
    inc_after=$(jq -r '.incomplete_results // false' "$out.after")
  fi
  jq --arg kind "$kind" '
    (if $kind == "issue" then map(select(.pull_request | not)) else . end)
    | {rows: length, items: unique_by(.number)} | . + {fetched: (.items | length)}
  ' "$out.rows" > "$out"
  rows=$(jq -r .rows "$out")
  fetched=$(jq -r .fetched "$out")
  if [ -z "$before" ] || [ -z "$after" ] || [ "$rows" != "$fetched" ] \
    || [ "$fetched" != "$before" ] || [ "$before" != "$after" ] \
    || [ "$inc_before" = true ] || [ "$inc_after" = true ]; then
    LIST_STATUS="unverified($fetched/${before:-?})"
    LIST_NOTE="$label unverified: $rows rows, $fetched unique, totals ${before:-?} -> ${after:-?}; duplicates, inconsistent counts, or incomplete search results may hide work"
  else
    LIST_STATUS="ok($fetched/$before)"
  fi
}

fetch_corpus() {
  fetch_list pr "repos/$REPO/pulls?state=open&per_page=100" "$WORK/pulls.json" "open-PR corpus"
  CORPUS_STATUS=$LIST_STATUS
  CORPUS_NOTE=$LIST_NOTE
  [ "$CORPUS_STATUS" != failed ] || return 0
  jq '{prs: (.items | map({number, title: (.title // ""), body: (.body // ""),
    head: (.head.ref // ""), author: (.user.login // "?"),
    head_owner: (.head.repo.owner.login // .user.login // "?"),
    draft: (.draft // false)}))}' "$WORK/pulls.json" > "$CORPUS"
}

fetch_corpus

DEFAULT_BRANCH=
if ! gh_read "$WORK/repo" api "repos/$REPO" \
  || ! DEFAULT_BRANCH=$(jq -er '.default_branch | strings | select(length > 0)' "$WORK/repo" 2>/dev/null); then
  DEFAULT_BRANCH=
fi

# --- history ref ----------------------------------------------------------

HISTORY_STATUS=
HISTORY_NOTE=

resolve_history() {
  local remote='' url norm want lower_repo sha date
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
    if [ -z "$DEFAULT_BRANCH" ]; then
      HISTORY_STATUS=failed
      HISTORY_NOTE="history check could not look: default branch of $REPO could not be read (pass --ref)"
      return 0
    fi
    REF="$remote/$DEFAULT_BRANCH"
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

fix_pattern() {
  local n=$1
  printf '(^|[^A-Za-z0-9_])(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+(#%s|%s#%s|https?://github\\.com/%s/issues/%s)([^0-9]|$)' \
    "$n" "$REPO_RE" "$n" "$REPO_RE" "$n"
}

ANY_UNKNOWN=0

screen_issue() {
  local n=$1
  local d="$WORK/issue-$n" ev failed=() checks state author title labels created
  local timeline_st stamps_st corpus_st fork_st history_st pat fixpat
  fixpat=$(fix_pattern "$n")
  mkdir -p "$d"
  ev="$d/evidence.tsv"
  : > "$ev"
  : > "$d/notes"
  if [ "$SWEEP_ALL" = 1 ] && [ -n "$SWEEP_NOTE" ]; then
    failed+=(issues)
    printf 'disclose: %s\n' "$SWEEP_NOTE" >> "$d/notes"
  fi

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
    jq -r --arg repo "$REPO" --arg fix "$fixpat" '
      .[] | select(.event == "cross-referenced") | .source.issue // empty
      | (.repository.full_name // "?") as $src
      | ((.title // "") | gsub("[\t\n\r]"; " ") | .[0:80]) as $t
      | if .pull_request and (($src | ascii_downcase) == ($repo | ascii_downcase)) then
          ["pr", (.number | tostring),
           (if .pull_request.merged_at then "merged"
            elif .state == "open" then (if .draft then "open(draft)" else "open" end)
            else "closed" end),
           "timeline", (.user.login // "?"), $t,
           ((.body // "") | test($fix; "i"))] | @tsv
        elif .pull_request then
          ["hint", "", "", "", "", "PR \($src)#\(.number) (\(.state)) in another repository cross-references this issue"] | @tsv
        else
          ["hint", "", "", "", "", "issue \($src)#\(.number) (\(.state)) cross-references this issue"] | @tsv
        end' "$d/timeline.json" >> "$ev"
    if jq -e 'any(.[]; .event == "connected" or .event == "disconnected")' "$d/timeline.json" >/dev/null; then
      # shellcheck disable=SC2016 # Dollar signs are literal GraphQL variables.
      if gh_read "$d/links" api graphql --paginate -f owner="$OWNER" -f name="$NAME" -F number="$n" -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
        repository(owner: $owner, name: $name) { issue(number: $number) {
          timelineItems(first: 100, after: $endCursor, itemTypes: [CONNECTED_EVENT, DISCONNECTED_EVENT]) {
            nodes {
              __typename
              ... on ConnectedEvent { id createdAt source { ...linkedSubject } subject { ...linkedSubject } }
              ... on DisconnectedEvent { id createdAt source { ...linkedSubject } subject { ...linkedSubject } }
            }
            pageInfo { hasNextPage endCursor }
          }
        } }
      }
      fragment linkedSubject on ReferencedSubject {
        __typename
        ... on Issue { number repository { nameWithOwner } }
        ... on PullRequest { number repository { nameWithOwner } state isDraft }
      }' \
        && jq -sr --arg repo "$REPO" --argjson n "$n" --slurpfile timeline "$d/timeline.json" '
          def this_issue: .__typename == "Issue" and .number == $n
            and ((.repository.nameWithOwner | ascii_downcase) == ($repo | ascii_downcase));
          if length == 0 or any(.[];
            ((.errors // []) | length) > 0
            or (.data.repository.issue.timelineItems.nodes | type) != "array"
            or (.data.repository.issue.timelineItems.pageInfo.hasNextPage | type) != "boolean")
            or .[-1].data.repository.issue.timelineItems.pageInfo.hasNextPage != false
          then error("incomplete Development links")
          else [.[].data.repository.issue.timelineItems.nodes[]] end
          | . as $events
          | if any($timeline[0][] | select(.event == "connected" or .event == "disconnected");
              .node_id as $id | ($id | type) != "string" or all($events[]; .id != $id))
            then error("unresolved Development event") else . end
          | map(
              if (.__typename != "ConnectedEvent" and .__typename != "DisconnectedEvent")
                or (.createdAt | type) != "string" then error("invalid Development event") else . end
              | .peer = (if (.source | this_issue) then .subject
                  elif (.subject | this_issue) then .source else error("unresolved Development endpoint") end)
              | if (.peer.number | type) != "number" or (.peer.repository.nameWithOwner | type) != "string"
                  or (.peer.__typename != "Issue" and .peer.__typename != "PullRequest")
                  or (.peer.__typename == "PullRequest" and (.peer.state != "OPEN" and .peer.state != "CLOSED" and .peer.state != "MERGED"))
                then error("unresolved Development subject") else . end)
          | sort_by(.createdAt)
          | reduce .[] as $e ({};
              .[($e.peer | "\(.__typename):\(.repository.nameWithOwner | ascii_downcase)#\(.number)")] = $e)
          | .[] | select(.__typename == "ConnectedEvent") | .peer
          | if .__typename == "PullRequest" and ((.repository.nameWithOwner | ascii_downcase) == ($repo | ascii_downcase)) then
              ["pr", (.number | tostring), "unknown", "timeline", "", ""]
            else
              [(if .__typename == "PullRequest" and .state == "OPEN" then "claim" else "hint" end),
               "", "", "timeline", "",
               "\(if .__typename == "PullRequest" then "PR" else "issue" end) \(.repository.nameWithOwner)#\(.number)\(if .state then " " + (.state | ascii_downcase) + (if .state == "OPEN" and .isDraft then "(draft)" else "" end) else "" end) linked through Development"]
            end | @tsv
        ' "$d/links" > "$d/links.tsv" 2>/dev/null; then
        cat "$d/links.tsv" >> "$ev"
      else
        timeline_st=partial
        failed+=(timeline)
        printf 'disclose: Development links could not be resolved: %s\n' "$(gh_reason "$d/links")" >> "$d/notes"
      fi
    fi
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
                  ["claim", "", "", "stamp", $u, "maintainer stamp outcome=existing-pr names no PR (\(.html_url // "?"))"] | @tsv
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
    jq -r --arg n "$n" --arg cite "$pat" --arg fix "$fixpat" '
      ("(^|[^0-9])" + $n + "([^0-9]|$)") as $whole
      | .prs[]
      | [ (if (.body | test($cite; "i")) then "body" else empty end),
          (if (.head | test($whole)) then "branch" else empty end),
          (if (.title | test($whole)) then "title" else empty end) ] as $m
      | select(($m | length) > 0)
      | ["pr", (.number | tostring), (if .draft then "open(draft)" else "open" end),
         "corpus:" + ($m | join("+")), .author,
         ((.title | gsub("[\t\n\r]"; " ")) | .[0:80]),
         (.body | test($fix; "i"))] | @tsv' "$CORPUS" >> "$ev"
  fi
  [ -z "$CORPUS_NOTE" ] || printf 'disclose: %s\n' "$CORPUS_NOTE" >> "$d/notes"

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
      pulls_of=$(jq -r --arg b "$br" --arg who "$author" --arg fix "$fixpat" '
        .prs[]? | select(.head == $b and (((.head_owner // .author) | ascii_downcase) == ($who | ascii_downcase)))
        | ["pr", (.number | tostring), (if .draft then "open(draft)" else "open" end), "fork", .author,
           ((.title | gsub("[\t\n\r]"; " ")) | .[0:80]),
           (.body | test($fix; "i"))] | @tsv' "$CORPUS" 2>/dev/null || true)
      if [ -z "$pulls_of" ]; then
        if gh_read "$d/headpr" api -X GET "repos/$REPO/pulls" -f head="$author:$br" -f state=all -F per_page=10 \
          && slurp_pages "$d/headpr" > "$d/headpr.json" 2>/dev/null; then
          pulls_of=$(jq -r --arg fix "$fixpat" '.[] | ["pr", (.number | tostring),
            (if .merged_at then "merged" elif .state == "open" then (if .draft then "open(draft)" else "open" end) else "closed" end),
            "fork", (.user.login // "?"), ((.title // "") | gsub("[\t\n\r]"; " ") | .[0:80]),
            ((.body // "") | test($fix; "i"))] | @tsv' "$d/headpr.json")
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
    local since=() s sym match_kind
    [ -z "$created" ] || since=(--since="$created")
    for match_kind in cites fixes; do
      if [ "$match_kind" = fixes ]; then pat=$fixpat; else pat=$(cite_pattern "$n"); fi
      if git -C "$GIT_DIR_ARG" log -E --regexp-ignore-case --grep="$pat" ${since[@]+"${since[@]}"} \
          --format='%h%x09%cs %s' "$REF" > "$d/history" 2>"$d/history.err"; then
        awk -F '\t' -v kind="$match_kind" '{ printf "commit\t%s\tmerged\thistory:%s\t\t%s\t%s\n", $1, kind, substr($2, 1, 90), (kind == "fixes" ? "true" : "false") }' "$d/history" >> "$ev"
      else
        history_st=failed
        failed+=(history)
        printf 'disclose: history search failed: %s\n' "$(head -n 1 "$d/history.err" | one_line 160)" >> "$d/notes"
      fi
    done
    for s in ${SYMBOLS[@]+"${SYMBOLS[@]}"}; do
      [ "${s%%:*}" = "$n" ] || continue
      sym=${s#*:}
      if git -C "$GIT_DIR_ARG" log -S"$sym" ${since[@]+"${since[@]}"} \
          --format='%h%x09%cs %s' "$REF" > "$d/pickaxe" 2>"$d/pickaxe.err"; then
        SYM=$sym awk -F '\t' '{ printf "hint\t\t\t\t\tsuspected fix to verify: commit %s %s [history:-S %s]\n", $1, substr($2, 1, 90), ENVIRON["SYM"] }' "$d/pickaxe" >> "$ev"
      else
        history_st=failed
        failed+=(history)
        printf 'disclose: history -S %s failed: %s\n' "$sym" "$(head -n 1 "$d/pickaxe.err" | one_line 160)" >> "$d/notes"
      fi
    done
  fi

  local x
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    printf 'pr\t%s\tunknown\tstamp\t\t\n' "$x" >> "$ev"
  done <<EOF
$(awk -F '\t' '$1 == "stamp-pr" { print $2 }' "$ev" | sort -un)
EOF

  local prs_st=ok pr_state pr_base pr_fix
  : > "$d/resolved-prs"
  while IFS= read -r x; do
    [ -n "$x" ] || continue
    if gh_read "$d/pr-$x" api "repos/$REPO/pulls/$x" \
      && jq -e --argjson x "$x" '.number == $x and (.state == "open" or .state == "closed")' "$d/pr-$x" >/dev/null 2>&1; then
      pr_state=$(jq -r 'if .merged_at then "merged" elif .state == "open" then (if .draft then "open(draft)" else "open" end) else "closed" end' "$d/pr-$x")
      pr_fix=false
      pr_base=
      if [ "$pr_state" = merged ]; then
        if ! pr_base=$(jq -er '.base.ref | strings | select(length > 0)' "$d/pr-$x" 2>/dev/null) \
          || [ -z "$DEFAULT_BRANCH" ]; then
          prs_st=partial
          failed+=(prs)
          printf 'disclose: merged PR #%s base or repository default branch could not be read\n' "$x" >> "$d/notes"
        elif [ "$pr_base" = "$DEFAULT_BRANCH" ]; then
          if jq -e --arg fix "$fixpat" '(.body // "") | test($fix; "i")' "$d/pr-$x" >/dev/null; then
            pr_fix=true
          elif
            # shellcheck disable=SC2016 # Dollar signs are literal GraphQL variables.
            gh_read "$d/closing-$x" api graphql --paginate -f owner="$OWNER" -f name="$NAME" -F number="$x" -f query='query($owner: String!, $name: String!, $number: Int!, $endCursor: String) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { closingIssuesReferences(first: 100, after: $endCursor) { nodes { number repository { nameWithOwner } } pageInfo { hasNextPage endCursor } } } } }' \
            && pr_fix=$(jq -sr --argjson n "$n" --arg repo "$REPO" '
              if length == 0 or any(.[];
                ((.errors // []) | length) > 0
                or (.data.repository.pullRequest.closingIssuesReferences.nodes | type) != "array"
                or (.data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage | type) != "boolean")
                or .[-1].data.repository.pullRequest.closingIssuesReferences.pageInfo.hasNextPage != false
              then error("incomplete closing-issue references")
              else any(.[].data.repository.pullRequest.closingIssuesReferences.nodes[];
                .number == $n and ((.repository.nameWithOwner | ascii_downcase) == ($repo | ascii_downcase))) end
            ' "$d/closing-$x" 2>/dev/null); then
            :
          else
            pr_fix=false
            prs_st=partial
            failed+=(prs)
            printf 'disclose: PR #%s closing-issue references could not be read: %s\n' "$x" "$(gh_reason "$d/closing-$x")" >> "$d/notes"
          fi
        fi
      elif [ "$pr_state" != closed ]; then
        pr_fix=$(jq -r --arg fix "$fixpat" '(.body // "") | test($fix; "i")' "$d/pr-$x")
      fi
      jq -r --arg state "$pr_state" --arg fix "$pr_fix" --arg base "$pr_base" '
        [(.number | tostring), $state, $fix, $base, (.user.login // "?"),
         ((.title // "") | gsub("[\t\n\r]"; " ") | .[0:80])] | @tsv
      ' "$d/pr-$x" >> "$d/resolved-prs"
    else
      printf '%s\tunknown\tfalse\t\t\t\n' "$x" >> "$d/resolved-prs"
      prs_st=partial
      failed+=(prs)
      if awk -F '\t' -v x="$x" '$1 == "pr" && $2 == x && $4 == "stamp" { found=1 } END { exit !found }' "$ev"; then
        stamps_st=partial
        failed+=(stamps)
      fi
      if awk -F '\t' -v x="$x" '$1 == "pr" && $2 == x && $3 == "unknown" && $4 == "timeline" { found=1 } END { exit !found }' "$ev"; then
        timeline_st=partial
        failed+=(timeline)
      fi
      printf 'disclose: PR #%s could not be read: %s\n' "$x" "$(gh_reason "$d/pr-$x")" >> "$d/notes"
    fi
  done <<EOF
$(awk -F '\t' '$1 == "pr" && ($3 == "merged" || $3 == "unknown") { print $2 }' "$ev" | sort -un)
EOF

  # Aggregate evidence per item, then judge.
  awk -F '\t' '
    FILENAME == ARGV[1] {
      resolved_state[$1] = $2; resolved_fix[$1] = $3; resolved_base[$1] = $4
      resolved_who[$1] = $5; resolved_what[$1] = $6
      next
    }
    $1 == "pr" || $1 == "commit" || $1 == "branch" {
      if ($1 == "pr" && ($2 in resolved_state)) {
        $3 = resolved_state[$2]; $7 = resolved_fix[$2]
        if ($5 == "") $5 = resolved_who[$2]
        if ($6 == "") $6 = resolved_what[$2]
      }
      k = $1 SUBSEP $2
      if (!(k in seen)) { seen[k] = 1; order[++count] = k; kind[k] = $1; id[k] = $2 }
      if ($3 != "" && (st[k] == "" || st[k] == "unknown")) st[k] = $3
      if (index("," src[k] ",", "," $4 ",") == 0) src[k] = (src[k] == "" ? $4 : src[k] "," $4)
      if (who[k] == "" && $5 != "") who[k] = $5
      if (what[k] == "" && $6 != "") what[k] = $6
      if ($7 == "true") fixing[k] = 1
    }
    $1 == "claim" { claims[++nclaims] = $6 " [" $4 "]" }
    $1 == "hint" { hints[++nhints] = $6 }
    END {
      for (i = 1; i <= count; i++) {
        k = order[i]
        if (kind[k] == "pr") {
          s = st[k]
          label = (s ~ /^open/ || (s == "unknown" && src[k] ~ /(^|,)stamp(,|$)/)) ? "claim" : (s == "merged" ? (fixing[k] ? "merged" : "hint") : (s == "closed" ? "closed" : "hint"))
          line = "PR #" id[k] " " s
          if (resolved_base[id[k]] != "") line = line " base=" resolved_base[id[k]]
          if (who[k] != "") line = line " by " who[k]
          if (what[k] != "") line = line " :: " what[k]
        } else if (kind[k] == "commit") {
          label = fixing[k] ? "merged" : "hint"
          line = "commit " id[k] " " what[k]
        } else {
          label = "claim"
          line = "fork branch " id[k] " (no PR found for it)"
        }
        printf "%s: %s [%s%s]\n", label, line, src[k], (fixing[k] ? ",fixes" : "")
      }
      for (i = 1; i <= nclaims; i++) printf "claim: %s\n", claims[i]
      for (i = 1; i <= nhints; i++) printf "hint: %s\n", hints[i]
    }' "$d/resolved-prs" "$ev" > "$d/lines"

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
  checks="issue=ok timeline=$timeline_st stamps=$stamps_st corpus=$corpus_st fork=$fork_st history=$history_st prs=$prs_st"
  [ "$SWEEP_ALL" = 0 ] || checks="$checks issues=$ISSUE_LIST_STATUS"

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
ISSUE_LIST_STATUS=
list_open_issues() {
  fetch_list issue "repos/$REPO/issues?state=open&per_page=100" "$WORK/issues.json" "open-issue list"
  ISSUE_LIST_STATUS=$LIST_STATUS
  SWEEP_NOTE=$LIST_NOTE
  [ "$ISSUE_LIST_STATUS" != failed ] || die "$SWEEP_NOTE"
  [ -z "$SWEEP_NOTE" ] || ANY_UNKNOWN=1
  jq -r '.items[].number' "$WORK/issues.json" > "$WORK/issue-numbers"
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
      if (src !~ /(^|,)fixes(,|$)/) next
      item = $0; sub(/^[a-z]+: /, "", item); split(item, w, " ")
      out = out (out == "" ? "" : ",") w[2]
    }
    END { print (out == "" ? "-" : out) }' "$d/lines")
  evidence=$(awk '
    /^(claim|merged|hint): / {
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
  [ "$HISTORY_STATUS" != failed ] || printf 'disclose: %s\n' "$HISTORY_NOTE"
  printf 'sweep: %s issue(s) screened; nothing was written to the forge - no issue closed, labelled, or commented on\n' \
    "${#ISSUES[@]}"
fi

[ "$ANY_UNKNOWN" = 0 ] || exit 1
exit 0
