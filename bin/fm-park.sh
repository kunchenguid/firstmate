#!/usr/bin/env bash
# fm-park.sh - park a ship lane whose PR or MR only awaits human review, watch
# it while its agent is stopped, relaunch a fresh worker on review activity,
# and clean the lane up once the merge poll sees it merged.
#
# Usage:
#   fm-park.sh gate <task-id> [--expect-head <sha>]
#   fm-park.sh park <task-id>
#   fm-park.sh resume <task-id> --trigger <text>
#   fm-park.sh land <task-id> [--if-eligible] [--detach]
#   fm-park.sh tick
#   fm-park.sh list
#   fm-park.sh run <task-id> park|resume|land [<args>...]   (internal)
#
# gate is read-only: one fresh forge read of the task's recorded pr= (GitHub
# through one gh GraphQL read, GitLab through glab api for the merge request and
# all pages of its discussions), never a cached verdict. It prints "clean head=<sha>" and
# exits 0, or prints one "unclean: <reason>" line per failing condition and
# exits 3; an unreadable forge, an unsupported provider, or a missing pr= exits 1
# and is never clean. Clean means ready to merge except for a human approval:
#   - open and not a draft;
#   - no conflict, not behind its base, mergeability computed (GitHub mergeable
#     MERGEABLE with mergeStateStatus CLEAN, BLOCKED or HAS_HOOKS; GitLab
#     has_conflicts false with detailed_merge_status mergeable or not_approved);
#   - CI green on the current head (GitHub statusCheckRollup SUCCESS on the
#     head commit; GitLab head_pipeline success with its sha the MR's sha); no
#     CI reported on the current head is not green; on GitHub every check the
#     base branch requires has also reported on the head, read with
#     bin/fm-pr-merge.sh's required-check reading (bin/fm-pr-lib.sh), because
#     the rollup holds only checks that reported; an unreadable requirement
#     is unclean;
#   - no changes requested (GitHub reviewDecision; GitLab requested_changes);
#   - zero unresolved review threads, all of them read;
#   - automated reviewers settled: every reviewer bot that has ever posted on
#     the PR has submitted a review bound to the current head (a comment, or a
#     comment edited later, does not prove its review finished), or the quiet
#     window has elapsed since the anchor. The push time is the
#     earliest check suite created on the head commit on GitHub (its committer
#     time only when no check suite exists) and the head pipeline's creation on
#     GitLab; the anchor is the later of that and the newest CI completion on
#     the head, so the window never starts before CI finished. A reviewer bot is a GitHub Bot account or
#     [bot] login, a GitLab group or project access-token bot
#     (group_<n>_bot_..., how CodeRabbit appears on gitlab.com), or a login
#     listed in config/contribution-review-bots. The window is
#     FM_PARK_QUIET_SECS seconds (default 900), so a PR no bot touched parks
#     only after it, never the moment CI turns green.
# With --expect-head, a head other than <sha> is unclean too.
#
# park re-establishes everything itself and accepts no verdict as input. It
# refuses unless: the task is a ship with pr= and an armed merge poll
# (state/<id>.check.sh); its local copy is clean with HEAD equal to the forge
# head; bin/fm-crew-state.sh reads done or paused; the agent is idle; the
# steering inbox holds no unhandled message; and the gate is clean. It then
# durably leases a Treehouse slot to the task (treehouse lease, state-only, so a
# later get never hands the copy out and prune never removes it even if the
# endpoint shell dies; bin/fm-teardown.sh's treehouse return releases it),
# evaluates the gate again with --expect-head immediately before the stop,
# checks once more that the agent is idle and the inbox empty, writes
# state/<id>.review-park marked pending=1, stops the agent with
# bin/fm-control.sh exit (endpoint, branch, PR, task record, brief, and copy all
# stay), rewrites the record without pending once the stop is confirmed, and
# appends a declared paused: line to the task's status log (reported upward in a
# secondmate home). A refusal before the pending record leaves no record and the
# agent running; a lease already taken stays until teardown, which is harmless.
# A pending record is watched and resumed like a parked one, so feedback still
# relaunches a lane whose park died after the stop, and crew state reads it as
# parking. Each tick promotes a pending record to parked once its agent is
# confirmed dead and drops it while the agent is still alive.
#
# resume writes a note naming the PR, the parked head and the trigger, then runs
# bin/fm-control.sh relaunch --note-file, which starts a fresh agent of the
# recorded adapter in the same copy on the same branch with its original brief
# plus that note. A working: line superseding the declared wait is appended just
# before the launch, so the fresh worker's own reports always follow it. Success
# removes the park record; failure keeps it with resume_error=, which crew state
# reports as blocked and which stops tick retrying until resume runs by hand.
#
# land waits for any other park action on the lane to finish, runs
# bin/fm-teardown.sh <task-id> (never --force), so every teardown gate still
# applies, and prints one outcome line naming the lane and its PR. With
# --if-eligible it does nothing unless the lane is eligible for merge-time
# cleanup (land_eligible below: parked, or config/auto-land present). With
# --detach it starts the land as a detached action (below), prints "automatic
# cleanup started", and returns at once; with --queue it only saves the request.
# The request (state/<id>.review-park-land) records the merged PR as pr=, and
# a land holding the lane lock drops a request whose pr= is not the lane's
# current pr= without acting, so a stale request never tears down a lane that
# has moved on to another PR. bin/fm-watch.sh runs
# land --if-eligible --detach for every merged lane from its merged-poll path
# after the merge outcome is recorded, also when bin/fm-pr-merge.sh recorded it
# first, which makes the watcher the one owner of a merged lane's teardown.
#
# tick is what bin/fm-watch.sh runs every check interval. With
# neither config/auto-land nor config/park-on-review, and no park record, it exits
# after those file tests. Otherwise, holding state/.review-park-tick.lock (a
# held lock exits silently):
#   - pending merged-lane cleanup requests (state/<id>.review-park-land) are
#     retried when the lane lock is free; outcome reports survive task teardown;
#   - the outcome lines detached actions published since the last tick are
#     collected with this tick's close lines;
#   - each parked lane gets one forge read; a trigger relaunches it, a merge is
#     left to the merge poll, and a close without merge is reported once;
#   - with config/auto-land or config/park-on-review, each other idle ship lane
#     with pr= and an armed merge poll gets one forge read:
#     a close without merge is reported once (marker
#     state/.review-park-closed-<id>), and with config/park-on-review a clean
#     gate parks it.
# Relaunch triggers on a parked lane: the head moved, checks failing, changes
# requested, a merge conflict, any unresolved review thread, or any new
# comment (inline review-thread replies included), review or note created or
# edited after the park (an approval with
# no body is not a comment). A branch merely behind its base is not a trigger. It
# records its outcome and close lines as one check park-on-review wake before
# it removes the reports they came from or marks a close as reported, then
# prints them for the watcher to ring; when the wake cannot be recorded it
# removes and prints nothing, so the next tick retries. A quiet tick prints
# nothing.
#
# A lane action started by tick (park, resume) or by the merge poll (land) runs
# detached, as fm-park.sh run, in its own process group with stdio closed, so it
# outlives the watcher iteration that started it and no tick or watcher budget
# can cut it short. It takes the lane's lock itself (state/.review-park-<id>.lock,
# held by every park, resume and land), so a lane runs one action at a time and
# tick skips a lane whose lock is held. Its stdout outcome line, if any, is
# published as state/.review-park-report-<id>-<epoch>-<pid> (a park refusal
# prints none), and the next tick reports it.
# Forge reads are bounded by FM_PARK_READ_SECS (default 15). Each lifecycle
# call an action makes (bin/fm-control.sh exit or relaunch, bin/fm-teardown.sh)
# is bounded by FM_PARK_ACTION_SECS (default 900), a hang backstop well above
# the bounded waits those owners keep themselves. A whole tick holds only reads
# and action starts and ends within FM_PARK_TICK_SECS (default 180), well under
# the watcher's stale grace: every read is cut to what the tick has left. A tick
# that runs out of time saves the lane it did not reach
# (state/.review-park-tick-next) and the next tick starts there.
# Parked lanes use only the first half of the tick, reserving the rest for
# unparked lanes.
#
# list prints each parked lane: id, PR, parked head, and when it parked.
#
# The record is key=value lines (pr, head, parked_at, slot_leased, pending
# until the stop is confirmed, and resume_error after a failed relaunch), mode
# 0600, published by rename.
# GraphQL and jq programs below are literal, not shell expressions.
# shellcheck disable=SC2016
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

# The lifecycle owners this script drives; the overrides exist for tests.
CONTROL_BIN="${FM_PARK_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
TEARDOWN_BIN="${FM_PARK_TEARDOWN_BIN:-$SCRIPT_DIR/fm-teardown.sh}"
CREW_STATE_BIN="${FM_PARK_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
QUIET_SECS=${FM_PARK_QUIET_SECS:-900}
READ_SECS=${FM_PARK_READ_SECS:-15}
ACTION_SECS=${FM_PARK_ACTION_SECS:-900}
TICK_SECS=${FM_PARK_TICK_SECS:-180}
for v in "$QUIET_SECS" "$READ_SECS" "$ACTION_SECS" "$TICK_SECS"; do
  case "$v" in ''|*[!0-9]*) printf 'fm-park: timing overrides must be whole seconds\n' >&2; exit 2 ;; esac
done

usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
die() { printf 'fm-park: %s\n' "$*" >&2; exit "${2:-1}"; }

LOCKS_HELD=
release_locks() {
  local lock
  for lock in $LOCKS_HELD; do fm_lock_release "$lock" || true; done
  LOCKS_HELD=
}
cleanup() {
  release_locks
  [ -z "${PARK_TMP:-}" ] || rm -rf -- "$PARK_TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
PARK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-park.XXXXXX") || die "cannot create a temporary directory"

lock_try() {  # <lock-path>
  fm_lock_try_acquire "$1" || return 1
  LOCKS_HELD="$LOCKS_HELD $1"
}

# The epoch second a tick must end by; empty outside tick.
DEADLINE=
# step_secs <secs> prints that bound cut to what the tick has left, and fails
# once nothing is left.
step_secs() {  # <secs>
  local left
  [ -n "$DEADLINE" ] || { printf '%s\n' "$1"; return 0; }
  left=$(( DEADLINE - $(date +%s) ))
  [ "$left" -gt 0 ] || return 1
  if [ "$left" -lt "$1" ]; then printf '%s\n' "$left"; else printf '%s\n' "$1"; fi
}
lane_lock() { printf '%s/.review-park-%s.lock' "$STATE" "$1"; }

# Succeeds while another park action holds the lane.
lane_busy() {  # <id>
  local lock
  lock=$(lane_lock "$1")
  fm_lock_try_acquire "$lock" || return 0
  fm_lock_release "$lock" || true
  return 1
}

# Starts fm-park.sh run <id> <verb> <args...> detached: its own process group
# (so a bound on the caller's group cannot reach it), nohup, and stdio closed
# (so it holds no pipe of the watcher open), in a subshell that returns at once.
action_start() {  # <id> <verb> <args...>
  ( set -m 2>/dev/null || true
    nohup "$SCRIPT_DIR/fm-park.sh" run "$@" </dev/null >/dev/null 2>&1 & )
}

# Publishes one outcome line for the next tick to report.
report_write() {  # <id> <line>
  local tmp
  tmp=$(mktemp "$STATE/.review-park.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" > "$tmp" && mv -f -- "$tmp" "$STATE/.review-park-report-$1-$(date +%s)-$$"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

agent_idle() {  # <id>
  local verdict
  verdict=$(fm_busy_classify_meta "$STATE/$1.meta" "$1" "$STATE" 2>/dev/null || true)
  case "$verdict" in idle\ *) return 0 ;; *) return 1 ;; esac
}

# An idle agent with no instruction waiting for it; prints the refusal and
# returns 1 otherwise.
agent_quiet() {  # <id>
  if find "$STATE/$1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | grep -q .; then
    echo "an instruction is waiting in the steering inbox"; return 1
  fi
  agent_idle "$1" || { echo "the agent is not idle ($(fm_busy_classify_meta "$STATE/$1.meta" "$1" "$STATE" 2>/dev/null || echo unknown))"; return 1; }
}

task_id_ok() { [ -n "$1" ] && fm_pr_task_id_valid "$1"; }

record_path() { printf '%s/%s.review-park' "$STATE" "$1"; }
record_get() { fm_meta_get "$(record_path "$1")" "$2"; }

record_write() {  # <id> <key=value>...
  local id=$1 tmp dest
  shift
  dest=$(record_path "$id")
  tmp=$(mktemp "$STATE/.review-park.XXXXXX") || return 1
  if ! { printf '%s\n' "$@" > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

status_append() {  # <id> <line>
  printf '%s\n' "$2" >> "$STATE/$1.status"
}

review_bots_json() {
  [ -f "$CONFIG/contribution-review-bots" ] || { printf '[]\n'; return 0; }
  jq -Rn '[inputs | gsub("^\\s+|\\s+$"; "") | select(length > 0 and (startswith("#") | not))]' \
    "$CONFIG/contribution-review-bots"
}

# --- forge snapshot ---------------------------------------------------------
# snapshot <pr-url> prints one normalized JSON object, the only input the gate
# and trigger programs read, so both providers share one decision procedure.

GITHUB_QUERY='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){
  state isDraft headRefOid baseRefName mergeable mergeStateStatus reviewDecision
  commits(last:1){nodes{commit{oid committedDate checkSuites(first:100){nodes{createdAt}} statusCheckRollup{state contexts(first:100){nodes{__typename ... on CheckRun{name completedAt} ... on StatusContext{context createdAt}}}}}}}
  reviewThreads(first:100){totalCount nodes{isResolved comments(last:100){nodes{author{login __typename} createdAt updatedAt}}}}
  reviews(last:100){nodes{author{login __typename} state body submittedAt updatedAt commit{oid}}}
  comments(last:100){nodes{author{login __typename} createdAt updatedAt}}
}}}'

GITHUB_NORMALIZE='
  .data.repository.pullRequest as $p
  | if ($p | type) != "object" then error("no pull request") else . end
  | ($p.commits.nodes[0].commit) as $c
  | if ($c.oid // "") != $p.headRefOid then error("head commit read is incoherent") else . end
  | ($c.statusCheckRollup) as $r
  | {
      provider: "github",
      state: ($p.state | ascii_downcase),
      draft: ($p.isDraft == true),
      head: $p.headRefOid,
      merge_status: ($p.mergeStateStatus // "UNKNOWN"),
      conflict: (if $p.mergeable == "CONFLICTING" or $p.mergeStateStatus == "DIRTY" then "conflict"
                 elif $p.mergeStateStatus == "BEHIND" then "behind"
                 elif $p.mergeable == "UNKNOWN" or $p.mergeStateStatus == "UNKNOWN" then "unknown"
                 else "none" end),
      blocked_other: (if ($p.mergeStateStatus // "UNKNOWN") | IN("CLEAN","BLOCKED","HAS_HOOKS","DIRTY","BEHIND","UNKNOWN","DRAFT","UNSTABLE")
                      then null else $p.mergeStateStatus end),
      ci: (if $r == null then "none" elif $r.state == "SUCCESS" then "success"
           elif ($r.state | IN("FAILURE","ERROR")) then "failure" else "pending" end),
      ci_done_at: ([$r.contexts.nodes[]? | (.completedAt // .createdAt)] | map(select(. != null)) | max),
      pushed_at: ([$c.checkSuites.nodes[]?.createdAt | select(. != null)] | min // $c.committedDate),
      changes_requested: ($p.reviewDecision == "CHANGES_REQUESTED"),
      threads_unresolved: ([$p.reviewThreads.nodes[] | select(.isResolved | not)] | length),
      threads_complete: ($p.reviewThreads.totalCount <= ($p.reviewThreads.nodes | length)),
      activity: (
        [$p.comments.nodes[] | {author: (.author.login // "ghost"), bot: (.author.__typename == "Bot"),
          at: .createdAt, touched: (.updatedAt // .createdAt), on_head: false, approval_only: false}]
        + [$p.reviews.nodes[] | {author: (.author.login // "ghost"), bot: (.author.__typename == "Bot"),
          at: .submittedAt, touched: (.updatedAt // .submittedAt), on_head: (.commit.oid == $p.headRefOid),
          approval_only: (.state == "APPROVED" and ((.body // "") | length) == 0)}]
        + [$p.reviewThreads.nodes[].comments.nodes[]? | {author: (.author.login // "ghost"), bot: (.author.__typename == "Bot"),
          at: .createdAt, touched: (.updatedAt // .createdAt), on_head: false, approval_only: false}]
        | map(select(.at != null)))
    }'

GITLAB_NORMALIZE='
  .[0] as $mr | .[1] as $d
  | if ($mr | type) != "object" or ($d | type) != "array" then error("invalid merge request read") else . end
  | ($mr.detailed_merge_status // "unchecked") as $s
  | ($mr.head_pipeline | if . != null and .sha == $mr.sha then . else null end) as $hp
  | ($hp.status // null) as $ps
  | {
      provider: "gitlab",
      state: (if $mr.state == "opened" then "open" else $mr.state end),
      draft: (($mr.draft // $mr.work_in_progress // false) == true),
      head: $mr.sha,
      merge_status: $s,
      conflict: (if $mr.has_conflicts == true or ($s | IN("conflict","broken_status")) then "conflict"
                 elif $s == "need_rebase" then "behind"
                 elif ($s | IN("checking","unchecked","preparing","approvals_syncing")) then "unknown"
                 else "none" end),
      blocked_other: (if $s | IN("mergeable","not_approved","conflict","broken_status","need_rebase","checking",
                                 "unchecked","preparing","approvals_syncing","requested_changes","draft_status",
                                 "ci_must_pass","ci_still_running","discussions_not_resolved","not_open")
                      then null else $s end),
      ci: (if $ps == null then "none" elif $ps == "success" then "success"
           elif ($ps | IN("failed","canceled")) then "failure" else "pending" end),
      ci_done_at: ($hp.finished_at // null),
      pushed_at: ($hp.created_at // null),
      changes_requested: ($s == "requested_changes"),
      threads_unresolved: ([$d[] | select(any(.notes[]?; .resolvable == true and .resolved != true))] | length),
      threads_complete: true,
      activity: [$d[] | .notes[]? | select(.system != true)
        | {author: (.author.username // "ghost"), bot: false, at: .created_at,
           touched: (.updated_at // .created_at), on_head: false, approval_only: false}]
    }'

# The required checks of the PR's base branch that have not reported on its
# head, as a JSON array, read with the same required-check reading
# bin/fm-pr-merge.sh does; fails when any requirement cannot be read.
github_required_unreported() {  # <graphql-json>
  local raw=$1 base head rollup secs missing
  base=$(printf '%s' "$raw" | jq -er '.data.repository.pullRequest.baseRefName | select(type == "string" and length > 0)') || return 1
  head=$(printf '%s' "$raw" | jq -r '.data.repository.pullRequest.headRefOid')
  rollup=$(printf '%s' "$raw" | jq -c '{statusCheckRollup: (.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])}') || return 1
  secs=$(step_secs "$READ_SECS") || return 1
  # shellcheck disable=SC2016
  missing=$(fm_run_timed "$secs" bash -c '
    . "$1/fm-pr-lib.sh"
    PR_OWNER=$2 PR_REPO=$3
    github_read_required_contexts "$4" && github_read_required_producers "$5" \
      && github_required_checks_missing "$6" "$FM_PR_GITHUB_REQUIRED" "$FM_PR_GITHUB_PRODUCERS"' \
    _ "$SCRIPT_DIR" "$FM_PR_OWNER" "$FM_PR_REPO" "$base" "$head" "$rollup" 2>/dev/null) || return 1
  printf '%s' "$missing" | jq -Rsc 'split("\n") | map(select(length > 0))'
}

# snapshot <pr-url> [--required]: --required adds required_missing, the GitHub
# required checks not yet reported on the head (null when unreadable), which
# only the gate reads.
snapshot() {  # <pr-url> [--required]
  local url=$1 raw mr discussions enc secs snap missing
  fm_pr_url_parse "$url" || return 1
  case "$FM_PR_PROVIDER" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      fm_pr_github_host_export "$FM_PR_HOST"
      secs=$(step_secs "$READ_SECS") || return 1
      raw=$(fm_run_timed "$secs" gh api graphql -f query="$GITHUB_QUERY" \
        -F "owner=${FM_PR_PATH%%/*}" -F "repo=${FM_PR_PATH#*/}" -F "number=$FM_PR_NUMBER" 2>/dev/null) || return 1
      snap=$(printf '%s' "$raw" | jq -c "$GITHUB_NORMALIZE" 2>/dev/null) || return 1
      [ "${2-}" = --required ] || { printf '%s\n' "$snap"; return 0; }
      missing=$(github_required_unreported "$raw") || missing=null
      printf '%s' "$snap" | jq -c --argjson m "$missing" '. + {required_missing: $m}'
      ;;
    gitlab)
      command -v glab >/dev/null 2>&1 || return 1
      enc=$(jq -rn --arg p "$FM_PR_PATH" '$p | @uri')
      secs=$(step_secs "$READ_SECS") || return 1
      mr=$(fm_run_timed "$secs" glab api --hostname "$FM_PR_HOST" \
        "projects/$enc/merge_requests/$FM_PR_NUMBER" 2>/dev/null) || return 1
      secs=$(step_secs "$READ_SECS") || return 1
      discussions=$(fm_run_timed "$secs" glab api --paginate --hostname "$FM_PR_HOST" \
        "projects/$enc/merge_requests/$FM_PR_NUMBER/discussions?per_page=100" 2>/dev/null) || return 1
      [ -n "$discussions" ] || return 1
      # --paginate prints one JSON array per page; together they are one list.
      discussions=$(printf '%s\n' "$discussions" \
        | jq -cs '[.[] | if type == "array" then .[] else error("invalid discussions page") end]' 2>/dev/null) || return 1
      printf '%s\n%s\n' "$mr" "$discussions" | jq -cs "$GITLAB_NORMALIZE" 2>/dev/null
      ;;
    *) return 1 ;;
  esac
}

JQ_TIME='def ts: if . == null then null else (try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null) end;'

GATE_PROGRAM="$JQ_TIME"'
  def isbot: .bot or (.author | test("\\[bot\\]$")) or (.author | test("^(group|project)_[0-9]+_bot_"))
    or (.author as $a | any($bots[]; . == $a));
  . as $s
  | ($s.pushed_at | ts) as $pushed
  | ([($s.ci_done_at | ts), $pushed] | map(select(. != null)) | max) as $anchor
  | ([$s.activity[] | select(isbot) | .author] | unique) as $seen
  | (if $anchor == null then null else ($anchor + $quiet - $now) end) as $left
  | ($anchor != null and ($left <= 0 or (($seen | length) > 0
       and all($seen[]; . as $b | any($s.activity[]; .author == $b and .on_head))))) as $settled
  | [
      (if $s.state != "open" then "the PR is \($s.state)" else empty end),
      (if $s.draft then "the PR is a draft" else empty end),
      (if $expect != "" and $s.head != $expect then "the head moved from \($expect[0:12]) to \($s.head[0:12])" else empty end),
      (if $s.conflict == "conflict" then "the PR has merge conflicts"
       elif $s.conflict == "behind" then "the branch is behind its base"
       elif $s.conflict == "unknown" then "mergeability is not computed yet (\($s.merge_status))" else empty end),
      (if $s.blocked_other != null then "the forge reports merge status \($s.blocked_other)" else empty end),
      (if $s.ci != "success" then "CI is \($s.ci) on head \($s.head[0:12])" else empty end),
      (if ($s | has("required_missing") | not) then empty
       elif $s.required_missing == null then "the required checks of the base branch could not be read"
       elif ($s.required_missing | length) > 0 then "required check(s) \($s.required_missing | join(", ")) have not reported on head \($s.head[0:12])"
       else empty end),
      (if $s.changes_requested then "changes are requested" else empty end),
      (if $s.threads_unresolved > 0 then "\($s.threads_unresolved) review thread(s) unresolved" else empty end),
      (if ($s.threads_complete | not) then "review threads could not all be read" else empty end),
      (if $settled or $s.ci != "success" then empty
       elif ($seen | length) > 0 then "automated reviewers (\($seen | join(", "))) have not submitted a review of this head; quiet window \($left)s left"
       else "no automated reviewer has submitted a review of this head; quiet window \($left)s left" end)
    ]
  | {clean: (length == 0), head: $s.head, reasons: .}'

TRIGGER_PROGRAM="$JQ_TIME"'
  . as $s
  | {
      state: $s.state,
      triggers: [
        (if $s.head != $head then "the head moved to \($s.head[0:12])" else empty end),
        (if $s.ci == "failure" then "checks are failing on \($s.head[0:12])" else empty end),
        (if $s.changes_requested then "changes were requested" else empty end),
        (if $s.conflict == "conflict" then "the PR has merge conflicts" else empty end),
        (if $s.threads_unresolved > 0 then "\($s.threads_unresolved) review thread(s) unresolved" else empty end),
        ([$s.activity[] | select(([.at, .touched] | map(ts // 0) | max) > $parked and (.approval_only | not)) | .author] | unique
         | if length > 0 then "new comments from \(join(", "))" else empty end)
      ]
    }'

# gate_eval <id> <expect-head> prints the gate result JSON; returns 1 when the
# forge cannot be read.
gate_eval() {  # <id> <expect-head>
  local id=$1 expect=$2 pr snap bots
  pr=$(fm_meta_get "$STATE/$id.meta" pr)
  [ -n "$pr" ] || return 1
  snap=$(snapshot "$pr" --required) || return 1
  [ -n "$snap" ] || return 1
  bots=$(review_bots_json) || return 1
  printf '%s' "$snap" | jq -c --argjson now "$(date +%s)" --argjson quiet "$QUIET_SECS" \
    --arg expect "$expect" --argjson bots "$bots" "$GATE_PROGRAM"
}

gate_print() {  # <gate-json>; returns 0 clean, 3 unclean
  if [ "$(printf '%s' "$1" | jq -r .clean)" = true ]; then
    printf 'clean head=%s\n' "$(printf '%s' "$1" | jq -r .head)"
    return 0
  fi
  printf '%s' "$1" | jq -r '.reasons[] | "unclean: " + .'
  return 3
}

cmd_gate() {
  local id=${1-} expect='' result
  task_id_ok "$id" || die "usage: fm-park.sh gate <task-id> [--expect-head <sha>]" 2
  shift
  if [ "${1-}" = --expect-head ]; then
    expect=${2-}
    fm_pr_head_valid "$expect" || die "--expect-head needs a full commit sha" 2
  fi
  [ -f "$STATE/$id.meta" ] || die "no task record for $id"
  result=$(gate_eval "$id" "$expect") || die "could not read the PR for $id from its forge"
  gate_print "$result"
}

# --- park ------------------------------------------------------------------

# Local preconditions that make a park reversible: an armed merge poll, a clean
# copy at the forge head, a worker that finished its turn and reported, and no
# instruction waiting for it. Prints the first refusal and returns 1.
park_preflight() {  # <id>
  local id=$1 meta kind pr wt crew secs
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || { echo "no task record"; return 1; }
  kind=$(fm_meta_get "$meta" kind)
  [ "${kind:-ship}" = ship ] || { echo "only a ship lane can park (kind=$kind)"; return 1; }
  pr=$(fm_meta_get "$meta" pr)
  [ -n "$pr" ] || { echo "no PR is recorded (pr=)"; return 1; }
  if ! fm_pr_url_parse "$pr" || { [ "$FM_PR_PROVIDER" != github ] && [ "$FM_PR_PROVIDER" != gitlab ]; }; then
    echo "parking supports GitHub pull requests and GitLab merge requests only"; return 1
  fi
  [ -f "$STATE/$id.check.sh" ] || { echo "no merge poll is armed (run bin/fm-pr-check.sh first)"; return 1; }
  [ ! -e "$(record_path "$id")" ] || { echo "already parked"; return 1; }
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || { echo "the local copy is missing"; return 1; }
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || { echo "the local copy has uncommitted changes"; return 1; }
  agent_quiet "$id" || return 1
  secs=$(step_secs 60) || { echo "the tick ran out of time"; return 1; }
  crew=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE fm_run_timed "$secs" "$CREW_STATE_BIN" "$id" 2>/dev/null | head -1 || true)
  case "$crew" in
    'state: done '*|'state: paused '*) ;;
    *) echo "the worker has not finished at a ready report (${crew:-crew state unreadable})"; return 1 ;;
  esac
}

# Durable Treehouse lease for a pool slot; prints yes when taken, no when the
# copy is not a Treehouse slot, and fails when a slot cannot be leased.
slot_lease() {  # <id>
  local id=$1 meta project wt slot_dir pool slot leased holder secs
  local -a root=()
  meta="$STATE/$id.meta"
  project=$(fm_meta_get "$meta" project)
  wt=$(fm_meta_get "$meta" worktree)
  if [ -z "$project" ] || ! fm_treehouse_pool_slot "$project" "$wt"; then
    printf 'no\n'
    return 0
  fi
  # treehouse lease names a slot, resolved against the pool of the repository
  # it runs in, so a pool under a non-default root (<root>/.treehouse/<pool>)
  # is addressed through that root; the printed path is verified either way.
  slot_dir=$(dirname "$(CDPATH='' cd -- "$wt" && pwd -P)")
  slot=$(basename "$slot_dir")
  pool=$(dirname "$slot_dir")
  [ "$(basename "$(dirname "$pool")")" != .treehouse ] || root=(--root "$(dirname "$(dirname "$pool")")")
  # A lane parked before and relaunched since still holds its lease, which
  # treehouse lease refuses to take again, so this task's own lease counts.
  secs=$(step_secs 60) || return 1
  holder=$( (cd "$project" && fm_run_timed "$secs" treehouse status --json "${root[@]}") 2>/dev/null \
    | jq -r --arg p "$(CDPATH='' cd -- "$wt" && pwd -P)" \
      '[.[] | select(.status == "leased" and .path == $p) | .lease_holder] | first // empty' 2>/dev/null) || holder=
  if [ "$holder" = "$id" ]; then
    printf 'yes\n'
    return 0
  fi
  secs=$(step_secs 60) || return 1
  leased=$( (cd "$project" && fm_run_timed "$secs" treehouse lease "$slot" --lease-holder "$id" "${root[@]}") 2>/dev/null) || return 1
  [ "$(CDPATH='' cd -- "$leased" 2>/dev/null && pwd -P)" = "$(CDPATH='' cd -- "$wt" && pwd -P)" ] || return 1
  printf 'yes\n'
}

cmd_park() {
  local id=${1-} why result head local_head pr lease parked_at out rc=0 line
  task_id_ok "$id" || die "usage: fm-park.sh park <task-id>" 2
  lock_try "$(lane_lock "$id")" || die "another park action holds $id"
  why=$(park_preflight "$id") || die "refusing to park $id: $why"
  result=$(gate_eval "$id" "") || die "refusing to park $id: its PR could not be read from the forge"
  if ! gate_print "$result" > "$PARK_TMP/gate" ; then
    die "refusing to park $id: $(sed 's/^unclean: //' "$PARK_TMP/gate" | paste -sd ';' - | sed 's/;/; /g')" 3
  fi
  head=$(printf '%s' "$result" | jq -r .head)
  local_head=$(git -C "$(fm_meta_get "$STATE/$id.meta" worktree)" rev-parse HEAD 2>/dev/null || true)
  [ "$local_head" = "$head" ] || die "refusing to park $id: the local copy is at ${local_head:0:12}, the PR head is ${head:0:12}"
  pr=$(fm_meta_get "$STATE/$id.meta" pr)
  lease=$(slot_lease "$id") || die "refusing to park $id: its pool slot could not be leased durably"
  # Review activity after this moment relaunches the lane once it is parked.
  parked_at=$(date +%s)
  # The verdict above is already history: read the forge once more, bound to
  # the head just verified, immediately before anything is stopped.
  if ! result=$(gate_eval "$id" "$head") || ! gate_print "$result" > "$PARK_TMP/gate"; then
    die "refusing to park $id: the re-check before stopping was not clean ($(sed 's/^unclean: //' "$PARK_TMP/gate" 2>/dev/null | paste -sd ';' - | sed 's/;/; /g'))" 3
  fi
  if ! why=$(agent_quiet "$id"); then
    die "refusing to park $id: $why"
  fi
  # Written before the stop and marked pending, so a park that dies after the
  # stop still leaves the lane watched; the next tick settles a pending record.
  record_write "$id" "pr=$pr" "head=$head" "parked_at=$parked_at" "slot_leased=$lease" "pending=1" \
    || die "refusing to park $id: its park record could not be written"
  out=$(FM_HOME=$FM_HOME fm_run_timed "$ACTION_SECS" "$CONTROL_BIN" "$id" exit 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "refusing to park $id: the agent could not be stopped: $(printf '%s\n' "$out" | tail -1); the next tick settles its pending park record"
  fi
  record_write "$id" "pr=$pr" "head=$head" "parked_at=$parked_at" "slot_leased=$lease" \
    || die "$id: the agent was stopped but its park record could not be marked parked; the next tick settles it"
  line="paused [at=$(date +%s)]: parked on review: PR $pr clean at ${head:0:12}; agent stopped, relaunches on review activity"
  status_append "$id" "$line"
  fm_parent_channel_report "$FM_HOME" "$STATE" "$line" >/dev/null 2>&1 || true
  printf 'parked %s: PR %s clean at %s; agent stopped\n' "$id" "$pr" "${head:0:12}"
}

# --- resume ----------------------------------------------------------------

cmd_resume() {
  local id=${1-} trigger pr head note out rc=0 rec
  task_id_ok "$id" || die "usage: fm-park.sh resume <task-id> --trigger <text>" 2
  shift
  [ "${1-}" = --trigger ] && [ -n "${2-}" ] || die "usage: fm-park.sh resume <task-id> --trigger <text>" 2
  trigger=$2
  rec=$(record_path "$id")
  [ -f "$rec" ] || die "$id is not parked"
  lock_try "$(lane_lock "$id")" || die "another park action holds $id"
  pr=$(record_get "$id" pr)
  head=$(record_get "$id" head)
  note="$PARK_TMP/note"
  {
    printf 'This lane was parked on review: PR %s was clean and ready to merge at head %s, so its previous agent was stopped.\n' "$pr" "$head"
    printf 'You are a fresh agent relaunched in the same local copy on the same branch because: %s.\n' "$trigger"
    printf 'Read the PR and its new review activity, address it on this branch, then report again exactly as your instructions define done.\n'
  } > "$note"
  # Written before the launch, so the fresh worker's own reports always follow
  # it; while the record stays, crew state still reads the record, not this.
  status_append "$id" "working [at=$(date +%s)]: relaunched from review park: $trigger"
  out=$(FM_HOME=$FM_HOME fm_run_timed "$ACTION_SECS" "$CONTROL_BIN" "$id" relaunch --note-file "$note" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    record_write "$id" "pr=$pr" "head=$head" "parked_at=$(record_get "$id" parked_at)" \
      "slot_leased=$(record_get "$id" slot_leased)" "resume_error=$(date +%s)" || true
    printf 'relaunch-failed %s: PR %s (%s): %s\n' "$id" "$pr" "$trigger" "$(printf '%s\n' "$out" | tail -1)"
    return 1
  fi
  rm -f -- "$rec"
  printf 'relaunched %s: PR %s - %s\n' "$id" "$pr" "$trigger"
}

# --- land ------------------------------------------------------------------

# Parked lanes always clean up; other lanes require explicit home opt-in.
land_eligible() {  # <id>
  [ -e "$(record_path "$1")" ] || [ -e "$CONFIG/auto-land" ]
}

cmd_land() {
  local id=${1-} eligible=0 detach=0 queue=0 pr out rc=0 why
  task_id_ok "$id" || die "usage: fm-park.sh land <task-id> [--if-eligible] [--detach] [--queue]" 2
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --if-eligible) eligible=1 ;;
      --detach) detach=1 ;;
      --queue) queue=1 ;;
      *) die "usage: fm-park.sh land <task-id> [--if-eligible] [--detach] [--queue]" 2 ;;
    esac
    shift
  done
  [ "$eligible" = 0 ] || land_eligible "$id" || return 0
  [ -f "$STATE/$id.meta" ] || return 0
  if [ "$queue" = 1 ] || [ "$detach" = 1 ]; then
    printf 'pr=%s\n' "$(fm_meta_get "$STATE/$id.meta" pr)" > "$STATE/$id.review-park-land"
    [ "$detach" = 1 ] || return 0
    action_start "$id" land
    printf 'automatic cleanup started\n'
    return 0
  fi
  pr=$(fm_meta_get "$STATE/$id.meta" pr)
  # A park or relaunch under way finishes first; each is bounded by the same
  # backstop, so this wait is too.
  if ! fm_lock_acquire_wait_max "$(lane_lock "$id")" "$ACTION_SECS"; then
    printf 'cleanup-refused %s: PR %s merged; another park action still holds the lane\n' "$id" "$pr"
    return 1
  fi
  LOCKS_HELD="$LOCKS_HELD $(lane_lock "$id")"
  [ -f "$STATE/$id.meta" ] || return 0
  pr=$(fm_meta_get "$STATE/$id.meta" pr)
  if [ -e "$STATE/$id.review-park-land" ] \
    && [ "$(fm_meta_get "$STATE/$id.review-park-land" pr)" != "$pr" ]; then
    rm -f -- "$STATE/$id.review-park-land"
    return 0
  fi
  out=$(FM_HOME=$FM_HOME fm_run_timed "$ACTION_SECS" "$TEARDOWN_BIN" "$id" 2>&1) || rc=$?
  case "$rc" in
    0) printf 'cleaned up %s: PR %s merged; lane torn down and its working copy returned\n' "$id" "$pr" ;;
    4) printf 'cleaned up %s: PR %s merged; lane torn down, but its returned pool slot was lost (see teardown output)\n' "$id" "$pr" ;;
    *)
      why=$(printf '%s\n' "$out" | grep -m1 -E 'REFUSED|^error|refus' || printf '%s\n' "$out" | tail -1)
      printf 'cleanup-refused %s: PR %s merged; automatic cleanup refused: %s\n' "$id" "$pr" "$why"
      return 1
      ;;
  esac
}

# --- detached action -------------------------------------------------------

cmd_run() {
  local id=${1-} verb=${2-} out
  task_id_ok "$id" || die "usage: fm-park.sh run <task-id> park|resume|land [<args>...]" 2
  case "$verb" in park|resume|land) ;; *) die "usage: fm-park.sh run <task-id> park|resume|land [<args>...]" 2 ;; esac
  shift 2
  out=$( LOCKS_HELD=; trap release_locks EXIT; "cmd_$verb" "$id" "$@" 2>/dev/null ) || true
  if [ -n "$out" ]; then
    case "$out" in *"another lifecycle action is already running"*|*"another park action still holds"*) return 0 ;; esac
    report_write "$id" "$out"
    [ "$verb" != land ] || rm -f -- "$STATE/$id.review-park-land"
  elif [ "$verb" = land ] && [ ! -e "$STATE/$id.meta" ]; then
    rm -f -- "$STATE/$id.review-park-land"
  fi
}

# --- tick ------------------------------------------------------------------

# Prints a close once; the tick writes the marker after recording the wake.
closed_once() {  # <id> <pr>
  [ ! -e "$STATE/.review-park-closed-$1" ] || return 0
  printf 'closed %s: PR %s was closed without merging; the lane needs a decision\n' "$1" "$2"
}

watch_parked() {  # <id>
  local id=$1 pr head parked snap result state triggers
  ! lane_busy "$id" || return 0
  if [ -n "$(record_get "$id" pending)" ]; then
    ( LOCKS_HELD=; trap release_locks EXIT; settle_pending "$id" ) || true
    [ -e "$(record_path "$id")" ] || return 0
  fi
  [ -z "$(record_get "$id" resume_error)" ] || return 0
  pr=$(record_get "$id" pr)
  head=$(record_get "$id" head)
  parked=$(record_get "$id" parked_at)
  case "$parked" in ''|*[!0-9]*) return 0 ;; esac
  snap=$(snapshot "$pr") || return 0
  result=$(printf '%s' "$snap" | jq -c --arg head "$head" --argjson parked "$parked" "$TRIGGER_PROGRAM") || return 0
  state=$(printf '%s' "$result" | jq -r .state)
  case "$state" in
    merged) return 0 ;;
    closed) closed_once "$id" "$pr"; return 0 ;;
  esac
  triggers=$(printf '%s' "$result" | jq -r '.triggers | join("; ")')
  [ -n "$triggers" ] || return 0
  action_start "$id" resume --trigger "$triggers"
}

watch_unparked() {  # <id>
  local id=$1 meta pr snap state result
  meta="$STATE/$id.meta"
  [ "$(fm_meta_get "$meta" kind)" != secondmate ] || return 0
  pr=$(fm_meta_get "$meta" pr)
  [ -n "$pr" ] && [ -f "$STATE/$id.check.sh" ] || return 0
  [ ! -e "$(record_path "$id")" ] || return 0
  ! lane_busy "$id" || return 0
  local idle_secs
  idle_secs=$(step_secs "$READ_SECS") || return 0
  fm_run_timed "$idle_secs" "$SCRIPT_DIR/fm-park.sh" idle-check "$id" >/dev/null 2>&1 || return 0
  snap=$(snapshot "$pr") || return 0
  state=$(printf '%s' "$snap" | jq -r .state)
  [ "$state" != closed ] || { closed_once "$id" "$pr"; return 0; }
  [ "$state" = open ] && [ -e "$CONFIG/park-on-review" ] || return 0
  result=$(printf '%s' "$snap" | jq -c --argjson now "$(date +%s)" --argjson quiet "$QUIET_SECS" \
    --arg expect "" --argjson bots "$(review_bots_json)" "$GATE_PROGRAM") || return 0
  [ "$(printf '%s' "$result" | jq -r .clean)" = true ] || return 0
  action_start "$id" park
}

# A pending record is a park that did not confirm its stop. Once its agent is
# confirmed dead it is promoted to parked; while the agent is still alive the
# park did not happen and the record is dropped; otherwise (including a check
# that outlasts its bound) it stays pending.
settle_pending() {  # <id>
  local id=$1 meta secs alive
  lock_try "$(lane_lock "$id")" || return 0
  [ -n "$(record_get "$id" pending)" ] || return 0
  meta="$STATE/$id.meta"
  secs=$(step_secs "$READ_SECS") || return 0
  # shellcheck disable=SC2016  # The inner script expands after bash -c receives positional args.
  alive=$(fm_run_timed "$secs" bash -c '. "$1"; fm_backend_agent_alive "$2" "$3"' _ \
    "$SCRIPT_DIR/fm-backend.sh" "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")" 2>/dev/null) || true
  case "$alive" in
    dead)
      record_write "$id" "pr=$(record_get "$id" pr)" "head=$(record_get "$id" head)" \
        "parked_at=$(record_get "$id" parked_at)" "slot_leased=$(record_get "$id" slot_leased)" ;;
    alive) rm -f -- "$(record_path "$id")" ;;
  esac
}

# visit_lanes <cursor> <visit> <id>... runs <visit> on each lane, starting at
# the lane saved in <cursor> and wrapping around. When the tick runs out of time
# it saves the next lane there, so a slow early lane cannot starve later ones.
visit_lanes() {  # <cursor> <visit> <id>...
  local cursor=$1 visit=$2 start id
  local -a first=() rest=()
  shift 2
  start=$(cat "$cursor" 2>/dev/null || true)
  for id in "$@"; do
    if [[ "$id" < "$start" ]]; then rest+=("$id"); else first+=("$id"); fi
  done
  for id in ${first[@]+"${first[@]}"} ${rest[@]+"${rest[@]}"}; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
      printf '%s\n' "$id" > "$cursor"
      return 1
    fi
    "$visit" "$id"
  done
  rm -f -- "$cursor"
}

cmd_tick() {
  local rec id meta any=0
  local -a parked=() unparked=()
  for rec in "$STATE"/*.review-park "$STATE"/*.review-park-land "$STATE"/.review-park-report-*; do [ -e "$rec" ] && any=1 && break; done
  [ "$any" = 1 ] || [ -e "$CONFIG/park-on-review" ] || [ -e "$CONFIG/auto-land" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  lock_try "$STATE/.review-park-tick.lock" || return 0
  DEADLINE=$(( $(date +%s) + TICK_SECS ))
  local lines='' line
  local -a reports=()
  for rec in "$STATE"/.review-park-report-*; do
    [ -f "$rec" ] || continue
    reports+=("$rec")
    lines+=$(cat -- "$rec")$'\n'
  done
  for rec in "$STATE"/*.review-park-land; do
    [ -e "$rec" ] || continue
    id=$(basename "$rec" .review-park-land)
    fm_pr_task_id_valid "$id" && [ -f "$STATE/$id.meta" ] || { rm -f -- "$rec"; continue; }
    lane_busy "$id" || action_start "$id" land
  done
  for rec in "$STATE"/*.review-park; do
    [ -e "$rec" ] || continue
    id=$(basename "$rec" .review-park)
    fm_pr_task_id_valid "$id" && [ -f "$STATE/$id.meta" ] || continue
    parked+=("$id")
  done
  # Reserve half the tick for unparked lanes; parked forge reads cannot starve them.
  local full_deadline=$DEADLINE
  DEADLINE=$(( $(date +%s) + (TICK_SECS + 1) / 2 ))
  lines+=$(visit_lanes "$STATE/.review-park-tick-next" watch_parked ${parked[@]+"${parked[@]}"})$'\n' || true
  DEADLINE=$full_deadline
  if [ -e "$CONFIG/park-on-review" ] || [ -e "$CONFIG/auto-land" ]; then
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || continue
      id=$(basename "$meta" .meta)
      fm_pr_task_id_valid "$id" || continue
      unparked+=("$id")
    done
    lines+=$(visit_lanes "$STATE/.review-park-tick-next-unparked" watch_unparked ${unparked[@]+"${unparked[@]}"})$'\n' || true
  fi
  lines=$(printf '%s' "$lines" | grep -v '^$') || return 0
  fm_wake_append check park-on-review "check: park-on-review: $(printf '%s\n' "$lines" | paste -sd ';' - | sed 's/;/; /g')" || return 0
  rm -f -- ${reports[@]+"${reports[@]}"}
  while IFS= read -r line; do
    case "$line" in "closed "*:*) line=${line#closed }; : > "$STATE/.review-park-closed-${line%%:*}" ;; esac
  done <<< "$lines"
  printf '%s\n' "$lines"
}

cmd_list() {
  local rec id
  for rec in "$STATE"/*.review-park; do
    [ -e "$rec" ] || continue
    id=$(basename "$rec" .review-park)
    printf '%s\tPR %s\thead %s\tparked %s%s\n' "$id" "$(record_get "$id" pr)" \
      "$(record_get "$id" head | cut -c1-12)" \
      "$(date -u -r "$(record_get "$id" parked_at)" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$(record_get "$id" parked_at)" +%Y-%m-%dT%H:%MZ 2>/dev/null || record_get "$id" parked_at)" \
      "$([ -z "$(record_get "$id" pending)" ] || printf '\tparking; stop not yet confirmed')$([ -z "$(record_get "$id" resume_error)" ] || printf '\trelaunch failed; run fm-park.sh resume by hand')"
  done
}

case "${1:-}" in
  idle-check) shift; agent_idle "${1:?}" ;;
  -h|--help) usage ;;
  gate) shift; cmd_gate "$@" ;;
  park) shift; cmd_park "$@" ;;
  resume) shift; cmd_resume "$@" ;;
  land) shift; cmd_land "$@" ;;
  tick) cmd_tick ;;
  list) cmd_list ;;
  run) shift; cmd_run "$@" ;;
  *) usage >&2; exit 2 ;;
esac
