#!/usr/bin/env bash
# Tests for bin/fm-park.sh: the parked-on-review gate, park transition,
# working-copy protection, relaunch triggers, merge-time cleanup, and the
# watcher-facing tick.
#
# The forges are faked through gh and glab stubs that serve recorded JSON, and
# the lifecycle owners (bin/fm-control.sh, bin/fm-teardown.sh,
# bin/fm-crew-state.sh) through the script's documented FM_PARK_*_BIN
# overrides, so each case drives the real decision procedure end to end and
# asserts what it did to the lane: its record, its status log, and the exact
# lifecycle calls it made.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PARK="$ROOT/bin/fm-park.sh"
TMP_ROOT=$(fm_test_tmproot fm-park-tests)
GH_URL=https://github.com/example/repo/pull/7
GL_URL=https://gitlab.example.com/team/sub/repo/-/merge_requests/7
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OLD_ISO=2026-01-01T00:00:00Z

# A home with one ship lane: a project, a Treehouse-shaped pool slot holding
# the lane's copy at a pushed head, an idle Claude busy record, an armed merge
# poll, and stubs for every external tool. Echoes the world dir; the copy's
# HEAD is in $WORLD/head.
make_world() {
  local name=$1 url=$2 world fakebin wt head
  world="$TMP_ROOT/$name"
  fakebin="$world/fakebin"
  mkdir -p "$world/state" "$world/config" "$fakebin" "$world/root/.treehouse/repo-1/3"
  git init -q -b main "$world/project"
  git -C "$world/project" commit -q --allow-empty -m base
  printf '{}\n' > "$world/root/.treehouse/repo-1/treehouse-state.json"
  wt="$world/root/.treehouse/repo-1/3/repo"
  git -C "$world/project" worktree add -q -b fm/lane "$wt" main
  printf 'work\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -q -m work
  head=$(git -C "$wt" rev-parse HEAD)
  printf '%s\n' "$head" > "$world/head"
  fm_write_meta "$world/state/lane.meta" \
    "window=fm:fm-lane" "endpoint_task_id=lane" "worktree=$wt" \
    "project=$world/project" "kind=ship" "mode=no-mistakes" "harness=claude" \
    "branch=fm/lane" "pr=$url"
  printf 'gen1\n' > "$world/state/lane.busy-gen"
  printf 'v1 gen=gen1 seq=3 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" \
    > "$world/state/lane.busy-state"
  printf '#!/bin/sh\nexit 0\n' > "$world/state/lane.check.sh"
  printf 'done [at=1]: PR %s checks green\n' "$url" > "$world/state/lane.status"

  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
# The base branch's required checks: gh.branch.json (unprotected by default,
# gh.branch.fail fails the read), with no rulesets.
case "\$*" in
  *"/rules/branches/"*) echo '[]'; exit 0 ;;
  *"/branches/"*) [ ! -e "$world/gh.branch.fail" ] || exit 1; cat "$world/gh.branch.json" 2>/dev/null || echo '{"protected":false}'; exit 0 ;;
esac
# Serves gh.<n>.json for the n-th GraphQL read, repeating the last one.
n=\$(( \$(cat "$world/gh.count" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" > "$world/gh.count"
[ ! -f "$world/gh.\$n.sh" ] || sh "$world/gh.\$n.sh"
f="$world/gh.\$n.json"
[ -f "\$f" ] || f=\$(ls "$world"/gh.*.json | sort -t. -k2 -n | tail -1)
cat "\$f"
SH
  cat > "$fakebin/glab" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$world/glab.log"
case "\$*" in
  *"/discussions"*)
    cat "$world/gl.discussions.json"
    case "\$*" in *--paginate*) [ ! -f "$world/gl.discussions.2.json" ] || cat "$world/gl.discussions.2.json" ;; esac
    ;;
  *) cat "$world/gl.mr.json" ;;
esac
SH
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$world/treehouse.log"
if [ "\${1:-} \${2:-}" = "status --json" ]; then cat "$world/treehouse.status.json" 2>/dev/null || echo '[]'; exit 0; fi
[ "\${1:-}" = lease ] || exit 1
[ ! -e "$world/treehouse.fail" ] || exit 1
printf '%s\n' "$wt"
SH
  cat > "$fakebin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$world/control.log"
if [ "\${2:-}" = relaunch ] && [ "\${3:-}" = --note-file ]; then cat "\$4" >> "$world/control.log"; fi
[ ! -e "$world/control.fail" ] || { echo "error: control refused"; exit 1; }
SH
  cat > "$fakebin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$world/teardown.log"
if [ -e "$world/teardown.refuse" ]; then echo "REFUSED: worktree has work not on any remote and not landed." >&2; exit 1; fi
echo "Torn down \$1"
SH
  # The lane's tmux window: no server by default (the agent is dead), and a
  # live claude in the foreground while $world/agent.alive exists.
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
[ ! -e "$world/tmux.hang" ] || sleep 30
[ -e "$world/agent.alive" ] || { echo "no server running on /tmp/tmux-fake/default" >&2; exit 1; }
case "\$1" in
  list-windows) echo fm-lane ;;
  display-message) echo /dev/ttysfake ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/ps" <<SH
#!/usr/bin/env bash
case " \$* " in *" -t ttysfake "*) echo "1 1 1 claude"; exit 0 ;; esac
exec /bin/ps "\$@"
SH
  cat > "$fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
cat "$world/crew-state" 2>/dev/null || echo 'state: done · source: status-log · PR ready'
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$world"
}

run_park() {  # <world> <args...>
  local world=$1
  shift
  FM_HOME="$world" FM_STATE_OVERRIDE="$world/state" FM_CONFIG_OVERRIDE="$world/config" \
    FM_PARK_CONTROL_BIN="$world/fakebin/fm-control.sh" \
    FM_PARK_TEARDOWN_BIN="$world/fakebin/fm-teardown.sh" \
    FM_PARK_CREW_STATE_BIN="$world/fakebin/fm-crew-state.sh" \
    FM_PARK_QUIET_SECS="${FM_TEST_QUIET:-900}" \
    PATH="$world/fakebin:$PATH" "$PARK" "$@"
}

# GitHub GraphQL fixture. Fields default to a clean PR whose only reviewer bot
# reviewed the current head; key=value arguments override them. The head's one
# check suite was created at pushed= (default: the committer time; none: no
# check suite).
gh_fixture() {  # <out> [key=value...]
  local out=$1 kv
  shift
  local state=OPEN draft=false head mergeable=MERGEABLE mss=BLOCKED decision=REVIEW_REQUIRED
  local rollup='"SUCCESS"' completed=$OLD_ISO committed=$OLD_ISO threads='[]' total=0
  local review_oid bot_at=$OLD_ISO comments='[]' extra_reviews='' pushed=''
  head=$(cat "$(dirname "$out")/head")
  review_oid=$head
  for kv in "$@"; do
    case "$kv" in
      state=*) state=${kv#*=} ;; draft=*) draft=${kv#*=} ;; head=*) head=${kv#*=} ;;
      mergeable=*) mergeable=${kv#*=} ;; mss=*) mss=${kv#*=} ;; decision=*) decision=${kv#*=} ;;
      rollup=*) rollup=${kv#*=} ;; completed=*) completed=${kv#*=} ;; committed=*) committed=${kv#*=} ;;
      threads=*) threads=${kv#*=} ;; total=*) total=${kv#*=} ;; review_oid=*) review_oid=${kv#*=} ;;
      bot_at=*) bot_at=${kv#*=} ;; comments=*) comments=${kv#*=} ;; extra_reviews=*) extra_reviews=${kv#*=} ;;
      pushed=*) pushed=${kv#*=} ;;
    esac
  done
  local suites="[{\"createdAt\":\"${pushed:-$committed}\"}]"
  [ "$pushed" != none ] || suites='[]'
  local rollup_obj=null
  [ "$rollup" = null ] || rollup_obj="{\"state\":$rollup,\"contexts\":{\"nodes\":[{\"__typename\":\"CheckRun\",\"name\":\"ci\",\"completedAt\":\"$completed\"}]}}"
  cat > "$out" <<JSON
{"data":{"repository":{"pullRequest":{
  "state":"$state","isDraft":$draft,"headRefOid":"$head","baseRefName":"main","mergeable":"$mergeable",
  "mergeStateStatus":"$mss","reviewDecision":"$decision",
  "commits":{"nodes":[{"commit":{"oid":"$head","committedDate":"$committed","checkSuites":{"nodes":$suites},"statusCheckRollup":$rollup_obj}}]},
  "reviewThreads":{"totalCount":$total,"nodes":$threads},
  "reviews":{"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"state":"COMMENTED","body":"lgtm",
    "submittedAt":"$bot_at","updatedAt":"$bot_at","commit":{"oid":"$review_oid"}}$extra_reviews]},
  "comments":{"nodes":$comments}
}}}}
JSON
}

# GitLab fixtures: the merge request and its discussions, clean by default with
# a CodeRabbit group-bot note posted after the head pipeline was created.
gl_fixture() {  # <world> [key=value...]
  local world=$1 kv
  shift
  local state=opened draft=false head has_conflicts=false dms=not_approved pstatus=success
  local created=$OLD_ISO finished=$OLD_ISO notes psha=''
  head=$(cat "$world/head")
  notes="[{\"notes\":[{\"author\":{\"username\":\"group_42_bot_abc\"},\"system\":false,\"created_at\":\"2026-01-01T00:05:00Z\",\"resolvable\":false}]}]"
  for kv in "$@"; do
    case "$kv" in
      state=*) state=${kv#*=} ;; draft=*) draft=${kv#*=} ;; head=*) head=${kv#*=} ;;
      has_conflicts=*) has_conflicts=${kv#*=} ;; dms=*) dms=${kv#*=} ;; pstatus=*) pstatus=${kv#*=} ;;
      created=*) created=${kv#*=} ;; finished=*) finished=${kv#*=} ;; notes=*) notes=${kv#*=} ;;
      psha=*) psha=${kv#*=} ;;
    esac
  done
  local pipeline=null
  [ "$pstatus" = none ] || pipeline="{\"status\":\"$pstatus\",\"sha\":\"${psha:-$head}\",\"created_at\":\"$created\",\"finished_at\":\"$finished\"}"
  printf '{"state":"%s","draft":%s,"sha":"%s","has_conflicts":%s,"detailed_merge_status":"%s","head_pipeline":%s}\n' \
    "$state" "$draft" "$head" "$has_conflicts" "$dms" "$pipeline" > "$world/gl.mr.json"
  printf '%s\n' "$notes" > "$world/gl.discussions.json"
}

expect_unclean() {  # <world> <label> <reason-substring>
  local world=$1 label=$2 want=$3 out rc=0
  rm -f "$world/gh.count"
  out=$(run_park "$world" gate lane 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "$label: gate exit $rc, wanted 3 (unclean): $out"
  case "$out" in *"$want"*) ;; *) fail "$label: gate reason missing '$want': $out" ;; esac
}

expect_clean() {  # <world> <label>
  local world=$1 label=$2 out rc=0
  rm -f "$world/gh.count"
  out=$(run_park "$world" gate lane 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "$label: gate exit $rc, wanted clean: $out"
  [ "$out" = "clean head=$(cat "$world/head")" ] || fail "$label: unexpected clean output: $out"
}

test_github_gate_clean_and_each_unclean_condition() {
  local w
  w=$(make_world gh-gate "$GH_URL")
  gh_fixture "$w/gh.1.json"; expect_clean "$w" "github clean"
  gh_fixture "$w/gh.1.json" draft=true; expect_unclean "$w" draft "the PR is a draft"
  gh_fixture "$w/gh.1.json" state=CLOSED; expect_unclean "$w" closed "the PR is closed"
  gh_fixture "$w/gh.1.json" mergeable=CONFLICTING mss=DIRTY; expect_unclean "$w" conflict "merge conflicts"
  gh_fixture "$w/gh.1.json" mss=BEHIND; expect_unclean "$w" behind "behind its base"
  gh_fixture "$w/gh.1.json" mergeable=UNKNOWN mss=UNKNOWN; expect_unclean "$w" unknown "mergeability is not computed"
  gh_fixture "$w/gh.1.json" 'rollup="PENDING"'; expect_unclean "$w" ci-pending "CI is pending"
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'; expect_unclean "$w" ci-failing "CI is failure"
  gh_fixture "$w/gh.1.json" rollup=null; expect_unclean "$w" ci-none "CI is none"
  gh_fixture "$w/gh.1.json" decision=CHANGES_REQUESTED; expect_unclean "$w" changes "changes are requested"
  gh_fixture "$w/gh.1.json" 'threads=[{"isResolved":true},{"isResolved":false}]' total=2
  expect_unclean "$w" threads "1 review thread(s) unresolved"
  gh_fixture "$w/gh.1.json" 'threads=[]' total=150; expect_unclean "$w" threads-truncated "could not all be read"
  pass "github gate: clean PR parks, and draft, closed, conflict, behind, unknown mergeability, CI pending/failing/absent, changes requested, unresolved and unread threads each refuse"
}

test_github_gate_refuses_until_every_required_check_reports() {
  local w
  w=$(make_world gh-required "$GH_URL")
  gh_fixture "$w/gh.1.json"
  # The rollup is green, but it holds only the checks that reported: the
  # base branch also requires validate, which has not.
  printf '%s\n' '{"protected":true,"protection":{"required_status_checks":{"contexts":["ci","validate"]}}}' > "$w/gh.branch.json"
  expect_unclean "$w" required-missing "required check(s) validate have not reported on head"
  printf '%s\n' '{"protected":true,"protection":{"required_status_checks":{"contexts":["ci"]}}}' > "$w/gh.branch.json"
  expect_clean "$w" required-reported
  : > "$w/gh.branch.fail"
  expect_unclean "$w" required-unreadable "the required checks of the base branch could not be read"
  pass "github gate refuses while a required check of the base branch has not reported on the head, or the requirement cannot be read"
}

test_github_gate_waits_for_review_bots_or_quiet_window() {
  local w
  w=$(make_world gh-bots "$GH_URL")
  # The bot reviewed an older head and CI just finished: neither settled.
  gh_fixture "$w/gh.1.json" review_oid=0000000000000000000000000000000000000001 completed="$NOW_ISO" committed="$NOW_ISO"
  expect_unclean "$w" bot-stale "automated reviewers (coderabbitai) have not submitted a review of this head"
  # No reviewer bot ever posted and CI just finished: only the window can settle it.
  gh_fixture "$w/gh.1.json" completed="$NOW_ISO" committed="$NOW_ISO" extra_reviews=''
  sed -i.bak 's/"coderabbitai","__typename":"Bot"/"alice","__typename":"User"/' "$w/gh.1.json"
  expect_unclean "$w" no-bot "no automated reviewer has submitted a review of this head"
  # The same PR once the quiet window has elapsed.
  FM_TEST_QUIET=0 expect_clean "$w" quiet-elapsed
  # A bot comment or review edit after the push does not prove its review of
  # this head finished: only a review bound to the head, or the window, does.
  gh_fixture "$w/gh.1.json" review_oid=0000000000000000000000000000000000000001 completed="$NOW_ISO" committed="$OLD_ISO" bot_at="$NOW_ISO" \
    comments="[{\"author\":{\"login\":\"coderabbitai\",\"__typename\":\"Bot\"},\"createdAt\":\"$NOW_ISO\",\"updatedAt\":\"$NOW_ISO\"}]"
  expect_unclean "$w" bot-comment-after-push "automated reviewers (coderabbitai) have not submitted a review of this head"
  # A login named in config/contribution-review-bots counts as a reviewer bot.
  gh_fixture "$w/gh.1.json" completed="$NOW_ISO" committed="$NOW_ISO" \
    comments='[{"author":{"login":"greptile","__typename":"User"},"createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}]'
  printf 'greptile\n' > "$w/config/contribution-review-bots"
  expect_unclean "$w" listed-bot "automated reviewers (coderabbitai, greptile)"
  rm -f "$w/config/contribution-review-bots"
  # The head was committed long ago but pushed just now: the window runs from
  # the push, not the commit.
  gh_fixture "$w/gh.1.json" review_oid=0000000000000000000000000000000000000001 committed="$OLD_ISO" \
    pushed="$NOW_ISO" completed="$OLD_ISO"
  expect_unclean "$w" committed-before-push "quiet window"
  # With no check suite on the head, the committer time stands in for the push.
  gh_fixture "$w/gh.1.json" review_oid=0000000000000000000000000000000000000001 committed="$NOW_ISO" \
    pushed=none completed="$OLD_ISO"
  expect_unclean "$w" no-check-suite "quiet window"
  pass "github gate waits for every reviewer bot to submit a review of the current head, or the quiet window since it was pushed"
}

test_gitlab_gate_clean_and_unclean_conditions() {
  local w
  w=$(make_world gl-gate "$GL_URL")
  gl_fixture "$w"; expect_clean "$w" "gitlab clean"
  grep -qF -- '--hostname gitlab.example.com projects/team%2Fsub%2Frepo/merge_requests/7' "$w/glab.log" \
    || fail "gitlab gate did not address the merge request on its own host"
  gl_fixture "$w" draft=true; expect_unclean "$w" gl-draft "the PR is a draft"
  gl_fixture "$w" has_conflicts=true dms=conflict; expect_unclean "$w" gl-conflict "merge conflicts"
  gl_fixture "$w" dms=need_rebase; expect_unclean "$w" gl-rebase "behind its base"
  gl_fixture "$w" pstatus=running; expect_unclean "$w" gl-ci-running "CI is pending"
  gl_fixture "$w" pstatus=failed; expect_unclean "$w" gl-ci-failed "CI is failure"
  gl_fixture "$w" pstatus=none; expect_unclean "$w" gl-ci-none "CI is none"
  # A green pipeline that ran on an older commit is not CI on this head.
  gl_fixture "$w" psha=0000000000000000000000000000000000000004; expect_unclean "$w" gl-ci-old-sha "CI is none"
  gl_fixture "$w" dms=requested_changes; expect_unclean "$w" gl-changes "changes are requested"
  gl_fixture "$w" dms=jira_association_missing; expect_unclean "$w" gl-other "merge status jira_association_missing"
  gl_fixture "$w" notes='[{"notes":[{"author":{"username":"bob"},"system":false,"created_at":"2026-01-01T00:00:00Z","resolvable":true,"resolved":false},{"author":{"username":"alice"},"system":false,"created_at":"2026-01-01T00:01:00Z","resolvable":true,"resolved":false},{"author":{"username":"carol"},"system":false,"created_at":"2026-01-01T00:02:00Z","resolvable":true,"resolved":true}]}]'
  expect_unclean "$w" gl-thread "2 review thread(s) unresolved"
  # CodeRabbit's group bot posted before this head's pipeline was created.
  gl_fixture "$w" created="$NOW_ISO" finished="$NOW_ISO"
  expect_unclean "$w" gl-bot-stale "automated reviewers (group_42_bot_abc) have not submitted a review of this head"
  # A bot note after the pipeline started proves no finished review: the
  # quiet window still decides.
  gl_fixture "$w" created="$OLD_ISO" finished="$NOW_ISO" \
    notes="[{\"notes\":[{\"author\":{\"username\":\"group_42_bot_abc\"},\"system\":false,\"created_at\":\"$NOW_ISO\",\"resolvable\":false}]}]"
  expect_unclean "$w" gl-bot-note-only "quiet window"
  # A full first page of system-note discussions: every page is read.
  gl_fixture "$w" notes="$(jq -cn '[range(100) | {notes: [{author: {username: "root"}, system: true, created_at: "2026-01-01T00:00:00Z", resolvable: false}]}]')"
  printf '%s\n' '[{"notes":[{"author":{"username":"group_42_bot_abc"},"system":false,"created_at":"2026-01-01T00:05:00Z","resolvable":false}]}]' \
    > "$w/gl.discussions.2.json"
  expect_clean "$w" gl-second-page
  printf '%s\n' '[{"notes":[{"author":{"username":"bob"},"system":false,"created_at":"2026-01-01T00:06:00Z","resolvable":true,"resolved":false}]}]' \
    > "$w/gl.discussions.2.json"
  expect_unclean "$w" gl-second-page-thread "1 review thread(s) unresolved"
  rm -f "$w/gl.discussions.2.json"
  pass "gitlab gate: clean MR parks, and draft, conflict, rebase, CI running/failed/absent, changes requested, other merge blockers, unresolved threads, a pipeline on an older commit, and a review bot that has not finished each refuse, across every page of discussions"
}

test_park_stops_agent_records_lane_and_leases_slot() {
  local w head out rc=0
  w=$(make_world park-ok "$GH_URL")
  head=$(cat "$w/head")
  gh_fixture "$w/gh.1.json"
  out=$(run_park "$w" park lane 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "park: exit $rc: $out"
  case "$out" in "parked lane: PR $GH_URL clean at ${head:0:12}; agent stopped") ;; *) fail "park: output $out" ;; esac
  [ "$(cat "$w/control.log")" = "lane exit" ] || fail "park: expected exactly one control exit, got $(cat "$w/control.log")"
  grep -qx "lease 3 --lease-holder lane --root $w/root" "$w/treehouse.log" || fail "park: slot was not durably leased: $(cat "$w/treehouse.log" 2>/dev/null)"
  grep -qx "head=$head" "$w/state/lane.review-park" || fail "park: record lacks the parked head"
  grep -qx "slot_leased=yes" "$w/state/lane.review-park" || fail "park: record does not note the lease"
  [ "$(stat -f %Lp "$w/state/lane.review-park" 2>/dev/null || stat -c %a "$w/state/lane.review-park")" = 600 ] \
    || fail "park: record is not private"
  tail -1 "$w/state/lane.status" | grep -q "^paused \[at=[0-9]*\]: parked on review: PR $GH_URL clean at ${head:0:12}" \
    || fail "park: no declared wait in the status log: $(tail -1 "$w/state/lane.status")"
  [ "$(cat "$w/gh.count")" = 2 ] || fail "park: expected a fresh gate read and a re-check before the stop, got $(cat "$w/gh.count") reads"
  out=$(run_park "$w" list)
  case "$out" in "lane	PR $GH_URL	head ${head:0:12}	parked "*) ;; *) fail "park: list output $out" ;; esac
  pass "park evaluates the gate twice, leases the slot, writes a private record, stops the agent once, and declares the wait"
}

test_park_refuses_when_head_moves_after_the_verdict() {
  local w out rc=0
  w=$(make_world park-head-moved "$GH_URL")
  gh_fixture "$w/gh.1.json"
  gh_fixture "$w/gh.2.json" head=0000000000000000000000000000000000000002
  out=$(run_park "$w" park lane 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "head-moved: exit $rc: $out"
  case "$out" in *"the head moved from"*) ;; *) fail "head-moved: refusal does not name the moved head: $out" ;; esac
  [ ! -e "$w/control.log" ] || fail "head-moved: the agent was stopped: $(cat "$w/control.log")"
  [ ! -e "$w/state/lane.review-park" ] || fail "head-moved: a park record was left behind"
  ! grep -q "parked on review" "$w/state/lane.status" || fail "head-moved: a parked line was appended"
  pass "a head change between the verdict and the stop refuses the park and leaves the agent running"
}

test_park_refuses_when_the_lane_is_steered_before_the_stop() {
  local w out rc
  w=$(make_world park-steered "$GH_URL")
  gh_fixture "$w/gh.1.json"
  printf 'mkdir -p "%s/state/lane.inbox"; : > "%s/state/lane.inbox/001.msg"\n' "$w" "$w" > "$w/gh.2.sh"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"steering inbox"*) ;; *) fail "steered-inbox: $rc $out" ;; esac
  [ ! -e "$w/control.log" ] || fail "steered-inbox: the agent was stopped: $(cat "$w/control.log")"
  [ ! -e "$w/state/lane.review-park" ] || fail "steered-inbox: a park record was left behind"

  rm -rf "$w/state/lane.inbox" "$w/gh.count"
  cat > "$w/gh.2.sh" <<SH
printf 'v1 gen=gen1 seq=9 state=busy source=claude-hook event=UserPromptSubmit ts=%s\\n' "\$(date +%s)" > "$w/state/lane.busy-state"
SH
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"the agent is not idle"*) ;; *) fail "steered-busy: $rc $out" ;; esac
  [ ! -e "$w/control.log" ] || fail "steered-busy: the agent was stopped: $(cat "$w/control.log")"
  [ ! -e "$w/state/lane.review-park" ] || fail "steered-busy: a park record was left behind"
  ! grep -q "parked on review" "$w/state/lane.status" || fail "steered: a parked line was appended"
  pass "an instruction or a new turn arriving after the preflight refuses the park before the agent is stopped"
}

# Starts a park whose stop hangs and kills it outright in the middle of it.
kill_park_during_stop() {  # <world>
  local w=$1 pid
  cp "$w/fakebin/fm-control.sh" "$w/fm-control.sh.orig"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/control.log"\nsleep 5\n' "$w" > "$w/fakebin/fm-control.sh"
  TMPDIR="$w" run_park "$w" park lane >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -s "$w/control.log" ] && break; sleep 0.1; done
  [ -s "$w/control.log" ] || fail "interrupted: the stop never started"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  mv "$w/fm-control.sh.orig" "$w/fakebin/fm-control.sh"
  rm -f "$w/control.log" "$w/gh.count"
}

test_interrupted_park_reads_as_parking_and_the_tick_settles_it() {
  local w out
  w=$(make_world park-interrupted "$GH_URL")
  gh_fixture "$w/gh.1.json"
  kill_park_during_stop "$w"
  grep -qx 'pending=1' "$w/state/lane.review-park" || fail "interrupted: no pending park record"
  out=$(FM_HOME="$w" FM_STATE_OVERRIDE="$w/state" "$ROOT/bin/fm-crew-state.sh" lane 2>&1 | head -1)
  case "$out" in *"parking on review"*) ;; *) fail "interrupted: crew state does not read parking: $out" ;; esac
  case "$out" in *"agent stopped"*) fail "interrupted: crew state claims the agent stopped: $out" ;; esac
  case "$(run_park "$w" list)" in *"parking; stop not yet confirmed"*) ;; *) fail "interrupted: list: $(run_park "$w" list)" ;; esac
  # Feedback after the crash still relaunches the lane, and the tick first
  # promotes the record because the agent is confirmed dead.
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'
  expect_relaunch "$w" interrupted-dead "checks are failing"

  w=$(make_world park-interrupted-quiet "$GH_URL")
  gh_fixture "$w/gh.1.json"
  kill_park_during_stop "$w"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "interrupted-quiet: tick acted: $out"
  [ -e "$w/state/lane.review-park" ] || fail "interrupted-quiet: the record of a stopped agent was dropped"
  ! grep -q '^pending=' "$w/state/lane.review-park" || fail "interrupted-quiet: the record of a stopped agent was not promoted to parked"

  w=$(make_world park-interrupted-alive "$GH_URL")
  gh_fixture "$w/gh.1.json"
  kill_park_during_stop "$w"
  : > "$w/agent.alive"
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "interrupted-alive: tick acted: $out"
  [ ! -e "$w/state/lane.review-park" ] || fail "interrupted-alive: the record of a running agent was kept"
  pass "a park killed during the stop reads as parking, still relaunches on feedback, and the next tick parks it once the agent is dead or drops it while the agent runs"
}

test_hung_pending_check_ends_within_the_tick() {
  local w out start took
  w=$(make_world park-pending-hang "$GH_URL")
  gh_fixture "$w/gh.1.json"
  kill_park_during_stop "$w"
  cp "$w/state/lane.meta" "$w/state/lane2.meta"
  cp "$w/state/lane.review-park" "$w/state/lane2.review-park"
  : > "$w/tmux.hang"
  start=$(date +%s)
  out=$(FM_PARK_TICK_SECS=2 run_park "$w" tick 2>&1)
  took=$(( $(date +%s) - start ))
  [ "$took" -lt 10 ] || fail "pending-hang: a hung agent check held the tick for ${took}s"
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "pending-hang: tick acted: $out"
  grep -qx 'pending=1' "$w/state/lane.review-park" || fail "pending-hang: an unanswered check settled a pending record"
  grep -qx 'pending=1' "$w/state/lane2.review-park" || fail "pending-hang: an unvisited pending record was settled"
  [ "$(cat "$w/state/.review-park-tick-next" 2>/dev/null)" = lane2 ] \
    || fail "pending-hang: the tick did not save the lane it never reached"
  rm -f "$w/tmux.hang"
  run_park "$w" tick >/dev/null 2>&1
  ! grep -q '^pending=' "$w/state/lane.review-park" "$w/state/lane2.review-park" \
    || fail "pending-hang: the next tick did not settle the pending records"
  pass "a hung agent check on a pending park ends within the tick, and the next tick resumes and settles it"
}

test_failed_park_record_write_leaves_the_agent_running() {
  local w out rc=0
  w=$(make_world park-record-fail "$GH_URL")
  gh_fixture "$w/gh.1.json"
  printf 'chmod a-w "%s/state"\n' "$w" > "$w/gh.2.sh"
  out=$(run_park "$w" park lane 2>&1) || rc=$?
  chmod u+w "$w/state"
  case "$rc:$out" in 1:*"its park record could not be written"*) ;; *) fail "record-fail: $rc $out" ;; esac
  [ ! -e "$w/control.log" ] || fail "record-fail: the agent was stopped: $(cat "$w/control.log")"
  [ ! -e "$w/state/lane.review-park" ] || fail "record-fail: a park record was left behind"
  ! grep -q "parked on review" "$w/state/lane.status" || fail "record-fail: a parked line was appended"
  pass "a park whose record cannot be written refuses before the agent is stopped"
}

test_park_preflight_refusals_leave_the_agent_running() {
  local w out rc
  w=$(make_world park-preflight "$GH_URL")
  gh_fixture "$w/gh.1.json"

  printf 'v1 gen=gen1 seq=4 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$(date +%s)" > "$w/state/lane.busy-state"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"the agent is not idle"*) ;; *) fail "busy: $rc $out" ;; esac
  printf 'v1 gen=gen1 seq=5 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" > "$w/state/lane.busy-state"

  printf 'state: working · source: run-step · ci\n' > "$w/crew-state"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"has not finished at a ready report"*) ;; *) fail "working: $rc $out" ;; esac
  rm -f "$w/crew-state"

  mkdir -p "$w/state/lane.inbox"; : > "$w/state/lane.inbox/001.msg"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"steering inbox"*) ;; *) fail "inbox: $rc $out" ;; esac
  rm -f "$w/state/lane.inbox/001.msg"

  printf 'dirty\n' > "$(fm_meta_get_test "$w" worktree)/dirty.txt"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"uncommitted changes"*) ;; *) fail "dirty: $rc $out" ;; esac
  rm -f "$(fm_meta_get_test "$w" worktree)/dirty.txt"

  mv "$w/state/lane.check.sh" "$w/state/lane.check.off"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"no merge poll is armed"*) ;; *) fail "no-poll: $rc $out" ;; esac
  mv "$w/state/lane.check.off" "$w/state/lane.check.sh"

  gh_fixture "$w/gh.1.json" head=0000000000000000000000000000000000000003
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"the local copy is at"*) ;; *) fail "local-behind: $rc $out" ;; esac
  gh_fixture "$w/gh.1.json"

  : > "$w/treehouse.fail"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"could not be leased durably"*) ;; *) fail "lease-fail: $rc $out" ;; esac
  rm -f "$w/treehouse.fail"

  : > "$w/control.fail"
  rc=0; out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"the agent could not be stopped"*) ;; *) fail "control-fail: $rc $out" ;; esac
  grep -qx 'pending=1' "$w/state/lane.review-park" || fail "control-fail: no pending record for the tick to settle"
  rm -f "$w/control.fail" "$w/control.log"
  : > "$w/agent.alive"
  run_park "$w" tick >/dev/null 2>&1
  [ ! -e "$w/state/lane.review-park" ] || fail "control-fail: the tick kept the record of a running agent"
  [ ! -e "$w/control.log" ] || fail "control-fail: the tick acted on the lane: $(cat "$w/control.log")"

  ! grep -q "parked on review" "$w/state/lane.status" || fail "preflight: a parked line was appended"
  pass "park refuses a busy or unfinished worker, a waiting instruction, a dirty or lagging copy, an unarmed merge poll, an unleasable slot, and a failed stop"
}

test_repark_reuses_its_own_lease_and_refuses_a_foreign_one() {
  local w wt out rc=0
  w=$(make_world repark-lease "$GH_URL")
  gh_fixture "$w/gh.1.json"
  wt=$(cd "$(fm_meta_get_test "$w" worktree)" && pwd -P)
  printf '[{"name":"3","path":"%s","status":"leased","lease_holder":"lane"}]\n' "$wt" > "$w/treehouse.status.json"
  out=$(run_park "$w" park lane 2>&1) || fail "own-lease: park refused: $out"
  ! grep -q '^lease ' "$w/treehouse.log" || fail "own-lease: leased the slot a second time"
  grep -qx "slot_leased=yes" "$w/state/lane.review-park" || fail "own-lease: record does not note the lease"

  w=$(make_world foreign-lease "$GH_URL")
  gh_fixture "$w/gh.1.json"
  wt=$(cd "$(fm_meta_get_test "$w" worktree)" && pwd -P)
  printf '[{"name":"3","path":"%s","status":"leased","lease_holder":"other-task"}]\n' "$wt" > "$w/treehouse.status.json"
  : > "$w/treehouse.fail"
  out=$(run_park "$w" park lane 2>&1) || rc=$?
  case "$rc:$out" in 1:*"could not be leased durably"*) ;; *) fail "foreign-lease: $rc $out" ;; esac
  [ ! -e "$w/control.log" ] || fail "foreign-lease: the agent was stopped"
  pass "a lane re-parked after a relaunch keeps its own durable lease, and a slot leased to another holder refuses the park"
}

fm_meta_get_test() {  # <world> <key>
  sed -n "s/^$2=//p" "$1/state/lane.meta" | tail -1
}

# Park a world through the real park path, then reset the forge read counter.
park_world() {  # <world>
  local o; o=$(run_park "$1" park lane 2>&1) || fail "setup: park failed for $1: $o"
  rm -f "$1/gh.count" "$1/control.log"
}

# Waits for a detached lane action to publish its outcome for the next tick.
wait_report() {  # <world> <label>
  for _ in $(seq 1 200); do
    ! compgen -G "$1/state/.review-park-report-*" >/dev/null || return 0
    sleep 0.1
  done
  fail "$2: no detached action reported within 20s"
}

# Waits for a detached land to settle. It publishes its report before it
# removes the pending request, so a removed request means the report exists.
wait_land_settled() {  # <world> <label>
  for _ in $(seq 1 200); do
    [ -e "$1/state/lane.review-park-land" ] || break
    sleep 0.1
  done
  [ ! -e "$1/state/lane.review-park-land" ] || fail "$2: the pending cleanup request was not cleared within 20s"
  compgen -G "$1/state/.review-park-report-*" >/dev/null || fail "$2: the pending request was cleared without a reported outcome"
}

# One tick that starts a lane action, then the next tick, which reports its
# outcome; prints that report.
tick_and_report() {  # <world> <label>
  local out
  out=$(run_park "$1" tick 2>&1) || fail "$2: tick failed: $out"
  [ -z "$out" ] || fail "$2: the starting tick printed: $out"
  wait_report "$1" "$2"
  run_park "$1" tick 2>&1 || fail "$2: the reporting tick failed"
}

expect_relaunch() {  # <world> <label> <trigger-substring>
  local world=$1 label=$2 want=$3 out
  out=$(tick_and_report "$world" "$label")
  case "$out" in "relaunched lane: PR "*"$want"*) ;; *) fail "$label: tick output: $out" ;; esac
  head -1 "$world/control.log" | grep -q "^lane relaunch --note-file " || fail "$label: no relaunch call: $(cat "$world/control.log")"
  grep -qF "$want" "$world/control.log" || fail "$label: the relaunch note does not carry the trigger"
  grep -qF "same local copy on the same branch" "$world/control.log" || fail "$label: the note does not name the same copy and branch"
  [ ! -e "$world/state/lane.review-park" ] || fail "$label: park record kept after relaunch"
  tail -1 "$world/state/lane.status" | grep -q "^working \[at=[0-9]*\]: relaunched from review park: .*$want" \
    || fail "$label: no working line: $(tail -1 "$world/state/lane.status")"
}

test_each_relaunch_trigger_relaunches_a_fresh_worker() {
  local w later
  later=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)

  w=$(make_world trig-head "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  rm -f "$w"/gh.*.json; gh_fixture "$w/gh.1.json" head=0000000000000000000000000000000000000009
  expect_relaunch "$w" head "the head moved to 000000000000"

  w=$(make_world trig-ci "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'
  expect_relaunch "$w" ci "checks are failing"

  w=$(make_world trig-changes "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" decision=CHANGES_REQUESTED
  expect_relaunch "$w" changes "changes were requested"

  w=$(make_world trig-thread "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" 'threads=[{"isResolved":false}]' total=1
  expect_relaunch "$w" thread "1 review thread(s) unresolved"

  w=$(make_world trig-incomplete-threads "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" 'threads=[]' total=150
  expect_relaunch "$w" incomplete-threads "review threads could not all be read"

  w=$(make_world trig-conflict "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" mergeable=CONFLICTING mss=DIRTY
  expect_relaunch "$w" conflict "merge conflicts"

  w=$(make_world trig-comment "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" comments="[{\"author\":{\"login\":\"carol\",\"__typename\":\"User\"},\"createdAt\":\"$later\",\"updatedAt\":\"$later\"}]"
  expect_relaunch "$w" comment "new comments from carol"

  # An older comment edited after the park is new feedback too.
  w=$(make_world trig-edit "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" comments="[{\"author\":{\"login\":\"coderabbitai\",\"__typename\":\"Bot\"},\"createdAt\":\"$OLD_ISO\",\"updatedAt\":\"$later\"}]"
  expect_relaunch "$w" edited-comment "new comments from coderabbitai"

  # An inline reply in an already resolved thread leaves no unresolved thread
  # and no new review submission; the reply itself is the new feedback.
  w=$(make_world trig-thread-reply "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" total=1 \
    threads="[{\"isResolved\":true,\"comments\":{\"nodes\":[{\"author\":{\"login\":\"erin\",\"__typename\":\"User\"},\"createdAt\":\"$later\",\"updatedAt\":\"$later\"}]}}]"
  expect_relaunch "$w" thread-reply "new comments from erin"

  w=$(make_world trig-gl-edit "$GL_URL"); gl_fixture "$w"; park_world "$w"
  gl_fixture "$w" notes="[{\"notes\":[{\"author\":{\"username\":\"group_42_bot_abc\"},\"system\":false,\"created_at\":\"$OLD_ISO\",\"updated_at\":\"$later\",\"resolvable\":false}]}]"
  expect_relaunch "$w" gitlab-edited-note "new comments from group_42_bot_abc"

  w=$(make_world trig-gl-note "$GL_URL"); gl_fixture "$w"; park_world "$w"
  gl_fixture "$w" notes="[{\"notes\":[{\"author\":{\"username\":\"dave\"},\"system\":false,\"created_at\":\"$later\",\"resolvable\":false}]}]"
  expect_relaunch "$w" gitlab-note "new comments from dave"
  pass "head change, failing checks, changes requested, an unresolved thread, a conflict, and new or edited GitHub or GitLab comments, including an inline reply in a resolved thread, each relaunch a fresh worker with the trigger in its instructions"
}

test_behind_base_does_not_relaunch() {
  local w out
  w=$(make_world trig-behind "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" mss=BEHIND
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "behind: tick acted: $out"
  [ -e "$w/state/lane.review-park" ] || fail "behind: park record lost"
  pass "a parked branch that merely fell behind its base stays parked"
}

# A relaunch that takes longer than the whole tick budget still completes: the
# tick only starts it, and nothing bounded by the tick can kill it.
test_slow_relaunch_is_never_cut_short_by_the_tick() {
  local w out start took
  w=$(make_world tick-slow-relaunch "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'
  printf '#!/usr/bin/env bash\nsleep 8\nprintf "%%s\\n" "$*" >> "%s/control.log"\n' "$w" > "$w/fakebin/fm-control.sh"
  start=$(date +%s)
  out=$(FM_PARK_TICK_SECS=6 run_park "$w" tick 2>&1)
  took=$(( $(date +%s) - start ))
  [ -z "$out" ] || fail "slow-relaunch: the starting tick printed: $out"
  [ ! -e "$w/control.log" ] && [ "$took" -lt 8 ] || fail "slow-relaunch: the tick waited ${took}s for the relaunch"
  # A tick while the relaunch runs leaves the busy lane alone.
  out=$(FM_PARK_TICK_SECS=6 run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "slow-relaunch: a tick during the relaunch printed: $out"
  wait_report "$w" slow-relaunch
  out=$(FM_PARK_TICK_SECS=6 run_park "$w" tick 2>&1)
  case "$out" in "relaunched lane: PR $GH_URL - checks are failing"*) ;; *) fail "slow-relaunch: report: $out" ;; esac
  [ "$(grep -c ' relaunch ' "$w/control.log")" = 1 ] || fail "slow-relaunch: relaunch calls: $(cat "$w/control.log")"
  [ ! -e "$w/state/lane.review-park" ] || fail "slow-relaunch: the record of a relaunched lane was kept: $(cat "$w/state/lane.review-park")"
  pass "a relaunch slower than the whole tick budget completes once, is never killed, and is reported by the next tick"
}

test_tick_resumes_where_the_last_one_ran_out_of_time() {
  local w out
  w=$(make_world tick-rotate "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  cp "$w/state/lane.meta" "$w/state/lane2.meta"
  cp "$w/state/lane.review-park" "$w/state/lane2.review-park"
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'
  # The first lane's read outlasts the whole tick; in the next tick the second
  # lane visited is the slow one, so only the lane that tick starts at relaunches.
  printf 'sleep 8\n' > "$w/gh.1.sh"
  printf 'sleep 8\n' > "$w/gh.3.sh"
  out=$(FM_PARK_TICK_SECS=6 run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "rotate: the slow tick acted: $out"
  FM_PARK_TICK_SECS=6 run_park "$w" tick >/dev/null 2>&1
  wait_report "$w" rotate
  [ "$(grep ' relaunch ' "$w/control.log" | cut -d' ' -f1)" = lane2 ] \
    || fail "rotate: the next tick did not start at the lane the last one never reached: $(grep ' relaunch ' "$w/control.log")"
  [ -e "$w/state/lane.review-park" ] || fail "rotate: the lane read last was relaunched"
  out=$(run_park "$w" tick 2>&1)
  case "$out" in "relaunched lane2: "*) ;; *) fail "rotate: the next tick did not report lane2: $out" ;; esac
  wait_report "$w" rotate-rest
  [ ! -e "$w/state/lane.review-park" ] && [ ! -e "$w/state/lane2.review-park" ] \
    || fail "rotate: a complete tick did not visit every lane: $out"
  pass "a tick that runs out of time resumes at the next unvisited lane, so a slow early lane cannot starve later ones"
}

test_quiet_parked_lane_and_approval_do_not_relaunch() {
  local w later out
  later=$(date -u -v+1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
  w=$(make_world quiet "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "quiet: tick printed $out"
  gh_fixture "$w/gh.1.json" extra_reviews=",{\"author\":{\"login\":\"erin\",\"__typename\":\"User\"},\"state\":\"APPROVED\",\"body\":\"\",\"submittedAt\":\"$later\",\"updatedAt\":\"$later\",\"commit\":{\"oid\":\"$(cat "$w/head")\"}}"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "approval: tick printed $out"
  [ ! -e "$w/control.log" ] || fail "quiet: a lifecycle call was made: $(cat "$w/control.log")"
  [ -e "$w/state/lane.review-park" ] || fail "quiet: park record lost"
  pass "an unchanged parked PR and a bare approval stay parked silently"
}

test_failed_relaunch_keeps_record_and_stops_retrying() {
  local w out
  w=$(make_world relaunch-fail "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'
  : > "$w/control.fail"
  out=$(tick_and_report "$w" relaunch-fail)
  case "$out" in "relaunch-failed lane: PR $GH_URL (checks are failing"*) ;; *) fail "relaunch-fail: tick output $out" ;; esac
  grep -q '^resume_error=' "$w/state/lane.review-park" || fail "relaunch-fail: record does not note the failure"
  rm -f "$w/control.log"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "relaunch-fail: tick retried: $out"
  pass "a failed relaunch keeps the park record, reports once, and waits for a manual resume"
}

test_closed_pr_is_reported_once() {
  local w out
  w=$(make_world closed "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" state=CLOSED
  out=$(run_park "$w" tick 2>&1)
  [ "$out" = "closed lane: PR $GH_URL was closed without merging; the lane needs a decision" ] || fail "closed: $out"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "closed: reported twice: $out"
  [ ! -e "$w/control.log" ] || fail "closed: a lifecycle call was made"

  w=$(make_world closed-default-off "$GL_URL"); gl_fixture "$w" state=closed
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/glab.log" ] || fail "closed-default-off: tick acted without opt-in: $out"

  w=$(make_world closed-unparked "$GL_URL"); gl_fixture "$w" state=closed
  : > "$w/config/auto-land"
  out=$(run_park "$w" tick 2>&1)
  [ "$out" = "closed lane: PR $GL_URL was closed without merging; the lane needs a decision" ] || fail "closed-unparked: $out"
  pass "closed-without-merge reporting for unparked lanes requires a feature flag"
}

test_tick_parks_clean_idle_lanes_only_when_opted_in() {
  local w out
  w=$(make_world auto-park "$GL_URL"); gl_fixture "$w"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "auto-park: tick parked without config/park-on-review: $out"
  : > "$w/config/auto-land"; rm -f "$w/glab.log"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "auto-park: unexpected output while auto-land is enabled: $out"
  : > "$w/config/park-on-review"
  gl_fixture "$w" pstatus=running
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] && [ ! -e "$w/control.log" ] || fail "auto-park: parked an unclean lane: $out"
  gl_fixture "$w"
  out=$(tick_and_report "$w" auto-park)
  case "$out" in "parked lane: PR $GL_URL clean at "*) ;; *) fail "auto-park: tick output $out" ;; esac
  [ -e "$w/state/lane.review-park" ] || fail "auto-park: no record"
  pass "tick parks nothing without opt-in, reads nothing when opted out of cleanup too, never parks an unclean lane, and parks a clean idle one under config/park-on-review"
}

test_land_requires_opt_in_but_always_cleans_parked() {
  local w out rc
  w=$(make_world land-off "$GH_URL")
  out=$(run_park "$w" land lane --if-eligible 2>&1)
  [ -z "$out" ] && [ ! -e "$w/teardown.log" ] || fail "land: acted without config/auto-land: $out"
  : > "$w/config/auto-land"
  out=$(run_park "$w" land lane --if-eligible 2>&1)
  [ "$out" = "cleaned up lane: PR $GH_URL merged; lane torn down and its working copy returned" ] || fail "land: $out"
  [ "$(cat "$w/teardown.log")" = lane ] || fail "land: teardown was not called exactly once without --force: $(cat "$w/teardown.log")"

  w=$(make_world land-parked "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  : > "$w/teardown.refuse"
  rc=0; out=$(run_park "$w" land lane --if-eligible 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "land-refused: exit $rc"
  [ "$out" = "cleanup-refused lane: PR $GH_URL merged; automatic cleanup refused: REFUSED: worktree has work not on any remote and not landed." ] || fail "land-refused: $out"
  pass "merge-time cleanup requires opt-in for unparked lanes and always cleans parked lanes"
}

# The merge poll's land only starts a detached teardown: it returns at once
# however slow the teardown is, and the next tick reports the outcome, even in
# a home that opted out of everything the tick otherwise watches.
test_detached_land_returns_at_once_and_the_tick_reports_it() {
  local w out start took
  w=$(make_world land-detached "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  printf '#!/usr/bin/env bash\nsleep 6\nprintf "%%s\\n" "$*" >> "%s/teardown.log"\nrm -f "%s/state/lane.review-park" "%s/state/lane.meta"\n' "$w" "$w" "$w" > "$w/fakebin/fm-teardown.sh"
  start=$(date +%s)
  out=$(run_park "$w" land lane --if-eligible --detach 2>&1)
  took=$(( $(date +%s) - start ))
  [ "$out" = "automatic cleanup started" ] || fail "land-detached: $out"
  [ "$took" -lt 6 ] || fail "land-detached: the caller waited ${took}s for the teardown"
  [ ! -e "$w/teardown.log" ] || fail "land-detached: the teardown finished before the caller returned"
  wait_land_settled "$w" land-detached
  [ "$(cat "$w/teardown.log")" = lane ] || fail "land-detached: teardown calls: $(cat "$w/teardown.log")"
  out=$(run_park "$w" tick 2>&1)
  [ "$out" = "cleaned up lane: PR $GH_URL merged; lane torn down and its working copy returned" ] || fail "land-detached: report: $out"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-detached: reported twice: $out"
  pass "a detached merge-time cleanup returns at once, runs its slow teardown to completion, and the next tick reports it once"
}

test_pending_land_recovers_after_watcher_restart() {
  local w out
  w=$(make_world land-recovery "$GH_URL"); gh_fixture "$w/gh.1.json"
  : > "$w/config/auto-land"
  printf 'pr=%s\n' "$GH_URL" > "$w/state/lane.review-park-land"
  cat > "$w/fakebin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
: > "$w/teardown.started"
while [ ! -e "$w/teardown.release" ]; do sleep 0.05; done
echo "Torn down \$1"
SH
  chmod +x "$w/fakebin/fm-teardown.sh"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-recovery: starting tick printed: $out"
  for _ in $(seq 1 100); do [ -e "$w/teardown.started" ] && break; sleep 0.1; done
  [ -e "$w/teardown.started" ] || fail "land-recovery: cleanup did not start"
  [ -e "$w/state/lane.review-park-land" ] || fail "land-recovery: request removed before cleanup outcome"
  : > "$w/teardown.release"
  wait_land_settled "$w" land-recovery
  out=$(run_park "$w" tick 2>&1)
  [ "$out" = "cleaned up lane: PR $GH_URL merged; lane torn down and its working copy returned" ] || fail "land-recovery: outcome: $out"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-recovery: outcome reported twice: $out"
  pass "a pending merged-lane cleanup survives watcher restart and reports its outcome once"
}

test_pending_land_retries_after_control_lock_refusal() {
  local w out
  w=$(make_world land-lock-retry "$GH_URL"); gh_fixture "$w/gh.1.json"
  : > "$w/config/auto-land"
  printf 'pr=%s\n' "$GH_URL" > "$w/state/lane.review-park-land"
  cat > "$w/fakebin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
n=\$(cat "$w/teardown.count" 2>/dev/null || echo 0)
n=\$((n + 1)); printf '%s\\n' "\$n" > "$w/teardown.count"
[ "\$n" != 1 ] || { echo 'error: another lifecycle action is already running for task lane; nothing was changed'; exit 1; }
echo "Torn down \$1"
SH
  chmod +x "$w/fakebin/fm-teardown.sh"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-lock-retry: first tick printed: $out"
  for _ in $(seq 1 100); do [ "$(cat "$w/teardown.count" 2>/dev/null || echo 0)" -ge 1 ] && break; sleep 0.1; done
  [ "$(cat "$w/teardown.count")" = 1 ] || fail "land-lock-retry: first teardown did not run"
  # A tick skips the lane while the first attempt still holds it, and drains
  # any report it published, so tick until the retry runs: every tick must stay
  # silent and the pending request must survive the refusal.
  for _ in $(seq 1 200); do
    [ "$(cat "$w/teardown.count")" = 1 ] || break
    out=$(run_park "$w" tick 2>&1)
    [ -z "$out" ] || fail "land-lock-retry: the lock refusal was reported as an outcome: $out"
    sleep 0.1
  done
  [ "$(cat "$w/teardown.count")" = 2 ] || fail "land-lock-retry: the pending request was never retried"
  wait_land_settled "$w" land-lock-retry
  out=$(run_park "$w" tick 2>&1)
  [ "$out" = "cleaned up lane: PR $GH_URL merged; lane torn down and its working copy returned" ] || fail "land-lock-retry: outcome: $out"
  [ "$(cat "$w/teardown.count")" = 2 ] || fail "land-lock-retry: teardown calls: $(cat "$w/teardown.count")"
  pass "a temporary control-lock refusal stays pending and retries to one reported cleanup outcome"
}

# A cleanup killed partway through its teardown leaves its request behind, so
# the next tick retries it and reports the outcome once.
test_killed_cleanup_is_retried_and_reported_once() {
  local w out pgid
  w=$(make_world land-killed "$GH_URL"); gh_fixture "$w/gh.1.json"
  : > "$w/config/auto-land"
  printf 'pr=%s\n' "$GH_URL" > "$w/state/lane.review-park-land"
  cat > "$w/fakebin/fm-teardown.sh" <<SH
#!/usr/bin/env bash
n=\$(cat "$w/teardown.count" 2>/dev/null || echo 0)
n=\$((n + 1)); printf '%s\\n' "\$n" > "$w/teardown.count"
if [ "\$n" = 1 ]; then
  # Record the detached cleanup's own process group: the nearest ancestor
  # running fm-park.sh run.
  p=\$\$
  while p=\$(ps -o ppid= -p "\$p" | tr -d ' ') && [ "\${p:-1}" -gt 1 ]; do
    case "\$(ps -o command= -p "\$p")" in *"fm-park.sh run lane land"*) ps -o pgid= -p "\$p" | tr -d ' ' > "$w/cleanup.pgid"; break ;; esac
  done
  : > "$w/teardown.started"
  sleep 30
fi
echo "Torn down \$1"
SH
  chmod +x "$w/fakebin/fm-teardown.sh"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-killed: first tick printed: $out"
  for _ in $(seq 1 100); do [ -e "$w/teardown.started" ] && break; sleep 0.1; done
  pgid=$(cat "$w/cleanup.pgid" 2>/dev/null)
  [ -n "$pgid" ] && [ "$pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] || fail "land-killed: no detached cleanup process group found: '$pgid'"
  kill -KILL -- "-$pgid"
  sleep 0.5
  [ -e "$w/state/lane.review-park-land" ] || fail "land-killed: the killed cleanup lost its request"
  ! compgen -G "$w/state/.review-park-report-*" >/dev/null || fail "land-killed: the killed cleanup published an outcome"
  for _ in $(seq 1 200); do
    [ "$(cat "$w/teardown.count")" = 1 ] || break
    out=$(run_park "$w" tick 2>&1)
    [ -z "$out" ] || fail "land-killed: a retry tick printed: $out"
    sleep 0.1
  done
  [ "$(cat "$w/teardown.count")" = 2 ] || fail "land-killed: the killed cleanup was never retried"
  wait_land_settled "$w" land-killed
  out=$(run_park "$w" tick 2>&1)
  [ "$out" = "cleaned up lane: PR $GH_URL merged; lane torn down and its working copy returned" ] || fail "land-killed: outcome: $out"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-killed: reported twice: $out"
  pass "a cleanup killed during its teardown keeps its request, and the next tick retries it and reports once"
}

# A cleanup request names the PR that merged. When the lane has since moved on
# to another PR, the request is dropped without tearing anything down.
test_stale_cleanup_request_for_another_pr_is_dropped() {
  local w out
  w=$(make_world land-stale "$GH_URL"); gh_fixture "$w/gh.1.json"
  : > "$w/config/auto-land"
  printf 'pr=%s\n' "$GH_URL" > "$w/state/lane.review-park-land"
  sed -i.bak "s#^pr=.*#pr=${GH_URL%/*}/8#" "$w/state/lane.meta" && rm -f "$w/state/lane.meta.bak"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-stale: tick printed: $out"
  for _ in $(seq 1 200); do
    [ -e "$w/state/lane.review-park-land" ] || break
    sleep 0.1
  done
  [ ! -e "$w/state/lane.review-park-land" ] || fail "land-stale: the stale request was not dropped within 20s"
  [ ! -e "$w/teardown.log" ] || fail "land-stale: a stale request tore down the lane: $(cat "$w/teardown.log")"
  ! compgen -G "$w/state/.review-park-report-*" >/dev/null || fail "land-stale: a stale request reported: $(cat "$w"/state/.review-park-report-*)"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-stale: a later tick printed: $out"
  pass "a cleanup request for a PR the lane no longer names is dropped without a teardown or a report"
}

# The tick records its wake before it removes the reports behind it, so a
# failed record loses nothing: the reports stay for the next tick.
test_reports_survive_until_their_wake_is_recorded() {
  local w out report
  w=$(make_world report-durable "$GH_URL")
  report="$w/state/.review-park-report-lane-1-1"
  printf 'cleanup-refused lane: PR %s merged; automatic cleanup refused: REFUSED\n' "$GH_URL" > "$report"
  mkdir "$w/state/.wake-queue"
  out=$(run_park "$w" tick 2>/dev/null)
  [ -z "$out" ] || fail "report-durable: a tick that could not record its wake printed: $out"
  [ -e "$report" ] || fail "report-durable: the report was removed although its wake was not recorded"
  rmdir "$w/state/.wake-queue"
  out=$(run_park "$w" tick 2>&1)
  [ "$out" = "cleanup-refused lane: PR $GH_URL merged; automatic cleanup refused: REFUSED" ] || fail "report-durable: retry: $out"
  [ ! -e "$report" ] || fail "report-durable: the report survived its recorded wake"
  [ "$(awk -F '\t' '$3 == "check" && $4 == "park-on-review"' "$w/state/.wake-queue" | wc -l | tr -d ' ')" = 1 ] \
    || fail "report-durable: wake queue: $(cat "$w/state/.wake-queue")"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "report-durable: reported twice: $out"
  pass "an action report survives until the tick has recorded its wake, then is reported once"
}

# A merge-time cleanup that lands while a relaunch of the same lane is under
# way waits for it instead of tearing the lane down mid-relaunch.
test_land_waits_for_an_action_under_way() {
  local w out
  w=$(make_world land-waits "$GH_URL"); gh_fixture "$w/gh.1.json"; park_world "$w"
  gh_fixture "$w/gh.1.json" 'rollup="FAILURE"'
  printf '#!/usr/bin/env bash\nsleep 3\nprintf "%%s\\n" "$*" >> "%s/order.log"\n' "$w" > "$w/fakebin/fm-control.sh"
  printf '#!/usr/bin/env bash\nprintf "teardown\\n" >> "%s/order.log"\n' "$w" > "$w/fakebin/fm-teardown.sh"
  out=$(run_park "$w" tick 2>&1)
  [ -z "$out" ] || fail "land-waits: the starting tick printed: $out"
  for _ in $(seq 1 50); do [ -d "$w/state/.review-park-lane.lock" ] && break; sleep 0.1; done
  [ -d "$w/state/.review-park-lane.lock" ] || fail "land-waits: the relaunch never took the lane lock"
  out=$(run_park "$w" land lane 2>&1)
  case "$out" in "cleaned up lane: "*) ;; *) fail "land-waits: $out" ;; esac
  [ "$(cut -d' ' -f1-2 "$w/order.log" | paste -sd, -)" = "lane relaunch,teardown" ] \
    || fail "land-waits: the teardown did not wait for the relaunch: $(cat "$w/order.log")"
  pass "a merge-time cleanup waits for a relaunch of the same lane that is under way"
}

fm_test_run \
  test_github_gate_clean_and_each_unclean_condition \
  test_github_gate_refuses_until_every_required_check_reports \
  test_github_gate_waits_for_review_bots_or_quiet_window \
  test_gitlab_gate_clean_and_unclean_conditions \
  test_park_stops_agent_records_lane_and_leases_slot \
  test_park_refuses_when_head_moves_after_the_verdict \
  test_park_refuses_when_the_lane_is_steered_before_the_stop \
  test_interrupted_park_reads_as_parking_and_the_tick_settles_it \
  test_hung_pending_check_ends_within_the_tick \
  test_failed_park_record_write_leaves_the_agent_running \
  test_park_preflight_refusals_leave_the_agent_running \
  test_repark_reuses_its_own_lease_and_refuses_a_foreign_one \
  test_each_relaunch_trigger_relaunches_a_fresh_worker \
  test_behind_base_does_not_relaunch \
  test_slow_relaunch_is_never_cut_short_by_the_tick \
  test_tick_resumes_where_the_last_one_ran_out_of_time \
  test_quiet_parked_lane_and_approval_do_not_relaunch \
  test_failed_relaunch_keeps_record_and_stops_retrying \
  test_closed_pr_is_reported_once \
  test_tick_parks_clean_idle_lanes_only_when_opted_in \
  test_land_requires_opt_in_but_always_cleans_parked \
  test_detached_land_returns_at_once_and_the_tick_reports_it \
  test_pending_land_recovers_after_watcher_restart \
  test_pending_land_retries_after_control_lock_refusal \
  test_killed_cleanup_is_retried_and_reported_once \
  test_stale_cleanup_request_for_another_pr_is_dropped \
  test_reports_survive_until_their_wake_is_recorded \
  test_land_waits_for_an_action_under_way
