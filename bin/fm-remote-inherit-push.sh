#!/usr/bin/env bash
# Push the declared inherited-material allowlist to one remote secondmate route.
# Usage: fm-remote-inherit-push.sh <secondmate-id> <generation>
#
# The item set is derived from the ONE declared owner
# (FM_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh), the same declaration
# the receiving bin/fm-remote-inherit.sh enforces, so the two implementations in
# one code revision cannot drift silently. Different local and remote revisions
# fail closed as documented by that owner. FM_CONFIG_INHERIT_LIVE=1 marks a live
# convergence push into an already-running home and skips session-scoped items,
# exactly as the local propagation path does. Every item is validated and
# snapshotted locally before any is sent; the sends then overlap up to
# FM_REMOTE_INHERIT_PUSH_JOBS (default 4, 1 for strictly one at a time), and
# their output is replayed in allowlist order.
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
trap 'exit 143' TERM
trap 'exit 130' INT
EMPTY="$TMP/empty"
: > "$EMPTY"
EMPTY_HASH=$(sha256_file "$EMPTY") || die "cannot hash empty inheritance payload"

ITEMS=$(fm_config_inherit_items)
# Phase 1 is local: every item is classified, validated, and snapshotted in
# allowlist order before anything is sent, so a refusal here leaves the remote
# home untouched. PLAN holds one record per item: skip, put, or absent.
N=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  N=$((N + 1))
  printf '%s\n' "$rel" > "$TMP/item.$N.rel"
  if [ "${FM_CONFIG_INHERIT_LIVE:-0}" = 1 ]; then
    case "$rel" in
      config/*)
        if fm_config_inherit_item_session_scoped "${rel#config/}"; then
          printf 'skip\n' > "$TMP/item.$N.plan"
          continue
        fi
        ;;
    esac
  fi
  case "$rel" in
    config/firstmate-role)
      source="$TMP/firstmate-role.resolved"
      fm_role_inherit_payload "$FM_HOME" "$CONFIG" "$source" || die "cannot resolve the primary role"
      ;;
    config/*) source="$CONFIG/${rel#config/}" ;;
    data/*) source="$DATA/${rel#data/}" ;;
  esac
  source_present=$(fm_config_source_present "$source") || exit 1
  if [ "$source_present" = 1 ]; then
    [ -f "$source" ] && [ ! -L "$source" ] || die "inherited source is unsafe: $source"
    [ "$(file_link_count "$source")" = 1 ] || die "inherited source is hardlinked: $source"
    if [ "$rel" = data/captain-shared.md ]; then
      if ! missing=$(shared_captain_header_valid "$source"); then
        reason="shared captain preferences have no valid primary-authoritative header"
        [ -z "$missing" ] || reason="$reason: missing \"$missing\""
        die "$reason"
      fi
    fi
    snapshot="$TMP/item.$N.snapshot"
    cp -p -- "$source" "$snapshot" || die "cannot snapshot inherited source: $source"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || die "inherited source snapshot is unsafe: $source"
    bytes=$(LC_ALL=C wc -c < "$snapshot" | tr -d ' ')
    hash=$(sha256_file "$snapshot") || die "cannot hash inherited source: $source"
    printf 'put %s %s\n' "$bytes" "$hash" > "$TMP/item.$N.plan"
  else
    printf 'absent\n' > "$TMP/item.$N.plan"
  fi
done <<EOF
$ITEMS
EOF

# Phase 2 sends each item as its own remote command, up to JOBS at a time. Every
# item is a separate file with its own generation record on the receiver, and
# the remote job worker still runs one home's commands one after another, so
# concurrency overlaps only the transport round trips. Once any item has
# failed, no further item is started; items already in flight finish.
JOBS=${FM_REMOTE_INHERIT_PUSH_JOBS:-4}
case "$JOBS" in ''|*[!0-9]*|0) JOBS=1 ;; esac
[ "$JOBS" -le 16 ] || JOBS=16

send_item() {  # <n>
  local n=$1 rel plan bytes hash rc=0
  rel=$(cat "$TMP/item.$n.rel")
  read -r plan bytes hash < "$TMP/item.$n.plan"
  if [ "$plan" = put ]; then
    "$SCRIPT_DIR/fm-on.sh" --stdin "$ID" fm-remote-inherit.sh put "$rel" "$bytes" "$hash" "$GENERATION" \
      < "$TMP/item.$n.snapshot" > "$TMP/item.$n.out" 2> "$TMP/item.$n.err" || rc=$?
  else
    "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-inherit.sh absent "$rel" 0 "$EMPTY_HASH" "$GENERATION" \
      < /dev/null > "$TMP/item.$n.out" 2> "$TMP/item.$n.err" || rc=$?
    if [ "$rc" = 1 ] && grep -Fxq -- "error: path is not inherited material: $rel" "$TMP/item.$n.err"; then
      printf 'unchanged: %s\n' "$rel" > "$TMP/item.$n.out"
      : > "$TMP/item.$n.err"
      rc=0
    fi
  fi
  printf '%s\n' "$rc" > "$TMP/item.$n.rc.tmp" && mv -f "$TMP/item.$n.rc.tmp" "$TMP/item.$n.rc"
}

item_failed() {  # <n>: 0 when the item finished with a non-zero status
  local rc=
  [ -f "$TMP/item.$1.rc" ] || return 1
  read -r rc < "$TMP/item.$1.rc" || true
  [ "$rc" != 0 ]
}

running=0
next=1
launched=0
stop=0
while [ "$next" -le "$N" ] || [ "$running" -gt 0 ]; do
  running=0
  i=1
  while [ "$i" -le "$launched" ]; do
    if [ -f "$TMP/item.$i.started" ] && [ ! -f "$TMP/item.$i.rc" ]; then
      running=$((running + 1))
    elif item_failed "$i"; then
      stop=1
    fi
    i=$((i + 1))
  done
  if [ "$stop" -eq 0 ] && [ "$next" -le "$N" ] && [ "$running" -lt "$JOBS" ]; then
    launched=$next
    if [ "$(cut -d' ' -f1 "$TMP/item.$next.plan")" = skip ]; then
      printf '0\n' > "$TMP/item.$next.rc"
    else
      : > "$TMP/item.$next.started"
      send_item "$next" &
    fi
    next=$((next + 1))
    continue
  fi
  [ "$running" -gt 0 ] || break
  sleep 0.05
done
wait

# Replay in allowlist order, so the output reads exactly as one sequential push
# would: each sent item's own stdout and stderr, and a session-scoped item's
# unchanged line.
status=0
i=1
while [ "$i" -le "$launched" ]; do
  if [ "$(cut -d' ' -f1 "$TMP/item.$i.plan")" = skip ]; then
    printf 'unchanged: %s\n' "$(cat "$TMP/item.$i.rel")"
  else
    cat "$TMP/item.$i.out"
    cat "$TMP/item.$i.err" >&2
    if item_failed "$i"; then
      item_rc=$(cat "$TMP/item.$i.rc")
      if [ "$status" -eq 0 ] || [ "$item_rc" -eq 255 ]; then status=$item_rc; fi
    fi
  fi
  i=$((i + 1))
done
exit "$status"
