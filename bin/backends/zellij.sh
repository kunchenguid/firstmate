#!/usr/bin/env bash
# bin/backends/zellij.sh - the zellij session-provider adapter (EXPERIMENTAL).
#
# Design: data/fm-backend-design-d7/report.md ("Zellij Backend" section - the
# interface mapping, implementation choices, and "Zellij gaps to verify" list)
# and herdr-addendum.md D2/D3 (zellij is P3, after herdr; treehouse stays the
# worktree provider). Zellij is a session provider ONLY: the worktree provider
# stays treehouse, exactly like tmux and herdr. Sourced only through
# bin/fm-backend.sh's fm_backend_source in normal operation; the unit tests
# source it directly.
#
# Session shape (report "Zellij implementation choices" #1, unchanged by
# empirical verification): ONE zellij session (default name "firstmate",
# overridable via FM_ZELLIJ_SESSION for test isolation - mirrors herdr's
# HERDR_SESSION), ONE tab per task, with caller-facing label "fm-<id>" and a
# home-scoped actual title. No per-home workspace split (unlike herdr's later
# P3 refinement): zellij has no workspace concept, only sessions/tabs/panes,
# so this stays exactly the report's original choice. Target string shape:
# "<zellij-session>:<pane-id>" (pane id is a bare non-negative integer with no
# embedded colon, so splitting on the FIRST colon is trivially correct and
# mirrors herdr's target-string convention).
#
# Home-scoped tab titles (closes a cross-home collision gap): because every
# task in every firstmate home - primary or secondmate - shares this ONE
# session's tab bar with no per-home split, and zellij enforces no tab-name
# uniqueness at all, two firstmate homes whose task ids happen to collide
# could send/peek/close each other's tabs. This is the exact gap a
# captain-directed no-mistakes review gate caught for the cmux backend
# (docs/cmux-backend.md) and this same tag mechanism (bin/backends/cmux.sh's
# fm_backend_cmux_scoped_title, now shared via bin/fm-backend-hometag-lib.sh)
# is ported here for the identical reason. Every NEW tab is created with a
# title tagged with this installation's home label (fm_backend_zellij_scoped_title,
# "fm-<hometag>-<id>"); every list/find/recover/kill path is scoped to this
# home's own tag. A tab created before this change carries the old untagged
# "fm-<id>" title; target_ready, kill, and ad hoc selector fallback still
# match it, but ONLY when that bare title is unambiguous (exactly one live tab
# in the session carries it) - see fm_backend_zellij_tab_matches_label and
# docs/zellij-backend.md "Home-scoped tab titles" for the full migration
# posture. Moving/relocating a firstmate installation changes its tag
# (acceptable - recorded worktree paths do not survive a move either).
#
# Empirical verification (real zellij 0.44.0, macOS aarch64, 2026-07-02;
# docs/zellij-backend.md has the full evidence log) resolved every "gaps to
# verify" item in the design report, plus additional real findings not
# anticipated by the report:
#
#   1. dump-screen on a background session with NO attached client: WORKS.
#   2. Key names: Enter -> "Enter", Escape -> "Esc" (NOT "Escape"), Ctrl-C ->
#      "Ctrl c" as ONE shell argument with an embedded space (NOT two argv
#      words, NOT "C-c" or "Ctrl+c" - all verified to fail).
#   3. `new-tab --cwd --name` DOES return the created tab's bare integer id on
#      stdout, exactly as documented.
#   4. `list-panes --json`'s `pane_cwd` reflects a `cd` run DIRECTLY in the
#      pane's own top-level shell within one poll (<0.3s) - but does NOT
#      reflect a `cd` performed by a NESTED SUBSHELL the pane's shell
#      launched as a foreground command (verified: `treehouse get` opens
#      exactly such a subshell). `pane_cwd` stays frozen at wherever the
#      pane's shell was when it invoked that foreground command - worse than
#      herdr's frozen-cwd trap (herdr at least exposes a `foreground_cwd`
#      that tracks this; zellij's CLI exposes no live-process cwd field and
#      no per-pane pid to read it from `/proc`/`lsof` either). This directly
#      contradicts the design report's assumption ("acceptable for tmux and
#      zellij") and required a different implementation strategy - see
#      fm_backend_zellij_current_path below and docs/zellij-backend.md
#      "Worktree-path discovery: pane_cwd does not track a subshell".
#   5. `new-tab` DOES steal focus from an attached client with NO flag to
#      suppress it (unlike herdr's --no-focus and tmux's new-window -d).
#      Mitigated (fm_backend_zellij_create_task): capture the previously
#      active tab id before creating, restore it with go-to-tab-by-id
#      afterward - verified to correctly restore an attached client's view
#      and to be a safe no-op with no client attached.
#
#   Additional un-anticipated findings, load-bearing for this adapter:
#   - Every pane-targeting action (write-chars, send-keys, dump-screen, ...)
#     MUST pass an explicit --pane-id. The "focused pane" default is
#     unreliable: a fresh session auto-opens a floating "About Zellij"/release
#     notes PLUGIN pane that starts FOCUSED and shadows the real terminal pane
#     - a pane-id-less send silently goes nowhere.
#   - `zellij action <subcommand>` ALWAYS exits 0, even against a nonexistent
#     session (prints the live session list to stdout, an error to stderr) or
#     a nonexistent pane id in a live session (prints nothing at all, to
#     neither stream). The exit code can NEVER be trusted to detect a bad
#     target. Mitigated: send/capture/cwd ops verify session liveness first
#     (fm_backend_zellij_session_exists, a passive list-sessions query, never
#     auto-creating), verify the specific pane still appears in list-panes JSON,
#     and, for metadata-routed task selector operations, verify the pane's tab
#     still matches the expected caller-facing task label through the home-scoped or
#     unambiguous legacy title before use. Kill verifies the session and, when
#     teardown supplies an expected tab label, verifies a tab id still matches
#     that label before closing it. Output-SHAPE validation (a bare integer tab
#     id, JSON that parses) rejects the "session not found" text fallback. A
#     pane can still die between the preflight check and the operation call;
#     docs/zellij-backend.md records that residual race.
#   - `zellij list-tabs`/`new-tab` does NOT enforce unique tab names (same as
#     herdr's tabs, unlike tmux's own window-name uniqueness), so the
#     duplicate check below is ours, mirroring both prior adapters.
#   - Closing a tab's only pane (`close-pane`) does NOT close the now-empty
#     tab (unlike herdr, where the analogous close DOES remove the tab) - an
#     empty "ghost" tab survives in `list-tabs` until explicitly closed. Kill
#     therefore always resolves the owning tab id and calls
#     `close-tab-by-id`, which verified cleanly removes a live tab (pane and
#     all) in one call - never a separate close-pane first.
#
# Requires: zellij (CLI), jq (JSON parsing). Both are gated behind selecting
# this backend; bin/fm-bootstrap.sh's core tool list is unaffected.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own unit tests, which source it directly, resolve sanely. Mirrors
# bin/backends/herdr.sh's identical fallback; unlike herdr this adapter still
# has no per-home CONTAINER split (one shared session for every home), but
# FM_HOME/FM_ROOT now also feed fm_backend_zellij_home_label's tab-title tag
# below.
FM_BACKEND_ZELLIJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_ZELLIJ_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_ZELLIJ_ROOT/bin/fm-backend-hometag-lib.sh"

# Verified minimum: report.md recommends "likely Zellij 0.44 or newer" for
# returned pane/tab IDs and dump-screen --pane-id; empirically verified
# against the installed 0.44.0 (docs/zellij-backend.md).
FM_BACKEND_ZELLIJ_MIN_MAJOR=0
FM_BACKEND_ZELLIJ_MIN_MINOR=44

# fm_backend_zellij_session: the session name this spawn/op uses.
# FM_ZELLIJ_SESSION mirrors herdr's HERDR_SESSION ambient-selection knob: an
# operator (or firstmate's own isolated test harness) sets it explicitly;
# absent means the shared "firstmate" session. Do not use this alone for
# destructive test cleanup; tests/zellij-test-safety.sh documents and guards
# that path (mirrors tests/herdr-test-safety.sh).
fm_backend_zellij_session() {
  printf '%s' "${FM_ZELLIJ_SESSION:-firstmate}"
}

# fm_backend_zellij_home_label: readable home prefix plus a short hash of the
# resolved FM_ROOT path (bin/fm-backend-hometag-lib.sh). Zellij has one
# session-global tab namespace shared by every firstmate home, so the path
# hash distinguishes every installation, including multiple primary homes.
# Moving an installation changes this tag and old zellij tab titles stop
# matching; task meta already records absolute worktree paths, so repo
# relocation is already outside the supported recovery contract.
fm_backend_zellij_home_label() {
  fm_backend_hometag
}

# fm_backend_zellij_scoped_title: the actual tab title a NEW task's tab is
# created with - the caller-facing "fm-<id>" label, home-tagged as
# "fm-<hometag>-<id>" (mirrors bin/backends/cmux.sh's identical
# fm_backend_cmux_scoped_title). Every list/find/recover/kill path below
# scopes its own-home matches through this.
fm_backend_zellij_scoped_title() {  # <fm-task-label>
  local label=$1 rest home
  home=$(fm_backend_zellij_home_label)
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$home" "$rest"
}

# fm_backend_zellij_tool_check: refuse loudly if zellij or jq is missing.
fm_backend_zellij_tool_check() {
  command -v zellij >/dev/null 2>&1 || { echo "error: backend=zellij selected but the 'zellij' CLI is not installed (https://zellij.dev)" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=zellij selected but 'jq' is not installed (required to parse zellij's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_zellij_version_check: refuse loudly on a missing/incompatible
# zellij client. Verified locally: 0.44.0 (`zellij --version` -> "zellij
# 0.44.0", session-independent - no server/session needs to exist yet).
fm_backend_zellij_version_check() {
  fm_backend_zellij_tool_check || return 1
  local raw ver major rest minor
  raw=$(zellij --version 2>/dev/null) || { echo "error: 'zellij --version' failed; is zellij installed correctly?" >&2; return 1; }
  ver=$(printf '%s' "$raw" | awk '{print $2}')
  case "$ver" in
    ''|*[!0-9.]*)
      echo "error: could not parse a zellij version from '$raw'; refusing to use an unverified zellij build" >&2
      return 1
      ;;
  esac
  major=${ver%%.*}
  rest=${ver#*.}
  minor=${rest%%.*}
  case "$major" in ''|*[!0-9]*) major=0 ;; esac
  case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
  if [ "$major" -lt "$FM_BACKEND_ZELLIJ_MIN_MAJOR" ] || { [ "$major" -eq "$FM_BACKEND_ZELLIJ_MIN_MAJOR" ] && [ "$minor" -lt "$FM_BACKEND_ZELLIJ_MIN_MINOR" ]; }; then
    echo "error: zellij $ver is older than the verified minimum $FM_BACKEND_ZELLIJ_MIN_MAJOR.$FM_BACKEND_ZELLIJ_MIN_MINOR; update zellij before using backend=zellij" >&2
    return 1
  fi
  return 0
}

# fm_backend_zellij_cli: run `zellij --session <session> action <args...>`,
# setting BOTH the ZELLIJ_SESSION_NAME env var AND the leading global
# `--session <name>` flag (zellij's session-target flag is GLOBAL, before the
# subcommand - unlike herdr's trailing --session - verified both forms
# independently route correctly on the installed 0.44.0 client; kept together
# for defense in depth, mirroring bin/backends/herdr.sh's fm_backend_herdr_cli
# rationale even though no equivalent env-var-unreliable incident has been
# observed for zellij).
fm_backend_zellij_cli() {  # <session> <action-subcommand-and-args...>
  local session=$1
  shift
  ZELLIJ_SESSION_NAME="$session" zellij --session "$session" "$@"
}

# fm_backend_zellij_session_exists: passive, READ-ONLY liveness check - never
# starts or creates a session (unlike herdr's target_ready, which DOES
# auto-start its server: a herdr server restart is non-destructive and
# recovers persisted state, but zellij's `kill-session` is destructive and
# recreating an unrelated target session under the same name would silently
# orphan whatever the caller actually meant to reach). Every op below calls
# this first and fails rather than guessing.
fm_backend_zellij_session_exists() {  # <session>
  zellij list-sessions --short --no-formatting 2>/dev/null | grep -qxF "$1"
}

# fm_backend_zellij_server_ensure: create the named session in the background,
# headless (no attached client), if it does not already exist - mirrors
# tmux's `tmux has-session || tmux new-session -d` and herdr's server_ensure.
# Verified: `zellij attach -b <name>` with stdin redirected from /dev/null and
# no controlling TTY creates the session and returns promptly (it cannot
# actually attach without a TTY, so it exits after creating); running it again
# against an EXISTING session prints "Session already exists" and exits 1 -
# harmless here because existence is checked first and the launch is
# backgrounded, its exit status never inspected.
fm_backend_zellij_server_ensure() {  # <session>
  local session=$1 i
  fm_backend_zellij_session_exists "$session" && return 0
  ( nohup zellij attach -b "$session" </dev/null >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    fm_backend_zellij_session_exists "$session" && return 0
    sleep 0.5
  done
  echo "error: zellij session '$session' did not come up within 10s" >&2
  return 1
}

# fm_backend_zellij_container_ensure: the full spawn-time container-ensure
# sequence (version gate, session). Echoes the session name (no second
# "workspace" component - zellij has no such concept, unlike herdr).
fm_backend_zellij_container_ensure() {
  local session
  fm_backend_zellij_version_check || return 1
  session=$(fm_backend_zellij_session)
  fm_backend_zellij_server_ensure "$session" || return 1
  printf '%s' "$session"
}

# fm_backend_zellij_pane_for_tab: the terminal (non-plugin) pane id for
# <tab_id> in <session>, via one list-panes call filtered by tab_id and
# is_plugin==false. Terminal pane ids are globally unique across a session's
# whole tab set (verified: sequential across tabs, a SEPARATE numbering
# namespace from plugin panes, which is why a plugin pane and a terminal pane
# can share the same bare "id" - the CLI's own --pane-id contract, "3
# (equivalent to terminal_3)", already documents this split. Never assumes a
# tab-position/pane-number correspondence.
fm_backend_zellij_pane_for_tab() {  # <session> <tab_id>
  local session=$1 tab_id=$2
  fm_backend_zellij_cli "$session" action list-panes --json 2>/dev/null \
    | jq -r --argjson t "$tab_id" '.[]? | select(.tab_id == $t and .is_plugin == false) | .id' 2>/dev/null | head -1
}

# fm_backend_zellij_tab_for_pane: the owning tab id for <pane_id> in
# <session>, the reverse lookup kill needs (meta stores only the pane in the
# target string; the tab id is looked up fresh rather than trusted stale,
# mirroring herdr's label-based, never-trust-a-stored-id recovery posture).
fm_backend_zellij_tab_for_pane() {  # <session> <pane_id>
  local session=$1 pane_id=$2
  fm_backend_zellij_cli "$session" action list-panes --json 2>/dev/null \
    | jq -r --argjson p "$pane_id" '.[]? | select(.id == $p and .is_plugin == false) | .tab_id' 2>/dev/null | head -1
}

fm_backend_zellij_pane_exists() {  # <session> <pane_id>
  local session=$1 pane_id=$2
  fm_backend_zellij_cli "$session" action list-panes --json 2>/dev/null \
    | jq -e --argjson p "$pane_id" '[.[]? | select(.id == $p and .is_plugin == false)] | length > 0' >/dev/null 2>&1
}

# fm_backend_zellij_tab_matches_label: does <tab_id> in <session> carry the
# tab name firstmate expects for the caller-facing task label <label>?
# Checks the home-scoped, tagged title first (fm_backend_zellij_scoped_title
# - what every NEW tab is created with), then falls back to the legacy
# untagged bare title (the plain <label>, e.g. "fm-<id>") for a tab created
# before this home-scoping change shipped - but ONLY when that bare name is
# not ambiguous: exactly one live tab in the whole session carries it. A bare
# name shared by 2+ live tabs (this home's own pre-migration tab plus, say, a
# same-named tab from a different firstmate home sharing this one zellij
# session) refuses rather than silently trusting whichever one happened to
# match - the migration posture documented in docs/zellij-backend.md
# "Home-scoped tab titles". One list-tabs call serves every check here (the
# scoped check, the bare check, and the ambiguity count all read the SAME
# already-fetched JSON), so a caller whose fake-CLI fixture supplies exactly
# one list-tabs response keeps working unchanged.
fm_backend_zellij_tab_matches_label() {  # <session> <tab_id> <label>
  local session=$1 tab_id=$2 label=$3 scoped tabs count
  scoped=$(fm_backend_zellij_scoped_title "$label")
  tabs=$(fm_backend_zellij_cli "$session" action list-tabs --json 2>/dev/null)
  printf '%s' "$tabs" | jq -e --argjson t "$tab_id" --arg want "$scoped" \
    '[.[]? | select(.tab_id == $t and .name == $want)] | length > 0' >/dev/null 2>&1 && return 0
  printf '%s' "$tabs" | jq -e --argjson t "$tab_id" --arg want "$label" \
    '[.[]? | select(.tab_id == $t and .name == $want)] | length > 0' >/dev/null 2>&1 || return 1
  count=$(printf '%s' "$tabs" | jq -r --arg want "$label" '[.[]? | select(.name == $want)] | length' 2>/dev/null)
  [ "$count" = "1" ]
}

# fm_backend_zellij_create_task: create the task's tab (one terminal pane) in
# <session>, refusing an existing <label>. Zellij does NOT enforce tab-name
# uniqueness itself (verified: two tabs can share a name), so the duplicate
# check is ours, mirroring both tmux's and herdr's adapters. The tab is
# always created with the home-scoped, tagged title
# (fm_backend_zellij_scoped_title), never the bare caller-facing label - see
# the file header's "Home-scoped tab titles" note.
#
# Focus-steal mitigation (verified real finding, no upstream suppression
# flag exists): `new-tab` unconditionally focuses the created tab for every
# attached client. Capture the previously-active tab id (if any) before
# creating, and restore it with `go-to-tab-by-id` afterward - verified to
# correctly move an attached client's view back and to be a safe, silent
# no-op when no client is attached (the common case: an unattended firstmate
# spawn). Best-effort: a failure to restore never fails the spawn.
#
# Echoes "<tab_id> <pane_id>" on success.
fm_backend_zellij_create_task() {  # <session> <label> <cwd>
  local session=$1 label=$2 cwd=$3 title tabs dup prev_active tab_id pane_id
  fm_backend_zellij_session_exists "$session" || { echo "error: zellij session '$session' does not exist; run container_ensure first" >&2; return 1; }
  title=$(fm_backend_zellij_scoped_title "$label")
  tabs=$(fm_backend_zellij_cli "$session" action list-tabs --json 2>/dev/null)
  dup=$(printf '%s' "$tabs" | jq -r --arg want "$title" '.[]? | select(.name == $want) | .tab_id' 2>/dev/null | head -1)
  if [ -n "$dup" ]; then
    echo "error: zellij tab '$title' already exists in session '$session'" >&2
    return 1
  fi
  prev_active=$(printf '%s' "$tabs" | jq -r '.[]? | select(.active == true) | .tab_id' 2>/dev/null | head -1)
  tab_id=$(fm_backend_zellij_cli "$session" action new-tab --cwd "$cwd" --name "$title" 2>/dev/null | tr -d '[:space:]')
  case "$tab_id" in
    ''|*[!0-9]*)
      echo "error: zellij new-tab did not return a numeric tab id for '$title' (got '$tab_id'; session '$session' may not exist)" >&2
      return 1
      ;;
  esac
  pane_id=$(fm_backend_zellij_pane_for_tab "$session" "$tab_id")
  if [ -z "$pane_id" ]; then
    echo "error: could not find a terminal pane for zellij tab $tab_id (session '$session')" >&2
    return 1
  fi
  if [ -n "$prev_active" ] && [ "$prev_active" != "$tab_id" ]; then
    fm_backend_zellij_cli "$session" action go-to-tab-by-id "$prev_active" >/dev/null 2>&1 || true
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}

# fm_backend_zellij_parse_target: split "<session>:<pane_id>" on the FIRST
# colon (the pane id is a bare integer with no embedded colon, so this is
# simpler than herdr's equivalent but kept structurally parallel). Sets
# FM_BACKEND_ZELLIJ_SESSION and FM_BACKEND_ZELLIJ_PANE for the caller.
fm_backend_zellij_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_ZELLIJ_SESSION=${target%%:*}
  FM_BACKEND_ZELLIJ_PANE=${target#*:}
  [ -n "$FM_BACKEND_ZELLIJ_SESSION" ] && [ -n "$FM_BACKEND_ZELLIJ_PANE" ] && [ "$FM_BACKEND_ZELLIJ_PANE" != "$target" ]
}

# fm_backend_zellij_target_ready: parse the target and verify its session and
# pane are alive. When the caller knows the owning firstmate task label, verify
# the pane belongs to that named tab before trusting the numeric pane id.
fm_backend_zellij_target_ready() {  # <target> [expected-label]
  local expected_label=${2:-} tab_id
  fm_backend_zellij_parse_target "$1" || return 1
  fm_backend_zellij_session_exists "$FM_BACKEND_ZELLIJ_SESSION" || return 1
  if [ -n "$expected_label" ]; then
    tab_id=$(fm_backend_zellij_tab_for_pane "$FM_BACKEND_ZELLIJ_SESSION" "$FM_BACKEND_ZELLIJ_PANE" 2>/dev/null)
    [ -n "$tab_id" ] || return 1
    fm_backend_zellij_tab_matches_label "$FM_BACKEND_ZELLIJ_SESSION" "$tab_id" "$expected_label"
    return $?
  fi
  fm_backend_zellij_pane_exists "$FM_BACKEND_ZELLIJ_SESSION" "$FM_BACKEND_ZELLIJ_PANE"
}

# fm_backend_zellij_current_path: the live pane's cwd, or empty on any error.
# Mirrors tmux's pane_current_path poll used for worktree-path discovery after
# `treehouse get`.
#
# Verified pitfall (docs/zellij-backend.md "Worktree-path discovery: pane_cwd
# does not track a subshell"): `list-panes --json`'s `pane_cwd` DOES reflect a
# `cd` run directly in the pane's own top-level shell, but stays FROZEN at
# whatever directory the pane's shell was in when it launched `treehouse get`
# as a foreground command - it never follows that command's own internal `cd`
# into the acquired worktree, even after the subshell is fully interactive and
# a `pwd` typed into it prints the correct live path on screen. Zellij's CLI
# exposes no per-pane pid and no live-process cwd field to read instead
# (unlike herdr's `foreground_cwd`), so passive JSON polling cannot solve
# this. Active probe instead: print the pane's `$PWD` with a unique marker
# (atomically submitted, mirroring send_text_line), briefly settle, then capture
# and read only that marker line. Scoped to fm-spawn.sh's own worktree-discovery
# poll loop (the only caller of this op), where injecting a harmless extra
# command before the harness ever launches is an acceptable trade for a reliable
# answer.
fm_backend_zellij_current_path() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-} out line marker_begin="__FM_ZELLIJ_CWD_BEGIN__" marker_end="__FM_ZELLIJ_CWD_END__" in_block=0 chunk="" last=""
  fm_backend_zellij_target_ready "$target" "$expected_label" || return 0
  fm_backend_zellij_send_text_line "$target" "printf '%s\n' '$marker_begin'; pwd; printf '%s\n' '$marker_end'" "$expected_label" || return 0
  sleep 0.3
  out=$(fm_backend_zellij_capture "$target" 200 "$expected_label") || return 0
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

# fm_backend_zellij_send_literal: send TEXT as literal, UNSUBMITTED input via
# bracketed paste - the caller sends Enter separately. Mirrors tmux's
# `send-keys -t T -l text` / herdr's `pane send-text`. Verified: `action
# paste` does NOT auto-submit and uses bracketed paste mode (the report's
# recommendation over write-chars, for popup-safety parity with tmux/herdr).
fm_backend_zellij_send_literal() {  # <target> <text> [expected-label]
  fm_backend_zellij_target_ready "$1" "${3:-}" || return 1
  fm_backend_zellij_cli "$FM_BACKEND_ZELLIJ_SESSION" action paste --pane-id "$FM_BACKEND_ZELLIJ_PANE" -- "$2" >/dev/null 2>&1
}

# fm_backend_zellij_normalize_key: map firstmate's key vocabulary (Enter,
# Escape, C-c, as used by fm-send.sh --key and stuck-crewmate-recovery) onto
# zellij's verified `action send-keys` names. Verified empirically: "Enter"
# and "Esc" work; "Escape" and "escape" are REJECTED ("Invalid key"); Ctrl-C
# must be the single argument "Ctrl c" (a space-separated two-word key
# expression passed as ONE shell arg) - "C-c", "Ctrl+c", and two separate argv
# words all fail.
fm_backend_zellij_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'Enter' ;;
    Escape|escape|Esc|esc) printf 'Esc' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|'Ctrl c'|'ctrl c') printf 'Ctrl c' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_zellij_send_key: one named special key, targeted at the pane by
# its EXPLICIT --pane-id (never the ambient "focused pane" default - verified
# unreliable, see file header). Mirrors fm-send.sh's --key path.
fm_backend_zellij_send_key() {  # <target> <key> [expected-label]
  fm_backend_zellij_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_zellij_normalize_key "$2")
  fm_backend_zellij_cli "$FM_BACKEND_ZELLIJ_SESSION" action send-keys --pane-id "$FM_BACKEND_ZELLIJ_PANE" "$key" >/dev/null 2>&1
}

# fm_backend_zellij_send_text_line: send one line of TEXT then submit,
# ATOMICALLY - mirrors tmux's `send-keys -t T text Enter` / herdr's `pane
# run`. Used for the fixed spawn-time commands (treehouse get, the GOTMPDIR
# export). Zellij has no single-call atomic "run and submit" action, so this
# composes paste (literal) + send-keys Enter, exactly like send_literal +
# send_key are composed elsewhere - the two-step form is the ONLY form for
# this adapter, unlike tmux/herdr which have a genuinely atomic primitive.
fm_backend_zellij_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_zellij_send_literal "$1" "$2" "${3:-}" || return 1
  fm_backend_zellij_send_key "$1" Enter "${3:-}"
}

# fm_backend_zellij_capture: bounded plain-text pane capture. Mirrors
# fm-peek.sh's/fm-watch.sh's `tmux capture-pane -p -t T -S -N`. `dump-screen`
# has no --lines bound, so routine 40-line-or-smaller reads use the current
# viewport and larger explicit reads use --full scrollback, then trim locally.
# On a very short viewport, a small read can see fewer than the requested lines.
fm_backend_zellij_capture() {  # <target> <lines> [expected-label]
  fm_backend_zellij_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-40} out
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  if [ "$lines" -le 40 ]; then
    out=$(fm_backend_zellij_cli "$FM_BACKEND_ZELLIJ_SESSION" action dump-screen --pane-id "$FM_BACKEND_ZELLIJ_PANE" 2>/dev/null) || return 1
  else
    out=$(fm_backend_zellij_cli "$FM_BACKEND_ZELLIJ_SESSION" action dump-screen --pane-id "$FM_BACKEND_ZELLIJ_PANE" --full 2>/dev/null) || return 1
  fi
  printf '%s' "$out" | tail -n "$lines"
}

# fm_backend_zellij_send_text_submit: type <text> into <target> once (raw,
# unsubmitted, via send_literal), then submit with a named Enter key, retried
# (Enter only, never retyped) until the pane visibly changes. Unlike herdr's
# current native agent-state idle-baseline verifier and composer-state
# fallback, zellij still uses a content-diff strategy because its CLI has no
# cursor-row/ANSI capture primitive exposed:
# capture the pane right after typing (before any Enter) as the TYPED baseline,
# then after each Enter attempt capture again - unchanged means Enter was
# swallowed (retry); changed means submitted. This content-diff approach is
# also the load-bearing defense against the
# unconditional-exit-0 CLI quirk documented in the file header: a truly dead
# target never shows a change, so it correctly reports pending/unknown rather
# than a false "sent". Echoes empty|pending|unknown|send-failed, the SAME
# vocabulary fm-send.sh already branches on for tmux and herdr.
fm_backend_zellij_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} typed after i=0
  fm_backend_zellij_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  typed=$(fm_backend_zellij_capture "$target" 6 "$expected_label") || { printf 'unknown'; return 0; }
  while :; do
    fm_backend_zellij_send_key "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    after=$(fm_backend_zellij_capture "$target" 6 "$expected_label") || { printf 'unknown'; return 0; }
    if [ "$after" != "$typed" ]; then
      printf 'empty'
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# fm_backend_zellij_kill: remove the task's tab, best-effort (mirrors
# tmux-kill-window's/herdr-pane-close's `|| true` contract). Verified: unlike
# herdr, closing a zellij tab's only PANE does NOT close the tab itself (an
# empty tab survives in list-tabs); `close-tab-by-id` on a live tab DOES
# cleanly remove both the pane and the tab in one call, verified to need no
# separate pane-close first. The owning tab id is looked up fresh from the
# pane id when possible via fm_backend_zellij_tab_for_pane; teardown also
# passes the recorded tab id and expected tab label for already-empty ghost
# tabs. Any tab id is verified against the expected label when one is provided.
fm_backend_zellij_kill() {  # <target> [tab_id] [expected_label]
  fm_backend_zellij_parse_target "$1" || return 0
  fm_backend_zellij_session_exists "$FM_BACKEND_ZELLIJ_SESSION" || return 0
  local tab_id fallback_tab_id=${2:-} expected_label=${3:-}
  tab_id=$(fm_backend_zellij_tab_for_pane "$FM_BACKEND_ZELLIJ_SESSION" "$FM_BACKEND_ZELLIJ_PANE" 2>/dev/null)
  if [ -n "$tab_id" ] && [ -n "$expected_label" ] && ! fm_backend_zellij_tab_matches_label "$FM_BACKEND_ZELLIJ_SESSION" "$tab_id" "$expected_label"; then
    tab_id=
  fi
  case "$fallback_tab_id" in
    ''|*[!0-9]*) ;;
    *)
      if [ -z "$tab_id" ]; then
        if [ -z "$expected_label" ] || fm_backend_zellij_tab_matches_label "$FM_BACKEND_ZELLIJ_SESSION" "$fallback_tab_id" "$expected_label"; then
          tab_id=$fallback_tab_id
        fi
      fi
      ;;
  esac
  if [ -n "$tab_id" ]; then
    fm_backend_zellij_cli "$FM_BACKEND_ZELLIJ_SESSION" action close-tab-by-id "$tab_id" >/dev/null 2>&1 || true
  elif [ -z "$expected_label" ]; then
    fm_backend_zellij_cli "$FM_BACKEND_ZELLIJ_SESSION" action close-pane --pane-id "$FM_BACKEND_ZELLIJ_PANE" >/dev/null 2>&1 || true
  fi
}

# fm_backend_zellij_list_live: recovery/orphan discovery. Lists every tab in
# <session> whose title carries THIS firstmate home's own tag
# (fm-<hometag>-, fm_backend_zellij_home_label) - never any other home's
# tagged tabs, and never a bare untagged "fm-<id>" tab either (this sweep
# deliberately does NOT attempt the legacy-bare-title fallback
# fm_backend_zellij_tab_matches_label uses for a single already-known tab:
# telling apart "our own pre-migration tab" from "another home's same-shaped
# bare title" in a bulk, no-numeric-id-in-hand sweep is not something this
# adapter can do safely - see docs/zellij-backend.md "Home-scoped tab
# titles"). A pre-migration task is still reachable through its recorded
# window= meta, which target_ready/kill DO accept via that bare-title
# fallback. One "<session>:<pane_id>\t<plain fm-<id> label>" line per live,
# in-home task tab (the home tag is stripped back off before printing, so
# callers see the same plain label they always have). Read-only: a session
# that does not exist yet simply lists nothing.
fm_backend_zellij_list_live() {  # <session>
  local session=$1 home prefix tabs tab_id name pane_id plain
  fm_backend_zellij_session_exists "$session" || return 0
  home=$(fm_backend_zellij_home_label)
  prefix="fm-$home-"
  tabs=$(fm_backend_zellij_cli "$session" action list-tabs --json 2>/dev/null) || return 0
  while IFS=$'\t' read -r tab_id name; do
    [ -n "$tab_id" ] || continue
    plain=${name#"$prefix"}
    [ -n "$plain" ] || continue
    pane_id=$(fm_backend_zellij_pane_for_tab "$session" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s\tfm-%s\n' "$session" "$pane_id" "$plain"
  done < <(printf '%s' "$tabs" | jq -r --arg prefix "$prefix" '.[]? | select(.name | startswith($prefix)) | "\(.tab_id)\t\(.name)"' 2>/dev/null)
}

# fm_backend_zellij_resolve_bare_selector: the live-tab-listing fallback for
# an ad hoc selector with no meta (mirrors tmux's list-windows grep and
# herdr's equivalent). Searches every active zellij session for a tab
# matching <name>: the home-scoped, tagged title first
# (fm_backend_zellij_scoped_title), then falls back to an exact bare <name>
# match ONLY when unambiguous - exactly one tab across every active session
# carries it - mirroring fm_backend_zellij_tab_matches_label's migration
# posture. Rare path in practice (zellij tasks normally carry meta);
# best-effort. Not wired into fm_backend_resolve_selector's dispatcher
# (bin/fm-backend.sh), mirroring herdr: that bare-selector fallback stays
# tmux-only by design, and zellij/herdr tasks are targeted via task-selector
# meta or an explicit recorded target.
fm_backend_zellij_resolve_bare_selector() {  # <name>
  local name=$1 scoped sessions session tabs tab_id count=0 pane_id bare_session='' bare_tab_id=''
  scoped=$(fm_backend_zellij_scoped_title "$name")
  sessions=$(zellij list-sessions --short --no-formatting 2>/dev/null)
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(fm_backend_zellij_cli "$session" action list-tabs --json 2>/dev/null)
    tab_id=$(printf '%s' "$tabs" | jq -r --arg want "$scoped" '.[]? | select(.name == $want) | .tab_id' 2>/dev/null | head -1)
    [ -n "$tab_id" ] || continue
    pane_id=$(fm_backend_zellij_pane_for_tab "$session" "$tab_id") || continue
    [ -n "$pane_id" ] || continue
    printf '%s:%s' "$session" "$pane_id"
    return 0
  done <<EOF
$sessions
EOF
  while IFS= read -r session; do
    [ -n "$session" ] || continue
    tabs=$(fm_backend_zellij_cli "$session" action list-tabs --json 2>/dev/null)
    while IFS= read -r tab_id; do
      [ -n "$tab_id" ] || continue
      count=$((count + 1))
      if [ "$count" -eq 1 ]; then
        bare_session=$session
        bare_tab_id=$tab_id
      fi
    done <<EOF_MATCHES
$(printf '%s' "$tabs" | jq -r --arg want "$name" '.[]? | select(.name == $want) | .tab_id' 2>/dev/null)
EOF_MATCHES
  done <<EOF
$sessions
EOF
  if [ "$count" -eq 1 ]; then
    pane_id=$(fm_backend_zellij_pane_for_tab "$bare_session" "$bare_tab_id") || pane_id=
    if [ -n "$pane_id" ]; then
      printf '%s:%s' "$bare_session" "$pane_id"
      return 0
    fi
  fi
  echo "error: no zellij tab named $name in any active session" >&2
  return 1
}
