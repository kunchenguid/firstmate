#!/usr/bin/env bash
# Behavior tests for firstmate's GitHub Issues project layer.
#
# The two defects this layer exists to prevent are both "the tool answered
# confidently and the answer was wrong", so the refusals carry most of the
# weight here: a suite that only walked the happy path would have passed while
# both defects were live.
#
# Every case drives bin/fm-tracker.sh and bin/fm-tracker-notify.sh through their
# real command lines against a fake gh, so no case touches the network.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TRACKER="$ROOT/bin/fm-tracker.sh"
NOTIFY="$ROOT/bin/fm-tracker-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-tracker)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# --- fake gh ----------------------------------------------------------------
#
# Records every invocation to $FAKE_GH_LOG and answers from $FAKE_GH_DIR: a
# response file named for the request, or a canned default. Recording the calls
# is what lets a refusal case assert that NOTHING was created, which is the
# claim that matters - "it printed an error" is not the same as "it did not
# write".

FAKE_GH_DIR="$TMP_ROOT/gh"
FAKE_GH_LOG="$TMP_ROOT/gh/calls.log"
mkdir -p "$FAKE_GH_DIR"

setup_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
mode=$1
case $mode in
  api) shift ;;
  *) exit 0 ;;
esac

want_graphql=0
path=
for arg in "$@"; do
  case $arg in
    graphql) want_graphql=1 ;;
    /*) [ -n "$path" ] || path=$arg ;;
  esac
done

if [ "$want_graphql" -eq 1 ]; then
  [ -f "$FAKE_GH_DIR/graphql.out" ] || exit 0
  cat "$FAKE_GH_DIR/graphql.out"
  exit 0
fi

# An -i request is served verbatim from a canned HTTP response so the poll sees
# real status lines, ETag and X-Poll-Interval headers.
case " $* " in
  *" -i "*)
    n=$(cat "$FAKE_GH_DIR/http.seq" 2>/dev/null || echo 1)
    file="$FAKE_GH_DIR/http.$n"
    if [ ! -f "$file" ]; then
      file="$FAKE_GH_DIR/http.default"
    fi
    printf '%s\n' "$((n + 1))" > "$FAKE_GH_DIR/http.seq"
    [ -f "$file" ] || exit 1
    cat "$file"
    grep -q '^HTTP/[^ ]* 304' "$file" && exit 1
    exit 0
    ;;
esac

case $path in
  /user) printf '%s\n' "${FAKE_GH_LOGIN:-tester}"; exit 0 ;;
esac

name=$(printf '%s' "$path" | tr '/?&=' '____')
if [ -f "$FAKE_GH_DIR/rest$name" ]; then
  cat "$FAKE_GH_DIR/rest$name"
  exit 0
fi
if [ -f "$FAKE_GH_DIR/rest.default" ]; then
  cat "$FAKE_GH_DIR/rest.default"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# A home with a state directory and a fake gh on PATH.
make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state"
  fakebin=$(fm_fakebin "$home")
  setup_fake_gh "$fakebin"
  printf '%s\n' "$home"
}

run_tracker() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FAKE_GH_DIR="$FAKE_GH_DIR" \
    FAKE_GH_LOG="$FAKE_GH_LOG" "$TRACKER" "$@"
}

# Deliberately passes an EMPTY state root, which is the case the guard exists
# for: "$STATE/$task.check.sh" with an empty $STATE resolves to a path at the
# filesystem root that nobody named.
run_tracker_empty_state() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="" FAKE_GH_DIR="$FAKE_GH_DIR" \
    FAKE_GH_LOG="$FAKE_GH_LOG" "$TRACKER" "$@"
}

run_notify() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FAKE_GH_DIR="$FAKE_GH_DIR" \
    FAKE_GH_LOG="$FAKE_GH_LOG" "$NOTIFY" "$@"
}

reset_gh() {
  rm -f "$FAKE_GH_DIR"/rest* "$FAKE_GH_DIR"/http.* "$FAKE_GH_DIR"/graphql.out
  : > "$FAKE_GH_LOG"
}

# Build one graph record the way bin/fm-tracker-lib.sh's query emits it: fields
# separated by US (0x1f), title and body base64.
graph_record() {  # <number> <state> <labels> <assignees> <parent> <blockers> <title> <body>
  local us=$'\037'
  printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
    "$1" "$us" "$2" "$us" "$3" "$us" "$4" "$us" "$5" "$us" "$6" "$us" \
    "$(printf '%s' "$7" | base64 | tr -d '\n')" "$us" \
    "$(printf '%s' "$8" | base64 | tr -d '\n')"
}

# ===========================================================================
# Defect 1: a prose blocking edge is refused, and nothing is created
# ===========================================================================

HOME_A=$(make_home a)

reset_gh
out=$(run_tracker "$HOME_A" add o/r --type task --title 'a task' \
  --body 'Blocked by: #12 - the ruling has to land first.' 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "prose blocker must be refused"
assert_contains "$out" "refusing a prose blocking edge" "refusal must name the reason"
assert_contains "$out" "Blocked by: #12" "refusal must quote the offending line"
assert_contains "$out" "--blocked-by" "refusal must name the supported alternative"
assert_no_grep "POST" "$FAKE_GH_LOG" "a refused body must not create anything"
pass "add refuses a prose blocking edge before any write"

# The same refusal must fire on every spelling that reads as a blocker, not just
# the one the original defect happened to use.
for phrasing in \
  'This depends on #12.' \
  'waiting on #12 to land' \
  'blocker: #12 must close first'; do
  reset_gh
  out=$(run_tracker "$HOME_A" add o/r --type task --title 'a task' --body "$phrasing" 2>&1)
  rc=$?
  expect_code_out 1 "$rc" "$out" "prose blocker '$phrasing' must be refused"
  assert_no_grep "POST" "$FAKE_GH_LOG" "refused '$phrasing' must not create anything"
done
pass "add refuses every prose blocker phrasing, not only the observed one"

# Prose wearing the canonical heading is still prose: the heading alone does not
# make an edge, and this is the shape a well-meaning hand-edit produces.
reset_gh
out=$(run_tracker "$HOME_A" add o/r --type task --title 'a task' \
  --body "$(printf '## Blocked by\nthe grain ruling, once it lands\n')" 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "prose under the canonical heading must be refused"
assert_no_grep "POST" "$FAKE_GH_LOG" "refused canonical-heading prose must not create anything"
pass "add refuses prose under the canonical heading"

# A body carrying an already-correct task list is NOT prose and must be accepted,
# or the refusal would be unusable.
reset_gh
printf '7\n' > "$FAKE_GH_DIR/rest.default"
out=$(run_tracker "$HOME_A" add o/r --type task --title 'a task' \
  --body "$(printf '## Blocked by\n- [ ] #12\n')" 2>&1)
rc=$?
expect_code_out 0 "$rc" "$out" "a canonical task list must be accepted"
pass "add accepts an already-canonical blocked-by section"

# ===========================================================================
# Defect 2: type is carried by a label and never by the title
# ===========================================================================

reset_gh
printf '7\n' > "$FAKE_GH_DIR/rest.default"
out=$(run_tracker "$HOME_A" add o/r --type decision \
  --title 'TASK: does the house grain belong here?' 2>&1)
rc=$?
expect_code_out 0 "$rc" "$out" "add must create a typed ticket"
assert_grep 'labels[]=fm:decision' "$FAKE_GH_LOG" "type must be sent as a label"
assert_grep 'TASK: does the house grain belong here?' "$FAKE_GH_LOG" "the title must pass through verbatim"
assert_contains "$out" "[fm:decision]" "the reported type must come from the label"
pass "add carries type as a label, independent of the title text"

# The title is never consulted for type: a title that says DECISION on a ticket
# typed task must still be a task.
reset_gh
printf '7\n' > "$FAKE_GH_DIR/rest.default"
out=$(run_tracker "$HOME_A" add o/r --type task --title 'DECISION: ship it' 2>&1)
expect_code_out 0 "$?" "$out" "a misleading title must not change the type"
assert_grep 'labels[]=fm:task' "$FAKE_GH_LOG" "a DECISION title typed task must send fm:task"
assert_no_grep 'labels[]=fm:decision' "$FAKE_GH_LOG" "the title must never produce a decision label"
pass "a title reading DECISION does not reclassify a task"

reset_gh
out=$(run_tracker "$HOME_A" add o/r --type Decision --title 'x' 2>&1)
expect_code_out 2 "$?" "$out" "an unknown type must be a usage error"
assert_contains "$out" "invalid --type" "the type vocabulary must be closed"
pass "add refuses a type outside the closed vocabulary"

# ===========================================================================
# Blocking edges are written in the one form GitHub resolves
# ===========================================================================

reset_gh
printf '7\n' > "$FAKE_GH_DIR/rest.default"
out=$(run_tracker "$HOME_A" add o/r --type task --title 'blocked work' --blocked-by 12,13 2>&1)
expect_code_out 0 "$?" "$out" "add must accept --blocked-by"
assert_grep '## Blocked by' "$FAKE_GH_LOG" "the canonical heading must be written"
assert_grep '- [ ] #12' "$FAKE_GH_LOG" "each blocker must be a task-list reference"
assert_grep '- [ ] #13' "$FAKE_GH_LOG" "each blocker must be a task-list reference"
pass "add writes blocking edges as the task list GitHub resolves"

reset_gh
out=$(run_tracker "$HOME_A" add o/r --type task --title 'x' --blocked-by 'twelve' 2>&1)
expect_code_out 2 "$?" "$out" "a non-numeric blocker must be a usage error"
pass "add refuses a non-numeric blocker"

# ===========================================================================
# frontier: ready, blocked, and what each blocked ticket waits on
# ===========================================================================

reset_gh
{
  graph_record 1 OPEN 'fm:destination' '' '-' '' 'the destination' ''
  graph_record 2 OPEN 'fm:decision' '' '1' '' 'a captain decision' ''
  graph_record 3 OPEN 'fm:task' '' '1' '2|OPEN|decision|' 'blocked work' ''
  graph_record 4 OPEN 'fm:task' '' '1' '2|CLOSED|decision|' 'freed work' ''
  graph_record 5 OPEN 'fm:task' 'someone' '1' '' 'claimed work' ''
  graph_record 6 CLOSED 'fm:task' '' '1' '' 'finished work' ''
} > "$FAKE_GH_DIR/graphql.out"

out=$(run_tracker "$HOME_A" frontier o/r 2>&1)
expect_code_out 0 "$?" "$out" "frontier must succeed"
ready=$(printf '%s\n' "$out" | sed -n '/^READY/,/^$/p')
blocked=$(printf '%s\n' "$out" | sed -n '/^BLOCKED/,/^$/p')
claimed=$(printf '%s\n' "$out" | sed -n '/^CLAIMED/,$p')
assert_contains "$ready" "#4" "a ticket whose only blocker is closed must be ready"
assert_not_contains "$ready" "#3" "a ticket with an open blocker must not be ready"
assert_contains "$blocked" "#3" "a ticket with an open blocker must be blocked"
assert_contains "$blocked" "waits on #2" "a blocked ticket must name what it waits on"
assert_contains "$blocked" "a decision the captain owns" "the wait must be described by type"
assert_not_contains "$ready" "#5" "an assigned ticket must be excluded from ready"
assert_not_contains "$blocked" "#5" "an assigned ticket must be excluded from blocked"
assert_contains "$claimed" "#5" "an assigned ticket is reported as claimed"
assert_not_contains "$out" "#6" "a closed ticket is not on the frontier"
pass "frontier splits ready and blocked, names the wait, and excludes claims"

# A blocked ticket becomes ready with no rewrite once its blocker closes: the
# same records with the blocker's state flipped are all it takes.
reset_gh
{
  graph_record 1 OPEN 'fm:destination' '' '-' '' 'the destination' ''
  graph_record 3 OPEN 'fm:task' '' '1' '2|CLOSED|decision|' 'blocked work' ''
} > "$FAKE_GH_DIR/graphql.out"
out=$(run_tracker "$HOME_A" frontier o/r 2>&1)
assert_contains "$(printf '%s\n' "$out" | sed -n '/^READY/,/^$/p')" "#3" \
  "a dependent must become ready when its blocker closes"
pass "a dependent moves from blocked to ready when its blocker closes"

# ===========================================================================
# validate: the standing guard against both defects returning by hand-edit
# ===========================================================================

reset_gh
{
  graph_record 1 OPEN 'fm:destination' '' '-' '' 'the destination' ''
  graph_record 2 OPEN '' '' '1' '' 'DECISION: untyped' ''
  graph_record 3 OPEN 'fm:task' '' '1' '' 'invisible blocker' 'Blocked by: #2 - must land first.'
  graph_record 4 OPEN 'fm:task fm:decision' '' '1' '' 'two types' ''
  graph_record 5 OPEN 'fm:task' '' '-' '' 'orphan' ''
  graph_record 6 OPEN 'fm:task' '' '1' '2|OPEN|decision|' 'off-convention heading' \
    "$(printf '**Blocked by:**\n- [ ] #2\n')"
} > "$FAKE_GH_DIR/graphql.out"

out=$(run_tracker "$HOME_A" validate o/r 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "validate must fail when tickets are malformed"
assert_contains "$out" "#2 missing type label" "an unlabelled ticket must be reported"
assert_contains "$out" "#3 line 1 names #2 as a blocker with no resolved edge" \
  "a prose blocker with no edge must be reported as invisible"
assert_contains "$out" "reports READY while blocked" "the consequence must be stated"
assert_contains "$out" "#4 carries 2 type labels" "an ambiguous type must be reported"
assert_contains "$out" "#5 orphaned" "a ticket with no parent must be reported"
pass "validate reports missing type, invisible prose blockers, ambiguity and orphans"

# The distinction that keeps validate honest: an off-convention heading over a
# reference GitHub DID resolve is not invisible, and must not be reported as if
# it were. Claiming otherwise would be the same confident wrong answer this
# whole layer exists to prevent.
assert_contains "$out" "#6 line 2 uses a non-canonical blocked-by heading for #2" \
  "an off-convention heading over a real edge must be reported as such"
assert_contains "$out" "the edge" "the report must say the edge still resolves"
assert_not_contains "$(printf '%s\n' "$out" | grep '#6' || true)" "no resolved edge" \
  "a resolved edge must never be reported as invisible"
pass "validate distinguishes an invisible prose blocker from an off-convention heading"

reset_gh
{
  graph_record 1 OPEN 'fm:destination' '' '-' '' 'the destination' ''
  graph_record 2 OPEN 'fm:task' '' '1' '' 'clean work' 'Done when: it ships.'
} > "$FAKE_GH_DIR/graphql.out"
out=$(run_tracker "$HOME_A" validate o/r 2>&1)
expect_code_out 0 "$?" "$out" "validate must pass on well-formed tickets"
assert_contains "$out" "no malformed tickets" "a clean repo must say so"
pass "validate passes on tickets this script wrote"

# ===========================================================================
# claim, release and answer
# ===========================================================================

reset_gh
printf 'someone-else\n' > "$FAKE_GH_DIR/rest.default"
out=$(run_tracker "$HOME_A" claim o/r 3 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "claiming a ticket someone else holds must be refused"
assert_contains "$out" "already claimed by" "the refusal must name the holder"
assert_no_grep "POST" "$FAKE_GH_LOG" "a refused claim must not reassign"
pass "claim refuses a ticket another session already holds"

reset_gh
printf 'fm:task\n' > "$FAKE_GH_DIR/rest.default"
out=$(run_tracker "$HOME_A" answer o/r 3 --decision 'do it' 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "answering a task must be refused"
assert_contains "$out" "not a decision or unknown" "the refusal must name the reason"
assert_no_grep "POST" "$FAKE_GH_LOG" "a refused answer must not comment or close"
pass "answer refuses a ticket that is not a decision or unknown"

# ===========================================================================
# Destructive-path guards
#
# Disarming removes files, so the guards assert the facts that make a file ours
# before anything is removed. An empty variable is the case that matters: it
# silently resolves into a path nobody named, and it must refuse instead.
# ===========================================================================

HOME_B=$(make_home b)
: > "$HOME_B/state/other.check.sh"
chmod 0700 "$HOME_B/state/other.check.sh"

out=$(run_tracker_empty_state "$HOME_B" unwatch --task anything 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "an empty state root must refuse"
assert_contains "$out" "refusing to remove anything" "the refusal must lead with what it did not do"
# Pin the state-root guard specifically, not just the outcome. A later guard
# also refuses this input, so asserting only "it refused" would still pass with
# this guard deleted - the test would be reporting on a different guard than the
# one it names.
assert_contains "$out" "is not an existing state directory" \
  "the state-root guard itself must be what refuses an empty root"
assert_present "$HOME_B/state/other.check.sh" "an empty state root must remove nothing"
pass "unwatch refuses when the state root is empty, and removes nothing"

out=$(run_tracker "$HOME_B" unwatch --task '' 2>&1)
expect_code_out 2 "$?" "$out" "an empty task id must be a usage error"
assert_present "$HOME_B/state/other.check.sh" "an empty task id must remove nothing"
pass "unwatch refuses an empty task id, and removes nothing"

out=$(run_tracker "$HOME_B" unwatch --task ../escape 2>&1)
expect_code_out 2 "$?" "$out" "a traversing task id must be a usage error"
assert_present "$HOME_B/state/other.check.sh" "a traversing task id must remove nothing"
pass "unwatch refuses a task id that would escape the state root"

out=$(run_tracker "$HOME_B" unwatch --task never-armed 2>&1)
expect_code_out 1 "$?" "$out" "an unarmed task must refuse"
assert_contains "$out" "no tracker watch is armed" "the refusal must say why"
pass "unwatch refuses a task that has no watch armed"

# A watch sidecar next to somebody else's check: disarming must not touch the
# check it did not publish.
printf '%s\n%s\n' 'fm-tracker-watch-v1' 'o/r' > "$HOME_B/state/other.tracker-watch"
out=$(run_tracker "$HOME_B" unwatch --task other 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "a foreign check must refuse"
assert_contains "$out" "not this watch's own shim" "the refusal must name the mismatch"
assert_present "$HOME_B/state/other.check.sh" "a foreign check must survive"
pass "unwatch refuses to remove a check it did not publish"

out=$(run_tracker "$HOME_B" watch --task other o/r 2>&1)
rc=$?
expect_code_out 1 "$rc" "$out" "arming over a foreign check must refuse"
assert_contains "$out" "already armed" "the refusal must name the conflict"
pass "watch refuses to overwrite a check another owner armed"

# The happy path, so the guards above are not passing vacuously.
out=$(run_tracker "$HOME_B" watch --task mine o/r 2>&1)
expect_code_out 0 "$?" "$out" "arming a fresh watch must succeed"
assert_present "$HOME_B/state/mine.check.sh" "arming must publish the check"
assert_present "$HOME_B/state/mine.tracker-watch" "arming must publish the sidecar"
assert_present "$HOME_B/state/mine.check-trust" "arming must register the check"
# bin/fm-pr-lib.sh owns the cross-platform stat forms. Rolling them here with a
# `stat -f ... || stat -c ...` fallback is wrong on Linux, where `stat -f`
# succeeds as "filesystem status" and the fallback never runs.
mode=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$HOME_B/state/mine.check.sh")
[ "$mode" = 700 ] || fail "the check must be mode 0700, got $mode"
links=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_link_count "$2"' _ "$ROOT" "$HOME_B/state/mine.check.sh")
[ "$links" = 1 ] || fail "the check must be a single-link file, got $links links"
pass "watch publishes a registered, single-link, mode-0700 check"

out=$(run_tracker "$HOME_B" unwatch --task mine 2>&1)
expect_code_out 0 "$?" "$out" "disarming its own watch must succeed"
assert_absent "$HOME_B/state/mine.check.sh" "disarming must remove its own check"
assert_absent "$HOME_B/state/mine.tracker-watch" "disarming must remove its own sidecar"
assert_absent "$HOME_B/state/mine.check-trust" "disarming must remove its own registration"
assert_present "$HOME_B/state/other.check.sh" "disarming must leave another owner's check alone"
pass "unwatch removes exactly the artifacts it published"

# ===========================================================================
# The wake poll
# ===========================================================================

HOME_C=$(make_home c)

http_response() {  # <index> <status> <extra-headers> <body>
  {
    printf 'HTTP/2.0 %s\r\n' "$2"
    printf 'Etag: "e%s"\r\n' "$1"
    printf '%s' "$3"
    printf '\r\n'
    printf '%s\n' "$4"
  } > "$FAKE_GH_DIR/http.$1"
}

arm_watch() {  # <home> <task>
  run_tracker "$1" watch --task "$2" o/r >/dev/null 2>&1 \
    || fail "could not arm the watch fixture"
  rm -f "$FAKE_GH_DIR"/http.* 
  printf '1\n' > "$FAKE_GH_DIR/http.seq"
}

# Seeding: the first run after arming establishes position and must be silent,
# or arming a watch would immediately wake firstmate on the whole backlog.
reset_gh
arm_watch "$HOME_C" wake
http_response 1 '200 OK' 'X-Poll-Interval: 60
' '[{"subject":{"type":"Issue","latest_comment_url":"https://api.github.com/repos/o/r/issues/9"},"repository":{"full_name":"o/r"},"updated_at":"2026-08-25T10:00:00Z"}]'
http_response 2 '200 OK' '' '[{"issue_url":"https://api.github.com/repos/o/r/issues/9","updated_at":"2026-08-25T10:00:00Z"}]'
out=$(run_notify "$HOME_C" --task wake 2>&1)
expect_code_out 0 "$?" "$out" "the seeding run must succeed"
[ -z "$out" ] || fail "the seeding run must print nothing, got: $out"
assert_present "$HOME_C/state/wake.tracker-cursor" "the seeding run must record its position"
pass "the first poll after arming seeds silently"

# 304 is the common case and must be silent and free.
rm -f "$FAKE_GH_DIR"/http.*
printf '1\n' > "$FAKE_GH_DIR/http.seq"
http_response 1 '304 Not Modified' 'X-Poll-Interval: 60
' ''
http_response 2 '304 Not Modified' '' ''
out=$(run_notify "$HOME_C" --task wake 2>&1)
expect_code_out 0 "$?" "$out" "a 304 poll must succeed"
[ -z "$out" ] || fail "a 304 poll must print nothing, got: $out"
pass "a 304 poll prints nothing"

# A genuinely new comment produces exactly one line naming the repo and issue.
rm -f "$FAKE_GH_DIR"/http.*
printf '1\n' > "$FAKE_GH_DIR/http.seq"
sed -i.bak 's/^notifications_next=.*/notifications_next=0/' "$HOME_C/state/wake.tracker-cursor"
rm -f "$HOME_C/state/wake.tracker-cursor.bak"
http_response 1 '200 OK' 'X-Poll-Interval: 60
' '[{"subject":{"type":"Issue","latest_comment_url":"https://api.github.com/repos/o/r/issues/9"},"repository":{"full_name":"o/r"},"updated_at":"2026-08-25T12:00:00Z"}]'
http_response 2 '304 Not Modified' '' ''
out=$(run_notify "$HOME_C" --task wake 2>&1)
expect_code_out 0 "$?" "$out" "a new-comment poll must succeed"
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the wake must be one line, got: $out"
assert_contains "$out" "o/r#9" "the wake must name the repository and issue"
pass "a new comment wakes firstmate with one line naming the repo and issue"

# The same comment must not fire twice: a repeated wake on settled state is the
# supervision equivalent of a stuck alarm.
rm -f "$FAKE_GH_DIR"/http.*
printf '1\n' > "$FAKE_GH_DIR/http.seq"
sed -i.bak 's/^notifications_next=.*/notifications_next=0/' "$HOME_C/state/wake.tracker-cursor"
rm -f "$HOME_C/state/wake.tracker-cursor.bak"
http_response 1 '200 OK' 'X-Poll-Interval: 60
' '[{"subject":{"type":"Issue","latest_comment_url":"https://api.github.com/repos/o/r/issues/9"},"repository":{"full_name":"o/r"},"updated_at":"2026-08-25T12:00:00Z"}]'
http_response 2 '304 Not Modified' '' ''
out=$(run_notify "$HOME_C" --task wake 2>&1)
[ -z "$out" ] || fail "an already-reported comment must not wake again, got: $out"
pass "an already-reported comment does not wake firstmate twice"

# X-Poll-Interval is the server's own cadence and is honoured as a floor: with
# the interval unexpired, the poll must not re-request the inbox at all.
reset_gh
arm_watch "$HOME_C" cadence
http_response 1 '200 OK' 'X-Poll-Interval: 3600
' '[]'
http_response 2 '304 Not Modified' '' ''
run_notify "$HOME_C" --task cadence >/dev/null 2>&1
assert_grep 'notifications_interval=3600' "$HOME_C/state/cadence.tracker-cursor" \
  "the server's stated cadence must be recorded"
: > "$FAKE_GH_LOG"
printf '1\n' > "$FAKE_GH_DIR/http.seq"
run_notify "$HOME_C" --task cadence >/dev/null 2>&1
assert_no_grep '/notifications' "$FAKE_GH_LOG" \
  "the inbox must not be re-requested before the stated interval elapses"
pass "the poll honours the server's X-Poll-Interval as a floor"

# A poll for a task with no armed watch must do nothing at all, so a stale check
# left behind by anything else cannot start making requests.
reset_gh
out=$(run_notify "$HOME_C" --task unarmed 2>&1)
expect_code_out 0 "$?" "$out" "an unarmed poll must exit cleanly"
[ -z "$out" ] || fail "an unarmed poll must print nothing, got: $out"
assert_no_grep 'api' "$FAKE_GH_LOG" "an unarmed poll must make no request"
pass "a poll with no armed watch makes no request and prints nothing"

# ===========================================================================
# Stock Bash 3.2
#
# The poll runs as a watcher check on whatever bash the machine has, and stock
# macOS Bash is 3.2. CI's stock-bash job only PARSES the shell inventory, and a
# bash-4-only construct parses fine there while failing at runtime - which for
# this script meant writing no cursor and still exiting 0, indistinguishable
# from an inbox where nothing happened. A wake that silently never fires is the
# worst failure this script has, so it is exercised here rather than parsed.
stock_bash=''
for candidate in /bin/bash /usr/bin/bash; do
  [ -x "$candidate" ] || continue
  # shellcheck disable=SC2016 # $BASH_VERSION must expand in the CHILD shell.
  case "$("$candidate" -c 'printf %s "$BASH_VERSION"' 2>/dev/null)" in
    3.*) stock_bash=$candidate; break ;;
  esac
done

if [ -z "$stock_bash" ]; then
  printf 'note: no Bash 3.x on this machine; stock-Bash case not exercised\n'
else
  HOME_D=$(make_home d)
  reset_gh
  run_tracker "$HOME_D" watch --task stock o/r >/dev/null 2>&1 \
    || fail "could not arm the stock-bash fixture"
  rm -f "$FAKE_GH_DIR"/http.*
  printf '1\n' > "$FAKE_GH_DIR/http.seq"
  http_response 1 '200 OK' 'X-Poll-Interval: 60
' '[]'
  http_response 2 '200 OK' '' '[]'
  out=$(PATH="$HOME_D/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_D" \
    FM_STATE_OVERRIDE="$HOME_D/state" FAKE_GH_DIR="$FAKE_GH_DIR" FAKE_GH_LOG="$FAKE_GH_LOG" \
    "$stock_bash" "$NOTIFY" --task stock 2>&1)
  rc=$?
  expect_code_out 0 "$rc" "$out" "the poll must run under $stock_bash"
  assert_not_contains "$out" "invalid option" "the poll must use no Bash 4 builtin option"
  assert_not_contains "$out" "unbound variable" "the poll must not trip set -u under Bash 3.2"
  # Exiting 0 is not enough: it must actually have recorded position, or it
  # would be failing silently in exactly the way that looks like success.
  assert_present "$HOME_D/state/stock.tracker-cursor" \
    "the poll must record its cursor under Bash 3.2, not just exit 0"
  assert_grep 'seeded=1' "$HOME_D/state/stock.tracker-cursor" \
    "the cursor written under Bash 3.2 must be complete"
  pass "the wake poll runs correctly under stock Bash 3.x, not merely parses"
fi

printf '\nall fm-tracker cases passed\n'
