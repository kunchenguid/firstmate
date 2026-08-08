#!/usr/bin/env bash
# Integrate, reclassify, or discard one canonical fork divergence topic in an
# isolated fork candidate.
#
# Usage:
#   fm-fork-topic.sh integrate --id <id> --summary <sentence>
#     --class <pending|rejected-but-retained|private> --topic <ref>
#     --retire-when <falsifiable-condition> --path <path-or-prefix>...
#     [--pr-url <github-pr-url> --pr-disposition <open|rejected|closed|merged>]
#     [--repo <isolated-worktree>]
#   fm-fork-topic.sh disposition --id <id>
#     --class rejected-but-retained --pr-disposition rejected
#     [--repo <isolated-worktree>]
#   fm-fork-topic.sh discard --id <id> [--repo <isolated-worktree>]
#   fm-fork-topic.sh continue --decisions <json> [--repo <isolated-worktree>]
#
# integrate requires a clean named candidate branch at fetched origin/main and a
# canonical topic whose `git cherry upstream/main <topic>` result contains
# exactly one non-equivalent commit. This one-aggregate-patch invariant is what
# makes upstream squash/rebase equivalence measurable. It merges the topic with
# --no-ff --no-commit, writes the manifest entry into that same merge commit,
# commits, and validates the candidate against HEAD.
#
# disposition is the supported governance-only pending-to-rejected transition.
# It updates the class and recorded pull-request disposition atomically in one
# candidate commit, then validates that actual HEAD. The commit is reported by
# health as a manifest-governance artifact, never as a carried divergence.
#
# discard derives every first-parent merge that integrated the named topic and
# applies their mainline-parent-one inverses as one `git revert --no-commit`
# sequence. It removes the manifest unit and commits the complete discard once,
# so intermediate manifest states never enter history.
#
# A product conflict in integrate or discard exits 3, leaves Git's merge or
# revert state intact, and writes a worktree-private receipt binding the branch,
# original HEAD, merge or revert head, manifest, and unaffected index. continue
# requires a complete firstmate.fork-rejustify.v1 decision, resolved/staged
# conflicts, and that exact receipt. It finishes every queued revert before the
# one manifest update, then validates health against the completed candidate.
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
DECISIONS=
PATHS=()

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-fork-topic: %s\n' "$*" >&2
  exit 1
}

write_json_atomic() { # <dest>, stdin
  local dest=$1 tmp
  tmp=$(mktemp "$dest.XXXXXX") || return 1
  if cat > "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
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
    --decisions) [ "$#" -ge 2 ] || die "--decisions requires a path"; DECISIONS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

REPO=$(cd "$REPO" 2>/dev/null && pwd -P) || die "repository path is unavailable"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree"
MANIFEST=${FM_FORK_MANIFEST_OVERRIDE:-$REPO/fork-divergences.json}
MANIFEST_REL=${MANIFEST#"$REPO"/}
RECEIPT=$(git -C "$REPO" rev-parse --path-format=absolute --git-path fm-fork-topic-rejustify.json)
MANIFEST_BACKUP=$(git -C "$REPO" rev-parse --path-format=absolute --git-path fm-fork-topic-manifest.json)

require_topology() {
  local branch primary
  "$SCRIPT_DIR/fm-fork-remotes.sh" check "$REPO" >/dev/null || die "fork topology is invalid"
  [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || die "manifest is missing or unsafe"
  case "$MANIFEST" in "$REPO"/*) ;; *) die "manifest must be inside the candidate repository" ;; esac
  git -C "$REPO" ls-files --error-unmatch -- "$MANIFEST_REL" >/dev/null 2>&1 \
    || die "manifest is not tracked"
  ORIGIN_BRANCH=$(fm_fork_remote_branch "$REPO" origin) || die "cannot determine origin default branch"
  UPSTREAM_BRANCH=$(fm_fork_remote_branch "$REPO" upstream) || die "cannot determine upstream default branch"
  ORIGIN_REF="origin/$ORIGIN_BRANCH"
  UPSTREAM_REF="upstream/$UPSTREAM_BRANCH"
  branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] && [ "$branch" != "$ORIGIN_BRANCH" ] || die "expected a named non-default candidate branch"
  primary=$(git -C "$REPO" worktree list --porcelain | awk 'NR == 1 && $1 == "worktree" { print substr($0,10) }')
  [ "$(git -C "$REPO" rev-parse --show-toplevel)" != "$primary" ] || die "candidate is the primary checkout, not an isolated worktree"
}

require_fresh_candidate() {
  require_topology
  [ ! -e "$RECEIPT" ] || die "an earlier topic conflict receipt exists; continue it first"
  [ ! -e "$MANIFEST_BACKUP" ] || die "an earlier discard manifest backup exists; continue or inspect it first"
  [ -z "$(git -C "$REPO" status --porcelain)" ] || die "candidate working tree is dirty"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune origin || die "origin fetch failed"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune upstream || die "upstream fetch failed"
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse "$ORIGIN_REF")" ] \
    || die "candidate HEAD is not fetched $ORIGIN_REF"
  BASELINE_UPSTREAM=$(git -C "$REPO" merge-base "$ORIGIN_REF" "$UPSTREAM_REF") \
    || die "fork and upstream do not share a merge base"
}

validate_id() {
  case "$ID" in ''|*[!a-z0-9-]*|-*) die "invalid divergence id" ;; esac
}

validate_decision() { # <id> <required-action>
  local expected_id=$1 required_action=$2 decision_ids action
  [ -n "$DECISIONS" ] || die "continue requires --decisions <json>"
  [ -f "$DECISIONS" ] && [ ! -L "$DECISIONS" ] || die "decision file is missing or unsafe"
  jq -e '.schema == "firstmate.fork-rejustify.v1" and (.decisions | type == "array") and ([.decisions[].id] | length == (unique | length)) and all(.decisions[]; (.id|type=="string" and (. == "__unowned__" or test("^[a-z0-9][a-z0-9-]*$"))) and (.action=="retain" or .action=="remove") and (.reason|type=="string" and length>=12 and (test("[[:cntrl:]]")|not)))' \
    "$DECISIONS" >/dev/null || die "decision file does not satisfy firstmate.fork-rejustify.v1"
  decision_ids=$(jq -r '.decisions[].id' "$DECISIONS")
  [ "$decision_ids" = "$expected_id" ] || die "decision file must name exactly divergence $expected_id"
  action=$(jq -r --arg id "$expected_id" '.decisions[] | select(.id == $id) | .action' "$DECISIONS")
  [ "$action" = "$required_action" ] || die "decision for $expected_id must resolve this operation as $required_action"
}

validate_integrate_inputs() {
  validate_id
  [ -n "$SUMMARY" ] || die "summary is required"
  jq -en --arg value "$SUMMARY" '$value | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)' >/dev/null \
    || die "summary contains unsupported control characters"
  case "$CLASS" in pending|rejected-but-retained|private) ;; *) die "invalid active divergence class" ;; esac
  [ "$TOPIC" = "fm/divergence/$ID" ] || die "canonical topic must be fm/divergence/$ID"
  [ -n "$RETIRE_WHEN" ] && [ "${#RETIRE_WHEN}" -ge 12 ] || die "retirement condition must be concrete and falsifiable"
  jq -en --arg value "$RETIRE_WHEN" '$value | (test("[[:cntrl:]]") | not) and (test("(?i)(review periodically|revisit later|monitor this|^tbd$|^todo$)") | not)' >/dev/null \
    || die "retirement condition is vague or contains unsupported control characters"
  [ "${#PATHS[@]}" -gt 0 ] || die "at least one owned path is required"
  PATHS_JSON=$(printf '%s\n' "${PATHS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0)) | unique')
  jq -en --argjson paths "$PATHS_JSON" '$paths | length > 0 and all(.[]; (test("[[:cntrl:]]") | not) and (startswith("/") | not) and (contains("..") | not))' >/dev/null \
    || die "owned paths must be safe non-empty repository-relative paths or prefixes"
  if [ "$CLASS" != private ]; then
    jq -en --arg url "$PR_URL" '$url | test("^https://github\\.com/[^/]+/[^/]+/pull/[0-9]+$")' >/dev/null \
      || die "non-private divergence requires a full GitHub upstream PR URL"
    case "$PR_DISPOSITION" in open|rejected|closed|merged) ;; *) die "non-private divergence requires a valid PR disposition" ;; esac
  elif [ -n "$PR_URL$PR_DISPOSITION" ]; then
    die "private divergence must not carry an upstream pull-request record"
  fi
}

manifest_add_integrated_unit() {
  local tmp pr_json
  if [ "$CLASS" = private ]; then
    pr_json=null
  else
    pr_json=$(jq -n --arg url "$PR_URL" --arg disposition "$PR_DISPOSITION" '{url:$url,disposition:$disposition}')
  fi
  tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
  jq --arg id "$ID" --arg summary "$SUMMARY" --arg class "$CLASS" --arg topic "$TOPIC" \
    --arg introduced "${FM_FORK_DATE_OVERRIDE:-$(date +%F)}" --arg retire "$RETIRE_WHEN" \
    --argjson paths "$PATHS_JSON" --argjson pr "$pr_json" '
      .divergences += [{id:$id,summary:$summary,class:$class,topic:$topic,introduced:$introduced,upstream_pr:$pr,retire_when:$retire,paths:$paths}]
    ' "$MANIFEST" > "$tmp" || { rm -f "$tmp"; die "could not update manifest"; }
  mv -f "$tmp" "$MANIFEST"
}

validate_integrated_candidate() {
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref HEAD --upstream-ref "$BASELINE_UPSTREAM" --facts-only
  printf 'prepared: divergence %s integrated as branch-level merge; validate the actual post-pipeline head through the isolated fork target\n' "$ID"
}

write_integrate_receipt() { # <base-head> <topic-head> <conflicts-file>
  local base_head=$1 topic_head=$2 conflicts_file=$3 conflict_json clean_index_hash manifest_hash
  conflict_json=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$conflicts_file")
  clean_index_hash=$(fm_fork_index_without_paths_hash "$REPO" "$conflicts_file")
  manifest_hash=$(git hash-object "$MANIFEST")
  jq -n --arg schema firstmate.fork-topic-rejustify-receipt.v1 --arg operation integrate \
    --arg branch "$(git -C "$REPO" symbolic-ref --short HEAD)" --arg base "$base_head" \
    --arg merge_head "$topic_head" --arg baseline "$BASELINE_UPSTREAM" --arg id "$ID" \
    --arg summary "$SUMMARY" --arg class "$CLASS" --arg topic "$TOPIC" --arg retire "$RETIRE_WHEN" \
    --arg pr_url "$PR_URL" --arg pr_disposition "$PR_DISPOSITION" --arg manifest_hash "$manifest_hash" \
    --arg clean_index_hash "$clean_index_hash" --argjson paths "$PATHS_JSON" --argjson conflicts "$conflict_json" \
    '{schema:$schema,operation:$operation,branch:$branch,base_head:$base,merge_head:$merge_head,baseline_upstream:$baseline,id:$id,summary:$summary,class:$class,topic:$topic,retire_when:$retire,pr_url:$pr_url,pr_disposition:$pr_disposition,paths:$paths,manifest_hash:$manifest_hash,conflicts:$conflicts,clean_index_hash:$clean_index_hash}' \
    | write_json_atomic "$RECEIPT" || die "could not publish topic conflict receipt"
}

cmd_integrate() {
  local patch_sha merge_rc base_head conflicts changed_path covered spec
  require_fresh_candidate
  validate_integrate_inputs
  [ "$(jq --arg id "$ID" '[.divergences[] | select(.id == $id)] | length' "$MANIFEST")" -eq 0 ] \
    || die "manifest already contains divergence $ID"
  [ "$(jq --arg id "$ID" '[(.retired_upstream // [])[] | select(.id == $id)] | length' "$MANIFEST")" -eq 0 ] \
    || die "manifest records $ID as accepted upstream and retired; choose a new id"
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
    [ "$changed_path" != "$MANIFEST_REL" ] || die "a divergence topic must not edit its governance manifest"
    [ "$covered" -eq 1 ] || die "declared paths do not cover topic path $changed_path"
  done < <(git -C "$REPO" diff-tree --no-commit-id --name-only -r "$patch_sha")

  base_head=$(git -C "$REPO" rev-parse HEAD)
  merge_rc=0
  git -C "$REPO" merge --no-ff --no-commit -m "Merge divergence $ID" "$TOPIC_REF" || merge_rc=$?
  if [ "$merge_rc" -ne 0 ]; then
    conflicts=$(mktemp "${TMPDIR:-/tmp}/fm-fork-topic-conflicts.XXXXXX") || die "cannot create conflict list"
    git -C "$REPO" diff --name-only --diff-filter=U > "$conflicts"
    if [ ! -s "$conflicts" ]; then rm -f "$conflicts"; die "topic merge failed without conflict paths"; fi
    write_integrate_receipt "$base_head" "$(git -C "$REPO" rev-parse MERGE_HEAD)" "$conflicts"
    rm -f "$conflicts"
    printf 'rejustify-required: divergence %s conflicts with fork main; resolve the retain decision before staging the product result\n' "$ID" >&2
    printf 'receipt: %s\n' "$RECEIPT" >&2
    exit 3
  fi

  manifest_add_integrated_unit
  git -C "$REPO" add -- "$MANIFEST"
  GIT_EDITOR=true git -C "$REPO" merge --continue
  validate_integrated_candidate
}

cmd_disposition() {
  local current_class current_disposition tmp
  require_fresh_candidate
  validate_id
  [ "$CLASS" = rejected-but-retained ] || die "disposition transition requires --class rejected-but-retained"
  [ "$PR_DISPOSITION" = rejected ] || die "disposition transition requires --pr-disposition rejected"
  [ -z "$SUMMARY$TOPIC$RETIRE_WHEN$PR_URL" ] && [ "${#PATHS[@]}" -eq 0 ] \
    || die "disposition transition accepts only id, class, and pull-request disposition"
  current_class=$(jq -r --arg id "$ID" '.divergences[] | select(.id == $id) | .class' "$MANIFEST")
  [ "$current_class" = pending ] || die "divergence $ID is not pending"
  current_disposition=$(jq -r --arg id "$ID" '.divergences[] | select(.id == $id) | .upstream_pr.disposition // empty' "$MANIFEST")
  [ -n "$current_disposition" ] || die "pending divergence $ID has no upstream pull-request record"
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref "$ORIGIN_REF" --upstream-ref "$BASELINE_UPSTREAM" --facts-only >/dev/null \
    || die "existing divergence manifest facts are inconsistent"
  tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
  jq --arg id "$ID" '
    .divergences |= map(if .id == $id then .class = "rejected-but-retained" | .upstream_pr.disposition = "rejected" else . end)
  ' "$MANIFEST" > "$tmp" || { rm -f "$tmp"; die "cannot update upstream review disposition"; }
  mv -f "$tmp" "$MANIFEST"
  git -C "$REPO" add -- "$MANIFEST"
  git -C "$REPO" commit -m "Record upstream rejection for divergence $ID"
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref HEAD --upstream-ref "$BASELINE_UPSTREAM" --facts-only
  printf 'prepared: divergence %s transitioned from pending to rejected-but-retained; validate the actual post-pipeline head through the isolated fork target\n' "$ID"
}

find_discard_merges() {
  local topic_ref=$1 merge parent_line second_parent
  while IFS= read -r merge; do
    parent_line=$(git -C "$REPO" rev-list --parents -n1 "$merge")
    # Git emits a space-delimited list of hexadecimal object IDs.
    # shellcheck disable=SC2086
    set -- $parent_line
    [ "$#" -eq 3 ] || continue
    second_parent=$3
    if git -C "$REPO" merge-base --is-ancestor "$second_parent" "$topic_ref" 2>/dev/null \
        && ! git -C "$REPO" merge-base --is-ancestor "$second_parent" "$UPSTREAM_REF" 2>/dev/null; then
      printf '%s\n' "$merge"
    fi
  done < <(git -C "$REPO" rev-list --first-parent --merges HEAD)
}

write_discard_receipt() { # <original-base-head> <baseline> <conflicts-file>
  local discard_base=$1 baseline=$2 conflicts_file=$3 conflict_json clean_index_hash backup_hash revert_head current_head merges_json
  conflict_json=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$conflicts_file")
  clean_index_hash=$(fm_fork_index_without_paths_hash "$REPO" "$conflicts_file")
  backup_hash=$(git hash-object "$MANIFEST_BACKUP")
  revert_head=$(git -C "$REPO" rev-parse REVERT_HEAD)
  current_head=$(git -C "$REPO" rev-parse HEAD)
  merges_json=$(printf '%s\n' "$DISCARD_MERGES" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -n --arg schema firstmate.fork-topic-rejustify-receipt.v1 --arg operation discard \
    --arg branch "$(git -C "$REPO" symbolic-ref --short HEAD)" --arg base "$current_head" --arg discard_base "$discard_base" \
    --arg revert_head "$revert_head" --arg baseline "$baseline" --arg id "$ID" \
    --arg manifest_backup "$MANIFEST_BACKUP" --arg manifest_backup_hash "$backup_hash" \
    --arg clean_index_hash "$clean_index_hash" --argjson conflicts "$conflict_json" --argjson merges "$merges_json" \
    '{schema:$schema,operation:$operation,branch:$branch,base_head:$base,discard_base:$discard_base,revert_head:$revert_head,baseline_upstream:$baseline,id:$id,manifest_backup:$manifest_backup,manifest_backup_hash:$manifest_backup_hash,merges:$merges,conflicts:$conflicts,clean_index_hash:$clean_index_hash}' \
    | write_json_atomic "$RECEIPT" || die "could not publish discard conflict receipt"
}

continue_manifest_only_reverts() { # <base-head> <baseline>; returns 3 on product conflict
  local base_head=$1 baseline=$2 conflicts product_conflicts rc
  while git -C "$REPO" rev-parse --verify --quiet REVERT_HEAD >/dev/null; do
    conflicts=$(mktemp "${TMPDIR:-/tmp}/fm-fork-discard-conflicts.XXXXXX") || die "cannot create conflict list"
    git -C "$REPO" diff --name-only --diff-filter=U > "$conflicts"
    product_conflicts=$(grep -Fvx "$MANIFEST_REL" "$conflicts" || true)
    if [ -n "$product_conflicts" ]; then
      write_discard_receipt "$base_head" "$baseline" "$conflicts"
      rm -f "$conflicts"
      printf 'rejustify-required: discard of %s has product conflicts; resolve the remove decision before staging the product result\n' "$ID" >&2
      printf 'receipt: %s\n' "$RECEIPT" >&2
      return 3
    fi
    cp "$MANIFEST_BACKUP" "$MANIFEST" || die "cannot restore the pre-discard manifest"
    git -C "$REPO" add -- "$MANIFEST"
    rm -f "$conflicts"
    rc=0
    GIT_EDITOR=true git -C "$REPO" revert --continue >/dev/null || rc=$?
    # Restoring the manifest can leave the resolved inverse with no net change.
    # Git then refuses to commit it, keeps REVERT_HEAD, and reports no new
    # conflict, so the sequencer only advances through its documented --skip.
    if [ "$rc" -ne 0 ] && git -C "$REPO" rev-parse --verify --quiet REVERT_HEAD >/dev/null \
        && [ -z "$(git -C "$REPO" diff --name-only --diff-filter=U)" ]; then
      git -C "$REPO" diff-index --quiet --cached HEAD -- \
        || die "discard revert continuation failed with a staged result"
      rc=0
      GIT_EDITOR=true git -C "$REPO" revert --skip >/dev/null || rc=$?
    fi
    if [ "$rc" -ne 0 ] && ! git -C "$REPO" rev-parse --verify --quiet REVERT_HEAD >/dev/null; then
      die "discard revert continuation failed without a conflict"
    fi
  done
  return 0
}

finish_discard() {
  local tmp merge_count only_merge
  if [ "$(git -C "$REPO" rev-parse HEAD)" != "$DISCARD_BASE_HEAD" ]; then
    # Git's documented `revert --continue` may commit the resolved item even
    # when the sequence began with --no-commit. The candidate is unpublished,
    # so collect those sequencer commits back into the index before publishing
    # one atomic discard commit.
    git -C "$REPO" reset --soft "$DISCARD_BASE_HEAD"
  fi
  cp "$MANIFEST_BACKUP" "$MANIFEST" || die "cannot restore the pre-discard manifest"
  tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
  jq --arg id "$ID" '.divergences |= map(select(.id != $id))' "$MANIFEST" > "$tmp" \
    || { rm -f "$tmp"; die "cannot remove manifest entry"; }
  mv -f "$tmp" "$MANIFEST"
  git -C "$REPO" add -- "$MANIFEST"
  merge_count=$(printf '%s\n' "$DISCARD_MERGES" | awk 'NF { n++ } END { print n+0 }')
  if [ "$merge_count" -eq 1 ]; then
    only_merge=$(printf '%s\n' "$DISCARD_MERGES" | awk 'NF { print; exit }')
    git -C "$REPO" commit -m "Discard divergence $ID" -m "This reverts commit $only_merge, reversing"
  else
    git -C "$REPO" commit -m "Discard divergence $ID"
  fi
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref HEAD --upstream-ref "$BASELINE_UPSTREAM" --facts-only
  rm -f "$RECEIPT" "$MANIFEST_BACKUP"
  printf 'prepared: divergence %s discarded independently; validate the actual post-pipeline head through the isolated fork target\n' "$ID"
}

cmd_discard() {
  local topic topic_ref merges base_head rc
  require_fresh_candidate
  validate_id
  topic=$(jq -r --arg id "$ID" '.divergences[] | select(.id == $id) | .topic' "$MANIFEST")
  [ -n "$topic" ] || die "manifest has no divergence $ID"
  topic_ref=$(fm_fork_topic_ref "$REPO" "$topic") || die "canonical topic is missing: $topic"
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref "$ORIGIN_REF" --upstream-ref "$BASELINE_UPSTREAM" --facts-only >/dev/null \
    || die "existing divergence manifest facts are inconsistent"
  merges=$(find_discard_merges "$topic_ref")
  [ -n "$merges" ] || die "no integration merge found for divergence $ID"
  DISCARD_MERGES=$merges
  cp -p "$MANIFEST" "$MANIFEST_BACKUP" || die "cannot snapshot the pre-discard manifest"
  base_head=$(git -C "$REPO" rev-parse HEAD)
  DISCARD_BASE_HEAD=$base_head
  rc=0
  # shellcheck disable=SC2086 # one validated commit ID per line is the revert queue
  git -C "$REPO" revert --no-commit -m 1 $merges >/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    if continue_manifest_only_reverts "$base_head" "$BASELINE_UPSTREAM"; then :; else
      rc=$?
      [ "$rc" -eq 3 ] && exit 3
      exit "$rc"
    fi
  fi
  finish_discard
}

load_receipt() {
  require_topology
  [ -f "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || die "no topic conflict receipt exists"
  jq -e '.schema == "firstmate.fork-topic-rejustify-receipt.v1" and (.operation == "integrate" or .operation == "discard") and (.branch|type=="string" and length>0) and (.base_head|test("^[0-9a-f]{40,64}$")) and (if .operation == "discard" then (.discard_base|test("^[0-9a-f]{40,64}$")) and (.merges|type=="array" and length>0 and all(.[]; test("^[0-9a-f]{40,64}$"))) else true end) and (.baseline_upstream|test("^[0-9a-f]{40,64}$")) and (.id|test("^[a-z0-9][a-z0-9-]*$")) and (.conflicts|type=="array" and length>0) and (.clean_index_hash|test("^[0-9a-f]{40,64}$"))' \
    "$RECEIPT" >/dev/null || die "topic conflict receipt is malformed"
  receipt_branch=$(jq -r .branch "$RECEIPT")
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "$receipt_branch" ] || die "candidate branch differs from the receipt"
  base_head=$(jq -r .base_head "$RECEIPT")
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$base_head" ] || die "candidate HEAD differs from the receipt"
  ID=$(jq -r .id "$RECEIPT")
  BASELINE_UPSTREAM=$(jq -r .baseline_upstream "$RECEIPT")
  if [ "$(jq -r .operation "$RECEIPT")" = discard ]; then
    DISCARD_BASE_HEAD=$(jq -r .discard_base "$RECEIPT")
    DISCARD_MERGES=$(jq -r '.merges[]' "$RECEIPT")
  fi
}

require_resolved_index() {
  local conflicts_file=$1
  [ -z "$(git -C "$REPO" diff --name-only --diff-filter=U)" ] || die "conflicts remain unresolved or unstaged"
  git -C "$REPO" diff --quiet || die "unstaged changes remain after conflict resolution"
  [ -z "$(git -C "$REPO" ls-files --others --exclude-standard)" ] || die "untracked files are present in the candidate"
  [ "$(fm_fork_index_without_paths_hash "$REPO" "$conflicts_file")" = "$(jq -r .clean_index_hash "$RECEIPT")" ] \
    || die "non-conflict index entries changed after the operation stopped"
}

continue_integrate() {
  local conflicts_file
  validate_decision "$ID" retain
  [ "$(git -C "$REPO" rev-parse MERGE_HEAD 2>/dev/null || true)" = "$(jq -r .merge_head "$RECEIPT")" ] \
    || die "active merge differs from the receipt"
  [ "$(git hash-object "$MANIFEST")" = "$(jq -r .manifest_hash "$RECEIPT")" ] \
    || die "manifest differs from the pre-merge receipt"
  conflicts_file=$(mktemp "${TMPDIR:-/tmp}/fm-fork-integrate-continue.XXXXXX") || die "cannot create conflict state"
  jq -r '.conflicts[]' "$RECEIPT" > "$conflicts_file"
  require_resolved_index "$conflicts_file"
  rm -f "$conflicts_file"
  SUMMARY=$(jq -r .summary "$RECEIPT")
  CLASS=$(jq -r .class "$RECEIPT")
  TOPIC=$(jq -r .topic "$RECEIPT")
  RETIRE_WHEN=$(jq -r .retire_when "$RECEIPT")
  PR_URL=$(jq -r .pr_url "$RECEIPT")
  PR_DISPOSITION=$(jq -r .pr_disposition "$RECEIPT")
  PATHS_JSON=$(jq -c .paths "$RECEIPT")
  manifest_add_integrated_unit
  git -C "$REPO" add -- "$MANIFEST"
  git -C "$REPO" rerere >/dev/null 2>&1 || true
  GIT_EDITOR=true git -C "$REPO" merge --continue
  rm -f "$RECEIPT"
  validate_integrated_candidate
}

continue_discard() {
  local conflicts_file backup backup_hash rc
  validate_decision "$ID" remove
  [ "$(git -C "$REPO" rev-parse REVERT_HEAD 2>/dev/null || true)" = "$(jq -r .revert_head "$RECEIPT")" ] \
    || die "active revert differs from the receipt"
  backup=$(jq -r .manifest_backup "$RECEIPT")
  [ "$backup" = "$MANIFEST_BACKUP" ] && [ -f "$backup" ] && [ ! -L "$backup" ] \
    || die "discard manifest backup differs from the receipt"
  backup_hash=$(jq -r .manifest_backup_hash "$RECEIPT")
  [ "$(git hash-object "$backup")" = "$backup_hash" ] || die "discard manifest backup bytes changed"
  conflicts_file=$(mktemp "${TMPDIR:-/tmp}/fm-fork-discard-continue.XXXXXX") || die "cannot create conflict state"
  jq -r '.conflicts[]' "$RECEIPT" > "$conflicts_file"
  require_resolved_index "$conflicts_file"
  rm -f "$conflicts_file"
  cp "$MANIFEST_BACKUP" "$MANIFEST" || die "cannot restore the pre-discard manifest"
  git -C "$REPO" add -- "$MANIFEST"
  git -C "$REPO" rerere >/dev/null 2>&1 || true
  rc=0
  GIT_EDITOR=true git -C "$REPO" revert --continue >/dev/null || rc=$?
  rm -f "$RECEIPT"
  if [ "$rc" -ne 0 ]; then
    if continue_manifest_only_reverts "$DISCARD_BASE_HEAD" "$BASELINE_UPSTREAM"; then :; else
      rc=$?
      [ "$rc" -eq 3 ] && exit 3
      exit "$rc"
    fi
  fi
  finish_discard
}

cmd_continue() {
  local operation
  load_receipt
  operation=$(jq -r .operation "$RECEIPT")
  case "$operation" in
    integrate) continue_integrate ;;
    discard) continue_discard ;;
    *) die "unsupported receipt operation: $operation" ;;
  esac
}

case "$MODE" in
  integrate) cmd_integrate ;;
  disposition) cmd_disposition ;;
  discard) cmd_discard ;;
  continue) cmd_continue ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
