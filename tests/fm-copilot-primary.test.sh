#!/usr/bin/env bash
# Portable regression for GitHub Copilot CLI's native primary hooks:
# bin/fm-sessionstart-copilot.sh (sessionStart), bin/fm-pretool-copilot.sh
# (preToolUse), bin/fm-turnend-guard-copilot.sh (agentStop), and their tracked
# registration .github/hooks/firstmate-primary.json
# (docs/sessionstart-nudge.md "GitHub Copilot CLI", docs/verification/copilot.md).
# Payloads are sanitized recordings of copilot 1.0.105; no Copilot install is
# needed. tests/fm-copilot-harness.test.sh owns the worker launch itself.
# shellcheck disable=SC2016 # single quotes are deliberate: $COPILOT_PROJECT_DIR expands inside the registered command
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-copilot-primary)
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE CLAUDE_PROJECT_DIR PI_CODING_AGENT GROK_AGENT GROK_HOOK_EVENT FM_ALLOW_SUBAGENT COPILOT_PROJECT_DIR

REGISTRATION="$ROOT/.github/hooks/firstmate-primary.json"
SID=00000000-0000-4000-8000-000000000000
TS=1790000000000

session_payload() {  # <source>
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","source":"%s","initialPrompt":"hi"}' "$SID" "$TS" "$1"
}
tool_payload() {  # <tool> <json toolArgs> [extra json members, leading comma]
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","toolName":"%s","toolArgs":%s%s}' "$SID" "$TS" "$1" "$2" "${3:-}"
}
stop_payload() {  # [extra json members, leading comma]
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","stop_reason":"end_turn"%s}' "$SID" "$TS" "${1:-}"
}
SUB_MEMBERS=',"agentId":"a1","agentType":"task","parentAgentId":"00000000-0000-4000-8000-000000000001"'

install_scripts() {  # <dir>
  local dir=$1 f
  mkdir -p "$dir/bin" "$dir/docs" "$dir/.github/hooks"
  for f in fm-sessionstart-copilot.sh fm-pretool-copilot.sh fm-turnend-guard-copilot.sh fm-copilot-compact.sh \
           fm-turnend-guard.sh fm-copilot-wake.sh fm-sessionstart-run.sh \
           fm-sessionstart-nudge.sh fm-arm-pretool-check.sh fm-cd-pretool-check.sh \
           fm-subagent-pretool-check.sh fm-hook-host-lib.sh fm-primary-scope-lib.sh \
           fm-path-lib.sh fm-session-lock-lib.sh fm-operational-input.sh fm-harness.sh \
           fm-lock.sh fm-gate-refuse-lib.sh fm-timeout-lib.sh fm-supervision-lib.sh \
           fm-busy-lib.sh fm-cursor-lib.sh fm-wake-lib.sh fm-classify-lib.sh fm-afk-contract.sh fm-lease-lib.sh \
           fm-supervision-engine-lib.sh fm-supervision-instructions.sh; do
    cp "$ROOT/bin/$f" "$dir/bin/$f"
  done
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  cp "$REGISTRATION" "$dir/.github/hooks/firstmate-primary.json"
  chmod +x "$dir"/bin/*.sh
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/state/digest-args"
printf '%s\n' "${FM_COPILOT_HARNESS:-}" > "$FM_HOME/state/digest-harness"
printf 'FIRSTMATE DIGEST "quoted" line\nsecond line\n'
SH
  chmod +x "$dir/bin/fm-session-start.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_scripts "$dir"
  printf '%s\n' "$dir"
}

# make_worker_dir <base> <worktree>: a linked worktree of the primary, the shape
# bin/fm-spawn.sh hands every crewmate, carrying the same tracked files.
make_worker_dir() {
  local base=$1 child=$2
  fm_git_worktree "$base" "$child" fm/copilot-worker
  mkdir -p "$child/state"
  : > "$child/AGENTS.md"
  install_scripts "$child"
}

# registered_command <event>: the command string Copilot would run for <event>.
registered_command() {
  jq -r --arg e "$1" '.hooks[$e][-1].bash' "$REGISTRATION"
}

# run_registered <dir> <event> <payload>: run the tracked registration's own
# command string the way Copilot does, with COPILOT_PROJECT_DIR set.
run_registered() {
  local dir=$1 event=$2 payload=$3
  printf '%s' "$payload" | env COPILOT_HOOK_DEPTH=1 COPILOT_PROJECT_DIR="$dir" FM_HOME="$dir" bash -c "$(registered_command "$event")" 2>/dev/null
}

# --- session start -------------------------------------------------------------

test_sessionstart_emits_additional_context_for_a_new_session() {
  local dir out ctx
  dir=$(make_primary_dir "$TMP_ROOT/session-new")
  out=$(run_registered "$dir" sessionStart "$(session_payload new)")
  ctx=$(printf '%s' "$out" | jq -r '.additionalContext // empty' 2>/dev/null)
  case "$ctx" in *'FIRSTMATE DIGEST "quoted" line'*) ;; *) fail "the digest must reach model context verbatim, got: $out" ;; esac
  case "$ctx" in *'second line'*) ;; *) fail "the digest was truncated at the first line: $ctx" ;; esac
  printf '%s' "$out" | jq -e 'keys == ["additionalContext"]' >/dev/null || fail "the output must be exactly one additionalContext object: $out"
  [ "$(cat "$dir/state/digest-harness")" = copilot ] || fail "the digest must be told its harness, because its process chain is past the ancestry walk's bound"
  pass "fm-sessionstart-copilot: a new session gets the whole digest as additionalContext"
}

test_sessionstart_adds_the_chunked_read_note_for_copilot_only() {
  local dir out ctx raw
  dir=$(make_primary_dir "$TMP_ROOT/session-chunked")
  out=$(run_registered "$dir" sessionStart "$(session_payload new)")
  ctx=$(printf '%s' "$out" | jq -r '.additionalContext // empty' 2>/dev/null)
  case "$ctx" in *'AGENTS.md'*'view_range'*'do not stop after the first range'*) ;; *) fail "the Copilot digest must carry the chunked-read note: $out" ;; esac
  raw=$(FM_HOME="$dir" "$dir/bin/fm-sessionstart-run.sh" --source startup </dev/null 2>/dev/null)
  case "$raw" in *'FIRSTMATE DIGEST'*) ;; *) fail "the harness-neutral digest did not run: $raw" ;; esac
  case "$raw" in *view_range*) fail "a non-Copilot digest must not carry the Copilot note: $raw" ;; esac
  pass "fm-sessionstart-copilot: only the Copilot digest carries the chunked AGENTS.md read note"
}

test_sessionstart_routes_the_payload_source() {
  local dir out ctx
  dir=$(make_primary_dir "$TMP_ROOT/session-resume")
  out=$(run_registered "$dir" sessionStart "$(session_payload resume)")
  ctx=$(printf '%s' "$out" | jq -r '.additionalContext // empty' 2>/dev/null)
  case "$ctx" in *'FIRSTMATE DIGEST'*) ;; *) fail "a resumed session is a new process and must take the helm with the full digest: $out" ;; esac
  grep -q -- '--source startup' "$dir/state/digest-args" || fail "resume must reach the digest as a startup: $(cat "$dir/state/digest-args")"
  pass "fm-sessionstart-copilot: a resumed session gets the full digest, not a nudge"
}

test_sessionstart_unrecognized_source_gets_the_full_digest() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/session-odd")
  out=$(run_registered "$dir" sessionStart "$(session_payload somethingnew)")
  case "$out" in *'FIRSTMATE DIGEST'*) ;; *) fail "an unrecognized source must still take the helm: $out" ;; esac
  out=$(run_registered "$dir" sessionStart 'not json')
  case "$out" in *'FIRSTMATE DIGEST'*) ;; *) fail "an unreadable payload must still take the helm: $out" ;; esac
  pass "fm-sessionstart-copilot: unrecognized or unreadable payloads get the full digest"
}

test_sessionstart_warns_outside_the_verified_version_range() {
  local dir out fakebin v
  dir=$(make_primary_dir "$TMP_ROOT/session-version")
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-version")
  for v in 1.0.109 1.0.105; do
    printf '#!/usr/bin/env bash\necho "GitHub Copilot CLI %s."\n' "$v" > "$fakebin/copilot"; chmod +x "$fakebin/copilot"
    out=$(PATH="$fakebin:$PATH" run_registered "$dir" sessionStart "$(session_payload new)")
    case "$out" in *'warning: copilot version'*) fail "a verified version $v must not warn: $out" ;; esac
  done
  for v in 1.0.110 1.1.0 ''; do
    printf '#!/usr/bin/env bash\necho "GitHub Copilot CLI %s."\n' "$v" > "$fakebin/copilot"; chmod +x "$fakebin/copilot"
    out=$(PATH="$fakebin:$PATH" run_registered "$dir" sessionStart "$(session_payload new)")
    case "$(printf '%s' "$out" | jq -r '.additionalContext // empty')" in
      *'FIRSTMATE DIGEST'*'warning: copilot version'*'outside the verified range'*) ;;
      *) fail "version '$v' must add one warning line after the digest: $out" ;;
    esac
  done
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$fakebin/copilot"
  out=$(PATH="$fakebin:$PATH" run_registered "$dir" sessionStart "$(session_payload new)")
  case "$out" in *'copilot version unknown'*) ;; *) fail "a hung --version must be bounded and warn as unknown: $out" ;; esac
  pass "fm-sessionstart-copilot: warns when copilot --version is outside the verified range"
}

test_launcher_gives_a_plain_terminal_a_tmux_pane() {
  local d="$TMP_ROOT/launcher" fakebin out i
  command -v tmux >/dev/null 2>&1 || { pass "fm-copilot-primary launcher: skipped, tmux not found"; return 0; }
  mkdir -p "$d/tmux"
  fakebin=$(fm_fakebin "$TMP_ROOT/fakebin-launcher")
  printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s\\n" "${TMUX_PANE:-none}" "$PWD" "$*" > "$LAUNCH_OUT"\nsleep 5\n' > "$fakebin/copilot"
  chmod +x "$fakebin/copilot"
  # Inside a pane it runs copilot in place with the arguments.
  LAUNCH_OUT="$d/inplace" PATH="$fakebin:$PATH" TMUX_PANE=%9 FM_ROOT_OVERRIDE="$d" "$ROOT/bin/fm-copilot-primary.sh" --no-auto-update --allow-all >/dev/null 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/inplace" ] && break; sleep 0.3; done
  [ "$(cat "$d/inplace" 2>/dev/null)" = "%9|$d|--no-auto-update --allow-all -i Start the firstmate session." ] || fail "in-pane launch must run copilot here with its arguments: $(cat "$d/inplace" 2>/dev/null)"
  # From a plain terminal it opens a tmux pane, so TMUX_PANE is set for the wake.
  env -u TMUX -u TMUX_PANE LAUNCH_OUT="$d/plain" PATH="$fakebin:$PATH" TMUX_TMPDIR="$d/tmux" FM_ROOT_OVERRIDE="$d" \
    FM_COPILOT_PRIMARY_DETACH=1 "$ROOT/bin/fm-copilot-primary.sh" --no-auto-update >/dev/null 2>&1 || fail "plain-terminal launch failed"
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/plain" ] && break; sleep 0.3; done
  out=$(cat "$d/plain" 2>/dev/null)
  case "$out" in %*"|$d|--no-auto-update -i Start the firstmate session.") ;; *) fail "plain-terminal launch must run copilot in a tmux pane in the home: $out" ;; esac
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$d/tmux" tmux kill-server 2>/dev/null || true
  # A prompt the caller chose, or a help or version print, is left alone.
  rm -f "$d/inplace"
  LAUNCH_OUT="$d/inplace" PATH="$fakebin:$PATH" TMUX_PANE=%9 FM_ROOT_OVERRIDE="$d" "$ROOT/bin/fm-copilot-primary.sh" --resume=abc -i mine >/dev/null 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/inplace" ] && break; sleep 0.3; done
  [ "$(cat "$d/inplace" 2>/dev/null)" = "%9|$d|--no-auto-update --resume=abc -i mine" ] || fail "a caller's own -i must be kept and --no-auto-update added: $(cat "$d/inplace" 2>/dev/null)"
  # COPILOT_AUTO_UPDATE set by the caller suppresses the added flag.
  rm -f "$d/inplace"
  COPILOT_AUTO_UPDATE=true LAUNCH_OUT="$d/inplace" PATH="$fakebin:$PATH" TMUX_PANE=%9 FM_ROOT_OVERRIDE="$d" "$ROOT/bin/fm-copilot-primary.sh" -i mine >/dev/null 2>&1 &
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$d/inplace" ] && break; sleep 0.3; done
  [ "$(cat "$d/inplace" 2>/dev/null)" = "%9|$d|-i mine" ] || fail "COPILOT_AUTO_UPDATE must suppress --no-auto-update: $(cat "$d/inplace" 2>/dev/null)"
  pass "fm-copilot-primary launcher: runs in place inside a pane and opens a tmux pane from a plain terminal, adding -i unless the caller chose a prompt"
}

test_sessionstart_silent_in_a_worker_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/session-base")
  child="$TMP_ROOT/session-worker"
  make_worker_dir "$base" "$child"
  out=$(run_registered "$child" sessionStart "$(session_payload new)")
  [ -z "$out" ] || fail "a worker worktree must never take the helm: $out"
  [ ! -s "$child/state/digest-args" ] || fail "the digest ran in a worker worktree"
  pass "fm-sessionstart-copilot: silent inside a linked worker worktree"
}

# --- pre-tool deny ---------------------------------------------------------------

expect_deny() {  # <label> <output> <expected reason prefix>
  local label=$1 out=$2 code=$3
  printf '%s' "$out" | jq -e --arg c "$code" '
    .permissionDecision == "deny" and (.permissionDecisionReason | startswith($c)) and (keys | length == 2)
  ' >/dev/null 2>&1 || fail "$label: expected a Copilot deny starting $code, got: $out"
}

test_pretool_denies_with_a_visible_reason() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/pre-deny")
  out=$(run_registered "$dir" preToolUse "$(tool_payload bash '{"command":"cd projects/foo"}')")
  expect_deny "persistent cd" "$out" '[persistent-cd]'
  out=$(run_registered "$dir" preToolUse "$(tool_payload bash '{"command":"bin/fm-watch-arm.sh &"}')")
  expect_deny "backgrounded watcher arm" "$out" '['
  out=$(run_registered "$dir" preToolUse "$(tool_payload task '{"prompt":"x","agent_type":"task","mode":"sync"}')")
  expect_deny "subagent spawn" "$out" '[subagent-dispatch]'
  pass "fm-pretool-copilot: cd, watcher-arm, and subagent denies render as permissionDecisionReason"
}

test_pretool_exits_zero_on_deny() {
  local dir status
  dir=$(make_primary_dir "$TMP_ROOT/pre-exit")
  tool_payload bash '{"command":"cd projects/foo"}' | COPILOT_HOOK_DEPTH=1 "$dir/bin/fm-pretool-copilot.sh" >/dev/null 2>"$TMP_ROOT/pre-exit.err"; status=$?
  expect_code 0 "$status" "a deny must exit 0, because exit 2 hides the reason in Copilot"
  [ ! -s "$TMP_ROOT/pre-exit.err" ] || fail "a deny must leave stderr empty: $(cat "$TMP_ROOT/pre-exit.err")"
  pass "fm-pretool-copilot: a deny exits 0 with an empty stderr"
}

test_pretool_allows_ordinary_calls() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/pre-allow")
  for p in "$(tool_payload bash '{"command":"ls -la"}')" \
           "$(tool_payload bash '{"command":"(cd projects/foo && ls)"}')" \
           "$(tool_payload view '{"path":"/work/p/AGENTS.md"}')" \
           "$(tool_payload read_agent '{"agent_id":"a1"}')" \
           "$(tool_payload list_agents '{}')" \
           "$(tool_payload bash '{}')"; do
    out=$(run_registered "$dir" preToolUse "$p")
    [ -z "$out" ] || fail "an ordinary call was denied: $p -> $out"
  done
  pass "fm-pretool-copilot: ordinary shell, file, and agent-observing calls pass untouched"
}

test_pretool_skips_subagent_payloads_and_bad_input() {
  local dir out p
  dir=$(make_primary_dir "$TMP_ROOT/pre-skip")
  out=$(run_registered "$dir" preToolUse "$(tool_payload bash '{"command":"cd projects/foo"}' "$SUB_MEMBERS")")
  [ -z "$out" ] || fail "a subagent's own call must not be judged: $out"
  for p in '' 'not json' '[]' '{}' '{"toolName":7}'; do
    out=$(run_registered "$dir" preToolUse "$p")
    [ -z "$out" ] || fail "malformed input must allow, got: $out"
  done
  pass "fm-pretool-copilot: subagent-raised and malformed payloads are allowed"
}

test_pretool_honors_the_subagent_escape_hatch() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/pre-escape")
  out=$(tool_payload task '{"prompt":"x"}' | env FM_ALLOW_SUBAGENT=1 COPILOT_HOOK_DEPTH=1 COPILOT_PROJECT_DIR="$dir" FM_HOME="$dir" "$dir/bin/fm-pretool-copilot.sh")
  [ -z "$out" ] || fail "FM_ALLOW_SUBAGENT=1 must allow a deliberate subagent: $out"
  pass "fm-pretool-copilot: FM_ALLOW_SUBAGENT=1 is honored"
}

test_pretool_inert_in_a_worker_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/pre-base")
  child="$TMP_ROOT/pre-worker"
  make_worker_dir "$base" "$child"
  out=$(run_registered "$child" preToolUse "$(tool_payload bash '{"command":"cd projects/foo"}')")
  [ -z "$out" ] || fail "the cd seatbelt fired in a worker worktree: $out"
  out=$(run_registered "$child" preToolUse "$(tool_payload bash '{"command":"bin/fm-watch-arm.sh &"}')")
  [ -z "$out" ] || fail "the arm seatbelt fired in a worker worktree: $out"
  out=$(run_registered "$child" preToolUse "$(tool_payload task '{"prompt":"x"}')")
  [ -z "$out" ] || fail "the subagent guard fired in a worker worktree: $out"
  pass "fm-pretool-copilot: every check stands down in a linked worker worktree"
}

# --- turn-end guard --------------------------------------------------------------

test_turnend_blocks_once_when_work_is_unsupervised() {
  local dir out status reason
  dir=$(make_primary_dir "$TMP_ROOT/stop-block")
  : > "$dir/state/task1.meta"
  out=$(run_registered "$dir" agentStop "$(stop_payload)"); status=$?
  expect_code 0 "$status" "a block must exit 0, because exit 2 does not continue the turn in Copilot"
  printf '%s' "$out" | jq -e '.decision == "block" and (keys | length == 2)' >/dev/null 2>&1 \
    || fail "expected exactly one Copilot block object, got: $out"
  reason=$(printf '%s' "$out" | jq -r '.reason')
  case "$reason" in *'TURN WOULD END BLIND'*) ;; *) fail "the reason must carry the shared guard's banner: $reason" ;; esac
  [ "$(printf '%s' "$reason" | "$ROOT/bin/fm-operational-input.sh" kind)" = turn-end-guard ] \
    || fail "the reason must be a typed turn-end-guard input, so it never reads as the captain: $reason"
  out=$(run_registered "$dir" agentStop "$(stop_payload ',"stop_hook_active":true')")
  [ -z "$out" ] || fail "the stop after a block must end the turn, got: $out"
  pass "fm-turnend-guard-copilot: blocks an unsupervised stop once, and allows the stop that follows"
}

test_turnend_blocks_when_the_wake_process_is_dead() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/stop-wake")
  : > "$dir/state/task1.meta"
  # A shared guard that allows the stop stands in for a healthy orphan watcher.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/fm-turnend-guard.sh"
  out=$(run_registered "$dir" agentStop "$(stop_payload)")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 || fail "a dead wake process with work in flight must block: $out"
  case "$(printf '%s' "$out" | jq -r '.reason')" in *'bin/fm-copilot-wake.sh start'*) ;; *) fail "the reason must name the start command: $out" ;; esac
  out=$(run_registered "$dir" agentStop "$(stop_payload ',"stop_hook_active":true')")
  [ -z "$out" ] || fail "the stop after a block must end the turn: $out"
  mkdir -p "$dir/state/.copilot-wake.lock"
  printf '%s\n' "$$" > "$dir/state/.copilot-wake.lock/pid"
  out=$(run_registered "$dir" agentStop "$(stop_payload)")
  [ -z "$out" ] || fail "a live wake process must end the turn silently: $out"
  rm -rf "$dir/state/.copilot-wake.lock"
  : > "$dir/state/.afk"
  out=$(run_registered "$dir" agentStop "$(stop_payload)")
  [ -z "$out" ] || fail "away mode owns supervision and must not be blocked: $out"
  pass "fm-turnend-guard-copilot: a dead wake process blocks once even when a watcher is healthy"
}

test_turnend_allows_when_no_supervision_is_needed() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/stop-idle")
  out=$(run_registered "$dir" agentStop "$(stop_payload)")
  [ -z "$out" ] || fail "an empty fleet must end the turn silently, got: $out"
  pass "fm-turnend-guard-copilot: an empty fleet ends the turn silently"
}

test_turnend_skips_subagent_payloads_and_bad_input() {
  local dir out p
  dir=$(make_primary_dir "$TMP_ROOT/stop-skip")
  : > "$dir/state/task1.meta"
  out=$(run_registered "$dir" agentStop "$(stop_payload "$SUB_MEMBERS")")
  [ -z "$out" ] || fail "a subagent's own stop must not be blocked: $out"
  for p in '' 'not json' '[]' '{"stop_hook_active":"yes"}'; do
    out=$(run_registered "$dir" agentStop "$p")
    [ -z "$out" ] || fail "malformed input must allow, got: $p -> $out"
  done
  pass "fm-turnend-guard-copilot: subagent-raised and malformed payloads are allowed"
}

test_turnend_inert_in_a_worker_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/stop-base")
  child="$TMP_ROOT/stop-worker"
  make_worker_dir "$base" "$child"
  : > "$child/state/task1.meta"
  out=$(run_registered "$child" agentStop "$(stop_payload)")
  [ -z "$out" ] || fail "the guard fired in a worker worktree: $out"
  pass "fm-turnend-guard-copilot: stands down in a linked worker worktree"
}

# --- compaction re-emit ----------------------------------------------------------

prompt_payload() {  # [extra json members, leading comma]
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","prompt":"hi"%s}' "$SID" "$TS" "${1:-}"
}
compact_payload() {  # [extra json members, leading comma]
  printf '{"sessionId":"%s","timestamp":%s,"cwd":"/work/p","trigger":"manual","customInstructions":""%s}' "$SID" "$TS" "${1:-}"
}
DIGEST_MARK='FIRSTMATE DIGEST "quoted" line'

test_compact_marker_then_first_prompt_injects_once() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/compact-once")
  out=$(run_registered "$dir" preCompact "$(compact_payload)")
  [ -z "$out" ] || fail "preCompact output is discarded by Copilot, so the hook must print nothing: $out"
  [ -e "$dir/state/.copilot-compacted" ] || fail "preCompact must leave a marker"
  out=$(run_registered "$dir" userPromptSubmitted "$(prompt_payload)")
  printf '%s' "$out" | jq -e 'keys == ["additionalContext"]' >/dev/null 2>&1 || fail "the first prompt after a compaction must get exactly one additionalContext: $out"
  case "$(printf '%s' "$out" | jq -r .additionalContext)" in *"$DIGEST_MARK"*) ;; *) fail "the re-emit must carry the digest: $out" ;; esac
  grep -q -- '--source compact' "$dir/state/digest-args" 2>/dev/null || [ -s "$dir/state/digest-args" ] || fail "the run wrapper was not reached"
  [ ! -e "$dir/state/.copilot-compacted" ] || fail "delivery must clear the marker"
  out=$(run_registered "$dir" userPromptSubmitted "$(prompt_payload)")
  [ -z "$out" ] || fail "the second prompt must inject nothing: $out"
  out=$(run_registered "$dir" postToolUse "$(tool_payload bash '{"command":"ls"}')")
  [ -z "$out" ] || fail "a tool call after delivery must inject nothing: $out"
  pass "fm-copilot-compact: a marker set by preCompact injects the digest on the first prompt, once"
}

test_compact_marker_delivers_on_a_mid_turn_tool_call() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/compact-tool")
  run_registered "$dir" preCompact "$(compact_payload)" >/dev/null
  out=$(run_registered "$dir" postToolUse "$(tool_payload bash '{"command":"ls"}')")
  case "$(printf '%s' "$out" | jq -r '.additionalContext // empty' 2>/dev/null)" in *"$DIGEST_MARK"*) ;; *) fail "an automatic mid-turn compaction must deliver on the next tool result: $out" ;; esac
  out=$(run_registered "$dir" userPromptSubmitted "$(prompt_payload)")
  [ -z "$out" ] || fail "the prompt after a tool delivery must inject nothing: $out"
  pass "fm-copilot-compact: postToolUse delivers a mid-turn compaction once"
}

test_compact_without_a_marker_injects_nothing() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/compact-none")
  out=$(run_registered "$dir" userPromptSubmitted "$(prompt_payload)")
  [ -z "$out" ] || fail "no compaction, no injection: $out"
  [ ! -s "$dir/state/digest-args" ] || fail "the digest ran without a compaction"
  pass "fm-copilot-compact: no marker, no injection"
}

test_compact_marker_for_another_session_is_left_alone() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/compact-other")
  run_registered "$dir" preCompact "$(compact_payload)" >/dev/null
  out=$(run_registered "$dir" userPromptSubmitted "$(prompt_payload | jq -c '.sessionId="00000000-0000-4000-8000-0000000000ff"')")
  [ -z "$out" ] || fail "another session must not claim this session's marker: $out"
  [ -e "$dir/state/.copilot-compacted" ] || fail "the marker was consumed by another session"
  pass "fm-copilot-compact: a session id mismatch neither injects nor consumes the marker"
}

test_compact_skips_subagent_and_malformed_payloads() {
  local dir out p
  dir=$(make_primary_dir "$TMP_ROOT/compact-skip")
  run_registered "$dir" preCompact "$(compact_payload "$SUB_MEMBERS")" >/dev/null
  [ ! -e "$dir/state/.copilot-compacted" ] || fail "a subagent's own compaction must not mark the primary"
  run_registered "$dir" preCompact "$(compact_payload)" >/dev/null
  out=$(run_registered "$dir" userPromptSubmitted "$(prompt_payload "$SUB_MEMBERS")")
  [ -z "$out" ] || fail "a subagent must never receive the digest: $out"
  out=$(run_registered "$dir" postToolUse "$(tool_payload bash '{}' "$SUB_MEMBERS")")
  [ -z "$out" ] || fail "a subagent tool call must never receive the digest: $out"
  [ -e "$dir/state/.copilot-compacted" ] || fail "a subagent payload consumed the marker"
  for p in '' 'not json' '[]' '{}' '{"sessionId":7}'; do
    out=$(run_registered "$dir" userPromptSubmitted "$p")
    [ -z "$out" ] || fail "malformed input must inject nothing, got: $p -> $out"
  done
  [ -e "$dir/state/.copilot-compacted" ] || fail "malformed input consumed the marker"
  pass "fm-copilot-compact: subagent-raised and malformed payloads inject nothing and keep the marker"
}

test_compact_inert_in_a_worker_worktree() {
  local base child out
  base=$(make_primary_dir "$TMP_ROOT/compact-base")
  child="$TMP_ROOT/compact-worker"
  make_worker_dir "$base" "$child"
  run_registered "$child" preCompact "$(compact_payload)" >/dev/null
  [ ! -e "$child/state/.copilot-compacted" ] || fail "a worker worktree must not record a compaction"
  printf '%s\n' "$SID" > "$child/state/.copilot-compacted"
  out=$(run_registered "$child" userPromptSubmitted "$(prompt_payload)")
  [ -z "$out" ] || fail "a worker worktree must never receive the digest: $out"
  out=$(run_registered "$child" postToolUse "$(tool_payload bash '{}')")
  [ -z "$out" ] || fail "a worker worktree must never receive the digest on a tool call: $out"
  pass "fm-copilot-compact: stands down in a linked worker worktree"
}

test_compact_registration_commands() {
  [ "$(registered_command preCompact)" = '"$COPILOT_PROJECT_DIR"/bin/fm-copilot-compact.sh mark' ] || fail "preCompact must run the mark mode"
  [ "$(registered_command postToolUse)" = '"$COPILOT_PROJECT_DIR"/bin/fm-copilot-compact.sh deliver' ] || fail "postToolUse must run the deliver mode"
  jq -e '.hooks.userPromptSubmitted[-1].bash == "\"$COPILOT_PROJECT_DIR\"/bin/fm-copilot-compact.sh deliver"' "$REGISTRATION" >/dev/null \
    || fail "the delivery entry must be registered last on userPromptSubmitted, because only the last additionalContext reaches the model"
  jq -e '[.hooks.userPromptSubmitted[-1], .hooks.postToolUse[0]] | all(.timeoutSec > 120)' "$REGISTRATION" >/dev/null \
    || fail "delivery runs the digest, so its timeout must sit above the 120s digest budget"
  pass "copilot registration: preCompact marks, userPromptSubmitted (last) and postToolUse deliver"
}

# --- session lock ----------------------------------------------------------------

test_session_lock_recognizes_copilot() {
  (
    # shellcheck source=bin/fm-session-lock-lib.sh
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches MainThread 'copilot --allow-all' || fail "the Linux shape, comm MainThread and argv[0] copilot, must identify the session"
    fm_harness_process_matches /home/u/.local/bin/copilot 'copilot --allow-all' || fail "an installed Copilot path must identify the session"
    ! fm_harness_process_matches MainThread 'copilot-language-server --stdio' || fail "copilot-language-server must not identify a session"
    ! fm_harness_process_matches MainThread 'node server.js' || fail "an unrelated MainThread process must not identify a session"
  ) || exit 1
  pass "session lock: argv[0] copilot identifies a Copilot primary"
}

# --- registration ----------------------------------------------------------------

test_registration_covers_the_primary_events() {
  [ -f "$REGISTRATION" ] || fail "firstmate must ship a tracked project-scope .github/hooks/firstmate-primary.json"
  jq -e '.version == 1 and (.hooks | keys == ["agentStop","postToolUse","preCompact","preToolUse","sessionEnd","sessionStart","userPromptSubmitted"])' "$REGISTRATION" >/dev/null 2>&1 \
    || fail "the registration must cover exactly the session, tool, and turn boundary events"
  jq -e '.hooks.sessionStart[0].timeoutSec > 120' "$REGISTRATION" >/dev/null 2>&1 \
    || fail "the session-open timeout must sit above bin/fm-session-start.sh's own 120s budget"
  jq -e '[.hooks[][]] | all(.type == "command" and (.bash | startswith("\"$COPILOT_PROJECT_DIR\"/bin/")))' "$REGISTRATION" >/dev/null 2>&1 \
    || fail "every entry must anchor to COPILOT_PROJECT_DIR"
  pass "copilot registration: session, tool, and turn events, anchored to the project, session timeout above the digest budget"
}

test_worker_plugin_does_not_carry_the_primary_hooks() {
  local state out
  state="$TMP_ROOT/plugin-state"
  mkdir -p "$state"
  "$ROOT/bin/fm-copilot-plugin.sh" "$state" task1 gen1 >/dev/null 2>&1 \
    || fail "fm-copilot-plugin.sh did not write the worker plugin"
  out=$(cat "$state/task1.copilot-plugin/hooks/hooks.json")
  [ -n "$out" ] || fail "the worker plugin has no hooks file"
  case "$out" in *fm-sessionstart-copilot*|*fm-pretool-copilot*|*fm-turnend-guard-copilot*|*fm-copilot-wake*) fail "the worker plugin carries a primary hook: $out" ;; esac
  printf '%s' "$out" | jq -e '.hooks | (has("sessionStart") | not) and (has("preToolUse") | not)' >/dev/null 2>&1 \
    || fail "the worker plugin must not register sessionStart or preToolUse: $out"
  pass "copilot worker plugin: carries no sessionStart or preToolUse hook"
}

# --- secondmate home ---------------------------------------------------------------

# make_mate_dir <base> <home>: the same linked-worktree shape as a worker, but
# carrying the .fm-secondmate-home marker bin/fm-home-seed.sh publishes, which is
# what makes a persistent secondmate a primary session in its own home.
make_mate_dir() {
  local base=$1 mate=$2
  make_worker_dir "$base" "$mate"
  printf 'copilot-mate\n' > "$mate/.fm-secondmate-home"
}

test_secondmate_home_runs_all_three_adapters() {
  local base mate out
  base=$(make_primary_dir "$TMP_ROOT/mate-base")
  mate="$TMP_ROOT/mate-home"
  make_mate_dir "$base" "$mate"
  out=$(run_registered "$mate" sessionStart "$(session_payload new)")
  case "$out" in *'FIRSTMATE DIGEST'*) ;; *) fail "a secondmate home must get the digest: $out" ;; esac
  [ -s "$mate/state/digest-args" ] || fail "the digest did not run inside the secondmate home"
  [ ! -s "$base/state/digest-args" ] || fail "the secondmate's digest ran against the parent's home"
  : > "$mate/state/task1.meta"
  out=$(run_registered "$mate" agentStop "$(stop_payload)")
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 || fail "a secondmate with work in flight and no watcher must be blocked once: $out"
  pass "copilot secondmate home: digest, seatbelts, and turn-end guard run scoped to the home"
}

test_secondmate_home_busy_records_stay_apart() {
  local base mate gen
  base=$(make_primary_dir "$TMP_ROOT/mate-busy-base")
  mate="$TMP_ROOT/mate-busy-home"
  make_mate_dir "$base" "$mate"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$base/state" copilot-mate)
  "$ROOT/bin/fm-copilot-plugin.sh" "$base/state" copilot-mate "$gen" "$mate" || fail 'plugin writer failed for a secondmate'
  printf '{"sessionId":"s","timestamp":%s,"prompt":"hi"}' "$TS" \
    | env COPILOT_PROJECT_DIR="$mate" FM_HOME="$mate" bash -c "$(jq -r '.hooks.userPromptSubmitted[0].bash' "$base/state/copilot-mate.copilot-plugin/hooks/hooks.json")"
  grep -q 'state=busy' "$base/state/copilot-mate.busy-state" || fail "the per-task plugin did not publish the mate's busy turn to the parent's state"
  [ ! -e "$mate/state/copilot-mate.busy-state" ] || fail "the plugin wrote the parent's record into the mate's own state"
  pass "copilot secondmate: the parent-side busy record comes from the per-task plugin, apart from the home's own turn record"
}

test_sessionstart_emits_additional_context_for_a_new_session
test_sessionstart_adds_the_chunked_read_note_for_copilot_only
test_sessionstart_routes_the_payload_source
test_sessionstart_unrecognized_source_gets_the_full_digest
test_sessionstart_warns_outside_the_verified_version_range
test_launcher_gives_a_plain_terminal_a_tmux_pane
test_sessionstart_silent_in_a_worker_worktree
test_pretool_denies_with_a_visible_reason
test_pretool_exits_zero_on_deny
test_pretool_allows_ordinary_calls
test_pretool_skips_subagent_payloads_and_bad_input
test_pretool_honors_the_subagent_escape_hatch
test_pretool_inert_in_a_worker_worktree
test_turnend_blocks_once_when_work_is_unsupervised
test_turnend_blocks_when_the_wake_process_is_dead
test_turnend_allows_when_no_supervision_is_needed
test_turnend_skips_subagent_payloads_and_bad_input
test_turnend_inert_in_a_worker_worktree
test_session_lock_recognizes_copilot
test_registration_covers_the_primary_events
test_worker_plugin_does_not_carry_the_primary_hooks
test_secondmate_home_runs_all_three_adapters
test_secondmate_home_busy_records_stay_apart
test_compact_marker_then_first_prompt_injects_once
test_compact_marker_delivers_on_a_mid_turn_tool_call
test_compact_without_a_marker_injects_nothing
test_compact_marker_for_another_session_is_left_alone
test_compact_skips_subagent_and_malformed_payloads
test_compact_inert_in_a_worker_worktree
test_compact_registration_commands
