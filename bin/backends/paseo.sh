#!/usr/bin/env bash
# bin/backends/paseo.sh - the Paseo session-provider adapter (EXPERIMENTAL).
#
# Design: modeled on bin/backends/cmux.sh (the closest shared-namespace,
# session-provider-only GUI adapter) for CLI mechanics, with Herdr's
# container UX (ONE shared firstmate workspace per project, one tab per
# task, plain send-keys literal-then-Enter delivery, JSON capture). Paseo is
# a session provider ONLY: the worktree provider stays treehouse. Sourced
# only through bin/fm-backend.sh's fm_backend_source in normal operation;
# the unit tests source it directly.
#
# Container shape (Paseo's hierarchy is project > workspace > terminal tab):
# ONE Paseo workspace PER PROJECT, labeled `firstmate` (or `2ndmate-<id>`),
# adopted by (cwd, title) or created once, holding ONE terminal tab PER
# TASK. The adapter never runs a `paseo project ...` command: Paseo
# registers or reuses the project by path when the workspace is created, so
# a fleet of tasks shows up as tabs under one sidebar entry instead of one
# workspace (or project) per task. The daemon (127.0.0.1:6767 by default,
# `paseo status`) is the shared container.
#
# Target string shape: "<terminal_id>:<workspace_id>" - the terminal's UUID
# plus the workspace's `wks_...` id, neither of which contains a colon, so
# splitting on the FIRST colon is trivially correct (mirrors cmux's
# workspace:surface convention; terminal first because the terminal is the
# addressing authority).
#
# ROUTING AUTHORITY (the load-bearing rule from the live verification pass,
# docs/paseo-backend.md): the terminal's NAME (`terminal create --name`) is
# the firstmate-facing authority. The workspace TITLE is only used to adopt
# the shared per-project workspace (herdr's label lookup); it is never used
# to route a task. Recovery and list_live match the recorded home-scoped
# terminal NAME, and the recorded terminal id is validated against the live
# inventory before every send.
#
# GUI-first, macOS-only, EXPLICIT-ONLY: `--backend paseo`, `FM_BACKEND=paseo`,
# or config/backend. Never auto-detected: Paseo stamps PASEO_* markers and
# the sh.paseo.desktop bundle id into every descendant process (a tmux server
# started from a Paseo tab inherits them), so an inherited marker is not a
# selection (docs/paseo-backend.md "Selection is explicit").
#
# Empirical findings from the live verification pass against the real Paseo
# 0.8.0 CLI/daemon (docs/verification/runtime-backends.md#paseo owns the
# evidence log):
#
#   1. `terminal send-keys <id> -l -- <text>` sends literal, UNSUBMITTED
#      input; special tokens are sent without -l (`Enter`, `Escape`, `C-c`
#      all verified live: Enter submits, C-c interrupts with ^C on screen,
#      Escape is accepted) - exactly the literal-then-separate-Enter contract
#      every other backend uses. `--` guards option-shaped payloads. The
#      0.8.0 token set is Enter, Tab, Escape, Space, BSpace, C-c, C-d, C-z,
#      C-l, C-a, and C-e; any other name is written as literal text, so C-u
#      is delivered as its raw 0x15 byte through -l instead.
#   2. `terminal capture <id> -S --json` returns
#      {terminalId, lines[], totalLines} as PLAIN text (ANSI stripped unless
#      --ansi). There is no per-call line bound; the adapter fetches the
#      scrollback and trims the tail locally (cmux's fetch-generous pattern).
#   3. A terminal's `cwd` field in `terminal ls` is CREATION-TIME-FROZEN
#      (zellij/cmux shape): it never follows a foreground subshell such as
#      `treehouse get`, so current_path uses the same active pwd-marker probe
#      as cmux/zellij (send a marked pwd block, then read only that marker).
#   4. `workspace create --path <dir> --isolation local --title <t>` reuses
#      the project registered for <dir> (no duplicate project) and reports
#      the title back as `name` in `workspace ls`. Duplicate titles and
#      duplicate terminal names are freely allowed by Paseo, so the adopt-
#      first workspace lookup and the pre-create terminal duplicate check
#      below are ours.
#   5. One workspace holds many terminals; `terminal kill <id>` closes one
#      tab and leaves its siblings and the workspace alive (verified live).
#      The shared workspace is never archived by this adapter: it outlives
#      every task, and an operator archiving it by hand simply makes the next
#      spawn create a fresh one.
#
# Requires: paseo (CLI, bundled inside Paseo.app - not guaranteed to be on
# PATH; see fm_backend_paseo_bin), jq (JSON parsing). Bootstrap detects these
# through fm_backend_required_tools only when paseo is the resolved backend;
# this adapter also gates them again before spawning.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/cmux.sh's identical fallback.
FM_BACKEND_PASEO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_PASEO_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_PASEO_ROOT/bin/fm-backend-hometag-lib.sh"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_PASEO_ROOT/bin/fm-composer-lib.sh"

# Verified minimum: the version the live pass ran against
# (docs/paseo-backend.md).
FM_BACKEND_PASEO_MIN_MAJOR=0
FM_BACKEND_PASEO_MIN_MINOR=8

# fm_backend_paseo_bin: resolve the paseo CLI binary. Paseo's desktop app
# bundles the CLI at Contents/Resources/bin/paseo and an "install to PATH"
# action is not guaranteed to have run, so prefer PATH (respects an
# operator's own setup), then the well-known bundle path.
FM_BACKEND_PASEO_BUNDLE_BIN="${FM_BACKEND_PASEO_BUNDLE_BIN:-/Applications/Paseo.app/Contents/Resources/bin/paseo}"
fm_backend_paseo_bin() {
  if command -v paseo >/dev/null 2>&1; then
    printf 'paseo'
    return 0
  fi
  if [ -x "$FM_BACKEND_PASEO_BUNDLE_BIN" ]; then
    printf '%s' "$FM_BACKEND_PASEO_BUNDLE_BIN"
    return 0
  fi
  return 1
}

fm_backend_paseo_tool_check() {
  fm_backend_paseo_bin >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but the 'paseo' CLI was not found on PATH or at $FM_BACKEND_PASEO_BUNDLE_BIN (https://paseo.sh)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but 'jq' is not installed (required to parse paseo's JSON output)" >&2
    return 1
  }
  return 0
}

# fm_backend_paseo_cli: run `paseo <args...>` with JSON output where the
# caller asked for --json itself (no global quieting is needed; paseo's CLI
# is quiet on success for the mutating calls this adapter makes).
fm_backend_paseo_cli() { # <paseo-subcommand-and-args...>
  local bin
  bin=$(fm_backend_paseo_bin) || return 1
  "$bin" "$@"
}

# fm_backend_paseo_cli_json: a mutating `--json` call whose stdout must stay
# parseable. Verified live: when firstmate itself runs inside a Paseo agent
# the CLI prints an Electron warning on STDERR before its JSON, so stderr is
# never merged into the parsed output; it is relayed to our stderr only when
# the call fails, so the failure reason still reaches the spawn log.
fm_backend_paseo_cli_json() { # <paseo-subcommand-and-args...>
  local err status
  err=$(mktemp "${TMPDIR:-/tmp}/fm-paseo-err.XXXXXX") || return 1
  fm_backend_paseo_cli "$@" 2>"$err"
  status=$?
  [ "$status" -eq 0 ] || cat "$err" >&2
  rm -f "$err"
  return "$status"
}

# fm_backend_paseo_version_check: refuse loudly on a missing/incompatible
# paseo client. `paseo -v` is a pure client-side print (no daemon round
# trip), so this gates the CLI version separately from daemon reachability.
fm_backend_paseo_version_check() {
  fm_backend_paseo_tool_check || return 1
  local raw ver major rest minor
  raw=$(fm_backend_paseo_cli -v 2>/dev/null) || {
    echo "error: 'paseo -v' failed; is paseo installed correctly?" >&2
    return 1
  }
  ver=$(printf '%s' "$raw" | awk '{print $1}')
  case "$ver" in
  '' | *[!0-9.]*)
    echo "error: could not parse a paseo version from '$raw'; refusing to use an unverified paseo build" >&2
    return 1
    ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in '' | *[!0-9]*) major=0 ;; esac
  case "$minor" in '' | *[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$FM_BACKEND_PASEO_MIN_MAJOR" ] || { [ "$major" -eq "$FM_BACKEND_PASEO_MIN_MAJOR" ] && [ "$minor" -lt "$FM_BACKEND_PASEO_MIN_MINOR" ]; }; then
    echo "error: paseo $ver is older than the verified minimum $FM_BACKEND_PASEO_MIN_MAJOR.$FM_BACKEND_PASEO_MIN_MINOR; update paseo before using backend=paseo" >&2
    return 1
  fi
  return 0
}

# fm_backend_paseo_daemon_state: classify daemon reachability from
# `paseo status --json`'s own fields - ok|down|error. A local daemon reports
# localDaemon=running plus connectedDaemon=reachable; anything else that
# exits nonzero or fails to parse is down/error, both normal expected
# outcomes here (never a scripting bug).
fm_backend_paseo_daemon_state() {
  local out
  out=$(fm_backend_paseo_cli status --json 2>/dev/null) || {
    printf 'down'
    return 0
  }
  case "$(printf '%s' "$out" | jq -r '(.localDaemon == "running") and (.connectedDaemon == "reachable")' 2>/dev/null)" in
  true) printf 'ok' ;;
  false) printf 'down' ;;
  *) printf 'error' ;;
  esac
}

# fm_backend_paseo_ensure_running: start the daemon via `paseo start` only
# when it is simply not up yet, mirroring the CLI's own start path. A daemon
# that starts but never becomes reachable fails fast with a pointer to
# docs/paseo-backend.md instead of retry-looping.
fm_backend_paseo_ensure_running() {
  local state i
  state=$(fm_backend_paseo_daemon_state)
  [ "$state" = ok ] && return 0
  fm_backend_paseo_cli start >/dev/null 2>&1 || {
    echo "error: 'paseo start' failed; is the Paseo app installed? See docs/paseo-backend.md 'Setup'." >&2
    return 1
  }
  for i in $(seq 1 20); do
    state=$(fm_backend_paseo_daemon_state)
    [ "$state" = ok ] && return 0
    sleep 0.5
  done
  echo "error: the paseo daemon did not become reachable within 10s of 'paseo start' (state=$state) - see docs/paseo-backend.md 'Setup'." >&2
  return 1
}

# fm_backend_paseo_container_ensure: the full spawn-time container-ensure
# sequence (version gate, daemon reachability/start-if-needed). The daemon is
# the only container; nothing to echo; callers proceed straight to
# fm_backend_paseo_create_task.
fm_backend_paseo_container_ensure() {
  fm_backend_paseo_version_check || return 1
  fm_backend_paseo_ensure_running || return 1
  return 0
}

# fm_backend_paseo_home_label: readable home prefix plus a short hash of the
# resolved FM_ROOT path (bin/fm-backend-hometag-lib.sh). The paseo daemon is
# one app-global terminal namespace shared by every firstmate home, so the
# path hash distinguishes every installation, exactly like cmux's shared
# workspace namespace.
fm_backend_paseo_home_label() {
  fm_backend_hometag
}

# fm_backend_paseo_scoped_name: the ROUTING-AUTHORITY terminal name for an
# fm-<id> task label, home-scoped so two firstmate homes sharing one daemon
# can never cross-match each other's terminals.
fm_backend_paseo_scoped_name() { # <fm-task-label>
  local label=$1 rest home
  home=$(fm_backend_paseo_home_label)
  case "$label" in
  fm-*) rest=${label#fm-} ;;
  *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$home" "$rest"
}

# fm_backend_paseo_terminal_id_for_name: the live terminal id whose NAME
# equals <name>, or empty. Paseo enforces no name uniqueness itself
# (finding #4's sibling on the terminal layer), so this adopts the first
# match, mirroring cmux's duplicate-check posture.
fm_backend_paseo_terminal_id_for_name() { # <name>
  local name=$1
  fm_backend_paseo_cli terminal ls --all --json 2>/dev/null |
    jq -r --arg want "$name" '.[]? | select(.name == $want) | .id' 2>/dev/null | head -1
}

# fm_backend_paseo_workspace_label: the shared per-project workspace's title,
# `firstmate` or `2ndmate-<id>` (the hometag's readable prefix, without the
# path hash: the project path already scopes the workspace, and the title is
# what the captain reads in the sidebar).
fm_backend_paseo_workspace_label() {
  local tag
  tag=$(fm_backend_paseo_home_label)
  printf '%s' "${tag%-*}"
}

# fm_backend_paseo_workspace_ensure: the ONE shared workspace for <cwd>.
# Adopted, in order: the workspace firstmate itself is running in when a
# Paseo tab exported PASEO_WORKSPACE_ID and that live workspace's cwd is the
# project (herdr's launcher-identity rule, minus the pane ancestry Paseo
# does not expose); else a live workspace with this cwd and label (first
# match wins; Paseo allows duplicates); else created once. Never creates or
# deletes a project: `workspace create --path` reuses the project registered
# for <cwd> (finding #4). Echoes the workspace id.
fm_backend_paseo_workspace_ensure() { # <cwd>
  local cwd=$1 logical real label list out wsid
  # Paseo reports the workspace cwd normalized (no doubled slashes) but NOT
  # symlink-resolved (verified live: a $TMPDIR/ path came back without the
  # doubled slash and without the /private prefix), so match the raw path,
  # the logical normalization, and the physical one.
  logical=$(cd "$cwd" 2>/dev/null && pwd) || logical=$cwd
  real=$(cd "$cwd" 2>/dev/null && pwd -P) || real=$cwd
  label=$(fm_backend_paseo_workspace_label)
  list=$(fm_backend_paseo_cli workspace ls --json 2>/dev/null) || list='[]'
  wsid=""
  if [ -n "${PASEO_WORKSPACE_ID:-}" ]; then
    wsid=$(printf '%s' "$list" |
      jq -r --arg id "$PASEO_WORKSPACE_ID" --arg cwd "$cwd" --arg logical "$logical" --arg real "$real" \
        '.[]? | select(.workspaceId == $id and (.cwd == $cwd or .cwd == $logical or .cwd == $real)) | .workspaceId' 2>/dev/null | head -1)
  fi
  [ -n "$wsid" ] || wsid=$(printf '%s' "$list" |
    jq -r --arg want "$label" --arg cwd "$cwd" --arg logical "$logical" --arg real "$real" \
      '.[]? | select(.name == $want and (.cwd == $cwd or .cwd == $logical or .cwd == $real)) | .workspaceId' 2>/dev/null | head -1)
  if [ -n "$wsid" ]; then
    printf '%s' "$wsid"
    return 0
  fi
  out=$(fm_backend_paseo_cli_json workspace create --path "$cwd" --isolation local --title "$label" --json) || {
    echo "error: paseo workspace create failed for '$cwd'" >&2
    return 1
  }
  wsid=$(printf '%s' "$out" | jq -r '.workspaceId // empty' 2>/dev/null)
  [ -n "$wsid" ] || {
    echo "error: could not parse a workspaceId from paseo workspace create output: $out" >&2
    return 1
  }
  printf '%s' "$wsid"
}

# fm_backend_paseo_create_task: open the task's terminal TAB inside the
# project's shared workspace, refusing an existing live terminal NAME (ours;
# Paseo itself does not enforce uniqueness). The terminal name is the
# routing authority (see the header's routing rule). Echoes
# "<terminal_id> <workspace_id>" on success.
fm_backend_paseo_create_task() { # <label> <cwd>
  local label=$1 cwd=$2 name dup out wsid tid
  name=$(fm_backend_paseo_scoped_name "$label")
  dup=$(fm_backend_paseo_terminal_id_for_name "$name")
  if [ -n "$dup" ]; then
    echo "error: paseo terminal '$name' already exists" >&2
    return 1
  fi
  wsid=$(fm_backend_paseo_workspace_ensure "$cwd") || return 1
  out=$(fm_backend_paseo_cli_json terminal create --workspace "$wsid" --cwd "$cwd" --name "$name" --json) || {
    echo "error: paseo terminal create failed for '$name'" >&2
    return 1
  }
  tid=$(printf '%s' "$out" | jq -r '.id // empty' 2>/dev/null)
  [ -n "$tid" ] || {
    echo "error: could not parse a terminal id from paseo terminal create output: $out" >&2
    return 1
  }
  printf '%s %s' "$tid" "$wsid"
}

# fm_backend_paseo_parse_target: split "<terminal_id>:<workspace_id>" on the
# FIRST colon (neither id contains a colon, so this is unambiguous). Sets
# FM_BACKEND_PASEO_TERMINAL and FM_BACKEND_PASEO_WORKSPACE for the caller.
fm_backend_paseo_parse_target() { # <target>
  local target=$1
  FM_BACKEND_PASEO_TERMINAL=${target%%:*}
  FM_BACKEND_PASEO_WORKSPACE=${target#*:}
  [ -n "$FM_BACKEND_PASEO_TERMINAL" ] && [ -n "$FM_BACKEND_PASEO_WORKSPACE" ] && [ "$FM_BACKEND_PASEO_WORKSPACE" != "$target" ]
}

# fm_backend_paseo_terminal_entry: the live `terminal ls --all --json` entry
# (one jq object) whose id equals <terminal_id>, or empty. The structural
# existence check every readiness path routes through; never a content read.
fm_backend_paseo_terminal_entry() { # <terminal_id>
  fm_backend_paseo_cli terminal ls --all --json 2>/dev/null |
    jq -c --arg id "$1" '[.[]? | select(.id == $id)] | .[0] // empty' 2>/dev/null
}

# fm_backend_paseo_target_ready: parse the target and verify the recorded
# TERMINAL id against the live inventory (the spec's "validate recorded
# terminalId" rule). When the caller knows the owning task label, a missing
# terminal is recovered by its home-scoped NAME in the same inventory, and a
# present terminal whose name does not match the expected label is rejected
# (a reused id must never be silently targeted). The workspace half of the
# target is refreshed from the same entry; titles are never consulted.
fm_backend_paseo_target_ready() { # <target> [expected-label]
  local expected_label=${2:-} expected_name entry wsid tid
  fm_backend_paseo_parse_target "$1" || return 1
  entry=$(fm_backend_paseo_terminal_entry "$FM_BACKEND_PASEO_TERMINAL")
  if [ -n "$entry" ]; then
    if [ -n "$expected_label" ]; then
      expected_name=$(fm_backend_paseo_scoped_name "$expected_label")
      [ "$(printf '%s' "$entry" | jq -r '.name // empty' 2>/dev/null)" = "$expected_name" ] || return 1
    fi
    wsid=$(printf '%s' "$entry" | jq -r '.workspaceId // empty' 2>/dev/null)
    [ -n "$wsid" ] && FM_BACKEND_PASEO_WORKSPACE=$wsid
    return 0
  fi
  [ -n "$expected_label" ] || return 1
  expected_name=$(fm_backend_paseo_scoped_name "$expected_label")
  tid=$(fm_backend_paseo_terminal_id_for_name "$expected_name")
  [ -n "$tid" ] || return 1
  entry=$(fm_backend_paseo_terminal_entry "$tid")
  [ -n "$entry" ] || return 1
  wsid=$(printf '%s' "$entry" | jq -r '.workspaceId // empty' 2>/dev/null)
  [ -n "$wsid" ] || return 1
  FM_BACKEND_PASEO_TERMINAL=$tid
  FM_BACKEND_PASEO_WORKSPACE=$wsid
  return 0
}

# fm_backend_paseo_current_path: the live foreground process's cwd, or empty
# on any error. Verified pitfall (finding #3): the terminal ls `cwd` field is
# creation-time-frozen and never follows a foreground subshell such as
# `treehouse get`, so this actively probes with a marked pwd block (the
# cmux/zellij workaround, reused verbatim in spirit): print the terminal's
# $PWD between unique markers, atomically submitted, then read only that
# marker block from the capture. Scoped to fm-spawn.sh's own
# worktree-discovery poll loop.
fm_backend_paseo_current_path() { # <target> [expected-label]
  local target=$1 expected_label=${2:-} out line marker_begin="__FM_PASEO_CWD_BEGIN__" marker_end="__FM_PASEO_CWD_END__" in_block=0 chunk="" last=""
  fm_backend_paseo_target_ready "$target" "$expected_label" || return 0
  fm_backend_paseo_send_text_line "$target" "printf '%s\n' '$marker_begin'; pwd; printf '%s\n' '$marker_end'" "$expected_label" || return 0
  sleep 0.3
  out=$(fm_backend_paseo_capture "$target" 200 "$expected_label") || return 0
  while IFS= read -r line; do
    if [ "$line" = "$marker_begin" ]; then
      in_block=1
      chunk=""
      continue
    fi
    if [ "$line" = "$marker_end" ]; then
      case "$chunk" in /*) last=$chunk ;; esac
      in_block=0
      continue
    fi
    [ "$in_block" -eq 1 ] && chunk="$chunk$line"
  done <<EOF
$out
EOF
  printf '%s' "$last"
}

# fm_backend_paseo_send_literal: send TEXT as literal, UNSUBMITTED input -
# the caller sends Enter separately (finding #1). `--` guards
# option-shaped payloads before the literal.
fm_backend_paseo_send_literal() { # <target> <text> [expected-label]
  fm_backend_paseo_target_ready "$1" "${3:-}" || return 1
  fm_backend_paseo_cli terminal send-keys "$FM_BACKEND_PASEO_TERMINAL" -l -- "$2" >/dev/null 2>&1
}

# fm_backend_paseo_send_key: one named special key. Paseo's token set
# (finding #1) goes as a token send (no -l); C-u has no token, so it goes as
# the raw 0x15 byte through -l. Any other name is refused, because Paseo
# would type an unknown token as literal text.
fm_backend_paseo_send_key() { # <target> <key> [expected-label]
  case "$2" in
  Enter | Tab | Escape | Space | BSpace | C-c | C-d | C-z | C-l | C-a | C-e | C-u) ;;
  *)
    echo "error: unsupported paseo key '$2' (paseo would type it as literal text)" >&2
    return 1
    ;;
  esac
  fm_backend_paseo_target_ready "$1" "${3:-}" || return 1
  if [ "$2" = C-u ]; then
    fm_backend_paseo_cli terminal send-keys "$FM_BACKEND_PASEO_TERMINAL" -l -- $'\025' >/dev/null 2>&1
  else
    fm_backend_paseo_cli terminal send-keys "$FM_BACKEND_PASEO_TERMINAL" "$2" >/dev/null 2>&1
  fi
}

# fm_backend_paseo_send_text_line: send one line of TEXT then submit.
fm_backend_paseo_send_text_line() { # <target> <text> [expected-label]
  fm_backend_paseo_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_paseo_send_key "$1" Enter "${3:-}" && return 0
  fm_backend_paseo_send_key "$1" C-c "${3:-}" >/dev/null 2>&1 && return 1
  return 2
}

# fm_backend_paseo_capture: bounded plain-text terminal capture. `capture -S`
# has no per-call line bound (finding #2), so the scrollback is fetched
# whole and trimmed to the caller's tail locally (cmux's
# fetch-generous-trim-locally pattern).
fm_backend_paseo_capture() { # <target> <lines> [expected-label]
  fm_backend_paseo_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} raw out
  case "$lines" in '' | *[!0-9]*) lines=200 ;; esac
  raw=$(fm_backend_paseo_cli terminal capture "$FM_BACKEND_PASEO_TERMINAL" -S --json 2>/dev/null) || return 1
  out=$(printf '%s' "$raw" | jq -r '.lines | join("\n") // empty' 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_paseo_composer_capture: the composer screen - a bounded
# plain-text tail of the terminal. capture strips ANSI by construction
# (finding #2), so the capability descriptor declares styled=0: the shared
# classifier degrades a glyph row carrying trailing text to `unknown` instead
# of misreading an idle suggestion as unsent input.
fm_backend_paseo_composer_capture() { # <target> [expected-label]
  fm_backend_paseo_capture "$1" "$FM_COMPOSER_CAPTURE_LINES" "${2:-}"
}

# fm_backend_paseo_composer_caps: static capability facts, not logic (see
# the capability model in bin/fm-composer-lib.sh).
fm_backend_paseo_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_paseo_composer_state: thin adapter - capture plus capabilities
# in, shared verdict out (bin/fm-composer-lib.sh owns every shape). Paseo has
# no identity probe, so the classifier's identity sentinel resolves to
# unknown.
fm_backend_paseo_composer_state() { # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_paseo_composer_capture "$1" "${2:-}") || {
    printf 'unknown'
    return 0
  }
  verdict=$(fm_composer_classify_screen "$(fm_backend_paseo_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_paseo_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then drive the shared verify-and-retry-Enter
# loop (bin/fm-composer-lib.sh: fm_composer_submit_retry_core) against the
# shared composer verdict. Echoes empty|pending|unknown|send-failed, a subset
# of the proof-carrying submit vocabulary.
fm_backend_paseo_send_text_submit() { # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  fm_backend_paseo_parse_target "$target" || {
    printf 'unknown'
    return 0
  }
  fm_backend_paseo_send_literal "$target" "$text" "$expected_label" || {
    printf 'send-failed'
    return 0
  }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_paseo_send_key fm_backend_paseo_composer_state \
    "$target" "$retries" "$sleep_s" "$expected_label"
}

# fm_backend_paseo_kill: close the task's terminal TAB, best-effort (mirrors
# every other backend's `kill` `|| true` contract). The shared per-project
# workspace is never archived here: sibling task tabs live in it (finding
# #5). An already-gone target stays quiet.
fm_backend_paseo_kill() { # <target> [unused] [expected-label]
  local expected_label=${3:-}
  if [ -n "$expected_label" ]; then
    fm_backend_paseo_target_ready "$1" "$expected_label" || return 0
  else
    fm_backend_paseo_parse_target "$1" || return 0
  fi
  fm_backend_paseo_cli terminal kill "$FM_BACKEND_PASEO_TERMINAL" >/dev/null 2>&1 || true
}

# fm_backend_paseo_list_live: recovery/orphan discovery. Lists every terminal
# whose NAME is scoped to this firstmate home, by NAME from the live
# inventory - never by trusting a stored id alone and never by parsing the
# workspace TITLE (the header's routing rule). One
# "<terminal_id>:<workspace_id>\t<fm-id>" line per live task terminal.
# Read-only: an unreachable daemon simply lists nothing.
fm_backend_paseo_list_live() {
  local entries tid wsid name home prefix plain
  home=$(fm_backend_paseo_home_label)
  prefix="fm-$home-"
  entries=$(fm_backend_paseo_cli terminal ls --all --json 2>/dev/null) || return 0
  while IFS=$'\t' read -r tid wsid name; do
    [ -n "$tid" ] || continue
    plain=${name#"$prefix"}
    [ -n "$plain" ] || continue
    printf '%s:%s\tfm-%s\n' "$tid" "$wsid" "$plain"
  done < <(printf '%s' "$entries" | jq -r --arg prefix "$prefix" '.[]? | select(.name | startswith($prefix)) | "\(.id)\t\(.workspaceId)\t\(.name)"' 2>/dev/null)
}
