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
# Exit codes:
#   0  nothing flagged
#   1  flagged lines printed; read each one and judge it
#   2  usage error, unparseable PR URL, or the body could not be fetched
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
  if ! TEXT=$(gh api "repos/$OWNER/$REPO/pulls/$NUMBER" --jq '.title + "\n" + (.body // "")' 2>&1); then
    echo "error: could not fetch the live PR body: $TEXT" >&2
    exit 2
  fi
fi

# Each entry is "<label>\t<extended regex>", matched case-insensitively.
# Deliberately broad: this is a prompt to read a line, not a classifier.
PATTERNS=(
  $'meta-instruction\tdo(es)? ?n[o\']?t (re-?raise|raise|flag|surface|question|re-?open|suggest|comment|nitpick|review|change)'
  $'meta-instruction\talready (been )?(decided|made|agreed|settled|discussed)'
  $'meta-instruction\tdeliberate (decision|choice|scope)'
  $'meta-instruction\t(user|captain|reviewer|maintainer) (explicitly )?(declined|decided|approved|asked|wants)'
  $'meta-instruction\tnot (a concern|surprising|in scope|to be flagged)'
  $'meta-instruction\t(title|body|pr) (must|should|shall) (not )?(be|name|add|mention|contain)'
  $'second-person direction\t\\byou (must|should|shall|will|need to|are to|may not)\\b'
  $'internal vocabulary\t\\b(firstmate|crewmate|secondmate|captain|scout task|ship task|task id|worktree|harness|no-mistakes|the brief|this brief)\\b'
  $'agent co-author\tco-authored-by:.*(claude|opus|sonnet|haiku|gpt|codex|copilot|agent|bot)'
)

TMP=$(mktemp "${TMPDIR:-/tmp}/fm-pr-body-check.XXXXXX")
trap 'rm -f "$TMP"' EXIT
printf '%s\n' "$TEXT" > "$TMP"

# A line matching several patterns is still one line to read, so labels are
# collected per line number and the line is printed once, in file order.
declare -A LABELS=()
declare -A TEXTS=()
for entry in "${PATTERNS[@]}"; do
  label=${entry%%$'\t'*}
  regex=${entry#*$'\t'}
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    lineno=${hit%%:*}
    case " ${LABELS[$lineno]:-} " in
      *" $label "*) : ;;
      *) LABELS[$lineno]="${LABELS[$lineno]:+${LABELS[$lineno]} }$label" ;;
    esac
    TEXTS[$lineno]=${hit#*:}
  done < <(grep -n -i -E -- "$regex" "$TMP" || true)
done

flagged=0
for lineno in $(printf '%s\n' "${!TEXTS[@]}" | sort -n); do
  if [ "$flagged" -eq 0 ]; then
    printf 'FLAGGED (%s) - read each line below and judge it; a hit is not a verdict.\n\n' "$SOURCE"
    flagged=1
  fi
  printf '  line %s [%s]: %s\n' "$lineno" "${LABELS[$lineno]}" "${TEXTS[$lineno]}"
done

if [ "$flagged" -eq 1 ]; then
  cat <<'EOF'

These lines are PUBLIC: a maintainer who knows nothing about how this change was
produced will read them. Some matches are legitimate (a PR about firstmate names
firstmate), so read them - do not act on the count.

To rewrite a dirty body, do NOT use `gh pr edit --body`: it can silently NO-OP.
  gh api -X PATCH repos/OWNER/REPO/pulls/<n> -F body=@<file>
Then re-run this check against the live PR.
EOF
  exit 1
fi

printf 'clean (%s): nothing flagged.\n' "$SOURCE"
