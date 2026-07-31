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
# Semantic submit confirmation (the finish of the #1327 migration): for a
# recorded task whose harness has a trusted semantic lifecycle source with an
# armed busy contract (bin/fm-busy-lib.sh: claude, opencode, pi, pi-signed
# today) AND a record-proven idle baseline, fm_tmux_submit_semantic confirms
# "a turn opened, per the harness's own lifecycle signal, after my delivered
# Enter" from the task's busy record, mirroring
# herdr's native agent-state confirmation on legibly idle baselines
# (bin/backends/herdr.sh fm_backend_herdr_send_text_submit). An unchanged
# record never confirms anything, so every other baseline (mid-turn, unknown,
# malformed, stale) and every harness without a verified semantic source
# (codex, kimi, grok) uses the composer-geometry and luminance readers below
# as the EXPLICITLY LABELLED FALLBACK, as do context-free callers (the
# away-mode daemon's supervisor injection); bin/backends/tmux.sh owns the
# routing and the fallback label. While FM_SUBMIT_SEMANTIC_COMPARE=1 (the
# bake-in default) the semantic path also reads the rendered composer once
# after the verdict, prints a loud SUBMIT-CONFIRM DISAGREEMENT warning when
# the two signals differ, records the disagreement durably, and downgrades a
# contradicted confirmation to unconfirmed - the designed tripwire for a
# mis-wired hook reporting submits that did not happen. The incidents above
# (ghost text read as typed input, 9.5 hours of suppressed escalations) are
# exactly the class this migration removes from the confirm path.
#
# Overrides: FM_COMPOSER_IDLE_RE matches an empty composer after ghost and
# structural border stripping. FM_BUSY_REGEX overrides the rendered busy-footer
# matching used here.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.sh's
# semantic contract. The rendered-text matching below serves only fallback
# delivery guards: the fallback submit acknowledgement and the away-mode
# supervisor-pane busy guard. Both ask about the pane receiving input, not the
# state of a recorded worker task. Matching stays harness-scoped so one
# harness's output cannot make another read busy. The semantic submit path
# READS the busy records that contract owns but never writes them.
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
# shellcheck source=bin/fm-busy-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-busy-lib.sh"

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

# --- Semantic submit confirmation -------------------------------------------
#
# THE CONFIRMATION RULE (independent-review redesign, 2026-07-31): delivery is
# confirmed ONLY by positive evidence - an idle-to-busy transition, observed
# in the task's trusted busy record, after an Enter this process successfully
# delivered. An unchanged record can never confirm anything: the spawn-time
# seed, a stuck busy record from a crashed turn, and a mis-wired hook all
# look like "still busy", so any verdict built on an unchanged record would
# report instructions as delivered when they were not. Consequences:
#   - Only an exact idle baseline enters the semantic path. A busy, unknown,
#     malformed, or stale baseline routes to the labelled rendered-composer
#     fallback, which proves pane-level facts at decision time (the same
#     split herdr uses: native confirmation on legibly idle baselines,
#     composer reads otherwise).
#   - turn-opened is accepted only from that idle baseline, so a turn caused
#     by the harness picking up a previously queued message can never
#     confirm a swallowed Enter.
#   - The Enter keystroke's exit status is tracked; if no Enter was
#     delivered, the verdict is send-failed, never a confirmation.
#   - While FM_SUBMIT_SEMANTIC_COMPARE=1 (the bake-in default) the rendered
#     composer is read once AFTER the semantic verdict, and a contradiction
#     DOWNGRADES a confirmation to unknown semantic-contradicted (the
#     rendered signal can veto a confirmation, never grant one) and is
#     recorded durably in state/<id>.submit-disagreement as well as on
#     stderr.
#
# KNOWN GAPS, deliberately not addressed here and owned by the queued
# fm-submit-correlation follow-up (captain decision, 2026-07-31): there is
# no send-to-turn correlation, so any later trusted busy sequence can be
# credited to this send when the composer reads empty or unknown, and
# concurrent sends to one task are not serialised (a previous per-task lock
# was removed because busy and ineligible sends bypassed it while it could
# block legitimate sends). Correlation needs a per-submit token the harness
# echoes back, not more shell on this side.
#
# Confirmation window tuning, mirroring herdr's sampled confirmation
# (fm_backend_herdr_wait_for_working): each Enter attempt spreads
# FM_SUBMIT_SEMANTIC_POLLS record reads across a per-attempt budget of
# max(<enter-sleep>, FM_SUBMIT_SEMANTIC_MIN_BUDGET) seconds. The hook writes
# its record within milliseconds of the harness event, but the harness event
# itself (the turn opening) trails Enter by up to ~500ms on real harnesses
# (herdr measured first-working at 90-490ms), so the caller's bare
# enter-sleep alone would under-sample.
FM_SUBMIT_SEMANTIC_POLLS=${FM_SUBMIT_SEMANTIC_POLLS:-6}
FM_SUBMIT_SEMANTIC_MIN_BUDGET=${FM_SUBMIT_SEMANTIC_MIN_BUDGET:-0.9}

# fm_tmux_submit_semantic_eligible: 0 iff <harness> has a trusted semantic
# lifecycle source (bin/fm-busy-lib.sh's per-harness trust table, so codex
# and kimi stay ineligible until their verification gates open) AND the
# task's busy contract is armed. Everything else routes to the labelled
# rendered-composer fallback.
fm_tmux_submit_semantic_eligible() {  # <harness> <state-dir> <id>
  local harness=${1:-} state=${2:-} id=${3:-}
  [ -n "$harness" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  [ -n "$(fm_busy_sources_for_harness "$harness")" ] || return 1
  fm_busy_current_gen "$state" "$id" >/dev/null 2>&1
}

# fm_tmux_submit_record_read: one source-trusted read of the task's semantic
# busy record for submit confirmation. Prints "<state> <seq>" when the record
# is valid, gen-matching, and written by a source trusted for <harness>;
# prints "none" for missing, malformed, stale-gen, or untrusted records so
# the caller treats those as no usable signal, never as a state.
fm_tmux_submit_record_read() {  # <state-dir> <id> <harness>
  local out r_state r_source r_seq
  out=$(fm_busy_record_read "$1" "$2") || { printf 'none'; return 0; }
  r_state=${out%% *}
  out=${out#* }
  r_source=${out%% *}
  r_seq=${out##* }
  fm_busy_source_trusted "$3" "$r_source" || { printf 'none'; return 0; }
  printf '%s %s' "$r_state" "$r_seq"
}

# fm_tmux_submit_disagreement_record: durable append-only record of one
# semantic-vs-rendered submit-confirm disagreement, written alongside the
# stderr warning so the evidence survives the session
# (state/<id>.submit-disagreement; removed by teardown). Best-effort: the
# verdict downgrade is the load-bearing consequence, not this write.
fm_tmux_submit_disagreement_record() {  # <state-dir> <id> <harness> <semantic-reason> <composer-state> <action>
  printf 'v1 ts=%s harness=%s semantic=%s composer=%s action=%s\n' \
    "$(date +%s)" "$3" "$4" "$5" "$6" >> "$1/$2.submit-disagreement" 2>/dev/null || true
}

# fm_tmux_submit_semantic_core: type <text> ONCE into a task whose baseline
# record the caller has proven idle, then submit with
# Enter and confirm delivery ONLY from the positive idle-to-busy transition:
# a busy record with seq advanced past <base-seq>, written by a source the
# task's harness trusts, observed after an Enter this process successfully
# delivered. Retries Enter only, never retypes (same contract as
# fm_tmux_submit_core). Echoes "<verdict> <reason>":
#   empty turn-opened   a turn opened after our delivered Enter
#   pending no-turn     no turn opened: a swallowed Enter or a broken hook;
#                       the caller must not assume delivery
#   send-failed         the literal type failed, or no Enter keystroke was
#                       ever delivered (every send-keys Enter failed)
# Residual risk, shared with and documented by the herdr model: a turn so
# fast it opens AND closes between two record reads would be missed and
# report pending; the caller's recovery is Enter-only, so the worst case is
# a loud unconfirmed error, never a duplicate typed message. On an idle
# worker no queued message is pending by construction (queued input is
# consumed at turn end), so a turn opening in this window after our
# delivered Enter is our submit; direct captain typing in the same
# sub-second window remains the accepted residual, and the bake-in
# comparison in fm_tmux_submit_semantic surfaces that shape as a
# disagreement and downgrades it.
fm_tmux_submit_semantic_core() {  # <target> <text> <retries> <enter-sleep> <settle> <state-dir> <id> <harness> <base-seq>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 state=$6 id=$7 harness=$8 base_seq=$9
  local cur cur_state cur_seq enter_ok=0
  local i=0 p polls interval
  tmux send-keys -t "$target" -l "$text" 2>/dev/null || { printf 'send-failed'; return 0; }
  sleep "$settle"
  polls=$FM_SUBMIT_SEMANTIC_POLLS
  case "$polls" in ''|*[!0-9]*|0) polls=1 ;; esac
  interval=$(awk -v b="$sleep_s" -v m="$FM_SUBMIT_SEMANTIC_MIN_BUDGET" -v p="$polls" \
    'BEGIN { b += 0; m += 0; if (m > b) b = m; if (b < 0) b = 0; if (p < 1) p = 1; printf "%.4f", b / p }' 2>/dev/null)
  case "$interval" in ''|*[!0-9.]*) interval=$sleep_s ;; esac
  while :; do
    if tmux send-keys -t "$target" Enter 2>/dev/null; then
      enter_ok=1
    fi
    p=0
    while [ "$p" -lt "$polls" ]; do
      sleep "$interval"
      cur=$(fm_tmux_submit_record_read "$state" "$id" "$harness")
      if [ "$enter_ok" = 1 ] && [ "$cur" != none ]; then
        cur_state=${cur%% *}
        cur_seq=${cur##* }
        if [ "$cur_state" = busy ] && [ "$cur_seq" -gt "$base_seq" ]; then
          printf 'empty turn-opened'
          return 0
        fi
      fi
      p=$((p + 1))
    done
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  if [ "$enter_ok" = 0 ]; then
    printf 'send-failed'
    return 0
  fi
  printf 'pending no-turn'
}

# fm_tmux_submit_semantic: the semantic submit confirm plus the bake-in
# cross-check. It reads the trusted baseline record; anything but an exact
# idle baseline returns the 'fallback not-idle-baseline' routing sentinel
# (the adapter then runs the labelled rendered-composer core), because an
# unchanged record can never confirm a delivery. On an idle baseline the
# core runs, and while FM_SUBMIT_SEMANTIC_COMPARE=1 (the bake-in default)
# the rendered composer is read once afterwards:
#   - turn-opened contradicted by a still-pending composer DOWNGRADES the
#     confirmation to unknown semantic-contradicted, so a mis-wired hook can
#     never mark an undelivered instruction delivered (and never suppress a
#     pending-reply escalation); the rendered signal can veto a
#     confirmation, never grant one.
#   - no-turn contradicted by a cleared composer stays unconfirmed.
# Both directions print the loud stderr warning and append the durable
# state/<id>.submit-disagreement record. Setting FM_SUBMIT_SEMANTIC_COMPARE=0
# ends the bake-in, after which this path performs no pane capture at all.
# Concurrent sends to one task are NOT serialised here; see the KNOWN GAPS
# note in the header (fm-submit-correlation owns it).
fm_tmux_submit_semantic() {  # <target> <text> <retries> <enter-sleep> <settle> <state-dir> <id> <harness>
  local target=$1 state=$6 id=$7 harness=$8 base base_seq out verdict reason composer
  base=$(fm_tmux_submit_record_read "$state" "$id" "$harness")
  if [ "$base" = none ] || [ "${base%% *}" != idle ]; then
    printf 'fallback not-idle-baseline'
    return 0
  fi
  base_seq=${base##* }
  out=$(fm_tmux_submit_semantic_core "$target" "$2" "$3" "$4" "$5" "$state" "$id" "$harness" "$base_seq")
  verdict=${out%% *}
  reason=${out#* }
  if [ "$verdict" != send-failed ] && [ "${FM_SUBMIT_SEMANTIC_COMPARE:-1}" = 1 ]; then
    composer=$(fm_tmux_composer_state "$target")
    case "$reason:$composer" in
      turn-opened:pending|turn-opened:pending-unproven)
        fm_tmux_submit_disagreement_record "$state" "$id" "$harness" "$reason" "$composer" downgraded
        echo "warning: SUBMIT-CONFIRM DISAGREEMENT for $id (harness=$harness): the lifecycle record reports a submitted turn, but the rendered composer still shows unsubmitted text; the confirmation is DOWNGRADED to unconfirmed because a mis-wired lifecycle hook can report submits that did not happen - inspect the pane, state/$id.busy-state, and state/$id.submit-disagreement" >&2
        out='unknown semantic-contradicted'
        ;;
      no-turn:empty)
        fm_tmux_submit_disagreement_record "$state" "$id" "$harness" "$reason" "$composer" reported
        echo "warning: SUBMIT-CONFIRM DISAGREEMENT for $id (harness=$harness): the rendered composer cleared, but no turn opened in the lifecycle record; the send is treated as UNCONFIRMED - inspect the pane, state/$id.busy-state, and state/$id.submit-disagreement before re-sending" >&2
        ;;
    esac
  fi
  printf '%s' "$out"
}
