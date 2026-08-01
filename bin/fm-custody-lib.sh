#!/usr/bin/env bash
# Create an immutable, create-exclusive copy of an ephemeral artifact and a
# machine-verifiable receipt before its caller performs a destructive transition.
#
# Source this file, then call:
#   fm_custody_preserve <source> <archive-dir> <source-ref> <custody-class>
#
# The function prints "<archived-path><TAB><receipt-path>". It never removes or
# changes the source. Every output path is newly created with shell noclobber;
# retries choose another suffix and never replace prior evidence.

fm_custody_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    printf 'fm-custody: shasum or sha256sum is required\n' >&2
    return 1
  fi
}

fm_custody_preserve() {  # <source> <archive-dir> <source-ref> <custody-class>
  local source=$1 archive_dir=$2 source_ref=$3 custody_class=$4
  local timestamp stamp base attempt archived receipt digest bytes
  [ -f "$source" ] && [ ! -L "$source" ] || {
    printf 'fm-custody: source must be a regular non-symlink file: %s\n' "$source" >&2
    return 1
  }
  case "$source_ref$custody_class" in
    *$'\n'*|*$'\r'*)
      printf 'fm-custody: source ref and custody class must be one line\n' >&2
      return 1
      ;;
  esac
  [ -n "$source_ref" ] && [ -n "$custody_class" ] || {
    printf 'fm-custody: source ref and custody class are required\n' >&2
    return 1
  }
  mkdir -p "$archive_dir" || return 1
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || return 1
  stamp=$(date -u '+%Y%m%dT%H%M%SZ') || return 1
  base=$(basename "$source")
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    archived="$archive_dir/$base.$stamp.${BASHPID:-$$}.$attempt"
    receipt="$archived.receipt"
    if (set -C; umask 077; printf '%s' '' > "$archived") 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
  done
  [ "$attempt" -lt 100 ] || {
    printf 'fm-custody: could not allocate a create-exclusive archive path\n' >&2
    return 1
  }
  if ! cp "$source" "$archived"; then
    printf 'fm-custody: could not copy source to %s\n' "$archived" >&2
    return 1
  fi
  digest=$(fm_custody_sha256 "$archived") || return 1
  bytes=$(wc -c < "$archived" | tr -d '[:space:]') || return 1
  if ! (set -C; umask 077; {
    printf 'schema=fm-custody.v1\n'
    printf 'timestamp_utc=%s\n' "$timestamp"
    printf 'source_path=%s\n' "$source"
    printf 'source_ref=%s\n' "$source_ref"
    printf 'custody_class=%s\n' "$custody_class"
    printf 'archived_path=%s\n' "$archived"
    printf 'sha256=%s\n' "$digest"
    printf 'bytes=%s\n' "$bytes"
  } > "$receipt") 2>/dev/null; then
    printf 'fm-custody: could not create receipt %s\n' "$receipt" >&2
    return 1
  fi
  printf '%s\t%s\n' "$archived" "$receipt"
}
