#!/usr/bin/env bash
# fm-hygiene-audit.sh - read-only audit of leftover state that needs cleanup.
#
# The heartbeat fleet review reads these findings through fm-fleet-snapshot.sh's
# `hygiene` field and fm-fleet-view.sh's Cleanup section, so leftovers surface on
# the routine review instead of waiting for a manual sweep.
# It never deletes, resets, prunes, fetches, or rewrites repository or fleet
# state: every finding is a supervisor-actionable report, and cleanup stays under
# the ordinary guarded owners (bin/fm-teardown.sh, bin/fm-fleet-sync.sh, the
# captain). Its only write is the observational landed-PR cache described below.
#
# Scanned repositories, deduplicated by git common directory:
#   - every clone root under projects/;
#   - every project= recorded in a state/<id>.meta task record;
#   - the operational home itself when it is the main checkout of a repository
#     (the firstmate clone of a primary home).
#
# Finding classes (severity in parentheses):
#   slot-claimed-by-other (action) - a task record's copy carries a
#     .fm-slot-owner claim naming a different task, so the record is stale or the
#     slot was handed out twice; bin/fm-wake-lib.sh owns the claim and its states.
#   slot-claim-unreadable (action) - the claim file exists but is not a claim.
#   shared-copy (action) - two or more task records name the same copy.
#   dirty-orphan-copy (action) - a Treehouse pool copy (a slot
#     fm_treehouse_pool_slot recognizes, or one carrying a .fm-slot-owner claim)
#     that no task record names has uncommitted changes (Firstmate's own
#     untracked hook files are ignored, as in bin/fm-teardown.sh's landed-work
#     test). Other linked worktrees are someone's live work and never findings.
#   unlanded-branch (action) - a local fm/* branch no live task record owns has
#     commits on no remote whose content is not on the default branch.
#   clone-behind (routine) - a clone under projects/ whose local default branch
#     is behind its remote-tracking default branch as of the last fetch; refresh
#     it through bin/fm-fleet-sync.sh.
#   landed-branch (info) - an unowned fm/* branch with commits on no remote whose
#     content already landed; safe leftover, reported only as a count by views.
#
# A branch is owned when state/<id>.meta exists for its fm/<id> name or a task
# record's copy has it checked out; owned branches are live work, never findings.
# Landed means any of: the branch tip is an ancestor of the default ref; every
# unpushed commit is patch-equivalent to one on the default ref (git cherry);
# a 3-way merge of the branch into the default ref leaves the default tree
# unchanged (a squash landing); or a merged pull request from that head branch
# whose head is the local tip, contains it, or carries patch-equivalent commits
# (a pipeline that rebased the branch before pushing).
# The default ref is refs/remotes/origin/<default> when present, else the local
# default branch; nothing is fetched, so results are as fresh as the last fetch.
# A pull-request head is judged only when its commit is already local.
#
# Network: none by default. --pr-lookup opts in to at most FM_HYGIENE_PR_LOOKUPS
# (default 10) `gh pr list` calls, each bounded by FM_HYGIENE_PR_TIMEOUT
# (default 10 seconds), only for branches the offline checks call unlanded.
# A confirmed merged-PR landing is recorded in state/hygiene-landed-prs, keyed by
# repository, branch, and tip, so every later run - including the heartbeat
# snapshot, which never passes --pr-lookup - reports that branch as landed
# without a network call. A moved tip no longer matches its record. Only
# positive results are cached; the file is safe to delete.
# Bounds: FM_HYGIENE_BRANCH_LIMIT (default 100) fm/* branches per repository,
# FM_HYGIENE_GIT_TIMEOUT (default 5 seconds) per landed-content check, and
# FM_HYGIENE_MAX_FINDINGS (default 50) reported findings with the overflow
# counted in `truncated`.
#
# Output: --json prints one object with schema fm-hygiene-audit.v1:
#   {schema, repos_scanned, pr_lookup, findings[], truncated}
# where each finding is {class, severity, repo, path, branch, task, commits,
# detail, evidence}; fields that do not apply are null. The default text form
# prints one `CLEANUP <severity> <class>: ...` line per finding, or nothing when
# the fleet is clean.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() {
  cat <<'EOF'
usage: fm-hygiene-audit.sh [--json] [--pr-lookup]

Read-only audit of leftover state that needs cleanup: stale or shared copy
claims, dirty pool copies no task owns, unlanded fm/* branches no task owns, landed
leftover branches, and clones behind their remote default branch.
Nothing is fetched or changed. --pr-lookup opts in to bounded `gh pr list`
calls that recognize a branch landed through a merged pull request.
The script header owns finding classes, bounds, and the JSON schema.
EOF
}

OUTPUT=text
PR_LOOKUP=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) OUTPUT=json ;;
    --pr-lookup) PR_LOOKUP=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "fm-hygiene-audit: jq not found" >&2; exit 1; }

positive_int() {  # <name> <value>
  case "$2" in
    ''|*[!0-9]*|0) printf 'fm-hygiene-audit: %s must be a positive integer\n' "$1" >&2; exit 2 ;;
  esac
}
FM_HYGIENE_BRANCH_LIMIT=${FM_HYGIENE_BRANCH_LIMIT:-100}
FM_HYGIENE_GIT_TIMEOUT=${FM_HYGIENE_GIT_TIMEOUT:-5}
FM_HYGIENE_MAX_FINDINGS=${FM_HYGIENE_MAX_FINDINGS:-50}
FM_HYGIENE_PR_LOOKUPS=${FM_HYGIENE_PR_LOOKUPS:-10}
FM_HYGIENE_PR_TIMEOUT=${FM_HYGIENE_PR_TIMEOUT:-10}
positive_int FM_HYGIENE_BRANCH_LIMIT "$FM_HYGIENE_BRANCH_LIMIT"
positive_int FM_HYGIENE_GIT_TIMEOUT "$FM_HYGIENE_GIT_TIMEOUT"
positive_int FM_HYGIENE_MAX_FINDINGS "$FM_HYGIENE_MAX_FINDINGS"
positive_int FM_HYGIENE_PR_LOOKUPS "$FM_HYGIENE_PR_LOOKUPS"
positive_int FM_HYGIENE_PR_TIMEOUT "$FM_HYGIENE_PR_TIMEOUT"

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"  # fm_meta_get
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"  # fm_run_timed

FINDINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-hygiene-audit.XXXXXX") || exit 1
trap 'rm -f "$FINDINGS_FILE"' EXIT

finding() {  # <class> <severity> <repo> <path> <branch> <task> <commits> <detail> [<evidence>]
  jq -cn --arg class "$1" --arg severity "$2" --arg repo "$3" --arg path "$4" \
    --arg branch "$5" --arg task "$6" --arg commits "$7" --arg detail "$8" \
    --arg evidence "${9:-}" \
    'def opt: if . == "" then null else . end;
     {class:$class,severity:$severity,repo:($repo|opt),path:($path|opt),
      branch:($branch|opt),task:($task|opt),
      commits:(if $commits == "" then null else ($commits|tonumber) end),
      detail:$detail,evidence:($evidence|opt)}' >> "$FINDINGS_FILE"
}

real_dir() {  # <dir>
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# --- task records --------------------------------------------------------------

# Parallel arrays over task records whose copy still exists. A secondmate's home
# counts as an owned copy, but it has no project to scan and no slot claim.
TASK_IDS=()
TASK_COPIES=()
TASK_KINDS=()
TASK_PROJECTS=()
for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  id=$(basename "$meta" .meta)
  kind=$(fm_meta_get "$meta" kind)
  if [ "$kind" = secondmate ]; then
    worktree=$(fm_meta_get "$meta" home)
    [ -n "$worktree" ] || worktree=$(fm_meta_get "$meta" worktree)
  else
    project=$(fm_meta_get "$meta" project)
    [ -n "$project" ] && TASK_PROJECTS+=("$project")
    worktree=$(fm_meta_get "$meta" worktree)
  fi
  [ -n "$worktree" ] || continue
  copy=$(real_dir "$worktree") || continue
  TASK_IDS+=("$id")
  TASK_COPIES+=("$copy")
  TASK_KINDS+=("$kind")
done

copy_owner() {  # <real-path>: prints the first task id whose record names this copy
  local i
  for i in "${!TASK_COPIES[@]}"; do
    [ "${TASK_COPIES[$i]}" = "$1" ] && { printf '%s' "${TASK_IDS[$i]}"; return 0; }
  done
  return 1
}

# Slot claims and shared copies. The slot helpers are loaded only when needed,
# because loading them creates the state directory.
load_slot_lib() {
  command -v fm_treehouse_slot_owner_state >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"  # fm_treehouse_pool_slot, fm_treehouse_slot_owner_*
}
[ "${#TASK_IDS[@]}" -eq 0 ] || load_slot_lib
for i in "${!TASK_IDS[@]}"; do
  [ "${TASK_KINDS[$i]}" = secondmate ] && continue
  id=${TASK_IDS[$i]} copy=${TASK_COPIES[$i]}
  fm_treehouse_slot_owner_state "$copy" "$id"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    other)
      finding slot-claimed-by-other action "" "$copy" "" "$id" "" \
        "task record $id names this copy, but its slot claim names task $FM_TREEHOUSE_SLOT_OWNER_ID" \
        "claim home ${FM_TREEHOUSE_SLOT_OWNER_HOME:-unknown}"
      ;;
    unsafe)
      finding slot-claim-unreadable action "" "$copy" "" "$id" "" \
        "task record $id names this copy, but its slot claim file cannot be read as a claim"
      ;;
  esac
  sharers=
  for j in "${!TASK_IDS[@]}"; do
    [ "$j" -gt "$i" ] && [ "${TASK_KINDS[$j]}" != secondmate ] || continue
    [ "${TASK_COPIES[$j]}" = "$copy" ] && sharers="$sharers ${TASK_IDS[$j]}"
  done
  earlier=0
  for j in "${!TASK_IDS[@]}"; do
    [ "$j" -lt "$i" ] && [ "${TASK_KINDS[$j]}" != secondmate ] && [ "${TASK_COPIES[$j]}" = "$copy" ] && earlier=1
  done
  if [ -n "$sharers" ] && [ "$earlier" = 0 ]; then
    finding shared-copy action "" "$copy" "" "$id" "" \
      "task records $id$sharers all name this copy"
  fi
done

# --- repositories ----------------------------------------------------------------

REPOS=()
SEEN_COMMON=()
add_repo() {  # <dir> [main-only]
  local dir top common c
  dir=$(real_dir "$1") || return 0
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  top=$(real_dir "$top") || return 0
  [ "$top" = "$dir" ] || return 0
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  common=$(real_dir "$common") || return 0
  if [ "${2:-}" = main-only ] && [ "$common" != "$dir/.git" ]; then
    return 0
  fi
  for c in "${SEEN_COMMON[@]+"${SEEN_COMMON[@]}"}"; do
    [ "$c" = "$common" ] && return 0
  done
  SEEN_COMMON+=("$common")
  # Scan through the main checkout so paths and names are stable.
  REPOS+=("$(dirname "$common")")
}
CLONES=()
for d in "$PROJECTS"/*; do
  [ -d "$d" ] && [ ! -L "$d" ] || continue
  before=${#REPOS[@]}
  add_repo "$d"
  [ "${#REPOS[@]}" -gt "$before" ] && CLONES+=("${REPOS[${#REPOS[@]}-1]}")
done
for p in "${TASK_PROJECTS[@]+"${TASK_PROJECTS[@]}"}"; do add_repo "$p"; done
add_repo "$FM_HOME" main-only

repo_label() {  # <repo-path>
  local projects_real
  projects_real=$(real_dir "$PROJECTS" 2>/dev/null || true)
  if [ -n "$projects_real" ] && [ "$(dirname "$1")" = "$projects_real" ]; then
    basename "$1"
  else
    printf '%s' "$1"
  fi
}

default_name() {  # <repo>
  local ref b
  ref=$(git -C "$1" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then printf '%s' "${ref#origin/}"; return 0; fi
  for b in main master; do
    if git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$b" \
       || git -C "$1" show-ref --verify --quiet "refs/heads/$b"; then
      printf '%s' "$b"; return 0
    fi
  done
  return 1
}

default_ref() {  # <repo> <name>
  if git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2"; then
    printf 'refs/remotes/origin/%s' "$2"
  elif git -C "$1" show-ref --verify --quiet "refs/heads/$2"; then
    printf 'refs/heads/%s' "$2"
  else
    return 1
  fi
}

patch_equivalent() {  # <repo> <default-ref> <branch-ref>
  local out
  out=$(fm_run_timed "$FM_HYGIENE_GIT_TIMEOUT" git -C "$1" cherry "$2" "$3" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  ! printf '%s\n' "$out" | grep -q '^+'
}

content_in_default() {  # <repo> <default-ref> <branch-ref>
  local default_tree merged
  default_tree=$(git -C "$1" rev-parse --quiet --verify "$2^{tree}" 2>/dev/null) || return 1
  merged=$(fm_run_timed "$FM_HYGIENE_GIT_TIMEOUT" git -C "$1" merge-tree --write-tree "$2" "$3" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$merged" | head -1)" = "$default_tree" ]
}

PR_CACHE="$STATE/hygiene-landed-prs"
PR_LOOKUPS_USED=0
pr_cache_hit() {  # <common-dir> <branch> <tip>: prints the recorded PR URL
  [ -f "$PR_CACHE" ] || return 1
  awk -F '\t' -v c="$1" -v b="$2" -v t="$3" \
    '$1 == c && $2 == b && $3 == t { url = $4; found = 1 } END { if (found) print url; exit !found }' \
    "$PR_CACHE" 2>/dev/null
}
pr_cache_record() {  # <common-dir> <branch> <tip> <url>
  local tmp
  tmp="$PR_CACHE.tmp.${BASHPID:-$$}"
  if {
    if [ -f "$PR_CACHE" ]; then tail -n 499 "$PR_CACHE"; fi
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
  } > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$PR_CACHE" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}
# Runs in the caller's shell so the lookup budget is shared; sets MERGED_PR_URL.
MERGED_PR_URL=
merged_pr_contains() {  # <repo> <common-dir> <branch> <tip>
  local repo=$1 common=$2 branch=$3 tip=$4 out url head
  MERGED_PR_URL=$(pr_cache_hit "$common" "$branch" "$tip") && return 0
  [ "$PR_LOOKUP" = 1 ] || return 1
  [ "$PR_LOOKUPS_USED" -lt "$FM_HYGIENE_PR_LOOKUPS" ] || return 1
  PR_LOOKUPS_USED=$((PR_LOOKUPS_USED + 1))
  out=$(cd "$repo" && fm_run_timed "$FM_HYGIENE_PR_TIMEOUT" gh pr list --state merged \
    --head "$branch" --limit 5 --json url,headRefOid \
    --jq '.[] | .url + "\t" + .headRefOid' 2>/dev/null) || return 1
  while IFS=$'\t' read -r url head; do
    [ -n "$head" ] && [ -n "$url" ] || continue
    git -C "$repo" cat-file -e "$head^{commit}" 2>/dev/null || continue
    if [ "$head" = "$tip" ] \
       || git -C "$repo" merge-base --is-ancestor "$tip" "$head" 2>/dev/null \
       || patch_equivalent "$repo" "$head" "$tip"; then
      pr_cache_record "$common" "$branch" "$tip" "$url"
      MERGED_PR_URL=$url
      return 0
    fi
  done <<EOF
$out
EOF
  return 1
}

pool_copy() {  # <repo> <real-path>
  local marker
  load_slot_lib
  fm_treehouse_pool_slot "$1" "$2" && return 0
  marker=$(fm_treehouse_slot_owner_marker "$2") || return 1
  [ -e "$marker" ] || [ -L "$marker" ]
}

# Branches checked out in a copy some task record names.
owned_by_checkout() {  # <repo> <branch-ref>
  local line path=''
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path=${line#worktree } ;;
      "branch $2")
        path=$(real_dir "$path") || continue
        copy_owner "$path" >/dev/null && return 0
        ;;
    esac
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
  return 1
}

audit_repo() {  # <repo>
  local repo=$1 label name ref line path main='' branch_ref branch id tip unpushed evidence count=0 dirty common
  label=$(repo_label "$repo")
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=$repo

  # Dirty pool copies no task record names.
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path=${line#worktree }
        if [ -z "$main" ]; then main=$path; continue; fi
        path=$(real_dir "$path") || continue
        copy_owner "$path" >/dev/null && continue
        pool_copy "$repo" "$path" || continue
        dirty=$(git -C "$path" status --porcelain 2>/dev/null \
          | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -1 || true)
        [ -n "$dirty" ] || continue
        finding dirty-orphan-copy action "$label" "$path" \
          "$(git -C "$path" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" "" "" \
          "a copy no task record names has uncommitted changes" "$dirty"
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)

  name=$(default_name "$repo") || name=
  ref=
  [ -n "$name" ] && ref=$(default_ref "$repo" "$name" 2>/dev/null || true)

  # Unpushed fm/* branches no live task owns.
  while IFS= read -r branch_ref; do
    [ -n "$branch_ref" ] || continue
    count=$((count + 1))
    [ "$count" -le "$FM_HYGIENE_BRANCH_LIMIT" ] || break
    branch=${branch_ref#refs/heads/}
    id=${branch#fm/}
    [ -f "$STATE/$id.meta" ] && continue
    owned_by_checkout "$repo" "$branch_ref" && continue
    unpushed=$(git -C "$repo" rev-list --count "$branch_ref" --not --remotes 2>/dev/null) || continue
    [ "$unpushed" -gt 0 ] || continue
    tip=$(git -C "$repo" rev-parse --verify "$branch_ref" 2>/dev/null) || continue
    evidence=
    if [ -n "$ref" ]; then
      if git -C "$repo" merge-base --is-ancestor "$branch_ref" "$ref" 2>/dev/null; then
        evidence="contained in $name"
      elif patch_equivalent "$repo" "$ref" "$branch_ref"; then
        evidence="patch-equivalent commits on $name"
      elif content_in_default "$repo" "$ref" "$branch_ref"; then
        evidence="content already on $name (squash landing)"
      fi
    fi
    if [ -z "$evidence" ] && merged_pr_contains "$repo" "$common" "$branch" "$tip"; then
      evidence="merged pull request $MERGED_PR_URL"
    fi
    if [ -n "$evidence" ]; then
      finding landed-branch info "$label" "" "$branch" "$id" "$unpushed" \
        "unowned local branch with commits on no remote whose content already landed" "$evidence"
    else
      finding unlanded-branch action "$label" "" "$branch" "$id" "$unpushed" \
        "no task record owns this branch and its commits are on no remote and not on ${name:-the default branch}; bin/fm-hygiene-audit.sh --pr-lookup checks for a merged pull request"
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname)' 'refs/heads/fm/' 2>/dev/null)
}

for repo in "${REPOS[@]+"${REPOS[@]}"}"; do
  audit_repo "$repo"
done

# Clone lag, as of the last fetch.
for repo in "${CLONES[@]+"${CLONES[@]}"}"; do
  name=$(default_name "$repo") || continue
  git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$name" || continue
  git -C "$repo" show-ref --verify --quiet "refs/heads/$name" || continue
  behind=$(git -C "$repo" rev-list --count "refs/heads/$name..refs/remotes/origin/$name" 2>/dev/null) || continue
  [ "$behind" -gt 0 ] || continue
  label=$(repo_label "$repo")
  finding clone-behind routine "$label" "$repo" "$name" "" "$behind" \
    "local $name is behind origin/$name as of the last fetch; refresh with bin/fm-fleet-sync.sh $label"
done

RESULT=$(jq -s --argjson repos "${#REPOS[@]}" --argjson pr_lookup "$([ "$PR_LOOKUP" = 1 ] && echo true || echo false)" \
  --argjson max "$FM_HYGIENE_MAX_FINDINGS" '
  def rank: {action:0,routine:1,info:2}[.severity] // 3;
  (sort_by(rank)) as $all
  | {schema:"fm-hygiene-audit.v1",repos_scanned:$repos,pr_lookup:$pr_lookup,
     findings:$all[0:$max],truncated:([($all|length) - $max, 0] | max)}' "$FINDINGS_FILE") || exit 1

if [ "$OUTPUT" = json ]; then
  printf '%s\n' "$RESULT"
else
  printf '%s\n' "$RESULT" | jq -r '
    .findings[]
    | "CLEANUP \(.severity) \(.class): \([.repo, .branch, .path, (if .commits then "\(.commits) commit(s)" else null end)] | map(select(. != null)) | join(" ")) - \(.detail)\(if .evidence then " (\(.evidence))" else "" end)"'
  printf '%s\n' "$RESULT" | jq -r 'select(.truncated > 0) | "CLEANUP info truncated: \(.truncated) more finding(s) not shown"'
fi
