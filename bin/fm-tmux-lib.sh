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

# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# fm_tmux_row_is_rule: 0 (true) when a TRIMMED plain row consists solely of the
# composer box's horizontal rule glyphs - light ─ (U+2500) or heavy ━ (U+2501),
# the top/bottom border of claude's and codex's rule-bordered composer. Such a
# row is box DECORATION, never composer content. Detected here so the tmux
# cursor_y off-by-one (see fm_tmux_composer_state) can re-anchor. Non-empty rows
# only; a blank row is not a rule. bash 3.2 safe: literal multibyte substitution,
# no \u escapes or multibyte character classes (matches herdr's Pi-separator
# check, bin/backends/herdr.sh).
fm_tmux_row_is_rule() {  # <trimmed-plain-row>
  local r=$1 stripped
  [ -n "$r" ] || return 1
  stripped=${r//─/}
  stripped=${stripped//━/}
  [ -z "$stripped" ]
}

# fm_tmux_classify_raw_row: given the RAW (ANSI-styled) bytes of a single chosen
# composer row, produce the empty|pending|unknown verdict. Split out of
# fm_tmux_composer_state so the row-window re-anchoring there can hand it whatever
# row it settled on. The bordered flag (a genuine composer box) is read from the
# PLAIN row (fm_composer_strip_ansi keeps ghost text so the box border survives an
# all-ANSI strip), while the real-typed CONTENT is extracted with the shared
# fm_composer_strip_ghost so dim/faint AND dark-truecolor ghost text drops out
# before classification (grok's dark box border drops with the ghost, which is why
# the bordered flag is read from the plain row, not the ghost-stripped one). The
# detector strips the harness's box-drawing composer borders ("│ … │", heavy "┃",
# or a plain ASCII "|") using literal-string substitution (bash 3.2 safe,
# locale-independent - no \u escapes, no multibyte character classes), and
# delegates the empty/pending/unknown decision to the shared owner
# fm_composer_classify_content (bin/fm-composer-lib.sh). The bordered flag is what
# lets a bordered `│ > │` (a harness's own idle composer) read empty while a bare,
# unbordered `$ ` dead-shell prompt reads unknown.
fm_tmux_classify_raw_row() {  # <raw-styled-row> -> empty|pending|unknown
  local raw=$1 plain stripped bordered=0
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
# the single composer row (-S/-E), then classified by fm_tmux_classify_raw_row.
#
# Cursor-row off-by-one re-anchor (incident afk-daemon-composer-wedge-fix):
# a pristine, never-typed-into claude/codex composer renders its input row inside
# a rule-bordered box (─────/❯/─────), and tmux's own #{cursor_y} points one row
# BELOW the ❯ input row, at the box's bottom rule (the box appears to render one
# row lower before any real typing starts; documented as the "Residual gap,
# tmux-only" quirk in the harness-adapters skill). Reading only that single row,
# the rule glyphs classify as pending, so the away-mode escalation injector
# (bin/fm-supervise-daemon.sh) read firstmate's OWN idle composer as pending input
# and deferred 100% of escalations for ~15 hours with no delivery. When the cursor
# row is a pure rule, this widens to a small row window around cursor_y and
# re-anchors on the adjacent genuine agent-composer input row (a row whose trimmed
# content starts with the agent prompt glyph ❯ or ›, which appears ONLY on the
# live composer input row, never in transcript). If no such row is found the
# cursor row is kept, so the verdict defers safely and injection is never forced;
# the fix only ever turns a rule-masked EMPTY composer back into empty, and a
# rule-row that carries real ❯ text still reads pending. herdr locates its
# composer structurally, not by cursor_y (bin/backends/herdr.sh), so this is
# tmux-path-scoped; see docs/tmux-backend.md.
fm_tmux_composer_state() {  # <target> -> empty|pending|unknown
  local target=$1 cy raw plain win start row rp anchored=""
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) || { printf 'unknown'; return 0; }
  # If cursor_y landed on the composer box's horizontal rule (the off-by-one
  # above), re-anchor on the neighbouring ❯/› input row.
  plain=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  if fm_tmux_row_is_rule "$plain"; then
    start=$((cy - 2)); [ "$start" -ge 0 ] || start=0
    win=$(tmux capture-pane -e -p -t "$target" -S "$start" -E "$((cy + 2))" 2>/dev/null) || win=""
    if [ -n "$win" ]; then
      while IFS= read -r row; do
        rp=$(printf '%s\n' "$row" | fm_composer_strip_ansi)
        rp="${rp#"${rp%%[![:space:]]*}"}"
        rp="${rp%"${rp##*[![:space:]]}"}"
        # Strip an agent box's side borders before testing the glyph (defensive:
        # claude's rule box has no side borders, but a boxed harness may).
        case "$rp" in
          '│'*'│') rp=${rp#│}; rp=${rp%│} ;;
          '┃'*'┃') rp=${rp#┃}; rp=${rp%┃} ;;
          '|'*'|') rp=${rp#|}; rp=${rp%|} ;;
        esac
        rp="${rp#"${rp%%[![:space:]]*}"}"
        rp="${rp%"${rp##*[![:space:]]}"}"
        case "$rp" in
          '❯'*|'›'*) anchored=$row ;;
        esac
      done <<EOF
$win
EOF
      if [ -n "$anchored" ]; then raw=$anchored; fi
    fi
  fi
  fm_tmux_classify_raw_row "$raw"
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
