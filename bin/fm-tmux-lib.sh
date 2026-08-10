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
FM_TMUX_BUSY_REGEX_DEFAULT='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'
FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT='esc to interrupt|…[[:space:]]+\([0-9]+[smh]'
FM_TMUX_CODEX_BUSY_REGEX_DEFAULT='esc to interrupt'
FM_TMUX_OPENCODE_BUSY_REGEX_DEFAULT='esc interrupt'
FM_TMUX_PI_BUSY_REGEX_DEFAULT='Working\.\.\.'
FM_TMUX_GROK_BUSY_REGEX_DEFAULT='Ctrl\+c:cancel'
FM_TMUX_KIMI_BUSY_REGEX_DEFAULT='^[[:space:]]*(🌑|🌒|🌓|🌔|🌕|🌖|🌗|🌘)[[:space:]]+·[[:space:]]+'

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
  tmux capture-pane -e -p -t "$1" -S 0 -E - 2>/dev/null
}

# fm_tmux_composer_cursor_row: the pane's cursor row, zero-based, relative to
# the visible pane - tmux's genuine primitive that no other backend has.
fm_tmux_composer_cursor_row() {  # <target>
  tmux display-message -p -t "$1" '#{cursor_y}' 2>/dev/null
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
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || tty=
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
    comm=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || comm=
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
  local target=$1 cy pane verdict identity
  cy=$(fm_tmux_composer_cursor_row "$target") || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_tmux_composer_capture "$target") || { printf 'unknown'; return 0; }
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

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_busy_state() {  # <target> [harness] -> busy|idle|unknown
  local win=$1 harness=${2:-} tail40 visible
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || { printf 'unknown'; return 0; }
  if printf '%s' "$visible" | fm_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

fm_pane_is_busy() {  # <target> [harness]
  [ "$(fm_pane_busy_state "$1" "${2:-}")" = busy ]
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
    tmux send-keys -t "$target" Enter 2>/dev/null || true
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
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$baseline_idle"
}
