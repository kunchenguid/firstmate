#!/usr/bin/env bash
# bin/fm-composer-lib.sh - the ONE fleet-wide owner of composer-content
# classification, shared by every session-provider adapter: the tmux path
# through bin/fm-tmux-lib.sh, and bin/backends/{herdr,orca,cmux}.sh directly.
#
# WHY THIS EXISTS (task fm-composer-shellglyph-safety): the four adapters each
# carried their own copy of the "is this composer row empty / pending / not an
# agent composer" decision, and the copies drifted. The dangerous drift: a BARE
# shell prompt glyph (`>`, `$`, `%`, `#`) - what a pane shows once its agent has
# exited to a plain login shell - was treated as an empty, ready-to-inject
# AGENT composer. The away-mode escalation injector (bin/fm-supervise-daemon.sh)
# reads composer-emptiness to decide whether a pane is a safe injection target,
# so a dead-shell pane misread as "empty" meant an escalation could be typed
# into (and, worst case, executed by) that shell. Consolidating the one decision
# here means the safety rule cannot silently drift across adapters again.
#
# THE SAFETY RULE this owner enforces: a bare shell prompt glyph is a genuine
# empty agent composer ONLY when it appears INSIDE a real agent-composer
# container - a bordered composer box, where the harness draws its own prompt
# glyph (e.g. claude's older `| > ... |`). On a bare, unstructured row it is a
# dead-shell prompt and is NEVER "empty"; it classifies as `unknown` (not a safe
# injection target). The AGENT prompt glyphs `❯` (claude), `›` (codex), `⟩`
# (U+27E9, muse), and `→` (cursor) are a genuine empty agent composer either
# way, bordered or bare. Every agent glyph must be listed in ALL THREE places
# below - the ghost-stripped-to-empty fallback, the bare-row case, and the
# leading-glyph strip - because a glyph present in only some of them classifies
# inconsistently depending on how its harness happens to colour the row.
#
# GHOST/PLACEHOLDER TEXT is the other half of this owner (task
# afk-herdr-false-pending): a harness fills an otherwise-empty composer with
# de-emphasized ghost text - claude's rotating prompt suggestion, codex's idle
# suggestion, grok's placeholder - which a plain capture cannot tell apart from
# text a human typed, so the away-mode injector reads the idle pane as "pending
# input" and defers every escalation (the overnight wedge that motivated this
# consolidation). fm_composer_strip_ghost is the ONE ANSI-aware extractor of
# "real typed content": it drops every de-emphasized run - dim/faint (SGR 2, how
# claude and codex render ghost text) AND a dark/muted TRUECOLOR foreground (how
# grok renders placeholder/hint text) - and keeps only normal-intensity,
# normally-coloured text. Consolidating it here means the two ANSI-capable
# adapters (tmux via bin/fm-tmux-lib.sh, herdr via bin/backends/herdr.sh) cannot
# drift into per-harness one-off strips again; the previous herdr-only faint
# byte-pattern check missed claude's own dim ghost (its prompt glyph is not
# bold-wrapped) and no adapter covered grok's truecolor placeholder at all.
#
# Each adapter still owns its own CAPTURE and structural row-finding, because
# those use genuinely different primitives (tmux's visible-pane box scan,
# herdr's ANSI tail scan, orca/cmux's plain read-screen). Once an adapter has a
# candidate composer row it hands the RAW styled row to
# fm_composer_strip_ghost for the real-typed-content extraction, strips the box
# borders, trims, and hands the result plus a <bordered> flag to
# fm_composer_classify_content for the shared
# empty|pending|unknown verdict. orca/cmux read a plain (unstyled) screen so
# they have no ghost styling to strip and rely on the idle-placeholder match
# below. Re-sourcing is a cheap idempotent redefinition, so this file needs no
# include guard (matching bin/fm-tmux-lib.sh).

# fm_composer_strip_ansi: drop every CSI escape sequence, leaving plain text.
# Used for STRUCTURAL row/shape detection, where ghost text must be KEPT so the
# composer box border or bare prompt glyph is still visible; content extraction
# uses fm_composer_strip_ghost instead. Reads the styled text on stdin and prints
# plain text (stdin-only, matching fm_composer_strip_ghost). The character class
# includes ':' so an ITU colon-form SGR (38:2::r:g:b) is stripped whole, not left
# with a dangling tail.
fm_composer_strip_ansi() {
  local esc; esc=$(printf '\033')
  LC_ALL=C sed "s/${esc}\\[[0-9;:?]*[[:alpha:]]//g"
}

# fm_composer_strip_ghost: the ONE fleet-wide ANSI-aware extractor of "real typed
# content" from a captured, styled composer row. Reads the styled line on stdin
# (from `tmux capture-pane -e` or `herdr pane read --format ansi`) and prints the
# plain, non-ghost text on stdout, dropping:
#   - dim/faint runs (SGR 2): how claude and codex render ghost/suggestion text.
#     A reset (SGR 0) or normal-intensity (SGR 22) ends a dim run.
#   - dark/muted TRUECOLOR foreground runs (SGR 38;2;r;g;b or the colon form
#     38:2::r:g:b) whose perceived luminance (0.299R + 0.587G + 0.114B) is below
#     FM_COMPOSER_GHOST_LUMA_MAX (default 128): how grok renders its placeholder
#     and hint text. A reset (SGR 0), a default-foreground (SGR 39), any base
#     foreground colour (30-37 / 90-97), or a lighter 38;2 foreground ends the
#     dark-foreground run. This assumes a DARK terminal theme, the firstmate
#     fleet reality, where real typed input is bright and only de-emphasised UI
#     is dark; the SGR-2 signal above stays theme-independent. A 256-colour
#     foreground (38;5;n) is NOT luminance-tested - it is palette-dependent and
#     no fleet harness uses it for ghost text, so it is kept (real text wins:
#     under-stripping merely defers, which the max-defer alarm surfaces, while
#     over-stripping would inject over real input).
# Raising FM_COMPOSER_GHOST_LUMA_MAX is not free: muse draws its `⟩` prompt glyph
# in truecolor 38;2;90;160;255, luminance ~149.9 (verified, muse 0.1.0-R708.1),
# the tightest margin over the 128 default in the fleet. Above ~150 that glyph is
# stripped as ghost text, which is why the bare-glyph fallback below must also
# recognise every agent glyph from the UNSTRIPPED plain row.
# The dim/faint and dark-foreground states are tracked together as "de-emphasis";
# codes are processed left to right within a sequence, so "ESC[0;2m" reads as dim.
# LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and de-emphasised
# runs alike pass through or drop intact without locale-dependent classes.
fm_composer_strip_ghost() {
  # Cursor reverse-video cursor-cell gap drop is harness-gated: verified only
  # against Cursor (tmux coalesced and Herdr split SGR forms). Non-Cursor
  # callers keep pre-Cursor strip semantics - reverse-video between dim runs
  # is never dropped as a cursor cell.
  local cursor_rev_gap=0
  [ "${FM_COMPOSER_HARNESS:-}" = cursor ] && cursor_rev_gap=1
  LC_ALL=C awk -v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}" -v cursor_rev_gap="$cursor_rev_gap" '
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
    # fg38_is_dark: 1 when the SGR 38 foreground starting at param p is a
    # TRUECOLOR (38;2 / 38:2) whose luminance is below lumamax; 0 otherwise
    # (a 38;5 palette colour, a bright truecolor, or a malformed run).
    function fg38_is_dark(a, p, k, lumamax,   spec, nf, f, r, g, b) {
      spec = a[p]
      if (index(spec, ":") > 0) {           # colon form: whole colour in a[p]
        nf = split(spec, f, ":")
        if (f[2] != "2" || nf < 5) return 0
        r = f[nf - 2] + 0; g = f[nf - 1] + 0; b = f[nf] + 0
        return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
      }
      if (p + 1 > k || a[p + 1] != "2" || p + 4 > k) return 0
      r = a[p + 2] + 0; g = a[p + 3] + 0; b = a[p + 4] + 0
      return ((299*r + 587*g + 114*b) / 1000 < lumamax) ? 1 : 0
    }
    {
      line = $0; out = ""; dim = 0; darkfg = 0; rev = 0; n = length(line); i = 1
      ghost_gap = 0; gap_buf = ""; gap_rev = 0
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
            if (j <= n && substr(line, j, 1) == "m") {   # SGR: update de-emphasis
              if (params == "") params = "0"
              # Before processing this SGR, flush any pending ghost gap buffer
              # if this SGR CHANGES de-emphasis (dim/darkfg). Color-only SGRs
              # (38, 48, 58) between the gap characters must NOT flush the
              # buffer, because they arrive before the real content and would
              # close the gap prematurely (cursor-agent reverse-video cursor
              # cell sits between a dim exit and a dim re-entry, with a
              # background-color SGR in between). The buffer is dropped on dim
              # re-entry ONLY when Cursor reverse-gap handling is armed and the
              # content was reverse-video-marked (SGR 7, how the observed
              # cursor cell is always rendered): a plain-text gap is real typed
              # content and survives, deferring injection rather than licensing
              # it over genuine input.
              if (ghost_gap) {
                # peek: is this a de-emphasis-changing SGR or a color-only SGR?
                # Must skip color payload parameters (38;2, 38;5, 48;2, 48;5,
                # 58;2, 58;5) so the "2" in a TRUECOLOR color spec is not
                # mistaken for a dim code. Two separate scans: one for
                # is_deemph (any de-emphasis code), one for dim_reentered
                # (code 2 after a code 0/22 reset). The scans are separate
                # because code "0" is de-emphasis but does NOT re-enter dim,
                # and code "2" may appear after code "0" in the same params.
                is_deemph = 0; dim_reentered = 0; dark_reentered = 0
                k_check = split(params, a_check, ";")
                for (p_check = 1; p_check <= k_check; p_check++) {
                  v_check = a_check[p_check]; code_check = sgr_code(v_check)
                  if (code_check == "38" || code_check == "48" || code_check == "58") {
                    if (code_check == "38" && fg38_is_dark(a_check, p_check, k_check, lumamax)) {
                      is_deemph = 1; dark_reentered = 1; break
                    }
                    p_check = skip_color_payload(a_check, p_check, k_check)
                    continue
                  }
                  if (code_check == "2") { is_deemph = 1; break }
                  if (code_check == "0" || code_check == "22") { is_deemph = 1; break }
                  if (code_check == "39") { is_deemph = 1; break }
                  if (code_check + 0 >= 30 && code_check + 0 <= 37) { is_deemph = 1; break }
                  if (code_check + 0 >= 90 && code_check + 0 <= 97) { is_deemph = 1; break }
                }
                if (is_deemph) {
                  # Compute the re-entry flags first (dim / dark-38 re-entry in
                  # this same sequence), then decide. A de-emphasis-END-ONLY
                  # SGR (0 / 22 / 39 / base fg, with no dim or dark-38 re-entry
                  # in the same sequence) must NOT flush an open reverse-video
                  # gap under Cursor: herdr relays the raw split SGR sequences
                  # (ESC[0m + ESC[2m) while tmux coalesces them (0;2m), and the
                  # intermediate bare reset would flush the cursor cell as real
                  # text before the dim re-entry arrives. The gap stays open
                  # until dim/dark re-entry (drop if gap_rev), rev-off (SGR 27,
                  # keeps text), or end-of-line / normal content (emit).
                  for (p_check = 1; p_check <= k_check; p_check++) {
                    v_check = a_check[p_check]; code_check = sgr_code(v_check)
                    if (code_check == "38" || code_check == "48" || code_check == "58") {
                      if (code_check == "38" && fg38_is_dark(a_check, p_check, k_check, lumamax)) {
                        dark_reentered = 1; break
                      }
                      p_check = skip_color_payload(a_check, p_check, k_check)
                      continue
                    }
                    if (code_check == "2") { dim_reentered = 1; break }
                  }
                  if (!(gap_rev && !dim_reentered && !dark_reentered)) {
                    # Not a split-sequence relay reset: flush the gap as before.
                    ghost_gap = 0
                    if ((dim_reentered || dark_reentered) && gap_rev) {
                      gap_buf = ""   # reverse-video gap content is the cursor cell, drop it
                    } else {
                      out = out gap_buf   # gap content is real, emit it
                    }
                    gap_buf = ""; gap_rev = 0
                  }
                  # else: de-emphasis-END-ONLY SGR on a reverse-video gap
                  # (split-sequence relay) - the gap stays open untouched.
                }
              }
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") {
                  if (!dim) { dim = 1; ghost_gap = 0; gap_buf = ""; gap_rev = 0 }
                } else if (code == "0") {
                  if (dim || darkfg) {
                    # Exiting de-emphasis: start a ghost gap buffer to
                    # capture potential reverse-video cursor cell.
                    ghost_gap = 1; gap_buf = ""; gap_rev = 0
                  }
                  dim = 0; darkfg = 0; rev = 0
                } else if (code == "22") {
                  if (dim) { ghost_gap = 1; gap_buf = ""; gap_rev = 0 }
                  dim = 0
                } else if (code == "7") {
                  rev = 1
                  # Mark reverse-video gaps only for Cursor: non-Cursor must
                  # never drop reverse-video content as a cursor cell.
                  if (ghost_gap && cursor_rev_gap) gap_rev = 1
                } else if (code == "27") {
                  rev = 0; gap_rev = 0
                } else if (code == "39") { darkfg = 0 }
                else if (code + 0 >= 30 && code + 0 <= 37) { darkfg = 0 }
                else if (code + 0 >= 90 && code + 0 <= 97) { darkfg = 0 }
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (ghost_gap) {
          gap_buf = gap_buf c
        } else if (dim == 0 && darkfg == 0) {
          out = out c
        }
        i++
      }
      # End of line: flush any remaining ghost gap buffer (no dim re-entry,
      # so the gap content is real).
      if (ghost_gap && gap_buf != "") out = out gap_buf
      print out
    }
  '
}

# fm_composer_classify_content: the single shared composer-content verdict.
#   <bordered> 1 when <content> came from a genuine agent-composer container (a
#              bordered composer box, or a structurally-identified bare AGENT
#              prompt row); 0 for a bare, unstructured row (e.g. tmux's raw
#              cursor line that carried no box border).
#   <content>  the candidate composer content, already border-stripped and
#              whitespace-trimmed by the caller.
#   [idle_re]  optional per-harness idle-placeholder regex (e.g. grok's
#              "Type a message...") that reads as empty; matched both before and
#              after a leading prompt glyph is stripped, so a pattern written
#              with or without the glyph both land.
#   [harness]  optional harness identity; bare Cursor arrow is empty only for
#              Cursor or a structurally bordered composer.
fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | grep -qE "$idle_re" ;;
  esac
}

# fm_composer_cursor_arrow_ok: the single owner of when a leading `→` may read
# as an agent composer at all. `→` is Cursor's own prompt glyph, but unlike the
# other agent glyphs it is a common bare decoration, so an unscoped bare arrow
# is never a safe injection target. Two things scope it: a bordered container
# proves the composer structurally, and a cursor harness identity proves the
# glyph is Cursor's. Every arrow verdict in the classifier routes through here.
fm_composer_cursor_arrow_ok() {  # <bordered> <harness>
  [ "$1" = 1 ] || [ "$2" = cursor ]
}

# fm_composer_strip_prompt_glyph: strip ONE leading prompt glyph plus the
# whitespace after it, then re-emit the row for a second idle-placeholder
# match. The four agent glyphs are always stripped; pass `all` to also strip
# the shell prompt glyphs, which is correct only where the caller has already
# decided a shell glyph could be the harness's own prompt.
#
# Literal prefixes rather than `?` wildcards: the agent glyphs are multibyte,
# and a character-count strip is only correct in a UTF-8 locale.
fm_composer_strip_prompt_glyph() {  # <content> [all]
  local content=$1 stripped=
  case "$content" in
    '→'*) content=${content#'→'}; stripped=1 ;;
    '❯'*) content=${content#'❯'}; stripped=1 ;;
    '›'*) content=${content#'›'}; stripped=1 ;;
    '⟩'*) content=${content#'⟩'}; stripped=1 ;;
  esac
  if [ -z "$stripped" ] && [ "${2:-}" = all ]; then
    case "$content" in
      '>'*|'$'*|'%'*|'#'*) content=${content#?} ;;
    esac
  fi
  printf '%s' "${content#"${content%%[![:space:]]*}"}"
}

fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content] [harness]
  local bordered=$1 content=$2 idle_re=${3:-} idle_case=${4:-sensitive} plain_content harness remainder arrow_leading=0
  plain_content=${5:-$content}
  harness=${6:-${FM_COMPOSER_HARNESS:-}}
  case "$plain_content" in '→'*) arrow_leading=1 ;; esac
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    # Ghost stripping emptied the row, so every byte was de-emphasised. A bare
    # de-emphasised row is a confirmed empty agent composer only when its
    # plain text (a leading agent glyph stripped) matches the harness idle
    # placeholder: cursor renders its `→` glyph dim together with
    # "Add a follow-up" (verified cursor-agent 2026.07.23-e383d2b). Any other
    # fully de-emphasised bare row - a dimmed shell prompt, a dimmed prompt
    # glyph alone - stays unknown: never a safe injection target.
    case "$plain_content" in
      '→'|'→ '*)
        remainder=${plain_content#'→'}
        remainder="${remainder#"${remainder%%[![:space:]]*}"}"
        if [ -z "$remainder" ]; then
          if [ "$harness" = cursor ]; then printf 'empty'; else printf 'unknown'; fi
          return 0
        fi
        ;;
    esac
    plain_content=$(fm_composer_strip_prompt_glyph "$plain_content")
    if { [ "$arrow_leading" -eq 0 ] || fm_composer_cursor_arrow_ok "$bordered" "$harness"; } \
      && fm_composer_idle_matches "$plain_content" "$idle_re" "$idle_case"; then
      printf 'empty'
    else
      printf 'unknown'
    fi
    return 0
  fi
  # A bare prompt glyph on its own row.
  case "$content" in
    '→')
      if fm_composer_cursor_arrow_ok "$bordered" "$harness"; then
        printf 'empty'
      else
        printf 'unknown'
      fi
      return 0 ;;
    '❯'|'›'|'⟩') printf 'empty'; return 0 ;;
    '>'|'$'|'%'|'#')
      # Shell prompt glyph: empty ONLY inside a composer box (the harness's own
      # prompt). Bare, it is a dead-shell prompt - never a safe injection target.
      if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
      return 0 ;;
  esac
  # Nothing on the row = empty composer.
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched before a leading glyph is stripped).
  case "$content" in '→'*) arrow_leading=1 ;; esac
  if { [ "$arrow_leading" -eq 0 ] || fm_composer_cursor_arrow_ok "$bordered" "$harness"; } \
    && fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph, then re-judge the remainder.
  content=$(fm_composer_strip_prompt_glyph "$content" all)
  content="${content%"${content##*[![:space:]]}"}"
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched again after the leading glyph was stripped,
  # e.g. "❯ Type a message...").
  if { [ "$arrow_leading" -eq 0 ] || fm_composer_cursor_arrow_ok "$bordered" "$harness"; } \
    && fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  if [ "$arrow_leading" -eq 1 ] && ! fm_composer_cursor_arrow_ok "$bordered" "$harness" \
    && fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'unknown'; return 0
  fi
  # Real, unsubmitted content remains.
  printf 'pending'; return 0
}

# fm_composer_export_env: set and export the composer-classification env
# contract for one harness, so every caller that drives the shared classifier
# through a subprocess (bin/fm-send.sh, bin/fm-supervise-daemon.sh) agrees on
# the per-harness defaults. cursor-agent renders its bare `→` prompt glyph AND
# its "Add a follow-up" idle placeholder fully de-emphasised, so after ghost
# stripping only FM_COMPOSER_IDLE_RE can prove that composer empty. An idle
# regex the caller already supplied always wins; other harnesses keep their
# verified bare/bordered glyph routes and leave the override unset.
fm_composer_export_env() {  # <harness>
  local harness=$1
  if [ -z "${FM_COMPOSER_IDLE_RE:-}" ] && [ "$harness" = cursor ]; then
    FM_COMPOSER_IDLE_RE='^Add a follow-up$'
  fi
  FM_COMPOSER_HARNESS=$harness
  export FM_COMPOSER_HARNESS FM_COMPOSER_IDLE_RE
}

# fm_composer_queued_submit_verdict: the ONE owner of the exhausted-retry rule
# for a submit loop that ran out of retries with the composer still proven
# pending. Only opencode and cursor have verified Enter-while-busy queuing
# (opencode 1.18.4, cursor-agent 2026.07.23-e383d2b): on those harnesses an
# affirmatively busy pane means the harness accepted the Enter and queued the
# message for the end of the current turn, so the send counts as delivered.
# Every other harness - and a busy probe that cannot affirm busy - keeps
# pending, so a genuine swallow on an idle pane stays a loud failure.
#
# The busy probe stays backend-specific and is passed as a command that returns
# 0 for busy. It is only run for a queueing harness, so no other harness pays
# for a probe whose answer cannot change the verdict.
fm_composer_queued_submit_verdict() {  # <harness> <busy-probe-cmd> [args...] -> empty|pending
  local harness=$1
  shift
  case "$harness" in
    opencode|cursor) ;;
    *) printf 'pending'; return 0 ;;
  esac
  if "$@"; then printf 'empty'; else printf 'pending'; fi
}
