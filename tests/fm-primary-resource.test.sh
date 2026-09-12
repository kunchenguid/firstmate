#!/usr/bin/env bash
# Behavior tests for bin/fm-primary-resource.sh (main-session resource protection).
#
# Covers: inclusive thresholds 174999/175000 and 96.99/97, both-triggers quota
# precedence, unknown/malformed context, wrong-session/non-owner observe,
# same-provider and stale destination rejection, duplicate incident suppression
# at check and commit, secondmate no-op, unsupported-backend alert, commit
# revalidation, structured stow attestation, argv admission via commit,
# stranded-helper reconciliation, route-gateway refusal, per-window quota
# episodes, Herdr alert-only (no terminal), and a live isolated tmux
# (-L private socket) exit->shell->successor path (skipped when tmux is absent).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR="$ROOT/bin/fm-primary-resource.sh"
TMP_ROOT=$(fm_test_tmproot fm-primary-resource)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
TRACK_TMUX_SOCKETS=""

GLOBAL_CLEANUP() {
  local sock
  for sock in $TRACK_TMUX_SOCKETS; do
    tmux -L "$sock" kill-server 2>/dev/null || true
  done
}
trap 'GLOBAL_CLEANUP; fm_test_cleanup' EXIT

run_pr() {
  local home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
    FM_SUPERVISOR_TARGET="${FM_SUPERVISOR_TARGET:-fixture:agent}" \
    FM_SUPERVISOR_BACKEND="${FM_SUPERVISOR_BACKEND:-tmux}" \
    PATH="$FAKEBIN:$PATH" \
    "$PR" "$@"
}

install_helper_tmux() {
  cat > "$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = new-session ]; then
  command="${!#}"
  bash -c "$command" >/dev/null 2>&1 &
  exit 0
fi
exit 1
EOF
  chmod +x "$FAKEBIN/tmux"
}

make_main_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/data"
  git -C "$home" init -q
  printf '# fixture AGENTS\n' > "$home/AGENTS.md"
  ln -sfn "$ROOT/bin" "$home/bin"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "$home"
}

make_secondmate_home() {
  local home
  home=$(make_main_home "$1")
  printf 'mate1\n' > "$home/.fm-secondmate-home"
  printf '%s\n' "$home"
}

write_claude_transcript() {
  local path=$1 tokens=$2
  mkdir -p "$(dirname -- "$path")"
  jq -nc --argjson t "$tokens" \
    '{type:"assistant", isSidechain:false, message:{usage:{input_tokens:$t, cache_creation_input_tokens:0, cache_read_input_tokens:0}}}' \
    > "$path"
}

write_codex_transcript() {
  local path=$1 tokens=$2
  mkdir -p "$(dirname -- "$path")"
  jq -nc --argjson t "$tokens" \
    '{type:"event_msg", payload:{info:{last_token_usage:{input_tokens:$t}}}}' > "$path"
}

write_malformed_transcript() {
  local path=$1
  mkdir -p "$(dirname -- "$path")"
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":"nope"}}}' > "$path"
}

write_stow_ok() {  # <path> <incident> <generation>
  cat > "$1" <<EOF
FM_PRIMARY_RESOURCE_STOW_V1
verdict=reset-safe
incidentId=$2
generation=$3
EOF
}

quota_json() {
  local provider=$1 remaining=$2
  local dest=${3:-} dest_rem=${4:-100} stale=${5:-false}
  local five_kind=${6:-session}
  local ea
  ea='[{"scope":"account","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]'
  if [ -n "$dest" ]; then
    jq -nc --arg p "$provider" --argjson r "$remaining" --arg d "$dest" --argjson dr "$dest_rem" --arg fk "$five_kind" \
      --argjson stale "$stale" --argjson ea "$ea" '
      {schemaVersion:5, providers:[
        {provider:$p, state:{status:"ok", stale:false},
         quotaSemantics:{status:"known", effectiveAvailability:$ea},
         windows:[
           {id:"five_hour", kind:$fk, label:"5h", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:$r},
           {id:"seven_day", kind:"weekly", label:"wk", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:50}
         ]},
        {provider:$d, state:{status:"ok", stale:$stale},
         quotaSemantics:{status:"known", effectiveAvailability:$ea},
         windows:[
           {id:"five_hour", kind:"session", label:"5h", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:$dr},
           {id:"weekly", kind:"weekly", label:"wk", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:$dr}
         ]}
      ]}'
  else
    jq -nc --arg p "$provider" --argjson r "$remaining" --arg fk "$five_kind" --argjson ea "$ea" '
      {schemaVersion:5, providers:[
        {provider:$p, state:{status:"ok", stale:false},
         quotaSemantics:{status:"known", effectiveAvailability:$ea},
         windows:[
           {id:"five_hour", kind:$fk, label:"5h", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:$r},
           {id:"seven_day", kind:"weekly", label:"wk", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:50}
         ]}
      ]}'
  fi
}

bind_home() {
  local home=$1 harness=$2 session=$3 transcript=$4
  mkdir -p "$home/state/primary-resource"
  jq -nc --arg h "$harness" --argjson p "$$" --arg s "$session" --arg t "$transcript" \
    '{version:1, harness:$h, pid:$p, sessionId:$s, transcriptPath:$t, boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
}

test_check_context_thresholds() {
  local home q out
  home=$(make_main_home context-below)
  write_claude_transcript "$home/tx.jsonl" 174999
  bind_home "$home" claude sess-context-below "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" "174999 must stay below context threshold"

  home=$(make_main_home context-at)
  write_claude_transcript "$home/tx.jsonl" 175000
  bind_home "$home" claude sess-context-at "$home/tx.jsonl"
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  assert_contains "$out" "primary-resource context" "175000 must trigger context inclusive"
  pass "check context 174999/175000"
}

test_quota_percent_filter_96_99() {
  local home q out
  home=$(make_main_home qfilter)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-q "$home/tx.jsonl"
  q=$(quota_json claude 3.01)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" "96.99% used must not wake"
  q=$(quota_json claude 3 codex 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  assert_contains "$out" "primary-resource quota" "97% used must wake a quota handover"
  pass "check filters 96.99 vs 97 percent used"
}

test_check_quota_wins_both() {
  local home q out
  home=$(make_main_home quota-wins)
  write_claude_transcript "$home/tx.jsonl" 200000
  bind_home "$home" claude sess-quota-wins "$home/tx.jsonl"
  q=$(quota_json claude 3 codex 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  assert_contains "$out" "primary-resource quota" "quota must win when both triggers apply"
  case "$out" in *'primary-resource context '*) fail "quota must take precedence over context" ;; esac
  pass "check quota wins over context"
}

test_quota_five_hour_schema_variants() {
  local kind home q out
  for kind in session five_hour; do
    home=$(make_main_home "five-hour-$kind")
    write_claude_transcript "$home/tx.jsonl" 1000
    bind_home "$home" claude "sess-five-hour-$kind" "$home/tx.jsonl"
    q=$(quota_json claude 3 codex 50 false "$kind")
    out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
      run_pr "$home" check 2>&1 || true)
    assert_contains "$out" "primary-resource quota" "five-hour $kind shape at 97% must trigger quota handover"
  done
  pass "five-hour session and fixture shapes trigger at 97%"
}

test_observe_wrong_session_and_non_owner() {
  local home tx
  home=$(make_main_home obs)
  tx="$home/tx.jsonl"
  write_claude_transcript "$tx" 1000
  mkdir -p "$home/state/primary-resource"
  jq -nc --argjson p "$$" --arg t "$tx" \
    '{version:1, harness:"claude", pid:$p, sessionId:"old-sess", transcriptPath:$t, boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
  printf '%s\n' "{\"session_id\":\"new-sess\",\"transcript_path\":\"$tx\",\"harness\":\"claude\"}" \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
      "$PR" observe
  assert_equals "old-sess" "$(jq -r .sessionId "$home/state/primary-resource/binding.json")" \
    "live wrong-session observe must not overwrite binding"

  printf '1\n' > "$home/state/.lock"
  rm -f "$home/state/primary-resource/binding.json"
  printf '%s\n' "{\"session_id\":\"s2\",\"transcript_path\":\"$tx\",\"harness\":\"claude\"}" \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PR" observe || true
  assert_absent "$home/state/primary-resource/binding.json" "non-owner observe must not write a binding"
  pass "observe rejects wrong session and non-owner"
}

test_observe_stdin_no_args_writes_binding() {
  local home tx
  home=$(make_main_home obs-stdin)
  tx="$home/tx.jsonl"
  write_claude_transcript "$tx" 1000
  printf '%s\n' "$$" > "$home/state/.lock"
  printf '%s\n' "{\"session_id\":\"pipe-sess\",\"transcript_path\":\"$tx\",\"harness\":\"claude\"}" \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
      "$PR" observe
  assert_present "$home/state/primary-resource/binding.json" \
    "no-arg observe must read stdin and write binding.json"
  assert_equals "pipe-sess" "$(jq -r .sessionId "$home/state/primary-resource/binding.json")"
  assert_equals "$$" "$(jq -r .pid "$home/state/primary-resource/binding.json")" \
    "observe must record the bare lock pid"
  pass "observe stdin with no args writes binding"
}

test_unsupported_adapter_stays_alert_only() {
  local home tx out
  home=$(make_main_home pi-alert)
  tx="$home/tx.jsonl"
  printf '%s\n' '{"stop_hook_active":false}' | PI_CODING_AGENT=true \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 "$PR" observe
  assert_absent "$home/state/primary-resource/binding.json" "pi payload without a session id must not bind"
  out=$(PI_CODING_AGENT=true FM_PRIMARY_RESOURCE_QUOTA_JSON="$(quota_json claude 50)" \
    FM_SUPERVISOR_BACKEND=tmux run_pr "$home" check 2>&1 || true)
  assert_contains "$out" "adapter pi is alert-only" "unsupported adapter must explain its alert-only status"
  if find "$home/state/primary-resource/proposals" -type f -print -quit | grep -q .; then
    fail "unsupported adapter must not propose handover"
  fi

  write_codex_transcript "$tx" 175000
  printf '%s\n' "{\"session_id\":\"codex-sess\",\"transcript_path\":\"$tx\",\"harness\":\"codex\"}" \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PRIMARY_RESOURCE_FORCE_OWNER=1 "$PR" observe
  assert_equals "codex" "$(jq -r .harness "$home/state/primary-resource/binding.json")" \
    "codex must retain a supported binding"
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$(quota_json codex 50)" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  assert_contains "$out" "primary-resource context" "codex must still propose at the reliable context threshold"
  pass "unsupported adapters alert only while codex remains eligible"
}

test_check_lock_pid_mismatch_alert() {
  local home tx q out
  home=$(make_main_home lock-mismatch)
  tx="$home/tx.jsonl"
  write_claude_transcript "$tx" 1000
  mkdir -p "$home/state/primary-resource"
  jq -nc --arg t "$tx" \
    '{version:1, harness:"claude", pid:999999, sessionId:"mismatch", transcriptPath:$t, boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
  printf '%s\n' "$$" > "$home/state/.lock"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "binding pid does not own the session lock" \
    "check must alert when binding pid != bare lock pid"
  pass "check lock-pid mismatch alert"
}

# Finding 1: commit revalidates; stale proposal refused when context drops.
test_commit_revalidates_and_refuses_stale() {
  local home q out incident gen rc=0
  home=$(make_main_home reval)
  write_claude_transcript "$home/tx.jsonl" 200000
  bind_home "$home" claude sess-reval "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "primary-resource context" "setup: context proposal"
  incident=${out##* }
  incident=${incident%%$'\n'*}
  gen=sess-reval
  assert_present "$home/state/primary-resource/proposals/$incident.json"
  jq -e '.evidence and .generation and .sourceBinding' \
    "$home/state/primary-resource/proposals/$incident.json" >/dev/null \
    || fail "proposal must persist evidence+generation+sourceBinding"
  write_stow_ok "$home/stow.md" "$incident" "$gen"
  # Drop context below threshold before commit.
  write_claude_transcript "$home/tx.jsonl" 1000
  printf 'claude\0--verbose\0old' > "$home/argv"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$home/argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "commit must refuse when context no longer warrants action"
  assert_absent "$home/state/primary-resource/receipts/$incident.json" \
    "refused commit must not create a receipt"
  pass "commit revalidates and refuses stale proposal"
}

# Finding 2: structured attestation; negative prose rejected.
test_stow_attestation_rejects_negative_prose() {
  local home q out incident gen rc=0
  home=$(make_main_home stowneg)
  write_claude_transcript "$home/tx.jsonl" 200000
  bind_home "$home" claude sess-stow "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  incident=${out##* }; incident=${incident%%$'\n'*}
  gen=sess-stow
  printf 'not reset-safe\nthis is NOT safe to reset\n' > "$home/bad.md"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" commit "$incident" --stow-receipt "$home/bad.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "substring 'not reset-safe' must not pass"
  printf 'reset-safe: no\n' > "$home/bad2.md"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" commit "$incident" --stow-receipt "$home/bad2.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "reset-safe: no must not pass"
  write_stow_ok "$home/ok.md" "$incident" "wrong-gen"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" commit "$incident" --stow-receipt "$home/ok.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "wrong generation must not pass"
  write_stow_ok "$home/ok.md" "$incident" "$gen"
  ln -sfn "$home/ok.md" "$home/link.md"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" commit "$incident" --stow-receipt "$home/link.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "symlink attestation must be rejected"
  pass "stow attestation rejects negative/mismatched/symlink"
}

# Finding 5 + 10: argv admission through commit (not sed-extracted).
test_argv_admission_via_commit_rejects_wrappers() {
  local home q out incident gen rc=0 argv
  home=$(make_main_home argvadm)
  write_claude_transcript "$home/tx.jsonl" 200000
  bind_home "$home" claude sess-argv "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  incident=${out##* }; incident=${incident%%$'\n'*}
  gen=sess-argv
  write_stow_ok "$home/stow.md" "$incident" "$gen"
  argv="$home/argv"
  printf 'env\0FOO=bar\0claude\0--verbose\0old prompt' > "$argv"
  rc=0
  err=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="fixture:agent" \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" 2>&1) || rc=$?
  expect_code 1 "$rc" "env wrapper argv must be refused at commit"
  assert_contains "$err" "unparseable launch argv" "wrapper refusal must be actionable"
  assert_absent "$home/state/primary-resource/receipts/$incident.json"
  printf 'node\0/opt/claude/cli.js\0--verbose\0old prompt' > "$argv"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="fixture:agent" \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "node interpreter argv must be refused at commit"
  printf 'claude\0--unknown-option\0old prompt' > "$argv"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="fixture:agent" \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "unknown options must be refused at commit"
  # Honest happy path through commit: argv[0]=claude keeps flags.
  printf 'claude\0-c\0--dangerously-skip-permissions\0--verbose\0old prompt' > "$argv"
  install_helper_tmux
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="fixture:agent" \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "harness argv[0]=claude must commit"
  assert_present "$home/state/primary-resource/receipts/$incident.json"
  assert_grep '--dangerously-skip-permissions' \
    "$home/state/primary-resource/launch/$incident.cmd" \
    "commit launch cmd must keep skip-permissions"
  assert_grep '--verbose' "$home/state/primary-resource/launch/$incident.cmd" \
    "commit launch cmd must keep --verbose after -c"

  home=$(make_main_home argvadm-codex)
  write_codex_transcript "$home/tx.jsonl" 200000
  bind_home "$home" codex sess-argv-codex "$home/tx.jsonl"
  q=$(quota_json codex 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  incident=${out##* }; incident=${incident%%$'\n'*}
  write_stow_ok "$home/stow.md" "$incident" sess-argv-codex
  argv="$home/argv"
  printf 'codex\0-c\0model_reasoning_effort="high"\0--dangerously-bypass-approvals-and-sandbox\0old prompt' > "$argv"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="fixture:agent" \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "Codex bypass argv must commit"
  assert_grep '--dangerously-bypass-approvals-and-sandbox' \
    "$home/state/primary-resource/launch/$incident.cmd" \
    "Codex successor command must keep bypass flag"
  pass "argv admission rejects unknown options and keeps spawned adapter flags"
}

test_arm_requires_python3() {
  local home rc=0 err
  home=$(make_main_home armpy)
  # Shadow python3 with a non-runnable stub ahead of PATH.
  cat > "$FAKEBIN/python3" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$FAKEBIN/python3"
  rc=0
  err=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    PATH="$FAKEBIN:$PATH" "$PR" arm 2>&1) || rc=$?
  expect_code 1 "$rc" "arm must fail closed without a working python3"
  assert_contains "$err" "python3 required" "arm must name python3"
  rm -f "$FAKEBIN/python3"
  pass "arm preflights python3"
}

test_helper_busy_then_idle_fake_backend() {
  local home busyf incident reason
  home=$(make_main_home busy-idle)
  busyf="$home/busy-state"
  printf 'busy\n' > "$busyf"
  mkdir -p "$home/state/primary-resource/receipts" "$home/state/primary-resource/launch" \
    "$home/state/primary-resource/outcomes" "$home/state/primary-resource/helper-ready"
  jq -nc --argjson p "$$" \
    '{version:1, harness:"codex", pid:$p, sessionId:"b", transcriptPath:"/dev/null", boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
  incident=busy-inc-1
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, action:"context", sourceHarness:"codex", sourceProvider:"codex",
      destinationHarness:"codex", destinationProvider:"codex", stowReceiptPath:"", reservedAt:1}' \
    > "$home/state/primary-resource/receipts/$incident.json"
  printf 'true\n' > "$home/state/primary-resource/launch/$incident.cmd"
  ( sleep 1; printf 'idle\n' > "$busyf" ) &
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SUPERVISOR_TARGET="fake:0" FM_SUPERVISOR_BACKEND=zellij \
    FM_PRIMARY_RESOURCE_BUSY_STATE_FILE="$busyf" \
    FM_PRIMARY_RESOURCE_HELPER_WAIT_SECS=5 \
    "$PR" helper "$incident" >/dev/null 2>&1 || true
  reason=$(jq -r .reason "$home/state/primary-resource/outcomes/$incident.json" 2>/dev/null || true)
  case "$reason" in
    no-busy-signal) fail "helper must wait for busy->idle via fake busy file, got no-busy-signal" ;;
    awaiting-turn-end) fail "helper stuck in awaiting-turn-end; busy flip did not clear" ;;
  esac
  [ -n "$reason" ] || fail "helper left no outcome reason"
  pass "helper waits busy-then-idle via fake busy file (reason=$reason)"
}

test_helper_no_pgrep_fallback_records_failure() {
  local home incident stage reason
  home=$(make_main_home nopgrep)
  mkdir -p "$home/state/primary-resource/receipts" "$home/state/primary-resource/launch" \
    "$home/state/primary-resource/outcomes" "$home/state/primary-resource/helper-ready"
  jq -nc '{version:1, harness:"codex", pid:999999001, sessionId:"np", transcriptPath:"/dev/null", boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
  incident=nopgrep-1
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, action:"quota", sourceHarness:"codex", sourceProvider:"codex",
      destinationHarness:"bash", destinationProvider:"codex", stowReceiptPath:"", reservedAt:1}' \
    > "$home/state/primary-resource/receipts/$incident.json"
  printf 'echo successor\n' > "$home/state/primary-resource/launch/$incident.cmd"
  printf 'idle\n' > "$home/busy"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SUPERVISOR_TARGET="fake:0" FM_SUPERVISOR_BACKEND=zellij \
    FM_PRIMARY_RESOURCE_BUSY_STATE_FILE="$home/busy" \
    FM_PRIMARY_RESOURCE_HELPER_WAIT_SECS=2 \
    "$PR" helper "$incident" >/dev/null 2>&1 || true
  stage=$(jq -r .stage "$home/state/primary-resource/outcomes/$incident.json")
  reason=$(jq -r .reason "$home/state/primary-resource/outcomes/$incident.json")
  assert_equals "failed" "$stage" "helper without a real pane must fail"
  case "$reason" in
    occupant-changed|pane-not-shell|old-pid-still-alive|herdr-alert-only|missing-supervisor-target|no-busy-signal) ;;
    *) fail "unexpected failure reason: $reason" ;;
  esac
  pass "helper refuses host-wide pgrep started fallback (reason=$reason)"
}

# Finding 3: changed occupant is consumed failure with no exit text.
test_helper_occupant_changed_no_exit() {
  local home incident reason
  home=$(make_main_home occ)
  mkdir -p "$home/state/primary-resource/receipts" "$home/state/primary-resource/launch" \
    "$home/state/primary-resource/outcomes" "$home/state/primary-resource/helper-ready"
  # Dead/wrong pid: occupant cannot match.
  jq -nc '{version:1, harness:"codex", pid:999999002, sessionId:"occ", transcriptPath:"/dev/null", boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
  incident=occ-1
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, action:"context", sourceHarness:"codex", sourceProvider:"codex",
      destinationHarness:"codex", destinationProvider:"codex", stowReceiptPath:"", reservedAt:1}' \
    > "$home/state/primary-resource/receipts/$incident.json"
  printf 'true\n' > "$home/state/primary-resource/launch/$incident.cmd"
  printf 'idle\n' > "$home/busy"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SUPERVISOR_TARGET="sess:win" FM_SUPERVISOR_BACKEND=tmux \
    FM_PRIMARY_RESOURCE_BUSY_STATE_FILE="$home/busy" \
    FM_PRIMARY_RESOURCE_HELPER_WAIT_SECS=2 \
    "$PR" helper "$incident" >/dev/null 2>&1 || true
  reason=$(jq -r .reason "$home/state/primary-resource/outcomes/$incident.json")
  assert_equals "occupant-changed" "$reason" \
    "changed/missing occupant must fail before exit text"
  pass "helper occupant-changed is consumed failed attempt"
}

test_incident_path_rejected_before_state_write() {
  local home lock_hash err rc=0 incident=valid-incident
  home=$(make_main_home incident-path)
  printf 'lock must survive\n' > "$home/state/.lock"
  lock_hash=$(shasum -a 256 "$home/state/.lock" | awk '{print $1}')

  err=$(run_pr "$home" helper ../../.lock 2>&1) || rc=$?
  expect_code 2 "$rc" "helper must reject traversal incident ids"
  assert_contains "$err" "invalid incident id" "helper must explain traversal rejection"
  assert_equals "$lock_hash" "$(shasum -a 256 "$home/state/.lock" | awk '{print $1}')" \
    "helper traversal must leave the session lock byte-identical"

  rc=0
  err=$(run_pr "$home" commit ../../.lock --stow-receipt "$home/missing-stow" 2>&1) || rc=$?
  expect_code 2 "$rc" "commit must reject traversal incident ids"
  assert_contains "$err" "invalid incident id" "commit must explain traversal rejection"
  assert_equals "$lock_hash" "$(shasum -a 256 "$home/state/.lock" | awk '{print $1}')" \
    "commit traversal must leave the session lock byte-identical"

  mkdir -p "$home/state/primary-resource/receipts" "$home/state/primary-resource/launch"
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, action:"context", sourceHarness:"codex", destinationHarness:"codex"}' \
    > "$home/state/primary-resource/receipts/$incident.json"
  jq -nc --argjson p "$$" \
    '{version:1, harness:"codex", pid:$p, sessionId:"valid", transcriptPath:"/dev/null", boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
  printf 'true\n' > "$home/state/primary-resource/launch/$incident.cmd"
  FM_SUPERVISOR_BACKEND=zellij FM_SUPERVISOR_TARGET="fixture:0" \
    run_pr "$home" helper "$incident" >/dev/null 2>&1 || true
  assert_present "$home/state/primary-resource/helper-ready/$incident" \
    "valid helper incident must proceed through receipt validation"
  pass "incident paths are rejected before state writes"
}

# Finding 4: stranded nonterminal outcome emits one alert; receipt preserved.
test_reconcile_stranded_helper_alert() {
  local home out incident
  home=$(make_main_home strand)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-strand "$home/tx.jsonl"
  incident=strand-1
  mkdir -p "$home/state/primary-resource/receipts" "$home/state/primary-resource/outcomes" \
    "$home/state/primary-resource/alerts"
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, action:"context", sourceHarness:"claude", sourceProvider:"claude",
      destinationHarness:"claude", destinationProvider:"claude", generation:"sess-strand",
      stowReceiptPath:"", reservedAt:1}' \
    > "$home/state/primary-resource/receipts/$incident.json"
  # Outcome updated far in the past; nonterminal.
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, stage:"exiting", reason:"sending-exit", updatedAt:1}' \
    > "$home/state/primary-resource/outcomes/$incident.json"
  out=$(FM_PRIMARY_RESOURCE_RECONCILE_SECS=1 FM_PRIMARY_RESOURCE_NOW=99999 \
    FM_PRIMARY_RESOURCE_QUOTA_JSON="$(quota_json claude 50)" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "handover stranded" "stale exiting outcome must alert"
  assert_present "$home/state/primary-resource/receipts/$incident.json" \
    "reconciliation must preserve the receipt"
  out=$(FM_PRIMARY_RESOURCE_RECONCILE_SECS=1 FM_PRIMARY_RESOURCE_NOW=99999 \
    FM_PRIMARY_RESOURCE_QUOTA_JSON="$(quota_json claude 50)" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" "stranded alert once"
  pass "stranded helper reconciliation alerts once and keeps receipt"
}

test_quota_axi_bounded_and_fresh() {
  local home calls out started elapsed
  home=$(make_main_home qbound)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-qb "$home/tx.jsonl"
  calls="$home/quota-calls"
  : > "$calls"
  cat > "$FAKEBIN/quota-axi" <<EOF
#!/usr/bin/env bash
printf 'call\n' >> "$calls"
cat <<'JSON'
{"schemaVersion":5,"providers":[]}
JSON
EOF
  chmod +x "$FAKEBIN/quota-axi"
  out=$(FM_CHECK_TIMEOUT=30 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 FM_SUPERVISOR_BACKEND=tmux \
    PATH="$FAKEBIN:$PATH" "$PR" check 2>/dev/null || true)
  FM_CHECK_TIMEOUT=30 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 FM_SUPERVISOR_BACKEND=tmux \
    PATH="$FAKEBIN:$PATH" "$PR" check >/dev/null 2>&1 || true
  local n
  n=$(wc -l < "$calls" | tr -d ' ')
  [ "$n" -eq 2 ] || fail "quota-axi must re-read live quota (got $n calls)"
  : > "$calls"
  cat > "$FAKEBIN/quota-axi" <<'EOF'
#!/usr/bin/env bash
exec sleep 5
echo '{}'
EOF
  chmod +x "$FAKEBIN/quota-axi"
  started=$(date +%s)
  FM_CHECK_TIMEOUT=8 FM_PRIMARY_RESOURCE_QUOTA_BUDGET_SECS=2 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 FM_SUPERVISOR_BACKEND=tmux \
    PATH="$FAKEBIN:$PATH" "$PR" check >/dev/null 2>&1 || true
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 5 ] || fail "quota-axi must honor the bounded budget (took ${elapsed}s)"
  pass "quota-axi bounded and always fresh"
}

test_reconcile_same_second_successor() {
  local home out incident
  home=$(make_main_home same-second)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude successor "$home/tx.jsonl"
  incident=same-second-1
  mkdir -p "$home/state/primary-resource/receipts" "$home/state/primary-resource/outcomes"
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, action:"context", generation:"source", reservedAt:100}' \
    > "$home/state/primary-resource/receipts/$incident.json"
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, stage:"started", reason:"successor-alive", updatedAt:1}' \
    > "$home/state/primary-resource/outcomes/$incident.json"
  out=$(FM_PRIMARY_RESOURCE_RECONCILE_SECS=1 FM_PRIMARY_RESOURCE_NOW=100 \
    FM_PRIMARY_RESOURCE_QUOTA_JSON="$(quota_json claude 50)" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  case "$out" in *'successor never became'*) fail "changed generation in the same second must not alert" ;; esac

  bind_home "$home" claude source "$home/tx.jsonl"
  out=$(FM_PRIMARY_RESOURCE_RECONCILE_SECS=1 FM_PRIMARY_RESOURCE_NOW=100 \
    FM_PRIMARY_RESOURCE_QUOTA_JSON="$(quota_json claude 50)" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>&1 || true)
  assert_contains "$out" "successor never became" "unchanged generation must remain stranded"
  pass "same-second successor binding reconciles by generation"
}

test_commit_endpoint_on_outcome_not_receipt() {
  local home q out incident gen rc=0
  home=$(make_main_home endpoint)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-ep "$home/tx.jsonl"
  q=$(quota_json claude 3 codex 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "primary-resource quota" "setup quota proposal"
  incident=${out##* }; incident=${incident%%$'\n'*}
  gen=sess-ep
  write_stow_ok "$home/stow.md" "$incident" "$gen"
  printf '#!/usr/bin/env bash\necho ok\n' > "$FAKEBIN/codex"
  chmod +x "$FAKEBIN/codex"
  install_helper_tmux
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "quota commit must launch its helper"
  assert_present "$home/state/primary-resource/receipts/$incident.json"
  if jq -e 'has("helperEndpoint")' "$home/state/primary-resource/receipts/$incident.json" >/dev/null; then
    fail "immutable receipt must not carry helperEndpoint"
  fi
  pass "commit keeps helperEndpoint off the immutable receipt"
}

# Finding 6: custom route/gateway refuses independence claim.
test_custom_route_gateway_refuses_quota_replacement() {
  local home q out envf
  home=$(make_main_home route)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-route "$home/tx.jsonl"
  q=$(quota_json claude 3 codex 50)
  envf="$home/environ"
  printf 'ANTHROPIC_BASE_URL=https://gateway.example/v1\0' > "$envf"
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    FM_PRIMARY_RESOURCE_ROUTE_ENV_FILE="$envf" \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "alert" "custom gateway must alert rather than claim independence"
  case "$out" in
    *'primary-resource quota'*) fail "custom gateway must not propose quota handover" ;;
  esac
  pass "custom route/gateway refuses provider independence"
}

# Finding 8: later window does not mint a second terminal attempt.
test_quota_episode_blocks_second_window() {
  local home q out incident
  home=$(make_main_home episode)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-ep2 "$home/tx.jsonl"
  q=$(quota_json claude 3 codex 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "primary-resource quota"
  incident=${out##* }; incident=${incident%%$'\n'*}
  write_stow_ok "$home/stow.md" "$incident" "sess-ep2"
  printf '#!/usr/bin/env bash\necho ok\n' > "$FAKEBIN/codex"
  chmod +x "$FAKEBIN/codex"
  install_helper_tmux
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 \
    || fail "first quota commit must succeed"
  assert_present "$home/state/primary-resource/episodes/claude" "episode must open"
  # Weekly also exhausted now; episode must suppress a second wake.
  q=$(jq -nc --argjson ea '[{"scope":"account","status":"known","effectivePercentRemaining":50,"runway":{"status":"through_reset"}}]' '
    {schemaVersion:5, providers:[
      {provider:"claude", state:{status:"ok", stale:false},
       quotaSemantics:{status:"known", effectiveAvailability:$ea},
       windows:[
         {id:"five_hour", kind:"session", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:3},
         {id:"seven_day", kind:"weekly", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:2}
       ]},
      {provider:"codex", state:{status:"ok", stale:false},
       quotaSemantics:{status:"known", effectiveAvailability:$ea},
       windows:[
         {id:"five_hour", kind:"session", resetsAt:"2026-09-11T20:00:00Z", percentRemaining:50},
         {id:"weekly", kind:"weekly", resetsAt:"2026-09-18T00:00:00Z", percentRemaining:50}
       ]}
    ]}')
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" \
    "active episode must suppress a second quota terminal wake"
  pass "quota episode blocks second window terminal attempt"
}

test_ambiguous_resets_at_is_alert_only() {
  local home q out
  home=$(make_main_home ambreset)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-amb "$home/tx.jsonl"
  q=$(jq -nc --argjson ea '[{"scope":"account","status":"known","effectivePercentRemaining":1,"runway":{"status":"through_reset"}}]' '
    {schemaVersion:5, providers:[
      {provider:"claude", state:{status:"ok", stale:false},
       quotaSemantics:{status:"known", effectiveAvailability:$ea},
       windows:[{id:"five_hour", kind:"session", resetsAt:"", percentRemaining:1}]}
    ]}')
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "ambiguous" "missing resetsAt must alert"
  case "$out" in
    *'primary-resource quota'*) fail "ambiguous resetsAt must not propose quota handover" ;;
  esac
  pass "missing resetsAt is alert-only"
}

test_same_provider_and_stale_destination() {
  local home q out
  home=$(make_main_home sameprov)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-sp "$home/tx.jsonl"
  q=$(quota_json claude 3 claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "alert" "same-provider destination must alert"

  home=$(make_main_home staleprov)
  write_claude_transcript "$home/tx.jsonl" 1000
  bind_home "$home" claude sess-stale "$home/tx.jsonl"
  q=$(quota_json claude 3 codex 50 true)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "alert" "stale destination must alert"
  pass "same-provider and stale destination rejected"
}

test_duplicate_incident_check_and_commit() {
  local home q out incident gen rc=0
  home=$(make_main_home dup)
  write_claude_transcript "$home/tx.jsonl" 200000
  bind_home "$home" claude sess-dup "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "primary-resource context" "context threshold must propose once"
  incident=${out##* }; incident=${incident%%$'\n'*}
  gen=sess-dup
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  # Second check may re-print the same wake until receipt exists; allow either.
  write_stow_ok "$home/stow.md" "$incident" "$gen"
  printf 'claude\0--verbose\0old' > "$home/argv"
  install_helper_tmux
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$home/argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 \
    || fail "first commit must succeed"
  rc=0
  FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    FM_PRIMARY_RESOURCE_ARGV_FILE="$home/argv" \
    run_pr "$home" commit "$incident" --stow-receipt "$home/stow.md" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "duplicate commit must refuse"
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" "receipt suppresses further context wakes"
  pass "duplicate incident suppressed at check and commit"
}

test_secondmate_noop() {
  local home tx
  home=$(make_secondmate_home mate)
  tx="$home/tx.jsonl"
  write_claude_transcript "$tx" 200000
  printf '%s\n' "{\"session_id\":\"s\",\"transcript_path\":\"$tx\",\"harness\":\"claude\"}" \
    | FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PRIMARY_RESOURCE_FORCE_OWNER=1 "$PR" observe 2>/dev/null || true
  assert_absent "$home/state/primary-resource/binding.json" "observe must no-op in a secondmate home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PR" arm 2>/dev/null || true
  assert_absent "$home/state/primary-resource.check.sh" "arm must no-op in a secondmate home"
  local out
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PR" check 2>/dev/null || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" "check must no-op in a secondmate home"
  pass "secondmate home no-op"
}

test_unsupported_backend_alert() {
  local home q out
  home=$(make_main_home be)
  write_claude_transcript "$home/tx.jsonl" 200000
  bind_home "$home" claude sess-b "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
    FM_SUPERVISOR_BACKEND=zellij FM_SUPERVISOR_TARGET="z:0" \
    PATH="$FAKEBIN:$PATH" \
    "$PR" check 2>&1 || true)
  assert_contains "$out" "alert" "unsupported backend must alert"
  assert_contains "$out" "session kept" "unsupported backend keeps the session"
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
    FM_SUPERVISOR_BACKEND=zellij FM_SUPERVISOR_TARGET="z:0" \
    PATH="$FAKEBIN:$PATH" \
    "$PR" check 2>&1 || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" "unsupported-backend alert once per generation"
  pass "unsupported backend alert"
}

test_malformed_context_via_check() {
  local home q out
  home=$(make_main_home mal)
  write_malformed_transcript "$home/tx.jsonl"
  bind_home "$home" claude sess-m "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_contains "$out" "alert" "malformed context must alert"
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" FM_SUPERVISOR_BACKEND=tmux \
    run_pr "$home" check 2>/dev/null || true)
  assert_equals "" "$(printf '%s' "$out" | tr -d '\n')" "malformed context alert once per generation"
  pass "malformed context alerts once"
}

# Finding 7+10: Herdr is alert-only; no receipt deletion; no terminal launch claim.
test_herdr_alert_only_no_terminal() {
  local home q out
  home=$(make_main_home herdralert)
  write_claude_transcript "$home/tx.jsonl" 200000
  bind_home "$home" claude sess-h "$home/tx.jsonl"
  q=$(quota_json claude 50)
  out=$(FM_PRIMARY_RESOURCE_QUOTA_JSON="$q" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_PRIMARY_RESOURCE_FORCE_OWNER=1 \
    FM_SUPERVISOR_TARGET="sess:p0" FM_SUPERVISOR_BACKEND=herdr \
    PATH="$FAKEBIN:$PATH" \
    "$PR" check 2>&1 || true)
  assert_contains "$out" "Herdr terminal handover unverified" \
    "Herdr must alert that live proof is missing"
  case "$out" in
    *'primary-resource context '*|*'primary-resource quota '*)
      fail "Herdr must not propose a terminal handover wake"
      ;;
  esac
  local receipts_dir="$home/state/primary-resource/receipts"
  if [ -d "$receipts_dir" ] && [ -n "$(ls -A "$receipts_dir" 2>/dev/null || true)" ]; then
    fail "Herdr alert-only must not create receipts"
  fi
  pass "Herdr alert-only (no terminal handover)"
}

# Finding 10: live tmux with classifier-recognized agent identity.
test_live_tmux_helper_exit_shell_successor() {
  if ! command -v tmux >/dev/null 2>&1; then
    printf 'ok - live tmux helper # SKIP tmux absent\n'
    return 0
  fi
  local home sock session pane successor_marker fake_agent agent_pid real_tmux
  home=$(make_main_home live)
  sock="fmpr$$"
  TRACK_TMUX_SOCKETS="$TRACK_TMUX_SOCKETS $sock"
  session="fmpr-live"
  successor_marker="$home/successor.launched"
  real_tmux=$(command -v tmux)
  # Copy bash to a harness-named binary so argv0/comm classify as an agent, and
  # launch it as a CHILD of the pane shell (never exec-replace the shell).
  fake_agent="$home/codex"
  cp "$(command -v bash)" "$fake_agent"
  chmod +x "$fake_agent"
  # shellcheck disable=SC2016 # agent body is a literal -c string for the child shell
  agent_body='trap "exit 0" TERM; while IFS= read -r line; do case "$line" in /quit|/exit) exit 0 ;; esac; done; while true; do sleep 1; done'
  agent_cmd=$(printf '%q --noprofile --norc -c %q' "$fake_agent" "$agent_body")

  tmux -L "$sock" new-session -d -s "$session" -n agent "bash --noprofile --norc"
  pane=$(tmux -L "$sock" list-panes -t "$session:agent" -F '#{pane_id}' | head -n1)
  tmux -L "$sock" send-keys -t "$pane" -l "$agent_cmd"
  tmux -L "$sock" send-keys -t "$pane" Enter
  sleep 0.8
  local shell_pid
  shell_pid=$(tmux -L "$sock" display-message -p -t "$pane" '#{pane_pid}')
  agent_pid=$(pgrep -P "$shell_pid" -f "$fake_agent" | head -n1 || true)
  [ -n "$agent_pid" ] || agent_pid=$(pgrep -P "$shell_pid" | head -n1 || true)
  [ -n "$agent_pid" ] || fail "live tmux: codex-named agent child not found under shell pid $shell_pid"
  # Prove classifier identity before exercising the helper.
  local aname a0
  aname=$(ps -p "$agent_pid" -o comm= 2>/dev/null || true)
  a0=$(tr '\0' '\n' < "/proc/$agent_pid/cmdline" 2>/dev/null | head -n1 || true)
  case "$aname$a0" in
    *codex*) ;;
    *) fail "live tmux: agent identity not classifier-visible (comm=$aname argv0=$a0)" ;;
  esac

  mkdir -p "$home/state/primary-resource/receipts" "$home/state/primary-resource/launch" \
    "$home/state/primary-resource/outcomes" "$home/state/primary-resource/helper-ready"
  jq -nc --argjson p "$agent_pid" \
    '{version:1, harness:"codex", pid:$p, sessionId:"live", transcriptPath:"/dev/null", boundAt:1}' \
    > "$home/state/primary-resource/binding.json"
  local incident=live-inc-1
  jq -nc --arg id "$incident" \
    '{version:1, incidentId:$id, action:"context", sourceHarness:"codex", sourceProvider:"codex",
      destinationHarness:"codex", destinationProvider:"codex", generation:"live",
      stowReceiptPath:"", reservedAt:1}' \
    > "$home/state/primary-resource/receipts/$incident.json"

  cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
touch "$successor_marker"
exec -a codex sleep 3600
EOF
  chmod +x "$FAKEBIN/codex"
  printf '%q\n' "$FAKEBIN/codex" > "$home/state/primary-resource/launch/$incident.cmd"

  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
exec "$real_tmux" -L "$sock" "\$@"
EOF
  chmod +x "$FAKEBIN/tmux"

  # Occupant must match the recognized agent before the helper sends exit.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SUPERVISOR_TARGET="$session:agent" FM_SUPERVISOR_BACKEND=tmux \
    FM_PRIMARY_RESOURCE_HELPER_WAIT_SECS=15 \
    PATH="$FAKEBIN:$PATH" \
    "$PR" helper "$incident" >/dev/null 2>&1 || true

  local i=0
  while [ "$i" -lt 80 ]; do
    [ -f "$successor_marker" ] && break
    sleep 0.25
    i=$((i + 1))
  done
  if [ ! -f "$successor_marker" ]; then
    fail "live tmux: successor did not launch (outcome=$(cat "$home/state/primary-resource/outcomes/$incident.json" 2>/dev/null || true))"
  fi
  local stage reason
  stage=$(jq -r .stage "$home/state/primary-resource/outcomes/$incident.json")
  reason=$(jq -r .reason "$home/state/primary-resource/outcomes/$incident.json")
  if [ "$stage" != started ]; then
    fail "live tmux helper outcome must be started (got $stage/$reason)"
  fi
  pass "live isolated tmux helper exit->shell->successor"
}

# Finding 9: bootstrap emits PRIMARY_RESOURCE: (not MISSING:) when arm fails.
test_bootstrap_arm_failure_diagnostic() {
  local home out rc=0
  home=$(make_main_home bootstrap-arm)
  cat > "$FAKEBIN/python3" <<'EOF'
#!/usr/bin/env bash
exit 127
EOF
  chmod +x "$FAKEBIN/python3"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_BOOTSTRAP_NETWORK=skip PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-bootstrap.sh" 2>&1) || rc=$?
  rm -f "$FAKEBIN/python3"
  expect_code 0 "$rc" "bootstrap arm failure must remain non-fatal"
  assert_contains "$out" "PRIMARY_RESOURCE: not armed" \
    "bootstrap must emit a PRIMARY_RESOURCE arm-failure diagnostic"
  case "$out" in
    MISSING:*) fail "emitted line must not be MISSING: (got: $out)" ;;
  esac
  pass "bootstrap arm failure diagnostic"
}

# --- run ----------------------------------------------------------------------

test_check_context_thresholds
test_quota_percent_filter_96_99
test_check_quota_wins_both
test_quota_five_hour_schema_variants
test_observe_wrong_session_and_non_owner
test_observe_stdin_no_args_writes_binding
test_unsupported_adapter_stays_alert_only
test_check_lock_pid_mismatch_alert
test_commit_revalidates_and_refuses_stale
test_stow_attestation_rejects_negative_prose
test_argv_admission_via_commit_rejects_wrappers
test_arm_requires_python3
test_helper_busy_then_idle_fake_backend
test_helper_no_pgrep_fallback_records_failure
test_helper_occupant_changed_no_exit
test_incident_path_rejected_before_state_write
test_reconcile_stranded_helper_alert
test_quota_axi_bounded_and_fresh
test_reconcile_same_second_successor
test_commit_endpoint_on_outcome_not_receipt
test_custom_route_gateway_refuses_quota_replacement
test_quota_episode_blocks_second_window
test_ambiguous_resets_at_is_alert_only
test_same_provider_and_stale_destination
test_duplicate_incident_check_and_commit
test_secondmate_noop
test_unsupported_backend_alert
test_malformed_context_via_check
test_herdr_alert_only_no_terminal
test_live_tmux_helper_exit_shell_successor
test_bootstrap_arm_failure_diagnostic

printf 'All primary-resource tests passed.\n'
