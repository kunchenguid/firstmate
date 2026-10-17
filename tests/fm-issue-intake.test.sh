#!/usr/bin/env bash
# tests/fm-issue-intake.test.sh - the fleet issue dispatch loop's intake: one task row
# (a bead on a beads backend) per SOS keyed on the SOS UUID, one lifecycle
# comment per transition, one close watch per ticket, one dispatched crewmate
# per new ticket - and never a second of any of them across retries, replayed
# events, or lost cursors. Also pins the loop's hard invariant: intake and the
# close watch close a GitHub issue only for a not-supported decline; every
# other close belongs to the captain.
set -u

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTAKE="$ROOT/bin/fm-issue-intake.sh"
TASKS_AXI="$ROOT/bin/fm-tasks-axi.sh"
SOS_UUID="7f3c1a52-9b41-4c2e-9d6a-1f0b2c3d4e5f"
TASK_ID="fm-iss-$SOS_UUID"
GH_ISSUE=1921

TMP_ROOT=$(fm_test_tmproot fm-issue-intake)

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
FAKE="${FM_ISSUE_FAKE_DIR:?}"
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
        case "$*" in
          *--json*title*)
            [ -f "$FAKE/gh-view-fail-$n" ] && exit 1
            if [ -f "$FAKE/gh-view-$n.json" ]; then cat "$FAKE/gh-view-$n.json"
            else echo '{"title":"SOS: reported problem","body":"body","labels":[{"name":"sos"}]}'
            fi ;;
          *)
            [ -f "$FAKE/gh-state-fail-$n" ] && exit 1
            if [ -f "$FAKE/gh-state-$n" ]; then cat "$FAKE/gh-state-$n"; else echo '{"state":"OPEN"}'; fi ;;
        esac
        ;;
      edit)
        n="${3:-}"
        echo "edit $n $*" >> "$FAKE/edit.log"
        [ -f "$FAKE/edit-fail" ] && exit 1
        exit 0 ;;
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
      close)
        n="${3:-}"
        echo "CLOSE-ATTEMPTED" >> "$FAKE/gh.log"
        # The loop closes an issue only on a decline; every other path must
        # fail here, which pins every close to that one carve-out.
        [ -f "$FAKE/allow-close" ] || exit 97
        # A close is only safe once the close watch is gone: the decline must
        # retire the watch before this call, or a watcher could wake on the
        # close and post a captain-closed comment for a decline.
        if [ -n "${FM_HOME:-}" ] && [ -e "$FM_HOME/state/when/when-sos-$n.spec" ]; then
          echo "CLOSE-WATCH-ARMED" >> "$FAKE/gh.log"
        fi
        echo '{"state":"CLOSED"}' > "$FAKE/gh-state-$n"
        exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH

  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_ISSUE_FAKE_DIR:?}"
echo "curl $*" >> "$FAKE/curl.log"
cat "$FAKE/bridge.json"
SH

  cat > "$fb/fm-spawn" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_ISSUE_FAKE_DIR:?}"
echo "fm-spawn $*" >> "$FAKE/spawn.log"
[ -f "$FAKE/spawn-fail" ] && exit 1
exit 0
SH

  cat > "$fb/jev" <<'SH'
#!/usr/bin/env bash
set -u
FAKE="${FM_ISSUE_FAKE_DIR:?}"
echo "jev $*" >> "$FAKE/jev.log"
[ -f "$FAKE/jev-verdict" ] || { echo '{"verdict":"supported_bug","confidence":0.9,"fail_open":false}'; exit 0; }
case "$(cat "$FAKE/jev-verdict")" in
  fail) echo "jev: simulated outage" >&2; exit 1 ;;
  garbage) echo "not json at all"; exit 0 ;;
  v) printf '{"verdict":"%s","confidence":0.9,"fail_open":false}\n' "$(cat "$FAKE/jev-answer")" ;;
  *) printf '{"verdict":"%s","confidence":0.9,"fail_open":false}\n' "$(cat "$FAKE/jev-verdict")" ;;
esac
SH

  chmod +x "$fb/gh" "$fb/curl" "$fb/fm-spawn" "$fb/jev"

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
  FM_ISSUE_FAKE_DIR="$fd" \
  FM_ISSUE_BRIDGE_URL="http://bridge.invalid:8791" \
  FM_ISSUE_TASKS="${TEST_TASKS_OVERRIDE:-$TASKS_AXI}" \
  FM_ISSUE_SPAWN="$fb/fm-spawn" \
  FM_ISSUE_BRIEF="$ROOT/bin/fm-brief.sh" \
  FM_ISSUE_WHEN="$ROOT/bin/fm-procevent-when.sh" \
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

test_decline_comments_once_even_when_the_close_fails() {
  local parts home fd out
  parts=$(setup_case decline-retry)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "first reconcile failed: $out"
  assert_contains "$out" "failed: decline" "a failing close must be reported: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "the first pass posts exactly one decline comment"
  assert_equals "1" "$(count_of 'CLOSE-ATTEMPTED' "$fd/gh.log")" \
    "the first pass attempts the close once"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "retry reconcile failed: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "a retry after a failed close must not re-comment: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_equals "2" "$(count_of 'CLOSE-ATTEMPTED' "$fd/gh.log")" \
    "a retry must re-attempt only the close"

  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile) || fail "closing reconcile failed: $out"
  assert_contains "$out" "declined=1" "the decline must complete: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "the completing pass adds no comment"
  assert_equals "done" "$(task_state_of "$parts")" "the declined row must close"

  out=$(run_intake "$parts" reconcile) || fail "post-decline replay failed: $out"
  assert_contains "$out" "declined=1" "the decided decline replays as handled: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "a post-decline replay adds no comment"
  assert_equals "3" "$(count_of 'CLOSE-ATTEMPTED' "$fd/gh.log")" \
    "a completed decline is never closed again"
  pass "a decline comments once and a failed close retries only the close"
}

test_event_without_a_url_keeps_row_and_cursor_aligned() {
  local parts home fd out
  parts=$(setup_case no-url)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/bridge.json" <<EOF
{"events":[{"id":1,"kind":"sos","dedupeKey":"$SOS_UUID","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${SOS_UUID%%-*}","gh_issue":$GH_ISSUE}}],"cursor":1,"backlog":0}
EOF
  printf '[]\n' > "$fd/gh-list.json"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" \
    "a url-less event must still create its row: $out"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the cursor must land on the event id, never reset"
  assert_contains "$(FM_HOME="$home" "$TASKS_AXI" show "$TASK_ID" 2>/dev/null)" \
    "GitHub issue: https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE" \
    "an empty url must fall back to the canonical issue URL"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the url-less event must dispatch exactly once"
  pass "an event without a url keeps the row body and cursor aligned"
}

test_one_github_issue_is_never_two_candidates() {
  local parts home fd out upper
  upper=$(printf '%s' "$SOS_UUID" | tr '[:lower:]' '[:upper:]')

  # (a) an uppercased bridge dedupeKey against the lowercase body marker.
  parts=$(setup_case keycase)
  home=${parts%%|*}
  fd=${parts##*|}
  set_bridge_events "$fd" 1 "$upper" "$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "case reconcile failed: $out"
  assert_contains "$out" "task_created=1" \
    "an uppercased dedupeKey must merge with the lowercase marker: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "one ticket must get exactly one dispatched comment"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one ticket must spawn exactly once"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-$upper" >/dev/null 2>&1; then
    fail "the uppercase key minted a second row for one ticket"
  fi
  task_present "$parts" || fail "the lowercase row must own the ticket"

  # (b) a bridge event plus an open sos issue whose body carries no marker.
  parts=$(setup_case no-marker)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"### SOS Voice Ticket\ntranscribed report with no SOS marker"}]
EOF
  out=$(run_intake "$parts" reconcile) || fail "marker-less reconcile failed: $out"
  assert_contains "$out" "task_created=1" \
    "an event plus a marker-less issue is one ticket: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the merged ticket must get exactly one dispatched comment"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the merged ticket must spawn exactly once"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-gh-issue-$GH_ISSUE" >/dev/null 2>&1; then
    fail "the fallback key minted a second row for one ticket"
  fi
  pass "one GitHub issue is never split into two candidates"
}

test_stale_pre_rename_watch_is_retired_and_rearmed() {
  local parts home fd out
  parts=$(setup_case stale-watch)
  home=${parts%%|*}
  fd=${parts##*|}

  cat > "$fd/fm-sos-intake.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fd/fm-sos-intake.sh"
  FM_HOME="$home" "$ROOT/bin/fm-procevent-when.sh" arm "sos-$GH_ISSUE" \
    --condition "$fd/fm-sos-intake.sh" watch-condition "$GH_ISSUE" \
    --action "$fd/fm-sos-intake.sh" watch-fire "$GH_ISSUE" "$SOS_UUID" >/dev/null \
    || fail "fixture arm of the pre-rename watch failed"
  # The spec is the watch's persisted, hash-bound state; a pre-rename one
  # names the retired script in its argv.
  assert_grep "fm-sos-intake.sh" "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "fixture must start from a spec bound to the retired script"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_present "$home/state/when/when-sos-$GH_ISSUE.spec" "the watch must stay armed"
  assert_grep "fm-issue-intake.sh" "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "reconcile must re-arm the watch against the renamed script"
  assert_no_grep "fm-sos-intake.sh" "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "the retired script path must be gone from the watch"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the ordinary dispatch path still comments once"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the ordinary dispatch path still spawns once"
  pass "a stale pre-rename watch is retired and re-armed against the renamed script"
}

test_two_pass_marker_less_ticket_stays_one_ticket() {
  local parts home fd out
  parts=$(setup_case two-pass-marker-less)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"### SOS Voice Ticket\ntranscribed report with no SOS marker"}]
EOF

  # Pass 1: the bridge event and the open marker-less issue fold into one
  # candidate keyed on the event's dedupeKey.
  out=$(run_intake "$parts" reconcile) || fail "pass 1 failed: $out"
  assert_contains "$out" "task_created=1" "pass 1 must create one row: $out"
  assert_contains "$out" "dispatched=1" "pass 1 must dispatch: $out"

  # Pass 2: the bridge is drained; only the GH-heal axis offers the same
  # ticket, under the gh-issue fallback key.
  set_bridge_empty "$fd"
  out=$(run_intake "$parts" reconcile) || fail "pass 2 failed: $out"
  assert_contains "$out" "task_created=0" "pass 2 must not mint a second row: $out"
  assert_contains "$out" "dispatched=0" "pass 2 must not re-dispatch: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "one dispatched comment across both passes"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one spawn across both passes"
  assert_equals "1" "$(count_of 'jev verdict' "$fd/jev.log")" \
    "one verdict across both passes: $(cat "$fd/jev.log" 2>/dev/null)"
  task_present "$parts" || fail "the uuid row must own the ticket"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-gh-issue-$GH_ISSUE" >/dev/null 2>&1; then
    fail "the heal pass must not mint a gh-issue row for the same ticket"
  fi
  pass "a marker-less ticket stays one ticket across the event and heal passes"
}

test_failed_spawn_is_retried_and_never_ledgered() {
  local parts home fd out ledger
  parts=$(setup_case spawn-fail)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-issue-intake.log"
  touch "$fd/spawn-fail"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "failed: dispatch" "the spawn failure must be reported: $out"
  assert_contains "$out" "dispatched=0" "a failed spawn must not count as dispatched: $out"
  assert_equals "0" "$(count_of 'dispatch key=' "$ledger")" \
    "a failed spawn must never be ledgered as dispatched"
  assert_absent "$home/state/fm-issue-intake.cursor" \
    "the failed dispatch must block the cursor"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the spawn was attempted once"

  rm -f "$fd/spawn-fail"
  out=$(run_intake "$parts" reconcile 2>&1) || fail "retry failed: $out"
  assert_contains "$out" "dispatched=1" "the ticket must dispatch on retry: $out"
  assert_equals "1" "$(count_of 'dispatch key=' "$ledger")" \
    "exactly one dispatch record after the retry"
  assert_equals "2" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one failed attempt plus one real spawn"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the retry must not re-comment"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the cursor must advance once the dispatch lands"
  pass "a failed spawn is retried and never ledgered as dispatched"
}

test_watch_fire_never_captain_closes_a_declined_issue() {
  local parts home fd out ledger
  parts=$(setup_case decline-watch)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-issue-intake.log"

  # A staging run arms the watch without dispatching; a later gate-on run
  # declines and closes the same ticket.
  out=$(run_intake "$parts" reconcile --no-dispatch --no-verdict) || fail "staging pass failed: $out"
  assert_contains "$out" "dispatched=0" "the staging pass must not dispatch: $out"
  assert_present "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "the staging pass arms the close watch"
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile) || fail "decline pass failed: $out"
  assert_contains "$out" "declined=1" "the decline must land: $out"
  assert_absent "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "the decline must retire the close watch"
  assert_no_grep "CLOSE-WATCH-ARMED" "$fd/gh.log" \
    "the close must never run while the watch is still armed"

  # The tolerated row-close failure leaves no task-closed record behind.
  grep -v '^task-closed key=' "$ledger" > "$ledger.tmp"
  mv "$ledger.tmp" "$ledger"

  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_contains "$out" "declined-recorded" \
    "watch-fire must recognize the decline record itself: $out"
  assert_no_grep "Closed by the captain" "$fd/comments.log" \
    "a declined issue must never get a captain-closed comment"
  assert_equals "1" "$(count_of '' "$fd/comments.log")" \
    "only the declined comment exists: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_no_grep "closed key=" "$ledger" \
    "the decline never authorizes the reporter handoff marker"
  pass "watch-fire never captain-closes an issue intake declined"
}

test_gate_off_run_still_honors_declined_state() {
  local parts home fd out
  parts=$(setup_case gateoff-declined)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "gate-on pass failed: $out"
  assert_contains "$out" "failed: decline" "the gate-on decline must start: $out"

  out=$(run_intake "$parts" reconcile --no-verdict 2>&1) || fail "gate-off pass failed: $out"
  assert_contains "$out" "failed: decline" \
    "a gate-off run must still finish the recorded decline: $out"
  assert_equals "0" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "a gate-off run must not announce a dispatch for a declined ticket"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "the decline comment stays singular"
  assert_equals "0" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "a gate-off run must not spawn a declined ticket"
  [ ! -f "$home/state/when/when-sos-$GH_ISSUE.spec" ] || \
    fail "a declined ticket must not arm a watch, gate off or on"

  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile --no-verdict) || fail "closing pass failed: $out"
  assert_contains "$out" "declined=1" \
    "the recorded decline completes with the gate off: $out"
  assert_equals "0" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "still no dispatch announcement after the decline completes"
  assert_equals "0" "$(count_of 'fm-spawn' "$fd/spawn.log")" "still no spawn"
  assert_equals "done" "$(task_state_of "$parts")" "the declined row closes"
  pass "a gate-off run honors the recorded decline instead of dispatching"
}

test_gate_off_run_keeps_held_tickets_held() {
  local parts home fd out
  parts=$(setup_case gateoff-hold)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'captain_review\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "review=1" "the hold must land: $out"

  out=$(run_intake "$parts" reconcile --no-verdict) || fail "gate-off pass failed: $out"
  assert_contains "$out" "held for the captain" \
    "a recorded hold must survive a gate-off run: $out"
  assert_contains "$out" "review=1" "the held ticket still counts as held: $out"
  [ ! -f "$fd/comments.log" ] || fail "a held ticket must stay uncommented"
  [ ! -f "$fd/spawn.log" ] || fail "a held ticket must never spawn, gate off or on"
  [ ! -f "$home/state/when/when-sos-$GH_ISSUE.spec" ] || \
    fail "a held ticket must not arm a watch"
  assert_equals "queued" "$(task_state_of "$parts")" "the held row stays queued"
  pass "a gate-off run keeps a recorded captain_review hold"
}

test_no_dispatch_posts_no_dispatched_comment() {
  local parts home fd out ledger
  parts=$(setup_case no-dispatch)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-issue-intake.log"

  out=$(run_intake "$parts" reconcile --no-dispatch) || fail "staging pass failed: $out"
  assert_contains "$out" "task_created=1" "staging still ensures the row: $out"
  assert_contains "$out" "dispatched=0" "staging spawns nothing: $out"
  assert_equals "0" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "staging must not announce a dispatch"
  assert_equals "0" "$(count_of 'dispatch key=' "$ledger")" \
    "staging must not ledger a dispatch"
  [ ! -f "$fd/spawn.log" ] || fail "staging must not spawn"

  out=$(run_intake "$parts" reconcile) || fail "full pass failed: $out"
  assert_contains "$out" "dispatched=1" "the full pass dispatches: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the comment lands on the first run that spawns"
  assert_equals "1" "$(count_of 'dispatch key=' "$ledger")" \
    "exactly one dispatch record"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" "exactly one spawn"
  pass "--no-dispatch posts no dispatched comment; the full run does"
}

test_manual_comment_then_the_loop_never_duplicates_it() {
  local parts home fd out second

  # (a) a manual decline comment satisfies the gate-on decline guard. The
  # ops pass stages without dispatching, so the ticket is still declineable.
  parts=$(setup_case manual-decline)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile --no-verdict --no-dispatch) || fail "ops pass failed: $out"
  out=$(run_intake "$parts" comment "$GH_ISSUE" declined) || fail "manual declined failed: $out"
  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "declined=1" "the decline must complete: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "the manual decline comment must satisfy the decline guard: $(cat "$fd/comments.log" 2>/dev/null)"

  # (b) manual dispatched/captain-closed comments satisfy the loop's guards.
  parts=$(setup_case manual-captain)
  home=${parts%%|*}
  fd=${parts##*|}
  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  out=$(run_intake "$parts" comment "$GH_ISSUE" dispatched) || fail "manual dispatched failed: $out"
  second=$(sed -n 2p "$fd/comments.log")
  assert_contains "$second" "$TASK_ID" \
    "a manual dispatched comment must carry the real task id: $second"
  out=$(run_intake "$parts" comment "$GH_ISSUE" captain-closed) || fail "manual captain-closed failed: $out"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the watch must not duplicate a manual captain-closed comment"
  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  assert_equals "2" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "replay adds no dispatched comment of its own"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "replay still adds no captain-closed comment"

  # (c) a manual decline comment written before the ticket is ever reconciled
  parts=$(setup_case manual-decline-fresh)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  out=$(run_intake "$parts" comment "$GH_ISSUE" declined) || fail "fresh manual declined failed: $out"
  out=$(run_intake "$parts" reconcile) || fail "fresh gate-on pass failed: $out"
  assert_contains "$out" "declined=1" "the fresh decline must complete: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "a pre-reconcile manual decline comment must satisfy the guard: $(cat "$fd/comments.log" 2>/dev/null)"
  pass "a manual comment is never duplicated by reconcile or watch-fire"
}

test_legacy_dispatch_records_still_block_a_second_dispatch() {
  local parts home fd out ledger

  # (a) the exact shape every deployed build wrote: the task segment is present.
  parts=$(setup_case legacy-dispatch)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-issue-intake.log"
  {
    printf 'task key=%s issue=%s task=fm-sos-%s at=2026-01-01T00:00:00Z\n' "$SOS_UUID" "$GH_ISSUE" "$SOS_UUID"
    printf 'verdict key=%s issue=%s verdict=supported_bug at=2026-01-01T00:00:01Z\n' "$SOS_UUID" "$GH_ISSUE"
    printf 'dispatch key=%s issue=%s task=fm-sos-%s at=2026-01-01T00:00:02Z\n' "$SOS_UUID" "$GH_ISSUE" "$SOS_UUID"
  } > "$ledger"
  out=$(run_intake "$parts" reconcile) || fail "legacy pass failed: $out"
  assert_contains "$out" "dispatched=0" \
    "a legacy dispatch record must block a second dispatch: $out"
  assert_equals "0" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "a legacy-dispatched ticket must never spawn again"
  assert_equals "0" "$(count_of 'jev verdict' "$fd/jev.log")" \
    "a legacy verdict record must still bind: $(cat "$fd/jev.log" 2>/dev/null)"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "the ticket is still processed, only the dispatch is skipped"

  # (b) legacy records under the gh-issue key namespace.
  parts=$(setup_case legacy-dispatch-ns)
  home=${parts%%|*}
  fd=${parts##*|}
  ledger="$home/state/fm-issue-intake.log"
  {
    printf 'verdict key=gh-issue-%s issue=%s verdict=supported_bug at=2026-01-01T00:00:00Z\n' "$GH_ISSUE" "$GH_ISSUE"
    printf 'dispatch key=gh-issue-%s issue=%s task=fm-iss-gh-issue-%s at=2026-01-01T00:00:01Z\n' "$GH_ISSUE" "$GH_ISSUE" "$GH_ISSUE"
  } > "$ledger"
  out=$(run_intake "$parts" reconcile) || fail "legacy namespace pass failed: $out"
  assert_contains "$out" "dispatched=0" \
    "a gh-issue-keyed dispatch record must block a uuid-keyed dispatch: $out"
  assert_equals "0" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "a gh-issue-dispatched ticket must never spawn again"
  assert_equals "0" "$(count_of 'jev verdict' "$fd/jev.log")" \
    "a gh-issue-keyed verdict record must still bind: $(cat "$fd/jev.log" 2>/dev/null)"
  pass "legacy dispatch and verdict records still bind every guard"
}

test_reopened_declined_ticket_is_reported_not_dropped() {
  local parts home fd out
  parts=$(setup_case reopened-declined)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile) || fail "decline pass failed: $out"
  assert_contains "$out" "declined=1" "the decline must land: $out"
  assert_equals "done" "$(task_state_of "$parts")" "the declined row closes"

  # A human reopens the issue; the next pass must surface it for the captain.
  echo '{"state":"OPEN"}' > "$fd/gh-state-$GH_ISSUE"
  : > "$fd/gh.log"
  out=$(run_intake "$parts" reconcile) || fail "reopen pass failed: $out"
  assert_contains "$out" "held for the captain" \
    "a reopened declined ticket must be reported as held: $out"
  assert_contains "$out" "review=1" "the reopen is reported as review work: $out"
  assert_contains "$out" "declined=0" "the ticket is not silently counted as declined: $out"
  assert_equals "1" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "a reopened declined ticket is never re-declined"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" \
    "the reopen must not trigger a second close"
  [ ! -f "$fd/spawn.log" ] || fail "a reopened declined ticket must never spawn"
  assert_equals "0" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "a reopened declined ticket must not announce a dispatch"
  assert_equals "done" "$(task_state_of "$parts")" \
    "the row stays as the decline left it"
  pass "a reopened declined ticket is reported to the captain, never dropped"
}

test_dispatched_ticket_is_never_declined() {
  local parts home fd out

  # (a) a gate-off dispatch: no verdict is recorded, so the next gate-on pass
  # classifies from scratch - the dispatch record must still bind the decline.
  parts=$(setup_case dispatched-hold)
  home=${parts%%|*}
  fd=${parts##*|}
  out=$(run_intake "$parts" reconcile --no-verdict) || fail "ops pass failed: $out"
  assert_contains "$out" "dispatched=1" "the ops pass dispatches: $out"
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "review=1" "the dispatched ticket must be held: $out"
  assert_contains "$out" "already dispatched" \
    "the hold must state why: $out"
  assert_contains "$out" "declined=0" "a dispatched ticket is never declined: $out"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" \
    "a dispatched ticket must never be closed"
  assert_equals "0" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "a dispatched ticket must get no decline comment"
  assert_equals "0" "$(count_of 'not-supported' "$fd/edit.log")" \
    "a dispatched ticket must get no decline label"
  assert_equals "queued" "$(task_state_of "$parts")" \
    "the dispatched row must stay open for the worker"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "the hold must not spawn a second crewmate"

  # (b) a dispatched comment record (a dispatch whose spawn record is absent)
  # binds the decline path the same way, across key namespaces.
  parts=$(setup_case dispatched-hold-comment)
  home=${parts%%|*}
  fd=${parts##*|}
  out=$(run_intake "$parts" comment "$GH_ISSUE" dispatched) || fail "manual dispatched failed: $out"
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "review=1" \
    "a comment-record dispatch must hold the decline: $out"
  assert_contains "$out" "already dispatched" \
    "the hold must state why: $out"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" \
    "the comment-record dispatch must never be closed"
  assert_equals "0" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "no decline comment on a comment-record dispatch"
  [ ! -f "$fd/spawn.log" ] || fail "a held ticket must never spawn"
  pass "an already-dispatched ticket is held for the captain, never declined"
}

test_large_backlog_payloads_never_wedge_reconcile() {
  local parts home fd out residue
  parts=$(setup_case large-backlog)
  home=${parts%%|*}
  fd=${parts##*|}

  # Both payloads exceed the 128 KiB per-string exec limit on purpose: a lost
  # cursor can return the whole backlog, and a wedged collector would abort
  # every pass at the same point forever.
  python3 - "$fd" "$SOS_UUID" "$GH_ISSUE" <<'PY'
import json, sys
fd, uuid, issue = sys.argv[1], sys.argv[2], int(sys.argv[3])
pad = "x" * 200000
ev = {
    "events": [{
        "id": 1,
        "kind": "sos",
        "dedupeKey": uuid,
        "at": "2026-09-26T12:00:00.000Z",
        "receivedAt": "2026-09-26T12:00:01.000Z",
        "site": "covenant",
        "payload": {
            "ticket": uuid.split("-")[0],
            "gh_issue": issue,
            "gh_issue_url": "https://github.com/ArcsHealth/Portal/issues/%d" % issue,
            "pad": pad,
        },
    }],
    "cursor": 1,
    "backlog": 0,
}
with open(fd + "/bridge.json", "w") as fh:
    json.dump(ev, fh)
gh = [{
    "number": issue,
    "url": "https://github.com/ArcsHealth/Portal/issues/%d" % issue,
    "title": "SOS: reported problem",
    "body": "### SOS Voice Ticket\n- **SOS ID:** `%s`\n%s" % (uuid, pad),
}]
with open(fd + "/gh-list.json", "w") as fh:
    json.dump(gh, fh)
PY

  out=$(run_intake "$parts" reconcile 2>&1) \
    || fail "reconcile must not abort on a large backlog: $out"
  assert_contains "$out" "dispatched=1" \
    "the large-backlog pass must still dispatch: $out"
  assert_contains "$out" "task_created=1" \
    "the large-backlog pass must still create the row: $out"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the cursor must advance past a large payload"
  for residue in "$home/state"/.cand-events.* "$home/state"/.cand-gh.*; do
    [ -e "$residue" ] && fail "candidate payload temp file left behind: $residue"
  done
  pass "backlog payloads beyond the exec string limit never wedge reconcile"
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
  assert_contains "$(cat "$fd/comments.log")" "Issue intake" "the intake's comment must identify itself"
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
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" "cursor must advance to the event id"
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
  rm -f "${parts%%|*}/state/fm-issue-intake.cursor"
  set_bridge_events "${parts##*|}" 1 "$SOS_UUID" "$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "replay reconcile failed: $out"
  assert_contains "$out" "task_created=0" "replay must create no second row: $out"
  assert_contains "$out" "dispatched=0" "replay must not re-dispatch: $out"

  task_present "$parts" || fail "replay lost the task row"
  assert_equals "1" "$(count_of 'Issue intake' "${parts##*|}/comments.log")" \
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
  assert_equals "1" "$(count_of 'Issue intake' "${parts##*|}/comments.log")" \
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

  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
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
  rm -f "$home/state/fm-issue-intake.cursor"
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
  assert_absent "${parts%%|*}/state/fm-issue-intake.cursor" "dry-run must not move the cursor"
  [ ! -f "${parts##*|}/comments.log" ] || fail "dry-run must post no comment"
  [ ! -f "${parts##*|}/spawn.log" ] || fail "dry-run must not dispatch"
  pass "dry-run reports the plan and changes nothing"
}

test_legacy_fm_sos_rows_stay_authoritative() {
  local parts home fd out
  parts=$(setup_case legacy)
  home=${parts%%|*}
  fd=${parts##*|}

  # A row minted before the fm-sos -> fm-iss rename already owns this ticket.
  FM_HOME="$home" "$TASKS_AXI" add "fm-sos-$SOS_UUID" "legacy row for the ticket" \
    --kind ship --repo portal --priority 1 >/dev/null || fail "legacy row setup failed"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=0" "the legacy row must be reused, not duplicated: $out"
  assert_contains "$(cat "$fd/comments.log")" "fm-sos-$SOS_UUID" \
    "the comment must name the pre-rename row"
  task_present "$parts" "fm-sos-$SOS_UUID" || fail "legacy row disappeared"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-$SOS_UUID" >/dev/null 2>&1; then
    fail "the rename minted a second row for one ticket"
  fi
  pass "legacy fm-sos rows stay authoritative across the rename"
}

test_verdict_declines_a_by_design_request() {
  local parts home fd out
  parts=$(setup_case decline)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "declined=1" "the decline must be counted: $out"
  assert_contains "$(cat "$fd/comments.log")" "**Not supported**" "the reporter must get the decline"
  assert_contains "$(cat "$fd/gh.log")" "CLOSE-ATTEMPTED" "the decline closes the issue"
  assert_contains "$(cat "$fd/edit.log" 2>/dev/null)" "not-supported" \
    "the not-supported label must be applied"
  assert_equals "done" "$(task_state_of "$parts")" "the declined row must be closed"
  [ ! -f "$fd/spawn.log" ] || fail "a declined ticket must never spawn"
  [ ! -f "$home/state/when/when-sos-$GH_ISSUE.spec" ] || fail "a declined ticket must not arm a watch"

  # Replay: one decline, one comment, no second close attempt.
  : > "$fd/gh.log"
  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  assert_contains "$out" "declined=1" "the replay still counts it once: $out"
  assert_equals "1" "$(count_of "**Not supported**" "$fd/comments.log")" \
    "replay must not re-decline: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "replay must not close again"
  pass "a by-design request is declined, closed, and never re-declined"
}

test_verdict_holds_uncertain_tickets_for_the_captain() {
  local parts home fd out
  parts=$(setup_case hold)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'captain_review\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "review=1" "the hold must be counted: $out"
  assert_contains "$out" "held for the captain" "the hold must be visible"
  [ ! -f "$fd/comments.log" ] || fail "a held ticket must not comment"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "a held ticket must not close"
  [ ! -f "$fd/spawn.log" ] || fail "a held ticket must never spawn"
  assert_equals "queued" "$(task_state_of "$parts")" "the held row stays queued for the captain"
  pass "an uncertain ticket is held for the captain and never acted on"
}

test_verdict_failure_fails_open_not_closed() {
  local parts fd out
  parts=$(setup_case failopen)
  fd=${parts##*|}
  printf 'fail\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "review=1" "a broken classifier must hold, not decide: $out"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "a broken classifier must never close"
  [ ! -f "$fd/spawn.log" ] || fail "a broken classifier must never spawn"
  pass "verdict failure fails open to captain review"
}

test_verdict_is_decided_once() {
  local parts fd out calls
  parts=$(setup_case once)
  fd=${parts##*|}
  printf 'supported_bug\n' > "$fd/jev-verdict"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "dispatched=1" "supported tickets still dispatch: $out"
  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  calls=$(count_of 'jev verdict' "$fd/jev.log")
  assert_equals "1" "$calls" "the verdict must be decided exactly once: $(cat "$fd/jev.log" 2>/dev/null)"
  pass "the verdict is decided once and ledgered across replays"
}

test_decline_never_touches_a_captain_closed_ticket() {
  local parts home fd out
  parts=$(setup_case decline-captain-closed)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"

  # A staging pass arms the watch without dispatching; the captain then closes
  # the issue directly and watch-fire records the terminal close.
  out=$(run_intake "$parts" reconcile --no-dispatch --no-verdict) || fail "staging pass failed: $out"
  assert_present "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "the staging pass arms the close watch"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_contains "$out" "captain-closed" "watch-fire must record the close: $out"

  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "already-closed" "the decline must report the recorded close: $out"
  assert_contains "$out" "declined=0" "a captain-closed ticket must not be declined: $out"
  assert_equals "0" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "no decline comment on a captain-closed ticket"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" \
    "a captain-closed ticket must never be closed again"
  assert_equals "0" "$(count_of 'not-supported' "$fd/edit.log")" \
    "no decline label on a captain-closed ticket"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the captain-closed comment stays singular"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the already-closed ticket must still advance the cursor"
  assert_equals "done" "$(task_state_of "$parts")" "the row stays as watch-fire left it"
  [ ! -f "$fd/spawn.log" ] || fail "a captain-closed ticket must never spawn"

  # Replaying the same gate-on pass changes nothing.
  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  assert_contains "$out" "declined=0" "the replay must still not decline: $out"
  assert_equals "0" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "the replay still adds no decline comment"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "the replay still never closes"
  pass "a captain-closed ticket is never declined, commented, or closed"
}

test_closed_issue_is_never_dispatched_or_watched() {
  local parts home fd out

  # (a) the issue is already closed when intake first sees it - a replay after
  # a lost cursor, or a ticket closed before intake ever processed it.
  parts=$(setup_case closed-at-intake)
  home=${parts%%|*}
  fd=${parts##*|}
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"

  out=$(run_intake "$parts" reconcile) || fail "closed pass failed: $out"
  assert_contains "$out" "skip:" "a closed ticket must be skipped: $out"
  assert_contains "$out" "spawn skipped" "the skip must state what happened: $out"
  assert_not_contains "$out" "before any dispatch" \
    "the skip must not claim no dispatch exists: $out"
  assert_contains "$out" "task_created=1" "the row is still ensured: $out"
  [ ! -f "$fd/comments.log" ] || fail "a closed issue must get no comment: $(cat "$fd/comments.log")"
  [ ! -f "$fd/spawn.log" ] || fail "a closed issue must never spawn"
  assert_absent "$home/state/when/when-sos-$GH_ISSUE.spec" \
    "a closed issue must never get a close watch"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the skip must still advance the cursor"
  assert_equals "done" "$(task_state_of "$parts")" \
    "the row closes the way watch-fire would leave it"

  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  assert_contains "$out" "skip:" "the replay must skip again: $out"
  assert_contains "$out" "dispatched=0" "the replay must not dispatch: $out"
  [ ! -f "$fd/spawn.log" ] || fail "the replay must still never spawn"
  assert_equals "done" "$(task_state_of "$parts")" "the row stays done"

  # (b) the staging pass arms the watch, the captain closes, watch-fire
  # records it - a later gate-on pass must not announce or spawn a dispatch.
  parts=$(setup_case closed-after-staging)
  home=${parts%%|*}
  fd=${parts##*|}
  out=$(run_intake "$parts" reconcile --no-dispatch --no-verdict) || fail "staging pass failed: $out"
  assert_contains "$out" "dispatched=0" "the staging pass must not dispatch: $out"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_contains "$out" "captain-closed" "watch-fire must record the close: $out"

  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "skip:" "the captain-closed ticket must be skipped: $out"
  assert_contains "$out" "dispatched=0" "the captain-closed ticket must not dispatch: $out"
  assert_equals "0" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "no dispatched comment on a captain-closed ticket"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the captain-closed comment stays singular"
  [ ! -f "$fd/spawn.log" ] || fail "a captain-closed ticket must never spawn"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the run must still advance the cursor"
  assert_equals "done" "$(task_state_of "$parts")" "the row stays closed"
  pass "a closed issue is never commented on, watched, or spawned"
}

test_malformed_event_key_and_missing_id_stay_idempotent() {
  local parts home fd out rows

  # (a) a dedupeKey carrying a space would corrupt every space-delimited
  # ledger matcher; it must fold to the canonical GitHub-issue identity, so
  # the event and its valid marker twin collapse to one row, one comment,
  # one spawn - across replays.
  parts=$(setup_case malformed-key)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/bridge.json" <<EOF
{"events":[{"id":1,"kind":"sos","dedupeKey":"Bad Key $SOS_UUID","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"ticket":"${SOS_UUID%%-*}","gh_issue":$GH_ISSUE,"gh_issue_url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE"}}],"cursor":1,"backlog":0}
EOF

  out=$(run_intake "$parts" reconcile) || fail "first pass failed: $out"
  assert_contains "$out" "task_created=1" "the malformed-key ticket still gets a row: $out"
  assert_contains "$out" "dispatched=1" "and a dispatch: $out"
  task_present "$parts" "fm-iss-gh-issue-$GH_ISSUE" || \
    fail "the canonical GitHub-issue identity must own the ticket"
  if FM_HOME="$home" "$TASKS_AXI" show "fm-iss-$SOS_UUID" >/dev/null 2>&1; then
    fail "the marker twin must not mint a second row for the same ticket"
  fi
  if FM_HOME="$home" "$TASKS_AXI" list 2>/dev/null | grep -qF 'bad key'; then
    fail "a malformed key leaked into the backlog"
  fi

  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  assert_contains "$out" "task_created=0" "the replay must not mint a second row: $out"
  assert_contains "$out" "dispatched=0" "the replay must not dispatch again: $out"
  assert_equals "1" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "one dispatched comment across replays: $(cat "$fd/comments.log" 2>/dev/null)"
  assert_equals "1" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one spawn across replays"
  assert_equals "1" "$(count_of 'jev verdict' "$fd/jev.log")" \
    "the verdict is decided once: $(cat "$fd/jev.log" 2>/dev/null)"
  rows=$(FM_HOME="$home" "$TASKS_AXI" list 2>/dev/null | grep -cE '^  (fm-)?(sos|iss)-')
  assert_equals "1" "${rows:-0}" "one ticket is exactly one row"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the cursor advances past the malformed-key event"

  # (b) an event with no id must never write a non-numeric cursor: a cursor
  # that reads back as garbage resets to 0 and re-feeds the whole backlog.
  parts=$(setup_case missing-event-id)
  home=${parts%%|*}
  fd=${parts##*|}
  cat > "$fd/bridge.json" <<EOF
{"events":[{"kind":"sos","dedupeKey":"$SOS_UUID","at":"2026-09-26T12:00:00.000Z","receivedAt":"2026-09-26T12:00:01.000Z","site":"covenant","payload":{"gh_issue":$GH_ISSUE}}],"cursor":1,"backlog":0}
EOF
  printf '[]\n' > "$fd/gh-list.json"

  out=$(run_intake "$parts" reconcile) || fail "id-less pass failed: $out"
  assert_contains "$out" "dispatched=1" "an id-less event still dispatches: $out"
  assert_absent "$home/state/fm-issue-intake.cursor" \
    "an event without a numeric id must leave the cursor untouched"
  pass "a malformed key and a missing event id degrade to idempotent behavior"
}

test_reopened_close_record_is_held_for_the_captain() {
  local parts home fd out

  # (a) decline side: a staged watch, a captain close recorded by watch-fire,
  # then the issue reopened on GitHub - the stale close record must not
  # silence the not_supported verdict; it goes to the captain instead.
  parts=$(setup_case reopened-close-decline)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  out=$(run_intake "$parts" reconcile --no-dispatch --no-verdict) || fail "staging pass failed: $out"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  assert_contains "$out" "captain-closed" "watch-fire must record the close: $out"
  echo '{"state":"OPEN"}' > "$fd/gh-state-$GH_ISSUE"

  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "review=1" "the reopened ticket must reach the captain: $out"
  assert_contains "$out" "held for the captain" "the review line must be reported: $out"
  assert_contains "$out" "declined=0" "a reopened ticket must not be declined: $out"
  assert_equals "0" "$(count_of '**Not supported**' "$fd/comments.log")" \
    "no decline comment on a reopened ticket"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" \
    "a reopened ticket must never be closed"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the reopened ticket must still advance the cursor"

  # (b) dispatch side: the same closed-then-reopened ticket with a
  # dispatchable verdict - reported for the captain, never skipped silently,
  # never dispatched.
  parts=$(setup_case reopened-close-dispatch)
  home=${parts%%|*}
  fd=${parts##*|}
  out=$(run_intake "$parts" reconcile --no-dispatch --no-verdict) || fail "staging pass failed: $out"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID") || fail "watch-fire failed: $out"
  echo '{"state":"OPEN"}' > "$fd/gh-state-$GH_ISSUE"

  out=$(run_intake "$parts" reconcile) || fail "gate-on pass failed: $out"
  assert_contains "$out" "review=1" "the reopened ticket must reach the captain: $out"
  assert_contains "$out" "open again" "the review line must state why: $out"
  assert_equals "0" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "no dispatch comment on a reopened ticket"
  [ ! -f "$fd/spawn.log" ] || fail "a reopened ticket must never spawn"
  assert_equals "1" "$(cat "$home/state/fm-issue-intake.cursor")" \
    "the reopened ticket must still advance the cursor"
  pass "a stale close record over an open issue is held for the captain"
}

test_duplicate_marker_keeps_both_issues_as_candidates() {
  local parts home fd out rows
  parts=$(setup_case duplicate-marker)
  home=${parts%%|*}
  fd=${parts##*|}
  set_bridge_empty "$fd"
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"SOS: reported problem","body":"### SOS Voice Ticket\n- **SOS ID:** \`$SOS_UUID\`\n"},
 {"number":1922,"url":"https://github.com/ArcsHealth/Portal/issues/1922","title":"SOS: reported problem","body":"### SOS Voice Ticket\n- **SOS ID:** \`$SOS_UUID\`\n"}]
EOF

  out=$(run_intake "$parts" reconcile) || fail "first pass failed: $out"
  assert_contains "$out" "task_created=2" \
    "both issues carrying one marker must get a row: $out"
  assert_contains "$out" "dispatched=2" \
    "both issues carrying one marker must dispatch: $out"
  task_present "$parts" "fm-iss-$SOS_UUID" || fail "the first issue keeps the marker row"
  task_present "$parts" "fm-iss-gh-issue-1922" || \
    fail "the second issue must get its own per-issue row"
  assert_equals "2" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "one dispatched comment per issue"
  assert_equals "2" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "one spawn per issue"
  rows=$(FM_HOME="$home" "$TASKS_AXI" list 2>/dev/null | grep -cE '^  (fm-)?(sos|iss)-')
  assert_equals "2" "${rows:-0}" "two issues are exactly two rows"

  out=$(run_intake "$parts" reconcile) || fail "replay failed: $out"
  assert_contains "$out" "task_created=0" "the replay mints no row: $out"
  assert_contains "$out" "dispatched=0" "the replay dispatches nothing: $out"
  assert_equals "2" "$(count_of 'Issue intake' "$fd/comments.log")" \
    "comments stay one per issue across replays"
  assert_equals "2" "$(count_of 'fm-spawn' "$fd/spawn.log")" \
    "spawns stay one per issue across replays"
  pass "two issues carrying the same marker both produce candidates"
}

test_ensure_survives_a_tasks_axi_without_why() {
  local parts home stub out
  parts=$(setup_case nowhy)
  home=${parts%%|*}
  stub="$home/fake-tasks-axi-no-why"
  cat > "$stub" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --why "*) echo 'error: "Unknown flag: --why"' >&2; exit 2 ;;
esac
exec "$TASKS_AXI" "\$@"
SH
  chmod +x "$stub"

  out=$(TEST_TASKS_OVERRIDE="$stub" run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "task_created=1" \
    "a tasks-axi build without --why must still create the row: $out"
  task_present "$parts" || fail "task row missing after the --why retry"
  pass "a tasks-axi without --why still gets its row"
}

test_unread_report_is_never_judged() {
  local parts home fd out
  parts=$(setup_case unread)
  home=${parts%%|*}
  fd=${parts##*|}
  : > "$fd/gh-view-fail-$GH_ISSUE"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "verdict deferred" "an unreadable report must defer: $out"
  [ ! -f "$fd/jev.log" ] || fail "jev must never judge an unread report"
  [ ! -f "$fd/spawn.log" ] || fail "an unread report must never spawn"
  [ ! -f "$fd/comments.log" ] || fail "an unread report must never comment"
  assert_no_grep "verdict key=" "$home/state/fm-issue-intake.log" "no verdict may be ledgered"
  assert_equals "0" "$(cat "$home/state/fm-issue-intake.cursor" 2>/dev/null || echo 0)" \
    "the cursor must stay on the deferred ticket"

  rm -f "$fd/gh-view-fail-$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "retry failed: $out"
  assert_contains "$out" "dispatched=1" "the readable retry dispatches: $out"
  pass "an unreadable report is deferred, never judged"
}

test_unknown_issue_state_never_dispatches() {
  local parts home fd out
  parts=$(setup_case unknown-state)
  home=${parts%%|*}
  fd=${parts##*|}
  : > "$fd/gh-state-fail-$GH_ISSUE"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "dispatched=0" "an unknown state must not dispatch: $out"
  [ ! -f "$fd/spawn.log" ] || fail "an unknown state must never spawn"
  [ ! -f "$fd/comments.log" ] || fail "an unknown state must never comment"
  [ ! -f "$home/state/when/when-sos-$GH_ISSUE.spec" ] || fail "an unknown state must not arm a watch"

  rm -f "$fd/gh-state-fail-$GH_ISSUE"
  out=$(run_intake "$parts" reconcile) || fail "retry failed: $out"
  assert_contains "$out" "dispatched=1" "the retry dispatches once GitHub answers: $out"
  pass "an unknown GitHub state never permits dispatch"
}

test_decline_completes_despite_a_failed_label() {
  local parts home fd out
  parts=$(setup_case label-fail)
  home=${parts%%|*}
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  : > "$fd/allow-close"
  : > "$fd/edit-fail"

  out=$(run_intake "$parts" reconcile 2>&1) || fail "reconcile failed: $out"
  assert_contains "$out" "declined=1" "a failed label must not block the decline: $out"
  assert_contains "$out" "could not add label not-supported" "the warning must name the label: $out"
  assert_equals "1" "$(count_of "**Not supported**" "$fd/comments.log")" "the decline comment posts once"
  assert_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "the issue must still close"
  assert_grep "declined key=" "$home/state/fm-issue-intake.log" "the decline must be recorded"
  pass "a decline completes with a named warning when its label fails"
}

test_closed_not_supported_ticket_closes_its_row() {
  local parts fd out
  parts=$(setup_case closed-decline)
  fd=${parts##*|}
  printf 'not_supported\n' > "$fd/jev-verdict"
  echo '{"state":"CLOSED"}' > "$fd/gh-state-$GH_ISSUE"

  out=$(run_intake "$parts" reconcile) || fail "reconcile failed: $out"
  assert_contains "$out" "already-closed" "the closed ticket is recognised: $out"
  assert_equals "done" "$(task_state_of "$parts")" "a closed ticket must not leave a queued row"
  assert_no_grep "CLOSE-ATTEMPTED" "$fd/gh.log" "intake must not re-close it"
  pass "a not_supported ticket already closed at intake closes its row"
}

test_watch_fire_reports_a_reopen_after_recording_the_close() {
  local parts home fd out
  parts=$(setup_case fire-reopened)
  home=${parts%%|*}
  fd=${parts##*|}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"

  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID" 2>&1) \
    || fail "watch-fire must not fail after recording the close: $out"
  assert_contains "$out" "reopened-after-close: GH #$GH_ISSUE is open again" "the reopen must be reported: $out"
  assert_grep "closed key=$SOS_UUID issue=$GH_ISSUE" "$home/state/fm-issue-intake.log" \
    "the close records are never lost"

  date +%s > "$home/state/when/when-sos-$GH_ISSUE.fired"
  out=$(run_intake "$parts" reconcile 2>&1) || fail "post-fire reconcile failed: $out"
  assert_contains "$out" "closed earlier and open again - held for the captain" \
    "the open issue must be held for captain_review, not treated as closed: $out"
  assert_contains "$out" "dispatched=0" "the reopened issue must not re-dispatch: $out"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the close is announced exactly once"
  [ ! -f "$home/state/when/when-sos-$GH_ISSUE.spec" ] || fail "the fired watch must not stay armed: $out"
  out=$(run_intake "$parts" reconcile 2>&1) || fail "second reconcile failed: $out"
  assert_contains "$out" "closed earlier and open again - held for the captain" \
    "the reopen is still reported on every later pass: $out"
  pass "watch-fire reports a reopen after recording the close, and reconcile holds it"
}

test_watch_fire_records_the_close_when_github_is_unreadable() {
  local parts home fd out
  parts=$(setup_case fire-unreadable)
  home=${parts%%|*}
  fd=${parts##*|}
  run_intake "$parts" reconcile >/dev/null || fail "setup reconcile failed"

  : > "$fd/gh-state-fail-$GH_ISSUE"
  out=$(run_intake "$parts" watch-fire "$GH_ISSUE" "$SOS_UUID" 2>&1) \
    || fail "an unreadable state must not fail the action or drop the close: $out"
  assert_contains "$out" "captain-closed" "the close must be announced: $out"
  assert_equals "1" "$(count_of 'Closed by the captain' "$fd/comments.log")" \
    "the captain-closed comment must post"
  assert_equals "done" "$(task_state_of "$parts")" "the row must close"
  assert_grep "task-closed key=" "$home/state/fm-issue-intake.log" "the row close must be recorded"
  assert_grep "closed key=$SOS_UUID issue=$GH_ISSUE" "$home/state/fm-issue-intake.log" \
    "the handoff marker must be written"
  pass "watch-fire never loses a close to a transient GitHub failure"
}

test_marker_twin_never_adopts_another_issues_row() {
  local parts home fd stub out
  parts=$(setup_case marker-adopt)
  home=${parts%%|*}
  fd=${parts##*|}
  set_bridge_empty "$fd"
  cat > "$fd/gh-list.json" <<EOF
[{"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"t","body":"- **SOS ID:** \`$SOS_UUID\`\n"},
 {"number":1922,"url":"https://github.com/ArcsHealth/Portal/issues/1922","title":"t","body":"- **SOS ID:** \`$SOS_UUID\`\n"}]
EOF
  stub="$home/fake-tasks-axi-1922-fails"
  cat > "$stub" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"GH #1922"*) exit 1 ;;
esac
exec "$TASKS_AXI" "\$@"
SH
  chmod +x "$stub"
  out=$(TEST_TASKS_OVERRIDE="$stub" run_intake "$parts" reconcile 2>&1) || fail "first pass failed: $out"
  assert_contains "$out" "dispatched=1" "only the first issue dispatches: $out"

  # The candidate order flips: #1922 now sees the marker first.
  cat > "$fd/gh-list.json" <<EOF
[{"number":1922,"url":"https://github.com/ArcsHealth/Portal/issues/1922","title":"t","body":"- **SOS ID:** \`$SOS_UUID\`\n"},
 {"number":$GH_ISSUE,"url":"https://github.com/ArcsHealth/Portal/issues/$GH_ISSUE","title":"t","body":"- **SOS ID:** \`$SOS_UUID\`\n"}]
EOF
  out=$(run_intake "$parts" reconcile 2>&1) || fail "second pass failed: $out"
  task_present "$parts" "fm-iss-gh-issue-1922" || fail "#1922 must get its own row: $out"
  assert_equals "1" "$(count_of "fm-spawn $TASK_ID " "$fd/spawn.log")" \
    "the marker row must be spawned exactly once: $(cat "$fd/spawn.log")"
  assert_equals "1" "$(count_of "fm-spawn fm-iss-gh-issue-1922 " "$fd/spawn.log")" \
    "#1922 must spawn on its own row"
  pass "an unbound marker twin never adopts another issue's row"
}

test_overlapping_reconcile_passes_never_both_dispatch() {
  local parts home fd out holder
  parts=$(setup_case overlap)
  home=${parts%%|*}
  fd=${parts##*|}
  # shellcheck disable=SC2016  # expanded by the child bash, not here.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$FM_STATE_OVERRIDE/.fm-issue-intake.lock" || exit 1
    : > "$2/lock-held"
    exec sleep 30
  ' _ "$ROOT" "$fd" >/dev/null 2>&1 &
  holder=$!
  for _ in $(seq 1 100); do [ -f "$fd/lock-held" ] && break; sleep 0.1; done
  [ -f "$fd/lock-held" ] || fail "could not hold the reconcile lock"

  out=$(run_intake "$parts" reconcile) || fail "overlapping reconcile failed: $out"
  assert_contains "$out" "skipping" "an overlapping pass must stand down: $out"
  [ ! -f "$fd/spawn.log" ] || fail "an overlapping pass must never spawn"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

  out=$(run_intake "$parts" reconcile) || fail "reconcile after release failed: $out"
  assert_contains "$out" "dispatched=1" "the next pass dispatches once: $out"
  pass "overlapping reconcile passes never both dispatch"
}

test_reconcile_creates_one_task_comment_watch_and_dispatch
test_reconcile_is_idempotent_across_replays_and_lost_cursors
test_lost_event_is_healed_from_github
test_watch_condition_never_reads_a_failure_as_closed
test_watch_fire_comments_closes_the_task_and_never_the_issue
test_comment_transitions_are_canonical_and_bounded
test_dry_run_changes_nothing
test_legacy_fm_sos_rows_stay_authoritative
test_verdict_declines_a_by_design_request
test_verdict_holds_uncertain_tickets_for_the_captain
test_verdict_failure_fails_open_not_closed
test_verdict_is_decided_once
test_decline_comments_once_even_when_the_close_fails
test_event_without_a_url_keeps_row_and_cursor_aligned
test_one_github_issue_is_never_two_candidates
test_stale_pre_rename_watch_is_retired_and_rearmed
test_two_pass_marker_less_ticket_stays_one_ticket
test_failed_spawn_is_retried_and_never_ledgered
test_watch_fire_never_captain_closes_a_declined_issue
test_gate_off_run_still_honors_declined_state
test_gate_off_run_keeps_held_tickets_held
test_no_dispatch_posts_no_dispatched_comment
test_manual_comment_then_the_loop_never_duplicates_it
test_legacy_dispatch_records_still_block_a_second_dispatch
test_reopened_declined_ticket_is_reported_not_dropped
test_dispatched_ticket_is_never_declined
test_decline_never_touches_a_captain_closed_ticket
test_closed_issue_is_never_dispatched_or_watched
test_malformed_event_key_and_missing_id_stay_idempotent
test_reopened_close_record_is_held_for_the_captain
test_duplicate_marker_keeps_both_issues_as_candidates
test_large_backlog_payloads_never_wedge_reconcile
test_ensure_survives_a_tasks_axi_without_why
test_unread_report_is_never_judged
test_unknown_issue_state_never_dispatches
test_decline_completes_despite_a_failed_label
test_closed_not_supported_ticket_closes_its_row
test_watch_fire_reports_a_reopen_after_recording_the_close
test_watch_fire_records_the_close_when_github_is_unreadable
test_marker_twin_never_adopts_another_issues_row
test_overlapping_reconcile_passes_never_both_dispatch
