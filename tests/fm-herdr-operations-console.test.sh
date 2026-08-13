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

run_json() {
  "$CONSOLE" --fixture "$FIXTURE" --format json --now 2026-08-13T12:00:00Z
}

test_shared_snapshot_drives_every_surface() {
  local out
  out=$(run_json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-herdr-operations-console.v1"
      and .mode == "fixture"
      and .theme == "tokyo-night"
      and ((.tasks | map(.id)) == .network.task_ids)
      and (.tasks | length == 6)
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
  panel=$("$CONSOLE" --fixture "$FIXTURE" --format panel --no-color --now 2026-08-13T12:00:00Z --width 76)
  if printf '%s\n' "$panel" | awk 'length($0) > 76 { exit 1 }'; then :; else
    fail "narrow panel emitted a line wider than 76 columns"
  fi
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
test_fleet_snapshot_exposes_recorded_model_and_effort
