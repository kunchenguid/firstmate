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
TASK_ID="fm-sos-$SOS_UUID"
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
  # The captain's autodispatch grant; tests of the ungranted path remove it.
  mkdir -p "$home/config"
  : > "$home/config/sos-autodispatch"
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
  FM_SOS_TASKS="${FM_SOS_TASKS_OVERRIDE:-$TASKS_AXI}" \
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

# install_tasks_axi_stub <fakebin>: put a tasks-axi on the intake's PATH whose
# `add --help` reports whatever the fixture's tasks-with-flags marker selects,
# whose `add` logs its argv and reports a fresh row, and which delegates every
# other command to this environment's real tasks-axi.
install_tasks_axi_stub() {
  local fb=$1 real
  real=$(command -v tasks-axi)
  cat > "$fb/tasks-axi" <<SH
#!/usr/bin/env bash
set -u
FAKE="\${FM_SOS_FAKE_DIR:?}"
if [ "\${1:-}" = add ] && [ "\${2:-}" = --help ]; then
  if [ -f "\$FAKE/tasks-with-flags" ]; then
    printf '%s\\n' 'flags: --kind <k>, --repo <n>, --priority <0-4>' '  --why "<one line>"' '  --due <date>'
  else
    printf '%s\\n' 'flags: --kind <k>, --repo <n>, --priority <0-4>'
  fi
  exit 0
fi
if [ "\${1:-}" = add ]; then
  printf '%s\\n' "\$*" >> "\$FAKE/tasks.log"
  due=""
  prev=""
  for a in "\$@"; do
    case "\$prev" in
      --due) due="\$a" ;;
    esac
    case "\$a" in
      --due=*) due="\${a#--due=}" ;;
    esac
    prev="\$a"
  done
  printf '{"id":"%s","due":"%s"}\\n' "\$2" "\$due" > "\$FAKE/row.json"
  printf '{"ok":true,"action":"add","already":false}\\n'
  exit 0
fi
exec "$real" "\$@"
SH
  chmod +x "$fb/tasks-axi"
}

# write_beads_toml <home>: point this home's backlog at a beads backend.
write_beads_toml() {
  cat > "$1/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = ".beads"
prefix = "fm"
EOF
}

# stub_row_due <fakedir>: the due the stub's row record carries.
stub_row_due() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("due") or "")' \
    "$1/row.json" 2>/dev/null || true
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
  assert_no_grep "Auto-dispatched" "$fd/comments.log" \
    "the comment must not claim a dispatch that has not happened"

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

  out=$(run_intake "$parts" comment "$GH_ISSUE" dispatched) || fail "comment dispatched failed: $out"
  assert_contains "$(cat "$fd/comments.log")" "task \`fm-sos-gh-issue-$GH_ISSUE\`" \
    "a manual dispatched comment must name the task row"
  assert_no_grep "Auto-dispatched" "$fd/comments.log" \
    "a manual dispatched comment must not claim a dispatch that has not happened"
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

test_reconcile_folds_one_ticket_to_one_key() {
  local parts fd out upper
  parts=$(setup_case fold)
  fd=${parts##*|}
  upper=$(printf '%s' "$SOS_UUID" | tr '[:lower:]' '[:upper:]')

  # The bridge dedupe key and the body's SOS ID are one message id in two
  # cases: one ticket must still yield one row, one comment, one dispatch.
  set_bridge_events "$fd" 1 "$upper" "$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" "one ticket must fold to one row: $out"
  task_present "$parts" || fail "the SOS-keyed row is missing"
  if task_present "$parts" "fm-sos-$upper"; then
    fail "case divergence between the event key and the body key minted a second row"
  fi
  assert_equals "1" "$(count_of 'SOS dispatch' "$fd/comments.log")" \
    "one ticket must post one dispatched comment: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "one ticket must dispatch one crewmate"
  pass "one ticket folds to one key across the event and the issue body"
}

test_ticket_keeps_one_key_across_passes() {
  local parts fd out
  parts=$(setup_case stablekey)
  fd=${parts##*|}

  # The body no longer parses (marker edited away or format drift) while the
  # bridge event is unconsumed: the fallback key must not fork the ticket.
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"### SOS Voice Ticket\\nreport text with no id marker\\n"}]
EOF
  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" "the ticket must fold to one row: $out"
  task_present "$parts" || fail "the event's SOS row is missing"
  if task_present "$parts" "fm-sos-gh-issue-$GH_ISSUE"; then
    fail "the fallback key minted a second row for one ticket"
  fi

  # The event is drained now: the marker-less issue alone must land on the
  # row, comment, and dispatch the first pass already recorded.
  set_bridge_empty "$fd"
  out=$(run_intake "$parts" reconcile) || fail "second reconcile failed: $out"
  assert_contains "$out" "task_created=0" "a later pass must not mint a second row: $out"
  assert_contains "$out" "dispatched=0" "a later pass must not re-dispatch: $out"
  if task_present "$parts" "fm-sos-gh-issue-$GH_ISSUE"; then
    fail "the fallback key forked the ticket on a later pass"
  fi
  assert_equals "1" "$(count_of 'SOS dispatch' "$fd/comments.log")" "the ticket must stay one comment"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "the ticket must stay one dispatch"
  pass "a ticket keeps one key across passes even when its marker is gone"
}

test_reconcile_survives_a_pile_up_of_large_reports() {
  local parts fd out big
  parts=$(setup_case bigbodies)
  fd=${parts##*|}

  # One open report larger than a single argv string: the fold must still see
  # it (Linux caps one argv string at 128KiB).
  big=$(head -c 300000 /dev/zero | tr '\0' 'x')
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"### SOS Voice Ticket\n- **SOS ID:** \`$SOS_UUID\`\n$big"}]
EOF
  out=$(run_intake "$parts" reconcile) || fail "reconcile failed on a large report: $out"
  assert_contains "$out" "task_created=1" "a large report must still be picked up: $out"
  assert_contains "$out" "dispatched=1" "a large report must still dispatch: $out"
  pass "reconcile survives a pile-up of large open reports"
}

test_status_reports_rows_and_live_watches() {
  local parts home out
  parts=$(setup_case status)
  home=${parts%%|*}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"

  out=$(run_intake "$parts" status) || fail "status failed: $out"
  assert_contains "$out" "fm-sos-$SOS_UUID" "status must list the sos task rows: $out"
  assert_contains "$out" "when-sos-$GH_ISSUE" "status must list the armed close watch: $out"

  # A watch that reached its terminal outcome keeps its spec but loses its
  # registration: status must not report it as armed.
  rm -f "$home/state/procevent/when-sos-$GH_ISSUE.source"
  out=$(run_intake "$parts" status) || fail "status failed: $out"
  assert_not_contains "$out" "when-sos-$GH_ISSUE" \
    "status must not report a retired watch as armed: $out"
  pass "status reports the sos rows and only live close watches"
}

test_reconcile_rearms_a_dead_watch_with_no_captured_verdict() {
  local parts home out
  parts=$(setup_case rearms)
  home=${parts%%|*}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"
  assert_present "$home/state/procevent/when-sos-$GH_ISSUE.source" "the close watch must register"

  # The registration is gone while spec/trust/fired stay and no outcome was
  # captured for this source: the watch died without reaching a verdict.
  rm -f "$home/state/procevent/when-sos-$GH_ISSUE.source"
  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_present "$home/state/procevent/when-sos-$GH_ISSUE.source" \
    "reconcile must re-arm a watch that reached no verdict: $out"
  assert_equals "1" "$(count_of 'fm-spawn' "${parts##*|}/spawn.log")" \
    "re-arming a watch must not dispatch again"
  pass "reconcile re-arms a dead close watch that captured no verdict"
}

test_watch_fire_owes_the_close_until_the_row_closes() {
  local parts fd out rc
  parts=$(setup_case closeowed)
  fd=${parts##*|}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"

  cat > "$fd/tasks-flaky" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  done) exit 1 ;;
esac
exec "$TASKS_AXI" "\$@"
SH
  chmod +x "$fd/tasks-flaky"

  out=$(FM_SOS_TASKS_OVERRIDE="$fd/tasks-flaky" run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID" 2>&1)
  rc=$?
  expect_code 1 "$rc" "an owed close must exit non-zero so the runner reports action-failed: $out"
  assert_equals "queued" "$(task_state_of "$parts")" "the row must still be open"
  assert_contains "$out" "close stays owed" "watch-fire must report the owed close: $out"

  # The close is still owed: the next run must finish it, not no-op.
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "re-run failed: $out"
  assert_contains "$out" "captain-closed" "the owed close must complete: $out"
  assert_equals "done" "$(task_state_of "$parts")" "the row must close once the tool recovers"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the close comment must post exactly once across both runs"
  pass "watch-fire records the close only after the row actually closes"
}

test_reconcile_exits_nonzero_when_a_pass_leaves_work_owed() {
  local parts fd out rc
  parts=$(setup_case blocked)
  fd=${parts##*|}
  touch "$fd/gh-broken"

  out=$(run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "a pass that left work owed must exit non-zero (output: $out)"
  task_present "$parts" || fail "the owed row must still be ensured"
  assert_equals "0" "$(count_of 'SOS dispatch' "$fd/comments.log")" \
    "the owed comment must not be posted by a failed pass"
  pass "a blocked reconcile pass exits non-zero"
}

test_reconcile_surfaces_the_task_ensure_failure() {
  local parts fd out rc
  parts=$(setup_case ensurefail)
  fd=${parts##*|}

  cat > "$fd/tasks-broken" <<SH
#!/usr/bin/env bash
FAKE="\${FM_SOS_FAKE_DIR:?}"
echo "\$*" >> "\$FAKE/tasks.log"
case "\${1:-}" in
  add)
    echo 'error: backlog backend unavailable' >&2
    echo 'retry with Authorization: Bearer abcdef0123456789abcdef0123456789abcdef01' >&2
    exit 2 ;;
esac
exec "$TASKS_AXI" "\$@"
SH
  chmod +x "$fd/tasks-broken"

  out=$(FM_SOS_TASKS_OVERRIDE="$fd/tasks-broken" run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "a pass whose ensure failed must exit non-zero: $out"
  assert_contains "$out" "backlog backend unavailable" "the tasks-axi cause must reach the operator: $out"
  assert_contains "$out" "<redacted>" "tool diagnostics must be redacted: $out"
  assert_not_contains "$out" "abcdef0123456789abcdef0123456789abcdef01" \
    "no token-like text may reach the operator line: $out"
  assert_contains "$(cat "$fd/tasks.log" 2>/dev/null)" "--priority 1" \
    "the row must be created at the P0/P1 priority the deploy backend accepts"
  assert_equals "1" "$(count_of 'SOS dispatch' "$fd/comments.log")" \
    "an ensure failure must not stop the dispatched comment: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "an ensure failure must not stop intake from dispatching the ticket"
  pass "a failed task ensure surfaces its redacted cause and intake continues"
}

test_reconcile_rejects_the_removed_dispatch_flags() {
  local parts out rc
  parts=$(setup_case dispatchflag)

  out=$(run_intake "$parts" reconcile --dispatch 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--dispatch is absent from the usage contract and must be refused: $out"
  assert_contains "$out" "unknown argument: --dispatch" "the refusal must name the flag: $out"

  out=$(run_intake "$parts" reconcile --no-dispatch 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "--no-dispatch is absent from the usage contract and must be refused: $out"
  assert_contains "$out" "unknown argument: --no-dispatch" "the refusal must name the flag: $out"

  if task_present "$parts"; then fail "a refused pass must change nothing"; fi
  pass "reconcile refuses the removed dispatch flags"
}

test_overlapping_reconcile_passes_serialize() {
  local parts fd fb a_pid
  parts=$(setup_case overlap)
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)

  # A spawn slow enough for a second pass to start inside its guard window.
  cat > "$fb/fm-spawn" <<SH
#!/usr/bin/env bash
set -u
FAKE="\${FM_SOS_FAKE_DIR:?}"
echo "fm-spawn \$*" >> "\$FAKE/spawn.log"
sleep 3
exit 0
SH
  chmod +x "$fb/fm-spawn"

  (run_intake "$parts" reconcile >"$fd/pass-a.out" 2>&1) &
  a_pid=$!
  sleep 0.5
  run_intake "$parts" reconcile >"$fd/pass-b.out" 2>&1
  wait "$a_pid"

  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "overlapping passes must dispatch one crewmate: $(cat "$fd/spawn.log" 2>/dev/null)"
  assert_equals "1" "$(count_of 'SOS dispatch' "$fd/comments.log")" \
    "overlapping passes must post one dispatched comment: $(cat "$fd/comments.log" 2>/dev/null)"
  pass "overlapping reconcile passes serialize on the intake lock"
}

test_reconcile_does_not_rearm_after_a_terminal_verdict() {
  local parts home out rc result
  parts=$(setup_case nevertrue)
  home=${parts%%|*}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"
  assert_present "$home/state/procevent/when-sos-$GH_ISSUE.source" "the close watch must register"

  # The runner captures the never-true outcome and then retires the
  # registration; spec/trust/fired and the captured result both stay behind.
  mkdir -p "$home/state/procevent-inbox"
  result="$home/state/procevent-inbox/when-sos-$GH_ISSUE.1.result"
  cat > "$result" <<EOF
when: when-sos-$GH_ISSUE
status: never-true
detail: condition never held before the deadline
condition_polls: 0
EOF
  assert_equals "never-true" \
    "$(FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" classify "$result")" \
    "the fixture must be a real never-true verdict"
  : > "$home/state/procevent-inbox/when-sos-$GH_ISSUE.1.handled"
  rm -f "$home/state/procevent/when-sos-$GH_ISSUE.source"

  out=$(run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 0 "$rc" "a finished watch must not fail the pass: $out"
  assert_absent "$home/state/procevent/when-sos-$GH_ISSUE.source" \
    "reconcile must not re-arm past a captured terminal verdict"
  assert_present "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "the finished watch's own state must be left alone"
  assert_equals "1" "$(count_of 'fm-spawn' "${parts##*|}/spawn.log")" \
    "a finished watch must not change dispatching"
  pass "reconcile does not re-arm a close watch that already reached a terminal verdict"
}

test_reconcile_rearms_after_a_run_that_did_not_complete() {
  local parts home out status result
  for status in condition-error rejected; do
    parts=$(setup_case "rearm-$status")
    home=${parts%%|*}
    run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed for $status"
    mkdir -p "$home/state/procevent-inbox"
    result="$home/state/procevent-inbox/when-sos-$GH_ISSUE.1.result"
    printf 'when: when-sos-%s\nstatus: %s\ndetail: fixture\n' "$GH_ISSUE" "$status" > "$result"
    : > "$home/state/procevent-inbox/when-sos-$GH_ISSUE.1.handled"
    assert_equals "$status" \
      "$(FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" classify "$result")" \
      "the fixture must classify as $status"
    rm -f "$home/state/procevent/when-sos-$GH_ISSUE.source"
    out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed for $status: $out"
    assert_present "$home/state/procevent/when-sos-$GH_ISSUE.source" \
      "reconcile must re-arm after $status on a still-open issue: $out"
  done
  pass "reconcile re-arms a close watch whose run died before completing"
}

test_failed_dispatch_stays_owed_and_is_retried() {
  local parts home fb fd out rc
  parts=$(setup_case spawnfail)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)

  cat > "$fb/fm-spawn" <<SH
#!/usr/bin/env bash
set -u
FAKE="\${FM_SOS_FAKE_DIR:?}"
if [ -f "\$FAKE/spawn-broken" ]; then
  echo "error: spawn cannot start" >&2
  exit 1
fi
echo "fm-spawn \$*" >> "\$FAKE/spawn.log"
exit 0
SH
  chmod +x "$fb/fm-spawn"
  touch "$fd/spawn-broken"

  out=$(run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "a failed spawn must leave the pass blocked: $out"
  assert_contains "$out" "dispatch-blocked key=$SOS_UUID issue=$GH_ISSUE reason=spawn-failed" \
    "the spawn failure must be reported as a dispatch block: $out"
  assert_no_grep "dispatch key=" "$home/state/fm-sos-intake.log" \
    "a failed spawn must not write the once-only dispatch guard"

  rm -f "$fd/spawn-broken"
  out=$(run_intake "$parts" reconcile 2>&1) || fail "retry reconcile failed: $out"
  assert_contains "$out" "dispatched=1" "the owed dispatch must run on the retry: $out"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "exactly one crewmate must spawn"
  assert_grep "dispatch key=" "$home/state/fm-sos-intake.log" \
    "the dispatch guard must be recorded for the successful spawn"
  pass "a failed dispatch stays owed and is retried on the next pass"
}

test_dispatch_rescaffolds_a_brief_recorded_for_another_mode() {
  local parts home fb fd out
  parts=$(setup_case briefmode)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)

  # A spawn that refuses a brief whose recorded mode disagrees, as fm-spawn does.
  cat > "$fb/fm-spawn" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
id=$1
shift
mode=no-mistakes
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode=$2; shift 2 ;;
    *) shift ;;
  esac
done
recorded=$(sed -n 's/^Delivery contract: mode=\([^ ]*\).*$/\1/p' "$FM_HOME/data/$id/brief.md" | head -n 1)
if [ -n "$recorded" ] && [ "$recorded" != "$mode" ]; then
  echo "error: delivery mismatch for $id: the brief says mode=$recorded but this spawn passed --mode $mode" >&2
  exit 1
fi
echo "fm-spawn $*" >> "$FAKE/spawn.log"
exit 0
SH
  chmod +x "$fb/fm-spawn"

  mkdir -p "$home/data/$TASK_ID"
  printf '# Brief\n\nDelivery contract: mode=direct-PR\n\n{TASK}\n{FIRSTMATE_SPEC}\n' \
    > "$home/data/$TASK_ID/brief.md"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the dispatch must launch after the brief is corrected: $out"
  assert_grep "Delivery contract: mode=no-mistakes" "$home/data/$TASK_ID/brief.md" \
    "the brief must record the mode this pass spawns with"
  pass "dispatch re-scaffolds a brief recorded for another delivery mode"
}

test_ticket_key_stabilizes_before_the_first_successful_ensure() {
  local parts home fd out rc
  parts=$(setup_case keystable)
  home=${parts%%|*}
  fd=${parts##*|}

  # Marker-less body and no event yet: the derived key is the fallback, and
  # the backlog backend refuses the row.
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"report text with no id marker"}]
EOF
  set_bridge_empty "$fd"
  cat > "$fd/tasks-broken" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  add) echo 'error: backlog backend unavailable' >&2; exit 2 ;;
esac
exec "$TASKS_AXI" "\$@"
SH
  chmod +x "$fd/tasks-broken"

  out=$(FM_SOS_TASKS_OVERRIDE="$fd/tasks-broken" run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "a failing ensure must leave the pass owed: $out"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the first pass must dispatch the marker-less ticket: $out"

  # The bridge recovers: the deferred event carries the SOS uuid.
  set_bridge_events "$fd" 1 "$SOS_UUID" "$GH_ISSUE"
  out=$(FM_SOS_TASKS_OVERRIDE="$fd/tasks-broken" run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "the ensure is still owed: $out"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one ticket must never dispatch a second crewmate: $out"
  assert_equals "1" "$(count_of 'SOS dispatch' "$fd/comments.log")" \
    "one ticket must never post a second dispatched comment: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_grep "dispatch key=gh-issue-$GH_ISSUE issue=$GH_ISSUE" \
    "$home/state/fm-sos-intake.log" "the first recorded key must stay the ticket's key"
  pass "the issue key stabilizes before the first successful ensure"
}

test_event_for_a_closed_issue_gets_no_comment_or_crewmate() {
  local parts home fd out
  parts=$(setup_case closedevent)
  home=${parts%%|*}
  fd=${parts##*|}

  # The event arrives after the captain closed the ticket: absent from the
  # open list, and gh reports it closed.
  printf '[]\n' > "$fd/gh-list.json"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "skip: #$GH_ISSUE is closed" \
    "the closed ticket must be reported as skipped: $out"
  task_present "$parts" || fail "the row must still be ensured for a late-discovered closed ticket"
  assert_present "$home/state/procevent/when-sos-$GH_ISSUE.source" \
    "the close watch must still be armed: $out"
  [ ! -f "$fd/comments.log" ] || \
    fail "a closed ticket must not get the dispatched comment: $(cat "$fd/comments.log")"
  [ ! -f "$fd/spawn.log" ] || \
    fail "a closed ticket must not spawn a crewmate: $(cat "$fd/spawn.log")"
  assert_equals "1" "$(cat "$home/state/fm-sos-intake.cursor")" \
    "the event must still be consumed"
  pass "a bridge event for a closed ticket keeps its row and watch but no dispatch"
}

test_replay_across_heal_and_event_is_exactly_one_dispatch() {
  local parts fd out rc
  parts=$(setup_case replayfold)
  fd=${parts##*|}

  # Run 1: the open issue alone (GH heal), no SOS id marker, and the backlog
  # backend refuses the row - the ticket is still picked up under the
  # fallback key.
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"report text with no id marker"}]
EOF
  set_bridge_empty "$fd"
  cat > "$fd/tasks-broken" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  add) echo 'error: backlog backend unavailable' >&2; exit 2 ;;
esac
exec "$TASKS_AXI" "\$@"
SH
  chmod +x "$fd/tasks-broken"
  out=$(FM_SOS_TASKS_OVERRIDE="$fd/tasks-broken" run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "the owed ensure must fail the pass: $out"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "run 1 must dispatch once: $out"

  # Run 2: the same ticket replays as a bridge event (uuid dedupe key) with the
  # backend recovered - both sources must fold onto the first recorded key.
  set_bridge_events "$fd" 1 "$SOS_UUID" "$GH_ISSUE"
  out=$(run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 0 "$rc" "the recovered pass must succeed: $out"
  assert_contains "$out" "dispatched=0" "the replay must not dispatch again: $out"
  task_present "$parts" "fm-sos-gh-issue-$GH_ISSUE" || \
    fail "the row must land on the ticket's first recorded key"
  if task_present "$parts" "fm-sos-$SOS_UUID"; then
    fail "the replayed event minted a second row under its own key"
  fi
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one ticket must stay exactly one dispatch: $(cat "$fd/spawn.log" 2>/dev/null)"
  assert_equals "1" "$(count_of 'SOS dispatch' "$fd/comments.log")" \
    "one ticket must stay one dispatched comment"
  pass "a replay across the heal and event paths is exactly one dispatch"
}

test_event_without_a_url_keeps_every_column() {
  local parts home fd out
  parts=$(setup_case nourl)
  home=${parts%%|*}
  fd=${parts##*|}

  # Event-only candidate (absent from the open list) whose payload carries no
  # gh_issue_url.
  printf '[]\n' > "$fd/gh-list.json"
  cat > "$fd/bridge.json" <<EOF
{"events":[{"id":1,"kind":"sos","dedupeKey":"$SOS_UUID","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${SOS_UUID%%-*}","gh_issue":$GH_ISSUE}}],"cursor":1,"backlog":0}
EOF

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  task_present "$parts" || fail "the row must be ensured"
  assert_contains "$(FM_HOME="$home" "$TASKS_AXI" show "$TASK_ID" 2>/dev/null)" \
    "GitHub issue: https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE" \
    "an absent url must fall back to the issue URL"
  assert_equals "1" "$(cat "$home/state/fm-sos-intake.cursor")" \
    "the event must be consumed: $out"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "the event must dispatch once"
  pass "a candidate with no url keeps every column"
}

test_intake_creates_a_row_on_a_due_required_beads_home() {
  local parts home out due desc
  command -v bd >/dev/null 2>&1 || { pass "skipped: bd not found (beads backend coverage)"; return 0; }

  parts=$(setup_case beads)
  home=${parts%%|*}

  # The deploy home's shape: a beads store whose due governance is on.
  cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = ".beads"
prefix = "fm"
EOF
  (cd "$home" && bd init --prefix fm >/dev/null 2>&1) || { pass "skipped: bd could not initialize a fixture store"; return 0; }
  printf '\ndue:\n    required: true\n' >> "$home/.beads/config.yaml"
  if ! FM_HOME="$home" "$TASKS_AXI" list >/dev/null 2>&1; then
    pass "skipped: this tasks-axi cannot operate on a beads home"
    return 0
  fi
  if (cd "$home" && bd create "due governance probe" --id fm-due-probe --type task --json >/dev/null 2>&1); then
    fail "the fixture store must reject a create that carries no due"
  fi

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed on the beads home: $out"
  task_present "$parts" || fail "intake must create a row on a due-required beads home: $out"
  due=$(cd "$home" && bd show "$TASK_ID" --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print(d.get("due_at") or "")' 2>/dev/null) || due=""
  [ -n "$due" ] || fail "the created row must carry a due under due governance: $out"
  desc=$(cd "$home" && bd show "$TASK_ID" --json 2>/dev/null | python3 -c 'import json,sys
d = json.load(sys.stdin)
d = d[0] if isinstance(d, list) else d
print(d.get("description") or "")' 2>/dev/null) || desc=""
  assert_contains "$desc" "priority-why: staff SOS report awaiting fix" \
    "the P0/P1 reason must reach the beads record"

  if FM_HOME="$home" "$TASKS_AXI" add fm-p1-no-reason "no reason" --kind ship --repo portal \
      --priority 1 --json >/dev/null 2>&1; then
    fail "priority 1 must still require --why on a beads home"
  fi
  pass "intake creates a row on a due-required beads home"
}

test_tool_flags_are_capability_gated_per_run() {
  local parts home fd fb out argv
  parts=$(setup_case flagsnpm)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  install_tasks_axi_stub "$fb"
  write_beads_toml "$home"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" "the row must still be created: $out"
  assert_present "$fd/tasks.log" "the stub must have received the add"
  argv=$(cat "$fd/tasks.log" 2>/dev/null)
  assert_not_contains "$argv" "--why" "a tool whose help omits --why must never receive it"
  assert_not_contains "$argv" "--due" "a tool whose help omits --due must never receive it"
  assert_contains "$out" \
    "fm-tasks-axi: stripping --due/--why: installed tasks-axi does not accept them (due not applied to row)" \
    "a stripped due must never look like success"
  pass "a tool without --why or --due receives neither flag"
}

test_tool_flags_pass_through_when_the_tool_and_backend_allow_them() {
  local parts home fd fb out argv
  # A fork-like tool on a markdown home: --why passes, --due does not apply.
  parts=$(setup_case flagsmarkdown)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  install_tasks_axi_stub "$fb"
  touch "$fd/tasks-with-flags"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "markdown pass failed: $out"
  assert_contains "$out" "task_created=1" "the row must be created: $out"
  assert_present "$fd/tasks.log" "the stub must have received the add"
  argv=$(cat "$fd/tasks.log" 2>/dev/null)
  assert_contains "$argv" "--why staff SOS report awaiting fix" \
    "a tool whose help takes --why must receive it at P1"
  assert_not_contains "$argv" "--due" "a markdown home stores no due"

  # The same tool on a beads-configured home: both flags pass through.
  parts=$(setup_case flagsbeads)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  install_tasks_axi_stub "$fb"
  touch "$fd/tasks-with-flags"
  write_beads_toml "$home"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "beads pass failed: $out"
  assert_contains "$out" "task_created=1" "the row must be created: $out"
  assert_present "$fd/tasks.log" "the stub must have received the add"
  argv=$(cat "$fd/tasks.log" 2>/dev/null)
  assert_contains "$argv" "--why staff SOS report awaiting fix" \
    "the why must reach a fork-like tool"
  assert_contains "$argv" "--due +2w" \
    "the due must reach a beads store whose tool takes it"
  assert_equals "+2w" "$(stub_row_due "$fd")" "the row's due must equal FM_SOS_DUE"
  assert_not_contains "$out" "fm-tasks-axi: stripping" \
    "a tool that accepts the flags must not be warned about"

  out=$(FM_SOS_DUE=+5d run_intake "$parts" reconcile 2>&1) \
    || fail "FM_SOS_DUE pass failed: $out"
  assert_equals "+5d" "$(stub_row_due "$fd")" \
    "an operator-set FM_SOS_DUE must reach the row"
  pass "flags pass through only for a tool and a backend that accept them"
}

test_reopened_issue_after_terminal_is_loud_once() {
  local parts home fd out ledger
  parts=$(setup_case reopened)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-sos-intake.log"

  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"
  assert_equals "1" "$(count_of 'dispatch key=' "$ledger")" "the first pass must dispatch"

  # The captain closes it: watch-fire closes the row and records the close,
  # the watch fires and its fired verdict is captured, then the issue reopens.
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID" 2>&1) \
    || fail "watch-fire failed: $out"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/when-sos-$GH_ISSUE.1.result" <<EOF
when: when-sos-$GH_ISSUE
status: fired
detail: captain closed the issue
condition_polls: 3
action_exit: 0
EOF
  rm -f "$home/state/procevent/when-sos-$GH_ISSUE.source"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reopened pass failed: $out"
  assert_contains "$out" "reopened-after-terminal key=$SOS_UUID issue=$GH_ISSUE" \
    "the reopen must be logged with its exact class: $out"
  assert_contains "$out" "dispatched=0" "a reopened ticket must not be dispatched: $out"
  assert_equals "1" "$(count_of 'reopened key=' "$ledger")" \
    "the reopen must be recorded once"
  assert_contains "$(run_intake "$parts" status 2>&1)" "reopened key=$SOS_UUID issue=$GH_ISSUE" \
    "status must list the reopened ticket"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "no second crewmate may launch"
  assert_equals "1" "$(count_of 'SOS dispatch' "$fd/comments.log")" \
    "no second dispatched comment may post"
  assert_absent "$home/state/procevent/when-sos-$GH_ISSUE.source" \
    "a captured fired verdict must never be re-armed by reconcile"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "repeat pass failed: $out"
  assert_equals "1" "$(count_of 'reopened key=' "$ledger")" \
    "the signal must stay recorded once"
  assert_not_contains "$out" "reopened-after-terminal" \
    "a repeat pass must not repeat the signal"
  pass "a reopened-after-terminal ticket is loud once, listed, and never re-dispatched"
}

test_reopened_without_a_dispatch_still_launches_nothing() {
  local parts home fd fb out rc ledger
  parts=$(setup_case reopennever)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  ledger="$home/state/fm-sos-intake.log"

  # First pass: the spawn fails, so no dispatch is ever recorded.
  cat > "$fb/fm-spawn" <<SH
#!/usr/bin/env bash
set -u
FAKE="\${FM_SOS_FAKE_DIR:?}"
if [ -f "\$FAKE/spawn-broken" ]; then
  echo "error: spawn cannot start" >&2
  exit 1
fi
echo "fm-spawn \$*" >> "\$FAKE/spawn.log"
exit 0
SH
  chmod +x "$fb/fm-spawn"
  touch "$fd/spawn-broken"
  out=$(run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "a failed spawn must leave the pass owed: $out"
  assert_equals "0" "$(count_of 'dispatch key=' "$ledger")" \
    "a failed spawn must not record a dispatch"

  # The captain closes it anyway: the row closes and the fired verdict lands.
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID" 2>&1) \
    || fail "watch-fire failed: $out"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$home/state/procevent-inbox/when-sos-$GH_ISSUE.1.result" <<EOF
when: when-sos-$GH_ISSUE
status: fired
detail: captain closed the issue
EOF
  rm -f "$home/state/procevent/when-sos-$GH_ISSUE.source"
  rm -f "$fd/spawn-broken"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reopened pass failed: $out"
  assert_contains "$out" "reopened-after-terminal key=$SOS_UUID issue=$GH_ISSUE" \
    "the reopen must be logged: $out"
  assert_contains "$out" "dispatched=0" "the reopened ticket must not be dispatched: $out"
  assert_equals "0" "$(count_of 'dispatch key=' "$ledger")" \
    "with no dispatch recorded, only the reopened guard can hold it back"
  assert_equals "0" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "no crewmate may launch for a reopened-after-terminal ticket"
  assert_grep "dispatch-skipped key=$SOS_UUID issue=$GH_ISSUE reason=reopened-terminal" "$ledger" \
    "the reopened-after-terminal guard must supersede the block durably"
  assert_not_contains "$(run_intake "$parts" status 2>&1)" \
    "dispatch-blocked key=$SOS_UUID" \
    "status must not list a block for a ticket that can never dispatch"
  pass "a never-dispatched reopened ticket still launches nothing"
}

test_dispatch_consults_the_profile_and_completes() {
  local parts home fd fb out
  parts=$(setup_case profile)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  mkdir -p "$home/config"
  printf '%s\n' '{"rules":[{"when":"sos","profiles":[{"harness":"fleet-claude"}]}]}' \
    > "$home/config/crew-dispatch.json"
  cat > "$fb/fm-dispatch-resolve" <<SH
#!/usr/bin/env bash
printf '%s\\n' 'dispatch-resolve:' '  status: clear' '  profile: --harness fleet-claude'
SH
  chmod +x "$fb/fm-dispatch-resolve"

  out=$(FM_SOS_RESOLVE="$fb/fm-dispatch-resolve" run_intake "$parts" reconcile 2>&1) \
    || fail "reconcile failed: $out"
  assert_contains "$out" "dispatched=1" "the ticket must dispatch: $out"
  assert_contains "$(cat "$fd/spawn.log" 2>/dev/null)" "--harness fleet-claude --mode no-mistakes" \
    "the spawn must receive the resolved profile alongside --mode"
  assert_grep "dispatch key=" "$home/state/fm-sos-intake.log" \
    "the dispatch must be recorded"
  assert_equals "1" "$(cat "$home/state/fm-sos-intake.cursor")" "the cursor must advance"
  pass "reconcile consults the dispatch profile and completes end to end"
}

test_unresolvable_profile_blocks_the_dispatch_loudly() {
  local parts home fd fb out rc
  parts=$(setup_case profileblocked)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  mkdir -p "$home/config"
  printf '%s\n' '{"rules":[{"when":"sos","profiles":[{"harness":"fleet-claude"}]}]}' \
    > "$home/config/crew-dispatch.json"
  cat > "$fb/fm-dispatch-resolve" <<SH
#!/usr/bin/env bash
printf '%s\\n' 'dispatch-resolve:' '  status: escalate' '  reason: approval required'
SH
  chmod +x "$fb/fm-dispatch-resolve"

  out=$(FM_SOS_RESOLVE="$fb/fm-dispatch-resolve" run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "an unresolvable profile must fail the pass: $out"
  assert_contains "$out" "dispatch-blocked key=$SOS_UUID issue=$GH_ISSUE reason=escalate" \
    "the named, greppable line must appear: $out"
  assert_grep "dispatch-blocked key=$SOS_UUID issue=$GH_ISSUE" \
    "$home/state/fm-sos-intake.log" "the block must be durable in the ledger"
  assert_contains "$(run_intake "$parts" status 2>&1)" \
    "dispatch-blocked key=$SOS_UUID issue=$GH_ISSUE" "status must surface the block"
  assert_absent "$home/state/fm-sos-intake.cursor" "the cursor must not advance"
  assert_equals "0" "$(count_of 'fm-spawn' "$fd/spawn.log")" "no crewmate may launch"
  pass "an unresolvable profile blocks the dispatch loudly and stays owed"
}

test_status_scopes_a_dispatch_block_to_an_open_ticket() {
  local parts home fd fb out rc ledger status_out
  parts=$(setup_case blockscope)
  home=${parts%%|*}
  fd=${parts##*|}
  fb=$(printf '%s' "$parts" | cut -d'|' -f2)
  ledger="$home/state/fm-sos-intake.log"

  cat > "$fb/fm-spawn" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_SOS_FAKE_DIR:?}"
if [ -f "$FAKE/spawn-broken" ]; then
  echo "error: spawn cannot start" >&2
  exit 1
fi
echo "fm-spawn $*" >> "$FAKE/spawn.log"
exit 0
SH
  chmod +x "$fb/fm-spawn"
  touch "$fd/spawn-broken"

  # An open ticket whose dispatch fails: the block is durable and status
  # lists it - the ticket is still open and owed.
  out=$(run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 1 "$rc" "a failed spawn must leave the pass owed: $out"
  assert_grep "dispatch-blocked key=$SOS_UUID issue=$GH_ISSUE" "$ledger" \
    "the block must be durable in the ledger"
  status_out=$(run_intake "$parts" status 2>&1)
  assert_contains "$status_out" "dispatch-blocked key=$SOS_UUID issue=$GH_ISSUE" \
    "an open ticket's block must be listed by status: $status_out"

  # The captain closes the issue: the next pass supersedes the block with an
  # appended dispatch-skipped line - never a rewrite - and status drops it.
  printf '[]\n' > "$fd/gh-list.json"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  rm -f "$fd/spawn-broken"

  out=$(run_intake "$parts" reconcile 2>&1)
  rc=$?
  expect_code 0 "$rc" "a closed ticket's pass must succeed: $out"
  assert_contains "$out" "dispatch-skipped key=$SOS_UUID issue=$GH_ISSUE reason=issue-closed" \
    "the superseding line must be reported: $out"
  assert_grep "dispatch-skipped key=$SOS_UUID issue=$GH_ISSUE reason=issue-closed" "$ledger" \
    "the superseding line must be durable in the ledger"
  assert_equals "1" "$(count_of 'dispatch-blocked key=' "$ledger")" \
    "the ledger is append-only: the original block line must survive"
  status_out=$(run_intake "$parts" status 2>&1)
  assert_not_contains "$status_out" "dispatch-blocked key=$SOS_UUID" \
    "status must not list a block for a ticket that can never dispatch: $status_out"

  # A repeat pass must not stack a second superseding line.
  out=$(run_intake "$parts" reconcile 2>&1) || fail "repeat pass failed: $out"
  assert_equals "1" "$(count_of 'dispatch-skipped key=' "$ledger")" \
    "the superseding line must be recorded once"
  pass "status lists a dispatch block only while the ticket is open and owed"
}

test_skill_documents_profile_dispatch() {
  local skill="$ROOT/.agents/skills/sos-dispatch-loop/SKILL.md"
  assert_grep "resolves the concrete profile" "$skill" \
    "the SKILL must document profile-consulting dispatch"
  assert_grep "dispatch-blocked" "$skill" \
    "the SKILL must document the dispatch-blocked class"
  assert_grep "surfaces it through \`bin/fm-sos-intake.sh status\`" "$skill" \
    "the SKILL must document the status surface"
  pass "the SKILL documents profile-consulting dispatch and its blocked class"
}

test_unknown_issue_state_never_dispatches() {
  local parts home fd out
  parts=$(setup_case unknownstate)
  home=${parts%%|*}
  fd=${parts##*|}

  # The event's issue is absent from the open list and its state read fails.
  printf '[]\n' > "$fd/gh-list.json"
  echo 'not json' > "$fd/gh-state-$GH_ISSUE"

  if out=$(run_intake "$parts" reconcile 2>&1); then
    fail "an unreadable issue state must fail the pass: $out"
  fi
  assert_contains "$out" "cannot read the state of #$GH_ISSUE" "the unknown state must be named: $out"
  [ ! -f "$fd/comments.log" ] || fail "an unknown state must not comment: $(cat "$fd/comments.log")"
  [ ! -f "$fd/spawn.log" ] || fail "an unknown state must not spawn: $(cat "$fd/spawn.log")"
  assert_absent "$home/state/fm-sos-intake.cursor" "the event must stay owed"
  pass "an unknown issue state keeps the ticket owed with no comment or crewmate"
}

test_repeated_transition_comment_posts_once() {
  local parts fd out
  parts=$(setup_case dupcomment)
  fd=${parts##*|}
  out=$(run_intake "$parts" comment "$GH_ISSUE" deployed "first") || fail "comment failed: $out"
  out=$(run_intake "$parts" comment "$GH_ISSUE" deployed "retry") || fail "retried comment failed: $out"
  assert_contains "$out" "already-commented" "the retry must report the recorded transition: $out"
  assert_equals "1" "$(count_of '' "$fd/comments.log")" "a retried transition must post once"
  pass "a retried transition posts its comment once"
}

test_source_outage_is_not_empty_work() {
  local parts fd out
  parts=$(setup_case outage)
  fd=${parts##*|}
  rm -f "$fd/bridge.json"
  touch "$fd/gh-broken"
  if out=$(run_intake "$parts" reconcile 2>&1); then
    fail "a pass with both sources down must fail: $out"
  fi
  assert_contains "$out" "no SOS source reachable" "the outage must be named: $out"
  assert_not_contains "$out" "no open SOS work" "an outage must not read as empty work: $out"

  rm -f "$fd/gh-broken"
  set_bridge_empty "$fd"
  printf '[]\n' > "$fd/gh-list.json"
  out=$(run_intake "$parts" reconcile 2>&1) || fail "a healthy empty pass must succeed: $out"
  assert_contains "$out" "no open SOS work" "a reachable empty backlog is empty work: $out"
  pass "a source outage fails loudly instead of reading as empty work"
}

test_dispatch_requires_the_captain_grant() {
  local parts home fd out
  parts=$(setup_case nogrant)
  home=${parts%%|*}
  fd=${parts##*|}
  rm -f "$home/config/sos-autodispatch"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "an ungranted pass must still succeed: $out"
  assert_contains "$out" "dispatch-held key=$SOS_UUID issue=$GH_ISSUE reason=autodispatch-not-granted" \
    "the held dispatch must be reported: $out"
  task_present "$parts" || fail "the row must still be ensured without the grant"
  [ ! -f "$fd/spawn.log" ] || fail "no crewmate may spawn without the grant: $(cat "$fd/spawn.log")"
  [ ! -f "$fd/comments.log" ] || fail "no dispatched comment without the grant: $(cat "$fd/comments.log")"
  assert_contains "$(run_intake "$parts" status 2>&1)" "autodispatch: not granted" \
    "status must show the missing grant"

  assert_absent "$home/state/fm-sos-intake.cursor" "a held event must keep the cursor unadvanced"

  # The ticket drops out of the sos-labeled list before the grant lands; the
  # replayed bridge event alone must still release the dispatch.
  printf '[]\n' > "$fd/gh-list.json"
  : > "$home/config/sos-autodispatch"
  out=$(run_intake "$parts" reconcile 2>&1) || fail "the granted pass failed: $out"
  assert_equals "1" "$(count_of "fm-spawn fm-sos-$SOS_UUID" "$fd/spawn.log")" \
    "the grant must release exactly one dispatch"
  pass "auto-dispatch waits for the captain's explicit grant"
}

test_reconcile_creates_one_task_comment_watch_and_dispatch
test_reconcile_is_idempotent_across_replays_and_lost_cursors
test_lost_event_is_healed_from_github
test_watch_condition_never_reads_a_failure_as_closed
test_watch_fire_comments_closes_the_task_and_never_the_issue
test_comment_transitions_are_canonical_and_bounded
test_dry_run_changes_nothing
test_reconcile_folds_one_ticket_to_one_key
test_ticket_keeps_one_key_across_passes
test_reconcile_survives_a_pile_up_of_large_reports
test_status_reports_rows_and_live_watches
test_reconcile_rearms_a_dead_watch_with_no_captured_verdict
test_watch_fire_owes_the_close_until_the_row_closes
test_reconcile_exits_nonzero_when_a_pass_leaves_work_owed
test_reconcile_surfaces_the_task_ensure_failure
test_reconcile_rejects_the_removed_dispatch_flags
test_overlapping_reconcile_passes_serialize
test_reconcile_does_not_rearm_after_a_terminal_verdict
test_reconcile_rearms_after_a_run_that_did_not_complete
test_failed_dispatch_stays_owed_and_is_retried
test_dispatch_rescaffolds_a_brief_recorded_for_another_mode
test_ticket_key_stabilizes_before_the_first_successful_ensure
test_event_for_a_closed_issue_gets_no_comment_or_crewmate
test_replay_across_heal_and_event_is_exactly_one_dispatch
test_event_without_a_url_keeps_every_column
test_intake_creates_a_row_on_a_due_required_beads_home
test_tool_flags_are_capability_gated_per_run
test_tool_flags_pass_through_when_the_tool_and_backend_allow_them
test_reopened_issue_after_terminal_is_loud_once
test_reopened_without_a_dispatch_still_launches_nothing
test_dispatch_consults_the_profile_and_completes
test_unresolvable_profile_blocks_the_dispatch_loudly
test_status_scopes_a_dispatch_block_to_an_open_ticket
test_skill_documents_profile_dispatch
test_unknown_issue_state_never_dispatches
test_repeated_transition_comment_posts_once
test_source_outage_is_not_empty_work
test_dispatch_requires_the_captain_grant
