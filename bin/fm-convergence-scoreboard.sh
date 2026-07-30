#!/usr/bin/env bash
# fm-convergence-scoreboard.sh - measure one local ref against one upstream ref.
#
# Usage:
#   bin/fm-convergence-scoreboard.sh <local-ref> <upstream-ref>
#   bin/fm-convergence-scoreboard.sh --help
#
# Both refs are required so reruns never inherit an ambient branch or remote.
# The current worktree must be clean because an uncommitted convergence step
# cannot be represented by either resolved commit identity.
# Each ref name must be unambiguous and resolve locally to a commit.
# The resolved commits must have exactly one merge base.
# Ahead and behind are graph counts from upstream...local.
# First-parent deliveries are local first-parent commits unreachable upstream.
# Diff metrics compare the unique merge base with the resolved local commit.
# Every Git subprocess uses an allowlisted environment with optional locks and
# lazy fetches disabled.
# Measurements ignore ambient config and replacement refs, source attributes
# from the local commit, and use a bare repository pinned to the source storage
# object format, so ambient Git state cannot change the resolved measurements.
# A failed graph or diff measurement exits before emitting partial metrics.
# Renames count as one deletion plus one addition so file grouping is stable.
# Git binary-file numstat markers count as zero lines while the paths still count.
# Every changed path belongs to exactly one of these ordered groups:
#   agent-runtime: AGENTS.md, CLAUDE.md, .agents/, and skills/
#   automation: bin/, .github/, .claude/, .codex/, .opencode/, and .pi/
#   tests: tests/
#   documentation: docs/, README.md, and CONTRIBUTING.md
#   configuration: .tasks.toml, .no-mistakes.yaml, and .gitignore
#   other: every remaining path
# Stdout is deterministic TOON without a trailing newline for help, successful
# results, and errors, and quoted strings escape every ASCII control character.
# Exit 0 means success, 1 means the comparison cannot be measured, and 2 means
# the invocation is invalid.
set -u

export LC_ALL=C

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"

toon_quote() {
  local value=$1 char code escaped='' i
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  for ((i = 0; i < ${#value}; i += 1)); do
    char=${value:i:1}
    if [[ "$char" == [[:cntrl:]] ]]; then
      printf -v code '%d' "'$char"
      if ((code < 32 || code == 127)); then
        printf -v char '\\u%04x' "$code"
      fi
    fi
    escaped+=$char
  done
  printf '"%s"' "$escaped"
}

display_bin() {
  if [ -n "${HOME-}" ] && [[ "$SELF" == "$HOME"/* ]]; then
    printf '%s/%s' '~' "${SELF#"$HOME"/}"
  else
    printf '%s' "$SELF"
  fi
}

usage() {
  printf 'bin: %s\n' "$(toon_quote "$(display_bin)")"
  printf 'description: %s\n' "$(toon_quote "Measure a clean local Git ref against an explicit upstream ref without changing either.")"
  printf 'usage: %s\n' "$(toon_quote "bin/fm-convergence-scoreboard.sh <local-ref> <upstream-ref>")"
  printf 'arguments[2]{name,description}:\n'
  printf '  %s,%s\n' \
    "$(toon_quote "local-ref")" \
    "$(toon_quote "Local delivery ref to measure.")"
  printf '  %s,%s\n' \
    "$(toon_quote "upstream-ref")" \
    "$(toon_quote "Fetched upstream ref to compare against.")"
  printf 'examples[2]: %s,%s' \
    "$(toon_quote "bin/fm-convergence-scoreboard.sh origin/main upstream/main")" \
    "$(toon_quote "bin/fm-convergence-scoreboard.sh HEAD upstream/main")"
}

usage_error() {
  printf 'error: %s\n' "$(toon_quote "$1")"
  usage
  exit 2
}

measure_error() {
  printf 'error: %s\n' "$(toon_quote "$1")"
  printf 'help[1]: %s' "$(toon_quote "$2")"
  exit 1
}

isolated_git() {
  local attr_source=$1 object_directory=$2
  local -a environment
  shift 2
  environment=(
    env -i
    "PATH=$PATH"
    "HOME=${HOME-}"
    "LC_ALL=C"
    "GIT_CONFIG_COUNT=0"
    "GIT_CONFIG_GLOBAL=/dev/null"
    "GIT_CONFIG_NOSYSTEM=1"
    "GIT_NO_LAZY_FETCH=1"
    "GIT_NO_REPLACE_OBJECTS=1"
    "GIT_OPTIONAL_LOCKS=0"
  )
  if [ -n "$attr_source" ]; then
    environment+=(
      "GIT_ATTR_NOSYSTEM=1"
      "GIT_ATTR_SOURCE=$attr_source"
      "GIT_OBJECT_DIRECTORY=$object_directory"
    )
  fi
  "${environment[@]}" git "$@"
}

preflight_git() {
  isolated_git '' '' "$@"
}

reject_ambiguous_ref() {
  local role=$1 ref=$2 diagnostics
  diagnostics=$(
    preflight_git -c core.warnAmbiguousRefs=true \
      -C "$REPO" rev-parse --symbolic-full-name "$ref" 2>&1 >/dev/null
  ) || true
  case "$diagnostics" in
    *"refname '$ref' is ambiguous"*)
      measure_error \
        "$role ref name is ambiguous: $ref" \
        "Use a fully qualified ref such as refs/heads/<name> or refs/remotes/<remote>/<name>, then rerun with the same two arguments."
      ;;
  esac
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  usage
  exit 0
fi

[ "$#" -eq 2 ] \
  || usage_error "expected exactly <local-ref> and <upstream-ref>"

case "$1" in
  -*) usage_error "unknown flag or invalid local ref: $1" ;;
esac
case "$2" in
  -*) usage_error "unknown flag or invalid upstream ref: $2" ;;
esac

LOCAL_REF=$1
UPSTREAM_REF=$2

if ! REPO=$(preflight_git rev-parse --show-toplevel 2>/dev/null) || [ -z "$REPO" ]; then
  measure_error \
    "current directory is not inside a Git worktree" \
    "Run this command from the clean worktree that contains both refs."
fi

if ! STATUS=$(preflight_git -C "$REPO" status --porcelain --untracked-files=normal 2>/dev/null); then
  measure_error \
    "cannot inspect the current worktree state" \
    "Verify the worktree is readable, then rerun the same command."
fi
if [ -n "$STATUS" ]; then
  measure_error \
    "current worktree is dirty" \
    "Commit or otherwise resolve every tracked and untracked change, then rerun with the same refs."
fi

reject_ambiguous_ref "local" "$LOCAL_REF"
reject_ambiguous_ref "upstream" "$UPSTREAM_REF"

if ! LOCAL_COMMIT=$(preflight_git -C "$REPO" rev-parse --verify --quiet "$LOCAL_REF^{commit}" 2>/dev/null); then
  measure_error \
    "local ref is missing, unfetched, or does not resolve to one commit: $LOCAL_REF" \
    "Fetch or create the local ref explicitly, then rerun with the same two arguments."
fi
if ! UPSTREAM_COMMIT=$(preflight_git -C "$REPO" rev-parse --verify --quiet "$UPSTREAM_REF^{commit}" 2>/dev/null); then
  measure_error \
    "upstream ref is missing, unfetched, or does not resolve to one commit: $UPSTREAM_REF" \
    "Fetch the upstream ref explicitly, then rerun with the same two arguments."
fi

if ! OBJECTS_DIR=$(preflight_git -C "$REPO" rev-parse --path-format=absolute --git-path objects 2>/dev/null); then
  measure_error \
    "cannot locate the repository object database" \
    "Verify the repository metadata, then rerun with the same refs."
fi
if ! OBJECT_FORMAT=$(preflight_git -C "$REPO" rev-parse --show-object-format=storage 2>/dev/null) \
  || [ -z "$OBJECT_FORMAT" ]; then
  measure_error \
    "cannot determine the repository object format" \
    "Verify the repository metadata, then rerun with the same refs."
fi

if ! MEASURE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-convergence-scoreboard.XXXXXX"); then
  measure_error \
    "cannot create isolated storage for measurements" \
    "Verify that the temporary directory is writable, then rerun with the same refs."
fi
MEASURE_GIT_DIR="$MEASURE_DIR/repository.git"
NUMSTAT_FILE="$MEASURE_DIR/numstat"
cleanup_measurement() {
  rm -rf -- "$MEASURE_DIR"
}
trap cleanup_measurement EXIT

if ! preflight_git init --bare --quiet --template= --object-format="$OBJECT_FORMAT" \
    "$MEASURE_GIT_DIR" 2>/dev/null; then
  measure_error \
    "cannot initialize isolated storage for measurements" \
    "Verify that the temporary directory is writable, then rerun with the same refs."
fi

measure_git() {
  isolated_git "$LOCAL_COMMIT" "$OBJECTS_DIR" \
    --no-replace-objects --git-dir="$MEASURE_GIT_DIR" \
    -c core.bigFileThreshold=512m "$@"
}

if ! MERGE_BASES=$(measure_git merge-base --all "$UPSTREAM_COMMIT" "$LOCAL_COMMIT" 2>/dev/null); then
  measure_error \
    "the refs have no common commit" \
    "Choose local and upstream refs from the same repository history."
fi
MERGE_BASE_COUNT=$(printf '%s\n' "$MERGE_BASES" | awk 'NF { count += 1 } END { print count + 0 }')
case "$MERGE_BASE_COUNT" in
  1) MERGE_BASE=$MERGE_BASES ;;
  0)
    measure_error \
      "the refs have no common commit" \
      "Choose local and upstream refs from the same repository history."
    ;;
  *)
    measure_error \
      "the refs have multiple merge bases, so the diff basis is ambiguous" \
      "Converge the histories to one merge base, then rerun with the same refs."
    ;;
esac

if ! GRAPH_COUNTS=$(measure_git rev-list --left-right --count "$UPSTREAM_COMMIT...$LOCAL_COMMIT" 2>/dev/null); then
  measure_error \
    "cannot count commits between the resolved refs" \
    "Verify the repository object database, then rerun with the same refs."
fi
read -r BEHIND AHEAD <<< "$GRAPH_COUNTS"

if ! FIRST_PARENT_DELIVERIES=$(measure_git rev-list --first-parent --count "$UPSTREAM_COMMIT..$LOCAL_COMMIT" 2>/dev/null); then
  measure_error \
    "cannot count first-parent local deliveries" \
    "Verify the repository object database, then rerun with the same refs."
fi

CHANGED_FILES=0
INSERTIONS=0
DELETIONS=0

AGENT_FILES=0
AGENT_INSERTIONS=0
AGENT_DELETIONS=0
AUTOMATION_FILES=0
AUTOMATION_INSERTIONS=0
AUTOMATION_DELETIONS=0
TEST_FILES=0
TEST_INSERTIONS=0
TEST_DELETIONS=0
DOC_FILES=0
DOC_INSERTIONS=0
DOC_DELETIONS=0
CONFIG_FILES=0
CONFIG_INSERTIONS=0
CONFIG_DELETIONS=0
OTHER_FILES=0
OTHER_INSERTIONS=0
OTHER_DELETIONS=0

if ! measure_git diff --numstat -z --no-renames --no-ext-diff --no-textconv \
  --diff-algorithm=myers --no-indent-heuristic "$MERGE_BASE" "$LOCAL_COMMIT" \
  > "$NUMSTAT_FILE" 2>/dev/null; then
  measure_error \
    "cannot calculate diff metrics between the resolved refs" \
    "Verify that all repository objects are available locally, then rerun with the same refs."
fi

while IFS= read -r -d '' record; do
  added=${record%%$'\t'*}
  remainder=${record#*$'\t'}
  deleted=${remainder%%$'\t'*}
  path=${remainder#*$'\t'}
  [ "$added" = "-" ] && added=0
  [ "$deleted" = "-" ] && deleted=0
  CHANGED_FILES=$((CHANGED_FILES + 1))
  INSERTIONS=$((INSERTIONS + added))
  DELETIONS=$((DELETIONS + deleted))
  case "$path" in
    AGENTS.md|CLAUDE.md|.agents/*|skills/*)
      AGENT_FILES=$((AGENT_FILES + 1))
      AGENT_INSERTIONS=$((AGENT_INSERTIONS + added))
      AGENT_DELETIONS=$((AGENT_DELETIONS + deleted))
      ;;
    bin/*|.github/*|.claude/*|.codex/*|.opencode/*|.pi/*)
      AUTOMATION_FILES=$((AUTOMATION_FILES + 1))
      AUTOMATION_INSERTIONS=$((AUTOMATION_INSERTIONS + added))
      AUTOMATION_DELETIONS=$((AUTOMATION_DELETIONS + deleted))
      ;;
    tests/*)
      TEST_FILES=$((TEST_FILES + 1))
      TEST_INSERTIONS=$((TEST_INSERTIONS + added))
      TEST_DELETIONS=$((TEST_DELETIONS + deleted))
      ;;
    docs/*|README.md|CONTRIBUTING.md)
      DOC_FILES=$((DOC_FILES + 1))
      DOC_INSERTIONS=$((DOC_INSERTIONS + added))
      DOC_DELETIONS=$((DOC_DELETIONS + deleted))
      ;;
    .tasks.toml|.no-mistakes.yaml|.gitignore)
      CONFIG_FILES=$((CONFIG_FILES + 1))
      CONFIG_INSERTIONS=$((CONFIG_INSERTIONS + added))
      CONFIG_DELETIONS=$((CONFIG_DELETIONS + deleted))
      ;;
    *)
      OTHER_FILES=$((OTHER_FILES + 1))
      OTHER_INSERTIONS=$((OTHER_INSERTIONS + added))
      OTHER_DELETIONS=$((OTHER_DELETIONS + deleted))
      ;;
  esac
done < "$NUMSTAT_FILE"

printf 'schema: %s\n' "$(toon_quote "fm-convergence-scoreboard.v1")"
printf 'local:\n'
printf '  ref: %s\n' "$(toon_quote "$LOCAL_REF")"
printf '  commit: %s\n' "$(toon_quote "$LOCAL_COMMIT")"
printf 'upstream:\n'
printf '  ref: %s\n' "$(toon_quote "$UPSTREAM_REF")"
printf '  commit: %s\n' "$(toon_quote "$UPSTREAM_COMMIT")"
printf 'commits:\n'
printf '  ahead: %s\n' "$AHEAD"
printf '  behind: %s\n' "$BEHIND"
printf '  first_parent_deliveries: %s\n' "$FIRST_PARENT_DELIVERIES"
printf 'diff:\n'
printf '  base_commit: %s\n' "$(toon_quote "$MERGE_BASE")"
printf '  changed_files: %s\n' "$CHANGED_FILES"
printf '  insertions: %s\n' "$INSERTIONS"
printf '  deletions: %s\n' "$DELETIONS"
printf '  net_lines: %s\n' "$((INSERTIONS - DELETIONS))"
printf 'file_groups[6]{name,changed_files,insertions,deletions,net_lines}:\n'
printf '  %s,%s,%s,%s,%s\n' \
  "$(toon_quote "agent-runtime")" "$AGENT_FILES" "$AGENT_INSERTIONS" "$AGENT_DELETIONS" \
  "$((AGENT_INSERTIONS - AGENT_DELETIONS))"
printf '  %s,%s,%s,%s,%s\n' \
  "$(toon_quote "automation")" "$AUTOMATION_FILES" "$AUTOMATION_INSERTIONS" "$AUTOMATION_DELETIONS" \
  "$((AUTOMATION_INSERTIONS - AUTOMATION_DELETIONS))"
printf '  %s,%s,%s,%s,%s\n' \
  "$(toon_quote "tests")" "$TEST_FILES" "$TEST_INSERTIONS" "$TEST_DELETIONS" \
  "$((TEST_INSERTIONS - TEST_DELETIONS))"
printf '  %s,%s,%s,%s,%s\n' \
  "$(toon_quote "documentation")" "$DOC_FILES" "$DOC_INSERTIONS" "$DOC_DELETIONS" \
  "$((DOC_INSERTIONS - DOC_DELETIONS))"
printf '  %s,%s,%s,%s,%s\n' \
  "$(toon_quote "configuration")" "$CONFIG_FILES" "$CONFIG_INSERTIONS" "$CONFIG_DELETIONS" \
  "$((CONFIG_INSERTIONS - CONFIG_DELETIONS))"
printf '  %s,%s,%s,%s,%s' \
  "$(toon_quote "other")" "$OTHER_FILES" "$OTHER_INSERTIONS" "$OTHER_DELETIONS" \
  "$((OTHER_INSERTIONS - OTHER_DELETIONS))"
