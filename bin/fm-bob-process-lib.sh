#!/usr/bin/env bash
# Bob (IBM Bob CLI) process identity, shared by harness detection and the
# session lock. Bob is a node bundle that sets no process title, so Linux reports
# comm as MainThread and macOS as node, and neither a name table nor its own
# marker (BOB_SESSION, set only for descendants) can identify the process itself
# (verified, bob 2.0.9 on Node v24). Its first script argument is the structural
# fact: Bob is the process running Bob's installed entry script.

# True when path $1 is Bob's installed entry script, or a `bob` launcher whose
# symlink chain ends there (npm's bin shim). The script must exist: ps joins argv
# with spaces, so a path ending in Bob's suffix can be an accident of joining a
# later argument onto an unrelated first one. The npm package is @ibm/bob at
# 2.0.9 and bobshell at 2.0.6.
fm_bob_script_is_bob() {  # <path>
  local path=$1 target hop
  for hop in 1 2 3 4 5 6 7 8 9; do
    case "$path" in
      */@ibm/bob/dist/bob.js | */bobshell/dist/bob.js)
        [ -f "$path" ]
        return
        ;;
    esac
    [ "$hop" -gt 1 ] || [ "${path##*/}" = bob ] || return 1
    [ -L "$path" ] || return 1
    target=$(readlink -- "$path" 2>/dev/null) || return 1
    case "$target" in
      /*) path=$target ;;
      *) path=$(dirname -- "$path")/$target ;;
    esac
  done
  return 1
}

# True when command name $1 is the node runtime Bob's processes report.
fm_bob_comm_is_node() {  # <comm>
  case "${1##*/}" in
    MainThread|node|node-*|node[0-9]*) return 0 ;;
  esac
  return 1
}

# True when command name $1 and argument string $2 describe Bob's session or
# supervisor process. An empty $1 leaves the proof to the interpreter in $2. Node
# options before the script are skipped, and both the interpreter and the script
# path may contain spaces. MainThread is accepted ONLY together with that script,
# never widened to every node process. Every caller runs this on foreign node
# processes too, some on each watcher poll and some holding a whole brief in
# argv, so the cost is bounded whatever the argv length: only the head of argv
# can hold the script, and at most 16 words can continue a path that spaces split.
# Anything past either bound is not Bob.
fm_bob_process_matches() {  # <comm> <args>
  local comm=$1 args=${2:0:8192} i last=0 start=-1
  local -a words=()
  [ -z "$comm" ] || fm_bob_comm_is_node "$comm" || return 1
  case "$args" in
    */bob*) ;;
    *) return 1 ;;
  esac
  read -r -a words <<<"$args" || true
  # argv[0] ends at the first word that completes a real node executable, so a
  # later argument can never pose as the end of the interpreter.
  for ((i = 0; i < ${#words[@]} && i <= 16; i++)); do
    fm_bob_comm_is_node "${words[i]}" || continue
    [ -f "${words[*]:0:i+1}" ] && [ -x "${words[*]:0:i+1}" ] || continue
    last=$i
    break
  done
  [ -n "$comm" ] || fm_bob_comm_is_node "${words[last]}" || return 1
  for ((i = last + 1; i < ${#words[@]}; i++)); do
    case "${words[i]}" in -*) continue ;; esac
    start=$i
    break
  done
  [ "$start" -ge 0 ] || return 1
  # ps joins argv with spaces, so an install path containing spaces arrives as
  # several words (and may be followed by Bob's own arguments): join a candidate
  # only at a word that can end Bob's launcher or script.
  for ((i = start; i < ${#words[@]} && i <= start + 16; i++)); do
    case "${words[i]}" in
      */bob | */bob.js)
        fm_bob_script_is_bob "${words[*]:start:i-start+1}" && return 0
        ;;
    esac
  done
  return 1
}

# fm_bob_process_matches for a live process whose argv the caller has not read.
# Only node processes pay for the ps.
fm_bob_pid_matches() {  # <comm> <pid>
  fm_bob_comm_is_node "$1" || return 1
  fm_bob_process_matches "$1" "$(LC_ALL=C ps -p "$2" -o args= 2>/dev/null)"
}
