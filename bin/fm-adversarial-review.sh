#!/usr/bin/env bash
# Adversarial-review loop runner for Firstmate-raised PRs.
# It stages review evidence per the adversarial-review skill (diff minus
# generated files, prose file, tree at the reviewed SHA), posts each round's
# evidence and results into the PR itself, reconciles lens reports under the
# skill's GREEN conditions, and writes the loop-green marker that
# bin/fm-pr-merge.sh requires before merging.
#
# Reviewers stay read-only: this script stages file paths a reviewer can read
# and records structured reports, while firstmate dispatches the tier lenses
# and reconciles each MAJOR/BLOCKER. GREEN needs every required lens
# returned under an assigned independent seat, no lens RED without a parsed
# MAJOR/BLOCKER to reconcile, no MAJOR/BLOCKER unresolved or pending a fix, the
# reviewed head still current, the round within cap, and the Design/UX lens
# present for UI-impacting T2/T3 work. Anything else is RED and writes no
# marker.
#
# The tier is not the caller's to lower, and neither is the diff it is derived
# from. dispatch reads the PR's own base from the forge and classifies the
# reviewed change from the staged file list and diff over it - security- or
# architecture-sensitive paths and major waves need T3, everything else T2. A
# --base is accepted only when it IS the forge base or an ancestor of it, which
# can only widen the review; a narrower base that would understate the tier is
# refused, and a base nothing could verify pins the floor at T3 rather than
# trusting the caller. A --tier below the derived floor is refused too. That
# floor is recorded in the loop-green marker as required=, so the merge
# boundary enforces a minimum tier from the evidence instead of re-deriving a
# classification of its own.
#
# A T0 waiver is captain authority, never self-attestation, and that authority
# is bound to THIS lane and THIS PR: --waiver-hold must name the lane task's own
# captain call, and that call's newest captain decision must contain both the
# grant phrase and this PR's URL (bin/fm-captain-hold.sh answered --names). An
# answered call about anything else clears nothing and writes no marker.
#
# Findings outlive the round that raised them. Reconciliation re-checks every
# MAJOR/BLOCKER from every earlier round of the same PR, and a later round that
# simply stops reporting one does not close it: only a fixed_verified or
# rejected_with_counterevidence disposition does, recorded in any round.
#
# State layout under the task state dir:
#   <id>.adversarial-review/round-<N>/  staged evidence, prompts, reports,
#     seats recorded as each lens reports, resolutions, reconciliation, and
#     posted comments for one round.
#   <id>.adversarial-review-green  the loop-green marker: exactly a pr=, head=,
#     tier=, and required= line. Written only on a GREEN reconciliation at that
#     head, or on a captain-granted T0 waiver.
#
# Usage: fm-adversarial-review.sh <command> [args]
#   dispatch <task-id> <pr-url> [--tier T1|T2|T3|T0] [--wt <path>]
#     [--base <sha>] [--head <sha>] [--round N] [--reclaim] [--ui-impacting]
#     [--seat SLOT=MODEL ...]
#     [--waiver-class C --waiver-reason R --waiver-hold <task-id>]
#   record-lens <task-id> --round N --lens <slot> --report <file> [--seat MODEL]
#   resolve <task-id> --round N --finding <lens>:<id> --disposition <d>
#     [--note <text>]
#   reconcile <task-id> --round N
#   condition
#   action
#   check-green <task-id> <pr-url> [--head <sha>] [--min-tier T1|T2|T3]
#   arm-watch [--interval <secs>] [--stable <n>] [--deadline <secs>]
#   ensure-watch [--interval <secs>] [--stable <n>] [--deadline <secs>]
#
# The condition exits 0 when a PR-open status line still needs a loop and 1
# otherwise. The action dispatches EVERY pending loop, not just the first, so
# one fire covers every PR that opened while the watch was armed. A when-watch
# fires at most once and the runner then drops its REGISTRATION while leaving
# its private spec, trust record, and fired marker behind, so ensure-watch is
# the re-arming half: it reads liveness from the registration, completes the
# adapter's handle-then-retire cycle for the fired outcome, and arms again. It
# runs from the startup path (bin/fm-bootstrap.sh) and again from every PR-open
# registration (bin/fm-pr-check.sh), which is what makes the loop automatic
# rather than something a human remembers to arm. An outcome that is not a
# clean fire is left unacknowledged and reported, because re-arming over it
# would discard the only evidence of what the last fire did.
# Exact reads go through gh and every PR mutation through gh-axi, the same
# split bin/fm-pr-check.sh uses, because gh-axi's curated surface has no
# exact-body read while gh exposes selectable fields.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SELF="$SCRIPT_DIR/fm-adversarial-review.sh"

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

BODY_BEGIN='<!-- fm-adversarial-review:start -->'
BODY_END='<!-- fm-adversarial-review:end -->'
FM_ADV_NL='
'

usage() {
  sed -n '2,/^set -eu/p' "$SELF" | sed 's/^# \{0,1\}//'
}

fail() {
  echo "error: $1" >&2
  exit "${2:-1}"
}

review_dir() {
  printf '%s/%s.adversarial-review' "$STATE" "$1"
}

green_file() {
  printf '%s/%s.adversarial-review-green' "$STATE" "$1"
}

round_dir() {
  printf '%s/round-%s' "$(review_dir "$1")" "$2"
}

# Tier lens slots at the merge boundary, per the skill's strength matrix.
tier_slots() {
  case "$1" in
    T1) printf 'standard\n' ;;
    T2) printf 'frontier\ndeep\n' ;;
    T3) printf 'frontier_max\ndeep-1\ndeep-2\n' ;;
    T0) printf '\n' ;;
    *) return 1 ;;
  esac
}

tier_cap() {
  case "$1" in
    T1) printf '1\n' ;;
    T2|T3) printf '3\n' ;;
    T0) printf '0\n' ;;
    *) return 1 ;;
  esac
}

# Comparable review strength. T0 is a captain waiver rather than a weaker
# review, so it is ordered outside the T1..T3 ladder and compared explicitly
# wherever a floor is enforced.
tier_rank() {
  case "$1" in
    T1) printf '1\n' ;;
    T2) printf '2\n' ;;
    T3) printf '3\n' ;;
    T0) printf '0\n' ;;
    *) return 1 ;;
  esac
}

# Classify the reviewed change from its staged file list and diff. Prints
# "<floor> <default> <ui-impacting>": the floor is the weakest tier this change
# may be reviewed at, and the default is the tier a caller that named none
# adopts. Security-sensitive, architecture-heavy, and major-wave changes pin
# both to T3, so no caller can talk them down to a two-lens round. Everything
# else defaults to T2 and floors at T1, which keeps T1 available for the
# trivial mechanical changes it is for without making it the norm.
classify_required() {
  local files=$1 diff=$2 floor=T1 default=T2 ui=0 count lines
  count=$(grep -c . "$files" 2>/dev/null || true)
  lines=$(grep -c '^[+-]' "$diff" 2>/dev/null || true)
  case "${count:-0}" in ''|*[!0-9]*) count=0 ;; esac
  case "${lines:-0}" in ''|*[!0-9]*) lines=0 ;; esac
  if grep -qEi '(^|/)[^/]*(auth|security|secret|crypto|credential|token|password|permission|policy|sandbox|trust|lease|lock)[^/]*(/|\.)' "$files" 2>/dev/null \
    || grep -qEi '(^|/)(migration|migrations|schema|infra|terraform|k8s|helm|deploy|\.github)(/|\.)' "$files" 2>/dev/null \
    || [ "$count" -ge 25 ] || [ "$lines" -ge 1500 ]; then
    floor=T3
    default=T3
  fi
  if grep -qEi '\.(tsx|jsx|vue|svelte|css|scss|sass|less|html)$' "$files" 2>/dev/null; then
    ui=1
  fi
  printf '%s %s %s\n' "$floor" "$default" "$ui"
}

# One key from the lane task's own metadata, for the facts the round meta does
# not carry (the lane model the seat check compares against).
meta_get() {
  local key=$2 meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  grep -E "^$key=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

slot_class() {
  case "$1" in
    deep-1|deep-2) printf 'deep\n' ;;
    advisory:*) printf 'advisory\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

round_meta_get() {
  local dir=$1 key=$2
  grep -E "^$key=" "$dir/meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# The round meta is a line-per-key record whose reader takes the LAST match, so
# any caller-supplied value carrying a line break could append a second tier=,
# slots=, or required_tier= line below the real one and be read back instead.
# Nothing with a line break is ever written into it.
meta_value_safe() {
  case "$1" in
    *"$FM_ADV_NL"*|*$'\r'*) return 1 ;;
  esac
  return 0
}

# A round number names a directory under the review state dir, so every command
# that takes one holds it to the same shape dispatch does rather than letting a
# traversal through round_dir.
require_round_number() {
  case "${1-}" in
    ''|*[!0-9]*|0*) fail "invalid round: ${1-}" 2 ;;
  esac
}

# Parse the loop-green marker strictly: exactly one pr=, head=, tier=, and
# required= line in any order, nothing else. Sets FM_ADV_GREEN_PR/HEAD/TIER/
# REQUIRED. A marker missing the tier evidence is malformed rather than
# tolerated, so an older two-line marker fails closed instead of merging with
# an unknown review strength.
fm_adv_green_parse() {
  local file=$1 line pr_count=0 head_count=0 tier_count=0 required_count=0
  FM_ADV_GREEN_PR=
  FM_ADV_GREEN_HEAD=
  FM_ADV_GREEN_TIER=
  FM_ADV_GREEN_REQUIRED=
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      pr=*)
        pr_count=$((pr_count + 1))
        [ "$pr_count" -eq 1 ] || return 1
        FM_ADV_GREEN_PR=${line#pr=}
        ;;
      head=*)
        head_count=$((head_count + 1))
        [ "$head_count" -eq 1 ] || return 1
        FM_ADV_GREEN_HEAD=${line#head=}
        ;;
      tier=*)
        tier_count=$((tier_count + 1))
        [ "$tier_count" -eq 1 ] || return 1
        FM_ADV_GREEN_TIER=${line#tier=}
        ;;
      required=*)
        required_count=$((required_count + 1))
        [ "$required_count" -eq 1 ] || return 1
        FM_ADV_GREEN_REQUIRED=${line#required=}
        ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$pr_count" -eq 1 ] && [ "$head_count" -eq 1 ] || return 1
  [ "$tier_count" -eq 1 ] && [ "$required_count" -eq 1 ] || return 1
  tier_rank "$FM_ADV_GREEN_TIER" >/dev/null || return 1
  tier_rank "$FM_ADV_GREEN_REQUIRED" >/dev/null || return 1
  fm_pr_url_parse "$FM_ADV_GREEN_PR" >/dev/null || return 1
  [ "$FM_PR_PROVIDER" = github ] || return 1
  FM_ADV_GREEN_PR=$FM_PR_URL
  fm_pr_head_valid "$FM_ADV_GREEN_HEAD" || return 1
}

write_green_marker() {
  local id=$1 url=$2 head=$3 tier=$4 required=$5 dest tmp
  dest=$(green_file "$id")
  tmp=$(mktemp "$STATE/.fm-adv-green.XXXXXX") || return 1
  printf 'pr=%s\nhead=%s\ntier=%s\nrequired=%s\n' "$url" "$head" "$tier" "$required" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# The literal words a captain has to write to waive this gate. It is fixed and
# specific so the pre-answer task body, which the decision region below still
# includes, cannot supply it by accident.
FM_ADV_WAIVER_PHRASE='adversarial-review waiver'

# A T0 waiver is only as strong as the captain's own recorded words ABOUT THIS
# PR. The lane task's own captain call must carry a recorded captain decision
# naming both the grant phrase and this PR's URL; a call still open, a decision
# about some other subject, an unrelated answered row, or a backlog that cannot
# be read are all refused.
captain_waiver_granted() {
  local hold=$1 url=$2 rc=0
  [ -x "$SCRIPT_DIR/fm-captain-hold.sh" ] || return 1
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-captain-hold.sh" answered "$hold" \
    --names "$FM_ADV_WAIVER_PHRASE" --names "$url" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ]
}

forge_head() {
  local url=$1
  command -v gh >/dev/null 2>&1 || return 1
  gh pr view "$url" --json headRefOid -q .headRefOid 2>/dev/null
}

forge_base() {
  local url=$1
  command -v gh >/dev/null 2>&1 || return 1
  gh pr view "$url" --json baseRefOid -q .baseRefOid 2>/dev/null
}

# Post a comment file to the PR through gh-axi, the only mutation path.
pr_comment() {
  local number=$1 repo=$2 body_file=$3
  gh-axi pr comment "$number" --repo "$repo" --body-file "$body_file" >/dev/null
}

# Splice the loop status section into the PR body and push it back.
sync_body_section() {
  local url=$1 number=$2 repo=$3 section=$4 current tmp in
  command -v gh >/dev/null 2>&1 || return 1
  current=$(gh pr view "$url" --json body -q .body 2>/dev/null) || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/.fm-adv-body.XXXXXX") || return 1
  in=$(mktemp "${TMPDIR:-/tmp}/.fm-adv-body-in.XXXXXX") || { rm -f -- "$tmp"; return 1; }
  printf '%s\n' "$current" > "$in" || { rm -f -- "$tmp" "$in"; return 1; }
  awk -v begin="$BODY_BEGIN" -v end="$BODY_END" -v section="$section" '
    BEGIN { in_old = 0; replaced = 0 }
    $0 == begin { print begin; print section; in_old = 1; replaced = 1; next }
    $0 == end { print end; in_old = 0; next }
    in_old == 1 { next }
    { print }
    END { if (replaced == 0) { print ""; print begin; print section; print end } }
  ' "$in" > "$tmp" || { rm -f -- "$tmp" "$in"; return 1; }
  rm -f -- "$in"
  gh-axi pr edit "$number" --repo "$repo" --body-file "$tmp" >/dev/null || {
    rm -f -- "$tmp"
    return 1
  }
  rm -f -- "$tmp"
}

# Resolve the lane worktree: explicit --wt wins, else the task meta worktree=.
resolve_wt() {
  local id=$1 explicit=$2 meta wt
  if [ -n "$explicit" ]; then
    [ -d "$explicit" ] || return 1
    printf '%s\n' "$explicit"
    return 0
  fi
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  printf '%s\n' "$wt"
}

# Write one read-only reviewer prompt per the skill's dispatch template.
# The enforced reviewer profile has no shell, so every path below is staged
# evidence it can Read, never a command it must run.
# shellcheck disable=SC2016 # single quotes are deliberate: prompt lines carry literal backticked commands that must reach the reviewer verbatim, not expand at staging time.
write_prompt() {
  local dir=$1 slot=$2 class=$3 seat=$4 tier=$5 url=$6 base=$7 head=$8 tree=$9
  local tree_head=${10} files=${11}
  {
    printf 'CAVEMAN MODE: lite - terse, full sentences, keep articles. Technical terms exact. Code unchanged.\n'
    printf '\n'
    printf 'ROLE: adversarial reviewer. Grill-me. READ-ONLY - do NOT edit, and do NOT run `git stash`,\n'
    printf '`git checkout --`, or any heredoc/redirect write to a tracked file, even to test a hypothesis\n'
    printf 'empirically. Do NOT move HEAD either: no `git checkout <branch>`, `switch`, `restore --source`,\n'
    printf '`reset`, or `rebase`. If you do NOT have a shell (the enforced read-only profile has none),\n'
    printf 'work only from the staged evidence files and tree path named below, and say so rather than\n'
    printf 'reviewing a tree you cannot pin to the reviewed SHA. Goal: falsify every claim against the\n'
    printf 'ACTUAL code; find blind/weak spots; rank findings.\n'
    printf '\n'
    printf 'LENS SLOT: %s (strength class %s; seat %s; tier %s; boundary merge).\n' "$slot" "$class" "$seat" "$tier"
    printf 'REVIEWED PR: %s\n' "$url"
    printf 'REVIEWED HEAD: %s over base %s.\n' "$head" "$base"
    printf 'STAGED DIFF: %s/diff.patch (generated files excluded).\n' "$dir"
    printf 'STAGED PROSE (PR title, body, every commit message): %s/prose.md.\n' "$dir"
    printf 'STAGED FILE LIST: %s/files.txt.\n' "$dir"
    printf 'TREE AT REVIEWED SHA: %s (tree HEAD %s).\n' "$tree" "$tree_head"
    if [ "$tree_head" != "$head" ]; then
      printf 'WARNING: the tree HEAD is NOT the reviewed SHA; the diff file above is authoritative.\n'
    fi
    printf 'VERIFY AGAINST (read fully, cite file:line):\n%s\n' "$files"
    printf 'ATTACK THESE ASSUMPTIONS (firstmate: fill the load-bearing claims before dispatching):\n'
    printf '<claims go here>\n'
    printf 'ALSO FALSIFY THE PROSE, not just the code: every factual claim in the commit messages, PR\n'
    printf 'body, and code comments is in scope - counts, "verified against ..." statements, ticket IDs,\n'
    printf 'and any rationale given for a decision. Check each against the code.\n'
    printf 'ALSO HUNT BLIND SPOTS: security/authz, wiring (front+back), schema/type parity, line-number\n'
    printf 'drift, existing-test breakage, edge/empty/error states, accessibility, scope creep.\n'
    printf '\n'
    printf 'OUTPUT (markdown, terse): A. verdict + biggest risk. B. findings table |id|SEV\n'
    printf '(BLOCKER/MAJOR/MINOR/NIT)|claim|code evidence (file:line)|problem|fix|. C. blind spots.\n'
    printf 'D. top 3 must-fix. Cite real file:line for every claim; if unverifiable, say so.\n'
    printf 'ALSO return the structured lens report (verdict, boundary_class: merge, findings with\n'
    printf 'id/severity/claim/evidence/problem/fix, blind_spots) for the reconciler.\n'
  } > "$dir/prompt-$slot.md"
}

cmd_dispatch() {
  local id=$1 url=$2 tier=T2 tier_explicit=0 round=1 reclaim=0 ui=0 ui_explicit=0
  local wt='' base='' head='' waiver_class='' waiver_reason='' waiver_hold='' seats_args=''
  shift 2 || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --tier) tier=${2-}; tier_explicit=1; shift 2 ;;
      --wt) wt=${2-}; shift 2 ;;
      --base) base=${2-}; shift 2 ;;
      --head) head=${2-}; shift 2 ;;
      --round) round=${2-}; shift 2 ;;
      --reclaim) reclaim=1; shift ;;
      --ui-impacting) ui=1; ui_explicit=1; shift ;;
      --seat)
        case "${2-}" in
          *[[:space:]]*|'') fail "--seat must be SLOT=MODEL with no whitespace: ${2-}" 2 ;;
          *=*) ;;
          *) fail "--seat must be SLOT=MODEL: ${2-}" 2 ;;
        esac
        case "${2%%=*}" in
          ''|*[!A-Za-z0-9_:.-]*) fail "--seat slot must be a plain slot name: ${2%%=*}" 2 ;;
        esac
        case "${2#*=}" in
          '') fail "--seat needs a model after the =: ${2-}" 2 ;;
        esac
        seats_args="$seats_args ${2-}"
        shift 2
        ;;
      --waiver-class) waiver_class=${2-}; shift 2 ;;
      --waiver-reason) waiver_reason=${2-}; shift 2 ;;
      --waiver-hold) waiver_hold=${2-}; shift 2 ;;
      --help|-h) usage; return 0 ;;
      *) fail "unknown dispatch flag: $1" 2 ;;
    esac
  done
  meta_value_safe "$waiver_class" || fail "--waiver-class cannot contain a line break" 2
  meta_value_safe "$waiver_reason" || fail "--waiver-reason cannot contain a line break" 2
  meta_value_safe "$wt" || fail "--wt cannot contain a line break" 2
  fm_pr_task_id_valid "$id" || fail "invalid task id" 2
  fm_pr_url_parse "$url" || fail "invalid PR URL" 2
  [ "$FM_PR_PROVIDER" = github ] || fail "adversarial review supports GitHub PRs only" 2
  url=$FM_PR_URL
  owner=$FM_PR_OWNER
  repo=$FM_PR_REPO
  number=$FM_PR_NUMBER
  case "$tier" in
    T0|T1|T2|T3) ;;
    *) fail "unknown tier: $tier (want T0, T1, T2, or T3)" 2 ;;
  esac
  require_round_number "$round"
  if [ "$tier" = T0 ]; then
    [ -n "$waiver_class" ] && [ -n "$waiver_reason" ] \
      || fail "T0 needs --waiver-class and --waiver-reason on explicit captain words" 2
    [ -n "$waiver_hold" ] \
      || fail "T0 needs --waiver-hold naming this lane task's own captain call" 2
    fm_pr_task_id_valid "$waiver_hold" || fail "invalid --waiver-hold task id" 2
    [ "$waiver_hold" = "$id" ] \
      || fail "T0 waiver must be this lane task's own captain call ($id), not $waiver_hold" 2
    captain_waiver_granted "$id" "$url" \
      || fail "T0 refused: captain call $id records no captain decision naming \"$FM_ADV_WAIVER_PHRASE\" and $url" 1
  fi
  cap=$(tier_cap "$tier")
  if [ "$round" -gt 1 ]; then
    prev=$(round_dir "$id" "$((round - 1))")
    [ -f "$prev/reconciliation.md" ] || fail "round $round needs round $((round - 1)) reconciled first" 1
    grep -qx 'recommendation: RED' "$prev/reconciliation.md" \
      || fail "round $round needs round $((round - 1)) at recommendation RED" 1
    [ "$round" -le "$cap" ] || fail "round $round exceeds the $tier cap of $cap" 1
  fi
  [ ! "$round" -gt "$cap" ] || [ "$tier" = T0 ] || fail "round exceeds cap"
  wt=$(resolve_wt "$id" "$wt") || fail "no lane worktree (pass --wt or record worktree= in task meta)" 1
  meta_value_safe "$wt" || fail "the lane worktree path cannot contain a line break" 1
  if [ -z "$head" ]; then
    head=$(forge_head "$url") || fail "cannot resolve the PR head from the forge (pass --head)" 1
  fi
  fm_pr_head_valid "$head" || fail "invalid head SHA" 2
  # The PR's own base is what decides how much of the change gets reviewed, and
  # therefore what tier it is classified at, so the forge owns it. A --base is
  # a widening escape hatch, never a narrowing one.
  forge_base_sha=$(forge_base "$url" 2>/dev/null) || forge_base_sha=''
  case "$forge_base_sha" in
    *[!0-9a-f]*|"") forge_base_sha='' ;;
  esac
  if [ -z "$base" ]; then
    [ -n "$forge_base_sha" ] || fail "cannot resolve the PR base from the forge (pass --base)" 1
    base=$forge_base_sha
  fi
  case "$base" in
    *[!0-9a-f]*|"") fail "invalid base SHA" 2 ;;
  esac
  base_source=forge
  if [ -z "$forge_base_sha" ]; then
    base_source=unverified
  elif [ "$base" != "$forge_base_sha" ]; then
    git -C "$wt" merge-base --is-ancestor "$base" "$forge_base_sha" 2>/dev/null \
      || fail "--base $base is neither the PR base $forge_base_sha nor an ancestor of it; a narrower base would understate the tier" 1
    base_source=widened
  fi
  dir=$(round_dir "$id" "$round")
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    if [ "$reclaim" = 1 ] && [ "$(round_meta_get "$dir" status)" = failed ]; then
      rm -rf -- "$dir" || fail "cannot reclaim round $round" 1
    else
      fail "round $round already dispatched for $id" 1
    fi
  fi
  # The exclusive create is the exactly-once claim: a second dispatcher for
  # the same round fails here before staging or posting anything.
  mkdir -p "$(review_dir "$id")" || fail "cannot create review state" 1
  mkdir "$dir" || fail "round $round already dispatched for $id" 1
  status='failed'
  round_cleanup() {
    if [ "$status" = 'failed' ]; then
      printf 'status=failed\n' >> "$dir/meta" 2>/dev/null || true
    fi
  }
  trap round_cleanup EXIT
  trap 'exit 1' HUP INT TERM
  slots=$(tier_slots "$tier")
  tree_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || fail "worktree is not a git checkout" 1
  if git -C "$wt" diff --quiet "$base...$head" -- . 2>/dev/null; then
    fail "empty diff for $base...$head: nothing to review" 1
  fi
  git -C "$wt" diff "$base...$head" -- . \
    ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' ':!Cargo.lock' \
    ':!Gemfile.lock' ':!uv.lock' ':!poetry.lock' \
    ':!*symbols.json' ':!*codemap*' > "$dir/diff.patch" \
    || fail "cannot stage the diff" 1
  [ -s "$dir/diff.patch" ] || fail "empty review diff after generated-file exclusions" 1
  git -C "$wt" diff --name-only "$base...$head" -- . \
    ':!package-lock.json' ':!yarn.lock' ':!pnpm-lock.yaml' ':!Cargo.lock' \
    ':!Gemfile.lock' ':!uv.lock' ':!poetry.lock' \
    ':!*symbols.json' ':!*codemap*' > "$dir/files.txt" \
    || fail "cannot list reviewed files" 1
  # The change itself decides the floor. A caller that named no tier adopts the
  # derived one (this is what makes the auto-dispatched loop tier-correct), and
  # a caller that named a weaker tier is refused rather than quietly upgraded,
  # so the mismatch is visible to whoever chose it. A captain-granted T0 waiver
  # is the one tier outside this ladder and keeps its own authority check.
  read -r required_tier default_tier derived_ui <<CLASSIFY
$(classify_required "$dir/files.txt" "$dir/diff.patch")
CLASSIFY
  tier_rank "$required_tier" >/dev/null || fail "cannot classify the reviewed change" 1
  tier_rank "$default_tier" >/dev/null || fail "cannot classify the reviewed change" 1
  # A base nothing could check against the forge makes the staged diff - and so
  # the classification drawn from it - unverifiable, so the floor goes to the
  # top rather than to whatever that diff happened to show.
  if [ "$base_source" = unverified ]; then
    required_tier=T3
    default_tier=T3
  fi
  if [ "$tier" != T0 ]; then
    if [ "$tier_explicit" = 0 ]; then
      tier=$default_tier
    elif [ "$(tier_rank "$tier")" -lt "$(tier_rank "$required_tier")" ]; then
      fail "tier $tier is below the $required_tier this change requires (security/architecture-sensitive paths or major wave)" 1
    fi
    if [ "$ui_explicit" = 0 ] && [ "$derived_ui" = 1 ]; then ui=1; fi
    slots=$(tier_slots "$tier")
    cap=$(tier_cap "$tier")
  fi
  prose_source=gh
  if command -v gh >/dev/null 2>&1 \
    && title=$(gh pr view "$url" --json title -q .title 2>/dev/null) \
    && body=$(gh pr view "$url" --json body -q .body 2>/dev/null); then
    {
      printf '# %s\n\n%s\n' "$title" "$body"
      printf '\n## Commits on the branch\n\n'
      git -C "$wt" log --format='--- %h %s%n%b' "$base..$head" 2>/dev/null || true
    } > "$dir/prose.md"
  elif command -v gh-axi >/dev/null 2>&1 \
    && gh-axi pr view "$number" --repo "$owner/$repo" --full > "$dir/prose.md" 2>/dev/null; then
    {
      printf '\n## Commits on the branch\n\n'
      git -C "$wt" log --format='--- %h %s%n%b' "$base..$head" 2>/dev/null || true
    } >> "$dir/prose.md"
    prose_source=gh-axi
  else
    fail "cannot stage PR prose (gh and gh-axi both failed)" 1
  fi
  {
    printf 'url=%s\ntier=%s\nrequired_tier=%s\nboundary=merge\n' "$url" "$tier" "$required_tier"
    printf 'base=%s\nbase_source=%s\nhead=%s\nwt=%s\ntree=%s\ntree_head=%s\n' \
      "$base" "$base_source" "$head" "$wt" "$wt" "$tree_head"
    printf 'round=%s\ncap=%s\nui_impacting=%s\nprose_source=%s\n' "$round" "$cap" "$ui" "$prose_source"
    printf 'slots=%s\n' "$(printf '%s' "$slots" | paste -sd' ' -)"
    printf 'seats=%s\n' "$seats_args"
    [ "$tier" != T0 ] || printf 'waiver_class=%s\nwaiver_reason=%s\nwaiver_hold=%s\n' \
      "$waiver_class" "$waiver_reason" "$waiver_hold"
    printf 'status=staging\n'
  } > "$dir/meta"
  numstat=$(git -C "$wt" diff --numstat "$base...$head" -- . 2>/dev/null | awk '{a+=$1; d+=$2} END {printf "%d additions, %d deletions", a+0, d+0}')
  files_count=$(grep -c . "$dir/files.txt" 2>/dev/null || true)
  slot_lines=
  # shellcheck disable=SC2086
  for slot in $slots; do
    class=$(slot_class "$slot")
    seat=$(slot_seat "$seats_args" "$slot")
    [ -n "$seat" ] || seat=unassigned
    slot_lines="$slot_lines- $slot (class $class, seat $seat)
"
    write_prompt "$dir" "$slot" "$class" "$seat" "$tier" "$url" "$base" "$head" "$wt" "$tree_head" "$(cat "$dir/files.txt")"
  done
  if [ "$tier" = T0 ]; then
    comment_head="Adversarial review: T0 waiver recorded (merge boundary)"
  else
    comment_head="Adversarial review: round $round dispatched (tier $tier, merge boundary)"
  fi
  {
    printf '## %s\n\n' "$comment_head"
    printf "PR head \`%s\` over base \`%s\`.\n\n" "$head" "$base"
    printf 'Required lens slots: %s (round cap %s).\n\n' "$(printf '%s' "$slots" | paste -sd' ' -)" "$cap"
    [ -z "$slot_lines" ] || printf '%s\n' "$slot_lines"
    if [ "$ui" = 1 ]; then
      printf 'UI-impacting: the advisory Design/UX lens is required this round.\n\n'
    fi
    [ "$tier" != T0 ] || printf 'Waiver class: %s. Reason: %s. Granted by captain call `%s`.\n\n' \
      "$waiver_class" "$waiver_reason" "$waiver_hold"
    [ "$tier" = T0 ] || printf 'Tier floor derived from the reviewed change: %s (base %s).\n\n' \
      "$required_tier" "$base_source"
    printf "Evidence staged before dispatch: diff \`%s\`, prose \`%s\`, file list \`%s\`, tree \`%s\`.\n\n" \
      "$dir/diff.patch" "$dir/prose.md" "$dir/files.txt" "$wt"
    printf 'Diff scope: %s files, %s.\n\n' "$files_count" "$numstat"
    printf 'Reviewers are read-only; reconciliation by firstmate lands in the next round comment.\n'
  } > "$dir/comment.md"
  section=$(printf "Adversarial review (tier %s): round %s dispatched at \`%s\`; recommendation pending." "$tier" "$round" "$head")
  sync_body_section "$url" "$number" "$owner/$repo" "$section" \
    || fail "cannot sync the PR body section" 1
  pr_comment "$number" "$owner/$repo" "$dir/comment.md" \
    || fail "cannot post the round comment" 1
  if [ "$tier" = T0 ]; then
    write_green_marker "$id" "$url" "$head" T0 T0 || fail "cannot write the loop-green marker" 1
    sed -i.bak 's/^status=staging$/status=waived/' "$dir/meta" 2>/dev/null || true
    rm -f -- "$dir/meta.bak"
  else
    sed -i.bak 's/^status=staging$/status=dispatched/' "$dir/meta" 2>/dev/null || true
    rm -f -- "$dir/meta.bak"
  fi
  status='done'
  trap - EXIT
  trap - HUP INT TERM
  printf 'dispatched: %s %s round-%s tier=%s head=%s\n' "$id" "$url" "$round" "$tier" "$head"
}

# Validate a structured lens report: one verdict line and one boundary line,
# then a findings list where every finding carries an id and a severity.
# Prints the verdict, then one id:severity line per finding.
#
# Every value is extracted by stripping its own label rather than by field
# position, because the matching regexes tolerate spacing the field numbering
# does not: `severity:BLOCKER` put the severity in $1, so a BLOCKER parsed to
# an empty severity, passed record-lens, and then missed reconciliation's
# BLOCKER|MAJOR branch entirely. An id is rejected outright when it is empty or
# carries a colon, because the colon is what separates id from severity in the
# line below and in the resolution keys built from it.
lens_report_scan() {
  awk '
    /^[[:space:]]*verdict:[[:space:]]*(GREEN|RED)[[:space:]]*$/ {
      if (saw_verdict == 0) {
        value = $0
        sub(/^[[:space:]]*verdict:[[:space:]]*/, "", value)
        sub(/[[:space:]]+$/, "", value)
        verdict = value
        saw_verdict = 1
      }
      next
    }
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*[^[:space:]]/ {
      if (current != "") { printf "MALFORMED missing-severity %s\n", current; bad = 1 }
      value = $0
      sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      gsub(/[[:space:]]+/, "-", value)
      if (value == "" || index(value, ":") > 0) {
        printf "MALFORMED unusable-id %s\n", (value == "" ? "(empty)" : value)
        bad = 1
        current = ""
        next
      }
      current = value
      next
    }
    /^[[:space:]]*severity:[[:space:]]*(BLOCKER|MAJOR|MINOR|NIT)[[:space:]]*$/ {
      value = $0
      sub(/^[[:space:]]*severity:[[:space:]]*/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (value == "") {
        printf "MALFORMED unusable-severity %s\n", (current == "" ? "(no-id)" : current)
        bad = 1
        current = ""
        next
      }
      if (current != "") { printf "FINDING %s:%s\n", current, value; current = "" }
      next
    }
    END {
      if (saw_verdict == 0) { print "MALFORMED missing-verdict"; exit 1 }
      if (current != "") { printf "MALFORMED missing-severity %s\n", current; exit 1 }
      if (bad) { exit 1 }
      print "VERDICT " verdict
    }
  ' "$1"
}

cmd_record_lens() {
  local id=$1 round='' lens='' report='' seat=''
  shift 1 || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --round) round=${2-}; shift 2 ;;
      --lens) lens=${2-}; shift 2 ;;
      --report) report=${2-}; shift 2 ;;
      --seat) seat=${2-}; shift 2 ;;
      *) fail "unknown record-lens flag: $1" 2 ;;
    esac
  done
  fm_pr_task_id_valid "$id" || fail "invalid task id" 2
  [ -n "$round" ] && [ -n "$lens" ] && [ -n "$report" ] || fail "record-lens needs --round, --lens, --report" 2
  require_round_number "$round"
  # The seat is only known once the lens actually runs, so a round dispatched
  # without one is seated here rather than being unseatable forever.
  if [ -n "$seat" ]; then
    case "$seat" in
      *[[:space:]]*) fail "seat cannot contain whitespace" 2 ;;
      unassigned) fail "\"unassigned\" is the absence of a seat, not a seat" 2 ;;
    esac
  fi
  dir=$(round_dir "$id" "$round")
  [ -f "$dir/meta" ] || fail "round $round was never dispatched for $id" 1
  [ "$(round_meta_get "$dir" status)" != failed ] || fail "round $round failed to dispatch; reclaim it first" 1
  slots=$(round_meta_get "$dir" slots)
  slot_ok=0
  # shellcheck disable=SC2086
  for slot in $slots; do
    if [ "$slot" = "$lens" ]; then slot_ok=1; fi
  done
  if [ "$lens" = advisory:design-ux ]; then slot_ok=1; fi
  [ "$slot_ok" = 1 ] || fail "lens $lens is not a required slot this round" 2
  [ -f "$report" ] || fail "report file is missing" 2
  dest=$(lens_file "$dir" "$lens")
  [ ! -e "$dest" ] || fail "lens $lens is already recorded this round" 1
  scan=$(lens_report_scan "$report") || fail "malformed lens report (need verdict plus id/severity findings)" 1
  case "$scan" in
    *MALFORMED*) fail "malformed lens report" 1 ;;
  esac
  cp -- "$report" "$dest" || fail "cannot store the lens report" 1
  chmod 0600 "$dest" || fail "cannot protect the lens report" 1
  if [ -n "$seat" ]; then
    printf '%s %s\n' "$lens" "$seat" >> "$dir/seats.recorded" \
      || fail "cannot record the lens seat" 1
    chmod 0600 "$dir/seats.recorded" || fail "cannot protect the recorded seats" 1
  fi
  printf 'recorded: %s round-%s lens %s seat %s\n' "$id" "$round" "$lens" "${seat:-unassigned}"
}

cmd_resolve() {
  local id=$1 round='' finding='' disposition='' note=''
  shift 1 || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --round) round=${2-}; shift 2 ;;
      --finding) finding=${2-}; shift 2 ;;
      --disposition) disposition=${2-}; shift 2 ;;
      --note) note=${2-}; shift 2 ;;
      *) fail "unknown resolve flag: $1" 2 ;;
    esac
  done
  fm_pr_task_id_valid "$id" || fail "invalid task id" 2
  [ -n "$round" ] && [ -n "$finding" ] || fail "resolve needs --round and --finding" 2
  require_round_number "$round"
  case "$disposition" in
    unresolved|rejected_with_counterevidence|accepted_pending_fix|fixed_verified) ;;
    *) fail "unknown disposition: $disposition" 2 ;;
  esac
  case "$finding" in
    *:*)
      lens=${finding%%:*}
      fid=${finding#*:}
      ;;
    *) fail "finding must look like <lens>:<id>" 2 ;;
  esac
  [ -n "$lens" ] && [ -n "$fid" ] || fail "finding must look like <lens>:<id>" 2
  # The resolutions file is a whitespace-separated record read back by key, so
  # a key or note carrying whitespace could forge or shadow another finding's
  # disposition. Reject them at the door rather than sanitising on read.
  case "$finding" in
    *[[:space:]]*) fail "finding key cannot contain whitespace" 2 ;;
  esac
  case "$note" in
    *[[:space:]]*)
      case "$note" in
        *$'\n'*|*$'\r'*) fail "note cannot contain a line break" 2 ;;
      esac
      ;;
  esac
  dir=$(round_dir "$id" "$round")
  [ -f "$dir/meta" ] || fail "round $round was never dispatched for $id" 1
  printf '%s:%s %s %s\n' "$lens" "$fid" "$disposition" "$note" >> "$dir/resolutions"
  chmod 0600 "$dir/resolutions" || fail "cannot protect the resolutions" 1
  printf 'resolved: %s round-%s %s:%s %s\n' "$id" "$round" "$lens" "$fid" "$disposition"
}

# The last disposition recorded for one finding wins. The key is matched as the
# whole first field, so a resolution whose free-text note happens to name
# another finding cannot lend that finding its disposition.
finding_disposition() {
  local file=$1 key=$2
  [ -f "$file" ] || return 0
  awk -v k="$key" '$1 == k { d = $2 } END { if (d != "") print d }' "$file" 2>/dev/null || true
}

# The seat assigned to one slot, from the round's recorded seats= list.
# Prints nothing when the slot was never seated.
slot_seat() {
  local seats=$1 slot=$2 pair seat=
  # shellcheck disable=SC2086
  for pair in $seats; do
    case "$pair" in
      "$slot="*) seat=${pair#*=} ;;
    esac
  done
  printf '%s' "$seat"
}

# The seat record-lens stored for one slot, matched as the whole first field.
# The last one recorded wins, and it outranks the dispatch-time seats= list
# because it names the seat that actually produced the report.
recorded_slot_seat() {
  local file=$1 slot=$2
  [ -f "$file" ] || return 0
  awk -v k="$slot" '$1 == k { s = $2 } END { if (s != "") print s }' "$file" 2>/dev/null || true
}

# Every resolutions file for this PR up to and including one round, oldest
# first. A finding's disposition is the last one recorded for it in ANY of
# them, so a fix verified in a later round closes the round that raised it.
resolution_files_through() {
  local id=$1 url=$2 upto=$3 k=1 d files=''
  while [ "$k" -le "$upto" ]; do
    d=$(round_dir "$id" "$k")
    if [ -f "$d/meta" ] && [ "$(round_meta_get "$d" url)" = "$url" ] && [ -f "$d/resolutions" ]; then
      files="$files$d/resolutions
"
    fi
    k=$((k + 1))
  done
  printf '%s' "$files"
}

finding_disposition_across() {
  local files=$1 key=$2 f d disp=''
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    d=$(finding_disposition "$f" "$key")
    [ -z "$d" ] || disp=$d
  done <<RESOLUTIONS
$files
RESOLUTIONS
  printf '%s' "$disp"
}

# Report file for one lens slot. Colons are normalised away so advisory
# slot names stay plain filenames.
lens_file() {
  local dir=$1 slot=$2 safe
  safe=$(printf '%s' "$slot" | tr ':' '-')
  printf '%s/lens-%s.report' "$dir" "$safe"
}

cmd_reconcile() {
  local id=$1 round=
  shift 1 || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --round) round=${2-}; shift 2 ;;
      *) fail "unknown reconcile flag: $1" 2 ;;
    esac
  done
  fm_pr_task_id_valid "$id" || fail "invalid task id" 2
  [ -n "$round" ] || fail "reconcile needs --round" 2
  require_round_number "$round"
  dir=$(round_dir "$id" "$round")
  [ -f "$dir/meta" ] || fail "round $round was never dispatched for $id" 1
  url=$(round_meta_get "$dir" url)
  tier=$(round_meta_get "$dir" tier)
  required_tier=$(round_meta_get "$dir" required_tier)
  recorded_head=$(round_meta_get "$dir" head)
  ui=$(round_meta_get "$dir" ui_impacting)
  slots=$(round_meta_get "$dir" slots)
  seats=$(round_meta_get "$dir" seats)
  lane_model=$(meta_get "$id" model 2>/dev/null || true)
  fm_pr_url_parse "$url" || fail "round meta has an invalid PR URL" 1
  url=$FM_PR_URL
  owner=$FM_PR_OWNER
  repo=$FM_PR_REPO
  number=$FM_PR_NUMBER
  if [ "$tier" = T0 ]; then
    printf 'reconciled: %s round-%s T0 waiver stands\n' "$id" "$round"
    return 0
  fi
  reasons=
  red=0
  note_red() {
    red=1
    reasons="$reasons$1
"
  }
  [ -n "$recorded_head" ] || note_red "missing recorded head"
  live_head=$(forge_head "$url") || live_head=
  if [ -z "$live_head" ]; then
    note_red "current head is unverifiable from the forge"
  elif [ -n "$recorded_head" ] && [ "$live_head" != "$recorded_head" ]; then
    note_red "head changed: reviewed $recorded_head, PR is at $live_head"
  fi
  if [ "$ui" = 1 ] && [ ! -f "$(lens_file "$dir" advisory:design-ux)" ]; then
    note_red "UI-impacting round without the advisory Design/UX lens"
  fi
  lens_table=
  finding_rows=
  seen_keys=' '
  resolution_files=$(resolution_files_through "$id" "$url" "$round")
  # shellcheck disable=SC2086
  for slot in $slots; do
    class=$(slot_class "$slot")
    seat=$(recorded_slot_seat "$dir/seats.recorded" "$slot")
    [ -n "$seat" ] || seat=$(slot_seat "$seats" "$slot")
    # A seat nobody filled is a lens nobody ran, and a lens run by the lane's
    # own model is the implementer reviewing their own work. The seat map makes
    # the standard slot the lane model by definition, so only that class is
    # exempt from the self-review refusal.
    if [ -z "$seat" ] || [ "$seat" = unassigned ]; then
      note_red "lens $slot has no assigned seat"
    elif [ "$class" != standard ] && [ -n "$lane_model" ] && [ "$seat" = "$lane_model" ]; then
      note_red "lens $slot was seated on the lane's own model $lane_model"
    fi
    report=$(lens_file "$dir" "$slot")
    if [ ! -f "$report" ]; then
      note_red "missing REQUIRED lens $slot"
      lens_table="$lens_table- $slot: MISSING (REQUIRED, seat ${seat:-unassigned})
"
      continue
    fi
    verdict=$(lens_report_scan "$report" | awk '$1=="VERDICT"{print $2}')
    lens_table="$lens_table- $slot: $verdict (seat ${seat:-unassigned})
"
    if [ "$verdict" != GREEN ] && [ "$verdict" != RED ]; then
      note_red "lens $slot has no readable verdict"
      continue
    fi
    findings=$(lens_report_scan "$report" | awk '$1=="FINDING"{print $2}')
    reconcilable=0
    # shellcheck disable=SC2086
    for entry in $findings; do
      fid=${entry%%:*}
      sev=${entry#*:}
      case "$sev" in
        BLOCKER|MAJOR)
          reconcilable=$((reconcilable + 1))
          seen_keys="$seen_keys$slot:$fid "
          disp=$(finding_disposition_across "$resolution_files" "$slot:$fid")
          case "$disp" in
            fixed_verified|rejected_with_counterevidence)
              finding_rows="$finding_rows- [$slot:$fid] $sev: $disp
"
              ;;
            accepted_pending_fix)
              note_red "[$slot:$fid] $sev accepted but the fix is pending"
              finding_rows="$finding_rows- [$slot:$fid] $sev: accepted_pending_fix (still red)
"
              ;;
            *)
              note_red "[$slot:$fid] $sev is ${disp:-unresolved}"
              finding_rows="$finding_rows- [$slot:$fid] $sev: ${disp:-unresolved}
"
              ;;
          esac
          ;;
        *)
          disp=$(finding_disposition_across "$resolution_files" "$slot:$fid")
          finding_rows="$finding_rows- [$slot:$fid] $sev: ${disp:-noted}
"
          ;;
      esac
    done
    # A lens that judged the change RED but contributed nothing reconcilable is
    # a report this parser could not read, not a clean round: its blockers live
    # somewhere the reconciler never saw. Disclose it red instead of greening
    # on an empty finding list.
    if [ "$verdict" = RED ] && [ "$reconcilable" -eq 0 ]; then
      note_red "lens $slot returned RED with no parsed MAJOR/BLOCKER finding; its report is degraded or unparseable"
    fi
  done
  # A fix round that simply stops reporting an earlier round's BLOCKER has not
  # closed it. Every MAJOR/BLOCKER raised in an earlier round of this PR is
  # re-checked here against the dispositions recorded in ANY round, so the only
  # way out of the loop is through each finding rather than past it.
  prev_round=1
  while [ "$prev_round" -lt "$round" ]; do
    prev_dir=$(round_dir "$id" "$prev_round")
    if [ -f "$prev_dir/meta" ] && [ "$(round_meta_get "$prev_dir" url)" = "$url" ]; then
      prev_slots=$(round_meta_get "$prev_dir" slots)
      # shellcheck disable=SC2086
      for prev_slot in $prev_slots; do
        prev_report=$(lens_file "$prev_dir" "$prev_slot")
        [ -f "$prev_report" ] || continue
        prev_findings=$(lens_report_scan "$prev_report" | awk '$1=="FINDING"{print $2}') || prev_findings=
        # shellcheck disable=SC2086
        for prev_entry in $prev_findings; do
          prev_fid=${prev_entry%%:*}
          prev_sev=${prev_entry#*:}
          case "$prev_sev" in BLOCKER|MAJOR) ;; *) continue ;; esac
          case "$seen_keys" in *" $prev_slot:$prev_fid "*) continue ;; esac
          seen_keys="$seen_keys$prev_slot:$prev_fid "
          prev_disp=$(finding_disposition_across "$resolution_files" "$prev_slot:$prev_fid")
          case "$prev_disp" in
            fixed_verified|rejected_with_counterevidence)
              finding_rows="$finding_rows- [round $prev_round][$prev_slot:$prev_fid] $prev_sev: $prev_disp (carried)
"
              ;;
            *)
              note_red "[round $prev_round][$prev_slot:$prev_fid] $prev_sev carried forward is ${prev_disp:-unresolved}"
              finding_rows="$finding_rows- [round $prev_round][$prev_slot:$prev_fid] $prev_sev: ${prev_disp:-unresolved} (carried)
"
              ;;
          esac
        done
      done
    fi
    prev_round=$((prev_round + 1))
  done
  if [ "$red" = 0 ]; then recommendation=GREEN; else recommendation=RED; fi
  {
    printf '# Adversarial reconciliation: %s round-%s\n\n' "$id" "$round"
    printf "Tier %s, merge boundary, reviewed head \`%s\`, PR head \`%s\`.\n\n" "$tier" "$recorded_head" "${live_head:-unknown}"
    printf '## Lenses\n\n%s\n' "$lens_table"
    printf '## Findings\n\n'
    if [ -z "$finding_rows" ]; then printf 'No MAJOR/BLOCKER findings recorded.\n\n'; fi
    printf '%s\n' "$finding_rows"
    if [ -n "$reasons" ]; then printf '## Why RED\n\n%s\n' "$reasons"; fi
    printf 'recommendation: %s\n' "$recommendation"
  } > "$dir/reconciliation.md"
  {
    printf '## Adversarial review: round %s %s (tier %s)\n\n' "$round" "$recommendation" "$tier"
    printf "Reviewed head \`%s\`; PR head \`%s\`.\n\n" "$recorded_head" "${live_head:-unknown}"
    printf '%s\n' "$lens_table"
    printf '%s\n' "$finding_rows"
    if [ -n "$reasons" ]; then printf 'Blocking reasons:\n%s\n' "$reasons"; fi
  } > "$dir/result-comment.md"
  section=$(printf "Adversarial review (tier %s): round %s %s at \`%s\`." "$tier" "$round" "$recommendation" "$recorded_head")
  sync_body_section "$url" "$number" "$owner/$repo" "$section" \
    || fail "cannot sync the PR body section" 1
  pr_comment "$number" "$owner/$repo" "$dir/result-comment.md" \
    || fail "cannot post the results comment" 1
  if [ "$recommendation" = GREEN ]; then
    tier_rank "$tier" >/dev/null || fail "round meta has an invalid tier" 1
    tier_rank "$required_tier" >/dev/null || fail "round meta has no derived tier floor" 1
    write_green_marker "$id" "$url" "$recorded_head" "$tier" "$required_tier" \
      || fail "cannot write the loop-green marker" 1
    sed -i.bak 's/^status=.*$/status=green/' "$dir/meta" 2>/dev/null || true
    rm -f -- "$dir/meta.bak"
  else
    sed -i.bak 's/^status=.*$/status=red/' "$dir/meta" 2>/dev/null || true
    rm -f -- "$dir/meta.bak"
  fi
  printf 'reconciled: %s round-%s %s\n' "$id" "$round" "$recommendation"
}

# Print one id<TAB>url line per PR-open status line that still needs a loop.
# A PR needs a loop when no round dir and no loop-green marker cover its URL.
# Task ids come from status filenames and are validated before any path is
# built from them, so a stray file can never escape the state dir.
#
# Selection deliberately does NOT require the lane to be stageable: a PR-open
# line with a worktree that is not resolvable yet is still a PR that owes a
# loop. What keeps such a lane from starving the others is that the action
# claims its round as failed (mark_dispatch_failed) rather than leaving it to
# be re-selected and fail again on every later fire.
pending_loops() {
  local f base id line url marker rdir has_round meta_url rd
  shopt -s nullglob
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    base=$(basename -- "$f")
    id=${base%.status}
    fm_pr_task_id_valid "$id" || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        'done: PR http'*)
          url=${line#done: PR }
          url=${url%% *}
          ;;
        *) continue ;;
      esac
      fm_pr_url_parse "$url" 2>/dev/null || continue
      [ "$FM_PR_PROVIDER" = github ] || continue
      url=$FM_PR_URL
      marker=$(green_file "$id")
      if fm_adv_green_parse "$marker" 2>/dev/null; then
        if [ "$FM_ADV_GREEN_PR" = "$url" ]; then continue; fi
      fi
      has_round=0
      rdir=$(review_dir "$id")
      if [ -d "$rdir" ]; then
        for rd in "$rdir"/round-*/meta; do
          [ -f "$rd" ] || continue
          meta_url=$(grep -E '^url=' "$rd" 2>/dev/null | tail -1 | cut -d= -f2- || true)
          if [ "$meta_url" = "$url" ]; then has_round=1; break; fi
        done
      fi
      [ "$has_round" = 0 ] || continue
      printf '%s\t%s\n' "$id" "$url"
    done < "$f"
  done
  shopt -u nullglob
}

# Claim round 1 as failed for a PR the action could not dispatch. Dispatch's own
# failures all happen before it creates the round directory, so without this the
# same unstageable entry is re-selected on every fire, fails again, and keeps
# the watch from ever re-arming. A failed round is reclaimable with --reclaim
# once the cause is fixed, and no marker is written, so the merge still refuses.
mark_dispatch_failed() {
  local id=$1 url=$2 reason=$3 dir
  meta_value_safe "$url" && meta_value_safe "$reason" || return 1
  dir=$(round_dir "$id" 1)
  mkdir -p "$(review_dir "$id")" 2>/dev/null || return 1
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    mkdir "$dir" 2>/dev/null || return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ ! -f "$dir/meta" ] || return 0
  printf 'url=%s\nboundary=merge\nround=1\ndispatch_error=%s\nstatus=failed\n' \
    "$url" "$reason" > "$dir/meta" || return 1
  chmod 0600 "$dir/meta" || return 1
}

cmd_condition() {
  if [ -n "$(pending_loops | head -1)" ]; then
    return 0
  fi
  return 1
}

# Dispatch EVERY pending loop, not just the first: a when-watch fires once, so
# firing on only one PR would leave every other PR that opened in the same
# window with no loop until somebody noticed. No --tier is passed, so each
# dispatch adopts the tier its own change requires. One failure is reported and
# does not abandon the rest, and any failure exits nonzero so the fire is
# captured as action-failed and firstmate is woken with the evidence. A failure
# also claims its round as failed, so the next fire moves on to the other PRs
# instead of hitting the same unstageable lane and failing again forever.
cmd_action() {
  local pending line id url rc=0 dispatched=0
  pending=$(pending_loops | sort -u)
  [ -n "$pending" ] || fail "no pending adversarial-review loop" 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=${line%%$'\t'*}
    url=${line#*$'\t'}
    if ( cmd_dispatch "$id" "$url" ); then
      dispatched=$((dispatched + 1))
    else
      rc=1
      printf 'actionable: adversarial-review dispatch failed for %s %s\n' "$id" "$url" >&2
      mark_dispatch_failed "$id" "$url" dispatch-failed \
        || printf 'actionable: %s stays pending; its failed round could not be recorded\n' "$id" >&2
    fi
  done <<PENDING
$pending
PENDING
  printf 'dispatched %s pending adversarial-review loop(s)\n' "$dispatched"
  return "$rc"
}

cmd_check_green() {
  local id=$1 url=$2 want_head='' min_tier=''
  shift 2 || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --head) want_head=${2-}; shift 2 ;;
      --min-tier) min_tier=${2-}; shift 2 ;;
      *) fail "unknown check-green flag: $1" 2 ;;
    esac
  done
  [ -z "$min_tier" ] || tier_rank "$min_tier" >/dev/null || fail "unknown --min-tier: $min_tier" 2
  fm_pr_task_id_valid "$id" || fail "invalid task id" 2
  fm_pr_url_parse "$url" || fail "invalid PR URL" 2
  url=$FM_PR_URL
  marker=$(green_file "$id")
  if [ ! -f "$marker" ] || [ -L "$marker" ]; then
    echo "error: adversarial-review loop-green evidence is missing for $url" >&2
    echo "run bin/fm-adversarial-review.sh dispatch $id $url, drive the loop to GREEN, then retry" >&2
    return 1
  fi
  if ! fm_adv_green_parse "$marker"; then
    echo "error: adversarial-review loop-green evidence is malformed for $id" >&2
    return 1
  fi
  if [ "$FM_ADV_GREEN_PR" != "$url" ]; then
    echo "error: adversarial-review loop-green covers $FM_ADV_GREEN_PR, not $url" >&2
    return 1
  fi
  if [ -n "$want_head" ] && [ "$FM_ADV_GREEN_HEAD" != "$want_head" ]; then
    echo "error: adversarial-review loop is GREEN at $FM_ADV_GREEN_HEAD but the PR is at $want_head" >&2
    echo "re-run the loop at the current head, then retry" >&2
    return 1
  fi
  # The minimum tier at this boundary comes from the evidence itself: the
  # marker carries the tier the loop actually ran and the tier the reviewed
  # change required, so a weaker round can never clear a change that needed a
  # stronger one. A T0 marker is a captain-granted waiver and is ordered
  # outside that ladder, so it satisfies the floor by the captain's authority
  # rather than by review strength.
  if [ "$FM_ADV_GREEN_TIER" != T0 ]; then
    if [ "$(tier_rank "$FM_ADV_GREEN_TIER")" -lt "$(tier_rank "$FM_ADV_GREEN_REQUIRED")" ]; then
      echo "error: adversarial-review ran $FM_ADV_GREEN_TIER but this change requires $FM_ADV_GREEN_REQUIRED" >&2
      return 1
    fi
    if [ -n "$min_tier" ] && [ "$(tier_rank "$FM_ADV_GREEN_TIER")" -lt "$(tier_rank "$min_tier")" ]; then
      echo "error: adversarial-review ran $FM_ADV_GREEN_TIER but this boundary requires at least $min_tier" >&2
      return 1
    fi
  fi
  printf 'adversarial-review: green at %s (tier %s, required %s)\n' \
    "$FM_ADV_GREEN_HEAD" "$FM_ADV_GREEN_TIER" "$FM_ADV_GREEN_REQUIRED"
}

when_watch_name() { printf 'adversarial-review-pr\n'; }

cmd_arm_watch() {
  local interval=60 stable=2 deadline=604800
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) interval=${2-}; shift 2 ;;
      --stable) stable=${2-}; shift 2 ;;
      --deadline) deadline=${2-}; shift 2 ;;
      *) fail "unknown arm-watch flag: $1" 2 ;;
    esac
  done
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-when.sh" arm "$(when_watch_name)" \
    --interval "$interval" --stable "$stable" --deadline "$deadline" \
    --condition "$SELF" condition \
    --action "$SELF" action
}

# The re-arming half of the trigger, idempotent so the startup path and every
# PR-open registration can both call it unconditionally.
#
# Liveness is the REGISTRATION, not the watch's private records. A terminal
# outcome makes bin/fm-procevent.sh drop only state/procevent/<sid>.source; the
# spec, trust record, and fired marker under state/when/ survive until
# fm-procevent-when.sh retire removes them. Reading those as "armed" is how a
# watch that has already fired presents as live forever with no runner behind
# it, so this reads the registration and completes the adapter's documented
# handle-then-retire cycle before arming again.
#
# A captured outcome is acknowledged here only when it is a clean end to the
# last arming - a fire that ran the action, or a deadline that expired with
# nothing to do. Anything else (the action failed, the condition errored, the
# fire is ambiguous, the spec was rejected) stays unacknowledged so it keeps
# being re-announced to firstmate, and this reports that it cannot re-arm yet
# rather than burying the evidence under a fresh watch.
cmd_ensure_watch() {
  local sid registration inbox result seq class out rc=0 blocked=0
  sid=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$(when_watch_name)" 2>/dev/null) \
    || { echo "error: adversarial-review watch source id unavailable; the PR-open loop is not armed" >&2; return 1; }
  registration="$STATE/procevent/$sid.source"
  if [ -e "$registration" ] || [ -L "$registration" ]; then
    printf 'adversarial-review: watch %s is registered\n' "$sid"
    return 0
  fi
  inbox="$STATE/procevent-inbox"
  shopt -s nullglob
  for result in "$inbox/$sid".*.result; do
    [ -f "$result" ] && [ ! -L "$result" ] || continue
    [ -e "${result%.result}.handled" ] && continue
    seq=${result%.result}
    seq=${seq##*.}
    case "$seq" in ''|*[!0-9]*) continue ;; esac
    class=$("$SCRIPT_DIR/fm-procevent-when.sh" classify "$result" 2>/dev/null) || class=unknown
    case "$class" in
      fired|never-true)
        printf 'adversarial-review: watch %s outcome %s was %s; acknowledging it to re-arm\n' \
          "$sid" "$seq" "$class"
        FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null || {
          printf 'error: cannot acknowledge adversarial-review watch outcome %s; the PR-open loop stays unarmed\n' \
            "$seq" >&2
          blocked=1
        }
        ;;
      *)
        printf 'actionable: adversarial-review watch %s outcome %s is %s; handle it before the PR-open loop can re-arm\n' \
          "$sid" "$seq" "$class" >&2
        blocked=1
        ;;
    esac
  done
  shopt -u nullglob
  [ "$blocked" -eq 0 ] || return 1
  if ! FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-procevent-when.sh" retire "$(when_watch_name)" >/dev/null; then
    if [ -e "$registration" ] || [ -L "$registration" ]; then
      printf 'adversarial-review: watch %s was armed concurrently\n' "$sid"
      return 0
    fi
    echo "error: cannot clear the adversarial-review watch records before re-arming" >&2
    return 1
  fi
  out=$(cmd_arm_watch "$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ -e "$registration" ] || [ -L "$registration" ]; then
      printf 'adversarial-review: watch %s was armed concurrently\n' "$sid"
      return 0
    fi
    printf 'error: cannot arm the adversarial-review PR-open watch: %s\n' "$out" >&2
    return "$rc"
  fi
  printf '%s\n' "$out"
}

cmd=${1-}
case "$cmd" in
  dispatch) shift; [ "$#" -ge 2 ] || { usage >&2; exit 2; }; cmd_dispatch "$@" ;;
  record-lens) shift; [ "$#" -ge 1 ] || { usage >&2; exit 2; }; cmd_record_lens "$@" ;;
  resolve) shift; [ "$#" -ge 1 ] || { usage >&2; exit 2; }; cmd_resolve "$@" ;;
  reconcile) shift; [ "$#" -ge 1 ] || { usage >&2; exit 2; }; cmd_reconcile "$@" ;;
  condition) shift; cmd_condition "$@" ;;
  action) shift; cmd_action "$@" ;;
  check-green) shift; [ "$#" -ge 2 ] || { usage >&2; exit 2; }; cmd_check_green "$@" ;;
  arm-watch) shift; cmd_arm_watch "$@" ;;
  ensure-watch) shift; cmd_ensure_watch "$@" ;;
  --help|-h|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
