#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d "$ROOT/tests/.prefix-cursor.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
. "$ROOT/bin/fm-classify-lib.sh"
unset FM_CLASSIFY_RESOLVE_VERB FM_CLASSIFY_CAPTAIN_HELD_VERB FM_STATUS_CURSOR_SNAPSHOT_FILE
f="$TMP_ROOT/mate.status"
printf 'kind=secondmate\n' > "$TMP_ROOT/mate.meta"
printf 'needs-decision [key=secret-choice]: choose\n' > "$f"
cursor=$(_fm_open_decisions_cursor_path "$f")
size=$(_fm_status_file_size "$f")
for writer in default explicit empty custom; do
  unset FM_CLASSIFY_RESERVED_KEY_PREFIXES
  case "$writer" in
    explicit) export FM_CLASSIFY_RESERVED_KEY_PREFIXES="$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT" ;;
    empty) export FM_CLASSIFY_RESERVED_KEY_PREFIXES='' ;;
    custom) export FM_CLASSIFY_RESERVED_KEY_PREFIXES='pending-reply- secret-' ;;
  esac
  rm -f "$cursor"
  actual=$(status_open_decisions_incremental "$f")
  if [ "$writer" = custom ]; then
    [ -z "$actual" ]
  else
    [ "$actual" = $'secret-choice\tneeds-decision\tchoose' ]
    IFS= read -r version < "$cursor"
    [ "$version" = "version=$FM_OPEN_DECISIONS_FOLD_VERSION:secondmate" ]
  fi
  cp "$cursor" "$cursor.saved"
  for reader in default explicit empty custom; do
    unset FM_CLASSIFY_RESERVED_KEY_PREFIXES
    case "$reader" in
      explicit) export FM_CLASSIFY_RESERVED_KEY_PREFIXES="$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT" ;;
      empty) export FM_CLASSIFY_RESERVED_KEY_PREFIXES='' ;;
      custom) export FM_CLASSIFY_RESERVED_KEY_PREFIXES='pending-reply- secret-' ;;
    esac
    cp "$cursor.saved" "$cursor"
    expected=$(status_open_decisions "$f")
    [ "$(status_open_decisions "$f" secondmate "$f")" = "$expected" ]
    cmp -s "$cursor" "$cursor.saved"
    expected_offset=$size
    if { [ "$writer" = custom ] && [ "$reader" != custom ]; } \
      || { [ "$writer" != custom ] && [ "$reader" = custom ]; }; then
      expected_offset=0
    fi
    [ "$(status_open_decisions_cursor_offset "$f")" = "$expected_offset" ]
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ]
    [ "$(status_open_decisions_cursor_offset "$f")" = "$size" ]
  done
done
printf 'PASS: cursor validity honors effective reserved prefixes\n'
