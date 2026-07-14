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
# those use genuinely different primitives (tmux's cursor-row read, herdr's ANSI
# tail scan, orca/cmux's plain read-screen). Once an adapter has a candidate
# composer row it hands the RAW styled row to fm_composer_strip_ghost for the
# real-typed-content extraction, strips the box borders, trims, and hands the
# result plus a <bordered> flag to fm_composer_classify_content for the shared
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

# THE AGENT PROMPT GLYPH SET: the prompt glyphs a harness draws in its own
# composer - `❯` (claude) and `›` (codex) - as a WHITESPACE-SEPARATED list of
# LITERAL glyphs, never a regex. A regex form cannot be made safe here: under a
# C/POSIX locale (what bin/fm-supervise-daemon.sh runs with) an ERE bracket
# expression over multibyte glyphs degenerates into the BYTE class
# {E2,9D,AF,80,BA}, and since every box-drawing glyph starts with byte E2, a
# composer box's own border row matches as a prompt row. A literal set compared
# with a bash `case` matches whole strings and is locale-invariant, so it is the
# only form this owner accepts. An adapter that recognizes a further harness's
# prompt glyph extends the set and passes it in (bin/backends/herdr.sh threads
# FM_BACKEND_HERDR_BARE_PROMPT_GLYPHS through), so an adapter's structural row
# detection and this classification can never disagree about which glyphs are
# agent prompts - a glyph honored for detection but not for classification would
# leave that harness's idle composer stuck on `pending` forever, wedging away-mode
# injection behind input that was never there.
# SHELL prompt glyphs (`>`, `$`, `%`, `#`) are deliberately NOT part of this set
# and are never configurable: the safety rule at the top of this file turns on
# telling them apart from agent glyphs. That is ENFORCED, not merely stated, and
# in two independent layers - because a shell glyph accepted into the set would
# make a dead-shell prompt read `empty`, handing the away-mode injector the exact
# target this owner exists to deny it:
#   1. fm_composer_sanitize_agent_glyphs rejects a shell glyph out of any set
#      read from the environment, loudly, naming the glyph - and never leaves the
#      set EMPTY doing so, because an empty set would trade the dead-shell hazard
#      for the false-pending one (see that function).
#   2. fm_composer_classify_content evaluates the hardcoded shell-glyph rule
#      BEFORE the configurable agent-glyph match, so even a set handed straight
#      to it by a caller cannot promote a bare shell prompt to `empty`.
FM_COMPOSER_SHELL_GLYPHS='> $ % #'
FM_COMPOSER_AGENT_GLYPHS_DEFAULT='❯ ›'

# fm_composer_sanitize_agent_glyphs: print <set> with every SHELL prompt glyph
# removed, warning once per rejected glyph on stderr. Applied to every agent glyph
# set read from the environment (the fleet-wide knob below, and each adapter's own
# knob), so an operator adding a harness whose composer prompt happens to be
# shell-shaped cannot silently disarm the dead-shell rule.
#
# It NEVER prints an empty set. When nothing survives the rejection - an operator
# set made only of shell glyphs, or an empty one - the built-in
# FM_COMPOSER_AGENT_GLYPHS_DEFAULT is printed instead and the substitution is
# announced. An empty set is not a safe degenerate: with no agent glyphs, a leading
# `❯`/`›` is never matched and never stripped, so every real idle claude/codex
# composer stops reading `empty` and reads `pending` forever. The away-mode injector
# needs an affirmative `empty` to inject, so it would then defer every escalation -
# the false-PENDING wedge, the same failure this owner exists to prevent from the
# other direction. Rejecting a shell glyph must not cost the agent glyphs with it.
# The set is split with pathname expansion disabled, so a glob character in an
# operator-supplied set stays literal (same idiom as fm_composer_leading_agent_glyph).
fm_composer_sanitize_agent_glyphs() {  # <set>
  local g out='' shell_g restore_glob=0
  case $- in *f*) : ;; *) restore_glob=1 ;; esac
  set -f
  # shellcheck disable=SC2086  # deliberate split: the glyph set is whitespace-separated
  set -- $1
  if [ "$restore_glob" = 1 ]; then set +f; fi
  for g in "$@"; do
    [ -n "$g" ] || continue
    for shell_g in $FM_COMPOSER_SHELL_GLYPHS; do
      if [ "$g" = "$shell_g" ]; then
        printf '%s\n' \
          "firstmate: WARNING: shell prompt glyph '$g' was REJECTED from an agent prompt glyph set." \
          "firstmate: a bare '$g' is a DEAD SHELL, not an empty agent composer; reading it as empty would let the away-mode injector type an escalation into that shell (bin/fm-composer-lib.sh)." >&2
        continue 2
      fi
    done
    out="${out:+$out }$g"
  done
  if [ -z "$out" ]; then
    printf '%s\n' \
      "firstmate: WARNING: an agent prompt glyph set contained no usable agent glyphs; falling back to the built-in default '$FM_COMPOSER_AGENT_GLYPHS_DEFAULT'." \
      "firstmate: an empty set would stop every idle agent composer from reading as empty, so away-mode would defer every escalation behind input that was never there (bin/fm-composer-lib.sh)." >&2
    out=$FM_COMPOSER_AGENT_GLYPHS_DEFAULT
  fi
  printf '%s' "$out"
}

# Sanitize FIRST, then let the sanitizer's own non-empty guarantee supply the
# fallback: a `:-DEFAULT` expansion here would only cover an UNSET knob, and a knob
# set to a shell-glyph-only value is non-empty, so it would sail past the expansion
# and collapse to an empty set inside the sanitizer instead.
FM_COMPOSER_AGENT_GLYPHS=$(fm_composer_sanitize_agent_glyphs \
  "${FM_COMPOSER_AGENT_GLYPHS:-$FM_COMPOSER_AGENT_GLYPHS_DEFAULT}")

# fm_composer_leading_agent_glyph: set FM_COMPOSER_MATCHED_GLYPH to the agent
# prompt glyph <content> starts with and return 0; return 1 and clear it when it
# starts with none. [glyphs] overrides the glyph set for this call. The set is
# split on ASCII whitespace, and pathname expansion is disabled around the split
# so a glob character in an operator-supplied set stays literal.
fm_composer_leading_agent_glyph() {  # <content> [glyphs]
  local content=$1 glyphs=${2:-$FM_COMPOSER_AGENT_GLYPHS} g restore_glob=0
  FM_COMPOSER_MATCHED_GLYPH=''
  [ -n "$content" ] || return 1
  case $- in *f*) : ;; *) restore_glob=1 ;; esac
  set -f
  # shellcheck disable=SC2086  # deliberate split: the glyph set is whitespace-separated
  set -- $glyphs
  if [ "$restore_glob" = 1 ]; then set +f; fi
  for g in "$@"; do
    case "$content" in
      "$g"*) FM_COMPOSER_MATCHED_GLYPH=$g; return 0 ;;
    esac
  done
  return 1
}

# fm_composer_idle_matches: does <content> match the harness's idle-placeholder
# regex? This is the one place in this owner that still needs real regex
# semantics, so it is the one place that still reaches grep - and the grep is
# pinned to LC_ALL=C so the verdict cannot depend on the ambient locale. Without
# the pin the same pattern can read `empty` in an interactive UTF-8 shell and
# `pending` inside bin/fm-supervise-daemon.sh, which runs under a C/POSIX locale:
# a pattern is tested by hand, looks right, and then silently wedges away-mode.
# Pinning costs no expressiveness - a LITERAL multibyte glyph still matches its
# own bytes under C - it only rules out a bracket class over multibyte glyphs,
# which is unusable here regardless (see the glyph-set comment above).
fm_composer_idle_matches() {
  local content=$1 idle_re=$2 idle_case=$3
  [ -n "$idle_re" ] || return 1
  case "$idle_case" in
    insensitive) printf '%s' "$content" | LC_ALL=C grep -qiE "$idle_re" ;;
    *) printf '%s' "$content" | LC_ALL=C grep -qE "$idle_re" ;;
  esac
}

# fm_composer_classify_content: the single shared composer-content verdict.
#   <bordered> 1 when <content> came from a genuine agent-composer container (a
#              bordered composer box, or a structurally-identified bare AGENT
#              prompt row); 0 for a bare, unstructured row (e.g. tmux's raw
#              cursor line that carried no box border).
#   <content>  the candidate composer content, already border-stripped and
#              whitespace-trimmed by the caller.
#   [idle_re]  optional per-harness idle-placeholder regex (e.g. grok's
#              "Type a message...") that reads as empty. Write it WITHOUT a
#              leading prompt glyph: the glyph is stripped before the pattern is
#              matched a second time, so the bare placeholder text is what needs
#              to match. A pattern that does name a glyph must spell it as a
#              LITERAL (or an alternation of literals), NEVER as a bracket class -
#              `[❯›]` degenerates into the byte class {E2,9D,AF,80,BA} under the
#              C/POSIX locale this match is pinned to, matching any byte of any
#              box-drawing glyph and none of the glyphs it names.
#   [glyphs]   optional agent prompt glyph set for this caller, defaulting to
#              FM_COMPOSER_AGENT_GLYPHS. An adapter whose structural row
#              detection recognizes an extra harness glyph MUST pass the same set
#              here, or that harness's idle composer never classifies empty. A
#              SHELL glyph in this set is inert: the shell rule below is evaluated
#              first, so it can never promote a dead shell to `empty`.

fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content] [glyphs]
  local bordered=$1 content=$2 idle_re=${3:-} idle_case=${4:-sensitive} plain_content glyphs
  plain_content=${5:-$content}
  glyphs=${6:-$FM_COMPOSER_AGENT_GLYPHS}
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    # Shell rule first, exactly as below: this row is unbordered by construction,
    # so a bare shell glyph is a dead shell whatever the glyph set claims.
    case "$plain_content" in
      '>'|'$'|'%'|'#') printf 'unknown'; return 0 ;;
    esac
    if fm_composer_leading_agent_glyph "$plain_content" "$glyphs" \
      && [ "$FM_COMPOSER_MATCHED_GLYPH" = "$plain_content" ]; then
      printf 'empty'; return 0
    fi
    printf 'unknown'; return 0
  fi
  # A bare prompt glyph on its own row. The SHELL rule is hardcoded and is
  # evaluated BEFORE the configurable agent-glyph match below, so a shell glyph
  # that reached the set anyway - past fm_composer_sanitize_agent_glyphs, e.g.
  # handed straight to this function by a caller - still cannot make a dead shell
  # read `empty`. Neither guard is load-bearing alone.
  case "$content" in
    '>'|'$'|'%'|'#')
      # Shell prompt glyph: empty ONLY inside a composer box (the harness's own
      # prompt). Bare, it is a dead-shell prompt - never a safe injection target.
      if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
      return 0 ;;
  esac
  if fm_composer_leading_agent_glyph "$content" "$glyphs" \
    && [ "$FM_COMPOSER_MATCHED_GLYPH" = "$content" ]; then
    # Agent prompt glyph: a genuine empty agent composer, bordered or bare.
    printf 'empty'; return 0
  fi
  # Nothing on the row = empty composer.
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched before a leading glyph is stripped).
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph, then re-judge the remainder. Match and remove
  # the exact glyph literal, not a character count: under a C/POSIX locale
  # ${content#?} counts a single BYTE, so it would leave two stray bytes of the
  # 3-byte ❯ behind and misread an idle composer as pending. The whitespace trim
  # below drops any space that followed the glyph. At most ONE leading glyph is
  # stripped, so a shell glyph is only considered when no agent glyph led the row.
  if fm_composer_leading_agent_glyph "$content" "$glyphs"; then
    content=${content#"$FM_COMPOSER_MATCHED_GLYPH"}
  else
    case "$content" in
      '>'*) content=${content#'>'} ;;
      '$'*) content=${content#'$'} ;;
      '%'*) content=${content#'%'} ;;
      '#'*) content=${content#'#'} ;;
    esac
  fi
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
