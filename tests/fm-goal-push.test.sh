#!/usr/bin/env bash
# Lab-only goal automation: every launch endpoint is replaced by a recorder.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot fm-goal-push)
H=$T/home
mkdir -p "$H/config" "$H/state" "$H/data" "$H/projects/demo"
export FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config"
export FM_DATA_OVERRIDE="$H/data" FM_PROJECTS_OVERRIDE="$H/projects"
unset FM_TASK_ID
G=$ROOT/bin/fm-goal.sh P=$ROOT/bin/fm-goal-push.sh Q=$ROOT/bin/fm-admission-queue.sh
export FM_GOAL_PUSH_CAPACITY="$T/capacity" FM_AUTODISPATCH_READY="$T/ready"
export FM_AUTODISPATCH_DISPATCH="$T/dispatch" FM_ADMISSION_DISPATCH="$T/dispatch"
export FM_ADMISSION_SPAWN="$T/spawn" FM_AUTODISPATCH_PROJECT_MODE="$T/project-mode"
export FM_CREW_STATE_BIN="$T/crew" QUEUE_CMD="$Q" LAB="$T"

# Every redirected target below is in a fresh private fixture directory.
cat > "$T/capacity" <<'SH'
#!/usr/bin/env bash
[ "$1" = --start-budget ] || exit 2
cat "$LAB/budget"
SH
cat > "$T/ready" <<'SH'
#!/usr/bin/env bash
[ "$1" = ready ] || exit 2
cat "$LAB/ready.csv"
SH
cat > "$T/dispatch" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$LAB/dispatch.log"
if [ -f "$LAB/hold-$2" ]; then
  "$QUEUE_CMD" add "$2" --reason 'lab admission hold' -- "$2" "$3"
  exit 75
fi
printf 'kind=ship\n' > "$FM_STATE_OVERRIDE/$2.meta"
SH
cat > "$T/spawn" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$LAB/spawn.log"
printf 'kind=ship\n' > "$FM_STATE_OVERRIDE/$1.meta"
SH
cat > "$T/project-mode" <<'SH'
#!/usr/bin/env bash
printf 'direct-PR off\n'
SH
cat > "$T/crew" <<'SH'
#!/usr/bin/env bash
if [ -f "$LAB/done-$1" ]; then printf 'state: done\n'; else printf 'state: working\n'; fi
SH
chmod +x "$T/"{capacity,ready,dispatch,spawn,project-mode,crew}

capacity() {
  printf '%s\n' "$1" > "$T/budget"
}
start() {
  "$G" start "$1" --title "$1" --named-by lab --plan plan.md --done-when 'done' --items-file "$T/$1.items" >/dev/null
}
brief() {
  mkdir -p "$H/data/$1"
  printf 'Delivery contract: mode=direct-PR\nShip branch: fm/%s\n' "$1" > "$H/data/$1/brief.md"
  printf '%s,queued,ship,demo,Test brief\n' "$1" >> "$T/ready.csv"
}

for id in one two three four captain blocked off held mate unrelated; do brief "$id"; done
printf '%s\n' \
  'item [id=one] [owner=main] [task=one]: start first' \
  'item [id=two] [owner=main] [task=two]: start second' \
  'item [id=three] [owner=main] [task=three]: start third' \
  'item [id=four] [owner=main] [task=four]: start later' \
  'item [id=captain] [owner=main] [class=captain] [task=captain]: human only' \
  'item [id=blocked] [owner=main] [task=blocked] [after=four]: dependency' \
  'item [id=mate] [owner=mate1] [task=mate]: nonlocal owner' \
  'item [id=missing-a] [owner=main]: needs brief' \
  'item [id=missing-b] [owner=main]: needs brief' \
  'item [id=missing-task] [owner=main] [task=missing-task]: orphan' \
  'item [id=wait] [owner=main]: stale wait' > "$T/on.items"
printf '%s\n' 'item [id=off] [owner=main] [task=off]: switched off' > "$T/off.items"
printf '%s\n' 'item [id=held] [owner=main] [task=held]: held by admission' > "$T/hold.items"
start on; start off; start hold
"$G" pause off >/dev/null
"$G" pause hold >/dev/null
"$G" mark on missing-task running -- 'lost worker' >/dev/null
printf 'goal [goal=on] [item=wait] [state=waiting] [at=%s]: no target\n' "$(( $(date +%s) - 1900 ))" >> "$H/state/goals/on.marks"
capacity 3
before=$(cksum "$H/state/goals/on.marks" "$H/state/goals/off.goal")
"$P" run
assert_equals "$before" "$(cksum "$H/state/goals/on.marks" "$H/state/goals/off.goal")" 'shadow does not mutate goal records'
assert_absent "$T/dispatch.log" 'shadow does not dispatch'
assert_absent "$T/spawn.log" 'shadow does not replay admissions'
assert_absent "$H/state/.wake-queue" 'shadow does not wake the owner'
assert_grep 'shadow mark on/missing-task open' "$H/state/goal-push.log" 'shadow would reconcile'
assert_grep 'shadow start on/one (one)' "$H/state/goal-push.log" 'shadow would route'
assert_grep 'shadow goal wait is stale: on/wait' "$H/state/goal-push.log" 'shadow would flag stale wait'
pass 'shadow logs proposals and leaves records, wakes and launch calls unchanged'

printf 'enforce\n' > "$H/config/goal-push"
capacity 0
"$P" run
assert_absent "$T/dispatch.log" 'zero capacity budget holds starts'
assert_grep 'hold on/one (one): no remaining start headroom' "$H/state/goal-push.log" 'headroom block is visible'
capacity 3
"$P" run --dry-run
assert_absent "$T/dispatch.log" 'dry-run takes precedence over enforce'
"$P" run
expected=$(printf 'new %s %s --wait --mode direct-PR --yolo off\n' one "$H/projects/demo" two "$H/projects/demo" three "$H/projects/demo")
assert_equals "$expected" "$(<"$T/dispatch.log")" 'only three owner-local eligible calls reach real dispatch front door stub'
assert_equals running "$("$G" export on | jq -r '.goals[0].items[] | select(.id == "one").state')" 'started item is marked running'
assert_equals open "$("$G" export on | jq -r '.goals[0].items[] | select(.id == "missing-task").state')" 'orphan reopens'
assert_absent "$H/state/goals/off.marks" 'OFF goal never gets a mark'
assert_equals 1 "$(grep -c 'goal briefs needed:.*on/missing-a.*on/missing-b' "$H/state/.wake-queue")" 'missing briefs are asked in one deduped batch'
assert_equals 1 "$(grep -c 'goal wait is stale: on/wait' "$H/state/.wake-queue")" 'stale wait is asked once'
pass 'enforce starts only startable ON drive items, observes headroom and caps starts at three'

# Publish the same canonical landing event as the PR watcher in the lab.
pr='https://github.com/example/demo/pull/1'
printf 'kind=ship\npr=%s\n' "$pr" >> "$H/state/one.meta"
bash -c '. "$1"; fm_pr_url_parse "$2" && fm_pr_poll_merge_mark_notified "$FM_STATE_OVERRIDE" one "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"' \
  _ "$ROOT/bin/fm-pr-lib.sh" "$pr"
capacity 0
"$P" tick
assert_equals running "$("$G" export on | jq -r '.goals[0].items[] | select(.id == "one").state')" 'landing does not close a live worker'
: > "$T/done-one"
printf 'done [at=%s]: full local task proof\n' "$(date +%s)" > "$H/state/one.status"
"$P" tick
assert_equals "$pr" "$("$G" export on | jq -r '.goals[0].items[] | select(.id == "one" and .state == "done").pr')" 'done plus canonical landing closes the item'
pass 'landing and terminal status events reconcile a running item using its bound PR'

capacity 3
"$G" pause on >/dev/null
"$G" resume hold >/dev/null
: > "$T/hold-held"
"$P" tick
assert_grep 'new held ' "$T/dispatch.log" 'switch event triggers immediate pass'
"$G" pause hold >/dev/null
"$Q" retry --max-starts 3
"$P" tick
assert_absent "$T/spawn.log" 'pausing stops scoped replay; generic retry cannot bypass goal gate'
"$G" resume hold >/dev/null
"$P" tick
assert_equals "held $H/projects/demo" "$(<"$T/spawn.log")" 'resuming replays held task through admission'
assert_equals 4 "$(wc -l < "$T/dispatch.log" | tr -d ' ')" 'OFF stops additional starts, with no second dispatch for the hold'
pass 'switch events and held queue replay preserve OFF safety'

# A local mate consumes the parent view and publishes marks via its own stream.
M=$T/mate
mkdir -p "$M/config" "$M/state" "$M/data/mate-task" "$M/projects/demo"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$M/.fm-secondmate-parent"
printf 'mate1\n' > "$M/.fm-secondmate-home"
printf 'enforce\n' > "$M/config/goal-push"
printf 'Delivery contract: mode=direct-PR\nShip branch: fm/mate-task\n' > "$M/data/mate-task/brief.md"
printf 'mate-task,queued,ship,demo,Local mate test\n' >> "$T/ready.csv"
printf '%s\n' 'item [id=mate] [owner=mate1] [task=mate-task]: mate owns this' > "$T/mategoal.items"
start mategoal
FM_HOME="$M" FM_STATE_OVERRIDE="$M/state" FM_CONFIG_OVERRIDE="$M/config" FM_DATA_OVERRIDE="$M/data" \
  FM_PROJECTS_OVERRIDE="$M/projects" "$P" tick
assert_grep "new mate-task $M/projects/demo --wait" "$T/dispatch.log" 'mate dispatch uses its own project clone'
assert_grep '[goal=mategoal] [item=mate] [state=running]' "$H/state/mate1.status" 'mate marks the item via the parent channel'
assert_absent "$M/state/goals/mategoal.marks" 'mate never creates a second goal record'
pass 'local mate uses the parent goal view, its own dispatcher, and the parent mark channel'
echo '# all fm-goal-push tests passed'
