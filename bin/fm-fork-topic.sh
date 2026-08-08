#!/usr/bin/env bash
# Integrate or discard one canonical fork divergence topic in an isolated fork
# candidate.
#
# Usage:
#   fm-fork-topic.sh integrate --id <id> --summary <sentence>
#     --class <pending|rejected-but-retained|private> --topic <ref>
#     --retire-when <falsifiable-condition> --path <path-or-prefix>...
#     [--pr-url <github-pr-url> --pr-disposition <open|rejected|closed|merged>]
#     [--repo <isolated-worktree>]
#   fm-fork-topic.sh discard --id <id> [--repo <isolated-worktree>]
#
# integrate requires a clean named candidate branch at fetched origin/main and a
# canonical topic whose `git cherry upstream/main <topic>` result contains
# exactly one non-equivalent commit. This one-aggregate-patch invariant is what
# makes upstream squash/rebase equivalence measurable. It merges the topic with
# --no-ff --no-commit, writes the manifest entry into that same merge commit,
# commits, and validates the candidate against HEAD. A conflict exits 3 and is
# left unstaged for re-justification; it is never resolved mechanically here.
#
# discard derives every first-parent merge that integrated the named topic,
# reverts those merges newest to oldest with `git revert -m 1`, removes any
# remaining manifest entry in the final unpublished revert commit, and validates
# the candidate. Neighboring topics are never selected. Git's documented merge
# revert semantics mean re-enabling a discarded topic requires reverting the
# revert or creating a genuinely new topic version, never blindly merging the
# old branch again.
#
# Neither command pushes, opens a PR, force-updates a ref, or invokes
# no-mistakes. The task worker validates and delivers the candidate through the
# isolated fork-target registration.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-fork-lib.sh
. "$SCRIPT_DIR/fm-fork-lib.sh"
MODE=${1:-}
[ "$#" -eq 0 ] || shift
REPO=$FM_ROOT
ID=
SUMMARY=
CLASS=
TOPIC=
RETIRE_WHEN=
PR_URL=
PR_DISPOSITION=
PATHS=()

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-fork-topic: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a path"; REPO=$2; shift 2 ;;
    --id) [ "$#" -ge 2 ] || die "--id requires a value"; ID=$2; shift 2 ;;
    --summary) [ "$#" -ge 2 ] || die "--summary requires a value"; SUMMARY=$2; shift 2 ;;
    --class) [ "$#" -ge 2 ] || die "--class requires a value"; CLASS=$2; shift 2 ;;
    --topic) [ "$#" -ge 2 ] || die "--topic requires a ref"; TOPIC=$2; shift 2 ;;
    --retire-when) [ "$#" -ge 2 ] || die "--retire-when requires a condition"; RETIRE_WHEN=$2; shift 2 ;;
    --path) [ "$#" -ge 2 ] || die "--path requires a value"; PATHS+=("$2"); shift 2 ;;
    --pr-url) [ "$#" -ge 2 ] || die "--pr-url requires a URL"; PR_URL=$2; shift 2 ;;
    --pr-disposition) [ "$#" -ge 2 ] || die "--pr-disposition requires a value"; PR_DISPOSITION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

REPO=$(cd "$REPO" 2>/dev/null && pwd -P) || die "repository path is unavailable"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree"
MANIFEST=${FM_FORK_MANIFEST_OVERRIDE:-$REPO/fork-divergences.json}

require_candidate() {
  "$SCRIPT_DIR/fm-fork-remotes.sh" check "$REPO" >/dev/null || die "fork topology is invalid"
  [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || die "manifest is missing or unsafe"
  case "$MANIFEST" in "$REPO"/*) ;; *) die "manifest must be inside the candidate repository" ;; esac
  git -C "$REPO" ls-files --error-unmatch -- "${MANIFEST#"$REPO"/}" >/dev/null 2>&1 \
    || die "manifest is not tracked"
  ORIGIN_BRANCH=$(fm_fork_remote_branch "$REPO" origin) || die "cannot determine origin default branch"
  UPSTREAM_BRANCH=$(fm_fork_remote_branch "$REPO" upstream) || die "cannot determine upstream default branch"
  ORIGIN_REF="origin/$ORIGIN_BRANCH"
  UPSTREAM_REF="upstream/$UPSTREAM_BRANCH"
  branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] && [ "$branch" != "$ORIGIN_BRANCH" ] || die "expected a named non-default candidate branch"
  primary=$(git -C "$REPO" worktree list --porcelain | awk 'NR == 1 && $1 == "worktree" { print substr($0,10) }')
  [ "$(git -C "$REPO" rev-parse --show-toplevel)" != "$primary" ] || die "candidate is the primary checkout, not an isolated worktree"
  [ -z "$(git -C "$REPO" status --porcelain)" ] || die "candidate working tree is dirty"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune origin || die "origin fetch failed"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune upstream || die "upstream fetch failed"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse "$ORIGIN_REF")" ] \
    || die "candidate HEAD is not fetched $ORIGIN_REF"
  BASELINE_UPSTREAM=$(git -C "$REPO" merge-base "$ORIGIN_REF" "$UPSTREAM_REF") \
    || die "fork and upstream do not share a merge base"
}

cmd_integrate() {
  require_candidate
  case "$ID" in ''|*[!a-z0-9-]*|-*) die "invalid divergence id" ;; esac
  [ -n "$SUMMARY" ] || die "summary is required"
  jq -en --arg value "$SUMMARY" '$value | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)' >/dev/null \
    || die "summary contains unsupported control characters"
  case "$CLASS" in pending|rejected-but-retained|private) ;; *) die "invalid active divergence class" ;; esac
  [ "$TOPIC" = "fm/divergence/$ID" ] || die "canonical topic must be fm/divergence/$ID"
  [ -n "$RETIRE_WHEN" ] && [ "${#RETIRE_WHEN}" -ge 12 ] || die "retirement condition must be concrete and falsifiable"
  jq -en --arg value "$RETIRE_WHEN" '$value | (test("[[:cntrl:]]") | not) and (test("(?i)(review periodically|revisit later|monitor this|^tbd$|^todo$)") | not)' >/dev/null \
    || die "retirement condition is vague or contains unsupported control characters"
  [ "${#PATHS[@]}" -gt 0 ] || die "at least one owned path is required"
  paths_json=$(printf '%s\n' "${PATHS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
  jq -en --argjson paths "$paths_json" '$paths | length > 0 and all(.[]; (test("[[:cntrl:]]") | not) and (startswith("/") | not) and (contains("..") | not))' >/dev/null \
    || die "owned paths must be safe non-empty repository-relative paths or prefixes"
  if [ "$CLASS" != private ]; then
    jq -en --arg url "$PR_URL" '$url | test("^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$")' >/dev/null \
      || die "non-private divergence requires a full GitHub upstream PR URL"
    case "$PR_DISPOSITION" in open|rejected|closed|merged) ;; *) die "non-private divergence requires a valid PR disposition" ;; esac
  elif [ -n "$PR_URL$PR_DISPOSITION" ]; then
    die "private divergence must not carry an upstream pull-request record"
  fi
  [ "$(jq --arg id "$ID" '[.divergences[] | select(.id == $id)] | length' "$MANIFEST")" -eq 0 ] \
    || die "manifest already contains divergence $ID"
  TOPIC_REF=$(fm_fork_topic_ref "$REPO" "$TOPIC") || die "canonical topic is missing: $TOPIC"
  git -C "$REPO" merge-base --is-ancestor "$UPSTREAM_REF" "$ORIGIN_REF" \
    || die "official upstream must be integrated and validated before adding a divergence topic"
  git -C "$REPO" merge-base --is-ancestor "$UPSTREAM_REF" "$TOPIC_REF" \
    || die "canonical topic is not based on the current official upstream"
  [ "$(git -C "$REPO" rev-list --merges --count "$UPSTREAM_REF..$TOPIC_REF")" -eq 0 ] \
    || die "canonical topic contains merge commits; exactly one aggregate patch commit is required"
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref "$ORIGIN_REF" --upstream-ref "$BASELINE_UPSTREAM" --facts-only >/dev/null \
    || die "existing divergence manifest facts are inconsistent"
  plus_count=$(git -C "$REPO" cherry "$UPSTREAM_REF" "$TOPIC_REF" | awk '$1 == "+" { n++ } END { print n+0 }')
  [ "$plus_count" -eq 1 ] || die "canonical topic has $plus_count non-equivalent commits; exactly one aggregate patch is required"
  patch_sha=$(git -C "$REPO" cherry "$UPSTREAM_REF" "$TOPIC_REF" | awk '$1 == "+" { print $2 }')
  while IFS= read -r changed_path; do
    covered=0
    for spec in "${PATHS[@]}"; do
      if fm_fork_path_covered "$spec" "$changed_path"; then covered=1; break; fi
    done
    [ "$changed_path" != "${MANIFEST#"$REPO"/}" ] || die "a divergence topic must not edit its governance manifest"
    [ "$covered" -eq 1 ] || die "declared paths do not cover topic path $changed_path"
  done < <(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$patch_sha")

  merge_rc=0
  git -C "$REPO" merge --no-ff --no-commit "$TOPIC_REF" || merge_rc=$?
  if [ "$merge_rc" -ne 0 ]; then
    if [ -n "$(git -C "$REPO" diff --name-only --diff-filter=U)" ]; then
      printf 'rejustify-required: divergence %s conflicts with fork main; decide whether it remains worth carrying before resolution\n' "$ID" >&2
      exit 3
    fi
    die "topic merge failed without conflict paths"
  fi

  tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
  if [ "$CLASS" = private ]; then pr_json=null; else
    pr_json=$(jq -n --arg url "$PR_URL" --arg disposition "$PR_DISPOSITION" '{url:$url,disposition:$disposition}')
  fi
  jq --arg id "$ID" --arg summary "$SUMMARY" --arg class "$CLASS" --arg topic "$TOPIC" \
    --arg introduced "${FM_FORK_DATE_OVERRIDE:-$(date +%F)}" --arg retire "$RETIRE_WHEN" \
    --argjson paths "$paths_json" --argjson pr "$pr_json" '
      .divergences += [{id:$id,summary:$summary,class:$class,topic:$topic,introduced:$introduced,upstream_pr:$pr,retire_when:$retire,paths:$paths}]
    ' "$MANIFEST" > "$tmp" || { rm -f "$tmp"; die "could not update manifest"; }
  mv -f "$tmp" "$MANIFEST"
  git -C "$REPO" add -- "$MANIFEST"
  git -C "$REPO" commit -m "Merge divergence $ID"
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref HEAD --upstream-ref "$BASELINE_UPSTREAM" --facts-only
  printf 'prepared: divergence %s integrated as branch-level merge; validate through the isolated fork target\n' "$ID"
}

cmd_discard() {
  require_candidate
  case "$ID" in ''|*[!a-z0-9-]*|-*) die "invalid divergence id" ;; esac
  topic=$(jq -r --arg id "$ID" '.divergences[] | select(.id == $id) | .topic' "$MANIFEST")
  [ -n "$topic" ] || die "manifest has no divergence $ID"
  topic_ref=$(fm_fork_topic_ref "$REPO" "$topic") || die "canonical topic is missing: $topic"
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref "$ORIGIN_REF" --upstream-ref "$BASELINE_UPSTREAM" --facts-only >/dev/null \
    || die "existing divergence manifest facts are inconsistent"
  merges=
  while IFS= read -r merge; do
    parent_line=$(git -C "$REPO" rev-list --parents -n1 "$merge")
    # Git emits a space-delimited list of hexadecimal object IDs.
    # shellcheck disable=SC2086
    set -- $parent_line
    [ "$#" -eq 3 ] || continue
    second_parent=$3
    if git -C "$REPO" merge-base --is-ancestor "$second_parent" "$topic_ref" 2>/dev/null \
        && ! git -C "$REPO" merge-base --is-ancestor "$second_parent" "$UPSTREAM_REF" 2>/dev/null; then
      merges="${merges}${merges:+ }$merge"
    fi
  done < <(git -C "$REPO" rev-list --first-parent --merges HEAD)
  [ -n "$merges" ] || die "no integration merge found for divergence $ID"
  discard_tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-discard.XXXXXX") || die "cannot create discard state"
  cp "$MANIFEST" "$discard_tmp/manifest"
  for merge in $merges; do
    if ! git -C "$REPO" revert -m 1 --no-edit "$merge"; then
      conflict_paths=$(git -C "$REPO" diff --name-only --diff-filter=U)
      # A later topic normally changed only the manifest after this merge. Keep
      # the current manifest bytes through that administrative overlap, then
      # remove this one entry below. Any product-file conflict still requires
      # explicit re-justification.
      if [ "$conflict_paths" = "${MANIFEST#"$REPO"/}" ] || [ "$conflict_paths" = fork-divergences.json ]; then
        cp "$discard_tmp/manifest" "$MANIFEST"
        git -C "$REPO" add "$MANIFEST"
        GIT_EDITOR=true git -C "$REPO" revert --continue >/dev/null \
          || { rm -rf "$discard_tmp"; printf 'rejustify-required: discard of %s could not preserve manifest while reverting %s\n' "$ID" "$merge" >&2; exit 3; }
      else
        rm -rf "$discard_tmp"
        printf 'rejustify-required: discard of %s conflicts while reverting %s\n' "$ID" "$merge" >&2
        exit 3
      fi
    fi
  done
  rm -rf "$discard_tmp"
  if [ "$(jq --arg id "$ID" '[.divergences[] | select(.id == $id)] | length' "$MANIFEST")" -ne 0 ]; then
    tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
    jq --arg id "$ID" '.divergences |= map(select(.id != $id))' "$MANIFEST" > "$tmp" \
      || { rm -f "$tmp"; die "cannot remove manifest entry"; }
    mv -f "$tmp" "$MANIFEST"
    git -C "$REPO" add "$MANIFEST"
    git -C "$REPO" commit --amend --no-edit
  fi
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref HEAD --upstream-ref "$BASELINE_UPSTREAM" --facts-only
  printf 'prepared: divergence %s discarded independently; validate through the isolated fork target\n' "$ID"
}

case "$MODE" in
  integrate) cmd_integrate ;;
  discard) cmd_discard ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
