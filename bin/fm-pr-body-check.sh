#!/usr/bin/env bash
# Fetch a pull request's LIVE title and body and flag phrases that do not belong
# in public, reviewer-facing writing: meta-instructions aimed at a reviewer or a
# bot, second-person direction, internal firstmate vocabulary, and agent
# co-authors.
#
# Why this exists: no-mistakes renders the `--intent` string VERBATIM into the
# PR body, so intent text written for an internal audience is published to the
# repo's maintainers. A crewmate that opens a PR must confirm what it actually
# PUBLISHED, not what it believes it passed in, so this reads the body back from
# the API.
#
# Usage: fm-pr-body-check.sh <pr-url>          check the live PR (title + body)
#        fm-pr-body-check.sh --file <path>     check a draft locally, e.g. the
#                                              intent text before passing it
#
# This tool SURFACES lines; it does not judge them. A match is a line to READ,
# never a verdict, and a hit count alone is misleading: legitimate prose in a
# PR against firstmate itself names "firstmate" and "crewmate" all the time.
# Every flagged line is printed in full for exactly that reason.
#
# The trailing `## Pipeline` section no-mistakes generates is NOT scanned: it is
# machine-written boilerplate that names no-mistakes on every PR, and a check
# that can never come back clean is a check nobody reads. Everything above it -
# the title, the intent text, and any prose - is scanned.
#
# Exit codes:
#   0  nothing flagged
#   1  flagged lines printed; read each one and judge it
#   2  usage error, unparseable PR URL, the body could not be fetched, or the
#      scan itself failed - never a silent "clean" on a body that was not read
#
# Repairing a dirty body: `gh pr edit --body` can silently NO-OP (observed
# failing with "GraphQL: Projects (classic) is being deprecated", changing
# nothing while reporting success). Use the REST API instead:
#   gh api -X PATCH repos/OWNER/REPO/pulls/<n> -F body=@<file>
# then re-run this check against the live PR.
set -eu

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') usage >&2; exit 2 ;;
esac

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-body-check.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
TMP="$WORK/text"
SCAN="$WORK/scan"
HITS="$WORK/hits"
GH_ERR="$WORK/gh-err"

TARGET=""
SOURCE=""
if [ "$1" = --file ]; then
  TARGET=${2:-}
  [ -n "$TARGET" ] || { echo "error: --file needs a path" >&2; exit 2; }
  [ -f "$TARGET" ] || { echo "error: no such file: $TARGET" >&2; exit 2; }
  SOURCE="draft $TARGET"
  TEXT=$(cat "$TARGET")
else
  URL=$1
  # https://github.com/<owner>/<repo>/pull/<n>
  if ! [[ $URL =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$ ]]; then
    echo "error: expected a full PR URL like https://github.com/owner/repo/pull/123, got: $URL" >&2
    exit 2
  fi
  OWNER=${BASH_REMATCH[1]}
  REPO=${BASH_REMATCH[2]}
  NUMBER=${BASH_REMATCH[3]}
  SOURCE="live PR $URL"
  # gh's stderr stays OUT of $TEXT: a deprecation notice folded into the body
  # would be scanned and printed back as if the PR had published it.
  if ! TEXT=$(gh api "repos/$OWNER/$REPO/pulls/$NUMBER" --jq '.title + "\n" + (.body // "")' 2>"$GH_ERR"); then
    echo "error: could not fetch the live PR body: $(cat "$GH_ERR")" >&2
    exit 2
  fi
  # A PR always has a title, so empty text means the read produced nothing, not
  # that the PR is empty. Scanning it would print "clean" for a body nobody read.
  if [ -z "$(printf '%s' "$TEXT" | tr -d '[:space:]')" ]; then
    echo "error: could not fetch the live PR body: the API returned no title or body for $URL" >&2
    exit 2
  fi
fi

# Each entry is "<label>\t<extended regex>", matched case-insensitively.
# Deliberately broad: this is a prompt to read a line, not a classifier. The one
# limit on that breadth is words that are ordinary English in other repos - a
# "worktree", a "harness", a "captain" - which fire on innocent prose in every
# project in the fleet, and steady false noise is how a real leak stops being
# read. Only unmistakably internal names are listed.
# Word boundaries are spelled out as character classes rather than `\b`, which is
# a GNU extension: under BSD grep (stock macOS) a `\b` pattern would quietly
# match nothing and report a dirty body clean.
B_OPEN='(^|[^[:alnum:]_])'
B_CLOSE='([^[:alnum:]_]|$)'
PATTERNS=(
  $'meta-instruction\tdo(es)? ?n[o\']?t (re-?raise|raise|flag|surface|question|re-?open|suggest|comment|nitpick|review|change)'
  $'meta-instruction\talready (been )?(decided|made|agreed|settled|discussed)'
  $'meta-instruction\tdeliberate (decision|choice|scope)'
  $'meta-instruction\t(user|captain|reviewer|maintainer) (explicitly )?(declined|decided|approved|asked|wants)'
  $'meta-instruction\tnot (a concern|surprising|in scope|to be flagged)'
  $'meta-instruction\t(title|body|pr) (must|should|shall) (not )?(be|name|add|mention|contain)'
  "second-person direction"$'\t'"${B_OPEN}you (must|should|shall|will|need to|are to|may not)${B_CLOSE}"
  "internal vocabulary"$'\t'"${B_OPEN}(firstmate|crewmate|secondmate|scout task|ship task|task id|no-mistakes|the brief|this brief)${B_CLOSE}"
  $'agent co-author\tco-authored-by:.*(claude|opus|sonnet|haiku|gpt|codex|copilot|agent|bot)'
)

printf '%s\n' "$TEXT" > "$TMP"

# The no-mistakes pipeline appends its own trailing "## Pipeline" section to the
# bodies it publishes, and the generated "Updates from [git push no-mistakes]"
# link in it always matches the internal-vocabulary pattern. That footer is not
# the author's writing, and a check that can never report clean is one nobody
# reads: scan only the body ABOVE it. The cut needs BOTH the heading and the
# generated link, so a "## Pipeline" heading someone actually wrote is still
# scanned, and truncating a suffix keeps every line number intact.
CUT=$(awk '
  /^## Pipeline[[:space:]]*$/ { start = FNR; next }
  start && /Updates from \[git push no-mistakes\]/ { print start; exit }
' "$TMP")
if [ -n "$CUT" ]; then
  head -n "$((CUT - 1))" "$TMP" > "$SCAN"
else
  cp "$TMP" "$SCAN"
fi

# Every hit is recorded as "<line number>\t<label>"; associative arrays would
# pin this script to bash 4, and stock macOS ships bash 3.2.
: > "$HITS"
MATCH="$WORK/match"
for entry in "${PATTERNS[@]}"; do
  label=${entry%%$'\t'*}
  regex=${entry#*$'\t'}
  # Only grep's "no match" (1) is tolerated. An error (2+: a regex the local
  # engine cannot compile, an unreadable file) would otherwise contribute zero
  # hits and let an unscanned body report clean - the one failure this tool
  # exists to prevent.
  status=0
  grep -n -i -E -- "$regex" "$SCAN" > "$MATCH" || status=$?
  if [ "$status" -gt 1 ]; then
    echo "error: the scan failed (grep exit $status) on the [$label] pattern; the body was NOT checked" >&2
    exit 2
  fi
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    printf '%s\t%s\n' "${hit%%:*}" "$label" >> "$HITS"
  done < "$MATCH"
done

if [ ! -s "$HITS" ]; then
  printf 'clean (%s): nothing flagged.\n' "$SOURCE"
  exit 0
fi

printf 'FLAGGED (%s) - read each line below and judge it; a hit is not a verdict.\n\n' "$SOURCE"
# A line matching several patterns is still one line to read, so labels are
# collected per line number and the line is printed once, in file order.
awk -F'\t' '
  NR == FNR {
    if (!seen[$1 SUBSEP $2]++) {
      labels[$1] = ($1 in labels) ? labels[$1] " " $2 : $2
    }
    next
  }
  FNR in labels { printf "  line %s [%s]: %s\n", FNR, labels[FNR], $0 }
' "$HITS" "$SCAN"

cat <<'EOF'

These lines are PUBLIC: a maintainer who knows nothing about how this change was
produced will read them. Some matches are legitimate (a PR about firstmate names
firstmate), so read them - do not act on the count.

To rewrite a dirty body, do NOT use `gh pr edit --body`: it can silently NO-OP.
  gh api -X PATCH repos/OWNER/REPO/pulls/<n> -F body=@<file>
Then re-run this check against the live PR.
EOF
exit 1
