#!/usr/bin/env bash
# fm-verify-delivered.sh - MECHANISM, not a promise.
#
# Firstmate repeatedly reported work as delivered without checking the merged
# result against what was asked (2026-07-28/29: Stage 6 "every comparison
# through NS" when 16 files still used strings; PR 657 merged with 11 files
# still string-only after "solve every brand-related bug").
#
# Run this BEFORE telling the captain a PR delivered a capability, and BEFORE
# marking a task done. It checks the CLAIM against the CODE, not the report.
#
# Usage:
#   fm-verify-delivered.sh brand-identity [--no-fetch]
#                                    who still decides brand identity by string
#   fm-verify-delivered.sh <task-id>  acceptance claims in a brief, to check by hand
#   fm-verify-delivered.sh --help     print this header
#
# The exit status is the verdict, and only 0 may be read as delivered:
#   0  CLEAN              inspected one or more files and found no violation
#                         (in task-id mode: acceptance claims were extracted,
#                         which is a checklist to work through, not a verdict)
#   1  VIOLATIONS         found violations, listed above the verdict line
#   2  USAGE              bad invocation
#   3  INSPECTED NOTHING  the search matched no files, so it proves nothing
#   4  SEARCH FAILED      the search itself errored, so the answer is unknown
#
# Outcomes 3 and 4 exist because this verifier twice printed a clean result
# while checking nothing. First its pathspec matched no files, and git grep
# reports that as an ordinary no-match, so zero files inspected read as zero
# violations found. Then a git grep no-match status aborted the whole run under
# `set -o pipefail`, so it printed its header and stopped. A verifier that
# cannot say "I do not know" converts unknown into clean, which is worse than
# having no verifier at all. Every git search below therefore classifies its own
# exit status, and every count of what was actually inspected is checked before
# any clean verdict is allowed to print.
#
# A rev nobody could refresh is unknown for the same reason. brand-identity
# fetches origin before it reads $REV, and a fetch that was asked for and failed
# is outcome 4, not a warning: the verdict would otherwise be computed against
# whatever origin/main happens to be locally. --no-fetch is the honest opt-in for
# inspecting a local ref on purpose, and it never errors.
#
# tests/fm-verify-delivered.test.sh holds one regression test per outcome.
#
# Environment:
#   FM_VERIFY_REPO  repo brand-identity inspects. Resolution order: this
#                   variable, then the path data/projects.md records for
#                   inception as `repo at <path>` on its `- inception ...` line
#                   (this script parses that form directly; the registry's mode
#                   field is fm-project-mode.sh's business), then
#                   $FM_HOME/projects/inception. A miss is outcome 4, never clean.
#   FM_VERIFY_REV   rev brand-identity inspects (default: origin/main)
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REV="${FM_VERIFY_REV:-origin/main}"

# brand-identity's definition of the migration: which files are candidates, who
# is allowed to own string comparison, and what counts as consulting the graph.
BRAND_PATHSPEC="schema-generator/app"
BRAND_CANDIDATE_RE='is_same_brand|normalize_entity|is_competitor_reference'
BRAND_GRAPH_RE='graph_directives|brand_relations|ns_comparison|brand_graph|referability'

SELF="${BASH_SOURCE[0]}"
ERRLOG=""
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() { [ -z "$ERRLOG" ] || rm -f "$ERRLOG"; }
trap cleanup EXIT

# --- outcome emitters -------------------------------------------------------
#
# One function per outcome so no code path can invent a fifth one, and so a
# clean verdict is only reachable from the single place that has already
# counted what was inspected.

usage_error() {
  printf 'fm-verify-delivered.sh: %s\n' "$1" >&2
  printf 'usage: fm-verify-delivered.sh brand-identity [--no-fetch] | fm-verify-delivered.sh <task-id>\n' >&2
  exit 2
}

inspected_nothing() {
  printf 'INSPECTED NOTHING: %s\n' "$1"
  printf '  >>> NOT a clean result. The check examined no files, so it proved nothing.\n'
  printf '  >>> Fix the search before reporting anything about this claim.\n'
  exit 3
}

search_failed() {
  printf 'SEARCH FAILED: %s\n' "$1"
  printf '  >>> NOT a clean result. The answer is unknown, not negative.\n'
  exit 4
}

# Any failure this script did not classify itself lands here rather than
# escaping as some other status. An unhandled failure is an unknown answer.
# `-E` above is what carries this trap into the mode functions, where all the
# work happens; without it bash would drop the trap at the function boundary and
# an unclassified failure would escape as exit 1, which here means "violations".
# BASH_COMMAND names the command that actually failed: LINENO inside a trap
# resolves to the enclosing function's definition line, not the failing one.
#
# Only the top-level shell turns a failure into outcome 4. `-E` carries the trap
# into command substitutions as well, and the searches below read a subshell's
# exit status to tell a legitimate git grep no-match from a real error; firing
# there would rewrite every no-match as a failure. Standing aside loses nothing:
# a subshell that dies under `-e` still hands its status to the command that
# captured it, which is either classified there or caught here.
trap '[ "${BASH_SUBSHELL:-0}" -ne 0 ] || search_failed "unhandled command failure in ${FUNCNAME[0]:-main} (called at line ${BASH_LINENO[0]}): $BASH_COMMAND"' ERR

# --- helpers ---------------------------------------------------------------

# Count the lines in a captured command substitution, where empty means zero
# rather than one blank line.
count_lines() {
  [ -n "$1" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$1" | wc -l | tr -d '[:space:]'
}

# Resolve the repo brand-identity inspects: an explicit override first, then the
# path data/projects.md records for inception, then the standard clone location.
# No personal absolute path is baked into this shared script.
resolve_brand_repo() {
  local registry="$DATA/projects.md" from_registry=""
  if [ -n "${FM_VERIFY_REPO:-}" ]; then
    printf '%s\n' "$FM_VERIFY_REPO"
    return 0
  fi
  if [ -f "$registry" ]; then
    from_registry=$(sed -n 's/^- inception .*repo at \([^ ,)]*\).*$/\1/p' "$registry" | sed -n 1p)
  fi
  if [ -n "$from_registry" ]; then
    printf '%s\n' "$from_registry"
    return 0
  fi
  printf '%s\n' "$FM_HOME/projects/inception"
}

# --- brand-identity mode ---------------------------------------------------

verify_brand_identity() {
  local fetch=1 repo candidate_out st scope_out scope_n cand_n matched_n
  local unmigrated=0 migrated=0 line f
  local -a candidates=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-fetch) fetch=0 ;;
      *) usage_error "unknown brand-identity option '$1'" ;;
    esac
    shift
  done

  repo=$(resolve_brand_repo)
  ERRLOG=$(mktemp "${TMPDIR:-/tmp}/fm-verify-delivered.XXXXXX")

  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>"$ERRLOG"; then
    search_failed "$repo is not a git repository ($(tr '\n' ' ' <"$ERRLOG")); set FM_VERIFY_REPO"
  fi
  # A fetch that was asked for and failed leaves $REV at whatever is already on
  # disk, so any verdict below would be about an unknown rev. That is outcome 4,
  # not a warning; --no-fetch is how a caller accepts a local ref on purpose.
  if [ "$fetch" -eq 1 ]; then
    if ! git -C "$repo" fetch origin -q 2>"$ERRLOG"; then
      search_failed "git fetch origin failed in $repo ($(tr '\n' ' ' <"$ERRLOG")); '$REV' may be stale, so nothing was searched; pass --no-fetch to inspect the local ref on purpose"
    fi
  fi
  if ! git -C "$repo" rev-parse --verify --quiet "$REV^{commit}" >/dev/null 2>"$ERRLOG"; then
    search_failed "cannot resolve rev '$REV' in $repo; nothing was searched"
  fi

  printf '=== files deciding brand identity by STRING, no graph consultation ===\n'
  printf '  repo: %s\n  rev:  %s\n  path: %s\n' "$repo" "$REV" "$BRAND_PATHSPEC"

  # Bug 1's shape: a pathspec that matches no files. git grep reports that as an
  # ordinary no-match, so the scope has to be counted separately from the search.
  st=0
  scope_out=$(git -C "$repo" ls-tree -r --name-only "$REV" -- "$BRAND_PATHSPEC" 2>"$ERRLOG") || st=$?
  if [ "$st" -ne 0 ]; then
    search_failed "git ls-tree failed with status $st: $(tr '\n' ' ' <"$ERRLOG")"
  fi
  scope_n=$(count_lines "$scope_out")
  if [ "$scope_n" -eq 0 ]; then
    inspected_nothing "pathspec '$BRAND_PATHSPEC' matches no file at $REV in $repo"
  fi

  # git grep: 0 means matches, 1 means a legitimate no-match, anything higher is
  # a real failure. Only the first two are results.
  st=0
  candidate_out=$(git -C "$repo" grep -lE "$BRAND_CANDIDATE_RE" "$REV" -- "$BRAND_PATHSPEC" 2>"$ERRLOG") || st=$?
  case "$st" in
    0 | 1) : ;;
    *) search_failed "git grep for candidates failed with status $st: $(tr '\n' ' ' <"$ERRLOG")" ;;
  esac

  # Counted before the owner exclusion below, so an empty candidate list can say
  # which of the two ways it got there: the pattern matched nothing at all, or
  # everything it matched is a file allowed to compare strings.
  matched_n=$(count_lines "$candidate_out")

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    f=${line#"$REV:"}
    # The two owners of string matching are allowed to compare strings.
    case "$f" in
      */name_matching.py | */competitor_guards.py) continue ;;
    esac
    candidates+=("$f")
  done <<<"$candidate_out"

  cand_n=${#candidates[@]}
  if [ "$cand_n" -eq 0 ] && [ "$matched_n" -eq 0 ]; then
    inspected_nothing "no file among the $scope_n under '$BRAND_PATHSPEC' matches /$BRAND_CANDIDATE_RE/; the candidate pattern matched nothing in scope, so it found nothing to check"
  fi
  if [ "$cand_n" -eq 0 ]; then
    inspected_nothing "all $matched_n file(s) under '$BRAND_PATHSPEC' matching /$BRAND_CANDIDATE_RE/ are name_matching.py or competitor_guards.py; every file it matched is an allowed string-matching owner, so it found nothing to check"
  fi

  for f in "${candidates[@]}"; do
    st=0
    git -C "$repo" grep -qE "$BRAND_GRAPH_RE" "$REV" -- "$f" 2>"$ERRLOG" || st=$?
    case "$st" in
      0) migrated=$((migrated + 1)) ;;
      1)
        printf '  UNMIGRATED: %s\n' "${f#schema-generator/}"
        unmigrated=$((unmigrated + 1))
        ;;
      *) search_failed "git grep for graph consultation failed on $f with status $st: $(tr '\n' ' ' <"$ERRLOG")" ;;
    esac
  done

  printf '  INSPECTED: %s candidate file(s) out of %s under %s\n' "$cand_n" "$scope_n" "$BRAND_PATHSPEC"
  if [ "$unmigrated" -gt 0 ]; then
    printf 'VIOLATIONS: %s of %s inspected file(s) decide brand identity by string with no graph consultation.\n' \
      "$unmigrated" "$cand_n"
    printf '  >>> DO NOT report brand-identity work as complete.\n'
    exit 1
  fi
  # Wording limited to what the per-file grep above actually proves: a graph
  # identifier appears in the file. It can appear in a comment or a docstring,
  # and a file can still decide by string in some other branch, so this is not a
  # claim that the file consults the graph.
  printf 'CLEAN: all %s inspected file(s) reference a graph identifier somewhere in the file, comments and docstrings included, which is not proof they consult it; %s referencing, 0 with no graph reference.\n' \
    "$cand_n" "$migrated"
  exit 0
}

# --- task-id mode ----------------------------------------------------------

verify_task_claims() {
  local id=$1 brief claims st=0
  brief="$DATA/$id/brief.md"
  [ -f "$brief" ] || usage_error "no brief for '$id' at $brief"

  claims=$(grep -nE "^[0-9]+\.|^\*\*[0-9]|must |MUST |every |EVERY |all " "$brief") || st=$?
  case "$st" in
    0 | 1) : ;;
    *) search_failed "grep over $brief failed with status $st" ;;
  esac
  if [ -z "$claims" ]; then
    inspected_nothing "no acceptance-shaped line in $brief; the claim pattern extracted nothing to verify"
  fi

  printf '=== ACCEPTANCE CLAIMS in the brief for %s - verify EACH against merged main ===\n' "$id"
  # sed, not head: head can close the pipe early, and under pipefail that turns
  # a long claim list into a spurious failure.
  printf '%s\n' "$claims" | sed -n '1,40p'
  printf '\n'
  printf '>>> For each line above: does merged main actually satisfy it? Check, do not assume.\n'
  printf ">>> A worker's 'done' is a claim. The code is the evidence.\n"
  printf 'CHECKLIST: %s claim line(s) extracted. This is a checklist, NOT a clean verdict.\n' "$(count_lines "$claims")"
  exit 0
}

case "${1:-}" in
  brand-identity)
    shift
    verify_brand_identity "$@"
    ;;
  -h | --help)
    # Print this file's leading comment block, so the header stays the one owner
    # of the usage text and no line range has to be kept in sync.
    awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SELF"
    exit 0
    ;;
  "")
    usage_error "no mode given"
    ;;
  -*)
    usage_error "unknown option '$1'"
    ;;
  *)
    verify_task_claims "$1"
    ;;
esac
