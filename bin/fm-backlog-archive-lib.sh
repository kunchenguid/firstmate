# shellcheck shell=bash
# Shared read-only markdown archive replay through tasks-axi.
# Usage: source after fm-backlog-transition-lib.sh; call
# fm_backlog_row_show_archived <data-dir> <id> for the newest archived row.

fm_backlog_toml_section_entries() {  # <toml-file> <section> <key-alternation>
  [ -f "$1" ] || return 0
  LC_ALL=C awk -v section="[$2]" -v keys="^($3)[[:space:]]*=" '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    BEGIN { insection = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { insection = (line == section); next }
      if (!insection) next
      if (line ~ keys) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "%s %s\n", key, line
      }
    }
  ' "$1"
}

fm_backlog_archive_setting() {  # <backlog-root>
  local root=$1 archive
  archive=$(fm_backlog_toml_section_entries "$root/.tasks.toml" markdown archive | sed -n 's/^archive //p' | head -1)
  if [ -z "$archive" ] && [ -n "${HOME:-}" ]; then
    archive=$(fm_backlog_toml_section_entries "$HOME/.tasks-axi/config.toml" markdown archive | sed -n 's/^archive //p' | head -1)
  fi
  printf '%s\n' "$archive"
}

fm_backlog_archive_path() {
  local data root backend archive file
  data=$(fm_backlog_data_absolute "$1") || return 1
  root=$(fm_backlog_root "$data") || return 1
  backend=$(fm_tasks_axi_backend "$root" 2>/dev/null) || return 1
  [ "$backend" = markdown ] || return 1
  archive=$(fm_backlog_archive_setting "$root")
  case "$archive" in
    '')
      file=$(fm_backlog_file "$data") || return 1
      archive="${file%/*}/done-archive.md"
      ;;
    /*) ;;
    *) archive="$root/$archive" ;;
  esac
  printf '%s\n' "$archive"
}

fm_backlog_row_show_archived() {  # <data-dir> <id>
  local data=$1 id=$2 archive dir output status=0 secs=${FM_BACKLOG_ROW_TIMEOUT_SECS:-10}
  output=
  case "$secs" in ''|*[!0-9]*) secs=10 ;; esac
  [ "$secs" -gt 0 ] 2>/dev/null || secs=10
  archive=$(fm_backlog_archive_path "$data") || return 1
  [ -f "$archive" ] || return 1
  dir=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/fm-backlog-archive.XXXXXX") \
    || return 1
  printf 'backend = "markdown"\n' > "$dir/.tasks.toml"
  {
    printf '## Done\n'
    LC_ALL=C awk -v id="$id" '
      /^- \[.\] / {
        rest = substr($0, 7)
        inrow = (rest == id || index(rest, id " ") == 1)
        if (inrow) block = $0 "\n"
        next
      }
      inrow && ($0 == "" || $0 ~ /^[[:space:]]/) { block = block $0 "\n"; next }
      { inrow = 0 }
      END { printf "%s", block }
    ' "$archive"
  } > "$dir/backlog.md" || status=1
  if [ "$status" -eq 0 ]; then
    # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
    output=$(fm_run_timed "$secs" bash -c \
      'cd "$1" 2>/dev/null || exit 1; shift; exec tasks-axi show "$@"' \
      _ "$dir" "$id" --full --file "$dir/backlog.md" 2>/dev/null)
    status=$?
    if [ "$status" -eq 124 ]; then
      printf 'fm-backlog: tasks-axi show %s exceeded its %ss Done-archive read bound\n' "$id" "$secs" >&2
    elif [ "$status" -ne 0 ]; then
      status=1
    fi
  fi
  rm -f -- "$dir/backlog.md" "$dir/.tasks.toml"
  rmdir -- "$dir" 2>/dev/null || true
  [ "$status" -ne 0 ] || printf '%s\n' "$output"
  return "$status"
}
