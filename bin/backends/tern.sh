#!/usr/bin/env bash
# bin/backends/tern.sh - the Stencil Tern session-provider adapter (EXPERIMENTAL).
#
# Tern is a native terminal with a session daemon and a scriptable CLI
# (`tern ls|new|run|send|capture|process|rename|close|ctl ...`). Like
# herdr/zellij/cmux it is a session provider ONLY: the worktree provider stays
# treehouse. docs/tern-backend.md owns the user-facing mechanics and
# docs/verification/runtime-backends.md owns what was and was not verified; this
# header owns the adapter's own design decisions. Sourced only through
# bin/fm-backend.sh's fm_backend_source in normal operation; the unit tests
# source it directly.
#
# Selection is explicit-only: `--backend tern`, FM_BACKEND=tern, or
# config/backend. The TERM_PROGRAM=tern and TERN_PANE markers Tern injects reach
# every descendant process of a block, so bin/fm-backend.sh's fm_backend_detect
# never reads them (docs/tern-backend.md "Selection is explicit").
#
# Container shape: ONE Tern session per firstmate home, named
# fm-<hometag> (bin/fm-backend-hometag-lib.sh; FM_TERN_SESSION overrides the
# NAME for test isolation, mirroring FM_ZELLIJ_SESSION/HERDR_SESSION), and ONE
# keep-open tab per task whose tab is renamed to the home-scoped title
# fm-<hometag>-<id> (fm_backend_tern_scoped_title), with one block as the
# endpoint. `tern new session` seeds the session with one ordinary shell tab;
# this adapter leaves it alone, which also keeps the session alive after the
# last task tab closes.
#
# Target string shape: "<session-id>:<block-id>", two bare unsigned decimal
# ids with no embedded colon, so splitting on the FIRST colon is unambiguous
# (herdr/zellij/cmux convention). Tern ids are 64-bit integers and globally
# unique per window (on the Linux daemon this adapter was probed against one
# counter numbered a session 1, its blocks 2 and 4 and its tabs 3 and 5).
# parse_target accepts nothing but digits:digits.
#
# Id handling: ids are never trusted through a JSON number type. Every JSON
# document read from tern passes fm_backend_tern_quote_ids first, which turns
# the integer ids ("id", "pane", "session", "tab", "block") into strings, so a
# 64-bit id above 2^53 is compared as text and a jq that converts numbers to
# doubles cannot round it. Every operation that takes a target also revalidates
# it against a fresh `tern ls --json` (fm_backend_tern_endpoint_state) before
# acting, because a BLOCK selector that matches no id can fall through to a
# title or program-name match. Selectors handed to tern are always
# "<session-id>/<block-id>", the documented one-session form, so tern itself
# also refuses a block that is not in the recorded session, and `tern rename`
# cannot read a bare numeric id as a session.
#
# Observed on tern 0.9.4 (b9ef74c) on 2026-10-19 from a Linux remote-host block
# with no desktop window, using read-only commands (ls, process, capture, ctl
# state) on the probing session's own block:
#   - `tern capture` of a block that draws natively through the Tern Surface
#     Protocol (an omp session) returns NOTHING for plain and --ansi captures.
#     `--surfaces` returns a JSON object {"block","text"} whose `text` is the
#     surface's main-region text (the transcript), byte-identical with and
#     without --scrollback, and does not contain omp's composer. Every capture
#     therefore passes --surfaces and reads `.text` (raw output that is not
#     that object is used as is); the composer classifier cannot see an omp
#     composer on tern, so the native agent state below is the only submit
#     proof for it. Capture is plain text (styled=0).
#   - Because --scrollback changes nothing for a surface, a viewport read of a
#     surface block is its WHOLE transcript. visible_capture and the composer
#     read are therefore trimmed to the block's `rows` from `tern ls --json`.
#   - `tern process BLOCK --json` is {pane, child{pid,name,argv,cwd}, group,
#     foreground{pid,name,argv,cwd}}; an unknown block prints
#     "tern <cmd>: no block is called `<selector>`" and exits 1.
#   - `tern ctl state` and `tern ctl carly lua ...` with no window showing the
#     pane exit 1 immediately with {"ok":false,"error":"no Tern window on this
#     machine shows this pane"}.
# Taken from the task brief (measured on a macOS window, not re-measured here):
# the `new tab --json` result {"session","tab","block"} and the native agent
# list read through `tern ctl`. NOT live-verified: the key names (enter, escape,
# ctrl+c, ctrl+u), whether `send ... text` can be confused by flag-looking
# text, that `tern rename` stays pinned, and whether creating a session or tab
# moves an attached window's focus (no focus restore is attempted).
#
# Native agent state (desktop window only): `tern ctl carly lua
# "$FM_BACKEND_TERN_AGENTS_LUA"` has Carly run that Lua program and store its
# answer, and `tern ctl state` returns it at .carly.last_tool.text as "→ <json
# array>". Each entry's `pane` is the block id and `state` is
# working|idle|waiting_input. Both calls run under fm_run_timed with
# FM_BACKEND_TERN_CTL_TIMEOUT (default 5s), so a hung window cannot hold a
# caller; any failure, timeout, non-ok reply, malformed answer or missing entry
# degrades to `unknown` and the shared screen classifier, and never errors. A
# first failing call skips the second.
# Multiplexers swallow the protocol: a tmux or herdr hosted inside a Tern block
# never shows native state.
#
# Carly's answer slot is display text: free-text fields can contain raw newlines
# and control characters that make the displayed JSON invalid. Request only the
# safe-field projection in FM_BACKEND_TERN_AGENTS_LUA; never request last_message,
# title, running.line, last.line, or other free text. Malformed answers are not
# repaired: fm_backend_tern_agents_json fails and callers read `unknown`.
# Keep fm_backend_tern_quote_ids before jq to preserve 64-bit numeric ids.
#
# busy_state prints busy|idle|blocked|unknown: working is busy, idle is idle,
# waiting_input is blocked (Tern's word for an agent waiting on the human, the
# analogue of herdr's `blocked` status), and anything unreadable is unknown.
# Herdr's own busy_state folds its blocked status into idle (pinned by
# tests/fm-backend-herdr.test.sh), so this adapter keeps one distinction more
# than herdr does. That is safe downstream because every shared consumer of the
# dispatcher's busy_state tests the exact word `busy` (fm-busy-lib.sh's native
# branch, fm-supervise-daemon.sh's pane_is_busy, fm-task-inbox-lib.sh's ring),
# so blocked is classified not-busy, as herdr's idle is: a blocked agent is
# waiting on the human, not grinding. The one reader of the idle word,
# fm_pending_reply_backend_observation, serves secondmates only and sends any
# other word through its rendered-tail fallback; tern has no secondmates.
# native_state returns Tern's own words (working|idle|waiting_input|unknown),
# and submit confirmation counts working and waiting_input alike as a landed
# turn. `tern events` kinds were not shown to cover agent transitions, so there
# is no has_push/wait_transition surface (herdr-only).
#
# agent_state follows the recovery-grade contract in bin/fm-backend.sh from
# `tern ls --json` (is the block there, in the recorded session, still live?)
# plus `tern process --json` (what runs in the foreground?). The foreground is a
# single process, so an interactive shell reads `dead` only when it has no
# command or script argument; a shell running one (`sh -c ...`) can still hold
# an agent as a child and reads `ambiguous`.
#
# Requires: tern (CLI), jq (JSON parsing). Bootstrap detects these through
# fm_backend_required_tools only when tern is the resolved backend; this
# adapter also gates them again before spawning. Secondmate spawns are not
# supported by this adapter.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/cmux.sh's identical fallback.
FM_BACKEND_TERN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_TERN_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_TERN_ROOT/bin/fm-backend-hometag-lib.sh"

# Shared composer-content classifier and submit helpers (bin/fm-composer-lib.sh).
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_TERN_ROOT/bin/fm-composer-lib.sh"

# Shared harness-process identity (agent|shell|other), the same classifier the
# tmux and herdr adapters prove liveness with (bin/fm-agent-process-lib.sh).
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_TERN_ROOT/bin/fm-agent-process-lib.sh"

# bin/fm-timeout-lib.sh owns bounded execution (fm_run_timed). It declares
# set -u for its own hygiene, which this adapter must not impose on a caller
# that runs without it, so the caller's nounset setting is restored.
_fm_backend_tern_nounset=off
case $- in *u*) _fm_backend_tern_nounset=on ;; esac
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_BACKEND_TERN_ROOT/bin/fm-timeout-lib.sh"
[ "$_fm_backend_tern_nounset" = on ] || set +u
unset _fm_backend_tern_nounset

# Verified minimum: the version the probing above ran against.
FM_BACKEND_TERN_MIN_MAJOR=0
FM_BACKEND_TERN_MIN_MINOR=9
FM_BACKEND_TERN_MIN_PATCH=4

# Request only the fields the native-state classifier consumes (pane, state,
# alive); the header owns the display-text constraint.
FM_BACKEND_TERN_AGENTS_LUA='local out = {} for _, a in ipairs(cx.agents:list()) do table.insert(out, {pane = a.pane, state = a.state, alive = a.alive}) end return tern.json.encode(out)'

# FM_BACKEND_TERN_SUBMIT_POLLS (default 6): how many native-state samples
# fm_backend_tern_send_text_submit spreads across each Enter attempt's
# confirmation budget. FM_BACKEND_TERN_SUBMIT_MIN_SLEEP (default 0.6) is the
# floor on that budget. Overridable for tests, as herdr's equivalents are.
FM_BACKEND_TERN_SUBMIT_POLLS=${FM_BACKEND_TERN_SUBMIT_POLLS:-6}
FM_BACKEND_TERN_SUBMIT_MIN_SLEEP=${FM_BACKEND_TERN_SUBMIT_MIN_SLEEP:-0.6}

# fm_backend_tern_tool_check: refuse loudly if tern or jq is missing.
fm_backend_tern_tool_check() {
  command -v tern >/dev/null 2>&1 || { echo "error: backend=tern selected but the 'tern' CLI was not found on PATH (install Stencil Tern and put its 'tern' command on PATH)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=tern selected but 'jq' is not installed (required to parse tern's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_tern_cli: the one place a plain (non-ctl) tern command is run.
# stdin is detached so a tern command can never consume a caller's loop input.
fm_backend_tern_cli() {  # <tern-subcommand-and-args...>
  tern "$@" </dev/null
}

# fm_backend_tern_version_check: refuse loudly on a missing or older-than-verified
# tern. `tern --version` prints "tern 0.9.4 (b9ef74c)" and needs no window.
fm_backend_tern_version_check() {
  fm_backend_tern_tool_check || return 1
  local raw ver major rest minor patch cur min
  raw=$(fm_backend_tern_cli --version 2>/dev/null) || { echo "error: 'tern --version' failed; is tern installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk '{print $2}')
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a tern version from '$raw'; refusing to use an unverified tern build" >&2
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
  patch=${patch%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  case "$patch" in ''|*[!0-9]*) patch=0 ;; esac
  cur=$((major * 1000000 + minor * 1000 + patch))
  min=$((FM_BACKEND_TERN_MIN_MAJOR * 1000000 + FM_BACKEND_TERN_MIN_MINOR * 1000 + FM_BACKEND_TERN_MIN_PATCH))
  if [ "$cur" -lt "$min" ]; then
    echo "error: tern $ver is older than the verified minimum $FM_BACKEND_TERN_MIN_MAJOR.$FM_BACKEND_TERN_MIN_MINOR.$FM_BACKEND_TERN_MIN_PATCH; update tern before using backend=tern" >&2
    return 1
  fi
  return 0
}

# fm_backend_tern_home_label / fm_backend_tern_scoped_title / fm_backend_tern_session_name:
# the home-scoped names. The tag derivation lives in
# bin/fm-backend-hometag-lib.sh, shared with zellij and cmux.
fm_backend_tern_home_label() {
  fm_backend_hometag
}

fm_backend_tern_scoped_title() {  # <fm-task-label>
  local label=$1 rest home
  home=$(fm_backend_tern_home_label)
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$home" "$rest"
}

# FM_TERN_SESSION is the operator/test knob for the session NAME. Do not use it
# alone for destructive test cleanup; tests/tern-test-safety.sh guards that path.
fm_backend_tern_session_name() {
  if [ -n "${FM_TERN_SESSION:-}" ]; then
    printf '%s' "$FM_TERN_SESSION"
  else
    printf 'fm-%s' "$(fm_backend_tern_home_label)"
  fi
}

# fm_backend_tern_valid_id: a bare unsigned decimal id of at most 20 digits
# (the width of a 64-bit unsigned integer).
fm_backend_tern_valid_id() {  # <id>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 20 ]
}

# fm_backend_tern_quote_ids: stdin -> stdout, with every integer value of an
# id-bearing key turned into a JSON string (see the header's id handling). A
# value that is not a plain integer (a fraction or an exponent) is left alone,
# an integral "N.0" is normalized to "N", and a key inside a string value
# cannot match because its quotes are backslash-escaped there.
fm_backend_tern_quote_ids() {
  sed -E 's/("(id|pane|session|tab|block)"[[:space:]]*:[[:space:]]*)([0-9]+)(\.0+)?([^0-9.eE]|$)/\1"\3"\5/g'
}

# fm_backend_tern_ls_json: `tern ls --json` with its ids quoted, or failure. An
# answer that is not a sessions inventory fails too, so a garbled read can never
# look like an empty inventory (which would read as an absent endpoint).
fm_backend_tern_ls_json() {
  local out
  out=$(fm_backend_tern_cli ls --json 2>/dev/null) || return 1
  out=$(printf '%s\n' "$out" | fm_backend_tern_quote_ids)
  printf '%s' "$out" | jq -e '(.sessions | type) == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$out"
}

# fm_backend_tern_session_id_for_name: the id of the first session called <name>
# in the quoted listing <json>, or empty.
fm_backend_tern_session_id_for_name() {  # <ls-json> <name>
  printf '%s' "$1" | jq -r --arg name "$2" \
    '[.sessions[]? | select(.name == $name) | (.id | tostring)] | .[0] // empty' 2>/dev/null
}

# fm_backend_tern_container_ensure: the full spawn-time container-ensure
# sequence (version gate, session). Echoes the numeric session id, nothing else.
# `tern new session` is only run when no session of this home's name is listed;
# its own output is not parsed, the id is re-read from the listing.
fm_backend_tern_container_ensure() {
  local name listing sid out
  fm_backend_tern_version_check || return 1
  name=$(fm_backend_tern_session_name)
  case "$name" in
    ''|-*|*[[:cntrl:]]*)
      echo "error: refusing tern session name '$name' (empty, leading dash, or control characters)" >&2
      return 1
      ;;
  esac
  listing=$(fm_backend_tern_ls_json) || { echo "error: 'tern ls --json' failed; is a Tern window or session daemon reachable from this shell?" >&2; return 1; }
  sid=$(fm_backend_tern_session_id_for_name "$listing" "$name")
  if [ -z "$sid" ]; then
    out=$(fm_backend_tern_cli new session "$name" 2>&1) || { echo "error: tern new session failed for '$name': $out" >&2; return 1; }
    listing=$(fm_backend_tern_ls_json) || { echo "error: 'tern ls --json' failed after creating session '$name'" >&2; return 1; }
    sid=$(fm_backend_tern_session_id_for_name "$listing" "$name")
  fi
  fm_backend_tern_valid_id "$sid" || { echo "error: could not resolve a numeric tern session id for '$name' (got '$sid')" >&2; return 1; }
  printf '%s' "$sid"
}

# fm_backend_tern_json_id: the string form of <key> in the JSON object <json>
# (ids quoted first), or empty.
fm_backend_tern_json_id() {  # <json> <key>
  printf '%s\n' "$1" | fm_backend_tern_quote_ids | jq -r --arg k "$2" '(.[$k] // empty) | tostring' 2>/dev/null
}

# fm_backend_tern_endpoint_state: classify <block-id> of <session-id> against a
# fresh inventory. Always returns 0 and prints exactly one of:
#   ready<TAB><tab-id><TAB><rows><TAB><live><TAB><exited>  the block is in that session (and, when
#                   [expected-title] is given, its tab carries that name); the
#                   fields are "-" when tern did not report them
#   absent          no block with that id is listed
#   moved           the block is listed, but in another session
#   renamed         right session, but the tab is not called [expected-title]
#   unreadable      the inventory could not be read
fm_backend_tern_endpoint_state() {  # <session-id> <block-id> [expected-title]
  local sid=$1 bid=$2 want=${3:-} listing verdict
  listing=$(fm_backend_tern_ls_json) || { printf 'unreadable'; return 0; }
  verdict=$(printf '%s' "$listing" | jq -r --arg sid "$sid" --arg bid "$bid" --arg want "$want" '
    [ .sessions[]? as $s
      | ($s.tabs // [])[] as $t
      | ($t.blocks // [])[]
      | select((.id | tostring) == $bid)
      | { s: ($s.id | tostring), t: ($t.id | tostring), name: ($t.name // ""),
          rows: (if .rows == null then "-" else (.rows | tostring) end),
          live: (if .live == null then "-" else (.live | tostring) end),
          exited: ((.exited != null) | tostring) } ] as $m
    | if ($m | length) == 0 then "absent"
      elif $m[0].s != $sid then "moved"
      elif ($want != "") and ($m[0].name != $want) then "renamed"
      else "ready\t\($m[0].t)\t\($m[0].rows)\t\($m[0].live)\t\($m[0].exited)" end' 2>/dev/null) || verdict=
  [ -n "$verdict" ] || verdict=unreadable
  printf '%s' "$verdict"
}

# fm_backend_tern_create_task: create the task's tab (one block) in the home's
# session, refusing an existing tab of the same scoped title. The session is
# found by name, so no container argument is needed. The tab is created
# keep-open so a finished program stays readable, renamed to the scoped title,
# and the rename is read back before the endpoint is handed out: every later
# operation checks that title, so a tern that did not keep it must fail here,
# loudly, and not silently at the first steer. Echoes "<tab-id> <block-id>".
fm_backend_tern_create_task() {  # <label> <cwd>
  local label=$1 cwd=$2 title name listing sid dup out tab block state kind i=0
  title=$(fm_backend_tern_scoped_title "$label")
  name=$(fm_backend_tern_session_name)
  listing=$(fm_backend_tern_ls_json) || { echo "error: 'tern ls --json' failed; cannot create tab '$title'" >&2; return 1; }
  sid=$(fm_backend_tern_session_id_for_name "$listing" "$name")
  fm_backend_tern_valid_id "$sid" || { echo "error: tern session '$name' does not exist; run container_ensure first" >&2; return 1; }
  dup=$(printf '%s' "$listing" | jq -r --arg sid "$sid" --arg want "$title" \
    '[.sessions[]? | select((.id | tostring) == $sid) | (.tabs // [])[] | select((.name // "") == $want) | (.id | tostring)] | .[0] // empty' 2>/dev/null)
  if [ -n "$dup" ]; then
    echo "error: tern tab '$title' already exists in session '$name'" >&2
    return 1
  fi
  out=$(fm_backend_tern_cli new tab "$sid" --cwd "$cwd" --keep-open --json) || { echo "error: tern new tab failed for '$title'" >&2; return 1; }
  tab=$(fm_backend_tern_json_id "$out" tab)
  block=$(fm_backend_tern_json_id "$out" block)
  if ! fm_backend_tern_valid_id "$tab" || ! fm_backend_tern_valid_id "$block"; then
    echo "error: tern new tab did not return numeric tab and block ids for '$title' (got: $out)" >&2
    return 1
  fi
  if ! fm_backend_tern_cli rename "$sid/$block" "$title" >/dev/null 2>&1; then
    fm_backend_tern_cli close "$sid/$block" >/dev/null 2>&1 || true
    echo "error: tern rename failed for new block $block ('$title'); closed it" >&2
    return 1
  fi
  while :; do
    state=$(fm_backend_tern_endpoint_state "$sid" "$block" "$title")
    kind=${state%%$'\t'*}
    [ "$kind" = ready ] && break
    i=$((i + 1))
    if [ "$i" -ge 3 ]; then
      fm_backend_tern_cli close "$sid/$block" >/dev/null 2>&1 || true
      echo "error: tern did not keep the tab name '$title' on new block $block (read back '$kind'); closed it" >&2
      return 1
    fi
    sleep 0.2
  done
  printf '%s %s' "$tab" "$block"
}

# fm_backend_tern_parse_target: split "<session-id>:<block-id>". Strict: exactly
# two non-empty runs of digits around one colon (at most 20 digits each), so a
# title, "@focused", a program name or a path can never reach tern as a selector.
# Sets FM_BACKEND_TERN_SESSION_ID and FM_BACKEND_TERN_BLOCK_ID for the caller.
fm_backend_tern_parse_target() {  # <target>
  local target=${1:-}
  FM_BACKEND_TERN_SESSION_ID=
  FM_BACKEND_TERN_BLOCK_ID=
  case "$target" in
    ''|*[!0-9:]*|:*|*:|*:*:*) return 1 ;;
    *:*) ;;
    *) return 1 ;;
  esac
  FM_BACKEND_TERN_SESSION_ID=${target%%:*}
  FM_BACKEND_TERN_BLOCK_ID=${target#*:}
  if ! fm_backend_tern_valid_id "$FM_BACKEND_TERN_SESSION_ID" || ! fm_backend_tern_valid_id "$FM_BACKEND_TERN_BLOCK_ID"; then
    FM_BACKEND_TERN_SESSION_ID=
    FM_BACKEND_TERN_BLOCK_ID=
    return 1
  fi
  return 0
}

# fm_backend_tern_target_ready: parse the target and verify it against a fresh
# inventory (fm_backend_tern_endpoint_state). Read-only: it never creates a
# session or touches a block. When the caller knows the owning firstmate task
# label the tab must carry that task's scoped title, so a recycled or foreign
# id is refused. Sets FM_BACKEND_TERN_ROWS (the block's viewport rows, or
# empty) for the caller.
fm_backend_tern_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} want='' state
  FM_BACKEND_TERN_ROWS=
  fm_backend_tern_parse_target "${1:-}" || return 1
  [ -z "$expected_label" ] || want=$(fm_backend_tern_scoped_title "$expected_label")
  state=$(fm_backend_tern_endpoint_state "$FM_BACKEND_TERN_SESSION_ID" "$FM_BACKEND_TERN_BLOCK_ID" "$want")
  [ "${state%%$'\t'*}" = ready ] || return 1
  IFS=$'\t' read -r _ _ FM_BACKEND_TERN_ROWS _ _ <<EOF
$state
EOF
  case "$FM_BACKEND_TERN_ROWS" in
    ''|*[!0-9]*|0) FM_BACKEND_TERN_ROWS= ;;
  esac
  return 0
}

# fm_backend_tern_current_path: the live foreground process's cwd, or empty on
# any error. Unlike zellij/cmux (an active pwd probe typed into the shell) tern
# reports the foreground process's own cwd, the herdr `foreground_cwd` shape, so
# it tracks the subshell `treehouse get` opens and nothing is typed. The block's
# `cwd` in `tern ls` is not used: it is not the foreground process's.
fm_backend_tern_current_path() {  # <target> [expected-label]
  local info cwd
  fm_backend_tern_target_ready "$1" "${2:-}" || return 0
  info=$(fm_backend_tern_cli process "$FM_BACKEND_TERN_SESSION_ID/$FM_BACKEND_TERN_BLOCK_ID" --json 2>/dev/null) || return 0
  cwd=$(printf '%s' "$info" | jq -r '.foreground.cwd // empty' 2>/dev/null) || return 0
  case "$cwd" in
    /*) printf '%s' "$cwd" ;;
  esac
  return 0
}

# fm_backend_tern_send_literal: send TEXT as literal, UNSUBMITTED input; the
# caller sends Enter separately. `tern send BLOCK text` types without Enter (a
# bracketed paste is deliberately not used: harness composers fold pastes).
fm_backend_tern_send_literal() {  # <target> <text> [expected-label]
  fm_backend_tern_target_ready "$1" "${3:-}" || return 1
  fm_backend_tern_cli send "$FM_BACKEND_TERN_SESSION_ID/$FM_BACKEND_TERN_BLOCK_ID" text "$2" >/dev/null 2>&1
}

# fm_backend_tern_normalize_key: map firstmate's key vocabulary (Enter, Escape,
# C-c, C-u) onto tern's `send keys` chord names. The names are the brief's and
# the ones Tern's own send_input tool documents (ctrl+c, enter, escape); they
# were not exercised against a live block. Anything else passes through.
fm_backend_tern_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'ctrl+c' ;;
    # C-u clears a composer line. fm-send.sh's muse interrupt path needs it to
    # drop the prompt muse restores into the composer after Escape.
    C-u|c-u|ctrl+u|Ctrl+u|Ctrl+U|ctrl-u) printf 'ctrl+u' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_tern_send_key: one named special key.
fm_backend_tern_send_key() {  # <target> <key> [expected-label]
  local key
  fm_backend_tern_target_ready "$1" "${3:-}" || return 1
  key=$(fm_backend_tern_normalize_key "$2")
  fm_backend_tern_cli send "$FM_BACKEND_TERN_SESSION_ID/$FM_BACKEND_TERN_BLOCK_ID" keys "$key" >/dev/null 2>&1
}

# fm_backend_tern_send_text_line: type one line of TEXT and Enter in a single
# atomic `tern run`, so there is no state in which the text is typed but not
# submitted (herdr's `pane run` shape).
fm_backend_tern_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_tern_target_ready "$1" "${3:-}" || return 1
  fm_backend_tern_cli run "$FM_BACKEND_TERN_SESSION_ID/$FM_BACKEND_TERN_BLOCK_ID" "$2" >/dev/null 2>&1
}

# fm_backend_tern_surface_text: the screen text of one `tern capture --surfaces`
# output - `.text` when the output is a single JSON object with a string
# `text`, otherwise the raw output unchanged.
fm_backend_tern_surface_text() {  # <capture-output>
  local text
  if text=$(printf '%s' "$1" | jq -sj 'if length == 1 and (.[0] | type) == "object" and (.[0].text | type) == "string" then .[0].text else error("not a surface object") end' 2>/dev/null); then
    printf '%s' "$text"
  else
    printf '%s' "$1"
  fi
}

# fm_backend_tern_capture: bounded plain-text capture. --scrollback is this
# adapter's explicit opt-in to history and --surfaces is mandatory (see the
# header: a natively drawn block captures empty without it). tern has no line
# bound, so the whole capture is read and trimmed locally.
fm_backend_tern_capture() {  # <target> <lines> [expected-label]
  local lines=${2:-200} out
  fm_backend_tern_target_ready "$1" "${3:-}" || return 1
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  out=$(fm_backend_tern_cli capture "$FM_BACKEND_TERN_SESSION_ID/$FM_BACKEND_TERN_BLOCK_ID" --scrollback --surfaces 2>/dev/null) || return 1
  out=$(fm_backend_tern_surface_text "$out")
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_tern_visible_capture: the viewport only, without --scrollback,
# trimmed to the block's reported row count. A natively drawn block has no
# scrollback to leave out, so without the trim its viewport read would be its
# whole transcript (see the header); for such a block the result is the tail of
# the surface text, an upper bound on what is on screen.
fm_backend_tern_visible_capture() {  # <target> [expected-label]
  local out
  fm_backend_tern_target_ready "$1" "${2:-}" || return 1
  out=$(fm_backend_tern_cli capture "$FM_BACKEND_TERN_SESSION_ID/$FM_BACKEND_TERN_BLOCK_ID" --surfaces 2>/dev/null) || return 1
  out=$(fm_backend_tern_surface_text "$out")
  if [ -n "$FM_BACKEND_TERN_ROWS" ]; then
    printf '%s' "$out" | tail -n "$FM_BACKEND_TERN_ROWS"
  else
    printf '%s' "$out"
  fi
}

# fm_backend_tern_composer_capture: the composer screen, the visible viewport
# (never a bounded tail: an overlay a harness draws between the composer and
# the bottom of the pane would push the composer out of a short tail).
fm_backend_tern_composer_capture() {  # <target> [expected-label]
  fm_backend_tern_visible_capture "$1" "${2:-}"
}

# fm_backend_tern_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh). The capture is plain text, so
# styled=0: the shared classifier then degrades a glyph row carrying trailing
# text to `unknown` instead of misreading an idle suggestion as typed input.
# identity=0: no identity probe is wired, because the native entry's `program`
# was not verified to name a harness the way herdr's `agent get` does and a
# wrong identity could prove a composer empty. The only shape that needs one,
# pi's blank separator pair, therefore stays `unknown` on tern; native state
# still drives submit confirmation, so steering is not blocked by it.
fm_backend_tern_composer_caps() {
  printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES"
}

# fm_backend_tern_composer_state: thin adapter - capture plus capabilities in,
# shared verdict out. Every shape lives in bin/fm-composer-lib.sh.
fm_backend_tern_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_tern_composer_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_backend_tern_composer_caps)" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# --- native agent state ---------------------------------------------------------

# fm_backend_tern_ctl: `tern ctl <args...>` under the hard bound. Success needs
# a zero exit AND the caller checks the reply; stderr is dropped because a window
# that does not answer is a normal, expected outcome here.
fm_backend_tern_ctl() {  # <ctl-args...>
  local bound=${FM_BACKEND_TERN_CTL_TIMEOUT:-5}
  case "$bound" in ''|*[!0-9]*|0) bound=5 ;; esac
  fm_run_timed "$bound" tern ctl "$@" </dev/null 2>/dev/null
}

# fm_backend_tern_agents_json: the window's agent list as a JSON array with its
# ids quoted, or failure when any step of the two-call read fails. The answer
# is the text after the leading arrow, ignoring a banner line before it; text
# with no arrow is accepted only if it is itself a JSON array. The answer is
# display text (see the header): one that is not valid JSON, such as a string
# holding a raw newline, fails here like any other malformed answer and is never
# repaired.
fm_backend_tern_agents_json() {
  local ack state text line json='' found=0
  ack=$(fm_backend_tern_ctl carly lua "$FM_BACKEND_TERN_AGENTS_LUA") || return 1
  printf '%s' "$ack" | jq -e '.ok == true' >/dev/null 2>&1 || return 1
  state=$(fm_backend_tern_ctl state) || return 1
  text=$(printf '%s' "$state" | jq -r '.carly.last_tool.text // empty' 2>/dev/null) || return 1
  [ -n "$text" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$found" -eq 1 ]; then
      json="$json"$'\n'"$line"
      continue
    fi
    case "$line" in
      '→ '*) json=${line#'→ '}; found=1 ;;
      '→'*) json=${line#'→'}; found=1 ;;
    esac
  done <<EOF
$text
EOF
  [ "$found" -eq 1 ] || json=$text
  json=$(printf '%s\n' "$json" | fm_backend_tern_quote_ids)
  printf '%s' "$json" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s' "$json"
}

# fm_backend_tern_native_state_raw: <block-id>'s native agent state, one of
# working|idle|waiting_input, or unknown for everything else: the window cannot
# be asked, the answer is malformed, the pane has no agent entry, or the entry
# reports the agent as no longer alive. No inventory check: callers that need
# one run fm_backend_tern_target_ready first.
fm_backend_tern_native_state_raw() {  # <block-id>
  local agents state
  agents=$(fm_backend_tern_agents_json) || { printf 'unknown'; return 0; }
  state=$(printf '%s' "$agents" | jq -r --arg b "$1" '
    ([ .[]? | select((.pane | tostring) == $b) ] | .[0]) as $e
    | if $e == null then "unknown" elif $e.alive == false then "unknown" else ($e.state // "unknown") end' 2>/dev/null) || state=unknown
  case "$state" in
    working|idle|waiting_input) printf '%s' "$state" ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_tern_native_state: the validated form of the raw read.
fm_backend_tern_native_state() {  # <target> [expected-label] -> working|idle|waiting_input|unknown
  fm_backend_tern_target_ready "$1" "${2:-}" || { printf 'unknown'; return 0; }
  fm_backend_tern_native_state_raw "$FM_BACKEND_TERN_BLOCK_ID"
}

# fm_backend_tern_classify_state: raw native state -> the busy_state vocabulary
# (see the header): working is busy, idle is idle, waiting_input is blocked.
fm_backend_tern_classify_state() {  # <raw-state> -> busy|idle|blocked|unknown
  case "$1" in
    working) printf 'busy' ;;
    idle) printf 'idle' ;;
    waiting_input) printf 'blocked' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_tern_classify_submit_state: raw native state -> the submit
# vocabulary. working and waiting_input both mean the Enter did something.
fm_backend_tern_classify_submit_state() {  # <raw-state> -> busy|idle|unknown
  case "$1" in
    working|waiting_input) printf 'busy' ;;
    idle) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_tern_foreground_class: what runs in <session>/<block>'s foreground,
# from one `tern process --json`:
#   agent          a verified harness (bin/fm-agent-process-lib.sh)
#   shell          an interactive shell: no command or script argument (the value
#                  of --rcfile/--init-file, as Tern's shell integration passes, is
#                  part of its option)
#   shell-command  a shell given one (`sh -c ...`), which can hold an agent child
#   other          anything else
#   none           no foreground process is reported
#   unreadable     the read failed
fm_backend_tern_foreground_class() {  # <session-id> <block-id>
  local info fields name argv0 args nonopt
  info=$(fm_backend_tern_cli process "$1/$2" --json 2>/dev/null) || { printf 'unreadable'; return 0; }
  fields=$(printf '%s' "$info" | jq -r '
    def one: split("\n") | join(" ");
    .foreground as $f
    | if ($f | type) != "object" then "none"
      else
        ($f.argv // []) as $argv
        | [ (($f.name // "") | tostring | one),
            (($argv[0] // "") | tostring | one),
            ($argv | map(select(type == "string")) | join(" ") | one),
            (reduce ($argv[1:][] | select(type == "string")) as $a ({skip: false, n: 0};
               if .skip then .skip = false
               elif ($a | startswith("-")) then .skip = ($a == "--rcfile" or $a == "--init-file")
               else .n += 1 end) | .n | tostring)
          ] | join("\u001f")
      end' 2>/dev/null) || { printf 'unreadable'; return 0; }
  [ -n "$fields" ] || { printf 'unreadable'; return 0; }
  [ "$fields" != none ] || { printf 'none'; return 0; }
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

# fm_backend_tern_busy_state: semantic busy state from the native agent state
# (see the header for the vocabulary). A `busy` verdict is proven at process
# level before it is reported, as herdr's is: a lingering `working` entry over a
# shell-only block (an agent killed mid-turn) reads `unknown`, never busy. Only
# the busy case pays the extra process read.
fm_backend_tern_busy_state() {  # <target> [expected-label] -> busy|idle|blocked|unknown
  local verdict
  fm_backend_tern_target_ready "$1" "${2:-}" || { printf 'unknown'; return 0; }
  verdict=$(fm_backend_tern_classify_state "$(fm_backend_tern_native_state_raw "$FM_BACKEND_TERN_BLOCK_ID")")
  if [ "$verdict" = busy ] \
    && [ "$(fm_backend_tern_foreground_class "$FM_BACKEND_TERN_SESSION_ID" "$FM_BACKEND_TERN_BLOCK_ID")" = shell ]; then
    verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_backend_tern_agent_state: recovery-grade state for one recorded target; see
# bin/fm-backend.sh's fm_backend_agent_state for the shared vocabulary. Only
# `dead` and `missing` license recovery, so each is claimed from positive
# evidence only: `missing` needs a successful inventory that omits the exact
# block, `dead` needs the block listed as exited or an interactive shell alone
# in the foreground. A block listed in a different session, or anything the
# foreground read cannot attribute, is `ambiguous`; a failed read is `unreadable`.
fm_backend_tern_agent_state() {  # <target>
  local state kind live exited
  fm_backend_tern_parse_target "${1:-}" || { printf 'unreadable'; return 0; }
  state=$(fm_backend_tern_endpoint_state "$FM_BACKEND_TERN_SESSION_ID" "$FM_BACKEND_TERN_BLOCK_ID" "")
  kind=${state%%$'\t'*}
  case "$kind" in
    absent) printf 'missing'; return 0 ;;
    moved) printf 'ambiguous'; return 0 ;;
    ready) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  IFS=$'\t' read -r _ _ _ live exited <<EOF
$state
EOF
  if [ "$live" = false ] || [ "$exited" = true ]; then
    printf 'dead'
    return 0
  fi
  case "$(fm_backend_tern_foreground_class "$FM_BACKEND_TERN_SESSION_ID" "$FM_BACKEND_TERN_BLOCK_ID")" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    unreadable) printf 'unreadable' ;;
    *) printf 'ambiguous' ;;
  esac
}

# --- submit ------------------------------------------------------------------------

# fm_backend_tern_submit_confirm_budget: the seconds one Enter attempt waits for
# a native transition: the caller's budget, floored at FM_BACKEND_TERN_SUBMIT_MIN_SLEEP.
fm_backend_tern_submit_confirm_budget() {  # <caller-budget-seconds>
  awk -v b="${1:-0}" -v m="$FM_BACKEND_TERN_SUBMIT_MIN_SLEEP" 'BEGIN {
    b += 0
    m += 0
    if (b < 0) b = 0
    if (m < 0) m = 0
    if (m > b) b = m
    printf "%.4f", b
  }' 2>/dev/null || printf '%s' "${1:-0}"
}

# fm_backend_tern_wait_for_working: poll <block-id>'s native state up to <polls>
# times spread evenly across <budget-seconds> and print the STRONGEST signal:
#   busy     working or waiting_input was seen (a turn started or reached a
#            prompt: the submit landed); returned the instant it is seen
#   idle     the state was read at least once and never active: readable but
#            inconclusive, so the caller falls through to the composer
#   unknown  no poll read the state (two failed reads in a row end the window):
#            native state is gone for this attempt
fm_backend_tern_wait_for_working() {  # <block-id> <budget-seconds> <polls>
  local block=$1 budget=$2 polls=${3:-1} i interval raw saw_idle=0 unreadable_run=0
  case "$polls" in ''|*[!0-9]*|0) polls=1 ;; esac
  interval=$(awk -v b="$budget" -v p="$polls" 'BEGIN { d = p - 1; if (d < 1) d = 1; v = b / d; if (v < 0) v = 0; printf "%.4f", v }' 2>/dev/null)
  case "$interval" in ''|*[!0-9.]*) interval=0 ;; esac
  for ((i = 0; i < polls; i++)); do
    if [ "$polls" -eq 1 ] || [ "$i" -gt 0 ]; then
      sleep "$interval"
    fi
    raw=$(fm_backend_tern_native_state_raw "$block")
    case "$(fm_backend_tern_classify_submit_state "$raw")" in
      busy) printf 'busy'; return 0 ;;
      idle) saw_idle=1; unreadable_run=0 ;;
      *)
        # Each failed read can cost a full ctl bound, so two in a row end the
        # window: native state is gone for this attempt.
        unreadable_run=$((unreadable_run + 1))
        [ "$unreadable_run" -lt 2 ] || break
        ;;
    esac
  done
  if [ "$saw_idle" -eq 1 ]; then
    printf 'idle'
  else
    printf 'unknown'
  fi
}

# fm_backend_tern_queued_enter_busy: the delivery-busy signal for the shared
# fm_composer_queued_enter_verdict policy: busy only while the agent reports
# working (waiting_input is not a queued-Enter signal, as herdr's blocked is not).
fm_backend_tern_queued_enter_busy() {  # <block-id> -> busy|idle|unknown
  case "$(fm_backend_tern_native_state_raw "$1")" in
    working) printf 'busy' ;;
    idle|waiting_input) printf 'idle' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_tern_send_text_submit: type <text> into <target> ONCE (raw,
# unsubmitted), then press Enter and confirm, retrying Enter only - never
# retyping, because a swallowed Enter leaves the text in the composer and a
# retype would duplicate it. Echoes empty|pending|pending-unproven|unknown|
# send-failed, a subset of the proof-carrying submit vocabulary.
#
# With native agent state readable BEFORE typing, delivery is confirmed by the
# native idle -> working (or waiting_input) transition after Enter, which no
# composer text can fake; a window that stayed idle is inconclusive and falls
# through to the shared composer classifier. With no readable native state the
# whole attempt is the shared composer loop, exactly cmux's.
fm_backend_tern_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-}
  local block baseline confirm_sleep verdict i=0 enter_sent=0
  case "$retries" in ''|*[!0-9]*) retries=1 ;; esac
  fm_backend_tern_parse_target "$target" || { printf 'unknown'; return 0; }
  block=$FM_BACKEND_TERN_BLOCK_ID
  baseline=$(fm_backend_tern_classify_submit_state "$(fm_backend_tern_native_state_raw "$block")")
  fm_backend_tern_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  if [ "$baseline" = unknown ]; then
    fm_composer_submit_retry_core fm_backend_tern_send_key fm_backend_tern_composer_state \
      "$target" "$retries" "$sleep_s" "$expected_label"
    return 0
  fi
  confirm_sleep=$(fm_backend_tern_submit_confirm_budget "$sleep_s")
  while :; do
    if fm_backend_tern_send_key "$target" Enter "$expected_label"; then
      enter_sent=1
    elif [ "$enter_sent" -eq 0 ]; then
      i=$((i + 1))
      if [ "$i" -ge "$retries" ]; then
        printf 'send-failed'
        return 0
      fi
      sleep "$sleep_s"
      continue
    fi
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_tern_wait_for_working "$block" "$confirm_sleep" "$FM_BACKEND_TERN_SUBMIT_POLLS")
      if [ "$verdict" = busy ]; then
        printf 'empty'
        return 0
      fi
    else
      sleep "$sleep_s"
    fi
    verdict=$(fm_backend_tern_composer_state "$target" "$expected_label")
    # The Enter can open a picker, and a later Enter would answer it.
    if fm_composer_blocking_dialog_noted >/dev/null; then
      printf 'unknown'
      return 0
    fi
    case "$verdict" in
      empty) printf 'empty'; return 0 ;;
      pending|pending-unproven) ;;
      *) printf '%s' "$verdict"; return 0 ;;
    esac
    i=$((i + 1))
    if [ "$i" -ge "$retries" ]; then
      if [ "$enter_sent" -eq 0 ]; then
        printf 'send-failed'
      else
        fm_composer_queued_enter_verdict "$verdict" "$(fm_backend_tern_queued_enter_busy "$block")"
      fi
      return 0
    fi
  done
}

# --- teardown and discovery -----------------------------------------------------

# fm_backend_tern_kill: close the task's block, best-effort in the way every
# adapter's kill is: a target that is already gone returns 0 and is not touched.
# A nonzero return means the close could not be proven and the endpoint may
# still be live, so the caller keeps the durable records that name it: an
# unreadable inventory, a block that now lives in another session, a block
# still in the recorded session whose tab no longer carries the task's title,
# or one still listed after a failed close. Closing a task block's only block
# closes its tab; the home session's seed tab keeps the session open.
fm_backend_tern_kill() {  # <target> [unused] [expected-label]
  local expected_label=${3:-} want='' state kind
  if ! fm_backend_tern_parse_target "${1:-}"; then
    echo "error: refusing to close malformed tern target '${1:-}'" >&2
    return 1
  fi
  [ -z "$expected_label" ] || want=$(fm_backend_tern_scoped_title "$expected_label")
  state=$(fm_backend_tern_endpoint_state "$FM_BACKEND_TERN_SESSION_ID" "$FM_BACKEND_TERN_BLOCK_ID" "$want")
  kind=${state%%$'\t'*}
  case "$kind" in
    absent) return 0 ;;
    ready) ;;
    renamed)
      echo "error: tern block $FM_BACKEND_TERN_BLOCK_ID in session $FM_BACKEND_TERN_SESSION_ID is no longer in a tab titled $want, so it cannot be verified as this task's endpoint; not closing it" >&2
      return 1
      ;;
    moved)
      echo "error: tern block $FM_BACKEND_TERN_BLOCK_ID is no longer in session $FM_BACKEND_TERN_SESSION_ID, so it cannot be verified as this task's endpoint; not closing it" >&2
      return 1
      ;;
    *)
      echo "error: tern inventory could not be read, so block $FM_BACKEND_TERN_BLOCK_ID cannot be verified for closing" >&2
      return 1
      ;;
  esac
  if fm_backend_tern_cli close "$FM_BACKEND_TERN_SESSION_ID/$FM_BACKEND_TERN_BLOCK_ID" >/dev/null 2>&1; then
    return 0
  fi
  state=$(fm_backend_tern_endpoint_state "$FM_BACKEND_TERN_SESSION_ID" "$FM_BACKEND_TERN_BLOCK_ID" "")
  case "${state%%$'\t'*}" in
    absent) return 0 ;;
    ready|moved)
      echo "error: tern block $FM_BACKEND_TERN_BLOCK_ID is still present after its close" >&2
      return 1
      ;;
    *)
      echo "error: tern block $FM_BACKEND_TERN_BLOCK_ID could not be read after its close, so whether it survived is unknown" >&2
      return 1
      ;;
  esac
}

# fm_backend_tern_list_live: recovery/orphan discovery. Lists every tab of this
# home's session whose title carries THIS home's scoped prefix
# (fm-<hometag>-), by TITLE, never by a stored id. One
# "<session-id>:<block-id>\t<plain fm-<id> label>" line per live task tab, the
# home tag stripped back off. Read-only: an unreadable inventory lists nothing.
fm_backend_tern_list_live() {
  local name prefix listing
  name=$(fm_backend_tern_session_name)
  prefix="fm-$(fm_backend_tern_home_label)-"
  listing=$(fm_backend_tern_ls_json) || return 0
  printf '%s' "$listing" | jq -r --arg name "$name" --arg prefix "$prefix" '
    .sessions[]? | select(.name == $name) | (.id | tostring) as $sid
    | (.tabs // [])[] | select((.name // "") | startswith($prefix))
    | select(((.blocks // []) | length) > 0)
    | "\($sid):\(.blocks[0].id | tostring)\tfm-\(.name | ltrimstr($prefix))"' 2>/dev/null
  return 0
}
