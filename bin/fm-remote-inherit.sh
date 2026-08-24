#!/usr/bin/env bash
# Apply one primary-authoritative inherited item inside the selected remote home.
#
# Usage:
#   fm-remote-inherit.sh put <allowlisted-relative-path> <bytes> <sha256> <generation> < stdin
#   fm-remote-inherit.sh absent <allowlisted-relative-path> 0 <empty-sha256> <generation>
#
# Only the inherited-material allowlist is writable or removable. Writes are
# atomic ordinary-file replacements. Divergent data/captain-shared.md bytes are
# quarantined before replacement or removal and its converged copy is read-only.
# A config item this home holds under an evidence-backed deviation record is left
# at the home's own value and reported as "deviation: <path> ..." instead.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_BYTES=1048576
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
# Writable set, derived from the ONE declared inherited-material owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), so this code root's
# receiver and sender cannot drift silently. This runs under the remote
# entrypoint's fixed empty environment, so the declaration is this code root's
# own, never something the caller can widen over SSH; a caller from a different
# revision must match it or the transfer fails closed.
allowed() {
  local candidate
  while IFS= read -r candidate; do
    [ "$candidate" = "$1" ] && return 0
  done <<EOF
$(fm_config_inherit_items)
EOF
  return 1
}

[ "$#" -eq 5 ] || usage
COMMAND=$1
REL=$2
EXPECTED_BYTES=$3
EXPECTED_HASH=$4
GENERATION=$5
allowed "$REL" || die "path is not inherited material: $REL"
case "$EXPECTED_BYTES" in ''|*[!0-9]*) die "expected bytes must be a nonnegative integer" ;; esac
[ "${#EXPECTED_BYTES}" -le 10 ] || die "expected bytes exceed the byte bound"
[ "$EXPECTED_BYTES" -le "$MAX_BYTES" ] || die "expected bytes exceed the byte bound"
case "$EXPECTED_HASH" in ''|*[!A-Fa-f0-9]*) die "expected SHA-256 is invalid" ;; esac
[ "${#EXPECTED_HASH}" -eq 64 ] || die "expected SHA-256 has the wrong length"
EXPECTED_HASH=$(printf '%s' "$EXPECTED_HASH" | tr 'A-F' 'a-f')
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
HOME_REAL=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
PARENT="$HOME_REAL/$(dirname "$REL")"
# The captain accepts this config/data parent TOCTOU within Firstmate's single-user trust boundary.
[ ! -L "$PARENT" ] || die "inherited destination parent is a symlink"
mkdir -p "$PARENT" || die "cannot create inherited destination parent"
PARENT_REAL=$(CDPATH='' cd -- "$PARENT" && pwd -P)
case "$PARENT_REAL" in "$HOME_REAL/config"|"$HOME_REAL/data") ;; *) die "inherited destination escapes FM_HOME" ;; esac
DEST="$PARENT_REAL/$(basename "$REL")"

BASE=$(basename "$REL")
LOCK="$PARENT_REAL/.fm-inherit-$BASE.lock"
GENERATION_FILE="$PARENT_REAL/.fm-inherit-$BASE.generation"
fm_lock_acquire_wait "$LOCK" || die "cannot lock inherited destination"
TMP=
GENERATION_TMP=
GENERATION_ALREADY_COMMITTED=0
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  [ -z "$GENERATION_TMP" ] || rm -f -- "$GENERATION_TMP"
  fm_lock_release "$LOCK" || true
}
trap cleanup EXIT

validate_generation() {
  local existing_generation existing_bytes existing_hash existing_command
  if [ -e "$GENERATION_FILE" ] || [ -L "$GENERATION_FILE" ]; then
    [ -f "$GENERATION_FILE" ] && [ ! -L "$GENERATION_FILE" ] || die "inheritance generation record is unsafe"
    {
      IFS= read -r existing_generation \
        && IFS= read -r existing_bytes \
        && IFS= read -r existing_hash \
        && IFS= read -r existing_command \
        && ! IFS= read -r
    } < "$GENERATION_FILE" || die "inheritance generation record is malformed"
    case "$existing_generation" in ''|*[!0-9]*) die "inheritance generation record is malformed" ;; esac
    [ "${#existing_generation}" -le 18 ] || die "inheritance generation record is malformed"
    case "$existing_bytes" in ''|*[!0-9]*) die "inheritance generation record is malformed" ;; esac
    case "$existing_hash" in ''|*[!A-Fa-f0-9]*) die "inheritance generation record is malformed" ;; esac
    [ "${#existing_hash}" -eq 64 ] || die "inheritance generation record is malformed"
    case "$existing_command" in put|absent) ;; *) die "inheritance generation record is malformed" ;; esac
    if [ "$existing_generation" -gt "$GENERATION" ]; then
      die "inheritance write generation is superseded"
    fi
    if [ "$existing_generation" -eq "$GENERATION" ]; then
      [ "$existing_bytes" = "$EXPECTED_BYTES" ] \
        && [ "$existing_hash" = "$EXPECTED_HASH" ] \
        && [ "$existing_command" = "$COMMAND" ] \
        || die "inheritance generation conflicts with its committed payload"
      GENERATION_ALREADY_COMMITTED=1
      return 0
    fi
  fi
}

commit_generation() {
  [ "$GENERATION_ALREADY_COMMITTED" -eq 0 ] || return 0
  GENERATION_TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit-generation.XXXXXX") \
    || die "cannot stage inheritance generation"
  printf '%s\n%s\n%s\n%s\n' "$GENERATION" "$EXPECTED_BYTES" "$EXPECTED_HASH" "$COMMAND" > "$GENERATION_TMP" \
    || die "cannot write inheritance generation"
  chmod 600 "$GENERATION_TMP" || die "cannot secure inheritance generation"
  mv -f -- "$GENERATION_TMP" "$GENERATION_FILE" || die "cannot publish inheritance generation"
  GENERATION_TMP=
}

# The destination home's OWN deviation record keeps a deviable config item at
# this home's value. Reported on stdout, where the pushing primary already reads
# pushed/removed/unchanged, so a remote divergence is as visible as a local one
# (bin/fm-config-inherit-lib.sh owns the record contract).
DEVIATION_REJECTED=0
deviation_holds() {
  local primary=$1 item answer rc rejection
  case "$REL" in
    config/*) item=${REL#config/} ;;
    *) return 1 ;;
  esac
  answer=$(fm_config_deviation_evidence "$PARENT_REAL" "$item") && rc=0 || rc=$?
  if [ "$rc" -eq 0 ] && rejection=$(fm_config_deviation_value_rejection "$DEST"); then
    answer=$rejection
    rc=2
  fi
  case "$rc" in
    0)
      printf 'deviation: %s held locally at %s against primary %s: %s\n' \
        "$REL" "$(fm_config_deviation_display "$DEST")" \
        "$(fm_config_deviation_display "$primary")" "$answer"
      return 0
      ;;
    2)
      printf 'deviation-rejected: %s deviation record rejected (%s); converging to the primary value\n' \
        "$REL" "$answer"
      DEVIATION_REJECTED=1
      ;;
  esac
  return 1
}

# Preserve the receiver's ordinary refusal for unsafe inherited destinations.
# A rejected deviation is the narrow exception: it has already been named to
# the primary and must now converge through the same replacement boundary as a
# safe ordinary file. An empty directory can be removed without discarding
# data; a nonempty directory still fails closed after the named rejection.
refuse_unsafe_destination() {
  local rejection
  rejection=$(fm_config_deviation_value_rejection "$DEST") || return 0
  case "$rejection" in
    "held value is a symlink") die "inherited destination is a symlink" ;;
    "held value is not an ordinary file") die "inherited destination is not a regular file" ;;
    *) die "inherited destination is hardlinked" ;;
  esac
}

prepare_rejected_deviation_destination() {
  if [ -d "$DEST" ] && [ ! -L "$DEST" ]; then
    rmdir -- "$DEST" || die "cannot replace rejected deviation destination"
  fi
}

quarantine_shared() {
  local reason=$1 quarantine stamp base n=0
  [ "$REL" = data/captain-shared.md ] && [ -f "$DEST" ] || return 0
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  base="$HOME_REAL/data/captain-shared.md.remote-quarantine-$stamp-$$"
  quarantine=$base
  while [ -e "$quarantine" ] || [ -L "$quarantine" ]; do
    n=$((n + 1))
    quarantine="$base.$n"
  done
  cp -p -- "$DEST" "$quarantine" || die "cannot quarantine divergent shared captain preferences"
  chmod 600 "$quarantine" || die "cannot secure shared-preference quarantine"
  printf 'quarantined: %s (%s)\n' "${quarantine#"$HOME_REAL/"}" "$reason" >&2
}

case "$COMMAND" in
  put)
    TMP=$(umask 077; mktemp "$PARENT_REAL/.inherit.XXXXXX") || die "cannot stage inherited material"
    head -c "$((MAX_BYTES + 1))" > "$TMP" || die "cannot read inherited material"
    BYTES=$(LC_ALL=C wc -c < "$TMP" | tr -d ' ')
    [ "$BYTES" -le "$MAX_BYTES" ] || die "inherited material exceeds the byte bound"
    [ "$BYTES" -eq "$EXPECTED_BYTES" ] || die "inherited material length does not match its commitment"
    ACTUAL_HASH=$(sha256_file "$TMP") || die "cannot hash inherited material"
    [ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || die "inherited material digest does not match its commitment"
    validate_generation
    DESTINATION_UNSAFE=0
    if fm_config_deviation_value_rejection "$DEST" >/dev/null; then
      DESTINATION_UNSAFE=1
      deviation_holds "$TMP" && exit 0
      [ "$DEVIATION_REJECTED" -eq 1 ] || refuse_unsafe_destination
    fi
    if [ "$DESTINATION_UNSAFE" -eq 1 ]; then
      prepare_rejected_deviation_destination
    fi
    if [ "$DESTINATION_UNSAFE" -eq 0 ] && [ -f "$DEST" ] && cmp -s "$TMP" "$DEST"; then
      [ "$REL" != data/captain-shared.md ] || chmod 444 "$DEST"
      commit_generation
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    if [ "$DEVIATION_REJECTED" -eq 0 ] && deviation_holds "$TMP"; then
      commit_generation
      exit 0
    fi
    quarantine_shared replaced
    chmod 600 "$TMP" || die "cannot secure inherited material"
    mv -f -- "$TMP" "$DEST" || die "cannot publish inherited material"
    TMP=
    [ "$REL" != data/captain-shared.md ] || chmod 444 "$DEST"
    commit_generation
    printf 'pushed: %s\n' "$REL"
    ;;
  absent)
    [ "$EXPECTED_BYTES" -eq 0 ] || die "absent inheritance has a nonzero payload commitment"
    EMPTY=$(umask 077; mktemp "$PARENT_REAL/.inherit-empty.XXXXXX") || die "cannot stage empty inheritance commitment"
    : > "$EMPTY"
    EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"
    rm -f -- "$EMPTY"
    [ "$EMPTY_HASH" = "$EXPECTED_HASH" ] || die "absent inheritance digest is not the empty payload"
    validate_generation
    DESTINATION_UNSAFE=0
    if fm_config_deviation_value_rejection "$DEST" >/dev/null; then
      DESTINATION_UNSAFE=1
      deviation_holds "$EMPTY" && exit 0
      [ "$DEVIATION_REJECTED" -eq 1 ] || refuse_unsafe_destination
    fi
    if [ "$DESTINATION_UNSAFE" -eq 1 ]; then
      prepare_rejected_deviation_destination
    fi
    if [ "$DESTINATION_UNSAFE" -eq 0 ] && [ ! -e "$DEST" ] && [ ! -L "$DEST" ]; then
      commit_generation
      printf 'unchanged: %s\n' "$REL"
      exit 0
    fi
    if [ "$DEVIATION_REJECTED" -eq 0 ] && deviation_holds "$EMPTY"; then
      commit_generation
      exit 0
    fi
    quarantine_shared removed
    rm -f -- "$DEST" || die "cannot remove absent inherited material"
    commit_generation
    printf 'removed: %s\n' "$REL"
    ;;
  *) usage ;;
esac
