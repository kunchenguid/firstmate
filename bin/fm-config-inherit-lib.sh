# shellcheck shell=bash
# Inheritable-config propagation: the PRIMARY firstmate pushes a declared,
# extensible set of LOCAL (gitignored) config items down into each secondmate
# home's config/, so a secondmate's OWN crewmates inherit the primary's settings
# (e.g. primary config/crew-dispatch.json makes a secondmate use the same dispatch
# profile rules, primary config/crew-harness=codex makes a secondmate's crewmates
# spawn on codex too, and primary config/backlog-backend=manual makes that home
# hand-edit backlog files too).
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

# The declared inheritable set (space-separated, config-dir-relative item paths).
# Extend here to inherit more of the primary's local config; override via the
# environment only in tests. Items must not contain whitespace.
FM_INHERITABLE_CONFIG="${FM_INHERITABLE_CONFIG:-crew-dispatch.json crew-harness backlog-backend}"

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
# is actually something to write, so a primary with no inheritable config set is a
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
