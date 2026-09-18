# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_PROJECT_MEMORY_DIR is the documented output variable read by callers.
# Project memory registry shared by fm-brief.sh and fm-spawn.sh.
# config/project-memory contains one '<project> <absolute-or-~/directory>' per line.

fm_project_memory_lookup() {  # <config-dir> <project-name>
  local project=$2 file="$1/project-memory" line name dir number=0 value seen=' '
  FM_PROJECT_MEMORY_DIR=
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    echo "error: config/project-memory must be a readable regular file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    line=${line%%$'\r'}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    name=${line%%[[:space:]]*}
    if [ "$name" = "$line" ]; then
      echo "error: config/project-memory:$number must contain a project name and directory" >&2
      return 1
    fi
    dir=${line#"$name"}
    dir=$(printf '%s' "$dir" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    case "$name" in *[!A-Za-z0-9._-]*|'')
      echo "error: config/project-memory:$number has an invalid project name" >&2
      return 1 ;;
    esac
    case "$seen" in *" $name "*)
      echo "error: config/project-memory:$number duplicates project $name" >&2
      return 1 ;;
    esac
    seen="$seen$name "
    case "$dir" in
      \~/*) [ -n "${HOME:-}" ] || { echo "error: config/project-memory:$number cannot resolve ~/ without HOME" >&2; return 1; }; dir="$HOME/${dir#\~/}" ;;
      /*) ;;
      *) echo "error: config/project-memory:$number directory must be absolute or begin with ~/" >&2; return 1 ;;
    esac
    case "$dir" in *[[:cntrl:]]*)
      echo "error: config/project-memory:$number directory contains a control character" >&2
      return 1 ;;
    esac
    if [ "$name" = "$project" ]; then
      value=$dir
    fi
  done < "$file"
  FM_PROJECT_MEMORY_DIR=${value:-}
}

fm_project_memory_render_section() {  # <directory> <kind> <status-file> <report-file>
  local dir=$1 kind=$2 status_file=$3 report_file=${4:-}
  [ -n "$dir" ] || return 0
  # shellcheck disable=SC2016 # These are literal instructions for the launched worker.
  printf '%s\n' \
    '# Project memory' \
    "This project has durable memory at: $dir" \
    'Read `MEMORY.md` first, then open linked files relevant to this task.' \
    'Record new lasting lessons as new files using the same frontmatter format, and add one line for each new file to `MEMORY.md`.' \
    'The index is append-only for workers: never rewrite, reorder, or delete existing lines or other memory files; firstmates curate memory.' \
    ''
  case "$kind" in
    scout)
      printf 'This modifies Rule 2 for this task only: the only permitted writes outside the worktree are the report file %s, the status file %s, and this exact project-memory directory: %s. No other outside writes are permitted.\n\n' "$report_file" "$status_file" "$dir"
      ;;
    *)
      printf 'This modifies Rule 2 for this task only: the only permitted writes outside the worktree are the status file %s and this exact project-memory directory: %s. No other outside writes are permitted.\n\n' "$status_file" "$dir"
      ;;
  esac
}

fm_project_memory_render_brief() {  # <source-brief> <directory> <kind> <status-file> <report-file>
  local source=$1 dir=$2 kind=$3 status_file=$4 report_file=${5:-} line found=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '2. Stay inside this worktree;'*)
        found=1
        if [ "$kind" = scout ]; then
          printf '2. Stay inside this worktree; the only files you may write outside it are the report file %s, the status file %s, and this exact project-memory directory: %s.\n' "$report_file" "$status_file" "$dir"
        else
          printf '2. Stay inside this worktree; modify nothing outside it except the status file %s and this exact project-memory directory: %s.\n' "$status_file" "$dir"
        fi
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$source"
  [ "$found" -eq 1 ] || return 0
}
