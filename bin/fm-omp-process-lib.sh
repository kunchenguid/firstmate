#!/usr/bin/env bash
# omp (Oh My Pi) process identity, shared by harness detection and the
# session-lock ancestry walk. This file has no side effects on source.
#
# omp ships two ways, and the live process looks different for each:
#   - the Bun-compiled single binary, whose process name is exactly `omp`
#     (verified, omp 18.1.11);
#   - the bun global package (`bun install -g @oh-my-pi/pi-coding-agent`), whose
#     ~/.bun/bin/omp launcher is a symlink to dist/cli.js with a
#     `#!/usr/bin/env bun` shebang, so `ps -o comm=` reports `bun` and
#     `ps -o args=` reports `bun <path>/omp` (verified on macOS).
# Match the exact compiled name, or bun running a script whose own name is
# exactly `omp` or the package's dist/cli.js. Only the first non-option word
# after bun counts; a later prompt or working-directory argument never does.
# ps prints argv space-joined, so a script path containing spaces is rebuilt by
# extending that first word until it names an existing file; with no such file
# the first word alone is judged.
# Anchored throughout, so ompd, comp, and similar names are never this harness.
fm_omp_script_matches() {  # <script path>
  case "${1##*/}" in
    omp) return 0 ;;
  esac
  case "$1" in
    */@oh-my-pi/pi-coding-agent/dist/cli.js) return 0 ;;
  esac
  return 1
}

fm_omp_process_matches() {  # <comm> <args>
  local comm=${1:-} args=${2:-} word first=1 i j n candidate
  local words=()
  case "${comm##*/}" in
    omp) return 0 ;;
    bun) ;;
    *) return 1 ;;
  esac
  read -r -a words <<< "$args"
  n=${#words[@]}
  for ((i = 0; i < n; i++)); do
    word=${words[i]}
    if [ "$first" = 1 ]; then
      first=0
      case "${word##*/}" in
        omp) return 0 ;;
        bun) continue ;;
        *) return 1 ;;
      esac
    fi
    case "$word" in
      -e|--eval|-p|--print) return 1 ;;
      -*) continue ;;
    esac
    candidate=$word
    for ((j = i; j < n; j++)); do
      [ "$j" -eq "$i" ] || candidate+=" ${words[j]}"
      if [ -f "$candidate" ]; then
        fm_omp_script_matches "$candidate"
        return
      fi
    done
    fm_omp_script_matches "$word"
    return
  done
  return 1
}
