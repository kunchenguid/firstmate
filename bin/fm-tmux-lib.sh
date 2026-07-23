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
# ANSI styling (tmux capture-pane -e) and extracts the real typed content with the
# shared, fleet-wide fm_composer_strip_ghost (bin/fm-composer-lib.sh), which drops
# every de-emphasised run - dim/faint (SGR 2) AND a dark/muted truecolor
# foreground - so ghost/placeholder text never counts as real input. The styled
# capture is consumed internally and parsed into a boolean here; it is NEVER
# surfaced (fm-peek and every human/LLM-facing path stay plain), and only the
# single composer row is captured, so no escape-laden pane bulk is produced. This
# is harness-generic: any harness that de-emphasises placeholder/ghost text
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
# Per-harness override: FM_COMPOSER_IDLE_RE matches an empty composer after
# ghost and structural border stripping. FM_BUSY_REGEX overrides the busy
# footer set (mirrors fm-watch.sh / the daemon).
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

# Busy footers per harness (mirror fm-watch.sh). claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel";
# omp: "esc" inside angle brackets (mid-turn cancel hint).
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel|[<⟨]esc[>⟩]'
FM_TMUX_QUEUED_ACK_REGEX_DEFAULT='Messages? to be submitted after (the )?next tool call|submitted after (the )?next tool call|queued (for|until) (the )?next tool call'

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

fm_tmux_strip_composer_borders() {  # <line>
  local stripped=$1
  stripped=${stripped//│/}
  stripped=${stripped//┃/}
  stripped=${stripped//|/}
  stripped=${stripped//╭/}
  stripped=${stripped//╮/}
  stripped=${stripped//╰/}
  stripped=${stripped//╯/}
  stripped=${stripped//─/}
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  printf '%s' "$stripped"
}

# fm_tmux_composer_state: classify the cursor/composer line of <target> as
#   empty   - no pending input (blank, a busy footer, an empty agent composer, or
#             only de-emphasised ghost/placeholder text). Safe to inject; also the positive
#             acknowledgement that a submit landed.
#   pending - real, unsubmitted text on the cursor line (a human mid-typing, or a
#             previous injection whose Enter was swallowed). Defer / retry.
#   unknown - the pane could not be read (tmux error), OR the cursor line is a
#             bare shell prompt (`$`/`%`/`#`/`>`) - a dead shell, not an agent
#             composer, so NOT a safe injection target. The caller decides.
#
# The cursor line is captured WITH ANSI styling (capture-pane -e) and bounded to
# the single composer row (-S/-E). The bordered flag (a genuine composer box) is
# read from the PLAIN row (fm_composer_strip_ansi keeps ghost text so the box
# border is still visible), while the real-typed CONTENT is extracted with the
# shared fm_composer_strip_ghost so dim/faint AND dark-truecolor ghost text drops
# out before classification (grok's dark box border drops with the ghost, which
# is why the bordered flag is read from the plain row, not the ghost-stripped
# one). Both are internal only, never surfaced. The detector strips the harness's
# box-drawing composer borders ("│ … │", heavy "┃", or a plain ASCII "|") using
# literal-string substitution (bash 3.2 safe, locale-independent - no \u escapes,
# no multibyte character classes), and delegates the empty/pending/unknown
# decision to the shared owner fm_composer_classify_content
# (bin/fm-composer-lib.sh). The bordered flag is what lets a bordered `│ > │`
# (claude's own idle composer) or OMP's rounded input box read empty while a bare,
# unbordered `$ ` dead-shell prompt reads unknown.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw plain stripped bordered=0
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  # bordered: from the plain row (borders survive an all-ANSI strip).
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  case "$plain" in
    '│'*'│'|'┃'*'┃') bordered=1 ;;
    '|'*'|') bordered=1 ;;
    '╭'*'╮'|'╰'*'╯') bordered=1 ;;
  esac
  # content: from the ghost-stripped row (real typed text only).
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  stripped=$(fm_tmux_strip_composer_borders "$stripped")
  # A busy footer landing on the cursor line is not pending input (tmux-specific:
  # only tmux captures the raw cursor row, which may BE the footer).
  if [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  fm_composer_classify_content "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-}" insensitive "$plain"
}

fm_tmux_submit_region_bounds() {  # <target> <text> -> "<start> <end>" or blank
  local target=$1 text=$2 cy width usable rows max_rows start
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || return 1
  case "$cy" in ''|*[!0-9]*) return 1 ;; esac
  width=$(tmux display-message -p -t "$target" '#{pane_width}' 2>/dev/null || true)
  case "$width" in ''|*[!0-9]*) width=80 ;; esac
  usable=$((width - 4))
  [ "$usable" -ge 10 ] || usable=10
  rows=$(( (${#text} + usable - 1) / usable + 2 ))
  [ "$rows" -ge 1 ] || rows=1
  max_rows=${FM_TMUX_SUBMIT_VERIFY_MAX_LINES:-20}
  case "$max_rows" in ''|*[!0-9]*) max_rows=20 ;; esac
  [ "$max_rows" -ge 1 ] || max_rows=1
  [ "$rows" -le "$max_rows" ] || rows=$max_rows
  start=$((cy - rows + 1))
  [ "$start" -ge 0 ] || start=0
  printf '%s %s' "$start" "$cy"
}

fm_tmux_submit_region_text() {  # <target> <start> <end>
  local target=$1 start=$2 end=$3 raw
  raw=$(tmux capture-pane -e -p -t "$target" -S "$start" -E "$end" 2>/dev/null) || return 1
  printf '%s\n' "$raw" | fm_composer_strip_ghost | while IFS= read -r line || [ -n "$line" ]; do
    fm_tmux_strip_composer_borders "$line"
    printf '\n'
  done
}

fm_tmux_submit_region_state() {  # <target> <text> <start> <end> -> empty|pending|unknown
  local target=$1 text=$2 start=$3 end=$4 region needle haystack match_chars
  region=$(fm_tmux_submit_region_text "$target" "$start" "$end") || { printf 'unknown'; return 0; }
  if printf '%s' "$region" | grep -qiE "${FM_TMUX_QUEUED_ACK_RE:-$FM_TMUX_QUEUED_ACK_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  match_chars=${FM_TMUX_SUBMIT_MATCH_CHARS:-160}
  case "$match_chars" in ''|*[!0-9]*) match_chars=160 ;; esac
  [ "$match_chars" -ge 1 ] || match_chars=160
  # Match the visible tail: wrapped composers keep the end of a long message
  # near cursor_y, while control bytes such as the AFK sentinel do not render.
  needle=$(printf '%s' "$text" | LC_ALL=C tr -d '[:space:][:cntrl:]' | tail -c "$match_chars")
  [ -n "$needle" ] || { printf 'unknown'; return 0; }
  haystack=$(printf '%s' "$region" | LC_ALL=C tr -d '[:space:][:cntrl:]')
  case "$haystack" in
    *"$needle"*) printf 'pending'; return 0 ;;
  esac
  printf 'empty'; return 0
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

fm_tmux_pane_boot_state() {  # <target> -> booting|ready|unknown
  local target=$1 tail40
  tail40=$(tmux capture-pane -p -t "$target" -S -40 2>/dev/null) || { printf 'unknown'; return 0; }
  if printf '%s\n' "$tail40" | grep -qiE 'Update available!' \
     && printf '%s\n' "$tail40" | grep -qiE 'Press enter to continue'; then
    printf 'booting'; return 0
  fi
  if printf '%s\n' "$tail40" | grep -qiE 'OpenAI Codex' \
     && printf '%s\n' "$tail40" | grep -qiE 'model:[[:space:]]+loading'; then
    printf 'booting'; return 0
  fi
  printf 'ready'; return 0
}

fm_tmux_wait_until_not_booting() {  # <target> -> ready|unknown|send-deferred
  local target=$1 max_s=${FM_TMUX_BOOT_WAIT_SECS:-20} poll_s=${FM_TMUX_BOOT_POLL_SLEEP:-1}
  local elapsed=0 state
  case "$max_s" in ''|*[!0-9]*) max_s=20 ;; esac
  case "$poll_s" in ''|*[!0-9]*) poll_s=1 ;; esac
  [ "$poll_s" -ge 1 ] || poll_s=1
  while :; do
    state=$(fm_tmux_pane_boot_state "$target")
    [ "$state" = booting ] || { printf '%s' "$state"; return 0; }
    [ "$elapsed" -lt "$max_s" ] || { printf 'send-deferred'; return 0; }
    sleep "$poll_s"
    elapsed=$((elapsed + poll_s))
  done
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final verdict on stdout
# (empty|pending|unknown|send-failed|send-deferred) so callers can pick their own
# success policy:
#   - the daemon clears its buffer only on "empty" (strict: an unknown pane must
#     not be mistaken for a delivered escalation).
#   - fm-send fails only on "pending" (lenient: a positively-confirmed swallow),
#     so an unreadable pane never turns a normal steer into a false error.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep> [text start end]
  local target=$1 retries=$2 sleep_s=$3 text=${4-} start=${5-} end=${6-} i=0 state region_state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
    if [ -n "$text" ] && [ -n "$start" ] && [ -n "$end" ]; then
      region_state=$(fm_tmux_submit_region_state "$target" "$text" "$start" "$end")
      [ "$region_state" = empty ] && { printf 'empty'; return 0; }
    fi
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  # Retries exhausted, composer still shows pending.
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
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 boot_state bounds start end
  boot_state=$(fm_tmux_wait_until_not_booting "$target")
  [ "$boot_state" != send-deferred ] || { printf 'send-deferred'; return 0; }
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  bounds=$(fm_tmux_submit_region_bounds "$target" "$text" 2>/dev/null || true)
  if [ -n "$bounds" ]; then
    start=${bounds% *}
    end=${bounds#* }
    fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$text" "$start" "$end"
  else
    fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
  fi
}
