#!/usr/bin/env bash
# Task-bound rolling-quota reset process-event adapter.
#
# Usage:
#   fm-procevent-quota-reset.sh arm <task-id> --run <run-id> --provider <provider> --window <window-id> [--interval <secs>] [--timeout <secs>]
#   fm-procevent-quota-reset.sh poll <source-id> [--interval <secs>] [--timeout <secs>]
#   fm-procevent-quota-reset.sh handle <source-id> <sequence> <result-file>
#   fm-procevent-quota-reset.sh classify <result-file>
#   fm-procevent-quota-reset.sh terminal <result-file>
#   fm-procevent-quota-reset.sh source-id <task-id>
#   fm-procevent-quota-reset.sh retire <task-id>
#
# arm captures one failed validation attempt only when all evidence agrees:
# the task metadata names one spawn incarnation and local worktree, that copy is
# clean at the failed run's submitted head, the exact run is terminal failed,
# its error describes provider usage/rate/quota exhaustion without billing,
# monthly, credit, or payment-limit language, and quota-axi reports the named
# session/rolling window fresh, measurable, exhausted, and with a parseable
# future reset time. The private watch record binds the canonical home/state
# root, task, incarnation, run, branch, full submitted head, provider, window,
# observed percent, run-failure digest, and baseline reset identity plus epoch.
# A task has one canonical source, so a duplicate arm replaces nothing and
# reports the already-bound watch; changed identity must be retired first.
#
# poll is the blocking child run only by fm-procevent.sh. It asks quota-axi
# --json without reading or storing credentials. It emits reset only after the
# SAME provider window remains fresh and measurable, its reset epoch advances
# beyond the captured baseline, and positive headroom is restored. A 100%
# reading under the unchanged reset, changes to any other window, and an
# unknown source keep no authority. Malformed data, authentication/provider
# errors, billing caps, disappearance, or an unmeasurable tracked window emit a
# terminal diagnosis result instead of claiming reset. Every emitted result is
# one-shot through the generic process-event capture and acknowledgement.
#
# handle is the wake-time guarded reconciliation. It trusts the private watch,
# not result prose, and re-reads the exact task metadata, worktree, branch,
# clean HEAD, exact validation run, run failure, branch custody, replacement-run
# inventory, merge/cleanup evidence, and worker incarnation. A mismatch records
# the result handled without retrying. On a complete match it sends one normal
# durable task-inbox instruction, guarded by spawn_gen, with a deterministic
# idempotent ordinary-inbox write so a crash/replay deduplicates onto the same
# re-ring-eligible record. The instruction tells the owning worker to rerun its preserved
# validation using the original persisted intent and sleep prevention; this
# adapter never runs no-mistakes. Only after durable delivery does it record the
# process-event result handled. terminal returns success for reset and diagnosis.
# retire delegates source retirement to fm-procevent.sh; task/home cleanup keeps
# using that existing lifecycle owner and captured unhandled results remain
# independently acknowledgement-bound.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

DEFAULT_INTERVAL=60
DEFAULT_TIMEOUT=30
WATCH_DIR="$STATE/procevent-quota-reset"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
valid_id() { fm_task_id_path_safe "${1-}" && [ "${#1}" -le 128 ]; }
positive_number() { local LC_ALL=C; [[ "${1-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && [ "${1-}" != 0 ]; }
positive_int() { case "${1-}" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac; }
field() { sed -n "s/^$2=//p" "$1" | head -1; }
sha256_text() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
meta_value() { grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
no_newline() { [ "$(printf '%s' "$1" | wc -l | tr -d ' ')" = 0 ]; }

source_id_for_task() {
  valid_id "$1" || return 1
  printf 'quota-reset-%s\n' "$(sha256_text "$1" | cut -c1-20)"
}
watch_file() { printf '%s/%s.watch\n' "$WATCH_DIR" "$1"; }

rfc3339_epoch() {
  printf '%s\n' "$1" | jq -Rer '
    if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+]00:00)$")
    then sub("[.][0-9]+(?=Z|[+]00:00$)"; "") | sub("[+]00:00$"; "Z") | fromdateiso8601
    else error("not UTC RFC3339") end
  ' 2>/dev/null
}

quota_json() {
  local timeout=$1 output
  fm_quota_axi_compatible "$timeout" >/dev/null 2>&1 || return 1
  output=$(fm_run_timed "$timeout" quota-axi --json 2>/dev/null </dev/null) || return 1
  printf '%s\n' "$output" | fm_quota_json_valid || return 1
  printf '%s\n' "$output"
}

window_json() { # <json> <provider> <window>
  printf '%s\n' "$1" | jq -cer --arg provider "$2" --arg window "$3" '
    [.providers[] | select(.provider == $provider)] as $providers |
    if ($providers | length) != 1 then error("provider missing") else $providers[0] end as $p |
    if (($p.state.status // "") != "fresh" or ($p.state | has("stale") | not) or $p.state.stale != false)
      then error("provider not fresh") else . end |
    [$p.windows[]? | select(.id == $window)] as $windows |
    if ($windows | length) != 1 then error("window missing") else $windows[0] end as $w |
    if (($w.kind == "session" or $w.kind == "rolling") and
        ($w.resetsAt | type) == "string" and
        ($w.percentRemaining | type) == "number" and
        $w.percentRemaining >= 0 and $w.percentRemaining <= 100)
    then {provider:$provider,id:$w.id,kind:$w.kind,resetsAt:$w.resetsAt,percentRemaining:$w.percentRemaining}
    else error("window unmeasurable") end
  ' 2>/dev/null
}

status_error() {
  printf '%s\n' "$1" | sed -n 's/^error:[[:space:]]*//p' | head -1
}
quota_failure_error() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$lower" in *monthly*|*billing*|*credit*|*payment*|*insufficient_quota*) return 1 ;; esac
  printf '%s\n' "$lower" | grep -Eq '(usage|rate|quota).*(limit|exhaust|capacity)|((limit|exhaust).*(usage|rate|quota))'
}

status_identity_matches() { # <status> <run> <branch> <head> <failure-digest>
  local out=$1 run=$2 branch=$3 head=$4 digest=$5
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" id)")" = "$run" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" = "$branch" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" head_sha)")" = "$head" ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" status)")" = failed ] || return 1
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" outcome)")" = failed ] || return 1
  [ "$(sha256_text "$(status_error "$out")")" = "$digest" ]
}

branch_next_action() {
  printf '%s\n' "$1" | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}next_action:[[:space:]]*\(.*\)/\1/p' | head -1 | tr -d '"'
}

replacement_run_active() { # <overview> <branch> <captured-run>
  printf '%s\n' "$1" | awk -v branch="$2" -v run="$3" '
    /^[[:space:]]+/ {
      line=$0; gsub(/^ +|"/, "", line); split(line, f, ",")
      if (f[2] == branch && f[1] != run && (f[3] == "running" || f[3] == "pending")) found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

write_watch() { # <file> then key=value args
  local file=$1 tmp key value
  shift
  mkdir -p "$WATCH_DIR" || return 1
  chmod 0700 "$WATCH_DIR" || return 1
  tmp=$(umask 077; mktemp "$WATCH_DIR/.watch.XXXXXX") || return 1
  while [ "$#" -gt 0 ]; do
    key=$1; value=$2; shift 2
    printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done
  chmod 0600 "$tmp" && mv "$tmp" "$file"
}

cmd_arm() {
  # shellcheck disable=SC1007
  local task=${1-} run='' provider='' window='' interval=$DEFAULT_INTERVAL timeout=$DEFAULT_TIMEOUT
  local sid record meta wt incarnation branch head status error failure_digest json wj reset_at reset_epoch percent existing
  [ -n "$task" ] || usage; shift
  valid_id "$task" || die "invalid task id: $task"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --run) run=${2-}; shift 2 ;; --provider) provider=${2-}; shift 2 ;;
      --window) window=${2-}; shift 2 ;; --interval) interval=${2-}; shift 2 ;;
      --timeout) timeout=${2-}; shift 2 ;; *) usage ;;
    esac
  done
  valid_id "$run" || die "--run needs a valid run id"
  valid_id "$provider" || die "--provider needs a valid provider"
  valid_id "$window" || die "--window needs a valid window id"
  positive_number "$interval" || die "--interval needs a positive number"
  positive_int "$timeout" || die "--timeout needs a positive integer"
  sid=$(source_id_for_task "$task") || die "cannot derive source id"
  record=$(watch_file "$sid")
  if [ -f "$record" ]; then
    existing=$(field "$record" binding_digest)
    [ -n "$existing" ] || die "existing watch is malformed; retire it before replacement"
    printf 'already-armed: %s\n' "$sid"
    return 0
  fi
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || die "task metadata is absent"
  incarnation=$(meta_value "$meta" spawn_gen); wt=$(meta_value "$meta" worktree)
  valid_id "$incarnation" || die "task has no unambiguous spawn incarnation"
  [ -n "$wt" ] && [ -d "$wt" ] || die "task worktree is unavailable or unsafe"
  no_newline "$wt" || die "task worktree is unavailable or unsafe"
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || die "task worktree is dirty"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || die "task worktree has no branch"
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || die "cannot read task head"
  no_newline "$branch" || die "task branch is unsafe"
  status=$(fm_nm_run_bounded "$wt" "$timeout" axi status --run "$run" 2>/dev/null) || die "cannot read exact validation run"
  error=$(status_error "$status")
  quota_failure_error "$error" || die "terminal failure is not a rolling quota-exhaustion failure"
  failure_digest=$(sha256_text "$error")
  status_identity_matches "$status" "$run" "$branch" "$head" "$failure_digest" || die "validation run does not bind the clean submitted head"
  json=$(quota_json "$timeout") || die "quota-axi is unavailable, malformed, or not fresh"
  wj=$(window_json "$json" "$provider" "$window") || die "named rolling quota window is unknown or unmeasurable"
  percent=$(printf '%s\n' "$wj" | jq -r .percentRemaining)
  jq -en --argjson p "$percent" '$p <= 1' >/dev/null || die "named rolling quota window is not exhausted"
  reset_at=$(printf '%s\n' "$wj" | jq -r .resetsAt)
  reset_epoch=$(rfc3339_epoch "$reset_at") || die "quota reset identity is not parseable UTC RFC3339"
  local digest
  digest=$(sha256_text "$STATE|$task|$incarnation|$run|$wt|$branch|$head|$provider|$window|$reset_at|$reset_epoch|$percent|$failure_digest")
  write_watch "$record" schema fm-quota-reset.v1 state "$STATE" task "$task" incarnation "$incarnation" run "$run" worktree "$wt" branch "$branch" head "$head" provider "$provider" window "$window" baseline_reset_at "$reset_at" baseline_reset_epoch "$reset_epoch" baseline_percent "$percent" failure_digest "$failure_digest" binding_digest "$digest" || die "cannot publish private watch"
  "$SCRIPT_DIR/fm-procevent.sh" register quota-reset "$sid" -- "$SCRIPT_DIR/fm-procevent-quota-reset.sh" poll "$sid" --interval "$interval" --timeout "$timeout" || { rm -f "$record"; exit 1; }
  printf 'armed: %s\n' "$sid"
}

load_watch() {
  local sid=$1 file key recorded_state task incarnation run wt branch head provider window reset_at reset_epoch percent failure expected actual
  fm_procevent_source_id_valid "$sid" || return 1
  file=$(watch_file "$sid")
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ "$(field "$file" schema)" = fm-quota-reset.v1 ] || return 1
  for key in state task incarnation run worktree branch head provider window baseline_reset_at baseline_reset_epoch baseline_percent failure_digest binding_digest; do
    [ -n "$(field "$file" "$key")" ] || return 1
  done
  recorded_state=$(field "$file" state); task=$(field "$file" task); incarnation=$(field "$file" incarnation)
  run=$(field "$file" run); wt=$(field "$file" worktree); branch=$(field "$file" branch); head=$(field "$file" head)
  provider=$(field "$file" provider); window=$(field "$file" window); reset_at=$(field "$file" baseline_reset_at)
  reset_epoch=$(field "$file" baseline_reset_epoch); percent=$(field "$file" baseline_percent)
  failure=$(field "$file" failure_digest); actual=$(field "$file" binding_digest)
  [ "$recorded_state" = "$STATE" ] || return 1
  [ "$(source_id_for_task "$task")" = "$sid" ] || return 1
  expected=$(sha256_text "$recorded_state|$task|$incarnation|$run|$wt|$branch|$head|$provider|$window|$reset_at|$reset_epoch|$percent|$failure")
  [ "$actual" = "$expected" ] || return 1
  WATCH_FILE=$file
}

cmd_poll() {
  local sid=${1-} interval=$DEFAULT_INTERVAL timeout=$DEFAULT_TIMEOUT json wj reset_at reset_epoch percent polls=0
  [ -n "$sid" ] || usage; shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --interval) interval=${2-}; shift 2 ;; --timeout) timeout=${2-}; shift 2 ;; *) usage ;; esac
  done
  positive_number "$interval" || die "--interval needs a positive number"
  positive_int "$timeout" || die "--timeout needs a positive integer"
  load_watch "$sid" || die "watch record is absent or malformed"
  local provider window baseline binding
  provider=$(field "$WATCH_FILE" provider); window=$(field "$WATCH_FILE" window)
  baseline=$(field "$WATCH_FILE" baseline_reset_epoch); binding=$(field "$WATCH_FILE" binding_digest)
  while :; do
    polls=$((polls + 1))
    if ! json=$(quota_json "$timeout"); then
      printf 'status: diagnosis\nsource: %s\nbinding: %s\nreason: quota-axi unavailable, malformed, or provider evidence not fresh\ncondition_polls: %s\n' "$sid" "$binding" "$polls"
      return 0
    fi
    if ! wj=$(window_json "$json" "$provider" "$window"); then
      printf 'status: diagnosis\nsource: %s\nbinding: %s\nreason: tracked provider window is unknown or unmeasurable\ncondition_polls: %s\n' "$sid" "$binding" "$polls"
      return 0
    fi
    reset_at=$(printf '%s\n' "$wj" | jq -r .resetsAt)
    if ! reset_epoch=$(rfc3339_epoch "$reset_at"); then
      printf 'status: diagnosis\nsource: %s\nbinding: %s\nreason: tracked reset identity is malformed\ncondition_polls: %s\n' "$sid" "$binding" "$polls"
      return 0
    fi
    percent=$(printf '%s\n' "$wj" | jq -r .percentRemaining)
    if [ "$reset_epoch" -gt "$baseline" ] && jq -en --argjson p "$percent" '$p > 0' >/dev/null; then
      printf 'status: reset\nsource: %s\nbinding: %s\nprovider: %s\nwindow: %s\nbaseline_reset_epoch: %s\nreset_at: %s\nreset_epoch: %s\npercent_remaining: %s\ncondition_polls: %s\n' "$sid" "$binding" "$provider" "$window" "$baseline" "$reset_at" "$reset_epoch" "$percent" "$polls"
      return 0
    fi
    sleep "$interval"
  done
}

cmd_classify() {
  local file=${1-} status
  [ -f "$file" ] || die "result file does not exist: $file"
  status=$(awk '$0 == "output:" { exit } /^status: / { sub(/^status: /, ""); print; exit }' "$file")
  case "$status" in reset|diagnosis) printf '%s\n' "$status" ;; *) printf 'unknown\n' ;; esac
}
cmd_terminal() { [ "$(cmd_classify "${1-}")" != unknown ]; }

retire_handled_watch() { # <sid>
  "$SCRIPT_DIR/fm-procevent.sh" retire "$1" >/dev/null || return 1
  rm -f "$(watch_file "$1")"
}

handle_refuse() { # <sid> <seq> <reason>
  "$SCRIPT_DIR/fm-procevent.sh" handled "$1" "$2" >/dev/null || return 1
  retire_handled_watch "$1" || return 1
  printf 'refused: %s\n' "$3"
}

cmd_handle() {
  local sid=${1-} seq=${2-} result=${3-} task incarnation run wt branch head provider window failure_digest binding
  local result_sid result_binding meta current_inc current_wt current_branch current_head status error next overview message
  [ -n "$sid" ] && [ -n "$seq" ] && [ -f "$result" ] || usage
  case "$seq" in ''|*[!0-9]*) die "invalid result sequence" ;; esac
  [ "$(cmd_classify "$result")" = reset ] || { handle_refuse "$sid" "$seq" "quota result requires diagnosis"; return; }
  result_sid=$(fm_procevent_result_source_id "$result")
  [ "$result_sid" = "$sid" ] || die "result source does not match"
  load_watch "$sid" || { handle_refuse "$sid" "$seq" "watch is absent or malformed"; return; }
  task=$(field "$WATCH_FILE" task); incarnation=$(field "$WATCH_FILE" incarnation); run=$(field "$WATCH_FILE" run)
  wt=$(field "$WATCH_FILE" worktree); branch=$(field "$WATCH_FILE" branch); head=$(field "$WATCH_FILE" head)
  provider=$(field "$WATCH_FILE" provider); window=$(field "$WATCH_FILE" window)
  failure_digest=$(field "$WATCH_FILE" failure_digest); binding=$(field "$WATCH_FILE" binding_digest)
  result_binding=$(awk '$0 == "output:" { exit } /^binding: / { sub(/^binding: /, ""); print; exit }' "$result")
  [ "$result_binding" = "$binding" ] || { handle_refuse "$sid" "$seq" "result binding changed"; return; }
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || { handle_refuse "$sid" "$seq" "task was retired"; return; }
  [ ! -e "$STATE/$task.backlog-close" ] && [ -z "$(meta_value "$meta" pr)" ] || { handle_refuse "$sid" "$seq" "task already entered merge or cleanup"; return; }
  current_inc=$(meta_value "$meta" spawn_gen); current_wt=$(meta_value "$meta" worktree)
  [ "$current_inc" = "$incarnation" ] && [ "$current_wt" = "$wt" ] || { handle_refuse "$sid" "$seq" "task incarnation or worktree changed"; return; }
  [ -d "$wt" ] || { handle_refuse "$sid" "$seq" "task worktree disappeared"; return; }
  current_branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  current_head=$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)
  [ "$current_branch" = "$branch" ] && [ "$current_head" = "$head" ] || { handle_refuse "$sid" "$seq" "branch or submitted head changed"; return; }
  [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || { handle_refuse "$sid" "$seq" "task worktree is dirty"; return; }
  status=$(fm_nm_run_bounded "$wt" "$DEFAULT_TIMEOUT" axi status --run "$run" 2>/dev/null) || { handle_refuse "$sid" "$seq" "exact validation run is unreadable"; return; }
  status_identity_matches "$status" "$run" "$branch" "$head" "$failure_digest" || { handle_refuse "$sid" "$seq" "terminal quota failure no longer matches"; return; }
  error=$(status_error "$status"); quota_failure_error "$error" || { handle_refuse "$sid" "$seq" "terminal failure is no longer quota exhaustion"; return; }
  next=$(branch_next_action "$status")
  case "$(fm_nm_branch_sync_state "$status"):$next" in pipeline_owned:*|*:recover_custody|*:abort|*:sync) handle_refuse "$sid" "$seq" "branch custody requires another action"; return ;; esac
  overview=$(fm_nm_run_bounded "$wt" "$DEFAULT_TIMEOUT" axi status 2>/dev/null) || { handle_refuse "$sid" "$seq" "validation inventory is unreadable"; return; }
  if replacement_run_active "$overview" "$branch" "$run"; then handle_refuse "$sid" "$seq" "another validation run is active"; return; fi
  message="The measured $provider $window rolling quota window has advanced beyond the failed validation run $run's captured reset and usable headroom is restored. Re-run that preserved no-mistakes validation now from the unchanged clean submitted head $head, using the original persisted captain intent and the same sleep-prevention arrangement. Continue to own every validation command and gate; do not use --yes."
  if ! FM_SEND_IDEMPOTENT=1 FM_SEND_EXPECTED_SPAWN_GEN="$incarnation" FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "$task" "$message" >/dev/null; then
    die "durable retry instruction was not delivered"
  fi
  "$SCRIPT_DIR/fm-procevent.sh" handled "$sid" "$seq" >/dev/null || die "retry delivered but result acknowledgement failed; replay deduplicates onto the same ordinary inbox record"
  retire_handled_watch "$sid" || die "retry delivered and acknowledged but the stale watch could not be retired"
  printf 'retry-delivered: %s\n' "$task"
}

cmd_retire() {
  local task=${1-} sid
  valid_id "$task" || die "retire needs a valid task id"
  sid=$(source_id_for_task "$task") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$sid" || exit 1
  rm -f "$(watch_file "$sid")"
}

case "${1-}" in
  arm) shift; cmd_arm "$@" ;; poll) shift; cmd_poll "$@" ;; handle) shift; cmd_handle "$@" ;;
  classify) shift; cmd_classify "$@" ;; terminal) shift; cmd_terminal "$@" ;;
  source-id) shift; [ "$#" -eq 1 ] || usage; source_id_for_task "$1" || die "invalid task id" ;;
  retire) shift; cmd_retire "$@" ;; ''|-h|--help|help) usage ;; *) die "unknown command: $1" ;;
esac
