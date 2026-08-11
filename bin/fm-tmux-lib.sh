#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by both the away-mode
# daemon (bin/fm-supervise-daemon.sh) and bin/fm-send.sh so the composer/submit
# logic cannot drift between the two.
#
# Why this exists (incident afk-invx-i5): the daemon's old composer check only
# recognized a BARE prompt glyph ("> ") as an empty composer. claude draws its
# input box with box-drawing borders ("│ > … │"), so every idle claude pane read
# as "pending input" and the away-mode daemon deferred 100% of escalations for
# 9.5 hours with no escape. The detector below strips the box borders before
# deciding, so a bordered-but-empty composer is correctly seen as empty. The same
# corrected detector backs the submit acknowledgement (a submit "landed" iff the
# composer is empty afterward), fixing the parallel false "Enter swallowed".
#
# Ghost text (incident composer-robust): claude renders a predicted-next-prompt
# "suggestion" as dim/faint text inside an otherwise-empty composer. A plain
# capture cannot tell it apart from text a human typed, so the old reader saw an
# idle pane as holding pending input and the daemon deferred injection / firstmate
# misjudged the pane. The composer reader now captures the visible pane WITH ANSI
# styling (tmux capture-pane -e), locates a bordered composer structurally, and
# extracts the real typed content from every row with the shared, fleet-wide
# fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops every
# de-emphasised run - dim/faint (SGR 2) AND a dark/muted truecolor foreground -
# so ghost/placeholder text never counts as real input. The styled capture is
# consumed internally and parsed into a boolean here; it is NEVER surfaced
# (fm-peek and every human/LLM-facing path stay plain). This is harness-generic:
# any harness that de-emphasises placeholder/ghost text
# benefits, and the herdr adapter routes through the same owner (task
# afk-herdr-false-pending), so the two backends cannot drift.
#
# Busy-queued Enter (opencode 1.18.4, on the tmux backend only for now): when
# the agent is mid-turn, opencode accepts Enter as a "send when the turn ends"
# keystroke but does NOT clear the composer until then, so the composer keeps
# showing the typed text the whole time. The plain "empty iff composer cleared"
# acknowledgement above false-positives on a swallowed Enter for every steer
# sent to a busy opencode pane, and `fm-send` exits non-zero on a normal
# captain instruction. The submit core now falls back to `fm_pane_is_busy` once
# the Enter-retry budget is spent: a busy pane means the harness accepted and
# queued the Enter (report `empty` so the caller does not re-send), while an
# idle pane keeps the `pending` verdict (a genuine swallow). The herdr backend
# observes the same opencode behavior but needs a separate fix; it is recorded
# as a known gap in `docs/herdr-backend.md` rather than patched here, so the
# tmux adapter does not paper over a herdr-specific shape.
#
# Overrides: FM_COMPOSER_IDLE_RE matches an empty composer after ghost and
# structural border stripping. FM_BUSY_REGEX overrides the rendered busy-footer
# matching used here.
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
# Composer-content classification (empty|pending|unknown, and the fleet-wide
# rule that a BARE shell prompt glyph is a dead shell, not an empty agent
# composer) is NOT owned here: it is the shared bin/fm-composer-lib.sh, sourced
# below and reused by every backend adapter so the decision cannot drift.

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

# fm_tmux_composer_row_state: classify one raw styled candidate row.
# A structural caller forces bordered=1; the compatibility fallback passes 0
# and may recognize a busy footer.
fm_tmux_composer_row_state() {  # <raw-row> [bordered] [allow-busy] -> empty|pending|unknown
  local raw=$1 bordered=${2:-0} allow_busy=${3:-1} plain stripped
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '║'*'║') stripped=${stripped#║}; stripped=${stripped%║} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  if [ "$allow_busy" = 1 ] && [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  fm_composer_classify_content "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-}" insensitive "$plain"
}

fm_tmux_row_has_composer_edge() {  # <plain-row>
  local row=$1
  row="${row#"${row%%[![:space:]]*}"}"
  row="${row%"${row##*[![:space:]]}"}"
  case "$row" in
    '│'*|*'│'|'┃'*|*'┃'|'║'*|*'║'|'╭'*|*'╭'|'╮'*|*'╮'|\
    '┌'*|*'┌'|'┐'*|*'┐'|'╔'*|*'╔'|'╗'*|*'╗'|'┏'*|*'┏'|'┓'*|*'┓'|\
    '╰'*|*'╰'|'╯'*|*'╯'|'└'*|*'└'|'┘'*|*'┘'|'╚'*|*'╚'|'╝'*|*'╝'|\
    '┗'*|*'┗'|'┛'*|*'┛'|'─'*|*'─'|'━'*|*'━'|'═'*|*'═'|'|'*|*'|'|'+'*|*'+')
      return 0
      ;;
  esac
  return 1
}

fm_tmux_composer_geometry_spaces() {  # <content-inner> -> spaces
  local content=$1 probe
  probe="${content#"${content%%[![:space:]]*}"}"
  case "$probe" in
    '>'*) content=${content/>/ } ;;
    '❯'*) content=${content/❯/ } ;;
    '›'*) content=${content/›/ } ;;
  esac
  content=$(printf '%s' "$content" | LC_ALL=C sed 's/[!-~]/ /g')
  case "$content" in
    *[![:space:]]*) return 1 ;;
  esac
  printf '%s' "$content"
}

# fm_tmux_find_composer_box: print the zero-based top and bottom rows of the
# complete bordered box that structurally contains the cursor, plus whether its
# geometry is ambiguous. The cursor may be on any content row or on the bottom
# border; no fixed cursor offset is used.
fm_tmux_find_composer_box() {  # <cursor-y> <plain-visible-pane> -> "<top> <bottom> <ambiguous>"
  local cy=$1 pane=$2 line indent left_stripped trimmed kind family current_family=
  local side_family top_inner top_spaces='' geometry_check=0 geometry_ambiguous=0
  local content_inner content_spaces bottom_inner bottom_spaces
  local current_indent=
  local row=0 top=-1 valid=0 content_rows=0 unsafe=0 cursor_structural=0
  while IFS= read -r line; do
    indent=${line%%[![:space:]]*}
    left_stripped="${line#"${line%%[![:space:]]*}"}"
    trimmed="${left_stripped%"${left_stripped##*[![:space:]]}"}"
    kind=
    family=
    case "$trimmed" in
      '╭'*'╮') kind=top; family=rounded ;;
      '┌'*'┐') kind=top; family=light ;;
      '╔'*'╗') kind=top; family=double ;;
      '┏'*'┓') kind=top; family=heavy ;;
      '╰'*'╯') kind=bottom; family=rounded ;;
      '└'*'┘') kind=bottom; family=light ;;
      '╚'*'╝') kind=bottom; family=double ;;
      '┗'*'┛') kind=bottom; family=heavy ;;
      '+'*'+') kind=ascii; family=ascii ;;
    esac
    if [ "$row" -eq "$cy" ] && fm_tmux_row_has_composer_edge "$trimmed"; then
      cursor_structural=1
    fi
    if [ "$kind" = top ] || { [ "$kind" = ascii ] && [ "$top" -lt 0 ]; }; then
      if [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; then
        unsafe=1
      fi
      top=$row
      current_family=$family
      current_indent=$indent
      valid=1
      content_rows=0
      geometry_ambiguous=0
      geometry_check=1
      top_inner=$trimmed
      case "$family" in
        rounded) top_inner=${top_inner#╭}; top_inner=${top_inner%╮}; top_spaces=${top_inner//─/ } ;;
        light) top_inner=${top_inner#┌}; top_inner=${top_inner%┐}; top_spaces=${top_inner//─/ } ;;
        double) top_inner=${top_inner#╔}; top_inner=${top_inner%╗}; top_spaces=${top_inner//═/ } ;;
        heavy) top_inner=${top_inner#┏}; top_inner=${top_inner%┓}; top_spaces=${top_inner//━/ } ;;
        ascii) top_inner=${top_inner#+}; top_inner=${top_inner%+}; top_spaces=${top_inner//-/ } ;;
      esac
      case "$top_spaces" in
        *[![:space:]]*) geometry_check=0; geometry_ambiguous=1 ;;
      esac
    elif [ "$kind" = bottom ] || { [ "$kind" = ascii ] && [ "$top" -ge 0 ]; }; then
      if [ "$top" -ge 0 ] && [ "$family" = "$current_family" ] \
         && [ "$valid" = 1 ] && [ "$content_rows" -gt 0 ] \
         && [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; then
        [ "$indent" = "$current_indent" ] || geometry_ambiguous=1
        if [ "$geometry_check" = 1 ]; then
          bottom_inner=$trimmed
          case "$family" in
            rounded) bottom_inner=${bottom_inner#╰}; bottom_inner=${bottom_inner%╯}; bottom_spaces=${bottom_inner//─/ } ;;
            light) bottom_inner=${bottom_inner#└}; bottom_inner=${bottom_inner%┘}; bottom_spaces=${bottom_inner//─/ } ;;
            double) bottom_inner=${bottom_inner#╚}; bottom_inner=${bottom_inner%╝}; bottom_spaces=${bottom_inner//═/ } ;;
            heavy) bottom_inner=${bottom_inner#┗}; bottom_inner=${bottom_inner%┛}; bottom_spaces=${bottom_inner//━/ } ;;
            ascii) bottom_inner=${bottom_inner#+}; bottom_inner=${bottom_inner%+}; bottom_spaces=${bottom_inner//-/ } ;;
          esac
          [ "$bottom_spaces" = "$top_spaces" ] || geometry_ambiguous=1
        fi
        printf '%s %s %s' "$top" "$row" "$geometry_ambiguous"
        return 0
      fi
      if { [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; } \
         || [ "$row" -eq "$cy" ]; then
        unsafe=1
      fi
      top=-1
      current_family=
      current_indent=
      valid=0
      content_rows=0
    elif [ "$top" -ge 0 ]; then
      side_family=
      case "$trimmed" in
        '│'*'│') side_family=single ;;
        '┃'*'┃') side_family=heavy ;;
        '║'*'║') side_family=double ;;
        '|'*'|') side_family=ascii ;;
      esac
      case "$current_family:$side_family" in
        rounded:single|light:single|heavy:heavy|double:double|ascii:ascii)
          content_rows=$((content_rows + 1))
          [ "$indent" = "$current_indent" ] || geometry_ambiguous=1
          if [ "$geometry_check" = 1 ]; then
            content_inner=$trimmed
            case "$side_family" in
              single) content_inner=${content_inner#│}; content_inner=${content_inner%│} ;;
              heavy) content_inner=${content_inner#┃}; content_inner=${content_inner%┃} ;;
              double) content_inner=${content_inner#║}; content_inner=${content_inner%║} ;;
              ascii) content_inner=${content_inner#|}; content_inner=${content_inner%|} ;;
            esac
            if content_spaces=$(fm_tmux_composer_geometry_spaces "$content_inner"); then
              [ "$content_spaces" = "$top_spaces" ] || geometry_ambiguous=1
            else
              geometry_ambiguous=1
            fi
          fi
          ;;
        *) valid=0 ;;
      esac
    fi
    row=$((row + 1))
  done <<EOF
$pane
EOF
  if [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ]; then
    unsafe=1
  fi
  if [ "$unsafe" = 1 ] || [ "$cursor_structural" = 1 ]; then
    return 2
  fi
  return 1
}

# fm_tmux_composer_state classification contract:
# A row is structural only when its first or last non-whitespace character is a
# composer edge. A complete box has matching border families and bounded top and
# bottom rows. The proof-carrying verdict is empty for proven emptiness, pending
# for proven text in established structure, pending-unproven for text in
# ambiguous structure, and unknown for unreadable state. Consumers that can
# overwrite input or confirm delivery must accept only the exact positive proof
# they require, so unrecognized future verdicts fail safe by default. Empty
# requires positive proof: a genuinely empty composer, an all-empty unambiguous
# box, an empty non-bordered fallback row, or the submit core's proven
# busy-queued Enter conversion.
fm_tmux_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local target=$1 cy raw pane plain box box_status top bottom geometry_ambiguous
  local row row_raw state unknown_seen=0
  cy=$(fm_tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_tmux capture-pane -e -p -t "$target" -S 0 -E - 2>/dev/null) || { printf 'unknown'; return 0; }
  plain=$(printf '%s\n' "$pane" | fm_composer_strip_ansi)
  if box=$(fm_tmux_find_composer_box "$cy" "$plain"); then
    top=${box%% *}
    box=${box#* }
    bottom=${box%% *}
    geometry_ambiguous=${box#* }
    row=$((top + 1))
    while [ "$row" -lt "$bottom" ]; do
      row_raw=$(printf '%s\n' "$pane" | sed -n "$((row + 1))p")
      state=$(fm_tmux_composer_row_state "$row_raw" 1 0)
      case "$state" in
        pending)
          if [ "$geometry_ambiguous" = 1 ]; then
            printf 'pending-unproven'
          else
            printf 'pending'
          fi
          return 0
          ;;
        unknown) unknown_seen=1 ;;
      esac
      row=$((row + 1))
    done
    if [ "$unknown_seen" = 1 ] || [ "$geometry_ambiguous" = 1 ]; then
      printf 'unknown'
    else
      printf 'empty'
    fi
    return 0
  else
    box_status=$?
    if [ "$box_status" -eq 2 ]; then
      printf 'unknown'
      return 0
    fi
  fi
  raw=$(fm_tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  if fm_tmux_row_has_composer_edge "$(printf '%s\n' "$raw" | fm_composer_strip_ansi)"; then
    printf 'unknown'
    return 0
  fi
  fm_tmux_composer_row_state "$raw" 0
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
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    fm_tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    case "$state" in
      pending|pending-unproven) ;;
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
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  fm_tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
