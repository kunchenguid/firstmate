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
# Each adapter still owns its own CAPTURE and structural row-finding, because
# those use genuinely different primitives (tmux's cursor-row read, herdr's ANSI
# tail scan, orca/cmux's plain read-screen). Once an adapter has a candidate
# composer row, it strips the box borders, trims, and hands the resulting
# content plus a <bordered> flag to fm_composer_classify_content for the shared
# empty|pending|unknown verdict. Re-sourcing is a cheap idempotent redefinition,
# so this file needs no include guard (matching bin/fm-tmux-lib.sh).

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

fm_composer_classify_content() {  # <bordered> <content> [idle_re] [idle_case]
  local bordered=$1 content=$2 idle_re=${3:-} idle_case=${4:-sensitive}
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
