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
# is an explicit copy run at the two convergence points the primary owns - a
# secondmate spawn (bin/fm-spawn.sh) and the bootstrap secondmate sweep
# (bin/fm-bootstrap.sh). It is PRIMARY-AUTHORITATIVE: the primary's value wins and
# is re-pushed on every convergence, so the fleet stays converged on the primary;
# an item the primary does not set is mirrored as absence downstream.
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
# secondmate home's config dir (dest). SILENT on success - callers parse stdout,
# so this writes nothing there. A source item that is present is copied only when
# its content differs (idempotent: a re-run never churns mtimes). A source item
# that is absent is mirrored as a missing destination item, so clearing the
# primary's value clears it downstream too (primary-authoritative). The
# destination dir is created lazily, only when there is actually something to
# write, so a primary with no inheritable config set is a complete no-op (it
# leaves the secondmate home exactly as it was - the backward-compatible path).
# Returns non-zero only when the destination cannot be created or written.
propagate_inheritable_config() {
  local src_config=$1 dest_config=$2 item src dest
  [ -n "$src_config" ] || return 1
  [ -n "$dest_config" ] || return 1
  for item in $FM_INHERITABLE_CONFIG; do
    case "$item" in
      ''|/*|.|..|../*|*/../*|*/..) return 1 ;;
    esac
    src="$src_config/$item"
    dest="$dest_config/$item"
    if [ -f "$src" ]; then
      destination_allows_inherited_item "$dest_config" "$item" || continue
      if [ -L "$dest" ] || [ ! -f "$dest" ] || ! cmp -s "$src" "$dest"; then
        copy_inheritable_file "$src" "$dest" || return 1
      fi
    elif [ -e "$dest" ] || [ -L "$dest" ]; then
      destination_allows_inherited_item "$dest_config" "$item" || continue
      # Primary has no value for this item: mirror the absence downstream.
      rm -f "$dest" 2>/dev/null || return 1
    fi
  done
  return 0
}
