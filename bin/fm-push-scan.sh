#!/usr/bin/env bash
# Guard a branch push with one explicitly selected fleet-local term list.
#
# The selected list is resolved only below the absolute fleet home, never from
# the caller's current directory. FM_HOME defaults to this script's repository
# root; when set, it must itself be absolute. The two directions stay separate:
#   company   config/company-push-terms.txt (tooling identity entering company code)
#   sensitive config/sensitive-terms.txt (private/project identity entering public code)
#
# Comment lines (optionally indented) and blank lines are removed before use.
# Every attempted scan prints the loaded-pattern count before any result. A
# missing, non-regular, unreadable, invalid, or zero-pattern list prints no
# clean/hit result and exits 2. A completed clean scan exits 0; any hit prints
# its pattern, source, and matching line, then exits 1.
#
# Every completed scan covers git diff origin/main...HEAD, the branch name, all
# commit messages and authors in origin/main..HEAD, and the exact pull-request
# title and body supplied as files. Both PR files are mandatory, including when
# rescanning text read back from a published pull request.
#
# Usage:
#   fm-push-scan.sh <company|sensitive> --pr-title-file <path> --pr-body-file <path>
#   fm-push-scan.sh --help
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail_before_patterns() { # <list-kind> <list-path> <diagnostic>
  printf 'fm-push-scan: patterns loaded: 0 (list=%s, path=%s)\n' "$1" "$2"
  printf 'fm-push-scan: error: %s\n' "$3" >&2
  exit 2
}

fail_after_patterns() { # <diagnostic>
  printf 'fm-push-scan: error: %s\n' "$1" >&2
  exit 2
}

emit_scan_record() { # <record-kind> <record>
  local record_kind=$1 record=$2
  if ! printf '%s\n' "$record"; then
    fail_after_patterns "could not write $record_kind scan record"
  fi
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

[ "$#" -ge 1 ] || {
  printf 'fm-push-scan: error: select exactly one list: company or sensitive.\n' >&2
  usage >&2
  exit 2
}
LIST_KIND=$1
shift
case "$LIST_KIND" in
  company) LIST_REL=config/company-push-terms.txt ;;
  sensitive) LIST_REL=config/sensitive-terms.txt ;;
  *)
    printf 'fm-push-scan: error: unknown list %s; select exactly company or sensitive.\n' "$LIST_KIND" >&2
    exit 2
    ;;
esac

PR_TITLE_FILE=
PR_BODY_FILE=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr-title-file)
      [ "$#" -ge 2 ] || { printf 'fm-push-scan: error: --pr-title-file requires a path.\n' >&2; exit 2; }
      PR_TITLE_FILE=$2
      shift 2
      ;;
    --pr-title-file=*)
      PR_TITLE_FILE=${1#*=}
      shift
      ;;
    --pr-body-file)
      [ "$#" -ge 2 ] || { printf 'fm-push-scan: error: --pr-body-file requires a path.\n' >&2; exit 2; }
      PR_BODY_FILE=$2
      shift 2
      ;;
    --pr-body-file=*)
      PR_BODY_FILE=${1#*=}
      shift
      ;;
    --)
      shift
      [ "$#" -eq 0 ] || { printf 'fm-push-scan: error: unexpected positional arguments.\n' >&2; exit 2; }
      ;;
    *)
      printf 'fm-push-scan: error: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done
[ -n "$PR_TITLE_FILE" ] || { printf 'fm-push-scan: error: --pr-title-file is required.\n' >&2; exit 2; }
[ -n "$PR_BODY_FILE" ] || { printf 'fm-push-scan: error: --pr-body-file is required.\n' >&2; exit 2; }

HOME_INPUT=${FM_HOME:-$SCRIPT_ROOT}
case "$HOME_INPUT" in
  /*) ;;
  *)
    fail_before_patterns "$LIST_KIND" "$HOME_INPUT/$LIST_REL" \
      "FM_HOME must be an absolute directory: $HOME_INPUT"
    ;;
esac
if [ -d "$HOME_INPUT" ]; then
  FLEET_HOME=$(CDPATH='' cd -- "$HOME_INPUT" 2>/dev/null && pwd -P) || \
    fail_before_patterns "$LIST_KIND" "$HOME_INPUT/$LIST_REL" \
      "fleet home cannot be resolved: $HOME_INPUT"
else
  FLEET_HOME=$HOME_INPUT
fi
LIST_PATH="$FLEET_HOME/$LIST_REL"

[ -e "$LIST_PATH" ] || \
  fail_before_patterns "$LIST_KIND" "$LIST_PATH" \
    "$LIST_KIND pattern list is missing: $LIST_PATH"
[ -f "$LIST_PATH" ] && [ -r "$LIST_PATH" ] || \
  fail_before_patterns "$LIST_KIND" "$LIST_PATH" \
    "$LIST_KIND pattern list is not a readable regular file: $LIST_PATH"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-push-scan.XXXXXX") || \
  fail_before_patterns "$LIST_KIND" "$LIST_PATH" "could not create a private scan directory"
# shellcheck disable=SC2329 # Invoked indirectly by the EXIT trap.
cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
PATTERNS="$TMP_ROOT/patterns"
if ! awk '
  {
    sub(/\r$/, "")
    if ($0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/) next
    print
  }
' "$LIST_PATH" > "$PATTERNS"; then
  fail_before_patterns "$LIST_KIND" "$LIST_PATH" \
    "$LIST_KIND pattern list could not be read: $LIST_PATH"
fi
PATTERN_COUNT=$(awk 'END { print NR + 0 }' "$PATTERNS")
emit_scan_record "loaded-pattern count" \
  "fm-push-scan: patterns loaded: $PATTERN_COUNT (list=$LIST_KIND, path=$LIST_PATH)"
[ "$PATTERN_COUNT" -gt 0 ] || \
  fail_after_patterns "$LIST_KIND pattern list yielded zero usable patterns after comments and blank lines were removed: $LIST_PATH"

GREP_ERROR="$TMP_ROOT/grep-error"
if ! exec 3> "$GREP_ERROR"; then
  fail_after_patterns "opening the regular-expression diagnostic output failed"
fi
LC_ALL=C grep -aEi -f "$PATTERNS" /dev/null >/dev/null 2>&3
GREP_RC=$?
exec 3>&-
case "$GREP_RC" in
  0|1) ;;
  *)
    GREP_DETAIL=$(tr '\n' ' ' < "$GREP_ERROR")
    fail_after_patterns "$LIST_KIND pattern list contains an invalid extended regular expression: ${GREP_DETAIL:-grep exited $GREP_RC}"
    ;;
esac

[ -f "$PR_TITLE_FILE" ] && [ -r "$PR_TITLE_FILE" ] || \
  fail_after_patterns "pull-request title is not a readable regular file: $PR_TITLE_FILE"
[ -f "$PR_BODY_FILE" ] && [ -r "$PR_BODY_FILE" ] || \
  fail_after_patterns "pull-request body is not a readable regular file: $PR_BODY_FILE"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || \
  fail_after_patterns "current directory is not inside a git repository"
REPO_ROOT=$(CDPATH='' cd -- "$REPO_ROOT" 2>/dev/null && pwd -P) || \
  fail_after_patterns "git repository root cannot be resolved"
git -C "$REPO_ROOT" rev-parse --verify 'origin/main^{commit}' >/dev/null 2>&1 || \
  fail_after_patterns "required base origin/main is missing or is not a commit"
BRANCH=$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null) || \
  fail_after_patterns "HEAD is detached; a branch name is required for the scan"

DIFF_FILE="$TMP_ROOT/diff"
BRANCH_FILE="$TMP_ROOT/branch"
MESSAGES_FILE="$TMP_ROOT/commit-messages"
AUTHORS_FILE="$TMP_ROOT/commit-authors"
TITLE_FILE="$TMP_ROOT/pull-request-title"
BODY_FILE="$TMP_ROOT/pull-request-body"
if ! git -C "$REPO_ROOT" --no-pager diff --no-ext-diff --no-color origin/main...HEAD -- > "$DIFF_FILE"; then
  fail_after_patterns "git diff origin/main...HEAD failed"
fi
if ! printf '%s\n' "$BRANCH" > "$BRANCH_FILE"; then
  fail_after_patterns "materializing the branch scan source failed"
fi
if ! git -C "$REPO_ROOT" --no-pager log --format=%B origin/main..HEAD > "$MESSAGES_FILE"; then
  fail_after_patterns "reading commit messages from origin/main..HEAD failed"
fi
if ! git -C "$REPO_ROOT" --no-pager log --format='%an <%ae>' origin/main..HEAD > "$AUTHORS_FILE"; then
  fail_after_patterns "reading commit authors from origin/main..HEAD failed"
fi
if ! cat < "$PR_TITLE_FILE" > "$TITLE_FILE"; then
  fail_after_patterns "pull-request title could not be read: $PR_TITLE_FILE"
fi
if ! cat < "$PR_BODY_FILE" > "$BODY_FILE"; then
  fail_after_patterns "pull-request body could not be read: $PR_BODY_FILE"
fi

SOURCE_LABELS=(
  diff
  branch
  commit-messages
  commit-authors
  pull-request-title
  pull-request-body
)
SOURCE_FILES=(
  "$DIFF_FILE"
  "$BRANCH_FILE"
  "$MESSAGES_FILE"
  "$AUTHORS_FILE"
  "$TITLE_FILE"
  "$BODY_FILE"
)
HITS=0
SOURCE_INDEX=0
while [ "$SOURCE_INDEX" -lt "${#SOURCE_FILES[@]}" ]; do
  SOURCE=${SOURCE_FILES[$SOURCE_INDEX]}
  LABEL=${SOURCE_LABELS[$SOURCE_INDEX]}
  PATTERN_INDEX=0
  if ! exec 3< "$PATTERNS"; then
    fail_after_patterns "opening the pattern input for $LABEL failed"
  fi
  while IFS= read -r PATTERN <&3 || [ -n "$PATTERN" ]; do
    PATTERN_INDEX=$((PATTERN_INDEX + 1))
    MATCHES="$TMP_ROOT/matches"
    if ! exec 4> "$MATCHES"; then
      fail_after_patterns "opening the match output for $LABEL pattern $PATTERN_INDEX failed"
    fi
    if ! exec 5> "$GREP_ERROR"; then
      exec 4>&-
      fail_after_patterns "opening the grep diagnostic output for $LABEL pattern $PATTERN_INDEX failed"
    fi
    LC_ALL=C grep -aEin -- "$PATTERN" "$SOURCE" >&4 2>&5
    GREP_RC=$?
    exec 4>&-
    exec 5>&-
    case "$GREP_RC" in
      0)
        HITS=1
        if ! exec 4< "$MATCHES"; then
          fail_after_patterns "opening the match input for $LABEL pattern $PATTERN_INDEX failed"
        fi
        MATCH_COUNT=0
        while IFS= read -r MATCH <&4 || [ -n "$MATCH" ]; do
          MATCH_COUNT=$((MATCH_COUNT + 1))
          emit_scan_record "hit" \
            "fm-push-scan: hit: source=$LABEL pattern[$PATTERN_INDEX]=$PATTERN match=$MATCH"
        done
        exec 4<&-
        [ "$MATCH_COUNT" -gt 0 ] || \
          fail_after_patterns "grep reported a hit without readable match output for $LABEL pattern $PATTERN_INDEX"
        ;;
      1) ;;
      *)
        GREP_DETAIL=$(tr '\n' ' ' < "$GREP_ERROR")
        fail_after_patterns "grep failed while scanning $LABEL with pattern $PATTERN_INDEX: ${GREP_DETAIL:-exit $GREP_RC}"
        ;;
    esac
  done
  exec 3<&-
  [ "$PATTERN_INDEX" -eq "$PATTERN_COUNT" ] || \
    fail_after_patterns "pattern input ended early while scanning $LABEL (read $PATTERN_INDEX of $PATTERN_COUNT)"
  SOURCE_INDEX=$((SOURCE_INDEX + 1))
done

if [ "$HITS" -ne 0 ]; then
  emit_scan_record "final result" "fm-push-scan: result: hits found"
  exit 1
fi
emit_scan_record "final result" "fm-push-scan: result: clean"
exit 0
