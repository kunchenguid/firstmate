#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq programs are single-quoted on purpose.
# fm-fleet-seats.sh - opt-in fleet-wide active-agent seat pools for shared model endpoints.
#
# docs/configuration.md "Fleet seat pools" owns the operator contract: the
# config/fleet-seats schema, what a seat is, which homes share one pool, and
# what the refusals mean. This header owns the mechanics; it is the single
# owner of the seat record format, counting, and every seat transition.
# Callers supply evidence and request an operation; they never write or delete
# seat records themselves.
#
# A seat is an active agent slot on a pooled model, never an inference
# request. Its holder is keyed by canonical state directory plus task id.
#
# THE AUTHORITY. Every home resolves the one fleet root with
# fm_firstmate_root_home (bin/fm-wake-lib.sh): the primary is its own root, and
# a local secondmate walks its .fm-secondmate-parent binding to the primary.
# The root's config/fleet-seats declares the pools, and every grant is decided
# under the root's lock (<root>/state/.fleet-seats.lock). A home whose walk
# ends at a remote parent binding keeps its OWN ledger for its workers under
# its own lock and receives its policy and grants from the root (REMOTE HOMES
# below).
#
# THE LEDGER. Each holder is one record at
# <authority-state>/fleet-seats/holders/<seat-name>.json, where <seat-name> is
# derived from the canonical state directory plus task id and the embedded key
# is validated on every access (a hash collision refuses). Schema
# fm-fleet-seat-holder.v2:
#   {schema, state_dir, task, revision, incarnations: [{generation,
#    previous_generation, kind, model, policy_digest_at_reserve, lifecycle,
#    launch_phase, owner_pid, owner_pid_identity, route, startup_confirmed,
#    disposition, [legacy], [requested_model]}]}
# Every state is per holder + generation. lifecycle is reserved | confirmed
# (both count) | released | reclaimed (neither counts); launch_phase refines
# reserved as prepared -> dispatching -> started, with unknown for a
# conservatively imported record. revision increases on every atomic mutation.
# Pools are never storage directories: a pool's count is the number of
# distinct holder keys with a nonterminal incarnation whose model the CURRENT
# policy maps to that pool (a null model - an imported unresolved legacy model
# - occupies every pool). Two generations of one holder in one pool count once;
# an old and a candidate generation in different pools count in both until the
# old one is terminal.
#
# Transitions (only this script writes them, each a short compare-and-set
# under the ledger lock):
#   absent/terminal -> reserved   reserve, with a NEW generation and a capacity
#                                 check; a same-generation same-model retry is
#                                 idempotent; a terminal generation never revives.
#                                 A nonterminal incarnation other than the named
#                                 --previous-generation refuses: retry reconciles
#                                 the existing candidate instead of replacing it.
#   prepared -> dispatching       dispatch, by the reserving owner (or its
#                                 descendant) before any launch delivery; only
#                                 the first dispatch is permitted.
#   reserved -> confirmed         confirm, on this script's own recovery-grade
#                                 `alive` reading of the dispatched local route.
#   reserved -> released          release --reason prelaunch (never dispatched)
#                                 or cancelled (dispatched endpoint proven gone).
#   nonterminal -> released       release --reason replaced (a candidate naming
#                                 this generation as previous exists and this
#                                 route no longer runs an agent) or teardown
#                                 (the task record is gone after cleanup).
#   nonterminal -> reclaimed      reclaim, recovery with fresh generation-bound
#                                 endpoint or host-operation evidence.
#   remote operations             reconcile-remote applies one host disposition.
# No transition is inferred from reserving-process death, session-lock
# absence, a timestamp, missing metadata, a model mismatch, transport failure,
# or a shell-only `dead` reading of a submitted launch: those can trigger
# reconciliation but never free capacity. Counting is side-effect free.
#
# COUNTING AT THE ROOT. Under the root lock, a pool's holders are the union of:
#   - nonterminal ledger holders mapped to the pool, as above;
#   - UNMANAGED pooled task records in the root home and local descendants
#     (reached through each home's data/secondmates.md): a record is managed,
#     and so ignored here, when a ledger holder exists for its key; a record
#     generation (spawn_gen=, or fleet_seat_generation= on a remote route) that
#     conflicts with every ledger incarnation fails admission closed. An
#     unmanaged ship or scout counts while its record is pooled; an unmanaged
#     local secondmate counts unless its session lock is free or stale and its
#     endpoint reads dead or missing; an unresolved model counts everywhere.
#   - the primary supervisor, keyed "<root-state>\t.primary", when the root's
#     config/fleet-seats declares "primary_model" in a pool and the root's
#     session lock is not provably free or stale (bin/fm-session-lock-lib.sh).
#     A running primary is never refused or preempted.
#   - for each registered remote secondmate, the rows of its last complete
#     serve certificate, remote-<id>.cert.
# The root refuses (exit 5) instead of counting when any registered remote has
# a pending serve, no certificate, or a certificate for another policy digest;
# a registry line cannot be parsed; a home cannot be listed; a task record or
# holder record cannot be read.
#
# REMOTE HOMES. The root's serve-remotes (run from the root's watcher) serves
# each registered remote through bin/fm-on.sh outside the root lock:
#   - it allocates a serve epoch "<issuer>.<seq>" (a stable root issuer id plus
#     a per-remote sequence persisted under the root lock), writes
#     remote-<id>.pending carrying that epoch BEFORE the call - which
#     invalidates the previous certificate even across a crash or timeout -
#     releases the lock and sends the pool declaration with the digest, epoch, and each
#     pool's allowance (capacity minus every other holder, 0 while another
#     remote is unconfirmed), then reacquires the lock, validates and publishes it
#     atomically as remote-<id>.cert, and only then clears the matching
#     pending marker. Lost, truncated, or mismatched output leaves the pending
#     marker, so admission stays refused; an old response cannot clear a newer
#     marker. A counter or issuer that cannot be reconciled with existing
#     certificates refuses rather than restarting the sequence.
#   - under the remote's own lock, serve refuses an epoch lower than its
#     highest applied one and replays an exact same-epoch/digest response
#     without granting anything, stores the delivered policy, rejects stale
#     requests, grants waiting requests in arrival order within the allowance
#     (a request from a holder already counted in that pool is one slot),
#     creating the granted holder record, and prints one JSON certificate
#     {schema:"fm-fleet-seats-serve.v2", policy_digest, epoch, complete:true,
#     holders:[{state_dir, task, generation, model, lifecycle}]} listing every
#     reserved or confirmed generation, including unmanaged pooled records.
#   - a remote reserve files a request carrying its generation and waits
#     (bounded) for the root's next serve to confirm that exact policy and
#     model; pooled requests also require the grant. A timeout withdraws the
#     request and refuses unless the grant landed first.
#
# REMOTE SUPERVISORS. A remote secondmate's own seat is parent-owned: the
# parent reserves it at the root, dispatches it with a remote route carrying
# the host operation token, and applies the host's token-scoped disposition
# with reconcile-remote. Host-side records under state/parent-route are
# execution receipts, not counted holders (bin/fm-remote-secondmate-control.sh).
#
# EXPLICIT MODELS. While any pool is configured, every launch needs a verified
# explicit model. A harness default or raw launch command cannot prove its
# actual model and refuses before dispatch.
#
# SUPERVISOR EPISODES. Every mutation of a kind=secondmate holder adopts the
# caller's verified lifecycle carrier or takes the task's lifecycle mutex
# without waiting (bin/fm-secondmate-liveness-lib.sh), refusing while another
# episode holds it. Lock order: lifecycle episode, then task metadata (reclaim
# only), then the ledger lock; this script never takes a lifecycle or metadata
# lock while holding the ledger lock and never probes a host from inside it.
#
# Usage:
#   fm-fleet-seats.sh reserve <id> --generation <gen> [--previous-generation <gen|->]
#       --harness <harness> --model <model|default> --holder-pid <pid>
#       [--kind ship|scout|secondmate] [--raw-launch]
#       Prints nothing and exits 0 with no declaration. With one, records the
#       holder and prints "fleet-seats: reserved pool=..." (pooled) or
#       "fleet-seats: recorded ..." (a model in no pool).
#   fm-fleet-seats.sh dispatch <id> --generation <gen> --route-file <private-json>
#       Exit 0 "fleet-seats: dispatched ..." permits the one launch delivery;
#       exit 3 "already-dispatched" forbids delivering again.
#   fm-fleet-seats.sh confirm <id> --generation <gen>
#   fm-fleet-seats.sh release <id> --generation <gen> --reason <prelaunch|cancelled|replaced|teardown>
#   fm-fleet-seats.sh reclaim <id> --generation <gen> [--state-dir <canonical-state>]
#   fm-fleet-seats.sh reconcile-remote <id> --generation <gen> --response-file <private-json>
#   fm-fleet-seats.sh reconcile --limit <n>
#       Bounded maintenance: try reclaim on up to <n> holders whose owner has
#       ended, skipping busy episodes; nothing is killed to free a seat.
#   fm-fleet-seats.sh show <id>
#       Print this home's holder record for <id> (read-only).
#   fm-fleet-seats.sh serve-remotes
#       Root only (a no-op anywhere else): serve every registered remote
#       secondmate and print one "served <id> ..." or "unreachable <id>" line
#       each. A remote that failed is skipped for a fixed backoff.
#   fm-fleet-seats.sh serve --digest <digest> --epoch <epoch> [--allowance <pool>=<n>]...
#       Remote home only; the root runs it through bin/fm-on.sh with the pool
#       declaration on stdin.
#
# Private carrier files (--route-file, --response-file) must be regular,
# non-symlink files owned by the caller with no group or other access.
# A route object is {placement, backend, target, home, host, remote_root,
# spawn_gen, operation} with placement local|remote and remote-only fields
# null locally. A host disposition response is the
# fm-remote-seat-operation.v2 object bin/fm-remote-secondmate-control.sh prints.
#
# Fixed bounds: 30s lock wait, 90s remote request wait, 20s per remote serve
# or disposition call, 120s backoff after a failed serve.
# FM_FLEET_SEATS_TEST_REMOTE_WAIT and FM_FLEET_SEATS_TEST_BACKOFF shorten the
# second and last for the regression suite only; they are not operator
# settings.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE, and
# FM_DATA_OVERRIDE resolve the calling home as the other bin/ scripts do; they
# also select the root's own directories when the caller is the root.
#
# Exit status: 0 reserved, not pooled, transitioned, nothing held, or served;
# 2 usage error; 3 the evidence is uncertain and the seat stays counted (or a
# dispatch was already made); 4 the pool is full; 5 the accounting authority is
# unreachable, unconfirmed, unreadable, busy, or misconfigured, an explicit
# model is required, or the transition is refused. Exit 4 and 5 from reserve
# both mean no seat: choose another route.
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
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

EXIT_UNCERTAIN=3
EXIT_FULL=4
EXIT_UNAVAILABLE=5
LOCK_WAIT=30
REMOTE_WAIT=${FM_FLEET_SEATS_TEST_REMOTE_WAIT:-90}
REMOTE_CALL_TIMEOUT=20
SERVE_BACKOFF=${FM_FLEET_SEATS_TEST_BACKOFF:-120}
HOLDER_SCHEMA=fm-fleet-seat-holder.v2
SERVE_SCHEMA=fm-fleet-seats-serve.v2
OPERATION_SCHEMA=fm-remote-seat-operation.v2
POOL_NAME_RULE='type == "string" and test("^[A-Za-z0-9._-]+$") and . != "." and . != ".."'

usage() {
  sed -n '/^# Usage:/,/^# Private carrier/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2
  exit 2
}

unavailable() {
  echo "fleet-seats: no seat - $* (a pooled model is never launched without a counted seat; choose another route or repair the authority)" >&2
  exit "$EXIT_UNAVAILABLE"
}

refuse() {
  echo "fleet-seats: refused - $*" >&2
  exit "$EXIT_UNAVAILABLE"
}

uncertain() {
  echo "fleet-seats: retained - $* (the seat stays counted until evidence resolves it)" >&2
  exit "$EXIT_UNCERTAIN"
}

canon_dir() { CDPATH='' cd -- "$1" 2>/dev/null && pwd -P; }
is_count() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
id_ok() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
gen_ok() { case "$1" in ''|-|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
pool_ok() { jq -en --arg name "$1" "\$name | $POOL_NAME_RULE" >/dev/null 2>&1; }

# validate_pools <file>: a readable, well-formed pool declaration, or fail.
# An empty "pools" list is valid and means no pool.
validate_pools() {
  local file=$1
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  jq -e "def pool_name_ok: $POOL_NAME_RULE;"'
    (.pools | type == "array")
    and all(.pools[];
      (.name | pool_name_ok)
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

seat_name() { printf '%s\t%s' "$1" "$2" | cksum | tr -s ' ' '-' | cut -d- -f1-2; }

record_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# holder_alive <pid> <identity>: the owning process is still the same process.
holder_alive() {
  local pid=$1 identity=$2 now
  fm_pid_alive "$pid" || return 1
  [ -n "$identity" ] || return 0
  now=$(fm_pid_identity "$pid") || return 0
  [ "$now" = "$identity" ]
}

# private_file_ok <path>: a regular non-symlink file owned by this user with
# no group or other access.
private_file_ok() {
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] || return 1
  [ -z "$(find "$path" -prune \( -perm -g=r -o -perm -g=w -o -perm -o=r -o -perm -o=w \) -print 2>/dev/null)" ]
}

# Resolve the authority for the calling home. Sets ROOT_REMOTE=1 when the walk
# ends at a remote parent binding, else ROOT_STATE / ROOT_CONFIG / ROOT_DATA,
# with ROOT_SELF=1 when this home is the root.
resolve_authority() {
  local home_canon root
  ROOT_REMOTE=0 ROOT_SELF=0
  ROOT_HOME='' ROOT_STATE='' ROOT_CONFIG='' ROOT_DATA=''
  home_canon=$(canon_dir "$FM_HOME") || return 1
  root=$(fm_firstmate_root_home "$home_canon") || return 1
  if [ -e "$root/.fm-secondmate-parent" ] || [ -L "$root/.fm-secondmate-parent" ]; then
    fm_secondmate_parent_record_parse "$root/.fm-secondmate-parent" || return 1
    [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ] || return 1
    ROOT_REMOTE=1
  fi
  ROOT_HOME=$root
  if [ "$root" = "$home_canon" ]; then
    ROOT_SELF=1
    ROOT_STATE=$STATE ROOT_CONFIG=$CONFIG ROOT_DATA=$DATA
  else
    ROOT_STATE=$root/state ROOT_CONFIG=$root/config ROOT_DATA=$root/data
  fi
}

# --- the holder ledger ---------------------------------------------------------

holder_path() { printf '%s/holders/%s.json\n' "$LEDGER" "$(seat_name "$1" "$2")"; }

# holder_validate <file> <state-dir> <task>: the record is a well-formed v2
# holder for exactly that key.
holder_validate() {
  jq -e --arg s "$2" --arg t "$3" --arg schema "$HOLDER_SCHEMA" '
    .schema == $schema and .state_dir == $s and .task == $t
    and (.revision | type == "number" and . >= 1 and . == floor)
    and (.incarnations | type == "array")
    and all(.incarnations[];
      (.generation | type == "string" and test("^[A-Za-z0-9._-]+$"))
      and (.lifecycle | IN("reserved", "confirmed", "released", "reclaimed"))
      and (.launch_phase | IN("prepared", "dispatching", "started", "unknown"))
      and (.model == null or (.model | type == "string" and length > 0))
      and (.kind | IN("ship", "scout", "secondmate")))
    and ([.incarnations[].generation] | length == (unique | length))
  ' "$1" >/dev/null 2>&1
}

# holder_load <state-dir> <task>: sets HOLDER_FILE and HOLDER_JSON (empty when
# absent). Returns 1 when the record exists but is malformed or names a
# different key.
holder_load() {
  HOLDER_FILE=$(holder_path "$1" "$2")
  HOLDER_JSON=
  if [ ! -e "$HOLDER_FILE" ] && [ ! -L "$HOLDER_FILE" ]; then
    return 0
  fi
  [ -f "$HOLDER_FILE" ] && [ ! -L "$HOLDER_FILE" ] || return 1
  holder_validate "$HOLDER_FILE" "$1" "$2" || return 1
  HOLDER_JSON=$(cat "$HOLDER_FILE") || return 1
}

# holder_publish <json>: atomically replace HOLDER_FILE with <json>, which the
# caller built from HOLDER_JSON with its revision already advanced.
holder_publish() {
  local tmp
  mkdir -p "$LEDGER/holders" || return 1
  tmp="$HOLDER_FILE.tmp.$$"
  if ! { (umask 077 && printf '%s\n' "$1" > "$tmp") && mv -f "$tmp" "$HOLDER_FILE"; }; then
    rm -f "$tmp"
    return 1
  fi
}

# holder_mutate <jq-filter> [jq-args...]: apply <filter> to HOLDER_JSON (which
# must exist), advance the revision, publish, and refresh HOLDER_JSON.
holder_mutate() {
  local filter=$1 out
  shift
  out=$(printf '%s\n' "$HOLDER_JSON" | jq -c "$@" "$filter | .revision += 1") || return 1
  holder_publish "$out" || return 1
  HOLDER_JSON=$out
}

inc_get() {  # <generation> <jq-expression-on-incarnation>
  printf '%s\n' "$HOLDER_JSON" | jq -r --arg g "$1" ".incarnations[] | select(.generation == \$g) | $2"
}

inc_exists() {  # <generation>
  [ -n "$HOLDER_JSON" ] && [ -n "$(inc_get "$1" .generation)" ]
}

holder_revision() { printf '%s\n' "$HOLDER_JSON" | jq -r '.revision'; }

# ledger_scan: one TSV row per incarnation of every holder:
# state task generation lifecycle model(- for null) kind phase owner-pid
# route-placement previous-generation (- for none). Fails when any record is malformed
# or stored under another key's name.
ledger_scan() {
  local f name st task
  : > "$TMPD/ledger" || return 1
  [ -d "$LEDGER/holders" ] || return 0
  for f in "$LEDGER/holders"/*.json; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ -f "$f" ] && [ ! -L "$f" ] || { LEDGER_ERROR="holder record $f is not a regular file"; return 1; }
    st=$(jq -r '.state_dir // empty' "$f" 2>/dev/null) || st=
    task=$(jq -r '.task // empty' "$f" 2>/dev/null) || task=
    name=${f##*/}
    name=${name%.json}
    if [ -z "$st" ] || [ -z "$task" ] || [ "$name" != "$(seat_name "$st" "$task")" ] \
      || ! holder_validate "$f" "$st" "$task"; then
      LEDGER_ERROR="holder record $f is malformed or names another holder"
      return 1
    fi
    jq -r '. as $h | .incarnations[] | [$h.state_dir, $h.task, .generation, .lifecycle,
      (.model // "-"), .kind, .launch_phase, ((.owner_pid // "-") | tostring),
      (.route.placement // "-"), (.previous_generation // "-")] | @tsv' "$f" >> "$TMPD/ledger" || return 1
  done
}

# --- legacy v1 import ------------------------------------------------------------

# import_legacy_v1: convert every v1 <ledger>/<pool>/*.seat reservation into a
# conservatively counted v2 holder once, under the ledger lock. A v2 record
# already present for the key takes precedence. The source is deleted only
# after the imported record reads back with its key and model.
import_legacy_v1() {
  local f st task model pid identity fp gen meta meta_gen route kind json
  for f in "$LEDGER"/*/*.seat "$LEDGER"/.[!.]*/*.seat "$LEDGER"/..?*/*.seat; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    st=$(record_field "$f" state)
    task=$(record_field "$f" task)
    model=$(record_field "$f" model)
    pid=$(record_field "$f" pid)
    identity=$(record_field "$f" pid_identity)
    if [ -z "$st" ] || ! id_ok "$task"; then
      LEDGER_ERROR="legacy seat record $f is unreadable"
      return 1
    fi
    holder_load "$st" "$task" || { LEDGER_ERROR="holder record for $task is malformed"; return 1; }
    if [ -n "$HOLDER_JSON" ]; then
      rm -f "$f" || return 1
      continue
    fi
    fp=$(cksum < "$f" | tr -s ' ' '-' | cut -d- -f1-2)
    gen="v1-$fp"
    meta="$st/$task.meta"
    meta_gen=
    route=null
    kind=ship
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      meta_gen=$(record_field "$meta" spawn_gen)
      [ -z "$(record_field "$meta" fleet_seat_generation)" ] || meta_gen=$(record_field "$meta" fleet_seat_generation)
      kind=$(record_field "$meta" kind)
      case "$kind" in ship|scout|secondmate) ;; *) kind=ship ;; esac
      [ "$(record_field "$meta" model)" != "$model" ] || { gen_ok "$meta_gen" && gen=$meta_gen; }
    fi
    json=$(jq -cn --arg s "$st" --arg t "$task" --arg g "$gen" --arg m "$model" \
      --arg k "$kind" --arg p "$pid" --arg i "$identity" --arg fp "$fp" --argjson r "$route" \
      --arg schema "$HOLDER_SCHEMA" '{schema: $schema, state_dir: $s, task: $t, revision: 1,
        incarnations: [{generation: $g, previous_generation: null, kind: $k,
          model: (if $m == "" then null else $m end), policy_digest_at_reserve: null,
          lifecycle: "reserved", launch_phase: "unknown",
          owner_pid: (if ($p | test("^[0-9]+$")) then ($p | tonumber) else null end),
          owner_pid_identity: $i, route: $r, startup_confirmed: false, disposition: null,
          legacy: {source: "v1", fingerprint: $fp}}]}') || return 1
    holder_publish "$json" || return 1
    holder_load "$st" "$task" || return 1
    [ "$(inc_get "$gen" '.model // ""')" = "$model" ] || { LEDGER_ERROR="imported seat for $task did not read back"; return 1; }
    rm -f "$f" || return 1
  done
}

# --- task records ---------------------------------------------------------------

meta_generation() {  # <meta>
  local g
  g=$(record_field "$1" fleet_seat_generation)
  [ -n "$g" ] || g=$(record_field "$1" spawn_gen)
  printf '%s' "$g"
}

# meta_state <meta> <models-file>: "pooled", "other", "absent", or "unreadable"
# for an UNMANAGED record.
meta_state() {
  local meta=$1 models=$2 model kind home id endpoint_state
  if [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
    echo absent
    return
  fi
  [ -f "$meta" ] && [ -r "$meta" ] || { echo unreadable; return; }
  kind=$(sed -n 's/^kind=//p' "$meta" | tail -1)
  if [ "$kind" = secondmate ] && [ -z "$(sed -n 's/^remote_host=//p' "$meta" | tail -1)" ]; then
    home=$(sed -n 's/^home=//p' "$meta" | tail -1)
    if [ -n "$home" ] && [ -d "$home/state" ]; then
      fm_session_lock_inspect "$home/state"
      case "$FM_LOCK_INSPECT_STATE" in
        free|stale)
          id=${meta##*/}
          id=${id%.meta}
          if fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1; then
            endpoint_state=$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null) || endpoint_state=unreadable
            case "$endpoint_state" in dead|missing) echo other; return ;; esac
          fi
          ;;
      esac
    fi
  fi
  model=$(sed -n 's/^model=//p' "$meta" | tail -1)
  case "$model" in ''|default|-) echo unreadable; return ;; esac
  if ! grep -Fxq -- "$model" "$models"; then
    echo other
    return
  fi
  echo pooled
}

# pooled_records <state-dir> <models-file>: "<state>\t<id>" per unmanaged
# pooled active record. A record whose generation is a predecessor some
# incarnation names, but which the ledger never held, is still an unmanaged
# agent and counts by its record. Returns 4 (with CONFLICT
# set) when a record's generation is otherwise unknown to its ledger holder.
pooled_records() {
  local home_state=$1 models=$2 meta id verdict gen
  [ -r "$home_state" ] && [ -x "$home_state" ] || return 1
  for meta in "$home_state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    id_ok "$id" || continue
    if awk -F '\t' -v s="$home_state" -v t="$id" '$1 == s && $2 == t { found = 1 } END { exit !found }' "$TMPD/ledger"; then
      gen=$(meta_generation "$meta")
      if [ -z "$gen" ] || awk -F '\t' -v s="$home_state" -v t="$id" -v g="$gen" \
          '$1 == s && $2 == t && $3 == g { found = 1 } END { exit !found }' "$TMPD/ledger"; then
        continue
      fi
      if ! awk -F '\t' -v s="$home_state" -v t="$id" -v g="$gen" \
          '$1 == s && $2 == t && $10 == g { found = 1 } END { exit !found }' "$TMPD/ledger"; then
        CONFLICT="task record $meta names generation $gen, which its seat holder never issued"
        return 4
      fi
    fi
    verdict=$(meta_state "$meta" "$models")
    case "$verdict" in pooled|unreadable) printf '%s\t%s\n' "$home_state" "$id" ;; esac
  done
}

# ledger_pool_holders <models-file>: "<state>\t<task>" per holder with a
# nonterminal incarnation the current policy maps to the pool.
ledger_pool_holders() {
  awk -F '\t' 'NR == FNR { m[$0] = 1; next }
    ($4 == "reserved" || $4 == "confirmed") && ($5 == "-" || ($5 in m)) { print $1 "\t" $2 }' \
    "$1" "$TMPD/ledger"
}

# primary_counts <state-dir>: the primary's session lock is not provably free
# or stale.
primary_counts() {
  fm_session_lock_inspect "$1"
  case "$FM_LOCK_INSPECT_STATE" in free|stale) return 1 ;; esac
  return 0
}

registry_homes_walk() {
  local home=$1 home_state=$2 depth=$3 reg line child child_state
  grep -Fxq -- "$home" "$TMPD/seen-homes" && return 0
  [ "$depth" -le 64 ] || { REGISTRY_ERROR="secondmate registry nesting exceeds 64 homes"; return 1; }
  printf '%s\n' "$home" >> "$TMPD/seen-homes" || return 1
  printf '%s\n' "$home_state" >> "$TMPD/local-homes" || return 1
  if [ "$depth" -eq 0 ]; then
    reg=$ROOT_DATA/secondmates.md
  else
    reg=$home/data/secondmates.md
  fi
  [ -e "$reg" ] || [ -L "$reg" ] || return 0
  [ -f "$reg" ] && [ -r "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! secondmate_registry_parse_line "$line"; then
      REGISTRY_ERROR="unparseable secondmate registry line: $line"
      return 1
    fi
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
      if grep -Fxq -- "$SECONDMATE_REGISTRY_ID" "$TMPD/remote-ids"; then
        REGISTRY_ERROR="duplicate remote secondmate id: $SECONDMATE_REGISTRY_ID"
        return 1
      fi
      printf '%s\n' "$SECONDMATE_REGISTRY_ID" >> "$TMPD/remote-ids"
      continue
    fi
    child=$(canon_dir "$SECONDMATE_REGISTRY_HOME") || return 1
    [ -d "$child/state" ] || return 1
    child_state=$(canon_dir "$child/state") || return 1
    registry_homes_walk "$child" "$child_state" "$((depth + 1))" || return 1
  done < "$reg"
}

registry_homes() {
  local root_state
  : > "$TMPD/local-homes" || return 1
  : > "$TMPD/remote-ids" || return 1
  : > "$TMPD/seen-homes" || return 1
  root_state=$(canon_dir "$ROOT_STATE") || return 1
  registry_homes_walk "$ROOT_HOME" "$root_state" 0
}

# remote_confirmed <id>: the remote's latest certificate is complete, matches
# the current digest, and no newer serve is pending. Sets CERT_FILE.
remote_confirmed() {
  CERT_FILE="$LEDGER/remote-$1.cert"
  [ ! -e "$LEDGER/remote-$1.pending" ] && [ ! -L "$LEDGER/remote-$1.pending" ] || return 1
  [ -f "$CERT_FILE" ] && [ ! -L "$CERT_FILE" ] || return 1
  jq -e --arg d "$DIGEST" --arg schema "$SERVE_SCHEMA" \
    '.schema == $schema and .policy_digest == $d and .complete == true and (.holders | type == "array")' \
    "$CERT_FILE" >/dev/null 2>&1
}

# root_holders <models-file> [excluded-remote-id]: every holder the root
# counts for one pool, one "<key>\t<id>" per line, sorted unique. Returns 3
# (with UNCONFIRMED set) when a registered remote is unconfirmed, and 4 (with
# CONFLICT set) on a task record the ledger contradicts.
root_holders() {
  local models=$1 exclude=${2:-} home_state id primary rc
  UNCONFIRMED=
  CONFLICT=
  registry_homes || return 1
  ledger_scan || return 1
  {
    ledger_pool_holders "$models"
    while IFS= read -r home_state; do
      pooled_records "$home_state" "$models" || { rc=$?; [ "$rc" -ne 4 ] || return 4; return 1; }
    done < "$TMPD/local-homes"
    primary=$(jq -r '.primary_model // empty' "$POOLS")
    if [ -n "$primary" ] && grep -Fxq -- "$primary" "$models" && primary_counts "$ROOT_STATE"; then
      printf '%s\t.primary\n' "$(canon_dir "$ROOT_STATE")"
    fi
    while IFS= read -r id; do
      [ "$id" != "$exclude" ] || continue
      if ! remote_confirmed "$id"; then
        UNCONFIRMED="$UNCONFIRMED $id"
        continue
      fi
      jq -r --slurpfile m <(jq -R . "$models" | jq -s .) \
        '.holders[] | select(.model == null or (.model as $x | $m[0] | index($x))) | "\(.state_dir)\t\(.task)"' \
        "$CERT_FILE" | while IFS=$'\t' read -r st task; do
          printf 'remote:%s:%s\t%s\n' "$id" "$st" "$task"
        done
    done < "$TMPD/remote-ids"
  } > "$TMPD/holders.raw"
  rc=$?
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 4 ] && return 4; return 1; }
  sort -u "$TMPD/holders.raw"
  [ -z "$UNCONFIRMED" ] || return 3
}

# remote_home_holders <models-file>: a remote home's own holders for one pool.
remote_home_holders() {
  local models=$1 home_state rc
  CONFLICT=
  registry_homes || return 1
  ledger_scan || return 1
  {
    ledger_pool_holders "$models"
    while IFS= read -r home_state; do
      pooled_records "$home_state" "$models" || { rc=$?; [ "$rc" -ne 4 ] || return 4; return 1; }
    done < "$TMPD/local-homes"
  } > "$TMPD/holders.raw" || return $?
  LC_ALL=C sort -u "$TMPD/holders.raw"
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
  [ "$RAW_LAUNCH" -eq 0 ] \
    || unavailable "a raw launch command cannot verify its actual model while fleet seat pools are configured"
  case "$MODEL" in
    ''|-|default) unavailable "harness $HARNESS launches an unverified default model; pass an explicit --model while fleet seat pools are configured" ;;
  esac
}

# --- lifecycle episode ownership ---------------------------------------------------

# lifecycle_join <state-dir> <task>: adopt the caller's verified lifecycle
# carrier for this supervisor, or take its mutex without waiting.
lifecycle_join() {
  local rc=0
  fm_supervisor_lifecycle_adopt "$1" "$2" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1)
      fm_supervisor_lifecycle_acquire "$1" "$2" 0 \
        || refuse "another lifecycle episode for supervisor $2 is active (pid ${FM_LOCK_HELD_PID:-unknown}); retry after it finishes"
      LIFECYCLE_JOINED="$1|$2"
      ;;
    *) refuse "the inherited lifecycle carrier for supervisor $2 does not verify against its live episode" ;;
  esac
}

lifecycle_leave() {
  [ -n "$LIFECYCLE_JOINED" ] || return 0
  fm_supervisor_lifecycle_release "${LIFECYCLE_JOINED%%|*}" "${LIFECYCLE_JOINED#*|}"
  LIFECYCLE_JOINED=
}

# --- endpoint evidence (collected outside the ledger lock) --------------------------

# route_local_state <generation>: recovery-grade state of the incarnation's
# local route, "none" without one.
route_local_state() {
  local backend target
  backend=$(inc_get "$1" '.route.backend // empty')
  target=$(inc_get "$1" '.route.target // empty')
  if [ -z "$backend" ] || [ -z "$target" ]; then
    printf 'none'
    return 0
  fi
  fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable'
}

# route_local_gone <generation>: the incarnation's local endpoint is PROVEN
# destroyed (fm_control_endpoint_absence_verdict), so a buffered launch line
# can no longer execute.
route_local_gone() {
  local backend target state verdict
  backend=$(inc_get "$1" '.route.backend // empty')
  target=$(inc_get "$1" '.route.target // empty')
  [ -n "$backend" ] && [ -n "$target" ] || return 1
  state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || return 1
  [ "$state" = missing ] || return 1
  verdict=$(fm_control_endpoint_absence_verdict "$backend" "$target")
  EVIDENCE_REASON=${verdict#*$'\t'}
  [ "${verdict%%$'\t'*}" = gone ]
}

# remote_disposition_fetch <task> <operation> <out-file>: ask the host for the
# token-scoped disposition, bounded and outside every lock.
remote_disposition_fetch() {
  local out
  out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    fm_run_timed "$REMOTE_CALL_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" "$1" \
      fm-remote-secondmate-control.sh disposition "$1" --operation "$2" </dev/null 2>/dev/null) || return 1
  printf '%s\n' "$out" | sed -n 's/^seat_disposition=//p' | tail -1 > "$3"
  [ -s "$3" ]
}

# --- argument parsing ---------------------------------------------------------

CMD=${1:-}
shift 2>/dev/null || true
TASK='' MODEL='' HOLDER='' HARNESS='' DIGEST_ARG='' EPOCH_ARG='' RAW_LAUNCH=0
GEN='' PREV_GEN='-' KIND='' ROUTE_FILE='' RESPONSE_FILE='' REASON='' LIMIT='' STATE_DIR_ARG=''
ALLOWANCES=''
case "$CMD" in
  reserve|dispatch|confirm|release|reclaim|reconcile-remote|show)
    TASK=${1:-}
    shift 2>/dev/null || true
    id_ok "$TASK" || usage
    ;;
esac
case "$CMD" in
  reserve|dispatch|confirm|release|reclaim|reconcile-remote)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --generation) GEN=${2:-}; shift 2 || usage ;;
        --previous-generation) PREV_GEN=${2:-}; shift 2 || usage ;;
        --model) MODEL=${2:-}; shift 2 || usage ;;
        --harness) HARNESS=${2:-}; shift 2 || usage ;;
        --holder-pid) HOLDER=${2:-}; shift 2 || usage ;;
        --kind) KIND=${2:-}; shift 2 || usage ;;
        --raw-launch) RAW_LAUNCH=1; shift ;;
        --route-file) ROUTE_FILE=${2:-}; shift 2 || usage ;;
        --response-file) RESPONSE_FILE=${2:-}; shift 2 || usage ;;
        --reason) REASON=${2:-}; shift 2 || usage ;;
        --state-dir) STATE_DIR_ARG=${2:-}; shift 2 || usage ;;
        *) usage ;;
      esac
    done
    gen_ok "$GEN" || usage
    [ "$PREV_GEN" = - ] || gen_ok "$PREV_GEN" || usage
    ;;
esac
case "$CMD" in
  reserve)
    [ -n "$HOLDER" ] || usage
    [ -n "$KIND" ] || KIND=ship
    case "$KIND" in ship|scout|secondmate) ;; *) usage ;; esac
    [ "$PREV_GEN" != "$GEN" ] || usage
    ;;
  dispatch) [ -n "$ROUTE_FILE" ] || usage ;;
  release)
    case "$REASON" in prelaunch|cancelled|replaced|teardown) ;; *) usage ;; esac
    ;;
  reconcile-remote) [ -n "$RESPONSE_FILE" ] || usage ;;
  confirm|reclaim|show) ;;
  reconcile)
    [ "${1:-}" = --limit ] && is_count "${2:-}" && [ "$#" -eq 2 ] || usage
    LIMIT=$2
    ;;
  serve-remotes) [ "$#" -eq 0 ] || usage ;;
  serve)
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --digest) DIGEST_ARG=${2:-}; shift 2 || usage ;;
        --epoch) EPOCH_ARG=${2:-}; shift 2 || usage ;;
        --allowance)
          case "${2:-}" in
            *=*) { is_count "${2#*=}" && pool_ok "${2%%=*}"; } || usage ;;
            *) usage ;;
          esac
          ALLOWANCES="$ALLOWANCES${2}
"
          shift 2
          ;;
        *) usage ;;
      esac
    done
    case "$DIGEST_ARG" in ''|*[!0-9-]*) usage ;; esac
    case "$EPOCH_ARG" in [A-Za-z0-9]*.[0-9]*) ;; *) usage ;; esac
    case "$EPOCH_ARG" in *[!A-Za-z0-9.]*) usage ;; esac
    ;;
  *) usage ;;
esac

if ! resolve_authority; then
  case "$CMD" in serve-remotes|reconcile) exit 0 ;; esac
  unavailable "this home's fleet root cannot be resolved from its secondmate parent binding"
fi

# The ledger this home's operations act on, and the policy that governs it.
if [ "$ROOT_REMOTE" -eq 1 ]; then
  LEDGER_STATE=$ROOT_STATE
  DELIVERED=$ROOT_STATE/fleet-seats/policy.json
  if [ -e "$DELIVERED" ] || [ -L "$DELIVERED" ]; then
    POLICY=$DELIVERED
  else
    POLICY=$ROOT_CONFIG/fleet-seats
  fi
else
  LEDGER_STATE=$ROOT_STATE
  POLICY=$ROOT_CONFIG/fleet-seats
  DELIVERED=
fi
LEDGER=$LEDGER_STATE/fleet-seats
LOCK=$LEDGER_STATE/.fleet-seats.lock

declared() {
  [ -e "$POLICY" ] || [ -L "$POLICY" ] || return 1
  if [ -n "$DELIVERED" ] && [ "$POLICY" = "$DELIVERED" ] && [ -f "$DELIVERED" ] && [ ! -L "$DELIVERED" ] \
    && cmp -s "$DELIVERED" <(printf '{"pools":[]}\n'); then
    return 1
  fi
  return 0
}

# Reserve opts out without a declaration; existing ledger transitions remain available.
OPT_OUT=0
case "$CMD" in
  reserve) declared || { [ -d "$LEDGER/holders" ] || exit 0; OPT_OUT=1; } ;;
  dispatch|confirm|release|reclaim|reconcile-remote|show)
    declared || [ -d "$LEDGER/holders" ] || exit 0
    ;;
  reconcile) [ -d "$LEDGER/holders" ] || exit 0 ;;
  serve-remotes)
    [ "$ROOT_SELF" -eq 1 ] || exit 0
    if [ ! -e "$ROOT_CONFIG/fleet-seats" ] && [ ! -L "$ROOT_CONFIG/fleet-seats" ] \
      && [ ! -d "$ROOT_STATE/fleet-seats" ]; then
      exit 0
    fi
    ;;
esac

command -v jq >/dev/null 2>&1 || unavailable "jq is not installed"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-fleet-seats.XXXXXX") || unavailable "cannot create a scratch directory"
LOCK_HELD=
LIFECYCLE_JOINED=
REGISTRY_ERROR=
LEDGER_ERROR=
EVIDENCE_REASON=
cleanup() {
  unlock
  lifecycle_leave
  rm -rf "$TMPD"
}
trap cleanup EXIT

CALLER_STATE=$(canon_dir "$STATE") || unavailable "this home's state directory $STATE is missing"
HOLDER_STATE=$CALLER_STATE
if [ -n "$STATE_DIR_ARG" ]; then
  [ "$CMD" = reclaim ] && [ "$ROOT_SELF" -eq 1 ] || usage
  HOLDER_STATE=$(canon_dir "$STATE_DIR_ARG") || refuse "state directory $STATE_DIR_ARG is missing"
  [ "$HOLDER_STATE" = "$STATE_DIR_ARG" ] || refuse "--state-dir must be canonical"
  registry_homes || unavailable "${REGISTRY_ERROR:-the secondmate registry cannot be read}"
  grep -Fxq -- "$HOLDER_STATE" "$TMPD/local-homes" || refuse "$HOLDER_STATE is not a registered home of this fleet"
fi

load_or_refuse() {
  holder_load "$HOLDER_STATE" "$TASK" || unavailable "the seat holder record for $TASK is malformed or names another holder"
}

# --- read-only ------------------------------------------------------------------

if [ "$CMD" = show ]; then
  load_or_refuse
  [ -z "$HOLDER_JSON" ] || printf '%s\n' "$HOLDER_JSON"
  exit 0
fi

# --- reserve --------------------------------------------------------------------

# reserve_apply <pool|-> <in-pool-already 0|1>: the generation checks and the
# new incarnation, under the ledger lock with HOLDER_JSON loaded. Prints
# "existing" for an idempotent retry.
reserve_apply() {
  local existing_model others identity
  if inc_exists "$GEN"; then
    case "$(inc_get "$GEN" .lifecycle)" in
      reserved|confirmed) ;;
      *) refuse "generation $GEN of $TASK is already terminal; a new episode needs a new generation" ;;
    esac
    existing_model=$(inc_get "$GEN" '.model // ""')
    [ "$existing_model" = "$MODEL" ] \
      || refuse "generation $GEN of $TASK is already reserved for model ${existing_model:-unresolved}, not $MODEL"
    RESERVE_EXISTING=1
    return 0
  fi
  if [ -n "$HOLDER_JSON" ]; then
    others=$(printf '%s\n' "$HOLDER_JSON" | jq -r --arg p "$PREV_GEN" \
      '.incarnations[] | select((.lifecycle == "reserved" or .lifecycle == "confirmed") and .generation != $p) | .generation' | head -1)
    [ -z "$others" ] \
      || refuse "an earlier launch of $TASK (generation $others) is still unresolved; reconcile or reclaim it before starting another"
  fi
  identity=$(fm_pid_identity "$HOLDER" 2>/dev/null || true)
  if [ -z "$HOLDER_JSON" ]; then
    HOLDER_JSON=$(jq -cn --arg s "$HOLDER_STATE" --arg t "$TASK" --arg schema "$HOLDER_SCHEMA" \
      '{schema: $schema, state_dir: $s, task: $t, revision: 0, incarnations: []}')
  fi
  holder_mutate '.incarnations += [{generation: $g,
      previous_generation: (if $p == "-" then null else $p end), kind: $k, model: $m,
      policy_digest_at_reserve: $d, lifecycle: "reserved", launch_phase: "prepared",
      owner_pid: ($o | tonumber), owner_pid_identity: $i, route: null,
      startup_confirmed: false, disposition: null}]' \
    --arg g "$GEN" --arg p "$PREV_GEN" --arg k "$KIND" --arg m "$MODEL" --arg d "$DIGEST" \
    --arg o "$HOLDER" --arg i "$identity" || unavailable "cannot write the seat holder record for $TASK"
  RESERVE_EXISTING=0
}

# --- transitions shared by the lifecycle verbs --------------------------------------

set_terminal() {  # <generation> <released|reclaimed> <reason> <source>
  holder_mutate '(.incarnations[] | select(.generation == $g)) |= (.lifecycle = $l
      | .disposition = {reason: $r, source: $src, generation: $g, route: .route,
          operation: (.route.operation // null)})' \
    --arg g "$1" --arg l "$2" --arg r "$3" --arg src "$4"
}

set_confirmed() {  # <generation>
  holder_mutate '(.incarnations[] | select(.generation == $g)) |= (.lifecycle = "confirmed"
      | .launch_phase = "started" | .startup_confirmed = true)' \
    --arg g "$1"
}

# lifecycle_join_for <generation>: join the episode when this holder is a
# supervisor. Must run before the ledger lock.
lifecycle_join_for() {
  [ "$(inc_get "$1" .kind)" = secondmate ] || return 0
  lifecycle_join "$HOLDER_STATE" "$TASK"
}

# relock_and_reload <revision>: take the ledger lock and reload; a record that
# moved since the evidence was collected invalidates it.
relock_and_reload() {
  lock_or_refuse "$LOCK"
  load_or_refuse
  [ -n "$HOLDER_JSON" ] && [ "$(holder_revision)" = "$1" ] \
    || refuse "the seat record for $TASK changed while its evidence was collected; retry with fresh evidence"
}

# --- remote disposition decoding ---------------------------------------------------

# apply_remote_disposition <response-file>: validate one host disposition for
# GEN and apply it. Runs under the ledger lock with HOLDER_JSON loaded.
apply_remote_disposition() {
  local resp=$1 op disposition actual prev_resp prev old_stopped actual_model requested_model route
  op=$(inc_get "$GEN" '.route.operation // empty')
  [ -n "$op" ] || refuse "generation $GEN of $TASK has no dispatched remote operation"
  jq -e --arg schema "$OPERATION_SCHEMA" --arg t "$TASK" --arg op "$op" --arg g "$GEN" '
    .schema == $schema and .complete == true and .task == $t and .operation == $op
    and .requested_generation == $g
    and (.disposition | IN("prelaunch", "started", "existing", "cancelled", "dead-after-start", "unknown"))
    and (.actual_generation == null or (.actual_generation | type == "string" and test("^[A-Za-z0-9._-]+$")))
    and (.previous_generation == null or (.previous_generation | type == "string"))
    and (.old_stopped | type == "boolean") and (.startup_confirmed | type == "boolean")
    and (.old_destroyed == null or (.old_destroyed | type == "boolean"))
    and (.actual_model == null or (.actual_model | type == "string" and length > 0))
    and (.route == null or (.route | type == "object" and .placement == "remote"
      and (.backend | type == "string") and (.target | type == "string" and length > 0)))
  ' "$resp" >/dev/null 2>&1 || uncertain "the host disposition for $TASK generation $GEN is malformed or belongs to another operation"
  disposition=$(jq -r .disposition "$resp")
  actual=$(jq -r '.actual_generation // empty' "$resp")
  prev_resp=$(jq -r '.previous_generation // empty' "$resp")
  prev=$(inc_get "$GEN" '.previous_generation // empty')
  old_stopped=$(jq -r .old_stopped "$resp")
  actual_model=$(jq -r '.actual_model // empty' "$resp")
  requested_model=$(inc_get "$GEN" '.model // ""')
  route=$(jq -c --arg op "$op" '.route // null | if . == null then . else . + {operation: $op} end' "$resp")
  if [ "$old_stopped" = true ]; then
    [ -n "$prev" ] && [ "$prev_resp" = "$prev" ] \
      || uncertain "the host reports a stopped predecessor for $TASK that does not match generation ${prev:-none}"
  fi
  release_stopped_predecessor() {
    [ "$old_stopped" = true ] || return 0
    inc_exists "$prev" || return 0
    case "$(inc_get "$prev" .lifecycle)" in
      reserved|confirmed)
        [ "$(inc_get "$prev" .startup_confirmed)" = true ] || [ "$(jq -r '.old_destroyed // false' "$resp")" = true ] \
          || uncertain "the host did not prove destruction of $TASK's unconfirmed predecessor $prev"
        set_terminal "$prev" released old-stopped reconcile-remote || unavailable "cannot record $TASK's stopped predecessor"
        ;;
    esac
  }
  case "$disposition" in
    prelaunch)
      [ "$(inc_get "$GEN" .lifecycle)" = reserved ] || refuse "generation $GEN of $TASK is not a pending candidate"
      [ "$old_stopped" = false ] || uncertain "a prelaunch refusal cannot report a stopped predecessor"
      set_terminal "$GEN" released prelaunch reconcile-remote || unavailable "cannot release $TASK's refused candidate"
      echo "fleet-seats: released id=$TASK generation=$GEN reason=prelaunch"
      ;;
    started)
      [ "$actual" = "$GEN" ] && [ "$(jq -r .startup_confirmed "$resp")" = true ] && [ "$route" != null ] \
        || uncertain "the host's started disposition for $TASK does not name generation $GEN with a confirmed startup"
      case "$(inc_get "$GEN" .lifecycle)" in reserved|confirmed) ;; *) refuse "generation $GEN of $TASK is already terminal" ;; esac
      holder_mutate '(.incarnations[] | select(.generation == $g)) |= (.route = $r
          | if $am != "" and $am != (.model // "") then .requested_model = .model | .model = $am else . end)' \
        --arg g "$GEN" --argjson r "$route" --arg am "$actual_model" || unavailable "cannot record $TASK's confirmed route"
      set_confirmed "$GEN" || unavailable "cannot confirm $TASK's started generation"
      release_stopped_predecessor
      echo "fleet-seats: confirmed id=$TASK generation=$GEN"
      if [ -n "$actual_model" ] && [ "$actual_model" != "$requested_model" ]; then
        echo "fleet-seats: model-mismatch id=$TASK requested=${requested_model:-unresolved} actual=$actual_model (counted on the actual model; admission to a full pool refuses until it resolves)" >&2
      fi
      ;;
    existing)
      [ -n "$actual" ] && [ "$actual" != "$GEN" ] && [ "$route" != null ] \
        || uncertain "the host's existing disposition for $TASK names no earlier generation"
      [ "$old_stopped" = false ] || uncertain "an existing disposition cannot report a stopped predecessor"
      if inc_exists "$actual"; then
        case "$(inc_get "$actual" .lifecycle)" in
          reserved) set_confirmed "$actual" || unavailable "cannot confirm $TASK's existing generation" ;;
          confirmed) ;;
          *) refuse "the host reports generation $actual of $TASK alive, but it is already terminal here; reconcile the route by hand" ;;
        esac
      else
        holder_mutate '.incarnations += [{generation: $a, previous_generation: null, kind: "secondmate",
            model: (if $am == "" then null else $am end), policy_digest_at_reserve: null,
            lifecycle: "confirmed", launch_phase: "started", owner_pid: null, owner_pid_identity: "",
            route: $r, startup_confirmed: true, disposition: null}]' \
          --arg a "$actual" --arg am "$actual_model" --argjson r "$route" || unavailable "cannot import $TASK's existing generation"
      fi
      set_terminal "$GEN" released prelaunch reconcile-remote || unavailable "cannot release $TASK's unsubmitted candidate"
      echo "fleet-seats: existing id=$TASK generation=$actual (candidate $GEN released)"
      ;;
    cancelled)
      case "$(inc_get "$GEN" .lifecycle)" in reserved) ;; *) refuse "generation $GEN of $TASK is not a pending candidate" ;; esac
      set_terminal "$GEN" released cancelled reconcile-remote || unavailable "cannot release $TASK's cancelled candidate"
      release_stopped_predecessor
      echo "fleet-seats: released id=$TASK generation=$GEN reason=cancelled"
      ;;
    dead-after-start)
      [ "$actual" = "$GEN" ] && [ "$(jq -r .startup_confirmed "$resp")" = true ] \
        || uncertain "the host's death report for $TASK does not name the started generation $GEN"
      case "$(inc_get "$GEN" .lifecycle)" in reserved|confirmed) ;; *) echo "fleet-seats: already terminal id=$TASK generation=$GEN"; return 0 ;; esac
      set_terminal "$GEN" reclaimed dead-after-start reconcile-remote || unavailable "cannot reclaim $TASK's dead generation"
      release_stopped_predecessor
      echo "fleet-seats: reclaimed id=$TASK generation=$GEN"
      ;;
    unknown)
      release_stopped_predecessor
      uncertain "the host cannot yet account for $TASK generation $GEN"
      ;;
  esac
}

if [ "$CMD" = reserve ] && [ "$OPT_OUT" -eq 1 ]; then
  load_or_refuse
  [ -n "$HOLDER_JSON" ] || exit 0
  if ! inc_exists "$GEN"; then
    inc_exists "$PREV_GEN" || exit 0
    case "$(inc_get "$PREV_GEN" .lifecycle)" in reserved|confirmed) ;; *) exit 0 ;; esac
  fi
  fm_pid_alive "$HOLDER" || unavailable "holder pid $HOLDER is not a running process"
  [ "$KIND" != secondmate ] || lifecycle_join "$HOLDER_STATE" "$TASK"
  lock_or_refuse "$LOCK"
  declared && unavailable "the fleet seat policy returned before the successor was recorded; retry admission"
  load_or_refuse
  if ! inc_exists "$GEN"; then
    case "$(inc_get "$PREV_GEN" .lifecycle)" in reserved|confirmed) ;; *) unavailable "the predecessor ended before its opt-out successor was recorded" ;; esac
  fi
  DIGEST=$(policy_digest <(printf '{"pools":[]}\n'))
  reserve_apply
  echo "fleet-seats: recorded id=$TASK generation=$GEN (existing holder successor during policy opt-out)"
  exit 0
fi

# --- lifecycle verbs -------------------------------------------------------------

case "$CMD" in
  dispatch|confirm|release|reclaim|reconcile-remote)
    load_or_refuse
    if [ -z "$HOLDER_JSON" ] || ! inc_exists "$GEN"; then
      case "$CMD" in
        release|reclaim)
          echo "fleet-seats: no seat held id=$TASK generation=$GEN"
          exit 0
          ;;
        *) refuse "no seat is reserved for $TASK generation $GEN" ;;
      esac
    fi
    lifecycle_join_for "$GEN"
    ;;
esac

if [ "$CMD" = dispatch ]; then
  private_file_ok "$ROUTE_FILE" || refuse "the route file $ROUTE_FILE is not a private regular file"
  jq -e --arg g "$GEN" '
    type == "object" and (.placement | IN("local", "remote"))
    and (if .placement == "local" then
          (.backend | type == "string" and length > 0) and (.target | type == "string" and length > 0)
          and .spawn_gen == $g and .host == null and .remote_root == null
        else
          (.host | type == "string" and length > 0) and (.remote_root | type == "string" and length > 0)
          and (.home | type == "string" and length > 0) and .operation == $g
        end)
  ' "$ROUTE_FILE" >/dev/null 2>&1 || refuse "the route file for $TASK generation $GEN is malformed"
  if [ "$(jq -r .placement "$ROUTE_FILE")" = local ]; then
    fm_backend_is_known "$(jq -r .backend "$ROUTE_FILE")" || refuse "the route for $TASK names an unknown backend"
  fi
  owner=$(inc_get "$GEN" '.owner_pid // empty')
  if [ -z "$owner" ] || ! holder_alive "$owner" "$(inc_get "$GEN" '.owner_pid_identity // ""')" \
    || ! fm_sm_lifecycle_is_ancestor "$owner"; then
    refuse "only the process that reserved $TASK generation $GEN may dispatch its launch"
  fi
  lock_or_refuse "$LOCK"
  load_or_refuse
  case "$(inc_get "$GEN" .lifecycle):$(inc_get "$GEN" .launch_phase)" in
    reserved:prepared) ;;
    reserved:dispatching|reserved:started|confirmed:*)
      echo "fleet-seats: already-dispatched id=$TASK generation=$GEN (never deliver a launch twice)"
      exit "$EXIT_UNCERTAIN"
      ;;
    *) refuse "generation $GEN of $TASK is not a prepared reservation" ;;
  esac
  holder_mutate '(.incarnations[] | select(.generation == $g)) |= (.launch_phase = "dispatching" | .route = $r[0])' \
    --arg g "$GEN" --slurpfile r "$ROUTE_FILE" || unavailable "cannot record the dispatch for $TASK"
  echo "fleet-seats: dispatched id=$TASK generation=$GEN"
  exit 0
fi

if [ "$CMD" = confirm ]; then
  if [ "$(inc_get "$GEN" .lifecycle)" = confirmed ]; then
    echo "fleet-seats: confirmed id=$TASK generation=$GEN (already)"
    exit 0
  fi
  [ "$(inc_get "$GEN" .lifecycle)" = reserved ] || refuse "generation $GEN of $TASK is terminal"
  [ "$(inc_get "$GEN" '.route.placement // ""')" = local ] \
    || refuse "generation $GEN of $TASK has no dispatched local route; a remote supervisor is confirmed from its host disposition"
  revision=$(holder_revision)
  state=$(route_local_state "$GEN")
  [ "$state" = alive ] || uncertain "the endpoint for $TASK generation $GEN reads '$state', not alive"
  relock_and_reload "$revision"
  set_confirmed "$GEN" || unavailable "cannot confirm $TASK generation $GEN"
  echo "fleet-seats: confirmed id=$TASK generation=$GEN"
  exit 0
fi

if [ "$CMD" = release ]; then
  lifecycle=$(inc_get "$GEN" .lifecycle)
  case "$lifecycle" in
    released|reclaimed)
      echo "fleet-seats: already terminal id=$TASK generation=$GEN"
      exit 0
      ;;
  esac
  phase=$(inc_get "$GEN" .launch_phase)
  revision=$(holder_revision)
  case "$REASON" in
    prelaunch)
      [ "$lifecycle:$phase" = reserved:prepared ] \
        || refuse "generation $GEN of $TASK was already dispatched; only proven cancellation or recovery can release it"
      ;;
    cancelled)
      [ "$lifecycle" = reserved ] || refuse "generation $GEN of $TASK already started; it is released by replacement, teardown, or reclaim"
      if [ "$phase" != prepared ]; then
        [ "$(inc_get "$GEN" '.route.placement // ""')" = local ] \
          || refuse "a remote candidate is cancelled only by its host disposition"
        # The launch owner's own rollback closed its endpoint: its own view of
        # that exact endpoint as missing is the structural proof (it addresses
        # the same server it created the endpoint on). Anyone else needs the
        # backend's absence proof.
        owner=$(inc_get "$GEN" '.owner_pid // empty')
        if [ -n "$owner" ] && holder_alive "$owner" "$(inc_get "$GEN" '.owner_pid_identity // ""')" \
          && fm_sm_lifecycle_is_ancestor "$owner" && [ "$(route_local_state "$GEN")" = missing ]; then
          :
        else
          route_local_gone "$GEN" \
            || uncertain "the submitted launch endpoint for $TASK generation $GEN is not proven destroyed${EVIDENCE_REASON:+: $EVIDENCE_REASON}"
        fi
      fi
      ;;
    replaced)
      [ -n "$(printf '%s\n' "$HOLDER_JSON" | jq -r --arg g "$GEN" \
        '.incarnations[] | select((.lifecycle == "reserved" or .lifecycle == "confirmed") and .previous_generation == $g) | .generation')" ] \
        || refuse "no counted replacement names generation $GEN of $TASK as its predecessor"
      case "$(inc_get "$GEN" '.route.placement // ""')" in
        local)
          state=$(route_local_state "$GEN")
          case "$state" in
            dead)
              [ "$(inc_get "$GEN" .startup_confirmed)" = true ] \
                || uncertain "the unconfirmed predecessor $TASK generation $GEN holds only a shell; its submitted launch may still execute"
              ;;
            missing) route_local_gone "$GEN" || uncertain "the old endpoint for $TASK is not proven stopped${EVIDENCE_REASON:+: $EVIDENCE_REASON}" ;;
            *) uncertain "the old endpoint for $TASK generation $GEN reads '$state', so its agent is not proven stopped" ;;
          esac
          ;;
        *) refuse "generation $GEN of $TASK has no local route whose stop can be verified here" ;;
      esac
      ;;
    teardown)
      meta="$HOLDER_STATE/$TASK.meta"
      if [ -e "$meta" ] || [ -L "$meta" ]; then
        [ "$(meta_generation "$meta")" != "$GEN" ] || refuse "task $TASK still records generation $GEN; cleanup has not finished"
      fi
      ;;
  esac
  relock_and_reload "$revision"
  set_terminal "$GEN" released "$REASON" release || unavailable "cannot release $TASK generation $GEN"
  echo "fleet-seats: released id=$TASK generation=$GEN reason=$REASON"
  exit 0
fi

if [ "$CMD" = reconcile-remote ]; then
  [ "$ROOT_SELF" -eq 1 ] || refuse "only the fleet root accounts for remote supervisors"
  private_file_ok "$RESPONSE_FILE" || refuse "the response file $RESPONSE_FILE is not a private regular file"
  lock_or_refuse "$LOCK"
  load_or_refuse
  inc_exists "$GEN" || refuse "no seat is reserved for $TASK generation $GEN"
  apply_remote_disposition "$RESPONSE_FILE"
  exit 0
fi

if [ "$CMD" = reclaim ]; then
  lifecycle=$(inc_get "$GEN" .lifecycle)
  case "$lifecycle" in
    released|reclaimed) echo "fleet-seats: already terminal id=$TASK generation=$GEN"; exit 0 ;;
  esac
  kind=$(inc_get "$GEN" .kind)
  phase=$(inc_get "$GEN" .launch_phase)
  owner=$(inc_get "$GEN" '.owner_pid // empty')
  if [ -n "$owner" ] && holder_alive "$owner" "$(inc_get "$GEN" '.owner_pid_identity // ""')"; then
    uncertain "the process that launched $TASK generation $GEN (pid $owner) is still running"
  fi
  meta="$HOLDER_STATE/$TASK.meta"
  if [ "$kind" != secondmate ] && [ -f "$meta" ] && [ "$(meta_generation "$meta")" = "$GEN" ]; then
    uncertain "$kind task $TASK still records generation $GEN; its seat is released by cleanup"
  fi
  revision=$(holder_revision)
  placement=$(inc_get "$GEN" '.route.placement // ""')
  if [ "$placement" = remote ]; then
    [ "$ROOT_SELF" -eq 1 ] || refuse "only the fleet root reconciles remote supervisors"
    op=$(inc_get "$GEN" '.route.operation // empty')
    remote_disposition_fetch "$TASK" "$op" "$TMPD/disposition" \
      || uncertain "the host did not report a disposition for $TASK operation $op"
    chmod 0600 "$TMPD/disposition"
    relock_and_reload "$revision"
    apply_remote_disposition "$TMPD/disposition"
    exit 0
  fi
  verdict=
  if [ "$phase" = prepared ]; then
    verdict='never-dispatched'
  elif [ -z "$placement" ]; then
    uncertain "generation $GEN of $TASK has no recorded route, so its launch cannot be proven finished"
  else
    state=$(route_local_state "$GEN")
    case "$state" in
      alive)
        if [ "$lifecycle" = reserved ]; then
          verdict=confirm
        else
          uncertain "the endpoint for $TASK generation $GEN is alive"
        fi
        ;;
      dead)
        [ "$lifecycle" = confirmed ] \
          || uncertain "the endpoint for $TASK generation $GEN holds only a shell; a submitted launch may still execute there"
        verdict='dead-after-start'
        ;;
      missing)
        route_local_gone "$GEN" || uncertain "the endpoint for $TASK generation $GEN is not proven destroyed${EVIDENCE_REASON:+: $EVIDENCE_REASON}"
        verdict='endpoint-gone'
        ;;
      *) uncertain "the endpoint for $TASK generation $GEN reads '$state'" ;;
    esac
  fi
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    META_LOCK_PATH=$(fm_meta_lock_path "$meta") || refuse "metadata lock path is invalid for $TASK"
    fm_lock_acquire_wait_max "$META_LOCK_PATH" "$LOCK_WAIT" || unavailable "the task record for $TASK stayed locked"
    trap 'fm_lock_release "$META_LOCK_PATH" || true; cleanup' EXIT
    if [ "$kind" = secondmate ] && [ -f "$meta" ]; then
      mg=$(meta_generation "$meta")
      [ -z "$mg" ] || [ "$mg" = "$GEN" ] || [ "$lifecycle" = reserved ] || ! inc_exists "$mg" \
        || [ "$(inc_get "$mg" .lifecycle)" = released ] || [ "$(inc_get "$mg" .lifecycle)" = reclaimed ] \
        || refuse "task $TASK now records generation $mg; the evidence about $GEN is stale"
    fi
  fi
  relock_and_reload "$revision"
  if [ "$verdict" = confirm ]; then
    set_confirmed "$GEN" || unavailable "cannot confirm $TASK generation $GEN"
    echo "fleet-seats: confirmed id=$TASK generation=$GEN"
    exit 0
  fi
  set_terminal "$GEN" reclaimed "$verdict" reclaim || unavailable "cannot reclaim $TASK generation $GEN"
  echo "fleet-seats: reclaimed id=$TASK generation=$GEN ($verdict)"
  exit 0
fi

if [ "$CMD" = reconcile ]; then
  lock_or_refuse "$LOCK"
  import_legacy_v1 || unavailable "${LEDGER_ERROR:-the legacy seat records cannot be imported}"
  ledger_scan || unavailable "${LEDGER_ERROR:-the seat ledger cannot be read}"
  unlock
  awk -F '\t' '$4 == "reserved" || $4 == "confirmed"' "$TMPD/ledger" > "$TMPD/candidates"
  tried=0
  while IFS=$'\t' read -r st task gen lifecycle _model kind phase owner placement _prev; do
    [ "$tried" -lt "$LIMIT" ] || break
    # A home below the root reconciles only its own holders in the shared ledger.
    [ "$ROOT_SELF" -eq 1 ] || [ "$st" = "$CALLER_STATE" ] || continue
    fm_pid_alive "$owner" && continue
    if [ "$lifecycle:$kind" = confirmed:secondmate ] && [ -f "$st/$task.meta" ] \
      && [ "$(meta_generation "$st/$task.meta")" = "$gen" ]; then
      continue
    fi
    if [ "$kind" != secondmate ] && [ -f "$st/$task.meta" ] \
      && [ "$(meta_generation "$st/$task.meta")" = "$gen" ]; then
      continue
    fi
    [ "$phase" != unknown ] || [ "$placement" != - ] || continue
    tried=$((tried + 1))
    args=(reclaim "$task" --generation "$gen")
    [ "$st" = "$CALLER_STATE" ] || args+=(--state-dir "$st")
    if out=$("$0" "${args[@]}" 2>&1); then
      printf '%s\n' "$out"
    else
      printf 'fleet-seats: skipped id=%s generation=%s: %s\n' "$task" "$gen" "$(printf '%s\n' "$out" | tail -1)"
    fi
  done < "$TMPD/candidates"
  exit 0
fi

# --- remote home ---------------------------------------------------------------

if [ "$ROOT_REMOTE" -eq 1 ]; then
  [ "$CMD" != serve-remotes ] || exit 0
  REQDIR=$LEDGER/requests

  if [ "$CMD" = serve ]; then
    mkdir -p "$REQDIR" || unavailable "cannot create $REQDIR"
    cat > "$TMPD/delivered" || unavailable "cannot read the delivered policy"
    validate_pools "$TMPD/delivered" || unavailable "the delivered policy is malformed"
    [ "$(policy_digest "$TMPD/delivered")" = "$DIGEST_ARG" ] || unavailable "the delivered policy does not match digest $DIGEST_ARG"
    ISSUER=${EPOCH_ARG%.*}
    SEQ=${EPOCH_ARG##*.}
    lock_or_refuse "$LOCK"
    SERVED=$LEDGER/served.json
    if [ -e "$SERVED" ] || [ -L "$SERVED" ]; then
      if [ ! -f "$SERVED" ] || [ -L "$SERVED" ] \
        || ! jq -e '(.issuer | type == "string") and (.seq | type == "number") and (.digest | type == "string") and (.response | type == "object")' "$SERVED" >/dev/null 2>&1; then
        unavailable "the serve record of this home is malformed"
      fi
      last_issuer=$(jq -r .issuer "$SERVED")
      last_seq=$(jq -r .seq "$SERVED")
      [ "$last_issuer" = "$ISSUER" ] || unavailable "serve epoch $EPOCH_ARG comes from another fleet root issuer than $last_issuer"
      if [ "$SEQ" -lt "$last_seq" ]; then
        unavailable "serve epoch $EPOCH_ARG is older than the applied epoch $last_issuer.$last_seq"
      elif [ "$SEQ" -eq "$last_seq" ]; then
        [ "$(jq -r .digest "$SERVED")" = "$DIGEST_ARG" ] || unavailable "serve epoch $EPOCH_ARG was already applied to another policy"
        jq -c .response "$SERVED"
        exit 0
      fi
    fi
    { cp "$TMPD/delivered" "$DELIVERED.tmp.$$" && mv -f "$DELIVERED.tmp.$$" "$DELIVERED"; } || unavailable "cannot store the delivered policy"
    POLICY=$DELIVERED
    DIGEST=$DIGEST_ARG
    import_legacy_v1 || unavailable "${LEDGER_ERROR:-the legacy seat records cannot be imported}"
    # Reject requests the delivered policy no longer supports.
    for f in "$REQDIR"/*.req; do
      [ -f "$f" ] || continue
      request_model=$(record_field "$f" model)
      request_pool=$(record_field "$f" pool)
      current_pool=$(pool_for_model "$DELIVERED" "$request_model")
      current_pool=${current_pool%%$'\t'*}
      [ -n "$current_pool" ] || current_pool=@checks
      if [ "$(record_field "$f" policy)" != "$DIGEST_ARG" ] || [ "$request_pool" != "$current_pool" ]; then
        response=${f%.req}.rejected
        { printf 'nonce=%s\n' "$(record_field "$f" nonce)" > "$response.tmp.$$" \
          && mv -f "$response.tmp.$$" "$response"; } \
          || unavailable "cannot reject a stale seat request"
        rm -f "$f"
      fi
    done
    # Arrival order: oldest request first.
    for f in "$REQDIR"/*.req; do
      [ -f "$f" ] || continue
      printf '%s\t%s\n' "$(record_field "$f" at)" "$f"
    done | sort -n > "$TMPD/requests"
    jq -r '.pools[].name' "$DELIVERED" > "$TMPD/pools"
    while IFS= read -r pool; do
      allowance=0
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        [ "${a%%=*}" != "$pool" ] || allowance=${a#*=}
      done <<EOF_ALLOW
$ALLOWANCES
EOF_ALLOW
      capacity=$(jq -r --arg p "$pool" '.pools[] | select(.name == $p) | .capacity' "$DELIVERED")
      pool_models "$DELIVERED" "$pool" > "$TMPD/models"
      if remote_home_holders "$TMPD/models" > "$TMPD/holders"; then
        :
      else
        rc=$?
        [ "$rc" -ne 4 ] || unavailable "$CONFLICT"
        unavailable "${LEDGER_ERROR:-the task records of this home cannot be read}"
      fi
      while IFS=$'\t' read -r _ f; do
        [ -f "$f" ] || continue
        [ "$(record_field "$f" pool)" = "$pool" ] || continue
        st=$(record_field "$f" state)
        task=$(record_field "$f" task)
        pid=$(record_field "$f" pid)
        gen=$(record_field "$f" nonce)
        if [ -z "$st" ] || ! id_ok "$task" || ! gen_ok "$gen" || ! holder_alive "$pid" "$(record_field "$f" pid_identity)"; then
          rm -f "$f"
          continue
        fi
        key=$(printf '%s\t%s' "$st" "$task")
        used=$(wc -l < "$TMPD/holders" | tr -d ' ')
        if grep -Fxq -- "$key" "$TMPD/holders" || [ "$used" -lt "$allowance" ]; then
          HOLDER_STATE=$st TASK=$task GEN=$gen PREV_GEN=$(record_field "$f" previous) KIND=$(record_field "$f" kind)
          MODEL=$(record_field "$f" model) HOLDER=$pid DIGEST=$DIGEST_ARG
          [ -n "$PREV_GEN" ] || PREV_GEN=-
          case "$KIND" in ship|scout|secondmate) ;; *) KIND=ship ;; esac
          holder_load "$st" "$task" || unavailable "the seat holder record for $task is malformed"
          if ( reserve_apply ) > "$TMPD/grant.out" 2>&1; then
            grep -Fxq -- "$key" "$TMPD/holders" || printf '%s\n' "$key" >> "$TMPD/holders"
          else
            printf 'nonce=%s\nreason=%s\n' "$gen" "$(tail -1 "$TMPD/grant.out")" > "${f%.req}.rejected.tmp.$$" \
              && mv -f "${f%.req}.rejected.tmp.$$" "${f%.req}.rejected"
          fi
        else
          {
            echo "nonce=$gen"
            echo "used=$((used + capacity - allowance))"
            echo "capacity=$capacity"
          } > "${f%.req}.denied.tmp.$$" && mv -f "${f%.req}.denied.tmp.$$" "${f%.req}.denied"
        fi
        rm -f "$f"
      done < "$TMPD/requests"
    done < "$TMPD/pools"
    for f in "$REQDIR"/*.req; do
      [ -f "$f" ] || continue
      [ "$(record_field "$f" pool)" = @checks ] || continue
      if ! holder_alive "$(record_field "$f" pid)" "$(record_field "$f" pid_identity)"; then
        rm -f "$f"
        continue
      fi
      st=$(record_field "$f" state)
      task=$(record_field "$f" task)
      gen=$(record_field "$f" nonce)
      if [ -z "$st" ] || ! id_ok "$task" || ! gen_ok "$gen"; then
        unavailable "the unpooled seat request is malformed"
      fi
      HOLDER_STATE=$st TASK=$task GEN=$gen PREV_GEN=$(record_field "$f" previous) KIND=$(record_field "$f" kind)
      MODEL=$(record_field "$f" model) HOLDER=$(record_field "$f" pid) DIGEST=$DIGEST_ARG
      [ -n "$PREV_GEN" ] || PREV_GEN=-
      case "$KIND" in ship|scout|secondmate) ;; *) KIND=ship ;; esac
      holder_load "$st" "$task" || unavailable "the seat holder record for $task is malformed"
      if ! ( reserve_apply ) > "$TMPD/grant.out" 2>&1; then
        { printf 'nonce=%s\nreason=%s\n' "$gen" "$(tail -1 "$TMPD/grant.out")" > "${f%.req}.rejected.tmp.$$" \
          && mv -f "${f%.req}.rejected.tmp.$$" "${f%.req}.rejected"; } \
          || unavailable "cannot reject an unpooled seat request"
      fi
      rm -f "$f"
    done
    # The certificate: every reserved or confirmed generation this home holds,
    # plus its unmanaged pooled records.
    ledger_scan || unavailable "${LEDGER_ERROR:-the seat ledger cannot be read}"
    jq -r '[.pools[].models[]] | .[]' "$DELIVERED" > "$TMPD/all-models"
    registry_homes || unavailable "${REGISTRY_ERROR:-the secondmate registry cannot be read}"
    : > "$TMPD/unmanaged"
    while IFS= read -r home_state; do
      pooled_records "$home_state" "$TMPD/all-models" >> "$TMPD/unmanaged" || unavailable "${CONFLICT:-the task records of this home cannot be read}"
    done < "$TMPD/local-homes"
    {
      awk -F '\t' '$4 == "reserved" || $4 == "confirmed" { print $1 "\t" $2 "\t" $3 "\t" $5 "\t" $4 }' "$TMPD/ledger"
      while IFS=$'\t' read -r st task; do
        m=$(record_field "$st/$task.meta" model)
        case "$m" in ''|default|-) m=- ;; esac
        g=$(meta_generation "$st/$task.meta")
        gen_ok "$g" || g=unmanaged
        printf '%s\t%s\t%s\t%s\tconfirmed\n' "$st" "$task" "$g" "$m"
      done < "$TMPD/unmanaged"
    } > "$TMPD/rows"
    response=$(jq -cRn --arg d "$DIGEST_ARG" --arg e "$EPOCH_ARG" --arg schema "$SERVE_SCHEMA" '
      {schema: $schema, policy_digest: $d, epoch: $e, complete: true,
       holders: [inputs | split("\t") | {state_dir: .[0], task: .[1], generation: .[2],
         model: (if .[3] == "-" then null else .[3] end), lifecycle: .[4]}]}' < "$TMPD/rows") \
      || unavailable "cannot build the serve certificate"
    { jq -cn --arg i "$ISSUER" --argjson s "$SEQ" --arg d "$DIGEST_ARG" --argjson r "$response" \
      '{issuer: $i, seq: $s, digest: $d, response: $r}' > "$SERVED.tmp.$$" \
      && mv -f "$SERVED.tmp.$$" "$SERVED"; } || unavailable "cannot record serve epoch $EPOCH_ARG"
    printf '%s\n' "$response"
    exit 0
  fi

  # reserve in a remote home
  if [ "$POLICY" != "$DELIVERED" ]; then
    validate_pools "$CONFIG/fleet-seats" || unavailable "$CONFIG/fleet-seats is malformed"
    require_explicit_model "$CONFIG/fleet-seats"
    [ -n "$(pool_for_model "$CONFIG/fleet-seats" "$MODEL")" ] || exit 0
    unavailable "the fleet root has not delivered a seat policy to this home"
  fi
  validate_pools "$POLICY" || unavailable "$POLICY is malformed"
  require_explicit_model "$POLICY"
  DIGEST=$(policy_digest "$POLICY")
  POOL_LINE=$(pool_for_model "$POLICY" "$MODEL")
  fm_pid_alive "$HOLDER" || unavailable "holder pid $HOLDER is not a running process"
  if [ -n "$POOL_LINE" ]; then
    POOL=${POOL_LINE%%$'\t'*}
  else
    POOL=@checks
  fi
  [ "$KIND" != secondmate ] || lifecycle_join "$HOLDER_STATE" "$TASK"
  mkdir -p "$REQDIR" || unavailable "cannot create $REQDIR"
  NAME=$(seat_name "$HOLDER_STATE" "$TASK")
  REQ=$REQDIR/$NAME.req
  DENIED=$REQDIR/$NAME.denied
  REJECTED=$REQDIR/$NAME.rejected

  granted() {
    holder_load "$HOLDER_STATE" "$TASK" || return 1
    inc_exists "$GEN" && [ "$(inc_get "$GEN" .lifecycle)" = reserved ] \
      && [ "$(inc_get "$GEN" '.model // ""')" = "$MODEL" ]
  }

  print_grant() {
    if [ "$POOL" = @checks ]; then
      echo "fleet-seats: recorded id=$TASK generation=$GEN (model $MODEL is in no pool)"
    else
      echo "fleet-seats: reserved pool=$POOL id=$TASK generation=$GEN ($1 by the fleet root)"
    fi
  }

  lock_or_refuse "$LOCK"
  load_or_refuse
  if granted; then
    print_grant 'already granted'
    exit 0
  fi
  if inc_exists "$GEN"; then
    refuse "generation $GEN of $TASK already exists with another model or state"
  fi
  if [ -n "$HOLDER_JSON" ]; then
    others=$(printf '%s\n' "$HOLDER_JSON" | jq -r --arg p "$PREV_GEN" \
      '.incarnations[] | select((.lifecycle == "reserved" or .lifecycle == "confirmed") and .generation != $p) | .generation' | head -1)
    [ -z "$others" ] \
      || refuse "an earlier launch of $TASK (generation $others) is still unresolved; reconcile or reclaim it before starting another"
  fi
  rm -f "$DENIED" "$REJECTED"
  {
    echo "state=$HOLDER_STATE"
    echo "task=$TASK"
    echo "model=$MODEL"
    echo "pool=$POOL"
    echo "kind=$KIND"
    echo "pid=$HOLDER"
    printf 'pid_identity=%s\n' "$(fm_pid_identity "$HOLDER" 2>/dev/null || true)"
    echo "nonce=$GEN"
    echo "previous=$PREV_GEN"
    echo "policy=$DIGEST"
    echo "at=$(date +%s)"
  } > "$REQ.tmp.$$" || unavailable "cannot write $REQ"
  mv -f "$REQ.tmp.$$" "$REQ" || unavailable "cannot write $REQ"
  unlock

  deadline=$((SECONDS + REMOTE_WAIT))
  while :; do
    if granted; then
      print_grant granted
      exit 0
    fi
    if [ -f "$REJECTED" ] && [ "$(record_field "$REJECTED" nonce)" = "$GEN" ]; then
      reason=$(record_field "$REJECTED" reason)
      rm -f "$REJECTED"
      unavailable "${reason:-the fleet seat policy changed before the request for $TASK was confirmed}"
    fi
    if [ -f "$DENIED" ] && [ "$(record_field "$DENIED" nonce)" = "$GEN" ]; then
      print_full "$POOL" "$(record_field "$DENIED" used)" "$(record_field "$DENIED" capacity)" -
      rm -f "$DENIED"
      exit "$EXIT_FULL"
    fi
    [ "$SECONDS" -lt "$deadline" ] || break
    sleep 1
  done
  lock_or_refuse "$LOCK"
  if granted; then
    print_grant granted
    exit 0
  fi
  rm -f "$REQ"
  unavailable "the fleet root on another host did not answer the seat request for $TASK within ${REMOTE_WAIT}s"
fi

# --- root and local homes ------------------------------------------------------

[ "$CMD" != serve ] || unavailable "serve runs only in a home whose fleet root is on another host"
POOLS=$POLICY

if [ "$CMD" = serve-remotes ]; then
  registry_homes || unavailable "${REGISTRY_ERROR:-the secondmate registry cannot be read}"
  [ -s "$TMPD/remote-ids" ] || exit 0
  mkdir -p "$LEDGER" || unavailable "cannot create $LEDGER"
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
    import_legacy_v1 || unavailable "${LEDGER_ERROR:-the legacy seat records cannot be imported}"
    # The serve epoch: a stable issuer plus a per-remote sequence, persisted
    # before dispatch and reconciled with every surviving certificate.
    ISSUER_FILE=$LEDGER/issuer
    if [ ! -e "$ISSUER_FILE" ]; then
      if ls "$LEDGER"/remote-*.cert "$LEDGER"/remote-*.pending >/dev/null 2>&1; then
        unavailable "the serve issuer record is missing while certificates exist; repair $LEDGER before serving"
      fi
      { printf 'r%s%s%s\n' "$(date +%s)" "$$" "$RANDOM" > "$ISSUER_FILE.tmp.$$" \
        && mv -f "$ISSUER_FILE.tmp.$$" "$ISSUER_FILE"; } || unavailable "cannot record the serve issuer"
    fi
    ISSUER=$(cat "$ISSUER_FILE" 2>/dev/null) || ISSUER=
    case "$ISSUER" in ''|*[!A-Za-z0-9]*) unavailable "the serve issuer record $ISSUER_FILE is malformed" ;; esac
    seq=$(cat "$LEDGER/remote-$id.seq" 2>/dev/null || echo 0)
    is_count "$seq" || unavailable "the serve sequence for $id is malformed"
    for f in "$LEDGER/remote-$id.cert" "$LEDGER/remote-$id.pending"; do
      [ -f "$f" ] || continue
      e=$(jq -r '.epoch // empty' "$f" 2>/dev/null || cat "$f")
      [ -n "$e" ] || e=$(cat "$f")
      [ "${e%.*}" = "$ISSUER" ] || unavailable "a serve record for $id comes from another issuer than $ISSUER"
      s=${e##*.}
      is_count "$s" || unavailable "a serve record for $id has a malformed epoch"
      [ "$s" -le "$seq" ] || seq=$s
    done
    seq=$((seq + 1))
    EPOCH="$ISSUER.$seq"
    { printf '%s\n' "$seq" > "$LEDGER/remote-$id.seq.tmp.$$" && mv -f "$LEDGER/remote-$id.seq.tmp.$$" "$LEDGER/remote-$id.seq"; } \
      || unavailable "cannot persist the serve sequence for $id"
    jq -r '.pools[] | "\(.name)\t\(.capacity)"' "$POOLS" > "$TMPD/pools"
    set --
    while IFS=$'\t' read -r name cap; do
      pool_models "$POOLS" "$name" > "$TMPD/models"
      if root_holders "$TMPD/models" "$id" > "$TMPD/holders"; then
        others=$(wc -l < "$TMPD/holders" | tr -d ' ')
        allowance=$((cap - others))
        [ "$allowance" -ge 0 ] || allowance=0
      else
        rc=$?
        [ "$rc" -eq 3 ] || unavailable "${CONFLICT:-${REGISTRY_ERROR:-${LEDGER_ERROR:-a fleet task record cannot be read}}}"
        allowance=0
      fi
      set -- "$@" --allowance "$name=$allowance"
    done < "$TMPD/pools"
    # Invalidate before dispatch: a lost or late response can never certify.
    { printf '%s\n' "$EPOCH" > "$LEDGER/remote-$id.pending.tmp.$$" \
      && mv -f "$LEDGER/remote-$id.pending.tmp.$$" "$LEDGER/remote-$id.pending"; } \
      || unavailable "cannot invalidate the certificate for $id"
    rm -f "$LEDGER/remote-$id.policy" "$LEDGER/remote-$id.holders" 2>/dev/null || true
    unlock
    served=0
    rpc_rc=0
    fm_run_timed "$REMOTE_CALL_TIMEOUT" "$SCRIPT_DIR/fm-on.sh" --stdin "$id" fm-fleet-seats.sh serve \
        --digest "$DIGEST" --epoch "$EPOCH" "$@" < "$POOLS" > "$TMPD/served" 2>"$TMPD/served.err" || rpc_rc=$?
    lock_or_refuse "$LOCK"
    if [ "$rpc_rc" -eq 0 ]; then
      grep '^{' "$TMPD/served" | tail -1 > "$TMPD/cert"
      if jq -e --arg d "$DIGEST" --arg e "$EPOCH" --arg schema "$SERVE_SCHEMA" '
          .schema == $schema and .policy_digest == $d and .epoch == $e and .complete == true
          and (.holders | type == "array")
          and all(.holders[];
            (.state_dir | type == "string" and startswith("/"))
            and (.task | type == "string" and test("^[A-Za-z0-9_-][A-Za-z0-9._-]*$"))
            and (.generation | type == "string" and test("^[A-Za-z0-9._-]+$"))
            and (.model == null or (.model | type == "string" and length > 0))
            and (.lifecycle | IN("reserved", "confirmed")))
          and ([.holders[] | [.state_dir, .task, .generation]] | length == (unique | length))
        ' "$TMPD/cert" >/dev/null 2>&1; then
        served=1
      fi
    fi
    if [ "$(cat "$LEDGER/remote-$id.pending" 2>/dev/null)" != "$EPOCH" ]; then
      echo "unreachable $id (serve epoch superseded)"
      unlock
      continue
    fi
    if [ -e "$ROOT_CONFIG/fleet-seats" ] || [ -L "$ROOT_CONFIG/fleet-seats" ]; then
      validate_pools "$ROOT_CONFIG/fleet-seats" && [ "$(policy_digest "$ROOT_CONFIG/fleet-seats")" = "$DIGEST" ] || served=0
    else
      [ "$(policy_digest <(printf '{"pools":[]}\n'))" = "$DIGEST" ] || served=0
    fi
    if [ "$served" -eq 1 ]; then
      { cp "$TMPD/cert" "$LEDGER/remote-$id.cert.tmp.$$" && mv -f "$LEDGER/remote-$id.cert.tmp.$$" "$LEDGER/remote-$id.cert"; } \
        || unavailable "cannot record the certificate for $id"
      [ "$(cat "$LEDGER/remote-$id.pending" 2>/dev/null)" != "$EPOCH" ] || rm -f "$LEDGER/remote-$id.pending"
      rm -f "$failed"
      echo "served $id policy=$DIGEST epoch=$EPOCH holders=$(jq '.holders | length' "$LEDGER/remote-$id.cert")"
    else
      : > "$failed"
      echo "unreachable $id"
    fi
    unlock
  done < "$TMPD/serve-ids"
  exit 0
fi

# reserve at the root or a local home
validate_pools "$POOLS" || unavailable "$POOLS is malformed (see docs/configuration.md \"Fleet seat pools\")"
require_explicit_model "$POOLS"
POOL_LINE=$(pool_for_model "$POOLS" "$MODEL")
DIGEST=$(policy_digest "$POOLS")
fm_pid_alive "$HOLDER" || unavailable "holder pid $HOLDER is not a running process"
[ -d "$ROOT_STATE" ] || unavailable "the fleet root state directory $ROOT_STATE is missing"
[ "$KIND" != secondmate ] || lifecycle_join "$HOLDER_STATE" "$TASK"
mkdir -p "$LEDGER/holders" 2>/dev/null || unavailable "cannot create $LEDGER/holders"
lock_or_refuse "$LOCK"
[ -e "$POOLS" ] && validate_pools "$POOLS" && [ "$(policy_digest "$POOLS")" = "$DIGEST" ] \
  || unavailable "the fleet seat policy changed before the reservation was decided"
import_legacy_v1 || unavailable "${LEDGER_ERROR:-the legacy seat records cannot be imported}"
load_or_refuse

if [ -z "$POOL_LINE" ]; then
  reserve_apply
  echo "fleet-seats: recorded id=$TASK generation=$GEN (model $MODEL is in no pool)"
  exit 0
fi
POOL=${POOL_LINE%%$'\t'*}
CAP=${POOL_LINE#*$'\t'}
pool_models "$POOLS" "$POOL" > "$TMPD/models"
if root_holders "$TMPD/models" > "$TMPD/holders"; then
  :
else
  rc=$?
  case "$rc" in
    3) unavailable "remote secondmate(s)$UNCONFIRMED have not confirmed the current seat policy, so their agents cannot be counted yet" ;;
    4) unavailable "$CONFLICT" ;;
    *) unavailable "${REGISTRY_ERROR:-${LEDGER_ERROR:-a fleet task record cannot be read}}" ;;
  esac
fi
load_or_refuse
USED=$(wc -l < "$TMPD/holders" | tr -d ' ')
KEY=$(printf '%s\t%s' "$HOLDER_STATE" "$TASK")
if ! inc_exists "$GEN" && ! grep -Fxq -- "$KEY" "$TMPD/holders" && [ "$USED" -ge "$CAP" ]; then
  print_full "$POOL" "$USED" "$CAP" "$TMPD/holders"
  exit "$EXIT_FULL"
fi
reserve_apply
if [ "$RESERVE_EXISTING" -eq 1 ]; then
  echo "fleet-seats: reserved pool=$POOL id=$TASK generation=$GEN (already reserved) used=$USED capacity=$CAP"
elif grep -Fxq -- "$KEY" "$TMPD/holders"; then
  echo "fleet-seats: reserved pool=$POOL id=$TASK generation=$GEN (already held) used=$USED capacity=$CAP"
else
  echo "fleet-seats: reserved pool=$POOL id=$TASK generation=$GEN used=$((USED + 1)) capacity=$CAP"
fi
