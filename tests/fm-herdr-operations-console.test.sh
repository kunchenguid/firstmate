#!/usr/bin/env bash
# Fixture-first behavior tests for the Herdr Firstmate operations console.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"

CONSOLE="$ROOT/bin/fm-herdr-operations-console.sh"
FIXTURE="$ROOT/tests/fixtures/herdr-operations-console.json"
TMP_ROOT=$(fm_test_tmproot fm-herdr-operations-console)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required for width measurement)"; exit 0; }

run_json() {
  "$CONSOLE" --fixture "$FIXTURE" --format json --now 2026-08-13T12:00:00Z
}

fm_console_overlong_lines() {
  FM_CONSOLE_WIDTH_LIMIT="$1" python3 -c '
import os, sys
limit = int(os.environ["FM_CONSOLE_WIDTH_LIMIT"])
for line in sys.stdin.read().split("\n"):
    if len(line) > limit:
        print("%d chars: %s" % (len(line), line))
'
}

test_shared_snapshot_drives_every_surface() {
  local out
  out=$(run_json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-herdr-operations-console.v1"
      and .mode == "fixture"
      and .theme == "tokyo-night"
      and ((.tasks | map(.id)) == .network.task_ids)
      and (.tasks | length == 8)
      and ((.tasks | map(select(.id == "react-qa"))[0])
        | .task == "Browser QA"
        and .state == "working"
        and .state_label == "Working"
        and .profile_lane == "Personal Codex"
        and .model == "Luna Max"
        and .effort == "QA"
        and .freshness == "fresh")
      and ((.tasks | map(select(.id == "company-blocked"))[0])
        | .state == "blocked" and .needs_review == true and .review == "Captain decision")
      and ((.tasks | map(select(.id == "paused-task"))[0])
        | .state == "paused" and .profile_lane == "Personal Codex")
      and ((.tasks | map(select(.id == "done-task"))[0])
        | .state == "done" and .profile_lane == "Company Claude")
      and ((.tasks | map(select(.id == "stale-task"))[0])
        | .state == "stale" and .reported_state == "done" and .state_label == "Stale")
      and ((.tasks | map(select(.id == "unknown-task"))[0])
        | .state == "unknown" and .state_label == "Unknown")
      and .activity.scrollable == true
      and (.activity.events | length == 4)
      and .activity.deduplicated == 1
      and .activity.malformed == 1
      and .activity.redacted == 1
      and .activity.truncated == true
      and ([.activity.events[].summary] | index("React Library task refreshed") != null)
      and ([.activity.events[].summary] | index("React Library task recorded") == null)
      and .network.malformed == 0
      and (.network.edges | length == 9)
      and .safety.display_only == true
      and .safety.control_actions == false
      and .safety.chat_read == false
      and .safety.private_paths_redacted == true
      and .safety.default_session_untouched == true
  ' >/dev/null || fail "fixture snapshot did not feed the panel, activity, and network contracts"
  assert_not_contains "$out" "/Users/example" "normalized JSON leaked a private path"
  assert_not_contains "$out" "secret-worktree" "normalized JSON leaked private event text"
  pass "one structured fixture snapshot drives honest task, activity, and network surfaces"
}

test_restart_is_deterministic() {
  local first second
  first=$(run_json)
  second=$(run_json)
  [ "$first" = "$second" ] || fail "restarting the fixture adapter changed its deterministic output"
  pass "fixture adapter restart preserves deterministic output"
}

test_ttl_expiry_preserves_honest_state() {
  local fresh expired
  fresh=$(run_json)
  expired=$("$CONSOLE" --fixture "$FIXTURE" --format json --now 2026-08-13T12:10:00Z)
  printf '%s' "$fresh" | jq -e '
    .source.freshness == "fresh"
      and ([.tasks[] | select(.state == "working")] | length) == 1
      and ([.tasks[] | select(.state == "done")] | length) == 1
      and ([.tasks[] | select(.state == "blocked")] | length) == 1
  ' >/dev/null || fail "fresh fixture state was not preserved"
  printf '%s' "$expired" | jq -e '
    .source.freshness == "stale"
      and ([.tasks[] | select(.id == "done-task")][0].state) == "stale"
      and ([.tasks[] | select(.id == "done-task")][0].reported_state) == "done"
      and ([.tasks[] | select(.id == "react-qa")][0].state) == "stale"
  ' >/dev/null || fail "TTL expiry inferred a terminal state instead of showing stale"
  pass "TTL expiry turns old evidence stale while retaining reported state"
}

test_malformed_and_private_identifiers_fail_closed() {
  local malformed private_fixture output rc
  malformed="$TMP_ROOT/malformed.json"
  private_fixture="$TMP_ROOT/private-task-id.json"
  printf '%s\n' '{"schema":"not-the-console-schema"}' > "$malformed"
  rc=0
  output=$("$CONSOLE" --fixture "$malformed" --format json --now 2026-08-13T12:00:00Z 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "malformed fixture unexpectedly rendered successfully"
  assert_contains "$output" "malformed fixture input" "malformed fixture error was not explicit"

  jq '.snapshot.tasks[0].id = "/Users/example/private-task"' "$FIXTURE" > "$private_fixture"
  rc=0
  output=$("$CONSOLE" --fixture "$private_fixture" --format json --now 2026-08-13T12:00:00Z 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "private task identifier unexpectedly rendered successfully"
  assert_not_contains "$output" "/Users/example/private-task" "private task identifier appeared in the error output"

  rc=0
  output=$("$CONSOLE" --fixture "$FIXTURE" --format json --max-events 201 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "activity bound above the hard cap unexpectedly rendered successfully"
  assert_contains "$output" "hard bound" "activity hard-bound refusal was not explicit"
  pass "malformed fixtures and private identifiers fail closed"
}

test_narrow_panel_and_ascii_network() {
  local panel network
  local width over
  for width in 20 40 76; do
    panel=$("$CONSOLE" --fixture "$FIXTURE" --format panel --no-color \
      --now 2026-08-13T12:00:00Z --width "$width")
    over=$(printf '%s\n' "$panel" | fm_console_overlong_lines "$width")
    [ -z "$over" ] || fail "panel exceeded --width $width: $over"
    over=$("$CONSOLE" --fixture "$FIXTURE" --format activity --no-color \
      --now 2026-08-13T12:00:00Z --width "$width" | fm_console_overlong_lines "$width")
    [ -z "$over" ] || fail "activity view exceeded --width $width: $over"
  done
  panel=$("$CONSOLE" --fixture "$FIXTURE" --format panel --no-color --now 2026-08-13T12:00:00Z --width 76)
  assert_contains "$panel" "TOKYO NIGHT" "panel did not identify the Tokyo Night surface"
  assert_contains "$panel" "display-only: yes" "panel did not disclose display-only behavior"
  assert_contains "$panel" "Stale" "panel omitted the explicit stale state"
  assert_contains "$panel" "Unknown" "panel omitted the explicit unknown state"

  network=$("$CONSOLE" --fixture "$FIXTURE" --format network --now 2026-08-13T12:00:00Z --width 76)
  if LC_ALL=C printf '%s\n' "$network" | grep -n '[^ -~]' >/dev/null; then
    fail "ASCII network view contains a non-ASCII character"
  fi
  assert_contains "$network" "Captain -> Firstmate" "network view omitted ownership edge"
  assert_contains "$network" "Task: Browser QA [Working]" "network view was not derived from task state"
  assert_contains "$network" "Task: Historical run [Stale]" "network view omitted stale state"
  pass "narrow panel and separate ASCII dependency view remain bounded"
}

write_fake_lab_helper() {
  local helper=$1 log=$2
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
set -u
log=$FM_FAKE_HERDR_LOG
printf '%s\n' "$*" >> "$log"
for arg in "$@"; do
  case "$arg" in
    --session|--session=*)
      printf 'fake helper saw a caller-supplied session flag\n' >&2
      exit 97
      ;;
  esac
done
[ "$1" = run ] && [ "$2" = fm-lab-console-test ] || exit 98
case "$3:$4" in
  api:snapshot)
    printf '%s\n' '{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","focused":true}],"tabs":[{"tab_id":"t1","workspace_id":"w1","focused":true}],"panes":[{"pane_id":"p1","workspace_id":"w1","tab_id":"t1","focused":true}]}}}'
    ;;
  workspace:report-metadata)
    printf '%s\n' '{"result":{"ok":true}}'
    ;;
  workspace:get)
    printf '%s\n' '{"result":{"workspace":{"tokens":{"surface":"fixture"}}}}'
    ;;
  *)
    printf 'unexpected helper call\n' >&2
    exit 99
    ;;
esac
SH
  chmod +x "$helper"
  : > "$log"
}

test_metadata_publication_uses_named_lab_and_preserves_focus() {
  local helper="$TMP_ROOT/fake-herdr-lab.sh" log="$TMP_ROOT/herdr.log" out rc line
  write_fake_lab_helper "$helper" "$log"
  out=$(HERDR_LAB_HELPER="$helper" HERDR_LAB_SESSION=fm-lab-console-test \
    FM_FAKE_HERDR_LOG="$log" "$CONSOLE" --fixture "$FIXTURE" --format json \
    --now 2026-08-13T12:00:00Z --publish-metadata w1) \
    || fail "named-lab metadata publication failed"
  printf '%s' "$out" | jq -e '
    .herdr.mode == "fixture-lab"
      and .herdr.publish.focus_preserved == true
      and .herdr.publish.control_actions == false
      and .safety.focus_preserved == true
  ' >/dev/null || fail "metadata publication did not report focus-preserving display-only state"
  while IFS= read -r line; do
    case "$line" in
      "run fm-lab-console-test "*) ;;
      *) fail "console bypassed the helper contract: $line" ;;
    esac
  done < "$log"
  assert_grep "run fm-lab-console-test workspace report-metadata w1" "$log" \
    "metadata was not published through the helper"
  assert_no_grep "server stop" "$log" "metadata publication attempted a server-global stop"
  assert_no_grep "session stop" "$log" "metadata publication attempted session stop"
  assert_no_grep "session delete" "$log" "metadata publication attempted session delete"

  : > "$log"
  rc=0
  HERDR_LAB_HELPER="$helper" HERDR_LAB_SESSION=default FM_FAKE_HERDR_LOG="$log" \
    "$CONSOLE" --fixture "$FIXTURE" --format json --publish-metadata w1 >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "default session publication must refuse before helper calls"
  [ ! -s "$log" ] || fail "default session refusal reached the helper"
  pass "metadata publication is named-lab-only, helper-routed, and focus-preserving"
}

test_failed_publication_reports_only_its_own_diagnostic() {
  local helper="$TMP_ROOT/failing-herdr-lab.sh" log="$TMP_ROOT/failing-herdr.log" output rc
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
case "$3:$4" in
  api:snapshot)
    printf '%s\n' '{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","focused":true}],"tabs":[],"panes":[]}}}'
    ;;
  workspace:report-metadata) exit 7 ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$helper"
  : > "$log"
  rc=0
  output=$(HERDR_LAB_HELPER="$helper" HERDR_LAB_SESSION=fm-lab-console-test \
    FM_FAKE_HERDR_LOG="$log" "$CONSOLE" --fixture "$FIXTURE" --format json \
    --now 2026-08-13T12:00:00Z --publish-metadata w1 2>&1) || rc=$?
  expect_code 1 "$rc" "failed metadata publication must exit non-zero"
  assert_contains "$output" "lab metadata publication failed" \
    "failed publication did not report its own diagnostic"
  assert_not_contains "$output" "invalid JSON text" \
    "failed publication leaked an unrelated jq parse error"
  assert_not_contains "$output" "could not attach lab publication result" \
    "failed publication continued past its own refusal"

  : > "$log"
  cat > "$helper" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
case "$3:$4" in
  api:snapshot)
    if [ -f "$FM_FAKE_HERDR_LOG.seen" ]; then
      printf '%s\n' '{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","focused":false}],"tabs":[],"panes":[]}}}'
    else
      : > "$FM_FAKE_HERDR_LOG.seen"
      printf '%s\n' '{"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","focused":true}],"tabs":[],"panes":[]}}}'
    fi
    ;;
  workspace:report-metadata) printf '%s\n' '{"result":{"ok":true}}' ;;
  workspace:get) printf '%s\n' '{"result":{"workspace":{"tokens":{"surface":"fixture"}}}}' ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$helper"
  rm -f "$log.seen"
  rc=0
  output=$(HERDR_LAB_HELPER="$helper" HERDR_LAB_SESSION=fm-lab-console-test \
    FM_FAKE_HERDR_LOG="$log" "$CONSOLE" --fixture "$FIXTURE" --format json \
    --now 2026-08-13T12:00:00Z --publish-metadata w1 2>&1) || rc=$?
  expect_code 1 "$rc" "focus-changing publication must exit non-zero"
  assert_contains "$output" "metadata publication changed Herdr focus" \
    "focus-change refusal did not report its own diagnostic"
  assert_not_contains "$output" "invalid JSON text" \
    "focus-change refusal leaked an unrelated jq parse error"
  pass "publication failures abort with only their own explicit diagnostic"
}

test_truncated_history_is_surfaced() {
  local panel activity json
  json=$(run_json)
  printf '%s' "$json" | jq -e '.activity.truncated == true' >/dev/null \
    || fail "fixture no longer exercises the truncated activity path"
  panel=$("$CONSOLE" --fixture "$FIXTURE" --format panel --no-color --now 2026-08-13T12:00:00Z)
  activity=$("$CONSOLE" --fixture "$FIXTURE" --format activity --now 2026-08-13T12:00:00Z)
  assert_contains "$panel" "truncated: older events dropped" \
    "panel presented a bounded history as complete"
  assert_contains "$activity" "truncated=true" \
    "activity footer presented a bounded history as complete"

  local untruncated
  untruncated=$("$CONSOLE" --fixture "$FIXTURE" --format activity --now 2026-08-13T12:00:00Z --max-events 50)
  assert_contains "$untruncated" "truncated=false" \
    "activity footer did not report an untruncated history honestly"
  pass "dropped activity history is disclosed on every text surface"
}

test_fractional_ttl_is_refused_before_any_helper_call() {
  local helper="$TMP_ROOT/ttl-herdr-lab.sh" log="$TMP_ROOT/ttl-herdr.log" fixture output rc value
  write_fake_lab_helper "$helper" "$log"

  for value in 300.5 1.0005 0.5 86400.9; do
    fixture="$TMP_ROOT/ttl-$value.json"
    jq --argjson t "$value" '.ttl_seconds = $t' "$FIXTURE" > "$fixture"
    : > "$log"
    rc=0
    output=$(HERDR_LAB_HELPER="$helper" HERDR_LAB_SESSION=fm-lab-console-test \
      FM_FAKE_HERDR_LOG="$log" "$CONSOLE" --fixture "$fixture" --format json \
      --now 2026-08-13T12:00:00Z --publish-metadata w1 2>&1) || rc=$?
    expect_code 1 "$rc" "fractional ttl_seconds $value was not refused"
    assert_contains "$output" "malformed fixture input" \
      "fractional ttl_seconds $value did not fail closed at the normalizer"
    assert_not_contains "$output" "integer expression expected" \
      "fractional ttl_seconds $value reached the shell numeric clamp"
    [ ! -s "$log" ] || fail "fractional ttl_seconds $value reached the lab helper"
  done

  for value in 1 300 86400; do
    fixture="$TMP_ROOT/ttl-ok-$value.json"
    jq --argjson t "$value" '.ttl_seconds = $t' "$FIXTURE" > "$fixture"
    "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z >/dev/null \
      || fail "whole ttl_seconds $value was rejected"
  done
  jq 'del(.ttl_seconds)' "$FIXTURE" > "$TMP_ROOT/ttl-absent.json"
  "$CONSOLE" --fixture "$TMP_ROOT/ttl-absent.json" --format json \
    --now 2026-08-13T12:00:00Z >/dev/null || fail "absent ttl_seconds lost its documented default"

  : > "$log"
  output=$(HERDR_LAB_HELPER="$helper" HERDR_LAB_SESSION=fm-lab-console-test \
    FM_FAKE_HERDR_LOG="$log" "$CONSOLE" --fixture "$FIXTURE" --format json \
    --now 2026-08-13T12:00:00Z --publish-metadata w1) \
    || fail "whole-number ttl publication failed"
  assert_grep "--ttl-ms 300000" "$log" "publication did not send a whole-millisecond TTL"
  pass "fractional ttl_seconds fails closed before any Herdr call"
}

test_status_panel_uses_accessible_markers_and_required_fields() {
  local plain colored task_block
  plain=$("$CONSOLE" --fixture "$FIXTURE" --format status --no-color --now 2026-08-13T12:00:00Z)

  assert_contains "$plain" "✓ TESTS" "status panel omitted the readable TESTS label"
  assert_contains "$plain" "◆ COMMIT" "status panel omitted the readable COMMIT label"
  assert_contains "$plain" "↗ REVIEW" "status panel omitted the readable REVIEW label"
  assert_contains "$plain" "⚠ BLOCKER" "status panel omitted the readable BLOCKER label"

  assert_contains "$plain" "128 passed" "status panel omitted recorded test evidence"
  assert_contains "$plain" "a1b2c3d" "status panel omitted recorded commit evidence"
  assert_contains "$plain" "v1.4.0" "status panel omitted a recorded version as commit evidence"
  assert_contains "$plain" "Finish runtime QA sweep" "status panel omitted the recorded next action"
  assert_contains "$plain" "Awaiting Captain diagnosis decision" "status panel omitted a recorded blocker"
  assert_contains "$plain" "Personal Codex" "status panel omitted the profile lane"
  assert_contains "$plain" "Luna Max" "status panel omitted the model"

  if printf '%s' "$plain" | grep -qE '[😀-🿿🚀-🛿✅❌🔴🟢🟡]'; then
    fail "status panel used an emoji status marker"
  fi

  task_block=$(printf '%s\n' "$plain" | grep -A 8 'Old Project / Historical run')
  case "$task_block" in
    *"✓ TESTS   Unknown"*) ;;
    *) fail "status panel inferred test evidence that the snapshot never recorded" ;;
  esac
  case "$task_block" in
    *"⚠ BLOCKER None recorded"*) ;;
    *) fail "status panel did not report an absent blocker honestly" ;;
  esac

  assert_contains "$plain" "[BLOCKED]" "status panel lacked a non-color blocked marker"
  assert_contains "$plain" "[WORKING]" "status panel lacked a non-color working marker"
  assert_contains "$plain" "[STALE]" "status panel lacked a non-color stale marker"
  assert_contains "$plain" "[UNKNOWN]" "status panel lacked a non-color unknown marker"

  colored=$("$CONSOLE" --fixture "$FIXTURE" --format status --color --now 2026-08-13T12:00:00Z)
  printf '%s' "$colored" | grep -q "$(printf '\033')\[38;5;" \
    || fail "status panel emitted no ANSI color when color was requested"
  assert_contains "$colored" "[BLOCKED]" "colored status panel dropped the text marker"
  assert_contains "$colored" "✓ TESTS" "colored status panel dropped the readable TESTS label"
  printf '%s' "$plain" | grep -q "$(printf '\033')" \
    && fail "no-color status panel still emitted ANSI escapes"

  local narrow width over
  for width in 20 30 40 76; do
    narrow=$("$CONSOLE" --fixture "$FIXTURE" --format status --no-color \
      --now 2026-08-13T12:00:00Z --width "$width")
    over=$(printf '%s\n' "$narrow" | fm_console_overlong_lines "$width")
    [ -z "$over" ] || fail "status panel exceeded --width $width: $over"
  done

  local private_fixture private_out
  private_fixture="$TMP_ROOT/status-private.json"
  jq '.tasks["react-qa"] += {
        tests:"/Users/bob/private-results.txt",
        commit:"/Users/bob/repo secret",
        blocker:"/Users/bob/secret-plan.md is missing",
        next_action:"open ~/private/notes.md"
      }' "$FIXTURE" > "$private_fixture"
  private_out=$("$CONSOLE" --fixture "$private_fixture" --format status --no-color \
    --now 2026-08-13T12:00:00Z)
  assert_not_contains "$private_out" "/Users/bob" "status panel leaked a private path"
  assert_not_contains "$private_out" "private-results.txt" "status panel leaked a private filename"
  assert_not_contains "$private_out" "secret-plan" "status panel leaked a private blocker path"
  # shellcheck disable=SC2088 # literal tilde text, not a path to expand
  assert_not_contains "$private_out" "~/private" "status panel leaked a home-relative private path"
  task_block=$(printf '%s\n' "$private_out" | grep -A 8 'React Library / Browser QA')
  case "$task_block" in
    *"✓ TESTS   Unknown"*) ;;
    *) fail "redacted test evidence did not fall back to Unknown" ;;
  esac
  case "$task_block" in
    *"⚠ BLOCKER None recorded"*) ;;
    *) fail "redacted blocker did not fall back to None recorded" ;;
  esac
  case "$task_block" in
    *"NEXT      Unknown"*) ;;
    *) fail "redacted next action did not fall back to Unknown" ;;
  esac
  pass "status panel pairs colored state markers with readable labels and honest fields"
}

test_decision_inbox_is_stable_bounded_and_approval_safe() {
  local out single_fixture single restricted_card
  out=$(run_json)

  printf '%s' "$out" | jq -e '
    .decisions.open == 3
      and .decisions.click_to_approve == false
      and .decisions.selection_required == true
      and .decisions.bare_reply_accepted == false
      and .decisions.focused == null
      and ([.decisions.cards[].alias] | length) == ([.decisions.cards[].alias] | unique | length)
      and ([.decisions.cards[].task_id] | length) == ([.decisions.cards[].task_id] | unique | length)
  ' >/dev/null || fail "decision inbox did not report unique, unselected, click-free cards"

  printf '%s' "$out" | jq -e '
    ([.decisions.cards[] | select(.task_id == "review-merge")][0]
      | (.alias | test("^D-[a-z0-9-]+ · React Library$")) and .restricted == true
        and .shorthand_allowed == false
        and .approval_boundary == "explicit confirmation required")
  ' >/dev/null || fail "merge decision did not carry an Obsidian alias and a hard approval boundary"

  printf '%s' "$out" | jq -e '
    ([.decisions.cards[] | select(.task_id == "multi-option")][0]
      | .binary == false
        and (.options | length) == 3
        and (.options | map(test("^[A-Za-z]") and (length > 1)) | all)
        and (.options | map(test("^[ABC]$")) | any | not)
        and (.keys | map(test("^\\[[A-Z]\\] [A-Za-z]")) | all))
  ' >/dev/null || fail "multi-option decision used bare letter codes instead of option names"

  local resolved_fixture resolved before_map after_map alias task_before task_after
  resolved_fixture="$TMP_ROOT/decision-resolved.json"
  jq 'del(.tasks["company-blocked"])
      | .snapshot.tasks = [.snapshot.tasks[] | select(.id != "company-blocked")]' \
    "$FIXTURE" > "$resolved_fixture"
  resolved=$("$CONSOLE" --fixture "$resolved_fixture" --format json --now 2026-08-13T12:00:00Z)

  before_map=$(printf '%s' "$out" | jq -c '[.decisions.cards[] | {alias, task_id}] | sort_by(.task_id)')
  after_map=$(printf '%s' "$resolved" | jq -c '[.decisions.cards[] | {alias, task_id}] | sort_by(.task_id)')

  printf '%s' "$resolved" | jq -e --argjson before "$before_map" '
    . as $after
    | ([$before[] | select(.task_id != "company-blocked")] | sort_by(.task_id))
      == ([$after.decisions.cards[] | {alias, task_id}] | sort_by(.task_id))
  ' >/dev/null || fail "resolving one decision renumbered the surviving aliases"

  for alias in $(printf '%s' "$before_map" | jq -r '.[].alias | @base64'); do
    task_before=$(printf '%s' "$before_map" | jq -r --arg a "$alias" \
      '[.[] | select((.alias | @base64) == $a)][0].task_id')
    task_after=$(printf '%s' "$after_map" | jq -r --arg a "$alias" \
      '[.[] | select((.alias | @base64) == $a)][0].task_id // empty')
    [ -z "$task_after" ] || [ "$task_before" = "$task_after" ] \
      || fail "alias was reused for a different task: $task_before -> $task_after"
  done

  local new_fixture
  new_fixture="$TMP_ROOT/decision-new.json"
  jq '.snapshot.tasks += [{
        id:"extra-decision", kind:"ship", harness:"codex", project:"extra",
        backlog:{title:"Extra"},
        current_state:{state:"parked", source:"run-step", observed_at:"2026-08-13T11:59:30Z"},
        hints:{pending_decision:true}
      }]
      | .tasks["extra-decision"] = {
          project:"Extra", task:"Unrelated follow-up", phase:"Review",
          profile_lane:"Personal Codex", model:"Luna Max", effort:"low",
          decision:{question:"Continue the follow-up?", recommendation:"Continue",
                    opened_at:"2026-08-13T11:50:00Z"}
        }' "$resolved_fixture" > "$new_fixture"
  "$CONSOLE" --fixture "$new_fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e --argjson before "$before_map" '
      [.decisions.cards[] | {alias, task_id}] as $now
      | ([$now[] | .alias] | length) == ([$now[] | .alias] | unique | length)
        and (all($now[];
              . as $card
              | ([$before[] | select(.alias == $card.alias)] | .[0]) as $prior
              | $prior == null or $prior.task_id == $card.task_id))
    ' >/dev/null || fail "a newly opened decision took over a resolved decision's alias"

  local signature_query baseline_sig changed_sig same_sig
  signature_query='[.decisions.cards[] | select(.task_id == "company-blocked")][0].evidence_signature'
  baseline_sig=$(printf '%s' "$out" | jq -r "$signature_query")

  jq '.tasks["company-blocked"].decision.recommendation = "Defer the sweep"' "$FIXTURE" \
    > "$TMP_ROOT/decision-changed.json"
  changed_sig=$("$CONSOLE" --fixture "$TMP_ROOT/decision-changed.json" --format json \
    --now 2026-08-13T12:00:00Z | jq -r "$signature_query")
  [ "$baseline_sig" != "$changed_sig" ] \
    || fail "changed decision evidence did not change the card signature"

  jq '.tasks["company-blocked"].phase = "Diagnosis sweep"' "$FIXTURE" > "$TMP_ROOT/decision-same.json"
  same_sig=$("$CONSOLE" --fixture "$TMP_ROOT/decision-same.json" --format json \
    --now 2026-08-13T12:00:00Z | jq -r "$signature_query")
  [ "$baseline_sig" = "$same_sig" ] \
    || fail "unchanged decision evidence produced a new card signature"

  single_fixture="$TMP_ROOT/decision-single.json"
  jq 'del(.tasks["review-merge"]) | del(.tasks["multi-option"])
      | .snapshot.tasks = [.snapshot.tasks[] | select(.id != "review-merge" and .id != "multi-option")]' \
    "$FIXTURE" > "$single_fixture"
  single=$("$CONSOLE" --fixture "$single_fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$single" | jq -e '
    .decisions.open == 1
      and .decisions.selection_required == false
      and .decisions.bare_reply_accepted == true
      and (.decisions.cards[0].options == ["Igen", "Nem"])
      and (.decisions.cards[0].keys == ["[I] Igen", "[N] Nem"])
  ' >/dev/null || fail "a single focused binary card did not accept a bare Hungarian reply"

  local single_text
  single_text=$("$CONSOLE" --fixture "$single_fixture" --format decisions --no-color \
    --now 2026-08-13T12:00:00Z)
  assert_contains "$single_text" "bare Igen or Nem accepted" \
    "focused binary card did not offer the bare Hungarian reply"
  assert_contains "$single_text" "click-to-approve is not available" \
    "decision surface did not refuse click-to-approve"

  restricted_card=$("$CONSOLE" --fixture "$FIXTURE" --format decisions --no-color \
    --now 2026-08-13T12:00:00Z)
  assert_contains "$restricted_card" "select one explicitly" \
    "multiple open decisions did not require explicit selection"
  assert_contains "$restricted_card" "shorthand refused" \
    "restricted decision did not refuse alias shorthand"
  assert_not_contains "$restricted_card" "/Users/" "decision surface leaked a private path"

  if printf '%s' "$restricted_card" | grep -qE '[😀-🿿🚀-🛿✅❌🔴🟢🟡]'; then
    fail "decision surface used an emoji marker"
  fi
  printf '%s' "$restricted_card" | grep -q "$(printf '\033')" \
    && fail "no-color decision surface emitted ANSI escapes"
  "$CONSOLE" --fixture "$FIXTURE" --format decisions --color --now 2026-08-13T12:00:00Z \
    | grep -q "$(printf '\033')\[" \
    || fail "decision surface emitted no ANSI color when color was requested"

  local width over
  for width in 20 40 76; do
    over=$("$CONSOLE" --fixture "$FIXTURE" --format decisions --no-color \
      --now 2026-08-13T12:00:00Z --width "$width" | fm_console_overlong_lines "$width")
    [ -z "$over" ] || fail "decision surface exceeded --width $width: $over"
  done
  pass "decision inbox keeps stable aliases, explicit selection, and approval boundaries"
}

write_collision_fixture() {
  local target=$1 drop=$2
  jq --arg drop "$drop" '
      .snapshot.tasks = [.snapshot.tasks[] | select(.id | startswith("task-") | not)]
      | .tasks = (.tasks | with_entries(select(.key | startswith("task-") | not)))
      | .snapshot.tasks += [
          {id:"task-230", kind:"ship", harness:"codex", project:"p", backlog:{title:"P"},
           current_state:{state:"parked", source:"run-step", observed_at:"2026-08-13T11:59:30Z"},
           hints:{pending_decision:true}},
          {id:"task-311", kind:"ship", harness:"codex", project:"q", backlog:{title:"Q"},
           current_state:{state:"parked", source:"run-step", observed_at:"2026-08-13T11:59:30Z"},
           hints:{pending_decision:true}}]
      | .tasks["task-230"] = {project:"P", task:"Safe cleanup", phase:"Review",
          profile_lane:"Personal Codex",
          decision:{question:"Archive the old notes?", recommendation:"Archive",
                    opened_at:"2026-08-13T11:50:00Z"}}
      | .tasks["task-311"] = {project:"Q", task:"Release", phase:"Review",
          profile_lane:"Personal Codex",
          decision:{question:"Merge the release branch into main?", recommendation:"Hold",
                    opened_at:"2026-08-13T11:50:00Z"}}
      | if $drop == "" then .
        else (del(.tasks[$drop])
              | .snapshot.tasks = [.snapshot.tasks[] | select(.id != $drop)])
        end' "$FIXTURE" > "$target"
}

test_alias_is_pure_identity_under_collision() {
  local both only_311 only_230 alias_230_both alias_311_both alias_311_alone alias_230_alone

  write_collision_fixture "$TMP_ROOT/collide-both.json" ""
  write_collision_fixture "$TMP_ROOT/collide-311.json" "task-230"
  write_collision_fixture "$TMP_ROOT/collide-230.json" "task-311"

  both=$("$CONSOLE" --fixture "$TMP_ROOT/collide-both.json" --format json --now 2026-08-13T12:00:00Z)
  only_311=$("$CONSOLE" --fixture "$TMP_ROOT/collide-311.json" --format json --now 2026-08-13T12:00:00Z)
  only_230=$("$CONSOLE" --fixture "$TMP_ROOT/collide-230.json" --format json --now 2026-08-13T12:00:00Z)

  alias_230_both=$(printf '%s' "$both" | jq -r '[.decisions.cards[] | select(.task_id == "task-230")][0].alias')
  alias_311_both=$(printf '%s' "$both" | jq -r '[.decisions.cards[] | select(.task_id == "task-311")][0].alias')
  alias_311_alone=$(printf '%s' "$only_311" | jq -r '[.decisions.cards[] | select(.task_id == "task-311")][0].alias')
  alias_230_alone=$(printf '%s' "$only_230" | jq -r '[.decisions.cards[] | select(.task_id == "task-230")][0].alias')

  [ "$alias_230_both" != "$alias_311_both" ] \
    || fail "two open decisions shared the alias $alias_230_both"
  [ "$alias_311_both" = "$alias_311_alone" ] \
    || fail "resolving the other card changed task-311's alias: $alias_311_both -> $alias_311_alone"
  [ "$alias_230_both" = "$alias_230_alone" ] \
    || fail "resolving the other card changed task-230's alias: $alias_230_both -> $alias_230_alone"
  [ "$alias_230_both" != "$alias_311_alone" ] \
    || fail "the restricted card inherited the unrestricted card's alias $alias_230_both"

  printf '%s' "$both" | jq -e '
    ([.decisions.cards[] | select(.task_id == "task-230")][0].restricted == false)
      and ([.decisions.cards[] | select(.task_id == "task-311")][0].restricted == true)
  ' >/dev/null || fail "collision fixture lost its restricted/unrestricted split"
  printf '%s' "$only_311" | jq -e '
    [.decisions.cards[] | select(.task_id == "task-311")][0]
      | .restricted == true and .shorthand_allowed == false
  ' >/dev/null || fail "surviving merge card lost its approval boundary"

  local hash_fixture pair pair_a pair_b alias_a alias_b
  for pair in "aaaaAAA:AaAAaaa" "task.A_b:task+a:B"; do
    pair_a=${pair%%:*}
    pair_b=${pair#*:}
    hash_fixture="$TMP_ROOT/alias-hash-$pair_a.json"
    jq --arg a "$pair_a" --arg b "$pair_b" '
        .snapshot.tasks += [
          {id:$a, kind:"ship", harness:"codex", project:"h", backlog:{title:"H"},
           current_state:{state:"parked", source:"run-step", observed_at:"2026-08-13T11:59:30Z"},
           hints:{pending_decision:true}},
          {id:$b, kind:"ship", harness:"codex", project:"h", backlog:{title:"H"},
           current_state:{state:"parked", source:"run-step", observed_at:"2026-08-13T11:59:30Z"},
           hints:{pending_decision:true}}]
        | .tasks[$a] = {project:"H", task:"Safe cleanup", phase:"Review",
            profile_lane:"Personal Codex",
            decision:{question:"Archive the old notes?", recommendation:"Archive",
                      opened_at:"2026-08-13T11:50:00Z"}}
        | .tasks[$b] = {project:"H", task:"Release", phase:"Review",
            profile_lane:"Personal Codex",
            decision:{question:"Merge the release branch into main?", recommendation:"Hold",
                      opened_at:"2026-08-13T11:50:00Z"}}' "$FIXTURE" > "$hash_fixture"
    alias_a=$("$CONSOLE" --fixture "$hash_fixture" --format json --now 2026-08-13T12:00:00Z \
      | jq -r --arg a "$pair_a" '[.decisions.cards[] | select(.task_id == $a)][0].alias')
    alias_b=$("$CONSOLE" --fixture "$hash_fixture" --format json --now 2026-08-13T12:00:00Z \
      | jq -r --arg b "$pair_b" '[.decisions.cards[] | select(.task_id == $b)][0].alias')
    [ "$alias_a" != "$alias_b" ] \
      || fail "ids $pair_a and $pair_b shared alias $alias_a (restricted card reachable by the safe alias)"
    "$CONSOLE" --fixture "$hash_fixture" --format json --now 2026-08-13T12:00:00Z \
      | jq -e --arg b "$pair_b" '
        .decisions.aliases_unique == true
          and (.decisions.ambiguous_aliases | length) == 0
          and ([.decisions.cards[] | select(.task_id == $b)][0].restricted) == true
      ' >/dev/null || fail "alias uniqueness was not reported for the $pair_a pair"
  done

  local variant_fixture
  variant_fixture="$TMP_ROOT/alias-variants.json"
  jq '.snapshot.tasks = [.snapshot.tasks[] | select(.id | startswith("variant") | not)]
      | .tasks = (.tasks | with_entries(select(.key | startswith("variant") | not)))
      | reduce ["variant-a1", "variant_a1", "varianta1", "VARIANT-A1"][] as $id (.;
          .snapshot.tasks += [{id:$id, kind:"ship", harness:"codex", project:"v",
            backlog:{title:"V"},
            current_state:{state:"parked", source:"run-step", observed_at:"2026-08-13T11:59:30Z"},
            hints:{pending_decision:true}}]
          | .tasks[$id] = {project:"V", task:"Variant", phase:"Review",
              profile_lane:"Personal Codex",
              decision:{question:"Continue?", recommendation:"Continue",
                        opened_at:"2026-08-13T11:50:00Z"}})' "$FIXTURE" > "$variant_fixture"
  "$CONSOLE" --fixture "$variant_fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e '
      [.decisions.cards[] | select(.task_id | startswith("variant") or startswith("VARIANT"))] as $v
      | ($v | length) == 4
        and (($v | map(.alias) | length) == ($v | map(.alias) | unique | length))
    ' >/dev/null || fail "task ids differing only in punctuation or case shared an alias"
  pass "decision aliases stay identity-pure when short forms collide"
}

test_restriction_survives_truncation_redaction_and_options() {
  local fixture long_question restricted_query
  restricted_query='[.decisions.cards[] | select(.task_id == "multi-option")][0]'

  long_question="Please confirm whether we should proceed with the following operational step which the team has already reviewed thank you kindly: deploy to production"
  fixture="$TMP_ROOT/restrict-truncated.json"
  jq --arg q "$long_question" '.tasks["multi-option"].task = "Routine step"
      | .tasks["multi-option"].decision = {question:$q, recommendation:"Proceed",
          opened_at:"2026-08-13T11:55:00Z"}' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e "$restricted_query | .restricted == true and .shorthand_allowed == false" >/dev/null \
    || fail "a truncated deploy question was downgraded to shorthand-approvable"

  fixture="$TMP_ROOT/restrict-redacted.json"
  jq '.tasks["multi-option"].task = "Routine step"
      | .tasks["multi-option"].decision = {question:"Merge /Users/bob/release into main?",
          recommendation:"Proceed", opened_at:"2026-08-13T11:55:00Z"}' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e "$restricted_query
        | .restricted == true and .shorthand_allowed == false
          and (.question | test(\"/Users/bob\") | not)" >/dev/null \
    || fail "a redacted merge question was downgraded to shorthand-approvable"

  fixture="$TMP_ROOT/restrict-options.json"
  jq '.tasks["multi-option"].task = "Routine step"
      | .tasks["multi-option"].decision = {question:"Which follow-up should run?",
          recommendation:"Pick the safe one", opened_at:"2026-08-13T11:55:00Z",
          options:["archive","deploy to prod","rerun"]}' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e "$restricted_query | .restricted == true and .shorthand_allowed == false" >/dev/null \
    || fail "a restricted option name was shorthand-approvable"

  fixture="$TMP_ROOT/restrict-blocker.json"
  jq '.tasks["multi-option"].task = "Routine step"
      | .tasks["multi-option"].blocker = "waiting to force-push the release"
      | .tasks["multi-option"].decision = {question:"Continue?", recommendation:"Continue",
          opened_at:"2026-08-13T11:55:00Z"}' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e "$restricted_query | .restricted == true" >/dev/null \
    || fail "a restricted blocker was not classified from raw evidence"

  local field
  for field in next_action review; do
    fixture="$TMP_ROOT/restrict-$field.json"
    jq --arg f "$field" '.tasks["multi-option"].task = "Routine step"
        | .tasks["multi-option"][$f] = "deploy to production and merge the branch"
        | .tasks["multi-option"].decision = {question:"Continue?", recommendation:"Continue",
            opened_at:"2026-08-13T11:55:00Z"}' "$FIXTURE" > "$fixture"
    "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
      | jq -e "$restricted_query | .restricted == true and .shorthand_allowed == false" >/dev/null \
      || fail "a restricted $field was shorthand-approvable"
  done

  for field in next_action review; do
    fixture="$TMP_ROOT/restrict-$field-redacted.json"
    jq --arg f "$field" '.tasks["multi-option"].task = "Routine step"
        | .tasks["multi-option"][$f] = "/Users/bob/deploy-to-production.sh"
        | .tasks["multi-option"].decision = {question:"Continue?", recommendation:"Continue",
            opened_at:"2026-08-13T11:55:00Z"}' "$FIXTURE" > "$fixture"
    "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
      | jq -e "$restricted_query | .restricted == true" >/dev/null \
      || fail "a redacted $field lost its restriction before classification"
  done
  pass "restriction classification reads raw evidence before truncation and redaction"
}

test_option_key_tokens_are_unique_and_readable() {
  local fixture keys
  fixture="$TMP_ROOT/option-keys.json"
  jq '.tasks["multi-option"].decision.options = ["zip","zstd","tarball"]' "$FIXTURE" > "$fixture"
  keys=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -c '[.decisions.cards[] | select(.task_id == "multi-option")][0].keys')
  printf '%s' "$keys" | jq -e '
    length == 3
      and ((map(capture("^\\[(?<k>[^]]+)\\]").k) | length)
           == (map(capture("^\\[(?<k>[^]]+)\\]").k) | unique | length))
      and (map(test("^\\[[A-Z0-9]\\] [A-Za-z]")) | all)
  ' >/dev/null || fail "colliding option initials produced duplicate key tokens: $keys"

  local set
  for set in '["a","aa","aaa"]' '["ab","ba","ab ba"]' '["zip","zip x","zap"]' '["x","x","xx","xxx","xxxx"]'; do
    fixture="$TMP_ROOT/option-keys-exhaust.json"
    jq --argjson opts "$set" '.tasks["multi-option"].decision.options = $opts' "$FIXTURE" > "$fixture"
    keys=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
      | jq -c '[.decisions.cards[] | select(.task_id == "multi-option")][0].keys')
    printf '%s' "$keys" | jq -e '
      (map(capture("^\\[(?<k>[^]]+)\\] (?<label>.+)$"))) as $parsed
      | ($parsed | length) > 0
        and (($parsed | map(.k) | length) == ($parsed | map(.k) | unique | length))
        and ($parsed | map(.label | length > 0) | all)
    ' >/dev/null || fail "option set $set produced duplicate or unlabeled key tokens: $keys"
  done

  "$CONSOLE" --fixture "$FIXTURE" --format json --now 2026-08-13T12:00:00Z \
    | jq -e '
      all(.decisions.cards[];
        (.keys | map(capture("^\\[(?<k>[^]]+)\\]").k) | length)
        == (.keys | map(capture("^\\[(?<k>[^]]+)\\]").k) | unique | length))
    ' >/dev/null || fail "shipped fixture produced duplicate key tokens"
  pass "option key tokens stay unique and readable under colliding initials"
}

test_decision_options_are_never_silently_dropped() {
  local fixture out text card_query
  card_query='[.decisions.cards[] | select(.task_id == "multi-option")][0]'

  fixture="$TMP_ROOT/options-punctuation.json"
  jq '.tasks["multi-option"].decision.options = ["zip","native bundle (fast)","tarball"]' \
    "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .options_retained == 3 and .options_complete == true
        and .binary == false
        and (.options | index(\"native bundle (fast)\")) != null" >/dev/null \
    || fail "an ordinary parenthesised option was dropped from the card"

  fixture="$TMP_ROOT/options-numeric.json"
  jq '.tasks["multi-option"].decision.options = ["deploy to prod","2fa"]' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .binary == false
        and .option_count == 2 and .options_retained == 2
        and (.options | index(\"Igen\")) == null
        and (.options | index(\"2fa\")) != null
        and .restricted == true and .shorthand_allowed == false" >/dev/null \
    || fail "a numeric-leading option collapsed the card to a binary Igen/Nem decision"

  fixture="$TMP_ROOT/options-unsupported.json"
  jq '.tasks["multi-option"].decision.options = ["zip","/Users/bob/secret-plan.md","tarball"]' \
    "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .unsupported_options == 1 and .options_complete == true
        and .binary == false
        and (.options | map(test(\"/Users/bob\")) | any | not)
        and (.options | map(test(\"^<unsupported #[0-9]+>\")) | any)" >/dev/null \
    || fail "a private-path option was silently discarded instead of explicitly marked"
  assert_not_contains "$out" "/Users/bob" "decision option leaked a private path"

  text=$("$CONSOLE" --fixture "$fixture" --format decisions --no-color --now 2026-08-13T12:00:00Z)
  assert_contains "$text" "unsupported - select explicitly" \
    "decision surface did not disclose an unsupported option"

  fixture="$TMP_ROOT/options-two-unsupported.json"
  jq '.tasks["multi-option"].decision.options =
        ["/Users/a/plan-alpha.md","/Users/b/plan-beta.md","zip"]' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .distinct_options == 3
        and .options_retained == 3 and .unsupported_options == 2
        and .options_complete == true
        and ((.options | map(select(test(\"^<unsupported #[0-9]+>\"))) | unique | length) == 2)" \
    >/dev/null || fail "two distinct unsupported options collapsed into one card row"
  assert_not_contains "$out" "/Users/a" "decision option leaked a private path"
  assert_not_contains "$out" "/Users/b" "decision option leaked a private path"

  fixture="$TMP_ROOT/options-all-unsupported.json"
  jq '.tasks["multi-option"].decision.options = ["/Users/a/x.md","/Users/b/y.md"]' \
    "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e "$card_query
      | .option_count == 2 and .options_retained == 2 and .unsupported_options == 2
        and .binary == false" >/dev/null \
    || fail "a fully unsupported option set collapsed to a single row"

  fixture="$TMP_ROOT/options-duplicate.json"
  jq '.tasks["multi-option"].decision.options = ["zip","zip","tarball"]' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .distinct_options == 2 and .duplicate_options == 1
        and .options_retained == 2 and .unsupported_options == 0
        and .options_complete == true
        and (.options == [\"zip\",\"tarball\"])" >/dev/null \
    || fail "an exact duplicate option was reported as a lost choice"
  text=$("$CONSOLE" --fixture "$fixture" --format decisions --no-color --now 2026-08-13T12:00:00Z)
  assert_not_contains "$text" "unsupported - select explicitly" \
    "duplicate options produced a false unsupported-option notice"
  assert_contains "$text" "1 duplicate" "duplicate options were not disclosed"

  fixture="$TMP_ROOT/options-trailing-space.json"
  jq '.tasks["multi-option"].decision.options = ["zip ","zip","tarball"]' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .distinct_options == 2 and .duplicate_options == 1
        and .options_retained == 2 and .unsupported_options == 0
        and .options_complete == true
        and (.options == [\"zip\",\"tarball\"])" >/dev/null \
    || fail "options differing only in trailing whitespace were not collapsed as duplicates"
  text=$("$CONSOLE" --fixture "$fixture" --format decisions --no-color --now 2026-08-13T12:00:00Z)
  assert_contains "$text" "1 duplicate" "whitespace-variant duplicate was not disclosed"
  assert_not_contains "$text" "zip #" "whitespace-variant options were suffixed instead of merged"

  fixture="$TMP_ROOT/options-leading-space.json"
  jq '.tasks["multi-option"].decision.options = ["  tarball","tarball ","zip"]' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e "$card_query
      | .option_count == 3 and .distinct_options == 2 and .duplicate_options == 1
        and (.options == [\"tarball\",\"zip\"])" >/dev/null \
    || fail "leading-whitespace variants were not normalized before comparison"

  fixture="$TMP_ROOT/options-internal-space.json"
  jq '.tasks["multi-option"].decision.options = ["zip x","zip  x","tarball"]' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .distinct_options == 2 and .duplicate_options == 1
        and .options_retained == 2 and .unsupported_options == 0
        and .options_complete == true
        and (.options == [\"zip x\",\"tarball\"])" >/dev/null \
    || fail "options differing only in internal whitespace were not collapsed as duplicates"

  local run_case
  for run_case in '["zip  x","zip   x","tarball"]' '["zip  x","zip\t\tx","tarball"]' '["zip\tx","zip x","tarball"]'; do
    fixture="$TMP_ROOT/options-space-runs.json"
    jq --argjson opts "$(printf '%s' "$run_case" | jq -c '.')" \
      '.tasks["multi-option"].decision.options = $opts' "$FIXTURE" > "$fixture"
    out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
    printf '%s' "$out" | jq -e "$card_query
        | .option_count == 3 and .distinct_options == 2 and .duplicate_options == 1
          and .options_retained == 2
          and ((.options | length) == (.options | unique | length))
          and ((.options | map(select(test(\" #[0-9]+\$\"))) | length) == 0)" >/dev/null \
      || fail "whitespace-run variants $run_case were not normalized into one option"
  done
  text=$("$CONSOLE" --fixture "$fixture" --format decisions --no-color --now 2026-08-13T12:00:00Z)
  assert_not_contains "$text" " _ " "collapsed whitespace produced a display marker instead of merging"

  local long_a long_b
  long_a=$(printf 'a%.0s' $(seq 1 40))XX
  long_b=$(printf 'a%.0s' $(seq 1 40))YY
  fixture="$TMP_ROOT/options-truncation-collision.json"
  jq --arg a "$long_a" --arg b "$long_b" \
    '.tasks["multi-option"].decision.options = [$a,$b,"zip"]' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .distinct_options == 3 and .options_retained == 3
        and .options_complete == true
        and ((.options | length) == (.options | unique | length))" >/dev/null \
    || fail "two options colliding after truncation rendered identical card rows"
  printf '%s' "$out" | jq -e "$card_query
      | (.keys | map(capture(\"^\\\\[(?<k>[^]]+)\\\\] (?<label>.+)\$\").label))
        as \$labels
      | (\$labels | length) == (\$labels | unique | length)" >/dev/null \
    || fail "truncated option collision produced duplicate key labels"

  fixture="$TMP_ROOT/options-placeholder-collision.json"
  jq '.tasks["multi-option"].decision.options =
        ["/Users/a/x.md","Unsupported option 1 (select explicitly)","<unsupported #1>"]' \
    "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e "$card_query
      | .option_count == 3 and .distinct_options == 3 and .options_retained == 3
        and ((.options | length) == (.options | unique | length))
        and .unsupported_options >= 1" >/dev/null \
    || fail "a literal option matching the unsupported placeholder collided with a redacted row"
  assert_not_contains "$out" "/Users/a" "decision option leaked a private path"

  text=$("$CONSOLE" --fixture "$FIXTURE" --format decisions --no-color --now 2026-08-13T12:00:00Z)
  assert_contains "$text" "all shown" \
    "decision surface did not confirm a complete option set"
  pass "decision options are retained, marked, and never collapsed to a false binary"
}

test_obsidian_decision_id_alias_and_ambiguity() {
  local fixture out text value

  fixture="$TMP_ROOT/obsidian-alias.json"
  jq '.tasks["review-merge"].decision.obsidian_id = "D36"' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e '
    [.decisions.cards[] | select(.task_id == "review-merge")][0]
      | .alias == "D36 · React Library" and .alias_key == "D36"
        and .alias_source == "obsidian" and .restricted == true
  ' >/dev/null || fail "an authoritative obsidian_id did not produce the D36 · Domain header"
  printf '%s' "$out" | jq -e '.decisions.aliases_unique == true' >/dev/null \
    || fail "a unique obsidian_id was reported as ambiguous"

  for value in '"d36"' '"D36x"' '"36"' '123' 'null' '{"id":"D36"}'; do
    fixture="$TMP_ROOT/obsidian-malformed.json"
    jq --argjson v "$value" '.tasks["review-merge"].decision.obsidian_id = $v' "$FIXTURE" > "$fixture"
    "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
      | jq -e '[.decisions.cards[] | select(.task_id == "review-merge")][0]
          | .alias_source == "task-identity" and (.alias_key | startswith("D-"))' >/dev/null \
      || fail "malformed obsidian_id $value did not fall back to the task identity alias"
  done

  fixture="$TMP_ROOT/obsidian-ambiguous.json"
  jq '.tasks["review-merge"].decision.obsidian_id = "D36"
      | .tasks["multi-option"].decision.obsidian_id = "D36"' "$FIXTURE" > "$fixture"
  out=$("$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z)
  printf '%s' "$out" | jq -e '
    .decisions.aliases_unique == false
      and (.decisions.ambiguous_aliases == ["D36"])
      and .decisions.focused == null
      and .decisions.bare_reply_accepted == false
      and .decisions.selection_required == true
      and ([.decisions.cards[] | select(.task_id == "review-merge")][0].restricted) == true
      and ([.decisions.cards[] | select(.task_id == "multi-option")][0].restricted) == false
  ' >/dev/null || fail "a duplicated obsidian_id did not force explicit selection"
  text=$("$CONSOLE" --fixture "$fixture" --format decisions --no-color --now 2026-08-13T12:00:00Z)
  assert_contains "$text" "Alias is ambiguous" \
    "ambiguous alias was not disclosed on the decision surface"
  assert_contains "$text" "no reply is routed" \
    "ambiguous alias did not refuse to route a reply"

  fixture="$TMP_ROOT/obsidian-ambiguous-single.json"
  jq 'del(.tasks["company-blocked"]) | del(.tasks["multi-option"])
      | .snapshot.tasks = [.snapshot.tasks[]
          | select(.id != "company-blocked" and .id != "multi-option")]
      | .tasks["review-merge"].decision.obsidian_id = "D36"' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e '.decisions.open == 1 and .decisions.aliases_unique == true
             and .decisions.focused == "D36 · React Library"' >/dev/null \
    || fail "a single unambiguous obsidian card was not focusable"
  pass "authoritative obsidian ids alias cleanly and refuse routing when ambiguous"
}

test_chat_visibility_is_reported_honestly() {
  run_json | jq -e '
    .decisions.chat_visibility == "unsupported"
      and .decisions.chat_ask_state == "unknown"
      and (.decisions | has("asked_in_chat_once") | not)
      and .safety.chat_read == false
  ' >/dev/null || fail "console claimed chat knowledge it cannot observe"
  pass "chat visibility is reported as unsupported rather than assumed"
}

test_profile_selector_is_display_only_and_verified() {
  local out text fixture
  out=$(run_json)

  printf '%s' "$out" | jq -e '
    .selector.mode == "fixture-mock"
      and .selector.keyboard_only == true
      and .selector.launches == false
      and .selector.switches_account == false
      and .selector.copies_credentials == false
      and .selector.copies_session_state == false
      and .selector.step_order == ["Profile", "Model", "Effort"]
      and ([.selector.profiles[].profile]
           == ["Company Codex", "Personal Codex", "Company Claude", "Personal Claude"])
  ' >/dev/null || fail "selector did not expose a display-only three-step keyboard flow"

  printf '%s' "$out" | jq -e '
    .selector.preview.state == "ready"
      and .selector.preview.tuple == "Company Codex · openai-codex/gpt-5.6-sol · high thinking"
  ' >/dev/null || fail "selector did not preview the guarded target tuple"

  printf '%s' "$out" | jq -e '
    ([.selector.profiles[] | select(.profile == "Personal Codex")][0]
      | (.models | index("openai-codex/gpt-5.6-sol")) == null
        and (.efforts | index("high thinking")) == null
        and .last_selection.model == "openai-codex/gpt-5.3-codex")
      and ([.selector.profiles[] | select(.profile == "Company Claude")][0].last_selection == null)
  ' >/dev/null || fail "selector leaked models or efforts across profile lanes"

  fixture="$TMP_ROOT/selector-unverified.json"
  jq '.selector.preview = {profile:"Personal Codex", model:"openai-codex/gpt-5.6-sol",
        effort:"high thinking"}' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e '.selector.preview.state == "unverified" and .selector.preview.tuple == null' >/dev/null \
    || fail "selector previewed a model not verified for the chosen profile"

  fixture="$TMP_ROOT/selector-unsupported.json"
  jq '.selector.preview = {profile:"Personal Claude", model:"anthropic/claude-sonnet-5",
        effort:"high thinking"}' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e '.selector.preview.state == "unsupported" and .selector.preview.tuple == null' >/dev/null \
    || fail "selector previewed an effort the profile does not support"

  fixture="$TMP_ROOT/selector-secret.json"
  jq '.selector.profiles["Company Codex"].last_selection = {model:"/Users/bob/token.txt",
        effort:"api_key high"}' "$FIXTURE" > "$fixture"
  "$CONSOLE" --fixture "$fixture" --format json --now 2026-08-13T12:00:00Z \
    | jq -e '([.selector.profiles[] | select(.profile == "Company Codex")][0].last_selection) == null' \
    >/dev/null || fail "selector remembered a secret-shaped selection"

  text=$("$CONSOLE" --fixture "$FIXTURE" --format selector --no-color --now 2026-08-13T12:00:00Z)
  assert_contains "$text" "Company Codex · openai-codex/gpt-5.6-sol · high thinking" \
    "selector surface did not preview the exact tuple"
  assert_contains "$text" "never launches" "selector surface did not disclaim launching"
  assert_not_contains "$text" "/Users/" "selector surface leaked a private path"
  if printf '%s' "$text" | grep -qE '[😀-🿿🚀-🛿✅❌🔴🟢🟡]'; then
    fail "selector surface used an emoji marker"
  fi

  local width over
  for width in 20 40 76; do
    over=$("$CONSOLE" --fixture "$FIXTURE" --format selector --no-color \
      --now 2026-08-13T12:00:00Z --width "$width" | fm_console_overlong_lines "$width")
    [ -z "$over" ] || fail "selector surface exceeded --width $width: $over"
  done
  pass "profile selector previews verified tuples without launching or copying credentials"
}

test_motion_is_bounded_and_reduced_motion_aware() {
  local motion reduced
  motion=$("$CONSOLE" --fixture "$FIXTURE" --format json --now 2026-08-13T12:00:00Z --motion)
  reduced=$("$CONSOLE" --fixture "$FIXTURE" --format json --now 2026-08-13T12:00:00Z --reduced-motion)

  printf '%s' "$motion" | jq -e '
    .motion.reduced_motion == false
      and .motion.looping_attention == false
      and .motion.steals_focus == false
      and .motion.obscures_text == false
      and (.motion.transition == "one-bounded")
      and (.motion.spinner == "bounded")
      and (.motion.pulse as $pulse | ["none", "one-pulse"] | index($pulse)) != null
  ' >/dev/null || fail "motion contract was unbounded or attention-looping"

  printf '%s' "$reduced" | jq -e '
    .motion.reduced_motion == true
      and .motion.pulse == "none"
      and .motion.transition == "none"
      and .motion.spinner == "none"
      and .motion.looping_attention == false
  ' >/dev/null || fail "reduced motion still reported animation"
  pass "motion stays bounded and honors reduced motion"
}

test_fleet_snapshot_exposes_recorded_model_and_effort() {
  local home out
  home="$TMP_ROOT/snapshot-model"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_write_meta "$home/state/model-task.meta" \
    "project=example" "harness=codex" "kind=ship" "mode=ship" \
    "model=gpt-5.3-codex" "effort=high"
  out=$(FM_HOME="$home" FM_SNAPSHOT_NOW=2026-08-13T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and ([.tasks[] | select(.id == "model-task")][0].model) == "gpt-5.3-codex"
      and ([.tasks[] | select(.id == "model-task")][0].effort) == "high"
  ' >/dev/null || fail "fleet snapshot did not expose recorded model and effort"
  pass "fleet snapshot exposes explicit model and effort metadata"
}

test_shared_snapshot_drives_every_surface
test_restart_is_deterministic
test_ttl_expiry_preserves_honest_state
test_malformed_and_private_identifiers_fail_closed
test_narrow_panel_and_ascii_network
test_metadata_publication_uses_named_lab_and_preserves_focus
test_failed_publication_reports_only_its_own_diagnostic
test_truncated_history_is_surfaced
test_fractional_ttl_is_refused_before_any_helper_call
test_status_panel_uses_accessible_markers_and_required_fields
test_decision_inbox_is_stable_bounded_and_approval_safe
test_alias_is_pure_identity_under_collision
test_restriction_survives_truncation_redaction_and_options
test_option_key_tokens_are_unique_and_readable
test_decision_options_are_never_silently_dropped
test_obsidian_decision_id_alias_and_ambiguity
test_chat_visibility_is_reported_honestly
test_profile_selector_is_display_only_and_verified
test_motion_is_bounded_and_reduced_motion_aware
test_fleet_snapshot_exposes_recorded_model_and_effort
