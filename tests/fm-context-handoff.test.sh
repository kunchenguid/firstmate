#!/usr/bin/env bash
# Hermetic public-interface tests for the default-off curated context handoff.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

CLI="$ROOT/bin/fm-context-handoff.py"
CORE=$(realpath "$ROOT/tests/fixtures/context-handoff-transaction-core.py")
TRANSACTION_CORE="$CORE"
TRANSACTION_MODULE="$CORE"
if [ "${FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE:-0}" = 1 ]; then
  TRANSACTION_ROOT=${FM_CONTEXT_HANDOFF_TRANSACTION_ROOT:-$HOME/claude-obsidian}
  TRANSACTION_CORE=$(realpath "$TRANSACTION_ROOT/scripts/claude-obsidian.py")
  TRANSACTION_MODULE=$(realpath "$TRANSACTION_ROOT/claude_obsidian/transaction.py")
  [ -f "$TRANSACTION_CORE" ] && [ -f "$TRANSACTION_MODULE" ] || fail "required installed claude-obsidian transaction core is unavailable"
fi
TMP_ROOT=$(fm_test_tmproot context-handoff)
FIXED_NOW=2026-08-30T20:00:00Z
CAPABILITY=claude-process-generation-1
REGISTRATION_ENABLED=true
SEALING_ENABLED=true
DELIVERY_ENABLED=false
CONSUMER_ENABLED=false

hash_text() {
  printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

hash_file() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

python_path() {
  python3 -c 'import pathlib,sys; print(pathlib.Path(sys.executable).resolve())'
}

fs_identity() {
  python3 -c 'import os,sys; s=os.stat(sys.argv[1]); print(f"{s.st_dev} {s.st_ino}")' "$1"
}

session_hash() {
  printf 'firstmate-context-handoff-v1\0%s\0%s' "$1" "$2" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

write_config() {
  local identity device inode temporary
  identity=$(fs_identity "$VAULT") || fail "could not read synthetic Vault identity"
  device=${identity%% *}
  inode=${identity##* }
  temporary="$FM_HOME/config/context-handoff.json.tmp"
  jq -n \
    --argjson registration "$REGISTRATION_ENABLED" \
    --argjson sealing "$SEALING_ENABLED" \
    --argjson delivery "$DELIVERY_ENABLED" \
    --argjson consumer "$CONSUMER_ENABLED" \
    --arg source "$SOURCE" \
    --slurpfile allowlist "$ALLOWLIST" \
    --arg vault "$VAULT" \
    --argjson device "$device" \
    --argjson inode "$inode" \
    --arg herdr "$FAKE_HERDR" \
    --arg herdr_sha "$(hash_file "$FAKE_HERDR")" \
    --arg session_sha "$(session_hash claude "$CLAUDE_SESSION")" \
    --arg python "$(python_path)" \
    --arg core "$TRANSACTION_CORE" \
    --arg core_sha "$(hash_file "$TRANSACTION_CORE")" \
    --arg module "$TRANSACTION_MODULE" \
    --arg module_sha "$(hash_file "$TRANSACTION_MODULE")" \
    '{
      schema:"firstmate.context-handoff.config.v1",
      registration_enabled:$registration,
      sealing_enabled:$sealing,
      delivery_enabled:$delivery,
      consumer_enabled:$consumer,
      approved_source_roots:[$source],
      registration_allowlist:$allowlist[0],
      allowed_provider_classes:["anthropic-claude-obsidian"],
      vault:{path:$vault,device:$device,inode:$inode},
      recipient:{herdr_cli_path:$herdr,herdr_cli_sha256:$herdr_sha,session:"lab",workspace_id:"workspace-1",tab_id:"tab-1",pane_id:"pane-1",agent:"claude",agent_session_sha256:$session_sha},
      transaction:{python_path:$python,core_path:$core,core_sha256:$core_sha,module_path:$module,module_sha256:$module_sha},
      consumer:{create_prefix_allowlist:["wiki/concepts/","wiki/decisions/","wiki/projects/"],replace_path_allowlist:["wiki/hot.md","wiki/index.md","wiki/log.md"],required_coupled_paths:["wiki/hot.md","wiki/index.md","wiki/log.md"]}
    }' > "$temporary" || fail "could not write synthetic configuration"
  chmod 600 "$temporary"
  mv "$temporary" "$FM_HOME/config/context-handoff.json"
}

new_env() {
  EROOT="$TMP_ROOT/$1"
  FM_HOME="$EROOT/home"
  SOURCE="$EROOT/source"
  VAULT="$EROOT/vault"
  SOURCE_FILE="$SOURCE/facts.md"
  ALLOWLIST="$EROOT/allowlist.json"
  HERDR_MODE="$EROOT/herdr-mode"
  HERDR_LOG="$EROOT/herdr-log"
  HERDR_PID="$EROOT/herdr-pid"
  FAKE_HERDR="$EROOT/fake-herdr"
  CLAUDE_SESSION=claude-session-generation-1
  CAPABILITY=claude-process-generation-1
  REGISTRATION_ENABLED=true
  SEALING_ENABLED=true
  DELIVERY_ENABLED=false
  CONSUMER_ENABLED=false
  mkdir -p "$FM_HOME/config" "$FM_HOME/state" "$SOURCE" "$VAULT/.obsidian" "$VAULT/.raw" "$VAULT/wiki/concepts" "$VAULT/wiki/decisions" "$VAULT/wiki/projects"
  printf 'Curated durable facts.\n' > "$SOURCE_FILE"
  printf '# Index\n' > "$VAULT/wiki/index.md"
  printf '# Log\n' > "$VAULT/wiki/log.md"
  printf '# Hot\n' > "$VAULT/wiki/hot.md"
  printf '[]\n' > "$ALLOWLIST"
  printf 'ready\n' > "$HERDR_MODE"
  : > "$HERDR_LOG"
  cat > "$FAKE_HERDR" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
mode=$(cat "$FAKE_HERDR_MODE_FILE")
if [ "$mode" = flood ]; then
  printf '%s\n' "$$" > "$FAKE_HERDR_PID"
  exec yes x
fi
if [ "$1 $2" = "agent get" ]; then
  [ "$mode" = unavailable ] && exit 1
  value=$FAKE_CLAUDE_SESSION
  [ "$mode" = mismatch ] && value=other-session
  status=idle
  [ "$mode" = busy ] && status=working
  jq -nc --arg pane pane-1 --arg workspace workspace-1 --arg tab tab-1 --arg value "$value" --arg status "$status" --arg cwd "$FAKE_VAULT" '{result:{agent:{pane_id:$pane,workspace_id:$workspace,tab_id:$tab,agent:"claude",agent_status:$status,cwd:$cwd,foreground_cwd:$cwd,agent_session:{source:"claude",agent:"claude",kind:"id",value:$value}}}}'
  exit 0
fi
[ "$1 $2" = "agent prompt" ] && { printf '{}\n'; exit 0; }
exit 64
EOF
  chmod 755 "$FAKE_HERDR"
  write_config
}

cli() {
  (
    cd "$VAULT" || exit 1
    env \
      FM_HOME="$FM_HOME" \
      HOME="$EROOT/synthetic-home" \
      FM_HANDOFF_TESTING=1 \
      FM_HANDOFF_TEST_NOW="$FIXED_NOW" \
      FM_HANDOFF_TEST_PROCESS_CAPABILITY="$CAPABILITY" \
      FM_HANDOFF_TEST_FAILPOINT="${FM_HANDOFF_TEST_FAILPOINT:-}" \
      PI_SESSION_ID=pi-session-1 \
      FAKE_HERDR_LOG="$HERDR_LOG" \
      FAKE_HERDR_PID="$HERDR_PID" \
      FAKE_HERDR_MODE_FILE="$HERDR_MODE" \
      FAKE_CLAUDE_SESSION="$CLAUDE_SESSION" \
      FAKE_VAULT="$VAULT" \
      HERDR_SESSION=lab \
      HERDR_WORKSPACE_ID=workspace-1 \
      HERDR_TAB_ID=tab-1 \
      HERDR_PANE_ID=pane-1 \
      "$CLI" "$@"
  )
}

enable_consumer() {
  CONSUMER_ENABLED=true
  write_config
}

authorize() {
  local statement=${1:?} kind=${2:-gotcha} temporary
  temporary="$ALLOWLIST.tmp"
  jq \
    --arg source "$SOURCE_FILE" \
    --arg source_sha "$(hash_file "$SOURCE_FILE")" \
    --arg statement_sha "$(hash_text "$statement")" \
    --arg kind "$kind" \
    '. + [{source_record:$source,source_sha256:$source_sha,statement_sha256:$statement_sha,kind:$kind,confidence:"verified",sphere:"privat",provider_class:"anthropic-claude-obsidian",supersedes:[]}] | unique_by(tojson)' \
    "$ALLOWLIST" > "$temporary" || fail "could not extend registration allowlist"
  mv "$temporary" "$ALLOWLIST"
  write_config
}

register_statement() {
  local statement=${1:?} kind=${2:-gotcha}
  authorize "$statement" "$kind"
  cli register \
    --source-harness pi \
    --kind "$kind" \
    --statement "$statement" \
    --source-record "$SOURCE_FILE" \
    --source-sha256 "$(hash_file "$SOURCE_FILE")" \
    --confidence verified \
    --sphere privat \
    --provider-class anthropic-claude-obsidian
}

seal_pi() {
  printf '{"session_id":"pi-session-1"}\n' | cli seal --source-harness pi --trigger threshold
}

complete() {
  local seal=${1:?} outcome=${2:-success} payload
  payload=$(printf '%s' "$seal" | jq -c '{bindings:(.bindings // [{record_id:.record_id,envelope_sha256:.envelope_sha256}]),trigger:"threshold",reason:"synthetic-result"}') || fail "could not build compaction outcome"
  printf '%s\n' "$payload" | cli compaction-outcome "$outcome"
}

bind_claude() {
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"SessionStart",session_id:$session,source:"startup"}' | cli claude-hook
}

mcp_response() {
  local name=${1:?} arguments request
  if [ "$#" -ge 2 ]; then
    arguments=$2
  else
    arguments='{}'
  fi
  request=$(jq -nc --arg name "$name" --argjson arguments "$arguments" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$name,arguments:$arguments}}') || fail "could not build MCP request"
  printf '%s\n' "$request" | cli mcp-server
}

mcp_content() {
  if [ "$#" -ge 2 ]; then
    mcp_response "$1" "$2"
  else
    mcp_response "$1"
  fi | jq -c '.result.content[0].text | fromjson'
}

make_ready() {
  local statement=${1:-Keep retries bounded after a lock conflict.} registered seal
  registered=$(register_statement "$statement") || fail "candidate registration failed"
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "candidate did not register"
  seal=$(seal_pi) || fail "candidate seal failed"
  complete "$seal" success >/dev/null || fail "compaction completion failed"
  printf '%s\n' "$seal"
}

make_bundle() {
  local record_id=${1:?} operation index_sha log_sha hot_sha
  operation="handoff-$(hash_text "$record_id" | cut -c1-32)"
  index_sha=$(hash_file "$VAULT/wiki/index.md")
  log_sha=$(hash_file "$VAULT/wiki/log.md")
  hot_sha=$(hash_file "$VAULT/wiki/hot.md")
  jq -nc \
    --arg operation "$operation" \
    --arg index "$index_sha" \
    --arg log "$log_sha" \
    --arg hot "$hot_sha" \
    '{schema:"claude-obsidian.transaction.v1",operation_id:$operation,operation_type:"save",expected_hashes:{"wiki/concepts/Bounded retry.md":null,"wiki/index.md":$index,"wiki/log.md":$log,"wiki/hot.md":$hot},writes:[{path:"wiki/concepts/Bounded retry.md",mode:"create",content:"# Bounded retry\n\nKeep retries bounded after a lock conflict.\n"},{path:"wiki/index.md",mode:"replace",content:"# Index\n- [[concepts/Bounded retry]]\n"},{path:"wiki/log.md",mode:"replace",content:"# Log\n- Added bounded retry guidance.\n"},{path:"wiki/hot.md",mode:"replace",content:"# Hot\n- Bounded retry guidance.\n"}],address_requests:[],source_manifest_updates:{}}'
}

prepare_save() {
  local record_id=${1:?} bundle=${2:?} arguments
  arguments=$(jq -nc --arg record "$record_id" --argjson bundle "$bundle" '{record_id:$record,duplicate_check:{result:"no-match",searched_paths:["wiki/index.md"]},bundle:$bundle}') || fail "could not build prepare request"
  mcp_content prepare_handoff_save "$arguments"
}

commit_save() {
  local record_id=${1:?} approval=${2:?} arguments
  arguments=$(jq -nc --arg record "$record_id" --arg approval "$approval" '{record_id:$record,approval_sha256:$approval}') || fail "could not build commit request"
  mcp_content commit_handoff_save "$arguments"
}

test_sensitive_contracts() {
  local statement seal record bundle sensitive arguments result
  new_env sensitive
  for statement in 'The taxpayer identifier is 123-45-6789.' 'Alice Smith account balance is EUR 5,000.'; do
    authorize "$statement"
    if cli register --source-harness pi --kind gotcha --statement "$statement" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --provider-class anthropic-claude-obsidian > /dev/null 2> "$EROOT/error"; then
      fail "sensitive candidate passed an exact eligibility contract"
    fi
    grep -q 'SENSITIVE_CONTENT' "$EROOT/error" || fail "sensitive candidate failed for the wrong reason"
  done
  enable_consumer
  seal=$(make_ready) || fail "sensitive bundle fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  sensitive=$(printf '%s' "$bundle" | jq -c '.writes[0].content="# Account\n\nAccount balance is EUR 5,000.\n"')
  arguments=$(jq -nc --arg record "$record" --argjson bundle "$sensitive" '{record_id:$record,duplicate_check:{result:"no-match",searched_paths:["wiki/index.md"]},bundle:$bundle}')
  result=$(mcp_content prepare_handoff_save "$arguments")
  [ "$(printf '%s' "$result" | jq -r .code)" = BUNDLE_CONTENT ] || fail "sensitive Save content was accepted"
  pass "sensitive candidate and Save content rejection"
}

test_queue_first_recovery() {
  local seal record claim queue retry
  new_env queue-first-recovery
  register_statement 'Recover queue state before publishing a candidate claim.' >/dev/null || fail "recovery candidate registration failed"
  seal=$(seal_pi) || fail "recovery fixture seal failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  claim=$(find "$FM_HOME/state/context-handoff/claims" -type f -name 'candidate-*.json' | head -1)
  queue="$FM_HOME/state/context-handoff/queue/$record.json"
  rm -f "$claim" "$queue"
  if FM_HANDOFF_TEST_FAILPOINT=after-recovery-queue-before-claims seal_pi > /dev/null 2> "$EROOT/error"; then
    fail "recovery failpoint did not interrupt claim publication"
  fi
  [ -f "$queue" ] || fail "recovery published no queue before claims"
  [ -z "$(find "$FM_HOME/state/context-handoff/claims" -type f -name 'candidate-*.json' -print -quit)" ] || fail "recovery published a claim before its queue"
  retry=$(seal_pi) || fail "queue-first recovery did not resume"
  [ "$(printf '%s' "$retry" | jq -r .status)" = already-sealed ] || fail "queue-first retry resealed different bytes"
  [ -n "$(find "$FM_HOME/state/context-handoff/claims" -type f -name 'candidate-*.json' -print -quit)" ] || fail "queue-first retry did not restore claims"
  pass "queue-first orphan recovery"
}

test_registration_capability_lock() {
  local statement args request state binding cap2 before i response lock_marker lock_release lock_pid stale_pid
  new_env registration-capability
  enable_consumer
  bind_claude >/dev/null || fail "initial Claude binding failed"
  statement='A stale MCP process must not register for its replacement generation.'
  authorize "$statement"
  args=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  request=$(jq -nc --argjson arguments "$args" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"register_curated_candidate",arguments:$arguments}}')
  state="$FM_HOME/state/context-handoff"
  binding=$(find "$state/bindings" -maxdepth 1 -type f ! -name 'compaction-*' | head -1)
  lock_marker="$EROOT/lock-held"
  lock_release="$EROOT/lock-release"
  mkfifo "$lock_release"
  python3 - "$state/.lock" "$lock_marker" "$lock_release" <<'PY' &
import fcntl
import pathlib
import sys

with open(sys.argv[1], "a+b") as handle:
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).write_text("held\n")
    with open(sys.argv[3], "rb") as release:
        release.read(1)
PY
  lock_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -f "$lock_marker" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -f "$lock_marker" ] || fail "synthetic state lock was not acquired"
  before=$(wc -l < "$HERDR_LOG")
  printf '%s\n' "$request" | cli mcp-server > "$EROOT/stale-response" 2> "$EROOT/stale-error" &
  stale_pid=$!
  i=0
  while [ "$i" -lt 20 ] && [ "$(wc -l < "$HERDR_LOG")" -le "$before" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  cap2=$(printf 'test\0claude-process-generation-2' | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
  jq --arg cap "$cap2" '.process_capability_sha256=$cap' "$binding" > "$binding.tmp" || fail "could not replace synthetic binding"
  chmod 600 "$binding.tmp"
  mv "$binding.tmp" "$binding"
  printf x > "$lock_release"
  wait "$lock_pid" || fail "synthetic state lock holder failed"
  wait "$stale_pid" || fail "stale MCP server process failed"
  response=$(jq -r '.result.content[0].text | fromjson | .code' "$EROOT/stale-response")
  [ "$response" = CONSUMER_SESSION ] || fail "stale MCP request registered after replacement binding"
  [ -z "$(find "$state/candidates" -type f -name 'candidate-*.json' -print -quit)" ] || fail "stale MCP request published a candidate"
  pass "locked registration capability snapshot"
}

test_compaction_backpressure() {
  local i statement seal drain after
  new_env compaction-backpressure
  i=1
  while [ "$i" -le 32 ]; do
    statement="Retryable bounded record $i must remain recoverable."
    register_statement "$statement" >/dev/null || fail "could not register retryable record $i"
    seal=$(seal_pi) || fail "could not seal retryable record $i"
    complete "$seal" failure >/dev/null || fail "could not record failed compaction $i"
    i=$((i + 1))
  done
  statement='Backpressure must leave an exact later success transition.'
  authorize "$statement"
  if cli register --source-harness pi --kind gotcha --statement "$statement" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --provider-class anthropic-claude-obsidian > /dev/null 2> "$EROOT/backpressure-error"; then
    fail "compaction cap accepted an unrecoverable extra candidate"
  fi
  grep -q 'COMPACTION_BACKPRESSURE' "$EROOT/backpressure-error" || fail "compaction cap did not apply explicit backpressure"
  drain=$(seal_pi) || fail "backpressured retry set could not drain"
  [ "$(printf '%s' "$drain" | jq '.bindings | length')" -eq 32 ] || fail "drain attempt lost retryable records"
  complete "$drain" success >/dev/null || fail "bounded retry set could not reach success"
  after=$(register_statement "$statement") || fail "registration did not recover after bounded drain"
  [ "$(printf '%s' "$after" | jq -r .status)" = registered ] || fail "post-drain registration failed"
  pass "bounded compaction backpressure and drain"
}

test_exit75_requires_fresh_inspect() {
  local seal record bundle prepared approval result fresh
  new_env exit75
  enable_consumer
  seal=$(make_ready) || fail "exit-75 fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  prepared=$(prepare_save "$record" "$bundle") || fail "Save prepare failed"
  [ "$(printf '%s' "$prepared" | jq -r .status)" = review-required ] || fail "Save prepare returned an error: $prepared"
  approval=$(printf '%s' "$prepared" | jq -r .approval_sha256)
  mkdir -p "$VAULT/.vault-meta"
  printf 'held\n' > "$VAULT/.vault-meta/mutation.lock"
  result=$(commit_save "$record" "$approval")
  [ "$(printf '%s' "$result" | jq -r .reason)" = fresh-inspect-required ] || fail "exit 75 did not require fresh inspect: $result"
  rm -f "$VAULT/.vault-meta/mutation.lock"
  result=$(commit_save "$record" "$approval")
  [ "$(printf '%s' "$result" | jq -r .code)" = SAVE_AUTHORITY_REVOKED ] || fail "exit 75 retained stale Save authority"
  fresh=$(prepare_save "$record" "$bundle") || fail "fresh inspect did not restore authority"
  approval=$(printf '%s' "$fresh" | jq -r .approval_sha256)
  result=$(commit_save "$record" "$approval")
  [ "$(printf '%s' "$result" | jq -r .status)" = acknowledged ] || fail "fresh inspect could not commit"
  pass "exit-75 Save authority revocation"
}

test_exact_mcp_guard() {
  local denied shell_denied
  new_env exact-mcp-guard
  enable_consumer
  denied=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreToolUse",session_id:$session,tool_name:"mcp__firstmate-context-handoff-evil__execute",tool_input:{}}' | cli claude-hook 2>&1 >/dev/null || true)
  printf '%s' "$denied" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 || fail "substring MCP server bypassed the guard"
  shell_denied=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreToolUse",session_id:$session,tool_name:"Bash",tool_input:{command:"printf unsafe"}}' | cli claude-hook 2>&1 >/dev/null || true)
  printf '%s' "$shell_denied" | jq -e '.hookSpecificOutput.permissionDecision=="deny"' >/dev/null 2>&1 || fail "direct shell mutation bypassed the guard"
  if ! jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreToolUse",session_id:$session,tool_name:"mcp__firstmate-context-handoff__next_curated_handoff",tool_input:{}}' | cli claude-hook > "$EROOT/allowed" 2> "$EROOT/allowed-error"; then
    fail "exact bundled MCP read tool was denied"
  fi
  [ ! -s "$EROOT/allowed" ] && [ ! -s "$EROOT/allowed-error" ] || fail "exact bundled MCP guard emitted an unexpected decision"
  pass "exact bundled MCP tool allowlist"
}

test_bounded_transports_and_delivery() {
  local seal delivery framed pid i
  new_env bounded-transport
  enable_consumer
  seal=$(make_ready 'Retain delivery until an exact atomic generation prompt exists.') || fail "delivery fixture failed"
  DELIVERY_ENABLED=true
  write_config
  delivery=$(cli deliver) || fail "unsupported atomic delivery did not stay pending"
  [ "$(printf '%s' "$delivery" | jq -r .reason)" = recipient-atomic-generation-prompt-unsupported ] || fail "delivery did not fail closed without an atomic generation precondition"
  ! grep -q '^agent prompt' "$HERDR_LOG" || fail "delivery sent a probe-then-prompt notification"
  dd if=/dev/zero bs=1048576 count=1 2>/dev/null | tr '\000' x > "$EROOT/frames"
  printf 'x\n{"jsonrpc":"2.0","id":2,"method":"ping"}\n' >> "$EROOT/frames"
  framed=$(cli mcp-server < "$EROOT/frames") || fail "MCP server failed while draining an oversized frame"
  [ "$(printf '%s' "$framed" | jq -r .id)" = 2 ] || fail "oversized MCP frame consumed the following ping"

  new_env bounded-subprocess
  enable_consumer
  make_ready 'Terminate a local adapter when its output exceeds the cap.' >/dev/null || fail "output-cap fixture failed"
  DELIVERY_ENABLED=true
  write_config
  printf 'flood\n' > "$HERDR_MODE"
  if cli deliver > /dev/null 2> "$EROOT/flood-error"; then
    fail "unbounded adapter output was accepted"
  fi
  pid=$(cat "$HERDR_PID")
  i=0
  while [ "$i" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  ! kill -0 "$pid" 2>/dev/null || fail "output-capped adapter remained alive"
  pass "bounded transports and fail-closed delivery"
}

test_directory_durability() {
  local result retry
  new_env directory-durability
  register_statement 'Every new state directory must be durable before compaction.' >/dev/null || fail "directory durability candidate failed"
  rmdir "$FM_HOME/state/context-handoff/records"
  result=$(FM_HANDOFF_TEST_FAILPOINT=before-created-directory-fsync seal_pi) || fail "directory durability failure did not return a bounded result"
  [ "$(printf '%s' "$result" | jq -r .status)" = seal-failed ] || fail "directory fsync failure did not stop compaction"
  retry=$(seal_pi) || fail "directory durability retry failed"
  [ "$(printf '%s' "$retry" | jq -r .status)" = sealed ] || fail "directory durability retry did not recover"
  pass "durable private state directory creation"
}

test_pi_result_validation() {
  local adapter_root body
  new_env pi-result-validation
  for case_name in malformed unknown polluted empty disabled; do
    adapter_root="$EROOT/$case_name"
    mkdir -p "$adapter_root/bin"
    case "$case_name" in
      malformed) body='{"status":"sealed","bindings":[]}' ;;
      unknown) body='{"status":"surprising"}' ;;
      polluted) body='{"status":"empty","bindings":[]}' ;;
      empty) body='{"status":"empty"}' ;;
      disabled) body='{"status":"disabled"}' ;;
    esac
    cat > "$adapter_root/bin/fm-context-handoff.py" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$body'
EOF
    chmod 755 "$adapter_root/bin/fm-context-handoff.py"
  done
  FM_HOME="$FM_HOME" EXT="$ROOT/.pi/extensions/lib/fm-context-handoff.ts" \
  MALFORMED="$EROOT/malformed" UNKNOWN="$EROOT/unknown" POLLUTED="$EROOT/polluted" EMPTY="$EROOT/empty" DISABLED="$EROOT/disabled" \
  node --input-type=module <<'EOF' || fail "Pi result validation failed"
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT).href + `?v=${Date.now()}`);
const ctx = { sessionManager:{ getSessionId(){ return "pi-session-1"; } } };
for (const [root, cancel] of [[process.env.MALFORMED,true],[process.env.UNKNOWN,true],[process.env.POLLUTED,true],[process.env.EMPTY,false],[process.env.DISABLED,false]]) {
  const handlers = new Map();
  mod.registerContextHandoff({on(name, handler){handlers.set(name, handler);}}, root, process.env.FM_HOME);
  const result = await handlers.get("session_before_compact")({reason:"threshold"}, ctx);
  if (Boolean(result?.cancel) !== cancel) throw new Error(`unexpected cancel result for ${root}`);
}
EOF
  pass "fail-closed Pi adapter result validation"
}

test_completed_save_precedes_source_validation() {
  local seal record bundle prepared approval bundle_path result disposition
  new_env completed-save-source-change
  enable_consumer
  seal=$(make_ready) || fail "completed-Save fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  prepared=$(prepare_save "$record" "$bundle") || fail "Save prepare failed"
  approval=$(printf '%s' "$prepared" | jq -r .approval_sha256)
  bundle_path="$FM_HOME/state/context-handoff/bundles/$record/$(printf '%s' "$prepared" | jq -r .bundle_sha256).json"
  "$(python_path)" "$TRANSACTION_CORE" transaction apply "$bundle_path" --vault "$VAULT" --approved-plan-sha256 "$approval" >/dev/null || fail "synthetic apply did not complete"
  printf 'Changed after apply completed.\n' > "$SOURCE_FILE"
  disposition=$(jq -nc --arg record "$record" '{record_id:$record,disposition:"duplicate",rationale:"The durable fact already exists."}')
  result=$(mcp_content record_curation_disposition "$disposition")
  [ "$(printf '%s' "$result" | jq -r .disposition)" = saved ] || fail "source change blocked completed-Save recovery"
  [ -f "$FM_HOME/state/context-handoff/acks/$record.json" ] || fail "completed Save was not acknowledged"
  [ "$(jq -r .status "$FM_HOME/state/context-handoff/queue/$record.json")" = acknowledged ] || fail "completed Save did not heal queue state"
  pass "completed Save recovery before source validation"
}

test_sensitive_contracts
test_queue_first_recovery
test_registration_capability_lock
test_compaction_backpressure
test_exit75_requires_fresh_inspect
test_exact_mcp_guard
test_bounded_transports_and_delivery
test_directory_durability
test_pi_result_validation
test_completed_save_precedes_source_validation

if [ "${FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE:-0}" = 1 ]; then
  pass "exact-installed-transaction-core core=$(hash_file "$TRANSACTION_CORE") module=$(hash_file "$TRANSACTION_MODULE")"
fi
