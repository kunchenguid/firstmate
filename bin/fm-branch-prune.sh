#!/usr/bin/env bash
# Guarded forge-level prune of remote branches whose pull request is merged.
#
# This is the sanctioned path for deleting remote refs on a GitHub repo.
# Firstmate must not hand-delete project branches: ancestry checks break under
# squash-merge, and a bulk delete with no audit trail is how work is lost.
# Local gone-upstream pruning remains owned by bin/fm-fleet-sync.sh; this helper
# only classifies and (optionally) deletes remote refs on the forge.
#
# Classification uses the pull request's own merged signal, never git ancestry:
#   merged          -> candidate for delete
#   open            -> keep
#   closed unmerged -> keep and surface by PR number
#   no PR           -> keep and surface for investigation
#
# Protected refs (main/master/uat/prod/production/release/develop/staging and
# any path under them) are never deleted. A candidate is also refused when it is
# the base (or head) of any still-open PR, so pruning cannot orphan another PR.
#
# Default is dry-run (plan only). Pass --apply to perform deletions. Every kept
# and deleted decision is appended to data/branch-prune.log under FM_HOME.
#
# Usage:
#   fm-branch-prune.sh --repo OWNER/REPO [--apply] [--yes]
#   fm-branch-prune.sh --repo OWNER/REPO \
#     --prs-file PATH --branches-file PATH [--apply] [--yes]
#
# --prs-file / --branches-file feed fixture JSON (GitHub REST list shapes) so
# tests exercise classification without the network. Live mode pages the same
# shapes through `gh api --paginate` (machine-readable JSON; gh-axi remains the
# interactive human CLI and is not used here because its list output is not JSON).
# Deletions call `gh api --method DELETE repos/OWNER/REPO/git/refs/heads/BRANCH`.
# jq is required (already a firstmate bootstrap tool).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
LOG="${FM_BRANCH_PRUNE_LOG:-$DATA/branch-prune.log}"

REPO=""
APPLY=0
ASSUME_YES=0
PRS_FILE=""
BRANCHES_FILE=""

usage() {
  cat <<'EOF' >&2
Usage: fm-branch-prune.sh --repo OWNER/REPO [--apply] [--yes]
       fm-branch-prune.sh --repo OWNER/REPO --prs-file PATH --branches-file PATH [--apply] [--yes]

Classify remote branches by PR merge state and optionally delete only safe ones.
Default is dry-run. --apply performs deletions; --yes skips the apply confirm.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { echo "error: --repo needs OWNER/REPO" >&2; exit 2; }
      REPO=$2
      shift 2
      ;;
    --repo=*)
      REPO=${1#--repo=}
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    --prs-file)
      [ "$#" -ge 2 ] || { echo "error: --prs-file needs a path" >&2; exit 2; }
      PRS_FILE=$2
      shift 2
      ;;
    --prs-file=*)
      PRS_FILE=${1#--prs-file=}
      shift
      ;;
    --branches-file)
      [ "$#" -ge 2 ] || { echo "error: --branches-file needs a path" >&2; exit 2; }
      BRANCHES_FILE=$2
      shift 2
      ;;
    --branches-file=*)
      BRANCHES_FILE=${1#--branches-file=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown flag: $1" >&2
      usage
      exit 2
      ;;
    *)
      echo "error: unexpected argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ -z "$REPO" ]; then
  echo "error: --repo OWNER/REPO is required" >&2
  usage
  exit 2
fi

# Exactly one slash, non-empty owner and name, no nested path segments.
OWNER=""
NAME=""
case "$REPO" in
  */*)
    OWNER=${REPO%%/*}
    NAME=${REPO#*/}
    ;;
esac
if [ -z "$OWNER" ] || [ -z "$NAME" ] \
  || [ "$OWNER/$NAME" != "$REPO" ] \
  || [ "${NAME#*/}" != "$NAME" ] \
  || [ "${OWNER#*/}" != "$OWNER" ]; then
  echo "error: --repo must be OWNER/REPO" >&2
  exit 2
fi

if [ -n "$PRS_FILE" ] && [ -z "$BRANCHES_FILE" ]; then
  echo "error: --prs-file requires --branches-file" >&2
  exit 2
fi
if [ -n "$BRANCHES_FILE" ] && [ -z "$PRS_FILE" ]; then
  echo "error: --branches-file requires --prs-file" >&2
  exit 2
fi
if [ -n "$PRS_FILE" ] && [ ! -f "$PRS_FILE" ]; then
  echo "error: --prs-file is not a file: $PRS_FILE" >&2
  exit 2
fi
if [ -n "$BRANCHES_FILE" ] && [ ! -f "$BRANCHES_FILE" ]; then
  echo "error: --branches-file is not a file: $BRANCHES_FILE" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required" >&2
  exit 1
}

# Protected long-lived refs: never candidates, regardless of PR state.
is_protected_ref() {
  local branch=$1 lower
  lower=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    main|master|uat|prod|production|release|develop|staging) return 0 ;;
    main/*|master/*|uat/*|prod/*|production/*|release/*|develop/*|staging/*) return 0 ;;
  esac
  return 1
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

ensure_log() {
  mkdir -p "$(dirname "$LOG")"
  if [ ! -e "$LOG" ]; then
    : > "$LOG"
  fi
  if [ -L "$LOG" ] || [ ! -f "$LOG" ]; then
    echo "error: prune log is not a regular file: $LOG" >&2
    exit 1
  fi
}

append_log() {
  # tab-separated: ts action repo branch detail
  printf '%s\t%s\t%s\t%s\t%s\n' "$(iso_now)" "$1" "$REPO" "$2" "$3" >> "$LOG"
}

fetch_prs_json() {
  if [ -n "$PRS_FILE" ]; then
    cat "$PRS_FILE"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || {
    echo "error: gh is required for live prune (or pass --prs-file/--branches-file)" >&2
    return 1
  }
  # Page every PR. A truncated page silently turns landed branches into "no PR".
  gh api --paginate \
    "repos/$OWNER/$NAME/pulls?state=all&per_page=100"
}

fetch_branches_json() {
  if [ -n "$BRANCHES_FILE" ]; then
    cat "$BRANCHES_FILE"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || {
    echo "error: gh is required for live prune (or pass --prs-file/--branches-file)" >&2
    return 1
  }
  gh api --paginate \
    "repos/$OWNER/$NAME/branches?per_page=100"
}

delete_remote_branch() {
  local branch=$1 encoded
  # Encode the full branch name so slashes become %2F in the ref path.
  encoded=$(printf '%s' "$branch" | jq -sRr @uri)
  gh api --method DELETE "repos/$OWNER/$NAME/git/refs/heads/$encoded" >/dev/null
}

# gh --paginate may emit one JSON array or a stream of arrays; normalize to one.
normalize_json_array() {
  local src=$1 dest=$2
  if ! [ -s "$src" ]; then
    echo "error: empty forge response" >&2
    return 1
  fi
  if jq -e 'type == "array"' "$src" >/dev/null 2>&1; then
    # Nested array-of-arrays (rare) -> flatten; else already a flat array.
    if jq -e 'length > 0 and (.[0] | type == "array")' "$src" >/dev/null 2>&1; then
      jq 'add' "$src" > "$dest"
    else
      cp "$src" "$dest"
    fi
    return 0
  fi
  # NDJSON / multi-document stream of arrays from paginate.
  if jq -s 'add // []' "$src" > "$dest" 2>/dev/null \
    && jq -e 'type == "array"' "$dest" >/dev/null 2>&1; then
    return 0
  fi
  echo "error: could not parse JSON array from forge response" >&2
  return 1
}

WORKDIR=
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-branch-prune.XXXXXX")
# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

PRS_JSON="$WORKDIR/prs.json"
BRANCHES_JSON="$WORKDIR/branches.json"
PR_HEAD_MAP="$WORKDIR/pr_head.tsv"
OPEN_BASES="$WORKDIR/open_bases.txt"
OPEN_HEADS="$WORKDIR/open_heads.txt"
CANDIDATES="$WORKDIR/candidates.txt"
DELETE_LIST="$WORKDIR/delete.txt"
SUMMARY="$WORKDIR/summary.txt"

if ! fetch_prs_json > "$WORKDIR/prs.raw.json"; then
  echo "error: failed to load pull requests for $REPO" >&2
  exit 1
fi
if ! fetch_branches_json > "$WORKDIR/branches.raw.json"; then
  echo "error: failed to load branches for $REPO" >&2
  exit 1
fi

normalize_json_array "$WORKDIR/prs.raw.json" "$PRS_JSON" || exit 1
normalize_json_array "$WORKDIR/branches.raw.json" "$BRANCHES_JSON" || exit 1

# Emit one TSV row per PR: head \t kind \t number \t url \t base
jq -r '
  def url:
    (.html_url // (
      if ((.base.repo.full_name // "") != "") then
        "https://github.com/\(.base.repo.full_name)/pull/\(.number)"
      else
        "#\(.number)"
      end
    ));
  def kind:
    if .state == "open" then "open"
    elif ((.merged_at != null) and (.merged_at != "")) or (.merged == true) then "merged"
    else "closed_unmerged"
    end;
  .[]
  | select((.head.ref // "") != "")
  | [(.head.ref // ""), kind, (.number|tostring), url, (.base.ref // "")]
  | @tsv
' "$PRS_JSON" > "$WORKDIR/pr_rows.tsv"

: > "$PR_HEAD_MAP"
: > "$OPEN_BASES"
: > "$OPEN_HEADS"

# Collapse PR rows per head ref. Precedence: open > merged > closed_unmerged.
# bash 3.2 portable (no associative arrays in the outer script path beyond awk).
awk -F '\t' '
  BEGIN {
    rank["open"] = 3
    rank["merged"] = 2
    rank["closed_unmerged"] = 1
  }
  NF >= 4 {
    head = $1
    kind = $2
    pr = $3
    url = $4
    base = (NF >= 5 ? $5 : "")
    r = rank[kind] + 0
    if (r >= best[head] + 0) {
      best[head] = r
      out_kind[head] = kind
      out_pr[head] = pr
      out_url[head] = url
    }
    if (kind == "open") {
      if (base != "") print base >> bases_file
      print head >> heads_file
    }
  }
  END {
    for (h in out_kind) {
      printf "%s\t%s\t%s\t%s\n", h, out_kind[h], out_pr[h], out_url[h]
    }
  }
' bases_file="$OPEN_BASES" heads_file="$OPEN_HEADS" \
  "$WORKDIR/pr_rows.tsv" > "$PR_HEAD_MAP"

sort -u "$OPEN_BASES" -o "$OPEN_BASES" 2>/dev/null || : > "$OPEN_BASES"
sort -u "$OPEN_HEADS" -o "$OPEN_HEADS" 2>/dev/null || : > "$OPEN_HEADS"

jq -r '.[] | .name // empty' "$BRANCHES_JSON" | sort -u > "$WORKDIR/branches.txt"

ensure_log

: > "$CANDIDATES"
: > "$DELETE_LIST"
: > "$SUMMARY"

deleted=0
kept=0
candidates=0

while IFS= read -r branch || [ -n "${branch:-}" ]; do
  [ -n "${branch:-}" ] || continue

  if is_protected_ref "$branch"; then
    printf 'keep\t%s\tprotected_ref\n' "$branch" >> "$SUMMARY"
    append_log "kept" "$branch" "reason=protected_ref"
    kept=$((kept + 1))
    continue
  fi

  pr_line=$(awk -F '\t' -v b="$branch" '$1 == b { print; exit }' "$PR_HEAD_MAP" || true)
  if [ -z "$pr_line" ]; then
    printf 'keep\t%s\tno_pr\n' "$branch" >> "$SUMMARY"
    append_log "kept" "$branch" "reason=no_pr"
    kept=$((kept + 1))
    continue
  fi

  kind=$(printf '%s\n' "$pr_line" | cut -f2)
  pr=$(printf '%s\n' "$pr_line" | cut -f3)
  url=$(printf '%s\n' "$pr_line" | cut -f4)

  case "$kind" in
    open)
      printf 'keep\t%s\topen_pr:%s\t%s\n' "$branch" "$pr" "$url" >> "$SUMMARY"
      append_log "kept" "$branch" "reason=open_pr pr=#$pr url=$url"
      kept=$((kept + 1))
      ;;
    closed_unmerged)
      printf 'keep\t%s\tclosed_unmerged:%s\t%s\n' "$branch" "$pr" "$url" >> "$SUMMARY"
      append_log "kept" "$branch" "reason=closed_unmerged pr=#$pr url=$url"
      kept=$((kept + 1))
      ;;
    merged)
      if grep -Fxq -- "$branch" "$OPEN_BASES"; then
        printf 'keep\t%s\topen_pr_base\tpr_merged:#%s\n' "$branch" "$pr" >> "$SUMMARY"
        append_log "kept" "$branch" "reason=open_pr_base pr_merged=#$pr url=$url"
        kept=$((kept + 1))
        continue
      fi
      if grep -Fxq -- "$branch" "$OPEN_HEADS"; then
        # Defensive: precedence should have classified this open, but fail closed.
        printf 'keep\t%s\topen_pr_head\tpr_merged:#%s\n' "$branch" "$pr" >> "$SUMMARY"
        append_log "kept" "$branch" "reason=open_pr_head pr_merged=#$pr url=$url"
        kept=$((kept + 1))
        continue
      fi
      printf 'delete\t%s\tmerged_pr:%s\t%s\n' "$branch" "$pr" "$url" >> "$SUMMARY"
      printf '%s\t%s\t%s\n' "$branch" "$pr" "$url" >> "$CANDIDATES"
      candidates=$((candidates + 1))
      ;;
    *)
      printf 'keep\t%s\tunknown_kind:%s\n' "$branch" "$kind" >> "$SUMMARY"
      append_log "kept" "$branch" "reason=unknown_kind kind=$kind"
      kept=$((kept + 1))
      ;;
  esac
done < "$WORKDIR/branches.txt"

branch_count=$(wc -l < "$WORKDIR/branches.txt" | tr -d ' ')

echo "repo: $REPO"
if [ "$APPLY" -eq 1 ]; then
  echo "mode: apply"
else
  echo "mode: dry-run"
fi
echo "branches_scanned: $branch_count"
echo "candidates: $candidates"
echo "kept: $kept"
echo

if [ "$candidates" -gt 0 ]; then
  echo "SAFE TO DELETE (merged PR, not protected, not an open PR base/head):"
  while IFS=$'\t' read -r branch pr url || [ -n "${branch:-}" ]; do
    [ -n "${branch:-}" ] || continue
    printf '  %s  (merged PR #%s  %s)\n' "$branch" "$pr" "$url"
  done < "$CANDIDATES"
  echo
fi

kept_closed=$(awk -F '\t' '$1 == "keep" && $3 ~ /^closed_unmerged:/ { c++ } END { print c+0 }' "$SUMMARY")
kept_nopr=$(awk -F '\t' '$1 == "keep" && $3 == "no_pr" { c++ } END { print c+0 }' "$SUMMARY")
if [ "$kept_closed" -gt 0 ]; then
  echo "KEPT closed-unmerged (may hold abandoned-but-wanted work):"
  awk -F '\t' '$1 == "keep" && $3 ~ /^closed_unmerged:/ {
    split($3, a, ":")
    printf "  %s  PR #%s  %s\n", $2, a[2], $4
  }' "$SUMMARY"
  echo
fi
if [ "$kept_nopr" -gt 0 ]; then
  echo "KEPT with no PR (not provably landed - investigate):"
  awk -F '\t' '$1 == "keep" && $3 == "no_pr" { printf "  %s\n", $2 }' "$SUMMARY"
  echo
fi

if [ "$APPLY" -eq 0 ]; then
  if [ -s "$CANDIDATES" ]; then
    while IFS=$'\t' read -r branch pr url || [ -n "${branch:-}" ]; do
      [ -n "${branch:-}" ] || continue
      append_log "dry-run" "$branch" "would_delete pr=#$pr url=$url"
    done < "$CANDIDATES"
  fi
  echo "dry-run only; re-run with --apply to delete the candidates above."
  echo "log: $LOG"
  exit 0
fi

if [ "$candidates" -eq 0 ]; then
  echo "nothing to delete."
  echo "log: $LOG"
  exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
  if [ ! -t 0 ]; then
    echo "error: --apply without --yes requires an interactive confirm (or pass --yes)" >&2
    exit 2
  fi
  printf 'Delete %s candidate branch(es) on %s? [y/N] ' "$candidates" "$REPO" >&2
  read -r answer || answer=
  case "$answer" in
    y|Y|yes|YES) ;;
    *)
      echo "aborted; no branches deleted."
      append_log "aborted" "-" "reason=confirm_declined candidates=$candidates"
      exit 1
      ;;
  esac
fi

failures=0
while IFS=$'\t' read -r branch pr url || [ -n "${branch:-}" ]; do
  [ -n "${branch:-}" ] || continue
  if delete_remote_branch "$branch"; then
    printf 'deleted: %s (PR #%s)\n' "$branch" "$pr"
    append_log "deleted" "$branch" "pr=#$pr url=$url"
    deleted=$((deleted + 1))
    printf '%s\n' "$branch" >> "$DELETE_LIST"
  else
    printf 'error: failed to delete %s (PR #%s)\n' "$branch" "$pr" >&2
    append_log "delete_failed" "$branch" "pr=#$pr url=$url"
    failures=$((failures + 1))
  fi
done < "$CANDIDATES"

# Post-delete orphan check against open PRs known before the delete pass.
if [ -s "$DELETE_LIST" ]; then
  orphan=0
  while IFS= read -r b || [ -n "${b:-}" ]; do
    [ -n "${b:-}" ] || continue
    if grep -Fxq -- "$b" "$OPEN_BASES" || grep -Fxq -- "$b" "$OPEN_HEADS"; then
      printf 'ORPHAN RISK after delete: %s still referenced by an open PR\n' "$b" >&2
      append_log "orphan_risk" "$b" "reason=open_pr_still_references"
      orphan=$((orphan + 1))
    fi
  done < "$DELETE_LIST"
  if [ "$orphan" -gt 0 ]; then
    echo "error: post-delete orphan check failed for $orphan ref(s)" >&2
    failures=$((failures + orphan))
  fi
fi

echo "deleted: $deleted"
echo "failures: $failures"
echo "log: $LOG"

if [ "$failures" -gt 0 ]; then
  exit 1
fi
exit 0
