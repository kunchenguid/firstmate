#!/usr/bin/env bash
# Host-local lifecycle control for the remote secondmate home selected by fm-on.
#
# Usage:
#   fm-remote-secondmate-control.sh launch <id> <harness> <model|-> <effort|-> herdr [traceparent] [--operation <gen> --previous <gen|->]
#   fm-remote-secondmate-control.sh relaunch <id> <harness> <model|default|-> <effort|default|-> [--operation <gen> --previous <gen|->] [--expect-generation <gen>]
#   fm-remote-secondmate-control.sh disposition <id> --operation <gen>
#   fm-remote-secondmate-control.sh state <id>
#   fm-remote-secondmate-control.sh route <id>
#   fm-remote-secondmate-control.sh send <id> <message> [fire-and-forget]
#   fm-remote-secondmate-control.sh key <id> <key>
#   fm-remote-secondmate-control.sh capture <id> [lines]
#   fm-remote-secondmate-control.sh observe <id>
#   fm-remote-secondmate-control.sh sync <id> [<parent-commit>]
#   fm-remote-secondmate-control.sh update <id>
#   fm-remote-secondmate-control.sh retire <id> [--force]
#
# Remote placement ends here, but the second-mate agent always runs on the
# Herdr backend in the dedicated fm-remote session, so launch refuses any other
# selection rather than reading this home's config/backend. The interactive
# default session remains for the user's work.
# fm-spawn/fm-send/fm-teardown keep owning the local endpoint mechanics.
# The home's own workers keep their ordinary backend selection.
# bin/fm-remote-doctor.sh owns that host's readiness for Herdr.
# docs/remote-secondmates.md owns why.
#
# With <parent-commit>, sync follows the PARENT PRIMARY's default-branch commit,
# which the parent resolves on its own checkout and passes in, so a remote home
# tracks the primary exactly like a local one instead of stopping at whatever
# this host's Firstmate copy happens to hold. Omitting <parent-commit> targets
# this host's own code-root HEAD instead, which is what /updatefirstmate wants
# after it has refreshed that
# code root from origin. Because this home is a standalone clone, the target
# commit is imported here first and the fast-forward itself is the shared one in
# bin/fm-ff-lib.sh, so the clean, ancestry, and branch guards have a single owner.
# A private parent-route state directory stores only the remote secondmate
# agent's endpoint record; the home's own
# state/*.meta remains reserved for workers the secondmate supervises.
# Retirement closes only this secondmate's panes or workspace and never
# stops fm-remote or removes a sibling secondmate's workspace or panes.
#
# Relaunch is not a second lifecycle implementation: it runs the ORDINARY local
# control plane here, because from this host the mate is a plain local
# secondmate. cmd_relaunch below owns why the parent must hand it the profile.
# It ends by printing the same route block `route` prints, so a caller that
# invoked it directly (rather than through bin/fm-remote-secondmate-relaunch.sh,
# which reads this block to keep the parent's own record in sync) still gets
# the confirmed identity.
#
# Fleet seat operations. When the parent accounts for this supervisor's fleet
# seat (bin/fm-fleet-seats.sh "REMOTE SUPERVISORS"), launch and relaunch carry
# its generation as --operation (plus the generation it replaces). This host
# then runs the whole episode inside its own lifecycle mutex for the
# parent-route record (bin/fm-secondmate-liveness-lib.sh), persists the token
# in the operation receipt <state>/parent-route/<id>.seat-operation.<gen> BEFORE any
# stop or launch, hands the generation to the host-local launch owner (which
# records dispatch and startup in the same receipt and consumes the parent's
# seat rather than reserving another), and ends every outcome - success,
# refusal, or failure - with one "seat_disposition=<json>" line:
#   {schema:"fm-remote-seat-operation.v2", task, operation,
#    requested_generation, actual_generation, previous_generation,
#    disposition, startup_confirmed, old_stopped, old_destroyed, route, actual_model,
#    complete:true}
# with disposition prelaunch | started | existing | cancelled |
# dead-after-start | unknown. A same-token retry reports the durable episode
# and never launches twice; `disposition` rereads it (a busy mutex or an absent
# or foreign receipt is unknown, never a refusal). While this home has seat
# pools, a launch or relaunch without a verified parent reservation refuses
# before touching anything: the parent wrapper must account for it. Each
# operation keeps its own receipt and an immutable .seat-reservation.<gen> holder record
# received from fm-on's ledger-verified input. Losing its mutable receipt is
# unknown and never permits opening another episode for that token.
# An `existing` receipt binds its request token to the actual generation it observed, so
# disposition and predecessor readiness resolve evidence through that binding,
# not just a receipt filename equal to the generation. Replacement preserves
# matching receipts' request identities when recording terminal outcomes.
# Receipt keys: schema,
# operation, verb, requested_generation, previous_generation, phase
# (received | prelaunch | existing | dispatched | started | dead-after-start |
# cancelled), actual_generation, route_backend, route_target, actual_model,
# old_stopped, old_destroyed.
#
# The optional launch traceparent is the per-task W3C trace-context carrier the
# PARENT home resolved for this secondmate; this host only delivers it to the
# pane, and fm-spawn validates it (bin/fm-trace-context-lib.sh). Omitting it is
# the default-off path. print_route echoes the carrier the endpoint actually
# holds, including for an already-alive endpoint that was not relaunched, so the
# parent records the identity the agent really received rather than an intent.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET_HOME=${FM_HOME:?FM_HOME is required}
CONTROL_STATE="$TARGET_HOME/state/parent-route"
CONTROL_DATA="$TARGET_HOME/data/.parent-route"
REMOTE_HERDR_SESSION=fm-remote

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
# Seat operation of the running launch/relaunch, when the parent passed one.
SEAT_OP=
SEAT_PREV=-
EXPECT_GENERATION=
SEAT_LIFECYCLE_ID=
prelaunch_die() {
  if [ -n "$SEAT_OP" ]; then
    seat_receipt_set phase=prelaunch 2>/dev/null || true
    seat_emit prelaunch false false
  fi
  printf 'relaunch_failure=prelaunch\n' >&2
  die "$1"
}
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
validate_id() { case "$1" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $1" ;; esac; }

validate_home() { # <id> [allow-absent]
  local id=$1 allow_absent=${2:-no} marker
  if [ ! -e "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] && [ "$allow_absent" = yes ]; then return 2; fi
  [ -d "$TARGET_HOME" ] && [ ! -L "$TARGET_HOME" ] || die "remote secondmate home is unavailable or unsafe"
  [ -f "$TARGET_HOME/.fm-secondmate-home" ] && [ ! -L "$TARGET_HOME/.fm-secondmate-home" ] \
    || die "remote home is not a seeded secondmate home"
  marker=$(cat "$TARGET_HOME/.fm-secondmate-home")
  [ "$marker" = "$id" ] || die "remote home belongs to $marker, not $id"
  [ -f "$TARGET_HOME/AGENTS.md" ] && [ -d "$TARGET_HOME/bin" ] || die "remote home is not a Firstmate checkout"
}

meta_path() { printf '%s/%s.meta\n' "$CONTROL_STATE" "$1"; }

# --- fleet seat operation receipts ----------------------------------------------

receipt_path() { printf '%s/%s.seat-operation.%s\n' "$CONTROL_STATE" "$1" "${2:-$SEAT_OP}"; }

receipt_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

host_pools_enabled() {
  local delivered="$TARGET_HOME/state/fleet-seats/policy.json"
  if [ -e "$delivered" ] || [ -L "$delivered" ]; then
    cmp -s "$delivered" <(printf '{"pools":[]}\n') && return 1
    return 0
  fi
  [ -e "$TARGET_HOME/config/fleet-seats" ] || [ -L "$TARGET_HOME/config/fleet-seats" ]
}

json_str() {  # <value>: a JSON string, or null when empty
  local v=$1
  [ -n "$v" ] || { printf 'null'; return 0; }
  case "$v" in *[[:cntrl:]]*) printf 'null'; return 0 ;; esac
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

# seat_parse_operation <args...>: split trailing --operation/--previous from a
# verb's positional arguments into SEAT_OP/SEAT_PREV and SEAT_ARGS.
seat_parse_operation() {
  SEAT_ARGS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --operation) [ "$#" -ge 2 ] || usage; SEAT_OP=$2; shift 2 ;;
      --previous) [ "$#" -ge 2 ] || usage; SEAT_PREV=$2; shift 2 ;;
      --expect-generation)
        [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "error: missing expected generation; nothing was changed" >&2; exit 6; }
        EXPECT_GENERATION=$2
        case "$EXPECT_GENERATION" in *[!A-Za-z0-9._-]*) die "invalid expected generation" ;; esac
        shift 2
        ;;
      *) SEAT_ARGS+=("$1"); shift ;;
    esac
  done
  case "$SEAT_OP" in *[!A-Za-z0-9.]*) die "invalid seat operation token" ;; esac
  case "$SEAT_PREV" in -|*[!A-Za-z0-9._-]*) [ "$SEAT_PREV" = - ] || die "invalid previous seat generation" ;; esac
}

# seat_receipt_open <id> <verb>: persist the token-scoped receipt before any
# endpoint effect. Must run inside the host lifecycle episode.
seat_receipt_open() {
  local id=$1 receipt tmp
  receipt=$(receipt_path "$id")
  tmp="$receipt.tmp.$$"
  (umask 077 && {
    echo "schema=fm-remote-seat-receipt.v1"
    echo "operation=$SEAT_OP"
    echo "verb=$2"
    echo "requested_generation=$SEAT_OP"
    echo "previous_generation=$SEAT_PREV"
    echo "phase=received"
  } > "$tmp") && mv -f "$tmp" "$receipt"
}

seat_receipt_set() {  # <key=value>...
  fm_remote_seat_receipt_update "$(receipt_path "$SEAT_LIFECYCLE_ID")" "$SEAT_OP" "$SEAT_OP" "$@"
}

# seat_emit <disposition> <startup-confirmed> <old-stopped> [actual-gen] [backend] [target] [model]
seat_emit() {
  local route=null
  if [ -n "${6:-}" ]; then
    route="{\"placement\":\"remote\",\"backend\":$(json_str "${5:-herdr}"),\"target\":$(json_str "$6"),\"home\":$(json_str "$TARGET_HOME"),\"host\":null,\"remote_root\":null,\"spawn_gen\":$(json_str "${4:-}")}"
  fi
  local prev=null
  [ "$SEAT_PREV" = - ] || prev=$(json_str "$SEAT_PREV")
  printf 'seat_disposition={"schema":"fm-remote-seat-operation.v2","task":%s,"operation":%s,"requested_generation":%s,"actual_generation":%s,"previous_generation":%s,"disposition":%s,"startup_confirmed":%s,"old_stopped":%s,"old_destroyed":%s,"route":%s,"actual_model":%s,"complete":true}\n' \
    "$(json_str "$SEAT_LIFECYCLE_ID")" "$(json_str "$SEAT_OP")" "$(json_str "$SEAT_OP")" \
    "$(json_str "${4:-}")" "$prev" "$(json_str "$1")" "$2" "$3" "${SEAT_OLD_DESTROYED:-false}" "$route" "$(json_str "${7:-}")"
}

# seat_endpoint_state <backend> <target>: recovery-grade state, with a
# `missing` reading upgraded to `gone` only on the backend's absence proof.
seat_endpoint_state() {
  local state verdict
  [ -n "$1" ] && [ -n "$2" ] || { printf 'unreadable'; return 0; }
  state=$(fm_backend_agent_state "$1" "$2" 2>/dev/null || printf 'unreadable')
  if [ "$state" = missing ]; then
    verdict=$(fm_control_endpoint_absence_verdict "$1" "$2")
    case "${verdict%%$'\t'*}" in
      gone) state=gone ;;
      dead) state=dead ;;
      alive) state=alive ;;
      *) state=unproven ;;
    esac
  fi
  printf '%s' "$state"
}

# seat_decide <id>: compute and emit the disposition of operation SEAT_OP from
# the durable receipt, the control journal, and a fresh generation-bound
# endpoint observation. The caller holds the host lifecycle mutex. Sets
# SEAT_DECIDED to the disposition.
seat_decide() {
  local id=$1 receipt meta journal phase verb gen meta_gen backend target model state jphase jop rollback exit_result previous_phase _prior_receipt _prior_op prior_phase old_stopped=false
  receipt=$(receipt_path "$id")
  meta=$(meta_path "$id")
  SEAT_DECIDED=unknown
  SEAT_OLD_DESTROYED=false
  if [ ! -f "$receipt" ] || [ -L "$receipt" ] \
    || [ "$(receipt_field "$receipt" schema)" != fm-remote-seat-receipt.v1 ] \
    || [ "$(receipt_field "$receipt" operation)" != "$SEAT_OP" ] \
    || [ "$(receipt_field "$receipt" requested_generation)" != "$SEAT_OP" ]; then
    seat_emit unknown false false
    return 0
  fi
  [ -n "$(receipt_field "$receipt" previous_generation)" ] && SEAT_PREV=$(receipt_field "$receipt" previous_generation)
  phase=$(receipt_field "$receipt" phase)
  verb=$(receipt_field "$receipt" verb)
  [ "$(receipt_field "$receipt" old_stopped)" != true ] || old_stopped=true
  [ "$(receipt_field "$receipt" old_destroyed)" != true ] || SEAT_OLD_DESTROYED=true
  gen=$(receipt_field "$receipt" actual_generation)
  [ -n "$gen" ] || gen=$SEAT_OP
  meta_gen=
  model=
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    meta_gen=$(fm_meta_get "$meta" spawn_gen)
    model=$(fm_meta_get "$meta" model)
  fi
  backend=$(receipt_field "$receipt" route_backend)
  target=$(receipt_field "$receipt" route_target)
  if [ "$verb" = relaunch ]; then
    journal="$CONTROL_STATE/$id.control-relaunch"
    jop=$(sed -n 's/^seat_operation=//p' "$journal" 2>/dev/null | tail -1)
    jphase=$(sed -n 's/^phase=//p' "$journal" 2>/dev/null | tail -1)
    rollback=$(sed -n 's/^rollback=//p' "$journal" 2>/dev/null | tail -1)
    exit_result=$(sed -n 's/^exit_result=//p' "$journal" 2>/dev/null | tail -1)
    previous_phase=
    while IFS=$'\t' read -r _prior_receipt _prior_op prior_phase; do
      case "$prior_phase" in existing|started|dead-after-start) previous_phase=started ;; esac
    done < <(fm_remote_seat_receipts_for_generation "$CONTROL_STATE" "$id" "$SEAT_PREV")
    if [ "$jop" = "$SEAT_OP" ]; then
      case "${jphase#failed:}" in
        exited|launching|complete)
          if [ "$exit_result" = endpoint-gone ]; then
            old_stopped=true
            SEAT_OLD_DESTROYED=true
          elif [ "$exit_result" = stopped ] || [ "$previous_phase" = started ]; then
            old_stopped=true
          fi
          ;;
        stopping)
          case "$rollback" in
            prior-record-kept-agent-dead) [ "$previous_phase" != started ] || old_stopped=true ;;
            instructions-restored-agent-alive) ;;
            *)
              if [ "$phase" = received ] || [ "$phase" = prelaunch ]; then
                SEAT_DECIDED=unknown
                seat_emit unknown false false
                return 0
              fi
              ;;
          esac
          ;;
      esac
    fi
  fi
  case "$phase" in
    dead-after-start)
      SEAT_DECIDED=dead-after-start
      seat_emit dead-after-start true "$old_stopped" "$gen" "$backend" "$target" "$(receipt_field "$receipt" actual_model)"
      ;;
    cancelled)
      SEAT_DECIDED=cancelled
      seat_emit cancelled false "$old_stopped" "" "$backend" "$target"
      ;;
    prelaunch|received)
      if [ "$old_stopped" = true ]; then
        # The old agent stopped but the candidate was never submitted.
        SEAT_DECIDED=cancelled
        seat_emit cancelled false true
      else
        SEAT_DECIDED=prelaunch
        seat_emit prelaunch false false
      fi
      ;;
    existing|dispatched|started)
      state=$(seat_endpoint_state "$backend" "$target")
      if [ "$state" = alive ] && [ "$meta_gen" = "$gen" ]; then
        if [ "$phase" = existing ]; then
          SEAT_DECIDED=existing
          seat_emit existing true false "$gen" "$backend" "$target" "$model"
        else
          seat_receipt_set phase=started "actual_generation=$gen" "actual_model=$model" 2>/dev/null || true
          SEAT_DECIDED=started
          seat_emit started true "$old_stopped" "$gen" "$backend" "$target" "$model"
        fi
      elif { [ "$phase" = existing ] || [ "$phase" = started ]; } \
        && { { [ "$state" = dead ] && [ "$meta_gen" = "$gen" ]; } || [ "$state" = gone ]; }; then
        seat_receipt_set phase=dead-after-start "actual_generation=$gen" 2>/dev/null || true
        SEAT_DECIDED=dead-after-start
        seat_emit dead-after-start true "$old_stopped" "$gen" "$backend" "$target" "$model"
      elif [ "$phase" = dispatched ] && [ "$state" = gone ]; then
        SEAT_DECIDED=cancelled
        seat_emit cancelled false "$old_stopped" "" "$backend" "$target"
      else
        SEAT_DECIDED=unknown
        seat_emit unknown false "$old_stopped" "" "$backend" "$target"
      fi
      ;;
    *)
      seat_emit unknown false "$old_stopped"
      ;;
  esac
}

# seat_enter <id> <verb>: parse-time checks done, join the host lifecycle
# episode, answer a same-token retry from its durable episode (returns 3), or
# open a fresh receipt (returns 0). Refuses a pooled launch with no operation.
seat_enter() {
  local id=$1 verb=$2 model=$3 receipt reservation record
  SEAT_LIFECYCLE_ID=$id
  mkdir -p "$CONTROL_STATE" "$CONTROL_DATA" 2>/dev/null \
    || prelaunch_die "remote endpoint directories could not be created"
  if ! fm_supervisor_lifecycle_enter "$CONTROL_STATE" "$id" 30; then
    # Another episode may be running this very token; never call it refused.
    seat_emit unknown false false
    die "another lifecycle episode for remote secondmate $id is running on this host"
  fi
  trap 'fm_supervisor_lifecycle_release "$CONTROL_STATE" "$SEAT_LIFECYCLE_ID"' EXIT
  if [ -z "$SEAT_OP" ] && host_pools_enabled; then
    prelaunch_die "this home has fleet seat pools, so a supervisor $verb must come from the parent's seat operation (bin/fm-remote-secondmate-relaunch.sh or fm-spawn); nothing was changed"
  fi
  [ -n "$SEAT_OP" ] || return 0
  receipt=$(receipt_path "$id")
  reservation="$CONTROL_STATE/$id.seat-reservation.$SEAT_OP"
  if [ -e "$receipt" ] || [ -L "$receipt" ] || [ -e "$reservation" ] || [ -L "$reservation" ] \
    || [ "$(fm_meta_get "$(meta_path "$id")" spawn_gen 2>/dev/null || true)" = "$SEAT_OP" ] \
    || [ "$(receipt_field "$CONTROL_STATE/$id.control-relaunch" seat_operation)" = "$SEAT_OP" ]; then
    seat_decide "$id"
    return 3
  fi
  record=$(cat) || prelaunch_die "the parent seat reservation could not be read"
  if ! printf '%s\n' "$record" | jq -e --arg t "$id" --arg g "$SEAT_OP" \
    --arg p "$SEAT_PREV" --arg home "$TARGET_HOME" --arg m "$model" '
      .schema == "fm-fleet-seat-holder.v2" and .task == $t
      and (.state_dir | type == "string" and startswith("/"))
      and any(.incarnations[]; .generation == $g and .kind == "secondmate"
        and .lifecycle == "reserved" and .launch_phase == "dispatching"
        and .model == (if $m == "-" or $m == "default" or $m == "" then null else $m end)
        and (.previous_generation // "-") == $p
        and .route.placement == "remote" and .route.operation == $g
        and .route.home == $home)
    ' >/dev/null 2>&1; then
    prelaunch_die "operation $SEAT_OP has no verified dispatched parent reservation; nothing was changed"
  fi
  (umask 077; set -C; printf '%s\n' "$record" > "$reservation") \
    || { seat_emit unknown false false; die "the seat operation was already claimed or could not be retained"; }
  seat_receipt_open "$id" "$verb" || prelaunch_die "the seat operation receipt could not be written"
  return 0
}

remote_endpoint_load() {
  local id=$1 herdr_session
  REMOTE_ENDPOINT_ERROR=
  REMOTE_ENDPOINT_META=$(meta_path "$id")
  if ! fm_backend_validate_task_endpoint "$REMOTE_ENDPOINT_META" "$id" 2>/dev/null; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint metadata is invalid; refusing access until it is explicitly migrated"
    return 1
  fi
  REMOTE_ENDPOINT_BACKEND=$FM_BACKEND_VALIDATED_BACKEND
  REMOTE_ENDPOINT_TARGET=$FM_BACKEND_VALIDATED_TARGET
  if [ "$REMOTE_ENDPOINT_BACKEND" != herdr ]; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded on backend '$REMOTE_ENDPOINT_BACKEND', expected 'herdr'; refusing access until it is explicitly migrated"
    return 1
  fi
  herdr_session=$(fm_backend_meta_exact_value "$REMOTE_ENDPOINT_META" herdr_session 2>/dev/null || true)
  if [ "$herdr_session" != "$REMOTE_HERDR_SESSION" ]; then
    REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint is recorded in Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
    return 1
  fi
  case "$REMOTE_ENDPOINT_TARGET" in
    "$REMOTE_HERDR_SESSION":?*) ;;
    *)
      REMOTE_ENDPOINT_ERROR="remote secondmate $id endpoint target '$REMOTE_ENDPOINT_TARGET' is outside Herdr session '$REMOTE_HERDR_SESSION'; refusing access until it is explicitly migrated"
      return 1
      ;;
  esac
}

seat_predecessor_ready() {
  local gen state phase receipt op confirmed=0 terminal_phase
  [ -n "$SEAT_OP" ] || return 0
  gen=$(fm_meta_get "$REMOTE_ENDPOINT_META" spawn_gen)
  while IFS=$'\t' read -r receipt op phase; do
    case "$phase" in existing|started|dead-after-start) confirmed=1 ;; esac
  done < <(fm_remote_seat_receipts_for_generation "$CONTROL_STATE" "$SEAT_LIFECYCLE_ID" "$gen")
  state=$(seat_endpoint_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET")
  case "$state" in
    alive) ;;
    dead|gone)
      if [ "$confirmed" != 1 ] && [ "$state" != gone ]; then
        prelaunch_die "the predecessor generation ${gen:-unknown} has no confirmed startup or proven endpoint destruction; refusing replacement"
      fi
      while IFS=$'\t' read -r receipt op phase; do
        case "$phase" in dead-after-start|cancelled|prelaunch) continue ;; esac
        terminal_phase=cancelled
        case "$phase" in existing|started) terminal_phase=dead-after-start ;; esac
        fm_remote_seat_receipt_update "$receipt" "$op" "$op" "phase=$terminal_phase" "actual_generation=$gen" \
          || prelaunch_die "could not retain the predecessor's terminal receipt"
      done < <(fm_remote_seat_receipts_for_generation "$CONTROL_STATE" "$SEAT_LIFECYCLE_ID" "$gen")
      ;;
    *) prelaunch_die "the predecessor generation ${gen:-unknown} has no confirmed startup or proven endpoint destruction; refusing replacement" ;;
  esac
}

remote_endpoint_require() {
  remote_endpoint_load "$1" || die "$REMOTE_ENDPOINT_ERROR"
}

state_value() { # <id>; prints recovery-grade state
  local id=$1 meta
  meta=$(meta_path "$id")
  [ -f "$meta" ] && [ ! -L "$meta" ] || { printf 'missing\n'; return 0; }
  if ! remote_endpoint_load "$id"; then
    printf 'error: %s\n' "$REMOTE_ENDPOINT_ERROR" >&2
    printf 'unverified\n'
    return 0
  fi
  fm_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n'
}

print_route() { # <id>
  local id=$1 harness model effort traceparent
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  model=$(fm_meta_get "$REMOTE_ENDPOINT_META" model)
  effort=$(fm_meta_get "$REMOTE_ENDPOINT_META" effort)
  traceparent=$(fm_meta_get "$REMOTE_ENDPOINT_META" traceparent)
  printf 'schema=fm-remote-secondmate-control.v1\n'
  printf 'backend=%s\n' "$REMOTE_ENDPOINT_BACKEND"
  printf 'target=%s\n' "$REMOTE_ENDPOINT_TARGET"
  printf 'herdr_session=%s\n' "$REMOTE_HERDR_SESSION"
  printf 'harness=%s\n' "$harness"
  printf 'model=%s\n' "$model"
  printf 'effort=%s\n' "$effort"
  [ -z "$traceparent" ] || printf 'traceparent=%s\n' "$traceparent"
  printf 'spawn_gen=%s\n' "$(fm_meta_get "$REMOTE_ENDPOINT_META" spawn_gen)"
  [ -z "$SEAT_OP" ] || printf 'seat_operation=%s\n' "$SEAT_OP"
}

cmd_route() {
  local id=$1 meta
  validate_id "$id"
  validate_home "$id"
  meta=$(meta_path "$id")
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    die "remote secondmate has no endpoint metadata"
  fi
  print_route "$id"
}

cmd_launch() {
  local id=$1 harness=$2 model=$3 effort=$4 selected_backend=$5 traceparent=${6:-}
  local current meta out herdr_session enter_rc=0

  validate_id "$id"
  SEAT_LIFECYCLE_ID=$id
  ( validate_home "$id" ) || prelaunch_die "remote secondmate home validation failed"
  seat_enter "$id" launch "$model" || enter_rc=$?
  if [ "$enter_rc" -eq 3 ]; then
    case "$SEAT_DECIDED" in
      started|existing) remote_endpoint_load "$id" && print_route "$id"; return 0 ;;
      *) die "seat operation $SEAT_OP was already handled on this host ($SEAT_DECIDED)" ;;
    esac
  fi
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) prelaunch_die "unverified remote secondmate harness: $harness" ;;
  esac
  case "$effort" in -|low|medium|high|xhigh|max|ultra) ;; *) prelaunch_die "invalid remote secondmate effort: $effort" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" \
      || prelaunch_die "remote secondmate native effort validation failed"
  fi
  # Herdr is required on this host, not merely preferred: its server belongs to
  # the GUI login session, so the endpoint survives every SSH disconnection that
  # a remote route depends on. bin/fm-remote-doctor.sh is the readiness owner.
  case "$selected_backend" in herdr) ;; *) prelaunch_die "a remote secondmate runs only on the herdr backend, not '$selected_backend'" ;; esac
  mkdir -p "$CONTROL_STATE" "$CONTROL_DATA" || prelaunch_die "remote endpoint directories could not be created"
  meta=$(meta_path "$id")
  if [ -f "$meta" ]; then
    remote_endpoint_load "$id" || prelaunch_die "$REMOTE_ENDPOINT_ERROR"
    seat_predecessor_ready
    current=$(fm_backend_agent_state "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null || printf 'unreadable\n')
    case "$current" in
      alive)
        if [ -n "$SEAT_OP" ]; then
          seat_receipt_set phase=existing "actual_generation=$(fm_meta_get "$meta" spawn_gen)" \
            "route_backend=$REMOTE_ENDPOINT_BACKEND" "route_target=$REMOTE_ENDPOINT_TARGET" \
            "actual_model=$(fm_meta_get "$meta" model)" 2>/dev/null || true
          seat_decide "$id"
        fi
        print_route "$id"
        return 0
        ;;
      dead)
        fm_backend_kill "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" 2>/dev/null \
          || prelaunch_die "could not remove the confirmed agent-less endpoint"
        ;;
      missing) ;;
      *) prelaunch_die "remote endpoint state is $current; refusing duplicate launch" ;;
    esac
  fi
  # The parent owns both convergence legs before it asks for this launch: it
  # already fast-forwarded this home to ITS primary commit and pushed inherited
  # local material, so this spawn must not redo either against this host's own
  # Firstmate copy, which would target the wrong checkout.
  ARGS=("$id" "$TARGET_HOME" --secondmate --harness "$harness" --backend "$selected_backend")
  [ "$model" = - ] || ARGS+=(--model "$model")
  [ "$effort" = - ] || ARGS+=(--effort "$effort")
  [ -z "$traceparent" ] || ARGS+=(--traceparent "$traceparent")
  if ! out=$(HERDR_SESSION="$REMOTE_HERDR_SESSION" FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_SKIP_SECONDMATE_SYNC=1 FM_REMOTE_SEAT_OPERATION="$SEAT_OP" FM_SPAWN_SEAT_GENERATION="$SEAT_OP" \
    "$SCRIPT_DIR/fm-spawn.sh" "${ARGS[@]}" 2>&1); then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    [ -z "$SEAT_OP" ] || seat_decide "$id"
    die "remote host-local secondmate launch failed"
  fi
  [ -z "$SEAT_OP" ] || seat_decide "$id"
  [ -f "$meta" ] || die "remote launch returned without endpoint metadata"
  herdr_session=$(fm_meta_get "$meta" herdr_session)
  [ "$herdr_session" = "$REMOTE_HERDR_SESSION" ] \
    || die "remote launch recorded Herdr session '${herdr_session:-missing}', expected '$REMOTE_HERDR_SESSION'"
  print_route "$id"
}

# Restart the second-mate agent this host runs, by executing the ORDINARY local
# control plane here. From this host's point of view the mate is a plain local
# secondmate: its endpoint record under the private parent-route state directory
# was written by a host-local fm-spawn and carries no remote_host= field, so
# bin/fm-control.sh's remote refusal never fires, and every checkpoint, journal,
# rollback, and postcondition that plane owns applies unchanged. This verb is the
# transport hop, not a second implementation.
#
# harness/model/effort come from the PARENT and are passed explicitly, because
# config/secondmate-harness is deliberately not inherited into a secondmate home:
# the copy on this host is a different home's file, so letting the control plane
# re-resolve it here would silently drift the mate onto another runtime. `default`
# explicitly clears an absent parent pin; `-` remains its compatibility spelling.
cmd_relaunch() {
  local id=$1 harness=$2 model=$3 effort=$4 enter_rc=0 control_rc=0
  local -a control_args

  validate_id "$id"
  SEAT_LIFECYCLE_ID=$id
  ( validate_home "$id" ) || prelaunch_die "remote secondmate home validation failed"
  seat_enter "$id" relaunch "$model" || enter_rc=$?
  if [ "$enter_rc" -eq 3 ]; then
    case "$SEAT_DECIDED" in
      started) remote_endpoint_load "$id" && print_route "$id"; return 0 ;;
      *) die "seat operation $SEAT_OP was already handled on this host ($SEAT_DECIDED)" ;;
    esac
  fi
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi|cursor) ;;
    *) prelaunch_die "unverified remote secondmate harness: $harness" ;;
  esac
  case "$effort" in -|default|low|medium|high|xhigh|max|ultra) ;; *) prelaunch_die "invalid remote secondmate effort: $effort" ;; esac
  case "$model" in *[[:space:]]*) prelaunch_die "invalid remote secondmate model: $model" ;; esac
  if [ "$effort" = ultra ]; then
    "$SCRIPT_DIR/fm-harness.sh" validate-native-effort "$harness" "$model" "$effort" \
      || prelaunch_die "remote secondmate native effort validation failed"
  fi
  if [ -n "$EXPECT_GENERATION" ] && [ "$(fm_meta_get "$(meta_path "$id")" spawn_gen)" != "$EXPECT_GENERATION" ]; then
    if [ -n "$SEAT_OP" ]; then
      seat_receipt_set phase=prelaunch || die "could not record the generation mismatch"
      seat_emit prelaunch false false
    fi
    echo "error: generation-mismatch: the host incarnation is not $EXPECT_GENERATION; nothing was changed" >&2
    exit 6
  fi
  remote_endpoint_load "$id" || prelaunch_die "$REMOTE_ENDPOINT_ERROR"
  seat_predecessor_ready
  [ "$model" != - ] || model=default
  [ "$effort" != - ] || effort=default
  control_args=("$id" relaunch --harness "$harness" --model "$model" --effort "$effort")
  [ -z "$EXPECT_GENERATION" ] || control_args+=(--expect-generation "$EXPECT_GENERATION")
  # The same launch-boundary facts cmd_launch establishes: the endpoint lives in
  # the dedicated fm-remote session, and the parent already owns both convergence
  # legs, so the host-local spawn must not re-sync or re-inherit against this
  # host's own Firstmate copy.
  HERDR_SESSION="$REMOTE_HERDR_SESSION" FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_SKIP_SECONDMATE_SYNC=1 FM_REMOTE_SEAT_OPERATION="$SEAT_OP" \
    FM_SPAWN_SEAT_GENERATION="$SEAT_OP" \
    "$SCRIPT_DIR/fm-control.sh" "${control_args[@]}" || control_rc=$?
  [ -z "$SEAT_OP" ] || seat_decide "$id"
  [ "$control_rc" -eq 0 ] || exit "$control_rc"
  # A parent tracking this route needs the identity the relaunch actually
  # produced, not the one it asked for, so it can republish its own record the
  # same way cmd_launch's caller already does. Reading it back from the
  # endpoint's own republished metadata - rather than trusting these argv
  # values - is what makes that record correct even when relaunch resolved
  # "default" against a configured pin this call never saw.
  print_route "$id"
}

cmd_disposition() {
  local id=$1
  validate_id "$id"
  SEAT_LIFECYCLE_ID=$id
  [ "${2:-}" = --operation ] && [ -n "${3:-}" ] || usage
  SEAT_OP=$3
  case "$SEAT_OP" in *[!A-Za-z0-9.]*) die "invalid seat operation token" ;; esac
  if ! ( validate_home "$id" ) 2>/dev/null; then
    seat_emit unknown false false
    return 0
  fi
  if [ ! -d "$CONTROL_STATE" ] || ! fm_supervisor_lifecycle_enter "$CONTROL_STATE" "$id" 0; then
    seat_emit unknown false false
    return 0
  fi
  trap 'fm_supervisor_lifecycle_release "$CONTROL_STATE" "$SEAT_LIFECYCLE_ID"' EXIT
  seat_decide "$id"
}

cmd_send() {
  local id=$1 message=$2 delivery_mode=${3:-} rec ring_rc=0 meta meta_lock
  validate_id "$id"
  [ -z "$delivery_mode" ] || [ "$delivery_mode" = fire-and-forget ] || die "invalid send delivery mode"
  validate_home "$id"
  meta=$(meta_path "$id")
  meta_lock=$(fm_meta_lock_path "$meta") || die "remote secondmate metadata lock path is invalid"
  fm_task_inbox_lock_acquire "$meta_lock" \
    || die "remote secondmate endpoint metadata could not be locked for final delivery validation"
  if ! remote_endpoint_load "$id"; then
    fm_lock_release "$meta_lock"
    die "$REMOTE_ENDPOINT_ERROR"
  fi
  # A remote steer is delivered by durable record, never by typing its payload
  # into the pane: write it into this secondmate's host-local steering inbox,
  # then ring the constant self-describing doorbell into the recorded pane,
  # best-effort (bin/fm-task-inbox-lib.sh owns the record and doorbell). The
  # write is idempotent - re-running the same request after an ambiguous
  # transport failure lands on the existing record instead of a duplicate - so
  # the parent may safely repeat this leg. Exit 0 once the record durably
  # exists; no ring outcome changes it, because the parent transport owns any
  # retry or reply-tracking policy from here.
  if ! rec=$(fm_task_inbox_write_idempotent "$CONTROL_STATE" "$id" "$message" "$delivery_mode"); then
    fm_lock_release "$meta_lock"
    die "steering-inbox record could not be written under $CONTROL_STATE/$id.inbox"
  fi
  fm_lock_release "$meta_lock"
  case "$rec" in
    */handled/*)
      # The dedup landed on a record the worker already acknowledged: the
      # steer was delivered and acted on, so there is nothing to announce.
      printf 'notice: this steer was already delivered and acknowledged at %s; nothing re-rung\n' "$rec" >&2
      return 0
      ;;
  esac
  fm_task_inbox_ring "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$rec" "fm-$id" || ring_rc=$?
  case "$ring_rc" in
    1) printf 'notice: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at %s\n' "$rec" >&2 ;;
    2) printf 'notice: doorbell did not reach %s; the steer is durably recorded at %s\n' "$REMOTE_ENDPOINT_TARGET" "$rec" >&2 ;;
    3) printf 'notice: doorbell not typed because the agent in %s has exited; the steer is durably recorded at %s for recovery\n' "$REMOTE_ENDPOINT_TARGET" "$rec" >&2 ;;
  esac
}

cmd_key() {
  local id=$1 key=$2
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    "$SCRIPT_DIR/fm-send.sh" "$REMOTE_ENDPOINT_TARGET" --key "$key"
}

cmd_capture() {
  local id=$1 lines=${2:-20}
  validate_id "$id"
  validate_home "$id"
  case "$lines" in ''|*[!0-9]*|0) die "capture line count must be positive" ;; esac
  [ "$lines" -le 100 ] || die "capture line count exceeds 100"
  remote_endpoint_require "$id"
  fm_backend_capture "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "$lines" "fm-$id" | head -c 65536
}

cmd_observe() {
  local id=$1 harness
  validate_id "$id"
  validate_home "$id"
  remote_endpoint_require "$id"
  harness=$(fm_meta_get "$REMOTE_ENDPOINT_META" harness)
  fm_pending_reply_backend_observation "$REMOTE_ENDPOINT_BACKEND" "$REMOTE_ENDPOINT_TARGET" "fm-$id" "$harness"
  printf '\n'
}

# Make <commit> readable in this home's own object store without moving any other
# checkout. Ordered by cost: already present, then this host's Firstmate copy (a
# read-only fetch of that one commit, which never advances that copy's HEAD), then
# the home's own origin for that one commit. No pack transport beyond those two.
import_home_commit() { # <home> <commit>
  local home=$1 commit=$2
  if git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then return 0; fi
  if git -C "$home" fetch --quiet --no-tags -- "$FM_ROOT" "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  if git -C "$home" remote get-url origin >/dev/null 2>&1 \
    && git -C "$home" fetch --quiet --no-tags -- origin "$commit" 2>/dev/null \
    && git -C "$home" cat-file -e "$commit^{commit}" 2>/dev/null; then
    return 0
  fi
  return 1
}

cmd_sync() {
  local id=$1 commit report out
  validate_id "$id"
  validate_home "$id"
  if [ "$#" -ge 2 ]; then
    commit=$2
    case "$commit" in *[!0-9a-f]*) die "sync target must be a full 40-character commit id" ;; esac
    [ "${#commit}" -eq 40 ] || die "sync target must be a full 40-character commit id"
  else
    commit=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null) || die "remote code root HEAD is unreadable"
  fi
  import_home_commit "$TARGET_HOME" "$commit" \
    || die "remote home could not import $commit from this host's Firstmate copy or the home's origin; run /updatefirstmate to refresh this host's copy, or push that commit first"
  # ff_target publishes its verdict in FF_STATUS, so it must run in THIS shell.
  report=$(mktemp "${TMPDIR:-/tmp}/fm-remote-sync.XXXXXX") || die "cannot stage the sync report"
  ff_target "$TARGET_HOME" "remote home" "$commit" yes yes "$id" "$TARGET_HOME/state" > "$report" 2>&1
  out=$(cat "$report")
  rm -f "$report"
  case "$FF_STATUS" in
    # instr= names the watched instruction paths this advance changed, with no
    # spaces so the whole result stays one parseable line. The parent needs it to
    # decide whether the running agent must reload; an older parent ignores the
    # suffix, and an older HOST omits it, which a parent must read as unknown
    # rather than as "nothing changed".
    updated) printf 'synced: %s instr=%s\n' "$commit" "$(printf '%s' "$FF_INSTR" | tr -d ' ')" ;;
    current) printf 'current: %s\n' "$commit" ;;
    *) die "remote secondmate home sync skipped: ${out#remote home: skipped: }" ;;
  esac
}

cmd_update() {
  local id=$1 update_out root_status
  validate_id "$id"
  validate_home "$id"
  if ! update_out=$(FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/fm-update.sh" 2>&1); then
    [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
    die "remote code root update failed"
  fi
  root_status=$(printf '%s\n' "$update_out" | grep '^firstmate:' | tail -1)
  case "$root_status" in
    'firstmate: updated '*|'firstmate: already current'*) ;;
    *)
      [ -z "$update_out" ] || printf '%s\n' "$update_out" >&2
      die "remote code root did not complete a safe origin update"
      ;;
  esac
  cmd_sync "$id"
}

cmd_retire() {
  local id=$1 force=${2:-} rc
  validate_id "$id"
  validate_home "$id" yes || rc=$?
  if [ "${rc:-0}" -eq 2 ]; then
    printf 'already-retired: %s\n' "$id"
    return 0
  fi
  [ -z "$force" ] || [ "$force" = --force ] || usage
  remote_endpoint_require "$id"
  FM_HOME="$TARGET_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$TARGET_HOME/state" \
    FM_CONFIG_OVERRIDE="$TARGET_HOME/config" "$SCRIPT_DIR/fm-guard.sh" || true
  if [ -n "$force" ]; then
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id" --force
  else
    FM_HOME="$FM_ROOT" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$CONTROL_STATE" FM_DATA_OVERRIDE="$CONTROL_DATA" \
      FM_CONFIG_OVERRIDE="$TARGET_HOME/config" FM_TEARDOWN_GUARD_DONE=1 \
      "$SCRIPT_DIR/fm-teardown.sh" "$id"
  fi
}

case "${1:-}" in
  launch)
    shift
    seat_parse_operation "$@"
    [ "${#SEAT_ARGS[@]}" -ge 5 ] && [ "${#SEAT_ARGS[@]}" -le 6 ] || usage
    cmd_launch "${SEAT_ARGS[@]}"
    ;;
  relaunch)
    shift
    seat_parse_operation "$@"
    [ "${#SEAT_ARGS[@]}" -eq 4 ] || usage
    cmd_relaunch "${SEAT_ARGS[@]}"
    ;;
  disposition) shift; [ "$#" -eq 3 ] || usage; cmd_disposition "$@" ;;
  state) shift; [ "$#" -eq 1 ] || usage; validate_id "$1"; validate_home "$1"; state_value "$1" ;;
  route) shift; [ "$#" -eq 1 ] || usage; cmd_route "$1" ;;
  send) shift; [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; cmd_send "$@" ;;
  key) shift; [ "$#" -eq 2 ] || usage; cmd_key "$@" ;;
  capture) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_capture "$@" ;;
  observe) shift; [ "$#" -eq 1 ] || usage; cmd_observe "$@" ;;
  sync) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_sync "$@" ;;
  update) shift; [ "$#" -eq 1 ] || usage; cmd_update "$@" ;;
  retire) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
