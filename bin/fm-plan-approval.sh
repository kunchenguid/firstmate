#!/usr/bin/env bash
# Plan approval: the primary firstmate's cryptographic authorization for one
# secondmate implementation, and the home-side check that enforces it.
#
# THE CONTRACT THIS FILE OWNS
# The captain's standing order is that an officer submits a plan (goal, which
# agreement it implements, steps, acceptance) before EVERY implementation and
# starts only after the main firstmate's explicit approval, while investigation
# and analysis stay free. This script is the mechanical form of that order: it
# is the single owner of the approval record, the signing and verification
# procedure, the key files, and the gate's exact scope. Every other mention of
# the plan gate is a one-line cross-reference to this header.
#
# WHAT IS GATED
#   Gated:    a ship spawn (bin/fm-spawn.sh with --mode) started in a home that
#             carries the .fm-secondmate-home marker, and a scout promotion
#             (bin/fm-promote.sh) in such a home, which is the other way a
#             ship contract can begin there.
#   Ungated:  scout spawns (investigation and analysis stay free), secondmate
#             launches, and --relaunch. A relaunch cannot create a task: it
#             reuses metadata that only a gated fresh spawn could have written,
#             so leaving it open keeps recovery working without opening a path
#             to start an implementation.
#   Ungated:  the primary home. Its dispatches are the approving instance's own.
#
# KEYS
#   config/plan-approval-key       ed25519 private key, PEM, mode 0600. Created
#                                  lazily by `init` or the first `approve`, in
#                                  the PRIMARY home only. It is never inherited,
#                                  never copied into a secondmate home, and is
#                                  absent from every propagation path
#                                  (bin/fm-config-inherit-lib.sh).
#   config/plan-approval-key.pub   ed25519 public key, PEM, mode 0644. This is
#                                  the one inherited item: it is declared in
#                                  FM_INHERITABLE_CONFIG, so every convergence
#                                  point pushes it into each secondmate home,
#                                  local and remote alike.
# An officer home therefore holds only the public half. It cannot mint a
# signature from anything present in it.
#
# THE APPROVAL RECORD
# One record per approved task, written into the officer home at
# state/<task-id>.plan-approval, mode 0444, EXACTLY eight lines in this order:
#   v=1
#   task=<task-id>
#   secondmate=<secondmate-id>
#   plan_sha256=<64 lowercase hex>
#   plan_bytes=<decimal>
#   approved_at=<YYYY-MM-DDTHH:MM:SSZ>
#   key_sha256=<64 lowercase hex of the approving public-key file>
#   sig=<base64 ed25519 signature>
# The signature covers the first seven lines byte-exactly. Any extra line,
# missing line, reordered key, or malformed value is rejected before the
# signature is even checked, so the parsed record and the signed bytes are the
# same thing by construction.
# The record is task-scoped state, so bin/fm-teardown.sh retires it with the
# task's other state files and a later task cannot inherit it by reusing an id.
#
# PLAN BINDING
# `plan_sha256` is the content hash of the approved plan, and the gate hashes
# the brief it is about to hand the worker. The approved plan is therefore the
# exact instructions the worker will follow: edit the brief after approval and
# verification fails until a fresh approval is issued. `approve` refuses when the
# officer home's brief for that task is readable and does not already match the
# approved bytes, so an unusable approval is never minted.
#
# VERIFICATION, IN ORDER
#   1. The active home carries a valid .fm-secondmate-home marker.
#   2. state/<task-id>.plan-approval exists as a non-symlink regular file.
#   3. The record has the exact eight-line structure above.
#   4. task= matches the task being launched.
#   5. secondmate= matches this home's marker id, so a record cannot be replayed
#      into a different officer home.
#   6. key_sha256 matches the trusted public key, which gives a precise
#      "signed by a key this home does not trust" diagnostic.
#   7. The ed25519 signature verifies against that trusted public key.
#   8. The plan file's size and sha256 match plan_bytes and plan_sha256.
# Any failure refuses. There is no degraded pass.
#
# TRUSTED KEY PRECEDENCE
# When the officer home records a LOCAL parent binding (.fm-secondmate-parent,
# bin/fm-secondmate-parent-lib.sh), that parent home's config/plan-approval-key.pub
# is the trusted key, with no fallback: it lives outside the home being gated,
# and falling back whenever it is unreadable would turn a deleted key into a
# silent downgrade to a key this home can rewrite. A remote binding, or no
# binding at all, uses the inherited config/plan-approval-key.pub, which is the
# only key such a home can reach. Every convergence point re-pushes that
# inherited copy from the primary, so a rewritten one is also restored on the
# next push.
#
# BOUNDARY, STATED HONESTLY
# The cryptographic guarantee is that no approval can be produced without the
# primary's private key, and that key exists only in the primary home. It is not
# a sandbox: a home has write access to its own files, so this gate stops an
# officer that starts an implementation without approval, not one that rewrites
# the scripts it runs. That is the same threat model as bin/fm-gate-refuse-lib.sh.
#
# DEPENDENCY
# Signing and verification use `openssl` ed25519 raw sign/verify. `init` proves
# the installed build can do it before writing any key, and a verification
# failure re-probes so "this openssl cannot verify ed25519" is never reported as
# a bad signature.
#
# Usage:
#   fm-plan-approval.sh init
#       Create the primary keypair if it does not exist and print its
#       fingerprint. Refused in a secondmate home.
#   fm-plan-approval.sh pubkey
#       Print the primary public key path and its fingerprint, for hand
#       delivery to a home the inheritance path cannot reach.
#   fm-plan-approval.sh approve <secondmate-id> <task-id> --plan-file <path> [--home <path>] [--emit]
#       Sign the plan for that exact task and write the record into that
#       secondmate home. --emit prints the record to stdout instead of writing
#       it, which is how a remote route is served: place the printed bytes at
#       <remote-home>/state/<task-id>.plan-approval on that host. A remote route
#       requires --emit, because this home cannot write into it.
#       --home names the target home directly instead of resolving it from this
#       home's task metadata and secondmate registry, for a home that is not
#       currently recorded there. It is exactly as strong: the record still
#       carries the secondmate id, that id must match the target's own
#       .fm-secondmate-home marker, and verification re-checks both.
#   fm-plan-approval.sh verify <task-id> [--plan-file <path>]
#       The home-side check bin/fm-spawn.sh and bin/fm-promote.sh call. Runs in
#       the home being gated. --plan-file defaults to data/<task-id>/brief.md.
#       Prints one summary line on success and a concrete refusal on failure.
#   fm-plan-approval.sh revoke <task-id> [--secondmate <id>]
#       Remove an approval. Without --secondmate this acts on the active home;
#       with it, on that registered secondmate home.
#   fm-plan-approval.sh list [--secondmate <id>]
#       List approvals in the active home, or in that secondmate home, one
#       tab-separated line per record: task, secondmate, approval time, plan
#       hash, and verdict (valid, stale when it no longer covers the current
#       plan or key, or malformed with the parse error).
#
# Exit status: 0 success, 1 refusal or error, 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
  echo "error: FM_HOME cannot be resolved" >&2
  exit 1
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

PRIVATE_KEY_NAME="plan-approval-key"
PUBLIC_KEY_NAME="plan-approval-key.pub"
RECORD_SUFFIX=".plan-approval"
RECORD_VERSION=1

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
refuse() { printf 'plan-approval: %s\n' "$1" >&2; exit 1; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

byte_count() { wc -c < "$1" | tr -d ' '; }

valid_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    .|..) return 1 ;;
  esac
  return 0
}

valid_hex64() {
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

valid_decimal() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

valid_base64() {
  case "$1" in
    ''|*[!A-Za-z0-9+/=]*) return 1 ;;
  esac
  return 0
}

valid_timestamp() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) return 0 ;;
  esac
  return 1
}

regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

# Prove this openssl build can create and verify a raw ed25519 signature. Run
# before any key is written, and again after a verification failure so a missing
# capability is never reported as a bad signature.
openssl_ed25519_works() {
  local probe rc=0
  command -v openssl >/dev/null 2>&1 || return 1
  probe=$(mktemp -d "${TMPDIR:-/tmp}/fm-plan-approval-probe.XXXXXX") || return 1
  printf 'probe\n' > "$probe/msg"
  if ! openssl genpkey -algorithm ed25519 -out "$probe/key" >/dev/null 2>&1 \
    || ! openssl pkey -in "$probe/key" -pubout -out "$probe/key.pub" >/dev/null 2>&1 \
    || ! openssl pkeyutl -sign -inkey "$probe/key" -rawin -in "$probe/msg" -out "$probe/sig" >/dev/null 2>&1 \
    || ! openssl pkeyutl -verify -pubin -inkey "$probe/key.pub" -rawin -in "$probe/msg" -sigfile "$probe/sig" >/dev/null 2>&1; then
    rc=1
  fi
  rm -rf "$probe"
  return "$rc"
}

openssl_requirement() {
  printf '%s' "signing and verification need an openssl build with ed25519 raw sign/verify (openssl 1.1.1 or newer; on macOS the system LibreSSL may not qualify, install openssl@3)"
}

# --- key resolution ---------------------------------------------------------

primary_private_key() { printf '%s/%s\n' "$CONFIG" "$PRIVATE_KEY_NAME"; }
primary_public_key() { printf '%s/%s\n' "$CONFIG" "$PUBLIC_KEY_NAME"; }

# Create the primary keypair when it is absent. Refuses in a secondmate home and
# refuses a half-present pair rather than silently minting a key that would
# replace the one the fleet already trusts.
ensure_primary_keypair() {
  local private public tmp_private tmp_public
  private=$(primary_private_key)
  public=$(primary_public_key)
  if fm_root_is_secondmate_home "$FM_HOME"; then
    refuse "only the primary firstmate mints plan approvals; this home is a secondmate home"
  fi
  if regular_file "$private" && regular_file "$public"; then
    return 0
  fi
  if [ -e "$private" ] || [ -L "$private" ] || [ -e "$public" ] || [ -L "$public" ]; then
    refuse "the plan-approval keypair at $CONFIG is incomplete or not a pair of ordinary files; repair it by hand rather than letting a new key replace the one secondmate homes already trust"
  fi
  openssl_ed25519_works || refuse "$(openssl_requirement)"
  mkdir -p "$CONFIG" || refuse "could not create $CONFIG"
  tmp_private=$(umask 077; mktemp "$CONFIG/.plan-approval-key.XXXXXX") || refuse "could not stage a new private key"
  tmp_public="$tmp_private.pub"
  if ! openssl genpkey -algorithm ed25519 -out "$tmp_private" >/dev/null 2>&1 \
    || ! openssl pkey -in "$tmp_private" -pubout -out "$tmp_public" >/dev/null 2>&1; then
    rm -f "$tmp_private" "$tmp_public"
    refuse "could not generate the ed25519 plan-approval keypair"
  fi
  chmod 0600 "$tmp_private" 2>/dev/null || true
  chmod 0644 "$tmp_public" 2>/dev/null || true
  # Publish the private half first: a failure after only the public half landed
  # would leave a key the fleet would start trusting with nothing able to sign
  # for it, so each failure path removes everything it created.
  if ! mv -f "$tmp_private" "$private"; then
    rm -f "$tmp_private" "$tmp_public"
    refuse "could not publish the plan-approval private key into $CONFIG"
  fi
  if ! mv -f "$tmp_public" "$public"; then
    rm -f "$tmp_public" "$private"
    refuse "could not publish the plan-approval public key into $CONFIG"
  fi
  printf 'plan-approval: created the primary keypair at %s\n' "$private" >&2
}

# Set TRUSTED_KEY_PATH to the public key file this home trusts and
# TRUSTED_KEY_SOURCE to "parent" or "inherited". Both are globals rather than
# stdout so the source survives for the diagnostics. Precedence is documented
# above.
TRUSTED_KEY_PATH=
TRUSTED_KEY_SOURCE=
resolve_trusted_public_key() {
  local parent_record parent_key local_key
  TRUSTED_KEY_PATH=
  TRUSTED_KEY_SOURCE=
  parent_record="$FM_HOME/.fm-secondmate-parent"
  if fm_secondmate_parent_record_parse "$parent_record" \
    && [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] \
    && [ -n "$FM_SECONDMATE_PARENT_HOME" ]; then
    # A local parent is authoritative with no fallback: falling back to this
    # home's own copy whenever the parent key is unreadable would turn a
    # deleted key into a silent downgrade to a key this home can rewrite.
    parent_key="$FM_SECONDMATE_PARENT_HOME/config/$PUBLIC_KEY_NAME"
    regular_file "$parent_key" || return 1
    TRUSTED_KEY_PATH=$parent_key
    TRUSTED_KEY_SOURCE=parent
    return 0
  fi
  local_key="$CONFIG/$PUBLIC_KEY_NAME"
  if regular_file "$local_key"; then
    TRUSTED_KEY_PATH=$local_key
    TRUSTED_KEY_SOURCE=inherited
    return 0
  fi
  return 1
}

# --- secondmate home resolution --------------------------------------------

# True when <home> carries a valid secondmate marker naming exactly <id>. This
# is the identity binding the record commits to, so an explicitly named target
# is checked against it exactly as a resolved one is.
marker_home_id_matches() {  # <home> <secondmate-id>
  local home=$1 id=$2 marker_id
  fm_root_is_secondmate_home "$home" || return 1
  IFS= read -r marker_id < "$home/.fm-secondmate-home" || true
  marker_id=${marker_id//[[:space:]]/}
  [ "$marker_id" = "$id" ]
}

resolve_secondmate_home() {  # <secondmate-id> -> prints "<home>|<remote-host>"
  local id=$1 home remote host meta
  valid_id "$id" || die "invalid secondmate id: $id"
  meta="$STATE/$id.meta"
  home=""
  if [ -f "$meta" ]; then
    home=$(grep '^home=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  if [ -z "$home" ]; then
    home=$(secondmate_registry_field "$DATA/secondmates.md" "$id" home 2>/dev/null || true)
  fi
  [ -n "$home" ] || die "no home recorded for secondmate $id in $STATE/$id.meta or $DATA/secondmates.md"
  remote=$(secondmate_registry_field "$DATA/secondmates.md" "$id" remote 2>/dev/null || true)
  host=""
  if [ "$remote" = 1 ]; then
    host=$(secondmate_registry_field "$DATA/secondmates.md" "$id" host 2>/dev/null || true)
    [ -n "$host" ] || host="the configured host"
    printf '%s|%s\n' "$home" "$host"
    return 0
  fi
  validate_secondmate_home "$id" "$home" || die "secondmate $id home is not usable: $VALIDATION_ERROR"
  printf '%s|\n' "$VALIDATED_HOME"
}

# --- record read/write ------------------------------------------------------

RECORD_TASK=
RECORD_SECONDMATE=
RECORD_PLAN_SHA=
RECORD_PLAN_BYTES=
RECORD_APPROVED_AT=
RECORD_KEY_SHA=
RECORD_SIG=

# Parse one record with the exact eight-line structure. Returns 1 and sets
# RECORD_PARSE_ERROR on any deviation, so the signed bytes and the parsed fields
# can never disagree.
RECORD_PARSE_ERROR=
parse_record() {  # <record-file>
  local file=$1 lines
  RECORD_PARSE_ERROR=
  RECORD_TASK=; RECORD_SECONDMATE=; RECORD_PLAN_SHA=; RECORD_PLAN_BYTES=
  RECORD_APPROVED_AT=; RECORD_KEY_SHA=; RECORD_SIG=
  regular_file "$file" || { RECORD_PARSE_ERROR="record is not an ordinary file"; return 1; }
  lines=$(wc -l < "$file" | tr -d ' ')
  if [ "$lines" != 8 ]; then
    RECORD_PARSE_ERROR="record must be exactly 8 lines, found $lines"
    return 1
  fi
  local n=0 line key value
  while IFS= read -r line; do
    n=$((n + 1))
    key=${line%%=*}
    value=${line#*=}
    case "$n:$key" in
      1:v)
        [ "$value" = "$RECORD_VERSION" ] || { RECORD_PARSE_ERROR="unsupported record version '$value'"; return 1; }
        ;;
      2:task)
        valid_id "$value" || { RECORD_PARSE_ERROR="malformed task field"; return 1; }
        RECORD_TASK=$value ;;
      3:secondmate)
        valid_id "$value" || { RECORD_PARSE_ERROR="malformed secondmate field"; return 1; }
        RECORD_SECONDMATE=$value ;;
      4:plan_sha256)
        valid_hex64 "$value" || { RECORD_PARSE_ERROR="malformed plan_sha256 field"; return 1; }
        RECORD_PLAN_SHA=$value ;;
      5:plan_bytes)
        valid_decimal "$value" || { RECORD_PARSE_ERROR="malformed plan_bytes field"; return 1; }
        RECORD_PLAN_BYTES=$value ;;
      6:approved_at)
        valid_timestamp "$value" || { RECORD_PARSE_ERROR="malformed approved_at field"; return 1; }
        RECORD_APPROVED_AT=$value ;;
      7:key_sha256)
        valid_hex64 "$value" || { RECORD_PARSE_ERROR="malformed key_sha256 field"; return 1; }
        RECORD_KEY_SHA=$value ;;
      8:sig)
        valid_base64 "$value" || { RECORD_PARSE_ERROR="malformed sig field"; return 1; }
        RECORD_SIG=$value ;;
      *)
        RECORD_PARSE_ERROR="unexpected field '$key' on line $n"
        return 1 ;;
    esac
  done < "$file"
  return 0
}

record_path() {  # <home> <task-id>
  printf '%s/state/%s%s\n' "$1" "$2" "$RECORD_SUFFIX"
}

# --- subcommands ------------------------------------------------------------

cmd_init() {
  [ "$#" -eq 0 ] || { echo "usage: fm-plan-approval.sh init" >&2; exit 2; }
  ensure_primary_keypair
  printf 'plan-approval: primary key %s sha256=%s\n' "$(primary_public_key)" "$(sha256_file "$(primary_public_key)")"
}

cmd_pubkey() {
  [ "$#" -eq 0 ] || { echo "usage: fm-plan-approval.sh pubkey" >&2; exit 2; }
  local public
  public=$(primary_public_key)
  regular_file "$public" || refuse "no plan-approval public key at $public; run 'bin/fm-plan-approval.sh init' in the primary home first"
  printf 'plan-approval: public key %s sha256=%s\n' "$public" "$(sha256_file "$public")"
  cat "$public"
}

cmd_approve() {
  local secondmate_id="" task_id="" plan_file="" home_arg="" emit=0 want_value=""
  local a
  for a in "$@"; do
    if [ -n "$want_value" ]; then
      case "$a" in --*) echo "error: --$want_value requires a value" >&2; exit 2 ;; esac
      case "$want_value" in
        plan-file) plan_file=$a ;;
        home) home_arg=$a ;;
      esac
      want_value=
      continue
    fi
    case "$a" in
      --plan-file) want_value=plan-file ;;
      --plan-file=*) plan_file=${a#--plan-file=} ;;
      --home) want_value=home ;;
      --home=*) home_arg=${a#--home=} ;;
      --emit) emit=1 ;;
      --*) echo "error: unknown flag $a" >&2; exit 2 ;;
      *)
        if [ -z "$secondmate_id" ]; then secondmate_id=$a
        elif [ -z "$task_id" ]; then task_id=$a
        else echo "error: unexpected argument $a" >&2; exit 2
        fi ;;
    esac
  done
  [ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
  [ -n "$secondmate_id" ] && [ -n "$task_id" ] && [ -n "$plan_file" ] || {
    echo "usage: fm-plan-approval.sh approve <secondmate-id> <task-id> --plan-file <path> [--home <path>] [--emit]" >&2
    exit 2
  }
  valid_id "$task_id" || die "invalid task id: $task_id"
  regular_file "$plan_file" || die "plan file is not an ordinary file: $plan_file"
  [ -s "$plan_file" ] || die "plan file is empty: $plan_file"

  ensure_primary_keypair
  local private public key_sha plan_sha plan_bytes stamp target home host record payload sig_raw sig_b64 tmp_record
  private=$(primary_private_key)
  public=$(primary_public_key)
  key_sha=$(sha256_file "$public") || die "could not hash the public key"
  plan_sha=$(sha256_file "$plan_file") || die "could not hash the plan file"
  plan_bytes=$(byte_count "$plan_file")
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ) || die "could not read the current time"

  if [ -n "$home_arg" ]; then
    home=$(CDPATH='' cd -- "$home_arg" 2>/dev/null && pwd -P) \
      || die "--home is not a directory: $home_arg"
    host=""
    marker_home_id_matches "$home" "$secondmate_id" \
      || die "$home is not a secondmate home marked for $secondmate_id"
  else
    target=$(resolve_secondmate_home "$secondmate_id") || exit 1
    home=${target%%|*}
    host=${target#*|}
  fi

  if [ -z "$host" ]; then
    # The approval must be the exact instructions the worker will follow, so a
    # readable brief that already disagrees means this approval could never be
    # used. Refuse now instead of minting it.
    local brief brief_sha
    brief="$home/data/$task_id/brief.md"
    if regular_file "$brief"; then
      brief_sha=$(sha256_file "$brief") || die "could not hash $brief"
      if [ "$brief_sha" != "$plan_sha" ]; then
        refuse "the approved plan must be the exact instructions the worker will follow, but $brief does not match $plan_file; approve that brief, or have the officer bring it in line with the approved plan first"
      fi
    else
      printf 'plan-approval: note: %s does not exist yet; this approval is usable only once it holds exactly the approved plan bytes\n' "$brief" >&2
    fi
  elif [ "$emit" -eq 0 ]; then
    refuse "secondmate $secondmate_id is a remote route on $host, so this home cannot write its record; re-run with --emit and place the printed bytes at $home/state/$task_id$RECORD_SUFFIX on $host"
  fi

  payload=$(mktemp "${TMPDIR:-/tmp}/fm-plan-approval-payload.XXXXXX") || die "could not stage the approval payload"
  sig_raw="$payload.sig"
  {
    printf 'v=%s\n' "$RECORD_VERSION"
    printf 'task=%s\n' "$task_id"
    printf 'secondmate=%s\n' "$secondmate_id"
    printf 'plan_sha256=%s\n' "$plan_sha"
    printf 'plan_bytes=%s\n' "$plan_bytes"
    printf 'approved_at=%s\n' "$stamp"
    printf 'key_sha256=%s\n' "$key_sha"
  } > "$payload"
  if ! openssl pkeyutl -sign -inkey "$private" -rawin -in "$payload" -out "$sig_raw" >/dev/null 2>&1; then
    rm -f "$payload" "$sig_raw"
    openssl_ed25519_works || die "$(openssl_requirement)"
    die "could not sign the approval payload with $private"
  fi
  sig_b64=$(openssl base64 -A -in "$sig_raw") || { rm -f "$payload" "$sig_raw"; die "could not encode the signature"; }
  rm -f "$sig_raw"

  if [ "$emit" -eq 1 ]; then
    cat "$payload"
    printf 'sig=%s\n' "$sig_b64"
    rm -f "$payload"
    printf 'plan-approval: emitted %s for secondmate %s; place it at %s\n' \
      "$task_id" "$secondmate_id" "$(record_path "$home" "$task_id")" >&2
    return 0
  fi

  record=$(record_path "$home" "$task_id")
  mkdir -p "$home/state" || { rm -f "$payload"; die "could not create $home/state"; }
  tmp_record=$(umask 077; mktemp "$home/state/.plan-approval.XXXXXX") || { rm -f "$payload"; die "could not stage the approval record"; }
  if ! { cat "$payload"; printf 'sig=%s\n' "$sig_b64"; } > "$tmp_record"; then
    rm -f "$payload" "$tmp_record"
    die "could not write the approval record"
  fi
  rm -f "$payload"
  if [ -e "$record" ] || [ -L "$record" ]; then
    chmod u+w "$record" 2>/dev/null || true
    rm -f "$record" 2>/dev/null || { rm -f "$tmp_record"; die "could not replace the existing approval at $record"; }
  fi
  chmod 0444 "$tmp_record" 2>/dev/null || true
  mv -f "$tmp_record" "$record" || { rm -f "$tmp_record"; die "could not publish the approval record at $record"; }
  printf 'approved %s for secondmate %s plan sha256=%s at %s\n' "$task_id" "$secondmate_id" "$plan_sha" "$stamp"
  printf 'record: %s\n' "$record"
}

cmd_verify() {
  local task_id="" plan_file="" want_value="" a
  for a in "$@"; do
    if [ -n "$want_value" ]; then
      case "$a" in --*) echo "error: --$want_value requires a value" >&2; exit 2 ;; esac
      case "$want_value" in plan-file) plan_file=$a ;; esac
      want_value=
      continue
    fi
    case "$a" in
      --plan-file) want_value=plan-file ;;
      --plan-file=*) plan_file=${a#--plan-file=} ;;
      --*) echo "error: unknown flag $a" >&2; exit 2 ;;
      *)
        if [ -z "$task_id" ]; then task_id=$a
        else echo "error: unexpected argument $a" >&2; exit 2
        fi ;;
    esac
  done
  [ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
  [ -n "$task_id" ] || { echo "usage: fm-plan-approval.sh verify <task-id> [--plan-file <path>]" >&2; exit 2; }
  valid_id "$task_id" || die "invalid task id: $task_id"
  [ -n "$plan_file" ] || plan_file="$DATA/$task_id/brief.md"

  local marker_id record trusted_key payload sig_raw plan_sha plan_bytes
  fm_root_is_secondmate_home "$FM_HOME" \
    || refuse "verify runs in the home being gated, and $FM_HOME carries no secondmate-home marker"
  # A marker without a trailing newline still yields the id, and read's non-zero
  # status there must not abort a check that already knows the file is valid.
  IFS= read -r marker_id < "$FM_HOME/.fm-secondmate-home" || true
  marker_id=${marker_id//[[:space:]]/}
  [ -n "$marker_id" ] || refuse "this home's secondmate marker is empty"

  record="$STATE/$task_id$RECORD_SUFFIX"
  regular_file "$record" \
    || refuse "no approval recorded for $task_id; submit the plan to the main firstmate and start only after it runs 'bin/fm-plan-approval.sh approve $marker_id $task_id --plan-file <plan>'"
  parse_record "$record" || refuse "the approval for $task_id is not a valid record: $RECORD_PARSE_ERROR"
  [ "$RECORD_TASK" = "$task_id" ] \
    || refuse "the approval at $record is for task $RECORD_TASK, not $task_id"
  [ "$RECORD_SECONDMATE" = "$marker_id" ] \
    || refuse "the approval for $task_id was issued to secondmate $RECORD_SECONDMATE, not this home ($marker_id)"

  resolve_trusted_public_key \
    || refuse "this home holds no plan-approval public key; the main firstmate must push its inherited local material before any implementation can start here"
  trusted_key=$TRUSTED_KEY_PATH
  local trusted_sha
  trusted_sha=$(sha256_file "$trusted_key") || refuse "could not hash the trusted public key at $trusted_key"
  [ "$RECORD_KEY_SHA" = "$trusted_sha" ] \
    || refuse "the approval for $task_id was signed with a key this home does not trust; ask the main firstmate to re-approve with its current key"

  regular_file "$plan_file" \
    || refuse "the approved plan file is missing at $plan_file, so the approval for $task_id cannot be checked against what the worker would follow"

  payload=$(mktemp "${TMPDIR:-/tmp}/fm-plan-approval-verify.XXXXXX") || die "could not stage the approval payload"
  sig_raw="$payload.sig"
  head -n 7 "$record" > "$payload"
  if ! printf '%s' "$RECORD_SIG" | openssl base64 -d -A -out "$sig_raw" >/dev/null 2>&1; then
    rm -f "$payload" "$sig_raw"
    refuse "the signature on the approval for $task_id is not decodable"
  fi
  if ! openssl pkeyutl -verify -pubin -inkey "$trusted_key" -rawin -in "$payload" -sigfile "$sig_raw" >/dev/null 2>&1; then
    rm -f "$payload" "$sig_raw"
    openssl_ed25519_works || refuse "$(openssl_requirement)"
    refuse "the approval for $task_id does not carry a valid signature from the main firstmate"
  fi
  rm -f "$payload" "$sig_raw"

  plan_bytes=$(byte_count "$plan_file")
  plan_sha=$(sha256_file "$plan_file") || refuse "could not hash $plan_file"
  if [ "$plan_bytes" != "$RECORD_PLAN_BYTES" ] || [ "$plan_sha" != "$RECORD_PLAN_SHA" ]; then
    refuse "$plan_file changed after it was approved, so the approval for $task_id no longer covers it; submit the current plan and start only after a fresh approval"
  fi
  printf 'plan-approval: %s approved %s plan sha256=%s key=%s\n' \
    "$task_id" "$RECORD_APPROVED_AT" "$RECORD_PLAN_SHA" "$TRUSTED_KEY_SOURCE"
}

# Run verify for one task inside <home>, with this home's overrides cleared so
# the child resolves that home's own state, data, and config.
verify_in_home() {  # <home> <task-id>
  local home=$1 task_id=$2
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$FM_ROOT" \
    "$SCRIPT_DIR/$(basename "$0")" verify "$task_id" 2>&1
}

resolve_scope_home() {  # <secondmate-id-or-empty> -> prints home
  local id=$1 target host
  if [ -z "$id" ]; then
    printf '%s\n' "$FM_HOME"
    return 0
  fi
  target=$(resolve_secondmate_home "$id") || return 1
  host=${target#*|}
  [ -z "$host" ] || die "secondmate $id is a remote route on $host; act on its records from that host"
  printf '%s\n' "${target%%|*}"
}

cmd_revoke() {
  local task_id="" secondmate_id="" want_value="" a home record
  for a in "$@"; do
    if [ -n "$want_value" ]; then
      case "$a" in --*) echo "error: --$want_value requires a value" >&2; exit 2 ;; esac
      case "$want_value" in secondmate) secondmate_id=$a ;; esac
      want_value=
      continue
    fi
    case "$a" in
      --secondmate) want_value=secondmate ;;
      --secondmate=*) secondmate_id=${a#--secondmate=} ;;
      --*) echo "error: unknown flag $a" >&2; exit 2 ;;
      *)
        if [ -z "$task_id" ]; then task_id=$a
        else echo "error: unexpected argument $a" >&2; exit 2
        fi ;;
    esac
  done
  [ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
  [ -n "$task_id" ] || { echo "usage: fm-plan-approval.sh revoke <task-id> [--secondmate <id>]" >&2; exit 2; }
  valid_id "$task_id" || die "invalid task id: $task_id"
  home=$(resolve_scope_home "$secondmate_id") || exit 1
  record=$(record_path "$home" "$task_id")
  if [ ! -e "$record" ] && [ ! -L "$record" ]; then
    printf 'plan-approval: no approval recorded for %s at %s\n' "$task_id" "$record"
    return 0
  fi
  chmod u+w "$record" 2>/dev/null || true
  rm -f "$record" || die "could not remove $record"
  printf 'revoked %s (%s)\n' "$task_id" "$record"
}

cmd_list() {
  local secondmate_id="" want_value="" a home record task verdict found=0
  for a in "$@"; do
    if [ -n "$want_value" ]; then
      case "$a" in --*) echo "error: --$want_value requires a value" >&2; exit 2 ;; esac
      case "$want_value" in secondmate) secondmate_id=$a ;; esac
      want_value=
      continue
    fi
    case "$a" in
      --secondmate) want_value=secondmate ;;
      --secondmate=*) secondmate_id=${a#--secondmate=} ;;
      --*) echo "error: unknown flag $a" >&2; exit 2 ;;
      *) echo "error: unexpected argument $a" >&2; exit 2 ;;
    esac
  done
  [ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 2; }
  home=$(resolve_scope_home "$secondmate_id") || exit 1
  for record in "$home"/state/*"$RECORD_SUFFIX"; do
    regular_file "$record" || continue
    found=1
    task=$(basename "$record" "$RECORD_SUFFIX")
    if parse_record "$record"; then
      if verify_in_home "$home" "$task" >/dev/null 2>&1; then
        verdict=valid
      else
        verdict=stale
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$RECORD_SECONDMATE" "$RECORD_APPROVED_AT" "$RECORD_PLAN_SHA" "$verdict"
    else
      printf '%s\t?\t?\t?\tmalformed (%s)\n' "$task" "$RECORD_PARSE_ERROR"
    fi
  done
  [ "$found" -eq 1 ] || printf 'plan-approval: no approvals recorded in %s\n' "$home"
}

COMMAND=${1:-}
[ -n "$COMMAND" ] || { usage >&2; exit 2; }
shift
case "$COMMAND" in
  init) cmd_init "$@" ;;
  pubkey) cmd_pubkey "$@" ;;
  approve) cmd_approve "$@" ;;
  verify) cmd_verify "$@" ;;
  revoke) cmd_revoke "$@" ;;
  list) cmd_list "$@" ;;
  *) printf 'error: unknown command %s\n' "$COMMAND" >&2; exit 2 ;;
esac
