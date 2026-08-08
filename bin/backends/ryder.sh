#!/usr/bin/env bash
# bin/backends/ryder.sh - the Ryder session-provider adapter (EXPERIMENTAL).
#
# Design: data/stack-session-host/report.md section 10 (the adapter sketch)
# plus the live verification pass recorded in docs/ryder-backend.md, run
# against a `ryder` built from the Ryder session host's own tree. Ryder is a
# session provider ONLY, exactly like herdr/zellij/cmux: the worktree provider
# stays treehouse. Sourced only through bin/fm-backend.sh's fm_backend_source
# in normal operation; the tests source it directly.
#
# The app-side prerequisite is the `ryder` binary from the Ryder session host;
# docs/ryder-backend.md "Setup" owns where it comes from and how it is built.
# Its wire contract is the host's own PROTOCOL.md, which is written for this
# adapter and is the authority for every field read below.
#
# Container shape: NONE. Ryder has no session, workspace, or tab layer to
# multiplex - one detached host process owns one pty, and the sessions
# directory IS the registry. That makes container_ensure a pure version gate
# with nothing to stand up, the simplest of every backend.
#
# Target string shape: the Ryder session id ALONE, with no colon and no
# composite parts. Unlike tmux ("<session>:<window>"), herdr/zellij
# ("<session>:<pane>") and cmux ("<workspace>:<surface>"), a Ryder session id
# is already globally unique, so nothing is split. The id is also constrained
# by the host to [A-Za-z0-9._@%+-] (PROTOCOL.md section 1), which is exactly
# fm_backend_endpoint_atom_valid's alphabet, so a session id is directly usable
# as an endpoint target with no escaping.
#
# The id is DERIVED, not stored-and-trusted: it is the home-scoped task label
# (fm_backend_ryder_session_id), so a recorded target is a pure function of the
# task and the home. That is why recovery here needs no id refresh dance - a
# stale id is not a reachable state - and why fm_backend_ryder_target_ready can
# cross-check a recorded target against its expected label with no CLI call at
# all. Home scoping matters for the same reason it does for cmux and zellij:
# $RYDER_HOME is one machine-global namespace, so two firstmate homes with
# colliding task ids would otherwise address each other's sessions.
#
# Empirical findings from the live verification pass (docs/ryder-backend.md has
# the full evidence log) that shaped this adapter, including two that correct
# the design sketch:
#
#   1. `state.cwd` LIVE-TRACKS the foreground process, read from the kernel -
#      verified: a `cd` inside the session moved it immediately. So this is the
#      first session-provider-only backend after tmux that needs NO active
#      pwd-marker probe for worktree discovery (zellij and cmux both do,
#      because their cwd fields freeze at creation or at the top-level shell).
#   2. `snapshot --lines N` is a genuine drop-in for `tmux capture-pane -p -S
#      -N`: the reply is always the whole viewport including trailing blank
#      rows, plus up to N lines of scrollback above it. It is NOT trimmed to N
#      lines the way herdr's and cmux's capture wrappers have to trim theirs,
#      so no "fetch generous, trim locally" workaround is needed or wanted.
#   3. `cursor_line` is VIEWPORT-relative, NOT relative to the returned text.
#      Verified: with `--lines 10` against a scrolled session, the reply
#      carried 50 lines of text, the cursor genuinely sat on the last one, and
#      `cursor_line` still read 39 (the last row of the 40-row viewport). The
#      cursor's index in `.text` is therefore `.scrollback + .cursor_line`, and
#      `.scrollback` must be read from the REPLY (it reports how much history
#      was actually available, which is not always what was requested). Getting
#      this wrong silently classifies the wrong row as the composer, which is
#      why fm_backend_ryder_composer_state computes the offset explicitly.
#   4. Session ids are REUSABLE after death: `create` sweeps a stale directory
#      into archived/ first, so re-creating a task with the same derived id
#      succeeds. Verified against a killed session. The duplicate check below
#      is therefore about LIVE collisions only, which the host enforces itself
#      with a typed `already_running` error.
#   5. Labels are NOT unique - two sessions were created live sharing one
#      label. The id is what is unique, which is another reason the id (not a
#      lookup by label) is the target.
#   6. CORRECTS THE SKETCH: `ambiguous` cannot be dropped. The sketch reasoned
#      that tmux needs it only because two name sources disagree, which is
#      genuinely gone here - `fg_argv0` is read from the process's vnode and
#      cannot be rewritten, so there is one authority. But firstmate's spawn
#      flow puts a LOGIN SHELL in the pty and runs the harness inside it (that
#      is what `treehouse get` needs), so an unrecognized foreground process is
#      still a real, reachable state that cannot be attributed either way.
#      Collapsing it into `dead` would license recovery against a live agent,
#      and recovery means a duplicate agent on a live worktree - the one
#      outcome bin/backends/tmux.sh's own classifier is built to avoid. See
#      fm_backend_ryder_agent_state.
#   7. CORRECTS THE SKETCH: the socket path is subject to the platform's
#      ~104-byte sun_path limit, and `$RYDER_HOME` plus a long derived id can
#      exceed it. The host checks up front and refuses with a typed `usage`
#      error naming the byte count, so this fails loudly at create time rather
#      than mysteriously at connect time. docs/ryder-backend.md "Known limits"
#      owns the arithmetic.
#
# Requires: ryder (the session host CLI) and jq (JSON parsing). Bootstrap
# detects these through fm_backend_required_tools only when ryder is the
# resolved backend; this adapter also gates them again before spawning.

# FM_HOME fallback: every real caller already sets FM_HOME as a global before
# sourcing fm-backend.sh (which sources this file); this exists only so this
# file's own tests, which source it directly, resolve sanely. Mirrors
# bin/backends/{zellij,cmux}.sh's identical fallback.
FM_BACKEND_RYDER_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_RYDER_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$FM_BACKEND_RYDER_ROOT/bin/fm-backend-hometag-lib.sh"

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule) plus the shared ANSI ghost stripper. Owned
# by bin/fm-composer-lib.sh, reused by every backend so the decision cannot
# drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_RYDER_ROOT/bin/fm-composer-lib.sh"

# Shared process-name vocabulary (agent|shell|other), owned by
# bin/fm-process-identity-lib.sh and shared with bin/backends/tmux.sh.
# shellcheck source=bin/fm-process-identity-lib.sh
. "$FM_BACKEND_RYDER_ROOT/bin/fm-process-identity-lib.sh"

# The protocol version this adapter speaks. PROTOCOL.md's versioning rule makes
# this the real compatibility contract, not the binary's semver: the protocol
# version and the $RYDER_HOME/vN path component move together and never
# separately, fields may be added within a version but never changed, and a
# client whose version does not match refuses to proceed rather than guessing.
# Gating on the protocol is therefore both stricter and more durable than
# gating on a version number that may move for unrelated app-side reasons.
FM_BACKEND_RYDER_PROTOCOL=1

# Ambient harness markers stripped from a new session's environment. The host
# builds the agent's environment from its own and deliberately strips only the
# markers it owns (its own RYDER_*, plus TMUX/TMUX_PANE, which are outright
# false inside a Ryder pty); it documents harness-specific markers as the
# CALLER's policy, which for firstmate means this adapter. Firstmate normally
# spawns a worker from inside an agent session, so without this every worker
# would inherit its parent's child-process markers. Each entry is here for a
# named reason:
#   CLAUDE_CODE_CHILD_SESSION - observed live to make Claude Code disable
#     transcript saving in an unrelated agent that merely inherited it.
#   CLAUDECODE - bin/fm-harness.sh's own harness auto-detection marker, so an
#     inherited copy makes a spawned worker misidentify its own harness.
#   GROK_AGENT - the same hazard for grok (.agents/skills/harness-adapters).
# Override for a home that needs a different set; an empty value strips none.
FM_BACKEND_RYDER_ENV_REMOVE=${FM_BACKEND_RYDER_ENV_REMOVE-CLAUDE_CODE_CHILD_SESSION CLAUDECODE GROK_AGENT}

# The shell put in the pty. Ryder spawns an explicit argv rather than a
# configured default-command the way tmux does, so the choice is named here.
# A login shell matches what `tmux new-window` gives a task pane, which is what
# the shared spawn steps (`treehouse get`, the harness launch command) expect.
FM_BACKEND_RYDER_SHELL=${FM_BACKEND_RYDER_SHELL:-${SHELL:-/bin/bash}}

fm_backend_ryder_bin() {
  command -v ryder >/dev/null 2>&1 || return 1
  printf 'ryder'
}

fm_backend_ryder_tool_check() {
  fm_backend_ryder_bin >/dev/null 2>&1 || { echo "error: backend=ryder selected but the 'ryder' CLI was not found on PATH; see docs/ryder-backend.md 'Setup'" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=ryder selected but 'jq' is not installed (required to parse ryder's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_ryder_cli: run `ryder <args...>`. A thin seam so every call site
# resolves the binary the same way and a future bundle-path fallback (cmux
# needs one) lands in exactly one place.
fm_backend_ryder_cli() {  # <ryder-verb-and-args...>
  local bin
  bin=$(fm_backend_ryder_bin) || return 1
  "$bin" "$@"
}

# fm_backend_ryder_version_check: refuse loudly on a missing or
# protocol-incompatible client. `ryder --version` needs no socket and no
# session - the host documents that explicitly as what a client-version gate
# needs - so this is a pure client gate with nothing running.
fm_backend_ryder_version_check() {
  fm_backend_ryder_tool_check || return 1
  local raw proto
  raw=$(fm_backend_ryder_cli --version 2>/dev/null) || { echo "error: 'ryder --version' failed; is the ryder session host installed correctly?" >&2; return 1; }
  proto=$(printf '%s' "$raw" | sed -n 's/.*protocol v\([0-9][0-9]*\).*/\1/p')
  case "$proto" in
    ''|*[!0-9]*)
      echo "error: could not parse a ryder protocol version from '$raw'; refusing to use an unverified ryder build" >&2
      return 1
      ;;
  esac
  if [ "$proto" -ne "$FM_BACKEND_RYDER_PROTOCOL" ]; then
    echo "error: ryder speaks protocol v$proto but this adapter speaks v$FM_BACKEND_RYDER_PROTOCOL ('$raw'); a mismatched protocol serves a different \$RYDER_HOME/vN tree and cannot see this one's sessions - update firstmate or ryder so both agree" >&2
    return 1
  fi
  return 0
}

# fm_backend_ryder_container_ensure: the full spawn-time container-ensure
# sequence. Ryder has no container: no daemon to start, no session to attach
# to, no workspace to stand up. `create` forks its own host per session, so the
# only thing that can be wrong before a spawn is the client itself. Nothing to
# echo; callers proceed straight to fm_backend_ryder_create_task.
fm_backend_ryder_container_ensure() {
  fm_backend_ryder_version_check || return 1
  return 0
}

# fm_backend_ryder_home_label: readable home prefix plus a short hash of the
# resolved FM_ROOT path. $RYDER_HOME is one machine-global session namespace,
# so the path hash distinguishes every firstmate installation, including
# multiple primary homes. Derivation lives in bin/fm-backend-hometag-lib.sh,
# shared with cmux's and zellij's identical shared-namespace collision fix.
fm_backend_ryder_home_label() {
  fm_backend_hometag
}

# fm_backend_ryder_session_id: the Ryder session id for a firstmate task label.
# This IS the endpoint target, and it is a pure function of the label and the
# home, which is what makes a recorded target verifiable with no CLI call.
fm_backend_ryder_session_id() {  # <fm-task-label>
  local label=$1 rest home
  home=$(fm_backend_ryder_home_label)
  case "$label" in
    fm-*) rest=${label#fm-} ;;
    *) rest=$label ;;
  esac
  printf 'fm-%s-%s' "$home" "$rest"
}

fm_backend_ryder_session_prefix() {
  printf 'fm-%s-' "$(fm_backend_ryder_home_label)"
}

# fm_backend_ryder_target_valid: a target must be a single session id - the
# host's own alphabet, no colon, and never empty. Structural only, no CLI call.
fm_backend_ryder_target_valid() {  # <target>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._@%+-]*) return 1 ;;
    .*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# fm_backend_ryder_target_ready: validate the target and, when the caller knows
# the owning firstmate task label, confirm the target is the id that label
# derives to. Deliberately a PURE check with no CLI round trip: unlike every
# other backend, a Ryder target cannot go stale (the id is derived, not
# assigned), so there is no id to refresh - only an identity to confirm. The
# liveness question is answered separately, by fm_backend_ryder_target_exists.
fm_backend_ryder_target_ready() {  # <target> [expected-label]
  local target=$1 expected_label=${2:-}
  fm_backend_ryder_target_valid "$target" || return 1
  [ -n "$expected_label" ] || return 0
  [ "$target" = "$(fm_backend_ryder_session_id "$expected_label")" ]
}

# fm_backend_ryder_state_raw: `ryder state <target> --json`, echoing the reply
# body either way and returning the CLI's own status. With --json the host
# prints failures as JSON on STDOUT too, so a failed call still returns a
# readable body carrying the typed error code - which is why the code is
# recovered from that body (fm_backend_ryder_error_code) rather than from a
# global. Callers read this through command substitution, and a subshell cannot
# publish a global back to its parent, so routing the code through stdout with
# the body is what keeps the two in one place and always in agreement.
fm_backend_ryder_state_raw() {  # <target> -> state json | error json
  local target=$1 out rc
  fm_backend_ryder_target_valid "$target" || return 1
  out=$(fm_backend_ryder_cli state "$target" --json 2>/dev/null)
  rc=$?
  printf '%s' "$out"
  return "$rc"
}

# fm_backend_ryder_error_code: the host's own typed error code from a failed
# reply body (no_such_session, session_dead, io, ...), or empty when the body
# carries none - which is itself meaningful, since it means the CLI failed
# before the host could answer. PROTOCOL.md's error table is stable within a
# protocol version and is what callers branch on, never the message text.
fm_backend_ryder_error_code() {  # <reply-body>
  printf '%s' "$1" | jq -r '.error.code // empty' 2>/dev/null
}

# fm_backend_ryder_state_field: one scalar from the state object, or empty on
# any failure. Never errors, mirroring every other adapter's field readers.
fm_backend_ryder_state_field() {  # <target> <jq-path> [expected-label]
  local target=$1 path=$2 expected_label=${3:-} raw
  fm_backend_ryder_target_ready "$target" "$expected_label" || return 0
  raw=$(fm_backend_ryder_state_raw "$target") || return 0
  printf '%s' "$raw" | jq -r "$path // empty" 2>/dev/null
}

# fm_backend_ryder_create_task: create the task's session in <cwd>, refusing an
# existing LIVE session for <label>. The host enforces the same thing itself
# with a typed `already_running` error (finding #4), but the check is made
# explicitly here so the refusal reads the same as every other adapter's and so
# a caller sees the firstmate-facing label rather than a derived id. Echoes the
# session id, which is the endpoint target, on success.
#
# The agent is a LOGIN SHELL, not the harness: firstmate's shared spawn steps
# run `treehouse get` in the endpoint and then launch the harness inside the
# resulting worktree, exactly as they do for tmux. <harness>, when the caller
# knows it, is recorded as the host's own `--harness` declaration so the Ryder
# app can name what the session is for; it is caller-declared metadata and
# never a liveness signal, which stays with the kernel-read foreground identity.
fm_backend_ryder_create_task() {  # <label> <cwd> [harness]
  local label=$1 cwd=$2 harness=${3:-} sid out shell_bin k
  sid=$(fm_backend_ryder_session_id "$label")
  fm_backend_ryder_target_valid "$sid" || {
    echo "error: task label '$label' derives an invalid ryder session id '$sid' (allowed: A-Za-z0-9._@%+-, at most 128 characters)" >&2
    return 1
  }
  if fm_backend_ryder_cli state "$sid" --json >/dev/null 2>&1; then
    echo "error: ryder session '$sid' already exists for '$label'" >&2
    return 1
  fi
  shell_bin=$FM_BACKEND_RYDER_SHELL
  set -- create --id "$sid" --label "$sid" --cwd "$cwd"
  [ -z "$harness" ] || set -- "$@" --harness "$harness"
  for k in $FM_BACKEND_RYDER_ENV_REMOVE; do
    set -- "$@" --env-remove "$k"
  done
  # `--json` and every other ryder flag must precede the `--` separator:
  # everything after it is the agent's argv and reaches it byte for byte.
  set -- "$@" --json -- "$shell_bin" -l
  out=$(fm_backend_ryder_cli "$@" 2>&1) || {
    echo "error: ryder create failed for '$label' ($sid): $out" >&2
    return 1
  }
  printf '%s' "$sid"
}

# fm_backend_ryder_capture: bounded plain-text session capture. A direct
# drop-in for fm_backend_tmux_capture (finding #2): <lines> is scrollback ABOVE
# the viewport, matching `tmux capture-pane -p -S -N`, and the reply is the
# whole viewport plus that history. Deliberately NOT trimmed with `tail` the
# way herdr's and cmux's wrappers trim theirs - those work around their own
# CLIs returning less than asked for, a bug Ryder does not have, and trimming
# here would silently give callers LESS than the tmux path gives them.
fm_backend_ryder_capture() {  # <target> <lines> [expected-label]
  fm_backend_ryder_target_ready "$1" "${3:-}" || return 1
  local lines=${2:-200} raw
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  raw=$(fm_backend_ryder_cli snapshot "$1" --lines "$lines" --json 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -er '.text // empty' 2>/dev/null
}

# fm_backend_ryder_send_literal: send TEXT as literal, UNSUBMITTED input - the
# caller sends Enter separately. `write --literal` writes raw bytes with no
# newline, and a successful reply means the bytes reached the pty (the host
# uses its own ping barrier to promise that), never that the agent read them.
fm_backend_ryder_send_literal() {  # <target> <text> [expected-label]
  fm_backend_ryder_target_ready "$1" "${3:-}" || return 1
  fm_backend_ryder_cli write "$1" --literal "$2" >/dev/null 2>&1
}

# fm_backend_ryder_normalize_key: map firstmate's key vocabulary onto ryder's
# `key` names. Verified live: Enter, Escape, enter and C-c are all accepted
# directly and key names are case- and separator-insensitive, so this is a thin
# guard rather than a translation table. It stays because firstmate's shared
# vocabulary is what must keep working, and an unknown name is a typed usage
# error (exit 2) rather than a silent no-op.
fm_backend_ryder_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'Enter' ;;
    Escape|escape|Esc|esc) printf 'Escape' ;;
    C-c|c-c|ctrl+c|Ctrl+c|Ctrl+C|ctrl-c) printf 'C-c' ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_ryder_send_key() {  # <target> <key> [expected-label]
  fm_backend_ryder_target_ready "$1" "${3:-}" || return 1
  local key
  key=$(fm_backend_ryder_normalize_key "$2")
  fm_backend_ryder_cli key "$1" "$key" >/dev/null 2>&1
}

# fm_backend_ryder_send_text_line: send one line of TEXT then submit, with no
# composer verification - used for the fixed spawn-time commands that the tmux
# path sends the same way. `write --line` is text plus Enter in one call, so
# nothing can interleave between the two halves.
fm_backend_ryder_send_text_line() {  # <target> <text> [expected-label]
  fm_backend_ryder_target_ready "$1" "${3:-}" || return 1
  fm_backend_ryder_cli write "$1" --line "$2" >/dev/null 2>&1
}

# fm_backend_ryder_current_path: the live foreground process's working
# directory, read by the host from the kernel. Verified (finding #1) to follow
# a `cd` immediately, so unlike zellij and cmux this needs NO active
# pwd-marker probe - it is a passive read, exactly like tmux's
# #{pane_current_path}. Empty on any error.
fm_backend_ryder_current_path() {  # <target> [expected-label]
  fm_backend_ryder_state_field "$1" '.cwd' "${2:-}"
}

# fm_backend_ryder_current_command: <target>'s live foreground process name -
# the host's own `fg_comm`, resolved from `tcgetpgrp` on the pty master rather
# than reconciled from two sources. Empty on any error.
fm_backend_ryder_current_command() {  # <target> [expected-label]
  fm_backend_ryder_state_field "$1" '.fg_comm' "${2:-}"
}

# --- composer classification -------------------------------------------------
#
# fm_backend_ryder_composer_state: classify the composer's own row as
# empty|pending|unknown from an ANSI snapshot.
# docs/ryder-backend.md "Capture and composer classification" owns why this
# backend reads both the style channel and the cursor position, and what that
# buys over every other adapter's classifier.
#
# Two signals decide WHICH row is the composer, in this order of authority:
#   1. The CURSOR ROW, when it carries a composer shape - the cursor is where
#      typing lands, so a shape under it is the live input row by construction.
#      Its index in the reply's text is `.scrollback + .cursor_line`, NOT
#      `.cursor_line` (finding #3), and `.scrollback` must come from the reply.
#   2. Otherwise the BOTTOM-MOST structural match, herdr's proven approach, so
#      a shape earlier in the capture (a decorative banner, a stale popup) can
#      never outrank the real bottom-anchored composer.
# With no match at all the verdict is `unknown`, the safe verdict: callers that
# can overwrite input require an exact `empty` before acting.
#
# Two shapes are recognized, both from herdr's verified vocabulary: `bordered`,
# whose trimmed content starts and ends with the same border glyph, and `bare`,
# whose trimmed content starts with a verified AGENT prompt glyph and has no
# closing border. `bare` is deliberately narrower than the bordered content
# rule so a no-agent SHELL prompt (>, $, %, #) falls through to `unknown`
# rather than reading as an empty, ready-to-inject agent composer - the
# fleet-wide safety rule bin/fm-composer-lib.sh exists to keep from drifting.
#
# The verdict itself is the shared owner's: the RAW styled row goes to
# fm_composer_strip_ghost, and the trimmed result to
# fm_composer_classify_content.
#
# The capture window is the viewport alone (`--lines 0`): the composer is
# always on screen, the viewport is bounded, and asking for no scrollback keeps
# the cursor offset arithmetic trivially correct.
FM_BACKEND_RYDER_COMPOSER_SCROLLBACK=${FM_BACKEND_RYDER_COMPOSER_SCROLLBACK:-0}
# Known ghost/placeholder composer text that reads as empty. Extend this when
# another ryder-verified harness needs its own idle placeholder recognized.
FM_BACKEND_RYDER_IDLE_RE=${FM_BACKEND_RYDER_IDLE_RE:-'^Type a message\.\.\.$'}
# fm_backend_ryder_row_shape: bordered|bare|none for one PLAIN, trimmed row.
#
# Both shapes are matched as LITERAL byte sequences by bash's own pattern
# matching, never by a regex bracket expression. Under the C/POSIX locale the
# fleet runs in, a bracket expression matches individual BYTES, so a bracketed
# pair of multibyte glyphs decomposes into its shared leading byte and
# spuriously matches any glyph in that range - including box-drawing corners,
# which would misread a composer box's bottom border as a bare prompt. Literal
# patterns stay correct regardless of locale, and cost no subprocess.
fm_backend_ryder_row_shape() {  # <plain-trimmed-row> -> bordered|bare|none
  case "${1:-}" in
    '') printf 'none' ;;
    '│'*'│'|'┃'*'┃'|'|'*'|') printf 'bordered' ;;
    '❯'*|'›'*) printf 'bare' ;;
    *) printf 'none' ;;
  esac
}

fm_backend_ryder_composer_state() {  # <target> [expected-label] -> empty|pending|unknown
  local target=$1 expected_label=${2:-} raw text plain_text cursor_idx row=0
  local plain trimmed shape match_raw
  local match_idx=-1 match_shape="" cursor_idx_match=-1 cursor_shape="" bordered=0 stripped
  fm_backend_ryder_target_ready "$target" "$expected_label" || { printf 'unknown'; return 0; }
  raw=$(fm_backend_ryder_cli snapshot "$target" \
    --lines "$FM_BACKEND_RYDER_COMPOSER_SCROLLBACK" --format ansi --json 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  text=$(printf '%s' "$raw" | jq -er '.text // empty' 2>/dev/null) || { printf 'unknown'; return 0; }
  # Finding #3: the cursor's index in .text is .scrollback + .cursor_line,
  # because cursor_line is viewport-relative while .text may carry history
  # above the viewport. Reading .scrollback from the REPLY (not from what was
  # requested) is what keeps this correct when less history was available.
  cursor_idx=$(printf '%s' "$raw" | jq -r '((.scrollback // 0) + (.cursor_line // 0))' 2>/dev/null)
  case "$cursor_idx" in ''|*[!0-9]*) cursor_idx=-1 ;; esac
  # Strip the whole capture ONCE and scan the plain copy for structure, keeping
  # only the matching row's INDEX. The raw styled bytes of that one row are
  # pulled out afterwards, so a viewport-sized scan costs two subprocesses
  # rather than two per row - this runs in the submit retry loop and on every
  # away-mode injection check.
  plain_text=$(printf '%s\n' "$text" | fm_composer_strip_ansi)
  while IFS= read -r plain; do
    trimmed="${plain#"${plain%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    shape=$(fm_backend_ryder_row_shape "$trimmed")
    if [ "$shape" != none ]; then
      match_idx=$row
      match_shape=$shape
      if [ "$row" = "$cursor_idx" ]; then
        cursor_idx_match=$row
        cursor_shape=$shape
      fi
    fi
    row=$((row + 1))
  done <<EOF
$plain_text
EOF
  # The cursor row wins when it is itself a composer: that is where typing
  # lands, so it is the live input row by construction. Otherwise fall back to
  # the bottom-most structural match.
  if [ -n "$cursor_shape" ]; then
    match_idx=$cursor_idx_match
    match_shape=$cursor_shape
  fi
  [ -n "$match_shape" ] || { printf 'unknown'; return 0; }
  match_raw=$(printf '%s\n' "$text" | sed -n "$((match_idx + 1))p")
  stripped=$(printf '%s\n' "$match_raw" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  if [ "$match_shape" = bordered ]; then
    bordered=1
    stripped=${stripped//│/}
    stripped=${stripped//┃/}
    stripped=${stripped//|/}
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
  fi
  # The bare shape only ever starts with an AGENT glyph, so a bare shell prompt
  # never reaches the shared classifier as a bordered container - it has no
  # shape at all and already returned 'unknown' above.
  fm_composer_classify_content "$bordered" "$stripped" "$FM_BACKEND_RYDER_IDLE_RE"
}

# fm_backend_ryder_send_text_submit: type <text> into <target> once (raw,
# unsubmitted), then submit with a named Enter, retried (Enter ONLY, never
# retyped, because a swallowed Enter leaves the text in the composer and
# retyping would duplicate it) until the composer's own row reads empty.
#
# Verifying the composer row rather than diffing the screen is what makes a
# slash-command popup safe: the first Enter on an open popup is a SELECTION
# that closes the popup and can fill an argument hint into the composer, which
# a raw diff misreads as "submitted" while a composer read correctly still says
# pending, so the retry loop sends the second Enter that actually submits.
# Echoes empty|pending|unknown|send-failed, a subset of the proof-carrying
# submit vocabulary; callers require exact `empty` for confirmed delivery.
fm_backend_ryder_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected_label=${6:-} i=0 state
  fm_backend_ryder_target_ready "$target" "$expected_label" || { printf 'unknown'; return 0; }
  fm_backend_ryder_send_literal "$target" "$text" "$expected_label" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    fm_backend_ryder_send_key "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    state=$(fm_backend_ryder_composer_state "$target" "$expected_label")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

# --- liveness ----------------------------------------------------------------

# fm_backend_ryder_target_exists: cheap, READ-ONLY existence probe. Connecting
# to the session's socket is the whole check - the host serves one socket per
# session and starts nothing on connect, so this satisfies the contract's
# never-start-anything requirement structurally rather than by avoiding a
# side-effectful call the way the herdr adapter must. A session in its
# post-exit linger window still answers, and that is correct here: the endpoint
# genuinely still exists, and whether an AGENT is in it is
# fm_backend_ryder_agent_state's question, not this one.
fm_backend_ryder_target_exists() {  # <target> [expected-label]
  fm_backend_ryder_target_ready "$1" "${2:-}" || return 1
  fm_backend_ryder_cli state "$1" --json >/dev/null 2>&1
}

# fm_backend_ryder_foreground_names: every process name and argv[0] in
# <target>'s foreground process group, one value per line, empty on any
# failure. The host names the group and the tty authoritatively (`fg_pgrp` from
# tcgetpgrp on the pty master, `tty` from the kernel), so this filters `ps` on
# the group id itself rather than reconciling a pane's tpgid the way the tmux
# adapter has to.
#
# Scanning the whole group rather than trusting the leader alone is what keeps
# a multi-process launcher attributable: the Pi launcher path runs a wrapper
# and an engine in one group, so reading only the group leader would miss the
# harness in one of the two arrangements.
fm_backend_ryder_foreground_names() {  # <tty> <fg_pgrp>
  local tty=$1 pgrp=$2 pid pgid comm args argv0
  [ -n "$tty" ] && [ -n "$pgrp" ] || return 0
  case "$pgrp" in ''|*[!0-9]*) return 0 ;; esac
  LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,comm= 2>/dev/null \
    | while read -r pid pgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$pgrp" ] || continue
        printf '%s\n' "$comm"
        args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
        args=${args#"${args%%[![:space:]]*}"}
        argv0=${args%%[[:space:]]*}
        [ -n "$argv0" ] && printf '%s\n' "$argv0"
      done
}

# fm_backend_ryder_foreground_class: what is holding <state-json>'s terminal
# right now - agent|shell|other|unreadable. The ONE place the foreground
# identity is decided, so the liveness verdict and the busy verdict below can
# never disagree about the same screen.
#
# Two sources feed it, and either naming a harness is enough for `agent`
# because a false negative is the costly direction: the whole foreground
# process group (which is what keeps a multi-process launcher attributable),
# and the host's own fg_comm/fg_argv0 (which the agent cannot rewrite, and
# which still answers when `ps` cannot). `other` wins over `shell` when both
# appear, since a group containing a real command is not an idle shell.
fm_backend_ryder_foreground_class() {  # <state-json> -> agent|shell|other|unreadable
  local raw=$1 tty pgrp names name seen=0 other_seen=0
  tty=$(printf '%s' "$raw" | jq -r '.tty // empty' 2>/dev/null)
  pgrp=$(printf '%s' "$raw" | jq -r '.fg_pgrp // empty' 2>/dev/null)
  names=$(fm_backend_ryder_foreground_names "$tty" "$pgrp")
  names="$names
$(printf '%s' "$raw" | jq -r '.fg_argv0 // empty' 2>/dev/null)
$(printf '%s' "$raw" | jq -r '.fg_comm // empty' 2>/dev/null)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    seen=1
    case "$(fm_process_classify_name "$name" "$name")" in
      agent) printf 'agent'; return 0 ;;
      other) other_seen=1 ;;
    esac
  done <<EOF
$names
EOF
  # Every classified name is agent, shell, or other, and agent returned above,
  # so "seen something, none of it `other`" is exactly "all shells".
  [ "$seen" -eq 1 ] || { printf 'unreadable'; return 0; }
  if [ "$other_seen" -eq 1 ]; then
    printf 'other'
  else
    printf 'shell'
  fi
}

# fm_backend_ryder_agent_state: recovery-grade harness-agent state for one
# recorded target. bin/fm-backend.sh's fm_backend_agent_state owns the shared
# state vocabulary and docs/ryder-backend.md "Agent liveness" owns the mapping
# table and its empirical basis; every arm below was verified live.
#
# The one decision worth stating at the code: an unattributable foreground
# stays `ambiguous` and is never folded into `dead`. Only `dead` and `missing`
# license recovery, and firstmate runs the harness inside a login shell, so the
# foreground can legitimately be a third process that is neither - a build, a
# pager, a git subcommand. Calling that `dead` would license spawning a
# duplicate agent onto a live worktree. Withholding recovery costs a
# supervision cycle; a duplicate agent costs the worktree.
fm_backend_ryder_agent_state() {  # <target>
  local target=$1 raw alive
  fm_backend_ryder_target_valid "$target" || { printf 'unreadable'; return 0; }
  if ! raw=$(fm_backend_ryder_state_raw "$target"); then
    case "$(fm_backend_ryder_error_code "$raw")" in
      no_such_session|session_dead) printf 'missing' ;;
      *) printf 'unreadable' ;;
    esac
    return 0
  fi
  alive=$(printf '%s' "$raw" | jq -r '.alive // false' 2>/dev/null)
  [ "$alive" = true ] || { printf 'dead'; return 0; }
  case "$(fm_backend_ryder_foreground_class "$raw")" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    other) printf 'ambiguous' ;;
    *) printf 'unreadable' ;;
  esac
}

# Backward-compatible three-state view, mirroring every other adapter's.
fm_backend_ryder_agent_alive() {  # <target>
  case "$(fm_backend_ryder_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_ryder_busy_state: semantic busy/unknown, honest about exactly what
# foreground process identity can and cannot prove.
#
# `busy` is reported on positive proof only: a concrete command that is neither
# a harness nor a shell owns the terminal, so something is genuinely running -
# a build, a test run, `treehouse get` during a spawn. That is a real verdict
# from kernel state, and it is more than the tmux adapter offers.
#
# `idle` is NEVER reported. A harness sitting at its prompt and a harness
# mid-turn are the SAME process in the SAME foreground group, so process
# identity cannot separate them, and this was verified the hard way: an earlier
# revision inferred busy from "the foreground group is not the agent's own
# pid", which looked right until a real Claude Code session proved it reports
# busy forever - firstmate runs the harness as a foreground child of the
# session's login shell, so that condition holds for the entire life of every
# task. Claiming idle, or busy, from that would be a guess. `unknown` is the
# honest answer and callers already own its fallback: fm-watch.sh treats it as
# the cue for harness-scoped pane-tail detection, which is the signal that CAN
# answer this question.
fm_backend_ryder_busy_state() {  # <target> -> busy|unknown
  local target=$1 raw alive
  fm_backend_ryder_target_valid "$target" || { printf 'unknown'; return 0; }
  raw=$(fm_backend_ryder_state_raw "$target") || { printf 'unknown'; return 0; }
  alive=$(printf '%s' "$raw" | jq -r '.alive // false' 2>/dev/null)
  [ "$alive" = true ] || { printf 'unknown'; return 0; }
  case "$(fm_backend_ryder_foreground_class "$raw")" in
    other) printf 'busy' ;;
    *) printf 'unknown' ;;
  esac
}

# fm_backend_ryder_kill: end the task's session, best-effort (mirroring every
# other backend's kill contract, where an already-gone target is not an error).
# An empty or malformed target returns nonzero BEFORE invoking ryder, so a
# missing id can never be handed to the CLI at all.
#
# `kill` SIGTERMs the agent's process group, SIGKILLs it after the grace, and
# retires the host. The session directory and its log stay behind until the
# next sweep archives them - archived, never deleted, which is what makes a
# post-mortem possible and is why teardown does not try to remove it.
fm_backend_ryder_kill() {  # <target> [unused] [expected-label]
  local target=${1:-} expected_label=${3:-}
  fm_backend_ryder_target_ready "$target" "$expected_label" || return 1
  fm_backend_ryder_cli kill "$target" >/dev/null 2>&1 || true
  return 0
}

# fm_backend_ryder_list_live: recovery/orphan discovery. Lists every LIVE
# session whose id is scoped to this firstmate home, as
# "<session-id>\tfm-<task-id>" - the same shape as every other adapter's.
#
# Discovery is by the derived, home-scoped id rather than by a stored one,
# matching herdr's and cmux's recovery posture. Here that is not a workaround
# for ids that do not survive a restart (Ryder's do - the sessions directory IS
# the registry and outlives everything) but the same property stated once: the
# id is a function of the task and the home, so enumerating live sessions and
# filtering by this home's prefix is exactly the set of this home's endpoints.
# Read-only: `list` sweeps stale directories but never touches a live session,
# and an unreadable registry simply lists nothing.
fm_backend_ryder_list_live() {
  local raw prefix sid plain
  prefix=$(fm_backend_ryder_session_prefix)
  raw=$(fm_backend_ryder_cli list --json 2>/dev/null) || return 0
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    plain=${sid#"$prefix"}
    [ -n "$plain" ] && [ "$plain" != "$sid" ] || continue
    printf '%s\tfm-%s\n' "$sid" "$plain"
  done < <(printf '%s' "$raw" | jq -r --arg prefix "$prefix" \
    '.sessions[]? | select(.alive) | select(.id | startswith($prefix)) | .id' 2>/dev/null)
}
