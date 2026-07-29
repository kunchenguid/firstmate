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

# FM_COMPOSER_BLANKS: the non-ASCII blank characters a harness can leave in an
# otherwise-empty composer, as raw UTF-8 byte literals. Terminal captures are
# UTF-8 regardless of the shell's locale, and fm_composer_trim strips these as
# whole literal strings, so the set stays correct under LC_ALL=C too - a byte
# class would be wrong here, because U+202F (E2 80 AF) and U+2000 (E2 80 80)
# share their lead byte with the claude prompt glyph ❯ (U+276F, E2 9D AF).
# Every Unicode space separator (Zs) plus the two zero-width characters that
# render as nothing: U+200B and U+FEFF.
FM_COMPOSER_BLANKS=(
  $'\xc2\xa0'                                     # U+00A0 no-break space
  $'\xe1\x9a\x80'                                 # U+1680 ogham space mark
  $'\xe2\x80\x80' $'\xe2\x80\x81' $'\xe2\x80\x82' # U+2000 U+2001 U+2002
  $'\xe2\x80\x83' $'\xe2\x80\x84' $'\xe2\x80\x85' # U+2003 U+2004 U+2005
  $'\xe2\x80\x86' $'\xe2\x80\x87' $'\xe2\x80\x88' # U+2006 U+2007 U+2008
  $'\xe2\x80\x89' $'\xe2\x80\x8a'                 # U+2009 U+200A
  $'\xe2\x80\x8b'                                 # U+200B zero-width space
  $'\xe2\x80\xaf'                                 # U+202F narrow no-break space
  $'\xe2\x81\x9f'                                 # U+205F medium mathematical space
  $'\xe3\x80\x80'                                 # U+3000 ideographic space
  $'\xef\xbb\xbf'                                 # U+FEFF zero-width no-break space
)

# fm_composer_trim: the ONE fleet-wide blank trim for composer content. Strips
# leading and trailing ASCII whitespace AND the Unicode blanks above, which
# `[[:space:]]` does not cover (glibc classifies U+00A0 as printable, not space).
# That gap was the away-mode wedge of task fm-afk-wedge-bgjob-pane: claude's
# current CLI draws its idle composer as an unbordered `❯` followed by U+00A0,
# the residual no-break space survived the ASCII trim and read as typed text, so
# every escalation deferred instead of being delivered. Interior blanks are left
# alone, so real typed text is never rewritten - only the ends are normalised.
# Locale scope, measured rather than assumed: the FM_COMPOSER_BLANKS step below
# matches whole literal UTF-8 byte strings and is locale-independent, which is
# what keeps U+202F from being confused with the lead byte of `❯`. The ASCII step
# still uses `[[:space:]]`, which glibc widens in a UTF-8 locale to U+2028 and
# U+2029 - neither is in FM_COMPOSER_BLANKS - so a row whose only trailing
# character is one of those two classifies differently under LC_ALL=C.UTF-8 than
# under LC_ALL=C. That is pre-existing behaviour, measured identically on
# fork/main and here, and is recorded as a residual gap in the composer-emptiness
# contract in docs/herdr-backend.md rather than closed here.
fm_composer_trim() {  # <text> -> <text> without leading/trailing blanks
  local s=$1 prev b
  while [ -n "$s" ]; do
    prev=$s
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    for b in "${FM_COMPOSER_BLANKS[@]}"; do
      while [ -n "$s" ] && [ "${s#"$b"}" != "$s" ]; do s=${s#"$b"}; done
      while [ -n "$s" ] && [ "${s%"$b"}" != "$s" ]; do s=${s%"$b"}; done
    done
    if [ "$s" = "$prev" ]; then break; fi   # `if`, not `&&`: set -e safe
  done
  printf '%s' "$s"
}

fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | grep -qE "$idle_re" ;;
  esac
}

# fm_composer_classify_content: the single shared composer-content verdict.
#   <bordered> 1 when <content> came from a genuine composer CONTAINER - a
#              bordered composer box, or herdr's native Pi separator pair, which
#              is the container-equivalent. 0 for any row not proven to be inside
#              such a container, including tmux's raw cursor line and a
#              structurally matched bare AGENT prompt row (herdr's `bare` shape,
#              which passes 0).
#              The bare shape deliberately stays 0: `bordered` decides the
#              verdict for a row that only Unicode-blank trimming emptied, so
#              promoting it to 1 would make such a row read `empty` instead of
#              `unknown`, which moves an injection-permitting boundary rather
#              than deferring.
#              A bare row that still carries its agent glyph reads `empty` through
#              the glyph case below - measured and unchanged.
#   <content>  the candidate composer content, already border-stripped by the
#              caller. The owner re-trims it through fm_composer_trim, so
#              Unicode blanks in the CONTENT are handled here, once, rather than
#              per adapter.
#   [idle_re]  optional per-harness idle-placeholder regex (e.g. grok's
#              "Type a message...") that reads as empty; matched both before and
#              after a leading prompt glyph is stripped, so a pattern written
#              with or without the glyph both land.
#
# SCOPE OF THE BLANK NORMALISATION: fm_composer_trim removes blanks from the
# LEADING and TRAILING positions of the content only, and never interior ones.
# A row holding just a known agent prompt glyph plus blanks therefore reads
# `empty`, while a blank inside real text leaves that row `pending` - so a
# no-break space in a half-typed human line never makes the pane a safe
# injection target.
# The trim also never widens the empty-row verdict: a row an ASCII trim already
# emptied keeps the reading it had before this trim existed, and only a row
# emptied purely by Unicode-blank trimming needs a composer container to read
# `empty`.
# Each adapter's own structural row detection runs BEFORE this classifier, so
# whether a given row reaches here at all is the adapter's decision, not this
# owner's.
# The composer-emptiness contract in docs/herdr-backend.md - "Composer-emptiness
# safety" and "Incident (2026-07-26): away-mode never delivered because claude's
# idle composer ends in a no-break space" - is the single owner of the
# per-backend verdict matrix, the residual structural gap, and the measured
# bounds.
fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content]
  local bordered=$1 content=$2 idle_re=${3:-} idle_case=${4:-sensitive} plain_content
  local ascii_only
  plain_content=${5:-$content}
  # What an ASCII-ONLY trim would have left, captured before the Unicode-aware
  # trim runs. A non-empty
  # remainder here on a row that trims to nothing means the row became empty ONLY
  # because Unicode blanks were removed - the one new permission this trim would
  # otherwise create, which the empty-row decision below declines. The class is
  # spelled out as literal ASCII whitespace (space, tab, newline, VT, FF, CR)
  # rather than `[[:space:]]`, which glibc widens to U+2003/U+3000 and friends in
  # a UTF-8 locale: that would silently grant the new permission in one locale and
  # decline it in another, on the decision that gates injection. That spelling
  # scopes this remainder only - fm_composer_trim's own ASCII step still uses
  # `[[:space:]]`, so the pre-existing U+2028/U+2029 locale divergence noted on
  # that function is unchanged by it.
  ascii_only=${content#"${content%%[!$' \t\n\v\f\r']*}"}
  ascii_only=${ascii_only%"${ascii_only##*[!$' \t\n\v\f\r']}"}
  content=$(fm_composer_trim "$content")
  # plain_content is deliberately NOT trimmed: the branch below asks whether the
  # RAW row carried anything at all, so emptying it here would let a blanks-only
  # plain row skip that branch and reach the empty-row decision as `empty` - an
  # injection-permitting flip against pre-branch behaviour.
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
  # Nothing on the row. Inside a composer container that is an empty composer.
  # Outside one, the verdict is scoped to what this trim changed: a row that an
  # ASCII trim already emptied keeps its long-standing `empty` reading, which is
  # what keeps a container-less composer such as Pi deliverable on the tmux path,
  # while a row emptied only by Unicode-blank trimming defers as `unknown`.
  if [ -z "$content" ]; then
    if [ "$bordered" = 1 ]; then printf 'empty'
    elif [ -n "$ascii_only" ]; then printf 'unknown'
    else printf 'empty'
    fi
    return 0
  fi
  # Known idle placeholder (matched before a leading glyph is stripped).
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph, then re-judge the remainder. The multibyte
  # agent glyphs are removed as literal strings, never with `?`, which matches a
  # single BYTE under LC_ALL=C and would leave an invalid UTF-8 tail; any blank
  # that followed the glyph is removed by the trim below.
  case "$content" in
    '❯'*) content=${content#'❯'} ;;
    '›'*) content=${content#'›'} ;;
    '>'*|'$'*|'%'*|'#'*) content=${content#?} ;;
  esac
  content=$(fm_composer_trim "$content")
  # Known idle placeholder (matched again after the leading glyph was stripped,
  # e.g. "❯ Type a message...").
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Real, unsubmitted content remains.
  printf 'pending'; return 0
}
