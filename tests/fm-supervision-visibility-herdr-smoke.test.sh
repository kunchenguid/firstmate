#!/usr/bin/env bash
# Opt-in real-Herdr proof for the display-only supervision state.
# It creates no agent process and uses only a synthetic idle lifecycle record in
# a guarded, named non-default lab session.
set -u

if [ "${FM_SUPERVISION_VISIBILITY_HERDR_SMOKE:-0}" != 1 ]; then
  echo "skip: set FM_SUPERVISION_VISIBILITY_HERDR_SMOKE=1 to run the isolated Herdr regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-visible-supervision)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-supervision-visibility-herdr.XXXXXX")
CRASH_PUBLISHER=

cleanup() {
  [ -z "$CRASH_PUBLISHER" ] || kill -KILL "$CRASH_PUBLISHER" 2>/dev/null || true
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
  rm -rf "$LAB"
  fm_test_cleanup
}
trap cleanup EXIT

# Keep every task-specific real Herdr call both helper-scoped and independently
# bounded. The helper remains the only process that invokes the real CLI.
run_lab() {
  perl -e 'my $timeout = shift; alarm $timeout; exec @ARGV' 15 \
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

mkdir -p "$LAB/home/state" "$LAB/home/config"
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
out=$(run_lab workspace create --cwd "$ROOT" --label fm-visible-supervision --no-focus)
pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$pane" ] || fail "lab workspace create did not return a pane"
run_lab pane report-agent "$pane" --source integration:pi --agent pi --state idle >/dev/null

read_agent() {
  run_lab agent get "$pane"
}

baseline=$(read_agent)
printf '%s' "$baseline" | jq -e '
  .result.agent.agent_status == "idle"
  and (.result.agent | has("custom_status") | not)
  and (.result.agent | has("state_labels") | not)
' >/dev/null || fail "inactive baseline was not plain idle"

# These are byte-for-byte the display arguments emitted by
# fm_supervision_visibility_refresh before its bounded Herdr call adds session
# targeting. The deterministic test separately pins that production argv.
run_lab pane report-metadata "$pane" \
  --source firstmate-supervision:smoke \
  --custom-status supervised \
  --state-label 'idle=idle · supervised' \
  --ttl-ms 360000 >/dev/null
run_lab pane report-metadata "$pane" \
  --source firstmate-supervision:smoke \
  --custom-status supervised \
  --state-label 'idle=idle · supervised' \
  --ttl-ms 360000 >/dev/null

active=$(read_agent)
printf '%s' "$active" | jq -e '
  .result.agent.agent_status == "idle"
  and .result.agent.custom_status == "supervised"
  and .result.agent.state_labels.idle == "idle · supervised"
' >/dev/null || fail "active supervision metadata changed lifecycle state or was not visible: $active"

run_lab pane report-metadata "$pane" \
  --source firstmate-supervision:smoke \
  --clear-custom-status --clear-state-labels >/dev/null

cleared=$(read_agent)
printf '%s' "$cleared" | jq -e '
  .result.agent.agent_status == "idle"
  and (.result.agent | has("custom_status") | not)
  and (.result.agent | has("state_labels") | not)
' >/dev/null || fail "clean clear did not restore plain idle"

crash_ready="$LAB/crash-ready"
(
  run_lab pane report-metadata "$pane" \
    --source firstmate-supervision:crash \
    --custom-status supervised \
    --state-label 'idle=idle · supervised' \
    --ttl-ms 500 >/dev/null
  touch "$crash_ready"
  while :; do sleep 30; done
) &
crash_publisher=$!
CRASH_PUBLISHER=$crash_publisher
for _ in {1..100}; do
  [ -e "$crash_ready" ] && break
  sleep 0.05
done
[ -e "$crash_ready" ] || fail "crash publisher did not report short-TTL metadata"
kill -KILL "$crash_publisher" 2>/dev/null || true
wait "$crash_publisher" 2>/dev/null || true
CRASH_PUBLISHER=

expired=
for _ in {1..100}; do
  crashed=$(read_agent)
  if printf '%s' "$crashed" | jq -e '
    .result.agent.agent_status == "idle"
    and (.result.agent | has("custom_status") | not)
    and (.result.agent | has("state_labels") | not)
  ' >/dev/null; then
    expired=1
    break
  fi
  sleep 0.05
done
[ "$expired" = 1 ] || fail "crashed publisher metadata did not expire through its TTL: $crashed"

version=$(run_lab status --json | jq -r '.client.version // "unknown"')
pass "real Herdr $version keeps Pi idle with clean clearing and crash TTL cleanup"
