#!/usr/bin/env bash
# fm-pr-ready-bucket.sh - read-only listing of MemberOS (or --repo) open PRs
# grouped for the next bors rollup.
#
# GitHub is the ready-bucket. This helper never scrapes a Bors dashboard,
# never writes to GitHub, and never merges, comments, or reviews.
#
# Groups:
#   ready    MERGEABLE, targeting --base (default main), not draft, not
#            release/release-please, every required Depot + title/body lint
#            check green, no review-blocker label, no CHANGES_REQUESTED,
#            not stacked
#   blocked  conflicts, red required CI, review-blocker, CHANGES_REQUESTED,
#            or still-truncated nested GitHub state after paging (main-
#            targeting non-draft non-release PRs only)
#   stacked  open PR whose base is not --base
#   in-Bors  open rollup PRs authored by bors-ci-merge-queue (optional [bot]
#            suffix) or PRs with a GitHub comment from that bot (or Homu
#            bors[bot]) that marks approved / queued / trying / rollup
#
# Drafts and release-please PRs targeting --base are omitted unless they
# already match stacked or in-Bors. Pending required CI is omitted rather
# than treated as blocked.
#
# Usage:
#   fm-pr-ready-bucket.sh [--repo OWNER/NAME] [--base BRANCH]
#                        [--required-check NAME]... [--json]
#   fm-pr-ready-bucket.sh --help
#
# Default --repo is Chamber-Hero/memberos.
# Default --base is main.
# --repo or --base other than those defaults requires --required-check,
# so a different forge target cannot silently keep the MemberOS main list.
# Nested label, check, and comment connections are paged to completion.
# A still-truncated connection after the page bound is never classified
# ready (blocked: incomplete GitHub state).
# Required checks (MemberOS main ruleset: Depot CI + title/body lint):
#   CI (Depot) / lint
#   CI (Depot) / typecheck
#   CI (Depot) / build
#   CI (Depot) / guardrails
#   CI (Depot) / test
#   CI (Depot) / cli-test
#   CI (Depot) / quality
#   CI (Depot) / edge-test
#   PR Title Lint (Depot) / pr-title-lint
#   PR Body Lint (Depot) / pr-body-lint
set -eu
set -o pipefail

DEFAULT_REPO=Chamber-Hero/memberos
DEFAULT_BASE=main
PAGE_SIZE=50
MAX_PAGES=20
NESTED_PAGE_SIZE=100
MAX_NESTED_PAGES=${FM_PR_READY_BUCKET_MAX_NESTED_PAGES:-20}

MEMBEROS_REQUIRED_CHECKS_JSON='[
  "CI (Depot) / lint",
  "CI (Depot) / typecheck",
  "CI (Depot) / build",
  "CI (Depot) / guardrails",
  "CI (Depot) / test",
  "CI (Depot) / cli-test",
  "CI (Depot) / quality",
  "CI (Depot) / edge-test",
  "PR Title Lint (Depot) / pr-title-lint",
  "PR Body Lint (Depot) / pr-body-lint"
]'

# shellcheck disable=SC2016 # GraphQL $variables are for GitHub, not the shell.
GQL_QUERY='query ReadyBucketPulls($owner:String!,$name:String!,$after:String,$pageSize:Int!){ repository(owner:$owner,name:$name){ pullRequests(first:$pageSize,states:OPEN,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}){ pageInfo{hasNextPage endCursor} nodes{ number title url isDraft mergeable baseRefName headRefName author{login} reviewDecision labels(first:100){pageInfo{hasNextPage endCursor} nodes{name}} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:100){pageInfo{hasNextPage endCursor} nodes{... on CheckRun{name conclusion status} ... on StatusContext{context state}}}}}}} comments(last:100){pageInfo{hasPreviousPage startCursor} nodes{author{login} body}} } } } }'

# shellcheck disable=SC2016 # GraphQL $variables are for GitHub, not the shell.
GQL_LABELS_QUERY='query ReadyBucketLabels($owner:String!,$name:String!,$number:Int!,$after:String,$pageSize:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$number){ labels(first:$pageSize,after:$after){ pageInfo{hasNextPage endCursor} nodes{name} } } } }'

# shellcheck disable=SC2016 # GraphQL $variables are for GitHub, not the shell.
GQL_CHECKS_QUERY='query ReadyBucketChecks($owner:String!,$name:String!,$number:Int!,$after:String,$pageSize:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$number){ commits(last:1){ nodes{ commit{ statusCheckRollup{ contexts(first:$pageSize,after:$after){ pageInfo{hasNextPage endCursor} nodes{... on CheckRun{name conclusion status} ... on StatusContext{context state}} } } } } } } } }'

# shellcheck disable=SC2016 # GraphQL $variables are for GitHub, not the shell.
GQL_COMMENTS_QUERY='query ReadyBucketComments($owner:String!,$name:String!,$number:Int!,$before:String,$pageSize:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$number){ comments(last:$pageSize,before:$before){ pageInfo{hasPreviousPage startCursor} nodes{author{login} body} } } } }'

# Compact records for local classification. gh-axi --jq keeps these keys and
# TOON-encodes the object; the embedded decoder below is the only parser.
GQL_JQ='.data.repository.pullRequests | {
  hasNextPage: (.pageInfo.hasNextPage // false),
  endCursor: (.pageInfo.endCursor // ""),
  prs: [
    .nodes[]? | {
      number,
      title: ((.title // "") | gsub("[\t\n]"; " ")),
      url: (.url // ""),
      draft: (.isDraft // false),
      mergeable: (.mergeable // "UNKNOWN"),
      base: (.baseRefName // ""),
      head: (.headRefName // ""),
      author: (.author.login // ""),
      review: (.reviewDecision // ""),
      labels: ([.labels.nodes[]?.name] | join(",")),
      labels_truncated: (.labels.pageInfo.hasNextPage // false),
      labels_cursor: (.labels.pageInfo.endCursor // ""),
      checks: ([
        .commits.nodes[0]?.commit.statusCheckRollup.contexts.nodes[]? |
        ((.name // .context // "") + "=" + ((.conclusion // .state // .status // "") | ascii_downcase))
      ] | join(";")),
      checks_truncated: ((.commits.nodes[0]?.commit.statusCheckRollup.contexts.pageInfo.hasNextPage) // false),
      checks_cursor: ((.commits.nodes[0]?.commit.statusCheckRollup.contexts.pageInfo.endCursor) // ""),
      comments_truncated: (.comments.pageInfo.hasPreviousPage // false),
      comments_cursor: (.comments.pageInfo.startCursor // ""),
      bors_author: ((.author.login // "") | test("^(bors-ci-merge-queue|bors)(\\[bot\\])?$"; "i")),
      bors_last: ((
        [.comments.nodes[]? | select((.author.login // "") | test("^(bors-ci-merge-queue|bors)(\\[bot\\])?$"; "i")) | ((.body // "") | gsub("[\t\n]"; " "))]
        | last
      ) // "")
    }
  ]
}'

GQL_LABELS_JQ='.data.repository.pullRequest.labels | {
  hasNextPage: (.pageInfo.hasNextPage // false),
  endCursor: (.pageInfo.endCursor // ""),
  names: ([.nodes[]?.name] | join(","))
}'

GQL_CHECKS_JQ='(.data.repository.pullRequest.commits.nodes[0]?.commit.statusCheckRollup.contexts // {pageInfo:{hasNextPage:false,endCursor:""},nodes:[]}) | {
  hasNextPage: (.pageInfo.hasNextPage // false),
  endCursor: (.pageInfo.endCursor // ""),
  checks: ([
    .nodes[]? |
    ((.name // .context // "") + "=" + ((.conclusion // .state // .status // "") | ascii_downcase))
  ] | join(";"))
}'

GQL_COMMENTS_JQ='.data.repository.pullRequest.comments | {
  hasPreviousPage: (.pageInfo.hasPreviousPage // false),
  startCursor: (.pageInfo.startCursor // ""),
  bors_last: ((
    [.nodes[]? | select((.author.login // "") | test("^(bors-ci-merge-queue|bors)(\\[bot\\])?$"; "i")) | ((.body // "") | gsub("[\t\n]"; " "))]
    | last
  ) // "")
}'

# shellcheck disable=SC2016 # jq $base/$required/$k are jq variables.
CLASSIFY_JQ='
  def fail_conclusions: ["failure","timed_out","cancelled","action_required","stale","startup_failure","error"];
  def pass_conclusions: ["success","neutral"];
  def parse_checks:
    ((.checks // "") | split(";") | map(select(length > 0) | (
      index("=") as $i
      | if $i then {name: .[0:$i], conclusion: .[$i+1:]}
        else {name: ., conclusion: ""}
        end
    )));
  def req_status($req; $checks):
    ($checks | map(select(.name == $req))) as $hits
    | if any($hits[]; .conclusion as $c | fail_conclusions | index($c)) then "red"
      elif any($hits[]; .conclusion as $c | pass_conclusions | index($c)) then "green"
      else "pending"
      end;
  def is_release:
    ((.author // "") | test("release-please"; "i"))
    or ((.head // "") | test("^release-please"; "i"))
    or ((.title // "") | test("^chore\\(.*\\): release"; "i"));
  def has_blocker_label:
    ((.labels // "") | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(ascii_downcase) | index("review-blocker")) != null;
  def in_bors:
    (.bors_author == true)
    or (
      ((.bors_last // "") | test("has been approved|now in the \\[queue\\]|Trying:|:hourglass:|Rollup created"; "i"))
      and ((.bors_last // "") | test("unapproved|not previously approved|unmergeable"; "i") | not)
    );
  def incomplete_state:
    ((.labels_truncated == true) and (has_blocker_label | not))
    or (.checks_truncated == true)
    or ((.comments_truncated == true) and ((.bors_last // "") == "") and (.bors_author != true));
  def red_required($checks):
    [$required[] | select(req_status(.; $checks) == "red")];
  def pending_required($checks):
    [$required[] | select(req_status(.; $checks) == "pending")];
  def reasons:
    parse_checks as $checks
    | [
        (if .mergeable == "CONFLICTING" then "conflicts" else empty end),
        (if has_blocker_label then "review-blocker" else empty end),
        (if .review == "CHANGES_REQUESTED" then "CHANGES_REQUESTED" else empty end),
        (red_required($checks) as $red | if ($red | length) > 0 then "red required CI: \($red | join(", "))" else empty end),
        (if incomplete_state then "incomplete GitHub state" else empty end)
      ];
  def item:
    {
      number,
      url,
      title,
      base,
      reasons: reasons
    };
  def bucket:
    if in_bors then "in_bors"
    elif .base != $base then "stacked"
    elif (.draft == true) or is_release then "omit"
    elif incomplete_state then "blocked"
    else
      (reasons) as $r
      | parse_checks as $checks
      | if ($r | length) > 0 then "blocked"
        elif .mergeable == "MERGEABLE" and (pending_required($checks) | length) == 0
          then "ready"
        else "omit"
        end
    end;
  [.[] | . + {bucket: bucket, item: item}]
  | {
      ready:    [.[] | select(.bucket == "ready")    | .item] | sort_by(-.number),
      blocked:  [.[] | select(.bucket == "blocked")  | .item] | sort_by(-.number),
      stacked:  [.[] | select(.bucket == "stacked")  | .item] | sort_by(-.number),
      in_bors:  [.[] | select(.bucket == "in_bors")  | .item] | sort_by(-.number)
    }
'

usage() {
  cat <<'EOF'
usage: fm-pr-ready-bucket.sh [--repo OWNER/NAME] [--base BRANCH]
                            [--required-check NAME]... [--json]
       fm-pr-ready-bucket.sh --help

Read-only listing of open GitHub PRs grouped for the next bors rollup.
Default --repo is Chamber-Hero/memberos. Default --base is main.
--repo or --base other than those defaults requires --required-check NAME.
GitHub is the ready-bucket; this command does not scrape a Bors host.
Prints ready, blocked, stacked, and in-Bors groups with full PR URLs.
EOF
}

REPO=$DEFAULT_REPO
BASE=$DEFAULT_BASE
JSON_OUT=0
REQUIRED_CHECK_NAMES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --json)
      JSON_OUT=1
      shift
      ;;
    --repo)
      [ "$#" -ge 2 ] || { echo "error: --repo needs OWNER/NAME" >&2; exit 2; }
      REPO=$2
      shift 2
      ;;
    --repo=*)
      REPO=${1#--repo=}
      shift
      ;;
    --base)
      [ "$#" -ge 2 ] || { echo "error: --base needs a branch name" >&2; exit 2; }
      BASE=$2
      shift 2
      ;;
    --base=*)
      BASE=${1#--base=}
      shift
      ;;
    --required-check)
      [ "$#" -ge 2 ] || { echo "error: --required-check needs a check name" >&2; exit 2; }
      [ -n "$2" ] || { echo "error: --required-check needs a check name" >&2; exit 2; }
      REQUIRED_CHECK_NAMES+=("$2")
      shift 2
      ;;
    --required-check=*)
      [ -n "${1#--required-check=}" ] || { echo "error: --required-check needs a check name" >&2; exit 2; }
      REQUIRED_CHECK_NAMES+=("${1#--required-check=}")
      shift
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

case "$REPO" in
  */*/*|/*|*/)
    echo "error: --repo must be OWNER/NAME" >&2
    exit 2
    ;;
  */*)
    OWNER=${REPO%%/*}
    NAME=${REPO#*/}
    ;;
  *)
    echo "error: --repo must be OWNER/NAME" >&2
    exit 2
    ;;
esac
case "$OWNER" in ''|*[!A-Za-z0-9._-]*) echo "error: --repo must be OWNER/NAME" >&2; exit 2 ;; esac
case "$NAME" in ''|*[!A-Za-z0-9._-]*) echo "error: --repo must be OWNER/NAME" >&2; exit 2 ;; esac
case "$BASE" in
  ''|*[!A-Za-z0-9._/-]*)
    echo "error: --base must be a branch name" >&2
    exit 2
    ;;
esac
case "$MAX_NESTED_PAGES" in
  ''|*[!0-9]*|0)
    echo "error: FM_PR_READY_BUCKET_MAX_NESTED_PAGES must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "${#REQUIRED_CHECK_NAMES[@]}" -gt 0 ]; then
  :
elif [ "$REPO" != "$DEFAULT_REPO" ] || [ "$BASE" != "$DEFAULT_BASE" ]; then
  echo "error: --repo/--base override needs --required-check NAME" >&2
  exit 2
fi

command -v gh-axi >/dev/null 2>&1 || { echo "error: gh-axi not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }

if [ "${#REQUIRED_CHECK_NAMES[@]}" -gt 0 ]; then
  REQUIRED_CHECKS_JSON=$(printf '%s\n' "${REQUIRED_CHECK_NAMES[@]}" | jq -R . | jq -s -c .)
else
  REQUIRED_CHECKS_JSON=$MEMBEROS_REQUIRED_CHECKS_JSON
fi

# Decode one gh-axi TOON page (hasNextPage/endCursor plus a tabular prs array)
# into JSON. The decoder is intentionally narrow: it only understands the
# compact record shape this script asks --jq to emit.
# argv[1] is the TOON file: a stdin heredoc is the program, so the payload
# cannot also ride stdin.
toon_page_to_json() {
  python3 - "$1" <<'PY'
import csv, json, re, sys

text = open(sys.argv[1], encoding="utf-8").read()
has_next = False
cursor = ""
prs = []
table_re = re.compile(r"^prs\[(\d+)\](?:\{([^}]*)\})?:\s*(.*)$")
bool_keys = {"draft", "bors_author", "labels_truncated", "checks_truncated", "comments_truncated"}
lines = text.splitlines()
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("hasNextPage:"):
        has_next = line.split(":", 1)[1].strip().lower() == "true"
        i += 1
        continue
    if line.startswith("endCursor:"):
        cursor = line.split(":", 1)[1].strip().strip('"')
        i += 1
        continue
    match = table_re.match(line)
    if match:
        keys = [k.strip() for k in (match.group(2) or "").split(",") if k.strip()]
        rows = []
        rest = match.group(3).strip()
        if rest:
            rows.append(rest)
        i += 1
        while i < len(lines) and lines[i].startswith("  "):
            rows.append(lines[i][2:])
            i += 1
        if not keys:
            continue
        for raw in rows:
            if not raw.strip():
                continue
            parsed = next(csv.reader([raw]))
            if len(parsed) != len(keys):
                sys.stderr.write("error: ready-bucket TOON row field count mismatch\n")
                sys.exit(1)
            rec = {}
            for key, val in zip(keys, parsed):
                if key in bool_keys:
                    rec[key] = val.strip().lower() == "true"
                elif key == "number":
                    try:
                        rec[key] = int(val)
                    except ValueError:
                        sys.stderr.write("error: ready-bucket TOON row has a non-integer number\n")
                        sys.exit(1)
                else:
                    rec[key] = val
            prs.append(rec)
        continue
    i += 1
print(json.dumps({"hasNextPage": has_next, "endCursor": cursor, "prs": prs}))
PY
}

# Decode a scalar gh-axi TOON object (follow-up label/check/comment pages).
toon_object_to_json() {
  python3 - "$1" <<'PY'
import json, sys

obj = {}
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.rstrip("\n")
    if not line or line.startswith(" ") or ":" not in line:
        continue
    key, val = line.split(":", 1)
    key = key.strip()
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] == '"':
        val = val[1:-1]
    if val.lower() == "true":
        obj[key] = True
    elif val.lower() == "false":
        obj[key] = False
    else:
        obj[key] = val
print(json.dumps(obj))
PY
}

fetch_page() {
  local after=$1 variables toon page_json toon_file
  if [ -n "$after" ]; then
    variables=$(printf '{"owner":"%s","name":"%s","after":"%s","pageSize":%s}' "$OWNER" "$NAME" "$after" "$PAGE_SIZE")
  else
    variables=$(printf '{"owner":"%s","name":"%s","after":null,"pageSize":%s}' "$OWNER" "$NAME" "$PAGE_SIZE")
  fi
  toon=$(
    gh-axi api POST /graphql \
      --field "query=$GQL_QUERY" \
      --field "variables=$variables" \
      --jq "$GQL_JQ"
  ) || {
    echo "error: GitHub pull request listing failed" >&2
    return 1
  }
  toon_file=$(mktemp "${TMPDIR:-/tmp}/fm-pr-ready-bucket.XXXXXX") || return 1
  printf '%s\n' "$toon" > "$toon_file" || { rm -f "$toon_file"; return 1; }
  page_json=$(toon_page_to_json "$toon_file") || { rm -f "$toon_file"; return 1; }
  rm -f "$toon_file"
  printf '%s\n' "$page_json"
}

fetch_nested() {
  local query=$1 jq_expr=$2 variables=$3 toon toon_file page_json
  toon=$(
    gh-axi api POST /graphql \
      --field "query=$query" \
      --field "variables=$variables" \
      --jq "$jq_expr"
  ) || {
    echo "error: GitHub pull request details failed" >&2
    return 1
  }
  toon_file=$(mktemp "${TMPDIR:-/tmp}/fm-pr-ready-bucket.XXXXXX") || return 1
  printf '%s\n' "$toon" > "$toon_file" || { rm -f "$toon_file"; return 1; }
  page_json=$(toon_object_to_json "$toon_file") || { rm -f "$toon_file"; return 1; }
  rm -f "$toon_file"
  printf '%s\n' "$page_json"
}

nested_vars() {
  local number=$1 cursor_key=$2 cursor=$3
  jq -nc --arg owner "$OWNER" --arg name "$NAME" --argjson number "$number" \
    --arg ckey "$cursor_key" --arg cursor "$cursor" --argjson pageSize "$NESTED_PAGE_SIZE" \
    '{owner:$owner,name:$name,number:$number,pageSize:$pageSize} + {($ckey):$cursor}'
}

page_labels() {
  local rec=$1 page pages=0 cursor number vars
  number=$(jq -r '.number' <<<"$rec") || return 1
  cursor=$(jq -r '.labels_cursor // ""' <<<"$rec") || return 1
  while [ "$(jq -r '.labels_truncated' <<<"$rec")" = "true" ]; do
    pages=$((pages + 1))
    if [ "$pages" -gt "$MAX_NESTED_PAGES" ] || [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
      break
    fi
    vars=$(nested_vars "$number" after "$cursor") || return 1
    page=$(fetch_nested "$GQL_LABELS_QUERY" "$GQL_LABELS_JQ" "$vars") || return 1
    rec=$(jq -c --argjson page "$page" '
      (.labels // "" | split(",") | map(select(length>0))) as $have
      | (($page.names // "") | split(",") | map(select(length>0))) as $more
      | .labels = (($have + $more) | unique | join(","))
      | .labels_cursor = ($page.endCursor // "")
      | .labels_truncated = ($page.hasNextPage == true)
    ' <<<"$rec") || return 1
    if jq -e '((.labels // "") | split(",") | map(gsub("^\\s+|\\s+$";"") | ascii_downcase) | index("review-blocker")) != null' <<<"$rec" >/dev/null; then
      rec=$(jq -c '.labels_truncated = false' <<<"$rec") || return 1
      break
    fi
    cursor=$(jq -r '.labels_cursor // ""' <<<"$rec") || return 1
  done
  printf '%s\n' "$rec"
}

page_checks() {
  local rec=$1 page pages=0 cursor number vars
  number=$(jq -r '.number' <<<"$rec") || return 1
  cursor=$(jq -r '.checks_cursor // ""' <<<"$rec") || return 1
  while [ "$(jq -r '.checks_truncated' <<<"$rec")" = "true" ]; do
    pages=$((pages + 1))
    if [ "$pages" -gt "$MAX_NESTED_PAGES" ] || [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
      break
    fi
    vars=$(nested_vars "$number" after "$cursor") || return 1
    page=$(fetch_nested "$GQL_CHECKS_QUERY" "$GQL_CHECKS_JQ" "$vars") || return 1
    rec=$(jq -c --argjson page "$page" '
      (.checks // "" | split(";") | map(select(length>0))) as $have
      | (($page.checks // "") | split(";") | map(select(length>0))) as $more
      | .checks = (($have + $more) | unique | join(";"))
      | .checks_cursor = ($page.endCursor // "")
      | .checks_truncated = ($page.hasNextPage == true)
    ' <<<"$rec") || return 1
    cursor=$(jq -r '.checks_cursor // ""' <<<"$rec") || return 1
  done
  printf '%s\n' "$rec"
}

page_comments() {
  local rec=$1 page pages=0 cursor number vars
  number=$(jq -r '.number' <<<"$rec") || return 1
  cursor=$(jq -r '.comments_cursor // ""' <<<"$rec") || return 1
  while [ "$(jq -r '.comments_truncated' <<<"$rec")" = "true" ] \
    && [ "$(jq -r '.bors_last // ""' <<<"$rec")" = "" ] \
    && [ "$(jq -r '.bors_author' <<<"$rec")" != "true" ]; do
    pages=$((pages + 1))
    if [ "$pages" -gt "$MAX_NESTED_PAGES" ] || [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
      break
    fi
    vars=$(nested_vars "$number" before "$cursor") || return 1
    page=$(fetch_nested "$GQL_COMMENTS_QUERY" "$GQL_COMMENTS_JQ" "$vars") || return 1
    rec=$(jq -c --argjson page "$page" '
      .bors_last = (if ((.bors_last // "") == "") then ($page.bors_last // "") else .bors_last end)
      | .comments_cursor = ($page.startCursor // "")
      | .comments_truncated = ($page.hasPreviousPage == true)
    ' <<<"$rec") || return 1
    if [ "$(jq -r '.bors_last // ""' <<<"$rec")" != "" ]; then
      rec=$(jq -c '.comments_truncated = false' <<<"$rec") || return 1
      break
    fi
    cursor=$(jq -r '.comments_cursor // ""' <<<"$rec") || return 1
  done
  printf '%s\n' "$rec"
}

complete_pr_connections() {
  local rec=$1
  rec=$(jq -c '
    if (.comments_truncated == true) and (((.bors_last // "") != "") or (.bors_author == true))
    then .comments_truncated = false
    else .
    end
  ' <<<"$rec") || return 1
  if [ "$(jq -r '.labels_truncated' <<<"$rec")" = "true" ]; then
    rec=$(page_labels "$rec") || return 1
  fi
  if [ "$(jq -r '.checks_truncated' <<<"$rec")" = "true" ]; then
    rec=$(page_checks "$rec") || return 1
  fi
  if [ "$(jq -r '.comments_truncated' <<<"$rec")" = "true" ]; then
    rec=$(page_comments "$rec") || return 1
  fi
  printf '%s\n' "$rec"
}

complete_truncated_connections() {
  local prs=$1 rec idx count
  count=$(printf '%s\n' "$prs" | jq 'length') || return 1
  idx=0
  while [ "$idx" -lt "$count" ]; do
    rec=$(printf '%s\n' "$prs" | jq -c --argjson i "$idx" '.[$i]') || return 1
    rec=$(complete_pr_connections "$rec") || return 1
    prs=$(printf '%s\n' "$prs" | jq -c --argjson i "$idx" --argjson rec "$rec" '.[$i] = $rec') || return 1
    idx=$((idx + 1))
  done
  printf '%s\n' "$prs"
}

ALL_PRS_JSON='[]'
AFTER=
PAGE=0
while :; do
  PAGE=$((PAGE + 1))
  if [ "$PAGE" -gt "$MAX_PAGES" ]; then
    echo "error: open PR listing exceeded $MAX_PAGES pages" >&2
    exit 1
  fi
  PAGE_JSON=$(fetch_page "$AFTER") || exit 1
  PAGE_PRS=$(printf '%s\n' "$PAGE_JSON" | jq -c '.prs') || exit 1
  ALL_PRS_JSON=$(jq -c --argjson page "$PAGE_PRS" '. + $page' <<<"$ALL_PRS_JSON") || exit 1
  HAS_NEXT=$(printf '%s\n' "$PAGE_JSON" | jq -r '.hasNextPage') || exit 1
  AFTER=$(printf '%s\n' "$PAGE_JSON" | jq -r '.endCursor') || exit 1
  if [ "$HAS_NEXT" != "true" ]; then
    break
  fi
  if [ -z "$AFTER" ] || [ "$AFTER" = "null" ]; then
    echo "error: GitHub reported another PR page without a cursor" >&2
    exit 1
  fi
done

ALL_PRS_JSON=$(complete_truncated_connections "$ALL_PRS_JSON") || exit 1

GROUPED=$(
  printf '%s\n' "$ALL_PRS_JSON" | jq \
    --arg base "$BASE" \
    --argjson required "$REQUIRED_CHECKS_JSON" \
    "$CLASSIFY_JQ"
) || {
  echo "error: ready-bucket classification failed" >&2
  exit 1
}

if [ "$JSON_OUT" -eq 1 ]; then
  jq -n --arg repo "$REPO" --arg base "$BASE" --argjson grouped "$GROUPED" \
    '$grouped + {repo:$repo, base:$base}'
  exit 0
fi

print_group() {
  local key=$1 label=$2
  local count
  count=$(printf '%s\n' "$GROUPED" | jq --arg k "$key" '.[$k] | length')
  printf '%s (%s)\n' "$label" "$count"
  printf '%s\n' "$GROUPED" | jq -r --arg k "$key" '
    .[$k][]
    | if ($k == "blocked") and ((.reasons | length) > 0) then
        "\(.url)  \(.reasons | join("; "))"
      elif $k == "stacked" then
        "\(.url)  base \(.base)"
      else
        .url
      end
  '
  printf '\n'
}

printf 'ready-bucket  %s  base %s\n\n' "$REPO" "$BASE"
print_group ready ready
print_group blocked blocked
print_group stacked stacked
print_group in_bors in-Bors
