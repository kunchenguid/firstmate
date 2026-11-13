#!/usr/bin/env bash
# Auggie (Augment CLI) process identity.
# Sourced by bin/fm-session-lock-lib.sh and bin/fm-harness.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: auggie ships as a node bundle, so a live auggie session
# presents as an interpreter and nothing about its command NAME says auggie.
# Measured on auggie 1.2.0 with Node v26 on Linux, the primary process read:
#
#   comm : node-MainThread
#   args : node /home/<user>/.local/bin/auggie
#
# where ~/.local/bin/auggie is a symlink into the published package,
# <prefix>/lib/node_modules/@augmentcode/auggie/auggie-v2.mjs, and Node 24 can
# report comm as a bare MainThread instead. Only the script argument carries
# the identity, so the rule reads it and resolves its symlink chain, the same
# structural shape bin/fm-cursor-lib.sh and bin/fm-gemini-lib.sh use: no
# subprocess, because probing a stranger's binary during an ancestry walk or a
# liveness poll is exactly what must not happen.
#
# auggie is deliberately NOT a name in FM_HARNESS_RE (bin/fm-session-lock-lib.sh)
# and the interpreter rule is never loosened to "any node": a bare node or
# MainThread with no auggie script is rejected, so an unrelated node process
# cannot pass session-lock holder liveness.
#
# auggie publishes no harness-identity marker: zero AUGMENT_* variables reach
# the commands its bash tool runs (verified, auggie 1.2.0), so identity is this
# structural rule alone.

# fm_cursor_canonical_path owns the portable symlink walk; load it only when the
# caller has not already sourced its owner.
if ! declare -F fm_cursor_canonical_path >/dev/null 2>&1; then
  _FM_AUGGIE_LIB_DIR=${BASH_SOURCE[0]%/*}
  [ "$_FM_AUGGIE_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_AUGGIE_LIB_DIR=.
  # shellcheck source=bin/fm-cursor-lib.sh
  . "${_FM_AUGGIE_LIB_DIR:-/}/fm-cursor-lib.sh"
  unset _FM_AUGGIE_LIB_DIR
fi

# True when script path $1 carries auggie's own structural evidence after its
# symlink chain is resolved: it sits directly in the published
# @augmentcode/auggie package tree (any entrypoint name, so a renamed
# auggie-v<N>.mjs keeps matching). A script merely named auggie outside that
# package, a vendored dependency under the package's node_modules, a directory
# merely named auggie-something, and a sibling such as auggie-mcp never match.
fm_auggie_path_is_auggie() {  # <path>
  local path=$1 canonical
  [ -n "$path" ] || return 1
  case "$path" in -*) return 1 ;; esac
  canonical=$(fm_cursor_canonical_path "$path") || return 1
  case "$canonical" in
    */@augmentcode/auggie/node_modules/*) return 1 ;;
    */@augmentcode/auggie/*) return 0 ;;
  esac
  return 1
}

# Print Node's main script, skipping interpreter options and their operands.
# Read the live process's NUL-delimited argv when [pid] is readable under /proc
# (which keeps a script path containing spaces intact), otherwise use <args>.
# For flattened args, prefer the longest space-joined prefix after interpreter
# flags that names an existing file, preserving script paths containing spaces.
#
# A --opt=value word is one option. The separate-operand list below is every
# Node option `node --help` shows with a required value (Node v26.13.1), plus
# the hidden aliases --inspect-port, --debug-port, and --loader; an option with
# an optional value (--inspect[=...]) never consumes the next word, and V8
# flags accept only the --flag=value form. -e, -p, and --run run no main
# script, so they carry no auggie identity. In flattened args an operand,
# separate or after =, extends over following words while the longest
# space-joined value names an existing path, so a preload path containing
# spaces is skipped whole; a non-path operand containing spaces cannot be
# recovered from flattened args.
fm_auggie_script_arg() {  # <args> [pid]
  local args=$1 pid=${2:-} token index=1 candidate='' script=''
  local live_argv=0 options=1 option operand joined probe
  local -a words=()
  if [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ]; then
    live_argv=1
    while IFS= read -r -d '' token; do
      words+=("$token")
    done < "/proc/$pid/cmdline"
  else
    read -r -a words <<<"$args" || [ "${#words[@]}" -gt 0 ] || return 1
  fi
  while [ "$index" -lt "${#words[@]}" ]; do
    token=${words[index]}
    index=$((index + 1))
    if [ -z "$candidate" ]; then
      if [ "$options" -eq 1 ]; then
        option=$token
        if [[ "$token" = -* ]]; then
          option=${token%%=*}
          option=${option//_/-}
          case "$token" in *=*) option="$option=${token#*=}" ;; esac
        fi
        case "$option" in
          -e|--eval|-p|--print|--run|--eval=*|--print=*|--run=*|-e?*|-p?*) return 1 ;;
          --) options=0; continue ;;
          -*=*) operand=${token#*=} ;;
          -r|--require|--import|--loader|--experimental-loader|-C|--conditions|--input-type|\
          --inspect-port|--debug-port|--inspect-publish-uid|--env-file|--env-file-if-exists|\
          --title|--allow-fs-read|--allow-fs-write|--disable-proto|--disable-warning|\
          --dns-result-order|--unhandled-rejections|--max-http-header-size|\
          --max-old-space-size-percentage|--network-family-autoselection-attempt-timeout|\
          --openssl-config|--icu-data-dir|--secure-heap|--secure-heap-min|--snapshot-blob|\
          --build-snapshot-config|--build-sea|--experimental-sea-config|--config-file|\
          --experimental-config-file|--experimental-package-map|--localstorage-file|\
          --redirect-warnings|--diagnostic-dir|--report-dir|--report-directory|\
          --report-filename|--report-signal|--heapsnapshot-near-heap-limit|\
          --heapsnapshot-signal|--cpu-prof-dir|--cpu-prof-interval|--cpu-prof-name|\
          --heap-prof-dir|--heap-prof-interval|--heap-prof-name|--tls-cipher-list|\
          --tls-keylog|--trace-event-categories|--trace-event-file-pattern|\
          --trace-require-module|--use-largepages|--v8-pool-size|--vfs-load|\
          --process-timeout|--watch-path|--watch-kill-signal|--experimental-test-isolation|\
          --experimental-test-tag-filter|--test-isolation|--test-concurrency|\
          --test-coverage-branches|--test-coverage-exclude|--test-coverage-functions|\
          --test-coverage-include|--test-coverage-lines|--test-global-setup|\
          --test-name-pattern|--test-random-seed|--test-reporter|--test-reporter-destination|\
          --test-rerun-failures|--test-shard|--test-skip-pattern|--test-timeout|\
          --bench-isolation|--bench-name-pattern|--bench-reporter|\
          --bench-reporter-destination|--bench-samples|--bench-warmup)
            operand=${words[index]-}
            index=$((index + 1))
            ;;
          -*) continue ;;
          *) operand='' ;;
        esac
        if [ "$token" != "${token#-}" ]; then
          if [ "$live_argv" -eq 0 ] && [ -n "$operand" ]; then
            joined=$operand
            probe=$index
            while [ "$probe" -lt "${#words[@]}" ]; do
              joined="$joined ${words[probe]}"
              probe=$((probe + 1))
              [ ! -e "$joined" ] || index=$probe
            done
          fi
          continue
        fi
      fi
      if [ "$live_argv" -eq 1 ]; then
        printf '%s\n' "$token"
        return 0
      fi
      candidate=$token
      script=$token
    else
      candidate="$candidate $token"
    fi
    [ ! -f "$candidate" ] || script=$candidate
  done
  [ -n "$script" ] || return 1
  printf '%s\n' "$script"
}

# True when the process described by command name $1 and full argument string
# $2 is auggie. The single owner of auggie process identity for the session-lock
# ancestry walk (bin/fm-session-lock-lib.sh) and harness detection
# (bin/fm-harness.sh).
#
# Accepted: an exact auggie command name; a node, node-*, node<N>, or MainThread
# interpreter whose script argument resolves into the @augmentcode/auggie package.
#
# Rejected: a bare interpreter with no script, an interpreter running anything
# else, and any name or path that merely contains the auggie fragment.
fm_auggie_process_matches() {  # <comm> <args> [pid]
  local comm=$1 args=${2:-} pid=${3:-} base script
  [ -n "$comm" ] || return 1
  base=${comm##*/}
  base=${base#-}
  case "$base" in
    auggie) return 0 ;;
    node|node-*|node[0-9]*|MainThread)
      script=$(fm_auggie_script_arg "$args" "$pid") || return 1
      fm_auggie_path_is_auggie "$script"
      return $?
      ;;
  esac
  return 1
}
