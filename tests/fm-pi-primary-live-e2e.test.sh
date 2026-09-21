#!/usr/bin/env bash
# Opt-in credentialed Pi continuity regression on a private tmux socket and
# isolated project/home state. It uses the existing shared Pi auth store without
# copying credentials and pins the captain-approved openai-codex model.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PI_LIVE_E2E pi tmux jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
AHOY_PROJECT="$LAB/ahoy-project"
HOME_DIR="$LAB/fmhome"
PI_VERSION=$(pi --version)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
LEGACY_AWAY=$'\xE2\x81\xA3Supervisor escalate (1 event(s)): done: legacy rollout'
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode watcher "CURRENT_AHOY_WATCHER_BODY" CURRENT_WATCHER \
  || fail "could not construct current Ahoy watcher fixture"
QUOTED_CURRENT="Captain quote: $CURRENT_WATCHER"
ASCII_ONLY='FIRSTMATE_OP: v1 watcher: captain-authored text'

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
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
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
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

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_ahoy_case() {
  local label=$1 preceding=$2 expected=$3 out status=0
  out=$(
    cd "$PROJECT" &&
      FM_HOME="$LAB/ahoy-$label-home" FM_ROOT_OVERRIDE="$PROJECT" \
        pi --print --approve --no-session --no-context-files --no-extensions \
        --no-skills --skill .agents/skills --tools read,bash \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "$preceding" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi Ahoy $label case exited $status: $out"
  case "$expected" in
    bearings)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "Pi Ahoy $label case did not take Bearings: $out"
      ;;
    boundary)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "Pi Ahoy $label near miss was treated as operational: $out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  # A legacy startup instruction is still executable input. Give it an inert
  # startup endpoint and bash instead of testing refusal for a missing tool.
  cp "$PROJECT/bin/fm-session-start.sh" "$LAB/session-start.saved"
  printf '#!/usr/bin/env bash\nprintf "SESSION_START_DONE\\n"\n' > "$PROJECT/bin/fm-session-start.sh"
  mkdir -p "$PROJECT/.agents/skills/ahoy" "$PROJECT/.agents/skills/bearings"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$PROJECT/.agents/skills/ahoy/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$PROJECT/.agents/skills/bearings/SKILL.md"

  run_ahoy_case legacy-start "$LEGACY_START" bearings
  run_ahoy_case legacy-away "$LEGACY_AWAY" bearings
  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
  run_ahoy_case quoted-current "$QUOTED_CURRENT" boundary
  run_ahoy_case ascii-only "$ASCII_ONLY" boundary
  cp "$LAB/session-start.saved" "$PROJECT/bin/fm-session-start.sh"
}

run_native_ahoy_regressions() {
  local first_home="$LAB/pi-ahoy-first-home"
  local later_home="$LAB/pi-ahoy-later-home"
  local first_out later_out

  mkdir -p \
    "$AHOY_PROJECT/.pi/extensions/lib" \
    "$AHOY_PROJECT/.agents/skills/ahoy" \
    "$AHOY_PROJECT/.agents/skills/bearings" \
    "$AHOY_PROJECT/bin" \
    "$first_home/state" "$first_home/config" \
    "$later_home/state" "$later_home/config"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$AHOY_PROJECT/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$AHOY_PROJECT/.pi/extensions/lib/"
  cp \
    "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$AHOY_PROJECT/bin/"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$AHOY_PROJECT/.agents/skills/ahoy/SKILL.md"
  chmod +x "$AHOY_PROJECT/bin/fm-sessionstart-nudge.sh"
  # shellcheck disable=SC2016 # Variables expand in the generated script, not this test shell.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'file="${FM_HOME:?}/state/session-start-count"' \
    'count=0' \
    '[ ! -f "$file" ] || count=$(sed -n "1p" "$file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$file"' \
    'printf "SESSION_START_DONE count=%s\n" "$count"' \
    > "$AHOY_PROJECT/bin/fm-session-start.sh"
  chmod +x "$AHOY_PROJECT/bin/fm-session-start.sh"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
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
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '# Native Pi Ahoy regression fixture' \
    '' \
    'Run `bin/fm-session-start.sh` exactly once at session start.' \
    > "$AHOY_PROJECT/AGENTS.md"

  first_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$first_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "/ahoy"
  )
  printf '%s\n' "$first_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    || fail "Pi native first-message Ahoy did not take Bearings: $first_out"
  [ "$(sed -n '1p' "$first_home/state/session-start-count")" = 1 ] \
    || fail "Pi native first-message Ahoy did not preserve one session-start execution"

  later_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$later_home" pi --mode json --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "Respond exactly PRIOR_BOUNDARY_ACK." "/ahoy" \
        | jq -r 'select(.type == "message_end" and .message.role == "assistant") | .message.content[]? | select(.type == "text") | .text'
  )
  printf '%s\n' "$later_out" | grep -Fq "PRIOR_BOUNDARY_ACK" \
    || fail "Pi native later-message setup did not preserve the genuine captain boundary: $later_out"
  printf '%s\n' "$later_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    && fail "Pi native later-message Ahoy gathered Bearings: $later_out"
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "Pi native later-message Ahoy reran session start"
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
run_ahoy_transcript_regressions
run_native_ahoy_regressions
mkdir -p "$PROJECT/.pi/extensions/lib"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship-sprite.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$PROJECT/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$PROJECT/.pi/extensions/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$PROJECT/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --no-session --no-context-files --no-extensions -e .pi/extensions/fm-calm.ts -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts --model openai-codex/gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] || fail "Pi turn-end extension did not load"
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] || fail "Pi watcher extension did not load"
wait_for_text "(openai-codex)" 120 || fail "Pi did not reach its ready composer"
sleep 1

send_prompt "/calm"
sleep 0.2
send_prompt "Reply exactly CALM_LIVE_WORKING_VISIBLE"
i=0
while [ "$i" -lt 240 ]; do
  pane=$(capture)
  if printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱'; then
    break
  fi
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱' \
  || fail "Calm did not show the working ship on the credentialed provider path"
printf '%s\n' "$pane" | grep -Fq "Working..." \
  && fail "Calm left Pi's stock working row visible on the credentialed provider path"
wait_for_exact_line "CALM_LIVE_WORKING_VISIBLE" 120 \
  || fail "Pi did not settle the Calm working-ship provider probe"
pane=$(capture)
printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱' \
  && fail "Calm left the working ship on screen after the run settled"
printf '%s\n' "$pane" | grep -Fq "calm transcript" \
  && fail "Calm added a persistent Calm status row on the credentialed provider path"
send_prompt "/calm"
sleep 0.2

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Supervision is already active through the extension. Do not re-arm it with a tool or bash. Reply exactly READY. After a watcher wake arrives, run bin/fm-wake-drain.sh and reply exactly HANDLED."
# Owning session_start can already have armed the first cycle. Prove live
# supervision rather than requiring a redundant model call's old result text.
i=0
while [ "$i" -lt 120 ]; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c \
    '. "$1"; fm_watcher_healthy "$2" "$3" 300 "$4"' _ \
    "$PROJECT/bin/fm-wake-lib.sh" "$HOME_DIR/state" "$PROJECT/bin/fm-watch.sh" "$HOME_DIR" && break
  sleep 0.5
  i=$((i + 1))
done
[ "$i" -lt 120 ] || fail "Pi did not establish a healthy initial watcher"
wait_for_exact_line "READY" 120 || fail "Pi did not settle before the watcher stimulus"
initial_arm_tool_count=$(capture | grep -Ec 'watcher: (started|unchanged|not armed|read-only)' || true)

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Pi extension did not start and ledger-link a successor after the actionable close"
wait_for_exact_line "HANDLED" 120 || fail "Pi did not drain and settle after its extension-owned successor started"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "successor was not protecting Pi before its next turn end (guard count $guard_count)"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi
arm_tool_result_count=$(printf '%s\n' "$pane" | grep -Ec 'watcher: (started|unchanged|not armed|read-only)' || true)
[ "$arm_tool_result_count" -eq "$initial_arm_tool_count" ] \
  || fail "Pi model re-armed after the watcher stimulus instead of relying on the extension"

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

# A real Pi session must recover a watcher that loses health after readiness,
# without another model tool call or turn-end prompt to trigger the repair.
lab_pid_is_safe "$watcher_pid" || fail "unowned watcher in live health fixture"
kill -STOP "$watcher_pid" || fail "could not suspend the fixture watcher"
touch -t 200001010000 "$HOME_DIR/state/.last-watcher-beat"
i=0
while [ "$i" -lt 120 ]; do
  grep -Eq "watcher_pid=$watcher_pid.*reason=watcher-unhealthy.*successor=started:[0-9]+" \
    "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq "watcher_pid=$watcher_pid.*reason=watcher-unhealthy.*successor=started:[0-9]+" \
  "$HOME_DIR/state/.watch-cycle-exits.log" \
  || fail "Pi did not automatically replace its live-but-stale watcher"
wait_pid_dead "$watcher_pid" || fail "Pi retained the unhealthy watcher"
after_health_tool_count=$(capture | grep -Ec 'watcher: (started|unchanged|not armed|read-only)' || true)
[ "$after_health_tool_count" -eq "$arm_tool_result_count" ] \
  || fail "Pi needed a model arm call to recover post-readiness health"
watcher_pid=$(sed -n '1p' "$HOME_DIR/state/.watch.lock/pid")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
printf 'ok - Pi %s replaces a post-readiness stale watcher without a model re-arm\n' "$PI_VERSION"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E covered the Calm working ship, Ahoy first/later messages, legacy transcripts, near misses, and watcher continuity\n' "$PI_VERSION"
