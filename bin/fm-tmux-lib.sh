#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE source of truth for: busy detection, composer-empty (pending-input)
# detection, and a verify-and-retry-Enter submit. Sourced by the away-mode daemon
# (bin/fm-supervise-daemon.sh), bin/fm-send.sh, and the secondmate pending-reply
# guard (bin/fm-pending-reply-lib.sh) so their rendered delivery checks share one
# contract.
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
# Busy-queued Enter, on the tmux backend only for now: OpenCode 1.18.4 and the
# structurally matched Claude footer shapes are verified to accept Enter while
# mid-turn without clearing the composer. `fm_tmux_harness_supports_busy_queued_enter`
# is the explicit capability gate for treating their rendered busy footer as
# submit proof after the Enter-retry budget is spent. Every other harness and
# an unknown harness fail closed with `pending`; rendered activity alone does
# not prove input acceptance, and Kimi's locale-sensitive moon spinner in
# particular must never convert a visibly retained composer to `empty`. The
# herdr backend observes the same OpenCode behavior but needs a separate fix;
# it is recorded as a known gap in `docs/herdr-backend.md` rather than patched
# here, so the tmux adapter does not paper over a herdr-specific shape.
#
# Overrides: FM_COMPOSER_IDLE_RE matches an empty composer after ghost and
# structural border stripping. FM_BUSY_REGEX overrides the rendered busy-footer
# matching used here.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.sh's
# semantic contract. The matching below serves only delivery guards: the submit
# acknowledgement, the away-mode supervisor-pane busy guard, and the secondmate
# pending-reply observation. They ask about a pane receiving input or completing
# one delivered request, not the state of a recorded worker task. Matching stays
# harness-scoped so one harness's output cannot make another read busy.
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

# Delivery-only rendered busy footers per harness. claude/codex: "esc to
# interrupt"; opencode: "esc interrupt"; pi: "Working..."; grok: "Ctrl+c:cancel".
# Claude renders THREE busy footers and only one carries a token counter:
# a streaming turn "<Gerund>... (4m 39s . 17.0k tokens)", a tool wait
# "<Gerund> for 53s . 1 shell still running" with neither a counter nor a
# parenthesized duration, and extended thinking "<Gerund>... (2m 50s .
# thinking some more with xhigh effort)" with neither a counter nor a wait
# hint. The gerund is randomised and can contain non-ASCII characters, so it is
# never matched.
# The elapsed timer is NOT the discriminator either: a FINISHED turn renders
# the same timer ("Baked for 8m 42s"), so a bare timer alternative reports a
# genuinely idle pane as busy - the direction that makes the submit guard
# treat a swallowed Enter as delivered. Streaming and thinking rows therefore
# require a complete parenthesized duration-plus-detail footer, and tool-wait
# rows require the elapsed "for" prefix plus a complete count-and-nouns wait
# hint. Both shapes are anchored as full rows so ordinary transcript fragments
# cannot keep an idle pane falsely busy. The wait hint counts arbitrary tool
# nouns ("5 shells, 1 monitor still running"), so it is matched by
# count-plus-nouns rather than "shells?".
# The parenthesized-duration arm rejects lines containing a path separator
# before it, because a completed tool call leaves its own elided path and
# duration in the transcript ("/private/tmp/...- ... (6m 8s)").
# Every alternative is ASCII: the spinner glyph, the middot, and the ellipsis
# are all locale-fragile, which is the lesson the grok adapter already taught.
# Keep this signature separate from the shared default because that shape is
# not generic enough to classify arbitrary harness output safely.
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
FM_TMUX_CLAUDE_BUSY_REGEX_DEFAULT='esc to interrupt|^[^/]*\(([0-9]+h )?([0-9]+m )?[0-9]+s [^[:alnum:][:space:]]+ (([^[:alnum:][:space:]]+ )?[0-9]+(\.[0-9]+)?[kKmM]? tokens( [^[:alnum:][:space:]]+ (still thinking with [a-z]+ effort|thought for ([0-9]+m )?[0-9]+s))?|thinking( some more)? with [a-z]+ effort)\)$|^[^/]* for ([0-9]+h )?([0-9]+m )?[0-9]+s [^[:alnum:][:space:]]+ [0-9]+ [a-z]+(, [0-9]+ [a-z]+)* still running$'
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
  cy=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(tmux capture-pane -e -p -t "$target" -S 0 -E - 2>/dev/null) || { printf 'unknown'; return 0; }
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
  raw=$(tmux capture-pane -e -p -t "$target" -S "$cy" -E "$cy" 2>/dev/null) \
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

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_is_busy() {  # <target> [harness]
  local win=$1 harness=${2:-} tail40
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12 \
    | fm_busy_lines_match "$harness"
}

fm_tmux_harness_supports_busy_queued_enter() {  # <harness>
  case "${1:-}" in
    claude|opencode) return 0 ;;
  esac
  return 1
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final proof-carrying verdict on stdout so callers can require
# exact `empty` before treating submission as confirmed.
# The header's busy-queued Enter capability contract owns when a rendered busy
# footer is sufficient submit proof. Pending-unproven receives the same Enter
# retry budget but never reaches this exception.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep> [harness]
  local target=$1 retries=$2 sleep_s=$3 harness=${4:-} i=0 state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
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
  # For an opted-in harness, a busy pane proves the message was queued.
  # Every other case keeps reporting pending - a genuine swallow.
  if fm_tmux_harness_supports_busy_queued_enter "$harness" \
    && fm_pane_is_busy "$target" "$harness"; then
    printf 'empty'
  else
    printf 'pending'
  fi
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle> [harness]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 harness=${6:-}
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$harness"
}
