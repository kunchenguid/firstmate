#!/usr/bin/env bash
# fm-review-sweep.sh — recurring, automated review sweep across the whole fleet.
#
# Every run: enumerate every OPEN PR across the fleet repos, drop drafts and
# already-approved PRs (GitHub reviewDecision=APPROVED), fetch CI status per PR,
# and dispatch a review-rectify-pi review (in --push mode, REVIEW-ONLY: no code
# edits, no fixes) to each kept PR as a firstmate crewmate via bin/fm-spawn.sh,
# bounded to FM_SWEEP_CONCURRENCY (3) concurrent reviews. After each review lands
# its PR comment, parse the recommendation; on a clean APPROVE, transition the
# PR's linked Jira ticket (MILE-\d+) to "In Review". A single PR's failure never
# aborts the sweep. Designed to run unattended from cron (no live firstmate).
#
# Usage:
#   fm-review-sweep.sh             # run the sweep (dispatch + review + jira)
#   fm-review-sweep.sh --dry-run   # enumerate + filter + print the plan, dispatch nothing
#   fm-review-sweep.sh --one REPO  # run only one repo (full name owner/name) — for testing
#
# Cron (every 8 hours; firstmate installs this after merge — do NOT auto-install):
#   0 */8 * * * /home/boks/Projects/firstmate/bin/fm-review-sweep.sh >> /home/boks/Projects/firstmate/state/sweep.log 2>&1
#
# Concurrency: FM_SWEEP_CONCURRENCY (default 3). Bounded by gating the dispatch
# loop on the count of running sweep crewmates.
# Per-review timeout: FM_SWEEP_TASK_TIMEOUT (default 1800s = 30min). A review that
# overruns is abandoned (window left for inspection) so the sweep always progresses.
# Fleet repos: parsed from data/projects.md (the github.com/<owner>/<name> URLs).
# Log: state/sweep.log (timestamped run summary: considered/filtered/reviewed,
# per-PR recommendation, Jira moves, failures).
#
# Review-only contract: the dispatched crewmate runs review-rectify-pi --push and
# POSTS/REPLACES the single "Review Findings - Rectification Status" comment
# (the skill's Phase 9 already deletes its prior comment — we do not re-implement
# that). It never edits code or pushes fixes. For failing-CI PRs the brief adds an
# "investigate the CI failure root cause and include a ## CI Failure section"
# instruction so the posted review names the failing job + the error.
set -uo pipefail   # NOT -e: a single PR's failure must not abort the whole sweep.

FM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$FM_ROOT/state"
PROJECTS_MD="$FM_ROOT/data/projects.md"
SWEEP_LOG="$STATE_DIR/sweep.log"
SWEEP_RUN_DIR="$STATE_DIR/sweep"          # per-run scratch (task ids, briefs live under data/)

CONCURRENCY="${FM_SWEEP_CONCURRENCY:-3}"
TASK_TIMEOUT="${FM_SWEEP_TASK_TIMEOUT:-1800}"
DRY_RUN=0
ONLY_REPO=""

log() { printf '%s\n' "$*" >> "$SWEEP_LOG"; }
say() { printf '%s\n' "$*"; }   # stdout (cron redirects both to sweep.log via >>2>&1)
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
# prerequisite helper (used inside main)
need() { command -v "$1" >/dev/null 2>&1 || { say "error: missing required tool '$1'"; exit 1; }; }

# ---- resolve fleet repos from data/projects.md -----------------------------
# Each registry line carries a github.com/<owner>/<name> URL. Emit
# "<owner>/<name>\t<local-clone-path>" per repo. The local clone path is needed
# so fm-spawn can `treehouse get` a worktree of that repo.
resolve_fleet() {
  [ -f "$PROJECTS_MD" ] || { say "error: no fleet registry at $PROJECTS_MD"; exit 1; }
  local line url proj
  # project name is the first token of each "- <name> [...]" bullet; the local
  # clone lives at projects/<name>. The github URL is the github.com/<o>/<n> token.
  while IFS= read -r line; do
    case "$line" in
      *github.com/*)
        url=$(printf '%s' "$line" | grep -oE 'github.com/[^ )"]+' | head -1 | sed 's#github.com/##')
        proj=$(printf '%s' "$line" | grep -oE '^- [A-Za-z0-9_-]+' | sed 's/^- //')
        # strip a trailing .git if present
        url="${url%.git}"
        if [ -n "$url" ] && [ -n "$proj" ]; then
          printf '%s\t%s\n' "$url" "projects/$proj"
        fi
        ;;
    esac
  done < "$PROJECTS_MD"
}

# ---- CI status for a PR: returns "fail" | "pass" | "unknown" ----------------
# gh pr checks --json state values: SUCCESS, FAILURE, STARTED, PENDING, SKIPPED,
# CANCELLED, TIMED_OUT, etc. We treat a PR as CI-failing only if at least one
# check is in a hard-failure state; pending/running/missing checks are not fails.
ci_status() {
  local repo=$1 num=$2 states out
  if ! out=$(gh pr checks "$num" --repo "$repo" --json state -q '[.[].state]' 2>/dev/null); then
    echo unknown; return
  fi
  states=$(printf '%s' "$out" | tr -d ' \n[]"')
  [ -z "$states" ] && { echo unknown; return; }
  # hard failures
  case "$states" in
    *FAILURE*|*TIMED_OUT*|*CANCELLED*|*ACTION_REQUIRED*) echo fail; return ;;
  esac
  echo pass
}

# ---- enumerate candidate PRs for one repo ----------------------------------
# Emits TSV rows: repo<TAB>num<TAB>cifail<TAB>title<TAB>url<TAB>headRefOid
# Drafts and APPROVED PRs are excluded here.
emit_repo_prs() {
  local repo=$1 proj=$2 prs num draft dec cifail title url head
  prs=$(gh pr list --repo "$repo" --state open --limit 100 \
        --json number,isDraft,reviewDecision,title,url,headRefOid 2>/dev/null) || return 0
  [ -n "$prs" ] || return 0
  while IFS=$'\t' read -r num draft dec title url head; do
    [ -n "$num" ] || continue
    # filter: exclude drafts
    [ "$draft" = "true" ] && { log "  filter  $repo#$num draft"; continue; }
    # filter: exclude already-approved (reviewDecision=APPROVED)
    [ "$dec" = "APPROVED" ] && { log "  filter  $repo#$num approved"; continue; }
    cifail=$(ci_status "$repo" "$num")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$repo" "$num" "$cifail" "$title" "$url" "$head" "$proj"
  done < <(printf '%s' "$prs" | jq -r '.[] | [.number, (.isDraft|tostring), (.reviewDecision // ""), .title, .url, .headRefOid] | @tsv')
}

# ---- build a per-PR review brief -------------------------------------------
# Review-only: check out the PR head, run review-rectify-pi --push, report done.
# For failing-CI PRs, add the "investigate root cause + ## CI Failure section" rule.
write_brief() {
  local id=$1 repo=$2 num=$3 cifail=$4 proj=$5
  local brief_dir="$FM_ROOT/data/$id"
  mkdir -p "$brief_dir"
  local status_file="$FM_ROOT/state/$id.status"
  local repo_dir="$FM_ROOT/$proj"
  local cifail_rule=""
  if [ "$cifail" = "fail" ]; then
    cifail_rule=$(
      cat <<'EOF'

## CI failure (this PR's CI is RED — investigate before reviewing)
This PR's GitHub checks are FAILING. As part of this review you MUST investigate
the ROOT CAUSE of the CI failure and include a `## CI Failure` section in the
posted review comment. Steps:
- `gh pr checks <NUM> --repo <REPO>` to list the checks; identify the FAILING job(s).
- Open the failing job's log: `gh run view <run-id> --repo <REPO> --log-failed`
  (or the job URL from `gh pr checks`). Read the actual error.
- Name the failing job and quote the error in the `## CI Failure` section, with a
  one-line root-cause assessment (compile error, test failure, lint, env, flake?).
The review-rectify-pi recommendation may still be APPROVE if the code is sound
and CI fails for an unrelated/env reason — but the failure MUST be documented.
EOF
    )
    cifail_rule=${cifail_rule//<NUM>/$num}
    cifail_rule=${cifail_rule//<REPO>/$repo}
  fi

  cat > "$brief_dir/brief.md" <<EOF
You are a crewmate dispatched by the automated review sweep. Work autonomously; do not wait for a human.

# Task
Run a **fresh code review** of PR **$repo#$num** and post it as the PR's review
comment. This is **REVIEW-ONLY**: review and post — do NOT edit any code, do NOT
push any fix, do NOT change the branch beyond checking out the PR to review it.

# Engine
Use the **review-rectify-pi** skill in **\`--push\`** mode. Invoke it so it runs
its full pipeline (existing-comment rectification + fresh code review + merged
findings table + recommendation) and posts/replaces the single
"Review Findings - Rectification Status" comment on the PR.

# Setup
You are in a treehouse worktree of \`$repo\` (clone at \`$repo_dir\`) on a detached
HEAD of the default branch. To review THIS PR, check out its head commit IN THIS
WORKTREE (never touch the pooled clone — review here, in your disposable worktree):
1. \`gh pr checkout $num --repo $repo\`  — run this from your worktree; it fetches
   the PR head and checks it out locally. If it refuses (shared worktree / branch
   exists), fall back to a detached checkout of the head:
   \`git fetch origin pull/$num/head && git checkout --detach FETCH_HEAD\`.
2. Confirm you are on the PR head: \`git rev-parse HEAD\` should equal the PR's
   head SHA (\`gh pr view $num --repo $repo --json headRefOid -q .headRefOid\`).
$cifail_rule

# How to run the review
- Invoke review-rectify-pi with **\`--push\`** so it posts the comment to GitHub.
- The skill already deletes its prior "Review Findings - Rectification Status"
  comment and posts the fresh one (Phase 9) — do NOT manually delete comments.
- Scope the review to the PR's diff. The skill computes diff scope itself; make
  sure you are on the PR head (step above) so \`git diff main...HEAD\` is correct.
- Pre-push validation (Phase 8.5) runs the project's lint/typecheck/test. If that
  fails because of the RED CI, that is expected for failing-CI PRs — still post
  the review with the \`## CI Failure\` section; do not block on Phase 8.5.

# Rules
1. REVIEW-ONLY. Never edit project code, never commit, never push, never open or
   merge a PR. The only GitHub write you do is the review comment (via the skill).
2. Stay inside this worktree; the only files you may write outside it are the
   status file below.
3. Use gh / gh-axi for GitHub operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $status_file\`
   States: working, needs-decision, blocked, done, failed.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop.
6. If a decision belongs to a human, append \`needs-decision: {summary}\` and stop.

# Definition of done
The review comment is posted to $repo#$num. When posted, append
\`done: posted review to $repo#$num\` to the status file and STOP (exit pi with
\`/quit\`). Do not attempt to fix anything the review found.
EOF
  echo "$brief_dir/brief.md"
}

# ---- spawn one review (non-blocking) -------------------------------------
# Writes the brief and spawns the crewmate via fm-spawn. Returns 0 and sets
# SPAWN_ID on success; the caller then owns waiting for that task. fm-spawn
# itself blocks until the harness is confirmed running (its post-launch verify),
# so when this returns the crewmate is live and processing the brief — but the
# review is NOT done yet. Best-effort: never aborts the caller.
spawn_review() {
  local repo=$1 num=$2 cifail=$3 proj=$4
  local id status_file
  id="sweep-$(printf '%s' "$repo" | tr '/.' '--')-${num}-$$"
  status_file="$FM_ROOT/state/$id.status"
  if ! write_brief "$id" "$repo" "$num" "$cifail" "$proj"; then
    log "  error   $repo#$num brief write failed"
    return 1
  fi
  : > "$status_file"
  # Spawn headlessly (cron has no TMUX). FM_SPAWN_NO_GUARD: no watcher to guard.
  local spawn_out spawn_rc=0
  if ! spawn_out=$(env -u TMUX FM_SPAWN_NO_GUARD=1 \
        "$FM_ROOT/bin/fm-spawn.sh" "$id" "$FM_ROOT/$proj" 2>&1); then
    spawn_rc=$?
    log "  error   $repo#$num fm-spawn failed (rc=$spawn_rc): $(printf '%s' "$spawn_out" | tail -1)"
    rm -f "$FM_ROOT/state/$id.meta" "$status_file"; rm -rf "$FM_ROOT/data/$id"
    return 1
  fi
  printf '%s\n' "$id" >> "$SWEEP_RUN_DIR/.active"
  log "  spawn   $repo#$num -> $id (cifail=$cifail)"
  SPAWN_ID="$id"
}

# ---- parse the recommendation from the posted PR comment -------------------
# review-rectify-pi posts a comment whose closing section contains a line:
#   ### Recommendation: APPROVE    (or BLOCK / REQUEST CHANGES / CAUTION /
#                                   CONDITIONAL APPROVE)
# We must detect a CLEAN APPROVE only (not CONDITIONAL APPROVE). Returns the
# bare decision word (uppercased) or "" if not found.
parse_recommendation() {
  local repo=$1 num=$2 comments line
  comments=$(gh api "repos/$repo/issues/$num/comments" --jq '.[].body' 2>/dev/null) || { echo ""; return; }
  # Find the recommendation line in the review-rectify comment block.
  line=$(printf '%s\n' "$comments" | grep -iE '^[# ]*Recommendation:' | tail -1)
  [ -n "$line" ] || line=$(printf '%s\n' "$comments" | grep -iE 'Recommendation:' | tail -1)
  [ -n "$line" ] || { echo ""; return; }
  # strip up to the colon, take the first decision word, uppercase
  local decision
  decision=$(printf '%s' "$line" | sed -E 's/.*[Rr]ecommendation:[[:space:]]*//' | awk '{print toupper($1)}')
  # CONDITIONAL APPROVE: the first word is CONDITIONAL — surface it distinctly.
  printf '%s\n' "$decision"
}

# ---- Jira tie-in: on clean APPROVE, move MILE-<key> to "In Review" ---------
jira_key_for() {
  local repo=$1 num=$2 key
  # Firstmate's records (brief/backlog) are the preferred source, but the sweep
  # is self-contained: parse MILE-\d+ from the PR title/body.
  key=$(gh pr view "$num" --repo "$repo" --json title,body -q '.title + "\n" + .body' 2>/dev/null \
        | grep -oE 'MILE-[0-9]+' | head -1)
  printf '%s\n' "$key"
}

maybe_transition_jira() {
  local repo=$1 num=$2 decision=$3 key out
  [ "$decision" = "APPROVE" ] || return 0
  key=$(jira_key_for "$repo" "$num")
  if [ -z "$key" ]; then
    log "  jira    $repo#$num APPROVE but no MILE- key in title/body; skipping transition"
    return 0
  fi
  if ! command -v jira >/dev/null 2>&1; then
    log "  jira    $repo#$num APPROVE ($key) but 'jira' CLI not found; skipping transition"
    return 0
  fi
  if out=$(jira issue move "$key" "In Review" 2>&1); then
    log "  jira    $repo#$num APPROVE -> moved $key to In Review"
    say "jira: moved $key to In Review ($repo#$num approved by sweep)"
  else
    log "  jira    $repo#$num APPROVE -> FAILED to move $key: $(printf '%s' "$out" | tail -1)"
  fi
}

# ---- teardown a sweep crewmate (best-effort) -------------------------------
teardown_task() {
  local id=$1
  local window="fm-$id"
  # Tell pi to quit, then exit the treehouse subshell, then kill the window.
  tmux send-keys -t "$window" '/quit' Enter 2>/dev/null || true
  sleep 2
  tmux send-keys -t "$window" 'exit' Enter 2>/dev/null || true
  sleep 1
  tmux kill-window -t "$window" 2>/dev/null || true
  # return the worktree to the pool if treehouse still holds it
  treehouse prune --yes >/dev/null 2>&1 || true
  rm -f "$FM_ROOT/state/$id.meta" "$FM_ROOT/state/$id.turn-ended" \
        "$FM_ROOT/state/$id.pi-ext.ts" "$FM_ROOT/state/$id.status"
  rm -rf "$FM_ROOT/data/$id"
}

# ============================================================================
# Main (guarded so the helper functions above can be sourced by tests)
# ============================================================================
main() {
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --one) ONLY_REPO="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE_DIR" "$SWEEP_RUN_DIR"

# ---- flock: never overlap two sweeps ---------------------------------------
exec 9>>"$STATE_DIR/.sweep.lock"
if ! flock -n 9; then
  say "sweep: another run holds the lock; exiting"
  exit 0
fi

RUN_TS="$(ts)"
log ""
log "==== sweep start $RUN_TS (dry-run=$DRY_RUN, concurrency=$CONCURRENCY) ===="

# ---- prerequisites ----------------------------------------------------------
need gh
need tmux
need jq
need git
# jira is optional (only the transition needs it); checked lazily where used.

say "sweep: enumerating fleet PRs..."
FLEET=$(resolve_fleet)
[ -n "$FLEET" ] || { say "sweep: no fleet repos resolved; nothing to do"; log "==== sweep end (no repos) ===="; exit 0; }

# Collect candidate PRs into a plan.
PLAN_FILE="$SWEEP_RUN_DIR/$$.plan"
: > "$PLAN_FILE"
considered=0
while IFS=$'\t' read -r repo proj; do
  [ -n "$repo" ] || continue
  if [ -n "$ONLY_REPO" ] && [ "$repo" != "$ONLY_REPO" ]; then continue; fi
  say "  repo $repo ($proj)"
  emit_repo_prs "$repo" "$proj" >> "$PLAN_FILE" 2> >(log)
  considered=$((considered + 1))
done < <(printf '%s\n' "$FLEET")

total=$(wc -l < "$PLAN_FILE" | tr -d ' ')
log "  plan    $total candidate PR(s) across $considered repo(s) (after draft+approved filters)"

if [ "$DRY_RUN" -eq 1 ]; then
  say ""
  say "==== DRY RUN PLAN ===="
  say "concurrency=$CONCURRENCY  task_timeout=${TASK_TIMEOUT}s"
  if [ "$total" -eq 0 ]; then
    say "(no candidate PRs after filters)"
  else
    printf 'repo\t#cifail\ttitle\turl\n' 
    while IFS=$'\t' read -r repo num cifail title url head proj; do
      printf '%s\t#%s\t%s\t%s\n' "$repo" "$num" "$cifail" "$title"
    done < "$PLAN_FILE"
  fi
  say "==== END DRY RUN (dispatched nothing) ===="
  log "==== sweep end (dry-run, $total candidates) ===="
  exit 0
fi

# Dispatch with TRUE bounded concurrency: spawn up to CONCURRENCY reviews at
# once, then reap finished ones and refill slots. Each task is polled
# round-robin (non-blocking status check) rather than blocking on one at a time.
reviewed=0
failures=0
# Active pool, held as parallel arrays indexed identically:
#   A_ID[i] A_REPO[i] A_NUM[i] A_DEADLINE[i]
A_ID=(); A_REPO=(); A_NUM=(); A_DEADLINE=()

# helper: current length of the active pool
pool_size() { echo "${#A_ID[@]}"; }

# helper: reap one finished task at index i (parse rec, jira, teardown), then
# compact it out of the arrays. Returns 0 if it reaped one, 1 if still running.
try_reap() {
  local i=$1 id repo num dl now last
  id=${A_ID[i]}; repo=${A_REPO[i]}; num=${A_NUM[i]}; dl=${A_DEADLINE[i]}
  now=$(date +%s)
  last=$(tail -1 "$FM_ROOT/state/$id.status" 2>/dev/null || true)
  local finished=0
  case "$last" in
    done:*|failed:*|blocked:*|needs-decision:*) finished=1 ;;
  esac
  if [ "$finished" -ne 1 ]; then
    # window gone? crewmate exited without terminal status.
    if ! tmux list-windows -a -F '#{window_name}' 2>/dev/null | grep -qx "fm-$id"; then
      [ -n "$last" ] || { last="done: window-exited"; echo "$last" >> "$FM_ROOT/state/$id.status"; }
      finished=1
    elif [ "$now" -ge "$dl" ]; then
      last="timeout"; finished=1
      log "  timeout $repo#$num ($id) after ${TASK_TIMEOUT}s"
    fi
  fi
  [ "$finished" -eq 1 ] || return 1
  # Collect result.
  local decision=""
  decision=$(parse_recommendation "$repo" "$num")
  log "  result  $repo#$num status='$last' recommendation='${decision}'"
  say "sweep: $repo#$num -> recommendation=${decision:-unknown} ($last)"
  if [ -n "$decision" ]; then maybe_transition_jira "$repo" "$num" "$decision"; fi
  teardown_task "$id"
  reviewed=$((reviewed + 1))
  # compact: move last element into slot i, then pop (order does not matter).
  local last_idx=$((${#A_ID[@]} - 1))
  if [ "$i" -lt "$last_idx" ]; then
    A_ID[i]=${A_ID[last_idx]}; A_REPO[i]=${A_REPO[last_idx]}
    A_NUM[i]=${A_NUM[last_idx]}; A_DEADLINE[i]=${A_DEADLINE[last_idx]}
  fi
  unset 'A_ID[last_idx]' 'A_REPO[last_idx]' 'A_NUM[last_idx]' 'A_DEADLINE[last_idx]'
  return 0
}

while IFS=$'\t' read -r repo num cifail title url head proj; do
  [ -n "$repo" ] || continue
  # Concurrency gate: if the pool is full, reap until a slot opens.
  while [ "$(pool_size)" -ge "$CONCURRENCY" ]; do
    reaped=0
    for ((i=0; i<${#A_ID[@]}; i++)); do
      if try_reap "$i"; then reaped=1; break; fi
    done
    [ "$reaped" -eq 1 ] || sleep 15   # all still running; wait and retry
  done
  say "sweep: reviewing $repo#$num (cifail=$cifail)"
  SPAWN_ID=""
  if spawn_review "$repo" "$num" "$cifail" "$proj"; then
    A_ID+=("$SPAWN_ID"); A_REPO+=("$repo"); A_NUM+=("$num")
    A_DEADLINE+=($(( $(date +%s) + TASK_TIMEOUT )))
  else
    failures=$((failures + 1))
    log "  result  $repo#$num FAILED to spawn"
  fi
done < "$PLAN_FILE"

# Drain the remaining pool: reap everything still active until empty.
while [ "$(pool_size)" -gt 0 ]; do
  reaped=0
  for ((i=0; i<${#A_ID[@]}; i++)); do
    if try_reap "$i"; then reaped=1; break; fi
  done
  [ "$reaped" -eq 1 ] || sleep 15
done

log "==== sweep end $RUN_TS: considered=$considered candidates=$total reviewed=$reviewed failures=$failures ===="
say "sweep done: reviewed=$reviewed failures=$failures (see state/sweep.log)"
}

# Run main only when executed, not when sourced (e.g. by tests).
[ "${BASH_SOURCE[0]:-$0}" = "$0" ] && main "$@"
