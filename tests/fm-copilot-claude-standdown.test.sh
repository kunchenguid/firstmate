#!/usr/bin/env bash
# Portable regression: the tracked Claude-shaped hook entrypoints stand down on
# a payload delivered by GitHub Copilot CLI and still run on a Claude payload.
# The payload shapes are sanitized recordings (docs/verification/copilot.md
# "Claude-shaped payloads"); no Copilot or Claude install is needed.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-claude-standdown)
trap fm_test_cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR PI_CODING_AGENT GROK_AGENT GROK_HOOK_EVENT

SID=00000000-0000-4000-8000-000000000000
TS=2026-01-01T00:00:00.000Z
CP_SESSION="{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\",\"timestamp\":\"$TS\",\"cwd\":\"/work/p\",\"source\":\"new\",\"initial_prompt\":\"hi\"}"
CP_PROMPT="{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"timestamp\":\"$TS\",\"cwd\":\"/work/p\",\"prompt\":\"hi\"}"
CP_STOP="{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"timestamp\":\"$TS\",\"cwd\":\"/work/p\",\"transcript_path\":\"/work/h/events.jsonl\",\"stop_reason\":\"end_turn\",\"stop_hook_active\":false}"
cp_pretool() {  # <tool> <json tool_input>
  printf '{"hook_event_name":"PreToolUse","session_id":"%s","timestamp":"%s","cwd":"/work/p","tool_name":"%s","tool_input":%s}' "$SID" "$TS" "$1" "$2"
}
CL_SESSION="{\"session_id\":\"$SID\",\"transcript_path\":\"/work/t.jsonl\",\"cwd\":\"/work/p\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
CL_STOP="{\"session_id\":\"$SID\",\"transcript_path\":\"/work/t.jsonl\",\"cwd\":\"/work/p\",\"prompt_id\":\"p1\",\"permission_mode\":\"default\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"
cl_pretool() {  # <tool> <json tool_input>
  printf '{"session_id":"%s","transcript_path":"/work/t.jsonl","cwd":"/work/p","prompt_id":"p1","permission_mode":"default","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":%s,"tool_use_id":"toolu_x"}' "$SID" "$1" "$2"
}

# shellcheck source=bin/fm-hook-host-lib.sh
. "$ROOT/bin/fm-hook-host-lib.sh"

test_predicate() {
  local p
  for p in "$CP_SESSION" "$CP_PROMPT" "$CP_STOP" "$(cp_pretool Bash '{"command":"ls"}')"; do
    fm_hook_payload_is_foreign_host "$p" || fail "Copilot payload not recognized: $p"
  done
  for p in "$CL_SESSION" "$CL_STOP" "$(cl_pretool Bash '{"command":"ls"}')" '' 'not json' '[]' '{"timestamp":"2026-01-01T00:00:00Z","prompt_id":"x"}' '{"timestamp":1700000000}'; do
    ! fm_hook_payload_is_foreign_host "$p" || fail "payload wrongly treated as foreign: $p"
  done
  pass "predicate: Copilot payloads are foreign, Claude and malformed payloads run"
}

test_predicate_drift() {
  local nots nostamp fakebin probe
  nots=$(printf '%s' "$CP_STOP" | jq -c 'del(.timestamp)')
  ! fm_hook_payload_is_foreign_host "$nots" || fail "control: a payload without timestamp must not match by payload alone"
  COPILOT_HOOK_DEPTH=1 fm_hook_payload_is_foreign_host "$nots" || fail "COPILOT_HOOK_DEPTH=1 must identify Copilot without a timestamp"
  COPILOT_HOOK_DEPTH=2 fm_hook_payload_is_foreign_host "$CL_STOP" || fail "COPILOT_HOOK_DEPTH=2 must identify Copilot"
  for nostamp in 0 00 '' abc -1 1x; do
    ! COPILOT_HOOK_DEPTH=$nostamp fm_hook_payload_is_foreign_host "$CL_STOP" || fail "COPILOT_HOOK_DEPTH='$nostamp' must not identify Copilot"
  done
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-drift")
  ln -s /bin/bash "$fakebin/copilot"
  ln -s /bin/bash "$fakebin/claude"
  # The hook runs one process below its parent; the trailing `:` keeps bash from exec-ing it away.
  probe='. "$1/bin/fm-hook-host-lib.sh"; fm_hook_payload_is_foreign_host "$2"; echo $?'
  [ "$("$fakebin/copilot" -c 'bash -c "$1" _ "$2" "$3"; :' _ "$probe" "$ROOT" "$nots")" = 0 ] \
    || fail "a hook whose parent is copilot must be identified without a timestamp"
  [ "$("$fakebin/claude" -c 'bash -c "$1" _ "$2" "$3"; :' _ "$probe" "$ROOT" "$CL_STOP")" = 1 ] \
    || fail "a hook whose parent is claude must run"
  pass "predicate: COPILOT_HOOK_DEPTH and a copilot parent identify Copilot despite a changed payload"
}

# A genuine primary checkout with this repo's bin and one task in flight.
HOME_DIR="$TMP_ROOT/primary"
mkdir -p "$HOME_DIR/state"
git init -q "$HOME_DIR"
: > "$HOME_DIR/AGENTS.md"
ln -s "$ROOT/bin" "$HOME_DIR/bin"
: > "$HOME_DIR/state/task1.meta"

run_entry() {  # <payload> <script> [args...] -> sets OUT and STATUS
  local payload=$1; shift
  OUT=$(printf '%s' "$payload" | env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" bash "$HOME_DIR/bin/$1" "${@:2}" 2>&1); STATUS=$?
}

test_turnend_guard() {
  run_entry "$CP_STOP" fm-turnend-guard.sh --claude
  [ "$STATUS" -eq 0 ] && [ -z "$OUT" ] || fail "turn-end guard did not stand down: $STATUS $OUT"
  run_entry "$CL_STOP" fm-turnend-guard.sh --claude
  [ "$STATUS" -eq 2 ] || fail "turn-end guard must still block a Claude Stop: $STATUS $OUT"
  pass "fm-turnend-guard: stands down on Copilot, blocks on Claude"
}

test_autoarm() {
  local d="$TMP_ROOT/arm" fakebin payload
  mkdir -p "$d/state"
  cp -R "$ROOT/bin" "$d/bin"
  git init -q "$d"; : > "$d/AGENTS.md"; : > "$d/state/task1.meta"
  printf '#!/usr/bin/env bash\necho ran >> "$FM_HOME/state/arm-ran"\nprintf "stale: fixture\\n"\n' > "$d/bin/fm-watch-arm.sh"
  chmod +x "$d/bin/fm-watch-arm.sh"
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin")
  ln -s /bin/bash "$fakebin/claude"
  for payload in "$CP_STOP" "$CL_STOP"; do
    # The trailing `:` keeps bash from exec-ing the hook over the fake claude, which the hook's ancestry walk must find.
    printf '%s' "$payload" | FM_HOME="$d" FM_ROOT_OVERRIDE="$d" "$fakebin/claude" -c '
      printf "%s\n" "$$" > "$FM_HOME/state/.lock"
      "$FM_HOME/bin/fm-claude-stop-autoarm.sh"; :' >/dev/null 2>&1
    if [ "$payload" = "$CP_STOP" ]; then
      [ ! -e "$d/state/arm-ran" ] || fail "auto-arm ran under a Copilot Stop payload"
    fi
  done
  [ -e "$d/state/arm-ran" ] || fail "auto-arm must still run for the Claude Stop payload (control)"
  pass "fm-claude-stop-autoarm: stands down on Copilot, runs on Claude"
}

test_sessionstart() {
  local d="$TMP_ROOT/ss"
  mkdir -p "$d/state"
  cp -R "$ROOT/bin" "$d/bin"
  printf '#!/usr/bin/env bash\necho DIGEST\n' > "$d/bin/fm-session-start.sh"
  git init -q "$d"; : > "$d/AGENTS.md"
  OUT=$(printf '%s' "$CP_SESSION" | env FM_HOME="$d" bash "$d/bin/fm-sessionstart-run.sh" 2>&1)
  [ -z "$OUT" ] || fail "session start ran for Copilot: $OUT"
  OUT=$(printf '%s' "$CL_SESSION" | env FM_HOME="$d" bash "$d/bin/fm-sessionstart-run.sh" 2>&1)
  case "$OUT" in *DIGEST*) ;; *) fail "session start must run for Claude, got: $OUT" ;; esac
  pass "fm-sessionstart-run: stands down on Copilot, runs on Claude"
}

test_pretool_guards() {
  local script tool input
  for script in "fm-arm-pretool-check.sh|Bash|{\"command\":\"bin/fm-watch-arm.sh &\"}" \
                "fm-cd-pretool-check.sh|Bash|{\"command\":\"cd projects/example\"}" \
                "fm-subagent-pretool-check.sh|Task|{}"; do
    IFS='|' read -r script tool input <<<"$script"
    run_entry "$(cp_pretool "$tool" "$input")" "$script" --claude
    [ "$STATUS" -eq 0 ] && [ -z "$OUT" ] || fail "$script did not stand down on Copilot: $STATUS $OUT"
    run_entry "$(cl_pretool "$tool" "$input")" "$script" --claude
    [ "$STATUS" -eq 2 ] || fail "$script must still deny the Claude payload: $STATUS $OUT"
  done
  pass "pretool guards: stand down on Copilot, still deny on Claude"
}

test_predicate
test_predicate_drift
test_turnend_guard
test_autoarm
test_sessionstart
test_pretool_guards
