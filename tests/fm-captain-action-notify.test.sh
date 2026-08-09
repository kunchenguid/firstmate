#!/usr/bin/env bash
# Transition behavior for watcher-owned captain-action desktop notifications.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOTIFY="$ROOT/bin/fm-captain-action-notify.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-action-notify)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_case() {  # <name>
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/home/state" "$dir/home/config"
  cat > "$dir/snapshot" <<'SH'
#!/usr/bin/env bash
cat "${FM_SNAPSHOT_FIXTURE:?}"
SH
  cat > "$dir/recorder" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "${FM_CAPTAIN_ACTION_NOTIFICATION_LOG:?}"
SH
  chmod +x "$dir/snapshot" "$dir/recorder"
  printf '%s\n' "$dir"
}

write_snapshot() {  # <file> <captain-actionable json array> <PR json array> [secondmates json array]
  local file=$1 decisions=$2 prs=$3 secondmates=${4:-[]}
  jq -n --argjson decisions "$decisions" --argjson prs "$prs" --argjson secondmates "$secondmates" '
    {schema:"fm-fleet-snapshot.v1",
     backlog:{records:$decisions},
     tasks:($prs | map({id,kind:"ship",pr:{url:.url},backlog:{title:.title}})),
     secondmate_current:{records:$secondmates}}
  ' > "$file"
}

run_notify() {  # <case-dir>
  local dir=$1
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_FLEET_SNAPSHOT_BIN="$dir/snapshot" FM_SNAPSHOT_FIXTURE="$dir/snapshot.json" \
    FM_CAPTAIN_ACTION_NOTIFICATION_CHANNEL=osascript \
    FM_CAPTAIN_ACTION_NOTIFICATION_EXEC="$dir/recorder" \
    FM_CAPTAIN_ACTION_NOTIFICATION_LOG="$dir/notifications.log" \
    "$NOTIFY"
}

notification_count() {  # <case-dir>
  [ -f "$1/notifications.log" ] || { printf '0'; return; }
  wc -l < "$1/notifications.log" | tr -d '[:space:]'
}

test_transition_detection_and_batching() {
  local dir count
  dir=$(make_case transitions)

  # An empty first snapshot establishes the bounded baseline without replaying
  # old work or posting a desktop banner.
  write_snapshot "$dir/snapshot.json" '[]' '[]'
  run_notify "$dir" || fail "baseline notification check failed"
  [ "$(notification_count "$dir")" = 0 ] || fail "empty baseline posted a notification"

  # One newly actionable decision posts exactly one notification.
  write_snapshot "$dir/snapshot.json" \
    '[{"id":"decide-theme","title":"Choose the alert tone","captain_actionable":true}]' '[]'
  run_notify "$dir" || fail "one-item notification check failed"
  count=$(notification_count "$dir")
  [ "$count" = 1 ] || fail "one new decision did not produce one notification (got $count)"
  grep -F $'osascript\tNew captain action: Decision: Choose the alert tone' "$dir/notifications.log" >/dev/null \
    || fail "one decision did not use the wedge notifier seam with its summary"

  # The identical open item has no new transition.
  run_notify "$dir" || fail "stable notification check failed"
  [ "$(notification_count "$dir")" = 1 ] || fail "an already actionable decision was re-notified"

  # A decision and PR landing together remain one batched OS notification.
  write_snapshot "$dir/snapshot.json" \
    '[{"id":"decide-theme","title":"Choose the alert tone","captain_actionable":true},
      {"id":"decide-scope","title":"Choose the launch scope","captain_actionable":true}]' \
    '[{"id":"ship-alerts","title":"Ship desktop alerts","url":"https://example.test/org/repo/pull/42"}]'
  run_notify "$dir" || fail "batched notification check failed"
  count=$(notification_count "$dir")
  [ "$count" = 2 ] || fail "several new items did not share one batched notification (got $count)"
  tail -1 "$dir/notifications.log" | grep -F '2 new captain actions:' >/dev/null \
    || fail "batched notification did not identify the number of new actions"
  tail -1 "$dir/notifications.log" | grep -F 'Decision: Choose the launch scope' >/dev/null \
    || fail "batched notification did not name the new decision"
  tail -1 "$dir/notifications.log" | grep -F 'PR: Ship desktop alerts' >/dev/null \
    || fail "batched notification did not name the new PR"

  # Resolution removes the identity from the immediately-prior set. Reopening it
  # is therefore a genuine new transition and posts once again.
  write_snapshot "$dir/snapshot.json" '[]' '[]'
  run_notify "$dir" || fail "resolved notification check failed"
  [ "$(notification_count "$dir")" = 2 ] || fail "resolution posted a notification"
  write_snapshot "$dir/snapshot.json" \
    '[{"id":"decide-theme","title":"Choose the alert tone","captain_actionable":true}]' '[]'
  run_notify "$dir" || fail "reopened notification check failed"
  [ "$(notification_count "$dir")" = 3 ] || fail "resolved then reopened decision was not re-notified"

  write_snapshot "$dir/snapshot.json" '[]' '[]' \
    '[{"id":"domain-alpha","decisions_open":[{"id":"worker","key":"release-channel","summary":"Choose the release channel","verb":"needs-decision"}]}]'
  run_notify "$dir" || fail "secondmate decision notification check failed"
  [ "$(notification_count "$dir")" = 4 ] || fail "new secondmate decision was not notified"
  tail -1 "$dir/notifications.log" | grep -F 'Decision: Choose the release channel' >/dev/null \
    || fail "secondmate decision notification omitted its summary"
  grep -Fx 'decision/secondmate/domain-alpha/release-channel' "$dir/home/state/.captain-action-notification-set" >/dev/null \
    || fail "secondmate decision identity did not preserve its decision key"
  pass "captain action notifier baselines silently, batches transitions, suppresses stable items, and re-notifies reopenings"
}

test_sibling_config_is_independent() {
  local dir
  dir=$(make_case sibling-config)
  printf 'off\n' > "$dir/home/config/wedge-alarm"
  printf 'osascript\n' > "$dir/home/config/captain-action-notifications"
  write_snapshot "$dir/snapshot.json" '[]' '[]'
  run_notify "$dir" || fail "sibling-config baseline failed"
  write_snapshot "$dir/snapshot.json" \
    '[{"id":"configured","title":"Use sibling preferences","captain_actionable":true}]' '[]'
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_FLEET_SNAPSHOT_BIN="$dir/snapshot" FM_SNAPSHOT_FIXTURE="$dir/snapshot.json" \
    FM_CAPTAIN_ACTION_NOTIFICATION_EXEC="$dir/recorder" \
    FM_CAPTAIN_ACTION_NOTIFICATION_LOG="$dir/notifications.log" \
    "$NOTIFY" || fail "sibling-config notification check failed"
  [ "$(notification_count "$dir")" = 1 ] \
    || fail "wedge-alarm preferences incorrectly disabled captain-action notifications"
  pass "captain action notifications use their independent sibling config"
}

test_snapshot_and_notifier_failures_are_silent() {
  local dir before
  dir=$(make_case failures)
  printf '#!/usr/bin/env bash\nexit 73\n' > "$dir/snapshot"
  chmod +x "$dir/snapshot"
  run_notify "$dir" || fail "snapshot failure escaped the best-effort notification helper"
  [ "$(notification_count "$dir")" = 0 ] || fail "snapshot failure posted a notification"

  write_snapshot "$dir/snapshot.json" '[]' '[]'
  cat > "$dir/snapshot" <<'SH'
#!/usr/bin/env bash
cat "${FM_SNAPSHOT_FIXTURE:?}"
SH
  chmod +x "$dir/snapshot"
  run_notify "$dir" || fail "notifier failure baseline failed"
  before=$(notification_count "$dir")
  write_snapshot "$dir/snapshot.json" \
    '[{"id":"decide-failure","title":"No crash","captain_actionable":true}]' '[]'
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
    FM_FLEET_SNAPSHOT_BIN="$dir/snapshot" FM_SNAPSHOT_FIXTURE="$dir/snapshot.json" \
    FM_CAPTAIN_ACTION_NOTIFICATION_CHANNEL=osascript \
    FM_CAPTAIN_ACTION_NOTIFICATION_EXEC=false \
    FM_CAPTAIN_ACTION_NOTIFICATION_LOG="$dir/notifications.log" \
    "$NOTIFY" || fail "notifier failure escaped the best-effort notification helper"
  [ "$(notification_count "$dir")" = "$before" ] || fail "failed notifier unexpectedly recorded delivery"
  pass "captain action notifier contains snapshot and OS-delivery failures"
}

test_transition_detection_and_batching
test_sibling_config_is_independent
test_snapshot_and_notifier_failures_are_silent
