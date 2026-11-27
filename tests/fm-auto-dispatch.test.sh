#!/usr/bin/env bash
# fm-auto-dispatch.sh: a queued startable ON-goal brief with no hold or record
# is dispatched once config/auto-dispatch enforces; every other row waits for
# firstmate, and a dispatch that does not start or hold is parked with one wake
# row, never retried blind.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-auto-dispatch)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/projects/firstmate"
trap 'rm -rf "$TMP_ROOT"' EXIT
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects"
AD="$ROOT/bin/fm-auto-dispatch.sh"

# Fake the `ready` listing and the dispatch/registry commands; both record what
# they were asked to do so assertions never read agent prose.
READY_LIST="$TMP_ROOT/ready-list"
: > "$READY_LIST"
cat > "$TMP_ROOT/ready-fake" <<SH
#!/usr/bin/env bash
[ "\$1" = ready ] || exit 2
cat "$READY_LIST"
SH
chmod +x "$TMP_ROOT/ready-fake"
DISPATCH_ARGS="$TMP_ROOT/dispatch-args"
DISPATCH_MODE="$TMP_ROOT/dispatch-mode"
printf 'start\n' > "$DISPATCH_MODE"
: > "$DISPATCH_ARGS"
cat > "$TMP_ROOT/dispatch-fake" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DISPATCH_ARGS"
case "\$(cat "$DISPATCH_MODE")" in
  start) printf 'dispatched\n'; exit 0 ;;
  spawn-hold) printf 'held by spawn admission\n'; exit 75 ;;
  weekly-hold) printf 'status: held: the weekly start guard kept it queued\n'; exit 3 ;;
  captain-pick)
    printf 'status: captain-pick: no override answers the request\npick: one-of: use the repo standard prefix\n'; exit 3 ;;
  error) printf 'fm-dispatch: brief unreadable\n'; exit 1 ;;
  race) printf 'x' > "\$FM_STATE_OVERRIDE/t1.meta"; printf 'dispatched\n'; exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/dispatch-fake"
cat > "$TMP_ROOT/project-mode-fake" <<'SH'
#!/usr/bin/env bash
printf 'direct-PR off\n'
SH
chmod +x "$TMP_ROOT/project-mode-fake"
AD_ENV=(FM_AUTODISPATCH_READY="$TMP_ROOT/ready-fake" FM_AUTODISPATCH_DISPATCH="$TMP_ROOT/dispatch-fake"
  FM_AUTODISPATCH_PROJECT_MODE="$TMP_ROOT/project-mode-fake")

# A standard crewmate ship brief: contract, ship branch, base branch.
brief() {  # <id> [extra brief lines...]
  local id=$1
  shift
  mkdir -p "$HOME_DIR/data/$id"
  printf 'You are a crewmate.\nDelivery contract: mode=direct-PR\nShip branch: fm/%s\nBase branch: main\n%s\n' \
    "$id" "$*" > "$HOME_DIR/data/$id/brief.md"
}
scout_brief() {  # <id>
  local id=$1
  mkdir -p "$HOME_DIR/data/$id"
  printf 'This is a SCOUT task: the deliverable is a written report, not a PR.\n' > "$HOME_DIR/data/$id/brief.md"
}

# --- verdicts: what may be dispatched without a firstmate turn ---------------
brief t1
brief nobrief
rm -rf "$HOME_DIR/data/nobrief"
brief placeholders
printf 'Do {TASK} then {FILL: this in}.\n' >> "$HOME_DIR/data/placeholders/brief.md"
brief started
printf 'kind=ship\n' > "$HOME_DIR/state/started.meta"
brief mate-charter
scout_brief sc1
printf '%s\n' \
  'ready[7]{' \
  't1,queued,ship,firstmate,Write the feature' \
  'nobrief,queued,ship,firstmate,No brief yet' \
  'placeholders,queued,ship,firstmate,Half written' \
  'started,queued,ship,firstmate,Raced with firstmate' \
  'mate-charter,queued,secondmate,firstmate,A secondmate charter' \
  'sm2,queued,captain,firstmate,A captain row' \
  'sc1,queued,scout,firstmate,Scout it' \
  'help[1]: fm-tasks-axi.sh show <id>' > "$READY_LIST"
out=$(env "${AD_ENV[@]}" "$AD" list)
line=$(printf '%s\n' "$out" | grep '^t1 ')
assert_contains "$line" 'start '"$HOME_DIR"'/projects/firstmate --mode direct-PR --yolo off' 'a ready ship with a written brief is a start verdict'
assert_not_contains "$line" '--branch-prefix' 'the standard fm/<id> branch needs no prefix flag'
assert_contains "$out" 'sc1 start '"$HOME_DIR"'/projects/firstmate --scout' 'a SCOUT brief dispatches with --scout'
assert_contains "$out" 'nobrief skip: no written brief' 'a row without a brief is never dispatched'
assert_contains "$out" 'placeholders skip: brief still has placeholders' 'a scaffold with placeholders waits'
assert_contains "$out" 'started skip: already started' 'a row with a task record is live work'
assert_contains "$out" 'mate-charter skip: secondmate-class row' 'a secondmate row is never dispatched'
assert_contains "$out" 'sm2 skip: captain-class row' 'a captain-class row is never dispatched'
pass 'verdicts: ready rows are classified; held, captain and secondmate rows wait'
mkdir -p "$HOME_DIR/state/admission-queue"
printf 'pending\n' > "$HOME_DIR/state/admission-queue/t1.start"
printf 'PR start: review https://github.com/example/project/pull/1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >> "$HOME_DIR/data/sc1/brief.md"
out=$(env "${AD_ENV[@]}" "$AD" list)
assert_contains "$out" 't1 skip: admission queue owns start' 'async requests must not be redispatched'
assert_contains "$out" '--scout --merge-review' 'known review template must retain reserved allowance'
rm -f "$HOME_DIR/state/admission-queue/t1.start"
pass 'pending requests have one owner and review templates retain reserved capacity'

# A custom ship branch passes the prefix the brief recorded; a branch that is
# not <prefix>/<id> parks instead of guessing; a clone that is missing waits.
brief custom
sed -i 's/^Ship branch: fm\/custom$/Ship branch: fix\/custom/' "$HOME_DIR/data/custom/brief.md"
brief oddbranch
sed -i 's/^Ship branch: fm\/oddbranch$/Ship branch: feature-xyz/' "$HOME_DIR/data/oddbranch/brief.md"
brief noclone
printf '%s\n' 'custom,queued,ship,firstmate,Custom prefix' 'oddbranch,queued,ship,firstmate,Odd branch' \
  'noclone,queued,ship,other-repo,Missing clone' > "$READY_LIST"
out=$(env "${AD_ENV[@]}" "$AD" list)
line=$(printf '%s\n' "$out" | grep '^custom ')
assert_contains "$line" '--branch-prefix fix/' 'a custom prefix is passed through'
assert_contains "$out" 'oddbranch skip: ship branch feature-xyz does not end in the task id' 'an unrelatable branch refuses to guess'
assert_contains "$out" 'noclone skip: no project clone for other-repo' 'a row whose clone is missing waits for fleet-sync'
pass 'verdicts: branch prefixes pass through and broken or missing inputs wait'

# --- off, shadow, enforce -----------------------------------------------------
assert_equals '' "$("$AD" check)" 'without config/auto-dispatch the check prints nothing'
err=$("$AD" run 2>&1) && fail 'run must refuse while the mode is off'
assert_contains "$err" 'enforce mode' 'the refusal names the mode'
printf 'shadow\n' > "$HOME_DIR/config/auto-dispatch"
printf '%s\n' 't1,queued,ship,firstmate,Write the feature' 'nobrief,queued,ship,firstmate,No brief yet' > "$READY_LIST"
out=$(env "${AD_ENV[@]}" "$AD" check)
assert_contains "$out" 'auto-dispatch (shadow, nothing started): 1 dispatchable row(s): t1 start' 'shadow reports once and names the dispatchable rows'
assert_equals '' "$(env "${AD_ENV[@]}" "$AD" check)" 'an unchanged candidate set does not wake again'
assert_equals '' "$(cat "$DISPATCH_ARGS" 2>/dev/null)" 'shadow dispatches nothing'
pass 'off refuses to run, shadow reports a changed set once and dispatches nothing'

# --- run: outcomes, pacing, parking ------------------------------------------
# Every phase below lists exactly one row, so the default one-dispatch-per-pass
# bound puts its outcome on that row.
printf 'enforce\n' > "$HOME_DIR/config/auto-dispatch"
: > "$DISPATCH_ARGS"
GOAL="$ROOT/bin/fm-goal.sh"
goal_start() {
  "$GOAL" start "$1" --title 'Fixture goal' --done-when 'fixture done' \
    --named-by 'exercise auto-dispatch' --plan plan.md --items-file "$TMP_ROOT/items"
}
printf '%s\n' 'item [id=linked] [owner=main]: drive a queued brief' \
  'item [id=dependent] [owner=main] [task=dep] [after=linked]: wait on a dependency' \
  'item [id=mate] [owner=miko] [task=mate-job]: drive in the owner home' > "$TMP_ROOT/items"
goal_start enabled >/dev/null || fail 'could not create enabled goal'
"$GOAL" mark enabled linked open --task t1 -- 'brief ready' >/dev/null || fail 'could not link t1'
printf '%s\n' 'item [id=paused] [owner=main] [task=paused-job]: do not start' > "$TMP_ROOT/items"
goal_start disabled >/dev/null || fail 'could not create disabled goal'
"$GOAL" pause disabled >/dev/null || fail 'could not turn goal OFF'
for id in unlinked paused-job dep mate-job; do brief "$id"; done
printf '%s\n' 'unlinked,queued,ship,firstmate,Unrelated' \
  'paused-job,queued,ship,firstmate,OFF goal' 'dep,queued,ship,firstmate,Blocked dependency' \
  'mate-job,queued,ship,firstmate,Other owner' 't1,queued,ship,firstmate,ON goal' > "$READY_LIST"
out=$(env "${AD_ENV[@]}" FM_AUTODISPATCH_MAX_STARTS=5 "$AD" run)
assert_equals 'started t1' "$out" 'only the ready ON link owned by this home may start'
printf '%s\n' 't1,queued,ship,firstmate,ON goal' > "$READY_LIST"
assert_contains "$out" 'started t1' 'a dispatchable row is started'
assert_equals 1 "$(wc -l < "$DISPATCH_ARGS")" 'one dispatch per pass, like the admission retry'
assert_contains "$(cat "$DISPATCH_ARGS")" 'new t1 '"$HOME_DIR"'/projects/firstmate --wait --mode direct-PR --yolo off' 'the dispatch goes through fm-dispatch.sh new with derived flags'
assert_contains "$(cat "$HOME_DIR/state/.wake-queue")" 'auto-dispatch: started t1' 'a start is announced as a durable wake row'
pass 'enforce starts the ON goal link, skips unrelated, OFF, blocked and other-owner rows'

printf 'weekly-hold\n' > "$DISPATCH_MODE"
rm -f "$HOME_DIR/state/.wake-queue"
out=$(env "${AD_ENV[@]}" "$AD" run)
assert_contains "$out" 'wait t1: the weekly start guard held every candidate' 'a resolver hold is paced, not parked'
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail 'a weekly-guard hold must not wake firstmate'
assert_contains "$(env "${AD_ENV[@]}" "$AD" list)" 't1 skip: last attempt' 'a held attempt paces itself before the next try'
printf '1\n' > "$HOME_DIR/state/auto-dispatch-attempt/t1"
assert_contains "$(env "${AD_ENV[@]}" "$AD" list)" 't1 start' 'after the pacing interval the row is dispatchable again'
pass 'a resolver hold retries on its own interval without a wake'

printf 'captain-pick\n' > "$DISPATCH_MODE"
touch -d '@1' "$HOME_DIR/state/auto-dispatch-attempt/t1"
out=$(env "${AD_ENV[@]}" "$AD" run)
assert_contains "$out" 'parked t1: dispatch exit 3' 'a captain pick parks the row'
queue=$(cat "$HOME_DIR/state/.wake-queue")
assert_contains "$queue" 'auto-dispatch: t1 parked for firstmate' 'the pick wakes firstmate once'
assert_contains "$queue" 'pick: one-of: use the repo standard prefix' 'the wake carries the pick evidence'
assert_contains "$(env "${AD_ENV[@]}" "$AD" list)" 't1 skip: parked for firstmate' 'a parked row is not retried'
printf 'error\n' > "$DISPATCH_MODE"
rm -f "$HOME_DIR/state/auto-dispatch-attempt/t1"
touch -d '@1' "$HOME_DIR/state/auto-dispatch-failed/t1"
out=$(env "${AD_ENV[@]}" "$AD" run)
assert_contains "$out" 'parked t1: dispatch exit 1' 'an errored dispatch parks the row'
assert_contains "$(cat "$HOME_DIR/state/.wake-queue")" 't1 parked for firstmate' 'the error wakes firstmate once'
rm -f "$HOME_DIR/state/auto-dispatch-attempt/t1"
touch -d '@1' "$HOME_DIR/state/auto-dispatch-failed/t1"
assert_contains "$(env "${AD_ENV[@]}" "$AD" list)" 't1 start' 'rewriting the brief clears the mark'
printf 'error\n' > "$DISPATCH_MODE"
rm -f "$HOME_DIR/state/auto-dispatch-attempt/t1"
touch -d '@1' "$HOME_DIR/state/auto-dispatch-failed/t1"
env "${AD_ENV[@]}" "$AD" run > /dev/null
env "${AD_ENV[@]}" "$AD" drop t1
assert_contains "$(env "${AD_ENV[@]}" "$AD" list)" 't1 start' 'drop forgets a failure mark'
pass 'refusals park with one wake row; drop and a rewritten brief clear the mark'

printf 'spawn-hold\n' > "$DISPATCH_MODE"
rm -f "$HOME_DIR/state/.wake-queue" "$HOME_DIR/state/auto-dispatch-attempt/t1" "$HOME_DIR/state/auto-dispatch-failed/t1"
out=$(env "${AD_ENV[@]}" "$AD" run)
assert_contains "$out" 'held t1: spawn admission held the start; the admission queue retries it' 'a spawn hold names the admission queue'
[ ! -e "$HOME_DIR/state/auto-dispatch-attempt/t1" ] || fail 'a spawn-held start must not pace itself'
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail 'the admission queue owns spawn-held retries, no wake'
printf 'race\n' > "$DISPATCH_MODE"
out=$(env "${AD_ENV[@]}" "$AD" run)
assert_contains "$out" 'started t1 (the task record appeared during the launch)' 'a launch whose record appeared counts as started'
assert_not_contains "$(cat "$HOME_DIR/state/.wake-queue" 2>/dev/null)" 'parked for firstmate' 'a raced launch never parks'
pass 'spawn holds hand off to the admission queue and a raced launch parks nothing'

# The mate must use the parent's goal switch but only its own item links.
MATE="$TMP_ROOT/mate"
mkdir -p "$MATE/state" "$MATE/config"
printf 'miko\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$MATE/.fm-secondmate-parent"
printf '%s\n' "- miko - Lab mate (home: $MATE; scope: test; projects: firstmate; added 2026-11-27)" > "$HOME_DIR/data/secondmates.md"
printf 'enforce\n' > "$MATE/config/auto-dispatch"
printf '%s\n' 't1,queued,ship,firstmate,Parent item' 'mate-job,queued,ship,firstmate,Mate item' > "$READY_LIST"
MATE_ENV=(FM_HOME="$MATE" FM_CONFIG_OVERRIDE="$MATE/config" FM_STATE_OVERRIDE="$MATE/state")
printf 'start\n' > "$DISPATCH_MODE"
out=$(env "${AD_ENV[@]}" "${MATE_ENV[@]}" "$AD" run)
assert_equals 'started mate-job' "$out" 'the mate does not start the parent item'
"$GOAL" pause enabled >/dev/null || fail 'could not turn parent goal OFF'
assert_equals '' "$(env "${AD_ENV[@]}" "${MATE_ENV[@]}" "$AD" run)" 'parent OFF stops mate dispatch'
pass 'a local secondmate starts only its own items and honors the parent goal switch'

# --- arm ---------------------------------------------------------------------
env "${AD_ENV[@]}" "$AD" arm >/dev/null 2>&1 || true
assert_present "$HOME_DIR/state/auto-dispatch.check.sh" 'arm writes the watcher check'
assert_contains "$(<"$HOME_DIR/state/auto-dispatch.check.sh")" 'fm-auto-dispatch.sh check' 'the check runs auto-dispatch'
pass 'arm writes state/auto-dispatch.check.sh'

err=$(FM_AUTODISPATCH_MAX_STARTS=x "$AD" list 2>&1) && fail 'a bad max must refuse'
assert_contains "$err" 'FM_AUTODISPATCH_MAX_STARTS' 'the bad max names itself'
err=$(FM_AUTODISPATCH_RETRY_SECS=y "$AD" list 2>&1) && fail 'a bad retry interval must refuse'
assert_contains "$err" 'FM_AUTODISPATCH_RETRY_SECS' 'the bad interval names itself'
pass 'bad tuning refuses with the variable named'

echo '# all fm-auto-dispatch tests passed'
