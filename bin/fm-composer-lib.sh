#!/usr/bin/env bash
# bin/fm-composer-lib.sh - the ONE fleet-wide owner of composer classification:
# every shape a verified harness draws, every glyph, every container proof, and
# the empty|pending|pending-unproven|unknown verdict, shared by every
# session-provider adapter (tmux via bin/fm-tmux-lib.sh, and
# bin/backends/{herdr,orca,cmux,zellij}.sh) and by fm-spawn.sh's kimi
# launch-readiness check.
#
# WHY THIS EXISTS (tasks fm-composer-shellglyph-safety and
# fm-composer-thin-adapter-refactor-r1): the adapters each carried their own
# copy of composer shape knowledge, and every copy drifted. The audited result
# (data/fm-composer-consolidation-audit-s1) was a 5-adapter x 6-harness matrix
# in which no adapter was right about more than five harnesses, no two adapters
# were wrong in the same places, and one harness was unreadable everywhere.
# The consolidation rule that prevents a recurrence: an adapter CAPTURES a
# screen and DESCRIBES its capabilities; it never classifies. A new harness
# shape is taught to fm_composer_classify_screen below, once, and every backend
# that can capture a screen learns it in the same commit.
#
# THE CAPABILITY MODEL: adapters differ in what their capture primitive can
# see, and those differences enter here as DATA (the <caps> argument), never as
# adapter code. Capability differences change how CONFIDENTLY a shape can be
# judged; they never change what the shapes ARE:
#   styled=1    the capture preserves ANSI styling, so ghost/placeholder text
#               is detectable and can be stripped (tmux -e, herdr --format
#               ansi, zellij dump-screen --ansi). With styled=0 (cmux, orca)
#               ghost text is unreadable, so a bare glyph row or left-bar row
#               carrying trailing non-idle text degrades to `unknown` rather
#               than `pending`: the text may be the harness's own idle
#               suggestion, and a false `pending` blocks every safe caller.
#   cursor=1    a cursor row is supplied (tmux #{cursor_y} only). The cursor
#               anchors shape selection: the shape containing the cursor is the
#               composer. Without it, the bottom-most shape wins.
#   identity=1  a native agent identity/state probe exists (herdr `agent get`;
#               the tmux pi foreground-process probe). Identity is what makes
#               Pi's blank separated composer provable; with identity=0 that
#               shape stays `unknown`.
#   rows=<n>    the capture's bounded row count (informational).
#
# THE STRICT BLANK-ROW RULE (captain decision blank-row-injection-posture,
# 2026-08-09): a blank or otherwise unidentified input row with no positive
# container proof is `unknown` and callers defer. This replaced tmux's
# permissive "blank cursor row = empty = safe to inject" rule fleet-wide: a
# blank row under the cursor can be a modal dialog, a dead shell between
# transcript rules, or a mid-redraw pane, and the away-mode injector types
# escalations into whatever it calls empty. Positive container proof means one
# of the shapes in the catalogue below.
#
# THE SHAPE CATALOGUE (all verified against real harnesses; byte-level
# captures in data/fm-composer-consolidation-audit-s1/report.md and
# docs/verification/runtime-backends.md):
#   bordered   - a complete boxed composer: a top border, side-bordered content
#                rows of the same family, and a bottom border (grok, kimi,
#                older claude). The bottom border may carry a TITLE (grok
#                writes its model name there); a titled bottom border that
#                still starts and ends with the family's rule glyph is
#                tolerated, not ambiguity.
#   bare       - an agent prompt glyph row with no border at all (claude `❯`,
#                codex `›`, muse `⟩`). The agent glyph is itself the container
#                proof; a bare SHELL glyph (`>` `$` `%` `#`) never is.
#   left-bar   - opencode: rows prefixed by a heavy left bar `┃` with no
#                closing border, holding the idle hint, blank rows, and a
#                mode/model footer line.
#   separated  - pi: content rows between two solid horizontal `─` rules, no
#                glyph and no side border. Provable only with a live agent
#                identity reporting an idle/done/blocked pi (herdr `agent
#                get`; the tmux foreground-process probe), because a blank
#                region between two transcript rules is otherwise exactly the
#                strict rule's unidentifiable blank row.
#
# THE SAFETY RULE for glyphs: a bare shell prompt glyph (`>` `$` `%` `#`) -
# what a pane shows once its agent has exited to a plain login shell - is a
# genuine empty agent composer ONLY inside a bordered container. On a bare row
# it is a dead-shell prompt and classifies `unknown` (never a safe injection
# target). The AGENT glyphs `❯` (claude), `›` (codex), and `⟩` (U+27E9, muse)
# are a genuine empty agent composer either way. Both glyph sets are declared
# exactly once below; every decision reaches them through the declarations.
#
# GHOST/PLACEHOLDER TEXT (task afk-herdr-false-pending): a harness fills an
# otherwise-empty composer with de-emphasized ghost text - claude's rotating
# prompt suggestion, codex's idle suggestion, grok's placeholder - which a
# plain capture cannot tell apart from text a human typed.
# fm_composer_strip_ghost is the ONE ANSI-aware extractor of "real typed
# content": it drops every de-emphasized run - dim/faint (SGR 2) AND a
# dark/muted TRUECOLOR foreground - and keeps only normal-intensity,
# normally-coloured text.
#
# UNICODE WHITESPACE (issue #1988; open PRs #1995/#2047 target the same
# defect and #1995's naming is adopted here so the implementations converge):
# a harness may separate its prompt glyph from composer content with a
# non-ASCII space. Real claude 2.x draws its EMPTY composer as exactly `❯`
# followed by U+00A0 NO-BREAK SPACE. POSIX `[[:space:]]` includes U+00A0 only
# under some locales, so every trim used to be locale-dependent: the same live
# pane read `empty` under a UTF-8 shell and `pending` under LC_ALL=C (a
# daemon, launchd, or ssh context), deferring every away-mode escalation.
# fm_composer_normalize_trim_var is the one fix: it maps every code point
# Unicode gives the property White_Space=Yes outside ASCII onto a plain ASCII
# space before any trim or comparison, byte-exactly, so the verdict cannot
# depend on the ambient locale. Glyph strips use literal byte-exact pattern
# removal for the same reason: `${v#?}` removes one BYTE under LC_ALL=C and
# one CHARACTER under UTF-8, which used to leave partial multibyte residue.
#
# Re-sourcing is a cheap idempotent redefinition, so this file needs no
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

# Every code point Unicode gives the property White_Space=Yes that lies OUTSIDE
# ASCII, as UTF-8 byte sequences. Built from octal escapes rather than written
# literally so each entry stays reviewable in source instead of being an
# invisible character:
#   U+0085 NEXT LINE                  U+00A0 NO-BREAK SPACE
#   U+1680 OGHAM SPACE MARK           U+2000..U+200A EN QUAD..HAIR SPACE
#   U+2028 LINE SEPARATOR             U+2029 PARAGRAPH SEPARATOR
#   U+202F NARROW NO-BREAK SPACE      U+205F MEDIUM MATHEMATICAL SPACE
#   U+3000 IDEOGRAPHIC SPACE
# ASCII whitespace is absent because POSIX `[[:space:]]` already covers it.
# U+200B ZERO WIDTH SPACE is deliberately absent: Unicode gives it
# White_Space=No (a format character), so listing it would substitute this
# owner's own guess for the property it claims to follow. The live harness
# guard (bin/fm-test-run.sh, live-harness-optin) is what catches a harness
# that starts drawing its composer with a character outside this property.
FM_COMPOSER_UNICODE_SPACES=()
for _fm_composer_space_octal in \
  '\0302\0205' '\0302\0240' '\0341\0232\0200' \
  '\0342\0200\0200' '\0342\0200\0201' '\0342\0200\0202' '\0342\0200\0203' \
  '\0342\0200\0204' '\0342\0200\0205' '\0342\0200\0206' '\0342\0200\0207' \
  '\0342\0200\0210' '\0342\0200\0211' '\0342\0200\0212' \
  '\0342\0200\0250' '\0342\0200\0251' '\0342\0200\0257' \
  '\0342\0201\0237' '\0343\0200\0200'; do
  printf -v _fm_composer_space_utf8 '%b' "$_fm_composer_space_octal"
  FM_COMPOSER_UNICODE_SPACES+=("$_fm_composer_space_utf8")
done
unset -v _fm_composer_space_octal _fm_composer_space_utf8

# fm_composer_normalize_spaces_var: the ONE Unicode-whitespace mapping.
# Replaces in place through the named variable so no caller needs a subshell.
# Substitution, never deletion: deleting would silently join "foo<NBSP>bar"
# into one token, while a space preserves the separation the harness drew.
fm_composer_normalize_spaces_var() {  # <varname>
  local __fmns_name=$1 __fmns_text=${!1} __fmns_space
  for __fmns_space in "${FM_COMPOSER_UNICODE_SPACES[@]}"; do
    __fmns_text=${__fmns_text//"$__fmns_space"/ }
  done
  printf -v "$__fmns_name" '%s' "$__fmns_text"
}

# fm_composer_normalize_trim_var: the one whitespace-normalizing trim shared by
# this owner and every structural row scan - map Unicode whitespace onto ASCII
# space, then strip leading and trailing whitespace, in place through the named
# variable. Idempotent, locale-independent.
fm_composer_normalize_trim_var() {  # <varname>
  local __fmnt_name=$1 __fmnt_text
  fm_composer_normalize_spaces_var "$__fmnt_name"
  __fmnt_text=${!__fmnt_name}
  __fmnt_text="${__fmnt_text#"${__fmnt_text%%[![:space:]]*}"}"
  __fmnt_text="${__fmnt_text%"${__fmnt_text##*[![:space:]]}"}"
  printf -v "$__fmnt_name" '%s' "$__fmnt_text"
}

# fm_composer_strip_ghost: the ONE fleet-wide ANSI-aware extractor of "real typed
# content" from a captured, styled composer row. Reads the styled line on stdin
# (from `tmux capture-pane -e`, `herdr pane read --format ansi`, or
# `zellij action dump-screen --ansi`) and prints the
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

# The prompt glyphs, each declared exactly once (see THE SAFETY RULE above).
# AGENT glyphs are a genuine empty agent composer on any row, bordered or bare.
# SHELL glyphs are one only INSIDE a composer container; on a bare row they are
# a dead-shell prompt and must never read `empty`. Newline-separated and
# consumed by `read` rather than word splitting, so `$`, `%`, and `#` stay
# literal and no entry is ever exposed to pathname expansion.
FM_COMPOSER_AGENT_PROMPT_GLYPHS=$(printf '%s\n' '❯' '›' '⟩')
FM_COMPOSER_SHELL_PROMPT_GLYPHS=$(printf '%s\n' '>' '$' '%' '#')

# The ONE fleet-wide idle-placeholder set: composer text a harness renders in
# an EMPTY composer that a plain capture cannot tell from typed text. Grok's
# bordered placeholder and opencode's left-bar hint (which continues with a
# rotating quoted suggestion, hence the unanchored tail). FM_COMPOSER_IDLE_RE
# overrides for an unverified harness; matching is case-insensitive.
FM_COMPOSER_IDLE_RE_DEFAULT='^Type a message\.\.\.$|^Ask anything\.\.\.'

# Opencode draws a mode/model footer line INSIDE its left-bar composer
# ("Build · GPT-5.5 Fast OpenAI · high"). It is composer furniture, not typed
# text, and only the run's LAST row is ever matched against it.
FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT='^(Build|Plan)[[:space:]]+·[[:space:]]+'

# The bounded row window adapters should capture for a composer read. One
# shared policy (previously three per-backend variables that had drifted to
# 20/20/200): the composer is bottom-anchored, so a small tail window is
# sufficient and keeps stale scrollback (startup banners, old transcript
# boxes) from ever competing with the live composer.
FM_COMPOSER_CAPTURE_LINES=${FM_COMPOSER_CAPTURE_LINES:-20}

# Pi allows a multi-line composer between its horizontal separators. Bound the
# structural candidate so two unrelated transcript rules with an arbitrarily
# large region between them can never be promoted into a composer.
FM_COMPOSER_PI_MAX_LINES=${FM_COMPOSER_PI_MAX_LINES:-8}

# 0 when <content> is exactly one glyph drawn from <glyph-list>.
_fm_composer_is_prompt_glyph() {  # <content> <glyph-list>
  local content=$1 glyph
  while IFS= read -r glyph; do
    [ -n "$glyph" ] || continue
    [ "$content" = "$glyph" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# fm_composer_leading_prompt_glyph_var: set <out-varname> to the ONE prompt
# glyph <content> begins with once its leading whitespace is ignored, or to the
# empty string (returning 1) when it begins with none. Both glyph lists are
# reached here, so no caller can respell them and drift. Returning the matched
# glyph as a LITERAL string lets every caller remove it byte-exactly with
# `${v#"$glyph"}`, which is correct in every locale.
fm_composer_leading_prompt_glyph_var() {  # <out-varname> <content>
  local __fmpg_out=$1 __fmpg_text=$2 __fmpg_glyph
  __fmpg_text="${__fmpg_text#"${__fmpg_text%%[![:space:]]*}"}"
  while IFS= read -r __fmpg_glyph; do
    [ -n "$__fmpg_glyph" ] || continue
    case "$__fmpg_text" in
      "$__fmpg_glyph"*) printf -v "$__fmpg_out" '%s' "$__fmpg_glyph"; return 0 ;;
    esac
  done <<EOF
$FM_COMPOSER_AGENT_PROMPT_GLYPHS
$FM_COMPOSER_SHELL_PROMPT_GLYPHS
EOF
  printf -v "$__fmpg_out" '%s' ''
  return 1
}

# fm_composer_leading_agent_glyph_var: like the above but AGENT glyphs only.
# The bare-row shape must never be anchored by a shell glyph (dead-shell rule).
fm_composer_leading_agent_glyph_var() {  # <out-varname> <content>
  local __fmag_out=$1 __fmag_text=$2 __fmag_glyph
  __fmag_text="${__fmag_text#"${__fmag_text%%[![:space:]]*}"}"
  while IFS= read -r __fmag_glyph; do
    [ -n "$__fmag_glyph" ] || continue
    case "$__fmag_text" in
      "$__fmag_glyph"*) printf -v "$__fmag_out" '%s' "$__fmag_glyph"; return 0 ;;
    esac
  done <<EOF
$FM_COMPOSER_AGENT_PROMPT_GLYPHS
EOF
  printf -v "$__fmag_out" '%s' ''
  return 1
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
#   <bordered> 1 when <content> came from a genuine agent-composer container (a
#              bordered composer box, an identity-proven separated composer, or
#              a structurally-identified left-bar row); 0 for a bare
#              agent-glyph row, where only the agent glyph itself is proof.
#   <content>  the candidate composer content, border-stripped by the caller.
#   [idle_re]  optional idle-placeholder regex; empty means no idle matching.
#              The screen classifier below passes the resolved fleet-wide idle
#              set; this parameter stays pure so a direct caller's semantics
#              cannot shift underneath it.
#   [idle_case] `sensitive` (default) or `insensitive`.
#   [plain_content] the UNSTRIPPED plain row, consulted when ghost stripping
#              emptied an unbordered row: muse's `⟩` sits at luminance ~150,
#              close enough to the ghost threshold that a raised threshold
#              strips it, and the plain row is what keeps that pane readable.
# Content and plain_content are normalized and re-trimmed on entry, so the
# verdict never depends on which whitespace alphabet the calling adapter
# trimmed with.
fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case] [plain_content]
  local bordered=$1 idle_re=${3:-} idle_case=${4:-sensitive} content plain_content glyph=''
  content=$2
  fm_composer_normalize_trim_var content
  plain_content=${5:-$2}
  fm_composer_normalize_trim_var plain_content
  if [ "$bordered" != 1 ] && [ -z "$content" ] && [ -n "$plain_content" ]; then
    if _fm_composer_is_prompt_glyph "$plain_content" "$FM_COMPOSER_AGENT_PROMPT_GLYPHS"; then
      printf 'empty'; return 0
    fi
    printf 'unknown'; return 0
  fi
  # A bare prompt glyph on its own row.
  # Agent prompt glyph: a genuine empty agent composer, bordered or bare.
  if _fm_composer_is_prompt_glyph "$content" "$FM_COMPOSER_AGENT_PROMPT_GLYPHS"; then
    printf 'empty'; return 0
  fi
  # Shell prompt glyph: empty ONLY inside a composer container (the harness's
  # own prompt). Bare, it is a dead-shell prompt - never a safe injection
  # target.
  if _fm_composer_is_prompt_glyph "$content" "$FM_COMPOSER_SHELL_PROMPT_GLYPHS"; then
    if [ "$bordered" = 1 ]; then printf 'empty'; else printf 'unknown'; fi
    return 0
  fi
  # Nothing on the row = empty composer. The caller proved the container.
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched before a leading glyph is stripped).
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Strip a leading prompt glyph byte-exactly, then re-judge the remainder.
  if fm_composer_leading_prompt_glyph_var glyph "$content"; then
    content=${content#*"$glyph"}
  fi
  fm_composer_normalize_trim_var content
  [ -n "$content" ] || { printf 'empty'; return 0; }
  # Known idle placeholder (matched again after the leading glyph was stripped,
  # e.g. "❯ Type a message...").
  if fm_composer_idle_matches "$content" "$idle_re" "$idle_case"; then
    printf 'empty'; return 0
  fi
  # Real, unsubmitted content remains.
  printf 'pending'; return 0
}

# --- The screen classifier ---------------------------------------------------
#
# fm_composer_classify_screen <caps> <screen> [cursor_row] [identity]
#   <caps>       newline-separated key=value capability facts (see header).
#   <screen>     the captured screen: ANSI-preserving when styled=1, plain
#                otherwise.
#   [cursor_row] zero-based row index of the cursor within <screen>, only
#                meaningful when caps carry cursor=1.
#   [identity]   "<agent>\t<status>" from the backend's native identity probe,
#                or `probe-absent` when the probe found no live identity; only
#                meaningful when caps carry identity=1.
# Prints exactly one verdict: empty | pending | pending-unproven | unknown,
# or the internal sentinel `need-identity` when caps declare identity=1, no
# identity result was supplied, and the verdict depends on it. Adapters answer
# `need-identity` by running their identity probe once and re-calling with
# either its result or `probe-absent`; the sentinel never escapes an adapter.
# Identity stays a lazy second pass so the common non-pi read never pays for
# the probe.
#
# Consumers that can overwrite input or confirm delivery must accept only the
# exact positive proof they require (`empty`), so unrecognized future verdicts
# fail safe by default.

# _fm_composer_pi_separator_row: a solid pi separator - nothing but `─`, at
# least 8 columns wide. The width floor is a literal substring test so it is
# byte-exact in every locale.
_fm_composer_pi_separator_row() {  # <trimmed-row>
  local row=$1
  [ -n "$row" ] || return 1
  [ -z "${row//─/}" ] || return 1
  case "$row" in
    *────────*) return 0 ;;
  esac
  return 1
}

# Row-scan results are returned through FM_COMPOSER_SCAN_* globals (bash 3.2
# has no nameref); they are internal to this owner.
_fm_composer_scan_screen() {  # <plain-screen> <cursor-or-empty>
  local pane=$1 cy=${2:-}
  local line indent left_stripped trimmed kind family side_family
  local top_inner top_spaces='' geometry_check=0 geometry_ambiguous=0
  local content_inner content_spaces bottom_inner bottom_spaces glyph
  local current_indent='' current_family='' row=0 top=-1 valid=0 content_rows=0
  # Complete-box results: the box containing the cursor (cursor mode) or the
  # bottom-most complete box (no cursor).
  FM_COMPOSER_SCAN_BOX_TOP=-1
  FM_COMPOSER_SCAN_BOX_BOTTOM=-1
  FM_COMPOSER_SCAN_BOX_AMBIG=0
  FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=-1
  FM_COMPOSER_SCAN_UNSAFE=0
  FM_COMPOSER_SCAN_CURSOR_EDGE=0
  FM_COMPOSER_SCAN_BARE_ROW=-1
  FM_COMPOSER_SCAN_LEFTBAR_START=-1
  FM_COMPOSER_SCAN_LEFTBAR_END=-1
  FM_COMPOSER_SCAN_PI_PAIR_FOUND=0
  FM_COMPOSER_SCAN_PI_PAIR_VALID=0
  FM_COMPOSER_SCAN_PI_OPEN=-1
  FM_COMPOSER_SCAN_PI_CLOSE=-1
  FM_COMPOSER_SCAN_PI_LAST_SEPARATOR=-1
  local leftbar_start=-1 pi_open=-1 pi_lines=0 pi_max
  pi_max=$FM_COMPOSER_PI_MAX_LINES
  case "$pi_max" in ''|*[!0-9]*|0) pi_max=8 ;; esac
  while IFS= read -r line; do
    indent=${line%%[![:space:]]*}
    left_stripped="${line#"${line%%[![:space:]]*}"}"
    trimmed=$left_stripped
    fm_composer_normalize_trim_var trimmed
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
    # Pi separator rows: a solid `─` rule at least 8 columns wide. A separator
    # closes the preceding candidate and immediately opens the next, so an
    # earlier transcript rule can never outrank the live bottom composer pair.
    if _fm_composer_pi_separator_row "$trimmed"; then
      FM_COMPOSER_SCAN_PI_LAST_SEPARATOR=$row
      if [ "$pi_open" -ge 0 ]; then
        FM_COMPOSER_SCAN_PI_PAIR_FOUND=1
        FM_COMPOSER_SCAN_PI_OPEN=$pi_open
        FM_COMPOSER_SCAN_PI_CLOSE=$row
        if [ "$pi_lines" -le "$pi_max" ]; then
          FM_COMPOSER_SCAN_PI_PAIR_VALID=1
        else
          FM_COMPOSER_SCAN_PI_PAIR_VALID=0
        fi
      fi
      pi_open=$row
      pi_lines=0
    elif [ "$pi_open" -ge 0 ]; then
      pi_lines=$((pi_lines + 1))
    fi
    # Left-bar rows (opencode): a heavy left bar `┃` opening the row with no
    # closing side border. A `┃…┃` row is a bordered box row, not a left bar.
    case "$trimmed" in
      '┃'*'┃') leftbar_start=-1 ;;
      '┃'*)
        if [ "$leftbar_start" -lt 0 ]; then leftbar_start=$row; fi
        FM_COMPOSER_SCAN_LEFTBAR_START=$leftbar_start
        FM_COMPOSER_SCAN_LEFTBAR_END=$row
        ;;
      *) leftbar_start=-1 ;;
    esac
    # Bare agent-glyph rows: the glyph itself is the container proof. Bare
    # shell glyphs are deliberately not candidates (dead-shell rule).
    if fm_composer_leading_agent_glyph_var glyph "$trimmed"; then
      FM_COMPOSER_SCAN_BARE_ROW=$row
    fi
    # Cursor safety: a cursor sitting on a structural edge row is never an
    # input row.
    if [ -n "$cy" ] && [ "$row" -eq "$cy" ] && fm_composer_row_has_edge "$trimmed"; then
      FM_COMPOSER_SCAN_CURSOR_EDGE=1
    fi
    # Complete-box state machine (all border families, geometry, ambiguity).
    if [ "$kind" = top ] || { [ "$kind" = ascii ] && [ "$top" -lt 0 ]; }; then
      if [ -n "$cy" ] && [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; then
        FM_COMPOSER_SCAN_UNSAFE=1
      fi
      top=$row
      FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=$row
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
         && [ "$valid" = 1 ] && [ "$content_rows" -gt 0 ]; then
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
          if [ "$bottom_spaces" != "$top_spaces" ]; then
            # A TITLED bottom border (grok writes its model name there) is
            # tolerated when the inner still starts and ends with the family's
            # own rule glyph: the corners, family, indent, and every content
            # row's geometry were already proven. Anything else is ambiguity.
            if ! _fm_composer_titled_bottom_ok "$family" "$bottom_inner" "$top_spaces"; then
              geometry_ambiguous=1
            fi
          fi
        fi
        if [ -n "$cy" ]; then
          if [ "$top" -lt "$cy" ] && [ "$cy" -lt "$row" ]; then
            FM_COMPOSER_SCAN_BOX_TOP=$top
            FM_COMPOSER_SCAN_BOX_BOTTOM=$row
            FM_COMPOSER_SCAN_BOX_AMBIG=$geometry_ambiguous
          fi
        else
          FM_COMPOSER_SCAN_BOX_TOP=$top
          FM_COMPOSER_SCAN_BOX_BOTTOM=$row
          FM_COMPOSER_SCAN_BOX_AMBIG=$geometry_ambiguous
        fi
        FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=-1
      else
        if [ "$FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM" -lt 0 ]; then
          FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM=$row
        fi
        if [ -n "$cy" ]; then
          if { [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ] && [ "$cy" -le "$row" ]; } \
             || [ "$row" -eq "$cy" ]; then
            FM_COMPOSER_SCAN_UNSAFE=1
          fi
        fi
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
            if content_spaces=$(fm_composer_geometry_spaces "$content_inner"); then
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
  if [ -n "$cy" ] && [ "$top" -ge 0 ] && [ "$top" -lt "$cy" ]; then
    FM_COMPOSER_SCAN_UNSAFE=1
  fi
}

# 0 when a mismatched bottom border reads as a legitimate TITLE: the trimmed
# inner (corners already stripped) still starts and ends with the family's own
# rule glyph, so the title is embedded IN the rule rather than replacing it.
_fm_composer_titled_bottom_ok() {  # <family> <bottom-inner> <top-spaces>
  local family=$1 inner=$2 expected=$3 dash spaces
  fm_composer_normalize_trim_var inner
  case "$family" in
    rounded|light) dash='─' ;;
    double) dash='═' ;;
    heavy) dash='━' ;;
    ascii) dash='-' ;;
    *) return 1 ;;
  esac
  case "$inner" in
    "$dash"*"$dash") ;;
    *) return 1 ;;
  esac
  spaces=${inner//"$dash"/ }
  spaces=$(printf '%s' "$spaces" | LC_ALL=C sed 's/[!-~]/ /g')
  case "$spaces" in
    *[![:space:]]*) return 1 ;;
  esac
  [ "$spaces" = "$expected" ]
}

# fm_composer_row_has_edge: 0 when the trimmed row starts or ends with a
# box-drawing/edge glyph - a structural row, never an input row.
fm_composer_row_has_edge() {  # <trimmed-row>
  local row=$1
  fm_composer_normalize_trim_var row
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

# fm_composer_geometry_spaces: prove a box content row blank to the same width
# as its border. One leading prompt glyph is blanked (every prompt glyph
# occupies one column), the content is normalized so a Unicode space cannot
# defeat the blankness proof, then every remaining ASCII-printable is mapped to
# a space; any other residue fails the proof.
fm_composer_geometry_spaces() {  # <content-inner> -> spaces
  local content=$1 glyph
  fm_composer_normalize_spaces_var content
  if fm_composer_leading_prompt_glyph_var glyph "$content"; then
    content=${content/"$glyph"/ }
  fi
  content=$(printf '%s' "$content" | LC_ALL=C sed 's/[!-~]/ /g')
  case "$content" in
    *[![:space:]]*) return 1 ;;
  esac
  printf '%s' "$content"
}

# _fm_composer_screen_row: print row <n> (zero-based) of <screen>.
_fm_composer_screen_row() {  # <n> <screen>
  printf '%s\n' "$2" | sed -n "$(($1 + 1))p"
}

# _fm_composer_row_content: extract the classification content of one raw row:
# ghost-strip when styled, plain otherwise, normalize-trim, and strip one
# matching pair of side border glyphs.
_fm_composer_row_content() {  # <raw-row> <styled> -> content on stdout
  local raw=$1 styled=$2 stripped
  if [ "$styled" = 1 ]; then
    stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ghost)
  else
    stripped=$(printf '%s\n' "$raw" | fm_composer_strip_ansi)
  fi
  fm_composer_normalize_trim_var stripped
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '║'*'║') stripped=${stripped#║}; stripped=${stripped%║} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  fm_composer_normalize_trim_var stripped
  printf '%s' "$stripped"
}

# _fm_composer_classify_rows: shared multi-row container verdict for the box
# and separated shapes: pending beats empty, an unreadable row is unknown, and
# geometry ambiguity turns pending into pending-unproven and empty into
# unknown (an ambiguous container is not positive proof).
_fm_composer_classify_rows() {  # <screen> <styled> <ambiguous> <first-row> <last-row>
  local screen=$1 styled=$2 ambiguous=$3 first=$4 last=$5
  local row raw content plain state unknown_seen=0
  row=$first
  while [ "$row" -le "$last" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    plain=$(_fm_composer_row_content "$raw" 0)
    state=$(fm_composer_classify_content 1 "$content" \
      "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive "$plain")
    case "$state" in
      pending)
        if [ "$ambiguous" = 1 ]; then printf 'pending-unproven'; else printf 'pending'; fi
        return 0
        ;;
      unknown) unknown_seen=1 ;;
    esac
    row=$((row + 1))
  done
  if [ "$unknown_seen" = 1 ] || [ "$ambiguous" = 1 ]; then
    printf 'unknown'
  else
    printf 'empty'
  fi
}

# _fm_composer_classify_bare_row: the bare agent-glyph row verdict, including
# the styled=0 degradation: without styling, trailing text after the glyph may
# be the harness's own idle suggestion (claude's rotating dim hint, codex's
# `Use /skills ...`), so it must read `unknown` rather than a false `pending`.
_fm_composer_classify_bare_row() {  # <screen> <styled> <row>
  local screen=$1 styled=$2 row=$3 raw content plain state
  raw=$(_fm_composer_screen_row "$row" "$screen")
  content=$(_fm_composer_row_content "$raw" "$styled")
  plain=$(_fm_composer_row_content "$raw" 0)
  state=$(fm_composer_classify_content 0 "$content" \
    "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive "$plain")
  if [ "$styled" != 1 ] && [ "$state" = pending ]; then
    printf 'unknown'
    return 0
  fi
  printf '%s' "$state"
}

# _fm_composer_wrap_region_ok: 0 when every row STRICTLY BELOW <glyph-row>
# through <cursor-row> is non-blank and carries no structural edge - the
# contiguity proof that those rows are the bare composer's wrapped input
# rather than unrelated screen content.
_fm_composer_wrap_region_ok() {  # <plain-screen> <glyph-row> <cursor-row>
  local plain=$1 g=$2 cy=$3 row line trimmed
  row=$((g + 1))
  while [ "$row" -le "$cy" ]; do
    line=$(_fm_composer_screen_row "$row" "$plain")
    trimmed=$line
    fm_composer_normalize_trim_var trimmed
    [ -n "$trimmed" ] || return 1
    if fm_composer_row_has_edge "$trimmed"; then return 1; fi
    row=$((row + 1))
  done
  return 0
}

# _fm_composer_classify_bare_wrap: the bare composer plus its wrap region.
# Content is the glyph row (glyph stripped) plus every continuation row down
# to the cursor. Ghost-stripped-to-nothing rows are an empty composer whose
# suggestion happened to wrap; any surviving text is pending when styling can
# prove it real and unknown otherwise (the same styled=0 degradation as the
# glyph row itself).
_fm_composer_classify_bare_wrap() {  # <screen> <styled> <glyph-row> <cursor-row>
  local screen=$1 styled=$2 g=$3 cy=$4 row raw content glyph='' text_seen=0
  row=$g
  while [ "$row" -le "$cy" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    if [ "$row" -eq "$g" ] && fm_composer_leading_agent_glyph_var glyph "$content"; then
      content=${content#*"$glyph"}
    fi
    fm_composer_normalize_trim_var content
    [ -z "$content" ] || text_seen=1
    row=$((row + 1))
  done
  if [ "$text_seen" = 0 ]; then
    printf 'empty'
    return 0
  fi
  if [ "$styled" = 1 ]; then printf 'pending'; else printf 'unknown'; fi
}

# _fm_composer_classify_leftbar: opencode's left-bar composer. Blank rows and
# the idle hint read empty; the run's LAST row may be the mode/model footer
# (composer furniture, never typed text). Real content is pending when styling
# can prove it real, unknown otherwise.
_fm_composer_classify_leftbar() {  # <screen> <styled> <first-row> <last-row>
  local screen=$1 styled=$2 first=$3 last=$4
  local row raw content pending_seen=0 footer_re
  footer_re=${FM_COMPOSER_LEFTBAR_FOOTER_RE:-$FM_COMPOSER_LEFTBAR_FOOTER_RE_DEFAULT}
  row=$first
  while [ "$row" -le "$last" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    case "$content" in
      '┃'*) content=${content#┃} ;;
    esac
    fm_composer_normalize_trim_var content
    if [ -z "$content" ]; then row=$((row + 1)); continue; fi
    if fm_composer_idle_matches "$content" "${FM_COMPOSER_IDLE_RE:-$FM_COMPOSER_IDLE_RE_DEFAULT}" insensitive; then
      row=$((row + 1)); continue
    fi
    if [ "$row" -eq "$last" ] \
       && fm_composer_idle_matches "$content" "$footer_re" sensitive; then
      row=$((row + 1)); continue
    fi
    pending_seen=1
    row=$((row + 1))
  done
  if [ "$pending_seen" = 1 ]; then
    if [ "$styled" = 1 ]; then printf 'pending'; else printf 'unknown'; fi
  else
    printf 'empty'
  fi
}

fm_composer_classify_screen() {  # <caps> <screen> [cursor_row] [identity]
  local caps=$1 screen=$2 cy=${3:-} identity=${4:-}
  local styled=0 cursor=0 has_identity=0 kv plain
  local generic=-1 winner=''
  while IFS= read -r kv; do
    case "$kv" in
      styled=1) styled=1 ;;
      cursor=1) cursor=1 ;;
      identity=1) has_identity=1 ;;
    esac
  done <<EOF
$caps
EOF
  [ "$cursor" = 1 ] || cy=''
  if [ -n "$cy" ]; then
    case "$cy" in *[!0-9]*) printf 'unknown'; return 0 ;; esac
  fi
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  _fm_composer_scan_screen "$plain" "$cy"
  if [ -n "$cy" ]; then
    # Cursor mode (tmux): the shape CONTAINING the cursor is the composer.
    if [ "$FM_COMPOSER_SCAN_UNSAFE" = 1 ]; then
      printf 'unknown'; return 0
    fi
    if [ "$FM_COMPOSER_SCAN_BOX_TOP" -ge 0 ]; then
      _fm_composer_classify_rows "$screen" "$styled" "$FM_COMPOSER_SCAN_BOX_AMBIG" \
        "$((FM_COMPOSER_SCAN_BOX_TOP + 1))" "$((FM_COMPOSER_SCAN_BOX_BOTTOM - 1))"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_LEFTBAR_START" -ge 0 ] \
       && [ "$cy" -ge "$FM_COMPOSER_SCAN_LEFTBAR_START" ] \
       && [ "$cy" -le "$FM_COMPOSER_SCAN_LEFTBAR_END" ]; then
      _fm_composer_classify_leftbar "$screen" "$styled" \
        "$FM_COMPOSER_SCAN_LEFTBAR_START" "$FM_COMPOSER_SCAN_LEFTBAR_END"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_BARE_ROW" -ge 0 ] && [ "$cy" -eq "$FM_COMPOSER_SCAN_BARE_ROW" ]; then
      if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
         && [ "$cy" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
         && [ "$cy" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
        _fm_composer_classify_bare_pi_overlap "$screen" "$styled" "$has_identity" "$identity" "$cy"
      else
        _fm_composer_classify_bare_row "$screen" "$styled" "$cy"
      fi
      return 0
    fi
    # A bare composer's WRAP region: long typed input wraps below the glyph
    # row, and the cursor lands on a continuation row that carries no glyph of
    # its own. When every row from the glyph row down to the cursor is
    # non-blank and non-structural, the cursor is inside that composer's
    # wrapped input - an IDENTIFIED region, so the strict blank-row rule does
    # not apply and a swallowed Enter on a long message still reads pending
    # and earns its retry.
    if [ "$FM_COMPOSER_SCAN_BARE_ROW" -ge 0 ] && [ "$cy" -gt "$FM_COMPOSER_SCAN_BARE_ROW" ] \
       && _fm_composer_wrap_region_ok "$plain" "$FM_COMPOSER_SCAN_BARE_ROW" "$cy"; then
      _fm_composer_classify_bare_wrap "$screen" "$styled" "$FM_COMPOSER_SCAN_BARE_ROW" "$cy"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
       && [ "$cy" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
       && [ "$cy" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
      _fm_composer_pi_verdict "$screen" "$styled" "$has_identity" "$identity"
      return 0
    fi
    if [ "$FM_COMPOSER_SCAN_CURSOR_EDGE" = 1 ]; then
      printf 'unknown'; return 0
    fi
    # STRICT: a blank or otherwise unidentified cursor row has no positive
    # container proof. This replaced the permissive blank-cursor-row rule
    # (captain decision blank-row-injection-posture).
    printf 'unknown'
    return 0
  fi
  # No cursor: the bottom-most shape wins, with the pi-separator staleness
  # rules layered on (a live pi composer pair below the generic candidate
  # proves that candidate stale).
  generic=-1
  winner=''
  if [ "$FM_COMPOSER_SCAN_BOX_BOTTOM" -ge 0 ]; then
    generic=$FM_COMPOSER_SCAN_BOX_BOTTOM
    winner=box
  fi
  if [ "$FM_COMPOSER_SCAN_BARE_ROW" -gt "$generic" ]; then
    generic=$FM_COMPOSER_SCAN_BARE_ROW
    winner=bare
  fi
  if [ "$FM_COMPOSER_SCAN_LEFTBAR_END" -gt "$generic" ]; then
    generic=$FM_COMPOSER_SCAN_LEFTBAR_END
    winner=leftbar
  fi
  if [ "$FM_COMPOSER_SCAN_INCOMPLETE_BOX_FROM" -gt "$generic" ]; then
    printf 'unknown'
    return 0
  fi
  if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
     && [ "$FM_COMPOSER_SCAN_PI_CLOSE" -gt "$generic" ] \
     && [ "$generic" -lt "$FM_COMPOSER_SCAN_PI_OPEN" ]; then
    _fm_composer_pi_verdict "$screen" "$styled" "$has_identity" "$identity"
    return 0
  fi
  if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 0 ] \
     && [ "$FM_COMPOSER_SCAN_PI_LAST_SEPARATOR" -gt "$generic" ]; then
    # A lower unmatched separator proves the generic candidate is stale, but
    # does not provide the complete pi composer structure.
    printf 'unknown'
    return 0
  fi
  case "$winner" in
    box)
      _fm_composer_classify_rows "$screen" "$styled" "$FM_COMPOSER_SCAN_BOX_AMBIG" \
        "$((FM_COMPOSER_SCAN_BOX_TOP + 1))" "$((FM_COMPOSER_SCAN_BOX_BOTTOM - 1))"
      ;;
    bare)
      if [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
         && [ "$FM_COMPOSER_SCAN_BARE_ROW" -gt "$FM_COMPOSER_SCAN_PI_OPEN" ] \
         && [ "$FM_COMPOSER_SCAN_BARE_ROW" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; then
        _fm_composer_classify_bare_pi_overlap "$screen" "$styled" "$has_identity" "$identity" \
          "$FM_COMPOSER_SCAN_BARE_ROW"
      else
        _fm_composer_classify_bare_row "$screen" "$styled" "$FM_COMPOSER_SCAN_BARE_ROW"
      fi
      ;;
    leftbar)
      _fm_composer_classify_leftbar "$screen" "$styled" \
        "$FM_COMPOSER_SCAN_LEFTBAR_START" "$FM_COMPOSER_SCAN_LEFTBAR_END"
      ;;
    *)
      printf 'unknown'
      ;;
  esac
}

# fm_composer_submit_retry_core: the ONE verify-and-retry-Enter submit loop
# for the cursor-less backends (cmux, orca, zellij), parameterised by the
# adapter's send-key and composer-state functions. The caller has already
# typed the text ONCE (send_literal) and settled; this loop submits with
# Enter, re-reading the composer verdict, and retries Enter ONLY - never
# retypes, because a swallowed Enter leaves the text in the composer and
# retyping would duplicate it. Proven pending (and pending-unproven) retries
# consume the budget; any other verdict returns immediately, so `unknown`
# stays a loud refusal rather than a blind retry into an unreadable pane.
# tmux keeps its own richer core (bin/fm-tmux-lib.sh: the busy-queued-Enter
# and idle-baseline turn-started conversions its busy primitive enables), and
# herdr confirms through native agent-state; both consume the same shared
# verdict, so no shape knowledge lives in any of the three loops.
fm_composer_submit_retry_core() {  # <send-key-fn> <state-fn> <target> <retries> <enter-sleep> [expected-label]
  local send_key_fn=$1 state_fn=$2 target=$3 retries=$4 sleep_s=$5 expected_label=${6:-} i=0 state
  while :; do
    "$send_key_fn" "$target" Enter "$expected_label" || true
    sleep "$sleep_s"
    state=$("$state_fn" "$target" "$expected_label")
    case "$state" in
      pending|pending-unproven) ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf '%s' "$state"; return 0; }
  done
}

_fm_composer_classify_pi_rows() {  # <screen> <styled>
  local screen=$1 styled=$2 row raw content
  row=$((FM_COMPOSER_SCAN_PI_OPEN + 1))
  while [ "$row" -lt "$FM_COMPOSER_SCAN_PI_CLOSE" ]; do
    raw=$(_fm_composer_screen_row "$row" "$screen")
    content=$(_fm_composer_row_content "$raw" "$styled")
    fm_composer_normalize_trim_var content
    if [ -n "$content" ]; then
      printf 'pending'
      return 0
    fi
    row=$((row + 1))
  done
  printf 'empty'
}

_fm_composer_classify_bare_pi_overlap() {  # <screen> <styled> <has-identity> <identity> <bare-row>
  local screen=$1 styled=$2 has_identity=$3 identity=$4 row=$5 agent
  if [ "$has_identity" != 1 ]; then
    _fm_composer_classify_bare_row "$screen" "$styled" "$row"
    return 0
  fi
  if [ -z "$identity" ]; then
    printf 'need-identity'
    return 0
  fi
  if [ "$identity" = probe-absent ]; then
    _fm_composer_classify_bare_row "$screen" "$styled" "$row"
    return 0
  fi
  agent=${identity%%$'\t'*}
  if [ "$agent" = pi ]; then
    _fm_composer_pi_verdict "$screen" "$styled" "$has_identity" "$identity"
  else
    _fm_composer_classify_bare_row "$screen" "$styled" "$row"
  fi
}

# The pi separated-shape verdict: identity + structure conjunction (herdr's
# rule, now fleet-wide). A missing identity capability keeps the shape
# unknown; an unfetched identity on an identity-capable backend asks the
# adapter to probe (lazily) and re-call. Proven input remains pending for every
# live pi state, while only an idle/done/blocked pi proves an empty composer.
_fm_composer_pi_verdict() {  # <screen> <styled> <has_identity> <identity>
  local screen=$1 styled=$2 has_identity=$3 identity=$4 agent agent_status state
  if [ "$has_identity" != 1 ]; then
    printf 'unknown'
    return 0
  fi
  if [ -z "$identity" ]; then
    printf 'need-identity'
    return 0
  fi
  if [ "$identity" = probe-absent ]; then
    printf 'unknown'
    return 0
  fi
  agent=${identity%%$'\t'*}
  agent_status=${identity#*$'\t'}
  if [ "$agent" != pi ] || [ "$FM_COMPOSER_SCAN_PI_PAIR_VALID" != 1 ]; then
    printf 'unknown'
    return 0
  fi
  state=$(_fm_composer_classify_pi_rows "$screen" "$styled")
  if [ "$state" = pending ]; then
    printf 'pending'
    return 0
  fi
  case "$agent_status" in
    idle|done|blocked) printf 'empty' ;;
    *) printf 'unknown' ;;
  esac
}
