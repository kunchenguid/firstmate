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
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel"
# (grok's mid-turn cancel hint, shown iff a turn is running - verified grok 0.2.73).
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'

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
# The pattern is the SHAPE of that line - a parenthesised elapsed-time counter
# followed by a token counter - not the spinner glyph (locale-fragile) or the
# verb (claude randomises it: Meandering/Simmering/Puttering/...).
FM_TMUX_SPINNER_REGEX_DEFAULT='\([0-9]+[hms][^)]*token'
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
fm_busy_hint_in_text() {  # <pane-text>
  printf '%s' "$1" | grep -v '^[[:space:]]*$' \
    | tail -"${FM_BUSY_TAIL_LINES:-$FM_TMUX_BUSY_TAIL_DEFAULT}" \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
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
# (claude's own idle composer) read empty while a bare, unbordered `$ ` dead-shell
# prompt reads unknown.
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
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  # content: from the ghost-stripped row (real typed text only).
  stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  # A busy footer landing on the cursor line is not pending input (tmux-specific:
  # only tmux captures the raw cursor row, which may BE the footer).
  if [ -n "$stripped" ] \
     && printf '%s' "$stripped" | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"; then
    printf 'empty'; return 0
  fi
  fm_composer_classify_content "$bordered" "$stripped" "${FM_COMPOSER_IDLE_RE:-}" insensitive "$plain"
}

# fm_pane_input_pending: 0 (pending) if the cursor line holds real unsubmitted
# text, 1 otherwise. An unreadable pane is treated as NOT pending (fail-safe:
# the same bias the old daemon used — an unknown pane defers nothing here).
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" = pending ]
}

# fm_pane_is_busy: 0 if the pane shows an agent mid-turn. Scans a 40-line tail
# like fm-watch.sh, and accepts EITHER busy signature:
#   1. an interrupt hint in the footer window (single-shot, as before), or
#   2. a spinner status line that is DEMONSTRABLY LIVE - it is still there, and
#      the pane repainted, across two captures FM_BUSY_LIVENESS_SECS apart.
# The liveness requirement is what keeps this from weakening wedge detection: a
# wedged harness's last frame keeps whatever spinner it died on, but it stops
# repainting, so it reads not-busy and still escalates.
fm_pane_is_busy() {  # <target>
  local win=$1 t0 t1
  t0=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  fm_busy_hint_in_text "$t0" && return 0
  fm_spinner_in_text "$t0" || return 1
  sleep "${FM_BUSY_LIVENESS_SECS:-$FM_TMUX_BUSY_LIVENESS_SECS_DEFAULT}"
  t1=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  fm_spinner_in_text "$t1" || return 1
  fm_pane_text_advanced "$t0" "$t1"
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
# Busy-queued Enter (opencode 1.18.4): the harness accepts Enter while mid-turn
# and queues it for after the current turn, but keeps the typed text visible in
# the composer. Once the Enter-retry budget is spent and the composer still
# reads "pending", the submit core falls back to `fm_pane_is_busy`: a busy pane
# means the Enter was accepted and queued (report `empty` so the caller does
# not re-send), while an idle pane keeps `pending` as a genuine swallow. This
# is the only place that exception lives, so the daemon's strict and
# fm-send's lenient success policies both treat a busy-queued Enter as
# delivered.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep>
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    [ "$state" = pending ] || { printf '%s' "$state"; return 0; }
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
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
