#!/usr/bin/env bash
# fm-attribution-sweep.sh - read-only detector for GitHub writes made under the
# captain's own account that do NOT carry the model-write attribution token.
#
# Why this exists. Every fleet write - issue comment, pull request review, and
# pushed commit - authenticates as the captain's own GitHub account with
# author_association OWNER and no bot marker or app identity, so nothing at
# write time can tell a model session apart from the captain typing. The ruled
# convention is therefore a self-identifying token led by the model session
# itself, and a model can silently omit it. A convention nothing can enforce is
# only worth something if omissions become visible afterwards, so this sweep is
# what converts an unenforceable rule into a detectable one. The sweep's cadence
# is the exposure window.
#
# docs/model-write-attribution.md owns the convention, the token's rationale,
# and the residual exposure that was accepted knowingly.
#
# READ-ONLY. Every GitHub call is a GET issued through one chokepoint that
# refuses any other method and any mutating flag. The sweep never comments on,
# edits, closes, or deletes anything it finds, including the writes it reports.
#
# IT DOES NOT IDENTIFY AUTHORS. A write without the token is a CANDIDATE, never
# a verdict: a comment the captain typed by hand is byte-identical in every
# field GitHub exposes. Each candidate prints the evidence available so the
# captain judges.
#
# Three-valued outcomes. Every scope - one repository and one kind of write -
# ends in exactly one of observed-clean, candidates, or could-not-observe. An
# unreachable API, an expired or missing token, a truncated response, an
# exhausted request budget, and an unparsable reply are all could-not-observe,
# and none of them is ever folded into a clean run.
#
# Usage:
#   fm-attribution-sweep.sh [options]
#   fm-attribution-sweep.sh --convention   print the paste-ready prompt preamble
#   fm-attribution-sweep.sh --token        print the exact token, nothing else
#   fm-attribution-sweep.sh --help         print this header
#
# Options:
#   --account <login>    account whose writes are swept (default: the gh-axi login)
#   --repo <owner/name>  repository to sweep (repeatable; default: every repository
#                        the account owns)
#   --kind <kind>        comments | reviews | commits (repeatable; default: all three)
#   --since <iso8601>    window start, spelled YYYY-MM-DDTHH:MM:SSZ (default:
#                        FM_SWEEP_WINDOW_DAYS, itself 7, days back). Every window
#                        filter is a string comparison against GitHub's own UTC
#                        timestamps, so any other spelling is refused outright
#                        rather than sorting below every record and quietly
#                        examining nothing. A component outside its range -
#                        month 13, day 32, hour 24 - is refused for the same
#                        reason from the other side: it matches the shape, then
#                        sorts above every record and drops them all.
#   --branch <name>      restrict the commits kind to this branch (repeatable).
#                        Naming a branch also skips the pull request head pass,
#                        so a commit whose branch was deleted when its pull
#                        request closed is not reached by that run.
#   --budget <n>         maximum GitHub requests for the whole run (default 300).
#                        There is no unlimited value: 0 permits no request at
#                        all, and every scope then reports could-not-observe
#                        rather than a clean sweep of nothing.
#   --max-pages <n>      maximum pages per individual listing (default 20)
#   --per-page <n>       records per listing page (default 25, GitHub's cap is 100).
#                        The client renders a bounded response and flags anything
#                        longer as truncated, which this sweep reports as
#                        could-not-observe, so a smaller page keeps a busy
#                        repository readable. Correctness never depends on the
#                        value: an over-large page is refused, not silently cut.
#
# The window and the request budget are printed in the begin marker and named
# again in the summary; every other bound is named in the could-not-observe
# detail when a run hits it, rather than silently narrowing what was examined.
#
# Output markers (stdout):
#   FM_SWEEP_BEGIN <iso> account=<login> since=<iso> token=<token> repos=<n> budget=<n>
#   FM_SWEEP_SCOPE repo=<owner/name> kind=<kind> outcome=observed examined=<n> declared=<n> candidates=<n>
#   FM_SWEEP_SCOPE repo=<owner/name> kind=<kind> outcome=could-not-observe reason=<slug> detail=<text>
#   FM_SWEEP_CANDIDATE repo=<owner/name> kind=<kind> ref=<id> when=<iso> url=<url> evidence=<k=v,...>
#   FM_SWEEP_SUMMARY scopes=<n> observed=<n> could_not_observe=<n> declared=<n> candidates=<n> requests=<n> outcome=<clean|candidates|could-not-observe>
#
# examined counts the records that survived the account and window filters, the
# same way for all three kinds, so examined always equals declared plus
# candidates and a gap between them is a bug rather than a reading of the field.
#
# Exit status:
#   0   every scope was observed and no candidate was found
#   10  every scope was observed and at least one candidate was found
#   20  at least one scope could not be observed; any candidates are still listed
#   64  usage error
set -u

# The one attribution token. docs/model-write-attribution.md states why this
# exact spelling and no other; changing it here without changing that doc splits
# the convention from its detector.
FM_ATTRIBUTION_TOKEN='SOL-AI:'

EXIT_CLEAN=0
EXIT_CANDIDATES=10
EXIT_UNOBSERVED=20
EXIT_USAGE=64

SELF="${BASH_SOURCE[0]}"

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed 's/^# \{0,1\}//; $d'
}

die_usage() {
  printf 'fm-attribution-sweep: %s\n' "$1" >&2
  printf 'run "%s --help" for usage\n' "$(basename "$SELF")" >&2
  exit "$EXIT_USAGE"
}

ACCOUNT=
SINCE=
BUDGET=300
MAX_PAGES=20
PER_PAGE=25
REPOS=()
KINDS=()
BRANCHES=()

while [ "$#" -gt 0 ]; do
  case $1 in
    --help|-h) usage; exit 0 ;;
    --token) printf '%s\n' "$FM_ATTRIBUTION_TOKEN"; exit 0 ;;
    --convention) CONVENTION_ONLY=1; shift ;;
    --account) [ "$#" -ge 2 ] || die_usage "--account needs a value"; ACCOUNT=$2; shift 2 ;;
    --account=*) ACCOUNT=${1#--account=}; shift ;;
    --repo) [ "$#" -ge 2 ] || die_usage "--repo needs a value"; REPOS+=("$2"); shift 2 ;;
    --repo=*) REPOS+=("${1#--repo=}"); shift ;;
    --kind) [ "$#" -ge 2 ] || die_usage "--kind needs a value"; KINDS+=("$2"); shift 2 ;;
    --kind=*) KINDS+=("${1#--kind=}"); shift ;;
    --branch) [ "$#" -ge 2 ] || die_usage "--branch needs a value"; BRANCHES+=("$2"); shift 2 ;;
    --branch=*) BRANCHES+=("${1#--branch=}"); shift ;;
    --since) [ "$#" -ge 2 ] || die_usage "--since needs a value"; SINCE=$2; shift 2 ;;
    --since=*) SINCE=${1#--since=}; shift ;;
    --budget) [ "$#" -ge 2 ] || die_usage "--budget needs a value"; BUDGET=$2; shift 2 ;;
    --budget=*) BUDGET=${1#--budget=}; shift ;;
    --max-pages) [ "$#" -ge 2 ] || die_usage "--max-pages needs a value"; MAX_PAGES=$2; shift 2 ;;
    --max-pages=*) MAX_PAGES=${1#--max-pages=}; shift ;;
    --per-page) [ "$#" -ge 2 ] || die_usage "--per-page needs a value"; PER_PAGE=$2; shift 2 ;;
    --per-page=*) PER_PAGE=${1#--per-page=}; shift ;;
    *) die_usage "unknown argument: $1" ;;
  esac
done

# The prompt preamble. This is the artifact pasted at the top of a browser model
# session, so the convention is reachable where a write is actually authored
# rather than only in a decision record.
print_convention() {
  cat <<EOF
--- paste this at the top of a browser model session that can write to GitHub ---

Attribution rule for this session, and it is not optional.

You are signed in to GitHub as the account owner. Everything you write there -
an issue or pull request comment, a pull request review, and any commit you
create - is recorded as the owner's own writing, with no bot marker and no
separate machine identity. A human reading it later cannot tell it apart from
something the owner typed.

So every write you make must begin with this exact token, followed by one space:

    ${FM_ATTRIBUTION_TOKEN}

Put it at the very start of the comment body, the very start of the review body,
and inside the commit message. Where a repository lints commit subjects, put it
at the start of the first body line instead of the subject; anywhere in the
commit message counts. Do not translate it, wrap it in punctuation, reformat it,
or drop it because a write feels minor. If you are unsure whether something
counts as a write, include the token.

If you cannot include the token for any reason, do not make the write. Say so
instead and stop.

--- end of preamble ---

The token is checked after the fact by bin/fm-attribution-sweep.sh; omissions
are reported as candidates for the captain to judge.
EOF
}

if [ "${CONVENTION_ONLY:-0}" = "1" ]; then
  print_convention
  exit 0
fi

now_iso() {
  printf '%s\n' "${FM_SWEEP_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
}

days_ago_iso() {
  local days=$1
  date -u -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v-"${days}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

is_uint() {
  case $1 in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Every window filter - the pull request walk here and the jq selects sent to
# GitHub - is a lexicographic comparison against GitHub's own UTC timestamps.
# That is only sound for one exact spelling: a value like "30d" sorts below every
# real timestamp, so it would drop every record and report an observed-clean
# sweep of nothing. The window start is therefore checked to be that spelling
# before it is ever compared against anything.
#
# The shape alone is not the check. An impossible date that still matches the
# shape - month 13, day 32, hour 24 - sorts ABOVE every real timestamp, which
# drops every record and reports the same observed-clean sweep of nothing from
# the other side. Each component is therefore range-checked against the calendar,
# so a value that cannot order sensibly against GitHub's timestamps is refused
# exactly like "30d" is.
is_iso8601() {
  local v=$1 month day hour minute second
  case $v in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
  # Base 10 explicitly: "08" and "09" are not octal numbers.
  month=$((10#${v:5:2}))
  day=$((10#${v:8:2}))
  hour=$((10#${v:11:2}))
  minute=$((10#${v:14:2}))
  second=$((10#${v:17:2}))
  { [ "$month" -ge 1 ] && [ "$month" -le 12 ]; } || return 1
  { [ "$day" -ge 1 ] && [ "$day" -le 31 ]; } || return 1
  [ "$hour" -le 23 ] || return 1
  [ "$minute" -le 59 ] || return 1
  # A leap second is spelled :60 and GitHub can print one, so it is accepted.
  [ "$second" -le 60 ] || return 1
  return 0
}

is_uint "$BUDGET" || die_usage "--budget must be a non-negative integer"
is_uint "$MAX_PAGES" || die_usage "--max-pages must be a non-negative integer"
is_uint "$PER_PAGE" || die_usage "--per-page must be a non-negative integer"
{ [ "$PER_PAGE" -ge 1 ] && [ "$PER_PAGE" -le 100 ]; } || die_usage "--per-page must be between 1 and 100"

if [ "${#KINDS[@]}" -eq 0 ]; then
  KINDS=(comments reviews commits)
fi
for kind in "${KINDS[@]}"; do
  case $kind in
    comments|reviews|commits) ;;
    *) die_usage "unknown kind: $kind" ;;
  esac
done

# The default window is 7 days, chosen so a default run FINISHES inside the
# default budget rather than reporting could-not-observe. A detector whose first
# run usually says it could not look trains its operator to ignore it, and an
# ignored sweep is worth nothing.
#
# The arithmetic, measured on this fleet's own repositories rather than
# estimated: the commits kind pays a window-independent cost of one listing page
# per 25 branches plus one request per branch, which on a 128-branch repository
# is about 134 requests before the window is considered at all, and roughly 155
# across the three repositories the account owns. Reviews and commits then each
# spend one request per pull request touched in the window. Measured pull request
# counts were 38 over 7 days, 66 over 14, and 71 over 30, so the totals come to
# about 250 requests at 7 days, 310 at 14, and 320 at 30 against a 300 budget.
# Seven days is therefore the widest default that completes, and it was not a
# close call against fourteen.
WINDOW_DAYS=${FM_SWEEP_WINDOW_DAYS:-7}
if [ -n "$SINCE" ]; then
  is_iso8601 "$SINCE" \
    || die_usage "--since must be a UTC ISO-8601 timestamp spelled YYYY-MM-DDTHH:MM:SSZ, e.g. 2026-01-01T00:00:00Z"
else
  is_uint "$WINDOW_DAYS" || die_usage "FM_SWEEP_WINDOW_DAYS must be a non-negative integer"
fi

NOW=$(now_iso)

# Set before any early could-not-observe can reach the summary under `set -u`.
WINDOW_DESCRIPTION="an unresolved window"

# Run-level tallies. Scope tallies are reset per scope.
SCOPES=0
SCOPES_OBSERVED=0
SCOPES_UNOBSERVED=0
TOTAL_DECLARED=0
TOTAL_CANDIDATES=0
REQUESTS_SPENT=0


sanitize() {
  # One marker field: no newlines, no tabs, bounded length.
  printf '%s' "$1" | tr '\n\t' '  ' | cut -c1-200
}

# ---------------------------------------------------------------------------
# base64 decoding, detected once. Records travel base64-encoded so no comment
# body, commit subject, or review text can inject a newline, a tab, or a field
# separator into a marker line.
# ---------------------------------------------------------------------------
B64D=
for flag in --decode -D -d; do
  if [ "$(printf 'eA==' | base64 "$flag" 2>/dev/null)" = "x" ]; then
    B64D=$flag
    break
  fi
done

b64d() { printf '%s' "$1" | base64 "$B64D" 2>/dev/null; }

# ---------------------------------------------------------------------------
# The single GitHub chokepoint. GET only, through gh-axi, with no method
# argument and no mutating flag reachable from anywhere in this script.
#
# On success the decoded response body is left in GH_BODY and GH_STATUS is "ok".
# On any other result GH_STATUS names which could-not-observe it was and
# GH_DETAIL carries a bounded diagnostic; there is no third state in which the
# caller may treat the absence of a body as an answer.
#
# The body is returned in a variable rather than on stdout on purpose: a caller
# writing out=$(gh_get ...) would run this in a subshell, and the status, the
# diagnostic, and the spent-request count would all be discarded with it, which
# is precisely how a could-not-observe turns into a silent clean run.
# ---------------------------------------------------------------------------
GH_STATUS=
GH_DETAIL=
GH_BODY=

gh_get() {
  local path=$1 jq_expr=$2 out rc first body trunc
  GH_STATUS=
  GH_DETAIL=
  GH_BODY=

  case $path in
    /*) ;;
    *) GH_STATUS=bad-request; GH_DETAIL="path must start with /: $path"; return 1 ;;
  esac
  case $path in
    *[[:space:]]*) GH_STATUS=bad-request; GH_DETAIL="path contains whitespace"; return 1 ;;
  esac

  if [ "$REQUESTS_SPENT" -ge "$BUDGET" ]; then
    GH_STATUS=request-budget
    GH_DETAIL="request budget of $BUDGET exhausted before $path"
    return 1
  fi
  REQUESTS_SPENT=$((REQUESTS_SPENT + 1))

  out=$(gh-axi api "$path" --jq "$jq_expr" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    GH_STATUS=api-error
    GH_DETAIL=$(sanitize "$out")
    return 1
  fi

  first=$(printf '%s\n' "$out" | head -1)
  case $first in
    error:*|code:*)
      GH_STATUS=api-error
      GH_DETAIL=$(sanitize "$out")
      return 1
      ;;
    api_response:*)
      trunc=$(printf '%s\n' "$out" | sed -n 's/^  *truncated: //p' | head -1)
      if [ "$trunc" = "true" ]; then
        GH_STATUS=truncated
        GH_DETAIL=$(sanitize "response truncated by the client: $(printf '%s\n' "$out" | sed -n 's/^  *original_length: //p' | head -1) bytes")
        return 1
      fi
      body=$(printf '%s\n' "$out" | sed -n 's/^  *body: //p' | head -1)
      ;;
    *)
      # A bare scalar rendering with no envelope.
      body=$out
      ;;
  esac

  case $body in
    '""') body='' ;;
    '"'*'"') body=${body#\"}; body=${body%\"} ;;
  esac

  GH_STATUS=ok
  GH_BODY=$(printf '%s' "$body" | sed 's/\\n/\
/g')
  return 0
}

# jq fragment shared by every listing: emit the raw page length on the first
# line, then one "|"-joined record of base64 fields per surviving element.
JQ_ENVELOPE='| ([(.n|tostring)] + .r) | join("\n")'

# The two halves of that envelope, read back through one pair of helpers rather
# than open-coded at every listing. The count line drives pagination and the
# record lines drive the tallies, so a caller that took one from a stale body and
# the other from a fresh one would page on a length that never described the
# records it counted. Both halves come from the same GH_BODY here by
# construction.
page_count() {
  printf '%s\n' "$GH_BODY" | head -1
}

page_records() {
  printf '%s\n' "$GH_BODY" | tail -n +2
}

# Percent-encode a value going into a request path or query. A branch named
# "feat/a&b" would otherwise end the query early, and the sweep would report a
# branch it never actually asked about as observed - a silent wrong answer of
# exactly the kind this tool exists to prevent. Byte-wise under LC_ALL=C so a
# non-ASCII name encodes correctly rather than per rendered character. LC_ALL is
# local so that byte-wise view stays inside this function: leaking it would
# silently make sanitize's character bound a byte bound and change the collation
# every other comparison in the script relies on.
urlq() {
  local s=$1 out='' i c LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [A-Za-z0-9._~/-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

jq_str() {
  # Quote a shell value for embedding as a jq string literal.
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

# ---------------------------------------------------------------------------
# Scope reporting. Exactly one of these ends every scope.
# ---------------------------------------------------------------------------
scope_observed() {
  local repo=$1 kind=$2 examined=$3 declared=$4 candidates=$5
  SCOPES=$((SCOPES + 1))
  SCOPES_OBSERVED=$((SCOPES_OBSERVED + 1))
  TOTAL_DECLARED=$((TOTAL_DECLARED + declared))
  TOTAL_CANDIDATES=$((TOTAL_CANDIDATES + candidates))
  printf 'FM_SWEEP_SCOPE repo=%s kind=%s outcome=observed examined=%s declared=%s candidates=%s\n' \
    "$repo" "$kind" "$examined" "$declared" "$candidates"
}

scope_unobserved() {
  local repo=$1 kind=$2 reason=$3 detail=$4 declared=${5:-0} candidates=${6:-0}
  SCOPES=$((SCOPES + 1))
  SCOPES_UNOBSERVED=$((SCOPES_UNOBSERVED + 1))
  TOTAL_DECLARED=$((TOTAL_DECLARED + declared))
  TOTAL_CANDIDATES=$((TOTAL_CANDIDATES + candidates))
  printf 'FM_SWEEP_SCOPE repo=%s kind=%s outcome=could-not-observe reason=%s detail=%s\n' \
    "$repo" "$kind" "$reason" "$(sanitize "$detail")"
}

emit_candidate() {
  local repo=$1 kind=$2 ref=$3 when=$4 url=$5 evidence=$6
  printf 'FM_SWEEP_CANDIDATE repo=%s kind=%s ref=%s when=%s url=%s evidence=%s\n' \
    "$repo" "$kind" "$(sanitize "$ref")" "$(sanitize "$when")" \
    "$(sanitize "$url")" "$(sanitize "$evidence")"
}

# ---------------------------------------------------------------------------
# Preconditions. Each failure is a run-level could-not-observe, never a clean run.
# ---------------------------------------------------------------------------
run_blocked() {
  local reason=$1 detail=$2
  printf 'FM_SWEEP_BEGIN %s account=%s since=%s token=%s repos=0 budget=%s\n' \
    "$NOW" "${ACCOUNT:-unknown}" "$SINCE" "$FM_ATTRIBUTION_TOKEN" "$BUDGET"
  scope_unobserved '-' '-' "$reason" "$detail"
  print_summary
  exit "$EXIT_UNOBSERVED"
}

print_summary() {
  local outcome=clean
  if [ "$SCOPES_UNOBSERVED" -gt 0 ]; then
    outcome=could-not-observe
  elif [ "$TOTAL_CANDIDATES" -gt 0 ]; then
    outcome=candidates
  fi
  printf 'FM_SWEEP_SUMMARY scopes=%s observed=%s could_not_observe=%s declared=%s candidates=%s requests=%s outcome=%s\n' \
    "$SCOPES" "$SCOPES_OBSERVED" "$SCOPES_UNOBSERVED" "$TOTAL_DECLARED" \
    "$TOTAL_CANDIDATES" "$REQUESTS_SPENT" "$outcome"
  cat <<EOF
This sweep cannot determine who wrote anything. A candidate is a write under
this account that does not carry ${FM_ATTRIBUTION_TOKEN} - which is equally what an
undeclared model session and the captain's own hand-typed comment look like in
every field GitHub exposes. The evidence on each line is a signal, not an
attribution; the captain judges.

Some candidates are known permanent ones. A capability probe on 2026-08-02 left
five deliberately unprefixed writes in place as this sweep's only real-world red
control, and reporting them is correct behaviour rather than a finding. Before
investigating any candidate dated 2026-08-02, check it against the table in
docs/model-write-attribution.md under "The retained probe writes".

This run covered ${WINDOW_DESCRIPTION}, and writes outside it
were not examined at all - a clean result says nothing about them. Widen the
window with --since <iso8601> or FM_SWEEP_WINDOW_DAYS=<days>, and raise --budget
with it: reviews and commits each spend about one request per pull request in
the window, so a wider window on the current budget of ${BUDGET} will report
could-not-observe instead of a result.
EOF
  if [ "$SCOPES_UNOBSERVED" -gt 0 ]; then
    cat <<'EOF'
At least one scope could not be observed. This run is NOT a clean result: the
unobserved scopes were not searched, so nothing is known about them either way.
EOF
  fi
}

# The derived window start is resolved here rather than beside the other
# argument checks because a system whose date understands neither form yields no
# window at all. That is a could-not-observe, not a usage error, and reporting it
# needs the markers above to exist.
if [ -z "$SINCE" ]; then
  SINCE=$(days_ago_iso "$WINDOW_DAYS")
  WINDOW_DESCRIPTION="the $WINDOW_DAYS days since $SINCE"
  if ! is_iso8601 "$SINCE"; then
    SINCE=unresolved
    run_blocked missing-tool \
      "date could not compute a window start $WINDOW_DAYS days back, so there is no window to sweep"
  fi
else
  WINDOW_DESCRIPTION="everything since $SINCE, as given by --since"
fi

if [ -z "$B64D" ]; then
  run_blocked missing-tool "base64 cannot decode on this system; no response could be read"
fi

if ! command -v gh-axi >/dev/null 2>&1; then
  run_blocked missing-tool "gh-axi is not installed, so no GitHub state could be read"
fi

if [ -z "$ACCOUNT" ]; then
  gh_get '/user' '.login'
  ACCOUNT=$GH_BODY
  if [ "$GH_STATUS" != "ok" ] || [ -z "$ACCOUNT" ]; then
    run_blocked "${GH_STATUS:-empty-result}" "could not resolve the authenticated account: ${GH_DETAIL:-empty login}"
  fi
fi

ACCOUNT_JQ=$(jq_str "$ACCOUNT")
TOKEN_JQ=$(jq_str "$FM_ATTRIBUTION_TOKEN")
SINCE_JQ=$(jq_str "$SINCE")

# ---------------------------------------------------------------------------
# Repository set.
# ---------------------------------------------------------------------------
if [ "${#REPOS[@]}" -eq 0 ]; then
  page=1
  while [ "$page" -le "$MAX_PAGES" ]; do
    gh_get "/user/repos?affiliation=owner&per_page=$PER_PAGE&page=$page" \
      "{n: length, r: [ .[] | (.full_name|@base64) ]} $JQ_ENVELOPE"
    if [ "$GH_STATUS" != "ok" ]; then
      run_blocked "$GH_STATUS" "could not enumerate the account's repositories: $GH_DETAIL"
    fi
    raw=$(page_count)
    is_uint "$raw" || run_blocked unparsable "repository listing page $page was not parsable"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      REPOS+=("$(b64d "$line")")
    done < <(page_records)
    [ "$raw" -eq "$PER_PAGE" ] || break
    page=$((page + 1))
  done
  if [ "$page" -gt "$MAX_PAGES" ]; then
    run_blocked max-pages "the account owns more repositories than --max-pages $MAX_PAGES would list; the repository set itself is incomplete"
  fi
fi

# An empty repository set is never a clean sweep. GitHub answers
# /user/repos?affiliation=owner with HTTP 200 and an empty array both for a token
# whose scopes exclude the account's repositories and for an account that owns
# nothing, and those two are the same bytes on the wire - there is no field that
# separates them. Calling either one clean would report "nothing to find" for a
# run that could not look at anything, which is exactly the false clean this
# sweep exists to make impossible.
if [ "${#REPOS[@]}" -eq 0 ]; then
  run_blocked empty-repository-set \
    "no repository resolved, so nothing was examined; an empty owner listing means either a token whose scopes exclude the account's repositories or an account that owns none, and those are indistinguishable here - name a repository with --repo to sweep it directly"
fi

printf 'FM_SWEEP_BEGIN %s account=%s since=%s token=%s repos=%s budget=%s\n' \
  "$NOW" "$ACCOUNT" "$SINCE" "$FM_ATTRIBUTION_TOKEN" "${#REPOS[@]}" "$BUDGET"

# ---------------------------------------------------------------------------
# comments: every issue and pull request conversation comment in the window.
#
# An app-performed comment is NOT skipped. The measured browser session writes
# through the ChatGPT Codex Connector GitHub App, which sets
# performed_via_github_app while still recording the comment under the account
# owner's login with author_association OWNER, so it reads as the owner's own
# writing everywhere a human looks. Filtering those out would drop exactly the
# writes this sweep exists to surface, so the app slug is reported as evidence
# instead.
# ---------------------------------------------------------------------------
sweep_comments() {
  local repo=$1 page=1 raw line examined=0 declared=0 candidates=0
  local id issue when has_token assoc app jq_expr

  # Only what cannot be derived travels: the permalink is rebuilt from the
  # repository, the issue number, and the comment id. Keeping records narrow is
  # what keeps a busy repository under the client's render limit, and therefore
  # observable at all rather than reported as truncated.
  jq_expr="{n: length, r: [ .[]
    | select(.user.login == $ACCOUNT_JQ)
    | [ (.id|tostring|@base64),
        (((.issue_url // \"\")|split(\"/\")|last)|@base64),
        ((.created_at // \"\")|@base64),
        (((.body // \"\")|contains($TOKEN_JQ))|tostring|@base64),
        ((.author_association // \"\")|@base64),
        ((if .performed_via_github_app == null then \"none\" else ((.performed_via_github_app.slug) // \"unnamed\") end)|@base64) ]
    | join(\"|\") ]} $JQ_ENVELOPE"

  while [ "$page" -le "$MAX_PAGES" ]; do
    gh_get "/repos/$(urlq "$repo")/issues/comments?since=$(urlq "$SINCE")&per_page=$PER_PAGE&page=$page" "$jq_expr"
    if [ "$GH_STATUS" != "ok" ]; then
      scope_unobserved "$repo" comments "$GH_STATUS" "$GH_DETAIL" "$declared" "$candidates"
      return
    fi
    raw=$(page_count)
    if ! is_uint "$raw"; then
      scope_unobserved "$repo" comments unparsable "comment page $page was not parsable" "$declared" "$candidates"
      return
    fi
    while IFS='|' read -r id issue when has_token assoc app; do
      [ -n "$id" ] || continue
      examined=$((examined + 1))
      if [ "$(b64d "$has_token")" = "true" ]; then
        declared=$((declared + 1))
        continue
      fi
      candidates=$((candidates + 1))
      id=$(b64d "$id")
      issue=$(b64d "$issue")
      emit_candidate "$repo" comment "$id" "$(b64d "$when")" \
        "https://github.com/$repo/issues/$issue#issuecomment-$id" \
        "assoc=$(b64d "$assoc"),via_app=$(b64d "$app"),token=absent"
    done < <(page_records)
    [ "$raw" -eq "$PER_PAGE" ] || break
    page=$((page + 1))
  done

  if [ "$page" -gt "$MAX_PAGES" ]; then
    scope_unobserved "$repo" comments max-pages \
      "more comment pages than --max-pages $MAX_PAGES; the window was not fully read" "$declared" "$candidates"
    return
  fi
  scope_observed "$repo" comments "$examined" "$declared" "$candidates"
}

# ---------------------------------------------------------------------------
# Pull requests touched in the window. Both the reviews scope and the commits
# scope need this list, so it is collected once here rather than walked twice
# with two chances to drift.
#
# On success PR_NUMBERS holds the numbers and PR_STATUS is "ok"; otherwise
# PR_STATUS and PR_DETAIL name the could-not-observe for the caller to report
# against its own scope.
# ---------------------------------------------------------------------------
PR_NUMBERS=()
PR_STATUS=
PR_DETAIL=

# Both scopes of a repository want the same list, so the walk is paid for once.
# A failed walk is cached too: retrying it would spend the budget again to reach
# the same could-not-observe.
PR_CACHE_REPO=
PR_CACHE=()
PR_CACHE_STATUS=
PR_CACHE_DETAIL=

collect_prs() {
  local repo=$1
  if [ "$PR_CACHE_REPO" = "$repo" ]; then
    PR_NUMBERS=(${PR_CACHE[@]+"${PR_CACHE[@]}"})
    PR_STATUS=$PR_CACHE_STATUS
    PR_DETAIL=$PR_CACHE_DETAIL
    [ "$PR_STATUS" = "ok" ]
    return
  fi
  collect_prs_uncached "$repo"
  PR_CACHE_REPO=$repo
  PR_CACHE=(${PR_NUMBERS[@]+"${PR_NUMBERS[@]}"})
  PR_CACHE_STATUS=$PR_STATUS
  PR_CACHE_DETAIL=$PR_DETAIL
  [ "$PR_STATUS" = "ok" ]
}

collect_prs_uncached() {
  local repo=$1 page=1 raw number updated exhausted=0 pr_jq
  PR_NUMBERS=()
  PR_STATUS=
  PR_DETAIL=

  pr_jq="{n: length, r: [ .[] | [ ((.number|tostring)|@base64), ((.updated_at // \"\")|@base64) ] | join(\"|\") ]} $JQ_ENVELOPE"

  while [ "$page" -le "$MAX_PAGES" ]; do
    gh_get "/repos/$(urlq "$repo")/pulls?state=all&sort=updated&direction=desc&per_page=$PER_PAGE&page=$page" "$pr_jq"
    if [ "$GH_STATUS" != "ok" ]; then
      PR_STATUS=$GH_STATUS
      PR_DETAIL=$GH_DETAIL
      return 1
    fi
    raw=$(page_count)
    if ! is_uint "$raw"; then
      PR_STATUS=unparsable
      PR_DETAIL="pull request page $page was not parsable"
      return 1
    fi
    while IFS='|' read -r number updated; do
      [ -n "$number" ] || continue
      updated=$(b64d "$updated")
      if [ -n "$updated" ] && [ "$updated" \< "$SINCE" ]; then
        exhausted=1
        continue
      fi
      PR_NUMBERS+=("$(b64d "$number")")
    done < <(page_records)
    [ "$exhausted" -eq 0 ] || break
    [ "$raw" -eq "$PER_PAGE" ] || break
    page=$((page + 1))
  done

  if [ "$exhausted" -eq 0 ] && [ "$page" -gt "$MAX_PAGES" ]; then
    PR_STATUS=max-pages
    PR_DETAIL="more pull request pages than --max-pages $MAX_PAGES; the window was not fully walked"
    return 1
  fi

  PR_STATUS=ok
  return 0
}

# ---------------------------------------------------------------------------
# reviews: pull request review bodies. GitHub has no repository-wide review
# listing, so pull requests touched in the window are walked first.
# ---------------------------------------------------------------------------
sweep_reviews() {
  local repo=$1 page raw number
  local examined=0 declared=0 candidates=0
  local id when has_token assoc state
  local review_jq
  local prs=()

  if ! collect_prs "$repo"; then
    scope_unobserved "$repo" reviews "$PR_STATUS" "$PR_DETAIL" "$declared" "$candidates"
    return
  fi
  prs=(${PR_NUMBERS[@]+"${PR_NUMBERS[@]}"})

  review_jq="{n: length, r: [ .[]
    | select(.user.login == $ACCOUNT_JQ)
    | select((.submitted_at // \"\") >= $SINCE_JQ)
    | [ (.id|tostring|@base64),
        ((.submitted_at // \"\")|@base64),
        (((.body // \"\")|contains($TOKEN_JQ))|tostring|@base64),
        ((.author_association // \"\")|@base64),
        ((.state // \"\")|@base64) ]
    | join(\"|\") ]} $JQ_ENVELOPE"

  for number in ${prs[@]+"${prs[@]}"}; do
    page=1
    while [ "$page" -le "$MAX_PAGES" ]; do
      gh_get "/repos/$(urlq "$repo")/pulls/$number/reviews?per_page=$PER_PAGE&page=$page" "$review_jq"
      if [ "$GH_STATUS" != "ok" ]; then
        scope_unobserved "$repo" reviews "$GH_STATUS" "pull request $number: $GH_DETAIL" "$declared" "$candidates"
        return
      fi
      raw=$(page_count)
      if ! is_uint "$raw"; then
        scope_unobserved "$repo" reviews unparsable "reviews of pull request $number were not parsable" "$declared" "$candidates"
        return
      fi
      while IFS='|' read -r id when has_token assoc state; do
        [ -n "$id" ] || continue
        examined=$((examined + 1))
        if [ "$(b64d "$has_token")" = "true" ]; then
          declared=$((declared + 1))
          continue
        fi
        candidates=$((candidates + 1))
        id=$(b64d "$id")
        emit_candidate "$repo" review "$id" "$(b64d "$when")" \
          "https://github.com/$repo/pull/$number#pullrequestreview-$id" \
          "assoc=$(b64d "$assoc"),state=$(b64d "$state"),pr=$number,token=absent"
      done < <(page_records)
      [ "$raw" -eq "$PER_PAGE" ] || break
      page=$((page + 1))
    done
    if [ "$page" -gt "$MAX_PAGES" ]; then
      scope_unobserved "$repo" reviews max-pages \
        "pull request $number has more review pages than --max-pages $MAX_PAGES" "$declared" "$candidates"
      return
    fi
  done

  scope_observed "$repo" reviews "$examined" "$declared" "$candidates"
}

# ---------------------------------------------------------------------------
# commits: authored by the account. Branches are walked because the default
# branch alone would miss a commit pushed to a side branch, which is exactly
# where a browser session's commit lands.
#
# Pull request heads are walked too, and that pass is not redundant. A merged or
# closed pull request usually has its branch deleted, after which the commit is
# reachable by SHA and still visible on the pull request but appears in no
# branch listing at all. Branch enumeration alone would therefore go quiet on
# precisely the commits that are finished and shipped.
# ---------------------------------------------------------------------------
sweep_commits() {
  local repo=$1 page=1 raw name number
  local examined=0 declared=0 candidates=0
  local sha when has_token verified committer
  local branch_jq commit_jq label base source_seen
  local branches=()
  local labels=() paths=()
  local seen=" "

  if [ "${#BRANCHES[@]}" -gt 0 ]; then
    branches=("${BRANCHES[@]}")
  else
    branch_jq="{n: length, r: [ .[] | (.name|@base64) ]} $JQ_ENVELOPE"
    while [ "$page" -le "$MAX_PAGES" ]; do
      gh_get "/repos/$(urlq "$repo")/branches?per_page=$PER_PAGE&page=$page" "$branch_jq"
      if [ "$GH_STATUS" != "ok" ]; then
        scope_unobserved "$repo" commits "$GH_STATUS" "$GH_DETAIL" "$declared" "$candidates"
        return
      fi
      raw=$(page_count)
      if ! is_uint "$raw"; then
        scope_unobserved "$repo" commits unparsable "branch page $page was not parsable" "$declared" "$candidates"
        return
      fi
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        branches+=("$(b64d "$name")")
      done < <(page_records)
      [ "$raw" -eq "$PER_PAGE" ] || break
      page=$((page + 1))
    done
    if [ "$page" -gt "$MAX_PAGES" ]; then
      scope_unobserved "$repo" commits max-pages \
        "more branches than --max-pages $MAX_PAGES would list; some branches were never read" "$declared" "$candidates"
      return
    fi
  fi

  for name in ${branches[@]+"${branches[@]}"}; do
    labels+=("branch=$name")
    paths+=("/repos/$(urlq "$repo")/commits?sha=$(urlq "$name")&since=$(urlq "$SINCE")&author=$(urlq "$ACCOUNT")&per_page=$PER_PAGE")
  done

  # The pull request pass only makes sense for the whole repository; an explicit
  # --branch means the caller asked for exactly that branch.
  if [ "${#BRANCHES[@]}" -eq 0 ]; then
    if ! collect_prs "$repo"; then
      scope_unobserved "$repo" commits "$PR_STATUS" "$PR_DETAIL" "$declared" "$candidates"
      return
    fi
    for number in ${PR_NUMBERS[@]+"${PR_NUMBERS[@]}"}; do
      labels+=("pr=$number")
      paths+=("/repos/$(urlq "$repo")/pulls/$number/commits?per_page=$PER_PAGE")
    done
  fi

  # The pull request commit listing accepts neither an author nor a since
  # filter, so the window and the account are applied here for every source.
  # The raw page count stays unfiltered above this, so pagination still ends on
  # the real page length rather than on how many records survived.
  #
  # The window is compared against the LATER of the committer and author dates.
  # GitHub's own since= filters a branch listing on committer date, while a
  # rebase or cherry-pick - the fleet's routine lane workflow - keeps an author
  # date from before the window on a commit pushed inside it. Filtering on author
  # date alone would let the API return such a commit and then silently drop it
  # here, which is a write made invisible by a scope that still reads observed.
  commit_jq="{n: length, r: [ .[]
    | select(((.author.login) // \"\") == $ACCOUNT_JQ)
    | (((.commit.committer.date) // \"\")) as \$committed
    | (((.commit.author.date) // \"\")) as \$authored
    | (if \$committed >= \$authored then \$committed else \$authored end) as \$when
    | select(\$when >= $SINCE_JQ)
    | [ (.sha|@base64),
        (\$when|@base64),
        (((((.commit.message) // \"\")|contains($TOKEN_JQ)))|tostring|@base64),
        ((((.commit.verification.verified) // false)|tostring)|@base64),
        (((.committer.login) // \"none\")|@base64) ]
    | join(\"|\") ]} $JQ_ENVELOPE"

  local index=0
  while [ "$index" -lt "${#paths[@]}" ]; do
    label=${labels[$index]}
    base=${paths[$index]}
    index=$((index + 1))
    page=1
    source_seen=0
    while [ "$page" -le "$MAX_PAGES" ]; do
      gh_get "$base&page=$page" "$commit_jq"
      if [ "$GH_STATUS" != "ok" ]; then
        scope_unobserved "$repo" commits "$GH_STATUS" "$label: $GH_DETAIL" "$declared" "$candidates"
        return
      fi
      raw=$(page_count)
      if ! is_uint "$raw"; then
        scope_unobserved "$repo" commits unparsable "commits of $label were not parsable" "$declared" "$candidates"
        return
      fi
      source_seen=$((source_seen + raw))
      while IFS='|' read -r sha when has_token verified committer; do
        [ -n "$sha" ] || continue
        sha=$(b64d "$sha")
        case $seen in
          *" $sha "*) continue ;;
        esac
        seen="$seen$sha "
        examined=$((examined + 1))
        if [ "$(b64d "$has_token")" = "true" ]; then
          declared=$((declared + 1))
          continue
        fi
        candidates=$((candidates + 1))
        emit_candidate "$repo" commit "$sha" "$(b64d "$when")" \
          "https://github.com/$repo/commit/$sha" \
          "$label,signed=$(b64d "$verified"),committer=$(b64d "$committer"),token=absent"
      done < <(page_records)
      [ "$raw" -eq "$PER_PAGE" ] || break
      page=$((page + 1))
    done
    if [ "$page" -gt "$MAX_PAGES" ]; then
      scope_unobserved "$repo" commits max-pages \
        "$label has more commit pages than --max-pages $MAX_PAGES" "$declared" "$candidates"
      return
    fi
    # GitHub stops listing a pull request's commits at 250 and says nothing
    # about the rest, so reaching that wall is a boundary of what was seen.
    case $label in
      pr=*)
        if [ "$source_seen" -ge 250 ]; then
          scope_unobserved "$repo" commits pr-commit-cap \
            "$label reached GitHub's 250-commit listing limit; its remaining commits were never read" \
            "$declared" "$candidates"
          return
        fi
        ;;
    esac
  done

  scope_observed "$repo" commits "$examined" "$declared" "$candidates"
}

for repo in ${REPOS[@]+"${REPOS[@]}"}; do
  case $repo in
    */*) ;;
    *) scope_unobserved "$repo" '-' bad-request "not an owner/name repository"; continue ;;
  esac
  for kind in "${KINDS[@]}"; do
    case $kind in
      comments) sweep_comments "$repo" ;;
      reviews) sweep_reviews "$repo" ;;
      commits) sweep_commits "$repo" ;;
    esac
  done
done

print_summary

if [ "$SCOPES_UNOBSERVED" -gt 0 ]; then
  exit "$EXIT_UNOBSERVED"
fi
if [ "$TOTAL_CANDIDATES" -gt 0 ]; then
  exit "$EXIT_CANDIDATES"
fi
exit "$EXIT_CLEAN"
