#!/usr/bin/env bash
# Consume one quota-axi snapshot during an ordinary watcher cycle and own automatic quota-threshold episodes.
#
# Usage: fm-auto-quota-drain.sh
#
# The home-local config/auto-quota-drain.json file owns thresholds and trigger-to-position facts only.
# The exact post-drain harness/model/effort tuple belongs exclusively to the durable config/secondmate-harness owner.
# A present automatic-drain config therefore requires a concrete three-token secondmate pin before lifecycle work can begin.
# The evaluator validates every effective provider pool before this script changes episode state or invokes a lifecycle step.
# Stale, absent, malformed, unmeasurable, or contradictory data emits one deduplicated nonblocking diagnostic and performs no lifecycle action.
# The watcher remains the scheduler and singleton; this script creates no daemon, timer, selector service, or handoff protocol.
#
# Action journal state/auto-quota-drain/action-<position> is fm-auto-quota-action.v4 with phase, position, seat,
# home, required_reasoning_class, trigger_provider, percent, candidate_b64, the journal-bound old endpoint identity
# (old_backend, old_target, old_harness, old_model, old_effort) captured before any lifecycle write, optional corr_id,
# and optional error.
# The old endpoint identity is the exact pre-park endpoint bound from seat metadata at plan time; park observes it
# through the existing backend owner rather than whatever mutable seat metadata may carry later.
# Every nonterminal journal resumes before current config or quota validation, reset, or disable handling.
# Resume uses the journal-bound seat and home and refuses identity drift without acting on a replacement.
# A production action advances at most one durable transition per invocation:
#   planned -> checkpoint_pending -> checkpointed -> parking -> parked -> complete.
# The checkpoint correlation id is written before this invocation returns.
# The existing fm_pending_reply_tick owner resolves its marked receipt on a later watcher cycle.
# Graceful exit is requested once, then a later cycle observes the journal-bound old endpoint die and parks it without sleeping.
# The parking phase never declares complete from mutable seat metadata; it advances only on the observed death of the bound old endpoint.
# Relaunch calls the existing fm-spawn.sh --secondmate owner without explicit tuple flags, so config/secondmate-harness
# remains the durable recovery source for this action and for a later bootstrap liveness recovery.
# Completion requires a distinct live endpoint whose tuple and truthful provenance match the durable owner.
# No lifecycle path sleeps waiting for a reply, graceful exit, park, or relaunch.
#
# FM_AUTO_QUOTA_LIFECYCLE_ADAPTER is a unit-test seam for checkpoint, park, and relaunch commands.
# Adapter success means that phase completed synchronously, but perform_action still advances only one phase per invocation.
# Production integration tests leave the seam unset and exercise the real pending-reply, backend park, fm-spawn, and restart owners.
# FM_AUTO_QUOTA_NOW is a test-only zone-qualified instant, and production always uses the current UTC clock.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG_DIR/auto-quota-drain.json"
RUNTIME_DIR="$STATE/auto-quota-drain"
EVALUATOR="$SCRIPT_DIR/fm-auto-quota-drain.mjs"
LIFECYCLE_ADAPTER=${FM_AUTO_QUOTA_LIFECYCLE_ADAPTER:-}
NOW=${FM_AUTO_QUOTA_NOW:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}

case "${1:-}" in
  -h|--help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  '') ;;
  *) echo "error: fm-auto-quota-drain.sh accepts no arguments" >&2; exit 2 ;;
esac

mkdir -p "$RUNTIME_DIR" || exit 1
TMP=$(mktemp "${TMPDIR:-/tmp}/fm-auto-quota-drain.XXXXXX") || exit 1
PLAN_FILE="$TMP.plan"
CONFIG_PLAN_FILE="$TMP.config-plan"
trap 'rm -f -- "$TMP" "$PLAN_FILE" "$CONFIG_PLAN_FILE"' EXIT

hash_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

atomic_line() {
  local file=$1 value=$2 tmp
  tmp="$file.tmp.$$"
  printf '%s\n' "$value" > "$tmp" && mv -f -- "$tmp" "$file"
}

emit_diagnostic() {
  local detail=$1 line fingerprint previous
  line="diagnostic: auto-quota-drain $detail; no lifecycle action taken"
  fingerprint=$(hash_text "$line")
  previous=$(cat "$RUNTIME_DIR/diagnostic" 2>/dev/null || true)
  if [ "$previous" != "$fingerprint" ]; then
    atomic_line "$RUNTIME_DIR/diagnostic" "$fingerprint" || return 1
    printf '%s\n' "$line"
  fi
  return 0
}

meta_get() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2-
}

pool_state_path() {
  printf '%s/pool-%s' "$RUNTIME_DIR" "$1"
}

pool_previous() {
  meta_get "$(pool_state_path "$1")" percent
}

write_pool_state() {
  local provider=$1 percent=$2 warning_open=$3 action_open=$4 file tmp
  file=$(pool_state_path "$provider")
  tmp="$file.tmp.$$"
  {
    printf 'schema=fm-auto-quota-pool.v1\n'
    printf 'percent=%s\n' "$percent"
    printf 'warning_open=%s\n' "$warning_open"
    printf 'action_open=%s\n' "$action_open"
  } > "$tmp" && mv -f -- "$tmp" "$file"
}

number_le() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit !(left <= right) }'
}

number_gt() {
  awk -v left="$1" -v right="$2" 'BEGIN { exit !(left > right) }'
}

one_line() {
  printf '%s\n' "$1" | sed -n '1{s/[[:space:]][[:space:]]*/ /g;s/^ //;s/ $//;p;}' | cut -c1-240
}

base64_decode() {
  if printf '%s' "$1" | base64 --decode 2>/dev/null; then return 0; fi
  printf '%s' "$1" | base64 -D 2>/dev/null
}

journal_write() {
  local file=$1 phase=$2 position=$3 seat=$4 home=$5 required=$6 trigger_provider=$7 percent=$8 candidate=$9
  local old_backend=${10} old_target=${11} old_harness=${12} old_model=${13} old_effort=${14}
  local corr=${15:-} error=${16:-} tmp
  tmp="$file.tmp.$$"
  {
    printf 'schema=fm-auto-quota-action.v4\n'
    printf 'phase=%s\n' "$phase"
    printf 'position=%s\n' "$position"
    printf 'seat=%s\n' "$seat"
    printf 'home=%s\n' "$home"
    printf 'required_reasoning_class=%s\n' "$required"
    printf 'trigger_provider=%s\n' "$trigger_provider"
    printf 'percent=%s\n' "$percent"
    printf 'candidate_b64=%s\n' "$candidate"
    printf 'old_backend=%s\n' "$old_backend"
    printf 'old_target=%s\n' "$old_target"
    printf 'old_harness=%s\n' "$old_harness"
    printf 'old_model=%s\n' "$old_model"
    printf 'old_effort=%s\n' "$old_effort"
    [ -z "$corr" ] || printf 'corr_id=%s\n' "$corr"
    [ -z "$error" ] || printf 'error=%s\n' "$error"
  } > "$tmp" && mv -f -- "$tmp" "$file"
}

journal_field() {
  local file=$1 key=$2 count
  count=$(grep -c "^${key}=" "$file" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  grep "^${key}=" "$file" | cut -d= -f2-
}

journal_load() {
  local file=$1 expected_position=$2 lines key count
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  lines=$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]')
  [ "$lines" -ge 14 ] && [ "$lines" -le 16 ] || return 1
  for key in schema phase position seat home required_reasoning_class trigger_provider percent candidate_b64 \
    old_backend old_target old_harness old_model old_effort; do
    count=$(grep -c "^${key}=" "$file" 2>/dev/null || true)
    [ "$count" -eq 1 ] || return 1
  done
  for key in corr_id error; do
    count=$(grep -c "^${key}=" "$file" 2>/dev/null || true)
    [ "$count" -le 1 ] || return 1
  done
  awk -F= '
    $1 != "schema" && $1 != "phase" && $1 != "position" && $1 != "seat" &&
    $1 != "home" && $1 != "required_reasoning_class" && $1 != "trigger_provider" &&
    $1 != "percent" && $1 != "candidate_b64" && $1 != "old_backend" &&
    $1 != "old_target" && $1 != "old_harness" && $1 != "old_model" &&
    $1 != "old_effort" && $1 != "corr_id" && $1 != "error" { bad=1 }
    END { exit bad }
  ' "$file" || return 1

  [ "$(journal_field "$file" schema)" = fm-auto-quota-action.v4 ] || return 1
  J_PHASE=$(journal_field "$file" phase) || return 1
  J_POSITION=$(journal_field "$file" position) || return 1
  J_SEAT=$(journal_field "$file" seat) || return 1
  J_HOME=$(journal_field "$file" home) || return 1
  J_REQUIRED=$(journal_field "$file" required_reasoning_class) || return 1
  J_PROVIDER=$(journal_field "$file" trigger_provider) || return 1
  J_PERCENT=$(journal_field "$file" percent) || return 1
  J_CANDIDATE_B64=$(journal_field "$file" candidate_b64) || return 1
  J_OLD_BACKEND=$(journal_field "$file" old_backend) || return 1
  J_OLD_TARGET=$(journal_field "$file" old_target) || return 1
  J_OLD_HARNESS=$(journal_field "$file" old_harness) || return 1
  J_OLD_MODEL=$(journal_field "$file" old_model) || return 1
  J_OLD_EFFORT=$(journal_field "$file" old_effort) || return 1
  J_CORR=$(meta_get "$file" corr_id)
  [ "$J_POSITION" = "$expected_position" ] || return 1
  printf '%s\n' "$J_POSITION" "$J_SEAT" "$J_REQUIRED" "$J_PROVIDER" "$J_OLD_BACKEND" "$J_OLD_HARNESS" \
    | grep -Ev '^[A-Za-z0-9._-]{1,96}$' | grep -q . && return 1
  [ -n "$J_HOME" ] && [ -n "$J_OLD_TARGET" ] && [ -n "$J_OLD_MODEL" ] && [ -n "$J_OLD_EFFORT" ] || return 1
  case "$J_PHASE" in planned|checkpoint_pending|checkpointed|parking|parked|complete|refused) ;; *) return 1 ;; esac
  J_CANDIDATE=$(base64_decode "$J_CANDIDATE_B64") || return 1
  printf '%s' "$J_CANDIDATE" | jq -e '
    type == "object" and
    (keys | sort) == ["effort","harness","headroom","model","modelFamily","provider","reasoningClass","runway"] and
    all(.harness,.provider,.modelFamily,.effort,.reasoningClass,.headroom,.runway;
      type == "string" and length >= 1 and length <= 96 and test("^[A-Za-z0-9._/-]+$")) and
    (.model | type == "string" and length >= 1 and length <= 160 and test("^[A-Za-z0-9._/-]+$"))
  ' >/dev/null 2>&1 || return 1
}

validate_bound_identity() {
  local position_json=$1 meta="$STATE/$J_SEAT.meta" current
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo "journal-bound secondmate metadata is unavailable" >&2; return 1; }
  [ "$(meta_get "$meta" kind)" = secondmate ] || { echo "journal-bound seat is no longer a secondmate" >&2; return 1; }
  [ "$(meta_get "$meta" home)" = "$J_HOME" ] || { echo "journal-bound secondmate home drifted" >&2; return 1; }
  [ -z "$(meta_get "$meta" remote_host)" ] || { echo "journal-bound seat became remote" >&2; return 1; }
  [ -n "$position_json" ] || return 0
  current=$(printf '%s' "$position_json" | jq -r '[.position,.seat,.provider,.postDrainProvider,.postDrainModelFamily,.requiredReasoningClass,.postDrainReasoningClass] | @tsv') || return 1
  [ "$current" = "$J_POSITION"$'\t'"$J_SEAT"$'\t'"$J_PROVIDER"$'\t'"$(printf '%s' "$J_CANDIDATE" | jq -r '.provider')"$'\t'"$(printf '%s' "$J_CANDIDATE" | jq -r '.modelFamily')"$'\t'"$J_REQUIRED"$'\t'"$(printf '%s' "$J_CANDIDATE" | jq -r '.reasoningClass')" ] || {
    echo "journal-bound position or candidate drifted" >&2
    return 1
  }
}

validate_local_seat() {
  local seat=$1 home=$2 meta
  meta="$STATE/$seat.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { echo "secondmate metadata is unavailable" >&2; return 1; }
  [ "$(meta_get "$meta" kind)" = secondmate ] || { echo "record is not a secondmate seat" >&2; return 1; }
  [ "$(meta_get "$meta" home)" = "$home" ] || { echo "secondmate home no longer matches its position" >&2; return 1; }
  [ -z "$(meta_get "$meta" remote_host)" ] || { echo "remote secondmate seats are outside this first slice" >&2; return 1; }
}

checkpoint_expectation_recoverable() {
  local seat=$1 corr=$2 rec phase delivered marker
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] \
    && [ "$(fm_pending_reply_get "$rec" corr_id)" = "$corr" ] \
    && [ "$(fm_pending_reply_get "$rec" task_id)" = "$seat" ] || return 1
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    awaiting_report)
      delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
      [ -n "$delivered" ] && return 0
      marker=$(fm_pending_reply_delivery_confirmation_path "$STATE" "$corr")
      grep -Eq '^confirmed=[0-9]+$' "$marker" 2>/dev/null
      ;;
    delivery_unknown|recovery_sending|recovery_sent|recovery_failed|recovery_unknown|escalated|resolved) return 0 ;;
    *) return 1 ;;
  esac
}

production_checkpoint() {
  local seat=$1 home=$2 provider=$3 percent=$4 corr message rec
  validate_local_seat "$seat" "$home" || return 1
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
  message="Quota action checkpoint for pool $provider at $percent percent remaining. Run /stow completely through its completion receipt before any further routed work. If and only if the stow pass is sealed, append a parent status line containing 'done: auto quota drain checkpoint sealed' and the injected corr token. Report a blocked or failed line with the same corr token instead of exiting when the checkpoint cannot seal."
  corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$seat" "$message") || { echo "checkpoint expectation could not be recorded" >&2; return 1; }
  if ! fm_pending_reply_prepare_delivery "$STATE" "$corr"; then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    echo "checkpoint delivery could not be prepared" >&2
    return 1
  fi
  if ! FM_PENDING_REPLY_EXISTING_CORR="$corr" FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$seat" "$message" >/dev/null; then
    rec=$(fm_pending_reply_path "$STATE" "$corr")
    if checkpoint_expectation_recoverable "$seat" "$corr"; then
      printf 'pending:%s\n' "$corr"
      return 0
    fi
    if fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 && [ ! -e "$rec" ]; then
      echo "checkpoint steer was not durably delivered" >&2
      return 1
    fi
    printf 'pending:%s\n' "$corr"
    return 0
  fi
  printf 'pending:%s\n' "$corr"
}

production_checkpoint_receipt() {
  local seat=$1 corr=$2 rec phase line
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$SCRIPT_DIR/fm-pending-reply-lib.sh"
  rec=$(fm_pending_reply_path "$STATE" "$corr")
  [ -f "$rec" ] || { echo "checkpoint expectation is unavailable" >&2; return 1; }
  phase=$(fm_pending_reply_get "$rec" phase)
  case "$phase" in
    resolved) ;;
    escalated) echo "checkpoint report escalation did not seal the stow pass" >&2; return 1 ;;
    awaiting_report|delivery_unknown|recovery_sending|recovery_sent|recovery_failed|recovery_unknown) return 75 ;;
    *) echo "checkpoint expectation phase is invalid" >&2; return 1 ;;
  esac
  line=$(fm_pending_reply_find_resolve_line "$STATE/$seat.status" "$corr")
  case "$line" in
    'done: auto quota drain checkpoint sealed'*"corr=$corr"*) return 0 ;;
    *) echo "checkpoint reply did not seal the stow pass" >&2; return 1 ;;
  esac
}

production_park() {
  local seat=$1 home=$2 old_backend=$3 old_target=$4 old_harness=$5 meta command dirty
  validate_local_seat "$seat" "$home" || return 1
  [ -n "$old_backend" ] && [ -n "$old_target" ] && [ -n "$old_harness" ] || { echo "journal-bound old endpoint identity is unavailable" >&2; return 1; }
  dirty=$(git -C "$home" status --porcelain --untracked-files=all 2>/dev/null) || { echo "REFUSED: secondmate home work status is unreadable" >&2; return 1; }
  [ -z "$dirty" ] || { echo "REFUSED: unlanded work remains in the secondmate home" >&2; return 1; }
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  case "$old_harness" in
    cursor-agent)
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$old_target" --key C-d >/dev/null || { echo "graceful Cursor exit was not delivered" >&2; return 1; }
      ;;
    claude|opencode|grok|kimi) command=/exit ;;
    codex|pi|pi-signed) command=/quit ;;
    *) echo "secondmate harness is not verified for graceful exit" >&2; return 1 ;;
  esac
  if [ "$old_harness" != cursor-agent ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$old_target" "$command" >/dev/null || { echo "graceful harness exit was not delivered" >&2; return 1; }
  fi
  printf 'pending\n'
}

production_park_status() {
  local seat=$1 home=$2 old_backend=$3 old_target=$4 backend target agent_state
  validate_local_seat "$seat" "$home" || return 1
  [ -n "$old_backend" ] && [ -n "$old_target" ] || { echo "journal-bound old endpoint identity is unavailable" >&2; return 1; }
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  backend=$old_backend
  target=$old_target
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  case "$agent_state" in
    alive|ambiguous|unreadable|unverified) return 75 ;;
    missing) return 0 ;;
    dead)
      fm_backend_kill "$backend" "$target" >/dev/null 2>&1 || { echo "exited secondmate endpoint could not be parked" >&2; return 1; }
      return 0
      ;;
    *) echo "graceful harness exit state is invalid" >&2; return 1 ;;
  esac
}

production_relaunch() {
  local seat=$1 home=$2 harness=$3 model=$4 effort=$5 out meta backend target agent_state
  meta="$STATE/$seat.meta"
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  if [ -n "$target" ] \
    && agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) \
    && [ "$agent_state" = alive ] \
    && [ "$(meta_get "$meta" home)" = "$home" ] \
    && [ "$(meta_get "$meta" harness)" = "$harness" ] \
    && [ "$(meta_get "$meta" model)" = "$model" ] \
    && [ "$(meta_get "$meta" effort)" = "$effort" ] \
    && [ "$(meta_get "$meta" routing_source)" = secondmate-config ]; then
    # A distinct live endpoint with the durable tuple and truthful provenance already
    # exists (e.g. bootstrap liveness recovery relaunched the seat between cycles).
    # The launch owner already reconciled; do not issue a duplicate launch.
    printf 'reconciled\n'
    return 0
  fi
  out=$(FM_SPAWN_NO_GUARD=1 FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-spawn.sh" "$seat" --secondmate 2>&1) || { one_line "$out" >&2; return 1; }
  meta="$STATE/$seat.meta"
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { echo "relaunched seat has no endpoint" >&2; return 1; }
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
  [ "$agent_state" = alive ] || { echo "relaunched endpoint is not alive" >&2; return 1; }
  [ "$(meta_get "$meta" home)" = "$home" ] \
    && [ "$(meta_get "$meta" harness)" = "$harness" ] \
    && [ "$(meta_get "$meta" model)" = "$model" ] \
    && [ "$(meta_get "$meta" effort)" = "$effort" ] \
    && [ "$(meta_get "$meta" routing_source)" = secondmate-config ] \
    || { echo "relaunched seat did not reuse its durable secondmate tuple and provenance" >&2; return 1; }
  printf 'launched\n'
  return 0
}

run_lifecycle() {
  local command=$1
  shift
  if [ -n "$LIFECYCLE_ADAPTER" ]; then
    "$LIFECYCLE_ADAPTER" "$command" "$@"
    return $?
  fi
  case "$command" in
    checkpoint) production_checkpoint "$@" ;;
    checkpoint-receipt) production_checkpoint_receipt "$@" ;;
    park) production_park "$@" ;;
    park-status) production_park_status "$@" ;;
    relaunch) production_relaunch "$@" ;;
    *) echo "unknown lifecycle command" >&2; return 2 ;;
  esac
}

resolve_candidate() {
  local position_json=$1 tuple harness model effort provider model_family expected_provider expected_family reasoning headroom runway cooldown_rc stderr_out rc
  stderr_out=$(mktemp "${TMPDIR:-/tmp}/fm-auto-quota-drain.stderr.XXXXXX") || return 1
  tuple=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG_DIR" "$SCRIPT_DIR/fm-harness.sh" secondmate-tuple-facts 2>"$stderr_out") || rc=$?
  if [ "${rc:-0}" -ne 0 ]; then
    one_line "$(cat "$stderr_out" 2>/dev/null)" >&2
    rm -f -- "$stderr_out"
    return 1
  fi
  rm -f -- "$stderr_out"
  [ -n "$tuple" ] || { echo "secondmate tuple resolved empty" >&2; return 1; }
  IFS=$'\t' read -r harness model effort provider model_family <<EOF
$tuple
EOF
  expected_provider=$(printf '%s' "$position_json" | jq -r '.postDrainProvider')
  expected_family=$(printf '%s' "$position_json" | jq -r '.postDrainModelFamily')
  if [ "$provider" != "$expected_provider" ] || [ "$model_family" != "$expected_family" ]; then
    echo "durable secondmate tuple catalog facts do not match the configured post-drain provider/model family" >&2
    return 1
  fi
  reasoning=$(printf '%s' "$position_json" | jq -r '.postDrainReasoningClass')
  headroom=$(jq -r --arg provider "$provider" '.providers[] | select(.provider==$provider) | .headroom' "$PLAN_FILE")
  runway=$(jq -r --arg provider "$provider" '.providers[] | select(.provider==$provider) | .runway' "$PLAN_FILE")
  cooldown_rc=0
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-quota-cooldown.sh" authorize \
    --harness "$harness" --provider "$provider" --model-family "$model_family" >/dev/null 2>&1 || cooldown_rc=$?
  case "$cooldown_rc" in
    0) ;;
    3) echo "durable secondmate tuple is under an active routing cooldown" >&2; return 1 ;;
    *) echo "routing cooldown evidence is unreadable" >&2; return 1 ;;
  esac
  jq -cn --arg harness "$harness" --arg provider "$provider" --arg modelFamily "$model_family" \
    --arg model "$model" --arg effort "$effort" --arg reasoningClass "$reasoning" \
    --arg headroom "$headroom" --arg runway "$runway" \
    '{harness:$harness,provider:$provider,modelFamily:$modelFamily,model:$model,effort:$effort,reasoningClass:$reasoningClass,headroom:$headroom,runway:$runway}'
}

candidate_pool_available() {
  local candidate=$1 provider percent action
  provider=$(printf '%s' "$candidate" | jq -r '.provider')
  percent=$(jq -r --arg provider "$provider" '.providers[] | select(.provider==$provider) | .percentRemaining' "$PLAN_FILE")
  action=$(jq -r '.actionPercentRemaining' "$PLAN_FILE")
  [ -n "$percent" ] && number_gt "$percent" "$action"
}

perform_action() {
  local provider=$1 percent=$2 position_json=$3 journal_override=${4:-}
  local position seat home required journal phase candidate_b64 candidate corr harness model effort reasoning out detail rc
  local old_backend old_target old_harness old_model old_effort relaunch_verb relaunch_phrase expected_position existing=0
  if [ -n "$journal_override" ]; then
    journal=$journal_override
    expected_position=${journal##*/action-}
    existing=1
  else
    position=$(printf '%s' "$position_json" | jq -r '.position')
    journal="$RUNTIME_DIR/action-$position"
    phase=$(meta_get "$journal" phase)
    case "$phase" in complete|refused) return 0 ;; esac
    if [ -n "$phase" ]; then
      expected_position=$position
      existing=1
    else
      seat=$(printf '%s' "$position_json" | jq -r '.seat')
      required=$(printf '%s' "$position_json" | jq -r '.requiredReasoningClass')
      home=$(meta_get "$STATE/$seat.meta" home)
      if [ -z "$home" ]; then
        emit_diagnostic "seat $seat metadata is unavailable"
        return 0
      fi
      if ! candidate=$(resolve_candidate "$position_json" 2>&1); then
        emit_diagnostic "seat $seat $(one_line "$candidate")"
        return 0
      fi
      if ! candidate_pool_available "$candidate"; then
        emit_diagnostic "seat $seat post-drain pool is not above the action threshold"
        return 0
      fi
      candidate_b64=$(printf '%s' "$candidate" | base64 | tr -d '\n')
      # shellcheck source=bin/fm-backend.sh
      . "$SCRIPT_DIR/fm-backend.sh"
      old_backend=$(fm_backend_of_meta "$STATE/$seat.meta")
      old_target=$(fm_backend_target_of_meta "$STATE/$seat.meta")
      old_harness=$(meta_get "$STATE/$seat.meta" harness)
      old_model=$(meta_get "$STATE/$seat.meta" model)
      old_effort=$(meta_get "$STATE/$seat.meta" effort)
      if [ -z "$old_target" ] || [ -z "$old_harness" ] || [ -z "$old_model" ] || [ -z "$old_effort" ]; then
        emit_diagnostic "seat $seat has no live old endpoint identity to bind"
        return 0
      fi
      corr=
      journal_write "$journal" planned "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
        "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" || return 1
      write_pool_state "$provider" "$percent" 1 1 || return 1
      expected_position=$position
      existing=1
    fi
  fi

  if [ "$existing" -eq 1 ] && ! journal_load "$journal" "$expected_position"; then
    emit_diagnostic "recovery journal $expected_position is malformed"
    return 0
  fi
  phase=$J_PHASE
  case "$phase" in complete|refused) return 0 ;; esac
  position=$J_POSITION
  seat=$J_SEAT
  home=$J_HOME
  required=$J_REQUIRED
  provider=$J_PROVIDER
  percent=$J_PERCENT
  candidate_b64=$J_CANDIDATE_B64
  candidate=$J_CANDIDATE
  corr=$J_CORR
  old_backend=$J_OLD_BACKEND
  old_target=$J_OLD_TARGET
  old_harness=$J_OLD_HARNESS
  old_model=$J_OLD_MODEL
  old_effort=$J_OLD_EFFORT
  if ! detail=$(validate_bound_identity "$position_json" 2>&1); then
    emit_diagnostic "seat $seat $(one_line "$detail")"
    return 0
  fi
  harness=$(printf '%s' "$candidate" | jq -r '.harness')
  model=$(printf '%s' "$candidate" | jq -r '.model')
  effort=$(printf '%s' "$candidate" | jq -r '.effort')
  reasoning=$(printf '%s' "$candidate" | jq -r '.reasoningClass')
  if [ "$reasoning" != "$required" ]; then
    emit_diagnostic "seat $seat recovery journal would downgrade the required reasoning class"
    return 0
  fi

  case "$phase" in
    planned)
      if ! out=$(run_lifecycle checkpoint "$seat" "$home" "$provider" "$percent" 2>&1); then
        detail=$(one_line "$out")
        journal_write "$journal" refused "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
          "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "" "$detail" || return 1
        printf 'diagnostic: auto-quota-drain %s checkpoint refused: %s; no later lifecycle step ran\n' "$seat" "$detail"
        return 0
      fi
      if [ -n "$LIFECYCLE_ADAPTER" ]; then
        journal_write "$journal" checkpointed "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
          "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" || return 1
      else
        corr=$(printf '%s\n' "$out" | sed -n 's/^pending:\([a-f0-9]\{16\}\)$/\1/p' | tail -1)
        printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || {
          journal_write "$journal" refused "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
            "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "" "checkpoint correlation is malformed" || return 1
          printf 'diagnostic: auto-quota-drain %s checkpoint refused: checkpoint correlation is malformed; no later lifecycle step ran\n' "$seat"
          return 0
        }
        journal_write "$journal" checkpoint_pending "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
          "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "$corr" || return 1
      fi
      return 0
      ;;
    checkpoint_pending)
      run_lifecycle checkpoint-receipt "$seat" "$corr" >/dev/null 2>&1
      rc=$?
      case "$rc" in
        0) journal_write "$journal" checkpointed "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
             "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "$corr" || return 1 ;;
        75) return 0 ;;
        *)
          detail="checkpoint reply did not seal the stow pass"
          journal_write "$journal" refused "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
            "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "$corr" "$detail" || return 1
          printf 'diagnostic: auto-quota-drain %s checkpoint refused: %s; no later lifecycle step ran\n' "$seat" "$detail"
          ;;
      esac
      return 0
      ;;
    checkpointed)
      if ! out=$(run_lifecycle park "$seat" "$home" "$old_backend" "$old_target" "$old_harness" 2>&1); then
        detail=$(one_line "$out")
        journal_write "$journal" refused "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
          "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "" "$detail" || return 1
        printf 'diagnostic: auto-quota-drain %s park refused: %s; no relaunch ran\n' "$seat" "$detail"
        return 0
      fi
      if [ -n "$LIFECYCLE_ADAPTER" ]; then
        journal_write "$journal" parked "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
          "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" || return 1
      else
        journal_write "$journal" parking "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
          "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "$corr" || return 1
      fi
      return 0
      ;;
    parking)
      # The parking phase advances only by observing the journal-bound old endpoint die.
      # It never declares complete from mutable seat metadata or a still-live old process.
      run_lifecycle park-status "$seat" "$home" "$old_backend" "$old_target" >/dev/null 2>&1
      rc=$?
      case "$rc" in
        0) journal_write "$journal" parked "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
             "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "$corr" || return 1 ;;
        75) return 0 ;;
        *)
          detail="graceful harness exit could not be confirmed"
          printf 'diagnostic: auto-quota-drain %s park refused: %s; no relaunch ran\n' "$seat" "$detail"
          return 0
          ;;
      esac
      return 0
      ;;
    parked)
      if ! out=$(run_lifecycle relaunch "$seat" "$home" "$harness" "$model" "$effort" 2>&1); then
        detail=$(one_line "$out")
        journal_write "$journal" parked "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
          "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "$corr" "$detail" || return 1
        printf 'diagnostic: auto-quota-drain %s relaunch refused after a sealed checkpoint and park: %s\n' "$seat" "$detail"
        return 0
      fi
      # The relaunch owner reports the action it actually performed: "launched" when
      # it called the launch owner, or "reconciled" when a distinct live durable
      # endpoint already existed (e.g. bootstrap liveness recovery). The terminal
      # attestation echoes only that action, never a hardcoded park/relaunch claim.
      relaunch_verb=$(printf '%s' "$out" | sed -n '1p')
      case "$relaunch_verb" in
        launched) relaunch_phrase='relaunched from durable config' ;;
        reconciled) relaunch_phrase='reconciled to a durable-config endpoint' ;;
        *) relaunch_phrase='relaunched from durable config' ;;
      esac
      journal_write "$journal" complete "$position" "$seat" "$home" "$required" "$provider" "$percent" "$candidate_b64" \
        "$old_backend" "$old_target" "$old_harness" "$old_model" "$old_effort" "$corr" || return 1
      ;;
    *) emit_diagnostic "seat $seat recovery journal has an unknown phase"; return 0 ;;
  esac

  write_pool_state "$provider" "$percent" 1 1 || return 1
  rm -f -- "$RUNTIME_DIR/diagnostic"
  printf 'action: quota pool %s crossed to %s%% remaining; secondmate %s checkpointed, parked, and %s on %s/%s (%s)\n' \
    "$provider" "$percent" "$seat" "$relaunch_phrase" "$harness" "$model" "$effort"
  return 0
}

resume_nonterminal_journal() {
  local config_plan journal phase position position_json
  if [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ]; then
    config_plan=$(node "$EVALUATOR" --config-only "$CONFIG_FILE" 2>/dev/null || true)
    if [ "$(printf '%s' "$config_plan" | jq -r '.ok // false' 2>/dev/null)" = true ]; then
      printf '%s\n' "$config_plan" > "$CONFIG_PLAN_FILE" || return 1
    fi
  fi
  for journal in "$RUNTIME_DIR"/action-*; do
    [ -e "$journal" ] || [ -L "$journal" ] || continue
    if [ ! -f "$journal" ] || [ -L "$journal" ]; then
      emit_diagnostic "recovery journal ${journal##*/action-} is unsafe"
      return 0
    fi
    phase=$(meta_get "$journal" phase)
    case "$phase" in
      planned|checkpoint_pending|checkpointed|parking|parked)
        position=${journal##*/action-}
        position_json=
        if [ -s "$CONFIG_PLAN_FILE" ]; then
          position_json=$(jq -c --arg position "$position" '.positions[] | select(.position==$position)' "$CONFIG_PLAN_FILE" | head -1)
        fi
        perform_action "" "" "$position_json" "$journal"
        return $?
        ;;
    esac
  done
  return 75
}

main() {
  local quota_rc reason warning action provider percent previous warning_open action_open position_json position journal phase resume_rc
  resume_rc=0
  resume_nonterminal_journal || resume_rc=$?
  case "$resume_rc" in
    0) return 0 ;;
    75) ;;
    *) return "$resume_rc" ;;
  esac
  [ -e "$CONFIG_FILE" ] || return 0
  quota_rc=0
  quota-axi --json > "$TMP" 2>/dev/null || quota_rc=$?
  if [ "$quota_rc" -ne 0 ] || [ ! -s "$TMP" ]; then
    emit_diagnostic "quota snapshot is absent"
    return 0
  fi
  if [ ! -f "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
    emit_diagnostic "configuration is malformed"
    return 0
  fi
  PLAN=$(node "$EVALUATOR" "$TMP" "$CONFIG_FILE" "$NOW" 2>/dev/null) || {
    emit_diagnostic "quota snapshot is malformed"
    return 0
  }
  if [ "$(printf '%s' "$PLAN" | jq -r '.ok // false' 2>/dev/null)" != true ]; then
    reason=$(printf '%s' "$PLAN" | jq -r '.reason // "quota snapshot is malformed"' 2>/dev/null)
    emit_diagnostic "$reason"
    return 0
  fi
  printf '%s\n' "$PLAN" > "$PLAN_FILE" || return 1
  rm -f "$RUNTIME_DIR/diagnostic"
  warning=$(printf '%s' "$PLAN" | jq -r '.warningPercentRemaining')
  action=$(printf '%s' "$PLAN" | jq -r '.actionPercentRemaining')

  while IFS=$'\t' read -r provider percent; do
    [ -n "$provider" ] || continue
    previous=$(pool_previous "$provider")
    warning_open=$(meta_get "$(pool_state_path "$provider")" warning_open)
    action_open=$(meta_get "$(pool_state_path "$provider")" action_open)
    [ -n "$warning_open" ] || warning_open=0
    [ -n "$action_open" ] || action_open=0
    if number_gt "$percent" "$warning"; then
      write_pool_state "$provider" "$percent" 0 0 || return 1
      while IFS= read -r position_json; do
        [ -n "$position_json" ] || continue
        position=$(printf '%s' "$position_json" | jq -r '.position')
        journal="$RUNTIME_DIR/action-$position"
        phase=$(meta_get "$journal" phase)
        case "$phase" in
          complete|refused|'') rm -f -- "$journal" ;;
          planned|checkpoint_pending|checkpointed|parking|parked) : ;;
          *) emit_diagnostic "recovery journal $position has an unknown phase"; return 0 ;;
        esac
      done < <(printf '%s' "$PLAN" | jq -c --arg provider "$provider" '.positions[] | select(.provider==$provider)')
      continue
    fi

    if number_le "$percent" "$action" && [ -n "$previous" ] && number_gt "$previous" "$action" && [ "$action_open" != 1 ]; then
      position_json=$(printf '%s' "$PLAN" | jq -c --arg provider "$provider" '.positions[] | select(.provider==$provider)' | head -1)
      if [ -n "$position_json" ]; then
        perform_action "$provider" "$percent" "$position_json"
        return $?
      fi
    fi
    if [ -n "$previous" ] && number_gt "$previous" "$warning" && [ "$warning_open" != 1 ]; then
      write_pool_state "$provider" "$percent" 1 "$action_open" || return 1
      printf 'warning: quota pool %s crossed to %s%% remaining (warning threshold %s%%)\n' "$provider" "$percent" "$warning"
      return 0
    fi
    write_pool_state "$provider" "$percent" 1 "$action_open" || return 1
  done < <(printf '%s' "$PLAN" | jq -r '.providers[] | [.provider,.percentRemaining] | @tsv')
  return 0
}

PLAN=
main
