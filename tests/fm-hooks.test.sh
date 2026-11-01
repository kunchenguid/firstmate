#!/usr/bin/env bash
# Behavior tests for the lifecycle hook runner (bin/fm-hooks.sh), its call-site
# helpers (bin/fm-hooks-lib.sh), and the wake-drain intake and pr-merge
# pre-merge call sites (docs/configuration.md "Lifecycle hooks"). The spawn,
# turn-end, and session-start call sites are covered beside their own suites.
#
# Pinned here: no hook folder means nothing runs, nothing is read, and the
# runner is never started; hooks run in order with the payload on stdin;
# blocking events refuse at the first failure or timeout with the hook's
# reason; a slow or failing hook of a non-blocking event times out and the
# rest still run; session-start stdout passes through; pre-spawn and intake
# output merge into one JSON object by the documented rule; the dialog
# events prompt-submit and stop are mirrored with digests only unless text is
# allowed, and their Claude call point (bin/fm-dialog-hooks.sh, through the
# tracked .claude/settings.json registrations) never blocks, prints, or runs
# outside a primary checkout.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

HOOKS="$ROOT/bin/fm-hooks.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-hooks)
# Every case names its own home; never let an operator shell's home leak in.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
unset FM_HOOKS_EXTRA_DIR FM_HOOK_LOG FM_HOOK_TIMEOUT

new_home() {  # <name>: prints a fresh home directory
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# hook <folder> <name> <body> [mode]: write one sh hook.
hook() {
  mkdir -p "$1"
  printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"
  chmod "${4:-755}" "$1/$2"
}

# trace_hook <folder> <name> <trace> [extra-body]: a hook that logs its name,
# event, and args, then runs the extra body.
trace_hook() {
  hook "$1" "$2" "echo \"$2 \$FM_HOOK_EVENT \$*\" >> '$3'
${4:-}"
}

run_hooks() {  # <home> <event> <payload> [args...]: runner with stdout+stderr split
  local home=$1 event=$2 payload=$3
  shift 3
  printf '%s' "$payload" | FM_HOME="$home" "$HOOKS" run "$event" "$@" 2>"$CASE_ERR"
}

test_no_hooks_is_a_silent_no_op() {
  local home out rc
  home=$(new_home no-hooks)
  CASE_ERR="$TMP_ROOT/no-hooks/err"
  for event in session-start intake pre-spawn post-spawn watch-tick turn-end pre-merge post-merge teardown heartbeat \
    prompt-submit stop; do
    out=$(run_hooks "$home" "$event" '{"task_id":"t-1"}'); rc=$?
    expect_code 0 "$rc" "$event with no hooks"
    assert_equals '' "$out$(cat "$CASE_ERR")" "$event with no hooks printed something"
  done
  mkdir -p "$home/hooks/pre-spawn.d"
  out=$(run_hooks "$home" pre-spawn '{}'); rc=$?
  expect_code 0 "$rc" "an empty hook folder"
  assert_equals '' "$out" "an empty hook folder printed something"
  # The runner must not consume the caller's stdin when nothing is installed.
  out=$(printf 'kept\n' | { FM_HOME="$home" "$HOOKS" run teardown; cat; })
  assert_equals 'kept' "$out" "the runner read stdin with no hooks installed"
  pass "no hooks: every event is silent, exits 0, and leaves stdin unread"
}

test_emit_never_starts_the_runner_without_a_folder() {
  local home fake out
  home=$(new_home emit-cost)
  fake="$TMP_ROOT/emit-cost/fake-bin"
  mkdir -p "$fake"
  printf '#!/bin/sh\necho started >> "%s/started"\ncat >/dev/null\n' "$fake" > "$fake/fm-hooks.sh"
  chmod +x "$fake/fm-hooks.sh"
  out=$(FM_HOME="$home" FM_HOOKS_LIB_DIR="$fake" bash -c '
    . "$1"
    fm_hooks_present teardown && echo present
    fm_hooks_emit teardown task_id=t-1 || echo "emit failed"
  ' _ "$ROOT/bin/fm-hooks-lib.sh")
  assert_equals '' "$out" "emit with no folder printed or failed"
  assert_absent "$fake/started" "emit started the runner with no hook folder"
  mkdir -p "$home/hooks/teardown.d"
  FM_HOME="$home" FM_HOOKS_LIB_DIR="$fake" bash -c '. "$1"; fm_hooks_emit teardown task_id=t-1' _ "$ROOT/bin/fm-hooks-lib.sh"
  assert_present "$fake/started" "emit did not start the runner once the folder exists"
  pass "fm_hooks_emit costs one directory test and starts nothing when no folder exists"
}

test_payload_builder_escapes_values() {
  local out
  out=$(bash -c '. "$1"; fm_hooks_payload a=plain "q=say \"hi\"
next	tab \\ back" n:=3 ok:=true "e=" "skip"' _ "$ROOT/bin/fm-hooks-lib.sh")
  printf '%s' "$out" | jq -e '
    .a == "plain" and .q == "say \"hi\"\nnext\ttab \\ back" and .n == 3 and .ok == true and .e == ""
    and (keys | length) == 5
  ' >/dev/null || fail "payload did not round-trip through jq: $out"
  out=$(bash -c '. "$1"; fm_hooks_payload "c=$(printf "bell\001end")"' _ "$ROOT/bin/fm-hooks-lib.sh")
  printf '%s' "$out" | jq -e '.c == "bell\u0001end"' >/dev/null || fail "control byte was not escaped: $out"
  pass "payload fields are escaped into valid JSON, raw literals pass through"
}

test_order_payload_args_and_skips() {
  local home extra trace out rc
  home=$(new_home order)
  extra="$TMP_ROOT/order/extra"
  trace="$TMP_ROOT/order/trace"
  CASE_ERR="$TMP_ROOT/order/err"
  trace_hook "$extra/watch-tick.d" 05-extra "$trace"
  trace_hook "$home/hooks/watch-tick.d" 20-b "$trace"
  trace_hook "$home/hooks/watch-tick.d" 10-a "$trace"
  trace_hook "$home/hooks/watch-tick.d" 9-z "$trace"
  hook "$home/hooks/watch-tick.d" 30-not-executable 'exit 1' 644
  hook "$home/hooks/watch-tick.d" .hidden 'exit 1'
  hook "$home/hooks/watch-tick.d" 40-backup~ 'exit 1'
  out=$(printf '{"cycle":1}' | FM_HOME="$home" FM_HOOKS_EXTRA_DIR="$extra" "$HOOKS" run watch-tick arg1 2>"$CASE_ERR"); rc=$?
  expect_code 0 "$rc" "ordered run: $(cat "$CASE_ERR")"
  assert_equals $'10-a watch-tick arg1\n20-b watch-tick arg1\n9-z watch-tick arg1\n05-extra watch-tick arg1' \
    "$(cat "$trace")" "hooks ran out of order or skipped files ran"
  rm -f "$trace"
  FM_HOME="$home" FM_HOOKS_EXTRA_DIR="$home/hooks" "$HOOKS" run watch-tick </dev/null
  assert_equals 3 "$(wc -l < "$trace" | tr -d ' ')" "the same folder named twice ran its hooks twice"
  hook "$home/hooks/post-spawn.d" 10-cat "cat > '$TMP_ROOT/order/payload'; printf '%s' \"\$FM_HOME\" > '$TMP_ROOT/order/home-seen'"
  run_hooks "$home" post-spawn '{"task_id":"t-1"}' >/dev/null
  assert_equals '{"task_id":"t-1"}' "$(cat "$TMP_ROOT/order/payload")" "the payload did not reach stdin"
  assert_equals "$home" "$(cat "$TMP_ROOT/order/home-seen")" "FM_HOME did not reach the hook"
  FM_HOME="$home" "$HOOKS" run post-spawn </dev/null
  assert_equals '{}' "$(cat "$TMP_ROOT/order/payload")" "an empty stdin was not the payload {}"
  out=$(FM_HOME="$home" FM_HOOKS_EXTRA_DIR="$extra" "$HOOKS" list watch-tick)
  assert_equals "$(printf '%s\n' "$home/hooks/watch-tick.d/10-a" "$home/hooks/watch-tick.d/20-b" "$home/hooks/watch-tick.d/9-z" "$extra/watch-tick.d/05-extra")" \
    "$out" "list did not print the run order"
  pass "hooks run home folder first, then the extra folder, in byte order with payload, FM_HOME, and args"
}

test_blocking_events_stop_at_first_refusal() {
  local home trace out rc event
  for event in pre-spawn turn-end pre-merge; do
    home=$(new_home "block-$event")
    trace="$TMP_ROOT/block-$event/trace"
    CASE_ERR="$TMP_ROOT/block-$event/err"
    trace_hook "$home/hooks/$event.d" 10-ok "$trace"
    trace_hook "$home/hooks/$event.d" 20-refuse "$trace" "echo 'no task id for this spawn' >&2; exit 1"
    trace_hook "$home/hooks/$event.d" 30-never "$trace"
    out=$(run_hooks "$home" "$event" '{}'); rc=$?
    expect_code 3 "$rc" "$event refusal"
    assert_contains "$(cat "$CASE_ERR")" 'no task id for this spawn' "$event refusal lost the hook's reason"
    assert_equals $'10-ok\n20-refuse' "$(cut -d' ' -f1 "$trace")" "$event ran a hook after the refusal"
    hook "$home/hooks/$event.d" 20-refuse 'exit 4'
    run_hooks "$home" "$event" '{}' >/dev/null; rc=$?
    expect_code 3 "$rc" "$event silent refusal"
    assert_contains "$(cat "$CASE_ERR")" '20-refuse exited 4' "$event silent refusal is not named"
  done
  pass "pre-spawn, turn-end, and pre-merge refuse at the first failing hook with its reason"
}

test_blocking_timeout_refuses_within_the_bound() {
  local home trace start elapsed rc
  home=$(new_home block-timeout)
  trace="$TMP_ROOT/block-timeout/trace"
  CASE_ERR="$TMP_ROOT/block-timeout/err"
  hook "$home/hooks/pre-merge.d" 10-slow 'exec sleep 30'
  trace_hook "$home/hooks/pre-merge.d" 20-never "$trace"
  start=$(date +%s)
  printf '{}' | FM_HOOK_TIMEOUT=1 FM_HOME="$home" "$HOOKS" run pre-merge 2>"$CASE_ERR"; rc=$?
  elapsed=$(( $(date +%s) - start ))
  expect_code 3 "$rc" "a slow blocking hook"
  [ "$elapsed" -lt 8 ] || fail "a slow blocking hook held the runner for ${elapsed}s"
  assert_contains "$(cat "$CASE_ERR")" '10-slow timed out after 1s' "the timeout reason is missing"
  assert_absent "$trace" "a hook after the timed-out one ran"
  pass "a blocking hook that times out refuses within its bound"
}

test_slow_and_failing_non_blocking_hooks_do_not_block() {
  local home trace log start elapsed rc out event
  for event in post-spawn watch-tick post-merge teardown heartbeat; do
    home=$(new_home "nonblock-$event")
    trace="$TMP_ROOT/nonblock-$event/trace"
    log="$TMP_ROOT/nonblock-$event/hooks.log"
    CASE_ERR="$TMP_ROOT/nonblock-$event/err"
    hook "$home/hooks/$event.d" 10-fail 'echo broken >&2; exit 7'
    hook "$home/hooks/$event.d" 20-slow 'exec sleep 30'
    trace_hook "$home/hooks/$event.d" 30-runs "$trace" 'echo chatty'
    start=$(date +%s)
    out=$(printf '{}' | FM_HOOK_TIMEOUT=1 FM_HOOK_LOG="$log" FM_HOME="$home" "$HOOKS" run "$event" 2>"$CASE_ERR"); rc=$?
    elapsed=$(( $(date +%s) - start ))
    expect_code 0 "$rc" "$event with a failing and a slow hook"
    [ "$elapsed" -lt 8 ] || fail "$event: a slow hook held the run for ${elapsed}s"
    assert_equals '30-runs' "$(cut -d' ' -f1 "$trace")" "$event: the hook after the failures did not run"
    assert_equals '' "$out" "$event: stdout of a non-collecting event leaked"
    assert_contains "$(cat "$CASE_ERR")" "$event: 10-fail exited 7 (ignored): broken" "$event: failure not reported"
    assert_contains "$(cat "$CASE_ERR")" "$event: 20-slow timed out after 1s (ignored)" "$event: timeout not reported"
    assert_equals 2 "$(wc -l < "$log" | tr -d ' ')" "$event: FM_HOOK_LOG did not get both failures"
  done
  pass "a failing or slow hook of a non-blocking event is logged, times out, and the rest still run"
}

test_session_start_passes_stdout_and_intake_merges() {
  local home out
  home=$(new_home collect)
  CASE_ERR="$TMP_ROOT/collect/err"
  hook "$home/hooks/session-start.d" 10-a 'echo first'
  hook "$home/hooks/session-start.d" 20-b 'echo second; exit 1'
  out=$(run_hooks "$home" session-start '{"home":"x"}')
  assert_equals $'first\nsecond' "$out" "session-start stdout was not passed through in order"
  hook "$home/hooks/intake.d" 10-node 'echo "{\"node\":\"node:n1\"}"'
  hook "$home/hooks/intake.d" 20-note 'echo "{\"note\":\"sorted\"}"; exit 1'
  out=$(run_hooks "$home" intake '{}')
  assert_equals '{"node":"node:n1","note":"sorted"}' "$out" "intake output did not merge into one object"
  pass "session-start stdout passes through and intake output merges, failing hooks included"
}

test_pre_spawn_output_merge_rule() {
  local home out rc err
  home=$(new_home merge)
  CASE_ERR="$TMP_ROOT/merge/err"
  hook "$home/hooks/pre-spawn.d" 10-team 'cat >/dev/null; echo "{\"account\":\"first\",\"seat\":{\"id\":\"s1\"}}"'
  hook "$home/hooks/pre-spawn.d" 20-quiet 'exit 0'
  hook "$home/hooks/pre-spawn.d" 30-other 'printf "  {\"account\": \"second\", \"seat\": {\"pool\": \"p\"}}\n{\"nice\": 7}\n"'
  out=$(run_hooks "$home" pre-spawn '{"task_id":"t-1"}'); rc=$?
  err=$(cat "$CASE_ERR")
  expect_code 0 "$rc" "merged pre-spawn output: $err"
  printf '%s' "$out" | jq -e '. == {"account":"first","seat":{"id":"s1","pool":"p"},"nice":7}' >/dev/null \
    || fail "pre-spawn objects did not merge recursively with the first value kept: $out"
  assert_contains "$err" 'pre-spawn: conflict on account: kept 10-team, ignored 30-other' "the conflict is not reported"
  assert_not_contains "$err" 'second' "a conflict report named a value"
  out=$(FM_HOOK_MERGE_CONFLICT=refuse run_hooks "$home" pre-spawn '{}'); rc=$?
  expect_code 3 "$rc" "a conflict with FM_HOOK_MERGE_CONFLICT=refuse"
  assert_equals '' "$out" "a refused merge still printed output"
  assert_contains "$(cat "$CASE_ERR")" 'pre-spawn: conflict on account: kept 10-team, ignored 30-other' "the refusal lost its reason"
  hook "$home/hooks/pre-spawn.d" 25-noise 'echo "not json"'
  hook "$home/hooks/pre-spawn.d" 26-array 'echo "[1]"'
  rm -f "$home/hooks/pre-spawn.d/30-other"
  out=$(run_hooks "$home" pre-spawn '{}'); rc=$?
  expect_code 0 "$rc" "output that is not JSON objects is ignored"
  assert_equals '{"account":"first","seat":{"id":"s1"}}' "$out" "ignored output changed the merged object"
  assert_contains "$(cat "$CASE_ERR")" '25-noise printed output that is not a JSON object (ignored)' "ignored output is not reported"
  assert_contains "$(cat "$CASE_ERR")" '26-array printed output that is not a JSON object (ignored)' "an ignored array is not reported"
  out=$(FM_HOOKS_JQ="$TMP_ROOT/no-such-jq" run_hooks "$home" pre-spawn '{}'); rc=$?
  expect_code 0 "$rc" "merge without jq"
  assert_equals '{"account":"first","seat":{"id":"s1"}}' "$out" "without jq the first hook's output did not pass through"
  assert_contains "$(cat "$CASE_ERR")" 'jq not found, kept the output of 10-team, ignored 25-noise' "the jq fallback is not reported"
  rm -f "$home/hooks/pre-spawn.d/10-team" "$home/hooks/pre-spawn.d/25-noise" "$home/hooks/pre-spawn.d/26-array"
  out=$(run_hooks "$home" pre-spawn '{}'); rc=$?
  expect_code 0 "$rc" "silent pre-spawn hooks"
  assert_equals '' "$out" "silent pre-spawn hooks printed an object"
  pass "pre-spawn output merges recursively, keeps the first value, and reports or refuses conflicts"
}

test_mirror_records_digests_only() {
  local home mirror
  home=$(new_home mirror)
  mirror="$TMP_ROOT/mirror/runs.jsonl"
  CASE_ERR="$TMP_ROOT/mirror/err"
  hook "$home/hooks/pre-spawn.d" 10-team 'echo "{\"account\":\"secret-name\"}"'
  printf '{"task_id":"private-task"}' | FM_HOOK_MIRROR="$mirror" FM_HOME="$home" "$HOOKS" run pre-spawn >/dev/null 2>"$CASE_ERR"
  FM_HOOK_MIRROR="$mirror" FM_HOME="$home" "$HOOKS" run teardown </dev/null
  assert_equals 1 "$(wc -l < "$mirror" | tr -d ' ')" "the mirror recorded a run that ran no hook"
  jq -e '.runner == "fm-hooks.sh" and .event == "pre-spawn" and .refused == false
    and (.payload_sha256 | length) == 64 and .payload_bytes == 26 and (.output_sha256 | length) == 64
    and .hooks[0].hook == "10-team" and .hooks[0].exit == 0 and .hooks[0].timed_out == false' "$mirror" >/dev/null \
    || fail "mirror line is wrong: $(cat "$mirror")"
  assert_no_grep 'secret-name' "$mirror" "the mirror wrote hook output"
  assert_no_grep 'private-task' "$mirror" "the mirror wrote the payload"
  pass "FM_HOOK_MIRROR records one digest-only line per run that ran a hook"
}

sha256_text() {  # <text>: its sha256 hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}

test_dialog_events_mirror_digests_unless_text_is_allowed() {
  local home mirror prompt said line out rc
  home=$(new_home dialog)
  mirror="$TMP_ROOT/dialog/runs.jsonl"
  CASE_ERR="$TMP_ROOT/dialog/err"
  prompt=$'Ship the private fix, then report\n'
  jq -cn --arg p "$prompt" '{session_id: "sess-1", prompt_id: "p-7", prompt: $p}' \
    | FM_HOOK_MIRROR="$mirror" FM_HOME="$home" "$HOOKS" run prompt-submit >/dev/null 2>"$CASE_ERR"
  expect_code 0 $? "prompt-submit with no hooks"
  hook "$home/hooks/stop.d" 10-fails 'echo noise; exit 4'
  said=$(printf 'the private answer %.0s' $(seq 1 300))
  out=$(jq -cn --arg t "$said" '{session_id: "sess-1", last_assistant_message: $t}' \
    | FM_HOOK_MIRROR="$mirror" FM_HOME="$home" "$HOOKS" run stop 2>"$CASE_ERR"); rc=$?
  expect_code 0 "$rc" "a failing stop hook must not block"
  assert_equals '' "$out" "a stop hook's stdout was passed through"
  printf 'not json' | FM_HOOK_MIRROR="$mirror" FM_HOME="$home" "$HOOKS" run stop >/dev/null 2>&1
  assert_equals 3 "$(wc -l < "$mirror" | tr -d ' ')" "every dialog run must be mirrored"
  line=$(sed -n 1p "$mirror")
  printf '%s' "$line" | jq -e --arg sha "$(sha256_text "$prompt")" '
    .event == "prompt-submit" and .hooks == [] and .dialog == {role: "captain", session_id: "sess-1", id: "p-7",
    text_sha256: $sha, text_chars: 34}' >/dev/null || fail "prompt-submit mirror line is wrong: $line"
  line=$(sed -n 2p "$mirror")
  printf '%s' "$line" | jq -e --argjson n "${#said}" '.event == "stop" and .dialog.role == "main"
    and .dialog.text_chars == $n and .hooks[0].exit == 4 and (.dialog | has("text") | not)' >/dev/null \
    || fail "stop mirror line is wrong: $line"
  sed -n 3p "$mirror" | jq -e '.dialog == {role: "main", session_id: null, id: null, text_sha256: null,
    text_chars: null}' >/dev/null || fail "a payload that is not JSON must leave the dialog fields null"
  assert_no_grep 'private' "$mirror" "the mirror wrote dialog text without FM_HOOK_MIRROR_TEXT"
  rm -f "$mirror"
  jq -cn --arg t "$(printf 'a%.0s' $(seq 1 3000))$(printf 'b%.0s' $(seq 1 3000))" \
    '{last_assistant_message: $t, generation_id: 12}' \
    | FM_HOOK_MIRROR="$mirror" FM_HOOK_MIRROR_TEXT=1 FM_HOME="$home" "$HOOKS" run stop >/dev/null 2>&1
  jq -e --arg want "$(printf 'a%.0s' $(seq 1 2000))"$'\n[... 2050 characters cut ...]\n'"$(printf 'b%.0s' $(seq 1 1950))" \
    '.dialog.text == $want and .dialog.text_chars == 6000 and .dialog.id == "12"' "$mirror" >/dev/null \
    || fail "the allowed dialog text is not capped as documented"
  pass "prompt-submit and stop: every run mirrored, digests only unless FM_HOOK_MIRROR_TEXT=1, text capped"
}

# --- prompt-submit and stop call point: bin/fm-dialog-hooks.sh -----------------

# A primary checkout (git, AGENTS.md, this repo's bin) the tracked Claude
# registrations run from, as a primary's own hooks do.
DIALOG_ROOT="$TMP_ROOT/dialog-primary"
mkdir -p "$DIALOG_ROOT"
git init -q "$DIALOG_ROOT"
: > "$DIALOG_ROOT/AGENTS.md"
ln -s "$ROOT/bin" "$DIALOG_ROOT/bin"

dialog_cmd() {  # <UserPromptSubmit|Stop>: the tracked registration's command string
  jq -r --arg e "$1" '.hooks[$e][].hooks[] | select(.command | contains("fm-dialog-hooks.sh")) | .command' \
    "$ROOT/.claude/settings.json"
}

run_dialog() {  # <home> <UserPromptSubmit|Stop> <payload> [root]: run the tracked registration
  printf '%s' "$3" | env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u GROK_AGENT -u GROK_HOOK_EVENT \
    FM_HOME="$1" CLAUDE_PROJECT_DIR="${4:-$DIALOG_ROOT}" bash -c "$(dialog_cmd "$2")"
}

test_dialog_call_point_hands_the_dialog_to_hooks() {
  local home out rc prompt
  home=$(new_home dialog-call)
  [ -n "$(dialog_cmd UserPromptSubmit)" ] && [ -n "$(dialog_cmd Stop)" ] \
    || fail "the tracked Claude settings do not register fm-dialog-hooks.sh on UserPromptSubmit and Stop"
  out=$(printf 'kept\n' | { env -u FM_ROOT_OVERRIDE FM_HOME="$home" CLAUDE_PROJECT_DIR="$DIALOG_ROOT" \
    bash -c "$(dialog_cmd UserPromptSubmit)"; cat; })
  assert_equals 'kept' "$out" "the call point read stdin with no dialog hooks installed"
  hook "$home/hooks/prompt-submit.d" 10-seen "cat > '$home/prompt.json'; echo 'context the model must never see'"
  hook "$home/hooks/stop.d" 10-seen "cat > '$home/stop.json'; echo noise; echo 'stop hook broke' >&2; exit 2"
  prompt=$'Ship it\n\n'
  out=$(run_dialog "$home" UserPromptSubmit "$(jq -cn --arg p "$prompt" \
    '{hook_event_name: "UserPromptSubmit", session_id: "sess-1", prompt_id: "p-1", prompt: $p}')" 2>&1); rc=$?
  expect_code 0 "$rc" "the prompt-submit call point"
  assert_equals '' "$out" "the prompt-submit call point printed (it would reach the model's context)"
  jq -e --arg p "$prompt" --arg home "$home" '. == {session_id: "sess-1", prompt_id: "p-1", prompt: $p,
    harness: "claude", home: $home}' "$home/prompt.json" >/dev/null \
    || fail "prompt-submit payload is wrong: $(cat "$home/prompt.json")"
  out=$(run_dialog "$home" Stop '{"hook_event_name":"Stop","session_id":"sess-1","stop_hook_active":true,"last_assistant_message":"Done.","transcript_path":"/t.jsonl"}' 2>&1); rc=$?
  expect_code 0 "$rc" "a failing stop hook must never block the stop"
  assert_equals '' "$out" "the stop call point printed"
  jq -e '. == {session_id: "sess-1", prompt_id: null, last_assistant_message: "Done.", stop_hook_active: true,
    transcript_path: "/t.jsonl", harness: "claude", home: .home}' "$home/stop.json" >/dev/null \
    || fail "stop payload is wrong: $(cat "$home/stop.json")"
  assert_grep 'stop hook broke' "$home/state/.fm-hooks.log" "the stop hook failure was not logged"
  pass "the tracked Claude registrations hand prompt and stop to their hooks without printing or blocking"
}

test_dialog_call_point_stays_out_of_other_hosts_and_worktrees() {
  local home other
  home=$(new_home dialog-scope)
  hook "$home/hooks/prompt-submit.d" 10-seen "cat >> '$home/ran'"
  run_dialog "$home" UserPromptSubmit '{"hook_event_name":"UserPromptSubmit","cursor_version":"1.7","prompt":"x"}'
  run_dialog "$home" UserPromptSubmit '{"hook_event_name":"SessionStart","prompt":"x"}'
  run_dialog "$home" UserPromptSubmit 'not json'
  other="$TMP_ROOT/dialog-not-primary"
  mkdir -p "$other"
  ln -s "$ROOT/bin" "$other/bin"
  run_dialog "$home" UserPromptSubmit '{"hook_event_name":"UserPromptSubmit","prompt":"x"}' "$other"
  assert_absent "$home/ran" "a dialog hook ran for a Cursor payload, another event, or outside a primary checkout"
  run_dialog "$home" UserPromptSubmit '{"hook_event_name":"UserPromptSubmit","prompt":"x"}'
  assert_present "$home/ran" "the dialog hook did not run for a primary's own prompt"
  pass "the dialog call point ignores Cursor payloads, other events, and non-primary checkouts"
}

test_unknown_event_is_a_usage_error() {
  local rc
  FM_HOME="$TMP_ROOT" "$HOOKS" run pre-tool </dev/null 2>/dev/null; rc=$?
  expect_code 2 "$rc" "unknown event"
  "$HOOKS" run 2>/dev/null; rc=$?
  expect_code 2 "$rc" "missing event"
  "$HOOKS" --help | grep -F 'fm-hooks.sh run <event>' >/dev/null || fail "--help does not print the usage"
  pass "an unknown or missing event is a usage error"
}

# --- intake call site: bin/fm-wake-drain.sh ---------------------------------

drain_case() {  # <name>: prints a case directory whose state holds one inbox note wake
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/config" "$dir/state/inbox"
  : > "$dir/config/supervision-host-off"
  printf 'id=n1\n--\nfile the cooking idea\n' > "$dir/state/inbox/n1.note"
  append_wake "$dir/state" check inbox:n1 'check: captain inbox note n1 - file the cooking idea'
  append_wake "$dir/state" check board-forward 'check: board forward'
  printf '%s\n' "$dir"
}

run_drain() {  # <dir>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_CONFIG_OVERRIDE="$1/config" "$DRAIN" 2>/dev/null
}

test_intake_annotates_presented_inbox_notes() {
  local plain hooked out_plain out_hooked
  plain=$(drain_case intake-plain)
  hooked=$(drain_case intake-hooked)
  out_plain=$(run_drain "$plain") || fail "drain without hooks failed: $out_plain"
  assert_not_contains "$out_plain" 'INTAKE' "a drain without intake hooks printed an intake line"
  hook "$hooked/hooks/intake.d" 10-route "cat > '$hooked/payload'; echo '{\"node\":\"node:kitchen\",\"note\":\"routed\"}'"
  hook "$hooked/hooks/intake.d" 20-broken 'exit 9'
  out_hooked=$(run_drain "$hooked") || fail "drain with intake hooks failed: $out_hooked"
  assert_contains "$out_hooked" 'INTAKE inbox:n1: {"node":"node:kitchen","note":"routed"}' "the intake hook output is missing"
  assert_equals 1 "$(printf '%s\n' "$out_hooked" | grep -c '^INTAKE ')" "intake ran for a wake that is not an inbox note"
  jq -e --arg file "$hooked/state/inbox/n1.note" '
    .item_key == "inbox:n1" and .surface == "inbox" and .place == "captain-inbox" and .text_file == $file
  ' "$hooked/payload" >/dev/null || fail "intake payload is wrong: $(cat "$hooked/payload")"
  # Wake rows lead with their append time, which differs between the two cases.
  assert_equals "$(printf '%s\n' "$out_plain" | cut -f2-)" \
    "$(printf '%s\n' "$out_hooked" | grep -v '^INTAKE ' | sed "s#$hooked#$plain#g" | cut -f2-)" \
    "intake hooks changed the rest of the drain output"
  pass "the wake drain offers presented inbox notes to intake hooks and appends their lines"
}

# --- pre-merge call site: bin/fm-pr-merge.sh --------------------------------

test_pre_merge_refusal_merges_and_records_nothing() {
  local dir home fake out rc
  dir="$TMP_ROOT/pre-merge"
  home=$(new_home pre-merge)
  fake="$dir/fakebin"
  mkdir -p "$fake"
  printf 'window=fm:t1\nproject=p\nworktree=%s/nowhere\n' "$dir" > "$home/state/t1.meta"
  printf '#!/bin/sh\necho "gh $*" >> "%s/forge.log"\nexit 1\n' "$dir" > "$fake/gh"
  chmod +x "$fake/gh"
  hook "$home/hooks/pre-merge.d" 10-freeze "cat > '$dir/payload.json'; echo 'release freeze until Monday' >&2; exit 1"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" PATH="$fake:$PATH" \
    "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/example/repo/pull/7 2>&1); rc=$?
  expect_code 3 "$rc" "a refusing pre-merge hook: $out"
  assert_contains "$out" 'release freeze until Monday' "the hook's reason is missing"
  assert_contains "$out" 'nothing was merged or recorded' "the refusal does not say nothing happened"
  assert_absent "$dir/forge.log" "the forge was contacted after a pre-merge refusal"
  assert_no_grep 'pr=' "$home/state/t1.meta" "the PR was recorded after a pre-merge refusal"
  jq -e '.task_id == "t1" and .pr_url == "https://github.com/example/repo/pull/7" and .provider == "github"' \
    "$dir/payload.json" >/dev/null || fail "pre-merge payload is wrong: $(cat "$dir/payload.json")"
  pass "a refusing pre-merge hook stops the merge before the forge or any record is touched"
}

test_no_hooks_is_a_silent_no_op
test_emit_never_starts_the_runner_without_a_folder
test_payload_builder_escapes_values
test_order_payload_args_and_skips
test_blocking_events_stop_at_first_refusal
test_blocking_timeout_refuses_within_the_bound
test_slow_and_failing_non_blocking_hooks_do_not_block
test_session_start_passes_stdout_and_intake_merges
test_pre_spawn_output_merge_rule
test_mirror_records_digests_only
test_dialog_events_mirror_digests_unless_text_is_allowed
test_dialog_call_point_hands_the_dialog_to_hooks
test_dialog_call_point_stays_out_of_other_hosts_and_worktrees
test_unknown_event_is_a_usage_error
test_intake_annotates_presented_inbox_notes
test_pre_merge_refusal_merges_and_records_nothing

echo 'fm-hooks: all tests passed'
