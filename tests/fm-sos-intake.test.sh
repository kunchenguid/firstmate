#!/usr/bin/env bash
# tests/fm-sos-intake.test.sh - the SOS dispatch loop's intake: one task row
# (a bead on a beads backend) per SOS keyed on the SOS UUID, one lifecycle
# comment per transition, one close watch per ticket, one dispatched crewmate
# per new ticket - and never a second of any of them across retries, replayed
# events, or lost cursors. Also pins the loop's hard invariant: intake and the
# close watch never close a GitHub issue; only the captain does.
set -u

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-sos-intake.sh"
TASKS_AXI="$ROOT/bin/fm-tasks-axi.sh"
SOS_UUID="7f3c1a52-9b41-4c2e-9d6a-1f0b2c3d4e5f"
TASK_ID="sos-$SOS_UUID"
GH_ISSUE=1921

TMP_ROOT=$(fm_test_tmproot fm-sos-intake)

# setup_case <name>: a fixture home with a real tasks-axi backlog (markdown
# backend - the beads-capable backend is the fleet's, and the intake reaches
# it through the same fm-tasks-axi.sh entry point), a fakebin holding stub
# gh/curl/fm-spawn, and the canned bridge/GitHub scenario files the stubs
# serve. Echoes "<home>|<fakebin>|<fakedir>".
setup_case() {
  local name=$1 case_dir home fb fd
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fd="$case_dir/fake"
  mkdir -p "$home/data" "$fd"
  (umask 077; mkdir -p "$home/state")
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  fb=$(fm_fakebin "$case_dir")

  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
echo "gh $*" >> "$FAKE/gh.log"
if [ -f "$FAKE/gh-broken" ]; then
  echo "gh: simulated outage" >&2
  exit 1
fi
case "${1:-}" in
  issue)
    case "${2:-}" in
      list) cat "$FAKE/gh-list.json" 2>/dev/null || echo "[]" ;;
      view)
        n="${3:-}"
        if [ -f "$FAKE/gh-state-$n" ]; then cat "$FAKE/gh-state-$n"; else echo '{"state":"OPEN"}'; fi
        ;;
      comment)
        n="${3:-}"
        shift 3
        body=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--body" ] && [ $# -ge 2 ]; then body="$2"; shift; fi
          shift
        done
        printf '%s\t%s\n' "$n" "$body" >> "$FAKE/comments.log"
        echo "https://github.com/ArcsHealth/Portal/issues/$n#comment-1"
        ;;
      close) echo "CLOSE-ATTEMPTED" >> "$FAKE/gh.log"; exit 97 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH

  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
echo "curl $*" >> "$FAKE/curl.log"
cat "$FAKE/bridge.json"
SH

  cat > "$fb/fm-spawn" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
echo "fm-spawn $*" >> "$FAKE/spawn.log"
exit 0
SH

  chmod +x "$fb/gh" "$fb/curl" "$fb/fm-spawn"

  # Default scenario: one bridge event for one open SOS ticket.
  set_bridge_events "$fd" 1 "$SOS_UUID" "$GH_ISSUE"
  set_gh_open_issues "$fd" "$GH_ISSUE" "$SOS_UUID"

  printf '%s\n' "$home|$fb|$fd"
}

set_bridge_events() { # <fakedir> <id> <uuid> <issue>
  local fd=$1 id=$2 uuid=$3 issue=$4
  cat > "$fd/bridge.json" <<EOF
{"events":[{"id":$id,"kind":"sos","dedupeKey":"$uuid","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${uuid%%-*}","gh_issue":$issue,"gh_issue_url":"https://github.com/ArcsHealth/Portal/issues/$issue"}}],"cursor":$id,"backlog":0}
EOF
}

set_bridge_empty() { # <fakedir>
  printf '{"events":[],"cursor":0,"backlog":0}\n' > "$1/bridge.json"
}

set_gh_open_issues() { # <fakedir> <issue> <uuid>
  local fd=$1 issue=$2 uuid=$3
  cat > "$fd/gh-list.json" <<EOF
[{"number":$issue,"url":"https://github.com/ArcsHealth/Portal/issues/$issue","title":"SOS: reported problem","body":"### SOS Voice Ticket\n- **SOS ID:** \`$uuid\`\n"}]
EOF
}

run_intake() { # <case-parts> <args...>
  local parts=$1
  shift
  local home fb fd
  home=${parts%%|*}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  fd=${parts##*|}
  FM_HOME="$home" \
  FM_SOS_FAKE_DIR="$fd" \
  FM_SOS_BRIDGE_URL="http://bridge.invalid:8791" \
  FM_SOS_TASKS="$TASKS_AXI" \
  FM_SOS_SPAWN="$fb/fm-spawn" \
  FM_SOS_BRIEF="$ROOT/bin/fm-brief.sh" \
  FM_SOS_WHEN="$ROOT/bin/fm-procevent-when.sh" \
  PATH="$fb:$PATH" \
    "$INTAKE" "$@"
}

task_state_of() { # <case-parts> [task-id]
  local parts=$1 id=${2:-$TASK_ID} home
  home=${parts%%|*}
  FM_HOME="$home" "$TASKS_AXI" show "$id" 2>/dev/null \
    | sed -n 's/^  state: //p' | head -1
}

task_present() { # <case-parts> [task-id]
  local parts=$1 id=${2:-$TASK_ID} home
  home=${parts%%|*}
  FM_HOME="$home" "$TASKS_AXI" show "$id" >/dev/null 2>&1
}

# count_of <fixed-string> <file>: matches in file, 0 when the file is absent.
count_of() {
  local n
  n=$(grep -cF -- "$1" "$2" 2>/dev/null) || true
  echo "${n:-0}"
}

test_reconcile_creates_one_task_comment_watch_and_dispatch() {
  local parts home fd out
  parts=$(setup_case basic)
  home=${parts%%|*}
  fd=${parts##*|}

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" "reconcile should report one created task: $out"
  assert_contains "$out" "dispatched=1" "reconcile should report one dispatch: $out"

  # The row id IS the SOS UUID key: the idempotency contract made literal.
  task_present "$parts" || fail "task row $TASK_ID missing"
  assert_equals "queued" "$(task_state_of "$parts")" "a fresh task row must await dispatch"

  # One dispatched lifecycle comment on the GitHub issue.
  assert_equals "1" "$(count_of '' "$fd/comments.log")" \
    "expected exactly one comment, got: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_contains "$(cat "$fd/comments.log")" "SOS dispatch" "the intake's comment must identify itself"
  assert_contains "$(cat "$fd/comments.log")" "$TASK_ID" "the comment must name the task row"
  assert_contains "$(cat "$fd/comments.log")" "never closes it" "the comment must state the no-self-close rule"

  # One armed close watch (real fm-procevent-when.sh spec + trust record).
  assert_present "$home/state/when/when-sos-$GH_ISSUE.spec" "close watch spec missing"
  assert_present "$home/state/when/when-sos-$GH_ISSUE.trust" "close watch trust record missing"

  # One spawn, on the auto-dispatch contract, with a filled brief.
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "expected exactly one spawn"
  assert_contains "$(cat "$fd/spawn.log")" "$TASK_ID" "spawn must name the ticket task id"
  assert_contains "$(cat "$fd/spawn.log")" "--mode no-mistakes" "spawn must carry the delivery mode"
  assert_grep "Resolve the staff SOS reported in ArcsHealth/Portal#$GH_ISSUE" \
    "$home/data/$TASK_ID/brief.md" "brief captain intent must name the issue"
  assert_no_grep "{TASK}" "$home/data/$TASK_ID/brief.md" "brief must carry no placeholders"
  assert_no_grep "{FIRSTMATE_SPEC}" "$home/data/$TASK_ID/brief.md" "brief must carry no placeholders"
  assert_grep "NEVER run \`gh issue close\`" "$home/data/$TASK_ID/brief.md" \
    "the worker brief must forbid closing the issue"

  # The cursor landed on the event id, and the loop never closed the issue.
  assert_equals "1" "$(cat "$home/state/fm-sos-intake.cursor")" "cursor must advance to the event id"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "the intake must never close a GitHub issue"
  pass "reconcile creates one task row, comment, watch, and dispatch"
}

test_reconcile_is_idempotent_across_replays_and_lost_cursors() {
  local parts out
  parts=$(setup_case replay)
  run_intake "$parts" reconcile >/dev/null || fail "first reconcile failed"

  # A second pass over a drained bridge changes nothing.
  set_bridge_empty "${parts##*|}"
  out=$(run_intake "$parts" reconcile) || fail "second reconcile failed: $out"
  assert_contains "$out" "task_created=0" "second pass must create no row: $out"
  assert_contains "$out" "dispatched=0" "second pass must not re-dispatch: $out"

  # Lose the cursor entirely and replay the same event: the SOS UUID row id is
  # the idempotency anchor, so work is never done twice.
  rm -f "${parts%%|*}/state/fm-sos-intake.cursor"
  set_bridge_events "${parts##*|}" 1 "$SOS_UUID" "$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "replay reconcile failed: $out"
  assert_contains "$out" "task_created=0" "replay must create no second row: $out"
  assert_contains "$out" "dispatched=0" "replay must not re-dispatch: $out"

  task_present "$parts" || fail "replay lost the task row"
  assert_equals "1" "$(count_of 'SOS dispatch' "${parts##*|}/comments.log")" \
    "replay must not double-comment"
  assert_equals "1" "$(count_of 'fm-spawn' "${parts##*|}/spawn.log")" \
    "replay must never double-dispatch"
  pass "reconcile is idempotent across replays and lost cursors"
}

test_lost_event_is_healed_from_github() {
  local parts out
  parts=$(setup_case heal)
  # No event at all (pre-bridge ticket, or a bridge that lost the POST): the
  # open sos-labeled issue alone is enough to dispatch.
  set_bridge_empty "${parts##*|}"
  out=$(run_intake "$parts" reconcile) || fail "heal reconcile failed: $out"
  assert_contains "$out" "task_created=1" "the GH heal path must create the row: $out"

  out=$(run_intake "$parts" reconcile) || fail "heal re-run failed: $out"
  assert_contains "$out" "task_created=0" "the heal path must be idempotent: $out"
  assert_equals "1" "$(count_of 'SOS dispatch' "${parts##*|}/comments.log")" \
    "the heal path must not double-comment"
  pass "a lost bridge event is healed from GitHub and never double-dispatches"
}

test_watch_condition_never_reads_a_failure_as_closed() {
  local parts fd rc
  parts=$(setup_case condition)
  fd=${parts##*|}

  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 1 "$rc" "an OPEN issue must be a clean false"

  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 0 "$rc" "a CLOSED issue must be a clean true"

  echo "state=$(date +%s)" > "$fd/gh-state-$GH_ISSUE"
  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 2 "$rc" "an unparseable answer must never count as closed"

  touch "$fd/gh-broken"
  run_intake "$parts" watch-condition "$GH_ISSUE"
  rc=$?
  expect_code 2 "$rc" "a gh failure must never count as closed"
  rm -f "$fd/gh-broken"
  pass "watch-condition is closed-only and fails closed"
}

test_watch_fire_comments_closes_the_task_and_never_the_issue() {
  local parts home fd out
  parts=$(setup_case fire)
  home=${parts%%|*}
  fd=${parts##*|}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"

  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_contains "$out" "captain-closed" "watch-fire must report the close"
  assert_contains "$(cat "$fd/comments.log")" "Closed by the captain" \
    "watch-fire must comment the close on the issue"

  assert_equals "done" "$(task_state_of "$parts")" \
    "watch-fire must close the task row, not the issue"

  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "watch-fire must never close the GitHub issue"

  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "re-run failed: $out"
  assert_contains "$out" "already-closed-recorded" "a manual re-run must be a no-op"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the close comment must post exactly once"

  # Regression: a replayed event after the task closed must not mint a second
  # row, and must not reopen the closed one.
  rm -f "$home/state/fm-sos-intake.cursor"
  set_bridge_events "$fd" 1 "$SOS_UUID" "$GH_ISSUE"
  printf '[]\n' > "$fd/gh-list.json"
  out=$(run_intake "$parts" reconcile) || fail "post-close replay failed: $out"
  assert_contains "$out" "task_created=0" "a closed row must still absorb the replay: $out"
  assert_equals "done" "$(task_state_of "$parts")" \
    "a replayed add must never reopen a closed row"
  pass "watch-fire comments once, closes the task row, and never the issue"
}

test_comment_transitions_are_canonical_and_bounded() {
  local parts fd out rc
  parts=$(setup_case comments)
  fd=${parts##*|}

  out=$(run_intake "$parts" comment "$GH_ISSUE" fix-up "PR https://github.com/ArcsHealth/Portal/pull/1") \
    || fail "comment failed: $out"
  assert_contains "$(cat "$fd/comments.log")" "Fix up" "fix-up comment must carry the canonical label"
  assert_contains "$(cat "$fd/comments.log")" "pull/1" "the note must ride along"

  run_intake "$parts" comment "$GH_ISSUE" nonsense
  rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown transition must be refused"
  assert_equals "1" "$(count_of '' "$fd/comments.log")" "a refused transition must not post"

  for t in deployed verified repro-confirmed; do
    out=$(run_intake "$parts" comment "$GH_ISSUE" "$t") || fail "comment $t failed: $out"
  done
  assert_equals "4" "$(count_of '' "$fd/comments.log")" "each transition posts once"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "comments must never close the issue"
  pass "transition comments are canonical, bounded, and never close the issue"
}

test_dry_run_changes_nothing() {
  local parts out
  parts=$(setup_case dry)
  out=$(run_intake "$parts" reconcile --dry-run) || fail "dry-run failed: $out"
  assert_contains "$out" "would-create" "dry-run must report the plan: $out"
  if task_present "$parts"; then fail "dry-run must create no task row"; fi
  assert_absent "${parts%%|*}/state/fm-sos-intake.cursor" "dry-run must not move the cursor"
  [ ! -f "${parts##*|}/comments.log" ] || fail "dry-run must post no comment"
  [ ! -f "${parts##*|}/spawn.log" ] || fail "dry-run must not dispatch"
  pass "dry-run reports the plan and changes nothing"
}

test_reconcile_creates_one_task_comment_watch_and_dispatch
test_reconcile_is_idempotent_across_replays_and_lost_cursors
test_lost_event_is_healed_from_github
test_watch_condition_never_reads_a_failure_as_closed
test_watch_fire_comments_closes_the_task_and_never_the_issue
test_comment_transitions_are_canonical_and_bounded
test_dry_run_changes_nothing
