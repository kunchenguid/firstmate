#!/usr/bin/env bash
# Hermetic public-interface tests for the default-off curated context handoff.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_tool() {
  local name=$1
  if [ "${FM_CONTEXT_HANDOFF_TEST_MISSING_TOOL:-}" = "$name" ] || ! command -v "$name" >/dev/null 2>&1; then
    if [ "${FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE:-0}" = 1 ]; then
      fail "required context-handoff evidence tool is unavailable: $name"
    fi
    echo "skip: $name not found"
    exit 0
  fi
}

require_tool jq
require_tool python3
require_tool node

if [ "${FM_CONTEXT_HANDOFF_PREREQ_ONLY:-0}" = 1 ]; then
  exit 0
fi

CLI="$ROOT/bin/fm-context-handoff.py"
CORE=$(realpath "$ROOT/tests/fixtures/context-handoff-transaction-core.sh")
PLUGIN="$ROOT/integrations/claude-context-handoff"
TRANSACTION_CORE="$CORE"
TRANSACTION_MODULE="$CORE"
TRANSACTION_INTERPRETER=$(realpath "$(command -v bash)")
if [ "${FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE:-0}" = 1 ]; then
  TRANSACTION_ROOT=${FM_CONTEXT_HANDOFF_TRANSACTION_ROOT:-$HOME/claude-obsidian}
  TRANSACTION_CORE=$(realpath "$TRANSACTION_ROOT/scripts/claude-obsidian.py")
  TRANSACTION_MODULE=$(realpath "$TRANSACTION_ROOT/claude_obsidian/transaction.py")
  TRANSACTION_INTERPRETER=$(realpath "$(command -v python3)")
  [ -f "$TRANSACTION_CORE" ] && [ -f "$TRANSACTION_MODULE" ] || fail "required installed claude-obsidian transaction core is unavailable"
fi
TMP_ROOT=$(fm_test_tmproot context-handoff)
FIXED_NOW=2026-08-30T20:00:00Z
CAPABILITY=claude-process-generation-1
PROCESS_GENERATION=1
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

file_mode() {
  python3 -c 'import os,stat,sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$1"
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
    --arg python "$TRANSACTION_INTERPRETER" \
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
  PROCESS_GENERATION=1
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
if [ "$mode" = hang ]; then
  printf '%s\n' "$$" > "$FAKE_HERDR_PID"
  exec sleep 30
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
      FM_HANDOFF_TEST_PROCESS_GENERATION="$PROCESS_GENERATION" \
      FM_HANDOFF_TEST_FAILPOINT="${FM_HANDOFF_TEST_FAILPOINT:-}" \
      FM_HANDOFF_TEST_PAUSEPOINT="${FM_HANDOFF_TEST_PAUSEPOINT:-}" \
      FM_HANDOFF_TEST_PAUSE_MARKER="${FM_HANDOFF_TEST_PAUSE_MARKER:-$EROOT/pause-marker}" \
      FM_HANDOFF_TEST_PAUSE_RELEASE="${FM_HANDOFF_TEST_PAUSE_RELEASE:-$EROOT/pause-release}" \
      FM_HANDOFF_TEST_EXIT_AFTER_EXECUTION_CLAIM="${FM_HANDOFF_TEST_EXIT_AFTER_EXECUTION_CLAIM:-}" \
      FM_HANDOFF_TEST_EXIT_AFTER_APPLY_SPAWN="${FM_HANDOFF_TEST_EXIT_AFTER_APPLY_SPAWN:-}" \
      FM_FIXTURE_APPLY_PAUSE_MARKER="${FM_FIXTURE_APPLY_PAUSE_MARKER:-}" \
      FM_FIXTURE_APPLY_PAUSE_RELEASE="${FM_FIXTURE_APPLY_PAUSE_RELEASE:-}" \
      PI_SESSION_ID="${PI_SESSION_ID:-pi-session-1}" \
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

plugin_cli() {
  (
    cd "$VAULT" || exit 1
    env \
      FM_HOME="$FM_HOME" \
      HOME="$EROOT/synthetic-home" \
      FM_HANDOFF_TESTING=1 \
      FM_HANDOFF_TEST_NOW="$FIXED_NOW" \
      FM_HANDOFF_TEST_PROCESS_CAPABILITY="$CAPABILITY" \
      FM_HANDOFF_TEST_PROCESS_GENERATION="$PROCESS_GENERATION" \
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
      "$PLUGIN/scripts/adapter.py" "$@"
  )
}

enable_consumer() {
  CONSUMER_ENABLED=true
  write_config
}

authorize() {
  local statement=${1:?} kind=${2:-gotcha} sensitivity_class=${3:-ordinary-project-context} temporary
  temporary="$ALLOWLIST.tmp"
  jq \
    --arg source "$SOURCE_FILE" \
    --arg source_sha "$(hash_file "$SOURCE_FILE")" \
    --arg statement_sha "$(hash_text "$statement")" \
    --arg kind "$kind" \
    --arg sensitivity_class "$sensitivity_class" \
    '. + [{source_record:$source,source_sha256:$source_sha,statement_sha256:$statement_sha,kind:$kind,confidence:"verified",sphere:"privat",sensitivity_class:$sensitivity_class,provider_class:"anthropic-claude-obsidian",supersedes:[]}] | unique_by(tojson)' \
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
    --sensitivity-class ordinary-project-context \
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
  local record_id=${1:?} bundle=${2:?} arguments content_sensitivity
  content_sensitivity=$(printf '%s' "$bundle" | jq -c '.writes | map({key:.path,value:"ordinary-project-context"}) | from_entries') || fail "could not classify Save paths"
  arguments=$(jq -nc --arg record "$record_id" --argjson bundle "$bundle" --argjson content_sensitivity "$content_sensitivity" '{record_id:$record,duplicate_check:{result:"no-match",searched_paths:["wiki/index.md"]},content_sensitivity:$content_sensitivity,bundle:$bundle}') || fail "could not build prepare request"
  mcp_content prepare_handoff_save "$arguments"
}

commit_save() {
  local record_id=${1:?} approval=${2:?} arguments
  arguments=$(jq -nc --arg record "$record_id" --arg approval "$approval" '{record_id:$record,approval_sha256:$approval}') || fail "could not build commit request"
  mcp_content commit_handoff_save "$arguments"
}

test_required_prerequisite_status() {
  if FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE=1 FM_CONTEXT_HANDOFF_TEST_MISSING_TOOL=node FM_CONTEXT_HANDOFF_PREREQ_ONLY=1 bash "$0" > "$TMP_ROOT/required-prerequisite-out" 2> "$TMP_ROOT/required-prerequisite-error"; then
    fail "required evidence gate skipped a missing prerequisite"
  fi
  FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE=0 FM_CONTEXT_HANDOFF_TEST_MISSING_TOOL=node FM_CONTEXT_HANDOFF_PREREQ_ONLY=1 bash "$0" > "$TMP_ROOT/portable-prerequisite-out" 2> "$TMP_ROOT/portable-prerequisite-error" || fail "portable missing prerequisite did not remain a skip"
  grep -q '^skip: node not found$' "$TMP_ROOT/portable-prerequisite-out" || fail "portable prerequisite skip was not explicit"
  pass "required evidence prerequisite exit status"
}

test_sensitive_contracts() {
  local statement seal record bundle sensitive arguments result
  new_env sensitive
  register_statement 'The client uses API v2.' project-fact >/dev/null || fail "ordinary client project fact was rejected"
  for statement in \
    'The taxpayer identifier is 123-45-6789.' \
    'Taxpayer identifier is 12345678901.' \
    'Alice Smith account balance is EUR 5,000.' \
    "The client's salary is EUR 120,000." \
    'The vendor assets total 120000 euros.' \
    'Home address: 12 Main St.' \
    'Alice lives at 42 Kingsway.'; do
    authorize "$statement"
    if cli register --source-harness pi --kind gotcha --statement "$statement" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --sensitivity-class ordinary-project-context --provider-class anthropic-claude-obsidian > /dev/null 2> "$EROOT/error"; then
      fail "sensitive candidate passed an exact eligibility contract"
    fi
    grep -q 'SENSITIVE_CONTENT' "$EROOT/error" || fail "sensitive candidate failed for the wrong reason"
  done
  statement='The weekly release cadence is documented.'
  authorize "$statement" gotcha financial-data
  if cli register --source-harness pi --kind gotcha --statement "$statement" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --sensitivity-class financial-data --provider-class anthropic-claude-obsidian > /dev/null 2> "$EROOT/error"; then
    fail "explicit forbidden sensitivity class was accepted"
  fi
  grep -q 'SENSITIVE_CLASS' "$EROOT/error" || fail "explicit sensitivity classification failed for the wrong reason"
  for sensitive in 'Account balance is EUR 5,000.' "The client's salary is EUR 120,000." 'The vendor assets total 120000 euros.' 'Home address: 12 Main St.' 'Alice lives at 42 Kingsway.'; do
    new_env "sensitive-save-$(hash_text "$sensitive" | cut -c1-8)"
    enable_consumer
    seal=$(make_ready) || fail "sensitive bundle fixture failed"
    record=$(printf '%s' "$seal" | jq -r .record_id)
    bind_claude >/dev/null || fail "Claude binding failed"
    bundle=$(make_bundle "$record")
    bundle=$(printf '%s' "$bundle" | jq -c --arg sensitive "$sensitive" '.writes[0].content=("# Account\n\n"+$sensitive+"\n")')
    arguments=$(jq -nc --arg record "$record" --argjson bundle "$bundle" --argjson content_sensitivity "$(printf '%s' "$bundle" | jq -c '.writes | map({key:.path,value:"ordinary-project-context"}) | from_entries')" '{record_id:$record,duplicate_check:{result:"no-match",searched_paths:["wiki/index.md"]},content_sensitivity:$content_sensitivity,bundle:$bundle}')
    result=$(mcp_content prepare_handoff_save "$arguments")
    [ "$(printf '%s' "$result" | jq -r .code)" = BUNDLE_CONTENT ] || fail "sensitive Save content was accepted"
  done
  new_env sensitive-save-classification
  enable_consumer
  seal=$(make_ready) || fail "Save sensitivity classification fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  arguments=$(jq -nc --arg record "$record" --argjson bundle "$bundle" --argjson content_sensitivity "$(printf '%s' "$bundle" | jq -c '.writes | map({key:.path,value:"ordinary-project-context"}) | from_entries | .["wiki/concepts/Bounded retry.md"]="customer-record"')" '{record_id:$record,duplicate_check:{result:"no-match",searched_paths:["wiki/index.md"]},content_sensitivity:$content_sensitivity,bundle:$bundle}')
  result=$(mcp_content prepare_handoff_save "$arguments")
  [ "$(printf '%s' "$result" | jq -r .code)" = SENSITIVE_CLASS ] || fail "explicit forbidden Save sensitivity class was accepted"
  pass "sensitive candidate and Save content rejection"
}

test_foreign_candidate_isolation() {
  local current_source foreign_source current_statement foreign_statement seal record
  new_env foreign-candidate-isolation
  current_statement='Current Pi work seals independently of foreign candidates.'
  register_statement "$current_statement" project-fact >/dev/null || fail "current candidate did not register"
  current_source=$SOURCE_FILE
  foreign_source="$SOURCE/foreign.md"
  printf 'Foreign durable facts.\n' > "$foreign_source"
  SOURCE_FILE=$foreign_source
  foreign_statement='Foreign Pi work belongs to another exact session.'
  authorize "$foreign_statement" project-fact
  PI_SESSION_ID=pi-session-foreign cli register \
    --source-harness pi \
    --kind project-fact \
    --statement "$foreign_statement" \
    --source-record "$foreign_source" \
    --source-sha256 "$(hash_file "$foreign_source")" \
    --confidence verified \
    --sphere privat \
    --sensitivity-class ordinary-project-context \
    --provider-class anthropic-claude-obsidian >/dev/null || fail "foreign candidate did not register"
  SOURCE_FILE=$current_source
  printf 'Foreign source changed after registration.\n' > "$foreign_source"
  seal=$(seal_pi) || fail "foreign stale source blocked current session sealing"
  [ "$(printf '%s' "$seal" | jq -r .status)" = sealed ] || fail "current session did not seal with foreign stale work present"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  jq -e --arg statement "$current_statement" '.items | length == 1 and .[0].statement == $statement' "$FM_HOME/state/context-handoff/records/$record.json" >/dev/null || fail "current envelope included foreign session work"
  pass "foreign candidate ownership isolation"
}

test_single_create_save() {
  local seal record bundle expanded result extra_sha
  new_env single-create-save
  enable_consumer
  seal=$(make_ready) || fail "single-create Save fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  expanded=$(printf '%s' "$bundle" | jq -c '.expected_hashes["wiki/concepts/Second note.md"]=null | .writes += [{path:"wiki/concepts/Second note.md",mode:"create",content:"# Second note\n\nThis must require separate review.\n"}]')
  result=$(prepare_save "$record" "$expanded")
  [ "$(printf '%s' "$result" | jq -r .code)" = BUNDLE_DESTRUCTIVE ] || fail "automatic Save accepted multiple new notes"
  new_env extra-replacement-save
  printf '# Extra\n' > "$VAULT/wiki/extra.md"
  enable_consumer
  seal=$(make_ready) || fail "extra replacement fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  jq '.consumer.replace_path_allowlist += ["wiki/extra.md"]' "$FM_HOME/config/context-handoff.json" > "$FM_HOME/config/context-handoff.json.tmp"
  chmod 600 "$FM_HOME/config/context-handoff.json.tmp"
  mv "$FM_HOME/config/context-handoff.json.tmp" "$FM_HOME/config/context-handoff.json"
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  extra_sha=$(hash_file "$VAULT/wiki/extra.md")
  expanded=$(printf '%s' "$bundle" | jq -c --arg sha "$extra_sha" '.expected_hashes["wiki/extra.md"]=$sha | .writes += [{path:"wiki/extra.md",mode:"replace",content:"# Extra updated\n"}]')
  result=$(prepare_save "$record" "$expanded")
  [ "$(printf '%s' "$result" | jq -r .code)" = BUNDLE_COUPLED ] || fail "automatic Save accepted an extra replacement"
  pass "single-note automatic Save boundary"
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

test_invalid_candidate_receipts() {
  local case_name candidate result
  for case_name in malformed wrong-mode symlink non-file; do
    new_env "candidate-$case_name"
    register_statement 'Invalid durable candidates must fail closed with a receipt.' >/dev/null || fail "candidate receipt fixture did not register"
    candidate=$(find "$FM_HOME/state/context-handoff/candidates" -name 'candidate-*.json' -print -quit)
    case "$case_name" in
      malformed) printf '{' > "$candidate"; chmod 600 "$candidate" ;;
      wrong-mode) chmod 644 "$candidate" ;;
      symlink) rm "$candidate"; ln -s "$SOURCE_FILE" "$candidate" ;;
      non-file) rm "$candidate"; mkdir "$candidate"; chmod 700 "$candidate" ;;
    esac
    result=$(seal_pi) || fail "invalid candidate escaped seal transport"
    [ "$(printf '%s' "$result" | jq -r .status)" = seal-failed ] || fail "invalid candidate did not block compaction"
    find "$FM_HOME/state/context-handoff/receipts" -name '*.json' -exec jq -e '.reason=="registered-candidate-validation-failed" and (.failure_code | type=="string")' {} \; | grep -q true || fail "invalid candidate failure lacked its durable receipt"
  done
  pass "invalid candidate failures are durably receipted"
}

test_registration_capability_lock() {
  local statement args request state binding cap2 before i response lock_marker lock_release lock_pid stale_pid
  new_env registration-capability
  enable_consumer
  bind_claude >/dev/null || fail "initial Claude binding failed"
  statement='A stale MCP process must not register for its replacement generation.'
  authorize "$statement"
  args=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
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
  if cli register --source-harness pi --kind gotcha --statement "$statement" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --sensitivity-class ordinary-project-context --provider-class anthropic-claude-obsidian > /dev/null 2> "$EROOT/backpressure-error"; then
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

test_envelope_subset_drain() {
  local i statement seal record item_count rounds claims
  new_env envelope-subset
  i=1
  while [ "$i" -le 20 ]; do
    statement="Bounded envelope item $i: $(printf '%01800d' 0 | tr 0 x)"
    register_statement "$statement" >/dev/null || fail "could not register byte-bounded candidate $i"
    i=$((i + 1))
  done
  rounds=0
  while :; do
    claims=$(find "$FM_HOME/state/context-handoff/claims" -type f -name 'candidate-*.json' | wc -l)
    [ "$claims" -lt 20 ] || break
    seal=$(seal_pi) || fail "byte-bounded candidate subset could not seal"
    [ "$(printf '%s' "$seal" | jq -r .status)" = sealed ] || fail "byte-bounded subset returned a terminal seal failure"
    record=$(printf '%s' "$seal" | jq -r .record_id)
    item_count=$(jq '.items | length' "$FM_HOME/state/context-handoff/records/$record.json")
    [ "$item_count" -gt 0 ] && [ "$item_count" -lt 20 ] || fail "seal did not choose a non-empty bounded subset"
    complete "$seal" success >/dev/null || fail "byte-bounded subset compaction could not complete"
    rounds=$((rounds + 1))
    [ "$rounds" -le 4 ] || fail "byte-bounded candidates did not drain"
  done
  [ "$rounds" -ge 2 ] || fail "byte-cap regression did not require multiple deterministic subsets"
  [ "$(find "$FM_HOME/state/context-handoff/claims" -type f -name 'candidate-*.json' | wc -l)" -eq 20 ] || fail "subset drain changed or lost candidate identities"
  pass "deterministic byte-bounded envelope draining"
}

test_monotonic_claude_binding() {
  local stale current
  new_env monotonic-binding
  enable_consumer
  CAPABILITY=claude-process-generation-1
  PROCESS_GENERATION=1
  bind_claude >/dev/null || fail "initial Claude generation did not bind"
  CAPABILITY=claude-process-generation-2
  PROCESS_GENERATION=2
  bind_claude >/dev/null || fail "replacement Claude generation did not bind"
  CAPABILITY=claude-process-generation-1
  PROCESS_GENERATION=1
  bind_claude >/dev/null || fail "retired Claude hook transport failed"
  stale=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$stale" | jq -r .code)" = CONSUMER_SESSION ] || fail "retired hook restored stale MCP authority"
  CAPABILITY=claude-process-generation-2
  PROCESS_GENERATION=2
  current=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$current" | jq -r .status)" = empty ] || fail "current replacement generation lost MCP authority"
  pass "replacement-monotonic Claude session binding"
}

test_claude_precompact_binding_failure() {
  local statement arguments registered foreign blocked
  new_env claude-precompact-binding
  enable_consumer
  bind_claude >/dev/null || fail "Claude binding failed"
  statement='Stop compaction when the exact Claude endpoint becomes unhealthy.'
  authorize "$statement"
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "Claude endpoint failure fixture did not register"
  printf 'unavailable\n' > "$HERDR_MODE"
  foreign=$(jq -nc '{hook_event_name:"PreCompact",session_id:"foreign-session",trigger:"auto"}' | cli claude-hook) || fail "foreign Claude PreCompact did not remain ignorable"
  [ -z "$foreign" ] || fail "foreign Claude session was blocked for another register"
  blocked=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook) || fail "matching Claude PreCompact binding failure escaped the hook"
  printf '%s' "$blocked" | jq -e '.decision=="block"' >/dev/null || fail "unhealthy exact Claude endpoint failed open"
  [ -z "$(find "$FM_HOME/state/context-handoff/records" -type f -print -quit)" ] || fail "unhealthy Herdr endpoint sealed Claude work"
  jq -e 'select(.reason=="claude-precompact-binding-failed")' "$FM_HOME/state/context-handoff/receipts"/*.json >/dev/null || fail "unhealthy Claude PreCompact wrote no durable failure receipt"

  new_env claude-retry-binding
  enable_consumer
  bind_claude >/dev/null || fail "Claude retry binding failed"
  statement='Retryable Claude queues must block when their endpoint becomes unhealthy.'
  authorize "$statement"
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "Claude retry-only fixture did not register"
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "Claude retry-only fixture did not seal"
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"StopFailure",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "Claude retry-only fixture did not record failure"
  printf 'mismatch\n' > "$HERDR_MODE"
  blocked=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook) || fail "retry-only Claude binding failure escaped the hook"
  printf '%s' "$blocked" | jq -e '.decision=="block"' >/dev/null || fail "retryable Claude queue failed open after endpoint failure"
  pass "fail-closed Claude PreCompact endpoint binding"
}

test_lifecycle_and_authority_snapshots() {
  local seal outcome statement arguments registered marker release stale_pid stale_status i record result lock_marker lock_release holder request_pid
  new_env immutable-lifecycle
  register_statement 'Producer lifecycle transitions bind immutable envelope bytes.' >/dev/null || fail "immutable lifecycle fixture did not register"
  seal=$(seal_pi) || fail "immutable lifecycle fixture did not seal"
  printf 'Mutable source changed after durable sealing.\n' > "$SOURCE_FILE"
  jq '.registration_allowlist=[] | .allowed_provider_classes=["retired-provider"]' "$FM_HOME/config/context-handoff.json" > "$FM_HOME/config/context-handoff.json.tmp"
  chmod 600 "$FM_HOME/config/context-handoff.json.tmp"
  mv "$FM_HOME/config/context-handoff.json.tmp" "$FM_HOME/config/context-handoff.json"
  outcome=$(complete "$seal" success) || fail "mutable source stranded a successful compaction"
  [ "$(printf '%s' "$outcome" | jq -r .status)" = compaction-succeeded ] || fail "producer lifecycle revalidated mutable source state"

  new_env retired-precompact
  enable_consumer
  bind_claude >/dev/null || fail "initial Claude generation did not bind"
  statement='Only the active Claude generation may publish a compaction attempt.'
  authorize "$statement"
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "retired PreCompact fixture did not register"
  marker="$EROOT/stale-paused"
  release="$EROOT/stale-release"
  (
    export FM_HANDOFF_TEST_PAUSEPOINT=before-compaction-binding-lock
    export FM_HANDOFF_TEST_PAUSE_MARKER="$marker"
    export FM_HANDOFF_TEST_PAUSE_RELEASE="$release"
    jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook
  ) > "$EROOT/stale-output" 2> "$EROOT/stale-error" &
  stale_pid=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -f "$marker" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$marker" ] || fail "retired PreCompact did not reach its publication boundary"
  CAPABILITY=claude-process-generation-2
  PROCESS_GENERATION=2
  bind_claude >/dev/null || fail "replacement Claude generation did not bind"
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "replacement PreCompact did not publish"
  : > "$release"
  stale_status=0
  wait "$stale_pid" || stale_status=$?
  if [ "$stale_status" -eq 0 ]; then
    jq -e '.decision=="block"' "$EROOT/stale-output" >/dev/null || fail "retired PreCompact retained publication authority"
  fi
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PostCompact",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "replacement PostCompact lost its exact attempt"
  record=$(find "$FM_HOME/state/context-handoff/queue" -type f -name 'handoff-*.json' -exec basename {} .json \;)
  [ "$(jq -r .compaction "$FM_HOME/state/context-handoff/queue/$record.json")" = succeeded ] || fail "retired PreCompact overwrote the replacement attempt"

  new_env stale-mcp-config
  enable_consumer
  make_ready 'Reload configuration inside the serialized MCP transition.' >/dev/null || fail "stale MCP fixture did not become ready"
  bind_claude >/dev/null || fail "stale MCP fixture did not bind"
  lock_marker="$EROOT/state-lock-held"
  lock_release="$EROOT/state-lock-release"
  python3 - "$FM_HOME/state/context-handoff/.lock" "$lock_marker" "$lock_release" <<'PY' &
import fcntl
import os
import pathlib
import sys
import time

fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
pathlib.Path(sys.argv[2]).write_text("held\n")
while not pathlib.Path(sys.argv[3]).exists():
    time.sleep(0.01)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -f "$lock_marker" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$lock_marker" ] || fail "synthetic MCP state lock was not held"
  mcp_content next_curated_handoff > "$EROOT/waiting-mcp" 2> "$EROOT/waiting-mcp-error" &
  request_pid=$!
  sleep 0.2
  jq '.consumer_enabled=false' "$FM_HOME/config/context-handoff.json" > "$FM_HOME/config/context-handoff.json.tmp" || fail "could not revoke MCP configuration"
  chmod 600 "$FM_HOME/config/context-handoff.json.tmp"
  mv "$FM_HOME/config/context-handoff.json.tmp" "$FM_HOME/config/context-handoff.json"
  : > "$lock_release"
  wait "$holder" || fail "synthetic MCP state lock failed"
  wait "$request_pid" || fail "revoked MCP request transport failed"
  result=$(cat "$EROOT/waiting-mcp")
  [ "$(printf '%s' "$result" | jq -r .code)" = CONSUMER_DISABLED ] || fail "waiting MCP request retained stale configuration authority"

  new_env empty-coupled-paths
  enable_consumer
  jq '.consumer.required_coupled_paths=[]' "$FM_HOME/config/context-handoff.json" > "$FM_HOME/config/context-handoff.json.tmp" || fail "could not empty coupled replacement set"
  chmod 600 "$FM_HOME/config/context-handoff.json.tmp"
  mv "$FM_HOME/config/context-handoff.json.tmp" "$FM_HOME/config/context-handoff.json"
  if cli status > "$EROOT/empty-coupled-output" 2> "$EROOT/empty-coupled-error"; then
    fail "empty coupled replacement set enabled automatic Save authority"
  fi
  grep -q 'CONFIG_CONSUMER' "$EROOT/empty-coupled-error" || fail "empty coupled replacement set failed without its contract error"
  pass "immutable lifecycle and serialized authority snapshots"
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

test_serialized_directory_initialization() {
  local first second marker release holder first_pid second_pid i
  new_env serialized-directory-initialization
  rm -rf "$FM_HOME/state/context-handoff"
  first='First concurrent initializer must wait for the durable boundary.'
  second='Second concurrent initializer must share the durable boundary.'
  authorize "$first"
  authorize "$second"
  marker="$EROOT/home-lock-held"
  release="$EROOT/home-lock-release"
  python3 - "$FM_HOME" "$marker" "$release" <<'PY' &
import fcntl
import os
import pathlib
import sys
import time

fd = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
fcntl.flock(fd, fcntl.LOCK_EX)
pathlib.Path(sys.argv[2]).write_text("held\n")
while not pathlib.Path(sys.argv[3]).exists():
    time.sleep(0.01)
fcntl.flock(fd, fcntl.LOCK_UN)
os.close(fd)
PY
  holder=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -f "$marker" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$marker" ] || fail "synthetic durable initialization boundary was not held"
  cli register --source-harness pi --kind gotcha --statement "$first" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --sensitivity-class ordinary-project-context --provider-class anthropic-claude-obsidian > "$EROOT/first-register" 2> "$EROOT/first-error" &
  first_pid=$!
  cli register --source-harness pi --kind gotcha --statement "$second" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --sensitivity-class ordinary-project-context --provider-class anthropic-claude-obsidian > "$EROOT/second-register" 2> "$EROOT/second-error" &
  second_pid=$!
  sleep 0.3
  [ ! -e "$FM_HOME/state/context-handoff" ] || fail "concurrent process bypassed the initialization durability boundary"
  kill -0 "$first_pid" 2>/dev/null && kill -0 "$second_pid" 2>/dev/null || fail "concurrent initializer completed outside the shared boundary"
  : > "$release"
  wait "$holder" || fail "synthetic initialization boundary failed"
  wait "$first_pid" || fail "first serialized initializer failed"
  wait "$second_pid" || fail "second serialized initializer failed"
  [ "$(find "$FM_HOME/state/context-handoff/candidates" -type f -name 'candidate-*.json' | wc -l)" -eq 2 ] || fail "serialized initialization lost a concurrent candidate"
  rm -rf "$FM_HOME/state/context-handoff"
  mkdir -p "$FM_HOME/state/context-handoff"/{candidates,records,claims,queue,receipts,quarantine,acks,approvals,bundles,bindings}
  chmod 700 "$FM_HOME/state/context-handoff" "$FM_HOME/state/context-handoff"/*
  if FM_HANDOFF_TEST_FAILPOINT=before-initialization-boundary-fsync cli status > "$EROOT/orphan-status" 2> "$EROOT/orphan-error"; then
    fail "orphan directory chain skipped its durable initialization boundary"
  fi
  [ ! -e "$FM_HOME/state/context-handoff/.initialized" ] || fail "failed initialization published its durable boundary"
  cli status > /dev/null || fail "orphan directory chain could not recover"
  [ "$(file_mode "$FM_HOME/state/context-handoff/.initialized")" = 600 ] || fail "recovered initialization boundary is not private"
  pass "serialized durable state initialization"
}

test_pi_result_validation() {
  local adapter_root body stale_root
  new_env pi-result-validation
  register_statement 'Cancel Pi compaction only when a non-empty durable register cannot seal.' >/dev/null || fail "Pi lifecycle candidate did not register"
  for case_name in malformed unknown polluted empty disabled exited hanging; do
    adapter_root="$EROOT/$case_name"
    mkdir -p "$adapter_root/bin"
    case "$case_name" in
      malformed) body='{"status":"sealed","bindings":[]}' ;;
      unknown) body='{"status":"surprising"}' ;;
      polluted) body='{"status":"empty","bindings":[]}' ;;
      empty) body='{"status":"empty"}' ;;
      disabled) body='{"status":"disabled"}' ;;
      exited) body=exit ;;
      hanging) body=hang ;;
    esac
    if [ "$body" = exit ]; then
      cat > "$adapter_root/bin/fm-context-handoff.py" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    elif [ "$body" = hang ]; then
      cat > "$adapter_root/bin/fm-context-handoff.py" <<'EOF'
#!/usr/bin/env bash
exec sleep 10
EOF
    else
      cat > "$adapter_root/bin/fm-context-handoff.py" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$body'
EOF
    fi
    chmod 755 "$adapter_root/bin/fm-context-handoff.py"
  done
  stale_root="$EROOT/stale-binding"
  mkdir -p "$stale_root/bin"
  printf 'sealed\n' > "$stale_root/mode"
  : > "$stale_root/log"
  cat > "$stale_root/bin/fm-context-handoff.py" <<'EOF'
#!/usr/bin/env bash
set -u
payload=$(cat)
printf '%s\t%s\n' "$*" "$payload" >> "$FM_STALE_BINDING_LOG"
if [ "$1" = seal ]; then
  if [ "$(cat "$FM_STALE_BINDING_MODE")" = sealed ]; then
    printf '{"status":"sealed","record_id":"handoff-111111111111111111111111111111111111111111111111","envelope_sha256":"2222222222222222222222222222222222222222222222222222222222222222","bindings":[{"record_id":"handoff-111111111111111111111111111111111111111111111111","envelope_sha256":"2222222222222222222222222222222222222222222222222222222222222222"}]}\n'
  else
    printf '{"status":"empty"}\n'
  fi
  exit 0
fi
exit 7
EOF
  chmod 755 "$stale_root/bin/fm-context-handoff.py"
  FM_HOME="$FM_HOME" FM_HANDOFF_TESTING=1 FM_HANDOFF_TEST_NOW="$FIXED_NOW" PI_SESSION_ID=pi-session-1 \
  EXT="$ROOT/.pi/extensions/lib/fm-context-handoff.ts" REAL_ROOT="$ROOT" MISSING="$EROOT/missing" \
  MALFORMED="$EROOT/malformed" UNKNOWN="$EROOT/unknown" POLLUTED="$EROOT/polluted" EMPTY="$EROOT/empty" DISABLED="$EROOT/disabled" EXITED="$EROOT/exited" HANGING="$EROOT/hanging" STALE="$stale_root" \
  FM_STALE_BINDING_MODE="$stale_root/mode" FM_STALE_BINDING_LOG="$stale_root/log" \
  node --input-type=module <<'EOF' || fail "Pi result validation failed"
import fs from "node:fs";
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT).href + `?v=${Date.now()}`);
const ctx = { sessionManager:{ getSessionId(){ return "pi-session-1"; } } };
const lifecycle = new Map();
mod.registerContextHandoff({on(name, handler){lifecycle.set(name, handler);}}, process.env.REAL_ROOT, process.env.FM_HOME);
for (const name of ["session_before_compact","session_compact","session_compact_failed"]) {
  if (!lifecycle.has(name)) throw new Error(`missing lifecycle handler ${name}`);
}
process.env.FM_HANDOFF_TEST_FAILPOINT = "before-file-fsync";
const blocked = await lifecycle.get("session_before_compact")({reason:"threshold"}, ctx);
if (!blocked?.cancel) throw new Error("non-empty seal failure did not cancel Pi compaction");
delete process.env.FM_HANDOFF_TEST_FAILPOINT;
const sealed = await lifecycle.get("session_before_compact")({reason:"overflow"}, ctx);
if (sealed?.cancel) throw new Error("durably sealed candidate cancelled Pi compaction");
await lifecycle.get("session_compact_failed")({reason:"overflow"}, ctx);
const retry = await lifecycle.get("session_before_compact")({reason:"overflow"}, ctx);
if (retry?.cancel) throw new Error("failed Pi compaction did not retain its exact retry binding");
await lifecycle.get("session_compact")({reason:"overflow"}, ctx);
const emptyResult = await lifecycle.get("session_before_compact")({reason:"threshold"}, ctx);
if (emptyResult?.cancel) throw new Error("explicit empty result cancelled Pi compaction");
for (const [root, cancel] of [[process.env.MALFORMED,true],[process.env.UNKNOWN,true],[process.env.POLLUTED,true],[process.env.EMPTY,false],[process.env.DISABLED,false]]) {
  const handlers = new Map();
  mod.registerContextHandoff({on(name, handler){handlers.set(name, handler);}}, root, process.env.FM_HOME);
  const result = await handlers.get("session_before_compact")({reason:"threshold"}, ctx);
  if (Boolean(result?.cancel) !== cancel) throw new Error(`unexpected cancel result for ${root}`);
}
for (const root of [process.env.MISSING, process.env.EXITED]) {
  const handlers = new Map();
  mod.registerContextHandoff({on(name, handler){handlers.set(name, handler);}}, root, process.env.FM_HOME);
  const result = await handlers.get("session_before_compact")({reason:"threshold"}, ctx);
  if (!result?.cancel) throw new Error(`adapter process failure did not cancel Pi compaction: ${root}`);
}
process.env.FM_HANDOFF_TEST_ADAPTER_TIMEOUT_MS = "100";
const hanging = new Map();
mod.registerContextHandoff({on(name, handler){hanging.set(name, handler);}}, process.env.HANGING, process.env.FM_HOME);
const started = Date.now();
const timedOut = await hanging.get("session_before_compact")({reason:"threshold"}, ctx);
if (!timedOut?.cancel || Date.now() - started > 2000) throw new Error("hanging Pi adapter did not cancel within its bound");
const stale = new Map();
mod.registerContextHandoff({on(name, handler){stale.set(name, handler);}}, process.env.STALE, process.env.FM_HOME);
if ((await stale.get("session_before_compact")({reason:"threshold"}, ctx))?.cancel) throw new Error("synthetic stale binding did not seal");
await stale.get("session_compact_failed")({reason:"threshold"});
fs.writeFileSync(process.env.FM_STALE_BINDING_MODE, "empty\n");
if ((await stale.get("session_before_compact")({reason:"threshold"}, ctx))?.cancel) throw new Error("explicit no-op cancelled after outcome failure");
await stale.get("session_compact")({reason:"threshold"});
const calls = fs.readFileSync(process.env.FM_STALE_BINDING_LOG, "utf8").trim().split("\n").filter(line => line.startsWith("compaction-outcome success"));
const payload = JSON.parse(calls.at(-1).split("\t")[1]);
if (Object.hasOwn(payload, "bindings")) throw new Error("prior Pi binding crossed into a later no-op attempt");
EOF
  pass "model-free Pi lifecycle and fail-closed adapter validation"
}

test_installed_pi_success_order() {
  local pi_entry pi_root output expected
  if ! command -v pi >/dev/null 2>&1; then
    if [ "${FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE:-0}" = 1 ] || [ "${FM_CONTEXT_HANDOFF_PI_SUCCESS_PROBE_ONLY:-0}" = 1 ]; then
      fail "required installed Pi success-order probe is unavailable"
    fi
    printf 'skip: pi not found\n'
    return
  fi
  pi_entry=$(realpath "$(command -v pi)")
  pi_root=$(dirname "$(dirname "$(dirname "$pi_entry")")")
  [ -f "$pi_root/dist/core/agent-session.js" ] || fail "installed Pi agent session is unavailable"
  output=$(PI_ROOT="$pi_root" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const { AgentSession } = await import(pathToFileURL(`${process.env.PI_ROOT}/dist/core/agent-session.js`));
const events = [];
let persisted = false;
let entries = [];
const entry = (id, parentId, text) => ({
  type: "message",
  id,
  parentId,
  timestamp: "2026-08-30T20:00:00.000Z",
  message: { role: "user", content: text, timestamp: 1788120000000 },
});
const branch = [entry("old", null, "old ".repeat(5000)), entry("recent", "old", "recent")];
const runner = {
  hasHandlers: () => true,
  async emit(event) {
    if (event.type === "session_before_compact") {
      events.push(`extension:${event.type}:${event.reason}`);
      return { compaction: { summary: "synthetic", firstKeptEntryId: "recent", tokensBefore: 5001 } };
    }
    if (event.type === "session_compact") {
      events.push(`extension:${event.type}:persisted=${persisted}`);
    }
  },
};
const probe = {
  model: { provider: "synthetic" },
  settingsManager: { getCompactionSettings: () => ({ keepRecentTokens: 1 }) },
  sessionManager: {
    getBranch: () => branch,
    appendCompaction(summary, firstKeptEntryId, tokensBefore) {
      persisted = true;
      events.push("persistence:appendCompaction");
      entries = [{ type: "compaction", summary, firstKeptEntryId, tokensBefore }];
    },
    getEntries: () => entries,
    buildSessionContext: () => ({ messages: [] }),
  },
  agent: { state: { messages: [] }, hasQueuedMessages: () => false },
  _extensionRunner: runner,
  _getSummarizationRequestAuth: async model => ({ model, apiKey: undefined, headers: undefined, env: undefined }),
  _runDefaultCompaction: async () => { throw new Error("synthetic extension compaction called a model"); },
  _emit: event => events.push(`public:${event.type}:${event.reason}:aborted=${event.aborted ?? "unset"}`),
  _emitSessionCompactFailed: AgentSession.prototype._emitSessionCompactFailed,
};
const continued = await AgentSession.prototype._runAutoCompaction.call(probe, "threshold", false);
console.log([...events, `continued=${continued}`].join("\n"));
EOF
  ) || fail "installed Pi success-order probe failed"
  expected=$(printf '%s\n' \
    'public:compaction_start:threshold:aborted=unset' \
    'extension:session_before_compact:threshold' \
    'persistence:appendCompaction' \
    'extension:session_compact:persisted=true' \
    'public:compaction_end:threshold:aborted=false' \
    'continued=false')
  [ "$output" = "$expected" ] || fail "installed Pi success event preceded durable compaction persistence"
  printf '%s\n' "$output"
  pass "installed Pi persistence-before-success order"
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
  "$TRANSACTION_INTERPRETER" "$TRANSACTION_CORE" transaction apply "$bundle_path" --vault "$VAULT" --approved-plan-sha256 "$approval" >/dev/null || fail "synthetic apply did not complete"
  rm "$SOURCE_FILE"
  disposition=$(jq -nc --arg record "$record" '{record_id:$record,disposition:"duplicate",rationale:"The durable fact already exists."}')
  result=$(mcp_content record_curation_disposition "$disposition")
  [ "$(printf '%s' "$result" | jq -r .disposition)" = saved ] || fail "missing source blocked completed-Save recovery"
  [ -f "$FM_HOME/state/context-handoff/acks/$record.json" ] || fail "completed Save was not acknowledged"
  [ "$(jq -r .status "$FM_HOME/state/context-handoff/queue/$record.json")" = acknowledged ] || fail "completed Save did not heal queue state"
  pass "completed Save recovery before source validation"
}

test_registration_lifecycle_retries() {
  local first duplicate seal record claim queue recovered failed statement retry status
  new_env registration-lifecycle
  REGISTRATION_ENABLED=false
  write_config
  statement='Registration remains default-off until explicitly enabled.'
  authorize "$statement"
  if cli register --source-harness pi --kind gotcha --statement "$statement" --source-record "$SOURCE_FILE" --source-sha256 "$(hash_file "$SOURCE_FILE")" --confidence verified --sphere privat --sensitivity-class ordinary-project-context --provider-class anthropic-claude-obsidian > /dev/null 2> "$EROOT/disabled-error"; then
    fail "disabled candidate registration succeeded"
  fi
  REGISTRATION_ENABLED=true
  write_config
  first=$(register_statement 'Keep lifecycle retries bound to exact durable bytes.') || fail "enabled registration failed"
  duplicate=$(register_statement 'Keep lifecycle retries bound to exact durable bytes.') || fail "idempotent registration failed"
  [ "$(printf '%s' "$first" | jq -r .candidate_id)" = "$(printf '%s' "$duplicate" | jq -r .candidate_id)" ] || fail "identical registration changed candidate identity"
  seal=$(seal_pi) || fail "registered candidate did not seal"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  [ "$(file_mode "$FM_HOME/state/context-handoff/records/$record.json")" = 600 ] || fail "sealed envelope is not private"
  [ "$(hash_file "$FM_HOME/state/context-handoff/records/$record.json")" = "$(printf '%s' "$seal" | jq -r .envelope_sha256)" ] || fail "sealed envelope hash changed"
  claim="$FM_HOME/state/context-handoff/claims/$(printf '%s' "$first" | jq -r .candidate_id).json"
  queue="$FM_HOME/state/context-handoff/queue/$record.json"
  rm -f "$claim" "$queue"
  recovered=$(seal_pi) || fail "published envelope did not recover"
  [ "$(printf '%s' "$recovered" | jq -r .record_id)" = "$record" ] && [ -f "$claim" ] && [ -f "$queue" ] || fail "orphan envelope recovery changed identity"
  failed=$(complete "$recovered" failure) || fail "provider failure was not recorded"
  [ "$(printf '%s' "$failed" | jq -r .status)" = compaction-failed ] || fail "provider failure was not durable"
  statement='Bind a new candidate into the exact retry attempt.'
  register_statement "$statement" >/dev/null || fail "new retry candidate did not register"
  retry=$(seal_pi) || fail "failed compaction could not retry"
  [ "$(printf '%s' "$retry" | jq '.bindings | length')" -eq 2 ] || fail "retry did not bind old and new records together"
  complete "$retry" success >/dev/null || fail "multi-record retry could not succeed"
  status=$(cli status) || fail "handoff status failed"
  [ "$(printf '%s' "$status" | jq -r .counts.pending)" -eq 2 ] || fail "successful retry did not preserve both pending records"
  pass "registration lifecycle and multi-record retry recovery"
}

test_quarantine_disable_and_disposition_recovery() {
  local seal record result arguments queue before after
  new_env source-quarantine
  enable_consumer
  seal=$(make_ready 'Revalidate the exact source before curation.') || fail "source quarantine fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  printf 'Changed after registration.\n' > "$SOURCE_FILE"
  result=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$result" | jq -r .code)" = SOURCE_HASH_MISMATCH ] || fail "changed source was accepted"
  [ "$(jq -r .status "$FM_HOME/state/context-handoff/queue/$record.json")" = quarantined ] || fail "changed source was not quarantined"

  new_env provider-quarantine
  enable_consumer
  seal=$(make_ready 'Revalidate the provider class before curation.') || fail "provider quarantine fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  jq '.allowed_provider_classes=["different-provider"]' "$FM_HOME/config/context-handoff.json" > "$FM_HOME/config/context-handoff.json.tmp" || fail "could not change provider fixture"
  chmod 600 "$FM_HOME/config/context-handoff.json.tmp"
  mv "$FM_HOME/config/context-handoff.json.tmp" "$FM_HOME/config/context-handoff.json"
  result=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$result" | jq -r .code)" = PROVIDER_CLASS ] || fail "refused provider class was accepted"
  [ "$(jq -r .status "$FM_HOME/state/context-handoff/queue/$record.json")" = quarantined ] || fail "refused provider class was not quarantined"

  new_env payload-quarantine
  enable_consumer
  seal=$(make_ready 'Quarantine changed payload bytes under a stable record identity.') || fail "payload quarantine fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  jq '.items[0].statement="Changed payload under the same stable record ID."' "$FM_HOME/state/context-handoff/records/$record.json" > "$FM_HOME/state/context-handoff/records/$record.json.tmp" || fail "could not mutate payload fixture"
  chmod 600 "$FM_HOME/state/context-handoff/records/$record.json.tmp"
  mv "$FM_HOME/state/context-handoff/records/$record.json.tmp" "$FM_HOME/state/context-handoff/records/$record.json"
  result=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$result" | jq -r .status)" = error ] || fail "changed payload bytes were accepted"
  [ "$(jq -r .status "$FM_HOME/state/context-handoff/queue/$record.json")" = quarantined ] || fail "changed payload bytes were not quarantined"

  new_env disable-reenable
  enable_consumer
  seal=$(make_ready 'Preserve pending records across disable and re-enable.') || fail "disable fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  before=$(hash_file "$FM_HOME/state/context-handoff/records/$record.json")
  SEALING_ENABLED=false
  DELIVERY_ENABLED=false
  CONSUMER_ENABLED=false
  write_config
  result=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$result" | jq -r .code)" = CONSUMER_DISABLED ] || fail "disabled consumer remained active"
  after=$(hash_file "$FM_HOME/state/context-handoff/records/$record.json")
  [ "$before" = "$after" ] || fail "disable changed a pending envelope"
  CONSUMER_ENABLED=true
  write_config
  bind_claude >/dev/null || fail "re-enabled Claude generation did not bind"
  result=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$result" | jq -r .record_id)" = "$record" ] || fail "re-enable did not resume the pending record"
  arguments=$(jq -nc --arg record "$record" '{record_id:$record,disposition:"duplicate",rationale:"The durable fact already exists."}')
  FM_HANDOFF_TEST_FAILPOINT=after-ack-before-queue mcp_response record_curation_disposition "$arguments" > /dev/null 2>&1 || true
  [ -f "$FM_HOME/state/context-handoff/acks/$record.json" ] || fail "disposition crash did not leave a durable acknowledgement"
  queue="$FM_HOME/state/context-handoff/queue/$record.json"
  [ "$(jq -r .status "$queue")" != acknowledged ] || fail "disposition crash passed its queue transition"
  result=$(mcp_content next_curated_handoff)
  [ "$(printf '%s' "$result" | jq -r .status)" = empty ] && [ "$(jq -r .status "$queue")" = acknowledged ] || fail "disposition acknowledgement did not recover"
  pass "quarantine, disable, and disposition recovery"
}

test_transaction_replay_and_rollback() {
  local seal record bundle prepared approval result bundle_path operation transaction_dir
  new_env transaction-replay
  enable_consumer
  seal=$(make_ready) || fail "transaction replay fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  prepared=$(prepare_save "$record" "$bundle") || fail "transaction inspect failed"
  approval=$(printf '%s' "$prepared" | jq -r .approval_sha256)
  result=$(commit_save "$record" "$approval")
  [ "$(printf '%s' "$result" | jq -r .status)" = acknowledged ] || fail "transaction did not acknowledge after verified apply"
  result=$(commit_save "$record" "$approval")
  [ "$(printf '%s' "$result" | jq -r .status)" = acknowledged ] || fail "transaction replay was not idempotent"
  [ ! -e "$VAULT/.vault-meta/mutation.lock" ] || fail "transaction replay left its mutation lock"

  new_env transaction-rollback
  enable_consumer
  seal=$(make_ready 'Recover a rolled-back transaction before acknowledgement.') || fail "rollback fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  prepared=$(prepare_save "$record" "$bundle") || fail "rollback inspect failed"
  approval=$(printf '%s' "$prepared" | jq -r .approval_sha256)
  bundle_path="$FM_HOME/state/context-handoff/bundles/$record/$(printf '%s' "$prepared" | jq -r .bundle_sha256).json"
  if FM_FIXTURE_FAIL_AFTER=1 "$TRANSACTION_INTERPRETER" "$TRANSACTION_CORE" transaction apply "$bundle_path" --vault "$VAULT" --approved-plan-sha256 "$approval" > "$EROOT/crash-output" 2> "$EROOT/crash-error"; then
    fail "synthetic transaction crash unexpectedly completed"
  fi
  [ ! -e "$VAULT/wiki/concepts/Bounded retry.md" ] && [ ! -e "$VAULT/.vault-meta/mutation.lock" ] || fail "transaction crash did not roll back and release its lock"
  [ ! -e "$FM_HOME/state/context-handoff/acks/$record.json" ] || fail "rolled-back transaction was acknowledged"
  result=$(commit_save "$record" "$approval")
  [ "$(printf '%s' "$result" | jq -r .status)" = acknowledged ] || fail "rolled-back transaction did not recover on retry"

  new_env reviewed-result-plan
  enable_consumer
  seal=$(make_ready 'Verify every reviewed changed path before acknowledgement.') || fail "reviewed result fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  prepared=$(prepare_save "$record" "$bundle") || fail "reviewed result inspect failed"
  approval=$(printf '%s' "$prepared" | jq -r .approval_sha256)
  bundle_path="$FM_HOME/state/context-handoff/bundles/$record/$(printf '%s' "$prepared" | jq -r .bundle_sha256).json"
  "$TRANSACTION_INTERPRETER" "$TRANSACTION_CORE" transaction apply "$bundle_path" --vault "$VAULT" --approved-plan-sha256 "$approval" >/dev/null || fail "reviewed result apply failed"
  operation="handoff-$(hash_text "$record" | cut -c1-32)"
  transaction_dir="$VAULT/.vault-meta/transactions/$operation"
  jq '.changed_paths=.changed_paths[0:1] | .hashes=(.hashes | to_entries[0:1] | from_entries)' "$transaction_dir/changed-paths.json" > "$transaction_dir/result.tmp" || fail "could not truncate synthetic result"
  chmod 600 "$transaction_dir/result.tmp"
  mv "$transaction_dir/result.tmp" "$transaction_dir/changed-paths.json"
  jq '.applied=.applied[0:1] | .writes=.writes[0:1]' "$transaction_dir/journal.json" > "$transaction_dir/journal.tmp" || fail "could not truncate synthetic journal"
  chmod 600 "$transaction_dir/journal.tmp"
  mv "$transaction_dir/journal.tmp" "$transaction_dir/journal.json"
  result=$(commit_save "$record" "$approval")
  [ "$(printf '%s' "$result" | jq -r .code)" = TRANSACTION_PATHS ] || fail "truncated transaction evidence matched the reviewed plan"
  [ ! -e "$FM_HOME/state/context-handoff/acks/$record.json" ] || fail "truncated transaction evidence was acknowledged"
  pass "transaction apply replay and rollback recovery"
}

test_orphan_apply_execution_claim() {
  local seal record bundle prepared approval arguments marker release parent result i operation saved_core saved_module saved_interpreter
  saved_core=$TRANSACTION_CORE
  saved_module=$TRANSACTION_MODULE
  saved_interpreter=$TRANSACTION_INTERPRETER
  TRANSACTION_CORE=$CORE
  TRANSACTION_MODULE=$CORE
  TRANSACTION_INTERPRETER=$(realpath "$(command -v bash)")
  new_env spawning-claim-recovery
  enable_consumer
  seal=$(make_ready 'Recover a durable execution claim before any child exists.') || fail "spawning claim fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  prepared=$(prepare_save "$record" "$bundle") || fail "spawning claim inspect failed"
  approval=$(printf '%s' "$prepared" | jq -r .approval_sha256)
  arguments=$(jq -nc --arg record "$record" --arg approval "$approval" '{record_id:$record,approval_sha256:$approval}')
  if (
    export FM_HANDOFF_TEST_EXIT_AFTER_EXECUTION_CLAIM=1
    mcp_response commit_handoff_save "$arguments"
  ) > "$EROOT/spawning-parent-output" 2> "$EROOT/spawning-parent-error"; then
    fail "synthetic MCP parent survived its pre-spawn crash"
  fi
  result=$(mcp_content record_curation_disposition "$(jq -nc --arg record "$record" '{record_id:$record,disposition:"duplicate",rationale:"The durable fact already exists."}')")
  [ "$(printf '%s' "$result" | jq -r .disposition)" = duplicate ] || fail "orphan spawning claim did not recover"
  [ ! -e "$VAULT/wiki/concepts/Bounded retry.md" ] || fail "pre-spawn crash allowed an unclaimed mutation"
  [ ! -e "$FM_HOME/state/context-handoff/bindings/execution-$record.json" ] || fail "recovered spawning claim remained durable"

  new_env orphan-apply-claim
  enable_consumer
  seal=$(make_ready 'Keep terminal disposition behind the durable apply claim.') || fail "orphan apply fixture failed"
  record=$(printf '%s' "$seal" | jq -r .record_id)
  bind_claude >/dev/null || fail "Claude binding failed"
  bundle=$(make_bundle "$record")
  prepared=$(prepare_save "$record" "$bundle") || fail "orphan apply inspect failed"
  approval=$(printf '%s' "$prepared" | jq -r .approval_sha256)
  arguments=$(jq -nc --arg record "$record" --arg approval "$approval" '{record_id:$record,approval_sha256:$approval}')
  marker="$EROOT/apply-child-paused"
  release="$EROOT/apply-child-release"
  (
    export FM_HANDOFF_TEST_EXIT_AFTER_APPLY_SPAWN=1
    export FM_FIXTURE_APPLY_PAUSE_MARKER="$marker"
    export FM_FIXTURE_APPLY_PAUSE_RELEASE="$release"
    mcp_response commit_handoff_save "$arguments"
  ) > "$EROOT/orphan-parent-output" 2> "$EROOT/orphan-parent-error" &
  parent=$!
  if wait "$parent"; then
    fail "synthetic MCP parent survived its post-spawn crash"
  fi
  i=0
  while [ "$i" -lt 300 ] && [ ! -e "$marker" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -e "$marker" ] || fail "orphan transaction child did not reach its pre-mutation pause"
  result=$(mcp_content record_curation_disposition "$(jq -nc --arg record "$record" '{record_id:$record,disposition:"duplicate",rationale:"The durable fact already exists."}')")
  [ "$(printf '%s' "$result" | jq -r .code)" = TRANSACTION_RECOVERY_PENDING ] || fail "terminal disposition bypassed a live orphan apply claim"
  : > "$release"
  operation="handoff-$(hash_text "$record" | cut -c1-32)"
  i=0
  while [ "$i" -lt 500 ] && { [ ! -f "$VAULT/.vault-meta/transactions/$operation/changed-paths.json" ] || [ -e "$VAULT/.vault-meta/mutation.lock" ]; }; do
    sleep 0.01
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 200 ]; do
    result=$(mcp_content record_curation_disposition "$(jq -nc --arg record "$record" '{record_id:$record,disposition:"duplicate",rationale:"The durable fact already exists."}')")
    [ "$(printf '%s' "$result" | jq -r '.disposition // empty')" = saved ] && break
    [ "$(printf '%s' "$result" | jq -r '.code // empty')" = TRANSACTION_RECOVERY_PENDING ] || break
    sleep 0.01
    i=$((i + 1))
  done
  [ "$(printf '%s' "$result" | jq -r .disposition)" = saved ] || fail "completed orphan apply did not recover before disposition"
  TRANSACTION_CORE=$saved_core
  TRANSACTION_MODULE=$saved_module
  TRANSACTION_INTERPRETER=$saved_interpreter
  pass "orphan apply remains behind durable execution authority"
}

test_claude_lifecycle_and_plugin_discovery() {
  local statement arguments registered output marker adapter_status
  new_env claude-plugin
  enable_consumer
  bind_claude >/dev/null || fail "Claude binding failed"
  statement='Preserve only bounded curated bytes across Claude compaction.'
  authorize "$statement" decision
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"decision",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "Claude lifecycle candidate did not register"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"manual",transcript_path:"/forbidden/transcript"}' | cli claude-hook) || fail "Claude PreCompact failed"
  [ -z "$output" ] || fail "successful Claude PreCompact emitted content"
  marker=COMPACT_SUMMARY_MUST_NOT_PERSIST
  if (
    export FM_HANDOFF_TEST_FAILPOINT=after-compaction-terminal-before-queues
    jq -nc --arg session "$CLAUDE_SESSION" --arg marker "$marker" '{hook_event_name:"PostCompact",session_id:$session,trigger:"manual",compact_summary:$marker,transcript_path:"/forbidden/transcript"}' | cli claude-hook
  ) > "$EROOT/crash-post" 2> "$EROOT/crash-post-error"; then
    fail "Claude terminal compaction failpoint unexpectedly completed"
  fi
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"StopFailure",session_id:$session,trigger:"manual"}' | cli claude-hook) || fail "Claude terminal compaction recovery failed"
  [ -z "$output" ] || fail "successful Claude PostCompact emitted content"
  if find "$FM_HOME/state/context-handoff/queue" -name 'handoff-*.json' -exec jq -e '.compaction!="succeeded"' {} \; | grep -q true; then
    fail "opposite Claude outcome reversed a durable terminal result"
  fi
  statement='Retry the exact Claude seal after a provider failure.'
  authorize "$statement" next-step
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"next-step",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "Claude retry candidate did not register"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook) || fail "automatic Claude PreCompact failed"
  [ -z "$output" ] || fail "automatic Claude PreCompact emitted content"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"StopFailure",session_id:$session,trigger:"auto"}' | cli claude-hook) || fail "Claude StopFailure failed"
  [ -z "$output" ] || fail "Claude StopFailure emitted content"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook) || fail "Claude compaction retry failed"
  [ -z "$output" ] || fail "Claude retry emitted content"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" --arg marker "$marker" '{hook_event_name:"PostCompact",session_id:$session,trigger:"auto",compact_summary:$marker}' | cli claude-hook) || fail "Claude retry PostCompact failed"
  [ -z "$output" ] || fail "Claude retry PostCompact emitted content"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"SessionStart",session_id:$session,source:"compact"}' | cli claude-hook) || fail "Claude compact SessionStart failed"
  printf '%s' "$output" | jq -e '.systemMessage | test("bounded record\\(s\\) await Claude curation")' >/dev/null || fail "Claude compact SessionStart omitted bounded pending context"
  if printf '%s' "$output" | grep -q 'handoff-[0-9a-f]'; then
    fail "Claude compact SessionStart exposed a record identity"
  fi
  if grep -R -F -e "$marker" -e /forbidden/transcript "$FM_HOME/state/context-handoff" >/dev/null; then
    fail "Claude lifecycle persisted summary or transcript input"
  fi
  jq -e '.name=="firstmate-context-handoff" and (.version | type=="string")' "$PLUGIN/.claude-plugin/plugin.json" >/dev/null || fail "Claude plugin manifest is not discoverable"
  jq -e '(.hooks | keys | sort)==["PostCompact","PreCompact","PreToolUse","SessionStart","StopFailure"] and all(.hooks[]; length>0 and all(.[]; (.hooks | length)==1 and .hooks[0].type=="command" and .hooks[0].command=="python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/adapter.py\" claude-hook" and (.hooks[0].timeout | type=="number") and .hooks[0].timeout>=10))' "$PLUGIN/hooks/hooks.json" >/dev/null || fail "Claude plugin hook lifecycle contract is incomplete"
  jq -e '.mcpServers["firstmate-context-handoff"] | .command=="python3" and .args==["${CLAUDE_PLUGIN_ROOT}/scripts/adapter.py","mcp-server"]' "$PLUGIN/.mcp.json" >/dev/null || fail "Claude plugin MCP discovery contract is incomplete"
  jq -nc --arg session "$CLAUDE_SESSION" --arg path "$VAULT/blocked.md" '{hook_event_name:"PreToolUse",session_id:$session,tool_name:"Write",tool_input:{file_path:$path,content:"x"}}' | plugin_cli claude-hook > "$EROOT/plugin-out" 2> "$EROOT/plugin-error"
  adapter_status=$?
  [ "$adapter_status" -eq 2 ] && [ ! -s "$EROOT/plugin-out" ] || fail "Claude plugin adapter changed deny transport status"
  jq -e '.hookSpecificOutput.permissionDecision=="deny"' "$EROOT/plugin-error" >/dev/null || fail "Claude plugin adapter did not preserve the mutation guard"
  pass "Claude lifecycle and model-free plugin discovery"
}

test_candidate_identity_binding() {
  local candidate foreign_hash seal
  new_env candidate-identity-binding
  register_statement 'Candidate identity binds its exact source session.' project-fact >/dev/null || fail "candidate identity fixture did not register"
  candidate=$(find "$FM_HOME/state/context-handoff/candidates" -name 'candidate-*.json' -print -quit)
  [ -n "$candidate" ] || fail "candidate identity fixture wrote no candidate"
  foreign_hash=$(session_hash pi pi-session-foreign)
  jq -c --arg hash "$foreign_hash" '.source_session_hash=$hash' "$candidate" > "$EROOT/retargeted.json" || fail "could not retarget the candidate binding"
  cat "$EROOT/retargeted.json" > "$candidate"
  chmod 600 "$candidate"
  seal=$(printf '{"session_id":"pi-session-foreign"}\n' | cli seal --source-harness pi --trigger threshold) || fail "retargeted candidate seal transport failed"
  [ "$(printf '%s' "$seal" | jq -r .status)" = seal-failed ] || fail "retargeted candidate sealed into another session"
  [ -z "$(find "$FM_HOME/state/context-handoff/records" -type f -print -quit)" ] || fail "retargeted candidate produced a sealed record"
  jq -se 'any(.[]; .reason=="registered-candidate-validation-failed" and .failure_code=="CANDIDATE_ID")' "$FM_HOME/state/context-handoff/receipts"/*.json >/dev/null || fail "retargeted candidate wrote no durable identity receipt"
  pass "candidate identity binds its exact source session"
}

test_seal_binding_failure_receipt() {
  local seal
  new_env seal-binding-receipt
  register_statement 'Durable seal receipts survive an unhealthy Vault binding.' >/dev/null || fail "seal binding fixture did not register"
  jq '.vault.inode=999999999' "$FM_HOME/config/context-handoff.json" > "$FM_HOME/config/context-handoff.json.tmp" || fail "could not break the reviewed Vault binding"
  chmod 600 "$FM_HOME/config/context-handoff.json.tmp"
  mv "$FM_HOME/config/context-handoff.json.tmp" "$FM_HOME/config/context-handoff.json"
  seal=$(seal_pi) || fail "unhealthy Vault binding escaped the seal receipt boundary"
  [ "$(printf '%s' "$seal" | jq -r .status)" = seal-failed ] || fail "unhealthy Vault binding did not cancel Pi compaction"
  [ "$(printf '%s' "$seal" | jq -r .reason)" = seal-binding-failed ] || fail "unhealthy Vault binding reported an unrelated seal reason"
  [ -z "$(find "$FM_HOME/state/context-handoff/records" -type f -print -quit)" ] || fail "unhealthy Vault binding sealed a record"
  jq -se 'any(.[]; .reason=="seal-binding-failed" and .failure_code=="VAULT_IDENTITY")' "$FM_HOME/state/context-handoff/receipts"/*.json >/dev/null || fail "unhealthy seal-time binding wrote no durable receipt"
  pass "durable receipt for unhealthy seal-time bindings"
}

test_durable_compaction_attempt() {
  local first second succeeded queues
  new_env durable-compaction-attempt
  register_statement 'First bounded record must survive a crashed compaction outcome.' >/dev/null || fail "first attempt record did not register"
  first=$(seal_pi) || fail "first attempt record did not seal"
  complete "$first" failure >/dev/null || fail "first attempt failure was not recorded"
  register_statement 'Second bounded record joins the same compaction attempt.' next-step >/dev/null || fail "second attempt record did not register"
  second=$(seal_pi) || fail "second attempt seal failed"
  [ "$(printf '%s' "$second" | jq '.bindings | length')" = 2 ] || fail "retry attempt did not bind both records"
  if (
    export FM_HANDOFF_TEST_FAILPOINT=after-compaction-attempt-before-queues
    complete "$second" success
  ) > "$EROOT/attempt-crash-out" 2> "$EROOT/attempt-crash-error"; then
    fail "compaction attempt failpoint unexpectedly completed"
  fi
  succeeded=$(jq -s '[.[] | select(.compaction=="succeeded")] | length' "$FM_HOME"/state/context-handoff/queue/handoff-*.json) || fail "could not read queue state"
  [ "$succeeded" -eq 0 ] || fail "crashed attempt applied a queue transition before persisting its exact result"
  seal_pi >/dev/null || fail "compaction attempt replay transport failed"
  queues=$(find "$FM_HOME/state/context-handoff/queue" -name 'handoff-*.json' | wc -l)
  [ "$queues" -eq 2 ] || fail "durable attempt fixture did not seal two records"
  succeeded=$(jq -s '[.[] | select(.compaction=="succeeded")] | length' "$FM_HOME"/state/context-handoff/queue/handoff-*.json) || fail "could not read replayed queue state"
  [ "$succeeded" -eq 2 ] || fail "crashed compaction attempt lost its exact terminal result"
  pass "durable compaction attempt result replay"
}

test_precompact_generation_and_timeout_margin() {
  local statement arguments registered marker release paused_pid paused_status blocked started elapsed budget i
  new_env precompact-generation-at-seal
  enable_consumer
  bind_claude >/dev/null || fail "generation-at-seal fixture did not bind"
  statement='Seal only while the exact live Claude generation is still bound.'
  authorize "$statement"
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "generation-at-seal fixture did not register"
  marker="$EROOT/seal-paused"
  release="$EROOT/seal-release"
  (
    export FM_HANDOFF_TEST_PAUSEPOINT=before-compaction-binding-lock
    export FM_HANDOFF_TEST_PAUSE_MARKER="$marker"
    export FM_HANDOFF_TEST_PAUSE_RELEASE="$release"
    jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook
  ) > "$EROOT/paused-output" 2> "$EROOT/paused-error" &
  paused_pid=$!
  i=0
  while [ "$i" -lt 200 ] && [ ! -f "$marker" ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -f "$marker" ] || fail "PreCompact did not reach its sealing boundary"
  printf 'mismatch\n' > "$HERDR_MODE"
  : > "$release"
  paused_status=0
  wait "$paused_pid" || paused_status=$?
  [ "$paused_status" -eq 0 ] || fail "replaced-generation PreCompact transport failed"
  jq -e '.decision=="block"' "$EROOT/paused-output" >/dev/null || fail "endpoint replacement between binding and sealing failed open"
  [ -z "$(find "$FM_HOME/state/context-handoff/records" -type f -print -quit)" ] || fail "replaced Claude generation still sealed work"
  jq -se 'any(.[]; .reason=="claude-precompact-binding-failed")' "$FM_HOME/state/context-handoff/receipts"/*.json >/dev/null || fail "replaced generation wrote no durable failure receipt"

  new_env precompact-hang-margin
  enable_consumer
  bind_claude >/dev/null || fail "hanging endpoint fixture did not bind"
  statement='A hanging Herdr probe must still block compaction in time.'
  authorize "$statement"
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "hanging endpoint fixture did not register"
  budget=$(jq -r '.hooks.PreCompact[0].hooks[0].timeout' "$PLUGIN/hooks/hooks.json") || fail "could not read the PreCompact hook budget"
  printf 'hang\n' > "$HERDR_MODE"
  started=$(date +%s)
  blocked=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook) || fail "hanging Herdr probe escaped the PreCompact hook"
  elapsed=$(( $(date +%s) - started ))
  printf '%s' "$blocked" | jq -e '.decision=="block"' >/dev/null || fail "hanging Herdr endpoint failed open"
  [ "$elapsed" -lt "$budget" ] || fail "the Herdr probe consumed the whole PreCompact hook budget"
  [ "$(( elapsed * 2 ))" -le "$budget" ] || fail "PreCompact reserved no fail-closed margin for its receipt and block response"
  jq -se 'any(.[]; .reason=="claude-precompact-binding-failed")' "$FM_HOME/state/context-handoff/receipts"/*.json >/dev/null || fail "hanging Herdr endpoint wrote no durable failure receipt"
  pass "fail-closed Claude generation and probe budget margin"
}

test_sessionstart_pending_eligibility() {
  local statement arguments registered output
  new_env sessionstart-eligibility
  enable_consumer
  bind_claude >/dev/null || fail "SessionStart eligibility fixture did not bind"
  statement='Announce only handoff records the consumer can actually claim.'
  authorize "$statement"
  arguments=$(jq -nc --arg statement "$statement" --arg source "$SOURCE_FILE" --arg sha "$(hash_file "$SOURCE_FILE")" '{kind:"gotcha",statement:$statement,source_record:$source,source_sha256:$sha,confidence:"verified",sphere:"privat",sensitivity_class:"ordinary-project-context",provider_class:"anthropic-claude-obsidian",supersedes:[]}')
  registered=$(mcp_content register_curated_candidate "$arguments")
  [ "$(printf '%s' "$registered" | jq -r .status)" = registered ] || fail "SessionStart eligibility fixture did not register"
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "SessionStart eligibility fixture did not seal"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"SessionStart",session_id:$session,source:"startup"}' | cli claude-hook) || fail "SessionStart transport failed after sealing"
  [ -z "$output" ] || fail "SessionStart announced a record whose compaction never completed"
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"StopFailure",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "SessionStart eligibility fixture did not record its failure"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"SessionStart",session_id:$session,source:"startup"}' | cli claude-hook) || fail "SessionStart transport failed after a compaction failure"
  [ -z "$output" ] || fail "SessionStart announced a failed compaction record"
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PreCompact",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "SessionStart eligibility retry did not seal"
  jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"PostCompact",session_id:$session,trigger:"auto"}' | cli claude-hook >/dev/null || fail "SessionStart eligibility retry did not complete"
  output=$(jq -nc --arg session "$CLAUDE_SESSION" '{hook_event_name:"SessionStart",session_id:$session,source:"startup"}' | cli claude-hook) || fail "SessionStart transport failed after a successful compaction"
  printf '%s' "$output" | jq -e '.systemMessage | test("1 bounded record")' >/dev/null || fail "SessionStart omitted the one consumable record"
  pass "SessionStart announces only consumable records"
}

if [ "${FM_CONTEXT_HANDOFF_PI_SUCCESS_PROBE_ONLY:-0}" = 1 ]; then
  test_installed_pi_success_order
  exit 0
fi

test_required_prerequisite_status
test_sensitive_contracts
test_foreign_candidate_isolation
test_candidate_identity_binding
test_seal_binding_failure_receipt
test_durable_compaction_attempt
test_precompact_generation_and_timeout_margin
test_sessionstart_pending_eligibility
test_single_create_save
test_queue_first_recovery
test_invalid_candidate_receipts
test_registration_capability_lock
test_compaction_backpressure
test_envelope_subset_drain
test_monotonic_claude_binding
test_claude_precompact_binding_failure
test_lifecycle_and_authority_snapshots
test_exit75_requires_fresh_inspect
test_exact_mcp_guard
test_bounded_transports_and_delivery
test_directory_durability
test_serialized_directory_initialization
test_pi_result_validation
test_installed_pi_success_order
test_completed_save_precedes_source_validation
test_registration_lifecycle_retries
test_quarantine_disable_and_disposition_recovery
test_transaction_replay_and_rollback
test_orphan_apply_execution_claim
test_claude_lifecycle_and_plugin_discovery

if [ "${FM_CONTEXT_HANDOFF_REQUIRE_INSTALLED_CORE:-0}" = 1 ]; then
  pass "exact-installed-transaction-core core=$(hash_file "$TRANSACTION_CORE") module=$(hash_file "$TRANSACTION_MODULE")"
fi
