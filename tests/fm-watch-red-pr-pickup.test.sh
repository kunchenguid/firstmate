#!/usr/bin/env bash
# The red-PR pickup SLA through the watcher's real queue interface: detection
# of every open red PR a live-or-parked lane owns, the owner/step/eta record
# that silences it, the supervisor/main/captain ladder, the mate-home
# backstop, and the record CLI firstmate is told to run. Only the crew-state
# verdict is stubbed through FM_CREW_STATE_BIN (its documented test seam) and
# the forge through a `gh` on PATH; no endpoint, harness process, model call or
# network is needed. Nothing here may merge, tear down or otherwise act on a
# lane.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-red-pr-pickup)
export FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/state"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$TMP_ROOT/bin"

STUB="$TMP_ROOT/crew-state-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${FM_CREW_STATE_NO_FORGE:-0}" >> "$FM_STATE_OVERRIDE/.stub-calls"
cat "$FM_STATE_OVERRIDE/$1.crew-state-line" 2>/dev/null || printf 'state: unknown · source: none · no metadata for %s\n' "$1"
EOF
chmod +x "$STUB"
export FM_CREW_STATE_BIN="$STUB"

# The forge: `gh pr view <url> --json ...` prints the payload kept in
# <state>/.gh-json and `gh pr list --repo ... --json ...` the one kept in
# <state>/.gh-list-json (the branch-discovery read), recording every call so a
# test can prove when the forge was and was not read and how many bounded
# reads a scan spent. A missing payload is a failed read.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_STATE_OVERRIDE/.gh-calls"
case "$1 $2" in
  'pr view') [ -f "$FM_STATE_OVERRIDE/.gh-json" ] || exit 1
    cat "$FM_STATE_OVERRIDE/.gh-json"; exit 0 ;;
  'pr list') [ -f "$FM_STATE_OVERRIDE/.gh-list-json" ] || exit 1
    cat "$FM_STATE_OVERRIDE/.gh-list-json"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# shellcheck source=bin/fm-watch.sh
. "$ROOT/bin/fm-watch.sh"

RED_PR_PICKUP_SCAN_SECS=0
PAUSE_RESURFACE_SECS=10000

PICKUP_BIN="$ROOT/bin/fm-red-pr-pickup.sh"
PR=https://github.com/o/r/pull/7
PR2=https://github.com/o/r/pull/8
PRKEY=https___github.com_o_r_pull_7
PRKEY2=https___github.com_o_r_pull_8
PARKED="state: parked · source: run-step · parked at ci · pr: $PR"
WORKING="state: working · source: run-step · validating · pr: $PR"
DONE="state: done · source: run-step · passed"
RED='{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}'

reset_case() {
  rm -rf -- "$STATE"/.red-pr-pickup "$STATE"/.red-pr-pickups "$STATE"/.red-pr-pickups-scan \
    "$STATE"/.red-pr-ring-*
  rm -f -- "$STATE"/* "$STATE"/.[!.]*
  RED_PR_PICKUP=
}

lane() {  # <task> <crew-state line> [pr-url] [kind]
  printf 'working [at=1000]: on it\n' > "$STATE/$1.status"
  {
    printf 'worktree=%s\n' "$TMP_ROOT"
    [ -z "${3:-}" ] || printf 'pr=%s\n' "$3"
    [ -z "${4:-}" ] || printf 'kind=%s\n' "$4"
  } > "$STATE/$1.meta"
  printf '%s\n' "$2" > "$STATE/$1.crew-state-line"
}

forge() {  # <json>
  printf '%s\n' "$1" > "$STATE/.gh-json"
}

# Branch-discovery lanes: a task with NO pr= (a no-mistakes run whose PR step
# was skipped) whose PR must be found by its task branch on the origin named
# by the project clone. The clone is a real git repo with only an origin
# remote, exactly what red_pr_task_repo reads.
PROJECT="$TMP_ROOT/project-clone"
make_origin_repo() {
  rm -rf -- "$1"
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "$2"
}

lane_branch() {  # <task> <crew-state line> [branch] - no pr=, project clone as repo
  printf 'working [at=1000]: on it\n' > "$STATE/$1.status"
  {
    printf 'worktree=%s\n' "$TMP_ROOT"
    printf 'project=%s\n' "$PROJECT"
    [ -z "${3:-}" ] || printf 'branch=%s\n' "$3"
  } > "$STATE/$1.meta"
  printf '%s\n' "$2" > "$STATE/$1.crew-state-line"
}

listforge() {  # <json> - the open-PR list the branch discovery reads
  printf '%s\n' "$1" > "$STATE/.gh-list-json"
}

PR3=https://github.com/o/r/pull/21
PRKEY3=https___github.com_o_r_pull_21
DONE_NOIDENT="state: done · source: run-step · run passed: PR state unknown (no PR identity)"
LIST_LANDED_RED='[{"url":"https://github.com/o/r/pull/21","headRefName":"fm/landed","state":"OPEN","isDraft":true,"statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE"}]}]'
LIST_ONE_RED_DRAFT='[{"url":"https://github.com/o/r/pull/21","headRefName":"fm/taska","state":"OPEN","isDraft":true,"statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"FAILURE"}]},{"url":"https://github.com/o/r/pull/22","headRefName":"fm/taskb","state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS"}]}]'

count_wakes() {
  if [ -f "$FM_WAKE_QUEUE" ]; then wc -l < "$FM_WAKE_QUEUE" | tr -d ' '; else printf 0; fi
}

count_forge_reads() {
  if [ -f "$STATE/.gh-calls" ]; then wc -l < "$STATE/.gh-calls" | tr -d ' '; else printf 0; fi
}

test_record_cli_writes_and_reads() {
  reset_case
  "$PICKUP_BIN" record "$PR" owner=alice step='revert the bad commit' eta='2026-11-21T10:00Z' >/dev/null
  [ -f "$STATE/.red-pr-pickup/$PRKEY" ] || fail "record did not create the record file"
  grep -qx "owner=alice" "$STATE/.red-pr-pickup/$PRKEY" || fail "owner line missing"
  grep -qx "step=revert the bad commit" "$STATE/.red-pr-pickup/$PRKEY" || fail "step line missing"
  grep -qx "eta=2026-11-21T10:00Z" "$STATE/.red-pr-pickup/$PRKEY" || fail "eta line missing"
  grep -q "^pr=$PR$" "$STATE/.red-pr-pickup/$PRKEY" || fail "pr line missing"
  [ "$(wc -l < "$STATE/.red-pr-pickup/$PRKEY" | tr -d ' ')" = 5 ] || fail "record is not five lines"
  "$PICKUP_BIN" show "$PR" | grep -qx "owner=alice" || fail "show did not print the record"
  [ "$("$PICKUP_BIN" path "$PR")" = "$STATE/.red-pr-pickup/$PRKEY" ] || fail "path did not print the record path"
  "$PICKUP_BIN" record "$PR" owner=bob step='drive the fix' eta='tomorrow' >/dev/null
  grep -qx "owner=bob" "$STATE/.red-pr-pickup/$PRKEY" || fail "a rewrite did not replace the record"
  grep -qv '^owner=alice$' "$STATE/.red-pr-pickup/$PRKEY" || fail "the old owner survived a rewrite"
  if "$PICKUP_BIN" record "$PR" owner=x step='s' >/dev/null 2>&1; then fail "record without eta was accepted"; fi
  if "$PICKUP_BIN" record "$PR" owner=x eta='e' >/dev/null 2>&1; then fail "record without step was accepted"; fi
  if "$PICKUP_BIN" record "$PR" step='s' eta='e' >/dev/null 2>&1; then fail "record without owner was accepted"; fi
  if "$PICKUP_BIN" record "$PR" owner=$'a\tb' step='s' eta='e' >/dev/null 2>&1; then fail "a tab inside a field was accepted"; fi
  if "$PICKUP_BIN" record "$PR" owner=$'a\nb' step='s' eta='e' >/dev/null 2>&1; then fail "a newline inside a field was accepted"; fi
  if "$PICKUP_BIN" record "$PR" bogus=1 owner=x step='s' eta='e' >/dev/null 2>&1; then fail "an unknown argument was accepted"; fi
  if "$PICKUP_BIN" show "$PR2" >/dev/null 2>&1; then fail "show of an unknown PR succeeded"; fi
  pass "the pickup CLI writes one line per field, rewrites atomically, rejects incomplete or multi-line records, and reads back"
}

test_record_freshness() {
  reset_case
  fm_red_pr_record_write "$STATE" "$PR" alice 'fix the build' '1970-01-01T00:00:00Z' 1000 || fail "record write failed"
  fm_red_pr_record_fresh "$STATE" "$PR" 1000 || fail "a just-written record was not fresh"
  FM_RED_PR_RECORD_STALE_SECS=100 fm_red_pr_record_fresh "$STATE" "$PR" 1099 || fail "a record inside the stale bound was not fresh"
  if FM_RED_PR_RECORD_STALE_SECS=100 fm_red_pr_record_fresh "$STATE" "$PR" 1101; then fail "an unrefreshed past-eta record stayed fresh"; fi
  fm_red_pr_record_write "$STATE" "$PR" alice 'wait for reviewer' '1970-01-01T02:00:00Z' 1000 || fail "record write failed"
  FM_RED_PR_RECORD_STALE_SECS=100 fm_red_pr_record_fresh "$STATE" "$PR" 7000 \
    || fail "a future UTC eta did not hold freshness past the stale bound"
  if FM_RED_PR_RECORD_STALE_SECS=100 fm_red_pr_record_fresh "$STATE" "$PR" 7300; then fail "a passed eta kept the record fresh"; fi
  printf 'pr=%s\nowner=alice\nstep=fix\n' "$PR" > "$STATE/.red-pr-pickup/$PRKEY"
  if FM_RED_PR_RECORD_STALE_SECS=10000 fm_red_pr_record_fresh "$STATE" "$PR" 1000; then fail "an incomplete record counted as ownership"; fi
  rm -f -- "$STATE/.red-pr-pickup/$PRKEY"
  if fm_red_pr_record_fresh "$STATE" "$PR" 1000; then fail "a missing record counted as ownership"; fi
  pass "freshness is refresh-within-bound OR future UTC eta, and incomplete or missing records never own"
}

test_forge_red_is_strict() {
  reset_case
  rm -f "$STATE/.gh-json"
  pr_forge_checks_red "$PR" && st=0 || st=$?
  [ "$st" -eq 2 ] || fail "an unreadable forge read did not return 2"
  forge "$RED"
  pr_forge_checks_red "$PR" || fail "an open PR with a failed check was not red"
  grep -F "pr view $PR" "$STATE/.gh-calls" >/dev/null || fail "the forge was not asked about the named PR"
  forge '{"state":"OPEN","isDraft":true,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"}]}'
  pr_forge_checks_red "$PR" || fail "a red draft PR was not red"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"TIMED_OUT"}]}'
  pr_forge_checks_red "$PR" || fail "a timed-out check was not red"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"CANCELLED"}]}'
  pr_forge_checks_red "$PR" || fail "a cancelled check was not red"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"StatusContext","context":"c","state":"ERROR"}]}'
  pr_forge_checks_red "$PR" || fail "an errored status context was not red"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"StatusContext","context":"c","state":"FAILURE"}]}'
  pr_forge_checks_red "$PR" || fail "a failed status context was not red"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[]}'
  pr_forge_checks_red "$PR" && fail "a PR with no checks counted as red"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"IN_PROGRESS","conclusion":null}]}'
  pr_forge_checks_red "$PR" && fail "a pending check counted as red"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"c","state":"SUCCESS"}]}'
  pr_forge_checks_red "$PR" && fail "an all-green rollup counted as red"
  forge '{"state":"CLOSED","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"FAILURE"}]}'
  pr_forge_checks_red "$PR" && fail "a closed red PR counted as red"
  forge 'not json'
  pr_forge_checks_red "$PR" && st=0 || st=$?
  [ "$st" -eq 2 ] || fail "garbage did not read as unreadable"
  forge "$RED"
  pr_forge_checks_red 'https://gitlab.com/o/r/-/merge_requests/3' && st=0 || st=$?
  [ "$st" -eq 2 ] || fail "another forge did not read as unreadable"
  pr_forge_checks_red 'not a url' && st=0 || st=$?
  [ "$st" -eq 2 ] || fail "a non-URL did not read as unreadable"
  pass "red is an open PR (drafts included) with any failed, timed-out, cancelled or errored check; everything answered else is not red, and no answer is never red"
}

test_ladder_supervisor_main_captain() {
  reset_case
  lane worker "$PARKED" "$PR"
  forge "$RED"
  red_pr_pickup_tick 1000
  [ "$(count_wakes)" = 0 ] || fail "a first-sighting red PR woke before the threshold"
  [ -f "$STATE/.red-pr-pickups" ] || fail "a red PR did not get an episode row"
  [ "$(awk -F '\t' -v k="$PRKEY" '$1==k{print $5}' "$STATE/.red-pr-pickups")" = 0 ] || fail "the first row was not level 0"
  red_pr_pickup_tick 1299
  [ "$(count_wakes)" = 0 ] || fail "the supervisor wake fired before the threshold"
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 1 ] || fail "the supervisor wake did not fire at the threshold"
  case "$RED_PR_PICKUP" in
    "check: red pr pickup overdue: worker $PR red 300s (threshold 300s, crew parked, no owner/step/eta record) - pickup: bin/fm-red-pr-pickup.sh record $PR owner=<owner> step='<next step>' eta='<eta>'") ;;
    *) fail "unexpected level-1 wake: $RED_PR_PICKUP" ;;
  esac
  awk -F '\t' -v k="$PRKEY" '$1==k && $4==1 && $2==1000 && $3==1000 && $5==1300 {found=1} END { exit found?0:1 }' \
    "$STATE/.red-pr-pickups" || fail "the ledger did not record the escalation with the original first red"
  grep -q "red-pr-$PRKEY-l1" "$FM_WAKE_QUEUE" || fail "the level-1 wake was not keyed per PR"
  red_pr_pickup_tick 1599
  [ "$(count_wakes)" = 1 ] || fail "level 2 fired early"
  red_pr_pickup_tick 1600
  [ "$(count_wakes)" = 2 ] || fail "level 2 did not fire at its threshold"
  grep -q "red-pr-$PRKEY-l2" "$FM_WAKE_QUEUE" || fail "the level-2 wake was not keyed per PR"
  red_pr_pickup_tick 2199
  [ "$(count_wakes)" = 2 ] || fail "level 3 fired early"
  red_pr_pickup_tick 2200
  [ "$(count_wakes)" = 3 ] || fail "level 3 did not fire at its threshold"
  case "$RED_PR_PICKUP" in
    "check: red pr abandoned: worker $PR red 1200s (threshold 1200s, crew parked) - CAPTAIN-FACING: no pickup record survived the supervisor and main wakes; surface this PR to the captain now") ;;
    *) fail "unexpected level-3 wake: $RED_PR_PICKUP" ;;
  esac
  grep -q "red-pr-$PRKEY-l3" "$FM_WAKE_QUEUE" || fail "the level-3 wake was not keyed per PR"
  red_pr_pickup_tick 2210
  [ "$(count_wakes)" = 3 ] || fail "the ladder repeated before the recheck cadence"
  red_pr_pickup_tick 12200
  [ "$(count_wakes)" = 4 ] || fail "the ladder did not repeat on the recheck cadence"
  pass "the ladder walks supervisor, main then captain on exact per-PR keys, once per level, repeating only per the recheck cadence"
}

test_record_silences_and_stale_reescalates() {
  reset_case
  lane worker "$PARKED" "$PR"
  forge "$RED"
  red_pr_pickup_tick 1000
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 1 ] || fail "level 1 did not fire"
  fm_red_pr_record_write "$STATE" "$PR" alice 'revert the bad commit' '1970-01-01T00:00:00Z' 1300 \
    || fail "record write failed"
  red_pr_pickup_tick 1310
  [ "$(count_wakes)" = 1 ] || fail "a fresh record still woke"
  awk -F '\t' -v k="$PRKEY" '$1==k && $3==0 && $4==0 {found=1} END { exit found?0:1 }' "$STATE/.red-pr-pickups" \
    || fail "a fresh record did not mark the row owned"
  awk -F '\t' -v k="$PRKEY" '$1==k && $2==1000 {found=1} END { exit found?0:1 }' "$STATE/.red-pr-pickups" \
    || fail "a fresh record lost the first-red age"
  red_pr_pickup_tick 2000
  [ "$(count_wakes)" = 1 ] || fail "a fresh record woke on a later scan"
  fm_red_pr_record_write "$STATE" "$PR" alice 'still on it' '1970-01-01T00:00:00Z' 100 || true
  red_pr_pickup_tick 2100
  awk -F '\t' -v k="$PRKEY" '$1==k && $3==2100 && $4==0 {found=1} END { exit found?0:1 }' "$STATE/.red-pr-pickups" \
    || fail "a stale record did not restart the missing clock"
  [ "$(count_wakes)" = 1 ] || fail "a stale record escalated instantly"
  red_pr_pickup_tick 2400
  [ "$(count_wakes)" = 2 ] || fail "a stale record did not re-escalate from level 1"
  [ "$(grep -c "red-pr-$PRKEY-l1" "$FM_WAKE_QUEUE")" = 2 ] || fail "the re-escalation was not a fresh level-1 wake"
  pass "a fresh record owns the PR and keeps its age; a stale record re-walks the ladder from level 1"
}

test_scope_and_episode_reset() {
  reset_case
  lane donelane "$DONE" https://github.com/o/r/pull/9
  lane paused 'state: paused · source: status-log · paused: waiting [until 2030-01-01T00:00Z]' https://github.com/o/r/pull/10
  lane worker "$PARKED" "$PR"
  lane working "$WORKING" "$PR2"
  forge "$RED"
  red_pr_pickup_tick 1000
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 2 ] || fail "done or paused lanes were scanned as pickup candidates"
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 2 ] || fail "the two in-scope PRs did not wake"
  [ "$(grep -c "red-pr-$PRKEY2-l1" "$FM_WAKE_QUEUE")" = 1 ] || fail "a working lane's red PR did not demand a record"
  grep -q "crew working" "$FM_WAKE_QUEUE" || fail "the wake did not name the crew state"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  red_pr_pickup_tick 6000
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 0 ] || fail "a green answer did not end the episode"
  forge "$RED"
  red_pr_pickup_tick 6100
  red_pr_pickup_tick 6400
  [ "$(grep -c "red-pr-$PRKEY2-l1" "$FM_WAKE_QUEUE")" = 2 ] || fail "a re-reddened PR did not start a fresh episode"
  pass "done and paused lanes are out of scope, working lanes still need a record, and a green answer ends the episode"
}

test_secondmate_lanes_and_remote_mates() {
  reset_case
  forge "$RED"
  lane mate "$PARKED" "$PR" secondmate
  red_pr_pickup_tick 1000
  red_pr_pickup_tick 5000
  [ "$(count_wakes)" = 0 ] || fail "a secondmate lane's own pr= woke as a main task"
  [ ! -s "$STATE/.red-pr-pickups" ] || fail "a secondmate lane without a home got a row"
  printf 'remote_host=elsewhere\nhome=/nope\n' >> "$STATE/mate.meta"
  red_pr_pickup_tick 6000
  [ ! -s "$STATE/.red-pr-pickups" ] || fail "a remote mate was scanned through its home"
  [ ! -e "$STATE/.stub-calls" ] || fail "a secondmate lane paid a crew-state read"
  pass "secondmate lanes never count as main tasks and remote mates are left to their host"
}

test_mate_home_backstop() {
  reset_case
  MATEHOME="$TMP_ROOT/matehome"
  rm -rf -- "$MATEHOME"
  mkdir -p "$MATEHOME/state"
  printf 'mate\n' > "$MATEHOME/.fm-secondmate-home"
  lane mate "state: working · source: run-step · supervising" '' secondmate
  printf 'home=%s\n' "$MATEHOME" >> "$STATE/mate.meta"
  printf 'worktree=%s\nkind=ship\npr=%s\n' "$MATEHOME" "$PR" > "$MATEHOME/state/worker.meta"
  printf '%s\n' "$PARKED" > "$MATEHOME/state/worker.crew-state-line"
  printf 'worktree=%s\nkind=secondmate\npr=%s\n' "$MATEHOME" "$PR2" > "$MATEHOME/state/nested.meta"
  forge "$RED"
  red_pr_pickup_tick 1000
  awk -F '\t' -v k="$PRKEY" '$1==k && $2==1000 {found=1} END { exit found?0:1 }' \
    "$STATE/.red-pr-pickups" || fail "a mate home's red worker PR did not get an episode row"
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 1 ] || fail "a nested secondmate lane inside the mate home was scanned"
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 0 ] || fail "level 1 woke main for a mate-owned PR"
  [ -f "$STATE/.red-pr-ring-$PRKEY" ] || fail "the level-1 ring attempt was not marked"
  red_pr_pickup_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "level 2 did not wake main for a mate-owned PR"
  case "$RED_PR_PICKUP" in
    "check: red pr unpicked after supervisor wake: mate=mate (worker worker) $PR red 600s (threshold 600s) - no pickup record in the mate's home; steer the mate or record for it: bin/fm-red-pr-pickup.sh record $PR owner=<owner> step='<next step>' eta='<eta>' (in the mate's home)") ;;
    *) fail "unexpected mate level-2 wake: $RED_PR_PICKUP" ;;
  esac
  grep -q "red-pr-$PRKEY-l2" "$FM_WAKE_QUEUE" || fail "the mate level-2 wake was not keyed per PR"
  fm_red_pr_record_write "$MATEHOME/state" "$PR" worker 'fix the build' '1970-01-01T00:00:00Z' 1600 \
    || fail "mate-home record write failed"
  red_pr_pickup_tick 1610
  red_pr_pickup_tick 2000
  [ "$(count_wakes)" = 1 ] || fail "a mate-home record did not silence the backstop"
  printf 'nope\n' > "$MATEHOME/.fm-secondmate-home"
  red_pr_pickup_tick 2400
  [ "$(count_wakes)" = 1 ] || fail "a home whose marker names another mate kept waking"
  pass "a local secondmate home's red PRs escalate through a ring, a main wake naming the mate, and a record in the mate's home"
}

test_unreadable_forge_keeps_the_episode() {
  reset_case
  lane worker "$PARKED" "$PR"
  forge "$RED"
  red_pr_pickup_tick 1000
  rm -f "$STATE/.gh-json"
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 0 ] || fail "an unreadable forge woke"
  awk -F '\t' -v k="$PRKEY" '$1==k && $3==1000 {found=1} END { exit found?0:1 }' "$STATE/.red-pr-pickups" \
    || fail "an unreadable forge advanced the missing clock"
  forge "$RED"
  red_pr_pickup_tick 1600
  [ "$(count_wakes)" = 1 ] || fail "a readable scan did not resume the episode"
  grep -q "red-pr-$PRKEY-l2" "$FM_WAKE_QUEUE" || fail "a resumed 600s-old episode did not escalate to main"
  forge '{"state":"OPEN","isDraft":false,"statusCheckRollup":[{"__typename":"CheckRun","name":"a","status":"COMPLETED","conclusion":"SUCCESS"}]}'
  red_pr_pickup_tick 1700
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 0 ] || fail "a green answer after an outage did not end the episode"
  pass "an unreadable forge keeps the episode frozen without waking or forgiving, and the next answer resolves it"
}

test_scan_throttle_and_joined_wake() {
  reset_case
  lane one "$PARKED" "$PR"
  lane two "state: parked · source: run-step · parked at ci · pr: $PR2" "$PR2"
  forge "$RED"
  RED_PR_PICKUP_SCAN_SECS=300
  red_pr_pickup_tick 1000
  red_pr_pickup_tick 1299
  [ "$(wc -l < "$STATE/.stub-calls" | tr -d ' ')" = 2 ] || fail "the scan ran inside its interval"
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 2 ] || fail "two due PRs did not queue their exact keys"
  grep -q "red-pr-$PRKEY-l1" "$FM_WAKE_QUEUE" || fail "the first PR key is missing"
  grep -q "red-pr-$PRKEY2-l1" "$FM_WAKE_QUEUE" || fail "the second PR key is missing"
  RED_PR_PICKUP_SCAN_SECS=0
  pass "the scan runs once per interval and due PRs wake on exact per-PR keys"
}

test_watcher_loop() {
  local dir="$TMP_ROOT/watcher-loop" pid i=0 now key
  mkdir -p "$dir/state" "$dir/config"
  fm_test_track_watcher_state "$dir/state"
  touch "$dir/state/home-summary.json"
  printf 'working [at=1000]: on it\n' > "$dir/state/worker.status"
  printf 'worktree=%s\nkind=ship\npr=%s\n' "$dir" "$PR" > "$dir/state/worker.meta"
  printf '%s\n' "$PARKED" > "$dir/state/worker.crew-state-line"
  printf '%s\n' "$RED" > "$dir/state/.gh-json"
  # An episode an earlier watcher left behind: the SLA clock survives a restart,
  # and a restart that finds the ladder already due still escalates.
  now=$(date +%s)
  key="$PRKEY"
  printf '%s\t%s\t%s\t0\t0\n' "$key" "$((now - 400))" "$((now - 400))" > "$dir/state/.red-pr-pickups"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_CREW_STATE_BIN="$STUB" \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/out" 2> "$dir/err" &
  pid=$!
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "real watcher failed to wake on an overdue red PR"
  fi
  wait "$pid" || fail "real watcher exited unsuccessfully: $(cat "$dir/err")"
  grep -E "check: red pr pickup overdue: worker $PR red 4[0-9][0-9]s \\(threshold 300s" "$dir/out" >/dev/null \
    || fail "real watcher did not print the pickup wake: $(cat "$dir/out")"
  grep -q "red-pr-$key-l1" "$dir/state/.wake-queue" \
    || fail "real watcher did not durably queue the pickup wake"
  pass "the actual watcher wakes and exits on an overdue red PR, keeping the clock across a restart"
}

test_branch_discovery_no_pr_meta() {
  reset_case
  make_origin_repo "$PROJECT" https://github.com/o/r.git
  lane_branch taska "$PARKED"            # no branch= -> default fm/<task-id>
  lane_branch taskb "$WORKING" fm/taskb  # recorded branch
  printf 'worktree=%s\n' "$TMP_ROOT" > "$STATE/norepo.meta"  # no repo identity
  printf '%s\n' "$WORKING" > "$STATE/norepo.crew-state-line"
  listforge "$LIST_ONE_RED_DRAFT"
  red_pr_pickup_tick 1000
  [ -f "$STATE/.red-pr-pickups" ] || fail "a red branch-matched PR got no episode row"
  awk -F '\t' -v k="$PRKEY3" '$1==k && $2==1000 && $3==1000 && $6=="github.com/o/r" {found=1} END { exit found?0:1 }' \
    "$STATE/.red-pr-pickups" || fail "the discovered draft PR row lacks first red or repo column"
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 1 ] \
    || fail "taska and taskb did not share the single discovered PR"
  [ "$(grep -c 'pr list' "$STATE/.gh-calls")" = 1 ] \
    || fail "two tasks on one repo did not share one bounded list read"
  [ "$(grep -c 'pr view' "$STATE/.gh-calls")" = 0 ] \
    || fail "a branch-discovered red PR was re-read through pr view"
  [ -f "$STATE/.red-pr-pickups-skip" ] || fail "a task with no repo identity was skipped without a reason"
  grep -q "^norepo"$'\t\t'"no forge repository identity" "$STATE/.red-pr-pickups-skip" \
    || fail "the skip reason did not name the task and its cause"
  grep -q "^epoch=1000$" "$STATE/.red-pr-pickups-skip" || fail "the skip file does not carry the scan epoch"
  if [ -f "$STATE/.stub-calls" ] && grep -q '^norepo ' "$STATE/.stub-calls"; then
    fail "a skipped task paid a crew-state read"
  fi
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 1 ] || fail "the discovered red PR did not wake at the threshold"
  case "$RED_PR_PICKUP" in
    "check: red pr pickup overdue: taska $PR3 red 300s (threshold 300s, crew parked, no owner/step/eta record) - pickup: bin/fm-red-pr-pickup.sh record $PR3 owner=<owner> step='<next step>' eta='<eta>'") ;;
    *) fail "unexpected branch-discovery wake: $RED_PR_PICKUP" ;;
  esac
  red_pr_pickup_tick 1301
  [ "$(grep -c 'pr list' "$STATE/.gh-calls")" = 3 ] \
    || fail "a new scan did not get exactly one fresh bounded list read"
  pass "a meta without pr= is discovered by its task branch: one bounded list read per repo per scan, red drafts count, no repo is a recorded skip"
}

test_done_lane_with_open_red_pr() {
  reset_case
  make_origin_repo "$PROJECT" https://github.com/o/r.git
  lane_branch landed "$DONE_NOIDENT"
  listforge "$LIST_LANDED_RED"
  red_pr_pickup_tick 1000
  [ -f "$STATE/.red-pr-pickups" ] || fail "a done lane's open red PR (run passed, no PR identity) got no row"
  awk -F '\t' -v k="$PRKEY3" '$1==k && $2==1000 {found=1} END { exit found?0:1 }' \
    "$STATE/.red-pr-pickups" || fail "the done lane's row is missing its episode fields"
  red_pr_pickup_tick 1300
  [ "$(count_wakes)" = 1 ] || fail "a done lane's unowned red PR did not wake"
  case "$RED_PR_PICKUP" in "check: red pr pickup overdue: landed $PR3 red 300s (threshold 300s, crew done,"*) ;;
    *) fail "unexpected done-lane wake: $RED_PR_PICKUP" ;; esac
  # the same done lane whose PR left the open list (merged or closed) is out
  listforge '[]'
  red_pr_pickup_tick 1600
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 0 ] \
    || fail "a done lane whose PR merged kept its episode row"
  [ "$(count_wakes)" = 1 ] || fail "a merged PR kept escalating"
  pass "a done lane with no PR identity counts exactly while its matched PR is open and red"
}

test_branch_merged_drops_episode() {
  reset_case
  make_origin_repo "$PROJECT" https://github.com/o/r.git
  lane_branch taska "$PARKED"
  listforge "$LIST_ONE_RED_DRAFT"
  red_pr_pickup_tick 1000
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 1 ] || fail "the branch episode did not start"
  listforge '[]'
  red_pr_pickup_tick 1300
  [ "$(awk 'END { print NR }' "$STATE/.red-pr-pickups")" = 0 ] \
    || fail "a merged branch PR did not drop its episode row"
  [ "$(count_wakes)" = 0 ] || fail "a merged branch PR still woke"
  listforge "$LIST_ONE_RED_DRAFT"
  red_pr_pickup_tick 2000
  red_pr_pickup_tick 2300
  awk -F '\t' -v k="$PRKEY3" '$1==k && $2==2000 {found=1} END { exit found?0:1 }' \
    "$STATE/.red-pr-pickups" || fail "a re-reddened branch PR did not start a fresh episode"
  [ "$(count_wakes)" = 1 ] || fail "a fresh branch episode did not wake at its own threshold"
  pass "a merged or closed branch PR ends its episode and a re-reddened branch starts fresh"
}

test_unreadable_list_freezes_branch_episodes() {
  reset_case
  make_origin_repo "$PROJECT" https://github.com/o/r.git
  lane_branch taska "$PARKED"
  listforge "$LIST_ONE_RED_DRAFT"
  red_pr_pickup_tick 2000
  red_pr_pickup_tick 2300
  [ "$(count_wakes)" = 1 ] || fail "setup: level 1 did not fire"
  rm -f "$STATE/.gh-list-json"
  red_pr_pickup_tick 2400
  red_pr_pickup_tick 3000
  [ "$(count_wakes)" = 1 ] || fail "an unreadable open list woke"
  awk -F '\t' -v k="$PRKEY3" '$1==k && $2==2000 && $3==2000 && $4==1 {found=1} END { exit found?0:1 }' \
    "$STATE/.red-pr-pickups" \
    || fail "an unreadable list did not keep the episode row frozen with its clock"
  listforge "$LIST_ONE_RED_DRAFT"
  red_pr_pickup_tick 3100
  [ "$(count_wakes)" = 2 ] || fail "a resumed branch episode did not escalate"
  grep -q "red-pr-$PRKEY3-l2" "$FM_WAKE_QUEUE" \
    || fail "the resumed episode did not escalate to main with its full first-red age"
  pass "an unreadable open-list read freezes every branch episode row it owns without waking or forgiving"
}

fm_test_run test_record_cli_writes_and_reads test_record_freshness test_forge_red_is_strict \
  test_ladder_supervisor_main_captain test_record_silences_and_stale_reescalates \
  test_scope_and_episode_reset test_secondmate_lanes_and_remote_mates test_mate_home_backstop \
  test_unreadable_forge_keeps_the_episode test_scan_throttle_and_joined_wake test_watcher_loop \
  test_branch_discovery_no_pr_meta test_done_lane_with_open_red_pr \
  test_branch_merged_drops_episode test_unreadable_list_freezes_branch_episodes
