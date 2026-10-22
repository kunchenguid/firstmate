#!/usr/bin/env bash
# bin/backends/rex.sh - the Rex session-provider adapter (EXPERIMENTAL).
#
# Rex (https://www.superlogical.com/rex) is a terminal multiplexer whose
# hierarchy is server > session > window (a tab) > block (a pane). Rex is a
# session provider ONLY: the worktree provider stays treehouse. Modeled on
# bin/backends/paseo.sh for CLI mechanics and home-scoped names, with the
# Herdr adapter's recovery-grade control plane. Sourced only through
# bin/fm-backend.sh's fm_backend_source in normal operation; the unit tests
# source it directly. docs/rex-backend.md owns the user-facing contract and
# docs/verification/runtime-backends.md#rex the live evidence.
#
# Container shape: ONE window (tab) PER TASK, created focus-safe with
# `window new --focus=false`. When Firstmate itself runs directly inside a Rex
# block (TERM_PROGRAM=rex with REX_SESSION and REX_BLOCK, and the server
# confirms that block lives in that session), every task tab goes into that
# launcher session. Otherwise, and for a secondmate's own home, the tab goes
# into ONE session per home labeled with the home tag
# (bin/fm-backend-hometag-lib.sh), adopted when exactly one session carries
# that label, created once when none does, and refused when several do. A
# created session's first window becomes the first task's tab, and cleanup
# kills that per-home session once its last window closes. `rex window new`
# rather than `rex run` opens the tab because `rex run` requires a command
# and a task tab is an ordinary login shell that spawn then drives.
#
# Target string shape: "<session-uuid>:<block-uuid>". Rex ids carry their own
# colon (`session:<uuid>`, `block:<uuid>`), so the recorded target strips both
# prefixes and the adapter re-adds them for every CLI call. The prefixed ids
# are also recorded as rex_session_id/rex_window_id/rex_block_id, plus the
# server endpoint as rex_server (bin/fm-spawn.sh writes them; bin/fm-backend.sh
# validates them).
#
# ROUTING AUTHORITY: the immutable block id. Rex never reuses an id, so the
# recorded id names exactly one block for its whole life and nothing else
# afterwards; labels are mutable and non-unique and are used only for the
# human (`fm-<id>` window labels), for duplicate refusal, and for list_live
# discovery (the home-scoped block label). Every call passes an explicit
# `-s <session-id>` and `-b <block-id>`: without -s the CLI defaults to the
# caller's own REX_SESSION, which is the captain's session.
#
# Exit codes (verified live, docs/rex-backend.md): 0 ok, 2 invalid command
# line, 3 target not found (or an ambiguous label, which full ids never are),
# 4 server unreachable. Passive reads pass --autostart=false so a probe never
# starts a server; spawn, cleanup, and the control plane's absence recheck let
# the CLI start a missing personal server, because a stopped server ends every
# session on it and a started one then answers "not found" with authority.
#
# Viewport: `rex capture` returns scrollback plus the screen and has no
# viewport-only mode, so the visible viewport is DERIVED as the last
# `size.rows` lines of the untrimmed capture. A capture always ends with the
# full screen grid (blank rows included), and an alternate-screen program's
# capture is the screen alone, so the derivation holds on both screens; a
# resize landing between the two reads can skew it by the size difference.
#
# Requires: rex (the CLI shipped inside the Rex server bundle, which Rex puts
# on REX_BIN_DIR rather than PATH; see fm_backend_rex_bin) and jq. Bootstrap
# checks them through fm_backend_required_tools only when rex is the resolved
# backend; this adapter gates them again, plus the server API revision,
# before spawning.

FM_BACKEND_REX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_REX_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_REX_ROOT/bin/fm-backend-hometag-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_REX_ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_REX_ROOT/bin/fm-agent-process-lib.sh"

# Verified floor: the API revision the live verification ran against.
FM_BACKEND_REX_MIN_API=5
# An unviewed block is 80x24, which wraps harness TUIs far more than any real
# viewer; every task block is resized to this right after it is created. A
# client that later views the block takes ownership and applies its own size.
FM_BACKEND_REX_COLUMNS=${FM_BACKEND_REX_COLUMNS:-200}
FM_BACKEND_REX_ROWS=${FM_BACKEND_REX_ROWS:-50}
FM_BACKEND_REX_BUNDLE_BIN="${FM_BACKEND_REX_BUNDLE_BIN:-$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex}"

# fm_backend_rex_bin: the running server's own CLI first. Rex exports
# REX_BIN_DIR into every block and prepends it only for --shell=none commands,
# because shell startup files commonly reset PATH; then PATH, then the server
# bundle path.
fm_backend_rex_bin() {
  local found
  if [ -n "${REX_BIN_DIR:-}" ] && [ -x "$REX_BIN_DIR/rex" ]; then
    printf '%s' "$REX_BIN_DIR/rex"
    return 0
  fi
  if found=$(command -v rex 2>/dev/null) && [ -n "$found" ]; then
    printf '%s' "$found"
    return 0
  fi
  if [ -x "$FM_BACKEND_REX_BUNDLE_BIN" ]; then
    printf '%s' "$FM_BACKEND_REX_BUNDLE_BIN"
    return 0
  fi
  return 1
}

fm_backend_rex_tool_check() {
  fm_backend_rex_bin >/dev/null 2>&1 || {
    echo "error: backend=rex selected but the 'rex' CLI was not found at \$REX_BIN_DIR/rex, on PATH, or at $FM_BACKEND_REX_BUNDLE_BIN (https://www.superlogical.com/rex)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=rex selected but 'jq' is not installed (required to parse rex's JSON output)" >&2
    return 1
  }
  return 0
}

# fm_backend_rex_cli: one CLI call that may start a missing personal server.
fm_backend_rex_cli() {  # <rex-args...>
  local bin
  bin=$(fm_backend_rex_bin) || return 1
  "$bin" "$@"
}

# fm_backend_rex_read: one CLI call that never starts a server; an unreachable
# server exits 4 instead.
fm_backend_rex_read() {  # <rex-args...>
  fm_backend_rex_cli --autostart=false "$@"
}

# fm_backend_rex_failure_class: classify a failed call from its exit status
# and stderr. `missing` is a structured not-found; an ambiguous match (also
# exit 3) cannot happen for a full id and reads as an error.
fm_backend_rex_failure_class() {  # <rc> <stderr> -> missing|unreachable|error
  case "$1" in
    3)
      case "$2" in
        *"not found"*) printf 'missing' ;;
        *) printf 'error' ;;
      esac
      ;;
    4) printf 'unreachable' ;;
    *) printf 'error' ;;
  esac
}

# fm_backend_rex_version_check: refuse a missing CLI, or a CLI or server below
# the verified API revision. The server read may start a missing personal
# server; it runs only on the spawn path.
fm_backend_rex_version_check() {
  local raw client_api status server_api
  fm_backend_rex_tool_check || return 1
  raw=$(fm_backend_rex_cli version 2>/dev/null) || {
    echo "error: 'rex version' failed; is Rex installed correctly?" >&2
    return 1
  }
  client_api=$(printf '%s\n' "$raw" | sed -n 's/^api: revision \([0-9][0-9]*\).*/\1/p' | head -1)
  case "$client_api" in
    ''|*[!0-9]*)
      echo "error: could not parse an API revision from 'rex version'; refusing to use an unverified rex build" >&2
      return 1
      ;;
  esac
  if [ "$client_api" -lt "$FM_BACKEND_REX_MIN_API" ]; then
    echo "error: the rex CLI speaks API revision $client_api, older than the verified minimum $FM_BACKEND_REX_MIN_API; update Rex before using backend=rex" >&2
    return 1
  fi
  status=$(fm_backend_rex_cli api call server.status 2>/dev/null) || {
    echo "error: the Rex server could not be reached or started ('rex api call server.status' failed); see docs/rex-backend.md 'Setup'" >&2
    return 1
  }
  server_api=$(printf '%s' "$status" | jq -r '.api_revision // empty' 2>/dev/null)
  case "$server_api" in
    ''|*[!0-9]*)
      echo "error: could not read the Rex server's API revision; refusing to use an unverified rex server" >&2
      return 1
      ;;
  esac
  if [ "$server_api" -lt "$FM_BACKEND_REX_MIN_API" ]; then
    echo "error: the Rex server speaks API revision $server_api, older than the verified minimum $FM_BACKEND_REX_MIN_API; update Rex before using backend=rex" >&2
    return 1
  fi
  return 0
}

# fm_backend_rex_container_ensure: the spawn-time gate (tool, CLI, server).
# The container itself is chosen inside fm_backend_rex_create_task, under the
# session lock.
fm_backend_rex_container_ensure() {
  fm_backend_rex_version_check
}

# fm_backend_rex_server_endpoint: the server address the CLI resolves from this
# process, as `rex whoami` reports it. Recorded at spawn as rex_server so the
# control plane can refuse an absence claim read from a different server.
fm_backend_rex_server_endpoint() {
  local out endpoint
  out=$(fm_backend_rex_cli whoami --json 2>/dev/null) || return 1
  endpoint=$(printf '%s' "$out" | jq -r '.endpoint // empty' 2>/dev/null)
  case "$endpoint" in
    ''|*[[:space:]]*) return 1 ;;
  esac
  printf '%s' "$endpoint"
}

fm_backend_rex_uuid_valid() {  # <uuid>
  case "$1" in
    ''|*[!0-9a-f-]*) return 1 ;;
  esac
}

# fm_backend_rex_id_valid: a full prefixed Rex id of the given kind.
fm_backend_rex_id_valid() {  # <kind> <id>
  case "$2" in
    "$1":*) fm_backend_rex_uuid_valid "${2#"$1":}" ;;
    *) return 1 ;;
  esac
}

# fm_backend_rex_parse_target: split "<session-uuid>:<block-uuid>" and restore
# the prefixes. Sets FM_BACKEND_REX_SESSION and FM_BACKEND_REX_BLOCK.
fm_backend_rex_parse_target() {  # <target>
  local target=$1 left right
  FM_BACKEND_REX_SESSION=
  FM_BACKEND_REX_BLOCK=
  case "$target" in
    *:*:*|'') return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  left=${target%%:*}
  right=${target#*:}
  fm_backend_rex_uuid_valid "$left" && fm_backend_rex_uuid_valid "$right" || return 1
  FM_BACKEND_REX_SESSION="session:$left"
  FM_BACKEND_REX_BLOCK="block:$right"
}

# fm_backend_rex_target: the recorded target string for a session and block id.
fm_backend_rex_target() {  # <session-id> <block-id>
  printf '%s:%s' "${1#session:}" "${2#block:}"
}

# fm_backend_rex_home_label: the per-home session label, home-scoped so two
# Firstmate homes sharing one Rex server never adopt each other's session.
fm_backend_rex_home_label() {
  fm_backend_hometag
}

# fm_backend_rex_scoped_name: the home-scoped BLOCK label for an fm-<id> task
# label, used for duplicate refusal and list_live; never for routing.
fm_backend_rex_scoped_name() {  # <fm-task-label>
  local label=$1 rest
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$(fm_backend_rex_home_label)" "$rest"
}

# fm_backend_rex_session_view: one session's structured view (windows, their
# layers, and blocks with labels).
fm_backend_rex_session_view() {  # <session-id>
  fm_backend_rex_read api call -s "$1" session.view 2>/dev/null
}

# fm_backend_rex_launcher_session: the Rex session this process runs directly
# inside. Returns 0 and prints it when TERM_PROGRAM=rex, REX_SESSION and
# REX_BLOCK are set, and the server confirms that block lives in that
# session; 2 when this process is not directly inside Rex (a tmux or Herdr
# nested in a Rex block rewrites TERM_PROGRAM and is not); 1 when the claim
# cannot be confirmed, which the caller refuses rather than guessing a
# placement.
fm_backend_rex_launcher_session() {
  local view
  [ "${TERM_PROGRAM:-}" = rex ] && [ -n "${REX_SESSION:-}" ] && [ -n "${REX_BLOCK:-}" ] || return 2
  if ! fm_backend_rex_id_valid session "$REX_SESSION" || ! fm_backend_rex_id_valid block "$REX_BLOCK"; then
    echo "error: this process claims Rex session '$REX_SESSION' block '$REX_BLOCK', which are not valid Rex ids; refusing to guess where task tabs belong" >&2
    return 1
  fi
  view=$(fm_backend_rex_session_view "$REX_SESSION") || {
    echo "error: this process claims Rex session $REX_SESSION, but the Rex server could not show it; refusing to guess where task tabs belong" >&2
    return 1
  }
  printf '%s' "$view" | jq -e --arg b "$REX_BLOCK" \
    '[.windows[]?.layers[]?.blocks[]? | select(.block_id == $b)] | length == 1' >/dev/null 2>&1 || {
    echo "error: this process claims Rex block $REX_BLOCK in session $REX_SESSION, but that session does not hold it; refusing to guess where task tabs belong" >&2
    return 1
  }
  printf '%s' "$REX_SESSION"
}

# fm_backend_rex_session_lock / _unlock: one home-wide lock (the shared
# stale-owner lock from bin/fm-wake-lib.sh, loaded on demand) that serializes
# choosing or creating the per-home session plus opening a tab against killing
# an emptied per-home session, so cleanup can never kill a session a
# concurrent spawn has just opened a tab in, and two spawns never both create
# the per-home session. Bounded: a spawn that cannot get it refuses, cleanup
# skips the session retirement.
FM_BACKEND_REX_LOCK_ATTEMPTS="${FM_BACKEND_REX_LOCK_ATTEMPTS:-300}"
fm_backend_rex_session_lock_path() {
  printf '%s/.rex-session.lock' "${STATE:-$FM_HOME/state}"
}
fm_backend_rex_session_lock() {
  local attempt=0 lock
  if ! declare -F fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_BACKEND_REX_ROOT/bin/fm-wake-lib.sh"
  fi
  lock=$(fm_backend_rex_session_lock_path)
  mkdir -p "${lock%/*}" 2>/dev/null || return 1
  while [ "$attempt" -lt "$FM_BACKEND_REX_LOCK_ATTEMPTS" ]; do
    fm_lock_try_acquire "$lock" && return 0
    sleep 0.1
    attempt=$((attempt + 1))
  done
  return 1
}
fm_backend_rex_session_unlock() {
  fm_lock_release "$(fm_backend_rex_session_lock_path)" || true
}

# fm_backend_rex_home_sessions: ids of the live sessions labeled <label>, one
# per line. Fails when the inventory cannot be read, so a caller about to
# create a session never mistakes an unreadable list for "none".
fm_backend_rex_home_sessions() {  # <label>
  local list
  list=$(fm_backend_rex_cli ls --json 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '.sessions | type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$list" | jq -r --arg want "$1" '.sessions[] | select(.label == $want) | .session_id'
}

# fm_backend_rex_create_task: open the task's tab and print
# "<session-id> <window-id> <block-id>". <relationship> is launcher-home for a
# crewmate or scout of THIS home (the launcher's own Rex session when there is
# one) and other-home for a --secondmate launch, which always uses that other
# home's own per-home session (the caller shadows FM_HOME). The window label
# is the task label the captain reads in the tab bar; the block label is the
# home-scoped name. <mode> is spawn or reclaim and decides what a block
# already carrying that name in the chosen session means
# (fm_backend_rex_open_tab_locked).
fm_backend_rex_create_task() {  # <label> <cwd> [launcher-home|other-home] [spawn|reclaim]
  local label=$1 cwd=$2 relationship=${3:-launcher-home} mode=${4:-spawn} home_label sid wid bid
  local sessions count out launcher_rc=2
  home_label=$(fm_backend_rex_home_label)
  fm_backend_rex_session_lock || {
    echo "error: could not take the rex session lock; refusing to create '$label'" >&2
    return 1
  }
  sid=
  if [ "$relationship" = launcher-home ]; then
    sid=$(fm_backend_rex_launcher_session) || launcher_rc=$?
    [ -z "$sid" ] || launcher_rc=0
    if [ "$launcher_rc" -eq 1 ]; then
      fm_backend_rex_session_unlock
      return 1
    fi
  fi
  wid=
  bid=
  if [ -z "$sid" ]; then
    if ! sessions=$(fm_backend_rex_home_sessions "$home_label"); then
      fm_backend_rex_session_unlock
      echo "error: could not read the rex session inventory; refusing to create '$label'" >&2
      return 1
    fi
    count=$(printf '%s' "$sessions" | grep -c . || true)
    case "$count" in
      0)
        if ! out=$(fm_backend_rex_cli new "$home_label" --window "$label" --cwd "$cwd" --json); then
          fm_backend_rex_session_unlock
          echo "error: rex could not create the '$home_label' session for '$label'" >&2
          return 1
        fi
        sid=$(printf '%s' "$out" | jq -r '.session_id // empty' 2>/dev/null)
        wid=$(printf '%s' "$out" | jq -r '.initial_windows[0].window_id // empty' 2>/dev/null)
        bid=$(printf '%s' "$out" | jq -r '.initial_windows[0].block_ids[0] // empty' 2>/dev/null)
        ;;
      1) sid=$sessions ;;
      *)
        fm_backend_rex_session_unlock
        echo "error: $count rex sessions are labeled '$home_label'; refusing to guess which one belongs to this home" >&2
        return 1
        ;;
    esac
  fi
  if [ -z "$bid" ]; then
    fm_backend_rex_open_tab_locked "$sid" "$label" "$cwd" "$mode" || {
      [ "$?" -ne 2 ] || echo "error: rex session $sid disappeared before a tab for '$label' could be opened" >&2
      fm_backend_rex_session_unlock
      return 1
    }
    wid=$FM_BACKEND_REX_NEW_WINDOW
    bid=$FM_BACKEND_REX_NEW_BLOCK
  fi
  fm_backend_rex_session_unlock
  fm_backend_rex_finish_tab "$sid" "$wid" "$bid" "$label"
}

# fm_backend_rex_create_task_in_session: open a fresh tab for a task in an
# EXACT existing session, the relaunch reclaim path for a task whose recorded
# block is proven gone. Prints the same triple. Returns 2, creating nothing,
# when that session is itself gone (a structured not-found), and 1 on any
# other failure.
fm_backend_rex_create_task_in_session() {  # <session-id> <label> <cwd>
  local sid=$1 label=$2 cwd=$3 rc=0
  fm_backend_rex_id_valid session "$sid" || return 1
  fm_backend_rex_session_lock || {
    echo "error: could not take the rex session lock; refusing to reclaim '$label'" >&2
    return 1
  }
  fm_backend_rex_open_tab_locked "$sid" "$label" "$cwd" reclaim || rc=$?
  fm_backend_rex_session_unlock
  [ "$rc" -eq 0 ] || return "$rc"
  fm_backend_rex_finish_tab "$sid" "$FM_BACKEND_REX_NEW_WINDOW" "$FM_BACKEND_REX_NEW_BLOCK" "$label"
}

# fm_backend_rex_open_tab_locked: the one tab-opening boundary, run under the
# session lock. Opens the task's tab focus-safe in EXACT session <sid> and sets
# FM_BACKEND_REX_NEW_WINDOW and FM_BACKEND_REX_NEW_BLOCK. Returns 2, creating
# nothing, when that session is gone (a structured not-found), and 1 on any
# other failure. A block already carrying the task's scoped label refuses a
# spawn. On reclaim it is the husk of an earlier reclaim that refused before
# its record was republished, wherever that reclaim placed it: a bare shell
# there is closed first, and anything else refuses. Call it directly, not in a
# command substitution, so the globals reach the caller.
fm_backend_rex_open_tab_locked() {  # <session-id> <label> <cwd> <spawn|reclaim>
  local sid=$1 label=$2 cwd=$3 mode=$4 name view err rc husk state out
  FM_BACKEND_REX_NEW_WINDOW=
  FM_BACKEND_REX_NEW_BLOCK=
  name=$(fm_backend_rex_scoped_name "$label")
  err=$(mktemp "${TMPDIR:-/tmp}/fm-rex-err.XXXXXX") || return 1
  view=$(fm_backend_rex_cli api call -s "$sid" session.view 2>"$err")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$(fm_backend_rex_failure_class "$rc" "$(cat "$err" 2>/dev/null)")" = missing ]; then
      rm -f "$err"
      return 2
    fi
    rm -f "$err"
    echo "error: could not read rex session $sid" >&2
    return 1
  fi
  rm -f "$err"
  printf '%s' "$view" | jq -e '.windows | type == "array"' >/dev/null 2>&1 || {
    echo "error: could not read rex session $sid" >&2
    return 1
  }
  while IFS= read -r husk; do
    [ -n "$husk" ] || continue
    if [ "$mode" != reclaim ]; then
      echo "error: rex block '$name' already exists in session $sid" >&2
      return 1
    fi
    state=$(fm_backend_rex_agent_state "$(fm_backend_rex_target "$sid" "$husk")")
    case "$state" in
      missing) continue ;;
      dead) ;;
      *)
        echo "error: rex block $husk already carries '$name' and is not a bare shell ($state); refusing to open a second tab for it" >&2
        return 1
        ;;
    esac
    fm_backend_rex_cli block close -s "$sid" "$husk" >/dev/null 2>&1 || true
    if [ "$(fm_backend_rex_block_presence "$(fm_backend_rex_target "$sid" "$husk")")" != missing ]; then
      echo "error: could not close the leftover rex block $husk carrying '$name'" >&2
      return 1
    fi
  done <<EOF
$(printf '%s' "$view" | jq -r --arg n "$name" '.windows[]?.layers[]?.blocks[]? | select(.label == $n) | .block_id' 2>/dev/null)
EOF
  out=$(fm_backend_rex_cli window new -s "$sid" "$label" --focus=false --cwd "$cwd" --json) || {
    echo "error: rex could not open a tab for '$label' in session $sid" >&2
    return 1
  }
  FM_BACKEND_REX_NEW_WINDOW=$(printf '%s' "$out" | jq -r '.window_id // empty' 2>/dev/null)
  FM_BACKEND_REX_NEW_BLOCK=$(printf '%s' "$out" | jq -r '.block_ids[0] // empty' 2>/dev/null)
}

# fm_backend_rex_finish_tab: validate a freshly opened tab's ids, label its
# block with the home-scoped name, size it, and print
# "<session-id> <window-id> <block-id>".
fm_backend_rex_finish_tab() {  # <session-id> <window-id> <block-id> <label>
  local sid=$1 wid=$2 bid=$3 label=$4 name
  if ! fm_backend_rex_id_valid session "$sid" || ! fm_backend_rex_id_valid window "$wid" \
    || ! fm_backend_rex_id_valid block "$bid"; then
    echo "error: rex did not return session, window, and block ids for '$label'" >&2
    return 1
  fi
  name=$(fm_backend_rex_scoped_name "$label")
  fm_backend_rex_cli block rename -s "$sid" "$bid" "$name" >/dev/null 2>&1 \
    || echo "warning: could not label rex block $bid '$name'; routing uses its id, but duplicate detection cannot see it" >&2
  fm_backend_rex_cli block call -s "$sid" -b "$bid" resize \
    "{\"columns\":$FM_BACKEND_REX_COLUMNS,\"rows\":$FM_BACKEND_REX_ROWS}" >/dev/null 2>&1 \
    || echo "warning: could not resize rex block $bid to ${FM_BACKEND_REX_COLUMNS}x$FM_BACKEND_REX_ROWS; harness screens may wrap" >&2
  printf '%s %s %s' "$sid" "$wid" "$bid"
}

# fm_backend_rex_block_call: one read-only block method on the target.
fm_backend_rex_block_call() {  # <target> <method>
  fm_backend_rex_parse_target "$1" || return 1
  fm_backend_rex_read block call -s "$FM_BACKEND_REX_SESSION" -b "$FM_BACKEND_REX_BLOCK" "$2" 2>/dev/null
}

# fm_backend_rex_target_ready: the recorded block exists. The id is the routing
# authority (never reused), so an optional expected label adds nothing a live
# id does not already prove; it is accepted for the shared call shape.
fm_backend_rex_target_ready() {  # <target> [expected-label]
  fm_backend_rex_block_call "$1" size >/dev/null
}

# fm_backend_rex_current_path: the block's foreground process cwd, which
# follows a nested subshell such as `treehouse get` (verified live). Empty on
# any error.
fm_backend_rex_current_path() {  # <target> [expected-label]
  local out
  out=$(fm_backend_rex_block_call "$1" process) || return 0
  printf '%s' "$out" | jq -r '.foreground.cwd // empty' 2>/dev/null
}

# fm_backend_rex_send_literal: literal, UNSUBMITTED input. `--` guards an
# option-shaped payload; Rex refuses empty input, which has nothing to send.
fm_backend_rex_send_literal() {  # <target> <text> [expected-label]
  fm_backend_rex_parse_target "$1" || return 1
  [ -n "$2" ] || return 0
  fm_backend_rex_read send -s "$FM_BACKEND_REX_SESSION" -b "$FM_BACKEND_REX_BLOCK" -- "$2" >/dev/null 2>&1
}

# fm_backend_rex_key_name: Firstmate's key vocabulary in Rex's binding syntax
# (each verified live). Anything else is refused rather than guessed.
fm_backend_rex_key_name() {  # <key>
  case "$1" in
    Enter) printf 'enter' ;;
    Escape) printf 'escape' ;;
    Tab) printf 'tab' ;;
    C-c) printf 'ctrl+c' ;;
    C-u) printf 'ctrl+u' ;;
    *) return 1 ;;
  esac
}

fm_backend_rex_send_key() {  # <target> <key> [expected-label]
  local key
  key=$(fm_backend_rex_key_name "$2") || {
    echo "error: unsupported rex key '$2'" >&2
    return 1
  }
  fm_backend_rex_parse_target "$1" || return 1
  fm_backend_rex_read send-key -s "$FM_BACKEND_REX_SESSION" -b "$FM_BACKEND_REX_BLOCK" "$key" >/dev/null 2>&1
}

# fm_backend_rex_send_text_line: send one line then submit it.
fm_backend_rex_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_rex_send_literal "$1" "$2" || return 1
  fm_backend_rex_send_key "$1" Enter && return 0
  fm_backend_rex_send_key "$1" C-c >/dev/null 2>&1 && return 1
  return 2
}

# fm_backend_rex_capture_vt_grid: the whole styled capture, one line per row,
# carriage returns stripped. The vt format ends with the full screen grid:
# rows are joined by CRLF and a final LF is added only when the output does
# not already end in one, so an empty bottom row leaves the output ending in
# CRLF with that row implicit (verified live). That row is restored here, so
# the last size.rows lines are exactly the screen. The plain text format is
# not used for this: it drops trailing blank rows.
fm_backend_rex_capture_vt_grid() {  # <target>
  local out
  fm_backend_rex_parse_target "$1" || return 1
  out=$(fm_backend_rex_read capture -s "$FM_BACKEND_REX_SESSION" -b "$FM_BACKEND_REX_BLOCK" \
    --format=vt 2>/dev/null && printf x) || return 1
  out=${out%x}
  case "$out" in
    *$'\r\n') out="$out"$'\n' ;;
  esac
  printf '%s' "$out" | tr -d '\r'
}

# fm_backend_rex_capture: bounded plain-text capture. Rex returns scrollback
# plus the screen, so trailing blank rows are trimmed by --trim and the tail is
# taken locally.
fm_backend_rex_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-200} out
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  fm_backend_rex_parse_target "$1" || return 1
  out=$(fm_backend_rex_read capture -s "$FM_BACKEND_REX_SESSION" -b "$FM_BACKEND_REX_BLOCK" \
    --trim 2>/dev/null) || return 1
  printf '%s\n' "$out" | tr -d '\r' | tail -n "$lines"
}

# fm_backend_rex_rows: the block's current row count.
fm_backend_rex_rows() {  # <target>
  local out rows
  out=$(fm_backend_rex_block_call "$1" size) || return 1
  rows=$(printf '%s' "$out" | jq -r '.rows // empty' 2>/dev/null)
  case "$rows" in ''|0|*[!0-9]*) return 1 ;; esac
  printf '%s' "$rows"
}

# fm_backend_rex_visible_capture_vt: the derived viewport (see the header) with
# SGR styling preserved, so the composer classifier can strip ghost text: the
# last size.rows rows of the styled capture grid.
fm_backend_rex_visible_capture_vt() {  # <target>
  local rows grid
  rows=$(fm_backend_rex_rows "$1") || return 1
  grid=$(fm_backend_rex_capture_vt_grid "$1" && printf x) || return 1
  printf '%s' "${grid%x}" | tail -n "$rows"
}

# fm_backend_rex_visible_capture: the same derived viewport as plain text.
fm_backend_rex_visible_capture() {  # <target> [expected-label]
  local screen
  screen=$(fm_backend_rex_visible_capture_vt "$1" && printf x) || return 1
  printf '%s' "${screen%x}" | fm_composer_strip_ansi
}

# fm_backend_rex_process_chain: read the block's process view into
# FM_BACKEND_REX_CHAIN, one "<role>\t<pid>\t<name>\t<path>\t<argv0>" line per
# process, foreground first then each ancestor; empty for a block with no
# foreground process. FM_BACKEND_REX_LAST_EXIT is `exited` once the terminal
# child has exited. Fails, with FM_BACKEND_REX_READ_CLASS set to
# missing|unreachable|error, when the block cannot be read. Call it directly,
# not in a command substitution, so the globals reach the caller.
fm_backend_rex_process_chain() {  # <target>
  local out err rc
  FM_BACKEND_REX_CHAIN=
  FM_BACKEND_REX_READ_CLASS=
  FM_BACKEND_REX_LAST_EXIT=
  fm_backend_rex_parse_target "$1" || { FM_BACKEND_REX_READ_CLASS=error; return 1; }
  err=$(mktemp "${TMPDIR:-/tmp}/fm-rex-err.XXXXXX") || { FM_BACKEND_REX_READ_CLASS=error; return 1; }
  out=$(fm_backend_rex_read block call -s "$FM_BACKEND_REX_SESSION" -b "$FM_BACKEND_REX_BLOCK" process 2>"$err")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    FM_BACKEND_REX_READ_CLASS=$(fm_backend_rex_failure_class "$rc" "$(cat "$err" 2>/dev/null)")
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || { FM_BACKEND_REX_READ_CLASS=error; return 1; }
  FM_BACKEND_REX_LAST_EXIT=$(printf '%s' "$out" | jq -r 'if .last_exit == null then "" else "exited" end' 2>/dev/null)
  FM_BACKEND_REX_CHAIN=$(printf '%s' "$out" | jq -r '
    def row($role): [$role, ((.pid // "") | tostring), (.name // ""), (.path // ""), (.argv0 // "")] | join("\t");
    (if .foreground then (.foreground | row("foreground")) else empty end),
    (.ancestors[]? | row("ancestor"))' 2>/dev/null) || { FM_BACKEND_REX_READ_CLASS=error; return 1; }
}

# fm_backend_rex_process_kind: agent|shell|other for one process, from its
# name, install path, argv[0], and live pid through the shared classifier.
fm_backend_rex_process_kind() {  # <pid> <name> <path> <argv0>
  local pid=$1 name=$2 path=$3 argv0=$4 kind
  kind=$(fm_agent_process_classify "$name" "$argv0" '' "$pid")
  [ "$kind" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$path" ] && [ "$(fm_agent_process_classify_name "$path" "$argv0")" = agent ]; then
    printf 'agent'
    return 0
  fi
  printf '%s' "$kind"
}

# fm_backend_rex_agent_state: the recovery-grade agent/endpoint state (the
# vocabulary is owned by bin/fm-backend.sh's fm_backend_agent_state), from
# Rex's structured process view. A verified harness anywhere in the
# foreground process or its ancestors is `alive` (a harness running a pager
# or an interactive shell escape is still there); a shell foreground with no
# harness above it is `dead`; anything else is `ambiguous`. A structured
# not-found is `missing`; an unreachable server or a bad read is
# `unreadable`. Read-only: it never starts a server.
fm_backend_rex_agent_state() {  # <target>
  local role pid name path argv0 kind fg_kind='' seen=0
  if ! fm_backend_rex_process_chain "$1"; then
    case "$FM_BACKEND_REX_READ_CLASS" in
      missing) printf 'missing' ;;
      *) printf 'unreadable' ;;
    esac
    return 0
  fi
  while IFS=$'\t' read -r role pid name path argv0; do
    [ -n "$role" ] || continue
    seen=1
    kind=$(fm_backend_rex_process_kind "$pid" "$name" "$path" "$argv0")
    if [ "$kind" = agent ]; then
      printf 'alive'
      return 0
    fi
    [ "$role" != foreground ] || fg_kind=$kind
  done <<EOF
$FM_BACKEND_REX_CHAIN
EOF
  if [ "$seen" -eq 0 ]; then
    # No foreground process: the terminal child exited (a kept-open block) or
    # the block is still starting.
    if [ "$FM_BACKEND_REX_LAST_EXIT" = exited ]; then
      printf 'dead'
    else
      printf 'ambiguous'
    fi
    return 0
  fi
  case "$fg_kind" in
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# fm_backend_rex_native_state: the block's OSC 7501 program state
# (working|blocked|idle|done|error), or empty when no record can be trusted.
# A record is trusted only while its reporting process is the foreground
# process or one of its ancestors: without shell integration a `working`
# record outlives the command that reported it (verified live), so no
# self-report outranks the process view.
fm_backend_rex_native_state() {  # <target>
  local status process
  status=$(fm_backend_rex_block_call "$1" program_status) || return 0
  process=$(fm_backend_rex_block_call "$1" process) || return 0
  jq -rn --argjson s "$status" --argjson p "$process" '
    ([$p.foreground.pid?, ($p.ancestors[]?.pid)] | map(select(. != null))) as $live
    | [$s.records[]? | select(.owner.pid != null and ([.owner.pid] | inside($live))) | .state] as $states
    | if ($states | index("working")) then "working"
      elif ($states | index("blocked")) then "blocked"
      elif ($states | index("error")) then "error"
      elif ($states | index("done")) then "done"
      elif ($states | index("idle")) then "idle"
      else empty end' 2>/dev/null || true
}

# fm_backend_rex_busy_state: busy|idle|unknown from the trusted native state.
# Only harnesses that report OSC 7501 ever read busy; callers treat a native
# busy as positive activity evidence only (bin/fm-busy-lib.sh).
fm_backend_rex_busy_state() {  # <target>
  case "$(fm_backend_rex_native_state "$1")" in
    working) printf 'busy' ;;
    idle|done|blocked|error) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_rex_rendered_busy_state: busy|idle|unknown from the rendered busy
# footer, the same delivery-only signal the herdr adapter reads, for harnesses
# that do not report OSC 7501.
fm_backend_rex_rendered_busy_state() {  # <target> [harness]
  local cap visible
  cap=$(fm_backend_rex_capture "$1" 40) || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$cap" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || { printf 'unknown'; return 0; }
  if printf '%s' "$visible" | fm_busy_lines_match "${2:-}"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

# fm_backend_rex_composer_identity: the identity probe behind the separated
# (pi, polytoken) composer shape and Command Code's placeholder ceiling.
# Prints "<owner>\t<status>" when the foreground process is one of those
# owners; status is the trusted native state, else the owner's own rendered
# busy footer.
fm_backend_rex_composer_identity() {  # <target>
  local role pid name path argv0 owner='' base native rendered
  fm_backend_rex_process_chain "$1" || return 1
  while IFS=$'\t' read -r role pid name path argv0; do
    [ "$role" = foreground ] || continue
    for base in "${name##*/}" "${argv0##*/}" "${path##*/}"; do
      case "${base#-}" in
        pi|pi-signed|pi-launcher|Pi) owner=pi ;;
        polytoken) owner=polytoken ;;
        command-code) owner=commandcode ;;
      esac
      [ -z "$owner" ] || break
    done
  done <<EOF
$FM_BACKEND_REX_CHAIN
EOF
  [ -n "$owner" ] || return 1
  native=$(fm_backend_rex_native_state "$1")
  case "$native" in
    working|blocked|idle|done) printf '%s\t%s' "$owner" "$native"; return 0 ;;
  esac
  rendered=$(fm_backend_rex_rendered_busy_state "$1" "$owner")
  case "$rendered" in
    busy) printf '%s\tworking' "$owner" ;;
    idle) printf '%s\tidle' "$owner" ;;
    *) return 1 ;;
  esac
}

# fm_backend_rex_composer_caps: static capability facts for the shared
# classifier (bin/fm-composer-lib.sh).
fm_backend_rex_composer_caps() {
  printf 'styled=1\ncursor=0\nidentity=1\nrows=%s\n' "${1:-0}"
}

# fm_backend_rex_composer_state: thin adapter - the styled derived viewport
# plus capabilities in, the shared verdict out. The whole viewport is read,
# never a bounded tail, so an overlay drawn below the composer cannot push it
# out of view. Identity is fetched lazily, only when the verdict depends on it.
fm_backend_rex_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local target=$1 cap caps verdict identity
  cap=$(fm_backend_rex_visible_capture_vt "$target" 2>/dev/null) || { printf 'unknown'; return 0; }
  caps=$(fm_backend_rex_composer_caps "$(printf '%s\n' "$cap" | wc -l | tr -d '[:space:]')")
  verdict=$(fm_composer_classify_screen "$caps" "$cap")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_backend_rex_composer_identity "$target" 2>/dev/null) || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$caps" "$cap" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_backend_rex_delivery_busy: busy|idle|unknown for the queued-Enter
# conversion: a trusted native working state, else the rendered busy footer.
fm_backend_rex_delivery_busy() {  # <target>
  [ "$(fm_backend_rex_busy_state "$1")" != busy ] || { printf 'busy'; return 0; }
  fm_backend_rex_rendered_busy_state "$1"
}

# fm_backend_rex_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop (fm_composer_submit_retry_core) against the
# shared composer verdict, and convert a still-pending composer whose agent is
# visibly busy into a queued delivery (fm_composer_queued_enter_verdict).
# Echoes empty|pending|pending-unproven|unknown|send-failed.
fm_backend_rex_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} verdict
  fm_backend_rex_parse_target "$target" || { printf 'unknown'; return 0; }
  fm_backend_rex_send_literal "$target" "$text" "$expected_label" || {
    printf 'send-failed'
    return 0
  }
  sleep "$settle"
  verdict=$(fm_composer_submit_retry_core fm_backend_rex_send_key fm_backend_rex_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label")
  if [ "$verdict" = pending ]; then
    verdict=$(fm_composer_queued_enter_verdict "$verdict" "$(fm_backend_rex_delivery_busy "$target")")
  fi
  printf '%s' "$verdict"
}

# fm_backend_rex_block_presence: present|missing|unknown for the target block,
# read through a call that may start a missing personal server, so a stopped
# server resolves to the authoritative not-found its fresh start returns.
fm_backend_rex_block_presence() {  # <target>
  local err rc
  fm_backend_rex_parse_target "$1" || { printf 'unknown'; return 0; }
  err=$(mktemp "${TMPDIR:-/tmp}/fm-rex-err.XXXXXX") || { printf 'unknown'; return 0; }
  fm_backend_rex_cli block call -s "$FM_BACKEND_REX_SESSION" -b "$FM_BACKEND_REX_BLOCK" size >/dev/null 2>"$err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$err"
    printf 'present'
    return 0
  fi
  if [ "$(fm_backend_rex_failure_class "$rc" "$(cat "$err" 2>/dev/null)")" = missing ]; then
    printf 'missing'
  else
    printf 'unknown'
  fi
  rm -f "$err"
}

# fm_backend_rex_kill: close the task's block (its tab closes with its last
# block) and PROVE it gone: an exact not-found after the close is the proof,
# so a close that failed or left the block alive returns nonzero and the
# caller keeps its records. An already-gone block is success. A per-home
# session left with no windows is then retired.
fm_backend_rex_kill() {  # <target> [unused] [expected-label]
  local sid
  fm_backend_rex_parse_target "$1" || {
    echo "error: malformed rex target '$1'; cannot close it" >&2
    return 1
  }
  sid=$FM_BACKEND_REX_SESSION
  fm_backend_rex_cli block close -s "$sid" "$FM_BACKEND_REX_BLOCK" >/dev/null 2>&1 || true
  case "$(fm_backend_rex_block_presence "$1")" in
    missing) ;;
    present)
      echo "error: rex block $FM_BACKEND_REX_BLOCK is still open after its close" >&2
      return 1
      ;;
    *)
      echo "error: could not confirm rex block $FM_BACKEND_REX_BLOCK closed" >&2
      return 1
      ;;
  esac
  fm_backend_rex_retire_session "$sid"
  return 0
}

# fm_backend_rex_retire_session: kill a per-home session once it holds no
# window. Only a session labeled with THIS home's label is ever killed, never
# the launcher's own session, and an unreadable view skips the cleanup. Runs
# under the session lock so a concurrent spawn cannot open a tab between the
# empty check and the kill.
fm_backend_rex_retire_session() {  # <session-id>
  local sid=$1 view
  [ -n "$sid" ] || return 0
  [ "$sid" != "${REX_SESSION:-}" ] || return 0
  fm_backend_rex_session_lock || return 0
  if view=$(fm_backend_rex_session_view "$sid") \
    && printf '%s' "$view" | jq -e --arg want "$(fm_backend_rex_home_label)" \
      '.label == $want and (.windows | type == "array" and length == 0)' >/dev/null 2>&1; then
    fm_backend_rex_cli kill "$sid" >/dev/null 2>&1 || true
  fi
  fm_backend_rex_session_unlock
  return 0
}

# fm_backend_rex_endpoint_absence_recheck: the control plane's absence proof
# (bin/fm-control-lib.sh's fm_control_endpoint_absence_verdict owns the
# argument). Rex ids are never reused and a session never survives its
# server, so a structured not-found from the server the task was created on
# proves the block is gone. The proof therefore requires the endpoint this
# process reaches (starting a stopped personal server) to equal the recorded
# one. Prints missing|dead|alive|unproven.
fm_backend_rex_endpoint_absence_recheck() {  # <target> <recorded-server>
  local target=$1 recorded=${2:-} now state
  [ -n "$recorded" ] || { printf 'unproven'; return 0; }
  now=$(fm_backend_rex_server_endpoint) || { printf 'unproven'; return 0; }
  [ "$now" = "$recorded" ] || { printf 'unproven'; return 0; }
  case "$(fm_backend_rex_block_presence "$target")" in
    missing) printf 'missing' ;;
    present)
      state=$(fm_backend_rex_agent_state "$target")
      case "$state" in
        dead|alive) printf '%s' "$state" ;;
        *) printf 'unproven' ;;
      esac
      ;;
    *) printf 'unproven' ;;
  esac
}

# fm_backend_rex_list_live: recovery/orphan discovery. One
# "<session-uuid>:<block-uuid>\tfm-<id>" line per live block whose label is
# scoped to this home, read from the live inventory. Read-only: an
# unreachable server lists nothing.
fm_backend_rex_list_live() {
  local list sid prefix view
  prefix="fm-$(fm_backend_rex_home_label)-"
  list=$(fm_backend_rex_read ls --json 2>/dev/null) || return 0
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    view=$(fm_backend_rex_session_view "$sid") || continue
    printf '%s' "$view" | jq -r --arg prefix "$prefix" '
      .session_id as $s
      | .windows[]?.layers[]?.blocks[]?
      | select((.label // "") | startswith($prefix))
      | "\($s | sub("^session:"; "")):\(.block_id | sub("^block:"; ""))\tfm-\(.label | ltrimstr($prefix))"' 2>/dev/null
  done <<EOF
$(printf '%s' "$list" | jq -r '.sessions[]?.session_id' 2>/dev/null)
EOF
}
