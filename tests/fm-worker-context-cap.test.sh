#!/usr/bin/env bash
# Behavior tests for the Claude Stop and PreToolUse hooks that cap a ship or
# scout worker's context size.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAP="$ROOT/bin/fm-worker-context-cap.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-context-cap)
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"
ID=cap-t1

# prepare_case <name> - a fresh state, data, and config directory plus an empty
# transcript.
prepare_case() {
  CASE_DIR="$TMP_ROOT/cases/$1"
  CASE_STATE="$CASE_DIR/state"
  CASE_DATA="$CASE_DIR/data"
  CASE_CONFIG="$CASE_DIR/config"
  CASE_TRANSCRIPT="$CASE_DIR/transcript.jsonl"
  CASE_STATUS="$CASE_STATE/$ID.status"
  CASE_HANDOFF="$CASE_DATA/$ID/handoff.md"
  mkdir -p "$CASE_STATE" "$CASE_DATA/$ID" "$CASE_CONFIG"
  : > "$CASE_TRANSCRIPT"
}

# invoke_cap <mode> [extra args...] - the hook payload is on stdin. The exit
# status is the hook's.
invoke_cap() {
  local mode=$1
  shift
  : > "$OUT"
  : > "$ERR"
  "$CAP" "$mode" --id "$ID" --state "$CASE_STATE" --data "$CASE_DATA" \
    --config "$CASE_CONFIG" "$@" >"$OUT" 2>"$ERR"
}

write_usage() {
  jq -nc --argjson tokens "$1" \
    '{message:{usage:{input_tokens:$tokens,cache_read_input_tokens:0,cache_creation_input_tokens:0}}}' \
    >> "$CASE_TRANSCRIPT"
}

stop_payload() {
  printf '{"session_id":"s1","stop_hook_active":%s,"transcript_path":"%s"}\n' \
    "${1:-false}" "$CASE_TRANSCRIPT"
}

tool_payload() { # <tool_name> <tool_input json>
  jq -nc --arg transcript "$CASE_TRANSCRIPT" --arg tool "$1" --argjson input "$2" \
    '{session_id:"s1",transcript_path:$transcript,tool_name:$tool,tool_input:$input}'
}

bash_payload() { # <command>
  tool_payload Bash "$(jq -nc --arg command "$1" '{command:$command}')"
}

assert_silent() {
  local label=$1
  [ ! -s "$OUT" ] || fail "$label wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

assert_block() {
  local label=$1 needle=$2
  jq -e --arg needle "$needle" \
    '.decision == "block" and (.reason | contains($needle))' "$OUT" >/dev/null 2>&1 \
    || fail "$label did not block with '$needle': $(cat "$OUT") $(cat "$ERR")"
  [ ! -s "$ERR" ] || fail "$label wrote stderr: $(cat "$ERR")"
}

# expect_pretool <label> <allow|deny> <payload>
expect_pretool() {
  local label=$1 verdict=$2 body=$3 rc=0
  printf '%s\n' "$body" | invoke_cap pretool || rc=$?
  case "$verdict" in
    allow)
      [ "$rc" -eq 0 ] || fail "$label must be allowed, got exit $rc: $(cat "$ERR")"
      assert_silent "$label"
      ;;
    deny)
      [ "$rc" -eq 2 ] || fail "$label must be denied with exit 2, got $rc: $(cat "$OUT")"
      [ ! -s "$OUT" ] || fail "$label deny wrote stdout, which makes Claude ignore the deny: $(cat "$OUT")"
      jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
          and .hookSpecificOutput.permissionDecision == "deny"
          and (.systemMessage | contains("hard limit"))' "$ERR" >/dev/null 2>&1 \
        || fail "$label deny is not the Claude PreToolUse deny object: $(cat "$ERR")"
      ;;
  esac
}

test_context_read_uses_the_newest_usage_sum() {
  local rc=0
  prepare_case read
  printf 'soft=1000\n' > "$CASE_CONFIG/worker-context-cap"
  {
    jq -nc '{message:{usage:{input_tokens:5,cache_read_input_tokens:7000,cache_creation_input_tokens:20}}}'
    printf '%s\n' '{"type":"user","message":{"content":"no usage here"}}' 'not json'
    jq -nc '{message:{usage:{input_tokens:1,cache_read_input_tokens:1100,cache_creation_input_tokens:30}}}'
    printf '%s\n' '{"type":"user","message":{"content":"still no usage"}}'
  } >> "$CASE_TRANSCRIPT"
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "stop must exit 0, got $rc: $(cat "$ERR")"
  assert_block "newest usage" "context is 1131 tokens"
  pass "the context read sums input, cache read, and cache creation of the newest usage and skips other lines"
}

test_soft_ask_once_per_crossing() {
  local rc=0
  prepare_case soft
  printf '%s\n' '# note' 'soft=1000' 'hard=5000' > "$CASE_CONFIG/worker-context-cap"
  write_usage 999
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "below the soft limit must exit 0, got $rc"
  assert_silent "below the soft limit"

  write_usage 1000
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "soft crossing must exit 0, got $rc"
  assert_block "soft crossing" "context is 1000 tokens"
  jq -e --arg handoff "$CASE_HANDOFF" \
    '.reason | contains("soft limit of 1000") and contains($handoff) and contains("relaunch --note-file") and contains("cannot split")' \
    "$OUT" >/dev/null || fail "soft ask lacks the handoff path, launch line, or no-split branch: $(cat "$OUT")"
  jq -e '.fired.s1 == true' "$CASE_STATE/$ID.context-cap.json" >/dev/null \
    || fail "soft crossing did not record the session as asked"

  rc=0
  write_usage 1400
  stop_payload true | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "second stop above the line must exit 0, got $rc"
  assert_silent "second stop above the line, as a continuation"

  rc=0
  write_usage 700
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "stop between two-thirds and the line must exit 0, got $rc"
  assert_silent "reading above two-thirds of the line"
  jq -e '.fired.s1 == true' "$CASE_STATE/$ID.context-cap.json" >/dev/null \
    || fail "a reading above two-thirds re-armed the ask"

  rc=0
  write_usage 600
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "stop below two-thirds must exit 0, got $rc"
  assert_silent "reading below two-thirds of the line"
  jq -e '.fired | has("s1") | not' "$CASE_STATE/$ID.context-cap.json" >/dev/null \
    || fail "a reading below two-thirds left the session armed"

  rc=0
  write_usage 1200
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "re-armed crossing must exit 0, got $rc"
  assert_block "re-armed crossing" "context is 1200 tokens"
  pass "the soft ask fires once per crossing, a continuation does not repeat it, and only a fall below two-thirds re-arms it"
}

test_default_limits_apply_without_a_config_file() {
  local rc=0
  prepare_case defaults
  write_usage 199999
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "199999 tokens must exit 0, got $rc"
  assert_silent "199999 tokens"
  write_usage 200000
  stop_payload | invoke_cap stop || rc=$?
  assert_block "200000 tokens" "soft limit of 200000"

  write_usage 299999
  expect_pretool "299999 tokens" allow "$(bash_payload 'ls')"
  write_usage 300000
  expect_pretool "300000 tokens" deny "$(bash_payload 'ls')"
  pass "without a config file the soft limit is 200000 and the hard limit is 300000"
}

test_hard_limit_denies_every_tool_but_the_handoff_set() {
  prepare_case hard
  printf '%s\n' 'soft=1000' 'hard=2000' > "$CASE_CONFIG/worker-context-cap"
  write_usage 1999
  expect_pretool "below the hard limit" allow "$(bash_payload 'ls -la')"

  write_usage 2000
  expect_pretool "ordinary shell command" deny "$(bash_payload 'ls -la')"
  expect_pretool "Read" deny "$(tool_payload Read '{"file_path":"/etc/hosts"}')"
  expect_pretool "Task" deny "$(tool_payload Task '{"prompt":"x"}')"
  expect_pretool "Write elsewhere" deny "$(tool_payload Write "$(jq -nc --arg p "$CASE_DATA/$ID/other.md" '{file_path:$p,content:"x"}')")"
  expect_pretool "Write through a dot-dot path" deny "$(tool_payload Write "$(jq -nc --arg p "$CASE_DATA/$ID/../x/../$ID/handoff.md" '{file_path:$p,content:"x"}')")"

  expect_pretool "Write handoff" allow "$(tool_payload Write "$(jq -nc --arg p "$CASE_HANDOFF" '{file_path:$p,content:"x"}')")"
  expect_pretool "Edit handoff" allow "$(tool_payload Edit "$(jq -nc --arg p "$CASE_HANDOFF" '{file_path:$p,old_string:"a",new_string:"b"}')")"
  expect_pretool "MultiEdit handoff" allow "$(tool_payload MultiEdit "$(jq -nc --arg p "$CASE_HANDOFF" '{file_path:$p,edits:[]}')")"

  expect_pretool "git add" allow "$(bash_payload 'git add -A')"
  expect_pretool "git -C add" allow "$(bash_payload "git -C '/tmp/some wt' add -- bin/x.sh")"
  expect_pretool "git commit" allow "$(bash_payload "git commit -m 'fix(bin): hand off; a (quoted) message'")"
  expect_pretool "git -C commit, double quotes" allow "$(bash_payload 'git -C /tmp/wt commit -m "wip: split at the cap"')"

  expect_pretool "plain status append" allow \
    "$(bash_payload "echo \"paused [at=1700000000]: context handoff, note at $CASE_HANDOFF\" >> '$CASE_STATUS'")"
  expect_pretool "status append with the ledger suffix" allow \
    "$(bash_payload "echo \"working [at=1]: cannot split\" >> '$CASE_STATUS' && { [ ! -e '$CASE_CONFIG/fleet-ledger' ] || '$ROOT/bin/fm-fleet-ledger.sh' appended '$CASE_CONFIG' '$CASE_STATUS' >/dev/null 2>&1 || true; }")"
  pass "at the hard limit only git add, git commit, the handoff note, and the status append run"
}

test_deny_carries_a_usable_epoch_for_the_status_stamp() {
  local before after stamp
  prepare_case epoch
  printf '%s\n' 'soft=1000' 'hard=2000' > "$CASE_CONFIG/worker-context-cap"
  write_usage 2500
  before=$(date +%s)
  expect_pretool "date" deny "$(bash_payload 'date +%s')"
  after=$(date +%s)
  stamp=$(jq -r '.systemMessage' "$ERR" | sed -n 's/.*Use \([0-9][0-9]*\) as the \[at=<epoch>\].*/\1/p')
  [ -n "$stamp" ] || fail "the deny names no epoch: $(cat "$ERR")"
  [ "$stamp" -ge "$before" ] && [ "$stamp" -le "$after" ] \
    || fail "the deny epoch $stamp is outside $before..$after"
  pass "the hard deny hands the worker the current epoch, so the status stamp needs no date command"
}

test_status_append_accepts_a_symlinked_state_path() {
  local link
  prepare_case symlink
  printf '%s\n' 'soft=1000' 'hard=2000' > "$CASE_CONFIG/worker-context-cap"
  link="$CASE_DIR/state-link"
  ln -s "$CASE_STATE" "$link"
  write_usage 2500
  # The hook holds the physical state path; the brief spells it through the link.
  expect_pretool "status append through a symlinked state directory" allow \
    "$(bash_payload "echo \"paused [at=1]: handoff\" >> '$link/$ID.status'")"
  expect_pretool "status append with the ledger suffix through a symlink" allow \
    "$(bash_payload "echo \"paused [at=1]: handoff\" >> '$link/$ID.status' && { [ ! -e '$CASE_CONFIG/fleet-ledger' ] || '$ROOT/bin/fm-fleet-ledger.sh' appended '$CASE_CONFIG' '$link/$ID.status' >/dev/null 2>&1 || true; }")"
  mkdir -p "$CASE_DIR/other"
  expect_pretool "status append through a link to another directory" deny \
    "$(bash_payload "echo \"x\" >> '$CASE_DIR/other/$ID.status'")"
  pass "a status path spelled through a symlink to the state directory is allowed, another directory is not"
}

test_hard_limit_denies_chained_or_substituted_commands() {
  prepare_case chained
  printf '%s\n' 'soft=1000' 'hard=2000' > "$CASE_CONFIG/worker-context-cap"
  write_usage 2500
  expect_pretool "git push" deny "$(bash_payload 'git push origin HEAD')"
  expect_pretool "git status" deny "$(bash_payload 'git status')"
  expect_pretool "git -c option" deny "$(bash_payload 'git -c core.pager=x commit -m y')"
  expect_pretool "commit chained with &&" deny "$(bash_payload "git commit -m y && rm -rf /")"
  expect_pretool "commit chained with ;" deny "$(bash_payload "git commit -m y; rm -rf /")"
  expect_pretool "commit piped" deny "$(bash_payload "git commit -m y | sh")"
  expect_pretool "commit with a heredoc message" deny "$(bash_payload "git commit -m \"\$(cat <<'EOF'
msg
EOF
)\"")"
  # shellcheck disable=SC2016 # The substitution must reach the hook unexpanded.
  expect_pretool "commit with a substitution in double quotes" deny "$(bash_payload 'git commit -m "$(rm -rf x)"')"
  # shellcheck disable=SC2016 # The backtick must reach the hook unexpanded.
  expect_pretool "commit with a backtick in double quotes" deny "$(bash_payload 'git commit -m "`id`"')"
  expect_pretool "commit with an unquoted redirect" deny "$(bash_payload 'git commit -m y > /tmp/x')"
  expect_pretool "commit on a second line" deny "$(bash_payload "git commit -m y
rm -rf /")"
  expect_pretool "commit with an unclosed quote" deny "$(bash_payload "git commit -m 'y")"
  expect_pretool "status append to another file" deny \
    "$(bash_payload "echo \"x\" >> '$CASE_STATE/other.status'")"
  expect_pretool "status append with a substitution" deny \
    "$(bash_payload "echo \"\$(id)\" >> '$CASE_STATUS'")"
  expect_pretool "status append chained" deny \
    "$(bash_payload "echo \"x\" >> '$CASE_STATUS'; rm -rf /")"
  expect_pretool "status append with a foreign ledger script" deny \
    "$(bash_payload "echo \"x\" >> '$CASE_STATUS' && { [ ! -e '$CASE_CONFIG/fleet-ledger' ] || '/tmp/fm-fleet-ledger.sh' appended '$CASE_CONFIG' '$CASE_STATUS' >/dev/null 2>&1 || true; }")"
  pass "a chained, piped, redirected, or substituted command is denied even when it starts with an allowed one"
}

test_config_parsing_keeps_defaults_for_unusable_values() {
  local rc=0 file
  prepare_case config
  file="$CASE_CONFIG/worker-context-cap"

  # A usable hard limit applies, an unusable soft line keeps its default.
  printf '%s\n' 'soft=abc' 'soft=0' 'soft=-5' 'soft=1e3' 'soft=99999999999' 'hard=250000' 'bogus=1' 'nonsense' > "$file"
  write_usage 199999
  stop_payload | invoke_cap stop || rc=$?
  assert_silent "unusable soft lines"
  write_usage 200000
  stop_payload | invoke_cap stop || rc=$?
  assert_block "unusable soft lines keep 200000" "soft limit of 200000"
  write_usage 249999
  expect_pretool "below the configured hard limit" allow "$(bash_payload 'ls')"
  write_usage 250000
  expect_pretool "at the configured hard limit" deny "$(bash_payload 'ls')"

  # A soft limit at or above the hard limit makes both keep their defaults.
  printf '%s\n' 'soft=5000' 'hard=4000' > "$file"
  write_usage 250000
  expect_pretool "inverted limits keep the default hard limit" allow "$(bash_payload 'ls')"
  write_usage 300000
  expect_pretool "inverted limits at the default hard limit" deny "$(bash_payload 'ls')"

  # Only the literal value false turns the cap off.
  printf '%s\n' 'enabled=maybe' > "$file"
  write_usage 300000
  expect_pretool "an unusable enabled value keeps the cap on" deny "$(bash_payload 'ls')"
  printf '%s\n' 'enabled=false' > "$file"
  expect_pretool "enabled=false turns the hard limit off" allow "$(bash_payload 'ls')"
  rc=0
  rm -f "$CASE_STATE/$ID.context-cap.json"
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "enabled=false stop must exit 0, got $rc"
  assert_silent "enabled=false stop"
  [ ! -e "$CASE_STATE/$ID.context-cap.json" ] || fail "enabled=false wrote the state file"
  pass "an unusable limit keeps its default, inverted limits fall back to both defaults, and enabled=false turns the cap off"
}

test_bad_input_and_hook_errors_exit_zero_silently() {
  local rc=0 fakebin="$TMP_ROOT/no-jq-bin" entry name
  prepare_case failopen
  printf '%s\n' 'soft=1000' 'hard=2000' > "$CASE_CONFIG/worker-context-cap"
  write_usage 900000

  rc=0
  printf '%s' '{' | invoke_cap pretool || rc=$?
  [ "$rc" -eq 0 ] || fail "bad json must exit 0, got $rc"
  assert_silent "bad json"

  rc=0
  printf '%s' '' | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "empty payload must exit 0, got $rc"
  assert_silent "empty payload"

  rc=0
  printf '%s\n' "$(jq -nc --arg t "$CASE_TRANSCRIPT" '{cursor_version:"1.0",session_id:"s1",transcript_path:$t,tool_name:"Bash",tool_input:{command:"ls"}}')" \
    | invoke_cap pretool || rc=$?
  [ "$rc" -eq 0 ] || fail "cursor payload must exit 0, got $rc"
  assert_silent "cursor payload"

  rc=0
  printf '%s\n' '{"session_id":"s1","transcript_path":"/nonexistent/transcript.jsonl","tool_name":"Bash","tool_input":{"command":"ls"}}' \
    | invoke_cap pretool || rc=$?
  [ "$rc" -eq 0 ] || fail "missing transcript must exit 0, got $rc"
  assert_silent "missing transcript"

  rc=0
  printf '%s\n' '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}' | invoke_cap pretool || rc=$?
  [ "$rc" -eq 0 ] || fail "payload without a transcript path must exit 0, got $rc"
  assert_silent "payload without a transcript path"

  rc=0
  printf '%s\n' '{"session_id":"s1","transcript_path":"'"$CASE_TRANSCRIPT"'"}' | invoke_cap pretool || rc=$?
  [ "$rc" -eq 0 ] || fail "payload without a tool name must exit 0, got $rc"
  assert_silent "payload without a tool name"

  : > "$CASE_TRANSCRIPT"
  printf '%s\n' 'not json at all' '{"message":{"content":"no usage"}}' >> "$CASE_TRANSCRIPT"
  rc=0
  bash_payload ls | invoke_cap pretool || rc=$?
  [ "$rc" -eq 0 ] || fail "transcript without usage must exit 0, got $rc"
  assert_silent "transcript without usage"

  write_usage 900000
  chmod 000 "$CASE_TRANSCRIPT"
  if [ -r "$CASE_TRANSCRIPT" ]; then
    chmod 644 "$CASE_TRANSCRIPT"
  else
    rc=0
    bash_payload ls | invoke_cap pretool || rc=$?
    [ "$rc" -eq 0 ] || fail "unreadable transcript must exit 0, got $rc"
    assert_silent "unreadable transcript"
    chmod 644 "$CASE_TRANSCRIPT"
  fi

  rc=0
  bash_payload ls | "$CAP" pretool --id "$ID" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing arguments must exit 0, got $rc"
  assert_silent "missing arguments"

  rc=0
  rm -rf "$CASE_STATE"
  stop_payload | invoke_cap stop || rc=$?
  [ "$rc" -eq 0 ] || fail "an unwritable state directory must exit 0, got $rc"
  assert_silent "an unwritable state directory"
  mkdir -p "$CASE_STATE"

  mkdir -p "$fakebin"
  for entry in /bin/* /usr/bin/*; do
    [ -x "$entry" ] || continue
    name=${entry##*/}
    [ "$name" = jq ] && continue
    ln -s "$entry" "$fakebin/$name" 2>/dev/null || true
  done
  rm -f "$fakebin/jq"
  PATH="$fakebin" command -v dirname >/dev/null 2>&1 || fail "fixture PATH lost dirname"
  PATH="$fakebin" command -v jq >/dev/null 2>&1 && fail "fixture PATH still finds jq"
  rc=0
  bash_payload ls | PATH="$fakebin" "$CAP" pretool --id "$ID" --state "$CASE_STATE" \
    --data "$CASE_DATA" --config "$CASE_CONFIG" >"$OUT" 2>"$ERR" || rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must exit 0, got $rc: $(cat "$ERR")"
  assert_silent "missing jq"
  pass "bad json, an empty payload, a cursor payload, a missing or unreadable transcript, missing arguments, an unwritable state directory, and a missing jq all exit 0 silently"
}

fm_test_run \
  test_context_read_uses_the_newest_usage_sum \
  test_soft_ask_once_per_crossing \
  test_default_limits_apply_without_a_config_file \
  test_hard_limit_denies_every_tool_but_the_handoff_set \
  test_deny_carries_a_usable_epoch_for_the_status_stamp \
  test_status_append_accepts_a_symlinked_state_path \
  test_hard_limit_denies_chained_or_substituted_commands \
  test_config_parsing_keeps_defaults_for_unusable_values \
  test_bad_input_and_hook_errors_exit_zero_silently
