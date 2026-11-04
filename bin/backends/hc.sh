#!/usr/bin/env bash
# bin/backends/hc.sh - the herdr-core (`hc`) session-provider adapter (EXPERIMENTAL).
#
# herdr-core is the terminal core under Herdr.app: a per-user daemon that keeps
# terminals alive and answers a JSON CLI (`hc run|get|ls|read|send|keys|kill|rm`).
# It is not Herdr 1 (`herdr`, bin/backends/herdr.sh); the two share no socket,
# no id space, and no CLI. Like tmux, hc is a session provider ONLY: the
# worktree provider stays treehouse, driven by fm-spawn.sh through the same
# send/current-path primitives it uses for tmux. docs/hc-backend.md owns the
# user-facing mechanics and limits; this header owns the adapter's design.
# Sourced only through bin/fm-backend.sh's fm_backend_source in normal
# operation; the unit tests source it directly.
#
# docs/hc-backend.md "Runtime auto-detection" owns selection; an open app
# window alone never selects hc. fm_backend_detect owns the check order.
#
# Target string shape: "<session>:<address>". <session> is the hc session the
# terminal lives in (HC_SESSION at spawn time, `default` when unset) and
# <address> is hc's own terminal address (`t7`). Every call re-exports exactly
# that HC_SESSION, so a target keeps naming the core it was created on even when
# the caller's ambient HC_SESSION differs. Measured on hc 0.1.13: HC_SESSION
# wins over an inherited HC_TERMINAL_SOCKET, so a firstmate running inside an hc
# terminal still reaches the recorded core.
#
# Identity: each task terminal carries the labels firstmate.task=<window-label>
# and firstmate.home=<hometag> (bin/fm-backend-hometag-lib.sh). Operations that
# receive an expected label refuse a terminal whose labels do not match, so a
# recorded address can never steer input into another home's terminal. hc
# names are not used: they allow only 1-32 of [a-z0-9_-], narrower than task ids.
#
# Visibility in Herdr.app: the app shows a terminal that carries
# herdr.space=<id> and herdr.tab=<id> labels, and an unknown id becomes a new
# space or tab. create_task sets herdr.space=FM_HC_SPACE (default
# fm-<hometag>) and herdr.tab=<scoped label>, so a home's tasks group in one
# space with one tab each. Naming the space needs the app window and is not done.
#
# Measured limits on hc 0.1.13 and 0.1.14 (docs/hc-backend.md "Limits"):
#   - `hc send` always presses Enter after pasting. There is no paste without
#     submit, so hc cannot type without submitting. `hc send --wait` reports
#     the turn the send started natively, which is what send_text_submit reads.
#   - hc reports one foreground process per terminal (`foreground` in
#     `hc get`), not a process group; when that process is a launcher,
#     agent_state also reads the rest of its process group from `ps`, on the
#     terminal's own machine.
#   - hc has no event push this adapter consumes; supervision polls like tmux.
#
# Binary gate: FM_HC_BIN wins, else `herdr-core`, else `hc` (the release
# asset's name and its CLI alias). `<bin> --version` must report `hc x.y.z`
# at or above FM_BACKEND_HC_MIN_VERSION, and container_ensure additionally
# proves the session speaks protocol generation 1 through `hello`.
#
# Placement on another machine (docs/hc-backend.md "Workers on another
# machine"): config/hc-machine, or fm-spawn's --hc-machine, starts a ship or
# scout terminal with `hc run --on <machine>` on a machine the local core
# already reaches. Its address is `<machine>/t7`, so a target reads
# "<session>:<machine>/t7" and every terminal call (get, read, send, keys,
# kill, rm) goes through the local core exactly as for a local terminal. What
# is not a terminal call - the worktree's git state, the process-group scan,
# files - runs on that machine through `hc exec --on`, never against this
# machine's filesystem or process table: fm_backend_hc_remote_exec is the one
# transport and reports a transport failure (exit 255) apart from the
# program's own exit code, so a caller can refuse instead of reading an
# unreachable machine as an empty answer. Teardown's worktree process reap and
# the staged launch file's removal run there the same way. A remote foreground pid is never
# passed to the local process classifier, which would read whatever local
# process holds that number.

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"

# The verified floor: the oldest herdr-core release every adapter surface
# (including `send --wait` and the `hello` handshake) was exercised against.
FM_BACKEND_HC_MIN_VERSION=0.1.14

# The one protocol generation this adapter speaks.
FM_BACKEND_HC_GENERATION=1

# Placement floors: the oldest local binary and the oldest hc reported for the
# other machine that placement (run/exec/file --on, machine ls state and
# version) was exercised against (docs/verification/runtime-backends.md).
FM_BACKEND_HC_PLACEMENT_MIN_VERSION=0.1.16
FM_BACKEND_HC_REMOTE_MIN_VERSION=0.1.18

# The hc session a new task is created on: the caller's HC_SESSION, else hc's
# own default session name.
fm_backend_hc_session() {
  printf '%s' "${HC_SESSION:-default}"
}

# fm_backend_hc_bin: the resolved herdr-core binary path, or failure. The
# release asset's own name is `herdr-core`; `hc` is its CLI alias. FM_HC_BIN
# wins so tests and the lab can pin a build; version_check still proves the
# resolved file is herdr-core and no other tool.
fm_backend_hc_bin() {
  if [ -n "${FM_HC_BIN:-}" ]; then
    [ -x "$FM_HC_BIN" ] || return 1
    printf '%s' "$FM_HC_BIN"
    return 0
  fi
  command -v herdr-core 2>/dev/null || command -v hc 2>/dev/null
}

# fm_backend_hc_version_number: x.y.z as one comparable integer; a missing or
# non-numeric part reads as 0.
fm_backend_hc_version_number() {  # <x.y.z>
  local ver=$1 major rest minor patch
  major=${ver%%.*}
  rest=${ver#*.}
  [ "$rest" != "$ver" ] || rest=0
  minor=${rest%%.*}
  case "$rest" in
    *.*) patch=${rest#*.} ;;
    *) patch=0 ;;
  esac
  patch=${patch%%[^0-9]*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  case "$patch" in ''|*[!0-9]*) patch=0 ;; esac
  printf '%s' "$((10#$major * 1000000 + 10#$minor * 1000 + 10#$patch))"
}

# fm_backend_hc_version_at_least: whether <x.y.z> is at or above <floor>.
fm_backend_hc_version_at_least() {  # <x.y.z> <floor>
  [ "$(fm_backend_hc_version_number "$1")" -ge "$(fm_backend_hc_version_number "$2")" ]
}

# fm_backend_hc_local_version: the resolved binary's own x.y.z, or failure
# with the reason on stderr. `<bin> --version` must print `hc x.y.z`.
fm_backend_hc_local_version() {
  local bin raw ver
  bin=$(fm_backend_hc_bin) || {
    echo "error: backend=hc selected but no 'herdr-core' or 'hc' binary was found on PATH (install Herdr Core per docs/hc-backend.md or set FM_HC_BIN)" >&2
    return 1
  }
  raw=$("$bin" --version 2>/dev/null) \
    || { echo "error: '$bin --version' failed; is herdr-core installed correctly?" >&2; return 1; }
  case "$raw" in
    'hc '[0-9]*.[0-9]*.[0-9]*)
      ver=${raw#hc }
      ver=${ver%%[[:space:]]*}
      ;;
    *)
      echo "error: expected 'hc x.y.z' from '$bin --version' but got '$raw'; refusing to use a binary that is not Herdr Core" >&2
      return 1
      ;;
  esac
  printf '%s' "$ver"
}

# fm_backend_hc_version_check: refuse loudly on a missing, misnamed, or
# older-than-verified binary.
fm_backend_hc_version_check() {
  local ver
  ver=$(fm_backend_hc_local_version) || return 1
  if ! fm_backend_hc_version_at_least "$ver" "$FM_BACKEND_HC_MIN_VERSION"; then
    echo "error: herdr-core $ver is older than the verified minimum $FM_BACKEND_HC_MIN_VERSION; update herdr-core before using backend=hc" >&2
    return 1
  fi
  return 0
}

# fm_backend_hc_env_run: run the resolved binary with exactly <session>'s env
# pins. Ambient HC_TERMINAL_* routing markers are always stripped. An
# inherited HC_SOCKET is stripped because hc lets it win over HC_SESSION;
# FM_HC_SOCKET is the deliberate pin used by tests and the lab instead.
fm_backend_hc_env_run() {  # <session> <args...>
  local session=$1 bin
  shift
  bin=$(fm_backend_hc_bin) || {
    echo "error: backend=hc selected but no 'herdr-core' or 'hc' binary was found on PATH (install Herdr Core per docs/hc-backend.md or set FM_HC_BIN)" >&2
    return 1
  }
  if [ -n "${FM_HC_SOCKET:-}" ]; then
    env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE \
      HC_SESSION="$session" HC_SOCKET="$FM_HC_SOCKET" "$bin" "$@"
  else
    env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SOCKET \
      HC_SESSION="$session" "$bin" "$@"
  fi
}

# fm_backend_hc_cli: run hc against exactly <session>.
# An invalid or empty session is refused: an empty HC_SESSION would let hc
# fall back to whatever core the caller's environment names. stdin is
# detached so hc never consumes a caller's loop input.
fm_backend_hc_cli() {  # <session> <args...>
  local session=$1
  shift
  fm_backend_hc_atom_valid "$session" || { echo "error: refusing hc session '$session'" >&2; return 1; }
  fm_backend_hc_env_run "$session" "$@" </dev/null
}

fm_backend_hc_atom_valid() {  # <value>
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# An hc terminal address: `t7`, or `<machine>/t7` for a terminal another
# machine holds (`hc run --on`).
fm_backend_hc_address_valid() {  # <value>
  local local_part=$1
  case "$1" in
    */*/*) return 1 ;;
    */*)
      fm_backend_hc_atom_valid "${1%%/*}" || return 1
      local_part=${1#*/}
      ;;
  esac
  case "$local_part" in
    t*) ;;
    *) return 1 ;;
  esac
  case "${local_part#t}" in
    ''|*[!0123456789abcdefghijklmnopqrstuvwxyz]*) return 1 ;;
  esac
}

# fm_backend_hc_address_machine: the machine a valid address names, or
# nothing for a terminal on the local core's own machine.
fm_backend_hc_address_machine() {  # <address>
  case "$1" in
    */*) printf '%s' "${1%%/*}" ;;
  esac
}

# fm_backend_hc_parse_target: split "<session>:<address>" into
# FM_BACKEND_HC_SESSION and FM_BACKEND_HC_ADDRESS, or return 1.
fm_backend_hc_parse_target() {  # <target>
  local target=${1:-}
  FM_BACKEND_HC_SESSION=
  FM_BACKEND_HC_ADDRESS=
  case "$target" in
    *:*:*|:*|*:) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  fm_backend_hc_atom_valid "${target%%:*}" || return 1
  fm_backend_hc_address_valid "${target#*:}" || return 1
  FM_BACKEND_HC_SESSION=${target%%:*}
  FM_BACKEND_HC_ADDRESS=${target#*:}
}

fm_backend_hc_scoped_label() {  # <window-label>
  printf '%s-%s' "$(fm_backend_hometag)" "$1"
}

# fm_backend_hc_get: `hc get --json` of the parsed target. Status 3 is hc's
# structured not_found; any other failure is an unreadable core.
fm_backend_hc_get() {  # <target>
  fm_backend_hc_parse_target "$1" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" get --json "$FM_BACKEND_HC_ADDRESS" 2>/dev/null
}

# fm_backend_hc_endpoint_state: classify <target> against a fresh `hc get`.
# Prints exactly one of: ready, finished, absent, foreign, unreadable. A
# terminal is `foreign` when [expected-label] is given and its labels do not
# carry this home's labels for it; `*` accepts any task label of this home.
fm_backend_hc_endpoint_state() {  # <target> [expected-label]
  local target=$1 expected=${2:-} json rc fields state task home
  fm_backend_hc_parse_target "$target" || { printf 'unreadable'; return 0; }
  json=$(fm_backend_hc_get "$target")
  rc=$?
  if [ "$rc" -eq 3 ]; then printf 'absent'; return 0; fi
  [ "$rc" -eq 0 ] || { printf 'unreadable'; return 0; }
  fields=$(printf '%s' "$json" | jq -r '[.state // "", .labels["firstmate.task"] // "", .labels["firstmate.home"] // ""] | @tsv' 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  IFS=$'\t' read -r state task home <<EOF
$fields
EOF
  if [ -n "$expected" ] && { [ "$home" != "$(fm_backend_hometag)" ] \
    || { [ "$expected" = '*' ] && [ -z "$task" ]; } \
    || { [ "$expected" != '*' ] && [ "$task" != "$expected" ]; }; }; then
    printf 'foreign'
    return 0
  fi
  case "$state" in
    live) printf 'ready' ;;
    finished) printf 'finished' ;;
    *) printf 'unreadable' ;;
  esac
}

# Also leaves FM_BACKEND_HC_SESSION/ADDRESS set in the caller's shell, which
# the command-substituted state read above cannot do.
fm_backend_hc_target_ready() {  # <target> [expected-label]
  [ "$(fm_backend_hc_endpoint_state "$1" "${2:-}")" = ready ] && fm_backend_hc_parse_target "$1"
}

# fm_backend_hc_hello: the generation handshake for <session> over `hc
# connect`. Prints the negotiated generation, nothing on failure.
fm_backend_hc_hello() {  # <session>
  local session=$1 out gen
  out=$(printf '{"jsonrpc":"2.0","method":"hello","params":{"generation":%s},"id":1}\n' \
      "$FM_BACKEND_HC_GENERATION" \
    | fm_backend_hc_env_run "$session" connect --session "$session" 2>/dev/null) || return 1
  gen=$(printf '%s' "$out" | jq -r '.result.generation // empty' 2>/dev/null)
  [ -n "$gen" ] || return 1
  printf '%s' "$gen"
}

# fm_backend_hc_container_ensure: prove the binary is herdr-core at the
# verified floor, make sure the session's core answers (hc starts its own
# core on first use) and speaks protocol generation 1, then print the
# session name.
fm_backend_hc_container_ensure() {
  local session gen
  fm_backend_hc_version_check || return 1
  command -v jq >/dev/null 2>&1 \
    || { echo "error: backend=hc selected but 'jq' is not installed (required to parse hc's JSON output)" >&2; return 1; }
  session=$(fm_backend_hc_session)
  fm_backend_hc_atom_valid "$session" || { echo "error: refusing hc session name '$session'" >&2; return 1; }
  fm_backend_hc_cli "$session" server status --json >/dev/null 2>&1 \
    || { echo "error: 'hc server status' failed for session '$session'; is herdr-core installed and startable?" >&2; return 1; }
  gen=$(fm_backend_hc_hello "$session") || {
    echo "error: herdr-core session '$session' did not answer the hello handshake; is the core reachable?" >&2
    return 1
  }
  if [ "$gen" != "$FM_BACKEND_HC_GENERATION" ]; then
    echo "error: herdr-core session '$session' speaks protocol generation '$gen', but this adapter requires generation $FM_BACKEND_HC_GENERATION" >&2
    return 1
  fi
  printf '%s' "$session"
}

# --- Placement on another machine -------------------------------------------

# fm_backend_hc_placement_config: read config/hc-machine into
# FM_BACKEND_HC_PLACE_MACHINE, FM_BACKEND_HC_PLACE_FIRSTMATE_AS,
# FM_BACKEND_HC_PLACE_PROJECTS, and the optional
# FM_BACKEND_HC_PLACE_CLAUDE_CONFIG. Returns 1 when the file is absent and 2,
# with the reason on stderr, when it exists but is not exactly the shape
# docs/configuration.md "hc worker placement" documents, so a malformed file
# never quietly means "start workers here".
fm_backend_hc_placement_config() {  # <file>
  local file=$1 line key value n=0 machine='' as='' projects='' claude_config=''
  FM_BACKEND_HC_PLACE_MACHINE=
  FM_BACKEND_HC_PLACE_FIRSTMATE_AS=
  FM_BACKEND_HC_PLACE_PROJECTS=
  FM_BACKEND_HC_PLACE_CLAUDE_CONFIG=
  [ -e "$file" ] || [ -L "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file is not a readable regular file" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    if [ -z "$machine" ]; then
      case "$line" in
        *[[:space:]]*) echo "error: $file line $n: the first line must be the machine name alone" >&2; return 2 ;;
      esac
      machine=$line
      continue
    fi
    key=${line%%[[:space:]]*}
    value=${line#"$key"}
    value=${value#"${value%%[![:space:]]*}"}
    [ -n "$value" ] || { echo "error: $file line $n: '$key' needs a value" >&2; return 2; }
    case "$key" in
      firstmate-as)
        [ -z "$as" ] || { echo "error: $file line $n: firstmate-as appears twice" >&2; return 2; }
        as=$value
        ;;
      projects)
        [ -z "$projects" ] || { echo "error: $file line $n: projects appears twice" >&2; return 2; }
        projects=$value
        ;;
      claude-config)
        [ -z "$claude_config" ] || { echo "error: $file line $n: claude-config appears twice" >&2; return 2; }
        claude_config=$value
        ;;
      *) echo "error: $file line $n: unknown key '$key' (expected firstmate-as, projects, or claude-config)" >&2; return 2 ;;
    esac
  done < "$file"
  [ -n "$machine" ] || { echo "error: $file names no machine" >&2; return 2; }
  fm_backend_hc_atom_valid "$machine" || { echo "error: $file: '$machine' is not a usable hc machine name" >&2; return 2; }
  [ -n "$as" ] || { echo "error: $file: firstmate-as is required (what $machine's own hc calls this machine)" >&2; return 2; }
  fm_backend_hc_atom_valid "$as" || { echo "error: $file: firstmate-as '$as' is not a usable hc machine name" >&2; return 2; }
  projects=${projects%/}
  claude_config=${claude_config%/}
  [ -n "$projects" ] || { echo "error: $file: projects is required (the directory on $machine holding the project clones)" >&2; return 2; }
  fm_backend_hc_remote_path_valid "$projects" || { echo "error: $file: projects '$projects' must be an absolute path without '.', '..', quotes, or control characters" >&2; return 2; }
  if [ -n "$claude_config" ] && ! fm_backend_hc_remote_path_valid "$claude_config"; then
    echo "error: $file: claude-config '$claude_config' must be an absolute path without '.', '..', quotes, or control characters" >&2
    return 2
  fi
  FM_BACKEND_HC_PLACE_MACHINE=$machine
  FM_BACKEND_HC_PLACE_FIRSTMATE_AS=$as
  FM_BACKEND_HC_PLACE_PROJECTS=$projects
  FM_BACKEND_HC_PLACE_CLAUDE_CONFIG=$claude_config
  return 0
}

# An absolute path on another machine that is safe to hand to a shell there
# quoted and to compare as a string: no relative components, quotes, or
# control characters.
fm_backend_hc_remote_path_valid() {  # <path>
  local LC_ALL=C
  case "$1" in
    /) return 1 ;;
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *"'"*|*'"'*|*[![:print:]]*) return 1 ;;
  esac
  case "$1/" in
    */./*|*/../*|*//*) return 1 ;;
  esac
  return 0
}

# fm_backend_hc_b64_decode: decode base64 <text> into <file> byte for byte.
# jq's @base64d is not used: it turns bytes that are not UTF-8 into U+FFFD, so
# two different patches could read alike. Fails on input that is not base64.
fm_backend_hc_b64_decode() {  # <text> <file>
  if [ -z "$1" ]; then : > "$2"; return 0; fi
  if printf '%s' "$1" | base64 --decode > "$2" 2>/dev/null; then return 0; fi
  printf '%s' "$1" | base64 -D > "$2" 2>/dev/null
}

# fm_backend_hc_remote_exec: run <argv> on <machine> through the <session>
# core (`hc exec --on`, no shell), printing the program's stdout and stderr
# byte for byte and returning its exit code. A transport failure - an unknown
# or unreachable machine, a timeout, a signal, truncated output, output that
# is not base64, or an answer that is not hc's exec result - prints the reason
# and returns 255, which no caller reads as an answer. <cwd> is `-` for that
# machine's home.
FM_BACKEND_HC_EXEC_FAILED=255
fm_backend_hc_remote_exec() {  # <session> <machine> <timeout-secs> <cwd|-> <argv...>
  local session=$1 machine=$2 timeout=$3 cwd=$4 out err_file out_file fields code signal timed_out truncated
  local -a cwd_args=()
  shift 4
  fm_backend_hc_atom_valid "$machine" || { echo "error: refusing hc machine name '$machine'" >&2; return 255; }
  case "$timeout" in ''|*[!0-9]*|0) timeout=60 ;; esac
  [ "$timeout" -le 600 ] || timeout=600
  [ "$cwd" = - ] || cwd_args=(--cwd "$cwd")
  err_file=$(mktemp "${TMPDIR:-/tmp}/fm-hc-exec.XXXXXX") || { echo "error: could not stage hc exec output" >&2; return 255; }
  out=$(fm_backend_hc_cli "$session" exec --json --on "$machine" ${cwd_args[@]+"${cwd_args[@]}"} \
    --timeout "$timeout" -- "$@" 2>"$err_file") || true
  fields=$(printf '%s' "$out" | jq -r 'if (.code | type) == "number" or .code == null
    then [(.code // "" | tostring), (.signal // "" | tostring), (.timed_out // false | tostring), (.truncated // false | tostring)] | join("\u001f")
    else empty end' 2>/dev/null)
  if [ -z "$fields" ]; then
    echo "error: hc exec on machine '$machine' did not run: $(tr '\n' ' ' < "$err_file")" >&2
    rm -f "$err_file"
    return 255
  fi
  IFS=$'\x1f' read -r code signal timed_out truncated <<EOF
$fields
EOF
  if [ "$timed_out" = true ] || [ "$truncated" = true ] || [ -z "$code" ] || [ -n "$signal" ]; then
    echo "error: hc exec on machine '$machine' did not finish cleanly (timed_out=$timed_out truncated=$truncated signal=${signal:-none})" >&2
    rm -f "$err_file"
    return 255
  fi
  out_file=$(mktemp "${TMPDIR:-/tmp}/fm-hc-exec.XXXXXX") || { rm -f "$err_file"; echo "error: could not stage hc exec output" >&2; return 255; }
  if ! fm_backend_hc_b64_decode "$(printf '%s' "$out" | jq -r '.stdout // ""' 2>/dev/null)" "$out_file" \
    || ! fm_backend_hc_b64_decode "$(printf '%s' "$out" | jq -r '.stderr // ""' 2>/dev/null)" "$err_file"; then
    rm -f "$out_file" "$err_file"
    echo "error: hc exec on machine '$machine' returned output that is not base64" >&2
    return 255
  fi
  cat "$out_file"
  cat "$err_file" >&2
  rm -f "$out_file" "$err_file"
  case "$code" in ''|*[!0-9]*) return 255 ;; esac
  [ "$code" -ne 255 ] || code=254
  return "$code"
}

# fm_backend_hc_remote_git: git -C <dir> on <machine>; exit 255 is transport.
fm_backend_hc_remote_git() {  # <session> <machine> <dir> <git args...>
  local session=$1 machine=$2 dir=$3
  shift 3
  fm_backend_hc_remote_exec "$session" "$machine" "${FM_HC_REMOTE_GIT_TIMEOUT:-300}" - git -C "$dir" "$@"
}

# fm_backend_hc_machine_ready: <machine> is added to <session>, connected, and
# reports an hc at or above FM_BACKEND_HC_REMOTE_MIN_VERSION, and the local
# binary is at or above FM_BACKEND_HC_PLACEMENT_MIN_VERSION. An exec first
# makes the core connect a machine it has not reached yet.
fm_backend_hc_machine_ready() {  # <session> <machine>
  local session=$1 machine=$2 local_ver json fields state ver
  local_ver=$(fm_backend_hc_local_version) || return 1
  if ! fm_backend_hc_version_at_least "$local_ver" "$FM_BACKEND_HC_PLACEMENT_MIN_VERSION"; then
    echo "error: herdr-core $local_ver on this machine is older than $FM_BACKEND_HC_PLACEMENT_MIN_VERSION, the oldest verified for placing workers on another machine; update it or keep this task local" >&2
    return 1
  fi
  fm_backend_hc_remote_exec "$session" "$machine" 30 - true >/dev/null 2>&1 || true
  json=$(fm_backend_hc_cli "$session" machine ls --json 2>/dev/null) \
    || { echo "error: 'hc machine ls' failed for session '$session'" >&2; return 1; }
  fields=$(printf '%s' "$json" | jq -r --arg m "$machine" \
    'first(.machines[]? | select(.name == $m) | [.state // "", .version // ""] | map(tostring) | join("\u001f")) // empty' 2>/dev/null)
  if [ -z "$fields" ]; then
    echo "error: hc machine '$machine' is not added to hc session '$session' on this machine (hc machine ls); add it with 'hc machine add' or keep this task local" >&2
    return 1
  fi
  IFS=$'\x1f' read -r state ver <<EOF
$fields
EOF
  if [ "$state" != connected ]; then
    echo "error: hc machine '$machine' is ${state:-in an unknown state}, not connected; refusing to place a worker there (never falling back to this machine)" >&2
    return 1
  fi
  case "$ver" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "error: hc machine '$machine' reports no usable hc version ('$ver'); refusing to place a worker there" >&2; return 1 ;;
  esac
  if ! fm_backend_hc_version_at_least "$ver" "$FM_BACKEND_HC_REMOTE_MIN_VERSION"; then
    echo "error: hc machine '$machine' runs hc $ver, older than $FM_BACKEND_HC_REMOTE_MIN_VERSION, the oldest verified for placed workers; update it there (hc machine update $machine) or keep this task local" >&2
    return 1
  fi
  return 0
}

# A remote's identity for comparing two clones of one project: host and path,
# lowercased, without scheme, user, port, or a trailing .git.
fm_backend_hc_url_key() {  # <url>
  local u=$1 host rest
  u=${u%/}
  u=${u%.git}
  case "$u" in
    *://*)
      u=${u#*://}
      u=${u#*@}
      host=${u%%/*}
      rest=${u#"$host"}
      u=${host%%:*}$rest
      ;;
    *@*:*)
      u=${u#*@}
      u=${u%%:*}/${u#*:}
      ;;
  esac
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

# fm_backend_hc_remote_clone_check: <clone> on <machine> is a git checkout's
# top level whose origin is the same remote as <local-project>'s origin. Git
# reports the top level by its physical path, so <clone> is resolved there
# first (a projects path under macOS /tmp is /private/tmp); on success the
# check prints that physical path for the caller to use as the clone.
fm_backend_hc_remote_clone_check() {  # <session> <machine> <clone> <local-project>
  local session=$1 machine=$2 clone=$3 project=$4 phys top rc local_url remote_url
  # shellcheck disable=SC2016 # expands on the other machine
  phys=$(fm_backend_hc_remote_exec "$session" "$machine" 60 - /bin/sh -c 'cd "$1" && pwd -P' sh "$clone" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    top=$(fm_backend_hc_remote_git "$session" "$machine" "$phys" rev-parse --show-toplevel 2>/dev/null) && rc=0 || rc=$?
  fi
  if [ "$rc" -eq 255 ]; then
    echo "error: could not reach hc machine '$machine' to check the project clone at $clone" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$phys" ] || [ "$top" != "$phys" ]; then
    echo "error: hc machine '$machine' has no clone of this project at $clone (clone it there first, from the same origin)" >&2
    return 1
  fi
  local_url=$(git -C "$project" remote get-url origin 2>/dev/null) \
    || { echo "error: $project has no origin remote to match against the clone on '$machine'" >&2; return 1; }
  remote_url=$(fm_backend_hc_remote_git "$session" "$machine" "$clone" remote get-url origin 2>/dev/null) \
    || { echo "error: the clone at $clone on '$machine' has no readable origin remote" >&2; return 1; }
  if [ "$(fm_backend_hc_url_key "$local_url")" != "$(fm_backend_hc_url_key "$remote_url")" ]; then
    echo "error: the clone at $clone on '$machine' tracks origin '$remote_url', not this project's '$local_url'" >&2
    return 1
  fi
  printf '%s\n' "$phys"
}

# fm_backend_hc_reverse_route_check: prove that <machine>'s own hc reaches
# THIS machine as <firstmate-as>, by having it read back a nonce written here
# under <state-dir>. A placed worker reaches its brief, status, and inbox only
# through that route.
fm_backend_hc_reverse_route_check() {  # <session> <machine> <firstmate-as> <state-dir>
  local session=$1 machine=$2 as=$3 state=$4 nonce probe seen rc
  nonce=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  case "$nonce" in ''|*[!0-9a-f]*) echo "error: could not draw a reverse-route nonce" >&2; return 1 ;; esac
  probe="$state/.hc-reverse-route.$nonce"
  printf '%s\n' "$nonce" > "$probe" || { echo "error: could not write the reverse-route probe under $state" >&2; return 1; }
  seen=$(fm_backend_hc_remote_exec "$session" "$machine" 60 - hc exec --on "$as" -- cat "$probe" 2>/dev/null) && rc=0 || rc=$?
  rm -f "$probe"
  if [ "$rc" -eq 0 ] && [ "$seen" = "$nonce" ]; then
    return 0
  fi
  if [ "$rc" -eq 255 ]; then
    echo "error: could not reach hc machine '$machine' to prove its route back to this machine" >&2
  else
    echo "error: hc on machine '$machine' does not reach this machine as '$as' (firstmate-as in config/hc-machine): a placed worker reads its instructions and reports through that route. On '$machine', add this machine with 'hc machine add <ssh-target> --name $as'." >&2
  fi
  return 1
}

# fm_backend_hc_claude_runs_check: `claude --version` succeeds on <machine> in
# the environment the placed launch gets: the login shell there
# (${SHELL:-/bin/sh} -l, stdin from /dev/null, bounded by the exec timeout),
# with CLAUDE_CONFIG_DIR=<claude-config> when configured, as the launch sets it.
fm_backend_hc_claude_runs_check() {  # <session> <machine> [claude-config]
  local session=$1 machine=$2 cfg=${3:-} out rc
  # shellcheck disable=SC2016 # expands on the other machine
  out=$(fm_backend_hc_remote_exec "$session" "$machine" 60 - /bin/sh -c '
    if [ -n "$1" ]; then
      FM_HC_CLAUDE_CONFIG=$1
      export FM_HC_CLAUDE_CONFIG
      exec "${SHELL:-/bin/sh}" -lc "CLAUDE_CONFIG_DIR=\"\$FM_HC_CLAUDE_CONFIG\" claude --version" </dev/null
    fi
    exec "${SHELL:-/bin/sh}" -lc "claude --version" </dev/null
  ' sh "$cfg" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || return 0
  if [ "$rc" -eq 255 ]; then
    echo "error: could not reach hc machine '$machine' to check that claude runs there" >&2
  else
    echo "error: claude does not run on hc machine '$machine' in its login shell (claude --version exited $rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)); install Claude Code there or put it on that login shell's PATH" >&2
  fi
  return 1
}

# fm_backend_hc_claude_trust_check: Claude Code on <machine> already trusts
# <clone> or an ancestor of <worktree> in the store the worker will read
# (<claude-config>/.claude.json when configured, else the login shell's
# CLAUDE_CONFIG_DIR, else ~/.claude.json). A linked worktree resolves trust
# through its primary checkout first (bin/fm-claude-trust.sh), so a clone the
# operator already opened Claude in carries every placed worktree. Read-only:
# nothing writes another machine's Claude store.
fm_backend_hc_claude_trust_check() {  # <session> <machine> <clone> <worktree> [claude-config]
  local session=$1 machine=$2 clone=$3 wt=$4 cfg=${5:-} out rc store
  # shellcheck disable=SC2016 # expands on the other machine
  out=$(fm_backend_hc_remote_exec "$session" "$machine" 60 - /bin/sh -c '
    clone=$1 wt=$2 cfg=$3
    if [ -z "$cfg" ]; then
      cfg=${CLAUDE_CONFIG_DIR:-}
      [ -n "$cfg" ] || cfg=$("${SHELL:-/bin/sh}" -lc "printf %s \"\${CLAUDE_CONFIG_DIR:-}\"" </dev/null 2>/dev/null)
    fi
    if [ -n "$cfg" ]; then store=$cfg/.claude.json; else store=$HOME/.claude.json; fi
    command -v jq >/dev/null 2>&1 || { printf "nojq\t%s\n" "$store"; exit 0; }
    [ -r "$store" ] || { printf "nostore\t%s\n" "$store"; exit 0; }
    jq -r --arg clone "$clone" --arg wt "$wt" --arg store "$store" "
      (.projects // {}) as \$p
      | ([\$clone] + ([\$wt | split(\"/\") | range(1; length + 1) as \$i | .[0:\$i] | join(\"/\")] | map(select(. != \"\"))))
      | map(\$p[.].hasTrustDialogAccepted == true) | any
      | if . then \"trusted\t\" + \$store else \"untrusted\t\" + \$store end" "$store" 2>/dev/null \
      || printf "unreadable\t%s\n" "$store"
  ' sh "$clone" "$wt" "$cfg" 2>/dev/null) && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: could not read Claude's workspace trust on hc machine '$machine'" >&2
    return 1
  fi
  store=${out#*$'\t'}
  case "$out" in
    trusted*) return 0 ;;
    untrusted*) echo "error: Claude on '$machine' ($store) has not trusted $clone, so a placed worker would stop at Claude's workspace-trust dialog; open claude in $clone on '$machine' once and accept it" >&2 ;;
    nojq*) echo "error: hc machine '$machine' has no jq to read Claude's workspace trust in $store" >&2 ;;
    nostore*) echo "error: hc machine '$machine' has no readable Claude store at $store; set claude-config in config/hc-machine if Claude there uses another directory" >&2 ;;
    *) echo "error: could not read Claude's workspace trust on '$machine' (${out:-no answer})" >&2 ;;
  esac
  return 1
}

# fm_backend_hc_remote_worktree_add: create <worktree> on <machine> as a
# detached linked worktree of <clone> at the freshly fetched origin/<base>.
# Refuses a path that already exists there. Prints the worktree's own
# top-level path as git reports it.
fm_backend_hc_remote_worktree_add() {  # <session> <machine> <clone> <worktree> <base-branch>
  local session=$1 machine=$2 clone=$3 wt=$4 base=$5 rc top
  fm_backend_hc_remote_exec "$session" "$machine" 30 - test -e "$wt" >/dev/null 2>&1 && rc=0 || rc=$?
  case "$rc" in
    0) echo "error: $wt already exists on '$machine'; refusing to reuse or overwrite it" >&2; return 1 ;;
    255) echo "error: could not reach hc machine '$machine' to create the worktree" >&2; return 1 ;;
  esac
  fm_backend_hc_remote_exec "$session" "$machine" 30 - mkdir -p "${wt%/*}" >/dev/null \
    || { echo "error: could not create ${wt%/*} on '$machine'" >&2; return 1; }
  fm_backend_hc_remote_git "$session" "$machine" "$clone" fetch --quiet origin \
    "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null \
    || { echo "error: could not fetch origin/$base into $clone on '$machine'" >&2; return 1; }
  # From here <wt> was proved absent, so anything at it is this call's own:
  # a failure (including a lost answer) removes it there or names it.
  fm_backend_hc_remote_git "$session" "$machine" "$clone" worktree add --quiet --detach "$wt" \
    "refs/remotes/origin/$base" >/dev/null \
    || { echo "error: could not add worktree $wt from origin/$base on '$machine'" >&2
         fm_backend_hc_remote_worktree_add_undo "$session" "$machine" "$clone" "$wt"; return 1; }
  top=$(fm_backend_hc_remote_git "$session" "$machine" "$wt" rev-parse --show-toplevel 2>/dev/null) \
    || { echo "error: worktree $wt on '$machine' did not come up as a git checkout" >&2
         fm_backend_hc_remote_worktree_add_undo "$session" "$machine" "$clone" "$wt"; return 1; }
  printf '%s\n' "$top"
}

fm_backend_hc_remote_worktree_add_undo() {  # <session> <machine> <clone> <worktree>
  fm_backend_hc_remote_worktree_remove "$@" >/dev/null 2>&1 \
    || echo "warning: worktree $4 on '$2' may remain from this failed spawn; remove it there (git -C $3 worktree remove --force $4)" >&2
}

# fm_backend_hc_remote_default_branch: origin's current default branch for
# <clone>, asked of origin itself (never the clone's cached origin/HEAD), and
# a failure when origin cannot answer, as a local spawn refuses a stale base.
fm_backend_hc_remote_default_branch() {  # <session> <machine> <clone>
  local out ref
  out=$(fm_backend_hc_remote_git "$1" "$2" "$3" ls-remote --symref origin HEAD 2>/dev/null) || return 1
  ref=$(printf '%s\n' "$out" | awk '$1 == "ref:" && $3 == "HEAD" { sub("^refs/heads/", "", $2); print $2; exit }')
  [ -n "$ref" ] || return 1
  printf '%s' "$ref"
}

# fm_backend_hc_remote_worktree_remove: remove <worktree> from <clone> on
# <machine> and delete its local branch. Callers prove the work landed (or
# hold explicit discard authority) first; this only removes.
fm_backend_hc_remote_worktree_remove() {  # <session> <machine> <clone> <worktree>
  local session=$1 machine=$2 clone=$3 wt=$4 branch rc
  fm_backend_hc_remote_exec "$session" "$machine" 30 - test -d "$wt" >/dev/null 2>&1 && rc=0 || rc=$?
  case "$rc" in
    0) ;;
    255) echo "error: could not reach hc machine '$machine' to remove worktree $wt" >&2; return 1 ;;
    *) fm_backend_hc_remote_git "$session" "$machine" "$clone" worktree prune >/dev/null 2>&1 || true; return 0 ;;
  esac
  branch=$(fm_backend_hc_remote_git "$session" "$machine" "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=
  fm_backend_hc_remote_git "$session" "$machine" "$clone" worktree remove --force "$wt" >/dev/null \
    || { echo "error: could not remove worktree $wt on '$machine'" >&2; return 1; }
  if [ -n "$branch" ]; then
    fm_backend_hc_remote_git "$session" "$machine" "$clone" branch -D "$branch" >/dev/null 2>&1 \
      || echo "warning: could not delete branch $branch in $clone on '$machine'" >&2
  fi
  return 0
}

# fm_backend_hc_remote_file_write: write stdin to <path> on <machine>.
fm_backend_hc_remote_file_write() {  # <session> <machine> <path>
  local session=$1 machine=$2 path=$3
  fm_backend_hc_atom_valid "$session" || { echo "error: refusing hc session '$session'" >&2; return 1; }
  fm_backend_hc_atom_valid "$machine" || { echo "error: refusing hc machine name '$machine'" >&2; return 1; }
  fm_backend_hc_env_run "$session" file write --json --on "$machine" "$path" >/dev/null
}

# fm_backend_hc_remote_file_remove: `rm -f` <path> on <machine>; an absent
# file is success. A failure warns with the path and returns 1, never more.
fm_backend_hc_remote_file_remove() {  # <session> <machine> <path>
  fm_backend_hc_remote_exec "$1" "$2" 30 - rm -f -- "$3" >/dev/null 2>&1 && return 0
  echo "warning: could not remove $3 on hc machine '$2'; remove it there by hand" >&2
  return 1
}

# fm_backend_hc_remote_reap_cwd: the placed counterpart of fm-teardown.sh's
# reap_task_worktree_processes, run in one `hc exec` on <machine>. Every
# process whose current directory is <dir> or under it (lsof -a -d cwd where
# that machine has lsof, else a /proc cwd scan) gets TERM, then KILL after a
# one-second grace, then a recheck; the scan never signals its own shell.
# Each scan records every match's start identity (/proc/<pid>/stat starttime,
# else `ps -o lstart=`, as task_process_identity does), and each signal is sent
# only to a pid whose identity still matches just before it, so a pid reused
# by another process after the scan is never signalled.
# Returns 0 when nothing is left (or <dir> is gone), and 1 with the reason on
# stderr when the scan could not run there or a process survived.
fm_backend_hc_remote_reap_cwd() {  # <session> <machine> <dir>
  local session=$1 machine=$2 dir=$3 out rc
  # shellcheck disable=SC2016 # expands on the other machine
  out=$(fm_backend_hc_remote_exec "$session" "$machine" 60 - /bin/sh -c '
    dir=$(cd "$1" 2>/dev/null && pwd -P) || exit 0
    self=$$
    if command -v lsof >/dev/null 2>&1; then how=lsof
    elif readlink "/proc/$self/cwd" >/dev/null 2>&1; then how=proc
    else exit 5
    fi
    scan() {
      if [ "$how" = lsof ]; then
        out=$(lsof -a -d cwd -Fpn 2>/dev/null) || return 1
        printf "%s\n" "$out" | awk -v d="$dir" -v self="$self" "
          /^p/ { pid = substr(\$0, 2); next }
          /^n/ { path = substr(\$0, 2); if ((path == d || index(path, d \"/\") == 1) && pid != self) print pid }"
      else
        for p in /proc/[0-9]*; do
          c=$(readlink "$p/cwd" 2>/dev/null) || continue
          case "$c" in "$dir"|"$dir"/*) [ "${p#/proc/}" = "$self" ] || printf "%s\n" "${p#/proc/}" ;; esac
        done
      fi
    }
    ident() {
      if [ -r "$proc_root/$1/stat" ]; then
        line=$(cat "$proc_root/$1/stat" 2>/dev/null) || return 1
        set -- ${line##*)}
        [ "$#" -ge 20 ] || return 1
        shift 19
        case "$1" in ""|*[!0-9]*) return 1 ;; esac
        printf "starttime=%s\n" "$1"
        return 0
      fi
      v=$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null) || return 1
      v=$(printf "%s" "$v" | tr -s " ")
      v=${v# }; v=${v% }
      [ -n "$v" ] || return 1
      printf "lstart=%s\n" "$v"
    }
    tracked() {
      for p in $1; do
        i=$(ident "$p") && printf "%s %s\n" "$p" "$i"
      done
    }
    signal() {
      printf "%s\n" "$2" | while read -r p i; do
        [ -n "$p" ] || continue
        c=$(ident "$p") && [ "$c" = "$i" ] && kill "-$1" "$p" 2>/dev/null
      done
    }
    proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
    pids=$(scan) || exit 4
    [ -n "$pids" ] || exit 0
    printf "%s\n" "$pids" | tr "\n" " "
    signal TERM "$(tracked "$pids")"
    sleep 1
    pids=$(scan) || exit 4
    if [ -n "$pids" ]; then
      signal KILL "$(tracked "$pids")"
      sleep 1
      pids=$(scan) || exit 4
    fi
    [ -z "$pids" ] || { printf "\nsurvivors: %s" "$(printf "%s\n" "$pids" | tr "\n" " ")"; exit 3; }
    exit 0
  ' sh "$dir" 2>/dev/null) && rc=0 || rc=$?
  case "$rc" in
    0)
      [ -z "$out" ] || echo "teardown: reaped leaked worktree process(es) on hc machine '$machine': $out" >&2
      return 0
      ;;
    3) echo "REFUSED: processes under $dir on hc machine '$machine' survived TERM and KILL (${out##*survivors: }); preserving the worktree and every record for inspection or retry." >&2 ;;
    5) echo "REFUSED: hc machine '$machine' has neither lsof nor a readable /proc, so no scan can find processes left under $dir there; preserving the worktree and every record." >&2 ;;
    255) echo "REFUSED: cannot reach hc machine '$machine' to stop processes left under $dir there; preserving the worktree and every record for retry." >&2 ;;
    *) echo "REFUSED: cannot determine leaked processes under $dir on hc machine '$machine' (scan failed there); preserving the worktree and every record for inspection or retry." >&2 ;;
  esac
  return 1
}

# fm_backend_hc_create_task: start a login shell terminal in <cwd> for
# <window-label>, refusing a live duplicate in this home. Prints the address.
# --no-parent and --outlive-parent keep the terminal independent of whichever
# hc terminal firstmate itself runs in; --no-notify keeps hc from typing notes
# into any parent. With <machine> the terminal starts there (`--on`) and its
# address is `<machine>/t7`; <cwd> is then a path on that machine.
fm_backend_hc_create_task() {  # <session> <window-label> <cwd> [machine]
  local session=$1 label=$2 cwd=$3 machine=${4:-} home scoped dup out address
  local -a on=()
  if [ -n "$machine" ]; then
    fm_backend_hc_atom_valid "$machine" || { echo "error: refusing hc machine name '$machine'" >&2; return 1; }
    on=(--on "$machine")
  fi
  home=$(fm_backend_hometag)
  scoped=$(fm_backend_hc_scoped_label "$label")
  dup=$(fm_backend_hc_cli "$session" ls --json --label "firstmate.task=$label" --label "firstmate.home=$home" 2>/dev/null) \
    || { echo "error: 'hc ls' failed for session '$session'; cannot create $label" >&2; return 1; }
  if [ -n "$(printf '%s' "$dup" | jq -r '.terminals[]?.address' 2>/dev/null)" ]; then
    echo "error: hc terminal for $label already exists in session '$session'" >&2
    return 1
  fi
  out=$(fm_backend_hc_cli "$session" run --bg --json ${on[@]+"${on[@]}"} --no-parent --outlive-parent --no-notify \
    --cwd "$cwd" \
    --label "firstmate.task=$label" --label "firstmate.home=$home" \
    --label "herdr.space=${FM_HC_SPACE:-fm-$home}" --label "herdr.tab=$scoped" 2>&1) \
    || { echo "error: hc run failed for $label: $out" >&2; return 1; }
  address=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)
  fm_backend_hc_address_valid "$address" || { echo "error: hc run did not return a terminal address for $label (got: $out)" >&2; return 1; }
  if [ "$(fm_backend_hc_address_machine "$address")" != "$machine" ]; then
    echo "error: hc run returned $address for $label, not a terminal on ${machine:-this machine}" >&2
    return 1
  fi
  printf '%s\n' "$address"
}

# fm_backend_hc_capture: the screen plus <lines> of history, the same window
# tmux's `capture-pane -S -<lines>` returns.
fm_backend_hc_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-200}
  fm_backend_hc_target_ready "$1" "${3:-}" || return 1
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" read --lines "$lines" "$FM_BACKEND_HC_ADDRESS" 2>/dev/null
}

# fm_backend_hc_visible_capture: the screen only (`--lines 0`).
fm_backend_hc_visible_capture() {  # <target> [expected-label]
  fm_backend_hc_target_ready "$1" "${2:-}" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" read --lines 0 "$FM_BACKEND_HC_ADDRESS" 2>/dev/null
}

# fm_backend_hc_normalize_key: firstmate's key vocabulary onto hc key names.
fm_backend_hc_normalize_key() {  # <key>
  case "$1" in
    Enter|enter|C-m) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'esc' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl+c' ;;
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl+u' ;;
    Up) printf 'up' ;;
    Down) printf 'down' ;;
    Tab) printf 'tab' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_hc_send_key() {  # <target> <key> [expected-label]
  fm_backend_hc_target_ready "$1" "${3:-}" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" keys --json "$FM_BACKEND_HC_ADDRESS" \
    -- "$(fm_backend_hc_normalize_key "$2")" >/dev/null 2>&1
}

# fm_backend_hc_send_text_line: paste one line and submit it (`hc send`). The
# `--` delimiter keeps flag-looking text from being parsed as options.
fm_backend_hc_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_hc_target_ready "$1" "${3:-}" || return 1
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" send --json "$FM_BACKEND_HC_ADDRESS" -- "$2" >/dev/null 2>&1
}

fm_backend_hc_current_path() {  # <target> [expected-label]
  local json
  fm_backend_hc_target_ready "$1" "${2:-}" || return 0
  json=$(fm_backend_hc_get "$1") || return 0
  printf '%s' "$json" | jq -r '.foreground.cwd // .cwd // empty' 2>/dev/null
}

fm_backend_hc_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

fm_backend_hc_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_hc_visible_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_hc_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_hc_send_text_submit: one `hc send --wait`, which pastes, presses
# Enter, and reports the turn it started. Echoes
# empty|pending|pending-unproven|unknown|send-failed, a subset of the
# proof-carrying submit vocabulary.
#
# A started turn or a still-working wait confirms the submit natively, which
# no composer text can fake. A program that never reports status answers
# started:null once the bounded wait times out; the send still typed and
# entered, so the verdict falls back to the composer screen, and only a
# proven pending composer gets Enter retries through the shared loop. A
# blocked terminal refuses with exit 9 before typing - unknown, with a
# diagnostic and no retries, never forced. The other structured refusals
# (3 not_found, 11 finished) and any other failure are send-failed.
fm_backend_hc_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected=${6:-}
  local wait_secs out rc started wait_status verdict
  case "$retries" in ''|*[!0-9]*) retries=1 ;; esac
  case "$sleep_s" in ''|*[!0-9.]*) sleep_s=0.4 ;; esac
  case "$settle" in ''|*[!0-9.]*) settle=0 ;; esac
  fm_backend_hc_target_ready "$target" "$expected" || { printf 'send-failed'; return 0; }
  wait_secs=$(awk -v r="$retries" -v s="$sleep_s" 'BEGIN { v = r * s; if (v < 1) v = 1; printf "%d", (v == int(v) ? v : int(v) + 1) }' 2>/dev/null)
  case "$wait_secs" in ''|*[!0-9]*|0) wait_secs=1 ;; esac
  out=$(fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" send --json "$FM_BACKEND_HC_ADDRESS" \
    --wait --timeout "$wait_secs" -- "$text" 2>&1)
  rc=$?
  case "$rc" in
    0) ;;
    9)
      echo "error: hc send refused $target - the terminal is blocked waiting on input (never forced): $out" >&2
      printf 'unknown'
      return 0
      ;;
    *) printf 'send-failed'; return 0 ;;
  esac
  started=$(printf '%s' "$out" | jq -r '.started // empty' 2>/dev/null)
  wait_status=$(printf '%s' "$out" | jq -r '.wait.status // empty' 2>/dev/null)
  if [ "$started" = true ] || [ "$wait_status" = working ]; then
    printf 'empty'
    return 0
  fi
  [ "$settle" = 0 ] || sleep "$settle"
  verdict=$(fm_backend_hc_composer_state "$target" "$expected")
  case "$verdict" in
    pending|pending-unproven)
      fm_composer_submit_retry_core fm_backend_hc_send_key fm_backend_hc_composer_state \
        "$target" "$retries" "$sleep_s" "$expected"
      ;;
    *) printf '%s' "$verdict" ;;
  esac
}

# fm_backend_hc_busy_state: hc's native agent status. `working` is busy; the
# settled words are idle; a terminal with no reported status is unknown.
fm_backend_hc_busy_state() {  # <target>
  local json
  json=$(fm_backend_hc_get "$1") || { printf 'unknown'; return 0; }
  case "$(printf '%s' "$json" | jq -r '.status.state // empty' 2>/dev/null)" in
    working) printf 'busy' ;;
    idle|done) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_hc_kill: end the program and remove the terminal, then prove it is
# gone. Already absent is a silent success; a terminal still present, a core
# that cannot be read, or a terminal without this home's labels is a refusal.
fm_backend_hc_kill() {  # <target> [unused] [expected-label]
  local target=$1 expected=${3:-'*'} state
  fm_backend_hc_parse_target "$target" || return 1
  state=$(fm_backend_hc_endpoint_state "$target" "$expected")
  case "$state" in
    absent) return 0 ;;
    foreign) echo "error: hc terminal $target does not carry this task's labels; refusing to close it" >&2; return 1 ;;
    unreadable) echo "error: hc terminal $target could not be read, so it was not closed" >&2; return 1 ;;
  esac
  [ "$state" != ready ] || fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" kill --json "$FM_BACKEND_HC_ADDRESS" >/dev/null 2>&1 || true
  fm_backend_hc_cli "$FM_BACKEND_HC_SESSION" rm --json "$FM_BACKEND_HC_ADDRESS" >/dev/null 2>&1 || true
  state=$(fm_backend_hc_endpoint_state "$target")
  case "$state" in
    absent) return 0 ;;
    unreadable) echo "error: hc terminal $target could not be read after its close, so whether it survived is unknown" >&2 ;;
    *) echo "error: hc terminal $target is still present after its close" >&2 ;;
  esac
  return 1
}

# fm_backend_hc_agent_state: recovery-grade state (vocabulary owned by
# bin/fm-backend.sh's fm_backend_agent_state). A structured not_found or a
# finished terminal is `missing`: an hc terminal whose program ended can never
# host the agent again, exactly like a closed tmux window. A live terminal is
# classified from hc's foreground process through the shared classifier.
fm_backend_hc_agent_state() {  # <target>
  local json rc fields state name argv0 args pid class machine session local_pid
  fm_backend_hc_parse_target "${1:-}" || { printf 'unreadable'; return 0; }
  json=$(fm_backend_hc_get "$1")
  rc=$?
  if [ "$rc" -eq 3 ]; then printf 'missing'; return 0; fi
  [ "$rc" -eq 0 ] || { printf 'unreadable'; return 0; }
  fields=$(printf '%s' "$json" | jq -r '[.state // "", .foreground.name // "", .foreground.argv[0] // "",
    ((.foreground.argv // []) | join(" ")), (.foreground.pid // "" | tostring)] | @tsv' 2>/dev/null) || {
    printf 'unreadable'
    return 0
  }
  IFS=$'\t' read -r state name argv0 args pid <<EOF
$fields
EOF
  case "$state" in
    finished) printf 'missing'; return 0 ;;
    live) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  [ -n "$name$argv0" ] || { printf 'unreadable'; return 0; }
  machine=$(fm_backend_hc_address_machine "$FM_BACKEND_HC_ADDRESS")
  session=$FM_BACKEND_HC_SESSION
  # A remote pid names a process on that machine, never one here.
  local_pid=$pid
  [ -z "$machine" ] || local_pid=
  class=$(fm_agent_process_classify "$name" "$argv0" "$args" "$local_pid")
  [ "$class" != agent ] || { printf 'alive'; return 0; }
  # A launcher (a wrapper script, or a tool that runs the harness as a child)
  # is what hc names as the foreground; the harness itself is another member
  # of the same foreground process group, which is what tmux reads too. A shell
  # wrapper waiting on the harness is such a launcher, so a shell is only dead
  # once its group holds no harness. A terminal on another machine has its
  # group read there; a scan that cannot run there proves nothing, so the
  # state stays unreadable rather than dead.
  if [ -n "$machine" ]; then
    rc=0
    fm_backend_hc_remote_group_has_agent "$session" "$machine" "$pid" || rc=$?
    case $rc in
      0) printf 'alive'; return 0 ;;
      1) ;;
      *) printf 'unreadable'; return 0 ;;
    esac
  else
    fm_backend_hc_group_has_agent "$pid" && { printf 'alive'; return 0; }
  fi
  [ "$class" != shell ] || { printf 'dead'; return 0; }
  printf 'ambiguous'
}

# fm_backend_hc_remote_group_has_agent: the remote counterpart of
# fm_backend_hc_group_has_agent, read in one `hc exec` on <machine>. Returns 0
# when another member of <pid>'s group classifies as a harness, 1 when none
# does, and 2 when the scan could not run there.
fm_backend_hc_remote_group_has_agent() {  # <session> <machine> <pid>
  local session=$1 machine=$2 pid=$3 out member comm args
  case "$pid" in ''|*[!0123456789]*) return 2 ;; esac
  # shellcheck disable=SC2016 # expands on the other machine
  out=$(fm_backend_hc_remote_exec "$session" "$machine" 30 - /bin/sh -c '
    pg=$(LC_ALL=C ps -o pgid= -p "$1" 2>/dev/null | tr -d " ")
    [ -n "$pg" ] || exit 3
    LC_ALL=C ps -A -o pid=,pgid=,comm= | while read -r p g c; do
      [ "$g" = "$pg" ] && [ "$p" != "$1" ] || continue
      a=$(LC_ALL=C ps -o args= -p "$p" 2>/dev/null) || continue
      printf "%s\t%s\t%s\n" "$p" "$c" "$a"
    done
  ' sh "$pid" 2>/dev/null) || return 2
  while IFS=$'\t' read -r member comm args; do
    [ -n "$member" ] || continue
    [ "$(fm_agent_process_classify "$comm" "${args%% *}" "$args")" = agent ] && return 0
  done <<EOF
$out
EOF
  return 1
}

# fm_backend_hc_group_has_agent: whether any other process in <pid>'s process
# group classifies as a harness. Positive evidence only.
fm_backend_hc_group_has_agent() {  # <pid>
  local pid=$1 pgid member mpgid comm args
  case "$pid" in ''|*[!0123456789]*) return 1 ;; esac
  pgid=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
  [ -n "$pgid" ] || return 1
  while read -r member mpgid comm; do
    [ "$mpgid" = "$pgid" ] && [ "$member" != "$pid" ] || continue
    args=$(LC_ALL=C ps -o args= -p "$member" 2>/dev/null) || continue
    [ "$(fm_agent_process_classify "$comm" "${args%% *}" "$args" "$member")" = agent ] && return 0
  done <<EOF
$(LC_ALL=C ps -A -o pid=,pgid=,comm= 2>/dev/null)
EOF
  return 1
}
