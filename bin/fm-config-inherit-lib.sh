# shellcheck shell=bash
# Inheritance propagation: the PRIMARY firstmate pushes a declared, extensible
# set of LOCAL (gitignored) config items down into each secondmate home's
# config/, so a secondmate's OWN crewmates inherit the primary's settings
# (e.g. primary config/crew-dispatch.json makes a secondmate use the same dispatch
# profile rules, primary config/crew-harness=codex makes a secondmate's crewmates
# spawn on codex too, and primary config/backlog-backend=manual makes that home
# hand-edit backlog files too). It also pushes the one primary-authoritative
# shared captain-preference file, data/captain-shared.md, into each secondmate
# home's data/ as a read-only copy.
#
# Usage: . bin/fm-config-inherit-lib.sh   (no FM_* setup required)
#
# Why this is separate from the tracked-files fast-forward (fm-ff-lib.sh): config/
# is gitignored, so a tracked-files fast-forward never carries these items. This
# is an explicit copy run at the convergence points the primary owns - a
# secondmate spawn (bin/fm-spawn.sh), the bootstrap secondmate sweep
# (bin/fm-bootstrap.sh), and the focused mid-session config push
# (bin/fm-config-push.sh). It is PRIMARY-AUTHORITATIVE: the primary's value wins
# and is re-pushed on every convergence, so the fleet stays converged on the
# primary; an item the primary does not set is mirrored as absence downstream.
#
# Extensible by design: FM_INHERITABLE_CONFIG is the single declared list of
# config-dir-relative items the primary propagates. Add an item there and every
# convergence point inherits it - no other change needed. config/secondmate-harness
# is deliberately NOT in the list: it is the primary's own setting for launching
# secondmates, and a secondmate never spawns secondmates, so it must not flow
# downstream.

# The one shared data file in this inheritance contract. There is deliberately
# no shared learnings file.
FM_SHARED_CAPTAIN_FILE="captain-shared.md"
FM_SHARED_CAPTAIN_REL="data/$FM_SHARED_CAPTAIN_FILE"
FM_SHARED_CAPTAIN_MODE="444"

# The declared inheritable set (space-separated, config-dir-relative item paths).
# Extend here to inherit more of the primary's local config; override via the
# environment only in tests. Items must not contain whitespace.
FM_INHERITABLE_CONFIG="${FM_INHERITABLE_CONFIG:-crew-dispatch.json crew-harness backlog-backend}"

fm_inherit_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

fm_inherit_file_device() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

fm_inherit_file_link_count() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

fm_inherit_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

copy_inheritable_file() {
  local src=$1 dest=$2 dest_parent tmp
  if [ -e "$dest" ] && [ ! -f "$dest" ] && [ ! -L "$dest" ]; then
    return 1
  fi
  dest_parent=${dest%/*}
  [ -n "$dest_parent" ] && [ "$dest_parent" != "$dest" ] || return 1
  mkdir -p "$dest_parent" 2>/dev/null || return 1
  tmp=$(mktemp "$dest_parent/.fm-inherit.XXXXXX" 2>/dev/null) || return 1
  if ! cp "$src" "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if [ -L "$dest" ] && ! rm -f "$dest" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

destination_allows_inherited_item() {
  local dest_config=$1 item=$2 dest_parent dest_name dest_parent_abs top dest_path rel_path
  dest_parent=${dest_config%/*}
  dest_name=${dest_config##*/}
  [ -n "$dest_parent" ] && [ "$dest_parent" != "$dest_config" ] || return 1
  dest_parent_abs=$(cd "$dest_parent" 2>/dev/null && pwd -P) || return 1
  if ! git -C "$dest_parent_abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi
  top=$(git -C "$dest_parent_abs" rev-parse --show-toplevel 2>/dev/null) || return 1
  dest_path="$dest_parent_abs/$dest_name/$item"
  case "$dest_path" in
    "$top"/*) rel_path=${dest_path#"$top"/} ;;
    *) return 1 ;;
  esac
  git -C "$top" check-ignore -q -- "$rel_path" 2>/dev/null
}

# propagate_inheritable_config <src-config-dir> <dest-config-dir>
# Copy each declared inheritable item from the primary's config dir (src) into a
# secondmate home's config dir (dest). SILENT on stdout - callers parse stdout,
# so this writes nothing there. It emits concise stderr diagnostics only for
# notable events: a guard skip or a copy/remove error. A source item that is
# present is copied only when its content differs (idempotent: a re-run never
# churns mtimes). A source item that is absent is mirrored as a missing
# destination item, so clearing the primary's value clears it downstream too
# (primary-authoritative). The destination dir is created lazily, only when there
# is actually something to write, so a primary with no inherited config item set is a
# complete no-op (it leaves the secondmate home exactly as it was - the
# backward-compatible path). When FM_CONFIG_INHERIT_REPORT points at a writable
# file, one tab-separated line per item is appended there:
#   <item> <status> <reason>
# Status is pushed, unchanged, skipped, or error. Skipped items are warnings and
# do not affect the exit code. Returns non-zero only when a real propagation
# error, such as copy or remove failure, occurs.
record_inheritable_config_result() {
  local item=$1 status=$2 reason=${3:-}
  [ -n "${FM_CONFIG_INHERIT_REPORT:-}" ] || return 0
  printf '%s\t%s\t%s\n' "$item" "$status" "$reason" >> "$FM_CONFIG_INHERIT_REPORT" 2>/dev/null || true
}

inheritable_config_skip_reason() {
  printf '%s' "destination does not allow inherited item (not gitignored or guard failed)"
}

warn_inheritable_config_skip() {
  local item=$1 dest_config=$2 reason=$3
  echo "fm-config-inherit: warning: skipped $item for $dest_config: $reason" >&2
}

warn_inheritable_config_error() {
  local item=$1 dest=$2 reason=$3
  echo "fm-config-inherit: error: $reason $item at $dest" >&2
}

shared_captain_header_valid() {
  local src=$1 head
  head=$(sed -n '1,12p' "$src" 2>/dev/null) || return 1
  case "$head" in *main-authoritative*) ;; *) return 1 ;; esac
  case "$head" in *"read-only in secondmate homes"*) ;; *) return 1 ;; esac
  case "$head" in *"must not be edited there"*) ;; *) return 1 ;; esac
  case "$head" in *"main firstmate"*) ;; *) return 1 ;; esac
  case "$head" in *"marked status"*|*"document pointer"*) ;; *) return 1 ;; esac
}

shared_captain_dir_safe() {
  local dir=$1
  [ -n "$dir" ] || return 1
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  else
    mkdir -p "$dir" 2>/dev/null || return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
}

shared_captain_file_safe_existing() {
  local path=$1
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(fm_inherit_file_link_count "$path")" = 1 ]
}

restore_shared_captain_readonly() {
  local dest=$1
  [ -e "$dest" ] || [ -L "$dest" ] || return 0
  shared_captain_file_safe_existing "$dest" || return 1
  chmod "$FM_SHARED_CAPTAIN_MODE" "$dest" 2>/dev/null || return 1
}

shared_captain_quarantine_existing_for_hash() {
  local parent=$1 hash=$2 artifact artifact_hash
  for artifact in "$parent"/."$FM_SHARED_CAPTAIN_FILE".quarantine.*."$hash" "$parent"/."$FM_SHARED_CAPTAIN_FILE".quarantine.*."$hash".[0-9]*; do
    [ -e "$artifact" ] || [ -L "$artifact" ] || continue
    shared_captain_file_safe_existing "$artifact" || return 1
    artifact_hash=$(fm_inherit_sha256 "$artifact") || return 1
    [ "$artifact_hash" = "$hash" ] || continue
    printf '%s\n' "$artifact"
    return 0
  done
  return 1
}

shared_captain_quarantine_name() {
  local parent=$1 hash=$2 stamp base candidate n
  stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null) || return 1
  base="$parent/.$FM_SHARED_CAPTAIN_FILE.quarantine.$stamp.$hash"
  candidate=$base
  n=0
  while [ -e "$candidate" ] || [ -L "$candidate" ]; do
    n=$((n + 1))
    candidate="$base.$n"
  done
  printf '%s\n' "$candidate"
}

quarantine_shared_captain_dest() {
  local dest=$1 dest_parent=$2 dest_hash artifact existing
  shared_captain_file_safe_existing "$dest" || return 1
  dest_hash=$(fm_inherit_sha256 "$dest") || return 1
  if existing=$(shared_captain_quarantine_existing_for_hash "$dest_parent" "$dest_hash" 2>/dev/null); then
    chmod u+w "$dest" 2>/dev/null || return 1
    if rm -f -- "$dest" 2>/dev/null; then
      printf '%s\n' "$existing"
      return 0
    fi
    restore_shared_captain_readonly "$dest" || true
    return 1
  fi
  artifact=$(shared_captain_quarantine_name "$dest_parent" "$dest_hash") || return 1
  chmod u+w "$dest" 2>/dev/null || return 1
  if mv -- "$dest" "$artifact" 2>/dev/null; then
    chmod 0600 "$artifact" 2>/dev/null || return 1
    shared_captain_file_safe_existing "$artifact" || return 1
    printf '%s\n' "$artifact"
    return 0
  fi
  restore_shared_captain_readonly "$dest" || true
  return 1
}

copy_shared_captain_file() {
  local src=$1 dest=$2 dest_parent tmp
  dest_parent=${dest%/*}
  shared_captain_dir_safe "$dest_parent" || return 1
  tmp=$(mktemp "$dest_parent/.fm-captain-shared.XXXXXX" 2>/dev/null) || return 1
  if ! cp "$src" "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  shared_captain_file_safe_existing "$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  if mv -f -- "$tmp" "$dest" 2>/dev/null; then
    chmod "$FM_SHARED_CAPTAIN_MODE" "$dest" 2>/dev/null || return 1
    shared_captain_file_safe_existing "$dest" || return 1
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

propagate_shared_captain_preferences() {
  local src_data=$1 dest_data=$2 src dest src_hash dest_hash dest_parent dest_home quarantine reason rc
  [ -n "$src_data" ] || return 1
  [ -n "$dest_data" ] || return 1
  src="$src_data/$FM_SHARED_CAPTAIN_FILE"
  dest="$dest_data/$FM_SHARED_CAPTAIN_FILE"
  dest_parent=${dest%/*}
  dest_home=${dest_data%/data}
  rc=0

  if [ -e "$src" ] || [ -L "$src" ]; then
    if ! shared_captain_file_safe_existing "$src"; then
      reason="unsafe primary source"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$src" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      return 1
    fi
    if ! shared_captain_header_valid "$src"; then
      reason="primary source header missing required main-authoritative warning"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$src" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      return 1
    fi
    src_hash=$(fm_inherit_sha256 "$src") || {
      reason="failed to hash primary source"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$src" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      return 1
    }
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if ! shared_captain_file_safe_existing "$dest"; then
        reason="unsafe destination"
        warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest" "$reason"
        record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
        return 1
      fi
      dest_hash=$(fm_inherit_sha256 "$dest") || {
        reason="failed to hash destination"
        warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest" "$reason"
        record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
        restore_shared_captain_readonly "$dest" || true
        return 1
      }
      if [ "$src_hash" = "$dest_hash" ]; then
        if restore_shared_captain_readonly "$dest"; then
          record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" unchanged ""
          return 0
        fi
        reason="failed to restore read-only mode"
        warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest" "$reason"
        record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
        return 1
      fi
      if ! shared_captain_dir_safe "$dest_parent"; then
        reason="unsafe destination directory"
        warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest_parent" "$reason"
        record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
        restore_shared_captain_readonly "$dest" || true
        return 1
      fi
      if ! quarantine=$(quarantine_shared_captain_dest "$dest" "$dest_parent"); then
        reason="failed to quarantine divergent destination"
        warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest" "$reason"
        record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
        restore_shared_captain_readonly "$dest" || true
        return 1
      fi
      printf 'SECONDMATE_SYNC: secondmate home %s: quarantined %s drift at %s\n' "$dest_home" "$FM_SHARED_CAPTAIN_REL" "$quarantine"
    elif ! shared_captain_dir_safe "$dest_parent"; then
      reason="unsafe destination directory"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest_parent" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      return 1
    fi
    if copy_shared_captain_file "$src" "$dest"; then
      if [ -n "${quarantine:-}" ]; then
        record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" pushed "quarantined local drift at $quarantine"
      else
        record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" pushed ""
      fi
    else
      reason="failed to copy"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      rc=1
    fi
  elif [ -e "$dest" ] || [ -L "$dest" ]; then
    if ! shared_captain_file_safe_existing "$dest"; then
      reason="unsafe destination"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      return 1
    fi
    if ! shared_captain_dir_safe "$dest_parent"; then
      reason="unsafe destination directory"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest_parent" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      restore_shared_captain_readonly "$dest" || true
      return 1
    fi
    if quarantine=$(quarantine_shared_captain_dest "$dest" "$dest_parent"); then
      printf 'SECONDMATE_SYNC: secondmate home %s: quarantined %s drift at %s\n' "$dest_home" "$FM_SHARED_CAPTAIN_REL" "$quarantine"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" pushed "mirrored primary absence after quarantining local copy at $quarantine"
    else
      reason="failed to quarantine destination before mirroring primary absence"
      warn_inheritable_config_error "$FM_SHARED_CAPTAIN_REL" "$dest" "$reason"
      record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" error "$reason"
      restore_shared_captain_readonly "$dest" || true
      rc=1
    fi
  else
    record_inheritable_config_result "$FM_SHARED_CAPTAIN_REL" unchanged ""
  fi
  return "$rc"
}

propagate_secondmate_inheritance() {
  local src_home=$1 dest_home=$2 src_config=${3:-} src_data=${4:-} rc
  [ -n "$src_home" ] || return 1
  [ -n "$dest_home" ] || return 1
  [ -n "$src_config" ] || src_config="$src_home/config"
  [ -n "$src_data" ] || src_data="$src_home/data"
  rc=0
  propagate_inheritable_config "$src_config" "$dest_home/config" || rc=1
  propagate_shared_captain_preferences "$src_data" "$dest_home/data" || rc=1
  return "$rc"
}

propagate_inheritable_config() {
  local src_config=$1 dest_config=$2 item src dest reason rc
  [ -n "$src_config" ] || return 1
  [ -n "$dest_config" ] || return 1
  rc=0
  for item in $FM_INHERITABLE_CONFIG; do
    case "$item" in
      ''|/*|.|..|../*|*/../*|*/..) return 1 ;;
    esac
    src="$src_config/$item"
    dest="$dest_config/$item"
    if [ -f "$src" ]; then
      if ! destination_allows_inherited_item "$dest_config" "$item"; then
        reason=$(inheritable_config_skip_reason)
        warn_inheritable_config_skip "$item" "$dest_config" "$reason"
        record_inheritable_config_result "$item" skipped "$reason"
        continue
      fi
      if [ -L "$dest" ] || [ ! -f "$dest" ] || ! cmp -s "$src" "$dest"; then
        if copy_inheritable_file "$src" "$dest"; then
          record_inheritable_config_result "$item" pushed ""
        else
          reason="failed to copy"
          warn_inheritable_config_error "$item" "$dest" "$reason"
          record_inheritable_config_result "$item" error "$reason"
          rc=1
        fi
      else
        record_inheritable_config_result "$item" unchanged ""
      fi
    elif [ -e "$dest" ] || [ -L "$dest" ]; then
      if ! destination_allows_inherited_item "$dest_config" "$item"; then
        reason=$(inheritable_config_skip_reason)
        warn_inheritable_config_skip "$item" "$dest_config" "$reason"
        record_inheritable_config_result "$item" skipped "$reason"
        continue
      fi
      # Primary has no value for this item: mirror the absence downstream.
      if rm -f "$dest" 2>/dev/null; then
        record_inheritable_config_result "$item" pushed "mirrored primary absence"
      else
        reason="failed to remove"
        warn_inheritable_config_error "$item" "$dest" "$reason"
        record_inheritable_config_result "$item" error "$reason"
        rc=1
      fi
    else
      record_inheritable_config_result "$item" unchanged ""
    fi
  done
  return "$rc"
}
