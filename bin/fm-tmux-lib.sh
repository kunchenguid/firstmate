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
# misjudged the pane. The composer reader now captures just the cursor line WITH
# ANSI styling (tmux capture-pane -e), drops dim/faint (SGR 2) runs, and decides on
# what is left, so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that dims placeholder/ghost text benefits.
#
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# dim-ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon). FM_INJECT_SUBMIT_RETRIES and
# FM_INJECT_SUBMIT_SLEEP tune how long fm_tmux_inject_brief retries Enter while a
# cold-starting composer (e.g. kimi/pi-tui) drops the first keypresses.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; kimi:
# "thinking..." / "working...".
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|thinking\.\.\.|working\.\.\.'

# fm_tmux_strip_ghost: remove dim/faint (ANSI SGR 2) styled runs from one captured
# composer line, then drop any remaining escape sequences, leaving only the plain,
# normal-intensity text, the text a human actually typed. Dim/faint runs are
# ghost/placeholder text (e.g. claude's predicted-next-prompt suggestion) that
# fills an otherwise-empty composer and must never read as pending input. Reads the
# styled line on stdin (from `tmux capture-pane -e`) and prints plain text on
# stdout. LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and dim runs
# alike pass through or drop intact without locale-dependent character classes.
# A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run; codes are processed
# left to right within a sequence so "ESC[0;2m" (reset then dim) reads as dim.
fm_tmux_strip_ghost() {
  LC_ALL=C awk '
    function sgr_code(v, b) {
      b = v
      sub(/:.*/, "", b)
      if (b == "") b = "0"
      return b
    }
    function skip_color_payload(a, p, k, mode, code) {
      if (index(a[p], ":") > 0) return p
      if (p >= k) return p
      mode = a[p + 1]
      code = sgr_code(mode)
      if (index(mode, ":") > 0) return p + 1
      if (code == "5") return p + 2
      if (code == "2") return p + 4
      return p + 1
    }
    {
      line = $0; out = ""; dim = 0; n = length(line); i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == "\033") {            # ESC: consume a CSI ... final-byte sequence
          j = i + 1
          if (substr(line, j, 1) == "[") {
            j++; params = ""
            while (j <= n) {
              cc = substr(line, j, 1)
              if (cc ~ /[@-~]/) break
              params = params cc; j++
            }
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update dim/faint state
              if (params == "") params = "0"
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38" || code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0" || code == "22") dim = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0) out = out c        # keep only normal-intensity bytes
        i++
      }
      print out
    }
  '
}

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a bare prompt, a busy footer, or only dim
#             ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error). The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E), then run through fm_tmux_strip_ghost so dim/faint
# ghost text drops out before classification. The styled capture is internal only,
# never surfaced. The detector then strips the harness's box-drawing composer
# borders ("│ … │", heavy "┃", or a plain ASCII "|") using literal-string
# substitution (bash 3.2 safe, locale-independent — no \u escapes, no multibyte
# character classes), and asks whether anything real is left.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw line stripped
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  line=$(printf '%s\n' "$raw" | fm_tmux_strip_ghost)
  # Strip the composer box borders (literal glyphs — no character classes).
  stripped=${line//│/}      # U+2502 light vertical (claude)
  stripped=${stripped//┃/}  # U+2503 heavy vertical
  stripped=${stripped//|/}  # ASCII pipe
  # Trim surrounding whitespace.
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # Nothing left inside the box = empty composer.
  [ -n "$stripped" ] || { printf 'empty'; return 0; }
  if [ -n "${FM_COMPOSER_IDLE_RE:-}" ] \
     && printf '%s' "$stripped" | grep -qiE "$FM_COMPOSER_IDLE_RE"; then
    printf 'empty'; return 0
  fi
  # Just a bare prompt glyph = empty composer (idle).
  case "$stripped" in
    '>'|'❯'|'$'|'%'|'#') printf 'empty'; return 0 ;;
  esac
  # A busy footer landing on the cursor line is not pending input.
  if printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  printf 'pending'; return 0
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target>
  local win=$1 tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout (empty|pending|unknown|send-failed) so callers can
# pick their own success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf 'pending'; return 0; }
  done
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}

# fm_tmux_composer_box_state: classify the agent's whole composer input BOX as
# empty|pending|unknown by scanning the bottom of the pane for the composer's
# prompt row, instead of trusting a single cursor-row read.
#
# Why this exists (kimi / pi-tui): fm_tmux_composer_state reads only the cursor_y
# row. kimi draws a multi-row composer box and parks the cursor on a BLANK
# continuation row below the prompt, so a single-row read reports "empty" while
# the typed brief still sits on the prompt row above. Used to verify a brief
# actually submitted — where a false "empty" silently drops the brief — so it must
# find the prompt row wherever it is, not assume it is the cursor line.
#
# The prompt row is the last captured line that, after dropping dim ghost text and
# box borders, begins with a composer prompt glyph (">" or "❯"). Text after the
# glyph is pending input; just the glyph is an empty composer. If no such row is
# found (the box has not rendered yet) the state is unknown, so a not-yet-ready
# pane is never mistaken for a ready, empty one.
fm_tmux_composer_box_state() {  # <target> -> empty|pending|unknown
  local target=$1 raw cleaned line stripped rest found=0 state=unknown
  raw=$(tmux capture-pane -e -p -t "$target" -S -12 2>/dev/null) || { printf 'unknown'; return 0; }
  cleaned=$(printf '%s\n' "$raw" | fm_tmux_strip_ghost)
  while IFS= read -r line; do
    stripped=${line//│/}
    stripped=${stripped//┃/}
    stripped=${stripped//|/}
    stripped="${stripped#"${stripped%%[![:space:]]*}"}"
    stripped="${stripped%"${stripped##*[![:space:]]}"}"
    case "$stripped" in
      '>'*|'❯'*)
        found=1
        rest=$stripped
        rest=${rest#'>'}
        rest=${rest#'❯'}
        rest="${rest#"${rest%%[![:space:]]*}"}"
        if [ -n "$rest" ]; then state=pending; else state=empty; fi
        ;;
    esac
  done <<EOF
$cleaned
EOF
  [ "$found" -eq 1 ] || { printf 'unknown'; return 0; }
  printf '%s' "$state"
}

# fm_tmux_inject_brief: inject a brief file into an interactive agent composer.
# Usage: fm_tmux_inject_brief <target> <brief-file> [<timeout>]
#   <target>      tmux target (session:window)
#   <brief-file>  path to the brief to inject
#   <timeout>     seconds to wait for a ready composer (default 30)
# Returns 0 on success, 1 if the composer never becomes ready or the brief cannot be sent.
# Multi-line briefs are pasted via tmux paste-buffer; single-line briefs use send-keys -l.
fm_tmux_inject_brief() {  # <target> <brief-file> [<timeout>]
  local target=$1 brief=$2 timeout=${3:-30} waited=0 line_count
  local attempts sleep_s i box
  # Wait for the actual composer BOX to render empty, not just for the cursor row
  # to read blank. On a cold-starting pane the cursor line is blank before the TUI
  # draws its composer, which a single-row check mistakes for a ready, empty
  # composer and injects into a pane that cannot yet accept input.
  while [ "$waited" -lt "$timeout" ]; do
    [ "$(fm_tmux_composer_box_state "$target")" = empty ] && break
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$waited" -ge "$timeout" ]; then
    printf 'error: composer never became ready for brief injection in %s\n' "$target" >&2
    return 1
  fi
  line_count=$(awk 'END { print NR }' "$brief" 2>/dev/null || echo 0)
  if [ "$line_count" -gt 1 ]; then
    # Multi-line: paste so internal newlines do not submit early.
    if ! tmux load-buffer -b __fm_brief - < "$brief" 2>/dev/null; then
      printf 'error: failed to load brief into tmux paste buffer\n' >&2
      return 1
    fi
    if ! tmux paste-buffer -b __fm_brief -t "$target" 2>/dev/null; then
      printf 'error: failed to paste brief into %s\n' "$target" >&2
      return 1
    fi
  else
    # Single-line: type literally.
    if ! tmux send-keys -t "$target" -l "$(cat "$brief")" 2>/dev/null; then
      printf 'error: failed to send brief to %s\n' "$target" >&2
      return 1
    fi
  fi
  # Submit and verify the brief actually LEFT the composer. Two kimi-specific
  # hazards make a single Enter + cursor-row check unreliable:
  #   1. kimi parks the cursor on a blank composer row, so emptiness must be judged
  #      against the whole composer box (fm_tmux_composer_box_state), not the cursor
  #      line — otherwise a still-full composer reads as "submitted" and the brief
  #      is silently dropped while spawn reports success.
  #   2. kimi (pi-tui) can drop the first Enter(s) during cold start, so Enter is
  #      retried (only — never retyped, which would duplicate the brief) until the
  #      box clears or the window ends.
  attempts=${FM_INJECT_SUBMIT_RETRIES:-30}
  sleep_s=${FM_INJECT_SUBMIT_SLEEP:-0.5}
  i=0
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    box=$(fm_tmux_composer_box_state "$target")
    [ "$box" = empty ] && return 0
    i=$((i + 1))
    if [ "$i" -ge "$attempts" ]; then
      printf 'error: brief typed but composer never cleared (submit not confirmed) in %s\n' "$target" >&2
      return 1
    fi
  done
}
