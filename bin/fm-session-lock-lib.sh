#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi)

# A Codex tool command can execute in a private PID namespace whose ancestry
# ends at that namespace's init.  On hosts where Codex exports its own stable
# session id into that namespace, fm-spawn records the host-side Codex agent
# that was launched for this exact home/incarnation in this private file.
# This is an additional identity route, never an ancestry fallback: absence or
# any malformed field leaves the caller unverified.
FM_CODEX_HOME_BINDING_FILE=.fm-codex-session-binding
FM_CODEX_HOME_BINDING_REQUIREMENT_FILE=.fm-codex-session-binding-required

fm_codex_spawn_generation_valid() { # <spawn-gen>
  local gen=$1 first second third rest
  first=${gen%%.*}
  rest=${gen#*.}
  [ "$rest" != "$gen" ] || return 1
  second=${rest%%.*}
  third=${rest#*.}
  [ "$third" != "$rest" ] && [ "${third#*.}" = "$third" ] || return 1
  case "$first" in s*) first=${first#s} ;; *) return 1 ;; esac
  case "$first" in ''|*[!0-9]*) return 1 ;; esac
  case "$second" in ''|*[!0-9]*) return 1 ;; esac
  case "$third" in ''|*[!0-9]*) return 1 ;; esac
}

fm_codex_home_binding_requirement_publish() { # <state-dir> <home> <spawn-gen>
  local state=$1 home=$2 spawn_gen=$3 file tmp old_umask
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$home" in *$'\n'*|*$'\r'*) return 1 ;; esac
  fm_codex_spawn_generation_valid "$spawn_gen" || return 1
  file="$state/$FM_CODEX_HOME_BINDING_REQUIREMENT_FILE"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$state/.fm-codex-session-binding-required.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  if ! {
    printf 'harness=codex\n'
    printf 'home=%s\n' "$home"
    printf 'spawn_gen=%s\n' "$spawn_gen"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_codex_home_binding_requirement_read() { # <state-dir>
  local state=$1 file line key value seen=' '
  FM_CODEX_REQUIREMENT_HARNESS=
  FM_CODEX_REQUIREMENT_HOME=
  FM_CODEX_REQUIREMENT_SPAWN_GEN=
  file="$state/$FM_CODEX_HOME_BINDING_REQUIREMENT_FILE"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}; value=${line#*=}
    [ "$key" != "$line" ] || return 1
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen$key "
    case "$key" in
      harness) FM_CODEX_REQUIREMENT_HARNESS=$value ;;
      home) FM_CODEX_REQUIREMENT_HOME=$value ;;
      spawn_gen) FM_CODEX_REQUIREMENT_SPAWN_GEN=$value ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$FM_CODEX_REQUIREMENT_HARNESS" = codex ] \
    && case "$FM_CODEX_REQUIREMENT_HOME" in /*) true ;; *) false ;; esac \
    && case "$FM_CODEX_REQUIREMENT_HOME" in *$'\n'*|*$'\r'*) false ;; *) true ;; esac \
    && fm_codex_spawn_generation_valid "$FM_CODEX_REQUIREMENT_SPAWN_GEN"
}

fm_codex_home_binding_requirement_present() { # <state-dir>
  [ -e "$1/$FM_CODEX_HOME_BINDING_REQUIREMENT_FILE" ] \
    || [ -L "$1/$FM_CODEX_HOME_BINDING_REQUIREMENT_FILE" ] \
    || [ -e "$1/$FM_CODEX_HOME_BINDING_FILE" ] \
    || [ -L "$1/$FM_CODEX_HOME_BINDING_FILE" ]
}

fm_codex_home_binding_requirement_clear() { # <state-dir>
  local state=$1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  rm -f -- "$state/$FM_CODEX_HOME_BINDING_REQUIREMENT_FILE" \
    "$state/$FM_CODEX_HOME_BINDING_FILE"
}

fm_codex_session_id_valid() { # <uuid>
  case "$1" in
    [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]) return 0 ;;
    *) return 1 ;;
  esac
}

fm_codex_session_id_for_pid() { # <pid>; prints the one exported Codex session id
  local pid=$1 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} file entry session=
  case "$pid" in *[!0-9]*|''|0|1) return 1 ;; esac
  file="$proc_root/$pid/environ"
  [ -r "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r -d '' entry; do
    case "$entry" in
      CODEX_SESSION_ID=*)
        [ -z "$session" ] || return 1
        session=${entry#CODEX_SESSION_ID=}
        ;;
    esac
  done < "$file"
  fm_codex_session_id_valid "$session" || return 1
  printf '%s\n' "$session"
}

fm_codex_host_agent_matches() { # <pid>; prove the host-side process is Codex, never a bare interpreter
  local pid=$1 comm args argv0
  FM_CODEX_HOST_MATCH_REASON=
  case "$pid" in *[!0-9]*|''|0|1) FM_CODEX_HOST_MATCH_REASON='reject:invalid-pid'; return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || { FM_CODEX_HOST_MATCH_REASON='reject:not-live'; return 1; }
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) \
    || { FM_CODEX_HOST_MATCH_REASON='reject:comm-unreadable'; return 1; }
  args=$(ps -o args= -p "$pid" 2>/dev/null) \
    || { FM_CODEX_HOST_MATCH_REASON='reject:args-unreadable'; return 1; }
  argv0=$(fm_harness_argv0_for_pid "$pid" "$args")
  if ! fm_harness_process_matches "$comm" "$args" "$argv0" "$pid"; then
    FM_CODEX_HOST_MATCH_REASON=$FM_HARNESS_MATCH_REASON
    return 1
  fi
  if [ "$FM_HARNESS_MATCH_NAME" != codex ]; then
    FM_CODEX_HOST_MATCH_REASON="reject:harness-family=${FM_HARNESS_MATCH_NAME:-unknown}"
    return 1
  fi
  FM_CODEX_HOST_MATCH_REASON='accept:harness-family=codex'
  return 0
}

fm_codex_home_binding_publish() { # <state-dir> <home> <spawn-gen> <agent-pid> <codex-session-id>
  local state=$1 home=$2 spawn_gen=$3 pid=$4 session=$5 observed file tmp old_umask
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  case "$home$spawn_gen" in *$'\n'*|*$'\r'*) return 1 ;; esac
  fm_codex_home_binding_requirement_read "$state" \
    && [ "$FM_CODEX_REQUIREMENT_HOME" = "$home" ] \
    && [ "$FM_CODEX_REQUIREMENT_SPAWN_GEN" = "$spawn_gen" ] || return 1
  fm_codex_session_id_valid "$session" || return 1
  fm_codex_host_agent_matches "$pid" || return 1
  observed=$(fm_codex_session_id_for_pid "$pid") || return 1
  [ "$observed" = "$session" ] || return 1
  file="$state/$FM_CODEX_HOME_BINDING_FILE"
  old_umask=$(umask)
  umask 077
  tmp=$(mktemp "$state/.fm-codex-session-binding.XXXXXXXX") || { umask "$old_umask"; return 1; }
  umask "$old_umask"
  if ! {
    printf 'harness=codex\n'
    printf 'home=%s\n' "$home"
    printf 'spawn_gen=%s\n' "$spawn_gen"
    printf 'agent_pid=%s\n' "$pid"
    printf 'codex_session_id=%s\n' "$session"
  } > "$tmp" || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_codex_home_binding_read() { # <state-dir>; parses one complete private binding into FM_CODEX_BINDING_*
  local state=$1 file line key value seen=' '
  FM_CODEX_BINDING_HARNESS=
  FM_CODEX_BINDING_HOME=
  FM_CODEX_BINDING_SPAWN_GEN=
  FM_CODEX_BINDING_PID=
  FM_CODEX_BINDING_SESSION=
  file="$state/$FM_CODEX_HOME_BINDING_FILE"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}; value=${line#*=}
    [ "$key" != "$line" ] || return 1
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen$key "
    case "$key" in
      harness) FM_CODEX_BINDING_HARNESS=$value ;;
      home) FM_CODEX_BINDING_HOME=$value ;;
      spawn_gen) FM_CODEX_BINDING_SPAWN_GEN=$value ;;
      agent_pid) FM_CODEX_BINDING_PID=$value ;;
      codex_session_id) FM_CODEX_BINDING_SESSION=$value ;;
      *) return 1 ;;
    esac
  done < "$file"
}

fm_codex_home_binding_pid() { # <state-dir>; prints host agent pid when this tool proves the recorded binding
  local state=$1 file session
  FM_CODEX_BINDING_REASON=
  session=${CODEX_SESSION_ID:-}
  if ! fm_codex_session_id_valid "$session"; then
    FM_CODEX_BINDING_REASON='reject:no-codex-session-identity-in-environment'
    return 1
  fi
  fm_codex_home_binding_requirement_read "$state" \
    || { FM_CODEX_BINDING_REASON='reject:malformed-codex-binding-requirement'; return 1; }
  [ "$FM_CODEX_REQUIREMENT_HOME" = "${FM_HOME:-}" ] \
    || { FM_CODEX_BINDING_REASON='reject:codex-binding-requirement-home-mismatch'; return 1; }
  file="$state/$FM_CODEX_HOME_BINDING_FILE"
  [ -f "$file" ] && [ ! -L "$file" ] || { FM_CODEX_BINDING_REASON='reject:missing-codex-home-binding'; return 1; }
  fm_codex_home_binding_read "$state" || { FM_CODEX_BINDING_REASON='reject:malformed-codex-home-binding'; return 1; }
  case "$FM_CODEX_BINDING_PID" in
    *[!0-9]*|''|0|1) FM_CODEX_BINDING_REASON='reject:codex-home-binding-mismatch'; return 1 ;;
  esac
  [ "$FM_CODEX_BINDING_HARNESS" = codex ] && [ "$FM_CODEX_BINDING_HOME" = "${FM_HOME:-}" ] \
    && [ "$FM_CODEX_BINDING_SPAWN_GEN" = "$FM_CODEX_REQUIREMENT_SPAWN_GEN" ] \
    && [ "$FM_CODEX_BINDING_SESSION" = "$session" ] \
    && fm_codex_session_id_valid "$FM_CODEX_BINDING_SESSION" || {
      FM_CODEX_BINDING_REASON='reject:codex-home-binding-mismatch'; return 1; }
  # shellcheck disable=SC2034 # Read by lock callers that need the refusal evidence.
  FM_CODEX_BINDING_REASON='accept:codex-session-home-binding'
  printf '%s\n' "$FM_CODEX_BINDING_PID"
}

fm_codex_home_binding_pid_alive() { # <state-dir> <pid>; liveness for a binding another session must respect
  local state=$1 expected_pid=$2 observed
  case "$expected_pid" in *[!0-9]*|''|0|1) return 1 ;; esac
  fm_codex_home_binding_requirement_read "$state" || return 1
  [ "$FM_CODEX_REQUIREMENT_HOME" = "${FM_HOME:-}" ] || return 1
  fm_codex_home_binding_read "$state" || return 1
  [ "$FM_CODEX_BINDING_HARNESS" = codex ] && [ "$FM_CODEX_BINDING_HOME" = "${FM_HOME:-}" ] \
    && [ "$FM_CODEX_BINDING_SPAWN_GEN" = "$FM_CODEX_REQUIREMENT_SPAWN_GEN" ] \
    && [ "$FM_CODEX_BINDING_PID" = "$expected_pid" ] \
    && fm_codex_session_id_valid "$FM_CODEX_BINDING_SESSION" \
    && fm_codex_host_agent_matches "$FM_CODEX_BINDING_PID" \
    && observed=$(fm_codex_session_id_for_pid "$FM_CODEX_BINDING_PID") \
    && [ "$observed" = "$FM_CODEX_BINDING_SESSION" ]
}

# Print the process argv[0] when Linux exposes it, otherwise use the first
# token from ps args.  The fallback intentionally differs from Cursor's
# argv0 helper: a session-lock matcher has ps args in hand and must preserve
# that platform evidence when a portable test fixture has no /proc entry.
fm_harness_argv0_for_pid() {  # <pid> <args>
  local pid=$1 args=$2 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} argv0=
  if [ -r "$proc_root/$pid/cmdline" ]; then
    IFS= read -r -d '' argv0 < "$proc_root/$pid/cmdline" || true
  fi
  printf '%s' "${argv0:-${args%% *}}"
}

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

fm_codex_system_home() {
  local home
  home=$(unset HOME; CDPATH='' builtin cd ~ 2>/dev/null && pwd -P) || return 1
  case "$home" in ''|/) return 1 ;; esac
  printf '%s\n' "$home"
}

fm_codex_canonical_leaf_path() {  # <path>
  local path=$1 directory leaf canonical_directory
  case "$path" in /*) ;; *) return 1 ;; esac
  directory=${path%/*}
  leaf=${path##*/}
  [ -n "$directory" ] && [ -n "$leaf" ] || return 1
  canonical_directory=$(CDPATH='' builtin cd -P -- "$directory" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$canonical_directory" "$leaf"
}

fm_codex_nvm_node_root_for_path() {  # <path>
  local path system_home rest version normalized major minor patch extra
  path=$(fm_codex_canonical_leaf_path "$1") || return 1
  system_home=$(fm_codex_system_home) || return 1
  case "$path" in "$system_home"/.nvm/versions/node/*/*) ;; *) return 1 ;; esac
  rest=${path#"$system_home/.nvm/versions/node/"}
  version=${rest%%/*}
  normalized=${version#v}
  IFS=. read -r major minor patch extra <<< "$normalized"
  case "$major:$minor:$patch:$extra" in *[!0-9:]*) return 1 ;; esac
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  printf '%s\n' "$system_home/.nvm/versions/node/$version"
}

fm_codex_nvm_install_matches() {  # <path>
  local path=$1 node_root script launcher target
  path=$(fm_codex_canonical_leaf_path "$path") || return 1
  node_root=$(fm_codex_nvm_node_root_for_path "$path") || return 1
  script="$node_root/lib/node_modules/@openai/codex/bin/codex.js"
  launcher="$node_root/bin/codex"
  [ -f "$script" ] && [ ! -L "$script" ] && [ -x "$script" ] || return 1
  [ -L "$launcher" ] || return 1
  target=$(readlink "$launcher" 2>/dev/null) || return 1
  case "$target" in
    ../lib/node_modules/@openai/codex/bin/codex.js|"$script") return 0 ;;
    *) return 1 ;;
  esac
}

fm_codex_script_path_matches() {  # <path>
  local path=$1 node_root
  path=$(fm_codex_canonical_leaf_path "$path") || return 1
  node_root=$(fm_codex_nvm_node_root_for_path "$path") || return 1
  case "$path" in
    "$node_root/bin/codex"|"$node_root/lib/node_modules/@openai/codex/bin/codex.js")
      fm_codex_nvm_install_matches "$path" ;;
    *) return 1 ;;
  esac
}

fm_codex_installed_executable_path_matches() {  # <path>
  local path=$1 node_root system_home
  path=$(fm_codex_canonical_leaf_path "$path") || return 1
  if node_root=$(fm_codex_nvm_node_root_for_path "$path"); then
    fm_codex_nvm_install_matches "$path" || return 1
    case "$path" in
      "$node_root"/lib/node_modules/@openai/codex/vendor/*/bin/codex) return 0 ;;
      "$node_root"/lib/node_modules/@openai/codex/node_modules/@openai/codex-*/vendor/*/bin/codex) return 0 ;;
    esac
  fi
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 1
  system_home=$(fm_codex_system_home) || return 1
  case "$path" in
    "$system_home"/.vscode/extensions/openai.chatgpt-*-darwin-*/bin/macos-*/codex) return 0 ;;
    /Applications/ChatGPT.app/Contents/Resources/codex) return 0 ;;
    "$system_home"/Applications/ChatGPT.app/Contents/Resources/codex) return 0 ;;
    *) return 1 ;;
  esac
}

fm_codex_executable_identity_matches() {  # <pid> <comm>
  local pid=$1 comm=$2 proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} executable= base
  case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
  base=$(basename -- "$comm")
  case "$base" in codex|-codex) ;; *) return 1 ;; esac
  if [ -L "$proc_root/$pid/exe" ]; then
    executable=$(readlink "$proc_root/$pid/exe" 2>/dev/null) || return 1
    fm_codex_installed_executable_path_matches "$executable"
    return
  fi
  [ "$proc_root" = /proc ] && [ "$(uname -s 2>/dev/null)" = Darwin ] || return 1
  case "$comm" in
    /*) [ -f "$comm" ] && [ ! -L "$comm" ] && [ -x "$comm" ] \
      && fm_codex_installed_executable_path_matches "$comm" ;;
    *) return 1 ;;
  esac
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
# The last accepted or rejected structural check.  Callers use this only for
# a refusal diagnostic; it is deliberately not lock or dispatch authority.
FM_HARNESS_MATCH_REASON=
FM_HARNESS_MATCH_NAME=
fm_harness_process_matches() {  # <comm> <args> [argv0] [pid]
  local comm=$1 args=$2 base argv0 name token pid=${4:-}
  local -a words
  FM_HARNESS_IS_CLAUDE=0
  FM_HARNESS_MATCH_REASON=
  FM_HARNESS_MATCH_NAME=
  base=$(basename -- "$comm")
  argv0=${3:-${args%% *}}
  case "$base" in
    codex|-codex)
      if fm_codex_executable_identity_matches "$pid" "$comm"; then
        FM_HARNESS_MATCH_NAME=codex
        FM_HARNESS_MATCH_REASON="accept:verified-codex-executable observed-basename=$base"
        return 0
      fi
      FM_HARNESS_MATCH_REASON="reject:unverified-codex-launcher observed-basename=$base"
      return 1
      ;;
    *codex*) FM_HARNESS_MATCH_REASON="reject:non-exact-codex-basename=$base"; return 1 ;;
  esac
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in
      *claude*) name=claude ;;
      *opencode*) name=opencode ;;
      *grok*) name=grok ;;
      *kimi*) name=kimi ;;
      pi-signed) name=pi-signed ;;
      pi) name=pi ;;
      *) FM_HARNESS_MATCH_REASON='reject:unclassified-basename'; return 1 ;;
    esac
    [ "$name" != claude ] || FM_HARNESS_IS_CLAUDE=1
    FM_HARNESS_MATCH_NAME=$name
    FM_HARNESS_MATCH_REASON="accept:basename=$base"
    return 0
  fi
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    if [ "$name" != codex ]; then
      [ "$name" != claude ] || FM_HARNESS_IS_CLAUDE=1
      FM_HARNESS_MATCH_NAME=$name
      FM_HARNESS_MATCH_REASON="accept:path-component=$name"
      return 0
    fi
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if [ -n "$args" ]; then
        read -r -a words <<< "$args"
        token=${words[1]:-}
        case "$token" in ''|-*) ;;
          *)
            if fm_codex_script_path_matches "$token"; then
              FM_HARNESS_MATCH_NAME=codex
              FM_HARNESS_MATCH_REASON='accept:exact-codex-script'
              return 0
            elif name=$(fm_harness_path_name "$token") && [ "$name" != codex ]; then
              [ "$name" != claude ] || FM_HARNESS_IS_CLAUDE=1
              FM_HARNESS_MATCH_NAME=$name
              FM_HARNESS_MATCH_REASON="accept:interpreter-script-component=$name"
              return 0
            fi
            ;;
        esac
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  if fm_cursor_process_matches "$comm" "$args" "$argv0"; then
    FM_HARNESS_MATCH_NAME=cursor
    FM_HARNESS_MATCH_REASON="accept:cursor-structural"
    return 0
  fi
  FM_HARNESS_MATCH_REASON="reject:basename,path-component,interpreter-args,cursor-structural"
  return 1
}

# Print a read-only, shell-escaped account of the ancestry inspection for PID
# $1 (or this shell).  This is the diagnostic owner for both the lock refusal
# and fm-harness's unknown result, so the evidence and matcher cannot drift.
# A successful diagnostic means the inspection completed; result=none remains
# a fail-closed absence of verified harness evidence.
fm_harness_ancestry_diagnostic() {  # [pid]
  local explicit_pid=${1:-} pid=${1:-$$} comm args ppid hop=0 matched=0 extending=0 argv0 state
  case "$pid" in ''|*[!0-9]*|0|1) printf 'result=invalid-start-pid pid=%q\n' "$pid"; return 1 ;; esac
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}
  if [ -z "$explicit_pid" ] && [ -n "${FM_HOME:-}" ] \
    && fm_codex_home_binding_requirement_present "$state"; then
    if ! fm_codex_home_binding_pid "$state" >/dev/null; then
      printf 'schema=fm-harness-ancestry-diagnostic.v1 start_pid=%s max_hops=0\n' "$pid"
      printf 'result=required-codex-binding-rejected reason=%q\n' "${FM_CODEX_BINDING_REASON:-reject:unknown-codex-binding}"
      return 0
    fi
  fi
  printf 'schema=fm-harness-ancestry-diagnostic.v1 start_pid=%s max_hops=16\n' "$pid"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    hop=$((hop + 1))
    if ! comm=$(ps -o comm= -p "$pid" 2>/dev/null); then
      printf 'hop=%s pid=%s result=unreadable-process\n' "$hop" "$pid"
      break
    fi
    args=$(ps -o args= -p "$pid" 2>/dev/null || true)
    argv0=$(fm_harness_argv0_for_pid "$pid" "$args")
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    if fm_harness_process_matches "$comm" "$args" "$argv0" "$pid"; then
      printf 'hop=%s pid=%s ppid=%q comm=%q argv0=%q args=redacted match=%q\n' \
        "$hop" "$pid" "$ppid" "$comm" "$argv0" "$FM_HARNESS_MATCH_REASON"
      matched=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    else
      printf 'hop=%s pid=%s ppid=%q comm=%q argv0=%q args=redacted match=%q\n' \
        "$hop" "$pid" "$ppid" "$comm" "$argv0" "$FM_HARNESS_MATCH_REASON"
      [ "$extending" -eq 0 ] || break
    fi
    case "$ppid" in ''|*[!0-9]*|0|1) break ;; esac
    pid=$ppid
  done
  if [ "$matched" -eq 1 ]; then
    printf 'result=verified-harness-found\n'
  else
    printf 'result=no-verified-harness\n'
  fi
  return 0
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args argv0 extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    argv0=$(fm_harness_argv0_for_pid "$pid" "$args")
    if fm_harness_process_matches "$comm" "$args" "$argv0" "$pid"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost='' state
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}
  if [ -n "${FM_HOME:-}" ] && pid=$(fm_codex_home_binding_pid "$state"); then
    printf '%s\n' "$pid"
    return 0
  fi
  if [ -n "${FM_HOME:-}" ] && fm_codex_home_binding_requirement_present "$state"; then
    return 1
  fi
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args argv0 state
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}
  if [ -n "${FM_HOME:-}" ] && fm_codex_home_binding_pid_alive "$state" "$pid"; then
    return 0
  fi
  if [ -n "${FM_HOME:-}" ] && fm_codex_home_binding_requirement_present "$state"; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  argv0=$(fm_harness_argv0_for_pid "$pid" "$args")
  fm_harness_process_matches "$comm" "$args" "$argv0" "$pid"
}

# True when state dir $1 holds a session lock whose pid is ANY harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. Membership is the honest test of that question, because the
# lock owner sits at an unknown depth in a contiguous Claude run - it is the
# outermost pid when the hook fires inside the session's own nested worker chain,
# and an inner pid when a harness-named daemon parents the session. A missing
# lock, a malformed lock, a lock held by a harness outside this ancestry, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid bound_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  if bound_pid=$(fm_codex_home_binding_pid "$state") && [ "$bound_pid" = "$lock_pid" ]; then
    return 0
  fi
  if [ -n "${FM_HOME:-}" ] && fm_codex_home_binding_requirement_present "$state"; then
    return 1
  fi
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
