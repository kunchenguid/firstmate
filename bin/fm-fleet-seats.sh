#!/usr/bin/env bash
# fm-fleet-seats.sh - opt-in fleet-wide active-agent seat pools for shared model endpoints.
#
# docs/configuration.md "Fleet seat pools" owns the operator contract: the
# config/fleet-seats schema, what a seat is, which homes share one pool, and
# what the refusals mean. This header owns the mechanics.
#
# A seat is an active agent slot on a pooled model, never an inference
# request. The holders of a pool are, keyed by canonical state directory plus
# id:
#   - every ship or scout whose task record names a pooled model, from
#     reservation until cleanup removes the record or a relaunch republishes it
#     on a model outside the pool;
#   - every live secondmate supervisor whose task record in the root names a
#     pooled model, including idle supervisors;
#   - the primary supervisor, keyed "<root-state>\t.primary", when the root's
#     config/fleet-seats declares "primary_model" in a pool and the root's
#     session lock is not provably free or stale (bin/fm-session-lock-lib.sh).
#     No primary busy record exists, so a live primary is indeterminate and
#     counts. A running primary is never refused or preempted.
#
# THE AUTHORITY. Every home resolves the one fleet root with
# fm_firstmate_root_home (bin/fm-wake-lib.sh): the primary is its own root, and
# a local secondmate walks its .fm-secondmate-parent binding to the primary.
# The root's config/fleet-seats declares the pools, and every grant is decided
# under the root's lock (<root>/state/.fleet-seats.lock), so no two homes can
# both take the last seat.
#
# COUNTING AT THE ROOT. Under the root lock, a pool's holders are the union of:
#   - live seat records in <root>/state/fleet-seats/<pool>/*.seat. A record is
#     live while its task record is pooled and active (as above), or while its
#     reserving process (recorded pid plus pid identity) still runs, which
#     covers a spawn that reserved before publishing its record. A record that
#     is neither is stale and removed; a live task record is never reclaimed,
#     so recovery never preempts running work.
#   - pooled active task records in the root home and in every local
#     secondmate registered in the root's data/secondmates.md, so agents
#     launched before a pool existed count without any reservation.
#   - the primary supervisor, as above.
#   - for each registered remote secondmate, the holders that home returned
#     from its last successful serve, cached in
#     <root>/state/fleet-seats/remote-<id>.holders ("remote:<id>" keys), with
#     the policy digest it confirmed in remote-<id>.policy. A failed serve
#     keeps the previous snapshot, so an unreachable remote's seats stay
#     counted.
# The root refuses (exit 5) instead of counting when any registered remote has
# not confirmed the current policy digest, a registered remote snapshot is
# absent, a registry line cannot be parsed, a registered local home cannot be
# listed, or a task record cannot be read.
#
# REMOTE HOMES. A home whose walk ends at a remote parent binding cannot reach
# the root, so the root delivers the policy and grants seats to it:
#   - the root's serve-remotes (run from the root's watcher) calls serve on
#     each registered remote through bin/fm-on.sh while holding the root lock.
#     It sends the root's pool declaration on stdin (an empty "pools" list
#     when the root has none) plus the policy digest and each pool's
#     allowance (capacity minus every other holder, or 0 while another remote
#     is unconfirmed).
#   - under the remote's own lock, serve stores the delivered policy in
#     <home>/state/fleet-seats/policy.json, prunes dead seats, grants waiting
#     requests in arrival order while its holders stay within the allowance,
#     denies the rest, and prints "policy <digest>" plus one
#     "holder <pool> <id>" line per seat, which become the root's snapshot.
#   - reserve requires a delivered policy, files a request for every model,
#     and waits (bounded) for the root's next serve to confirm that exact
#     policy and model. Pooled requests also require a seat grant. A timeout
#     withdraws the request and refuses unless confirmation landed first.
#
# EXPLICIT MODELS. While any pool is configured, a ship, scout, or secondmate
# on a multi-provider harness (pi, pi-signed, omp, opencode) refuses without an
# explicit --model, because that harness's own default could be a pooled model
# nothing counted.
#
# Usage:
#   fm-fleet-seats.sh reserve <id> --harness <harness> --model <model|default> --holder-pid <pid>
#       Reserve a seat for this home's <id> when <model> belongs to a pool.
#       Prints nothing and exits 0 when no pool names the model (or no pool is
#       configured locally); prints "fleet-seats: reserved ..." on success.
#       An id that already holds a seat keeps it even when the pool is full.
#       <holder-pid> is the long-lived reserving process
#       (bin/fm-spawn.sh passes its own pid) and must be alive.
#   fm-fleet-seats.sh serve-remotes
#       Root only (a no-op anywhere else): serve every registered remote
#       secondmate and print one "served <id> ..." or "unreachable <id>" line
#       each. A remote that failed is skipped for a fixed backoff.
#   fm-fleet-seats.sh serve --digest <digest> [--allowance <pool>=<n>]...
#       Remote home only; the root runs it through bin/fm-on.sh with the pool
#       declaration on stdin.
#
# Fixed bounds: 30s lock wait, 90s remote request wait, 20s per remote serve
# call, 120s backoff after a failed serve. FM_FLEET_SEATS_TEST_REMOTE_WAIT and
# FM_FLEET_SEATS_TEST_BACKOFF shorten the last two for the regression suite
# only; they are not operator settings.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_DATA_OVERRIDE resolve the calling home as the other bin/ scripts do; they
# also select the root's own directories when the caller is the root.
#
# Exit status: 0 reserved, not pooled, or served; 2 usage error; 4 the pool is
# full; 5 the accounting authority is unreachable, unconfirmed, unreadable, or
# misconfigured, or an explicit model is required. Exit 4 and 5 both mean no
# seat: choose another route.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

EXIT_FULL=4
EXIT_UNAVAILABLE=5
LOCK_WAIT=30
REMOTE_WAIT=${FM_FLEET_SEATS_TEST_REMOTE_WAIT:-90}
SERVE_TIMEOUT=20
SERVE_BACKOFF=${FM_FLEET_SEATS_TEST_BACKOFF:-120}

usage() {
  echo "usage: fm-fleet-seats.sh reserve <id> --harness <harness> --model <model|default> --holder-pid <pid> | serve-remotes | serve --digest <digest> [--allowance <pool>=<n>]..." >&2
  exit 2
}

unavailable() {
  echo "fleet-seats: no seat - $* (a pooled model is never launched without a counted seat; choose another route or repair the authority)" >&2
  exit "$EXIT_UNAVAILABLE"
}

canon_dir() { CDPATH='' cd -- "$1" 2>/dev/null && pwd -P; }
is_count() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
id_ok() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }

# validate_pools <file>: a readable, well-formed pool declaration, or fail.
# An empty "pools" list is valid and means no pool.
validate_pools() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  jq -e '
    (.pools | type == "array")
    and all(.pools[];
      (.name | type == "string" and test("^[A-Za-z0-9._-]+$"))
      and (.capacity | type == "number" and . >= 0 and . == floor)
      and (.models | type == "array" and length > 0
           and all(.[]; type == "string" and length > 0)))
    and ([.pools[].name] | length == (unique | length))
    and ([.pools[].models[]] | length == (unique | length))
    and ((has("primary_model") | not) or (.primary_model | type == "string" and length > 0))
  ' "$file" >/dev/null 2>&1
}

pool_count() { jq -r '.pools | length' "$1"; }

# pool_for_model <file> <model>: print "<name>\t<capacity>" for the pool naming it.
pool_for_model() {
  jq -r --arg m "$2" '.pools[] | select(.models | index($m)) | "\(.name)\t\(.capacity)"' "$1"
}

# pool_models <file> <pool>: one model per line.
pool_models() {
  jq -r --arg p "$2" '.pools[] | select(.name == $p) | .models[]' "$1"
}

policy_digest() { jq -cS . "$1" | cksum | tr -s ' ' '-' | cut -d- -f1-2; }

# Resolve the authority for the calling home. Sets ROOT_REMOTE=1 when the walk
# ends at a remote parent binding, else ROOT_STATE / ROOT_CONFIG / ROOT_DATA,
# with ROOT_SELF=1 when this home is the root.
resolve_authority() {
  local home_canon root
  ROOT_REMOTE=0 ROOT_SELF=0
  ROOT_STATE='' ROOT_CONFIG='' ROOT_DATA=''
  home_canon=$(canon_dir "$FM_HOME") || return 1
  root=$(fm_firstmate_root_home "$home_canon") || return 1
  if [ -e "$root/.fm-secondmate-parent" ] || [ -L "$root/.fm-secondmate-parent" ]; then
    fm_secondmate_parent_record_parse "$root/.fm-secondmate-parent" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ] || return 1
    ROOT_REMOTE=1
    return 0
  fi
  if [ "$root" = "$home_canon" ]; then
    ROOT_SELF=1
    ROOT_STATE=$STATE ROOT_CONFIG=$CONFIG ROOT_DATA=$DATA
  else
    ROOT_STATE=$root/state ROOT_CONFIG=$root/config ROOT_DATA=$root/data
  fi
}

# meta_state <meta> <models-file>: "pooled", "other", "absent", or "unreadable".
meta_state() {
  local meta=$1 models=$2 model kind home
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    echo absent
    return
  fi
  [ -f "$meta" ] && [ -r "$meta" ] || { echo unreadable; return; }
  model=$(sed -n 's/^model=//p' "$meta" | tail -1)
  if [ -z "$model" ] || ! grep -Fxq -- "$model" "$models"; then
    echo other
    return
  fi
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  if [ "$kind" = secondmate ] && [ -z "$(sed -n 's/^remote_host=//p' "$meta" | tail -1)" ]; then
    home=$(sed -n 's/^home=//p' "$meta" | tail -1)
    if [ -n "$home" ] && [ -d "$home/state" ]; then
      fm_session_lock_inspect "$home/state"
      case "$FM_LOCK_INSPECT_STATE" in free|stale) echo other; return ;; esac
    fi
  fi
  echo pooled
}

# holder_alive <pid> <identity>: the reserving process is still the same process.
holder_alive() {
  local pid=$1 identity=$2 now
  fm_pid_alive "$pid" || return 1
  [ -n "$identity" ] || return 0
  now=$(fm_pid_identity "$pid") || return 0
  [ "$now" = "$identity" ]
}

record_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

seat_name() { printf '%s\t%s' "$1" "$2" | cksum | tr -s ' ' '-' | cut -d- -f1-2; }

# write_record <path> <state> <id> <model> <pid> [nonce]: publish atomically.
write_record() {
  local path=$1 identity
  identity=$(fm_pid_identity "$5" 2>/dev/null || true)
  {
    echo "state=$2"
    echo "task=$3"
    echo "model=$4"
    echo "pid=$5"
    printf 'pid_identity=%s\n' "$identity"
    echo "nonce=${6:-}"
    echo "policy=${7:-}"
    echo "at=$(date +%s)"
  } > "$path.tmp.$$" && mv -f "$path.tmp.$$" "$path"
}

# seat_records <dir> <models-file> <remove-stale 0|1>: "<state>\t<id>" per live record.
seat_records() {
  local dir=$1 models=$2 remove_stale=$3 f st task verdict
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.seat; do
    [ -f "$f" ] || continue
    st=$(record_field "$f" state)
    task=$(record_field "$f" task)
    if [ -z "$st" ] || [ -z "$task" ]; then
      [ "$remove_stale" -eq 0 ] || rm -f "$f"
      continue
    fi
    verdict=$(meta_state "$st/$task.meta" "$models")
    case "$verdict" in
      pooled|unreadable) printf '%s\t%s\n' "$st" "$task" ;;
      *)
        if holder_alive "$(record_field "$f" pid)" "$(record_field "$f" pid_identity)"; then
          printf '%s\t%s\n' "$st" "$task"
        elif [ "$remove_stale" -eq 1 ]; then
          rm -f "$f"
        fi
        ;;
    esac
  done
}

# pooled_records <state-dir> <models-file>: "<state>\t<id>" per pooled active record.
pooled_records() {
  local home_state=$1 models=$2 meta id verdict
  [ -r "$home_state" ] && [ -x "$home_state" ] || return 1
  for meta in "$home_state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    id_ok "$id" || continue
    verdict=$(meta_state "$meta" "$models")
    case "$verdict" in pooled|unreadable) printf '%s\t%s\n' "$home_state" "$id" ;; esac
  done
}

# primary_counts <state-dir>: the primary's session lock is not provably free
# or stale.
primary_counts() {
  fm_session_lock_inspect "$1"
  case "$FM_LOCK_INSPECT_STATE" in free|stale) return 1 ;; esac
  return 0
}

# registry_homes: fill $TMPD/local-homes (canonical state dirs) and
# $TMPD/remote-ids from the root registry. A record line that parses under
# neither form fails, because its home's agents would go uncounted.
registry_homes() {
  local reg=$ROOT_DATA/secondmates.md line home
  : > "$TMPD/local-homes"
  : > "$TMPD/remote-ids"
  canon_dir "$ROOT_STATE" >> "$TMPD/local-homes" || return 1
  [ -e "$reg" ] || return 0
  [ -f "$reg" ] && [ -r "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! secondmate_registry_parse_line "$line"; then
      REGISTRY_ERROR="unparseable secondmate registry line: $line"
      return 1
    fi
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      printf '%s\n' "$SECONDMATE_REGISTRY_ID" >> "$TMPD/remote-ids"
      continue
    fi
    home=$SECONDMATE_REGISTRY_HOME
    [ -d "$home" ] && [ -d "$home/state" ] || return 1
    canon_dir "$home/state" >> "$TMPD/local-homes" || return 1
  done < "$reg"
}

# root_holders <pool> <models-file> <remove-stale 0|1> [excluded-remote-id]:
# every holder the root counts, one "<key>\t<id>" per line, sorted unique.
# Returns 3 (with UNCONFIRMED set) when another registered remote has not
# confirmed the current policy.
root_holders() {
  local pool=$1 models=$2 remove_stale=$3 exclude=${4:-} dir home_state id primary
  dir="$ROOT_STATE/fleet-seats"
  UNCONFIRMED=
  registry_homes || return 1
  {
    seat_records "$dir/$pool" "$models" "$remove_stale"
    while IFS= read -r home_state; do
      pooled_records "$home_state" "$models" || return 1
    done < "$TMPD/local-homes"
    primary=$(jq -r '.primary_model // empty' "$POOLS")
    if [ -n "$primary" ] && grep -Fxq -- "$primary" "$models" && primary_counts "$ROOT_STATE"; then
      printf '%s\t.primary\n' "$(canon_dir "$ROOT_STATE")"
    fi
    while IFS= read -r id; do
      [ "$id" != "$exclude" ] || continue
      if [ "$(cat "$dir/remote-$id.policy" 2>/dev/null)" != "$DIGEST" ]; then
        UNCONFIRMED="$UNCONFIRMED $id"
        continue
      fi
      [ -f "$dir/remote-$id.holders" ] && [ -r "$dir/remote-$id.holders" ] || return 1
      awk -F '\t' -v p="$pool" '$1 == p && NF == 2 { print $2 }' "$dir/remote-$id.holders" | while IFS= read -r task; do
        printf 'remote:%s\t%s\n' "$id" "$task"
      done
    done < "$TMPD/remote-ids"
  } > "$TMPD/holders.raw" || return 1
  sort -u "$TMPD/holders.raw"
  [ -z "$UNCONFIRMED" ] || return 3
}

# remote_holders <pool> <models-file> <remove-stale 0|1>: a remote home's own seats.
remote_holders() {
  local pool=$1 models=$2 remove_stale=$3 own
  own=$(canon_dir "$STATE") || return 1
  {
    seat_records "$STATE/fleet-seats/$pool" "$models" "$remove_stale"
    pooled_records "$own" "$models" || return 1
  } > "$TMPD/holders.raw" || return 1
  sort -u "$TMPD/holders.raw"
}

lock_or_refuse() {  # <lock>
  fm_lock_acquire_wait_max "$1" "$LOCK_WAIT" \
    || unavailable "the fleet seat lock $1 stayed held by pid ${FM_LOCK_HELD_PID:-unknown}"
  LOCK_HELD=$1
}

unlock() {
  [ -z "$LOCK_HELD" ] || fm_lock_release "$LOCK_HELD" || true
  LOCK_HELD=
}

print_full() {  # <pool> <used> <cap> <holders-file|->
  echo "fleet-seats: pool $1 is full ($2 of $3 seats held); $TASK gets no seat for model $MODEL - choose an overflow route or wait for a holder to finish" >&2
  [ "$4" = - ] && return 0
  while IFS=$'\t' read -r st task; do
    echo "  holder $st $task" >&2
  done < "$4"
}

# require_explicit_model <pools-file>: refuse a harness default while pools exist.
require_explicit_model() {
  [ "$(pool_count "$1")" -gt 0 ] || return 0
  case "$MODEL" in ''|default) ;; *) return 0 ;; esac
  case "$HARNESS" in
    pi|pi-signed|omp|opencode)
      unavailable "harness $HARNESS launches its own default model, which may be pooled; pass an explicit --model while fleet seat pools are configured"
      ;;
  esac
}

CMD=${1:-}
shift 2>/dev/null || true
TASK='' MODEL='' HOLDER='' HARNESS='' DIGEST_ARG=''
ALLOWANCES=''
case "$CMD" in
  reserve)
    TASK=${1:-}
    shift 2>/dev/null || true
    id_ok "$TASK" || usage
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --model) MODEL=${2:-}; shift 2 || usage ;;
        --harness) HARNESS=${2:-}; shift 2 || usage ;;
        --holder-pid) HOLDER=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    [ -n "$HOLDER" ] || usage
    ;;
  serve-remotes) [ "$#" -eq 0 ] || usage ;;
  serve)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --digest) DIGEST_ARG=${2:-}; shift 2 || usage ;;
        --allowance)
          case "${2:-}" in
            *=*) { is_count "${2#*=}" && id_ok "${2%%=*}"; } || usage ;;
            *) usage ;;
          esac
          ALLOWANCES="$ALLOWANCES ${2}"
          shift 2
          ;;
        *) usage ;;
      esac
    done
    case "$DIGEST_ARG" in ''|*[!0-9-]*) usage ;; esac
    ;;
  *) usage ;;
esac

command -v jq >/dev/null 2>&1 || unavailable "jq is not installed"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-seats.XXXXXX") || unavailable "cannot create a scratch directory"
LOCK_HELD=
REGISTRY_ERROR=
cleanup() {
  unlock
  rm -rf "$TMPD"
}
trap cleanup EXIT

if ! resolve_authority; then
  case "$CMD" in serve-remotes) exit 0 ;; esac
  unavailable "this home's fleet root cannot be resolved from its secondmate parent binding"
fi

# --- remote home -------------------------------------------------------------

if [ "$ROOT_REMOTE" -eq 1 ]; then
  [ "$CMD" != serve-remotes ] || exit 0
  OWN_STATE=$(canon_dir "$STATE") || unavailable "this home's state directory $STATE is missing"
  DELIVERED=$STATE/fleet-seats/policy.json
  LOCK=$STATE/.fleet-seats.lock

  if [ "$CMD" = serve ]; then
    mkdir -p "$STATE/fleet-seats" || unavailable "cannot create $STATE/fleet-seats"
    cat > "$TMPD/delivered" || unavailable "cannot read the delivered policy"
    validate_pools "$TMPD/delivered" || unavailable "the delivered policy is malformed"
    [ "$(policy_digest "$TMPD/delivered")" = "$DIGEST_ARG" ] || unavailable "the delivered policy does not match digest $DIGEST_ARG"
    lock_or_refuse "$LOCK"
    { cp "$TMPD/delivered" "$DELIVERED.tmp.$$" && mv -f "$DELIVERED.tmp.$$" "$DELIVERED"; } || unavailable "cannot store the delivered policy"
    echo "policy $DIGEST_ARG"
    for f in "$STATE/fleet-seats"/*/requests/*.req; do
      [ -f "$f" ] || continue
      request_pool=${f%/requests/*}
      request_pool=${request_pool##*/}
      request_model=$(record_field "$f" model)
      current_pool=$(pool_for_model "$DELIVERED" "$request_model")
      current_pool=${current_pool%%$'\t'*}
      if [ "$(record_field "$f" policy)" != "$DIGEST_ARG" ] \
        || { [ "$request_pool" = @checks ] && [ -n "$current_pool" ]; } \
        || { [ "$request_pool" != @checks ] && [ "$request_pool" != "$current_pool" ]; }; then
        response=${f%/requests/*}/${f##*/}
        response=${response%.req}.rejected
        printf 'nonce=%s\n' "$(record_field "$f" nonce)" > "$response.tmp.$$" \
          && mv -f "$response.tmp.$$" "$response" \
          || unavailable "cannot reject a stale seat request"
        rm -f "$f"
      fi
    done
    jq -r '.pools[].name' "$DELIVERED" > "$TMPD/pools"
    while IFS= read -r pool; do
      allowance=0
      for a in $ALLOWANCES; do
        [ "${a%%=*}" != "$pool" ] || allowance=${a#*=}
      done
      capacity=$(jq -r --arg p "$pool" '.pools[] | select(.name == $p) | .capacity' "$DELIVERED")
      pool_models "$DELIVERED" "$pool" > "$TMPD/models"
      SEATDIR=$STATE/fleet-seats/$pool
      mkdir -p "$SEATDIR/requests" || unavailable "cannot create $SEATDIR"
      remote_holders "$pool" "$TMPD/models" 1 > "$TMPD/holders" || unavailable "this home's task records cannot be read"
      # Arrival order: oldest request first.
      for f in "$SEATDIR/requests"/*.req; do
        [ -f "$f" ] || continue
        printf '%s\t%s\n' "$(record_field "$f" at)" "$f"
      done | sort -n > "$TMPD/requests"
      while IFS=$'\t' read -r _ f; do
        name=${f##*/}
        name=${name%.req}
        st=$(record_field "$f" state)
        task=$(record_field "$f" task)
        pid=$(record_field "$f" pid)
        if [ -z "$st" ] || [ -z "$task" ] || ! holder_alive "$pid" "$(record_field "$f" pid_identity)"; then
          rm -f "$f"
          continue
        fi
        key=$(printf '%s\t%s' "$st" "$task")
        used=$(wc -l < "$TMPD/holders" | tr -d ' ')
        if grep -Fxq -- "$key" "$TMPD/holders" || [ "$used" -lt "$allowance" ]; then
          if ! { cp "$f" "$SEATDIR/$name.seat.tmp.$$" && mv -f "$SEATDIR/$name.seat.tmp.$$" "$SEATDIR/$name.seat"; }; then
            continue
          fi
          grep -Fxq -- "$key" "$TMPD/holders" || printf '%s\n' "$key" >> "$TMPD/holders"
        else
          {
            echo "nonce=$(record_field "$f" nonce)"
            echo "used=$((used + capacity - allowance))"
            echo "capacity=$capacity"
          } > "$SEATDIR/$name.denied.tmp.$$" && mv -f "$SEATDIR/$name.denied.tmp.$$" "$SEATDIR/$name.denied"
        fi
        rm -f "$f"
      done < "$TMPD/requests"
      while IFS=$'\t' read -r _ task; do
        echo "holder $pool $task"
      done < "$TMPD/holders"
    done < "$TMPD/pools"
    for f in "$STATE/fleet-seats/@checks/requests/"*.req; do
      [ -f "$f" ] || continue
      if ! holder_alive "$(record_field "$f" pid)" "$(record_field "$f" pid_identity)"; then
        rm -f "$f"
        continue
      fi
      response=${f%/requests/*}/${f##*/}
      response=${response%.req}.approved
      printf 'nonce=%s\n' "$(record_field "$f" nonce)" > "$response.tmp.$$" \
        && mv -f "$response.tmp.$$" "$response" \
        || unavailable "cannot confirm an unpooled model"
      rm -f "$f"
    done
    exit 0
  fi

  [ -e "$DELIVERED" ] || unavailable "the fleet root has not delivered a seat policy to this home"
  POOLS=$DELIVERED
  validate_pools "$POOLS" || unavailable "$POOLS is malformed"
  require_explicit_model "$POOLS"
  POLICY_DIGEST=$(policy_digest "$POOLS")
  POOL_LINE=$(pool_for_model "$POOLS" "$MODEL")
  fm_pid_alive "$HOLDER" || unavailable "holder pid $HOLDER is not a running process"
  if [ -n "$POOL_LINE" ]; then
    POOL=${POOL_LINE%%$'\t'*}
    pool_models "$POOLS" "$POOL" > "$TMPD/models"
    SEATDIR=$STATE/fleet-seats/$POOL
  else
    POOL=@checks
    SEATDIR=$STATE/fleet-seats/@checks
  fi
  mkdir -p "$SEATDIR/requests" || unavailable "cannot create $SEATDIR"
  KEY=$(printf '%s\t%s' "$OWN_STATE" "$TASK")
  NAME=$(seat_name "$OWN_STATE" "$TASK")
  SEAT=$SEATDIR/$NAME.seat
  REQ=$SEATDIR/requests/$NAME.req
  DENIED=$SEATDIR/$NAME.denied
  REJECTED=$SEATDIR/$NAME.rejected
  APPROVED=$SEATDIR/$NAME.approved

  lock_or_refuse "$LOCK"
  if [ "$POOL" != @checks ]; then
    remote_holders "$POOL" "$TMPD/models" 1 > "$TMPD/holders" || unavailable "this home's task records cannot be read"
  fi
  NONCE="$(date +%s).$$.$RANDOM"
  rm -f "$DENIED" "$REJECTED" "$APPROVED"
  write_record "$REQ" "$OWN_STATE" "$TASK" "$MODEL" "$HOLDER" "$NONCE" "$POLICY_DIGEST" || unavailable "cannot write $REQ"
  unlock

  deadline=$((SECONDS + REMOTE_WAIT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if [ "$POOL" != @checks ] && [ -f "$SEAT" ] && [ "$(record_field "$SEAT" nonce)" = "$NONCE" ]; then
      echo "fleet-seats: reserved pool=$POOL id=$TASK (granted by the fleet root)"
      exit 0
    fi
    if [ "$POOL" = @checks ] && [ -f "$APPROVED" ] && [ "$(record_field "$APPROVED" nonce)" = "$NONCE" ]; then
      rm -f "$APPROVED"
      exit 0
    fi
    if [ -f "$REJECTED" ] && [ "$(record_field "$REJECTED" nonce)" = "$NONCE" ]; then
      rm -f "$REJECTED"
      unavailable "the fleet seat policy changed before the request for $TASK was confirmed"
    fi
    if [ -f "$DENIED" ] && [ "$(record_field "$DENIED" nonce)" = "$NONCE" ]; then
      print_full "$POOL" "$(record_field "$DENIED" used)" "$(record_field "$DENIED" capacity)" -
      rm -f "$DENIED"
      exit "$EXIT_FULL"
    fi
    sleep 1
  done
  lock_or_refuse "$LOCK"
  if [ "$POOL" != @checks ] && [ -f "$SEAT" ] && [ "$(record_field "$SEAT" nonce)" = "$NONCE" ]; then
    echo "fleet-seats: reserved pool=$POOL id=$TASK (granted by the fleet root)"
    exit 0
  fi
  if [ "$POOL" = @checks ] && [ -f "$APPROVED" ] && [ "$(record_field "$APPROVED" nonce)" = "$NONCE" ]; then
    rm -f "$APPROVED"
    exit 0
  fi
  rm -f "$REQ"
  unavailable "the fleet root on another host did not answer the seat request for $TASK within ${REMOTE_WAIT}s"
fi

# --- root and local homes ----------------------------------------------------

[ "$CMD" != serve ] || unavailable "serve runs only in a home whose fleet root is on another host"
POOLS=$ROOT_CONFIG/fleet-seats
SEATROOT=$ROOT_STATE/fleet-seats
LOCK=$ROOT_STATE/.fleet-seats.lock

if [ "$CMD" = serve-remotes ]; then
  [ "$ROOT_SELF" -eq 1 ] || exit 0
  registry_homes || unavailable "${REGISTRY_ERROR:-the secondmate registry cannot be read}"
  [ -s "$TMPD/remote-ids" ] || exit 0
  mkdir -p "$SEATROOT" || unavailable "cannot create $SEATROOT"
  cp "$TMPD/remote-ids" "$TMPD/serve-ids"
  while IFS= read -r id; do
    failed=$ROOT_STATE/.fleet-seats-serve-failed-$id
    if [ -e "$failed" ] && [ "$(fm_path_age "$failed")" -lt "$SERVE_BACKOFF" ]; then
      echo "unreachable $id (backing off)"
      continue
    fi
    lock_or_refuse "$LOCK"
    if [ -e "$ROOT_CONFIG/fleet-seats" ] || [ -L "$ROOT_CONFIG/fleet-seats" ]; then
      validate_pools "$ROOT_CONFIG/fleet-seats" || unavailable "$ROOT_CONFIG/fleet-seats is malformed"
      cp "$ROOT_CONFIG/fleet-seats" "$TMPD/policy" || unavailable "cannot read the current seat policy"
    else
      printf '{"pools":[]}\n' > "$TMPD/policy"
    fi
    POOLS=$TMPD/policy
    DIGEST=$(policy_digest "$POOLS")
    jq -r '.pools[] | "\(.name)\t\(.capacity)"' "$POOLS" > "$TMPD/pools"
    set --
    while IFS=$'\t' read -r name cap; do
      pool_models "$POOLS" "$name" > "$TMPD/models"
      if root_holders "$name" "$TMPD/models" 1 "$id" > "$TMPD/holders"; then
        others=$(wc -l < "$TMPD/holders" | tr -d ' ')
        allowance=$((cap - others))
        [ "$allowance" -ge 0 ] || allowance=0
      else
        [ "$?" -eq 3 ] || unavailable "${REGISTRY_ERROR:-a fleet task record cannot be read}"
        allowance=0
      fi
      set -- "$@" --allowance "$name=$allowance"
    done < "$TMPD/pools"
    if fm_run_timed "$SERVE_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-fleet-seats.sh serve \
        --digest "$DIGEST" "$@" < "$POOLS" > "$TMPD/served" 2>"$TMPD/served.err" \
      && [ "$(sed -n 's/^policy //p' "$TMPD/served" | head -1)" = "$DIGEST" ]; then
      awk '$1 == "holder" && NF == 3 && $2 ~ /^[A-Za-z0-9._-]+$/ && $3 ~ /^[A-Za-z0-9._-]+$/ { printf "%s\t%s\n", $2, $3 }' "$TMPD/served" \
        > "$SEATROOT/remote-$id.holders.tmp.$$" || unavailable "cannot record the snapshot for $id"
      mv -f "$SEATROOT/remote-$id.holders.tmp.$$" "$SEATROOT/remote-$id.holders" || unavailable "cannot record the snapshot for $id"
      { printf '%s\n' "$DIGEST" > "$SEATROOT/remote-$id.policy.tmp.$$" \
        && mv -f "$SEATROOT/remote-$id.policy.tmp.$$" "$SEATROOT/remote-$id.policy"; } \
        || unavailable "cannot record the policy confirmation for $id"
      rm -f "$failed"
      echo "served $id policy=$DIGEST holders=$(wc -l < "$SEATROOT/remote-$id.holders" | tr -d ' ')"
    else
      : > "$failed"
      echo "unreachable $id"
    fi
    unlock
  done < "$TMPD/serve-ids"
  exit 0
fi

# reserve at the root or a local home
if [ ! -e "$POOLS" ] && [ ! -L "$POOLS" ]; then
  exit 0
fi
validate_pools "$POOLS" || unavailable "$POOLS is malformed (see docs/configuration.md \"Fleet seat pools\")"
require_explicit_model "$POOLS"
POOL_LINE=$(pool_for_model "$POOLS" "$MODEL")
[ -n "$POOL_LINE" ] || exit 0
POOL=${POOL_LINE%%$'\t'*}
CAP=${POOL_LINE#*$'\t'}
DIGEST=$(policy_digest "$POOLS")
fm_pid_alive "$HOLDER" || unavailable "holder pid $HOLDER is not a running process"
CALLER_STATE=$(canon_dir "$STATE") || unavailable "this home's state directory $STATE is missing"
pool_models "$POOLS" "$POOL" > "$TMPD/models"

[ -d "$ROOT_STATE" ] || unavailable "the fleet root state directory $ROOT_STATE is missing"
mkdir -p "$SEATROOT/$POOL" 2>/dev/null || unavailable "cannot create $SEATROOT/$POOL"
lock_or_refuse "$LOCK"
[ -e "$POOLS" ] && validate_pools "$POOLS" && [ "$(policy_digest "$POOLS")" = "$DIGEST" ] \
  || unavailable "the fleet seat policy changed before the reservation was decided"

if root_holders "$POOL" "$TMPD/models" 1 > "$TMPD/holders"; then
  :
elif [ "$?" -eq 3 ]; then
  unavailable "remote secondmate(s)$UNCONFIRMED have not confirmed the current seat policy, so their agents cannot be counted yet"
else
  unavailable "${REGISTRY_ERROR:-a fleet task record cannot be read}"
fi
USED=$(wc -l < "$TMPD/holders" | tr -d ' ')
KEY=$(printf '%s\t%s' "$CALLER_STATE" "$TASK")
if ! grep -Fxq -- "$KEY" "$TMPD/holders" && [ "$USED" -ge "$CAP" ]; then
  print_full "$POOL" "$USED" "$CAP" "$TMPD/holders"
  exit "$EXIT_FULL"
fi

SEAT=$SEATROOT/$POOL/$(seat_name "$CALLER_STATE" "$TASK").seat
write_record "$SEAT" "$CALLER_STATE" "$TASK" "$MODEL" "$HOLDER" || unavailable "cannot write $SEAT"
if grep -Fxq -- "$KEY" "$TMPD/holders"; then
  echo "fleet-seats: reserved pool=$POOL id=$TASK (already held) used=$USED capacity=$CAP"
else
  echo "fleet-seats: reserved pool=$POOL id=$TASK used=$((USED + 1)) capacity=$CAP"
fi
