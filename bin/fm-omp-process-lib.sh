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
# Match the exact compiled name, or bun whose argv0 is bun and whose very next
# argument is a script named exactly `omp`.
# ps prints argv space-joined, so a script path containing spaces is rebuilt by
# extending that word until it names an existing file; with no such file the
# word alone is judged.
# Anchored throughout, so ompd, comp, and similar names are never this harness.
fm_omp_process_matches() {  # <comm> <args>
  local comm=${1:-} args=${2:-} i n script
  local words=()
  case "${comm##*/}" in
    omp) return 0 ;;
    bun) ;;
    *) return 1 ;;
  esac
  read -r -a words <<< "$args"
  n=${#words[@]}
  [ "$n" -ge 2 ] && [ "${words[0]##*/}" = bun ] || return 1
  script=${words[1]}
  for ((i = 2; i < n; i++)); do
    [ -f "$script" ] && break
    script+=" ${words[i]}"
  done
  [ -f "$script" ] || script=${words[1]}
  [ "${script##*/}" = omp ]
}
