#!/usr/bin/env bash
# fm-config-inherit-apply.sh - apply a STAGED inheritance surface to one of THIS
# machine's secondmate homes, and report that home's converged digest.
#
# Usage:
#   fm-config-inherit-apply.sh <id>                 print the home's current digest
#   fm-config-inherit-apply.sh <id> --from <dir>    apply <dir>, then print the digest
#   fm-config-inherit-apply.sh --manifest           print this build's declared item set
#
# Why this exists: a secondmate home on ANOTHER machine cannot be converged by
# the ordinary `cp` in bin/fm-config-inherit-lib.sh, because the primary's
# config/ and data/captain-shared.md are not on that filesystem. The control
# machine therefore stages those bytes into the peer's exchange area and the
# peer runs THIS script against them, so every guard the local path applies -
# the seeded-home check, the gitignore guard, the shared-captain header check,
# the quarantine of divergent secondmate bytes, and the read-only destination
# mode - is applied by the same library, on the machine that owns the home.
# Nothing about the inheritance contract is reimplemented across the link
# (docs/relay-host.md, the secondmate-provisioning skill).
#
# <dir> is a SOURCE-HOME SKELETON, not a diff:
#   <dir>/manifest              the sender's declared item set, one per line
#   <dir>/config/<item>         present only for items the sender actually has
#   <dir>/data/captain-shared.md   present only when the sender has it
# An item absent from the skeleton is the sender declaring it has no value for
# it, and propagate_inheritable_config mirrors that absence downstream, exactly
# as a local push does. That is why the manifest is compared FIRST and a
# mismatch refuses: a sender whose declared set differs from this build's would
# otherwise silently delete an item this machine inherits but the sender has
# never heard of.
#
# The digest is fm_config_inherit_surface_digest over the destination home, so
# the caller can skip the whole transfer when the two sides already agree.
#
# Exit 0 on a clean apply (warnings included), non-zero on a real failure.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
}

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  --manifest) fm_config_inherit_declared_manifest; exit 0 ;;
esac

ID=$1
shift
case "$ID" in
  ''|*[!A-Za-z0-9._-]*|.*) die "invalid secondmate id" ;;
esac

FROM=
while [ $# -gt 0 ]; do
  case "$1" in
    --from) shift; FROM=${1:-} ;;
    --from=*) FROM=${1#--from=} ;;
    *) die "unexpected argument '$1'" ;;
  esac
  shift || true
done

# Resolve this machine's own home for the secondmate, from its runtime record
# first and the registry second - the same order every other secondmate reader
# uses, so a home that moved is followed rather than guessed.
HOME_PATH=
if [ -f "$STATE/$ID.meta" ]; then
  HOME_PATH=$(grep '^home=' "$STATE/$ID.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
fi
[ -n "$HOME_PATH" ] || HOME_PATH=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" home || true)
[ -n "$HOME_PATH" ] || die "no home recorded for secondmate $ID on this machine"
validate_secondmate_home "$ID" "$HOME_PATH" || die "unsafe secondmate home $HOME_PATH: $VALIDATION_ERROR"
HOME_REAL="$VALIDATED_HOME"

emit_digest() {
  local digest
  digest=$(fm_config_inherit_surface_digest "$HOME_REAL/config" "$HOME_REAL/data") \
    || die "cannot digest the inheritance surface of $HOME_REAL"
  printf 'home=%s\n' "$HOME_REAL"
  printf 'digest=%s\n' "$digest"
}

if [ -z "$FROM" ]; then
  emit_digest
  exit 0
fi

[ -d "$FROM" ] || die "no staged inheritance surface at $FROM"
[ -f "$FROM/manifest" ] || die "staged inheritance surface at $FROM has no manifest"
# Fail closed on a declaration mismatch. This is the version-skew answer: a peer
# running an older or newer build refuses the push and says so, instead of
# applying a partial set and reporting success.
if ! printf '%s\n' "$(fm_config_inherit_declared_manifest)" \
  | diff -q - "$FROM/manifest" >/dev/null 2>&1; then
  echo "error: the staged inheritance manifest does not match this build's declared item set" >&2
  echo "       this machine declares:" >&2
  fm_config_inherit_declared_manifest | sed 's/^/         /' >&2
  echo "       the sender staged:" >&2
  sed 's/^/         /' "$FROM/manifest" >&2
  exit 1
fi

mkdir -p "$HOME_REAL/state" || die "could not create $HOME_REAL/state"
LOCK=$(fm_config_inherit_lock_path "$HOME_REAL") || die "could not resolve the inheritance lock for $HOME_REAL"
fm_lock_acquire_wait "$LOCK" || die "could not acquire the inheritance lock for $HOME_REAL"
RC=0
REPORT=$(mktemp "${TMPDIR:-/tmp}/fm-inherit-apply.XXXXXX" 2>/dev/null) || {
  fm_lock_release "$LOCK" || true
  die "could not create a propagation report"
}

if ! FM_CONFIG_INHERIT_REPORT="$REPORT" \
  propagate_secondmate_inheritance "$FROM" "$HOME_REAL" "$FROM/config" "$FROM/data"; then
  RC=1
fi
while IFS=$'\t' read -r item status reason; do
  [ -n "$item" ] || continue
  if [ -n "$reason" ]; then
    printf 'item %s %s (%s)\n' "$item" "$status" "$reason"
  else
    printf 'item %s %s\n' "$item" "$status"
  fi
done < "$REPORT"

# The live agent in that home keeps applying the old values until it re-reads
# them, so the same reread contract the local push follows applies here, run by
# the machine the agent is actually on.
if reread_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
  fm_config_send_reread_nudge "$ID" "$HOME_REAL" "$REPORT" 2>&1); then
  [ -z "$reread_out" ] || printf '%s\n' "$reread_out"
else
  RC=1
  if [ -n "$reread_out" ]; then
    printf '%s\n' "$reread_out"
  else
    printf 'CONFIG_REREAD: secondmate %s: send failed: unknown error\n' "$ID"
  fi
fi
rm -f "$REPORT"
fm_lock_release "$LOCK" || true

emit_digest
exit "$RC"
