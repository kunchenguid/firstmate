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
