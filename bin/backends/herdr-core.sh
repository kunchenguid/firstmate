#!/usr/bin/env bash
# bin/backends/herdr-core.sh - the Herdr Core session-provider adapter
# (EXPERIMENTAL). Herdr Core (`herdr-core` on PATH, self-identifying as `hc
# x.y.z`) is the new flat-terminal product line from herdrdev: NOT an upgrade
# of `herdr` 0.9.x, which backend=herdr keeps driving unchanged. A core
# session is an isolated state/socket domain holding a flat list of
# persistent terminals; labels are the discovery and ownership mechanism.
# docs/herdr-core-backend.md owns the user-facing mechanics and
# docs/verification/runtime-backends.md owns what was and was not verified;
# this header owns the adapter's own design decisions. Sourced only through
# bin/fm-backend.sh's fm_backend_source in normal operation; the unit tests
# source it directly.
#
# Selection is explicit-only for this stage: `--backend herdr-core`,
# FM_BACKEND=herdr-core, or config/backend. HC_* markers reach every
# descendant of a core terminal (a tmux server started inside one inherits
# them), so bin/fm-backend.sh's fm_backend_detect never reads them; app-vs-TUI
# auto-detection is a later stage, not this adapter's business.
#
# Container shape: ONE core session per firstmate home, named fm-<hometag>
# (bin/fm-backend-hometag-lib.sh; FM_HC_SESSION overrides the NAME for test
# isolation, mirroring FM_TERN_SESSION/HERDR_SESSION). One terminal per task,
# named fm-<id> when the id fits hc's 32-char name budget, carrying labels
# fm.id=<task-id>, fm.home=<hometag>, and fm.project=<project basename>.
#
# Target string shape: "<session>:<terminal-address>" - the session name and
# the terminal's own address (t5, t1b, ...). Local terminals only: a
# `machine/t7` remote address contains a slash and is refused by
# parse_target. The session is the first colon's left side, so a session
# name may never contain a colon (hometag sessions cannot).
#
# Socket pinning: EVERY hc call runs under env HC_SESSION=<session>
# HC_SOCKET=<socket for that session> - never ambient. The socket is
# FM_HC_SOCKET when set (tests/labs), else hc's own state derivation
# ${XDG_STATE_HOME:-$HOME/.local/state}/herdr-core/<session>/<session>.sock.
# Ambient HC_SESSION/HC_SOCKET/HC_TERMINAL_* are stripped so a call issued
# from inside a core terminal never silently targets the caller's own
# session or stamps a bogus caller on terminal.send.
#
# Observed on hc 0.1.14 (the pinned/verified version) on 2026-10-30, macOS
# arm64, in an isolated lab session:
#   - `hc run --bg --name N --label K=V --cwd DIR --no-parent --json` starts
#     a persistent terminal and returns {"address":"t5",...}; with no argv it
#     runs that machine's own shell.
#   - `hc get <addr> --json` returns {address, argv, agent, cwd, foreground
#     {argv,cwd,name,pid}|null, labels, name, pid, state, status, reported,
#     reason, turn, ...}; unknown address exits 3 with kind=not_found.
#     `foreground` is populated for programs that spawn children (shells);
#     for a direct `hc run <agent>` argv/pid describe the program itself.
#   - `hc ls --json [--all] [--label K=V]` returns
#     {"hidden_finished":n,"terminals":[{address,agent,cwd,name,state,turn}]};
#     no label echo, so label reads go through `hc get`.
#   - `hc send <t> -- <text>` pastes text and presses Enter atomically; text
#     beginning with '-' needs the `--` delimiter. `--wait --timeout N`
#     bounds a check-in and reports {started, wait:{ended,reason,status}}.
#     A blocked terminal refuses with exit 9 (never retried with --force),
#     a finished terminal exits 11, a status_mismatch (--if) exits 10, an
#     unknown address exits 3, invalid params exit 6, an unreachable core
#     exits 5.
#   - `hc keys <t> <keys...>` presses named keys: enter, esc|escape, tab,
#     up|down|left|right, backspace, delete, home, end, pageup, pagedown,
#     f1-f12, space, ctrl+<letter>, alt+<letter>, shift+tab, and single
#     literal characters from a LIMITED set: a-z A-Z 0-9 ' , - . / ; = [ ] `.
#     It CANNOT type shifted punctuation (!"#$%&()*+:<>?@^_{|}~).
#   - Because `hc send` is atomic paste+enter and `hc keys` cannot type
#     arbitrary text, UNSUBMITTED literal input rides an adapter-local pending
#     buffer (fm_backend_herdr_core_pending_path): send_literal appends to it,
#     and the next Enter/text-line/submit flushes it through one `hc send`,
#     which is paste-safe for every character class. Between the literal and
#     its flush the text is buffered, not on the terminal's screen - narrower
#     than the tmux -l semantics, and documented as a Stage-1 limit in
#     docs/herdr-core-backend.md.
#   - `hc read <t> --json [--lines N]` returns {"complete","how","text"} with
#     ANSI already stripped; default how=screen is the viewport, --lines N
#     adds N lines of history above it (how=history).
#   - `hc kill <t>` is synchronous and idempotent; the record stays with
#     state=finished until `hc rm <t>` removes it ({"removed":"t5"}).
#   - `hc interrupt <t>` presses the agent's stop key (ctrl+c observed) and
#     reports {"key","outcome"}.
#   - `hc server start` is idempotent; any session-scoped command auto-starts
#     a stopped core for that session, so passive reads never mistake a
#     stopped server for a destroyed endpoint (the record list answers).
#   - `hc connect` speaks line JSON-RPC; `hello` with params.generation=1
#     returns {generation,version,methods,features}; a wrong generation
#     returns an unsupported_generation error. Generation 1 is required.
#   - OSC 7501 status: `hc get`'s .status/.reported/.turn carry the program's
#     reported state (working|idle|blocked...) ONLY when the program emits
#     OSC 7501. A non-reporting program has status:null reported:false - it
#     must NEVER read as dead or idle-proven on that account.
#   - `hc events --json` streams JSON-RPC records (created, foreground,
#     title, status, finished, ...). The normalized push-transition surface
#     is NOT wired in this stage: fm_backend_has_push stays false and the
#     watcher's poll loop is the event source, as for zellij/cmux/tern.
#
# Liveness (fm_backend_herdr_core_agent_state): state==live plus the shared
# process classifier over `foreground` (or the program's own argv for a
# direct run), never screen inference. busy_state maps the OSC 7501 status
# when reported (working->busy, blocked->blocked, idle->idle) with a
# foreground-agent guard on busy so a stale working record over a shell-only
# terminal reads unknown; an unreported program reads unknown.
#
# Requires: herdr-core (CLI), jq (JSON parsing). Bootstrap detects these
# through fm_backend_required_tools only when herdr-core is the resolved
# backend; this adapter also gates them again before spawning. Secondmate
# spawns are not supported by this adapter in this stage.
#
# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/tern.sh's identical fallback.
FM_BACKEND_HERDR_CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_CORE_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_HERDR_CORE_ROOT/bin/fm-backend-hometag-lib.sh"

# Shared composer-content classifier and submit helpers (bin/fm-composer-lib.sh).
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_HERDR_CORE_ROOT/bin/fm-composer-lib.sh"

# Shared harness-process identity (agent|shell|other), the same classifier the
# tmux, herdr, and tern adapters prove liveness with (bin/fm-agent-process-lib.sh).
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_HERDR_CORE_ROOT/bin/fm-agent-process-lib.sh"

# Verified minimum: the version the probing above ran against.
FM_BACKEND_HC_MIN_MAJOR=0
FM_BACKEND_HC_MIN_MINOR=1
FM_BACKEND_HC_MIN_PATCH=14

# The one protocol generation this adapter speaks.
FM_BACKEND_HC_GENERATION=1

# fm_backend_herdr_core_bin: the resolved herdr-core binary path, or failure.
# The distributed name is `herdr-core`; the bare `hc` name is deliberately
# never resolved because it can collide with other tools (the spec names the
# full binary name). FM_HC_BIN overrides for tests and labs.
fm_backend_herdr_core_bin() {
  if [ -n "${FM_HC_BIN:-}" ]; then
    [ -x "$FM_HC_BIN" ] || return 1
    printf '%s' "$FM_HC_BIN"
    return 0
  fi
  command -v herdr-core 2>/dev/null || return 1
}

# fm_backend_herdr_core_tool_check: refuse loudly if herdr-core or jq is missing.
fm_backend_herdr_core_tool_check() {
  fm_backend_herdr_core_bin >/dev/null 2>&1 || { echo "error: backend=herdr-core selected but the 'herdr-core' CLI was not found on PATH (install Herdr Core per docs/herdr-core-backend.md and put its 'herdr-core' command on PATH)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=herdr-core selected but 'jq' is not installed (required to parse hc's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_herdr_core_version_check: refuse loudly on a missing, misnamed, or
# older-than-verified herdr-core. `<bin> --version` must print `hc x.y.z` -
# anything else means the resolved binary is not Herdr Core.
fm_backend_herdr_core_version_check() {
  fm_backend_herdr_core_tool_check || return 1
  local bin raw ver major rest minor patch cur min
  bin=$(fm_backend_herdr_core_bin) || return 1
  raw=$("$bin" --version 2>/dev/null) || { echo "error: 'herdr-core --version' failed; is herdr-core installed correctly?" >&2; return 1; }
  case "$raw" in
    'hc '[0-9]*.[0-9]*.[0-9]*)
      ver=${raw#hc }
      ver=${ver%%[[:space:]]*}
      ;;
    *)
      echo "error: expected 'hc x.y.z' from herdr-core --version but got '$raw'; refusing to use a binary that is not Herdr Core" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$rest" in
    *.*) patch=${rest#*.} ;;
    *) patch=0 ;;
  esac
  patch=${patch%%[^0-9]*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  case "$patch" in ''|*[!0-9]*) patch=0 ;; esac
  cur=$((major * 1000000 + minor * 1000 + patch))
  min=$((FM_BACKEND_HC_MIN_MAJOR * 1000000 + FM_BACKEND_HC_MIN_MINOR * 1000 + FM_BACKEND_HC_MIN_PATCH))
  if [ "$cur" -lt "$min" ]; then
    echo "error: herdr-core $ver is older than the verified minimum $FM_BACKEND_HC_MIN_MAJOR.$FM_BACKEND_HC_MIN_MINOR.$FM_BACKEND_HC_MIN_PATCH; update herdr-core before using backend=herdr-core" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_core_session_name: the home session name. FM_HC_SESSION is
# the operator/test knob; NEVER default to a non-fm- name and never to
# `default` - that session belongs to the user's own hc usage. A refused name
# fails container_ensure rather than silently landing in another domain.
fm_backend_herdr_core_session_name() {
  if [ -n "${FM_HC_SESSION:-}" ]; then
    printf '%s' "$FM_HC_SESSION"
  else
    printf 'fm-%s' "$(fm_backend_hometag)"
  fi
}

# fm_backend_herdr_core_socket: the pinned socket path for <session>. FM_HC_SOCKET
# overrides (tests and labs); otherwise hc's own state derivation is
# reproduced so this adapter and a same-session `hc` agree.
fm_backend_herdr_core_socket() {  # <session>
  local session=$1 base
  if [ -n "${FM_HC_SOCKET:-}" ]; then
    printf '%s' "$FM_HC_SOCKET"
    return 0
  fi
  base=${XDG_STATE_HOME:-$HOME/.local/state}
  printf '%s/herdr-core/%s/%s.sock' "$base" "$session" "$session"
}

# fm_backend_herdr_core_cli: the ONE place an hc command runs. Every call is
# pinned to <session> AND its socket, with ambient HC_* stripped, so no
# caller's environment can redirect an operation into another session or
# stamp a wrong caller on it. The unset runs in a subshell because `env -u`
# is not portable to every env hc runs under. stdin is detached so hc never
# consumes a caller's loop input.
fm_backend_herdr_core_cli() {  # <session> <hc-args...>
  local session=$1 socket bin
  shift
  socket=$(fm_backend_herdr_core_socket "$session") || return 1
  bin=$(fm_backend_herdr_core_bin) || return 1
  (
    unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET
    HC_SESSION="$session" HC_SOCKET="$socket" "$bin" "$@" </dev/null
  )
}

# fm_backend_herdr_core_hello: the generation handshake for <session> through
# `hc connect`; prints the result object on success, nothing on failure.
fm_backend_herdr_core_hello() {  # <session>
  local session=$1 socket bin out
  socket=$(fm_backend_herdr_core_socket "$session") || return 1
  bin=$(fm_backend_herdr_core_bin) || return 1
  out=$(printf '{"jsonrpc":"2.0","method":"hello","params":{"generation":%s},"id":1}\n' "$FM_BACKEND_HC_GENERATION" \
    | (
        unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SESSION HC_SOCKET
        HC_SESSION="$session" HC_SOCKET="$socket" "$bin" connect --session "$session" 2>/dev/null
      )) || return 1
  printf '%s' "$out" | jq -e '.result.generation' >/dev/null 2>&1 || return 1
  printf '%s' "$out" | jq -c '.result'
}

# fm_backend_herdr_core_gate: the spawn-time capability gate - tools, verified
# version floor, protocol generation exactly 1.
fm_backend_herdr_core_gate() {  # <session>
  local session=$1 hello gen
  fm_backend_herdr_core_version_check || return 1
  hello=$(fm_backend_herdr_core_hello "$session") || {
    echo "error: herdr-core session '$session' did not answer the hello handshake; is the core reachable at $(fm_backend_herdr_core_socket "$session")?" >&2
    return 1
  }
  gen=$(printf '%s' "$hello" | jq -r '.generation // empty' 2>/dev/null)
  if [ "$gen" != "$FM_BACKEND_HC_GENERATION" ]; then
    echo "error: herdr-core session '$session' speaks protocol generation '${gen:-<none>}', but this adapter requires generation $FM_BACKEND_HC_GENERATION" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_core_valid_session: a usable session name atom - no colon,
# slash, whitespace, or control characters, so it can never confuse the
# "<session>:<terminal>" split or the env pinning.
fm_backend_herdr_core_valid_session() {
  case "${1:-}" in
    ''|*[:/[:space:]]*|*[[:cntrl:]]*) return 1 ;;
  esac
  return 0
}

# fm_backend_herdr_core_container_ensure: the full spawn-time container-ensure
# sequence (tool+version+generation gate, refuse non-fm/default names, ensure
# the session's core is up). Echoes the session name, nothing else.
# `hc server start` is idempotent and safe on a running session.
fm_backend_herdr_core_container_ensure() {
  local session
  session=$(fm_backend_herdr_core_session_name)
  if [ "$session" = default ]; then
    echo "error: refusing the 'default' herdr-core session - it belongs to the user's own hc usage, not firstmate tasks" >&2
    return 1
  fi
  fm_backend_herdr_core_valid_session "$session" || { echo "error: refusing herdr-core session name '$session' (must be letters, digits, and ._- only)" >&2; return 1; }
  if [ -z "${FM_HC_SESSION:-}" ]; then
    # The derived name is always fm-<hometag>; this guard catches a hometag
    # resolver change, not an operator override (FM_HC_SESSION is explicit
    # authority, so it only has to pass valid_session + non-default).
    case "$session" in
      fm-*) : ;;
      *) echo "error: refusing derived herdr-core session name '$session' - task sessions must carry the fm- prefix" >&2; return 1 ;;
    esac
  fi
  fm_backend_herdr_core_gate "$session" || return 1
  fm_backend_herdr_core_cli "$session" server start --json >/dev/null 2>&1 || {
    echo "error: could not start the herdr-core session '$session'" >&2
    return 1
  }
  printf '%s' "$session"
}

# --- target parsing and endpoint reads -----------------------------------------

# fm_backend_herdr_core_parse_target: split "<session>:<terminal-address>".
# Strict: a valid session atom, one colon, and a local terminal address
# (`t` plus letters/digits - `machine/t7` remote addresses are refused by the
# no-slash rule). Sets FM_BACKEND_HC_SESSION and FM_BACKEND_HC_TERMINAL.
fm_backend_herdr_core_parse_target() {  # <target>
  local target=${1:-} session term
  FM_BACKEND_HC_SESSION=
  FM_BACKEND_HC_TERMINAL=
  case "$target" in
    ''|*:*:*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  session=${target%%:*}
  term=${target#*:}
  fm_backend_herdr_core_valid_session "$session" || return 1
  case "$term" in
    t[A-Za-z0-9]*) ;;
    *) return 1 ;;
  esac
  FM_BACKEND_HC_SESSION=$session
  FM_BACKEND_HC_TERMINAL=$term
  return 0
}

# fm_backend_herdr_core_get: `hc get <term> --json` under <session>; prints the
# raw JSON on rc 0, nothing otherwise. Callers distinguish a structured
# not_found from an unreachable core by exit code (3 vs 5).
fm_backend_herdr_core_get() {  # <session> <term>
  fm_backend_herdr_core_cli "$1" get "$2" --json 2>/dev/null
}

# fm_backend_herdr_core_endpoint_state: classify the terminal of a parsed
# target against a fresh read. Always returns 0 and prints exactly one of:
#   ready<TAB><state-json-reduced-fields>
#     where fields are <fm.id or -> <name or -> and the read is consistent;
#     with [expected-id] given, labels."fm.id" must equal it
#   absent          no terminal with that address is listed (structured
#                   not_found, or the record was removed)
#   finished        the record exists but its program ended
#   renamed         the record's fm.id label does not match [expected-id]
#   unreadable      the read failed or contradicted itself
fm_backend_herdr_core_endpoint_state() {  # <session> <term> [expected-id]
  local session=$1 term=$2 want=${3:-} json verdict
  json=$(fm_backend_herdr_core_get "$session" "$term")
  case $? in
    0) ;;
    3) printf 'absent'; return 0 ;;
    11) printf 'finished'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  verdict=$(printf '%s' "$json" | jq -r --arg want "$want" '
    if (.state // "") == "finished" then "finished"
    elif ($want != "") and ((.labels["fm.id"] // "") != $want) then "renamed"
    else "ready\t\(.labels["fm.id"] // "-")\t\(.name // "-")\t\(.state // "-")"
    end' 2>/dev/null) || verdict=
  [ -n "$verdict" ] || verdict=unreadable
  printf '%s' "$verdict"
}

# fm_backend_herdr_core_target_ready: parse the target and verify it against a
# fresh read. Read-only in intent (hc may auto-start the session's core, which
# does not disturb terminals). When the caller knows the owning task label
# (fm-<id>) the terminal's fm.id label must equal it, so a recycled address is
# refused.
fm_backend_herdr_core_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} want='' state kind
  fm_backend_herdr_core_parse_target "${1:-}" || return 1
  if [ -n "$expected_label" ]; then
    case "$expected_label" in
      fm-*) want=${expected_label#fm-} ;;
      *) want=$expected_label ;;
    esac
  fi
  state=$(fm_backend_herdr_core_endpoint_state "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" "$want")
  kind=${state%%$'\t'*}
  [ "$kind" = ready ] || return 1
  return 0
}

# fm_backend_herdr_core_task_name: the terminal name for <label>, inside hc's
# "1-32 of a-z 0-9 - _ . starting with a letter or digit" budget; empty when
# the label cannot fit (labels, not the name, carry ownership).
fm_backend_herdr_core_task_name() {  # <label> (fm-<id>)
  local name=$1
  case "$name" in
    [a-z]*|[0-9]*) ;;
    *) return 1 ;;
  esac
  [ "${#name}" -le 32 ] || return 1
  case "$name" in
    *[!a-z0-9._-]*) return 1 ;;
  esac
  printf '%s' "$name"
}

# fm_backend_herdr_core_create_task: create the task's terminal in this home's
# session, refusing an existing live terminal carrying the same fm.id label.
# The terminal runs that machine's own shell (no argv) in <cwd>, named fm-<id>
# when that fits, labeled fm.id/fm.home/fm.project, then read back so a core
# that dropped the labels fails loudly here rather than at the first steer.
# Echoes the terminal address, nothing else.
fm_backend_herdr_core_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 session taskid name project dup out addr check fid
  session=$(fm_backend_herdr_core_session_name)
  taskid=$label
  case "$taskid" in
    fm-*) taskid=${taskid#fm-} ;;
  esac
  name=$(fm_backend_herdr_core_task_name "$label" 2>/dev/null || true)
  project=$(basename "$cwd" 2>/dev/null)
  project=$(printf '%s' "$project" | tr -c 'A-Za-z0-9._-' '_')
  fm_backend_herdr_core_valid_session "$session" || { echo "error: herdr-core session '$session' is not usable" >&2; return 1; }
  # Duplicate guard: a live terminal already carrying fm.id=<taskid> in this
  # session means the task id is already spawned here.
  dup=$(fm_backend_herdr_core_cli "$session" ls --json --label "fm.id=$taskid" --label "fm.home=$(fm_backend_hometag)" 2>/dev/null \
    | jq -r '[.terminals[]? | select(.state == "live") | .address] | .[0] // empty' 2>/dev/null)
  if [ -n "$dup" ]; then
    echo "error: a live herdr-core terminal for task '$label' already exists in session '$session' ($dup)" >&2
    return 1
  fi
  local -a run_args
  run_args=(run --bg --json --cwd "$cwd" --no-parent --no-notify
    --label "fm.id=$taskid" --label "fm.home=$(fm_backend_hometag)" --label "fm.project=$project")
  [ -z "$name" ] || run_args+=(--name "$name")
  out=$(fm_backend_herdr_core_cli "$session" "${run_args[@]}" 2>&1) || { echo "error: hc run failed for '$label': $out" >&2; return 1; }
  addr=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)
  case "$addr" in
    t[A-Za-z0-9]*) ;;
    *) echo "error: hc run did not return a terminal address for '$label' (got: $out)" >&2; return 1 ;;
  esac
  # Read back: the record must carry our fm.id label and be live.
  check=$(fm_backend_herdr_core_get "$session" "$addr" 2>/dev/null) || {
    fm_backend_herdr_core_cli "$session" kill "$addr" >/dev/null 2>&1 || true
    echo "error: hc run returned $addr but the terminal could not be read back" >&2
    return 1
  }
  fid=$(printf '%s' "$check" | jq -r '.labels["fm.id"] // empty' 2>/dev/null)
  if [ "$fid" != "$taskid" ]; then
    fm_backend_herdr_core_cli "$session" kill "$addr" >/dev/null 2>&1 || true
    fm_backend_herdr_core_cli "$session" rm "$addr" >/dev/null 2>&1 || true
    echo "error: new herdr-core terminal $addr did not keep its fm.id=$taskid label (read back '${fid:-<none>}'); removed it" >&2
    return 1
  fi
  printf '%s' "$addr"
}

# --- capture ----------------------------------------------------------------

# fm_backend_herdr_core_capture: bounded plain-text capture. `hc read --lines N`
# returns history plus the viewport, so the result is tail-trimmed to <lines>.
fm_backend_herdr_core_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-200} out
  fm_backend_herdr_core_target_ready "$1" "${3:-}" || return 1
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  out=$(fm_backend_herdr_core_cli "$FM_BACKEND_HC_SESSION" read "$FM_BACKEND_HC_TERMINAL" --json --lines "$lines" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.text // empty' 2>/dev/null | tail -n "$lines"
}

# fm_backend_herdr_core_visible_capture: the viewport only - `hc read` with no
# --lines returns exactly the screen (how=screen).
fm_backend_herdr_core_visible_capture() {  # <target> [expected-label]
  local out
  fm_backend_herdr_core_target_ready "$1" "${2:-}" || return 1
  out=$(fm_backend_herdr_core_cli "$FM_BACKEND_HC_SESSION" read "$FM_BACKEND_HC_TERMINAL" --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.text // empty' 2>/dev/null
}

# fm_backend_herdr_core_composer_capture: the composer screen, the visible
# viewport, never a bounded tail.
fm_backend_herdr_core_composer_capture() {  # <target> [expected-label]
  fm_backend_herdr_core_visible_capture "$1" "${2:-}"
}

# fm_backend_herdr_core_composer_caps: static capability facts. hc's read is
# plain text (styled=0), there is no cursor-coordinate read (cursor=0), and a
# native identity probe exists (identity=1): .agent when the program reports
# OSC 7501, else the foreground/program argv basename.
fm_backend_herdr_core_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=1\n'
}

# fm_backend_herdr_core_composer_identity: the native identity/state probe
# backing the shared classifier's separated (pi) shape: "<agent>\t<status>"
# from `hc get` - .agent when reported, else the foreground or program argv
# basename; .status verbatim (empty when unreported).
fm_backend_herdr_core_composer_identity() {  # <target> -> "<agent>\t<status>"
  local json agent status
  fm_backend_herdr_core_parse_target "${1:-}" || return 1
  json=$(fm_backend_herdr_core_get "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL") || return 1
  agent=$(printf '%s' "$json" | jq -r '
    (.agent // "") as $a
    | if $a != "" then $a
      elif (((.foreground // {}).argv[0] // "") != "") then ((.foreground // {}).argv[0] | sub(".*/"; ""))
      else ((.argv[0] // "") | sub(".*/"; "")) end' 2>/dev/null)
  status=$(printf '%s' "$json" | jq -r '.status // ""' 2>/dev/null)
  [ -n "$agent" ] || return 1
  printf '%s\t%s' "$agent" "$status"
}

# fm_backend_herdr_core_composer_state: thin adapter - capture plus
# capabilities in, shared verdict out. Every shape lives in
# bin/fm-composer-lib.sh. The identity probe is lazy: it runs only when the
# classifier answers need-identity (a pi separator pair below every other
# candidate).
fm_backend_herdr_core_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap caps verdict identity
  cap=$(fm_backend_herdr_core_composer_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  caps=$(fm_backend_herdr_core_composer_caps)
  verdict=$(fm_composer_classify_screen "$caps" "$cap")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_backend_herdr_core_composer_identity "$1" 2>/dev/null) || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$caps" "$cap" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# --- current path -------------------------------------------------------------

# fm_backend_herdr_core_current_path: the live foreground process's cwd, or the
# terminal's own cwd when no foreground is reported; empty on any error. The
# foreground cwd tracks the subshell `treehouse get` opens, the herdr
# `foreground_cwd` shape.
fm_backend_herdr_core_current_path() {  # <target> [expected-label]
  local json cwd
  fm_backend_herdr_core_target_ready "$1" "${2:-}" || return 0
  json=$(fm_backend_herdr_core_get "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL") || return 0
  cwd=$(printf '%s' "$json" | jq -r '.foreground.cwd // .cwd // empty' 2>/dev/null) || return 0
  case "$cwd" in
    /*) printf '%s' "$cwd" ;;
  esac
  return 0
}

# --- pending literal buffer ----------------------------------------------------
#
# `hc send` is atomic paste+Enter and `hc keys` cannot type shifted
# punctuation, so unsubmitted literal text is held adapter-side until a flush
# (send_key Enter, send_text_line, send_text_submit) delivers it through one
# `hc send`. The buffer is a per-target file under this home's state dir, so
# it survives across the separate processes that run the literal and the
# flush.

# fm_backend_herdr_core_pending_path: the buffer file for a parsed target.
fm_backend_herdr_core_pending_path() {  # <session> <term>
  local state safe
  state=${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}
  safe=$(printf '%s__%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/.herdr-core-pending-%s' "$state" "$safe"
}

# fm_backend_herdr_core_pending_read: the buffered literal text, if any.
fm_backend_herdr_core_pending_read() {  # <session> <term>
  local f
  f=$(fm_backend_herdr_core_pending_path "$1" "$2")
  [ -f "$f" ] || return 1
  cat "$f"
}

# fm_backend_herdr_core_pending_drop: discard the buffered text (composer-clear
# key semantics, or after a successful flush).
fm_backend_herdr_core_pending_drop() {  # <session> <term>
  local f
  f=$(fm_backend_herdr_core_pending_path "$1" "$2")
  rm -f "$f" 2>/dev/null || true
}

# fm_backend_herdr_core_send_literal: record TEXT as unsubmitted input for
# <target>; the next Enter/line/submit delivers it through `hc send`. The
# terminal's live state is verified first so a literal is never queued for a
# dead endpoint. See the header for the reduced fidelity versus tmux -l.
fm_backend_herdr_core_send_literal() {  # <target> <text> [expected-label]
  local f dir
  fm_backend_herdr_core_target_ready "$1" "${3:-}" || return 1
  f=$(fm_backend_herdr_core_pending_path "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL")
  dir=${f%/*}
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s' "$2" >> "$f"
}

# fm_backend_herdr_core_send_combined: the actual `hc send`: pending text plus
# <text>, pasted and submitted in one atomic call. Any extra hc options come
# before the `--` delimiter that protects flag-looking text; options after it
# would be swallowed as positionals. On success the buffer is dropped; on
# failure it stays (the text was never delivered, so the caller's retry still
# owns it).
fm_backend_herdr_core_send_combined() {  # <session> <term> <text> [extra hc-send opts...]
  local session=$1 term=$2 text=$3 pending rc
  shift 3
  pending=$(fm_backend_herdr_core_pending_read "$session" "$term" 2>/dev/null || true)
  text="$pending$text"
  fm_backend_herdr_core_cli "$session" send "$term" "$@" -- "$text"
  rc=$?
  # hc's structured refusal codes (3 not_found, 9 blocked, 11 finished) are
  # load-bearing for send_text_submit's verdict - propagate, never flatten.
  [ "$rc" = 0 ] || return "$rc"
  fm_backend_herdr_core_pending_drop "$session" "$term"
}

# fm_backend_herdr_core_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c, C-u, C-d, arrows, Tab, Backspace, function keys) onto hc's key
# names. Unknown names pass through - hc refuses what it does not know with a
# structured invalid_params error.
fm_backend_herdr_core_normalize_key() {  # <key>
  case "$1" in
    Enter|enter|Return) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'esc' ;;
    Tab|tab) printf 'tab' ;;
    BTab|btab|shift+tab|Shift+Tab|Bspace|backspace|Backspace|BS|bs) printf 'backspace' ;;
    Delete|delete|DC|dc) printf 'delete' ;;
    Up|up) printf 'up' ;;
    Down|down) printf 'down' ;;
    Left|left) printf 'left' ;;
    Right|right) printf 'right' ;;
    Home|home) printf 'home' ;;
    End|end) printf 'end' ;;
    PageUp|pageup|PPage|ppage) printf 'pageup' ;;
    PageDown|pagedown|NPage|npage) printf 'pagedown' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl+c' ;;
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl+u' ;;
    C-d|c-d|ctrl+d|Ctrl+d|Ctrl+D|ctrl-d) printf 'ctrl+d' ;;
    C-z|c-z|ctrl+z|Ctrl+z|Ctrl+Z|ctrl-z) printf 'ctrl+z' ;;
    F[1-9]|F1[0-2]|f[1-9]|f1[0-2]) printf '%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" ;;
    space|Space) printf 'space' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_herdr_core_send_key: one named special key. Enter flushes the
# pending literal buffer through `hc send` (paste+Enter); every other key goes
# through `hc keys`. C-u and C-c clear the composer, so they drop the buffer
# as well.
fm_backend_herdr_core_send_key() {  # <target> <key> [expected-label]
  local key
  fm_backend_herdr_core_target_ready "$1" "${3:-}" || return 1
  key=$(fm_backend_herdr_core_normalize_key "$2")
  case "$key" in
    enter)
      if fm_backend_herdr_core_pending_read "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" >/dev/null 2>&1; then
        fm_backend_herdr_core_send_combined "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" '' >/dev/null
      else
        fm_backend_herdr_core_cli "$FM_BACKEND_HC_SESSION" keys "$FM_BACKEND_HC_TERMINAL" -- enter >/dev/null 2>&1
      fi
      ;;
    ctrl+u|ctrl+c)
      fm_backend_herdr_core_pending_drop "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL"
      fm_backend_herdr_core_cli "$FM_BACKEND_HC_SESSION" keys "$FM_BACKEND_HC_TERMINAL" -- "$key" >/dev/null 2>&1
      ;;
    *)
      fm_backend_herdr_core_cli "$FM_BACKEND_HC_SESSION" keys "$FM_BACKEND_HC_TERMINAL" -- "$key" >/dev/null 2>&1
      ;;
  esac
}

# fm_backend_herdr_core_send_text_line: type one line of TEXT and Enter in a
# single atomic `hc send`, flushing any pending literal ahead of it.
fm_backend_herdr_core_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_herdr_core_target_ready "$1" "${3:-}" || return 1
  fm_backend_herdr_core_send_combined "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" "$2" >/dev/null 2>&1
}

# --- native state --------------------------------------------------------------

# fm_backend_herdr_core_native_state_raw: <session> <term>'s reported OSC 7501
# status, one of working|idle|blocked plus anything hc adds later, or unknown
# for a program that reports nothing. No inventory check.
fm_backend_herdr_core_native_state_raw() {  # <session> <term>
  local json status
  json=$(fm_backend_herdr_core_get "$1" "$2") || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$json" | jq -r '
    if (.reported // false) != true then "unknown"
    elif (.status // "") == "" then "unknown"
    else .status end' 2>/dev/null) || status=unknown
  case "$status" in
    working|idle|blocked|waiting_input) printf '%s' "$status" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_herdr_core_foreground_class: what runs in <session>/<term>'s
# foreground, from one `hc get`:
#   agent          a verified harness (bin/fm-agent-process-lib.sh)
#   shell          an interactive shell in the foreground (or as the program
#                  itself when no foreground is reported)
#   shell-command  a shell given a command/script argument, which can hold an
#                  agent child
#   other          anything else
#   unreadable     the read failed
fm_backend_herdr_core_foreground_class() {  # <session> <term>
  local json fields name argv0 args nonopt
  json=$(fm_backend_herdr_core_get "$1" "$2") || { printf 'unreadable'; return 0; }
  fields=$(printf '%s' "$json" | jq -r '
    def one: tostring | split("\n") | join(" ");
    if (.foreground | type) == "object" then
      (.foreground.argv // []) as $argv
      | [ ((.foreground.name // "") | one),
          (($argv[0] // "") | one),
          ($argv | map(select(type == "string")) | join(" ") | one),
          ([$argv[1:][] | select(type == "string") | select(startswith("-") | not)] | length | tostring)
        ] | join("")
    else
      # No reported foreground (a direct `hc run <program>`): the program
      # argv is the running identity.
      ((.argv // []) as $argv
      | [ (($argv[0] // "") | sub(".*/"; "") | one),
          (($argv[0] // "") | one),
          ($argv | map(select(type == "string")) | join(" ") | one),
          "0"
        ] | join(""))
    end' 2>/dev/null) || { printf 'unreadable'; return 0; }
  [ -n "$fields" ] || { printf 'unreadable'; return 0; }
  IFS=$'\037' read -r name argv0 args nonopt <<EOF
$fields
EOF
  case "$(fm_agent_process_classify "$name" "$argv0" "$args")" in
    agent) printf 'agent' ;;
    shell)
      if [ "$nonopt" = 0 ]; then
        printf 'shell'
      else
        printf 'shell-command'
      fi
      ;;
    *) printf 'other' ;;
  esac
}

# fm_backend_herdr_core_busy_state: semantic busy state from the reported OSC
# 7501 status: working is busy, blocked is blocked (the agent waits on the
# human), idle is idle, and anything unreported or unreadable is unknown. A
# `busy` verdict is proven at process level first, as herdr's and tern's are:
# a lingering working record over a shell-only terminal (an agent that exited
# mid-turn) reads unknown, never busy.
fm_backend_herdr_core_busy_state() {  # <target> [expected-label] -> busy|idle|blocked|unknown
  local verdict
  fm_backend_herdr_core_target_ready "$1" "${2:-}" || { printf 'unknown'; return 0; }
  verdict=$(fm_backend_herdr_core_native_state_raw "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL")
  case "$verdict" in
    working) verdict=busy ;;
    blocked|waiting_input) verdict=blocked ;;
    idle) verdict=idle ;;
    *) verdict=unknown ;;
  esac
  if [ "$verdict" = busy ] \
    && [ "$(fm_backend_herdr_core_foreground_class "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL")" = shell ]; then
    verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_backend_herdr_core_agent_state: recovery-grade state for one recorded
# target; see bin/fm-backend.sh's fm_backend_agent_state for the shared
# vocabulary. `missing` needs the structured not_found; `dead` needs the
# record finished or an interactive shell alone in the foreground; a live
# terminal whose foreground cannot be attributed is `ambiguous`; a failed or
# contradictory read is `unreadable`.
fm_backend_herdr_core_agent_state() {  # <target>
  local state kind
  fm_backend_herdr_core_parse_target "${1:-}" || { printf 'unreadable'; return 0; }
  state=$(fm_backend_herdr_core_endpoint_state "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" "")
  kind=${state%%$'\t'*}
  case "$kind" in
    absent) printf 'missing'; return 0 ;;
    finished) printf 'dead'; return 0 ;;
    ready) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  case "$(fm_backend_herdr_core_foreground_class "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL")" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    unreadable) printf 'unreadable' ;;
    *) printf 'ambiguous' ;;
  esac
}

# --- submit ---------------------------------------------------------------------

# fm_backend_herdr_core_send_text_submit: flush the pending buffer plus <text>
# through ONE `hc send --wait`, which pastes, presses Enter, and reports the
# turn it started. Echoes empty|pending|pending-unproven|unknown|send-failed,
# a subset of the proof-carrying submit vocabulary.
#
# started:true (or a still-working wait) confirms delivery natively, which no
# composer text can fake. A silent (non-7501) program answers started:null
# after its check-in timeout; the send still typed and entered, so the
# verdict falls through to the shared composer classifier's screen verdict.
# A blocked terminal refuses with exit 9 before typing - a hard stop, never
# retried with --force, reported as unknown with the refusal on stderr.
fm_backend_herdr_core_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  local wait_secs out rc started wait_status verdict
  case "$retries" in ''|*[!0-9]*) retries=1 ;; esac
  case "$sleep_s" in ''|*[!0-9.]*) sleep_s=0.4 ;; esac
  case "$settle" in ''|*[!0-9.]*) settle=0 ;; esac
  fm_backend_herdr_core_target_ready "$target" "$expected_label" || { printf 'send-failed'; return 0; }
  wait_secs=$(awk -v r="$retries" -v s="$sleep_s" 'BEGIN { v = r * s; if (v < 1) v = 1; printf "%d", (v == int(v) ? v : int(v) + 1) }' 2>/dev/null)
  case "$wait_secs" in ''|*[!0-9]*|0) wait_secs=1 ;; esac
  [ "$settle" = 0 ] || sleep "$settle"
  set +e
  out=$(fm_backend_herdr_core_send_combined "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" "$text" --wait --timeout "$wait_secs" --json 2>&1)
  rc=$?
  set -e
  case "$rc" in
    0) ;;
    9)
      echo "error: hc send refused $FM_BACKEND_HC_SESSION:$FM_BACKEND_HC_TERMINAL - the terminal is blocked waiting on input (never forced): $out" >&2
      printf 'unknown'
      return 0
      ;;
    3|11)
      printf 'send-failed'
      return 0
      ;;
    *)
      printf 'send-failed'
      return 0
      ;;
  esac
  started=$(printf '%s' "$out" | jq -r '.started // empty' 2>/dev/null)
  wait_status=$(printf '%s' "$out" | jq -r '.wait.status // empty' 2>/dev/null)
  if [ "$started" = true ] || [ "$wait_status" = working ]; then
    printf 'empty'
    return 0
  fi
  verdict=$(fm_backend_herdr_core_composer_state "$target" "$expected_label")
  case "$verdict" in
    empty|pending|pending-unproven) printf '%s' "$verdict" ;;
    *) printf 'unknown' ;;
  esac
}

# --- teardown and discovery -----------------------------------------------------

# fm_backend_herdr_core_kill: end the task's terminal. A target already gone
# returns 0 and is not touched. A finished record is removed (hc rm). A live
# terminal is killed (synchronous) then removed. A nonzero return means the
# close could not be proven and the endpoint may still exist: an unreadable
# record, a label mismatch, or a terminal still listed after its kill+rm - so
# the caller keeps the durable records that name it.
fm_backend_herdr_core_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} want='' state kind i=0
  if ! fm_backend_herdr_core_parse_target "${1:-}"; then
    echo "error: refusing to close malformed herdr-core target '${1:-}'" >&2
    return 1
  fi
  if [ -n "$expected_label" ]; then
    case "$expected_label" in
      fm-*) want=${expected_label#fm-} ;;
      *) want=$expected_label ;;
    esac
  fi
  state=$(fm_backend_herdr_core_endpoint_state "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" "$want")
  kind=${state%%$'\t'*}
  case "$kind" in
    absent) return 0 ;;
    finished) ;;
    ready) ;;
    renamed)
      echo "error: herdr-core terminal $FM_BACKEND_HC_TERMINAL in session $FM_BACKEND_HC_SESSION no longer carries fm.id=$want, so it cannot be verified as this task's endpoint; not closing it" >&2
      return 1
      ;;
    *)
      echo "error: herdr-core inventory could not be read, so terminal $FM_BACKEND_HC_TERMINAL cannot be verified for closing" >&2
      return 1
      ;;
  esac
  if [ "$kind" = ready ]; then
    fm_backend_herdr_core_cli "$FM_BACKEND_HC_SESSION" kill "$FM_BACKEND_HC_TERMINAL" --json >/dev/null 2>&1 || true
    # kill is synchronous, but let a slow reporter settle before rm refuses.
    while :; do
      state=$(fm_backend_herdr_core_endpoint_state "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" "")
      kind=${state%%$'\t'*}
      [ "$kind" != ready ] && break
      i=$((i + 1))
      [ "$i" -lt 10 ] || break
      sleep 0.2
    done
    if [ "$kind" = ready ]; then
      echo "error: herdr-core terminal $FM_BACKEND_HC_TERMINAL is still live after kill" >&2
      return 1
    fi
  fi
  fm_backend_herdr_core_cli "$FM_BACKEND_HC_SESSION" rm "$FM_BACKEND_HC_TERMINAL" --json >/dev/null 2>&1 || true
  state=$(fm_backend_herdr_core_endpoint_state "$FM_BACKEND_HC_SESSION" "$FM_BACKEND_HC_TERMINAL" "")
  case "${state%%$'\t'*}" in
    absent) return 0 ;;
    ready|finished|renamed)
      echo "error: herdr-core terminal $FM_BACKEND_HC_TERMINAL is still present after kill+rm" >&2
      return 1
      ;;
    *)
      echo "error: herdr-core terminal $FM_BACKEND_HC_TERMINAL could not be read after kill+rm, so whether it survived is unknown" >&2
      return 1
      ;;
  esac
}

# fm_backend_herdr_core_list_live: recovery/orphan discovery. Lists every live
# terminal of this home's session carrying fm.home=<this home's tag> with a
# non-empty fm.id label, one "<session>:<addr>\tfm-<id>" line per task. The
# label pair is the ownership claim - never a stored id. Read-only.
fm_backend_herdr_core_list_live() {
  local session tag listing addr json fid state
  session=$(fm_backend_herdr_core_session_name)
  fm_backend_herdr_core_valid_session "$session" || return 0
  tag=$(fm_backend_hometag)
  listing=$(fm_backend_herdr_core_cli "$session" ls --json --all --label "fm.home=$tag" 2>/dev/null) || return 0
  printf '%s' "$listing" | jq -r '.terminals[]?.address' 2>/dev/null | while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    json=$(fm_backend_herdr_core_get "$session" "$addr" 2>/dev/null) || continue
    fid=$(printf '%s' "$json" | jq -r '.labels["fm.id"] // empty' 2>/dev/null)
    state=$(printf '%s' "$json" | jq -r '.state // empty' 2>/dev/null)
    [ "$state" = live ] || continue
    [ -n "$fid" ] || continue
    printf '%s:%s\tfm-%s\n' "$session" "$addr" "$fid"
  done
  return 0
}
