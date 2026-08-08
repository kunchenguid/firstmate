#!/usr/bin/env bash
# Prepare or continue one validated upstream-to-fork-main merge candidate.
#
# Usage:
#   fm-fork-merge.sh prepare [--repo <isolated-worktree>]
#   fm-fork-merge.sh continue --decisions <json> [--repo <isolated-worktree>]
#   fm-fork-merge.sh range-diff [--repo <isolated-worktree>]
#
# prepare requires a clean named feature branch whose HEAD exactly equals
# origin/<default>. It fetches origin and upstream, then runs
# `git merge --no-ff --no-commit upstream/<default>` only in that isolated
# candidate. The operating main checkout is never a target.
#
# A conflict is a relevance decision, not a mechanical merge failure. prepare
# leaves the candidate conflict intact, writes a worktree-private receipt under
# its Git directory, lists matching manifest units, and exits 3. Rerere may have
# populated known working-tree resolutions, but topology setup keeps
# rerere.autoupdate=false, so they remain unstaged. continue refuses until every
# listed unit has one explicit retain/remove decision with a reason and all
# conflicts have been resolved and staged.
#
# A successful merge updates fork-divergences.json in the merge commit itself:
# a unit whose one aggregate patch Git proves equivalent to a reachable upstream
# commit is moved from divergences to retired_upstream with that proof, and one
# bounded sync record captures the pre-merge fork/upstream refs and touched
# units. The proof stays because after this merge upstream is an ancestor of
# fork main, which empties git cherry's equivalence search space. It then
# commits the two-parent merge, runs the human `git range-diff --remerge-diff`
# review, and validates the candidate manifest against HEAD. It never pushes,
# opens a PR, force-updates a ref, or invokes no-mistakes; the task worker owns
# validation and delivery through the isolated fork-target registration.
#
# Decision file schema:
#   {"schema":"firstmate.fork-rejustify.v1","decisions":[
#     {"id":"<manifest-id-or-__unowned__>","action":"retain|remove","reason":"..."}
#   ]}
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-fork-lib.sh
. "$SCRIPT_DIR/fm-fork-lib.sh"
MODE=${1:-}
[ "$#" -eq 0 ] || shift
REPO=
DECISIONS=

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-fork-merge: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || die "--repo requires a path"; REPO=$2; shift 2 ;;
    --repo=*) REPO=${1#*=}; shift ;;
    --decisions) [ "$#" -ge 2 ] || die "--decisions requires a path"; DECISIONS=$2; shift 2 ;;
    --decisions=*) DECISIONS=${1#*=}; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$REPO" ] || REPO=$FM_ROOT
REPO=$(cd "$REPO" 2>/dev/null && pwd -P) || die "repository path is unavailable"
git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git worktree: $REPO"
MANIFEST=${FM_FORK_MANIFEST_OVERRIDE:-$REPO/fork-divergences.json}
RECEIPT=$(git -C "$REPO" rev-parse --git-path fm-fork-rejustify.json)
SYNC_RECEIPT=$(git -C "$REPO" rev-parse --git-path fm-fork-last-sync.json)

ids_for_paths() { # [include-unowned], paths on stdin, unique ids on stdout
  local include_unowned=${1:-no} path id spec matched
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    matched=0
    while IFS= read -r id; do
      while IFS= read -r spec; do
        if fm_fork_path_covered "$spec" "$path"; then
          printf '%s\n' "$id"
          matched=1
          break
        fi
      done < <(jq -r --arg id "$id" '.divergences[] | select(.id == $id) | .paths[]' "$MANIFEST")
    done < <(jq -r '.divergences[].id' "$MANIFEST")
    [ "$matched" -eq 1 ] || [ "$include_unowned" != yes ] || printf '__unowned__\n'
  done | sort -u
}

require_topology() {
  "$SCRIPT_DIR/fm-fork-remotes.sh" check "$REPO" >/dev/null \
    || die "fork remote and rerere topology is invalid"
  [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || die "manifest is missing or unsafe"
  case "$MANIFEST" in "$REPO"/*) ;; *) die "manifest must be inside the candidate repository" ;; esac
  git -C "$REPO" ls-files --error-unmatch -- "${MANIFEST#"$REPO"/}" >/dev/null 2>&1 \
    || die "manifest is not tracked"
  ORIGIN_BRANCH=$(fm_fork_remote_branch "$REPO" origin) || die "cannot determine origin default branch"
  UPSTREAM_BRANCH=$(fm_fork_remote_branch "$REPO" upstream) || die "cannot determine upstream default branch"
  ORIGIN_REF="origin/$ORIGIN_BRANCH"
  UPSTREAM_REF="upstream/$UPSTREAM_BRANCH"
}

require_isolated_candidate() {
  local branch top primary
  branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || die "candidate is detached; expected a named feature branch"
  [ "$branch" != "$ORIGIN_BRANCH" ] || die "refusing to merge upstream directly on $ORIGIN_BRANCH"
  top=$(git -C "$REPO" rev-parse --show-toplevel)
  primary=$(git -C "$REPO" worktree list --porcelain | awk 'NR == 1 && $1 == "worktree" { print substr($0,10) }')
  [ "$top" != "$primary" ] || die "candidate is the repository's primary checkout, not an isolated worktree"
}

write_json_atomic() { # <dest>, stdin
  local dest=$1 tmp
  tmp=$(mktemp "$dest.XXXXXX") || return 1
  if cat > "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

accepted_records() { # one JSON retirement record per unit accepted upstream
  # Once this merge lands, upstream becomes an ancestor of fork main and
  # `git cherry`'s <head>..<upstream> equivalence search space is empty, so the
  # fork's own copy of an accepted patch can never be proved equivalent from the
  # merged refs again. This is the last moment the proof exists, so capture the
  # concrete commits and patch identity rather than only the verdict.
  local id class topic summary ref cherry plus minus fork_patch patch_id upstream_patch
  while IFS=$'\t' read -r id class topic summary; do
    [ "$class" != superseded ] || continue
    ref=$(fm_fork_topic_ref "$REPO" "$topic" || true)
    [ -n "$ref" ] || continue
    # A failed `git cherry` prints nothing, which would otherwise count as zero
    # non-equivalent patches and silently delete this unit's governance record
    # from the manifest inside a merge commit claiming upstream accepted it.
    # Git's own diagnosis stays on stderr.
    cherry=$(git -C "$REPO" cherry "$UPSTREAM_REF" "$ref") \
      || die "git cherry could not compare $topic against $UPSTREAM_REF; refusing to treat $id as accepted upstream"
    plus=$(printf '%s\n' "$cherry" | awk '$1 == "+" { n++ } END { print n+0 }')
    [ "$plus" -eq 0 ] || continue
    minus=$(printf '%s\n' "$cherry" | awk '$1 == "-" { n++ } END { print n+0 }')
    # The one-aggregate-patch invariant is the proof boundary. Without exactly
    # one carried commit there is no single patch whose acceptance Git can
    # prove, so the unit keeps its governance record instead of disappearing.
    [ "$minus" -eq 1 ] \
      || die "$topic has $minus equivalent commits rather than one aggregate patch; refusing to retire $id without a single provable patch"
    fork_patch=$(printf '%s\n' "$cherry" | awk '$1 == "-" { print $2 }')
    patch_id=$(fm_fork_commit_patch_id "$REPO" "$fork_patch") \
      || die "cannot compute the patch identity of $fork_patch; refusing to retire $id without it"
    upstream_patch=$(git -C "$REPO" rev-list --no-merges "$ref..$UPSTREAM_REF" \
      | git -C "$REPO" diff-tree -p --stdin \
      | git patch-id --stable | awk -v want="$patch_id" '$1 == want { print $2; exit }')
    [ -n "$upstream_patch" ] \
      || die "git cherry called $topic equivalent upstream but no commit in $UPSTREAM_REF carries patch identity $patch_id; refusing to retire $id unproved"
    jq -nc --arg id "$id" --arg topic "$topic" --arg summary "$summary" \
      --arg date "${FM_FORK_DATE_OVERRIDE:-$(date +%F)}" --arg fork_patch "$fork_patch" \
      --arg upstream_patch "$upstream_patch" --arg patch_id "$patch_id" \
      '{id:$id,topic:$topic,summary:$summary,date:$date,fork_patch:$fork_patch,upstream_patch:$upstream_patch,patch_id:$patch_id}'
  done < <(jq -r '.divergences[] | [.id,.class,.topic,.summary] | @tsv' "$MANIFEST")
}

record_retirements() { # <json-lines-file>
  # Removing the active entry and persisting its proof are one manifest edit so
  # the merge can never publish a fallen divergence count without its evidence.
  local records tmp
  records=$(jq -sc '.' "$1") || die "cannot read the accepted-upstream retirement records"
  tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
  jq --argjson retired "$records" '
    .retired_upstream = ((.retired_upstream // []) + $retired)
    | .divergences |= map(select(.id as $id | ($retired | map(.id) | index($id)) == null))
  ' "$MANIFEST" > "$tmp" || { rm -f "$tmp"; die "cannot record accepted-upstream retirements"; }
  mv -f "$tmp" "$MANIFEST"
}

remove_manifest_ids() { # ids on stdin
  local ids_json tmp
  ids_json=$(jq -Rsc 'split("\n") | map(select(length > 0))')
  tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
  jq --argjson ids "$ids_json" '.divergences |= map(select(.id as $id | ($ids | index($id)) == null))' \
    "$MANIFEST" > "$tmp" || { rm -f "$tmp"; die "cannot remove accepted manifest units"; }
  mv -f "$tmp" "$MANIFEST"
}

record_sync() { # <fork-before> <upstream-before> <upstream-after> <touched-file>
  local fork_before=$1 upstream_before=$2 upstream_after=$3 touched_file=$4 touched_json date tmp
  touched_json=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$touched_file")
  date=${FM_FORK_DATE_OVERRIDE:-$(date +%F)}
  tmp=$(mktemp "$MANIFEST.XXXXXX") || die "cannot create manifest update"
  jq --arg date "$date" --arg fork "$fork_before" --arg before "$upstream_before" \
    --arg after "$upstream_after" --argjson touched "$touched_json" '
      .upstream_syncs += [{date:$date,fork_before:$fork,upstream_before:$before,upstream_after:$after,touched:$touched,validation_pr:null}]
      | if (.upstream_syncs | length) > 20 then .upstream_syncs = .upstream_syncs[-20:] else . end
    ' "$MANIFEST" > "$tmp" || { rm -f "$tmp"; die "cannot record upstream sync"; }
  mv -f "$tmp" "$MANIFEST"
}

commit_merge_and_review() { # <fork-before> <upstream-before> <upstream-after> <touched-file> [removed-file] [accepted-file]
  local fork_before=$1 upstream_before=$2 upstream_after=$3 touched_file=$4 removed_file=${5:-} accepted_file=${6:-}
  if [ -n "$accepted_file" ] && [ -s "$accepted_file" ]; then
    record_retirements "$accepted_file"
  fi
  if [ -n "$removed_file" ] && [ -s "$removed_file" ]; then
    remove_manifest_ids < "$removed_file"
  fi
  record_sync "$fork_before" "$upstream_before" "$upstream_after" "$touched_file"
  git -C "$REPO" add -- "$MANIFEST"
  git -C "$REPO" commit -m "Merge upstream/$UPSTREAM_BRANCH into fork main"
  merge_sha=$(git -C "$REPO" rev-parse HEAD)
  write_json_atomic "$SYNC_RECEIPT" <<EOF
{"fork_before":"$fork_before","upstream_before":"$upstream_before","upstream_after":"$upstream_after","merge":"$merge_sha"}
EOF
  printf 'range-diff: %s..%s -> %s..%s\n' "$upstream_before" "$fork_before" "$upstream_after" "$merge_sha"
  old_patch_count=$(git -C "$REPO" rev-list --no-merges --count "$upstream_before..$fork_before")
  new_patch_count=$(git -C "$REPO" rev-list --no-merges --count "$upstream_after..$merge_sha")
  if [ "$old_patch_count" -eq 0 ] && [ "$new_patch_count" -eq 0 ]; then
    printf 'range-diff: no divergence patches on either side\n'
  else
    git -C "$REPO" range-diff --remerge-diff "$upstream_before..$fork_before" "$upstream_after..$merge_sha"
  fi
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref HEAD
  printf 'prepared: upstream merge candidate %s; run no-mistakes through the isolated fork-target registration\n' "$merge_sha"
}

cmd_prepare() {
  require_topology
  require_isolated_candidate
  [ ! -e "$RECEIPT" ] || die "an earlier conflict re-justification receipt exists; continue it before preparing another merge"
  [ -z "$(git -C "$REPO" status --porcelain)" ] || die "candidate working tree is dirty"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune origin || die "origin fetch failed"
  GIT_TERMINAL_PROMPT=0 git -C "$REPO" fetch --quiet --prune upstream || die "upstream fetch failed"
  local_head=$(git -C "$REPO" rev-parse HEAD)
  origin_head=$(git -C "$REPO" rev-parse "$ORIGIN_REF")
  [ "$local_head" = "$origin_head" ] || die "candidate HEAD is not the fetched $ORIGIN_REF tip"
  upstream_after=$(git -C "$REPO" rev-parse "$UPSTREAM_REF")
  if git -C "$REPO" merge-base --is-ancestor "$UPSTREAM_REF" "$ORIGIN_REF"; then
    printf 'current: %s already contains %s\n' "$ORIGIN_REF" "$UPSTREAM_REF"
    return 0
  fi
  upstream_before=$(git -C "$REPO" merge-base "$local_head" "$upstream_after") \
    || die "fork and upstream do not share a merge base"
  "$SCRIPT_DIR/fm-fork-status.sh" --repo "$REPO" --fork-ref "$ORIGIN_REF" --upstream-ref "$upstream_before" --facts-only >/dev/null \
    || die "pre-merge divergence manifest facts are inconsistent against the previously integrated upstream base"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-merge.XXXXXX") || die "cannot create temporary state"
  trap 'rm -rf "$TMP"' EXIT
  git -C "$REPO" diff --name-only "$upstream_before..$upstream_after" > "$TMP/upstream-paths"
  ids_for_paths no < "$TMP/upstream-paths" > "$TMP/touched"

  merge_rc=0
  git -C "$REPO" merge --no-ff --no-commit "$UPSTREAM_REF" || merge_rc=$?
  if [ "$merge_rc" -ne 0 ]; then
    conflicts="$TMP/conflicts"
    git -C "$REPO" diff --name-only --diff-filter=U > "$conflicts"
    [ -s "$conflicts" ] || die "upstream merge failed without conflict paths; candidate left untouched for inspection"
    ids_for_paths yes < "$conflicts" > "$TMP/affected"
    affected_json=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$TMP/affected")
    conflict_json=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$conflicts")
    touched_json=$(jq -Rsc 'split("\n") | map(select(length > 0)) | unique' "$TMP/touched")
    clean_index_hash=$(fm_fork_index_without_paths_hash "$REPO" "$conflicts")
    jq -n --arg schema firstmate.fork-rejustify-receipt.v1 --arg branch "$(git -C "$REPO" symbolic-ref --short HEAD)" \
      --arg fork "$local_head" --arg before "$upstream_before" --arg after "$upstream_after" --arg clean_index_hash "$clean_index_hash" \
      --argjson affected "$affected_json" --argjson conflicts "$conflict_json" --argjson touched "$touched_json" \
      '{schema:$schema,branch:$branch,fork_before:$fork,upstream_before:$before,upstream_after:$after,affected:$affected,conflicts:$conflicts,touched:$touched,clean_index_hash:$clean_index_hash}' \
      | write_json_atomic "$RECEIPT" || die "could not publish conflict re-justification receipt"
    printf 'rejustify-required: upstream merge conflicts must be justified before resolution\n'
    while IFS= read -r id; do printf '  affected: %s\n' "$id"; done < "$TMP/affected"
    while IFS= read -r path; do printf '  conflict: %s\n' "$path"; done < "$conflicts"
    printf 'receipt: %s\n' "$RECEIPT"
    exit 3
  fi

  accepted_records > "$TMP/accepted"
  commit_merge_and_review "$local_head" "$upstream_before" "$upstream_after" "$TMP/touched" '' "$TMP/accepted"
}

cmd_continue() {
  require_topology
  require_isolated_candidate
  [ -n "$DECISIONS" ] || die "continue requires --decisions <json>"
  [ -f "$DECISIONS" ] && [ ! -L "$DECISIONS" ] || die "decision file is missing or unsafe"
  [ -f "$RECEIPT" ] && [ ! -L "$RECEIPT" ] || die "no conflict re-justification receipt exists"
  jq -e '.schema == "firstmate.fork-rejustify-receipt.v1" and (.branch|type=="string" and length>0) and (.fork_before|test("^[0-9a-f]{40,64}$")) and (.upstream_before|test("^[0-9a-f]{40,64}$")) and (.upstream_after|test("^[0-9a-f]{40,64}$")) and (.clean_index_hash|test("^[0-9a-f]{40,64}$")) and (.affected|type=="array" and length>0) and (.conflicts|type=="array" and length>0) and (.touched|type=="array")' \
    "$RECEIPT" >/dev/null || die "conflict re-justification receipt is malformed"
  jq -e '.schema == "firstmate.fork-rejustify.v1" and (.decisions | type == "array") and ([.decisions[].id] | length == (unique | length)) and all(.decisions[]; (.id|type=="string" and (. == "__unowned__" or test("^[a-z0-9][a-z0-9-]*$"))) and (.action=="retain" or .action=="remove") and (.reason|type=="string" and length>=12 and (test("[[:cntrl:]]")|not)))' \
    "$DECISIONS" >/dev/null || die "decision file does not satisfy firstmate.fork-rejustify.v1"
  expected_ids=$(jq -r '.affected[]' "$RECEIPT" | sort)
  decision_ids=$(jq -r '.decisions[].id' "$DECISIONS" | sort)
  [ "$decision_ids" = "$expected_ids" ] || die "decision file must name exactly the affected units and no others"
  receipt_branch=$(jq -r .branch "$RECEIPT")
  [ "$(git -C "$REPO" symbolic-ref --short HEAD)" = "$receipt_branch" ] || die "candidate branch differs from the receipt"
  fork_before=$(jq -r .fork_before "$RECEIPT")
  upstream_before=$(jq -r .upstream_before "$RECEIPT")
  upstream_after=$(jq -r .upstream_after "$RECEIPT")
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$fork_before" ] || die "candidate HEAD differs from the recorded pre-merge fork"
  [ "$(git -C "$REPO" rev-parse MERGE_HEAD 2>/dev/null || true)" = "$upstream_after" ] || die "active merge differs from the receipt"
  [ -z "$(git -C "$REPO" diff --name-only --diff-filter=U)" ] || die "conflicts remain unresolved or unstaged"
  git -C "$REPO" diff --quiet || die "unstaged changes remain after conflict resolution"
  [ -z "$(git -C "$REPO" ls-files --others --exclude-standard)" ] || die "untracked files are present in the merge candidate"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-fork-continue.XXXXXX") || die "cannot create temporary state"
  trap 'rm -rf "$TMP"' EXIT
  jq -r '.conflicts[]' "$RECEIPT" > "$TMP/conflicts"
  [ "$(fm_fork_index_without_paths_hash "$REPO" "$TMP/conflicts")" = "$(jq -r .clean_index_hash "$RECEIPT")" ] \
    || die "non-conflict index entries changed after the merge stopped"
  jq -r '.touched[]' "$RECEIPT" > "$TMP/touched"
  jq -r '.decisions[] | select(.action == "remove" and .id != "__unowned__") | .id' "$DECISIONS" | sort -u > "$TMP/remove"
  accepted_records > "$TMP/accepted"
  # Ensure rerere records the manually staged result before the merge commit.
  git -C "$REPO" rerere >/dev/null 2>&1 || true
  commit_merge_and_review "$fork_before" "$upstream_before" "$upstream_after" "$TMP/touched" "$TMP/remove" "$TMP/accepted"
  rm -f "$RECEIPT"
}

cmd_range_diff() {
  [ -f "$SYNC_RECEIPT" ] && [ ! -L "$SYNC_RECEIPT" ] || die "no completed sync receipt exists"
  fork_before=$(jq -r .fork_before "$SYNC_RECEIPT")
  upstream_before=$(jq -r .upstream_before "$SYNC_RECEIPT")
  upstream_after=$(jq -r .upstream_after "$SYNC_RECEIPT")
  merge_sha=$(jq -r .merge "$SYNC_RECEIPT")
  git -C "$REPO" range-diff --remerge-diff "$upstream_before..$fork_before" "$upstream_after..$merge_sha"
}

case "$MODE" in
  prepare) cmd_prepare ;;
  continue) cmd_continue ;;
  range-diff) cmd_range_diff ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
