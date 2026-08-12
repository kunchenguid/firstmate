#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE tmux source for delivery-busy detection, composer capture primitives,
# and verified submit.
# Both the away-mode daemon and bin/fm-send.sh reach these primitives through
# backend dispatch, while bin/fm-composer-lib.sh owns the shared verdict.
#
# Composer shapes and verdicts are owned by bin/fm-composer-lib.sh.
# This file owns only tmux's styled capture, cursor and Pi identity primitives,
# delivery busy read, and submit conversions that consume the shared verdict.
# Styled captures remain internal; fm-peek and every human-facing capture stay
# plain.
#
# OpenCode's busy-queued Enter conversion accepts only structurally proven
# pending text after retries, while the separate turn-started conversion accepts
# an unknown post-Enter composer only after this submit observed an idle baseline
# become busy.
# Herdr's OpenCode busy-queue limitation remains documented in
# docs/herdr-backend.md.
#
# FM_COMPOSER_IDLE_RE is interpreted by the shared classifier with its structural
# and styling safety gates.
# FM_BUSY_REGEX overrides the rendered delivery-busy matching used here.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.sh's
# semantic contract. The matching below serves only delivery guards: the submit
# acknowledgement and the away-mode supervisor-pane busy guard. Both ask about
# the pane receiving input, not the state of a recorded worker task. Matching
# stays harness-scoped so one harness's output cannot make another read busy.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer classification is NOT owned here: every shape, glyph, border
# family, geometry rule, and verdict decision lives in the shared
# bin/fm-composer-lib.sh (fm_composer_classify_screen), sourced below and
# reused by every backend adapter so the decision cannot drift. This file
# keeps only tmux's genuine capture-side primitives - the styled pane
# capture, the #{cursor_y} cursor read, the pi foreground-process identity
# probe, and the capability descriptor - plus the busy detection and submit
# cores that consume the shared verdict.

# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-composer-lib.sh"

# --- fleet socket ------------------------------------------------------------
#
# Every fleet-side tmux call goes through fm_tmux, which addresses the fleet's
# tmux server EXPLICITLY with `-S <socket>` instead of letting tmux pick a server
# from the caller's ambient environment.
#
# Why (incident 2026-07-28 00:47, and 2026-07-27 20:16 before it): the whole
# fleet - primary, secondmate, every crewmate - shared ONE tmux server on the
# default socket, and every pane inherited $TMUX, so a bare `tmux` typed inside
# any crew pane operated on the fleet's own server. A crewmate experimenting
# with tmux behavior ran one command in its pane and the server exited cleanly
# (atop process accounting: tmux pid 588148, exit code 0, five agents SIGHUP'd
# out with it). The fleet's lifeline was reachable from every pane.
#
# The isolation has two halves, and both are needed:
#   1. bin/fm-spawn.sh gives each pane a PRIVATE tmux namespace - it unsets $TMUX
#      and points TMUX_TMPDIR at a per-task sandbox dir - so a bare `tmux` (or
#      `tmux -L anything`) inside a pane resolves to that task's own throwaway
#      server. `tmux kill-server` there kills only the sandbox.
#   2. Because the pane no longer carries $TMUX, firstmate's OWN scripts can no
#      longer rely on the ambient server either. fm_tmux names the socket
#      explicitly, which is what lets a secondmate - a firstmate primary living
#      in a sandboxed pane - keep dispatching its crew onto the shared fleet
#      server (bin/fm-spawn.sh exports FM_TMUX_SOCKET into secondmate panes).
#
# Resolution order (fm_tmux_socket_resolve), highest first:
#   1. FM_TMUX_SOCKET - an explicit binding: a task's recorded socket
#      (fm_tmux_bind_meta), the value fm-spawn exports into a secondmate pane, or
#      an operator/test override.
#   2. $TMUX's socket path - the server this process is actually running in.
#      Ambient wins over any configured preference on purpose: the fleet must be
#      the server the captain has attached, so crew windows stay in one session
#      and one window list.
#   3. ${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default - tmux's own default socket, i.e.
#      exactly where a firstmate launched outside tmux put its fleet before this
#      change. `tmux attach` keeps working unchanged.
# A dedicated fleet socket is therefore an operator choice, not a code default:
# start the primary inside `tmux -L <name>` and rule 2 puts the whole fleet
# there, attached with `tmux -L <name> attach -t <home-basename>`.
#
# The fleet is always ONE tmux server: rules 2 and 3 keep crew windows in the
# same session and the same window list as the primary, so `tmux attach` shows
# the whole fleet exactly as it did before. Rule 1 exists to keep a reader
# pointed at the server a given endpoint is on, never to spread the fleet across
# servers.
FM_TMUX_SOCKET_BASENAME_DEFAULT=default

# fm_tmux_socket_dir: tmux's own socket directory for this user.
fm_tmux_socket_dir() {
  printf '%s/tmux-%s' "${TMUX_TMPDIR:-/tmp}" "$(id -u)"
}

# fm_tmux_socket_from_env: the socket path encoded in $TMUX ("<socket>,<pid>,<id>"),
# i.e. the server this process runs inside. Returns 1 when not inside tmux.
fm_tmux_socket_from_env() {
  local v=${TMUX:-}
  [ -n "$v" ] || return 1
  v=${v%%,*}
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# fm_tmux_implicit_socket: the socket a BARE `tmux` would use in this process -
# rules 2 and 3 above, without the explicit binding. This is what makes the
# default path byte-identical: fm_tmux only adds `-S` when the fleet socket is
# something other than what tmux would have picked anyway.
fm_tmux_implicit_socket() {
  local s
  if s=$(fm_tmux_socket_from_env); then
    printf '%s' "$s"
    return 0
  fi
  printf '%s/%s' "$(fm_tmux_socket_dir)" "$FM_TMUX_SOCKET_BASENAME_DEFAULT"
}

# fm_tmux_socket_resolve: print the fleet socket path per the order above.
fm_tmux_socket_resolve() {
  if [ -n "${FM_TMUX_SOCKET:-}" ]; then
    printf '%s' "$FM_TMUX_SOCKET"
    return 0
  fi
  fm_tmux_implicit_socket
}

# fm_tmux_socket: this home's FLEET socket, resolved once and then PINNED for the
# life of the process.
#
# Pinned deliberately. A per-task binding replaces the socket fm_tmux addresses
# (FM_TMUX_SOCKET), but it must never change what "the fleet socket" means:
# otherwise a loop over tasks would resolve the next task's absent
# `tmux_socket=` to the PREVIOUS task's server - the exact "read the wrong
# endpoint" failure this whole contract exists to prevent.
#
# Neither variable is exported: a child process resolves for itself, and a
# task-scoped binding must not leak into a sibling task's process. fm-spawn hands
# the value to a secondmate pane explicitly.
fm_tmux_socket() {
  [ -n "${_FM_TMUX_FLEET_SOCKET:-}" ] || _FM_TMUX_FLEET_SOCKET=$(fm_tmux_socket_resolve)
  printf '%s' "$_FM_TMUX_FLEET_SOCKET"
}

# fm_tmux_socket_of_meta: the socket a task's endpoint lives on. fm-spawn records
# `tmux_socket=` for every tmux task; an older meta has no such line and predates
# any socket move, so it resolves to the ambient fleet socket - byte-identical to
# what every reader did before this field existed. That is the compatibility
# contract: a pre-existing task keeps resolving to the server it was spawned on.
fm_tmux_socket_of_meta() {  # <meta-file>
  local meta=${1:-} v=
  if [ -n "$meta" ] && [ -f "$meta" ]; then
    v=$(grep '^tmux_socket=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  fi
  if [ -n "$v" ]; then
    printf '%s' "$v"
  else
    fm_tmux_socket
  fi
}

# fm_tmux_bind_meta: point every subsequent fm_tmux call in THIS process at the
# server <meta-file>'s endpoint lives on. Always assigns, so a loop over tasks
# cannot carry a previous task's socket into the next one.
fm_tmux_bind_meta() {  # <meta-file>
  # Pin the fleet socket before rebinding, so the fallback for a meta with no
  # recorded socket stays the fleet's server rather than the last bound task's.
  fm_tmux_socket >/dev/null
  FM_TMUX_SOCKET=$(fm_tmux_socket_of_meta "${1:-}")
}

# fm_tmux: run tmux against the fleet socket.
#
# `-S <socket>` is added ONLY when the fleet socket differs from the one a bare
# `tmux` would already use in this process. In the primary's own pane the two are
# the same server, so the command line stays byte-identical to what every one of
# these call sites ran before - no argv change for anything that observes them.
# The flag appears exactly where it changes the outcome: a task bound to a socket
# other than the ambient one, and a sandboxed pane (no $TMUX, private
# TMUX_TMPDIR) that was handed the fleet socket explicitly.
#
# `kill-server` is refused outright. It is never a legitimate firstmate
# operation, and it is the one command that takes the whole fleet down, so no
# future edit to a fleet-side script can reach it by accident. A task's own
# sandbox server is torn down by path in bin/fm-teardown.sh, not through here.
fm_tmux() {
  case "${1:-}" in
    kill-server)
      echo "error: fm_tmux refuses kill-server (fleet socket $(fm_tmux_socket))" >&2
      return 1
      ;;
  esac
  [ -n "${FM_TMUX_SOCKET:-}" ] || FM_TMUX_SOCKET=$(fm_tmux_socket)
  [ -n "${_FM_TMUX_IMPLICIT_SOCKET:-}" ] || _FM_TMUX_IMPLICIT_SOCKET=$(fm_tmux_implicit_socket)
  if [ "$FM_TMUX_SOCKET" = "$_FM_TMUX_IMPLICIT_SOCKET" ]; then
    tmux "$@"
  else
    tmux -S "$FM_TMUX_SOCKET" "$@"
  fi
}

# Delivery-only rendered busy footers per harness. claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel".
# Claude's current spinner has a rotating glyph and word, but every active-turn
# line has an ellipsis followed by a parenthesized elapsed duration. Keep this
# signature separate from the shared default because that shape is not generic
# enough to classify arbitrary harness output safely.
# Kimi's anchored moon-phase spinner is separate because bare moon glyphs in
# ordinary output must not classify another harness as busy. Leading whitespace is
# OPTIONAL; whitespace on both sides of the separator is REQUIRED because every
# captured spinner row had it. A zero-whitespace form has NEVER been observed and
# is deliberately not matched. The line end is intentionally unanchored because
# rotating tip text follows and is not required to be present. The idle status
# bar's lowercase `thinking` label and independently rotating tip text are not
# busy signals on their own.
# The full moon-phase set remains locale- and emoji-font-sensitive because Kimi
# exposes no stable ASCII busy token.
# traex (TRAE CLI 2.0) is a codex fork and renders codex's exact `esc to
# interrupt` line, verified in both directions on a live pane (traex 0.200.13,
# 2026-07-17; see the harness-adapters skill). It needs its own entry because an
# unregistered harness is deliberately never classified busy below, and its
# `Working...` alternative uses a Unicode ellipsis that no ASCII pattern matches.
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'
FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT='esc to interrupt|…[[:space:]]+\([0-9]+[smh]'
FM_TMUX_CODEX_BUSY_REGEX_DEFAULT='esc to interrupt'
FM_TMUX_OPENCODE_BUSY_REGEX_DEFAULT='esc interrupt'
FM_TMUX_PI_BUSY_REGEX_DEFAULT='Working\.\.\.'
FM_TMUX_GROK_BUSY_REGEX_DEFAULT='Ctrl\+c:cancel'
FM_TMUX_KIMI_BUSY_REGEX_DEFAULT='^[[:space:]]*(🌑|🌒|🌓|🌔|🌕|🌖|🌗|🌘)[[:space:]]+·[[:space:]]+'
FM_TMUX_TRAEX_BUSY_REGEX_DEFAULT='esc to interrupt'

fm_busy_lines_match() {  # [harness]
  local harness=${1:-} lines regex
  IFS= read -r -d '' lines || true
  if [ -n "${FM_BUSY_REGEX:-}" ]; then
    regex=$FM_BUSY_REGEX
  else
    case "$harness" in
      claude) regex=$FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT ;;
      codex) regex=$FM_TMUX_CODEX_BUSY_REGEX_DEFAULT ;;
      opencode) regex=$FM_TMUX_OPENCODE_BUSY_REGEX_DEFAULT ;;
      pi|pi-signed) regex=$FM_TMUX_PI_BUSY_REGEX_DEFAULT ;;
      grok) regex=$FM_TMUX_GROK_BUSY_REGEX_DEFAULT ;;
      kimi) regex=$FM_TMUX_KIMI_BUSY_REGEX_DEFAULT ;;
      traex) regex=$FM_TMUX_TRAEX_BUSY_REGEX_DEFAULT ;;
      '') regex=$FM_TMUX_BUSY_REGEX_DEFAULT ;;
      *)
        # A supplied harness must never borrow another harness's signature.
        # Register its verified signature explicitly before classifying it busy.
        regex=
        ;;
    esac
  fi
  [ -n "$regex" ] && printf '%s' "$lines" | grep -qiE "$regex"
}

# Second busy signature: the SPINNER STATUS LINE.
#
# Why it exists (2026-07-13, verified live on claude 2.1.207): a busy claude
# crewmate no longer renders an interrupt hint at all. Its mid-turn footer is
#
#   ✳ Meandering… (5m 46s · ↓ 18.2k tokens)
#   ───────────────
#   ❯
#   ───────────────
#       Opus 4.8 (1M context)  ctx 15% (154k)  session 49% ...
#       session-id 8c284187-...
#     ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents
#
# so FM_TMUX_BUSY_REGEX_DEFAULT matches nothing, AND the spinner sits 7 lines
# from the bottom - outside the 6-line footer window the hint scan uses. A
# demonstrably busy crew therefore read as NOT busy everywhere the pane is the
# evidence: the daemon's wedge recheck (stale_window_is_busy) could not see that
# a crew had resumed, so it escalated "stale persisted Ns (possible wedge)" on a
# crew that was actively working, and fm-crew-state.sh's pane fallback reported
# no positive working evidence for it.
#
# The pattern is the SHAPE of that line - not the spinner glyph (locale-fragile)
# or the verb (claude randomises it: Meandering/Simmering/Puttering/...).
#
# Widened 2026-07-28 (task fm-send-busy-false-negative, claude 2.1.220): the
# original shape required a parenthesised elapsed counter FOLLOWED BY a token
# counter, and claude renders that only once it has started emitting output.
# Sampled every 3s across a live thinking phase, the status line instead reads
#
#   ✻ Whatchamacalliting… (2s · thinking with high effort)
#   ✢ Whatchamacalliting… (11s · still thinking with high effort)
#   · Crystallizing… (running stop hooks… 4/5 · 52s · ↓ 87 tokens)
#   · Metamorphosing… (0s · ↓ 4 tokens)          <- the only matched form
#
# so the old pattern matched 0 of 8 consecutive captures of a demonstrably busy
# pane, and claude renders no interrupt hint either: `fm_pane_is_busy` reported
# NOT busy for the whole thinking phase of every turn. That is why the
# busy-queued-Enter fallback in fm_tmux_submit_enter_core, which rescues
# opencode, could not rescue claude.
#
# The invariant across every observed form is the VERB'S ELLIPSIS immediately
# followed by a parenthesised status, which is also how claude renders a running
# tool's timer ("… (10s)") - both mean a turn is in flight. The original token
# form is kept as an alternation so a pane that only shows the counter still
# matches. The ellipsis anchor is what keeps this tight: displayed text
# truncated with `…` ends the line there, so it is never followed by `(`.
FM_TMUX_SPINNER_REGEX_DEFAULT='[[:alnum:]]…[[:space:]]*\(|\([0-9]+[hms][^)]*token'
# Footer window for the hint scan. Deliberately narrow (the TUI footer area) so
# busy-looking strings in DISPLAYED CONTENT cannot suppress stale detection.
FM_TMUX_BUSY_TAIL_DEFAULT=6
# Wider window for the spinner scan: claude's own footer now occupies 6 lines
# BELOW the spinner. Safe to widen because a spinner match is never trusted on
# its own - see fm_pane_is_busy's liveness rule.
FM_TMUX_SPINNER_TAIL_DEFAULT=12
# Seconds between the two captures that prove a spinner is LIVE.
FM_TMUX_BUSY_LIVENESS_SECS_DEFAULT=2

# 0 if <pane-text>'s last few non-blank lines carry a harness interrupt hint.
# Single-shot and self-sufficient: a hint is rendered only while a turn is in
# flight, so it is trusted without a liveness check, exactly as before.
fm_busy_hint_in_text() {  # <pane-text> [harness]
  printf '%s' "$1" | grep -v '^[[:space:]]*$' \
    | tail -"${FM_BUSY_TAIL_LINES:-$FM_TMUX_BUSY_TAIL_DEFAULT}" \
    | fm_busy_lines_match "${2:-}"
}

# 0 if <pane-text> shows a spinner status line. NOT proof of busy on its own: a
# wedged or dead harness leaves its last painted frame - spinner included - on
# screen forever, so trusting a single frame would mask exactly the wedges this
# fleet must catch. Callers pair it with a liveness check (fm_pane_is_busy) or
# with an outer staleness check that already proves the pane is changing (the
# watcher's pane-hash comparison).
fm_spinner_in_text() {  # <pane-text>
  printf '%s' "$1" | grep -v '^[[:space:]]*$' \
    | tail -"${FM_SPINNER_TAIL_LINES:-$FM_TMUX_SPINNER_TAIL_DEFAULT}" \
    | grep -qE "${FM_SPINNER_REGEX:-$FM_TMUX_SPINNER_REGEX_DEFAULT}"
}

# 0 if two captures of the same pane differ, i.e. the pane is actually repainting.
# This is what turns a spinner frame into evidence: a live spinner advances its
# elapsed-time counter every second, a frozen one does not.
fm_pane_text_advanced() {  # <text-t0> <text-t1>
  [ "$1" != "$2" ]
}

fm_is_login_shell_name() {  # <command-name>
  local name=${1##*/}
  name=${name#-}
  case "$name" in
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) return 0 ;;
    *) return 1 ;;
  esac
}

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# --- tmux composer capture and capability primitives ------------------------
#
# These four functions are the ONLY tmux-specific composer knowledge left:
# how to capture a styled screen, how to read the cursor row, how to probe a
# live pi agent, and the static capability facts. Every shape, glyph, border
# family, and verdict decision lives in the shared owner
# (bin/fm-composer-lib.sh, fm_composer_classify_screen), so a new harness
# shape is taught there once and never here.

# fm_tmux_composer_capture: the visible pane WITH ANSI styling. The styled
# capture is consumed internally by the classifier and is NEVER surfaced
# (fm-peek and every human/LLM-facing path stay plain).
fm_tmux_composer_capture() {  # <target>
  fm_tmux capture-pane -e -p -t "$1" -S 0 -E - 2>/dev/null
}

# fm_tmux_composer_cursor_row: the pane's cursor row, zero-based, relative to
# the visible pane - tmux's genuine primitive that no other backend has.
fm_tmux_composer_cursor_row() {  # <target>
  fm_tmux display-message -p -t "$1" '#{cursor_y}' 2>/dev/null
}

# fm_tmux_composer_caps: the tmux capability descriptor - static data, not
# logic (see the capability model in bin/fm-composer-lib.sh).
fm_tmux_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n'
}

# fm_tmux_composer_identity: the tmux agent-identity probe backing the
# separated (pi) composer shape, tmux's analogue of herdr's native
# `agent get`. It answers only for pi, from two live signals:
#   - identity: the pane tty's FOREGROUND process group (pgid = tpgid, the
#     same scoping as fm_backend_tmux_foreground_comms) contains a pi-family
#     process (pi, pi-signed, pi-launcher - docs/verification/
#     runtime-backends.md "Agent liveness name sources"), falling back to
#     tmux's own foreground-derived #{pane_current_command}. A pane whose
#     agent died to a shell has no pi foreground process and gets NO identity,
#     which is exactly what keeps the strict blank-row rule honest: a blank
#     row between two stale rules stays unknown.
#   - status: pi's verified busy footer via fm_pane_is_busy, mapped onto the
#     idle/working vocabulary herdr's probe reports natively.
# Prints "pi<TAB>idle" or "pi<TAB>working"; exits 1 when the pane is not a
# live pi.
fm_tmux_composer_identity() {  # <target>
  local target=$1 tty pgid tpgid comm found=0 status
  tty=$(fm_tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || tty=
  case "$tty" in
    /dev/*)
      while read -r _ pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        case "${comm##*/}" in
          pi|pi-signed|pi-launcher|Pi) found=1 ;;
        esac
      done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
      ;;
  esac
  if [ "$found" -ne 1 ]; then
    comm=$(fm_tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || comm=
    case "${comm##*/}" in
      pi|pi-signed|pi-launcher) found=1 ;;
    esac
  fi
  [ "$found" -eq 1 ] || return 1
  status=$(fm_pane_busy_state "$target" pi)
  case "$status" in
    busy) printf 'pi\tworking' ;;
    idle) printf 'pi\tidle' ;;
    *) return 1 ;;
  esac
}

# fm_tmux_composer_state: the tmux composer verdict - a thin adapter over the
# shared screen classifier. The verdict contract (empty | pending |
# pending-unproven | unknown, positive proof required for empty, unrecognized
# future verdicts failing safe) is owned by bin/fm-composer-lib.sh. Identity
# is fetched lazily, only when the classifier reports the verdict depends on
# it (a pi separator pair under the cursor), so the common read never pays
# for the process probe.
fm_tmux_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local target=$1 cy pane verdict identity rows
  cy=$(fm_tmux_composer_cursor_row "$target") || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_tmux_composer_capture "$target") || { printf 'unknown'; return 0; }
  # A capture can race a terminal resize and contain fewer rows than the cursor
  # coordinate read immediately before it.
  # Clamp only that transient out-of-range coordinate to the captured last row;
  # ordinary full-pane captures keep their exact cursor position.
  rows=$(printf '%s\n' "$pane" | awk 'END { print NR }')
  [ "$rows" -gt 0 ] || { printf 'unknown'; return 0; }
  [ "$cy" -lt "$rows" ] || cy=$((rows - 1))
  verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_tmux_composer_identity "$target") || [ -z "$identity" ]; then
      identity=probe-absent
    fi
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy" "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_pane_input_pending: 0 when the composer is not proven empty, so pending
# text, ambiguous structure, unreadable state, and future verdicts all defer.
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" != empty ]
}

# fm_pane_is_busy: 0 if the pane shows an agent mid-turn. Scans a 40-line tail
# like fm-watch.sh, and accepts EITHER busy signature:
#   1. a harness interrupt hint in the footer window (single-shot, as before), or
#   2. a spinner status line that is DEMONSTRABLY LIVE - it is still there, and
#      the pane repainted, across two captures FM_BUSY_LIVENESS_SECS apart.
# The liveness requirement is what keeps this from weakening wedge detection: a
# wedged harness's last frame keeps whatever spinner it died on, but it stops
# repainting, so it reads not-busy and still escalates. The hint window stays
# narrow for the same reason - claude renders its spinner ABOVE that window, so
# the liveness-checked path is the only one that can trust it.
# <harness> scopes the hint to that harness's own verified signature; an
# unregistered harness matches nothing rather than borrowing another's.
fm_pane_busy_state() {  # <target> [harness] -> busy|idle|unknown
  local win=$1 harness=${2:-} tail40
  tail40=$(fm_tmux capture-pane -p -t "$win" -S -40 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  printf '%s' "$tail40" | grep -qv '^[[:space:]]*$' \
    || { printf 'unknown'; return 0; }
  if fm_busy_hint_in_text "$tail40" "$harness"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

fm_pane_is_busy() {  # <target> [harness]
  local win=$1 harness=${2:-} t0 t1
  t0=$(fm_tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  fm_busy_hint_in_text "$t0" "$harness" && return 0
  fm_spinner_in_text "$t0" || return 1
  sleep "${FM_BUSY_LIVENESS_SECS:-$FM_TMUX_BUSY_LIVENESS_SECS_DEFAULT}"
  t1=$(fm_tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  fm_spinner_in_text "$t1" || return 1
  fm_pane_text_advanced "$t0" "$t1"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final proof-carrying verdict on stdout so callers can require
# exact `empty` before treating submission as confirmed.
# Busy-queued Enter (opencode 1.18.4): the harness accepts Enter while mid-turn
# and queues it for after the current turn, but keeps the typed text visible in
# the composer. Once the Enter-retry budget is spent and a structurally proven
# composer still reads "pending", the submit core falls back to
# `fm_pane_is_busy`: a busy pane means the Enter was accepted and queued (report
# `empty` so the caller does not re-send), while an idle pane keeps `pending` as
# a genuine swallow. Pending-unproven receives the same Enter retry budget but
# never reaches this exception.
# Turn-started confirmation (the strict blank-row posture's counterpart): a
# harness whose mid-turn screen the classifier cannot positively identify (pi
# replaces its separated composer while working) reads `unknown` right after a
# successful submit. When and only when the pane was IDLE before the text was
# typed, an idle-to-busy transition across our Enter is proof the harness
# accepted the submission - the same semantic signal herdr's native
# agent-state confirmation uses, read from the pane's verified busy footer.
# The busy read is polled across the remaining retry budget because the turn
# takes a beat to render. Without the baseline (a direct
# fm_tmux_submit_enter_core caller, or a pane already busy before typing) an
# `unknown` verdict is preserved untouched: busy conversion without the
# transition evidence could mark an undelivered message delivered.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep> [baseline-idle]
  local target=$1 retries=$2 sleep_s=$3 baseline_idle=${4:-} i=0 j state
  while :; do
    fm_tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    case "$state" in
      pending|pending-unproven) ;;
      unknown)
        if [ "$baseline_idle" = 1 ]; then
          j=0
          while [ "$j" -lt "$retries" ]; do
            if fm_pane_is_busy "$target"; then
              printf 'empty'
              return 0
            fi
            j=$((j + 1))
            [ "$j" -ge "$retries" ] || sleep "$sleep_s"
          done
        fi
        printf 'unknown'
        return 0
        ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  if [ "$state" != pending ]; then
    printf '%s' "$state"
    return 0
  fi
  # Retries exhausted, composer still shows proven pending.
  # If the pane is busy (agent mid-turn), the harness accepted the Enter
  # and queued the message for processing when the current turn ends.
  # Treat it as submitted so the caller does not re-send.
  # On an idle pane, keep reporting pending - a genuine swallow.
  if fm_pane_is_busy "$target"; then
    printf 'empty'
  else
    printf 'pending'
  fi
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 baseline_idle='' baseline_state
  # The turn-started baseline must predate our own typing: a pane already
  # busy before the text lands can turn "busy" for reasons unrelated to our
  # Enter, so only a clean idle-to-busy transition may confirm a submit.
  baseline_state=$(fm_pane_busy_state "$target")
  [ "$baseline_state" = idle ] && baseline_idle=1
  fm_tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$baseline_idle"
}
