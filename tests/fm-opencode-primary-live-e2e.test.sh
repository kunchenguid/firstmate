#!/usr/bin/env bash
# Opt-in credentialed OpenCode continuity regression on an isolated project and
# FM_HOME. Existing OpenCode credentials stay in their managed store.
set -u

if [ "${FM_OPENCODE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OPENCODE_LIVE_E2E=1 to run the interactive OpenCode continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v opencode >/dev/null 2>&1 || fail "opencode not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
SOCKET="fm-opencode-live-e2e-$$"
SESSION=opencode-live-e2e
LAB="$ROOT/.opencode-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
OPENCODE_VERSION=$(opencode --version)
AHOY_PROJECT="$LAB/ahoy-project"
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
LEGACY_AWAY=$'\xE2\x81\xA3Supervisor escalate (1 event(s)): done: legacy rollout'
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -800 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-180} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_absent() {
  local unexpected=$1 attempts=${2:-60} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$unexpected" || return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

dismiss_update_offer() {
  capture | grep -Fq "Update Available" || return 0
  # Choose Skip explicitly. Escape merely hides the offer until the next idle
  # event, which can obstruct the watcher follow-up under test.
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Left Enter
  wait_for_absent "Update Available" 60
}

wait_for_handled() {
  local i=0
  while [ "$i" -lt 240 ]; do
    dismiss_update_offer || return 1
    [ -f "$HOME_DIR/state/opencode-model-handled" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local watcher_pid arm_pid
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

run_ahoy_case() {
  local label=$1 preceding=$2 expected=$3 db="$LAB/opencode-$1.db"
  local first_out second_out session_id status=0
  first_out=$(
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$db" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run --pure --format json "$preceding"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode Ahoy $label setup exited $status: $first_out"
  session_id=$(printf '%s\n' "$first_out" | jq -r 'select(.sessionID != null) | .sessionID' | head -1)
  [ -n "$session_id" ] || fail "OpenCode Ahoy $label setup did not return a session id: $first_out"

  status=0
  second_out=$(
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$db" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run --pure --format json --session "$session_id" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode Ahoy $label case exited $status: $second_out"
  case "$expected" in
    bearings)
      printf '%s\n' "$second_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "OpenCode Ahoy $label case did not take Bearings: $second_out"
      ;;
    boundary)
      printf '%s\n' "$second_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "OpenCode Ahoy $label near miss was treated as operational: $second_out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  mkdir -p "$AHOY_PROJECT/.agents/skills/ahoy" "$AHOY_PROJECT/.agents/skills/bearings"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$AHOY_PROJECT/.agents/skills/ahoy/SKILL.md"
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$AHOY_PROJECT/.agents/skills/bearings/SKILL.md"

  run_ahoy_case legacy-start "$LEGACY_START" bearings
  run_ahoy_case legacy-away "$LEGACY_AWAY" bearings
  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
}

mkdir -p "$LAB"
run_ahoy_transcript_regressions
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$PROJECT/.opencode/plugins/fm-primary-watch-arm.js"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/opencode-e2e.meta"

# shellcheck disable=SC2016 # The model, not this test shell, expands FM_HOME.
PROMPT='Use the terminal to run `printf ready > "$FM_HOME/state/opencode-model-initial"`, then respond briefly. If a later watcher wake arrives, run bin/fm-wake-drain.sh, then run `printf handled > "$FM_HOME/state/opencode-model-handled"`. Never run or request any watcher arm command.'
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; opencode --auto; rc=\$?; printf \"OPENCODE_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

# Send the initial prompt through the ready composer so this exercises the same
# persistent TUI path as a primary session.
wait_for_text "$OPENCODE_VERSION" 120 || fail "OpenCode did not reach its TUI"
dismiss_update_offer || fail "OpenCode update offer did not dismiss"
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$PROMPT"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
i=0
while [ "$i" -lt 240 ]; do
  dismiss_update_offer || fail "OpenCode update offer obstructed the initial turn"
  [ -f "$HOME_DIR/state/opencode-model-initial" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/opencode-model-initial" ] || fail "OpenCode credentialed initial turn did not complete"

i=0
while [ "$i" -lt 120 ]; do
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
if [ -z "${watcher_pid:-}" ] || ! kill -0 "$watcher_pid" 2>/dev/null; then
  fail "OpenCode idle event did not start the initial watcher"
fi

printf 'done: opencode live e2e watcher fire\n' > "$HOME_DIR/state/opencode-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "OpenCode plugin did not start and ledger-link a successor after the actionable close"
wait_for_handled || fail "OpenCode did not drain and settle after plugin-owned re-arm"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "OpenCode successor was not protecting the next idle event (guard count $guard_count)"
if printf '%s\n' "$pane" | grep -Fq '$ bin/fm-watch-arm.sh'; then
  fail "OpenCode model attempted to re-arm instead of leaving continuity to the plugin"
fi

printf 'ok - OpenCode %s live E2E covered Ahoy legacy transcripts and near misses, then auto-started one successor\n' "$OPENCODE_VERSION"
