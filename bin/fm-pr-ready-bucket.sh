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
#   blocked  conflicts, red required CI, review-blocker, or CHANGES_REQUESTED
#            (main-targeting non-draft non-release PRs only)
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
#   fm-pr-ready-bucket.sh [--repo OWNER/NAME] [--base BRANCH] [--json]
#   fm-pr-ready-bucket.sh --help
#
# Default --repo is Chamber-Hero/memberos.
# Default --base is main.
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

REQUIRED_CHECKS_JSON='[
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
GQL_QUERY='query($owner:String!,$name:String!,$after:String,$pageSize:Int!){ repository(owner:$owner,name:$name){ pullRequests(first:$pageSize,states:OPEN,after:$after,orderBy:{field:UPDATED_AT,direction:DESC}){ pageInfo{hasNextPage endCursor} nodes{ number title url isDraft mergeable baseRefName headRefName author{login} reviewDecision labels(first:20){nodes{name}} commits(last:1){nodes{commit{statusCheckRollup{contexts(first:40){nodes{... on CheckRun{name conclusion status} ... on StatusContext{context state}}}}}}} comments(last:30){nodes{author{login} body}} } } } }'

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
      checks: ([
        .commits.nodes[0]?.commit.statusCheckRollup.contexts.nodes[]? |
        ((.name // .context // "") + "=" + ((.conclusion // .state // .status // "") | ascii_downcase))
      ] | join(";")),
      bors_author: ((.author.login // "") | test("^(bors-ci-merge-queue|bors)(\\[bot\\])?$"; "i")),
      bors_last: ((
        [.comments.nodes[]? | select((.author.login // "") | test("^(bors-ci-merge-queue|bors)(\\[bot\\])?$"; "i")) | ((.body // "") | gsub("[\t\n]"; " "))]
        | last
      ) // "")
    }
  ]
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
      ((.bors_last // "") | test("has been approved|now in the \\[queue\\]|Trying:|:hourglass:"; "i"))
      and ((.bors_last // "") | test("unapproved|not previously approved|unmergeable"; "i") | not)
    );
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
        (red_required($checks) as $red | if ($red | length) > 0 then "red required CI: \($red | join(", "))" else empty end)
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
usage: fm-pr-ready-bucket.sh [--repo OWNER/NAME] [--base BRANCH] [--json]
       fm-pr-ready-bucket.sh --help

Read-only listing of open GitHub PRs grouped for the next bors rollup.
Default --repo is Chamber-Hero/memberos. Default --base is main.
GitHub is the ready-bucket; this command does not scrape a Bors host.
Prints ready, blocked, stacked, and in-Bors groups with full PR URLs.
EOF
}

REPO=$DEFAULT_REPO
BASE=$DEFAULT_BASE
JSON_OUT=0

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

command -v gh-axi >/dev/null 2>&1 || { echo "error: gh-axi not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 1; }

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
bool_keys = {"draft", "bors_author"}
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
