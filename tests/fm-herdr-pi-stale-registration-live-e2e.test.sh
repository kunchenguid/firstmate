#!/usr/bin/env bash
# Default-on live guard for the Herdr stale-registration classifier (issue
# #4115) against the REAL Pi harness under the REAL Herdr binary.
#
# The defect: Herdr keeps a Pi registration (`agent get` -> agent=pi,
# agent_status=idle) after the Pi process has exited to a plain shell whenever
# a nested interactive shell sits under the pane's top shell - the crew shape,
# where `treehouse get` leaves a worktree shell under the pane's login shell.
# The adapter now proves an agent at process level before trusting a
# registration, and this guard measures the two vendor facts that proof rests
# on, which no fixture can prove:
#
#   1. how Pi presents in `pane process-info` (on Herdr 0.9.0 the kernel name
#      is `node` and only argv0 says `pi`), so the shared process classifier
#      must still attribute the running harness as `agent`;
#   2. whether this Herdr release still leaves the registration behind after
#      Pi quits under a nested shell, so the stale-registration branch is
#      exercised against the real record rather than a canned one.
#
# It fails naming the Herdr and Pi versions when either fact drifts. Pi is
# launched with no prompt and quit immediately, so no model token is spent and
# the shared live gate runs it by default wherever both tools are installed.
# Run it after every Herdr or Pi upgrade and before trusting a refreshed
# docs/verification/runtime-backends.md "Stale agent registration" entry.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; bin/fm-herdr-lab.sh owns the isolation).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_PI_STALE_REGISTRATION_LIVE_E2E herdr pi jq

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
PI_VERSION=$(pi --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION, pi $PI_VERSION]"
}

SESSION="fm-lab-pi-stale-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  local status=$?
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-stale.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
mkdir -p "$SCRATCH/cwd"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

lab() { fm_herdr_lab_cli "$SESSION" "$@"; }

# prepare only records the tripwire; the adapter's own server-ensure starts
# the lab session's server exactly as a spawn would.
fm_backend_herdr_server_ensure "$SESSION" || fail "could not start the isolated Herdr lab server"
WS=$(lab workspace create --label fm-pi-stale --cwd "$SCRATCH/cwd" 2>&1) \
  || fail "could not create the lab workspace: $WS"
PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$PANE_ID" ] || fail "workspace create did not return a root pane id"
TARGET="$SESSION:$PANE_ID"

wait_process_state() {  # <expected> <tries>
  local expected=$1 tries=$2 got i=0
  while [ "$i" -lt "$tries" ]; do
    got=$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")
    [ "$got" = "$expected" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

registered_status() {
  herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty'
}

# The crew shape: a nested interactive shell under the pane's top shell, then
# the real Pi TUI with no prompt.
lab pane run "$PANE_ID" zsh >/dev/null 2>&1 || fail "could not start the nested shell in the pane"
sleep 1
lab pane run "$PANE_ID" pi >/dev/null 2>&1 || fail "could not start pi in the pane"

# Herdr creates the record with its own placeholder status (`unknown`, verified
# 0.9.0) the moment it notices Pi, before Pi's extension reports a lifecycle
# state; only a lifecycle state is the registration this guard is about.
STATUS=
for _ in $(seq 1 300); do
  STATUS=$(registered_status)
  case "$STATUS" in working|idle|done|blocked) break ;; esac
  sleep 0.2
done
case "$STATUS" in
  working|idle|done|blocked) ;;
  *) version_fail \
    "pi never reported a lifecycle state to Herdr in this pane (agent get read '${STATUS:-agent_not_found}' for 60s); the herdr pi integration (~/.pi/agent/extensions/herdr-agent-state.ts) is what reports it" ;;
esac

wait_process_state agent 100 || version_fail \
  "pi is running and registered ($STATUS) but pane process-info reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")', not 'agent'. Observed foreground: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -c '.result.process_info.foreground_processes'). Teach bin/fm-agent-process-lib.sh's fm_agent_process_classify the identity this release actually reports"
FOREGROUND=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null \
  | jq -c '[.result.process_info.foreground_processes[] | {name, argv0}]')
STATE=$(fm_backend_agent_state herdr "$TARGET")
[ "$STATE" = alive ] || version_fail "a running, registered pi reads '$STATE' rather than 'alive' (registration '$(registered_status)', pane state '$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")', process state '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")', agent get: $(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | tr -d '\n'))"
note "pi $PI_VERSION under herdr $HERDR_VERSION: registered $STATUS, foreground $FOREGROUND"
pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a running registered pi classifies alive at process level"

# Quit Pi to the nested shell. A slash command can open a completion popup that
# swallows the first Enter, so one extra Enter is allowed before judging.
lab pane send-text "$PANE_ID" '/quit' >/dev/null 2>&1 || fail "could not type /quit"
sleep 0.5
lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1 || fail "could not submit /quit"
if ! wait_process_state shell 50; then
  lab pane send-keys "$PANE_ID" Enter >/dev/null 2>&1 || true
  wait_process_state shell 150 || version_fail \
    "pi did not exit to a shell within 40s of /quit; pane process-info reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")'"
fi

# Let Herdr settle whatever release it is going to do, then read the record.
sleep 2
STATUS=$(registered_status)
PANE_STATE=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")
STATE=$(fm_backend_agent_state herdr "$TARGET")
BUSY=$(fm_backend_herdr_busy_state "$TARGET")
[ "$STATE" = dead ] || version_fail \
  "after pi quit to a shell the endpoint recovers as '$STATE' (pane state '$PANE_STATE', registration '${STATUS:-none}') rather than 'dead'; every relaunch would be refused"
[ "$BUSY" != busy ] || version_fail "a shell-only pane after pi quit reads busy (registration '${STATUS:-none}')"
if [ -n "$STATUS" ]; then
  [ "$PANE_STATE" = stale-agent ] || version_fail \
    "Herdr kept the registration ($STATUS) over the shell-only pane but the classifier reads '$PANE_STATE' rather than 'stale-agent'"
  note "herdr $HERDR_VERSION kept the pi registration ($STATUS) after /quit under a nested shell: the stale-registration branch is exercised"
  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: the registration left behind by a quit pi reads stale-agent and recovers as dead"
else
  [ "$PANE_STATE" = no-agent ] || version_fail \
    "Herdr released the registration but the pane reads '$PANE_STATE' rather than 'no-agent'"
  note "herdr $HERDR_VERSION released the pi registration after /quit under a nested shell; the stale-registration branch was not exercised by this release, the agent-free verdict still held through agent_not_found"
  pass "real herdr $HERDR_VERSION + pi $PI_VERSION: a quit pi under a nested shell recovers as dead"
fi
