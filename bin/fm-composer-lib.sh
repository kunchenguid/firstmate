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
# injection target). The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a
# genuine empty agent composer either way, bordered or bare.
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
# The dim/faint and dark-foreground states are tracked together as "de-emphasis";
# codes are processed left to right within a sequence, so "ESC[0;2m" reads as dim.
# LC_ALL=C makes awk walk bytes, so multibyte glyphs (e.g. ❯) and de-emphasised
# runs alike pass through or drop intact without locale-dependent classes.
fm_composer_strip_ghost() {
  LC_ALL=C awk -v lumamax="${FM_COMPOSER_GHOST_LUMA_MAX:-128}" '
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
      line = $0; out = ""; dim = 0; darkfg = 0; n = length(line); i = 1
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
              k = split(params, a, ";")
              for (p = 1; p <= k; p++) {
                v = a[p]; code = sgr_code(v)
                if (code == "38") {
                  darkfg = fg38_is_dark(a, p, k, lumamax)
                  p = skip_color_payload(a, p, k)
                } else if (code == "48" || code == "58") {
                  p = skip_color_payload(a, p, k)
                } else if (code == "2") dim = 1
                else if (code == "0") { dim = 0; darkfg = 0 }
                else if (code == "22") dim = 0
                else if (code == "39") darkfg = 0
                else if (code + 0 >= 30 && code + 0 <= 37) darkfg = 0
                else if (code + 0 >= 90 && code + 0 <= 97) darkfg = 0
              }
            }
            if (j <= n) { i = j + 1; continue }
          }
          i = i + 1; continue          # lone/other ESC: drop the ESC byte only
        }
        if (dim == 0 && darkfg == 0) out = out c   # keep only non-de-emphasised bytes
        i++
      }
      print out
    }
  '
}

# NON-ASCII BLANKS are the third concern this owner carries (task
# fm-send-false-negative-herdr): a harness may pad its composer with a Unicode
# blank instead of an ASCII space, and every trim in this file and in the
# adapters uses `[[:space:]]`, which under the fleet's C locale matches ASCII
# whitespace ONLY. Verified live on 2026-08-04: claude 2.x renders its EMPTY
# composer as the prompt glyph followed by U+00A0 NO-BREAK SPACE (bytes
# `e2 9d af c2 a0`), so the trim left a bare U+00A0 behind, the content never
# equalled the bare glyph, and a genuinely empty claude composer classified as
# `pending`. That permanent false "unsubmitted text" made the away-mode injector
# defer every escalation on a claude+herdr pane and made every fm-send to a BUSY
# claude+herdr pane report a swallowed Enter that had actually landed.
# fm_composer_classify_content normalizes these blanks to spaces before it
# judges, so the existing empty/glyph/idle rules apply unchanged.
# Which adapters SEE the pad is a capture-layer fact, not a classifier one:
# herdr's `pane read --format ansi` returns the U+00A0 verbatim, while
# `tmux capture-pane` normalizes it to an ASCII space, so the same claude
# release reached this classifier padded on one backend and unpadded on the
# other. Normalizing here keeps the verdict identical either way instead of
# leaving it dependent on which backend happened to read the pane.
# Only glyphs OBSERVED in a real fleet harness composer belong in the list
# below; each entry is an empirical fact, not a guess, because widening it
# widens what counts as an empty (safe-to-inject) composer.
# Each entry is one whole glyph, held as its exact UTF-8 BYTES. The list is an
# array rather than one string because a multibyte glyph cannot be walked
# character by character in a locale-independent way: under LC_CTYPE=C a
# substring expansion would split U+00A0 into its lead byte 0xC2 and replace
# every 0xC2 in the row instead, corrupting unrelated multibyte text.
FM_COMPOSER_BLANKS=("$(printf '\xc2\xa0')")   # U+00A0, claude 2.x's empty-composer pad

# fm_composer_normalize_blanks: map every FM_COMPOSER_BLANKS glyph in <text> to
# an ASCII space and trim the result, so an all-blank composer collapses to the
# empty string and a padded prompt glyph collapses to the bare glyph.
fm_composer_normalize_blanks() {  # <text>
  local text=$1 blank
  for blank in "${FM_COMPOSER_BLANKS[@]}"; do
    text=${text//"$blank"/ }
  done
  text="${text#"${text%%[![:space:]]*}"}"
  printf '%s' "${text%"${text##*[![:space:]]}"}"
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
fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | grep -qE "$idle_re" ;;
  esac
}

fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content]
  local bordered=$1 content=$2 idle_re=${3:-} idle_case=${4:-sensitive} plain_content
  plain_content=${5:-$content}
  # Callers trim with ASCII-only [[:space:]], so a harness's non-ASCII composer
  # padding survives their trim and would otherwise read as real typed text.
  content=$(fm_composer_normalize_blanks "$content")
  plain_content=$(fm_composer_normalize_blanks "$plain_content")
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    case "$plain_content" in
      '❯'|'›') printf 'empty'; return 0 ;;
      *) printf 'unknown'; return 0 ;;
    esac
  fi
  # A bare prompt glyph on its own row.
  case "$content" in
    '❯'|'›')
      # Agent prompt glyph: a genuine empty agent composer, bordered or bare.
      printf 'empty'; return 0 ;;
    '>'|'$'|'%'|'#')
      # Shell prompt glyph: empty ONLY inside a composer box (the harness's own
      # prompt). Bare, it is a dead-shell prompt - never a safe injection target.
      if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
      return 0 ;;
  esac
  # Nothing on the row = empty composer.
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched before a leading glyph is stripped).
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph, then re-judge the remainder.
  case "$content" in
    '❯ '*|'› '*|'> '*|'$ '*|'% '*|'# '*) content=${content#??} ;;
    '❯'*|'›'*|'>'*|'$'*|'%'*|'#'*) content=${content#?} ;;
  esac
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched again after the leading glyph was stripped,
  # e.g. "❯ Type a message...").
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Real, unsubmitted content remains.
  printf 'pending'; return 0
}
