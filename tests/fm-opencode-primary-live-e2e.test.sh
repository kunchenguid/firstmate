#!/usr/bin/env bash
# Token-free OpenCode 2 native plugin integration plus an opt-in credentialed
# OpenCode continuity regression, both on an isolated project and FM_HOME.
# Existing OpenCode credentials stay in their managed store.
#
# The token-free half drives tests/opencode-v2-live-fixture.py (a private
# `opencode serve` and a loopback provider) against every OpenCode 2 executable
# named in FM_OPENCODE_LIVE_BINS (space-separated paths), or the `opencode` on
# PATH when that is unset. An OpenCode 1.x executable is reported and skipped,
# because the fixture exercises only the OpenCode 2 plugin surface.
# FM_OPENCODE_LIVE_E2E=1 selects the credentialed TUI half instead, against the
# `opencode` on PATH, with the launch flags and session database queries of its
# detected major.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

opencode_major() {  # <executable>
  local version
  version=$("$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  printf '%s\n' "${version%%.*}"
}

if [ "${FM_OPENCODE_LIVE_E2E:-0}" != 1 ]; then
  fm_live_gate default-on FM_OPENCODE_V2_OFFLINE_LIVE opencode python3 git
  fixture="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/opencode-v2-live-fixture.py"
  checked=0
  for bin in ${FM_OPENCODE_LIVE_BINS:-$(command -v opencode)}; do
    [ -x "$bin" ] || { printf 'not ok - OpenCode executable %s is missing\n' "$bin" >&2; exit 1; }
    major=$(opencode_major "$bin")
    if [ -z "$major" ] || [ "$major" -lt 2 ]; then
      printf 'skip: %s reports %s, not OpenCode 2\n' "$bin" "$("$bin" --version 2>/dev/null || printf unknown)"
      continue
    fi
    PATH="$(dirname "$bin"):$PATH" python3 "$fixture" || {
      printf 'not ok - OpenCode %s native fixture failed\n' "$("$bin" --version)" >&2
      exit 1
    }
    checked=$((checked + 1))
  done
  [ "$checked" -gt 0 ] || printf 'skip: no OpenCode 2 executable to exercise\n'
  exit 0
fi

fm_live_gate opt-in FM_OPENCODE_LIVE_E2E opencode tmux sqlite3

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

TMUX=$(command -v tmux)
SOCKET="fm-opencode-live-e2e-$$"
SESSION=opencode-live-e2e
LAB="$ROOT/.opencode-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
# The TUI panes below start through a login shell, which can reset PATH, so
# they launch this resolved executable rather than whatever that PATH finds.
OPENCODE_BIN=$(command -v opencode)
OPENCODE_VERSION=$("$OPENCODE_BIN" --version)
OPENCODE_MAJOR=$(opencode_major "$OPENCODE_BIN")
# OpenCode 2 runs every session on a private server (--standalone) and stores
# sessions in session_v2/session_message; OpenCode 1 uses --pure for a
# plugin-free run and the session/message/part tables.
if [ -n "$OPENCODE_MAJOR" ] && [ "$OPENCODE_MAJOR" -ge 2 ]; then
  OC_PLUGIN_FREE=--standalone
  OC_PRIVATE=--standalone
  OC_SESSION_TABLE=session_v2
else
  OC_PLUGIN_FREE=--pure
  OC_PRIVATE=
  OC_SESSION_TABLE=session
fi

sql_startup_text() {
  if [ "$OC_SESSION_TABLE" = session_v2 ]; then
    printf '%s' "select json_extract(m.data,'$.text') text from session_message m where m.type='user' and json_extract(m.data,'$.text') like '%FIRSTMATE_OP:%' order by m.time_created limit 1;"
  else
    printf '%s' "select json_extract(p.data,'$.text') text from message m join part p on p.message_id=m.id where json_extract(m.data,'$.role')='user' and json_extract(p.data,'$.text') like '%FIRSTMATE_OP:%' order by m.time_created limit 1;"
  fi
}

sql_last_assistant_text() {  # [session-id]
  local scope=''
  if [ "$OC_SESSION_TABLE" = session_v2 ]; then
    [ -z "${1:-}" ] || scope="m.session_id='$1' and "
    printf '%s' "select c.value->>'text' text from session_message m, json_each(json_extract(m.data,'$.content')) c where ${scope}m.type='assistant' and c.value->>'type'='text' order by m.time_created desc, m.seq desc limit 1;"
  else
    [ -z "${1:-}" ] || scope="m.session_id='$1' and "
    printf '%s' "select json_extract(p.data,'$.text') text from message m join part p on p.message_id=m.id where ${scope}json_extract(m.data,'$.role')='assistant' and json_extract(p.data,'$.type')='text' order by m.time_created desc limit 1;"
  fi
}

sql_assistant_text_count() {  # <needle>
  if [ "$OC_SESSION_TABLE" = session_v2 ]; then
    printf '%s' "select count(*) from session_message m, json_each(json_extract(m.data,'$.content')) c where m.type='assistant' and c.value->>'type'='text' and c.value->>'text' like '%$1%';"
  else
    printf '%s' "select count(*) from message m join part p on p.message_id=m.id where json_extract(m.data,'$.role')='assistant' and json_extract(p.data,'$.type')='text' and json_extract(p.data,'$.text') like '%$1%';"
  fi
}
AHOY_PROJECT="$LAB/ahoy-project"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode session-start "$LEGACY_START" CURRENT_START \
  || fail "could not construct the current session-start fixture"
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode watcher "CURRENT_AHOY_WATCHER_BODY" CURRENT_WATCHER \
  || fail "could not construct current Ahoy watcher fixture"
QUOTED_CURRENT="Captain quote: $CURRENT_WATCHER"
ASCII_ONLY='FIRSTMATE_OP: v1 watcher: captain-authored text'

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
  local assistant_text first_out second_out session_id status=0
  first_out=$(
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$db" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run "$OC_PLUGIN_FREE" --format json "$preceding"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode Ahoy $label setup exited $status: $first_out"
  session_id=$(printf '%s\n' "$first_out" | jq -r 'select(.sessionID != null) | .sessionID' | head -1)
  [ -n "$session_id" ] || fail "OpenCode Ahoy $label setup did not return a session id: $first_out"

  status=0
  second_out=$(
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$db" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run "$OC_PLUGIN_FREE" --format json --session "$session_id" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode Ahoy $label case exited $status: $second_out"
  assistant_text=$(printf '%s\n' "$second_out" | jq -r 'select(.type == "text") | .part.text' | tail -1)
  case "$expected" in
    bearings)
      printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "OpenCode Ahoy $label case did not take Bearings: $second_out"
      ;;
    boundary)
      printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "OpenCode Ahoy $label near miss was treated as operational: $second_out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  mkdir -p \
    "$AHOY_PROJECT/.opencode/plugins/lib" \
    "$AHOY_PROJECT/.agents/skills/ahoy" \
    "$AHOY_PROJECT/.agents/skills/bearings" \
    "$AHOY_PROJECT/bin"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.opencode/plugins/fm-primary-sessionstart-nudge.js" \
    "$ROOT/.opencode/plugins/package.json" \
    "$AHOY_PROJECT/.opencode/plugins/"
  cp "$ROOT/.opencode/plugins/lib/fm-opencode2.js" "$AHOY_PROJECT/.opencode/plugins/lib/fm-opencode2.js"
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
    '# Native OpenCode Ahoy regression fixture' \
    '' \
    'Run `bin/fm-session-start.sh` exactly once at session start.' \
    > "$AHOY_PROJECT/AGENTS.md"

  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
  run_ahoy_case quoted-current "$QUOTED_CURRENT" boundary
  run_ahoy_case ascii-only "$ASCII_ONLY" boundary
}

wait_for_db_count() {
  local db=$1 query=$2 expected=$3 attempts=${4:-180} i=0 actual
  while [ "$i" -lt "$attempts" ]; do
    actual=
    if [ -f "$db" ]; then
      actual=$(sqlite3 "$db" "$query" 2>/dev/null || true)
    fi
    [ "$actual" = "$expected" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

run_native_ahoy_regressions() {
  local first_home="$LAB/opencode-ahoy-first-home"
  local later_home="$LAB/opencode-ahoy-later-home"
  local first_db="$LAB/opencode-ahoy-first.db"
  local later_db="$LAB/opencode-ahoy-later.db"
  local native_session=opencode-ahoy-native
  local session_id startup_text assistant_text session_count status

  mkdir -p \
    "$first_home/state" "$first_home/config" \
    "$later_home/state" "$later_home/config"

  status=0
  (
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$first_db" FM_HOME="$first_home" \
        OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run $OC_PRIVATE --format json --auto "/ahoy"
  ) >/dev/null || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode native first-message Ahoy exited $status"
  session_id=$(sqlite3 "$first_db" "select id from $OC_SESSION_TABLE order by time_created desc limit 1;")
  startup_text=$(sqlite3 -json "$first_db" "$(sql_startup_text)" \
    | jq -r '.[0].text')
  [ "$startup_text" = "$CURRENT_START" ] \
    || fail "OpenCode native first-message session stored an unexpected typed startup input: $startup_text"
  assistant_text=$(sqlite3 -json "$first_db" "$(sql_last_assistant_text)" \
    | jq -r '.[0].text')
  printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    || fail "OpenCode native first-message Ahoy did not take Bearings: $assistant_text"
  [ "$(sed -n '1p' "$first_home/state/session-start-count")" = 1 ] \
    || fail "OpenCode native first-message Ahoy did not preserve one session-start execution"
  session_count=$(sqlite3 "$first_db" "select count(*) from $OC_SESSION_TABLE;")
  [ "$session_count" = 1 ] || fail "OpenCode native first-message Ahoy left the original session"

  "$TMUX" -L "$SOCKET" new-session -d -s "$native_session" -c "$AHOY_PROJECT" \
    "env OPENCODE_DB='$later_db' FM_HOME='$later_home' OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' '$OPENCODE_BIN' $OC_PRIVATE --auto"
  i=0
  while [ "$i" -lt 120 ]; do
    "$TMUX" -L "$SOCKET" capture-pane -p -t "$native_session" 2>/dev/null | grep -Fq "$OPENCODE_VERSION" && break
    sleep 0.5
    i=$((i + 1))
  done
  [ "$i" -lt 120 ] || fail "OpenCode native later-message session did not reach its TUI"
  "$TMUX" -L "$SOCKET" send-keys -t "$native_session" -l "Respond exactly PRIOR_BOUNDARY_ACK."
  "$TMUX" -L "$SOCKET" send-keys -t "$native_session" Enter
  wait_for_db_count "$later_db" "$(sql_assistant_text_count PRIOR_BOUNDARY_ACK)" \
    1 || fail "OpenCode native later-message setup did not preserve the genuine captain boundary"
  session_id=$(sqlite3 "$later_db" "select id from $OC_SESSION_TABLE order by time_created desc limit 1;")
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "OpenCode native later-message setup did not run session start exactly once"
  "$TMUX" -L "$SOCKET" kill-server

  status=0
  (
    cd "$AHOY_PROJECT" &&
      OPENCODE_DB="$later_db" FM_HOME="$later_home" \
        OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1 \
        OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' \
        opencode run $OC_PRIVATE --format json --auto --session "$session_id" "/ahoy"
  ) >/dev/null || status=$?
  [ "$status" -eq 0 ] || fail "OpenCode native later-message Ahoy exited $status"
  assistant_text=$(sqlite3 -json "$later_db" "$(sql_last_assistant_text "$session_id")" \
    | jq -r '.[0].text')
  printf '%s\n' "$assistant_text" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    && fail "OpenCode native later-message Ahoy gathered Bearings: $assistant_text"
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "OpenCode native later-message Ahoy reran session start"
  session_count=$(sqlite3 "$later_db" "select count(*) from $OC_SESSION_TABLE;")
  [ "$session_count" = 1 ] || fail "OpenCode native later-message Ahoy left the original session"
}

mkdir -p "$LAB"
run_ahoy_transcript_regressions
run_native_ahoy_regressions
git clone -q "$ROOT" "$PROJECT"
mkdir -p "$PROJECT/.opencode/plugins/lib"
cp "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" "$PROJECT/.opencode/plugins/fm-primary-watch-arm.js"
cp "$ROOT/.opencode/plugins/lib/fm-operational-input.js" "$PROJECT/.opencode/plugins/lib/fm-operational-input.js"
cp "$ROOT/.opencode/plugins/lib/fm-opencode2.js" "$PROJECT/.opencode/plugins/lib/fm-opencode2.js"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/opencode-e2e.meta"

# shellcheck disable=SC2016 # The model, not this test shell, expands FM_HOME.
PROMPT='Use the terminal to run `printf ready > "$FM_HOME/state/opencode-model-initial"`, then respond briefly. If a later watcher wake arrives, run bin/fm-wake-drain.sh, then run `printf handled > "$FM_HOME/state/opencode-model-handled"`. Never run or request any watcher arm command.'
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; \"$OPENCODE_BIN\" $OC_PRIVATE --auto; rc=\$?; printf \"OPENCODE_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

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

printf 'ok - OpenCode %s live E2E covered native Ahoy first/later messages, near misses, and watcher continuity\n' "$OPENCODE_VERSION"
