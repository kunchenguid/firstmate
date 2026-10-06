#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || { printf 'skip - tasks-axi absent\n'; exit 0; }

TEST_HOME=$(fm_test_tmproot fm-integrate-after)
mkdir -p "$TEST_HOME/data" "$TEST_HOME/config"
mkdir -p "$TEST_HOME/state"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$TEST_HOME/data/backlog.md"
tool() { FM_HOME="$TEST_HOME" "$ROOT/bin/fm-integrate-after.sh" "$@"; }
backlog() { FM_HOME="$TEST_HOME" "$ROOT/bin/fm-tasks-axi.sh" "$@"; }

backlog add provider 'Frozen provider' >/dev/null
backlog add consumer 'Consumer' --body 'Preserve this note.' >/dev/null
backlog add hard-blocked 'Implementation blocker' --blocked-by provider >/dev/null
probe_dispatch() {
  FM_HOME="$TEST_HOME" bash -c '
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_row_probe "$2/data" "$3" || exit 2
    fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE"
  ' _ "$ROOT" "$TEST_HOME" "$1"
}
if probe_dispatch hard-blocked; then fail 'ordinary blocked-by no longer prevents implementation'; fi
probe_dispatch consumer || fail 'integration-only relation made a queued row ineligible for dispatch'
tool --help | grep -qi 'integration-only' || fail 'public integration help is missing'
tool check legacy-task | grep -q 'legacy task has no backlog row' || fail 'pre-backlog task was gated'
tool check consumer | grep -q 'no integration-only dependencies' || fail 'legacy task was gated'
tool add consumer provider >/dev/null
tool add consumer provider | grep -q '^unchanged:' || fail 'add was not idempotent'
body=$(backlog show consumer --full)
printf '%s\n' "$body" | grep -q 'Preserve this note' || fail 'existing body was lost'
printf '%s\n' "$body" | grep -q 'integrate-after: provider' || fail 'relation was not durable in task body'

# Integration dependency does not turn into tasks-axi's implementation blocker.
backlog start consumer >/dev/null || fail 'integration relation blocked implementation'
if tool check consumer > "$TEST_HOME/check.out" 2>&1; then fail 'landing passed before provider Done'; fi
grep -q 'provider state is queued' "$TEST_HOME/check.out" || fail 'landing refusal did not name provider state'
printf 'paused: integrate-after: provider, waiting for landing\n' > "$TEST_HOME/state/consumer.status"
ready_tick() {
  FM_HOME="$TEST_HOME" FM_STATE_OVERRIDE="$TEST_HOME/state" bash -c '
    . "$1/bin/fm-watch.sh"
    integrate_after_ready_tick
  ' _ "$ROOT"
}
if ready_tick; then fail 'consumer was notified before provider landing'; fi
[ ! -s "$TEST_HOME/state/.wake-queue" ] || fail 'unready consumer queued a notification'
# A confirmed PR merge releases the gate before teardown moves the provider to Done.
printf 'pr=https://github.com/example/project/pull/12\n' > "$TEST_HOME/state/provider.meta"
FM_STATE_OVERRIDE="$TEST_HOME/state" bash -c '
  . "$1/bin/fm-pr-lib.sh"
  fm_pr_poll_merge_mark_notified "$2" provider github github.com example/project 12
' _ "$ROOT" "$TEST_HOME/state" || fail 'could not stage a confirmed merge notification'
tool check consumer | grep -q 'provider landing confirmed' || fail 'confirmed PR merge did not release integration'
if ready_tick; then fail 'unready probe ignored its durable check interval'; fi
touch -t 202001010000 "$TEST_HOME/state/.integrate-after-probed-consumer"
mkdir "$TEST_HOME/state/.integrate-after-ready-consumer"
if ready_tick >/dev/null 2>&1; then fail 'failed marker write unexpectedly completed'; fi
rmdir "$TEST_HOME/state/.integrate-after-ready-consumer"
[ "$(grep -c 'integrate-after ready: consumer' "$TEST_HOME/state/.wake-queue")" -eq 1 ] \
  || fail 'failed marker write lost the queued notification'
touch -t 202001010000 "$TEST_HOME/state/.integrate-after-probed-consumer"
ready_tick || fail 'queued ready notification was not recovered'
[ "$(grep -c 'integrate-after ready: consumer' "$TEST_HOME/state/.wake-queue")" -eq 1 ] \
  || fail 'retry duplicated a queued ready notification'
grep -q 'integrate-after ready: consumer' "$TEST_HOME/state/.wake-queue" || fail 'ready notification was not durable'
if ready_tick; then fail 'ready notification repeated for an unchanged pause'; fi
printf 'paused: integrate-after: provider, waiting for landing\n' >> "$TEST_HOME/state/consumer.status"
ready_tick || fail 'new pause declaration was suppressed by the old ready marker'
[ "$(grep -c 'integrate-after ready: consumer' "$TEST_HOME/state/.wake-queue")" -eq 2 ] \
  || fail 'new pause did not get its own notification'
if ready_tick; then fail 'new pause notification repeated'; fi
printf 'working: final validation\n' > "$TEST_HOME/state/consumer.status"
if ready_tick; then fail 'working consumer was notified'; fi
[ ! -e "$TEST_HOME/state/.integrate-after-ready-consumer" ] || fail 'new work did not clear the notification marker'
[ ! -e "$TEST_HOME/state/.integrate-after-probed-consumer" ] || fail 'new work did not clear the probe marker'
backlog 'done' provider >/dev/null
tool check consumer | grep -q 'provider landing confirmed' || fail 'Done provider did not release integration'
backlog prune --keep 0 >/dev/null
if tool check consumer > "$TEST_HOME/check.out" 2>&1; then fail 'archived provider was silently accepted'; fi
grep -q 'verify its landing and remove' "$TEST_HOME/check.out" \
  || fail 'archived provider did not require explicit verification and removal'
printf 'Preserve this note.\nintegrate-after:provider\n' > "$TEST_HOME/body"
backlog update consumer --body-file "$TEST_HOME/body" >/dev/null
if tool check consumer > "$TEST_HOME/check.out" 2>&1; then fail 'no-space relation was accepted'; fi
grep -q 'malformed integrate-after relation' "$TEST_HOME/check.out" || fail 'no-space relation did not fail closed'
printf 'Preserve this note.\nintegrate-after: provider\n' > "$TEST_HOME/body"
backlog update consumer --body-file "$TEST_HOME/body" >/dev/null
tool remove consumer provider >/dev/null
tool remove consumer provider | grep -q '^unchanged:' || fail 'remove was not idempotent'
tool check consumer | grep -q 'no integration-only dependencies' || fail 'relation was not removed'
printf 'paused: integrate-after: provider, waiting for landing\n' > "$TEST_HOME/state/consumer.status"
ready_tick || fail 'removing a verified dependency did not notify the paused consumer'
[ "$(grep -c 'integrate-after ready: consumer' "$TEST_HOME/state/.wake-queue")" -eq 3 ] \
  || fail 'dependency removal did not queue one ready notification'
printf 'ok - integration relation dispatches early and gates landing\n'
