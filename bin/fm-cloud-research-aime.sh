#!/usr/bin/env bash
# Firstmate-owned AIME cloud research executor.
#
# Usage:
#   fm-cloud-research-aime.sh probe [--site <site>] [--space-id <uuid>]
#   fm-cloud-research-aime.sh dispatch <task-id> --instructions <private-file> [--document]
#   fm-cloud-research-aime.sh adopt <task-id>
#   fm-cloud-research-aime.sh state <task-id>
#   fm-cloud-research-aime.sh interrupt-wait <task-id>
#   fm-cloud-research-aime.sh cancel <task-id>
#   fm-cloud-research-aime.sh retire <task-id>
#   fm-cloud-research-aime.sh sandbox-verify --authorize-disposable-session --site <site> --space-id <uuid>
#
# `dispatch` is the only production write entry.
# It requires an existing ordinary Firstmate task directory and brief, plus the
# disabled-by-default config contract owned by bin/fm-aime-cloud-lib.sh.
# The exact research instruction is read by bytedcli from the named private file;
# this script never composes prompt text in argv.
# A document task must already instruct AIME to create the Feishu document and to
# return the machine-readable marker documented by the cloud-research-worker
# skill.
#
# Before either remote write, the local task/provider/site/space/identity and
# exact instruction digest are durable.
# A successful create is checkpointed before send.
# Any create or send whose acceptance is not proven is preserved as
# create-unknown or send-unknown and is never retried automatically.
# Once a remote side effect may have occurred, no provider or site fallback is
# permitted.
#
# `adopt` never repeats create or send after acceptance may be unknown.
# It may issue the first create only from `create-not-started`, while the same
# sandbox-verified configuration is still enabled, or the first send only from
# `created`, where the session identity is durable and no send request started.
# Submitted-session readback works even when the feature was later disabled.
#
# `interrupt-wait` stops only Firstmate's local process-event waiter.
# It records that AIME may still be running and never claims cancellation.
# The current bytedcli contract has no cancellation command, so `cancel` always
# reports cancellation-unsupported without issuing a provider write.
#
# `sandbox-verify` is intentionally mutating and opt-in.
# It creates one disposable empty AIME session, reads that same session back, and
# writes config/aime-cloud-worker with enabled=false and the exact bytedcli
# version.
# Ordinary validation must not invoke it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-aime-cloud-lib.sh
. "$SCRIPT_DIR/fm-aime-cloud-lib.sh"

AIME_PROBE_TIMEOUT=${FM_AIME_PROBE_TIMEOUT:-20}
AIME_WRITE_TIMEOUT=${FM_AIME_WRITE_TIMEOUT:-30}
AIME_STATE_TIMEOUT=${FM_AIME_STATE_TIMEOUT:-15}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

validate_timeout() {
  case "$2" in ''|0|*[!0-9]*) die "$1 must be a positive integer" ;; esac
}

validate_timeout FM_AIME_PROBE_TIMEOUT "$AIME_PROBE_TIMEOUT"
validate_timeout FM_AIME_WRITE_TIMEOUT "$AIME_WRITE_TIMEOUT"
validate_timeout FM_AIME_STATE_TIMEOUT "$AIME_STATE_TIMEOUT"

temp_root() {
  local root
  root=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-aime.XXXXXX") || die "cannot create private temporary storage"
  printf '%s\n' "$root"
}

run_bytedcli_json() { # <timeout> <stdout-file> <stderr-file> <args...>
  local bound=$1 out=$2 err=$3
  shift 3
  : > "$out"
  : > "$err"
  if BYTEDCLI_NO_AUTO_UPGRADE=1 fm_run_timed "$bound" bytedcli --json "$@" >"$out" 2>"$err"; then
    BYTEDCLI_RC=0
  else
    BYTEDCLI_RC=$?
  fi
}

bytedcli_version() {
  local root out err version
  root=$(temp_root)
  out="$root/out"
  err="$root/err"
  run_bytedcli_json "$AIME_PROBE_TIMEOUT" "$out" "$err" --version
  [ "$BYTEDCLI_RC" -eq 0 ] || { rm -rf -- "$root"; return 1; }
  version=$(jq -r '
    if .status == "success" and .error == null
      and (.data.version | type == "string" and length > 0)
    then .data.version
    else empty
    end
  ' "$out" 2>/dev/null)
  rm -rf -- "$root"
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

structured_success() { # <file>
  jq -e '.status == "success" and .error == null and (.data | type != "null")' "$1" >/dev/null 2>&1
}

structured_error() { # <file>
  jq -e '.status == "error" and (.error | type == "object")' "$1" >/dev/null 2>&1
}

normalized_error_file() { # <stdout> <stderr> <destination>
  local out=$1 err=$2 dest=$3
  if jq -e . "$out" >/dev/null 2>&1; then
    cp "$out" "$dest"
  else
    jq -n --rawfile stderr "$err" '{status:"error",error:{message:($stderr | .[0:4096])}}' > "$dest"
  fi
}

probe_json() { # <site> <space-id> <destination>
  local site=$1 space_id=$2 dest=$3 root list_out list_err get_out get_err class version
  root=$(temp_root)
  list_out="$root/list.out"
  list_err="$root/list.err"
  get_out="$root/get.out"
  get_err="$root/get.err"
  version=$(bytedcli_version) || {
    jq -n --arg site "$site" --arg space_id "$space_id" \
      '{schema:"fm-aime-probe.v1",outcome:"unavailable",error_class:"cli-unavailable",site:$site,space_id:$space_id,identity:"user"}' > "$dest"
    rm -rf -- "$root"
    return 1
  }

  run_bytedcli_json "$AIME_PROBE_TIMEOUT" "$list_out" "$list_err" \
    --site "$site" --as user aime space list --limit 100
  if [ "$BYTEDCLI_RC" -ne 0 ] || ! structured_success "$list_out"; then
    normalized_error_file "$list_out" "$list_err" "$root/error.json"
    class=$(fm_aime_error_classify "$root/error.json")
    [ "$BYTEDCLI_RC" -ne 124 ] || class=timeout
    jq -n \
      --arg site "$site" --arg space_id "$space_id" --arg version "$version" --arg class "$class" \
      '{schema:"fm-aime-probe.v1",outcome:(if $class == "unsupported" then "unsupported" else "unavailable" end),error_class:$class,site:$site,space_id:$space_id,identity:"user",bytedcli_version:$version}' > "$dest"
    rm -rf -- "$root"
    return 1
  fi
  if ! jq -e --arg id "$space_id" '
      .data.spaces
      | type == "array"
      and any(.[]; .id == $id and .status == "active"
        and (.permission_actions | type == "array" and index("space.read") != null and index("session.create") != null))
    ' "$list_out" >/dev/null 2>&1; then
    jq -n \
      --arg site "$site" --arg space_id "$space_id" --arg version "$version" \
      '{schema:"fm-aime-probe.v1",outcome:"unsupported",error_class:"space-capability",site:$site,space_id:$space_id,identity:"user",bytedcli_version:$version}' > "$dest"
    rm -rf -- "$root"
    return 1
  fi

  run_bytedcli_json "$AIME_PROBE_TIMEOUT" "$get_out" "$get_err" \
    --site "$site" --as user aime space get --space-id "$space_id"
  if [ "$BYTEDCLI_RC" -ne 0 ] || ! structured_success "$get_out" \
    || [ "$(jq -r '.data.id // ""' "$get_out" 2>/dev/null)" != "$space_id" ]; then
    normalized_error_file "$get_out" "$get_err" "$root/error.json"
    class=$(fm_aime_error_classify "$root/error.json")
    [ "$BYTEDCLI_RC" -ne 124 ] || class=timeout
    jq -n \
      --arg site "$site" --arg space_id "$space_id" --arg version "$version" --arg class "$class" \
      '{schema:"fm-aime-probe.v1",outcome:"unavailable",error_class:$class,site:$site,space_id:$space_id,identity:"user",bytedcli_version:$version}' > "$dest"
    rm -rf -- "$root"
    return 1
  fi

  jq -n \
    --arg site "$site" --arg space_id "$space_id" --arg version "$version" \
    --arg space_name "$(jq -r '.data.name // ""' "$get_out")" \
    '{schema:"fm-aime-probe.v1",outcome:"ready",error_class:null,site:$site,space_id:$space_id,space_name:$space_name,identity:"user",provider:"aime",capabilities:["space.read","session.create","session.get","session.send","session.get-output","session.replay-events"],bytedcli_version:$version}' > "$dest"
  rm -rf -- "$root"
}

cmd_probe() {
  local site='' space_id='' root result rc=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --site) [ "$#" -ge 2 ] || usage; site=$2; shift 2 ;;
      --space-id) [ "$#" -ge 2 ] || usage; space_id=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  if [ -z "$site" ] || [ -z "$space_id" ]; then
    fm_aime_config_load || die "AIME config is missing or invalid; pass --site and --space-id for an explicit read-only probe"
    site=$AIME_CONFIG_SITE
    space_id=$AIME_CONFIG_SPACE_ID
  fi
  fm_aime_site_valid "$site" || die "unsupported AIME site: $site"
  fm_aime_uuid_valid "$space_id" || die "invalid AIME space id"
  root=$(temp_root)
  result="$root/probe.json"
  probe_json "$site" "$space_id" "$result" || rc=$?
  cat "$result"
  rm -rf -- "$root"
  return "$rc"
}

write_failure_report() { # <id> <outcome> <phase> <error-class>
  local id=$1 outcome=$2 phase=$3 error_class=$4 report links owner
  report="$DATA/$id/report.md"
  [ ! -L "$report" ] || return 1
  if [ -e "$report" ]; then
    [ -f "$report" ] || return 1
    links=$(fm_aime_file_links "$report") || return 1
    [ "$links" = 1 ] || return 1
    owner=$(fm_aime_file_owner "$report") || return 1
    [ "$owner" = "$(id -u)" ] || return 1
  fi
  cat > "$report" <<EOF
# AIME cloud research result

- Task: \`$id\`
- Executor: \`cloud-worker\`
- Provider: \`aime\`
- Site: \`$AIME_STATE_SITE\`
- Space: \`$AIME_STATE_SPACE_ID\`
- bytedcli: \`$AIME_STATE_BYTEDCLI_VERSION\`
- Phase: \`$phase\`
- Outcome: \`$outcome\`
- Error class: \`$error_class\`
- Session: \`${AIME_STATE_SESSION_ID:-not checkpointed}\`

The cloud operation did not yield a verified research result.
No provider output is treated as implementation, publication, merge, destructive, or security authority.
The recorded provider identity must be reconciled before any retry when the phase is an acceptance-unknown state.
EOF
  chmod 0600 "$report"
  printf '%s\n' "$report"
}

record_explicit_write_failure() { # <id> <phase> <class>
  local id=$1 phase=$2 class=$3 outcome report
  case "$class" in
    auth) outcome=auth ;;
    unsupported) outcome=unsupported ;;
    rate-limited) outcome=rate-limited ;;
    timeout) outcome=timeout ;;
    unavailable|remote-not-found) outcome=unavailable ;;
    *) outcome=failed ;;
  esac
  fm_aime_state_transition "$id" terminal-failure "$outcome" "$class" "" "" "" "$phase" "" "" not-armed "" \
    || die "cannot record explicit AIME failure"
  fm_aime_state_load "$id" || die "cannot reload AIME failure state"
  report=$(write_failure_report "$id" "$outcome" terminal-failure "$class") \
    || die "cannot write AIME failure report"
  fm_aime_state_transition "$id" terminal-failure "$outcome" "$class" "" "" "" "$phase" "" "$report" not-armed "" \
    || die "cannot checkpoint AIME failure report"
  fm_aime_status_append "$id" "failed: AIME $class before task submission; see data/$id/report.md" \
    || die "cannot append AIME failure event"
}

cmd_dispatch_locked() {
  local id=$1 instructions=$2 result_mode=$3 root probe create_out create_err send_out send_err
  local version instruction_sha session_id message_id class artifact meta_rc
  [ -f "$DATA/$id/brief.md" ] && [ ! -L "$DATA/$id/brief.md" ] \
    || die "ordinary Firstmate brief is missing or unsafe: data/$id/brief.md"
  fm_aime_instruction_validate "$id" "$instructions" || exit 1
  fm_aime_config_load || die "AIME cloud worker is disabled: config is missing or invalid"
  [ "$AIME_CONFIG_ENABLED" = true ] || die "AIME cloud worker is disabled in config"
  version=$(bytedcli_version) || die "bytedcli is unavailable"
  [ "$version" = "$AIME_CONFIG_VERIFIED_VERSION" ] \
    || die "bytedcli version $version does not match sandbox-verified version $AIME_CONFIG_VERIFIED_VERSION"
  fm_aime_task_dir "$id" >/dev/null || die "invalid task id"
  [ ! -e "$(fm_aime_state_path "$id")" ] && [ ! -L "$(fm_aime_state_path "$id")" ] \
    || die "AIME task state already exists; use adopt or state, never redispatch"
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] \
    || die "task metadata already exists; dispatch refuses to replace another executor"

  root=$(temp_root)
  probe="$root/probe.json"
  if ! probe_json "$AIME_CONFIG_SITE" "$AIME_CONFIG_SPACE_ID" "$probe"; then
    cat "$probe"
    rm -rf -- "$root"
    die "AIME read-only capability probe did not pass"
  fi

  instruction_sha=$(fm_aime_sha256_file "$instructions") || {
    rm -rf -- "$root"
    die "cannot hash the AIME instruction file"
  }
  fm_aime_state_initialize "$id" "$AIME_CONFIG_SITE" "$AIME_CONFIG_SPACE_ID" \
    "$result_mode" "$instructions" "$instruction_sha" "$version" \
    || { rm -rf -- "$root"; die "cannot initialize durable AIME task state"; }
  if ! fm_aime_meta_write "$id" "$result_mode"; then
    meta_rc=$?
    rm -rf -- "$(fm_aime_task_dir "$id")"
    rm -rf -- "$root"
    [ "$meta_rc" -eq 2 ] && die "task metadata appeared during AIME preparation"
    die "cannot publish AIME task metadata"
  fi
  fm_aime_artifact_store "$id" probe "$probe" >/dev/null \
    || { rm -rf -- "$root"; die "cannot checkpoint AIME probe"; }

  fm_aime_state_transition "$id" create-not-started "" "" "" "" "" create-intent "" "" not-armed "" \
    || { rm -rf -- "$root"; die "cannot checkpoint AIME create intent"; }
  create_out="$root/create.out"
  create_err="$root/create.err"
  fm_aime_state_transition "$id" create-unknown "" "" "" "" "" create-request-in-flight "" "" not-armed "" \
    || { rm -rf -- "$root"; die "cannot checkpoint AIME create request boundary"; }
  run_bytedcli_json "$AIME_WRITE_TIMEOUT" "$create_out" "$create_err" \
    --site "$AIME_CONFIG_SITE" --as user aime session create \
    --space-id "$AIME_CONFIG_SPACE_ID" --include-context
  if [ "$BYTEDCLI_RC" -eq 0 ] && structured_success "$create_out" \
    && fm_aime_uuid_valid "$(jq -r '.data.id // ""' "$create_out")" \
    && [ "$(jq -r '.data.source_space_id // ""' "$create_out")" = "$AIME_CONFIG_SPACE_ID" ]; then
    session_id=$(jq -r '.data.id' "$create_out")
    artifact=$(fm_aime_artifact_store "$id" create "$create_out") \
      || { rm -rf -- "$root"; die "cannot checkpoint AIME create response"; }
    fm_aime_state_transition "$id" created "" "" "$session_id" "" "" create-accepted "$artifact" "" not-armed "" \
      || { rm -rf -- "$root"; die "cannot checkpoint the AIME session identity"; }
  elif [ "$BYTEDCLI_RC" -ne 124 ] && structured_error "$create_out"; then
    class=$(fm_aime_error_classify "$create_out")
    record_explicit_write_failure "$id" create-rejected "$class"
    rm -rf -- "$root"
    return 1
  else
    normalized_error_file "$create_out" "$create_err" "$root/error.json"
    class=$(fm_aime_error_classify "$root/error.json")
    [ "$BYTEDCLI_RC" -ne 124 ] || class=timeout
    fm_aime_state_transition "$id" create-unknown create-acceptance-unknown "$class" "" "" "" create-acceptance-unknown "" "" not-armed "" \
      || { rm -rf -- "$root"; die "cannot preserve unknown AIME create acceptance"; }
    fm_aime_status_append "$id" "blocked [key=aime-create-unknown]: AIME create acceptance is unknown; do not redispatch" \
      || { rm -rf -- "$root"; die "cannot append AIME create blocker"; }
    rm -rf -- "$root"
    die "AIME create acceptance is unknown; no automatic retry is safe"
  fi

  fm_aime_state_transition "$id" created "" "" "$session_id" "" "" send-intent-durable "" "" not-armed "" \
    || { rm -rf -- "$root"; die "cannot checkpoint AIME send intent"; }
  send_out="$root/send.out"
  send_err="$root/send.err"
  fm_aime_state_transition "$id" send-unknown "" "" "$session_id" "" "" send-request-in-flight "" "" not-armed "" \
    || { rm -rf -- "$root"; die "cannot checkpoint AIME send request boundary"; }
  run_bytedcli_json "$AIME_WRITE_TIMEOUT" "$send_out" "$send_err" \
    --site "$AIME_CONFIG_SITE" --as user aime session send \
    --session-id "$session_id" --content-file "$instructions" --mode agent --execution-mode max
  if [ "$BYTEDCLI_RC" -eq 0 ] && structured_success "$send_out" \
    && [ "$(jq -r '.data.session_id // ""' "$send_out")" = "$session_id" ] \
    && jq -e '.data.auto_session_created == false' "$send_out" >/dev/null 2>&1 \
    && [ -n "$(jq -r '.data.message.message_id // ""' "$send_out")" ]; then
    message_id=$(jq -r '.data.message.message_id' "$send_out")
    artifact=$(fm_aime_artifact_store "$id" send "$send_out") \
      || { rm -rf -- "$root"; die "cannot checkpoint AIME send response"; }
    fm_aime_state_transition "$id" submitted "" "" "$session_id" "$message_id" "" send-accepted "$artifact" "" not-armed "" \
      || { rm -rf -- "$root"; die "cannot checkpoint AIME submission"; }
  elif [ "$BYTEDCLI_RC" -ne 124 ] && structured_error "$send_out"; then
    class=$(fm_aime_error_classify "$send_out")
    record_explicit_write_failure "$id" send-rejected "$class"
    rm -rf -- "$root"
    return 1
  else
    normalized_error_file "$send_out" "$send_err" "$root/error.json"
    class=$(fm_aime_error_classify "$root/error.json")
    [ "$BYTEDCLI_RC" -ne 124 ] || class=timeout
    fm_aime_state_transition "$id" send-unknown send-acceptance-unknown "$class" "$session_id" "" "" send-acceptance-unknown "" "" not-armed "" \
      || { rm -rf -- "$root"; die "cannot preserve unknown AIME send acceptance"; }
    fm_aime_status_append "$id" "blocked [key=aime-send-unknown]: AIME send acceptance is unknown; do not resend" \
      || { rm -rf -- "$root"; die "cannot append AIME send blocker"; }
    rm -rf -- "$root"
    die "AIME send acceptance is unknown; no automatic retry is safe"
  fi

  rm -rf -- "$root"
}

cmd_dispatch() {
  local id=${1-} instructions='' result_mode=research lock dispatch_rc
  [ -n "$id" ] || usage
  shift
  fm_aime_task_id_valid "$id" || die "invalid task id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instructions) [ "$#" -ge 2 ] || usage; instructions=$2; shift 2 ;;
      --document) result_mode=document; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$instructions" ] || die "dispatch requires --instructions <private-file>"
  lock=$(fm_aime_task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock AIME task $id"
  trap 'fm_lock_release "$lock"' EXIT
  cmd_dispatch_locked "$id" "$instructions" "$result_mode"
  dispatch_rc=$?
  fm_lock_release "$lock"
  trap - EXIT
  [ "$dispatch_rc" -eq 0 ] || return "$dispatch_rc"
  "$SCRIPT_DIR/fm-procevent-aime.sh" arm "$id" >/dev/null \
    || die "AIME was submitted but its waiter could not be armed; use adopt"
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null \
    || die "AIME was submitted but process-event reconciliation failed; use adopt"
  fm_aime_state_load "$id" || die "cannot reload submitted AIME state"
  printf 'submitted: %s provider=aime session=%s\n' "$id" "$AIME_STATE_SESSION_ID"
}

cmd_adopt_locked() {
  local id=$1 phase root create_out create_err send_out send_err class artifact
  local session_id message_id instruction_sha version probe probe_checked=0
  fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
  phase=$AIME_STATE_PHASE
  case "$phase" in
    create-unknown)
      die "AIME create acceptance is unknown and no session identity exists; adoption cannot create another session"
      ;;
    send-unknown)
      die "AIME send acceptance is unknown; adoption cannot resend"
      ;;
    terminal-success|terminal-failure)
      return 0
      ;;
  esac
  if [ ! -f "$STATE/$id.meta" ]; then
    fm_aime_meta_write "$id" "$AIME_STATE_RESULT_MODE" \
      || die "cannot repair missing AIME task metadata"
  elif ! fm_aime_meta_validate "$id" "$AIME_STATE_RESULT_MODE"; then
    die "AIME task metadata does not match the recorded cloud task"
  fi
  if [ "$phase" = create-not-started ]; then
    fm_aime_config_load || die "AIME config is missing or invalid; cannot resume a not-started create"
    [ "$AIME_CONFIG_ENABLED" = true ] \
      || die "AIME cloud worker is disabled; cannot resume a not-started create"
    [ "$AIME_CONFIG_SITE" = "$AIME_STATE_SITE" ] \
      && [ "$AIME_CONFIG_SPACE_ID" = "$AIME_STATE_SPACE_ID" ] \
      && [ "$AIME_CONFIG_IDENTITY" = user ] \
      && [ "$AIME_CONFIG_VERIFIED_VERSION" = "$AIME_STATE_BYTEDCLI_VERSION" ] \
      || die "AIME config no longer matches the checkpointed task provider identity"
    version=$(bytedcli_version) || die "bytedcli is unavailable"
    [ "$version" = "$AIME_STATE_BYTEDCLI_VERSION" ] \
      || die "bytedcli version $version does not match the task-pinned version $AIME_STATE_BYTEDCLI_VERSION"
    root=$(temp_root)
    probe="$root/probe.json"
    if ! probe_json "$AIME_STATE_SITE" "$AIME_STATE_SPACE_ID" "$probe"; then
      cat "$probe"
      rm -rf -- "$root"
      die "AIME read-only capability probe did not pass before resumed create"
    fi
    rm -rf -- "$root"
    probe_checked=1
    fm_aime_instruction_validate "$id" "$AIME_STATE_INSTRUCTION_FILE" || exit 1
    instruction_sha=$(fm_aime_sha256_file "$AIME_STATE_INSTRUCTION_FILE") \
      || die "cannot re-hash the AIME instruction file"
    [ "$instruction_sha" = "$AIME_STATE_INSTRUCTION_SHA256" ] \
      || die "AIME instruction file changed before create; refusing create"
    root=$(temp_root)
    create_out="$root/create.out"
    create_err="$root/create.err"
    fm_aime_state_transition "$id" create-unknown "" "" "" "" "" \
      create-request-in-flight "" "" not-armed "" \
      || { rm -rf -- "$root"; die "cannot checkpoint adopted AIME create request boundary"; }
    run_bytedcli_json "$AIME_WRITE_TIMEOUT" "$create_out" "$create_err" \
      --site "$AIME_STATE_SITE" --as user aime session create \
      --space-id "$AIME_STATE_SPACE_ID" --include-context
    if [ "$BYTEDCLI_RC" -eq 0 ] && structured_success "$create_out" \
      && fm_aime_uuid_valid "$(jq -r '.data.id // ""' "$create_out")" \
      && [ "$(jq -r '.data.source_space_id // ""' "$create_out")" = "$AIME_STATE_SPACE_ID" ]; then
      session_id=$(jq -r '.data.id' "$create_out")
      artifact=$(fm_aime_artifact_store "$id" create "$create_out") \
        || { rm -rf -- "$root"; die "cannot checkpoint adopted AIME create response"; }
      fm_aime_state_transition "$id" created "" "" "$session_id" "" "" \
        create-accepted "$artifact" "" not-armed "" \
        || { rm -rf -- "$root"; die "cannot checkpoint the adopted AIME session identity"; }
    elif [ "$BYTEDCLI_RC" -ne 124 ] && structured_error "$create_out"; then
      class=$(fm_aime_error_classify "$create_out")
      record_explicit_write_failure "$id" create-rejected "$class"
      rm -rf -- "$root"
      return 1
    else
      normalized_error_file "$create_out" "$create_err" "$root/error.json"
      class=$(fm_aime_error_classify "$root/error.json")
      [ "$BYTEDCLI_RC" -ne 124 ] || class=timeout
      fm_aime_state_transition "$id" create-unknown create-acceptance-unknown "$class" \
        "" "" "" create-acceptance-unknown "" "" not-armed "" \
        || { rm -rf -- "$root"; die "cannot preserve adopted AIME create acceptance"; }
      fm_aime_status_append "$id" \
        "blocked [key=aime-create-unknown]: AIME create acceptance is unknown; do not redispatch" \
        || { rm -rf -- "$root"; die "cannot append adopted AIME create blocker"; }
      rm -rf -- "$root"
      die "AIME create acceptance is unknown; no automatic retry is safe"
    fi
    rm -rf -- "$root"
    fm_aime_state_load "$id" || die "cannot reload adopted AIME create state"
    phase=$AIME_STATE_PHASE
  fi
  [ -n "$AIME_STATE_SESSION_ID" ] || die "AIME task has no checkpointed session identity"
  if [ "$phase" = created ]; then
    if [ -z "${version:-}" ]; then
      version=$(bytedcli_version) || die "bytedcli is unavailable"
    fi
    [ "$version" = "$AIME_STATE_BYTEDCLI_VERSION" ] \
      || die "bytedcli version $version does not match the task-pinned version $AIME_STATE_BYTEDCLI_VERSION"
    if [ "$probe_checked" -eq 0 ]; then
      root=$(temp_root)
      probe="$root/probe.json"
      if ! probe_json "$AIME_STATE_SITE" "$AIME_STATE_SPACE_ID" "$probe"; then
        cat "$probe"
        rm -rf -- "$root"
        die "AIME read-only capability probe did not pass before resumed send"
      fi
      rm -rf -- "$root"
    fi
    fm_aime_instruction_validate "$id" "$AIME_STATE_INSTRUCTION_FILE" || exit 1
    instruction_sha=$(fm_aime_sha256_file "$AIME_STATE_INSTRUCTION_FILE") \
      || die "cannot re-hash the AIME instruction file"
    [ "$instruction_sha" = "$AIME_STATE_INSTRUCTION_SHA256" ] \
      || die "AIME instruction file changed after create; refusing send"
    root=$(temp_root)
    send_out="$root/send.out"
    send_err="$root/send.err"
    fm_aime_state_transition "$id" send-unknown "" "" \
      "$AIME_STATE_SESSION_ID" "" "" send-request-in-flight "" "" not-armed "" \
      || { rm -rf -- "$root"; die "cannot checkpoint adopted AIME send request boundary"; }
    run_bytedcli_json "$AIME_WRITE_TIMEOUT" "$send_out" "$send_err" \
      --site "$AIME_STATE_SITE" --as user aime session send \
      --session-id "$AIME_STATE_SESSION_ID" --content-file "$AIME_STATE_INSTRUCTION_FILE" \
      --mode agent --execution-mode max
    if [ "$BYTEDCLI_RC" -eq 0 ] && structured_success "$send_out" \
      && [ "$(jq -r '.data.session_id // ""' "$send_out")" = "$AIME_STATE_SESSION_ID" ] \
      && jq -e '.data.auto_session_created == false' "$send_out" >/dev/null 2>&1 \
      && [ -n "$(jq -r '.data.message.message_id // ""' "$send_out")" ]; then
      message_id=$(jq -r '.data.message.message_id' "$send_out")
      artifact=$(fm_aime_artifact_store "$id" send "$send_out") \
        || { rm -rf -- "$root"; die "cannot checkpoint adopted AIME send response"; }
      fm_aime_state_transition "$id" submitted "" "" \
        "$AIME_STATE_SESSION_ID" "$message_id" "" send-accepted \
        "$artifact" "" not-armed "" \
        || { rm -rf -- "$root"; die "cannot checkpoint adopted AIME submission"; }
    elif [ "$BYTEDCLI_RC" -ne 124 ] && structured_error "$send_out"; then
      class=$(fm_aime_error_classify "$send_out")
      record_explicit_write_failure "$id" send-rejected "$class"
      rm -rf -- "$root"
      return 1
    else
      normalized_error_file "$send_out" "$send_err" "$root/error.json"
      class=$(fm_aime_error_classify "$root/error.json")
      [ "$BYTEDCLI_RC" -ne 124 ] || class=timeout
      fm_aime_state_transition "$id" send-unknown send-acceptance-unknown "$class" \
        "$AIME_STATE_SESSION_ID" "" "" send-acceptance-unknown "" "" not-armed "" \
        || { rm -rf -- "$root"; die "cannot preserve adopted AIME send acceptance"; }
      fm_aime_status_append "$id" "blocked [key=aime-send-unknown]: AIME send acceptance is unknown; do not resend" \
        || { rm -rf -- "$root"; die "cannot append adopted AIME send blocker"; }
      rm -rf -- "$root"
      die "AIME send acceptance is unknown; no automatic retry is safe"
    fi
    rm -rf -- "$root"
  fi
}

cmd_adopt() {
  local id=${1-} lock adopt_rc
  [ "$#" -eq 1 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  lock=$(fm_aime_task_lock_path "$id")
  fm_lock_acquire_wait "$lock" || die "cannot lock AIME task $id"
  trap 'fm_lock_release "$lock"' EXIT
  cmd_adopt_locked "$id"
  adopt_rc=$?
  fm_lock_release "$lock"
  trap - EXIT
  [ "$adopt_rc" -eq 0 ] || return "$adopt_rc"
  fm_aime_state_load "$id" || die "cannot reload adopted AIME state"
  case "$AIME_STATE_PHASE" in
    terminal-success|terminal-failure)
      printf 'already-terminal: %s phase=%s\n' "$id" "$AIME_STATE_PHASE"
      return 0
      ;;
  esac
  "$SCRIPT_DIR/fm-procevent-aime.sh" arm "$id" >/dev/null \
    || die "cannot re-arm AIME readback"
  "$SCRIPT_DIR/fm-procevent.sh" reconcile >/dev/null \
    || die "cannot start adopted AIME readback"
  printf 'adopted: %s session=%s\n' "$id" "$AIME_STATE_SESSION_ID"
}

state_from_phase() { # <phase>
  case "$1" in
    submitted|running) printf 'working\n' ;;
    create-not-started|created|create-unknown|send-unknown|result-unavailable) printf 'blocked\n' ;;
    terminal-success) printf 'done\n' ;;
    terminal-failure) printf 'failed\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

cmd_state() {
  local id=${1-} root observation live_class state provider_status terminal output_ready
  [ "$#" -eq 1 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  if ! fm_aime_state_load "$id"; then
    printf 'state: unknown · source: none · invalid or missing AIME task state\n'
    return 0
  fi
  state=$(state_from_phase "$AIME_STATE_PHASE")
  case "$AIME_STATE_PHASE" in
    terminal-success|terminal-failure)
      printf 'state: %s · source: cloud-state · phase=%s outcome=%s\n' \
        "$state" "$AIME_STATE_PHASE" "${AIME_STATE_OUTCOME:-none}"
      return 0
      ;;
    create-not-started|created|create-unknown|send-unknown)
      printf 'state: %s · source: cloud-state · phase=%s outcome=%s\n' \
        "$state" "$AIME_STATE_PHASE" "${AIME_STATE_OUTCOME:-none}"
      return 0
      ;;
  esac
  if [ -z "$AIME_STATE_SESSION_ID" ]; then
    printf 'state: %s · source: cloud-state · phase=%s outcome=%s\n' \
      "$state" "$AIME_STATE_PHASE" "${AIME_STATE_OUTCOME:-none}"
    return 0
  fi
  root=$(temp_root)
  observation="$root/observation.json"
  if ! FM_AIME_READBACK_TIMEOUT="$AIME_STATE_TIMEOUT" \
    "$SCRIPT_DIR/fm-procevent-aime.sh" source "$id" >"$observation" 2>/dev/null \
    || ! jq -e --arg id "$id" --arg session "$AIME_STATE_SESSION_ID" '
      .schema == "fm-aime-observation.v1"
      and .task_id == $id
      and .session_id == $session
    ' "$observation" >/dev/null 2>&1; then
    printf 'state: unknown · source: cloud-readback · phase=%s readback=%s\n' \
      "$AIME_STATE_PHASE" unavailable
    rm -rf -- "$root"
    return 0
  fi
  if ! jq -e '.replay_ok == true and .session_ok == true' "$observation" >/dev/null 2>&1; then
    live_class=$(jq -r '
      [.replay.error_class?,.session.error_class?]
      | map(select(type == "string" and length > 0))
      | first // "unavailable"
    ' "$observation")
    printf 'state: unknown · source: cloud-readback · phase=%s readback=%s\n' \
      "$AIME_STATE_PHASE" "$live_class"
    rm -rf -- "$root"
    return 0
  fi
  provider_status=$(jq -r '.session.data.status // "unknown"' "$observation")
  terminal=$(jq -r '.terminal_candidate == true' "$observation")
  output_ready=$(jq -r '
    .output_ok == true
    and .output.data.finished == true
    and (.output.data.content | type == "string" and length > 0)
  ' "$observation")
  case "$provider_status" in
    failed|error|cancelled|canceled) state=failed ;;
    *)
      if [ "$terminal" = true ] && [ "$output_ready" != true ]; then
        state=blocked
      else
        state=working
      fi
      ;;
  esac
  printf 'state: %s · source: cloud-readback · phase=%s provider-status=%s terminal=%s output-ready=%s\n' \
    "$state" "$AIME_STATE_PHASE" "$provider_status" "$terminal" "$output_ready"
  rm -rf -- "$root"
}

cmd_interrupt_wait() {
  local id=${1-} source lock
  [ "$#" -eq 1 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  lock=$(fm_aime_task_lock_path "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock AIME task $id"
    trap 'fm_lock_release "$lock"' EXIT
    fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
    source=$(fm_aime_source_id "$id") || die "invalid task id"
    "$SCRIPT_DIR/fm-procevent.sh" retire "$source" >/dev/null \
      || die "cannot stop the local AIME waiter"
    fm_aime_state_transition "$id" "$AIME_STATE_PHASE" "$AIME_STATE_OUTCOME" cancellation-unsupported \
      "$AIME_STATE_SESSION_ID" "$AIME_STATE_MESSAGE_ID" "$AIME_STATE_CURSOR" waiter-interrupted \
      "" "" interrupted "" || die "cannot record interrupted AIME waiter"
    printf 'waiter-interrupted: %s; AIME session %s may still be running\n' "$id" "$AIME_STATE_SESSION_ID"
  )
}

cmd_cancel() {
  local id=${1-}
  [ "$#" -eq 1 ] || usage
  fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
  printf 'cancellation-unsupported: current bytedcli has no proven AIME cancellation surface; session %s may continue\n' \
    "${AIME_STATE_SESSION_ID:-unknown}"
  return 3
}

cmd_retire() {
  local id=${1-} source lock
  [ "$#" -eq 1 ] || usage
  fm_aime_task_id_valid "$id" || die "invalid task id"
  lock=$(fm_aime_task_lock_path "$id")
  (
    fm_lock_acquire_wait "$lock" || die "cannot lock AIME task $id"
    trap 'fm_lock_release "$lock"' EXIT
    fm_aime_state_load "$id" || die "AIME task state is missing or invalid"
    case "$AIME_STATE_PHASE" in
      terminal-success|terminal-failure) ;;
      *) die "AIME task is not safely terminal: phase=$AIME_STATE_PHASE" ;;
    esac
    [ -f "$DATA/$id/report.md" ] && [ ! -L "$DATA/$id/report.md" ] \
      || die "AIME task has no safe report at data/$id/report.md"
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-decision-hold.sh" verify "$id" >/dev/null \
      || die "AIME task decision completion gate has not passed"
    source=$(fm_aime_source_id "$id") || die "invalid task id"
    "$SCRIPT_DIR/fm-procevent.sh" retire "$source" >/dev/null \
      || die "cannot retire the AIME process-event source"
    rm -f -- "$STATE/$id.meta" "$STATE/$id.status" "$STATE/$id.turn-ended" \
      "$STATE/.$id.open-decisions-cursor"
    rm -rf -- "$(fm_aime_task_dir "$id")"
    printf 'retired: %s report=data/%s/report.md\n' "$id" "$id"
  )
}

cmd_sandbox_verify() {
  local authorized=0 site='' space_id='' version root probe create_out create_err get_out get_err session_id
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --authorize-disposable-session) authorized=1; shift ;;
      --site) [ "$#" -ge 2 ] || usage; site=$2; shift 2 ;;
      --space-id) [ "$#" -ge 2 ] || usage; space_id=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ "$authorized" -eq 1 ] || die "sandbox verification requires --authorize-disposable-session"
  fm_aime_site_valid "$site" || die "unsupported AIME site"
  fm_aime_uuid_valid "$space_id" || die "invalid AIME space id"
  version=$(bytedcli_version) || die "bytedcli is unavailable"
  root=$(temp_root)
  probe="$root/probe.json"
  probe_json "$site" "$space_id" "$probe" \
    || { cat "$probe"; rm -rf -- "$root"; die "sandbox read-only probe failed"; }
  create_out="$root/create.out"
  create_err="$root/create.err"
  run_bytedcli_json "$AIME_WRITE_TIMEOUT" "$create_out" "$create_err" \
    --site "$site" --as user aime session create --space-id "$space_id" --include-context
  if [ "$BYTEDCLI_RC" -ne 0 ] || ! structured_success "$create_out"; then
    rm -rf -- "$root"
    die "disposable AIME session create was not confirmed; config was not written"
  fi
  session_id=$(jq -r '.data.id // ""' "$create_out")
  fm_aime_uuid_valid "$session_id" \
    || { rm -rf -- "$root"; die "disposable AIME create response had no valid session id"; }
  get_out="$root/get.out"
  get_err="$root/get.err"
  run_bytedcli_json "$AIME_PROBE_TIMEOUT" "$get_out" "$get_err" \
    --site "$site" --as user aime session get --session-id "$session_id"
  [ "$BYTEDCLI_RC" -eq 0 ] && structured_success "$get_out" \
    && [ "$(jq -r '.data.id // ""' "$get_out")" = "$session_id" ] \
    || { rm -rf -- "$root"; die "disposable AIME session readback failed; config was not written"; }
  fm_aime_config_write_verified "$site" "$space_id" "$version" "$(fm_aime_now)" \
    || { rm -rf -- "$root"; die "sandbox passed but disabled config could not be written"; }
  rm -rf -- "$root"
  printf 'sandbox-verified: bytedcli=%s site=%s space=%s session=%s config-disabled=true\n' \
    "$version" "$site" "$space_id" "$session_id"
}

case "${1-}" in
  probe) shift; cmd_probe "$@" ;;
  dispatch) shift; cmd_dispatch "$@" ;;
  adopt) shift; cmd_adopt "$@" ;;
  state) shift; cmd_state "$@" ;;
  interrupt-wait) shift; cmd_interrupt_wait "$@" ;;
  cancel) shift; cmd_cancel "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  sandbox-verify) shift; cmd_sandbox_verify "$@" ;;
  -h|--help|'') usage ;;
  *) usage ;;
esac
