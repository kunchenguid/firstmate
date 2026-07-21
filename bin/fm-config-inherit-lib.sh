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
# After successful config/* changes under an already-running secondmate, callers
# invoke fm_config_send_reread_nudge so the live agent re-reads exact post-write
# bytes (spawn/respawn already re-reads at launch and needs no redundant nudge).
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

# Relative prefix of per-home instruction files written after a successful
# config push so the live secondmate can re-read exact post-write bytes.
# Kept under state/ (gitignored operational dir) so it never dirties the home.
FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL="state/.fm-inherited-config-reread"
FM_CONFIG_REREAD_MAX_SENT=16
FM_CONFIG_REREAD_RETRY_ROOT_REL="state/.fm-inherited-config-reread-retry"
FM_CONFIG_REREAD_MAX_PENDING=16
FM_CONFIG_REREAD_MAX_QUARANTINE=16
FM_CONFIG_INHERIT_LOCK_REL="state/.fm-inherited-config.lock"

# Framing lines for the config-reread instruction. Defaults/rules only - never
# an enforcement claim, and never a parsed summary of file contents.
FM_CONFIG_REREAD_FRAMING='These inherited config files changed. Re-read and apply their exact contents at every future intake. They are defaults/rules and do not remove your judgment to choose differently when warranted.'

# fm_config_reread_is_allowlisted_item <item>
# True only for the declared inheritable config allowlist (bare item name as
# recorded in FM_CONFIG_INHERIT_REPORT). data/captain-shared.md is never
# allowlisted here and must never be inlined into a reread instruction.
fm_config_reread_is_allowlisted_item() {
  local item=$1 candidate
  for candidate in $FM_INHERITABLE_CONFIG; do
    [ "$candidate" = "$item" ] && return 0
  done
  return 1
}

# fm_config_reread_changed_items <report>
# Print bare allowlisted config item names whose report status is "pushed",
# in FM_INHERITABLE_CONFIG order (deterministic path order). Empty when none.
fm_config_reread_changed_items() {
  local report=$1 item status
  [ -n "$report" ] && [ -f "$report" ] || return 0
  for item in $FM_INHERITABLE_CONFIG; do
    status=$(awk -F '\t' -v item="$item" '$1 == item { print $2; exit }' "$report" 2>/dev/null) || status=""
    [ "$status" = pushed ] || continue
    printf '%s\n' "$item"
  done
}

fm_config_inherit_lock_path() {
  local dest_home=$1
  [ -n "$dest_home" ] || return 1
  printf '%s/%s\n' "$dest_home" "$FM_CONFIG_INHERIT_LOCK_REL"
}

fm_config_reread_retry_dir() {
  local source_home=$1 id=$2 token
  [ -n "$source_home" ] && [ -n "$id" ] || return 1
  token=${id//[^a-zA-Z0-9_.-]/_}
  [ -n "$token" ] || token=unknown
  printf '%s/%s/%s\n' "$source_home" "$FM_CONFIG_REREAD_RETRY_ROOT_REL" "$token"
}

fm_config_reread_pending_stages() {
  local source_home=$1 id=$2 retry_dir stage
  retry_dir=$(fm_config_reread_retry_dir "$source_home" "$id") || return 1
  for stage in "$retry_dir"/.fm-inherited-config-reread.*; do
    case "$stage" in
      *.report) continue ;;
    esac
    [ -f "$stage" ] && [ ! -L "$stage" ] || continue
    [ -s "$stage" ] || continue
    printf '%s\n' "$stage"
  done | LC_ALL=C sort
}

fm_config_reread_pending_reports() {
  local source_home=$1 id=$2 retry_dir report
  retry_dir=$(fm_config_reread_retry_dir "$source_home" "$id") || return 1
  for report in "$retry_dir"/.fm-inherited-config-reread.*.report; do
    [ -f "$report" ] && [ ! -L "$report" ] || continue
    printf '%s\n' "$report"
  done | LC_ALL=C sort
}

fm_config_reread_has_staged() {
  local source_home=$1 id=$2 stage
  while IFS= read -r stage; do
    [ -n "$stage" ] && return 0
  done < <(fm_config_reread_pending_stages "$source_home" "$id")
  while IFS= read -r stage; do
    [ -n "$stage" ] && return 0
  done < <(fm_config_reread_pending_reports "$source_home" "$id")
  return 1
}

fm_config_reread_retry_queue_is_full() {
  local source_home=$1 id=$2 count report_count
  count=$(fm_config_reread_pending_stages "$source_home" "$id" | wc -l | tr -d ' ')
  report_count=$(fm_config_reread_pending_reports "$source_home" "$id" | wc -l | tr -d ' ')
  count=$((count + report_count))
  [ "$count" -ge "$FM_CONFIG_REREAD_MAX_PENDING" ]
}

fm_config_reread_retry_pending() {
  local id=$1 dest_home=$2 report retry_out rc
  report=$(mktemp "${TMPDIR:-/tmp}/fm-config-reread-retry.XXXXXX" 2>/dev/null) || {
    printf 'CONFIG_REREAD: secondmate %s: send failed: could not create retry report\n' "$id"
    return 1
  }
  retry_out=$(fm_config_send_reread_nudge "$id" "$dest_home" "$report" 2>&1)
  rc=$?
  rm -f "$report"
  [ -z "$retry_out" ] || printf '%s\n' "$retry_out"
  return "$rc"
}

fm_config_reread_new_retry_stage_path() {
  local source_home=$1 id=$2 retry_dir sequence sequence_file sequence_tmp generation stage
  retry_dir=$(fm_config_reread_retry_dir "$source_home" "$id") || return 1
  mkdir -p "$retry_dir" 2>/dev/null || return 1
  chmod 0700 "$retry_dir" 2>/dev/null || return 1
  sequence=$(cat "$retry_dir/.sequence" 2>/dev/null || true)
  case "$sequence" in
    ''|*[!0-9]*) sequence=0 ;;
  esac
  sequence=$((sequence + 1))
  sequence_file="$retry_dir/.sequence"
  sequence_tmp=$(umask 077; mktemp "$retry_dir/.sequence.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$sequence" > "$sequence_tmp" || ! chmod 0600 "$sequence_tmp" 2>/dev/null || ! mv -f "$sequence_tmp" "$sequence_file" 2>/dev/null; then
    rm -f "$sequence_tmp"
    return 1
  fi
  generation=$(date -u +%Y%m%dT%H%M%S 2>/dev/null) || return 1
  generation="$generation.$(printf '%08d' "$sequence")"
  stage=$(umask 077; mktemp "$retry_dir/.fm-inherited-config-reread.$generation.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$stage"
}

fm_config_reread_save_retry_report() {
  local report=$1 stage_path=$2 report_path tmp parent
  parent=${stage_path%/*}
  report_path="$stage_path.report"
  tmp=$(umask 077; mktemp "$parent/.fm-config-reread-report.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$report" > "$tmp" || ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$report_path" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s\n' "$report_path"
}

# fm_config_write_reread_instruction <dest-home> <report> <instruction-path>
# After successful propagation, write one instruction from the validated
# destination state. Includes only changed allowlisted config files, each with
# relative path, begin/end delimiters, and either the destination file's full
# exact post-write bytes (streamed unparsed) or the literal token ABSENT when
# the destination copy was removed. Returns 1 when no allowlisted config item
# changed (or on write failure). Never inlines data/captain-shared.md, SHA
# values, selected profiles, or any generated interpretation.
fm_config_write_reread_instruction() {
  local dest_home=$1 report=$2 instruction_path=$3 item rel dest parent tmp first=1
  FM_CONFIG_REREAD_FAILED_TEMP=""
  [ -n "$dest_home" ] || return 1
  [ -n "$report" ] && [ -f "$report" ] || return 1
  [ -n "$instruction_path" ] || return 1
  parent=${instruction_path%/*}
  [ -n "$parent" ] && [ "$parent" != "$instruction_path" ] || return 1
  mkdir -p "$parent" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$instruction_path.tmp.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    fm_config_reread_is_allowlisted_item "$item" || continue
    rel="config/$item"
    dest="$dest_home/config/$item"
    if [ "$first" = 1 ]; then
      printf '%s\n' "$FM_CONFIG_REREAD_FRAMING" >> "$tmp" || { rm -f "$tmp"; return 1; }
      first=0
    fi
    {
      printf '\n'
      printf '%s\n' "$rel"
      printf '%s\n' "-----BEGIN $rel-----"
    } >> "$tmp" || { rm -f "$tmp"; return 1; }
    if [ -f "$dest" ] && [ ! -L "$dest" ]; then
      # Stream destination post-write bytes only - never re-read the primary.
      cat "$dest" >> "$tmp" || { rm -f "$tmp"; return 1; }
    else
      printf '%s\n' "ABSENT" >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    printf '%s\n' "-----END $rel-----" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < <(fm_config_reread_changed_items "$report")
  if [ "$first" = 1 ]; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$instruction_path" 2>/dev/null; then
    FM_CONFIG_REREAD_FAILED_TEMP="$tmp"
    return 1
  fi
  return 0
}

fm_config_reread_adopt_exact_temp() {
  local exact_tmp=$1 stage_path=$2
  [ -f "$exact_tmp" ] && [ ! -L "$exact_tmp" ] || return 1
  [ ! -L "$stage_path" ] || return 1
  if mv -f "$exact_tmp" "$stage_path" 2>/dev/null; then
    return 0
  fi
  if cp "$exact_tmp" "$stage_path" 2>/dev/null \
    && chmod 0600 "$stage_path" 2>/dev/null \
    && cmp -s "$exact_tmp" "$stage_path"; then
    rm -f "$exact_tmp" 2>/dev/null || true
    return 0
  fi
  rm -f "$stage_path" 2>/dev/null || true
  return 1
}

fm_config_reread_pending_instructions() {
  local state=$1 pending instruction
  for pending in "$state"/.fm-inherited-config-reread.*.pending; do
    [ -f "$pending" ] && [ ! -L "$pending" ] || continue
    instruction=${pending%.pending}
    printf '%s\n' "$instruction"
  done | LC_ALL=C sort
}

fm_config_reread_has_pending() {
  local dest_home=$1 state pending
  state="$dest_home/${FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL%/*}"
  for pending in "$state"/.fm-inherited-config-reread.*.pending; do
    [ -f "$pending" ] && [ ! -L "$pending" ] || continue
    return 0
  done
  return 1
}

fm_config_reread_cleanup_sent() {
  local dest_home=$1 state path paths sorted total remove
  state="$dest_home/${FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL%/*}"
  [ -d "$state" ] || return 0
  paths=""
  for path in "$state"/.fm-inherited-config-reread.*; do
    case "$path" in
      *.pending) continue ;;
    esac
    [ -f "$path" ] && [ ! -L "$path" ] || continue
    [ -e "$path.pending" ] || [ -L "$path.pending" ] && continue
    if [ -n "$paths" ]; then
      paths+=$'\n'
    fi
    paths+="$path"
  done
  [ -n "$paths" ] || return 0
  sorted=$(printf '%s\n' "$paths" | LC_ALL=C sort)
  total=$(printf '%s\n' "$sorted" | wc -l | tr -d ' ')
  remove=$((total - FM_CONFIG_REREAD_MAX_SENT))
  [ "$remove" -gt 0 ] || return 0
  while IFS= read -r path; do
    [ "$remove" -gt 0 ] || break
    [ -n "$path" ] || continue
    [ -e "$path.pending" ] || [ -L "$path.pending" ] && continue
    rm -f "$path" 2>/dev/null || continue
    remove=$((remove - 1))
  done <<EOF
$sorted
EOF
}

fm_config_reread_mark_pending() {
  local instruction_path=$1 pending_path=$2 parent tmp
  parent=${pending_path%/*}
  [ -n "$parent" ] && [ "$parent" != "$pending_path" ] || return 1
  mkdir -p "$parent" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$parent/.fm-config-reread-pending.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$instruction_path" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 0600 "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$pending_path" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

fm_config_reread_publish_stage() {
  local dest_home=$1 stage=$2 state final pending_pointer tmp
  [ -f "$stage" ] && [ ! -L "$stage" ] || return 1
  state="$dest_home/${FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL%/*}"
  mkdir -p "$state" 2>/dev/null || return 1
  final="$state/${stage##*/}"
  if [ -f "$final.pending" ] && [ ! -L "$final.pending" ]; then
    pending_pointer=$(cat "$final.pending" 2>/dev/null || true)
    [ "$pending_pointer" = "$final" ] || return 1
    [ -f "$final" ] && [ ! -L "$final" ] || return 1
    printf '%s\n' "$final"
    return 0
  fi
  tmp=$(umask 077; mktemp "$state/.fm-config-reread-publish.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$stage" > "$tmp" || ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$final" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! fm_config_reread_mark_pending "$final" "$final.pending"; then
    rm -f "$final"
    return 1
  fi
  printf '%s\n' "$final"
}

fm_config_reread_send_failure() {
  local id=$1 instruction_path=$2 pending_path=$3 detail=$4
  if ! fm_config_reread_mark_pending "$instruction_path" "$pending_path"; then
    detail="$detail; could not record retry marker"
  fi
  printf 'CONFIG_REREAD: secondmate %s: send failed: %s\n' "$id" "$detail"
  return 1
}

# fm_config_reread_send_pointer <id> <instruction-path>
fm_config_reread_send_pointer() {
  local id=$1 instruction_path=$2 pending_path selector out rc send_bin message pending_pointer
  pending_path="$instruction_path.pending"
  if [ ! -f "$instruction_path" ] || [ -L "$instruction_path" ]; then
    printf 'CONFIG_REREAD: secondmate %s: send failed: pending instruction file is missing\n' "$id"
    return 1
  fi
  pending_pointer=$(cat "$pending_path" 2>/dev/null || true)
  if [ "$pending_pointer" != "$instruction_path" ]; then
    printf 'CONFIG_REREAD: secondmate %s: send failed: pending instruction file is mismatched\n' "$id"
    return 1
  fi
  selector="fm-$id"
  send_bin="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-send.sh"
  if [ ! -x "$send_bin" ]; then
    fm_config_reread_send_failure "$id" "$instruction_path" "$pending_path" "fm-send.sh not executable at $send_bin"
    return 1
  fi
  if [ -z "${FM_HOME:-}" ]; then
    fm_config_reread_send_failure "$id" "$instruction_path" "$pending_path" "FM_HOME is not set"
    return 1
  fi
  message="CONFIG_REREAD: $instruction_path"
  out=$(FM_HOME="$FM_HOME" \
    FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-}" \
    FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-}" \
    FM_SEND_SETTLE="${FM_SEND_SETTLE:-0}" \
    "$send_bin" "$selector" "$message" 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$pending_path"
    return 0
  fi
  out=${out%%$'\n'*}
  [ -n "$out" ] || out="fm-send exited $rc"
  fm_config_reread_send_failure "$id" "$instruction_path" "$pending_path" "$out"
  return 1
}

# fm_config_reread_discard_pending <dest-home>
fm_config_reread_discard_pending() {
  local dest_home=$1 id=${2:-} source_home=${3:-} state pending instruction retry_dir retry_stage rc=0
  state="$dest_home/${FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL%/*}"
  for pending in "$state"/.fm-inherited-config-reread.*.pending; do
    [ -f "$pending" ] && [ ! -L "$pending" ] || continue
    instruction=${pending%.pending}
    rm -f "$pending" 2>/dev/null || rc=1
    rm -f "$instruction" 2>/dev/null || rc=1
  done
  if [ -n "$id" ] && [ -n "$source_home" ]; then
    retry_dir=$(fm_config_reread_retry_dir "$source_home" "$id") || rc=1
    if [ -d "$retry_dir" ]; then
      for retry_stage in "$retry_dir"/.fm-inherited-config-reread.*; do
        [ -f "$retry_stage" ] && [ ! -L "$retry_stage" ] || continue
        rm -f "$retry_stage" 2>/dev/null || rc=1
      done
      rm -f "$retry_dir/.sequence" 2>/dev/null || true
      rmdir "$retry_dir" 2>/dev/null || true
    fi
  fi
  return "$rc"
}

fm_config_reread_quarantine_prune() {
  local root=$1 keep=${2:-$FM_CONFIG_REREAD_MAX_QUARANTINE} dirs dir oldest path remove
  case "$keep" in
    ''|*[!0-9]*) keep=$FM_CONFIG_REREAD_MAX_QUARANTINE ;;
  esac
  [ -d "$root" ] || return 0
  dirs=""
  for dir in "$root"/generation.*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    [ -n "$dirs" ] && dirs+=$'\n'
    dirs+="$dir"
  done
  dirs=$(printf '%s\n' "$dirs" | LC_ALL=C sort)
  [ -n "$dirs" ] || return 0
  remove=$(printf '%s\n' "$dirs" | wc -l | tr -d ' ')
  remove=$((remove - keep))
  while [ "$remove" -gt 0 ]; do
    oldest=${dirs%%$'\n'*}
    if [ "$oldest" = "$dirs" ]; then
      dirs=""
    else
      dirs=${dirs#*$'\n'}
    fi
    for path in "$oldest"/.[!.]* "$oldest"/..?* "$oldest"/*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      if [ -d "$path" ] && [ ! -L "$path" ]; then
        rmdir "$path" 2>/dev/null || return 1
      else
        rm -f "$path" 2>/dev/null || return 1
      fi
    done
    rmdir "$oldest" 2>/dev/null || return 1
    remove=$((remove - 1))
  done
}

fm_config_reread_quarantine_dir() {
  local home=$1 state root quarantine
  state="$home/${FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL%/*}"
  root="$state/.fm-inherited-config-reread-quarantine"
  mkdir -p "$root" 2>/dev/null || return 1
  chmod 0700 "$root" 2>/dev/null || return 1
  fm_config_reread_quarantine_prune "$root" $((FM_CONFIG_REREAD_MAX_QUARANTINE - 1)) || return 1
  quarantine=$(umask 077; mktemp -d "$root/generation.XXXXXX" 2>/dev/null) || return 1
  chmod 0700 "$quarantine" 2>/dev/null || return 1
  printf '%s\n' "$quarantine"
}

fm_config_reread_quarantine_pending() {
  local dest_home=$1 id=${2:-} source_home=${3:-}
  local state pending instruction retry_dir retry_stage dest_quarantine source_quarantine
  local dest_has_artifacts source_has_artifacts rc=0
  state="$dest_home/${FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL%/*}"
  dest_has_artifacts=0
  for pending in "$state"/.fm-inherited-config-reread.*.pending; do
    [ -f "$pending" ] && [ ! -L "$pending" ] || continue
    dest_has_artifacts=1
    break
  done
  dest_quarantine=""
  if [ "$dest_has_artifacts" -eq 1 ]; then
    dest_quarantine=$(fm_config_reread_quarantine_dir "$dest_home" 2>/dev/null || true)
  fi
  for pending in "$state"/.fm-inherited-config-reread.*.pending; do
    [ -f "$pending" ] && [ ! -L "$pending" ] || continue
    instruction=${pending%.pending}
    if [ -n "$dest_quarantine" ] && mv -f "$pending" "$dest_quarantine/${pending##*/}" 2>/dev/null; then
      if [ -e "$instruction" ] || [ -L "$instruction" ]; then
        mv -f "$instruction" "$dest_quarantine/${instruction##*/}" 2>/dev/null || {
          rm -f "$instruction" 2>/dev/null || true
          rc=1
        }
      fi
    else
      rm -f "$pending" 2>/dev/null || rc=1
      rm -f "$instruction" 2>/dev/null || rc=1
      rc=1
    fi
  done
  if [ -n "$id" ] && [ -n "$source_home" ]; then
    retry_dir=$(fm_config_reread_retry_dir "$source_home" "$id") || retry_dir=
    source_has_artifacts=0
    if [ -d "$retry_dir" ]; then
      for retry_stage in "$retry_dir"/.fm-inherited-config-reread.*; do
        [ -f "$retry_stage" ] && [ ! -L "$retry_stage" ] || continue
        source_has_artifacts=1
        break
      done
    fi
    source_quarantine=""
    if [ "$source_has_artifacts" -eq 1 ]; then
      source_quarantine=$(fm_config_reread_quarantine_dir "$source_home" 2>/dev/null || true)
    fi
    if [ -d "$retry_dir" ]; then
      for retry_stage in "$retry_dir"/.fm-inherited-config-reread.*; do
        [ -f "$retry_stage" ] && [ ! -L "$retry_stage" ] || continue
        if [ -n "$source_quarantine" ] && mv -f "$retry_stage" "$source_quarantine/${retry_stage##*/}" 2>/dev/null; then
          :
        else
          rm -f "$retry_stage" 2>/dev/null || rc=1
          rc=1
        fi
      done
      if [ -f "$retry_dir/.sequence" ] && [ ! -L "$retry_dir/.sequence" ]; then
        if [ -n "$source_quarantine" ] && mv -f "$retry_dir/.sequence" "$source_quarantine/.sequence" 2>/dev/null; then
          :
        else
          rm -f "$retry_dir/.sequence" 2>/dev/null || rc=1
          rc=1
        fi
      fi
      rmdir "$retry_dir" 2>/dev/null || true
    fi
  fi
  return "$rc"
}

# fm_config_send_reread_nudge <id> <dest-home> <report>
# After successful propagation, if any allowlisted config item changed for this
# home, write the exact-byte instruction under the destination home and send a
# single-line pointers to those files through the routed secondmate path
# (fm-send). The files contain only changed config paths, clear delimiters, and
# the destination's full exact post-write bytes (or ABSENT) - never summaries,
# SHA values, selected profiles, or data/captain-shared.md. No-op (return 0) when
# nothing changed and no pending delivery exists. On publication or send
# failure, print a concrete CONFIG_REREAD retry diagnostic to stdout and return
# non-zero - never claim the live agent reread the values.
fm_config_send_reread_nudge() {
  local id=$1 dest_home=$2 report=$3
  local dest_home_abs state source_home_abs changed_items pending_paths stage_paths delivery_paths
  local stage_path instruction_path current_stage_path exact_tmp
  local send_failures retry_report_paths retry_report_path retry_stage_path retry_record_path
  [ -n "$id" ] || return 1
  [ -n "$dest_home" ] || return 1
  [ -n "$report" ] && [ -f "$report" ] || return 1
  dest_home_abs=$(cd "$dest_home" 2>/dev/null && pwd -P) || {
    printf 'CONFIG_REREAD: secondmate %s: send failed: destination home is not readable\n' "$id"
    return 1
  }
  state="$dest_home_abs/${FM_CONFIG_REREAD_INSTRUCTION_PREFIX_REL%/*}"
  changed_items=$(fm_config_reread_changed_items "$report")
  pending_paths=""
  stage_paths=""
  retry_report_paths=""
  if [ "${FM_CONFIG_REREAD_SKIP_PENDING:-0}" != 1 ]; then
    pending_paths=$(fm_config_reread_pending_instructions "$state")
    source_home_abs=$(cd "${FM_HOME:-}" 2>/dev/null && pwd -P || true)
    if [ -n "$source_home_abs" ]; then
      stage_paths=$(fm_config_reread_pending_stages "$source_home_abs" "$id")
      retry_report_paths=$(fm_config_reread_pending_reports "$source_home_abs" "$id")
    fi
  fi
  send_failures=0
  while IFS= read -r retry_report_path; do
    [ -n "$retry_report_path" ] || continue
    retry_stage_path=${retry_report_path%.report}
    exact_tmp=""
    for stage_path in "$retry_stage_path".tmp.*; do
      [ -f "$stage_path" ] && [ ! -L "$stage_path" ] || continue
      exact_tmp="$stage_path"
      break
    done
    if [ -n "$exact_tmp" ]; then
      rm -f "$retry_report_path" 2>/dev/null || send_failures=1
      continue
    fi
    if fm_config_write_reread_instruction "$dest_home_abs" "$retry_report_path" "$retry_stage_path"; then
      rm -f "$retry_report_path" 2>/dev/null || send_failures=1
      if [ -n "$stage_paths" ]; then
        stage_paths+=$'\n'
      fi
      stage_paths+="$retry_stage_path"
    else
      exact_tmp=${FM_CONFIG_REREAD_FAILED_TEMP:-}
      if [ -n "$exact_tmp" ] \
        && fm_config_reread_adopt_exact_temp "$exact_tmp" "$retry_stage_path"; then
        rm -f "$retry_report_path" 2>/dev/null || send_failures=1
        if [ -n "$stage_paths" ]; then
          stage_paths+=$'\n'
        fi
        stage_paths+="$retry_stage_path"
      elif [ -n "$exact_tmp" ] && [ -f "$exact_tmp" ]; then
        printf 'CONFIG_REREAD: secondmate %s: send failed: retained exact retry temporary %s\n' "$id" "$exact_tmp"
        send_failures=1
        break
      else
        printf 'CONFIG_REREAD: secondmate %s: send failed: could not rebuild retry instruction\n' "$id"
        send_failures=1
        break
      fi
    fi
  done <<EOF
$retry_report_paths
EOF
  if [ "$send_failures" -ne 0 ]; then
    fm_config_reread_cleanup_sent "$dest_home_abs"
    return 1
  fi
  if [ -n "$changed_items" ]; then
    source_home_abs=$(cd "${FM_HOME:-}" 2>/dev/null && pwd -P || true)
    if [ -z "$source_home_abs" ]; then
      printf 'CONFIG_REREAD: secondmate %s: send failed: could not reserve retry instruction\n' "$id"
      return 1
    fi
    if fm_config_reread_retry_queue_is_full "$source_home_abs" "$id"; then
      printf 'CONFIG_REREAD: secondmate %s: send failed: retry instruction queue is full\n' "$id"
      return 1
    fi
    current_stage_path=$(fm_config_reread_new_retry_stage_path "$source_home_abs" "$id") || {
      printf 'CONFIG_REREAD: secondmate %s: send failed: could not reserve retry instruction\n' "$id"
      return 1
    }
    if ! fm_config_write_reread_instruction "$dest_home_abs" "$report" "$current_stage_path"; then
      exact_tmp=${FM_CONFIG_REREAD_FAILED_TEMP:-}
      if [ -n "$exact_tmp" ] \
        && fm_config_reread_adopt_exact_temp "$exact_tmp" "$current_stage_path"; then
        printf 'CONFIG_REREAD: secondmate %s: send failed: could not publish retry instruction; retained exact retry generation %s\n' "$id" "$current_stage_path"
      elif [ -n "$exact_tmp" ] && [ -f "$exact_tmp" ]; then
        rm -f "$current_stage_path" 2>/dev/null || true
        printf 'CONFIG_REREAD: secondmate %s: send failed: retained exact retry temporary %s\n' "$id" "$exact_tmp"
      elif retry_record_path=$(fm_config_reread_save_retry_report "$report" "$current_stage_path"); then
        rm -f "$current_stage_path" 2>/dev/null || true
        printf 'CONFIG_REREAD: secondmate %s: send failed: could not write retry instruction; retained retry report %s\n' "$id" "$retry_record_path"
      else
        rm -f "$current_stage_path" 2>/dev/null || true
        printf 'CONFIG_REREAD: secondmate %s: send failed: could not write retry instruction or retain retry report\n' "$id"
      fi
      return 1
    fi
    if [ -n "$stage_paths" ]; then
      stage_paths+=$'\n'
    fi
    stage_paths+="$current_stage_path"
  fi
  delivery_paths="$pending_paths"
  while IFS= read -r stage_path; do
    [ -n "$stage_path" ] || continue
    if instruction_path=$(fm_config_reread_publish_stage "$dest_home_abs" "$stage_path"); then
      if [ -n "$delivery_paths" ]; then
        case $'\n'"$delivery_paths"$'\n' in
          *$'\n'"$instruction_path"$'\n'*) ;;
          *) delivery_paths+=$'\n'; delivery_paths+="$instruction_path" ;;
        esac
      else
        delivery_paths="$instruction_path"
      fi
    else
      printf 'CONFIG_REREAD: secondmate %s: send failed: could not publish retry instruction\n' "$id"
      send_failures=1
      break
    fi
  done <<EOF
$stage_paths
EOF
  if [ -z "$delivery_paths" ]; then
    fm_config_reread_cleanup_sent "$dest_home_abs"
    [ "${send_failures:-0}" = 1 ] && return 1
    return 0
  fi
  delivery_paths=$(printf '%s\n' "$delivery_paths" | LC_ALL=C sort)
  while IFS= read -r instruction_path; do
    [ -n "$instruction_path" ] || continue
    if fm_config_reread_send_pointer "$id" "$instruction_path"; then
      while IFS= read -r stage_path; do
        [ -n "$stage_path" ] || continue
        [ "${stage_path##*/}" = "${instruction_path##*/}" ] || continue
        rm -f "$stage_path" 2>/dev/null || true
      done <<EOF
$stage_paths
EOF
    else
      send_failures=1
      break
    fi
  done <<EOF
$delivery_paths
EOF
  if [ "$send_failures" -ne 0 ]; then
    fm_config_reread_cleanup_sent "$dest_home_abs"
    return 1
  fi
  fm_config_reread_cleanup_sent "$dest_home_abs"
  return 0
}
