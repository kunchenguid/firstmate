#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote secondmate route.
# Usage: fm-remote-inherit-push.sh <secondmate-id> <generation>
#
# The item set is fm_config_inherit_remote_items from the ONE declared owner
# (bin/fm-config-inherit-lib.sh), the same declaration the receiving
# bin/fm-remote-inherit.sh enforces, so the two implementations in one code
# revision cannot drift silently; machine-local items are never offered to
# another machine. When the remote code root is older and refuses an item with
# the receiver's cross-revision refusal line, that item is reported on stderr as
# a skipped-item warning and the push continues, because that refusal happens
# before the receiver reads, locks, or writes anything. Every other failure
# stops the push with the remote's stderr and exit status unchanged, including
# exit 255 for unknown completion. FM_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}
file_link_count() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %l "$1" 2>/dev/null; else stat -c %h "$1" 2>/dev/null; fi
}
shared_captain_header_valid() {
  local head
  head=$(sed -n '1,12p' "$1" 2>/dev/null) || return 1
  case "$head" in *main-authoritative*) ;; *) return 1 ;; esac
  case "$head" in *"read-only in secondmate homes"*) ;; *) return 1 ;; esac
  case "$head" in *"must not be edited there"*) ;; *) return 1 ;; esac
  case "$head" in *"main firstmate"*) ;; *) return 1 ;; esac
  case "$head" in *"marked status"*|*"document pointer"*) ;; *) return 1 ;; esac
}
[ "$#" -eq 2 ] || { echo "usage: fm-remote-inherit-push.sh <secondmate-id> <generation>" >&2; exit 2; }
ID=$1
GENERATION=$2
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac
case "$GENERATION" in ''|*[!0-9]*) die "generation must be a positive integer" ;; esac
[ "${#GENERATION}" -le 18 ] && [ "$GENERATION" -ge 1 ] || die "generation is outside the supported range"
REMOTE=$(secondmate_registry_field "$DATA/secondmates.md" "$ID" remote 2>/dev/null || true)
[ "$REMOTE" = 1 ] || die "secondmate $ID is not a remote route"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-inherit-push.XXXXXX") || die "cannot create inheritance staging directory"
trap 'rm -rf -- "$TMP"' EXIT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"
REMOTE_ERR="$TMP/remote.stderr"

# Apply one item on the remote host, classifying only the receiver's
# cross-revision refusal of <rel> as version skew (see the header).
remote_apply() {  # <rel> <stdin-path> <fm-on.sh arguments...>
  local rel=$1 input=$2 rc=0
  shift 2
  "$SCRIPT_DIR/fm-on.sh" "$@" < "$input" 2> "$REMOTE_ERR" || rc=$?
  if [ "$rc" -eq 1 ] && grep -Fxq -- "error: path is not inherited material: $rel" "$REMOTE_ERR"; then
    printf '%s\n' "fm-remote-inherit-push: warning: skipped $rel for remote secondmate $ID: the Firstmate code root on that host predates it and does not declare it inherited material, so nothing was written; updating Firstmate on that host converges it" >&2
    return 0
  fi
  cat -- "$REMOTE_ERR" >&2
  [ "$rc" -eq 0 ] || exit "$rc"
}

ITEMS=$(fm_config_inherit_remote_items)
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if [ "${FM_CONFIG_INHERIT_LIVE:-0}" = 1 ]; then
    case "$rel" in
      config/*)
        if fm_config_inherit_item_session_scoped "${rel#config/}"; then
          printf 'unchanged: %s\n' "$rel"
          continue
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  source_present=$(fm_config_source_present "$source") || exit 1
  if [ "$source_present" = 1 ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || die "inherited source is unsafe: $source"
    [ "$(file_link_count "$source")" = 1 ] || die "inherited source is hardlinked: $source"
    if [ "$rel" = data/captain-shared.md ]; then
      shared_captain_header_valid "$source" || die "shared captain preferences have no valid primary-authoritative header"
    fi
    snapshot="$TMP/$(printf '%s' "$rel" | tr '/' '_')"
    cp -p -- "$source" "$snapshot" || die "cannot snapshot inherited source: $source"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || die "inherited source snapshot is unsafe: $source"
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
    hash=$(sha256_file "$snapshot") || die "cannot hash inherited source: $source"
    remote_apply "$rel" "$snapshot" --stdin "$ID" fm-remote-inherit.sh put "$rel" "$bytes" "$hash" "$GENERATION"
  else
    # This loop's heredoc is its control stream, not remote command input.
    remote_apply "$rel" /dev/null "$ID" fm-remote-inherit.sh absent "$rel" 0 "$EMPTY_HASH" "$GENERATION"
  fi
done <<EOF
$ITEMS
EOF
